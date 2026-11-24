#!/usr/bin/env bash
# S2' 배치 재현: 지정한 application 노드 하나에 judge-api, Envoy 하나, Prometheus, Alertmanager, Tempo, core 하나가 함께 있게 만든다.
#   stage.sh <노드>     (RECORD_DIR 필요)
# 방법: 다른 application 노드를 cordon하고 대상 파드를 지워 <노드>에 다시 뜨게 한 뒤, 끝나면 반드시 uncordon한다.
# S2_STAGE_SKIP=monitoring,tempo,judge-api,envoy,core 로 개선 단계가 이미 바꾼 항목은 건너뛴다(monitoring은 tempo도 포함).
# S2_STAGE_WAIT_S(기본 300)까지 모든 배치와 Ready를 기다린다. 하나라도 안 맞으면 종료 1, 사용법 오류는 2.
set -uo pipefail
node=${1:-}; [ -n "$node" ] || { echo "사용: $0 <노드>" >&2; exit 2; }
: "${RECORD_DIR:?RECORD_DIR가 필요하다}"
SKIP=",${S2_STAGE_SKIP:-},"
skipped() { [[ "$SKIP" == *",$1,"* ]] || { [ "$1" = tempo ] && [[ "$SKIP" == *",monitoring,"* ]]; }; }
# 모니터링 볼륨(Prometheus, Alertmanager)이 있는 존. 클러스터를 새로 띄우면 바뀐다(1차 2a, 2차 2c). Tempo 볼륨이 다른 존이면 S2_STAGE_SKIP=tempo.
MON_ZONE=${S2_MON_ZONE:-ap-northeast-2a}
WAIT_S=${S2_STAGE_WAIT_S:-300}; POLL_S=${S2_STAGE_POLL_S:-5}

# 대상: 항목|네임스페이스|라벨|기대 개수(all은 지금 있는 파드 전부, 숫자는 노드 위 개수)
ITEMS=(
  "judge-api|prod|app.kubernetes.io/name=cosmos-judge-api|all"
  "envoy|envoy-gateway-system|gateway.envoyproxy.io/owning-gateway-name=prod|1+"
  "monitoring|monitoring|statefulset.kubernetes.io/pod-name=prometheus-kube-prometheus-stack-prometheus-0|all"
  "monitoring|monitoring|statefulset.kubernetes.io/pod-name=alertmanager-kube-prometheus-stack-alertmanager-0|all"
  "tempo|monitoring|statefulset.kubernetes.io/pod-name=tempo-0|all"
  "core|prod|app.kubernetes.io/name=cosmos-core|1"
)

# 파드 목록: 이름|노드|Ready|삭제 중 표시. 삭제 중인 파드는 뺀다.
pods() {  # ns label
  kubectl get pods -n "$1" -l "$2" -o jsonpath='{range .items[*]}{.metadata.name}|{.spec.nodeName}|{.status.conditions[?(@.type=="Ready")].status}|{.metadata.deletionTimestamp}{"\n"}{end}' 2>/dev/null \
    | awk -F'|' 'NF && $4==""'
}

cordoned=()
cleanup() { for n in "${cordoned[@]:-}"; do [ -n "$n" ] && kubectl uncordon "$n" >/dev/null 2>&1 && echo "uncordon $n"; done; }
trap cleanup EXIT
trap 'exit 130' INT TERM

cls=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.workload-class}' 2>/dev/null)
[ "$cls" = application ] || { echo "$node는 application 노드가 아니다($cls)" >&2; exit 1; }
if ! skipped monitoring || ! skipped tempo; then
  zone=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}' 2>/dev/null)
  [ "$zone" = "$MON_ZONE" ] || { echo "$node의 존이 $zone이다. 모니터링 볼륨은 $MON_ZONE에 있어 올릴 수 없다(S2_MON_ZONE으로 존을 지정하거나 S2_STAGE_SKIP=monitoring,tempo)" >&2; exit 1; }
fi

# 다른 application 노드를 cordon한다.
while read -r n; do
  [ -n "$n" ] && [ "$n" != "$node" ] || continue
  cordoned+=("$n")
  kubectl cordon "$n" >/dev/null || { echo "cordon $n 실패" >&2; exit 1; }
done < <(kubectl get nodes -l workload-class=application -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
echo "cordon: ${cordoned[*]:-없음}"

# 대상 파드를 지운다. 이미 노드 위에 있는 것은 두고, core는 노드에 없을 때만 하나를 지운다.
delete_one() { echo "삭제: $1/$2"; kubectl delete pod "$2" -n "$1" --wait=false >/dev/null || { echo "$1/$2 삭제 실패" >&2; exit 1; }; }
for it in "${ITEMS[@]}"; do
  IFS='|' read -r kind ns label want <<<"$it"
  skipped "$kind" && continue
  list=$(pods "$ns" "$label")
  [ -n "$list" ] || { echo "$kind 파드를 찾지 못했다($ns, $label)" >&2; exit 1; }
  case "$want" in
    all) while IFS='|' read -r name on _; do [ "$on" = "$node" ] || delete_one "$ns" "$name"; done <<<"$list" ;;
    *) if ! awk -F'|' -v n="$node" '$2==n{f=1} END{exit !f}' <<<"$list"; then
         delete_one "$ns" "$(head -1 <<<"$list" | cut -d'|' -f1)"
       fi ;;
  esac
done

# 모두 <노드>에 Ready로 올라올 때까지 기다린다. 판정 결과를 기록 파일에도 남긴다.
check() {  # 실패한 항목을 stdout에 줄로 낸다
  local it kind ns label want list total on ready
  for it in "${ITEMS[@]}"; do
    IFS='|' read -r kind ns label want <<<"$it"
    skipped "$kind" && continue
    list=$(pods "$ns" "$label")
    total=$(grep -c . <<<"$list"); on=$(awk -F'|' -v n="$node" '$2==n' <<<"$list" | grep -c .)
    ready=$(awk -F'|' -v n="$node" '$2==n && $3=="True"' <<<"$list" | grep -c .)
    case "$want" in
      all) (( total > 0 && on == total && ready == total )) || echo "$kind $ns/$label: 노드 위 $on/$total, Ready $ready" ;;
      1+) (( ready >= 1 )) || echo "$kind $ns/$label: 노드 위 Ready ${ready}개" ;;
      1) (( on == 1 && ready == 1 )) || echo "$kind $ns/$label: 노드 위 ${on}개, Ready ${ready}개(정확히 1개여야 한다)" ;;
    esac
  done
}
deadline=$(( $(date +%s) + WAIT_S )); bad=""
while :; do
  bad=$(check)
  [ -z "$bad" ] && break
  (( $(date +%s) >= deadline )) && break
  sleep "$POLL_S"
done

{
  echo "# S2' 배치 기록 노드=$node 시각=$(date -u +%Y-%m-%dT%H:%M:%SZ) skip=${S2_STAGE_SKIP:-}"
  for it in "${ITEMS[@]}"; do
    IFS='|' read -r kind ns label _ <<<"$it"
    skipped "$kind" && continue
    pods "$ns" "$label" | while IFS='|' read -r name on rd _; do echo "$ns/$name $on ready=$rd"; done
  done
} > "$RECORD_DIR/s2-staged.txt"

if [ -n "$bad" ]; then
  echo "배치 실패:" >&2; echo "$bad" >&2; exit 1
fi
echo "배치 완료: $node (기록 $RECORD_DIR/s2-staged.txt)"
