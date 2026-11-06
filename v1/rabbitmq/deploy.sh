#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
compose_file="${script_dir}/docker-compose.yml"
env_file="${1:-${script_dir}/.env}"

die() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

[[ -f "${env_file}" ]] || die "environment file not found: ${env_file}"
command -v docker >/dev/null 2>&1 || die "docker is not installed"
docker compose version >/dev/null 2>&1 || die "Docker Compose plugin is not available"

compose() {
  env \
    -u RABBITMQ_DEFAULT_USER \
    -u RABBITMQ_DEFAULT_PASS \
    -u RABBITMQ_DEFAULT_VHOST \
    docker compose -f "${compose_file}" --env-file "${env_file}" "$@"
}

if permissions="$(stat -c '%a' "${env_file}" 2>/dev/null)"; then
  :
else
  permissions="$(stat -f '%Lp' "${env_file}" 2>/dev/null)" || die "cannot read environment file permissions"
fi
[[ "${permissions}" == "600" ]] || die "environment file must have mode 0600 (current: ${permissions})"

read_env_value() {
  local key="$1"
  local line
  line="$(grep -E "^${key}=" "${env_file}" | tail -n 1 || true)"
  printf '%s' "${line#*=}"
}

for key in RABBITMQ_DEFAULT_USER RABBITMQ_DEFAULT_PASS RABBITMQ_DEFAULT_VHOST; do
  value="$(read_env_value "${key}")"
  if [[ ! "${value}" =~ ^[A-Za-z0-9._~:/@%+-]+$ ]]; then
    die "${key} must use only safe characters: letters, digits, . _ ~ : / @ % + -"
  fi
  case "${value}" in
    "" | CHANGE_ME | change_me | REPLACE_ME | replace_me | TODO | todo)
      die "${key} is empty or contains a placeholder"
      ;;
  esac
done

if ! compose config --quiet >/dev/null 2>&1; then
  die "Docker Compose configuration is invalid; check docker-compose.yml and .env formatting"
fi
compose up -d --remove-orphans
"${script_dir}/verify.sh" "${env_file}"
