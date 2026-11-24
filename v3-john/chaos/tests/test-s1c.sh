#!/usr/bin/env bash
# S1' s1c 시나리오 테스트: 가짜 kubectl로 주석 부착·제거와 멱등성을 본다. 실행: bash v3-john/chaos/tests/test-s1c.sh
set -uo pipefail
DIR=$(cd "$(dirname "$0")" && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; fail=0
ok() { echo "ok   $1"; }; no() { echo "FAIL $1"; fail=1; }
mkdir "$T/bin"; : > "$T/calls"; echo 1 > "$T/pods"; : > "$T/ann"
cat > "$T/bin/kubectl" <<K
#!/usr/bin/env bash
echo "\$*" >> "$T/calls"
case "\$*" in
  *"annotate scaledobject"*"paused-replicas=0"*) echo 0 > "$T/ann"; echo 0 > "$T/pods";;
  *"annotate scaledobject"*"paused-replicas-"*) : > "$T/ann"; echo 1 > "$T/pods";;
  *"get scaledobject"*) cat "$T/ann";;
  *"get pods"*) [ "\$(cat "$T/pods")" = 1 ] && echo w1; true;;
  *wait*) exit 0;;
esac
K
chmod +x "$T/bin/kubectl"
export PATH="$T/bin:$PATH" RECORD_DIR="$T/rec"; mkdir -p "$RECORD_DIR"
S="$DIR/../scenarios/s1c"
bash "$S/inject.sh" >/dev/null 2>&1 && ok "inject 성공" || no "inject 실패"
grep -q 'annotate scaledobject cosmos-judge-worker -n prod autoscaling.keda.sh/paused-replicas=0 --overwrite' "$T/calls" && ok "inject가 KEDA 일시 정지 주석(0)을 붙임" || no "주석 부착 없음: $(cat $T/calls)"
grep -q "채점 워커 0" "$RECORD_DIR/s1c-events" && ok "inject 이벤트 기록" || no "inject 이벤트 없음"
bash "$S/stop.sh" >/dev/null 2>&1 && ok "stop 성공" || no "stop 실패"
grep -q 'annotate scaledobject cosmos-judge-worker -n prod autoscaling.keda.sh/paused-replicas-' "$T/calls" && ok "stop이 주석을 지움" || no "주석 제거 없음"
: > "$T/calls"; bash "$S/stop.sh" >/dev/null 2>&1 && ok "stop 두 번째도 성공(멱등)" || no "stop 두 번째 실패"
! grep -q 'paused-replicas-' "$T/calls" && ok "주석이 없으면 지우지 않음" || no "불필요한 주석 제거"
grep -q '^INJECT_DURATION=300$' "$S/scenario.env" && ok "주입 300초" || no "scenario.env"
exit $fail
