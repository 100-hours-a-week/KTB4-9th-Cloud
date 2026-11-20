#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_file="$(mktemp "${TMPDIR:-/tmp}/ecr-destroy-plan.XXXXXX")"
cleanup() { rm -f -- "$output_file"; }
trap cleanup EXIT

set +e
terraform -chdir="$ROOT/environments/ecr" plan -destroy -input=false -detailed-exitcode >"$output_file" 2>&1
status=$?
set -e

if [[ "$status" -ne 1 ]]; then
  echo "ECR destroy plan must be rejected, got exit code $status" >&2
  tail -n 30 "$output_file" >&2
  exit 1
fi

if ! grep -q 'prevent_destroy' "$output_file"; then
  echo 'ECR destroy rejection must be enforced by prevent_destroy' >&2
  tail -n 30 "$output_file" >&2
  exit 1
fi

echo 'PASS: ECR repositories reject Terraform destroy'
