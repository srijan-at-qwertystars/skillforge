# Advanced JWT Patterns

## Table of Contents

- [JWE — Encrypted Tokens](#jwe--encrypted-tokens)
- [Token Binding and DPoP](#token-binding-and-dpop-rfc-9449)
- [Microservice Token Exchange (RFC 8693)](#microservice-token-exchange-rfc-8693)
- [JWT in gRPC and Non-HTTP Protocols](#jwt-in-grpc-and-non-http-protocols)
- [Multi-Tenant JWT Patterns](#multi-tenant-jwt-patterns)
- [Scoped Tokens and Fine-Grained Permissions](#scoped-tokens-and-fine-grained-permissions)
- [JWT Profiles for OAuth (RFC 7523)](#jwt-profiles-for-oauth-rfc-7523)
- [PASETO vs JWT](#paseto-vs-jwt)
- [Embedded Refresh in BFF Architectures](#embedded-refresh-in-bff-architectures)
- [Token Size Optimization](#token-size-optimization)

---

## JWE — Encrypted Tokens

JWS (signed tokens) guarantee integrity but expose claims in base64url-encoded plaintext. JWE adds confidentiality — the payload is encrypted and unreadable without the decryption key.

### When to use JWE

- Tokens contain PII or sensitive data that must not be visible to intermediaries (proxies, CDNs, browser devtools).
- Regulatory requirements (GDPR, HIPAA) mandate encryption of personal data in transit beyond TLS.
- Tokens pass through untrusted intermediaries (third-party API gateways).

### JWE structure

A JWE compact serialization has five parts:

```
BASE64URL(Header).BASE64URL(EncryptedKey).BASE64URL(IV).BASE64URL(Ciphertext).BASE64URL(AuthTag)
```

### JWE in Node.js (using `jose`)

```javascript
import { CompactEncrypt, compactDecrypt, generateKeyPair } from 'jose';

// Generate RSA-OAEP key pair for encryption
const { publicKey, privateKey } = await generateKeyPair('RSA-OAEP-256');

// Encrypt
const encoder = new TextEncoder();
const jwe = await new CompactEncrypt(encoder.encode(JSON.stringify({
  sub: 'user_921',
  email: 'user@example.com',  // PII — needs encryption
  role: 'admin'
})))
  .setProtectedHeader({ alg: 'RSA-OAEP-256', enc: 'A256GCM' })
  .encrypt(publicKey);

// Decrypt
const { plaintext } = await compactDecrypt(jwe, privateKey);
const payload = JSON.parse(new TextDecoder().decode(plaintext));
```

### JWE in Python (using `python-jose`)

```python
from jose import jwe
import json

# RSA-OAEP + A256GCM
public_key = open("rsa-public.pem").read()
private_key = open("rsa-private.pem").read()

# Encrypt
token = jwe.encrypt(
    json.dumps({"sub": "user_921", "email": "user@example.com"}).encode(),
    public_key,
    algorithm="RSA-OAEP-256",
    encryption="A256GCM",
)

# Decrypt
payload = json.loads(jwe.decrypt(token, private_key))
```

### Nested JWE+JWS (sign-then-encrypt)

When you need both integrity (signature) and confidentiality (encryption), nest a JWS inside a JWE. Sign first, then encrypt — the receiver decrypts first, then verifies the signature.

```javascript
import { SignJWT, jwtVerify, CompactEncrypt, compactDecrypt } from 'jose';

// Step 1: Sign the payload (JWS)
const jws = await new SignJWT({ sub: 'user_921', email: 'user@example.com' })
  .setProtectedHeader({ alg: 'ES256' })
  .setIssuedAt()
  .setExpirationTime('15m')
  .sign(signingPrivateKey);

// Step 2: Encrypt the signed token (JWE wrapping JWS)
const nested = await new CompactEncrypt(new TextEncoder().encode(jws))
  .setProtectedHeader({
    alg: 'RSA-OAEP-256',
    enc: 'A256GCM',
    cty: 'JWT'  // MUST set cty to 'JWT' for nested tokens per RFC 7516
  })
  .encrypt(encryptionPublicKey);

// Receiving side: decrypt then verify
const { plaintext } = await compactDecrypt(nested, encryptionPrivateKey);
const innerJws = new TextDecoder().decode(plaintext);
const { payload } = await jwtVerify(innerJws, signingPublicKey);
```

### Algorithm choices for JWE

| Key Management (`alg`) | Content Encryption (`enc`) | Use Case |
|------------------------|---------------------------|----------|
| `RSA-OAEP-256` | `A256GCM` | General purpose, wide library support |
| `ECDH-ES+A256KW` | `A256GCM` | Smaller keys, forward secrecy with ephemeral ECDH |
| `dir` | `A256GCM` | Symmetric direct encryption — both parties share the key |
| `A256KW` | `A256CBC-HS512` | Symmetric key wrapping, legacy compatibility |

---

## Token Binding and DPoP (RFC 9449)

Standard bearer tokens are vulnerable to theft — anyone possessing the token can use it. DPoP (Demonstrating Proof of Possession) binds a token to a specific client key pair so stolen tokens are useless without the corresponding private key.

### How DPoP works

1. Client generates an ephemeral key pair (per session or per device).
2. On each request, client creates a DPoP proof — a JWS signed with the private key containing the HTTP method, URL, and a unique `jti`.
3. Auth server binds the access token to the client's public key via a `cnf` (confirmation) claim.
4. Resource server verifies both the access token AND the DPoP proof.

### DPoP flow

```
Client                         Auth Server                    Resource Server
  |                               |                               |
  |-- Token Request ------------->|                               |
  |   + DPoP: proof (signed      |                               |
  |     with client privkey)      |                               |
  |                               |                               |
  |<-- Access Token --------------|                               |
  |   token_type: "DPoP"          |                               |
  |   cnf.jkt: thumbprint of      |                               |
  |            client pubkey       |                               |
  |                               |                               |
  |-- API Request ------------------------------------------>|
  |   Authorization: DPoP <token>                             |
  |   DPoP: proof (htm, htu, ath, jti)                        |
  |                               |                               |
  |   [Server verifies: proof signature matches cnf.jkt,      |
  |    htm matches method, htu matches URL, ath matches token] |
```

### DPoP proof structure

```javascript
import { SignJWT, generateKeyPair, exportJWK, calculateJwkThumbprint } from 'jose';

const { publicKey, privateKey } = await generateKeyPair('ES256');
const publicJwk = await exportJWK(publicKey);

// Create DPoP proof for a specific request
async function createDPoPProof(method, url, accessToken = null) {
  const builder = new SignJWT({
    htm: method,           // HTTP method
    htu: url,              // Target URL (without query/fragment)
    iat: Math.floor(Date.now() / 1000),
    jti: crypto.randomUUID(),
    ...(accessToken && {
      ath: await hashAccessToken(accessToken)  // SHA-256 of access token
    })
  })
    .setProtectedHeader({
      alg: 'ES256',
      typ: 'dpop+jwt',
      jwk: publicJwk       // Embed public key in header
    });

  return builder.sign(privateKey);
}

// Usage: attach to requests
const dpopProof = await createDPoPProof('GET', 'https://api.example.com/resource', accessToken);
fetch('https://api.example.com/resource', {
  headers: {
    'Authorization': `DPoP ${accessToken}`,
    'DPoP': dpopProof
  }
});
```

### Server-side DPoP validation

```python
import hashlib, base64, json
from jose import jwk, jws

def validate_dpop(dpop_proof: str, method: str, url: str, access_token: str):
    # 1. Decode DPoP header to get embedded public key
    header = json.loads(base64url_decode(dpop_proof.split('.')[0]))
    assert header['typ'] == 'dpop+jwt'
    assert 'jwk' in header

    # 2. Verify signature using embedded public key
    public_key = jwk.construct(header['jwk'])
    payload = json.loads(jws.verify(dpop_proof, public_key, algorithms=['ES256']))

    # 3. Validate claims
    assert payload['htm'] == method
    assert payload['htu'] == url
    assert abs(payload['iat'] - time.time()) < 60  # Clock tolerance

    # 4. Verify access token hash
    expected_ath = base64url_encode(hashlib.sha256(access_token.encode()).digest())
    assert payload['ath'] == expected_ath

    # 5. Return JWK thumbprint to match against token's cnf.jkt
    return calculate_jwk_thumbprint(header['jwk'])
```

---

## Microservice Token Exchange (RFC 8693)

When Service A needs to call Service B on behalf of a user, the original user token often has the wrong audience/scopes. OAuth 2.0 Token Exchange (RFC 8693) standardizes how services obtain appropriately scoped tokens.

### Exchange types

| Grant Type | Description | Use Case |
|------------|-------------|----------|
| Delegation | Service acts on behalf of user (`may_act` claim) | API gateway calling downstream services |
| Impersonation | New token represents user directly (no `act` claim) | Internal microservice-to-microservice |
| Reduce scope | Exchange broad token for narrower one | Least-privilege for specific operations |

### Token exchange request

```bash
# Service A exchanges user's token for a token scoped to Service B
curl -X POST https://auth.example.com/oauth/token \
  -d grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
  -d subject_token=<user_access_token> \
  -d subject_token_type=urn:ietf:params:oauth:token-type:access_token \
  -d audience=service-b.example.com \
  -d scope="read:orders" \
  -d requested_token_type=urn:ietf:params:oauth:token-type:access_token
```

### Delegation token with `act` claim

```json
{
  "sub": "user_921",
  "iss": "auth.example.com",
  "aud": "service-b.example.com",
  "act": {
    "sub": "service-a@clients"
  },
  "scope": "read:orders",
  "exp": 1735000000
}
```

### Implementation (Node.js auth server)

```javascript
app.post('/oauth/token', async (req, res) => {
  if (req.body.grant_type !== 'urn:ietf:params:oauth:grant-type:token-exchange') {
    return res.status(400).json({ error: 'unsupported_grant_type' });
  }

  // Validate the incoming subject token
  const subjectPayload = await validateToken(req.body.subject_token);

  // Verify the requesting service is allowed to exchange
  const clientId = authenticateClient(req);
  const exchangePolicy = await getExchangePolicy(clientId, req.body.audience);
  if (!exchangePolicy.allowed) {
    return res.status(403).json({ error: 'unauthorized_client' });
  }

  // Scope reduction: issued scopes must be subset of policy-allowed scopes
  const requestedScopes = req.body.scope?.split(' ') || exchangePolicy.defaultScopes;
  const grantedScopes = requestedScopes.filter(s => exchangePolicy.allowedScopes.includes(s));

  // Issue new token scoped to the target audience
  const exchangedToken = await new SignJWT({
    sub: subjectPayload.sub,
    aud: req.body.audience,
    scope: grantedScopes.join(' '),
    act: { sub: clientId },  // delegation chain
    original_jti: subjectPayload.jti
  })
    .setProtectedHeader({ alg: 'RS256' })
    .setIssuedAt()
    .setExpirationTime('5m')  // Short-lived exchanged tokens
    .setIssuer('auth.example.com')
    .sign(privateKey);

  res.json({
    access_token: exchangedToken,
    issued_token_type: 'urn:ietf:params:oauth:token-type:access_token',
    token_type: 'Bearer',
    expires_in: 300,
    scope: grantedScopes.join(' ')
  });
});
```

---

## JWT in gRPC and Non-HTTP Protocols

### gRPC metadata-based JWT

gRPC uses metadata (equivalent to HTTP headers) for token transmission. Attach JWTs as metadata entries.

```go
// Go gRPC client — attach JWT as per-RPC credential
import (
    "context"
    "google.golang.org/grpc"
    "google.golang.org/grpc/credentials/oauth"
)

// Using grpc.PerRPCCredentials
type jwtCredentials struct {
    token string
}

func (j *jwtCredentials) GetRequestMetadata(ctx context.Context, uri ...string) (map[string]string, error) {
    return map[string]string{
        "authorization": "Bearer " + j.token,
    }, nil
}

func (j *jwtCredentials) RequireTransportSecurity() bool {
    return true  // Always require TLS
}

conn, err := grpc.Dial("api.example.com:443",
    grpc.WithPerRPCCredentials(&jwtCredentials{token: accessToken}),
    grpc.WithTransportCredentials(creds),
)
```

```go
// Go gRPC server — unary interceptor for JWT validation
func jwtUnaryInterceptor(
    ctx context.Context,
    req interface{},
    info *grpc.UnaryServerInfo,
    handler grpc.UnaryHandler,
) (interface{}, error) {
    md, ok := metadata.FromIncomingContext(ctx)
    if !ok {
        return nil, status.Error(codes.Unauthenticated, "missing metadata")
    }

    authHeader := md.Get("authorization")
    if len(authHeader) == 0 {
        return nil, status.Error(codes.Unauthenticated, "missing authorization")
    }

    token := strings.TrimPrefix(authHeader[0], "Bearer ")
    claims, err := validateJWT(token)
    if err != nil {
        return nil, status.Error(codes.Unauthenticated, "invalid token")
    }

    // Inject claims into context for downstream handlers
    ctx = context.WithValue(ctx, claimsKey, claims)
    return handler(ctx, req)
}

server := grpc.NewServer(grpc.UnaryInterceptor(jwtUnaryInterceptor))
```

### JWT over WebSocket

Attach the JWT during the WebSocket handshake (as a query parameter or in the protocol upgrade headers), then optionally re-validate on a heartbeat interval.

```javascript
// Client: pass JWT during WebSocket connection
const ws = new WebSocket('wss://api.example.com/ws', {
  headers: { 'Authorization': `Bearer ${accessToken}` }
});

// Browser WebSocket API doesn't support custom headers — use a ticket pattern:
// 1. POST /ws/ticket with Bearer token → get short-lived ticket
// 2. Connect: new WebSocket(`wss://api.example.com/ws?ticket=${ticket}`)
```

```javascript
// Server: validate on connection and periodically
wss.on('connection', (ws, req) => {
  const ticket = new URL(req.url, 'wss://base').searchParams.get('ticket');
  const claims = validateTicket(ticket);  // Verify ticket, map to user
  if (!claims) return ws.close(4001, 'Unauthorized');

  ws.userId = claims.sub;
  ws.tokenExp = claims.exp;

  // Periodic re-auth check
  const interval = setInterval(() => {
    if (Date.now() / 1000 > ws.tokenExp) {
      ws.close(4001, 'Token expired');
      clearInterval(interval);
    }
  }, 60_000);
});
```

### JWT in MQTT (IoT)

```python
# MQTT 5.0: JWT in the password field or as an AUTH packet
import paho.mqtt.client as mqtt

client = mqtt.Client(protocol=mqtt.MQTTv5)
client.username_pw_set(username="device_42", password=jwt_token)
client.tls_set()  # Always use TLS
client.connect("mqtt.example.com", 8883)
```

---

## Multi-Tenant JWT Patterns

### Strategy 1: Tenant claim in the token

Simplest approach. All tenants share one auth server and one signing key. The `tenant_id` claim scopes every operation.

```json
{
  "sub": "user_921",
  "iss": "auth.example.com",
  "aud": "api.example.com",
  "tenant_id": "acme_corp",
  "role": "admin",
  "exp": 1735000000
}
```

```python
# Middleware: extract tenant and enforce isolation
def tenant_middleware(request):
    claims = validate_token(request.token)
    request.tenant_id = claims["tenant_id"]

    # Enforce tenant isolation at the query level
    # Every DB query MUST filter by tenant_id
    request.db = get_tenant_scoped_session(request.tenant_id)
```

### Strategy 2: Audience per tenant

Each tenant gets a unique audience. Token issued for Tenant A is cryptographically rejected by Tenant B's API.

```json
{
  "sub": "user_921",
  "iss": "auth.example.com",
  "aud": "https://acme-corp.api.example.com",
  "role": "admin"
}
```

### Strategy 3: Separate signing keys per tenant

Maximum isolation. Each tenant has its own key pair. Compromise of one tenant's key doesn't affect others.

```json
// JWKS endpoint returns keys tagged by tenant
{
  "keys": [
    { "kid": "acme-2025-01", "kty": "EC", "crv": "P-256", "x": "...", "y": "..." },
    { "kid": "globex-2025-01", "kty": "EC", "crv": "P-256", "x": "...", "y": "..." }
  ]
}
```

```javascript
// Key resolution by tenant
async function getVerificationKey(header, token) {
  const tenantId = extractTenantFromRequest(req);  // from subdomain, path, or header
  const jwks = await fetchJWKS(`https://auth.example.com/${tenantId}/.well-known/jwks.json`);
  const key = jwks.keys.find(k => k.kid === header.kid);
  if (!key) throw new Error('Unknown key');
  return importJWK(key);
}
```

### Choosing a multi-tenant JWT strategy

| Strategy | Isolation | Complexity | Best For |
|----------|-----------|------------|----------|
| Tenant claim | Logical | Low | SaaS with shared infrastructure |
| Audience per tenant | Cryptographic (audience) | Medium | APIs with distinct tenant endpoints |
| Key per tenant | Cryptographic (signing) | High | Regulated industries, enterprise customers |

---

## Scoped Tokens and Fine-Grained Permissions

### OAuth 2.0 scopes in JWTs

```json
{
  "sub": "user_921",
  "scope": "read:users write:users read:orders",
  "exp": 1735000000
}
```

```python
# Scope enforcement middleware
def require_scope(*required_scopes):
    def decorator(handler):
        def wrapper(request):
            token_scopes = set(request.claims.get("scope", "").split())
            missing = set(required_scopes) - token_scopes
            if missing:
                raise ForbiddenError(f"Missing scopes: {missing}")
            return handler(request)
        return wrapper
    return decorator

@require_scope("read:orders")
def get_orders(request):
    ...
```

### Capability-based tokens

Instead of identity + role, the token itself encodes exactly what the bearer can do. Useful for temporary sharing, webhooks, and machine-to-machine.

```json
{
  "sub": "service_account_12",
  "capabilities": [
    { "resource": "orders/*", "actions": ["read"] },
    { "resource": "orders/order_555", "actions": ["read", "update"] },
    { "resource": "reports/daily", "actions": ["generate"] }
  ],
  "exp": 1735000000
}
```

```python
def check_capability(claims, resource, action):
    for cap in claims.get("capabilities", []):
        if fnmatch.fnmatch(resource, cap["resource"]) and action in cap["actions"]:
            return True
    raise ForbiddenError(f"No capability for {action} on {resource}")
```

### Downscoping tokens

Issue a narrower token from a broader one — useful when delegating to a less-trusted component.

```javascript
// Gateway receives a broad token, issues a narrow one for a specific downstream call
async function downscopeToken(broadToken, targetScopes, targetAudience) {
  const claims = await validateToken(broadToken);

  // Granted scopes must be a subset of original
  const originalScopes = new Set(claims.scope.split(' '));
  const narrowScopes = targetScopes.filter(s => originalScopes.has(s));

  return new SignJWT({
    sub: claims.sub,
    scope: narrowScopes.join(' '),
    aud: targetAudience,
    parent_jti: claims.jti  // Traceability back to original token
  })
    .setProtectedHeader({ alg: 'ES256' })
    .setExpirationTime('2m')
    .setIssuedAt()
    .sign(privateKey);
}
```

---

## JWT Profiles for OAuth (RFC 7523)

RFC 7523 defines how to use a JWT as a client authentication assertion or an authorization grant — eliminating the need for client secrets in service-to-service auth.

### JWT bearer for client authentication

Replace `client_id` + `client_secret` with a signed JWT assertion. The client proves its identity by signing with its private key.

```python
import jwt, time, uuid

def create_client_assertion(client_id, token_endpoint, private_key):
    now = int(time.time())
    return jwt.encode(
        {
            "iss": client_id,                    # Client identifier
            "sub": client_id,                    # Same as iss for client auth
            "aud": token_endpoint,               # Token endpoint URL
            "exp": now + 300,                    # 5-minute validity
            "iat": now,
            "jti": str(uuid.uuid4()),
        },
        private_key,
        algorithm="RS256",
        headers={"kid": "client-key-2025-01"},
    )

# Use in token request
assertion = create_client_assertion(
    "my-service-client",
    "https://auth.example.com/oauth/token",
    private_key
)

response = requests.post("https://auth.example.com/oauth/token", data={
    "grant_type": "client_credentials",
    "client_assertion_type": "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
    "client_assertion": assertion,
    "scope": "read:data"
})
```

### JWT bearer as authorization grant

Use a JWT issued by a trusted identity provider as an authorization grant to obtain an access token — common in Google Cloud service accounts.

```python
# Google-style service account JWT grant
def get_google_access_token(service_account_key):
    now = int(time.time())
    assertion = jwt.encode(
        {
            "iss": service_account_key["client_email"],
            "sub": service_account_key["client_email"],
            "aud": "https://oauth2.googleapis.com/token",
            "iat": now,
            "exp": now + 3600,
            "scope": "https://www.googleapis.com/auth/cloud-platform"
        },
        service_account_key["private_key"],
        algorithm="RS256"
    )

    resp = requests.post("https://oauth2.googleapis.com/token", data={
        "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
        "assertion": assertion
    })
    return resp.json()["access_token"]
```

---

## PASETO vs JWT

PASETO (Platform-Agnostic Security Tokens) is an alternative token format designed to eliminate JWT's footguns.

### Key differences

| Feature | JWT | PASETO |
|---------|-----|--------|
| Algorithm agility | Header specifies algorithm (source of vulnerabilities) | Version-locked — no algorithm choice |
| `none` algorithm | Possible (must be blocked) | Does not exist |
| Key confusion attacks | Possible (RSA/HMAC) | Impossible — version determines crypto |
| Encryption | JWE (separate spec, complex) | Built-in (local tokens = encrypted) |
| Ecosystem | Massive, universal | Smaller but growing |
| Standards body | IETF RFC 7519 | Community specification |

### PASETO versions

| Version | Signing (Public) | Encryption (Local) |
|---------|-------------------|---------------------|
| v4 | Ed25519 | XChaCha20-Poly1305 + BLAKE2b |
| v3 | ECDSA P-384 | AES-256-CTR + HMAC-SHA384 |

### PASETO example (Node.js with `paseto`)

```javascript
import { V4 } from 'paseto';
import { generateKeyPair } from 'crypto';

// Generate Ed25519 key pair
const { publicKey, secretKey } = await V4.generateKey('public');

// Sign (public token — equivalent to JWS)
const token = await V4.sign(
  { sub: 'user_921', role: 'admin', exp: '2025-07-01T00:00:00Z' },
  secretKey,
  { audience: 'api.example.com', issuer: 'auth.example.com' }
);
// Result: v4.public.eyJzdWIiOiJ1c2VyXzkyMSIs...

// Verify
const payload = await V4.verify(token, publicKey, {
  audience: 'api.example.com',
  issuer: 'auth.example.com'
});

// Encrypt (local token — equivalent to JWE, no signature)
const localKey = await V4.generateKey('local');
const encrypted = await V4.encrypt(
  { sub: 'user_921', email: 'user@example.com' },
  localKey
);
```

### When to prefer PASETO over JWT

- **Prefer PASETO** when: building a new system with no JWT interoperability requirements, you want to eliminate algorithm confusion by design, your language has a mature PASETO library.
- **Prefer JWT** when: integrating with OAuth 2.0/OIDC (mandatory JWT), interoperating with third-party services expecting JWT, using managed auth services (Auth0, Cognito, Firebase).

---

## Embedded Refresh in BFF Architectures

In the Backend for Frontend (BFF) pattern, the BFF server manages tokens on behalf of the SPA. The browser never sees JWTs — it only holds a session cookie to the BFF.

### Architecture

```
Browser (SPA)              BFF Server                Auth Server        API Server
    |                          |                          |                  |
    |-- Login form data ------>|                          |                  |
    |                          |-- Authorization Code --->|                  |
    |                          |<-- access + refresh -----|                  |
    |                          |   (stored server-side)   |                  |
    |<-- Set-Cookie: sid ------|                          |                  |
    |                          |                          |                  |
    |-- GET /api/data -------->|                          |                  |
    |   Cookie: sid            |-- GET /data ------------>|----------------->|
    |                          |   Authorization: Bearer  |                  |
    |<-- JSON response --------|<-- response -------------|<-----------------|
    |                          |                          |                  |
    |  [access token expired]  |                          |                  |
    |-- GET /api/data -------->|                          |                  |
    |   Cookie: sid            |-- POST /refresh -------->|                  |
    |                          |<-- new tokens -----------|                  |
    |                          |-- GET /data (retry) ---->|----------------->|
```

### BFF token management (Node.js/Express)

```javascript
import session from 'express-session';
import RedisStore from 'connect-redis';

// Session stores tokens server-side
app.use(session({
  store: new RedisStore({ client: redisClient }),
  secret: process.env.SESSION_SECRET,
  cookie: {
    httpOnly: true,
    secure: true,
    sameSite: 'strict',
    maxAge: 24 * 60 * 60 * 1000  // Session cookie: 24h
  },
  resave: false,
  saveUninitialized: false
}));

// Proxy middleware: attach token, handle refresh transparently
async function tokenProxy(req, res, next) {
  let { accessToken, refreshToken, tokenExpiry } = req.session.tokens || {};

  if (!accessToken) return res.status(401).json({ error: 'Not authenticated' });

  // Proactive refresh: refresh if token expires within 60 seconds
  if (tokenExpiry && Date.now() > (tokenExpiry - 60_000)) {
    try {
      const refreshed = await refreshTokens(refreshToken);
      req.session.tokens = {
        accessToken: refreshed.access_token,
        refreshToken: refreshed.refresh_token,
        tokenExpiry: Date.now() + refreshed.expires_in * 1000
      };
      accessToken = refreshed.access_token;
    } catch (err) {
      req.session.destroy();
      return res.status(401).json({ error: 'Session expired' });
    }
  }

  // Forward request to API with token
  req.headers['authorization'] = `Bearer ${accessToken}`;
  next();
}
```

### Advantages of BFF for JWT

- Tokens never reach the browser — immune to XSS token theft.
- Refresh logic is centralized — no client-side token management code.
- Can use `httpOnly` + `Secure` + `SameSite=Strict` session cookies — strongest browser security.
- Token rotation and revocation happen server-side without client coordination.

---

## Token Size Optimization

JWTs grow as you add claims. Large tokens cause real problems.

### Size limits to know

| Constraint | Limit | Impact |
|------------|-------|--------|
| HTTP `Authorization` header | ~8 KB (most servers) | Request rejected with 431 |
| Single cookie | 4,096 bytes | Cookie silently truncated or rejected |
| All cookies per domain | ~80 KB (browser-dependent) | Oldest cookies evicted |
| AWS ALB header | 16 KB | 502 Bad Gateway |
| Nginx default header buffer | 8 KB (`large_client_header_buffers`) | 400 Bad Request |
| Cloudflare header | 16 KB | 520 error |

### Strategy 1: Claim delegation (external claims)

Store large claim sets externally. The JWT contains only a reference.

```json
// Instead of embedding all permissions in the token:
{
  "sub": "user_921",
  "permissions_ref": "perm_set_abc123",
  "exp": 1735000000
}
```

```python
# Permission resolution at the API layer
async def resolve_permissions(claims):
    perm_ref = claims["permissions_ref"]
    # Cache aggressively — permissions change less often than tokens rotate
    perms = await cache.get(f"perms:{perm_ref}")
    if not perms:
        perms = await db.get_permission_set(perm_ref)
        await cache.set(f"perms:{perm_ref}", perms, ttl=300)
    return perms
```

### Strategy 2: Reference tokens (opaque tokens)

Replace the JWT entirely with an opaque string. The resource server introspects it with the auth server (RFC 7662).

```bash
# Token introspection request
curl -X POST https://auth.example.com/oauth/introspect \
  -u "client_id:client_secret" \
  -d token=dGhpcyBpcyBhbiBvcGFxdWUgdG9rZW4
```

```json
// Introspection response
{
  "active": true,
  "sub": "user_921",
  "scope": "read:users write:users",
  "client_id": "api-gateway",
  "exp": 1735000000,
  "permissions": ["users.read", "users.write", "orders.read", "reports.generate"]
}
```

**Trade-off:** Reference tokens require a network call per request. Mitigate with short-lived caching (15–60 seconds) at the resource server.

### Strategy 3: Split token pattern

Use a short JWT for authentication (identity only) and a separate mechanism for authorization data.

```javascript
// Short identity token (~200 bytes)
const identityToken = await new SignJWT({
  sub: 'user_921',
  tid: 'acme_corp'
})
  .setProtectedHeader({ alg: 'ES256' })
  .setExpirationTime('15m')
  .sign(privateKey);

// Authorization data loaded from cache/DB by middleware
async function authMiddleware(req, res, next) {
  const identity = await verifyToken(req.token);

  // Cache authorization data keyed by user + version
  const authData = await authCache.getOrLoad(
    `auth:${identity.sub}`,
    () => loadUserPermissions(identity.sub)
  );

  req.user = { ...identity, ...authData };
  next();
}
```

### Strategy 4: Compress claims

For large claim sets that must stay in the JWT, compress the payload before encoding.

```javascript
import { deflateSync, inflateSync } from 'zlib';

// Custom claim compression (non-standard — both sides must agree)
function compressClaims(claims) {
  const json = JSON.stringify(claims);
  const compressed = deflateSync(Buffer.from(json)).toString('base64url');
  return { _c: compressed };  // Single compressed claim
}

function decompressClaims(payload) {
  if (payload._c) {
    const decompressed = inflateSync(Buffer.from(payload._c, 'base64url'));
    return JSON.parse(decompressed.toString());
  }
  return payload;
}
```

### Decision matrix: when tokens get too large

| Token Size | Action |
|------------|--------|
| < 1 KB | Standard JWT — no optimization needed |
| 1–4 KB | Review claims — remove anything the API can look up itself |
| 4–8 KB | Use claim delegation or split token pattern |
| > 8 KB | Switch to reference tokens or BFF pattern |
