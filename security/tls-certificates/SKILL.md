---
name: tls-certificates
description: >
  Comprehensive guide for TLS/SSL certificate management, debugging, and automation.
  Use when user needs SSL/TLS certificates, HTTPS setup, certificate debugging,
  Let's Encrypt automation, certbot, mTLS mutual authentication, openssl commands,
  certificate chain issues, CSR generation, self-signed certificates, certificate
  renewal, OCSP stapling, HSTS configuration, certificate pinning, cipher suite
  selection, SNI setup, cert-manager for Kubernetes, or ACME protocol integration.
  NOT for application-level encryption (AES, symmetric ciphers), NOT for SSH keys
  or SSH configuration, NOT for JWT/token signing or verification, NOT for VPN
  configuration (WireGuard, OpenVPN tunnels), NOT for code signing certificates.
---

# TLS Certificates

## TLS Handshake

### TLS 1.2 (2-RTT)
1. ClientHello: supported cipher suites, random, session ID
2. ServerHello: selected suite, random, session ID
3. Server sends Certificate, ServerKeyExchange (if DHE/ECDHE), ServerHelloDone
4. Client sends ClientKeyExchange, ChangeCipherSpec, Finished
5. Server sends ChangeCipherSpec, Finished
- Certificate sent in plaintext. PFS optional (only with ECDHE/DHE suites).

### TLS 1.3 (1-RTT)
1. ClientHello: supported suites + key shares (X25519/P-256) sent immediately
2. ServerHello: selected suite + key share; all subsequent messages encrypted
3. Server sends EncryptedExtensions, Certificate, CertificateVerify, Finished
4. Client sends Finished; application data flows
- 0-RTT resumption available (replay risk). PFS mandatory. Only 5 AEAD cipher suites.
- All legacy algorithms removed: no RSA key exchange, CBC, RC4, SHA-1, 3DES.

### Recommended cipher suites
TLS 1.3: `TLS_AES_256_GCM_SHA384`, `TLS_CHACHA20_POLY1305_SHA256`, `TLS_AES_128_GCM_SHA256`
TLS 1.2: `ECDHE-ECDSA-AES256-GCM-SHA384`, `ECDHE-RSA-AES256-GCM-SHA384`, `ECDHE-ECDSA-CHACHA20-POLY1305`, `ECDHE-RSA-CHACHA20-POLY1305`

## Certificate Types

| Type | Validation | Use Case | Issuance Time |
|------|-----------|----------|---------------|
| DV (Domain Validation) | Domain control only | Blogs, small sites | Minutes |
| OV (Organization Validation) | Domain + org verified | Business sites | 1-3 days |
| EV (Extended Validation) | Full org vetting | Financial, e-commerce | 1-2 weeks |
| Wildcard (`*.example.com`) | Covers all subdomains of one level | Multi-subdomain sites | Varies |
| SAN/Multi-domain | Multiple distinct domains in one cert | CDNs, multi-tenant | Varies |

- Wildcard certs do NOT cover the apex domain; request both `*.example.com` and `example.com`.
- SAN certs list domains in the Subject Alternative Name extension.

## Certificate Formats

### PEM (Base64, `.pem`, `.crt`, `.key`)
Most common on Linux/Apache/Nginx. Base64-encoded, delimited by `-----BEGIN/END CERTIFICATE-----`. Concatenate chain: leaf → intermediate → root.

### DER (Binary, `.der`, `.cer`)
Binary encoding of PEM. Used by Java, Windows.
```bash
# PEM to DER
openssl x509 -in cert.pem -outform DER -out cert.der
# DER to PEM
openssl x509 -in cert.der -inform DER -outform PEM -out cert.pem
```

### PKCS#12/PFX (`.p12`, `.pfx`)
Bundles private key + certificate + chain in one encrypted file. Used by Windows/IIS, Java.
```bash
# Create PFX from PEM
openssl pkcs12 -export -out cert.pfx -inkey key.pem -in cert.pem -certfile chain.pem
# Extract from PFX
openssl pkcs12 -in cert.pfx -out all.pem -nodes
```

### JKS (Java KeyStore, `.jks`)
```bash
# Import PFX into JKS
keytool -importkeystore -srckeystore cert.pfx -srcstoretype PKCS12 \
  -destkeystore keystore.jks -deststoretype JKS
# List entries
keytool -list -keystore keystore.jks -v
```

## Key Types

| Algorithm | Key Size | Security Bits | Signature Size | TLS Support |
|-----------|----------|---------------|----------------|-------------|
| RSA | 2048/3072/4096 | 112/128/140 | 256-512 bytes | Universal |
| ECDSA P-256 | 256-bit curve | 128 | 64 bytes | Modern clients |
| ECDSA P-384 | 384-bit curve | 192 | 96 bytes | Modern clients |
| Ed25519 | 256-bit fixed | ~128 | 64 bytes | Limited in TLS |

- **Use ECDSA P-256** for modern deployments: fastest handshakes, smallest certs.
- **Use RSA 2048+** when legacy device support is required.
- **Ed25519**: best performance but not yet supported by most public CAs for TLS certs.

## CSR Generation

### RSA CSR
```bash
# Generate RSA key + CSR in one step
openssl req -new -newkey rsa:2048 -nodes -keyout server.key -out server.csr \
  -subj "/C=US/ST=California/L=SF/O=MyOrg/CN=example.com"
```

### ECDSA CSR
```bash
# Generate ECDSA key
openssl ecparam -genkey -name prime256v1 -noout -out server.key
# Generate CSR
openssl req -new -key server.key -out server.csr \
  -subj "/C=US/ST=California/L=SF/O=MyOrg/CN=example.com"
```

### CSR with SAN (multiple domains)
```bash
openssl req -new -key server.key -out server.csr \
  -subj "/CN=example.com" \
  -addext "subjectAltName=DNS:example.com,DNS:www.example.com,DNS:api.example.com"
```

### Inspect CSR
```bash
openssl req -in server.csr -noout -text
# Verify CSR signature
openssl req -in server.csr -verify -noout
```

## Self-Signed Certificates

### Quick self-signed (dev/test only)
```bash
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem \
  -days 365 -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"
```

### Self-signed CA + server cert (internal PKI)
```bash
# 1. Create CA key and cert
openssl req -x509 -newkey rsa:4096 -nodes -keyout ca.key -out ca.crt \
  -days 3650 -subj "/CN=Internal CA"

# 2. Create server key and CSR
openssl req -new -newkey rsa:2048 -nodes -keyout server.key -out server.csr \
  -subj "/CN=myapp.internal"

# 3. Sign server cert with CA
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out server.crt -days 365 \
  -extfile <(printf "subjectAltName=DNS:myapp.internal,DNS:*.myapp.internal")
```

## Certificate Chain

```
Root CA (self-signed, in trust stores)
  └── Intermediate CA (signed by root)
        └── Leaf/Server cert (signed by intermediate)
```

- Server must send leaf + all intermediates. Root is optional (clients have it).
- Order in PEM bundle: leaf first, then intermediate(s), root last (if included).
- Verify chain:
```bash
openssl verify -CAfile ca-bundle.crt -untrusted intermediate.crt server.crt
```

## Let's Encrypt & Certbot

### Install certbot
```bash
sudo apt install certbot python3-certbot-nginx    # Ubuntu/Debian
sudo apt install python3-certbot-dns-cloudflare   # DNS plugin
```

### Issue certificate (HTTP-01 challenge)
```bash
sudo certbot certonly --nginx -d example.com -d www.example.com
sudo certbot certonly --standalone -d example.com  # standalone
```

### Wildcard certificate (DNS-01 challenge required)
```bash
sudo certbot certonly --dns-cloudflare \
  --dns-cloudflare-credentials /etc/letsencrypt/credentials/cloudflare.ini \
  -d '*.example.com' -d example.com
```

### Renewal automation
```bash
sudo certbot renew --dry-run  # test
0 0,12 * * * /usr/bin/certbot renew --quiet --deploy-hook "systemctl reload nginx"
```

### Certificate locations
```
/etc/letsencrypt/live/example.com/fullchain.pem  # cert + intermediate
/etc/letsencrypt/live/example.com/privkey.pem    # private key
/etc/letsencrypt/live/example.com/chain.pem      # intermediate only
/etc/letsencrypt/live/example.com/cert.pem       # leaf cert only
```

## OpenSSL Debugging

### Test TLS connection
```bash
# Basic connection test
openssl s_client -connect example.com:443 -servername example.com </dev/null

# Show full certificate chain
openssl s_client -connect example.com:443 -showcerts </dev/null 2>/dev/null

# Force TLS version
openssl s_client -connect example.com:443 -tls1_2
openssl s_client -connect example.com:443 -tls1_3
```

### Inspect certificate
```bash
# From file
openssl x509 -in cert.pem -noout -text
# Expiry dates only
openssl x509 -in cert.pem -noout -dates
# Subject and SANs
openssl x509 -in cert.pem -noout -subject -ext subjectAltName
# Serial and fingerprint
openssl x509 -in cert.pem -noout -serial -fingerprint -sha256
```

### Check remote certificate expiry
```bash
echo | openssl s_client -connect example.com:443 -servername example.com 2>/dev/null \
  | openssl x509 -noout -dates
# Check if expiring within 30 days (exit code 1 = expiring)
echo | openssl s_client -connect example.com:443 2>/dev/null \
  | openssl x509 -noout -checkend 2592000
```

### Verify certificate chain
```bash
openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt server.crt
# With intermediate
openssl verify -CAfile root.crt -untrusted intermediate.crt server.crt
```

### Match key to certificate
```bash
# These must produce identical output
openssl x509 -in cert.pem -noout -modulus | openssl md5
openssl rsa -in key.pem -noout -modulus | openssl md5
```

## Common Errors and Fixes

| Error | Cause | Fix |
|-------|-------|-----|
| `unable to verify the first certificate` | Missing intermediate(s) | Add intermediate certs to server config |
| `certificate has expired` | Cert past notAfter date | Renew certificate |
| `hostname mismatch` | CN/SAN doesn't match requested domain | Reissue with correct SAN entries |
| `self signed certificate` | Untrusted self-signed cert | Add CA to trust store or use public CA |
| `unable to get local issuer certificate` | Root CA not in trust store | Install CA bundle or add custom CA |
| `certificate is not yet valid` | System clock skewed or cert notBefore in future | Fix system time; check cert dates |
| `SSL routines:ssl3_get_record:wrong version number` | Connecting TLS to non-TLS port | Verify port supports TLS |
| `no peer certificate available` | Server not presenting cert | Check server TLS configuration |

## Mutual TLS (mTLS)

Both client and server authenticate via certificates.

### Generate client certificate
```bash
# Client key + CSR
openssl req -new -newkey rsa:2048 -nodes -keyout client.key -out client.csr \
  -subj "/CN=client-app/O=MyOrg"
# Sign with CA
openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out client.crt -days 365
```

### Nginx mTLS configuration
```nginx
server {
    listen 443 ssl;
    ssl_certificate /etc/ssl/server.crt;
    ssl_certificate_key /etc/ssl/server.key;
    ssl_client_certificate /etc/ssl/ca.crt;
    ssl_verify_client on;
    ssl_verify_depth 2;
}
```

### Test mTLS with curl
```bash
curl --cert client.crt --key client.key --cacert ca.crt https://secure.example.com
```

## OCSP Stapling

Server fetches and caches OCSP response, attaches to TLS handshake.

```nginx
# Nginx
ssl_stapling on;
ssl_stapling_verify on;
ssl_trusted_certificate /etc/ssl/chain.pem;
resolver 8.8.8.8 8.8.4.4 valid=300s;
```

```bash
# Test OCSP stapling
openssl s_client -connect example.com:443 -servername example.com -status </dev/null 2>/dev/null \
  | grep -A 5 "OCSP Response"
```

## HSTS (HTTP Strict Transport Security)

### Nginx header
```nginx
add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
```

### Apache header
```apache
Header always set Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"
```

- `max-age=63072000` = 2 years. Start with shorter values, increase after testing.
- `includeSubDomains`: all subdomains must support HTTPS before enabling.
- `preload`: submit to hstspreload.org. Removal is slow; only preload when fully committed.

## Certificate Transparency (CT)

All public CAs must log certificates to CT logs. Browsers require SCTs for trust.
```bash
curl -s "https://crt.sh/?q=%25.example.com&output=json" | jq '.[].common_name'
```

## Certificate Pinning

Pin SPKI hash to reject unexpected certs. **HPKP is deprecated**; use pinning only in mobile apps or API clients. Prefer CT monitoring + CAA records for web.
```bash
openssl x509 -in cert.pem -pubkey -noout | openssl pkey -pubin -outform DER | openssl dgst -sha256 -binary | base64
```

## CAA DNS Records

Restrict which CAs can issue certificates for your domain:
```dns
example.com. IN CAA 0 issue "letsencrypt.org"
example.com. IN CAA 0 issuewild "letsencrypt.org"
example.com. IN CAA 0 iodef "mailto:security@example.com"
```

## SNI (Server Name Indication)

TLS extension allowing multiple HTTPS sites on one IP. Client sends hostname in ClientHello (plaintext in TLS 1.2, encrypted in TLS 1.3 via ECH).
```bash
openssl s_client -connect shared-ip:443 -servername site1.example.com </dev/null
```

## ACME Protocol

Automated Certificate Management Environment (RFC 8555). Used by Let's Encrypt.

### Challenge types
| Challenge | Method | Wildcard Support | Firewall Friendly |
|-----------|--------|-----------------|-------------------|
| HTTP-01 | File at `/.well-known/acme-challenge/` on port 80 | No | Requires port 80 |
| DNS-01 | TXT record `_acme-challenge.domain` | Yes | Yes |
| TLS-ALPN-01 | Special TLS cert on port 443 | No | Requires port 443 |

### ACME clients (alternatives to certbot)
`acme.sh` (pure shell, no root), `lego` (Go binary), `dehydrated` (lightweight bash).

## cert-manager for Kubernetes

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.3/cert-manager.yaml
```

### ClusterIssuer with Let's Encrypt
```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: admin@example.com
    privateKeySecretRef:
      name: letsencrypt-prod-key
    solvers:
    - http01:
        ingress:
          class: nginx
```

### Ingress annotation (auto-issue)
```yaml
metadata:
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
spec:
  tls:
  - hosts: ["example.com"]
    secretName: example-com-tls
```

### Troubleshoot
```bash
kubectl get certificate,certificaterequest,order,challenge -A
kubectl describe certificate example-com-tls
kubectl logs -n cert-manager deploy/cert-manager -f
```

> Full cert-manager details (Certificate resources, DNS-01 solvers, etc.) in [references/acme-reference.md](references/acme-reference.md).

## Quick Reference: Nginx TLS Configuration

```nginx
server {
    listen 443 ssl http2;
    server_name example.com;
    ssl_certificate /etc/letsencrypt/live/example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/example.com/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;
    ssl_session_timeout 1d;
    ssl_session_cache shared:TLS:10m;
    ssl_session_tickets off;
    ssl_stapling on;
    ssl_stapling_verify on;
    ssl_trusted_certificate /etc/letsencrypt/live/example.com/chain.pem;
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
}
```

## Security Checklist

- [ ] TLS 1.3 enabled; TLS 1.2 only if legacy clients require it
- [ ] TLS 1.0 and 1.1 disabled
- [ ] Strong cipher suites only (AEAD, ECDHE key exchange)
- [ ] Certificate chain complete (leaf + intermediates)
- [ ] OCSP stapling enabled and verified
- [ ] HSTS header set with long max-age
- [ ] CAA DNS records restrict authorized CAs
- [ ] Certificate renewal automated and monitored
- [ ] Private keys stored with restrictive permissions (0600)
- [ ] CT log monitoring for unauthorized issuance
- [ ] ECDSA P-256 keys preferred over RSA for new deployments
- [ ] mTLS configured for service-to-service communication where needed

---

## Additional Resources

### Reference Guides (`references/`)

- **[Advanced TLS Patterns](references/advanced-patterns.md)** — mTLS setup patterns (API gateway, service mesh, Envoy), TLS 1.3 0-RTT replay protection, CT monitoring, DANE/TLSA, HPKP alternatives, short-lived certs with Vault, rotation strategies, wildcard vs SAN, cross-signing, revocation (CRL/OCSP/Stapling/Must-Staple).

- **[Troubleshooting Guide](references/troubleshooting.md)** — Chain verification failures, hostname mismatches, expired cert detection, mixed content, OCSP failures, cipher negotiation, TLS version incompatibility, SNI issues, trust store differences (OS/browser/Java/Python/Node/Go), OpenSSL debugging cookbook.

- **[ACME / Let's Encrypt Reference](references/acme-reference.md)** — ACME protocol flow, certbot DNS plugins (Cloudflare, Route 53, DigitalOcean, GCP), challenge comparison (HTTP-01/DNS-01/TLS-ALPN-01), rate limits, renewal hooks, cert-manager for K8s, acme.sh, Caddy auto-HTTPS.

### Scripts (`scripts/`)

Executable shell scripts for certificate operations:

- **[cert-check.sh](scripts/cert-check.sh)** — Certificate inspector that checks expiry, chain validity, SANs, key strength, OCSP status, TLS version support, and CT logs for any domain or local cert file.
  ```bash
  ./scripts/cert-check.sh example.com
  ./scripts/cert-check.sh -f /path/to/cert.pem
  ```

- **[self-signed-ca.sh](scripts/self-signed-ca.sh)** — Creates a complete CA hierarchy: root CA, intermediate CA, server certificate with SANs, client certificate for mTLS, chain bundles, and PKCS#12 files.
  ```bash
  ./scripts/self-signed-ca.sh ./pki myapp.internal
  ```

- **[cert-renew-monitor.sh](scripts/cert-renew-monitor.sh)** — Monitors certificates for expiration with configurable warning/critical thresholds, Slack alerts, JSON output, and optional certbot auto-renewal.
  ```bash
  ./scripts/cert-renew-monitor.sh -f domains.txt -w 30 -c 7 --slack
  ```

### Assets (`assets/`)

Copy-paste ready configuration templates:

- **[openssl.cnf](assets/openssl.cnf)** — Comprehensive OpenSSL configuration template covering CA operations, CSR generation, server/client/mTLS certificate extensions, SANs, and OCSP signing.

- **[certbot-hooks/](assets/certbot-hooks/)** — Post-renewal deploy hooks for Nginx, Apache, and HAProxy. Each tests config before reloading and logs results.

- **[cipher-suites.md](assets/cipher-suites.md)** — Recommended cipher suite configurations for Modern (TLS 1.3 only), Intermediate (TLS 1.2+1.3, recommended), and Old (legacy) compatibility profiles, with complete configs for Nginx, Apache, HAProxy, and Caddy.
