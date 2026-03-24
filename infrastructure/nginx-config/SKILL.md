---
name: nginx-config
description: >
  Expert Nginx web server configuration assistant. Use when user needs nginx configuration,
  reverse proxy setup, load balancing, SSL/TLS termination, web server config, virtual host
  setup, upstream configuration, rate limiting, caching, gzip compression, security hardening,
  HTTP/2 or HTTP/3 setup, WebSocket proxying, nginx as API gateway, location block design,
  rewrite rules, try_files directives, error pages, worker tuning, or debugging nginx issues.
  NOT for Apache/Caddy/Traefik/HAProxy configuration. NOT for application-level routing or
  framework-specific middleware. NOT for DNS configuration or domain registration. NOT for
  firewall rules (iptables/nftables). NOT for container orchestration (use k8s skills instead).
---

# Nginx Configuration Skill

Generate production-grade Nginx configs. Validate with `nginx -t` before reload.
Use `nginx -T` to dump full effective config. Reload without downtime: `nginx -s reload`.

## Core Architecture

Event-driven, non-blocking. One master process manages workers. Config hierarchy:
`main` → `events` → `http` → `server` → `location`. Directives inherit downward unless overridden.

## Performance Tuning

```nginx
worker_processes auto;               # Match CPU cores
worker_rlimit_nofile 65535;          # FD limit per worker
events {
    worker_connections 4096;         # Max connections per worker
    multi_accept on;                 # Accept all pending connections
    use epoll;                       # Linux optimal event model
}
http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 15;
    keepalive_requests 1000;
    server_tokens off;               # Hide nginx version
    client_max_body_size 50m;
    client_body_buffer_size 128k;
    large_client_header_buffers 4 16k;
}
```

Max connections = `worker_processes × worker_connections`. Set `worker_rlimit_nofile` ≥ 2× worker_connections.

## Server Blocks (Virtual Hosts)

```nginx
server {
    listen 80;
    server_name example.com www.example.com;
    return 301 https://$host$request_uri;
}
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name example.com www.example.com;
    root /var/www/example.com/html;
    index index.html;
    ssl_certificate /etc/letsencrypt/live/example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/example.com/privkey.pem;
    include snippets/ssl-params.conf;
    include snippets/security-headers.conf;
    location / { try_files $uri $uri/ =404; }
}
```

Default catch-all: `server { listen 80 default_server; server_name _; return 444; }`

## Location Matching (Priority Order)

Evaluated in this exact order — memorize this:

1. **`= /path`** — Exact match. Highest priority. Stops immediately.
2. **`^~ /path`** — Preferential prefix. Skips all regex if matched.
3. **`~ regex`** — Case-sensitive regex. First match in config order wins.
4. **`~* regex`** — Case-insensitive regex. First match in config order wins.
5. **`/path`** — Standard prefix. Longest match, only if no regex matched.

```nginx
location = / { }              # Only "/"
location ^~ /static/ { }      # Prefix, skips regex
location ~ \.php$ { }         # Case-sensitive regex
location ~* \.(jpg|png)$ { }  # Case-insensitive regex
location /api/ { }            # Standard prefix
location / { }                # Default fallback
```

PITFALL: A regex overrides a longer prefix match. Use `^~` to prevent this.

## Reverse Proxy

```nginx
location /api/ {
    proxy_pass http://127.0.0.1:3000/;   # Trailing slash strips /api/ prefix
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_connect_timeout 5s;
    proxy_send_timeout 60s;
    proxy_read_timeout 60s;
    proxy_buffer_size 64k;
    proxy_buffers 8 64k;
    proxy_busy_buffers_size 128k;
}
```

CRITICAL: `proxy_pass http://backend/` (trailing slash) strips location prefix.
`proxy_pass http://backend` (no slash) preserves full URI.

### WebSocket Proxy

```nginx
location /ws/ {
    proxy_pass http://websocket_backend;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_read_timeout 86400s;
    proxy_send_timeout 86400s;
}
```

## SSL/TLS Configuration

```nginx
# /etc/nginx/snippets/ssl-params.conf
ssl_protocols TLSv1.2 TLSv1.3;
ssl_ciphers 'ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305';
ssl_prefer_server_ciphers off;
ssl_session_cache shared:SSL:10m;
ssl_session_timeout 1d;
ssl_session_tickets off;
ssl_stapling on;
ssl_stapling_verify on;
ssl_trusted_certificate /etc/letsencrypt/live/example.com/chain.pem;
resolver 1.1.1.1 8.8.8.8 valid=300s;
resolver_timeout 5s;
add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
```

Certbot renewal: `certbot renew --nginx --quiet` via cron/systemd timer.

## Load Balancing

```nginx
upstream app_cluster {
    # Algorithm (uncomment one): least_conn; | ip_hash; | hash $request_uri;
    server 10.0.0.101:8080 weight=3 max_fails=3 fail_timeout=30s;
    server 10.0.0.102:8080 weight=2 max_fails=3 fail_timeout=30s;
    server 10.0.0.103:8080 backup;
    keepalive 32;
}
server {
    location / {
        proxy_pass http://app_cluster;
        proxy_http_version 1.1;
        proxy_set_header Connection "";    # Required for upstream keepalive
    }
}
```

`max_fails`/`fail_timeout` = passive health checks. Active checks require Nginx Plus.

## Caching

### Proxy Cache

```nginx
proxy_cache_path /var/cache/nginx levels=1:2 keys_zone=cache:10m max_size=1g
    inactive=60m use_temp_path=off;

location / {
    proxy_cache cache;
    proxy_cache_valid 200 302 1h;
    proxy_cache_valid 404 1m;
    proxy_cache_key "$scheme$request_method$host$request_uri";
    proxy_cache_use_stale error timeout updating http_500 http_502 http_503;
    proxy_cache_lock on;
    add_header X-Cache-Status $upstream_cache_status;
    proxy_pass http://backend;
}
```

### FastCGI Cache (PHP)

```nginx
fastcgi_cache_path /var/cache/nginx/fcgi levels=1:2 keys_zone=fcgi:10m max_size=512m;

set $skip_cache 0;
if ($request_method = POST) { set $skip_cache 1; }
if ($request_uri ~* "/admin") { set $skip_cache 1; }

location ~ \.php$ {
    fastcgi_cache fcgi;
    fastcgi_cache_valid 200 10m;
    fastcgi_cache_bypass $skip_cache;
    fastcgi_no_cache $skip_cache;
    fastcgi_pass unix:/run/php/php-fpm.sock;
    include fastcgi_params;
}
```

Cache purging (requires `ngx_cache_purge`):
```nginx
location ~ /purge(/.*) {
    allow 127.0.0.1; deny all;
    proxy_cache_purge cache "$scheme$request_method$host$1";
}
```

## Rate Limiting

```nginx
http {
    limit_req_zone $binary_remote_addr zone=general:10m rate=10r/s;
    limit_req_zone $binary_remote_addr zone=login:10m rate=1r/s;
    limit_conn_zone $binary_remote_addr zone=addr:10m;
}
location /api/ {
    limit_req zone=general burst=20 nodelay;
    limit_req_status 429;
    proxy_pass http://backend;
}
location /login {
    limit_req zone=login burst=5 nodelay;
    limit_conn addr 5;
    limit_req_status 429;
}
```

`burst=N nodelay` — process N excess requests immediately, then enforce rate.
`burst=N` (no nodelay) — queue excess with delay. 10m zone ≈ 160,000 IPs.

## Gzip Compression

```nginx
gzip on;
gzip_vary on;
gzip_proxied any;
gzip_comp_level 5;
gzip_min_length 256;
gzip_types text/plain text/css text/xml text/javascript
    application/json application/javascript application/xml
    application/xml+rss application/atom+xml
    font/opentype image/svg+xml;
```

Never gzip images/video/archives. For pre-compressed files: `gzip_static on;`.

## Security Headers

```nginx
# /etc/nginx/snippets/security-headers.conf
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-Content-Type-Options "nosniff" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header Permissions-Policy "camera=(), microphone=(), geolocation=()" always;
add_header Content-Security-Policy "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; frame-ancestors 'self';" always;
```

PITFALL: `add_header` in a child block removes ALL parent `add_header` directives.
Always `include` header snippets in every location that adds its own headers.

## Access Control

```nginx
location /admin/ {
    allow 10.0.0.0/8;
    deny all;
    auth_basic "Restricted";
    auth_basic_user_file /etc/nginx/.htpasswd;
}
# satisfy any = OR (IP or auth), satisfy all = AND (IP and auth)
```

## Logging

```nginx
log_format json escape=json '{'
    '"time":"$time_iso8601","remote_addr":"$remote_addr",'
    '"method":"$request_method","uri":"$request_uri",'
    '"status":$status,"bytes":$body_bytes_sent,'
    '"request_time":$request_time,"upstream_time":"$upstream_response_time"'
    '}';

# Skip health check logs
map $request_uri $loggable { ~*^/health 0; default 1; }
access_log /var/log/nginx/access.log json if=$loggable;
error_log /var/log/nginx/error.log warn;
```

## Rewrite Rules

```nginx
rewrite ^/old-page$ /new-page permanent;          # 301
rewrite ^/promo$ /sale redirect;                   # 302
rewrite ^/user/(\d+)$ /api/users/$1 last;          # Re-evaluate location
rewrite ^/download/(.*)$ /files/$1 break;          # Stay in current location
```

`last` restarts location matching. `break` stops rewrite processing.
Prefer `return 301` over `rewrite` for simple redirects (faster).

## try_files

```nginx
location / { try_files $uri $uri/ /index.html; }                # SPA
location / { try_files $uri $uri/ /index.php?$query_string; }   # PHP
location / { try_files $uri @backend; }                          # Named fallback
location @backend { proxy_pass http://127.0.0.1:8080; }
```

Checks left-to-right. Last arg = fallback (URI for redirect or `=404`).

## Error Pages

```nginx
error_page 404 /custom-404.html;
error_page 500 502 503 504 /custom-50x.html;
location = /custom-404.html { root /var/www/errors; internal; }
location = /custom-50x.html { root /var/www/errors; internal; }
# For proxied errors: proxy_intercept_errors on;
```

## HTTP/2 and HTTP/3

```nginx
server {
    listen 443 ssl http2;
    listen 443 quic reuseport;                    # HTTP/3, nginx 1.25+
    add_header Alt-Svc 'h3=":443"; ma=86400' always;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_early_data on;                            # 0-RTT (beware replay attacks)
}
```

## Nginx as API Gateway

```nginx
upstream api_v1 { server 10.0.0.10:8080; }
upstream api_v2 { server 10.0.0.20:8080; }
map $uri $api_upstream {
    ~^/api/v1/ api_v1;
    ~^/api/v2/ api_v2;
    default    api_v2;
}
server {
    location /api/ {
        if ($request_method = OPTIONS) {
            add_header Access-Control-Allow-Origin "$http_origin";
            add_header Access-Control-Allow-Methods "GET, POST, PUT, DELETE, OPTIONS";
            add_header Access-Control-Allow-Headers "Authorization, Content-Type";
            add_header Access-Control-Max-Age 86400;
            return 204;
        }
        limit_req zone=api burst=50 nodelay;
        proxy_pass http://$api_upstream;
        proxy_set_header Host $host;
        proxy_set_header X-Request-ID $request_id;
        client_max_body_size 10m;
    }
}
```

## Common Pitfalls

### "If Is Evil"
Avoid `if` inside `location`. It creates implicit nested locations with unpredictable behavior.
Safe uses: `return`, `rewrite`, variable assignment. Use `map` for conditional logic instead.

```nginx
# BAD
location / {
    if ($request_uri ~* "^/old") { proxy_pass http://legacy; }
    proxy_pass http://new;
}
# GOOD — use map
map $request_uri $backend { ~^/old legacy; default new_backend; }
location / { proxy_pass http://$backend; }
```

### Trailing Slash in proxy_pass
`proxy_pass http://backend/;` (slash) strips location prefix. Without slash, preserves it.

### add_header Inheritance
Child block `add_header` replaces ALL parent headers. Use `include` snippets everywhere.

### Debugging
`nginx -t` — syntax check. `nginx -T` — dump full config. `curl -I` — verify headers.
`tail -f /var/log/nginx/error.log` — watch errors in real time.

## Input → Output Examples

**"Reverse proxy Node.js on port 3000 with SSL"** → Generate: HTTP→HTTPS redirect server block,
SSL server block with cert paths, proxy_pass to 127.0.0.1:3000 with all headers, ssl snippet.

**"Rate limit my login endpoint"** → Generate: `limit_req_zone` in http, `limit_req` with
burst in location /login, 429 status, connection limit.

**"Load balance 3 backends"** → Generate: `upstream` with health params, proxy_pass,
keepalive, algorithm recommendation based on use case.

**"Location not matching"** → Explain 5-level priority, identify prefix vs regex conflicts,
suggest `^~` or `=`, recommend `nginx -T` to inspect effective config.

## Validation Checklist

1. `nginx -t` passes
2. SSL certs exist at specified paths
3. Upstream backends reachable
4. `worker_rlimit_nofile` ≥ 2 × `worker_connections`
5. `client_max_body_size` matches app needs
6. `add_header` not silently dropped by child blocks
7. `curl -I` confirms headers, redirects, SSL
