#!/usr/bin/env bash
# 주입 유지 루프가 주입 시간이 한도(600초)와 같아도 duration 위반 없이 끝나는지 본다. 실제 시간을 줄여 흉내 낸다.
set -uo pipefail
source "$(dirname "$0")/../lib/guard.sh"
_prom_ok() { return 0; }; _am_ok() { return 0; }; GUARD_FAKE_VCPU=8
GUARD_MAX_INJECT_S=3; INJECT_DURATION=3; INJECT_START=$(date +%s); ABORTED=""
log() { :; }
eval "$(sed -n '/^while :; do$/,/^done$/p' "$(dirname "$0")/../run-experiment.sh" | sed 's/sleep \$(( remaining < 15 ? remaining : 15 ))/sleep $(( remaining < 1 ? remaining : 1 ))/')"
if [ -z "$ABORTED" ] && (( $(date +%s) - INJECT_START <= 4 )); then echo "PASS 주입 시간 = 한도에서 중단 없음"; else echo "FAIL aborted=$ABORTED"; exit 1; fi
