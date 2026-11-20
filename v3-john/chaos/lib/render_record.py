# 실험 기록 JSON을 records/TEMPLATE.md 형식의 md로 바꾼다. 사람이 채울 칸은 그대로 둔다.
#   python3 render_record.py records/<이름>.json > records/<이름>.md
import json, os, sys, time

def dur(s):
    return f"{s // 60}분 {s % 60}초"

def kst(t):
    return time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(t + 9 * 3600))

def pct(x):
    return "-" if x is None else f"{x * 100:.2f}%"

def num(x):
    return "-" if x is None else f"{x:.0f}"

def main():
    rec = json.load(open(sys.argv[1]))
    tpl = open(os.path.join(os.path.dirname(__file__), "..", "records", "TEMPLATE.md")).read()
    det = rec.get("detection")
    rs = rec.get("recovery_seconds_core")
    j = rec.get("judge") or {}
    blockers = rec.get("verdict_blockers") or []
    rows = "\n".join(f"| {k} | {v['requests']} | {pct(v.get('failure_ratio'))} | {num(v.get('p95_ms'))} |"
                     for k, v in sorted(rec.get("journeys", {}).items()))
    t = rec["times"]
    print(tpl.format(
        scenario=rec["scenario"], step=rec["step"], testid=rec.get("testid"),
        inject_at=kst(t["inject"]), stop_at=kst(t["stop"]), end_at=kst(t["end"]),
        verdict="판정 가능" if not blockers else "판정 불가: " + "; ".join(blockers),
        detection=f"{dur(det['seconds'])} ({det['alert']})" if det else "탐지되지 않음",
        recovery="관찰 구간 안에 회복하지 못함" if rs is None else ("영향 없음" if rs == 0 else dur(rs)),
        budget=f"{rec.get('budget_percent_core')}%",
        read_p95="-" if rec.get("read_p95_ms") is None else f"{rec['read_p95_ms']:.0f}ms",
        submit_p95="-" if j.get("submit_p95_s") is None else f"{j['submit_p95_s']:.2f}초",
        judge=f"{pct(j.get('completion_ratio'))} (유실 {num(j.get('judge_lost'))}, 업무 거절 {num(j.get('submit_rejected'))})",
        alerts=", ".join(rec.get("symptom_alerts_fired") or []) or "없음",
        journeys=rows or "| - | 0 | - | - |",
    ), end="")

if __name__ == "__main__":
    main()
