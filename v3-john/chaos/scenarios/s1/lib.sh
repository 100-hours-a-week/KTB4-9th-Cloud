# S1 공통: core 값 파일의 메모리 requests/limits를 바꾸는 PR을 만들어 main에 병합하고 Argo CD 동기화를 기다린다.
# 사용자 승인(2026-11-20): S1 주입·원복 PR은 main에 자동 병합한다.
REPO=100-hours-a-week/KTB4-9th-Cloud
VALUES=v3-john/gitops/environments/prod/core.yaml
GIT_DIR_ROOT=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)

# 현재 origin/main의 core 메모리 값 "requests limits"
s1_current() {
  git -C "$GIT_DIR_ROOT" fetch -q origin main
  git -C "$GIT_DIR_ROOT" show "origin/main:$VALUES" | python3 -c '
import re,sys
s=sys.stdin.read()
r=re.search(r"requests:\s*\{[^}]*memory:\s*([0-9A-Za-z]+)",s).group(1)
l=re.search(r"limits:\s*\{[^}]*memory:\s*([0-9A-Za-z]+)",s).group(1)
print(r,l)'
}

# s1_merge <requests> <limits> <커밋 메시지> → 병합 SHA를 own-revisions에 남기고 동기화와 롤아웃을 기다린다
s1_merge() {
  local req=$1 lim=$2 msg=$3 wt br pr sha
  br="chaos/s1-$(date +%Y%m%d-%H%M%S)"
  wt=$(mktemp -d)
  git -C "$GIT_DIR_ROOT" worktree add -q -b "$br" "$wt" origin/main
  python3 - "$wt/$VALUES" "$req" "$lim" <<'PY'
import re,sys
p,req,lim=sys.argv[1:4]
s=open(p).read()
s=re.sub(r"(requests:\s*\{[^}]*memory:\s*)[0-9A-Za-z]+",r"\g<1>"+req,s,count=1)
s=re.sub(r"(limits:\s*\{[^}]*memory:\s*)[0-9A-Za-z]+",r"\g<1>"+lim,s,count=1)
open(p,"w").write(s)
PY
  git -C "$wt" commit -q -am "$msg"
  git -C "$wt" push -q origin "$br"
  pr=$(gh pr create --repo "$REPO" --base main --head "$br" --title "$msg" \
        --body "장애 주입 실험 S1(v3-john/chaos/scenarios/s1)이 만든 PR이다. 실험 기록: ${RECORD_DIR#*/v3-john/}" | grep -o '[0-9]*$')
  gh pr merge "$pr" --repo "$REPO" --merge --delete-branch >/dev/null
  sha=$(gh pr view "$pr" --repo "$REPO" --json mergeCommit -q .mergeCommit.oid)
  git -C "$GIT_DIR_ROOT" worktree remove --force "$wt"; git -C "$GIT_DIR_ROOT" branch -q -D "$br" 2>/dev/null || true
  echo "$sha" >> "$RECORD_DIR/own-revisions"
  echo "$(date +%s) PR #$pr 병합 $sha ($req/$lim)" >> "$RECORD_DIR/s1-events"
  echo "PR #$pr 병합: $sha"
  # Argo CD는 3분마다 저장소를 보므로 바로 새로 고친다
  kubectl annotate application prod-core -n argocd argocd.argoproj.io/refresh=normal --overwrite >/dev/null
  for _ in $(seq 60); do
    [ "$(kubectl get application prod-core -n argocd -o jsonpath='{.status.sync.revision}')" = "$sha" ] && break; sleep 5
  done
  [ "$(kubectl get application prod-core -n argocd -o jsonpath='{.status.sync.revision}')" = "$sha" ] || { echo "Argo CD가 $sha로 동기화하지 않았다" >&2; return 1; }
  echo "$(date +%s) Argo CD 동기화 $sha" >> "$RECORD_DIR/s1-events"
}
# S1 공통 대기 함수. Deployment와 Argo Rollouts(단계 4) 어느 쪽이 파드를 관리해도 같게 동작하도록 파드의 메모리 한도로 판단한다.
# s1_pods_state <한도>: 그 한도를 가진 core 파드의 Ready 상태 목록("True False ...")
s1_pods_state() {
  kubectl get pods -n prod -l app.kubernetes.io/name=cosmos-core -o json | jq -r --arg m "$1" \
    '[.items[]|select(.metadata.deletionTimestamp==null)|select(.spec.containers[0].resources.limits.memory==$m)
      |(.status.conditions[]?|select(.type=="Ready")|.status)]|join(" ")'
}
# s1_wait_all <한도> <초>: 살아 있는 core 파드가 모두 그 한도이고 모두 Ready가 될 때까지 기다린다.
s1_wait_all() {
  local deadline=$(( $(date +%s) + $2 )) total ok
  while :; do
    read -r total ok <<<"$(kubectl get pods -n prod -l app.kubernetes.io/name=cosmos-core -o json | jq -r --arg m "$1" \
      '[.items[]|select(.metadata.deletionTimestamp==null)] as $p
       | "\($p|length) \([$p[]|select(.spec.containers[0].resources.limits.memory==$m)|select(any(.status.conditions[]?; .type=="Ready" and .status=="True"))]|length)"')"
    (( total > 0 && total == ok )) && return 0
    (( $(date +%s) >= deadline )) && { echo "core 파드 ${ok}/${total}개만 $1 준비" >&2; return 1; }
    sleep 5
  done
}
