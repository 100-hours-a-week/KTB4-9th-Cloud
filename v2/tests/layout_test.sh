#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
v2_root="${repo_root}/v2"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_file() {
  [[ -f "$1" ]] || fail "필수 파일이 없습니다: ${1#"${repo_root}/"}"
}

assert_contains() {
  local file="$1"
  local pattern="$2"
  rg -q --fixed-strings "$pattern" "$file" || fail "${file#"${repo_root}/"}에 필수 설정이 없습니다: ${pattern}"
}

assert_matches() {
  local file="$1"
  local pattern="$2"
  rg -q "$pattern" "$file" || fail "${file#"${repo_root}/"}에 필수 설정이 없습니다: ${pattern}"
}

for module in shared environment; do
  [[ -d "${v2_root}/modules/${module}" ]] || fail "modules/${module}이 없습니다."
done

if find "${v2_root}" -maxdepth 1 -type f -name '*.tf' -print -quit | grep -q .; then
  fail "v2 root에 이전 단일 환경 Terraform 파일이 남아 있습니다. environments/*를 사용해야 합니다."
fi

for environment in shared stage prod; do
  root="${v2_root}/environments/${environment}"
  for file in versions.tf providers.tf main.tf outputs.tf; do
    assert_file "${root}/${file}"
  done
  if [[ "$environment" != "shared" ]]; then
    assert_file "${root}/variables.tf"
  fi
done

assert_matches "${v2_root}/environments/shared/versions.tf" 'name[[:space:]]*=[[:space:]]*"KTB4-9th-Cloud-v2-shared"'
assert_matches "${v2_root}/environments/stage/versions.tf" 'name[[:space:]]*=[[:space:]]*"KTB4-9th-Cloud-v2-stage"'
assert_matches "${v2_root}/environments/prod/versions.tf" 'name[[:space:]]*=[[:space:]]*"KTB4-9th-Cloud-v2-prod"'

for environment in stage prod; do
  main="${v2_root}/environments/${environment}/main.tf"
  outputs="${v2_root}/environments/${environment}/outputs.tf"
  assert_matches "$main" 'source[[:space:]]*=[[:space:]]*"../../modules/environment"'
  assert_contains "$main" 'data.terraform_remote_state.shared.outputs.vpc_id'
  assert_contains "$main" 'data.terraform_remote_state.shared.outputs.public_subnet_ids'
  assert_contains "$main" 'data.terraform_remote_state.shared.outputs.private_subnet_ids'
  assert_contains "$main" 'data.terraform_remote_state.shared.outputs.data_subnet_ids'
  assert_contains "$main" 'data.terraform_remote_state.shared.outputs.ecr_repository_urls'
  assert_contains "$main" 'data.terraform_remote_state.shared.outputs.ecr_repository_arns'
  assert_contains "$main" 'data.terraform_remote_state.shared.outputs.regional_wildcard_certificate_arn'
  assert_contains "$main" 'toset(["spring", "fastapi", "judge"])'
  assert_matches "$main" 'enable_phase2_services[[:space:]]*=[[:space:]]*var.enable_phase2_services'
  assert_matches "$main" 'enable_stateful_services[[:space:]]*=[[:space:]]*var.enable_stateful_services'
  assert_matches "$main" 'enable_judge_worker_capacity[[:space:]]*=[[:space:]]*var.enable_judge_worker_capacity'
  assert_matches "$main" 'enable_judge_worker[[:space:]]*=[[:space:]]*var.enable_judge_worker'
  assert_matches "$main" 'judge_image_digest[[:space:]]*=[[:space:]]*var.judge_image_digest'
  assert_matches "$main" 'judge_api_command[[:space:]]*=[[:space:]]*var.judge_api_command'
  assert_matches "$main" 'judge_worker_command[[:space:]]*=[[:space:]]*var.judge_worker_command'
  assert_matches "$main" 'judge_postgres_image[[:space:]]*=[[:space:]]*var.judge_postgres_image'
  assert_matches "$main" 'judge_redis_image[[:space:]]*=[[:space:]]*var.judge_redis_image'
  assert_matches "$main" 'ai_postgres_image[[:space:]]*=[[:space:]]*var.ai_postgres_image'
  assert_contains "$outputs" 'output "spring_target_group_arn"'
  assert_contains "$outputs" 'module.environment.spring_target_group_arn'
  assert_contains "$outputs" 'output "stage_service_urls"'
done

assert_matches "${v2_root}/environments/stage/main.tf" 'environment[[:space:]]*=[[:space:]]*"stage"'
assert_matches "${v2_root}/environments/prod/main.tf" 'environment[[:space:]]*=[[:space:]]*"prod"'
assert_matches "${v2_root}/environments/prod/main.tf" 'enable_public_dns_cutover[[:space:]]*=[[:space:]]*var.enable_public_dns_cutover'
assert_contains "${v2_root}/environments/shared/main.tf" 'data "aws_route53_zone" "main"'
assert_contains "${v2_root}/environments/shared/main.tf" 'data "aws_acm_certificate" "cloudfront"'
assert_contains "${v2_root}/environments/shared/outputs.tf" 'output "regional_wildcard_certificate_arn"'
assert_contains "${v2_root}/modules/shared/acm.tf" 'resource "aws_acm_certificate" "regional_wildcard"'
assert_contains "${v2_root}/modules/shared/acm.tf" 'resource "aws_acm_certificate_validation" "regional_wildcard"'
assert_contains "${v2_root}/modules/environment/ecs-container-instances.tf" 'name = "/aws/service/ecs/optimized-ami/amazon-linux-2023/recommended/image_id"'

if rg -n 'amazon-linux-2023/x86_64/recommended/image_id' "${v2_root}/modules/environment" --glob '*.tf'; then
  echo "ECS optimized AL2023 AMI parameter must use the ECS path without /x86_64." >&2
  exit 1
fi

if rg -n 'alias/aws/elasticache|kms_key_id' "${v2_root}/modules/environment/valkey.tf"; then
  fail "ElastiCache Serverless 기본 암호화에 AWS 관리형 KMS 키를 명시하면 안 됩니다."
fi

if rg -n 'resource "aws_route53_zone"' "${v2_root}" --glob '*.tf'; then
  fail "v2는 기존 Route 53 Hosted Zone을 새로 생성하면 안 됩니다."
fi

acm_certificate_count="$(rg -n 'resource "aws_acm_certificate"' "${v2_root}" --glob '*.tf' | wc -l | tr -d ' ')"
if [[ "$acm_certificate_count" != "1" ]]; then
  fail "v2가 소유하는 ACM 인증서는 Shared 서울 wildcard 인증서 하나여야 합니다."
fi

if rg -n 'resource "aws_(vpc|subnet|nat_gateway|ecr_repository)"' "${v2_root}/modules/environment" --glob '*.tf'; then
  fail "environment module이 shared 네트워크 또는 ECR을 소유하면 안 됩니다."
fi

if rg -n 'aws_secretsmanager_secret_version|secret_string|stage-api\.cosmoscode\.site' "${v2_root}" --glob '*.tf'; then
  fail "Secret 값 관리 또는 금지된 Stage API 주소가 발견되었습니다."
fi

if rg -n 'FASTAPI_SECRET_JSON|JUDGE_API_SECRET_JSON|JUDGE_WORKER_SECRET_JSON' "${v2_root}/modules/environment" --glob '*.tf'; then
  fail "애플리케이션이 읽지 않는 JSON 전체 Secret 환경 변수가 발견되었습니다."
fi

if rg -n 'SPRING_DATASOURCE_' "${v2_root}/modules/environment/ecs-task-definitions.tf"; then
  fail "Spring prod profile이 읽지 않는 SPRING_DATASOURCE_* 환경 변수가 발견되었습니다."
fi

if rg -n '^After=cloud-final\.service$' "${v2_root}/modules/environment/templates/ecs-stateful-user-data.sh.tftpl"; then
  fail "cloud-final에서 시작하는 ECS service가 cloud-final 완료를 기다리면 부팅 교착이 발생합니다."
fi

if rg -n 'systemctl (enable --now|start) ecs' "${v2_root}/modules/environment/templates/ecs-stateful-user-data.sh.tftpl"; then
  fail "ECS optimized AMI의 ecs.service는 cloud-final 완료 후 systemd가 시작해야 합니다."
fi

if rg -n 'judge_(api|worker|postgres|redis)_image_digest' "${v2_root}" --glob '*.tf'; then
  fail "이전 6개 ECR image digest 변수가 남아 있습니다."
fi

if rg -n '/cosmos-v2/prod' "${v2_root}/modules/environment" --glob '*.tf'; then
  fail "environment module에 prod Secret 경로가 하드코딩되어 있습니다."
fi

if rg -n 'cidr_blocks[[:space:]]*=[[:space:]]*\[[[:space:]]*"0\.0\.0\.0/0"[[:space:]]*\]' "${v2_root}/modules/environment/security.tf"; then
  fail "허용된 Stage HTTPS 규칙 외에 legacy 0.0.0.0/0 inline ingress가 발견되었습니다."
fi

assert_contains "${v2_root}/modules/environment/security.tf" 'resource "aws_vpc_security_group_ingress_rule" "alb_public_https"'
assert_contains "${v2_root}/modules/environment/security.tf" 'description       = "Temporary public HTTPS access for stage service testing"'

printf 'PASS: Shared/Stage/Prod root layout 계약이 일치합니다.\n'

