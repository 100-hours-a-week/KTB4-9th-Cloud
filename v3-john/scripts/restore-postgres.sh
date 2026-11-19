#!/usr/bin/env bash
# seed.sh가 올린 AI, Judge PostgreSQL 덤프를 복원한다.
source "$(dirname "$0")/common.sh"
for db in ai judge; do
  pod="$db-postgres-0"
  user=$(kubectl exec -n prod "$pod" -- cat /mnt/secrets/POSTGRES_USER 2>/dev/null || kubectl exec -n prod "$pod" -- cat /mnt/secrets/DB_USER)
  aws s3 cp "s3://$SEED_BUCKET/eks-seed/$db.sql.gz" - | gunzip | kubectl exec -i -n prod "$pod" -- psql -q -U "$user" -d postgres -v ON_ERROR_STOP=0 >/dev/null
  # 덤프의 ALTER ROLE이 계정 비밀번호를 오레곤 값으로 바꾼다. 클러스터 시크릿 값으로 되돌린다(값은 파드 안에서만 읽는다).
  kubectl exec -n prod "$pod" -- sh -c '
    u=$(cat /mnt/secrets/POSTGRES_USER); p=$(cat /mnt/secrets/POSTGRES_PASSWORD)
    printf "%s\n" "ALTER ROLE :\"u\" PASSWORD :'"'"'p'"'"';" | psql -q -U "$u" -d postgres -v ON_ERROR_STOP=1 -v u="$u" -v p="$p"' >/dev/null
  echo "$db 복원 완료"
done
# mlflow 백엔드 DB는 덤프에 없다. 없으면 만든다.
kubectl exec -n prod ai-postgres-0 -- sh -c '
  u=$(cat /mnt/secrets/POSTGRES_USER)
  psql -U "$u" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '"'"'mlflow'"'"'" | grep -q 1 \
    || psql -q -U "$u" -d postgres -c "CREATE DATABASE mlflow OWNER \"$u\""'
echo "mlflow DB 준비 완료"
