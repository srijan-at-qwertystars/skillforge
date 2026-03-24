---
name: argocd-gitops
description: >
  Generate ArgoCD and Argo CD GitOps manifests, Application CRDs, ApplicationSet
  configs, ArgoCD sync policies, argocd app create commands, and GitOps deployment
  pipelines. Covers automated/manual sync, hooks, waves, multi-cluster management,
  SSO/RBAC, notifications, App of Apps, Helm/Kustomize integration, and CI/CD.
  Triggers: ArgoCD, Argo CD, GitOps, ArgoCD Application, ApplicationSet, ArgoCD sync,
  argocd app create, GitOps deployment.
  Does NOT cover: FluxCD, Jenkins CD, Spinnaker, manual kubectl apply,
  Helm-only deployments without GitOps.
---
# ArgoCD GitOps Skill
## Installation & Setup
Install ArgoCD into a dedicated namespace:
```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```
Install CLI, login, change password:
```bash
curl -sSL -o argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
chmod +x argocd && sudo mv argocd /usr/local/bin/
argocd admin initial-password -n argocd
argocd login <SERVER> --username admin --password <PASSWORD>
argocd account update-password
```
Expose via Ingress or `kubectl port-forward svc/argocd-server -n argocd 8080:443`.
Helm install for production:
```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd -n argocd --create-namespace \
  --set server.ingress.enabled=true --set server.ingress.hosts[0]=argocd.example.com
```
## Application CRD
Links a Git source to a cluster destination with sync policy.
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/org/repo.git
    targetRevision: HEAD
    path: k8s/overlays/prod
  destination:
    server: https://kubernetes.default.svc
    namespace: my-app
  syncPolicy:
    automated:
      prune: true       # Remove resources deleted from Git
      selfHeal: true    # Revert manual cluster changes
    syncOptions: [CreateNamespace=true, ApplyOutOfSyncOnly=true]
    retry:
      limit: 5
      backoff: { duration: 5s, factor: 2, maxDuration: 3m }
```
Key fields: `source.repoURL`, `source.path`, `source.targetRevision`, `source.helm`, `source.kustomize`, `destination.server`, `destination.namespace`, `syncPolicy.automated`.

Multi-source (Helm chart + values from separate repo):
```yaml
spec:
  sources:
    - repoURL: https://charts.example.com
      chart: my-chart
      targetRevision: 1.2.0
      helm:
        valueFiles: [$values/envs/prod/values.yaml]
    - repoURL: https://github.com/org/config.git
      targetRevision: HEAD
      ref: values
```
## Sync Strategies
**Automated**: Set `syncPolicy.automated` with `prune: true`, `selfHeal: true`. Polls Git every 3min or use webhooks.

**Manual**: Omit `syncPolicy.automated`. Trigger via CLI:
```bash
argocd app sync my-app --prune --force
argocd app sync my-app --resource apps:Deployment:my-deploy  # selective
```
**Sync waves** — control ordering. Lower wave numbers deploy first:
```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
```
Order: Phase (PreSync→Sync→PostSync) → Wave (lowest first) → Kind → Name.

**Sync hooks** — run Jobs at lifecycle phases:
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: db-migrate
  annotations:
    argocd.argoproj.io/hook: PreSync
    argocd.argoproj.io/hook-delete-policy: HookSucceeded
spec:
  template:
    spec:
      containers:
        - name: migrate
          image: org/migrator:latest
          command: ["./migrate.sh"]
      restartPolicy: Never
```
Hook phases: `PreSync`, `Sync`, `PostSync`, `SyncFail`, `Skip`, `PreDelete`, `PostDelete`.
Delete policies: `HookSucceeded`, `HookFailed`, `BeforeHookCreation`.
## ApplicationSet Generators
Generate multiple Applications from a single spec.

**List** — explicit enumeration:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: my-app-envs
  namespace: argocd
spec:
  generators:
    - list:
        elements:
          - env: dev
            cluster: https://dev-k8s.example.com
          - env: prod
            cluster: https://prod-k8s.example.com
  template:
    metadata:
      name: 'my-app-{{env}}'
    spec:
      project: default
      source:
        repoURL: https://github.com/org/repo.git
        path: 'overlays/{{env}}'
        targetRevision: HEAD
      destination:
        server: '{{cluster}}'
        namespace: my-app
      syncPolicy:
        automated: { prune: true, selfHeal: true }
```
**Git directory** — auto-discover from repo structure:
```yaml
generators:
  - git:
      repoURL: https://github.com/org/services.git
      revision: HEAD
      directories:
        - path: 'services/*'
        - path: 'services/legacy'
          exclude: true
```
Template uses `{{path}}` and `{{path.basename}}`.

**Git file** — read params from config files in repo:
```yaml
generators:
  - git:
      repoURL: https://github.com/org/config.git
      revision: HEAD
      files:
        - path: 'envs/*/config.json'
```
**Cluster** — one Application per registered cluster:
```yaml
generators:
  - clusters:
      selector:
        matchLabels: { env: production }
```
Template uses `{{name}}`, `{{server}}`, and cluster metadata.

**Matrix** — Cartesian product of two generators:
```yaml
generators:
  - matrix:
      generators:
        - git:
            repoURL: https://github.com/org/apps.git
            revision: HEAD
            directories: [{ path: 'apps/*' }]
        - clusters:
            selector:
              matchLabels: { tier: frontend }
```
**Merge** — combine and override parameters:
```yaml
generators:
  - merge:
      mergeKeys: [server]
      generators:
        - clusters: {}
        - list:
            elements:
              - server: https://prod.example.com
                replicas: "5"
```
## Multi-Cluster Management
Register and label external clusters:
```bash
argocd cluster add <CONTEXT_NAME> --name prod-cluster
argocd cluster set prod-cluster --label env=production --label region=us-east-1
argocd cluster list
```
Credentials stored as Secrets in `argocd` namespace. Use ApplicationSet cluster generator to deploy across all clusters. Isolate ArgoCD control plane in a management cluster.
## SSO and RBAC
OIDC in `argocd-cm` ConfigMap:
```yaml
data:
  url: https://argocd.example.com
  oidc.config: |
    name: Okta
    issuer: https://org.okta.com
    clientID: <CLIENT_ID>
    clientSecret: $oidc.okta.clientSecret
    requestedScopes: ["openid", "profile", "email", "groups"]
```
Store `clientSecret` in `argocd-secret`. RBAC in `argocd-rbac-cm`:
```yaml
data:
  policy.default: role:readonly
  policy.csv: |
    p, role:developer, applications, get, */*, allow
    p, role:developer, applications, sync, dev-project/*, allow
    p, role:admin, applications, *, */*, allow
    g, okta-admins, role:admin
    g, okta-devs, role:developer
  scopes: '[groups]'
```
Format: `p, <subject>, <resource>, <action>, <object>, <effect>`. Resources: `applications`, `repositories`, `clusters`, `projects`, `logs`, `exec`. Actions: `get`, `create`, `update`, `delete`, `sync`, `override`, `action`.

AppProject for team isolation:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: team-alpha
  namespace: argocd
spec:
  sourceRepos: ['https://github.com/org/team-alpha-*']
  destinations:
    - server: https://kubernetes.default.svc
      namespace: 'team-alpha-*'
  roles:
    - name: deployer
      policies: ['p, proj:team-alpha:deployer, applications, sync, team-alpha/*, allow']
      groups: [alpha-deployers]
```
## Notifications and Webhooks
Configure `argocd-notifications-cm`:
```yaml
data:
  service.slack: |
    token: $slack-token
  trigger.on-sync-succeeded: |
    - when: app.status.operationState.phase in ['Succeeded']
      send: [app-sync-succeeded]
  trigger.on-sync-failed: |
    - when: app.status.operationState.phase in ['Error', 'Failed']
      send: [app-sync-failed]
  template.app-sync-succeeded: |
    slack:
      attachments: |
        [{"color":"#18be52","title":"{{.app.metadata.name}} synced","text":"Rev {{.app.status.sync.revision}}"}]
```
Store token in `argocd-notifications-secret`. Subscribe apps via annotation:
```yaml
metadata:
  annotations:
    notifications.argoproj.io/subscribe.on-sync-succeeded.slack: my-channel
```
Set Git webhooks to `https://argocd.example.com/api/webhook` for instant sync on push.
## App of Apps Pattern
Parent Application manages child Application YAMLs in Git:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/org/platform.git
    path: apps/
    targetRevision: HEAD
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: { prune: true, selfHeal: true }
```
Place child Application YAMLs in `apps/`. Use Helm/Kustomize to template per env. Prefer ApplicationSet over App of Apps for >50 apps or cross-cluster.
## Helm and Kustomize Integration
**Helm**:
```yaml
source:
  repoURL: https://charts.example.com
  chart: nginx
  targetRevision: 15.0.0
  helm:
    releaseName: nginx-prod
    values: |
      replicaCount: 3
    parameters:
      - name: image.tag
        value: "1.25"
    valueFiles: [values-prod.yaml]
```
**Kustomize**:
```yaml
source:
  repoURL: https://github.com/org/repo.git
  path: k8s/overlays/prod
  kustomize:
    namePrefix: prod-
    commonLabels: { env: production }
    images: [{ name: org/app, newTag: v2.1.0 }]
```
## Diff Customization and Resource Tracking
Ignore expected diffs (HPA replicas, webhook CA bundles):
```yaml
spec:
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers: [/spec/replicas]
    - group: admissionregistration.k8s.io
      kind: MutatingWebhookConfiguration
      jqPathExpressions: ['.webhooks[]?.clientConfig.caBundle']
```
System-level in `argocd-cm`:
```yaml
data:
  resource.customizations.ignoreDifferences.all: |
    jsonPointers: [/metadata/annotations/kubectl.kubernetes.io~1last-applied-configuration]
```
Resource tracking modes (`argocd-cm`): `label` (default, uses `app.kubernetes.io/instance`), `annotation` (uses `argocd.argoproj.io/tracking-id`, preferred when labels conflict), `annotation+label`.
```yaml
data:
  application.resourceTrackingMethod: annotation
```
## CI/CD Pipeline Integration
Pattern: CI builds image → pushes to registry → updates Git manifest → ArgoCD syncs.
```yaml
# GitHub Actions step
- name: Update manifests
  run: |
    cd config-repo
    kustomize edit set image org/app=org/app:${{ github.sha }}
    git commit -am "deploy: org/app:${{ github.sha }}" && git push
```
ArgoCD Image Updater — watches registries, auto-commits tag updates:
```yaml
metadata:
  annotations:
    argocd-image-updater.argoproj.io/image-list: app=org/app
    argocd-image-updater.argoproj.io/app.update-strategy: semver
    argocd-image-updater.argoproj.io/write-back-method: git
```
CLI for CI pipelines:
```bash
argocd app create my-app --repo https://github.com/org/repo.git \
  --path k8s/prod --dest-server https://kubernetes.default.svc \
  --dest-namespace my-app --sync-policy automated --auto-prune --self-heal
argocd app sync my-app --timeout 300
argocd app wait my-app --health --timeout 300
```
## Patterns and Anti-Patterns
**DO**: Separate config repos from app source repos. Use `syncPolicy.retry` for transient failures. Set `ServerSideApply=true` for large CRDs. Use `RespectIgnoreDifferences=true`. Enforce least-privilege via AppProject. Pin `targetRevision` to branch/tag. Enable `selfHeal`. Use sync windows to restrict prod deploys.

**DON'T**: Store secrets in plain Git (use Sealed Secrets, SOPS, External Secrets). Use `Replace=true` (causes downtime). Put Application CRDs with workloads in monorepos (circular sync). Disable pruning in prod. Rely solely on polling (configure webhooks).
## Examples
**Input**: "Create an ArgoCD Application for a Helm chart deployed to staging."
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app-staging
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://charts.example.com
    chart: my-app
    targetRevision: 2.0.0
    helm:
      valueFiles: [values-staging.yaml]
  destination:
    server: https://kubernetes.default.svc
    namespace: staging
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true]
```
**Input**: "ApplicationSet deploying to all clusters labeled env=prod."
```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: prod-deploy
  namespace: argocd
spec:
  generators:
    - clusters:
        selector:
          matchLabels: { env: prod }
  template:
    metadata:
      name: 'app-{{name}}'
    spec:
      project: default
      source:
        repoURL: https://github.com/org/repo.git
        path: k8s/prod
        targetRevision: main
      destination:
        server: '{{server}}'
        namespace: app
      syncPolicy:
        automated: { prune: true, selfHeal: true }
```
**Input**: "PreSync database migration hook."
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: db-migrate
  annotations:
    argocd.argoproj.io/hook: PreSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
    argocd.argoproj.io/sync-wave: "-1"
spec:
  template:
    spec:
      containers:
        - name: migrate
          image: org/db-migrator:latest
          command: ["python", "manage.py", "migrate"]
      restartPolicy: Never
  backoffLimit: 1
```
## References
Deep-dive documentation in `references/`:
- **`references/advanced-patterns.md`** — ApplicationSet generators (matrix, merge, pull request, SCM provider), progressive delivery with Argo Rollouts, config management plugins, resource hooks lifecycle, custom health checks, diffing customization, multi-tenancy, GitOps repo structure patterns.
- **`references/troubleshooting.md`** — Sync failures, OutOfSync diagnosis, resource hook failures, ComparisonError/diff issues, repo access failures, namespace gotchas, resource tracking conflicts, performance tuning (repo-server, controller, Redis), disaster recovery, RBAC permission errors, SSO/OIDC problems, webhook issues, Image Updater troubleshooting.
- **`references/security-guide.md`** — RBAC policies and Casbin syntax, SSO (OIDC, Dex, SAML, Azure AD, Okta), secrets management (Sealed Secrets, External Secrets, SOPS, Vault), network policies, audit logging, supply chain security (image signing, GPG), project-level restrictions, repository/cluster credential management.

## Scripts
Operational helpers in `scripts/` (all executable):
- **`scripts/install-argocd.sh`** — Install ArgoCD via Helm or manifests, HA/non-HA, custom version, dry-run mode.
- **`scripts/bootstrap-apps.sh`** — Set up App of Apps pattern: create root Application, scaffold gitops repo directory structure with Kustomize overlays.
- **`scripts/sync-check.sh`** — Check sync status of all applications, report drift, identify failed syncs. Supports table/JSON/brief output, CI exit codes, wait mode.
- **`scripts/app-health-check.sh`** — Health dashboard: filter by project, show unhealthy/out-of-sync apps with color-coded table output.
- **`scripts/backup-restore.sh`** — Backup and restore Applications, AppProjects, repo/cluster secrets, ConfigMaps, notification config.

## Assets
Production-ready templates in `assets/`:
- **`assets/application.yaml`** — Application CRD template with sync policy, Helm/Kustomize/directory options, multi-source, ignoreDifferences, Image Updater annotations.
- **`assets/applicationset.yaml`** — ApplicationSet template with git directory generator, commented examples for list/cluster/matrix/PR generators, rolling sync strategy, templatePatch.
- **`assets/project.yaml`** — AppProject template with RBAC roles (developer/lead/CI/viewer), sync windows, orphaned resource monitoring, resource blacklists, destination service accounts.
- **`assets/argocd-values.yaml`** — Production Helm values: HA, OIDC/Dex SSO, RBAC, notifications, Redis HA, resource limits, metrics/ServiceMonitor.

<!-- tested: pass -->
