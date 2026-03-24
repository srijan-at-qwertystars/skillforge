# Nginx Security Hardening Reference

## Table of Contents

- [ModSecurity WAF Integration](#modsecurity-waf-integration)
- [DDoS Mitigation](#ddos-mitigation)
- [Bot Detection and Blocking](#bot-detection-and-blocking)
- [Client Certificate Authentication (mTLS)](#client-certificate-authentication-mtls)
- [OCSP Stapling](#ocsp-stapling)
- [Security Headers (CSP, HSTS, X-Frame)](#security-headers-csp-hsts-x-frame)
- [fail2ban Integration](#fail2ban-integration)
- [Request Body Inspection](#request-body-inspection)
- [IP Allowlisting and Denylisting](#ip-allowlisting-and-denylisting)
- [Advanced Access Control Patterns](#advanced-access-control-patterns)
- [SSL/TLS Hardening Checklist](#ssltls-hardening-checklist)

---

## ModSecurity WAF Integration

ModSecurity v3 runs as a dynamic nginx module. It inspects requests/responses against rules (OWASP Core Rule Set).

### Installation

```bash
# Debian/Ubuntu
apt install libmodsecurity3 libnginx-mod-http-modsecurity

# Or compile the nginx connector module
git clone https://github.com/owasp-modsecurity/ModSecurity-nginx
# Add --add-dynamic-module=../ModSecurity-nginx to nginx compile
```

### Configuration

```nginx
# nginx.conf
load_module modules/ngx_http_modsecurity_module.so;

http {
    modsecurity on;
    modsecurity_rules_file /etc/nginx/modsec/main.conf;
}
```

```
# /etc/nginx/modsec/main.conf
Include /etc/nginx/modsec/modsecurity.conf
Include /etc/nginx/modsec/crs/crs-setup.conf
Include /etc/nginx/modsec/crs/rules/*.conf

# Custom rules
SecRule REQUEST_URI "@contains /admin" \
    "id:1001,phase:1,deny,status:403,msg:'Admin access blocked'"

SecRule REQUEST_HEADERS:Content-Type "text/xml" \
    "id:1002,phase:1,deny,status:403,msg:'XML content type blocked'"
```

### Detection-Only Mode (Recommended for Initial Deployment)

```
# modsecurity.conf
SecRuleEngine DetectionOnly    # log but don't block
SecAuditEngine On
SecAuditLogParts ABCDEFHZ
SecAuditLog /var/log/nginx/modsec_audit.log
```

Switch to `SecRuleEngine On` after tuning false positives.

### Tuning False Positives

```
# Disable specific rules for a path
SecRule REQUEST_URI "@beginsWith /api/upload" \
    "id:1100,phase:1,nolog,pass,ctl:ruleRemoveById=920420"

# Whitelist specific parameter from SQL injection checks
SecRule ARGS:search_query "@rx .*" \
    "id:1101,phase:2,nolog,pass,ctl:ruleRemoveTargetById=942100;ARGS:search_query"

# Raise anomaly threshold for API endpoints
SecAction "id:1102,phase:1,nolog,pass,\
    ctl:ruleRemoveById=920170,\
    ctl:ruleRemoveById=920171"
```

### Per-Location WAF Control

```nginx
# Disable WAF for specific paths
location /api/webhooks {
    modsecurity off;
    proxy_pass http://backend;
}

# Custom rules per location
location /admin/ {
    modsecurity_rules '
        SecRule REMOTE_ADDR "!@ipMatch 10.0.0.0/8" \
            "id:2001,phase:1,deny,status:403"
    ';
    proxy_pass http://admin_backend;
}
```

---

## DDoS Mitigation

### Layer 7 Rate Limiting

```nginx
http {
    # Multiple rate limit zones for different patterns
    limit_req_zone $binary_remote_addr zone=general:20m rate=50r/s;
    limit_req_zone $binary_remote_addr zone=login:10m rate=3r/m;
    limit_req_zone $binary_remote_addr zone=api:20m rate=100r/s;
    limit_req_zone $server_name zone=per_server:10m rate=1000r/s;

    # Connection limits
    limit_conn_zone $binary_remote_addr zone=per_ip_conn:10m;
    limit_conn_zone $server_name zone=per_server_conn:10m;

    server {
        # Global connection limit
        limit_conn per_ip_conn 50;
        limit_conn per_server_conn 5000;
        limit_conn_status 429;

        # General rate limit
        limit_req zone=general burst=100 nodelay;
        limit_req_status 429;

        location /login {
            limit_req zone=login burst=5;
            proxy_pass http://backend;
        }

        location /api/ {
            limit_req zone=api burst=200 nodelay;
            proxy_pass http://backend;
        }
    }
}
```

### Slowloris Protection

```nginx
# Tight client timeouts
client_header_timeout 10s;     # slow header sends
client_body_timeout 10s;       # slow body sends
send_timeout 10s;              # slow response reads
keepalive_timeout 30s;         # reduce from default 65s under attack
keepalive_requests 100;        # limit requests per keepalive

# Request size limits
client_max_body_size 10m;
client_body_buffer_size 16k;
large_client_header_buffers 2 4k;
```

### SYN Flood Mitigation (OS-Level)

```bash
# /etc/sysctl.conf
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 65535
net.core.somaxconn = 65535
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.core.netdev_max_backlog = 65535
```

```nginx
# nginx supports the backlog parameter
server {
    listen 80 backlog=65535;
    listen 443 ssl http2 backlog=65535;
}
```

### Request Filtering

```nginx
# Block requests without Host header
if ($host = '') {
    return 444;
}

# Block obviously malicious URIs
location ~* (\.\.\/|\.\.\\|%2e%2e|eval\(|base64_) {
    return 444;
}

# Limit request methods
if ($request_method !~ ^(GET|HEAD|POST|PUT|PATCH|DELETE|OPTIONS)$) {
    return 405;
}

# Block empty user agents (many bots)
if ($http_user_agent = '') {
    return 444;
}
```

### Emergency Response: Quick Block

```nginx
# Geo-based emergency blocking
geo $blocked {
    default 0;
    # Add attacking IPs/ranges during incident
    203.0.113.0/24  1;
    198.51.100.50   1;
}

server {
    if ($blocked) {
        return 444;  # close connection without response
    }
}
```

---

## Bot Detection and Blocking

### User-Agent Based Blocking

```nginx
map $http_user_agent $bad_bot {
    default 0;
    "~*crawl|bot|spider"         0;  # allow legitimate bots
    "~*semrush|ahref|mj12"      1;  # block aggressive SEO bots
    "~*scanner|sqlmap|nikto"     1;  # block known attack tools
    "~*python-requests"          1;  # block raw library access
    "~*wget|curl"                1;  # block CLI tools (adjust as needed)
    ""                           1;  # block empty UA
}

server {
    if ($bad_bot) {
        return 403;
    }
}
```

### Honeypot Trap

```nginx
# Add hidden links in your pages that only bots follow
location /definitely-not-a-trap {
    access_log /var/log/nginx/bot-trap.log;
    # Log and block the IP (feed to fail2ban)
    return 444;
}
```

### CAPTCHA Challenge via auth_request

```nginx
map $cookie_bot_verified $needs_challenge {
    "verified"  0;
    default     1;
}

location / {
    if ($needs_challenge) {
        return 302 /challenge?next=$request_uri;
    }
    proxy_pass http://backend;
}

location /challenge {
    # Serve CAPTCHA page; on success, set bot_verified cookie
    proxy_pass http://captcha_service;
}
```

### Referer Validation (Hotlink Prevention)

```nginx
valid_referers none blocked server_names *.example.com;

location ~* \.(jpg|jpeg|png|gif|webp|svg|css|js)$ {
    if ($invalid_referer) {
        return 403;
    }
    expires 30d;
}
```

---

## Client Certificate Authentication (mTLS)

### Generate CA and Client Certificates

```bash
# 1. Create CA
openssl genrsa -out ca.key 4096
openssl req -new -x509 -days 3650 -key ca.key -out ca.crt \
    -subj "/CN=Internal CA/O=MyOrg"

# 2. Generate client key + CSR
openssl genrsa -out client.key 2048
openssl req -new -key client.key -out client.csr \
    -subj "/CN=service-a/O=MyOrg"

# 3. Sign client cert with CA
openssl x509 -req -days 365 -in client.csr \
    -CA ca.crt -CAkey ca.key -CAcreateserial \
    -out client.crt

# 4. Create PKCS12 for browser import (if needed)
openssl pkcs12 -export -out client.p12 \
    -inkey client.key -in client.crt -certfile ca.crt
```

### Nginx mTLS Configuration

```nginx
server {
    listen 443 ssl http2;
    server_name api-internal.example.com;

    ssl_certificate /etc/ssl/server.crt;
    ssl_certificate_key /etc/ssl/server.key;

    # mTLS settings
    ssl_client_certificate /etc/ssl/ca.crt;  # CA that signed client certs
    ssl_verify_client on;                     # require client cert
    ssl_verify_depth 2;

    # CRL (Certificate Revocation List)
    ssl_crl /etc/ssl/ca.crl;

    # Pass client cert info to upstream
    location / {
        proxy_set_header X-Client-CN $ssl_client_s_dn_cn;
        proxy_set_header X-Client-DN $ssl_client_s_dn;
        proxy_set_header X-Client-Serial $ssl_client_serial;
        proxy_set_header X-Client-Verify $ssl_client_verify;
        proxy_pass http://backend;
    }
}
```

### Optional mTLS (Mixed Public/Internal)

```nginx
server {
    ssl_client_certificate /etc/ssl/ca.crt;
    ssl_verify_client optional;  # don't require, but verify if present

    # Public endpoints
    location /public/ {
        proxy_pass http://backend;
    }

    # mTLS-required endpoints
    location /internal/ {
        if ($ssl_client_verify != SUCCESS) {
            return 403 '{"error":"client certificate required"}';
        }
        proxy_set_header X-Client-CN $ssl_client_s_dn_cn;
        proxy_pass http://backend;
    }
}
```

### Restrict by Client Certificate CN

```nginx
map $ssl_client_s_dn_cn $allowed_client {
    "service-a"     1;
    "service-b"     1;
    "admin-tool"    1;
    default         0;
}

location /internal/ {
    if ($ssl_client_verify != SUCCESS) {
        return 403;
    }
    if ($allowed_client = 0) {
        return 403;
    }
    proxy_pass http://backend;
}
```

---

## OCSP Stapling

OCSP stapling includes the certificate's revocation status in the TLS handshake, improving performance and privacy.

### Configuration

```nginx
server {
    ssl_stapling on;
    ssl_stapling_verify on;

    # The intermediate/root CA chain (NOT the server cert)
    ssl_trusted_certificate /etc/letsencrypt/live/example.com/chain.pem;

    # Required for OCSP responder lookup
    resolver 1.1.1.1 8.8.8.8 valid=300s;
    resolver_timeout 5s;
}
```

### Verification

```bash
# Test OCSP stapling
echo | openssl s_client -connect example.com:443 -servername example.com -status 2>/dev/null | grep -A5 "OCSP Response"

# Expected output:
# OCSP Response Status: successful (0x0)
# OCSP Response Data:
#     Response Type: Basic OCSP Response
#     Certificate Status: good

# Manual OCSP query
openssl ocsp -issuer chain.pem -cert server.crt \
    -url $(openssl x509 -in server.crt -noout -ocsp_uri) \
    -header "Host" "$(openssl x509 -in server.crt -noout -ocsp_uri | sed 's|https\?://\([^/]*\).*|\1|')"
```

### Troubleshooting OCSP Failures

```bash
# Check nginx can resolve OCSP responder
dig $(openssl x509 -in /etc/ssl/cert.pem -noout -ocsp_uri | sed 's|https\?://\([^/]*\).*|\1|')

# Check nginx error log
grep -i "ocsp" /var/log/nginx/error.log

# Common issues:
# - Missing resolver directive
# - Firewall blocking outbound to OCSP responder
# - Wrong ssl_trusted_certificate (needs CA chain, not server cert)
# - Cert has no OCSP responder URI embedded
```

---

## Security Headers (CSP, HSTS, X-Frame)

### Comprehensive Security Headers Include

```nginx
# /etc/nginx/snippets/security-headers.conf

# Prevent clickjacking
add_header X-Frame-Options "SAMEORIGIN" always;

# Prevent MIME-type sniffing
add_header X-Content-Type-Options "nosniff" always;

# XSS Protection (legacy, but still useful for old browsers)
add_header X-XSS-Protection "1; mode=block" always;

# Referrer Policy
add_header Referrer-Policy "strict-origin-when-cross-origin" always;

# HSTS — force HTTPS for 2 years, include subdomains, allow preloading
add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;

# Permissions Policy — restrict browser features
add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=(), usb=(), magnetometer=(), gyroscope=(), accelerometer=()" always;

# Content Security Policy — restrict resource loading
# Adjust per application requirements
add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' https://cdn.example.com; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; font-src 'self' https://fonts.googleapis.com https://fonts.gstatic.com; connect-src 'self' https://api.example.com; frame-ancestors 'self'; base-uri 'self'; form-action 'self';" always;

# Cross-Origin policies
add_header Cross-Origin-Embedder-Policy "require-corp" always;
add_header Cross-Origin-Opener-Policy "same-origin" always;
add_header Cross-Origin-Resource-Policy "same-origin" always;
```

### CSP for API-Only Servers

```nginx
# Strict CSP for APIs (no browser rendering)
add_header Content-Security-Policy "default-src 'none'; frame-ancestors 'none'" always;
```

### CSP Report-Only Mode (Testing)

```nginx
add_header Content-Security-Policy-Report-Only "default-src 'self'; report-uri /csp-report;" always;

location /csp-report {
    proxy_pass http://csp_collector;
}
```

### Per-Route Header Overrides

Remember: inner blocks clear all parent `add_header` directives.

```nginx
server {
    include snippets/security-headers.conf;

    # API routes need different CSP
    location /api/ {
        include snippets/security-headers.conf;
        # Override CSP for API
        add_header Content-Security-Policy "default-src 'none'" always;
        proxy_pass http://api_backend;
    }

    # Embeddable widget — allow framing from partners
    location /widget/ {
        include snippets/security-headers.conf;
        # Override X-Frame-Options
        add_header X-Frame-Options "" always;  # clear it
        add_header Content-Security-Policy "frame-ancestors https://partner.com" always;
        proxy_pass http://widget_backend;
    }
}
```

---

## fail2ban Integration

### Nginx Log Monitoring Filter

```ini
# /etc/fail2ban/filter.d/nginx-botsearch.conf
[Definition]
failregex = ^<HOST> .* "(GET|POST|HEAD) .*(wp-login|xmlrpc|phpmyadmin|\.env|\.git).*" (403|404|444)
ignoreregex =

# /etc/fail2ban/filter.d/nginx-badbots.conf
[Definition]
failregex = ^<HOST> .* ".*" 444
            ^<HOST> .* "-" 400
ignoreregex =

# /etc/fail2ban/filter.d/nginx-ratelimit.conf
[Definition]
failregex = limiting requests, excess: .* by zone .*, client: <HOST>
ignoreregex =
datepattern = {^LN-BEG}
```

### Jail Configuration

```ini
# /etc/fail2ban/jail.d/nginx.conf
[nginx-botsearch]
enabled  = true
port     = http,https
filter   = nginx-botsearch
logpath  = /var/log/nginx/access.log
maxretry = 5
findtime = 60
bantime  = 3600
action   = iptables-multiport[name=nginx, port="http,https"]

[nginx-ratelimit]
enabled  = true
port     = http,https
filter   = nginx-ratelimit
logpath  = /var/log/nginx/error.log
maxretry = 10
findtime = 60
bantime  = 600
action   = iptables-multiport[name=nginx-rl, port="http,https"]

[nginx-badbots]
enabled  = true
port     = http,https
filter   = nginx-badbots
logpath  = /var/log/nginx/access.log
maxretry = 3
findtime = 300
bantime  = 86400
action   = iptables-multiport[name=nginx-bots, port="http,https"]
```

### Dynamic Ban List with Nginx

```nginx
# Include a file of banned IPs (managed by fail2ban or script)
geo $banned_ip {
    default 0;
    include /etc/nginx/conf.d/banned-ips.conf;
}

server {
    if ($banned_ip) {
        return 444;
    }
}
```

```bash
# /etc/nginx/conf.d/banned-ips.conf (auto-generated)
# Format: IP 1;
203.0.113.50 1;
198.51.100.0/24 1;
```

### fail2ban Management Commands

```bash
# Check status
fail2ban-client status nginx-botsearch

# Unban an IP
fail2ban-client set nginx-botsearch unbanip 192.168.1.100

# Test filter against log
fail2ban-regex /var/log/nginx/access.log /etc/fail2ban/filter.d/nginx-botsearch.conf
```

---

## Request Body Inspection

### Size and Content Limits

```nginx
# Global limits
client_max_body_size 10m;
client_body_buffer_size 16k;

# Route-specific overrides
location /api/upload {
    client_max_body_size 500m;
    client_body_buffer_size 128k;
    client_body_temp_path /var/lib/nginx/upload_temp 1 2;
    proxy_pass http://upload_backend;
}

# Reject non-JSON to API endpoints
location /api/ {
    if ($content_type !~ "application/json") {
        return 415 '{"error":"Content-Type must be application/json"}';
    }
    proxy_pass http://backend;
}
```

### Blocking Suspicious Request Bodies (with Lua)

```nginx
access_by_lua_block {
    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    if body then
        -- Block SQL injection patterns
        local sql_patterns = {
            "union%s+select", "drop%s+table", "insert%s+into",
            "delete%s+from", "update%s+.*set", "exec%s*%(", "xp_cmdshell"
        }
        local lower_body = body:lower()
        for _, pattern in ipairs(sql_patterns) do
            if lower_body:match(pattern) then
                ngx.log(ngx.WARN, "SQL injection attempt blocked: ", ngx.var.remote_addr)
                return ngx.exit(403)
            end
        end

        -- Block XSS patterns
        if lower_body:match("<script") or lower_body:match("javascript:") then
            ngx.log(ngx.WARN, "XSS attempt blocked: ", ngx.var.remote_addr)
            return ngx.exit(403)
        end
    end
}
```

### File Upload Restrictions

```nginx
location /upload {
    client_max_body_size 50m;

    # Only allow specific content types for uploads
    if ($content_type !~ "multipart/form-data") {
        return 415;
    }

    # Anti-virus scanning via auth_request
    # auth_request /scan;
    proxy_pass http://upload_backend;
}
```

---

## IP Allowlisting and Denylisting

### Basic allow/deny

```nginx
# Admin panel — internal only
location /admin/ {
    allow 10.0.0.0/8;
    allow 172.16.0.0/12;
    allow 192.168.0.0/16;
    deny all;
    proxy_pass http://admin_backend;
}

# Status endpoint — monitoring only
location /nginx_status {
    stub_status;
    allow 10.0.0.0/8;
    allow 127.0.0.1;
    deny all;
}
```

### Geo Module for Complex Rules

```nginx
geo $remote_addr $access_level {
    default         "public";
    10.0.0.0/8      "internal";
    172.16.0.0/12   "internal";
    192.168.0.0/16  "internal";
    203.0.113.0/24  "partner";
    198.51.100.0/24 "blocked";
}

map $access_level $is_internal {
    internal 1;
    default  0;
}

server {
    # Block banned ranges
    if ($access_level = "blocked") {
        return 444;
    }

    location /internal/ {
        if ($is_internal = 0) {
            return 403;
        }
        proxy_pass http://internal_backend;
    }

    location /partner-api/ {
        if ($access_level !~ "^(internal|partner)$") {
            return 403;
        }
        proxy_pass http://partner_backend;
    }
}
```

### Dynamic IP Lists from File

```nginx
# Load large IP lists efficiently
geo $blocked_ip {
    default 0;
    include /etc/nginx/blocklist.conf;
}

# Reload without restart:
# 1. Update blocklist.conf
# 2. nginx -s reload
```

### CloudFlare / CDN Real IP Restoration

```nginx
# Restore real client IP from CDN headers
set_real_ip_from 173.245.48.0/20;
set_real_ip_from 103.21.244.0/22;
set_real_ip_from 103.22.200.0/22;
set_real_ip_from 103.31.4.0/22;
set_real_ip_from 141.101.64.0/18;
set_real_ip_from 108.162.192.0/18;
set_real_ip_from 190.93.240.0/20;
set_real_ip_from 188.114.96.0/20;
set_real_ip_from 197.234.240.0/22;
set_real_ip_from 198.41.128.0/17;
set_real_ip_from 162.158.0.0/15;
set_real_ip_from 104.16.0.0/13;
set_real_ip_from 104.24.0.0/14;
set_real_ip_from 172.64.0.0/13;
set_real_ip_from 131.0.72.0/22;
real_ip_header CF-Connecting-IP;
# Or for generic proxy:
# real_ip_header X-Forwarded-For;
# real_ip_recursive on;
```

---

## Advanced Access Control Patterns

### Time-Based Access

```nginx
# Allow admin access only during business hours (with Lua)
access_by_lua_block {
    local hour = tonumber(os.date("%H"))
    local day = tonumber(os.date("%w"))  -- 0=Sunday

    -- Weekdays 8am-6pm only
    if day == 0 or day == 6 then
        return ngx.exit(403)
    end
    if hour < 8 or hour >= 18 then
        return ngx.exit(403)
    end
}
```

### Combining Multiple Access Controls

```nginx
# Require BOTH valid IP AND valid client cert
location /supersecure/ {
    # IP restriction
    allow 10.0.0.0/8;
    deny all;

    # mTLS
    if ($ssl_client_verify != SUCCESS) {
        return 403;
    }

    # auth_request for token validation
    auth_request /auth;

    proxy_pass http://secure_backend;
}
```

---

## SSL/TLS Hardening Checklist

### Production SSL Configuration

```nginx
# Only modern TLS versions
ssl_protocols TLSv1.2 TLSv1.3;

# Strong cipher suites (TLS 1.2 + 1.3)
ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305';
ssl_prefer_server_ciphers off;  # let client choose for TLS 1.3

# ECDH curve
ssl_ecdh_curve X25519:secp384r1;

# DH parameters
ssl_dhparam /etc/nginx/dhparam.pem;

# Session management
ssl_session_cache shared:SSL:50m;
ssl_session_timeout 1d;
ssl_session_tickets off;  # disable for forward secrecy

# OCSP stapling
ssl_stapling on;
ssl_stapling_verify on;
ssl_trusted_certificate /etc/ssl/chain.pem;
resolver 1.1.1.1 8.8.8.8 valid=300s;

# HSTS
add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;

# 0-RTT (TLS 1.3 early data) — use with caution
ssl_early_data off;  # on = faster but replay attack risk for non-idempotent requests
```

### Quick SSL Test

```bash
# Test with SSL Labs methodology
# Check supported protocols
for proto in tls1 tls1_1 tls1_2 tls1_3; do
    echo -n "$proto: "
    echo | openssl s_client -connect example.com:443 -$proto 2>/dev/null | grep "Protocol"
done

# Check cipher suites
nmap --script ssl-enum-ciphers -p 443 example.com

# Full test
curl -sS https://api.ssllabs.com/api/v3/analyze?host=example.com | jq '.endpoints[0].grade'
```

### Certificate Transparency

```nginx
# Enable CT with TLS extension (requires nginx-ct module)
ssl_ct on;
ssl_ct_static_scts /etc/nginx/scts/;
```

### Key Pinning (Deprecated but Noted)

HPKP is deprecated due to risk of bricking sites. Use Certificate Transparency instead.

```nginx
# DON'T use HPKP in production — included only for historical reference
# add_header Public-Key-Pins '...' always;
```
