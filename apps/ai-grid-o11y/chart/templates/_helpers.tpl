{{- define "o11y.secretName" -}}
{{- if eq .Values.objectStorage.mode "existingSecret" }}{{ required "objectStorage.existingSecret.name is required in existingSecret mode" .Values.objectStorage.existingSecret.name }}{{ else }}{{ .Values.name }}-object-storage{{ end }}
{{- end }}
{{- define "o11y.caName" -}}
{{- if eq .Values.objectStorage.mode "existingSecret" }}{{ .Values.objectStorage.existingSecret.caName }}{{ else }}{{ .Values.objectStorage.obc.caName }}{{ end }}
{{- end }}
{{- define "o11y.caKey" -}}
{{- if eq .Values.objectStorage.mode "existingSecret" }}{{ .Values.objectStorage.existingSecret.caKey }}{{ else }}{{ .Values.objectStorage.obc.caKey }}{{ end }}
{{- end }}
{{- define "o11y.validate" -}}
{{- if not (has .Values.objectStorage.mode (list "obc" "existingSecret")) }}{{ fail (printf "objectStorage.mode %q: use obc or existingSecret" .Values.objectStorage.mode) }}{{ end }}
{{- $_ := required "lokistack.storageClassName is required: the block storage class for the LokiStack volumes" .Values.lokistack.storageClassName }}
{{- if not (has .Values.objectStorage.obc.scheme (list "https" "http")) }}{{ fail (printf "objectStorage.obc.scheme %q: use https or http" .Values.objectStorage.obc.scheme) }}{{ end }}
{{- end }}
