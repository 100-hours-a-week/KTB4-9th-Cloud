#!/usr/bin/env bash
# S2' 단계 1: preStopSleepSeconds가 0이면 lifecycle이 없고, 0보다 크면 sleep preStop이 렌더링되는지 확인한다.
# terminationGracePeriodSeconds가 preStop + 종료 단계 제한보다 크지 않으면 렌더링이 실패해야 한다.
set -uo pipefail
C=$(cd "$(dirname "$0")/.." && pwd); P=$C/../../environments/prod; fail=0
ok() { echo "PASS $1"; }; no() { echo "FAIL $1"; fail=1; }
def=$(helm template t "$C" -n prod -f "$P/judge-api.yaml" --set preStopSleepSeconds=0 2>&1)
! grep -q 'lifecycle:' <<<"$def" && ok "0이면 lifecycle 없음" || no "0인데 lifecycle 렌더링"
on=$(helm template t "$C" -n prod -f "$P/core.yaml" --set preStopSleepSeconds=10 2>&1)
grep -A5 'lifecycle:' <<<"$on" | grep -q 'preStop:' && grep -A6 'lifecycle:' <<<"$on" | grep -qF 'sleep 10' && ok "10이면 preStop sleep 10" || no "preStop sleep 10"
grep -A6 'lifecycle:' <<<"$on" | grep -q '"sh"' && grep -A6 'lifecycle:' <<<"$on" | grep -q '"-c"' && ok "command가 sh -c" || no "command 형태"
# 경계: 10 + 20 = 30 < 31은 통과, 30 이하는 실패
okr=$(helm template t "$C" -n prod -f "$P/core.yaml" --set preStopSleepSeconds=10 --set shutdownPhaseSeconds=20 --set terminationGracePeriodSeconds=31 2>&1)
grep -q 'lifecycle:' <<<"$okr" && ! grep -q '^Error' <<<"$okr" && ok "grace 31 > 10 + 20 통과" || no "grace 31 통과"
for g in 30 20; do
  bad=$(helm template t "$C" -n prod -f "$P/core.yaml" --set preStopSleepSeconds=10 --set shutdownPhaseSeconds=20 --set terminationGracePeriodSeconds=$g 2>&1)
  grep -q 'terminationGracePeriodSeconds는 preStopSleepSeconds와 shutdownPhaseSeconds의 합보다 커야' <<<"$bad" && ok "grace $g이면 렌더 실패(한국어 메시지)" || no "grace $g 검사"
done
# 모든 prod 값 파일이 렌더링된다(auth, core, battle, judge-api는 preStop 10)
for f in auth core battle judge-api; do
  r=$(helm template t "$C" -n prod -f "$P/$f.yaml" 2>&1)
  grep -A6 'lifecycle:' <<<"$r" | grep -qF 'sleep 10' && ok "$f preStop 10 적용" || no "$f preStop"
done
for f in auth core battle; do
  r=$(helm template t "$C" -n prod -f "$P/$f.yaml" 2>&1)
  grep -A1 'name: SERVER_SHUTDOWN' <<<"$r" | grep -q 'graceful' && grep -A1 'name: SPRING_LIFECYCLE_TIMEOUT_PER_SHUTDOWN_PHASE' <<<"$r" | grep -q '20s' && ok "$f graceful 종료 환경 변수" || no "$f graceful 환경 변수"
done
! grep -q 'SERVER_SHUTDOWN' <<<"$(helm template t "$C" -n prod -f "$P/judge-api.yaml" 2>&1)" && ok "judge-api는 Spring 설정 없음" || no "judge-api Spring 설정"
exit $fail
