# Nginx Security Hardening Guide

## Table of Contents

- [SSL/TLS Best Practices (Mozilla Recommendations)](#ssltls-best-practices-mozilla-recommendations)
- [Certificate Automation (Certbot, ACME)](#certificate-automation-certbot-acme)
- [DDoS Mitigation](#ddos-mitigation)
- [WAF with ModSecurity/njs](#waf-with-modsecuritynjs)
- [Bot Detection](#bot-detection)
- [IP Allowlists and Denylists](#ip-allowlists-and-denylists)
- [Hiding Server Version](#hiding-server-version)
- [Content Security Policy Headers](#content-security-policy-headers)
- [CORS Configuration](#cors-configuration)

---

## SSL/TLS Best Practices (Mozilla Recommendations)

Mozilla publishes three configuration profiles: **Modern**, **Intermediate**, and **Old**. Use Intermediate for broad compatibility.

### Modern Configuration (TLS 1.3 Only)

For services that don't need legacy client support (APIs, internal services).

```nginx
server {
    listen 443 ssl;
    http2 on;

    ssl_certificate     /etc/letsencrypt/live/example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/example.com/privkey.pem;

    ssl_protocols TLSv1.3;
    # TLS 1.3 cipher suites are not configurable in nginx — the
    # implementation selects the best available automatically

    ssl_prefer_server_ciphers off;

    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;
    ssl_session_tickets off;

    # OCSP Stapling
    ssl_stapling on;
    ssl_stapling_verify on;
    ssl_trusted_certificate /etc/letsencrypt/live/example.com/chain.pem;
    resolver 1.1.1.1 8.8.8.8 valid=300s;
    resolver_timeout 5s;

    # HSTS (2 years)
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
}
```

### Intermediate Configuration (TLS 1.2 + 1.3)

Recommended for most public-facing sites. Supports clients back to Firefox 27, Android 4.4, Chrome 31, IE 11, Safari 9.

```nginx
server {
    listen 443 ssl;
    http2 on;

    ssl_certificate     /etc/letsencrypt/live/example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/example.com/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;

    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;
    ssl_session_tickets off;

    # DH parameters (generate: openssl dhparam -out /etc/nginx/dhparam.pem 2048)
    ssl_dhparam /etc/nginx/dhparam.pem;

    # OCSP Stapling
    ssl_stapling on;
    ssl_stapling_verify on;
    ssl_trusted_certificate /etc/letsencrypt/live/example.com/chain.pem;
    resolver 1.1.1.1 8.8.8.8 valid=300s;
    resolver_timeout 5s;

    # HSTS
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
}
```

### OCSP Stapling Deep Dive

OCSP stapling proves the certificate isn't revoked without the client contacting the CA.

```nginx
ssl_stapling on;
ssl_stapling_verify on;

# The trust chain for OCSP verification
ssl_trusted_certificate /etc/letsencrypt/live/example.com/chain.pem;

# DNS resolver for OCSP responder lookups
resolver 1.1.1.1 8.8.8.8 valid=300s;
resolver_timeout 5s;
```

```bash
# Verify OCSP stapling is working
openssl s_client -connect example.com:443 -servername example.com -status < /dev/null 2>&1 | grep "OCSP Response Status"
# Expected: OCSP Response Status: successful (0x0)
```

### Certificate Chain Verification

```bash
# Verify certificate chain is complete
openssl s_client -connect example.com:443 -servername example.com < /dev/null 2>&1 | openssl x509 -noout -dates -subject -issuer

# Check certificate expiry
echo | openssl s_client -connect example.com:443 -servername example.com 2>/dev/null | openssl x509 -noout -enddate

# Test SSL configuration
# Use Mozilla's TLS Observatory or testssl.sh
docker run --rm -t drwetter/testssl.sh example.com
```

### HTTP to HTTPS Redirect

```nginx
server {
    listen 80;
    listen [::]:80;
    server_name example.com www.example.com;
    return 301 https://$host$request_uri;
}
```

---

## Certificate Automation (Certbot, ACME)

### Certbot with Nginx Plugin

```bash
# Install certbot
apt install certbot python3-certbot-nginx    # Debian/Ubuntu
dnf install certbot python3-certbot-nginx    # RHEL/Fedora

# Obtain certificate (modifies nginx config automatically)
certbot --nginx -d example.com -d www.example.com

# Obtain certificate (standalone, no nginx modification)
certbot certonly --webroot -w /var/www/html -d example.com -d www.example.com

# Renew all certificates
certbot renew

# Dry-run renewal test
certbot renew --dry-run
```

### Webroot Method Configuration

```nginx
# Nginx config for ACME challenge validation
server {
    listen 80;
    server_name example.com;

    # ACME challenge location
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
        try_files $uri =404;
    }

    # Redirect everything else to HTTPS
    location / {
        return 301 https://$host$request_uri;
    }
}
```

### Automated Renewal with Hooks

```bash
# /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
#!/bin/bash
systemctl reload nginx

# Cron job (certbot usually adds this automatically)
# 0 0,12 * * * certbot renew --quiet --deploy-hook "systemctl reload nginx"
```

### Wildcard Certificates with DNS Challenge

```bash
# Requires DNS plugin (e.g., Cloudflare)
certbot certonly \
  --dns-cloudflare \
  --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
  -d "*.example.com" \
  -d "example.com"
```

### acme.sh Alternative

```bash
# Install acme.sh
curl https://get.acme.sh | sh

# Issue certificate using webroot
acme.sh --issue -d example.com -w /var/www/html

# Install certificate with auto-reload
acme.sh --install-cert -d example.com \
  --key-file       /etc/nginx/ssl/example.com.key \
  --fullchain-file /etc/nginx/ssl/example.com.fullchain.pem \
  --reloadcmd      "systemctl reload nginx"
```

### Certificate Monitoring Script

```bash
#!/bin/bash
# Check certificate expiry and alert
DOMAINS=("example.com" "api.example.com" "www.example.com")
WARN_DAYS=30

for domain in "${DOMAINS[@]}"; do
    expiry=$(echo | openssl s_client -connect "$domain:443" -servername "$domain" 2>/dev/null | \
             openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
    if [ -n "$expiry" ]; then
        expiry_epoch=$(date -d "$expiry" +%s)
        now_epoch=$(date +%s)
        days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
        if [ "$days_left" -lt "$WARN_DAYS" ]; then
            echo "WARNING: $domain certificate expires in $days_left days ($expiry)"
        fi
    fi
done
```

---

## DDoS Mitigation

### Rate Limiting

```nginx
http {
    # Zone definitions (in http block)
    limit_req_zone $binary_remote_addr zone=general:20m rate=10r/s;
    limit_req_zone $binary_remote_addr zone=login:10m rate=3r/m;
    limit_req_zone $binary_remote_addr zone=api:20m rate=30r/s;

    # Connection limiting
    limit_conn_zone $binary_remote_addr zone=connperip:10m;
    limit_conn_zone $server_name zone=connperserver:10m;

    # Return 429 instead of default 503
    limit_req_status 429;
    limit_conn_status 429;

    server {
        # Global connection limit
        limit_conn connperip 50;
        limit_conn connperserver 10000;

        location / {
            limit_req zone=general burst=30 nodelay;
        }

        location /login {
            limit_req zone=login burst=3 nodelay;
            limit_conn connperip 5;
        }

        location /api/ {
            limit_req zone=api burst=50 nodelay;
        }
    }
}
```

### Connection Throttling

```nginx
server {
    # Limit bandwidth per connection
    location /downloads/ {
        limit_rate 500k;             # 500KB/s per connection
        limit_rate_after 10m;        # full speed for first 10MB
        limit_conn connperip 2;      # max 2 simultaneous downloads
    }

    # Slow down suspected attackers
    location / {
        # Delay response if too many requests
        limit_req zone=general burst=30 delay=20;
        # First 20 requests served immediately, next 10 delayed
    }
}
```

### Request Filtering

```nginx
server {
    # Block oversized request bodies
    client_max_body_size 10m;

    # Timeout slow clients (slowloris protection)
    client_body_timeout 10s;
    client_header_timeout 10s;
    send_timeout 10s;

    # Limit request line and header sizes
    large_client_header_buffers 4 8k;

    # Block requests with no Host header
    if ($host = "") {
        return 444;   # close connection without response
    }

    # Block requests with suspicious methods
    if ($request_method !~ ^(GET|HEAD|POST|PUT|PATCH|DELETE|OPTIONS)$) {
        return 444;
    }
}
```

### Geo-Based Blocking

```nginx
# Block known bad CIDR ranges
geo $blocked_country {
    default         0;
    # Add CIDR blocks from threat intelligence feeds
    # 192.0.2.0/24  1;  # example
}

server {
    if ($blocked_country) {
        return 444;
    }
}
```

### Kernel-Level Protections

```bash
# /etc/sysctl.d/ddos-protection.conf
# SYN flood protection
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_synack_retries = 2

# Connection tracking
net.netfilter.nf_conntrack_max = 1000000
net.netfilter.nf_conntrack_tcp_timeout_established = 600

# Rate limit at kernel level with iptables
# iptables -A INPUT -p tcp --dport 80 -m connlimit --connlimit-above 50 -j DROP
# iptables -A INPUT -p tcp --dport 80 -m recent --set --name HTTP
# iptables -A INPUT -p tcp --dport 80 -m recent --update --seconds 10 --hitcount 100 --name HTTP -j DROP
```

---

## WAF with ModSecurity/njs

### ModSecurity with Nginx

```bash
# Install ModSecurity for Nginx
apt install libmodsecurity3 libnginx-mod-http-modsecurity

# Or compile nginx with ModSecurity connector
# ./configure --add-dynamic-module=/path/to/ModSecurity-nginx
```

```nginx
# Enable ModSecurity
load_module modules/ngx_http_modsecurity_module.so;

http {
    modsecurity on;
    modsecurity_rules_file /etc/nginx/modsecurity/main.conf;

    server {
        location / {
            proxy_pass http://backend;
        }

        # Disable ModSecurity for health checks
        location = /health {
            modsecurity off;
            return 200 "ok";
        }
    }
}
```

### ModSecurity Configuration

```
# /etc/nginx/modsecurity/main.conf
Include /etc/nginx/modsecurity/modsecurity.conf
Include /etc/nginx/modsecurity/crs-setup.conf
Include /etc/nginx/modsecurity/rules/*.conf

# Set to DetectionOnly first, then switch to On
SecRuleEngine On

# Audit logging
SecAuditEngine RelevantOnly
SecAuditLogRelevantStatus "^(?:5|4(?!04))"
SecAuditLog /var/log/modsecurity/audit.log
SecAuditLogType Serial
```

### OWASP Core Rule Set (CRS)

```bash
# Install CRS
cd /etc/nginx/modsecurity
git clone https://github.com/coreruleset/coreruleset.git
cp coreruleset/crs-setup.conf.example crs-setup.conf
ln -s coreruleset/rules rules
```

### Lightweight WAF with njs

For environments where ModSecurity is not available:

```nginx
# /etc/nginx/njs/waf.js
function wafCheck(r) {
    let uri = r.uri.toLowerCase();
    let args = r.variables.query_string || '';
    let body = r.requestText || '';
    let userAgent = (r.headersIn['User-Agent'] || '').toLowerCase();

    // SQL injection patterns
    let sqlPatterns = [
        /(\bunion\b.*\bselect\b)/i,
        /(\bor\b\s+\d+=\d+)/i,
        /(\bdrop\b.*\btable\b)/i,
        /(\binsert\b.*\binto\b)/i,
        /(';\s*--)/i,
        /(\/\*.*\*\/)/i,
    ];

    // XSS patterns
    let xssPatterns = [
        /(<script[^>]*>)/i,
        /(javascript\s*:)/i,
        /(on\w+\s*=\s*["'])/i,
        /(<iframe[^>]*>)/i,
        /(<object[^>]*>)/i,
    ];

    // Path traversal
    let traversalPatterns = [
        /(\.\.\/)/,
        /(\.\.\\)/,
        /(%2e%2e)/i,
        /(etc\/passwd)/i,
    ];

    let checkString = uri + ' ' + decodeURIComponent(args) + ' ' + body;

    for (let p of sqlPatterns) {
        if (p.test(checkString)) {
            r.headersOut['X-WAF-Block'] = 'sql-injection';
            r.return(403, JSON.stringify({
                error: 'Forbidden',
                reason: 'Request blocked by WAF'
            }));
            return;
        }
    }

    for (let p of xssPatterns) {
        if (p.test(checkString)) {
            r.headersOut['X-WAF-Block'] = 'xss';
            r.return(403, JSON.stringify({
                error: 'Forbidden',
                reason: 'Request blocked by WAF'
            }));
            return;
        }
    }

    for (let p of traversalPatterns) {
        if (p.test(checkString)) {
            r.headersOut['X-WAF-Block'] = 'path-traversal';
            r.return(403, JSON.stringify({
                error: 'Forbidden',
                reason: 'Request blocked by WAF'
            }));
            return;
        }
    }

    r.return(200);
}

export default { wafCheck };
```

```nginx
js_import waf from waf.js;

server {
    location /api/ {
        auth_request /waf-check;
        proxy_pass http://backend;
    }

    location = /waf-check {
        internal;
        js_content waf.wafCheck;
    }
}
```

---

## Bot Detection

### User-Agent Based Detection

```nginx
map $http_user_agent $is_bot {
    default                                     0;
    # Known good bots
    ~*(googlebot|bingbot|yandexbot|duckduckbot) good;
    # Suspicious bots
    ~*(scrapy|httpclient|python-requests|curl)  suspect;
    ~*(wget|java|libwww-perl|lwp-trivial)       suspect;
    # Definitely bad
    ~*(nikto|sqlmap|nmap|masscan|zgrab)          bad;
    ""                                          bad;   # empty UA
}

server {
    # Block bad bots immediately
    if ($is_bot = bad) {
        return 444;
    }

    # Rate limit suspicious bots more aggressively
    # (see rate limiting section for zone setup)
    location / {
        if ($is_bot = suspect) {
            set $limit_key_bot $binary_remote_addr;
        }
        proxy_pass http://backend;
    }
}
```

### Advanced Bot Detection with njs

```nginx
# /etc/nginx/njs/bot_detect.js
function detectBot(r) {
    let ua = r.headersIn['User-Agent'] || '';
    let score = 0;

    // No User-Agent
    if (!ua) score += 50;

    // Missing common browser headers
    if (!r.headersIn['Accept']) score += 10;
    if (!r.headersIn['Accept-Language']) score += 10;
    if (!r.headersIn['Accept-Encoding']) score += 5;

    // Claims to be a browser but missing headers
    if (/Mozilla/.test(ua)) {
        if (!r.headersIn['Accept-Language']) score += 20;
        if (!r.headersIn['Accept-Encoding']) score += 15;
    }

    // Known scanner signatures
    if (/nikto|sqlmap|nmap|masscan|zgrab|nuclei/i.test(ua)) score += 100;

    // HTTP method anomalies for browsers
    if (/Mozilla/.test(ua) && /^(TRACE|TRACK|DEBUG|PROPFIND)$/.test(r.method)) {
        score += 50;
    }

    // Return score as header for downstream processing
    if (score >= 50) {
        r.return(403);
        return;
    }

    r.headersOut['X-Bot-Score'] = score.toString();
    r.return(200);
}

export default { detectBot };
```

### Robots.txt and Crawl-Delay

```nginx
location = /robots.txt {
    add_header Content-Type text/plain;
    return 200 "User-agent: *\nDisallow: /admin/\nDisallow: /api/\nCrawl-delay: 10\n\nUser-agent: Googlebot\nAllow: /\nCrawl-delay: 1\n";
}
```

### Honeypot Traps

```nginx
# Hidden link in HTML that real users won't click
# but bots following all links will trigger
location /totally-not-a-trap {
    # Log and block the IP
    access_log /var/log/nginx/honeypot.log;
    return 444;
    # Feed honeypot IPs into deny list via automation
}
```

---

## IP Allowlists and Denylists

### Static IP Lists

```nginx
# Allow only specific IPs
location /admin/ {
    allow 10.0.0.0/8;
    allow 192.168.1.0/24;
    allow 203.0.113.50;      # office IP
    deny all;
    proxy_pass http://backend;
}

# Block specific IPs (order matters — first match wins)
location / {
    deny 192.0.2.1;
    deny 198.51.100.0/24;
    allow all;
    proxy_pass http://backend;
}
```

### External IP Lists with include

```nginx
# /etc/nginx/conf.d/blocklist.conf (auto-generated)
deny 192.0.2.1;
deny 198.51.100.0/24;
deny 203.0.113.0/24;

# Main nginx config
location / {
    include /etc/nginx/conf.d/blocklist.conf;
    allow all;
    proxy_pass http://backend;
}
```

### Geo Module for IP Lists

```nginx
geo $blocked_ip {
    default 0;
    include /etc/nginx/geo/blocklist.conf;
    # blocklist.conf format:
    # 192.0.2.0/24 1;
    # 198.51.100.0/24 1;
}

geo $allowed_ip {
    default 0;
    10.0.0.0/8      1;
    192.168.0.0/16   1;
    203.0.113.50     1;
}

server {
    # Block listed IPs
    if ($blocked_ip) {
        return 444;
    }

    location /admin/ {
        if ($allowed_ip = 0) {
            return 403;
        }
        proxy_pass http://backend;
    }
}
```

### Dynamic Blocklist with fail2ban

```ini
# /etc/fail2ban/jail.d/nginx.conf
[nginx-limit-req]
enabled  = true
port     = http,https
filter   = nginx-limit-req
logpath  = /var/log/nginx/error.log
maxretry = 10
findtime = 600
bantime  = 3600
action   = iptables-multiport[name=nginx, port="80,443"]

[nginx-botsearch]
enabled  = true
port     = http,https
filter   = nginx-botsearch
logpath  = /var/log/nginx/access.log
maxretry = 5
findtime = 600
bantime  = 86400
```

### Real Client IP Behind Proxies

```nginx
# When behind a CDN or load balancer
set_real_ip_from 10.0.0.0/8;        # trusted proxy CIDR
set_real_ip_from 172.16.0.0/12;
set_real_ip_from 192.168.0.0/16;
set_real_ip_from 103.21.244.0/22;   # Cloudflare range
real_ip_header X-Forwarded-For;
real_ip_recursive on;   # look through chain of proxies
```

---

## Hiding Server Version

### Remove Server Header

```nginx
http {
    # Hide nginx version from Server header
    server_tokens off;
    # Changes "Server: nginx/1.24.0" to "Server: nginx"

    # To completely remove the Server header, use headers-more module
    more_clear_headers Server;
    # Or set a custom value
    more_set_headers "Server: MyApp";
}
```

### Hide Additional Information

```nginx
http {
    server_tokens off;

    # Remove headers that leak info
    proxy_hide_header X-Powered-By;
    proxy_hide_header X-AspNet-Version;
    proxy_hide_header X-AspNetMvc-Version;
    proxy_hide_header X-Runtime;
    proxy_hide_header X-Generator;

    # Hide PHP version
    fastcgi_hide_header X-Powered-By;

    # Custom error pages (don't expose nginx defaults)
    error_page 404 /custom_404.html;
    error_page 500 502 503 504 /custom_50x.html;

    location = /custom_404.html {
        root /var/www/error_pages;
        internal;
    }

    location = /custom_50x.html {
        root /var/www/error_pages;
        internal;
    }
}
```

### Disable Unnecessary Modules

Build nginx with only required modules:

```bash
./configure \
    --without-http_autoindex_module \
    --without-http_ssi_module \
    --without-http_userid_module \
    --without-http_scgi_module \
    --without-http_uwsgi_module \
    --without-http_empty_gif_module \
    --without-http_browser_module
```

---

## Content Security Policy Headers

### Basic CSP

```nginx
# Restrictive baseline — adjust per application
add_header Content-Security-Policy "
    default-src 'self';
    script-src 'self';
    style-src 'self' 'unsafe-inline';
    img-src 'self' data: https:;
    font-src 'self';
    connect-src 'self';
    media-src 'self';
    object-src 'none';
    frame-src 'none';
    frame-ancestors 'none';
    form-action 'self';
    base-uri 'self';
    upgrade-insecure-requests;
" always;
```

### CSP for Common Stacks

```nginx
# React/Vue/Angular SPA
add_header Content-Security-Policy "
    default-src 'self';
    script-src 'self' 'unsafe-inline' 'unsafe-eval';
    style-src 'self' 'unsafe-inline' https://fonts.googleapis.com;
    font-src 'self' https://fonts.gstatic.com;
    img-src 'self' data: blob: https:;
    connect-src 'self' https://api.example.com wss://ws.example.com;
    frame-ancestors 'none';
    base-uri 'self';
" always;

# WordPress / CMS
add_header Content-Security-Policy "
    default-src 'self';
    script-src 'self' 'unsafe-inline' 'unsafe-eval' https://www.google-analytics.com https://www.googletagmanager.com;
    style-src 'self' 'unsafe-inline' https://fonts.googleapis.com;
    img-src 'self' data: https:;
    font-src 'self' https://fonts.gstatic.com;
    connect-src 'self' https://www.google-analytics.com;
    frame-src https://www.youtube.com https://player.vimeo.com;
    frame-ancestors 'self';
" always;
```

### Report-Only Mode (Testing)

```nginx
# Test CSP without blocking — check browser console for violations
add_header Content-Security-Policy-Report-Only "
    default-src 'self';
    script-src 'self';
    style-src 'self';
    report-uri /csp-report;
    report-to csp-endpoint;
" always;

# Collect CSP violation reports
location /csp-report {
    proxy_pass http://csp-collector:8080;
    # Or log directly
    access_log /var/log/nginx/csp-reports.log;
    return 204;
}
```

### Full Security Headers Set

```nginx
# Include this file in every server block: include /etc/nginx/security-headers.conf;

# Prevent clickjacking
add_header X-Frame-Options "SAMEORIGIN" always;

# Prevent MIME sniffing
add_header X-Content-Type-Options "nosniff" always;

# Disable XSS auditor (modern browsers don't need it, can cause issues)
add_header X-XSS-Protection "0" always;

# Control referrer information
add_header Referrer-Policy "strict-origin-when-cross-origin" always;

# Restrict browser features
add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=(), usb=(), magnetometer=(), gyroscope=(), accelerometer=()" always;

# HSTS (only enable after confirming HTTPS works)
add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;

# CSP
add_header Content-Security-Policy "default-src 'self'; frame-ancestors 'none';" always;

# Prevent caching of sensitive pages
# (use selectively, not globally)
# add_header Cache-Control "no-store, no-cache, must-revalidate" always;
# add_header Pragma "no-cache" always;
```

---

## CORS Configuration

### Simple CORS (Single Origin)

```nginx
server {
    location /api/ {
        # Allow specific origin
        add_header Access-Control-Allow-Origin "https://app.example.com" always;
        add_header Access-Control-Allow-Methods "GET, POST, PUT, DELETE, OPTIONS" always;
        add_header Access-Control-Allow-Headers "Authorization, Content-Type, X-Requested-With" always;
        add_header Access-Control-Allow-Credentials "true" always;
        add_header Access-Control-Max-Age "86400" always;

        # Handle preflight requests
        if ($request_method = OPTIONS) {
            return 204;
        }

        proxy_pass http://backend;
    }
}
```

### Dynamic CORS (Multiple Origins)

```nginx
map $http_origin $cors_origin {
    default "";
    "https://app.example.com"     $http_origin;
    "https://staging.example.com" $http_origin;
    "https://admin.example.com"   $http_origin;
    ~^https://.*\.example\.com$   $http_origin;   # wildcard subdomain
}

map $http_origin $cors_credentials {
    default "";
    "https://app.example.com"     "true";
    "https://staging.example.com" "true";
    "https://admin.example.com"   "true";
    ~^https://.*\.example\.com$   "true";
}

server {
    location /api/ {
        # Only set CORS headers if origin is allowed
        add_header Access-Control-Allow-Origin $cors_origin always;
        add_header Access-Control-Allow-Methods "GET, POST, PUT, DELETE, PATCH, OPTIONS" always;
        add_header Access-Control-Allow-Headers "Authorization, Content-Type, X-Requested-With, X-Request-ID" always;
        add_header Access-Control-Allow-Credentials $cors_credentials always;
        add_header Access-Control-Max-Age "86400" always;
        add_header Access-Control-Expose-Headers "X-Request-ID, X-RateLimit-Remaining" always;

        # Vary header is important for caching
        add_header Vary "Origin" always;

        if ($request_method = OPTIONS) {
            return 204;
        }

        proxy_pass http://backend;
    }
}
```

### CORS for Public APIs

```nginx
location /api/public/ {
    add_header Access-Control-Allow-Origin "*" always;
    add_header Access-Control-Allow-Methods "GET, HEAD, OPTIONS" always;
    add_header Access-Control-Allow-Headers "Content-Type" always;
    add_header Access-Control-Max-Age "86400" always;

    # No credentials with wildcard origin
    # add_header Access-Control-Allow-Credentials "true";  ← INVALID with "*"

    if ($request_method = OPTIONS) {
        return 204;
    }

    proxy_pass http://backend;
}
```

### CORS Debugging

```bash
# Test preflight request
curl -v -X OPTIONS \
  -H "Origin: https://app.example.com" \
  -H "Access-Control-Request-Method: POST" \
  -H "Access-Control-Request-Headers: Content-Type, Authorization" \
  https://api.example.com/api/test

# Test actual CORS request
curl -v \
  -H "Origin: https://app.example.com" \
  https://api.example.com/api/test

# Check response headers
# Look for: Access-Control-Allow-Origin, Access-Control-Allow-Methods, etc.
```

### Common CORS Mistakes

```nginx
# MISTAKE 1: add_header in location with proxy_pass doesn't inherit from server
server {
    add_header Access-Control-Allow-Origin "*" always;

    location /api/ {
        proxy_pass http://backend;
        # ⚠️ If backend sets ANY header, the above add_header is IGNORED
        # because proxy adds its own headers
        # FIX: add the header in the location block too
        add_header Access-Control-Allow-Origin "*" always;
    }
}

# MISTAKE 2: Credentials with wildcard origin
# This is INVALID and browsers will reject it:
# Access-Control-Allow-Origin: *
# Access-Control-Allow-Credentials: true
# FIX: Use specific origin when credentials are needed

# MISTAKE 3: Missing Vary header
# Without Vary: Origin, CDNs may cache response with wrong CORS headers
# Always add: add_header Vary "Origin" always;

# MISTAKE 4: Forgetting 'always' parameter
# Without 'always', headers are only added on 2xx/3xx responses
# Error responses (4xx/5xx) won't have CORS headers, causing confusing errors
add_header Access-Control-Allow-Origin "*" always;  # ← 'always' is important
```
