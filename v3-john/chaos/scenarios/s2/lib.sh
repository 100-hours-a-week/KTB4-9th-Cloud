# S2 공통 함수. inject.sh, stop.sh, tests/test-s2.sh가 source한다.
S2_REGION=ap-northeast-2
S2_ROLE=cosmos-v3-john-fis
S2_ALARM=cosmos-v3-john-fis-stop-application

# 노드 spec.providerID(aws:///<az>/<instance-id>)에서 인스턴스 ID를 꺼낸다.
s2_instance_id() {
  [[ "$1" =~ ^aws:///[a-z0-9-]+/(i-[0-9a-f]+)$ ]] || { echo "AWS 노드가 아니다: $1" >&2; return 1; }
  echo "${BASH_REMATCH[1]}"
}

# 실험 템플릿 JSON. 대상 인스턴스 1대에 회수 2분 전 알림을 보낸다.
s2_template_json() {  # role_arn alarm_arn instance_arn testid
  jq -n --arg role "$1" --arg alarm "$2" --arg arn "$3" --arg testid "$4" '{
    description: "S2 spot interruption \($testid)",
    roleArn: $role,
    stopConditions: [{source: "aws:cloudwatch:alarm", value: $alarm}],
    targets: {node: {resourceType: "aws:ec2:spot-instance", resourceArns: [$arn], selectionMode: "ALL"}},
    actions: {interrupt: {actionId: "aws:ec2:send-spot-instance-interruptions",
      parameters: {durationBeforeInterruption: "PT2M"}, targets: {SpotInstances: "node"}}},
    tags: {Name: "cosmos-v3-john-s2", testid: $testid}
  }'
}

s2_state() { aws fis get-experiment --region "$S2_REGION" --id "$1" --query experiment.state.status --output text 2>/dev/null; }
