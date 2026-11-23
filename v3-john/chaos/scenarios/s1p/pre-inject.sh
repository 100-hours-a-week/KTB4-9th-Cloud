#!/usr/bin/env bash
# S1' 주입 준비: core DB 연결 풀을 바꾸는 PR을 main에 병합하고, core Rollout이 끝난 뒤 S1P_TRIGGER_DELAY초를 기다린다.
#   S1P_POOL=<n>            주입할 HIKARI 최대 풀 크기(필수)
#   S1P_TRIGGER_DELAY=<초>  core 롤아웃이 끝난 뒤 auth 재시작까지 대기(기본 180)
# 실행기는 이 시간을 주입 시간에 넣지 않는다. 장애를 일으키는 순간(auth 재시작)은 inject.sh다.
# core 카나리가 중단되면(영향 범위 카나리, S1' 단계 3) 그것도 결과로 기록하고 계속한다.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
source "$S1P_DIR/../../lib/prom.sh"
: "${S1P_POOL:?S1P_POOL을 지정한다(예: 40)}"
[ "$(s1p_current)" != "$S1P_POOL" ] || { echo "현재 풀 크기가 이미 ${S1P_POOL}이다. 변경 없는 주입은 실험이 아니다" >&2; exit 1; }
[ -f "$RECORD_DIR/s1p-original" ] || s1p_current > "$RECORD_DIR/s1p-original"
# 실험 전 DB 연결 수(stop.sh의 대기 기준). Prometheus에 닿지 않으면 기록하지 않는다.
if [ ! -s "$RECORD_DIR/s1p-db-before" ]; then
  prom_query 'cosmos:db_connections:sum' > "$RECORD_DIR/s1p-db-before" 2>/dev/null || : > "$RECORD_DIR/s1p-db-before"
fi
s1p_merge_pool "$S1P_POOL" "chaos(S1'): core 풀 크기를 ${S1P_POOL}로 변경"
echo "$(date +%s) core 풀 변경 PR 병합·동기화(풀 ${S1P_POOL})" >> "$RECORD_DIR/s1p-events"
rc=0; s1p_wait_core_settled 600 "$S1P_GEN_BEFORE" || rc=$?
case $rc in
  0) echo "$(date +%s) core Rollout Healthy(풀 ${S1P_POOL})" >> "$RECORD_DIR/s1p-events" ;;
  3) echo "$(date +%s) core 카나리 중단(풀 ${S1P_POOL})" >> "$RECORD_DIR/s1p-events"; echo aborted > "$RECORD_DIR/s1p-core-canary" ;;
  *) exit 1 ;;
esac
sleep "${S1P_TRIGGER_DELAY:-180}"
