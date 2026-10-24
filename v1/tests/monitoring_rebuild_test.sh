#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
monitoring_root="${repo_root}/v1/monitoring"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

required_files=(
  "${monitoring_root}/alloy/main.alloy"
  "${monitoring_root}/alloy/judge.alloy"
  "${monitoring_root}/prometheus/prometheus.yml"
  "${monitoring_root}/compose/main-cadvisor.yml"
  "${monitoring_root}/grafana/provisioning/dashboards.yml"
  "${monitoring_root}/grafana/dashboards/01-v1-service-overview.json"
  "${monitoring_root}/grafana/dashboards/02-v1-infrastructure.json"
  "${monitoring_root}/grafana/dashboards/03-v1-application-logs.json"
  "${monitoring_root}/grafana/dashboards/04-v1-data-layer.json"
)

for required_file in "${required_files[@]}"; do
  [[ -f "$required_file" ]] || fail "missing ${required_file#${repo_root}/}"
done

dashboard_dir="${monitoring_root}/grafana/dashboards"
dashboard_count="$(find "$dashboard_dir" -maxdepth 1 -name '*.json' -type f | wc -l | tr -d ' ')"
[[ "$dashboard_count" == "4" ]] || fail "exactly four v1 dashboards are required"

expected_uids=(
  cosmos-v1-service-overview
  cosmos-v1-infrastructure
  cosmos-v1-application-logs
  cosmos-v1-data-layer
)

for uid in "${expected_uids[@]}"; do
  matches="$(jq -r --arg uid "$uid" 'select(.uid == $uid) | .uid' "$dashboard_dir"/*.json | wc -l | tr -d ' ')"
  [[ "$matches" == "1" ]] || fail "dashboard uid ${uid} must exist exactly once"
done

for dashboard in "$dashboard_dir"/*.json; do
  jq -e '
    .schemaVersion == 39 and
    .editable == true and
    (.tags | index("version=v1")) != null and
    (.title | startswith("v1 ")) and
    ([.. | objects | .datasource?.uid? // empty] | all(. == "prometheus" or . == "P8E80F9AEF21F6940" or . == "-- Mixed --"))
  ' "$dashboard" >/dev/null || fail "invalid v1 dashboard contract: ${dashboard##*/}"
done

if rg -n -i 'migration|k6|cosmos-stage|stage-cloudwatch|cosmos-v2' "$dashboard_dir"; then
  fail "v1 dashboards must not contain migration, load-test, or v2 panels"
fi

overview="${dashboard_dir}/01-v1-service-overview.json"
infrastructure="${dashboard_dir}/02-v1-infrastructure.json"
logs="${dashboard_dir}/03-v1-application-logs.json"
data_layer="${dashboard_dir}/04-v1-data-layer.json"

rg -q 'http_server_requests_seconds_count' "$overview" || fail "Spring RPS is missing"
rg -q 'cosmos_requests_total' "$overview" || fail "Judge RPS is missing"
rg -Fq 'uvicorn\\.access' "$overview" || fail "FastAPI log-derived RPS is missing"
rg -Fq '[45][0-9]{2}$' "$overview" || fail "FastAPI HTTP error rate is missing"
fastapi_error_expr="$(jq -r '.panels[] | select(.id == 5) | .targets[].expr' "$overview")"
[[ "$fastapi_error_expr" != *'clamp_min('* ]] || fail "FastAPI LogQL must not use unsupported clamp_min"
zero_safe_panels="$(jq -r '.panels[] | select(.id == 2 or .id == 5 or .id == 8 or .id == 9) | .targets[].expr' "$overview")"
zero_safe_count="$(printf '%s\n' "$zero_safe_panels" | rg -c 'or vector\(0\)')"
[[ "$zero_safe_count" == "4" ]] || fail "zero-error and empty-latency panels must render 0 instead of No data"
rg -q 'node_cpu_seconds_total' "$infrastructure" || fail "EC2 CPU is missing"
rg -q 'node_memory_MemAvailable_bytes' "$infrastructure" || fail "EC2 RAM is missing"
rg -q 'container_cpu_usage_seconds_total' "$infrastructure" || fail "container CPU is missing"
rg -q 'container_memory_working_set_bytes' "$infrastructure" || fail "container RAM is missing"
rg -q 'count_over_time' "$logs" || fail "log volume/error panels are missing"
rg -q 'cosmos-backend-|cosmos-ai-|judge-server-|judge-worker-' "$logs" || fail "application container filter is missing"
non_empty_log_selectors="$(jq '[.panels[].targets[].expr | select(contains("container=~\"") and (contains("container=~\"$") | not))] | length' "$logs")"
[[ "$non_empty_log_selectors" == "12" ]] || fail "every Loki panel needs a non-empty application matcher"
if rg -q 'environment=~"stage\|"|version=~"v1\|"' "$logs"; then
  fail "Loki selectors must not rely on empty-compatible environment/version matchers"
fi

application_log_panels="$(jq '[.panels[] | select(.type == "logs")] | length' "$logs")"
[[ "$application_log_panels" == "4" ]] || fail "logs must be split into four application-specific panels"

jq -e '
  def expr_for($title): .panels[] | select(.title == $title) | .targets[0].expr;
  (expr_for("Spring Logs") | contains("cosmos-backend-.+") and (contains("cosmos-ai") | not)) and
  (expr_for("FastAPI Logs") | contains("cosmos-ai-(blue|green)") and (contains("cosmos-ai-postgres") | not)) and
  (expr_for("Judge API Logs") | contains("judge-server-.+") and (contains("judge-worker") | not)) and
  (expr_for("Judge Worker Logs") | contains("judge-worker-.+") and (contains("judge-server") | not))
' "$logs" >/dev/null || fail "each application log panel must use an isolated container selector"
rg -q 'mysql_up' "$data_layer" || fail "MySQL health is missing"
rg -q 'pg_up' "$data_layer" || fail "PostgreSQL health is missing"
rg -q 'redis_up' "$data_layer" || fail "Redis health is missing"
rg -q 'cosmos_judge_queue_depth' "$data_layer" || fail "Judge queue depth is missing"

main_alloy="${monitoring_root}/alloy/main.alloy"
judge_alloy="${monitoring_root}/alloy/judge.alloy"
prometheus_config="${monitoring_root}/prometheus/prometheus.yml"
cadvisor_compose="${monitoring_root}/compose/main-cadvisor.yml"
v1_security="${repo_root}/v1/security.tf"

rg -q '127\.0\.0\.1:8080' "$main_alloy" || fail "Spring must be scraped directly on port 8080"
rg -q '/api/actuator/prometheus' "$main_alloy" || fail "Spring metrics path is missing"
rg -q 'target_label\s*=\s*"version"' "$main_alloy" || fail "v1 metric label is missing"
rg -q 'target_label\s*=\s*"version"' "$judge_alloy" || fail "Judge v1 metric label is missing"
rg -q 'older_than\s*=\s*"168h"' "$main_alloy" || fail "main Alloy must drop logs older than Loki retention"
rg -q 'older_than\s*=\s*"168h"' "$judge_alloy" || fail "Judge Alloy must drop logs older than Loki retention"
rg -q '10\.0\.1\.184:18080' "$prometheus_config" || fail "main cAdvisor target is missing"
rg -q '10\.0\.1\.143:8080' "$prometheus_config" || fail "Judge cAdvisor target is missing"
if rg -q '"10\.0\.1\.184:80"|job_name:\s*cosmos-backend' "$prometheus_config"; then
  fail "broken central Spring target must be removed"
fi
rg -q '0\.0\.0\.0:18080:8080' "$cadvisor_compose" || fail "main cAdvisor must use the dedicated monitoring port"
rg -q 'ghcr\.io/google/cadvisor:v0\.60\.6' "$cadvisor_compose" || fail "cAdvisor must support Docker 29 containerd storage"
rg -q 'restart:\s*unless-stopped' "$cadvisor_compose" || fail "main cAdvisor must restart automatically"
cadvisor_ingress="$(sed -n '/Allow cAdvisor from monitoring server/,/}/p' "$v1_security")"
[[ "$cadvisor_ingress" == *'from_port       = 18080'* ]] || fail "main SG must allow cAdvisor port 18080"
[[ "$cadvisor_ingress" == *'security_groups = [aws_security_group.monitoring_sg.id]'* ]] || fail "cAdvisor must only allow the monitoring SG"

printf 'PASS: v1 monitoring rebuild contract is complete.\n'
