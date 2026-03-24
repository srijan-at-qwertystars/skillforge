# Advanced Nginx Patterns

Comprehensive reference for advanced Nginx configuration patterns beyond basic reverse proxying
and load balancing. Covers conditional logic, traffic management, authentication, streaming,
and monitoring.

## Table of Contents

- [Map Directive for Conditional Logic](#map-directive-for-conditional-logic)
- [split_clients for A/B Testing](#split_clients-for-ab-testing)
- [Mirror for Traffic Duplication](#mirror-for-traffic-duplication)
- [auth_request for Subrequest Authentication](#auth_request-for-subrequest-authentication)
- [OpenID Connect Integration](#openid-connect-integration)
- [Dynamic Upstreams with Resolver](#dynamic-upstreams-with-resolver)
- [stub_status and Metrics](#stub_status-and-metrics)
- [Streaming Patterns](#streaming-patterns)
  - [Chunked Transfer Encoding](#chunked-transfer-encoding)
  - [Server-Sent Events (SSE)](#server-sent-events-sse)
  - [gRPC Proxying](#grpc-proxying)

---

## Map Directive for Conditional Logic

The `map` directive creates variables whose values depend on other variables. It compiles
into a hash table at config load — far more efficient than `if` chains. Defined in the
`http` block only, usable everywhere.

### Basic Syntax

```nginx
map $source_variable $new_variable {
    default       value_if_no_match;
    exact_value   result;
    ~regex        result_for_regex;
    ~*iregex      case_insensitive_regex;
}
```

### Mobile Detection and Routing

```nginx
map $http_user_agent $is_mobile {
    default         0;
    "~*mobile"      1;
    "~*android"     1;
    "~*iphone"      1;
    "~*ipad"        1;
}

map $is_mobile $mobile_backend {
    0   desktop_upstream;
    1   mobile_upstream;
}

server {
    location / {
        proxy_pass http://$mobile_backend;
    }
}
```

### Backend Routing by URI

```nginx
map $uri $api_upstream {
    ~^/api/v1/   api_v1;
    ~^/api/v2/   api_v2;
    default      api_v2;
}
```

### Conditional Logging (Skip Health Checks)

```nginx
map $request_uri $loggable {
    ~*^/health    0;
    ~*^/ready     0;
    ~*^/metrics   0;
    default       1;
}

access_log /var/log/nginx/access.log combined if=$loggable;
```

### Dynamic CORS Origins

```nginx
map $http_origin $cors_origin {
    default                 "";
    "~^https://app\.example\.com$"   $http_origin;
    "~^https://admin\.example\.com$" $http_origin;
    "~^https://.*\.staging\.example\.com$" $http_origin;
}

server {
    location /api/ {
        add_header Access-Control-Allow-Origin $cors_origin always;
        add_header Access-Control-Allow-Methods "GET, POST, PUT, DELETE, OPTIONS" always;
        add_header Access-Control-Allow-Headers "Authorization, Content-Type" always;
        add_header Access-Control-Max-Age 86400 always;

        if ($request_method = OPTIONS) {
            return 204;
        }
        proxy_pass http://backend;
    }
}
```

### Connection Limit Exemptions

```nginx
# Exempt internal IPs from rate limiting
map $remote_addr $limit_key {
    10.0.0.0/8      "";
    172.16.0.0/12   "";
    192.168.0.0/16  "";
    default         $binary_remote_addr;
}

limit_req_zone $limit_key zone=api:10m rate=10r/s;
```

### Chaining Maps

```nginx
map $http_x_forwarded_proto $real_scheme {
    default $scheme;
    https   https;
}

map $real_scheme $hsts_header {
    https   "max-age=63072000; includeSubDomains; preload";
    default "";
}

add_header Strict-Transport-Security $hsts_header always;
```

**Key rules**: Maps are evaluated lazily (only when the variable is used). They cannot be
defined inside `server` or `location` blocks. Use `hostnames` flag to enable wildcard
hostname matching. The `volatile` flag disables caching of the result.

---

## split_clients for A/B Testing

The `split_clients` directive deterministically splits traffic into buckets based on a hash
of a variable. The hash is consistent — the same input always maps to the same bucket.

### Basic A/B Split

```nginx
split_clients "${remote_addr}${http_user_agent}" $variant {
    50%     "control";
    50%     "experiment";
}

upstream control {
    server 10.0.0.10:8080;
}

upstream experiment {
    server 10.0.0.20:8080;
}

server {
    location / {
        proxy_pass http://$variant;
    }
}
```

### Multi-Variant Canary Deployment

```nginx
split_clients "${remote_addr}" $app_version {
    5%      "canary";
    95%     "stable";
}

upstream stable {
    server 10.0.0.10:8080;
    server 10.0.0.11:8080;
}

upstream canary {
    server 10.0.0.20:8080;
}

server {
    location / {
        proxy_pass http://$app_version;
        add_header X-App-Version $app_version;
    }
}
```

### Cookie-Based Sticky A/B Testing

```nginx
split_clients "${cookie_ab_test}" $ab_bucket {
    30%     "new_design";
    70%     "old_design";
}

map $cookie_ab_test $needs_cookie {
    default   1;
    ~.+       0;
}

server {
    location / {
        if ($needs_cookie) {
            add_header Set-Cookie "ab_test=$request_id; Path=/; Max-Age=86400";
        }
        proxy_pass http://$ab_bucket;
    }
}
```

**Tips**: The hash string should include something unique per user for user-consistent
bucketing. Percentages must sum to 100% (last bucket gets the remainder if using `*`).
This is a compile-time module — requires `--with-http_split_clients_module` (included by
default in most builds).

---

## Mirror for Traffic Duplication

The `mirror` module duplicates live requests to a secondary backend for testing, analytics,
or shadow deployments. Only the primary backend's response reaches the client.

### Basic Traffic Mirroring

```nginx
server {
    location /api/ {
        mirror /mirror_api;
        mirror_request_body on;
        proxy_pass http://production_backend;
    }

    location = /mirror_api {
        internal;
        proxy_pass http://staging_backend$request_uri;
        proxy_set_header Host $host;
        proxy_set_header X-Original-URI $request_uri;
        proxy_connect_timeout 1s;
        proxy_read_timeout 5s;
    }
}
```

### Multiple Mirrors

```nginx
location / {
    mirror /mirror_analytics;
    mirror /mirror_staging;
    mirror_request_body on;
    proxy_pass http://production;
}

location = /mirror_analytics {
    internal;
    proxy_pass http://analytics_service$request_uri;
}

location = /mirror_staging {
    internal;
    proxy_pass http://staging_service$request_uri;
}
```

### Selective Mirroring (POST Requests Only)

```nginx
map $request_method $do_mirror {
    POST    /mirror_backend;
    default "";
}

server {
    location /api/ {
        mirror $do_mirror;
        mirror_request_body on;
        proxy_pass http://production;
    }

    location = /mirror_backend {
        internal;
        proxy_pass http://shadow_backend$request_uri;
    }
}
```

**Caveats**: Mirrored requests add latency and load. The mirror subrequest timeout does NOT
affect the client response. Always set short timeouts on mirror locations. Mirror is not
available in streams (TCP/UDP), only HTTP. The module is included by default since Nginx 1.13.4.

---

## auth_request for Subrequest Authentication

The `auth_request` directive delegates authentication to an external service via an internal
subrequest. The auth service returns 2xx to allow, 401/403 to deny.

### Basic Pattern

```nginx
server {
    location /protected/ {
        auth_request /auth;
        auth_request_set $auth_user $upstream_http_x_auth_user;
        auth_request_set $auth_role $upstream_http_x_auth_role;

        proxy_set_header X-Auth-User $auth_user;
        proxy_set_header X-Auth-Role $auth_role;
        proxy_pass http://app_backend;
    }

    location = /auth {
        internal;
        proxy_pass http://auth_service/validate;
        proxy_pass_request_body off;
        proxy_set_header Content-Length "";
        proxy_set_header X-Original-URI $request_uri;
        proxy_set_header X-Original-Method $request_method;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_cache auth_cache;
        proxy_cache_valid 200 5m;
        proxy_cache_key "$cookie_session_token";
    }
}
```

### Custom Error Handling

```nginx
location /app/ {
    auth_request /auth;
    error_page 401 = @login_redirect;
    error_page 403 = @forbidden;
    proxy_pass http://backend;
}

location @login_redirect {
    return 302 /login?redirect=$request_uri;
}

location @forbidden {
    return 403 '{"error": "insufficient_permissions"}';
    default_type application/json;
}
```

### Token Relay Pattern

```nginx
location /api/ {
    auth_request /auth;
    auth_request_set $access_token $upstream_http_x_access_token;
    auth_request_set $token_expiry $upstream_http_x_token_expiry;

    proxy_set_header Authorization "Bearer $access_token";
    proxy_set_header X-Token-Expiry $token_expiry;
    proxy_pass http://api_backend;
}
```

**Important**: `auth_request` adds latency to every request. Cache auth responses where
possible. The subrequest is a GET by default — body is not forwarded. Always set
`proxy_pass_request_body off` in the auth location. Requires
`--with-http_auth_request_module` (included in most distributions).

---

## OpenID Connect Integration

### Using oauth2-proxy (Open Source Nginx)

```nginx
# OAuth2 proxy endpoints
location /oauth2/ {
    proxy_pass http://127.0.0.1:4180;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Auth-Request-Redirect $request_uri;
}

location = /oauth2/auth {
    internal;
    proxy_pass http://127.0.0.1:4180;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-Uri $request_uri;
    proxy_set_header Content-Length "";
    proxy_pass_request_body off;
}

# Protected application
server {
    location / {
        auth_request /oauth2/auth;
        error_page 401 = @oauth2_signin;

        # Pass identity headers from oauth2-proxy
        auth_request_set $user  $upstream_http_x_auth_request_user;
        auth_request_set $email $upstream_http_x_auth_request_email;
        proxy_set_header X-User  $user;
        proxy_set_header X-Email $email;

        proxy_pass http://app_backend;
    }

    location @oauth2_signin {
        return 302 /oauth2/sign_in?rd=$scheme://$host$request_uri;
    }
}
```

### Using lua-resty-openidc (OpenResty)

```nginx
# Requires OpenResty with lua-resty-openidc
location / {
    access_by_lua_block {
        local opts = {
            redirect_uri = "https://example.com/callback",
            discovery = "https://idp.example.com/.well-known/openid-configuration",
            client_id = "my-client-id",
            client_secret = "my-client-secret",
            scope = "openid email profile",
            session_contents = {id_token=true}
        }
        local res, err = require("resty.openidc").authenticate(opts)
        if err then
            ngx.status = 500
            ngx.say(err)
            ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
        end
        ngx.req.set_header("X-User", res.id_token.sub)
        ngx.req.set_header("X-Email", res.id_token.email)
    }
    proxy_pass http://backend;
}
```

---

## Dynamic Upstreams with Resolver

When using variables in `proxy_pass`, Nginx resolves DNS at runtime instead of startup.
This is essential for service discovery, Kubernetes services, and elastic backends.

### Basic Dynamic Resolution

```nginx
server {
    resolver 10.0.0.2 valid=30s ipv6=off;
    resolver_timeout 5s;

    set $backend "http://api.service.consul:8080";

    location / {
        proxy_pass $backend;
        proxy_http_version 1.1;
        proxy_set_header Host api.service.consul;
        proxy_set_header Connection "";
    }
}
```

### Kubernetes Service Discovery

```nginx
server {
    # Use kube-dns/CoreDNS
    resolver kube-dns.kube-system.svc.cluster.local valid=5s;

    location /users/ {
        set $users_svc "http://users-service.default.svc.cluster.local:8080";
        proxy_pass $users_svc;
    }

    location /orders/ {
        set $orders_svc "http://orders-service.default.svc.cluster.local:8080";
        proxy_pass $orders_svc;
    }
}
```

### Consul-Based Service Discovery

```nginx
resolver 127.0.0.1:8600 valid=5s;

upstream dynamic_backend {
    server service.consul resolve;
    # Requires Nginx Plus for 'resolve' in upstream
}

# Open source alternative: use variable-based proxy_pass
server {
    set $backend "http://myapp.service.consul";

    location / {
        proxy_pass $backend;
    }
}
```

**Key points**: The `resolver` directive must specify a DNS server (not `/etc/resolv.conf`).
`valid=Ns` controls TTL override — set shorter than actual DNS TTL for faster failover.
Variable-based `proxy_pass` requires the full URL (scheme + host). Without variables,
DNS is resolved once at startup/reload only. The `ipv6=off` flag avoids AAAA lookups
when not needed.

---

## stub_status and Metrics

### Enable stub_status

```nginx
server {
    listen 8080;
    server_name 127.0.0.1;

    location /nginx_status {
        stub_status on;
        allow 127.0.0.1;
        allow 10.0.0.0/8;
        deny all;
    }
}
```

Output format:
```
Active connections: 291
server accepts handled requests
 16630948 16630948 31070465
Reading: 6 Writing: 179 Waiting: 106
```

- **Active connections**: current client connections including waiting
- **accepts**: total accepted connections
- **handled**: total handled connections (equals accepts unless resource limits hit)
- **requests**: total client requests
- **Reading**: connections reading request header
- **Writing**: connections writing response back
- **Waiting**: idle keepalive connections

### Prometheus Exporter Integration

```bash
# Install and run nginx-prometheus-exporter
./nginx-prometheus-exporter \
    --nginx.scrape-uri=http://127.0.0.1:8080/nginx_status \
    --web.listen-address=:9113
```

Prometheus scrape config:
```yaml
scrape_configs:
  - job_name: 'nginx'
    static_configs:
      - targets: ['localhost:9113']
    scrape_interval: 15s
```

### Systemd Service for Exporter

```ini
[Unit]
Description=NGINX Prometheus Exporter
After=network-online.target nginx.service

[Service]
Type=simple
User=nginx_exporter
ExecStart=/usr/local/bin/nginx-prometheus-exporter \
    --nginx.scrape-uri=http://127.0.0.1:8080/nginx_status
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

### JSON Metrics Endpoint (No Exporter)

```nginx
# Lightweight JSON metrics using Lua (requires OpenResty or ngx_http_lua_module)
location /metrics.json {
    allow 127.0.0.1;
    allow 10.0.0.0/8;
    deny all;
    default_type application/json;
    content_by_lua_block {
        local accepted, handled, requests = ngx.var.connections_active or 0, 0, 0
        ngx.say(string.format(
            '{"active_connections":%s,"reading":%s,"writing":%s,"waiting":%s}',
            ngx.var.connections_active,
            ngx.var.connections_reading,
            ngx.var.connections_writing,
            ngx.var.connections_waiting
        ))
    }
}
```

---

## Streaming Patterns

### Chunked Transfer Encoding

```nginx
location /stream/ {
    proxy_pass http://streaming_backend;
    proxy_http_version 1.1;
    proxy_set_header Connection "";

    # Disable buffering for streaming responses
    proxy_buffering off;
    proxy_cache off;

    # Allow chunked transfer
    chunked_transfer_encoding on;

    # Don't limit response size
    proxy_max_temp_file_size 0;
}
```

### Server-Sent Events (SSE)

SSE requires disabling proxy buffering and setting appropriate timeouts to keep
the connection alive for long-lived event streams.

```nginx
location /events/ {
    proxy_pass http://sse_backend;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header Connection "";
    proxy_set_header X-Real-IP $remote_addr;

    # Critical for SSE
    proxy_buffering off;
    proxy_cache off;
    proxy_read_timeout 86400s;    # Keep connection open (24h)
    proxy_send_timeout 86400s;

    # Ensure chunked encoding passes through
    chunked_transfer_encoding on;

    # Don't add gzip — SSE streams should not be compressed mid-stream
    gzip off;
}
```

### gRPC Proxying

gRPC requires HTTP/2 and uses the `grpc_pass` directive (not `proxy_pass`).

```nginx
upstream grpc_backend {
    server 127.0.0.1:50051;
    keepalive 32;
}

server {
    listen 443 ssl http2;
    server_name grpc.example.com;

    ssl_certificate /etc/ssl/grpc.crt;
    ssl_certificate_key /etc/ssl/grpc.key;

    location / {
        grpc_pass grpc://grpc_backend;
        grpc_set_header Host $host;
        grpc_set_header X-Real-IP $remote_addr;
        grpc_set_header X-Forwarded-For $proxy_add_x_forwarded_for;

        # Timeouts for streaming RPCs
        grpc_read_timeout 300s;
        grpc_send_timeout 300s;

        # gRPC error handling
        error_page 502 = /grpc_error_502;
    }

    # Return proper gRPC error on upstream failure
    location = /grpc_error_502 {
        internal;
        default_type application/grpc;
        add_header grpc-status 14;            # UNAVAILABLE
        add_header grpc-message "upstream unavailable";
        add_header content-length 0;
        return 204;
    }
}
```

### gRPC with TLS to Backend

```nginx
location / {
    grpc_pass grpcs://secure_grpc_backend;
    grpc_ssl_certificate /etc/ssl/client.crt;
    grpc_ssl_certificate_key /etc/ssl/client.key;
    grpc_ssl_trusted_certificate /etc/ssl/ca.crt;
    grpc_ssl_verify on;
}
```

### Mixed gRPC and HTTP on Same Port

```nginx
map $content_type $backend_type {
    default          "http";
    "application/grpc" "grpc";
}

server {
    listen 443 ssl http2;

    location / {
        # Route gRPC vs HTTP based on content-type
        if ($backend_type = "grpc") {
            grpc_pass grpc://grpc_backend;
        }

        proxy_pass http://http_backend;
        proxy_http_version 1.1;
    }
}
```

**Protocol summary**:

| Protocol   | Directive    | Transport | Buffering |
|-----------|-------------|-----------|-----------|
| HTTP/REST | `proxy_pass` | HTTP/1.1+ | Default on |
| SSE       | `proxy_pass` | HTTP/1.1+ | Must disable |
| gRPC      | `grpc_pass`  | HTTP/2    | N/A (framed) |
| WebSocket | `proxy_pass` | HTTP/1.1  | N/A (upgraded) |
