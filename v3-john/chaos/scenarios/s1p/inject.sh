#!/usr/bin/env bash
# S1' 주입: auth를 평소 배포 방식으로 재시작한다(롤링, 값 변경 없음). core 풀 변경은 pre-inject.sh가 먼저 끝낸다.
# auth 롤아웃 완료는 기다리지 않고 반환한다.
set -euo pipefail
kubectl rollout restart deployment/cosmos-auth -n prod
echo "$(date +%s) auth 재시작 트리거" >> "$RECORD_DIR/s1p-events"
