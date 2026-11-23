#!/usr/bin/env bash
# 개선 전 복구: Terraform으로 같은 식별자를 시드 스냅샷에서 새로 만들고, 시드 덤프를 복원하고, 테스트 데이터를 다시 만든다.
# 시드 이후 쓰인 데이터는 모두 잃는다.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
source "$S3B_V3/scripts/common.sh"
s3b_event "복구 시작(재생성)"
SNAPSHOT=$(aws s3 cp "s3://$SEED_BUCKET/eks-seed/snapshot-id" -)
tf apply -input=false -auto-approve -var "seed_snapshot_identifier=$SNAPSHOT" -var enable_edge=true >"$RECORD_DIR/recreate-tf.log" 2>&1
s3b_event "RDS 재생성 완료($(s3b_status))"
"$S3B_V3/scripts/restore-mysql.sh" >"$RECORD_DIR/restore-mysql.log" 2>&1
s3b_event "시드 덤프 복원 완료"
s3b_restart_spring
s3b_event "Spring 재시작 완료, 표식 응답 $(s3b_probe)"
"$S3B_V3/loadtest/prepare.sh" >"$RECORD_DIR/prepare.log" 2>&1
s3b_event "복구 끝(테스트 데이터 다시 만듦)"
