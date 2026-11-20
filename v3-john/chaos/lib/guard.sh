# 실험 중단 조건(설계서 8.2). guard_check는 위반이 있으면 이유를 출력하고 1을 돌려준다.
#   prometheus | alertmanager : 응답 없음(측정할 수 없는 실험)
#   vcpu                      : Spot vCPU 합계 24 초과(GUARD_FAKE_VCPU로 흉내 낼 수 있다. 주입 중에만 적용)
#   duration                  : 주입 경과 10분 초과(INJECT_START 기준)
source "$(dirname "${BASH_SOURCE[0]}")/prom.sh"
GUARD_MAX_VCPU=${GUARD_MAX_VCPU:-24}
GUARD_MAX_INJECT_S=${GUARD_MAX_INJECT_S:-600}

_prom_ok() { [ "$(prom_query 'vector(1)')" = "1" ]; }
_am_ok() { curl -sf --max-time 10 "$AM_URL/-/healthy" >/dev/null; }
_spot_vcpu() {
  # 시험용 값은 주입 중(INJECT_START 설정)에만 쓴다. 그래야 주입 중 위반 → stop.sh → 기록 경로를 시험할 수 있다.
  if [ -n "${GUARD_FAKE_VCPU:-}" ] && [ -n "${INJECT_START:-}" ]; then echo "$GUARD_FAKE_VCPU"; return; fi
  kubectl get nodes -l eks.amazonaws.com/capacityType=SPOT -o jsonpath='{range .items[*]}{.status.capacity.cpu}{"\n"}{end}' \
    | awk '{s+=$1} END {print s+0}'
}

guard_check() {
  _prom_ok || { echo "prometheus"; return 1; }
  _am_ok || { echo "alertmanager"; return 1; }
  local v; v=$(_spot_vcpu)
  if [ "${v:-0}" -gt "$GUARD_MAX_VCPU" ]; then echo "vcpu"; return 1; fi
  if [ -n "${INJECT_START:-}" ] && (( $(date +%s) - INJECT_START > GUARD_MAX_INJECT_S )); then echo "duration"; return 1; fi
  return 0
}
