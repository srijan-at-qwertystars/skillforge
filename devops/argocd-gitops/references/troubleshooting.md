# Argo CD Troubleshooting Guide

## Table of Contents

- [App Stuck in Syncing or OutOfSync](#app-stuck-in-syncing-or-outofSync)
  - [Diagnosing OutOfSync](#diagnosing-outofSync)
  - [Common Causes of Perpetual OutOfSync](#common-causes-of-perpetual-outofSync)
  - [App Stuck in Syncing](#app-stuck-in-syncing)
- [Resource Hook Failures](#resource-hook-failures)
  - [PreSync Hook Hangs](#presync-hook-hangs)
  - [Hook Not Deleted](#hook-not-deleted)
  - [SyncFail Hook Not Running](#syncfail-hook-not-running)
- [ComparisonError and Diff Issues](#comparisonerror-and-diff-issues)
  - [Common ComparisonError Causes](#common-comparisonerror-causes)
  - [Ignoring Differences](#ignoring-differences)
  - [Normalizing Resource Fields](#normalizing-resource-fields)
- [Repository Access Failures](#repository-access-failures)
  - [Authentication Issues](#authentication-issues)
  - [SSH Key Problems](#ssh-key-problems)
  - [Proxy and Network Issues](#proxy-and-network-issues)
  - [Repo-Server Errors](#repo-server-errors)
- [Namespace Management Gotchas](#namespace-management-gotchas)
  - [CreateNamespace Issues](#createnamespace-issues)
  - [Namespace Ownership Conflicts](#namespace-ownership-conflicts)
- [Resource Tracking and Annotation Conflicts](#resource-tracking-and-annotation-conflicts)
  - [Tracking Methods](#tracking-methods)
  - [Shared Resource Conflicts](#shared-resource-conflicts)
  - [Migration Between Tracking Methods](#migration-between-tracking-methods)
- [Performance Tuning](#performance-tuning)
  - [Repo-Server Optimization](#repo-server-optimization)
  - [Application Controller Tuning](#application-controller-tuning)
  - [Redis Optimization](#redis-optimization)
  - [Scaling for Large Installations](#scaling-for-large-installations)
- [Disaster Recovery Procedures](#disaster-recovery-procedures)
  - [Full Backup Strategy](#full-backup-strategy)
  - [Restore Procedure](#restore-procedure)
  - [Partial Recovery Scenarios](#partial-recovery-scenarios)

---

## App Stuck in Syncing or OutOfSync

### Diagnosing OutOfSync

```bash
# Check app sync status and details
argocd app get my-app
argocd app get my-app --show-operation

# View the diff between desired and live state
argocd app diff my-app

# Check for sync errors in the operation history
argocd app get my-app -o json | jq '.status.operationState'

# List all resources and their sync status
argocd app resources my-app
```

### Common Causes of Perpetual OutOfSync

**1. Controller-managed fields (e.g., HPA modifying replicas):**

```yaml
# Problem: HPA changes replicas, Argo CD sees drift
# Solution: Ignore the field
spec:
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/replicas
    # OR use JQ path expressions (v2.1+):
    - group: apps
      kind: Deployment
      jqPathExpressions:
        - .spec.replicas
```

**2. Defaulted fields added by the API server:**

Kubernetes adds default values (e.g., `strategy.rollingUpdate`, `dnsPolicy`, `restartPolicy`). These appear in live state but not in Git.

```yaml
# Ignore specific defaulted fields
spec:
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/template/spec/dnsPolicy
        - /spec/template/spec/terminationGracePeriodSeconds
```

Or system-wide in `argocd-cm`:
```yaml
data:
  resource.compareoptions: |
    ignoreResourceStatusField: all
```

**3. Mutating webhooks modifying resources:**

Webhooks (e.g., Istio sidecar injector) add fields after apply. Ignore injected fields:

```yaml
spec:
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jqPathExpressions:
        - .spec.template.metadata.annotations."sidecar.istio.io/status"
        - .spec.template.metadata.labels."security.istio.io/tlsMode"
```

**4. Annotation size limit exceeded:**

Large CRDs with many fields can exceed the `kubectl.kubernetes.io/last-applied-configuration` annotation limit (262144 bytes).

```yaml
# Solution: Enable Server-Side Apply
syncPolicy:
  syncOptions:
    - ServerSideApply=true
```

**5. Resource not tracked by Argo CD:**

```bash
# Check if the resource has the correct tracking label/annotation
kubectl get deployment my-app -o jsonpath='{.metadata.labels.app\.kubernetes\.io/instance}'
```

### App Stuck in Syncing

```bash
# Check operation state
argocd app get my-app -o json | jq '.status.operationState.phase'

# Check for pending hooks
argocd app resources my-app | grep -E 'Hook|PreSync|PostSync'

# Check hook Job logs
kubectl logs -n my-app job/db-migrate

# Force-terminate a stuck sync
argocd app terminate-op my-app
```

Common causes:
- Hook Job not completing (bad image, crashloop, waiting for resource)
- Resource stuck in `Progressing` health (Deployment can't roll out, PVC pending)
- Finalizer blocking deletion during prune
- Network timeout contacting target cluster

**Force sync after termination:**
```bash
argocd app terminate-op my-app
argocd app sync my-app --force --replace
```

---

## Resource Hook Failures

### PreSync Hook Hangs

```bash
# Find the hook Job
kubectl get jobs -n my-app -l argocd.argoproj.io/hook

# Check pod status
kubectl get pods -n my-app -l job-name=db-migrate

# Get logs
kubectl logs -n my-app job/db-migrate

# Common fixes:
# 1. Job image pull error → check imagePullSecrets
# 2. Job waiting for DB → check networkPolicy / service availability
# 3. Job OOMKilled → increase memory limits
# 4. Job timeout → set activeDeadlineSeconds on the Job
```

**Add timeout to prevent indefinite hangs:**
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: db-migrate
  annotations:
    argocd.argoproj.io/hook: PreSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
spec:
  activeDeadlineSeconds: 300   # 5-minute timeout
  backoffLimit: 2
  template:
    spec:
      containers:
        - name: migrate
          image: myapp:latest
          command: ["./migrate.sh"]
          resources:
            limits:
              memory: 512Mi
              cpu: 500m
      restartPolicy: Never
```

### Hook Not Deleted

```bash
# List orphaned hook resources
kubectl get jobs -n my-app -l argocd.argoproj.io/hook --show-labels

# Manual cleanup
kubectl delete job -n my-app db-migrate
```

Ensure delete policy is set:
```yaml
annotations:
  argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
```

Without a delete policy, hooks accumulate and can cause `BeforeHookCreation` to fail if names conflict.

### SyncFail Hook Not Running

SyncFail hooks only run when the sync operation fails. They do NOT run when:
- A PreSync hook fails (the sync hasn't started yet)
- The app is manually synced and the user cancels
- The operation is terminated with `argocd app terminate-op`

Verify the hook is correctly annotated:
```yaml
annotations:
  argocd.argoproj.io/hook: SyncFail
  argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
```

---

## ComparisonError and Diff Issues

### Common ComparisonError Causes

```bash
# View the error
argocd app get my-app -o json | jq '.status.conditions[] | select(.type=="ComparisonError")'
```

**1. Invalid manifests:**
```
ComparisonError: failed to load initial state of resource: Deployment.apps "my-app" is invalid
```
Fix: Validate manifests locally with `kubectl apply --dry-run=client -f manifest.yaml`.

**2. CRD not installed:**
```
ComparisonError: the server could not find the requested resource
```
Fix: Install CRDs before the Application that uses them (use sync waves).

**3. Helm rendering error:**
```
ComparisonError: helm template failed: ...
```
Fix: Test locally with `helm template . --values values.yaml`.

**4. Kustomize error:**
```
ComparisonError: kustomize build failed: ...
```
Fix: Test locally with `kustomize build overlays/production`.

**5. Too many resources:**
```
ComparisonError: rpc error: code = ResourceExhausted desc = grpc: received message larger than max
```
Fix: Increase gRPC message size in `argocd-cmd-params-cm`:
```yaml
data:
  server.repo.server.plaintext: "true"
  controller.repo.server.plaintext: "true"
  reposerver.max.combined.directory.manifests.size: "10M"
```

### Ignoring Differences

**Per-application:**
```yaml
spec:
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/replicas
    - group: ""
      kind: Service
      jqPathExpressions:
        - .spec.clusterIP
        - .spec.clusterIPs
    - group: admissionregistration.k8s.io
      kind: MutatingWebhookConfiguration
      jqPathExpressions:
        - '.webhooks[]?.clientConfig.caBundle'
```

**System-wide defaults in `argocd-cm`:**
```yaml
data:
  resource.customizations.ignoreDifferences.admissionregistration.k8s.io_MutatingWebhookConfiguration: |
    jsonPointers:
      - /webhooks/0/clientConfig/caBundle
    jqPathExpressions:
      - '.webhooks[]?.clientConfig.caBundle'
```

### Normalizing Resource Fields

Use `resource.customizations.knownTypeFields` in `argocd-cm` to normalize fields:

```yaml
data:
  resource.customizations.knownTypeFields.networking.k8s.io_Ingress: |
    - field: spec.rules
      type: networking.k8s.io/IngressRule
```

---

## Repository Access Failures

### Authentication Issues

```bash
# Test repo connectivity
argocd repo list
argocd repo get https://github.com/org/repo.git

# Debug connection
argocd repo add https://github.com/org/repo.git \
  --username git --password $TOKEN 2>&1

# Check repo-server logs
kubectl logs -n argocd deploy/argocd-repo-server | grep -i error
```

**Token expired or revoked:**
```bash
# Update repository credentials
argocd repo add https://github.com/org/repo.git \
  --username git --password $NEW_TOKEN --upsert
```

**Or update the Secret directly:**
```bash
kubectl edit secret -n argocd repo-<hash>
# Update password field (base64 encoded)
```

### SSH Key Problems

```bash
# Verify SSH key works
ssh -T git@github.com -i ~/.ssh/id_ed25519

# Add SSH known hosts
argocd cert add-ssh --batch < /path/to/known_hosts

# Check current known hosts
argocd cert list --cert-type ssh

# Common issue: host key changed
# Fix: remove old key and add new one
argocd cert rm-ssh github.com
ssh-keyscan github.com | argocd cert add-ssh --batch
```

**Self-hosted Git with custom SSH port:**
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: my-git-creds
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: ssh://git@git.example.com:2222/org/repo.git
  sshPrivateKey: |
    -----BEGIN OPENSSH PRIVATE KEY-----
    ...
    -----END OPENSSH PRIVATE KEY-----
```

### Proxy and Network Issues

```yaml
# Set proxy in argocd-cmd-params-cm
data:
  # HTTP proxy for repo-server outbound requests
  controller.repo.server.timeout.seconds: "120"

# Or set on repo-server container env
env:
  - name: HTTPS_PROXY
    value: http://proxy.example.com:8080
  - name: NO_PROXY
    value: kubernetes.default.svc,10.0.0.0/8
```

**TLS certificate issues:**
```bash
# Add custom CA certificate
argocd cert add-tls git.example.com --from /path/to/ca.pem

# Or disable TLS verification (NOT recommended for production)
argocd repo add https://git.example.com/org/repo.git --insecure-skip-server-verification
```

### Repo-Server Errors

```bash
# Check repo-server health
kubectl logs -n argocd deploy/argocd-repo-server --tail=100

# Common: "gpg failed to sign the data"
# Fix: disable GPG if not needed
# argocd-cmd-params-cm:
#   controller.repo.server.plaintext: "true"

# OOMKilled during Helm rendering
kubectl describe pod -n argocd -l app.kubernetes.io/component=repo-server | grep -A5 "Last State"
# Fix: increase memory limits
```

---

## Namespace Management Gotchas

### CreateNamespace Issues

```yaml
# This creates the namespace if it doesn't exist
syncPolicy:
  syncOptions:
    - CreateNamespace=true
```

**Problem**: Namespace created by Argo CD is owned by the Application. Deleting the Application (with finalizer) deletes the namespace and everything in it.

**Solutions:**
1. Create namespaces separately (in a different Application or manually):
```yaml
# namespace.yaml in a separate "infra" app
apiVersion: v1
kind: Namespace
metadata:
  name: my-app
  labels:
    managed-by: platform-team
```

2. Remove the finalizer if you don't want cascade deletion:
```yaml
metadata:
  # Omit finalizers array
  # finalizers: [resources-finalizer.argocd.argoproj.io]  # DON'T set this
```

### Namespace Ownership Conflicts

**Problem**: Two Applications targeting the same namespace — one with `CreateNamespace=true`. Deletion of either may delete the namespace.

**Solution**: Use a dedicated "namespaces" Application with higher priority:
```yaml
# Wave -5: Namespace app creates all namespaces
# Wave 0+: App deployments use existing namespaces (no CreateNamespace)
```

**Problem**: `CreateNamespace` with `automated.prune: true` — if the namespace manifest is removed from Git, Argo CD prunes the namespace (deleting everything inside).

**Solution**: Use `PruneLast=true` or exclude namespaces from pruning.

---

## Resource Tracking and Annotation Conflicts

### Tracking Methods

Argo CD tracks which resources belong to which Application using one of three methods:

| Method | Mechanism | Annotation/Label |
|--------|-----------|-----------------|
| `label` (legacy) | `app.kubernetes.io/instance` label | Label on resource |
| `annotation` | `argocd.argoproj.io/tracking-id` annotation | Annotation on resource |
| `annotation+label` | Both | Both (default in 2.6+) |

Configure in `argocd-cm`:
```yaml
data:
  application.resourceTrackingMethod: annotation+label
```

### Shared Resource Conflicts

**Problem**: Two Applications managing the same resource → tracking conflict.

```
ComparisonError: unable to reconcile: another application 'other-app' already manages this resource
```

**Solutions:**
1. Move shared resources to a dedicated Application
2. Use `annotation` tracking (allows same resource in multiple apps with careful management)
3. Exclude the resource from one Application:
```yaml
spec:
  source:
    directory:
      exclude: 'shared-configmap.yaml'
```

### Migration Between Tracking Methods

When switching tracking methods (e.g., `label` → `annotation+label`):

1. Update `argocd-cm` with new tracking method
2. Sync all Applications to apply new tracking metadata
3. Verify no tracking conflicts

```bash
# Check for resources with old tracking labels but no annotation
kubectl get all --all-namespaces -l app.kubernetes.io/instance=my-app \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.argocd\.argoproj\.io/tracking-id}{"\n"}{end}'
```

---

## Performance Tuning

### Repo-Server Optimization

```yaml
# argocd-cmd-params-cm
data:
  # Parallelism for manifest generation
  reposerver.parallelism.limit: "2"

  # Cache expiry (default 24h)
  reposerver.repo.cache.expiration: "24h"

# Repo-server resource limits (in Deployment)
resources:
  requests:
    cpu: 500m
    memory: 512Mi
  limits:
    cpu: "2"
    memory: 2Gi
```

**Helm rendering is CPU/memory intensive.** If you see OOMKilled on repo-server:
```bash
# Check which apps consume most resources during rendering
kubectl top pod -n argocd -l app.kubernetes.io/component=repo-server

# Increase limits or add replicas
kubectl scale deploy -n argocd argocd-repo-server --replicas=3
```

**Git clone optimization:**
```yaml
# argocd-cm
data:
  # Enable Git submodule support (if needed)
  # reposerver.enable.git.submodule: "true"

  # Use shallow clones to reduce clone time/disk
  # (enabled by default for repo-server)
```

### Application Controller Tuning

```yaml
# argocd-cmd-params-cm
data:
  # Number of application reconciliation workers (default: 20)
  controller.status.processors: "30"

  # Number of sync operation workers (default: 10)
  controller.operation.processors: "15"

  # Self-heal timeout (default: 5s)
  controller.self.heal.timeout.seconds: "5"

  # Reconciliation timeout
  controller.repo.server.timeout.seconds: "180"

  # K8s client QPS and burst
  controller.k8sclient.server.side.diff.enabled: "true"
```

**Sharding for large installations (100+ apps):**
```yaml
# Split apps across controller replicas by cluster
# argocd-application-controller StatefulSet
spec:
  replicas: 3
  template:
    spec:
      containers:
        - name: argocd-application-controller
          env:
            - name: ARGOCD_CONTROLLER_REPLICAS
              value: "3"
```

Apps are sharded by cluster. Each controller replica manages a subset of clusters.

### Redis Optimization

```yaml
# For HA installations, use Redis HA (Sentinel)
redis-ha:
  enabled: true
  haproxy:
    enabled: true
  replicas: 3

# Increase Redis memory for large installations
redis:
  resources:
    requests:
      memory: 256Mi
    limits:
      memory: 1Gi
```

**Monitor Redis memory:**
```bash
kubectl exec -n argocd deploy/argocd-redis -- redis-cli INFO memory | grep used_memory_human
```

### Scaling for Large Installations

For 500+ applications:

1. **Enable sharding** on the application controller
2. **Scale repo-server** to 3-5 replicas with increased CPU/memory
3. **Use Redis HA** with Sentinel
4. **Increase gRPC limits:**
```yaml
# argocd-cmd-params-cm
data:
  server.repo.server.plaintext: "true"
  controller.repo.server.plaintext: "true"
```
5. **Reduce reconciliation frequency** for non-critical apps:
```yaml
# Per-app annotation
metadata:
  annotations:
    argocd.argoproj.io/refresh: normal   # or "hard"
```
6. **Use ApplicationSet** instead of individual Application manifests
7. **Monitor metrics** with Prometheus:
```bash
# Key metrics to watch
argocd_app_reconcile_count
argocd_app_reconcile_bucket
argocd_app_k8s_request_total
argocd_git_request_total
argocd_redis_request_total
```

---

## Disaster Recovery Procedures

### Full Backup Strategy

```bash
#!/bin/bash
# Comprehensive Argo CD backup
BACKUP_DIR="argocd-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

# 1. Applications
kubectl get applications -n argocd -o yaml > "$BACKUP_DIR/applications.yaml"

# 2. ApplicationSets
kubectl get applicationsets -n argocd -o yaml > "$BACKUP_DIR/applicationsets.yaml"

# 3. AppProjects
kubectl get appprojects -n argocd -o yaml > "$BACKUP_DIR/appprojects.yaml"

# 4. Repository credentials
kubectl get secrets -n argocd -l argocd.argoproj.io/secret-type=repository -o yaml > "$BACKUP_DIR/repo-secrets.yaml"

# 5. Repository credential templates
kubectl get secrets -n argocd -l argocd.argoproj.io/secret-type=repo-creds -o yaml > "$BACKUP_DIR/repo-cred-templates.yaml"

# 6. Cluster credentials
kubectl get secrets -n argocd -l argocd.argoproj.io/secret-type=cluster -o yaml > "$BACKUP_DIR/cluster-secrets.yaml"

# 7. ConfigMaps
kubectl get configmap -n argocd argocd-cm argocd-rbac-cm argocd-cmd-params-cm argocd-notifications-cm -o yaml > "$BACKUP_DIR/configmaps.yaml"

# 8. SSH known hosts and TLS certs
kubectl get configmap -n argocd argocd-ssh-known-hosts-cm argocd-tls-certs-cm -o yaml > "$BACKUP_DIR/cert-configmaps.yaml"

# 9. Secrets (GPG keys, webhook secrets)
kubectl get secret -n argocd argocd-secret argocd-notifications-secret -o yaml > "$BACKUP_DIR/secrets.yaml"

echo "Backup completed: $BACKUP_DIR"
tar czf "$BACKUP_DIR.tar.gz" "$BACKUP_DIR"
```

### Restore Procedure

```bash
# 1. Install Argo CD (same version as backup)
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v2.9.0/manifests/ha/install.yaml

# 2. Wait for pods to be ready
kubectl wait --for=condition=available deploy -n argocd --all --timeout=300s

# 3. Restore in order (dependencies first):
#    ConfigMaps → Secrets → Projects → Repos → Clusters → Apps

# Strip resourceVersion and uid from backups before applying
for f in "$BACKUP_DIR"/*.yaml; do
  # Remove cluster-specific metadata
  yq 'del(.items[].metadata.resourceVersion, .items[].metadata.uid, .items[].metadata.creationTimestamp, .items[].metadata.generation)' "$f" > "${f}.clean"
done

kubectl apply -f "$BACKUP_DIR/configmaps.yaml.clean"
kubectl apply -f "$BACKUP_DIR/cert-configmaps.yaml.clean"
kubectl apply -f "$BACKUP_DIR/secrets.yaml.clean"
kubectl apply -f "$BACKUP_DIR/appprojects.yaml.clean"
kubectl apply -f "$BACKUP_DIR/repo-secrets.yaml.clean"
kubectl apply -f "$BACKUP_DIR/repo-cred-templates.yaml.clean"
kubectl apply -f "$BACKUP_DIR/cluster-secrets.yaml.clean"
kubectl apply -f "$BACKUP_DIR/applications.yaml.clean"
kubectl apply -f "$BACKUP_DIR/applicationsets.yaml.clean"

# 4. Restart Argo CD to pick up config changes
kubectl rollout restart deploy -n argocd
kubectl rollout restart statefulset -n argocd
```

### Partial Recovery Scenarios

**Scenario: Lost all Applications but clusters and repos intact:**
```bash
# If using ApplicationSets — they will regenerate Applications automatically
# If using App of Apps — re-sync the root application:
argocd app sync root --prune

# If neither — restore from backup:
kubectl apply -f applications-backup.yaml
```

**Scenario: Argo CD namespace deleted:**
```bash
# Full reinstall + restore from backup (see above)
# Git repos are the ultimate source of truth — apps will re-sync
```

**Scenario: Corrupted Redis cache:**
```bash
# Flush Redis and restart
kubectl exec -n argocd deploy/argocd-redis -- redis-cli FLUSHALL
kubectl rollout restart deploy -n argocd argocd-repo-server
kubectl rollout restart statefulset -n argocd argocd-application-controller
```

**Scenario: Lost cluster credentials:**
```bash
# Re-add clusters
argocd cluster add my-production-context --name production

# Or restore from backup:
kubectl apply -f cluster-secrets-backup.yaml
```
