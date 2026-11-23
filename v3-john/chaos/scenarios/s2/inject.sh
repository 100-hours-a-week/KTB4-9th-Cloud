#!/usr/bin/env bash
# S2 주입: core 파드가 있는 application 스팟 노드 1대에 FIS로 회수 2분 전 알림을 보낸다(설계서 9.2).
# 템플릿은 실험마다 만들고 stop.sh가 지운다. 실험이 실행 상태가 될 때까지만 기다리고 끝난다.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
R=$S2_REGION

# S2_NODE로 대상을 고정할 수 있다(core가 여러 노드에 있을 때 실행 전 cordon한 노드와 맞추려고 쓴다). 그 노드에도 core가 있어야 한다.
node=${S2_NODE:-$(kubectl get pods -n prod -l app.kubernetes.io/name=cosmos-core --field-selector status.phase=Running \
  -o jsonpath='{.items[0].spec.nodeName}')}
kubectl get pods -n prod -l app.kubernetes.io/name=cosmos-core --field-selector "status.phase=Running,spec.nodeName=$node" -o name | grep -q . \
  || { echo "노드 $node에 core 파드가 없다" >&2; exit 1; }
[ -n "$node" ] || { echo "실행 중인 core 파드가 없다" >&2; exit 1; }
cls=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.workload-class}/{.metadata.labels.eks\.amazonaws\.com/capacityType}')
[ "$cls" = "application/SPOT" ] || { echo "core 노드 $node가 application 스팟 노드가 아니다($cls)" >&2; exit 1; }
iid=$(s2_instance_id "$(kubectl get node "$node" -o jsonpath='{.spec.providerID}')")
acct=$(aws sts get-caller-identity --query Account --output text)
role=$(aws iam get-role --role-name "$S2_ROLE" --query Role.Arn --output text)
alarm=$(aws cloudwatch describe-alarms --region "$R" --alarm-names "$S2_ALARM" --query 'MetricAlarms[0].AlarmArn' --output text)
[ -n "$alarm" ] && [ "$alarm" != None ] || { echo "중단 조건 알람 $S2_ALARM이 없다(terraform 적용 확인)" >&2; exit 1; }
astate=$(aws cloudwatch describe-alarms --region "$R" --alarm-names "$S2_ALARM" --query 'MetricAlarms[0].StateValue' --output text)
[ "$astate" = OK ] || { echo "중단 조건 알람이 OK가 아니다($astate). ASG 그룹 지표 수집을 확인한다" >&2; exit 1; }

echo "$node" > "$RECORD_DIR/s2-node"; echo "$iid" > "$RECORD_DIR/s2-instance"
kubectl get pods -A --field-selector "spec.nodeName=$node" -o wide > "$RECORD_DIR/s2-pods-on-node.txt"
kubectl get nodes -L workload-class,eks.amazonaws.com/capacityType,topology.kubernetes.io/zone,node.kubernetes.io/instance-type \
  > "$RECORD_DIR/s2-nodes-before.txt"

testid=${TESTID:-s2-${STEP:-x}-$(date +%s)}
tpl=$(aws fis create-experiment-template --region "$R" \
  --cli-input-json "$(s2_template_json "$role" "$alarm" "arn:aws:ec2:$R:$acct:instance/$iid" "$testid")" \
  --query experimentTemplate.id --output text)
echo "$tpl" > "$RECORD_DIR/fis-template-id"
exp=$(aws fis start-experiment --region "$R" --experiment-template-id "$tpl" --tags "testid=$testid" \
  --query experiment.id --output text)
echo "$exp" > "$RECORD_DIR/fis-experiment-id"
echo "FIS 실험 $exp 시작: 노드 $node($iid)"

for _ in $(seq 1 30); do
  st=$(s2_state "$exp")
  case "$st" in
    running|completed) echo "FIS 상태 $st"; date +%s > "$RECORD_DIR/s2-notice-at"; exit 0 ;;
    failed|stopped|cancelled)
      aws fis get-experiment --region "$R" --id "$exp" --query experiment.state.reason --output text >&2; exit 1 ;;
  esac
  sleep 2
done
echo "FIS 실험이 60초 안에 실행 상태가 되지 않았다($st)" >&2; exit 1
