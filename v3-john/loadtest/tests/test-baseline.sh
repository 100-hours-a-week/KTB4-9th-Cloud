#!/usr/bin/env bash
# baseline.js의 제출 결과 분류(성공, 업무 거절, 유실)와 요약 출력 형식을 가짜 API로 검사한다. k6와 python3가 필요하다.
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
W=$(mktemp -d); PORT=18089
python3 "$DIR/mock_api.py" $PORT & MOCK=$!
trap 'kill $MOCK 2>/dev/null; rm -rf "$W"' EXIT
echo '["t1","t2"]' > "$W/tokens.json"; echo '[1,2,3,4]' > "$W/problems.json"
sleep 1
k6 run -q -e BASE=http://127.0.0.1:$PORT/api -e TOKENS="$W/tokens.json" -e PROBLEMS="$W/problems.json" \
  -e VUS=2 -e DURATION=6s -e SUBMIT_RATIO=1 -e THINK=0.1 -e SUMMARY_OUT="$W/summary.json" \
  "$DIR/../baseline.js" > "$W/stdout.txt" 2> "$W/stderr.txt" || { tail -20 "$W/stderr.txt"; exit 1; }
python3 - "$W" <<'PY'
import json, sys
w = sys.argv[1]
s = json.load(open(f"{w}/summary.json"))
m = s["metrics"]
lost, rej = m.get("judge_lost", {}).get("count", 0), m.get("submit_rejected", {}).get("count", 0)
ok = m.get("judge_completed", {}).get("count", 0)
assert ok > 0, f"성공 제출이 집계되지 않음: {ok}"
assert rej > 0, f"400이 업무 거절로 집계되지 않음: {rej}"
assert lost > 0, f"500·미완료가 유실로 집계되지 않음: {lost}"
assert "p(95)" in m["submit_latency"] and "p(95)" in m["read_latency"], "요약 형식이 summary-export와 다름"
assert "value" in m["http_req_failed"], "rate 지표에 value 키가 없음"
out = open(f"{w}/stdout.txt").read()
assert "@@K6_SUMMARY@@" in out, "표준 출력에 요약 표식이 없음(클러스터 실행에서 로그로 회수 불가)"
warns = open(f"{w}/stderr.txt").read().count("submit 4xx")
assert 1 <= warns <= 5, f"4xx 본문 경고는 1~5건이어야 함: {warns}"
print(f"PASS completed={ok} rejected={rej} lost={lost} warn4xx={warns}")
PY
