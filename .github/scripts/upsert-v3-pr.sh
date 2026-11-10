#!/usr/bin/env bash
set -euo pipefail

required=(GH_TOKEN GITHUB_REPOSITORY PROMOTION_BRANCH COMPONENT IMAGE_TAG SOURCE_GITHUB_REPO DIGEST)
for name in "${required[@]}"; do
  [[ -n "${!name:-}" ]] || { printf 'ERROR: missing %s\n' "${name}" >&2; exit 1; }
done

pr_url="$(gh pr list --repo "${GITHUB_REPOSITORY}" --head "${PROMOTION_BRANCH}" --base main --state open --json url --jq '.[0].url // empty')"
if [[ -z "${pr_url}" ]]; then
  pr_url="$(gh pr create \
    --repo "${GITHUB_REPOSITORY}" \
    --base main \
    --head "${PROMOTION_BRANCH}" \
    --title "deploy(v3-john,v3-wade): ${COMPONENT} ${IMAGE_TAG:0:12} promote" \
    --body "Source: ${SOURCE_GITHUB_REPO}@${IMAGE_TAG}; image digest: ${DIGEST}; gates: Trivy passed before push and ECR Basic Scan CRITICAL 0.")"
fi
[[ "${pr_url}" == https://github.com/*/pull/* ]] || { printf 'ERROR: promotion PR URL was not returned\n' >&2; exit 1; }
gh pr merge "${pr_url}" --repo "${GITHUB_REPOSITORY}" --auto --squash
