# 기준선 3회 결과를 k6 요약과 Prometheus(Envoy 기준)에서 모아 표로 출력한다.
import json, sys, urllib.parse, urllib.request
D = sys.argv[1]
PROM = "http://127.0.0.1:19090/api/v1/query"
runs = {}
for line in open(f"{D}/runs.log"):
    p = line.split()
    runs.setdefault(p[0], {})[p[1]] = int(p[2])

def q(expr, t):
    url = PROM + "?" + urllib.parse.urlencode({"query": expr, "time": t})
    return json.load(urllib.request.urlopen(url))["data"]["result"]

def one(expr, t, key=None):
    r = q(expr, t)
    if key:
        return {x["metric"].get(key, "-"): float(x["value"][1]) for x in r}
    return float(r[0]["value"][1]) if r else None

rows = []
for name in sorted(runs):
    s, e = runs[name]["start"], runs[name]["end"]
    w = f"{e - s}s"
    k6 = json.load(open(f"{D}/{name}.json"))["metrics"]
    # 라우트 → 묶음 라벨을 붙여 합산
    tot = one(f'sum by (journey) (label_replace(increase(envoy_cluster_upstream_rq_total{{envoy_cluster_name=~"httproute/prod/journey-.+"}}[{w}]), "journey", "$1", "envoy_cluster_name", "httproute/prod/journey-([a-z]+).*"))', e, "journey")
    err = one(f'sum by (journey) (label_replace(increase(envoy_cluster_upstream_rq_xx{{envoy_cluster_name=~"httproute/prod/journey-.+", envoy_response_code_class="5"}}[{w}]), "journey", "$1", "envoy_cluster_name", "httproute/prod/journey-([a-z]+).*"))', e, "journey")
    rp95 = one(f'histogram_quantile(0.95, sum by (le) (increase(envoy_cluster_upstream_rq_time_bucket{{envoy_cluster_name=~"httproute/prod/journey-core-(auth|problem)/.+"}}[{w}])))', e)
    sp95 = one(f'histogram_quantile(0.95, sum by (le) (increase(envoy_cluster_upstream_rq_time_bucket{{envoy_cluster_name=~"httproute/prod/journey-core-submit/.+"}}[{w}])))', e)
    rows.append({
        "run": name, "window": f"{runs[name].get('start')}~{e}",
        "core_req": tot.get("core", 0), "core_5xx": err.get("core", 0),
        "major_req": tot.get("major", 0), "major_5xx": err.get("major", 0),
        "read_p95_envoy_ms": rp95, "submit_p95_envoy_ms": sp95,
        "read_p95_k6_ms": k6["read_latency"]["p(95)"], "read_p99_k6_ms": k6["read_latency"]["p(99)"],
        "submit_p95_k6_ms": k6["submit_latency"]["p(95)"], "submit_max_k6_ms": k6["submit_latency"]["max"],
        # 2026-11-20부터 judge_lost(유실)와 submit_rejected(4xx 업무 거절)로 나눠 센다. 이전 결과는 judge_incomplete.
        "judge_lost": k6.get("judge_lost", k6.get("judge_incomplete", {})).get("count", 0),
        "submit_rejected": k6.get("submit_rejected", {}).get("count", 0),
        "http_failed": k6["http_req_failed"]["value"], "iterations": k6["iterations"]["count"],
    })
print(json.dumps(rows, indent=1, ensure_ascii=False))
