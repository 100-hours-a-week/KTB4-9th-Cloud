#!/usr/bin/env bash
# SSM SecureString의 GitHub PAT를 Image Updater가 사용하는 Kubernetes Secret으로 동기화한다.
source "$(dirname "$0")/common.sh"
# 복호화된 PAT가 `bash -x` 출력에 노출되지 않도록 이 지점부터 tracing을 강제로 끈다.
set +x

ensure_parameter=false
if [[ "${1:-}" == "--ensure-parameter" ]]; then
  ensure_parameter=true
elif [[ $# -gt 0 ]]; then
  echo "사용법: $0 [--ensure-parameter]" >&2
  exit 2
fi

credential_dir="$(mktemp -d "${TMPDIR:-/tmp}/image-updater-git.XXXXXX")"
parameter_json="$credential_dir/parameter.json"
credential_file="$credential_dir/password"
aws_error="$credential_dir/aws-error"
secret_json="$credential_dir/secret.json"
secret_patch="$credential_dir/secret-patch.json"
cleanup() {
  rm -f -- "$parameter_json" "$credential_file" "$aws_error" "$secret_json" "$secret_patch"
  rmdir -- "$credential_dir"
}
trap cleanup EXIT
umask 077

fetch_parameter() {
  : >"$aws_error"
  aws ssm get-parameter \
    --region "$REGION" \
    --name "$IMAGE_UPDATER_PAT_PARAMETER" \
    --with-decryption \
    --output json >"$parameter_json" 2>"$aws_error"
}

if ! fetch_parameter; then
  if [[ "$ensure_parameter" != true ]] || ! rg -q 'ParameterNotFound' "$aws_error"; then
    sed 's/^/AWS: /' "$aws_error" >&2
    exit 1
  fi

  : >"$aws_error"
  if aws ssm put-parameter \
    --region "$REGION" \
    --name "$IMAGE_UPDATER_PAT_PARAMETER" \
    --description "Fine-grained GitHub PAT for Argo CD Image Updater" \
    --type SecureString \
    --value REPLACE_ME_WITH_FINE_GRAINED_PAT >/dev/null 2>"$aws_error"; then
    echo "경고: $IMAGE_UPDATER_PAT_PARAMETER 을(를) 생성했습니다. 실제 fine-grained PAT로 교체해야 자동 이미지 갱신이 동작합니다." >&2
    exit 0
  fi

  # 동시에 실행된 다른 bootstrap이 먼저 생성했다면 새 값을 다시 읽는다.
  if ! rg -q 'ParameterAlreadyExists' "$aws_error"; then
    sed 's/^/AWS: /' "$aws_error" >&2
    exit 1
  fi
  fetch_parameter || { sed 's/^/AWS: /' "$aws_error" >&2; exit 1; }
fi

set +e
python3 - "$parameter_json" "$credential_file" "$ensure_parameter" <<'PY'
import json
import os
import sys

source, destination, ensure = sys.argv[1:]
with open(source, encoding="utf-8") as stream:
    parameter = json.load(stream)["Parameter"]

if parameter.get("Type") != "SecureString":
    print("오류: Image Updater PAT Parameter는 SecureString이어야 합니다.", file=sys.stderr)
    raise SystemExit(3)

value = parameter.get("Value", "")
if value == "REPLACE_ME_WITH_FINE_GRAINED_PAT":
    if ensure == "true":
        print("경고: SSM PAT가 placeholder 상태입니다. 자동 이미지 갱신은 PAT 교체 후 활성화됩니다.", file=sys.stderr)
        raise SystemExit(20)
    print("오류: SSM placeholder를 실제 fine-grained PAT로 먼저 교체하세요.", file=sys.stderr)
    raise SystemExit(4)
if not value:
    print("오류: SSM PAT 값이 비어 있습니다.", file=sys.stderr)
    raise SystemExit(5)

descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
    stream.write(value)
PY
validation_status=$?
set -e
if [[ $validation_status -eq 20 ]]; then
  exit 0
elif [[ $validation_status -ne 0 ]]; then
  exit "$validation_status"
fi

GITHUB_USERNAME="${GITHUB_USERNAME:-x-access-token}"
kubectl create secret generic argocd-image-updater-git -n argocd \
  --from-literal=username="${GITHUB_USERNAME}" \
  --from-file=password="${credential_file}" \
  --from-literal=insecure=false \
  --dry-run=client -o yaml | kubectl apply --server-side \
    --field-manager=image-updater-credentials --force-conflicts -f - >/dev/null

# 이전 GitHub App 필드와 client-side apply annotation을 제거한다.
kubectl get secret argocd-image-updater-git -n argocd -o json >"$secret_json"
python3 - "$secret_json" "$secret_patch" <<'PY'
import json
import sys

source, destination = sys.argv[1:]
with open(source, encoding="utf-8") as stream:
    secret = json.load(stream)

patch = []
for key in ("githubAppID", "githubAppInstallationID", "githubAppPrivateKey"):
    if key in secret.get("data", {}):
        patch.append({"op": "remove", "path": f"/data/{key}"})
annotation = "kubectl.kubernetes.io/last-applied-configuration"
if annotation in secret.get("metadata", {}).get("annotations", {}):
    patch.append({"op": "remove", "path": "/metadata/annotations/kubectl.kubernetes.io~1last-applied-configuration"})

with open(destination, "w", encoding="utf-8") as stream:
    json.dump(patch, stream)
PY
if [[ "$(cat "$secret_patch")" != "[]" ]]; then
  kubectl patch secret argocd-image-updater-git -n argocd --type=json --patch-file="$secret_patch" >/dev/null
fi

if ! deployments="$(kubectl get deployment -n argocd -l app.kubernetes.io/name=argocd-image-updater -o name)"; then
  echo "오류: Image Updater Deployment 조회에 실패했습니다." >&2
  exit 1
fi
if [[ -n "$deployments" ]]; then
  kubectl rollout restart deployment -n argocd -l app.kubernetes.io/name=argocd-image-updater
  kubectl rollout status deployment -n argocd -l app.kubernetes.io/name=argocd-image-updater --timeout=5m
fi

