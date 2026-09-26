{{- define "base-api.deploymentName" -}}
{{- if eq .Values.track "canary" }}{{ .Values.nameOverride }}-canary{{ else }}{{ .Values.nameOverride }}{{ end -}}
{{- end -}}
