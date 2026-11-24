#!/usr/bin/env bash
# S1' 단계 2 제출 경로 격벽 검사(오프라인). 실행: bash v3-john/gitops/environments/prod/platform/tests/test-submit-bulkhead.sh
set -uo pipefail
F="$(cd "$(dirname "$0")/.." && pwd)/gateway.yaml"; fail=0
python3 - "$F" <<'PY' || fail=1
import sys, yaml
docs=[d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
p=[d for d in docs if d.get("kind")=="BackendTrafficPolicy" and d["metadata"]["name"]=="submit-bulkhead"]
def chk(c,m):
    print(("ok   " if c else "FAIL ")+m); return c
ok=chk(len(p)==1,"submit-bulkhead 정책이 하나 있다")
if ok:
    s=p[0]["spec"]; t=[r["name"] for r in s.get("targetRefs",[])]
    ok&=chk(t==["journey-core-submit"],f"대상은 제출 경로 하나뿐이다({t})")
    cb=s.get("circuitBreaker",{})
    ok&=chk(cb.get("maxParallelRequests")==8,f"Envoy 한 대당 동시 요청 상한 8({cb.get('maxParallelRequests')})")
    ok&=chk("retry" not in s,"격벽 정책에 재시도를 섞지 않는다")
# 다른 정책이 제출 경로를 대상으로 하지 않는다(정책 겹침 방지)
others=[d["metadata"]["name"] for d in docs if d.get("kind")=="BackendTrafficPolicy" and d["metadata"]["name"]!="submit-bulkhead"
        and any(r.get("name")=="journey-core-submit" for r in d["spec"].get("targetRefs",[]))]
ok&=chk(not others,f"다른 BackendTrafficPolicy가 제출 경로를 대상으로 하지 않는다({others})")
sys.exit(0 if ok else 1)
PY
exit $fail
