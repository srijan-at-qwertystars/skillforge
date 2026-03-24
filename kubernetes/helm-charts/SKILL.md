---
name: helm-charts
description: >
  Create, debug, and manage Helm charts for Kubernetes deployments.
  Use when: user mentions "Helm chart", "helm install", "helm upgrade",
  "helm template", "helm lint", "chart values", "values.yaml override",
  "helm dependency", "helm repo", "chart repository", "helm hooks",
  "helm test", "helm secrets", "subchart", "library chart", "Chart.yaml",
  "_helpers.tpl", "helm rollback", "helm package", "OCI helm registry",
  "helm uninstall", "helm create", "helm plugin", "chart museum",
  "helm diff", "helmfile", or Go template issues in Kubernetes context.
  Do NOT use for: plain Kubernetes YAML without Helm, Kustomize overlays,
  kubectl-only operations, Docker Compose files, Skaffold configs,
  Terraform HCL for infrastructure, Pulumi programs, or generic
  Go template questions outside Helm/Kubernetes context.
---

# Helm Charts — Production Reference

## Chart Structure

Standard layout for every chart:

```
mychart/
├── Chart.yaml            # Chart metadata, version, dependencies
├── Chart.lock            # Locked dependency versions
├── values.yaml           # Default configuration values
├── values.schema.json    # JSON Schema for values validation
├── .helmignore           # Files to exclude from packaging
├── README.md             # Chart documentation
├── LICENSE
├── charts/               # Dependency chart archives (.tgz)
├── crds/                 # CRD manifests (applied before templates)
└── templates/
    ├── _helpers.tpl      # Named template definitions
    ├── NOTES.txt         # Post-install usage notes
    ├── deployment.yaml
    ├── service.yaml
    ├── ingress.yaml
    ├── hpa.yaml
    ├── serviceaccount.yaml
    ├── configmap.yaml
    ├── secret.yaml
    ├── pdb.yaml
    └── tests/
        └── test-connection.yaml
```

### Chart.yaml

```yaml
apiVersion: v2
name: myapp
description: A production application chart
type: application          # or "library" for shared templates
version: 1.2.3            # Chart version — bump on every change
appVersion: "4.5.6"        # Application version (informational)
kubeVersion: ">=1.25.0"    # Enforce minimum cluster version
home: https://example.com
sources:
  - https://github.com/org/myapp
maintainers:
  - name: teamlead
    email: lead@example.com
dependencies:
  - name: postgresql
    version: "~12.1.0"        # Tilde range: 12.1.x
    repository: "https://charts.bitnami.com/bitnami"
    condition: postgresql.enabled
    alias: db
  - name: common
    version: "2.x.x"
    repository: "oci://registry.example.com/charts"
    tags:
      - backend
```

Run `helm dependency update` after changing dependencies. Use `helm dependency build` in CI.

## Template Language

Helm uses Go text/template with Sprig function library. Key syntax:

### Actions and Pipelines

```yaml
# Variable interpolation with pipeline
image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"

# Whitespace control: {{- trims left, -}} trims right
metadata:
  labels:
    {{- include "myapp.labels" . | nindent 4 }}

# Conditionals
{{- if .Values.ingress.enabled }}
apiVersion: networking.k8s.io/v1
kind: Ingress
...
{{- end }}

# Ternary pattern
replicas: {{ .Values.autoscaling.enabled | ternary 1 (.Values.replicaCount | int) }}
```

### Essential Functions

| Function | Purpose | Example |
|----------|---------|---------|
| `default` | Fallback value | `{{ .Values.port \| default 8080 }}` |
| `required` | Fail if missing | `{{ required "image.repo is required" .Values.image.repository }}` |
| `quote` | Wrap in quotes | `{{ .Values.env \| quote }}` |
| `toYaml` | Render as YAML | `{{ toYaml .Values.resources \| nindent 6 }}` |
| `nindent` | Newline + indent | `{{- include "labels" . \| nindent 4 }}` |
| `indent` | Indent (no newline) | `{{ .Values.config \| indent 8 }}` |
| `tpl` | Evaluate string as template | `{{ tpl .Values.annotation $ }}` |
| `lookup` | Query cluster resources | `{{ lookup "v1" "Secret" .Release.Namespace "x" }}` |
| `include` | Render named template as string | `{{ include "myapp.fullname" . }}` |
| `printf` | Format strings | `{{ printf "%s-%s" .Release.Name "app" }}` |
| `trimSuffix` | Remove suffix | `{{ .Values.host \| trimSuffix "/" }}` |
| `b64enc` | Base64 encode | `{{ .Values.password \| b64enc }}` |
| `sha256sum` | Hash for change detection | `checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . \| sha256sum }}` |

### Iteration

```yaml
# Range over list
env:
  {{- range .Values.env }}
  - name: {{ .name }}
    value: {{ .value | quote }}
  {{- end }}

# Range over map
{{- range $key, $val := .Values.annotations }}
{{ $key }}: {{ $val | quote }}
{{- end }}

# With — scopes the dot
{{- with .Values.nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
```

### Named Templates (_helpers.tpl)

```yaml
{{- define "myapp.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "myapp.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "myapp.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
```

Always use `include` (not `template`) so output can be piped to `nindent`/`quote`.

## Values Management

### values.yaml Conventions

```yaml
# -- Number of replicas (ignored when autoscaling.enabled=true)
replicaCount: 1

image:
  # -- Container image repository
  repository: myapp
  # -- Image pull policy
  pullPolicy: IfNotPresent
  # -- Image tag (defaults to chart appVersion)
  tag: ""

service:
  type: ClusterIP
  port: 80

ingress:
  enabled: false
  className: ""
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
  enabled: false
  minReplicas: 1
  maxReplicas: 10
  targetCPUUtilizationPercentage: 80
```

Rules: use camelCase keys. Comment every value. Quote all string values in templates. Show commented-out examples for complex defaults. Provide `values.schema.json` for validation.

### Override Hierarchy (lowest to highest)

1. Parent chart's `values.yaml`
2. Subchart's `values.yaml`
3. `-f values-prod.yaml` (left-to-right, last wins)
4. `--set key=value` / `--set-string` / `--set-file`
5. `--set-json '{"image":{"tag":"v2"}}'`

Per-environment pattern:

```bash
helm upgrade myapp ./mychart \
  -f values.yaml \
  -f values-prod.yaml \
  --set image.tag=sha-abc123 \
  -n production
```

### values.schema.json

```json
{
  "$schema": "https://json-schema.org/draft-07/schema#",
  "type": "object",
  "required": ["image"],
  "properties": {
    "replicaCount": { "type": "integer", "minimum": 1 },
    "image": {
      "type": "object",
      "required": ["repository"],
      "properties": {
        "repository": { "type": "string" },
        "tag": { "type": "string" }
      }
    }
  }
}
```

## Dependencies and Subcharts

Declare in `Chart.yaml` under `dependencies:`. Key fields: `name`, `version`, `repository`, `condition`, `tags`, `alias`, `import-values`.

```yaml
# Pass values to subchart
postgresql:
  enabled: true
  auth:
    postgresPassword: "secret"
    database: "mydb"

# Import values from subchart into parent scope
dependencies:
  - name: postgresql
    import-values:
      - child: service.port
        parent: dbPort
```

Global values propagate to all subcharts:

```yaml
global:
  imageRegistry: registry.example.com
  storageClass: gp3
```

Access in subchart: `{{ .Values.global.imageRegistry }}`.

## Hooks

Annotate resources to run at lifecycle points:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ include "myapp.fullname" . }}-migrate
  annotations:
    "helm.sh/hook": pre-upgrade,pre-install
    "helm.sh/hook-weight": "-5"          # Lower runs first
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: migrate
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          command: ["./migrate", "--up"]
```

Hook types: `pre-install`, `post-install`, `pre-delete`, `post-delete`, `pre-upgrade`, `post-upgrade`, `pre-rollback`, `post-rollback`, `test`.

Delete policies: `before-hook-creation` (default safe choice), `hook-succeeded`, `hook-failed`.

Set `hook-weight` as string integers to control execution order.

## Chart Testing

### helm test

Place test pods in `templates/tests/`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: {{ include "myapp.fullname" . }}-test
  labels:
    {{- include "myapp.labels" . | nindent 4 }}
  annotations:
    "helm.sh/hook": test
spec:
  restartPolicy: Never
  containers:
    - name: test
      image: busybox:1.36
      command: ['sh', '-c', 'wget -qO- http://{{ include "myapp.fullname" . }}:{{ .Values.service.port }}/healthz']
```

Run: `helm test myrelease -n mynamespace`.

### CI/CD Validation Pipeline

```bash
# Lint chart
helm lint ./mychart --values values-prod.yaml --strict

# Render templates locally (catch errors before deploy)
helm template myrelease ./mychart -f values-prod.yaml --validate

# Validate rendered manifests against schemas
helm template myrelease ./mychart | kubeconform -strict -kubernetes-version 1.29.0

# Dry-run against cluster API
helm upgrade myrelease ./mychart --install --dry-run=server -n prod

# Diff before apply (requires helm-diff plugin)
helm diff upgrade myrelease ./mychart -f values-prod.yaml -n prod
```

## Chart Repositories

### OCI Registry (preferred)

```bash
# Login
helm registry login registry.example.com -u user

# Package and push
helm package ./mychart
helm push mychart-1.2.3.tgz oci://registry.example.com/charts

# Install from OCI
helm install myrelease oci://registry.example.com/charts/mychart --version 1.2.3
```

### Classic HTTP Repository

```bash
# Add repo
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

# Generate index for hosting
helm package ./mychart -d repo/
helm repo index repo/ --url https://charts.example.com
```

## Secrets Management

Never commit plaintext secrets in values files. Strategies:

1. **External Secrets Operator** — sync from AWS SM, Vault, GCP SM via `ExternalSecret` CRD.
2. **helm-secrets plugin** — encrypt values files with SOPS/age: `helm secrets install rel ./mychart -f values-secrets.yaml`.
3. **Sealed Secrets** — encrypt with cluster public key, commit encrypted `SealedSecret` safely.
4. **CI `--set`** — inject from pipeline variables: `helm upgrade ... --set db.password=$DB_PASSWORD`.

## Production Best Practices

### Security Defaults

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 65534
  fsGroup: 65534
  seccompProfile:
    type: RuntimeDefault

containerSecurityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop: [ALL]
```

### Resource Management

Always set resource requests. Use LimitRange as cluster safety net. Set `resources` via values with sensible commented-out defaults.

### Availability

- Set PodDisruptionBudget: `minAvailable: 1` or `maxUnavailable: 25%`.
- Use `topologySpreadConstraints` over `podAntiAffinity` for even distribution.
- Add readiness, liveness, and startup probes.
- Pin images by digest in production: `image: myapp@sha256:abc123...`.

### Rollout Safety

```bash
# Atomic upgrade — auto-rollback on failure
helm upgrade myrelease ./mychart --install --atomic --timeout 5m

# Force pod restart on config change (add to deployment annotations)
checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
```

### Chart Hygiene

- Run `helm lint --strict` in CI.
- Version the chart (semver) independently from appVersion.
- Keep `NOTES.txt` useful — show access URLs, credentials hints.
- Use `.helmignore` to exclude CI files, tests, docs from package.
- Document all values with `helm-docs` or inline `# --` comments.

## Common Patterns

### Library Charts

Create shared templates (`type: library` in Chart.yaml) consumed by multiple charts. Define reusable named templates for deployments, services, labels. Consuming chart adds library as dependency and calls `{{ include "common-lib.deployment" . }}`.

### CRD Management

Place CRDs in `crds/` directory — Helm installs them before templates but never upgrades or deletes them. For CRD lifecycle control, use a separate CRD chart or operator.

### Conditional Resources

```yaml
{{- if .Values.serviceMonitor.enabled }}
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: {{ include "myapp.fullname" . }}
spec:
  selector:
    matchLabels: {{- include "myapp.selectorLabels" . | nindent 6 }}
  endpoints:
    - port: metrics
      interval: {{ .Values.serviceMonitor.interval | default "30s" }}
{{- end }}
```

### Multi-container Pods

Add sidecars conditionally with `{{- if .Values.sidecar.enabled }}` blocks containing name, image, and resources from values.

## Quick Command Reference

```bash
helm create mychart                        # Scaffold new chart
helm install rel ./mychart -n ns           # Install release
helm upgrade rel ./mychart --install -n ns # Upgrade or install
helm rollback rel 2 -n ns                  # Rollback to revision 2
helm uninstall rel -n ns                   # Remove release
helm template rel ./mychart -f vals.yaml   # Local render
helm lint ./mychart --strict               # Validate chart
helm package ./mychart                     # Create .tgz archive
helm show values repo/chart                # Print default values
helm get values rel -n ns -a              # Get computed values
helm history rel -n ns                     # Show release history
helm dependency update ./mychart           # Fetch/update deps
helm test rel -n ns                        # Run chart tests
helm plugin install <url>                  # Install plugin
```
