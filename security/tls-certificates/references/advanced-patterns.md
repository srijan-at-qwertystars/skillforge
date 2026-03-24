# Advanced TLS Patterns

## Table of Contents

- [Mutual TLS (mTLS) Setup Patterns](#mutual-tls-mtls-setup-patterns)
  - [API Gateway mTLS](#api-gateway-mtls)
  - [Service Mesh mTLS](#service-mesh-mtls)
  - [Client Certificate Authentication Flow](#client-certificate-authentication-flow)
  - [mTLS with Envoy Proxy](#mtls-with-envoy-proxy)
  - [mTLS with NGINX Ingress](#mtls-with-nginx-ingress)
- [TLS 1.3 0-RTT (Early Data)](#tls-13-0-rtt-early-data)
  - [How 0-RTT Works](#how-0-rtt-works)
  - [Replay Attack Risks](#replay-attack-risks)
  - [Server Configuration](#server-configuration)
- [Certificate Transparency Monitoring](#certificate-transparency-monitoring)
  - [How CT Works](#how-ct-works)
  - [Monitoring Tools](#monitoring-tools)
  - [Automated CT Monitoring Script](#automated-ct-monitoring-script)
- [DANE/TLSA Records](#danetlsa-records)
  - [TLSA Record Format](#tlsa-record-format)
  - [Publishing TLSA Records](#publishing-tlsa-records)
  - [DANE for SMTP](#dane-for-smtp)
- [HPKP Deprecation and Alternatives](#hpkp-deprecation-and-alternatives)
  - [Why HPKP Was Deprecated](#why-hpkp-was-deprecated)
  - [Modern Alternatives](#modern-alternatives)
- [Short-Lived Certificates](#short-lived-certificates)
  - [Benefits](#benefits)
  - [Implementation Strategies](#implementation-strategies)
  - [HashiCorp Vault PKI](#hashicorp-vault-pki)
- [Automated Rotation Strategies](#automated-rotation-strategies)
  - [Zero-Downtime Rotation](#zero-downtime-rotation)
  - [Rotation with cert-manager](#rotation-with-cert-manager)
  - [Rotation Monitoring](#rotation-monitoring)
- [Wildcard vs SAN Tradeoffs](#wildcard-vs-san-tradeoffs)
- [Cross-Signing Chains](#cross-signing-chains)
  - [How Cross-Signing Works](#how-cross-signing-works)
  - [Let's Encrypt Cross-Sign Example](#lets-encrypt-cross-sign-example)
- [Certificate Revocation: CRL vs OCSP](#certificate-revocation-crl-vs-ocsp)
  - [CRL (Certificate Revocation Lists)](#crl-certificate-revocation-lists)
  - [OCSP (Online Certificate Status Protocol)](#ocsp-online-certificate-status-protocol)
  - [OCSP Stapling](#ocsp-stapling)
  - [OCSP Must-Staple](#ocsp-must-staple)
  - [Comparison Matrix](#comparison-matrix)

---

## Mutual TLS (mTLS) Setup Patterns

### API Gateway mTLS

Enforce client certificate authentication at the gateway level so backend services don't need individual TLS termination.

```nginx
# NGINX API Gateway with mTLS
upstream backend_api {
    server 10.0.1.10:8080;
    server 10.0.1.11:8080;
}

server {
    listen 443 ssl;
    server_name api.example.com;

    # Server identity
    ssl_certificate     /etc/ssl/api/server.crt;
    ssl_certificate_key /etc/ssl/api/server.key;

    # Client certificate verification
    ssl_client_certificate /etc/ssl/api/trusted-clients-ca.crt;
    ssl_verify_client on;
    ssl_verify_depth 3;

    # Pass client identity to backend
    proxy_set_header X-Client-DN     $ssl_client_s_dn;
    proxy_set_header X-Client-Serial $ssl_client_serial;
    proxy_set_header X-Client-Verify $ssl_client_verify;

    # Optional: require specific client cert fields
    if ($ssl_client_s_dn !~ "O=TrustedOrg") {
        return 403;
    }

    location / {
        proxy_pass http://backend_api;
    }
}
```

### Service Mesh mTLS

Istio automatic mTLS — all service-to-service traffic encrypted without app changes:

```yaml
# Istio PeerAuthentication — enforce mTLS cluster-wide
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: istio-system
spec:
  mtls:
    mode: STRICT  # STRICT = require mTLS, PERMISSIVE = allow both

---
# Istio DestinationRule — enforce mTLS for specific service
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: payments-mtls
spec:
  host: payments.default.svc.cluster.local
  trafficPolicy:
    tls:
      mode: ISTIO_MUTUAL
```

Linkerd automatic mTLS:
```bash
# Inject Linkerd sidecar — mTLS is automatic
linkerd inject deployment.yaml | kubectl apply -f -
# Verify mTLS is active
linkerd viz edges deployment -n default
```

### Client Certificate Authentication Flow

```
Client                              Server
  |                                   |
  |--- ClientHello ------------------>|
  |<-- ServerHello + Certificate -----|
  |<-- CertificateRequest -----------|  (Server requests client cert)
  |--- Certificate ------------------>|  (Client sends its cert)
  |--- CertificateVerify ------------>|  (Client proves key ownership)
  |--- Finished --------------------->|
  |<-- Finished ----------------------|
  |                                   |
  |  Bidirectional authenticated TLS  |
```

### mTLS with Envoy Proxy

```yaml
# Envoy listener with downstream mTLS
static_resources:
  listeners:
  - name: mtls_listener
    address:
      socket_address: { address: 0.0.0.0, port_value: 8443 }
    filter_chains:
    - transport_socket:
        name: envoy.transport_sockets.tls
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.DownstreamTlsContext
          require_client_certificate: true
          common_tls_context:
            tls_certificates:
            - certificate_chain: { filename: "/certs/server.crt" }
              private_key: { filename: "/certs/server.key" }
            validation_context:
              trusted_ca: { filename: "/certs/client-ca.crt" }
```

### mTLS with NGINX Ingress

```yaml
# Kubernetes NGINX Ingress with client cert auth
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: mtls-ingress
  annotations:
    nginx.ingress.kubernetes.io/auth-tls-verify-client: "on"
    nginx.ingress.kubernetes.io/auth-tls-secret: "default/ca-secret"
    nginx.ingress.kubernetes.io/auth-tls-verify-depth: "2"
    nginx.ingress.kubernetes.io/auth-tls-pass-certificate-to-upstream: "true"
spec:
  tls:
  - hosts:
    - api.example.com
    secretName: api-tls
  rules:
  - host: api.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: api-service
            port:
              number: 80
```

---

## TLS 1.3 0-RTT (Early Data)

### How 0-RTT Works

After a full TLS 1.3 handshake, the server issues a NewSessionTicket containing a PSK (Pre-Shared Key). On reconnection, the client encrypts application data using the PSK and sends it alongside ClientHello — saving one round trip.

```
Full handshake (1-RTT):        Resumption (0-RTT):
Client      Server             Client        Server
  |--Hello-->|                   |--Hello+Data-->|  ← early data
  |<-Hello---|                   |<--Hello-------|
  |<-Finish--|                   |<--Finish------|
  |--Finish->|                   |--Finish------>|
  |  DATA    |                   |    DATA       |
```

### Replay Attack Risks

0-RTT data is **not forward-secret** and is **replayable**. An attacker who captures the initial 0-RTT flight can replay it to the server.

**Safe for 0-RTT:**
- Idempotent GET requests
- Read-only API calls
- Static content fetches

**Unsafe for 0-RTT:**
- POST/PUT/DELETE requests
- Payment processing
- State-changing operations
- Any non-idempotent action

### Server Configuration

```nginx
# NGINX: enable 0-RTT (with caution)
ssl_early_data on;
proxy_set_header Early-Data $ssl_early_data;  # pass to backend

# Backend should check Early-Data header and reject sensitive operations
```

```
# HAProxy: disable 0-RTT (recommended for APIs)
ssl-default-bind-options no-tls-tickets
# Or selectively allow:
ssl-default-bind-options allow-0rtt
```

Application-level protection:
```python
# Flask/Django middleware to reject 0-RTT for non-idempotent requests
def reject_early_data(request):
    if request.headers.get('Early-Data') == '1':
        if request.method not in ('GET', 'HEAD', 'OPTIONS'):
            return HttpResponse(status=425)  # 425 Too Early
```

---

## Certificate Transparency Monitoring

### How CT Works

1. CA submits pre-certificate to CT logs before issuance
2. Log returns a Signed Certificate Timestamp (SCT)
3. SCT is embedded in the certificate or delivered via TLS extension / OCSP
4. Browsers verify SCT presence (Chrome requires 2-3 SCTs)
5. CT logs are append-only and publicly auditable

### Monitoring Tools

| Tool | Type | Cost |
|------|------|------|
| [crt.sh](https://crt.sh) | Web search / API | Free |
| [Certspotter](https://sslmate.com/certspotter/) | Monitoring service | Free tier |
| [Facebook CT Monitor](https://developers.facebook.com/tools/ct/) | Webhook alerts | Free |
| Google Certificate Transparency | Log viewer | Free |
| SSLMate Cert Spotter CLI | CLI tool | Free/Paid |

### Automated CT Monitoring Script

```bash
#!/bin/bash
# Monitor CT logs for new certificates on your domains
DOMAIN="example.com"
KNOWN_CERTS="/var/lib/ct-monitor/known-certs.txt"
touch "$KNOWN_CERTS"

# Query crt.sh for recent certificates
NEW_CERTS=$(curl -s "https://crt.sh/?q=%25.${DOMAIN}&output=json" | \
  jq -r '.[] | "\(.id) \(.common_name) \(.not_before) \(.issuer_name)"')

while IFS= read -r line; do
    CERT_ID=$(echo "$line" | awk '{print $1}')
    if ! grep -q "^${CERT_ID}$" "$KNOWN_CERTS"; then
        echo "[ALERT] New certificate detected: $line"
        echo "$CERT_ID" >> "$KNOWN_CERTS"
        # Send alert via webhook, email, etc.
    fi
done <<< "$NEW_CERTS"
```

---

## DANE/TLSA Records

### TLSA Record Format

```
_port._protocol.hostname. IN TLSA usage selector matching-type certificate-data
```

**Usage field:**
| Value | Name | Meaning |
|-------|------|---------|
| 0 | PKIX-TA | CA constraint (must chain to specified CA) |
| 1 | PKIX-EE | End entity constraint (must match leaf cert) |
| 2 | DANE-TA | Trust anchor (DNSSEC-validated CA, bypasses WebPKI) |
| 3 | DANE-EE | Domain-issued cert (self-signed OK, DNSSEC-validated) |

**Selector:** 0 = full certificate, 1 = SubjectPublicKeyInfo only
**Matching type:** 0 = exact match, 1 = SHA-256, 2 = SHA-512

### Publishing TLSA Records

```bash
# Generate TLSA record data from certificate
openssl x509 -in server.crt -outform DER | sha256sum | awk '{print $1}'

# Example DNS record (usage=3, selector=1, matching=1 = DANE-EE, SPKI, SHA-256)
# _443._tcp.mail.example.com. IN TLSA 3 1 1 <sha256-hex>

# Using openssl to generate the SPKI hash directly
openssl x509 -in server.crt -noout -pubkey | \
  openssl pkey -pubin -outform DER | \
  sha256sum | awk '{print $1}'
```

**Prerequisites:**
1. Domain must have DNSSEC enabled and properly configured
2. DNS provider must support TLSA record type
3. Verify with: `dig +dnssec TLSA _443._tcp.mail.example.com`

### DANE for SMTP

DANE is most widely adopted for email (SMTP). Postfix configuration:

```
# /etc/postfix/main.cf
smtp_tls_security_level = dane
smtp_dns_support_level = dnssec
smtp_tls_loglevel = 1
```

---

## HPKP Deprecation and Alternatives

### Why HPKP Was Deprecated

HTTP Public Key Pinning (HPKP) was removed from browsers (Chrome 72, Firefox 72) due to:

1. **Bricking risk**: Misconfigured pins could permanently lock users out of a site
2. **Ransom attacks**: Attackers who compromised a site could set hostile pins
3. **Operational complexity**: Key rotation required careful pin management
4. **Low adoption**: Few sites implemented it correctly

### Modern Alternatives

| Alternative | Protection | Effort |
|-------------|-----------|--------|
| **CT monitoring** | Detects unauthorized certificates | Low |
| **CAA records** | Restricts which CAs can issue | Low |
| **HSTS + preload** | Forces HTTPS | Low |
| **Expect-CT header** | Enforces CT compliance | Low (deprecated in favor of built-in CT) |
| **Short-lived certs** | Limits exposure window | Medium |
| **App-level pinning** | Mobile/API client pinning | High |

**Recommended stack:** CAA records + CT monitoring + HSTS preload

```dns
; CAA records — only Let's Encrypt can issue
example.com. IN CAA 0 issue "letsencrypt.org"
example.com. IN CAA 0 issuewild "letsencrypt.org"
example.com. IN CAA 0 iodef "mailto:security@example.com"
```

**Mobile app pinning** (still valid for API clients):
```kotlin
// Android OkHttp certificate pinning
val client = OkHttpClient.Builder()
    .certificatePinner(CertificatePinner.Builder()
        .add("api.example.com", "sha256/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=")
        .add("api.example.com", "sha256/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=") // backup
        .build())
    .build()
```

---

## Short-Lived Certificates

### Benefits

- **Revocation becomes moot** — cert expires before CRL/OCSP propagation would matter
- **Reduced blast radius** — compromised cert is only valid for hours/days
- **Forces automation** — no manual renewal means fewer human errors
- **Simpler auditing** — clear issuance/expiration timeline

### Implementation Strategies

| Strategy | Validity | Use Case |
|----------|----------|----------|
| Let's Encrypt (90 days) | 90 days | Public-facing web |
| HashiCorp Vault PKI | Minutes to days | Internal services |
| cert-manager + Vault | Configurable | Kubernetes workloads |
| SPIFFE/SPIRE | Hours | Service identity |
| Istio Citadel | 24 hours default | Service mesh |

### HashiCorp Vault PKI

```bash
# Enable PKI secrets engine
vault secrets enable pki
vault secrets tune -max-lease-ttl=8760h pki

# Generate root CA
vault write pki/root/generate/internal \
    common_name="Vault Root CA" \
    ttl=87600h

# Enable intermediate PKI
vault secrets enable -path=pki_int pki
vault write pki_int/intermediate/generate/internal \
    common_name="Vault Intermediate CA"

# Create role for short-lived certs
vault write pki_int/roles/short-lived \
    allowed_domains="internal.example.com" \
    allow_subdomains=true \
    max_ttl="24h" \
    ttl="1h"        # 1-hour certificates

# Issue certificate
vault write pki_int/issue/short-lived \
    common_name="myservice.internal.example.com" \
    ttl="1h"
```

---

## Automated Rotation Strategies

### Zero-Downtime Rotation

**NGINX graceful reload:**
```bash
# Deploy new cert, then reload without dropping connections
cp new-cert.pem /etc/ssl/server.crt
cp new-key.pem /etc/ssl/server.key
nginx -t && nginx -s reload  # zero-downtime reload
```

**HAProxy seamless reload:**
```bash
# HAProxy 2.x supports hitless reload
cp new-combined.pem /etc/haproxy/certs/site.pem
echo "set ssl cert /etc/haproxy/certs/site.pem" | socat stdio /var/run/haproxy/admin.sock
echo "commit ssl cert /etc/haproxy/certs/site.pem" | socat stdio /var/run/haproxy/admin.sock
```

### Rotation with cert-manager

```yaml
# cert-manager Certificate with rotation settings
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: api-cert
spec:
  secretName: api-tls
  duration: 2160h      # 90 days
  renewBefore: 720h    # Renew 30 days before expiry
  privateKey:
    rotationPolicy: Always  # Generate new key on each renewal
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
  - api.example.com
```

### Rotation Monitoring

```bash
# Check cert-manager certificate status
kubectl get certificate -A -o custom-columns=\
NAME:.metadata.name,\
READY:.status.conditions[0].status,\
EXPIRY:.status.notAfter,\
RENEWAL:.status.renewalTime
```

---

## Wildcard vs SAN Tradeoffs

| Factor | Wildcard (`*.example.com`) | SAN (Multi-Domain) |
|--------|---------------------------|---------------------|
| **Coverage** | All single-level subdomains | Only explicitly listed domains |
| **Multi-domain** | No (single domain only) | Yes (any combination) |
| **Security blast radius** | High — all subdomains exposed if key leaks | Limited to listed names |
| **Adding new names** | Automatic for subdomains | Requires reissuance |
| **Nested subdomains** | Not covered (`*.*.example.com` invalid) | Must be listed explicitly |
| **Apex domain** | Not covered (need separate SAN entry) | Included if listed |
| **Compliance (PCI-DSS)** | Sometimes restricted | Generally preferred |
| **Cost** | Single cert | May cost per SAN entry |
| **Best for** | Dynamic subdomains, dev/staging | Multi-brand, controlled environments |

**Common hybrid:** Wildcard + SAN in one cert:
```bash
certbot certonly --dns-cloudflare \
  -d 'example.com' \
  -d '*.example.com' \
  -d 'example.org' \
  -d '*.example.org'
```

---

## Cross-Signing Chains

### How Cross-Signing Works

Cross-signing allows a new CA to be trusted by clients that only recognize an older root CA. The new CA's intermediate is signed by both the new root AND the old root.

```
Old Root CA (widely trusted)        New Root CA (not yet in all stores)
     |                                    |
     └── Cross-signed Intermediate ──────┘
              |
              └── Leaf Certificate
```

Clients with the old root follow: Leaf → Cross-signed Intermediate → Old Root
Clients with the new root follow: Leaf → Intermediate → New Root

### Let's Encrypt Cross-Sign Example

Let's Encrypt transitioned from DST Root CA X3 (IdenTrust) to ISRG Root X1:

```
ISRG Root X1 (new, in modern trust stores)
  └── Let's Encrypt R3 (current intermediate)
        └── Your certificate

DST Root CA X3 (old, expired Sep 2021)
  └── Let's Encrypt R3 (cross-signed version)
        └── Your certificate
```

Verify cross-sign chain:
```bash
# Show which chain a server presents
openssl s_client -connect example.com:443 -showcerts 2>/dev/null | \
  grep -E "s:|i:" | head -10
```

---

## Certificate Revocation: CRL vs OCSP

### CRL (Certificate Revocation Lists)

The CA periodically publishes a signed list of revoked certificate serial numbers.

```bash
# Find CRL distribution point in a certificate
openssl x509 -in cert.pem -noout -text | grep -A2 "CRL Distribution"

# Download and inspect CRL
curl -s http://crl.example.com/ca.crl | openssl crl -inform DER -noout -text

# Check if a specific cert is revoked
openssl crl -in ca.crl -noout -text | grep -i "serial"
```

**Limitations:** Large file downloads, update delays (hours to days), no real-time status.

### OCSP (Online Certificate Status Protocol)

Real-time revocation checking by querying the CA's OCSP responder.

```bash
# Extract OCSP responder URL
OCSP_URL=$(openssl x509 -in cert.pem -noout -ocsp_uri)

# Get issuer certificate
openssl s_client -connect example.com:443 -showcerts 2>/dev/null | \
  awk '/BEGIN CERT/{i++}i==2' > issuer.pem

# Query OCSP status
openssl ocsp -issuer issuer.pem -cert cert.pem \
  -url "$OCSP_URL" -resp_text -noverify
```

### OCSP Stapling

Server pre-fetches the OCSP response and "staples" it to the TLS handshake. Client gets revocation status without contacting the CA.

```nginx
# NGINX OCSP stapling
ssl_stapling on;
ssl_stapling_verify on;
ssl_trusted_certificate /etc/ssl/chain.pem;
resolver 8.8.8.8 8.8.4.4 valid=300s;
resolver_timeout 5s;
```

```apache
# Apache OCSP stapling
SSLUseStapling On
SSLStaplingCache shmcb:/var/run/ocsp(128000)
SSLStaplingResponderTimeout 5
SSLStaplingReturnResponderErrors off
```

### OCSP Must-Staple

Certificate extension that tells browsers to **require** a stapled OCSP response. If the server doesn't staple, the connection fails (hard-fail).

```bash
# Generate CSR with OCSP Must-Staple
openssl req -new -key server.key -out server.csr \
  -addext "tlsfeature = status_request"

# Or in openssl.cnf
# [req_ext]
# tlsfeature = status_request
```

### Comparison Matrix

| Feature | CRL | OCSP | OCSP Stapling | OCSP Must-Staple |
|---------|-----|------|---------------|-------------------|
| Real-time | No | Yes | Near-real-time | Near-real-time |
| Privacy | Good (cached) | Poor (CA sees browsing) | Good (server fetches) | Good |
| Performance | Slow (large downloads) | Medium (per-connection query) | Fast (pre-fetched) | Fast |
| Reliability | Cached | Depends on CA responder | Server-managed | Strict enforcement |
| Failure mode | Soft-fail | Soft-fail (most browsers) | Soft-fail | **Hard-fail** |
| Browser support | Legacy | Universal | Universal | Growing |
| Recommended | Legacy only | Fallback | **Yes — enable always** | For high-security sites |
