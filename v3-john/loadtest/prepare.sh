#!/usr/bin/env bash
# 부하 테스트 준비: 시드 데이터를 넣고 테스트 사용자 토큰을 만든다. 결과는 $OUT에 둔다.
#   v3-john/loadtest/prepare.sh            # 시드 + 토큰 (3시간 유효)
#   k6 run -e TOKENS=$OUT/tokens.json -e PROBLEMS=$OUT/problems.json v3-john/loadtest/baseline.js
source "$(dirname "$0")/../scripts/common.sh"
OUT="${OUT:-${TMPDIR:-/tmp}/cosmos-loadtest}"; mkdir -p "$OUT"; chmod 700 "$OUT"
HOST=$(tf output -raw mysql_address)
DB_SECRET="cosmos/$ENV_NAME/main-db"

# restore-mysql.sh와 같은 방식: 대기 파드 + 3306 송신 허용 + kubectl exec
kubectl create secret generic loadtest-db -n prod \
  --from-literal="user=$(secret_key "$DB_SECRET" username)" \
  --from-literal="password=$(secret_key "$DB_SECRET" password)" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -f - >/dev/null <<YAML
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: loadtest-db, namespace: prod }
spec:
  podSelector: { matchLabels: { run: loadtest-db } }
  policyTypes: [Egress]
  egress:
    - to: [ { ipBlock: { cidr: 10.30.20.0/23 } } ]
      ports: [ { protocol: TCP, port: 3306 } ]
YAML
cleanup() { kubectl delete pod,networkpolicy,secret loadtest-db -n prod --ignore-not-found --wait=false >/dev/null; }
trap cleanup EXIT
overrides=$(python3 -c 'import json;print(json.dumps({"spec":{"containers":[{"name":"loadtest-db","image":"mysql:8.4","command":["sleep","600"],
  "env":[{"name":"DB_USER","valueFrom":{"secretKeyRef":{"name":"loadtest-db","key":"user"}}},
         {"name":"MYSQL_PWD","valueFrom":{"secretKeyRef":{"name":"loadtest-db","key":"password"}}}]}]}}))')
kubectl delete pod loadtest-db -n prod --ignore-not-found --wait=true >/dev/null
kubectl run loadtest-db -n prod --restart=Never --image=mysql:8.4 --labels=run=loadtest-db --overrides="$overrides" >/dev/null 2>&1
kubectl wait -n prod --for=condition=Ready pod/loadtest-db --timeout=180s >/dev/null

result=$(kubectl exec -i -n prod loadtest-db -- sh -c 'mysql -h "$0" -u "$DB_USER" cosmos -N' "$HOST" < "$(dirname "$0")/seed.sql")
read -r _ first last <<<"$(grep '^USERS' <<<"$result")"
grep '^PROBLEMS' <<<"$result" | cut -d' ' -f2 | python3 -c 'import sys,json;print(json.dumps([int(x) for x in sys.stdin.read().strip().split(",")]))' > "$OUT/problems.json"
python3 "$(dirname "$0")/mint_tokens.py" "$OUT/tokens.json" "$first" "$last" 10800
chmod 600 "$OUT/tokens.json"
echo "준비 완료: $OUT (사용자 ID $first~$last)"
