# Nginx Troubleshooting Guide

## Table of Contents

- [Common HTTP Errors (502, 504, 413)](#common-http-errors-502-504-413)
- [Debugging with error_log Levels](#debugging-with-error_log-levels)
- [stub_status Monitoring](#stub_status-monitoring)
- [Request Tracing](#request-tracing)
- [Connection Limits](#connection-limits)
- [Buffer Tuning](#buffer-tuning)
- [proxy_pass Trailing Slash Pitfalls](#proxy_pass-trailing-slash-pitfalls)
- [DNS Resolution with resolver](#dns-resolution-with-resolver)
- [Upstream Keepalive Issues](#upstream-keepalive-issues)
- [Graceful Reload vs Restart](#graceful-reload-vs-restart)

---

## Common HTTP Errors (502, 504, 413)

### 502 Bad Gateway

**Meaning**: Nginx received an invalid response from the upstream server.

**Common Causes and Fixes**:

1. **Upstream is down or not listening**
   ```bash
   # Check if upstream is running
   curl -v http://127.0.0.1:8080/health
   ss -tlnp | grep 8080
   systemctl status myapp
   ```

2. **Socket permission denied (PHP-FPM, uWSGI)**
   ```bash
   # Check socket permissions
   ls -la /run/php/php-fpm.sock
   # Fix: ensure nginx user can access the socket
   # In php-fpm pool config:
   # listen.owner = www-data
   # listen.group = www-data
   # listen.mode = 0660
   ```

3. **Upstream response too large for buffers**
   ```nginx
   # Increase proxy buffers
   proxy_buffer_size 16k;
   proxy_buffers 8 16k;
   proxy_busy_buffers_size 32k;

   # For FastCGI
   fastcgi_buffer_size 16k;
   fastcgi_buffers 8 16k;
   ```

4. **SELinux blocking connections**
   ```bash
   # Check SELinux denials
   ausearch -m avc -ts recent | grep nginx
   # Allow nginx to connect to network
   setsebool -P httpd_can_network_connect 1
   ```

5. **Upstream timeout during startup**
   ```nginx
   proxy_connect_timeout 10s;   # increase from default 60s if upstream is slow to accept
   ```

### 504 Gateway Timeout

**Meaning**: Upstream did not respond within the configured timeout.

**Common Causes and Fixes**:

1. **Slow backend processing**
   ```nginx
   # Increase timeouts (default is 60s each)
   proxy_connect_timeout 10s;
   proxy_read_timeout 300s;     # for long-running requests
   proxy_send_timeout 120s;

   # For FastCGI
   fastcgi_read_timeout 300s;
   ```

2. **Upstream is overloaded**
   ```bash
   # Check upstream connections and load
   ss -s
   top -bn1 | head -20
   # Check nginx upstream response times in logs
   grep "upstream_response_time" /var/log/nginx/access.log | \
     awk '{print $NF}' | sort -rn | head -20
   ```

3. **Network issues between nginx and upstream**
   ```bash
   # Test connectivity
   curl -w "connect: %{time_connect}s\ntotal: %{time_total}s\n" \
     -o /dev/null -s http://upstream:8080/health
   # Check for packet loss
   mtr --report upstream-host
   ```

4. **DNS resolution delays** (see [DNS Resolution](#dns-resolution-with-resolver))

### 413 Request Entity Too Large

**Meaning**: Client sent a request body exceeding the allowed size.

```nginx
# Increase client body size limit (default is 1m)
http {
    client_max_body_size 100m;    # global default
}

server {
    # Per-server override
    client_max_body_size 50m;

    location /upload {
        client_max_body_size 500m;   # per-location override
        client_body_buffer_size 10m; # buffer in memory before writing to disk
        client_body_temp_path /var/nginx/client_temp 1 2;
    }

    location /api/ {
        client_max_body_size 10m;
    }
}
```

**Related: 414 Request-URI Too Large**
```nginx
# Increase URI/header buffer sizes
large_client_header_buffers 4 32k;   # default: 4 8k
client_header_buffer_size 4k;        # default: 1k
```

### Other Common Errors

**400 Bad Request — "Request Header Or Cookie Too Large"**
```nginx
large_client_header_buffers 8 32k;
```

**494 Request Header Too Large** (Nginx-specific)
```nginx
large_client_header_buffers 4 64k;
```

**495/496/497 SSL Errors**
```bash
# 495: SSL certificate error — client cert validation failed
# 496: No client certificate — client cert required but not sent
# 497: HTTP to HTTPS — client sent HTTP to an HTTPS port
openssl s_client -connect example.com:443 -servername example.com
```

---

## Debugging with error_log Levels

### Log Levels (least to most verbose)

```
emerg → alert → crit → error → warn → notice → info → debug
```

```nginx
# Production: warn or error
error_log /var/log/nginx/error.log warn;

# Staging/debugging: info or notice
error_log /var/log/nginx/error.log info;

# Full debug (requires --with-debug compile flag)
error_log /var/log/nginx/error.log debug;
```

### Check if Debug is Available

```bash
nginx -V 2>&1 | grep -- '--with-debug'
# If present, debug logging is available
```

### Targeted Debug Logging

```nginx
# Debug only specific client IPs (reduces log volume)
events {
    debug_connection 192.168.1.100;
    debug_connection 10.0.0.0/24;
}

# Debug specific server block only
server {
    error_log /var/log/nginx/debug-mysite.log debug;
    # ...
}
```

### Per-Location Error Logging

```nginx
server {
    error_log /var/log/nginx/error.log warn;

    location /api/ {
        error_log /var/log/nginx/api-debug.log info;
        proxy_pass http://backend;
    }
}
```

### Reading Debug Output

Key patterns in debug logs:
```
# Connection lifecycle
*1 ... client 192.168.1.100 connected to 0.0.0.0:80
*1 ... http process request line
*1 ... http request line: "GET /api/test HTTP/1.1"

# Upstream connection
*1 ... upstream: "http://10.0.0.1:8080/api/test"
*1 ... http upstream process header
*1 ... http upstream status 200

# Location matching
*1 ... test location: "/"
*1 ... test location: "api/"
*1 ... using configuration "=/api/"

# SSL handshake
*1 ... SSL: TLSv1.3, cipher: TLS_AES_256_GCM_SHA384
```

### Structured Error Logging

```nginx
# Log to syslog for centralized collection
error_log syslog:server=10.0.0.5:514,facility=local7,tag=nginx,severity=error;

# Log to multiple destinations
error_log /var/log/nginx/error.log warn;
error_log syslog:server=10.0.0.5:514 error;
```

---

## stub_status Monitoring

### Basic Setup

```nginx
server {
    listen 127.0.0.1:8080;

    location /nginx_status {
        stub_status;
        allow 127.0.0.1;
        allow 10.0.0.0/8;
        deny all;
    }
}
```

### Output Format

```
Active connections: 291
server accepts handled requests
 16630948 16630948 31070465
Reading: 6 Writing: 179 Waiting: 106
```

- **Active connections**: current client connections (including waiting)
- **accepts**: total accepted connections
- **handled**: total handled connections (should equal accepts; if less, worker_connections limit hit)
- **requests**: total client requests
- **Reading**: reading request headers
- **Writing**: writing response to client
- **Waiting**: keep-alive connections waiting for request (idle)

### Monitoring Script

```bash
#!/bin/bash
# Parse stub_status for Prometheus/monitoring
STATUS=$(curl -s http://127.0.0.1:8080/nginx_status)
ACTIVE=$(echo "$STATUS" | awk '/Active/{print $3}')
ACCEPTS=$(echo "$STATUS" | awk 'NR==3{print $1}')
HANDLED=$(echo "$STATUS" | awk 'NR==3{print $2}')
REQUESTS=$(echo "$STATUS" | awk 'NR==3{print $3}')
READING=$(echo "$STATUS" | awk '/Reading/{print $2}')
WRITING=$(echo "$STATUS" | awk '/Writing/{print $4}')
WAITING=$(echo "$STATUS" | awk '/Waiting/{print $6}')
DROPPED=$((ACCEPTS - HANDLED))

echo "nginx_active_connections $ACTIVE"
echo "nginx_accepts_total $ACCEPTS"
echo "nginx_handled_total $HANDLED"
echo "nginx_requests_total $REQUESTS"
echo "nginx_reading $READING"
echo "nginx_writing $WRITING"
echo "nginx_waiting $WAITING"
echo "nginx_dropped_total $DROPPED"
```

### Health Check Patterns

```nginx
# Simple health check
location = /health {
    access_log off;
    return 200 "healthy\n";
    add_header Content-Type text/plain;
}

# Health check with upstream verification
location = /health/deep {
    access_log off;
    proxy_pass http://backend/health;
    proxy_connect_timeout 2s;
    proxy_read_timeout 2s;
}
```

---

## Request Tracing

### Adding Request IDs

```nginx
# Generate unique request ID (Nginx 1.11.0+)
# $request_id is a built-in variable: 32 hex characters
server {
    # Pass to upstream for distributed tracing
    proxy_set_header X-Request-ID $request_id;

    # Include in response headers
    add_header X-Request-ID $request_id always;

    # Include in access log
    log_format trace '$remote_addr - [$time_local] "$request" $status '
                     'rt=$request_time urt=$upstream_response_time '
                     'rid=$request_id';
    access_log /var/log/nginx/access.log trace;
}
```

### Preserving External Request IDs

```nginx
# Use incoming X-Request-ID if present, otherwise generate
map $http_x_request_id $reqid {
    default $http_x_request_id;
    ""      $request_id;
}

server {
    proxy_set_header X-Request-ID $reqid;
    add_header X-Request-ID $reqid always;
}
```

### Upstream Response Timing

```nginx
log_format detailed '$remote_addr - [$time_local] "$request" $status '
                    '$body_bytes_sent '
                    'rt=$request_time '
                    'uct=$upstream_connect_time '
                    'uht=$upstream_header_time '
                    'urt=$upstream_response_time '
                    'us=$upstream_status '
                    'ua=$upstream_addr';
```

- **request_time**: total time from first client byte to last byte sent
- **upstream_connect_time**: time to establish connection to upstream
- **upstream_header_time**: time to receive response header from upstream
- **upstream_response_time**: time to receive full response from upstream
- **upstream_status**: HTTP status from upstream
- **upstream_addr**: upstream server address used

### Tracing Slow Requests

```bash
# Find requests taking > 5 seconds
awk -F'rt=' '$2+0 > 5.0' /var/log/nginx/access.log

# Find where time is spent (upstream vs nginx)
awk -F'[= ]' '{
    for(i=1;i<=NF;i++) {
        if($i=="rt") rt=$(i+1);
        if($i=="urt") urt=$(i+1);
    }
    nginx_time = rt - urt;
    if(rt > 2) printf "total=%.3f upstream=%.3f nginx=%.3f %s\n", rt, urt, nginx_time, $0
}' /var/log/nginx/access.log
```

### Conditional Debug Logging

```nginx
# Log full request/response for specific conditions
map $status $log_error_requests {
    ~^[45]  1;
    default 0;
}

map $request_time $log_slow_requests {
    ~^[5-9]\.|~^[1-9][0-9]  1;
    default                   0;
}

server {
    # Log error responses to separate file
    access_log /var/log/nginx/errors.log detailed if=$log_error_requests;
    # Log slow requests to separate file
    access_log /var/log/nginx/slow.log detailed if=$log_slow_requests;
}
```

---

## Connection Limits

### Worker Connection Limits

```nginx
worker_processes auto;          # one per CPU core
worker_rlimit_nofile 65535;     # max open files per worker

events {
    worker_connections 4096;    # max connections per worker
    # Total max connections = worker_processes × worker_connections
    # Each proxied request uses 2 connections (client + upstream)
    # Effective capacity = worker_connections / 2
}
```

### Per-IP Connection Limits

```nginx
http {
    limit_conn_zone $binary_remote_addr zone=addr:10m;
    limit_conn_zone $server_name zone=perserver:10m;

    server {
        # Max 20 connections per IP
        limit_conn addr 20;
        # Max 1000 connections per virtual server
        limit_conn perserver 1000;
        limit_conn_status 429;
        limit_conn_log_level warn;

        location /downloads/ {
            limit_conn addr 2;       # stricter for downloads
            limit_rate 1m;           # 1MB/s per connection
            limit_rate_after 10m;    # full speed for first 10MB
        }
    }
}
```

### Upstream Connection Limits

```nginx
upstream backend {
    server 10.0.0.1:8080 max_conns=100;
    server 10.0.0.2:8080 max_conns=100;
    queue 50 timeout=10s;   # Nginx Plus: queue requests when max_conns reached
    keepalive 32;
}
```

### Diagnosing Connection Issues

```bash
# Current connections to nginx
ss -s
# Connections per state
ss -ant | awk '{print $1}' | sort | uniq -c | sort -rn
# Connections per client IP
ss -ant state established | awk '{print $5}' | cut -d: -f1 | sort | uniq -c | sort -rn | head -20
# Check nginx worker file descriptors
ls /proc/$(pgrep -o nginx)/fd | wc -l
# Check system-wide limits
cat /proc/sys/net/core/somaxconn
sysctl net.ipv4.tcp_max_syn_backlog
```

### System Tuning for High Connection Counts

```bash
# /etc/sysctl.d/nginx.conf
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.core.netdev_max_backlog = 65535
fs.file-max = 2097152

# /etc/security/limits.d/nginx.conf
nginx soft nofile 65535
nginx hard nofile 65535
```

---

## Buffer Tuning

### Understanding Nginx Buffers

Nginx uses buffers at multiple stages. Undersized buffers cause disk I/O; oversized buffers waste memory.

### Client Request Buffers

```nginx
http {
    # Buffer for reading client request body
    client_body_buffer_size 16k;       # default 8k|16k
    # Larger bodies written to temp files
    client_body_temp_path /var/nginx/client_temp 1 2;

    # Buffer for reading client request headers
    client_header_buffer_size 4k;      # default 1k
    # For large headers (big cookies, long URLs)
    large_client_header_buffers 4 32k; # default 4 8k
}
```

### Proxy Buffers

```nginx
location /api/ {
    proxy_pass http://backend;

    # First part of response (typically headers)
    proxy_buffer_size 8k;             # default 4k|8k

    # Buffers for response body
    proxy_buffers 8 16k;              # default 8 4k|8k

    # How much can be sent to client while still reading from upstream
    proxy_busy_buffers_size 32k;      # default 2 × proxy_buffer_size

    # Max size of temp files when response exceeds memory buffers
    proxy_max_temp_file_size 1024m;   # default 1024m, set 0 to disable

    proxy_temp_file_write_size 32k;
    proxy_temp_path /var/nginx/proxy_temp 1 2;
}
```

### When to Disable Buffering

```nginx
# Streaming responses (SSE, chunked transfers)
location /events/ {
    proxy_pass http://backend;
    proxy_buffering off;
    proxy_cache off;

    # Also for chunked/streaming:
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    chunked_transfer_encoding on;
}

# Large file downloads (let kernel handle it)
location /downloads/ {
    proxy_pass http://backend;
    proxy_buffering off;
    proxy_request_buffering off;
}
```

### FastCGI Buffer Tuning

```nginx
location ~ \.php$ {
    fastcgi_pass unix:/run/php/php-fpm.sock;
    fastcgi_buffer_size 16k;
    fastcgi_buffers 16 16k;
    fastcgi_busy_buffers_size 32k;
}
```

### Diagnosing Buffer Issues

```bash
# Look for buffer warnings in error log
grep -i "upstream buffer" /var/log/nginx/error.log
grep "an upstream response is buffered to a temporary file" /var/log/nginx/error.log

# Check for temp file usage
ls -la /var/nginx/proxy_temp/
du -sh /var/nginx/proxy_temp/
```

Signs of buffer issues:
- `warn` level: "an upstream response is buffered to a temporary file" — increase `proxy_buffers`
- Slow responses for large payloads — buffers too small, causing disk writes
- High memory usage — buffers too large per connection

---

## proxy_pass Trailing Slash Pitfalls

This is one of the most common sources of misrouted requests.

### The Rules

```nginx
# Rule 1: No URI in proxy_pass → request URI passed as-is
location /api/ {
    proxy_pass http://backend;
    # GET /api/users → backend receives /api/users
}

# Rule 2: URI in proxy_pass → location prefix is replaced
location /api/ {
    proxy_pass http://backend/;
    # GET /api/users → backend receives /users
    # The /api/ prefix is stripped and replaced with /
}

# Rule 3: URI path in proxy_pass → prefix is replaced with that path
location /api/ {
    proxy_pass http://backend/v2/;
    # GET /api/users → backend receives /v2/users
}

# Rule 4: No trailing slash in proxy_pass URI
location /api/ {
    proxy_pass http://backend/v2;
    # GET /api/users → backend receives /v2users  ← BROKEN!
}
```

### Common Mistakes

```nginx
# MISTAKE 1: Missing trailing slash causes path concatenation
location /app/ {
    proxy_pass http://backend/service;
    # /app/page → /servicepage  ← WRONG
}
# FIX:
location /app/ {
    proxy_pass http://backend/service/;
    # /app/page → /service/page  ← CORRECT
}

# MISTAKE 2: Regex location with URI in proxy_pass
location ~ ^/api/v(\d+)/(.*)$ {
    proxy_pass http://backend/api/$1/$2;
    # This WORKS — regex captures can be used in proxy_pass
}

# MISTAKE 3: Variable in proxy_pass changes behavior
location /api/ {
    set $backend "http://10.0.0.1:8080";
    proxy_pass $backend;
    # When proxy_pass uses a variable, the URI is passed as-is
    # (no prefix stripping, even with trailing slash)
    # /api/users → /api/users
}

# MISTAKE 4: Double slashes
location /api {          # no trailing slash in location
    proxy_pass http://backend/;
    # GET /api/users → backend receives //users  ← DOUBLE SLASH
}
# FIX: match the slash pattern
location /api/ {         # trailing slash matches proxy_pass /
    proxy_pass http://backend/;
}
```

### Debugging proxy_pass Routing

```nginx
# Add header to see what upstream received
location /api/ {
    proxy_pass http://backend/;
    proxy_set_header X-Original-URI $request_uri;

    # Or use add_header to verify from client side
    add_header X-Upstream-URI $upstream_http_x_original_uri always;
}

# On the upstream side, log the received URI
# Then compare $request_uri (nginx) with upstream's received path
```

### Quick Reference Table

| Location | proxy_pass | Request | Upstream Receives |
|---|---|---|---|
| `/api/` | `http://backend` | `/api/users` | `/api/users` |
| `/api/` | `http://backend/` | `/api/users` | `/users` |
| `/api/` | `http://backend/v2/` | `/api/users` | `/v2/users` |
| `/api/` | `http://backend/v2` | `/api/users` | `/v2users` ⚠️ |
| `/api` | `http://backend/` | `/api/users` | `//users` ⚠️ |

---

## DNS Resolution with resolver

### The Problem

Nginx resolves hostnames in `proxy_pass` **only at startup/reload**. If upstream IPs change (cloud, containers, DNS failover), nginx keeps using stale IPs.

### The Fix: resolver Directive

```nginx
http {
    # Set DNS resolver with caching
    resolver 127.0.0.53 valid=30s ipv6=off;
    resolver_timeout 5s;

    server {
        location /api/ {
            # MUST use a variable for resolver to work
            set $backend "api-service.internal.example.com";
            proxy_pass http://$backend:8080;

            # Without the variable, DNS is resolved only at startup
            # proxy_pass http://api-service.internal.example.com:8080;  ← STALE DNS
        }
    }
}
```

### Important: Variable Requirement

```nginx
# ❌ DNS resolved once at startup — will NOT re-resolve
proxy_pass http://my-service.consul:8080;

# ✅ DNS re-resolved based on resolver valid= TTL
set $upstream "my-service.consul";
proxy_pass http://$upstream:8080;
```

### Multiple Resolvers

```nginx
# Multiple DNS servers for redundancy
resolver 10.0.0.2 10.0.0.3 valid=30s ipv6=off;

# Kubernetes CoreDNS
resolver kube-dns.kube-system.svc.cluster.local valid=5s;

# Docker embedded DNS
resolver 127.0.0.11 valid=10s ipv6=off;

# Consul DNS
resolver 127.0.0.1:8600 valid=5s;
```

### Gotchas with resolver + Variables

```nginx
# When using variables in proxy_pass, the URI behavior changes
location /api/ {
    set $backend "myservice.local";
    proxy_pass http://$backend:8080;
    # /api/users → upstream receives /api/users (NO prefix stripping)
    # Variables disable the prefix replacement behavior
}

# To strip prefix with variables, use rewrite
location /api/ {
    set $backend "myservice.local";
    rewrite ^/api/(.*) /$1 break;
    proxy_pass http://$backend:8080;
}
```

### Diagnosing DNS Issues

```bash
# Check what nginx resolved
grep "resolver" /var/log/nginx/error.log
# Test DNS resolution
dig @127.0.0.53 my-service.internal.example.com
# Check for "no resolver defined" errors
grep "no resolver defined" /var/log/nginx/error.log
# Check for resolution timeouts
grep "resolver timed out" /var/log/nginx/error.log
```

---

## Upstream Keepalive Issues

### Proper Keepalive Configuration

```nginx
upstream backend {
    server 10.0.0.1:8080;
    server 10.0.0.2:8080;

    # Number of idle keepalive connections to preserve per worker
    keepalive 32;

    # Max requests per keepalive connection (Nginx 1.15.3+)
    keepalive_requests 1000;

    # Idle timeout for keepalive connections (Nginx 1.15.3+)
    keepalive_timeout 60s;
}

server {
    location / {
        proxy_pass http://backend;

        # REQUIRED for keepalive to work
        proxy_http_version 1.1;
        proxy_set_header Connection "";

        # Without these two lines, nginx sends HTTP/1.0 with
        # "Connection: close" — keepalive will NOT work
    }
}
```

### Common Keepalive Mistakes

```nginx
# MISTAKE 1: Missing HTTP/1.1 and Connection header
location / {
    proxy_pass http://backend;
    # Default: HTTP/1.0 with Connection: close → no keepalive
}

# MISTAKE 2: WebSocket map overrides keepalive
map $http_upgrade $connection_upgrade {
    default upgrade;
    ""      close;          # ← This kills keepalive!
}
# FIX:
map $http_upgrade $connection_upgrade {
    default upgrade;
    ""      "";             # Empty string preserves keepalive
}

# MISTAKE 3: keepalive value too high
upstream backend {
    server 10.0.0.1:8080;
    keepalive 1000;     # Each worker caches 1000 connections
    # With 8 workers: 8000 idle connections held open
    # This wastes upstream resources
}
# Better: keepalive = 2 × (typical concurrent requests / number of workers)

# MISTAKE 4: upstream closes connection before nginx
# If upstream keepalive timeout < proxy timeouts, nginx gets broken pipes
# Ensure upstream keepalive_timeout > proxy_read_timeout
```

### Diagnosing Keepalive Issues

```bash
# Check connection reuse in debug log
grep "keepalive" /var/log/nginx/error.log
# "free keepalive peer" = connection returned to pool
# "get keepalive peer" = connection reused from pool
# "close keepalive" = connection closed

# Monitor connection states
ss -ant state established dst 10.0.0.1 | wc -l

# Check for connection storms (many TIME_WAIT)
ss -ant state time-wait dst 10.0.0.1 | wc -l
# High TIME_WAIT count = keepalive not working
```

### Measuring Keepalive Effectiveness

```nginx
# Add upstream connection info to logs
log_format upstream_debug '$remote_addr [$time_local] "$request" '
    '$status ua=$upstream_addr us=$upstream_status '
    'uct=$upstream_connect_time uht=$upstream_header_time '
    'urt=$upstream_response_time uka=$upstream_keepalive_time';
```

Low `upstream_connect_time` (< 1ms) indicates connection reuse. High values (> 1ms) suggest new TCP connections each time.

---

## Graceful Reload vs Restart

### Reload (Graceful — Preferred)

```bash
# Sends SIGHUP to master process
nginx -s reload
# Or:
systemctl reload nginx
# Or:
kill -HUP $(cat /var/run/nginx.pid)
```

**What happens during reload**:
1. Master process reads new config
2. Master validates new config syntax
3. If valid, master starts new worker processes with new config
4. Old workers finish existing requests (graceful shutdown)
5. Old workers exit after all connections close or `worker_shutdown_timeout` expires
6. **Zero downtime** — no connections dropped

```nginx
# Set max time for old workers to finish (default: unlimited)
worker_shutdown_timeout 30s;
```

### Restart (Disruptive — Avoid in Production)

```bash
# Full stop and start
systemctl restart nginx
# Or:
nginx -s stop    # immediate shutdown (SIGTERM)
nginx             # start
```

**What happens during restart**:
- All connections immediately terminated
- Brief period with no listener on the port
- **Connections will be dropped**

### When Reload Fails

```bash
# Test config before reload
nginx -t
# Output: nginx: configuration file /etc/nginx/nginx.conf test is successful

# If reload fails, check error log
tail -f /var/log/nginx/error.log &
nginx -s reload

# Common reload failures:
# - Syntax error in config (old config continues serving)
# - Port conflict (new listen directive conflicts)
# - Missing SSL certificate file
# - Permission denied on log file
```

### Advanced: Binary Upgrade (Zero-Downtime)

For upgrading the nginx binary itself:

```bash
# 1. Send USR2 to start new master with new binary
kill -USR2 $(cat /var/run/nginx.pid)
# New master starts, old master renames PID file to .oldbin

# 2. Gracefully shut down old workers
kill -WINCH $(cat /var/run/nginx.pid.oldbin)
# Old workers finish requests and exit

# 3. If new version works, quit old master
kill -QUIT $(cat /var/run/nginx.pid.oldbin)

# 3b. If new version has problems, roll back
kill -HUP $(cat /var/run/nginx.pid.oldbin)   # restart old workers
kill -QUIT $(cat /var/run/nginx.pid)          # stop new master
```

### Reload Impact on Connections

| Feature | Reload | Restart |
|---|---|---|
| Existing HTTP connections | Completed gracefully | Dropped |
| WebSocket connections | Completed gracefully | Dropped |
| TCP stream connections | Completed gracefully | Dropped |
| SSL session cache | Preserved (shared memory) | Lost |
| proxy_cache | Preserved (on disk) | Preserved (on disk) |
| Rate limit counters | Preserved (shared memory) | Lost |
| Shared dict (Lua) | Preserved | Lost |
| New config applied | Yes | Yes |
| Downtime | None | Brief |

### Automated Safe Reload

```bash
#!/bin/bash
# Safe reload with pre-check
set -e

echo "Testing nginx configuration..."
nginx -t 2>&1

echo "Configuration valid. Reloading..."
nginx -s reload

echo "Verifying nginx is responding..."
sleep 1
if curl -sf http://127.0.0.1/health > /dev/null; then
    echo "Reload successful"
else
    echo "WARNING: Health check failed after reload!"
    exit 1
fi
```
