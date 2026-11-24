#!/usr/bin/env bash
# 중단 조건(설계서 8.2) 검사. 실제 클러스터 없이 확인 함수를 바꿔 끼워 돌린다.
set -uo pipefail
source "$(dirname "$0")/../lib/guard.sh"
fail=0
expect() { # expect <설명> <기대 종료코드> <기대 출력 일부>
  local out rc; out=$(guard_check); rc=$?
  if [[ $rc -ne $2 || "$out" != *"$3"* ]]; then echo "FAIL $1: rc=$rc out='$out'"; fail=1; else echo "PASS $1"; fi
}
_prom_ok() { return 0; }; _am_ok() { return 0; }
INJECT_START=$(date +%s)
GUARD_FAKE_VCPU=8  expect "정상" 0 ""
GUARD_FAKE_VCPU=30 expect "vCPU 28 초과" 1 "vcpu"
_prom_ok() { return 1; }
GUARD_FAKE_VCPU=8  expect "Prometheus 무응답" 1 "prometheus"
_prom_ok() { return 0; }; _am_ok() { return 1; }
GUARD_FAKE_VCPU=8  expect "Alertmanager 무응답" 1 "alertmanager"
_am_ok() { return 0; }
INJECT_START=$(( $(date +%s) - 601 ))
GUARD_FAKE_VCPU=8  expect "주입 10분 초과" 1 "duration"
# S2'(모니터링이 회수 대상 노드에 있음): GUARD_MON_GAP_OK_S초까지 주입 중 모니터링 무응답을 허용한다. 상태는 파일에 남긴다(guard_check는 하위 셸에서 돈다).
export GUARD_STATE_DIR=$(mktemp -d); INJECT_START=$(date +%s); GUARD_MON_GAP_OK_S=120
_prom_ok() { return 1; }
GUARD_FAKE_VCPU=8 expect "주입 중 모니터링 공백 허용 시간 안" 0 ""
echo $(( $(date +%s) - 121 )) > "$GUARD_STATE_DIR/mon-down-since"
GUARD_FAKE_VCPU=8 expect "허용 시간 초과면 중단" 1 "prometheus"
_prom_ok() { return 0; }
GUARD_FAKE_VCPU=8 expect "회복하면 통과" 0 ""
[ ! -f "$GUARD_STATE_DIR/mon-down-since" ] && echo "PASS 회복하면 공백 시작 기록을 지움" || { echo "FAIL 공백 기록이 남음"; fail=1; }
_prom_ok() { return 1; }; unset INJECT_START
GUARD_FAKE_VCPU=8 expect "주입 밖에서는 허용 안 함" 1 "prometheus"
exit $fail
