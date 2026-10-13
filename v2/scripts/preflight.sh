#!/usr/bin/env bash
set -euo pipefail

AWS_BIN="${AWS_BIN:-aws}"
TERRAFORM_BIN="${TERRAFORM_BIN:-terraform}"
AWS_REGION="${AWS_REGION:-ap-northeast-2}"
V2_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'preflight 실패: %s\n' "$1" >&2
  exit 1
}

target_environment="${TARGET_ENVIRONMENT:?TARGET_ENVIRONMENT is required}"
[[ "$target_environment" == "stage" || "$target_environment" == "prod" ]] || fail "TARGET_ENVIRONMENT은 stage 또는 prod여야 합니다."
TERRAFORM_DIR="${TERRAFORM_DIR:-${V2_ROOT}/environments/${target_environment}}"

expected_workspace="${EXPECTED_WORKSPACE:?EXPECTED_WORKSPACE is required}"
[[ "$expected_workspace" == "KTB4-9th-Cloud-v2-${target_environment}" ]] || fail "대상 환경과 Terraform Workspace가 일치하지 않습니다."

frontend_bucket="${FRONTEND_BUCKET:?FRONTEND_BUCKET is required}"
[[ "$frontend_bucket" == *"-${target_environment}-frontend-"* ]] || fail "frontend bucket이 대상 환경과 일치하지 않습니다."

frontend_url="${FRONTEND_URL:?FRONTEND_URL is required}"
if [[ "$target_environment" == "stage" ]]; then
  [[ "$frontend_url" == "https://stage.cosmoscode.site" ]] || fail "stage frontend URL은 https://stage.cosmoscode.site여야 합니다."
else
  [[ "$frontend_url" == https://* ]] || fail "prod frontend URL은 HTTPS URL이어야 합니다."
fi

"$AWS_BIN" s3api head-bucket --bucket "$frontend_bucket" >/dev/null || fail "frontend S3 bucket 조회에 실패했습니다."

cloudfront_state=$(
  "$AWS_BIN" cloudfront get-distribution \
    --id "${CLOUDFRONT_DISTRIBUTION_ID:?CLOUDFRONT_DISTRIBUTION_ID is required}" \
    --query 'Distribution.[Status,DistributionConfig.Enabled,DistributionConfig.Aliases.Items]' \
    --output text
) || fail "CloudFront distribution 조회에 실패했습니다."
read -r cloudfront_status cloudfront_enabled cloudfront_aliases <<<"$cloudfront_state"
[[ "$cloudfront_status" == "Deployed" && "$cloudfront_enabled" == "True" ]] || fail "CloudFront distribution이 Deployed/Enabled 상태가 아닙니다."
if [[ "$target_environment" == "stage" ]]; then
  grep -qw 'stage.cosmoscode.site' <<<"$cloudfront_aliases" || fail "Stage CloudFront alias가 stage.cosmoscode.site가 아닙니다."
fi

target_health=$(
  "$AWS_BIN" elbv2 describe-target-health \
    --region "$AWS_REGION" \
    --target-group-arn "${ALB_TARGET_GROUP_ARN:?ALB_TARGET_GROUP_ARN is required}" \
    --query 'TargetHealthDescriptions[].TargetHealth.State' \
    --output text | tr '\t' '\n'
) || fail "ALB target health 조회에 실패했습니다."
[[ -n "$target_health" ]] || fail "ALB Target Group에 등록된 target이 없습니다."
if grep -qv '^healthy$' <<<"$target_health"; then
  fail "ALB Target Group에 healthy가 아닌 target이 있습니다."
fi

for attestation in HEALTH_ENDPOINTS_VERIFIED MYSQL_BOOTSTRAP_VERIFIED SERVICE_CONNECT_BOOTSTRAP_VERIFIED; do
  [[ "${!attestation:-}" == "true" ]] || fail "$attestation=true 확인이 필요합니다."
done

images=(
  "${SPRING_REPOSITORY:?SPRING_REPOSITORY is required}|${SPRING_IMAGE_DIGEST:?SPRING_IMAGE_DIGEST is required}"
  "${FASTAPI_REPOSITORY:?FASTAPI_REPOSITORY is required}|${FASTAPI_IMAGE_DIGEST:?FASTAPI_IMAGE_DIGEST is required}"
  "${JUDGE_REPOSITORY:?JUDGE_REPOSITORY is required}|${JUDGE_IMAGE_DIGEST:?JUDGE_IMAGE_DIGEST is required}"
)

for item in "${images[@]}"; do
  repository="${item%%|*}"
  digest="${item#*|}"
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "유효하지 않은 image digest: $repository"
  "$AWS_BIN" ecr describe-images \
    --region "$AWS_REGION" \
    --repository-name "$repository" \
    --image-ids "imageDigest=$digest" >/dev/null || fail "ECR image digest를 찾지 못했습니다: $repository"
done

for stateful_image in \
  "${AI_POSTGRES_IMAGE:?AI_POSTGRES_IMAGE is required}" \
  "${JUDGE_POSTGRES_IMAGE:?JUDGE_POSTGRES_IMAGE is required}" \
  "${JUDGE_REDIS_IMAGE:?JUDGE_REDIS_IMAGE is required}"; do
  [[ "$stateful_image" =~ ^[^[:space:]]+@sha256:[0-9a-f]{64}$ ]] || fail "상태 저장 image는 @sha256 digest로 고정해야 합니다."
done

secret_arns=(
  "${SPRING_SECRET_ARN:?SPRING_SECRET_ARN is required}"
  "${FASTAPI_SECRET_ARN:?FASTAPI_SECRET_ARN is required}"
  "${AI_POSTGRES_SECRET_ARN:?AI_POSTGRES_SECRET_ARN is required}"
  "${JUDGE_API_SECRET_ARN:?JUDGE_API_SECRET_ARN is required}"
  "${JUDGE_POSTGRES_SECRET_ARN:?JUDGE_POSTGRES_SECRET_ARN is required}"
  "${JUDGE_REDIS_SECRET_ARN:?JUDGE_REDIS_SECRET_ARN is required}"
)

for secret_arn in "${secret_arns[@]}"; do
  [[ "$secret_arn" == *":secret:/cosmos-v2/${target_environment}/"* ]] || fail "Secret ARN이 대상 환경과 일치하지 않습니다."
  "$AWS_BIN" secretsmanager list-secret-version-ids \
    --region "$AWS_REGION" \
    --secret-id "$secret_arn" \
    --query 'Versions[?contains(VersionStages, `AWSCURRENT`)].VersionId | [0]' \
    --output text | grep -qvE '^(None|null)?$' || fail "AWSCURRENT Secret version이 없습니다."
done

if [[ "${CHECK_JUDGE_WORKER:-false}" == "true" ]]; then
  for attestation in WORKER_IMAGE_CONTRACT_VERIFIED WORKER_SIGTERM_VERIFIED WORKER_SANDBOX_VERIFIED; do
    [[ "${!attestation:-}" == "true" ]] || fail "$attestation=true 확인이 필요합니다."
  done

  cluster_name="${ECS_CLUSTER_NAME:?ECS_CLUSTER_NAME is required}"
  on_demand_provider="${WORKER_ON_DEMAND_CAPACITY_PROVIDER:?WORKER_ON_DEMAND_CAPACITY_PROVIDER is required}"
  spot_provider="${WORKER_SPOT_CAPACITY_PROVIDER:?WORKER_SPOT_CAPACITY_PROVIDER is required}"
  [[ "$cluster_name" == "cosmos-v2-${target_environment}-cluster" ]] || fail "ECS Cluster가 대상 환경과 일치하지 않습니다."
  [[ "$on_demand_provider" == "cosmos-v2-${target_environment}-judge-worker-on-demand" ]] || fail "On-Demand Capacity Provider가 대상 환경과 일치하지 않습니다."
  [[ "$spot_provider" == "cosmos-v2-${target_environment}-judge-worker-spot" ]] || fail "Spot Capacity Provider가 대상 환경과 일치하지 않습니다."

  container_instance_arn=$("$AWS_BIN" ecs list-container-instances \
    --region "$AWS_REGION" \
    --cluster "$cluster_name" \
    --status ACTIVE \
    --filter "capacityProviderName == $on_demand_provider" \
    --query 'containerInstanceArns[0]' \
    --output text) || fail "On-Demand Worker container instance 조회에 실패했습니다."
  [[ -n "$container_instance_arn" && "$container_instance_arn" != "None" ]] || fail "ACTIVE On-Demand Worker container instance가 없습니다."

  container_status=$("$AWS_BIN" ecs describe-container-instances \
    --region "$AWS_REGION" \
    --cluster "$cluster_name" \
    --container-instances "$container_instance_arn" \
    --query 'containerInstances[0].status' \
    --output text) || fail "On-Demand Worker container instance 상태 조회에 실패했습니다."
  [[ "$container_status" == "ACTIVE" ]] || fail "On-Demand Worker container instance가 ACTIVE가 아닙니다."

  provider_statuses=$("$AWS_BIN" ecs describe-capacity-providers \
    --region "$AWS_REGION" \
    --capacity-providers "$on_demand_provider" "$spot_provider" \
    --query 'capacityProviders[].status' \
    --output text) || fail "Worker Capacity Provider 상태 조회에 실패했습니다."
  [[ $(tr '\t' '\n' <<<"$provider_statuses" | grep -c '^ACTIVE$') -eq 2 ]] || fail "Worker Capacity Provider 두 개가 모두 ACTIVE여야 합니다."
fi

state_list=$("$TERRAFORM_BIN" -chdir="$TERRAFORM_DIR" state list) || fail "Terraform Cloud 인증 또는 workspace state 조회에 실패했습니다."

for forbidden in \
  aws_instance.main_server \
  aws_instance.judge_server \
  aws_cloudfront_distribution.frontend_cdn \
  aws_route53_zone.main; do
  escaped_forbidden="${forbidden//./\\.}"
  if grep -Eq "(^|\\.)${escaped_forbidden}$" <<<"$state_list"; then
    fail "v2 state에서 v1 전용 주소를 발견했습니다: $forbidden"
  fi
done

if [[ "${CHECK_JUDGE_WORKER:-false}" == "true" ]]; then
  for required in \
    'module.environment.aws_autoscaling_group.worker_on_demand[0]' \
    'module.environment.aws_autoscaling_group.worker_spot[0]' \
    'module.environment.aws_ecs_capacity_provider.worker_on_demand[0]' \
    'module.environment.aws_ecs_capacity_provider.worker_spot[0]'; do
    grep -Fxq "$required" <<<"$state_list" || fail "Worker capacity가 v2 state에 없습니다: $required"
  done
fi

printf 'preflight 통과(%s): frontend, image, Secret version, state, 운영 확인 항목이 준비되었습니다.\n' "$target_environment"
