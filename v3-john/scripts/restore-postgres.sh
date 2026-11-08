#!/usr/bin/env bash
# seed.sh가 올린 AI, Judge PostgreSQL 덤프를 복원한다.
source "$(dirname "$0")/common.sh"
for db in ai judge; do
  pod="$db-postgres-0"
  user=$(kubectl exec -n prod "$pod" -- cat /mnt/secrets/POSTGRES_USER 2>/dev/null || kubectl exec -n prod "$pod" -- cat /mnt/secrets/DB_USER)
  aws s3 cp "s3://$SEED_BUCKET/eks-seed/$db.sql.gz" - | gunzip | kubectl exec -i -n prod "$pod" -- psql -q -U "$user" -d postgres -v ON_ERROR_STOP=0 >/dev/null
  echo "$db 복원 완료"
done
