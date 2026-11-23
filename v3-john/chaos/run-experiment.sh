#!/usr/bin/env bash
# 장애 주입 실험 실행기. 정상 상태 확인 → 부하 → 주입 → 중단 조건 감시 → 원복 → 회복 관찰 → 집계와 기록.
#   v3-john/chaos/run-experiment.sh <scenario> <step> [--inject-after 3m] [--recover 10m] [--vus 10] [--inject-duration 5m]
#   예) run-experiment.sh noop smoke --inject-after 3m --recover 2m
# 시나리오 계약(scenarios/<id>/):
#   inject.sh  주입하고 바로 끝난다.        stop.sh  원복한다. 여러 번 불려도 안전해야 한다.
#   scenario.env (선택) INJECT_DURATION=<초>  주입을 유지할 시간. 기본 300초, 최대 600초.
#   두 스크립트는 RECORD_DIR(이번 실험 기록 폴더)과 SCENARIO, STEP 환경 변수를 받는다.
# 끊겨도(Ctrl+C, 오류, 잠자기 후 종료) 주입이 남지 않게 EXIT/INT/TERM에서 stop.sh를 부른다.
set -euo pipefail
CHAOS=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$CHAOS/.." && pwd)
source "$CHAOS/lib/guard.sh"
source "$CHAOS/lib/annotate.sh"

usage() { sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
SCENARIO=${1:-}; STEP=${2:-}; shift 2 || usage
INJECT_AFTER=3m RECOVER=10m VUS=10 INJECT_DURATION_OPT=""
while [ $# -gt 0 ]; do
  case $1 in
    --inject-after) INJECT_AFTER=$2; shift 2;;
    --recover) RECOVER=$2; shift 2;;
    --vus) VUS=$2; shift 2;;
    --inject-duration) INJECT_DURATION_OPT=$2; shift 2;;
    *) usage;;
  esac
done
SDIR="$CHAOS/scenarios/$SCENARIO"
[[ "$SCENARIO" =~ ^[a-z0-9-]+$ && "$STEP" =~ ^[a-z0-9-]+$ ]] || usage
[ -x "$SDIR/inject.sh" ] && [ -x "$SDIR/stop.sh" ] || { echo "시나리오 $SCENARIO에 inject.sh, stop.sh가 없다" >&2; exit 2; }
to_sec() { local n=${1%[smh]}; case ${1: -1} in s) echo "$n";; m) echo $((n*60));; h) echo $((n*3600));; *) echo "$1";; esac; }
INJECT_DURATION=300; [ -f "$SDIR/scenario.env" ] && source "$SDIR/scenario.env"
[ -n "$INJECT_DURATION_OPT" ] && INJECT_DURATION=$(to_sec "$INJECT_DURATION_OPT")
(( INJECT_DURATION <= GUARD_MAX_INJECT_S )) || { echo "주입 유지 시간은 ${GUARD_MAX_INJECT_S}초를 넘을 수 없다" >&2; exit 2; }
AFTER_S=$(to_sec "$INJECT_AFTER"); RECOVER_S=$(to_sec "$RECOVER")
(( AFTER_S >= 150 )) || { echo "--inject-after는 정상 상태 확인(2분)과 부하 예열을 위해 150초 이상이어야 한다" >&2; exit 2; }
K6_S=$(( AFTER_S + INJECT_DURATION + RECOVER_S + 60 ))

STAMP=$(date +%Y%m%d-%H%M)
NAME="$SCENARIO-$STEP-$STAMP"
TESTID=$(echo "$SCENARIO-$STEP-$(date +%m%d%H%M)" | cut -c1-40 | sed 's/-*$//')
export RECORD_DIR="$CHAOS/records/$NAME" SCENARIO STEP TESTID
mkdir -p "$RECORD_DIR"
LOG="$RECORD_DIR/run.log"
log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

PF_PIDS=() K6_PID="" INJECTED=0 STOPPED=0 ABORTED="" MITIGATED_AT=""
cleanup() {
  local rc=$?
  if (( INJECTED && !STOPPED )); then
    log "종료 감지: stop.sh 실행"; "$SDIR/stop.sh" >>"$LOG" 2>&1 || log "stop.sh 실패. 수동 원복 필요"
    STOPPED=1
  fi
  if [ -n "$ABORTED" ] || (( rc != 0 )); then
    kubectl delete job "k6-$TESTID" -n loadtest --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
  [ -n "$K6_PID" ] && kill "$K6_PID" 2>/dev/null || true
  for p in "${PF_PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done
  exit $rc
}
trap cleanup EXIT
trap 'ABORTED=${ABORTED:-signal}; exit 130' INT TERM

port_forward() { # <서비스> <로컬 포트> <원격 포트>
  kubectl port-forward -n monitoring "svc/$1" "$2:$3" >/dev/null 2>&1 & PF_PIDS+=($!)
}
port_forward kube-prometheus-stack-prometheus 19090 9090
port_forward kube-prometheus-stack-alertmanager 19093 9093
port_forward kube-prometheus-stack-grafana 13000 80
for _ in $(seq 20); do _prom_ok && _am_ok && break; sleep 1; done

# 1. 사전 검사
log "사전 검사: $NAME (주입 전 ${AFTER_S}s, 주입 ${INJECT_DURATION}s, 회복 ${RECOVER_S}s, $VUS VU)"
reason=$(guard_check) || { log "중단 조건 위반: $reason"; exit 1; }
exp=$(kubectl get secret k6-inputs -n loadtest -o jsonpath='{.data.expires_at}' 2>/dev/null | base64 -d || echo 0)
if (( ${exp:-0} < $(date +%s) + K6_S + 600 )); then
  log "테스트 토큰이 실험 도중 만료된다. prepare.sh를 다시 실행한다."; exit 1
fi
leftover=0
for kind in $(kubectl api-resources --api-group=chaos-mesh.org -o name 2>/dev/null | grep -v -E 'schedules|workflow|physicalmachine|remotecluster|statuscheck|^pod(network|http|io)chaos'); do
  # pod*chaos는 컨트롤러가 파드마다 남기는 내부 기록이다. 실험 리소스를 지우면 규칙이 비워지지만 객체는 남는다.
  leftover=$(( leftover + $(kubectl get "$kind" -A --no-headers 2>/dev/null | wc -l) ))
done
(( leftover == 0 )) || { log "남은 Chaos Mesh 리소스 ${leftover}개. 먼저 정리한다."; exit 1; }
running=$(aws fis list-experiments --region ap-northeast-2 \
  --query "length(experiments[?state.status=='running' || state.status=='initiating'])" --output text) \
  || { log "FIS 실험 목록을 확인할 수 없다(AWS 인증 확인)"; exit 1; }
(( running == 0 )) || { log "실행 중인 FIS 실험 ${running}개. 먼저 멈춘다."; exit 1; }
# 이전 stage.sh가 중단돼 cordon이 남으면 노드 한 대가 비어 있는 채로 실험하게 된다.
cordoned=$(kubectl get nodes -l workload-class=application -o jsonpath='{range .items[?(@.spec.unschedulable==true)]}{.metadata.name}{" "}{end}' 2>/dev/null) \
  || { log "application 노드 상태를 확인할 수 없다"; exit 1; }
[ -z "${cordoned// /}" ] || { log "cordon된 application 노드가 있다: ${cordoned}. kubectl uncordon 후 다시 실행한다."; exit 1; }

# 2. 배포 리비전 기록
revisions() { kubectl get applications.argoproj.io -n argocd -o json | python3 -c '
import json,sys; st=lambda i: i.get("status",{})
# 마지막으로 실제 동기화한 리비전. 자동 동기화가 없는 앱은 sync.revision이 비교 대상(HEAD)만 따라가므로 쓰지 않는다(2026-11-23 s3a).
rev=lambda i: (st(i).get("operationState",{}).get("syncResult",{}).get("revision") or st(i).get("sync",{}).get("revision"))
print(json.dumps({i["metadata"]["name"]: rev(i) for i in json.load(sys.stdin)["items"]}, indent=1))'; }
revisions > "$RECORD_DIR/revisions-before.json"

# 3. 부하 시작
T_START=$(date +%s)
OUT="$RECORD_DIR" "$ROOT/loadtest/k8s/run-k6.sh" "$TESTID" "${K6_S}s" "$VUS" >>"$LOG" 2>&1 & K6_PID=$!
log "k6-$TESTID 시작 (${K6_S}s)"

# 4. 정상 상태 확인: 주입 직전 2분 동안 핵심 요청이 있고, 오류율 0.5% 미만, 조회 p95 50ms 이하
while (( $(date +%s) < T_START + AFTER_S )); do
  reason=$(guard_check) || { ABORTED=$reason; log "중단 조건 위반(주입 전): $reason"; exit 1; }
  kill -0 "$K6_PID" 2>/dev/null || { log "k6가 일찍 끝났다. $RECORD_DIR/$TESTID.log 확인"; exit 1; }
  sleep 15
done
c='envoy_cluster_name=~"httproute/prod/journey-core-.+"'
req=$(prom_query "sum(increase(envoy_cluster_upstream_rq_total{$c}[2m]))")
err=$(prom_query "sum(increase(envoy_cluster_upstream_rq_xx{$c, envoy_response_code_class=\"5\"}[2m])) or vector(0)")
p95=$(prom_query 'histogram_quantile(0.95, sum by (le) (increase(envoy_cluster_upstream_rq_time_bucket{envoy_cluster_name=~"httproute/prod/journey-core-(auth|problem)/.+"}[2m])))')
steady=$(python3 -c '
import sys, math
req, err, p95 = (float(x) if x not in ("", "NaN") else float("nan") for x in sys.argv[1:4])
ok = req > 0 and not math.isnan(req) and (err / req) < 0.005 and not math.isnan(p95) and p95 <= 50
print("ok" if ok else f"요청 {req:.0f}, 5xx {err:.0f}, 조회 p95 {p95}ms")' "${req:-}" "${err:-0}" "${p95:-}")
if [ "$steady" != "ok" ]; then log "정상 상태가 아니라 주입하지 않는다: $steady"; ABORTED="steady-state"; exit 1; fi
log "정상 상태 확인: 핵심 요청 ${req%.*}, 조회 p95 ${p95}ms"

# 5. 주입
annotate "$SCENARIO $STEP 주입 시작" "chaos,$SCENARIO,$STEP" >/dev/null || log "Grafana 주석 실패(계속 진행)"
INJECT_START=$(date +%s); export INJECT_START; T_INJECT=$INJECT_START
INJECTED=1
"$SDIR/inject.sh" >>"$LOG" 2>&1 || { log "inject.sh 실패"; ABORTED="inject-failed"; exit 1; }
log "주입 완료. 최대 ${INJECT_DURATION}s 유지. 대응자 완화 신호: touch $RECORD_DIR/mitigate"

# 6. 주입 유지와 중단 조건 감시(15초마다)
# 남은 시간만큼만 잔다. 마지막 15초 대기가 10분 한도를 넘겨 duration 위반으로 끝나지 않게 한다(2026-11-20 s1 search에서 발생).
while :; do
  remaining=$(( INJECT_START + INJECT_DURATION - $(date +%s) ))
  (( remaining > 0 )) || break
  sleep $(( remaining < 5 ? remaining : 5 ))
  (( $(date +%s) < INJECT_START + INJECT_DURATION )) || break
  # 대응자가 완화를 결정하면 다른 터미널에서 `touch $RECORD_DIR/mitigate`. 바로 원복한다(완화 시각 측정).
  if [ -f "$RECORD_DIR/mitigate" ]; then MITIGATED_AT=$(date +%s); log "대응자 완화 신호: 원복"; break; fi
  reason=$(guard_check) || { ABORTED=$reason; log "중단 조건 위반: $reason"; break; }
done

# 7. 원복과 회복 관찰
"$SDIR/stop.sh" >>"$LOG" 2>&1 || log "stop.sh 실패. 수동 확인 필요"
STOPPED=1; T_STOP=$(date +%s); unset INJECT_START
annotate "$SCENARIO $STEP 원복" "chaos,$SCENARIO,$STEP" >/dev/null || true
log "원복. ${RECOVER_S}s 회복 관찰"
if [ -z "$ABORTED" ]; then
  while (( $(date +%s) < T_STOP + RECOVER_S )); do
    sleep 15
    reason=$(guard_check) || { ABORTED=$reason; log "중단 조건 위반(회복 중): $reason"; break; }
  done
fi
T_END=$(date +%s)
if [ -z "$ABORTED" ]; then wait "$K6_PID" || log "k6 실패(기록에 남김)"; fi
K6_PID=""

# 8~10. 집계, 리비전 비교, 저장
# k6를 기다리는 동안 port-forward가 끊길 수 있다(2026-11-23 s1-step2 집계 실패). 집계 전에 다시 잇는다.
if ! _prom_ok; then
  log "Prometheus 연결이 끊겨 port-forward를 다시 연다"
  port_forward kube-prometheus-stack-prometheus 19090 9090
  for _ in $(seq 20); do _prom_ok && break; sleep 1; done
fi
# 시나리오가 직접 병합한 리비전(scenarios/*가 $RECORD_DIR/own-revisions에 남김)은 외부 배포로 보지 않는다.
OWN_REV=""; [ -s "$RECORD_DIR/own-revisions" ] && OWN_REV="$RECORD_DIR/own-revisions"
revisions > "$RECORD_DIR/revisions-after.json"
python3 "$CHAOS/lib/aggregate.py" --prom "$PROM_URL" --scenario "$SCENARIO" --step "$STEP" --testid "$TESTID" \
  --start "$T_START" --inject "$T_INJECT" \
  --stop "$T_STOP" --end "$T_END" \
  --rev-before "$RECORD_DIR/revisions-before.json" --rev-after "$RECORD_DIR/revisions-after.json" \
  ${OWN_REV:+--own-revisions "$OWN_REV"} ${MITIGATED_AT:+--mitigated "$MITIGATED_AT"} \
  ${ABORTED:+--aborted "$ABORTED"} > "$RECORD_DIR/record.json"
cp "$RECORD_DIR/record.json" "$CHAOS/records/$NAME.json"
python3 "$CHAOS/lib/render_record.py" "$CHAOS/records/$NAME.json" > "$CHAOS/records/$NAME.md" || log "기록 md 생성 실패"
aws s3 cp --recursive --quiet "$RECORD_DIR" "s3://cosmos-db-backup-352635536602/chaos/$NAME/" || log "S3 업로드 실패(로컬 기록은 남음)"
log "기록: v3-john/chaos/records/$NAME.json"
[ -z "$ABORTED" ] || exit 1
