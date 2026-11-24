#!/usr/bin/env bash
# S2 FIS 템플릿 생성과 stop.sh의 멱등성을 aws·kubectl 가짜 명령으로 확인한다. AWS는 부르지 않는다.
set -uo pipefail
D=$(cd "$(dirname "$0")/.." && pwd); fail=0
ok() { echo "PASS $1"; }; no() { echo "FAIL $1"; fail=1; }
source "$D/scenarios/s2/lib.sh"

[ "$(s2_instance_id 'aws:///ap-northeast-2a/i-0abc123def4567890')" = "i-0abc123def4567890" ] && ok "providerID에서 인스턴스 ID" || no "providerID 파싱"
s2_instance_id 'kind://docker/x' >/dev/null 2>&1 && no "AWS가 아닌 providerID를 받아들임" || ok "AWS가 아닌 providerID 거부"

j=$(s2_template_json arn:role arn:alarm arn:aws:ec2:ap-northeast-2:1:instance/i-1 s2-before-x)
[ "$(jq -r '.actions.interrupt.actionId' <<<"$j")" = "aws:ec2:send-spot-instance-interruptions" ] && ok "액션" || no "액션 $j"
[ "$(jq -r '.actions.interrupt.parameters.durationBeforeInterruption' <<<"$j")" = "PT2M" ] && ok "회수 2분 전" || no "durationBeforeInterruption"
[ "$(jq -r '.targets.node.resourceArns[0]' <<<"$j")" = "arn:aws:ec2:ap-northeast-2:1:instance/i-1" ] && ok "대상 인스턴스 1대" || no "대상"
[ "$(jq -r '.targets.node.selectionMode' <<<"$j")" = "ALL" ] && ok "선택 모드" || no "선택 모드"
[ "$(jq -r '.stopConditions[0].value' <<<"$j")" = "arn:alarm" ] && ok "중단 조건 알람" || no "중단 조건"
[ "$(jq -r '.tags.testid' <<<"$j")" = "s2-before-x" ] && ok "testid 태그" || no "태그"

# stop.sh: 가짜 aws가 부른 하위 명령을 기록한다.
T=$(mktemp -d); mkdir -p "$T/bin"; export CALLS="$T/calls" FAKE_STATE
cat > "$T/bin/aws" <<'S'
#!/usr/bin/env bash
echo "$2" >> "$CALLS"
case "$2" in get-experiment) echo "$FAKE_STATE";; esac
S
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/kubectl"; chmod +x "$T/bin/"*
run_stop() { PATH="$T/bin:$PATH" RECORD_DIR="$1" S2_SKIP_WAIT=1 "$D/scenarios/s2/stop.sh" >/dev/null 2>&1; }

R=$(mktemp -d); : > "$CALLS"; run_stop "$R" && [ ! -s "$CALLS" ] && ok "실험 기록이 없으면 아무것도 안 함" || no "빈 기록 $(cat "$CALLS")"

R=$(mktemp -d); echo EXP1 > "$R/fis-experiment-id"; echo TPL1 > "$R/fis-template-id"; : > "$CALLS"; FAKE_STATE=running
run_stop "$R" && grep -qx stop-experiment "$CALLS" && grep -qx delete-experiment-template "$CALLS" && ok "실행 중이면 멈추고 템플릿 삭제" || no "실행 중 $(tr '\n' ' ' < "$CALLS")"
[ ! -f "$R/fis-template-id" ] && ok "템플릿 ID 파일 정리" || no "템플릿 ID 파일 남음"

: > "$CALLS"; FAKE_STATE=completed
run_stop "$R" && ! grep -qx stop-experiment "$CALLS" && ! grep -qx delete-experiment-template "$CALLS" && ok "두 번째 호출은 멈추지도 지우지도 않음" || no "재호출 $(tr '\n' ' ' < "$CALLS")"

# stage.sh: 가짜 kubectl이 파드 상태를 파일로 흉내 낸다. 줄 형식은 ns|라벨|파드|노드|Ready.
# delete pod는 FAKE_TARGET 노드로 다시 뜬 것처럼 노드 칸을 바꾼다(FAKE_NO_MOVE가 있으면 그대로 둔다).
cat > "$T/bin/kubectl" <<'S'
#!/usr/bin/env bash
echo "$*" >> "$CALLS"
ns=""; sel=""; args=("$@")
for ((i=0;i<${#args[@]};i++)); do
  case "${args[i]}" in -n) ns=${args[i+1]};; -l) sel=${args[i+1]};; esac
done
case "$1 $2" in
  "get node") case "$*" in *zone*) echo "$FAKE_ZONE";; *) echo application;; esac ;;
  "get nodes") printf '%s\n' n1 n2 n3 ;;
  "cordon "*|"uncordon "*) ;;
  "get pods") awk -F'|' -v ns="$ns" -v sel="$sel" '$1==ns && $2==sel {print $3"|"$4"|"$5"|"}' "$FAKE_PODS" ;;
  "delete pod") [ -n "${FAKE_DELETE_FAIL:-}" ] && exit 1
    [ -n "${FAKE_NO_MOVE:-}" ] || awk -F'|' -v OFS='|' -v ns="$ns" -v p="$3" '$1==ns && $3==p {$4=ENVIRON["FAKE_TARGET"]} {print}' "$FAKE_PODS" > "$FAKE_PODS.new" && mv "$FAKE_PODS.new" "$FAKE_PODS" ;;
esac
exit 0
S
chmod +x "$T/bin/kubectl"
mkpods() {  # core 파드 노드 두 개를 인자로. 나머지는 이미 목표 노드 n1이거나 다른 노드에 있다.
  cat > "$FAKE_PODS" <<EOP
prod|app.kubernetes.io/name=cosmos-judge-api|cosmos-judge-api-a|n2|True
prod|app.kubernetes.io/name=cosmos-judge-api|cosmos-judge-api-b|n3|True
envoy-gateway-system|gateway.envoyproxy.io/owning-gateway-name=prod|envoy-prod-a|n2|True
monitoring|statefulset.kubernetes.io/pod-name=prometheus-kube-prometheus-stack-prometheus-0|prometheus-kube-prometheus-stack-prometheus-0|n2|True
monitoring|statefulset.kubernetes.io/pod-name=alertmanager-kube-prometheus-stack-alertmanager-0|alertmanager-kube-prometheus-stack-alertmanager-0|n2|True
monitoring|statefulset.kubernetes.io/pod-name=tempo-0|tempo-0|n3|True
prod|app.kubernetes.io/name=cosmos-core|cosmos-core-a|$1|True
prod|app.kubernetes.io/name=cosmos-core|cosmos-core-b|$2|True
EOP
}
export FAKE_PODS="$T/pods" FAKE_TARGET=n1 FAKE_ZONE=ap-northeast-2a
run_stage() { PATH="$T/bin:$PATH" RECORD_DIR="$1" S2_STAGE_WAIT_S="${WAIT:-3}" S2_STAGE_POLL_S=0 "$D/scenarios/s2/stage.sh" n1 >"$1/out.txt" 2>&1; }

R=$(mktemp -d); mkpods n2 n3; : > "$CALLS"; run_stage "$R"; rc=$?
[ $rc -eq 0 ] && ok "stage 성공" || no "stage 성공 rc=$rc $(cat "$R/out.txt")"
grep -q '^cordon n2' "$CALLS" && grep -q '^cordon n3' "$CALLS" && ! grep -q '^cordon n1' "$CALLS" && ok "다른 노드만 cordon" || no "cordon $(grep cordon "$CALLS" | tr '\n' ' ')"
grep -q '^uncordon n2' "$CALLS" && grep -q '^uncordon n3' "$CALLS" && ok "성공 뒤 uncordon" || no "uncordon 없음"
[ "$(grep -c '^delete pod cosmos-core-' "$CALLS")" = 1 ] && ok "core는 한 개만 지움" || no "core 삭제 수 $(grep -c 'delete pod cosmos-core-' "$CALLS")"
grep -q 'tempo-0' "$R/s2-staged.txt" && grep -q 'cosmos-judge-api-a n1' "$R/s2-staged.txt" && ok "배치 기록" || no "s2-staged $(cat "$R/s2-staged.txt" 2>&1)"

R=$(mktemp -d); mkpods n2 n3; : > "$CALLS"; FAKE_NO_MOVE=1 WAIT=1 run_stage "$R"; rc=$?
[ $rc -eq 1 ] && ok "배치가 안 맞으면 종료 1" || no "배치 불일치 rc=$rc"
grep -q '^uncordon n2' "$CALLS" && grep -q '^uncordon n3' "$CALLS" && ok "실패해도 uncordon" || no "실패 뒤 uncordon 없음"

R=$(mktemp -d); mkpods n2 n3; : > "$CALLS"; FAKE_DELETE_FAIL=1 run_stage "$R"; rc=$?
[ $rc -ne 0 ] && grep -q '^uncordon n2' "$CALLS" && ok "delete 실패에도 uncordon" || no "delete 실패 rc=$rc"

R=$(mktemp -d); mkpods n1 n1; : > "$CALLS"; run_stage "$R"; rc=$?
[ $rc -eq 1 ] && ok "core 2개가 같은 노드면 종료 1" || no "core 2개 rc=$rc"

R=$(mktemp -d); mkpods n2 n3; : > "$CALLS"; S2_STAGE_SKIP=monitoring run_stage "$R"; rc=$?
[ $rc -eq 0 ] && ! grep -q '^delete pod .*-n monitoring' "$CALLS" && ! grep -q 'tempo-0' "$R/s2-staged.txt" && ok "S2_STAGE_SKIP=monitoring 존중" || no "skip rc=$rc $(grep 'delete pod' "$CALLS" | tr '\n' ' ')"

R=$(mktemp -d); mkpods n2 n3; : > "$CALLS"; FAKE_ZONE=ap-northeast-2c run_stage "$R"; rc=$?
[ $rc -eq 1 ] && ! grep -q '^cordon' "$CALLS" && ok "2a 밖 노드는 cordon 전에 거절" || no "zone 거절 rc=$rc"
R=$(mktemp -d); mkpods n2 n3; : > "$CALLS"; FAKE_ZONE=ap-northeast-2c S2_STAGE_SKIP=monitoring run_stage "$R"; rc=$?
[ $rc -eq 0 ] && ok "monitoring 건너뛰면 2a 밖도 허용" || no "zone+skip rc=$rc $(cat "$R/out.txt")"

# 2026-11-24: 볼륨 존은 클러스터마다 다르다(2차는 Prometheus·Alertmanager 2c, Tempo 2a). S2_MON_ZONE으로 받는다.
R=$(mktemp -d); mkpods n2 n3; : > "$CALLS"; FAKE_ZONE=ap-northeast-2c S2_MON_ZONE=ap-northeast-2c S2_STAGE_SKIP=tempo run_stage "$R"; rc=$?
[ $rc -eq 0 ] && ! grep -q 'tempo-0' "$CALLS" && grep -q 'prometheus' "$R/s2-staged.txt" && ok "S2_MON_ZONE=2c + tempo 건너뜀: 2c 노드 허용, Tempo는 건드리지 않음" || no "mon zone rc=$rc $(cat "$R/out.txt")"
R=$(mktemp -d); mkpods n2 n3; : > "$CALLS"; FAKE_ZONE=ap-northeast-2a S2_MON_ZONE=ap-northeast-2c run_stage "$R"; rc=$?
[ $rc -eq 1 ] && ! grep -q '^cordon' "$CALLS" && ok "S2_MON_ZONE과 다른 존 노드는 cordon 전에 거절" || no "mon zone 거절 rc=$rc"
R=$(mktemp -d); mkpods n2 n3; PATH="$T/bin:$PATH" RECORD_DIR="$R" "$D/scenarios/s2/stage.sh" >/dev/null 2>&1; rc=$?
[ $rc -eq 2 ] && ok "인자 없으면 사용법 오류" || no "인자 없음 rc=$rc"
exit $fail
