#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
compose_file="${script_dir}/docker-compose.yml"
env_file="${1:-${script_dir}/.env}"
max_attempts="${RABBITMQ_VERIFY_ATTEMPTS:-12}"

die() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

[[ -f "${env_file}" ]] || die "environment file not found: ${env_file}"
command -v docker >/dev/null 2>&1 || die "docker is not installed"

compose() {
  env \
    -u RABBITMQ_DEFAULT_USER \
    -u RABBITMQ_DEFAULT_PASS \
    -u RABBITMQ_DEFAULT_VHOST \
    docker compose -f "${compose_file}" --env-file "${env_file}" "$@"
}

container_id="$(compose ps -q rabbitmq)"
[[ -n "${container_id}" ]] || die "RabbitMQ container is not running"

attempt=1
while ((attempt <= max_attempts)); do
  health="$(docker inspect --format '{{.State.Health.Status}}' "${container_id}" 2>/dev/null || true)"
  case "${health}" in
    healthy)
      break
      ;;
    unhealthy)
      die "RabbitMQ container is unhealthy; inspect logs with: docker compose -f ${compose_file} --env-file ${env_file} logs rabbitmq"
      ;;
    starting)
      if ((attempt == max_attempts)); then
        die "RabbitMQ healthcheck timed out after ${max_attempts} attempts"
      fi
      sleep 5
      ;;
    *)
      die "RabbitMQ health status is unavailable: ${health:-unknown}"
      ;;
  esac
  ((attempt += 1))
done

docker exec "${container_id}" rabbitmq-diagnostics -q ping >/dev/null || die "RabbitMQ diagnostics ping failed"
listeners="$(docker exec "${container_id}" rabbitmq-diagnostics -q listeners)" || die "RabbitMQ listener query failed"
grep -Eq 'port:? 5672|port: 5672' <<<"${listeners}" || die "RabbitMQ AMQP listener on port 5672 is missing"

printf 'RabbitMQ is healthy and listening for AMQP on the cosmos-dev Docker network.\n'
