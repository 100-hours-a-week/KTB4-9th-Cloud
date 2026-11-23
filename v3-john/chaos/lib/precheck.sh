# 실행기 사전 검사 함수. 위반이 있으면 이유를 출력하고 1을 돌려준다(guard_check와 같은 방식).
#   precheck_nodes : cordon된 application 노드가 있으면 1. 이전 stage.sh가 중단돼 cordon이 남으면 노드 한 대가 빈 채로 실험하게 된다.
precheck_nodes() {
  local cordoned
  cordoned=$(kubectl get nodes -l workload-class=application \
    -o jsonpath='{range .items[?(@.spec.unschedulable==true)]}{.metadata.name}{" "}{end}' 2>/dev/null) \
    || { echo "application 노드 상태를 확인할 수 없다"; return 1; }
  [ -z "${cordoned// /}" ] || { echo "cordon된 application 노드가 있다: ${cordoned% }. kubectl uncordon 후 다시 실행한다."; return 1; }
}
