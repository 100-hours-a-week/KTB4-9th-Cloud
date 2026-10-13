# COSMOS v2 ECS 공통 기반 아키텍처

> 최신 통합 구조는 [Stage/Prod 공용 VPC 설계](../docs/superpowers/specs/2026-10-11-stage-prod-shared-vpc-design.md), [Stage 서비스 HTTPS 설계](../docs/superpowers/specs/2026-10-12-stage-service-subdomain-https-design.md), [AI PostgreSQL 및 ECS 런타임 계약](../docs/superpowers/specs/2026-10-12-ai-pgvector-runtime-contract-design.md)을 기준으로 한다. 실제 구축 순서는 [Stage 운영 절차](stage-operations.md)를 따른다. 이 문서의 기존 단계별 범위 설명은 설계 이력을 보존한다.

## 1. 문서 목적

이 문서는 COSMOS v2 애플리케이션을 AWS ECS에 배포하기 전에 구축할 공통 인프라의 설계를 정의한다.

이번 단계에서는 애플리케이션별 용량이나 Auto Scaling 수치를 확정하지 않는다. 운영 초기에는 각 서비스를 최소 수량으로 실행하되, 이후 부하 테스트 결과에 따라 ECS Task와 EC2 용량을 변경할 수 있는 기반을 만드는 것이 목적이다.

### 1.1 현재 Stage 외부 진입 구조

현재 구현은 공용 VPC 안에서 Stage와 Prod state를 분리하고, Stage 테스트를 위해 세 애플리케이션을 하나의 ALB HTTPS Listener에서 Host 기반으로 라우팅한다.

```text
Internet
   ├─ https://stage.cosmoscode.site ───────────── CloudFront ── S3 frontend
   │                                                  └──────── ALB HTTP :80 ── Spring
   │
   ├─ https://stage-be.cosmoscode.site ────────┐
   ├─ https://stage-ai.cosmoscode.site ────────┼─ Route 53 A Alias
   └─ https://stage-judge.cosmoscode.site ─────┘
                                                  │
                                                  ▼
                                          Stage ALB HTTPS :443
                                      ┌───────────┼────────────┐
                                      ▼           ▼            ▼
                                Spring :8080  FastAPI :8000  Judge :2358
```

- 서울 리전 wildcard ACM 인증서는 Shared Workspace가 관리한다.
- Stage `443/tcp`는 테스트 기간에 한해 IPv4 인터넷 전체에 공개한다.
- HTTP `80`은 CloudFront origin-facing prefix list에서만 접근할 수 있다.
- Stage ECS Service는 각 1개 Task로 시작하고 세 서비스 모두 ALB health check를 사용한다.
- Prod는 기존 Spring-only ALB 연결을 유지하고 FastAPI와 Judge API를 외부 공개하지 않는다.
- Prod의 내부 FastAPI와 Judge API는 ALB health가 없으므로 각 이미지에 포함된 Python/Ruby 런타임으로 container HTTP health check를 실행한다.
- Service Connect 최초 기동은 Judge 안정화 후 FastAPI와 Spring을 순서대로 재배포해 client가 backend endpoint 등록 이후 시작하도록 한다.
- MySQL과 Backend Valkey 인프라는 AWS 관리형 서비스를 사용한다. 현재 Spring은 MySQL만 연결하고 Valkey는 연결하지 않는다.
- AI PostgreSQL 17+pgvector, Judge PostgreSQL, Judge Redis는 각각 전용 ECS on EC2 1대와 보존형 EBS로 운영한다.

## 2. 설계 목표

- 기존 Oregon 리전의 v1 인프라와 분리된 서울 리전 v2 환경을 구축한다.
- 인터넷에 직접 노출되는 리소스와 애플리케이션 실행 리소스를 네트워크 수준에서 분리한다.
- 서로 다른 두 가용 영역을 사용해 추후 다중 AZ로 확장할 수 있게 한다.
- ECR, ECS, ALB, IAM, CloudWatch를 애플리케이션 배포 전에 공통 기반으로 준비한다.
- 초기 고정 비용을 줄이기 위해 NAT Gateway는 하나만 사용한다.
- v1과 v2의 Terraform state를 완전히 분리한다.
- 비밀값을 Terraform 코드와 state에 저장하지 않는다.

## 3. 이번 단계의 범위

### 3.1 포함 범위

- 서울 리전 전용 VPC
- 서로 다른 두 가용 영역의 Public subnet 2개
- 서로 다른 두 가용 영역의 Private subnet 2개
- Internet Gateway
- NAT Gateway 1개와 Elastic IP
- Public route table 1개
- AZ별 Private route table 2개
- S3 Gateway VPC Endpoint
- 인터넷-facing Application Load Balancer
- ALB HTTP fixed-response listener
- ALB Security Group
- ECS Cluster
- Fargate Capacity Provider 연결
- 서비스별 ECR repository 3개
- ECR lifecycle policy
- ECS task execution role
- 서비스별 CloudWatch Log Group
- Terraform 변수, 출력 및 공통 태그
- v1과 분리된 Terraform Cloud workspace

### 3.2 제외 범위

- ECS Task Definition
- ECS Service
- 애플리케이션 컨테이너 배포
- ECS 서비스별 Security Group
- ALB Target Group 및 서비스 routing rule
- ACM 인증서와 HTTPS listener
- Route 53 레코드 및 v1에서 v2로의 트래픽 전환
- RDS MySQL/PostgreSQL
- ElastiCache Valkey
- Judge Worker용 ECS on EC2 및 EC2 Capacity Provider
- Auto Scaling 정책
- Secrets Manager secret 생성 및 실제 비밀값
- 애플리케이션 배포 CI/CD
- VPC Flow Logs 활성화

## 4. 기존 v1과의 분리

하나의 Git repository 안에서 v1과 v2 코드를 디렉터리로 분리한다.

```text
KTB4-9th-Cloud/
├── v1/  -> Terraform Cloud workspace: KTB4-9th-Cloud
└── v2/  -> Terraform Cloud workspace: KTB4-9th-Cloud-v2-prod
```

Git branch와 디렉터리는 코드 변경을 분리하지만 Terraform state를 분리하지는 않는다. v2는 반드시 빈 state를 가진 별도 Terraform Cloud workspace `KTB4-9th-Cloud-v2-prod`를 사용한다.

v2 코드가 기존 v1 리소스를 소유하거나 변경하지 않도록 다음 원칙을 적용한다.

- v1 리소스를 v2 state로 이동하지 않는다.
- v2에서 v1 리소스를 직접 참조하지 않는다.
- v2 plan에 v1 리소스의 변경 또는 삭제가 나타나면 apply하지 않는다.
- v2 workspace의 AWS 인증 정보와 Terraform 변수를 v1 workspace와 별도로 관리한다.

## 5. 리전 및 네트워크 설계

### 5.1 리전과 가용 영역

- AWS Region: `ap-northeast-2`
- Availability Zones: `ap-northeast-2a`, `ap-northeast-2c`

가용 영역은 변수로 관리하되 운영 기본값은 위 두 영역으로 고정한다.

### 5.2 CIDR 배치

기존 v1 VPC의 `10.0.0.0/16`과 겹치지 않도록 v2는 `10.20.0.0/16`을 사용한다.

| 용도 | 가용 영역 | CIDR |
| --- | --- | --- |
| Public subnet A | ap-northeast-2a | `10.20.0.0/24` |
| Public subnet C | ap-northeast-2c | `10.20.1.0/24` |
| Private subnet A | ap-northeast-2a | `10.20.10.0/24` |
| Private subnet C | ap-northeast-2c | `10.20.11.0/24` |
| 향후 데이터 subnet A 예약 | ap-northeast-2a | `10.20.20.0/24` |
| 향후 데이터 subnet C 예약 | ap-northeast-2c | `10.20.21.0/24` |

향후 데이터 subnet CIDR은 이번 단계에서 실제 subnet으로 생성하지 않는다.

### 5.3 네트워크 흐름

```text
Internet
   |
Internet Gateway
   |
Public route table
   ├── Public subnet A: ALB, NAT Gateway
   └── Public subnet C: ALB
                         |
                    NAT Gateway A
                         |
              ┌──────────┴──────────┐
       Private route table A  Private route table C
              |                     |
       Private subnet A      Private subnet C
```

- Public route table은 `0.0.0.0/0`을 Internet Gateway로 전달한다.
- Private route table A와 C는 각각 생성한다.
- 두 Private route table의 `0.0.0.0/0` 경로는 초기에는 동일한 NAT Gateway를 가리킨다.
- NAT Gateway는 Public subnet A에 배치한다.
- 향후 두 번째 NAT Gateway를 추가하면 Private route table C의 기본 경로만 NAT Gateway C로 변경한다.
- Fargate Task에는 public IP를 할당하지 않는다.

### 5.4 단일 NAT Gateway의 한계

단일 NAT Gateway는 초기 고정 비용을 줄일 수 있지만 다음 한계를 가진다.

- NAT Gateway 또는 `ap-northeast-2a` 장애 시 두 Private subnet의 인터넷 outbound가 중단된다.
- Private subnet C에서 NAT Gateway A로 전달되는 트래픽에는 cross-AZ 데이터 처리 비용이 발생할 수 있다.
- 외부 API 호출, 신규 이미지 pull, 외부 패키지 접근 등에 영향을 줄 수 있다.

초기 운영에서는 이 위험을 수용한다. 서비스 가용성 요구가 높아지면 AZ별 NAT Gateway 구성으로 전환한다.

### 5.5 VPC Endpoint

이번 단계에서는 추가 사용료가 없는 S3 Gateway Endpoint를 생성하고 두 Private route table에 연결한다. 향후 ECR 이미지를 pull할 때 이미지 레이어를 S3에서 NAT Gateway를 통하지 않고 받을 수 있다.

다음 Interface Endpoint는 실제 ECS Service 구축 시 애플리케이션의 outbound 요구사항 및 NAT 비용과 비교한 후 추가한다.

- ECR API
- ECR DKR
- CloudWatch Logs
- Secrets Manager

## 6. ECS Cluster 설계

### 6.1 Cluster

- 이름: `cosmos-v2-prod-cluster`
- Container Insights: 활성화
- Capacity Provider: `FARGATE`
- 기본 Capacity Provider: `FARGATE`

이번 단계에서는 ECS Cluster와 Capacity Provider 연결만 생성한다. Task Definition과 ECS Service는 생성하지 않는다.

향후 ECS Service는 다음 원칙을 따른다.

- `awsvpc` network mode를 사용한다.
- 두 Private subnet을 네트워크 후보로 지정한다.
- `assign_public_ip = false`를 적용한다.
- 운영 초기 `desired_count`는 최소값으로 설정한다.
- 서비스별 부하 테스트 이후 원하는 수량과 Auto Scaling 정책을 조정한다.

## 7. ECR 설계

동일한 AWS ECR Registry 안에 서비스별 repository를 생성한다.

```text
cosmos-v2/spring
cosmos-v2/fastapi
cosmos-v2/judge
```

repository 이름에 환경명을 포함하지 않는다. 이후 staging 환경이 생겨도 동일한 이미지 digest를 검증 후 production에 배포할 수 있게 한다.

각 repository에는 다음 정책을 적용한다.

- Image tag mutability: `IMMUTABLE`
- Push 시 이미지 스캔 활성화
- AES-256 server-side encryption
- `force_delete = false`
- untagged 이미지 정리
- 최근 배포 이미지 일정 개수 유지

Lifecycle policy의 정확한 보존 개수와 기간은 Terraform 변수로 관리한다. 기본값은 tagged 이미지 최근 20개 보관과 untagged 이미지 7일 후 삭제로 한다.

## 8. Application Load Balancer 설계

- 이름: `cosmos-v2-prod-alb`
- 유형: Application Load Balancer
- Scheme: internet-facing
- Subnets: Public subnet A, Public subnet C
- Deletion protection: 활성화
- HTTP port 80: 허용
- HTTPS port 443: 보안 그룹에서 허용하되 listener는 후속 단계에서 생성

초기 HTTP listener는 모든 요청에 고정 `404` 응답을 반환한다. 이를 통해 Target Group이나 ECS Service 없이도 ALB 생성 및 네트워크 연결을 검증할 수 있다.

다음 항목은 실제 서비스 배포 단계에서 추가한다.

- ACM 인증서
- HTTPS listener
- HTTP에서 HTTPS로 redirect
- 서비스별 Target Group
- Host/path 기반 listener rule
- Route 53 alias record
- ALB access log용 S3 bucket

## 9. Security Group 설계

### 9.1 ALB Security Group

Inbound:

- TCP 80 from `0.0.0.0/0`
- TCP 443 from `0.0.0.0/0`

Outbound:

- 초기에는 전체 허용
- 서비스의 container port가 확정되면 ECS Service Security Group 대상으로 제한

### 9.2 ECS Service Security Group

이번 단계에서는 생성하지 않는다. 서비스별 container port와 호출 관계가 확정되기 전에 공통 SG를 만들면 불필요하게 넓은 포트를 허용할 수 있기 때문이다.

후속 단계에서 Spring, FastAPI, Judge API별 SG를 만들고 ALB SG 또는 호출 주체 SG를 source로 사용한다. CIDR 기반으로 애플리케이션 포트를 공개하지 않는다.

### 9.3 Network ACL

별도의 custom Network ACL을 만들지 않고 기본 Network ACL을 유지한다. 초기 보안 경계는 Security Group으로 관리한다.

## 10. IAM 설계

이번 단계에서는 공통 ECS task execution role을 생성한다.

허용 범위:

- ECR 인증 및 이미지 pull
- CloudWatch Logs 전송

애플리케이션이 사용하는 task role은 서비스 구축 단계에서 서비스별로 생성한다. Task execution role과 task role을 분리해 애플리케이션 컨테이너가 배포용 권한을 상속하지 않게 한다.

Secrets Manager 접근 권한은 secret ARN이 확정된 후 execution role 또는 서비스별 task role에 최소 권한으로 추가한다. wildcard secret 접근 권한은 부여하지 않는다.

## 11. 로그 및 관측성 설계

다음 CloudWatch Log Group을 미리 생성한다.

```text
/ecs/cosmos-v2-prod/spring
/ecs/cosmos-v2-prod/fastapi
/ecs/cosmos-v2-prod/judge-api
```

- 기본 보존 기간: 30일
- 보존 기간은 Terraform 변수로 관리
- 애플리케이션 Task Definition 생성 시 `awslogs` driver에 연결
- Container Insights를 ECS Cluster에 활성화
- VPC Flow Logs는 비용을 고려해 기본 비활성화

## 12. Secret 관리 원칙

이번 단계에서는 Secrets Manager secret 또는 secret version을 생성하지 않는다.

- 실제 secret 값을 `.tf`, `.tfvars`, Terraform output에 넣지 않는다.
- secret 값을 Terraform으로 생성해 state에 저장하지 않는다.
- 서비스별 secret naming convention은 후속 단계에서 정의한다.
- secret ARN이 확정되면 해당 서비스 IAM role에만 접근을 허용한다.
- secret rotation 이후 ECS Task가 새 값을 받도록 신규 deployment 절차를 마련한다.

## 13. Terraform 구성

v2는 현재 production 환경 하나만 관리하므로 별도 module 계층 없이 하나의 root module로 구성한다.

```text
v2/
├── architecture.md
├── versions.tf
├── providers.tf
├── variables.tf
├── locals.tf
├── network.tf
├── security.tf
├── ecr.tf
├── ecs.tf
├── alb.tf
├── iam.tf
├── logging.tf
└── outputs.tf
```

추후 dev 또는 staging 환경을 실제로 구축할 때 공통 부분을 reusable module로 추출한다. 사용하지 않는 환경을 가정해 초기부터 module 계층을 만들지는 않는다.

## 14. Terraform 변수

| 변수 | 기본값 | 설명 |
| --- | --- | --- |
| `aws_region` | `ap-northeast-2` | AWS 리전 |
| `project_name` | `cosmos-v2` | 리소스 이름 접두사 |
| `environment` | `prod` | 실행 환경 |
| `vpc_cidr` | `10.20.0.0/16` | VPC CIDR |
| `availability_zones` | `ap-northeast-2a`, `ap-northeast-2c` | 사용할 AZ |
| `public_subnet_cidrs` | `10.20.0.0/24`, `10.20.1.0/24` | Public subnet CIDR |
| `private_subnet_cidrs` | `10.20.10.0/24`, `10.20.11.0/24` | Private subnet CIDR |
| `ecr_repository_names` | `spring`, `fastapi`, `judge` | ECR repository 이름 |
| `ecr_tagged_image_count` | `20` | 유지할 tagged 이미지 개수 |
| `ecr_untagged_max_age_days` | `7` | untagged 이미지 보존 기간 |
| `cloudwatch_log_retention_days` | `30` | 로그 보존 기간 |
| `enable_container_insights` | `true` | Container Insights 활성화 |

변수 validation은 다음을 확인한다.

- CIDR 값의 유효성
- 가용 영역 개수가 2개인지
- Public/private CIDR 개수가 AZ 개수와 같은지
- environment가 허용된 값인지
- CloudWatch Logs가 지원하는 보존 기간인지

## 15. 공통 태그

모든 지원 리소스에 다음 태그를 적용한다.

```text
Project     = cosmos
Version     = v2
Environment = prod
ManagedBy   = Terraform
```

각 리소스에는 공통 태그와 별도로 식별 가능한 `Name` 태그를 추가한다.

## 16. Terraform 출력

후속 애플리케이션 인프라에서 사용할 수 있도록 다음 값을 출력한다.

- `vpc_id`
- `public_subnet_ids`
- `private_subnet_ids`
- `public_route_table_id`
- `private_route_table_ids`
- `internet_gateway_id`
- `nat_gateway_id`
- `nat_gateway_public_ip`
- `s3_gateway_endpoint_id`
- `ecs_cluster_name`
- `ecs_cluster_arn`
- `ecr_repository_urls`
- `ecr_repository_arns`
- `alb_arn`
- `alb_dns_name`
- `alb_zone_id`
- `alb_security_group_id`
- `ecs_task_execution_role_arn`
- `cloudwatch_log_group_names`

비밀값과 AWS 인증 정보는 출력하지 않는다.

## 17. 삭제 및 변경 안전장치

- ALB deletion protection을 활성화한다.
- ECR repository는 `force_delete = false`로 설정한다.
- ECR tag immutability를 활성화한다.
- NAT Gateway의 Elastic IP는 Terraform에서 함께 관리한다.
- 리소스 참조를 사용해 생성 및 삭제 순서를 표현한다.
- 실제 secret 값을 Terraform state에 저장하지 않는다.
- VPC 전체에는 `prevent_destroy`를 적용하지 않는다. 정상적인 네트워크 변경까지 차단하는 것을 피하기 위함이다.
- v2 plan에 v1 리소스가 나타나면 apply하지 않는다.

## 18. 검증 계획

### 18.1 정적 검증

```bash
terraform fmt -check
terraform init
terraform validate
terraform plan
```

### 18.2 Plan 검토

- 대상 리전이 `ap-northeast-2`인지 확인한다.
- Terraform Cloud workspace가 `KTB4-9th-Cloud-v2-prod`인지 확인한다.
- v1 리소스의 변경 또는 삭제가 없는지 확인한다.
- NAT Gateway가 정확히 1개인지 확인한다.
- Public/private subnet이 각각 2개인지 확인한다.
- subnet이 서로 다른 두 AZ에 배치되는지 확인한다.
- Private route table 2개가 동일한 NAT Gateway를 가리키는지 확인한다.
- ECR repository가 3개인지 확인한다.
- ECS Task Definition과 ECS Service가 생성되지 않는지 확인한다.
- 예상하지 않은 destroy가 없는지 확인한다.

### 18.3 Apply 후 검증

- Public subnet의 기본 경로가 Internet Gateway를 가리키는지 확인한다.
- Private subnet의 기본 경로가 NAT Gateway를 가리키는지 확인한다.
- S3 Gateway Endpoint가 두 Private route table에 연결되었는지 확인한다.
- ECS Cluster에 운영 기본 Fargate Capacity Provider만 연결되었는지 확인한다.
- ECR immutable, scanning, encryption, lifecycle 설정을 확인한다.
- ALB가 두 Public subnet에 연결되었는지 확인한다.
- ALB HTTP 요청이 고정 404 응답을 반환하는지 확인한다.
- CloudWatch Log Group 보존 기간이 30일인지 확인한다.

## 19. CI/CD 고려사항

기존 GitHub Actions workflow는 저장소 루트에서 Terraform 명령을 실행한다. v1 코드가 `v1/`으로 이동했기 때문에 현재 workflow는 working directory를 지정하지 않으면 실패한다.

이번 단계에서는 기존 v1 workflow가 `v1/`에서 실행되도록 최소 수정한다. v2 자동 plan/apply workflow는 애플리케이션 배포 CI/CD 단계에서 별도로 설계한다. v2를 자동 적용하기 전에는 `KTB4-9th-Cloud-v2-prod` workspace에서 plan을 검토하고 수동 승인 후 apply한다.

## 20. 후속 단계

공통 기반 구축 후 다음 순서로 확장한다.

1. Spring Boot, FastAPI, Judge API Task Definition과 ECS Service
2. 서비스별 Security Group과 ALB Target Group/routing
3. ACM, HTTPS listener, Route 53 연결
4. RDS MySQL/PostgreSQL과 ElastiCache Valkey
5. Judge Worker용 ECS on EC2 Capacity Provider
6. 애플리케이션 및 인프라 CI/CD
7. 부하 테스트 후 ECS 및 EC2 Auto Scaling 정책
