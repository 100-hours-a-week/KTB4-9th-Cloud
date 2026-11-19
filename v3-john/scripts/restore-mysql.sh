#!/usr/bin/env bash
# seed.sh가 올린 오레곤 MySQL 덤프를 스냅샷으로 만든 RDS 위에 덮어쓴다.
source "$(dirname "$0")/common.sh"
HOST=$(tf output -raw mysql_address)
DB_SECRET="cosmos/$ENV_NAME/main-db"
kubectl create secret generic mysql-restore -n prod \
  --from-literal="user=$(secret_key "$DB_SECRET" username)" \
  --from-literal="password=$(secret_key "$DB_SECRET" password)" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
# 대기용 파드를 띄우고 kubectl exec -i로 덤프를 넣는다. kubectl run -i의 attach 스트림은 네트워크에 따라 1분 만에 끊긴다.
overrides=$(python3 -c 'import json;print(json.dumps({"spec":{"containers":[{"name":"mysql-restore","image":"mysql:8.4","command":["sleep","1800"],
  "env":[{"name":"DB_USER","valueFrom":{"secretKeyRef":{"name":"mysql-restore","key":"user"}}},
         {"name":"MYSQL_PWD","valueFrom":{"secretKeyRef":{"name":"mysql-restore","key":"password"}}}]}]}}))')
# prod의 default-deny가 복원 파드의 RDS 접속을 막는다. 복원하는 동안만 데이터 서브넷 3306 송신을 연다.
kubectl apply -f - >/dev/null <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: mysql-restore
  namespace: prod
spec:
  podSelector:
    matchLabels: { run: mysql-restore }
  policyTypes: [Egress]
  egress:
    - to:
        - ipBlock: { cidr: 10.30.20.0/23 }
      ports:
        - { protocol: TCP, port: 3306 }
EOF
cleanup() {
  kubectl delete pod mysql-restore -n prod --ignore-not-found --wait=false >/dev/null
  kubectl delete networkpolicy mysql-restore -n prod --ignore-not-found >/dev/null
  kubectl delete secret mysql-restore -n prod --ignore-not-found >/dev/null
}
trap cleanup EXIT
kubectl delete pod mysql-restore -n prod --ignore-not-found --wait=true >/dev/null
kubectl run mysql-restore -n prod --restart=Never --image=mysql:8.4 --labels=run=mysql-restore --overrides="$overrides" >/dev/null 2>&1
kubectl wait -n prod --for=condition=Ready pod/mysql-restore --timeout=180s >/dev/null

# Argo CD 자동 동기화로 Spring 앱이 먼저 떠 있으면 커넥션이 테이블 메타데이터 잠금을 잡아 DROP TABLE이 멈춘다.
SPRING=(cosmos-auth cosmos-core cosmos-battle)
running=()
for d in "${SPRING[@]}"; do
  kubectl get deploy "$d" -n prod >/dev/null 2>&1 && running+=("$d")
done
if ((${#running[@]})); then
  kubectl scale deploy -n prod "${running[@]}" --replicas=0 >/dev/null
  kubectl wait -n prod --for=delete pod -l "app.kubernetes.io/name in (cosmos-auth,cosmos-core,cosmos-battle)" --timeout=180s >/dev/null 2>&1 || true
fi
aws s3 cp "s3://$SEED_BUCKET/eks-seed/mysql.sql.gz" - | gunzip \
  | kubectl exec -i -n prod mysql-restore -- sh -c 'mysql -h "$0" -u "$DB_USER" cosmos' "$HOST"
# 덤프 이후 BE에 추가된 스키마를 맞춘다(stage는 ddl-auto: validate).
kubectl exec -i -n prod mysql-restore -- sh -c 'mysql -h "$0" -u "$DB_USER" cosmos' "$HOST" < "$(dirname "$0")/schema-patches.sql"
# HPA가 다시 관리하도록 1개로 되돌린다.
((${#running[@]})) && kubectl scale deploy -n prod "${running[@]}" --replicas=1 >/dev/null
echo "mysql 복원 완료"
