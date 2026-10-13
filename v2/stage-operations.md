# COSMOS v2 Stage 운영 절차

## 1. 목적

이 문서는 공용 VPC 안에 `stage`와 `prod`를 분리한 COSMOS v2 인프라를 안전하게 생성하고, 비어 있는 데이터베이스에서 애플리케이션 검증을 시작하는 절차를 정의한다. Terraform 코드는 HCP Terraform Workspace별 작업 디렉터리에서 실행하며, 이 문서의 명령은 로컬 확인용이다.

## 2. Workspace와 실행 디렉터리

| 환경 | HCP Terraform Workspace | 작업 디렉터리 | 역할 |
| --- | --- | --- | --- |
| 공용 | `KTB4-9th-Cloud-v2-shared` | `v2/environments/shared` | VPC, subnet, NAT Gateway, ECR, Route 53 조회, 서울 ALB용 ACM 인증서 |
| Stage | `KTB4-9th-Cloud-v2-stage` | `v2/environments/stage` | Stage ECS, ALB, 데이터 계층, S3, CloudFront |
| Prod | `KTB4-9th-Cloud-v2-prod` | `v2/environments/prod` | Prod ECS, ALB, 데이터 계층, S3, CloudFront |

`stage`와 `prod`는 `terraform_remote_state`로 공용 Workspace의 output을 읽는다. 따라서 적용 순서는 반드시 `shared → stage → prod`로 유지한다. Workspace 이름 또는 working directory를 바꾸면 remote state 계약도 함께 검토해야 한다.

## 3. 최초 구축 순서

1. `shared` Workspace에 AWS 자격 증명과 HCP Terraform 연결을 설정한다.
2. `v2/environments/shared`에서 plan을 검토하고 apply한다.
3. Shared output의 `regional_wildcard_certificate_arn`이 `ap-northeast-2` 인증서이고 `ISSUED` 상태인지 확인한다. 기존 `us-east-1` 인증서는 CloudFront 전용으로 유지한다.
4. `stage` Workspace가 `shared` Workspace의 state를 읽을 권한이 있는지 확인한다.
5. 모든 활성화 변수를 `false`로 둔 채 Stage 기반 리소스를 먼저 apply한다.
6. 생성된 Secret에 실제 값을 직접 등록한다. Terraform 코드·변수·state에는 비밀값을 입력하지 않는다.
7. 프론트엔드와 컨테이너 이미지를 업로드한 뒤, 아래 활성화 순서대로 서비스를 단계적으로 apply한다.
8. Stage 검증이 끝난 뒤 같은 절차와 같은 image digest로 Prod를 구축한다.

## 4. 서비스 활성화 순서

한 번에 모든 토글을 켜지 않고 아래 순서마다 plan, apply, 상태 확인을 반복한다.

1. 기본 apply에서 생성되는 RDS, Valkey, AI PostgreSQL·Judge PostgreSQL·Judge Redis 전용 EC2와 EBS의 준비 상태를 확인한다.
2. `enable_stateful_services=true`로 AI PostgreSQL, Judge PostgreSQL, Judge Redis Task를 각각 1개 실행한다.
   - 두 PostgreSQL Task는 EBS mount 아래의 `PGDATA=/var/lib/postgresql/data/pgdata`를 사용한다. 처음 기동할 때 이 하위 디렉터리에 데이터가 생성되는지 로그로 확인한다.
3. AI image와 같은 환경 계약의 one-off Task로 `alembic upgrade head`를 실행하고, 실패하면 FastAPI를 정상 상태로 선언하지 않는다.
4. `enable_phase2_services=true`로 Judge API, FastAPI, Spring API를 각각 1개 실행한 뒤 이 순서로 안정화를 확인한다.
5. Service Connect 이름으로 Spring→FastAPI·Judge, FastAPI→Spring·Judge 호출을 확인한다.
6. `enable_judge_worker_capacity=true`: Worker용 On-Demand 1대와 확장 가능한 Spot 용량 기반을 준비한다.
7. `enable_judge_worker=true`: Worker Task를 1개 실행하고 Queue 처리와 정상 종료를 확인한다.

Worker의 추가 Spot 용량은 최대 7대까지 확장 가능하지만 초기 운영은 On-Demand 1대만 유지한다.

## 5. 배포 산출물과 Secret

- 각 컨테이너는 태그가 아니라 불변 image digest를 Terraform 변수에 전달한다.
- Stage Secret 경로는 `/cosmos-v2/stage/...`, Prod Secret 경로는 `/cosmos-v2/prod/...`를 사용한다.
- Secret은 Terraform이 metadata만 생성한다. 실제 값과 `AWSCURRENT` 버전은 운영자가 AWS Secrets Manager에 등록한다.
- 데이터베이스는 빈 상태를 전제로 하며 기존 데이터 백업·이전은 이번 범위에 포함하지 않는다.
- Backend Valkey는 생성 상태만 확인하고 Spring Task 환경 변수에는 연결하지 않는다. 기존 Spring SG ingress와 IAM metadata는 no-destroy 기반 적용에서 보존한다.

필수 Secret key는 다음과 같다.

| Secret | 필수 JSON key |
| --- | --- |
| `/cosmos-v2/{env}/spring` | `db_username`, `db_password`, `kakao_client_id`, `kakao_client_secret`, `kakao_redirect_uri`, `jwt_secret` |
| `/cosmos-v2/{env}/fastapi` | `gemini_api_key` |
| `/cosmos-v2/{env}/ai-postgres` | `username`, `password` |
| `/cosmos-v2/{env}/judge-api` | `secret_key_base` |
| `/cosmos-v2/{env}/judge-postgres` | `username`, `password`, `database` |
| `/cosmos-v2/{env}/judge-redis` | `password` |

실제 값은 콘솔 또는 승인된 운영 절차로 등록하고 Terraform 변수·plan·state에는 넣지 않는다.

## 6. 프론트엔드 배포

1. 해당 환경 output의 `frontend_bucket_name`에 정적 파일을 동기화한다.
2. 해시가 포함된 정적 자산은 장기 캐시하고 `index.html`에는 `Cache-Control: no-cache` 또는 짧은 TTL을 설정한다. SPA rewrite 응답도 이 metadata를 사용한다.
3. 배포 후 CloudFront invalidation은 우선 `/index.html`에만 수행한다. 전면 무효화 `/*`는 필요한 경우에만 사용한다.
4. Stage 주소 `https://stage.cosmoscode.site`에서 SPA fallback, `/api/*`, `/auth/*` 라우팅을 확인한다.

S3 버킷은 공개하지 않으며 CloudFront OAC를 통해서만 읽는다. ALB의 HTTP `80`은 CloudFront origin-facing prefix list에서만 허용한다. Stage 서비스 검증용 HTTPS `443`은 아래 절차에 따라 인터넷에 임시 공개한다.

## 7. Stage 서비스 HTTPS 배포

서울 ALB 인증서가 먼저 발급되어야 하므로 Shared와 Stage를 다음 순서로 적용한다.

```bash
terraform -chdir=v2/environments/shared init
terraform -chdir=v2/environments/shared plan
terraform -chdir=v2/environments/shared apply
terraform -chdir=v2/environments/shared output regional_wildcard_certificate_arn
```

ACM 인증서 발급이 완료되면 실제 ECR digest로 Stage를 계획하고 적용한다.

아래 명령은 상태 저장 서비스와 애플리케이션 활성화 값을 모두 반복한다. CLI `-var`로 활성화한 값을 다음 실행에서 생략하면 기본값 `false`로 돌아가 서비스 삭제가 계획될 수 있으므로, 실제 운영에서는 같은 값들을 HCP Terraform Workspace 변수 또는 하나의 비밀값 없는 `.tfvars` 파일에 저장하고 모든 plan/apply에서 재사용한다.

저장소의 `*.auto.tfvars`는 gitignore 대상이다. 예를 들어 `v2/environments/stage/stage.auto.tfvars`에 다음 비민감 값만 보관한다.

```hcl
enable_stateful_services = true
ai_postgres_image        = "pgvector/pgvector:pg17@sha256:<64자리 digest>"
judge_postgres_image     = "postgres@sha256:<64자리 digest>"
judge_redis_image        = "valkey@sha256:<64자리 digest>"
enable_phase2_services   = true
spring_image_digest      = "sha256:<64자리 digest>"
fastapi_image_digest     = "sha256:<64자리 digest>"
judge_image_digest       = "sha256:<64자리 digest>"
```

```bash
terraform -chdir=v2/environments/stage init
terraform -chdir=v2/environments/stage plan \
  -var='enable_stateful_services=true' \
  -var='ai_postgres_image=<pgvector-image@sha256:...>' \
  -var='judge_postgres_image=<postgres-image@sha256:...>' \
  -var='judge_redis_image=<redis-image@sha256:...>' \
  -var='enable_phase2_services=true' \
  -var='spring_image_digest=sha256:d2e85f1fb9eeaa8f367dd79fd78f0731cba3618b0d09e1573eaa5f913a2575f9' \
  -var='fastapi_image_digest=sha256:6f763b65c0e0ae84eeb36572ded74a9e39a97ee3ce535f41c9b7bcdf5dcaa861' \
  -var='judge_image_digest=sha256:e44c0adc000802b40bffc82043d922b934294e5d147fb86dc220ef195e99416b'

terraform -chdir=v2/environments/stage apply \
  -var='enable_stateful_services=true' \
  -var='ai_postgres_image=<pgvector-image@sha256:...>' \
  -var='judge_postgres_image=<postgres-image@sha256:...>' \
  -var='judge_redis_image=<redis-image@sha256:...>' \
  -var='enable_phase2_services=true' \
  -var='spring_image_digest=sha256:d2e85f1fb9eeaa8f367dd79fd78f0731cba3618b0d09e1573eaa5f913a2575f9' \
  -var='fastapi_image_digest=sha256:6f763b65c0e0ae84eeb36572ded74a9e39a97ee3ce535f41c9b7bcdf5dcaa861' \
  -var='judge_image_digest=sha256:e44c0adc000802b40bffc82043d922b934294e5d147fb86dc220ef195e99416b'
```

서비스를 활성화하기 전에 각 Stage Secret에 `AWSCURRENT` 값이 등록되어 있고 RDS, AI PostgreSQL, Judge PostgreSQL/Redis가 준비됐는지 확인한다. Backend Valkey는 연결 대상이 아니다. Stage 적용 후 `terraform output stage_service_urls`로 base URL을 확인한다.

세 ECS Service를 처음 동시에 생성하면 Service Connect backend endpoint보다 client Task가 먼저 시작될 수 있다. Judge API가 안정화된 후 FastAPI, Spring 순서로 한 번씩 신규 deployment를 강제해 모든 client Task가 이미 등록된 endpoint를 보고 시작하게 한다.

```bash
CLUSTER=cosmos-v2-stage-cluster

aws ecs wait services-stable \
  --cluster "$CLUSTER" \
  --services cosmos-v2-stage-judge-api \
  --region ap-northeast-2

aws ecs update-service \
  --cluster "$CLUSTER" \
  --service cosmos-v2-stage-fastapi \
  --force-new-deployment \
  --region ap-northeast-2
aws ecs wait services-stable \
  --cluster "$CLUSTER" \
  --services cosmos-v2-stage-fastapi \
  --region ap-northeast-2

aws ecs update-service \
  --cluster "$CLUSTER" \
  --service cosmos-v2-stage-spring \
  --force-new-deployment \
  --region ap-northeast-2
aws ecs wait services-stable \
  --cluster "$CLUSTER" \
  --services cosmos-v2-stage-spring \
  --region ap-northeast-2
```

이 절차와 API→AI·Judge, AI→Judge 호출을 확인한 뒤 preflight의 `SERVICE_CONNECT_BOOTSTRAP_VERIFIED=true`를 설정한다. 이후 기존 backend endpoint가 유지되는 일반 image 교체에는 이 최초 bootstrap 절차를 반복할 필요가 없다. 다음 문서 URL도 함께 점검한다.

| 서비스 | 점검 URL |
| --- | --- |
| Spring Boot | `https://stage-be.cosmoscode.site/swagger-ui/index.html` |
| FastAPI | `https://stage-ai.cosmoscode.site/docs` |
| Judge API | `https://stage-judge.cosmoscode.site/swagger.html` |

문서 화면만 열어보지 말고 Swagger에서 실제 API 요청을 실행해 Host 기반 routing과 브라우저 요청까지 확인한다. 실패하면 ALB 콘솔의 Target Group health reason을 먼저 확인하고, 이어서 `/ecs/cosmos-v2-stage/spring`, `/ecs/cosmos-v2-stage/fastapi`, `/ecs/cosmos-v2-stage/judge-api` CloudWatch Log Group을 확인한다.

AWS CLI가 설치된 환경에서는 다음 명령으로 같은 정보를 조회할 수 있다.

```bash
aws elbv2 describe-target-health --target-group-arn <target-group-arn> --region ap-northeast-2
aws logs tail /ecs/cosmos-v2-stage/spring --since 10m --region ap-northeast-2
aws logs tail /ecs/cosmos-v2-stage/fastapi --since 10m --region ap-northeast-2
aws logs tail /ecs/cosmos-v2-stage/judge-api --since 10m --region ap-northeast-2
```

Stage ALB의 `443/tcp`는 테스트를 위해 `0.0.0.0/0`에 임시 공개되어 있다. 운영 전에는 IP allowlist, WAF 또는 CloudFront 보호 계층으로 교체한다. HTTP `80`은 인터넷 전체에 공개하지 않으며 HTTPS redirect도 제공하지 않는다.

## 8. 적용 전·후 검증

각 환경 apply 전후 다음 형식으로 사전 점검을 실행한다.

```bash
TARGET_ENVIRONMENT=stage \
EXPECTED_WORKSPACE=KTB4-9th-Cloud-v2-stage \
FRONTEND_BUCKET=<stage-bucket> \
FRONTEND_URL=https://stage.cosmoscode.site \
CLOUDFRONT_DISTRIBUTION_ID=<distribution-id> \
ALB_TARGET_GROUP_ARN=<target-group-arn> \
SPRING_REPOSITORY=cosmos-v2/spring SPRING_IMAGE_DIGEST=<sha256:...> \
FASTAPI_REPOSITORY=cosmos-v2/fastapi FASTAPI_IMAGE_DIGEST=<sha256:...> \
JUDGE_REPOSITORY=cosmos-v2/judge JUDGE_IMAGE_DIGEST=<sha256:...> \
AI_POSTGRES_IMAGE=<registry/pgvector@sha256:...> \
JUDGE_POSTGRES_IMAGE=<registry/postgres@sha256:...> \
JUDGE_REDIS_IMAGE=<registry/valkey@sha256:...> \
SPRING_SECRET_ARN=<secret-arn> \
FASTAPI_SECRET_ARN=<secret-arn> \
AI_POSTGRES_SECRET_ARN=<secret-arn> \
JUDGE_API_SECRET_ARN=<secret-arn> \
JUDGE_POSTGRES_SECRET_ARN=<secret-arn> \
JUDGE_REDIS_SECRET_ARN=<secret-arn> \
HEALTH_ENDPOINTS_VERIFIED=true \
MYSQL_BOOTSTRAP_VERIFIED=true \
SERVICE_CONNECT_BOOTSTRAP_VERIFIED=true \
./v2/scripts/preflight.sh
```

Worker를 활성화하는 경우 별도 Worker digest 대신 같은 `JUDGE_IMAGE_DIGEST`와 이미 검사된 `JUDGE_API_SECRET_ARN`을 사용하고, ECS cluster, Capacity Provider와 이미지 계약·SIGTERM·sandbox 확인 변수를 함께 전달한다. 스크립트는 조회만 수행하며 Secret 값이나 Terraform apply를 실행하지 않는다.

## 9. 비용을 멈추는 경계

- 애플리케이션만 중지할 때는 ECS Service desired count를 0으로 내린다.
- Worker를 중지할 때는 Worker Service를 먼저 0으로 내린 뒤 Spot/On-Demand 용량을 축소한다.
- RDS, NAT Gateway, ALB, CloudFront 등은 ECS Task를 0으로 내려도 비용이 계속 발생한다.
- 공용 환경은 Stage와 Prod가 함께 사용하므로 한 환경을 정리한다는 이유로 `shared`를 destroy하지 않는다.
- stateful 리소스는 `prevent_destroy`와 백업 정책을 확인한 뒤 별도 변경 절차로 다룬다.

## 10. State 안전 수칙

- Workspace 간 state 이동이나 수동 state 명령은 사전 백업과 별도 검토 없이 수행하지 않는다.
- `stage`와 `prod`의 리소스를 같은 Workspace에서 관리하지 않는다.
- `shared` output 이름을 변경하면 두 환경의 plan을 모두 확인한다.
- 콘솔에서 수정한 값은 다음 plan에서 drift로 확인하고 코드에 반영할지 되돌릴지 결정한다.
