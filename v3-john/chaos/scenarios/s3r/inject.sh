#!/usr/bin/env bash
# S3r 주입: 상태 저장 노드 계획 교체. 새 노드를 하나 더 띄운 뒤 옛 노드를 drain해 DB·큐 4개를 한꺼번에 옮긴다.
# 2026-11-24 스팟 회수 실험에서 관리형 노드 그룹이 같은 방식(대체 노드 기동 → 옛 노드 drain)으로 옮겼을 때
# DB·큐는 45초 만에 떴지만 채점이 재연결하지 못해 약 47분 장애가 났다. 온디맨드에서도 점검·업그레이드로 같은 이동이 일어난다.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
ev() { echo "$(date +%s) $*" >> "$RECORD_DIR/s3r-events"; echo "$*"; }
old=$(s3r_nodes | awk '$2=="True"{print $1; exit}'); [ -n "$old" ] || { echo "상태 저장 노드 없음" >&2; exit 1; }
echo "$old" > "$RECORD_DIR/s3r-old-node"
s3r_pods_ready || { echo "실험 전부터 상태 저장 파드가 Ready가 아니다" >&2; exit 1; }
# 기록기: 5초마다 Ready 파드 수
( end=$(( $(date +%s) + 1800 )); while (( $(date +%s) < end )); do n=0; for p in $S3R_PODS; do [ "$(kubectl get pod "$p" -n prod -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ] && n=$((n+1)); done; echo "$(date +%s) $n" >> "$RECORD_DIR/s3r-timeline"; sleep 5; done ) >/dev/null 2>&1 &
s3r_scale 1 2 2; ev "새 노드 요청(desired 2)"
for _ in $(seq 1 60); do [ "$(s3r_ready_count)" -ge 2 ] && break; sleep 10; done
[ "$(s3r_ready_count)" -ge 2 ] || { echo "새 상태 저장 노드가 10분 안에 Ready가 되지 않았다" >&2; exit 1; }
ev "새 노드 Ready"
kubectl drain "$old" --ignore-daemonsets --delete-emptydir-data --timeout=300s >/dev/null
ev "옛 노드 drain 완료($old)"
