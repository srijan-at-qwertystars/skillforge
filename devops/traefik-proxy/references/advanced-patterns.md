# Advanced Traefik Patterns

## Table of Contents

- [Custom Plugin Development](#custom-plugin-development)
- [Traefik Hub](#traefik-hub)
- [Canary Deployments with Weighted Services](#canary-deployments-with-weighted-services)
- [gRPC Proxying](#grpc-proxying)
- [WebSocket Handling](#websocket-handling)
- [Rate Limiting with Redis](#rate-limiting-with-redis)
- [IP Whitelisting Strategies](#ip-whitelisting-strategies)
- [Content-Based Routing](#content-based-routing)
- [Consul and etcd Providers](#consul-and-etcd-providers)
- [Multi-Region Setups](#multi-region-setups)

---

## Custom Plugin Development

Traefik supports two plugin types: **Yaegi-interpreted Go** (classic) and **WASM** (v3+).

### Yaegi Go Plugins

Plugins run as interpreted Go inside Traefik — no external binaries.

**Project structure:**

```
traefik-plugin-example/
├── .traefik.yml          # Plugin manifest
├── go.mod
├── plugin.go             # Main middleware logic
└── plugin_test.go
```

**Manifest (`.traefik.yml`):**

```yaml
displayName: Example Plugin
type: middleware
import: github.com/yourorg/traefik-plugin-example
summary: Adds a custom header to responses
testData:
  headerName: X-Custom
  headerValue: "hello"
```

**Middleware implementation (`plugin.go`):**

```go
package traefik_plugin_example

import (
    "context"
    "net/http"
)

type Config struct {
    HeaderName  string `json:"headerName,omitempty"`
    HeaderValue string `json:"headerValue,omitempty"`
}

func CreateConfig() *Config {
    return &Config{}
}

type Plugin struct {
    next        http.Handler
    name        string
    headerName  string
    headerValue string
}

func New(ctx context.Context, next http.Handler, config *Config, name string) (http.Handler, error) {
    return &Plugin{
        next:        next,
        name:        name,
        headerName:  config.HeaderName,
        headerValue: config.HeaderValue,
    }, nil
}

func (p *Plugin) ServeHTTP(rw http.ResponseWriter, req *http.Request) {
    rw.Header().Set(p.headerName, p.headerValue)
    p.next.ServeHTTP(rw, req)
}
```

**Local testing (static config):**

```yaml
experimental:
  localPlugins:
    example:
      moduleName: github.com/yourorg/traefik-plugin-example
```

Mount the plugin directory into Traefik's `/plugins-local/src/github.com/yourorg/traefik-plugin-example/`.

**Publishing:** Register at [plugins.traefik.io](https://plugins.traefik.io), push to GitHub with `.traefik.yml` at repo root.

### WASM Plugins (v3)

Compile any language to WASM. Traefik uses the proxy-wasm ABI.

```yaml
experimental:
  plugins:
    my-wasm:
      moduleName: github.com/yourorg/traefik-wasm-plugin
      version: v1.0.0
      # WASM modules detected automatically by .wasm extension
```

WASM plugins have better isolation but slightly higher overhead than Yaegi plugins.

### Plugin Limitations

- No access to Traefik internals (only `http.Handler` chain).
- Yaegi doesn't support all Go features (no CGo, limited reflection).
- Plugins cannot modify TLS configuration.
- Plugin errors crash the middleware chain — handle errors gracefully.

---

## Traefik Hub

Traefik Hub extends Traefik with a control plane for API management, access control, and multi-cluster networking.

### Key Features

- **API Gateway:** OpenAPI-driven policies, versioning, and rate limiting.
- **Access Control:** OIDC/JWT validation at the edge without ForwardAuth.
- **Multi-Cluster:** Connect services across clusters with encrypted tunnels.
- **API Portal:** Auto-generated developer portal from OpenAPI specs.

### Hub Agent Setup (Docker)

```yaml
services:
  traefik:
    image: traefik:v3.4
    command:
      - "--experimental.hub=true"
      - "--hub.tls.insecure=true"
      - "--metrics.prometheus.addRoutersLabels=true"
    environment:
      - TRAEFIK_HUB_TOKEN=${HUB_TOKEN}
```

### Hub API Access Control

```yaml
apiVersion: hub.traefik.io/v1alpha1
kind: APIAccess
metadata:
  name: internal-api
spec:
  groups: ["developers"]
  apis:
    - name: user-api
      namespace: production
  operationFilter:
    include: ["GET", "POST"]
```

### When to Use Hub vs Standalone

| Scenario | Standalone Traefik | Traefik Hub |
|---|---|---|
| Single cluster | ✅ | Overkill |
| Multi-cluster routing | Manual | ✅ Native |
| API management | Plugin-based | ✅ Built-in |
| Team access control | ForwardAuth | ✅ OIDC native |
| Cost sensitivity | Free/OSS | Licensed |

---

## Canary Deployments with Weighted Services

### Basic Weighted Routing

```yaml
http:
  services:
    app-canary:
      weighted:
        services:
          - name: app-stable
            weight: 95
          - name: app-canary
            weight: 5
        healthCheck: {}  # Respect backend health checks

    app-stable:
      loadBalancer:
        servers:
          - url: "http://app-v1:8080"
        healthCheck:
          path: /healthz
          interval: 10s

    app-canary:
      loadBalancer:
        servers:
          - url: "http://app-v2:8080"
        healthCheck:
          path: /healthz
          interval: 5s
```

### Progressive Canary with Docker Labels

```yaml
# Stage 1: 5% canary
services:
  app-v2:
    labels:
      - "traefik.http.services.app.weighted.services.0.name=app-v1"
      - "traefik.http.services.app.weighted.services.0.weight=95"
      - "traefik.http.services.app.weighted.services.1.name=app-v2"
      - "traefik.http.services.app.weighted.services.1.weight=5"
```

Adjust weights by updating labels and Traefik hot-reloads. Automate with scripts that update Docker labels or file provider YAML.

### Header-Based Canary

Route beta users explicitly instead of random percentage:

```yaml
http:
  routers:
    app-canary:
      rule: "Host(`app.example.com`) && Headers(`X-Canary`, `true`)"
      service: app-v2
      priority: 100
    app-stable:
      rule: "Host(`app.example.com`)"
      service: app-v1
      priority: 50
```

### Blue-Green Deployments

Set weight to 0/100 for instant cutover:

```yaml
http:
  services:
    app-bg:
      weighted:
        services:
          - name: blue
            weight: 0    # Previous version, drained
          - name: green
            weight: 100  # New version, active
```

---

## gRPC Proxying

Traefik natively supports gRPC over HTTP/2 — no special configuration needed.

### Backend Configuration

```yaml
http:
  routers:
    grpc-api:
      rule: "Host(`grpc.example.com`)"
      entryPoints: [websecure]
      service: grpc-svc
      tls:
        certResolver: letsencrypt

  services:
    grpc-svc:
      loadBalancer:
        servers:
          - url: "h2c://grpc-server:50051"  # h2c for plaintext HTTP/2
        # Use "https://..." for TLS backends
```

### Key Points

- Use `h2c://` scheme for plaintext gRPC backends (HTTP/2 cleartext).
- Use `https://` for TLS-encrypted gRPC backends.
- `passHostHeader: true` (default) passes the Host header to backends.
- gRPC health checks: use gRPC health protocol or standard HTTP path on a side port.
- Streaming works natively — no timeout adjustments needed for unary calls.

### ServersTransport for gRPC TLS

```yaml
http:
  serversTransports:
    grpc-tls:
      serverName: "grpc-internal.example.com"
      rootCAs: ["/certs/ca.pem"]
      # insecureSkipVerify: true  # Dev only

  services:
    grpc-svc:
      loadBalancer:
        serversTransport: grpc-tls
        servers:
          - url: "https://grpc-server:50051"
```

### Docker Labels for gRPC

```yaml
services:
  grpc-app:
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.grpc.rule=Host(`grpc.example.com`)"
      - "traefik.http.routers.grpc.entrypoints=websecure"
      - "traefik.http.routers.grpc.tls.certresolver=letsencrypt"
      - "traefik.http.services.grpc.loadbalancer.server.port=50051"
      - "traefik.http.services.grpc.loadbalancer.server.scheme=h2c"
```

---

## WebSocket Handling

WebSocket connections work transparently through Traefik — no special middleware.

### Configuration

Standard HTTP routers handle WebSocket upgrade:

```yaml
http:
  routers:
    ws-app:
      rule: "Host(`ws.example.com`)"
      entryPoints: [websecure]
      service: ws-svc
      tls:
        certResolver: letsencrypt

  services:
    ws-svc:
      loadBalancer:
        servers:
          - url: "http://ws-backend:3000"
        sticky:
          cookie:
            name: ws_affinity
            secure: true
            httpOnly: true
```

### Important Considerations

- **Sticky sessions:** Required when multiple backend instances maintain connection state. Without them, reconnections may hit different instances.
- **Timeouts:** Traefik does not enforce idle timeouts on WebSocket connections by default. Backend-side heartbeats are sufficient.
- **Load balancing:** Only the initial HTTP upgrade request is load-balanced. The persistent connection stays on one backend.
- **Buffering middleware:** Avoid `buffering` middleware on WebSocket routes — it interferes with streaming.
- **Compress middleware:** Works with WebSocket but applies only to the HTTP upgrade, not to WebSocket frames.

### WebSocket with Path Routing

```yaml
http:
  routers:
    ws-chat:
      rule: "Host(`app.example.com`) && PathPrefix(`/ws`)"
      service: chat-svc
      priority: 100
    http-app:
      rule: "Host(`app.example.com`)"
      service: web-svc
      priority: 50
```

---

## Rate Limiting with Redis

Traefik's built-in rate limiter is in-memory and per-instance. For distributed rate limiting across multiple Traefik instances, use a plugin or external approach.

### CrowdSec Bouncer Plugin (Distributed)

CrowdSec provides distributed rate limiting and threat detection:

```yaml
# Static config
experimental:
  plugins:
    crowdsec:
      moduleName: github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin
      version: v1.3.5

# Dynamic config
http:
  middlewares:
    crowdsec-bouncer:
      plugin:
        crowdsec:
          crowdsecLapiKey: "${CROWDSEC_API_KEY}"
          crowdsecLapiHost: "http://crowdsec:8080"
          crowdsecMode: stream
          updateIntervalSeconds: 15
```

### ForwardAuth with Redis-Backed Rate Limiter

Deploy a rate-limiting microservice backed by Redis:

```yaml
http:
  middlewares:
    redis-rate-limit:
      forwardAuth:
        address: "http://rate-limiter:3000/check"
        trustForwardHeader: true
        authResponseHeaders:
          - X-RateLimit-Remaining
          - X-RateLimit-Limit
          - Retry-After
```

The rate-limiter service uses Redis `INCR` + `EXPIRE` or Redis Cell module for sliding window limiting.

### Per-Instance Rate Limiting (Built-in)

When per-instance limiting is acceptable:

```yaml
http:
  middlewares:
    strict-limit:
      rateLimit:
        average: 50
        burst: 100
        period: 1m
        sourceCriterion:
          requestHeaderName: "X-Real-IP"
          # Or use ipStrategy for proxy chains:
          # ipStrategy:
          #   depth: 1            # Skip 1 proxy
          #   excludedIPs: ["10.0.0.0/8"]
    api-key-limit:
      rateLimit:
        average: 1000
        burst: 2000
        period: 1h
        sourceCriterion:
          requestHeaderName: "X-API-Key"
```

---

## IP Whitelisting Strategies

### Direct IP Allow List

```yaml
http:
  middlewares:
    office-only:
      ipAllowList:
        sourceRange:
          - "203.0.113.0/24"
          - "198.51.100.50/32"
        # rejectStatusCode: 403  # Default is 403
```

### With Proxy Depth

When behind CDN/load balancer, use `ipStrategy` to find real client IP:

```yaml
http:
  middlewares:
    ip-filter:
      ipAllowList:
        sourceRange: ["10.20.0.0/16"]
        ipStrategy:
          depth: 2  # Skip 2 proxies in X-Forwarded-For
```

### Layered Access Control

Combine IP filtering with authentication:

```yaml
http:
  middlewares:
    admin-access:
      chain:
        middlewares:
          - admin-ip-filter
          - admin-auth

    admin-ip-filter:
      ipAllowList:
        sourceRange: ["10.0.0.0/8"]

    admin-auth:
      forwardAuth:
        address: "http://authelia:9091/api/verify"
        trustForwardHeader: true
```

### GeoIP-Based Filtering

Use the GeoBlock plugin for country-level filtering:

```yaml
experimental:
  plugins:
    geoblock:
      moduleName: github.com/PascalMinder/geoblock
      version: v0.2.8

http:
  middlewares:
    geo-filter:
      plugin:
        geoblock:
          allowLocalRequests: true
          logLocalRequests: false
          logAllowedRequests: false
          logApiRequests: false
          api: "https://get.geojs.io/v1/ip/country/{ip}"
          countries: ["US", "CA", "GB", "DE", "FR"]
```

---

## Content-Based Routing

### Header-Based Routing

```yaml
http:
  routers:
    api-v2:
      rule: "Host(`api.example.com`) && Headers(`Accept`, `application/vnd.api.v2+json`)"
      service: api-v2-svc
      priority: 100
    api-v1:
      rule: "Host(`api.example.com`)"
      service: api-v1-svc
      priority: 50
```

### Query Parameter Routing

```yaml
http:
  routers:
    debug-mode:
      rule: "Host(`app.example.com`) && Query(`debug`, `true`)"
      service: debug-svc
      middlewares: [debug-headers]
      priority: 100
```

### Method-Based Routing

```yaml
http:
  routers:
    read-api:
      rule: "Host(`api.example.com`) && Method(`GET`, `HEAD`)"
      service: read-replicas
      priority: 100
    write-api:
      rule: "Host(`api.example.com`) && Method(`POST`, `PUT`, `DELETE`, `PATCH`)"
      service: primary-db-svc
      priority: 100
```

### ClientIP Routing

```yaml
http:
  routers:
    internal:
      rule: "Host(`app.example.com`) && ClientIP(`10.0.0.0/8`)"
      service: internal-svc
      priority: 100
    external:
      rule: "Host(`app.example.com`)"
      service: external-svc
      priority: 50
```

---

## Consul and etcd Providers

### Consul Provider

```yaml
# Static config
providers:
  consul:
    endpoints: ["consul:8500"]
    rootKey: "traefik"
    token: "${CONSUL_TOKEN}"
    tls:
      ca: /certs/consul-ca.pem
      cert: /certs/consul-client.pem
      key: /certs/consul-client-key.pem
```

Store dynamic config in Consul KV at `traefik/http/routers/...`, `traefik/http/services/...`.

### Consul Catalog Provider

Auto-discover Consul services with tags:

```yaml
providers:
  consulCatalog:
    endpoint:
      address: "consul:8500"
      token: "${CONSUL_TOKEN}"
    exposedByDefault: false
    prefix: "traefik"
    connectAware: true     # Support Consul Connect
    serviceName: "traefik" # Register Traefik itself
```

Tag services in Consul:

```hcl
service {
  name = "webapp"
  port = 8080
  tags = [
    "traefik.enable=true",
    "traefik.http.routers.webapp.rule=Host(`app.example.com`)",
    "traefik.http.routers.webapp.entrypoints=websecure",
  ]
}
```

### etcd Provider

```yaml
providers:
  etcd:
    endpoints: ["etcd1:2379", "etcd2:2379", "etcd3:2379"]
    rootKey: "traefik"
    username: "${ETCD_USER}"
    password: "${ETCD_PASS}"
    tls:
      ca: /certs/etcd-ca.pem
      cert: /certs/etcd-client.pem
      key: /certs/etcd-client-key.pem
```

Populate with `etcdctl`:

```bash
etcdctl put traefik/http/routers/app/rule 'Host(`app.example.com`)'
etcdctl put traefik/http/routers/app/service 'app-svc'
etcdctl put traefik/http/services/app-svc/loadBalancer/servers/0/url 'http://backend:8080'
```

### KV Stores for ACME Certificates

Share certificates across Traefik instances:

```yaml
certificatesResolvers:
  letsencrypt:
    acme:
      email: admin@example.com
      storage: "consul://consul:8500/traefik/acme"
      # Or: "etcd://etcd:2379/traefik/acme"
      httpChallenge:
        entryPoint: web
```

---

## Multi-Region Setups

### Architecture Patterns

**Pattern 1: Independent Traefik per region with DNS failover**

- Each region runs its own Traefik instance(s).
- GeoDNS (Route53, Cloudflare) routes users to nearest region.
- No shared state between regions.

**Pattern 2: Global load balancer + regional Traefik**

```
Users → Global LB (Cloudflare/AWS GLB) → Regional Traefik → Local Services
```

**Pattern 3: Traefik Hub multi-cluster**

Hub connects Traefik instances across regions with encrypted tunnels and provides a unified control plane.

### Regional Health Checks with Failover

```yaml
http:
  services:
    global-api:
      weighted:
        services:
          - name: us-east-api
            weight: 50
          - name: eu-west-api
            weight: 50
        healthCheck: {}

    us-east-api:
      loadBalancer:
        servers:
          - url: "https://us-east.internal:8080"
        healthCheck:
          path: /healthz
          interval: 5s
          timeout: 3s
          hostname: "api.example.com"

    eu-west-api:
      loadBalancer:
        servers:
          - url: "https://eu-west.internal:8080"
        healthCheck:
          path: /healthz
          interval: 5s
          timeout: 3s
```

### Shared Certificate Storage

For HA Traefik clusters in any region, use a distributed KV store instead of `acme.json` files:

```yaml
certificatesResolvers:
  letsencrypt:
    acme:
      storage: "consul://consul.service.consul:8500/traefik/acme/region-us"
```

### Cross-Region Configuration Sync

- Use **Consul** with WAN federation or **etcd** with multi-cluster to sync configurations.
- Store shared middleware definitions in KV, region-specific routes locally.
- Use **GitOps** (ArgoCD, Flux) for Kubernetes-based Traefik deployments.

### Latency Considerations

- Place Traefik as close to backends as possible (same AZ/datacenter).
- Use `passHostHeader: true` to preserve original Host for backends.
- Enable HTTP/3 (QUIC) for improved connection setup latency across regions.
- Consider `ServersTransport` with keep-alive settings for cross-region backend calls.
