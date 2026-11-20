#!/usr/bin/env bash
# up.sh, down.sh 공통 설정
set -euo pipefail
ENV_NAME=wade
CLUSTER=cosmos-v3-wade
REGION=ap-northeast-2
SEED_BUCKET=cosmos-db-backup-352635536602
IMAGE_UPDATER_PAT_PARAMETER="${IMAGE_UPDATER_PAT_PARAMETER:-/cosmos/wade/github/image-updater-pat}"
BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$BASE/environments/eks"
ECR_TF_DIR="$BASE/environments/ecr"
export KUBECONFIG="${TMPDIR:-/tmp}/kubeconfig-$CLUSTER"
tf() { terraform -chdir="$TF_DIR" "$@"; }
ecr_tf() { terraform -chdir="$ECR_TF_DIR" "$@"; }
initialize_cluster_terraform() { tf init -input=false; }
provision_infrastructure() {
  ecr_tf init -input=false
  ecr_tf apply -input=false -auto-approve
  initialize_cluster_terraform
  tf apply -input=false -auto-approve -var enable_edge=false
}
destroy_cluster_infrastructure() {
  tf destroy -input=false -auto-approve -var enable_edge=false
}
secret_json() { aws secretsmanager get-secret-value --region "$REGION" --secret-id "$1" --query SecretString --output text; }
secret_key() { secret_json "$1" | python3 -c 'import json,sys;print(json.load(sys.stdin)[sys.argv[1]])' "$2"; }
