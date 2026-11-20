#!/usr/bin/env bash
# 가짜 Gemini(WireMock) 응답을 ai-llm과 같은 SDK 버전(langchain-google-genai 4.4.0, google-genai 2.23.0)으로 받아
# 풀이 평가 응답 형식(Evaluation)으로 해석되는지 검사한다. docker가 필요하다.
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
MANIFEST="$DIR/../../gitops/environments/prod/platform/fake-gemini.yaml"
W=$(mktemp -d); NET=fake-gemini-test-$$
cleanup() { docker rm -f "$NET-wm" >/dev/null 2>&1 || true; docker network rm "$NET" >/dev/null 2>&1 || true; rm -rf "$W"; }
trap cleanup EXIT
mkdir -p "$W/mappings"
python3 - "$MANIFEST" "$W" <<'PY'
import sys, yaml, os
m, w = sys.argv[1:3]
docs = [d for d in yaml.safe_load_all(open(m)) if d]
cm = next(d for d in docs if d["kind"] == "ConfigMap")
for k, v in cm["data"].items():
    open(os.path.join(w, "mappings", k), "w").write(v)
dep = next(d for d in docs if d["kind"] == "Deployment")
print(dep["spec"]["template"]["spec"]["containers"][0]["image"], file=open(os.path.join(w, "image"), "w"))
PY
docker network create "$NET" >/dev/null
docker run -d --name "$NET-wm" --network "$NET" -v "$W/mappings:/home/wiremock/mappings:ro" "$(cat "$W/image")" --port 8080 >/dev/null
for _ in $(seq 30); do docker run --rm --network "$NET" curlimages/curl:8.11.1 -sf "http://$NET-wm:8080/__admin/health" >/dev/null 2>&1 && break; sleep 1; done
cat > "$W/client.py" <<'PY'
import asyncio, time
from pydantic import BaseModel, Field
from langchain_google_genai import ChatGoogleGenerativeAI

class KeywordVerdict(BaseModel):
    keyword: str
    is_included: bool

class Evaluation(BaseModel):  # KTB4-9th-AI src/problem/evaluation.py와 같은 형식
    approach_score: int = Field(ge=0, le=40)
    category_score: int = Field(ge=0, le=20)
    order_score: int = Field(ge=0, le=10)
    feedback: str
    keywords: list[KeywordVerdict]

async def main():
    llm = ChatGoogleGenerativeAI(model="gemini-3.5-flash-lite", google_api_key="fake-gemini-key")
    t = time.time()
    r = await llm.with_structured_output(Evaluation).ainvoke([("system", "rules"), ("human", "solution")])
    dt = (time.time() - t) * 1000
    assert isinstance(r, Evaluation), type(r)
    assert 700 <= dt <= 3000, f"지연이 800~1500ms 범위를 크게 벗어남: {dt:.0f}ms"
    print(f"PASS Evaluation 해석 성공 approach={r.approach_score} latency={dt:.0f}ms")

asyncio.run(main())
PY
docker run --rm --network "$NET" -e GOOGLE_GEMINI_BASE_URL="http://$NET-wm:8080" -v "$W/client.py:/client.py:ro" python:3.13-slim \
  sh -c 'pip install -q --disable-pip-version-check --root-user-action=ignore langchain-google-genai==4.4.0 google-genai==2.23.0 >/dev/null 2>&1 && python /client.py'
# WireMock이 받은 요청이 1건이고, 실제 키가 아닌 가짜 키였는지 본다
docker run --rm --network "$NET" curlimages/curl:8.11.1 -s "http://$NET-wm:8080/__admin/requests" | python3 -c '
import json,sys; r=json.load(sys.stdin)["requests"]
assert len(r)==1, f"요청 수 {len(r)}"
u=r[0]["request"]["url"]; assert ":generateContent" in u, u
assert r[0]["wasMatched"], "스텁과 맞지 않음"
print("PASS WireMock 요청 1건", u)'
