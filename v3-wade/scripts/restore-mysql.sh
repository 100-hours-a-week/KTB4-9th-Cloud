#!/usr/bin/env bash
# seed.sh가 올린 오레곤 MySQL 덤프를 스냅샷으로 만든 RDS 위에 덮어쓴다.
source "$(dirname "$0")/common.sh"
HOST=$(tf output -raw mysql_address)
DB_SECRET="cosmos/$ENV_NAME/main-db"
kubectl create secret generic mysql-restore -n prod \
  --from-literal="user=$(secret_key "$DB_SECRET" username)" \
  --from-literal="password=$(secret_key "$DB_SECRET" password)" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
overrides=$(python3 -c 'import json,sys;print(json.dumps({"spec":{"containers":[{"name":"mysql-restore","image":"mysql:8.4","stdin":True,
  "command":["sh","-c","mysql -h \"$0\" -u \"$DB_USER\" cosmos",sys.argv[1]],
  "env":[{"name":"DB_USER","valueFrom":{"secretKeyRef":{"name":"mysql-restore","key":"user"}}},
         {"name":"MYSQL_PWD","valueFrom":{"secretKeyRef":{"name":"mysql-restore","key":"password"}}}]}]}}))' "$HOST")
aws s3 cp "s3://$SEED_BUCKET/eks-seed/mysql.sql.gz" - | gunzip \
  | kubectl run mysql-restore -n prod -i --rm --quiet --restart=Never --image=mysql:8.4 --overrides="$overrides"
kubectl delete secret mysql-restore -n prod >/dev/null
echo "mysql 복원 완료"
