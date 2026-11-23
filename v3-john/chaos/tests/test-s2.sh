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
exit $fail
