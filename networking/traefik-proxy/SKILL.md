---
name: traefik-proxy
description: >
  Generate and debug Traefik proxy configurations across Docker, Kubernetes, and file providers.
  Trigger ON: "Traefik proxy", "Traefik router", "Traefik middleware", "Traefik IngressRoute",
  "Traefik Docker labels", "Traefik Let's Encrypt", "Traefik entrypoints", "Traefik load balancer",
  Traefik TLS, Traefik ACME, Traefik reverse proxy, Traefik service discovery, Traefik dashboard,
  Traefik rate limiting, Traefik circuit breaker, Traefik TCP/UDP routing, Traefik observability.
  Trigger OFF: "Nginx config", "HAProxy", "Caddy server", "AWS ALB/ELB", "Envoy proxy",
  Apache httpd, Istio service mesh without Traefik, pure Kubernetes Ingress without Traefik CRDs.
---

# Traefik Proxy Skill

## Architecture

Two config layers: **static** (startup, requires restart): entrypoints, providers, cert resolvers, API; **dynamic** (hot-reloaded): routers, services, middlewares, TLS. Set static via `traefik.yml`, CLI flags, or env vars. Dynamic supplied by providers.

**Request flow:** `EntryPoint → Router (rule match) → Middleware chain → Service → Backend`

| Primitive | Purpose |
|-----------|---------|
| **EntryPoint** | Network listener (port + protocol). `web :80`, `websecure :443`. |
| **Router** | Matches requests by rules, dispatches to service, attaches middlewares. |
| **Service** | Backend target(s): LoadBalancer, Mirroring, Weighted. |
| **Middleware** | Request/response pipeline: auth, headers, rate limit, retry, circuit breaker. |
| **Provider** | Dynamic config source: Docker, Kubernetes CRD, File, Consul, etcd, ECS. |

## Static Configuration (traefik.yml)

```yaml
entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint: { to: websecure, scheme: https }
  websecure:
    address: ":443"
api:
  dashboard: true
  insecure: false          # never true in production
providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    exposedByDefault: false
    network: proxy
  file:
    directory: "/etc/traefik/dynamic"
    watch: true
  kubernetesCRD: {}
certificatesResolvers:
  letsencrypt:
    acme:
      email: admin@example.com
      storage: /data/acme.json
      httpChallenge:
        entryPoint: web
log:
  level: INFO
accessLog:
  filePath: "/var/log/traefik/access.log"
  bufferingSize: 100
metrics:
  prometheus:
    entryPoint: metrics
    addEntryPointsLabels: true
    addServicesLabels: true
    addRoutersLabels: true
tracing:
  otlp:
    grpc:
      endpoint: "jaeger:4317"
      insecure: true
```

## Docker Provider — Labels

### Traefik container

```yaml
services:
  traefik:
    image: traefik:v3.2
    restart: unless-stopped
    ports: ["80:80", "443:443"]
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./traefik.yml:/traefik.yml:ro
      - ./dynamic:/etc/traefik/dynamic:ro
      - traefik-certs:/data
    networks: [proxy]
    security_opt: [no-new-privileges:true]
networks:
  proxy: { external: true }
volumes:
  traefik-certs:
```

### Application labels

```yaml
services:
  myapp:
    image: myapp:latest
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.myapp.rule=Host(`app.example.com`)"
      - "traefik.http.routers.myapp.entrypoints=websecure"
      - "traefik.http.routers.myapp.tls.certresolver=letsencrypt"
      - "traefik.http.services.myapp.loadbalancer.server.port=8080"
      - "traefik.http.routers.myapp.middlewares=secure-headers@file,rate-limit@docker"
      - "traefik.http.services.myapp.loadbalancer.healthcheck.path=/health"
      - "traefik.http.services.myapp.loadbalancer.healthcheck.interval=10s"
    networks: [proxy]
```

### Label quick reference (prefix `traefik.http.`)

| Label | Purpose |
|-------|---------|
| `routers.<n>.rule` | `Host()`, `PathPrefix()`, `Headers()`, `Method()` |
| `routers.<n>.entrypoints` | Comma-separated entrypoint names |
| `routers.<n>.tls.certresolver` | ACME resolver name |
| `routers.<n>.middlewares` | `<name>@<provider>` list |
| `routers.<n>.priority` | Integer, higher wins |
| `services.<n>.loadbalancer.server.port` | Container port |
| `services.<n>.loadbalancer.sticky.cookie.name` | Session affinity |

## Kubernetes — IngressRoute CRDs

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: myapp
spec:
  entryPoints: [websecure]
  routes:
    - match: Host(`app.example.com`) && PathPrefix(`/api`)
      kind: Rule
      middlewares:
        - name: rate-limit
      services:
        - name: myapp-svc
          port: 80
  tls:
    certResolver: letsencrypt
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: rate-limit
spec:
  rateLimit:
    average: 100
    burst: 200
    period: 1s
    sourceCriterion:
      ipStrategy: { depth: 1 }
---
apiVersion: traefik.io/v1alpha1
kind: IngressRouteTCP
metadata:
  name: postgres
spec:
  entryPoints: [postgres]
  routes:
    - match: HostSNI(`db.example.com`)
      services:
        - name: postgres-svc
          port: 5432
  tls:
    passthrough: true
```

## File Provider — Dynamic Config

Place YAML in watched directory. Traefik hot-reloads on change.

```yaml
# /etc/traefik/dynamic/services.yml
http:
  routers:
    legacy-app:
      rule: "Host(`legacy.example.com`)"
      entryPoints: [websecure]
      middlewares: [secure-headers]
      service: legacy-svc
      tls: { certResolver: letsencrypt }
  services:
    legacy-svc:
      loadBalancer:
        servers:
          - url: "http://10.0.1.10:3000"
          - url: "http://10.0.1.11:3000"
        healthCheck: { path: /healthz, interval: 15s, timeout: 3s }
  middlewares:
    secure-headers:
      headers:
        sslRedirect: true
        forceSTSHeader: true
        stsSeconds: 63072000
        stsIncludeSubdomains: true
        stsPreload: true
        contentTypeNosniff: true
        browserXssFilter: true
        frameDeny: true
```

## HTTPS — Let's Encrypt (ACME)

| Challenge | Requires | Wildcards | Best For |
|-----------|----------|-----------|----------|
| HTTP-01 | Port 80 open | No | Standard servers |
| TLS-ALPN-01 | Port 443 open | No | Port 80 blocked |
| DNS-01 | DNS API access | Yes | Wildcards, private nets |

```yaml
# HTTP challenge
certificatesResolvers:
  le:
    acme:
      email: admin@example.com
      storage: /data/acme.json
      httpChallenge: { entryPoint: web }

# DNS challenge (Cloudflare) — set CF_DNS_API_TOKEN env var
certificatesResolvers:
  le:
    acme:
      email: admin@example.com
      storage: /data/acme.json
      dnsChallenge: { provider: cloudflare, resolvers: ["1.1.1.1:53"] }

# TLS-ALPN challenge
certificatesResolvers:
  le:
    acme:
      email: admin@example.com
      storage: /data/acme.json
      tlsChallenge: {}
```

Persist `acme.json` with `chmod 600`. Use staging for testing: `caServer: https://acme-staging-v02.api.letsencrypt.org/directory`

## Middlewares Reference

```yaml
http:
  middlewares:
    # BasicAuth
    auth:
      basicAuth:
        users: ["admin:$apr1$xyz$hashedpassword"]
        removeHeader: true

    # Rate Limiting — 429 on exceed
    rate-limit:
      rateLimit:
        average: 100
        burst: 200
        period: 1s
        sourceCriterion:
          requestHeaderName: X-Forwarded-For

    # Security Headers
    security-headers:
      headers:
        sslRedirect: true
        forceSTSHeader: true
        stsSeconds: 31536000
        contentTypeNosniff: true
        browserXssFilter: true
        referrerPolicy: "strict-origin-when-cross-origin"
        permissionsPolicy: "camera=(), microphone=(), geolocation=()"

    # Retry on 5xx / network errors
    retry:
      retry:
        attempts: 3
        initialInterval: 500ms

    # Circuit Breaker — trips → 503
    cb:
      circuitBreaker:
        expression: "ResponseCodeRatio(500, 600, 0, 600) > 0.25"
        checkPeriod: 10s
        fallbackDuration: 30s
        recoveryDuration: 60s

    # Compress
    gzip:
      compress:
        excludedContentTypes: ["text/event-stream"]

    # Path manipulation
    strip-api:
      stripPrefix: { prefixes: ["/api"] }
    add-v2:
      addPrefix: { prefix: "/v2" }

    # Chain — compose middlewares
    production-stack:
      chain:
        middlewares: [security-headers, rate-limit, gzip, retry]
```

CB expressions: `NetworkErrorRatio() > 0.3`, `LatencyAtQuantileMS(95.0) > 2000`.

## Load Balancing

```yaml
http:
  services:
    # Weighted — canary deployments
    app-canary:
      weighted:
        services:
          - name: app-v1
            weight: 90
          - name: app-v2
            weight: 10
    # Mirroring — shadow traffic
    mirror-app:
      mirroring:
        service: app-primary
        mirrors:
          - name: app-shadow
            percent: 10
    # Sticky sessions
    sticky-app:
      loadBalancer:
        sticky:
          cookie: { name: srv_id, secure: true, httpOnly: true }
        servers:
          - url: "http://backend1:8080"
          - url: "http://backend2:8080"
```

## Dashboard and API

Route dashboard to `api@internal` — never set `api.insecure=true` in prod:

```yaml
http:
  routers:
    dashboard:
      rule: "Host(`traefik.example.com`)"
      entryPoints: [websecure]
      service: api@internal
      middlewares: [dashboard-auth]
      tls: { certResolver: letsencrypt }
  middlewares:
    dashboard-auth:
      basicAuth:
        users: ["admin:$apr1$xyz$hashedpassword"]
```

API endpoints: `GET /api/http/routers`, `/api/http/services`, `/api/http/middlewares`, `/api/overview`, `/api/entrypoints`.

## Metrics and Observability

```yaml
# Prometheus — expose on dedicated entrypoint
entryPoints:
  metrics:
    address: ":8082"
metrics:
  prometheus:
    entryPoint: metrics
    addRoutersLabels: true
# Key metrics: traefik_entrypoint_requests_total, traefik_router_requests_total,
# traefik_service_requests_total, traefik_entrypoint_request_duration_seconds_bucket,
# traefik_service_open_connections

# Tracing — OpenTelemetry / Jaeger
tracing:
  otlp:
    grpc: { endpoint: "jaeger-collector:4317", insecure: true }

# Access logs — JSON format
accessLog:
  filePath: "/var/log/traefik/access.log"
  format: json
  fields:
    headers:
      names:
        User-Agent: keep
        Authorization: drop
```

## TCP and UDP Routing

```yaml
# Static entrypoints
entryPoints:
  postgres: { address: ":5432" }
  dns: { address: ":53/udp" }

# Dynamic — TCP
tcp:
  routers:
    postgres:
      rule: "HostSNI(`db.example.com`)"
      entryPoints: [postgres]
      service: pg-backend
      tls: { passthrough: true }
  services:
    pg-backend:
      loadBalancer:
        servers:
          - address: "10.0.1.20:5432"

# Dynamic — UDP
udp:
  routers:
    dns:
      entryPoints: [dns]
      service: dns-backend
  services:
    dns-backend:
      loadBalancer:
        servers:
          - address: "10.0.1.30:53"
```

TCP uses `HostSNI()` for matching; `HostSNI(` `` `*` `` `)` for catch-all without TLS. UDP has no match rules — binds directly to entrypoint.

## Examples

### Input: "Set up Traefik with HTTPS, dashboard, and a web app in Docker Compose"

Output: Use the template in [`assets/docker-compose.yaml`](assets/docker-compose.yaml) — it includes Traefik with Let's Encrypt, secured dashboard (BasicAuth), HTTP→HTTPS redirect, and example services. Customize domains, email, and dashboard password (generate with `htpasswd -nbB admin password`, double all `$` signs).

### Input: "Route 90% to v1 and 10% to v2 for canary"

Output: Use weighted service (see Load Balancing section) with `app-v1 weight:90`, `app-v2 weight:10`, router pointing to the weighted service on `websecure` with TLS.

## Troubleshooting

- **404 everywhere**: Check `exposedByDefault`, verify `traefik.enable=true`, confirm container is on correct Docker network.
- **502 Bad Gateway**: Port mismatch — `loadbalancer.server.port` must match container listen port.
- **ACME failures**: `chmod 600 acme.json`, verify port 80/443 reachable, check logs: `docker logs traefik 2>&1 | grep acme`.
- **Middleware ignored**: Verify `@provider` suffix — Docker-defined = `@docker`, file-defined = `@file`.
- **Dashboard down**: Route to `api@internal` service. Never `api.insecure=true` in production.
- **TCP conflicts**: One catch-all `HostSNI(*)` per TCP entrypoint. Use TLS + distinct SNI to multiplex.

## Resources

### References

Deep-dive reference documents for complex scenarios:

| Document | Contents |
|----------|----------|
| [`references/advanced-patterns.md`](references/advanced-patterns.md) | Plugin system, custom middleware, Traefik Hub, canary/weighted deployments, mTLS, Consul/etcd providers, dynamic config reloading, custom error pages, regex path matching, gRPC proxying, ForwardAuth, IP allowlisting |
| [`references/troubleshooting.md`](references/troubleshooting.md) | Diagnosing 404/502/503/504, certificate renewal failures, Docker socket security, provider conflicts, middleware ordering, WebSocket drops, memory optimization, log analysis, debug mode, health checks |
| [`references/kubernetes-guide.md`](references/kubernetes-guide.md) | CRD installation, IngressRoute/IngressRouteTCP/IngressRouteUDP, Middleware CRD, TLSOption/TLSStore, TraefikService (canary/mirroring), cert-manager integration, Helm chart values, RBAC, HA, monitoring |

### Scripts

Executable helpers — run with `--help` for usage:

| Script | Purpose |
|--------|---------|
| [`scripts/setup-traefik.sh`](scripts/setup-traefik.sh) | Deploy Traefik via Docker Compose or Helm. Generates static config, dynamic config, dashboard auth, acme.json. Supports `--staging` for Let's Encrypt testing. |
| [`scripts/test-config.sh`](scripts/test-config.sh) | Validate traefik.yml syntax, check ACME storage permissions, query API for router/service/middleware health, test TLS certificates, verify HTTP→HTTPS redirects and security headers. |
| [`scripts/generate-middleware.sh`](scripts/generate-middleware.sh) | Generate middleware configs (auth, rate-limit, headers, CORS, compress, circuit-breaker, redirect, IP allowlist, chain). Output as YAML, Docker labels, or Kubernetes CRDs. |

### Assets

Production-ready templates — copy and customize:

| Template | Description |
|----------|-------------|
| [`assets/docker-compose.yaml`](assets/docker-compose.yaml) | Full Docker Compose with Traefik, Let's Encrypt, secured dashboard, Prometheus metrics, Docker socket proxy option, and example services (whoami, webapp, API). |
| [`assets/traefik.yaml`](assets/traefik.yaml) | Static configuration template with entrypoints (HTTP→HTTPS redirect), Docker + File providers, ACME (HTTP + DNS challenge), structured logging, Prometheus metrics, OpenTelemetry tracing, and connection pool tuning. |
| [`assets/dynamic-config.yaml`](assets/dynamic-config.yaml) | Dynamic configuration with example routers (app, API, WebSocket, legacy), services (load balancer, canary weighted, mirroring), full middleware set (security headers, rate limiting, CORS, compression, circuit breaker, auth, path manipulation), and TLS options (modern, intermediate, mTLS). |
