# S3b 공통: RDS 삭제와 복원(설계서 9.3). 복구에 20분 넘게 걸려 run-experiment.sh(주입 최대 10분) 대신 run.sh가 시각을 남긴다.
# 시각은 $RECORD_DIR/s3b-events에 "유닉스초 설명" 한 줄씩 남는다.
S3B_REGION=ap-northeast-2
S3B_DB=cosmos-v3-john-mysql
S3B_V3=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)   # v3-john
S3B_URL=${S3B_URL:-https://john.cosmoscode.site/api/auth/me}
s3b_event() { echo "$(date +%s) $*" | tee -a "${RECORD_DIR:?}/s3b-events"; }
s3b_status() { aws rds describe-db-instances --region "$S3B_REGION" --db-instance-identifier "$S3B_DB" --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || echo absent; }
# 시드 이후 데이터 표식: prepare.sh가 만든 테스트 사용자로 /auth/me를 부른다. 200이면 그 사용자가 DB에 있다.
# 401·404면 사용자 행이 없다(시드 이후 데이터 손실). 5xx나 000이면 서비스가 아직 안 된다.
s3b_probe() {
  local tok; tok=$(jq -r '.[0]' "${OUT:-${TMPDIR:-/tmp}/cosmos-loadtest}/tokens.json")
  printf 'header = "Cookie: accessToken=%s"\n' "$tok" | curl -s -o /dev/null -w '%{http_code}' --max-time 10 -K - "$S3B_URL"
}
# Spring 3개를 다시 띄운다(새 DB 엔드포인트·연결 풀). core는 Argo Rollouts가 관리한다.
s3b_restart_spring() {
  kubectl rollout restart deployment/cosmos-auth deployment/cosmos-battle -n prod >/dev/null
  kubectl patch rollout cosmos-core -n prod --type merge -p "{\"spec\":{\"restartAt\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}}" >/dev/null
  kubectl rollout status deployment/cosmos-auth -n prod --timeout=600s >/dev/null
  kubectl rollout status deployment/cosmos-battle -n prod --timeout=600s >/dev/null
  for _ in $(seq 1 60); do [ "$(kubectl get rollout cosmos-core -n prod -o jsonpath='{.status.phase}')" = Healthy ] && break; sleep 10; done
}
