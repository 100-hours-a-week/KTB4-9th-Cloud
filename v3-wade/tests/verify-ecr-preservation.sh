#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/ecr-preservation-test.XXXXXX")"
cleanup() { rm -rf -- "$TEST_TMP"; }
trap cleanup EXIT
mkdir -p "$TEST_TMP/bin"

cat >"$TEST_TMP/bin/terraform" <<'MOCK_TERRAFORM'
#!/usr/bin/env bash
printf 'terraform %s\n' "$*" >>"$MOCK_LOG"
MOCK_TERRAFORM
chmod +x "$TEST_TMP/bin/terraform"

export MOCK_LOG="$TEST_TMP/terraform.log"
export PATH="$TEST_TMP/bin:$PATH"

# shellcheck source=../scripts/common.sh
source "$ROOT/scripts/common.sh"

: >"$MOCK_LOG"
provision_infrastructure
provision_calls="$(cat "$MOCK_LOG")"
expected_provision="$(printf '%s\n' \
  "terraform -chdir=$ROOT/environments/ecr init -input=false" \
  "terraform -chdir=$ROOT/environments/ecr apply -input=false -auto-approve" \
  "terraform -chdir=$ROOT/environments/eks init -input=false" \
  "terraform -chdir=$ROOT/environments/eks apply -input=false -auto-approve -var enable_edge=false")"
if [[ "$provision_calls" != "$expected_provision" ]]; then
  printf 'unexpected provision order:\n%s\n' "$(cat "$MOCK_LOG")" >&2
  exit 1
fi

: >"$MOCK_LOG"
initialize_cluster_terraform
destroy_cluster_infrastructure
teardown_calls="$(cat "$MOCK_LOG")"
expected_teardown="$(printf '%s\n' \
  "terraform -chdir=$ROOT/environments/eks init -input=false" \
  "terraform -chdir=$ROOT/environments/eks destroy -input=false -auto-approve -var enable_edge=false")"
if [[ "$teardown_calls" != "$expected_teardown" ]]; then
  printf 'teardown must only destroy the EKS state:\n%s\n' "$(cat "$MOCK_LOG")" >&2
  exit 1
fi

if grep -Eq 'environments/ecr .*destroy' "$MOCK_LOG"; then
  echo 'ECR state must never be destroyed by cluster teardown' >&2
  exit 1
fi

echo 'PASS: ECR state is provisioned first and excluded from teardown'
