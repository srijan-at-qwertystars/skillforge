# Traefik Troubleshooting Guide

## Table of Contents

- [Certificate Provisioning Failures](#certificate-provisioning-failures)
- [Docker Socket Security](#docker-socket-security)
- [Label Precedence Conflicts](#label-precedence-conflicts)
- [Middleware Ordering](#middleware-ordering)
- [502/504 Errors with Backends](#502504-errors-with-backends)
- [Dashboard Access Issues](#dashboard-access-issues)
- [Hot Reload Not Working](#hot-reload-not-working)
- [Memory Leaks with Many Routes](#memory-leaks-with-many-routes)
- [Log Verbosity Tuning](#log-verbosity-tuning)
- [Kubernetes CRD Version Mismatches](#kubernetes-crd-version-mismatches)

---

## Certificate Provisioning Failures

### Symptom: ACME challenge fails, no certificate issued

**HTTP Challenge (TLS-ALPN or HTTP-01):**

1. **Port 80/443 not reachable.** Verify firewall/cloud security groups allow inbound traffic.
   ```bash
   # Test from outside
   curl -v http://your-domain.com/.well-known/acme-challenge/test
   ```

2. **Entrypoint misconfigured.** The `httpChallenge.entryPoint` must match an entrypoint listening on port 80:
   ```yaml
   # Correct
   entryPoints:
     web: { address: ":80" }
   certificatesResolvers:
     le:
       acme:
         httpChallenge:
           entryPoint: web   # Must match
   ```

3. **HTTP→HTTPS redirect blocking challenge.** If you redirect all HTTP traffic, Let's Encrypt cannot reach `/.well-known/acme-challenge/`. Use entrypoint-level redirect (Traefik handles this correctly) instead of middleware-level redirect.

4. **acme.json permissions.** File must be `chmod 600`:
   ```bash
   chmod 600 /letsencrypt/acme.json
   ls -la /letsencrypt/acme.json  # Should show -rw-------
   ```

**DNS Challenge:**

1. **API credentials missing or wrong.** Check environment variables for your provider:
   ```bash
   # Cloudflare example
   echo $CF_DNS_API_TOKEN  # Must be set
   ```

2. **DNS propagation delay.** Add resolvers and increase delay:
   ```yaml
   dnsChallenge:
     provider: cloudflare
     delayBeforeCheck: 30s
     resolvers: ["1.1.1.1:53", "8.8.8.8:53"]
   ```

3. **Wrong API token scope.** Cloudflare needs `Zone:DNS:Edit` and `Zone:Zone:Read` permissions.

**General:**

- **Rate limits hit.** Let's Encrypt allows 5 duplicate certificates per week. Check `acme.json` for existing certs. Use staging first:
  ```yaml
  caServer: "https://acme-staging-v02.api.letsencrypt.org/directory"
  ```

- **acme.json not persisted.** Mount as volume, not bind mount to a tmpfs. On restart, Traefik re-requests all certs without persistence.

### Diagnostic Commands

```bash
# Check acme.json content
cat /letsencrypt/acme.json | jq '.le.Certificates[].domain'

# Check Traefik logs for ACME errors
docker logs traefik 2>&1 | grep -i "acme\|certificate\|challenge"

# Test DNS challenge propagation
dig TXT _acme-challenge.example.com @1.1.1.1
```

---

## Docker Socket Security

### Problem: Mounting `/var/run/docker.sock` gives Traefik root-equivalent access

**Risk:** A container with Docker socket access can create privileged containers, read secrets, and escalate to host root.

### Mitigations

**1. Read-only mount (minimal protection):**
```yaml
volumes:
  - /var/run/docker.sock:/var/run/docker.sock:ro
```
Prevents writes via the volume path but Traefik still has full Docker API access.

**2. Docker Socket Proxy (recommended):**

Deploy [tecnativa/docker-socket-proxy](https://github.com/Tecnativa/docker-socket-proxy) to filter API calls:

```yaml
services:
  docker-socket-proxy:
    image: tecnativa/docker-socket-proxy
    environment:
      CONTAINERS: 1
      SERVICES: 1
      NETWORKS: 1
      TASKS: 1
      # Deny everything else
      POST: 0
      BUILD: 0
      COMMIT: 0
      CONFIGS: 0
      DISTRIBUTION: 0
      EXEC: 0
      IMAGES: 0
      INFO: 1
      PLUGINS: 0
      SECRETS: 0
      SWARM: 0
      SYSTEM: 0
      VOLUMES: 0
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks: [proxy-internal]

  traefik:
    image: traefik:v3.4
    depends_on: [docker-socket-proxy]
    # NO docker.sock volume mounted
    command:
      - "--providers.docker.endpoint=tcp://docker-socket-proxy:2375"
    networks: [proxy, proxy-internal]
```

**3. Security options:**
```yaml
services:
  traefik:
    security_opt:
      - no-new-privileges:true
    cap_drop: [ALL]
    cap_add: [NET_BIND_SERVICE]
    read_only: true
```

**4. Run as non-root (with `NET_BIND_SERVICE`):**
```yaml
services:
  traefik:
    user: "65534:65534"  # nobody
    cap_add: [NET_BIND_SERVICE]
```

---

## Label Precedence Conflicts

### Problem: Docker labels conflict or override each other

**Symptom:** Wrong middleware applied, routes not matching, services pointing to wrong backends.

### How Label Precedence Works

1. Labels are scoped by router/service/middleware **name** (the segment after `traefik.http.routers.`).
2. Multiple containers with the same router name **merge** labels — last writer wins (container creation order is non-deterministic).
3. Provider-scoped references: `middleware@docker`, `middleware@file`, `middleware@consulcatalog`.

### Common Conflicts

**Duplicate router names across services:**
```yaml
# Container A — BAD: both use router name "app"
labels:
  - "traefik.http.routers.app.rule=Host(`a.example.com`)"

# Container B — BAD: conflicts with Container A
labels:
  - "traefik.http.routers.app.rule=Host(`b.example.com`)"
```

**Fix:** Use unique router names per service:
```yaml
# Container A
labels:
  - "traefik.http.routers.app-a.rule=Host(`a.example.com`)"

# Container B
labels:
  - "traefik.http.routers.app-b.rule=Host(`b.example.com`)"
```

**Middleware name collisions:**
```yaml
# Two containers defining different "secure-headers" middleware
# Result: non-deterministic — whichever Traefik reads last wins
```

**Fix:** Define shared middleware in file provider and reference with `@file`:
```yaml
# /etc/traefik/dynamic/middlewares.yml
http:
  middlewares:
    secure-headers:
      headers:
        frameDeny: true
        # ... shared definition
```

```yaml
# Docker labels
labels:
  - "traefik.http.routers.app.middlewares=secure-headers@file"
```

### Debugging

```bash
# Check Traefik API for resolved configuration
curl -s http://traefik:8080/api/http/routers | jq '.[] | {name, rule, service}'
curl -s http://traefik:8080/api/http/middlewares | jq '.[] | {name, type, provider}'
```

---

## Middleware Ordering

### Problem: Middleware executes in wrong order, causing unexpected behavior

**Rule:** Middleware executes in the order listed on the router. The first middleware in the list processes the request first (and the response last).

```yaml
middlewares: [auth, rate-limit, compress]
# Request flow:  auth → rate-limit → compress → backend
# Response flow: backend → compress → rate-limit → auth
```

### Common Ordering Mistakes

**1. Rate limiting before auth:**
```yaml
# BAD: rate-limits unauthenticated requests, wastes capacity
middlewares: [rate-limit, auth]

# GOOD: reject unauthorized first, then rate-limit authenticated users
middlewares: [auth, rate-limit]
```

**2. StripPrefix after forwarding:**
```yaml
# BAD: backend receives /api/v1/users instead of /users
middlewares: [auth, compress, strip-prefix]

# GOOD: strip prefix before other middleware that inspects paths
middlewares: [strip-prefix, auth, compress]
```

**3. Compress before headers:**
```yaml
# BAD: security headers may not apply to compressed responses correctly
middlewares: [compress, security-headers]

# GOOD: headers set first, compress wraps everything
middlewares: [security-headers, compress]
```

**4. ForwardAuth and headers:**
```yaml
# GOOD: ForwardAuth first, its response headers propagated
middlewares: [forward-auth, security-headers, rate-limit]
```

### Recommended Order

```yaml
middlewares:
  - ip-allow-list     # Block disallowed IPs first
  - forward-auth      # Authentication
  - rate-limit         # Throttle authenticated requests
  - strip-prefix       # Path manipulation
  - security-headers   # Add security headers
  - compress           # Compress last (wraps response)
```

### Using Chain Middleware

Group ordering into reusable chains:

```yaml
http:
  middlewares:
    standard-chain:
      chain:
        middlewares:
          - security-headers
          - rate-limit
          - compress
```

---

## 502/504 Errors with Backends

### 502 Bad Gateway

**Causes:**

1. **Backend not running or crashed.**
   ```bash
   docker ps | grep backend-name
   curl -v http://backend:port/healthz
   ```

2. **Wrong service port.** Traefik connects to the wrong port:
   ```yaml
   # Docker label — must match the port the app actually listens on
   - "traefik.http.services.app.loadbalancer.server.port=8080"
   ```

3. **Network mismatch.** Backend on different Docker network than Traefik:
   ```yaml
   # Both must share a network
   networks:
     proxy:
       name: proxy
   ```

4. **Container IP resolution.** Multi-network containers — Traefik picks the wrong IP:
   ```yaml
   providers:
     docker:
       network: proxy   # Specify which network to use
   ```

5. **Backend using HTTPS.** Traefik defaults to HTTP for backends:
   ```yaml
   - "traefik.http.services.app.loadbalancer.server.scheme=https"
   ```

6. **Self-signed backend certificates.** Configure `ServersTransport`:
   ```yaml
   http:
     serversTransports:
       skip-verify:
         insecureSkipVerify: true
     services:
       app:
         loadBalancer:
           serversTransport: skip-verify
   ```

### 504 Gateway Timeout

**Causes:**

1. **Slow backend.** Increase `respondingTimeouts`:
   ```yaml
   # Static config
   entryPoints:
     websecure:
       transport:
         respondingTimeouts:
           readTimeout: 60s
           writeTimeout: 60s
           idleTimeout: 180s
   ```

2. **Backend connection limits.** Check if backend connection pool is exhausted.

3. **DNS resolution.** Backend hostname not resolving. Check DNS or use IPs.

### Debugging

```bash
# Enable debug logging temporarily
docker exec traefik traefik --log.level=DEBUG  # Or set in static config

# Check Traefik service status via API
curl -s http://traefik:8080/api/http/services | jq '.[] | {name, status, serverStatus}'

# Test backend connectivity from Traefik container
docker exec traefik wget -q -O- http://backend:8080/healthz
```

---

## Dashboard Access Issues

### Problem: Cannot access Traefik dashboard

**1. Dashboard not enabled:**
```yaml
# Static config — required
api:
  dashboard: true
```

**2. Using `api.insecure` but port not exposed:**
```yaml
# Dev only — exposes on port 8080
api:
  insecure: true
# Ensure port 8080 is mapped
ports:
  - "8080:8080"
```

**3. Router misconfigured (production):**
```yaml
# Must use service api@internal
labels:
  - "traefik.http.routers.dashboard.service=api@internal"
  - "traefik.http.routers.dashboard.rule=Host(`traefik.example.com`)"
  - "traefik.http.routers.dashboard.entrypoints=websecure"
```

**4. Missing PathPrefix for API routes:**

The dashboard needs both the web UI and the API endpoint:
```yaml
labels:
  - "traefik.http.routers.dashboard.rule=Host(`traefik.example.com`) && (PathPrefix(`/api`) || PathPrefix(`/dashboard`))"
  - "traefik.http.routers.dashboard.service=api@internal"
```

**5. Auth middleware blocking:**

Verify credentials:
```bash
# Generate htpasswd entry
htpasswd -nB admin

# Test with curl
curl -u admin:password https://traefik.example.com/dashboard/
```

Note: The dashboard URL **must** end with a trailing slash: `/dashboard/` not `/dashboard`.

**6. DNS not pointing to Traefik:**
```bash
dig traefik.example.com
curl -H "Host: traefik.example.com" http://traefik-ip/dashboard/
```

---

## Hot Reload Not Working

### Problem: Changes to dynamic config not picked up

**1. File provider — `watch` not enabled:**
```yaml
providers:
  file:
    directory: /etc/traefik/dynamic
    watch: true   # Required for hot reload
```

**2. File not in watched directory:**

- If using `filename`, only that single file is watched.
- If using `directory`, all `.yml`/`.yaml`/`.toml` files in that directory are watched. Subdirectories are **not** watched.

**3. Volume mount issues (Docker):**

Bind mounts with some editors (vim, sed -i) replace the inode, breaking inotify:
```bash
# Check if the file inode changed
ls -i /etc/traefik/dynamic/config.yml
# Edit and check again — if inode changed, Traefik won't detect it
```

**Fix:** Use `directory` mode instead of `filename`, or use editors that write in-place (echo, tee). For bind mounts, mount the directory, not individual files.

**4. YAML syntax errors:**

Invalid YAML silently fails. Validate before applying:
```bash
# Validate YAML
python3 -c "import yaml; yaml.safe_load(open('config.yml'))"
# Or use yq
yq eval '.' config.yml > /dev/null
```

**5. Docker labels — container not restarted:**

Docker label changes require container recreation (not just restart):
```bash
docker compose up -d --force-recreate service-name
```

**6. Static config changes:**

Static configuration (entrypoints, providers, certificatesResolvers) **never** hot-reloads. Restart Traefik:
```bash
docker compose restart traefik
# Or for zero-downtime in Kubernetes:
kubectl rollout restart deployment/traefik
```

**7. Provider throttle:**
```yaml
providers:
  providersThrottleDuration: 2s  # Default. Reduce for faster updates in dev.
```

---

## Memory Leaks with Many Routes

### Problem: Traefik memory usage grows unboundedly

**1. Too many active certificates.**

Each certificate consumes memory. With thousands of domains:
- Use wildcard certificates where possible.
- Set `certificatesResolvers.*.acme.certificatesDuration` to manage renewal frequency.

**2. Access log buffering.**

Large `bufferingSize` without flushing:
```yaml
accessLog:
  bufferingSize: 100   # Keep reasonable, default 0 (unbuffered)
```

**3. Metrics cardinality explosion.**

`addRoutersLabels: true` with thousands of routers creates massive metric series:
```yaml
metrics:
  prometheus:
    addRoutersLabels: false   # Disable if >500 routes
    addServicesLabels: true
    addEntryPointsLabels: true
```

**4. Container resource limits:**
```yaml
services:
  traefik:
    deploy:
      resources:
        limits:
          memory: 512M
          cpus: "1.0"
        reservations:
          memory: 128M
```

**5. Go runtime tuning:**
```yaml
environment:
  - GOGC=100              # Default. Lower = more frequent GC, less memory
  - GOMEMLIMIT=450MiB     # Hard memory limit (Go 1.19+)
```

**6. Health check intervals.**

Aggressive health checks with many backends consume goroutines:
```yaml
healthCheck:
  interval: 30s   # Don't set below 10s with many backends
  timeout: 5s
```

### Monitoring Memory

```bash
# Check Traefik memory via metrics
curl -s http://traefik:8082/metrics | grep process_resident_memory_bytes

# Check container memory
docker stats traefik --no-stream --format "{{.MemUsage}}"

# Profile with pprof (if enabled)
curl -s http://traefik:8080/debug/pprof/heap > heap.prof
go tool pprof heap.prof
```

---

## Log Verbosity Tuning

### Log Levels

```yaml
# Static config
log:
  level: INFO   # TRACE, DEBUG, INFO, WARN, ERROR, FATAL, PANIC
  format: json  # common, json
  filePath: "/var/log/traefik/traefik.log"  # Omit for stdout
```

### Common Scenarios

**Debug routing issues (temporary):**
```yaml
log:
  level: DEBUG
```
⚠️ DEBUG is very verbose in production. Use temporarily and revert.

**Quiet production:**
```yaml
log:
  level: WARN
```

**Access logs — filter noise:**
```yaml
accessLog:
  format: json
  filters:
    statusCodes: ["400-599"]      # Only errors
    retryAttempts: true           # Only retried requests
    minDuration: 500ms            # Only slow requests
  fields:
    defaultMode: keep
    names:
      ClientHost: drop            # Remove noisy fields
      StartUTC: drop
    headers:
      defaultMode: drop
      names:
        User-Agent: keep
        Authorization: redact     # Mask sensitive headers
        X-Forwarded-For: keep
```

**Per-service access logs:**

Not supported natively. Filter externally:
```bash
# Filter JSON access logs by service
cat access.log | jq 'select(.ServiceName == "myapp@docker")'
```

### Dynamic Log Level Change

Traefik doesn't support dynamic log level changes. Restart required. In Kubernetes, use a ConfigMap and rolling restart.

---

## Kubernetes CRD Version Mismatches

### Problem: CRDs from different Traefik versions conflict

**Symptom:** Errors like `no matches for kind "IngressRoute" in version "traefik.io/v1alpha1"`, or middleware fields silently ignored.

### Diagnosis

```bash
# Check installed CRD versions
kubectl get crd | grep traefik

# Check CRD API versions
kubectl get crd ingressroutes.traefik.io -o jsonpath='{.spec.versions[*].name}'

# Check Traefik version
kubectl exec deploy/traefik -- traefik version
```

### Common Mismatches

**1. Old CRDs with new Traefik:**

Traefik v3 requires updated CRDs with `traefik.io` API group (not `traefik.containo.us`).

```bash
# Remove old CRDs
kubectl delete crd \
  ingressroutes.traefik.containo.us \
  middlewares.traefik.containo.us \
  tlsoptions.traefik.containo.us

# Install new CRDs
kubectl apply -f https://raw.githubusercontent.com/traefik/traefik/v3.4/docs/content/reference/dynamic-configuration/kubernetes-crd-definition-v1.yml
```

**2. Helm chart CRD management:**

Helm doesn't update CRDs on `helm upgrade`. Apply manually:
```bash
# Get CRDs from chart
helm pull traefik/traefik --untar
kubectl apply -f traefik/crds/

# Or directly from repo
helm show crds traefik/traefik | kubectl apply -f -
```

**3. Multiple Traefik versions in cluster:**

Different namespaces with different Traefik versions sharing cluster-scoped CRDs:

- CRDs are cluster-scoped — only one version can exist.
- All Traefik instances must be compatible with the installed CRD version.
- Upgrade all instances together, CRDs first.

### Migration v2 → v3 CRDs

```bash
# 1. Update CRDs
kubectl apply -f kubernetes-crd-definition-v1.yml

# 2. Update API group in all resources
# Change: traefik.containo.us/v1alpha1 → traefik.io/v1alpha1
find k8s/ -name '*.yml' -exec sed -i 's/traefik.containo.us/traefik.io/g' {} +

# 3. Check for removed/renamed fields
# ipWhiteList → ipAllowList
# stripPrefixRegex → use redirectRegex
grep -r 'ipWhiteList\|stripPrefixRegex' k8s/

# 4. Apply updated resources
kubectl apply -f k8s/
```

### Prevention

- Pin Traefik Helm chart version in `Chart.yaml` or values.
- Include CRD application in CI/CD pipeline before deploying Traefik.
- Use `kubectl diff` to preview CRD changes before applying.
- Document required CRD versions alongside Traefik version in deployment docs.
