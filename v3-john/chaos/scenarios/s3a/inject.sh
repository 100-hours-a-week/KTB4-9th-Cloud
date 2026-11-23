#!/usr/bin/env bash
# S3a 주입: NetworkChaos로 Spring 3개 → RDS 연결을 끊는다. 적용된 대상 파드 수를 기록한다.
set -euo pipefail
D=$(dirname "$0")
kubectl apply -f "$D/networkchaos.yaml"
for _ in $(seq 1 30); do
  n=$(kubectl get networkchaos s3a-rds-partition -n prod -o json | jq '[.status.experiment.containerRecords[]? | select(.phase=="Injected")] | length')
  (( n > 0 )) && { echo "$(date +%s) 주입 대상 ${n}개" >> "$RECORD_DIR/s3a-events"; exit 0; }
  sleep 2
done
echo "NetworkChaos가 60초 안에 주입되지 않았다" >&2; exit 1
