#!/usr/bin/env bash
# S1 주입: "비용 절감" 명목으로 core 메모리를 낮추는 PR을 main에 병합한다(설계서 9.1).
#   S1_MEMORY=<값>  requests와 limits를 모두 이 값으로 둔다(요청이 제한보다 클 수 없으므로 함께 낮춘다).
# 새 버전 파드가 준비 상태 검사를 한 번이라도 통과하면 반환한다. 기동조차 못 하는 값은 S1에 쓰지 않으므로 300초 안에 통과하지 못하면 실패다.
# 롤아웃 완료는 기다리지 않는다. 이중화(단계 3) 뒤에는 새 파드가 부하에서 죽는 동안 옛 파드가 남아 롤아웃이 끝나지 않는다(2026-11-23).
#   S1_REQUIRE_READY=0  준비 통과를 요구하지 않고 새 버전 파드가 만들어지면 반환한다. 단계 3의 JVM 힙 75%에서는 448Mi 파드가
#                       기동 중 죽는다. 이 경우 "잘못된 배포가 막힌 상태"를 10분 동안 재려고 쓴다. 값 탐색에는 쓰지 않는다.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
: "${S1_MEMORY:?S1_MEMORY를 지정한다(예: 640Mi)}"
read -r req lim <<<"$(s1_current)"
[ -f "$RECORD_DIR/s1-original" ] || echo "$req $lim" > "$RECORD_DIR/s1-original"
s1_merge "$S1_MEMORY" "$S1_MEMORY" "chaos(S1): core 메모리를 ${S1_MEMORY}로 낮춰 노드 비용 절감"

deadline=$(( $(date +%s) + 300 ))
while :; do
  # 파드의 메모리 한도로 새 버전을 가려낸다. Deployment와 Rollout(단계 4) 어느 쪽이 관리해도 같다.
  st=$(s1_pods_state "$S1_MEMORY")
  if grep -qw True <<<"$st"; then
    echo "$(date +%s) 새 버전 파드 준비 상태 검사 통과" >> "$RECORD_DIR/s1-events"; break
  fi
  if [ "${S1_REQUIRE_READY:-1}" = 0 ] && [ -n "$st" ]; then
    echo "$(date +%s) 새 버전 파드 생성(준비 미요구)" >> "$RECORD_DIR/s1-events"; break
  fi
  (( $(date +%s) < deadline )) || { echo "새 버전 파드가 300초 안에 준비되지 않았다" >&2; exit 1; }
  sleep 2
done
if s1_wait_all "$S1_MEMORY" 60 2>/dev/null; then
  echo "$(date +%s) 롤아웃 완료" >> "$RECORD_DIR/s1-events"
else
  echo "$(date +%s) 롤아웃 진행 중(옛 파드가 남아 있음)" >> "$RECORD_DIR/s1-events"
fi
