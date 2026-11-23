#!/usr/bin/env bash
# S1 단계 4: rollout.enabled면 Rollout(workloadRef), AnalysisTemplate core-health, HPA 대상 변경이 렌더링되는지 확인한다.
set -uo pipefail
C=$(cd "$(dirname "$0")/.." && pwd); P=$C/../../environments/prod; fail=0
ok() { echo "PASS $1"; }; no() { echo "FAIL $1"; fail=1; }
kind() { awk -v k="kind: $1" '$0==k{f=1} f{print} /^---/{if(f)exit}'; }
on=$(helm template t "$C" -n prod -f "$P/core.yaml" --set rollout.enabled=true 2>&1)
ro=$(kind Rollout <<<"$on")
grep -A4 'workloadRef' <<<"$ro" | grep -q 'kind: Deployment' && grep -A4 'workloadRef' <<<"$ro" | grep -q 'name: cosmos-core' && ok "Rollout workloadRef → Deployment" || no "workloadRef"
grep -q 'scaleDown: progressively' <<<"$ro" && ok "scaleDown progressively" || no "scaleDown"
steps=$(grep -E 'setWeight|templateName' <<<"$ro" | tr -d ' -' | tr '\n' ' ')
[ "$steps" = "setWeight:50 templateName:corehealth setWeight:100 " ] && ok "단계 50 → 분석 → 100" || no "단계 [$steps]"
at=$(kind AnalysisTemplate <<<"$on")
grep -q 'name: core-health' <<<"$at" && ok "AnalysisTemplate core-health" || no "AnalysisTemplate"
grep -q 'cosmos:journey_error_ratio:rate5m{journey="core"}' <<<"$at" && grep -q 'result\[0\] < 0.072' <<<"$at" && ok "오류율 조건" || no "오류율 조건"
grep -q 'kube_pod_container_status_restarts_total{namespace="prod",pod=~"cosmos-core-.\*"}' <<<"$at" && grep -q 'result\[0\] == 0' <<<"$at" && ok "재시작 조건" || no "재시작 조건"
grep -q 'interval: 1m' <<<"$at" && grep -q 'count: 5' <<<"$at" && ok "분석 5분(1분 간격 5회)" || no "분석 기간"
h=$(kind HorizontalPodAutoscaler <<<"$on")
grep -A3 scaleTargetRef <<<"$h" | grep -q 'kind: Rollout' && grep -A3 scaleTargetRef <<<"$h" | grep -q 'apiVersion: argoproj.io/v1alpha1' && ok "HPA 대상 Rollout" || no "HPA 대상"
off=$(helm template t "$C" -n prod -f "$P/auth.yaml" 2>&1)
grep -q 'kind: Rollout' <<<"$off" && no "auth에 Rollout" || ok "rollout 꺼지면 Rollout 없음"
grep -A3 scaleTargetRef <<<"$(kind HorizontalPodAutoscaler <<<"$off")" | grep -q 'kind: Deployment' && ok "꺼지면 HPA 대상 Deployment" || no "꺼진 HPA 대상"
exit $fail
