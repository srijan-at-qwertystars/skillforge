# Traefik Troubleshooting Guide

## Table of Contents

- [Diagnostic Approach](#diagnostic-approach)
- [HTTP Error Codes](#http-error-codes)
  - [404 Not Found](#404-not-found)
  - [502 Bad Gateway](#502-bad-gateway)
  - [503 Service Unavailable](#503-service-unavailable)
  - [504 Gateway Timeout](#504-gateway-timeout)
  - [429 Too Many Requests](#429-too-many-requests)
- [TLS and Certificate Issues](#tls-and-certificate-issues)
  - [Certificate Renewal Failures](#certificate-renewal-failures)
  - [TLS Handshake Errors](#tls-handshake-errors)
  - [Mixed TLS Versions](#mixed-tls-versions)
- [Docker Provider Issues](#docker-provider-issues)
  - [Docker Socket Security](#docker-socket-security)
  - [Container Discovery Problems](#container-discovery-problems)
  - [Network Connectivity](#network-connectivity)
- [Provider Conflicts](#provider-conflicts)
- [Middleware Issues](#middleware-issues)
  - [Middleware Ordering Problems](#middleware-ordering-problems)
  - [ForwardAuth Failures](#forwardauth-failures)
  - [Rate Limiting Misbehavior](#rate-limiting-misbehavior)
- [WebSocket Connection Drops](#websocket-connection-drops)
- [Performance and Memory](#performance-and-memory)
- [Log Analysis](#log-analysis)
- [Debug Mode](#debug-mode)
- [Health Checks](#health-checks)
- [Kubernetes-Specific Issues](#kubernetes-specific-issues)
- [Quick Reference Checklist](#quick-reference-checklist)

---

## Diagnostic Approach

Always start with these three steps:

```bash
# 1. Check Traefik logs (Docker)
docker logs traefik --tail 200 -f

# 2. Query the API to see registered config
curl -s http://localhost:8080/api/http/routers | jq .
curl -s http://localhost:8080/api/http/services | jq .
curl -s http://localhost:8080/api/http/middlewares | jq .
curl -s http://localhost:8080/api/overview | jq .

# 3. Enable debug logging temporarily
# Add to traefik.yml:   log: { level: DEBUG }
# Or CLI flag:          --log.level=DEBUG
# Or env var:           TRAEFIK_LOG_LEVEL=DEBUG
```

### Key Log Patterns

| Log Pattern | Meaning |
|-------------|---------|
| `no matching route` | Router rule didn't match the request |
| `service not found` | Service referenced by router doesn't exist |
| `server is not reachable` | Backend server connection failed |
| `middleware ... is not declared` | Middleware name typo or wrong provider suffix |
| `ACME challenge failed` | Certificate issuance problem |
| `entrypoint ... already exists` | Duplicate entrypoint definition |
| `skipping container` | Docker provider ignoring a container |

---

## HTTP Error Codes

### 404 Not Found

**Symptoms:** All or specific routes return 404.

**Cause 1: `exposedByDefault` is false and `traefik.enable` missing**

```yaml
# Problem: Container not discovered
providers:
  docker:
    exposedByDefault: false    # Requires traefik.enable=true per container

# Fix: Add label to container
labels:
  - "traefik.enable=true"
```

**Cause 2: Router rule doesn't match**

```bash
# Debug: Check what routers exist
curl -s http://localhost:8080/api/http/routers | jq '.[].rule'

# Common mistakes:
# - Host mismatch: "Host(`app.example.com`)" but accessing "localhost"
# - Missing backticks in Host()  (YAML quoting issue)
# - PathPrefix without leading slash
```

**Cause 3: Container not on Traefik's network**

```bash
# Check container networks
docker inspect <container> | jq '.[0].NetworkSettings.Networks | keys'

# Traefik must share at least one network with the backend
docker network connect proxy <container>
```

**Cause 4: Wrong entrypoints**

```yaml
# Router specifies websecure but request hits web (port 80)
routers:
  myapp:
    entryPoints: [websecure]    # Only listens on 443
    rule: "Host(`app.example.com`)"
```

**Cause 5: Priority conflict — another router matched first**

```bash
# Check router priorities
curl -s http://localhost:8080/api/http/routers | jq '.[] | {name: .name, rule: .rule, priority: .priority}'
```

### 502 Bad Gateway

**Symptoms:** Request reaches Traefik but backend connection fails.

**Cause 1: Port mismatch**

```yaml
# Wrong: Container listens on 3000, label says 8080
labels:
  - "traefik.http.services.app.loadbalancer.server.port=8080"  # WRONG

# Fix: Match the port the application actually listens on
labels:
  - "traefik.http.services.app.loadbalancer.server.port=3000"  # CORRECT
```

**Cause 2: Backend not ready**

```bash
# Check if backend is actually running and healthy
docker exec <container> curl -f http://localhost:3000/health

# Add health checks
labels:
  - "traefik.http.services.app.loadbalancer.healthcheck.path=/health"
  - "traefik.http.services.app.loadbalancer.healthcheck.interval=5s"
```

**Cause 3: HTTPS backend but HTTP URL**

```yaml
# If backend uses TLS internally
http:
  services:
    app:
      loadBalancer:
        servers:
          - url: "https://backend:8443"    # Use https:// not http://
        serversTransport: skip-verify
  serversTransports:
    skip-verify:
      insecureSkipVerify: true    # Only for internal/dev
```

**Cause 4: DNS resolution failure (Docker service names)**

```bash
# Verify DNS inside Traefik container
docker exec traefik nslookup myapp
# If failing, ensure containers are on the same Docker network
```

### 503 Service Unavailable

**Symptoms:** Intermittent or persistent 503 errors.

**Cause 1: All backends down**

```bash
# Check service health in Traefik
curl -s http://localhost:8080/api/http/services | jq '.[] | {name: .name, status: .status}'
```

**Cause 2: Circuit breaker tripped**

```yaml
# Check if circuit breaker is configured and triggering
http:
  middlewares:
    cb:
      circuitBreaker:
        expression: "ResponseCodeRatio(500, 600, 0, 600) > 0.25"
        checkPeriod: 10s
        fallbackDuration: 30s    # 503 for 30s after tripping
```

```bash
# Monitor via metrics
curl -s http://localhost:8082/metrics | grep circuit
```

**Cause 3: Max connections reached**

```yaml
# Increase transport limits
serversTransports:
  default:
    maxIdleConnsPerHost: 200    # default is 2!
    forwardingTimeouts:
      dialTimeout: 30s
      responseHeaderTimeout: 30s
```

### 504 Gateway Timeout

**Cause: Slow backend exceeding timeout**

```yaml
# Increase timeouts
serversTransports:
  slow-backend:
    forwardingTimeouts:
      dialTimeout: 60s
      responseHeaderTimeout: 120s
      idleConnTimeout: 300s

# Apply to specific service
http:
  services:
    slow-api:
      loadBalancer:
        servers:
          - url: "http://slow-backend:8080"
        serversTransport: slow-backend
```

### 429 Too Many Requests

**Expected when rate limiting is working.** But if unexpected:

```bash
# Check which rate limit middleware is applying
curl -s http://localhost:8080/api/http/middlewares | jq '.[] | select(.type == "rateLimit")'

# Verify sourceCriterion — might be rate-limiting all traffic as one source
```

```yaml
# Fix: Use proper source identification
http:
  middlewares:
    rate-limit:
      rateLimit:
        average: 100
        burst: 200
        sourceCriterion:
          ipStrategy:
            depth: 1             # Use X-Forwarded-For behind proxy
          # OR
          requestHeaderName: "X-API-Key"
          # OR
          requestHost: true
```

---

## TLS and Certificate Issues

### Certificate Renewal Failures

**Symptom:** Certificates expire, ACME errors in logs.

**Check 1: `acme.json` permissions**

```bash
# Must be 600
ls -la /data/acme.json
chmod 600 /data/acme.json

# Must not be a directory
file /data/acme.json
```

**Check 2: Port reachability for HTTP-01 challenge**

```bash
# Let's Encrypt needs to reach port 80 from the internet
curl -v http://your-domain.com/.well-known/acme-challenge/test

# Common blockers:
# - Firewall rules blocking port 80
# - Cloud load balancer not forwarding port 80
# - HTTP→HTTPS redirect breaking the challenge path
```

**Check 3: DNS for DNS-01 challenge**

```bash
# Verify DNS API credentials
# Cloudflare example:
curl -H "Authorization: Bearer $CF_DNS_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones" | jq '.result[].name'

# Check TXT record propagation
dig -t TXT _acme-challenge.example.com @1.1.1.1
```

**Check 4: Rate limits**

```
# Let's Encrypt rate limits:
# - 50 certificates per registered domain per week
# - 5 duplicate certificates per week
# - 300 new orders per account per 3 hours
# Use staging server for testing!
```

```yaml
certificatesResolvers:
  le-staging:
    acme:
      caServer: "https://acme-staging-v02.api.letsencrypt.org/directory"
      email: admin@example.com
      storage: /data/acme-staging.json
      httpChallenge:
        entryPoint: web
```

**Check 5: Entrypoint redirect conflicts**

```yaml
# Problem: HTTP→HTTPS redirect intercepts ACME challenge
entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
          # Fix: Traefik v3 handles this automatically,
          # but verify the challenge router has higher priority
```

### TLS Handshake Errors

```bash
# Test TLS connection
openssl s_client -connect example.com:443 -servername example.com 2>&1 | head -20

# Check certificate chain
openssl s_client -connect example.com:443 -servername example.com 2>&1 | openssl x509 -noout -dates -subject

# Test specific TLS version
openssl s_client -connect example.com:443 -tls1_2
openssl s_client -connect example.com:443 -tls1_3
```

**Fix: Set explicit TLS options**

```yaml
tls:
  options:
    default:
      minVersion: VersionTLS12
      cipherSuites:
        - TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
        - TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
        - TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256
      curvePreferences:
        - CurveP521
        - CurveP384
      sniStrict: true
```

### Mixed TLS Versions

```yaml
tls:
  options:
    # Strict for public endpoints
    modern:
      minVersion: VersionTLS13
    # Relaxed for legacy clients
    legacy:
      minVersion: VersionTLS12
      maxVersion: VersionTLS12

# Apply per-router
http:
  routers:
    public-api:
      tls:
        options: modern
    legacy-client:
      tls:
        options: legacy
```

---

## Docker Provider Issues

### Docker Socket Security

The Docker socket grants **root-level access** to the host. Mitigate:

**Option 1: Read-only mount (minimum)**

```yaml
volumes:
  - /var/run/docker.sock:/var/run/docker.sock:ro
```

**Option 2: Docker socket proxy (recommended)**

```yaml
services:
  docker-proxy:
    image: tecnativa/docker-socket-proxy:latest
    environment:
      CONTAINERS: 1
      SERVICES: 1
      TASKS: 1
      NETWORKS: 1
      # Block dangerous operations
      POST: 0
      BUILD: 0
      COMMIT: 0
      CONFIGS: 0
      SECRETS: 0
      EXEC: 0
      IMAGES: 0
      VOLUMES: 0
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks: [proxy-internal]

  traefik:
    image: traefik:v3.2
    # NO docker.sock mount
    environment:
      - TRAEFIK_PROVIDERS_DOCKER_ENDPOINT=tcp://docker-proxy:2375
    depends_on: [docker-proxy]
    networks: [proxy, proxy-internal]

networks:
  proxy-internal:
    internal: true    # No external access
```

**Option 3: `no-new-privileges` security opt**

```yaml
services:
  traefik:
    security_opt:
      - no-new-privileges:true
    read_only: true
    tmpfs:
      - /tmp
```

### Container Discovery Problems

```bash
# Container being skipped? Check:
# 1. Is it running?
docker ps --filter "name=myapp"

# 2. Does it have traefik.enable=true?
docker inspect myapp | jq '.[0].Config.Labels'

# 3. Is it on the right network?
docker network inspect proxy | jq '.[0].Containers'

# 4. Is the port label correct?
docker inspect myapp | jq '.[0].Config.ExposedPorts'
```

**Docker Compose label escaping:**

```yaml
# Dollar signs must be doubled in docker-compose labels
labels:
  - "traefik.http.middlewares.auth.basicauth.users=admin:$$apr1$$xyz$$hash"
  #                                                       ^^ ^^ ^^ doubled
```

### Network Connectivity

```bash
# Test connectivity from Traefik to backend
docker exec traefik wget -qO- http://myapp:8080/health

# If DNS fails, check network membership
docker network ls
docker network inspect proxy

# Recreate network if corrupt
docker network rm proxy
docker network create proxy
# Then restart all containers
```

---

## Provider Conflicts

When multiple providers define the same router/service name, the last one wins
(undefined order). Avoid by:

1. **Use unique names per provider:**

```yaml
# File provider: prefix with "file-"
http:
  routers:
    file-app:
      rule: "Host(`app.example.com`)"

# Docker labels: automatically namespaced with @docker
```

2. **Disable overlapping providers:**

```yaml
providers:
  docker:
    exposedByDefault: false
    constraints: "Label(`traefik.zone`, `docker`)"
  file:
    directory: "/etc/traefik/dynamic"
```

3. **Provider priority:** If both Docker and File define `myapp`, the behavior is
undefined. Always use `@provider` suffix when referencing cross-provider:

```yaml
middlewares:
  - "secure-headers@file"       # explicitly from file provider
  - "rate-limit@docker"         # explicitly from docker provider
```

---

## Middleware Issues

### Middleware Ordering Problems

Middleware executes in the order listed. Wrong order causes subtle bugs:

```yaml
# WRONG: Auth after stripPrefix — auth service sees stripped path
middlewares: [strip-prefix, auth, headers]

# CORRECT: Auth sees original path, strip happens after
middlewares: [auth, strip-prefix, headers]
```

**Common ordering issues:**

| Symptom | Likely Cause |
|---------|-------------|
| Auth always fails | stripPrefix before forwardAuth changes the path |
| CORS headers missing | headers middleware after a middleware that short-circuits |
| Redirect loop | redirectScheme + redirectRegex conflicting |
| Rate limit not per-user | rateLimit before forwardAuth (no user identity yet) |

### ForwardAuth Failures

```bash
# Test auth service directly
curl -v http://auth-service:4181/auth

# Check headers being forwarded
curl -v -H "Authorization: Bearer token" https://app.example.com/protected
```

**Common ForwardAuth issues:**

```yaml
http:
  middlewares:
    auth:
      forwardAuth:
        address: "http://auth-service:4181/auth"
        trustForwardHeader: true
        # Problem 1: Auth service not receiving needed headers
        authRequestHeaders:
          - "Authorization"
          - "Cookie"
          - "X-Forwarded-For"    # Include if auth checks IP
        # Problem 2: Auth response headers not passed to backend
        authResponseHeaders:
          - "X-User-Id"
          - "X-User-Role"
```

### Rate Limiting Misbehavior

**All users share one bucket:**

```yaml
# Problem: No sourceCriterion — all traffic shares one bucket
rate-limit:
  rateLimit:
    average: 100

# Fix: Rate limit per source IP
rate-limit:
  rateLimit:
    average: 100
    sourceCriterion:
      ipStrategy:
        depth: 1    # Behind 1 proxy (e.g., CloudFlare)
```

**Behind multiple proxies:**

```yaml
# depth=2 when behind 2 proxies (CDN + LB)
sourceCriterion:
  ipStrategy:
    depth: 2
    excludedIPs:
      - "10.0.0.0/8"    # Exclude internal proxy IPs
```

---

## WebSocket Connection Drops

**Symptom:** WebSocket connects then drops after ~60 seconds.

**Cause 1: Idle timeout too low**

```yaml
# Increase transport timeouts
entryPoints:
  websecure:
    address: ":443"
    transport:
      respondingTimeouts:
        readTimeout: 0     # 0 = no timeout (needed for long-lived WS)
        writeTimeout: 0
        idleTimeout: 300s  # 5 minutes
```

**Cause 2: Load balancer / CDN timeout**

- AWS ALB: default 60s idle timeout → increase to 3600s.
- CloudFlare: 100s WebSocket timeout (not configurable on free plan).
- Nginx in front of Traefik: `proxy_read_timeout 3600s;`.

**Cause 3: Missing sticky sessions for scaled backends**

```yaml
http:
  services:
    ws-service:
      loadBalancer:
        sticky:
          cookie:
            name: ws_session
            secure: true
            httpOnly: true
        servers:
          - url: "http://ws-backend-1:8080"
          - url: "http://ws-backend-2:8080"
```

**Cause 4: Retry middleware interfering**

```yaml
# Retry middleware can break WebSocket upgrades
# Either exclude WS routes from retry or disable retry for WS
http:
  routers:
    ws:
      rule: "Host(`ws.example.com`)"
      middlewares: []    # No retry middleware for WebSocket routes
```

**Verify WebSocket works:**

```bash
# Test WebSocket connection
websocat ws://app.example.com/ws

# Or with curl
curl -v \
  -H "Connection: Upgrade" \
  -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" \
  -H "Sec-WebSocket-Key: $(openssl rand -base64 16)" \
  https://app.example.com/ws
```

---

## Performance and Memory

### Memory Usage Investigation

```bash
# Check Traefik memory usage
docker stats traefik --no-stream

# Common memory hogs:
# 1. Access logs buffering — reduce bufferingSize or disable
# 2. Large number of routes (>10k) — increase memory limits
# 3. Metrics cardinality — disable addRoutersLabels if >1k routers
# 4. acme.json with many certificates
```

### Reducing Memory Footprint

```yaml
# Reduce access log buffering
accessLog:
  bufferingSize: 0           # Flush immediately (higher I/O)
  filters:
    statusCodes: ["400-599"]  # Only log errors

# Reduce metrics cardinality
metrics:
  prometheus:
    addRoutersLabels: false   # Disable if many routers
    addServicesLabels: true
    buckets: [0.1, 0.3, 1.2, 5.0]  # Fewer histogram buckets
```

### Connection Pool Tuning

```yaml
serversTransports:
  default:
    maxIdleConnsPerHost: 200  # Default 2 is too low for production
    forwardingTimeouts:
      dialTimeout: 30s
      responseHeaderTimeout: 0    # 0 = no timeout

entryPoints:
  websecure:
    transport:
      lifeCycle:
        requestAcceptGraceTimeout: 10s
        graceTimeOut: 30s
      respondingTimeouts:
        readTimeout: 60s
        writeTimeout: 60s
        idleTimeout: 180s
```

### High Traffic Optimization

```yaml
# Increase entrypoint connection limits
entryPoints:
  websecure:
    address: ":443"
    http:
      maxHeaderBytes: 1048576
    transport:
      respondingTimeouts:
        readTimeout: 30s

# Kernel tuning (host)
# sysctl -w net.core.somaxconn=65535
# sysctl -w net.ipv4.tcp_max_syn_backlog=65535
# sysctl -w net.ipv4.ip_local_port_range="1024 65535"
# ulimit -n 1048576
```

---

## Log Analysis

### Access Log Fields

```yaml
accessLog:
  filePath: "/var/log/traefik/access.log"
  format: json
  fields:
    defaultMode: keep
    names:
      ClientUsername: drop
    headers:
      defaultMode: drop
      names:
        User-Agent: keep
        Authorization: redact
        X-Forwarded-For: keep
```

### Useful Log Queries

```bash
# Find slow requests (>2s)
cat access.log | jq 'select(.Duration > 2000000000) | {time: .StartUTC, path: .RequestPath, duration_ms: (.Duration / 1000000), status: .DownstreamStatus}'

# Count errors by status code
cat access.log | jq '.DownstreamStatus' | sort | uniq -c | sort -rn

# Find 502 errors with backend info
cat access.log | jq 'select(.DownstreamStatus == 502) | {time: .StartUTC, path: .RequestPath, service: .ServiceName, backend: .ServiceAddr}'

# Top requested paths
cat access.log | jq -r '.RequestPath' | sort | uniq -c | sort -rn | head -20

# Requests per second over time
cat access.log | jq -r '.StartUTC[:19]' | uniq -c

# Identify rate-limited clients
cat access.log | jq 'select(.DownstreamStatus == 429) | .ClientAddr' | sort | uniq -c | sort -rn
```

### Structured Logging

```yaml
log:
  level: INFO
  format: json      # Structured JSON for log aggregation
  filePath: "/var/log/traefik/traefik.log"
```

---

## Debug Mode

### Enabling Debug Logging

```yaml
# Method 1: traefik.yml
log:
  level: DEBUG

# Method 2: CLI flag
# --log.level=DEBUG

# Method 3: Environment variable
# TRAEFIK_LOG_LEVEL=DEBUG
```

### Debug Checklist

```bash
# 1. Enable debug logging and watch for specific issues
docker logs traefik -f 2>&1 | grep -E "(error|warning|level=debug.*router)"

# 2. Inspect registered configuration via API
curl -s http://localhost:8080/api/rawdata | jq .

# 3. Check entrypoints
curl -s http://localhost:8080/api/entrypoints | jq .

# 4. Verify specific router
curl -s http://localhost:8080/api/http/routers/myapp@docker | jq .

# 5. Check middleware resolution
curl -s http://localhost:8080/api/http/middlewares | jq '.[].name'

# 6. Test with a simple curl (bypass DNS issues)
curl -v -H "Host: app.example.com" http://localhost/

# 7. Check if Traefik can reach backend
docker exec traefik wget -qO- --timeout=5 http://backend:8080/health
```

### API Endpoints Reference

| Endpoint | Description |
|----------|-------------|
| `GET /api/overview` | Global stats, providers, features |
| `GET /api/entrypoints` | All entrypoints with addresses |
| `GET /api/http/routers` | All HTTP routers |
| `GET /api/http/routers/{name}` | Specific router details |
| `GET /api/http/services` | All HTTP services with server status |
| `GET /api/http/services/{name}` | Specific service details |
| `GET /api/http/middlewares` | All HTTP middlewares |
| `GET /api/tcp/routers` | All TCP routers |
| `GET /api/tcp/services` | All TCP services |
| `GET /api/udp/routers` | All UDP routers |
| `GET /api/udp/services` | All UDP services |
| `GET /api/rawdata` | Full raw configuration dump |

---

## Health Checks

### Backend Health Checks

```yaml
http:
  services:
    app:
      loadBalancer:
        healthCheck:
          path: /health
          interval: 10s
          timeout: 3s
          hostname: "internal-health.example.com"
          headers:
            X-Health-Check: "traefik"
          followRedirects: false
          scheme: http       # or https
          mode: http         # or grpc
        servers:
          - url: "http://backend1:8080"
          - url: "http://backend2:8080"
```

**Health check failure behavior:**
- Failing server removed from pool immediately.
- Once healthy again, server is re-added automatically.
- If ALL servers fail, Traefik returns 503.

### Traefik's Own Health

```yaml
# Traefik ping endpoint for orchestrator health checks
ping:
  entryPoint: ping
  terminatingStatusCode: 503

entryPoints:
  ping:
    address: ":8082"
```

```yaml
# Docker healthcheck
services:
  traefik:
    healthcheck:
      test: ["CMD", "traefik", "healthcheck", "--ping"]
      interval: 10s
      timeout: 5s
      retries: 3
```

---

## Kubernetes-Specific Issues

### IngressRoute Not Working

```bash
# Check CRDs are installed
kubectl get crds | grep traefik

# Verify IngressRoute is created
kubectl get ingressroute -A

# Check Traefik logs for CRD errors
kubectl logs -n traefik deployment/traefik -f | grep -i error

# Verify RBAC — Traefik needs ClusterRole permissions
kubectl get clusterrole traefik -o yaml
```

### Service Not Discovered

```bash
# Check endpoints exist (pods are ready)
kubectl get endpoints myapp-svc

# Verify namespace — Traefik watches specific namespaces
kubectl get deployment traefik -n traefik -o yaml | grep -A5 namespaces

# Enable all namespaces
# In Helm values: providers.kubernetesCRD.allowCrossNamespace: true
```

### Multiple Traefik Instances (IngressClass)

```yaml
# Assign IngressClass to avoid conflicts
# Helm values:
ingressClass:
  name: traefik-internal
  isDefaultClass: false

# IngressRoute must reference:
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  annotations:
    kubernetes.io/ingress.class: traefik-internal
```

---

## Quick Reference Checklist

### Deployment Health Check

```
□ Traefik container running and healthy
□ Docker socket accessible (or socket proxy running)
□ Entrypoints listening (ports published)
□ Provider connected (Docker/K8s/File)
□ acme.json exists with correct permissions (600)
□ Dashboard accessible (if enabled)
□ Metrics endpoint responding
□ Access logs writing
```

### New Service Checklist

```
□ Container on shared network with Traefik
□ traefik.enable=true label present
□ Router rule matches expected Host/Path
□ Correct entrypoints specified
□ TLS certresolver configured
□ loadbalancer.server.port matches container port
□ Middleware references use correct @provider suffix
□ Health check configured on service
□ Test: curl -H "Host: app.example.com" http://localhost/
```

### Certificate Checklist

```
□ acme.json file permissions: 600
□ Email address valid
□ Challenge port reachable (80 for HTTP-01, 443 for TLS-ALPN-01)
□ DNS API credentials valid (for DNS-01)
□ Not hitting Let's Encrypt rate limits
□ Using staging server for testing
□ Domain resolves to Traefik's IP
□ No firewall blocking challenge
```
