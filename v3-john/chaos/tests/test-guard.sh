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
GUARD_FAKE_VCPU=30 expect "vCPU 24 초과" 1 "vcpu"
_prom_ok() { return 1; }
GUARD_FAKE_VCPU=8  expect "Prometheus 무응답" 1 "prometheus"
_prom_ok() { return 0; }; _am_ok() { return 1; }
GUARD_FAKE_VCPU=8  expect "Alertmanager 무응답" 1 "alertmanager"
_am_ok() { return 0; }
INJECT_START=$(( $(date +%s) - 601 ))
GUARD_FAKE_VCPU=8  expect "주입 10분 초과" 1 "duration"
exit $fail
