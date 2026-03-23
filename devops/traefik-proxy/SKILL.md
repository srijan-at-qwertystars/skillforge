---
name: traefik-proxy
description: >
  Configure and deploy Traefik v3 as a reverse proxy and edge router.
  Covers static/dynamic configuration, Docker labels provider, Kubernetes IngressRoute CRDs,
  file provider, entrypoints, routers, services, middleware (headers, rate limiting, basicAuth,
  compress, stripPrefix, retry, circuitBreaker), Let's Encrypt ACME with certificatesResolvers,
  TLS termination, service discovery, load balancing, TCP/UDP routing, health checks, Traefik
  Dashboard, metrics (Prometheus, Datadog, InfluxDB), access logs, OpenTelemetry tracing, WASM
  plugins, and Docker Compose deployment patterns.
  Use when: configuring Traefik, reverse proxy setup, edge router, service discovery, Docker labels
  routing, Let's Encrypt certificates, middleware chains, IngressRoute.
  Do NOT use for: Nginx configuration, Caddy server setup, HAProxy configuration, or general load
  balancing theory without a Traefik context.
---

# Traefik v3 — Reverse Proxy & Edge Router

## Overview

Traefik is a cloud-native edge router and reverse proxy that auto-discovers services by watching infrastructure APIs (Docker, Kubernetes, Consul, etcd) and updates routes in real time with zero restarts. Written in Go, ships as a single binary or container (`traefik:v3`).

Core model: providers emit dynamic configuration → Traefik reconciles routers, services, middleware → traffic flows.

## Static vs Dynamic Configuration

**Static** (set at startup, requires restart): entrypoints, providers, certificatesResolvers, API/dashboard, logging, metrics, tracing endpoints. Supply via CLI flags, env vars, or `traefik.yml`.

**Dynamic** (hot-reloaded): routers, services, middlewares. Supply via Docker labels, Kubernetes CRDs, file provider, or KV stores.

```yaml
# traefik.yml (static config)
entryPoints:
  web: { address: ":80" }
  websecure: { address: ":443", http3: {} }
providers:
  docker: { endpoint: "unix:///var/run/docker.sock", exposedByDefault: false }
  file: { directory: /etc/traefik/dynamic, watch: true }
api: { dashboard: true, insecure: false }
```

## Entrypoints

Network listeners. Define addresses and protocol settings in static config.

```yaml
entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint: { to: websecure, scheme: https }
  websecure:
    address: ":443"
    http3: {}           # HTTP/3 (QUIC) — stable in v3
  metrics: { address: ":8082" }
  tcp-pg: { address: ":5432" }
  udp-dns: { address: ":5353/udp" }
```

Redirect HTTP → HTTPS at the entrypoint level, not per-router middleware.

## Routers

Match incoming requests and bind to services through middleware chains.

```yaml
http:
  routers:
    app:
      rule: "Host(`app.example.com`) && PathPrefix(`/api`)"
      entryPoints: [websecure]
      service: app-svc
      middlewares: [rate-limit, secure-headers]
      tls: { certResolver: letsencrypt }
```

v3 matchers: `Host()`, `HostRegexp()`, `Path()`, `PathPrefix()`, `PathRegexp()`, `Method()`, `Headers()`, `HeadersRegexp()`, `Query()`, `ClientIP()`. Combine with `&&`, `||`, `!`. Set `priority` explicitly when rules overlap.

## Services

Define backend targets and load-balancing behavior.

```yaml
http:
  services:
    app-svc:
      loadBalancer:
        servers:
          - url: "http://10.0.0.1:8080"
          - url: "http://10.0.0.2:8080"
        healthCheck: { path: /healthz, interval: 10s, timeout: 3s }
        passHostHeader: true
        sticky:
          cookie: { name: srv_id, secure: true, httpOnly: true }
    canary:                          # Weighted for canary/blue-green
      weighted:
        services:
          - { name: app-v1, weight: 90 }
          - { name: app-v2, weight: 10 }
    mirror:                          # Traffic mirroring
      mirroring:
        service: main-svc
        mirrors: [{ name: shadow-svc, percent: 10 }]
```

## Docker Provider

Enable: `providers.docker.exposedByDefault: false`. Configure routing via container labels.

```yaml
services:
  webapp:
    image: myapp:latest
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.webapp.rule=Host(`app.example.com`)"
      - "traefik.http.routers.webapp.entrypoints=websecure"
      - "traefik.http.routers.webapp.tls.certresolver=letsencrypt"
      - "traefik.http.services.webapp.loadbalancer.server.port=8080"
      - "traefik.http.routers.webapp.middlewares=secure-headers@docker,rate-limit@docker"
      - "traefik.http.middlewares.secure-headers.headers.framedeny=true"
      - "traefik.http.middlewares.secure-headers.headers.stsseconds=31536000"
      - "traefik.http.middlewares.rate-limit.ratelimit.average=100"
    networks: [proxy]
```

Key settings: `exposedByDefault: false`, `network: proxy` to pick correct container IP, use `@docker`/`@file` suffixes for cross-provider references. Docker Swarm uses separate `swarm` provider in v3 (`swarmMode` removed).

## Kubernetes IngressRoute (CRD)

Install CRDs via Helm. Use `traefik.io/v1alpha1` API group.

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata: { name: app-ingress }
spec:
  entryPoints: [websecure]
  routes:
    - match: Host(`app.example.com`)
      kind: Rule
      services: [{ name: app-service, port: 80 }]
      middlewares: [{ name: rate-limit }]
  tls: { certResolver: letsencrypt }
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata: { name: rate-limit }
spec:
  rateLimit: { average: 100, burst: 200 }
```

Additional CRDs: `IngressRouteTCP`, `IngressRouteUDP`, `TLSOption`, `TLSStore`, `TraefikService`, `ServersTransport`. v3 also supports Kubernetes Gateway API (`HTTPRoute`, `TLSRoute`, `TCPRoute`) as a production-ready alternative.

## File Provider

For non-Docker/K8s environments or shared middleware definitions.

```yaml
# Static: providers.file.directory: /etc/traefik/dynamic, watch: true
# /etc/traefik/dynamic/routes.yml
http:
  routers:
    legacy:
      rule: "Host(`legacy.example.com`)"
      service: legacy-svc
      entryPoints: [websecure]
      tls: { certResolver: letsencrypt }
  services:
    legacy-svc:
      loadBalancer:
        servers: [{ url: "http://192.168.1.50:3000" }]
```

Reference file-defined resources from Docker labels with `@file` suffix.

## HTTPS / TLS

### certificatesResolvers (Let's Encrypt / ACME)

```yaml
certificatesResolvers:
  letsencrypt:
    acme:
      email: admin@example.com
      storage: /letsencrypt/acme.json   # persist via volume, chmod 600
      httpChallenge: { entryPoint: web }
  letsencrypt-dns:
    acme:
      email: admin@example.com
      storage: /letsencrypt/acme-dns.json
      dnsChallenge:
        provider: cloudflare            # set CF_DNS_API_TOKEN env var
        resolvers: ["1.1.1.1:53", "8.8.8.8:53"]
```

Challenge types: `httpChallenge` (port 80, simplest), `dnsChallenge` (works behind firewalls, supports wildcards), `tlsChallenge` (TLS-ALPN-01 on port 443).

### TLS Options & Manual Certs

```yaml
tls:
  options:
    modern: { minVersion: VersionTLS13 }
    intermediate:
      minVersion: VersionTLS12
      cipherSuites: [TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256, TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384]
  certificates:
    - certFile: /certs/example.com.crt
      keyFile: /certs/example.com.key
  stores:
    default:
      defaultCertificate: { certFile: /certs/default.crt, keyFile: /certs/default.key }
```

Assign to router: `tls.options: modern@file`.

## Middleware

### Headers

```yaml
security-headers:
  headers:
    frameDeny: true
    contentTypeNosniff: true
    browserXssFilter: true
    referrerPolicy: "strict-origin-when-cross-origin"
    contentSecurityPolicy: "default-src 'self'"
    stsSeconds: 31536000
    stsIncludeSubdomains: true
    stsPreload: true
    customResponseHeaders: { X-Powered-By: "", Server: "" }
    accessControlAllowOriginList: ["https://app.example.com"]
    accessControlAllowMethods: [GET, POST, OPTIONS]
```

### Rate Limiting

```yaml
rate-limit:
  rateLimit:
    average: 100          # requests per period
    burst: 200
    period: 1s
    sourceCriterion:
      ipStrategy: { depth: 1 }
```

Token bucket algorithm. Returns 429 when exceeded.

### BasicAuth

```yaml
basic-auth:
  basicAuth:
    users: ["admin:$apr1$xyz$hashedpassword"]
    removeHeader: true
```

Generate with `htpasswd -nB admin`. Escape `$` as `$$` in Docker Compose.

### Compress

```yaml
gzip:
  compress:
    excludedContentTypes: ["text/event-stream"]
    minResponseBodyBytes: 1024
```

Supports gzip, Brotli, Zstandard. Encoding chosen by client `Accept-Encoding`.

### StripPrefix

```yaml
strip-api:
  stripPrefix:
    prefixes: [/api/v1]    # /api/v1/users → backend receives /users
```

### Retry

```yaml
retry:
  retry:
    attempts: 3
    initialInterval: 100ms
```

Retries on network errors. Avoid for non-idempotent requests.

### CircuitBreaker

```yaml
circuit-breaker:
  circuitBreaker:
    expression: "NetworkErrorRatio() > 0.30 || ResponseCodeRatio(500, 600, 0, 600) > 0.25"
    checkPeriod: 10s
    fallbackDuration: 30s
    recoveryDuration: 60s
```

Expressions: `NetworkErrorRatio()`, `ResponseCodeRatio(from, to, dividedByFrom, dividedByTo)`, `LatencyAtQuantileMS(quantile)`.

### Other Middleware

- `ipAllowList` — restrict by CIDR (replaces deprecated `ipWhiteList`).
- `forwardAuth` — delegate auth to external service (Authelia, Authentik, OAuth2 Proxy).
- `chain` — group middlewares under one name.
- `redirectScheme` / `redirectRegex` — URL rewriting.
- `addPrefix` — prepend path prefix to requests.
- `buffering` — limit request body size.

```yaml
auth-chain:
  chain:
    middlewares: [security-headers, rate-limit, forward-auth]
```

## Load Balancing

Default: **RoundRobin**. Use `weighted` for canary deployments. Use `sticky.cookie` for session affinity (avoid for stateless services). See Services section for config examples.

## Health Checks

```yaml
healthCheck:
  path: /healthz
  interval: 15s
  timeout: 5s
  headers: { X-Health: check }
```

Configure on `loadBalancer` services. Unhealthy servers removed from pool. All servers failing → 503.

## Traefik Dashboard

Secure via a router with auth middleware. Never use `api.insecure: true` in production.

```yaml
labels:
  - "traefik.http.routers.dashboard.rule=Host(`traefik.example.com`)"
  - "traefik.http.routers.dashboard.service=api@internal"
  - "traefik.http.routers.dashboard.entrypoints=websecure"
  - "traefik.http.routers.dashboard.tls.certresolver=letsencrypt"
  - "traefik.http.routers.dashboard.middlewares=dash-auth"
  - "traefik.http.middlewares.dash-auth.basicauth.users=admin:$$apr1$$xyz$$hash"
```

## TCP / UDP Routing

```yaml
tcp:
  routers:
    postgres:
      rule: "HostSNI(`db.example.com`)"   # HostSNI(`*`) for non-TLS
      entryPoints: [tcp-pg]
      service: pg-svc
      tls: { passthrough: true }          # forward encrypted, no termination
  services:
    pg-svc:
      loadBalancer:
        servers: [{ address: "10.0.0.5:5432" }]
udp:
  routers:
    dns:
      entryPoints: [udp-dns]
      service: dns-svc                    # UDP has no rule matching
  services:
    dns-svc:
      loadBalancer:
        servers: [{ address: "10.0.0.10:53" }]
```

## Metrics

```yaml
# Prometheus
metrics:
  prometheus:
    entryPoint: metrics
    addEntryPointsLabels: true
    addRoutersLabels: true
    addServicesLabels: true
    buckets: [0.1, 0.3, 1.2, 5.0]
# Datadog
  # datadog: { address: "127.0.0.1:8125", prefix: traefik }
# InfluxDB v2
  # influxDB2: { address: "http://influxdb:8086", token: "x", org: "o", bucket: "traefik" }
# OpenTelemetry (v3 native)
  # otlp: { grpc: { endpoint: "otel-collector:4317", insecure: true } }
```

Key metrics: `traefik_entrypoint_requests_total`, `traefik_service_request_duration_seconds`, `traefik_service_open_connections`, `traefik_tls_certs_not_after`.

## Access Logs & Tracing

```yaml
accessLog:
  filePath: "/var/log/traefik/access.log"  # omit for stdout (recommended in containers)
  format: json
  filters:
    statusCodes: ["400-499", "500-599"]
    minDuration: 100ms
  fields:
    headers:
      defaultMode: drop
      names: { User-Agent: keep, Authorization: redact }
  bufferingSize: 100
tracing:
  otlp:
    grpc: { endpoint: "otel-collector:4317", insecure: true }
  sampleRate: 0.1
```

OpenTelemetry is the primary tracing integration in v3. Legacy Jaeger/Zipkin direct integrations removed; use OpenTelemetry Collector to bridge.
## Plugins

Extend middleware via Traefik Plugin Catalog (plugins.traefik.io). v3 adds WASM plugin support.

```yaml
# Static — declare plugin
experimental:
  plugins:
    bouncer:
      moduleName: github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin
      version: v1.3.5
# Dynamic — use as middleware
http:
  middlewares:
    crowdsec:
      plugin:
        bouncer: { crowdsecLapiKey: "key", crowdsecLapiHost: "http://crowdsec:8080" }
```

Popular plugins: CrowdSec bouncer, GeoBlock, RewriteBody, ModSecurity, theme.park.

## Docker Compose Production Template

See `assets/docker-compose.yml` for a complete production template. Key practices: mount socket `:ro`, use `no-new-privileges`, dedicated `proxy` network, named volumes for certs, secrets in `.env` never in labels.
## Traefik vs Nginx vs Caddy

| Feature | Traefik v3 | Nginx | Caddy |
|---|---|---|---|
| Auto-discovery | Native (Docker, K8s, Consul) | None | None |
| Config reload | Hot, zero-downtime | `nginx -s reload` | API hot reload |
| Let's Encrypt | Built-in ACME | Requires certbot | Built-in |
| Dashboard | Built-in | Third-party | None |
| TCP/UDP | Native | Stream module | Limited |
| HTTP/3 | Stable | Experimental | Stable |
| K8s support | CRD + Gateway API | Ingress controller | Adapter |

Choose Traefik for dynamic service discovery and container-native environments. Choose Nginx for raw throughput and static configs. Choose Caddy for simplicity and automatic HTTPS without discovery needs.

## Common Anti-Patterns

1. **`api.insecure: true` in prod** — exposes unauthenticated dashboard. Secure with router + auth middleware.
2. **`exposedByDefault: true`** — every container gets a route. Set `false`, opt-in per service.
3. **Docker socket without `:ro`** — grants write access. Mount read-only; consider docker-socket-proxy.
4. **No `acme.json` persistence** — certs regenerate on restart, hitting LE rate limits. Use volumes.
5. **Duplicating middleware on every container** — use `chain` or file provider, reference by name.
6. **Greedy `HostRegexp` at high priority** — shadows specific routes. Set explicit priorities.
7. **Missing health checks** — unhealthy backends receive traffic → 502s. Always set `healthCheck`.
8. **Wildcard `HostSNI(*)` on TLS TCP** — bypasses SNI. Use only for non-TLS catch-all.
9. **Multiple instances sharing `acme.json` on disk** — causes conflicts. Use KV store (Consul, etcd, Redis).
10. **No `providers.docker.network`** — Traefik picks wrong IP on multi-network containers. Always specify.
11. **No container resource limits** — unbounded memory under load. Set memory/CPU limits.
12. **Using deprecated v2 syntax** — `ipWhiteList` → `ipAllowList`, `swarmMode` → `swarm` provider, `tls.caOptional` removed.

## Resources

### References

| File | Description |
|---|---|
| `references/advanced-patterns.md` | Custom plugins, Traefik Hub, canary/blue-green deployments, gRPC, WebSocket, distributed rate limiting, IP filtering, content-based routing, Consul/etcd providers, multi-region setups |
| `references/troubleshooting.md` | Certificate failures, Docker socket security, label conflicts, middleware ordering, 502/504 debugging, dashboard access, hot reload issues, memory leaks, log tuning, K8s CRD mismatches |
| `references/kubernetes-guide.md` | Helm chart config, IngressRoute/Middleware/TLSOption CRDs, cross-namespace references, Ingress vs IngressRoute vs Gateway API, cert-manager integration |

### Scripts

| File | Description |
|---|---|
| `scripts/traefik-validate.sh` | Validate static config, dynamic config files/dirs, and Docker Compose for common issues |
| `scripts/traefik-docker-setup.sh` | Bootstrap Traefik with Docker: creates network, directories, configs, and Compose file |
| `scripts/traefik-cert-check.sh` | Check certificate status from acme.json, Traefik API, or live TLS handshake |

### Assets

| File | Description |
|---|---|
| `assets/docker-compose.yml` | Production Compose with Traefik, dashboard, metrics, and example services |
| `assets/traefik.yml` | Production static config with entrypoints, providers, ACME, logging, and metrics |
| `assets/dynamic-config.yml` | Dynamic config template: middleware chains, TLS options, rate limiting |
| `assets/kubernetes-values.yml` | Helm values for HA Traefik on Kubernetes with autoscaling, security, and observability |
