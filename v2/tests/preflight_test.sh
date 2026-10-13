#!/usr/bin/env bash
set -euo pipefail

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

cat >"$TEST_DIR/aws" <<'FAKE_AWS'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${FAIL_MODE:-}" == "missing_digest" && "$1 $2" == "ecr describe-images" && "$*" == *"spring"* ]]; then exit 1; fi
if [[ "$1 $2" == "secretsmanager list-secret-version-ids" ]]; then
  if [[ "${FAIL_MODE:-}" == "missing_secret" && "$*" == *"spring"* ]]; then
    printf 'None\n'
  elif [[ "${FAIL_MODE:-}" == "missing_ai_secret" && "$*" == *"ai-postgres"* ]]; then
    printf 'None\n'
  else
    printf 'version-id\n'
  fi
fi
if [[ "${FAIL_MODE:-}" == "capacity" && "$1 $2" == "ecs describe-capacity-providers" ]]; then exit 1; fi
if [[ "${FAIL_MODE:-}" == "frontend_bucket" && "$1 $2" == "s3api head-bucket" ]]; then exit 1; fi
if [[ "$1 $2" == "cloudfront get-distribution" ]]; then
  if [[ "${FAIL_MODE:-}" == "cloudfront_disabled" ]]; then
    printf 'Deployed\tFalse\tstage.cosmoscode.site\n'
  elif [[ "${FAIL_MODE:-}" == "cloudfront_alias" ]]; then
    printf 'Deployed\tTrue\twrong.cosmoscode.site\n'
  elif [[ "${TARGET_ENVIRONMENT:-stage}" == "stage" ]]; then
    printf 'Deployed\tTrue\tstage.cosmoscode.site\n'
  else
    printf 'Deployed\tTrue\tNone\n'
  fi
fi
if [[ "$1 $2" == "elbv2 describe-target-health" ]]; then
  [[ "${FAIL_MODE:-}" != "target_health" ]] || { printf 'unhealthy\n'; exit 0; }
  printf 'healthy\n'
fi
if [[ "$1 $2" == "ecs list-container-instances" ]]; then printf 'arn:aws:ecs:ap-northeast-2:123456789012:container-instance/worker\n'; fi
if [[ "$1 $2" == "ecs describe-container-instances" ]]; then printf 'ACTIVE\n'; fi
if [[ "$1 $2" == "ecs describe-capacity-providers" ]]; then printf 'ACTIVE\tACTIVE\n'; fi
FAKE_AWS

cat >"$TEST_DIR/terraform" <<'FAKE_TERRAFORM'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == "-chdir=${EXPECTED_TERRAFORM_DIR:?EXPECTED_TERRAFORM_DIR is required}" ]] || exit 2
if [[ "${FAIL_MODE:-}" == "auth" ]]; then exit 1; fi
if [[ "${FAIL_MODE:-}" == "v1state" ]]; then
  printf 'aws_instance.main_server\n'
elif [[ "${CHECK_JUDGE_WORKER:-false}" == "true" ]]; then
  printf '%s\n' \
    'module.environment.aws_ecs_cluster.main' \
    'module.environment.aws_autoscaling_group.worker_on_demand[0]' \
    'module.environment.aws_autoscaling_group.worker_spot[0]' \
    'module.environment.aws_ecs_capacity_provider.worker_on_demand[0]' \
    'module.environment.aws_ecs_capacity_provider.worker_spot[0]'
else
  printf 'module.environment.aws_ecs_cluster.main\n'
fi
FAKE_TERRAFORM
chmod +x "$TEST_DIR/aws" "$TEST_DIR/terraform"

DIGEST="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

run_preflight() {
  local target_environment="${TARGET_ENVIRONMENT:-stage}"
  local expected_workspace="KTB4-9th-Cloud-v2-${target_environment}"
  local frontend_url="https://stage.cosmoscode.site"
  local secret_prefix="/cosmos-v2/${SECRET_ENVIRONMENT_OVERRIDE:-$target_environment}"
  if [[ "$target_environment" == "prod" ]]; then
    frontend_url="https://dprod.cloudfront.net"
  fi

  AWS_BIN="$TEST_DIR/aws" TERRAFORM_BIN="$TEST_DIR/terraform" \
  EXPECTED_TERRAFORM_DIR="$(pwd)/v2/environments/${target_environment}" \
  AWS_REGION="ap-northeast-2" \
  TARGET_ENVIRONMENT="$target_environment" EXPECTED_WORKSPACE="${EXPECTED_WORKSPACE:-$expected_workspace}" \
  FRONTEND_BUCKET="cosmos-v2-${target_environment}-frontend-123456789012" \
  CLOUDFRONT_DISTRIBUTION_ID="DISTRIBUTION" FRONTEND_URL="${FRONTEND_URL:-$frontend_url}" \
  ALB_TARGET_GROUP_ARN="arn:aws:elasticloadbalancing:ap-northeast-2:123456789012:targetgroup/cosmos-v2-${target_environment}-spring/test" \
  SPRING_REPOSITORY="cosmos-v2/spring" SPRING_IMAGE_DIGEST="$DIGEST" \
  FASTAPI_REPOSITORY="cosmos-v2/fastapi" FASTAPI_IMAGE_DIGEST="$DIGEST" \
  JUDGE_REPOSITORY="cosmos-v2/judge" JUDGE_IMAGE_DIGEST="$DIGEST" \
  JUDGE_POSTGRES_IMAGE="${JUDGE_POSTGRES_IMAGE_OVERRIDE:-public.ecr.aws/docker/library/postgres@$DIGEST}" \
  JUDGE_REDIS_IMAGE="public.ecr.aws/valkey/valkey@$DIGEST" \
  AI_POSTGRES_IMAGE="${AI_POSTGRES_IMAGE_OVERRIDE:-pgvector/pgvector:pg17@$DIGEST}" \
  SPRING_SECRET_ARN="arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:${secret_prefix}/spring-test" \
  FASTAPI_SECRET_ARN="arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:${secret_prefix}/fastapi-test" \
  AI_POSTGRES_SECRET_ARN="arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:/cosmos-v2/${AI_SECRET_ENVIRONMENT_OVERRIDE:-$target_environment}/ai-postgres-test" \
  JUDGE_API_SECRET_ARN="arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:${secret_prefix}/judge-api-test" \
  JUDGE_POSTGRES_SECRET_ARN="arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:${secret_prefix}/judge-postgres-test" \
  JUDGE_REDIS_SECRET_ARN="arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:${secret_prefix}/judge-redis-test" \
  HEALTH_ENDPOINTS_VERIFIED="${HEALTH_ENDPOINTS_VERIFIED:-true}" \
  MYSQL_BOOTSTRAP_VERIFIED="${MYSQL_BOOTSTRAP_VERIFIED:-true}" \
  SERVICE_CONNECT_BOOTSTRAP_VERIFIED="${SERVICE_CONNECT_BOOTSTRAP_VERIFIED:-true}" \
  FAIL_MODE="${FAIL_MODE:-}" bash v2/scripts/preflight.sh
}

run_worker_preflight() {
  CHECK_JUDGE_WORKER=true \
  ECS_CLUSTER_NAME="${ECS_CLUSTER_NAME_OVERRIDE:-cosmos-v2-${TARGET_ENVIRONMENT:-stage}-cluster}" \
  WORKER_ON_DEMAND_CAPACITY_PROVIDER="cosmos-v2-${TARGET_ENVIRONMENT:-stage}-judge-worker-on-demand" \
  WORKER_SPOT_CAPACITY_PROVIDER="cosmos-v2-${TARGET_ENVIRONMENT:-stage}-judge-worker-spot" \
  WORKER_IMAGE_CONTRACT_VERIFIED="${WORKER_IMAGE_CONTRACT_VERIFIED:-true}" \
  WORKER_SIGTERM_VERIFIED="${WORKER_SIGTERM_VERIFIED:-true}" \
  WORKER_SANDBOX_VERIFIED="${WORKER_SANDBOX_VERIFIED:-true}" \
  run_preflight
}

expect_failure() {
  local name="$1"
  shift
  if "$@"; then
    printf '실패해야 하는 사례가 통과했습니다: %s\n' "$name" >&2
    exit 1
  fi
}

run_preflight
TARGET_ENVIRONMENT=prod run_preflight
TARGET_ENVIRONMENT=staging expect_failure "허용되지 않은 환경" run_preflight
EXPECTED_WORKSPACE=KTB4-9th-Cloud-v2-prod expect_failure "stage와 prod Workspace 혼용" run_preflight
SECRET_ENVIRONMENT_OVERRIDE=prod expect_failure "stage와 prod Secret 혼용" run_preflight
FRONTEND_URL=https://wrong.cosmoscode.site expect_failure "stage frontend URL 불일치" run_preflight
FAIL_MODE=frontend_bucket expect_failure "frontend bucket 조회 실패" run_preflight
FAIL_MODE=cloudfront_disabled expect_failure "CloudFront 비활성" run_preflight
FAIL_MODE=cloudfront_alias expect_failure "CloudFront alias 불일치" run_preflight
FAIL_MODE=target_health expect_failure "ALB target 비정상" run_preflight
FAIL_MODE=missing_digest expect_failure "ECR digest 누락" run_preflight
JUDGE_POSTGRES_IMAGE_OVERRIDE=postgres:16 expect_failure "PostgreSQL image digest 고정 누락" run_preflight
AI_POSTGRES_IMAGE_OVERRIDE=pgvector/pgvector:pg17 expect_failure "AI PostgreSQL image digest 고정 누락" run_preflight
AI_SECRET_ENVIRONMENT_OVERRIDE=prod expect_failure "AI PostgreSQL Secret 환경 혼용" run_preflight
FAIL_MODE=missing_secret expect_failure "AWSCURRENT 누락" run_preflight
FAIL_MODE=missing_ai_secret expect_failure "AI PostgreSQL AWSCURRENT 누락" run_preflight
FAIL_MODE=auth expect_failure "Terraform Cloud 인증 실패" run_preflight
FAIL_MODE=v1state expect_failure "v1 state 주소" run_preflight
HEALTH_ENDPOINTS_VERIFIED=false expect_failure "health 확인 누락" run_preflight
MYSQL_BOOTSTRAP_VERIFIED=false expect_failure "MySQL bootstrap 확인 누락" run_preflight
SERVICE_CONNECT_BOOTSTRAP_VERIFIED=false expect_failure "Service Connect bootstrap 재배포 확인 누락" run_preflight

run_worker_preflight
ECS_CLUSTER_NAME_OVERRIDE=cosmos-v2-prod-cluster expect_failure "stage와 prod Cluster 혼용" run_worker_preflight
FAIL_MODE=capacity expect_failure "Worker capacity 상태 조회 실패" run_worker_preflight
WORKER_IMAGE_CONTRACT_VERIFIED=false expect_failure "Worker image 계약 확인 누락" run_worker_preflight
WORKER_SIGTERM_VERIFIED=false expect_failure "Worker SIGTERM 확인 누락" run_worker_preflight
WORKER_SANDBOX_VERIFIED=false expect_failure "Worker sandbox 확인 누락" run_worker_preflight

printf 'preflight script tests passed\n'
