# S3r 공통: 상태 저장 노드 계획 교체(점검·업그레이드 재현).
S3R_REGION=ap-northeast-2; S3R_CLUSTER=cosmos-v3-john; S3R_NG=stateful-ng
S3R_PODS="ai-postgres-0 judge-postgres-0 judge-redis-queue-0 rabbitmq-0"
s3r_nodes() { kubectl get nodes -l workload-class=stateful -o jsonpath='{range .items[*]}{.metadata.name} {.status.conditions[?(@.type=="Ready")].status} {.spec.unschedulable}{"\n"}{end}'; }
s3r_ready_count() { s3r_nodes | awk '$2=="True"' | wc -l | tr -d ' '; }
s3r_pods_ready() { local p; for p in $S3R_PODS; do [ "$(kubectl get pod "$p" -n prod -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ] || return 1; done; }
s3r_scale() { aws eks update-nodegroup-config --region "$S3R_REGION" --cluster-name "$S3R_CLUSTER" --nodegroup-name "$S3R_NG" --scaling-config "minSize=$1,maxSize=$2,desiredSize=$3" >/dev/null; }
