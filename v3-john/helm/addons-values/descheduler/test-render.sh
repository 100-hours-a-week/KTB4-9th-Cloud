#!/usr/bin/env bash
# descheduler 값 렌더 검사. 클러스터 없이 helm template 결과만 확인한다.
set -euo pipefail
cd "$(dirname "$0")"
VER=0.37.0
OUT=$(helm template descheduler descheduler/descheduler --version "$VER" --namespace kube-system -f values.yaml)
fail=0
chk() { if ! grep -Eq -- "$2" <<<"$OUT"; then echo "FAIL: $1"; fail=1; else echo "ok: $1"; fi; }
nochk() { if grep -Eq -- "$2" <<<"$OUT"; then echo "FAIL: $1"; fail=1; else echo "ok: $1"; fi; }
chk "이미지가 digest로 고정됨" 'image: "registry.k8s.io/descheduler/descheduler:v[0-9.]+@sha256:[0-9a-f]{64}"'
chk "Deployment 종류" '^kind: Deployment'
chk "주기 2분" '--descheduling-interval=2m'
chk "토폴로지 분산 위반 플러그인 활성" 'RemovePodsViolatingTopologySpreadConstraint'
chk "ScheduleAnyway 포함" 'ScheduleAnyway'
chk "DoNotSchedule 포함" 'DoNotSchedule'
chk "대상 네임스페이스 prod" '^ +- prod$'
chk "대상 네임스페이스 envoy-gateway-system" '^ +- envoy-gateway-system$'
chk "system 노드에서 실행" 'workload-class: system'
chk "CriticalAddonsOnly 톨러레이션" 'CriticalAddonsOnly'
for p in LowNodeUtilization HighNodeUtilization RemoveDuplicates RemovePodsHavingTooManyRestarts RemovePodsViolatingNodeAffinity RemovePodsViolatingNodeTaints RemovePodsViolatingInterPodAntiAffinity RemoveFailedPods PodLifeTime; do
  nochk "다른 플러그인 없음: $p" "$p"
done
nochk "시스템 핵심 파드 보호 해제 없음" 'SystemCriticalPods'
nochk "로컬 저장소 보호 해제 없음" 'PodsWithLocalStorage'
exit $fail
