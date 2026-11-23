#!/usr/bin/env bash
# k6를 클러스터 안 Job으로 실행하고, 끝나면 요약 JSON을 $OUT/<testid>.json에 둔다.
#   v3-john/loadtest/k8s/run-k6.sh <testid> <duration> [vus]
#   예) run-k6.sh baseline-1 10m 10      AI=1 run-k6.sh ai-1 10m 10
#   K6_AVOID_NODE=<노드 이름>을 주면 k6 파드가 그 노드에 뜨지 않는다(실험 대상 노드 회수에 부하 발생기가 같이 죽지 않게).
#   RATE=<초당 반복 수>를 주면 열린 부하 모델로 돈다. 예) RATE=20 run-k6.sh open-1 10m
# 종료 코드: 0 성공, 1 Job 실패(k6 오류), 2 사용법·사전 조건 오류.
# 전제: prepare.sh로 Secret loadtest/k6-inputs가 있어야 한다.
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
TESTID=${1:-}; DURATION=${2:-}; VUS=${3:-10}
OUT="${OUT:-${TMPDIR:-/tmp}/cosmos-loadtest}"
usage() { echo "사용: $0 <testid> <duration(예: 10m)> [vus]" >&2; exit 2; }
[[ "$TESTID" =~ ^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$ ]] || { echo "testid는 소문자, 숫자, -로 40자 이내" >&2; usage; }
[[ "$DURATION" =~ ^[0-9]+[smh]$ ]] || usage
[[ "$VUS" =~ ^[0-9]+$ ]] || usage
RATE=${RATE:-}
[[ -z "$RATE" || "$RATE" =~ ^[0-9]+$ ]] || usage

to_sec() { local n=${1%[smh]}; case ${1: -1} in s) echo "$n";; m) echo $((n*60));; h) echo $((n*3600));; esac; }
DUR_S=$(to_sec "$DURATION")

kubectl get secret k6-inputs -n loadtest >/dev/null 2>&1 || { echo "Secret loadtest/k6-inputs가 없다. prepare.sh를 먼저 실행한다." >&2; exit 2; }
exp=$(kubectl get secret k6-inputs -n loadtest -o jsonpath='{.data.expires_at}' | base64 -d)
now=$(date +%s)
if (( exp < now + DUR_S + 300 )); then
  echo "토큰이 실행 도중 만료된다(남은 시간 $(( (exp-now)/60 ))분). prepare.sh를 다시 실행한다." >&2; exit 2
fi

# Envoy Gateway가 만든 Service 이름에는 해시가 붙으므로 라벨로 찾는다.
SVC=$(kubectl get svc -n envoy-gateway-system \
  -l gateway.envoyproxy.io/owning-gateway-name=prod,gateway.envoyproxy.io/owning-gateway-namespace=prod \
  -o jsonpath='{.items[0].metadata.name}')
[ -n "$SVC" ] || { echo "prod Gateway의 Envoy Service를 찾지 못했다" >&2; exit 2; }
BASE="http://$SVC.envoy-gateway-system.svc.cluster.local/api"

kubectl create configmap k6-script -n loadtest --from-file=baseline.js="$DIR/../baseline.js" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl delete job "k6-$TESTID" -n loadtest --ignore-not-found --wait=true >/dev/null

render_job() {
  local avoid=${K6_AVOID_NODE:-}
  if [ -n "$avoid" ]; then
    [[ "$avoid" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "K6_AVOID_NODE 형식이 올바르지 않다" >&2; exit 2; }
    # 치환할 줄을 YAML 조각으로 바꾼다. 줄 시작 공백은 spec.template.spec 들여쓰기(6칸)와 맞춘다.
    local aff="      affinity: { nodeAffinity: { requiredDuringSchedulingIgnoredDuringExecution: { nodeSelectorTerms: [ { matchExpressions: [ { key: kubernetes.io/hostname, operator: NotIn, values: [ \"$avoid\" ] } ] } ] } } }"
    awk -v aff="$aff" '$0=="__AFFINITY__"{print aff; next} {print}' "$DIR/job.yaml"
  else
    grep -v '^__AFFINITY__$' "$DIR/job.yaml"
  fi
}
render_job | sed -e "s|__TESTID__|$TESTID|g" -e "s|__BASE__|$BASE|g" -e "s|__VUS__|$VUS|g" \
    -e "s|__DURATION__|$DURATION|g" -e "s|__AI__|${AI:-0}|g" -e "s|__RATE__|$RATE|g" -e "s|__DEADLINE__|$((DUR_S + 600))|g" \
    | kubectl apply -f - >/dev/null
echo "k6-$TESTID 시작: $VUS VU, $DURATION, 대상 $BASE"

# 완료 또는 실패까지 기다린다(실행 길이 + 10분).
deadline=$(( $(date +%s) + DUR_S + 600 ))
state=""
while (( $(date +%s) < deadline )); do
  state=$(kubectl get job "k6-$TESTID" -n loadtest -o jsonpath='{range .status.conditions[?(@.status=="True")]}{.type}{" "}{end}')
  [[ "$state" == *Complete* || "$state" == *Failed* ]] && break
  sleep 10
done

mkdir -p "$OUT"; chmod 700 "$OUT"
kubectl logs "job/k6-$TESTID" -n loadtest > "$OUT/$TESTID.log" 2>&1 || true
grep -o '@@K6_SUMMARY@@.*' "$OUT/$TESTID.log" | sed 's/^@@K6_SUMMARY@@//' > "$OUT/$TESTID.json" || true
grep 'submit 4xx' "$OUT/$TESTID.log" || true

if [[ "$state" == *Complete* && -s "$OUT/$TESTID.json" ]]; then
  echo "k6-$TESTID 완료: $OUT/$TESTID.json"
else
  echo "k6-$TESTID 실패(상태: ${state:-시간 초과}). 로그: $OUT/$TESTID.log" >&2; exit 1
fi
