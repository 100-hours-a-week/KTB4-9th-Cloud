#!/usr/bin/env bash
# S1 원복: 주입 전 값으로 되돌리는 PR을 main에 병합한다. 이미 원래 값이면 아무것도 하지 않는다(여러 번 불려도 안전).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
[ -f "$RECORD_DIR/s1-original" ] || { echo "주입 기록 없음"; exit 0; }
read -r oreq olim < "$RECORD_DIR/s1-original"
read -r req lim <<<"$(s1_current)"
if [ "$req $lim" = "$oreq $olim" ]; then echo "이미 원래 값($oreq/$olim)"; exit 0; fi
s1_merge "$oreq" "$olim" "chaos(S1): core 메모리 되돌림(${oreq}/${olim})"
kubectl rollout status deployment/cosmos-core -n prod --timeout=600s
echo "$(date +%s) 원복 롤아웃 완료" >> "$RECORD_DIR/s1-events"
