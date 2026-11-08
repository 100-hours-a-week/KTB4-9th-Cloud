#!/usr/bin/env bash
set -euo pipefail

required=(BASE_MAIN_SHA PROMOTION_BRANCH COMPONENT IMAGE_TAG)
for name in "${required[@]}"; do
  [[ -n "${!name:-}" ]] || { printf 'ERROR: missing %s\n' "${name}" >&2; exit 1; }
done
[[ "${BASE_MAIN_SHA}" =~ ^[0-9a-f]{40}$ ]] || { printf 'ERROR: BASE_MAIN_SHA is invalid\n' >&2; exit 1; }

git fetch origin main
current_main="$(git rev-parse origin/main)"
if [[ "${current_main}" != "${BASE_MAIN_SHA}" ]]; then
  printf 'ERROR: Cloud main changed during promotion; rerun against the new main\n' >&2
  exit 1
fi

git config user.name "cosmos-release[bot]"
git config user.email "cosmos-release[bot]@users.noreply.github.com"
git switch -C "${PROMOTION_BRANCH}"
git add v3/gitops/environments/prod
git commit -m "deploy(v3): ${COMPONENT} ${IMAGE_TAG:0:12} promote"
git push --force-with-lease origin "HEAD:${PROMOTION_BRANCH}"
