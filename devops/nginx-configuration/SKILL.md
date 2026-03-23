---
name: nginx-configuration
description: |
  Use when user configures Nginx as reverse proxy, load balancer, or static file server, asks about nginx.conf syntax, location blocks, SSL/TLS setup, upstream config, rate limiting, or Nginx performance tuning.
  Do NOT use for Apache httpd, Caddy, Traefik, or HAProxy configurations. Do NOT use for Nginx Unit or NGINX Plus-specific features.
---

# Nginx Configuration

## Configuration File Structure

Nginx config uses nested contexts. Directives inherit from parent to child.

```
main                    # Global: user, worker_processes, error_log, pid
├── events { }          # Connection handling: worker_connections, use epoll
└── http { }            # HTTP traffic: mime types, logging, gzip
    ├── upstream { }    # Backend server groups for load balancing
    └── server { }      # Virtual host: listen, server_name
        └── location { } # URI matching: proxy_pass, root, try_files
```

Key file paths:
- Main config: `/etc/nginx/nginx.conf`
- Site configs: `/etc/nginx/conf.d/*.conf` or `/etc/nginx/sites-enabled/*`
- Include fragments with `include /etc/nginx/snippets/*.conf;`

Keep `nginx.conf` minimal. Put per-site config in separate files under `conf.d/`.

## Location Block Matching

Nginx evaluates locations in this priority order (highest first):

| Priority | Modifier | Type | Example |
|----------|----------|------|---------|
| 1 | `=` | Exact match | `location = /health { }` |
| 2 | `^~` | Prefix (skip regex) | `location ^~ /static/ { }` |
| 3 | `~` | Regex (case-sensitive) | `location ~ \.php$ { }` |
| 3 | `~*` | Regex (case-insensitive) | `location ~* \.(jpg|png)$ { }` |
| 4 | (none) | Prefix | `location /api/ { }` |

- Exact match (`=`) wins immediately if matched.
- Among prefix matches, the longest match is remembered. If it has `^~`, use it and skip regex.
- Regex locations are checked in declaration order; first match wins.
- If no regex matches, use the longest prefix match.
- Always define a fallback `location / { }`.

```nginx
server {
    location = / { return 301 /app; }        # exact: homepage redirect
    location ^~ /static/ { root /var/www; }  # prefix: skip regex for static
    location ~* \.(css|js|png|jpg)$ {        # regex: cache static assets
        expires 30d;
        add_header Cache-Control "public, immutable";
    }
    location /api/ { proxy_pass http://backend; } # prefix: API proxy
    location / { try_files $uri /index.html; }    # fallback: SPA
}
```

## Reverse Proxy Setup

### Basic Proxy

```nginx
location /api/ {
    proxy_pass http://127.0.0.1:3000/;  # trailing slash strips /api/ prefix
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

Trailing slash on `proxy_pass` matters:
- `proxy_pass http://backend;` → forwards `/api/foo` as `/api/foo`
- `proxy_pass http://backend/;` → forwards `/api/foo` as `/foo`

### Timeouts

```nginx
proxy_connect_timeout 5s;    # time to establish connection to upstream
proxy_send_timeout 60s;      # time to transmit request to upstream
proxy_read_timeout 60s;      # time to read response from upstream
```

### WebSocket Proxying

```nginx
location /ws/ {
    proxy_pass http://backend;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_read_timeout 86400s;  # keep WS connections open
}
```

## Load Balancing

### Upstream Block

```nginx
upstream app_servers {
    least_conn;  # or: ip_hash; or: random two least_conn;

    server 10.0.0.1:8080 weight=3;
    server 10.0.0.2:8080;
    server 10.0.0.3:8080 backup;

    # passive health checks
    server 10.0.0.4:8080 max_fails=3 fail_timeout=30s;

    keepalive 32;  # keep persistent connections to upstreams
}

server {
    location / {
        proxy_pass http://app_servers;
        proxy_http_version 1.1;
        proxy_set_header Connection "";  # required for upstream keepalive
    }
}
```

Algorithms:
- **(default) round-robin** — distribute sequentially.
- **least_conn** — route to server with fewest active connections.
- **ip_hash** — sticky sessions based on client IP.
- **random two least_conn** — pick two random servers, choose the one with fewer connections.
- **hash $request_uri consistent** — consistent hashing for cache distribution.

Use `proxy_next_upstream error timeout http_502 http_503;` to retry failed requests on another server.

## SSL/TLS Configuration

```nginx
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name example.com;

    ssl_certificate /etc/letsencrypt/live/example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/example.com/privkey.pem;

    # Protocols and ciphers
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305';
    ssl_prefer_server_ciphers off;  # let client choose with TLS 1.3

    # Session reuse
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    # OCSP stapling
    ssl_stapling on;
    ssl_stapling_verify on;
    ssl_trusted_certificate /etc/letsencrypt/live/example.com/chain.pem;
    resolver 1.1.1.1 8.8.8.8 valid=300s;
    resolver_timeout 5s;

    # HSTS
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
}
```

Generate DH params if needed: `openssl dhparam -out /etc/nginx/dhparam.pem 2048`

Automate certificate renewal with Certbot: `certbot renew --deploy-hook "systemctl reload nginx"`

## Static File Serving

### root vs alias

```nginx
# root: appends location path to root
location /images/ {
    root /var/www;  # serves /var/www/images/photo.jpg
}

# alias: replaces location path
location /img/ {
    alias /var/www/images/;  # serves /var/www/images/photo.jpg for /img/photo.jpg
}
```

### try_files

```nginx
location / {
    root /var/www/html;
    try_files $uri $uri/ =404;  # try file, then directory, then 404
}
```

### Caching Headers and Compression

```nginx
location ~* \.(css|js|woff2|svg|png|jpg|jpeg|gif|ico)$ {
    root /var/www/html;
    expires 1y;
    add_header Cache-Control "public, immutable";
    access_log off;
}

# Gzip
gzip on;
gzip_vary on;
gzip_proxied any;
gzip_comp_level 4;
gzip_min_length 256;
gzip_types text/plain text/css application/json application/javascript
           text/xml application/xml application/xml+rss text/javascript
           image/svg+xml application/wasm;

# Brotli (requires ngx_brotli module)
brotli on;
brotli_comp_level 4;
brotli_types text/plain text/css application/json application/javascript
             text/xml application/xml image/svg+xml;
```

## Rate Limiting

### Request Rate Limiting

```nginx
http {
    # Define zone: 10MB shared memory, 10 requests/second per IP
    limit_req_zone $binary_remote_addr zone=api_limit:10m rate=10r/s;
    limit_req_zone $binary_remote_addr zone=login_limit:10m rate=1r/s;

    server {
        location /api/ {
            limit_req zone=api_limit burst=20 nodelay;
            # burst: allow 20 extra requests in a burst
            # nodelay: serve burst requests immediately, don't queue
            limit_req_status 429;
        }

        location /login {
            limit_req zone=login_limit burst=5;
            # no nodelay: excess requests are queued and released at rate
        }
    }
}
```

### Connection Limiting

```nginx
http {
    limit_conn_zone $binary_remote_addr zone=conn_limit:10m;

    server {
        limit_conn conn_limit 20;  # max 20 simultaneous connections per IP
        limit_conn_status 429;
    }
}
```

## Security Hardening

### Security Headers

```nginx
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-Content-Type-Options "nosniff" always;
add_header X-XSS-Protection "0" always;  # modern browsers use CSP instead
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header Content-Security-Policy "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline';" always;
add_header Permissions-Policy "camera=(), microphone=(), geolocation=()" always;
```

Use `always` to apply headers on error responses too.

### Hide Version and Restrict Methods

```nginx
http {
    server_tokens off;  # hide "nginx/1.x.x" from headers and error pages

    server {
        # reject non-standard methods
        if ($request_method !~ ^(GET|HEAD|POST|PUT|PATCH|DELETE|OPTIONS)$) {
            return 444;  # close connection without response
        }
    }
}
```

### IP Allowlisting

```nginx
location /admin/ {
    allow 10.0.0.0/8;
    allow 192.168.1.0/24;
    deny all;
    proxy_pass http://admin_backend;
}
```

### Block Sensitive Files

```nginx
location ~ /\.(git|env|htaccess|htpasswd) {
    deny all;
    return 404;
}
```

## Logging

### Access and Error Logs

```nginx
http {
    # Custom log format
    log_format main '$remote_addr - $remote_user [$time_local] '
                    '"$request" $status $body_bytes_sent '
                    '"$http_referer" "$http_user_agent" '
                    '$request_time $upstream_response_time';

    access_log /var/log/nginx/access.log main;
    error_log /var/log/nginx/error.log warn;  # levels: debug info notice warn error crit alert emerg

    server {
        # Conditional logging: skip health checks
        map $request_uri $loggable {
            ~^/health 0;
            default   1;
        }
        access_log /var/log/nginx/access.log main if=$loggable;

        location ~* \.(ico|css|js|gif|jpg|png)$ {
            access_log off;
        }
    }
}
```

## Performance Tuning

```nginx
# Main context
worker_processes auto;            # match CPU cores
worker_rlimit_nofile 65535;       # max open file descriptors per worker

events {
    worker_connections 4096;       # connections per worker
    use epoll;                     # Linux: use epoll for efficiency
    multi_accept on;               # accept multiple connections at once
}

http {
    # TCP optimizations
    sendfile on;                   # kernel-level file sending
    tcp_nopush on;                 # send headers and file in one packet
    tcp_nodelay on;                # disable Nagle's algorithm for small packets

    # Keepalive
    keepalive_timeout 65;
    keepalive_requests 1000;       # max requests per keepalive connection

    # Client body
    client_max_body_size 10m;      # max upload size
    client_body_buffer_size 128k;

    # Proxy buffering
    proxy_buffering on;
    proxy_buffer_size 4k;
    proxy_buffers 8 16k;
    proxy_busy_buffers_size 32k;

    # File caching
    open_file_cache max=200000 inactive=20s;
    open_file_cache_valid 30s;
    open_file_cache_min_uses 2;
    open_file_cache_errors on;

    # Header buffers
    large_client_header_buffers 4 16k;
}
```

Max concurrent connections = `worker_processes` × `worker_connections`.
Set `worker_rlimit_nofile` ≥ `worker_connections × 2` (each connection may use two file descriptors).

## Common Patterns

### SPA Routing (React, Vue, Angular)

```nginx
server {
    listen 80;
    server_name app.example.com;
    root /var/www/app/dist;

    location / {
        try_files $uri $uri/ /index.html;
    }

    location /api/ {
        proxy_pass http://127.0.0.1:3000;
    }
}
```

### API Gateway + Frontend

```nginx
server {
    listen 443 ssl http2;
    server_name example.com;

    # Frontend
    location / {
        root /var/www/frontend;
        try_files $uri /index.html;
    }

    # API v1
    location /api/v1/ {
        proxy_pass http://api_v1_servers/;
        proxy_set_header Host $host;
    }

    # API v2
    location /api/v2/ {
        proxy_pass http://api_v2_servers/;
        proxy_set_header Host $host;
    }
}
```

### HTTP → HTTPS Redirect

```nginx
server {
    listen 80;
    listen [::]:80;
    server_name example.com www.example.com;
    return 301 https://$host$request_uri;
}
```

### Non-www → www Redirect

```nginx
server {
    listen 443 ssl http2;
    server_name example.com;
    return 301 https://www.example.com$request_uri;
}
```

## Debugging

### Validate Configuration

```bash
nginx -t          # test config syntax
nginx -T          # test and dump full merged config
nginx -T 2>&1 | grep "server_name"  # find all server_names
```

### Reload Without Downtime

```bash
nginx -t && systemctl reload nginx   # always test before reload
```

### Error Log Levels

Set `error_log` level from verbose to quiet: `debug`, `info`, `notice`, `warn`, `error`, `crit`, `alert`, `emerg`.
Use `debug` temporarily for troubleshooting — never in production (high I/O).

### Stub Status (Monitoring)

```nginx
location /nginx_status {
    stub_status;
    allow 127.0.0.1;
    deny all;
}
```

Returns active connections, accepts, handled, requests, and per-state connection counts.

### Common Errors

- **502 Bad Gateway** — upstream is down or unreachable. Check upstream service and `proxy_pass` address.
- **504 Gateway Timeout** — upstream took too long. Increase `proxy_read_timeout`.
- **413 Request Entity Too Large** — increase `client_max_body_size`.
- **[emerg] bind() failed** — port already in use or insufficient permissions.

<!-- tested: pass -->
