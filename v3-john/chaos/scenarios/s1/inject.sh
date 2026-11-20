#!/usr/bin/env bash
# S1 주입: "비용 절감" 명목으로 core 메모리를 낮추는 PR을 main에 병합한다(설계서 9.1).
#   S1_MEMORY=<값>  requests와 limits를 모두 이 값으로 둔다(요청이 제한보다 클 수 없으므로 함께 낮춘다).
# 새 파드가 준비 상태 검사를 통과해 롤아웃이 끝나면 반환한다. 기동이 실패하는 값은 S1에 쓰지 않으므로 실패로 끝낸다.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
: "${S1_MEMORY:?S1_MEMORY를 지정한다(예: 640Mi)}"
read -r req lim <<<"$(s1_current)"
[ -f "$RECORD_DIR/s1-original" ] || echo "$req $lim" > "$RECORD_DIR/s1-original"
s1_merge "$S1_MEMORY" "$S1_MEMORY" "chaos(S1): core 메모리를 ${S1_MEMORY}로 낮춰 노드 비용 절감"
kubectl rollout status deployment/cosmos-core -n prod --timeout=300s
echo "$(date +%s) 롤아웃 완료(준비 상태 검사 통과)" >> "$RECORD_DIR/s1-events"
