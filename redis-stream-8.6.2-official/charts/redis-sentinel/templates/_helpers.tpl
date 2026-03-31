{{/*
Chart 이름
*/}}
{{- define "redis-sentinel.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully-qualified 이름 (release prefix 포함)
*/}}
{{- define "redis-sentinel.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/* Redis StatefulSet 이름 → 파드명 prefix */}}
{{- define "redis-sentinel.nodeName" -}}
{{- printf "%s-node" (include "redis-sentinel.fullname" .) }}
{{- end }}

{{/* Sentinel StatefulSet 이름 */}}
{{- define "redis-sentinel.sentinelName" -}}
{{- printf "%s-sentinel" (include "redis-sentinel.fullname" .) }}
{{- end }}

{{/* Redis headless Service 이름 */}}
{{- define "redis-sentinel.redisHeadlessName" -}}
{{- printf "%s-headless" (include "redis-sentinel.fullname" .) }}
{{- end }}

{{/* Sentinel headless Service 이름 */}}
{{- define "redis-sentinel.sentinelHeadlessName" -}}
{{- printf "%s-sentinel-headless" (include "redis-sentinel.fullname" .) }}
{{- end }}

{{/* Secret 이름 */}}
{{- define "redis-sentinel.secretName" -}}
{{- printf "%s-secret" (include "redis-sentinel.fullname" .) }}
{{- end }}

{{/* Redis ConfigMap 이름 */}}
{{- define "redis-sentinel.redisConfigName" -}}
{{- printf "%s-redis-config" (include "redis-sentinel.fullname" .) }}
{{- end }}

{{/* Sentinel ConfigMap 이름 */}}
{{- define "redis-sentinel.sentinelConfigName" -}}
{{- printf "%s-sentinel-config" (include "redis-sentinel.fullname" .) }}
{{- end }}

{{/* Scripts ConfigMap 이름 */}}
{{- define "redis-sentinel.scriptsName" -}}
{{- printf "%s-scripts" (include "redis-sentinel.fullname" .) }}
{{- end }}

{{/* 컨테이너 이미지 전체 경로 */}}
{{- define "redis-sentinel.image" -}}
{{- printf "%s/%s:%s" .Values.global.imageRegistry .Values.image.repository .Values.image.tag }}
{{- end }}

{{/* 공통 레이블 */}}
{{- define "redis-sentinel.labels" -}}
helm.sh/chart: {{ include "redis-sentinel.name" . }}-{{ .Chart.Version }}
app.kubernetes.io/name: {{ include "redis-sentinel.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
