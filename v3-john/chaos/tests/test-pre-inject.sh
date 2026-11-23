#!/usr/bin/env bash
# 실행기 주입 준비 단계(pre-inject.sh) 테스트. 실행기의 해당 블록만 떼어 가짜 시나리오로 돌린다.
# 실행: bash v3-john/chaos/tests/test-pre-inject.sh
set -uo pipefail
DIR=$(cd "$(dirname "$0")" && pwd); R="$DIR/../run-experiment.sh"; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; fail=0
ok() { echo "ok   $1"; }; no() { echo "FAIL $1"; fail=1; }
block=$(sed -n '/^# 4b\. 주입 준비/,/^# 5\. 주입/p' "$R")
[ -n "$block" ] && ok "주입 준비 블록이 있다" || no "주입 준비 블록 없음"
# 준비 블록은 INJECT_START보다 앞에 있어야 주입 시간에 들어가지 않는다
a=$(grep -n '^# 4b\. 주입 준비' "$R" | cut -d: -f1); b=$(grep -n '^INJECT_START=\$(date +%s)' "$R" | cut -d: -f1)
[ -n "$a" ] && [ -n "$b" ] && (( a < b )) && ok "준비가 INJECT_START 앞" || no "준비 위치(a=$a b=$b)"
grep -q 'K6_S=\$(( AFTER_S + PRE_INJECT_MAX + INJECT_DURATION + RECOVER_S + 60 ))' "$R" && ok "k6 길이에 준비 한도 포함" || no "k6 길이"
run() { # <스크립트 본문> <PRE_INJECT_MAX>
  SDIR="$T/s"; mkdir -p "$SDIR"; rm -f "$SDIR/pre-inject.sh"
  if [ -n "$1" ]; then printf '#!/usr/bin/env bash\n%s\n' "$1" > "$SDIR/pre-inject.sh"; chmod +x "$SDIR/pre-inject.sh"; fi
  PRE_INJECT_MAX=$2 INJECTED=0 ABORTED="" LOG="$T/log"; : > "$LOG"
  log() { :; }; guard_check() { return 0; }
  ( eval "$block"; echo "INJECTED=$INJECTED ABORTED=$ABORTED" ) 2>/dev/null | tail -1
}
[ "$(run "" 0)" = "INJECTED=0 ABORTED=" ] && ok "준비 스크립트가 없으면 아무것도 안 함" || no "없을 때: $(run "" 0)"
[ "$(run "exit 0" 60)" = "INJECTED=1 ABORTED=" ] && ok "준비 성공이면 원복 대상(INJECTED=1)" || no "성공: $(run "exit 0" 60)"
out=$(run "exit 1" 60); [[ "$out" == "" || "$out" == *"ABORTED=pre-inject-failed"* ]] && grep -q 'ABORTED="pre-inject-failed"; exit 1' <<<"$block" && ok "준비 실패면 pre-inject-failed로 중단" || no "실패: $out"
grep -q 'ABORTED="pre-inject-timeout"' <<<"$block" && ok "준비가 한도를 넘으면 pre-inject-timeout" || no "한도 초과 처리 없음"
exit $fail
