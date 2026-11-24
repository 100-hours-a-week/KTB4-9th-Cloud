#!/usr/bin/env bash
# S1' 원복: KEDA 일시 정지 주석을 지우고 채점 워커가 Ready가 될 때까지 기다린다. 여러 번 불려도 안전하다.
set -euo pipefail
if [ -n "$(kubectl get scaledobject cosmos-judge-worker -n prod -o jsonpath='{.metadata.annotations.autoscaling\.keda\.sh/paused-replicas}' 2>/dev/null)" ]; then
  kubectl annotate scaledobject cosmos-judge-worker -n prod autoscaling.keda.sh/paused-replicas-
  echo "$(date +%s) 채점 워커 일시 정지 해제" >> "$RECORD_DIR/s1c-events"
fi
for _ in $(seq 1 30); do
  [ -n "$(kubectl get pods -n prod -l app.kubernetes.io/name=cosmos-judge-worker -o name 2>/dev/null)" ] && break
  sleep 5
done
kubectl wait -n prod --for=condition=Ready pod -l app.kubernetes.io/name=cosmos-judge-worker --timeout=300s \
  || { echo "채점 워커가 300초 안에 Ready가 되지 않았다" >&2; exit 1; }
echo "$(date +%s) 채점 워커 Ready" >> "$RECORD_DIR/s1c-events"
