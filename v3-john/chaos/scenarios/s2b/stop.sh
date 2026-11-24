#!/usr/bin/env bash
# S2' B 원복: FIS 정리 → 상태 저장 노드가 볼륨 존에 있고 네 파드가 Ready일 때까지 기다린다.
# 대체 노드가 볼륨과 다른 존이면 런북(runbooks/stateful-node-loss.md)의 수동 복구를 그대로 한다: 그 노드를 ASG에서
# 원하는 용량을 줄이지 않고 종료해 다시 띄우게 한다(최대 3번). 시각은 s2b-events에 남긴다. 여러 번 불러도 안전하다.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
R=$S2_REGION
ev() { echo "$(date +%s) $*" >> "$RECORD_DIR/s2b-events"; echo "$*"; }
if [ -s "$RECORD_DIR/fis-experiment-id" ]; then
  exp=$(cat "$RECORD_DIR/fis-experiment-id")
  case "$(s2_state "$exp")" in initiating|pending|running) aws fis stop-experiment --region "$R" --id "$exp" >/dev/null ;; esac
fi
if [ -s "$RECORD_DIR/fis-template-id" ]; then
  aws fis delete-experiment-template --region "$R" --id "$(cat "$RECORD_DIR/fis-template-id")" >/dev/null 2>&1 || true
  rm -f "$RECORD_DIR/fis-template-id"
fi
vz=$(cat "$RECORD_DIR/s2b-volume-zone" 2>/dev/null || s2b_volume_zone)
deadline=$(( $(date +%s) + ${S2B_WAIT_S:-1200} )); tries=0
while (( $(date +%s) < deadline )); do
  if s2b_pods_ready; then ev "상태 저장 파드 4개 Ready"; break; fi
  wrong=$(s2b_wrong_zone_node "$vz")
  if [ -n "$wrong" ] && (( tries < 3 )); then
    # 다른 존 노드가 볼륨 존 노드 없이 혼자 있으면 파드가 영영 못 뜬다
    if ! s2b_nodes | awk -v vz="$vz" '$3=="True" && $2==vz {f=1} END{exit !f}'; then
      tries=$((tries+1))
      iid=$(s2_instance_id "$(kubectl get node "$wrong" -o jsonpath='{.spec.providerID}')")
      ev "대체 노드 $wrong가 볼륨과 다른 존($(kubectl get node "$wrong" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}')) — 수동 복구 $tries: 인스턴스 $iid 교체"
      aws autoscaling terminate-instance-in-auto-scaling-group --region "$R" --instance-id "$iid" --no-should-decrement-desired-capacity >/dev/null
      sleep 30
    fi
  fi
  sleep 10
done
s2b_pods_ready || ev "제한 시간 안에 상태 저장 파드가 모두 Ready가 되지 않았다"
kubectl get nodes -L workload-class,eks.amazonaws.com/capacityType,topology.kubernetes.io/zone,node.kubernetes.io/instance-type > "$RECORD_DIR/s2-nodes-after.txt" 2>/dev/null || true
exit 0
