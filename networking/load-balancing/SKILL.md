---
name: load-balancing
description: >
  Guide for load balancing architecture and configuration. Use when: configuring load balancers,
  Nginx upstream blocks, HAProxy frontends/backends, AWS ALB/NLB/CLB, GCP/Azure LBs, round robin,
  weighted round robin, least connections, IP hash, consistent hashing, health checks, session
  affinity, sticky sessions, reverse proxy setup, SSL termination, connection draining, rate
  limiting at LB layer, WebSocket/gRPC balancing, GSLB, or auto-scaling integration.
  Do NOT use for: single-server deployments without distribution needs, CDN caching configuration,
  API gateway routing that does not involve load balancing, DNS-only failover without LB,
  service mesh sidecar traffic management (Istio/Linkerd), or firewall/WAF-only setups.
---

# Load Balancing Patterns

## L4 vs L7 Load Balancing

Use Layer 4 (transport) load balancing when operating on TCP/UDP connections without inspecting
application payloads. L4 is faster, lower latency, and protocol-agnostic. Use it for raw TCP
services, database connections, and high-throughput streaming.

Use Layer 7 (application) load balancing when routing decisions depend on HTTP headers, paths,
cookies, or host names. L7 enables content-based routing, header injection, URL rewrites, and
WAF integration. Use it for HTTP/HTTPS APIs, microservice routing, and WebSocket upgrades.

| Feature              | L4                        | L7                          |
|----------------------|---------------------------|-----------------------------|
| Protocols            | TCP, UDP                  | HTTP, HTTPS, gRPC, WS      |
| Routing granularity  | IP + port                 | Path, header, cookie, host  |
| TLS handling         | Passthrough or terminate  | Terminate + inspect         |
| Performance          | Higher throughput         | More CPU per request        |
| Use case             | DB, gaming, IoT           | APIs, web apps, microsvcs   |

## Load Balancing Algorithms

### Round Robin
Distribute requests sequentially across backends. Use for homogeneous server pools with
uniform request cost. Simple, stateless, zero overhead.

### Weighted Round Robin
Assign weights proportional to server capacity. Server with `weight=3` receives 3x traffic
vs `weight=1`. Use when backend servers have different CPU/memory specs.

### Least Connections
Route to the backend with fewest active connections. Requires real-time connection tracking.
Use when request durations vary significantly (file uploads, long-polling).

### IP Hash
Hash the client source IP to select a backend. Ensures the same client always hits the same
server. Use for basic session persistence without cookies. Breaks when clients share IPs (NAT).

### Consistent Hashing
Map keys to a hash ring so adding/removing servers displaces minimal sessions. Use for
caching layers, stateful services, and scenarios where backend pool changes frequently.

### Random with Two Choices (Power of Two)
Pick two random backends, route to the one with fewer connections. Provides near-optimal
distribution with minimal state. Use as a modern default for large backend pools.

## Nginx Load Balancing Configuration

### Basic upstream with health checks
```nginx
upstream app_backend {
    least_conn;
    server 10.0.1.10:8080 weight=3 max_fails=3 fail_timeout=30s;
    server 10.0.1.11:8080 weight=2 max_fails=3 fail_timeout=30s;
    server 10.0.1.12:8080 backup;
    keepalive 32;
}

server {
    listen 80;
    location / {
        proxy_pass http://app_backend;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_next_upstream error timeout http_502 http_503;
        proxy_connect_timeout 5s;
        proxy_read_timeout 60s;
    }
}
```

### IP hash for session persistence
```nginx
upstream sticky_backend {
    ip_hash;
    server 10.0.1.10:8080;
    server 10.0.1.11:8080;
}
```

### WebSocket proxying
```nginx
location /ws {
    proxy_pass http://app_backend;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_read_timeout 3600s;
}
```

### gRPC proxying
```nginx
upstream grpc_backend {
    server 10.0.1.10:50051;
    server 10.0.1.11:50051;
}

server {
    listen 443 ssl http2;
    location / {
        grpc_pass grpc://grpc_backend;
        grpc_set_header X-Real-IP $remote_addr;
    }
}
```

### Rate limiting
```nginx
limit_req_zone $binary_remote_addr zone=api:10m rate=10r/s;

location /api/ {
    limit_req zone=api burst=20 nodelay;
    proxy_pass http://app_backend;
}
```

## HAProxy Configuration

### Frontend with ACL-based routing
```haproxy
frontend http_front
    bind *:80
    bind *:443 ssl crt /etc/ssl/certs/site.pem

    acl is_api path_beg /api
    acl is_static path_beg /static /assets
    acl is_ws hdr(Upgrade) -i websocket

    http-request set-header X-Forwarded-Proto https if { ssl_fc }

    use_backend api_servers if is_api
    use_backend static_servers if is_static
    use_backend ws_servers if is_ws
    default_backend web_servers
```

### Backend with health checks and draining
```haproxy
backend api_servers
    balance leastconn
    option httpchk GET /healthz
    http-check expect status 200
    default-server inter 5s fall 3 rise 2 on-marked-down shutdown-sessions
    server api1 10.0.1.10:8080 check weight 3
    server api2 10.0.1.11:8080 check weight 2
    server api3 10.0.1.12:8080 check backup
```

### Rate limiting with stick tables
```haproxy
frontend http_front
    stick-table type ip size 100k expire 10m store http_req_rate(10s)
    tcp-request connection track-sc0 src
    acl rate_abuse sc_http_req_rate(0) gt 50
    http-request deny deny_status 429 if rate_abuse
```

### Cookie-based session persistence
```haproxy
backend web_servers
    balance roundrobin
    cookie SERVERID insert indirect nocache
    server web1 10.0.1.10:8080 check cookie w1
    server web2 10.0.1.11:8080 check cookie w2
```

### Stats and monitoring endpoint
```haproxy
listen stats
    bind *:8404
    stats enable
    stats uri /stats
    stats refresh 10s
    stats auth admin:securepass
```

## Cloud Load Balancers

### AWS
- **ALB (Application LB):** L7. Routes by path, host header, HTTP method, query string. Native
  WebSocket support. Integrates with WAF, Cognito. Use for HTTP/HTTPS workloads.
- **NLB (Network LB):** L4. Ultra-low latency, static IPs, preserves source IP. Handles
  millions of requests/sec. Use for TCP/UDP, gRPC, or when static IP is required.
- **CLB (Classic):** Legacy. Supports both L4/L7 but lacks advanced routing. Migrate to ALB/NLB.
- **Target groups:** Register EC2, IP, Lambda, or ALB. Set deregistration delay (default 300s)
  for connection draining. Configure health check path, interval, thresholds.

### GCP
- **External HTTP(S) LB:** Global L7 with Anycast IP, URL maps, CDN integration.
- **TCP/UDP LB:** Regional L4, supports connection draining and health checks.
- **Internal LB:** Private VPC traffic distribution.

### Azure
- **Application Gateway:** L7 with WAF, URL routing, cookie affinity, SSL offload.
- **Azure Load Balancer:** L4 for TCP/UDP with HA ports and cross-zone redundancy.
- **Front Door:** Global L7 with edge acceleration, WAF, and failover.

## Health Checks

### Active health checks
The LB periodically probes backends. Configure interval, timeout, and thresholds.

```
# Typical parameters
interval: 10s        # probe frequency
timeout: 5s          # max wait for response
healthy_threshold: 2 # consecutive passes to mark healthy
unhealthy_threshold: 3 # consecutive failures to mark unhealthy
```

Use TCP checks for L4 (port open). Use HTTP checks for L7 (return 200 on `/healthz`).
Implement a dedicated health endpoint that verifies database connectivity and critical
dependency availability — do not just return 200 unconditionally.

### Passive health checks
Monitor real traffic for errors. If a backend returns 5xx or connection resets N times
within a window, mark it unhealthy. Nginx uses `max_fails` + `fail_timeout`. HAProxy uses
`observe layer7` with `error-limit`.

Combine active + passive: active checks catch crashed processes, passive catches degraded
performance under real load.

## Session Persistence

### Sticky sessions (cookie-based)
Insert a cookie identifying the backend server. ALB uses `AWSALB` cookie. HAProxy uses
`cookie SERVERID insert`. Prefer cookie-based over IP-based for accuracy behind NAT/proxies.

### IP-based affinity
Hash source IP to select backend. Simpler but breaks with shared IPs or proxies. Use only
when cookies are unavailable (non-HTTP protocols, L4 balancing).

### Application-managed sessions
Store session state in Redis/Memcached. Any backend can serve any request. This is the
preferred approach for horizontally scaled systems — eliminates LB-level persistence complexity.

## SSL/TLS Termination vs Passthrough

**Termination at LB:** Decrypt TLS at the load balancer, forward plaintext to backends.
Enables L7 inspection, header injection, path routing. Offloads CPU from backends.
Re-encrypt to backends (TLS re-encryption) if internal network requires encryption.

**Passthrough:** Forward encrypted traffic directly to backends. LB cannot inspect content.
Use when end-to-end encryption is mandatory or backends must see the original TLS connection.

```nginx
# SSL termination at Nginx
server {
    listen 443 ssl;
    ssl_certificate /etc/ssl/cert.pem;
    ssl_certificate_key /etc/ssl/key.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    location / {
        proxy_pass http://app_backend;  # plaintext to backend
    }
}
```

## Connection Draining and Graceful Shutdown

When removing a backend from the pool (deploy, scale-in, maintenance):
1. Stop sending new connections to the server (mark as draining).
2. Allow in-flight requests to complete within a timeout window.
3. Remove the server after timeout or all connections close.

- **AWS ALB/NLB:** Set deregistration delay on target group (default 300s, tune to 30-60s
  for fast deploys).
- **Nginx:** Set `down` on server directive, reload config. Active connections finish.
- **HAProxy:** Use `set server <backend>/<server> state drain` via runtime API, or
  `on-marked-down shutdown-sessions` for immediate termination.

## Rate Limiting at the LB Layer

Apply rate limits at the LB to protect backends from abuse before traffic reaches application
servers. Use per-IP, per-path, or per-header limits.

Common thresholds by endpoint type:
- Public APIs: 100-1000 req/min per IP
- Auth endpoints: 10-20 req/min per IP
- Static assets: higher limits or no limit
- Webhooks: per-source token limits

## WebSocket and gRPC Load Balancing

**WebSocket:** Long-lived connections. Use least-connections algorithm. Ensure the LB does not
timeout idle connections (set read timeout to 3600s+). ALB natively supports WebSocket via
HTTP/1.1 upgrade.

**gRPC:** Multiplexed streams over HTTP/2. L7 LBs must support HTTP/2 to distribute individual
RPCs. With L4, a single TCP connection routes all RPCs to one backend — defeating load
distribution. Use ALB (with gRPC target group), Nginx `grpc_pass`, or Envoy for proper
per-RPC balancing.

## Global Server Load Balancing (GSLB)

Distribute traffic across geographic regions using DNS-based or anycast routing.

- **Latency-based:** Route to the region with lowest measured latency (AWS Route 53).
- **Geolocation:** Route based on client geographic location.
- **Failover:** Primary region serves all traffic; secondary activates on health check failure.
- **Weighted:** Split traffic across regions by percentage for gradual migration.

Combine GSLB with regional LBs: GSLB selects the region, regional ALB/NLB selects the server.

## Auto-Scaling Integration

Configure LBs to work with auto-scaling groups:
1. Register new instances automatically with target groups on scale-out.
2. Deregister with connection draining on scale-in.
3. Use health check status from LB as scaling signal (unhealthy instances get replaced).
4. Set slow-start on backends (Nginx `slow_start=30s`, HAProxy `slowstart 30s`) to avoid
   overwhelming newly launched instances.

### AWS ASG + ALB pattern
```
ASG → Target Group → ALB
- min: 2, max: 10, desired: 3
- scale-out at CPU > 70% sustained 5min
- scale-in at CPU < 30% sustained 15min
- health_check_grace_period: 300s
- deregistration_delay: 60s
```

## Monitoring and Metrics

Track these metrics at the LB layer:

| Metric                  | Alert threshold           | Indicates                      |
|-------------------------|---------------------------|--------------------------------|
| Request rate            | Baseline + 3σ             | Traffic spike or attack        |
| Error rate (5xx)        | > 1% of total             | Backend failures               |
| Latency p99             | > 2x baseline             | Backend degradation            |
| Active connections      | > 80% of max              | Capacity saturation            |
| Healthy host count      | < desired count           | Backend health issue           |
| Spillover count         | > 0                       | All backends at capacity       |
| SSL handshake errors    | Increasing trend          | Certificate or config issue    |

Export metrics to Prometheus, CloudWatch, or Datadog. Set up dashboards showing request
distribution per backend to detect imbalance.

## Common Pitfalls and Debugging

**Uneven distribution:** Check server weights, verify health checks pass on all backends,
confirm algorithm matches workload (least-conn for variable-duration requests).

**Connection timeouts:** Ensure LB idle timeout exceeds backend processing time. For
WebSockets, set to 3600s+. Match keep-alive settings between LB and backends.

**Health check flapping:** Increase thresholds (e.g., 3 failures before marking unhealthy).
Ensure health endpoint is lightweight and does not depend on external services that flap.

**Source IP lost:** Use `X-Forwarded-For` header (L7) or proxy protocol (L4). Configure
backends to read the correct header. NLB preserves source IP natively.

**Sticky session imbalance:** One server accumulates long-lived sessions. Set session TTL,
use application-managed sessions with Redis, or use cookie expiry to rebalance.

**gRPC not distributing:** Likely using L4 balancer with HTTP/2 — single connection carries
all streams to one backend. Switch to L7 with per-stream balancing.

**SSL errors after LB:** Verify certificate chain is complete (including intermediates).
Check that backend expects HTTP (not HTTPS) when TLS terminates at LB. Ensure
`X-Forwarded-Proto` is set so apps generate correct redirect URLs.

**Debugging checklist:**
1. Verify backend health: `curl -v http://backend:port/healthz` from LB network.
2. Check LB access logs for request distribution and error codes.
3. Test with a single backend to isolate LB vs application issues.
4. Use `tcpdump` or `ss` to verify connections reach backends.
5. Review LB metrics dashboard for connection counts and latency per backend.

## Additional Resources

### Reference Guides

- **[Advanced Patterns](references/advanced-patterns.md)** — Deep dive into consistent hashing
  with virtual nodes, power of two random choices, least-loaded with slow start, blue-green
  deployments, canary routing, request hedging, priority-based routing, circuit breaker
  integration, multi-region failover with GSLB, and sidecar vs centralized LB for microservices.

- **[Troubleshooting Guide](references/troubleshooting.md)** — Diagnosis and fixes for uneven
  distribution, health check flapping, connection timeout tuning, keep-alive misconfiguration,
  SSL/TLS handshake failures, WebSocket upgrade failures, gRPC balancing issues, client IP
  preservation (X-Forwarded-For, PROXY protocol), CORS with LBs, and log-based debugging.

### Scripts

- **[lb-health-check.sh](scripts/lb-health-check.sh)** — Health verification script that tests
  all backends, measures response time percentiles (p50/p90/p99), checks TLS certificates, and
  validates traffic distribution across the pool.
  ```bash
  ./scripts/lb-health-check.sh -l http://lb.example.com -b 10.0.1.10:8080,10.0.1.11:8080
  ```

- **[setup-haproxy.sh](scripts/setup-haproxy.sh)** — Automated HAProxy installation and
  configuration with frontend/backend setup, health checks, rate limiting, stats dashboard,
  and SSL support. Supports `--dry-run` for config generation without installation.
  ```bash
  ./scripts/setup-haproxy.sh --backends "10.0.1.10:8080,10.0.1.11:8080" --ssl-cert /path/to/cert.pem
  ```

### Configuration Assets

- **[nginx-lb.conf](assets/nginx-lb.conf)** — Production Nginx LB config with multiple upstream
  groups (app, API, WebSocket, gRPC), SSL termination, caching, rate limiting, CORS handling,
  security headers, and structured JSON logging.

- **[haproxy.cfg](assets/haproxy.cfg)** — Production HAProxy config with HTTPS frontend,
  ACL-based routing, multiple backends, stick-table rate limiting, gRPC support, connection
  draining, and stats dashboard.

- **[docker-compose.yml](assets/docker-compose.yml)** — Local demo environment with both Nginx
  and HAProxy LBs fronting three backend instances. Includes health checks and HAProxy stats
  dashboard for testing and experimentation.
<!-- tested: pass -->
