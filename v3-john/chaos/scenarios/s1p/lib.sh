# S1' 공통: s1/lib.sh의 값 파일 경로와 병합 흐름을 재사용하고, 임의의 편집 명령으로 core 값 파일을 바꾸는 병합 함수를 더한다.
# 사용자 승인(2026-11-24): S1' 주입·원복 PR은 main에 자동 병합한다.
source "$(dirname "${BASH_SOURCE[0]}")/../s1/lib.sh"
S1P_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# 현재 origin/main의 core 풀 크기
s1p_current() {
  git -C "$GIT_DIR_ROOT" fetch -q origin main
  git -C "$GIT_DIR_ROOT" show "origin/main:$VALUES" | sed -n 's/^  SPRING_DATASOURCE_HIKARI_MAXIMUM_POOL_SIZE: "\([0-9]*\)".*/\1/p'
}

# s1p_merge_edit <커밋 메시지> <편집 명령...> : 편집 명령은 마지막 인자로 작업 트리의 core 값 파일 경로를 받는다.
# 작업 트리 → 편집 → 커밋 → PR → 병합 → own-revisions 기록 → Argo CD 새로 고침 → 동기화 대기(s1_merge와 같은 흐름)
s1p_merge_edit() {
  local msg=$1 wt br pr sha; shift
  # core Rollout은 workloadRef라 값 변경이 generation을 올리지 않는다. 파드 템플릿 해시로 배포 완료를 판정한다.
  S1P_HASH_BEFORE=$(kubectl get rollout cosmos-core -n prod -o jsonpath='{.status.currentPodHash}' 2>/dev/null || true)
  br="chaos/s1p-$(date +%Y%m%d-%H%M%S)"
  wt=$(mktemp -d)
  git -C "$GIT_DIR_ROOT" worktree add -q -b "$br" "$wt" origin/main
  "$@" "$wt/$VALUES"
  git -C "$wt" commit -q -am "$msg"
  git -C "$wt" push -q origin "$br"
  pr=$(gh pr create --repo "$REPO" --base main --head "$br" --title "$msg" \
        --body "장애 주입 실험 S1'(v3-john/chaos/scenarios/s1p)이 만든 PR이다. 실험 기록: ${RECORD_DIR#*/v3-john/}" | grep -o '[0-9]*$')
  gh pr merge "$pr" --repo "$REPO" --merge --delete-branch >/dev/null
  sha=$(gh pr view "$pr" --repo "$REPO" --json mergeCommit -q .mergeCommit.oid)
  git -C "$GIT_DIR_ROOT" worktree remove --force "$wt"; git -C "$GIT_DIR_ROOT" branch -q -D "$br" 2>/dev/null || true
  echo "$sha" >> "$RECORD_DIR/own-revisions"
  echo "$(date +%s) PR #$pr 병합 $sha" >> "$RECORD_DIR/s1p-events"
  echo "PR #$pr 병합: $sha"
  kubectl annotate application prod-core -n argocd argocd.argoproj.io/refresh=normal --overwrite >/dev/null
  for _ in $(seq 60); do
    [ "$(kubectl get application prod-core -n argocd -o jsonpath='{.status.sync.revision}')" = "$sha" ] && break; sleep 5
  done
  [ "$(kubectl get application prod-core -n argocd -o jsonpath='{.status.sync.revision}')" = "$sha" ] || { echo "Argo CD가 $sha로 동기화하지 않았다" >&2; return 1; }
  # sync.revision은 비교한 리비전일 뿐이므로, 그 리비전의 동기화 작업이 성공으로 끝났는지도 확인한다.
  for _ in $(seq 60); do
    [ "$(kubectl get application prod-core -n argocd -o jsonpath='{.status.operationState.phase}')" = Succeeded ] &&
    [ "$(kubectl get application prod-core -n argocd -o jsonpath='{.status.operationState.syncResult.revision}')" = "$sha" ] && break; sleep 5
  done
  [ "$(kubectl get application prod-core -n argocd -o jsonpath='{.status.operationState.syncResult.revision}')" = "$sha" ] || { echo "Argo CD 동기화 작업이 $sha로 성공하지 않았다" >&2; return 1; }
  echo "$(date +%s) Argo CD 동기화 $sha" >> "$RECORD_DIR/s1p-events"
}

_s1p_edit_pool() { python3 "$S1P_DIR/set_pool.py" "$2" "$1"; }  # <n> <값 파일>

# s1p_merge_pool <n> <커밋 메시지> : core 풀 크기만 바꿔 병합한다.
s1p_merge_pool() { s1p_merge_edit "$2" _s1p_edit_pool "$1"; }

# s1p_wait_core_healthy <초> [<병합 전 파드 해시>] : 새 템플릿(currentPodHash != 병합 전)이 안정(stableRS)이 되고
# Rollout이 Healthy일 때까지 기다린다. 카나리 분석 포함. core Rollout은 workloadRef라 generation으로는 판정할 수 없다.
s1p_wait_core_healthy() {
  local deadline=$(( $(date +%s) + $1 )) before=${2:-} cur stable phase
  while :; do
    cur=$(kubectl get rollout cosmos-core -n prod -o jsonpath='{.status.currentPodHash}' 2>/dev/null || true)
    stable=$(kubectl get rollout cosmos-core -n prod -o jsonpath='{.status.stableRS}' 2>/dev/null || true)
    phase=$(kubectl get rollout cosmos-core -n prod -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [ -n "$cur" ] && [ "$cur" = "$stable" ] && [ "$phase" = Healthy ] && { [ -z "$before" ] || [ "$cur" != "$before" ]; }; then return 0; fi
    (( $(date +%s) >= deadline )) && { echo "core Rollout이 ${1}초 안에 Healthy가 되지 않았다(현재 해시=$cur 안정=$stable 병합 전=$before phase=$phase)" >&2; return 1; }
    sleep 5
  done
}
# s1p_wait_core_settled <초> [<병합 전 파드 해시>] : 새 템플릿이 안정이 되고 Healthy면 0, 새 템플릿의 카나리가 중단되면
# (status.abort=true) 3, 시간 안에 둘 다 아니면 1. 영향 범위 카나리(S1' 단계 3)가 배포를 멈추는 것도 실험 결과이므로 실패로 보지 않는다.
s1p_wait_core_settled() {
  local deadline=$(( $(date +%s) + $1 )) before=${2:-} cur stable phase abort
  while :; do
    cur=$(kubectl get rollout cosmos-core -n prod -o jsonpath='{.status.currentPodHash}' 2>/dev/null || true)
    stable=$(kubectl get rollout cosmos-core -n prod -o jsonpath='{.status.stableRS}' 2>/dev/null || true)
    phase=$(kubectl get rollout cosmos-core -n prod -o jsonpath='{.status.phase}' 2>/dev/null || true)
    abort=$(kubectl get rollout cosmos-core -n prod -o jsonpath='{.status.abort}' 2>/dev/null || true)
    if [ -n "$cur" ] && { [ -z "$before" ] || [ "$cur" != "$before" ]; }; then
      [ "$cur" = "$stable" ] && [ "$phase" = Healthy ] && return 0
      [ "$abort" = true ] && return 3
    fi
    (( $(date +%s) >= deadline )) && { echo "core Rollout이 ${1}초 안에 Healthy나 중단에 이르지 않았다(현재 해시=$cur 안정=$stable 병합 전=$before phase=$phase abort=$abort)" >&2; return 1; }
    sleep 5
  done
}
