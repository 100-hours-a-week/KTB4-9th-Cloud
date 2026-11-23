{{- define "cosmos.labels" -}}
app.kubernetes.io/part-of: cosmos
app.kubernetes.io/name: {{ .Values.name }}
app.kubernetes.io/component: {{ .Values.component }}
app.kubernetes.io/instance: {{ .Release.Namespace }}-{{ .Values.name }}
{{- end -}}
{{- define "cosmos.selector" -}}
app.kubernetes.io/name: {{ .Values.name }}
{{- end -}}
{{- define "cosmos.podSpec" -}}
{{- if gt (int .Values.preStopSleepSeconds) 0 }}
{{- if le (int .Values.terminationGracePeriodSeconds) (add (int .Values.preStopSleepSeconds) (int .Values.shutdownPhaseSeconds)) }}
{{- fail (printf "terminationGracePeriodSeconds는 preStopSleepSeconds와 shutdownPhaseSeconds의 합보다 커야 한다(종료 유예 %v초, preStop %v초, 종료 단계 %v초)" .Values.terminationGracePeriodSeconds .Values.preStopSleepSeconds .Values.shutdownPhaseSeconds) }}
{{- end }}
{{- end }}
serviceAccountName: {{ .Values.serviceAccount }}
automountServiceAccountToken: false
priorityClassName: {{ .Values.priorityClass }}
nodeSelector:
  {{- toYaml .Values.nodeSelector | nindent 2 }}
{{- with .Values.tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- if .Values.spread }}
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: ScheduleAnyway
    labelSelector:
      matchLabels: {{- include "cosmos.selector" . | nindent 8 }}
{{- end }}
{{- $agent := and .Values.otel.enabled .Values.otel.agent }}
{{- if $agent }}
initContainers:
  - name: otel-agent
    image: {{ .Values.otel.agentImage }}
    command: [cp, /javaagent.jar, /otel/javaagent.jar]
    resources:
      requests: { cpu: 10m, memory: 32Mi }
      limits: { cpu: 100m, memory: 64Mi }
    securityContext:
      allowPrivilegeEscalation: false
    volumeMounts:
      - name: otel-agent
        mountPath: /otel
{{- end }}
containers:
  - name: {{ .Values.name }}
    image: {{ .Values.image }}
    {{- with .Values.command }}
    command:
      {{- toYaml . | nindent 6 }}
    {{- end }}
    {{- if .Values.port }}
    ports:
      - name: http
        containerPort: {{ .Values.port }}
      {{- range .Values.extraPorts }}
      - name: {{ .name }}
        containerPort: {{ .port }}
      {{- end }}
    {{- end }}
    env:
      {{- range $k, $v := .Values.env }}
      - name: {{ $k }}
        value: {{ $v | quote }}
      {{- end }}
      {{- $jto := compact (list (ternary "-javaagent:/otel/javaagent.jar" "" $agent) .Values.jvmOptions) | join " " }}
      {{- if $jto }}
      - name: JAVA_TOOL_OPTIONS
        value: {{ $jto | quote }}
      {{- end }}
      {{- if .Values.otel.enabled }}
      - name: OTEL_SERVICE_NAME
        value: {{ default .Values.name .Values.otel.serviceName | quote }}
      - name: OTEL_EXPORTER_OTLP_ENDPOINT
        value: "http://otel-collector.monitoring.svc.cluster.local:4317"
      - name: OTEL_EXPORTER_OTLP_PROTOCOL
        value: "grpc"
      - name: OTEL_TRACES_EXPORTER
        value: "otlp"
      - name: OTEL_METRICS_EXPORTER
        value: "none"
      - name: OTEL_LOGS_EXPORTER
        value: "none"
      - name: OTEL_RESOURCE_ATTRIBUTES
        value: {{ printf "deployment.environment.name=john,service.namespace=cosmos,k8s.cluster.name=cosmos-v3-john,service.version=%s" (default "unknown" (regexFind "[0-9a-f]{40}" .Values.image)) | quote }}
      {{- end }}
    {{- with .Values.probes }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
    {{- if gt (int .Values.preStopSleepSeconds) 0 }}
    lifecycle:
      preStop:
        exec:
          command: ["sh", "-c", "sleep {{ int .Values.preStopSleepSeconds }}"]
    {{- end }}
    resources:
      {{- toYaml .Values.resources | nindent 6 }}
    securityContext:
      {{- if .Values.privileged }}
      privileged: true
      {{- else }}
      allowPrivilegeEscalation: false
      {{- end }}
    volumeMounts:
      - name: secrets
        mountPath: {{ .Values.secretMountPath }}
        readOnly: true
      {{- if .Values.stateful.enabled }}
      - name: data
        mountPath: {{ .Values.stateful.mountPath }}
      {{- end }}
      {{- if $agent }}
      - name: otel-agent
        mountPath: /otel
        readOnly: true
      {{- end }}
volumes:
  - name: secrets
    csi:
      driver: secrets-store.csi.k8s.io
      readOnly: true
      volumeAttributes:
        secretProviderClass: {{ .Values.name }}
  {{- if $agent }}
  - name: otel-agent
    emptyDir: { sizeLimit: 64Mi }
  {{- end }}
{{- end -}}
