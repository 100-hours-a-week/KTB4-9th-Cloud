#!/usr/bin/env bash
# S3b 실행: 안전망 스냅샷 → 표식 확인 → 삭제 → 복구 → 표식 확인. 10초마다 /auth/me 응답 코드를 probe.log에 남긴다.
#   run.sh <단계 이름> recreate        개선 전: 재생성 복구
#   run.sh <단계 이름> pitr            단계 3: 자동 백업에서 삭제 1분 전 시점으로 복원
set -uo pipefail
D=$(cd "$(dirname "$0")" && pwd); source "$D/lib.sh"
STEP=${1:?단계}; MODE=${2:?recreate|pitr}
export RECORD_DIR="$S3B_V3/chaos/records/s3b-$STEP-$(date +%Y%m%d-%H%M)"; mkdir -p "$RECORD_DIR"
( while :; do echo "$(date +%s) $(s3b_probe)" >> "$RECORD_DIR/probe.log"; sleep 10; done ) & PROBE=$!
trap 'kill $PROBE 2>/dev/null' EXIT
s3b_event "시작 $STEP $MODE, 표식 응답 $(s3b_probe)"
"$D/snapshot.sh" || { s3b_event "스냅샷 실패"; exit 1; }
T_DEL=$(date +%s)
S3B_KEEP_BACKUPS=$([ "$MODE" = pitr ] && echo 1 || echo 0) "$D/inject.sh"; rc=$?
[ $rc = 0 ] || { s3b_event "주입 실패 rc=$rc"; exit $rc; }
if [ "$MODE" = pitr ]; then "$D/recover-pitr.sh" "$(date -u -r $((T_DEL - 60)) +%Y-%m-%dT%H:%M:%SZ)"; else "$D/recover-recreate.sh"; fi
s3b_event "끝, 표식 응답 $(s3b_probe)"
python3 - "$RECORD_DIR" <<'PY'
import sys, json
d = sys.argv[1]
ev = [l.split(" ", 1) for l in open(f"{d}/s3b-events").read().splitlines()]
pr = [l.split() for l in open(f"{d}/probe.log").read().splitlines() if len(l.split()) == 2]
t = lambda key: next((int(a) for a, b in ev if key in b), None)
t_del = t("삭제 요청")
# 서비스 불가: 5xx나 연결 실패(000). 401·404는 서비스는 되지만 표식 사용자가 없다(데이터 손실)는 뜻이라 불가로 보지 않는다.
bad = lambda c: c == "000" or c.startswith("5")
down = next((int(a) for a, c in pr if int(a) >= t_del and bad(c)), None)
up = next((int(a) for a, c in pr if down and int(a) > down and not bad(c)), None)
rec = {"delete_requested": t_del, "first_failure": down, "service_back": up,
       "service_unavailable_seconds": (up - down) if (up and down) else None,
       "last_probe": pr[-1][1] if pr else None,
       "marker_after_recovery": next((b.split()[-1] for a, b in reversed(ev) if "표식 응답" in b), None)}
json.dump(rec, open(f"{d}/summary.json", "w"), ensure_ascii=False, indent=1); print(json.dumps(rec, ensure_ascii=False))
PY
