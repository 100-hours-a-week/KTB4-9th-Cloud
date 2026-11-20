#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0

assert_contains() {
  local file="$1"
  local expected="$2"
  local label="$3"

  if ! grep -Fq -- "$expected" "$file"; then
    printf 'FAIL: %s (%s 에서 %s 누락)\n' "$label" "$file" "$expected" >&2
    FAILURES=$((FAILURES + 1))
  fi
}

assert_node_group_sizes() {
  local group="$1"
  local min="$2"
  local desired="$3"
  local max="$4"
  local file="${ROOT_DIR}/modules/eks/variables.tf"
  local block

  block="$(sed -n "/    ${group} = {/,/    }/p" "$file")"
  for pair in "min_size       = ${min}" "desired_size   = ${desired}" "max_size       = ${max}"; do
    if ! grep -Fq -- "$pair" <<<"$block"; then
      printf 'FAIL: %s 노드 그룹에 %s 누락\n' "$group" "$pair" >&2
      FAILURES=$((FAILURES + 1))
    fi
  done
}

assert_node_group_sizes system-ng 1 1 2
assert_node_group_sizes application-ng 1 1 2
assert_node_group_sizes stateful-ng 1 1 1
assert_node_group_sizes judge-base-ng 1 1 1

DATA_TF="${ROOT_DIR}/modules/data/main.tf"
assert_contains "$DATA_TF" 'instance_class              = "db.t4g.micro"' 'RDS 테스트 인스턴스 클래스'
assert_contains "$DATA_TF" 'cache_usage_limits {' 'ElastiCache 사용량 제한 블록'
assert_contains "$DATA_TF" 'maximum = 1' 'ElastiCache DataStorage 1GB 상한'
assert_contains "$DATA_TF" 'maximum = 1000' 'ElastiCache ECPU 1000/초 상한'

while IFS='|' read -r app expected; do
  assert_contains "${ROOT_DIR}/gitops/environments/prod/${app}" "$expected" "${app} requests"
done <<'REQUESTS'
auth.yaml|requests: { cpu: 250m, memory: 768Mi }
core.yaml|requests: { cpu: 250m, memory: 768Mi }
battle.yaml|requests: { cpu: 250m, memory: 768Mi }
judge-api.yaml|requests: { cpu: 250m, memory: 512Mi }
judge-worker.yaml|requests: { cpu: 500m, memory: 1Gi }
ai-llm.yaml|requests: { cpu: 250m, memory: 512Mi }
mlflow.yaml|requests: { cpu: 250m, memory: 1Gi }
battle-worker.yaml|requests: { cpu: 125m, memory: 384Mi }
ai-make-problem.yaml|requests: { cpu: 125m, memory: 384Mi }
ai-problem-batch.yaml|requests: { cpu: 125m, memory: 384Mi }
ai-postgres.yaml|requests: { cpu: 250m, memory: 512Mi }
judge-postgres.yaml|requests: { cpu: 250m, memory: 512Mi }
rabbitmq.yaml|requests: { cpu: 125m, memory: 256Mi }
judge-redis.yaml|requests: { cpu: 50m, memory: 128Mi }
REQUESTS

for app in auth core battle judge-api ai-llm; do
  assert_contains "${ROOT_DIR}/gitops/environments/prod/${app}.yaml" 'hpa: { enabled: true, min: 1, max: 1, cpu: 70 }' "${app} HPA 최대 1"
done

assert_contains "${ROOT_DIR}/gitops/environments/prod/platform/gateway.yaml" 'replicas: 1' 'Envoy Gateway replica 1'
assert_contains "${ROOT_DIR}/gitops/environments/prod/platform/judge-worker-keda.yaml" 'maxReplicaCount: 1' 'Judge Worker KEDA 최대 1'
assert_contains "${ROOT_DIR}/helm/addons-values/monitoring/kube-prometheus-stack.yaml" 'requests: { cpu: 250m, memory: 1Gi }' 'Prometheus requests'
assert_contains "${ROOT_DIR}/helm/addons-values/monitoring/loki.yaml" 'requests: { cpu: 100m, memory: 256Mi }' 'Loki requests'
assert_contains "${ROOT_DIR}/helm/addons-values/monitoring/tempo.yaml" 'requests: { cpu: 250m, memory: 768Mi }' 'Tempo requests'
assert_contains "${ROOT_DIR}/helm/addons-values/monitoring/tempo.yaml" 'initialDelaySeconds: 300' 'Tempo cold-start liveness 유예'
assert_contains "${ROOT_DIR}/helm/addons-values/monitoring/tempo.yaml" 'nodeSelector: { workload-class: application }' 'Tempo application 노드 배치'
assert_contains "${ROOT_DIR}/helm/addons-values/monitoring/otel-collector.yaml" 'requests: { cpu: 50m, memory: 128Mi }' 'OpenTelemetry Collector requests'
assert_contains "${ROOT_DIR}/helm/addons-values/monitoring/otel-collector.yaml" 'nodeSelector: { workload-class: application }' 'Collector application 노드 배치'
assert_contains "${ROOT_DIR}/helm/addons-values/monitoring/alloy.yaml" 'requests: { cpu: 25m, memory: 96Mi }' 'Alloy requests'
assert_contains "${ROOT_DIR}/helm/addons-values/monitoring/network-policies.yaml" 'cidr: 169.254.170.23/32' 'Tempo Pod Identity endpoint egress'

if (( FAILURES > 0 )); then
  printf '\n비용 프로파일 검증 실패: %d개\n' "$FAILURES" >&2
  exit 1
fi

printf '비용 프로파일 검증 통과\n'
