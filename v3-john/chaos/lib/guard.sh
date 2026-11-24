# 실험 중단 조건(설계서 8.2). guard_check는 위반이 있으면 이유를 출력하고 1을 돌려준다.
#   prometheus | alertmanager : 응답 없음(측정할 수 없는 실험)
#   vcpu                      : Spot vCPU 합계 28 초과(계정 한도 32에서 4 남김)(GUARD_FAKE_VCPU로 흉내 낼 수 있다. 주입 중에만 적용)
#   duration                  : 주입 경과 10분 초과(INJECT_START 기준)
source "$(dirname "${BASH_SOURCE[0]}")/prom.sh"
# 2026-11-20 사용자 결정으로 24 → 28. 노드 최대 3대 적용 뒤 평상시 Spot 합계가 이미 24라(application 12, judge 8,
# system 2, stateful 2) 제출 부하로 judge 노드가 한 대만 늘어도 걸렸다.
GUARD_MAX_VCPU=${GUARD_MAX_VCPU:-28}
GUARD_MAX_INJECT_S=${GUARD_MAX_INJECT_S:-600}
# 주입 중 모니터링(Prometheus, Alertmanager) 무응답을 허용하는 시간(초, 기본 0 = 허용 안 함). S2'처럼 모니터링이 회수 대상 노드에
# 있어 공백 자체가 측정 대상인 시나리오가 scenario.env로 켠다. 원복 뒤 회복 관찰(GUARD_RECOVERING=1)에도 같은 허용을 쓴다. 이때 회수 안전은 FIS 중단 알람(CloudWatch)이 맡는다(2026-11-24).
GUARD_MON_GAP_OK_S=${GUARD_MON_GAP_OK_S:-0}

_prom_ok() { [ "$(prom_query 'vector(1)')" = "1" ]; }
_am_ok() { curl -sf --max-time 10 "$AM_URL/-/healthy" >/dev/null; }
_spot_vcpu() {
  # 시험용 값은 주입 중(INJECT_START 설정)에만 쓴다. 그래야 주입 중 위반 → stop.sh → 기록 경로를 시험할 수 있다.
  if [ -n "${GUARD_FAKE_VCPU:-}" ] && [ -n "${INJECT_START:-}" ]; then echo "$GUARD_FAKE_VCPU"; return; fi
  kubectl get nodes -l eks.amazonaws.com/capacityType=SPOT -o jsonpath='{range .items[*]}{.status.capacity.cpu}{"\n"}{end}' \
    | awk '{s+=$1} END {print s+0}'
}

guard_check() {
  # guard_check는 $(...) 하위 셸에서 불리므로 공백 시작 시각은 파일에 둔다.
  local st="${GUARD_STATE_DIR:-${RECORD_DIR:-/tmp}}/mon-down-since" which=""
  _prom_ok || which=prometheus
  [ -z "$which" ] && { _am_ok || which=alertmanager; }
  if [ -n "$which" ]; then
    if [ -n "${INJECT_START:-}${GUARD_RECOVERING:-}" ] && (( GUARD_MON_GAP_OK_S > 0 )); then
      [ -s "$st" ] || date +%s > "$st"
      (( $(date +%s) - $(cat "$st") > GUARD_MON_GAP_OK_S )) && { echo "$which"; return 1; }
    else
      echo "$which"; return 1
    fi
  else
    rm -f "$st"
  fi
  local v; v=$(_spot_vcpu)
  if [ "${v:-0}" -gt "$GUARD_MAX_VCPU" ]; then echo "vcpu"; return 1; fi
  if [ -n "${INJECT_START:-}" ] && (( $(date +%s) - INJECT_START > GUARD_MAX_INJECT_S )); then echo "duration"; return 1; fi
  return 0
}
