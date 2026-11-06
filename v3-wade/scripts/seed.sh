#!/usr/bin/env bash
# 오레곤 운영 서버의 데이터를 S3에 고정한다. v3-john, v3-wade의 up.sh가 이 결과를 함께 쓴다.
# RDS는 서울 최종 스냅샷으로 만들고, 그 위에 오레곤 MySQL 덤프를 덮어쓴다.
# 사용: SSH_KEY=<cosmos1-key-pair.pem 경로> ./seed.sh
set -euo pipefail
REGION=ap-northeast-2
SOURCE_REGION=us-west-2
BUCKET=cosmos-db-backup-352635536602
BASE_SNAPSHOT=cosmos-v2-mysql-final-20261106
: "${SSH_KEY:?SSH_KEY에 cosmos1-key-pair.pem 경로를 지정한다}"

ip() { aws ec2 describe-instances --region "$SOURCE_REGION" --filters "Name=tag:Name,Values=$1" Name=instance-state-name,Values=running --query 'Reservations[0].Instances[0].PublicIpAddress' --output text; }
MAIN=$(ip COSMOS-test-main-server)
JUDGER=$(ip COSMOS-test-judger-instance)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# $1 이름, $2 호스트, $3 덤프 명령, $4 덤프가 끝까지 됐는지 확인할 문구
dump() {
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new "ubuntu@$2" "$3" | gzip > "$TMP/$1.sql.gz"
  gunzip -c "$TMP/$1.sql.gz" | tail -n 5 | grep -q "$4" || { echo "$1 덤프 실패"; exit 1; }
  aws s3 cp --quiet "$TMP/$1.sql.gz" "s3://$BUCKET/eks-seed/$1.sql.gz"
  echo "$1 덤프 완료"
}
dump mysql "$MAIN" 'docker exec cosmos-mysql sh -c "MYSQL_PWD=\$MYSQL_ROOT_PASSWORD mysqldump -uroot --single-transaction --routines --triggers --no-tablespaces --set-gtid-purged=OFF \$MYSQL_DATABASE"' "Dump completed"
dump ai "$MAIN" 'docker exec cosmos-ai-postgres sh -c "pg_dumpall -U \$POSTGRES_USER --clean --if-exists"' "database cluster dump complete"
dump judge "$JUDGER" 'docker exec judge-db-1 sh -c "pg_dumpall -U \$POSTGRES_USER --clean --if-exists"' "database cluster dump complete"

aws rds describe-db-snapshots --region "$REGION" --db-snapshot-identifier "$BASE_SNAPSHOT" --query 'DBSnapshots[0].Status' --output text | grep -qx available
printf %s "$BASE_SNAPSHOT" | aws s3 cp - "s3://$BUCKET/eks-seed/snapshot-id"
echo "시드 완료: $BASE_SNAPSHOT + 오레곤 덤프"
