# Advanced Service Mesh Patterns

## Table of Contents

- [Wasm Plugin Development for Envoy](#wasm-plugin-development-for-envoy)
- [Multi-Cluster Mesh Federation](#multi-cluster-mesh-federation)
- [External Authorization (ext-authz)](#external-authorization-ext-authz)
- [Rate Limiting with Envoy](#rate-limiting-with-envoy)
- [Traffic Mirroring / Shadowing](#traffic-mirroring--shadowing)
- [Locality-Aware Load Balancing](#locality-aware-load-balancing)
- [Progressive Delivery with Flagger](#progressive-delivery-with-flagger)
- [Istio Ambient Mesh Deep Dive](#istio-ambient-mesh-deep-dive)
- [Egress Control Patterns](#egress-control-patterns)
- [Custom Envoy Filters with Lua](#custom-envoy-filters-with-lua)

---

## Wasm Plugin Development for Envoy

### Overview

WebAssembly (Wasm) plugins extend Envoy without recompiling the proxy. Istio's
`WasmPlugin` CRD deploys them declaratively. Wasm runs in a sandboxed VM inside
Envoy, enabling safe, portable, language-agnostic extensions.

### Supported Languages and SDKs

| Language | SDK | Maturity |
|----------|-----|----------|
| Rust | `proxy-wasm-rust-sdk` | Production-ready |
| Go | `proxy-wasm-go-sdk` | Production-ready |
| C++ | `proxy-wasm-cpp-sdk` | Stable |
| AssemblyScript | `proxy-wasm-assemblyscript-sdk` | Experimental |

### Rust Plugin Scaffold

```rust
use proxy_wasm::traits::*;
use proxy_wasm::types::*;

proxy_wasm::main! {{
    proxy_wasm::set_log_level(LogLevel::Info);
    proxy_wasm::set_http_context(|context_id, _| -> Box<dyn HttpContext> {
        Box::new(CustomAuth { context_id })
    });
}}

struct CustomAuth {
    context_id: u32,
}

impl Context for CustomAuth {}

impl HttpContext for CustomAuth {
    fn on_http_request_headers(&mut self, _num_headers: usize, _end_of_stream: bool) -> Action {
        match self.get_http_request_header("x-api-key") {
            Some(key) if key == "valid-key" => Action::Continue,
            _ => {
                self.send_http_response(403, vec![], Some(b"Forbidden"));
                Action::Pause
            }
        }
    }

    fn on_http_response_headers(&mut self, _num_headers: usize, _end_of_stream: bool) -> Action {
        self.set_http_response_header("x-wasm-processed", Some("true"));
        Action::Continue
    }
}
```

### Build and Deploy

```bash
# Build the Wasm binary
cargo build --target wasm32-wasi --release

# Push to OCI registry
wasm-to-oci push target/wasm32-wasi/release/plugin.wasm \
  ghcr.io/myorg/auth-plugin:v1.0

# Deploy via WasmPlugin CRD
cat <<EOF | kubectl apply -f -
apiVersion: extensions.istio.io/v1alpha1
kind: WasmPlugin
metadata:
  name: custom-auth
  namespace: default
spec:
  selector:
    matchLabels:
      app: my-service
  url: oci://ghcr.io/myorg/auth-plugin:v1.0
  phase: AUTHN
  pluginConfig:
    allowed_paths: ["/health", "/ready"]
  imagePullPolicy: IfNotPresent
EOF
```

### Plugin Lifecycle Phases

- `AUTHN` — Runs during authentication (before authorization).
- `AUTHZ` — Runs during authorization.
- `STATS` — Runs during stats collection (response path).
- Unset — Runs before the router filter.

### Performance Considerations

- Wasm adds ~0.2ms latency per plugin invocation.
- Use `imagePullPolicy: IfNotPresent` to cache plugin images on nodes.
- Avoid heavy computation in `on_http_request_body`; stream large bodies.
- Use shared data (`proxy_wasm::hostcalls::set_shared_data`) for cross-request
  caching within a single worker thread.

---

## Multi-Cluster Mesh Federation

### Topologies

**Primary-Remote**: Single control plane manages all clusters. Simpler but
creates a single point of failure for config distribution.

**Multi-Primary**: Each cluster runs its own `istiod`. Both discover services
across clusters via shared root CA and cross-cluster endpoint sync.

**Multi-Network**: Clusters on isolated networks use east-west gateways for
cross-cluster traffic. Required when pod IPs are not directly routable.

### Multi-Primary on Different Networks

```bash
# Cluster 1: Install with multi-cluster config
cat <<EOF > cluster1.yaml
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  values:
    global:
      meshID: production-mesh
      multiCluster:
        clusterName: cluster1
      network: network1
  meshConfig:
    defaultConfig:
      proxyMetadata:
        ISTIO_META_DNS_CAPTURE: "true"
        ISTIO_META_DNS_AUTO_ALLOCATE: "true"
EOF
istioctl install -f cluster1.yaml --context=cluster1

# Install east-west gateway for cross-network traffic
samples/multicluster/gen-eastwest-gateway.sh \
  --network network1 --cluster cluster1 | \
  istioctl install --context=cluster1 -y -f -

# Expose services via east-west gateway
kubectl --context=cluster1 apply -n istio-system \
  -f samples/multicluster/expose-services.yaml

# Exchange remote secrets
istioctl create-remote-secret --context=cluster1 --name=cluster1 | \
  kubectl apply --context=cluster2 -f -
istioctl create-remote-secret --context=cluster2 --name=cluster2 | \
  kubectl apply --context=cluster1 -f -
```

### Trust Domain Federation

For cross-cluster mTLS, all clusters must share a common root CA or configure
trust domain aliases:

```yaml
meshConfig:
  trustDomainAliases:
    - "cluster1.local"
    - "cluster2.local"
```

Or use a shared root CA with Cert Manager:
```bash
# Generate shared root CA
openssl req -x509 -sha256 -nodes -days 3650 \
  -newkey rsa:4096 -subj '/O=MyOrg/CN=MeshRootCA' \
  -keyout root-key.pem -out root-cert.pem

# Create intermediate CAs for each cluster from shared root
# Install each intermediate as cacerts secret in istio-system
kubectl create secret generic cacerts -n istio-system \
  --from-file=ca-cert.pem --from-file=ca-key.pem \
  --from-file=root-cert.pem --from-file=cert-chain.pem
```

### Verifying Cross-Cluster Connectivity

```bash
# Check endpoints are discovered across clusters
istioctl proxy-config endpoints <pod> --cluster "outbound|80||svc.ns.svc.cluster.local"

# Verify cross-cluster traffic
kubectl exec -it sleep-pod -- curl http://httpbin.sample.svc.cluster.local:8000/headers
```

---

## External Authorization (ext-authz)

ext-authz delegates authorization decisions to an external gRPC or HTTP service,
enabling centralized policy engines (OPA, custom auth services).

### Architecture

```
Client → Envoy Sidecar → ext-authz check → External Auth Service
                       ↓ (if allowed)
                    Upstream Service
```

### Deploy OPA as ext-authz Provider

```yaml
# Register ext-authz provider in Istio mesh config
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  meshConfig:
    extensionProviders:
      - name: opa-ext-authz
        envoyExtAuthzGrpc:
          service: opa.opa-system.svc.cluster.local
          port: 9191
          includeRequestBodyInCheck:
            maxRequestBytes: 4096
            allowPartialMessage: true
```

### AuthorizationPolicy with ext-authz

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: ext-authz-opa
  namespace: production
spec:
  selector:
    matchLabels:
      app: backend-api
  action: CUSTOM
  provider:
    name: opa-ext-authz
  rules:
    - to:
        - operation:
            paths: ["/api/*"]
            notPaths: ["/api/health"]
```

### OPA Policy Example (Rego)

```rego
package envoy.authz

import input.attributes.request.http as http_request

default allow := false

allow {
    http_request.method == "GET"
    glob.match("/api/public/*", ["/"], http_request.path)
}

allow {
    http_request.method == "POST"
    token := io.jwt.decode(bearer_token)
    token[1].role == "admin"
}

bearer_token := t {
    v := http_request.headers.authorization
    startswith(v, "Bearer ")
    t := substring(v, count("Bearer "), -1)
}
```

---

## Rate Limiting with Envoy

### Local Rate Limiting (Per-Proxy)

Apply token bucket rate limiting at each Envoy instance:

```yaml
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata:
  name: local-ratelimit
  namespace: default
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
          name: envoy.filters.http.local_ratelimit
          typed_config:
            "@type": type.googleapis.com/envoy.extensions.filters.http.local_ratelimit.v3.LocalRateLimit
            stat_prefix: http_local_rate_limiter
            token_bucket:
              max_tokens: 100
              tokens_per_fill: 100
              fill_interval: 60s
            filter_enabled:
              runtime_key: local_rate_limit_enabled
              default_value:
                numerator: 100
                denominator: HUNDRED
            filter_enforced:
              runtime_key: local_rate_limit_enforced
              default_value:
                numerator: 100
                denominator: HUNDRED
            response_headers_to_add:
              - append_action: OVERWRITE_IF_EXISTS_OR_ADD
                header:
                  key: x-local-rate-limit
                  value: "true"
```

### Global Rate Limiting (Centralized)

Use Envoy's rate limit service for cluster-wide limits:

```bash
# Deploy rate limit service (e.g., envoyproxy/ratelimit)
helm install ratelimit ./ratelimit-chart \
  --set redis.url=redis:6379

# Rate limit config
cat <<EOF > ratelimit-config.yaml
domain: production
descriptors:
  - key: header_match
    value: api-key
    rate_limit:
      unit: minute
      requests_per_unit: 60
  - key: remote_address
    rate_limit:
      unit: second
      requests_per_unit: 10
EOF
```

---

## Traffic Mirroring / Shadowing

Mirror production traffic to a test version without affecting responses. The
mirrored request is fire-and-forget — responses from the mirror target are
discarded.

### VirtualService with Mirroring

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
            subset: v1
          weight: 100
      mirror:
        host: my-service
        subset: v2
      mirrorPercentage:
        value: 50.0
```

### Use Cases

- **Testing new versions**: Mirror production load to canary for realistic
  load testing without user impact.
- **Data validation**: Mirror to a shadow service that validates response
  parity between old and new versions.
- **Performance benchmarking**: Compare latency/resource usage under real load.

### Caveats

- Mirrored requests include `-shadow` suffix in the `Host` header.
- POST/PUT requests are mirrored — ensure the mirror target uses a separate
  database or is idempotent.
- Mirror target errors do not affect the primary response.

---

## Locality-Aware Load Balancing

Route traffic preferentially to endpoints in the same zone/region to reduce
latency and cross-zone costs.

### Enable Locality Load Balancing

```yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: my-service
spec:
  host: my-service
  trafficPolicy:
    loadBalancer:
      localityLbSetting:
        enabled: true
        distribute:
          - from: "us-east-1/us-east-1a/*"
            to:
              "us-east-1/us-east-1a/*": 80
              "us-east-1/us-east-1b/*": 15
              "us-west-2/us-west-2a/*": 5
        failover:
          - from: us-east-1
            to: us-west-2
    outlierDetection:
      consecutive5xxErrors: 5
      interval: 30s
      baseEjectionTime: 30s
```

**Important**: Outlier detection MUST be configured for locality failover to
work. Without it, Envoy cannot detect unhealthy localities to fail away from.

### How Locality Is Determined

Envoy reads locality from Kubernetes node labels:
- `topology.kubernetes.io/region` → region
- `topology.kubernetes.io/zone` → zone
- `topology.istio.io/subzone` → subzone (optional)

---

## Progressive Delivery with Flagger

Flagger automates canary analysis and promotion using Istio traffic shifting
and Prometheus metrics.

### Install Flagger

```bash
helm repo add flagger https://flagger.app
helm install flagger flagger/flagger \
  --namespace istio-system \
  --set meshProvider=istio \
  --set metricsServer=http://prometheus:9090
```

### Canary CRD

```yaml
apiVersion: flagger.app/v1beta1
kind: Canary
metadata:
  name: my-service
  namespace: production
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: my-service
  progressDeadlineSeconds: 600
  service:
    port: 80
    targetPort: 8080
    gateways:
      - public-gateway.istio-system.svc.cluster.local
    hosts:
      - app.example.com
  analysis:
    interval: 1m
    threshold: 5           # max failed checks before rollback
    maxWeight: 50          # max canary traffic percentage
    stepWeight: 10         # increment per interval
    metrics:
      - name: request-success-rate
        thresholdRange:
          min: 99
        interval: 1m
      - name: request-duration
        thresholdRange:
          max: 500          # ms
        interval: 1m
    webhooks:
      - name: load-test
        type: rollout
        url: http://flagger-loadtester.test/
        metadata:
          cmd: "hey -z 1m -q 10 -c 2 http://my-service-canary.production:80/"
```

### Promotion Flow

1. Flagger detects a new revision (image tag or config change).
2. Creates canary deployment and routes initial `stepWeight` traffic to it.
3. Runs analysis at each `interval` — queries Prometheus for success rate and latency.
4. If metrics pass thresholds, increases traffic by `stepWeight`.
5. If a metric fails, increments failure counter. At `threshold` failures, rolls back.
6. At `maxWeight` with passing metrics, promotes canary to primary.

---

## Istio Ambient Mesh Deep Dive

### ztunnel (Zero Trust Tunnel)

ztunnel is a purpose-built, Rust-based L4 proxy deployed as a DaemonSet on every
node. It replaces sidecars for basic mesh functionality.

**Responsibilities**:
- mTLS encryption/decryption for all pod traffic on the node.
- L4 authorization policy enforcement.
- L4 telemetry (TCP metrics, connection-level logging).
- HBONE (HTTP-Based Overlay Network Environment) tunneling for cross-node traffic.

**Traffic Flow**:
```
Pod A → iptables redirect → ztunnel (source node)
  → HBONE tunnel (mTLS) →
ztunnel (dest node) → iptables redirect → Pod B
```

**Key Properties**:
- Shared per-node, not per-pod — dramatically reduces resource usage.
- Uses SPIFFE identities from Kubernetes service accounts.
- Cannot perform L7 inspection (no HTTP routing, header matching, etc.).

### Waypoint Proxies

Waypoint proxies are optional Envoy instances deployed per-namespace or
per-service-account for L7 features.

```bash
# Deploy a waypoint proxy for a namespace
istioctl waypoint apply --namespace production --enroll-namespace

# Deploy for a specific service account
istioctl waypoint apply --namespace production \
  --service-account my-service-sa
```

**When to Use Waypoint Proxies**:
- HTTP routing rules (VirtualService).
- L7 authorization policies (header-based, path-based).
- Advanced telemetry (HTTP metrics, distributed tracing).
- Traffic management (retries, timeouts, fault injection).

**Architecture with Waypoints**:
```
Pod A → ztunnel → Waypoint Proxy (L7) → ztunnel → Pod B
```

### Migration from Sidecar to Ambient

```bash
# 1. Install ambient profile
istioctl install --set profile=ambient -y

# 2. Enroll namespace (no pod restart needed)
kubectl label namespace production istio.io/dataplane-mode=ambient

# 3. Remove sidecar injection label
kubectl label namespace production istio-injection-

# 4. Restart pods to remove existing sidecars
kubectl rollout restart deployment -n production

# 5. Add waypoint if L7 features are needed
istioctl waypoint apply -n production --enroll-namespace
```

---

## Egress Control Patterns

### Default: Allow All Outbound

By default, Istio allows all outbound traffic. For security-sensitive
environments, switch to registry-only mode:

```yaml
meshConfig:
  outboundTrafficPolicy:
    mode: REGISTRY_ONLY
```

With `REGISTRY_ONLY`, only destinations registered via `ServiceEntry` are
reachable from the mesh.

### Egress Gateway Pattern

Route all external traffic through a dedicated egress gateway for monitoring,
policy enforcement, and audit logging.

```yaml
# ServiceEntry for external API
apiVersion: networking.istio.io/v1beta1
kind: ServiceEntry
metadata:
  name: external-api
spec:
  hosts:
    - api.partner.com
  ports:
    - number: 443
      name: tls
      protocol: TLS
  resolution: DNS
  location: MESH_EXTERNAL
---
# Gateway for egress
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: egress-gateway
spec:
  selector:
    istio: egressgateway
  servers:
    - port:
        number: 443
        name: tls
        protocol: TLS
      hosts:
        - api.partner.com
      tls:
        mode: PASSTHROUGH
---
# Route through egress gateway
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: external-api-via-egress
spec:
  hosts:
    - api.partner.com
  gateways:
    - mesh
    - egress-gateway
  tls:
    - match:
        - gateways: [mesh]
          port: 443
          sniHosts: [api.partner.com]
      route:
        - destination:
            host: istio-egressgateway.istio-system.svc.cluster.local
            port:
              number: 443
    - match:
        - gateways: [egress-gateway]
          port: 443
          sniHosts: [api.partner.com]
      route:
        - destination:
            host: api.partner.com
            port:
              number: 443
```

### Egress TLS Origination

Originate TLS at the egress gateway for services that require plain HTTP
internally but HTTPS externally:

```yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: originate-tls
spec:
  host: api.partner.com
  trafficPolicy:
    portLevelSettings:
      - port:
          number: 443
        tls:
          mode: SIMPLE
          sni: api.partner.com
```

---

## Custom Envoy Filters with Lua

### Request Header Manipulation

```yaml
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata:
  name: lua-request-transform
spec:
  workloadSelector:
    labels:
      app: api-gateway
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
              function envoy_on_request(request_handle)
                -- Add correlation ID if missing
                local correlation_id = request_handle:headers():get("x-correlation-id")
                if correlation_id == nil then
                  local id = string.format("%x%x", os.time(), math.random(0, 0xFFFF))
                  request_handle:headers():add("x-correlation-id", id)
                end

                -- Sanitize sensitive headers before forwarding
                request_handle:headers():remove("x-internal-debug")
              end

              function envoy_on_response(response_handle)
                -- Add timing and version headers
                response_handle:headers():add("x-envoy-mesh-version", "1.0")
                response_handle:headers():remove("server")
              end
```

### Response Body Logging

```lua
function envoy_on_response(response_handle)
  local content_type = response_handle:headers():get("content-type")
  if content_type and string.find(content_type, "application/json") then
    local body = response_handle:body():getBytes(0, response_handle:body():length())
    response_handle:logInfo("Response body: " .. body)
  end
end
```

### Lua vs Wasm Decision Matrix

| Criteria | Lua | Wasm |
|----------|-----|------|
| Use case | Simple header/body manipulation | Complex auth, protocol transforms |
| Performance | Good for small scripts | Better for heavy computation |
| Language | Lua only | Rust, Go, C++, AssemblyScript |
| Sandboxing | Limited | Full VM isolation |
| Debugging | Envoy logs | Richer tooling (language-native) |
| Deployment | Inline in EnvoyFilter | OCI image via WasmPlugin |

Use Lua for quick, small transformations (< 50 lines). Use Wasm for anything
requiring external libraries, complex logic, or strict sandboxing.
