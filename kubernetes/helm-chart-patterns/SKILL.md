---
name: helm-chart-patterns
description:
  positive: "Use when user creates or modifies Helm charts, asks about chart templates, values.yaml design, Helm template functions, chart dependencies, hooks, or Helm release management."
  negative: "Do NOT use for raw Kubernetes YAML manifests without Helm, Kustomize, or other K8s package managers. Do NOT use for Docker or container runtime questions."
---

# Helm Chart Patterns

## Chart Directory Structure
```
mychart/
├── Chart.yaml           # Metadata, version, dependencies
├── Chart.lock           # Locked dependency versions
├── values.yaml          # Default configuration
├── values.schema.json   # JSON Schema validation
├── templates/
│   ├── _helpers.tpl     # Named template definitions
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── ingress.yaml
│   ├── NOTES.txt        # Post-install instructions
│   └── tests/
│       └── test-connection.yaml
├── charts/              # Subcharts (.tgz or dirs)
├── crds/                # CRDs (applied before templates)
└── README.md
```

Minimal `Chart.yaml`:
```yaml
apiVersion: v2
name: myapp
version: 1.0.0
appVersion: "2.5.0"
type: application   # or "library" for template-only charts
```

## Template Functions and Pipelines

```yaml
# default — fallback value
image: {{ .Values.image.tag | default .Chart.AppVersion }}
# required — fail if value missing
namespace: {{ required "namespace is required" .Values.namespace }}
# toYaml + nindent — render nested structures (prefer nindent over indent)
resources:
  {{- toYaml .Values.resources | nindent 10 }}
# tpl — render a string as a template
annotations:
  {{- tpl .Values.customAnnotation . | nindent 4 }}
# include — call named template (pipeable, unlike `template`)
labels:
  {{- include "myapp.labels" . | nindent 4 }}
# lookup — query live cluster state
{{- $secret := lookup "v1" "Secret" .Release.Namespace "my-secret" }}
{{- if $secret }}
  # Secret already exists
{{- end }}
# Truncate and sanitize names (63-char K8s limit)
name: {{ printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" }}
# Range over maps
{{- range $key, $val := .Values.env }}
- name: {{ $key }}
  value: {{ $val | quote }}
{{- end }}
# Ternary
replicas: {{ ternary 1 .Values.replicaCount .Values.autoscaling.enabled }}
```

## Named Templates (_helpers.tpl)

```yaml
{{- define "myapp.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

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

{{- define "myapp.labels" -}}
helm.sh/chart: {{ include "myapp.chart" . }}
{{ include "myapp.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "myapp.selectorLabels" -}}
app.kubernetes.io/name: {{ include "myapp.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "myapp.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "myapp.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "myapp.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}
```

## values.yaml Design

```yaml
replicaCount: 1
image:
  repository: myapp
  pullPolicy: IfNotPresent
  tag: ""                    # Default: Chart appVersion
imagePullSecrets: []
nameOverride: ""
fullnameOverride: ""
serviceAccount: {create: true, annotations: {}, name: ""}
service: {type: ClusterIP, port: 80}
ingress:
  enabled: false
  className: ""
  hosts:
    - host: chart-example.local
      paths: [{path: /, pathType: ImplementationSpecific}]
  tls: []
resources: {}
autoscaling: {enabled: false, minReplicas: 1, maxReplicas: 10, targetCPUUtilizationPercentage: 80}
```

### Design Rules

- Keep nesting ≤ 3 levels. Flat structures simplify `--set` overrides.
- Comment values with `# --` for helm-docs. Provide safe defaults.
- Treat `values.yaml` as a public API — changing keys is breaking.
- Add `values.schema.json` for type enforcement. Use `{}` or `[]` for optional complex values.
- Use `existingSecret` pattern for credentials:

```yaml
auth:
  existingSecret: ""     # Use existing secret (key: password)
  password: ""           # Ignored if existingSecret is set
```

## Chart Dependencies and Subcharts

### Declaring Dependencies

```yaml
# Chart.yaml
dependencies:
  - name: postgresql
    version: "12.x.x"
    repository: https://charts.bitnami.com/bitnami
    condition: postgresql.enabled
    tags: [database]
  - name: redis
    version: "17.x.x"
    repository: https://charts.bitnami.com/bitnami
    alias: cache
    import-values:
      - child: primary
        parent: redis
```

Manage: `helm dependency update ./mychart` (fetch+lock) | `helm dependency build` (from lock).

Pass values to subcharts by prefixing with dependency name or alias:

```yaml
postgresql:
  enabled: true
  auth: {postgresPassword: "changeme", database: myapp}
cache:
  architecture: standalone
```

### Rules

- Pin versions with ranges (`12.x.x`) or exact. Never `*`.
- Use `condition` to disable subcharts. Use `tags` to group optional features.
- Use `alias` when including the same chart multiple times.

## Hooks

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ include "myapp.fullname" . }}-db-migrate
  annotations:
    "helm.sh/hook": pre-upgrade,pre-install
    "helm.sh/hook-weight": "-5"
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: migrate
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          command: ["./migrate", "up"]
```

Available: `pre-install` | `post-install` | `pre-upgrade` | `post-upgrade` | `pre-delete` | `post-delete` | `pre-rollback` | `post-rollback` | `test`

Delete policies: `before-hook-creation` (default) | `hook-succeeded` | `hook-failed`

- Make hooks idempotent — they may re-run on retries.
- Set `hook-weight` for ordering (lower = earlier).
- Always set a delete policy to prevent orphaned resources.

## Testing

### Render and Lint

```bash
helm template myrelease ./mychart -f values-test.yaml          # Render locally
helm template myrelease ./mychart --validate                    # With schema validation
helm lint ./mychart --strict --values values-prod.yaml          # Lint for errors
```

### helm test

Place test pods in `templates/tests/`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: {{ include "myapp.fullname" . }}-test
  annotations:
    "helm.sh/hook": test
spec:
  restartPolicy: Never
  containers:
    - name: curl-test
      image: curlimages/curl:8.5.0
      command: ['curl', '--fail', '{{ include "myapp.fullname" . }}:{{ .Values.service.port }}']
```

### helm-unittest

Install: `helm plugin install https://github.com/helm-unittest/helm-unittest`

```yaml
# tests/deployment_test.yaml
suite: deployment tests
templates:
  - deployment.yaml
tests:
  - it: should set replicas
    set:
      replicaCount: 3
    asserts:
      - equal:
          path: spec.replicas
          value: 3
  - it: should use correct image
    set:
      image.repository: nginx
      image.tag: "1.25"
    asserts:
      - equal:
          path: spec.template.spec.containers[0].image
          value: "nginx:1.25"
  - it: should fail without required value
    set:
      requiredField: null
    asserts:
      - failedTemplate: {}
```

Run: `helm unittest ./mychart`

### chart-testing (ct)

```bash
ct lint --target-branch main                    # Lint changed charts
ct install --target-branch main --upgrade       # Install and test
```

Integrate `ct` in CI — it detects changed charts, lints, installs into a Kind cluster, and runs `helm test`.

## Release Management

```bash
helm install myrelease ./mychart -n ns --create-namespace -f values-prod.yaml --wait --timeout 5m
helm upgrade myrelease ./mychart -n ns -f values-prod.yaml --atomic --timeout 5m
helm rollback myrelease 0 -n ns --wait
helm diff upgrade myrelease ./mychart -f values-prod.yaml    # requires helm-diff plugin
helm uninstall myrelease -n ns --keep-history
```

| Flag | Purpose |
|------|---------|
| `--atomic` | Auto-rollback on failed upgrade |
| `--wait` | Wait for pods ready |
| `--timeout` | Max wait time |
| `--dry-run` | Simulate without applying |
| `--force` | Delete/recreate resources |
| `--cleanup-on-fail` | Delete new resources on failure |

### Rules

- Always use `--atomic` in production CI/CD.
- Use `helm diff` before every upgrade.
- Store release history (`--keep-history`) for audit trails.

## Security

### securityContext Defaults

```yaml
# values.yaml
podSecurityContext:
  runAsNonRoot: true
  runAsUser: 1000
  runAsGroup: 1000
  fsGroup: 1000
containerSecurityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop: ["ALL"]
```

```yaml
# templates/deployment.yaml
spec:
  template:
    spec:
      securityContext:
        {{- toYaml .Values.podSecurityContext | nindent 8 }}
      containers:
        - name: {{ .Chart.Name }}
          securityContext:
            {{- toYaml .Values.containerSecurityContext | nindent 12 }}
```

### RBAC Templates

```yaml
{{- if .Values.serviceAccount.create }}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "myapp.serviceAccountName" . }}
  labels: {{- include "myapp.labels" . | nindent 4 }}
  {{- with .Values.serviceAccount.annotations }}
  annotations: {{- toYaml . | nindent 4 }}
  {{- end }}
automountServiceAccountToken: {{ .Values.serviceAccount.automount | default false }}
{{- end }}
---
{{- if .Values.rbac.create }}
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: {{ include "myapp.fullname" . }}
rules: {{- toYaml .Values.rbac.rules | nindent 2 }}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: {{ include "myapp.fullname" . }}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: {{ include "myapp.fullname" . }}
subjects:
  - kind: ServiceAccount
    name: {{ include "myapp.serviceAccountName" . }}
    namespace: {{ .Release.Namespace }}
{{- end }}
```

### NetworkPolicy

```yaml
{{- if .Values.networkPolicy.enabled }}
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: {{ include "myapp.fullname" . }}
spec:
  podSelector:
    matchLabels: {{- include "myapp.selectorLabels" . | nindent 6 }}
  policyTypes: [Ingress, Egress]
  ingress:
    - from:
        - podSelector:
            matchLabels: {{- toYaml .Values.networkPolicy.allowFrom | nindent 14 }}
      ports:
        - port: {{ .Values.service.port }}
  egress:
    - ports: [{port: 53, protocol: UDP}, {port: 53, protocol: TCP}]
{{- end }}
```

### Security Rules

- Default to non-root, read-only filesystem, drop all capabilities.
- Set `automountServiceAccountToken: false` unless needed.
- Use namespace-scoped Roles over ClusterRoles.
- Enable NetworkPolicy by default; deny-all then allow selectively.

## Common Patterns

### ConfigMap from Files

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "myapp.fullname" . }}-config
data:
  {{- range $path, $_ := .Files.Glob "config/**" }}
  {{ base $path }}: |- {{ $.Files.Get $path | nindent 4 }}
  {{- end }}
```

### Secret with existingSecret Pattern

```yaml
{{- if not .Values.auth.existingSecret }}
apiVersion: v1
kind: Secret
metadata:
  name: {{ include "myapp.fullname" . }}
type: Opaque
data:
  password: {{ .Values.auth.password | b64enc | quote }}
{{- end }}
```

### Init Container

```yaml
initContainers:
  {{- if .Values.waitForDB.enabled }}
  - name: wait-for-db
    image: busybox:1.36
    command: ['sh', '-c', 'until nc -z {{ .Values.database.host }} {{ .Values.database.port }}; do sleep 2; done']
  {{- end }}
```

### Sidecar Injection

```yaml
containers:
  - name: {{ .Chart.Name }}
  {{- if .Values.sidecar.enabled }}
  - name: {{ .Values.sidecar.name | default "sidecar" }}
    image: "{{ .Values.sidecar.image.repository }}:{{ .Values.sidecar.image.tag }}"
    {{- with .Values.sidecar.resources }}
    resources: {{- toYaml . | nindent 6 }}
    {{- end }}
  {{- end }}
```

### Optional Resources with `{{- with }}`

```yaml
{{- with .Values.tolerations }}
tolerations: {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.nodeSelector }}
nodeSelector: {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.affinity }}
affinity: {{- toYaml . | nindent 2 }}
{{- end }}
```

## Anti-Patterns and Fixes

| Anti-Pattern | Problem | Fix |
|---|---|---|
| `image.tag: latest` | Non-reproducible deploys | Pin immutable tags or digests |
| No `resources` set | Noisy neighbor, OOM kills | Set requests and limits defaults |
| Secrets in `values.yaml` | Credentials in Git | Use `existingSecret` pattern + external secret manager |
| Selector drift | Service routes to wrong pods | Define selectors in `_helpers.tpl`, reuse everywhere |
| Deep nesting (>3 levels) | `--set` overrides become unwieldy | Flatten structure, group only where logical |
| No `values.schema.json` | Invalid values reach deploy | Add JSON Schema, validate in CI |
| Skipping `helm lint` | Syntax errors hit production | Run `helm lint --strict` in CI |
| Mutable hook resources | Failed upgrades from leftover hooks | Set `hook-delete-policy: before-hook-creation` |
| Missing `--atomic` | Failed upgrades leave broken state | Always use `--atomic` in CI/CD |
| Hardcoded namespace | Chart not portable | Use `{{ .Release.Namespace }}`, never hardcode |
| No chart version bump | Broken rollbacks, cache issues | Bump `version` on every change |
| Using `template` not `include` | Output not pipeable | Use `include` for all named template calls |

<!-- tested: pass -->
