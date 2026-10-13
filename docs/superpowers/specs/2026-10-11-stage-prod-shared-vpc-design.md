# COSMOS v2 Shared VPC 기반 Stage·Prod 환경 분리 설계

## 1. 목표

현재 단일 `prod` 중심의 `v2` Terraform을 공통 네트워크와 환경별 런타임으로 분리한다. 하나의 VPC와 NAT Gateway를 공유하면서 `stage`와 `prod`가 독립된 Terraform Cloud state, 애플리케이션, 데이터 계층, IAM, 로그와 배포 수명주기를 갖게 한다.

`stage`는 애플리케이션 마이그레이션 검증 및 이후 상시 staging 환경으로 사용한다. 현재 데이터베이스에 이전할 데이터가 없으므로 snapshot 복원, 데이터 복제, 정합성 검증은 이번 범위에서 제외한다.

## 2. 성공 조건

- AWS 리전은 계속 서울 `ap-northeast-2`를 사용한다.
- VPC, subnet, Internet Gateway, NAT Gateway, route, S3 Gateway Endpoint는 한 벌만 존재한다.
- ECR repository는 환경 간 공유하고 환경별 image repository를 중복 생성하지 않는다.
- 각 환경은 private S3 frontend bucket, CloudFront distribution과 ALB를 별도로 가진다.
- stage의 유일한 외부 주소는 `https://stage.cosmoscode.site`이고 API도 같은 origin의 `/api/*`, `/auth/*`로 제공한다.
- `stage`와 `prod`는 서로 다른 Terraform Cloud Workspace와 state를 사용한다.
- `stage` 변경 plan이 `prod` 런타임 리소스를 변경할 수 없다.
- `stage`와 `prod`의 ECS, ALB, RDS, Valkey, Judge 상태 저장 계층과 Worker는 같은 topology를 사용한다.
- 환경별 리소스 이름, Service Connect namespace, Secret 경로와 Log Group이 충돌하지 않는다.
- stage에서 검증한 동일 ECR digest를 prod로 승격할 수 있다.
- 기존 1·2차 Terraform과 Worker 계약 테스트가 환경 module 재구성 후에도 유지된다.
- 실제 Terraform Cloud/AWS plan 및 apply는 소스 구현과 분리하고 별도 승인 후 수행한다.

## 3. 범위

### 3.1 포함

- 공통 Shared VPC root module과 Workspace
- `stage`, `prod` 환경별 root module과 Workspace
- 재사용 가능한 shared/environment Terraform module
- 환경별 변수와 output
- 환경별 S3·CloudFront·Route 53 alias와 CloudFront 전용 ALB 접근 경계
- 환경 격리 및 topology 동등성 Terraform 테스트
- stage 운영 및 애플리케이션 마이그레이션 전략 문서
- 기존 preflight의 환경별 실행 방식

### 3.2 제외

- 운영 데이터 snapshot, 복제, 마스킹 및 이전
- prod apex와 `www` DNS의 실제 v2 전환
- 실제 AWS plan/apply와 smoke test
- CI/CD pipeline 구현
- Queue 지표 기반 Worker Auto Scaling
- CloudWatch Dashboard와 운영 alarm 구현
- v1 인프라 제거

## 4. 선택한 구조

세 개의 Terraform Cloud Workspace를 사용한다.

```text
KTB4-9th-Cloud-v2-shared
  └─ VPC, subnet, NAT, route, endpoint, ECR

KTB4-9th-Cloud-v2-stage
  └─ stage S3, CloudFront, ALB, ECS, RDS, Valkey, Judge EC2/EBS, Worker

KTB4-9th-Cloud-v2-prod
  └─ prod S3, CloudFront, ALB, ECS, RDS, Valkey, Judge EC2/EBS, Worker
```

HCP Terraform Workspace는 다음 working directory를 사용한다.

| Workspace | Working directory |
| --- | --- |
| `KTB4-9th-Cloud-v2-shared` | `v2/environments/shared` |
| `KTB4-9th-Cloud-v2-stage` | `v2/environments/stage` |
| `KTB4-9th-Cloud-v2-prod` | `v2/environments/prod` |

적용 순서는 `shared → stage → prod`다. 환경 Workspace는 shared Workspace가 성공적으로 적용된 뒤에만 실행한다.

## 5. Terraform 디렉터리 구조

```text
v2/
├─ modules/
│  ├─ shared/
│  │  ├─ network.tf
│  │  ├─ ecr.tf
│  │  ├─ variables.tf
│  │  └─ outputs.tf
│  └─ environment/
│     ├─ alb.tf
│     ├─ frontend.tf
│     ├─ application-iam.tf
│     ├─ application-security.tf
│     ├─ backups.tf
│     ├─ data-subnets.tf
│     ├─ ecs-container-instances.tf
│     ├─ ecs-services.tf
│     ├─ ecs-task-definitions.tf
│     ├─ ecs.tf
│     ├─ judge-stateful-services.tf
│     ├─ judge-worker.tf
│     ├─ logging.tf
│     ├─ rds.tf
│     ├─ route53.tf
│     ├─ secrets.tf
│     ├─ service-connect.tf
│     ├─ valkey.tf
│     ├─ worker-capacity.tf
│     ├─ variables.tf
│     └─ outputs.tf
├─ environments/
│  ├─ shared/
│  │  ├─ versions.tf
│  │  ├─ providers.tf
│  │  ├─ main.tf
│  │  └─ outputs.tf
│  ├─ stage/
│  │  ├─ versions.tf
│  │  ├─ providers.tf
│  │  ├─ main.tf
│  │  └─ outputs.tf
│  └─ prod/
│     ├─ versions.tf
│     ├─ providers.tf
│     ├─ main.tf
│     └─ outputs.tf
├─ scripts/
├─ tests/
└─ *.md
```

module은 리소스 책임을 분리하고, root module은 Workspace 연결과 환경별 값만 결정한다. `stage`와 `prod` root는 동일한 `modules/environment`를 호출해야 하며 환경별로 Terraform resource 파일을 복사하지 않는다.

## 6. Shared 계층

Shared Workspace는 다음 리소스를 단독 소유한다.

- VPC `10.20.0.0/16`
- Public subnet 2개: `10.20.0.0/24`, `10.20.1.0/24`
- Private subnet 2개: `10.20.10.0/24`, `10.20.11.0/24`
- Data subnet 2개: `10.20.20.0/24`, `10.20.21.0/24`
- Internet Gateway
- NAT Gateway 1개와 Elastic IP 1개
- Public/Private/Data route table과 association
- S3 Gateway VPC Endpoint
- Spring, FastAPI, Judge 공용 ECR repository 3개

Shared output은 다음 비민감 식별자만 제공한다.

- VPC ID
- Public/Private/Data subnet ID map
- ECR repository URL/ARN map
- 기존 `cosmoscode.site` Hosted Zone ID
- 기존 CloudFront용 `us-east-1` ACM wildcard 인증서 ARN
- NAT Gateway ID
- S3 Endpoint ID

Secret 값, DB 자격 증명, image tag 또는 digest는 shared state에 저장하지 않는다. 기존 Hosted Zone과 인증서는 v1에서 이미 생성되었으므로 초기 stage 구축에서는 data source로 조회하며 중복 생성하지 않는다. v1 종료 전 DNS 기반 리소스의 장기 소유권은 별도 state 이전 plan으로 shared Workspace에 이관한다.

Shared root는 서울 리전 기본 AWS provider와 `us-east-1` alias provider를 함께 선언한다. Hosted Zone은 Route 53 data source로, CloudFront 인증서는 `us-east-1` ACM data source로 조회한다.

## 7. 환경 계층

`modules/environment`는 입력받은 shared VPC/subnet/ECR 식별자에 환경별 리소스를 생성한다.

각 환경이 독립 소유하는 항목은 다음과 같다.

- ECS Cluster 및 Cluster Capacity Provider 연결
- Service Connect namespace
- Public ALB, listener, target group
- private S3 frontend bucket, Public Access Block, CloudFront OAC와 bucket policy
- 환경별 CloudFront distribution과 frontend Route 53 alias
- 애플리케이션 및 데이터 Security Group
- 환경별 execution/task/instance IAM role
- Secrets Manager Secret metadata
- CloudWatch Log Group
- RDS MySQL
- Backend Valkey
- Judge PostgreSQL/Redis EC2와 보존 EBS
- 상태 저장 ECS Task/Service
- Spring, FastAPI, Judge API Fargate Task/Service
- Judge Worker Launch Template
- Worker On-Demand/Spot ASG와 Capacity Provider
- Judge Worker Task/Service
- DLM snapshot policy

stage와 prod 모두 초기 topology는 동일하다.

| 구성 | stage | prod |
| --- | --- | --- |
| Spring Fargate | 기본 1 Task | 기본 1 Task |
| FastAPI Fargate | 기본 1 Task | 기본 1 Task |
| Judge API Fargate | 기본 1 Task | 기본 1 Task |
| RDS MySQL | 별도 인스턴스 | 별도 인스턴스 |
| Backend Valkey | 별도 캐시 | 별도 캐시 |
| Judge PostgreSQL EC2/EBS | 1대 | 1대 |
| Judge Redis EC2/EBS | 1대 | 1대 |
| Worker On-Demand | 1대 | 1대 |
| Worker Spot | 0~7대 | 0~7대 |
| Frontend S3 | 별도 private bucket | 별도 private bucket |
| CloudFront | 별도 distribution | 별도 distribution |
| Public ALB | CloudFront origin | CloudFront origin |

실제 Task/Service와 Worker capacity는 기존 enable flag로 단계적으로 활성화한다. topology 동등성은 같은 module과 같은 기본값으로 보장하고, image digest와 enable 상태만 환경별로 다를 수 있다.

## 8. 명명 및 격리 규칙

모든 환경별 이름은 `${project_name}-${environment}`를 접두사로 사용한다.

```text
cosmos-v2-stage-cluster
cosmos-v2-prod-cluster

cosmos-v2-stage-alb
cosmos-v2-prod-alb

stage.cosmos-v2.local
prod.cosmos-v2.local
```

Secret과 Log Group은 환경명을 포함한다.

```text
/cosmos-v2/stage/spring
/cosmos-v2/prod/spring

/cosmos-v2/stage/judge-worker
/cosmos-v2/prod/judge-worker

/ecs/cosmos-v2-stage/spring
/ecs/cosmos-v2-prod/spring
```

Valkey user/user group, IAM role, DLM policy, Launch Template, ASG와 Capacity Provider에도 환경명을 포함한다. 하드코딩된 `prod` 문자열은 운영 문서의 예시를 제외하고 module resource에서 허용하지 않는다.

stage와 prod는 subnet을 공유하지만 Security Group source 참조를 환경 내부 리소스로만 연결한다. stage SG를 prod DB/캐시에 참조하거나 그 반대로 참조하지 않는다.

## 9. 프론트엔드와 외부 진입 구조

stage의 외부 공개 주소는 하나만 사용한다.

```text
https://stage.cosmoscode.site
```

요청 흐름은 다음과 같다.

```text
사용자
  → Stage CloudFront
      ├─ /*       → Stage private S3 frontend bucket
      ├─ /api/*   → Stage ALB → Spring ECS Service
      └─ /auth/*  → Stage ALB → Spring ECS Service
```

FastAPI, Judge API, RDS, Valkey, Judge PostgreSQL/Redis와 Worker의 외부 DNS는 생성하지 않는다. 내부 서비스는 `stage.cosmos-v2.local` Service Connect namespace만 사용한다.

환경별 frontend 구성은 다음 계약을 따른다.

- S3 Block Public Access 전체 활성화
- bucket 이름은 `${project_name}-${environment}-frontend-${aws_account_id}` 형식으로 환경과 계정을 포함
- S3 website endpoint를 사용하지 않고 regional REST endpoint 사용
- CloudFront Origin Access Control과 SigV4 사용
- bucket policy는 자신의 CloudFront distribution ARN에만 `s3:GetObject` 허용
- 기본 root object는 `index.html`
- S3 기본 behavior에만 CloudFront Function을 연결해 확장자 없는 frontend route를 `/index.html`로 rewrite
- `/api/*`, `/auth/*` behavior에는 SPA rewrite를 연결하지 않아 backend의 403/404 상태를 그대로 보존
- 기본 `/*`는 S3 origin
- `/api/*`, `/auth/*`는 환경별 ALB origin
- API behavior는 모든 HTTP method를 허용하고 caching을 비활성화
- API behavior는 query string, cookie와 인증 헤더를 Spring origin에 전달
- viewer는 HTTP를 HTTPS로 redirect
- stage alias는 `stage.cosmoscode.site`
- prod alias는 cutover 전에는 생성하지 않고 `enable_public_dns_cutover=true`일 때 apex와 `www`를 v2 CloudFront로 연결

CloudFront viewer 인증서는 기존 `us-east-1` 인증서에서 조회한다. 해당 인증서는 `cosmoscode.site`와 `*.cosmoscode.site`를 포함해야 하며 조건을 만족하지 않으면 plan을 거부한다.

ALB는 Nginx를 대체해 Spring Target Group의 health check와 요청 분산을 담당한다. CloudFront custom origin 연결을 위해 ALB는 internet-facing을 유지하지만, ALB Security Group의 HTTP ingress source는 AWS 관리형 `com.amazonaws.global.cloudfront.origin-facing` prefix list로 제한한다. 별도의 `stage-api.cosmoscode.site` 레코드는 만들지 않는다. ALB DNS로 직접 접근하는 일반 인터넷 요청은 Security Group에서 차단한다.

정적 asset은 content hash 파일을 전제로 장기 캐시하고 `index.html`은 짧은 캐시 또는 no-cache를 사용한다. frontend 배포 도구가 S3 upload와 CloudFront invalidation을 수행하는 것은 CI/CD 범위이며 이번 Terraform은 저장소와 배포 경계만 생성한다.

## 10. ECR 및 image 승격

ECR은 환경과 무관한 배포 artifact이므로 Shared Workspace에서 한 번만 생성한다.

```text
cosmos-v2/spring
cosmos-v2/fastapi
cosmos-v2/judge
```

stage와 prod는 repository URL은 공유하지만 별도의 Task Definition을 가진다. Judge API와 Worker는 같은 Judge digest를 사용하고 실행 command만 분리한다. PostgreSQL·Valkey는 별도 ECR 없이 공식 image 전체 reference를 `@sha256:`으로 고정한다. stage에서 검증한 digest를 변경 없이 prod 변수에 지정하며 prod 승격 과정에서 image를 다시 build하거나 `latest` tag를 사용하지 않는다.

## 11. Shared output 소비 방식

환경 root는 Shared Workspace의 명시적 output만 소비한다. 구현에서는 HCP Terraform의 Workspace 간 output 공유 권한을 제한하고, stage/prod Workspace가 `KTB4-9th-Cloud-v2-shared` output을 읽도록 구성한다.

소비 인터페이스는 다음 값으로 고정한다.

- `vpc_id`
- `public_subnet_ids`
- `private_subnet_ids`
- `data_subnet_ids`
- `ecr_repository_urls`
- `ecr_repository_arns`
- `route53_zone_id`
- `cloudfront_certificate_arn`

환경 module은 shared resource 자체를 참조하지 않고 위 값만 입력받는다. Shared output이 준비되지 않았거나 subnet map이 정확히 두 AZ를 제공하지 않으면 plan을 거부한다.

## 12. Terraform state 및 기존 구조 전환

현재 문서화된 상태로는 v2 실제 apply가 수행되지 않았다. 구현 전 실제 Terraform Cloud state를 조회해 다음과 같이 처리한다.

- 세 Workspace가 비어 있으면 새 module/root 구조로 바로 시작한다.
- 기존 `KTB4-9th-Cloud-v2-prod` state에 리소스가 있으면 module refactor를 즉시 적용하지 않는다.
- 기존 state가 있으면 resource별 `moved` block 또는 `terraform state mv` 계획을 별도 작성하고, destroy/recreate가 없는 저장 plan을 검토한 뒤 전환한다.
- 기존 Route 53 Hosted Zone과 ACM 인증서는 초기 stage 구축에서 data source로 조회하고 새로 만들지 않는다.
- v1 제거 전 Hosted Zone/인증서 소유권 이전이 필요하면 별도의 import/remove plan으로 shared state에 이관하고 destroy 없는 plan을 확인한다.
- v1 resource 주소가 v2 Workspace에서 발견되면 작업을 중단한다.

어떠한 경우에도 기존 RDS, EBS, EC2를 import 확인 없이 삭제하거나 교체하지 않는다.

## 13. Stage 구축 순서

1. Shared Workspace를 초기화하고 state가 비어 있거나 예상 주소만 포함하는지 확인한다.
2. Shared plan에서 VPC, subnet, NAT, endpoint, ECR만 생성되는지 확인한다.
3. Shared를 적용하고 output 공유 권한을 stage Workspace에 부여한다.
4. Stage Workspace를 capacity/service 비활성 상태로 plan한다.
5. Stage S3, CloudFront, ALB, RDS, Valkey, Judge 상태 저장 기반, Secret metadata, IAM, SG, 로그를 적용한다.
6. `stage.cosmoscode.site`가 Stage CloudFront를 가리키는지 확인한다.
7. 실제 Secret version을 AWS Secrets Manager에 등록한다.
8. DB schema migration을 빈 stage DB에 적용한다.
9. frontend 정적 파일을 Stage S3에 배포하고 CloudFront 동작을 확인한다.
10. ECR image digest와 애플리케이션 계약을 확인한다.
11. stage Fargate 서비스와 Worker capacity를 활성화한다.
12. Worker On-Demand container instance가 ACTIVE인 뒤 Worker Service를 활성화한다.
13. `stage.cosmoscode.site`, `/api/*`, `/auth/*`와 내부 서비스 smoke test를 수행한다.

## 14. 애플리케이션 마이그레이션 전략

### 14.1 준비

- `be`, `ai`, `judge` repository에서 배포 후보 image를 각각 build한다.
- frontend repository에서 정적 build artifact를 생성한다.
- image를 공통 ECR에 push하고 digest를 고정한다.
- stage/prod가 사용하는 환경 변수와 Secret JSON key 계약을 비교한다.
- DB schema migration revision을 image release와 함께 기록한다.

### 14.2 Stage 검증

1. 빈 RDS MySQL 및 Judge PostgreSQL에 schema migration을 적용한다.
2. Spring, FastAPI, Judge API를 stage 전용 Secret과 endpoint로 배포한다.
3. frontend artifact를 stage S3에 올리고 CloudFront cache behavior와 SPA fallback을 확인한다.
4. 외부에서는 `stage.cosmoscode.site`만 호출한다.
5. `/api/*`, `/auth/*`가 CloudFront → ALB → Spring으로 전달되는지 확인한다.
6. Spring API → FastAPI/Judge API 경로를 확인한다.
7. FastAPI → Judge API 경로를 확인한다.
8. Judge API → Judge PostgreSQL/Redis 경로를 확인한다.
9. Queue → Judge Worker → PostgreSQL/Redis 처리 흐름을 확인한다.
10. ALB DNS 직접 접근이 차단되는지 확인한다.
11. 실패 요청, 잘못된 Secret, health check 실패와 ECS rollback을 확인한다.
12. Worker desired count를 2로 올려 Spot 기동을 확인하고 다시 1로 복원한다.

### 14.3 Prod 승격

- stage에서 검증된 동일 image digest와 schema migration revision만 prod 후보로 사용한다.
- prod Secret version과 preflight를 확인한다.
- prod 데이터 계층을 빈 상태로 준비하고 동일 schema migration을 적용한다.
- prod 애플리케이션을 외부 트래픽 없이 먼저 기동해 내부 health를 확인한다.
- prod frontend artifact를 prod S3에 배포하고 CloudFront 기본 도메인으로 검증한다.
- `enable_public_dns_cutover=true`의 저장 plan을 검토한 뒤 apex와 `www`를 v1 CloudFront에서 v2 prod CloudFront로 전환한다.
- 전환 직후 API 오류율, 응답시간, ECS running/pending, Queue backlog와 Worker 처리 결과를 확인한다.

### 14.4 Rollback

- 트래픽 이상 시 Route 53 alias를 v1 CloudFront로 되돌린다.
- ECS 새 revision 문제는 deployment circuit breaker 또는 직전 정상 digest 재지정으로 복구한다.
- prod 승격 과정에서 image를 재build하지 않는다.
- 현재 데이터가 없으므로 schema migration은 destructive rollback보다 forward-fix를 원칙으로 한다.
- v1은 안정화 관찰 기간과 별도 제거 승인 전까지 유지한다.

Terraform은 prod DNS cutover resource와 보호 flag까지 구현하지만 실제 flag 활성화와 apply는 이번 범위에서 수행하지 않는다.

## 15. Preflight와 오류 처리

preflight는 실행 대상 환경을 명시적으로 받는다. 환경별로 다음을 확인한다.

- 예상 Terraform Cloud Workspace와 state 조회 성공
- v1 또는 다른 환경의 resource 주소가 현재 state에 없음
- 필요한 ECR digest 존재
- 대상 환경 Secret의 `AWSCURRENT` 존재
- application/Worker 계약 확인 변수
- Worker capacity 활성 시 container instance와 Capacity Provider가 ACTIVE
- frontend alias, S3 bucket, CloudFront distribution과 ALB origin 상태
- ALB Security Group이 CloudFront prefix list 외 ingress를 허용하지 않음

stage preflight가 prod Secret ARN이나 prod Cluster를 받으면 실패해야 한다. preflight는 Secret 값을 읽거나 출력하지 않고 `terraform apply`를 호출하지 않는다.

## 16. 테스트 전략

### 16.1 Shared module 계약

- VPC와 subnet은 한 벌만 생성한다.
- NAT Gateway는 한 개다.
- ECR repository는 환경명 없이 한 벌만 생성한다.
- Shared output map은 정확한 두 AZ의 subnet을 제공한다.

### 16.2 Environment module 계약

- `environment`는 `stage` 또는 `prod`만 허용한다.
- stage/prod 모두 같은 리소스 topology와 기본 용량을 사용한다.
- 이름, Secret, namespace, Log Group은 환경명을 포함한다.
- 각 SG rule은 같은 환경의 SG만 source로 사용한다.
- ECR은 입력값을 사용하고 environment module에서 생성하지 않는다.
- Worker capacity/service enable 계약과 digest validation을 유지한다.
- 환경별 private S3 bucket과 CloudFront distribution을 생성한다.
- stage alias는 `stage.cosmoscode.site` 하나뿐이며 stage API 전용 public record는 없다.
- CloudFront 기본 origin은 S3, `/api/*`와 `/auth/*` origin은 같은 환경 ALB다.
- ALB ingress source는 CloudFront origin-facing managed prefix list뿐이다.
- prod DNS record는 `enable_public_dns_cutover=false`일 때 생성되지 않는다.

### 16.3 Root 및 Workspace 계약

- shared/stage/prod root가 정확한 Workspace 이름을 사용한다.
- stage와 prod는 동일 environment module을 호출한다.
- stage plan에 prod module 또는 prod resource 주소가 없다.
- prod plan에 stage module 또는 stage resource 주소가 없다.
- environment root는 Shared output이 없거나 불완전하면 실패한다.

### 16.4 회귀 검증

- `terraform fmt -check -recursive`
- shared/stage/prod root `terraform validate`
- 모든 Terraform native test
- preflight shell fixture
- Secret version/value resource 금지 정적 검사
- 환경 module의 하드코딩된 `prod` 경로 금지 검사
- `git diff --check`

## 17. 운영 및 비용 고려

VPC와 NAT Gateway는 공유하므로 네트워크 고정비는 한 벌만 발생한다. 반면 stage는 prod와 같은 topology를 유지하므로 RDS, Valkey, 상태 저장 EC2 두 대, Worker On-Demand EC2 한 대, S3, CloudFront, ALB와 로그 비용이 추가된다.

동일 topology는 동일 instance class를 반드시 의미하지 않는다. 그러나 이번 요구에서는 migration parity를 우선하므로 초기 stage 기본값은 prod와 동일하게 둔다. 비용 절감이 필요하면 topology와 계약을 유지한 채 환경별 size override를 후속 설계로 추가한다.

## 18. 보안 경계

- stage와 prod는 같은 VPC를 사용하지만 SG 참조로 상호 통신을 허용하지 않는다.
- 사용자의 외부 공개 주소는 각 환경 CloudFront만 사용한다.
- ALB는 CloudFront origin-facing prefix list에서 오는 요청만 허용한다.
- frontend S3 bucket은 public access를 차단하고 자신의 CloudFront OAC만 허용한다.
- FastAPI, Judge API, RDS, Valkey, Judge 상태 저장 서비스와 Worker는 직접 공개하지 않는다.
- Secret ARN과 IAM role은 환경별로 분리한다.
- stage execution role이 prod Secret을 읽을 수 없고 prod role도 stage Secret을 읽을 수 없다.
- Worker Task는 해당 환경 PostgreSQL, Redis, VPC DNS만 egress한다.

## 19. 실제 배포 경계

이번 구현은 Terraform 구조, 테스트, preflight와 문서까지 작성한다. 다음 작업은 별도 승인과 인증 정보가 있을 때만 수행한다.

- Terraform Cloud Workspace 생성 및 output sharing 설정
- 실제 state 조회 및 state 이동
- AWS plan/apply
- Secret version 등록
- schema migration 실행
- 애플리케이션/Worker smoke test
- v1 → v2 트래픽 전환
- frontend artifact upload와 CloudFront invalidation

소스 구현 완료와 실제 환경 구축 완료를 구분해서 보고한다.
