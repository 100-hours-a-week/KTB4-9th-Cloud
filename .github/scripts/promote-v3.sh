#!/usr/bin/env bash
set -euo pipefail

required=(COMPONENT SOURCE_REPO IMAGE_TAG SOURCE_GITHUB_REPO AWS_REGION REGISTRY GH_TOKEN)
for name in "${required[@]}"; do
  [[ -n "${!name:-}" ]] || { printf 'ERROR: missing %s\n' "${name}" >&2; exit 1; }
done
[[ "${IMAGE_TAG}" =~ ^[0-9a-f]{40}$ ]] || { printf 'ERROR: IMAGE_TAG must be a 40-character lowercase Git SHA\n' >&2; exit 1; }

case "${COMPONENT}|${SOURCE_REPO}|${SOURCE_GITHUB_REPO}" in
  spring\|cosmos-v2/spring\|100-hours-a-week/KTB4-9th-BE)
    targets="auth:cosmos-auth core:cosmos-core battle:cosmos-battle"
    ;;
  fastapi\|cosmos-v2/fastapi\|100-hours-a-week/KTB4-9th-AI)
    targets="ai-llm:cosmos-ai-llm ai-make-problem:cosmos-ai-make-problem ai-problem-batch:cosmos-ai-problem-batch ai-migrate:cosmos-ai-make-problem"
    ;;
  judge\|cosmos-v2/judge\|100-hours-a-week/KTB4-9th-Judge)
    # api와 worker는 같은 이미지를 명령만 달리해 쓴다. 장애 주입 실험 대상인 v3-john에만 올린다.
    targets="judge-api:cosmos-judge-api judge-worker:cosmos-judge-worker"
    default_clusters="v3-john"
    ;;
  *)
    printf 'ERROR: component, ECR repository, and GitHub repository tuple is not allowed\n' >&2
    exit 1
    ;;
esac

root="${GITOPS_ROOT:-${GITHUB_WORKSPACE:-$(pwd)}}"
# 승격 대상 훈련 클러스터. 두 클러스터의 값 파일을 함께 바꾼다.
clusters="${PROMOTE_CLUSTERS:-${default_clusters:-v3-john v3-wade}}"
values_files=()
for cluster in ${clusters}; do
  for target in ${targets}; do
    file="${root}/${cluster}/gitops/environments/prod/${target%%:*}.yaml"
    [[ -f "${file}" ]] || { printf 'ERROR: missing values file %s\n' "${file}" >&2; exit 1; }
    values_files+=("${file}")
  done
done

main_status="$(gh api "repos/${SOURCE_GITHUB_REPO}/compare/${IMAGE_TAG}...main" --jq .status)"
case "${main_status}" in
  ahead|identical) ;;
  *) printf 'ERROR: candidate revision is not contained in source main\n' >&2; exit 1 ;;
esac

main_revision=""
for file in "${values_files[@]}"; do
  revision="$(awk '$1 == "sourceRevision:" { gsub(/"/, "", $2); print $2; exit }' "${file}")"
  if [[ -z "${main_revision}" ]]; then
    main_revision="${revision}"
  elif [[ "${revision}" != "${main_revision}" ]]; then
    printf 'ERROR: component values have inconsistent sourceRevision values\n' >&2
    exit 1
  fi
done

for current in "${main_revision}" "${CURRENT_REVISION_OVERRIDE:-}"; do
  [[ -n "${current}" ]] || continue
  [[ "${current}" =~ ^[0-9a-f]{40}$ ]] || { printf 'ERROR: current sourceRevision is invalid\n' >&2; exit 1; }
  order="$(gh api "repos/${SOURCE_GITHUB_REPO}/compare/${current}...${IMAGE_TAG}" --jq .status)"
  case "${order}" in
    ahead|identical) ;;
    behind|diverged)
      printf 'Skipping stale promotion %s; current candidate is %s\n' "${IMAGE_TAG}" "${current}"
      [[ -n "${GITHUB_OUTPUT:-}" ]] && printf 'stale=true\n' >>"${GITHUB_OUTPUT}"
      exit 0
      ;;
    *) printf 'ERROR: unsupported GitHub comparison status: %s\n' "${order}" >&2; exit 1 ;;
  esac
done

aws ecr wait image-scan-complete --repository-name "${SOURCE_REPO}" --image-id "imageTag=${IMAGE_TAG}" --region "${AWS_REGION}"
critical="$(aws ecr describe-image-scan-findings --repository-name "${SOURCE_REPO}" --image-id "imageTag=${IMAGE_TAG}" --region "${AWS_REGION}" --query 'imageScanFindings.findingSeverityCounts.CRITICAL || `0`' --output text)"
[[ "${critical}" =~ ^[0-9]+$ ]] || { printf 'ERROR: ECR scan did not return a CRITICAL count\n' >&2; exit 1; }
(( critical == 0 )) || { printf 'ERROR: ECR Basic Scan found %s CRITICAL vulnerabilities\n' "${critical}" >&2; exit 1; }

digest="$(aws ecr describe-images --repository-name "${SOURCE_REPO}" --image-ids "imageTag=${IMAGE_TAG}" --region "${AWS_REGION}" --query 'imageDetails[0].imageDigest' --output text)"
[[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]] || { printf 'ERROR: source digest was not found\n' >&2; exit 1; }

copied=" "
for target in ${targets}; do
  file="${target%%:*}"
  repository="${target##*:}"
  # 서비스 저장소는 태그 덮어쓰기 금지라 같은 저장소는 한 번만 복사한다.
  if [[ "${copied}" != *" ${repository} "* ]]; then
    docker buildx imagetools create \
      -t "${REGISTRY}/${repository}:${IMAGE_TAG}" \
      -t "${REGISTRY}/${repository}:prod-${digest:7:12}" \
      "${REGISTRY}/${SOURCE_REPO}@${digest}"
    copied+="${repository} "
  fi
  for cluster in ${clusters}; do
    ruby - "${root}/${cluster}/gitops/environments/prod/${file}.yaml" "${REGISTRY}/${repository}@${digest}" "${IMAGE_TAG}" <<'RUBY'
path, image, revision = ARGV
text = File.read(path, encoding: "UTF-8")
abort("missing image field in #{path}") unless text.sub!(/^image: .*$/, "image: #{image}")
abort("missing sourceRevision field in #{path}") unless text.sub!(/^sourceRevision: .*$/, "sourceRevision: #{revision}")
File.write(path, text)
RUBY
  done
done

[[ -n "${GITHUB_OUTPUT:-}" ]] && {
  printf 'stale=false\n' >>"${GITHUB_OUTPUT}"
  printf 'digest=%s\n' "${digest}" >>"${GITHUB_OUTPUT}"
}
printf 'Prepared %s promotion at %s\n' "${COMPONENT}" "${digest}"
