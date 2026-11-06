#!/usr/bin/env bash
# ECR 스캔 완료 이벤트로 Cloud 저장소 eks-promote를 호출하는 EventBridge 구성을 만든다. 여러 번 실행해도 된다.
# 흐름: cosmos-v2/{spring,fastapi,judge} 푸시 → 기본 스캔 완료(CRITICAL 없음) → API 대상 → GitHub repository_dispatch(promote)
# 실행 중 GitHub 토큰(KTB4-9th-Cloud Contents 쓰기)을 입력받는다. 화면에 표시되지 않는다.
set -euo pipefail
REGION=ap-northeast-2
ACCOUNT=352635536602
NAME=cosmos-ecr-scan-promote
PROMOTE_ROLE=cosmos-v3-ci-promote
REPOS='["cosmos-v2/spring","cosmos-v2/fastapi","cosmos-v2/judge"]'
ecr() { echo "arn:aws:ecr:$REGION:$ACCOUNT:repository/$1"; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# 1. 승격 역할에 judge 저장소 권한을 더한다.
aws iam get-role-policy --role-name "$PROMOTE_ROLE" --policy-name ecr-promote --query PolicyDocument --output json > "$TMP/p.json"
jq --arg src "$(ecr cosmos-v2/judge)" --arg api "$(ecr cosmos-judge-api)" --arg wk "$(ecr cosmos-judge-worker)" '
  .Statement[1].Resource = (.Statement[1].Resource + [$src] | unique) |
  .Statement[2].Resource = (.Statement[2].Resource + [$api, $wk] | unique)' "$TMP/p.json" > "$TMP/p2.json"
aws iam put-role-policy --role-name "$PROMOTE_ROLE" --policy-name ecr-promote --policy-document "file://$TMP/p2.json"
echo "승격 역할 권한 갱신"

# 2. GitHub 연결. 토큰은 EventBridge가 Secrets Manager에 보관한다.
if ! aws events describe-connection --region "$REGION" --name "$NAME" >/dev/null 2>&1; then
  read -rsp "GitHub 토큰: " TOKEN; echo
  jq -n --arg v "Bearer $TOKEN" '{ApiKeyAuthParameters:{ApiKeyName:"Authorization",ApiKeyValue:$v},
    InvocationHttpParameters:{HeaderParameters:[{Key:"Accept",Value:"application/vnd.github+json",IsValueSecret:false},
                                                {Key:"User-Agent",Value:"cosmos-eventbridge",IsValueSecret:false}]}}' > "$TMP/auth.json"
  unset TOKEN
  aws events create-connection --region "$REGION" --name "$NAME" --authorization-type API_KEY \
    --auth-parameters "file://$TMP/auth.json" >/dev/null
  rm -f "$TMP/auth.json"
fi
CONN=$(aws events describe-connection --region "$REGION" --name "$NAME" --query ConnectionArn --output text)
echo "연결: $CONN"

# 3. API 대상
ENDPOINT=https://api.github.com/repos/100-hours-a-week/KTB4-9th-Cloud/dispatches
if aws events describe-api-destination --region "$REGION" --name "$NAME" >/dev/null 2>&1; then
  aws events update-api-destination --region "$REGION" --name "$NAME" --connection-arn "$CONN" \
    --invocation-endpoint "$ENDPOINT" --http-method POST --invocation-rate-limit-per-second 1 >/dev/null
else
  aws events create-api-destination --region "$REGION" --name "$NAME" --connection-arn "$CONN" \
    --invocation-endpoint "$ENDPOINT" --http-method POST --invocation-rate-limit-per-second 1 >/dev/null
fi
DEST=$(aws events describe-api-destination --region "$REGION" --name "$NAME" --query ApiDestinationArn --output text)

# 4. EventBridge가 API 대상을 호출할 역할
if ! aws iam get-role --role-name "$NAME" >/dev/null 2>&1; then
  aws iam create-role --role-name "$NAME" --description "EventBridge: ECR scan -> GitHub eks-promote" \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"events.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
fi
aws iam put-role-policy --role-name "$NAME" --policy-name invoke-api-destination --policy-document \
  "$(jq -nc --arg d "arn:aws:events:$REGION:$ACCOUNT:api-destination/$NAME/*" '{Version:"2012-10-17",Statement:[{Effect:"Allow",Action:"events:InvokeApiDestination",Resource:$d}]}')"
ROLE_ARN=$(aws iam get-role --role-name "$NAME" --query Role.Arn --output text)

# 5. 규칙: 스캔 완료이고 CRITICAL 건수가 없을 때만. ECR은 0건인 심각도를 생략한다.
PATTERN=$(jq -nc --argjson r "$REPOS" '{source:["aws.ecr"],"detail-type":["ECR Image Scan"],
  detail:{"scan-status":["COMPLETE"],"repository-name":$r,"finding-severity-counts":{CRITICAL:[{exists:false}]}}}')
aws events put-rule --region "$REGION" --name "$NAME" --event-pattern "$PATTERN" \
  --description "cosmos-v2 이미지 스캔 통과 시 eks-promote 호출" >/dev/null
TARGET=$(jq -nc --arg d "$DEST" --arg role "$ROLE_ARN" '[{Id:"github",Arn:$d,RoleArn:$role,
  InputTransformer:{InputPathsMap:{repo:"$.detail.repository-name",tag:"$.detail.image-tags[0]"},
    InputTemplate:"{\"event_type\":\"promote\",\"client_payload\":{\"repository\":\"<repo>\",\"image_tag\":\"<tag>\"}}"},
  RetryPolicy:{MaximumRetryAttempts:3,MaximumEventAgeInSeconds:3600}}]')
aws events put-targets --region "$REGION" --rule "$NAME" --targets "$TARGET" >/dev/null
echo "완료: 규칙 $NAME"
