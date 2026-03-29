---
name: kyverno
description: |
  Kubernetes native policy engine for validation/mutation/generation. Use for Kubernetes policy enforcement.
  NOT for general OPA/Gatekeeper without cloud-native focus.
tested: 2026-03-29
---
# Kyverno

Kubernetes-native policy engine using YAML (not Rego). Policies as Kubernetes resources.

## Quick Reference

```bash
# Install
helm repo add kyverno https://kyverno.github.io/kyverno/
helm install kyverno kyverno/kyverno -n kyverno --create-namespace

# Apply/Test
kubectl apply -f policy.yaml
kyverno test . --target-policy require-labels
kubectl get policyreport -A
```

## Policy Types

### Validate

Block non-compliant resources.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-labels
spec:
  validationFailureAction: Enforce  # Enforce|Audit
  rules:
  - name: check-team-label
    match:
      resources:
        kinds:
        - Pod
    validate:
      message: "Pod must have team label"
      pattern:
        metadata:
          labels:
            team: "?*"
```

**Input:** Pod without `team` label
**Output:** `Error: admission webhook denied: Pod must have team label`
### Mutate

Modify resources on creation.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: add-default-labels
spec:
  rules:
  - name: add-env-label
    match:
      resources:
        kinds:
        - Pod
    mutate:
      patchStrategicMerge:
        metadata:
          labels:
            environment: production
```

**Input:** Pod creation request
**Output:** Pod created with `environment: production` label added
### Generate

Create additional resources.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: generate-network-policy
spec:
  rules:
  - name: create-default-deny
    match:
      resources:
        kinds:
        - Namespace
    generate:
      apiVersion: networking.k8s.io/v1
      kind: NetworkPolicy
      name: default-deny
      namespace: "{{request.object.metadata.name}}"
      data:
        spec:
          podSelector: {}
          policyTypes:
          - Ingress
          - Egress
```

**Input:** Namespace `app-ns` created
**Output:** NetworkPolicy `default-deny` created in `app-ns`
### Cleanup

Delete resources based on conditions.

```yaml
apiVersion: kyverno.io/v2alpha1
kind: ClusterCleanupPolicy
metadata:
  name: cleanup-old-pods
spec:
  schedule: "0 0 * * *"
  match:
    resources:
      kinds:
      - Pod
  conditions:
    - key: "{{ time_since('','{{ metadata.creationTimestamp }}','') }}"
      operator: GreaterThan
      value: 168h
  exclude:
    resources:
      namespaces:
      - kube-system
```
## CRD Types

### ClusterPolicy

Cluster-wide scope. Affects all namespaces.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: cluster-wide-policy
spec:
  validationFailureAction: Enforce
  background: true
  rules:
  - name: rule-name
    match:
      resources:
        kinds:
        - Deployment
        namespaces:
        - "prod-*"
    validate:
      message: "Message here"
      pattern:
        spec:
          replicas: ">=2"
```
### Policy

Namespace-scoped. Affects single namespace.

```yaml
apiVersion: kyverno.io/v1
kind: Policy
metadata:
  name: namespace-policy
  namespace: production
spec:
  validationFailureAction: Enforce
  rules:
  - name: restrict-images
    match:
      resources:
        kinds:
        - Pod
    validate:
      message: "Only approved registries"
      pattern:
        spec:
          containers:
          - image: "registry.company.io/* | gcr.io/company/*"
```
### PolicyException

Exclude specific resources from policies.

```yaml
apiVersion: kyverno.io/v2alpha1
kind: PolicyException
metadata:
  name: exception-for-legacy
  namespace: kyverno
spec:
  exceptions:
  - policyName: require-labels
    ruleNames:
    - check-team-label
  match:
    resources:
    - kind: Pod
      namespace: legacy-system
      names:
      - "legacy-app-*"
```
## Match/Exclude Patterns

```yaml
rules:
- name: complex-match
  match:
    any:
    - resources:
        kinds:
        - Pod
        namespaces:
        - "prod-*"
      subjects:
      - kind: User
        name: admin@company.com
    - resources:
        kinds:
        - Deployment
        selector:
          matchLabels:
            critical: "true"
  exclude:
    resources:
      namespaces:
      - kube-system
      - kyverno
```
## Variables and Context

```yaml
rules:
- name: use-variables
  context:
  - name: apiCall
    apiCall:
      urlPath: "/api/v1/namespaces/{{request.namespace}}"
  match:
    resources:
      kinds:
      - Pod
  validate:
    message: "Namespace must be labeled approved=true"
    deny:
      conditions:
      - key: "{{apiCall.data.metadata.labels.approved}}"
        operator: NotEquals
        value: "true"
```
## Predefined Variables

| Variable | Description |
|----------|-------------|
| `{{request.object}}` | Full resource being evaluated |
| `{{request.namespace}}` | Target namespace |
| `{{request.operation}}` | CREATE/UPDATE/DELETE/CONNECT |
| `{{request.userInfo.username}}` | Authenticated user |
| `{{request.userInfo.groups}}` | User's groups |
| `{{element}}` | Current element in foreach |
| `{{elementIndex}}` | Index in foreach |

## Kyverno CLI

```bash
# Install CLI
brew install kyverno

# Validate/test/scan
kyverno validate policy.yaml
kyverno test . --target-policy require-labels
kyverno apply policy.yaml --resource resource.yaml
kyverno scan --policy require-labels
```
## Test File Structure

```yaml
# kyverno-test.yaml
name: test-require-labels
policies:
- policy.yaml
resources:
- resources.yaml
results:
- policy: require-labels
  rule: check-team-label
  resource: good-pod
  kind: Pod
  result: pass
- policy: require-labels
  rule: check-team-label
  resource: bad-pod
  kind: Pod
  result: fail
```
## Admission Controller Modes

```yaml
spec:
  validationFailureAction: Enforce   # Block non-compliant
  # OR
  validationFailureAction: Audit     # Allow but report
  background: true
  webhookTimeoutSeconds: 30
  failurePolicy: Fail  # Fail|Ignore if webhook down
```

## Common Patterns

### Require Resource Limits

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-resources
spec:
  validationFailureAction: Enforce
  rules:
  - name: check-limits
    match:
      resources:
        kinds:
        - Pod
    validate:
      message: "CPU/memory limits required"
      pattern:
        spec:
          containers:
          - resources:
              limits:
                memory: "?*"
                cpu: "?*"
              requests:
                memory: "?*"
                cpu: "?*"
```

### Disallow Latest Tag

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-latest
spec:
  validationFailureAction: Enforce
  rules:
  - name: validate-image-tag
    match:
      resources:
        kinds:
        - Pod
    validate:
      message: "Using 'latest' tag is not allowed"
      pattern:
        spec:
          containers:
          - image: "!*:latest"
```

### Auto-Inject Sidecar

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: inject-istio
spec:
  rules:
  - name: add-istio-proxy
    match:
      resources:
        kinds:
        - Pod
        namespaces:
        - "istio-enabled"
    mutate:
      patchStrategicMerge:
        spec:
          containers:
          - name: istio-proxy
            image: istio/proxyv2:1.18.0
            args:
            - proxy
            - sidecar
```

### Verify Image Signatures

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image
spec:
  validationFailureAction: Enforce
  rules:
  - name: verify-cosign
    match:
      resources:
        kinds:
        - Pod
    verifyImages:
    - imageReferences:
      - "ghcr.io/company/*"
      attestors:
      - entries:
        - keys:
            publicKeys: |
              -----BEGIN PUBLIC KEY-----
              MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE...
              -----END PUBLIC KEY-----
```

## Policy Reports

```bash
# View reports
kubectl get clusterpolicyreport
kubectl get policyreport -n production
kubectl get policyreport -l kyverno.io/policy=require-labels
```

Report structure:
```yaml
results:
- policy: require-labels
  rule: check-team-label
  resource: pod/nginx
  result: fail
  message: "Pod must have team label"
  scored: true
  severity: medium
```

## Troubleshooting

```bash
# Check policy/webhook/logs
kubectl get clusterpolicy require-labels -o yaml
kubectl get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg
kubectl logs -n kyverno -l app.kubernetes.io/name=kyverno

# Force scan/adjust timeout
kubectl annotate clusterpolicy require-labels kyverno.io/force-scan=true
kubectl patch clusterpolicy require-labels --type merge -p '{"spec":{"webhookTimeoutSeconds":30}}'
```

## Best Practices

1. **Start with Audit mode**: Use `validationFailureAction: Audit` initially
2. **Use ClusterPolicy for standards**: Namespace policies for exceptions
3. **Test with CLI**: Validate before applying to cluster
4. **Monitor reports**: Set up alerts on policy failures
5. **Document exceptions**: Use PolicyException with clear justification
6. **Version policies**: Track in Git, use GitOps workflow
7. **Limit scope**: Use match/exclude to avoid system namespaces
8. **Set severity**: Helps prioritize violations

## Helm Values (Key)

```yaml
replicas: 3
resources:
  limits:
    memory: 512Mi
    cpu: 500m
config:
  webhooks:
    - namespaceSelector:
        matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values:
          - kube-system
          - kyverno
features:
  reports:
    enabled: true
  admission:
    enabled: true
```

## Best Practices

1. **Start with Audit mode**: Use `validationFailureAction: Audit` initially
2. **Use ClusterPolicy for standards**: Namespace policies for exceptions
3. **Test with CLI**: Validate before applying to cluster
4. **Monitor reports**: Set up alerts on policy failures
5. **Document exceptions**: Use PolicyException with clear justification
6. **Version policies**: Track in Git, use GitOps workflow
7. **Limit scope**: Use match/exclude to avoid system namespaces
8. **Set severity**: Helps prioritize violations
