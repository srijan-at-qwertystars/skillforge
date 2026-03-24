---
name: nginx-advanced
description: >
  Advanced Nginx configuration skill for production deployments. Use when: nginx config, nginx reverse proxy,
  nginx load balancer, nginx SSL/TLS, nginx rate limiting, nginx caching, nginx location block, nginx upstream,
  nginx WebSocket, nginx HTTP/2, nginx HTTP/3, nginx security headers, nginx performance tuning, nginx hardening,
  nginx proxy_pass, nginx worker_processes, nginx fastcgi_cache, nginx proxy_cache, nginx upstream health check,
  nginx keepalive, nginx gzip, nginx server block, nginx map directive, nginx rewrite rules, nginx buffer tuning.
  Do NOT use for: Apache httpd config, Caddy server setup, Traefik proxy routing, HAProxy configuration,
  basic nginx install or package management, Docker networking unrelated to nginx, DNS configuration,
  firewall rules (iptables/nftables), certbot standalone usage without nginx context.
---

# Advanced Nginx Configuration

## File Organization

Structure configs modularly. Never put everything in one monolithic `nginx.conf`.

```
/etc/nginx/
├── nginx.conf              # Global settings only
├── conf.d/                 # Drop-in server blocks (*.conf auto-included)
│   ├── example.com.conf
│   └── api.example.com.conf
├── snippets/               # Reusable partial configs
│   ├── ssl-params.conf
│   ├── proxy-params.conf
│   └── security-headers.conf
└── sites-enabled/          # Symlinks to sites-available (Debian-style)
```

## Reverse Proxy

Always pass real client information and use HTTP/1.1 to the backend.

```nginx
# snippets/proxy-params.conf
proxy_http_version 1.1;
proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header Connection "";
proxy_connect_timeout 5s;
proxy_send_timeout 60s;
proxy_read_timeout 60s;
proxy_buffering on;
proxy_buffer_size 4k;
proxy_buffers 8 16k;

# Usage
location / {
    proxy_pass http://backend;
    include snippets/proxy-params.conf;
}
```

Trailing slash matters in `proxy_pass`: `proxy_pass http://backend/` strips the matched location prefix; `proxy_pass http://backend` preserves it.

## Load Balancing

```nginx
# Round-robin (default) — even distribution
upstream backend_rr {
    server 10.0.0.1:8080;
    server 10.0.0.2:8080;
    server 10.0.0.3:8080 backup;  # only when others are down
}

# Least connections — best for varying request durations
upstream backend_lc {
    least_conn;
    server 10.0.0.1:8080 weight=3;  # receives 3x traffic
    server 10.0.0.2:8080;
}

# IP hash — session persistence without cookies
upstream backend_ip {
    ip_hash;
    server 10.0.0.1:8080;
    server 10.0.0.2:8080;
    server 10.0.0.3:8080 down;  # temporarily removed
}

# Consistent hashing — minimal redistribution on topology change
upstream backend_hash {
    hash $request_uri consistent;
    server 10.0.0.1:8080;
    server 10.0.0.2:8080;
}
```

Set failure detection on all upstreams:

```nginx
server 10.0.0.1:8080 max_fails=3 fail_timeout=30s;
```

Keep connections alive to upstreams to avoid TCP handshake overhead:

```nginx
upstream backend {
    server 10.0.0.1:8080;
    keepalive 32;  # idle connections per worker
}
location / {
    proxy_pass http://backend;
    proxy_http_version 1.1;
    proxy_set_header Connection "";  # required for keepalive
}
```

## SSL/TLS Termination and Optimization

```nginx
# snippets/ssl-params.conf
ssl_protocols TLSv1.2 TLSv1.3;
ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384';
ssl_prefer_server_ciphers off;  # let client choose with TLS 1.3
ssl_session_cache shared:SSL:50m;
ssl_session_timeout 1d;
ssl_session_tickets off;  # disable for forward secrecy
ssl_stapling on;
ssl_stapling_verify on;
resolver 1.1.1.1 8.8.8.8 valid=300s;
resolver_timeout 5s;

# Server block
server {
    listen 443 ssl http2;
    ssl_certificate /etc/letsencrypt/live/example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/example.com/privkey.pem;
    include snippets/ssl-params.conf;
}

# Redirect HTTP to HTTPS
server {
    listen 80;
    server_name example.com;
    return 301 https://$host$request_uri;
}
```

## Rate Limiting

Define zones in the `http` block; apply in `server`/`location`.

```nginx
# http context
limit_req_zone $binary_remote_addr zone=api_limit:10m rate=10r/s;
limit_req_zone $binary_remote_addr zone=login_limit:10m rate=1r/s;
limit_conn_zone $binary_remote_addr zone=conn_limit:10m;

# Apply
location /api/ {
    limit_req zone=api_limit burst=20 nodelay;
    limit_req_status 429;
    proxy_pass http://backend;
}

location /login {
    limit_req zone=login_limit burst=5;
    limit_conn conn_limit 5;  # max 5 concurrent connections per IP
    proxy_pass http://backend;
}
```

- `burst` queues excess requests up to N; `nodelay` processes burst immediately.
- Use `$binary_remote_addr` (16 bytes) not `$remote_addr` (7-15 bytes variable) for memory efficiency.
- Behind a CDN/LB, rate-limit on `$http_x_forwarded_for` or a custom key.

## Caching

### Proxy Cache

```nginx
# http context
proxy_cache_path /var/cache/nginx/proxy
    levels=1:2
    keys_zone=proxy_cache:100m
    max_size=10g
    inactive=60m
    use_temp_path=off;

location /api/ {
    proxy_cache proxy_cache;
    proxy_cache_valid 200 10m;
    proxy_cache_valid 404 1m;
    proxy_cache_key "$scheme$request_method$host$request_uri";
    proxy_cache_use_stale error timeout updating http_500 http_502 http_503;
    proxy_cache_lock on;           # coalesce simultaneous requests for same key
    proxy_cache_bypass $http_cache_control;
    add_header X-Cache-Status $upstream_cache_status;
    proxy_pass http://backend;
}
```

### FastCGI Cache (PHP/Python)

```nginx
fastcgi_cache_path /var/cache/nginx/fcgi
    levels=1:2 keys_zone=fcgi_cache:100m inactive=60m;

location ~ \.php$ {
    fastcgi_cache fcgi_cache;
    fastcgi_cache_valid 200 5m;
    fastcgi_cache_key "$scheme$request_method$host$request_uri";
    fastcgi_pass unix:/run/php/php-fpm.sock;
    include fastcgi_params;
}
```

## Location Block Matching Order

Nginx evaluates locations in this fixed priority:

1. `= /exact` — exact match, stops immediately
2. `^~ /prefix` — preferential prefix, stops before regex
3. `~ regex` / `~* regex_ci` — first matching regex in config order
4. `/prefix` — longest prefix match (used if no regex matches)

```nginx
location = / { }           # only "/"
location ^~ /static/ { }   # any /static/* — skips regex check
location ~ \.php$ { }      # regex: PHP files
location ~* \.(jpg|png)$ {} # regex case-insensitive: images
location /api/ { }          # prefix: /api/* (if no regex matches)
location / { }              # default fallback
```

Anti-pattern: placing a regex above a `^~` prefix and expecting the prefix to win. The `^~` always beats regex.

## Upstream Health Checks

OSS Nginx uses passive checks only. Configure failure thresholds:

```nginx
upstream backend {
    server 10.0.0.1:8080 max_fails=3 fail_timeout=30s;
    server 10.0.0.2:8080 max_fails=3 fail_timeout=30s;
}
```

- After `max_fails` failures within `fail_timeout`, the server is marked unavailable for `fail_timeout` seconds.
- NGINX Plus adds active health checks: `health_check interval=5s fails=3 passes=2;`
- For OSS active checks, use the `nginx_upstream_check_module` third-party module.

## WebSocket Proxying

```nginx
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

upstream ws_backend {
    server 10.0.0.1:3000;
    server 10.0.0.2:3000;
}

location /ws/ {
    proxy_pass http://ws_backend;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $connection_upgrade;
    proxy_set_header Host $host;
    proxy_read_timeout 3600s;   # keep connection alive for 1 hour
    proxy_send_timeout 3600s;
    proxy_buffering off;        # required for WebSocket
}
```

## HTTP/2 and HTTP/3

```nginx
server {
    # HTTP/2
    listen 443 ssl http2;

    # HTTP/3 (QUIC) — requires nginx 1.25+ compiled with quic
    listen 443 quic reuseport;
    add_header Alt-Svc 'h3=":443"; ma=86400';

    # HTTP/2 push (use sparingly — browser support declining)
    # http2_push /style.css;
    # http2_push /app.js;

    ssl_certificate /etc/ssl/cert.pem;
    ssl_certificate_key /etc/ssl/key.pem;
    include snippets/ssl-params.conf;
}
```

For HTTP/3: ensure UDP port 443 is open in firewall. Set `ssl_early_data on;` for 0-RTT (with replay attack awareness).

## Security Headers and Hardening

```nginx
# snippets/security-headers.conf
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-Content-Type-Options "nosniff" always;
add_header X-XSS-Protection "1; mode=block" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header Permissions-Policy "camera=(), microphone=(), geolocation=()" always;
add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
add_header Content-Security-Policy "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline';" always;

# Global hardening in nginx.conf
server_tokens off;                    # hide nginx version
client_body_buffer_size 16k;          # limit body buffer
client_max_body_size 10m;             # reject large uploads
large_client_header_buffers 4 8k;     # prevent header abuse

# Block sensitive files
location ~ /\.(git|svn|env|htaccess|htpasswd) {
    deny all;
    return 404;
}

# Block common exploits
location ~* (eval\(|base64_) {
    deny all;
}
```

## Logging and Monitoring

```nginx
# Custom log format with timing
log_format detailed '$remote_addr - $remote_user [$time_local] '
    '"$request" $status $body_bytes_sent '
    '"$http_referer" "$http_user_agent" '
    'rt=$request_time urt=$upstream_response_time '
    'uct=$upstream_connect_time uht=$upstream_header_time '
    'cs=$upstream_cache_status';

access_log /var/log/nginx/access.log detailed buffer=32k flush=5s;
error_log /var/log/nginx/error.log warn;

# Per-location logging
location /api/ {
    access_log /var/log/nginx/api.log detailed;
    proxy_pass http://backend;
}

# Disable logging for health checks and static assets
location = /health {
    access_log off;
    return 200 "ok";
}
location ~* \.(ico|css|js|gif|jpg|png|woff2?)$ {
    access_log off;
    expires 30d;
}
```

Key metrics to monitor: `$request_time` (total), `$upstream_response_time` (backend), `$upstream_cache_status` (HIT/MISS/EXPIRED/STALE).

## Performance Tuning

```nginx
# nginx.conf — main context
worker_processes auto;              # match CPU cores
worker_rlimit_nofile 65535;         # file descriptor limit per worker

events {
    worker_connections 10240;       # max connections per worker
    multi_accept on;                # accept all new connections at once
    use epoll;                      # Linux optimal event model
}

http {
    sendfile on;                    # kernel-level file transfer
    tcp_nopush on;                  # optimize packet size with sendfile
    tcp_nodelay on;                 # disable Nagle's for keepalive

    keepalive_timeout 65;
    keepalive_requests 1000;        # requests per keepalive connection

    # Gzip
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 4;             # 4-6 is sweet spot (CPU vs ratio)
    gzip_min_length 256;
    gzip_types text/plain text/css application/json application/javascript
               text/xml application/xml application/xml+rss text/javascript
               image/svg+xml application/wasm;

    # Open file cache
    open_file_cache max=10000 inactive=20s;
    open_file_cache_valid 30s;
    open_file_cache_min_uses 2;
    open_file_cache_errors on;

    # Buffer tuning
    client_body_buffer_size 16k;
    proxy_buffer_size 4k;
    proxy_buffers 8 16k;
    proxy_busy_buffers_size 32k;
}
```

## Common Anti-Patterns

| Anti-Pattern | Fix |
|---|---|
| `proxy_pass` trailing slash mismatch | `http://backend/` strips location prefix; `http://backend` preserves it |
| Using `if` for request routing | Use `map` + `try_files` or separate `location` blocks |
| `root` inside `location` with `alias` semantics | Use `alias` when location prefix shouldn't appear in file path |
| Hardcoding IPs in `proxy_pass` without `resolver` | Use upstream blocks or set `resolver` for DNS backends |
| Missing `proxy_set_header Connection ""` with keepalive | Required to prevent hop-by-hop header forwarding |
| `worker_connections` too low | Set to at least 1024; high traffic: 10240+ |
| Not using `proxy_cache_use_stale` | Serve stale during backend failures instead of errors |
| SSL with `ssl on` directive | Deprecated — use `listen 443 ssl` |
| Duplicate `add_header` in nested blocks | Inner block clears parent `add_header` — re-include them |

For a complete production server block example, see `assets/reverse-proxy.conf`.

## Config Validation and Reload

Always test before applying: `nginx -t` (syntax check), `nginx -T` (dump full config), `nginx -s reload` (graceful zero-downtime reload).

## References

Deep-dive reference docs for advanced topics:

| Reference | Covers |
|---|---|
| `references/advanced-patterns.md` | Dynamic upstreams, Lua/OpenResty scripting, stream module (TCP/UDP), map directive patterns, split_clients A/B testing, mirror module, auth_request subrequests, GeoIP module, content-based routing |
| `references/troubleshooting.md` | 502/504 gateway errors, upstream timeout tuning, buffer overflow errors, SSL handshake failures, worker_connections exhaustion, memory issues, log analysis, debug log level, strace/tcpdump |
| `references/security-hardening.md` | ModSecurity WAF, DDoS mitigation, bot detection, mTLS client certificate auth, OCSP stapling, CSP/HSTS/X-Frame headers, fail2ban integration, request body inspection, IP allowlisting |

## Scripts

Helper scripts in `scripts/` — all executable, with usage comments at top:

| Script | Purpose |
|---|---|
| `scripts/generate-ssl.sh` | Generate self-signed certs (with SAN), request Let's Encrypt certs via certbot, generate DH parameters, verify existing certs |
| `scripts/test-config.sh` | Validate nginx syntax, audit security settings, test SSL for a domain, check upstream connectivity |
| `scripts/log-analyzer.sh` | Parse access/error logs — top IPs, status codes, slow requests, bandwidth, bot detection, error patterns, request rate |

Usage examples:
```bash
scripts/generate-ssl.sh selfsigned example.com --days 365
scripts/generate-ssl.sh letsencrypt example.com --email admin@example.com
scripts/generate-ssl.sh dhparam --bits 4096
scripts/test-config.sh                    # run all checks
scripts/test-config.sh --ssl example.com  # SSL audit
scripts/log-analyzer.sh --all             # full log analysis
scripts/log-analyzer.sh --slow 2.0 --since "1 hour ago"
```

## Assets (Config Templates)

Production-ready config templates in `assets/` — copy, search for `CHANGEME`, customize:

| Template | Description |
|---|---|
| `assets/reverse-proxy.conf` | Full reverse proxy with SSL termination, caching, rate limiting, security headers, static asset optimization |
| `assets/load-balancer.conf` | Load balancer with multiple algorithms, health checks, sticky sessions, WebSocket support, failover to backup servers |
| `assets/security-headers.conf` | Include file with X-Frame-Options, HSTS, CSP, Permissions-Policy, CORP/COOP/COEP — drop into any server block |
