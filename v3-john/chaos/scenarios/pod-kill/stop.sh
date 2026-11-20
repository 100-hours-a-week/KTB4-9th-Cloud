#!/usr/bin/env bash
# 원복할 것은 없다. Deployment가 새 파드를 다 띄울 때까지 기다린다. 여러 번 불러도 안전하다.
kubectl rollout status deployment/cosmos-core -n prod --timeout=300s
