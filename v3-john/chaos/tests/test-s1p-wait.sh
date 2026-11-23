#!/usr/bin/env bash
# s1p_wait_core_healthy 테스트: 가짜 kubectl로 generation 조건을 확인한다. 실행: bash v3-john/chaos/tests/test-s1p-wait.sh
set -uo pipefail
DIR=$(cd "$(dirname "$0")" && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir "$T/bin"
cat > "$T/bin/kubectl" <<'K'
#!/usr/bin/env bash
case "$*" in
  *metadata.generation*) echo "$FAKE_GEN";; *observedGeneration*) echo "$FAKE_OBS";; *status.phase*) echo "$FAKE_PHASE";;
esac
K
chmod +x "$T/bin/kubectl"
source "$DIR/../scenarios/s1p/lib.sh"
PATH="$T/bin:$PATH"; fail=0
check() { # 이름 기대(0/1) gen obs phase before
  FAKE_GEN=$3 FAKE_OBS=$4 FAKE_PHASE=$5 s1p_wait_core_healthy 1 "${6:-}" >/dev/null 2>&1; local rc=$?
  [ "$rc" = "$2" ] && echo "ok   $1" || { echo "FAIL $1 (rc=$rc)"; fail=1; }
}
check "generation 증가 + 관측 + Healthy" 0 5 5 Healthy 4
check "generation이 병합 전과 같으면 거부" 1 4 4 Healthy 4
check "관측 전이면 거부" 1 5 4 Healthy 4
check "Progressing이면 거부" 1 5 5 Progressing 4
check "병합 전 값 없으면 generation 조건 생략" 0 4 4 Healthy ""
exit $fail
