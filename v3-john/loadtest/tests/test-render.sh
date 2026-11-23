#!/usr/bin/env bash
# run-k6.sh가 그리는 Job YAML을 가짜 kubectl로 가로채 검사한다. K6_AVOID_NODE 유무에 따라 nodeAffinity가 붙고 빠지는지 본다.
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd); fail=0
ok() { echo "PASS $1"; }; no() { echo "FAIL $1"; fail=1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; mkdir "$T/bin"
cat > "$T/bin/kubectl" <<'S'
#!/usr/bin/env bash
case "$1 $2" in
  "get secret") [[ "$*" == *expires_at* ]] && echo 99999999999 | base64 || true ;;
  "get svc") echo envoy-prod-abc ;;
  "apply -f") cat > "$RENDERED" ;;
  "get job") echo "Complete " ;;
  "create configmap") echo "kind: ConfigMap" ;;
esac
exit 0
S
chmod +x "$T/bin/kubectl"
run() { PATH="$T/bin:$PATH" RENDERED="$T/out.yaml" OUT="$T" "$DIR/k8s/run-k6.sh" t1 1m 2 >/dev/null 2>&1; }
valid() { python3 - "$1" <<'PY' 2>/dev/null
import sys
try:
    import yaml
except ImportError:
    sys.exit(0)
d = yaml.safe_load(open(sys.argv[1]))
sys.exit(0 if d["kind"] == "Job" else 1)
PY
}

unset K6_AVOID_NODE; run
! grep -q '^ *affinity:\|__AFFINITY__' "$T/out.yaml" && grep -q 'nodeSelector: { workload-class: application }' "$T/out.yaml" && valid "$T/out.yaml" \
  && ok "미지정이면 affinity 없음, YAML 유효" || no "미지정 렌더"
K6_AVOID_NODE=ip-10-0-1-5.ap-northeast-2.compute.internal run
grep -q 'key: kubernetes.io/hostname, operator: NotIn, values: \[ "ip-10-0-1-5.ap-northeast-2.compute.internal" \]' "$T/out.yaml" \
  && grep -q 'requiredDuringSchedulingIgnoredDuringExecution' "$T/out.yaml" && ! grep -q '__AFFINITY__' "$T/out.yaml" && valid "$T/out.yaml" \
  && ok "지정하면 NotIn affinity, YAML 유효" || no "지정 렌더 $(grep -n "affinity:" "$T/out.yaml")"
if python3 -c 'import yaml' 2>/dev/null; then python3 - "$T/out.yaml" <<'PY' && ok "affinity 위치가 spec.template.spec" || no "affinity 위치"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
s = d["spec"]["template"]["spec"]
assert s["affinity"]["nodeAffinity"]["requiredDuringSchedulingIgnoredDuringExecution"]["nodeSelectorTerms"][0]["matchExpressions"][0]["operator"] == "NotIn"
assert s["nodeSelector"] == {"workload-class": "application"}
PY
else echo "SKIP PyYAML이 없어 구조 검사를 건너뜀"; fi
K6_AVOID_NODE='x; rm -rf' run; rc=$?
[ $rc -ne 0 ] && ok "잘못된 노드 이름 거부" || no "잘못된 이름 허용"
exit $fail
