#!/usr/bin/env bash
# up.sh, down.sh 공통 설정
set -euo pipefail
ENV_NAME=wade
CLUSTER=cosmos-v3-wade
REGION=ap-northeast-2
SEED_BUCKET=cosmos-db-backup-352635536602
BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$BASE/environments/eks"
export KUBECONFIG="${TMPDIR:-/tmp}/kubeconfig-$CLUSTER"
tf() { terraform -chdir="$TF_DIR" "$@"; }
secret_json() { aws secretsmanager get-secret-value --region "$REGION" --secret-id "$1" --query SecretString --output text; }
secret_key() { secret_json "$1" | python3 -c 'import json,sys;print(json.load(sys.stdin)[sys.argv[1]])' "$2"; }
