#!/usr/bin/env bash
# 단계 3 복구: 남겨 둔 자동 백업에서 같은 식별자로 특정 시점 복원 → Terraform 상태에 다시 들인다 → Spring 재시작.
#   recover-pitr.sh <UTC 시각, 예 2026-11-23T12:00:00Z>
set -euo pipefail
source "$(dirname "$0")/lib.sh"
source "$S3B_V3/scripts/common.sh"
T=${1:?복원 시각}
s3b_event "복구 시작(특정 시점 복원 $T)"
arn=$(aws rds describe-db-instance-automated-backups --region "$S3B_REGION" --db-instance-identifier "$S3B_DB" \
  --query 'DBInstanceAutomatedBackups[0].DBInstanceAutomatedBackupsArn' --output text)
[ -n "$arn" ] && [ "$arn" != None ] || { s3b_event "남은 자동 백업 없음"; exit 1; }
# 요청 시각이 복원 가능 구간보다 늦으면 구간 끝으로 맞춘다(트랜잭션 로그 업로드가 몇 분 늦다).
latest=$(aws rds describe-db-instance-automated-backups --region "$S3B_REGION" --db-instance-identifier "$S3B_DB" \
  --query 'DBInstanceAutomatedBackups[0].RestoreWindow.LatestTime' --output text)
if [ "$(date -j -u -f %Y-%m-%dT%H:%M:%SZ "$T" +%s)" -gt "$(python3 -c "import sys,datetime;print(int(datetime.datetime.fromisoformat(sys.argv[1]).timestamp()))" "$latest")" ]; then
  s3b_event "요청 시각 $T가 복원 가능 끝 $latest보다 늦어 끝 시각으로 복원"; T=$(python3 -c "import sys,datetime;print(datetime.datetime.fromisoformat(sys.argv[1]).astimezone(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$latest")
fi
subnet=$(tf state show -no-color module.data.aws_db_subnet_group.main | awk -F'"' '/^ *name +=/{print $2; exit}')
sg=$(tf output -raw mysql_sg_id 2>/dev/null || tf state show -no-color module.data.aws_security_group.mysql | awk -F'"' '/^ *id +=/{print $2; exit}')
aws rds restore-db-instance-to-point-in-time --region "$S3B_REGION" \
  --source-db-instance-automated-backups-arn "$arn" --target-db-instance-identifier "$S3B_DB" --restore-time "$T" \
  --db-instance-class db.t4g.medium --storage-type gp3 --db-subnet-group-name "$subnet" --vpc-security-group-ids "$sg" \
  --db-parameter-group-name default.mysql8.4 --no-publicly-accessible --no-multi-az \
  --backup-retention-period 1 --deletion-protection >/dev/null
s3b_event "복원 요청(백업 $arn)"
aws rds wait db-instance-available --region "$S3B_REGION" --db-instance-identifier "$S3B_DB"
s3b_event "RDS 복원 완료(available)"
tf state rm module.data.aws_db_instance.main >/dev/null
tf import -input=false -var "seed_snapshot_identifier=$(aws s3 cp "s3://$SEED_BUCKET/eks-seed/snapshot-id" -)" -var enable_edge=true \
  module.data.aws_db_instance.main "$S3B_DB" >"$RECORD_DIR/import.log" 2>&1
set +e; tf plan -input=false -no-color -detailed-exitcode -var "seed_snapshot_identifier=$(aws s3 cp "s3://$SEED_BUCKET/eks-seed/snapshot-id" -)" -var enable_edge=true >"$RECORD_DIR/plan-after-import.log" 2>&1; pc=$?; set -e
s3b_event "Terraform 상태 반영(plan 종료 코드 $pc: 0 변경 없음, 2 변경 있음)"
s3b_restart_spring
s3b_event "Spring 재시작 완료, 표식 응답 $(s3b_probe)"
