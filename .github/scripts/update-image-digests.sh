#!/usr/bin/env bash
# 훈련 클러스터 하나의 gitops 값 파일에서 ECR 이미지 해시를 바꾼다.
# 사용: update-image-digests.sh <john|wade> <태그 또는 빈 값> <서비스 목록 또는 빈 값>
# 태그가 비면 저장소마다 가장 최근에 푸시된 이미지를 쓴다. 바뀐 내용은 $SUMMARY_FILE에 표로 남긴다.
set -euo pipefail
ENV_NAME=$1
TAG=${2:-}
SERVICES=${3:-}
REGION=ap-northeast-2
DIR="v3-$ENV_NAME/gitops/environments/prod"
SUMMARY_FILE=${SUMMARY_FILE:-/dev/stdout}
[ -d "$DIR" ] || { echo "$DIR 없음" >&2; exit 1; }

echo "| 서비스 | 저장소 | 태그 | 이전 | 새 해시 |" > "$SUMMARY_FILE"
echo "|---|---|---|---|---|" >> "$SUMMARY_FILE"
for f in "$DIR"/*.yaml; do
  svc=$(basename "$f" .yaml)
  if [ -n "$SERVICES" ] && ! grep -qw -- "$svc" <<<"${SERVICES//,/ }"; then continue; fi
  grep -Eq 'image: [0-9]+\.dkr\.ecr\.[^/]+/[^@]+@sha256:' "$f" || continue
  ref=$(grep -Eo '[0-9]+\.dkr\.ecr\.[^/]+/[^@]+@sha256:[0-9a-f]+' "$f" | head -1)
  repo=${ref#*/}; repo=${repo%@*}
  old=${ref#*@}
  if [ -n "$TAG" ]; then
    new=$(aws ecr describe-images --region "$REGION" --repository-name "$repo" --image-ids imageTag="$TAG" \
      --query 'imageDetails[0].imageDigest' --output text 2>/dev/null || true)
    used=$TAG
  else
    read -r new used < <(aws ecr describe-images --region "$REGION" --repository-name "$repo" \
      --query 'reverse(sort_by(imageDetails,&imagePushedAt))[0].[imageDigest,imageTags[0]]' --output text)
  fi
  case "$new" in sha256:*) ;; *) echo "$svc: $repo에 ${TAG:-최근} 이미지 없음, 건너뜀" >&2; continue ;; esac
  [ "$new" = "$old" ] && continue
  sed -i "s|$repo@$old|$repo@$new|" "$f"
  echo "| $svc | \`$repo\` | \`$used\` | \`${old:7:12}\` | \`${new:7:12}\` |" >> "$SUMMARY_FILE"
done
