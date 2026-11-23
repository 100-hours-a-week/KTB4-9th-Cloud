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
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts --force-update >/dev/null
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

kubectl create secret generic discord-webhook -n monitoring --from-literal="url=$(secret_json cosmos/monitoring/discord-webhook)" --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic grafana-admin -n monitoring --from-literal=admin-user=admin --from-literal="admin-password=$(secret_json /cosmos-v2/monitoring/grafana-admin)" --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic judge-redis-keda -n prod --from-literal="password=$(secret_key /cosmos-v2/stage/judge-redis password)" --dry-run=client -o yaml | kubectl apply -f -
inst kube-prometheus-stack prometheus-community/kube-prometheus-stack 92.18.0 monitoring "$V/monitoring/kube-prometheus-stack.yaml"
inst loki grafana/loki 7.5.0 monitoring "$V/monitoring/loki.yaml"
inst alloy grafana/alloy 1.15.0 monitoring "$V/monitoring/alloy.yaml"
TEMPO_BUCKET="$(tf output -raw tempo_bucket_name)"
inst tempo grafana/tempo 1.24.4 monitoring "$V/monitoring/tempo.yaml" --set-string "tempo.storage.trace.s3.bucket=$TEMPO_BUCKET" --set-string "tempo.storage.trace.s3.region=$REGION" --set-string "tempo.storage.trace.s3.endpoint=s3.dualstack.$REGION.amazonaws.com"
inst otel-collector open-telemetry/opentelemetry-collector 0.178.3 monitoring "$V/monitoring/otel-collector.yaml"
for f in "$V"/monitoring/dashboards/*.json; do
  n="dash-$(basename "$f" .json)"
  kubectl create configmap "$n" -n monitoring --from-file="$f" --dry-run=client -o yaml | kubectl apply --server-side -f -
  kubectl label configmap "$n" -n monitoring grafana_dashboard=1 --overwrite
done

# Argo CD는 ServiceMonitor를 만들므로 kube-prometheus-stack(CRD) 다음에 설치한다.
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl create secret generic argocd-notifications-secret -n argocd --from-literal="discord-url=$(secret_json cosmos/monitoring/discord-webhook)" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
inst argocd argo/argo-cd 10.12.1 argocd "$V/argocd/values.yaml"

G="$BASE/gitops"

# Image Updater: ECR에 approved-* 이미지가 올라오면 EventBridge 웹훅을 받아 v3-john 값 파일의 이미지를 갱신한다.
# Git 쓰기용 GitHub App Secret이 없고 환경변수도 없으면 설치를 건너뛴다. 그때는 값 파일을 직접 고쳐 배포한다.
IMAGE_UPDATER=false
if kubectl get secret argocd-image-updater-git -n argocd >/dev/null 2>&1; then
  IMAGE_UPDATER=true
elif [[ -n "${GITHUB_APP_ID:-}" && -n "${GITHUB_APP_INSTALLATION_ID:-}" && -f "${GITHUB_APP_PRIVATE_KEY_FILE:-}" ]]; then
  kubectl create secret generic argocd-image-updater-git -n argocd \
    --from-literal=githubAppID="${GITHUB_APP_ID}" \
    --from-literal=githubAppInstallationID="${GITHUB_APP_INSTALLATION_ID}" \
    --from-file=githubAppPrivateKey="${GITHUB_APP_PRIVATE_KEY_FILE}" \
    --dry-run=client -o yaml | kubectl apply -f -
  IMAGE_UPDATER=true
else
  echo "알림: GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID, GITHUB_APP_PRIVATE_KEY_FILE이 없어 Image Updater 설치를 건너뜁니다." >&2
fi
if [[ "$IMAGE_UPDATER" == true ]]; then
  kubectl create secret generic argocd-image-updater-secret -n argocd \
    --from-literal="webhook.cloudevents-secret=$(secret_key cosmos/john/argocd-image-updater-webhook secret)" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  inst argocd-image-updater oci://ghcr.io/argoproj/argo-helm/argocd-image-updater 1.4.2 argocd "$V/argocd-image-updater/values.yaml"
  kubectl apply -f "$G/argocd/image-updater.yaml"
fi

kubectl apply -f "$G/argocd/projects/prod.yaml" -f "$G/argocd/applicationsets-prod.yaml"
sync_app() {
  until kubectl get application -n argocd "$1" >/dev/null 2>&1; do sleep 3; done
  kubectl patch application -n argocd "$1" --type merge -p '{"operation":{"initiatedBy":{"username":"up.sh"},"sync":{}}}'
}
wait_healthy() { until [ "$(kubectl get application -n argocd "$1" -o jsonpath='{.status.health.status}')" = Healthy ]; do sleep 5; done; }

sync_app prod-platform
for a in prod-ai-postgres prod-judge-postgres prod-judge-redis prod-rabbitmq; do sync_app "$a"; done
for a in prod-ai-postgres prod-judge-postgres prod-judge-redis prod-rabbitmq; do wait_healthy "$a"; done
"$BASE/scripts/restore-postgres.sh"
"$BASE/scripts/restore-mysql.sh"
for a in auth core battle ai-llm ai-make-problem ai-problem-batch mlflow judge-api judge-worker; do sync_app "prod-$a"; done
for a in auth core battle ai-llm mlflow judge-api judge-worker; do wait_healthy "prod-$a"; done

until kubectl get svc -n envoy-gateway-system -o jsonpath='{.items[*].status.loadBalancer.ingress[*].hostname}' | grep -q "$CLUSTER"; do sleep 10; done
kubectl apply -f "$G/environments/argocd/route.yaml" -f "$G/environments/argocd/grafana-route.yaml"
[[ "$IMAGE_UPDATER" == true ]] && kubectl apply -f "$G/environments/argocd/image-updater-webhook-route.yaml"
tf apply -input=false -auto-approve -var "seed_snapshot_identifier=$SNAPSHOT" -var enable_edge=true
"$BASE/scripts/build-frontend.sh"
echo "완료: https://$ENV_NAME.cosmoscode.site"
