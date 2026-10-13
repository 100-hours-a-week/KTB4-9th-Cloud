# COSMOS v2 AI PostgreSQL 및 ECS 런타임 계약 보완 설계

## 1. 배경

Stage 공통 기반과 RDS MySQL, Backend Valkey, Judge PostgreSQL/Redis용 EC2·EBS는 이미 생성되었다. 애플리케이션 저장소의 실제 설정을 점검한 결과 FastAPI는 PostgreSQL 전용 기능과 `pgvector` 확장을 사용하지만 현재 Terraform에는 AI 전용 데이터베이스가 없다. 또한 Spring, FastAPI, Judge에 주입하는 환경 변수와 Secret 이름 일부가 애플리케이션이 읽는 이름과 다르다.

이번 보완은 기존 RDS MySQL을 Spring 전용으로 유지하고, AI PostgreSQL을 ECS on EC2로 추가하며, ECS Task Definition의 런타임 계약을 실제 애플리케이션 설정과 일치시키는 것을 목표로 한다.

## 2. 확정된 요구사항

- Spring, FastAPI, Judge API는 각각 Fargate Task 1개로 실행한다.
- Spring은 기존 RDS MySQL의 `cosmos` 데이터베이스를 사용한다.
- Backend Valkey는 인프라만 유지하며 이번 범위에서는 Spring과 연결하지 않는다.
- AI PostgreSQL은 외부 managed DB를 사용하지 않고 ECS on EC2로 실행한다.
- AI PostgreSQL 엔진은 PostgreSQL 17과 pgvector 확장을 제공해야 하며 데이터베이스 이름은 `cosmos`로 고정한다.
- Judge PostgreSQL과 Judge Redis는 기존 ECS on EC2 방식을 유지한다.
- Judge Worker는 privileged 실행이 필요하므로 ECS on EC2를 유지한다.
- 모든 컨테이너 이미지는 tag가 아니라 `@sha256:` digest로 고정한다.
- Secret 실제 값은 Terraform state에 저장하지 않고 AWS Secrets Manager에 운영자가 등록한다.
- 커밋과 Git push는 사용자가 직접 수행한다.

## 3. 선택한 구조

```text
                              ECS Cluster
                                   │
              ┌────────────────────┼─────────────────────┐
              │                    │                     │
       Spring Fargate       FastAPI Fargate       Judge API Fargate
              │                    │                     │
              ▼                    ▼                     ▼
       RDS MySQL :3306      ai-postgres :5432    judge-postgres :5432
         DB: cosmos         ECS on EC2 + EBS       ECS on EC2 + EBS
                                  DB: cosmos              │
                                                        judge-redis :6379
                                                        ECS on EC2 + EBS
                                                               │
                                                        Judge Worker EC2
```

AI PostgreSQL은 Judge 상태 저장 서비스와 같은 기본 패턴을 사용한다. 전용 EC2 1대에 삭제 방지 EBS 1개를 연결하고, EC2 host path를 PostgreSQL 데이터 경로에 mount한다. ECS Service desired count는 1로 고정하며 custom instance attribute와 placement constraint로 자신의 전용 EC2에만 배치한다.

Fargate Service의 task-managed EBS는 Service Task 종료 시 보존되지 않으므로 데이터베이스에 사용하지 않는다. EFS도 PostgreSQL의 초기 단일 노드 블록 스토리지 요구보다 복잡성과 비용이 커 이번 범위에서 제외한다.

## 4. AI PostgreSQL 리소스 계약

### 4.1 Compute와 Storage

- 서비스 이름: `ai-postgres`
- 실행 방식: ECS EC2 launch type
- EC2 수량: 환경별 1대
- 초기 instance type: 기존 상태 저장 서비스와 같은 기본값
- EBS: gp3, 암호화, `delete_on_termination=false`
- container mount: `/var/lib/postgresql/data`
- EBS tag와 custom ECS attribute로 `ai-postgres` 전용 배치를 보장한다.
- DLM으로 일일 snapshot을 생성하고 Stage 기본 보존 기간은 기존 PostgreSQL 정책과 동일하게 7일로 둔다.

### 4.2 Container와 Service Connect

- 이미지: `pgvector/pgvector:pg17@sha256:` 뒤에 lowercase 64자리 digest를 붙인 형식
- Service Connect discovery name/client alias: `ai-postgres`
- 내부 port: `5432`
- database: `cosmos`
- health check: `pg_isready -U "$POSTGRES_USER" -d cosmos`
- 외부 DNS, ALB Target Group, public IP는 생성하지 않는다.

### 4.3 Secret

새 Secret metadata `/cosmos-v2/{environment}/ai-postgres`를 생성한다.

```json
{
  "username": "cosmos",
  "password": "운영자가 생성한 비밀번호"
}
```

데이터베이스 이름 `cosmos`는 비민감 고정값이므로 Secret에 넣지 않는다. AI PostgreSQL Task와 FastAPI execution role만 이 Secret을 읽을 수 있다.

## 5. 애플리케이션 런타임 계약

### 5.1 Spring

비민감 환경 변수는 다음과 같다.

```text
SPRING_PROFILES_ACTIVE=prod
DB_URL=jdbc:mysql://${aws_db_instance.mysql.address}:3306/cosmos
AI_SERVER_BASE_URL=http://fastapi:8000
JUDGE0_BASE_URL=http://judge-api:2358
SENTRY_ENVIRONMENT=stage 또는 prod
SPRING_JPA_OPEN_IN_VIEW=false
```

`/cosmos-v2/{environment}/spring`의 JSON key를 다음 실제 환경 변수로 개별 주입한다.

| Secret key | Container 환경 변수 |
| --- | --- |
| `db_username` | `DB_USERNAME` |
| `db_password` | `DB_PASSWORD` |
| `kakao_client_id` | `KAKAO_CLIENT_ID` |
| `kakao_client_secret` | `KAKAO_CLIENT_SECRET` |
| `kakao_redirect_uri` | `KAKAO_REDIRECT_URI` |
| `jwt_secret` | `JWT_SECRET` |

Backend Valkey endpoint와 port는 이번 Task Definition에 주입하지 않는다. ALB health path는 prod context path를 반영해 `/api/actuator/health`로 변경한다.

### 5.2 FastAPI

비민감 환경 변수는 다음과 같다.

```text
DB_HOST=ai-postgres
DB_PORT=5432
DB_NAME=cosmos
DB_ECHO=false
DB_POOL_SIZE=5
DB_MAX_OVERFLOW=5
BACKEND_URL=http://spring:8080/api
JUDGE0_URL=http://judge-api:2358
MOCK_LLM=false
BATCH_ENABLED=false
BATCH_TIMEZONE=Asia/Seoul
BATCH_CONCURRENCY=5
LOG_LEVEL=INFO
```

`/cosmos-v2/{environment}/ai-postgres`의 `username`, `password`를 각각 `DB_USER`, `DB_PASSWORD`로 주입한다. `/cosmos-v2/{environment}/fastapi`에서는 `gemini_api_key`를 `GEMINI_API_KEY`로 주입한다. 선택적인 LangSmith 사용을 위해 `langsmith_api_key`도 key별로 주입할 수 있지만, 값이 없는 key를 필수 참조하면 Task 시작이 실패하므로 이번 초기 계약에는 포함하지 않는다.

현재 사용되지 않는 `FASTAPI_SECRET_JSON`, `JUDGE_API_URL`, `DATABASE_URL`은 주입하지 않는다.

FastAPI의 batch 기능이 Spring을 호출할 수 있도록 Spring도 Service Connect server로 등록하고 `spring:8080` client alias를 제공한다. FastAPI→Spring TCP `8080` SG 참조를 추가한다. 외부 Stage 서브도메인을 내부 호출에 사용하지 않으므로 Stage와 Prod가 같은 런타임 계약을 유지한다.

### 5.3 Judge API와 Worker

공통 비민감 변수는 PostgreSQL/Redis Service Connect 주소, `RAILS_ENV=production`, `RESQUE_NAMESPACE=${var.environment}:judge0`다. Judge API에는 `PORT=2358`, Worker에는 초기 `COUNT=2`, `INTERVAL=0.1`을 추가한다.

`/cosmos-v2/{environment}/judge-api`의 `secret_key_base`를 `SECRET_KEY_BASE`로 key별 주입한다. `AUTHN_TOKEN`, `AUTHZ_TOKEN`은 Stage 공개 테스트 정책이 확정되기 전까지 필수 참조하지 않는다. Judge PostgreSQL/Redis credential은 기존 Secret key별 주입을 유지한다.

앱이 읽지 않는 `JUDGE_API_SECRET_JSON`, `JUDGE_WORKER_SECRET_JSON`은 제거한다.

Judge 시작 스크립트가 `/api/environment`와 `/api/tmp`에 쓰므로 Judge API와 Worker만 `readonlyRootFilesystem=false`로 설정한다. Spring과 FastAPI는 read-only root filesystem을 유지한다. 존재하지 않는 `/app/healthcheck.sh` Worker health check는 제거하고 essential process 종료와 ECS Service 상태, 실제 queue smoke test로 검증한다.

## 6. 네트워크와 IAM

- `ai-postgres` Task SG는 FastAPI Task SG에서 오는 TCP `5432`만 허용한다.
- FastAPI Task SG는 `ai-postgres` SG의 TCP `5432`로 egress할 수 있다.
- Spring Task SG는 FastAPI Task SG에서 오는 TCP `8080`을 허용한다.
- `ai-postgres` host SG는 ECS agent, ECR pull, CloudWatch Logs, SSM에 필요한 기존 상태 저장 host 규칙을 재사용한다.
- FastAPI execution role은 FastAPI Secret과 AI PostgreSQL Secret만 읽는다.
- AI PostgreSQL execution role은 AI PostgreSQL Secret만 읽는다.
- Spring은 RDS SG의 TCP `3306`과 FastAPI/Judge Service Connect만 사용한다.
- Backend Valkey SG와 IAM user/policy는 그대로 보존하지만 Spring Task와 연결하지 않는다.

실제 Stage no-destroy plan 검토 결과 기존 Spring→Valkey SG ingress 6379/6380도 기반 리소스로 보존한다. Spring Task에는 Valkey endpoint/port를 주입하지 않으므로 애플리케이션 연결은 활성화되지 않는다. SG 규칙 제거는 기존 리소스 삭제가 허용되는 별도 변경으로 다룬다.

## 7. Migration 및 배포 순서

1. 모든 활성화 flag가 `false`인 상태에서 Terraform 구조 변경을 plan/apply한다.
2. `/ai-postgres`, `/spring`, `/fastapi`, `/judge-api`, `/judge-postgres`, `/judge-redis` Secret에 `AWSCURRENT` 값을 등록한다.
3. pgvector/PostgreSQL/Redis 공식 이미지의 immutable digest를 확정한다.
4. `enable_stateful_services=true`로 AI PostgreSQL, Judge PostgreSQL, Judge Redis를 시작한다.
5. AI 이미지와 동일 환경 계약으로 one-off ECS Task `alembic upgrade head`를 실행한다.
6. `enable_phase2_services=true`로 Judge API를 먼저 시작하고 FastAPI, Spring 순서로 안정화한다.
7. Spring은 첫 기동의 Hibernate `ddl-auto=update`로 빈 RDS `cosmos` schema를 생성한다.
8. Judge Worker capacity와 Worker Service는 별도 flag로 마지막에 활성화한다.

CLI `-var` 누락으로 Service 삭제가 계획되지 않도록 활성화 값과 image digest는 gitignored `stage.auto.tfvars`에 저장한다. Secret 값은 tfvars에 넣지 않는다.

## 8. 장애와 복구

- AI PostgreSQL Task 실패 시 ECS가 같은 전용 EC2에서 Task를 재시작하고 기존 EBS 데이터를 다시 mount한다.
- AI PostgreSQL EC2 자체 장애 시 자동 무상태 교체를 시도하지 않는다. EBS 보존 상태를 확인한 후 운영자가 instance와 attachment를 복구한다.
- EBS 손상 또는 운영자 오류는 최신 DLM snapshot으로 새 EBS를 복구한다.
- AI migration 실패 시 FastAPI Service를 활성화하지 않고 migration log와 revision을 수정한다.
- Secret key 누락 시 Task가 시작되지 않는 것을 정상적인 fail-closed 동작으로 본다.
- Backend Valkey 장애는 현재 애플리케이션에 연결되지 않았으므로 BE 가용성에 영향을 주지 않는다.

## 9. 테스트와 검증

### 9.1 Terraform 정적·단위 테스트

- `ai-postgres` EC2 1대, EBS 1개, Task Definition 1개, ECS Service 1개 생성 계약
- `enable_stateful_services=false`일 때 상태 저장 Task/Service 비활성 계약
- AI PostgreSQL image가 `@sha256:` digest가 아니면 plan 거부
- DB 이름이 `cosmos`로 고정되고 외부 공개가 없는지 확인
- FastAPI→AI PostgreSQL TCP `5432` SG 참조 확인
- FastAPI→Spring TCP `8080`과 `spring:8080` Service Connect alias 확인
- 환경별 Secret 이름과 execution role 최소 권한 확인
- Spring/FastAPI/Judge의 실제 환경 변수 이름과 제거 대상 legacy 이름 확인
- Spring health path `/api/actuator/health` 확인
- Judge API/Worker writable root와 Worker의 잘못된 health check 제거 확인
- 기존 Stage/Prod 격리, Worker, frontend, ALB 테스트 회귀 확인

### 9.2 실제 Stage 검증

- `terraform plan`에서 기존 RDS, Valkey, Judge EBS의 destroy/replace가 없는지 확인
- `ai-postgres` Service가 `RUNNING`이고 `pg_isready`가 성공하는지 확인
- FastAPI one-off Alembic migration 성공 확인
- FastAPI `/health`와 `/db-check` 확인
- Spring `/api/actuator/health` 및 RDS 연결 확인
- Judge API 문서와 submission→queue→Worker 처리 확인
- Backend Valkey가 존재하지만 Spring Task Definition에는 Valkey 환경 변수가 없는지 확인

## 10. 이번 범위에서 제외하는 항목

- Backend Valkey 애플리케이션 연동
- AI PostgreSQL 고가용성, 자동 failover, read replica
- DB schema/data migration 자동 CI/CD
- FE Stage CD 구현
- BE에 하드코딩된 OAuth 완료 redirect와 CORS의 애플리케이션 코드 수정
- Queue 지표 기반 Worker Auto Scaling

위 제외 항목은 Stage 기동 이후 별도 변경으로 다룬다.
