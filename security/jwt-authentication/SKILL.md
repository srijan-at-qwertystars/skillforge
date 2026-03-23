---
name: jwt-authentication
description: >
  Use when user implements JWT auth, asks about access/refresh token patterns,
  token validation, claims design, key rotation, RS256 vs HS256, or JWT security
  hardening. Do NOT use for session-based authentication, OAuth2 flows (use oauth
  skill), API key auth, or general cryptography questions.
---

# JWT Authentication

## JWT Structure

A JWT has three base64url-encoded parts separated by dots: `header.payload.signature`.

```
eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1c2VyXzkyMSIsImlzcyI6ImF1dGguZXhhbXBsZS5jb20iLCJhdWQiOiJhcGkuZXhhbXBsZS5jb20iLCJleHAiOjE3MzUwMDAwMDAsImlhdCI6MTczNDk5NjQwMCwianRpIjoiYWJjMTIzIiwicm9sZSI6ImFkbWluIn0.signature_bytes
```

Decoded:
```json
// Header
{ "alg": "RS256", "typ": "JWT", "kid": "key-2025-01" }

// Payload
{
  "sub": "user_921",
  "iss": "auth.example.com",
  "aud": "api.example.com",
  "exp": 1735000000,
  "iat": 1734996400,
  "nbf": 1734996400,
  "jti": "abc123",
  "role": "admin"
}

// Signature = RS256(base64url(header) + "." + base64url(payload), privateKey)
```

## Algorithm Selection

| Algorithm | Type | Key | Use When |
|-----------|------|-----|----------|
| HS256 | Symmetric | Shared secret | Single service, both signer and verifier are the same server |
| RS256 | Asymmetric | RSA key pair | Distributed systems, public key verification, JWKS endpoints |
| ES256 | Asymmetric | ECDSA P-256 | Same as RS256 but smaller keys/signatures, better performance |

**Decision guide:**

- Single monolith → HS256 with ≥256-bit secret.
- Microservices or third-party consumers → RS256 or ES256. Publish public keys via JWKS.
- Performance-sensitive with many verifiers → ES256 (smaller signatures, faster verification).
- Never use `none`. Never allow the client to choose the algorithm.

## Claims Design

### Registered Claims (RFC 7519)

| Claim | Purpose | Required? |
|-------|---------|-----------|
| `iss` | Issuer identifier | Yes |
| `sub` | Subject (user ID) | Yes |
| `aud` | Intended audience (API identifier) | Yes |
| `exp` | Expiration time (Unix timestamp) | Yes |
| `nbf` | Not valid before | Recommended |
| `iat` | Issued at | Recommended |
| `jti` | Unique token ID (for revocation/replay prevention) | Recommended |

### Custom Claims

Keep claims minimal. Never store sensitive data (passwords, SSNs, credit cards) in the payload—it is base64-encoded, not encrypted.

```json
{
  "sub": "user_921",
  "role": "editor",
  "permissions": ["read", "write"],
  "org_id": "org_42",
  "token_version": 3
}
```

Use namespaced keys for custom claims in multi-tenant systems: `"https://example.com/roles"`.

## Access + Refresh Token Pattern

```
Client                    Auth Server                 API Server
  |--- POST /login -------->|                            |
  |<-- access_token (15m) --|                            |
  |<-- refresh_token (7d) --|                            |
  |                          |                            |
  |--- GET /api (access) ----|-------------------------->|
  |<-- 200 OK ---------------|<--------------------------|
  |                          |                            |
  |  [access token expires]  |                            |
  |--- POST /refresh ------->|                            |
  |    (refresh_token)       |                            |
  |<-- new access_token -----|                            |
  |<-- new refresh_token ----|  (old refresh revoked)     |
```

**Access token:** 5–15 minutes. Stateless verification. Contains user identity and permissions.

**Refresh token:** 7–14 days. Stored server-side (DB or Redis). Opaque string or JWT.

### Refresh Token Rotation

Issue a new refresh token on every refresh. Immediately invalidate the old one.

```python
def refresh(request):
    old_token = request.refresh_token
    record = db.get_refresh_token(old_token)

    if not record:
        # Token reuse detected — revoke entire family
        db.revoke_token_family(record.family_id)
        raise AuthError("Token reuse detected. Session invalidated.")

    if record.revoked:
        db.revoke_token_family(record.family_id)
        raise AuthError("Compromised token family revoked.")

    db.revoke(old_token)

    new_refresh = generate_refresh_token(family_id=record.family_id)
    new_access = generate_access_token(user_id=record.user_id)
    db.store_refresh_token(new_refresh)

    return new_access, new_refresh
```

## Token Storage

### Browser Storage Comparison

| Method | XSS Safe? | CSRF Safe? | Notes |
|--------|-----------|------------|-------|
| `httpOnly` + `Secure` cookie | Yes | No (needs CSRF token) | Preferred for web apps |
| `localStorage` | No | Yes | Vulnerable to XSS — avoid for sensitive tokens |
| `sessionStorage` | No | Yes | Lost on tab close; still XSS-vulnerable |
| In-memory (JS variable) | Yes | Yes | Lost on refresh; use with silent refresh flow |

**Recommended browser pattern:** Store access token in memory, refresh token in `httpOnly` + `Secure` + `SameSite=Strict` cookie. Use a `/refresh` endpoint to get new access tokens.

```javascript
// Server: Set refresh token as httpOnly cookie
res.cookie('refresh_token', token, {
  httpOnly: true,
  secure: true,
  sameSite: 'strict',
  path: '/api/auth/refresh',
  maxAge: 7 * 24 * 60 * 60 * 1000 // 7 days
});

// Client: Store access token in memory only
let accessToken = null;

async function apiCall(url, options = {}) {
  if (!accessToken || isExpired(accessToken)) {
    accessToken = await refreshAccessToken();
  }
  return fetch(url, {
    ...options,
    headers: { ...options.headers, Authorization: `Bearer ${accessToken}` }
  });
}
```

## Validation Checklist

Validate every incoming JWT on every request. Check in this order:

1. **Parse structure** — Reject malformed tokens (not 3 dot-separated segments).
2. **Verify algorithm** — Match against server-side allowlist. Never trust the token's `alg` header blindly.
3. **Verify signature** — Use the correct key (identified by `kid` if using JWKS).
4. **Check `exp`** — Reject expired tokens. Allow ≤30s clock skew max.
5. **Check `nbf`** — Reject tokens not yet valid.
6. **Check `iss`** — Match against expected issuer.
7. **Check `aud`** — Match against this service's identifier.
8. **Check `jti`** — Optionally check against revocation blocklist.
9. **Validate custom claims** — Verify roles, permissions, scopes as needed.

```javascript
// Node.js with jose
import { jwtVerify } from 'jose';

async function validateToken(token, publicKey) {
  const { payload } = await jwtVerify(token, publicKey, {
    issuer: 'auth.example.com',
    audience: 'api.example.com',
    algorithms: ['RS256'],
    clockTolerance: 30
  });
  return payload;
}
```

## Key Management and Rotation

### Key Rotation Strategy

1. Generate new key pair. Assign a unique `kid` (key ID).
2. Add new public key to JWKS endpoint. Keep old public key available.
3. Start signing new tokens with the new private key.
4. After `max_token_lifetime` passes, remove old public key from JWKS.
```json
// JWKS endpoint response (/.well-known/jwks.json)
{
  "keys": [
    { "kid": "key-2025-06", "kty": "RSA", "use": "sig", "alg": "RS256", "n": "...", "e": "AQAB" },
    { "kid": "key-2025-01", "kty": "RSA", "use": "sig", "alg": "RS256", "n": "...", "e": "AQAB" }
  ]
}
```

### Key Storage

- Never hardcode secrets in source code. Use environment variables or a secrets manager (AWS KMS, HashiCorp Vault, GCP Secret Manager).
- For asymmetric keys, store private keys in HSMs or managed key services.

```bash
# Generate RS256 key pair
openssl genrsa -out private.pem 2048
openssl rsa -in private.pem -pubout -out public.pem

# Generate ES256 key pair
openssl ecparam -genkey -name prime256v1 -noout -out ec-private.pem
openssl ec -in ec-private.pem -pubout -out ec-public.pem
```

## Common Vulnerabilities and Mitigations

### 1. Algorithm None Attack

**Attack:** Attacker sets `"alg": "none"` and strips the signature.

**Mitigation:** Always enforce an algorithm allowlist server-side. Never accept `none`.

```python
# WRONG — vulnerable
payload = jwt.decode(token, options={"verify_signature": False})

# CORRECT
payload = jwt.decode(token, key, algorithms=["RS256"])
```

### 2. Key Confusion (RSA/HMAC)

**Attack:** Server expects RS256. Attacker sends HS256 token signed with the public key (which is publicly available).

**Mitigation:** Pin the algorithm. Never let the token header dictate which algorithm to use.

```go
// Go with golang-jwt — pin the algorithm
token, err := jwt.Parse(tokenString, func(t *jwt.Token) (interface{}, error) {
    if _, ok := t.Method.(*jwt.SigningMethodRSA); !ok {
        return nil, fmt.Errorf("unexpected signing method: %v", t.Header["alg"])
    }
    return publicKey, nil
})
```

### 3. Token Sidejacking

**Attack:** Attacker steals token via XSS, network sniffing, or log exposure.
**Mitigation:** Transmit tokens only over HTTPS. Store in `httpOnly` cookies (not `localStorage`). Bind tokens to client fingerprint when possible. Use short expiry windows.

### 4. JWT Replay

**Attack:** Attacker captures a valid token and reuses it.
**Mitigation:** Include `jti` claim with a unique ID. Maintain a server-side seen-JTI cache (Redis with TTL matching token expiry). Use one-time-use tokens for sensitive operations.

```python
def validate_jti(token_payload):
    jti = token_payload["jti"]
    if redis.exists(f"used_jti:{jti}"):
        raise AuthError("Token already used")
    redis.setex(f"used_jti:{jti}", token_payload["exp"] - time.time(), "1")
```

### 5. Insufficient Claim Validation

**Attack:** Token issued for Service A is used against Service B.
**Mitigation:** Always validate `aud` and `iss`. Each service must reject tokens not intended for it.

## Implementation Patterns

### Node.js (using `jose`)

```javascript
import { SignJWT, jwtVerify, generateKeyPair } from 'jose';

// Generate keys
const { publicKey, privateKey } = await generateKeyPair('RS256');

// Sign
const token = await new SignJWT({ sub: 'user_921', role: 'admin' })
  .setProtectedHeader({ alg: 'RS256', kid: 'key-2025-06' })
  .setIssuedAt()
  .setIssuer('auth.example.com')
  .setAudience('api.example.com')
  .setExpirationTime('15m')
  .setJti(crypto.randomUUID())
  .sign(privateKey);

// Verify
const { payload } = await jwtVerify(token, publicKey, {
  issuer: 'auth.example.com',
  audience: 'api.example.com',
  algorithms: ['RS256']
});
```

### Python (using `PyJWT`)

```python
import jwt
import uuid
from datetime import datetime, timedelta, timezone

private_key = open("private.pem").read()
public_key = open("public.pem").read()

# Sign
token = jwt.encode(
    {
        "sub": "user_921",
        "iss": "auth.example.com",
        "aud": "api.example.com",
        "exp": datetime.now(timezone.utc) + timedelta(minutes=15),
        "iat": datetime.now(timezone.utc),
        "jti": str(uuid.uuid4()),
        "role": "admin",
    },
    private_key,
    algorithm="RS256",
    headers={"kid": "key-2025-06"},
)

# Verify
payload = jwt.decode(
    token,
    public_key,
    algorithms=["RS256"],
    audience="api.example.com",
    issuer="auth.example.com",
)
```

### Go (using `golang-jwt/jwt/v5`)

```go
import (
    "crypto/rsa"
    "time"
    "github.com/golang-jwt/jwt/v5"
    "github.com/google/uuid"
)

// Sign
claims := jwt.MapClaims{
    "sub":  "user_921",
    "iss":  "auth.example.com",
    "aud":  "api.example.com",
    "exp":  time.Now().Add(15 * time.Minute).Unix(),
    "iat":  time.Now().Unix(),
    "jti":  uuid.New().String(),
    "role": "admin",
}
token := jwt.NewWithClaims(jwt.SigningMethodRS256, claims)
token.Header["kid"] = "key-2025-06"
signed, err := token.SignedString(privateKey)

// Verify
parsed, err := jwt.Parse(signed, func(t *jwt.Token) (interface{}, error) {
    if _, ok := t.Method.(*jwt.SigningMethodRSA); !ok {
        return nil, fmt.Errorf("unexpected method: %v", t.Header["alg"])
    }
    return publicKey, nil
}, jwt.WithIssuer("auth.example.com"),
   jwt.WithAudience("api.example.com"),
   jwt.WithValidMethods([]string{"RS256"}))
```

## Token Revocation Strategies

| Strategy | Latency | Complexity | Use When |
|----------|---------|------------|----------|
| Short expiry (5–15 min) | Up to expiry window | Low | Most apps; combine with refresh rotation |
| Blocklist (Redis/DB) | Immediate | Medium | Need instant revocation (logout, password change) |
| Token versioning | Immediate (requires DB check) | Medium | Per-user invalidation (store version in user record) |
| Event-based propagation | Near-real-time | High | Microservices; publish revocation events via message bus |

### Blocklist Implementation

```python
# On logout or password change
def revoke_token(jti: str, exp: int):
    ttl = exp - int(time.time())
    if ttl > 0:
        redis.setex(f"revoked:{jti}", ttl, "1")

# In auth middleware
def is_revoked(jti: str) -> bool:
    return redis.exists(f"revoked:{jti}")
```

### Token Versioning

```python
# User record has token_version field
def validate_token_version(payload, user):
    if payload.get("token_version") != user.token_version:
        raise AuthError("Token invalidated")

# To revoke all tokens for a user, increment token_version
def revoke_all_user_tokens(user_id):
    db.execute("UPDATE users SET token_version = token_version + 1 WHERE id = %s", user_id)
```

## Testing JWT Flows

### Unit Tests

```python
import pytest
import jwt
from datetime import datetime, timedelta, timezone
from freezegun import freeze_time

def test_valid_token_accepted():
    token = create_token(sub="user_1", exp_minutes=15)
    payload = validate_token(token)
    assert payload["sub"] == "user_1"

def test_expired_token_rejected():
    with freeze_time("2025-01-01 12:00:00"):
        token = create_token(sub="user_1", exp_minutes=15)
    with freeze_time("2025-01-01 12:30:00"):
        with pytest.raises(jwt.ExpiredSignatureError):
            validate_token(token)

def test_wrong_audience_rejected():
    token = create_token(sub="user_1", aud="wrong.api.com")
    with pytest.raises(jwt.InvalidAudienceError):
        validate_token(token)

def test_wrong_algorithm_rejected():
    token = jwt.encode({"sub": "user_1"}, "secret", algorithm="HS256")
    with pytest.raises(jwt.InvalidAlgorithmError):
        validate_token(token)  # expects RS256

def test_revoked_token_rejected():
    token = create_token(sub="user_1", jti="abc123")
    revoke_token("abc123", exp=9999999999)
    with pytest.raises(AuthError):
        validate_token(token)
```

### Integration Tests

```python
def test_refresh_rotation(client):
    login = client.post("/auth/login", json={"email": "u@x.com", "password": "pass"})
    refresh_1 = login.json()["refresh_token"]

    # First refresh succeeds
    r1 = client.post("/auth/refresh", json={"refresh_token": refresh_1})
    assert r1.status_code == 200
    refresh_2 = r1.json()["refresh_token"]

    # Reusing old refresh token triggers family revocation
    r2 = client.post("/auth/refresh", json={"refresh_token": refresh_1})
    assert r2.status_code == 401

    # New refresh token is also revoked (family invalidation)
    r3 = client.post("/auth/refresh", json={"refresh_token": refresh_2})
    assert r3.status_code == 401

def test_logout_revokes_token(client, auth_headers):
    client.post("/auth/logout", headers=auth_headers)
    r = client.get("/api/protected", headers=auth_headers)
    assert r.status_code == 401
```

### Security Test Checklist

- [ ] Token with `alg: none` is rejected.
- [ ] Token signed with wrong key is rejected.
- [ ] Expired token is rejected.
- [ ] Token with wrong `aud` is rejected.
- [ ] Token with wrong `iss` is rejected.
- [ ] Token with `nbf` in the future is rejected.
- [ ] Reused refresh token triggers family revocation.
- [ ] Revoked token (via blocklist) is rejected.
- [ ] Token with tampered payload is rejected.
- [ ] HS256 token is rejected when RS256 is expected (key confusion).

<!-- tested: needs-fix -->
