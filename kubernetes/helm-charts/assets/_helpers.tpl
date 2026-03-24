{{/*
==========================================================================
Production-Ready Named Templates (_helpers.tpl)

Copy this file into your chart's templates/ directory and replace
"myapp" with your chart name throughout.
==========================================================================
*/}}

{{/*
Expand the name of the chart.
Truncate to 63 chars (Kubernetes name limit) and strip trailing hyphens.
*/}}
{{- define "myapp.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
If fullnameOverride is set, use it. Otherwise combine release name + chart name.
If release name already contains the chart name, don't duplicate it.
*/}}
{{- define "myapp.fullname" -}}
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

{{/*
Create chart name + version for the "helm.sh/chart" label.
Replace "+" with "_" for label compliance.
*/}}
{{- define "myapp.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels — applied to every resource.
Includes selector labels + Helm metadata labels.
Usage:
  metadata:
    labels:
      {{- include "myapp.labels" . | nindent 6 }}
*/}}
{{- define "myapp.labels" -}}
helm.sh/chart: {{ include "myapp.chart" . }}
{{ include "myapp.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Selector labels — used in spec.selector.matchLabels and pod labels.
These MUST NOT change between upgrades (immutable selectors).
Usage:
  spec:
    selector:
      matchLabels:
        {{- include "myapp.selectorLabels" . | nindent 8 }}
*/}}
{{- define "myapp.selectorLabels" -}}
app.kubernetes.io/name: {{ include "myapp.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Component labels — extend selector labels with a component identifier.
Usage:
  labels:
    {{- include "myapp.componentLabels" (dict "context" . "component" "worker") | nindent 4 }}
*/}}
{{- define "myapp.componentLabels" -}}
{{ include "myapp.selectorLabels" .context }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/*
Common annotations — applied to resources that need standard annotations.
Merges any user-provided commonAnnotations from values.
Usage:
  metadata:
    annotations:
      {{- include "myapp.annotations" . | nindent 6 }}
*/}}
{{- define "myapp.annotations" -}}
{{- with .Values.commonAnnotations }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Checksum annotations — force pod restart when ConfigMap/Secret changes.
Usage (in pod template metadata):
  annotations:
    {{- include "myapp.checksumAnnotations" . | nindent 8 }}
*/}}
{{- define "myapp.checksumAnnotations" -}}
{{- $configmap := print $.Template.BasePath "/configmap.yaml" }}
{{- $secret := print $.Template.BasePath "/secret.yaml" }}
{{- if .Template.BasePath }}
{{- if (lookup "v1" "ConfigMap" .Release.Namespace (include "myapp.fullname" .)) }}
checksum/config: {{ include $configmap . | sha256sum }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create the name of the service account to use.
If create is true and no name is given, use the fullname.
If create is false, use the given name or default to "default".
*/}}
{{- define "myapp.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "myapp.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Container image reference — combines repository, tag, and optional digest.
Supports global imageRegistry for umbrella charts.
Usage:
  image: {{ include "myapp.image" . }}
*/}}
{{- define "myapp.image" -}}
{{- $registry := .Values.global.imageRegistry | default "" -}}
{{- $repository := .Values.image.repository -}}
{{- $tag := .Values.image.tag | default .Chart.AppVersion -}}
{{- if .Values.image.digest -}}
  {{- if $registry -}}
    {{- printf "%s/%s@%s" $registry $repository .Values.image.digest -}}
  {{- else -}}
    {{- printf "%s@%s" $repository .Values.image.digest -}}
  {{- end -}}
{{- else -}}
  {{- if $registry -}}
    {{- printf "%s/%s:%s" $registry $repository $tag -}}
  {{- else -}}
    {{- printf "%s:%s" $repository $tag -}}
  {{- end -}}
{{- end -}}
{{- end }}

{{/*
Namespace — use release namespace. Useful for resources that need explicit namespace.
*/}}
{{- define "myapp.namespace" -}}
{{ .Release.Namespace }}
{{- end }}

{{/*
Resource name with component suffix.
Usage: {{ include "myapp.componentName" (dict "context" . "component" "worker") }}
*/}}
{{- define "myapp.componentName" -}}
{{- printf "%s-%s" (include "myapp.fullname" .context) .component | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Validate required values — call at top of critical templates.
Usage: {{ include "myapp.validateValues" . }}
*/}}
{{- define "myapp.validateValues" -}}
{{- if not .Values.image.repository -}}
  {{- fail "image.repository is required. Set it via --set image.repository=<repo> or in values.yaml" -}}
{{- end -}}
{{- end }}

{{/*
Pod security context defaults — returns a security context with sensible defaults.
Values from .Values.podSecurityContext override these defaults.
*/}}
{{- define "myapp.podSecurityContext" -}}
{{- $defaults := dict "runAsNonRoot" true "runAsUser" 65534 "runAsGroup" 65534 "fsGroup" 65534 "seccompProfile" (dict "type" "RuntimeDefault") -}}
{{- toYaml (merge (.Values.podSecurityContext | default dict) $defaults) }}
{{- end }}

{{/*
Container security context defaults.
*/}}
{{- define "myapp.containerSecurityContext" -}}
{{- $defaults := dict "allowPrivilegeEscalation" false "readOnlyRootFilesystem" true "runAsNonRoot" true "capabilities" (dict "drop" (list "ALL")) -}}
{{- toYaml (merge (.Values.securityContext | default dict) $defaults) }}
{{- end }}
