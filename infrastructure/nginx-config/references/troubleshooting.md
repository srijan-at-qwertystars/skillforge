# Nginx Troubleshooting Guide

Systematic approaches to diagnosing and resolving common Nginx issues in production environments.

## Table of Contents

- [502 Bad Gateway Diagnosis](#502-bad-gateway-diagnosis)
- [Upstream Timeout Tuning](#upstream-timeout-tuning)
- [Connection Reset Debugging](#connection-reset-debugging)
- [SSL Handshake Failures](#ssl-handshake-failures)
- [client_max_body_size Issues](#client_max_body_size-issues)
- [proxy_buffer Issues](#proxy_buffer-issues)
- [Location Matching Debugging](#location-matching-debugging)
- [Permission Denied Errors](#permission-denied-errors)
- [Log Analysis Techniques](#log-analysis-techniques)
- [Quick Diagnostic Commands](#quick-diagnostic-commands)

---

## 502 Bad Gateway Diagnosis

A 502 means Nginx received an invalid response from the upstream server. This is the most
common Nginx error in reverse proxy setups.

### Systematic Diagnosis

```bash
# Step 1: Check error log for the specific error
tail -100 /var/log/nginx/error.log | grep "502\|upstream"

# Step 2: Is the upstream running?
ss -tulnp | grep <port>
systemctl status <service>

# Step 3: Can Nginx reach the upstream?
curl -v http://127.0.0.1:<upstream_port>/

# Step 4: Check for resource exhaustion
ulimit -n              # File descriptor limit
cat /proc/sys/net/core/somaxconn   # Connection backlog
```

### Common Causes and Fixes

**1. Upstream service is down**
```bash
# Verify the backend process
systemctl status php-fpm    # or node, gunicorn, etc.
journalctl -u <service> --since "5 minutes ago"
```

**2. Socket/port mismatch**
```nginx
# Wrong: Nginx points to TCP but backend uses socket
proxy_pass http://127.0.0.1:9000;

# Fix: Match the backend's actual listener
# For PHP-FPM with socket:
fastcgi_pass unix:/run/php/php8.2-fpm.sock;
# For PHP-FPM with TCP:
fastcgi_pass 127.0.0.1:9000;
```

**3. Socket permissions**
```bash
# Check socket ownership and permissions
ls -la /run/php/php8.2-fpm.sock
# Fix: Ensure nginx user can access the socket
# In php-fpm pool.d/www.conf:
#   listen.owner = www-data
#   listen.group = www-data
#   listen.mode = 0660
```

**4. Upstream connection refused**
```bash
# Error: connect() failed (111: Connection refused)
# The upstream is not listening on the expected address

# Check what's actually listening
ss -tulnp | grep LISTEN

# Common fix: backend bound to localhost but Nginx connects to 0.0.0.0
# Change proxy_pass to http://127.0.0.1:PORT (not http://0.0.0.0:PORT)
```

**5. Too many open files**
```bash
# Error: socket() failed (24: Too many open files)
# Increase limits:
# In nginx.conf:
worker_rlimit_nofile 65535;

# System level:
echo "nginx soft nofile 65535" >> /etc/security/limits.conf
echo "nginx hard nofile 65535" >> /etc/security/limits.conf
# Or in systemd unit: LimitNOFILE=65535
```

**6. Upstream sent too large header**
```
# Error: upstream sent too big header while reading response header
# See proxy_buffer section below
```

---

## Upstream Timeout Tuning

### The Three Timeout Phases

```nginx
location / {
    # Phase 1: Establishing connection to upstream
    proxy_connect_timeout 5s;     # Default: 60s. Keep short — if upstream is down, fail fast

    # Phase 2: Sending request to upstream
    proxy_send_timeout 60s;       # Default: 60s. Increase for large file uploads

    # Phase 3: Reading response from upstream
    proxy_read_timeout 300s;      # Default: 60s. Increase for long-running operations
}
```

### Timeout Error Messages

| Error Log Message | Timeout | Fix |
|---|---|---|
| `upstream timed out (110: Connection timed out) while connecting` | `proxy_connect_timeout` | Upstream is down or network issue |
| `upstream timed out (110: Connection timed out) while sending request` | `proxy_send_timeout` | Upstream overloaded, increase timeout |
| `upstream timed out (110: Connection timed out) while reading response header` | `proxy_read_timeout` | Slow query/computation, increase timeout |
| `upstream timed out (110: Connection timed out) while reading upstream` | `proxy_read_timeout` | Large response body, increase timeout |

### Per-Location Timeout Tuning

```nginx
# Fast API endpoints — fail fast
location /api/ {
    proxy_connect_timeout 3s;
    proxy_read_timeout 30s;
    proxy_pass http://api_backend;
}

# Long-running reports — generous timeout
location /api/reports/ {
    proxy_connect_timeout 5s;
    proxy_read_timeout 600s;
    proxy_pass http://api_backend;
}

# File uploads
location /upload/ {
    proxy_connect_timeout 5s;
    proxy_send_timeout 300s;
    proxy_read_timeout 300s;
    client_max_body_size 500m;
    proxy_pass http://upload_backend;
}

# WebSocket — very long timeout
location /ws/ {
    proxy_read_timeout 86400s;
    proxy_send_timeout 86400s;
    proxy_pass http://ws_backend;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
}
```

### Upstream Keepalive Tuning

```nginx
upstream backend {
    server 10.0.0.10:8080;
    keepalive 32;                          # Persistent connections to upstream
    keepalive_timeout 60s;                 # How long idle connections survive
    keepalive_requests 1000;               # Max requests per keepalive connection
}

location / {
    proxy_pass http://backend;
    proxy_http_version 1.1;                # Required for keepalive
    proxy_set_header Connection "";         # Remove "close" header
}
```

---

## Connection Reset Debugging

### Error: `(104: Connection reset by peer)`

This means the upstream closed the connection unexpectedly.

```bash
# Check upstream application logs
journalctl -u <service> | tail -50

# Common causes:
# 1. Upstream OOM killed
dmesg | grep -i "oom\|killed"

# 2. Upstream max connection limit reached
# Check backend's connection settings (e.g., PM max_children for PHP-FPM)

# 3. Upstream crashed/restarted during request
systemctl status <service>
```

### Error: `(111: Connection refused)`

```bash
# Upstream not listening
ss -tulnp | grep <port>

# Upstream bound to wrong interface
# Backend listening on 127.0.0.1 but Nginx connecting to private IP
# Fix: Match addresses exactly
```

### Error: `(113: No route to host)`

```bash
# Network/firewall issue
ping <upstream_ip>
traceroute <upstream_ip>
iptables -L -n | grep <upstream_port>
```

### Connection Reset by Client

```
# client prematurely closed connection
# This is usually the client disconnecting (browser closed, timeout)
# Configure behavior:

proxy_ignore_client_abort on;   # Continue upstream request even if client disconnects
# Default: off (abort upstream request when client disconnects)
```

---

## SSL Handshake Failures

### Diagnosis Steps

```bash
# Step 1: Test SSL from the command line
openssl s_client -connect example.com:443 -servername example.com

# Step 2: Check certificate validity
openssl x509 -in /etc/letsencrypt/live/example.com/fullchain.pem -text -noout

# Step 3: Verify certificate chain
openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt \
    /etc/letsencrypt/live/example.com/fullchain.pem

# Step 4: Check Nginx error log
grep -i "ssl\|handshake\|certificate" /var/log/nginx/error.log
```

### Common SSL Errors and Fixes

**1. Certificate and key mismatch**
```bash
# Error: SSL_CTX_use_PrivateKey_file failed / key values mismatch

# Compare modulus of cert and key:
openssl x509 -noout -modulus -in cert.pem | openssl md5
openssl rsa -noout -modulus -in key.pem | openssl md5
# Both must produce the same hash

# Fix: Regenerate CSR with the correct key, or get new cert
```

**2. Expired certificate**
```bash
# Error: certificate has expired

openssl x509 -enddate -noout -in /etc/letsencrypt/live/example.com/fullchain.pem
# Fix: Renew with certbot
certbot renew --force-renewal
nginx -s reload
```

**3. Incomplete certificate chain**
```bash
# Error: unable to verify the first certificate
# Client gets: ERR_CERT_AUTHORITY_INVALID

# Fix: Use fullchain.pem (not cert.pem) for ssl_certificate
ssl_certificate /etc/letsencrypt/live/example.com/fullchain.pem;

# Verify chain completeness:
openssl s_client -connect example.com:443 -showcerts
# Check that intermediate certs are included
```

**4. TLS version/cipher mismatch**
```bash
# Error: no shared cipher / handshake failure

# Test specific TLS versions:
openssl s_client -connect example.com:443 -tls1_2
openssl s_client -connect example.com:443 -tls1_3

# Check configured ciphers:
nginx -T | grep ssl_ciphers
nginx -T | grep ssl_protocols

# Fix: Ensure protocols and ciphers overlap between client and server
ssl_protocols TLSv1.2 TLSv1.3;
```

**5. SNI (Server Name Indication) issues**
```bash
# Wrong cert served for a domain

# Test with explicit SNI:
openssl s_client -connect example.com:443 -servername example.com

# Fix: Ensure each server block has correct server_name and ssl_certificate
# Use default_server to catch unmatched SNI:
server {
    listen 443 ssl default_server;
    server_name _;
    ssl_certificate /etc/ssl/default.crt;
    ssl_certificate_key /etc/ssl/default.key;
    return 444;
}
```

**6. OCSP stapling failures**
```bash
# Error: OCSP_basic_verify() failed

# Test OCSP:
openssl ocsp -issuer chain.pem -cert cert.pem \
    -url http://ocsp.provider.com -resp_text

# Fix: Ensure ssl_trusted_certificate points to the CA chain
ssl_stapling on;
ssl_stapling_verify on;
ssl_trusted_certificate /etc/letsencrypt/live/example.com/chain.pem;
resolver 1.1.1.1 8.8.8.8 valid=300s;
```

---

## client_max_body_size Issues

### Error: `413 Request Entity Too Large`

```nginx
# The client sent a request body larger than allowed
# Default: client_max_body_size 1m;

# Fix: Increase in the appropriate context
http {
    client_max_body_size 50m;      # Global default
}

server {
    client_max_body_size 100m;     # Per-server override
}

location /upload/ {
    client_max_body_size 500m;     # Per-location override
}

# Set to 0 to disable the check entirely (not recommended):
client_max_body_size 0;
```

### Related Buffer Settings for Large Uploads

```nginx
location /upload/ {
    client_max_body_size 500m;
    client_body_buffer_size 128k;          # Buffer in memory before writing to disk
    client_body_temp_path /var/lib/nginx/tmp 1 2;
    client_body_timeout 300s;              # Timeout between reads from client

    proxy_request_buffering off;           # Stream body directly to upstream
    proxy_pass http://upload_backend;
}
```

### Debugging

```bash
# Check which context is setting the limit
nginx -T | grep client_max_body_size

# Test with curl
curl -v -X POST -F "file=@largefile.zip" https://example.com/upload/
# Look for: < HTTP/1.1 413 Request Entity Too Large
```

---

## proxy_buffer Issues

### Error: `upstream sent too big header while reading response header`

The upstream's response headers exceed `proxy_buffer_size`.

```nginx
# Increase header buffer
proxy_buffer_size 16k;          # Default: 4k or 8k (platform-dependent)

# For applications with large cookies/headers (e.g., OAuth tokens):
proxy_buffer_size 32k;
```

### Error: `an upstream response is buffered to a temporary file`

Response body exceeds in-memory buffers, written to disk (slower).

```nginx
# Increase response body buffers
proxy_buffers 8 32k;             # 8 buffers of 32k each (256k total)
proxy_busy_buffers_size 64k;     # Max size sent to client while still buffering

# For large responses:
proxy_buffers 16 64k;
proxy_busy_buffers_size 128k;
proxy_max_temp_file_size 1024m;  # Max temp file size (0 = disable temp files)
```

### Disable Buffering (Streaming)

```nginx
# For SSE, streaming downloads, or real-time responses
location /stream/ {
    proxy_buffering off;           # Pass response chunks immediately
    proxy_pass http://backend;
}

# Or let upstream control it via header:
# Backend sends: X-Accel-Buffering: no
```

### FastCGI Buffer Issues

```nginx
# For PHP-FPM (similar to proxy_buffer but for FastCGI):
fastcgi_buffer_size 32k;
fastcgi_buffers 8 32k;
fastcgi_busy_buffers_size 64k;
```

### Buffer Size Calculation

```
Total buffer memory per connection = proxy_buffer_size + (proxy_buffers count × size)
Example: 16k + (8 × 32k) = 272k per connection
With 1000 connections: 272k × 1000 = ~266 MB

# Be mindful of total memory usage with many concurrent connections
```

---

## Location Matching Debugging

### Step-by-Step Debugging

```bash
# Step 1: Dump effective config
nginx -T | less

# Step 2: Identify all location blocks for the server
nginx -T | grep -A2 "location"

# Step 3: Test with debug logging
error_log /var/log/nginx/error.log debug;
# Then make a request and check the log for "test location" messages
```

### Common Matching Mistakes

**1. Regex overrides longer prefix match**
```nginx
# Request: /static/image.jpg
# WRONG: regex matches first despite shorter pattern
location /static/ { alias /var/www/static/; }     # This is a prefix match
location ~ \.(jpg|png)$ { proxy_pass http://img; } # Regex wins!

# FIX: Use ^~ to prevent regex from overriding
location ^~ /static/ { alias /var/www/static/; }   # Now this wins
```

**2. Missing trailing slash confusion**
```nginx
# These are DIFFERENT locations:
location /api { }       # Matches /api, /api/, /api-v2, /anything-starting-with-api
location /api/ { }      # Matches /api/, /api/users, but NOT /api

# For proxy_pass, trailing slash matters:
location /api/ {
    proxy_pass http://backend/;     # /api/users → /users (prefix stripped)
    proxy_pass http://backend;      # /api/users → /api/users (preserved)
}
```

**3. Nested location issues**
```nginx
# Nested locations only match if the parent matches first
location /api/ {
    location /api/admin/ {
        # This works — parent matches /api/ first
    }
}

location /api/ {
    location /other/ {
        # This NEVER matches — /other/ doesn't start with /api/
    }
}
```

### Debug Location Matching with Response Headers

```nginx
# Temporarily add a header to identify which location block handled the request
location / {
    add_header X-Debug-Location "root" always;
    proxy_pass http://backend;
}

location /api/ {
    add_header X-Debug-Location "api" always;
    proxy_pass http://api_backend;
}

location ^~ /static/ {
    add_header X-Debug-Location "static" always;
    alias /var/www/static/;
}

# Test: curl -I https://example.com/api/users | grep X-Debug
```

### Priority Reference

```
1. = /exact         Exact match (highest priority, stops immediately)
2. ^~ /prefix       Preferential prefix (stops, skips all regex)
3. ~ regex          Case-sensitive regex (first match in config order)
4. ~* regex         Case-insensitive regex (first match in config order)
5. /prefix          Standard prefix (longest match, but regex can override)
6. /                Default fallback (lowest priority)
```

---

## Permission Denied Errors

### Error: `(13: Permission denied)`

```bash
# Step 1: Identify what Nginx runs as
ps aux | grep nginx
# master runs as root, workers run as nginx/www-data

# Step 2: Check the file/directory permissions
ls -la /var/www/html/
namei -l /var/www/html/index.html    # Shows permissions of entire path

# Step 3: Fix ownership
chown -R www-data:www-data /var/www/html/
chmod -R 755 /var/www/html/
```

### Common Permission Issues

**1. Root directory traversal**
```bash
# Every directory in the path must be executable (traversable)
# BAD: /home/user/www (user's home may be 700)
chmod 711 /home/user
chmod 755 /home/user/www

# BETTER: Use /var/www/ or /srv/ for web content
```

**2. SELinux blocking access**
```bash
# Check if SELinux is the cause
getenforce
ausearch -m avc -ts recent

# Fix: Set correct SELinux context
chcon -R -t httpd_sys_content_t /var/www/html/
# Or for writable content:
chcon -R -t httpd_sys_rw_content_t /var/www/uploads/

# For proxying to non-standard ports:
setsebool -P httpd_can_network_connect 1
```

**3. Socket permission denied**
```bash
# Error: connect() to unix:/run/php/php-fpm.sock failed (13: Permission denied)

# Fix: Match socket ownership with Nginx user
# In php-fpm pool config:
listen.owner = www-data
listen.group = www-data
listen.mode = 0660
```

**4. Log directory permissions**
```bash
# Error: open() "/var/log/nginx/custom.log" failed (13: Permission denied)
chown www-data:adm /var/log/nginx/
chmod 755 /var/log/nginx/
```

**5. Temp directory permissions**
```bash
# Error: open() "/var/lib/nginx/tmp/..." failed (13: Permission denied)
chown -R www-data:www-data /var/lib/nginx/
```

---

## Log Analysis Techniques

### Essential Log Formats

```nginx
# JSON structured logging (recommended for production)
log_format json escape=json '{'
    '"time":"$time_iso8601",'
    '"remote_addr":"$remote_addr",'
    '"request_method":"$request_method",'
    '"request_uri":"$request_uri",'
    '"status":$status,'
    '"body_bytes_sent":$body_bytes_sent,'
    '"request_time":$request_time,'
    '"upstream_response_time":"$upstream_response_time",'
    '"upstream_addr":"$upstream_addr",'
    '"http_referer":"$http_referer",'
    '"http_user_agent":"$http_user_agent",'
    '"request_id":"$request_id"'
    '}';
```

### Quick Analysis Commands

```bash
# Top 20 requesting IPs
awk '{print $1}' /var/log/nginx/access.log | sort | uniq -c | sort -rn | head -20

# Status code distribution
awk '{print $9}' /var/log/nginx/access.log | sort | uniq -c | sort -rn

# Top 20 requested URIs
awk '{print $7}' /var/log/nginx/access.log | sort | uniq -c | sort -rn | head -20

# 5xx errors with full request
awk '$9 >= 500' /var/log/nginx/access.log | tail -50

# Requests per second (last 1000 lines)
tail -1000 /var/log/nginx/access.log | awk '{print $4}' | cut -d: -f1-3 | uniq -c

# Slowest requests (combined log format with $request_time appended)
awk '{print $NF, $7}' /var/log/nginx/access.log | sort -rn | head -20

# Large response bodies
awk '{print $10, $7}' /var/log/nginx/access.log | sort -rn | head -20
```

### JSON Log Analysis

```bash
# Using jq for JSON logs
# Top IPs
cat /var/log/nginx/access.log | jq -r '.remote_addr' | sort | uniq -c | sort -rn | head -20

# Slow requests (>1s)
cat /var/log/nginx/access.log | jq -r 'select(.request_time > 1) | "\(.request_time)s \(.request_method) \(.request_uri)"'

# 5xx errors
cat /var/log/nginx/access.log | jq -r 'select(.status >= 500) | "\(.time) \(.status) \(.request_uri) upstream=\(.upstream_addr)"'

# Average response time by URI pattern
cat /var/log/nginx/access.log | jq -r '"\(.request_uri | split("?")[0]) \(.request_time)"' | \
    awk '{uri=$1; time=$2; sum[uri]+=time; count[uri]++} END {for(u in sum) printf "%.3fs %s (%d reqs)\n", sum[u]/count[u], u, count[u]}' | sort -rn | head -20

# Upstream response time vs total (proxy overhead)
cat /var/log/nginx/access.log | jq -r 'select(.upstream_response_time != "-") | "\(.request_time) \(.upstream_response_time)"' | \
    awk '{total+=$1; upstream+=$2; count++} END {printf "avg total: %.3fs, avg upstream: %.3fs, avg nginx overhead: %.3fms\n", total/count, upstream/count, (total/count - upstream/count)*1000}'
```

### Error Log Analysis

```bash
# Count errors by type
grep -oP '\[\w+\]' /var/log/nginx/error.log | sort | uniq -c | sort -rn

# Recent upstream errors
grep "upstream" /var/log/nginx/error.log | tail -20

# SSL errors
grep -i "ssl\|certificate\|handshake" /var/log/nginx/error.log | tail -20

# Permission errors
grep "permission denied\|forbidden" /var/log/nginx/error.log | tail -20

# Connection limit errors
grep "limiting\|limit_req\|limit_conn" /var/log/nginx/error.log | tail -20
```

### Real-Time Monitoring

```bash
# Watch for errors in real time
tail -f /var/log/nginx/error.log

# Watch for 5xx in access log
tail -f /var/log/nginx/access.log | awk '$9 >= 500'

# Monitor request rate
tail -f /var/log/nginx/access.log | pv -l -i5 -r > /dev/null

# GoAccess real-time dashboard (if installed)
goaccess /var/log/nginx/access.log -o /var/www/html/report.html --real-time-html
```

---

## Quick Diagnostic Commands

```bash
# Config validation
nginx -t                           # Syntax check
nginx -T                           # Dump full effective config
nginx -T | grep -i <directive>     # Find specific directives
nginx -V                           # Show compile-time modules

# Process info
ps aux | grep nginx                # Master and worker processes
cat /proc/<worker_pid>/limits      # Check FD limits for workers

# Connection status
ss -s                              # Connection summary
ss -tulnp | grep nginx             # Nginx listening ports
ss -tnp | grep nginx | wc -l       # Active connections to Nginx

# Current Nginx metrics (if stub_status enabled)
curl http://127.0.0.1/nginx_status

# Test specific endpoints
curl -I https://example.com        # Headers only
curl -v https://example.com        # Verbose (includes TLS handshake)
curl -k https://example.com        # Skip cert verification
curl -H "Host: example.com" http://127.0.0.1  # Test specific vhost

# SSL diagnostics
openssl s_client -connect example.com:443 -servername example.com
echo | openssl s_client -connect example.com:443 2>/dev/null | openssl x509 -text -noout

# File descriptor usage
ls /proc/<nginx_worker_pid>/fd | wc -l    # FDs used by a worker
cat /proc/<nginx_worker_pid>/limits | grep "Max open files"
```
