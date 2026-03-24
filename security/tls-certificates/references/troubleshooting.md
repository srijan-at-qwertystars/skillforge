# TLS Troubleshooting Guide

## Table of Contents

- [Certificate Chain Verification Failures](#certificate-chain-verification-failures)
  - [Missing Intermediate Certificates](#missing-intermediate-certificates)
  - [Expired Certificates in the Chain](#expired-certificates-in-the-chain)
  - [Wrong Chain Order](#wrong-chain-order)
  - [Cross-Signed Chain Issues](#cross-signed-chain-issues)
- [Hostname Mismatch](#hostname-mismatch)
  - [Common Causes](#common-causes)
  - [Debugging Steps](#debugging-steps)
  - [Wildcard Matching Rules](#wildcard-matching-rules)
- [Expired Certificate Detection](#expired-certificate-detection)
  - [Check Remote Certificate](#check-remote-certificate)
  - [Batch Expiry Check](#batch-expiry-check)
  - [Monitor with Nagios/Prometheus](#monitor-with-nagiosprometheus)
- [Mixed Content Issues](#mixed-content-issues)
  - [Detection](#detection)
  - [Fixes](#fixes)
- [OCSP Responder Failures](#ocsp-responder-failures)
  - [Diagnosing OCSP Issues](#diagnosing-ocsp-issues)
  - [OCSP Stapling Failures](#ocsp-stapling-failures)
  - [Workarounds](#workarounds)
- [Cipher Suite Negotiation Problems](#cipher-suite-negotiation-problems)
  - [No Shared Cipher](#no-shared-cipher)
  - [Debugging Cipher Negotiation](#debugging-cipher-negotiation)
  - [Common Cipher Mismatches](#common-cipher-mismatches)
- [TLS Version Incompatibility](#tls-version-incompatibility)
  - [Protocol Version Errors](#protocol-version-errors)
  - [Forcing Specific TLS Versions](#forcing-specific-tls-versions)
  - [Legacy Client Support](#legacy-client-support)
- [SNI Issues](#sni-issues)
  - [SNI Not Sent](#sni-not-sent)
  - [Default Certificate Served](#default-certificate-served)
  - [SNI Behind Load Balancers](#sni-behind-load-balancers)
- [Certificate Store Differences](#certificate-store-differences)
  - [Operating System Trust Stores](#operating-system-trust-stores)
  - [Browser Trust Stores](#browser-trust-stores)
  - [Java Trust Store (cacerts)](#java-trust-store-cacerts)
  - [Python/Node.js/Go Trust Stores](#pythonnodejsgo-trust-stores)
- [OpenSSL Debugging Cookbook](#openssl-debugging-cookbook)
  - [Connection Testing](#connection-testing)
  - [Certificate Inspection](#certificate-inspection)
  - [Key and Certificate Matching](#key-and-certificate-matching)
  - [Protocol and Cipher Testing](#protocol-and-cipher-testing)
  - [Chain Verification](#chain-verification)
  - [OCSP Testing](#ocsp-testing)
  - [Conversion Commands](#conversion-commands)

---

## Certificate Chain Verification Failures

### Missing Intermediate Certificates

**Symptom:** `unable to verify the first certificate` or `unable to get local issuer certificate`

This is the single most common TLS error. The server sends only its leaf certificate but not the intermediate CA certificate(s) needed to build a chain to a trusted root.

```bash
# Diagnose: show full chain
openssl s_client -connect example.com:443 -servername example.com -showcerts 2>/dev/null

# Look for depth in output:
#  depth=0  leaf cert (your domain)
#  depth=1  intermediate CA
#  depth=2  root CA
# If only depth=0 appears, intermediates are missing

# Verify chain completeness
openssl s_client -connect example.com:443 -servername example.com </dev/null 2>&1 | \
  grep "Verify return code"
# "Verify return code: 0 (ok)" = chain is complete
# "Verify return code: 21" = unable to verify the first certificate
```

**Fix — build correct chain bundle:**
```bash
# Download intermediate from CA's repository, then concatenate
cat leaf.crt intermediate.crt > fullchain.crt

# Nginx: use fullchain
ssl_certificate /etc/ssl/fullchain.crt;

# Apache: specify chain separately
SSLCertificateFile /etc/ssl/leaf.crt
SSLCertificateChainFile /etc/ssl/intermediate.crt
```

### Expired Certificates in the Chain

An expired intermediate or root in the chain will cause verification failure even if the leaf cert is valid.

```bash
# Check expiry of each cert in a chain file
awk 'BEGIN {c=0} /BEGIN CERT/{c++} {print > "chain-" c ".pem"}' fullchain.pem
for f in chain-*.pem; do
    echo "=== $f ==="
    openssl x509 -in "$f" -noout -subject -dates
done
rm -f chain-*.pem
```

### Wrong Chain Order

Certificates in the bundle must be ordered: leaf → intermediate(s) → root (optional).

```bash
# Verify order — subject of cert N should match issuer of cert N-1
openssl s_client -connect example.com:443 -showcerts 2>/dev/null | \
  grep -E "^ *(s:|i:)"

# Expected output:
#  s:CN = example.com          ← leaf (depth 0)
#  i:CN = R3                   ← signed by intermediate
#  s:CN = R3                   ← intermediate (depth 1)
#  i:CN = ISRG Root X1         ← signed by root
```

### Cross-Signed Chain Issues

After the DST Root CA X3 expiration (Sep 2021), older clients may fail if the server sends the expired cross-sign chain.

```bash
# Check if server is sending the expired DST cross-sign
openssl s_client -connect example.com:443 -showcerts 2>/dev/null | \
  grep "DST Root CA"

# Fix: configure server to send only the ISRG Root X1 chain
# Download correct chain from: https://letsencrypt.org/certificates/
```

---

## Hostname Mismatch

### Common Causes

1. Certificate issued for `www.example.com` but accessed via `example.com`
2. Wildcard cert `*.example.com` doesn't cover the apex `example.com`
3. Certificate CN/SAN doesn't include the accessed subdomain
4. SNI not sent, server returns default cert for wrong domain

### Debugging Steps

```bash
# Extract all names from certificate
openssl s_client -connect example.com:443 -servername example.com 2>/dev/null | \
  openssl x509 -noout -subject -ext subjectAltName

# Output example:
# subject=CN = example.com
# X509v3 Subject Alternative Name:
#     DNS:example.com, DNS:www.example.com

# Quick check — does cert cover a specific name?
echo | openssl s_client -connect example.com:443 -servername example.com 2>/dev/null | \
  openssl x509 -noout -text | grep -o "DNS:[^ ,]*"
```

### Wildcard Matching Rules

- `*.example.com` matches `www.example.com`, `api.example.com`
- `*.example.com` does **NOT** match `example.com` (apex)
- `*.example.com` does **NOT** match `sub.api.example.com` (nested)
- `*.*.example.com` is **invalid** — wildcards only in leftmost label
- Wildcard only matches in DNS SANs, never in CN (per RFC 6125)

---

## Expired Certificate Detection

### Check Remote Certificate

```bash
# Human-readable expiry dates
echo | openssl s_client -connect example.com:443 -servername example.com 2>/dev/null | \
  openssl x509 -noout -dates

# Check if expiring within N seconds (exit code 1 = expiring)
echo | openssl s_client -connect example.com:443 -servername example.com 2>/dev/null | \
  openssl x509 -noout -checkend 2592000  # 30 days = 2592000 seconds

# Days until expiry
EXPIRY=$(echo | openssl s_client -connect example.com:443 -servername example.com 2>/dev/null | \
  openssl x509 -noout -enddate | cut -d= -f2)
DAYS=$(( ( $(date -d "$EXPIRY" +%s) - $(date +%s) ) / 86400 ))
echo "Expires in $DAYS days"
```

### Batch Expiry Check

```bash
#!/bin/bash
# Check multiple domains
for DOMAIN in example.com api.example.com mail.example.com; do
    EXPIRY=$(echo | openssl s_client -connect "$DOMAIN:443" \
      -servername "$DOMAIN" 2>/dev/null | \
      openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
    if [ -n "$EXPIRY" ]; then
        DAYS=$(( ( $(date -d "$EXPIRY" +%s) - $(date +%s) ) / 86400 ))
        printf "%-30s %s (%d days)\n" "$DOMAIN" "$EXPIRY" "$DAYS"
    else
        printf "%-30s FAILED TO CONNECT\n" "$DOMAIN"
    fi
done
```

### Monitor with Nagios/Prometheus

```bash
# Nagios check_http plugin
/usr/lib/nagios/plugins/check_http -H example.com -S -C 30
# Returns CRITICAL if cert expires within 30 days

# Prometheus blackbox exporter config
modules:
  tls_connect:
    prober: tcp
    tls: true
    tcp:
      tls: true
# Alert rule:
# probe_ssl_earliest_cert_expiry - time() < 86400 * 30
```

---

## Mixed Content Issues

### Detection

Mixed content occurs when an HTTPS page loads resources over HTTP.

```bash
# Scan page for mixed content using curl
curl -s https://example.com | grep -oP 'http://[^"'"'"'> ]+' | sort -u

# Browser dev tools: Console shows mixed content warnings
# Network tab: filter by "mixed-content"
```

### Fixes

```nginx
# Nginx: redirect all HTTP to HTTPS
server {
    listen 80;
    server_name example.com;
    return 301 https://$server_name$request_uri;
}

# Add CSP header to detect mixed content
add_header Content-Security-Policy "upgrade-insecure-requests" always;
# Or report-only mode:
add_header Content-Security-Policy-Report-Only "default-src https:; report-uri /csp-report" always;
```

---

## OCSP Responder Failures

### Diagnosing OCSP Issues

```bash
# Extract OCSP responder URL from certificate
openssl x509 -in cert.pem -noout -ocsp_uri

# Get the leaf and issuer certs
openssl s_client -connect example.com:443 -servername example.com -showcerts 2>/dev/null | \
  awk '/BEGIN CERT/{i++}i==1{print > "/tmp/leaf.pem"}i==2{print > "/tmp/issuer.pem"}'

# Query OCSP responder
openssl ocsp \
  -issuer /tmp/issuer.pem \
  -cert /tmp/leaf.pem \
  -url "$(openssl x509 -in /tmp/leaf.pem -noout -ocsp_uri)" \
  -resp_text

# Check OCSP stapling from server
openssl s_client -connect example.com:443 -servername example.com \
  -status </dev/null 2>/dev/null | grep -A 10 "OCSP Response"
```

### OCSP Stapling Failures

**Symptom:** `OCSP response: no response sent` in s_client output.

Common causes:
1. **Firewall blocking** — server can't reach the OCSP responder
2. **DNS resolution failure** — resolver can't resolve OCSP URL
3. **Missing trusted certificate** — `ssl_trusted_certificate` not set
4. **Initial delay** — OCSP stapling may take a few minutes after restart

```bash
# Test if server can reach OCSP responder
OCSP_URL=$(openssl x509 -in /etc/ssl/cert.pem -noout -ocsp_uri)
curl -v "$OCSP_URL" 2>&1 | head -20

# Nginx: ensure resolver is configured
# ssl_trusted_certificate must include the full chain (intermediates + root)
```

### Workarounds

```nginx
# NGINX: increase OCSP responder timeout
resolver 8.8.8.8 8.8.4.4 valid=300s;
resolver_timeout 10s;
ssl_stapling on;
ssl_stapling_verify on;
ssl_trusted_certificate /etc/ssl/fullchain-with-root.pem;
```

---

## Cipher Suite Negotiation Problems

### No Shared Cipher

**Symptom:** `SSL_ERROR_NO_CYPHER_OVERLAP`, `no shared cipher`, `handshake failure`

```bash
# List server's supported ciphers
nmap --script ssl-enum-ciphers -p 443 example.com

# Test a specific cipher
openssl s_client -connect example.com:443 \
  -cipher 'ECDHE-RSA-AES256-GCM-SHA384' 2>&1 | grep "Cipher is"

# Test TLS 1.3 ciphersuites specifically
openssl s_client -connect example.com:443 \
  -ciphersuites 'TLS_AES_256_GCM_SHA384' -tls1_3 2>&1 | grep "Cipher is"
```

### Debugging Cipher Negotiation

```bash
# Show all supported ciphers by your OpenSSL
openssl ciphers -v 'ALL:eNULL' | column -t

# Show only ciphers matching a string
openssl ciphers -v 'ECDHE+AESGCM'

# Verbose connection showing cipher negotiation
openssl s_client -connect example.com:443 -servername example.com \
  -msg -debug 2>&1 | grep -E "(Cipher|Protocol)"
```

### Common Cipher Mismatches

| Client | Issue | Fix |
|--------|-------|-----|
| Java 8 | Doesn't support CHACHA20 | Ensure ECDHE-RSA-AES128-GCM-SHA256 is enabled |
| IE11/Win7 | No TLS 1.2 ECDHE | Enable DHE-RSA-AES128-GCM-SHA256 as fallback |
| Android 4.x | Only TLS 1.0 + RC4 | Cannot support modern ciphers — drop support |
| curl (old) | Missing ECDHE | Update curl/OpenSSL or use `--ciphers` flag |
| .NET Framework | Default to TLS 1.0 | Set `ServicePointManager.SecurityProtocol = Tls12` |

---

## TLS Version Incompatibility

### Protocol Version Errors

**Symptom:** `wrong version number`, `unsupported protocol`, `protocol version`

```bash
# Test each TLS version
for ver in tls1 tls1_1 tls1_2 tls1_3; do
    result=$(openssl s_client -connect example.com:443 -"$ver" </dev/null 2>&1)
    if echo "$result" | grep -q "BEGIN CERTIFICATE"; then
        echo "$ver: SUPPORTED"
    else
        echo "$ver: NOT SUPPORTED"
    fi
done
```

### Forcing Specific TLS Versions

```bash
# Force TLS 1.2 only
openssl s_client -connect example.com:443 -tls1_2

# Force TLS 1.3 only
openssl s_client -connect example.com:443 -tls1_3

# curl: force minimum TLS version
curl --tlsv1.2 --tls-max 1.2 https://example.com
curl --tlsv1.3 https://example.com
```

### Legacy Client Support

```nginx
# Nginx: support TLS 1.2 and 1.3 only (recommended)
ssl_protocols TLSv1.2 TLSv1.3;

# If legacy support is absolutely required (not recommended):
ssl_protocols TLSv1.2 TLSv1.3;
# Never enable TLS 1.0 or 1.1 — they are deprecated (RFC 8996)
```

---

## SNI Issues

### SNI Not Sent

**Symptom:** Server returns default/wrong certificate instead of the domain-specific one.

```bash
# Verify SNI is being sent
openssl s_client -connect example.com:443 -servername example.com </dev/null 2>&1 | \
  grep -E "subject=|issuer="

# Without SNI (gets default cert)
openssl s_client -connect example.com:443 </dev/null 2>&1 | \
  grep -E "subject=|issuer="

# Compare the two outputs — if different, SNI is needed
```

### Default Certificate Served

If the wrong certificate is served, check:

```bash
# Verify which cert is served for a specific hostname
openssl s_client -connect SERVER_IP:443 -servername www.example.com 2>/dev/null | \
  openssl x509 -noout -subject -ext subjectAltName

# Common fixes:
# 1. Nginx: ensure server_name matches and listen has ssl
# 2. Apache: ensure <VirtualHost> has ServerName and SSLCertificateFile
# 3. Check that default_server / _default_ vhost has a valid cert
```

### SNI Behind Load Balancers

```bash
# AWS ALB/NLB: SNI is handled automatically for multiple certs
# Verify with specific IP:
curl -v --resolve example.com:443:LB_IP https://example.com 2>&1 | grep "subject:"

# HAProxy: SNI-based cert selection
# frontend https
#   bind *:443 ssl crt /etc/haproxy/certs/  # loads all certs from directory
#   # HAProxy auto-selects cert based on SNI
```

---

## Certificate Store Differences

### Operating System Trust Stores

| OS | Trust Store Location | Update Command |
|----|---------------------|----------------|
| Ubuntu/Debian | `/etc/ssl/certs/`, `/usr/share/ca-certificates/` | `update-ca-certificates` |
| RHEL/CentOS | `/etc/pki/tls/certs/`, `/etc/pki/ca-trust/source/anchors/` | `update-ca-trust` |
| macOS | System Keychain, `/etc/ssl/cert.pem` | `security add-trusted-cert` |
| Windows | Certificate Manager (`certmgr.msc`) | `certutil -addstore` |
| Alpine | `/etc/ssl/certs/ca-certificates.crt` | `update-ca-certificates` |

```bash
# Add custom CA to Linux trust store
# Debian/Ubuntu:
sudo cp my-ca.crt /usr/local/share/ca-certificates/my-ca.crt
sudo update-ca-certificates

# RHEL/CentOS:
sudo cp my-ca.crt /etc/pki/ca-trust/source/anchors/my-ca.crt
sudo update-ca-trust
```

### Browser Trust Stores

- **Chrome/Edge (non-Linux):** Uses OS trust store
- **Chrome (Linux):** Uses NSS database (`~/.pki/nssdb/`)
- **Firefox:** Uses its own built-in trust store (independent of OS)
- **Safari:** Uses macOS Keychain

```bash
# Add CA to Firefox/Chrome NSS database on Linux
certutil -d sql:$HOME/.pki/nssdb -A -t "C,," -n "My CA" -i my-ca.crt

# List trusted CAs in NSS
certutil -d sql:$HOME/.pki/nssdb -L
```

### Java Trust Store (cacerts)

Java maintains its own trust store, separate from the OS. This is a frequent source of "works in browser, fails in Java" issues.

```bash
# Default location
$JAVA_HOME/lib/security/cacerts
# Default password: changeit

# List all trusted CAs
keytool -list -keystore "$JAVA_HOME/lib/security/cacerts" -storepass changeit | head -20

# Import a custom CA
keytool -importcert -keystore "$JAVA_HOME/lib/security/cacerts" \
  -storepass changeit -alias my-internal-ca -file my-ca.crt -noprompt

# Delete a CA
keytool -delete -keystore "$JAVA_HOME/lib/security/cacerts" \
  -storepass changeit -alias my-internal-ca

# Verify a cert against Java trust store
keytool -printcert -file server.crt
```

**Common Java TLS issues:**
- Java 8 older updates don't have ISRG Root X1 — update JDK or import manually
- `PKIX path building failed` — missing CA in cacerts
- `SSLHandshakeException` — check TLS version support (`-Dhttps.protocols=TLSv1.2`)

### Python/Node.js/Go Trust Stores

```bash
# Python: uses OS trust store by default, or certifi package
python3 -c "import ssl; print(ssl.get_default_verify_paths())"
# Override: SSL_CERT_FILE=/path/to/ca-bundle.crt

# Node.js: uses compiled-in Mozilla trust store
# Override: NODE_EXTRA_CA_CERTS=/path/to/ca.crt
export NODE_EXTRA_CA_CERTS=/etc/ssl/my-ca.crt

# Go: uses OS trust store
# Override: SSL_CERT_FILE=/path/to/ca-bundle.crt
# Or in code: tls.Config{RootCAs: certPool}

# curl: uses OS trust store or bundled CA
curl --cacert /path/to/ca.crt https://internal.example.com
# Or set globally:
export CURL_CA_BUNDLE=/path/to/ca-bundle.crt
```

---

## OpenSSL Debugging Cookbook

### Connection Testing

```bash
# Basic TLS connection
openssl s_client -connect example.com:443 -servername example.com </dev/null

# Show full chain
openssl s_client -connect example.com:443 -servername example.com -showcerts </dev/null

# Test specific port
openssl s_client -connect mail.example.com:587 -starttls smtp </dev/null

# STARTTLS for various protocols
openssl s_client -connect mail.example.com:993 -starttls imap
openssl s_client -connect mail.example.com:587 -starttls smtp
openssl s_client -connect ftp.example.com:21 -starttls ftp
openssl s_client -connect db.example.com:5432 -starttls postgres

# Test with client certificate (mTLS)
openssl s_client -connect api.example.com:443 \
  -cert client.crt -key client.key -CAfile ca.crt

# Test via HTTP proxy
openssl s_client -connect example.com:443 -proxy proxy.corp.com:8080
```

### Certificate Inspection

```bash
# Full certificate details
openssl x509 -in cert.pem -noout -text

# Just the important fields
openssl x509 -in cert.pem -noout -subject -issuer -dates -serial -fingerprint -sha256

# SANs only
openssl x509 -in cert.pem -noout -ext subjectAltName

# Key usage and extended key usage
openssl x509 -in cert.pem -noout -ext keyUsage,extendedKeyUsage

# Check if cert is CA
openssl x509 -in cert.pem -noout -ext basicConstraints

# Inspect remote certificate (one-liner)
echo | openssl s_client -connect example.com:443 -servername example.com 2>/dev/null | \
  openssl x509 -noout -subject -issuer -dates -ext subjectAltName
```

### Key and Certificate Matching

```bash
# Verify key matches certificate (MD5 hashes must match)
openssl x509 -noout -modulus -in cert.pem | openssl md5
openssl rsa -noout -modulus -in key.pem | openssl md5
# For ECDSA:
openssl x509 -noout -pubkey -in cert.pem | openssl md5
openssl ec -in key.pem -pubout 2>/dev/null | openssl md5

# Verify CSR matches key
openssl req -noout -modulus -in request.csr | openssl md5
openssl rsa -noout -modulus -in key.pem | openssl md5

# Verify cert was signed by a specific CA
openssl verify -CAfile ca.crt cert.pem
```

### Protocol and Cipher Testing

```bash
# Test TLS 1.2
openssl s_client -connect example.com:443 -tls1_2 </dev/null 2>&1 | grep "Protocol\|Cipher"

# Test TLS 1.3
openssl s_client -connect example.com:443 -tls1_3 </dev/null 2>&1 | grep "Protocol\|Cipher"

# Test specific cipher
openssl s_client -connect example.com:443 -cipher 'ECDHE-RSA-AES256-GCM-SHA384' </dev/null

# List all ciphers supported by server (scan)
for cipher in $(openssl ciphers 'ALL:eNULL' | tr ':' '\n'); do
    result=$(openssl s_client -connect example.com:443 -cipher "$cipher" </dev/null 2>&1)
    if echo "$result" | grep -q "Cipher is"; then
        echo "SUPPORTED: $cipher"
    fi
done
```

### Chain Verification

```bash
# Verify complete chain
openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt cert.pem

# Verify with explicit intermediate
openssl verify -CAfile root.crt -untrusted intermediate.crt leaf.crt

# Verify chain from file bundle
openssl verify -CAfile ca-bundle.crt -untrusted intermediate-bundle.crt server.crt

# Show verification path
openssl verify -show_chain -CAfile /etc/ssl/certs/ca-certificates.crt cert.pem
```

### OCSP Testing

```bash
# Check OCSP stapling
openssl s_client -connect example.com:443 -servername example.com \
  -status </dev/null 2>/dev/null | grep -A 15 "OCSP Response"

# Manual OCSP check
OCSP_URI=$(openssl x509 -in cert.pem -noout -ocsp_uri)
openssl ocsp -issuer issuer.pem -cert cert.pem -url "$OCSP_URI" -resp_text
```

### Conversion Commands

```bash
# PEM to DER
openssl x509 -in cert.pem -outform DER -out cert.der

# DER to PEM
openssl x509 -in cert.der -inform DER -outform PEM -out cert.pem

# PEM to PKCS#12
openssl pkcs12 -export -out cert.pfx -inkey key.pem -in cert.pem -certfile chain.pem

# PKCS#12 to PEM
openssl pkcs12 -in cert.pfx -out all.pem -nodes

# Extract key from PKCS#12
openssl pkcs12 -in cert.pfx -nocerts -nodes -out key.pem

# Extract cert from PKCS#12
openssl pkcs12 -in cert.pfx -clcerts -nokeys -out cert.pem

# PEM key to PKCS#8
openssl pkcs8 -topk8 -inform PEM -outform PEM -in key.pem -out key-pkcs8.pem -nocrypt

# PKCS#12 to JKS (Java KeyStore)
keytool -importkeystore -srckeystore cert.pfx -srcstoretype PKCS12 \
  -destkeystore keystore.jks -deststoretype JKS
```
