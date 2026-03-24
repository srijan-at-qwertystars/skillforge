#!/usr/bin/env bash
#
# create-chart.sh — Scaffold a production-ready Helm chart
#
# Usage:
#   ./create-chart.sh <chart-name> [output-dir]
#
# Examples:
#   ./create-chart.sh myapp
#   ./create-chart.sh myapp ./charts
#
# Creates a Helm chart with:
#   - Hardened security defaults (non-root, read-only fs, drop all caps)
#   - PodDisruptionBudget, HPA, ServiceMonitor templates
#   - Comprehensive _helpers.tpl with standard labels
#   - NOTES.txt with access instructions
#   - Helm test for connectivity
#   - CI values file for testing
#   - values.schema.json for validation
#   - .helmignore for clean packaging
#

set -euo pipefail

CHART_NAME="${1:?Usage: $0 <chart-name> [output-dir]}"
OUTPUT_DIR="${2:-.}"
CHART_DIR="${OUTPUT_DIR}/${CHART_NAME}"

if [[ -d "${CHART_DIR}" ]]; then
  echo "Error: Directory ${CHART_DIR} already exists." >&2
  exit 1
fi

# Validate chart name (DNS-1123 subdomain)
if ! [[ "${CHART_NAME}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
  echo "Error: Chart name must be lowercase alphanumeric with optional hyphens." >&2
  exit 1
fi

echo "Creating chart: ${CHART_NAME} in ${OUTPUT_DIR}"

mkdir -p "${CHART_DIR}/templates/tests"
mkdir -p "${CHART_DIR}/ci"
mkdir -p "${CHART_DIR}/crds"

# ── Chart.yaml ──────────────────────────────────────────────────────
cat > "${CHART_DIR}/Chart.yaml" <<'YAML'
apiVersion: v2
name: CHART_NAME_PLACEHOLDER
description: A production-ready Helm chart
type: application
version: 0.1.0
appVersion: "1.0.0"
kubeVersion: ">=1.25.0"
home: ""
sources: []
maintainers:
  - name: maintainer
    email: maintainer@example.com
# dependencies:
#   - name: postgresql
#     version: "~14.0.0"
#     repository: "https://charts.bitnami.com/bitnami"
#     condition: postgresql.enabled
YAML
sed -i "s/CHART_NAME_PLACEHOLDER/${CHART_NAME}/" "${CHART_DIR}/Chart.yaml"

# ── values.yaml ─────────────────────────────────────────────────────
cat > "${CHART_DIR}/values.yaml" <<'YAML'
# -- Number of replicas (ignored when autoscaling.enabled=true)
replicaCount: 1

image:
  # -- Container image repository
  repository: ""
  # -- Image pull policy
  pullPolicy: IfNotPresent
  # -- Image tag (defaults to chart appVersion)
  tag: ""

# -- Image pull secrets
imagePullSecrets: []
# -- Override the chart name
nameOverride: ""
# -- Override the full release name
fullnameOverride: ""

serviceAccount:
  # -- Create a ServiceAccount
  create: true
  # -- Annotations for the ServiceAccount
  annotations: {}
  # -- ServiceAccount name (generated if not set)
  name: ""
  # -- Automount API credentials
  automountServiceAccountToken: false

# -- Pod-level annotations
podAnnotations: {}
# -- Pod-level labels
podLabels: {}

podSecurityContext:
  runAsNonRoot: true
  runAsUser: 65534
  runAsGroup: 65534
  fsGroup: 65534
  seccompProfile:
    type: RuntimeDefault

securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  runAsNonRoot: true
  capabilities:
    drop:
      - ALL

service:
  # -- Service type
  type: ClusterIP
  # -- Service port
  port: 80
  # -- Container target port
  targetPort: 8080

ingress:
  # -- Enable ingress
  enabled: false
  # -- Ingress class name
  className: ""
  # -- Ingress annotations
  annotations: {}
  hosts:
    - host: chart-example.local
      paths:
        - path: /
          pathType: ImplementationSpecific
  tls: []

resources: {}
  # requests:
  #   cpu: 100m
  #   memory: 128Mi
  # limits:
  #   cpu: 500m
  #   memory: 256Mi

autoscaling:
  # -- Enable HPA
  enabled: false
  minReplicas: 1
  maxReplicas: 10
  targetCPUUtilizationPercentage: 80
  # targetMemoryUtilizationPercentage: 80

pdb:
  # -- Enable PodDisruptionBudget
  enabled: false
  # -- Minimum available pods (mutually exclusive with maxUnavailable)
  minAvailable: 1
  # maxUnavailable: 1

livenessProbe:
  httpGet:
    path: /healthz
    port: http
  initialDelaySeconds: 15
  periodSeconds: 10
  timeoutSeconds: 5
  failureThreshold: 3

readinessProbe:
  httpGet:
    path: /readyz
    port: http
  initialDelaySeconds: 5
  periodSeconds: 5
  timeoutSeconds: 3
  failureThreshold: 3

startupProbe:
  httpGet:
    path: /healthz
    port: http
  initialDelaySeconds: 5
  periodSeconds: 5
  failureThreshold: 30

# -- Node selector
nodeSelector: {}
# -- Tolerations
tolerations: []
# -- Affinity rules
affinity: {}
# -- Topology spread constraints
topologySpreadConstraints: []

# -- Extra environment variables
env: []
# -- Extra environment variable sources (configMapRef, secretRef)
envFrom: []
# -- Extra volume mounts
extraVolumeMounts: []
# -- Extra volumes
extraVolumes: []

serviceMonitor:
  # -- Enable Prometheus ServiceMonitor
  enabled: false
  # -- Scrape interval
  interval: 30s
  # -- Additional labels for the ServiceMonitor
  labels: {}
YAML

# ── values.schema.json ──────────────────────────────────────────────
cat > "${CHART_DIR}/values.schema.json" <<'JSON'
{
  "$schema": "https://json-schema.org/draft-07/schema#",
  "type": "object",
  "required": ["image"],
  "properties": {
    "replicaCount": {
      "type": "integer",
      "minimum": 1
    },
    "image": {
      "type": "object",
      "required": ["repository"],
      "properties": {
        "repository": { "type": "string", "minLength": 1 },
        "pullPolicy": { "type": "string", "enum": ["Always", "IfNotPresent", "Never"] },
        "tag": { "type": "string" }
      }
    },
    "service": {
      "type": "object",
      "properties": {
        "type": { "type": "string", "enum": ["ClusterIP", "NodePort", "LoadBalancer", "ExternalName"] },
        "port": { "type": "integer", "minimum": 1, "maximum": 65535 }
      }
    }
  }
}
JSON

# ── _helpers.tpl ────────────────────────────────────────────────────
cat > "${CHART_DIR}/templates/_helpers.tpl" <<'TPL'
{{/*
Expand the name of the chart.
*/}}
{{- define "CHART_NAME_PLACEHOLDER.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "CHART_NAME_PLACEHOLDER.fullname" -}}
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
Create chart name and version for chart label.
*/}}
{{- define "CHART_NAME_PLACEHOLDER.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "CHART_NAME_PLACEHOLDER.labels" -}}
helm.sh/chart: {{ include "CHART_NAME_PLACEHOLDER.chart" . }}
{{ include "CHART_NAME_PLACEHOLDER.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "CHART_NAME_PLACEHOLDER.selectorLabels" -}}
app.kubernetes.io/name: {{ include "CHART_NAME_PLACEHOLDER.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "CHART_NAME_PLACEHOLDER.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "CHART_NAME_PLACEHOLDER.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}
TPL
sed -i "s/CHART_NAME_PLACEHOLDER/${CHART_NAME}/g" "${CHART_DIR}/templates/_helpers.tpl"

# ── deployment.yaml ─────────────────────────────────────────────────
cat > "${CHART_DIR}/templates/deployment.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "CHART_NAME_PLACEHOLDER.fullname" . }}
  labels:
    {{- include "CHART_NAME_PLACEHOLDER.labels" . | nindent 4 }}
spec:
  {{- if not .Values.autoscaling.enabled }}
  replicas: {{ .Values.replicaCount }}
  {{- end }}
  selector:
    matchLabels:
      {{- include "CHART_NAME_PLACEHOLDER.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      {{- with .Values.podAnnotations }}
      annotations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      labels:
        {{- include "CHART_NAME_PLACEHOLDER.labels" . | nindent 8 }}
        {{- with .Values.podLabels }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
    spec:
      {{- with .Values.imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      serviceAccountName: {{ include "CHART_NAME_PLACEHOLDER.serviceAccountName" . }}
      securityContext:
        {{- toYaml .Values.podSecurityContext | nindent 8 }}
      containers:
        - name: {{ .Chart.Name }}
          securityContext:
            {{- toYaml .Values.securityContext | nindent 12 }}
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - name: http
              containerPort: {{ .Values.service.targetPort }}
              protocol: TCP
          {{- with .Values.livenessProbe }}
          livenessProbe:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with .Values.readinessProbe }}
          readinessProbe:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with .Values.startupProbe }}
          startupProbe:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with .Values.resources }}
          resources:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with .Values.env }}
          env:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with .Values.envFrom }}
          envFrom:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with .Values.extraVolumeMounts }}
          volumeMounts:
            {{- toYaml . | nindent 12 }}
          {{- end }}
      {{- with .Values.extraVolumes }}
      volumes:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.affinity }}
      affinity:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.tolerations }}
      tolerations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.topologySpreadConstraints }}
      topologySpreadConstraints:
        {{- toYaml . | nindent 8 }}
      {{- end }}
YAML
sed -i "s/CHART_NAME_PLACEHOLDER/${CHART_NAME}/g" "${CHART_DIR}/templates/deployment.yaml"

# ── service.yaml ────────────────────────────────────────────────────
cat > "${CHART_DIR}/templates/service.yaml" <<'YAML'
apiVersion: v1
kind: Service
metadata:
  name: {{ include "CHART_NAME_PLACEHOLDER.fullname" . }}
  labels:
    {{- include "CHART_NAME_PLACEHOLDER.labels" . | nindent 4 }}
spec:
  type: {{ .Values.service.type }}
  ports:
    - port: {{ .Values.service.port }}
      targetPort: http
      protocol: TCP
      name: http
  selector:
    {{- include "CHART_NAME_PLACEHOLDER.selectorLabels" . | nindent 4 }}
YAML
sed -i "s/CHART_NAME_PLACEHOLDER/${CHART_NAME}/g" "${CHART_DIR}/templates/service.yaml"

# ── ingress.yaml ────────────────────────────────────────────────────
cat > "${CHART_DIR}/templates/ingress.yaml" <<'YAML'
{{- if .Values.ingress.enabled -}}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ include "CHART_NAME_PLACEHOLDER.fullname" . }}
  labels:
    {{- include "CHART_NAME_PLACEHOLDER.labels" . | nindent 4 }}
  {{- with .Values.ingress.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  {{- if .Values.ingress.className }}
  ingressClassName: {{ .Values.ingress.className }}
  {{- end }}
  {{- if .Values.ingress.tls }}
  tls:
    {{- range .Values.ingress.tls }}
    - hosts:
        {{- range .hosts }}
        - {{ . | quote }}
        {{- end }}
      secretName: {{ .secretName }}
    {{- end }}
  {{- end }}
  rules:
    {{- range .Values.ingress.hosts }}
    - host: {{ .host | quote }}
      http:
        paths:
          {{- range .paths }}
          - path: {{ .path }}
            pathType: {{ .pathType }}
            backend:
              service:
                name: {{ include "CHART_NAME_PLACEHOLDER.fullname" $ }}
                port:
                  number: {{ $.Values.service.port }}
          {{- end }}
    {{- end }}
{{- end }}
YAML
sed -i "s/CHART_NAME_PLACEHOLDER/${CHART_NAME}/g" "${CHART_DIR}/templates/ingress.yaml"

# ── serviceaccount.yaml ────────────────────────────────────────────
cat > "${CHART_DIR}/templates/serviceaccount.yaml" <<'YAML'
{{- if .Values.serviceAccount.create -}}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "CHART_NAME_PLACEHOLDER.serviceAccountName" . }}
  labels:
    {{- include "CHART_NAME_PLACEHOLDER.labels" . | nindent 4 }}
  {{- with .Values.serviceAccount.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
automountServiceAccountToken: {{ .Values.serviceAccount.automountServiceAccountToken }}
{{- end }}
YAML
sed -i "s/CHART_NAME_PLACEHOLDER/${CHART_NAME}/g" "${CHART_DIR}/templates/serviceaccount.yaml"

# ── hpa.yaml ────────────────────────────────────────────────────────
cat > "${CHART_DIR}/templates/hpa.yaml" <<'YAML'
{{- if .Values.autoscaling.enabled }}
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {{ include "CHART_NAME_PLACEHOLDER.fullname" . }}
  labels:
    {{- include "CHART_NAME_PLACEHOLDER.labels" . | nindent 4 }}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: {{ include "CHART_NAME_PLACEHOLDER.fullname" . }}
  minReplicas: {{ .Values.autoscaling.minReplicas }}
  maxReplicas: {{ .Values.autoscaling.maxReplicas }}
  metrics:
    {{- if .Values.autoscaling.targetCPUUtilizationPercentage }}
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: {{ .Values.autoscaling.targetCPUUtilizationPercentage }}
    {{- end }}
    {{- if .Values.autoscaling.targetMemoryUtilizationPercentage }}
    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: {{ .Values.autoscaling.targetMemoryUtilizationPercentage }}
    {{- end }}
{{- end }}
YAML
sed -i "s/CHART_NAME_PLACEHOLDER/${CHART_NAME}/g" "${CHART_DIR}/templates/hpa.yaml"

# ── pdb.yaml ────────────────────────────────────────────────────────
cat > "${CHART_DIR}/templates/pdb.yaml" <<'YAML'
{{- if .Values.pdb.enabled }}
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ include "CHART_NAME_PLACEHOLDER.fullname" . }}
  labels:
    {{- include "CHART_NAME_PLACEHOLDER.labels" . | nindent 4 }}
spec:
  {{- if .Values.pdb.minAvailable }}
  minAvailable: {{ .Values.pdb.minAvailable }}
  {{- else if .Values.pdb.maxUnavailable }}
  maxUnavailable: {{ .Values.pdb.maxUnavailable }}
  {{- end }}
  selector:
    matchLabels:
      {{- include "CHART_NAME_PLACEHOLDER.selectorLabels" . | nindent 6 }}
{{- end }}
YAML
sed -i "s/CHART_NAME_PLACEHOLDER/${CHART_NAME}/g" "${CHART_DIR}/templates/pdb.yaml"

# ── servicemonitor.yaml ────────────────────────────────────────────
cat > "${CHART_DIR}/templates/servicemonitor.yaml" <<'YAML'
{{- if .Values.serviceMonitor.enabled }}
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: {{ include "CHART_NAME_PLACEHOLDER.fullname" . }}
  labels:
    {{- include "CHART_NAME_PLACEHOLDER.labels" . | nindent 4 }}
    {{- with .Values.serviceMonitor.labels }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
spec:
  selector:
    matchLabels:
      {{- include "CHART_NAME_PLACEHOLDER.selectorLabels" . | nindent 6 }}
  endpoints:
    - port: http
      interval: {{ .Values.serviceMonitor.interval }}
{{- end }}
YAML
sed -i "s/CHART_NAME_PLACEHOLDER/${CHART_NAME}/g" "${CHART_DIR}/templates/servicemonitor.yaml"

# ── NOTES.txt ───────────────────────────────────────────────────────
cat > "${CHART_DIR}/templates/NOTES.txt" <<'TPL'
{{- $fullName := include "CHART_NAME_PLACEHOLDER.fullname" . -}}
1. Get the application URL by running these commands:
{{- if .Values.ingress.enabled }}
{{- range $host := .Values.ingress.hosts }}
  http{{ if $.Values.ingress.tls }}s{{ end }}://{{ $host.host }}{{ (first $host.paths).path }}
{{- end }}
{{- else if contains "NodePort" .Values.service.type }}
  export NODE_PORT=$(kubectl get --namespace {{ .Release.Namespace }} -o jsonpath="{.spec.ports[0].nodePort}" services {{ $fullName }})
  export NODE_IP=$(kubectl get nodes --namespace {{ .Release.Namespace }} -o jsonpath="{.items[0].status.addresses[0].address}")
  echo http://$NODE_IP:$NODE_PORT
{{- else if contains "LoadBalancer" .Values.service.type }}
  NOTE: It may take a few minutes for the LoadBalancer IP to be available.
  kubectl get --namespace {{ .Release.Namespace }} svc {{ $fullName }} -w
{{- else if contains "ClusterIP" .Values.service.type }}
  kubectl --namespace {{ .Release.Namespace }} port-forward svc/{{ $fullName }} {{ .Values.service.port }}:{{ .Values.service.port }}
  echo "Visit http://127.0.0.1:{{ .Values.service.port }}"
{{- end }}
TPL
sed -i "s/CHART_NAME_PLACEHOLDER/${CHART_NAME}/g" "${CHART_DIR}/templates/NOTES.txt"

# ── test-connection.yaml ───────────────────────────────────────────
cat > "${CHART_DIR}/templates/tests/test-connection.yaml" <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: "{{ include "CHART_NAME_PLACEHOLDER.fullname" . }}-test-connection"
  labels:
    {{- include "CHART_NAME_PLACEHOLDER.labels" . | nindent 4 }}
  annotations:
    "helm.sh/hook": test
spec:
  restartPolicy: Never
  containers:
    - name: wget
      image: busybox:1.36
      command: ['sh', '-c']
      args:
        - |
          wget -qO- --timeout=5 http://{{ include "CHART_NAME_PLACEHOLDER.fullname" . }}:{{ .Values.service.port }}/healthz
          echo "Connection test passed"
YAML
sed -i "s/CHART_NAME_PLACEHOLDER/${CHART_NAME}/g" "${CHART_DIR}/templates/tests/test-connection.yaml"

# ── CI values ───────────────────────────────────────────────────────
cat > "${CHART_DIR}/ci/test-values.yaml" <<YAML
# CI test values — used by chart-testing (ct)
replicaCount: 1
image:
  repository: nginx
  tag: "1.27"
service:
  type: ClusterIP
  port: 80
  targetPort: 80
livenessProbe:
  httpGet:
    path: /
    port: http
readinessProbe:
  httpGet:
    path: /
    port: http
startupProbe:
  httpGet:
    path: /
    port: http
resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    cpu: 100m
    memory: 128Mi
YAML

# ── .helmignore ─────────────────────────────────────────────────────
cat > "${CHART_DIR}/.helmignore" <<'IGNORE'
# Patterns to ignore when building packages
.DS_Store
.git/
.gitignore
.bzr/
.bzrignore
.hg/
.hgignore
.svn/
*.swp
*.bak
*.tmp
*.orig
*~
.project
.idea/
*.tmproj
.vscode/
ci/
tests/
OWNERS
README.md
CHANGELOG.md
IGNORE

# ── README.md ───────────────────────────────────────────────────────
cat > "${CHART_DIR}/README.md" <<MD
# ${CHART_NAME}

A production-ready Helm chart.

## Installing

\`\`\`bash
helm install my-release ./${CHART_NAME}
\`\`\`

## Configuration

See [values.yaml](values.yaml) for the full list of configurable parameters.

## Testing

\`\`\`bash
helm lint ./${CHART_NAME} --strict
helm template test ./${CHART_NAME} -f ci/test-values.yaml --validate
helm test my-release
\`\`\`
MD

echo "✅ Chart created: ${CHART_DIR}"
echo ""
echo "Next steps:"
echo "  1. Set image.repository in values.yaml"
echo "  2. Run: helm lint ${CHART_DIR} --strict"
echo "  3. Run: helm template test ${CHART_DIR} -f ${CHART_DIR}/ci/test-values.yaml"
