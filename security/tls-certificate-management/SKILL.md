---
name: tls-certificate-management
description:
  positive: "Use when user manages TLS/SSL certificates, asks about Let's Encrypt, cert-manager, ACME, mTLS, certificate chains, CSR generation, certificate rotation, or debugging TLS errors."
  negative: "Do NOT use for SSH keys (use ssh-configuration skill), JWT tokens (use jwt-authentication skill), or general encryption without certificate context."
---

# TLS Certificate Management

## TLS Fundamentals

### The TLS Handshake (TLS 1.3)
1. Client sends ClientHello with supported cipher suites and key share.
2. Server responds with ServerHello, key share, and certificate.
3. Server sends CertificateVerify (signature proving key ownership).
4. Client verifies certificate chain against its trust store.
5. Both derive session keys. Handshake completes in 1-RTT (0-RTT for resumption).

### Certificate Chain and CA Hierarchy
- **Root CA** → **Intermediate CA** → **End-entity (leaf) certificate**.
- Browsers and OS trust stores contain root CA certificates.
- Servers must send the full chain (leaf + intermediates), never the root.
- Verify a chain:
```bash
openssl verify -CAfile root.pem -untrusted intermediate.pem server.pem
```

### Trust Stores
- Linux: `/etc/ssl/certs/` (Debian) or `/etc/pki/tls/certs/` (RHEL). Add custom CA with `update-ca-certificates` or `update-ca-trust`.
```bash
cp custom-ca.crt /usr/local/share/ca-certificates/ && update-ca-certificates  # Debian/Ubuntu
cp custom-ca.crt /etc/pki/ca-trust/source/anchors/ && update-ca-trust         # RHEL/CentOS
```

## Certificate Types

| Type | Validation | Use Case |
|------|-----------|----------|
| DV (Domain Validation) | Domain ownership only | Most websites, APIs |
| OV (Organization Validation) | Domain + org identity | Business sites |
| EV (Extended Validation) | Domain + org + legal | Financial, regulated |
| Wildcard (`*.example.com`) | Covers all subdomains at one level | Multi-subdomain deployments |
| SAN (Subject Alternative Name) | Multiple specific domains in one cert | Multi-domain services |
| Self-signed | No CA validation | Development, testing only |
| Internal CA | Private CA signs certs | Service-to-service, mTLS |

## Let's Encrypt and ACME Protocol

### ACME Overview
ACME (RFC 8555) automates certificate issuance. The client proves domain control via challenges, then the CA issues a signed certificate.

### Challenge Types

**HTTP-01** — Place a token at `http://<domain>/.well-known/acme-challenge/<token>`:
- Requires port 80 open and publicly reachable.
- Cannot issue wildcard certificates.
- Simplest for single-server setups.

**DNS-01** — Create a `_acme-challenge.<domain>` TXT record:
- Required for wildcard certificates.
- Works for internal/non-public servers.
- Needs DNS provider API access for automation.

### Certbot Commands
```bash
# Install
sudo apt install certbot python3-certbot-nginx

# Obtain cert (HTTP-01, nginx)
sudo certbot --nginx -d example.com -d www.example.com

# Obtain cert (DNS-01, wildcard)
sudo certbot certonly --dns-cloudflare \
  --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
  -d "*.example.com" -d example.com

# Obtain cert (standalone, no web server)
sudo certbot certonly --standalone -d example.com

# Renew all certificates
sudo certbot renew --dry-run

# Revoke a certificate
sudo certbot revoke --cert-path /etc/letsencrypt/live/example.com/cert.pem
```

### Rate Limits (2025)
- **New Orders**: 300 per account per 3 hours.
- **Certificates per Registered Domain**: 50 per week.
- **Duplicate Certificates**: 5 per week per exact SAN set.
- **Failed Validations**: 5 per account per hostname per hour.
- Use staging endpoint for testing: `https://acme-staging-v02.api.letsencrypt.org/directory`.
- ARI (ACME Renewal Information) renewals within the suggested window do not count toward some limits.

### Short-Lived Certificates (2025)
Let's Encrypt now offers 6-day certificates via the `shortlived` ACME profile. These omit OCSP/CRL URLs since rapid expiry replaces revocation. Renew every 2–3 days. Requires ARI-capable ACME client.

## cert-manager (Kubernetes)

### Install
```bash
helm repo add jetstack https://charts.jetstack.io --force-update
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true
```

### ClusterIssuer (Let's Encrypt, HTTP-01)
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
      name: letsencrypt-prod-account-key
    solvers:
    - http01:
        ingress:
          class: nginx
```

### ClusterIssuer (DNS-01, Cloudflare)
```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-dns
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: admin@example.com
    privateKeySecretRef:
      name: letsencrypt-dns-account-key
    solvers:
    - dns01:
        cloudflare:
          apiTokenSecretRef: { name: cloudflare-api-token, key: api-token }
```

### Certificate Resource
```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: app-tls
  namespace: default
spec:
  secretName: app-tls-secret
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
  - app.example.com
  - api.example.com
  duration: 2160h    # 90 days
  renewBefore: 360h  # 15 days before expiry
```

### Ingress Annotation (auto-request)
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  tls:
  - hosts:
    - app.example.com
    secretName: app-tls-secret
```

### Troubleshooting cert-manager
```bash
kubectl get certificates -A
kubectl describe certificate app-tls
kubectl get certificaterequest -A
kubectl describe challenge -A
kubectl logs -n cert-manager deploy/cert-manager
```

## OpenSSL Commands

### Generate Keys
```bash
# RSA 2048-bit
openssl genpkey -algorithm RSA -out server.key -pkeyopt rsa_keygen_bits:2048

# ECDSA P-256
openssl ecparam -genkey -name prime256v1 -noout -out server.key

# Ed25519
openssl genpkey -algorithm Ed25519 -out server.key
```

### Generate CSR
```bash
openssl req -new -key server.key -out server.csr \
  -subj "/C=US/ST=CA/L=SF/O=MyOrg/CN=app.example.com"

# CSR with SANs — use config file
openssl req -new -key server.key -out server.csr -config san.cnf
```

SAN config (`san.cnf`):
```ini
[req]
distinguished_name = req_dn
req_extensions = v3_req
prompt = no
[req_dn]
CN = app.example.com
[v3_req]
subjectAltName = DNS:app.example.com,DNS:api.example.com,IP:10.0.0.1
```

### Self-Signed Certificate
```bash
openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem \
  -sha256 -days 365 -nodes -subj "/CN=localhost"
```

### Sign CSR with a CA
```bash
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key \
  -CAcreateserial -out server.crt -days 365 -sha256 \
  -extfile san.cnf -extensions v3_req
```

### Inspect and Verify
```bash
openssl x509 -in cert.pem -noout -text                         # Full details
openssl x509 -in cert.pem -noout -enddate                      # Expiry date
openssl x509 -in cert.pem -noout -ext subjectAltName           # SANs
openssl req -in server.csr -noout -text                         # View CSR
openssl x509 -in cert.pem -noout -modulus | openssl md5         # Check key matches cert
openssl rsa -in key.pem -noout -modulus | openssl md5           # (compare hashes)
openssl verify -CAfile root.pem -untrusted intermediate.pem server.crt  # Verify chain
```

## Certificate Formats and Conversion

| Format | Extension | Encoding | Contains |
|--------|-----------|----------|----------|
| PEM | .pem, .crt, .cer | Base64 | Cert and/or key, chain |
| DER | .der, .cer | Binary | Single cert |
| PKCS#12 | .p12, .pfx | Binary | Cert + key + chain |
| JKS | .jks | Binary | Java keystore |

### Conversions
```bash
# PEM → DER
openssl x509 -in cert.pem -outform DER -out cert.der

# DER → PEM
openssl x509 -in cert.der -inform DER -out cert.pem

# PEM cert+key → PKCS#12
openssl pkcs12 -export -out cert.p12 -inkey key.pem -in cert.pem -certfile chain.pem

# PKCS#12 → PEM
openssl pkcs12 -in cert.p12 -out cert.pem -nodes

# PEM → JKS (requires keytool)
keytool -importkeystore -srckeystore cert.p12 -srcstoretype PKCS12 \
  -destkeystore keystore.jks -deststoretype JKS
```

## Mutual TLS (mTLS)

Both client and server present certificates. Server verifies client cert against a trusted CA. Used for zero-trust, service-to-service auth, and API security.

### Generate Client Certificate
```bash
openssl genpkey -algorithm RSA -out client.key -pkeyopt rsa_keygen_bits:2048
openssl req -new -key client.key -out client.csr -subj "/CN=service-a"
openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key \
  -CAcreateserial -out client.crt -days 90 -sha256
```

### Nginx mTLS Configuration
```nginx
server {
    listen 443 ssl;
    ssl_certificate     /etc/nginx/tls/server.crt;
    ssl_certificate_key /etc/nginx/tls/server.key;
    ssl_client_certificate /etc/nginx/tls/ca.crt;  # CA that signed client certs
    ssl_verify_client on;
    ssl_verify_depth 2;
}
```

### Test mTLS Connection
```bash
curl --cert client.crt --key client.key --cacert ca.crt https://api.example.com/
```

### Service Mesh mTLS
Istio and Linkerd automate mTLS between pods. Istio PeerAuthentication:
```yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: production
spec:
  mtls:
    mode: STRICT
```

## Certificate Rotation and Renewal

### Automated Renewal Strategy
- Renew at 2/3 of certificate lifetime (e.g., 60 days for 90-day certs).
- Use cron or systemd timers for certbot: `systemctl enable certbot.timer`.
- cert-manager handles renewal automatically via `renewBefore`.
- For short-lived certs (6-day), renew every 2–3 days.

### Zero-Downtime Rotation
1. Issue new certificate before old one expires.
2. Deploy new cert alongside old one.
3. Reload (not restart) the server: `nginx -s reload` or `systemctl reload nginx`.
4. Verify new cert is served: `openssl s_client -connect host:443`.

### OCSP Stapling
Server fetches OCSP response and staples it to the TLS handshake, reducing client-side latency:
```nginx
ssl_stapling on;
ssl_stapling_verify on;
ssl_trusted_certificate /etc/nginx/tls/chain.pem;
resolver 8.8.8.8;
```

### CRL (Certificate Revocation List)
```bash
# Generate CRL
openssl ca -gencrl -out crl.pem -config openssl.cnf

# Check CRL
openssl crl -in crl.pem -noout -text
```

## Cloud Provider Certificates

### AWS Certificate Manager (ACM)
- Free public certificates for ALB, CloudFront, API Gateway.
- Auto-renewed. Cannot export private keys.
- Use DNS validation for automation.

### Google Cloud Certificate Manager
- Managed certs for GCLB, supports DNS authorization.
- Certificate Map resources for multi-domain.

### Cloudflare Origin CA
- 15-year certs for origin-to-Cloudflare only.
- Not trusted by browsers directly — use behind Cloudflare proxy.

## Web Server TLS Configuration

### Nginx
```nginx
server {
    listen 443 ssl http2;
    server_name example.com;

    ssl_certificate     /etc/letsencrypt/live/example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/example.com/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;

    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

    # HSTS
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;

    # OCSP Stapling
    ssl_stapling on;
    ssl_stapling_verify on;
    ssl_trusted_certificate /etc/letsencrypt/live/example.com/chain.pem;
}
```

### Apache
```apache
<VirtualHost *:443>
    SSLEngine on
    SSLCertificateFile    /etc/letsencrypt/live/example.com/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/example.com/privkey.pem
    SSLProtocol all -SSLv3 -TLSv1 -TLSv1.1
    Header always set Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"
</VirtualHost>
```

### Caddy
Caddy handles TLS automatically via built-in ACME. No config needed for basic HTTPS:
```caddyfile
example.com {
    reverse_proxy localhost:8080
    tls admin@example.com  # Optional: explicit email for ACME
}
```

## Debugging TLS

### Test Remote Server
```bash
openssl s_client -connect example.com:443 -servername example.com             # Full test
openssl s_client -connect example.com:443 -showcerts </dev/null               # Show chain
echo | openssl s_client -connect example.com:443 2>/dev/null | openssl x509 -noout -dates  # Expiry
openssl s_client -connect example.com:443 -tls1_3                             # Test TLS 1.3
openssl s_client -connect example.com:443 -status </dev/null | grep "OCSP"    # OCSP stapling
openssl s_client -connect example.com:443 -cert client.crt -key client.key    # mTLS test
```

### Common Errors and Fixes
| Error | Cause | Fix |
|-------|-------|-----|
| `certificate verify failed` | Missing intermediate or untrusted CA | Send full chain; add CA to trust store |
| `certificate has expired` | Cert past `notAfter` date | Renew immediately; check automation |
| `hostname mismatch` | CN/SAN doesn't match requested domain | Reissue with correct SAN entries |
| `unable to get local issuer certificate` | Missing root/intermediate in trust store | Install CA cert in system trust store |
| `self-signed certificate` | No CA signature | Use a proper CA or add self-signed to trust |
| `SSL_ERROR_RX_RECORD_TOO_LONG` | TLS on non-TLS port or plaintext response | Check port configuration; ensure SSL is enabled |
| `handshake failure` | Protocol/cipher mismatch | Align server and client TLS versions/ciphers |

### Expiry Monitoring
```bash
DOMAIN="example.com"
DAYS=$(echo | openssl s_client -connect "$DOMAIN:443" -servername "$DOMAIN" 2>/dev/null \
  | openssl x509 -noout -enddate | cut -d= -f2 \
  | xargs -I{} bash -c 'echo $(( ($(date -d "{}" +%s) - $(date +%s)) / 86400 ))')
echo "$DOMAIN expires in $DAYS days"
```

## Internal PKI

### step-ca (Smallstep)
```bash
# Initialize CA
step ca init --name "Internal CA" --dns ca.internal --address :8443

# Issue certificate
step ca certificate "service.internal" service.crt service.key

# Auto-renew with systemd
step ca renew --daemon service.crt service.key
```

### cfssl
```bash
# Generate CA
cfssl gencert -initca ca-csr.json | cfssljson -bare ca

# Sign a certificate
cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=config.json \
  -profile=server server-csr.json | cfssljson -bare server
```

### Vault PKI
```bash
vault secrets enable pki
vault secrets tune -max-lease-ttl=87600h pki
vault write pki/root/generate/internal common_name="Root CA" ttl=87600h

vault secrets enable -path=pki_int pki
vault write pki_int/intermediate/generate/internal common_name="Intermediate CA"
vault write pki_int/roles/service \
  allowed_domains="internal.example.com" allow_subdomains=true max_ttl="72h"
vault write pki_int/issue/service common_name="app.internal.example.com" ttl="24h"
```

## Certificate Transparency (CT)

- All publicly trusted CAs must submit certificates to CT logs.
- Browsers require Signed Certificate Timestamps (SCTs) — embedded in cert, TLS extension, or OCSP response.
- Monitor CT logs for unauthorized issuance: use `crt.sh`, `certspotter`, or Google Transparency Report.
- Let's Encrypt transitioning CT logs to Static CT API (Sunlight) by 2026.
```bash
curl -s "https://crt.sh/?q=%.example.com&output=json" | jq '.[0:5] | .[] | {id, name_value, not_after}'
```

## Anti-Patterns

- **Expired certificates in production.** Automate renewal. Monitor expiry with alerts at 30, 14, and 7 days.
- **Self-signed certificates in production.** Use Let's Encrypt (free) or internal CA. Self-signed disables trust verification.
- **Missing intermediate certificates.** Always serve the full chain. Test with `openssl s_client`.
- **Weak cipher suites or TLS versions.** Disable TLS 1.0/1.1 and weak ciphers. Use TLS 1.2+ only.
- **Reusing private keys across renewals.** Generate fresh keys on each renewal for forward secrecy.
- **Wildcard certificates shared across trust boundaries.** Compromising one service exposes all subdomains.
- **Ignoring certificate transparency.** Monitor CT logs for rogue issuance of your domains.
- **Manual certificate management.** Automate everything — ACME, cert-manager, or internal PKI with auto-renewal.
- **Storing private keys unencrypted.** Use file permissions (600), Kubernetes Secrets, or a vault.
- **Disabling TLS verification in code.** Never use `verify=False` or `NODE_TLS_REJECT_UNAUTHORIZED=0` in production.
