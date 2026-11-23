#!/usr/bin/env bash
# S2' 단계 2: gateway.yaml의 BackendTrafficPolicy를 서버 없이 검증한다.
# (a) Envoy Gateway 1.9.3 CRD의 openAPIV3Schema로 스키마 검증(알 수 없는 필드는 오탈자로 보고 거부한다).
# (b) 정책 대상 목록이 조회 경로 4개뿐이고 제출과 AI 경로는 없는지 확인한다.
# 필요: helm(네트워크로 CRD를 받는다), python3 + PyYAML + jsonschema. 없으면 SKIP이 아니라 FAIL로 끝낸다.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
GW=${GW:-$HERE/../gateway.yaml}
VER=${EG_VERSION:-1.9.3}
CRD=${CRD_FILE:-}
if [ -z "$CRD" ]; then
  CRD=$(mktemp -t eg-crds.XXXXXX)
  helm show crds oci://docker.io/envoyproxy/gateway-helm --version "$VER" >"$CRD" 2>/dev/null \
    || { echo "FAIL CRD 내려받기(helm show crds) 실패"; exit 1; }
fi
exec python3 -I - "$GW" "$CRD" <<'PY'
import sys
try:
    import yaml, jsonschema
except ImportError as e:
    print("FAIL 필요한 파이썬 모듈 없음:", e); sys.exit(1)

gw, crd = sys.argv[1], sys.argv[2]
fail = 0
def ok(m): print("PASS", m)
def chk(c, m, bad=None):
    ok(m) if c else no(bad or m)
def no(m):
    global fail; fail = 1; print("FAIL", m)

def strict(s):
    """구조적 스키마는 모르는 필드를 잘라 내므로 서버가 조용히 무시한다. 오탈자를 잡으려고 거부로 바꾼다."""
    if isinstance(s, dict):
        s = {k: strict(v) for k, v in s.items()}
        if s.get("type") == "object" and "properties" in s and not s.get("x-kubernetes-preserve-unknown-fields"):
            s["additionalProperties"] = False
        return s
    if isinstance(s, list):
        return [strict(i) for i in s]
    return s

schema = None
for d in yaml.safe_load_all(open(crd)):
    if d and d.get("spec", {}).get("names", {}).get("kind") == "BackendTrafficPolicy":
        schema = strict(d["spec"]["versions"][0]["schema"]["openAPIV3Schema"])
if schema is None:
    print("FAIL CRD에 BackendTrafficPolicy 없음"); sys.exit(1)

docs = [d for d in yaml.safe_load_all(open(gw)) if d and d.get("kind") == "BackendTrafficPolicy"]
if not docs:
    no("gateway.yaml에 BackendTrafficPolicy가 없다"); sys.exit(1)
ok(f"BackendTrafficPolicy {len(docs)}개 발견")

WANT = {"journey-core-auth", "journey-core-problem", "journey-major-battle", "journey-major-core"}
FORBID = {"journey-core-submit", "journey-ai"}
routes = {d["metadata"]["name"] for d in yaml.safe_load_all(open(gw)) if d and d.get("kind") == "HTTPRoute"}
targets = []
for p in docs:
    errs = list(jsonschema.Draft7Validator(schema).iter_errors(p))
    if errs:
        for e in errs: no(f"스키마 위반 {list(e.absolute_path)}: {e.message[:120]}")
    else:
        ok(f"{p['metadata']['name']}: CRD 스키마 통과")
    for t in p["spec"].get("targetRefs", []):
        if t.get("group") != "gateway.networking.k8s.io" or t.get("kind") != "HTTPRoute":
            no(f"대상이 HTTPRoute가 아니다: {t}")
        targets.append(t["name"])
    if p["metadata"].get("namespace") != "prod": no("정책 namespace가 prod가 아니다")
    r = p["spec"].get("retry", {})
    on = r.get("retryOn", {})
    chk(r.get("numRetries") == 2, "numRetries 2", f"numRetries {r.get('numRetries')}")
    chk(sorted(on.get("triggers", [])) == ["connect-failure", "reset"], "triggers connect-failure, reset", f"triggers {on.get('triggers')}")
    chk(on.get("httpStatusCodes") == [503], "httpStatusCodes [503]", f"httpStatusCodes {on.get('httpStatusCodes')}")
    chk(r.get("perRetry", {}).get("timeout") == "2s", "perRetry timeout 2s", "perRetry timeout")

chk(set(targets) == WANT and len(targets) == len(WANT), f"대상 목록이 정확히 {sorted(WANT)}", f"대상 목록 {sorted(targets)}")
bad = FORBID & set(targets)
chk(not bad, "대상에 journey-core-submit, journey-ai 없음", f"금지 대상 포함: {sorted(bad)}")
missing = set(targets) - routes
chk(not missing, "모든 대상 HTTPRoute가 같은 파일에 존재", f"없는 HTTPRoute: {sorted(missing)}")
sys.exit(fail)
PY
