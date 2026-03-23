---
name: argocd-gitops
description: >
  Use when writing Argo CD Application, ApplicationSet, or AppProject CRDs,
  configuring sync policies, sync waves, hooks, RBAC, SSO, notifications,
  multi-cluster management, Helm/Kustomize sources, health checks, or secrets
  integration (SOPS, Sealed Secrets, External Secrets). Use for argocd CLI
  commands, repo-server config, HA installation, disaster recovery, or
  debugging out-of-sync resources. DO NOT use for Argo Workflows, Argo Events,
  Argo Rollouts, Flux CD, generic Kubernetes manifests without Argo CD context,
  CI pipeline tools (Jenkins, GitHub Actions), or container image builds.
---

# Argo CD GitOps Skill

## Architecture

Four core components:
- **API Server (`argocd-server`)**: Deployment. Web UI, REST/gRPC API, CLI gateway. Handles authn/authz, RBAC. Stateless, scales horizontally.
- **Repo Server (`argocd-repo-server`)**: Deployment. Clones Git repos, renders manifests (Helm/Kustomize/Jsonnet/YAML). Caches output. Stateless. Custom plugins run here.
- **Application Controller (`argocd-application-controller`)**: StatefulSet. Reconciliation engine—compares live vs desired state, detects drift, triggers sync, runs hooks. Uses leader election + sharding for HA.
- **ApplicationSet Controller**: Deployment. Generates Application CRs from templates + generators.

Supporting: **Redis** (cache/queues), **Dex** (optional SSO), **Notifications Controller** (built-in alerts).

## Installation

```bash
# Non-HA (dev/test)
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# HA (production)
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/ha/install.yaml

# Helm (recommended production)
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd -n argocd --create-namespace \
  --set server.replicas=2 --set controller.replicas=2 \
  --set repoServer.replicas=2 --set redis-ha.enabled=true

# Get initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

## Application CRD

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app
  namespace: argocd
  finalizers: [resources-finalizer.argocd.argoproj.io]
spec:
  project: default
  source:
    repoURL: https://github.com/org/repo.git
    targetRevision: main
    path: k8s/overlays/production
  destination:
    server: https://kubernetes.default.svc
    namespace: my-app
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions: [CreateNamespace=true, PrunePropagationPolicy=foreground, PruneLast=true]
    retry:
      limit: 5
      backoff: { duration: 5s, factor: 2, maxDuration: 3m }
```

Key fields: `project` scopes RBAC. `targetRevision` accepts branch/tag/SHA. `finalizers` cascade-delete cluster resources on Application deletion. Use `https://kubernetes.default.svc` for in-cluster destination.

## Sync Strategies

| Strategy | Config | Behavior |
|----------|--------|----------|
| Manual | Omit `syncPolicy.automated` | Sync only on explicit trigger |
| Auto | `automated: {}` | Sync on Git change |
| Self-heal | `automated.selfHeal: true` | Revert manual cluster drift |
| Prune | `automated.prune: true` | Delete resources removed from Git |
| Selective | `syncOptions: [ApplyOutOfSyncOnly=true]` | Only apply drifted resources |

Always enable `selfHeal` + `prune` in production. Set `retry` with backoff for transient failures.

## Source Types

### Helm
```yaml
source:
  repoURL: https://charts.example.com  # or oci://registry.example.com/charts
  chart: my-chart
  targetRevision: 1.2.3
  helm:
    releaseName: my-release
    valueFiles: [values-production.yaml]
    values: |
      replicaCount: 3
    parameters:
      - name: service.type
        value: ClusterIP
```
Set `chart` (not `path`) for Helm repos. Use `valueFiles` for repo-local files, `values` for inline, `parameters` for individual overrides.

### Kustomize
```yaml
source:
  repoURL: https://github.com/org/repo.git
  path: k8s/overlays/staging
  kustomize:
    namePrefix: staging-
    images: [{name: myapp, newTag: v2.0.0}]
    commonLabels: {env: staging}
```

## ApplicationSet

### Git Directory Generator (mono-repo)
```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: cluster-apps
  namespace: argocd
spec:
  generators:
    - git:
        repoURL: https://github.com/org/gitops-repo.git
        revision: main
        directories: [{path: apps/*}]
  template:
    metadata:
      name: '{{path.basename}}'
    spec:
      project: default
      source:
        repoURL: https://github.com/org/gitops-repo.git
        targetRevision: main
        path: '{{path}}'
      destination:
        server: https://kubernetes.default.svc
        namespace: '{{path.basename}}'
      syncPolicy:
        automated: {prune: true, selfHeal: true}
```

### Cluster Generator (multi-cluster)
```yaml
generators:
  - clusters:
      selector:
        matchLabels: {env: production}
template:
  metadata:
    name: 'app-{{name}}'
  spec:
    destination:
      server: '{{server}}'
      namespace: my-app
```

### Matrix Generator — combines two generators (e.g., clusters × directories). Other generators: List, Pull Request, SCM Provider, Merge.

## Sync Waves and Hooks

Annotate resources with `argocd.argoproj.io/sync-wave: "<number>"`. Lower numbers sync first; default is 0; deletions reverse order.

```yaml
# Wave -1: Namespace → Wave 0: ConfigMaps (default) → Wave 1: Deployments → Wave 2: Ingress
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
```

### Hooks — run Jobs at lifecycle phases:
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: db-migrate
  annotations:
    argocd.argoproj.io/hook: PreSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
spec:
  template:
    spec:
      containers:
        - name: migrate
          image: myapp:latest
          command: ["./migrate.sh"]
      restartPolicy: Never
```

Phases: `PreSync` (migrations, backups), `Sync` (with sync), `PostSync` (smoke tests), `SyncFail` (alerts, rollback). Delete policies: `HookSucceeded`, `HookFailed`, `BeforeHookCreation`. Always set a delete policy.

## Repository Management

```bash
# HTTPS
argocd repo add https://github.com/org/repo.git --username git --password $TOKEN
# SSH
argocd repo add git@github.com:org/repo.git --ssh-private-key-path ~/.ssh/id_ed25519
```

Declarative (credential template for all repos under an org):
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: github-creds
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repo-creds
stringData:
  type: git
  url: https://github.com/org
  username: git
  password: ghp_xxxxxxxxxxxx
```

## RBAC and SSO

RBAC in `argocd-rbac-cm`:
```yaml
data:
  policy.default: role:readonly
  policy.csv: |
    p, role:dev, applications, get, */*, allow
    p, role:dev, applications, sync, */*, allow
    p, role:ops, applications, *, */*, allow
    g, my-github-org:dev-team, role:dev
    g, my-github-org:ops-team, role:ops
```

SSO via OIDC in `argocd-cm`:
```yaml
data:
  url: https://argocd.example.com
  oidc.config: |
    name: Okta
    issuer: https://example.okta.com
    clientID: xxxxxxxxxx
    clientSecret: $oidc.okta.clientSecret
    requestedScopes: ["openid", "profile", "email", "groups"]
```
Store `clientSecret` in `argocd-secret`, reference with `$oidc.okta.clientSecret`.

## Health Checks

Built-in health for Deployment, StatefulSet, DaemonSet, Ingress, Service, PVC. Custom health in `argocd-cm` using Lua:
```yaml
data:
  resource.customizations.health.certmanager.io_Certificate: |
    hs = {}
    if obj.status ~= nil and obj.status.conditions ~= nil then
      for i, condition in ipairs(obj.status.conditions) do
        if condition.type == "Ready" and condition.status == "True" then
          hs.status = "Healthy"
          hs.message = condition.message
          return hs
        end
      end
    end
    hs.status = "Progressing"
    hs.message = "Waiting for certificate"
    return hs
```
Return `{ status = "Healthy"|"Degraded"|"Progressing"|"Suspended", message = "..." }`.

## Notifications

Configure in `argocd-notifications-cm` + `argocd-notifications-secret`:
```yaml
data:
  service.slack: |
    token: $slack-token
  trigger.on-sync-succeeded: |
    - when: app.status.operationState.phase in ['Succeeded']
      send: [app-sync-succeeded]
  template.app-sync-succeeded: |
    message: "App {{.app.metadata.name}} synced. Rev: {{.app.status.sync.revision}}"
```

Subscribe apps via annotation: `notifications.argoproj.io/subscribe.on-sync-succeeded.slack: my-channel`. Supported: Slack, Teams, Email, Webhook, PagerDuty, Opsgenie, Telegram.

## Multi-Cluster

```bash
argocd cluster add my-production-context --name production
argocd cluster list
```
Declarative:
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: production-cluster
  namespace: argocd
  labels: {argocd.argoproj.io/secret-type: cluster}
stringData:
  name: production
  server: https://prod-k8s.example.com
  config: |
    {"bearerToken":"eyJhbGci...","tlsClientConfig":{"insecure":false,"caData":"LS0tLS1..."}}
```

## Secrets Management

- **Sealed Secrets**: Encrypt with `kubeseal --format yaml < secret.yaml > sealed-secret.yaml`. Commit encrypted SealedSecret to Git. Controller decrypts in-cluster.
- **External Secrets Operator**: Commit ExternalSecret CRDs referencing AWS Secrets Manager/Vault/GCP. ESO syncs real secrets into cluster. Argo CD never sees plaintext.
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: app-secrets
spec:
  refreshInterval: 1h
  secretStoreRef: {name: aws-sm, kind: ClusterSecretStore}
  target: {name: app-secrets}
  data:
    - secretKey: db-password
      remoteRef: {key: prod/myapp/db, property: password}
```
- **SOPS**: Encrypt manifests, decrypt at sync via custom repo-server plugin. Secrets appear in cache—prefer ESO/Sealed Secrets instead.

## CLI Quick Reference

```bash
argocd login argocd.example.com --sso
argocd app create my-app --repo URL --path k8s --dest-server https://kubernetes.default.svc --dest-namespace default
argocd app sync my-app [--prune] [--force]
argocd app get my-app
argocd app diff my-app
argocd app history my-app
argocd app rollback my-app <history-id>
argocd app delete my-app --cascade
argocd app wait my-app --health --timeout 300
argocd repo list / argocd repo add URL
argocd cluster add CONTEXT / argocd cluster list / argocd cluster rm URL
argocd proj create my-project -d https://kubernetes.default.svc,ns -s https://github.com/org/repo.git
```

## Disaster Recovery

```bash
# Backup
argocd app list -o yaml > apps-backup.yaml
kubectl get appprojects -n argocd -o yaml > projects-backup.yaml
kubectl get secrets -n argocd -l argocd.argoproj.io/secret-type -o yaml > secrets-backup.yaml

# Restore: reinstall Argo CD, then apply backups in order: projects → secrets → apps
```
Git repos are the source of truth. ApplicationSets can regenerate all Applications. Automate backups with CronJob.

## Additional Resources

### Reference Guides (`references/`)

| Guide | Description |
|-------|-------------|
| [advanced-patterns.md](references/advanced-patterns.md) | ApplicationSet generators (git, list, cluster, matrix, merge, PR), sync waves, custom Lua health checks, CMP plugins, App of Apps, multi-tenancy, progressive delivery with Rollouts, GitOps repo structures |
| [troubleshooting.md](references/troubleshooting.md) | Diagnosing OutOfSync/Syncing, hook failures, ComparisonError, repo access issues, namespace gotchas, resource tracking conflicts, performance tuning, disaster recovery |
| [security-guide.md](references/security-guide.md) | RBAC policies, SSO/OIDC setup (Azure AD, Okta, Dex), secrets management (Sealed Secrets, ESO, SOPS, Vault), network policies, audit logging, supply chain security |

### Scripts (`scripts/`)

| Script | Description |
|--------|-------------|
| [install-argocd.sh](scripts/install-argocd.sh) | Install Argo CD (Helm or manifests, HA or non-HA, configurable namespace/version) |
| [backup-restore.sh](scripts/backup-restore.sh) | Backup and restore Argo CD config (apps, projects, repos, clusters, configmaps, secrets) |
| [app-health-check.sh](scripts/app-health-check.sh) | Check health/sync status of all apps, report degraded ones (table/json/summary output) |

### Asset Templates (`assets/`)

| Template | Description |
|----------|-------------|
| [application.yaml](assets/application.yaml) | Application manifest with all common options commented |
| [applicationset.yaml](assets/applicationset.yaml) | ApplicationSet with git generator and other generator examples |
| [project.yaml](assets/project.yaml) | AppProject with RBAC roles, sync windows, resource restrictions |
| [argocd-values.yaml](assets/argocd-values.yaml) | Production Helm values (HA, SSO, RBAC, notifications, metrics) |

## Pitfalls and Best Practices

1. **Never store plain secrets in Git.** Use Sealed Secrets, External Secrets, or SOPS.
2. **Always set finalizer** `resources-finalizer.argocd.argoproj.io` on Applications.
3. **Set resource limits on repo-server** — Helm rendering is CPU/memory intensive.
4. **Use AppProjects** to scope team access. Block `kube-system` and `argocd` namespaces.
5. **Pin `targetRevision`** to branches, not `HEAD`.
6. **Enable `ServerSideApply=true`** for large CRDs to avoid annotation size limits.
7. **Ignore controller-managed fields** (e.g., HPA replicas):
   ```yaml
   spec:
     ignoreDifferences:
       - group: apps
         kind: Deployment
         jsonPointers: [/spec/replicas]
   ```
8. **Use `PruneLast=true`** — delete removed resources only after new ones are healthy.
9. **Use sync windows** in AppProject to restrict production sync times.
10. **Monitor with Prometheus** — alert on `argocd_app_info{sync_status="OutOfSync"}`.

## Examples

**Input**: "Deploy a Helm chart from a private OCI registry"
**Output**:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-oci-app
  namespace: argocd
  finalizers: [resources-finalizer.argocd.argoproj.io]
spec:
  project: default
  source:
    repoURL: oci://registry.example.com/charts
    chart: my-chart
    targetRevision: 2.0.0
    helm:
      valueFiles: [values-prod.yaml]
  destination:
    server: https://kubernetes.default.svc
    namespace: my-oci-app
  syncPolicy:
    automated: {prune: true, selfHeal: true}
    syncOptions: [CreateNamespace=true]
```

**Input**: "Create ApplicationSet deploying to all clusters labeled env=staging"
**Output**:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: staging-apps
  namespace: argocd
spec:
  generators:
    - clusters:
        selector:
          matchLabels: {env: staging}
  template:
    metadata:
      name: 'myapp-{{name}}'
    spec:
      project: default
      source:
        repoURL: https://github.com/org/repo.git
        targetRevision: main
        path: k8s/overlays/staging
      destination:
        server: '{{server}}'
        namespace: myapp
      syncPolicy:
        automated: {prune: true, selfHeal: true}
```

**Input**: "Run a database migration before deploying"
**Output**:
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: db-migrate
  annotations:
    argocd.argoproj.io/hook: PreSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
spec:
  template:
    spec:
      containers:
        - name: migrate
          image: myapp:latest
          command: ["python", "manage.py", "migrate"]
          envFrom: [{secretRef: {name: db-credentials}}]
      restartPolicy: Never
  backoffLimit: 1
```

<!-- tested: pass -->
