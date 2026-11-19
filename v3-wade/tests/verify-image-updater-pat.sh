#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

need_text() {
  local file="$1"
  local text="$2"
  rg -q --fixed-strings -- "$text" "$ROOT/$file" || {
    echo "missing from $file: $text" >&2
    exit 1
  }
}

need_text scripts/common.sh 'IMAGE_UPDATER_PAT_PARAMETER="${IMAGE_UPDATER_PAT_PARAMETER:-/cosmos/wade/github/image-updater-pat}"'
need_text scripts/up.sh '"$BASE/scripts/refresh-image-updater-git-credentials.sh" --ensure-parameter'
need_text scripts/refresh-image-updater-git-credentials.sh 'aws ssm put-parameter'
need_text scripts/refresh-image-updater-git-credentials.sh '--type SecureString'
need_text scripts/refresh-image-updater-git-credentials.sh '--with-decryption'
need_text scripts/refresh-image-updater-git-credentials.sh '--from-literal=username="${GITHUB_USERNAME}"'
need_text scripts/refresh-image-updater-git-credentials.sh '--from-file=password="${credential_file}"'
need_text scripts/refresh-image-updater-git-credentials.sh 'kubectl rollout restart deployment -n argocd -l app.kubernetes.io/name=argocd-image-updater'

if rg -q 'GITHUB_APP_(ID|INSTALLATION_ID|PRIVATE_KEY_FILE)' "$ROOT/scripts/up.sh"; then
  echo "up.sh must not require GitHub App credentials" >&2
  exit 1
fi

echo "PASS: Image Updater PAT is sourced from SSM SecureString"

TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/image-updater-pat-test.XXXXXX")"
cleanup() { rm -rf -- "$TEST_TMP"; }
trap cleanup EXIT
mkdir -p "$TEST_TMP/bin"

cat >"$TEST_TMP/bin/aws" <<'MOCK_AWS'
#!/usr/bin/env bash
echo "aws $*" >>"$MOCK_LOG"
case "${MOCK_AWS_MODE:-secure}" in
  denied)
    echo 'An error occurred (AccessDeniedException) when calling GetParameter' >&2
    exit 254
    ;;
  missing)
    if [[ " $* " == *' put-parameter '* ]]; then exit 0; fi
    echo 'An error occurred (ParameterNotFound) when calling GetParameter' >&2
    exit 254
    ;;
  string)
    if [[ " $* " == *' --output json '* ]]; then
      printf '{"Parameter":{"Type":"String","Value":"real-test-token"}}\n'
    else
      printf 'real-test-token\n'
    fi
    ;;
  placeholder)
    if [[ " $* " == *' --output json '* ]]; then
      printf '{"Parameter":{"Type":"SecureString","Value":"REPLACE_ME_WITH_FINE_GRAINED_PAT"}}\n'
    else
      printf 'REPLACE_ME_WITH_FINE_GRAINED_PAT\n'
    fi
    ;;
  secure)
    if [[ " $* " == *' --output json '* ]]; then
      printf '{"Parameter":{"Type":"SecureString","Value":"real-test-token"}}\n'
    else
      printf 'real-test-token\n'
    fi
    ;;
esac
MOCK_AWS

cat >"$TEST_TMP/bin/kubectl" <<'MOCK_KUBECTL'
#!/usr/bin/env bash
echo "kubectl $*" >>"$MOCK_LOG"
if [[ " $* " == *' get secret argocd-image-updater-git '* ]]; then
  printf '{"metadata":{"annotations":{}},"data":{"username":"eA==","password":"eA==","insecure":"ZmFsc2U="}}\n'
elif [[ " $* " == *' create secret generic '* ]]; then
  cat <<'YAML'
apiVersion: v1
kind: Secret
metadata:
  name: argocd-image-updater-git
  namespace: argocd
type: Opaque
data: {}
YAML
elif [[ " $* " == *' apply '* ]]; then
  cat >/dev/null
fi
MOCK_KUBECTL
chmod +x "$TEST_TMP/bin/aws" "$TEST_TMP/bin/kubectl"

run_refresh() {
  MOCK_AWS_MODE="$1" MOCK_LOG="$TEST_TMP/calls.log" PATH="$TEST_TMP/bin:$PATH" \
    bash "$ROOT/scripts/refresh-image-updater-git-credentials.sh" "${@:2}"
}

: >"$TEST_TMP/calls.log"
run_refresh placeholder --ensure-parameter >"$TEST_TMP/placeholder.out" 2>&1
if rg -q 'kubectl' "$TEST_TMP/calls.log"; then
  echo 'placeholder must not mutate Kubernetes credentials' >&2
  exit 1
fi

: >"$TEST_TMP/calls.log"
if run_refresh placeholder >"$TEST_TMP/manual-placeholder.out" 2>&1; then
  echo 'manual refresh must fail until the placeholder is replaced' >&2
  exit 1
fi

: >"$TEST_TMP/calls.log"
if run_refresh string >"$TEST_TMP/string.out" 2>&1; then
  echo 'plain String parameters must be rejected' >&2
  exit 1
fi

: >"$TEST_TMP/calls.log"
if run_refresh denied --ensure-parameter >"$TEST_TMP/denied.out" 2>&1; then
  echo 'AccessDenied must not be treated as a missing parameter' >&2
  exit 1
fi
if rg -q 'put-parameter' "$TEST_TMP/calls.log"; then
  echo 'AccessDenied must not attempt to create a parameter' >&2
  exit 1
fi

: >"$TEST_TMP/calls.log"
MOCK_AWS_MODE=secure MOCK_LOG="$TEST_TMP/calls.log" PATH="$TEST_TMP/bin:$PATH" \
  bash -x "$ROOT/scripts/refresh-image-updater-git-credentials.sh" >"$TEST_TMP/secure.out" 2>&1
if rg -q 'real-test-token' "$TEST_TMP/secure.out"; then
  echo 'PAT leaked through shell tracing' >&2
  exit 1
fi
need_call='kubectl apply --server-side --field-manager=image-updater-credentials --force-conflicts -f -'
rg -q --fixed-strings -- "$need_call" "$TEST_TMP/calls.log" || {
  echo 'Secret must use server-side apply' >&2
  exit 1
}

echo "PASS: Image Updater SSM PAT behavioral contract"
