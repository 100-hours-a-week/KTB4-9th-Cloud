#!/usr/bin/env bash
# 클러스터와 테스트 데이터를 모두 지운다.
source "$(dirname "$0")/common.sh"
[ "${1:-}" = "--yes" ] || { echo "사용: down.sh --yes"; exit 1; }

tf init -input=false
if aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" >/dev/null 2>&1; then
  tf apply -input=false -auto-approve -var enable_edge=false
  # Kubernetes가 만든 NLB와 EBS를 먼저 지워야 VPC를 삭제할 수 있다.
  kubectl delete applicationset,application --all -n argocd --cascade=foreground --timeout=10m || true
  kubectl delete gateway prod -n prod --timeout=5m || true
  # Operator가 Prometheus, Alertmanager 파드를 다시 만들어 PVC가 풀리지 않으므로 먼저 제거한다.
  helm uninstall kube-prometheus-stack -n monitoring --wait --timeout 5m || true
  kubectl delete statefulset --all -A --timeout=5m || true
  for pv in $(kubectl get pv -o name); do kubectl patch "$pv" -p '{"spec":{"persistentVolumeReclaimPolicy":"Delete"}}' || true; done
  kubectl delete pvc --all -A --timeout=5m || true
  until [ -z "$(kubectl get pv -o name)" ]; do sleep 10; done
  while aws elbv2 describe-load-balancers --region "$REGION" --names "$CLUSTER" >/dev/null 2>&1; do sleep 10; done
fi
tf destroy -input=false -auto-approve -var enable_edge=false
echo "삭제 완료: $CLUSTER"
