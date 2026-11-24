#!/usr/bin/env bash
# S3w 원복(사람 개입에 해당): 정지한 프로세스를 다시 돌린다(SIGCONT). 생존 검사가 이미 재시작했다면 새 파드라 할 일이 없다. 여러 번 불러도 안전하다.
set -uo pipefail
ev() { echo "$(date +%s) $*" >> "$RECORD_DIR/s3w-events"; echo "$*"; }
for p in $(kubectl get pods -n prod -l app.kubernetes.io/name=cosmos-judge-worker --field-selector status.phase=Running -o jsonpath='{.items[*].metadata.name}'); do
  kubectl exec -n prod "$p" -- sh -c 'pkill -CONT -f "^resque-"' >/dev/null 2>&1 || true
done
ev "원복: 정지한 채점 프로세스 재개"
kubectl get pods -n prod -l app.kubernetes.io/name=cosmos-judge-worker -o jsonpath='{range .items[*]}{.metadata.name} {.status.containerStatuses[0].restartCount}{"\n"}{end}' > "$RECORD_DIR/s3w-restarts-after"
exit 0
