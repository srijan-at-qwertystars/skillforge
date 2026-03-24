# Cipher Suite Configurations

Recommended cipher suite configurations based on Mozilla SSL Configuration Generator
guidelines. Choose the profile that matches your compatibility requirements.

---

## Quick Reference

| Profile | Min Client | TLS Versions | Security Level |
|---------|-----------|--------------|----------------|
| **Modern** | Firefox 63+, Chrome 70+, Safari 12.1+ | TLS 1.3 only | Highest |
| **Intermediate** | Firefox 27+, Chrome 31+, Android 5.0+, Java 8+ | TLS 1.2 + 1.3 | Recommended |
| **Old** | Firefox 1+, Chrome 1+, Android 2.3+, Java 6+ | TLS 1.0+ | Legacy only |

---

## Modern Profile (TLS 1.3 Only)

Use when all clients support TLS 1.3. Maximum security, no legacy overhead.

**Cipher Suites (TLS 1.3):**
```
TLS_AES_128_GCM_SHA256
TLS_AES_256_GCM_SHA384
TLS_CHACHA20_POLY1305_SHA256
```

### Nginx — Modern
```nginx
ssl_protocols TLSv1.3;
ssl_prefer_server_ciphers off;
# TLS 1.3 ciphers are not configurable in nginx — all three are enabled by default

ssl_session_timeout 1d;
ssl_session_cache shared:TLS:10m;
ssl_session_tickets off;

ssl_stapling on;
ssl_stapling_verify on;

add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
```

### Apache — Modern
```apache
SSLProtocol             all -SSLv3 -TLSv1 -TLSv1.1 -TLSv1.2
SSLHonorCipherOrder     off
SSLSessionTickets       off

SSLUseStapling On
SSLStaplingCache "shmcb:logs/ssl_stapling(32768)"

Header always set Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"
```

### HAProxy — Modern
```
global
    ssl-default-bind-ciphersuites TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256
    ssl-default-bind-options prefer-client-ciphers no-sslv3 no-tlsv10 no-tlsv11 no-tlsv12 no-tls-tickets

    ssl-default-server-ciphersuites TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256
    ssl-default-server-options no-sslv3 no-tlsv10 no-tlsv11 no-tlsv12 no-tls-tickets
```

---

## Intermediate Profile (Recommended)

Best balance of security and compatibility. Supports TLS 1.2 and 1.3.
**This is the recommended configuration for most deployments.**

**Cipher Suites (TLS 1.2):**
```
ECDHE-ECDSA-AES128-GCM-SHA256
ECDHE-RSA-AES128-GCM-SHA256
ECDHE-ECDSA-AES256-GCM-SHA384
ECDHE-RSA-AES256-GCM-SHA384
ECDHE-ECDSA-CHACHA20-POLY1305
ECDHE-RSA-CHACHA20-POLY1305
DHE-RSA-AES128-GCM-SHA256
DHE-RSA-AES256-GCM-SHA384
DHE-RSA-CHACHA20-POLY1305
```

**TLS 1.3 suites:** Same as Modern (always enabled).

### Nginx — Intermediate
```nginx
ssl_protocols TLSv1.2 TLSv1.3;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305;
ssl_prefer_server_ciphers off;

# Generate DH params: openssl dhparam -out /etc/nginx/dhparam.pem 2048
ssl_dhparam /etc/nginx/dhparam.pem;

ssl_session_timeout 1d;
ssl_session_cache shared:TLS:10m;
ssl_session_tickets off;

ssl_stapling on;
ssl_stapling_verify on;
ssl_trusted_certificate /etc/letsencrypt/live/example.com/chain.pem;
resolver 8.8.8.8 8.8.4.4 valid=300s;
resolver_timeout 5s;

add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
add_header X-Frame-Options DENY always;
add_header X-Content-Type-Options nosniff always;
```

### Apache — Intermediate
```apache
SSLProtocol             all -SSLv3 -TLSv1 -TLSv1.1
SSLCipherSuite          ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305
SSLHonorCipherOrder     off
SSLSessionTickets       off

# Generate DH params: openssl dhparam -out /etc/ssl/dhparam.pem 2048
SSLOpenSSLConfCmd DHParameters "/etc/ssl/dhparam.pem"

SSLUseStapling On
SSLStaplingCache "shmcb:logs/ssl_stapling(32768)"

Header always set Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"
Header always set X-Frame-Options DENY
Header always set X-Content-Type-Options nosniff
```

### HAProxy — Intermediate
```
global
    ssl-default-bind-ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305
    ssl-default-bind-ciphersuites TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256
    ssl-default-bind-options prefer-client-ciphers no-sslv3 no-tlsv10 no-tlsv11 no-tls-tickets

    ssl-default-server-ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305
    ssl-default-server-ciphersuites TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256
    ssl-default-server-options no-sslv3 no-tlsv10 no-tlsv11 no-tls-tickets

    # Generate DH params: openssl dhparam -out /etc/haproxy/dhparam.pem 2048
    ssl-dh-param-file /etc/haproxy/dhparam.pem
```

### Caddy — Intermediate
```
# Caddy uses secure defaults automatically. To customize:
{
    servers {
        protocols h1 h2
    }
}

example.com {
    tls {
        protocols tls1.2 tls1.3
        ciphers TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256 TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256 TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384 TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384 TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256 TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256
    }
}
```

---

## Old Profile (Legacy Compatibility)

**Only use when you must support very old clients (Windows XP, Java 6, Android 2.3).**
This profile includes weaker ciphers and should be avoided for new deployments.

**Additional Cipher Suites (beyond Intermediate):**
```
ECDHE-ECDSA-AES128-SHA256
ECDHE-RSA-AES128-SHA256
ECDHE-ECDSA-AES128-SHA
ECDHE-RSA-AES128-SHA
ECDHE-ECDSA-AES256-SHA384
ECDHE-RSA-AES256-SHA384
ECDHE-ECDSA-AES256-SHA
ECDHE-RSA-AES256-SHA
DHE-RSA-AES128-SHA256
DHE-RSA-AES256-SHA256
AES128-GCM-SHA256
AES256-GCM-SHA384
AES128-SHA256
AES256-SHA256
AES128-SHA
AES256-SHA
DES-CBC3-SHA
```

### Nginx — Old
```nginx
ssl_protocols TLSv1 TLSv1.1 TLSv1.2 TLSv1.3;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA256:ECDHE-ECDSA-AES128-SHA:ECDHE-RSA-AES128-SHA:ECDHE-ECDSA-AES256-SHA384:ECDHE-RSA-AES256-SHA384:ECDHE-ECDSA-AES256-SHA:ECDHE-RSA-AES256-SHA:DHE-RSA-AES128-SHA256:DHE-RSA-AES256-SHA256:AES128-GCM-SHA256:AES256-GCM-SHA384:AES128-SHA256:AES256-SHA256:AES128-SHA:AES256-SHA:DES-CBC3-SHA;
ssl_prefer_server_ciphers on;
```

---

## Cipher Suite Selection Principles

1. **AEAD ciphers only** for Modern/Intermediate (GCM, CHACHA20-POLY1305)
2. **ECDHE preferred** over DHE for key exchange (faster)
3. **ECDSA preferred** over RSA for signatures (smaller, faster) — requires ECDSA certificate
4. **Forward secrecy required** — all suites use ephemeral key exchange
5. **No CBC mode** in Modern/Intermediate — vulnerable to padding oracle attacks
6. **No RSA key exchange** — no forward secrecy
7. **No RC4, 3DES, MD5, SHA-1** in Modern/Intermediate
8. **`ssl_prefer_server_ciphers off`** for Intermediate — lets clients choose their preferred cipher

## Testing Your Configuration

```bash
# Quick test with openssl
openssl s_client -connect example.com:443 -servername example.com </dev/null 2>/dev/null | \
  grep -E "Protocol|Cipher"

# Comprehensive test with nmap
nmap --script ssl-enum-ciphers -p 443 example.com

# Online testers
# - https://www.ssllabs.com/ssltest/
# - https://www.immuniweb.com/ssl/
# - https://observatory.mozilla.org/

# Mozilla SSL Configuration Generator
# - https://ssl-config.mozilla.org/
```

## DH Parameters

For Intermediate and Old profiles using DHE cipher suites, generate custom DH parameters:

```bash
# Generate 2048-bit DH params (recommended minimum)
openssl dhparam -out dhparam.pem 2048

# For higher security (slower to generate)
openssl dhparam -out dhparam.pem 4096
```

Place the file where your server config references it, with restrictive permissions:
```bash
chmod 600 dhparam.pem
```
