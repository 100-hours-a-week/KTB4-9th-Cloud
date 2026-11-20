# Prometheus, Alertmanager, Grafana 접근. run-experiment.sh가 port-forward로 연결한 주소를 쓴다.
PROM_URL=${PROM_URL:-http://127.0.0.1:19090}
AM_URL=${AM_URL:-http://127.0.0.1:19093}
GRAFANA_URL=${GRAFANA_URL:-http://127.0.0.1:13000}

# prom_query <promql> [unix 시각] → 첫 결과 값 하나(없으면 빈 문자열). 질의 실패는 종료 코드 1.
prom_query() {
  local args=(--data-urlencode "query=$1"); [ -n "${2:-}" ] && args+=(--data-urlencode "time=$2")
  curl -sf -G --max-time 15 "$PROM_URL/api/v1/query" "${args[@]}" | python3 -c '
import json,sys
d=json.load(sys.stdin)
if d.get("status")!="success": sys.exit(1)
r=d["data"]["result"]
print(r[0]["value"][1] if r else "")'
}
