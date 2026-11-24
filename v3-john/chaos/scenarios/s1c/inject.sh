#!/usr/bin/env bash
# S1' 주입: 채점 워커를 0으로 멈춘다(KEDA 일시 정지 주석). 실제 채점 노드 회수(노드 교체 + 이미지 받기, 약 5분)를
# 시간이 일정한 방식으로 재현한다. 노드 cordon은 클러스터 오토스케일러가 새 노드를 띄워 중단 시간이 달라져 쓰지 않는다.
set -euo pipefail
kubectl annotate scaledobject cosmos-judge-worker -n prod autoscaling.keda.sh/paused-replicas=0 --overwrite
for _ in $(seq 1 24); do
  [ -z "$(kubectl get pods -n prod -l app.kubernetes.io/name=cosmos-judge-worker -o name 2>/dev/null)" ] && break
  sleep 5
done
[ -z "$(kubectl get pods -n prod -l app.kubernetes.io/name=cosmos-judge-worker -o name 2>/dev/null)" ] \
  || { echo "채점 워커가 120초 안에 0이 되지 않았다" >&2; exit 1; }
echo "$(date +%s) 채점 워커 0" >> "$RECORD_DIR/s1c-events"
