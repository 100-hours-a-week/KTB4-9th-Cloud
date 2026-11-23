# 실험 한 번의 기계 측정 지표(설계서 8.3)를 Prometheus에서 모아 JSON으로 낸다.
#   python3 aggregate.py --prom URL --start <unix> --inject <unix> --stop <unix> --end <unix> \
#       --testid ID --rev-before FILE --rev-after FILE [--aborted REASON] > record.json
# 판정 구간은 주입 시작부터 회복 구간 끝까지다(설계서 6.4). 사람이 채울 값(선언 시간, 원인 파악 시간과 근거)은 비워 둔다.
import argparse, json, math, sys, urllib.parse, urllib.request

CORE_SLO, MAJOR_SLO, AI_SLO = 0.995, 0.99, 0.95
PERIOD_MIN = 40320  # 4주
SYMPTOM_ALERTS = ("CoreUnavailable", "CoreErrorBudgetBurnFast", "MajorUnavailable", "ReadLatencyHigh",
                  "JudgeTurnaroundHigh", "JudgeJobLost", "AiErrorRateHigh")
# 2차: 서비스 전체 탐지 알림(Task 2 규칙)
ALL_ALERTS = ("CoreBurnFastAll", "ServiceErrorHigh")
BLAST_THRESHOLD = 0.05
STEP = 15
HOLD = 60

def _finite(v):
    return v is not None and not math.isnan(v)

def recovery_seconds(samples, inject_t, target, hold=HOLD):
    """주입 시작부터 지표가 목표 안으로 돌아와 hold초 유지된 시점까지(설계서 6.4).
    목표를 한 번도 벗어나지 않았으면 0, 끝까지 회복하지 못했으면 None. NaN(요청 없음)은 회복으로 보지 않는다."""
    pts = sorted((t, v) for t, v in samples if t >= inject_t)
    breached = False
    cand = None
    for t, v in pts:
        if not _finite(v):
            cand = None
            continue
        if v > target:
            breached, cand = True, None
            continue
        if breached:
            if cand is None:
                cand = t
            if t - cand >= hold:
                return int(cand - inject_t)
    return 0 if not breached else None

def slo_hold_ratio(samples, start_t, end_t, target=0.005):
    """구간 안 표본 중 값이 목표 이하인 비율. NaN(요청 없음)은 분모에서 뺀다. 표본이 없으면 None."""
    vals = [v for t, v in samples if start_t <= t <= end_t and _finite(v)]
    return None if not vals else sum(1 for v in vals if v <= target) / len(vals)

def blast_radius(route_ratios, start_t, end_t, threshold=BLAST_THRESHOLD):
    """구간 안에서 오류율이 한 번이라도 threshold를 넘은 route 이름 목록(정렬)."""
    return sorted(r for r, pts in route_ratios.items()
                  if any(start_t <= t <= end_t and _finite(v) and v > threshold for t, v in pts))

def first_alert(alerts, inject_t, names, step=STEP):
    """주입 뒤 처음 firing으로 바뀐 증상 알림 (이름, 초).
    alerts: 이름 → 시계열(라벨 조합)별 firing 시각 목록. 시계열마다 '직전 간격에는 firing이 아니었던' 시각을 찾는다.
    주입 전부터 이어지던 firing은 이 실험의 탐지로 보지 않고, 다른 시계열(앞 회차 testid 등)이 firing이어도 가리지 않는다."""
    best = None
    for name, series_list in alerts.items():
        if name not in names:
            continue
        for ts in series_list:
            on = set(int(t) for t in ts)
            for t in sorted(on):
                if t > inject_t and (t - step) not in on:
                    if best is None or t < best[1]:
                        best = (name, t)
                    break
    return None if best is None else (best[0], int(best[1] - inject_t))

def budget_percent(fail_ratio, minutes, slo, period_min=PERIOD_MIN):
    """설계서 6.2: (실패 비율 × 지속 시간) ÷ 4주 허용 실패 시간, 백분율."""
    allowed = period_min * (1 - slo)
    return round(fail_ratio * minutes / allowed * 100, 2)

def verdict(core_requests, rev_before, rev_after, aborted, own=()):
    """판정 불가 사유 목록. 비어 있으면 판정 가능.
    own: 시나리오가 스스로 병합한 리비전(S1 주입·원복). 이 리비전으로 바뀐 앱은 외부 배포로 보지 않는다."""
    reasons = []
    if aborted:
        reasons.append(f"중단: {aborted}")
    if core_requests < 1000:
        reasons.append(f"핵심 요청 {int(core_requests)}건(1,000건 미만)")
    own = set(own)
    changed = sorted(k for k in set(rev_before) | set(rev_after)
                     if rev_before.get(k) != rev_after.get(k) and rev_after.get(k) not in own)
    if changed:
        reasons.append("실험 중 배포 변경: " + ", ".join(changed))
    return reasons

COUNT_KEYS = {"judge_lost", "judge_completed", "submit_rejected", "requests", "errors_5xx"}

def clean(obj, key=None):
    """JSON에 NaN을 넣지 않고(None), 건수는 increase() 외삽 소수점을 반올림한다."""
    if isinstance(obj, dict):
        return {k: clean(v, k) for k, v in obj.items()}
    if isinstance(obj, list):
        return [clean(v) for v in obj]
    if isinstance(obj, float):
        if math.isnan(obj):
            return None
        if key in COUNT_KEYS:
            return round(obj)
    return obj

# ---- Prometheus 질의 ----
def _get(prom, path, params):
    url = f"{prom}{path}?{urllib.parse.urlencode(params)}"
    with urllib.request.urlopen(url, timeout=30) as r:
        body = json.load(r)
    if body.get("status") != "success":
        raise RuntimeError(f"Prometheus 오류: {body}")
    return body["data"]["result"]

def instant(prom, expr, t, key=None):
    res = _get(prom, "/api/v1/query", {"query": expr, "time": t})
    if key:
        return {x["metric"].get(key, "-"): float(x["value"][1]) for x in res}
    return float(res[0]["value"][1]) if res else None

def rng(prom, expr, start, end, step=STEP):
    res = _get(prom, "/api/v1/query_range", {"query": expr, "start": start, "end": end, "step": step})
    return {json.dumps(x["metric"], sort_keys=True): [(float(t), float(v)) for t, v in x["values"]] for x in res}

J = 'envoy_cluster_name=~"httproute/prod/journey-.+"'
LBL = '"journey", "$1", "envoy_cluster_name", "httproute/prod/journey-([a-z]+).*"'

def journey_window(prom, end, window):
    tot = instant(prom, f'sum by (journey) (label_replace(increase(envoy_cluster_upstream_rq_total{{{J}}}[{window}s]) or increase(envoy_cluster_upstream_cx_none_healthy{{{J}}}[{window}s]), {LBL}))', end, "journey")
    err = instant(prom, f'sum by (journey) (label_replace(increase(envoy_cluster_upstream_rq_xx{{{J}, envoy_response_code_class="5"}}[{window}s]) or increase(envoy_cluster_upstream_cx_none_healthy{{{J}}}[{window}s]), {LBL}))', end, "journey")
    p95 = instant(prom, f'histogram_quantile(0.95, sum by (journey, le) (label_replace(increase(envoy_cluster_upstream_rq_time_bucket{{{J}}}[{window}s]), {LBL})))', end, "journey")
    read = instant(prom, f'histogram_quantile(0.95, sum by (le) (increase(envoy_cluster_upstream_rq_time_bucket{{envoy_cluster_name=~"httproute/prod/journey-core-(auth|problem)/.+"}}[{window}s])))', end)
    out = {}
    for j in sorted(set(tot) | set(err)):
        t, e = tot.get(j, 0.0), err.get(j, 0.0)
        out[j] = {"requests": round(t), "errors_5xx": round(e), "failure_ratio": (e / t) if t else None,
                  "p95_ms": p95.get(j)}
    return out, read

def core_ratio_1m(prom, start, end):
    """복구 시간 판정용 핵심 오류율(1분 창). 5분 기록 규칙은 회복을 5분 늦게 보여 주므로 쓰지 않는다."""
    c = 'envoy_cluster_name=~"httproute/prod/journey-core-.+"'
    none = f"sum(rate(envoy_cluster_upstream_cx_none_healthy{{{c}}}[1m])) or vector(0)"
    expr = (f'(sum(rate(envoy_cluster_upstream_rq_xx{{{c}, envoy_response_code_class="5"}}[1m])) or vector(0)) + ({none})'
            f' ) / ( (sum(rate(envoy_cluster_upstream_rq_total{{{c}}}[1m])) or vector(0)) + ({none})')
    r = rng(prom, "(" + expr + ")", start, end)
    return next(iter(r.values()), [])

def route_ratios_1m(prom, start, end):
    """route별 1분 창 오류율. 5xx, 업스트림 타임아웃, 연결 실패, 정상 호스트 없음을 오류로 센다(Task 2 규칙과 같은 구성)."""
    r = 'envoy_cluster_name=~"httproute/prod/[^/]+/rule/.*"'
    lbl = '"route", "$1", "envoy_cluster_name", "httproute/prod/([^/]+)/rule/.*"'
    def part(metric, k, extra=""):
        # 같은 route의 여러 지표가 or 로 겹쳐 사라지지 않도록 k 라벨로 구분해 둔다
        return f'sum by (route, k) (label_replace(label_replace(rate({metric}{{{r}{extra}}}[1m]), {lbl}), "k", "{k}", "", ""))'
    none = part("envoy_cluster_upstream_cx_none_healthy", "n")
    err = " or ".join((part("envoy_cluster_upstream_rq_xx", "5", ', envoy_response_code_class="5"'),
                       part("envoy_cluster_upstream_rq_timeout", "t"),
                       part("envoy_cluster_upstream_cx_connect_fail", "c"), none))
    tot = " or ".join((part("envoy_cluster_upstream_rq_total", "r"), none))
    err_sum, tot_sum = f"sum by (route) ({err})", f"sum by (route) ({tot})"
    res = rng(prom, f"({err_sum}) / ({tot_sum})", start, end)
    return {json.loads(k).get("route", "-"): v for k, v in res.items()}

def alert_firing_times(prom, start, end):
    names = "|".join(SYMPTOM_ALERTS + ALL_ALERTS)
    r = rng(prom, f'ALERTS{{alertstate="firing", alertname=~"{names}"}}', start - 300, end)
    out = {}
    for k, pts in r.items():
        out.setdefault(json.loads(k)["alertname"], []).append([t for t, v in pts if v >= 1])
    return out

def k6_window(prom, testid, end, window):
    q = lambda e: instant(prom, e, end)
    return {
        "submit_p95_s": q(f'max_over_time(k6_submit_latency_p95{{testid="{testid}"}}[{window}s])'),
        "judge_lost": q(f'sum(increase(k6_judge_lost_total{{testid="{testid}"}}[{window}s]))') or 0,
        "judge_completed": q(f'sum(increase(k6_judge_completed_total{{testid="{testid}"}}[{window}s]))') or 0,
        "submit_rejected": q(f'sum(increase(k6_submit_rejected_total{{testid="{testid}"}}[{window}s]))') or 0,
    }

def main():
    ap = argparse.ArgumentParser()
    for a in ("prom", "testid", "rev_before", "rev_after", "aborted", "scenario", "step", "own_revisions"):
        ap.add_argument(f"--{a.replace('_', '-')}")
    for a in ("start", "inject", "stop", "end"):
        ap.add_argument(f"--{a}", type=int, required=True)
    ap.add_argument("--mitigated", type=int)
    a = ap.parse_args()
    window = a.end - a.inject
    journeys, read_p95 = journey_window(a.prom, a.end, window)
    rec_series = core_ratio_1m(a.prom, a.inject, a.end)
    alerts = alert_firing_times(a.prom, a.inject, a.end)
    det = first_alert(alerts, a.inject, SYMPTOM_ALERTS)
    det_all = first_alert(alerts, a.inject, ALL_ALERTS)
    routes = route_ratios_1m(a.prom, a.inject, a.end)
    k6 = k6_window(a.prom, a.testid, a.end, window) if a.testid else {}
    core = journeys.get("core", {"requests": 0, "failure_ratio": None})
    fr = core.get("failure_ratio") or 0.0
    lost, done = k6.get("judge_lost", 0), k6.get("judge_completed", 0)
    rb = json.load(open(a.rev_before)) if a.rev_before else {}
    ra = json.load(open(a.rev_after)) if a.rev_after else {}
    own = open(a.own_revisions).read().split() if a.own_revisions else []
    rec = {
        "scenario": a.scenario, "step": a.step, "testid": a.testid,
        "times": {"k6_start": a.start, "inject": a.inject, "stop": a.stop, "end": a.end},
        "detection": {"alert": det[0], "seconds": det[1]} if det else None,
        "recovery_seconds_core": recovery_seconds(rec_series, a.inject, 1 - CORE_SLO),
        "detection_all": {"alert": det_all[0], "seconds": det_all[1]} if det_all else None,
        "core_slo_hold": slo_hold_ratio(rec_series, a.inject, a.end, 1 - CORE_SLO),
        "blast_radius": blast_radius(routes, a.inject, a.end),
        "journeys": journeys,
        "read_p95_ms": read_p95,
        "budget_percent_core": budget_percent(fr, window / 60, CORE_SLO),
        "judge": {**k6, "completion_ratio": (done / (done + lost)) if (done + lost) else None},
        "symptom_alerts_fired": sorted(k for k, v in alerts.items() if k in SYMPTOM_ALERTS and any(t > a.inject for ts in v for t in ts)),
        "revisions": {"before": rb, "after": ra, "scenario_own": own},
        "aborted": a.aborted or None,
        "verdict_blockers": verdict(core.get("requests", 0), rb, ra, a.aborted, own),
        "mitigation_seconds": (a.mitigated - a.inject) if a.mitigated else None,
        "manual": {"declared_at": None, "severity": None, "mitigated_at": a.mitigated, "cause_identified_at": None, "cause_evidence": None},
    }
    json.dump(clean(rec), sys.stdout, ensure_ascii=False, indent=1, allow_nan=False)

if __name__ == "__main__":
    main()
