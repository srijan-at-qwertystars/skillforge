# Nginx Advanced Patterns

## Table of Contents

- [Dynamic Upstream with Lua/njs](#dynamic-upstream-with-luanjs)
- [Content-Based Routing](#content-based-routing)
- [A/B Testing with split_clients](#ab-testing-with-split_clients)
- [Canary Deployments](#canary-deployments)
- [auth_request Subrequests](#auth_request-subrequests)
- [Mirror Module](#mirror-module)
- [Geo Module](#geo-module)
- [Map with Regex](#map-with-regex)
- [sub_filter Module](#sub_filter-module)
- [Request/Response Manipulation with njs](#requestresponse-manipulation-with-njs)

---

## Dynamic Upstream with Lua/njs

### Using njs for Dynamic Upstream Selection

njs (Nginx JavaScript) allows runtime upstream selection without reloading config.

```nginx
# /etc/nginx/njs/upstream_selector.js
function selectUpstream(r) {
    let tenant = r.headersIn['X-Tenant-ID'] || 'default';
    let upstreams = {
        'acme':    '10.0.1.10:8080',
        'globex':  '10.0.2.10:8080',
        'default': '10.0.0.10:8080'
    };
    return upstreams[tenant] || upstreams['default'];
}

export default { selectUpstream };
```

```nginx
load_module modules/ngx_http_js_module.so;

http {
    js_path /etc/nginx/njs/;
    js_import main from upstream_selector.js;

    upstream dynamic_backend {
        server 0.0.0.1:1;  # placeholder, overridden by njs
    }

    server {
        listen 80;

        location /api/ {
            js_set $dynamic_upstream main.selectUpstream;
            proxy_pass http://$dynamic_upstream;
            proxy_set_header Host $host;
        }
    }
}
```

### Using Lua (OpenResty) for Dynamic Upstreams

```nginx
# Requires OpenResty or lua-nginx-module
http {
    lua_shared_dict upstream_cache 10m;

    upstream app_backend {
        server 0.0.0.1:1;  # placeholder
        balancer_by_lua_block {
            local balancer = require "ngx.balancer"
            local host = ngx.var.target_host or "127.0.0.1"
            local port = tonumber(ngx.var.target_port) or 8080
            local ok, err = balancer.set_current_peer(host, port)
            if not ok then
                ngx.log(ngx.ERR, "failed to set peer: ", err)
                return ngx.exit(502)
            end
        }
    }

    server {
        listen 80;

        location /api/ {
            set $target_host '';
            set $target_port '';

            access_by_lua_block {
                -- Look up target from Redis, database, consul, etc.
                local key = ngx.var.http_x_tenant_id or "default"
                local routes = {
                    acme   = { host = "10.0.1.10", port = 8080 },
                    globex = { host = "10.0.2.10", port = 8080 },
                }
                local target = routes[key] or { host = "10.0.0.10", port = 8080 }
                ngx.var.target_host = target.host
                ngx.var.target_port = target.port
            }

            proxy_pass http://app_backend;
        }
    }
}
```

### Service Discovery Integration (Consul)

```nginx
# njs script for Consul-based discovery
function resolveService(r) {
    // In practice, cache results in shared dict
    let svc = r.subrequest('/consul/v1/health/service/myapp?passing=true');
    // Parse and return healthy backend
    return svc[0].Service.Address + ':' + svc[0].Service.Port;
}
```

---

## Content-Based Routing

### Route by Header

```nginx
map $http_x_api_version $api_backend {
    "v1"    backend_v1;
    "v2"    backend_v2;
    default backend_v1;
}

upstream backend_v1 { server 10.0.1.10:8080; }
upstream backend_v2 { server 10.0.2.10:8080; }

server {
    listen 80;
    location /api/ {
        proxy_pass http://$api_backend;
    }
}
```

### Route by Content-Type

```nginx
map $content_type $upload_backend {
    ~*image/     image_processor;
    ~*video/     video_processor;
    ~*application/json  api_handler;
    default      api_handler;
}

server {
    location /upload {
        proxy_pass http://$upload_backend;
    }
}
```

### Route by Cookie

```nginx
map $cookie_app_version $app_upstream {
    "beta"   beta_backend;
    default  stable_backend;
}

upstream stable_backend { server 10.0.1.10:8080; }
upstream beta_backend   { server 10.0.2.10:8080; }

server {
    location / {
        proxy_pass http://$app_upstream;
    }
}
```

### Route by Request Body (njs)

```nginx
# /etc/nginx/njs/body_router.js
function routeByBody(r) {
    try {
        let body = JSON.parse(r.requestText);
        if (body.priority === 'high') {
            return 'priority_backend';
        }
        return 'default_backend';
    } catch (e) {
        return 'default_backend';
    }
}

export default { routeByBody };
```

```nginx
js_import router from body_router.js;

server {
    location /api/tasks {
        js_set $task_backend router.routeByBody;
        proxy_pass http://$task_backend;

        # Must buffer body for njs to read it
        client_body_buffer_size 16k;
        client_max_body_size 1m;
    }
}
```

---

## A/B Testing with split_clients

### Basic A/B Split

`split_clients` hashes a variable and assigns users to buckets deterministically.

```nginx
# 80/20 split based on client IP
split_clients $remote_addr $variant {
    80%    "A";
    *      "B";
}

upstream variant_a { server 10.0.1.10:8080; }
upstream variant_b { server 10.0.2.10:8080; }

map $variant $ab_backend {
    "A"  variant_a;
    "B"  variant_b;
}

server {
    listen 80;
    location / {
        proxy_pass http://$ab_backend;
        add_header X-Variant $variant;
    }
}
```

### Multi-Variant Testing

```nginx
split_clients "${remote_addr}${http_user_agent}" $experiment {
    33.3%  "control";
    33.3%  "variant_1";
    *      "variant_2";
}

map $experiment $exp_upstream {
    "control"    control_backend;
    "variant_1"  variant1_backend;
    "variant_2"  variant2_backend;
}

server {
    location / {
        proxy_pass http://$exp_upstream;
        # Pass variant info to backend for analytics
        proxy_set_header X-Experiment $experiment;
        # Set cookie so user stays in same bucket
        add_header Set-Cookie "experiment=$experiment; Path=/; Max-Age=86400" always;
    }
}
```

### Cookie-Sticky A/B Testing

```nginx
# Use existing cookie if present, otherwise assign
map $cookie_ab_test $ab_assigned {
    "A"     "A";
    "B"     "B";
    default "";
}

split_clients $remote_addr $ab_new {
    50%  "A";
    *    "B";
}

map $ab_assigned $ab_final {
    ""      $ab_new;
    default $ab_assigned;
}

server {
    location / {
        if ($ab_assigned = "") {
            add_header Set-Cookie "ab_test=$ab_new; Path=/; Max-Age=2592000";
        }
        proxy_set_header X-AB-Test $ab_final;
        proxy_pass http://$ab_final_backend;
    }
}
```

---

## Canary Deployments

### Weight-Based Canary

```nginx
upstream production {
    server 10.0.1.10:8080 weight=9;
    server 10.0.1.11:8080 weight=9;
}

upstream canary {
    server 10.0.2.10:8080;
}

split_clients $request_id $canary_pool {
    5%   canary;
    *    production;
}

server {
    listen 80;
    location / {
        proxy_pass http://$canary_pool;
        proxy_set_header X-Canary $canary_pool;
    }
}
```

### Header-Based Canary Override

```nginx
map $http_x_canary $use_canary {
    "true"  canary;
    default "";
}

map $use_canary $final_upstream {
    ""       $canary_pool;    # from split_clients
    default  $use_canary;     # header override
}

server {
    location / {
        proxy_pass http://$final_upstream;
    }
}
```

### Gradual Rollout with Monitoring

```nginx
# Increase canary percentage over time:
# Day 1: 1%, Day 2: 5%, Day 3: 25%, Day 4: 50%, Day 5: 100%
split_clients $request_id $canary_pool {
    5%   canary;      # adjust this percentage during rollout
    *    production;
}

server {
    location / {
        proxy_pass http://$canary_pool;
        # Log canary status for monitoring
        access_log /var/log/nginx/canary.log combined if=$is_canary;
    }
}

map $canary_pool $is_canary {
    canary  1;
    default 0;
}
```

---

## auth_request Subrequests

### Basic Token Validation

```nginx
server {
    location /api/ {
        auth_request /auth/validate;

        # Capture response headers from auth service
        auth_request_set $auth_user    $upstream_http_x_auth_user;
        auth_request_set $auth_roles   $upstream_http_x_auth_roles;
        auth_request_set $auth_tenant  $upstream_http_x_auth_tenant;

        # Forward identity to backend
        proxy_set_header X-User   $auth_user;
        proxy_set_header X-Roles  $auth_roles;
        proxy_set_header X-Tenant $auth_tenant;

        proxy_pass http://backend;
    }

    location = /auth/validate {
        internal;
        proxy_pass http://auth-service:8080/validate;
        proxy_pass_request_body off;
        proxy_set_header Content-Length "";
        proxy_set_header X-Original-URI $request_uri;
        proxy_set_header X-Original-Method $request_method;
        proxy_set_header Authorization $http_authorization;

        # Cache auth responses briefly
        proxy_cache auth_cache;
        proxy_cache_valid 200 5m;
        proxy_cache_valid 401 403 1m;
        proxy_cache_key "$http_authorization";
    }

    # Public endpoints bypass auth
    location /api/health {
        auth_request off;
        proxy_pass http://backend;
    }
}
```

### JWT Validation with njs (No External Service)

```nginx
# /etc/nginx/njs/jwt_validate.js
function validateJWT(r) {
    let auth = r.headersIn['Authorization'];
    if (!auth || !auth.startsWith('Bearer ')) {
        r.return(401, JSON.stringify({ error: 'Missing token' }));
        return;
    }
    let token = auth.slice(7);
    let parts = token.split('.');
    if (parts.length !== 3) {
        r.return(401, JSON.stringify({ error: 'Malformed token' }));
        return;
    }
    try {
        let payload = JSON.parse(Buffer.from(parts[1], 'base64url').toString());
        let now = Math.floor(Date.now() / 1000);
        if (payload.exp && payload.exp < now) {
            r.return(401, JSON.stringify({ error: 'Token expired' }));
            return;
        }
        r.headersOut['X-Auth-User'] = payload.sub || '';
        r.headersOut['X-Auth-Roles'] = (payload.roles || []).join(',');
        r.return(200);
    } catch (e) {
        r.return(401, JSON.stringify({ error: 'Invalid token' }));
    }
}

export default { validateJWT };
```

### Multi-Level Authorization

```nginx
# Different auth for different paths
location /api/admin/ {
    auth_request /auth/admin;
    proxy_pass http://backend;
}

location /api/user/ {
    auth_request /auth/user;
    proxy_pass http://backend;
}

location = /auth/admin {
    internal;
    proxy_pass http://auth-service:8080/validate?role=admin;
    proxy_pass_request_body off;
    proxy_set_header Content-Length "";
    proxy_set_header X-Original-URI $request_uri;
}

location = /auth/user {
    internal;
    proxy_pass http://auth-service:8080/validate?role=user;
    proxy_pass_request_body off;
    proxy_set_header Content-Length "";
    proxy_set_header X-Original-URI $request_uri;
}
```

---

## Mirror Module

Traffic mirroring (shadowing) sends copies of requests to another backend without affecting the primary response.

### Basic Mirroring

```nginx
server {
    listen 80;

    location /api/ {
        mirror /mirror;
        mirror_request_body on;

        proxy_pass http://production_backend;
    }

    location = /mirror {
        internal;
        proxy_pass http://staging_backend$request_uri;
        proxy_set_header Host $host;
        proxy_set_header X-Original-URI $request_uri;
        proxy_set_header X-Mirrored "true";

        # Don't wait for mirror response
        proxy_connect_timeout 1s;
        proxy_read_timeout 1s;
    }
}
```

### Conditional Mirroring

```nginx
# Only mirror a percentage of traffic
split_clients $request_id $do_mirror {
    10%  1;
    *    0;
}

server {
    location /api/ {
        if ($do_mirror) {
            mirror /mirror;
        }
        mirror_request_body on;
        proxy_pass http://production_backend;
    }

    location = /mirror {
        internal;
        proxy_pass http://test_backend$request_uri;
    }
}
```

### Multi-Target Mirroring

```nginx
server {
    location /api/ {
        mirror /mirror_staging;
        mirror /mirror_analytics;
        mirror_request_body on;

        proxy_pass http://production;
    }

    location = /mirror_staging {
        internal;
        proxy_pass http://staging$request_uri;
    }

    location = /mirror_analytics {
        internal;
        proxy_pass http://analytics_collector$request_uri;
    }
}
```

---

## Geo Module

The `geo` module sets variables based on client IP address. Useful for region-based routing, access control, and rate-limit whitelisting.

### Basic Geo Routing

```nginx
geo $country {
    default        unknown;
    10.0.0.0/8     internal;
    192.168.0.0/16 internal;
    203.0.113.0/24 US;
    198.51.100.0/24 EU;
}

map $country $geo_backend {
    US       us_backend;
    EU       eu_backend;
    internal local_backend;
    default  us_backend;
}

upstream us_backend    { server us-east.example.com:8080; }
upstream eu_backend    { server eu-west.example.com:8080; }
upstream local_backend { server 127.0.0.1:8080; }

server {
    location / {
        proxy_pass http://$geo_backend;
        proxy_set_header X-Geo-Region $country;
    }
}
```

### Rate Limit Whitelisting with Geo

```nginx
geo $is_whitelisted {
    default 0;
    10.0.0.0/8     1;   # internal network
    192.168.0.0/16 1;   # VPN
    203.0.113.50   1;   # monitoring
}

map $is_whitelisted $limit_key {
    1  "";                    # empty key = no rate limiting
    0  $binary_remote_addr;   # rate limit by IP
}

limit_req_zone $limit_key zone=api:10m rate=10r/s;
```

### Geo-Based Access Restriction

```nginx
geo $allowed_country {
    default        no;
    # Allow only specific CIDR ranges
    203.0.113.0/24  yes;  # US
    198.51.100.0/24 yes;  # EU
    10.0.0.0/8      yes;  # Internal
}

server {
    location / {
        if ($allowed_country = no) {
            return 403 '{"error": "Access denied from your region"}';
        }
        proxy_pass http://backend;
    }
}
```

### Geo with proxy_protocol (Real Client IP Behind LB)

```nginx
geo $remote_addr $is_trusted {
    default 0;
    10.0.0.0/8 1;
}

# When behind a load balancer using proxy_protocol
geo $proxy_protocol_addr $geo_region {
    default unknown;
    # CIDR blocks per region
}
```

---

## Map with Regex

### Complex URL Rewriting

```nginx
map $request_uri $new_uri {
    # Exact matches
    /old-about       /about;
    /old-contact     /contact;

    # Regex matches (case-insensitive)
    ~*^/blog/(\d{4})/(\d{2})/(.+)$    /posts/$1-$2-$3;
    ~*^/category/(.+)$                 /topics/$1;
    ~*^/user/(\d+)/profile$            /profiles/$1;

    # Catch-all
    default "";
}

server {
    if ($new_uri != "") {
        return 301 $new_uri;
    }
}
```

### Dynamic Backend Selection

```nginx
map $request_uri $service_backend {
    ~^/api/users       user_service;
    ~^/api/orders      order_service;
    ~^/api/products    product_service;
    ~^/api/payments    payment_service;
    default            default_service;
}
```

### User-Agent Based Behavior

```nginx
map $http_user_agent $is_bot {
    default 0;
    ~*(googlebot|bingbot|yandex|baiduspider)  1;
    ~*(curl|wget|python-requests|scrapy)      2;  # suspicious
}

map $is_bot $bot_action {
    0  "";
    1  "search_engine";
    2  "suspicious";
}

server {
    location / {
        if ($is_bot = 2) {
            return 429 "Rate limited";
        }

        # Serve pre-rendered pages to search engine bots
        if ($is_bot = 1) {
            rewrite ^(.*)$ /prerender$1 break;
        }

        proxy_pass http://backend;
    }
}
```

### Extracting Values from Complex Headers

```nginx
# Extract Bearer token from Authorization header
map $http_authorization $bearer_token {
    ~^Bearer\s+(.+)$  $1;
    default            "";
}

# Extract version from Accept header
# Accept: application/vnd.api+json; version=2
map $http_accept $api_version {
    ~version=(\d+)  $1;
    default         "1";
}

# Map multiple conditions with combined variable
map "$request_method:$uri" $cors_origin {
    ~^OPTIONS:/api/  "*";
    ~^(GET|POST):/api/public/  "*";
    default  "";
}
```

---

## sub_filter Module

`sub_filter` replaces text strings in the response body. Useful for modifying upstream responses without changing application code.

### Basic String Replacement

```nginx
location / {
    proxy_pass http://backend;

    # Replace internal URLs with external ones
    sub_filter 'http://internal-api.local' 'https://api.example.com';
    sub_filter 'http://localhost:3000' 'https://app.example.com';

    # Replace multiple occurrences (default replaces only the first)
    sub_filter_once off;

    # Ensure upstream doesn't gzip (sub_filter needs plain text)
    proxy_set_header Accept-Encoding "";

    # Apply to specific MIME types
    sub_filter_types text/html text/css application/javascript application/json;
}
```

### Injecting Scripts or Analytics

```nginx
location / {
    proxy_pass http://backend;
    sub_filter '</head>' '<script src="/analytics.js"></script></head>';
    sub_filter '</body>' '<div id="debug-bar">Server: $hostname</div></body>';
    sub_filter_once on;
    sub_filter_types text/html;
    proxy_set_header Accept-Encoding "";
}
```

### Environment-Specific Configuration

```nginx
# Inject environment banner on staging
map $hostname $env_banner {
    ~*staging  '<div style="background:orange;text-align:center;padding:5px">STAGING</div>';
    ~*dev      '<div style="background:red;text-align:center;padding:5px;color:white">DEV</div>';
    default    '';
}

server {
    location / {
        proxy_pass http://backend;
        sub_filter '<body>' '<body>$env_banner';
        sub_filter_once on;
        proxy_set_header Accept-Encoding "";
    }
}
```

### URL Rewriting in Proxied Content

```nginx
# Useful when proxying an app that generates absolute URLs
location /app/ {
    proxy_pass http://internal-app:8080/;

    sub_filter 'href="/'           'href="/app/';
    sub_filter 'src="/'            'src="/app/';
    sub_filter 'action="/'         'action="/app/';
    sub_filter 'url(/'             'url(/app/';
    sub_filter_once off;
    sub_filter_types text/html text/css application/javascript;
    proxy_set_header Accept-Encoding "";
}
```

---

## Request/Response Manipulation with njs

### Request Transformation

```nginx
# /etc/nginx/njs/transform.js

// Add computed headers to requests
function addRequestHeaders(r) {
    let timestamp = Date.now().toString();
    let requestId = Math.random().toString(36).substring(2, 15);
    r.headersOut['X-Request-ID'] = requestId;
    r.headersOut['X-Timestamp'] = timestamp;
    r.return(200);
}

// Transform request body (e.g., XML to JSON adapter)
function transformRequestBody(r) {
    let body = r.requestText;
    try {
        // Add metadata wrapper around original payload
        let original = JSON.parse(body);
        let enriched = {
            metadata: {
                timestamp: new Date().toISOString(),
                source: r.headersIn['X-Source'] || 'unknown',
                requestId: r.headersIn['X-Request-ID'] || ''
            },
            payload: original
        };
        r.headersOut['Content-Type'] = 'application/json';
        r.return(200, JSON.stringify(enriched));
    } catch (e) {
        r.return(400, JSON.stringify({ error: 'Invalid JSON' }));
    }
}

export default { addRequestHeaders, transformRequestBody };
```

### Response Transformation

```nginx
# /etc/nginx/njs/response_filter.js

// Filter sensitive fields from JSON responses
function filterResponse(r, data, flags) {
    if (r.status !== 200) {
        r.sendBuffer(data, flags);
        return;
    }

    let contentType = r.headersOut['Content-Type'] || '';
    if (!contentType.includes('application/json')) {
        r.sendBuffer(data, flags);
        return;
    }

    // Accumulate body chunks
    if (!r.privateData) {
        r.privateData = '';
    }
    r.privateData += data;

    if (flags.last) {
        try {
            let json = JSON.parse(r.privateData);
            // Remove sensitive fields
            let sensitiveFields = ['password', 'ssn', 'credit_card', 'secret'];
            function redact(obj) {
                for (let key in obj) {
                    if (sensitiveFields.includes(key.toLowerCase())) {
                        obj[key] = '[REDACTED]';
                    } else if (typeof obj[key] === 'object' && obj[key] !== null) {
                        redact(obj[key]);
                    }
                }
                return obj;
            }
            let filtered = redact(json);
            r.sendBuffer(JSON.stringify(filtered), flags);
        } catch (e) {
            r.sendBuffer(r.privateData, flags);
        }
    }
}

export default { filterResponse };
```

```nginx
js_import filter from response_filter.js;

server {
    location /api/ {
        proxy_pass http://backend;
        js_body_filter filter.filterResponse;
    }
}
```

### Request Rate Analytics with njs

```nginx
# /etc/nginx/njs/analytics.js
function logMetrics(r) {
    // Structured logging for analytics pipeline
    let entry = {
        timestamp: new Date().toISOString(),
        method: r.method,
        uri: r.uri,
        status: r.status,
        request_time: r.variables.request_time,
        upstream_time: r.variables.upstream_response_time,
        bytes_sent: r.variables.bytes_sent,
        client: r.remoteAddress,
        user_agent: r.headersIn['User-Agent'],
        referer: r.headersIn['Referer'] || '-'
    };
    r.log(JSON.stringify(entry));
}

export default { logMetrics };
```

```nginx
js_import analytics from analytics.js;

server {
    location /api/ {
        proxy_pass http://backend;
        js_header_filter analytics.logMetrics;
    }
}
```

### API Gateway Pattern with njs

```nginx
# /etc/nginx/njs/gateway.js

// Rate limiting with shared dict (Nginx Plus or OpenResty)
// For OSS, use limit_req_zone instead

// API key validation
function validateApiKey(r) {
    let apiKey = r.headersIn['X-API-Key'] || r.args.api_key;
    if (!apiKey) {
        r.return(401, JSON.stringify({
            error: 'API key required',
            docs: 'https://docs.example.com/auth'
        }));
        return;
    }

    // In production, validate against a database or cache
    let validKeys = {
        'key-abc-123': { name: 'ServiceA', rateLimit: 100 },
        'key-def-456': { name: 'ServiceB', rateLimit: 1000 },
    };

    let keyInfo = validKeys[apiKey];
    if (!keyInfo) {
        r.return(403, JSON.stringify({ error: 'Invalid API key' }));
        return;
    }

    r.headersOut['X-Client-Name'] = keyInfo.name;
    r.headersOut['X-Rate-Limit'] = keyInfo.rateLimit.toString();
    r.return(200);
}

// Request ID generation
function generateRequestId(r) {
    let id = `${Date.now()}-${Math.random().toString(36).substr(2, 9)}`;
    return id;
}

export default { validateApiKey, generateRequestId };
```

```nginx
js_import gw from gateway.js;

server {
    listen 80;

    # Generate request ID for tracing
    js_set $request_id_custom gw.generateRequestId;

    location /api/ {
        # Validate API key via subrequest
        auth_request /auth/apikey;
        auth_request_set $client_name $upstream_http_x_client_name;

        proxy_pass http://backend;
        proxy_set_header X-Request-ID $request_id_custom;
        proxy_set_header X-Client-Name $client_name;
    }

    location = /auth/apikey {
        internal;
        js_content gw.validateApiKey;
    }
}
```
