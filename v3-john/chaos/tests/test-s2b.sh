#!/usr/bin/env bash
# S2' B 공통 함수 테스트(가짜 kubectl). 실행: bash v3-john/chaos/tests/test-s2b.sh
set -uo pipefail
DIR=$(cd "$(dirname "$0")" && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; fail=0
ok() { echo "ok   $1"; }; no() { echo "FAIL $1"; fail=1; }
mkdir "$T/bin"
cat > "$T/bin/kubectl" <<'K'
#!/usr/bin/env bash
case "$*" in
  *"get nodes -l workload-class=stateful"*) printf '%b' "$FAKE_NODES";;
  *"get pod "*) p=$(echo "$*" | awk '{print $3}'); case ",$FAKE_NOTREADY," in *",$p,"*) echo False;; *) echo True;; esac;;
esac
K
chmod +x "$T/bin/kubectl"; export PATH="$T/bin:$PATH"
source "$DIR/../scenarios/s2b/lib.sh"
FAKE_NODES='n1 ap-northeast-2c True \n' ; export FAKE_NODES
[ "$(s2b_wrong_zone_node ap-northeast-2a)" = n1 ] && ok "볼륨 존(2a)과 다른 Ready 노드를 찾는다" || no "다른 존 노드"
FAKE_NODES='n1 ap-northeast-2a True \n'
[ -z "$(s2b_wrong_zone_node ap-northeast-2a)" ] && ok "같은 존이면 없음" || no "같은 존"
FAKE_NODES='n1 ap-northeast-2c False \n'
[ -z "$(s2b_wrong_zone_node ap-northeast-2a)" ] && ok "NotReady 노드는 제외" || no "NotReady"
FAKE_NOTREADY="" s2b_pods_ready && ok "네 파드 Ready" || no "Ready"
FAKE_NOTREADY="rabbitmq-0" s2b_pods_ready && no "하나라도 아니면 실패해야 함" || ok "하나라도 NotReady면 실패"
grep -q 'resourceType: "aws:ec2:spot-instance"' "$DIR/../scenarios/s2/lib.sh" && ok "FIS 템플릿 재사용" || no "템플릿"
grep -q '"stateful-ng"' "$DIR/../../environments/eks/fis.tf" && ok "FIS 역할이 stateful-ng 허용" || no "fis.tf"
exit $fail
