---
name: nginx-advanced
description: >
  Expert guidance for Nginx web server configuration and optimization.
  Triggers: Nginx configuration, nginx reverse proxy, nginx load balancing,
  nginx location block, nginx upstream, nginx SSL, nginx TLS, nginx rate limiting,
  nginx caching, nginx proxy_cache, nginx fastcgi_cache, nginx gzip, nginx brotli,
  nginx WebSocket, nginx HTTP/2, nginx HTTP/3, nginx QUIC, nginx map directive,
  nginx try_files, nginx rewrite, nginx stream module, nginx security headers,
  nginx worker_processes, nginx keepalive, nginx limit_req, nginx limit_conn,
  nginx access control, nginx performance tuning, nginx OCSP stapling, nginx HSTS.
  NOT for Apache httpd, Caddy, Traefik, HAProxy, Envoy, or general web server
  concepts without Nginx context.
---

# Nginx Advanced Configuration Guide

## Performance Tuning Baseline

Nginx uses an event-driven, non-blocking architecture. Master process manages workers.

```nginx
worker_processes auto;             # match CPU cores
worker_rlimit_nofile 65535;
events {
    worker_connections 4096;
    use epoll;
    multi_accept on;
}
http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    keepalive_requests 1000;
    types_hash_max_size 2048;
    server_tokens off;
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
}
```

## Location Match Priority (highest → lowest)

1. `= /exact` — exact match  2. `^~ /prefix` — preferential prefix  3. `~ /regex` — case-sensitive regex  4. `~* /regex` — case-insensitive regex  5. `/prefix` — longest prefix wins

```nginx
server {
    listen 80;
    server_name example.com;
    location = /health { return 200 "ok\n"; add_header Content-Type text/plain; }
    location ^~ /static/ { alias /var/www/static/; expires 30d; add_header Cache-Control "public, immutable"; }
    location ~ \.php$ { include fastcgi_params; fastcgi_pass unix:/run/php/php-fpm.sock; }
    location / { root /var/www/html; try_files $uri $uri/ /index.html; }
}
```

### try_files Patterns

```nginx
location / { try_files $uri $uri/ /index.html; }          # SPA fallback
location / { try_files $uri $uri/ @backend; }              # named fallback
location @backend { proxy_pass http://app_server; }
location /downloads/ { try_files $uri =404; }              # strict file serving
```

## Reverse Proxy

```nginx
upstream backend {
    server 10.0.0.1:8080;
    server 10.0.0.2:8080;
    keepalive 32;
}
server {
    listen 80;
    server_name api.example.com;
    location / {
        proxy_pass http://backend;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Connection "";
        proxy_connect_timeout 5s;
        proxy_read_timeout 60s;
        proxy_send_timeout 30s;
        proxy_buffering on;
        proxy_buffer_size 4k;
        proxy_buffers 8 4k;
    }
}
```

## Load Balancing

```nginx
upstream app         { server 10.0.0.1:8080 weight=3; server 10.0.0.2:8080; server 10.0.0.3:8080 backup; }
upstream app_least   { least_conn; server 10.0.0.1:8080; server 10.0.0.2:8080; }
upstream app_sticky  { ip_hash; server 10.0.0.1:8080; server 10.0.0.2:8080; }
upstream app_hash    { hash $request_uri consistent; server 10.0.0.1:8080; server 10.0.0.2:8080; }
upstream resilient   { server 10.0.0.1:8080 max_fails=3 fail_timeout=30s; server 10.0.0.2:8080 max_fails=3 fail_timeout=30s; }
```

Methods: **round-robin** (default, supports `weight`), **least_conn**, **ip_hash** (session persistence), **hash** (consistent hashing on arbitrary key). Use `backup` for failover, `max_fails`/`fail_timeout` for passive health checks.

## SSL/TLS Termination

```nginx
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name example.com;
    ssl_certificate /etc/letsencrypt/live/example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/example.com/privkey.pem;
    ssl_trusted_certificate /etc/letsencrypt/live/example.com/chain.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers 'TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384';
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:50m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    # OCSP Stapling
    ssl_stapling on;
    ssl_stapling_verify on;
    resolver 1.1.1.1 8.8.8.8 valid=300s;
    resolver_timeout 5s;
    # HSTS
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
}
server { listen 80; server_name example.com; return 301 https://$host$request_uri; }
```

## HTTP/2 and HTTP/3 (QUIC)

```nginx
server {
    listen 443 ssl;
    listen 443 quic reuseport;          # HTTP/3 over UDP
    listen [::]:443 ssl;
    listen [::]:443 quic reuseport;
    http2 on;                           # Nginx 1.25.1+ directive
    ssl_protocols TLSv1.2 TLSv1.3;     # QUIC requires TLS 1.3
    ssl_early_data on;                  # 0-RTT
    quic_gso on;
    quic_retry on;
    add_header Alt-Svc 'h3=":443"; ma=86400' always;
}
```

Nginx 1.25.1+ uses `http2 on;` instead of `listen ... http2`. Firewall must allow UDP 443 for QUIC.

## Rate Limiting

```nginx
http {
    limit_req_zone $binary_remote_addr zone=general:10m rate=10r/s;
    limit_req_zone $binary_remote_addr zone=login:10m rate=2r/m;
    limit_conn_zone $binary_remote_addr zone=connlimit:10m;
    limit_req_status 429;
    limit_conn_status 429;
    server {
        location / {
            limit_req zone=general burst=20 nodelay;
            proxy_pass http://backend;
        }
        location /login {
            limit_req zone=login burst=2 nodelay;
            limit_conn connlimit 3;
            proxy_pass http://backend;
        }
        location /downloads/ {
            limit_conn connlimit 2;
            limit_rate 500k;
            root /var/www;
        }
    }
}
```

Memory: 1MB zone ≈ 16,000 IPv4 addresses. `burst` = queue size. `nodelay` processes burst immediately; omit to smooth traffic.

### Whitelist Trusted IPs from Rate Limiting

```nginx
geo $limit { default 1; 10.0.0.0/8 0; 192.168.0.0/16 0; }
map $limit $limit_key { 0 ""; 1 $binary_remote_addr; }
limit_req_zone $limit_key zone=ratelimit:10m rate=5r/s;
```

## Caching

### Proxy Cache

```nginx
proxy_cache_path /var/cache/nginx/proxy levels=1:2 keys_zone=PROXY:100m inactive=1h max_size=1g use_temp_path=off;
server {
    location /api/ {
        proxy_pass http://backend;
        proxy_cache PROXY;
        proxy_cache_valid 200 1h;
        proxy_cache_valid 404 10m;
        proxy_cache_key "$scheme$request_method$host$request_uri";
        proxy_cache_use_stale error timeout updating http_500 http_503;
        proxy_cache_lock on;
        proxy_cache_bypass $http_cache_control;
        add_header X-Cache-Status $upstream_cache_status always;
    }
}
```

### FastCGI Cache

```nginx
fastcgi_cache_path /var/cache/nginx/fcgi levels=1:2 keys_zone=FCGI:100m inactive=1h max_size=1g;
server {
    set $skip_cache 0;
    if ($request_method = POST) { set $skip_cache 1; }
    if ($request_uri ~* "/admin|/cart|/checkout") { set $skip_cache 1; }
    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_pass unix:/run/php/php-fpm.sock;
        fastcgi_cache FCGI;
        fastcgi_cache_valid 200 30m;
        fastcgi_cache_bypass $skip_cache;
        fastcgi_no_cache $skip_cache;
        fastcgi_cache_use_stale error timeout updating;
        add_header X-FastCGI-Cache $upstream_cache_status always;
    }
}
```

## Compression

```nginx
# Gzip (built-in)
gzip on;
gzip_vary on;
gzip_proxied any;
gzip_comp_level 5;
gzip_min_length 256;
gzip_types text/plain text/css application/json application/javascript
           text/xml application/xml application/xml+rss text/javascript
           image/svg+xml application/wasm;
# Brotli (requires ngx_brotli module)
brotli on;
brotli_comp_level 6;
brotli_types text/plain text/css application/json application/javascript
             text/xml application/xml application/xml+rss text/javascript
             image/svg+xml application/wasm;
```

## Security Headers

```nginx
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-Content-Type-Options "nosniff" always;
add_header X-XSS-Protection "0" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header Content-Security-Policy "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline';" always;
add_header Permissions-Policy "camera=(), microphone=(), geolocation=()" always;
server_tokens off;
more_clear_headers Server;  # requires headers-more module
```

## WebSocket Proxying

```nginx
map $http_upgrade $connection_upgrade { default upgrade; "" close; }
server {
    location /ws/ {
        proxy_pass http://10.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $host;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
```

## Map Directive

```nginx
map $uri $api_backend      { ~^/api/v1/ backend_v1; ~^/api/v2/ backend_v2; default backend_v1; }
map $http_user_agent $is_mobile { default 0; ~*mobile 1; ~*android 1; }
map $remote_addr $maintenance   { default 1; 10.0.0.50 0; }
```

`map` evaluates lazily (only when variable is used). Place in `http {}` block. Supports regex (`~`, `~*`), exact strings, and `default`.

## Rewrite Rules

```nginx
rewrite ^/old-page$ /new-page permanent;       # 301 redirect
rewrite ^/user/(\d+)$ /profile?id=$1 last;     # internal rewrite
rewrite ^/(.*)/$ /$1 permanent;                # remove trailing slash
if ($host = 'example.com') { return 301 https://www.example.com$request_uri; }
```

Flags: `last` — restart location match; `break` — stop rewriting; `redirect` — 302; `permanent` — 301. Prefer `return` over `rewrite` for simple redirects.

## Access Control

```nginx
# IP-based
location /admin/ { allow 10.0.0.0/8; allow 192.168.1.0/24; deny all; proxy_pass http://backend; }
# Basic auth
location /internal/ { auth_basic "Restricted"; auth_basic_user_file /etc/nginx/.htpasswd; proxy_pass http://backend; }
# Subrequest auth (JWT/token validation)
location /api/ {
    auth_request /auth;
    auth_request_set $user $upstream_http_x_user;
    proxy_set_header X-User $user;
    proxy_pass http://backend;
}
location = /auth {
    internal;
    proxy_pass http://auth-service:8080/validate;
    proxy_pass_request_body off;
    proxy_set_header Content-Length "";
    proxy_set_header X-Original-URI $request_uri;
}
```

## Logging

```nginx
log_format main '$remote_addr - $remote_user [$time_local] "$request" $status $body_bytes_sent '
                '"$http_referer" "$http_user_agent" rt=$request_time urt=$upstream_response_time '
                'cache=$upstream_cache_status';
log_format json escape=json '{"time":"$time_iso8601","addr":"$remote_addr","method":"$request_method",'
                '"uri":"$request_uri","status":$status,"bytes":$body_bytes_sent,'
                '"rt":$request_time,"urt":"$upstream_response_time","cache":"$upstream_cache_status"}';
access_log /var/log/nginx/access.log main buffer=32k flush=5s;
error_log /var/log/nginx/error.log warn;
location = /health { access_log off; return 200 "ok"; }
```

## Stream Module (TCP/UDP Proxy)

Defined at top-level `nginx.conf`, outside `http {}`.

```nginx
stream {
    upstream mysql_backend { server 10.0.0.1:3306; server 10.0.0.2:3306 backup; }
    upstream dns_backend   { server 10.0.0.1:53; }
    server { listen 3306; proxy_pass mysql_backend; proxy_connect_timeout 5s; proxy_timeout 300s; }
    server { listen 5353 udp; proxy_pass dns_backend; proxy_responses 1; proxy_timeout 10s; }
    server {
        listen 5432 ssl;
        ssl_certificate /etc/nginx/ssl/cert.pem;
        ssl_certificate_key /etc/nginx/ssl/key.pem;
        proxy_pass 10.0.0.1:5432;
    }
}
```

## Examples: Input → Output

### Example 1: "Proxy Node.js app with WebSocket and SSL"

**Input**: Node.js on port 3000, SSL + WebSocket at /ws  
**Output**:
```nginx
map $http_upgrade $connection_upgrade { default upgrade; "" close; }
server {
    listen 443 ssl; http2 on;
    server_name app.example.com;
    ssl_certificate /etc/ssl/app.pem;
    ssl_certificate_key /etc/ssl/app.key;
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
    location /ws {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_read_timeout 3600s;
    }
}
```

### Example 2: "Rate-limit API to 100 req/min, cache GET responses 5min"

**Input**: Backend upstream `api_servers`, rate limit per IP, cache 200s  
**Output**:
```nginx
limit_req_zone $binary_remote_addr zone=api:10m rate=100r/m;
proxy_cache_path /var/cache/nginx/api levels=1:2 keys_zone=API:50m inactive=10m max_size=500m;
server {
    listen 80;
    location /api/ {
        limit_req zone=api burst=50 nodelay;
        proxy_pass http://api_servers;
        proxy_cache API;
        proxy_cache_valid 200 5m;
        proxy_cache_methods GET HEAD;
        proxy_cache_key "$request_method$request_uri";
        add_header X-Cache $upstream_cache_status;
    }
}
```

### Example 3: "Load-balance 3 backends with sticky sessions"

**Input**: Three servers, session affinity, mark down after 2 failures  
**Output**:
```nginx
upstream app {
    ip_hash;
    server 10.0.1.1:8080 max_fails=2 fail_timeout=30s;
    server 10.0.1.2:8080 max_fails=2 fail_timeout=30s;
    server 10.0.1.3:8080 max_fails=2 fail_timeout=30s;
}
server {
    listen 80;
    location / {
        proxy_pass http://app;
        proxy_next_upstream error timeout http_502 http_503;
        proxy_next_upstream_tries 2;
    }
}
```

## Reference Documents

In-depth guides in `references/`:

| File | Topics |
|------|--------|
| [`advanced-patterns.md`](references/advanced-patterns.md) | Dynamic upstreams with Lua/njs, content-based routing, A/B testing (`split_clients`), canary deployments, `auth_request` subrequests, mirror module, geo module, `map` with regex, `sub_filter`, request/response manipulation with njs |
| [`troubleshooting.md`](references/troubleshooting.md) | 502/504/413 errors, `error_log` debug levels, `stub_status`, request tracing, connection limits, buffer tuning, `proxy_pass` trailing slash pitfalls, DNS resolution with `resolver`, upstream keepalive issues, graceful reload vs restart |
| [`security-hardening.md`](references/security-hardening.md) | SSL/TLS best practices (Mozilla profiles), certificate automation (certbot/ACME), DDoS mitigation, WAF with ModSecurity/njs, bot detection, IP allowlists/denylists, hiding server version, Content-Security-Policy headers, CORS configuration |

## Scripts

Operational scripts in `scripts/` (all `chmod +x`):

| Script | Purpose |
|--------|---------|
| [`generate-ssl-config.sh`](scripts/generate-ssl-config.sh) | Generate SSL config following Mozilla Modern or Intermediate profile. Supports `--profile`, `--domain`, `--dhparam` flags |
| [`nginx-config-test.sh`](scripts/nginx-config-test.sh) | Validate nginx config and audit for 9 categories of misconfigurations: security, performance, SSL/TLS, proxy, logging, rate limiting, timeouts, permissions, and sensitive file exposure |
| [`log-analyzer.sh`](scripts/log-analyzer.sh) | Parse nginx access logs for top IPs, status codes, slow requests, bandwidth, user agents, and error URIs. Supports `--slow`, `--status`, `--ip`, `--section` filters |

## Assets & Templates

Production-ready config templates in `assets/`:

| File | Description |
|------|-------------|
| [`reverse-proxy-template.conf`](assets/reverse-proxy-template.conf) | Full reverse proxy: SSL termination, security headers, rate limiting, static asset serving, proxy buffering, error pages |
| [`load-balancer-template.conf`](assets/load-balancer-template.conf) | Load balancer with round-robin, least_conn, ip_hash, and consistent hash upstreams, health checks, WebSocket support |
| [`ssl-params.conf`](assets/ssl-params.conf) | Standalone SSL parameters file (Mozilla Intermediate) for `include` in server blocks |
| [`docker-compose-nginx.yml`](assets/docker-compose-nginx.yml) | Docker Compose with Nginx proxy, two app backends, Certbot auto-renewal, log rotation |

### njs Scripting Examples

JavaScript examples for the Nginx njs module in `assets/njs-examples/`:

| File | Capabilities |
|------|-------------|
| [`auth.js`](assets/njs-examples/auth.js) | JWT validation, JWT subject extraction, API key authentication |
| [`routing.js`](assets/njs-examples/routing.js) | Tenant-based routing, API version routing, body-based routing, geographic routing, canary deployment |
| [`transform.js`](assets/njs-examples/transform.js) | Trace ID generation, request enrichment, sensitive data redaction, XML-to-JSON conversion, dynamic CORS headers |
