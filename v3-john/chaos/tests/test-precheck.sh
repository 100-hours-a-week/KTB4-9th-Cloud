#!/usr/bin/env bash
# 실행기 사전 검사 precheck_nodes를 가짜 kubectl로 확인한다.
set -uo pipefail
D=$(cd "$(dirname "$0")/.." && pwd); fail=0
ok() { echo "PASS $1"; }; no() { echo "FAIL $1"; fail=1; }
source "$D/lib/precheck.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; mkdir "$T/bin"
cat > "$T/bin/kubectl" <<'S'
#!/usr/bin/env bash
echo "$*" > "$ARGS"
[ -n "${FAKE_FAIL:-}" ] && exit 1
case "$*" in *"workload-class=application"*"unschedulable==true"*) printf '%s' "${FAKE_CORDONED:-}";; esac
S
chmod +x "$T/bin/kubectl"; export ARGS="$T/args" PATH="$T/bin:$PATH"

export FAKE_CORDONED="ip-10-0-1-5 "; out=$(precheck_nodes); rc=$?
[ $rc -ne 0 ] && [[ "$out" == *"cordon된 application 노드가 있다: ip-10-0-1-5."* ]] && ok "cordon된 노드가 있으면 1과 이유" || no "cordon rc=$rc out=$out"
grep -q 'workload-class=application' "$ARGS" && grep -q 'unschedulable==true' "$ARGS" && ok "application 노드의 unschedulable만 묻는다" || no "질의 $(cat "$ARGS")"
export FAKE_CORDONED=""; out=$(precheck_nodes); rc=$?
[ $rc -eq 0 ] && [ -z "$out" ] && ok "cordon이 없으면 통과" || no "통과 rc=$rc out=$out"
export FAKE_FAIL=1; out=$(precheck_nodes); rc=$?
[ $rc -ne 0 ] && [[ "$out" == *"확인할 수 없다"* ]] && ok "조회 실패도 1" || no "조회 실패 rc=$rc"
grep -q 'precheck_nodes' "$D/run-experiment.sh" && grep -q 'lib/precheck.sh' "$D/run-experiment.sh" && ok "실행기가 함수를 부른다" || no "실행기 연결"
exit $fail
