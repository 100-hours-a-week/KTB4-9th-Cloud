# Grafana 주석. annotate <text> <쉼표로 나눈 태그> → 주석 id 출력.
# 관리자 계정은 monitoring/grafana-admin Secret에서 메모리로만 읽고 출력하지 않는다.
source "$(dirname "${BASH_SOURCE[0]}")/prom.sh"
annotate() {
  local user pass body
  user=$(kubectl get secret grafana-admin -n monitoring -o jsonpath='{.data.admin-user}' | base64 -d)
  pass=$(kubectl get secret grafana-admin -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d)
  body=$(python3 -c 'import json,sys,time; print(json.dumps({"time": int(time.time()*1000), "text": sys.argv[1], "tags": [t for t in sys.argv[2].split(",") if t]}))' "$1" "$2")
  # 계정을 명령줄 인자에 두지 않도록 curl 설정을 표준 입력으로 넘긴다.
  printf 'user = "%s:%s"\n' "$user" "$pass" | curl -sf --max-time 10 -K - -H 'Content-Type: application/json' -X POST "$GRAFANA_URL/api/annotations" -d "$body" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))'
}
