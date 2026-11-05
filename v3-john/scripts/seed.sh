#!/usr/bin/env bash
# 운영 데이터를 한 번 고정한다. 운영이 멈춘 뒤 실행하면 최종 데이터가 된다.
# v3-john, v3-wade의 up.sh가 이 결과를 함께 쓴다.
set -euo pipefail
REGION=ap-northeast-2
BUCKET=cosmos-db-backup-352635536602
SOURCE_DB=cosmos-v2-stage-mysql
SOURCE_FRONTEND=cosmos-v2-stage-frontend-352635536602
HOST_TAG=cosmos-v2-stage-stateful
ID="cosmos-eks-seed-$(date +%Y%m%d-%H%M)"
# 원본 EC2에 S3 권한이 없어 서명된 업로드 주소를 쓴다.
DEPS=$(mktemp -d)
python3 -m pip install -q --target "$DEPS" boto3

aws rds create-db-snapshot --region "$REGION" --db-instance-identifier "$SOURCE_DB" --db-snapshot-identifier "$ID" >/dev/null
aws rds wait db-snapshot-available --region "$REGION" --db-snapshot-identifier "$ID"

INSTANCE=$(aws ec2 describe-instances --region "$REGION" --filters "Name=tag:Name,Values=$HOST_TAG" Name=instance-state-name,Values=running --query 'Reservations[0].Instances[0].InstanceId' --output text)
for db in ai judge; do
  put=$(PYTHONPATH="$DEPS" python3 -c 'import boto3,sys;from botocore.config import Config;print(boto3.client("s3",region_name=sys.argv[1],config=Config(signature_version="s3v4")).generate_presigned_url("put_object",Params={"Bucket":sys.argv[2],"Key":sys.argv[3]},ExpiresIn=3600))' "$REGION" "$BUCKET" "eks-seed/$db.sql.gz")
  params=$(python3 -c 'import json,sys;print(json.dumps({"commands":[
    "set -e -o pipefail",
    f"c=$(docker ps --format {{{{.Names}}}} | grep -E -- -{sys.argv[1]}-postgres-[0-9a-f]+$)",
    "u=$(docker exec $c sh -c \"echo \\$POSTGRES_USER\")",
    "test -n \"$u\"",
    f"docker exec $c pg_dumpall -U $u --clean --if-exists | gzip > /tmp/{sys.argv[1]}.sql.gz",
    f"gunzip -c /tmp/{sys.argv[1]}.sql.gz | grep -q \"database cluster dump complete\"",
    f"curl -fsS -X PUT -T /tmp/{sys.argv[1]}.sql.gz \"{sys.argv[2]}\"",
    f"rm -f /tmp/{sys.argv[1]}.sql.gz"]}))' "$db" "$put")
  cmd=$(aws ssm send-command --region "$REGION" --instance-ids "$INSTANCE" --document-name AWS-RunShellScript --parameters "$params" --query Command.CommandId --output text)
  while :; do
    st=$(aws ssm get-command-invocation --region "$REGION" --command-id "$cmd" --instance-id "$INSTANCE" --query Status --output text 2>/dev/null || echo Pending)
    case "$st" in Success) break ;; Failed|Cancelled|TimedOut) echo "$db 덤프 실패: $st"; exit 1 ;; esac
    sleep 5
  done
done

aws s3 sync "s3://$SOURCE_FRONTEND/" "s3://$BUCKET/eks-seed/frontend/" --delete
printf %s "$ID" | aws s3 cp - "s3://$BUCKET/eks-seed/snapshot-id"
echo "시드 완료: $ID"
