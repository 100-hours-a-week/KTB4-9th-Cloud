#!/usr/bin/env bash
# S1 단계 3 = S2 단계 1: PDB, 노드 분산, HPA 최소 2, JVM 힙 비율이 prod 값으로 렌더링되는지 확인한다.
set -uo pipefail
C=$(cd "$(dirname "$0")/.." && pwd); P=$C/../../environments/prod; fail=0
ok() { echo "PASS $1"; }; no() { echo "FAIL $1"; fail=1; }
kind() { awk -v k="kind: $1" '$0==k{f=1} f{print} /^---/{if(f)exit}'; }
for s in auth core battle; do
  out=$(helm template t "$C" -n prod -f "$P/$s.yaml" 2>&1)
  pdb=$(kind PodDisruptionBudget <<<"$out")
  grep -q 'minAvailable: 1' <<<"$pdb" && grep -q "app.kubernetes.io/name: cosmos-$s" <<<"$pdb" && ok "$s PDB minAvailable 1" || no "$s PDB"
  dep=$(kind Deployment <<<"$out")
  grep -A6 'topologySpreadConstraints' <<<"$dep" | grep -q 'topologyKey: kubernetes.io/hostname' && grep -A6 'topologySpreadConstraints' <<<"$dep" | grep -q 'whenUnsatisfiable: ScheduleAnyway' && grep -A6 'topologySpreadConstraints' <<<"$dep" | grep -q 'maxSkew: 1' && ok "$s 노드 분산" || no "$s 노드 분산"
  grep -q 'minReplicas: 2' <<<"$(kind HorizontalPodAutoscaler <<<"$out")" && ok "$s HPA 최소 2" || no "$s HPA 최소 2"
  grep -A1 'name: JAVA_TOOL_OPTIONS' <<<"$dep" | grep -q -- '-XX:MaxRAMPercentage=75' && ok "$s JVM 힙 75%" || no "$s JVM 힙"
done
# S2' 단계 3: judge-api(Judge0)도 이중화한다. 이름이 cosmos-judge-api인지로 선택자를 확인한다.
out=$(helm template t "$C" -n prod -f "$P/judge-api.yaml" 2>&1)
pdb=$(kind PodDisruptionBudget <<<"$out")
grep -q 'minAvailable: 1' <<<"$pdb" && grep -q "app.kubernetes.io/name: cosmos-judge-api" <<<"$pdb" && ok "judge-api PDB minAvailable 1" || no "judge-api PDB"
dep=$(kind Deployment <<<"$out")
grep -A6 'topologySpreadConstraints' <<<"$dep" | grep -q 'topologyKey: kubernetes.io/hostname' && grep -A6 'topologySpreadConstraints' <<<"$dep" | grep -q 'whenUnsatisfiable: ScheduleAnyway' && grep -A6 'topologySpreadConstraints' <<<"$dep" | grep -q 'maxSkew: 1' && ok "judge-api 노드 분산" || no "judge-api 노드 분산"
grep -q 'minReplicas: 2' <<<"$(kind HorizontalPodAutoscaler <<<"$out")" && ok "judge-api HPA 최소 2" || no "judge-api HPA 최소 2"
grep -q 'preStop' <<<"$dep" && ok "judge-api preStop 유지" || no "judge-api preStop 유지"
off=$(helm template t "$C" -n prod -f "$P/ai-llm.yaml" 2>&1)
grep -q 'kind: PodDisruptionBudget' <<<"$off" && no "pdb 값이 없는데 PDB" || ok "pdb 기본값이면 PDB 없음"
grep -q 'topologySpreadConstraints' <<<"$off" && no "spread 기본값인데 분산 제약" || ok "spread 기본값이면 분산 제약 없음"
exit $fail
