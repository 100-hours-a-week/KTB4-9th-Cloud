#!/usr/bin/env bash
# S3w 주입: 채점 워커 파드 안의 채점 프로세스(resque)를 일시 정지(SIGSTOP)한다. 컨테이너는 Running으로 남지만 채점은 멈춘다.
# 2026-11-24 19:44 실제 사례(DB·큐 교체 뒤 채점 워커가 일을 거의 못 하는 상태로 남아 사람이 재시작할 때까지 장애 지속)를 재현한다.
set -euo pipefail
ev() { echo "$(date +%s) $*" >> "$RECORD_DIR/s3w-events"; echo "$*"; }
pods=$(kubectl get pods -n prod -l app.kubernetes.io/name=cosmos-judge-worker --field-selector status.phase=Running -o jsonpath='{.items[*].metadata.name}')
[ -n "$pods" ] || { echo "채점 워커 파드가 없다" >&2; exit 1; }
echo "$pods" > "$RECORD_DIR/s3w-pods"
kubectl get pods -n prod -l app.kubernetes.io/name=cosmos-judge-worker -o jsonpath='{range .items[*]}{.metadata.name} {.status.containerStatuses[0].restartCount}{"\n"}{end}' > "$RECORD_DIR/s3w-restarts-before"
for p in $pods; do kubectl exec -n prod "$p" -- sh -c 'pkill -STOP -f "^resque-" ; pgrep -f "^resque-" | wc -l' | xargs -I{} echo "$p 정지한 프로세스 {}개"; done
ev "채점 프로세스 정지($pods)"
