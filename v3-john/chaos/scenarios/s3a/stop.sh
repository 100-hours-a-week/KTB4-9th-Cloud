#!/usr/bin/env bash
# S3a 원복: NetworkChaos를 지운다. 여러 번 불러도 안전하다. Spring 파드가 모두 준비될 때까지 기다린다.
set -uo pipefail
kubectl delete networkchaos s3a-rds-partition -n prod --ignore-not-found --wait=true --timeout=120s
echo "$(date +%s) 원복(NetworkChaos 삭제)" >> "${RECORD_DIR:-/tmp}/s3a-events"
for d in cosmos-auth cosmos-battle; do kubectl rollout status "deployment/$d" -n prod --timeout=300s || true; done
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=cosmos-core -n prod --timeout=300s || true
