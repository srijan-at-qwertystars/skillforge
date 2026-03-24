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

- **Security defaults** — `runAsNonRoot: true`, `readOnlyRootFilesystem: true`, `capabilities.drop: [ALL]`, `seccompProfile: RuntimeDefault`. See [assets/_helpers.tpl](assets/_helpers.tpl) for ready-made templates.
- **Resources** — always set requests. Use LimitRange as cluster safety net. Provide commented-out defaults in values.yaml.
- **Availability** — PodDisruptionBudget (`minAvailable: 1`), `topologySpreadConstraints`, readiness/liveness/startup probes, pin images by digest.
- **Rollout safety** — `helm upgrade --atomic --timeout 5m` for auto-rollback. Add `checksum/config` annotation for config-change restarts.
- **Chart hygiene** — `helm lint --strict` in CI, semver chart versions, useful NOTES.txt, `.helmignore`, document all values.

## Common Patterns

- **Library charts** — `type: library` in Chart.yaml, shared named templates consumed via dependency. See [advanced-patterns.md](references/advanced-patterns.md).
- **Umbrella charts** — deploy full stack via dependencies, gate with `condition:` and `tags:`.
- **CRD management** — `crds/` dir for initial install; separate CRD chart or operator for lifecycle control.
- **Conditional resources** — guard with `{{- if .Values.feature.enabled }}`, check cluster capabilities with `.Capabilities.APIVersions.Has`.
- **Multi-container pods** — sidecars via `{{- if .Values.sidecar.enabled }}` blocks.
- **GitOps** — ArgoCD `Application` / Flux `HelmRelease` for declarative Helm. See [advanced-patterns.md](references/advanced-patterns.md).

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

## References

In-depth guides in `references/`:

| Reference | Contents |
|-----------|----------|
| [advanced-patterns.md](references/advanced-patterns.md) | Library charts, umbrella charts, CRD management, operator patterns, multi-cluster deployments, GitOps with ArgoCD/Flux, chart testing strategies (helm-unittest, ct, conftest), Helm Go SDK, advanced templating (dynamic resources, feature flags, post-renderer Kustomize) |
| [troubleshooting.md](references/troubleshooting.md) | Failed releases, stuck/pending releases, rollback problems, hook failures, template rendering errors, dependency issues, OCI registry problems, upgrade conflicts, values issues, namespace/RBAC issues, resource conflicts, performance/timeout issues, diagnostic commands |
| [template-functions.md](references/template-functions.md) | Complete Go template and Sprig function reference: string ops, math, date, defaults, encoding, crypto, list/dict manipulation, type conversion, flow control, named templates, regex, semver, UUID/random, `.Files` and `lookup` usage, common idioms |

## Scripts

Helper scripts in `scripts/` (all executable):

| Script | Purpose | Usage |
|--------|---------|-------|
| [create-chart.sh](scripts/create-chart.sh) | Scaffold a production-ready chart with hardened security defaults, PDB, HPA, ServiceMonitor, tests, CI values, and schema | `./scripts/create-chart.sh myapp [output-dir]` |
| [lint-chart.sh](scripts/lint-chart.sh) | Run helm lint, kubeconform, chart-testing, and custom validation (security, semver, structure checks) | `./scripts/lint-chart.sh ./mychart [values.yaml...]` |
| [publish-chart.sh](scripts/publish-chart.sh) | Package and push chart to OCI registry or ChartMuseum with auto-login, lint, and verification | `./scripts/publish-chart.sh ./mychart oci://registry/charts` |

## Assets

Reusable templates in `assets/`:

| Asset | Description |
|-------|-------------|
| [values-schema.json](assets/values-schema.json) | Comprehensive JSON Schema template for values.yaml validation — covers image, service, ingress, resources, autoscaling, PDB, security contexts, env, serviceMonitor |
| [ci-pipeline.yaml](assets/ci-pipeline.yaml) | GitHub Actions workflow with lint → schema validate → integration test (Kind cluster) → publish (OCI/GHCR) stages |
| [_helpers.tpl](assets/_helpers.tpl) | Production-ready named templates: fullname, labels, selectors, component labels, annotations, checksums, image reference (with digest/registry support), security context defaults, value validation |

<!-- tested: pass -->
