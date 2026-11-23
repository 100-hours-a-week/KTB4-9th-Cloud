#!/usr/bin/env bash
# S1' 원복: 풀 크기를 원래 값으로 되돌리는 PR을 병합하고, auth가 모두 Ready가 아니면 재시작한 뒤 DB 연결 수가 내려가기를 기다린다.
# 이미 원래 값이면 PR은 만들지 않는다(여러 번 불려도 안전).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
source "$S1P_DIR/../../lib/prom.sh"
[ -s "$RECORD_DIR/s1p-original" ] || { echo "주입 기록 없음"; exit 0; }
orig=$(cat "$RECORD_DIR/s1p-original")
cur=$(s1p_current)
if [ "$cur" = "$orig" ]; then
  echo "이미 원래 풀 크기($orig)"
else
  s1p_merge_pool "$orig" "chaos(S1'): core 풀 크기 되돌림(${orig})"
  echo "$(date +%s) 풀 크기 원복 병합($orig)" >> "$RECORD_DIR/s1p-events"
fi
s1p_wait_core_healthy 600
echo "$(date +%s) 원복 core Rollout Healthy" >> "$RECORD_DIR/s1p-events"

# auth가 모두 Ready가 아니면 재시작
read -r want ready <<<"$(kubectl get deployment cosmos-auth -n prod -o jsonpath='{.spec.replicas} {.status.readyReplicas}')"
if [ "${ready:-0}" != "${want:-0}" ]; then
  kubectl rollout restart deployment/cosmos-auth -n prod
  kubectl rollout status deployment/cosmos-auth -n prod --timeout=300s || echo "auth 롤아웃이 300초 안에 끝나지 않았다" >&2
  echo "$(date +%s) auth 재시작(Ready ${ready:-0}/${want:-0})" >> "$RECORD_DIR/s1p-events"
fi

# DB 연결 수가 실험 전 값 +20 이하로 내려갈 때까지 최대 300초. Prometheus에 닿지 않으면 기록만 하고 넘어간다.
before=$(cat "$RECORD_DIR/s1p-db-before" 2>/dev/null || true)
if [ -z "$before" ]; then echo "실험 전 DB 연결 수 기록이 없어 대기를 건너뛴다"; exit 0; fi
deadline=$(( $(date +%s) + 300 ))
while :; do
  now=$(prom_query 'cosmos:db_connections:sum' 2>/dev/null || true)
  if [ -z "$now" ]; then echo "Prometheus에 닿지 않아 DB 연결 수 대기를 건너뛴다"; break; fi
  if python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) <= float(sys.argv[2])+20 else 1)' "$now" "$before"; then
    echo "$(date +%s) DB 연결 수 복구($now <= $before+20)" >> "$RECORD_DIR/s1p-events"; break
  fi
  (( $(date +%s) < deadline )) || { echo "DB 연결 수가 300초 안에 내려가지 않았다($now > $before+20)" >&2; break; }
  sleep 10
done
