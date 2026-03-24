# Istio Security Deep Dive

## Table of Contents

- [Security Architecture](#security-architecture)
  - [SPIFFE Identity](#spiffe-identity)
  - [Certificate Management](#certificate-management)
  - [Security Data Flow](#security-data-flow)
- [PeerAuthentication](#peerauthentication)
  - [STRICT Mode](#strict-mode)
  - [PERMISSIVE Mode](#permissive-mode)
  - [DISABLE Mode](#disable-mode)
  - [Port-Level Overrides](#port-level-overrides)
  - [Migration Strategy](#migration-strategy)
- [AuthorizationPolicy](#authorizationpolicy)
  - [ALLOW Action](#allow-action)
  - [DENY Action](#deny-action)
  - [CUSTOM Action](#custom-action)
  - [Policy Evaluation Order](#policy-evaluation-order)
  - [Source Rules](#source-rules)
  - [Operation Rules](#operation-rules)
  - [Condition Rules](#condition-rules)
  - [Deny-by-Default Pattern](#deny-by-default-pattern)
  - [Namespace Isolation](#namespace-isolation)
- [RequestAuthentication](#requestauthentication)
  - [JWT Validation](#jwt-validation)
  - [Multiple Issuers](#multiple-issuers)
  - [Claims-Based Authorization](#claims-based-authorization)
  - [Token Forwarding](#token-forwarding)
- [External Authorization (ext-authz)](#external-authorization-ext-authz)
  - [gRPC ext-authz Server](#grpc-ext-authz-server)
  - [HTTP ext-authz Server](#http-ext-authz-server)
  - [Integration with OPA](#integration-with-opa)
- [Certificate Management](#certificate-management-1)
  - [Built-in Citadel CA](#built-in-citadel-ca)
  - [Custom CA Integration](#custom-ca-integration)
  - [cert-manager Integration](#cert-manager-integration)
  - [Certificate Rotation](#certificate-rotation)
  - [Plugging in External CAs](#plugging-in-external-cas)
- [Security Best Practices](#security-best-practices)
  - [Defense in Depth](#defense-in-depth)
  - [Production Checklist](#production-checklist)
  - [Common Pitfalls](#common-pitfalls)

---

## Security Architecture

Istio security is built on three pillars:
1. **Identity** — SPIFFE-based workload identity via X.509 certificates.
2. **Authentication** — peer (mTLS) and request (JWT) authentication.
3. **Authorization** — fine-grained access control policies.

### SPIFFE Identity

Every workload in the mesh gets a SPIFFE identity:

```
spiffe://<trust-domain>/ns/<namespace>/sa/<service-account>
```

Example:
```
spiffe://cluster.local/ns/production/sa/frontend
```

- Trust domain defaults to `cluster.local`. Configure via `meshConfig.trustDomain`.
- Identity is derived from the Kubernetes ServiceAccount.
- Identity is encoded in the X.509 certificate SAN (Subject Alternative Name).

**Best practice:** Assign unique ServiceAccounts per workload. Never share ServiceAccounts
across different services, as this undermines authorization boundaries.

### Certificate Management

istiod acts as the Certificate Authority (CA):

1. Envoy sidecar generates a private key and CSR.
2. `istio-agent` (pilot-agent) sends CSR to istiod over a secure gRPC channel.
3. istiod validates the pod identity via Kubernetes token review.
4. istiod signs the certificate and returns it.
5. Certificate is loaded into Envoy's SDS (Secret Discovery Service).
6. Certificates are rotated automatically before expiry (default TTL: 24h).

### Security Data Flow

```
Client Pod                             Server Pod
┌──────────┐                           ┌──────────┐
│  App     │                           │  App     │
│  ↓       │                           │  ↑       │
│  Envoy   │──── mTLS tunnel ─────────→│  Envoy   │
│  (SAN:   │                           │  (SAN:   │
│  frontend│                           │  backend)│
│  SA)     │                           │          │
└──────────┘                           └──────────┘
     ↑ CSR/Cert                              ↑ CSR/Cert
     └──────────────── istiod ───────────────┘
                    (CA + Policy)
```

Both sides verify the peer's certificate. AuthorizationPolicy checks the client's
SPIFFE identity against allowed principals.

---

## PeerAuthentication

PeerAuthentication controls mutual TLS between sidecars. Scope hierarchy:
1. **Mesh-wide** — in `istio-system` namespace, no selector.
2. **Namespace-wide** — in target namespace, no selector.
3. **Workload-specific** — with `selector.matchLabels`.

More specific policies override broader ones.

### STRICT Mode

Requires mTLS for all communication. Plaintext connections are rejected.

```yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: istio-system
spec:
  mtls:
    mode: STRICT
```

Use when:
- All workloads in the mesh have sidecars.
- No external services send plaintext to mesh services.
- Migration from PERMISSIVE is complete.

### PERMISSIVE Mode

Accepts both mTLS and plaintext. Use during migration.

```yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: istio-system
spec:
  mtls:
    mode: PERMISSIVE
```

**Monitoring plaintext traffic:**
```promql
# Find services still receiving plaintext
istio_requests_total{connection_security_policy="none"}
```

When this metric drops to zero for a namespace, switch that namespace to STRICT.

### DISABLE Mode

Disables mTLS entirely. Use for specific workloads that cannot terminate mTLS:

```yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: no-mtls-for-legacy
  namespace: legacy
spec:
  selector:
    matchLabels:
      app: legacy-service
  mtls:
    mode: DISABLE
```

### Port-Level Overrides

Override mTLS mode for specific ports. Common for health check endpoints:

```yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: backend-auth
  namespace: production
spec:
  selector:
    matchLabels:
      app: backend
  mtls:
    mode: STRICT
  portLevelMtls:
    8080:
      mode: STRICT
    8443:
      mode: STRICT
    15021:
      mode: DISABLE    # health check port — plaintext
```

### Migration Strategy

1. Start with `PERMISSIVE` mesh-wide.
2. Enable sidecar injection on all namespaces.
3. Restart all workloads to inject sidecars.
4. Monitor `connection_security_policy` metric.
5. Switch to `STRICT` namespace-by-namespace as plaintext drops to zero.
6. Finally switch mesh-wide to `STRICT`.

```bash
# Check current mTLS status
istioctl authn tls-check <pod>.<ns>

# Monitor plaintext traffic
kubectl exec -n istio-system deploy/prometheus -- \
  promtool query instant http://localhost:9090 \
  'sum(rate(istio_requests_total{connection_security_policy="none"}[5m])) by (destination_service)'
```

---

## AuthorizationPolicy

AuthorizationPolicy enforces access control at the Envoy proxy level. Policies are
additive — if any ALLOW policy matches, the request is allowed (unless a DENY matches).

### ALLOW Action

Allow matching requests; deny everything else (when combined with deny-all):

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-frontend-to-backend
  namespace: production
spec:
  selector:
    matchLabels:
      app: backend
  action: ALLOW
  rules:
    - from:
        - source:
            principals:
              - "cluster.local/ns/production/sa/frontend"
      to:
        - operation:
            methods: ["GET", "POST"]
            paths: ["/api/*"]
```

### DENY Action

Deny matching requests regardless of ALLOW policies. DENY is evaluated before ALLOW.

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-external-admin
  namespace: production
spec:
  selector:
    matchLabels:
      app: admin-panel
  action: DENY
  rules:
    - from:
        - source:
            notNamespaces: ["admin"]
      to:
        - operation:
            paths: ["/admin/*"]
```

### CUSTOM Action

Delegate authorization to an external service (ext-authz):

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: ext-authz
  namespace: production
spec:
  selector:
    matchLabels:
      app: api-gateway
  action: CUSTOM
  provider:
    name: my-ext-authz
  rules:
    - to:
        - operation:
            paths: ["/api/*"]
```

The provider is registered in the mesh config (see ext-authz section below).

### Policy Evaluation Order

```
1. CUSTOM policies (if match → delegate to ext-authz provider)
   ↓ (if no CUSTOM match or provider allows)
2. DENY policies (if any match → deny immediately)
   ↓ (if no DENY match)
3. ALLOW policies (if any match → allow)
   ↓ (if no ALLOW match)
4. If any ALLOW policy exists for the workload → deny (implicit deny)
   If no ALLOW policy exists → allow (no policy = allow all)
```

**Critical:** An empty `spec: {}` policy is a deny-all. No policy at all is allow-all.

### Source Rules

```yaml
rules:
  - from:
      - source:
          principals: ["cluster.local/ns/prod/sa/frontend"]      # SPIFFE identity
          notPrincipals: ["cluster.local/ns/prod/sa/untrusted"]
          namespaces: ["production", "staging"]
          notNamespaces: ["sandbox"]
          ipBlocks: ["10.0.0.0/8"]
          notIpBlocks: ["10.0.99.0/24"]
          remoteIpBlocks: ["203.0.113.0/24"]       # original client IP (X-Forwarded-For)
          requestPrincipals: ["issuer/subject"]     # JWT identity
```

### Operation Rules

```yaml
rules:
  - to:
      - operation:
          methods: ["GET", "POST"]
          notMethods: ["DELETE"]
          paths: ["/api/*", "/health"]
          notPaths: ["/api/admin/*"]
          hosts: ["api.example.com"]
          ports: ["8080", "8443"]
```

Paths support prefix (`/api/*`), suffix (`*/info`), and exact matching.

### Condition Rules

```yaml
rules:
  - when:
      - key: request.headers[x-api-key]
        values: ["valid-key-1", "valid-key-2"]
      - key: source.namespace
        values: ["production"]
      - key: request.auth.claims[groups]
        values: ["admin", "editor"]
```

Supported condition keys:
- `request.headers[<name>]`
- `source.ip`, `source.namespace`, `source.principal`
- `destination.ip`, `destination.port`
- `request.auth.principal`, `request.auth.audiences`
- `request.auth.claims[<claim>]`
- `connection.sni`

### Deny-by-Default Pattern

Recommended production setup:

```yaml
# Step 1: Deny all in namespace
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-all
  namespace: production
spec: {}
---
# Step 2: Allow specific paths (ALLOW policies per service)
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-frontend
  namespace: production
spec:
  selector:
    matchLabels:
      app: backend
  action: ALLOW
  rules:
    - from:
        - source:
            principals: ["cluster.local/ns/production/sa/frontend"]
      to:
        - operation:
            methods: ["GET"]
            paths: ["/api/products", "/api/reviews"]
```

### Namespace Isolation

Isolate namespaces from each other:

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: ns-isolation
  namespace: team-a
spec:
  action: ALLOW
  rules:
    - from:
        - source:
            namespaces: ["team-a", "shared-services"]
```

---

## RequestAuthentication

RequestAuthentication validates JWTs on incoming requests. It does NOT enforce that a
JWT is present — pair with AuthorizationPolicy to require valid tokens.

### JWT Validation

```yaml
apiVersion: security.istio.io/v1
kind: RequestAuthentication
metadata:
  name: jwt-auth
  namespace: production
spec:
  selector:
    matchLabels:
      app: api-gateway
  jwtRules:
    - issuer: "https://accounts.google.com"
      jwksUri: "https://www.googleapis.com/oauth2/v3/certs"
      audiences:
        - "my-app.example.com"
      fromHeaders:
        - name: Authorization
          prefix: "Bearer "
      fromParams:
        - access_token
      outputPayloadToHeader: x-jwt-payload
      forwardOriginalToken: true
```

**Behavior:**
- Request with valid JWT → allowed, claims extracted.
- Request with invalid JWT → rejected with 401.
- Request with no JWT → allowed (unless blocked by AuthorizationPolicy).

### Multiple Issuers

```yaml
spec:
  jwtRules:
    - issuer: "https://auth.internal.com"
      jwksUri: "https://auth.internal.com/.well-known/jwks.json"
    - issuer: "https://auth.external.com"
      jwksUri: "https://auth.external.com/.well-known/jwks.json"
      fromHeaders:
        - name: X-External-Token
          prefix: "Bearer "
```

Each JWT is validated against its matching issuer. Multiple valid JWTs can coexist.

### Claims-Based Authorization

Pair RequestAuthentication with AuthorizationPolicy for claims enforcement:

```yaml
# Require valid JWT
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: require-jwt
  namespace: production
spec:
  selector:
    matchLabels:
      app: api-gateway
  action: ALLOW
  rules:
    - from:
        - source:
            requestPrincipals: ["*"]    # any valid JWT
      when:
        - key: request.auth.claims[groups]
          values: ["admin", "editor"]
---
# Deny requests without JWT
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-no-jwt
  namespace: production
spec:
  selector:
    matchLabels:
      app: api-gateway
  action: DENY
  rules:
    - from:
        - source:
            notRequestPrincipals: ["*"]
```

### Token Forwarding

```yaml
jwtRules:
  - issuer: "https://auth.example.com"
    jwksUri: "https://auth.example.com/.well-known/jwks.json"
    forwardOriginalToken: true              # forward JWT to upstream
    outputPayloadToHeader: x-jwt-payload    # decode payload to header
    outputClaimToHeaders:
      - header: x-jwt-user
        claim: sub
      - header: x-jwt-email
        claim: email
```

Upstream services can read decoded claims from headers without validating the JWT again.

---

## External Authorization (ext-authz)

External authorization delegates access control decisions to an external service. Use
for complex authorization logic that goes beyond Istio's built-in capabilities.

### gRPC ext-authz Server

Register the provider in mesh config:

```yaml
meshConfig:
  extensionProviders:
    - name: my-ext-authz-grpc
      envoyExtAuthzGrpc:
        service: ext-authz.auth-system.svc.cluster.local
        port: 9000
        timeout: 2s
        failOpen: false    # deny on provider failure
        statusOnError: 403
```

### HTTP ext-authz Server

```yaml
meshConfig:
  extensionProviders:
    - name: my-ext-authz-http
      envoyExtAuthzHttp:
        service: ext-authz.auth-system.svc.cluster.local
        port: 8080
        timeout: 2s
        headersToUpstreamOnAllow:
          - x-auth-user
          - x-auth-role
        headersToDownstreamOnDeny:
          - x-auth-error
        includeRequestHeadersInCheck:
          - authorization
          - cookie
        includeAdditionalHeadersInCheck:
          x-auth-service: "istio-mesh"
```

### Integration with OPA

Open Policy Agent is a popular ext-authz backend:

```yaml
# Deploy OPA as ext-authz provider
meshConfig:
  extensionProviders:
    - name: opa-ext-authz
      envoyExtAuthzGrpc:
        service: opa.opa-system.svc.cluster.local
        port: 9191
---
# Use CUSTOM action in AuthorizationPolicy
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: opa-authz
spec:
  selector:
    matchLabels:
      app: my-service
  action: CUSTOM
  provider:
    name: opa-ext-authz
  rules:
    - to:
        - operation:
            paths: ["/*"]
```

---

## Certificate Management

### Built-in Citadel CA

istiod includes a built-in CA (formerly Citadel) that signs workload certificates:

- Default certificate TTL: 24 hours.
- Certificates are auto-rotated before expiry.
- Root CA certificate is stored in `istio-ca-root-cert` ConfigMap.

```bash
# Check CA health
kubectl get cm istio-ca-root-cert -n istio-system -o yaml

# Check workload certificate
istioctl proxy-config secret <pod>.<ns>

# Decode certificate
istioctl proxy-config secret <pod>.<ns> -o json | \
  jq -r '.[0].certificate_chain.inline_bytes' | \
  base64 -d | openssl x509 -noout -text
```

### Custom CA Integration

Use your own root CA with Istio:

```bash
# Create secret with custom CA
kubectl create secret generic cacerts -n istio-system \
  --from-file=ca-cert.pem \
  --from-file=ca-key.pem \
  --from-file=root-cert.pem \
  --from-file=cert-chain.pem
```

istiod will use this CA to sign workload certificates instead of its self-signed CA.

### cert-manager Integration

Use cert-manager as the CA for Istio:

```yaml
# Install istio-csr (cert-manager Istio agent)
helm install cert-manager-istio-csr jetstack/cert-manager-istio-csr \
  --namespace cert-manager \
  --set "app.tls.rootCAFile=/var/run/secrets/istio-csr/ca.pem" \
  --set "app.server.clusterID=cluster.local"

# Configure Istio to use cert-manager
meshConfig:
  defaultConfig:
    proxyMetadata:
      ISTIO_META_CERT_SIGNER: cert-manager
```

Benefits:
- Centralized certificate management.
- Integration with external CAs (Vault, AWS ACM PCA, Google CAS).
- Consistent certificate policies across the organization.

### Certificate Rotation

Certificates are rotated automatically. Tune the rotation parameters:

```yaml
meshConfig:
  defaultConfig:
    proxyMetadata:
      SECRET_TTL: "12h"                    # certificate lifetime
      SECRET_GRACE_PERIOD_RATIO: "0.5"     # rotate at 50% of lifetime
      SECRET_ROTATION_CHECK_INTERVAL: "5m" # check interval
```

**Monitor rotation:**
```bash
# Check certificate expiry
istioctl proxy-config secret <pod>.<ns> -o json | \
  jq '.[0].certificate_chain.inline_bytes' | \
  base64 -d | openssl x509 -noout -enddate
```

### Plugging in External CAs

For enterprise environments using Vault, AWS ACM PCA, or similar:

1. Use cert-manager with the appropriate issuer.
2. Deploy istio-csr to bridge cert-manager and Istio.
3. Configure istiod to use the external CA via `caAddress`.

```yaml
# Using external CA address
global:
  caAddress: cert-manager-istio-csr.cert-manager.svc:443
  pilotCertProvider: istiod
```

---

## Security Best Practices

### Defense in Depth

Layer security controls:

```
Layer 1: Network Policies (Kubernetes) — L3/L4 segmentation
Layer 2: PeerAuthentication (mTLS) — transport encryption + identity
Layer 3: AuthorizationPolicy — application-level access control
Layer 4: RequestAuthentication — end-user identity verification
Layer 5: Application-level security — business logic authorization
```

Each layer is independent. A failure in one layer doesn't compromise the others.

### Production Checklist

1. **mTLS everywhere:**
   ```yaml
   # Mesh-wide STRICT mTLS
   apiVersion: security.istio.io/v1
   kind: PeerAuthentication
   metadata:
     name: default
     namespace: istio-system
   spec:
     mtls:
       mode: STRICT
   ```

2. **Deny-all per namespace:**
   ```yaml
   apiVersion: security.istio.io/v1
   kind: AuthorizationPolicy
   metadata:
     name: deny-all
     namespace: production
   spec: {}
   ```

3. **Explicit ALLOW policies for each service pair.**

4. **Unique ServiceAccounts per workload:**
   ```yaml
   apiVersion: v1
   kind: ServiceAccount
   metadata:
     name: frontend-sa
     namespace: production
   ```

5. **Lock down egress:** Set `outboundTrafficPolicy.mode: REGISTRY_ONLY`.

6. **Rotate certificates frequently:** Default 24h is good; consider shorter for
   high-security environments.

7. **Audit AuthorizationPolicies regularly:** Use `istioctl analyze` to check for
   misconfigurations.

8. **Enable access logging:** For audit trail and forensics.

9. **Use NetworkPolicies alongside Istio policies** for defense in depth.

10. **Pin trusted root CAs:** Don't use self-signed CAs in production. Integrate with
    enterprise PKI.

### Common Pitfalls

1. **Empty spec = deny all:** An AuthorizationPolicy with `spec: {}` denies all traffic
   to the namespace. This is intentional but often surprises teams.

2. **RequestAuthentication alone doesn't enforce JWT:** It only validates present tokens.
   Use AuthorizationPolicy to require `requestPrincipals: ["*"]`.

3. **PERMISSIVE doesn't mean secure:** Traffic is encrypted only when both sides have
   sidecars. Non-mesh services communicate in plaintext.

4. **Wildcard principals are dangerous:** `principals: ["*"]` matches any identity,
   including from other namespaces. Be specific.

5. **DENY before ALLOW:** DENY policies always win, regardless of order. You cannot
   override a DENY with an ALLOW.

6. **Port-named protocols matter:** Istio infers protocol from port names (e.g.,
   `http-web`, `grpc-api`). Wrong naming leads to wrong security behavior.

7. **Shared ServiceAccounts break isolation:** If two services share a ServiceAccount,
   AuthorizationPolicy cannot distinguish between them.

8. **ext-authz failOpen:** Setting `failOpen: true` means authorization is skipped when
   the ext-authz provider is unreachable. Use `false` in production.

9. **JWT clock skew:** Configure `jwtRules[].clockSkew` if tokens are rejected due to
   time differences between services.

10. **Ambient mode security differences:** In ambient mesh, L4 security is handled by
    ztunnel (always on), but L7 authorization requires a waypoint proxy.
