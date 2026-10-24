#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
monitoring_root="${repo_root}/v2/monitoring"
compose_file="${monitoring_root}/docker-compose.yml"
prometheus_config="${monitoring_root}/prometheus/prometheus.yml"
loki_config="${monitoring_root}/loki/loki.yml"
caddy_config="${monitoring_root}/caddy/Caddyfile"
bootstrap_template="${repo_root}/v2/modules/shared/templates/monitoring-user-data.sh.tftpl"
monitoring_terraform="${repo_root}/v2/modules/shared/monitoring.tf"
datasource_config="${monitoring_root}/grafana/provisioning/datasources/datasources.yml"
dashboard_provider_config="${monitoring_root}/grafana/provisioning/dashboards/providers.yml"
dashboard_root="${monitoring_root}/grafana/dashboards"
ecs_dashboard="${dashboard_root}/v2-ecs-overview.json"
jvm_dashboard="${dashboard_root}/v2-spring-jvm.json"
self_dashboard="${dashboard_root}/monitoring-self-health.json"
redis_dashboard="${dashboard_root}/v2-judge-redis.json"
log_forwarder="${repo_root}/v2/modules/environment/lambda/cloudwatch_to_loki.py"
log_forwarding_terraform="${repo_root}/v2/modules/environment/log-forwarding.tf"
stateful_terraform="${repo_root}/v2/modules/environment/judge-stateful-services.tf"
application_security="${repo_root}/v2/modules/environment/application-security.tf"
application_tasks="${repo_root}/v2/modules/environment/ecs-task-definitions.tf"
application_alb="${repo_root}/v2/modules/environment/alb.tf"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_file() {
  [[ -f "$1" ]] || fail "필수 파일이 없습니다: ${1#"${repo_root}/"}"
}

assert_contains() {
  local file="$1"
  local text="$2"
  rg -q --fixed-strings -- "$text" "$file" || fail "${file#"${repo_root}/"}에 필수 설정이 없습니다: ${text}"
}

for file in \
  "$compose_file" \
  "$prometheus_config" \
  "$loki_config" \
  "$caddy_config" \
  "$monitoring_terraform" \
  "${monitoring_root}/grafana/grafana.ini" \
  "${monitoring_root}/grafana/provisioning/datasources/datasources.yml" \
  "$dashboard_provider_config" \
  "$bootstrap_template" \
  "$redis_dashboard" \
  "$log_forwarder" \
  "$log_forwarding_terraform"; do
  assert_file "$file"
done

for image in \
  'grafana/grafana:13.2.4' \
  'prom/prometheus:v3.14.0' \
  'grafana/loki:3.7.8' \
  'caddy:2.11.7' \
  'prom/node-exporter:v1.12.1'; do
  assert_contains "$compose_file" "$image"
done

if rg -ni 'alertmanager' "$monitoring_root"; then
  fail "초기 런타임에 Alertmanager가 포함되면 안 됩니다."
fi

assert_contains "$compose_file" '"80:80"'
assert_contains "$compose_file" '"443:443"'

if rg -n '"(3000|9090):(3000|9090)"' "$compose_file"; then
  fail "Grafana와 Prometheus 내부 포트를 host에 공개하면 안 됩니다."
fi

assert_contains "$compose_file" '${GRAFANA_ADMIN_PASSWORD}'
assert_contains "$compose_file" '/api/health'
assert_contains "$compose_file" '/-/ready'
assert_contains "$compose_file" '/ready'
assert_contains "$compose_file" '["CMD", "/usr/bin/loki", "-config.file=/etc/loki/loki.yml", "-verify-config=true"]'
assert_contains "$compose_file" '--storage.tsdb.retention.time=15d'
assert_contains "$loki_config" 'retention_period: 336h'
assert_contains "$caddy_config" '{$MONITORING_HOSTNAME}'
assert_contains "$caddy_config" 'reverse_proxy grafana:3000'

assert_contains "$bootstrap_template" 'blkid'
assert_contains "$bootstrap_template" 'mkfs.ext4'
assert_contains "$bootstrap_template" 'mktemp -d'
assert_contains "$bootstrap_template" 'https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip'
assert_contains "$bootstrap_template" '/tmp/awscliv2/aws/install'
assert_contains "$bootstrap_template" 'aws s3 sync'
assert_contains "$bootstrap_template" 'diff -qr'
assert_contains "$bootstrap_template" 'secretsmanager get-secret-value'
assert_contains "$bootstrap_template" 'up -d --remove-orphans --force-recreate'
assert_contains "$compose_file" 'http://prometheus:9090/-/reload'
assert_contains "$bootstrap_template" 'monitoring-config-refresh.timer'

monitoring_instance_block="$(sed -n '/resource "aws_instance" "monitoring" {/,/resource "aws_eip" "monitoring" {/p' "$monitoring_terraform")"
[[ "$monitoring_instance_block" == *'aws_s3_object.monitoring_config'* ]] ||
  fail "Monitoring EC2는 S3 설정 객체 업로드 완료 후 생성되어야 합니다."
[[ "$monitoring_instance_block" == *'aws_secretsmanager_secret_version.monitoring_grafana_admin'* ]] ||
  fail "Monitoring EC2는 Grafana secret version 생성 완료 후 생성되어야 합니다."
[[ "$monitoring_instance_block" == *'aws_iam_role_policy_attachment.monitoring_ssm'* ]] ||
  fail "Monitoring EC2는 SSM managed policy 연결 완료 후 생성되어야 합니다."
[[ "$monitoring_instance_block" == *'aws_iam_role_policy.monitoring_read'* ]] ||
  fail "Monitoring EC2는 runtime read policy 생성 완료 후 생성되어야 합니다."
[[ "$monitoring_instance_block" == *'ignore_changes = [user_data]'* ]] ||
  fail "Monitoring bootstrap 변경이 기존 EC2를 교체하면 안 됩니다."

if rg -n 'apt-get install[^\n]*awscli' "$bootstrap_template"; then
  fail "Ubuntu 24.04에서 제공되지 않는 awscli apt package를 사용하면 안 됩니다."
fi

assert_contains "$prometheus_config" 'aws_sd_configs:'
assert_contains "$prometheus_config" 'role: ecs'
assert_contains "$prometheus_config" 'region: ap-northeast-2'
assert_contains "$prometheus_config" 'cosmos-v2-.*-cluster'
assert_contains "$prometheus_config" '/actuator/prometheus'
assert_contains "$prometheus_config" 'replacement: $1:9091'
assert_contains "$prometheus_config" '__meta_ecs_desired_status'
assert_contains "$prometheus_config" '__meta_ecs_last_status'
assert_contains "$prometheus_config" '__meta_ecs_health_status'
assert_contains "$prometheus_config" 'regex: HEALTHY|UNKNOWN'
assert_contains "$prometheus_config" 'job_name: judge-redis'
assert_contains "$prometheus_config" 'regex: cosmos-v2-.*-judge-postgres'
assert_contains "$prometheus_config" 'replacement: $1:9121'

if rg -ni 'job_name:.*(fastapi|judge-api|judge-worker)' "$prometheus_config"; then
  fail "계측 endpoint가 준비되기 전 FastAPI/Judge API/Worker scrape job을 활성화하면 안 됩니다."
fi

assert_contains "$stateful_terraform" 'oliver006/redis_exporter:v1.93.0'
assert_contains "$stateful_terraform" 'REDIS_EXPORTER_CHECK_SINGLE_KEYS'
assert_contains "$stateful_terraform" 'stage:judge0:queue:1.13.1'
assert_contains "$stateful_terraform" 'containerPort = 9121'
assert_contains "$application_security" 'judge_redis_exporter_from_monitoring'
assert_contains "$application_security" 'from_port                    = 9121'
assert_contains "$application_tasks" 'MANAGEMENT_SERVER_PORT'
assert_contains "$application_security" 'spring_management_from_alb'
assert_contains "$application_alb" 'path                = "/actuator/health"'
assert_contains "$application_alb" 'port                = "9091"'
if rg -q 'name = "MANAGEMENT_PORT"' "$application_tasks"; then
  fail "Spring 관리 포트는 인식되지 않는 MANAGEMENT_PORT 환경변수를 사용하면 안 됩니다."
fi

assert_contains "$compose_file" '"3100:3100"'
assert_contains "$log_forwarding_terraform" 'aws_cloudwatch_log_subscription_filter'
assert_contains "$log_forwarding_terraform" 'aws_lambda_permission'
assert_contains "$log_forwarding_terraform" 'monitoring_private_ip'
assert_contains "$log_forwarder" 'CWL_TO_LOKI'
assert_contains "$log_forwarder" '/loki/api/v1/push'

if rg -n 'target_label:[[:space:]]*(task_arn|url|raw_url)' "$prometheus_config"; then
  fail "task ARN 또는 raw URL처럼 cardinality가 높은 값을 metric label로 사용하면 안 됩니다."
fi

for datasource_uid in cloudwatch-v2 prometheus-v2 loki-v2; do
  assert_contains "$datasource_config" "uid: ${datasource_uid}"
done

actual_datasource_uids="$(sed -n 's/^[[:space:]]*uid: //p' "$datasource_config" | sort)"
expected_datasource_uids="$(printf '%s\n' cloudwatch-v2 loki-v2 prometheus-v2)"
[[ "$actual_datasource_uids" == "$expected_datasource_uids" ]] ||
  fail "v2 Grafana에는 v2 전용 CloudWatch, Prometheus, Loki datasource만 있어야 합니다."

assert_contains "$dashboard_provider_config" 'name: COSMOS v2'
assert_contains "$dashboard_provider_config" 'folder: COSMOS v2'
assert_contains "$dashboard_provider_config" 'foldersFromFilesStructure: false'
assert_contains "$datasource_config" 'authType: default'
assert_contains "$datasource_config" 'defaultRegion: ap-northeast-2'
assert_contains "$datasource_config" 'url: http://prometheus:9090'
assert_contains "$datasource_config" 'url: http://loki:3100'

if rg -ni '(accessKey|secretKey)' "$datasource_config"; then
  fail "Grafana datasource에 정적 AWS access key를 넣으면 안 됩니다."
fi

for dashboard in "$ecs_dashboard" "$jvm_dashboard" "$self_dashboard" "$redis_dashboard"; do
  assert_file "$dashboard"
  jq -e . "$dashboard" >/dev/null || fail "유효하지 않은 dashboard JSON입니다: ${dashboard#"${repo_root}/"}"
  jq -e '[.. | objects | .datasource? | select(type == "object") | .uid? | select(. != null)] | all(. == "cloudwatch-v2" or . == "prometheus-v2" or . == "loki-v2")' "$dashboard" >/dev/null ||
    fail "dashboard가 provisioning되지 않은 datasource UID를 참조합니다: ${dashboard#"${repo_root}/"}"
done

jq -e '.uid == "v2-judge-redis" and ([.panels[].title] | index("Judge Queue Depth") != null)' "$redis_dashboard" >/dev/null ||
  fail "Judge Redis dashboard UID 또는 queue panel이 올바르지 않습니다."

for service in spring fastapi judge-api judge-worker judge-redis judge-postgres ai-postgres mlflow; do
  log_dashboard="${dashboard_root}/v2-logs-${service}.json"
  assert_file "$log_dashboard"
  jq -e . "$log_dashboard" >/dev/null || fail "유효하지 않은 log dashboard JSON입니다: ${log_dashboard#"${repo_root}/"}"
  jq -e --arg app "$service" '
    .uid == ("v2-logs-" + $app) and
    ([.. | objects | .expr? | select(type == "string")] | any(contains("application=\"" + $app + "\"")))
  ' "$log_dashboard" >/dev/null || fail "${service} 로그 dashboard가 application label을 고정하지 않았습니다."
done

jq -e '
  .uid == "v2-ecs-overview" and
  ([.panels[] | select(.title as $title | ["Spring", "FastAPI", "Judge API", "MLflow", "Judge Worker", "Judge Redis", "Judge DB", "AI PostgreSQL"] | index($title))] |
    length == 8 and
    all(
      .type == "stat" and .gridPos.w == 6 and .gridPos.h >= 5 and
      .options.graphMode == "none" and .options.colorMode == "value" and
      (.targets | length == 4) and
      ([.targets[].metricName] | sort == (["CPUUtilization", "DesiredTaskCount", "MemoryUtilization", "RunningTaskCount"] | sort)) and
      ([.targets[].dimensions.ServiceName] | unique | length == 1) and
      ([.targets[].dimensions.ClusterName] | unique == ["cosmos-v2-stage-cluster"])
    )
  )
' "$ecs_dashboard" >/dev/null ||
  fail "ECS dashboard는 8개 서비스별 Running/Desired/CPU/Memory 숫자 카드로 구성해야 합니다."
jq -e '
  [.. | objects | select(.datasource?.uid == "cloudwatch-v2" and .metricName? != null)] |
  length > 0 and all(.metricQueryType == 0 and .metricEditorMode == 0)
' "$ecs_dashboard" >/dev/null ||
  fail "모든 CloudWatch metric query는 Grafana 브라우저가 실행할 query/editor type을 명시해야 합니다."
jq -e '.uid == "v2-spring-jvm" and ([.templating.list[].name] | index("environment") != null) and ([.templating.list[].name] | index("service") != null)' "$jvm_dashboard" >/dev/null ||
  fail "Spring JVM dashboard UID 또는 environment/service 변수가 올바르지 않습니다."
jq -e '.uid == "monitoring-self-health"' "$self_dashboard" >/dev/null ||
  fail "Self-health dashboard UID가 올바르지 않습니다."

for title in 'Spring' 'FastAPI' 'Judge API' 'MLflow' 'Judge Worker' 'Judge Redis' 'Judge DB' 'AI PostgreSQL' 'Total HTTP RPS' 'Battle RPS' 'HTTP Error RPS' 'ALB Response Time'; do
  jq -e --arg title "$title" '[.panels[].title] | index($title) != null' "$ecs_dashboard" >/dev/null ||
    fail "ECS dashboard panel이 없습니다: ${title}"
done

jq -e '
  [.panels[] | select(.title as $title | ["Spring", "FastAPI", "Judge API", "MLflow", "Judge Worker", "Judge Redis", "Judge DB", "AI PostgreSQL"] | index($title))] |
  all(
    ([.fieldConfig.overrides[].matcher.options] | index("CPU") != null and index("Memory") != null and index("Running") != null) and
    ([.fieldConfig.overrides[] | select(.matcher.options == "CPU" or .matcher.options == "Memory") | .properties[] | select(.id == "unit").value] | unique == ["percent"])
  )
' "$ecs_dashboard" >/dev/null ||
  fail "서비스 상태 카드의 CPU/Memory는 퍼센트 숫자이고 Running 상태는 색상으로 구분해야 합니다."
jq -e '
  ([.panels[] | select(.title == "Battle RPS") | .targets[].expr] | any(contains("/daily-battles/.+/participations"))) and
  ([.panels[] | select(.title == "Battle RPS") | .targets[].expr] | any(contains("/daily-battles/.+/submissions"))) and
  ([.panels[] | select(.title == "Total HTTP RPS") | .targets[].expr] | any(contains("http_server_requests_seconds_count"))) and
  ([.panels[] | select(.title == "HTTP Error RPS") | .targets[].expr] | any(contains("status=~\"4..|5..\""))) and
  ([.panels[] | select(.title == "Total HTTP RPS" or .title == "Battle RPS" or .title == "HTTP Error RPS") | .targets[].expr] | all(contains("or vector(0)")))
' "$ecs_dashboard" >/dev/null ||
  fail "전체/Battle RPS와 HTTP Error RPS 쿼리가 올바르지 않습니다."
if jq -e '[.panels[].title] | any(. == "Running Tasks (Availability)" or . == "Desired Tasks" or contains("Utilization") or . == "ALB Requests" or . == "Target 5xx")' "$ecs_dashboard" >/dev/null; then
  fail "숫자 카드와 핵심 추이 그래프 외의 기존 대형 요약 패널은 제거해야 합니다."
fi

for metric in jvm_memory_used_bytes jvm_gc_pause_seconds jvm_threads_live_threads process_cpu_usage hikaricp_connections_active; do
  jq -e --arg metric "$metric" '[.. | objects | .expr? | select(type == "string")] | any(contains($metric))' "$jvm_dashboard" >/dev/null ||
    fail "Spring JVM dashboard metric이 없습니다: ${metric}"
done

for title in 'HTTP RPS by Route' 'HTTP p95 Latency by Route' 'HTTP 5xx Error Ratio'; do
  jq -e --arg title "$title" '[.panels[].title] | index($title) != null' "$jvm_dashboard" >/dev/null ||
    fail "Spring RED dashboard panel이 없습니다: ${title}"
done

printf 'PASS: PLG/Caddy 버전, 공개 포트, 보존기간, bootstrap 안전 계약이 일치합니다.\n'
