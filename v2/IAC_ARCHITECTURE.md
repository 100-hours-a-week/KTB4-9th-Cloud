# COSMOS v2 IaC 인프라 구성

## 1. 문서 목적

이 문서는 2026-10-20 기준 `v2/` Terraform 작업 트리에 선언된 인프라와 실제 AWS에 적용된 주요 상태를 함께 설명한다.

- HCP Terraform Workspace 분리 방식
- VPC, Subnet, NAT Gateway와 외부 진입 구조
- ECS Fargate 및 ECS on EC2 서비스 배치
- 애플리케이션별 CPU, 메모리, 포트, 실행 수
- 일반 환경변수와 Secrets Manager 주입 값
- MySQL, Valkey, AI PostgreSQL, Judge PostgreSQL/Redis 구성
- ECR, IAM, 로그, 백업 및 GitHub Actions 권한
- 현재 코드에서 주의해야 할 운영 특성

기본 기준은 **Terraform 코드가 의도하는 상태**다. 단, ECS 서비스는 `task_definition` 변경을 무시하도록 설정되어 있어 CI/CD 또는 수동 배포가 등록한 최신 Task Definition과 Terraform의 이미지 digest·환경변수·Secret 참조가 다를 수 있다. 확인된 차이는 각 절과 16절에 별도로 표시한다.

## 2. Terraform 프로젝트 구조

v2는 하나의 저장소 안에서 State를 두 개의 HCP Terraform Workspace로 분리한다.

| 구분 | 경로 | HCP Terraform Workspace | 역할 |
|---|---|---|---|
| Shared | `v2/environments/shared` | `KTB4-9th-Cloud-v2-shared` | VPC, Subnet, NAT, ECR, ACM, GitHub OIDC, 중앙 모니터링 EC2 |
| Stage | `v2/environments/stage` | `KTB4-9th-Cloud-v2-stage` | ECS, ALB, CloudFront, DB, Cache, Secrets, IAM, 로그 전달 Lambda |

Stage는 `terraform_remote_state`로 Shared State의 다음 출력을 읽는다.

- VPC ID
- Public/Private/Data Subnet ID
- ECR URL과 ARN
- GitHub Actions OIDC Provider ARN
- Route 53 Hosted Zone ID
- CloudFront용 ACM 인증서 ARN
- 서울 리전 ALB용 Wildcard ACM 인증서 ARN
- 모니터링 EC2의 Private IP와 Security Group ID

두 Workspace 모두 Terraform `>= 1.7.0, < 2.0.0`, AWS Provider `~> 5.0`을 사용한다.

## 3. 전체 아키텍처

```text
사용자
  |
  | HTTPS: cosmoscode.site, www.cosmoscode.site
  v
CloudFront
  |-- 정적 파일 --------------------------> Private S3 Frontend Bucket
  |-- /api/*, /auth/* -- HTTP ------------> Public ALB
                                                |
                                                v
                                      Spring Fargate :8080
                                                |
                     +--------------------------+--------------------------+
                     |                          |                          |
                     v                          v                          v
             RDS MySQL :3306          FastAPI Fargate :8000      Judge API Fargate :2358
                                             |                           |
                                             v                           +------------------+
                                  AI PostgreSQL ECS/EC2                  |                  |
                                                                     PostgreSQL         Redis
                                                                        ^                  ^
                                                                        |                  |
                                                                        +--------+---------+
                                                                                 |
                                                               Judge Worker ECS on EC2

직접 테스트용 HTTPS 서브도메인
  stage-be.cosmoscode.site    -> ALB -> Spring
  stage-ai.cosmoscode.site    -> ALB -> FastAPI
  stage-judge.cosmoscode.site -> ALB -> Judge API

관측 경로
  Spring/Redis/ECS/EC2 Metrics -------------> Prometheus
  CloudWatch Logs -> VPC Lambda -----------> Loki
  Prometheus + Loki ------------------------> Grafana
                                                   ^
                                                   |
                                 Caddy HTTPS / grafana-v2.cosmoscode.site
```

## 4. 네트워크

### 4.1 VPC와 Subnet

| 항목 | 설정 |
|---|---|
| AWS 리전 | `ap-northeast-2` (서울) |
| VPC CIDR | `10.20.0.0/16` |
| 가용 영역 | `ap-northeast-2a`, `ap-northeast-2c` |
| Public Subnet | `10.20.0.0/24`, `10.20.1.0/24` |
| Private Subnet | `10.20.10.0/24`, `10.20.11.0/24` |
| Data Subnet | `10.20.20.0/24`, `10.20.21.0/24` |

- Public Subnet에는 인터넷 연결 ALB와 NAT Gateway가 배치된다.
- Fargate 애플리케이션, Judge Worker 및 Stateful EC2는 Private Subnet에 배치된다.
- RDS MySQL과 Valkey Serverless는 외부 라우트가 없는 Data Subnet에 배치된다.
- Public, Private, Data Subnet은 각각 2개이며 두 AZ에 분산된다.

### 4.2 인터넷 경로

- Internet Gateway: 1개
- NAT Gateway: 1개
- NAT Gateway 위치: 첫 번째 Public Subnet
- 두 Private Subnet의 기본 경로는 같은 NAT Gateway를 사용한다.
- Data Subnet에는 인터넷 기본 경로가 없다.
- Private Route Table에는 S3 Gateway VPC Endpoint가 연결된다.

NAT Gateway를 하나만 사용하므로 비용은 줄어들지만, NAT가 위치한 AZ 또는 NAT Gateway 장애 시 두 Private Subnet의 외부 통신이 영향을 받는 구조다.

## 5. 컨테이너 이미지와 ECR

Shared 프로젝트가 다음 ECR Repository 3개를 생성한다.

| ECR Key | 용도 |
|---|---|
| `spring` | Spring Boot Backend |
| `fastapi` | AI FastAPI |
| `judge` | Judge API와 Judge Worker가 공유하는 이미지 |

공통 정책은 다음과 같다.

- Tag 변경 불가(`IMMUTABLE`)
- Push 시 이미지 스캔
- AES-256 서버 측 암호화
- Tagged 이미지 최근 20개 보존
- Untagged 이미지 7일 후 제거
- ECS Task Definition은 tag가 아닌 `@sha256:` digest로 이미지를 고정

## 6. ECS Cluster와 실행 방식

ECS Cluster 이름은 `cosmos-v2-stage-cluster`이며 Container Insights가 활성화된다. 기본 Capacity Provider는 Fargate다.

### 6.1 Fargate 애플리케이션

| 서비스 | 실행 방식 | Task 수 | CPU | 메모리 | 포트 | 이미지 |
|---|---:|---:|---:|---:|---:|---|
| Spring | Fargate | 1 | 1024 unit (1 vCPU) | 2048 MiB | 8080, 관리 9091 | `spring@digest` |
| FastAPI | Fargate | 1 | 512 unit (0.5 vCPU) | 1024 MiB | 8000 | `fastapi@digest` |
| Judge API | Fargate | 1 | 512 unit (0.5 vCPU) | 1024 MiB | 2358 | `judge@digest` |

공통 설정:

- `awsvpc` 네트워크 모드
- X86_64 Linux
- Private Subnet 두 곳에 배치하며 Public IP 미할당
- 배포 최소 정상 비율 100%, 최대 비율 200%
- ECS Deployment Circuit Breaker 및 자동 Rollback 활성화
- ECS Exec 활성화
- desired count는 초기 운영 정책상 서비스별 1개로 고정
- Application Auto Scaling Target/Policy는 정의되어 있지 않음
- CI/CD가 Task Definition을 갱신할 수 있도록 Terraform은 ECS Service의 `task_definition` 변경을 무시

### 6.2 Service Connect

Service Connect Namespace는 `stage.cosmos-v2.local`이다.

| DNS 별칭 | 대상 |
|---|---|
| `spring:8080` | Spring Task |
| `fastapi:8000` | FastAPI Task |
| `judge-api:2358` | Judge API Task |
| `ai-postgres:5432` | AI PostgreSQL Task |
| `judge-postgres:5432` | Judge PostgreSQL Task |
| `judge-redis:6379` | Judge Redis Task |

FastAPI는 내부 통신에 `spring`, `judge-api` 별칭을 사용한다. 반면 Spring의 현재 설정은 FastAPI와 Judge API에 대해 공개 HTTPS 서브도메인을 사용한다.

### 6.3 Stateful 서비스: ECS on EC2

다음 서비스는 Fargate가 아니라 각자 전용 EC2 인스턴스에서 ECS Task로 실행된다.

| 서비스 | EC2 | ECS Task 수 | 예약 메모리 | 데이터 볼륨 | Subnet |
|---|---|---:|---:|---:|---|
| AI PostgreSQL + pgvector | `t3.small` 1대 | 1 | 1536 MiB | 암호화 gp3 30 GiB | Private 1 |
| Judge PostgreSQL | `t3.small` 1대 | 1 | 1024 MiB | 암호화 gp3 30 GiB | Private 1 |
| Judge Redis | `t3.small` 1대 | 1 | 512 MiB | 암호화 gp3 30 GiB | Private 2 |

- ECS Optimized Amazon Linux 2023 AMI 사용
- 서비스마다 별도 EC2, 별도 EBS 사용
- EC2와 데이터 EBS에 `prevent_destroy` 적용
- 데이터 EBS는 EC2 종료 시에도 삭제되지 않도록 구성
- SSM Agent 권한을 부여하여 Public IP나 SSH 없이 관리 가능
- ECS placement constraint로 지정된 전용 인스턴스에만 배치
- 배포 중 동시에 두 Task를 실행하지 않도록 최소 0%, 최대 100% 설정

### 6.4 Judge Worker: ECS on EC2

Judge Worker는 격리 실행과 privileged container가 필요하므로 전용 ECS on EC2 Capacity Provider를 사용한다.

| 항목 | 설정 |
|---|---|
| Task CPU | 2048 unit (2 vCPU) |
| Task 메모리 | 2048 MiB |
| 현재 desired count | 1 |
| On-Demand ASG | 최소/희망/최대 `1/1/1` |
| On-Demand 타입 | `c7i.large` |
| Spot ASG | 최소/희망/최대 `0/0/7` |
| Spot 후보 | `c7i.large`, `c6i.large`, `c6a.large` |
| EC2 Root Volume | 암호화 gp3 50 GiB |
| Worker 프로세스 수 | `COUNT=2` |
| Worker Poll 간격 | `INTERVAL=0.1` |

- On-Demand 1대가 기본 용량을 담당한다.
- 추가 Task가 필요하면 Spot Capacity Provider를 사용할 수 있다.
- 현재 ECS Service desired count가 1이므로 Spot 인스턴스의 희망 용량은 0이다.
- Spot은 최대 7대까지 확장 가능한 기반만 정의되어 있다.
- ECS Managed Scaling, Managed Draining, Managed Termination Protection이 활성화된다.
- Judge0의 isolate가 cgroup v1을 요구해 Worker Host만 ECS Optimized Amazon Linux 2를 사용한다.
- Worker Container는 `privileged=true`, ECS Exec은 비활성화되어 있다.

## 7. 애플리케이션 환경변수

### 7.1 값 관리 원칙

- 비민감 값: ECS Task Definition의 `environment`
- 민감 값: Secrets Manager JSON의 특정 key를 ECS `secrets`로 주입
- Terraform은 Secret 리소스와 이름만 생성한다.
- 실제 Secret 값은 Terraform State에 저장하지 않고 AWS 외부 작업으로 등록한다.

### 7.2 Spring

일반 환경변수:

| 변수 | Terraform 정의 값 |
|---|---|
| `APP_REGION` | `ap-northeast-2` |
| `APP_VERSION` | `v2` |
| `SPRING_PROFILES_ACTIVE` | Terraform 현재 코드: `prod` / 실제 ECS revision 31: `stage` |
| `DB_URL` | `jdbc:mysql://<RDS endpoint>:3306/cosmos?...serverTimezone=Asia/Seoul` |
| `AI_SERVER_BASE_URL` | `https://stage-ai.cosmoscode.site` |
| `JUDGE0_BASE_URL` | `https://stage-judge.cosmoscode.site` |
| `FRONTEND_BASE_URL` | DNS 전환 활성화 시 `https://cosmoscode.site` |
| `MANAGEMENT_PORT` | `9091` |
| `SENTRY_ENVIRONMENT` | `stage` |
| `SPRING_JPA_OPEN_IN_VIEW` | `true` |

Terraform 현재 코드는 Secrets Manager `/cosmos-v2/stage/spring`에서 다음 값을 주입한다.

| ECS 변수 | Secret JSON key |
|---|---|
| `DB_USERNAME` | `db_username` |
| `DB_PASSWORD` | `db_password` |
| `KAKAO_CLIENT_ID` | `kakao_client_id` |
| `KAKAO_CLIENT_SECRET` | `kakao_client_secret` |
| `KAKAO_REDIRECT_URI` | `kakao_redirect_uri` |
| `JWT_SECRET` | `jwt_secret` |

실제 AWS의 Spring revision 31은 `SPRING_PROFILES_ACTIVE=stage`로 실행된다. DB 자격증명만 RDS 관리형 Secret의 `username`, `password` key를 직접 참조하고 카카오/JWT는 `/cosmos-v2/stage/spring`에서 읽는다. 따라서 **현재 Terraform 코드와 실제 실행 Task Definition 사이에 drift가 있다.** 다음 Terraform 배포 전에 코드도 실제 구조와 일치시켜야 한다.

### 7.3 FastAPI

일반 환경변수:

| 변수 | 값 |
|---|---|
| `DB_HOST` | `ai-postgres` |
| `DB_PORT` | `5432` |
| `DB_NAME` | `cosmos` |
| `DB_ECHO` | `false` |
| `DB_POOL_SIZE` | `5` |
| `DB_MAX_OVERFLOW` | `5` |
| `BACKEND_URL` | `http://spring:8080/api` |
| `JUDGE0_URL` | `http://judge-api:2358` |
| `MOCK_LLM` | `false` |
| `BATCH_ENABLED` | `true` |
| `BATCH_TIMEZONE` | `Asia/Seoul` |
| `BATCH_CONCURRENCY` | `5` |
| `LOG_LEVEL` | `INFO` |

Secret 주입:

| ECS 변수 | Secret | JSON key |
|---|---|---|
| `DB_USER` | `/cosmos-v2/stage/ai-postgres` | `username` |
| `DB_PASSWORD` | `/cosmos-v2/stage/ai-postgres` | `password` |
| `GEMINI_API_KEY` | `/cosmos-v2/stage/fastapi` | `gemini_api_key` |

### 7.4 Judge API

일반 환경변수:

| 변수 | 값 |
|---|---|
| `POSTGRES_HOST` | `judge-postgres` |
| `POSTGRES_PORT` | `5432` |
| `REDIS_HOST` | `judge-redis` |
| `REDIS_PORT` | `6379` |
| `RAILS_ENV` | `production` |
| `RESQUE_NAMESPACE` | `stage:judge0` |
| `PORT` | `2358` |

Secret 주입:

| ECS 변수 | Secret | JSON key |
|---|---|---|
| `SECRET_KEY_BASE` | `/cosmos-v2/stage/judge-api` | `secret_key_base` |
| `POSTGRES_USER` | `/cosmos-v2/stage/judge-postgres` | `username` |
| `POSTGRES_PASSWORD` | `/cosmos-v2/stage/judge-postgres` | `password` |
| `POSTGRES_DB` | `/cosmos-v2/stage/judge-postgres` | `database` |
| `REDIS_PASSWORD` | `/cosmos-v2/stage/judge-redis` | `password` |

### 7.5 Judge Worker

Judge Worker는 Judge API와 동일한 PostgreSQL, Redis, `SECRET_KEY_BASE`를 사용한다. 추가 환경변수는 `COUNT=2`, `INTERVAL=0.1`이며 실행 명령은 `./scripts/workers`다.

### 7.6 Stateful 컨테이너

| 서비스 | 일반 환경변수 | Secret 환경변수 |
|---|---|---|
| AI PostgreSQL | `POSTGRES_DB=cosmos`, `PGDATA=.../pgdata` | `POSTGRES_USER`, `POSTGRES_PASSWORD` |
| Judge PostgreSQL | `PGDATA=.../pgdata` | `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB` |
| Judge Redis | 별도 일반 값 없음 | `REDIS_PASSWORD` |

Judge Redis는 `appendonly yes`와 비밀번호 인증을 활성화한다.

## 8. 데이터 계층

### 8.1 Spring RDS MySQL

| 항목 | 설정 |
|---|---|
| Engine | MySQL 8.0 |
| DB 이름 | `cosmos` |
| Master 사용자 | `cosmos_admin` |
| 비밀번호 | RDS Managed Master Password |
| Instance | `db.t4g.medium` |
| Storage | 암호화 gp3 30 GiB |
| Storage Auto Scaling 최대 | 100 GiB |
| Multi-AZ | 비활성화 |
| Public Access | 비활성화 |
| 자동 Backup 보존 | 7일 |
| 삭제 방지 | 활성화 |
| 삭제 시 Final Snapshot | 생성 |

RDS는 Data Subnet 두 개로 구성된 DB Subnet Group을 사용한다. 3306 접근은 Spring Security Group과 Stage SSM 터널 용도의 AI PostgreSQL Host Security Group에서만 허용된다.

- Terraform의 `manage_master_user_password = true`가 RDS 관리형 Secret을 생성한다.
- 실제 AWS에서는 2026-10-20 장애 대응으로 자동 회전을 비활성화했다.
- 자동 회전 활성/비활성 상태는 현재 Terraform 코드가 직접 선언하지 않으므로 AWS 설정과 별도로 관리된다.
- Multi-AZ는 `false`이며 Primary 한 대만 운용한다.

### 8.2 Spring Valkey

| 항목 | 설정 |
|---|---|
| 서비스 | ElastiCache Serverless |
| Engine | Valkey |
| Subnet | Data Subnet 2개 |
| 인증 | ElastiCache IAM User |
| Snapshot 보존 | 7일 |
| 허용 포트 | Spring SG에서 6379, 6380 |

Spring Task Role에는 `elasticache:Connect` 권한이 있다. 하지만 현재 Spring Task Definition에는 Valkey endpoint, port 또는 IAM username 관련 환경변수가 없다. 따라서 **인프라는 생성되어 있지만 애플리케이션 연결 설정은 Terraform에 완성되어 있지 않다.**

### 8.3 AI PostgreSQL

- `pgvector/pgvector:pg17` 이미지 사용
- DB 이름 `cosmos`
- ECS on EC2 전용 Host와 영구 EBS 사용
- FastAPI에서만 5432 접근 허용
- 사용자명과 비밀번호는 `/cosmos-v2/stage/ai-postgres` Secret 사용

### 8.4 Judge PostgreSQL과 Redis

- Judge PostgreSQL: `postgres:16.2`
- Judge Redis: `redis:7.2.4`, AOF 활성화
- 각각 전용 ECS on EC2 Host와 EBS 사용
- Judge API와 Judge Worker만 접근 허용
- Service Connect DNS로 연결

## 9. 외부 진입, DNS와 TLS

### 9.1 Frontend

- S3 Bucket: `cosmos-v2-stage-frontend-<AWS account ID>`
- S3 Public Access 완전 차단
- CloudFront OAC만 객체 읽기 가능
- S3 Versioning 활성화
- 이전 객체 버전은 30일 후 제거
- 기본 정적 콘텐츠는 CloudFront Managed CachingOptimized 사용
- `/index.html`은 캐시하지 않음
- 확장자가 없는 경로는 CloudFront Function이 `/index.html`로 변경하여 SPA Routing 지원

DNS 전환이 활성화되어 현재 CloudFront Alias는 다음과 같다.

- `cosmoscode.site`
- `www.cosmoscode.site`

### 9.2 API 경로

CloudFront는 다음 경로를 ALB로 전달한다.

- `/api/*`
- `/auth/*`

이 경로는 캐시하지 않으며 모든 Viewer Header를 Origin에 전달한다. CloudFront에서 ALB까지는 현재 HTTP 80을 사용하고, ALB 80은 CloudFront Origin-facing Prefix List에서만 접근 가능하다.

### 9.3 Stage 서비스 서브도메인

| 주소 | 대상 | Root 처리 |
|---|---|---|
| `stage-be.cosmoscode.site` | Spring | Spring으로 전달 |
| `stage-ai.cosmoscode.site` | FastAPI | `/`를 `/docs`로 Redirect |
| `stage-judge.cosmoscode.site` | Judge API | `/`를 `/docs`로 Redirect |

서브도메인은 Route 53 Alias로 ALB를 가리킨다. ALB 443 Listener는 서울 리전 Wildcard ACM 인증서를 사용한다. 현재 Stage 테스트를 위해 443은 인터넷 전체(`0.0.0.0/0`)에 공개되어 있다.

## 10. Security Group 흐름

| 출발지 | 목적지 | 포트 |
|---|---|---:|
| CloudFront Origin Prefix List | ALB | 80 |
| 인터넷 전체(임시 Stage 테스트) | ALB | 443 |
| ALB | Spring | 8080 |
| ALB | FastAPI | 8000 |
| ALB | Judge API | 2358 |
| Spring | FastAPI | 8000 |
| FastAPI | Spring | 8080 |
| Spring/FastAPI | Judge API | 2358 |
| Spring | RDS MySQL | 3306 |
| Spring | Valkey | 6379, 6380 |
| FastAPI | AI PostgreSQL | 5432 |
| Judge API/Worker | Judge PostgreSQL | 5432 |
| Judge API/Worker | Judge Redis | 6379 |

애플리케이션 및 Data Security Group의 Egress는 전체 허용이다. Judge Worker Task는 PostgreSQL, Redis, VPC DNS만 허용하며 Worker EC2 Host는 HTTPS와 VPC DNS만 허용한다.

## 11. IAM과 비밀 관리

### 11.1 ECS 역할

각 애플리케이션과 Stateful 서비스는 Execution Role과 Task Role을 분리한다.

- Execution Role: ECR Pull, CloudWatch Logs, 허용된 Secrets Manager Secret 읽기
- Task Role: ECS Exec용 SSM Message Channel
- Spring Task Role: Valkey IAM 연결 권한 추가
- Worker Execution Role: Judge API/PostgreSQL/Redis Secret만 읽기
- Stateful EC2/Worker EC2 Role: ECS 등록과 SSM 관리

### 11.2 Secret 목록

Terraform이 생성하는 Secret 이름은 다음과 같다.

```text
/cosmos-v2/stage/spring
/cosmos-v2/stage/fastapi
/cosmos-v2/stage/ai-postgres
/cosmos-v2/stage/judge-api
/cosmos-v2/stage/judge-postgres
/cosmos-v2/stage/judge-redis
/cosmos-v2/stage/judge-worker
```

Secret 삭제 복구 기간은 30일이다. `/judge-worker` Secret 리소스는 생성되지만 현재 Worker Task는 그 Secret의 값을 직접 사용하지 않고 Judge 관련 3개 Secret을 사용한다.

## 12. 로그, 상태 확인과 백업

### 12.1 CloudWatch Logs와 Loki 전달

보존 기간은 모두 30일이다.

```text
/ecs/cosmos-v2-stage/spring
/ecs/cosmos-v2-stage/fastapi
/ecs/cosmos-v2-stage/judge-api
/ecs/cosmos-v2-stage/ai-postgres
/ecs/cosmos-v2-stage/judge-postgres
/ecs/cosmos-v2-stage/judge-redis
/ecs/cosmos-v2-stage/judge-worker
```

ECS Container Insights는 활성화되어 있다. Stage 모듈은 각 CloudWatch Log Group에 Subscription Filter를 연결하고, VPC Lambda `cosmos-v2-stage-cloudwatch-to-loki`가 로그를 Private IP의 Loki `:3100`으로 전달한다.

```text
ECS stdout/stderr
  -> CloudWatch Logs
  -> Subscription Filter
  -> VPC Lambda(Python 3.12)
  -> Loki :3100
  -> Grafana
```

Lambda는 Private Subnet에 배치되고 Loki Private IP 한 곳으로만 TCP 3100 Egress가 허용된다. 현재 코드에는 `/ecs/cosmos-v2-stage/mlflow`도 전달 대상으로 포함되어 있으나 같은 모듈 안에 해당 Log Group 생성 리소스가 없으므로, 적용 전 실제 Log Group 존재 여부를 확인해야 한다.

### 12.2 중앙 모니터링 서버

Shared 모듈은 Public Subnet에 단일 EC2 모니터링 서버를 구성한다.

| 항목 | 설정 |
|---|---|
| 인스턴스 | Ubuntu 24.04, `t3.medium` |
| 외부 주소 | `grafana-v2.cosmoscode.site` |
| 진입 | Caddy 80/443, Grafana 포트는 직접 공개하지 않음 |
| 구성 배포 | Terraform이 S3 구성 버킷에 `v2/monitoring/**` 업로드 |
| 구성 동기화 | EC2 systemd timer가 S3에서 주기적으로 동기화 |
| 영구 데이터 | 암호화 gp3 EBS 100 GiB 이상, `prevent_destroy` |
| 관리자 암호 | Secrets Manager `/cosmos-v2/monitoring/grafana-admin` |

Docker Compose 서비스는 다음과 같다.

- Grafana `13.2.4`: 대시보드와 데이터소스 제공
- Prometheus `3.14.0`: 자체 상태, Spring Actuator, Redis exporter와 인프라 메트릭 수집
- Loki `3.7.8`: 중앙 애플리케이션 로그 저장 및 조회
- Caddy: 공개 HTTPS와 인증서 자동 관리
- Prometheus reloader 및 Redis exporter 보조 컨테이너

모니터링 EC2 역할은 CloudWatch Metrics/Logs 조회, ECS/EC2 서비스 디스커버리, 구성 S3 읽기와 Grafana 관리자 Secret 읽기 권한을 가진다. 운영 접속은 SSM을 사용한다.

### 12.3 Health Check

| 서비스 | 확인 경로/명령 |
|---|---|
| Spring | ALB `/api/actuator/health` |
| FastAPI | ALB `/health` |
| Judge API | ALB `/` |
| AI PostgreSQL | `pg_isready -U $POSTGRES_USER -d cosmos` |
| Judge PostgreSQL | `pg_isready -U $POSTGRES_USER -d $POSTGRES_DB` |
| Judge Redis | 인증 후 `PING` |

Fargate Container Health Check는 코드상 `prod` 환경의 Spring 외 서비스에만 추가되도록 되어 있다. 현재 환경 값은 `stage`이므로 FastAPI/Judge API의 상태는 주로 ALB Target Group Health Check가 판단한다.

### 12.4 백업

- RDS: 자동 Backup 7일 및 삭제 시 Final Snapshot
- AI PostgreSQL EBS: 매일 Snapshot, 7개 보존
- Judge PostgreSQL EBS: 매일 Snapshot, 7개 보존
- Judge Redis EBS: 매일 Snapshot, 3개 보존
- DLM 실행 시간: 매일 UTC 18:00(한국 시간 다음 날 03:00)

## 13. GitHub Actions 권한

GitHub Actions는 장기 Access Key 대신 AWS IAM OIDC를 사용한다.

### CI 역할

- BE, AI, Judge 저장소별 별도 Role
- 각 저장소는 자신의 ECR에만 Push 가능
- GitHub Environment `staging-ci` 조건 적용

### CD 역할

- BE, AI, Judge, FE 저장소별 별도 Role
- Container CD는 자신의 ECR 조회, Task Definition 등록, 자신의 ECS Service 갱신만 가능
- FE CD는 Stage S3 동기화와 CloudFront Invalidation만 가능
- GitHub Environment `staging` 조건 적용

Cloud 저장소의 Terraform Plan Role은 AWS 리소스 읽기 권한만 가지며 Apply 권한은 포함하지 않는다. 따라서 Terraform Apply는 수동 운영 정책을 유지한다.

## 14. 현재 Stage 활성화 값

현재 변수 파일에는 다음 기능이 활성화되어 있다.

| 변수 | 값 |
|---|---:|
| `enable_stateful_services` | `true` |
| `enable_phase2_services` | `true` |
| `enable_judge_worker_capacity` | `true` |
| `enable_judge_worker` | `true` |
| `judge_worker_desired_count` | `1` |
| `enable_public_dns_cutover` | `true` |

`stage.auto.tfvars`는 Terraform이 자동으로 읽지만 `stage.tfvars`는 `-var-file=stage.tfvars`를 지정할 때만 읽는다. 두 파일의 Spring image digest가 서로 다르므로 실행 방식에 따라 Plan 결과가 달라질 수 있다. HCP Terraform Workspace Variable이 존재하면 그 우선순위도 함께 확인해야 한다.

## 15. 파일별 책임

### Shared Module

| 파일 | 역할 |
|---|---|
| `modules/shared/network.tf` | VPC, Subnet, IGW, NAT, Route Table, S3 Endpoint |
| `modules/shared/ecr.tf` | ECR 3개와 Lifecycle Policy |
| `modules/shared/acm.tf` | 서울 리전 Wildcard 인증서 |
| `modules/shared/github-actions.tf` | GitHub OIDC, CI 및 Terraform Plan Role |
| `modules/shared/monitoring.tf` | 모니터링 EC2, EIP, 영구 EBS, 구성 S3, Grafana Secret과 IAM |
| `modules/shared/outputs.tf` | Stage Workspace에 전달할 출력 |

### Environment Module

| 파일 | 역할 |
|---|---|
| `ecs.tf` | ECS Cluster와 Capacity Provider 연결 |
| `ecs-task-definitions.tf` | Spring/FastAPI/Judge API Task와 환경변수 |
| `ecs-services.tf` | Fargate ECS Service |
| `ecs-container-instances.tf` | Stateful 전용 EC2와 EBS |
| `judge-stateful-services.tf` | AI/Judge DB 및 Redis ECS Task/Service |
| `worker-capacity.tf` | Judge Worker Launch Template, ASG, Capacity Provider |
| `judge-worker.tf` | Judge Worker Task/Service |
| `rds.tf` | Spring용 RDS MySQL |
| `valkey.tf` | Spring용 Valkey Serverless |
| `frontend.tf` | S3, CloudFront, OAC, SPA Rewrite |
| `alb.tf` | ALB, Listener, Target Group, Routing Rule |
| `route53.tf` | Frontend과 서비스 DNS |
| `application-security.tf`, `security.tf` | Security Group과 통신 경로 |
| `application-iam.tf`, `iam.tf` | ECS/EC2 IAM 역할 |
| `secrets.tf` | Secrets Manager Secret 메타데이터 |
| `logging.tf` | CloudWatch Log Group |
| `log-forwarding.tf`, `lambda/cloudwatch_to_loki.py` | CloudWatch Logs를 Loki로 전달하는 VPC Lambda와 구독 필터 |
| `backups.tf` | Stateful EBS DLM Snapshot |
| `github-actions-cd.tf` | 서비스별 Stage 배포 권한 |
| `service-connect.tf` | 내부 Service Connect Namespace |

### Monitoring Runtime

| 경로 | 역할 |
|---|---|
| `monitoring/docker-compose.yml` | Grafana, Prometheus, Loki, Caddy 및 exporter 실행 |
| `monitoring/prometheus/prometheus.yml` | 메트릭 수집 대상과 ECS 서비스 디스커버리 |
| `monitoring/loki/loki.yml` | 로그 저장소와 보존 설정 |
| `monitoring/grafana/` | 데이터소스, Dashboard Provider와 서비스별 대시보드 |
| `modules/shared/templates/monitoring-user-data.sh.tftpl` | EC2 초기화, EBS Mount와 구성 동기화 timer 설치 |

## 16. 코드 기준 확인이 필요한 지점

1. Terraform 현재 코드는 `SPRING_PROFILES_ACTIVE=prod`지만 실제 revision 31은 `stage`다.
2. Terraform 현재 코드는 Spring DB 자격증명을 `/cosmos-v2/stage/spring`에서 읽지만 실제 revision 31은 RDS 관리형 Secret을 직접 읽는다.
3. 실제 RDS Secret 자동 회전은 비활성화되어 있지만 이 상태는 Terraform에서 선언하지 않는다.
4. Spring Valkey는 인프라와 IAM만 있고 애플리케이션 접속 환경변수가 없다.
5. Spring은 내부 Service Connect 대신 FastAPI/Judge의 공개 Stage URL을 사용한다.
6. Fargate Application Auto Scaling은 아직 정의되어 있지 않다.
7. Spot Worker 확장 기반은 있지만 Worker desired count는 수동 값이다.
8. ALB 443은 Stage 테스트 목적으로 인터넷 전체에 공개되어 있다.
9. `stage.auto.tfvars`와 `stage.tfvars`의 Spring digest가 서로 다르다.
10. CI/CD가 Task Definition을 변경하므로 Terraform 선언 digest와 실제 실행 revision이 다를 수 있다.
11. `/ecs/cosmos-v2-stage/mlflow` 구독 필터는 Log Group이 선행 생성되어 있어야 한다.
12. Secret 값은 Terraform이 생성하거나 검증하지 않으므로 배포 전에 필요한 JSON key가 모두 등록되어 있어야 한다.
