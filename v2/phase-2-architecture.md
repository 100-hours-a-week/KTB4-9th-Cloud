# COSMOS v2 2차 애플리케이션·데이터 계층 아키텍처

> 최신 환경 분리와 배포 흐름은 [Stage/Prod 공용 VPC 설계](../docs/superpowers/specs/2026-10-11-stage-prod-shared-vpc-design.md), [AI PostgreSQL 및 ECS 런타임 계약](../docs/superpowers/specs/2026-10-12-ai-pgvector-runtime-contract-design.md), [애플리케이션 마이그레이션 전략](application-migration.md)을 기준으로 한다. 아래의 과거 Valkey 연동 설명과 충돌하면 최신 런타임 계약을 우선한다.

## 1. 문서 목적

이 문서는 1차에서 구축한 COSMOS v2 ECS 공통 기반 위에 실제 애플리케이션과 데이터 계층을 배포하기 위한 2차 설계를 정의한다.

2차의 핵심 목표는 다음과 같다.

- Spring Boot, FastAPI, Judge API를 ECS Fargate Service로 실행한다.
- Spring Boot만 인터넷에 공개하고 나머지 서비스는 VPC 내부에서만 호출한다.
- ECS Service Connect로 서비스 간 주소와 Task 교체를 추상화한다.
- Spring Boot는 관리형 RDS MySQL의 `cosmos` 데이터베이스를 사용한다.
- Backend Valkey는 인프라만 유지하고 현재 Spring Task와 연결하지 않는다.
- FastAPI용 PostgreSQL 17+pgvector는 전용 ECS on EC2 인스턴스와 암호화 EBS에서 실행한다.
- Judge용 PostgreSQL과 Redis Queue는 각각 전용 ECS on EC2 인스턴스에서 직접 운영한다.
- 실제 비밀값을 Terraform 코드와 state에 저장하지 않는다.
- 운영 초기에는 각 서비스를 한 개씩만 실행하고 용량 및 Auto Scaling은 부하 테스트 이후 결정한다.

## 2. 전제 조건

2차 구성은 다음 1차 리소스를 사용한다.

- 서울 리전 `ap-northeast-2`
- VPC `10.20.0.0/16`
- Public subnet 2개
- Private subnet 2개
- NAT Gateway 1개
- 인터넷-facing Application Load Balancer
- ECS Cluster `cosmos-v2-prod-cluster`
- ECR repository `spring`, `fastapi`, `judge`
- 서비스별 CloudWatch Log Group
- 공통 ECS task execution role

실제 plan 또는 apply 전에는 Terraform Cloud workspace `cosmoscode/KTB4-9th-Cloud-v2-prod`의 state가 비어 있거나 v2 리소스만 포함하는지 확인해야 한다. v1 리소스가 나타나면 즉시 중단한다.

## 3. 범위

### 3.1 포함 범위

- Spring Boot ECS Fargate Task Definition 및 Service
- FastAPI ECS Fargate Task Definition 및 Service
- Judge API ECS Fargate Task Definition 및 Service
- ECS Service Connect와 Cloud Map namespace
- Spring Boot용 ALB Target Group 및 listener 연결
- 서비스별 Security Group
- 서비스별 task role 및 execution role
- 서비스별 Secrets Manager secret 컨테이너
- Data subnet 2개와 격리된 route table
- Amazon RDS MySQL
- ElastiCache Valkey Serverless
- Judge PostgreSQL 전용 ECS on EC2 인스턴스 1대
- Judge Redis 전용 ECS on EC2 인스턴스 1대
- Judge PostgreSQL 및 Redis Task Definition과 ECS Service
- AI PostgreSQL 17+pgvector 전용 ECS on EC2 인스턴스, EBS, Task Definition과 Service
- 상태 저장 서비스용 독립 EBS
- EBS snapshot 수명주기
- digest로 고정한 PostgreSQL·Valkey 공식 OCI image
- 배포 전 조건 및 Terraform native test
- 장애 및 복구 절차 문서화

### 3.2 제외 범위

- Judge Worker
- ECS Auto Scaling과 EC2 Auto Scaling
- Spot Instance
- ACM 인증서
- HTTPS listener
- Route 53 전환
- 다중 AZ RDS
- Judge PostgreSQL 및 Redis의 자동 장애조치
- 애플리케이션 빌드·배포 CI/CD
- Prometheus, Grafana 등 별도 관측성 스택
- v1에서 v2로의 실제 트래픽 전환

## 4. 관리형 서비스 사용 원칙

운영 데이터를 저장하는 관리형 서비스는 다음 두 종류만 사용한다.

- Spring Boot 데이터베이스: Amazon RDS MySQL
- Spring Boot 캐시 기반: ElastiCache Valkey Serverless. 애플리케이션 연동은 후속 범위다.

AI 데이터베이스는 관리형 서비스가 아니라 `ai-postgres:5432` Service Connect alias를 제공하는 PostgreSQL 17+pgvector ECS Service다. FastAPI는 `DB_HOST=ai-postgres`, `DB_NAME=cosmos`를 사용하고 AI PostgreSQL Secret의 `username`, `password`를 각각 `DB_USER`, `DB_PASSWORD`로 주입받는다. 외부 DNS, public IP, ALB Target Group은 생성하지 않는다.

Spring의 prod profile은 RDS 접속 정보를 `DB_URL`, `DB_USERNAME`, `DB_PASSWORD`로 읽는다. Terraform은 RDS endpoint로 `DB_URL`을 구성하고 Spring Secret의 `db_username`, `db_password` key를 나머지 두 환경 변수로 개별 주입한다.

AI 및 Judge PostgreSQL은 ext4 볼륨 루트의 `lost+found`와 충돌하지 않도록 `PGDATA=/var/lib/postgresql/data/pgdata`를 사용한다. PostgreSQL 소켓과 초기화 파일을 쓸 수 있도록 상태 저장 컨테이너에는 읽기 전용 root filesystem을 적용하지 않는다. 외부 노출 차단, 전용 Security Group, 암호화 EBS와 최소 IAM 권한으로 이를 보완한다.

Spring은 `spring:8080`, FastAPI는 `fastapi:8000`, Judge API는 `judge-api:2358` Service Connect server로 등록한다. Spring ALB health path는 prod context path를 반영한 `/api/actuator/health`다.

Judge PostgreSQL과 Judge Redis Queue는 외부 또는 AWS 관리형 데이터베이스 서비스를 사용하지 않고 ECS on EC2에서 직접 운영한다.

Secrets Manager, CloudWatch Logs, ECS Service Connect, Cloud Map, ECR, Systems Manager는 데이터 저장소를 외부에 위임하기 위한 서비스가 아니라 보안·관측·배포·운영 제어를 위한 AWS 기반 서비스이므로 사용할 수 있다.

## 5. 전체 구조

```text
Internet
   `-- Stage HTTPS ALB --> Spring:8080 / FastAPI:8000 / Judge API:2358

Spring Boot - Fargate 1 Task
   |-- Service Connect --> FastAPI:8000
   |-- Service Connect --> Judge API:2358
   `-- TCP 3306 ---------> RDS MySQL (cosmos)

FastAPI - Fargate 1 Task
   |-- Service Connect --> Spring:8080/api
   |-- Service Connect --> Judge API:2358
   `-- Service Connect --> ai-postgres:5432

ai-postgres
   `-- PostgreSQL 17+pgvector / ECS on EC2 1대 + 암호화 EBS

Judge API - Fargate 1 Task
   |-- Service Connect --> judge-postgres:5432
   `-- Service Connect --> judge-redis:6379

judge-postgres
   `-- ECS on EC2 1대 + 암호화 EBS

judge-redis
   `-- ECS on EC2 1대 + 암호화 EBS
```

Stage는 Swagger 검증을 위해 세 서비스를 HTTPS ALB host routing으로 임시 공개한다. Prod는 Spring만 ALB에 연결하고 FastAPI와 Judge API는 내부 전용이다. 모든 ECS Task는 public IP를 할당하지 않는다.

## 6. Subnet 설계

1차에서 예약한 CIDR로 Data subnet을 생성한다.

| 용도 | 가용 영역 | CIDR |
| --- | --- | --- |
| Data subnet A | ap-northeast-2a | `10.20.20.0/24` |
| Data subnet C | ap-northeast-2c | `10.20.21.0/24` |

Data subnet에는 인터넷 기본 경로를 만들지 않는다. RDS DB subnet group과 Valkey subnet 설정에 두 Data subnet을 사용한다.

Fargate와 AI PostgreSQL·Judge PostgreSQL·Redis EC2는 기존 Private subnet에 배치한다. ECS agent, ECR image pull, CloudWatch Logs, Systems Manager 및 외부 API 호출은 1차에서 만든 단일 NAT Gateway를 사용한다.

Judge PostgreSQL EC2와 Judge Redis EC2는 장애 영역을 분리하기 위해 서로 다른 가용 영역에 배치한다. 단, 각 서비스는 한 대뿐이므로 개별 서비스의 가용성을 보장하는 Multi-AZ 구성은 아니다.

## 7. ECS Service Connect

- Namespace: `prod.cosmos-v2.local` HTTP namespace
- Spring Boot: Service Connect client/server
- FastAPI: Service Connect client/server
- Judge API: Service Connect client/server
- AI PostgreSQL: Service Connect server
- Judge PostgreSQL: Service Connect server
- Judge Redis: Service Connect server

내부 endpoint는 다음과 같다.

| 서비스 | Endpoint |
| --- | --- |
| Spring Boot | `http://spring:8080/api` |
| FastAPI | `http://fastapi:8000` |
| Judge API | `http://judge-api:2358` |
| AI PostgreSQL | `ai-postgres:5432` |
| Judge PostgreSQL | `judge-postgres:5432` |
| Judge Redis | `judge-redis:6379` |

모든 server Task Definition의 port mapping에는 고유한 `name`을 지정한다. HTTP 서비스에만 `appProtocol = "http"`를 지정한다. PostgreSQL과 Redis는 `appProtocol`을 생략하고 TCP 연결로 사용한다.

Service Connect initial health 판단을 위해 모든 essential container에 container health check를 정의한다.

## 8. Fargate 서비스

### 8.1 공통 설정

- Launch type: Fargate
- Network mode: `awsvpc`
- Platform: Linux X86_64 기본값
- Private subnet 2개 사용
- `assign_public_ip = false`
- `desired_count = 1`
- Capacity Provider: `FARGATE`
- 배포 최소 정상 비율: 100%
- 배포 최대 비율: 200%
- Deployment circuit breaker 및 rollback 활성화
- ECS Exec 활성화
- 읽기 전용 root filesystem 활성화
- `/tmp`에는 Task 수명 동안만 유지되는 writable volume mount 제공
- 기본 ephemeral storage: 20GiB
- ECR image digest로 image 고정
- CloudWatch `awslogs` 사용

Fargate Spot과 Auto Scaling은 생성하지 않는다. 이후 안정성 및 부하 테스트 결과에 따라 별도 단계에서 추가한다.

### 8.2 Spring Boot

- Container port: 8080
- CPU: 1024
- Memory: 2048MiB
- Health endpoint: `/actuator/health`
- Public ALB Target Group에 유일하게 등록
- FastAPI와 Judge API의 Service Connect client
- RDS MySQL과 Backend Valkey 접근

### 8.3 FastAPI

- Container port: 8000
- CPU: 512
- Memory: 1024MiB
- Health endpoint: `/health`
- Spring Boot의 호출만 Security Group으로 허용
- Judge API의 Service Connect client
- 외부 Target Group 없음

### 8.4 Judge API

- Container port: 3000
- CPU: 512
- Memory: 1024MiB
- Health endpoint: `/health`
- Spring Boot와 FastAPI의 호출만 Security Group으로 허용
- Judge PostgreSQL과 Judge Redis의 Service Connect client
- 외부 Target Group 없음

CPU와 Memory는 변수를 통해 변경할 수 있어야 한다. 위 수치는 초기 배포 기본값이며 처리 용량 보장을 의미하지 않는다.

## 9. ALB와 Target Group

Spring Boot용 Target Group 하나만 생성한다.

- Target type: `ip`
- Protocol: HTTP
- Port: 8080
- Health check path: `/api/actuator/health`
- Healthy status matcher: `200`
- Deregistration delay: 30초
- Stickiness: 비활성화

기존 HTTP 80 listener의 기본 fixed `404` 동작은 유지한다. `enable_phase2_services=true`일 때만 우선순위 100의 `/*` listener rule을 추가해 Spring Target Group으로 forward한다. 따라서 서비스가 비활성인 bootstrap 단계에는 트래픽이 빈 Target Group으로 전달되지 않는다. FastAPI와 Judge API Target Group이나 listener rule은 만들지 않는다.

HTTPS 전환 단계에서는 HTTP listener를 HTTPS redirect로 변경하고 별도 HTTPS listener와 인증서를 추가한다.

## 10. Security Group

| 대상 | 허용 source | Protocol/port |
| --- | --- | --- |
| Stage ALB | `0.0.0.0/0` | TCP 443 |
| Spring Boot | ALB SG | TCP 8080 |
| Spring Boot | FastAPI SG | TCP 8080 |
| FastAPI | Spring SG | TCP 8000 |
| Judge API | Spring SG, FastAPI SG | TCP 2358 |
| RDS MySQL | Spring SG | TCP 3306 |
| AI PostgreSQL | FastAPI SG | TCP 5432 |
| Judge PostgreSQL | Judge API SG | TCP 5432 |
| Judge Redis | Judge API SG | TCP 6379 |

Security Group reference를 사용하고 애플리케이션 및 데이터 port에 VPC CIDR이나 `0.0.0.0/0`을 사용하지 않는다.

Judge PostgreSQL과 Redis EC2에는 SSH ingress를 만들지 않는다. 관리 접속은 Systems Manager Session Manager를 사용한다.

향후 Judge Worker를 추가할 때는 Judge PostgreSQL과 Redis Security Group에 Worker Security Group을 source로 추가한다.

## 11. RDS MySQL

- Engine: MySQL 8.0
- Instance class: `db.t4g.medium`
- 배치: Single-AZ
- Public access: 비활성화
- Storage: 암호화 gp3 30GiB
- Storage Auto Scaling 상한: 100GiB
- Backup retention: 7일
- deletion protection: 활성화
- 삭제 시 final snapshot 필수
- Data subnet 2개로 DB subnet group 구성
- Enhanced Monitoring과 Performance Insights는 초기 비용을 고려해 기본 비활성화
- CloudWatch error/general/slow query log export는 애플리케이션 안정화 후 활성화 여부 결정

RDS가 master password를 생성하고 Secrets Manager에서 관리하도록 한다. Terraform 변수, output, state에 master password를 저장하지 않는다.

Spring 애플리케이션은 장기적으로 master 계정이 아닌 전용 애플리케이션 계정을 사용해야 한다. 애플리케이션 계정과 schema 생성은 별도 일회성 migration/bootstrap 작업으로 수행한다.

## 12. Backend Valkey Serverless

- Engine: Valkey
- Deployment: Serverless
- VPC 내부 endpoint
- Data subnet 2개 사용
- 전송 중 암호화 적용
- 저장 데이터 암호화 적용
- Spring Security Group에서만 접근 허용
- Serverless snapshot 보존: 7일

Valkey IAM user/policy와 기존 Spring SG ingress는 no-destroy 원칙에 따라 보존하지만 Spring Task에는 endpoint/port를 주입하지 않는다. 따라서 애플리케이션 연동은 비활성 상태이며, SG 규칙 정리는 별도 변경으로 진행한다.

## 13. Judge PostgreSQL과 Redis ECS on EC2

### 13.1 공통 EC2 설정

- 인스턴스 수: 서비스별 1대
- 인스턴스 유형 기본값: `t3.small`
- AMI: 최신 ECS-optimized Amazon Linux 2023 X86_64
- AMI ID는 AWS 공개 SSM Parameter로 조회
- Private subnet 배치
- Public IP 없음
- IMDSv2 필수
- 암호화 root volume
- Systems Manager instance profile
- ECS container instance role
- SSH key pair 및 SSH ingress 없음

각 인스턴스에는 다음 ECS attribute를 설정한다.

```text
role=judge-postgres
role=judge-redis
```

각 ECS Service는 `memberOf` placement constraint를 사용해 지정된 instance에서만 실행된다.

### 13.2 EBS와 host mount

각 서비스는 Terraform이 별도로 생성한 암호화 gp3 EBS 30GiB를 사용한다.

- `delete_on_termination = false`
- Terraform `prevent_destroy` 적용
- PostgreSQL mount: `/data/postgresql`
- Redis mount: `/data/redis`
- 파일 시스템이 없을 때만 최초 포맷
- ECS agent는 EBS mount가 완료된 후 시작
- ECS Task는 host bind mount를 사용

ECS service-managed EBS는 Service Task 종료 시 보존되지 않으므로 사용하지 않는다.

### 13.3 PostgreSQL

- PostgreSQL 16
- 공식 PostgreSQL image reference를 `@sha256:` digest로 고정
- Service Connect endpoint: `judge-postgres:5432`
- Health check: `pg_isready`
- Task desired count: 1
- 배포 최소 정상 비율: 0%
- 배포 최대 비율: 100%

### 13.4 Redis Queue

- Valkey 8 호환 이미지
- 공식 Valkey image reference를 `@sha256:` digest로 고정
- Service Connect endpoint: `judge-redis:6379`
- AOF: 활성화
- `appendfsync everysec`
- Health check: 인증을 포함한 `redis-cli ping`
- Task desired count: 1
- 배포 최소 정상 비율: 0%
- 배포 최대 비율: 100%

상태 저장 서비스는 같은 volume을 동시에 두 Task가 사용하지 않게 stop-before-start 방식으로 배포하며 짧은 중단을 허용한다.

## 14. Container image

애플리케이션 ECR은 `spring`, `fastapi`, `judge` 세 개만 사용한다. Judge API와 Worker는 동일한 `judge` image digest를 사용하고 실행 command를 각각 `./scripts/server`, `./scripts/workers`로 분리한다.

Judge PostgreSQL과 Valkey는 별도 ECR을 만들지 않는다. 검증한 공식 OCI image의 전체 reference를 `registry/image@sha256:...` 형식으로 입력한다. 운영에서 public registry 의존을 제거해야 할 경우 동일 image를 기존 `judge` repository에 섞지 않고 별도의 mirror 전략을 추가 설계한다.

## 15. Secret과 IAM

Terraform은 Secret 리소스와 권한만 관리하며 `aws_secretsmanager_secret_version`이나 실제 값을 생성하지 않는다.

```text
/cosmos-v2/prod/spring
/cosmos-v2/prod/fastapi
/cosmos-v2/prod/judge-api
/cosmos-v2/prod/judge-postgres
/cosmos-v2/prod/judge-redis
```

서비스별 execution role을 생성한다.

- ECR image pull
- 해당 서비스 CloudWatch Logs 전송
- 해당 서비스에 필요한 Secret ARN만 조회
- Secret 암호화에 customer managed KMS key를 사용할 때 해당 key decrypt

서비스별 task role은 애플리케이션 런타임 권한만 가진다.

- Spring: Backend Valkey `elasticache:Connect`
- 모든 서비스: ECS Exec에 필요한 `ssmmessages` channel 권한
- FastAPI: ECS Exec 외 애플리케이션 AWS 권한 없음
- Judge API: ECS Exec 외 애플리케이션 AWS 권한 없음

기존 공통 task execution role은 1차 호환을 위해 유지하되 신규 서비스에서는 사용하지 않는다.

## 16. Health check

| 서비스 | Health check |
| --- | --- |
| Spring Boot | ALB HTTP `/api/actuator/health` |
| FastAPI | HTTP `/health` |
| Judge API | HTTP `/health` |
| Judge PostgreSQL | `pg_isready` |
| Judge Redis | `redis-cli ping` |

애플리케이션 컨테이너에는 HTTP health check를 실행할 수 있는 `curl` 또는 동등한 도구가 있어야 한다.

ALB와 Service Connect가 비정상 Task로 트래픽을 보내지 않도록 container health check를 essential container에 지정한다.

## 17. 배포 순서와 선행 조건

### 17.1 1단계: 데이터 및 실행 기반

1. Data subnet 및 route table
2. RDS MySQL
3. Backend Valkey
4. Secrets Manager secret 컨테이너
5. 상태 저장 공식 image digest 확인
6. AI PostgreSQL·Judge PostgreSQL·Redis EC2와 EBS
7. EBS snapshot 정책

### 17.2 2단계: 외부 준비

Terraform 외부에서 다음 항목을 준비한다.

1. 세 ECR repository의 image digest와 pgvector/PostgreSQL·Valkey 공식 image reference
2. 실제 Secret 값 입력
3. MySQL schema 및 최소 권한 애플리케이션 계정 준비
4. 모든 health endpoint 검증

### 17.3 3단계: ECS 배포

1. 데이터 기반 단계에서 만든 Service Connect namespace 확인
2. AI PostgreSQL·Judge PostgreSQL·Redis Task Definition과 ECS Service
3. 상태 저장 서비스 health 확인
4. FastAPI one-off Alembic migration
5. Judge API, FastAPI, Spring 순서의 Fargate 안정화
6. Stage HTTPS host routing과 내부 연결 검증

ECR digest 또는 Secret version이 없는 상태에서는 ECS Service를 생성하지 않는다. 표준 배포 명령은 사전 검증 스크립트를 먼저 실행하고 실패 시 Terraform apply를 호출하지 않는다. 사전 검증을 우회한 직접 apply는 운영 절차에서 금지한다.

## 18. 배포와 장애 처리

### 18.1 애플리케이션 서비스

- Task Definition 변경 시 새 Task를 먼저 실행한다.
- 새 Task가 container 및 ALB health check를 통과한 후 기존 Task를 종료한다.
- 배포 실패 시 deployment circuit breaker가 이전 revision으로 rollback한다.
- Task 장애 시 ECS가 replacement Task를 실행한다.

### 18.2 상태 저장 서비스

- 컨테이너 장애 시 동일 EC2와 EBS에서 Task를 재시작한다.
- EC2 장애 시 ECS Service는 Task를 `PENDING` 상태로 유지한다.
- 보존된 EBS를 동일 AZ의 복구 EC2에 재연결하고 ECS instance attribute를 복원한다.
- 복구 완료 후 ECS Service가 Task를 다시 배치하게 한다.
- EC2 교체와 EBS 재연결은 자동 Terraform apply로 수행하지 않고 운영 runbook을 따른다.

### 18.3 단일 구성의 수용 위험

- Fargate 서비스가 1개이므로 Task 교체 및 AZ 장애 시 일시적인 처리량 감소가 발생할 수 있다.
- RDS Single-AZ 장애 시 복구 시간 동안 Spring 데이터 접근이 중단될 수 있다.
- Judge PostgreSQL 또는 Redis EC2 장애 시 채점 요청 처리가 중단된다.
- 단일 NAT Gateway 또는 해당 AZ 장애 시 image pull, 로그, AWS API 및 외부 API 호출이 제한될 수 있다.

이번 단계에서는 비용과 최소 운영 수량을 우선해 위 위험을 수용한다.

## 19. 백업

- RDS 자동 백업: 7일
- RDS 삭제 시 final snapshot 필수
- Backend Valkey Serverless snapshot: 7일
- Judge PostgreSQL EBS snapshot: 매일, 7일 보존
- Judge Redis EBS snapshot: 매일, 3일 보존

EBS snapshot은 Data Lifecycle Manager 정책으로 생성한다. Snapshot은 crash-consistent 백업이므로 PostgreSQL의 논리 백업을 완전히 대체하지 않는다. 운영 안정화 후 `pg_dump` 기반 S3 백업을 추가한다.

복구 가능성을 확인하기 위해 별도 환경에서 PostgreSQL snapshot 복구 훈련을 정기적으로 수행한다.

## 20. Terraform 변수

추가 변수의 기본값은 다음과 같다.

| 변수 | 기본값 |
| --- | --- |
| `data_subnet_cidrs` | `10.20.20.0/24`, `10.20.21.0/24` |
| `service_connect_namespace` | `prod.cosmos-v2.local` |
| `spring_container_port` | `8080` |
| `fastapi_container_port` | `8000` |
| `judge_api_container_port` | `3000` |
| `spring_cpu` / `spring_memory` | `1024` / `2048` |
| `fastapi_cpu` / `fastapi_memory` | `512` / `1024` |
| `judge_api_cpu` / `judge_api_memory` | `512` / `1024` |
| `application_desired_count` | `1` |
| `rds_instance_class` | `db.t4g.medium` |
| `rds_allocated_storage` | `30` |
| `rds_max_allocated_storage` | `100` |
| `stateful_instance_type` | `t3.small` |
| `stateful_ebs_size` | `30` |

이미지는 tag가 아니라 다음 digest 변수로 전달한다.

- `spring_image_digest`
- `fastapi_image_digest`
- `judge_image_digest`
- `ai_postgres_image`
- `judge_postgres_image`
- `judge_redis_image`

애플리케이션 digest는 `sha256:`, 상태 저장 image는 전체 `registry/image@sha256:...` 형식을 validation으로 확인한다.

## 21. Terraform 출력

- Data subnet ID map
- Service Connect namespace ARN
- Spring Target Group ARN
- ECS Service 이름 map
- Task Definition ARN map
- RDS endpoint 및 port
- RDS master secret ARN
- Backend Valkey endpoint 및 port
- Backend Valkey ARN
- AI PostgreSQL·Judge PostgreSQL·Redis EC2 ID
- AI PostgreSQL·Judge PostgreSQL·Redis EBS ID
- 상태 저장 ECS Service 이름
- 서비스별 task role ARN
- 서비스별 execution role ARN
- 서비스별 Secret ARN

비밀번호, 인증 토큰, Secret 값은 출력하지 않는다.

## 22. Terraform 파일 구성

```text
v2/
├── phase-2-architecture.md
├── data-subnets.tf
├── service-connect.tf
├── application-security.tf
├── application-iam.tf
├── secrets.tf
├── rds.tf
├── valkey.tf
├── ecs-task-definitions.tf
├── ecs-services.tf
├── ecs-container-instances.tf
├── judge-stateful-services.tf
├── backups.tf
├── alb.tf
├── ecr.tf
├── variables.tf
├── outputs.tf
├── tests/
│   └── phase-2.tftest.hcl
└── scripts/
    └── preflight.sh
```

파일 이름은 책임을 구분하기 위한 기준이다. 반복되는 정책 문서는 `aws_iam_policy_document`와 local을 사용해 중복을 줄인다.

## 23. 검증 기준

### 23.1 Terraform native test

- Data subnet이 두 AZ에 하나씩 생성되는지 검증
- Data route table에 인터넷 기본 경로가 없는지 검증
- Spring만 Target Group에 연결되는지 검증
- FastAPI와 Judge API가 public ingress를 갖지 않는지 검증
- 모든 Fargate Service가 Private subnet과 `assign_public_ip = false`를 사용하는지 검증
- Service Connect alias와 port가 설계와 일치하는지 검증
- desired count가 각 1개인지 검증
- 상태 저장 Task가 올바른 EC2 attribute에 제한되는지 검증
- EBS 암호화, 삭제 보존 및 snapshot 정책 검증
- RDS public access, 암호화, backup, deletion protection 검증
- Valkey subnet과 암호화는 유지하되 Spring 연결이 없는지 검증
- FastAPI→AI PostgreSQL 5432와 FastAPI→Spring 8080 SG 참조 검증
- Secret version 및 평문 secret이 Terraform에 없는지 검증
- image digest 형식 validation 검증

### 23.2 실제 plan 검토

- v1 리소스 변경 또는 삭제가 없어야 한다.
- 1차 v2 리소스의 의도하지 않은 replacement가 없어야 한다.
- RDS, EBS, ECR, ALB에 예상하지 않은 destroy가 없어야 한다.
- 제외 범위 리소스가 없어야 한다.
- 실제 Secret 값이 plan에 없어야 한다.

### 23.3 Apply 후 smoke test

1. 상태 저장 ECS container instance 3대가 `ACTIVE`인지 확인
2. AI PostgreSQL, Judge PostgreSQL, Redis Task가 지정된 EC2에서 실행되는지 확인
3. Judge API에서 PostgreSQL과 Redis endpoint 연결 확인
4. FastAPI에서 Judge API `/health` 호출 확인
5. Spring에서 FastAPI와 Judge API `/health` 호출 확인
6. Spring에서 RDS MySQL 연결 확인
7. Spring에서 IAM 인증으로 Backend Valkey 연결 확인
8. ALB HTTP 요청이 Spring 응답을 반환하는지 확인
9. FastAPI와 Judge API가 인터넷에서 직접 접근되지 않는지 확인
10. 재실행한 Terraform plan이 변경 없음인지 확인

## 24. 구현 및 배포 중단 조건

다음 중 하나라도 충족하면 apply를 중단한다.

- Terraform Cloud v2 workspace state를 확인할 수 없음
- state에 v1 리소스가 존재
- plan에 destroy 또는 예상하지 않은 replacement가 존재
- 필수 ECR image digest가 없음
- 필수 Secret version이 없음
- 애플리케이션 health endpoint가 동작하지 않음
- Spring Valkey IAM 인증이 구현되지 않음
- 상태 저장 EBS snapshot 또는 복구 절차가 준비되지 않음
- PostgreSQL·Redis EC2가 ECS Cluster에 `ACTIVE`로 등록되지 않음

## 25. 후속 단계

2차 구축 및 검증 후 다음 순서로 확장한다.

1. Judge Worker ECS on EC2와 전용 Capacity Provider
2. ACM, HTTPS listener, Route 53 전환
3. 애플리케이션 및 Terraform CI/CD
4. 부하 테스트 기반 ECS Auto Scaling
5. Judge Worker On-Demand/Spot 혼합 Auto Scaling
6. RDS Multi-AZ 전환 여부 검토
7. NAT Gateway 다중 AZ 또는 VPC Interface Endpoint 비용 비교
