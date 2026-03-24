# Istio Traffic Management Deep Dive

## Table of Contents

- [Overview](#overview)
- [VirtualService](#virtualservice)
  - [HTTP Match Rules](#http-match-rules)
  - [Header-Based Routing](#header-based-routing)
  - [URI Matching](#uri-matching)
  - [Query Parameter Matching](#query-parameter-matching)
  - [Traffic Splitting (Weighted Routing)](#traffic-splitting-weighted-routing)
  - [HTTP Rewrites](#http-rewrites)
  - [HTTP Redirects](#http-redirects)
  - [Request and Response Header Manipulation](#request-and-response-header-manipulation)
  - [Delegate VirtualServices](#delegate-virtualservices)
- [DestinationRule](#destinationrule)
  - [Subsets](#subsets)
  - [Load Balancing Algorithms](#load-balancing-algorithms)
  - [Connection Pool Settings](#connection-pool-settings)
  - [TLS Settings](#tls-settings)
- [Fault Injection](#fault-injection)
  - [Delay Injection](#delay-injection)
  - [Abort Injection](#abort-injection)
  - [Combined Faults](#combined-faults)
- [Circuit Breaking](#circuit-breaking)
  - [Connection Limits](#connection-limits)
  - [Outlier Detection](#outlier-detection)
  - [Panic Threshold](#panic-threshold)
- [Retries](#retries)
  - [Retry Policies](#retry-policies)
  - [Retry Budgets](#retry-budgets)
  - [Per-Try Timeout](#per-try-timeout)
- [Timeouts](#timeouts)
  - [Route-Level Timeouts](#route-level-timeouts)
  - [Timeout Interaction with Retries](#timeout-interaction-with-retries)
- [Traffic Mirroring](#traffic-mirroring)
- [ServiceEntry](#serviceentry)
  - [External HTTP Services](#external-http-services)
  - [External TLS Services](#external-tls-services)
  - [TCP Services](#tcp-services)
  - [DNS Resolution Modes](#dns-resolution-modes)
- [Sidecar Resource](#sidecar-resource)
  - [Limiting Egress Scope](#limiting-egress-scope)
  - [Ingress Listeners](#ingress-listeners)
  - [Default Sidecar](#default-sidecar)
- [Gateway](#gateway)
  - [TLS Modes](#tls-modes)
  - [Multiple Hosts](#multiple-hosts)
  - [Kubernetes Gateway API](#kubernetes-gateway-api)
- [Best Practices](#best-practices)

---

## Overview

Istio traffic management works by programming Envoy sidecars via the xDS API. The
control plane (istiod/Pilot) translates Istio CRDs (VirtualService, DestinationRule,
Gateway, ServiceEntry, Sidecar) into Envoy configuration and pushes it to every proxy
in the mesh. Traffic decisions happen at the data plane — the application is unaware.

Key concept: Istio decouples traffic behavior from deployment topology. You deploy
versions independently and control traffic flow through configuration, not code.

---

## VirtualService

A VirtualService defines routing rules that are evaluated in order. The first matching
rule wins. Always include a default (catch-all) route at the end.

### HTTP Match Rules

Match rules can target headers, URI, scheme, method, authority, port, source labels,
query parameters, and gateways. Multiple conditions within a single match block are
ANDed; multiple match blocks are ORed.

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: reviews
spec:
  hosts:
    - reviews
  http:
    - match:
        # OR: any of these match blocks triggers the route
        - headers:
            end-user:
              exact: jason
          uri:
            prefix: /api/v2
          # AND: both header AND uri must match
        - sourceLabels:
            app: testing-tool
      route:
        - destination:
            host: reviews
            subset: v3
    # Default route (no match = catch-all)
    - route:
        - destination:
            host: reviews
            subset: v1
```

### Header-Based Routing

Use header matching for internal testing, A/B tests, or tenant routing:

```yaml
http:
  - match:
      - headers:
          x-tenant:
            exact: premium
    route:
      - destination:
          host: myservice
          subset: premium-tier
  - match:
      - headers:
          x-canary:
            exact: "true"
    route:
      - destination:
          host: myservice
          subset: canary
  - route:
      - destination:
          host: myservice
          subset: stable
```

Supported string match types: `exact`, `prefix`, `regex`.

### URI Matching

```yaml
http:
  - match:
      - uri:
          prefix: /api/v2/
    route:
      - destination:
          host: api-v2
  - match:
      - uri:
          regex: "^/users/[0-9]+$"
    route:
      - destination:
          host: user-service
  - match:
      - uri:
          exact: /healthz
    directResponse:
      status: 200
      body:
        string: "OK"
```

### Query Parameter Matching

```yaml
http:
  - match:
      - queryParams:
          version:
            exact: "2"
    route:
      - destination:
          host: myservice
          subset: v2
```

### Traffic Splitting (Weighted Routing)

Weights must sum to 100. Use for canary deployments, blue-green transitions, and A/B
testing:

```yaml
http:
  - route:
      - destination:
          host: myapp
          subset: stable
        weight: 90
      - destination:
          host: myapp
          subset: canary
        weight: 10
```

**Progressive rollout pattern:** 5 → 10 → 25 → 50 → 75 → 100

Combine with header-based routing for a two-phase approach:
1. Route internal testers via header match (weight 100 to canary).
2. Then apply weighted split for all users.

### HTTP Rewrites

Rewrite URI path or authority before forwarding:

```yaml
http:
  - match:
      - uri:
          prefix: /v1/api/
    rewrite:
      uri: /api/
      authority: backend.internal.svc.cluster.local
    route:
      - destination:
          host: backend
```

### HTTP Redirects

```yaml
http:
  - match:
      - uri:
          prefix: /old-path
    redirect:
      uri: /new-path
      redirectCode: 301
```

### Request and Response Header Manipulation

```yaml
http:
  - route:
      - destination:
          host: myservice
    headers:
      request:
        set:
          x-forwarded-client-cert: "%DOWNSTREAM_PEER_CERT%"
        add:
          x-custom-header: "mesh-routed"
        remove:
          - x-internal-debug
      response:
        set:
          strict-transport-security: "max-age=31536000"
```

### Delegate VirtualServices

Split routing rules across teams using delegation:

```yaml
# Root VirtualService (mesh admin)
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: root
  namespace: istio-system
spec:
  hosts: ["app.example.com"]
  gateways: [my-gateway]
  http:
    - match:
        - uri:
            prefix: /api/
      delegate:
        name: api-routes
        namespace: api-team
    - match:
        - uri:
            prefix: /web/
      delegate:
        name: web-routes
        namespace: web-team
```

---

## DestinationRule

DestinationRules define policies applied after routing. They configure subsets, load
balancing, connection pools, outlier detection, and TLS settings.

### Subsets

Subsets map to Kubernetes pod labels, enabling version-based routing:

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: reviews
spec:
  host: reviews
  subsets:
    - name: v1
      labels:
        version: v1
      trafficPolicy:
        connectionPool:
          http:
            h2UpgradePolicy: UPGRADE
    - name: v2
      labels:
        version: v2
    - name: v3
      labels:
        version: v3
```

Subset-level `trafficPolicy` overrides the top-level policy for that subset.

### Load Balancing Algorithms

```yaml
trafficPolicy:
  loadBalancer:
    simple: ROUND_ROBIN    # default
    # simple: LEAST_REQUEST
    # simple: RANDOM
    # simple: PASSTHROUGH   # direct to endpoint from EDS
```

Consistent hash (session affinity):

```yaml
trafficPolicy:
  loadBalancer:
    consistentHash:
      httpHeaderName: x-user-id
      # OR: httpCookie: { name: JSESSIONID, ttl: 0s }
      # OR: useSourceIp: true
      # OR: httpQueryParameterName: user
      minimumRingSize: 1024
```

### Connection Pool Settings

```yaml
trafficPolicy:
  connectionPool:
    tcp:
      maxConnections: 1000
      connectTimeout: 5s
      tcpKeepalive:
        time: 7200s
        interval: 75s
        probes: 9
    http:
      http1MaxPendingRequests: 1024
      http2MaxRequests: 1024
      maxRequestsPerConnection: 100
      maxRetries: 3
      idleTimeout: 60s
      h2UpgradePolicy: DEFAULT
```

### TLS Settings

```yaml
trafficPolicy:
  tls:
    mode: ISTIO_MUTUAL    # use mesh-issued certs (default for mTLS)
    # mode: MUTUAL        # custom client certs
    # mode: SIMPLE        # one-way TLS
    # mode: DISABLE       # no TLS
    clientCertificate: /etc/certs/client.pem
    privateKey: /etc/certs/key.pem
    caCertificates: /etc/certs/ca.pem
    sni: myservice.example.com
```

---

## Fault Injection

Fault injection tests resilience without modifying application code. Use in
non-production environments. Faults are injected before routing rules apply.

### Delay Injection

Simulates network latency or slow upstream:

```yaml
http:
  - fault:
      delay:
        percentage:
          value: 10.0
        fixedDelay: 5s
    route:
      - destination:
          host: ratings
```

### Abort Injection

Simulates upstream failures:

```yaml
http:
  - fault:
      abort:
        percentage:
          value: 5.0
        httpStatus: 503
    route:
      - destination:
          host: ratings
```

For gRPC, use `grpcStatus` instead of `httpStatus`.

### Combined Faults

```yaml
http:
  - match:
      - headers:
          x-chaos:
            exact: "true"
    fault:
      delay:
        percentage:
          value: 100.0
        fixedDelay: 3s
      abort:
        percentage:
          value: 50.0
        httpStatus: 500
    route:
      - destination:
          host: myservice
```

Tip: Use header matching to scope fault injection to test traffic only.

---

## Circuit Breaking

Circuit breaking prevents cascading failures by limiting connections to unhealthy
endpoints.

### Connection Limits

Set via `connectionPool` in DestinationRule (see above). When limits are hit, requests
receive 503 (upstream overflow). Monitor with `upstream_rq_pending_overflow` stat.

### Outlier Detection

Ejects unhealthy endpoints from the load balancing pool:

```yaml
trafficPolicy:
  outlierDetection:
    consecutive5xxErrors: 5          # eject after 5 consecutive 5xx
    interval: 10s                     # evaluation interval
    baseEjectionTime: 30s            # minimum ejection duration
    maxEjectionPercent: 50           # never eject >50% of endpoints
    minHealthPercent: 30             # disable ejection if healthy < 30%
    consecutiveGatewayErrors: 5      # also track gateway errors
    splitExternalLocalOriginErrors: true
```

**How it works:**
1. Envoy tracks error rates per endpoint.
2. When threshold is hit, endpoint is ejected for `baseEjectionTime * numEjections`.
3. Ejected endpoint is probed periodically and re-added when healthy.
4. `maxEjectionPercent` prevents ejecting the entire pool.

### Panic Threshold

When healthy endpoints drop below `minHealthPercent`, Envoy enters panic mode and
routes to all endpoints (including ejected). This prevents total failure when most
endpoints are unhealthy. Set to 0 to disable panic mode.

---

## Retries

### Retry Policies

```yaml
http:
  - route:
      - destination:
          host: myservice
    retries:
      attempts: 3
      perTryTimeout: 2s
      retryOn: 5xx,reset,connect-failure,retriable-4xx,refused-stream
      retryRemoteLocalities: true
```

**`retryOn` values:**
- `5xx` — retry on 5xx response
- `gateway-error` — 502, 503, 504
- `connect-failure` — connection failures
- `retriable-4xx` — 409 only
- `refused-stream` — REFUSED_STREAM error
- `reset` — connection reset
- `retriable-status-codes` — retry on specific codes
- `retriable-headers` — retry when response contains specific headers

### Retry Budgets

Limit retry traffic to prevent retry storms. Configured at the Envoy level via
EnvoyFilter or mesh config:

```yaml
# In DestinationRule (via connection pool)
trafficPolicy:
  connectionPool:
    http:
      maxRetries: 3    # max concurrent retries per connection pool
```

For mesh-wide retry budgets:

```yaml
# meshConfig overlay
meshConfig:
  defaultConfig:
    proxyMetadata:
      ISTIO_META_UPSTREAM_RETRY_BUDGET_PERCENT: "20"
```

This limits retries to 20% of active requests, preventing retry amplification.

### Per-Try Timeout

The `perTryTimeout` applies to each individual attempt. The overall timeout (set via
`timeout` on the route) caps the total time including all retries.

**Example:** `timeout: 10s`, `perTryTimeout: 3s`, `attempts: 3`
- Each retry can take up to 3s.
- Total time (including all retries) is capped at 10s.
- If the first attempt takes 3s and second takes 3s, only 4s remains for the third.

---

## Timeouts

### Route-Level Timeouts

```yaml
http:
  - route:
      - destination:
          host: slow-service
    timeout: 30s
```

A `timeout: 0s` disables the timeout (infinite wait — not recommended).

### Timeout Interaction with Retries

The route-level `timeout` is the overall budget. Retries consume from this budget:

```
Total time ≤ timeout
Each retry ≤ perTryTimeout
Actual attempts = min(attempts, timeout / perTryTimeout)
```

**Best practice:** Set `timeout > perTryTimeout * attempts` to allow all retries.

---

## Traffic Mirroring

Mirror (shadow) production traffic to a test service. Mirrored traffic is fire-and-
forget; responses are discarded.

```yaml
http:
  - route:
      - destination:
          host: myservice
          subset: v1
    mirror:
      host: myservice
      subset: v2-test
    mirrorPercentage:
      value: 100.0
```

**Key points:**
- Mirrored requests have `-shadow` appended to the `Host` header.
- Mirror responses are discarded — no impact on primary request latency.
- Use for testing new versions with real traffic patterns.
- Monitor mirrored service separately for errors.

---

## ServiceEntry

ServiceEntry registers external services in Istio's internal service registry, enabling
mesh features (retries, timeouts, mTLS origination) for external calls.

### External HTTP Services

```yaml
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: google-api
spec:
  hosts:
    - www.googleapis.com
  location: MESH_EXTERNAL
  ports:
    - number: 443
      name: https
      protocol: HTTPS
  resolution: DNS
```

### External TLS Services

```yaml
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: external-db
spec:
  hosts:
    - db.external.com
  location: MESH_EXTERNAL
  ports:
    - number: 5432
      name: tcp-postgres
      protocol: TCP
  resolution: DNS
  endpoints:
    - address: 203.0.113.10
```

### TCP Services

```yaml
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: external-redis
spec:
  hosts:
    - redis.external.com
  location: MESH_EXTERNAL
  ports:
    - number: 6379
      name: tcp-redis
      protocol: TCP
  resolution: STATIC
  endpoints:
    - address: 10.0.0.50
    - address: 10.0.0.51
```

### DNS Resolution Modes

- `NONE` — no DNS resolution; use when addresses are provided as IPs.
- `STATIC` — use `endpoints[].address` directly.
- `DNS` — resolve hostnames at connection time.
- `DNS_ROUND_ROBIN` — resolve and round-robin across addresses.

---

## Sidecar Resource

The Sidecar CRD limits the set of services a sidecar proxy can reach. This reduces
memory usage and xDS config push time significantly in large clusters.

### Limiting Egress Scope

```yaml
apiVersion: networking.istio.io/v1
kind: Sidecar
metadata:
  name: default
  namespace: my-namespace
spec:
  egress:
    - hosts:
        - "./*"                           # same namespace
        - "istio-system/*"                # Istio control plane
        - "shared-services/cache.shared"  # specific external service
```

Without a Sidecar resource, every proxy receives config for every service in the mesh.
In clusters with hundreds of services, this wastes significant memory.

### Ingress Listeners

Override the default inbound listener configuration:

```yaml
spec:
  ingress:
    - port:
        number: 8080
        protocol: HTTP
        name: http
      defaultEndpoint: 127.0.0.1:8080
      tls:
        mode: ISTIO_MUTUAL
```

### Default Sidecar

Apply a mesh-wide default in the `istio-system` namespace:

```yaml
apiVersion: networking.istio.io/v1
kind: Sidecar
metadata:
  name: default
  namespace: istio-system
spec:
  egress:
    - hosts:
        - "./*"
        - "istio-system/*"
  outboundTrafficPolicy:
    mode: REGISTRY_ONLY
```

This forces every namespace to only see its own services plus `istio-system`, unless
overridden by a namespace-specific Sidecar.

---

## Gateway

### TLS Modes

```yaml
servers:
  - port:
      number: 443
      name: https
      protocol: HTTPS
    tls:
      mode: SIMPLE               # standard TLS termination
      credentialName: my-cert    # Kubernetes Secret name
    hosts:
      - "*.example.com"
```

TLS modes:
- `PASSTHROUGH` — forward encrypted traffic to the backend (SNI-based routing).
- `SIMPLE` — TLS termination at the gateway.
- `MUTUAL` — mutual TLS; gateway verifies client certificates.
- `AUTO_PASSTHROUGH` — SNI-based routing without VirtualService (multi-cluster).
- `ISTIO_MUTUAL` — mutual TLS using Istio-managed certificates.

### Multiple Hosts

```yaml
servers:
  - port:
      number: 443
      name: https-app1
      protocol: HTTPS
    tls:
      mode: SIMPLE
      credentialName: app1-cert
    hosts:
      - "app1.example.com"
  - port:
      number: 443
      name: https-app2
      protocol: HTTPS
    tls:
      mode: SIMPLE
      credentialName: app2-cert
    hosts:
      - "app2.example.com"
```

### Kubernetes Gateway API

Istio supports the Kubernetes Gateway API as an alternative to the Istio Gateway CRD:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: my-gateway
  annotations:
    networking.istio.io/service-type: ClusterIP
spec:
  gatewayClassName: istio
  listeners:
    - name: https
      port: 443
      protocol: HTTPS
      tls:
        certificateRefs:
          - name: my-cert
      allowedRoutes:
        namespaces:
          from: Selector
          selector:
            matchLabels:
              gateway-access: "true"
```

---

## Best Practices

1. **Always define a default route.** A VirtualService without a catch-all route
   returns 404 for unmatched requests.

2. **Scope resources with `exportTo`.** Use `exportTo: ["."]` to limit VirtualService
   and DestinationRule visibility to the defining namespace. Use `exportTo: ["*"]` only
   for shared services.

3. **Use the Sidecar CRD in large clusters.** Without it, every proxy holds config for
   every service, causing memory bloat and slow config pushes.

4. **Set timeouts on every route.** Unbounded timeouts cause resource exhaustion under
   load. Default is 15s if not set.

5. **Configure outlierDetection on every DestinationRule.** This provides automatic
   circuit breaking for unhealthy endpoints.

6. **Use `REGISTRY_ONLY` for egress.** Lock down outbound traffic and explicitly
   register external services via ServiceEntry.

7. **Prefer weighted routing over header-based for broad rollouts.** Header-based
   routing is for targeted testing; weighted routing is for progressive delivery.

8. **Mirror before you split.** Use traffic mirroring to test with real traffic
   patterns before routing actual users to a new version.

9. **Mind retry amplification.** With 3 retries at each of 5 hops, a single request
   can generate 3^5 = 243 attempts. Use retry budgets.

10. **Validate with `istioctl analyze`.** Run before every deployment to catch
    misconfigurations (dangling references, missing subsets, conflicting rules).
