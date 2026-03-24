# Nginx Security Hardening Guide

Production security configurations for Nginx covering SSL/TLS, attack mitigation,
header hardening, and intrusion prevention.

## Table of Contents

- [SSL/TLS Best Practices](#ssltls-best-practices)
  - [Modern Cipher Suites](#modern-cipher-suites)
  - [HSTS and Preloading](#hsts-and-preloading)
  - [Certificate Pinning](#certificate-pinning)
  - [OCSP Stapling](#ocsp-stapling)
  - [Diffie-Hellman Parameters](#diffie-hellman-parameters)
- [WAF-Like Protections](#waf-like-protections)
  - [Request Filtering](#request-filtering)
  - [ModSecurity Integration](#modsecurity-integration)
  - [Bot Mitigation](#bot-mitigation)
- [DDoS Mitigation](#ddos-mitigation)
  - [Rate Limiting](#rate-limiting)
  - [Connection Limits](#connection-limits)
  - [Geo Blocking](#geo-blocking)
  - [Slowloris Protection](#slowloris-protection)
- [Hiding Server Information](#hiding-server-information)
- [Content-Security-Policy](#content-security-policy)
- [CORS Configuration](#cors-configuration)
- [Fail2Ban Integration](#fail2ban-integration)
- [Complete Hardened Configuration](#complete-hardened-configuration)

---

## SSL/TLS Best Practices

### Modern Cipher Suites

```nginx
# Modern configuration (TLS 1.3 + TLS 1.2 with strong ciphers only)
# Compatible with: Firefox 63+, Chrome 70+, Safari 12.1+, Edge 79+
ssl_protocols TLSv1.2 TLSv1.3;

# TLS 1.3 ciphers (configured at OpenSSL level, not in Nginx)
# TLS 1.2 ciphers — ECDHE only for forward secrecy
ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305';

# Let the client choose the cipher (modern best practice)
ssl_prefer_server_ciphers off;

# ECDH curve for key exchange
ssl_ecdh_curves X25519:secp384r1:secp256r1;
```

**Strict TLS 1.3-only configuration** (highest security, lower compatibility):
```nginx
ssl_protocols TLSv1.3;
# TLS 1.3 ciphers are fixed by the protocol — no ssl_ciphers directive needed
```

### HSTS and Preloading

```nginx
# Enable HSTS — force HTTPS for all future visits
# max-age: 2 years (63072000 seconds)
# includeSubDomains: applies to all subdomains
# preload: allows submission to browser preload list
add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
```

**HSTS preload checklist**:
1. Serve a valid SSL certificate
2. Redirect HTTP to HTTPS on the same host
3. All subdomains must support HTTPS
4. HSTS header on base domain with `includeSubDomains` and `preload`
5. Submit at https://hstspreload.org/

**Warning**: Once preloaded, removing HTTPS is extremely difficult. Ensure ALL
subdomains (including internal ones) support HTTPS before enabling.

### Certificate Pinning

> **Note**: HTTP Public Key Pinning (HPKP) is deprecated. Use Certificate Transparency
> (CT) and CAA DNS records instead.

```nginx
# CAA DNS record (set in DNS, not Nginx)
# Only allow Let's Encrypt to issue certificates:
# example.com. IN CAA 0 issue "letsencrypt.org"
# example.com. IN CAA 0 iodef "mailto:security@example.com"

# Expect-CT header (transitional, being phased out)
add_header Expect-CT "max-age=86400, enforce" always;
```

### OCSP Stapling

```nginx
# Staple OCSP responses — faster TLS handshake, better privacy
ssl_stapling on;
ssl_stapling_verify on;

# CA chain for OCSP verification
ssl_trusted_certificate /etc/letsencrypt/live/example.com/chain.pem;

# DNS resolver for OCSP responder
resolver 1.1.1.1 8.8.8.8 valid=300s;
resolver_timeout 5s;
```

Verify OCSP stapling:
```bash
openssl s_client -connect example.com:443 -status -servername example.com 2>/dev/null | grep -A3 "OCSP Response"
```

### Diffie-Hellman Parameters

```bash
# Generate strong DH parameters (do this once, takes several minutes)
openssl dhparam -out /etc/nginx/dhparam.pem 4096
```

```nginx
# Use custom DH parameters for TLS 1.2 DHE key exchange
ssl_dhparam /etc/nginx/dhparam.pem;
```

**Note**: DH params are only used with DHE cipher suites. If using ECDHE-only ciphers
(recommended), this is not strictly necessary but provides defense in depth.

---

## WAF-Like Protections

### Request Filtering

```nginx
# Block common attack patterns in URLs
location / {
    # Block SQL injection attempts
    if ($query_string ~* "union.*select|insert.*into|delete.*from|drop.*table|update.*set") {
        return 403;
    }

    # Block path traversal
    if ($uri ~* "\.\./" ) {
        return 403;
    }

    # Block common exploit scanners
    if ($http_user_agent ~* "nikto|sqlmap|nmap|masscan|zgrab") {
        return 444;    # Close connection without response
    }

    # Block requests with suspicious methods
    if ($request_method !~ ^(GET|HEAD|POST|PUT|PATCH|DELETE|OPTIONS)$) {
        return 405;
    }
}

# Block access to hidden files (dotfiles)
location ~ /\. {
    deny all;
    access_log off;
    log_not_found off;
}

# Block access to sensitive files
location ~* \.(env|git|svn|htaccess|htpasswd|ini|log|bak|sql|swp)$ {
    deny all;
    access_log off;
    log_not_found off;
}

# Limit request body size
client_max_body_size 10m;

# Limit request header size
large_client_header_buffers 4 8k;

# Limit URI length
if ($request_uri ~* "^.{4096,}") {
    return 414;
}
```

### ModSecurity Integration

```nginx
# ModSecurity WAF (requires ngx_http_modsecurity_module)
modsecurity on;
modsecurity_rules_file /etc/nginx/modsec/main.conf;

# /etc/nginx/modsec/main.conf
# Include OWASP Core Rule Set
Include /etc/nginx/modsec/modsecurity.conf
Include /etc/nginx/modsec/crs/crs-setup.conf
Include /etc/nginx/modsec/crs/rules/*.conf
```

Install ModSecurity:
```bash
# Debian/Ubuntu
apt install libmodsecurity3 libnginx-mod-http-modsecurity

# Download OWASP CRS
git clone https://github.com/coreruleset/coreruleset /etc/nginx/modsec/crs
cp /etc/nginx/modsec/crs/crs-setup.conf.example /etc/nginx/modsec/crs/crs-setup.conf
```

### Bot Mitigation

```nginx
# Block known bad bots by User-Agent
map $http_user_agent $bad_bot {
    default          0;
    ~*crawl          0;    # Allow legitimate crawlers
    ~*googlebot      0;
    ~*bingbot        0;
    ~*semrushbot     1;
    ~*ahrefsbot      1;
    ~*mj12bot        1;
    ~*dotbot         1;
    ""               1;    # Block empty user-agent
}

server {
    if ($bad_bot) {
        return 444;
    }
}

# Block by referrer spam
map $http_referer $bad_referer {
    default          0;
    ~*spam\.com      1;
    ~*malware\.site  1;
}
```

---

## DDoS Mitigation

### Rate Limiting

```nginx
http {
    # General request rate limit (10 requests/sec per IP)
    limit_req_zone $binary_remote_addr zone=general:10m rate=10r/s;

    # Login/auth endpoint rate limit (1 request/sec per IP)
    limit_req_zone $binary_remote_addr zone=login:10m rate=1r/s;

    # API rate limit by API key
    limit_req_zone $http_x_api_key zone=api_key:10m rate=100r/s;

    # Per-server rate limit (aggregate)
    limit_req_zone $server_name zone=per_server:10m rate=1000r/s;

    # Return 429 instead of default 503
    limit_req_status 429;

    # Log rate limit events
    limit_req_log_level warn;
}

server {
    # General pages
    location / {
        limit_req zone=general burst=20 nodelay;
        proxy_pass http://backend;
    }

    # Login — strict limiting
    location /login {
        limit_req zone=login burst=5 nodelay;
        proxy_pass http://backend;
    }

    # API with key-based limiting
    location /api/ {
        limit_req zone=api_key burst=200 nodelay;
        proxy_pass http://api_backend;
    }
}
```

### Connection Limits

```nginx
http {
    # Limit concurrent connections per IP
    limit_conn_zone $binary_remote_addr zone=conn_per_ip:10m;

    # Limit concurrent connections per server
    limit_conn_zone $server_name zone=conn_per_server:10m;

    limit_conn_status 429;
    limit_conn_log_level warn;
}

server {
    limit_conn conn_per_ip 20;          # Max 20 concurrent connections per IP
    limit_conn conn_per_server 2000;    # Max 2000 connections to this server

    # Limit download bandwidth per connection
    location /downloads/ {
        limit_conn conn_per_ip 5;       # Max 5 concurrent downloads per IP
        limit_rate 1m;                  # 1 MB/s per connection
        limit_rate_after 10m;           # Full speed for first 10 MB
    }
}
```

### Geo Blocking

```nginx
# Method 1: Using geoip2 module (recommended)
# Requires: ngx_http_geoip2_module and MaxMind GeoLite2 database

geoip2 /usr/share/GeoIP/GeoLite2-Country.mmdb {
    auto_reload 60m;
    $geoip2_data_country_code default=US country iso_code;
}

map $geoip2_data_country_code $allowed_country {
    default yes;
    CN      no;
    RU      no;
    KP      no;
}

server {
    if ($allowed_country = no) {
        return 444;
    }
}

# Method 2: Simple IP-based blocking (no module required)
# Useful for blocking known bad ranges
geo $blocked_ip {
    default        0;
    192.168.1.0/24 0;    # Allowlist internal
    10.0.0.0/8     0;    # Allowlist internal
    # Add known bad ranges:
    203.0.113.0/24 1;
}

server {
    if ($blocked_ip) {
        return 444;
    }
}
```

### Slowloris Protection

Slowloris attacks keep connections open by sending partial requests very slowly.

```nginx
http {
    # Close connections that send headers too slowly
    client_header_timeout 10s;     # Default: 60s

    # Close connections that send body too slowly
    client_body_timeout 10s;       # Default: 60s

    # Close idle keepalive connections
    keepalive_timeout 15s;         # Default: 75s

    # Limit keepalive requests per connection
    keepalive_requests 100;        # Default: 1000

    # Limit the number of connections per IP (most effective)
    limit_conn_zone $binary_remote_addr zone=conn:10m;
    limit_conn conn 20;

    # Reset lingering connections
    reset_timedout_connection on;

    # Send timeout — close connection if client stops reading
    send_timeout 10s;
}
```

---

## Hiding Server Information

```nginx
http {
    # Remove Nginx version from Server header
    server_tokens off;

    # Remove Server header entirely (requires headers-more module)
    # more_clear_headers Server;

    # Or set a custom Server header
    # more_set_headers "Server: MyApp";

    # Remove X-Powered-By headers from upstream
    proxy_hide_header X-Powered-By;
    proxy_hide_header X-AspNet-Version;
    proxy_hide_header X-Runtime;
    proxy_hide_header X-Version;

    # Hide Nginx-specific headers
    proxy_hide_header X-Nginx-Cache;

    # Remove ETag if exposing inode info (Apache)
    proxy_hide_header ETag;
}

# Disable unnecessary HTTP methods
server {
    if ($request_method !~ ^(GET|HEAD|POST|PUT|PATCH|DELETE)$) {
        return 405;
    }
}

# Block access to version control directories
location ~ /\.(git|svn|hg)/ {
    deny all;
    return 404;
}
```

---

## Content-Security-Policy

```nginx
# Strict CSP for a typical web application
add_header Content-Security-Policy "
    default-src 'self';
    script-src 'self' 'nonce-$request_id';
    style-src 'self' 'unsafe-inline';
    img-src 'self' data: https://cdn.example.com;
    font-src 'self' https://fonts.gstatic.com;
    connect-src 'self' https://api.example.com wss://ws.example.com;
    frame-ancestors 'self';
    base-uri 'self';
    form-action 'self';
    upgrade-insecure-requests;
" always;

# CSP for an API (very strict)
location /api/ {
    add_header Content-Security-Policy "default-src 'none'; frame-ancestors 'none'" always;
}

# Report-only mode for testing (does not enforce)
add_header Content-Security-Policy-Report-Only "
    default-src 'self';
    report-uri /csp-report;
" always;
```

### Full Security Headers Snippet

```nginx
# /etc/nginx/snippets/security-headers.conf
# Include this in every server block

# Prevent clickjacking
add_header X-Frame-Options "SAMEORIGIN" always;

# Prevent MIME type sniffing
add_header X-Content-Type-Options "nosniff" always;

# Referrer policy
add_header Referrer-Policy "strict-origin-when-cross-origin" always;

# Permissions policy (disable unnecessary browser features)
add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=(), usb=(), magnetometer=(), gyroscope=(), accelerometer=()" always;

# XSS protection (legacy, CSP is preferred)
add_header X-XSS-Protection "1; mode=block" always;

# HSTS
add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;

# Cross-Origin policies
add_header Cross-Origin-Opener-Policy "same-origin" always;
add_header Cross-Origin-Resource-Policy "same-origin" always;
add_header Cross-Origin-Embedder-Policy "require-corp" always;
```

---

## CORS Configuration

### Simple CORS (Single Origin)

```nginx
location /api/ {
    add_header Access-Control-Allow-Origin "https://app.example.com" always;
    add_header Access-Control-Allow-Methods "GET, POST, PUT, DELETE, OPTIONS" always;
    add_header Access-Control-Allow-Headers "Authorization, Content-Type, X-Requested-With" always;
    add_header Access-Control-Max-Age 86400 always;
    add_header Access-Control-Allow-Credentials "true" always;

    if ($request_method = OPTIONS) {
        return 204;
    }

    proxy_pass http://api_backend;
}
```

### Dynamic CORS (Multiple Allowed Origins)

```nginx
map $http_origin $cors_origin {
    default                 "";
    "https://app.example.com"       $http_origin;
    "https://admin.example.com"     $http_origin;
    "https://mobile.example.com"    $http_origin;
    "~^https://.*\.staging\.example\.com$"  $http_origin;
}

map $http_origin $cors_credentials {
    default                 "";
    "https://app.example.com"       "true";
    "https://admin.example.com"     "true";
    "https://mobile.example.com"    "true";
    "~^https://.*\.staging\.example\.com$"  "true";
}

server {
    location /api/ {
        add_header Access-Control-Allow-Origin $cors_origin always;
        add_header Access-Control-Allow-Methods "GET, POST, PUT, DELETE, OPTIONS" always;
        add_header Access-Control-Allow-Headers "Authorization, Content-Type" always;
        add_header Access-Control-Max-Age 86400 always;
        add_header Access-Control-Allow-Credentials $cors_credentials always;

        if ($request_method = OPTIONS) {
            return 204;
        }

        proxy_pass http://api_backend;
    }
}
```

**CORS pitfalls**:
- `Access-Control-Allow-Origin: *` cannot be used with `Access-Control-Allow-Credentials: true`
- Preflight (OPTIONS) requests must return 2xx status
- `add_header` in a location block replaces ALL parent headers — use `include` snippets

---

## Fail2Ban Integration

### Nginx Filter Definitions

```ini
# /etc/fail2ban/filter.d/nginx-botsearch.conf
[Definition]
failregex = ^<HOST> .* "(GET|POST|HEAD).*HTTP.*" (404|444) .*$
ignoreregex =

# /etc/fail2ban/filter.d/nginx-badbots.conf
[Definition]
failregex = ^<HOST> .* ".*" .* ".*(?:nikto|sqlmap|nmap|masscan|zgrab).*"$
ignoreregex =

# /etc/fail2ban/filter.d/nginx-noscript.conf
[Definition]
failregex = ^<HOST> .* "(GET|POST).*\.(php|asp|aspx|exe|pl|cgi|scgi).*HTTP.*"
ignoreregex =

# /etc/fail2ban/filter.d/nginx-req-limit.conf
[Definition]
failregex = limiting requests.*client: <HOST>
ignoreregex =

# /etc/fail2ban/filter.d/nginx-http-auth.conf
[Definition]
failregex = no user/password was provided for basic authentication.*client: <HOST>
            user .* was not found in.*client: <HOST>
            user .* password mismatch.*client: <HOST>
ignoreregex =
```

### Fail2Ban Jail Configuration

```ini
# /etc/fail2ban/jail.d/nginx.conf

[nginx-http-auth]
enabled  = true
port     = http,https
filter   = nginx-http-auth
logpath  = /var/log/nginx/error.log
maxretry = 3
findtime = 600
bantime  = 3600

[nginx-botsearch]
enabled  = true
port     = http,https
filter   = nginx-botsearch
logpath  = /var/log/nginx/access.log
maxretry = 20
findtime = 60
bantime  = 86400

[nginx-badbots]
enabled  = true
port     = http,https
filter   = nginx-badbots
logpath  = /var/log/nginx/access.log
maxretry = 1
findtime = 60
bantime  = 86400

[nginx-req-limit]
enabled  = true
port     = http,https
filter   = nginx-req-limit
logpath  = /var/log/nginx/error.log
maxretry = 5
findtime = 60
bantime  = 7200

[nginx-noscript]
enabled  = true
port     = http,https
filter   = nginx-noscript
logpath  = /var/log/nginx/access.log
maxretry = 10
findtime = 60
bantime  = 86400
```

### Manage Fail2Ban

```bash
# Restart fail2ban after config changes
systemctl restart fail2ban

# Check jail status
fail2ban-client status nginx-http-auth

# Manually ban/unban
fail2ban-client set nginx-http-auth banip 192.168.1.100
fail2ban-client set nginx-http-auth unbanip 192.168.1.100

# View all banned IPs
fail2ban-client status | grep "Jail list" | sed 's/.*://;s/,/\n/g' | \
    xargs -I{} fail2ban-client status {} | grep "Banned IP"

# Test filter regex
fail2ban-regex /var/log/nginx/error.log /etc/fail2ban/filter.d/nginx-http-auth.conf
```

---

## Complete Hardened Configuration

```nginx
# /etc/nginx/nginx.conf — Security-hardened base configuration

user www-data;
worker_processes auto;
worker_rlimit_nofile 65535;
pid /run/nginx.pid;

events {
    worker_connections 4096;
    multi_accept on;
    use epoll;
}

http {
    # --- Basic Settings ---
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    types_hash_max_size 2048;
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    # --- Hide Server Info ---
    server_tokens off;

    # --- Timeouts (Slowloris protection) ---
    client_header_timeout 10s;
    client_body_timeout 10s;
    keepalive_timeout 15s;
    keepalive_requests 100;
    send_timeout 10s;
    reset_timedout_connection on;

    # --- Request Limits ---
    client_max_body_size 10m;
    client_body_buffer_size 128k;
    large_client_header_buffers 4 8k;

    # --- Rate Limiting ---
    limit_req_zone $binary_remote_addr zone=general:10m rate=10r/s;
    limit_req_zone $binary_remote_addr zone=login:10m rate=1r/s;
    limit_req_status 429;
    limit_req_log_level warn;

    # --- Connection Limiting ---
    limit_conn_zone $binary_remote_addr zone=conn_per_ip:10m;
    limit_conn conn_per_ip 20;
    limit_conn_status 429;

    # --- SSL Defaults ---
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305';
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    ssl_stapling on;
    ssl_stapling_verify on;
    # ssl_dhparam /etc/nginx/dhparam.pem;

    # --- Logging ---
    log_format json escape=json '{'
        '"time":"$time_iso8601",'
        '"remote_addr":"$remote_addr",'
        '"request_method":"$request_method",'
        '"request_uri":"$request_uri",'
        '"status":$status,'
        '"body_bytes_sent":$body_bytes_sent,'
        '"request_time":$request_time,'
        '"http_user_agent":"$http_user_agent"'
        '}';

    access_log /var/log/nginx/access.log json;
    error_log /var/log/nginx/error.log warn;

    # --- Gzip ---
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 5;
    gzip_min_length 256;
    gzip_types text/plain text/css application/json application/javascript
        text/xml application/xml application/xml+rss text/javascript;

    # --- Default Server (catch-all, reject unknown hosts) ---
    server {
        listen 80 default_server;
        listen [::]:80 default_server;
        listen 443 ssl default_server;
        listen [::]:443 ssl default_server;
        server_name _;

        ssl_certificate /etc/nginx/ssl/default.crt;
        ssl_certificate_key /etc/nginx/ssl/default.key;

        return 444;
    }

    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
```

### Security Verification Checklist

```bash
# Test SSL grade (should be A+)
# https://www.ssllabs.com/ssltest/

# Test security headers
# https://securityheaders.com/

# Verify from command line
curl -sI https://example.com | grep -iE "server|x-frame|x-content|strict|referrer|content-security|permissions"

# Check TLS version
echo | openssl s_client -connect example.com:443 2>/dev/null | grep "Protocol"

# Verify HSTS
curl -sI https://example.com | grep -i strict

# Verify OCSP stapling
echo | openssl s_client -connect example.com:443 -status 2>/dev/null | grep "OCSP Response Status"

# Test rate limiting
for i in $(seq 1 50); do curl -s -o /dev/null -w "%{http_code}\n" https://example.com/; done

# Verify hidden server tokens
curl -sI https://example.com | grep -i server
# Should show "nginx" (no version) or nothing
```
