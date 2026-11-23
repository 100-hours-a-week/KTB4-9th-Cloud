# REPORT.md의 수치가 records/*.json, S3 결과와 같은지 대조한다.
#   python3 lib/verify-report.py [--s3]      (--s3: 같은 기록이 S3에도 있는지 확인)
# CLAIMS: (기록 이름, JSON 경로, 표시 형식). 기록의 값을 형식대로 만든 문자열이 REPORT.md 비교표에 있어야 한다.
import json, os, subprocess, sys
CHAOS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPORT = open(os.path.join(CHAOS, "REPORT.md"), encoding="utf-8").read()

def get(rec, path):
    v = rec
    for k in path.split("."):
        v = v.get(k) if isinstance(v, dict) else None
    return v

def frac(rec, base):
    return f"{get(rec, base + '.errors_5xx'):,}/{get(rec, base + '.requests'):,}"

CLAIMS = []
for name in ["s1-before-20261120-1608", "s1-step1-20261120-1634", "s1-step2-20261123-1559", "s1-step3-20261123-1701",
             "s1-step4-20261123-1750", "s2-before-20261123-1414", "s2-step1-20261123-1726", "s2-step2-20261123-1831",
             "s2-step3-20261123-1908", "s3a-before-20261123-1934", "s3a-step1-20261123-2013", "s3a-step2-20261123-2042"]:
    CLAIMS.append((name, "핵심 5xx", lambda r: frac(r, "journeys.core")))
    CLAIMS.append((name, "채점 유실", lambda r: f"| {get(r, 'judge.judge_lost')} |"))
    CLAIMS.append((name, "첫 알림", lambda r: (f"{r['detection']['alert']} {r['detection']['seconds']}초" if r.get("detection") else None)))
    CLAIMS.append((name, "예산", lambda r: f"{r['budget_percent_core']:.2f}%"))

def main():
    bad = 0
    for name, what, fmt in CLAIMS:
        rec = json.load(open(os.path.join(CHAOS, "records", name + ".json")))
        s = fmt(rec)
        if s is None:
            continue
        row = next((l for l in REPORT.splitlines() if name in l), None)
        if row is None:
            print(f"FAIL {name}: 보고서에 행이 없다"); bad += 1; continue
        if s not in row:
            print(f"FAIL {name} {what}: 기록 {s!r}가 행에 없다"); bad += 1
    if "--s3" in sys.argv:
        for name in sorted({c[0] for c in CLAIMS}):
            r = subprocess.run(["aws", "s3", "ls", f"s3://cosmos-db-backup-352635536602/chaos/{name}/record.json"], capture_output=True)
            if r.returncode != 0:
                print(f"FAIL {name}: S3에 record.json 없음"); bad += 1
    print("OK" if not bad else f"{bad}건 불일치")
    return 1 if bad else 0

if __name__ == "__main__":
    sys.exit(main())
