#!/usr/bin/env bash
# s1p_wait_core_healthy 테스트: 가짜 kubectl로 generation 조건을 확인한다. 실행: bash v3-john/chaos/tests/test-s1p-wait.sh
set -uo pipefail
DIR=$(cd "$(dirname "$0")" && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir "$T/bin"
cat > "$T/bin/kubectl" <<'K'
#!/usr/bin/env bash
case "$*" in
  *currentPodHash*) echo "$FAKE_CUR";; *stableRS*) echo "$FAKE_STABLE";; *status.phase*) echo "$FAKE_PHASE";;
  *status.abort*) echo "${FAKE_ABORT:-}";;
esac
K
chmod +x "$T/bin/kubectl"
source "$DIR/../scenarios/s1p/lib.sh"
PATH="$T/bin:$PATH"; fail=0
# core Rollout은 workloadRef로 Deployment 템플릿을 참조하므로 값 변경이 generation을 올리지 않는다(2026-11-24 실측).
# 그래서 배포 완료는 파드 템플릿 해시로 판정한다: 새 해시(currentPodHash != 병합 전)가 안정(stableRS)이 되고 Healthy.
check() { # 이름 기대(0/1) cur stable phase before
  FAKE_CUR=$3 FAKE_STABLE=$4 FAKE_PHASE=$5 s1p_wait_core_healthy 1 "${6:-}" >/dev/null 2>&1; local rc=$?
  [ "$rc" = "$2" ] && echo "ok   $1" || { echo "FAIL $1 (rc=$rc)"; fail=1; }
}
check "새 해시가 안정 + Healthy" 0 bbb bbb Healthy aaa
check "해시가 병합 전과 같으면 거부(Argo 반영 전)" 1 aaa aaa Healthy aaa
check "카나리 중(안정은 옛 해시)이면 거부" 1 bbb aaa Healthy aaa
check "Progressing이면 거부" 1 bbb bbb Progressing aaa
check "병합 전 값 없으면 해시 조건 생략" 0 aaa aaa Healthy ""
settled() { # 이름 기대 cur stable phase abort before
  FAKE_CUR=$3 FAKE_STABLE=$4 FAKE_PHASE=$5 FAKE_ABORT=$6 s1p_wait_core_settled 1 "${7:-}" >/dev/null 2>&1; local rc=$?
  [ "$rc" = "$2" ] && echo "ok   $1" || { echo "FAIL $1 (rc=$rc)"; fail=1; }
}
settled "settled: 새 해시 안정 + Healthy면 0" 0 bbb bbb Healthy "" aaa
settled "settled: 새 해시 카나리 중단이면 3" 3 bbb aaa Degraded true aaa
settled "settled: 병합 전 해시의 중단은 무시(시간 초과 1)" 1 aaa aaa Degraded true aaa
settled "settled: 카나리 진행 중이면 1" 1 bbb aaa Progressing "" aaa
# 병합 함수가 병합 전 해시를 남긴다
grep -q 'S1P_HASH_BEFORE=$(kubectl get rollout cosmos-core -n prod -o jsonpath=.{.status.currentPodHash}.' "$DIR/../scenarios/s1p/lib.sh" && echo "ok   병합 전 해시 기록" || { echo "FAIL 병합 전 해시 기록 없음"; fail=1; }
# 병합 편집 함수: 정의가 있고 풀 크기 한 줄만 바꾼다
if declare -F _s1p_edit_pool >/dev/null && declare -F s1p_merge_pool >/dev/null; then echo "ok   편집 함수 정의됨"; else echo "FAIL 편집 함수 없음"; fail=1; fi
cp "$DIR/../../gitops/environments/prod/core.yaml" "$T/core.yaml"
if _s1p_edit_pool 40 "$T/core.yaml" && grep -q '^  SPRING_DATASOURCE_HIKARI_MAXIMUM_POOL_SIZE: "40"$' "$T/core.yaml" \
   && [ "$(diff "$DIR/../../gitops/environments/prod/core.yaml" "$T/core.yaml" | grep -c '^>')" = 1 ]; then
  echo "ok   _s1p_edit_pool이 풀 한 줄만 40으로 변경"; else echo "FAIL _s1p_edit_pool 변경"; fail=1; fi
exit $fail
