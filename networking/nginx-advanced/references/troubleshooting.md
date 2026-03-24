# Nginx Troubleshooting Reference

## Table of Contents

- [502 Bad Gateway Errors](#502-bad-gateway-errors)
- [504 Gateway Timeout Errors](#504-gateway-timeout-errors)
- [Upstream Timeout Tuning](#upstream-timeout-tuning)
- [Buffer Overflow Errors](#buffer-overflow-errors)
- [SSL/TLS Handshake Failures](#ssltls-handshake-failures)
- [worker_connections Exhaustion](#worker_connections-exhaustion)
- [Memory Issues and Leaks](#memory-issues-and-leaks)
- [Log Analysis Techniques](#log-analysis-techniques)
- [Debug Log Level](#debug-log-level)
- [System-Level Debugging (strace/tcpdump)](#system-level-debugging-stracetcpdump)
- [Common Misconfigurations](#common-misconfigurations)
- [Performance Diagnostics](#performance-diagnostics)

---

## 502 Bad Gateway Errors

A 502 means nginx connected to the upstream but received an invalid response (or the connection was refused/reset).

### Diagnosis Checklist

```bash
# 1. Check if upstream is running
curl -v http://127.0.0.1:8080/health

# 2. Check nginx error log for specifics
tail -100 /var/log/nginx/error.log | grep -E '502|upstream|connect'

# 3. Check upstream process status
systemctl status your-app
ss -tlnp | grep 8080

# 4. Check if upstream socket exists (for unix sockets)
ls -la /run/php/php-fpm.sock
```

### Common 502 Causes and Fixes

**Upstream not running:**
```
*1 connect() failed (111: Connection refused) while connecting to upstream
```
Fix: Start the upstream service. Verify the port/socket path matches nginx config.

**Upstream crashed mid-response:**
```
*1 upstream prematurely closed connection while reading response header
```
Fix: Check upstream application logs for crashes/OOM kills. Increase upstream memory/timeout.

**PHP-FPM socket permission denied:**
```
*1 connect() to unix:/run/php/php-fpm.sock failed (13: Permission denied)
```
Fix: Ensure nginx worker user matches PHP-FPM socket owner:
```ini
; /etc/php/8.2/fpm/pool.d/www.conf
listen.owner = www-data
listen.group = www-data
listen.mode = 0660
```

**Upstream response too large for buffer:**
```
*1 upstream sent too big header while reading response header from upstream
```
Fix:
```nginx
proxy_buffer_size 8k;           # for response headers (default 4k)
proxy_buffers 16 16k;           # for response body
proxy_busy_buffers_size 32k;
```

**SELinux blocking connections:**
```bash
# Check SELinux denials
ausearch -m avc -ts recent | grep nginx
# Allow nginx to make network connections
setsebool -P httpd_can_network_connect 1
```

---

## 504 Gateway Timeout Errors

A 504 means nginx timed out waiting for the upstream to respond.

### Diagnosis

```bash
# Check which timeout was hit
grep "upstream timed out" /var/log/nginx/error.log

# Sample messages:
# upstream timed out (110: Connection timed out) while connecting to upstream
#   → proxy_connect_timeout hit
# upstream timed out (110: Connection timed out) while reading response header
#   → proxy_read_timeout hit
```

### Timeout Tuning

```nginx
location /api/ {
    # Time to establish connection to upstream (default: 60s, set low)
    proxy_connect_timeout 5s;

    # Time to wait for upstream to send response headers (default: 60s)
    proxy_read_timeout 120s;

    # Time to wait for upstream to accept data from nginx (default: 60s)
    proxy_send_timeout 60s;

    proxy_pass http://backend;
}

# For long-running operations (file uploads, reports)
location /api/reports/ {
    proxy_read_timeout 600s;
    proxy_send_timeout 300s;
    proxy_pass http://backend;
}
```

### Avoid Global Timeout Increases

Set generous timeouts only on specific locations, not globally:

```nginx
# BAD — all routes get 10 min timeout
proxy_read_timeout 600s;

# GOOD — only long routes get extended timeout
location / {
    proxy_read_timeout 30s;
    proxy_pass http://backend;
}

location /api/export/ {
    proxy_read_timeout 600s;
    proxy_pass http://backend;
}
```

---

## Upstream Timeout Tuning

### Full Timeout Chain

```
Client → [client_body_timeout] → Nginx → [proxy_connect_timeout] → Upstream
                                       ← [proxy_read_timeout]    ←
       ← [send_timeout]        ←
```

### Recommended Production Values

```nginx
# Client-facing timeouts
client_header_timeout 15s;    # time to receive full request headers
client_body_timeout 30s;      # time between successive body reads
send_timeout 30s;             # time between successive write operations to client
keepalive_timeout 65s;        # keep idle connections open

# Upstream timeouts
proxy_connect_timeout 5s;     # fail fast if backend is down
proxy_read_timeout 30s;       # normal API calls
proxy_send_timeout 30s;       # sending request body to upstream

# FastCGI timeouts (PHP-FPM)
fastcgi_connect_timeout 5s;
fastcgi_read_timeout 60s;
fastcgi_send_timeout 30s;
```

### Timeout Interaction with Retry

```nginx
upstream backend {
    server 10.0.0.1:8080 max_fails=3 fail_timeout=30s;
    server 10.0.0.2:8080 max_fails=3 fail_timeout=30s;
}

location / {
    proxy_connect_timeout 3s;
    proxy_next_upstream error timeout http_502 http_503;
    proxy_next_upstream_timeout 10s;  # total time for all retry attempts
    proxy_next_upstream_tries 2;      # max retries
    proxy_pass http://backend;
}
```

**Warning:** `proxy_next_upstream` retries non-idempotent requests (POST, PUT) by default. Disable for unsafe methods:

```nginx
proxy_next_upstream error timeout http_502 non_idempotent;
# Or disable entirely for POSTs:
# Only retry on connect errors, not after data was sent
proxy_next_upstream error timeout;
```

---

## Buffer Overflow Errors

### Symptom: "upstream sent too big header"

```
upstream sent too big header while reading response header from upstream
```

Cause: Upstream response headers exceed `proxy_buffer_size`. Common with large cookies or auth tokens.

```nginx
# Increase header buffer (headers only)
proxy_buffer_size 16k;  # default is 4k or 8k depending on platform
```

### Symptom: "an upstream response is buffered to a temporary file"

```
an upstream response is buffered to a temporary file /var/cache/nginx/proxy_temp/...
```

Warning, not error. Response body exceeded `proxy_buffers` total. Fix:

```nginx
proxy_buffers 16 32k;        # 16 buffers × 32k = 512k in memory
proxy_busy_buffers_size 64k; # max sent to client while still reading from upstream
proxy_max_temp_file_size 0;  # disable temp files (returns 502 if buffer exceeded)
# Or increase temp file limit:
proxy_max_temp_file_size 1024m;
proxy_temp_path /var/cache/nginx/proxy_temp 1 2;
```

### Symptom: "client intended to send too large body"

```
client intended to send too large body: 52428800 bytes
```

```nginx
client_max_body_size 100m;  # increase upload limit (default 1m)
client_body_buffer_size 128k;  # buffer small bodies in memory

# For specific upload routes
location /upload {
    client_max_body_size 500m;
    proxy_pass http://upload_backend;
}
```

### Symptom: "too large request header" (414/400)

```
client sent too long URI
```

```nginx
large_client_header_buffers 4 32k;  # default is 4 8k
```

---

## SSL/TLS Handshake Failures

### Diagnosis

```bash
# Test SSL connection
openssl s_client -connect example.com:443 -servername example.com

# Check certificate chain
openssl s_client -connect example.com:443 -servername example.com 2>/dev/null | openssl x509 -noout -dates -subject -issuer

# Test specific TLS version
openssl s_client -connect example.com:443 -tls1_2
openssl s_client -connect example.com:443 -tls1_3

# Check nginx error log
grep -i "ssl" /var/log/nginx/error.log
```

### Common SSL Errors

**Certificate chain incomplete:**
```
SSL_do_handshake() failed ... certificate verify failed
```
Fix: Concatenate intermediate certificates:
```bash
cat domain.crt intermediate.crt root.crt > fullchain.pem
# Or let certbot handle it:
ssl_certificate /etc/letsencrypt/live/example.com/fullchain.pem;
```

**Private key mismatch:**
```
SSL: error:0B080074:x509 certificate routines:X509_check_private_key:key values mismatch
```
Verify:
```bash
# These two should produce the same modulus hash
openssl x509 -noout -modulus -in cert.pem | md5sum
openssl rsa -noout -modulus -in key.pem | md5sum
```

**OCSP stapling failure:**
```
OCSP_basic_verify() failed ... certificate status request failed
```
Fix: Ensure resolver is configured and can reach OCSP responder:
```nginx
resolver 1.1.1.1 8.8.8.8 valid=300s;
resolver_timeout 5s;
ssl_stapling on;
ssl_stapling_verify on;
ssl_trusted_certificate /etc/letsencrypt/live/example.com/chain.pem;
```

**SNI mismatch / wrong certificate served:**
```
No SNI support or hostname mismatch
```
Fix: Ensure `server_name` matches certificate SAN. Set a default SSL server:
```nginx
server {
    listen 443 ssl default_server;
    ssl_certificate /etc/ssl/default.crt;
    ssl_certificate_key /etc/ssl/default.key;
    return 444;  # close connection for unknown hosts
}
```

**DH parameter too small:**
```
SSL routines:ssl3_check_cert_and_algorithm:dh key too small
```
Fix:
```bash
openssl dhparam -out /etc/nginx/dhparam.pem 4096
```
```nginx
ssl_dhparam /etc/nginx/dhparam.pem;
```

---

## worker_connections Exhaustion

### Symptoms

```
worker_connections are not enough
socket() failed (24: Too many open files)
```

### Diagnosis

```bash
# Current connections per worker
ps aux | grep "nginx: worker"
# Count connections
ss -s
ss -tnp | grep nginx | wc -l

# Check file descriptor limits
cat /proc/$(pgrep -f "nginx: master")/limits | grep "Max open files"
# Per-worker fd usage
ls /proc/$(pgrep -f "nginx: worker" | head -1)/fd | wc -l
```

### Capacity Planning

Each client connection uses 1 fd. Each proxied connection uses 2 fds (client + upstream). Max capacity:

```
max_clients = worker_processes × worker_connections
max_proxied_clients = worker_processes × worker_connections / 2
```

### Fix

```nginx
# nginx.conf
worker_processes auto;          # match CPU cores
worker_rlimit_nofile 65535;     # fd limit per worker

events {
    worker_connections 16384;   # connections per worker
    multi_accept on;
    use epoll;
}
```

Also raise OS limits:
```bash
# /etc/security/limits.conf
nginx soft nofile 65535
nginx hard nofile 65535

# Or systemd override
# /etc/systemd/system/nginx.service.d/limits.conf
[Service]
LimitNOFILE=65535
```

### Monitoring

```bash
# Watch connection count in real time
watch -n 1 'ss -tnp | grep nginx | wc -l'

# Nginx stub_status module
location /nginx_status {
    stub_status;
    allow 127.0.0.1;
    deny all;
}
# Output: Active connections, accepts, handled, requests, reading, writing, waiting
```

---

## Memory Issues and Leaks

### Monitoring Memory Usage

```bash
# Per-worker memory
ps -eo pid,ppid,rss,vsz,comm | grep nginx

# Total nginx memory
ps -eo rss,comm | grep nginx | awk '{sum+=$1} END {print sum/1024 " MB"}'

# Watch over time
watch -n 5 'ps -eo pid,rss,comm | grep "nginx: worker" | awk "{print \$1, \$2/1024 \" MB\"}"'
```

### Common Memory Consumers

1. **Shared memory zones** — each `zone` in `limit_req_zone`, `proxy_cache_path`, `ssl_session_cache` allocates from shared memory.

```bash
# List all shared memory zones
nginx -T 2>/dev/null | grep -E "zone=|keys_zone="
```

2. **Proxy buffers** — per connection: `proxy_buffer_size + (proxy_buffers count × size)`.

```
Memory per proxied connection = 4k + (8 × 16k) = 132k
With 10,000 connections = 1.3 GB
```

3. **Large open_file_cache** — each entry uses ~400 bytes.

### Reducing Memory

```nginx
# Reduce proxy buffer memory
proxy_buffering off;        # for streaming/WebSocket (no buffer memory)
proxy_buffer_size 2k;       # minimal for small headers
proxy_buffers 4 4k;         # small buffers

# Limit cache memory
proxy_cache_path /var/cache/nginx levels=1:2
    keys_zone=cache:10m     # 10m ≈ 80,000 keys
    max_size=1g
    inactive=10m;

# Reduce shared dict sizes
limit_req_zone $binary_remote_addr zone=api:5m rate=10r/s;  # 5m not 50m
```

### Worker Process Recycling

If workers grow unbounded, recycle them:

```nginx
worker_shutdown_timeout 30s;  # forcefully terminate lingering workers after reload
```

Periodic reload via cron recycles workers:
```bash
# Recycle workers every 6 hours
0 */6 * * * /usr/sbin/nginx -s reload
```

---

## Log Analysis Techniques

### Essential One-Liners

```bash
# Top 20 client IPs
awk '{print $1}' /var/log/nginx/access.log | sort | uniq -c | sort -rn | head -20

# Status code distribution
awk '{print $9}' /var/log/nginx/access.log | sort | uniq -c | sort -rn

# 5xx errors with URLs
awk '$9 ~ /^5/ {print $9, $7}' /var/log/nginx/access.log | sort | uniq -c | sort -rn | head -20

# Requests per second (last 1000 lines)
tail -1000 /var/log/nginx/access.log | awk '{print $4}' | cut -d: -f1-3 | uniq -c

# Slowest requests (requires custom log format with $request_time)
awk -F'rt=' '{split($2,a," "); if(a[1]+0 > 1.0) print a[1], $0}' /var/log/nginx/access.log | sort -rn | head -20

# Top URLs by request count
awk '{print $7}' /var/log/nginx/access.log | sort | uniq -c | sort -rn | head -20

# Top User-Agents (bot detection)
awk -F'"' '{print $6}' /var/log/nginx/access.log | sort | uniq -c | sort -rn | head -20

# Bandwidth by IP
awk '{ip[$1]+=$10} END {for(i in ip) print ip[i], i}' /var/log/nginx/access.log | sort -rn | head -20

# 502/504 errors in the last hour
awk -v date="$(date -d '1 hour ago' '+%d/%b/%Y:%H')" '$4 ~ date && $9 ~ /^50[24]/' /var/log/nginx/access.log
```

### Error Log Patterns

```bash
# Group error types
grep -oP '\[\w+\]' /var/log/nginx/error.log | sort | uniq -c | sort -rn

# Upstream errors
grep "upstream" /var/log/nginx/error.log | grep -oP 'upstream \K[^,]+' | sort | uniq -c | sort -rn

# SSL errors
grep -i "ssl" /var/log/nginx/error.log | tail -20

# Permission errors
grep "denied\|permission\|forbidden" /var/log/nginx/error.log | tail -20
```

### JSON Log Format for Structured Analysis

```nginx
log_format json_log escape=json '{'
    '"time":"$time_iso8601",'
    '"remote_addr":"$remote_addr",'
    '"request":"$request",'
    '"status":$status,'
    '"body_bytes_sent":$body_bytes_sent,'
    '"request_time":$request_time,'
    '"upstream_response_time":"$upstream_response_time",'
    '"upstream_addr":"$upstream_addr",'
    '"http_user_agent":"$http_user_agent",'
    '"http_referer":"$http_referer",'
    '"cache_status":"$upstream_cache_status"'
'}';

access_log /var/log/nginx/access.json json_log;
```

Query with `jq`:
```bash
# Slow requests
cat /var/log/nginx/access.json | jq -r 'select(.request_time > 2) | "\(.request_time)s \(.request)"'

# 5xx errors
cat /var/log/nginx/access.json | jq -r 'select(.status >= 500) | "\(.status) \(.request) upstream=\(.upstream_addr)"'
```

---

## Debug Log Level

### Enable Debug Logging

```nginx
# Global (very verbose — can produce GB of logs)
error_log /var/log/nginx/debug.log debug;

# Per-server block
server {
    error_log /var/log/nginx/mysite-debug.log debug;
}

# Per-location (most targeted)
location /api/problematic-endpoint {
    error_log /var/log/nginx/endpoint-debug.log debug;
}
```

**Prerequisite:** nginx must be compiled with `--with-debug`. Check:
```bash
nginx -V 2>&1 | grep -- '--with-debug'
```

### Debug Specific Connections Only

```nginx
events {
    debug_connection 192.168.1.100;   # debug only this IP
    debug_connection 10.0.0.0/24;     # or this subnet
}
```

### What Debug Logs Show

- Full HTTP request/response headers
- Upstream connection attempts and failures
- SSL handshake details
- Location matching decisions
- Rewrite rule evaluation
- Variable values at each phase

### Temporary Debug with Signal

```bash
# Reopen log files (after changing error_log directive and reload)
nginx -s reopen

# Or use USR1 signal for log rotation
kill -USR1 $(cat /var/run/nginx.pid)
```

---

## System-Level Debugging (strace/tcpdump)

### strace — Trace System Calls

```bash
# Attach to running nginx worker (find PID first)
WORKER_PID=$(pgrep -f "nginx: worker" | head -1)

# Trace network-related syscalls
strace -p $WORKER_PID -e trace=network -f 2>&1 | head -200

# Trace file operations (permission issues)
strace -p $WORKER_PID -e trace=open,openat,stat,access -f 2>&1 | head -100

# Trace with timing (find slow syscalls)
strace -p $WORKER_PID -e trace=read,write,sendto,recvfrom -T -f 2>&1 | head -200

# Full trace to file (WARNING: huge output)
strace -p $WORKER_PID -f -o /tmp/nginx-strace.log -tt -T
```

### tcpdump — Capture Network Traffic

```bash
# Capture traffic between nginx and upstream on port 8080
tcpdump -i lo -A -s0 port 8080 -w /tmp/upstream.pcap

# Capture client-facing traffic on port 443
tcpdump -i eth0 -s0 port 443 -w /tmp/client.pcap

# Live HTTP inspection (non-SSL)
tcpdump -i any -A -s0 'port 80 and (((ip[2:2] - ((ip[0]&0xf)<<2)) - ((tcp[12]&0xf0)>>2)) != 0)'

# Filter by client IP
tcpdump -i eth0 -A host 192.168.1.100 and port 443

# Analyze with tshark
tshark -r /tmp/upstream.pcap -Y "http.response.code >= 500" -T fields -e http.response.code -e http.request.uri
```

### ss — Socket Statistics

```bash
# Nginx connections in various states
ss -tnp | grep nginx | awk '{print $1}' | sort | uniq -c

# TIME_WAIT connections (indicator of upstream churn)
ss -tn state time-wait | grep :8080 | wc -l

# Connections to each upstream server
ss -tnp | grep nginx | awk '{print $5}' | sort | uniq -c | sort -rn

# Socket buffer sizes
ss -tnm | grep -A1 nginx
```

---

## Common Misconfigurations

### add_header Inheritance

Inner blocks clear ALL parent `add_header` directives:

```nginx
# BAD — security headers disappear for /api/
server {
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;

    location /api/ {
        add_header X-Custom "value";  # clears parent headers!
        proxy_pass http://backend;
    }
}

# GOOD — use include for shared headers
server {
    include snippets/security-headers.conf;

    location /api/ {
        include snippets/security-headers.conf;  # re-include
        add_header X-Custom "value";
        proxy_pass http://backend;
    }
}
```

### if Is Evil (Mostly)

```nginx
# BAD — unpredictable behavior
location / {
    if ($request_method = POST) {
        proxy_pass http://write_backend;  # DOESN'T WORK as expected
    }
    proxy_pass http://read_backend;
}

# GOOD — use map + separate locations
map $request_method $rw_backend {
    POST    write_backend;
    PUT     write_backend;
    default read_backend;
}

location / {
    proxy_pass http://$rw_backend;
}
```

### try_files with proxy_pass

```nginx
# BAD — try_files and proxy_pass don't combine well
location / {
    try_files $uri $uri/ http://backend;  # WRONG — treats it as a file path
}

# GOOD — use named location
location / {
    try_files $uri $uri/ @backend;
}

location @backend {
    proxy_pass http://backend;
}
```

---

## Performance Diagnostics

### Quick Health Check

```bash
#!/bin/bash
echo "=== Nginx Status ==="
systemctl is-active nginx
nginx -t 2>&1

echo "=== Worker Info ==="
ps -eo pid,ppid,rss,vsz,%cpu,comm | head -1
ps -eo pid,ppid,rss,vsz,%cpu,comm | grep nginx

echo "=== Connection Count ==="
ss -tnp | grep nginx | awk '{print $1}' | sort | uniq -c

echo "=== File Descriptors ==="
for pid in $(pgrep -f "nginx: worker"); do
    echo "Worker $pid: $(ls /proc/$pid/fd 2>/dev/null | wc -l) fds"
done

echo "=== Recent Errors ==="
tail -5 /var/log/nginx/error.log
```

### Benchmarking

```bash
# Quick benchmark with wrk
wrk -t4 -c100 -d30s http://localhost/

# With specific headers
wrk -t4 -c100 -d30s -H "Authorization: Bearer token" http://localhost/api/

# ab (Apache Benchmark)
ab -n 10000 -c 100 http://localhost/

# Compare before/after config change
wrk -t4 -c100 -d30s http://localhost/ > before.txt
# ... make change, reload ...
wrk -t4 -c100 -d30s http://localhost/ > after.txt
diff before.txt after.txt
```
