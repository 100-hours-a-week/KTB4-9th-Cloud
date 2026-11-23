#!/usr/bin/env python3
# v3-john prod 값 파일의 메모리 설정을 검사한다(S1 단계 5). 실패한 파일마다 "파일: 이유"를 출력하고 하나라도 있으면 1로 끝난다.
#   python3 .github/scripts/check-v3-john-values.py v3-john/gitops/environments/prod/*.yaml
# 규칙
#   1. 메모리 한도 >= 메모리 요청
#   2. Spring 이미지면 jvmOptions에 -XX:MaxRAMPercentage가 있다(기본 25%면 한도를 낮춰도 힙이 같이 줄어 결함이 숨는다)
#   3. Spring 이미지면 힙 밖 메모리(한도 × (1 - 비율)) >= 256Mi(메타스페이스, 스레드, OTel 에이전트. 448Mi·75%는 112Mi로 기동 중 OOMKilled)
#   4. Spring 서비스의 최대 연결 합계 sum((hpa.max + surge) x HIKARI_MAXIMUM_POOL_SIZE)가 RDS_MAX_CONNECTIONS x 0.8 이하다(S1' 단계 2).
#      넘기면 "연결 예산" 실패 한 줄을 출력한다. 전달된 파일 전체를 한 번에 계산한다.
#      surge는 rollout이 켜져 있으면 ceil(hpa.max x 0.25), 아니면 rollingUpdate maxSurge(값 파일에 없으면 차트 기본 1)이다.
#      풀 크기 줄이 없으면 Hikari 기본 10으로 계산한다
import math, os, re, sys

HEADROOM_MI = 256
# RDS 최대 연결 수. 2026-11-24 SHOW VARIABLES 실측값이다(Prometheus RdsConnectionBudgetHigh 분모, core connectionGuard rdsMax와 같아야 한다)
RDS_MAX_CONNECTIONS = 303
BUDGET_RATIO = 0.8
HIKARI_DEFAULT_POOL = 10
CHART_DEFAULT_MAX_SURGE = 1  # v3-john/gitops/charts/cosmos-app/values.yaml의 rollingUpdate.maxSurge
UNITS = {"Ki": 1 / 1024, "Mi": 1, "Gi": 1024, "K": 1000 / 1024 / 1024, "M": 1000 * 1000 / 1024 / 1024, "G": 1000 ** 3 / 1024 / 1024}

def mi(v):
    m = re.fullmatch(r"([0-9.]+)([KMG]i?)?", v)
    if not m:
        raise ValueError(v)
    return float(m.group(1)) * UNITS.get(m.group(2) or "", 1 / 1024 / 1024)

def check(path):
    s = open(path, encoding="utf-8").read()
    errs = []
    req = re.search(r"^\s*requests:\s*\{[^}]*memory:\s*([0-9A-Za-z.]+)", s, re.M)
    lim = re.search(r"^\s*limits:\s*\{[^}]*memory:\s*([0-9A-Za-z.]+)", s, re.M)
    if req and lim and mi(lim.group(1)) < mi(req.group(1)):
        errs.append(f"메모리 한도({lim.group(1)})가 요청({req.group(1)})보다 작다")
    img = re.search(r"^image:\s*(\S+)", s, re.M)
    if img and "/cosmos-v2/spring" in img.group(1):
        pct = re.search(r"^jvmOptions:.*-XX:MaxRAMPercentage=([0-9.]+)", s, re.M)
        if not pct:
            errs.append("Spring 이미지인데 jvmOptions에 -XX:MaxRAMPercentage가 없다")
        elif lim:
            head = mi(lim.group(1)) * (1 - float(pct.group(1)) / 100)
            if head < HEADROOM_MI:
                errs.append(f"힙 밖 메모리 {head:.0f}Mi < {HEADROOM_MI}Mi(한도 {lim.group(1)}, MaxRAMPercentage={pct.group(1)})")
    return errs

def connection_budget(paths):
    """Spring 서비스별 (hpa.max + surge) x 풀 크기의 합과 서비스별 계산 내역을 돌려준다."""
    total, lines = 0, []
    for p in paths:
        s = open(p, encoding="utf-8").read()
        img = re.search(r"^image:\s*(\S+)", s, re.M)
        if not (img and "/cosmos-v2/spring" in img.group(1)):
            continue
        hpa = re.search(r"^hpa:.*\bmax:\s*(\d+)", s, re.M)
        mx = int(hpa.group(1)) if hpa else 1
        if re.search(r"^rollout:\s*\{[^}]*enabled:\s*true", s, re.M):
            surge = math.ceil(mx * 0.25)
        else:
            sg = re.search(r"^rollingUpdate:.*maxSurge:\s*(\d+)", s, re.M)
            surge = int(sg.group(1)) if sg else CHART_DEFAULT_MAX_SURGE
        pool = re.search(r"^\s*SPRING_DATASOURCE_HIKARI_MAXIMUM_POOL_SIZE:\s*\"?(\d+)", s, re.M)
        size = int(pool.group(1)) if pool else HIKARI_DEFAULT_POOL
        n = (mx + surge) * size
        total += n
        lines.append(f"{os.path.basename(p)}: (hpa max {mx} + surge {surge}) x 풀 {size} = {n}")
    return total, lines

def main(paths):
    bad = 0
    for p in paths:
        for e in check(p):
            print(f"{p}: {e}")
            bad += 1
    total, lines = connection_budget(paths)
    limit = RDS_MAX_CONNECTIONS * BUDGET_RATIO
    if total > limit:
        print(f"연결 예산 초과: 최대 연결 합계 {total} > 한도 {limit:.0f}(RDS {RDS_MAX_CONNECTIONS} x {BUDGET_RATIO}). " + "; ".join(lines))
        bad += 1
    return 1 if bad else 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
