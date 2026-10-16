#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
environment_module="${repo_root}/v2/modules/environment"
instances="${environment_module}/ecs-container-instances.tf"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

rg -U -q 'ignore_changes[[:space:]]*=[[:space:]]*\[[[:space:]]*ami,[[:space:]]*user_data,[[:space:]]*\]' "$instances" ||
  fail "상태 저장 EC2는 최신 AMI 변경만으로 자동 교체되면 안 됩니다."

if rg -n 'metrics_collector|migration_v1|primary_canary' \
  "$environment_module" \
  "${repo_root}/v2/environments/stage" \
  --glob '*.tf'; then
  fail "폐기한 metrics collector, migration bridge 또는 primary canary 구성이 남아 있습니다."
fi

printf 'PASS: 상태 저장 호스트 보호와 임시 인프라 제거 계약이 일치합니다.\n'
