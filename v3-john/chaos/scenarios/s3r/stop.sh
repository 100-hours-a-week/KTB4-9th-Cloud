#!/usr/bin/env bash
# S3r 원복: 기록기를 멈추고 상태 저장 파드 Ready를 기다린다. drain이 끝났으면 옛 노드를, 중단됐으면 새 노드를 원하는 용량을 줄이며 종료한 뒤 노드 그룹을 1/1/1로 되돌린다. 여러 번 불러도 안전하다.
# 채점 장애가 남아 있으면 런북(runbooks/stateful-node-loss.md)대로 대응자가 처리한다. 이 스크립트는 채점 파드를 건드리지 않는다
# (대응 전 실험에서 '사람 개입 전까지 지속'을 재기 위해서다). 대응 전 실험의 수동 복구 시각은 s3r-events에 대응자가 남긴다.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ev() { echo "$(date +%s) $*" >> "$RECORD_DIR/s3r-events"; echo "$*"; }
[ -f "$RECORD_DIR/s3r-recorder.pid" ] && kill "$(cat "$RECORD_DIR/s3r-recorder.pid")" 2>/dev/null || true
for _ in $(seq 1 60); do s3r_pods_ready && break; sleep 5; done
s3r_pods_ready && ev "상태 저장 파드 4개 Ready" || ev "상태 저장 파드가 300초 안에 Ready가 아님"
old=$(cat "$RECORD_DIR/s3r-old-node" 2>/dev/null || true)
terminate() { local iid; iid=$(kubectl get node "$1" -o jsonpath='{.spec.providerID}' | sed 's|.*/||')
  aws autoscaling terminate-instance-in-auto-scaling-group --region "$S3R_REGION" --instance-id "$iid" --should-decrement-desired-capacity >/dev/null 2>&1 && ev "$2($iid)"; }
if [ -n "$old" ] && kubectl get node "$old" >/dev/null 2>&1; then
  # 옛 노드는 drain이 끝나고 네 파드가 모두 다른 노드에서 Ready일 때만 종료한다.
  # 주입이 drain 전·중에 중단되면 DB·큐가 아직 옛 노드에 있으므로, 옛 노드를 되살리고 새 노드를 지운다.
  on_old=0; for p in $S3R_PODS; do [ "$(kubectl get pod "$p" -n prod -o jsonpath='{.spec.nodeName}' 2>/dev/null)" = "$old" ] && on_old=$((on_old+1)); done
  if grep -q '옛 노드 drain 완료' "$RECORD_DIR/s3r-events" 2>/dev/null && s3r_pods_ready && [ "$on_old" -eq 0 ]; then
    terminate "$old" "옛 노드 종료"
  else
    kubectl uncordon "$old" >/dev/null 2>&1; ev "중단 원복: 옛 노드 유지(uncordon $old, 옛 노드에 남은 파드 $on_old개)"
    for n in $(s3r_nodes | awk -v o="$old" '$1!=o{print $1}'); do terminate "$n" "중단 원복: 새 노드 종료"; done
  fi
fi
s3r_scale 1 1 1; ev "노드 그룹 1/1/1"
exit 0
