# Advanced Caddy v2 Patterns

## Table of Contents

- [On-Demand TLS](#on-demand-tls)
- [Dynamic Backends](#dynamic-backends)
- [CEL Expression Matchers](#cel-expression-matchers)
- [Custom Error Pages with handle_errors](#custom-error-pages-with-handle_errors)
- [Rate Limiting](#rate-limiting)
- [IP Geolocation](#ip-geolocation)
- [Request Body Size Limits](#request-body-size-limits)
- [Metrics and Prometheus](#metrics-and-prometheus)
- [Caddy Events System](#caddy-events-system)
- [Storage Backends](#storage-backends)
- [Multi-Domain Configurations](#multi-domain-configurations)

---

## On-Demand TLS

On-demand TLS provisions certificates at TLS handshake time rather than at config load. Essential for SaaS/multi-tenant platforms where domains are added dynamically.

### Configuration

```caddyfile
{
    on_demand_tls {
        # REQUIRED: external endpoint that returns 200 to approve a domain
        ask http://localhost:5555/check-domain

        # Rate limiting to prevent abuse
        interval 5m
        burst 10
    }
}

# Catch-all HTTPS site — certs issued on first connection
https:// {
    tls {
        on_demand
    }
    reverse_proxy localhost:8080
}
```

### The `ask` Endpoint

The `ask` endpoint receives a `GET` request with `?domain=example.com`. It must:
- Return **200** to approve certificate issuance
- Return **anything else** to deny

Example Go handler:

```go
func checkDomain(w http.ResponseWriter, r *http.Request) {
    domain := r.URL.Query().Get("domain")
    if isAllowedDomain(domain) {
        w.WriteHeader(200)
        return
    }
    w.WriteHeader(403)
}
```

### Security Considerations

- **Always configure `ask`** — without it, attackers can trigger cert issuance for arbitrary domains, exhausting Let's Encrypt rate limits and filling disk
- Set `interval` and `burst` to constrain issuance rate
- The `ask` endpoint should check against a database/allowlist of customer domains
- Monitor certificate storage growth in `/data/caddy/certificates/`

### On-Demand TLS with DNS Challenge

```caddyfile
{
    on_demand_tls {
        ask http://localhost:5555/check
    }
}

https:// {
    tls {
        on_demand
        dns cloudflare {env.CF_API_TOKEN}
    }
    reverse_proxy localhost:8080
}
```

---

## Dynamic Backends

### Dynamic Upstreams via SRV Records

```caddyfile
example.com {
    reverse_proxy {
        dynamic srv {
            name _http._tcp.myservice.consul
            refresh 30s
        }
    }
}
```

### Dynamic Upstreams via A/AAAA Records

```caddyfile
example.com {
    reverse_proxy {
        dynamic a {
            name backend.internal
            port 8080
            refresh 10s
            resolvers 10.0.0.1:53
        }
    }
}
```

### Multiple Upstream Groups with Fallback

```caddyfile
example.com {
    reverse_proxy {
        to 10.0.1.1:8080 10.0.1.2:8080
        to 10.0.2.1:8080 10.0.2.2:8080

        lb_policy first
        lb_retries 2

        health_uri /healthz
        health_interval 5s

        # Fallback: second group used only if first is unhealthy
        fail_duration 10s
        max_fails 3
    }
}
```

---

## CEL Expression Matchers

CEL (Common Expression Language) matchers allow complex request matching logic beyond what named matchers provide. Use the `expression` matcher.

### Syntax

```caddyfile
@name expression <cel_expression>
```

### Available Variables

| Variable | Type | Description |
|----------|------|-------------|
| `{http.request.method}` | string | HTTP method |
| `{http.request.uri.path}` | string | Request path |
| `{http.request.host}` | string | Request host |
| `{http.request.header.*}` | string | Header value |
| `{http.request.uri.query}` | string | Raw query string |
| `{http.request.remote.host}` | string | Client IP |

### Examples

```caddyfile
# Match requests from a specific IP range during business hours
@business expression {http.request.remote.host}.startsWith("10.0.") && int(now().hour()) >= 9 && int(now().hour()) < 17

# Match API versioning from Accept header
@v2api expression {http.request.header.Accept}.contains("application/vnd.api.v2")

# Complex path matching with method constraints
@adminWrite expression {http.request.uri.path}.startsWith("/admin") && {http.request.method} in ["PUT", "POST", "DELETE"]
respond @adminWrite 403

# Match based on query parameter existence
@hasToken expression {http.request.uri.query}.contains("token=")
```

### CEL Functions Available

- String: `startsWith()`, `endsWith()`, `contains()`, `matches()` (regex)
- Logical: `&&`, `||`, `!`, ternary `? :`
- Comparison: `==`, `!=`, `<`, `>`, `<=`, `>=`
- List: `in`
- Time: `now()` (returns timestamp)

---

## Custom Error Pages with handle_errors

The `handle_errors` directive intercepts HTTP errors from upstream handlers and lets you serve custom responses.

### Basic Custom Error Pages

```caddyfile
example.com {
    root * /var/www/html
    file_server
    reverse_proxy /api/* localhost:8080

    handle_errors {
        @404 expression {http.error.status_code} == 404
        rewrite @404 /errors/404.html
        file_server

        @500 expression {http.error.status_code} >= 500
        rewrite @500 /errors/500.html
        file_server
    }
}
```

### JSON Error Responses for APIs

```caddyfile
example.com {
    handle /api/* {
        reverse_proxy localhost:8080
    }

    handle_errors {
        @api path /api/*
        header @api Content-Type "application/json"
        respond @api `{"error": "{http.error.status_code}", "message": "{http.error.message}"}` {http.error.status_code}

        # HTML fallback for non-API errors
        rewrite * /errors/{http.error.status_code}.html
        file_server {
            root /var/www/errors
        }
    }
}
```

### Error Page with Logging

```caddyfile
handle_errors {
    log {
        output file /var/log/caddy/errors.log
        format json
        level ERROR
    }
    respond "{http.error.status_code} {http.error.status_text}" {http.error.status_code}
}
```

### Available Error Placeholders

| Placeholder | Description |
|---|---|
| `{http.error.status_code}` | Numeric HTTP status code |
| `{http.error.status_text}` | HTTP status text (e.g., "Not Found") |
| `{http.error.message}` | Error message from the handler |
| `{http.error.trace}` | Error trace identifier |
| `{http.error.id}` | Unique error ID |

---

## Rate Limiting

Rate limiting requires the `caddy-ratelimit` module (install via xcaddy).

### Installation

```bash
xcaddy build --with github.com/mholt/caddy-ratelimit
```

### Basic Rate Limiting

```caddyfile
{
    order rate_limit before reverse_proxy
}

example.com {
    rate_limit {
        zone api_zone {
            key    {remote_host}
            events 100
            window 1m
        }
    }
    reverse_proxy localhost:8080
}
```

### Per-Path Rate Limits

```caddyfile
example.com {
    rate_limit {
        zone login_zone {
            key    {remote_host}
            events 5
            window 5m
        }
    }
    handle /auth/login {
        rate_limit { zone login_zone }
        reverse_proxy localhost:8080
    }

    rate_limit {
        zone general_zone {
            key    {remote_host}
            events 200
            window 1m
        }
    }
    handle {
        rate_limit { zone general_zone }
        reverse_proxy localhost:8080
    }
}
```

### Distributed Rate Limiting (Multi-Instance)

For clustered Caddy deployments, share state via Redis:

```caddyfile
{
    order rate_limit before reverse_proxy
}

example.com {
    rate_limit {
        zone api_zone {
            key    {remote_host}
            events 100
            window 1m
        }
        distributed {
            write_timeout 5s
            read_timeout  5s
        }
    }
    reverse_proxy localhost:8080
}
```

**Important**: All Caddy instances must have identical rate limit zone configurations for distributed mode to work correctly.

### Custom Rate Limit Response

When a client exceeds the limit, Caddy returns HTTP 429. Combine with `handle_errors`:

```caddyfile
handle_errors {
    @ratelimited expression {http.error.status_code} == 429
    header @ratelimited Retry-After "60"
    respond @ratelimited `{"error": "rate_limited", "retry_after": 60}` 429
}
```

---

## IP Geolocation

IP geolocation requires the `caddy-maxmind-geolocation` module and a MaxMind GeoLite2 database.

### Installation

```bash
xcaddy build --with github.com/porech/caddy-maxmind-geolocation
```

### Configuration

```caddyfile
{
    order geoip before respond
    geoip {
        database_path /var/lib/GeoIP/GeoLite2-Country.mmdb
    }
}

example.com {
    @blocked_countries expression {geoip.country_code} in ["CN", "RU", "KP"]
    respond @blocked_countries "Access denied" 403

    @eu expression {geoip.country_code} in ["DE", "FR", "IT", "ES", "NL", "BE", "AT", "PL"]
    header @eu X-Region "EU"

    reverse_proxy localhost:8080
}
```

### Available Placeholders

| Placeholder | Description |
|---|---|
| `{geoip.country_code}` | ISO country code (e.g., "US") |
| `{geoip.country_name}` | Country name |
| `{geoip.city_name}` | City name |
| `{geoip.latitude}` | Latitude |
| `{geoip.longitude}` | Longitude |
| `{geoip.time_zone}` | Timezone string |

---

## Request Body Size Limits

Use the `request_body` directive to limit upload sizes and prevent resource exhaustion.

### Basic Usage

```caddyfile
example.com {
    request_body {
        max_size 10MB
    }
    reverse_proxy localhost:8080
}
```

### Per-Path Limits

```caddyfile
example.com {
    handle /api/upload/* {
        request_body {
            max_size 100MB
        }
        reverse_proxy localhost:8080
    }

    handle /api/* {
        request_body {
            max_size 1MB
        }
        reverse_proxy localhost:8080
    }

    handle {
        request_body {
            max_size 512KB
        }
        file_server
    }
}
```

### Size Format

Supported units: `B`, `KB`, `MB`, `GB`. When exceeded, Caddy returns HTTP 413 Request Entity Too Large.

Combine with `handle_errors` for custom responses:

```caddyfile
handle_errors {
    @toolarge expression {http.error.status_code} == 413
    respond @toolarge `{"error": "File too large"}` 413
}
```

---

## Metrics and Prometheus

Caddy has built-in Prometheus metrics support — no third-party module needed.

### Enable Metrics

```caddyfile
{
    # Enable metrics on the admin API endpoint
    metrics
    admin :2019
}
```

Scrape at `http://localhost:2019/metrics`.

### Per-Host Metrics

```caddyfile
{
    metrics {
        per_host
    }
}
```

This adds host labels to HTTP metrics, useful for multi-site setups.

### Expose Metrics on a Dedicated Site

If you want metrics on a separate port (e.g., for Kubernetes service monitors):

```caddyfile
:9180 {
    metrics /metrics
}
```

### Key Metrics Exposed

| Metric | Type | Description |
|---|---|---|
| `caddy_http_requests_total` | counter | Total HTTP requests by server, handler |
| `caddy_http_request_duration_seconds` | histogram | Request latency distribution |
| `caddy_http_response_size_bytes` | histogram | Response body size distribution |
| `caddy_http_request_size_bytes` | histogram | Request body size distribution |
| `caddy_http_requests_in_flight` | gauge | Current in-flight requests |
| `caddy_tls_handshake_duration_seconds` | histogram | TLS handshake latency |
| `caddy_admin_http_requests_total` | counter | Admin API requests |

### Prometheus Scrape Config

```yaml
scrape_configs:
  - job_name: caddy
    static_configs:
      - targets: ['caddy:2019']
    scrape_interval: 15s
    metrics_path: /metrics
```

### Grafana Dashboard

Import [Caddy dashboard #14280](https://grafana.com/grafana/dashboards/14280) in Grafana for pre-built visualizations of all Caddy metrics.

---

## Caddy Events System

Caddy emits internal events that modules can subscribe to for automation and integration.

### Event Types

| Event | Description |
|---|---|
| `tls_get_certificate` | Certificate retrieved from storage |
| `cert_obtaining` | Starting to obtain a new certificate |
| `cert_obtained` | Certificate successfully obtained |
| `cert_renewed` | Certificate successfully renewed |
| `cert_failed` | Certificate obtain/renew failed |
| `config_change` | Configuration was reloaded |

### Subscribing to Events (JSON Config)

```json
{
    "apps": {
        "events": {
            "subscriptions": [
                {
                    "events": ["cert_obtained", "cert_renewed"],
                    "handlers": [
                        {
                            "handler": "exec",
                            "command": "/usr/local/bin/notify-cert-change.sh",
                            "args": ["{event.data.domain}"]
                        }
                    ]
                }
            ]
        }
    }
}
```

### Use Cases

- **Webhook notifications** on certificate events (renewal, failure)
- **Config reload triggers** — run scripts after config changes
- **Audit logging** — record cert lifecycle events for compliance
- **Alerting** — trigger PagerDuty/Slack on `cert_failed` events

---

## Storage Backends

By default, Caddy stores certificates on the local filesystem at `~/.local/share/caddy/`. For clustered deployments, use a shared storage backend.

### Consul Storage

```caddyfile
{
    storage consul {
        address     "127.0.0.1:8500"
        token       "{env.CONSUL_TOKEN}"
        prefix      "caddytls"
        aes_key     "consultls-1234567890-caddytls-32"
        tls_enabled false
    }
}
```

Module: `github.com/pteich/caddy-tlsconsul`

### Redis Storage

```caddyfile
{
    storage redis {
        host        "redis.internal"
        port        6379
        password    "{env.REDIS_PASSWORD}"
        db          0
        timeout     5
        key_prefix  "caddy"
        tls_enabled true
    }
}
```

Module: `github.com/pberkel/caddy-storage-redis`

Supports Redis Cluster and Sentinel topologies.

### S3 Storage

```caddyfile
{
    storage s3 {
        host       "s3.amazonaws.com"
        bucket     "my-caddy-certs"
        access_id  "{env.AWS_ACCESS_KEY_ID}"
        secret_key "{env.AWS_SECRET_ACCESS_KEY}"
        prefix     "ssl"
    }
}
```

Module: `github.com/ss098/certmagic-s3`

Works with any S3-compatible storage (AWS S3, MinIO, DigitalOcean Spaces).

### Building Caddy with Storage Modules

```bash
xcaddy build \
    --with github.com/pteich/caddy-tlsconsul \
    --with github.com/pberkel/caddy-storage-redis \
    --with github.com/ss098/certmagic-s3
```

### Comparison

| Backend | Latency | HA | Best For |
|---|---|---|---|
| Filesystem | Lowest | No | Single node |
| Consul | Low | Yes | HashiCorp stack |
| Redis | Very low | Yes | High performance clusters |
| S3 | Higher | Yes | Cloud-native, durability |

---

## Multi-Domain Configurations

### Multiple Domains, Same Backend

```caddyfile
example.com, www.example.com, example.org {
    reverse_proxy localhost:8080
}
```

### Domain-Specific Routing

```caddyfile
example.com {
    root * /var/www/example
    file_server
}

app.example.com {
    reverse_proxy localhost:3000
}

api.example.com {
    reverse_proxy localhost:8080
    header Content-Type "application/json"
}
```

### Wildcard with Specific Overrides

```caddyfile
# Specific subdomain takes priority
app.example.com {
    reverse_proxy localhost:3000
}

# Wildcard catches all other subdomains
*.example.com {
    tls {
        dns cloudflare {env.CF_API_TOKEN}
    }
    reverse_proxy localhost:8080
}
```

### Snippet Reuse

```caddyfile
(security_headers) {
    header {
        Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "DENY"
        Referrer-Policy "strict-origin-when-cross-origin"
        Content-Security-Policy "default-src 'self'"
        -Server
    }
}

(proxy_defaults) {
    header_up X-Real-IP {remote_host}
    header_up X-Forwarded-For {remote_host}
    header_up X-Forwarded-Proto {scheme}
}

example.com {
    import security_headers
    reverse_proxy localhost:3000 {
        import proxy_defaults
    }
}

app.example.com {
    import security_headers
    reverse_proxy localhost:8080 {
        import proxy_defaults
    }
}
```

### Environment-Based Configuration

```caddyfile
{$DOMAIN:localhost} {
    tls {$TLS_EMAIL:admin@example.com}
    root * {$SITE_ROOT:/var/www/html}
    reverse_proxy {$BACKEND:localhost:8080}
    file_server
}
```

Run with: `DOMAIN=example.com TLS_EMAIL=admin@example.com caddy run`
