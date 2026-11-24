#!/usr/bin/env bash
# cosmos 알림 규칙을 kube-prometheus-stack 값 그대로 렌더링해 검사하고 단위 테스트를 돌린다.
# 사용: bash v3-john/scripts/check-rules.sh   (helm, docker, python3 + PyYAML 필요)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
VALUES="$ROOT/helm/addons-values/monitoring/kube-prometheus-stack.yaml"
TESTS="$ROOT/helm/addons-values/monitoring/tests"
CHART_VERSION=92.18.0
PROM_IMAGE=prom/prometheus:v3.5.0
AM_IMAGE=prom/alertmanager:v0.28.1

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

helm template kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --version "$CHART_VERSION" -n monitoring -f "$VALUES" > "$WORK/rendered.yaml"

# 이름이 <릴리스>-cosmos-로 시작하는 PrometheusRule의 groups만 하나의 규칙 파일로 모은다.
python3 - "$WORK/rendered.yaml" "$WORK/cosmos-rules.yaml" "$VALUES" "$WORK/alertmanager.yaml" <<'PY'
import sys, yaml
rendered, out, values, am = sys.argv[1:5]
groups = []
for doc in yaml.safe_load_all(open(rendered)):
    if doc and doc.get("kind") == "PrometheusRule" and doc["metadata"]["name"].startswith("kube-prometheus-stack-cosmos-"):
        groups += doc["spec"]["groups"]
if not groups:
    sys.exit("cosmos PrometheusRule을 찾지 못했다")
yaml.safe_dump({"groups": groups}, open(out, "w"), allow_unicode=True, sort_keys=False)
cfg = yaml.safe_load(open(values))["alertmanager"]["config"]
yaml.safe_dump(cfg, open(am, "w"), allow_unicode=True, sort_keys=False)
print(f"cosmos 규칙 그룹 {len(groups)}개, 규칙 {sum(len(g['rules']) for g in groups)}개")
PY

cp "$TESTS"/*.yaml "$WORK/"
run() { docker run --rm -v "$WORK:/w" -w /w --entrypoint "$1" "${@:2}"; }
run promtool "$PROM_IMAGE" check rules cosmos-rules.yaml
# webhook_url_file은 파드 안 경로라 검사용 설정에서는 존재 여부를 따지지 않도록 amtool check-config만 쓴다.
run amtool "$AM_IMAGE" check-config alertmanager.yaml
tests=$(cd "$WORK" && ls -1 *.yaml | grep -vE '^(cosmos-rules|alertmanager|rendered)\.yaml$')
run promtool "$PROM_IMAGE" test rules $tests
# S1' 단계 1: 연결 예산 알림 둘이 blackhole이 아니라 Discord 수신자로 가는지 확인한다.
# 규칙에 정의된 라벨(severity=warning, sev=SEV2, namespace=prod)을 그대로 쓴다.
for a in RdsConnectionBudgetHigh DbConnectionAcquireFailed; do
  got=$(run amtool "$AM_IMAGE" config routes test --config.file=alertmanager.yaml \
    alertname="$a" severity=warning sev=SEV2 namespace=prod)
  [ "$got" = "discord" ] || { echo "경로 검사 실패: $a -> '$got' (기대: discord)"; exit 1; }
  echo "경로 검사 통과: $a -> $got"
done
