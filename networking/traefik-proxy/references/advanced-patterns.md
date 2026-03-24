# Traefik Advanced Patterns

## Table of Contents

- [Plugin System](#plugin-system)
- [Custom Middleware Development](#custom-middleware-development)
- [Traefik Hub](#traefik-hub)
- [Canary Deployments with Weighted Services](#canary-deployments-with-weighted-services)
- [Mutual TLS (mTLS)](#mutual-tls-mtls)
- [Consul Provider](#consul-provider)
- [etcd Provider](#etcd-provider)
- [Dynamic Configuration Reloading](#dynamic-configuration-reloading)
- [Custom Error Pages](#custom-error-pages)
- [Regex Path Matching and Advanced Rules](#regex-path-matching-and-advanced-rules)
- [gRPC Proxying](#grpc-proxying)
- [Request Mirroring](#request-mirroring)
- [ForwardAuth Pattern](#forwardauth-pattern)
- [Multi-Domain and SAN Certificates](#multi-domain-and-san-certificates)
- [IP Allowlisting and Geofencing](#ip-allowlisting-and-geofencing)

---

## Plugin System

Traefik supports plugins (called "middleware plugins") loaded at startup. Plugins are Go
Wasm or Yaegi-interpreted modules fetched from the Traefik Plugin Catalog or local paths.

### Installing a Plugin from Catalog

```yaml
# traefik.yml (static config)
experimental:
  plugins:
    bouncer:
      moduleName: "github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin"
      version: "v1.3.0"
    rewrite-body:
      moduleName: "github.com/traefik/plugin-rewritebody"
      version: "v0.3.1"
```

### Using a Plugin as Middleware

```yaml
# dynamic config
http:
  middlewares:
    crowdsec:
      plugin:
        bouncer:
          crowdsecLapiKey: "your-api-key"
          crowdsecLapiHost: "http://crowdsec:8080"
          crowdsecMode: "stream"
    body-rewrite:
      plugin:
        rewrite-body:
          rewrites:
            - regex: "oldstring"
              replacement: "newstring"
```

### Local Plugin Development

```yaml
# traefik.yml
experimental:
  localPlugins:
    my-plugin:
      moduleName: "github.com/myorg/my-traefik-plugin"
```

Directory structure for a local plugin:

```
plugins-local/
  src/
    github.com/
      myorg/
        my-traefik-plugin/
          .traefik.yml       # plugin manifest
          plugin.go          # main plugin code
          plugin_test.go
          go.mod
```

Plugin manifest (`.traefik.yml`):

```yaml
displayName: My Plugin
type: middleware
import: github.com/myorg/my-traefik-plugin
summary: Custom middleware plugin
testData:
  headerName: X-Custom
  headerValue: test
```

Plugin Go interface — implement `New()`, `ServeHTTP()`:

```go
package my_traefik_plugin

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

type MyPlugin struct {
    next   http.Handler
    config *Config
    name   string
}

func New(ctx context.Context, next http.Handler, config *Config, name string) (http.Handler, error) {
    return &MyPlugin{next: next, config: config, name: name}, nil
}

func (p *MyPlugin) ServeHTTP(rw http.ResponseWriter, req *http.Request) {
    req.Header.Set(p.config.HeaderName, p.config.HeaderValue)
    p.next.ServeHTTP(rw, req)
}
```

### Plugin Best Practices

- Plugins run inside the Traefik process — keep them lightweight.
- Test with `traefik --configFile=traefik.yml` locally before deploying.
- Pin exact versions in production; `latest` can break on update.
- Use `experimental.localPlugins` during development, switch to catalog for prod.
- Plugin errors surface in Traefik logs at DEBUG level.

---

## Custom Middleware Development

Beyond plugins, compose complex behavior by chaining built-in middlewares:

### Middleware Chain Pattern

```yaml
http:
  middlewares:
    # Individual middlewares
    strip-api:
      stripPrefix:
        prefixes: ["/api"]
    add-cors:
      headers:
        accessControlAllowMethods: ["GET", "POST", "PUT", "DELETE", "OPTIONS"]
        accessControlAllowHeaders: ["Content-Type", "Authorization"]
        accessControlAllowOriginList: ["https://app.example.com"]
        accessControlMaxAge: 3600
        addVaryHeader: true
    auth-check:
      forwardAuth:
        address: "http://auth-service:4181"
        trustForwardHeader: true
        authResponseHeaders: ["X-User-Id", "X-User-Role"]
    rate-limit-api:
      rateLimit:
        average: 50
        burst: 100
        period: 1m
        sourceCriterion:
          requestHeaderName: "X-User-Id"

    # Chain combines them in order
    api-stack:
      chain:
        middlewares:
          - strip-api
          - rate-limit-api
          - auth-check
          - add-cors
```

### Middleware Ordering Rules

1. **stripPrefix/addPrefix** — before auth (so auth service sees clean paths).
2. **rateLimit** — before auth (reject early, save auth service load).
3. **forwardAuth/basicAuth** — after rate limiting.
4. **headers** (CORS, security) — after auth (add response headers).
5. **compress** — last (compress the final response).
6. **retry** — wraps the entire service call, applies after middleware chain.

### ContentType-based Routing with Headers Middleware

```yaml
http:
  routers:
    json-api:
      rule: "Host(`api.example.com`) && HeadersRegexp(`Content-Type`, `application/json.*`)"
      service: json-backend
      middlewares: [json-transform]
    xml-api:
      rule: "Host(`api.example.com`) && HeadersRegexp(`Content-Type`, `application/xml.*`)"
      service: xml-backend
```

---

## Traefik Hub

Traefik Hub extends Traefik with API management, access control, and multi-cluster networking.

### Key Features

- **API Gateway**: Publish, version, and manage APIs with an OpenAPI catalog.
- **Access Control**: JWT validation, API keys, OIDC integration at the edge.
- **Multi-cluster**: Connect Traefik instances across clusters without VPN.
- **Observability**: Centralized metrics, distributed tracing dashboard.

### Enabling Traefik Hub

```yaml
# traefik.yml
hub:
  tls:
    insecure: false
    ca: "/certs/hub-ca.pem"
  # Token from hub.traefik.io
experimental:
  hub: true
```

```bash
# Install Hub agent in Kubernetes
helm repo add traefik https://traefik.github.io/charts
helm install traefik-hub traefik/traefik-hub \
  --set hub.token="YOUR_HUB_TOKEN" \
  --namespace traefik \
  --create-namespace
```

### Hub API Access Control

```yaml
apiVersion: hub.traefik.io/v1alpha1
kind: APIAccess
metadata:
  name: internal-api
spec:
  apis:
    - name: user-api
  groups:
    - internal-developers
  operationFilter:
    include: ["GET", "POST"]
```

---

## Canary Deployments with Weighted Services

### Basic Canary (90/10 split)

```yaml
http:
  services:
    app-stable:
      loadBalancer:
        servers:
          - url: "http://app-v1:8080"
    app-canary:
      loadBalancer:
        servers:
          - url: "http://app-v2:8080"
    app-weighted:
      weighted:
        services:
          - name: app-stable
            weight: 90
          - name: app-canary
            weight: 10
  routers:
    app:
      rule: "Host(`app.example.com`)"
      service: app-weighted
      entryPoints: [websecure]
      tls:
        certResolver: letsencrypt
```

### Progressive Canary with Sticky Sessions

```yaml
http:
  services:
    app-weighted:
      weighted:
        services:
          - name: app-stable
            weight: 80
          - name: app-canary
            weight: 20
        sticky:
          cookie:
            name: canary_track
            secure: true
            httpOnly: true
            sameSite: strict
```

Once a user hits the canary, the cookie pins them there — consistent experience.

### Canary by Header (internal testing)

```yaml
http:
  routers:
    app-canary:
      rule: "Host(`app.example.com`) && Headers(`X-Canary`, `true`)"
      service: app-v2
      priority: 100    # higher priority wins
      entryPoints: [websecure]
      tls:
        certResolver: letsencrypt
    app-stable:
      rule: "Host(`app.example.com`)"
      service: app-v1
      priority: 50
      entryPoints: [websecure]
      tls:
        certResolver: letsencrypt
```

### Shadow Traffic with Mirroring

```yaml
http:
  services:
    app-mirrored:
      mirroring:
        service: app-stable
        maxBodySize: 1048576    # 1MB — limit mirrored body
        mirrors:
          - name: app-canary
            percent: 5
```

Mirror responses are discarded. Use for testing new versions under real load without risk.

---

## Mutual TLS (mTLS)

### Server-side TLS with Client Certificate Validation

```yaml
# Static config — define TLS options
tls:
  options:
    mtls-strict:
      minVersion: VersionTLS12
      clientAuth:
        caFiles:
          - /certs/client-ca.pem
        clientAuthType: RequireAndVerifyClientCert
      sniStrict: true
    mtls-optional:
      clientAuth:
        caFiles:
          - /certs/client-ca.pem
        clientAuthType: VerifyClientCertIfGiven
```

### Apply TLS Options to Router

```yaml
http:
  routers:
    secure-api:
      rule: "Host(`api.example.com`)"
      entryPoints: [websecure]
      service: api-svc
      tls:
        options: mtls-strict
        certResolver: letsencrypt
```

### Docker Labels for mTLS

```yaml
labels:
  - "traefik.http.routers.api.tls.options=mtls-strict@file"
```

### Pass Client Certificate Info to Backend

```yaml
http:
  middlewares:
    pass-client-cert:
      passTLSClientCert:
        pem: true
        info:
          notAfter: true
          notBefore: true
          sans: true
          subject:
            commonName: true
            organization: true
          issuer:
            commonName: true
```

Headers added: `X-Forwarded-Tls-Client-Cert`, `X-Forwarded-Tls-Client-Cert-Info`.

### Generating Test Certificates

```bash
# CA
openssl genrsa -out ca.key 4096
openssl req -new -x509 -days 3650 -key ca.key -out ca.pem -subj "/CN=My CA"

# Client cert
openssl genrsa -out client.key 4096
openssl req -new -key client.key -out client.csr -subj "/CN=client1/O=MyOrg"
openssl x509 -req -days 365 -in client.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out client.pem

# Test
curl --cert client.pem --key client.key https://api.example.com/secure
```

---

## Consul Provider

### Static Configuration

```yaml
providers:
  consul:
    endpoints:
      - "consul-server:8500"
    rootKey: "traefik"
    token: "consul-acl-token"
    tls:
      ca: /certs/consul-ca.pem
      cert: /certs/consul-cert.pem
      key: /certs/consul-key.pem
```

### Consul Catalog (Service Discovery)

```yaml
providers:
  consulCatalog:
    endpoint:
      address: "consul-server:8500"
      token: "consul-acl-token"
    prefix: "traefik"
    exposedByDefault: false
    defaultRule: "Host(`{{ .Name }}.example.com`)"
    connectAware: true      # Consul Connect integration
    connectByDefault: false
```

### Service Tags in Consul

```hcl
service {
  name = "webapp"
  port = 8080
  tags = [
    "traefik.enable=true",
    "traefik.http.routers.webapp.rule=Host(`webapp.example.com`)",
    "traefik.http.routers.webapp.entrypoints=websecure",
    "traefik.http.routers.webapp.tls.certresolver=letsencrypt",
    "traefik.http.services.webapp.loadbalancer.server.port=8080"
  ]
  check {
    http     = "http://localhost:8080/health"
    interval = "10s"
    timeout  = "2s"
  }
}
```

---

## etcd Provider

### Static Configuration

```yaml
providers:
  etcd:
    endpoints:
      - "etcd1:2379"
      - "etcd2:2379"
      - "etcd3:2379"
    rootKey: "traefik"
    username: "traefik"
    password: "secret"
    tls:
      ca: /certs/etcd-ca.pem
      cert: /certs/etcd-cert.pem
      key: /certs/etcd-key.pem
```

### Setting Keys in etcd

```bash
# Create a router
etcdctl put traefik/http/routers/myapp/rule 'Host(`app.example.com`)'
etcdctl put traefik/http/routers/myapp/entryPoints/0 'websecure'
etcdctl put traefik/http/routers/myapp/service 'myapp-svc'

# Create a service
etcdctl put traefik/http/services/myapp-svc/loadBalancer/servers/0/url 'http://backend:8080'

# Create middleware
etcdctl put traefik/http/middlewares/rate/rateLimit/average '100'
etcdctl put traefik/http/middlewares/rate/rateLimit/burst '200'
```

### etcd Watch and Hot-Reload

Traefik watches etcd keys under `rootKey`. Any change triggers immediate reconfiguration
without restart. Use etcd transactions for atomic multi-key updates:

```bash
etcdctl txn <<EOF
put traefik/http/services/app/loadBalancer/servers/0/url "http://new-backend:8080"
put traefik/http/services/app/loadBalancer/servers/1/url "http://new-backend2:8080"

EOF
```

---

## Dynamic Configuration Reloading

### File Provider Watch

```yaml
providers:
  file:
    directory: "/etc/traefik/dynamic"
    watch: true              # inotify-based, near-instant
```

Changes to any file in the directory trigger a full reload of dynamic config. Traefik
validates the config before applying — invalid config is rejected silently (check logs).

### Reload Strategies

| Provider | Reload Mechanism | Latency |
|----------|-----------------|---------|
| File | inotify watch | <1s |
| Docker | Docker event stream | <2s |
| Kubernetes | Watch API | <3s |
| Consul/etcd | Key watch | <2s |
| HTTP | Polling interval | Configurable |

### HTTP Provider (pull-based)

```yaml
providers:
  http:
    endpoint: "https://config-server.example.com/traefik/config"
    pollInterval: 15s
    pollTimeout: 10s
    tls:
      ca: /certs/ca.pem
```

### Atomic Config Updates

For file provider, write to a temp file then `mv` (atomic on same filesystem):

```bash
# Safe update pattern
cat > /tmp/new-config.yml <<'EOF'
http:
  routers:
    app:
      rule: "Host(`app.example.com`)"
      service: app-svc
EOF
mv /tmp/new-config.yml /etc/traefik/dynamic/app.yml
```

Direct writes may trigger multiple reloads on partial writes.

---

## Custom Error Pages

### Errors Middleware

```yaml
http:
  middlewares:
    custom-errors:
      errors:
        status: ["400-499", "500-599"]
        service: error-pages-svc
        query: "/{status}.html"
  services:
    error-pages-svc:
      loadBalancer:
        servers:
          - url: "http://error-pages:8080"
  routers:
    app:
      rule: "Host(`app.example.com`)"
      middlewares: [custom-errors]
      service: app-backend
```

The `query` field supports `{status}` and `{url}` placeholders.

### Error Pages Container

```yaml
# docker-compose
services:
  error-pages:
    image: tarampampam/error-pages:latest
    environment:
      TEMPLATE_NAME: ghost    # or: l7, shuffle, noise, hacker-terminal
    labels:
      - "traefik.enable=true"
      - "traefik.http.services.error-pages.loadbalancer.server.port=8080"
    networks: [proxy]
```

### Scoped Error Handling

```yaml
http:
  middlewares:
    # Only handle 5xx from backend (not 4xx)
    backend-errors:
      errors:
        status: ["500-599"]
        service: error-pages-svc
        query: "/server-error.html"
    # Handle specific codes
    not-found:
      errors:
        status: ["404"]
        service: error-pages-svc
        query: "/not-found.html"
```

---

## Regex Path Matching and Advanced Rules

### Router Rule Syntax (v3)

```yaml
http:
  routers:
    # Exact path
    exact:
      rule: "Host(`api.example.com`) && Path(`/health`)"

    # Path prefix
    prefix:
      rule: "Host(`api.example.com`) && PathPrefix(`/api/v1`)"

    # Regex path matching
    regex:
      rule: "Host(`api.example.com`) && PathRegexp(`/api/v[0-9]+/users/[0-9]+`)"

    # Header matching
    header-match:
      rule: "Host(`api.example.com`) && Headers(`X-Api-Version`, `2`)"

    # Header regex
    header-regex:
      rule: "Host(`api.example.com`) && HeadersRegexp(`Authorization`, `Bearer .+`)"

    # Query parameter
    query:
      rule: "Host(`api.example.com`) && Query(`debug`, `true`)"

    # Method matching
    method:
      rule: "Host(`api.example.com`) && Method(`GET`, `POST`)"

    # Client IP
    ip:
      rule: "Host(`admin.example.com`) && ClientIP(`10.0.0.0/8`)"

    # Complex combination
    complex:
      rule: >-
        Host(`api.example.com`) &&
        PathPrefix(`/api`) &&
        (Headers(`X-Internal`, `true`) || ClientIP(`10.0.0.0/8`)) &&
        !Method(`DELETE`)
```

### Priority Rules

- Longer rules get higher automatic priority.
- Set explicit `priority` to override: higher number wins.
- When rules overlap, define priority explicitly to avoid ambiguity.

```yaml
http:
  routers:
    # Specific route — higher priority
    api-users:
      rule: "Host(`api.example.com`) && PathPrefix(`/api/users`)"
      priority: 100
      service: users-svc
    # Catch-all API — lower priority
    api-catch:
      rule: "Host(`api.example.com`) && PathPrefix(`/api`)"
      priority: 50
      service: api-gateway
```

### Path Manipulation with Regex

```yaml
http:
  middlewares:
    # Replace path using regex
    rewrite-path:
      replacePathRegex:
        regex: "^/api/v1/(.*)"
        replacement: "/internal/$1"
    # Strip prefix then add new one
    remap-path:
      chain:
        middlewares:
          - strip-old
          - add-new
    strip-old:
      stripPrefix:
        prefixes: ["/legacy"]
    add-new:
      addPrefix:
        prefix: "/v2"
```

---

## gRPC Proxying

### HTTP/2 Backend (h2c — plaintext gRPC)

```yaml
http:
  services:
    grpc-service:
      loadBalancer:
        servers:
          - url: "h2c://grpc-backend:50051"
        healthCheck:
          path: "/grpc.health.v1.Health/Check"
          scheme: h2c
          interval: 10s
  routers:
    grpc:
      rule: "Host(`grpc.example.com`)"
      entryPoints: [websecure]
      service: grpc-service
      tls:
        certResolver: letsencrypt
```

### Docker Labels for gRPC

```yaml
labels:
  - "traefik.enable=true"
  - "traefik.http.routers.grpc.rule=Host(`grpc.example.com`)"
  - "traefik.http.routers.grpc.entrypoints=websecure"
  - "traefik.http.routers.grpc.tls.certresolver=le"
  - "traefik.http.services.grpc.loadbalancer.server.port=50051"
  - "traefik.http.services.grpc.loadbalancer.server.scheme=h2c"
```

### gRPC with TLS Backend

```yaml
http:
  services:
    grpc-tls:
      loadBalancer:
        servers:
          - url: "https://grpc-backend:50051"
        serversTransport: grpc-transport
  serversTransports:
    grpc-transport:
      serverName: "grpc-backend.internal"
      rootCAs:
        - /certs/internal-ca.pem
```

### gRPC-Web Support

Traefik handles gRPC-Web natively when using HTTP/2 entrypoints. For browser clients
using gRPC-Web, ensure the CORS middleware is configured:

```yaml
http:
  middlewares:
    grpc-cors:
      headers:
        accessControlAllowMethods: ["POST"]
        accessControlAllowHeaders:
          - "Content-Type"
          - "X-Grpc-Web"
          - "X-User-Agent"
        accessControlAllowOriginList:
          - "https://app.example.com"
        accessControlExposeHeaders:
          - "Grpc-Status"
          - "Grpc-Message"
```

---

## Request Mirroring

### Mirror a Percentage of Traffic

```yaml
http:
  services:
    production:
      loadBalancer:
        servers:
          - url: "http://prod-backend:8080"
    staging:
      loadBalancer:
        servers:
          - url: "http://staging-backend:8080"
    mirrored-service:
      mirroring:
        service: production
        maxBodySize: 5242880    # 5MB limit for mirrored requests
        mirrors:
          - name: staging
            percent: 10         # 10% of traffic mirrored to staging
```

- Mirror responses are **discarded** — clients only see production responses.
- `maxBodySize` prevents large uploads from being duplicated.
- Use for validation, performance testing, and shadow launches.

---

## ForwardAuth Pattern

### External Auth Service

```yaml
http:
  middlewares:
    oauth2-proxy:
      forwardAuth:
        address: "http://oauth2-proxy:4180/oauth2/auth"
        trustForwardHeader: true
        authResponseHeaders:
          - "X-Auth-Request-User"
          - "X-Auth-Request-Email"
          - "X-Auth-Request-Groups"
        authResponseHeadersRegex: "^X-Auth-"
        authRequestHeaders:
          - "Authorization"
          - "Cookie"
```

### Authelia Integration

```yaml
http:
  middlewares:
    authelia:
      forwardAuth:
        address: "http://authelia:9091/api/verify?rd=https://auth.example.com"
        trustForwardHeader: true
        authResponseHeaders:
          - "Remote-User"
          - "Remote-Groups"
          - "Remote-Email"
```

---

## Multi-Domain and SAN Certificates

### Multiple Domains on One Router

```yaml
http:
  routers:
    multi-domain:
      rule: "Host(`example.com`) || Host(`www.example.com`) || Host(`api.example.com`)"
      tls:
        certResolver: letsencrypt
        domains:
          - main: "example.com"
            sans:
              - "www.example.com"
              - "api.example.com"
```

### Wildcard with DNS Challenge

```yaml
certificatesResolvers:
  le-wildcard:
    acme:
      email: admin@example.com
      storage: /data/acme.json
      dnsChallenge:
        provider: cloudflare
        resolvers: ["1.1.1.1:53", "8.8.8.8:53"]
        delayBeforeCheck: 10s

# Router using wildcard
http:
  routers:
    wildcard:
      rule: "HostRegexp(`{subdomain:[a-z]+}.example.com`)"
      tls:
        certResolver: le-wildcard
        domains:
          - main: "example.com"
            sans:
              - "*.example.com"
```

---

## IP Allowlisting and Geofencing

### IP Allowlist Middleware

```yaml
http:
  middlewares:
    internal-only:
      ipAllowList:
        sourceRange:
          - "10.0.0.0/8"
          - "172.16.0.0/12"
          - "192.168.0.0/16"
        ipStrategy:
          depth: 1    # trust 1 level of X-Forwarded-For
    block-ranges:
      ipAllowList:
        sourceRange:
          - "0.0.0.0/0"            # allow all...
        rejectStatusCode: 403
```

### Combining with GeoIP (via plugin)

```yaml
experimental:
  plugins:
    geoblock:
      moduleName: "github.com/PascalMinder/geoblock"
      version: "v0.2.8"

# Dynamic config
http:
  middlewares:
    geo-restrict:
      plugin:
        geoblock:
          allowLocalRequests: true
          logLocalRequests: false
          logAllowedRequests: false
          logApiRequests: false
          api: "https://get.geojs.io/v1/ip/country/{ip}"
          allowCountries: ["US", "CA", "GB", "DE", "FR"]
```
