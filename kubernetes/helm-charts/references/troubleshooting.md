# Helm Troubleshooting Guide

## Table of Contents

- [Failed Releases](#failed-releases)
- [Stuck and Pending Releases](#stuck-and-pending-releases)
- [Rollback Problems](#rollback-problems)
- [Hook Failures](#hook-failures)
- [Template Rendering Errors](#template-rendering-errors)
- [Dependency Issues](#dependency-issues)
- [OCI Registry Problems](#oci-registry-problems)
- [Upgrade Conflicts](#upgrade-conflicts)
- [Values and Configuration Issues](#values-and-configuration-issues)
- [Namespace and RBAC Issues](#namespace-and-rbac-issues)
- [Resource Conflicts](#resource-conflicts)
- [Performance and Timeout Issues](#performance-and-timeout-issues)
- [Diagnostic Commands Reference](#diagnostic-commands-reference)

---

## Failed Releases

### Release in `failed` State

**Symptom:** `helm list` shows status `failed`. New `helm upgrade` may refuse to proceed.

```bash
# Check release status
helm status myrelease -n mynamespace

# View release history
helm history myrelease -n mynamespace

# Check what was attempted
helm get manifest myrelease -n mynamespace
helm get values myrelease -n mynamespace -a
```

**Fix 1: Retry the upgrade**

```bash
helm upgrade myrelease ./mychart -f values.yaml -n mynamespace --force
```

`--force` deletes and recreates changed resources (causes brief downtime).

**Fix 2: Rollback then upgrade**

```bash
helm rollback myrelease 0 -n mynamespace    # 0 = previous revision
helm upgrade myrelease ./mychart -f values.yaml -n mynamespace
```

**Fix 3: Uninstall and reinstall (data-loss risk)**

```bash
helm uninstall myrelease -n mynamespace --keep-history
# Fix the issue
helm upgrade --install myrelease ./mychart -n mynamespace
```

### Release Exists but `helm list` Shows Nothing

**Cause:** Release is in a different namespace, or using a different storage driver.

```bash
# Search all namespaces
helm list --all-namespaces --all

# Check if using a non-default storage backend
kubectl get secrets -A -l "owner=helm"
kubectl get configmaps -A -l "owner=helm"
```

### `cannot re-use a name that is still in use`

**Cause:** A release with that name exists (possibly in failed/uninstalling state).

```bash
helm list -n mynamespace --all --filter myrelease

# If stuck in uninstalling:
helm uninstall myrelease -n mynamespace --no-hooks

# If the Helm secret is orphaned, manually remove it:
kubectl delete secret -n mynamespace -l "name=myrelease,owner=helm"
```

---

## Stuck and Pending Releases

### Release Stuck in `pending-install`

**Cause:** Helm crashed or lost connection mid-install. The release secret exists but nothing was deployed.

```bash
# Check the state
helm list -n mynamespace --pending

# Option 1: Delete the pending release secret and retry
kubectl delete secret -n mynamespace sh.helm.release.v1.myrelease.v1
helm install myrelease ./mychart -n mynamespace

# Option 2: Rollback (if a previous version exists)
helm rollback myrelease 0 -n mynamespace
```

### Release Stuck in `pending-upgrade`

**Cause:** Upgrade was interrupted. Partial resources may be deployed.

```bash
# Check what resources exist
helm get manifest myrelease -n mynamespace | kubectl get -f - 2>&1

# Force rollback to last known good
helm rollback myrelease 0 -n mynamespace --force

# If rollback also fails, delete the pending secret:
# Find the latest revision
kubectl get secrets -n mynamespace -l "name=myrelease,owner=helm" --sort-by=.metadata.creationTimestamp
# Delete the pending one (highest version)
kubectl delete secret sh.helm.release.v1.myrelease.v3 -n mynamespace
```

### Helm Command Hangs During Install/Upgrade

**Cause:** Helm waits for resources to become ready (if `--wait` is used). Common culprits:
- Pod stuck in `ImagePullBackOff` or `CrashLoopBackOff`
- PVC stuck in `Pending` (no StorageClass or capacity)
- Service LoadBalancer stuck in `Pending` (no cloud LB provisioner)

```bash
# In another terminal, check pod status
kubectl get pods -n mynamespace -l "app.kubernetes.io/instance=myrelease"
kubectl describe pod <podname> -n mynamespace
kubectl logs <podname> -n mynamespace

# Check events
kubectl get events -n mynamespace --sort-by=.lastTimestamp | tail -30

# Check PVC
kubectl get pvc -n mynamespace

# Cancel and retry with --timeout
# Ctrl-C the hanging command, then:
helm upgrade myrelease ./mychart --timeout 10m --atomic -n mynamespace
```

---

## Rollback Problems

### `Error: release has no N revisions`

```bash
# List all revisions
helm history myrelease -n mynamespace

# Rollback to the specific revision number shown in history
helm rollback myrelease <revision> -n mynamespace
```

### Rollback Doesn't Restore Previous State

**Cause:** Rollback only restores the Helm-managed manifest. Resources modified outside Helm (kubectl edit, operators) won't be reverted.

```bash
# Compare manifests between revisions
helm get manifest myrelease -n mynamespace --revision 3 > rev3.yaml
helm get manifest myrelease -n mynamespace --revision 2 > rev2.yaml
diff rev2.yaml rev3.yaml
```

### PVC Not Deleted on Rollback

**Expected behavior.** Helm never deletes PVCs to prevent data loss. Clean up manually:

```bash
kubectl delete pvc -n mynamespace -l "app.kubernetes.io/instance=myrelease"
```

### CRDs Not Rolled Back

**Expected behavior.** Helm never modifies or deletes CRDs after initial creation. Manually revert:

```bash
kubectl apply -f crds/previous-version/
```

---

## Hook Failures

### Pre-install/Pre-upgrade Hook Fails

**Symptom:** `Error: pre-install hook failed: job "myrelease-migrate" failed`

```bash
# Check hook job status
kubectl get jobs -n mynamespace -l "helm.sh/hook"
kubectl describe job myrelease-migrate -n mynamespace
kubectl logs job/myrelease-migrate -n mynamespace

# Check if previous hook resources still exist
kubectl get jobs,pods -n mynamespace -l "helm.sh/hook"
```

**Fix: Clean up old hooks and retry**

```bash
# Delete old hook resources
kubectl delete job myrelease-migrate -n mynamespace

# Retry with hook delete policy
# In your hook template, add:
#   "helm.sh/hook-delete-policy": before-hook-creation
helm upgrade myrelease ./mychart -n mynamespace
```

### Hook Timeout

```bash
# Increase timeout
helm upgrade myrelease ./mychart --timeout 15m -n mynamespace

# Or skip hooks
helm upgrade myrelease ./mychart --no-hooks -n mynamespace
```

### Hook Runs in Wrong Order

**Fix:** Set explicit weights. Lower numbers run first:

```yaml
annotations:
  "helm.sh/hook": pre-upgrade
  "helm.sh/hook-weight": "-10"   # Runs before weight "0"
```

### Test Hook Fails

```bash
# Run tests with output
helm test myrelease -n mynamespace --logs

# Check test pod
kubectl get pods -n mynamespace -l "helm.sh/hook=test"
kubectl logs <test-pod> -n mynamespace

# Clean up failed test pods
kubectl delete pods -n mynamespace -l "helm.sh/hook=test"
```

---

## Template Rendering Errors

### `Error: template: ... function "xyz" not defined`

**Cause:** Typo in function name, or using a function not available in Sprig/Helm.

```bash
# Debug: render templates locally to see the error
helm template myrelease ./mychart -f values.yaml --debug 2>&1 | head -50
```

Common typos: `toYAML` (should be `toYaml`), `nIndent` (should be `nindent`).

### `nil pointer evaluating interface {}.fieldName`

**Cause:** Accessing a nested value that doesn't exist.

```yaml
# BAD: crashes if image is not defined
{{ .Values.image.repository }}

# GOOD: guard with conditionals or default
{{- with .Values.image }}
{{ .repository }}
{{- end }}

# Or use dig for deep access
{{ dig "image" "repository" "default-repo" .Values }}
```

### YAML Indentation Errors

**Symptom:** `error converting YAML to JSON` or `did not find expected key`.

```bash
# Render and validate
helm template myrelease ./mychart 2>&1 | head -100

# Common cause: wrong nindent value
# Check rendered output for misaligned YAML
helm template myrelease ./mychart > rendered.yaml
yamllint rendered.yaml
```

**Fix patterns:**

```yaml
# WRONG — double indent from include + nindent
labels:
  {{ include "myapp.labels" . | nindent 4 }}    # Missing {{- (leading whitespace)

# RIGHT — trim whitespace before include
labels:
  {{- include "myapp.labels" . | nindent 4 }}
```

### `error unmarshaling JSON: ... cannot unmarshal string into Go value`

**Cause:** YAML type mismatch. A value expected as number/bool is quoted as string.

```yaml
# BAD
replicas: {{ .Values.replicaCount | quote }}    # "3" is a string, not integer

# GOOD
replicas: {{ .Values.replicaCount | int }}
```

### Empty Manifest / Missing Resources

**Cause:** Conditional block evaluates to false.

```bash
# Debug: check which templates produce output
helm template myrelease ./mychart --show-only templates/ingress.yaml -f values.yaml

# Check values that control conditionals
helm template myrelease ./mychart --debug 2>&1 | grep -A 5 "ingress"
```

### `YAML parse error on ... cannot unmarshal !!seq`

**Cause:** Passing a list where a map is expected, or vice versa.

```yaml
# BAD: annotations expects a map, not a list
annotations:
  - key: value

# GOOD
annotations:
  key: value
```

---

## Dependency Issues

### `Error: found in Chart.yaml, but missing in charts/ directory`

```bash
# Update dependencies
helm dependency update ./mychart

# If using OCI:
helm dependency build ./mychart

# Check Chart.lock matches Chart.yaml
cat ./mychart/Chart.lock
```

### Dependency Version Not Found

```bash
# List available versions
helm search repo bitnami/postgresql --versions | head -20

# For OCI registries
helm show chart oci://registry.example.com/charts/mychart --version 1.0.0

# Fix version range in Chart.yaml
# Bad:  version: "15.0.0"   (exact, may not exist)
# Good: version: "~15.0.0"  (15.0.x range)
```

### `Error: no cached repo found` / Repository Issues

```bash
# Re-add and update repos
helm repo list
helm repo update

# If repo URL changed:
helm repo remove bitnami
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
helm dependency update ./mychart
```

### Circular Dependency

Helm does not support circular dependencies. Refactor: extract shared logic into a library chart that both charts depend on.

### Subchart Values Not Applied

```yaml
# values.yaml — subchart values must be under the subchart's key
# If dependency name is "postgresql" with alias "db":
db:                    # Use the alias, not the name
  auth:
    postgresPassword: "secret"
```

---

## OCI Registry Problems

### `Error: failed to authorize: failed to fetch oauth token`

```bash
# Re-login
helm registry login registry.example.com -u username

# For ECR:
aws ecr get-login-password --region us-east-1 | \
  helm registry login --username AWS --password-stdin 123456.dkr.ecr.us-east-1.amazonaws.com

# For GCR/GAR:
gcloud auth print-access-token | \
  helm registry login -u oauth2accesstoken --password-stdin us-docker.pkg.dev
```

### `Error: failed to do request ... x509: certificate`

```bash
# Skip TLS verification (dev only)
helm push mychart-1.0.0.tgz oci://registry.example.com/charts --insecure-skip-tls-verify

# Add CA certificate
helm push mychart-1.0.0.tgz oci://registry.example.com/charts --ca-file /path/to/ca.crt

# Or set system-wide
export HELM_REGISTRY_CONFIG=~/.config/helm/registry.json
```

### `Error: unexpected status from HEAD request ... 404 Not Found`

**Cause:** The chart or version doesn't exist in the OCI registry, or the path is wrong.

```bash
# Verify the chart exists
# OCI uses: oci://registry/path/chartname (no :tag here)
helm show chart oci://registry.example.com/charts/mychart --version 1.0.0

# Common mistake: including version in the OCI URL
# WRONG: oci://registry.example.com/charts/mychart:1.0.0
# RIGHT: oci://registry.example.com/charts/mychart --version 1.0.0
```

### Push Fails with `MANIFEST_INVALID`

```bash
# Ensure chart is packaged correctly
helm package ./mychart
# Check the .tgz
tar tzf mychart-1.0.0.tgz | head

# Ensure Chart.yaml version matches
grep "^version:" mychart/Chart.yaml
```

---

## Upgrade Conflicts

### `Error: UPGRADE FAILED: another operation ... is in progress`

**Cause:** A previous Helm operation didn't complete cleanly.

```bash
# Check for pending operations
helm list -n mynamespace --all

# If stuck in pending-upgrade:
kubectl get secrets -n mynamespace -l "name=myrelease,owner=helm" \
  --sort-by=.metadata.creationTimestamp

# Remove the stuck release secret (latest revision with status != deployed)
kubectl delete secret sh.helm.release.v1.myrelease.v<N> -n mynamespace
```

### `Error: UPGRADE FAILED: has no deployed releases`

**Cause:** All revisions are in failed state. No "deployed" revision to upgrade from.

```bash
# Option 1: Uninstall and reinstall
helm uninstall myrelease -n mynamespace
helm install myrelease ./mychart -n mynamespace

# Option 2: If you need to keep history
helm rollback myrelease 1 -n mynamespace   # Roll back to revision 1
```

### `invalid ownership metadata ... annotation ... is missing`

**Cause:** Resource was created outside Helm, or by a different release.

```bash
# Check resource labels/annotations
kubectl get deployment myapp -n mynamespace -o jsonpath='{.metadata.annotations}' | jq .

# Option 1: Adopt the resource
kubectl annotate deployment myapp -n mynamespace \
  meta.helm.sh/release-name=myrelease \
  meta.helm.sh/release-namespace=mynamespace --overwrite
kubectl label deployment myapp -n mynamespace \
  app.kubernetes.io/managed-by=Helm --overwrite

# Option 2: Delete and let Helm recreate
kubectl delete deployment myapp -n mynamespace
helm upgrade myrelease ./mychart -n mynamespace
```

### Immutable Field Error

**Symptom:** `field is immutable` on upgrade (common with Service `clusterIP`, Job `selector`).

```bash
# For Services — preserve clusterIP:
# In template, use lookup to keep existing IP:
# clusterIP: {{ (lookup "v1" "Service" .Release.Namespace (include "myapp.fullname" .)).spec.clusterIP }}

# For Jobs — delete and recreate:
kubectl delete job myrelease-setup -n mynamespace
helm upgrade myrelease ./mychart -n mynamespace

# For StatefulSets — cannot change volumeClaimTemplates:
# Must delete the StatefulSet (pods will be recreated):
kubectl delete statefulset myapp -n mynamespace --cascade=orphan
helm upgrade myrelease ./mychart -n mynamespace
```

---

## Values and Configuration Issues

### Values Not Taking Effect

```bash
# Check computed values (all sources merged)
helm get values myrelease -n mynamespace -a

# Check specific value
helm get values myrelease -n mynamespace -a | grep -A 5 "image"

# Render template to verify
helm template myrelease ./mychart -f values.yaml --show-only templates/deployment.yaml
```

### `--set` Syntax Gotchas

```bash
# Commas in values: escape or use --set-string
helm upgrade rel ./chart --set-string "annotations.key=a\,b"

# Dots in keys: use brackets
helm upgrade rel ./chart --set "ingress.hosts[0].host=example.com"

# JSON values
helm upgrade rel ./chart --set-json 'resources={"requests":{"cpu":"100m"}}'

# File contents
helm upgrade rel ./chart --set-file config=./app.conf
```

### values.schema.json Validation Failures

```bash
# Check what's failing
helm lint ./mychart -f values.yaml 2>&1

# Test specific values
helm template test ./mychart -f values.yaml 2>&1 | head -20

# Temporarily bypass (debugging only): remove values.schema.json
```

---

## Namespace and RBAC Issues

### `Error: ... is forbidden: User ... cannot ... in the namespace`

```bash
# Check your current context
kubectl config current-context
kubectl auth can-i create deployments -n mynamespace

# Common fix: ensure the ServiceAccount/Role has Helm-needed permissions
# Helm needs: get, list, watch, create, update, patch, delete on all managed resource types
```

### Resources Created in Wrong Namespace

```bash
# Always specify namespace explicitly
helm upgrade myrelease ./mychart -n correct-namespace --create-namespace

# Check for hardcoded namespaces in templates
grep -r "namespace:" ./mychart/templates/
# Templates should use {{ .Release.Namespace }} not hardcoded values
```

---

## Resource Conflicts

### `Error: rendered manifests contain a resource that already exists`

```bash
# Find who owns the resource
kubectl get <resource> <name> -n mynamespace -o jsonpath='{.metadata.labels}'

# If it should be managed by this release, adopt it (see annotation fix above)
# If it belongs to another release, rename your resource
```

### Leftover Resources After Uninstall

```bash
# Find orphaned resources
kubectl get all -n mynamespace -l "app.kubernetes.io/instance=myrelease"

# Common leftovers: PVCs, Secrets with resource-policy: keep, CRDs
kubectl get pvc,secrets -n mynamespace -l "app.kubernetes.io/instance=myrelease"

# Check for resource-policy: keep annotation
kubectl get secrets -n mynamespace -o json | \
  jq '.items[] | select(.metadata.annotations["helm.sh/resource-policy"]=="keep") | .metadata.name'
```

---

## Performance and Timeout Issues

### Helm Operations Are Slow

```bash
# Too many release secrets (history)
kubectl get secrets -n mynamespace -l "owner=helm" | wc -l

# Reduce history
helm upgrade myrelease ./mychart --history-max 5 -n mynamespace

# Large chart packages
du -sh mychart/
# Add large files to .helmignore
```

### Timeout During Install/Upgrade

```bash
# Increase timeout
helm upgrade myrelease ./mychart --timeout 15m --wait -n mynamespace

# Use --atomic for auto-rollback on timeout
helm upgrade myrelease ./mychart --timeout 10m --atomic -n mynamespace

# Skip waiting (deploy and check manually)
helm upgrade myrelease ./mychart -n mynamespace  # no --wait
kubectl rollout status deployment/myapp -n mynamespace --timeout=600s
```

---

## Diagnostic Commands Reference

```bash
# === Release inspection ===
helm list -n NS --all                           # All releases including failed
helm list --all-namespaces --all                 # Everything across all namespaces
helm status RELEASE -n NS                       # Release status + notes
helm history RELEASE -n NS                      # Revision history
helm get manifest RELEASE -n NS                 # Deployed manifests
helm get values RELEASE -n NS -a                # All computed values
helm get hooks RELEASE -n NS                    # Hook resources
helm get notes RELEASE -n NS                    # NOTES.txt output
helm get all RELEASE -n NS                      # Everything

# === Template debugging ===
helm template RELEASE ./CHART -f VALUES --debug           # Render with debug info
helm template RELEASE ./CHART --show-only templates/X.yaml  # Render single template
helm template RELEASE ./CHART --validate                   # Render + K8s schema check
helm lint ./CHART -f VALUES --strict                       # Lint with strict mode

# === Diff and dry-run ===
helm diff upgrade RELEASE ./CHART -f VALUES -n NS         # Show what would change
helm upgrade RELEASE ./CHART --dry-run=server -n NS       # Server-side dry-run

# === Cluster investigation ===
kubectl get events -n NS --sort-by=.lastTimestamp          # Recent events
kubectl describe pod POD -n NS                              # Pod details
kubectl logs POD -n NS --previous                           # Previous container logs
kubectl get secrets -n NS -l "owner=helm"                   # Helm release secrets

# === Cleanup ===
helm uninstall RELEASE -n NS --keep-history                # Remove but keep history
helm uninstall RELEASE -n NS --no-hooks                    # Skip delete hooks
kubectl delete secret -n NS -l "name=RELEASE,owner=helm"  # Nuclear: remove all history
```
