#!/usr/bin/env bash
# 안전망 수동 스냅샷 cosmos-v3-john-safety-<날짜시각>. available까지 기다린다. 개선 전 측정에는 쓰지 않는다.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
id="cosmos-v3-john-safety-$(date +%Y%m%d-%H%M)"
aws rds create-db-snapshot --region "$S3B_REGION" --db-instance-identifier "$S3B_DB" --db-snapshot-identifier "$id" >/dev/null
aws rds wait db-snapshot-available --region "$S3B_REGION" --db-snapshot-identifier "$id"
echo "$id" > "$RECORD_DIR/safety-snapshot"; s3b_event "안전망 스냅샷 $id available"
