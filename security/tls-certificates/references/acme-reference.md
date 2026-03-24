# ACME / Let's Encrypt Deep Dive

## Table of Contents

- [ACME Protocol Overview](#acme-protocol-overview)
- [Certbot DNS Plugins](#certbot-dns-plugins)
  - [Cloudflare](#cloudflare)
  - [AWS Route 53](#aws-route-53)
  - [DigitalOcean](#digitalocean)
  - [Google Cloud DNS](#google-cloud-dns)
- [HTTP-01 vs DNS-01 Challenge Comparison](#http-01-vs-dns-01-challenge-comparison)
  - [HTTP-01 Challenge](#http-01-challenge)
  - [DNS-01 Challenge](#dns-01-challenge)
  - [TLS-ALPN-01 Challenge](#tls-alpn-01-challenge)
  - [Comparison Matrix](#comparison-matrix)
- [Rate Limits and Staging](#rate-limits-and-staging)
  - [Production Rate Limits](#production-rate-limits)
  - [Staging Environment](#staging-environment)
  - [Rate Limit Best Practices](#rate-limit-best-practices)
- [Renewal Hooks](#renewal-hooks)
  - [Hook Types](#hook-types)
  - [Hook Directory Structure](#hook-directory-structure)
  - [Example Deploy Hooks](#example-deploy-hooks)
- [cert-manager for Kubernetes](#cert-manager-for-kubernetes)
  - [Installation](#installation)
  - [Issuers and ClusterIssuers](#issuers-and-clusterissuers)
  - [Certificate Resources](#certificate-resources)
  - [DNS-01 with cert-manager](#dns-01-with-cert-manager)
  - [Ingress Integration](#ingress-integration)
  - [Troubleshooting cert-manager](#troubleshooting-cert-manager)
- [acme.sh Alternative](#acmesh-alternative)
  - [Installation](#acmesh-installation)
  - [Issue Certificates](#issue-certificates)
  - [DNS API Integration](#dns-api-integration)
  - [Deployment](#deployment)
- [Caddy Auto-HTTPS](#caddy-auto-https)
  - [Basic Setup](#basic-setup)
  - [Advanced Configuration](#advanced-configuration)
  - [Caddy as Reverse Proxy](#caddy-as-reverse-proxy)

---

## ACME Protocol Overview

The Automated Certificate Management Environment (ACME, RFC 8555) automates certificate issuance and renewal. The protocol flow:

```
Client                          ACME Server (e.g., Let's Encrypt)
  |                                    |
  |--- POST /newAccount ------------->|  (Register or find account)
  |<-- 201 Created -------------------|
  |                                    |
  |--- POST /newOrder --------------->|  (Request cert for domains)
  |<-- 201 + authorization URLs ------|
  |                                    |
  |--- GET /authz/{id} -------------->|  (Get challenge options)
  |<-- Challenges (http-01, dns-01) --|
  |                                    |
  |  (Provision challenge response)    |
  |                                    |
  |--- POST /challenge/{id} --------->|  (Tell server to validate)
  |<-- 200 (processing) --------------|
  |                                    |
  |  (Server verifies challenge)       |
  |                                    |
  |--- POST /finalize --------------->|  (Submit CSR)
  |<-- 200 + certificate URL ---------|
  |                                    |
  |--- GET /cert --------------------->|  (Download certificate)
  |<-- Certificate chain --------------|
```

**ACME endpoints:**
- **Production:** `https://acme-v02.api.letsencrypt.org/directory`
- **Staging:** `https://acme-staging-v02.api.letsencrypt.org/directory`

---

## Certbot DNS Plugins

DNS plugins automate DNS-01 challenges by creating TXT records via DNS provider APIs.

### Cloudflare

```bash
# Install
sudo apt install python3-certbot-dns-cloudflare
# or via pip
pip install certbot-dns-cloudflare

# Create credentials file
cat > /etc/letsencrypt/credentials/cloudflare.ini << 'EOF'
# Cloudflare API token (recommended — scoped to Zone:DNS:Edit)
dns_cloudflare_api_token = YOUR_API_TOKEN
EOF
chmod 600 /etc/letsencrypt/credentials/cloudflare.ini

# Issue certificate
certbot certonly --dns-cloudflare \
  --dns-cloudflare-credentials /etc/letsencrypt/credentials/cloudflare.ini \
  --dns-cloudflare-propagation-seconds 30 \
  -d example.com \
  -d '*.example.com'
```

**Cloudflare API token permissions:** Zone → DNS → Edit (for specific zone).

### AWS Route 53

```bash
# Install
sudo apt install python3-certbot-dns-route53
# or via pip
pip install certbot-dns-route53

# AWS credentials (use IAM role on EC2, or ~/.aws/credentials)
# Required IAM policy:
cat << 'EOF'
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "route53:ListHostedZones",
                "route53:GetChange"
            ],
            "Resource": "*"
        },
        {
            "Effect": "Allow",
            "Action": "route53:ChangeResourceRecordSets",
            "Resource": "arn:aws:route53:::hostedzone/YOUR_ZONE_ID"
        }
    ]
}
EOF

# Issue certificate
certbot certonly --dns-route53 \
  -d example.com \
  -d '*.example.com'
```

### DigitalOcean

```bash
# Install
pip install certbot-dns-digitalocean

# Create credentials file
cat > /etc/letsencrypt/credentials/digitalocean.ini << 'EOF'
dns_digitalocean_token = YOUR_DO_API_TOKEN
EOF
chmod 600 /etc/letsencrypt/credentials/digitalocean.ini

# Issue certificate
certbot certonly --dns-digitalocean \
  --dns-digitalocean-credentials /etc/letsencrypt/credentials/digitalocean.ini \
  --dns-digitalocean-propagation-seconds 60 \
  -d example.com \
  -d '*.example.com'
```

### Google Cloud DNS

```bash
# Install
pip install certbot-dns-google

# Create service account key (requires dns.admin role)
# Save JSON key to /etc/letsencrypt/credentials/google.json
chmod 600 /etc/letsencrypt/credentials/google.json

# Issue certificate
certbot certonly --dns-google \
  --dns-google-credentials /etc/letsencrypt/credentials/google.json \
  --dns-google-propagation-seconds 60 \
  -d example.com \
  -d '*.example.com'
```

---

## HTTP-01 vs DNS-01 Challenge Comparison

### HTTP-01 Challenge

The ACME server verifies domain control by making an HTTP request to:
`http://<domain>/.well-known/acme-challenge/<token>`

```bash
# Standalone mode (certbot runs its own web server on port 80)
certbot certonly --standalone -d example.com

# Webroot mode (place files in existing web server's document root)
certbot certonly --webroot -w /var/www/html -d example.com

# Nginx plugin (auto-configures nginx)
certbot certonly --nginx -d example.com -d www.example.com
```

**Requirements:**
- Port 80 must be accessible from the internet
- Domain must resolve to the server running certbot
- Cannot issue wildcard certificates

### DNS-01 Challenge

The ACME server verifies domain control by checking a DNS TXT record:
`_acme-challenge.<domain> TXT <token>`

```bash
# Manual DNS-01 (interactive, prompts to add TXT record)
certbot certonly --manual --preferred-challenges dns -d example.com

# Automated with DNS plugin
certbot certonly --dns-cloudflare \
  --dns-cloudflare-credentials /etc/letsencrypt/credentials/cloudflare.ini \
  -d '*.example.com' -d example.com
```

**Advantages:**
- Works behind firewalls and NAT
- Can issue wildcard certificates
- Server doesn't need to be publicly accessible
- Can run from a separate management host

### TLS-ALPN-01 Challenge

Verification via a specially crafted self-signed certificate served on port 443 with the `acme-tls/1` ALPN protocol.

```bash
# Less common — supported by Caddy, dehydrated, lego
# Useful when port 80 is unavailable but 443 is
```

### Comparison Matrix

| Feature | HTTP-01 | DNS-01 | TLS-ALPN-01 |
|---------|---------|--------|-------------|
| **Port required** | 80 | None | 443 |
| **Wildcard certs** | No | Yes | No |
| **Behind firewall** | No | Yes | No |
| **Automation ease** | Easy | Medium (needs DNS API) | Medium |
| **Separate host** | No | Yes | No |
| **Load balancer friendly** | Needs routing | Yes | Needs routing |
| **Multiple servers** | Complex | Easy (DNS is central) | Complex |
| **Speed** | Fast (seconds) | Slower (DNS propagation) | Fast |

---

## Rate Limits and Staging

### Production Rate Limits

| Limit | Value | Window |
|-------|-------|--------|
| Certificates per Registered Domain | 50 | 7 days |
| Duplicate Certificates | 5 | 7 days |
| Failed Validations | 5 per account, per hostname | 1 hour |
| New Registrations | 10 per IP | 3 hours |
| New Orders | 300 per account | 3 hours |
| Pending Authorizations | 300 per account | — |
| SANs per Certificate | 100 | — |
| Accounts per IP | 10 | 3 hours |

**Renewal exemption:** Renewals (same set of domains) don't count against the Certificates per Domain limit.

### Staging Environment

Always test with staging first. Staging has much higher rate limits and issues untrusted certificates.

```bash
# Use staging for testing
certbot certonly --staging --nginx -d example.com

# Staging directory
# https://acme-staging-v02.api.letsencrypt.org/directory

# After testing, switch to production
certbot certonly --nginx -d example.com  # defaults to production

# Clean up staging certificates
certbot delete --cert-name example.com
```

### Rate Limit Best Practices

1. **Always test with staging first** before going to production
2. **Use SAN certificates** — combine multiple domains into one cert (up to 100 SANs)
3. **Avoid revoking + reissuing** — revocation doesn't reset rate limits
4. **Monitor with `certbot certificates`** to track existing certs
5. **Use `--expand`** to add domains to existing certificates instead of issuing new ones

---

## Renewal Hooks

### Hook Types

| Hook | When It Runs | Use Case |
|------|-------------|----------|
| `--pre-hook` | Before renewal attempt | Stop web server, prepare environment |
| `--post-hook` | After renewal attempt (success or fail) | Start web server, cleanup |
| `--deploy-hook` | Only after successful renewal | Reload services, copy certs, notify |

### Hook Directory Structure

```
/etc/letsencrypt/renewal-hooks/
├── pre/         # Scripts run before any renewal
├── post/        # Scripts run after any renewal attempt
└── deploy/      # Scripts run after successful renewal only
```

Scripts placed in these directories run for ALL certificate renewals. Per-certificate hooks are set in `/etc/letsencrypt/renewal/<domain>.conf`.

### Example Deploy Hooks

```bash
# Reload nginx after renewal
certbot renew --deploy-hook "systemctl reload nginx"

# Or as a script in /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
#!/bin/bash
systemctl reload nginx
logger "Certbot: nginx reloaded after certificate renewal for $RENEWED_DOMAINS"

# Available environment variables in hooks:
# RENEWED_LINEAGE  — path to renewed cert (e.g., /etc/letsencrypt/live/example.com)
# RENEWED_DOMAINS  — space-separated list of renewed domains
```

```bash
# Copy certs to application directory after renewal
#!/bin/bash
# /etc/letsencrypt/renewal-hooks/deploy/copy-certs.sh
DEST="/opt/myapp/ssl"
cp "$RENEWED_LINEAGE/fullchain.pem" "$DEST/cert.pem"
cp "$RENEWED_LINEAGE/privkey.pem" "$DEST/key.pem"
chown myapp:myapp "$DEST"/*.pem
chmod 640 "$DEST"/*.pem
systemctl restart myapp
```

---

## cert-manager for Kubernetes

### Installation

```bash
# Install with kubectl
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.3/cert-manager.yaml

# Or with Helm
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true

# Verify installation
kubectl get pods -n cert-manager
# Should see: cert-manager, cert-manager-cainjector, cert-manager-webhook
```

### Issuers and ClusterIssuers

```yaml
# ClusterIssuer — available cluster-wide
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

---
# ClusterIssuer for staging (testing)
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: admin@example.com
    privateKeySecretRef:
      name: letsencrypt-staging-key
    solvers:
    - http01:
        ingress:
          class: nginx

---
# Namespace-scoped Issuer (only for certs in the same namespace)
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: letsencrypt-prod
  namespace: my-app
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

### Certificate Resources

```yaml
# Explicit Certificate resource
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: api-tls
  namespace: default
spec:
  secretName: api-tls-secret        # Secret where cert+key are stored
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  duration: 2160h                    # 90 days
  renewBefore: 720h                  # Renew 30 days before expiry
  privateKey:
    algorithm: ECDSA
    size: 256
    rotationPolicy: Always           # New key on each renewal
  dnsNames:
  - api.example.com
  - api-v2.example.com
  usages:
  - server auth
  - client auth                      # For mTLS
```

**Secret structure created by cert-manager:**
```yaml
# cert-manager creates this Secret automatically
apiVersion: v1
kind: Secret
metadata:
  name: api-tls-secret
type: kubernetes.io/tls
data:
  tls.crt: <base64-encoded-fullchain>
  tls.key: <base64-encoded-private-key>
  ca.crt: <base64-encoded-ca-cert>     # if CA issuer
```

### DNS-01 with cert-manager

```yaml
# ClusterIssuer with Cloudflare DNS-01
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-dns
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: admin@example.com
    privateKeySecretRef:
      name: letsencrypt-dns-key
    solvers:
    - dns01:
        cloudflare:
          apiTokenSecretRef:
            name: cloudflare-api-token
            key: api-token

---
# Cloudflare API token secret
apiVersion: v1
kind: Secret
metadata:
  name: cloudflare-api-token
  namespace: cert-manager
type: Opaque
stringData:
  api-token: YOUR_CLOUDFLARE_API_TOKEN

---
# Route 53 DNS-01 solver
# solvers:
# - dns01:
#     route53:
#       region: us-east-1
#       hostedZoneID: Z1234567890
#       # Uses IRSA or instance role for credentials
```

### Ingress Integration

```yaml
# Ingress with automatic cert issuance via annotation
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: web-ingress
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - www.example.com
    - example.com
    secretName: web-tls       # cert-manager creates this Secret
  rules:
  - host: www.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: web-service
            port:
              number: 80
```

### Troubleshooting cert-manager

```bash
# Check all cert-manager resources
kubectl get certificate,certificaterequest,order,challenge -A

# Describe certificate for events and conditions
kubectl describe certificate api-tls -n default

# Check cert-manager controller logs
kubectl logs -n cert-manager deploy/cert-manager --tail=50

# Check webhook logs
kubectl logs -n cert-manager deploy/cert-manager-webhook --tail=50

# Common issues:
# 1. Challenge stuck in "pending" — check ingress/DNS connectivity
# 2. Order stuck in "invalid" — authorization failed, check challenge logs
# 3. "failed to perform self check" — DNS not propagated or HTTP challenge unreachable

# Force re-issuance by deleting the Certificate's Secret
kubectl delete secret api-tls-secret -n default
# cert-manager will detect the missing secret and re-issue
```

---

## acme.sh Alternative

### acme.sh Installation

```bash
# Install acme.sh (no root required)
curl https://get.acme.sh | sh
# Or from git
git clone https://github.com/acmesh-official/acme.sh.git
cd acme.sh && ./acme.sh --install

# Set default CA (Let's Encrypt is default since v3.0)
acme.sh --set-default-ca --server letsencrypt
```

**Advantages over certbot:**
- Pure shell script — no Python dependencies
- No root required
- Built-in DNS API support for 150+ providers
- Lightweight and portable

### Issue Certificates

```bash
# HTTP mode (webroot)
acme.sh --issue -d example.com -w /var/www/html

# Standalone mode
acme.sh --issue -d example.com --standalone

# Nginx mode
acme.sh --issue -d example.com --nginx

# Multiple domains
acme.sh --issue -d example.com -d www.example.com -d api.example.com

# ECDSA certificate
acme.sh --issue -d example.com --keylength ec-256

# Wildcard (requires DNS mode)
acme.sh --issue -d '*.example.com' -d example.com --dns dns_cf
```

### DNS API Integration

```bash
# Cloudflare
export CF_Token="YOUR_API_TOKEN"
export CF_Zone_ID="YOUR_ZONE_ID"
acme.sh --issue -d '*.example.com' --dns dns_cf

# AWS Route 53
export AWS_ACCESS_KEY_ID="YOUR_KEY"
export AWS_SECRET_ACCESS_KEY="YOUR_SECRET"
acme.sh --issue -d '*.example.com' --dns dns_aws

# DigitalOcean
export DO_API_KEY="YOUR_API_KEY"
acme.sh --issue -d '*.example.com' --dns dns_dgon

# Google Cloud
export CLOUDSDK_CORE_PROJECT="your-project"
acme.sh --issue -d '*.example.com' --dns dns_gcloud
```

### Deployment

```bash
# Install (deploy) certificate to a specific location
acme.sh --install-cert -d example.com \
  --key-file /etc/ssl/private/example.key \
  --fullchain-file /etc/ssl/certs/example.crt \
  --reloadcmd "systemctl reload nginx"

# Deploy to specific service
acme.sh --deploy -d example.com --deploy-hook docker
acme.sh --deploy -d example.com --deploy-hook haproxy

# Cron for auto-renewal (installed automatically)
# Check with: crontab -l
# Manual renewal: acme.sh --renew -d example.com --force
```

---

## Caddy Auto-HTTPS

### Basic Setup

Caddy automatically obtains and renews TLS certificates for all sites with domain names.

```
# Caddyfile — HTTPS is automatic for public domains
example.com {
    root * /var/www/html
    file_server
}

# Multiple sites
example.com {
    respond "Hello from example.com"
}

api.example.com {
    reverse_proxy localhost:8080
}
```

**How it works:**
1. Caddy detects domain names in the config
2. Automatically requests certificates from Let's Encrypt (or ZeroSSL)
3. Handles HTTP-01 or TLS-ALPN-01 challenges automatically
4. Renews certificates before expiry
5. Redirects HTTP → HTTPS by default

### Advanced Configuration

```
# Custom TLS settings
example.com {
    tls admin@example.com {
        protocols tls1.2 tls1.3
        ciphers TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384 TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
        curves x25519 secp256r1
        alpn h2 http/1.1
    }
    reverse_proxy localhost:3000
}

# Use DNS challenge for wildcard
*.example.com {
    tls {
        dns cloudflare {env.CF_API_TOKEN}
    }
    reverse_proxy localhost:3000
}

# Use staging/test CA
example.com {
    tls {
        ca https://acme-staging-v02.api.letsencrypt.org/directory
    }
}

# Internal/self-signed certificates
internal.local {
    tls internal
}

# Client certificate authentication (mTLS)
api.example.com {
    tls {
        client_auth {
            mode require_and_verify
            trusted_ca_cert_file /etc/caddy/client-ca.crt
        }
    }
    reverse_proxy localhost:8080
}
```

### Caddy as Reverse Proxy

```
# Auto-HTTPS reverse proxy with health checks
api.example.com {
    reverse_proxy backend1:8080 backend2:8080 {
        lb_policy round_robin
        health_uri /health
        health_interval 10s
        health_timeout 5s

        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-Proto {scheme}
    }
}

# With WebSocket support
app.example.com {
    reverse_proxy /ws/* websocket-server:8080
    reverse_proxy /* app-server:3000
}
```

```bash
# Install Caddy
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | \
  sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | \
  sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update && sudo apt install caddy

# With DNS plugin (requires building from source or using xcaddy)
xcaddy build --with github.com/caddy-dns/cloudflare
```
