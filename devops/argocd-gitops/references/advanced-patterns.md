# Argo CD Advanced Patterns

## Table of Contents

- [ApplicationSet Generators](#applicationset-generators)
  - [Git Generator](#git-generator)
  - [List Generator](#list-generator)
  - [Cluster Generator](#cluster-generator)
  - [Matrix Generator](#matrix-generator)
  - [Merge Generator](#merge-generator)
  - [Pull Request Generator](#pull-request-generator)
  - [SCM Provider Generator](#scm-provider-generator)
- [Sync Waves and Resource Hooks](#sync-waves-and-resource-hooks)
  - [Sync Wave Ordering](#sync-wave-ordering)
  - [Resource Hooks](#resource-hooks)
  - [Hook Delete Policies](#hook-delete-policies)
  - [Complex Deployment Orchestration](#complex-deployment-orchestration)
- [Custom Health Checks](#custom-health-checks)
  - [Lua Health Check Scripts](#lua-health-check-scripts)
  - [Common CRD Health Checks](#common-crd-health-checks)
  - [Custom Resource Actions](#custom-resource-actions)
- [Config Management Plugins](#config-management-plugins)
  - [Sidecar CMP Architecture](#sidecar-cmp-architecture)
  - [Plugin Configuration](#plugin-configuration)
  - [Common Plugin Examples](#common-plugin-examples)
- [App of Apps Pattern](#app-of-apps-pattern)
  - [Structure](#app-of-apps-structure)
  - [Bootstrapping](#bootstrapping)
  - [App of Apps vs ApplicationSet](#app-of-apps-vs-applicationset)
- [Multi-Tenancy with Projects](#multi-tenancy-with-projects)
  - [AppProject Configuration](#appproject-configuration)
  - [Role-Based Access](#role-based-access)
  - [Sync Windows](#sync-windows)
  - [Resource Quotas and Limits](#resource-quotas-and-limits)
- [Progressive Delivery with Argo Rollouts](#progressive-delivery-with-argo-rollouts)
  - [Rollout Strategies](#rollout-strategies)
  - [Analysis Templates](#analysis-templates)
  - [Integration with Argo CD](#integration-with-argo-cd)
- [GitOps Repo Structure Patterns](#gitops-repo-structure-patterns)
  - [Monorepo Pattern](#monorepo-pattern)
  - [Polyrepo Pattern](#polyrepo-pattern)
  - [Hybrid Pattern](#hybrid-pattern)
  - [Environment Promotion](#environment-promotion)
- [Diffing Customization](#diffing-customization)
  - [ignoreDifferences Configuration](#ignoredifferences-configuration)
  - [System-Level Diff Overrides](#system-level-diff-overrides)
  - [Server-Side Diff](#server-side-diff)
  - [Diff Strategies for Common Scenarios](#diff-strategies-for-common-scenarios)

---

## ApplicationSet Generators

ApplicationSet controllers automate the generation of Argo CD Application resources from templates combined with generators. Each generator produces parameter sets that are substituted into the template.

### Git Generator

Two sub-types: **directory** and **file**.

**Directory generator** — creates an Application for each directory matching a path pattern:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: team-apps
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - git:
        repoURL: https://github.com/org/gitops-repo.git
        revision: main
        directories:
          - path: apps/*
          - path: apps/excluded-app
            exclude: true
  template:
    metadata:
      name: '{{ .path.basename }}'
    spec:
      project: default
      source:
        repoURL: https://github.com/org/gitops-repo.git
        targetRevision: main
        path: '{{ .path.path }}'
      destination:
        server: https://kubernetes.default.svc
        namespace: '{{ .path.basename }}'
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
```

**File generator** — reads JSON/YAML config files from a repo to parameterize Applications:

```yaml
generators:
  - git:
      repoURL: https://github.com/org/gitops-repo.git
      revision: main
      files:
        - path: "config/**/config.json"
```

Each `config.json` might contain:
```json
{
  "cluster": { "name": "production", "server": "https://prod.example.com" },
  "app": { "namespace": "my-app", "revision": "v2.0.0" }
}
```

Template parameters: `{{ .cluster.name }}`, `{{ .app.namespace }}`, etc.

### List Generator

Hardcoded parameter sets for explicit control:

```yaml
generators:
  - list:
      elements:
        - cluster: production
          url: https://prod-k8s.example.com
          values:
            revision: release-1.0
            replicas: "3"
        - cluster: staging
          url: https://staging-k8s.example.com
          values:
            revision: main
            replicas: "1"
template:
  metadata:
    name: 'myapp-{{ .cluster }}'
  spec:
    source:
      targetRevision: '{{ .values.revision }}'
    destination:
      server: '{{ .url }}'
```

Use for small, well-known sets of targets where cluster auto-discovery is not needed.

### Cluster Generator

Auto-discovers clusters registered with Argo CD:

```yaml
generators:
  - clusters:
      selector:
        matchLabels:
          env: production
          region: us-east-1
      # Optional: override template values per cluster
      values:
        revision: release-1.0
```

Available parameters: `{{ .name }}`, `{{ .server }}`, `{{ .metadata.labels.<key> }}`, `{{ .metadata.annotations.<key> }}`.

The in-cluster (`https://kubernetes.default.svc`) is included if it matches the selector. Exclude it with `matchExpressions`:

```yaml
selector:
  matchExpressions:
    - key: env
      operator: In
      values: [production]
    - key: argocd.argoproj.io/secret-type
      operator: Exists
```

### Matrix Generator

Combines two generators to produce a Cartesian product:

```yaml
generators:
  - matrix:
      generators:
        - git:
            repoURL: https://github.com/org/gitops-repo.git
            revision: main
            directories:
              - path: apps/*
        - clusters:
            selector:
              matchLabels:
                env: production
template:
  metadata:
    name: '{{ .path.basename }}-{{ .name }}'
  spec:
    source:
      path: '{{ .path.path }}'
    destination:
      server: '{{ .server }}'
      namespace: '{{ .path.basename }}'
```

This deploys every app directory to every production cluster. **Nested matrix** generators support up to two levels of nesting.

### Merge Generator

Combines generators with override semantics. Later generators override earlier ones for matching keys:

```yaml
generators:
  - merge:
      mergeKeys:
        - server
      generators:
        # Base: all clusters get defaults
        - clusters:
            values:
              revision: main
              replicas: "1"
        # Override: production clusters get specific settings
        - clusters:
            selector:
              matchLabels:
                env: production
            values:
              revision: release-1.0
              replicas: "3"
```

Use merge when you need defaults with per-target overrides — avoids duplicating configuration.

### Pull Request Generator

Creates ephemeral Applications for open PRs:

```yaml
generators:
  - pullRequest:
      github:
        owner: myorg
        repo: myapp
        tokenRef:
          secretName: github-token
          key: token
        labels:
          - preview
      requeueAfterSeconds: 60
template:
  metadata:
    name: 'pr-{{ .number }}'
  spec:
    source:
      repoURL: https://github.com/myorg/myapp.git
      targetRevision: '{{ .head_sha }}'
      path: k8s/overlays/preview
      kustomize:
        namePrefix: 'pr-{{ .number }}-'
    destination:
      server: https://kubernetes.default.svc
      namespace: 'pr-{{ .number }}'
    syncPolicy:
      automated:
        prune: true
        selfHeal: true
      syncOptions:
        - CreateNamespace=true
```

Available parameters: `{{ .number }}`, `{{ .branch }}`, `{{ .head_sha }}`, `{{ .head_short_sha }}`, `{{ .labels }}`. Supports GitHub, GitLab, Gitea, and Bitbucket.

**Important**: Set `requeueAfterSeconds` to poll for PR changes. Use labels to gate which PRs get preview environments.

### SCM Provider Generator

Discovers repositories from a GitHub org, GitLab group, or other SCM providers and creates Applications automatically. Unlike the Git generator (which reads from a single known repo), the SCM provider queries the SCM API to enumerate repos.

**GitHub Organization:**
```yaml
generators:
  - scmProvider:
      github:
        organization: my-org
        tokenRef:
          secretName: github-token
          key: token
        # Optional filters
        allBranches: false         # Only default branch
      filters:
        - repositoryMatch: ^service-.*     # Regex on repo name
          pathsExist:
            - deploy/k8s                   # Repo must have this path
          branchMatch: ^main$
          labelMatch: argocd-managed       # GitHub topic label
template:
  metadata:
    name: '{{ .repository }}'
  spec:
    source:
      repoURL: '{{ .url }}'
      targetRevision: '{{ .branch }}'
      path: deploy/k8s
    destination:
      server: https://kubernetes.default.svc
      namespace: '{{ .repository }}'
    syncPolicy:
      automated:
        prune: true
        selfHeal: true
      syncOptions: [CreateNamespace=true]
```

**GitLab Group:**
```yaml
generators:
  - scmProvider:
      gitlab:
        group: "my-group"               # Group path or ID
        includeSubgroups: true
        tokenRef:
          secretName: gitlab-token
          key: token
      filters:
        - repositoryMatch: ^svc-
          pathsExist: [k8s/]
```

Available template parameters: `{{ .organization }}`, `{{ .repository }}`, `{{ .url }}`, `{{ .branch }}`, `{{ .sha }}`, `{{ .labels }}`. Combine with matrix generator to deploy discovered repos across multiple clusters.

**SCM Provider with Matrix (deploy every discovered repo to every cluster):**
```yaml
generators:
  - matrix:
      generators:
        - scmProvider:
            github:
              organization: my-org
              tokenRef:
                secretName: github-token
                key: token
            filters:
              - pathsExist: [deploy/k8s]
        - clusters:
            selector:
              matchLabels:
                env: production
```

---

## Sync Waves and Resource Hooks

### Sync Wave Ordering

Resources sync in wave order (lowest first). Within a wave, resources sync by kind priority (Namespaces → CRDs → ServiceAccounts → Roles → ConfigMaps → Services → Deployments → etc.), then alphabetically by name.

```yaml
# Wave -5: Namespaces and CRDs
apiVersion: v1
kind: Namespace
metadata:
  name: my-app
  annotations:
    argocd.argoproj.io/sync-wave: "-5"

---
# Wave -3: RBAC
apiVersion: v1
kind: ServiceAccount
metadata:
  name: my-app-sa
  annotations:
    argocd.argoproj.io/sync-wave: "-3"

---
# Wave 0: Config (default wave)
apiVersion: v1
kind: ConfigMap
metadata:
  name: my-app-config
# No annotation needed for wave 0

---
# Wave 1: Database
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
  annotations:
    argocd.argoproj.io/sync-wave: "1"

---
# Wave 5: Application
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
  annotations:
    argocd.argoproj.io/sync-wave: "5"

---
# Wave 10: Ingress
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app-ingress
  annotations:
    argocd.argoproj.io/sync-wave: "10"
```

**Deletion order** is reversed — higher waves are deleted first.

### Resource Hooks

Hooks are resources that run at specific sync lifecycle phases and are not part of the normal application state.

| Phase | Timing | Use Cases |
|-------|--------|-----------|
| `PreSync` | Before sync starts | DB migrations, backups, notifications |
| `Sync` | During sync (same as normal resources) | Special jobs that must run with sync |
| `PostSync` | After all resources healthy | Smoke tests, cache warming, notifications |
| `SyncFail` | When sync fails | Alerts, cleanup, rollback triggers |
| `PostDelete` | After application deletion | Cleanup external resources |

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: schema-migrate
  annotations:
    argocd.argoproj.io/hook: PreSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
    argocd.argoproj.io/sync-wave: "-1"
spec:
  ttlSecondsAfterFinished: 3600
  template:
    spec:
      containers:
        - name: migrate
          image: myapp:latest
          command: ["python", "manage.py", "migrate", "--no-input"]
          envFrom:
            - secretRef:
                name: db-credentials
      restartPolicy: Never
  backoffLimit: 2
```

### Hook Delete Policies

| Policy | Behavior |
|--------|----------|
| `BeforeHookCreation` | Delete previous hook before creating new one (default if none set) |
| `HookSucceeded` | Delete hook after successful completion |
| `HookFailed` | Delete hook after failure |

Combine policies: `argocd.argoproj.io/hook-delete-policy: HookSucceeded, HookFailed` to always clean up.

### Complex Deployment Orchestration

```yaml
# Wave -2: PreSync backup Job
# Wave -1: PreSync migration Job
# Wave 0:  Sync ConfigMaps, Secrets
# Wave 1:  Sync Database StatefulSet
# Wave 2:  Sync Application Deployment
# Wave 3:  Sync Ingress
# Wave 5:  PostSync smoke test Job
# SyncFail: Notification Job
```

Each wave waits for the previous wave's resources to be healthy before proceeding. A hook failure in PreSync aborts the entire sync.

---

## Custom Health Checks

### Lua Health Check Scripts

Configure in `argocd-cm` ConfigMap. The Lua script receives `obj` (the full resource) and must return a table with `status` and optional `message`.

Valid statuses: `Healthy`, `Degraded`, `Progressing`, `Suspended`, `Missing`.

```yaml
# argocd-cm ConfigMap
data:
  resource.customizations.health.argoproj.io_Rollout: |
    hs = {}
    if obj.status == nil then
      hs.status = "Progressing"
      hs.message = "Waiting for status"
      return hs
    end

    if obj.status.currentPodHash == nil then
      hs.status = "Progressing"
      hs.message = "Waiting for rollout to initialize"
      return hs
    end

    if obj.status.phase == "Healthy" then
      hs.status = "Healthy"
      hs.message = "Rollout is healthy"
    elseif obj.status.phase == "Paused" then
      hs.status = "Suspended"
      hs.message = obj.status.message or "Rollout is paused"
    elseif obj.status.phase == "Degraded" then
      hs.status = "Degraded"
      hs.message = obj.status.message or "Rollout is degraded"
    else
      hs.status = "Progressing"
      hs.message = obj.status.message or "Rollout is progressing"
    end
    return hs
```

### Common CRD Health Checks

**cert-manager Certificate:**
```yaml
resource.customizations.health.cert-manager.io_Certificate: |
  hs = {}
  if obj.status ~= nil then
    if obj.status.conditions ~= nil then
      for i, condition in ipairs(obj.status.conditions) do
        if condition.type == "Ready" then
          if condition.status == "True" then
            hs.status = "Healthy"
            hs.message = condition.message
            return hs
          else
            hs.status = "Degraded"
            hs.message = condition.message
            return hs
          end
        end
      end
    end
  end
  hs.status = "Progressing"
  hs.message = "Waiting for certificate"
  return hs
```

**Istio VirtualService:**
```yaml
resource.customizations.health.networking.istio.io_VirtualService: |
  hs = {}
  if obj.status ~= nil and obj.status.conditions ~= nil then
    for i, condition in ipairs(obj.status.conditions) do
      if condition.type == "Reconciled" and condition.status == "True" then
        hs.status = "Healthy"
        return hs
      end
    end
  end
  hs.status = "Progressing"
  return hs
```

**Kafka Topic (Strimzi):**
```yaml
resource.customizations.health.kafka.strimzi.io_KafkaTopic: |
  hs = {}
  if obj.status ~= nil and obj.status.conditions ~= nil then
    for i, condition in ipairs(obj.status.conditions) do
      if condition.type == "Ready" then
        if condition.status == "True" then
          hs.status = "Healthy"
        else
          hs.status = "Degraded"
        end
        hs.message = condition.message
        return hs
      end
    end
  end
  hs.status = "Progressing"
  return hs
```

### Custom Resource Actions

Define custom actions on resources (e.g., restart a Deployment, pause a Rollout):

```yaml
# argocd-cm ConfigMap
data:
  resource.customizations.actions.apps_Deployment: |
    discovery.lua: |
      actions = {}
      actions["restart"] = {["disabled"] = false}
      return actions
    definitions:
      - name: restart
        action.lua: |
          local os = require("os")
          if obj.spec.template.metadata == nil then
            obj.spec.template.metadata = {}
          end
          if obj.spec.template.metadata.annotations == nil then
            obj.spec.template.metadata.annotations = {}
          end
          obj.spec.template.metadata.annotations["kubectl.kubernetes.io/restartedAt"] = tostring(os.date("!%Y-%m-%dT%H:%M:%SZ"))
          return obj
```

---

## Config Management Plugins

### Sidecar CMP Architecture

Since Argo CD 2.4+, plugins run as sidecar containers alongside `argocd-repo-server`. Each sidecar receives the repo files via a shared volume and returns rendered manifests on stdout.

```yaml
# repo-server deployment — add sidecar
apiVersion: apps/v1
kind: Deployment
metadata:
  name: argocd-repo-server
spec:
  template:
    spec:
      containers:
        - name: my-plugin
          image: myorg/argocd-cmp-sops:latest
          command: ["/var/run/argocd/argocd-cmp-server"]
          securityContext:
            runAsNonRoot: true
            runAsUser: 999
          volumeMounts:
            - name: var-files
              mountPath: /var/run/argocd
            - name: plugins
              mountPath: /home/argocd/cmp-server/config/plugin.yaml
              subPath: plugin.yaml
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: plugins
          configMap:
            name: cmp-plugin-config
        - name: tmp
          emptyDir: {}
```

### Plugin Configuration

```yaml
# ConfigMap: cmp-plugin-config
apiVersion: v1
kind: ConfigMap
metadata:
  name: cmp-plugin-config
data:
  plugin.yaml: |
    apiVersion: argoproj.io/v1alpha1
    kind: ConfigManagementPlugin
    metadata:
      name: sops-helm
    spec:
      version: v1.0
      init:
        command: ["/bin/sh", "-c"]
        args: ["helm dependency build"]
      generate:
        command: ["/bin/sh", "-c"]
        args:
          - |
            helm template $ARGOCD_APP_NAME . \
              --namespace $ARGOCD_APP_NAMESPACE \
              --values <(sops -d values-secret.yaml) \
              --include-crds
      discover:
        find:
          glob: "**/values-secret.yaml"
```

### Common Plugin Examples

**SOPS decryption plugin:**
```yaml
spec:
  generate:
    command: ["/bin/sh", "-c"]
    args:
      - |
        for f in $(find . -name '*.enc.yaml'); do
          sops -d "$f"
          echo "---"
        done
        for f in $(find . -name '*.yaml' ! -name '*.enc.yaml'); do
          cat "$f"
          echo "---"
        done
```

**Kustomize with Helm:**
```yaml
spec:
  generate:
    command: ["/bin/sh", "-c"]
    args: ["kustomize build --enable-helm ."]
  discover:
    find:
      glob: "**/kustomization.yaml"
```

---

## App of Apps Pattern

### App of Apps Structure

A root Application that manages child Applications. The root app points to a directory of Application manifests.

```
gitops-repo/
├── bootstrap/
│   └── root-app.yaml          # Root Application (apply manually)
├── apps/
│   ├── cert-manager.yaml      # Application for cert-manager
│   ├── ingress-nginx.yaml     # Application for ingress
│   ├── monitoring.yaml        # Application for Prometheus stack
│   └── my-app.yaml            # Application for business app
└── manifests/
    ├── cert-manager/
    ├── ingress-nginx/
    ├── monitoring/
    └── my-app/
```

### Bootstrapping

```yaml
# bootstrap/root-app.yaml — apply this once manually
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/org/gitops-repo.git
    targetRevision: main
    path: apps
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

Each file in `apps/` is a full Application manifest. Sync waves control ordering:
- Wave -3: Namespaces, CRDs
- Wave -2: Infrastructure (cert-manager, external-secrets)
- Wave -1: Networking (ingress)
- Wave 0: Platform services (monitoring, logging)
- Wave 1+: Business applications

### App of Apps vs ApplicationSet

| Feature | App of Apps | ApplicationSet |
|---------|-------------|----------------|
| Flexibility | Full control per app | Templated, uniform |
| Maintenance | More files to manage | Single resource |
| Use case | Heterogeneous apps | Homogeneous fleet |
| Bootstrap | Manual root apply | Manual AppSet apply |
| Customization | Per-app overrides easy | Requires merge/matrix |

**Recommendation**: Use ApplicationSet for fleets of similar apps. Use App of Apps for bootstrapping diverse infrastructure components.

---

## Multi-Tenancy with Projects

### AppProject Configuration

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: team-frontend
  namespace: argocd
spec:
  description: "Frontend team applications"

  # Allowed source repositories
  sourceRepos:
    - https://github.com/org/frontend-*.git
    - https://charts.example.com

  # Allowed destination clusters and namespaces
  destinations:
    - server: https://kubernetes.default.svc
      namespace: frontend-*
    - server: https://staging.example.com
      namespace: frontend-*

  # Deny list — block sensitive namespaces
  namespaceResourceBlacklist:
    - group: ''
      kind: ResourceQuota
    - group: ''
      kind: LimitRange
    - group: ''
      kind: NetworkPolicy

  # Cluster-scoped resources this project can manage
  clusterResourceWhitelist:
    - group: ''
      kind: Namespace

  # Sync windows — restrict production deploys
  syncWindows:
    - kind: allow
      schedule: '0 6-18 * * 1-5'     # Mon-Fri 6am-6pm
      duration: 12h
      applications: ['*']
      namespaces: ['frontend-prod-*']
    - kind: deny
      schedule: '0 0 25 12 *'         # Christmas
      duration: 24h
      applications: ['*']

  # Orphaned resource monitoring
  orphanedResources:
    warn: true
    ignore:
      - group: ''
        kind: ConfigMap
        name: kube-root-ca.crt
```

### Role-Based Access

```yaml
spec:
  roles:
    - name: frontend-dev
      description: "Frontend developers - read and sync"
      policies:
        - p, proj:team-frontend:frontend-dev, applications, get, team-frontend/*, allow
        - p, proj:team-frontend:frontend-dev, applications, sync, team-frontend/*, allow
        - p, proj:team-frontend:frontend-dev, logs, get, team-frontend/*, allow
      groups:
        - org:frontend-developers   # SSO group mapping

    - name: frontend-lead
      description: "Frontend leads - full access"
      policies:
        - p, proj:team-frontend:frontend-lead, applications, *, team-frontend/*, allow
        - p, proj:team-frontend:frontend-lead, logs, get, team-frontend/*, allow
        - p, proj:team-frontend:frontend-lead, exec, create, team-frontend/*, allow
      groups:
        - org:frontend-leads

    - name: ci-bot
      description: "CI/CD bot - sync only"
      policies:
        - p, proj:team-frontend:ci-bot, applications, sync, team-frontend/*, allow
        - p, proj:team-frontend:ci-bot, applications, get, team-frontend/*, allow
      jwtTokens:
        - iat: 1693000000   # issued-at timestamp
```

### Sync Windows

Restrict when syncs can happen:

```yaml
syncWindows:
  # Allow manual syncs only during business hours
  - kind: allow
    schedule: '0 9-17 * * 1-5'
    duration: 8h
    applications: ['*']
    manualSync: true

  # Allow automated syncs only during maintenance window
  - kind: allow
    schedule: '0 2 * * 0'       # Sunday 2am
    duration: 4h
    applications: ['critical-*']

  # Block all syncs during freeze
  - kind: deny
    schedule: '0 0 20-31 12 *'  # Dec 20-31 change freeze
    duration: 24h
    applications: ['*']
    clusters: ['*']
```

### Resource Quotas and Limits

Use `destinationServiceAccounts` (v2.9+) to enforce Kubernetes RBAC at the destination:

```yaml
spec:
  destinationServiceAccounts:
    - server: https://kubernetes.default.svc
      namespace: frontend-*
      defaultServiceAccount: argocd-frontend-deployer
```

This ensures Argo CD uses a limited ServiceAccount in target namespaces rather than cluster-admin.

---

## Progressive Delivery with Argo Rollouts

### Rollout Strategies

**Canary with traffic management:**
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: my-app
spec:
  replicas: 5
  strategy:
    canary:
      canaryService: my-app-canary
      stableService: my-app-stable
      trafficRouting:
        istio:
          virtualServices:
            - name: my-app-vsvc
              routes:
                - primary
      steps:
        - setWeight: 5
        - pause: { duration: 5m }
        - setWeight: 20
        - pause: { duration: 5m }
        - analysis:
            templates:
              - templateName: success-rate
            args:
              - name: service-name
                value: my-app-canary
        - setWeight: 50
        - pause: { duration: 10m }
        - setWeight: 80
        - pause: { duration: 5m }
  selector:
    matchLabels:
      app: my-app
  template:
    metadata:
      labels:
        app: my-app
    spec:
      containers:
        - name: my-app
          image: myapp:latest
```

**Blue-Green:**
```yaml
strategy:
  blueGreen:
    activeService: my-app-active
    previewService: my-app-preview
    autoPromotionEnabled: false
    prePromotionAnalysis:
      templates:
        - templateName: smoke-test
    postPromotionAnalysis:
      templates:
        - templateName: success-rate
```

### Analysis Templates

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: success-rate
spec:
  args:
    - name: service-name
  metrics:
    - name: success-rate
      interval: 1m
      count: 5
      successCondition: result[0] >= 0.95
      failureLimit: 3
      provider:
        prometheus:
          address: http://prometheus.monitoring:9090
          query: |
            sum(rate(http_requests_total{service="{{args.service-name}}",status=~"2.."}[5m]))
            /
            sum(rate(http_requests_total{service="{{args.service-name}}"}[5m]))
```

### Integration with Argo CD

1. Install Argo Rollouts alongside Argo CD
2. Add custom health check for Rollout resources (see [Custom Health Checks](#custom-health-checks))
3. Replace `Deployment` with `Rollout` in your manifests
4. Argo CD manages the Rollout resource; Rollouts controller handles progressive delivery

```yaml
# argocd-cm — add Rollout resource customization
data:
  resource.customizations.health.argoproj.io_Rollout: |
    -- (Lua health check as shown above)
  resource.customizations.actions.argoproj.io_Rollout: |
    discovery.lua: |
      actions = {}
      actions["resume"] = {["disabled"] = false}
      actions["abort"] = {["disabled"] = false}
      actions["promote-full"] = {["disabled"] = false}
      return actions
```

---

## GitOps Repo Structure Patterns

### Monorepo Pattern

All apps and environments in a single repository:

```
gitops-repo/
├── apps/
│   ├── app-a/
│   │   ├── base/
│   │   │   ├── deployment.yaml
│   │   │   ├── service.yaml
│   │   │   └── kustomization.yaml
│   │   └── overlays/
│   │       ├── dev/
│   │       │   ├── kustomization.yaml
│   │       │   └── patches/
│   │       ├── staging/
│   │       │   ├── kustomization.yaml
│   │       │   └── patches/
│   │       └── production/
│   │           ├── kustomization.yaml
│   │           └── patches/
│   └── app-b/
│       └── ...
├── infrastructure/
│   ├── cert-manager/
│   ├── ingress-nginx/
│   └── monitoring/
└── clusters/
    ├── dev/
    ├── staging/
    └── production/
```

**Pros**: Single PR for cross-cutting changes, easy to search, unified CI.
**Cons**: Blast radius on misconfiguration, harder access control, repo size grows.

### Polyrepo Pattern

Separate repos per app or team:

```
# Repo: gitops-infrastructure
infrastructure/
├── cert-manager/
├── ingress-nginx/
└── monitoring/

# Repo: gitops-app-a
app-a/
├── base/
└── overlays/

# Repo: gitops-app-b
app-b/
├── base/
└── overlays/

# Repo: gitops-clusters (cluster bootstrapping)
clusters/
├── dev/
├── staging/
└── production/
```

**Pros**: Team autonomy, fine-grained permissions, smaller repos.
**Cons**: Cross-repo changes harder, more repos to manage, credential duplication.

### Hybrid Pattern

Infrastructure in one repo, apps in per-team repos:

```
# Repo: gitops-platform (platform team)
platform/
├── infrastructure/
├── clusters/
└── app-of-apps/

# Repo: gitops-team-frontend (frontend team)
frontend/
├── app-a/
└── app-b/

# Repo: gitops-team-backend (backend team)
backend/
├── api-gateway/
└── user-service/
```

**Recommended for most organizations.** Platform team owns infrastructure and cluster config. App teams own their deploy manifests.

### Environment Promotion

**Branch-per-environment** (not recommended):
- `dev`, `staging`, `production` branches
- Promote via merge/cherry-pick
- Risk of drift between branches

**Directory-per-environment** (recommended):
- Kustomize overlays per environment
- Promote by updating image tags in overlay
- Single branch (`main`), all environments visible

**Automated promotion** pattern:
1. CI builds image, pushes to registry
2. CI updates image tag in dev overlay, commits
3. Argo CD syncs dev
4. After validation, CI (or human) updates staging overlay
5. After staging validation, update production overlay

Use Argo CD Image Updater for automated image tag updates:
```yaml
metadata:
  annotations:
    argocd-image-updater.argoproj.io/image-list: myapp=myregistry/myapp
    argocd-image-updater.argoproj.io/myapp.update-strategy: semver
    argocd-image-updater.argoproj.io/myapp.allow-tags: regexp:^v[0-9]+\.[0-9]+\.[0-9]+$
    argocd-image-updater.argoproj.io/write-back-method: git
```

---

## Diffing Customization

Argo CD compares the desired state (Git) with the live state (cluster) to detect drift. Some fields are modified by controllers, webhooks, or the API server, causing perpetual OutOfSync. Diffing customization tells Argo CD which differences to ignore.

### ignoreDifferences Configuration

Per-application ignore rules in the Application spec:

```yaml
spec:
  ignoreDifferences:
    # HPA manages replicas — don't treat as drift
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/replicas

    # Webhook CA bundles injected by cert-manager
    - group: admissionregistration.k8s.io
      kind: MutatingWebhookConfiguration
      jqPathExpressions:
        - '.webhooks[]?.clientConfig.caBundle'

    # Ignore specific fields on a named resource
    - group: apps
      kind: Deployment
      name: my-special-deploy
      namespace: production
      jsonPointers:
        - /metadata/annotations/deployment.kubernetes.io~1revision

    # Ignore all annotation changes on Services
    - group: ""
      kind: Service
      jqPathExpressions:
        - .metadata.annotations

    # Managed fields added by server-side apply
    - group: "*"
      kind: "*"
      managedFieldsManagers:
        - kube-controller-manager
        - cluster-autoscaler
```

**jsonPointers** uses RFC 6901 syntax. Escape `/` as `~1` and `~` as `~0`. **jqPathExpressions** uses jq filter syntax for more complex matching.

### System-Level Diff Overrides

Apply ignore rules globally across all Applications in `argocd-cm`:

```yaml
# argocd-cm ConfigMap
data:
  # Ignore last-applied-configuration on ALL resources
  resource.customizations.ignoreDifferences.all: |
    jsonPointers:
      - /metadata/annotations/kubectl.kubernetes.io~1last-applied-configuration

  # Ignore specific fields by resource type
  resource.customizations.ignoreDifferences.apps_Deployment: |
    jsonPointers:
      - /spec/replicas
    jqPathExpressions:
      - .spec.template.metadata.annotations."kubectl.kubernetes.io/restartedAt"

  resource.customizations.ignoreDifferences.admissionregistration.k8s.io_MutatingWebhookConfiguration: |
    jqPathExpressions:
      - '.webhooks[]?.clientConfig.caBundle'
      - '.webhooks[]?.failurePolicy'

  # Ignore status on all custom resources in a group
  resource.customizations.ignoreDifferences.cert-manager.io_Certificate: |
    jsonPointers:
      - /status
```

### Server-Side Diff

Server-side diff (v2.5+) sends manifests to the Kubernetes API server's dry-run endpoint, which normalizes defaults and mutations. This eliminates many false-positive diffs caused by defaulting webhooks and API server normalization.

Enable globally in `argocd-cmd-params-cm`:
```yaml
data:
  controller.diff.server.side: "true"
```

Or per-application via sync option:
```yaml
spec:
  syncPolicy:
    syncOptions:
      - ServerSideApply=true     # Also implies server-side diff
```

**When server-side diff helps:**
- API server adds defaulted fields (e.g., `spec.revisionHistoryLimit` on Deployments)
- Mutating webhooks inject/modify fields (e.g., Istio sidecar injection, Vault agent)
- CRDs with complex defaulting logic

**Caveats:**
- Requires cluster connectivity during diff (increased API server load)
- Some CRDs may not support dry-run correctly
- May reveal drift that was previously hidden by client-side normalization

### Diff Strategies for Common Scenarios

**HPA + Deployment replicas:**
```yaml
# Option 1: ignoreDifferences (simple)
ignoreDifferences:
  - group: apps
    kind: Deployment
    jsonPointers: [/spec/replicas]

# Option 2: RespectIgnoreDifferences sync option (prevents sync from resetting replicas)
syncPolicy:
  syncOptions:
    - RespectIgnoreDifferences=true
```

**Kustomize-managed resources with controller mutations:**
```yaml
ignoreDifferences:
  - group: ""
    kind: Service
    jqPathExpressions:
      - .spec.clusterIP
      - .spec.clusterIPs
      - '.spec.ports[]?.nodePort'
```

**CRDs with status subresource not properly configured:**
```yaml
# argocd-cm — ignore status globally for a CRD
data:
  resource.customizations.ignoreDifferences.mygroup.io_MyResource: |
    jsonPointers:
      - /status
    jqPathExpressions:
      - .metadata.generation
```

**Argo Rollouts AnalysisRun fields:**
```yaml
ignoreDifferences:
  - group: argoproj.io
    kind: Rollout
    jqPathExpressions:
      - .spec.template.metadata.annotations."rollout.argoproj.io/revision"
```

> **Tip:** Run `argocd app diff my-app` to see exactly what fields differ before configuring ignoreDifferences. Use `--server-side` flag to compare with server-side diff.
