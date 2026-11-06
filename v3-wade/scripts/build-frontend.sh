#!/usr/bin/env bash
# FE 저장소 stage 브랜치를 이 클러스터 주소로 빌드해 올린다. 운영 빌드에는 운영 API 주소가 들어 있어 쓰면 안 된다.
source "$(dirname "$0")/common.sh"
FE_REPO="${FE_REPO:-$BASE/../../KTB4-9th-FE}"
DOMAIN="https://$ENV_NAME.cosmoscode.site"
WORK=$(mktemp -d)
git -C "$FE_REPO" fetch -q origin stage
git -C "$FE_REPO" worktree add -q --detach "$WORK" origin/stage
trap 'git -C "$FE_REPO" worktree remove --force "$WORK"' EXIT
export VITE_API_BASE_URL="$DOMAIN/api" VITE_KAKAO_REDIRECT_URI="$DOMAIN/api/auth/oauth/kakao/callback"
VITE_KAKAO_REST_API_KEY=$(secret_key /cosmos-v2/stage/spring kakao_client_id); export VITE_KAKAO_REST_API_KEY
(cd "$WORK" && npm ci --silent && npm run build --silent)
# 빌드 결과에 운영 주소가 남아 있으면 올리지 않는다.
if grep -rqE 'https://(www\.)?cosmoscode\.site/api' "$WORK/dist"; then echo "운영 API 주소가 남아 있어 중단"; exit 1; fi
aws s3 sync "$WORK/dist/" "s3://$(tf output -raw edge_bucket)/" --delete --only-show-errors
aws cloudfront create-invalidation --distribution-id "$(tf output -raw edge_distribution_id)" --paths '/*' >/dev/null
echo "프런트엔드 배포 완료: $DOMAIN"
