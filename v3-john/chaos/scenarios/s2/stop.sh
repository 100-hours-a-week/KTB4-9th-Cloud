#!/usr/bin/env bash
# S2 원복: 남은 FIS 실험을 멈추고 임시 템플릿을 지운 뒤, application 노드 2대와 core가 돌아올 때까지 기다린다.
# 회수된 노드는 되돌릴 수 없다. 노드 그룹이 새 노드를 띄우는 것을 기다리는 것이 원복이다. 여러 번 불러도 안전하다.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
R=$S2_REGION

if [ -s "$RECORD_DIR/fis-experiment-id" ]; then
  exp=$(cat "$RECORD_DIR/fis-experiment-id")
  case "$(s2_state "$exp")" in
    initiating|pending|running) aws fis stop-experiment --region "$R" --id "$exp" >/dev/null && echo "FIS 실험 $exp 중지" ;;
  esac
fi
if [ -s "$RECORD_DIR/fis-template-id" ]; then
  aws fis delete-experiment-template --region "$R" --id "$(cat "$RECORD_DIR/fis-template-id")" >/dev/null 2>&1 || true
  rm -f "$RECORD_DIR/fis-template-id"
fi
[ -n "${S2_SKIP_WAIT:-}" ] && exit 0

deadline=$(( $(date +%s) + ${S2_WAIT_S:-600} ))
while :; do
  ready=$(kubectl get nodes -l workload-class=application --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l | tr -d ' ')
  (( ready >= 2 )) && break
  (( $(date +%s) >= deadline )) && { echo "application Ready 노드 ${ready}대(제한 시간 초과)"; break; }
  sleep 10
done
[ -s "$RECORD_DIR/s2-node-ready-at" ] || { (( ready >= 2 )) && date +%s > "$RECORD_DIR/s2-node-ready-at"; }
kubectl get nodes -L workload-class,eks.amazonaws.com/capacityType,topology.kubernetes.io/zone,node.kubernetes.io/instance-type \
  > "$RECORD_DIR/s2-nodes-after.txt" 2>/dev/null || true
for d in cosmos-core cosmos-auth cosmos-battle; do
  kubectl rollout status "deployment/$d" -n prod --timeout=300s || echo "$d 롤아웃 미완료"
done
exit 0
