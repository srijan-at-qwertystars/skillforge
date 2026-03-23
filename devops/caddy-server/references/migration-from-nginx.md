# Nginx to Caddy v2 Migration Guide

## Table of Contents

- [Key Differences](#key-differences)
- [Directive Mapping Reference](#directive-mapping-reference)
- [Configuration Translations](#configuration-translations)
  - [Basic Static Site](#basic-static-site)
  - [Reverse Proxy](#reverse-proxy)
  - [SSL/TLS Configuration](#ssltls-configuration)
  - [Load Balancer](#load-balancer)
  - [PHP/FastCGI](#phpfastcgi)
  - [WebSocket Proxy](#websocket-proxy)
  - [Rate Limiting](#rate-limiting)
  - [Basic Authentication](#basic-authentication)
  - [Redirects and Rewrites](#redirects-and-rewrites)
  - [Access Control by IP](#access-control-by-ip)
  - [Caching Headers](#caching-headers)
  - [Gzip/Compression](#gzipcompression)
  - [Security Headers](#security-headers)
  - [Logging](#logging)
  - [Multi-Site Configuration](#multi-site-configuration)
- [Feature Parity Table](#feature-parity-table)
- [Things Caddy Does Differently](#things-caddy-does-differently)
- [Migration Checklist](#migration-checklist)

---

## Key Differences

| Aspect | Nginx | Caddy |
|---|---|---|
| **HTTPS** | Manual (certbot, cron) | Automatic (built-in ACME) |
| **Config format** | nginx.conf (C-like syntax) | Caddyfile (simplified) or JSON |
| **Config reload** | `nginx -s reload` | `caddy reload` or API POST |
| **Config test** | `nginx -t` | `caddy validate` |
| **Include pattern** | `include /etc/nginx/conf.d/*.conf;` | `import /etc/caddy/sites/*` |
| **Modules** | Recompilation required | `xcaddy build --with ...` |
| **Default behavior** | Serve default page | Refuse to start without config |
| **Process model** | Master + workers (prefork) | Single Go binary (goroutines) |
| **HTTP/3** | Requires special build | Built-in |
| **Config API** | None | REST API on :2019 |

---

## Directive Mapping Reference

### Server Block → Site Block

```nginx
# NGINX
server {
    listen 80;
    listen 443 ssl;
    server_name example.com;
    ...
}
```

```caddyfile
# CADDY — HTTPS is automatic, no listen directives needed
example.com {
    ...
}
```

### Core Directives

| Nginx | Caddy | Notes |
|---|---|---|
| `listen 80;` | *(automatic)* | Caddy auto-listens on 80/443 |
| `listen 443 ssl;` | *(automatic)* | Caddy enables TLS automatically |
| `server_name example.com;` | `example.com {` | Domain is the site block header |
| `root /var/www/html;` | `root * /var/www/html` | `*` means all request paths |
| `index index.html;` | *(automatic with file_server)* | file_server serves index.html by default |
| `location /path { ... }` | `handle /path/* { ... }` | Or `handle_path` to strip prefix |
| `location ~ \.php$ { ... }` | `php_fastcgi ...` | Caddy has a dedicated PHP directive |
| `proxy_pass http://backend;` | `reverse_proxy backend:port` | Caddy auto-sets proxy headers |
| `ssl_certificate /path;` | `tls /cert /key` | Or omit for automatic HTTPS |
| `ssl_certificate_key /path;` | *(part of tls directive)* | |
| `return 301 https://...;` | `redir https://... permanent` | Or just use Caddy's auto-redirect |
| `rewrite ^/old /new;` | `rewrite /old /new` | |
| `try_files $uri /index.html;` | `try_files {path} /index.html` | Same concept, different syntax |
| `gzip on;` | `encode gzip` | Or `encode { gzip; zstd }` |
| `add_header X-Frame-Options DENY;` | `header X-Frame-Options DENY` | |
| `proxy_set_header Host $host;` | `header_up Host {host}` | Inside reverse_proxy block |
| `access_log /var/log/access.log;` | `log { output file /path }` | JSON by default |
| `error_log /var/log/error.log;` | `log { level ERROR }` | Unified logging |
| `auth_basic "Realm";` | `basicauth /path/* { ... }` | |
| `deny all;` | `respond 403` | |
| `allow 10.0.0.0/8;` | `@allowed remote_ip 10.0.0.0/8` | Use with named matcher |
| `client_max_body_size 10m;` | `request_body { max_size 10MB }` | |
| `proxy_read_timeout 60s;` | `transport http { read_timeout 60s }` | Inside reverse_proxy |
| `keepalive_timeout 65;` | *(configured in server options)* | |
| `sendfile on;` | *(automatic)* | Go handles this efficiently |
| `include /etc/nginx/mime.types;` | *(built-in)* | Caddy includes MIME types |

---

## Configuration Translations

### Basic Static Site

**Nginx:**

```nginx
server {
    listen 80;
    listen 443 ssl;
    server_name example.com;

    ssl_certificate /etc/letsencrypt/live/example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/example.com/privkey.pem;

    root /var/www/html;
    index index.html index.htm;

    location / {
        try_files $uri $uri/ =404;
    }

    # Redirect HTTP to HTTPS
    if ($scheme = http) {
        return 301 https://$host$request_uri;
    }
}
```

**Caddy:**

```caddyfile
example.com {
    root * /var/www/html
    file_server
}
# That's it. HTTPS, redirect, index files — all automatic.
```

### Reverse Proxy

**Nginx:**

```nginx
server {
    listen 443 ssl;
    server_name app.example.com;

    ssl_certificate /etc/letsencrypt/live/app.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/app.example.com/privkey.pem;

    location / {
        proxy_pass http://localhost:3000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
```

**Caddy:**

```caddyfile
app.example.com {
    reverse_proxy localhost:3000
}
# Caddy auto-sets Host, X-Real-IP, X-Forwarded-For, X-Forwarded-Proto
# Caddy auto-handles WebSocket upgrade headers
```

### SSL/TLS Configuration

**Nginx:**

```nginx
ssl_protocols TLSv1.2 TLSv1.3;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256;
ssl_prefer_server_ciphers on;
ssl_session_cache shared:SSL:10m;
ssl_session_timeout 10m;
ssl_stapling on;
ssl_stapling_verify on;
add_header Strict-Transport-Security "max-age=63072000" always;
```

**Caddy:**

```caddyfile
# Caddy defaults: TLS 1.2+, strong ciphers, OCSP stapling, HSTS
# Only customize if you need something non-default:
example.com {
    tls {
        protocols tls1.2 tls1.3
        ciphers TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
    }
    header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"
    reverse_proxy localhost:8080
}
```

### Load Balancer

**Nginx:**

```nginx
upstream backend {
    least_conn;
    server 10.0.0.1:8080;
    server 10.0.0.2:8080;
    server 10.0.0.3:8080;
}

server {
    listen 443 ssl;
    server_name example.com;

    location / {
        proxy_pass http://backend;
        proxy_next_upstream error timeout http_502 http_503;
    }
}
```

**Caddy:**

```caddyfile
example.com {
    reverse_proxy 10.0.0.1:8080 10.0.0.2:8080 10.0.0.3:8080 {
        lb_policy least_conn
        lb_retries 3
        fail_duration 30s
        health_uri /healthz
        health_interval 10s
    }
}
```

### PHP/FastCGI

**Nginx:**

```nginx
server {
    listen 443 ssl;
    server_name example.com;
    root /var/www/html;
    index index.php index.html;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        fastcgi_pass unix:/run/php/php-fpm.sock;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_read_timeout 60s;
    }

    location ~ /\.ht {
        deny all;
    }
}
```

**Caddy:**

```caddyfile
example.com {
    root * /var/www/html
    php_fastcgi unix//run/php/php-fpm.sock {
        read_timeout 60s
    }
    file_server
    # Hidden files (.ht*) blocked by default
}
```

### WebSocket Proxy

**Nginx:**

```nginx
location /ws {
    proxy_pass http://localhost:9090;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_read_timeout 86400s;
    proxy_send_timeout 86400s;
}
```

**Caddy:**

```caddyfile
handle /ws/* {
    reverse_proxy localhost:9090 {
        transport http {
            read_timeout 0
            write_timeout 0
        }
    }
}
```

### Rate Limiting

**Nginx:**

```nginx
http {
    limit_req_zone $binary_remote_addr zone=api:10m rate=10r/s;

    server {
        location /api/ {
            limit_req zone=api burst=20 nodelay;
            limit_req_status 429;
            proxy_pass http://localhost:8080;
        }
    }
}
```

**Caddy** (requires `caddy-ratelimit` module):

```caddyfile
{
    order rate_limit before reverse_proxy
}

example.com {
    handle /api/* {
        rate_limit {
            zone api_zone {
                key    {remote_host}
                events 10
                window 1s
            }
        }
        reverse_proxy localhost:8080
    }
}
```

### Basic Authentication

**Nginx:**

```nginx
location /admin {
    auth_basic "Admin Area";
    auth_basic_user_file /etc/nginx/.htpasswd;
    proxy_pass http://localhost:8080;
}
```

**Caddy:**

```caddyfile
# Generate password hash: caddy hash-password
handle /admin/* {
    basicauth {
        admin $2a$14$HASHED_PASSWORD_HERE
    }
    reverse_proxy localhost:8080
}
```

### Redirects and Rewrites

**Nginx:**

```nginx
# Permanent redirect
server {
    server_name www.example.com;
    return 301 https://example.com$request_uri;
}

# Internal rewrite
location /old-page {
    rewrite ^/old-page(.*)$ /new-page$1 permanent;
}

# Try files (SPA)
location / {
    try_files $uri $uri/ /index.html;
}
```

**Caddy:**

```caddyfile
# Permanent redirect
www.example.com {
    redir https://example.com{uri} permanent
}

# Rewrite
example.com {
    rewrite /old-page* /new-page{path}

    # SPA fallback
    try_files {path} /index.html
    file_server
}
```

### Access Control by IP

**Nginx:**

```nginx
location /internal {
    allow 10.0.0.0/8;
    allow 192.168.0.0/16;
    deny all;
    proxy_pass http://localhost:8080;
}
```

**Caddy:**

```caddyfile
@internal remote_ip 10.0.0.0/8 192.168.0.0/16
handle @internal {
    reverse_proxy localhost:8080
}
respond "Forbidden" 403
```

### Caching Headers

**Nginx:**

```nginx
location ~* \.(css|js|png|jpg|gif|ico|woff2)$ {
    expires 1y;
    add_header Cache-Control "public, immutable";
    access_log off;
}
```

**Caddy:**

```caddyfile
@static path *.css *.js *.png *.jpg *.gif *.ico *.woff2
header @static Cache-Control "public, max-age=31536000, immutable"
```

### Gzip/Compression

**Nginx:**

```nginx
gzip on;
gzip_vary on;
gzip_min_length 256;
gzip_types text/plain text/css application/json application/javascript text/xml;
gzip_comp_level 6;
```

**Caddy:**

```caddyfile
encode {
    gzip 6
    zstd     # Caddy also supports zstd out of the box
    minimum_length 256
}
```

### Security Headers

**Nginx:**

```nginx
add_header X-Frame-Options "DENY" always;
add_header X-Content-Type-Options "nosniff" always;
add_header X-XSS-Protection "1; mode=block" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header Content-Security-Policy "default-src 'self'" always;
server_tokens off;
```

**Caddy:**

```caddyfile
header {
    X-Frame-Options "DENY"
    X-Content-Type-Options "nosniff"
    X-XSS-Protection "1; mode=block"
    Referrer-Policy "strict-origin-when-cross-origin"
    Content-Security-Policy "default-src 'self'"
    -Server
}
```

### Logging

**Nginx:**

```nginx
access_log /var/log/nginx/access.log combined;
error_log /var/log/nginx/error.log warn;

log_format json escape=json '{"time":"$time_iso8601","remote_addr":"$remote_addr",'
    '"method":"$request_method","uri":"$request_uri","status":$status,'
    '"body_bytes_sent":$body_bytes_sent,"request_time":$request_time}';
access_log /var/log/nginx/access.json json;
```

**Caddy:**

```caddyfile
# JSON logging is default
log {
    output file /var/log/caddy/access.log {
        roll_size 100MiB
        roll_keep 5
    }
    format json
    level INFO
}
```

### Multi-Site Configuration

**Nginx:**

```nginx
# /etc/nginx/nginx.conf
http {
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}

# /etc/nginx/sites-available/example.conf
server { server_name example.com; ... }

# /etc/nginx/sites-available/app.conf
server { server_name app.example.com; ... }
```

**Caddy:**

```caddyfile
# Single Caddyfile — all sites in one file
example.com {
    root * /var/www/example
    file_server
}

app.example.com {
    reverse_proxy localhost:3000
}

# Or use imports for organization
import /etc/caddy/sites/*
```

There is no `sites-available`/`sites-enabled` pattern. Use `import` with a directory for file-per-site organization.

---

## Feature Parity Table

| Feature | Nginx | Caddy | Notes |
|---|---|---|---|
| Static file serving | ✅ | ✅ | Both excellent |
| Reverse proxy | ✅ | ✅ | Caddy auto-sets headers |
| Load balancing | ✅ | ✅ | Similar algorithms available |
| Automatic HTTPS | ❌ (needs certbot) | ✅ | Caddy's killer feature |
| HTTP/2 | ✅ | ✅ | Both default |
| HTTP/3 (QUIC) | ⚠️ (special build) | ✅ | Caddy built-in |
| WebSocket proxy | ✅ | ✅ | Caddy is simpler |
| gzip compression | ✅ | ✅ | Caddy adds zstd |
| Rate limiting | ✅ (built-in) | ⚠️ (module) | Nginx has native support |
| Basic auth | ✅ | ✅ | Both support bcrypt |
| IP allowlisting | ✅ | ✅ | Different syntax |
| Regex matching | ✅ | ✅ | Caddy uses `path_regexp` |
| FastCGI / PHP | ✅ | ✅ | Caddy has `php_fastcgi` |
| Custom error pages | ✅ | ✅ | Caddy uses `handle_errors` |
| Request body limit | ✅ | ✅ | |
| Access logs | ✅ | ✅ | Caddy defaults to JSON |
| Config test | ✅ (`nginx -t`) | ✅ (`caddy validate`) | |
| Graceful reload | ✅ | ✅ | Zero downtime both |
| Lua scripting | ✅ (OpenResty) | ❌ | Use Go modules instead |
| ModSecurity WAF | ✅ | ❌ | Caddy has `caddy-security` |
| GeoIP | ✅ (module) | ⚠️ (module) | Both need extra modules |
| Caching/proxy cache | ✅ (built-in) | ⚠️ (module) | `caddy-cache` exists |
| Stream (TCP/UDP) proxy | ✅ | ⚠️ (module) | `caddy-l4` module |
| mail proxy | ✅ | ❌ | Nginx niche feature |
| Config API | ❌ | ✅ | Caddy REST API |
| Dynamic upstreams | ⚠️ (Plus/commercial) | ✅ | Caddy SRV/A lookups |
| On-demand TLS | ❌ | ✅ | Caddy unique feature |

Legend: ✅ Built-in | ⚠️ Requires module/extra config | ❌ Not available

---

## Things Caddy Does Differently

### 1. Automatic HTTPS — No Certbot Needed

Delete your certbot cron jobs, remove `ssl_certificate` directives. Caddy handles everything:
- Obtains certificates from Let's Encrypt + ZeroSSL
- Renews before expiry (30 days out)
- OCSP stapling automatic
- HTTP→HTTPS redirect automatic
- HSTS headers added automatically

### 2. No `.conf.d` Include Pattern

Nginx uses `sites-available`/`sites-enabled` symlinks. Caddy has no equivalent — all config goes in one Caddyfile or use `import`:

```caddyfile
import /etc/caddy/sites/*.caddy
```

### 3. No `upstream` Blocks

```nginx
# Nginx: define upstream separately
upstream backend {
    server 10.0.0.1:8080;
    server 10.0.0.2:8080;
}
```

```caddyfile
# Caddy: upstreams defined inline
reverse_proxy 10.0.0.1:8080 10.0.0.2:8080
```

### 4. Directive Order Matters (But Caddy Has Defaults)

Caddy applies directives in a predefined order. To override:

```caddyfile
{
    order rate_limit before reverse_proxy
}
```

Or use `route { }` blocks to enforce explicit ordering.

### 5. `handle` vs `route` (No Direct Nginx Equivalent)

- `handle` — mutually exclusive (first matching handle wins, like nginx `location`)
- `route` — sequential (all matching directives execute in order)
- `handle_path` — like `handle` but strips the matched path prefix

### 6. Placeholders, Not Variables

Nginx uses `$variable`. Caddy uses `{placeholder}`:

```nginx
# Nginx
proxy_set_header X-Real-IP $remote_addr;
```

```caddyfile
# Caddy
header_up X-Real-IP {remote_host}
```

### 7. Single Binary, No Package Dependencies

Caddy is a single static Go binary. No `libssl`, no `libpcre`, no worker processes. Upgrade by replacing the binary and reloading.

### 8. Live Config API

Caddy exposes its full config via REST API on `:2019`. You can modify routing rules, add sites, and change TLS settings without restarting — something Nginx cannot do.

---

## Migration Checklist

- [ ] **Inventory current Nginx config** — list all `server` blocks, `location` blocks, upstreams, and SSL certs
- [ ] **Install Caddy** — use official repo or `xcaddy build` if modules needed
- [ ] **Translate server blocks** — each `server { server_name X; }` becomes `X { }` in Caddy
- [ ] **Remove SSL config** — delete `ssl_certificate`, `ssl_certificate_key`, certbot references
- [ ] **Translate location blocks** — use `handle`, `handle_path`, or named matchers
- [ ] **Translate proxy_pass** — change to `reverse_proxy`, remove manual header_up (Caddy sets them)
- [ ] **Translate try_files** — same concept, different syntax: `try_files {path} /index.html`
- [ ] **Translate PHP** — replace `fastcgi_pass` block with `php_fastcgi`
- [ ] **Test with staging** — set `acme_ca` to Let's Encrypt staging endpoint
- [ ] **Validate config** — run `caddy validate --config Caddyfile`
- [ ] **Run parallel** — run Caddy on alternate ports alongside Nginx for testing
- [ ] **DNS cutover** — point DNS to Caddy server (or swap ports on same server)
- [ ] **Monitor logs** — watch `journalctl -u caddy -f` for errors
- [ ] **Remove Nginx** — stop and disable Nginx after confirming Caddy works
- [ ] **Remove certbot** — delete certbot packages and cron jobs
- [ ] **Update monitoring** — point health checks to Caddy's new ports/endpoints
