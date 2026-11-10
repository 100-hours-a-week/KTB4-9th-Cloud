#!/usr/bin/env bash
# 클러스터 전체를 띄운다. 먼저 scripts/seed.sh가 끝나 있어야 한다.
source "$(dirname "$0")/common.sh"

SNAPSHOT=$(aws s3 cp "s3://$SEED_BUCKET/eks-seed/snapshot-id" -)
tf init -input=false
tf apply -input=false -auto-approve -var "seed_snapshot_identifier=$SNAPSHOT" -var enable_edge=false
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" >/dev/null
VPC_ID=$(tf output -raw vpc_id)

helm repo add eks https://aws.github.io/eks-charts --force-update >/dev/null
helm repo add autoscaler https://kubernetes.github.io/autoscaler --force-update >/dev/null
helm repo add kedacore https://kedacore.github.io/charts --force-update >/dev/null
helm repo add argo https://argoproj.github.io/argo-helm --force-update >/dev/null
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update >/dev/null
helm repo add grafana https://grafana.github.io/helm-charts --force-update >/dev/null
helm repo add secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts --force-update >/dev/null
helm repo add aws-secrets-manager https://aws.github.io/secrets-store-csi-driver-provider-aws --force-update >/dev/null

V="$BASE/helm/addons-values"
inst() { helm upgrade --install "$1" "$2" --version "$3" -n "$4" --create-namespace -f "$5" --wait --timeout 10m "${@:6}"; }
helm upgrade --install cosmos-foundation "$BASE/helm/platform/cosmos-foundation" -n kube-system --wait
inst aws-load-balancer-controller eks/aws-load-balancer-controller 3.6.2 kube-system "$V/lb-controller/values.yaml" --set "vpcId=$VPC_ID"
inst secrets-provider-aws aws-secrets-manager/secrets-store-csi-driver-provider-aws 3.1.4 kube-system "$V/secrets-store-csi/values.yaml"
inst cluster-autoscaler autoscaler/cluster-autoscaler 9.60.0 kube-system "$V/cluster-autoscaler/values.yaml"
inst keda kedacore/keda 2.21.0 keda "$V/keda/values.yaml"
inst envoy-gateway oci://docker.io/envoyproxy/gateway-helm 1.9.3 envoy-gateway-system "$V/envoy-gateway/values.yaml"
inst argocd argo/argo-cd 10.12.1 argocd "$V/argocd/values.yaml"

kubectl create secret generic discord-webhook -n monitoring --from-literal="url=$(secret_json cosmos/monitoring/discord-webhook)" --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic grafana-admin -n monitoring --from-literal=admin-user=admin --from-literal="admin-password=$(secret_json /cosmos-v2/monitoring/grafana-admin)" --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic judge-redis-keda -n prod --from-literal="password=$(secret_key /cosmos-v2/stage/judge-redis password)" --dry-run=client -o yaml | kubectl apply -f -
inst kube-prometheus-stack prometheus-community/kube-prometheus-stack 92.18.0 monitoring "$V/monitoring/kube-prometheus-stack.yaml"
inst loki grafana/loki 7.5.0 monitoring "$V/monitoring/loki.yaml"
inst alloy grafana/alloy 1.15.0 monitoring "$V/monitoring/alloy.yaml"

if ! kubectl get secret argocd-image-updater-git -n argocd >/dev/null 2>&1; then
  : "${GITHUB_APP_ID:?GITHUB_APP_ID is required for Argo CD Image Updater}"
  : "${GITHUB_APP_INSTALLATION_ID:?GITHUB_APP_INSTALLATION_ID is required for Argo CD Image Updater}"
  : "${GITHUB_APP_PRIVATE_KEY_FILE:?GITHUB_APP_PRIVATE_KEY_FILE is required for Argo CD Image Updater}"
  [[ -f "${GITHUB_APP_PRIVATE_KEY_FILE}" ]] || { echo "GitHub App private key file not found" >&2; exit 1; }
  kubectl create secret generic argocd-image-updater-git -n argocd \
    --from-literal=githubAppID="${GITHUB_APP_ID}" \
    --from-literal=githubAppInstallationID="${GITHUB_APP_INSTALLATION_ID}" \
    --from-file=githubAppPrivateKey="${GITHUB_APP_PRIVATE_KEY_FILE}" \
    --dry-run=client -o yaml | kubectl apply -f -
fi

inst argocd-image-updater oci://ghcr.io/argoproj/argo-helm/argocd-image-updater 1.4.2 argocd "$V/argocd-image-updater/values.yaml"
for f in "$V"/monitoring/dashboards/*.json; do
  n="dash-$(basename "$f" .json)"
  kubectl create configmap "$n" -n monitoring --from-file="$f" --dry-run=client -o yaml | kubectl apply --server-side -f -
  kubectl label configmap "$n" -n monitoring grafana_dashboard=1 --overwrite
done

G="$BASE/gitops"
kubectl apply -f "$G/argocd/projects/prod.yaml" -f "$G/argocd/image-updater.yaml"
# 데이터 복원 전에 애플리케이션이 자동 기동되지 않도록 최초 부트스트랩에서만 autoSync를 끈다.
sed 's/autoSync: true/autoSync: false/g' "$G/argocd/applicationsets-prod.yaml" | kubectl apply -f -
sync_app() {
  until kubectl get application -n argocd "$1" >/dev/null 2>&1; do sleep 3; done
  kubectl patch application -n argocd "$1" --type merge -p '{"operation":{"initiatedBy":{"username":"up.sh"},"sync":{}}}'
}
wait_healthy() { until [ "$(kubectl get application -n argocd "$1" -o jsonpath='{.status.health.status}')" = Healthy ]; do sleep 5; done; }

sync_app prod-platform
for a in prod-ai-postgres prod-judge-postgres prod-judge-redis; do sync_app "$a"; done
for a in prod-ai-postgres prod-judge-postgres prod-judge-redis; do wait_healthy "$a"; done
"$BASE/scripts/restore-postgres.sh"
"$BASE/scripts/restore-mysql.sh"
# 복원이 끝난 뒤 Git 선언 원본을 다시 적용해 지속적인 Auto Sync를 활성화한다.
kubectl apply -f "$G/argocd/applicationsets-prod.yaml"
for a in auth core battle ai-llm ai-make-problem ai-problem-batch mlflow judge-api judge-worker; do sync_app "prod-$a"; done
for a in auth core battle ai-llm mlflow judge-api judge-worker; do wait_healthy "prod-$a"; done

until kubectl get svc -n envoy-gateway-system -o jsonpath='{.items[*].status.loadBalancer.ingress[*].hostname}' | grep -q "$CLUSTER"; do sleep 10; done
kubectl apply -f "$G/environments/argocd/route.yaml" -f "$G/environments/argocd/grafana-route.yaml"
tf apply -input=false -auto-approve -var "seed_snapshot_identifier=$SNAPSHOT" -var enable_edge=true
"$BASE/scripts/build-frontend.sh"
echo "완료: https://$ENV_NAME.cosmoscode.site"
