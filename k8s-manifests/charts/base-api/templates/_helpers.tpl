{{- define "base-api.name" -}}
{{- default .Release.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "base-api.selectorLabels" -}}
app: {{ include "base-api.name" . }}
{{- end -}}

{{- define "base-api.labels" -}}
{{ include "base-api.selectorLabels" . }}
version: {{ .Values.version }}
app.kubernetes.io/name: {{ include "base-api.name" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}
