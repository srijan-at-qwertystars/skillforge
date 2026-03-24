# Advanced Helm Chart Patterns

## Table of Contents

- [Library Charts](#library-charts)
- [Umbrella Charts](#umbrella-charts)
- [CRD Management](#crd-management)
- [Operator Patterns](#operator-patterns)
- [Multi-Cluster Deployments](#multi-cluster-deployments)
- [GitOps with Helm](#gitops-with-helm)
- [Chart Testing Strategies](#chart-testing-strategies)
- [Helm SDK and Programmatic Usage](#helm-sdk-and-programmatic-usage)
- [Advanced Templating Patterns](#advanced-templating-patterns)
- [Chart Composition Patterns](#chart-composition-patterns)

---

## Library Charts

Library charts (`type: library` in Chart.yaml) contain only named templates — they produce no manifests directly. They provide reusable building blocks consumed by application charts.

### Creating a Library Chart

```yaml
# Chart.yaml
apiVersion: v2
name: common-lib
description: Shared templates for all team charts
type: library
version: 1.0.0
```

### Core Library Templates

Design library templates to accept a dictionary context, enabling flexibility:

```yaml
{{/* templates/_deployment.tpl */}}
{{- define "common-lib.deployment" -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "common-lib.fullname" . }}
  labels:
    {{- include "common-lib.labels" . | nindent 4 }}
spec:
  {{- if not .Values.autoscaling.enabled }}
  replicas: {{ .Values.replicaCount | default 1 }}
  {{- end }}
  selector:
    matchLabels:
      {{- include "common-lib.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "common-lib.selectorLabels" . | nindent 8 }}
      {{- with .Values.podAnnotations }}
      annotations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
    spec:
      {{- with .Values.imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      serviceAccountName: {{ include "common-lib.serviceAccountName" . }}
      securityContext:
        {{- toYaml (.Values.podSecurityContext | default dict) | nindent 8 }}
      containers:
        - name: {{ .Chart.Name }}
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
          imagePullPolicy: {{ .Values.image.pullPolicy | default "IfNotPresent" }}
          {{- with .Values.containerPorts }}
          ports:
            {{- range . }}
            - name: {{ .name }}
              containerPort: {{ .port }}
              protocol: {{ .protocol | default "TCP" }}
            {{- end }}
          {{- end }}
          {{- with .Values.resources }}
          resources:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            capabilities:
              drop: [ALL]
{{- end }}
```

### Consuming a Library Chart

In the consuming chart's `Chart.yaml`:

```yaml
dependencies:
  - name: common-lib
    version: "1.x.x"
    repository: "oci://registry.example.com/charts"
```

In `templates/deployment.yaml`:

```yaml
{{- include "common-lib.deployment" . }}
```

### Library Chart Versioning Strategy

- Use semver strictly: breaking template signature changes = major bump.
- Pin consuming charts to `~1.0.0` (patch updates only) or `1.x.x` (minor + patch).
- Run `helm dependency update` in CI to catch breakage early.
- Maintain a CHANGELOG documenting template signature changes.

### Advanced Library Pattern: Mixins

Provide composable partial templates that consumers combine:

```yaml
{{- define "common-lib.deployment.spec.strategy" -}}
{{- if eq .Values.deploymentStrategy "blue-green" }}
strategy:
  type: Recreate
{{- else }}
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxSurge: {{ .Values.rollingUpdate.maxSurge | default "25%" }}
    maxUnavailable: {{ .Values.rollingUpdate.maxUnavailable | default "25%" }}
{{- end }}
{{- end }}
```

Consumer includes it inside their deployment:

```yaml
spec:
  {{- include "common-lib.deployment.spec.strategy" . | nindent 2 }}
```

---

## Umbrella Charts

Umbrella (or meta) charts deploy an entire application stack via dependencies. The umbrella chart itself has minimal templates — primarily NOTES.txt and possibly a namespace or shared configmap.

### Structure

```
platform-stack/
├── Chart.yaml
├── values.yaml
├── values-staging.yaml
├── values-production.yaml
├── templates/
│   ├── _helpers.tpl
│   ├── NOTES.txt
│   └── shared-configmap.yaml    # optional cross-cutting config
└── charts/                       # populated by helm dep update
```

### Chart.yaml

```yaml
apiVersion: v2
name: platform-stack
description: Full application platform
version: 2.0.0
type: application
dependencies:
  - name: api-gateway
    version: "3.x.x"
    repository: "oci://registry.example.com/charts"
  - name: auth-service
    version: "2.x.x"
    repository: "oci://registry.example.com/charts"
    condition: auth.enabled
  - name: postgresql
    version: "~14.0.0"
    repository: "https://charts.bitnami.com/bitnami"
    alias: db
    condition: db.enabled
  - name: redis
    version: "~18.0.0"
    repository: "https://charts.bitnami.com/bitnami"
    condition: redis.enabled
  - name: monitoring
    version: "1.x.x"
    repository: "oci://registry.example.com/charts"
    tags:
      - observability
```

### values.yaml — Route Values to Subcharts

```yaml
global:
  imageRegistry: registry.example.com
  imagePullSecrets:
    - name: regcred
  storageClass: gp3

auth:
  enabled: true

# Values routed to auth-service subchart
auth-service:
  replicaCount: 2
  ingress:
    enabled: true
    hosts:
      - host: auth.example.com

# Values routed to aliased subchart
db:
  enabled: true
  auth:
    postgresPassword: "${DB_PASSWORD}"
    database: platform
  primary:
    persistence:
      size: 50Gi

redis:
  enabled: true
  architecture: standalone
```

### Umbrella Best Practices

1. **Version-lock subcharts** — use Chart.lock, commit it to SCM.
2. **Condition-gate everything** — every dependency gets a `.enabled` condition.
3. **Use tags for groups** — `--set tags.observability=false` disables monitoring + logging.
4. **Share config via globals** — registry, pull secrets, storage class.
5. **Keep the umbrella thin** — business logic lives in individual charts.
6. **Separate per-environment values** — `values-staging.yaml`, `values-production.yaml`.

---

## CRD Management

Helm has limited CRD lifecycle support by design. CRDs in `crds/` are installed once but never upgraded or deleted. This requires deliberate strategies.

### Strategy 1: Separate CRD Chart

```yaml
# crd-chart/Chart.yaml
apiVersion: v2
name: myapp-crds
version: 1.0.0
type: application

# crd-chart/templates/crd-myresource.yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: myresources.example.com
  annotations:
    helm.sh/resource-policy: keep    # Prevent deletion on uninstall
  labels:
    {{- include "myapp-crds.labels" . | nindent 4 }}
spec:
  group: example.com
  versions:
    - name: v1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                replicas:
                  type: integer
  scope: Namespaced
  names:
    plural: myresources
    singular: myresource
    kind: MyResource
```

Install CRDs first: `helm upgrade --install myapp-crds ./crd-chart`, then the main chart.

### Strategy 2: Pre-install Hook

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: myresources.example.com
  annotations:
    "helm.sh/hook": pre-install,pre-upgrade
    "helm.sh/hook-weight": "-10"
    helm.sh/resource-policy: keep
```

Downsides: hook resources don't appear in `helm get manifest`. Use for simpler cases.

### Strategy 3: Operator-Managed CRDs

For operators, the operator binary typically manages its own CRDs on startup. The chart deploys only the operator Deployment; CRD installation/upgrade is handled by the operator's reconciliation loop.

### CRD Upgrade Checklist

1. CRD changes must be backward-compatible (additive fields only).
2. Use conversion webhooks for breaking schema changes across versions.
3. Test CRD updates in staging with existing CRs before production.
4. Never remove a served version while CRs of that version exist.

---

## Operator Patterns

### Deploying an Operator with Helm

```yaml
# templates/operator-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "myoperator.fullname" . }}-controller
spec:
  replicas: {{ .Values.operator.replicas | default 1 }}
  selector:
    matchLabels:
      {{- include "myoperator.selectorLabels" . | nindent 6 }}
      app.kubernetes.io/component: controller
  template:
    spec:
      serviceAccountName: {{ include "myoperator.fullname" . }}
      containers:
        - name: manager
          image: "{{ .Values.operator.image.repository }}:{{ .Values.operator.image.tag }}"
          args:
            - --leader-elect={{ gt (int .Values.operator.replicas) 1 }}
            - --metrics-bind-address=:8080
            - --health-probe-bind-address=:8081
            - --webhook-port={{ .Values.operator.webhook.port | default 9443 }}
          ports:
            - containerPort: 8080
              name: metrics
            - containerPort: 8081
              name: health
          livenessProbe:
            httpGet:
              path: /healthz
              port: health
          readinessProbe:
            httpGet:
              path: /readyz
              port: health
          resources:
            {{- toYaml .Values.operator.resources | nindent 12 }}
```

### RBAC for Operators

```yaml
# templates/clusterrole.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: {{ include "myoperator.fullname" . }}
rules:
  - apiGroups: ["example.com"]
    resources: ["myresources"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["example.com"]
    resources: ["myresources/status"]
    verbs: ["get", "update", "patch"]
  - apiGroups: ["example.com"]
    resources: ["myresources/finalizers"]
    verbs: ["update"]
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["create", "patch"]
```

### Operator + CR in Same Chart

Deploy both the operator and a default CR instance:

```yaml
{{- if .Values.defaultInstance.enabled }}
apiVersion: example.com/v1
kind: MyResource
metadata:
  name: {{ .Values.defaultInstance.name | default "default" }}
  annotations:
    "helm.sh/hook": post-install,post-upgrade
    "helm.sh/hook-weight": "10"
spec:
  replicas: {{ .Values.defaultInstance.replicas }}
{{- end }}
```

Use a post-install hook so the CRD and operator are running before the CR is created.

---

## Multi-Cluster Deployments

### Values-Per-Cluster Pattern

```
charts/myapp/
├── values.yaml                 # Defaults
├── values-cluster-us-east.yaml
├── values-cluster-eu-west.yaml
└── values-cluster-ap-south.yaml
```

```bash
# Deploy to each cluster
for cluster in us-east eu-west ap-south; do
  kubectl config use-context "cluster-${cluster}"
  helm upgrade --install myapp ./charts/myapp \
    -f values.yaml \
    -f "values-cluster-${cluster}.yaml" \
    -n production --atomic --timeout 10m
done
```

### Templating Cluster-Specific Values

```yaml
# values-cluster-us-east.yaml
global:
  region: us-east-1
  clusterName: prod-us-east
  
ingress:
  hosts:
    - host: api-us.example.com
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing

resources:
  requests:
    cpu: "2"
    memory: 4Gi
```

### Helmfile for Multi-Cluster

```yaml
# helmfile.yaml
environments:
  us-east:
    values:
      - env/us-east.yaml
  eu-west:
    values:
      - env/eu-west.yaml

releases:
  - name: myapp
    chart: ./charts/myapp
    namespace: production
    values:
      - values.yaml
      - "env/{{ .Environment.Name }}.yaml"
    set:
      - name: global.clusterName
        value: "{{ .Environment.Name }}"
```

```bash
helmfile -e us-east apply
helmfile -e eu-west apply
```

---

## GitOps with Helm

### ArgoCD with Helm Charts

#### Application Manifest

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: myapp
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/org/helm-charts
    targetRevision: main
    path: charts/myapp
    helm:
      releaseName: myapp
      valueFiles:
        - values.yaml
        - values-production.yaml
      parameters:
        - name: image.tag
          value: "v1.2.3"
      # Skip CRDs if managed separately
      skipCrds: false
  destination:
    server: https://kubernetes.default.svc
    namespace: production
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
      - RespectIgnoreDifferences=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/replicas    # Ignore if HPA manages replicas
```

#### ApplicationSet for Multi-Cluster

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: myapp-clusters
  namespace: argocd
spec:
  generators:
    - clusters:
        selector:
          matchLabels:
            env: production
  template:
    metadata:
      name: "myapp-{{ name }}"
    spec:
      source:
        repoURL: https://github.com/org/helm-charts
        path: charts/myapp
        targetRevision: main
        helm:
          valueFiles:
            - "values-{{ name }}.yaml"
      destination:
        server: "{{ server }}"
        namespace: production
```

### Flux with Helm Charts

#### HelmRepository Source

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: bitnami
  namespace: flux-system
spec:
  interval: 1h
  url: https://charts.bitnami.com/bitnami
---
# For OCI registries:
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: internal
  namespace: flux-system
spec:
  type: oci
  interval: 5m
  url: oci://registry.example.com/charts
  secretRef:
    name: oci-creds
```

#### HelmRelease

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: myapp
  namespace: production
spec:
  interval: 30m
  chart:
    spec:
      chart: myapp
      version: "1.x"
      sourceRef:
        kind: HelmRepository
        name: internal
        namespace: flux-system
      interval: 5m
  install:
    remediation:
      retries: 3
  upgrade:
    remediation:
      retries: 3
      remediateLastFailure: true
    cleanupOnFail: true
  values:
    replicaCount: 3
    image:
      repository: myapp
      tag: v1.2.3
  valuesFrom:
    - kind: ConfigMap
      name: myapp-values
      optional: true
    - kind: Secret
      name: myapp-secrets
      valuesKey: values.yaml
  postRenderers:
    - kustomize:
        patches:
          - target:
              kind: Deployment
            patch: |
              - op: add
                path: /spec/template/metadata/annotations/cluster-autoscaler.kubernetes.io~1safe-to-evict
                value: "true"
```

### GitOps Best Practices

1. **Store values in Git** — never use `--set` in GitOps; everything must be declarative.
2. **Pin chart versions** — `1.2.3` not `1.x.x` for production releases in ArgoCD/Flux.
3. **Separate chart repo from config repo** — chart source vs. deployed config.
4. **Image tag automation** — Flux ImagePolicy or ArgoCD Image Updater for auto-bumping tags.
5. **Diff before sync** — ArgoCD shows diff in UI; Flux supports `flux diff helmrelease`.
6. **Secrets via external-secrets** — inject from Vault/AWS SM, not from Git.

---

## Chart Testing Strategies

### Unit Testing with helm-unittest

```yaml
# tests/deployment_test.yaml
suite: deployment tests
templates:
  - deployment.yaml
tests:
  - it: should set correct replicas
    set:
      replicaCount: 5
    asserts:
      - equal:
          path: spec.replicas
          value: 5

  - it: should not set replicas when autoscaling is enabled
    set:
      autoscaling.enabled: true
    asserts:
      - isNull:
          path: spec.replicas

  - it: should use image tag from values
    set:
      image.repository: myapp
      image.tag: v2.0.0
    asserts:
      - equal:
          path: spec.template.spec.containers[0].image
          value: "myapp:v2.0.0"

  - it: should render security context
    asserts:
      - equal:
          path: spec.template.spec.containers[0].securityContext.runAsNonRoot
          value: true
      - equal:
          path: spec.template.spec.containers[0].securityContext.allowPrivilegeEscalation
          value: false

  - it: should fail without required values
    set:
      image.repository: null
    asserts:
      - failedTemplate:
          errorMessage: "image.repository is required"
```

Install: `helm plugin install https://github.com/helm-unittest/helm-unittest`
Run: `helm unittest ./mychart`

### Integration Testing with chart-testing (ct)

```yaml
# ct.yaml (chart-testing config)
remote: origin
target-branch: main
chart-dirs:
  - charts
chart-repos:
  - bitnami=https://charts.bitnami.com/bitnami
helm-extra-args: --timeout 600s
validate-maintainers: false
check-version-increment: true
```

```bash
# Lint changed charts
ct lint --config ct.yaml

# Install and test changed charts (requires Kind cluster)
ct install --config ct.yaml --upgrade
```

### Snapshot Testing

Capture rendered output and diff against known-good baselines:

```bash
# Generate baseline
helm template myrelease ./mychart -f ci/values-test.yaml > tests/snapshots/baseline.yaml

# Compare current rendering
helm template myrelease ./mychart -f ci/values-test.yaml | diff tests/snapshots/baseline.yaml -
```

### Conftest / OPA Policy Testing

```bash
# Validate rendered manifests against policies
helm template myrelease ./mychart | conftest test - -p policy/

# policy/deployment.rego
package main
deny[msg] {
  input.kind == "Deployment"
  not input.spec.template.spec.securityContext.runAsNonRoot
  msg := "Deployments must set runAsNonRoot"
}
```

---

## Helm SDK and Programmatic Usage

### Go SDK — Installing Charts Programmatically

```go
package main

import (
    "log"
    "os"

    "helm.sh/helm/v3/pkg/action"
    "helm.sh/helm/v3/pkg/chart/loader"
    "helm.sh/helm/v3/pkg/cli"
)

func main() {
    settings := cli.New()
    actionConfig := new(action.Configuration)
    
    err := actionConfig.Init(
        settings.RESTClientGetter(),
        "default",             // namespace
        os.Getenv("HELM_DRIVER"), // storage driver
        log.Printf,
    )
    if err != nil {
        log.Fatal(err)
    }

    // Install
    install := action.NewInstall(actionConfig)
    install.ReleaseName = "myrelease"
    install.Namespace = "default"
    install.Wait = true
    install.Timeout = 300 * time.Second
    install.Atomic = true

    chart, err := loader.Load("./mychart")
    if err != nil {
        log.Fatal(err)
    }

    vals := map[string]interface{}{
        "replicaCount": 3,
        "image": map[string]interface{}{
            "repository": "myapp",
            "tag":        "v1.0.0",
        },
    }

    release, err := install.Run(chart, vals)
    if err != nil {
        log.Fatal(err)
    }
    log.Printf("Installed %s version %d", release.Name, release.Version)
}
```

### Go SDK — Listing and Upgrading Releases

```go
// List releases
list := action.NewList(actionConfig)
list.AllNamespaces = true
list.StateMask = action.ListAll
releases, err := list.Run()

// Upgrade
upgrade := action.NewUpgrade(actionConfig)
upgrade.Namespace = "production"
upgrade.Atomic = true
upgrade.Wait = true
release, err := upgrade.Run("myrelease", chart, vals)

// Rollback
rollback := action.NewRollback(actionConfig)
rollback.Version = 2  // revision number
err = rollback.Run("myrelease")
```

### Templating Programmatically

```go
// Render templates without installing
client := action.NewInstall(actionConfig)
client.DryRun = true
client.ReleaseName = "test"
client.Replace = true
client.ClientOnly = true

release, err := client.Run(chart, vals)
// release.Manifest contains rendered YAML
```

---

## Advanced Templating Patterns

### Dynamic Resource Generation

Generate multiple resources from a list in values:

```yaml
# values.yaml
cronJobs:
  - name: cleanup
    schedule: "0 2 * * *"
    command: ["./cleanup"]
  - name: report
    schedule: "0 8 * * 1"
    command: ["./report", "--weekly"]
```

```yaml
# templates/cronjobs.yaml
{{- range .Values.cronJobs }}
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: {{ include "myapp.fullname" $ }}-{{ .name }}
  labels:
    {{- include "myapp.labels" $ | nindent 4 }}
spec:
  schedule: {{ .schedule | quote }}
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
          containers:
            - name: {{ .name }}
              image: "{{ $.Values.image.repository }}:{{ $.Values.image.tag | default $.Chart.AppVersion }}"
              command: {{ toJson .command }}
{{- end }}
```

Note: use `$` to access root context inside `range`.

### Feature Flags via Capabilities

```yaml
{{- if .Capabilities.APIVersions.Has "monitoring.coreos.com/v1" }}
# ServiceMonitor is only rendered if Prometheus CRDs exist in cluster
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
...
{{- end }}

{{- if semverCompare ">=1.21-0" .Capabilities.KubeVersion.GitVersion }}
# Use new API version on newer clusters
apiVersion: policy/v1
{{- else }}
apiVersion: policy/v1beta1
{{- end }}
kind: PodDisruptionBudget
```

### Template Composition with Dictionaries

Pass structured context to named templates:

```yaml
{{- define "common.container" -}}
{{- $ctx := . -}}
- name: {{ $ctx.name }}
  image: "{{ $ctx.image.repository }}:{{ $ctx.image.tag }}"
  {{- with $ctx.env }}
  env:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with $ctx.resources }}
  resources:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end }}

{{/* Usage */}}
containers:
  {{- include "common.container" (dict "name" "app" "image" .Values.image "resources" .Values.resources "env" .Values.env) | nindent 8 }}
  {{- if .Values.sidecar.enabled }}
  {{- include "common.container" (dict "name" "sidecar" "image" .Values.sidecar.image "resources" .Values.sidecar.resources) | nindent 8 }}
  {{- end }}
```

---

## Chart Composition Patterns

### Microservice Template Chart

Create a generic chart that handles 90% of microservice deployments:

```yaml
# microservice-template/values.yaml
nameOverride: ""
fullnameOverride: ""

containerPort: 8080
healthCheckPath: /healthz

probes:
  liveness:
    path: /healthz
    initialDelaySeconds: 15
  readiness:
    path: /readyz
    initialDelaySeconds: 5

env: []
envFrom: []
volumes: []
volumeMounts: []
initContainers: []
sidecars: []

configMaps: {}
secrets: {}

# Each microservice overrides just what it needs:
# helm install user-svc ./microservice-template \
#   --set image.repository=user-service \
#   --set containerPort=3000 \
#   --set healthCheckPath=/health
```

### Layered Values Pattern

```bash
# Base → Environment → Region → Instance
helm upgrade myapp ./mychart \
  -f values.yaml \                    # chart defaults
  -f values-production.yaml \         # env overrides
  -f values-us-east-1.yaml \          # region overrides
  --set image.tag=${GIT_SHA}          # instance overrides
```

### Post-Renderer Kustomize

Apply Kustomize patches to Helm output:

```bash
helm template myrelease ./mychart | kustomize build --stdin

# Or with helm install
helm upgrade --install myrelease ./mychart --post-renderer ./kustomize-post-render.sh
```

```bash
#!/bin/bash
# kustomize-post-render.sh
cat > /tmp/helm-output.yaml
cat <<EOF > /tmp/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - helm-output.yaml
patches:
  - target:
      kind: Deployment
    patch: |-
      - op: add
        path: /metadata/annotations/custom
        value: "patched"
EOF
cd /tmp && kustomize build .
```
