---
name: caddy-server
description: >
  Guide for configuring and deploying Caddy v2 web server with automatic HTTPS.
  TRIGGER when: user mentions Caddy, Caddyfile, caddy reverse proxy, automatic HTTPS
  with Caddy, Let's Encrypt with Caddy, ACME certificate automation, ZeroSSL,
  caddy file_server, caddy encode, caddy templates, caddy basicauth, xcaddy build,
  caddy Docker deployment, caddy systemd service, caddy PHP FastCGI, caddy WebSocket
  proxy, caddy JSON API, caddy TLS configuration, caddy load balancing, caddy
  rate limiting, caddy request matchers, or caddy logging/access logs.
  DO NOT TRIGGER when: user asks about Nginx, Apache, Traefik, HAProxy, or other
  web servers unless explicitly comparing to Caddy. Do not trigger for general
  TLS/SSL questions unrelated to Caddy, generic DNS configuration, or container
  orchestration not involving Caddy.
---

# Caddy Web Server (v2)

## Overview

Caddy is an extensible web server written in Go. Its defining feature is **automatic HTTPS by default** — every site gets a TLS certificate from Let's Encrypt or ZeroSSL via ACME with zero configuration. Supports HTTP/1.1, HTTP/2, HTTP/3 out of the box. Current stable: **v2.11.x**.

Key differentiators: automatic cert provisioning/renewal/OCSP stapling, Caddyfile or JSON config with live API, single static binary, secure defaults (TLS 1.2+, strong ciphers, HSTS), built-in reverse proxy with load balancing, PCI/HIPAA/NIST compliant defaults.

## Caddyfile Syntax and Structure

Block-based structure. Each site block starts with an address:

```caddyfile
example.com {
    root * /var/www/html
    file_server
}
app.example.com {
    reverse_proxy localhost:3000
}
```

### Global Options Block

Place at top of Caddyfile, before any site blocks:

```caddyfile
{
    email admin@example.com
    acme_ca https://acme-staging-v02.api.letsencrypt.org/directory
    admin off
    log { level ERROR }
    servers { protocols h1 h2 h3 }
}
```

### Address Formats

```caddyfile
example.com                  # HTTPS on 443, auto-redirect HTTP 80
http://example.com           # HTTP only, no TLS
:8080                        # All interfaces, port 8080, no auto-HTTPS
localhost                    # HTTPS with self-signed cert
*.example.com                # Wildcard (requires DNS challenge)
```

## Automatic HTTPS

Caddy obtains and renews certificates automatically:

- **Public domains**: Let's Encrypt (primary) + ZeroSSL (fallback) via HTTP or TLS-ALPN challenge
- **Wildcard domains**: Require DNS challenge; configure a DNS provider module
- **localhost / IPs**: Locally-trusted self-signed certificates
- **On-Demand TLS**: Provision certs at handshake time for multi-tenant setups
- HTTP-to-HTTPS redirect is automatic; suppress with `http://` prefix

```caddyfile
# DNS challenge for wildcard
*.example.com {
    tls { dns cloudflare {env.CF_API_TOKEN} }
    reverse_proxy localhost:8080
}
# On-demand TLS (SaaS pattern)
{
    on_demand_tls { ask http://localhost:5555/check }
}
https:// {
    tls { on_demand }
    reverse_proxy localhost:8080
}
```

## Reverse Proxy Configuration

```caddyfile
# Basic proxy
example.com {
    reverse_proxy localhost:3000
}
# Path-based routing
example.com {
    handle /api/* {
        reverse_proxy localhost:8080
    }
    handle {
        reverse_proxy localhost:3000
    }
}
# Strip prefix with handle_path
handle_path /api/* {
    reverse_proxy localhost:8080   # receives request without /api prefix
}
```

### Load Balancing and Health Checks

```caddyfile
reverse_proxy {
    to 10.0.0.1:8080 10.0.0.2:8080 10.0.0.3:8080
    lb_policy round_robin    # round_robin|least_conn|random|first|ip_hash|uri_hash|header|cookie
    lb_retries 3
    health_uri /healthz
    health_interval 10s
    health_timeout 5s
    health_status 200
    fail_duration 30s        # passive health checks
    max_fails 3
    unhealthy_latency 500ms
}
```

### Headers and Transport

```caddyfile
reverse_proxy localhost:3000 {
    header_up Host {upstream_hostport}
    header_up X-Real-IP {remote_host}
    header_up X-Forwarded-For {remote_host}
    header_up X-Forwarded-Proto {scheme}
    header_down -Server
    header_down Strict-Transport-Security "max-age=31536000"
}
reverse_proxy localhost:8443 {
    transport http {
        tls                          # proxy to HTTPS upstream
        tls_insecure_skip_verify     # skip upstream cert verification (internal only)
        read_timeout 30s
        write_timeout 30s
        dial_timeout 5s
    }
}
```

## Static File Serving

```caddyfile
example.com {
    root * /var/www/html
    file_server {
        hide .git .env
        browse                       # enable directory listing
        precompressed gzip br zstd
    }
}
# SPA fallback
example.com {
    root * /var/www/app
    try_files {path} /index.html
    file_server
}
```

## Middleware

```caddyfile
# Compression
encode { gzip; zstd; minimum_length 256 }

# Basic auth (generate hash: caddy hash-password)
basicauth /admin/* {
    admin $2a$14$...
}

# Rate limiting (third-party module, install via xcaddy)
rate_limit {
    zone static_zone {
        key {remote_host}
        events 100
        window 1m
    }
}

# Templates — use Go template syntax in .html: {{.RemoteIP}}, {{include "/header.html"}}
templates
file_server

# Request body size limit
request_body { max_size 10MB }
```

## Request Matchers

Use named matchers (`@name`) for complex routing:

```caddyfile
@api {
    path /api/* /v1/* /v2/*
    method GET POST PUT DELETE
}
reverse_proxy @api localhost:8080

@websocket {
    header Connection *Upgrade*
    header Upgrade websocket
}
reverse_proxy @websocket localhost:9090

@internal {
    remote_ip 10.0.0.0/8 192.168.0.0/16 172.16.0.0/12
}
respond @internal "Internal access granted" 200

@static {
    path *.css *.js *.png *.jpg *.svg *.woff2
}
header @static Cache-Control "public, max-age=31536000, immutable"
```

Available matcher fields: `path`, `path_regexp`, `host`, `method`, `header`, `header_regexp`, `protocol`, `remote_ip`, `query`, `expression`, `not`.

## Logging and Access Logs

```caddyfile
{
    log {
        output file /var/log/caddy/default.log {
            roll_size 100MiB
            roll_keep 5
            roll_keep_for 720h
        }
        format json
        level INFO
    }
}
example.com {
    log {
        output file /var/log/caddy/example.access.log
        format json
    }
}
```

JSON fields: `ts`, `logger`, `msg`, `request.method`, `request.uri`, `request.host`, `status`, `size`, `duration`. Use `format console` for development. Use `format filter` to redact sensitive fields.

## JSON Config API

Caddy exposes a REST API on `localhost:2019`:

```bash
curl http://localhost:2019/config/                    # get current config
curl -X POST http://localhost:2019/load \
  -H "Content-Type: application/json" -d @caddy.json  # load new config
caddy adapt --config Caddyfile --pretty                # convert Caddyfile to JSON
```

Secure it: use `admin off` or `admin unix//run/caddy/admin.sock` in global options. Never expose `:2019` publicly.

## Caddy Modules and Plugins (xcaddy)

```bash
go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest
xcaddy build \
  --with github.com/caddy-dns/cloudflare \
  --with github.com/mholt/caddy-ratelimit \
  --with github.com/greenpau/caddy-security
xcaddy build v2.11.2 --with github.com/caddy-dns/cloudflare@v0.2.1  # pin versions
caddy list-modules  # verify loaded modules
```

Popular modules: `caddy-dns/*` (DNS challenge providers), `caddy-security` (auth portal), `caddy-ratelimit` (distributed rate limiting), `replace-response` (body find/replace), `caddy-ext/layer4` (TCP/UDP proxying).

## Docker Deployment

```yaml
# docker-compose.yml
services:
  caddy:
    image: caddy:2-alpine
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"       # HTTP/3
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data    # certificates — MUST persist
      - caddy_config:/config
    networks: [web]
  app:
    image: myapp:latest
    networks: [web]         # reference as reverse_proxy app:3000
networks:
  web:
volumes:
  caddy_data:
  caddy_config:
```

Custom build with plugins:

```dockerfile
FROM caddy:2-builder-alpine AS builder
RUN xcaddy build \
  --with github.com/caddy-dns/cloudflare \
  --with github.com/mholt/caddy-ratelimit
FROM caddy:2-alpine
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
```

## Systemd Integration

```bash
# Install (Debian/Ubuntu)
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update && sudo apt install caddy

# Manage
sudo systemctl enable caddy && sudo systemctl start caddy
sudo systemctl reload caddy          # graceful zero-downtime reload
journalctl -u caddy --no-pager -f    # follow logs
```

Config: `/etc/caddy/Caddyfile`. Data: `/var/lib/caddy/.local/share/caddy`. Override unit with `sudo systemctl edit caddy` (e.g., `LimitNOFILE=1048576`).

## PHP / FastCGI Configuration

```caddyfile
# Generic PHP
example.com {
    root * /var/www/html
    php_fastcgi unix//run/php/php-fpm.sock {
        index index.php
        split .php
        dial_timeout 10s
        read_timeout 60s
    }
    file_server
}
# Laravel
example.com {
    root * /var/www/laravel/public
    php_fastcgi unix//run/php/php-fpm.sock
    file_server
    encode gzip
}
# WordPress (block dangerous endpoints)
example.com {
    root * /var/www/wordpress
    php_fastcgi unix//run/php/php-fpm.sock
    file_server
    @disallowed path /xmlrpc.php /wp-config.php
    respond @disallowed 403
}
```

## WebSocket Proxying

Caddy proxies WebSocket transparently — no special config needed:

```caddyfile
reverse_proxy /ws localhost:9090
reverse_proxy localhost:3000
```

For long-lived connections, disable timeouts:

```caddyfile
reverse_proxy /ws localhost:9090 {
    transport http {
        keepalive off
        read_timeout 0
        write_timeout 0
    }
    flush_interval -1       # also required for SSE/streaming
}
```

## TLS Customization

```caddyfile
# Mutual TLS (client cert auth)
example.com {
    tls {
        client_auth {
            mode require_and_verify
            trusted_ca_cert_file /etc/caddy/client-ca.crt
        }
    }
    reverse_proxy localhost:8080
}
# Internal CA (Caddy PKI)
internal.example.com {
    tls internal
    reverse_proxy localhost:8080
}
# Custom certificates
example.com {
    tls /etc/ssl/certs/cert.pem /etc/ssl/private/key.pem
}
# Cipher/protocol control
example.com {
    tls {
        protocols tls1.2 tls1.3
        ciphers TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384 TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
        curves x25519 secp256r1
    }
}
```

## Caddy vs Nginx

| Feature | Caddy | Nginx |
|---|---|---|
| Auto HTTPS | Built-in, zero-config | Requires certbot/external |
| Config | Caddyfile (simple) or JSON | nginx.conf (complex) |
| HTTP/3 | Built-in | Requires recompilation |
| Extensibility | Go modules, xcaddy | C modules, recompilation |
| Config API | REST on :2019 | No native API |
| Performance | Excellent for most workloads | Faster static at extreme scale |
| Memory | ~20MB baseline | ~5MB baseline |

Prefer Caddy when: automatic TLS matters, config simplicity is valued, HTTP/3 needed. Prefer Nginx when: extreme static throughput is critical, memory severely constrained, existing Nginx expertise.

## Common Patterns

```caddyfile
# Redirect www to non-www
www.example.com {
    redir https://example.com{uri} permanent
}
# CORS headers
header {
    Access-Control-Allow-Origin *
    Access-Control-Allow-Methods "GET, POST, OPTIONS"
    Access-Control-Allow-Headers "Content-Type, Authorization"
}
@options method OPTIONS
respond @options 204

# Maintenance mode
@maintenance expression {env.MAINTENANCE} == "true"
respond @maintenance "Site under maintenance" 503

# Canonical HTTPS redirect
http://example.com, http://www.example.com, https://www.example.com {
    redir https://example.com{uri} permanent
}
```

## Anti-Patterns

- **Do not** disable TLS in production — defeats Caddy's primary advantage.
- **Do not** use `tls_insecure_skip_verify` except for known-safe internal services.
- **Do not** expose admin API (`:2019`) publicly. Use `admin off` or unix socket.
- **Do not** run as root unnecessarily. Use `setcap cap_net_bind_service=+ep /usr/bin/caddy`.
- **Do not** skip `caddy validate` before reloading config.
- **Do not** use ephemeral Docker volumes for `/data` — certificates will be lost.
- **Do not** confuse `handle` (mutually exclusive, first match) with `route` (preserves directive order).
- **Do not** forget `flush_interval -1` when proxying SSE or streaming responses.

## Resources

### references/ — Deep-Dive Documentation

| File | Description |
|---|---|
| `references/advanced-patterns.md` | On-demand TLS, dynamic backends, CEL matchers, handle_errors, rate limiting, IP geolocation, request body limits, Prometheus metrics, events system, storage backends (Consul/Redis/S3), multi-domain configs, snippets |
| `references/troubleshooting.md` | Certificate provisioning failures, ACME behind proxies/firewalls, rate limit mitigation, WebSocket proxy fixes, upload timeouts, redirect loops, Caddyfile parse errors, JSON API conflicts, systemd permissions, Docker networking, diagnostic commands |
| `references/migration-from-nginx.md` | Complete Nginx→Caddy directive mapping, 15+ configuration translations side-by-side, feature parity table, key behavioral differences, migration checklist |

### scripts/ — Executable Helpers

| Script | Description |
|---|---|
| `scripts/caddy-validate.sh` | Validates Caddyfile syntax, checks for common misconfigurations (exposed admin API, missing ask endpoint, insecure TLS), deprecation warnings, brace balance, JSON adaptation test |
| `scripts/caddy-install.sh` | Cross-platform installer — auto-detects OS and uses apt/dnf/brew or direct binary download, sets up systemd service and caddy user |
| `scripts/xcaddy-build.sh` | Builds custom Caddy with plugins via xcaddy — supports `--preset` shortcuts for popular modules (dns-cloudflare, ratelimit, storage-redis, etc.), version pinning, and verification |

### assets/ — Templates and Boilerplate

| File | Description |
|---|---|
| `assets/Caddyfile-reverse-proxy` | Production reverse proxy with HTTPS, security headers, load balancing, health checks, WebSocket/SSE support, structured JSON logging, custom error responses |
| `assets/Caddyfile-static-site` | Static file serving with gzip/zstd compression, immutable asset caching, SPA fallback (try_files), precompressed file support, security headers |
| `assets/Caddyfile-php` | Three PHP templates — generic PHP-FPM, Laravel (with Livewire paths), WordPress (with xmlrpc/wp-config blocking, upload limits, admin no-cache) |
| `assets/docker-compose.yml` | Multi-service Docker Compose with Caddy as reverse proxy, separate web/backend networks, PostgreSQL, Redis, resource limits, secrets, health checks |
| `assets/caddy.service` | Hardened systemd unit with 20+ security directives (ProtectSystem, MemoryDenyWriteExecute, SystemCallFilter, etc.), capability-based port binding, environment file support |
