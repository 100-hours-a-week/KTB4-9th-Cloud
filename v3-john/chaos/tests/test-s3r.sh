#!/usr/bin/env bash
# S3r 원복(stop.sh) 테스트(가짜 kubectl·aws). 실행: bash v3-john/chaos/tests/test-s3r.sh
# drain이 끝나지 않은 채 중단되면 옛 노드(DB·큐가 아직 있는 노드)를 종료하지 않고 되살려야 한다.
set -uo pipefail
DIR=$(cd "$(dirname "$0")" && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; fail=0
ok() { echo "ok   $1"; }; no() { echo "FAIL $1"; fail=1; }
mkdir "$T/bin"
cat > "$T/bin/kubectl" <<'K'
#!/usr/bin/env bash
echo "kubectl $*" >> "$CALLS"
case "$*" in
  *"get nodes -l workload-class=stateful"*) printf '%b' "$FAKE_NODES";;
  *"get pod "*"nodeName"*) echo "$FAKE_PODNODE";;
  *"get pod "*) echo True;;
  *"get node "*"providerID"*) n=$(echo "$*" | awk '{print $3}'); echo "aws:///ap-northeast-2a/i-$n";;
  *"get node "*) :;;
esac
K
cat > "$T/bin/aws" <<'A'
#!/usr/bin/env bash
echo "aws $*" >> "$CALLS"
A
chmod +x "$T/bin/kubectl" "$T/bin/aws"; export PATH="$T/bin:$PATH" CALLS="$T/calls"
run() { : > "$CALLS"; R="$T/rec"; rm -rf "$R"; mkdir "$R"; echo old1 > "$R/s3r-old-node"; printf '%s' "$1" > "$R/s3r-events"
  RECORD_DIR="$R" bash "$DIR/../scenarios/s3r/stop.sh" >/dev/null 2>&1; }
export FAKE_NODES='old1 True true\nnew1 True \n'
FAKE_PODNODE=old1 run "1 새 노드 요청(desired 2)
"
grep -q 'instance-id i-old1' "$CALLS" && no "drain 전 중단인데 옛 노드를 종료함" || ok "drain 전 중단: 옛 노드 종료 안 함"
grep -q 'kubectl uncordon old1' "$CALLS" && ok "drain 전 중단: 옛 노드 uncordon" || no "uncordon 없음"
grep -q 'instance-id i-new1' "$CALLS" && ok "drain 전 중단: 새 노드 종료" || no "새 노드 종료 없음"
FAKE_PODNODE=new1 run "1 옛 노드 drain 완료(old1)
"
grep -q 'instance-id i-old1' "$CALLS" && ok "drain 완료 + 파드 이동: 옛 노드 종료" || no "정상 경로에서 옛 노드 종료 안 함"
grep -q 'instance-id i-new1' "$CALLS" && no "정상 경로에서 새 노드를 종료함" || ok "정상 경로: 새 노드 유지"
FAKE_PODNODE=old1 run "1 옛 노드 drain 완료(old1)
"
grep -q 'instance-id i-old1' "$CALLS" && no "파드가 옛 노드에 남았는데 종료함" || ok "파드가 옛 노드에 남으면 종료 안 함"
export FAKE_PODNODE=new1; : > "$CALLS"; R="$T/rec"; rm -rf "$R"; mkdir "$R"; echo old1 > "$R/s3r-old-node"; echo "1 옛 노드 drain 완료(old1)" > "$R/s3r-events"
( sleep 300 & echo $! > "$R/s3r-recorder.pid" ); RECORD_DIR="$R" bash "$DIR/../scenarios/s3r/stop.sh" >/dev/null 2>&1
kill -0 "$(cat "$R/s3r-recorder.pid")" 2>/dev/null && { no "기록기가 남아 있음"; kill "$(cat "$R/s3r-recorder.pid")"; } || ok "원복 때 기록기 종료"
grep -q 'echo \$! > "\$RECORD_DIR/s3r-recorder.pid"' "$DIR/../scenarios/s3r/inject.sh" && ok "주입이 기록기 PID를 남긴다" || no "inject.sh PID 기록 없음"
exit $fail
