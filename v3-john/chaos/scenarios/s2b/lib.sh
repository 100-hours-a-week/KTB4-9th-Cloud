# S2' B(상태 저장 노드 회수) 공통. s2/lib.sh의 FIS 함수를 재사용한다.
source "$(dirname "${BASH_SOURCE[0]}")/../s2/lib.sh"
S2B_PODS="ai-postgres-0 judge-postgres-0 judge-redis-queue-0 rabbitmq-0"
# 상태 저장 볼륨이 있는 존(judge-postgres 데이터 볼륨 기준). 네 볼륨은 같은 존에 있다(2026-11-24 확인).
s2b_volume_zone() {
  local pv; pv=$(kubectl get pvc data-judge-postgres-0 -n prod -o jsonpath='{.spec.volumeName}')
  kubectl get pv "$pv" -o jsonpath='{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]}'
}
# 상태 저장 Ready 노드 "이름 존" 목록
s2b_nodes() { kubectl get nodes -l workload-class=stateful -o jsonpath='{range .items[*]}{.metadata.name} {.metadata.labels.topology\.kubernetes\.io/zone} {.status.conditions[?(@.type=="Ready")].status} {.spec.unschedulable}{"\n"}{end}'; }
# 네 파드가 모두 Ready면 0
s2b_pods_ready() {
  local p r
  for p in $S2B_PODS; do
    r=$(kubectl get pod "$p" -n prod -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    [ "$r" = True ] || return 1
  done
}
# 볼륨 존과 다른 존의 Ready 상태 저장 노드 이름(없으면 빈 출력). 이 노드에는 상태 저장 파드가 뜰 수 없다.
s2b_wrong_zone_node() { local vz=$1; s2b_nodes | awk -v vz="$vz" '$3=="True" && $2!=vz {print $1; exit}'; }
