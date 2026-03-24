# Service Mesh Troubleshooting Guide

## Table of Contents

- [Sidecar Injection Failures](#sidecar-injection-failures)
- [mTLS Handshake Errors](#mtls-handshake-errors)
- [VirtualService Not Routing](#virtualservice-not-routing)
- [503/504 Errors from Envoy](#503504-errors-from-envoy)
- [High Latency from Sidecar Overhead](#high-latency-from-sidecar-overhead)
- [Memory and CPU Overhead](#memory-and-cpu-overhead)
- [Istio Upgrade Failures](#istio-upgrade-failures)
- [Certificate Rotation Issues](#certificate-rotation-issues)
- [Debugging with istioctl](#debugging-with-istioctl)

---

## Sidecar Injection Failures

### Symptoms

- Pods start without the `istio-proxy` container.
- Only the application container is present in the pod spec.

### Common Causes and Fixes

**Namespace label missing**:
```bash
# Check namespace labels
kubectl get namespace <ns> --show-labels

# Add injection label
kubectl label namespace <ns> istio-injection=enabled

# For revision-based (canary upgrade)
kubectl label namespace <ns> istio.io/rev=1-20
```

**Pod has `sidecar.istio.io/inject: "false"` annotation**:
```bash
kubectl get pod <pod> -o jsonpath='{.metadata.annotations.sidecar\.istio\.io/inject}'
```

**Webhook not configured or unreachable**:
```bash
# Check mutating webhooks
kubectl get mutatingwebhookconfigurations | grep istio

# Check istiod logs for webhook errors
kubectl logs -n istio-system -l app=istiod -c discovery | grep -i webhook

# Verify istiod service is reachable
kubectl get svc istiod -n istio-system
```

**Init container `istio-init` failing** (iptables setup):
```bash
# Check init container logs
kubectl logs <pod> -c istio-init

# Common fix: ensure NET_ADMIN and NET_RAW capabilities
# Or use istio-cni plugin to avoid init container entirely
```

**Host network pods**: Pods with `hostNetwork: true` cannot use sidecar
injection. Use `sidecar.istio.io/inject: "false"` explicitly.

### Verify Injection

```bash
# Check if sidecar is present
kubectl get pod <pod> -o jsonpath='{.spec.containers[*].name}'
# Expected: my-app istio-proxy

# Verify proxy version
istioctl proxy-status | grep <pod>
```

---

## mTLS Handshake Errors

### Symptoms

- `RBAC: access denied` or `connection reset by peer` between services.
- Requests fail after enabling `STRICT` mTLS.
- `upstream connect error or disconnect/reset before headers` in Envoy logs.

### Diagnostic Steps

```bash
# Check mTLS status between services
istioctl authn tls-check <source-pod> <dest-service>

# Verify PeerAuthentication policies
kubectl get peerauthentication -A

# Check if destination has a sidecar (required for STRICT mTLS)
kubectl get pod <dest-pod> -o jsonpath='{.spec.containers[*].name}' | grep istio-proxy
```

### Common Fixes

**Non-mesh client calling STRICT mTLS service**:
```yaml
# Set PERMISSIVE mode for the specific port or namespace
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: allow-plaintext
  namespace: <namespace>
spec:
  selector:
    matchLabels:
      app: <service-needing-plaintext>
  mtls:
    mode: PERMISSIVE
  portLevelMtls:
    8080:
      mode: DISABLE    # Disable mTLS on specific port
```

**Certificate mismatch or expired certs**:
```bash
# Check proxy certificates
istioctl proxy-config secret <pod> -o json | \
  jq '.dynamicActiveSecrets[0].secret.tlsCertificate.certificateChain.inlineBytes' | \
  tr -d '"' | base64 -d | openssl x509 -text -noout

# Check cert expiry
istioctl proxy-config secret <pod> -o json | \
  jq -r '.dynamicActiveSecrets[0].secret.tlsCertificate.certificateChain.inlineBytes' | \
  base64 -d | openssl x509 -enddate -noout
```

**DestinationRule overriding mTLS**:
```bash
# Check if a DestinationRule disables mTLS
kubectl get destinationrule -A -o yaml | grep -A5 "tls:"
# Ensure trafficPolicy.tls.mode is ISTIO_MUTUAL, not DISABLE
```

---

## VirtualService Not Routing

### Symptoms

- Traffic ignores VirtualService rules, goes to default round-robin.
- Header-based routing not matching.
- Weight-based splitting not working as expected.

### Diagnostic Steps

```bash
# Validate configuration
istioctl analyze -n <namespace>

# Check VirtualService is applied
kubectl get virtualservice -n <namespace>

# Inspect Envoy route configuration
istioctl proxy-config routes <pod> -o json | \
  jq '.[] | select(.name == "80")'

# Check if VirtualService is synced to proxy
istioctl proxy-status
# Look for SYNCED status, not STALE
```

### Common Causes

**Host mismatch**: The `hosts` field in VirtualService must match the
Kubernetes service name exactly (short name within namespace, or FQDN).

```yaml
# WRONG — doesn't match any service
hosts: ["my-service.example.com"]

# CORRECT — matches Kubernetes service
hosts: ["my-service"]

# CORRECT — FQDN form
hosts: ["my-service.production.svc.cluster.local"]
```

**Missing DestinationRule subsets**: If VirtualService references subsets,
the DestinationRule must define them:

```bash
# Check subsets exist
kubectl get destinationrule <name> -o yaml | grep -A3 "subsets:"
```

**Gateway binding missing**: For ingress traffic, VirtualService must
reference the Gateway:

```yaml
spec:
  gateways:
    - my-gateway          # For ingress traffic
    - mesh                # For mesh-internal traffic (add both if needed)
```

**Conflicting VirtualServices**: Multiple VirtualServices for the same host
are merged, but conflicts can cause unpredictable behavior:

```bash
kubectl get virtualservice -A --field-selector metadata.name=<host>
```

**Route precedence**: Routes are evaluated top-to-bottom. Place specific
matches (header-based, URI-based) before catch-all routes.

---

## 503/504 Errors from Envoy

### 503 Upstream Connection Error

**Cause**: No healthy upstream endpoints, or circuit breaker triggered.

```bash
# Check upstream endpoints
istioctl proxy-config endpoints <pod> --cluster "outbound|80||svc.ns.svc.cluster.local"
# Look for HEALTHY status

# Check circuit breaker (outlier detection)
istioctl proxy-config cluster <pod> -o json | \
  jq '.[] | select(.name | contains("svc-name")) | .circuitBreakers'

# Check Envoy stats for overflow
kubectl exec <pod> -c istio-proxy -- \
  curl -s localhost:15000/stats | grep -E "upstream_cx_overflow|upstream_rq_pending_overflow"
```

**Fixes**:
- Increase `connectionPool` limits in DestinationRule.
- Check if destination pods are healthy and ready.
- Verify destination service port names follow Istio naming conventions
  (`http-`, `grpc-`, `tcp-` prefixes).

### 503 No Healthy Upstream

```bash
# Verify backend pods are running
kubectl get pods -l app=<service> -n <namespace>

# Check if endpoints are registered
kubectl get endpoints <service> -n <namespace>

# Check if service port naming is correct
kubectl get svc <service> -o yaml | grep -A5 "ports:"
# Port name MUST start with protocol prefix: http-, grpc-, tcp-, etc.
```

### 504 Upstream Request Timeout

```bash
# Check timeout configuration
istioctl proxy-config routes <pod> -o json | \
  jq '.. | .timeout? // empty'

# Default Envoy timeout is 15s. Increase in VirtualService:
```

```yaml
http:
  - timeout: 60s
    route:
      - destination:
          host: slow-service
```

### NR (No Route) Responses

Envoy returns 404 NR when no route matches:

```bash
# Dump all routes
istioctl proxy-config routes <pod>

# Check if the requested host:port combination has a matching route
istioctl proxy-config routes <pod> -o json | \
  jq '.[] | select(.virtualHosts[].domains[] | contains("target-host"))'
```

---

## High Latency from Sidecar Overhead

### Measuring Sidecar Latency

```bash
# Compare latency with and without sidecar
# From mesh pod (through sidecar):
kubectl exec mesh-pod -- curl -w "@curl-format.txt" -s -o /dev/null http://target:8080

# From non-mesh pod (direct):
kubectl exec non-mesh-pod -- curl -w "@curl-format.txt" -s -o /dev/null http://target:8080

# Check Envoy processing time via headers
# x-envoy-upstream-service-time shows upstream response time
# Compare with total request time to see proxy overhead
```

### Optimization Strategies

**Reduce Envoy configuration scope with Sidecar resource**:
```yaml
apiVersion: networking.istio.io/v1beta1
kind: Sidecar
metadata:
  name: limited-egress
  namespace: my-namespace
spec:
  egress:
    - hosts:
        - "./*"                    # Same namespace services
        - "istio-system/*"         # Istio services
        - "other-namespace/svc-a"  # Specific cross-namespace
```

This dramatically reduces the number of clusters/routes Envoy must maintain,
reducing memory and xDS update latency.

**Tune proxy concurrency**:
```yaml
# Match proxy worker threads to pod CPU limits
annotations:
  proxy.istio.io/config: |
    concurrency: 2
```

**Disable unused features**:
```yaml
meshConfig:
  enablePrometheusMerge: false    # If not using merged metrics
  defaultConfig:
    holdApplicationUntilProxyStarts: true
    proxyStatsMatcher:
      inclusionPrefixes:
        - "cluster.outbound"      # Only essential stats
```

**Use ambient mesh** for L4-only workloads — eliminates per-pod proxy entirely.

---

## Memory and CPU Overhead

### Diagnosing Resource Usage

```bash
# Check per-proxy resource usage
kubectl top pod -n <namespace> --containers | grep istio-proxy

# Check Envoy memory breakdown
kubectl exec <pod> -c istio-proxy -- curl -s localhost:15000/memory | python3 -m json.tool

# Check number of clusters/listeners/routes (correlates with memory)
istioctl proxy-config clusters <pod> | wc -l
istioctl proxy-config listeners <pod> | wc -l
istioctl proxy-config routes <pod> | wc -l
```

### Resource Limits

Set appropriate proxy resource limits:
```yaml
# Global defaults via MeshConfig
meshConfig:
  defaultConfig:
    proxyMetadata:
      ISTIO_META_REQUESTED_NETWORK_VIEW: ""
  resources:
    requests:
      cpu: 50m
      memory: 128Mi
    limits:
      cpu: 500m
      memory: 256Mi
```

Or per-pod annotation:
```yaml
annotations:
  sidecar.istio.io/proxyCPU: "50m"
  sidecar.istio.io/proxyMemory: "128Mi"
  sidecar.istio.io/proxyCPULimit: "500m"
  sidecar.istio.io/proxyMemoryLimit: "256Mi"
```

### Common Memory Bloat Causes

- **Too many services in mesh**: Each proxy gets config for ALL services by
  default. Use `Sidecar` resource to scope.
- **Large number of endpoints**: Each endpoint address is stored per proxy.
- **Access logging enabled with JSON format**: JSON access logs are memory-heavy.
- **High cardinality metrics**: Custom Envoy stats with unbounded label values.

---

## Istio Upgrade Failures

### Pre-Upgrade Checklist

```bash
# Check current version compatibility
istioctl version

# Run pre-upgrade analysis
istioctl analyze --all-namespaces

# Check for deprecated APIs
istioctl analyze -A 2>&1 | grep -i deprecated

# Backup current config
kubectl get istiooperator -n istio-system -o yaml > istio-backup.yaml
kubectl get virtualservice,destinationrule,gateway,peerauthentication,authorizationpolicy \
  -A -o yaml > mesh-config-backup.yaml
```

### Canary Upgrade (Recommended)

```bash
# Install new control plane revision
istioctl install --set revision=1-20 --set tag=1.20.0

# Verify both revisions are running
kubectl get pods -n istio-system -l app=istiod

# Migrate namespaces one at a time
kubectl label namespace <ns> istio.io/rev=1-20 --overwrite
kubectl label namespace <ns> istio-injection-     # Remove old label

# Restart pods to pick up new proxy version
kubectl rollout restart deployment -n <ns>

# Verify all proxies are on new version
istioctl proxy-status | grep "1.20"

# Remove old control plane after full migration
istioctl uninstall --revision 1-19
```

### Common Upgrade Issues

**CRD version conflicts**: Ensure CRDs are updated before control plane:
```bash
kubectl apply -f manifests/charts/base/crds/
```

**Webhook conflicts with multiple revisions**:
```bash
kubectl get mutatingwebhookconfigurations | grep istio
# Should show only one active default webhook
```

**Proxy version mismatch**: After upgrade, proxies still on old version:
```bash
# Find pods with old proxy version
istioctl proxy-status | awk '$5 != "1.20.0" {print}'

# Restart those deployments
kubectl rollout restart deployment <name> -n <namespace>
```

---

## Certificate Rotation Issues

### Check Certificate Status

```bash
# View current certificates in proxy
istioctl proxy-config secret <pod>

# Detailed cert info
istioctl proxy-config secret <pod> -o json | \
  jq -r '.dynamicActiveSecrets[] | select(.name == "default") |
  .secret.tlsCertificate.certificateChain.inlineBytes' | \
  base64 -d | openssl x509 -text -noout

# Check cert validity period
istioctl proxy-config secret <pod> -o json | \
  jq -r '.dynamicActiveSecrets[] | select(.name == "default") |
  .secret.tlsCertificate.certificateChain.inlineBytes' | \
  base64 -d | openssl x509 -dates -noout
```

### Common Certificate Issues

**Certificates not rotating (SDS failure)**:
```bash
# Check istiod CA logs
kubectl logs -n istio-system -l app=istiod | grep -i "certificate\|SDS\|error"

# Verify SDS is working
kubectl exec <pod> -c istio-proxy -- curl -s localhost:15000/certs | python3 -m json.tool
```

**Custom CA integration**: When using external CA (Vault, cert-manager):
```bash
# Check if cacerts secret exists
kubectl get secret cacerts -n istio-system

# Verify root cert matches across clusters (multi-cluster)
kubectl get secret cacerts -n istio-system -o jsonpath='{.data.root-cert\.pem}' | \
  base64 -d | openssl x509 -subject -issuer -noout
```

**Certificate TTL configuration**:
```yaml
# Adjust cert lifetime (default: 24h for workloads)
meshConfig:
  defaultConfig:
    proxyMetadata:
      SECRET_TTL: "24h"
  certificates:
    - secretName: dns-cert
      dnsNames: ["*.example.com"]
```

---

## Debugging with istioctl

### istioctl analyze — Configuration Validation

```bash
# Analyze all namespaces
istioctl analyze --all-namespaces

# Analyze specific namespace
istioctl analyze -n production

# Analyze local files before applying
istioctl analyze my-virtualservice.yaml

# Common issues detected:
# - VirtualService referencing non-existent DestinationRule
# - Gateway with conflicting port/host combinations
# - PeerAuthentication conflicts
# - Unreferenced Sidecar resources
```

### istioctl proxy-config — Envoy Configuration Inspection

```bash
# Listeners (what ports/protocols the proxy listens on)
istioctl proxy-config listeners <pod>
istioctl proxy-config listeners <pod> --port 80 -o json

# Routes (how requests are matched to upstreams)
istioctl proxy-config routes <pod>
istioctl proxy-config routes <pod> --name 80 -o json

# Clusters (upstream service endpoints)
istioctl proxy-config clusters <pod>
istioctl proxy-config clusters <pod> --fqdn "svc.ns.svc.cluster.local" -o json

# Endpoints (actual backend pod IPs)
istioctl proxy-config endpoints <pod>
istioctl proxy-config endpoints <pod> --cluster "outbound|80||svc.ns.svc.cluster.local"

# Secrets (certificates)
istioctl proxy-config secret <pod>

# Full config dump
istioctl proxy-config all <pod> -o json > envoy-config-dump.json
```

### istioctl proxy-status — Sync State

```bash
# Check sync status of all proxies
istioctl proxy-status

# Output columns:
# NAME            CLUSTER   CDS   LDS   EDS   RDS   ECDS  ISTIOD
# pod.namespace   cluster1  SYNCED SYNCED SYNCED SYNCED ...  istiod-xxx

# CDS = Cluster Discovery Service
# LDS = Listener Discovery Service
# EDS = Endpoint Discovery Service
# RDS = Route Discovery Service
# STALE = proxy has outdated config (investigate istiod connectivity)
```

### Debug Logging

```bash
# Enable debug logging on a specific proxy
istioctl proxy-config log <pod> --level debug

# Enable for specific Envoy component
istioctl proxy-config log <pod> --level connection:debug,router:debug

# View proxy logs
kubectl logs <pod> -c istio-proxy --tail=100 -f

# Reset to default log level
istioctl proxy-config log <pod> --level info
```

### Envoy Admin Interface

```bash
# Port-forward to Envoy admin (port 15000)
kubectl port-forward <pod> 15000:15000

# Useful endpoints:
# /config_dump    — Full Envoy config
# /clusters       — Upstream cluster health
# /listeners      — Active listeners
# /stats          — Envoy statistics
# /stats?filter=upstream_cx  — Connection stats
# /ready          — Readiness status
# /certs          — Loaded certificates
# /memory         — Memory allocation stats

# One-liner stat check
kubectl exec <pod> -c istio-proxy -- \
  curl -s localhost:15000/stats | grep -E "upstream_rq_total|upstream_rq_5xx"
```

### Common Debug Workflows

**Request not reaching destination**:
1. `istioctl proxy-config listeners <source-pod>` — verify outbound listener exists.
2. `istioctl proxy-config routes <source-pod>` — verify route to destination.
3. `istioctl proxy-config endpoints <source-pod>` — verify healthy endpoints.
4. `istioctl proxy-config log <source-pod> --level debug` — trace request flow.

**Unexpected 403 Forbidden**:
1. `istioctl analyze -n <ns>` — check for policy issues.
2. `kubectl get authorizationpolicy -n <ns>` — list active policies.
3. Check RBAC debug logs: `istioctl proxy-config log <pod> --level "rbac:debug"`.
4. Look for `shadow denied` vs `enforced denied` in proxy logs.

**Config not applying**:
1. `istioctl proxy-status` — check for STALE entries.
2. `kubectl logs -n istio-system -l app=istiod` — check istiod errors.
3. `istioctl analyze` — validate configuration correctness.
