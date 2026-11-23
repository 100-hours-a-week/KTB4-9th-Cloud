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
grep -q 'progressDeadlineSeconds: 300' <<<"$ro" && grep -q 'progressDeadlineAbort: true' <<<"$ro" && ok "준비 못 하는 카나리는 300초 뒤 자동 중단" || no "progressDeadline"
steps=$(grep -E 'setWeight|templateName' <<<"$ro" | tr -d ' -' | tr '\n' ' ')
[ "$steps" = "setWeight:50 templateName:corehealth setWeight:100 " ] && ok "단계 50 → 분석 → 100" || no "단계 [$steps]"
at=$(kind AnalysisTemplate <<<"$on")
grep -q 'name: core-health' <<<"$at" && ok "AnalysisTemplate core-health" || no "AnalysisTemplate"
grep -q 'cosmos:journey_error_ratio:rate5m{journey="core"}' <<<"$at" && grep -q 'result\[0\] < 0.072' <<<"$at" && ok "오류율 조건" || no "오류율 조건"
# 트래픽이 없으면 비율이 NaN이고 NaN < 0.072는 거짓이라 정상 배포가 중단된다(2026-11-23 리비전 4). NaN을 0으로 본다.
grep -q 'max(cosmos:journey_error_ratio:rate5m{journey="core"} >= 0) or vector(0)' <<<"$at" && ok "트래픽 없을 때 NaN을 0으로" || no "NaN 처리"
grep -q 'kube_pod_container_status_restarts_total{namespace="prod",pod=~"cosmos-core-.\*"}' <<<"$at" && grep -q 'result\[0\] == 0' <<<"$at" && ok "재시작 조건" || no "재시작 조건"
grep -q 'interval: 1m' <<<"$at" && grep -q 'count: 5' <<<"$at" && ok "분석 5분(1분 간격 5회)" || no "분석 기간"
# S1' 단계 3: connectionGuard를 켜면 공유 자원(DB 연결)과 다른 경로 오류율 지표가 추가된다.
g=$(helm template t "$C" -n prod -f "$P/core.yaml" --set rollout.enabled=true --set rollout.connectionGuard.enabled=true --set rollout.connectionGuard.rdsMax=300 --set rollout.connectionGuard.reserve=30 2>&1)
gat=$(kind AnalysisTemplate <<<"$g")
grep -q 'name: db-connection-headroom' <<<"$gat" && grep -q 'name: other-routes-error' <<<"$gat" && ok "connectionGuard 켜면 지표 두 개 추가" || no "connectionGuard 지표"
grep -q 'cosmos:db_connections:sum or vector(0)' <<<"$gat" && ok "연결 수 질의에 or vector(0)" || no "연결 수 질의"
grep -q 'result\[0\] <= 270' <<<"$gat" && ok "성공 조건에 rdsMax - reserve(270) 렌더링" || no "연결 여유 조건"
grep -q 'len(result) == 0 || result\[0\] <= 270' <<<"$gat" && ok "연결 여유: 결과 없음은 통과" || no "연결 여유 빈 결과"
grep -q 'max(cosmos:journey_error_ratio_all:rate5m{journey="major"} >= 0) or vector(0)' <<<"$gat" && ok "다른 경로 오류율 질의(NaN 처리)" || no "다른 경로 질의"
grep -q 'route="journey-core-auth"' <<<"$gat" && ok "auth 경로 오류율 질의" || no "auth 경로 질의"
[ "$(grep -c 'result\[0\] < 0.05' <<<"$gat")" -ge 2 ] && grep -c 'len(result) == 0 || result\[0\] < 0.05' <<<"$gat" | grep -q '^2$' && ok "다른 경로 조건 0.05 두 곳, 빈 결과 통과" || no "다른 경로 조건"
[ "$(grep -c 'interval: 1m' <<<"$gat")" = 5 ] && [ "$(grep -c 'count: 5' <<<"$gat")" = 5 ] && [ "$(grep -c 'failureLimit: 0' <<<"$gat")" = 5 ] && ok "새 지표도 1분 5회 실패 허용 0" || no "새 지표 간격"
offat=$(helm template t "$C" -n prod -f "$P/core.yaml" --set rollout.connectionGuard.enabled=false 2>&1 | kind AnalysisTemplate)
[ "$(grep -c '^    - name:' <<<"$offat")" = 2 ] && ! grep -q 'db-connection-headroom' <<<"$offat" && ok "꺼지면 1차와 같은 두 지표만" || no "꺼진 지표 수"
h=$(kind HorizontalPodAutoscaler <<<"$on")
grep -A3 scaleTargetRef <<<"$h" | grep -q 'kind: Rollout' && grep -A3 scaleTargetRef <<<"$h" | grep -q 'apiVersion: argoproj.io/v1alpha1' && ok "HPA 대상 Rollout" || no "HPA 대상"
off=$(helm template t "$C" -n prod -f "$P/auth.yaml" 2>&1)
grep -q 'kind: Rollout' <<<"$off" && no "auth에 Rollout" || ok "rollout 꺼지면 Rollout 없음"
grep -A3 scaleTargetRef <<<"$(kind HorizontalPodAutoscaler <<<"$off")" | grep -q 'kind: Deployment' && ok "꺼지면 HPA 대상 Deployment" || no "꺼진 HPA 대상"
exit $fail
