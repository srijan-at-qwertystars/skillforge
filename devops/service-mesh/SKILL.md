---
name: service-mesh
description: >
  Use when working with service mesh infrastructure, Istio, Envoy proxy, Linkerd,
  sidecar proxy patterns, mTLS configuration, traffic management, canary deployments,
  circuit breaking, outlier detection, service-to-service communication, ingress/egress
  gateways, observability with Kiali/Jaeger, VirtualService, DestinationRule, Gateway,
  PeerAuthentication, AuthorizationPolicy, ambient mesh, or multi-cluster mesh.
  Do NOT use for simple monolithic applications, Docker Compose networking, environments
  with fewer than 5 microservices, standalone API gateway configuration without mesh needs,
  basic Kubernetes networking without service mesh requirements, or simple load balancing
  that kubectl port-forward or a single Ingress controller can handle.
---

# Service Mesh Patterns

## Core Concepts

- **Data plane**: Proxy instances intercepting all service traffic. Handle routing,
  load balancing, encryption, and observability.
- **Control plane**: Centralized management (Istio's `istiod`) that configures proxies,
  distributes policy, and issues certificates.
- **Sidecar pattern**: Proxy container alongside each pod transparently intercepts
  inbound/outbound traffic. Zero application code changes required.

## Istio Architecture

Istio uses Envoy (C++ L7 proxy) as its data plane and `istiod` as unified control plane.

- **istiod**: Service discovery (Pilot), certificate management (Citadel), config
  validation. Single binary since Istio 1.5+.
- **Envoy sidecar**: Injected via mutating webhook. Intercepts pod traffic via iptables.
- **Ingress Gateway**: Envoy at mesh edge for inbound external traffic.
- **Egress Gateway**: Controls and monitors outbound traffic leaving the mesh.

## Installation

### istioctl (dev/staging)
```bash
curl -L https://istio.io/downloadIstio | sh -
export PATH=$PWD/istio-*/bin:$PATH
istioctl install --set profile=demo -y
kubectl label namespace default istio-injection=enabled
istioctl verify-install
```

### Helm (production)
```bash
helm repo add istio https://istio-release.storage.googleapis.com/charts && helm repo update
helm install istio-base istio/base -n istio-system --create-namespace
helm install istiod istio/istiod -n istio-system --wait
helm install istio-ingress istio/gateway -n istio-ingress --create-namespace
```

Profiles: `default` (production), `demo` (evaluation), `minimal` (control plane only),
`ambient` (sidecar-less).

## Traffic Management

### VirtualService — Route traffic to service versions
```yaml
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: reviews
spec:
  hosts:
    - reviews
  http:
    - match:
        - headers:
            end-user:
              exact: jason
      route:
        - destination:
            host: reviews
            subset: v2
    - route:
        - destination:
            host: reviews
            subset: v1
```

### DestinationRule — Define subsets and policies
```yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: reviews
spec:
  host: reviews
  trafficPolicy:
    loadBalancer:
      simple: ROUND_ROBIN
  subsets:
    - name: v1
      labels:
        version: v1
    - name: v2
      labels:
        version: v2
```

### Gateway — Expose services at mesh edge
```yaml
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: app-gateway
spec:
  selector:
    istio: ingressgateway
  servers:
    - port:
        number: 443
        name: https
        protocol: HTTPS
      tls:
        mode: SIMPLE
        credentialName: app-tls-cert
      hosts:
        - "app.example.com"
```

### ServiceEntry — Register external services in the mesh
```yaml
apiVersion: networking.istio.io/v1beta1
kind: ServiceEntry
metadata:
  name: external-api
spec:
  hosts:
    - api.external.com
  ports:
    - number: 443
      name: https
      protocol: TLS
  resolution: DNS
  location: MESH_EXTERNAL
```

## Canary Deployments and Traffic Splitting

Split traffic by weight between service versions. Shift gradually while monitoring metrics.

```yaml
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: my-service
spec:
  hosts:
    - my-service
  http:
    - route:
        - destination:
            host: my-service
            subset: stable
          weight: 90
        - destination:
            host: my-service
            subset: canary
          weight: 10
```

Workflow: deploy canary pods with `version: canary` label → set 5% weight →
monitor error rate/p99 → increase to 25%, 50%, 100% → remove old version.
Automate with Flagger or Argo Rollouts for metric-driven progressive delivery.

## Circuit Breaking and Outlier Detection

Prevent cascading failures by limiting connections and ejecting unhealthy hosts.

```yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: my-service
spec:
  host: my-service
  trafficPolicy:
    connectionPool:
      tcp:
        maxConnections: 100
      http:
        http1MaxPendingRequests: 50
        http2MaxRequests: 100
        maxRequestsPerConnection: 10
    outlierDetection:
      consecutive5xxErrors: 5
      interval: 10s
      baseEjectionTime: 30s
      maxEjectionPercent: 50
```

- `connectionPool`: Limits concurrent connections. Excess requests get 503.
- `outlierDetection`: Ejects hosts returning consecutive errors. Retried after
  `baseEjectionTime`. Cap simultaneous ejections with `maxEjectionPercent`.

## Retries, Timeouts, and Fault Injection

### Retries and timeouts
```yaml
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: my-service
spec:
  hosts:
    - my-service
  http:
    - timeout: 5s
      retries:
        attempts: 3
        perTryTimeout: 2s
        retryOn: 5xx,reset,connect-failure,retriable-4xx
      route:
        - destination:
            host: my-service
```

### Fault injection for chaos testing
```yaml
http:
  - fault:
      delay:
        percentage:
          value: 10
        fixedDelay: 5s
      abort:
        percentage:
          value: 5
        httpStatus: 503
    route:
      - destination:
          host: my-service
```

Inject faults in staging to verify retry logic and circuit breaker behavior.

## Security

### mTLS with PeerAuthentication
Enforce mesh-wide STRICT mTLS. Start with PERMISSIVE during migration.

```yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: istio-system    # mesh-wide when in root namespace
spec:
  mtls:
    mode: STRICT
```

Per-namespace override:
```yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: permissive-legacy
  namespace: legacy-apps
spec:
  mtls:
    mode: PERMISSIVE
```

### AuthorizationPolicy — L7 RBAC
```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-frontend
  namespace: production
spec:
  selector:
    matchLabels:
      app: backend-api
  rules:
    - from:
        - source:
            principals: ["cluster.local/ns/production/sa/frontend"]
      to:
        - operation:
            methods: ["GET", "POST"]
            paths: ["/api/*"]
```

Deny-by-default pattern: create an empty AuthorizationPolicy (no rules) on the
namespace to deny all, then add explicit ALLOW policies per service.

### RequestAuthentication — JWT validation
```yaml
apiVersion: security.istio.io/v1
kind: RequestAuthentication
metadata:
  name: jwt-auth
  namespace: production
spec:
  selector:
    matchLabels:
      app: backend-api
  jwtRules:
    - issuer: "https://auth.example.com"
      jwksUri: "https://auth.example.com/.well-known/jwks.json"
      forwardOriginalToken: true
```

Combine with AuthorizationPolicy matching on `request.auth.claims` for
claim-based access control.

## Observability

### Kiali — Service mesh topology and configuration validation
```bash
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.24/samples/addons/kiali.yaml
istioctl dashboard kiali
```

### Jaeger — Distributed tracing
```bash
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.24/samples/addons/jaeger.yaml
```
Propagate trace headers (`x-request-id`, `x-b3-traceid`, `x-b3-spanid`,
`x-b3-parentspanid`, `x-b3-sampled`) in application code for full trace context.

### Prometheus metrics
Istio exposes standard metrics: `istio_requests_total`, `istio_request_duration_milliseconds`,
`istio_tcp_connections_opened_total`. Scrape from Envoy sidecars on port 15090.

```promql
# Error rate for a service
sum(rate(istio_requests_total{destination_service="svc.ns.svc.cluster.local",
  response_code=~"5.."}[5m]))
/
sum(rate(istio_requests_total{destination_service="svc.ns.svc.cluster.local"}[5m]))
```

### Access logs
Enable Envoy access logs in the mesh config:
```yaml
meshConfig:
  accessLogFile: /dev/stdout
  accessLogEncoding: JSON
```

## Envoy Filters and Extensions

### Lua filter — Lightweight request/response manipulation
```yaml
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata:
  name: lua-add-header
spec:
  workloadSelector:
    labels:
      app: my-service
  configPatches:
    - applyTo: HTTP_FILTER
      match:
        context: SIDECAR_INBOUND
        listener:
          filterChain:
            filter:
              name: envoy.filters.network.http_connection_manager
              subFilter:
                name: envoy.filters.http.router
      patch:
        operation: INSERT_BEFORE
        value:
          name: envoy.filters.http.lua
          typed_config:
            "@type": type.googleapis.com/envoy.extensions.filters.http.lua.v3.Lua
            inline_code: |
              function envoy_on_response(response_handle)
                response_handle:headers():add("x-mesh-processed", "true")
              end
```

### WasmPlugin — Advanced extensibility (Istio 1.12+)
```yaml
apiVersion: extensions.istio.io/v1alpha1
kind: WasmPlugin
metadata:
  name: custom-auth
  namespace: istio-system
spec:
  selector:
    matchLabels:
      app: my-service
  url: oci://ghcr.io/myorg/auth-plugin:v1.0
  phase: AUTHN
  pluginConfig:
    auth_header: "x-custom-token"
```

Use Lua for simple header manipulation. Use Wasm (Rust/Go/C++) for complex logic,
custom auth, or protocol-level transformations.

## Ambient Mesh (Sidecar-less Mode)

Ambient mesh (GA in Istio 1.24, Nov 2024) removes per-pod sidecars entirely.

Architecture:
- **ztunnel**: Rust-based per-node L4 proxy (DaemonSet). Handles mTLS, L4 policy,
  and basic telemetry. Zero application changes required.
- **Waypoint proxy**: Optional per-namespace/service-account Envoy instance for L7
  features (HTTP routing, L7 auth policies, advanced telemetry).

```bash
# Install Istio in ambient mode
istioctl install --set profile=ambient -y

# Enroll a namespace (no pod restarts needed)
kubectl label namespace default istio.io/dataplane-mode=ambient
```

Benefits: 40-60% lower resource usage, no pod restarts for mesh upgrades, smaller
attack surface. Use ambient mode for new deployments; migrate existing sidecar
workloads gradually.

## Linkerd Comparison

| Aspect | Istio | Linkerd |
|--------|-------|---------|
| Proxy | Envoy (C++) | linkerd2-proxy (Rust) |
| Resource overhead | Higher | 40-400% lower latency |
| Feature depth | Advanced L7 routing, Wasm, multi-cluster | Essential mesh features |
| Complexity | Steep learning curve | Minimal configuration |
| mTLS | Configurable modes | Zero-config, always on |
| Extensibility | Lua, Wasm, EnvoyFilter | Limited by design |

Choose Linkerd when: team is small, Kubernetes-only, latency-sensitive workloads,
want zero-config mTLS and simplicity over advanced features.

Choose Istio when: need advanced traffic management, Wasm extensibility, multi-cluster
or hybrid cloud, VM workloads, or granular policy enforcement.

## Multi-Cluster Mesh

### Primary-remote topology
One cluster runs `istiod`; remote clusters connect to it.
```bash
# On primary cluster
istioctl install --set values.global.meshID=mesh1 \
  --set values.global.multiCluster.clusterName=cluster1 \
  --set values.global.network=network1

# Create remote secret for cross-cluster auth
istioctl create-remote-secret --name=cluster2 | \
  kubectl apply -f - --context=cluster1
```

### Multi-primary topology
Each cluster runs its own `istiod`. Use for independent failure domains.
Share a common root CA for cross-cluster mTLS trust.

## Performance Overhead and Optimization

Typical sidecar overhead: 0.5-1ms p50 latency, ~50MB memory per proxy, ~0.1 CPU.

Optimization strategies:
- Use ambient mesh to eliminate per-pod proxy overhead
- Tune `concurrency` in proxy config (match to workload CPU)
- Disable unused features: `meshConfig.enablePrometheusMerge: false` if not scraping
- Use Sidecar resource to limit proxy config scope:
```yaml
apiVersion: networking.istio.io/v1beta1
kind: Sidecar
metadata:
  name: limited-scope
  namespace: my-namespace
spec:
  egress:
    - hosts:
        - "./*"
        - "istio-system/*"
```
- Set `holdApplicationUntilProxyStarts: true` to prevent race conditions at startup
- Monitor proxy memory with `istio_agent_pilot_proxy_convergence_time` metric
