# Load Balancer Troubleshooting Guide

## Table of Contents

- [Uneven Distribution (Hot Backends)](#uneven-distribution-hot-backends)
- [Health Check Flapping](#health-check-flapping)
- [Connection Timeout Tuning](#connection-timeout-tuning)
- [Keep-Alive Misconfiguration](#keep-alive-misconfiguration)
- [SSL/TLS Handshake Failures](#ssltls-handshake-failures)
- [WebSocket Upgrade Failures](#websocket-upgrade-failures)
- [gRPC Load Balancing Issues](#grpc-load-balancing-issues)
- [Client IP Preservation](#client-ip-preservation)
- [CORS with Load Balancers](#cors-with-load-balancers)
- [Debugging with Access Logs](#debugging-with-access-logs)

---

## Uneven Distribution (Hot Backends)

### Symptoms

- One or more backends receive significantly more traffic than others.
- CPU/memory usage is asymmetric across backend instances.
- Latency is higher on overloaded backends while others are idle.

### Diagnosis

```bash
# Check HAProxy per-server stats
echo "show stat" | socat stdio /var/run/haproxy.sock | \
  awk -F, '{print $2, $8, $34}' | column -t
# Output: server_name current_sessions request_rate

# Check Nginx upstream response distribution (from access logs)
awk '{print $NF}' /var/log/nginx/access.log | sort | uniq -c | sort -rn | head
# Assumes $NF contains upstream_addr

# AWS ALB: Check target group metrics
aws cloudwatch get-metric-statistics \
  --namespace AWS/ApplicationELB \
  --metric-name RequestCountPerTarget \
  --dimensions Name=TargetGroup,Value=<tg-arn> \
  --period 300 --statistics Sum \
  --start-time "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%S)"
```

### Common Causes and Fixes

**1. Misconfigured weights**
```bash
# Verify weights in Nginx
nginx -T 2>/dev/null | grep -A5 'upstream'

# Verify weights in HAProxy
echo "show servers state" | socat stdio /var/run/haproxy.sock
```
Fix: Ensure weights reflect actual server capacity.

**2. Sticky sessions accumulating on one server**
Long-lived sessions pile up on a backend that was the initial target. Fix:
- Set session cookie TTL / max-age to force periodic rebalancing.
- Migrate to application-managed sessions (Redis) and remove LB stickiness.
- Use `cookie SERVERID insert indirect nocache maxlife 30m` in HAProxy.

**3. Wrong algorithm for the workload**
- Round robin with variable request durations → use `least_conn` instead.
- Large pool with no centralized state → use `random two least_conn`.

**4. Unequal health check status**
Some backends fail intermittent health checks, reducing the effective pool size.
Check health status:
```bash
echo "show servers state" | socat stdio /var/run/haproxy.sock
# Look for servers in DOWN or DRAIN state
```

**5. Connection reuse imbalance (HTTP/2)**
HTTP/2 multiplexes many requests on a single connection. If the LB uses L4 balancing,
a single connection carries all traffic to one backend.
Fix: Use L7 balancing that distributes per-stream, not per-connection.

---

## Health Check Flapping

### Symptoms

- Backend servers alternate rapidly between healthy and unhealthy states.
- Alerts fire repeatedly for the same server.
- Load distribution becomes unpredictable as servers enter/leave the pool.

### Diagnosis

```bash
# HAProxy: Watch health transitions in real time
tail -f /var/log/haproxy.log | grep -i "health\|UP\|DOWN"

# Nginx: Check error log for upstream health events
tail -f /var/log/nginx/error.log | grep -i "upstream\|peer"

# ALB: Check target health history
aws elbv2 describe-target-health \
  --target-group-arn <arn>
```

### Common Causes and Fixes

**1. Health endpoint is too expensive**

The health check endpoint performs database queries, external API calls, or heavy computation.
Under load, it times out.

Fix:
```python
# BAD: Health check queries the database
@app.get("/healthz")
def health():
    db.execute("SELECT 1")  # Slow under load
    return {"status": "ok"}

# GOOD: Lightweight liveness check
@app.get("/healthz")
def health():
    return {"status": "ok"}

# SEPARATE: Readiness check for deep validation
@app.get("/readyz")
def ready():
    try:
        db.execute("SELECT 1")
        redis.ping()
        return {"status": "ready"}
    except Exception:
        return Response(status_code=503)
```

**2. Thresholds too aggressive**

```
# Too aggressive: 1 failure = unhealthy
unhealthy_threshold: 1
interval: 2s

# Better: tolerate transient failures
unhealthy_threshold: 3
healthy_threshold: 2
interval: 10s
timeout: 5s
```

**3. Network instability between LB and backends**

Packet loss or jitter causes intermittent health check failures.

Fix:
- Increase timeout and failure thresholds.
- Use TCP health checks (more reliable) instead of HTTP if the issue is network-level.
- Check for MTU issues: `ping -M do -s 1472 <backend_ip>`.

**4. Backends under memory/CPU pressure**

The application is healthy but too slow to respond to health checks in time.

Fix:
- Increase health check timeout.
- Prioritize health check requests in the application.
- Scale up backend resources.

**5. DNS resolution issues for health check hostnames**

If health checks use hostnames that resolve intermittently:
```bash
# Use IP addresses directly in health check targets
# Or ensure DNS resolver is reliable and cached
```

---

## Connection Timeout Tuning

### Timeout Chain

```
Client → [connect_timeout] → LB → [proxy_connect_timeout] → Backend
                              LB ← [proxy_read_timeout]   ← Backend
Client ← [client_body_timeout] ← LB
```

Every timeout in the chain must be properly coordinated. The client's timeout must be ≥ LB
timeout, and the LB timeout must be ≥ backend processing time.

### Nginx Timeout Reference

```nginx
# Connection to backend
proxy_connect_timeout 5s;     # Time to establish TCP connection to upstream
proxy_send_timeout 30s;       # Time to transmit request to upstream
proxy_read_timeout 60s;       # Time to receive response from upstream

# Client-facing
client_body_timeout 30s;      # Time to receive client request body
client_header_timeout 10s;    # Time to receive client headers
send_timeout 30s;             # Time between two write operations to client

# Keep-alive
keepalive_timeout 65s;        # Keep-alive with client
proxy_http_version 1.1;       # Required for upstream keep-alive
proxy_set_header Connection "";
```

### HAProxy Timeout Reference

```haproxy
defaults
    timeout connect 5s          # TCP connection to backend
    timeout client 30s          # Inactivity timeout for client side
    timeout server 60s          # Inactivity timeout for server side
    timeout http-request 10s    # Time for complete HTTP request
    timeout http-keep-alive 5s  # Keep-alive between requests
    timeout queue 30s           # Time in backend queue waiting for a server
    timeout check 5s            # Health check response timeout
    timeout tunnel 3600s        # For WebSocket/tunnel connections
```

### Common Timeout Issues

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `504 Gateway Timeout` | `proxy_read_timeout` too low | Increase to match backend SLA |
| `502 Bad Gateway` | `proxy_connect_timeout` too low, backend overloaded | Check backend health, increase timeout |
| Connections piling up | `timeout server` too high | Reduce to match expected response time |
| Long-poll / SSE breaking | Default read timeout (60s) | Set `proxy_read_timeout 3600s` for long-poll paths |
| File uploads failing | `client_body_timeout` too low | Increase for upload endpoints |

### Per-Location Timeout Override (Nginx)

```nginx
location /api/fast {
    proxy_read_timeout 10s;
    proxy_pass http://app_backend;
}

location /api/reports {
    proxy_read_timeout 300s;    # Long-running reports
    proxy_pass http://app_backend;
}

location /api/upload {
    client_max_body_size 100M;
    client_body_timeout 120s;
    proxy_read_timeout 120s;
    proxy_pass http://app_backend;
}
```

---

## Keep-Alive Misconfiguration

### Problem

HTTP keep-alive allows multiple requests over a single TCP connection, reducing latency and
resource usage. Misconfiguration causes connections to drop unexpectedly, race conditions, or
resource leaks.

### The Race Condition

If the **backend** closes the keep-alive connection at the same moment the **LB** sends a new
request, the LB receives a TCP RST and returns a 502 to the client.

**Fix:** Set the backend's keep-alive timeout **longer** than the LB's upstream keep-alive timeout.

```
LB upstream keep-alive timeout:   60s
Backend keep-alive timeout:       75s  (must be > LB's)
```

### Nginx Keep-Alive to Upstream

```nginx
upstream app {
    server 10.0.1.10:8080;
    server 10.0.1.11:8080;
    keepalive 32;              # Max idle keep-alive connections to upstream
    keepalive_timeout 60s;     # Idle timeout for upstream connections
    keepalive_requests 1000;   # Max requests per keep-alive connection
}

server {
    location / {
        proxy_pass http://app;
        proxy_http_version 1.1;                  # Required for keep-alive
        proxy_set_header Connection "";           # Remove "close" header
    }
}
```

### HAProxy Keep-Alive

```haproxy
defaults
    option http-keep-alive          # Enable keep-alive (default in modern HAProxy)
    timeout http-keep-alive 10s     # Idle timeout between requests

backend app
    option httpchk GET /healthz
    http-reuse safe                 # Reuse connections to backends safely
    server app1 10.0.1.10:8080 check
```

### Checklist

- [ ] `proxy_http_version 1.1` is set (Nginx defaults to 1.0 for upstream).
- [ ] `Connection ""` header is set (prevents Nginx from sending `Connection: close`).
- [ ] `keepalive N` is configured in upstream block.
- [ ] Backend keep-alive timeout > LB upstream keep-alive timeout.
- [ ] `keepalive_requests` is set to prevent connection reuse exhaustion.
- [ ] Monitor `upstream_connect_time` to detect connection re-establishment overhead.

---

## SSL/TLS Handshake Failures

### Symptoms

- Clients receive `SSL handshake failure` or `ERR_SSL_PROTOCOL_ERROR`.
- Connection resets during TLS negotiation.
- Intermittent SSL errors under high load.

### Diagnosis

```bash
# Test TLS connection to the LB
openssl s_client -connect lb.example.com:443 -servername lb.example.com

# Check certificate chain
openssl s_client -connect lb.example.com:443 -showcerts 2>/dev/null | \
  openssl x509 -noout -dates -subject -issuer

# Test specific TLS version
openssl s_client -connect lb.example.com:443 -tls1_2
openssl s_client -connect lb.example.com:443 -tls1_3

# Check supported ciphers
nmap --script ssl-enum-ciphers -p 443 lb.example.com

# Verify certificate matches hostname
curl -vI https://lb.example.com 2>&1 | grep -i "ssl\|certificate\|CN"
```

### Common Causes and Fixes

**1. Incomplete certificate chain**

The LB presents the leaf certificate but not intermediate CAs.

```bash
# Verify chain completeness
openssl s_client -connect lb.example.com:443 2>&1 | grep "Verify return code"
# "Verify return code: 21 (unable to verify the first certificate)" = missing intermediates

# Fix: concatenate certs in correct order
cat server.crt intermediate.crt root.crt > fullchain.pem
```

**2. Certificate / hostname mismatch**

The CN or SAN in the certificate doesn't match the requested hostname.

```bash
# Check SAN entries
openssl x509 -in cert.pem -noout -text | grep -A1 "Subject Alternative Name"
```

**3. Expired certificate**

```bash
# Check expiry
openssl x509 -in cert.pem -noout -enddate
# Set up monitoring to alert 30 days before expiry
```

**4. TLS version mismatch**

Client requires TLS 1.3 but LB only supports TLS 1.2, or vice versa.

```nginx
# Nginx: support TLS 1.2 and 1.3
ssl_protocols TLSv1.2 TLSv1.3;
ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256';
ssl_prefer_server_ciphers on;
```

**5. SSL session cache / ticket issues**

Under high load, SSL session resumption failures cause full handshakes for every request.

```nginx
ssl_session_cache shared:SSL:50m;
ssl_session_timeout 1d;
ssl_session_tickets on;
```

**6. OCSP stapling failures**

```nginx
ssl_stapling on;
ssl_stapling_verify on;
ssl_trusted_certificate /etc/ssl/chain.pem;
resolver 8.8.8.8 8.8.4.4 valid=300s;
resolver_timeout 5s;
```

---

## WebSocket Upgrade Failures

### Symptoms

- WebSocket connections fail to establish (HTTP 400 or connection reset).
- WebSocket works initially but drops after idle period.
- Works with direct backend connection but fails through the LB.

### Diagnosis

```bash
# Test WebSocket through LB
curl -v -H "Upgrade: websocket" -H "Connection: Upgrade" \
  -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  -H "Sec-WebSocket-Version: 13" \
  http://lb.example.com/ws

# Test directly to backend (bypass LB)
curl -v -H "Upgrade: websocket" -H "Connection: Upgrade" \
  -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  -H "Sec-WebSocket-Version: 13" \
  http://10.0.1.10:8080/ws
```

### Common Causes and Fixes

**1. Missing Upgrade headers in proxy config**

```nginx
# REQUIRED for WebSocket proxying
location /ws {
    proxy_pass http://ws_backend;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
}
```

**2. Idle timeout kills WebSocket connections**

Default `proxy_read_timeout` is 60s. WebSocket connections idle between messages get killed.

```nginx
location /ws {
    proxy_read_timeout 3600s;    # 1 hour
    proxy_send_timeout 3600s;
    # Or implement application-level ping/pong
}
```

**3. HAProxy WebSocket configuration**

```haproxy
frontend http
    bind *:80
    acl is_ws hdr(Upgrade) -i websocket
    use_backend ws_servers if is_ws

backend ws_servers
    balance leastconn
    timeout tunnel 3600s         # Long-lived connection timeout
    server ws1 10.0.1.10:8080 check
```

**4. Connection header stripping by intermediate proxies**

Some CDNs or proxies strip the `Connection: Upgrade` header. Verify each proxy in the
chain passes the header through.

**5. AWS ALB WebSocket**

ALB natively supports WebSocket via HTTP/1.1 Upgrade. Ensure:
- Idle timeout is sufficient (default 60s, max 4000s).
- Target group protocol is HTTP (not HTTPS) if TLS terminates at ALB.
- Stickiness is enabled if WebSocket server is stateful.

---

## gRPC Load Balancing Issues

### The Core Problem

gRPC uses HTTP/2, which multiplexes multiple RPC calls over a **single TCP connection**. An
L4 load balancer sees one connection and routes all RPCs to the same backend, defeating load
distribution.

### Diagnosis

```bash
# Check if all gRPC calls hit one backend
grpcurl -plaintext lb:50051 list
# Monitor per-backend request distribution in LB metrics

# Verify L7 (HTTP/2) support
curl -v --http2 https://lb.example.com/
```

### Solutions

**1. Use an L7 load balancer that understands HTTP/2**

```nginx
# Nginx gRPC (L7 per-RPC balancing)
upstream grpc_backend {
    server 10.0.1.10:50051;
    server 10.0.1.11:50051;
    least_conn;
}

server {
    listen 443 ssl http2;
    location / {
        grpc_pass grpc://grpc_backend;
    }
}
```

**2. Client-side load balancing**

```go
// Go gRPC with round-robin client-side LB
conn, err := grpc.Dial(
    "dns:///grpc.example.com:50051",
    grpc.WithDefaultServiceConfig(`{"loadBalancingPolicy":"round_robin"}`),
)
```

**3. Envoy as gRPC proxy**

```yaml
clusters:
  - name: grpc_service
    connect_timeout: 5s
    type: STRICT_DNS
    lb_policy: ROUND_ROBIN
    typed_extension_protocol_options:
      envoy.extensions.upstreams.http.v3.HttpProtocolOptions:
        "@type": type.googleapis.com/envoy.extensions.upstreams.http.v3.HttpProtocolOptions
        explicit_http_config:
          http2_protocol_options:
            max_concurrent_streams: 100
    load_assignment:
      cluster_name: grpc_service
      endpoints:
        - lb_endpoints:
            - endpoint:
                address:
                  socket_address: { address: 10.0.1.10, port_value: 50051 }
            - endpoint:
                address:
                  socket_address: { address: 10.0.1.11, port_value: 50051 }
```

**4. AWS ALB for gRPC**

- Set target group protocol version to "gRPC".
- ALB performs per-RPC balancing automatically.
- Health check: use gRPC health checking protocol.

---

## Client IP Preservation

### The Problem

When traffic passes through a load balancer, the backend sees the LB's IP as the source
address instead of the real client IP.

### Solution 1: X-Forwarded-For Header (L7)

```nginx
# Nginx: add client IP to X-Forwarded-For
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-Proto $scheme;
```

Backend must read the correct header:

```python
# Python/Flask
from flask import request

def get_client_ip():
    # Trust X-Forwarded-For only from known proxies
    if request.headers.get('X-Forwarded-For'):
        # First IP is the original client
        return request.headers['X-Forwarded-For'].split(',')[0].strip()
    return request.remote_addr
```

**Security: Only trust X-Forwarded-For from known proxy IPs**

```nginx
# Nginx: set real IP from trusted proxies
set_real_ip_from 10.0.0.0/8;
set_real_ip_from 172.16.0.0/12;
real_ip_header X-Forwarded-For;
real_ip_recursive on;
```

### Solution 2: PROXY Protocol (L4)

For L4 load balancers that can't inject HTTP headers, PROXY protocol prepends a header to
the TCP stream with the original client IP.

```
PROXY TCP4 192.168.1.1 10.0.1.10 56789 8080\r\n
[actual TCP data follows]
```

**HAProxy sending PROXY protocol:**

```haproxy
backend app
    server app1 10.0.1.10:8080 check send-proxy-v2
```

**Nginx receiving PROXY protocol:**

```nginx
server {
    listen 80 proxy_protocol;
    set_real_ip_from 10.0.0.0/8;
    real_ip_header proxy_protocol;

    location / {
        proxy_set_header X-Real-IP $proxy_protocol_addr;
        proxy_pass http://app;
    }
}
```

### Solution 3: AWS NLB (Native Source IP Preservation)

NLB preserves the client source IP natively when targets are registered by instance ID.
When registered by IP address, enable PROXY protocol v2.

### Comparison

| Method           | Layer | Requires backend changes | Multi-hop support |
|------------------|-------|--------------------------|-------------------|
| X-Forwarded-For  | L7    | Read header              | Yes (append)      |
| PROXY Protocol   | L4    | Parse PROXY header       | First hop only    |
| NLB passthrough  | L4    | None                     | No                |

---

## CORS with Load Balancers

### Problem

Cross-Origin Resource Sharing (CORS) preflight requests (`OPTIONS`) may fail when:
- The LB doesn't forward `OPTIONS` requests to the backend.
- CORS headers are set inconsistently across multiple backends.
- The LB strips or overwrites CORS headers.

### Handling CORS at the LB Layer

It's often better to handle CORS at the LB to ensure consistency:

```nginx
# Nginx: Handle CORS at the LB
map $http_origin $cors_origin {
    "~^https://(www\.)?example\.com$" $http_origin;
    "~^https://app\.example\.com$"    $http_origin;
    default                           "";
}

server {
    listen 80;

    # Handle preflight at LB (don't forward to backend)
    if ($request_method = 'OPTIONS') {
        add_header 'Access-Control-Allow-Origin' $cors_origin always;
        add_header 'Access-Control-Allow-Methods' 'GET, POST, PUT, DELETE, OPTIONS' always;
        add_header 'Access-Control-Allow-Headers' 'Authorization, Content-Type, X-Requested-With' always;
        add_header 'Access-Control-Max-Age' 86400 always;
        add_header 'Content-Length' 0;
        return 204;
    }

    location / {
        proxy_pass http://app_backend;
        add_header 'Access-Control-Allow-Origin' $cors_origin always;
        add_header 'Access-Control-Allow-Credentials' 'true' always;
    }
}
```

### HAProxy CORS

```haproxy
frontend http
    bind *:80
    http-request set-var(txn.origin) req.hdr(Origin)

    # Respond to preflight directly
    acl is_options method OPTIONS
    http-request return status 204 \
        hdr Access-Control-Allow-Origin %[var(txn.origin)] \
        hdr Access-Control-Allow-Methods "GET,POST,PUT,DELETE,OPTIONS" \
        hdr Access-Control-Allow-Headers "Authorization,Content-Type" \
        hdr Access-Control-Max-Age "86400" \
        if is_options

    default_backend app

backend app
    http-response add-header Access-Control-Allow-Origin %[var(txn.origin)]
    server app1 10.0.1.10:8080 check
```

### Common Pitfalls

- **Wildcard origin with credentials**: `Access-Control-Allow-Origin: *` cannot be used with
  `Access-Control-Allow-Credentials: true`. Must echo the specific origin.
- **Missing `Vary: Origin`**: Caching layers may cache a response with one origin and serve
  it to requests from another origin. Add `Vary: Origin` header.
- **Duplicate headers**: If both LB and backend set CORS headers, the client receives
  duplicates which some browsers reject. Handle CORS at only one layer.

---

## Debugging with Access Logs

### Enable Detailed Access Logs

**Nginx:**

```nginx
log_format lb_debug '$remote_addr - $remote_user [$time_local] '
                    '"$request" $status $body_bytes_sent '
                    '"$http_referer" "$http_user_agent" '
                    'upstream=$upstream_addr '
                    'upstream_status=$upstream_status '
                    'upstream_response_time=$upstream_response_time '
                    'upstream_connect_time=$upstream_connect_time '
                    'request_time=$request_time '
                    'upstream_cache_status=$upstream_cache_status';

access_log /var/log/nginx/lb_access.log lb_debug;
```

**HAProxy:**

```haproxy
defaults
    log global
    option httplog
    log-format "%ci:%cp [%tr] %ft %b/%s %TR/%Tw/%Tc/%Tr/%Ta %ST %B %CC %CS %tsc %ac/%fc/%bc/%sc/%rc %sq/%bq %hr %hs %{+Q}r"

# Field reference:
# %ci     = client IP
# %cp     = client port
# %ft     = frontend name
# %b/%s   = backend/server name
# %TR     = time to receive full request
# %Tw     = time in queue
# %Tc     = time to connect to server
# %Tr     = server response time
# %Ta     = total active time
# %ST     = HTTP status code
```

### Log Analysis Recipes

```bash
# Find backends receiving the most traffic
awk -F'upstream=' '{print $2}' /var/log/nginx/lb_access.log | \
  awk '{print $1}' | sort | uniq -c | sort -rn

# Find slow requests (upstream response time > 5s)
awk -F'upstream_response_time=' '{print $2}' /var/log/nginx/lb_access.log | \
  awk '$1 > 5.0 {print $0}'

# Error rate per backend
awk -F'upstream=' '{split($2,a," "); print a[1]}' /var/log/nginx/lb_access.log | \
  awk -F'upstream_status=' '{print $1, $2}' | \
  grep -E '5[0-9]{2}' | sort | uniq -c | sort -rn

# Connection timeouts
grep "upstream timed out" /var/log/nginx/error.log | tail -20

# HAProxy: requests that spent time in queue
grep -E "Tw:[1-9]" /var/log/haproxy.log | tail -20

# Distribution of response times (percentiles)
awk -F'request_time=' '{print $2}' /var/log/nginx/lb_access.log | \
  awk '{print $1}' | sort -n | \
  awk '{a[NR]=$1} END {
    print "p50:", a[int(NR*0.5)];
    print "p90:", a[int(NR*0.9)];
    print "p99:", a[int(NR*0.99)];
    print "max:", a[NR]
  }'
```

### Real-Time Monitoring Commands

```bash
# Watch HAProxy stats in real time
watch -n 2 'echo "show stat" | socat stdio /var/run/haproxy.sock | \
  cut -d, -f1,2,5,8,18,34 | column -t -s,'

# Monitor Nginx active connections
watch -n 1 'curl -s http://localhost/nginx_status'

# Live tail with filtering
tail -f /var/log/nginx/lb_access.log | \
  awk -F'upstream_status=' '$2 ~ /^5/ {print "\033[31m" $0 "\033[0m"; next} {print}'
```

### Structured Logging for LB Debugging

For production systems, emit structured (JSON) logs for easy ingestion into ELK, Splunk, or
Datadog:

```nginx
log_format json_lb escape=json
  '{'
    '"timestamp":"$time_iso8601",'
    '"client_ip":"$remote_addr",'
    '"method":"$request_method",'
    '"uri":"$request_uri",'
    '"status":$status,'
    '"upstream_addr":"$upstream_addr",'
    '"upstream_status":"$upstream_status",'
    '"upstream_response_time":"$upstream_response_time",'
    '"request_time":"$request_time",'
    '"bytes_sent":$bytes_sent,'
    '"user_agent":"$http_user_agent",'
    '"x_forwarded_for":"$http_x_forwarded_for"'
  '}';

access_log /var/log/nginx/lb_access.json json_lb;
```

### Quick Debugging Checklist

1. **Is the request reaching the LB?** → Check LB access logs for the request.
2. **Is the LB forwarding to a backend?** → Check `upstream_addr` in logs.
3. **Which backend is it hitting?** → Look at `upstream_addr` field.
4. **Is the backend responding?** → Check `upstream_status` and `upstream_response_time`.
5. **Is the response correct?** → Compare `status` (LB response) vs `upstream_status`.
6. **Is distribution even?** → Aggregate `upstream_addr` across many requests.
7. **Are there timeouts?** → Look for `upstream_response_time` close to timeout value.
8. **Are health checks passing?** → Check LB health check logs or API.
