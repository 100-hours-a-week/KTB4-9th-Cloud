#!/usr/bin/env bash
# S1' 주입: core DB 연결 풀을 줄이는 PR을 main에 병합하고, core 롤아웃이 끝난 뒤 지연을 두고 auth를 재시작한다.
#   S1P_POOL=<n>            주입할 HIKARI 최대 풀 크기(필수)
#   S1P_TRIGGER_DELAY=<초>  core Healthy 이후 auth 재시작까지 대기(기본 180)
# auth 롤아웃 완료는 기다리지 않고 반환한다.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
source "$S1P_DIR/../../lib/prom.sh"
: "${S1P_POOL:?S1P_POOL을 지정한다(예: 40)}"
[ -f "$RECORD_DIR/s1p-original" ] || s1p_current > "$RECORD_DIR/s1p-original"
# 실험 전 DB 연결 수(stop.sh의 대기 기준). Prometheus에 닿지 않으면 기록하지 않는다.
if [ ! -s "$RECORD_DIR/s1p-db-before" ]; then
  prom_query 'cosmos:db_connections:sum' > "$RECORD_DIR/s1p-db-before" 2>/dev/null || : > "$RECORD_DIR/s1p-db-before"
fi
s1p_merge_pool "$S1P_POOL" "chaos(S1'): core 풀 크기를 ${S1P_POOL}로 변경"
s1p_wait_core_healthy 600
echo "$(date +%s) core Rollout Healthy(풀 ${S1P_POOL})" >> "$RECORD_DIR/s1p-events"
sleep "${S1P_TRIGGER_DELAY:-180}"
kubectl rollout restart deployment/cosmos-auth -n prod
echo "$(date +%s) auth 재시작 트리거" >> "$RECORD_DIR/s1p-events"
