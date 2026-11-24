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
  trap 'rm -f "$CRD"' EXIT
  helm show crds oci://docker.io/envoyproxy/gateway-helm --version "$VER" >"$CRD" 2>/dev/null \
    || { echo "FAIL CRD 내려받기(helm show crds) 실패"; exit 1; }
fi
python3 -I - "$GW" "$CRD" <<'PY'
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

# 재시도 정책만 검사한다. 같은 파일의 다른 BackendTrafficPolicy(S1' 단계 2 제출 경로 격벽 submit-bulkhead)는 제외한다.
docs = [d for d in yaml.safe_load_all(open(gw)) if d and d.get("kind") == "BackendTrafficPolicy" and d["metadata"]["name"] == "retry-read-routes"]
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
    # 요청이 업스트림 앱에 닿기 전에 실패한 경우만 재시도한다(POST 중복 방지). 정확히 이 집합이어야 한다.
    chk(sorted(on.get("triggers", [])) == ["connect-failure", "refused-stream", "reset-before-request"], "triggers connect-failure, refused-stream, reset-before-request", f"triggers {on.get('triggers')}")
    chk("reset" not in on.get("triggers", []), "reset 트리거 없음(처리 중 끊김은 재시도하지 않는다)", "reset 트리거가 있다")
    chk("httpStatusCodes" not in on and not ({"5xx", "gateway-error", "retriable-status-codes"} & set(on.get("triggers", []))), "503 등 상태 코드 재시도 없음", f"상태 코드 재시도가 있다: {on}")
    # 재시도별 제한 시간은 첫 시도에도 적용된다. 시간 초과는 재시도 트리거가 아니라 504로 끝나 느린 쓰기 요청을 끊으므로 두지 않는다.
    pr = r.get("perRetry", {})
    chk("timeout" not in pr, "perRetry timeout 없음", f"perRetry timeout이 있다: {pr.get('timeout')}")
    chk(pr.get("backOff") == {"baseInterval": "100ms", "maxInterval": "1s"}, "backOff 100ms/1s", f"backOff {pr.get('backOff')}")

chk(set(targets) == WANT and len(targets) == len(WANT), f"대상 목록이 정확히 {sorted(WANT)}", f"대상 목록 {sorted(targets)}")
bad = FORBID & set(targets)
chk(not bad, "대상에 journey-core-submit, journey-ai 없음", f"금지 대상 포함: {sorted(bad)}")
missing = set(targets) - routes
chk(not missing, "모든 대상 HTTPRoute가 같은 파일에 존재", f"없는 HTTPRoute: {sorted(missing)}")
sys.exit(fail)
PY
