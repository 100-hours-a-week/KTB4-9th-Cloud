#!/usr/bin/env bash
# S3b 주입: RDS 인스턴스를 지운다(사람 실수 재현). S3B_KEEP_BACKUPS=1이면 자동 백업을 남긴다(단계 3 이후).
# 삭제 보호가 켜져 있으면 실패하고 그 결과를 남긴다(단계 3 검증).
set -uo pipefail
source "$(dirname "$0")/lib.sh"
[ -s "$RECORD_DIR/safety-snapshot" ] || { echo "안전망 스냅샷이 없다. snapshot.sh 먼저" >&2; exit 1; }
args=(--skip-final-snapshot)
[ "${S3B_KEEP_BACKUPS:-0}" = 1 ] && args+=(--no-delete-automated-backups) || args+=(--delete-automated-backups)
s3b_event "삭제 요청 ${args[*]}"
if ! out=$(aws rds delete-db-instance --region "$S3B_REGION" --db-instance-identifier "$S3B_DB" "${args[@]}" 2>&1); then
  s3b_event "삭제 거부: $(echo "$out" | tr '\n' ' ' | cut -c1-200)"; exit 3
fi
aws rds wait db-instance-deleted --region "$S3B_REGION" --db-instance-identifier "$S3B_DB"
s3b_event "삭제 완료"
