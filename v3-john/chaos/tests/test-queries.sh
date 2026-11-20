#!/usr/bin/env bash
# 실행기와 집계의 PromQL이 문법 오류 없이 실행되는지 빈 Prometheus로 확인한다. docker가 필요하다.
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
NAME=chaos-promql-test-$$
docker run -d --rm --name "$NAME" -p 19190:9090 prom/prometheus:v3.5.0 >/dev/null
trap 'docker rm -f "$NAME" >/dev/null 2>&1' EXIT
for _ in $(seq 30); do curl -sf http://127.0.0.1:19190/-/ready >/dev/null && break; sleep 1; done
now=$(date +%s)
W=$(mktemp -d); echo '{"a":"r1"}' > "$W/rev.json"
python3 "$DIR/../lib/aggregate.py" --prom http://127.0.0.1:19190 --scenario noop --step t --testid t \
  --start $((now-600)) --inject $((now-300)) --stop $((now-240)) --end $now --rev-before "$W/rev.json" --rev-after "$W/rev.json" > "$W/out.json"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["verdict_blockers"]==["핵심 요청 0건(1,000건 미만)"], d["verdict_blockers"]; print("PASS aggregate 질의", d["recovery_seconds_core"], d["detection"])' "$W/out.json"
PROM_URL=http://127.0.0.1:19190 bash -c 'source "'"$DIR"'/../lib/prom.sh"
c="envoy_cluster_name=~\"httproute/prod/journey-core-.+\""
prom_query "sum(increase(envoy_cluster_upstream_rq_total{$c}[2m]))" >/dev/null
prom_query "sum(increase(envoy_cluster_upstream_rq_xx{$c, envoy_response_code_class=\"5\"}[2m])) or vector(0)" >/dev/null
prom_query "histogram_quantile(0.95, sum by (le) (increase(envoy_cluster_upstream_rq_time_bucket{envoy_cluster_name=~\"httproute/prod/journey-core-(auth|problem)/.+\"}[2m])))" >/dev/null
[ "$(prom_query "vector(1)")" = "1" ]' && echo "PASS 정상 상태 질의"
rm -rf "$W"
