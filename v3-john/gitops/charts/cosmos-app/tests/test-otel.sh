#!/usr/bin/env bash
# 차트 otel, jvmOptions 값의 렌더링 결과를 확인한다(설계서 S1 단계 2). helm만 쓰고 클러스터는 부르지 않는다.
set -uo pipefail
C=$(cd "$(dirname "$0")/.." && pwd); P=$C/../../environments/prod; fail=0
ok() { echo "PASS $1"; }; no() { echo "FAIL $1"; fail=1; }
r() { helm template t "$C" -n prod -f "$P/core.yaml" "$@" 2>&1 | awk '/^kind: Deployment/,/^---/'; }

off=$(r --set otel.enabled=false)
grep -q 'OTEL_' <<<"$off" && no "otel 꺼짐인데 OTEL_ 변수" || ok "otel 꺼지면 OTEL_ 변수 없음"
grep -q 'initContainers' <<<"$off" && no "otel 꺼짐인데 init 컨테이너" || ok "otel 꺼지면 init 컨테이너 없음"

on=$(r --set otel.enabled=true,otel.agent=true,otel.serviceName=cosmos-core)
grep -q 'initContainers' <<<"$on" && grep -q 'autoinstrumentation-java:.*@sha256:[0-9a-f]\{64\}' <<<"$on" && ok "agent면 digest 고정 init 컨테이너" || no "init 컨테이너"
grep -A1 'name: JAVA_TOOL_OPTIONS' <<<"$on" | grep -q -- '-javaagent:/otel/javaagent.jar' && ok "JAVA_TOOL_OPTIONS에 javaagent" || no "JAVA_TOOL_OPTIONS"
grep -A1 'name: OTEL_SERVICE_NAME' <<<"$on" | grep -q 'cosmos-core' && ok "OTEL_SERVICE_NAME" || no "OTEL_SERVICE_NAME"
grep -A1 'name: OTEL_EXPORTER_OTLP_ENDPOINT' <<<"$on" | grep -q 'http://otel-collector.monitoring.svc.cluster.local:4317' && ok "수집기 주소" || no "수집기 주소"
for k in OTEL_EXPORTER_OTLP_PROTOCOL OTEL_TRACES_EXPORTER OTEL_METRICS_EXPORTER OTEL_LOGS_EXPORTER; do
  grep -q "name: $k" <<<"$on" && ok "$k" || no "$k"; done
grep -A1 'name: OTEL_RESOURCE_ATTRIBUTES' <<<"$on" | grep -q 'deployment.environment.name=john,service.namespace=cosmos,k8s.cluster.name=cosmos-v3-john,service.version=' && ok "리소스 속성" || no "리소스 속성"
grep -q 'mountPath: /otel' <<<"$on" && grep -q 'emptyDir' <<<"$on" && ok "에이전트 볼륨" || no "에이전트 볼륨"

noagent=$(r --set otel.enabled=true,otel.agent=false,otel.serviceName=cosmos-core)
grep -q 'initContainers' <<<"$noagent" && no "agent=false인데 init 컨테이너" || ok "agent=false면 init 없음"
grep -q 'javaagent' <<<"$noagent" && no "agent=false인데 javaagent" || ok "agent=false면 javaagent 없음"

jvm=$(r --set otel.enabled=true,otel.agent=true,jvmOptions=-XX:MaxRAMPercentage=75)
grep -A1 'name: JAVA_TOOL_OPTIONS' <<<"$jvm" | grep -q -- '-javaagent:/otel/javaagent.jar -XX:MaxRAMPercentage=75' && ok "jvmOptions를 이어 붙임" || no "jvmOptions"
j2=$(r --set otel.enabled=false,jvmOptions=-XX:MaxRAMPercentage=75)
grep -A1 'name: JAVA_TOOL_OPTIONS' <<<"$j2" | grep -q -- 'value: "-XX:MaxRAMPercentage=75"' && ok "jvmOptions만 있어도 JAVA_TOOL_OPTIONS" || no "jvmOptions 단독"
[ "$(grep -c 'name: JAVA_TOOL_OPTIONS' <<<"$jvm")" = 1 ] && ok "JAVA_TOOL_OPTIONS 한 번" || no "JAVA_TOOL_OPTIONS 중복"
exit $fail
