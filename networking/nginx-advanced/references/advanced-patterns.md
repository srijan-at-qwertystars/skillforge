# Nginx Advanced Patterns Reference

## Table of Contents

- [Dynamic Upstream Configuration](#dynamic-upstream-configuration)
- [Lua Scripting with OpenResty](#lua-scripting-with-openresty)
- [Stream Module — TCP/UDP Proxy](#stream-module--tcpudp-proxy)
- [Map Directive Patterns](#map-directive-patterns)
- [split_clients A/B Testing](#split_clients-ab-testing)
- [Mirror Module](#mirror-module)
- [auth_request Subrequests](#auth_request-subrequests)
- [GeoIP Module](#geoip-module)
- [Content-Based Routing](#content-based-routing)
- [Advanced Variables and Internals](#advanced-variables-and-internals)

---

## Dynamic Upstream Configuration

### Resolving DNS at Runtime

By default, nginx resolves upstream DNS at startup and caches it forever. For dynamic backends (containers, cloud), resolve at runtime:

```nginx
# Use a variable in proxy_pass to force runtime resolution
resolver 127.0.0.53 valid=30s ipv6=off;
resolver_timeout 5s;

server {
    set $backend "backend.service.consul:8080";

    location / {
        proxy_pass http://$backend;
        proxy_set_header Host $host;
    }
}
```

**Critical:** When using a variable in `proxy_pass`, nginx does NOT use `upstream {}` blocks. The `resolver` directive is **required** or requests will fail with 502.

### Upstream with Consistent Hashing

Minimize cache invalidation when backends change:

```nginx
upstream cache_tier {
    hash $request_uri consistent;
    server cache-1:11211;
    server cache-2:11211;
    server cache-3:11211;
}
```

The `consistent` keyword uses ketama hashing — removing one server only remaps ~1/N of keys.

### Dynamic Upstreams via NJS (nginx JavaScript)

```nginx
# /etc/nginx/njs/upstreams.js
async function selectUpstream(r) {
    let res = await ngx.fetch('http://service-registry:8500/v1/catalog/service/web');
    let services = JSON.parse(res.text());
    let idx = Math.floor(Math.random() * services.length);
    return `${services[idx].ServiceAddress}:${services[idx].ServicePort}`;
}
export default { selectUpstream };

# nginx.conf
load_module modules/ngx_http_js_module.so;

http {
    js_import upstreams from njs/upstreams.js;
    js_set $dynamic_backend upstreams.selectUpstream;

    server {
        location / {
            proxy_pass http://$dynamic_backend;
        }
    }
}
```

### Slow Start (NGINX Plus)

Gradually ramp traffic to a recovering server:

```nginx
upstream backend {
    server 10.0.0.1:8080 slow_start=30s;
    server 10.0.0.2:8080;
}
```

OSS alternative: use `weight` and manually adjust, or script it with the upstream configuration API.

---

## Lua Scripting with OpenResty

OpenResty embeds LuaJIT into nginx. Install via `openresty` package, not stock nginx.

### Request Processing Phases

Lua hooks into nginx phases in order:

| Phase | Directive | Use Case |
|---|---|---|
| `init_by_lua_block` | Worker start | Load shared data, init modules |
| `init_worker_by_lua_block` | Each worker fork | Timers, background jobs |
| `set_by_lua_block` | Variable assignment | Compute a variable value |
| `rewrite_by_lua_block` | Rewrite phase | URL rewriting, redirects |
| `access_by_lua_block` | Access control | Auth, rate limiting, ACLs |
| `content_by_lua_block` | Content generation | Full response from Lua |
| `header_filter_by_lua_block` | Response headers | Modify upstream response headers |
| `body_filter_by_lua_block` | Response body | Transform upstream body |
| `log_by_lua_block` | Log phase | Custom logging, metrics |
| `balancer_by_lua_block` | Upstream selection | Custom load balancing logic |

### Custom Rate Limiter with Shared Dict

```nginx
http {
    lua_shared_dict rate_limit 10m;

    server {
        location /api/ {
            access_by_lua_block {
                local limit = ngx.shared.rate_limit
                local key = ngx.var.binary_remote_addr
                local rate = 100  -- requests per window
                local window = 60  -- seconds

                local count, err = limit:incr(key, 1, 0, window)
                if count > rate then
                    ngx.status = 429
                    ngx.header["Retry-After"] = window
                    ngx.say('{"error":"rate limit exceeded"}')
                    return ngx.exit(429)
                end
            }
            proxy_pass http://backend;
        }
    }
}
```

### JWT Validation in Lua

```nginx
access_by_lua_block {
    local cjson = require "cjson"
    local jwt = require "resty.jwt"

    local auth_header = ngx.var.http_Authorization
    if not auth_header then
        return ngx.exit(401)
    end

    local token = auth_header:match("Bearer%s+(.+)")
    if not token then
        return ngx.exit(401)
    end

    local jwt_obj = jwt:verify("my-secret-key", token)
    if not jwt_obj.verified then
        ngx.log(ngx.WARN, "JWT verification failed: ", jwt_obj.reason)
        return ngx.exit(403)
    end

    -- Pass claims to upstream
    ngx.req.set_header("X-User-ID", jwt_obj.payload.sub)
    ngx.req.set_header("X-User-Role", jwt_obj.payload.role)
}
```

### Shared Memory Caching

```nginx
lua_shared_dict cache 50m;

content_by_lua_block {
    local cache = ngx.shared.cache
    local key = ngx.var.request_uri
    local cached = cache:get(key)

    if cached then
        ngx.header["X-Cache"] = "HIT"
        ngx.say(cached)
        return
    end

    -- Fetch from upstream
    local res = ngx.location.capture("/internal-backend" .. key)
    if res.status == 200 then
        cache:set(key, res.body, 300)  -- TTL 300s
        ngx.header["X-Cache"] = "MISS"
        ngx.say(res.body)
    else
        ngx.exit(res.status)
    end
}
```

### Custom Load Balancer

```nginx
upstream dynamic_backend {
    server 0.0.0.1;  # placeholder, overridden by Lua
    balancer_by_lua_block {
        local balancer = require "ngx.balancer"

        -- Fetch server list (from shared dict, API, etc.)
        local servers = {
            { addr = "10.0.0.1", port = 8080, weight = 3 },
            { addr = "10.0.0.2", port = 8080, weight = 1 },
        }

        -- Weighted random selection
        local total = 0
        for _, s in ipairs(servers) do total = total + s.weight end
        local r = math.random() * total
        local acc = 0
        for _, s in ipairs(servers) do
            acc = acc + s.weight
            if r <= acc then
                local ok, err = balancer.set_current_peer(s.addr, s.port)
                if not ok then
                    ngx.log(ngx.ERR, "balancer error: ", err)
                    return ngx.exit(502)
                end
                return
            end
        end
    }
}
```

---

## Stream Module — TCP/UDP Proxy

The `stream {}` block handles L4 (TCP/UDP) proxying. Lives **outside** the `http {}` block in `nginx.conf`.

### Basic TCP Proxy

```nginx
stream {
    upstream mysql_servers {
        server db-primary:3306;
        server db-replica:3306 backup;
    }

    server {
        listen 3306;
        proxy_pass mysql_servers;
        proxy_connect_timeout 5s;
        proxy_timeout 300s;  # idle timeout
    }
}
```

### UDP Load Balancer (DNS Example)

```nginx
stream {
    upstream dns_servers {
        server 10.0.0.1:53;
        server 10.0.0.2:53;
    }

    server {
        listen 53 udp;
        proxy_pass dns_servers;
        proxy_timeout 5s;
        proxy_responses 1;  # expect 1 response per request
    }
}
```

### SSL/TLS Termination for TCP

```nginx
stream {
    upstream postgres {
        server db:5432;
    }

    server {
        listen 5432 ssl;
        ssl_certificate /etc/ssl/server.crt;
        ssl_certificate_key /etc/ssl/server.key;
        ssl_protocols TLSv1.2 TLSv1.3;

        proxy_pass postgres;
        proxy_ssl on;  # re-encrypt to upstream (optional)
        proxy_ssl_verify on;
        proxy_ssl_trusted_certificate /etc/ssl/ca.crt;
    }
}
```

### SSL Preread — Route by SNI Without Decryption

```nginx
stream {
    map $ssl_preread_server_name $backend {
        app1.example.com    app1_upstream;
        app2.example.com    app2_upstream;
        default             default_upstream;
    }

    upstream app1_upstream { server 10.0.0.1:443; }
    upstream app2_upstream { server 10.0.0.2:443; }
    upstream default_upstream { server 10.0.0.3:443; }

    server {
        listen 443;
        ssl_preread on;
        proxy_pass $backend;
    }
}
```

This passes encrypted traffic through — the backend handles TLS. Useful for multi-tenant SSL routing without needing all certificates on the proxy.

### Stream Access Control

```nginx
stream {
    # Geo-based access control
    geo $remote_addr $stream_access {
        default       0;
        10.0.0.0/8    1;
        172.16.0.0/12 1;
        192.168.0.0/16 1;
    }

    server {
        listen 6379;
        proxy_pass redis_cluster;

        # Restrict Redis access to internal networks
        # (requires stream_map + set + return approach)
    }
}
```

---

## Map Directive Patterns

`map` creates variables from other variables using a lookup table. Evaluated lazily (only when the variable is used).

### Basic Pattern: API Versioning

```nginx
map $http_accept $api_version {
    default        "v2";
    "~v1"          "v1";
    "~v3"          "v3";
}

upstream api_v1 { server 10.0.0.1:8080; }
upstream api_v2 { server 10.0.0.2:8080; }
upstream api_v3 { server 10.0.0.3:8080; }

map $api_version $api_backend {
    v1    api_v1;
    v2    api_v2;
    v3    api_v3;
}

server {
    location /api/ {
        proxy_pass http://$api_backend;
    }
}
```

### Conditional Logging

```nginx
# Only log non-2xx responses and slow requests
map $status $log_condition {
    ~^2    0;
    default 1;
}

map $request_time $slow_request {
    "~^[0-9]*\.[0-9]{0,2}$"  0;  # < 1 second
    default                    1;  # >= 1 second
}

# Combine conditions
map "$log_condition:$slow_request" $should_log {
    "0:0"   0;
    default 1;
}

access_log /var/log/nginx/important.log combined if=$should_log;
```

### Mobile Detection

```nginx
map $http_user_agent $is_mobile {
    default 0;
    "~*android|iphone|ipod|mobile" 1;
}

server {
    location / {
        if ($is_mobile) {
            rewrite ^ /mobile$request_uri last;
        }
        proxy_pass http://desktop_backend;
    }

    location /mobile/ {
        internal;
        proxy_pass http://mobile_backend;
    }
}
```

### Rate Limit Key Selection

```nginx
# Rate limit by API key if present, otherwise by IP
map $http_x_api_key $rate_key {
    default   $binary_remote_addr;
    "~.+"     $http_x_api_key;
}

limit_req_zone $rate_key zone=api:10m rate=100r/s;
```

### Chained Maps for Complex Logic

```nginx
# Determine environment from hostname
map $host $environment {
    "~^dev\."     development;
    "~^staging\." staging;
    default       production;
}

# Set backend based on environment
map $environment $backend_addr {
    development  "dev-server:8080";
    staging      "staging-server:8080";
    production   "prod-cluster";
}

# Set cache duration by environment
map $environment $cache_ttl {
    development  "0";
    staging      "60";
    production   "3600";
}
```

---

## split_clients A/B Testing

Distributes clients into buckets using a consistent hash. The distribution is deterministic per client key.

### Basic A/B Test

```nginx
split_clients "${remote_addr}${http_user_agent}" $ab_variant {
    50%   "A";
    *     "B";  # remainder gets B
}

upstream variant_a { server 10.0.0.1:8080; }
upstream variant_b { server 10.0.0.2:8080; }

map $ab_variant $ab_backend {
    A  variant_a;
    B  variant_b;
}

server {
    location / {
        add_header X-AB-Variant $ab_variant;
        proxy_pass http://$ab_backend;
    }
}
```

### Multi-Variant (Canary Deploy)

```nginx
split_clients "$request_id" $canary {
    5%    "canary";
    *     "stable";
}

upstream stable { server 10.0.0.1:8080; server 10.0.0.2:8080; }
upstream canary { server 10.0.1.1:8080; }

map $canary $deploy_backend {
    canary  canary;
    stable  stable;
}

server {
    location / {
        proxy_pass http://$deploy_backend;
        add_header X-Deploy $canary always;
    }
}
```

### Cookie-Based Sticky Variant

```nginx
# Assign variant once, persist via cookie
map $cookie_ab_variant $variant_from_cookie {
    A       "A";
    B       "B";
    default "";
}

split_clients "${remote_addr}" $variant_from_split {
    50%   "A";
    *     "B";
}

map $variant_from_cookie $final_variant {
    ""      $variant_from_split;
    default $variant_from_cookie;
}

server {
    location / {
        add_header Set-Cookie "ab_variant=$final_variant; Path=/; Max-Age=86400" always;
        proxy_pass http://variant_${final_variant};
    }
}
```

---

## Mirror Module

Sends copies of requests to another backend for testing, monitoring, or shadow traffic. Responses from the mirror are **discarded**.

### Basic Request Mirroring

```nginx
server {
    location / {
        mirror /mirror;
        mirror_request_body on;  # forward POST/PUT body too
        proxy_pass http://production_backend;
    }

    location = /mirror {
        internal;
        proxy_pass http://staging_backend$request_uri;
        proxy_set_header Host $host;
        proxy_connect_timeout 1s;
        proxy_read_timeout 5s;
    }
}
```

### Multiple Mirrors

```nginx
location / {
    mirror /mirror-staging;
    mirror /mirror-analytics;
    proxy_pass http://production;
}

location = /mirror-staging {
    internal;
    proxy_pass http://staging$request_uri;
}

location = /mirror-analytics {
    internal;
    proxy_pass http://analytics_collector$request_uri;
}
```

### Percentage-Based Mirroring

```nginx
split_clients "$request_id" $do_mirror {
    10%   1;
    *     0;
}

server {
    location / {
        # Only mirror 10% of traffic
        if ($do_mirror) {
            mirror /mirror;
        }
        proxy_pass http://production;
    }

    location = /mirror {
        internal;
        proxy_pass http://shadow$request_uri;
    }
}
```

**Warning:** Mirroring doubles request load on nginx. For write operations, ensure the mirror target handles duplicates idempotently or uses a read-only setup.

---

## auth_request Subrequests

Delegates authentication/authorization to an external service. Nginx makes a subrequest; if the auth service returns 2xx, the original request proceeds. 401/403 denies it.

### Basic Auth Gateway

```nginx
server {
    location / {
        auth_request /auth;
        auth_request_set $auth_user $upstream_http_x_auth_user;
        auth_request_set $auth_role $upstream_http_x_auth_role;

        proxy_set_header X-Auth-User $auth_user;
        proxy_set_header X-Auth-Role $auth_role;
        proxy_pass http://backend;
    }

    location = /auth {
        internal;
        proxy_pass http://auth-service:9000/validate;
        proxy_pass_request_body off;
        proxy_set_header Content-Length "";
        proxy_set_header X-Original-URI $request_uri;
        proxy_set_header X-Original-Method $request_method;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_cache auth_cache;
        proxy_cache_valid 200 5m;
        proxy_cache_key "$http_authorization";
    }
}
```

### Custom Error Pages on Auth Failure

```nginx
location / {
    auth_request /auth;
    error_page 401 = @login_redirect;
    error_page 403 = @forbidden;
    proxy_pass http://backend;
}

location @login_redirect {
    return 302 /login?next=$request_uri;
}

location @forbidden {
    return 403 '{"error":"insufficient permissions"}';
    add_header Content-Type application/json;
}
```

### Per-Route Authorization

```nginx
# Public routes — no auth
location /public/ {
    proxy_pass http://backend;
}

# Authenticated routes
location /api/ {
    auth_request /auth;
    proxy_pass http://backend;
}

# Admin routes — auth + role check
location /admin/ {
    auth_request /auth-admin;
    proxy_pass http://admin_backend;
}

location = /auth-admin {
    internal;
    proxy_pass http://auth-service:9000/validate?require_role=admin;
    proxy_pass_request_body off;
    proxy_set_header Content-Length "";
    proxy_set_header X-Original-URI $request_uri;
}
```

---

## GeoIP Module

Map client IP to geographic data for routing, restriction, or analytics.

### Setup with MaxMind GeoIP2

```nginx
load_module modules/ngx_http_geoip2_module.so;

http {
    geoip2 /usr/share/GeoIP/GeoLite2-Country.mmdb {
        auto_reload 24h;
        $geoip2_country_code country iso_code;
        $geoip2_country_name country names en;
    }

    geoip2 /usr/share/GeoIP/GeoLite2-City.mmdb {
        $geoip2_city city names en;
        $geoip2_region subdivisions 0 names en;
        $geoip2_latitude location latitude;
        $geoip2_longitude location longitude;
    }
}
```

### Geo-Based Upstream Selection

```nginx
map $geoip2_country_code $geo_backend {
    US      us_backend;
    CA      us_backend;
    GB      eu_backend;
    DE      eu_backend;
    FR      eu_backend;
    JP      asia_backend;
    default us_backend;
}

upstream us_backend { server us-east.example.com:443; }
upstream eu_backend { server eu-west.example.com:443; }
upstream asia_backend { server ap-northeast.example.com:443; }

server {
    location / {
        proxy_pass https://$geo_backend;
    }
}
```

### Country-Based Blocking

```nginx
map $geoip2_country_code $blocked_country {
    default 0;
    XX      1;  # replace with actual country codes
    YY      1;
}

server {
    if ($blocked_country) {
        return 403 "Access denied from your region";
    }
}
```

### Forwarding Geo Headers to Upstream

```nginx
location / {
    proxy_set_header X-Geo-Country $geoip2_country_code;
    proxy_set_header X-Geo-City $geoip2_city;
    proxy_set_header X-Geo-Region $geoip2_region;
    proxy_pass http://backend;
}
```

---

## Content-Based Routing

Route requests based on body content, headers, cookies, or query parameters.

### Route by Content-Type

```nginx
map $content_type $content_backend {
    "application/json"         json_api;
    "application/xml"          xml_api;
    "application/graphql"      graphql_api;
    "multipart/form-data"      upload_api;
    default                    json_api;
}

server {
    location /api/ {
        proxy_pass http://$content_backend;
    }
}
```

### Route by Query Parameter

```nginx
# Route ?version=v2 to different backend
map $arg_version $versioned_backend {
    v1      legacy_api;
    v2      modern_api;
    default modern_api;
}

server {
    location /api/ {
        proxy_pass http://$versioned_backend;
    }
}
```

### Route by Cookie

```nginx
map $cookie_feature_flags $feature_backend {
    "~*new-checkout"  checkout_v2;
    default           checkout_v1;
}
```

### GraphQL Operation Routing (with Lua)

```nginx
# Route GraphQL mutations to write replicas, queries to read replicas
access_by_lua_block {
    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    if body then
        if body:match('"mutation"') or body:match('"mutation%s') then
            ngx.var.graphql_backend = "write_backend"
        else
            ngx.var.graphql_backend = "read_backend"
        end
    end
}
```

---

## Advanced Variables and Internals

### Useful Built-in Variables

| Variable | Value | Use Case |
|---|---|---|
| `$request_id` | Unique request ID (hex) | Request tracing, correlation |
| `$connection` | Connection serial number | Connection tracking |
| `$connection_requests` | Requests on current connection | Keepalive monitoring |
| `$msec` | Current time (epoch + ms) | Precise timing |
| `$pipe` | "p" if pipelined, "." if not | HTTP pipelining detection |
| `$realpath_root` | Resolved root path | Symlink-aware paths |
| `$request_completion` | "OK" if request finished | Incomplete request detection |
| `$limit_req_status` | PASSED/DELAYED/REJECTED/etc. | Rate limiter debugging |
| `$upstream_addr` | Backend server address | Multi-upstream debugging |
| `$upstream_status` | Backend response status | Error tracking |
| `$ssl_client_s_dn` | Client cert subject DN | mTLS identity |

### Embedded Variable Composition

```nginx
# Compose complex cache keys
map "$request_method:$host:$request_uri:$http_accept_encoding" $cache_key {
    default "$request_method:$host:$request_uri:$http_accept_encoding";
}

# Conditional variable setting with map chains
map $http_x_forwarded_proto $real_scheme {
    default $scheme;
    https   https;
}

map $http_x_forwarded_port $real_port {
    default $server_port;
    "~.+"   $http_x_forwarded_port;
}
```

### Internal Locations

```nginx
# Named locations for error handling
error_page 502 503 504 @fallback;

location @fallback {
    proxy_pass http://fallback_backend;
}

# Internal locations for subrequests
location /internal/resize {
    internal;  # can't be accessed directly
    image_filter resize 150 150;
    proxy_pass http://image_store;
}
```
