#!/usr/bin/env python3
# v3-john prod 값 파일의 메모리 설정을 검사한다(S1 단계 5). 실패한 파일마다 "파일: 이유"를 출력하고 하나라도 있으면 1로 끝난다.
#   python3 .github/scripts/check-v3-john-values.py v3-john/gitops/environments/prod/*.yaml
# 규칙
#   1. 메모리 한도 >= 메모리 요청
#   2. Spring 이미지면 jvmOptions에 -XX:MaxRAMPercentage가 있다(기본 25%면 한도를 낮춰도 힙이 같이 줄어 결함이 숨는다)
#   3. Spring 이미지면 힙 밖 메모리(한도 × (1 - 비율)) >= 256Mi(메타스페이스, 스레드, OTel 에이전트. 448Mi·75%는 112Mi로 기동 중 OOMKilled)
import re, sys

HEADROOM_MI = 256
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

def main(paths):
    bad = 0
    for p in paths:
        for e in check(p):
            print(f"{p}: {e}")
            bad += 1
    return 1 if bad else 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
