# Istio Troubleshooting Guide

## Table of Contents

- [Diagnostic Tools Overview](#diagnostic-tools-overview)
- [Sidecar Injection Issues](#sidecar-injection-issues)
  - [Automatic Injection Not Working](#automatic-injection-not-working)
  - [Injection Webhook Errors](#injection-webhook-errors)
  - [Init Container Failures](#init-container-failures)
- [503 Errors](#503-errors)
  - [Upstream Connect Error](#upstream-connect-error)
  - [No Healthy Upstream](#no-healthy-upstream)
  - [Circuit Breaking Triggered](#circuit-breaking-triggered)
  - [Upstream Overflow](#upstream-overflow)
- [mTLS Handshake Failures](#mtls-handshake-failures)
  - [Mixed Mode Issues](#mixed-mode-issues)
  - [Certificate Rotation Failures](#certificate-rotation-failures)
  - [SPIFFE Identity Mismatch](#spiffe-identity-mismatch)
- [Traffic Not Routing Correctly](#traffic-not-routing-correctly)
  - [VirtualService Not Applied](#virtualservice-not-applied)
  - [Conflicting VirtualServices](#conflicting-virtualservices)
  - [Subset Not Found](#subset-not-found)
  - [Host Resolution Issues](#host-resolution-issues)
- [Envoy Config Not Updating](#envoy-config-not-updating)
  - [Config Propagation Delays](#config-propagation-delays)
  - [xDS Push Failures](#xds-push-failures)
  - [Stale Endpoints](#stale-endpoints)
- [Performance Issues](#performance-issues)
  - [Memory and CPU Overhead](#memory-and-cpu-overhead)
  - [Slow Startup](#slow-startup)
  - [High Latency](#high-latency)
  - [xDS Config Size](#xds-config-size)
- [Debugging with istioctl](#debugging-with-istioctl)
  - [proxy-status](#proxy-status)
  - [proxy-config](#proxy-config)
  - [istioctl analyze](#istioctl-analyze)
  - [istioctl bug-report](#istioctl-bug-report)
- [Envoy Proxy Logs Analysis](#envoy-proxy-logs-analysis)
  - [Enabling Debug Logging](#enabling-debug-logging)
  - [Response Flag Codes](#response-flag-codes)
  - [Access Log Format](#access-log-format)
- [Kiali Issues](#kiali-issues)
  - [Service Graph Not Loading](#service-graph-not-loading)
  - [Missing Metrics](#missing-metrics)
- [Common Scenarios and Fixes](#common-scenarios-and-fixes)

---

## Diagnostic Tools Overview

| Tool | Purpose |
|------|---------|
| `istioctl proxy-status` | Check sync status of all proxies |
| `istioctl proxy-config` | Inspect Envoy routes/clusters/listeners/endpoints |
| `istioctl analyze` | Static config analysis for misconfigurations |
| `istioctl bug-report` | Generate comprehensive diagnostic bundle |
| `istioctl experimental describe` | Describe how a pod is configured |
| `kubectl logs -c istio-proxy` | Read Envoy sidecar logs |
| `kubectl exec -- pilot-agent request GET /stats` | Envoy stats |
| Port-forward to 15000 | Envoy admin dashboard |
| Port-forward to 15020 | Sidecar health check endpoint |

---

## Sidecar Injection Issues

### Automatic Injection Not Working

**Symptoms:** Pods start without `istio-proxy` container.

**Check namespace label:**
```bash
kubectl get namespace <ns> --show-labels | grep istio
```

Expected: `istio-injection=enabled` or `istio.io/rev=<revision>`

**Check webhook:**
```bash
kubectl get mutatingwebhookconfiguration | grep istio
```

**Check pod annotations:**
```bash
kubectl get pod <pod> -n <ns> -o jsonpath='{.metadata.annotations}' | jq
```

If `sidecar.istio.io/inject: "false"` is set, injection is skipped.

**Common causes:**
1. Namespace not labeled.
2. Pod created before the namespace was labeled (restart pod).
3. `sidecar.istio.io/inject: "false"` annotation on pod or deployment.
4. Host networking (`hostNetwork: true`) — sidecars cannot inject.
5. MutatingWebhookConfiguration misconfigured or missing.
6. Revision mismatch — namespace has `istio.io/rev=1-20` but istiod version is `1-21`.

**Fix:**
```bash
# Label namespace
kubectl label namespace <ns> istio-injection=enabled --overwrite
# Restart pods to trigger injection
kubectl rollout restart deployment -n <ns>
```

### Injection Webhook Errors

**Symptoms:** Pod creation fails with webhook errors.

```bash
# Check webhook service is reachable
kubectl get svc istiod -n istio-system
kubectl get endpoints istiod -n istio-system

# Check istiod logs
kubectl logs -n istio-system -l app=istiod --tail=100 | grep -i "inject\|webhook"
```

**Common cause:** istiod not running or not ready. The webhook cannot reach the
injection endpoint.

### Init Container Failures

**Symptoms:** Pods stuck in `Init:CrashLoopBackOff`.

```bash
kubectl logs <pod> -n <ns> -c istio-init
```

**Common causes:**
1. Insufficient `NET_ADMIN` / `NET_RAW` capabilities.
2. Pod security policies or OPA/Gatekeeper blocking iptables rules.
3. CNI plugin conflict with istio-cni.

**Fix with Istio CNI:**
```bash
# Install Istio CNI to avoid NET_ADMIN requirement
istioctl install --set components.cni.enabled=true
```

---

## 503 Errors

### Upstream Connect Error

**Envoy response flag:** `UF` (UpstreamFailure)

```
upstream connect error or disconnect/reset before headers. reset reason: connection failure
```

**Causes:**
1. Backend pod not running or not ready.
2. Port mismatch between Service and Pod.
3. Service port naming wrong (must follow `<protocol>-<suffix>` convention).

**Debug:**
```bash
# Check endpoints
kubectl get endpoints <service> -n <ns>
# Check proxy can reach upstream
istioctl proxy-config endpoints <pod>.<ns> --cluster "outbound|<port>||<svc>.<ns>.svc.cluster.local"
# Verify port naming
kubectl get svc <service> -n <ns> -o yaml | grep -A3 ports
```

### No Healthy Upstream

**Envoy response flag:** `UH`

All endpoints ejected by outlier detection or no endpoints available.

```bash
# Check outlier detection stats
kubectl exec <pod> -c istio-proxy -- pilot-agent request GET /stats | grep outlier
# Check cluster health
istioctl proxy-config endpoints <pod>.<ns> | grep <service>
```

**Fix:** Reduce outlier detection sensitivity or check if endpoints are actually unhealthy.

### Circuit Breaking Triggered

**Envoy response flag:** `UO` (UpstreamOverflow)

```bash
# Check connection pool stats
kubectl exec <pod> -c istio-proxy -- pilot-agent request GET /stats | grep "upstream_rq_pending_overflow\|upstream_cx_overflow"
```

**Fix:** Increase `connectionPool` limits in DestinationRule or scale the backend.

### Upstream Overflow

When `http1MaxPendingRequests` or `http2MaxRequests` is exceeded:

```bash
# Check current limits
istioctl proxy-config cluster <pod>.<ns> --fqdn <service> -o json | jq '.[].circuitBreakers'
```

---

## mTLS Handshake Failures

### Mixed Mode Issues

**Symptoms:** Connection reset, TLS handshake errors, 503s between services.

This occurs when one side expects mTLS but the other sends plaintext (or vice versa).

```bash
# Check mTLS status between pods
istioctl authn tls-check <source-pod>.<ns> <destination-service>.<ns>.svc.cluster.local

# Check PeerAuthentication policies
kubectl get peerauthentication --all-namespaces

# Verify both pods have sidecars
kubectl get pod -n <ns> -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[*].name}{"\n"}{end}'
```

**Common scenario:** Service A (with sidecar, STRICT mTLS) → Service B (without sidecar).
Service B cannot terminate mTLS since it has no Envoy proxy.

**Fix:**
1. Ensure both pods have sidecars.
2. Use `PERMISSIVE` mode during migration.
3. Add port-level exceptions for services that cannot have sidecars:

```yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: with-exception
spec:
  mtls:
    mode: STRICT
  portLevelMtls:
    8080:
      mode: DISABLE    # allow plaintext on this port
```

### Certificate Rotation Failures

**Symptoms:** Sudden mTLS failures across the mesh.

```bash
# Check certificate expiry
istioctl proxy-config secret <pod>.<ns> -o json | jq '.[].certificate_chain.inline_bytes' | base64 -d | openssl x509 -noout -dates

# Check istiod CA health
kubectl logs -n istio-system -l app=istiod | grep -i "cert\|ca\|sign"
```

### SPIFFE Identity Mismatch

**Symptoms:** AuthorizationPolicy denying requests even though rules look correct.

```bash
# Check the actual SPIFFE identity
istioctl proxy-config secret <pod>.<ns> -o json | jq -r '.[0].certificate_chain.inline_bytes' | base64 -d | openssl x509 -noout -text | grep URI

# Expected format: spiffe://cluster.local/ns/<namespace>/sa/<service-account>
```

Ensure the ServiceAccount in the AuthorizationPolicy matches the pod's ServiceAccount.

---

## Traffic Not Routing Correctly

### VirtualService Not Applied

```bash
# Check if VirtualService is visible to the proxy
istioctl proxy-config routes <pod>.<ns> -o json | jq '.[].virtualHosts[] | select(.name | contains("<service>"))'

# Verify hosts field matches
kubectl get vs <name> -n <ns> -o yaml | grep -A5 "hosts:"
```

**Common causes:**
1. `hosts` field doesn't match the actual service name.
2. VirtualService in wrong namespace with default `exportTo`.
3. No gateway binding for ingress traffic.
4. Short name used instead of FQDN when VirtualService is in a different namespace.

### Conflicting VirtualServices

Multiple VirtualServices for the same host in the same namespace cause undefined
behavior.

```bash
# Find conflicting VirtualServices
istioctl analyze -n <ns> 2>&1 | grep "conflict\|multiple"

# List all VirtualServices for a host
kubectl get vs --all-namespaces -o json | jq '.items[] | select(.spec.hosts[] | contains("<hostname>")) | {name: .metadata.name, ns: .metadata.namespace}'
```

**Fix:** Merge VirtualServices for the same host or use delegation.

### Subset Not Found

**Envoy response flag:** `NR` (NoRoute)

```
no healthy upstream; 503 NR
```

```bash
# Check DestinationRule subsets exist
kubectl get dr <name> -n <ns> -o yaml | grep -A3 subsets

# Verify pods match subset labels
kubectl get pods -n <ns> -l version=v2 --show-labels
```

**Fix:** Ensure DestinationRule subsets match pod labels and that the DestinationRule
exists in the same namespace as the service (or uses `exportTo`).

### Host Resolution Issues

```bash
# Test DNS resolution from inside a pod
kubectl exec <pod> -c istio-proxy -- nslookup <service>.<ns>.svc.cluster.local

# Check if service exists
kubectl get svc <service> -n <ns>
```

---

## Envoy Config Not Updating

### Config Propagation Delays

**Symptoms:** New VirtualService/DestinationRule not taking effect.

```bash
# Check proxy sync status
istioctl proxy-status

# Look for STALE or NOT SENT status
# CDS=Cluster Discovery, LDS=Listener Discovery, EDS=Endpoint Discovery, RDS=Route Discovery
```

Status meanings:
- `SYNCED` — proxy has latest config from istiod
- `NOT SENT` — istiod hasn't pushed config to this proxy (possible scope issue)
- `STALE` — istiod sent config but proxy hasn't ACKed (connectivity issue)

### xDS Push Failures

```bash
# Check istiod push metrics
kubectl exec -n istio-system deploy/istiod -- pilot-agent request GET /metrics | grep "pilot_xds_pushes\|pilot_xds_push_errors\|pilot_proxy_convergence_time"

# Check istiod logs for push errors
kubectl logs -n istio-system -l app=istiod --tail=200 | grep -i "push\|error\|timeout"
```

### Stale Endpoints

```bash
# Compare endpoints in proxy vs Kubernetes
istioctl proxy-config endpoints <pod>.<ns> | grep <service>
kubectl get endpoints <service> -n <ns>
```

If they differ, istiod may be slow to propagate. Check istiod resource utilization.

---

## Performance Issues

### Memory and CPU Overhead

**Sidecar baseline:** ~40MB RAM, ~10m CPU per pod at idle. Under load, this increases
with concurrent connections and config size.

**Reduce sidecar resource usage:**

```yaml
# Set proxy resource limits via annotations
metadata:
  annotations:
    sidecar.istio.io/proxyCPU: "100m"
    sidecar.istio.io/proxyCPULimit: "500m"
    sidecar.istio.io/proxyMemory: "128Mi"
    sidecar.istio.io/proxyMemoryLimit: "512Mi"
```

**Reduce config size with Sidecar CRD:**
```yaml
apiVersion: networking.istio.io/v1
kind: Sidecar
metadata:
  name: default
  namespace: my-namespace
spec:
  egress:
    - hosts:
        - "./*"
        - "istio-system/*"
```

This dramatically reduces memory and xDS push time in large clusters.

### Slow Startup

**Symptoms:** Application starts before sidecar is ready, causing connection failures.

**Fix — hold application until proxy is ready:**

```yaml
# Global setting in meshConfig
meshConfig:
  defaultConfig:
    holdApplicationUntilProxyStarts: true
```

Or per-pod:
```yaml
metadata:
  annotations:
    proxy.istio.io/config: '{"holdApplicationUntilProxyStarts": true}'
```

**Other startup optimizations:**
- Increase sidecar `readinessInitialDelaySeconds`.
- Use `startupProbe` on the application container.
- Consider `istio-cni` to remove the init container step.

### High Latency

**Expected overhead:** <1ms per hop for typical requests (p99).

**Debug latency:**
```bash
# Check Envoy stats for timing
kubectl exec <pod> -c istio-proxy -- pilot-agent request GET /stats | grep "downstream_rq_time\|upstream_rq_time"

# Compare direct vs proxied latency
# Temporarily bypass sidecar for a specific port:
kubectl annotate pod <pod> traffic.sidecar.istio.io/excludeOutboundPorts="8080"
```

**Common high-latency causes:**
1. DNS resolution delays — use `STATIC` resolution in ServiceEntry.
2. Mutual TLS handshake overhead on first connection (cached after).
3. Large Envoy config — use Sidecar CRD to reduce scope.
4. Retries inflating observed latency.
5. Excessive access logging.

### xDS Config Size

```bash
# Check config size
istioctl proxy-config all <pod>.<ns> -o json | wc -c

# Check per-section sizes
for section in clusters listeners routes endpoints; do
  size=$(istioctl proxy-config $section <pod>.<ns> -o json | wc -c)
  echo "$section: $size bytes"
done
```

Large configs (>10MB) indicate the need for Sidecar scoping.

---

## Debugging with istioctl

### proxy-status

Shows sync status of all proxies with istiod:

```bash
istioctl proxy-status

# Example output:
# NAME           CDS    LDS    EDS    RDS    ECDS   ISTIOD
# app-abc.ns     SYNCED SYNCED SYNCED SYNCED        istiod-xxx
# app-def.ns     STALE  SYNCED SYNCED SYNCED        istiod-xxx
```

### proxy-config

Inspect what Envoy sees:

```bash
# Routes — how traffic is routed
istioctl proxy-config routes <pod>.<ns> --name <route-name>

# Clusters — upstream service endpoints
istioctl proxy-config clusters <pod>.<ns> --fqdn <service>

# Listeners — what ports Envoy listens on
istioctl proxy-config listeners <pod>.<ns> --port <port>

# Endpoints — actual pod IPs for a service
istioctl proxy-config endpoints <pod>.<ns> --cluster "outbound|<port>||<fqdn>"

# Secrets — TLS certificates
istioctl proxy-config secret <pod>.<ns>

# Full Envoy config dump
istioctl proxy-config all <pod>.<ns> -o json > envoy-config-dump.json

# Bootstrap config
istioctl proxy-config bootstrap <pod>.<ns>
```

### istioctl analyze

Static config analysis — catches misconfigurations before they cause runtime issues:

```bash
# Analyze specific namespace
istioctl analyze -n <ns>

# Analyze all namespaces
istioctl analyze --all-namespaces

# Analyze local files (pre-deploy check)
istioctl analyze -f my-virtualservice.yaml

# Suppress specific messages
istioctl analyze --suppress "IST0101=VirtualService default/my-vs"
```

Common analysis messages:
- `IST0101` — Referenced host not found
- `IST0104` — Gateway refers to undefined host
- `IST0106` — Referenced subset not found in DestinationRule
- `IST0108` — Unknown annotation

### istioctl bug-report

Generate a diagnostic bundle for support:

```bash
istioctl bug-report --include "<ns1>,<ns2>"
```

---

## Envoy Proxy Logs Analysis

### Enabling Debug Logging

```bash
# Change log level at runtime (no restart)
istioctl proxy-config log <pod>.<ns> --level debug

# Specific component
istioctl proxy-config log <pod>.<ns> --level connection:debug,router:debug

# View logs
kubectl logs <pod> -c istio-proxy -f --tail=100

# Reset to default
istioctl proxy-config log <pod>.<ns> --level warning
```

### Response Flag Codes

Key response flags in Envoy access logs:

| Flag | Meaning |
|------|---------|
| `UH` | No healthy upstream |
| `UF` | Upstream connection failure |
| `UO` | Upstream overflow (circuit breaking) |
| `NR` | No route configured |
| `URX` | Upstream retry limit exceeded |
| `NC` | No cluster found |
| `DT` | Downstream request timeout |
| `UT` | Upstream request timeout |
| `LR` | Connection local reset |
| `UR` | Connection upstream reset |
| `DC` | Downstream connection termination |
| `DPE` | Downstream protocol error |
| `RL` | Rate limited |
| `UAEX` | Unauthorized (ext-authz) |
| `RLSE` | Rate limit service error |

### Access Log Format

Default format includes: `[%START_TIME%] "%REQ(:METHOD)% %REQ(X-ENVOY-ORIGINAL-PATH?:PATH)% %PROTOCOL%" %RESPONSE_CODE% %RESPONSE_FLAGS% ...`

Enable JSON access logs for easier parsing:

```yaml
meshConfig:
  accessLogFile: /dev/stdout
  accessLogEncoding: JSON
  accessLogFormat: |
    {
      "protocol": "%PROTOCOL%",
      "upstream_service_time": "%RESP(X-ENVOY-UPSTREAM-SERVICE-TIME)%",
      "upstream_cluster": "%UPSTREAM_CLUSTER%",
      "response_flags": "%RESPONSE_FLAGS%",
      "route_name": "%ROUTE_NAME%"
    }
```

---

## Kiali Issues

### Service Graph Not Loading

**Symptoms:** Kiali shows empty service graph or "No data available."

**Causes:**
1. Prometheus not scraping Istio metrics:
```bash
kubectl get svc -n istio-system | grep prometheus
kubectl port-forward -n istio-system svc/prometheus 9090:9090
# Check targets at localhost:9090/targets
```

2. Kiali not configured to reach Prometheus:
```bash
kubectl get cm kiali -n istio-system -o yaml | grep -A5 prometheus
```

3. Time range too narrow — expand the time window in Kiali.

### Missing Metrics

```bash
# Verify metrics are being generated
kubectl exec <pod> -c istio-proxy -- pilot-agent request GET /stats/prometheus | grep istio_requests_total

# Check if telemetry is enabled
kubectl get telemetry --all-namespaces
```

If using custom Telemetry resources, ensure they don't accidentally disable metrics.

---

## Common Scenarios and Fixes

### Scenario: New deployment gets no traffic

```bash
# 1. Check sidecar is injected
kubectl get pod <pod> -o jsonpath='{.spec.containers[*].name}'

# 2. Check service selectors match pod labels
kubectl get svc <svc> -o wide
kubectl get pod <pod> --show-labels

# 3. Check endpoints are registered
kubectl get endpoints <svc>

# 4. Check proxy knows about the endpoint
istioctl proxy-config endpoints <caller-pod>.<ns> | grep <svc>

# 5. Check for restrictive AuthorizationPolicy
kubectl get authorizationpolicy -n <ns>
```

### Scenario: Intermittent 503s under load

```bash
# Check circuit breaker stats
kubectl exec <pod> -c istio-proxy -- pilot-agent request GET /stats | grep "upstream_rq_pending_overflow\|upstream_cx_overflow"

# Check outlier detection ejections
kubectl exec <pod> -c istio-proxy -- pilot-agent request GET /stats | grep "outlier_detection"

# Increase limits in DestinationRule
kubectl edit dr <name> -n <ns>
```

### Scenario: Traffic split not working as expected

```bash
# 1. Verify VirtualService weights
kubectl get vs <name> -o yaml | grep -A5 weight

# 2. Check DestinationRule subsets exist
kubectl get dr <name> -o yaml | grep -A3 subsets

# 3. Verify pods with correct labels exist
kubectl get pods -l version=v2

# 4. Check route in proxy
istioctl proxy-config routes <pod>.<ns> -o json | jq '.[] | .virtualHosts[] | select(.name | contains("<svc>"))'
```

### Scenario: External service calls failing

```bash
# 1. Check outbound traffic policy
kubectl get cm istio -n istio-system -o yaml | grep outboundTrafficPolicy

# 2. If REGISTRY_ONLY, check ServiceEntry exists
kubectl get se --all-namespaces | grep <external-host>

# 3. Check DNS resolution
kubectl exec <pod> -c istio-proxy -- curl -v https://<external-host>

# 4. Check proxy knows about the external service
istioctl proxy-config clusters <pod>.<ns> | grep <external-host>
```
