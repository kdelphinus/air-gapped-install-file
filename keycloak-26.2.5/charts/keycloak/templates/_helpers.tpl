{{- define "keycloak.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "keycloak.fullname" -}}
{{- printf "%s-%s" .Release.Name (include "keycloak.name" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
