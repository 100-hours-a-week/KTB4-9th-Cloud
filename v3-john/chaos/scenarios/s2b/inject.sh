#!/usr/bin/env bash
# S2' B 주입: 상태 저장 스팟 노드(Postgres 2, Redis 큐, RabbitMQ)에 FIS로 회수 2분 전 알림을 보낸다.
# 대체 노드가 볼륨과 다른 존에 뜨면 상태 저장 파드는 볼륨을 붙이지 못해 뜨지 못한다(stateful-ng 서브넷이 a·c 둘 다).
# 회수부터 네 파드 Ready까지를 s2b-timeline에 5초 간격으로 남기는 기록기를 함께 띄운다.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
R=$S2_REGION
node=$(kubectl get nodes -l workload-class=stateful -o jsonpath='{.items[0].metadata.name}')
[ -n "$node" ] || { echo "상태 저장 노드가 없다" >&2; exit 1; }
[ "$(kubectl get node "$node" -o jsonpath='{.metadata.labels.eks\.amazonaws\.com/capacityType}')" = SPOT ] || { echo "$node가 스팟이 아니다(회수 대상 아님)" >&2; exit 1; }
s2b_pods_ready || { echo "상태 저장 파드가 실험 전부터 Ready가 아니다" >&2; exit 1; }
iid=$(s2_instance_id "$(kubectl get node "$node" -o jsonpath='{.spec.providerID}')")
acct=$(aws sts get-caller-identity --query Account --output text)
role=$(aws iam get-role --role-name "$S2_ROLE" --query Role.Arn --output text)
alarm=$(aws cloudwatch describe-alarms --region "$R" --alarm-names "$S2_ALARM" --query 'MetricAlarms[0].AlarmArn' --output text)
vz=$(s2b_volume_zone)
echo "$node" > "$RECORD_DIR/s2-node"; echo "$iid" > "$RECORD_DIR/s2-instance"; echo "$vz" > "$RECORD_DIR/s2b-volume-zone"
kubectl get pods -A --field-selector "spec.nodeName=$node" -o wide > "$RECORD_DIR/s2-pods-on-node.txt"
kubectl get nodes -L workload-class,eks.amazonaws.com/capacityType,topology.kubernetes.io/zone,node.kubernetes.io/instance-type > "$RECORD_DIR/s2-nodes-before.txt"
testid=${TESTID:-s2b-${STEP:-x}-$(date +%s)}
tpl=$(aws fis create-experiment-template --region "$R" \
  --cli-input-json "$(s2_template_json "$role" "$alarm" "arn:aws:ec2:$R:$acct:instance/$iid" "$testid")" \
  --query experimentTemplate.id --output text)
echo "$tpl" > "$RECORD_DIR/fis-template-id"
exp=$(aws fis start-experiment --region "$R" --experiment-template-id "$tpl" --tags "testid=$testid" --query experiment.id --output text)
echo "$exp" > "$RECORD_DIR/fis-experiment-id"
echo "FIS 실험 $exp 시작: 상태 저장 노드 $node($iid), 볼륨 존 $vz"
# 기록기: 25분 동안 5초마다 "시각 Ready파드수 노드목록"
( end=$(( $(date +%s) + 1500 ))
  while (( $(date +%s) < end )); do
    n=0; for p in $S2B_PODS; do [ "$(kubectl get pod "$p" -n prod -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ] && n=$((n+1)); done
    echo "$(date +%s) $n $(s2b_nodes | tr '\n' ';')" >> "$RECORD_DIR/s2b-timeline"; sleep 5
  done ) >/dev/null 2>&1 &
for _ in $(seq 1 30); do
  st=$(s2_state "$exp")
  case "$st" in
    running|completed) echo "FIS 상태 $st"; date +%s > "$RECORD_DIR/s2-notice-at"; exit 0 ;;
    failed|stopped|cancelled) aws fis get-experiment --region "$R" --id "$exp" --query experiment.state.reason --output text >&2; exit 1 ;;
  esac
  sleep 2
done
echo "FIS 실험이 60초 안에 실행 상태가 되지 않았다($st)" >&2; exit 1
