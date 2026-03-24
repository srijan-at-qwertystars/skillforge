# NATS Security Deep-Dive Reference

Production-oriented guide to securing NATS: TLS, authentication, authorization, multi-tenancy, and hardening.

## Table of Contents

- [1. TLS Configuration](#1-tls-configuration)
- [2. NKeys Authentication](#2-nkeys-authentication)
- [3. JWT-Based Authorization](#3-jwt-based-authorization)
- [4. Account Isolation](#4-account-isolation)
- [5. User Permissions](#5-user-permissions)
- [6. Operator/Account/User Hierarchy](#6-operatoraccountuser-hierarchy)
- [7. Certificate Rotation](#7-certificate-rotation)
- [8. NATS Resolver Configuration](#8-nats-resolver-configuration)
- [9. Security Best Practices Checklist](#9-security-best-practices-checklist)

---

## 1. TLS Configuration

### Generating Certificates (CA, Server, Client)

```bash
# --- CA ---
openssl genrsa -aes256 -out ca-key.pem 4096
openssl req -new -x509 -days 3650 -key ca-key.pem -sha256 -out ca-cert.pem \
  -subj "/C=US/ST=CA/O=MyOrg/CN=NATS-CA"

# --- Server cert with SANs ---
openssl genrsa -out server-key.pem 2048
openssl req -new -key server-key.pem -out server.csr -subj "/CN=nats.example.com"
openssl x509 -req -in server.csr -CA ca-cert.pem -CAkey ca-key.pem -CAcreateserial \
  -out server-cert.pem -days 825 -sha256 -extfile <(printf "basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth,clientAuth
subjectAltName=DNS:nats.example.com,DNS:*.nats.default.svc.cluster.local,IP:10.0.0.10")

# --- Client cert (for mTLS) ---
openssl genrsa -out client-key.pem 2048
openssl req -new -key client-key.pem -out client.csr -subj "/CN=nats-client-orderservice"
openssl x509 -req -in client.csr -CA ca-cert.pem -CAkey ca-key.pem -CAcreateserial \
  -out client-cert.pem -days 365 -sha256 \
  -extfile <(echo "basicConstraints=CA:FALSE
keyUsage=digitalSignature
extendedKeyUsage=clientAuth")
```

### Server TLS + mTLS Enforcement

```hcl
tls {
  cert_file:  "/etc/nats/certs/server-cert.pem"
  key_file:   "/etc/nats/certs/server-key.pem"
  ca_file:    "/etc/nats/certs/ca-cert.pem"
  verify:           true    # require client cert (mTLS)
  verify_and_map:   true    # map client cert CN → NATS user
  timeout:          2
}
```

### TLS for Cluster Routes, Leaf Nodes, WebSocket

```hcl
cluster {
  port: 6222
  tls { cert_file: "...", key_file: "...", ca_file: "...", verify: true }
  routes = [ "nats-route://nats-0.nats.svc:6222", "nats-route://nats-1.nats.svc:6222" ]
}
leafnodes {
  port: 7422
  tls { cert_file: "...", key_file: "...", ca_file: "...", verify: true }
}
websocket {
  port: 443
  tls { cert_file: "...", key_file: "...", ca_file: "..." }
  no_tls: false
}
```

### Cipher Suite Selection and TLS Version Enforcement

```hcl
tls {
  cert_file: "...", key_file: "...", ca_file: "..."
  min_version: 1.2
  cipher_suites: [
    "TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384"
    "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384"
    "TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256"
    "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256"
  ]
  curve_preferences: ["CurveP384", "CurveP256"]
}
```

### Certificate Pinning

Pin a specific intermediate CA and verify route peer SANs match expected hostnames:

```hcl
cluster {
  tls {
    ca_file: "/etc/nats/certs/pinned-intermediate-ca.pem"   # only this CA trusted
    verify: true
    verify_cert_and_check_known_urls: true                   # SAN must match route URL
  }
}
```
## 2. NKeys Authentication

### What NKeys Are

Ed25519 key pairs for password-less auth. The client signs a server-issued nonce with the private seed; the server verifies against the public key. No secret crosses the wire.

### Generating NKeys and Key Types

```bash
go install github.com/nats-io/nkeys/cmd/nk@latest
nk -gen user -pubout   # outputs seed (SUAJ3G...) + public key (UCDXB3...)
```

| Type | Prefix | Seed | Purpose |
|------|--------|------|---------|
| Operator | `O` | `SO` | Root trust, signs account JWTs |
| Account | `A` | `SA` | Tenant boundary, signs user JWTs |
| User | `U` | `SU` | Client identity |
| Server | `N` | `SN` | Server identity |
| Cluster | `C` | `SC` | Cluster identity |

### Server Config + Client Connection

```hcl
authorization {
  users = [
    { nkey: "UCDXB3DE2WYQ7ZLH...", permissions: {
        publish: { allow: ["orders.>"] }, subscribe: { allow: ["orders.>", "_INBOX.>"] }
    }}
  ]
}
```

```bash
nats pub orders.new '{"id":1}' --nkey path/to/user.nk
```

### Seed Security and Key Rotation

Seeds are secrets — store in Vault/K8s Secrets, never commit to VCS. Public keys are safe to embed in config. Always `chmod 600` seed files.

**Rotation:** 1) Generate new NKey pair. 2) Add new public key to config alongside old. 3) `kill -HUP $(pidof nats-server)`. 4) Migrate clients to new seed. 5) Remove old key, reload.
## 3. JWT-Based Authorization

### Architecture: Operator → Account → User

The server trusts an operator public key. The operator signs account JWTs, accounts sign user JWTs. Account admins self-service their own users without involving the operator.

### Creating Operators, Accounts, Users with nsc

```bash
nsc add operator --name MyOperator --sys
nsc add account --name TeamAlpha
nsc add user --account TeamAlpha --name svc-order \
  --allow-pub "orders.>" --allow-sub "orders.>,_INBOX.>"
nsc generate creds --account TeamAlpha --name svc-order -o svc-order.creds
```

### JWT Claims and Permissions

Key claims inside a user JWT: `iss` (issuer key), `sub` (user key), `exp` (expiry), `nats.pub`/`nats.sub` (allow/deny lists), `nats.resp` (response permissions), `nats.subs` (max subscriptions), `nats.payload` (max size). Inspect with `nsc describe user --account TeamAlpha --name svc-order`.

### Account JWTs vs User JWTs

Account JWTs (signed by operator) define connection limits, JetStream quotas, exports/imports. User JWTs (signed by account) define pub/sub permissions and payload limits. Account JWTs go to the resolver; user JWTs live in `.creds` files.

### Signing Keys for Delegation

```bash
nsc generate nkey --account --store
nsc edit account --name TeamAlpha --sk ABJHGQVNPCGR...
nsc add user --account TeamAlpha --name svc-payment \
  --signing-key ABJHGQVNPCGR... --allow-pub "payments.>"
```

Signing keys can be revoked without rotating the account identity key.

### JWT Expiration and Revocation

```bash
nsc add user --account TeamAlpha --name temp-user --expiry 90d
nsc revocations add-user --account TeamAlpha --name compromised-user
nsc revocations add-user --account TeamAlpha --before "2024-06-01"
nsc push --account TeamAlpha
```

### Push-Based vs Full Resolver

| Resolver | Storage                  | Best For              |
|----------|--------------------------|-----------------------|
| Full     | JWT directory on disk    | Production clusters   |
| Memory   | Embedded in server conf  | Development/testing   |
| URL      | HTTP endpoint            | Centralized mgmt     |
| Cache    | Local cache + remote     | Edge/leaf nodes       |
## 4. Account Isolation

### Multi-Tenancy and Subject Space Isolation

Each account has its own subject namespace. `orders.new` in Account A is completely invisible to Account B — isolation is automatic, no configuration required.

### Resource Limits per Account

```bash
nsc edit account --name TeamAlpha \
  --conns 500 --data 10GB --subs 10000 --payload 1MB \
  --exports 50 --imports 50 --leaf-conns 10
```

### Import/Export Between Accounts (Services and Streams)

```bash
# Export a request-reply service from Alpha; import into Beta
nsc add export --account TeamAlpha --name "OrderLookup" --subject "orders.lookup" --service
nsc add import --account TeamBeta --name "OrderLookup" \
  --src-account $(nsc describe account TeamAlpha --field sub) \
  --remote-subject "orders.lookup" --local-subject "alpha.orders.lookup" --service

# Export a pub/sub stream; import with local prefix
nsc add export --account TeamAlpha --name "OrderEvents" --subject "orders.events.>"
nsc add import --account TeamBeta --name "OrderEvents" \
  --src-account $(nsc describe account TeamAlpha --field sub) \
  --remote-subject "orders.events.>" --local-subject "partner.orders.events.>"
```

### Account-Level JetStream Limits

```bash
nsc edit account --name TeamAlpha \
  --js-mem-storage 1GB --js-disk-storage 50GB --js-streams 20 --js-consumer 100
```

### System Account

Receives internal server events on `$SYS.>`. Always create explicitly and restrict access:

```bash
nsc add account --name SYS
nsc edit operator --system-account SYS
nsc add user --account SYS --name sys-monitor --allow-sub '$SYS.>'
```
## 5. User Permissions

### Publish and Subscribe Restrictions

```hcl
# Static config
permissions: {
  publish:   { allow: ["orders.>", "_INBOX.>"], deny: ["orders.admin.>"] }
  subscribe: { allow: ["orders.>", "_INBOX.>"], deny: ["orders.internal.>"] }
}
```

```bash
# With nsc
nsc add user --account TeamAlpha --name order-writer \
  --allow-pub "orders.>" --deny-pub "orders.admin.>" \
  --allow-sub "orders.>" --deny-sub "orders.internal.>"
```

### Response Permissions

Allow a service to reply to dynamic inboxes without blanket `_INBOX.>` publish rights:

```hcl
permissions: {
  subscribe: { allow: ["orders.requests"] }
  allow_responses: { max: 1, expires: "5s" }
}
```

### Queue Group and Wildcard Permissions

`*` matches one token; `>` matches one or more. Use deny lists to carve exceptions:

```hcl
permissions: {
  publish: { allow: ["events.>"], deny: ["events.internal.>", "events.admin.*"] }
}
```

### Permission Violations

Violations produce `-ERR 'Permissions Violation for Publish to "..."'` — the client is **not** disconnected. The server emits advisories on `$SYS.SERVER.*.CLIENT.AUTH.ERR` for security monitoring.
## 6. Operator/Account/User Hierarchy

**Operator** — root trust anchor. Server trusts the operator public key. Signs account JWTs. **Account** — tenant boundary. Defines limits, exports/imports. Signs user JWTs. **User** — individual identity. Defines pub/sub permissions. Seed authenticates connections.

**Signing keys** at each level enable delegation without exposing identity keys:

```bash
nsc edit operator --sk generate           # operator signing key
nsc edit account --name TeamAlpha --sk generate   # account signing key
```

**Scoped signing keys** cap the permissions any user created with that key can receive:

```bash
nsc edit signing-key --account TeamAlpha --sk ABJHGQV... \
  --role "readonly" --allow-sub ">" --deny-pub ">"
```

Users issued under this scoped key inherit the ceiling — even if broader permissions are requested.
## 7. Certificate Rotation

### Zero-Downtime Rotation

1. Place new cert/key on disk. 2. Update config if paths changed. 3. Reload: `kill -HUP $(pidof nats-server)`.

Existing connections keep their TLS session; new connections use the updated cert.

### OCSP Stapling

```hcl
ocsp { mode: always }   # always | never | must
```

### Monitoring Expiry

```bash
DAYS=$(( ($(date -d "$(openssl x509 -in /etc/nats/certs/server-cert.pem -noout -enddate \
  | cut -d= -f2)" +%s) - $(date +%s)) / 86400 ))
[ "$DAYS" -lt 30 ] && echo "ALERT: cert expires in $DAYS days"
```

### Automation with cert-manager (Kubernetes)

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: { name: nats-server-cert, namespace: nats }
spec:
  secretName: nats-server-tls
  issuerRef: { name: internal-ca-issuer, kind: ClusterIssuer }
  dnsNames: ["nats.nats.svc.cluster.local", "*.nats.nats.svc.cluster.local"]
  duration: 720h
  renewBefore: 168h
  privateKey: { algorithm: ECDSA, size: 256 }
```

Mount the secret and use the NATS Helm chart's reloader sidecar for automatic SIGHUP on renewal.
## 8. NATS Resolver Configuration

### Full Resolver (Directory-Based) — Production

```hcl
operator: /etc/nats/nsc/stores/MyOperator/MyOperator.jwt
system_account: ADYKIQ4SPNZ7G4FDHLPFCSA6EXAMPLE
resolver: { type: full, dir: "/etc/nats/jwt", allow_delete: false, interval: "2m", limit: 1000 }
```

### Memory Resolver — Development

```hcl
resolver: MEMORY
resolver_preload: {
  ABJHGQVNPCGR...: "eyJ0eXAiOiJKV1Qi..."
  ACLS7HTQGZ6X...: "eyJ0eXAiOiJKV1Qi..."
}
```

### Cache Resolver — Edge/Leaf Nodes

```hcl
resolver: { type: cache, dir: "/etc/nats/jwt-cache", ttl: "1h", limit: 1000 }
```

### URL Resolver — Centralized

```hcl
resolver: URL("https://jwt-server.example.com/jwt/v1/accounts/")
# Server appends the account public key to the URL to fetch the JWT
```

### Resolver Preloads and nsc Push/Pull

Bootstrap essential accounts so the server starts even if the resolver is unreachable:

```hcl
resolver_preload: { ADYKIQ4SPNZ7G4FDHLPFCSA6EXAMPLE: "eyJ0eXAi..." }
```

```bash
nsc push --all --system-account SYS --system-user sys-admin
nsc pull --all --system-account SYS --system-user sys-admin
```
## 9. Security Best Practices Checklist

### Production Hardening

- [ ] Enable TLS on **all** listeners: client, cluster, leaf, WebSocket, gateway
- [ ] Enforce mTLS (`verify: true`) for service-to-service connections
- [ ] Set `min_version: 1.2` and restrict to AEAD cipher suites
- [ ] Use JWT/NKey auth — never username/password in production
- [ ] Set per-account connection, data, and subscription limits
- [ ] Limit `max_payload` to prevent memory abuse
- [ ] Bind monitoring port (8222) to localhost or disable it

### Least Privilege

- [ ] Grant exact subjects (`orders.create`) not wildcards (`orders.>`) when possible
- [ ] Deny sensitive subjects (`$SYS.>`) for non-admin users
- [ ] Set `max_responses: 1` on service responders
- [ ] Use scoped signing keys to cap delegated permissions
- [ ] Separate read-only monitoring users from operational users

### Audit Logging

```bash
nats sub '$SYS.SERVER.*.CLIENT.AUTH.ERR' --creds sys.creds   # auth failures
nats sub '$SYS.ACCOUNT.*.CONNECT' --creds sys.creds          # connections
nats sub '$SYS.ACCOUNT.*.DISCONNECT' --creds sys.creds       # disconnections
```

Forward advisories to your SIEM pipeline.

### Network Segmentation

Place NATS in a dedicated VPC subnet. Expose only port 4222 to application subnets; keep 6222 (cluster), 7422 (leaf), 8222 (monitoring) internal. Use gateway connections for cross-DC traffic.

### Secrets Management

**Vault:** `vault kv put secret/nats/svc-order seed=SUAJ3G...` — retrieve at runtime, write to `chmod 600` file.

**Kubernetes Secrets:**

```yaml
apiVersion: v1
kind: Secret
metadata: { name: nats-client-creds, namespace: app }
stringData:
  svc-order.creds: |
    -----BEGIN NATS USER JWT-----
    eyJ0eXAiOiJKV1Qi...
    ------END NATS USER JWT------
    -----BEGIN USER NKEY SEED-----
    SUAJ3G2NLOJBPKZD...
    ------END USER NKEY SEED------
```

Mount as a read-only volume.
> **Layer defenses:** TLS for transport → NKeys/JWTs for identity → accounts for isolation → permissions for authorization. No single mechanism is sufficient alone.
