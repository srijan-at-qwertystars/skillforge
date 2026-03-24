# Advanced JWT Patterns

## Table of Contents

- [Token Families and Lineage Tracking](#token-families-and-lineage-tracking)
- [Sliding Window Refresh](#sliding-window-refresh)
- [Proof-of-Possession Tokens](#proof-of-possession-tokens)
- [DPoP (Demonstrating Proof-of-Possession)](#dpop-demonstrating-proof-of-possession)
- [JWT-Based Sessions at Scale](#jwt-based-sessions-at-scale)
- [Distributed Revocation](#distributed-revocation)
- [Audience-Scoped Tokens](#audience-scoped-tokens)
- [Nested JWTs](#nested-jwts)
- [JWE Encryption](#jwe-encryption)
- [Token Downscoping](#token-downscoping)
- [Cross-Service Token Exchange (RFC 8693)](#cross-service-token-exchange-rfc-8693)

---

## Token Families and Lineage Tracking

A **token family** is a chain of refresh tokens originating from a single authentication event. Every refresh token rotation produces a new member of the same family.

### Data Model

```sql
CREATE TABLE refresh_tokens (
    jti         UUID PRIMARY KEY,
    family_id   UUID NOT NULL,          -- shared across the lineage
    user_id     UUID NOT NULL,
    parent_jti  UUID,                   -- NULL for the root token
    issued_at   TIMESTAMPTZ NOT NULL,
    expires_at  TIMESTAMPTZ NOT NULL,
    revoked_at  TIMESTAMPTZ,            -- non-null = revoked
    replaced_by UUID,                   -- jti of successor token
    INDEX idx_family (family_id),
    INDEX idx_user   (user_id)
);
```

### Rotation Flow

```
1. User logs in → issue RT_0 with family_id=F, parent_jti=NULL
2. Client uses RT_0 → issue RT_1 (family_id=F, parent_jti=RT_0.jti)
   Mark RT_0 as replaced_by=RT_1.jti
3. Client uses RT_1 → issue RT_2, mark RT_1 replaced
...
```

### Reuse Detection

If a client presents RT_0 after RT_1 has already been issued:

```python
def refresh(token):
    rt = db.get_refresh_token(token.jti)
    if rt.revoked_at or rt.replaced_by:
        # REUSE DETECTED — compromise assumed
        db.revoke_family(rt.family_id)  # revoke ALL tokens in family
        alert_security_team(rt.user_id, rt.family_id)
        raise TokenReusedError()
    # Normal rotation continues...
    new_rt = issue_refresh_token(family_id=rt.family_id, parent_jti=rt.jti)
    db.mark_replaced(rt.jti, new_rt.jti)
    return new_rt
```

Key rules:
- **One active leaf** per family at all times.
- Reuse of any non-leaf token → revoke the entire family.
- Log the reuse event with IP, user-agent, and timestamps for forensics.
- Optionally force re-authentication after family revocation.

### Cleanup

Run periodic cleanup to remove expired families:

```sql
DELETE FROM refresh_tokens
WHERE expires_at < NOW() - INTERVAL '30 days'
  AND revoked_at IS NOT NULL;
```

---

## Sliding Window Refresh

Instead of a fixed refresh token expiry, extend the refresh window each time the token is used. This keeps active users logged in while expiring idle sessions.

### Mechanism

```
Initial login:   refresh_token.exp = now + 30 days
First refresh:   new_refresh_token.exp = now + 30 days   (window slides)
Idle for 30 days: refresh_token expires, user must re-login
```

### Implementation

```python
REFRESH_WINDOW = timedelta(days=30)
ABSOLUTE_MAX = timedelta(days=90)  # hard cap regardless of activity

def refresh_with_sliding_window(old_rt):
    original_auth_time = old_rt.claims["auth_time"]
    elapsed = datetime.now(UTC) - datetime.fromtimestamp(original_auth_time, UTC)

    if elapsed > ABSOLUTE_MAX:
        raise ReauthenticationRequired("Session exceeded absolute maximum")

    new_exp = datetime.now(UTC) + REFRESH_WINDOW
    max_allowed = datetime.fromtimestamp(original_auth_time, UTC) + ABSOLUTE_MAX
    new_exp = min(new_exp, max_allowed)

    return issue_refresh_token(
        user_id=old_rt.claims["sub"],
        exp=new_exp,
        auth_time=original_auth_time,  # preserve original auth time
    )
```

Key rules:
- Always include `auth_time` claim to track the original authentication.
- Set an **absolute maximum** (e.g., 90 days) beyond which re-authentication is required regardless of activity.
- The sliding window is for UX convenience; the absolute max is for security.

---

## Proof-of-Possession Tokens

Standard bearer tokens are vulnerable to theft — anyone who has the token can use it. **Proof-of-possession (PoP)** tokens bind the token to a cryptographic key held by the client, so stolen tokens are useless without the key.

### Concept

```
1. Client generates an ephemeral key pair (pub/priv)
2. Client sends public key during authentication
3. Server embeds a "cnf" (confirmation) claim in the JWT with a key thumbprint
4. On each API call, client signs a challenge or the request with the private key
5. Server verifies both the JWT AND the proof-of-possession signature
```

### Token with `cnf` Claim (RFC 7800)

```json
{
  "sub": "user_8a3f",
  "iss": "auth.example.com",
  "exp": 1719000000,
  "cnf": {
    "jkt": "0ZcOCORZNYy-DWpqq30jZyJGHTN0d2HglBV3uiguA4I"
  }
}
```

The `jkt` (JWK Thumbprint, RFC 7638) is a hash of the client's public key. The server computes the thumbprint of the key used to sign the proof and compares it to `jkt`.

### Verification Flow

```python
def verify_pop_request(access_token, pop_signature, request_data):
    claims = verify_jwt(access_token)
    expected_thumbprint = claims["cnf"]["jkt"]

    # Extract client's public key from the PoP header or DPoP proof
    client_pub_key = extract_client_key(pop_signature)
    actual_thumbprint = compute_jwk_thumbprint(client_pub_key)

    if actual_thumbprint != expected_thumbprint:
        raise InvalidProof("Key thumbprint mismatch")

    if not verify_signature(pop_signature, client_pub_key, request_data):
        raise InvalidProof("PoP signature verification failed")

    return claims
```

---

## DPoP (Demonstrating Proof-of-Possession)

DPoP (RFC 9449) is the standardized approach to proof-of-possession for OAuth 2.0. It's simpler to adopt than mTLS-based PoP.

### How It Works

```
1. Client generates an ephemeral key pair (per session or per device)
2. On token request: client sends a DPoP proof JWT signed with private key
3. Server issues access token with "cnf" claim containing JWK thumbprint
4. On each API call: client sends a fresh DPoP proof in the "DPoP" header
5. Resource server verifies both access token AND DPoP proof
```

### DPoP Proof JWT Structure

```json
// Header
{
  "typ": "dpop+jwt",
  "alg": "ES256",
  "jwk": {
    "kty": "EC",
    "crv": "P-256",
    "x": "...",
    "y": "..."
  }
}
// Payload
{
  "jti": "unique-proof-id",
  "htm": "POST",              // HTTP method
  "htu": "https://api.example.com/resource",  // HTTP URI
  "iat": 1718999100,
  "ath": "fUHyO2r2Z3DZ53EsNrWBb0xWXoaNy59IiKCAqksmQEo"  // access token hash
}
```

### Server-Side Verification

```javascript
async function verifyDPoP(dpopProof, accessToken, method, url) {
  // 1. Decode DPoP proof header — extract embedded JWK
  const { header, payload } = decodeJwt(dpopProof);
  if (header.typ !== 'dpop+jwt') throw new Error('Invalid DPoP type');

  // 2. Verify DPoP proof signature using the embedded public key
  const pubKey = importJWK(header.jwk);
  if (!verifySignature(dpopProof, pubKey)) throw new Error('Bad DPoP sig');

  // 3. Check method and URL binding
  if (payload.htm !== method) throw new Error('Method mismatch');
  if (payload.htu !== url) throw new Error('URL mismatch');

  // 4. Check freshness (iat within acceptable window)
  if (Math.abs(Date.now()/1000 - payload.iat) > 60) throw new Error('Stale DPoP');

  // 5. Check jti uniqueness (prevent replay)
  if (await isJtiUsed(payload.jti)) throw new Error('DPoP replay');
  await markJtiUsed(payload.jti, ttl=120);

  // 6. Verify access token's cnf.jkt matches DPoP key thumbprint
  const atClaims = verifyJwt(accessToken);
  const thumbprint = computeJwkThumbprint(header.jwk);
  if (atClaims.cnf?.jkt !== thumbprint) throw new Error('Key binding mismatch');

  return atClaims;
}
```

### When to Use DPoP

- Public clients (SPAs, mobile apps) where client secrets can't be safely stored.
- High-security APIs (financial, healthcare) where bearer token theft is a concern.
- Environments where mTLS is impractical (e.g., browser-based clients).

---

## JWT-Based Sessions at Scale

### Architecture for High-Traffic Systems

```
┌──────────┐     ┌────────────┐     ┌─────────────┐
│  Client   │────▶│  API GW /  │────▶│  Service A  │
│           │     │  Load Bal. │     │  (validates  │
│           │     │            │     │   locally)   │
│           │     │  Caches    │     └─────────────┘
│           │     │  JWKS      │────▶│  Service B  │
│           │     └────────────┘     │  (validates  │
│           │                        │   locally)   │
└──────────┘                        └─────────────┘
```

### JWKS Caching Strategy

```python
import httpx
from cachetools import TTLCache

class JWKSProvider:
    def __init__(self, jwks_url: str):
        self.jwks_url = jwks_url
        self._cache = TTLCache(maxsize=10, ttl=300)  # 5-min cache
        self._http = httpx.Client(timeout=5)

    def get_key(self, kid: str):
        if kid in self._cache:
            return self._cache[kid]

        # Cache miss — fetch JWKS
        resp = self._http.get(self.jwks_url)
        resp.raise_for_status()
        jwks = resp.json()

        for key_data in jwks["keys"]:
            self._cache[key_data["kid"]] = key_data

        if kid not in self._cache:
            raise KeyNotFoundError(f"Unknown kid: {kid}")
        return self._cache[kid]
```

### Performance Considerations

| Concern | Solution |
|---------|----------|
| JWKS fetch latency | Cache with TTL (5 min). Prefetch on startup. |
| Signature verification CPU | ES256 verify: ~0.5ms. RS256: ~0.1ms. Use ES256 for smaller tokens. |
| Token size in headers | Keep claims minimal. Use claim references (DB lookup by `sub`). |
| Clock skew across services | Allow 30s leeway. Use NTP on all servers. |
| Thundering herd on JWKS refresh | Use single-flight pattern (only one goroutine/thread fetches). |

### Stateless Authorization Patterns

**Embedded permissions** — fast but inflexible:
```json
{ "sub": "u_1", "roles": ["admin"], "perms": ["users:read", "users:write"] }
```

**Claim reference** — flexible but adds latency:
```json
{ "sub": "u_1", "scope": "api" }
// Service looks up permissions from DB/cache by sub
```

**Hybrid** — embed coarse role, look up fine-grained permissions:
```json
{ "sub": "u_1", "role": "editor", "org": "org_42" }
// Service checks: does editor in org_42 have access to this resource?
```

---

## Distributed Revocation

### Redis-Based Token Blocklist

```python
import redis

r = redis.Redis(host="revocation-redis", port=6379, db=0)

def revoke_token(jti: str, exp: int):
    """Add token to blocklist with TTL matching token expiry."""
    ttl = exp - int(time.time())
    if ttl > 0:
        r.setex(f"revoked:{jti}", ttl, "1")

def is_revoked(jti: str) -> bool:
    return r.exists(f"revoked:{jti}") > 0

def revoke_user_tokens(user_id: str):
    """Increment user's token version — all existing tokens become invalid."""
    r.incr(f"token_ver:{user_id}")

def get_token_version(user_id: str) -> int:
    ver = r.get(f"token_ver:{user_id}")
    return int(ver) if ver else 0
```

### Database-Backed Revocation with Cache

```python
class HybridRevocationStore:
    """DB as source of truth, Redis as read cache."""

    def __init__(self, db, redis_client):
        self.db = db
        self.redis = redis_client

    async def revoke(self, jti: str, exp: int):
        # Write to DB (durable)
        await self.db.execute(
            "INSERT INTO revoked_tokens (jti, revoked_at, expires_at) VALUES ($1, NOW(), $2)",
            jti, datetime.fromtimestamp(exp, UTC)
        )
        # Write to Redis (fast reads)
        ttl = exp - int(time.time())
        if ttl > 0:
            await self.redis.setex(f"revoked:{jti}", ttl, "1")

    async def is_revoked(self, jti: str) -> bool:
        # Check Redis first (fast path)
        if await self.redis.exists(f"revoked:{jti}"):
            return True
        # Fallback to DB (cache miss or Redis down)
        row = await self.db.fetchone(
            "SELECT 1 FROM revoked_tokens WHERE jti = $1 AND expires_at > NOW()", jti
        )
        if row:
            # Backfill Redis
            await self.redis.setex(f"revoked:{jti}", 3600, "1")
            return True
        return False
```

### Event-Driven Revocation (Pub/Sub)

For multi-instance deployments, broadcast revocations:

```python
# Publisher (auth service)
async def revoke_and_broadcast(jti: str, exp: int):
    await revocation_store.revoke(jti, exp)
    await redis.publish("token:revoked", json.dumps({"jti": jti, "exp": exp}))

# Subscriber (each API instance)
async def listen_revocations():
    pubsub = redis.pubsub()
    await pubsub.subscribe("token:revoked")
    async for message in pubsub.listen():
        if message["type"] == "message":
            data = json.loads(message["data"])
            local_blocklist.add(data["jti"], ttl=data["exp"] - time.time())
```

---

## Audience-Scoped Tokens

Issue different access tokens for different downstream services, each with a specific `aud` claim.

### Multi-Audience Architecture

```
Auth Server issues:
  Token A: { aud: "api.example.com",     scope: "read write",  exp: +15m }
  Token B: { aud: "billing.example.com", scope: "billing:read", exp: +15m }
  Token C: { aud: "admin.example.com",   scope: "admin:full",   exp: +5m  }
```

### Token Exchange for Audience Scoping

```python
@app.post("/auth/token-exchange")
async def exchange_token(request: TokenExchangeRequest):
    """Exchange a broad token for an audience-scoped token (RFC 8693)."""
    source_claims = verify_jwt(request.subject_token)

    # Verify the user is allowed to access the target audience
    if request.audience not in get_allowed_audiences(source_claims["sub"]):
        raise HTTPException(403, "Not authorized for this audience")

    # Issue a narrowly-scoped token
    scoped_token = issue_jwt(
        sub=source_claims["sub"],
        aud=request.audience,
        scope=compute_scoped_permissions(source_claims, request.audience),
        exp=timedelta(minutes=15),
        act={"sub": source_claims["sub"]},  # actor claim for audit trail
    )
    return {"access_token": scoped_token, "token_type": "bearer"}
```

### Validation Rules per Service

Each service MUST validate that `aud` matches its own identifier:

```python
# billing-service/auth.py
EXPECTED_AUDIENCE = "billing.example.com"

def verify_token(token: str):
    return jwt.decode(token, key,
        algorithms=["ES256"],
        audience=EXPECTED_AUDIENCE,  # MUST match
        issuer="auth.example.com",
    )
```

---

## Nested JWTs

A nested JWT is a JWT that is both signed and encrypted: sign first, then encrypt. The outer layer is a JWE containing the signed JWT as its payload.

### Structure

```
JWE( JWS( payload ) )

Outer (JWE): encrypted envelope — only the intended recipient can read it
Inner (JWS): signed payload — guarantees integrity and authenticity
```

### When to Use

- Tokens transiting through intermediaries (API gateways, proxies) that should not read claims.
- Tokens containing sensitive PII (email, phone) that must be encrypted at rest and in transit.
- Cross-organization token exchange where confidentiality matters.

### Creation (using jose library in Node.js)

```javascript
import { SignJWT, CompactEncrypt, importJWK } from 'jose';

async function createNestedJWT(payload, signingKey, encryptionKey) {
  // Step 1: Sign the JWT
  const signedJWT = await new SignJWT(payload)
    .setProtectedHeader({ alg: 'ES256', typ: 'JWT' })
    .setIssuedAt()
    .setExpirationTime('15m')
    .sign(signingKey);

  // Step 2: Encrypt the signed JWT
  const nestedJWT = await new CompactEncrypt(
    new TextEncoder().encode(signedJWT)
  )
    .setProtectedHeader({
      alg: 'RSA-OAEP-256',     // key encryption algorithm
      enc: 'A256GCM',           // content encryption algorithm
      cty: 'JWT',               // content type = nested JWT
    })
    .encrypt(encryptionKey);

  return nestedJWT;
}
```

### Decryption and Verification

```javascript
import { compactDecrypt, jwtVerify, importJWK } from 'jose';

async function verifyNestedJWT(nestedJWT, decryptionKey, verificationKey) {
  // Step 1: Decrypt outer JWE layer
  const { plaintext, protectedHeader } = await compactDecrypt(
    nestedJWT, decryptionKey
  );

  if (protectedHeader.cty !== 'JWT') {
    throw new Error('Expected nested JWT (cty: JWT)');
  }

  // Step 2: Verify inner JWS layer
  const signedJWT = new TextDecoder().decode(plaintext);
  const { payload } = await jwtVerify(signedJWT, verificationKey, {
    algorithms: ['ES256'],
    issuer: 'auth.example.com',
  });

  return payload;
}
```

---

## JWE Encryption

When you need encrypted tokens (without nesting), use JWE directly.

### JWE Compact Serialization

```
BASE64URL(header) . BASE64URL(encrypted_key) . BASE64URL(iv) . BASE64URL(ciphertext) . BASE64URL(tag)
```

### Algorithm Choices

| Key Management (`alg`) | Content Encryption (`enc`) | Use Case |
|------------------------|---------------------------|----------|
| `RSA-OAEP-256` | `A256GCM` | Standard asymmetric encryption |
| `ECDH-ES+A256KW` | `A256GCM` | Smaller overhead with EC keys |
| `dir` | `A256GCM` | Direct symmetric key (shared secret) |
| `A256KW` | `A256GCM` | Symmetric key wrap |

### Direct Encryption Example (Python, jwcrypto)

```python
from jwcrypto import jwk, jwe
import json

# Generate a symmetric key for direct encryption
key = jwk.JWK.generate(kty='oct', size=256)

# Encrypt
payload = json.dumps({"sub": "user_1", "email": "user@example.com"}).encode()
jwe_token = jwe.JWE(payload,
    protected=json.dumps({
        "alg": "dir",
        "enc": "A256GCM",
        "typ": "JWT",
    })
)
jwe_token.add_recipient(key)
encrypted = jwe_token.serialize(compact=True)

# Decrypt
jwe_recv = jwe.JWE()
jwe_recv.deserialize(encrypted)
jwe_recv.decrypt(key)
claims = json.loads(jwe_recv.payload)
```

---

## Token Downscoping

Issue a new token with reduced permissions from a broader token. Useful for:
- Delegating limited access to third-party services.
- Applying least-privilege when forwarding tokens between microservices.

### Implementation

```python
@app.post("/auth/downscope")
async def downscope_token(request: DownscopeRequest):
    parent_claims = verify_jwt(request.access_token)

    requested_scopes = set(request.scopes)
    parent_scopes = set(parent_claims.get("scope", "").split())

    # Downscoped token can ONLY have a subset of parent permissions
    if not requested_scopes.issubset(parent_scopes):
        raise HTTPException(403, "Cannot escalate permissions")

    downscoped = issue_jwt(
        sub=parent_claims["sub"],
        scope=" ".join(requested_scopes),
        aud=request.target_audience or parent_claims["aud"],
        exp=min(
            datetime.now(UTC) + timedelta(minutes=15),
            datetime.fromtimestamp(parent_claims["exp"], UTC),  # never exceed parent
        ),
        parent_jti=parent_claims["jti"],  # audit trail
    )
    return {"access_token": downscoped, "scope": " ".join(requested_scopes)}
```

---

## Cross-Service Token Exchange (RFC 8693)

Standard protocol for exchanging one security token for another with different properties.

### Request Format

```http
POST /oauth/token HTTP/1.1
Content-Type: application/x-www-form-urlencoded

grant_type=urn:ietf:params:oauth:grant-type:token-exchange
&subject_token=<original-jwt>
&subject_token_type=urn:ietf:params:oauth:token-type:jwt
&audience=billing-service
&scope=billing:read billing:write
&requested_token_type=urn:ietf:params:oauth:token-type:jwt
```

### Response

```json
{
  "access_token": "<new-jwt-for-billing-service>",
  "issued_token_type": "urn:ietf:params:oauth:token-type:jwt",
  "token_type": "bearer",
  "expires_in": 900,
  "scope": "billing:read billing:write"
}
```

### Implementation Considerations

- Validate the source token fully before issuing exchange.
- The exchanged token MUST NOT have broader permissions than the source.
- Include `act` (actor) claim for delegation audit trails.
- Rate-limit token exchange endpoints aggressively.
- Log all exchanges with source and target details for security audit.
