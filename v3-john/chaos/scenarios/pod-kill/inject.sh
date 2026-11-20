#!/usr/bin/env bash
# 시험용 파드 종료: core 파드 하나를 지운다. 대응 순서(7장)를 처음부터 끝까지 연습하는 용도다.
set -euo pipefail
pod=$(kubectl get pods -n prod -l app.kubernetes.io/name=cosmos-core -o jsonpath='{.items[0].metadata.name}')
[ -n "$pod" ] || { echo "core 파드가 없다" >&2; exit 1; }
echo "$pod" > "$RECORD_DIR/killed-pod"
kubectl delete pod -n prod "$pod" --wait=false
