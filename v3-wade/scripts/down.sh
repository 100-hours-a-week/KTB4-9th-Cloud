#!/usr/bin/env bash
# 클러스터를 모두 지운다. 시드 스냅샷과 덤프는 남긴다. 복원한 DB의 변경 내용은 사라진다.
source "$(dirname "$0")/common.sh"
[ "${1:-}" = "--yes" ] || { echo "사용: down.sh --yes"; exit 1; }

SNAPSHOT=$(aws s3 cp "s3://$SEED_BUCKET/eks-seed/snapshot-id" -)
tf init -input=false
if aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" >/dev/null 2>&1; then
  tf apply -input=false -auto-approve -var "seed_snapshot_identifier=$SNAPSHOT" -var enable_edge=false
  # Kubernetes가 만든 NLB와 EBS를 먼저 지워야 VPC를 삭제할 수 있다.
  kubectl delete applicationset,application --all -n argocd --cascade=foreground --timeout=10m || true
  kubectl delete gateway prod -n prod --timeout=5m || true
  kubectl delete pvc --all -A --timeout=5m || true
  while aws elbv2 describe-load-balancers --region "$REGION" --names "$CLUSTER" >/dev/null 2>&1; do sleep 10; done
fi
tf destroy -input=false -auto-approve -var "seed_snapshot_identifier=$SNAPSHOT" -var enable_edge=false
echo "삭제 완료: $CLUSTER"
