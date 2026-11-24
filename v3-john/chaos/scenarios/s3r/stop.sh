#!/usr/bin/env bash
# S3r 원복: 상태 저장 파드 Ready를 기다리고, 옛 노드를 원하는 용량을 줄이며 종료한 뒤 노드 그룹을 1/1/1로 되돌린다. 여러 번 불러도 안전하다.
# 채점 장애가 남아 있으면 런북(runbooks/stateful-node-loss.md)대로 대응자가 처리한다. 이 스크립트는 채점 파드를 건드리지 않는다
# (대응 전 실험에서 '사람 개입 전까지 지속'을 재기 위해서다). 대응 전 실험의 수동 복구 시각은 s3r-events에 대응자가 남긴다.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ev() { echo "$(date +%s) $*" >> "$RECORD_DIR/s3r-events"; echo "$*"; }
for _ in $(seq 1 60); do s3r_pods_ready && break; sleep 5; done
s3r_pods_ready && ev "상태 저장 파드 4개 Ready" || ev "상태 저장 파드가 300초 안에 Ready가 아님"
old=$(cat "$RECORD_DIR/s3r-old-node" 2>/dev/null || true)
if [ -n "$old" ] && kubectl get node "$old" >/dev/null 2>&1; then
  iid=$(kubectl get node "$old" -o jsonpath='{.spec.providerID}' | sed 's|.*/||')
  aws autoscaling terminate-instance-in-auto-scaling-group --region "$S3R_REGION" --instance-id "$iid" --should-decrement-desired-capacity >/dev/null 2>&1 && ev "옛 노드 종료($iid)"
fi
s3r_scale 1 1 1; ev "노드 그룹 1/1/1"
exit 0
