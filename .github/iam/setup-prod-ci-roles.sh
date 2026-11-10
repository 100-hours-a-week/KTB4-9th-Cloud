#!/usr/bin/env bash
# BE, AI main-ci가 cosmos-v2 ECR에 이미지를 올릴 때 쓰는 OIDC 역할을 만든다. 여러 번 실행해도 된다.
# 각 저장소의 GitHub 환경 production-ci에 변수 AWS_PROD_CI_ROLE_ARN으로 출력된 ARN을 넣는다.
set -euo pipefail
ACCOUNT=352635536602
REGION=ap-northeast-2
OIDC="arn:aws:iam::$ACCOUNT:oidc-provider/token.actions.githubusercontent.com"

# 역할 이름, GitHub 저장소(조직@ID/저장소@ID), ECR 저장소
setup() {
  local name=$1 repo=$2 ecr=$3
  local trust policy
  trust=$(jq -nc --arg oidc "$OIDC" --arg sub "repo:100-hours-a-week@167328634/$repo:environment:production-ci" '{
    Version:"2012-10-17",
    Statement:[{Effect:"Allow",Principal:{Federated:$oidc},Action:"sts:AssumeRoleWithWebIdentity",
      Condition:{StringEquals:{"token.actions.githubusercontent.com:aud":"sts.amazonaws.com","token.actions.githubusercontent.com:sub":$sub}}}]}')
  # docker build 기본값이 만드는 증명 manifest를 푸시하려면 BatchGetImage가 필요하다.
  policy=$(jq -nc --arg arn "arn:aws:ecr:$REGION:$ACCOUNT:repository/$ecr" '{
    Version:"2012-10-17",
    Statement:[{Effect:"Allow",Action:"ecr:GetAuthorizationToken",Resource:"*"},
      {Effect:"Allow",Action:["ecr:BatchCheckLayerAvailability","ecr:BatchGetImage","ecr:CompleteLayerUpload","ecr:DescribeImages",
        "ecr:InitiateLayerUpload","ecr:PutImage","ecr:UploadLayerPart"],Resource:$arn}]}')
  if aws iam get-role --role-name "$name" >/dev/null 2>&1; then
    aws iam update-assume-role-policy --role-name "$name" --policy-document "$trust"
  else
    aws iam create-role --role-name "$name" --assume-role-policy-document "$trust" \
      --description "GitHub $repo main-ci: push $ecr" >/dev/null
  fi
  aws iam put-role-policy --role-name "$name" --policy-name push-own-ecr-repository --policy-document "$policy"
  echo "$repo → $(aws iam get-role --role-name "$name" --query Role.Arn --output text)"
}

setup cosmos-v3-github-spring-prod-ci  "KTB4-9th-BE@1344700709" cosmos-v2/spring
setup cosmos-v3-github-fastapi-prod-ci "KTB4-9th-AI@1344703221" cosmos-v2/fastapi
