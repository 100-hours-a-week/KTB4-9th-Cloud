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
serviceAccountName: {{ .Values.serviceAccount }}
automountServiceAccountToken: false
priorityClassName: {{ .Values.priorityClass }}
nodeSelector:
  {{- toYaml .Values.nodeSelector | nindent 2 }}
{{- with .Values.tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
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
    {{- with .Values.probes }}
    {{- toYaml . | nindent 4 }}
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
volumes:
  - name: secrets
    csi:
      driver: secrets-store.csi.k8s.io
      readOnly: true
      volumeAttributes:
        secretProviderClass: {{ .Values.name }}
{{- end -}}
