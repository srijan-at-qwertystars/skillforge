---
name: jwt-auth
description: >
  Implement JWT (JSON Web Token) authentication and authorization.
  Use when: user mentions "JWT token", "JSON Web Token", "access token refresh",
  "token-based auth", "JWT validation", "JWT signing", "bearer token",
  "refresh token rotation", "token expiration", "JWT middleware",
  "token-based API security", "stateless authentication", "JWT claims".
  Do NOT use when: user wants "session-based auth without tokens",
  "OAuth2 authorization server setup", "API key authentication",
  "SAML/SSO federation", "basic auth", "cookie-only session management",
  "OpenID Connect provider implementation", "certificate-based mTLS auth".
  Covers JWT structure, signing algorithms (HS256/RS256/ES256/EdDSA),
  access+refresh token patterns, storage, validation, revocation,
  key rotation, security hardening, and implementation in Node.js/Python/Go.
---

# JWT Authentication

## JWT Structure

A JWT has three Base64url-encoded parts separated by dots: `header.payload.signature`.

**Header** — declares token type and signing algorithm:
```json
{ "alg": "RS256", "typ": "JWT", "kid": "key-2024-06" }
```

**Payload** — contains claims (assertions about the subject):
```json
{
  "sub": "user_8a3f", "iss": "auth.example.com", "aud": "api.example.com",
  "exp": 1719000000, "iat": 1718999100, "nbf": 1718999100,
  "roles": ["admin"], "tenant_id": "t_42"
}
```

**Signature** — computed over `base64url(header) + "." + base64url(payload)` using the algorithm specified in the header and the signing key.

## Standard Claims (RFC 7519)

| Claim | Purpose | Required? |
|-------|---------|-----------|
| `iss` | Issuer identifier | Always set |
| `sub` | Subject (user ID) | Always set |
| `aud` | Intended audience | Always validate |
| `exp` | Expiration (Unix timestamp) | Always set |
| `nbf` | Not valid before | Recommended |
| `iat` | Issued at | Recommended |
| `jti` | Unique token ID | Use for revocation |

Custom claims: prefix with a namespace (`app:role`, `x-tenant`) to avoid collisions. Keep payloads small — every byte is sent on every request.

## Signing Algorithms

### Symmetric (shared secret)
- **HS256** (HMAC-SHA256): Same secret signs and verifies. Use only when signer and verifier are the same service. Secret MUST be ≥256 bits (32 bytes) of cryptographic randomness.
- **HS384/HS512**: Larger HMAC variants. Use HS256 unless compliance requires otherwise.

### Asymmetric (key pair)
- **RS256** (RSA-SHA256): 2048-bit RSA minimum. Private key signs, public key verifies. Widely supported. Use for multi-service architectures.
- **ES256** (ECDSA P-256): Smaller keys/signatures than RSA, equivalent security. Preferred for new systems.
- **EdDSA** (Ed25519): Fastest, smallest signatures, strongest security properties. Use when library support exists across your stack.

### Algorithm Selection Rules
1. Multi-service or public verification → RS256, ES256, or EdDSA.
2. Single service, internal only → HS256 acceptable.
3. NEVER allow `alg: "none"` in production. Pin the expected algorithm in verification code — do not read it from the token header.
4. Prefer ES256 or EdDSA for new greenfield projects.

## Access Token + Refresh Token Pattern

```
Login → issue access_token (15m) + refresh_token (7d)
API call → send access_token in Authorization header
Token expired → POST /auth/refresh with refresh_token → new access_token
Logout → revoke refresh_token server-side, clear client storage
```

**Access token**: Short-lived (5–30 min). Stateless. Sent as `Authorization: Bearer <token>`. Contains user identity and permissions. Never store server-side.

**Refresh token**: Longer-lived (1–30 days). Stored server-side (DB/Redis) for revocation. Opaque string or JWT. Issue a new refresh token on each use (rotation). Detect reuse — if an old refresh token is presented, revoke the entire token family.

## Token Storage

### Browser Applications
| Method | XSS Safe | CSRF Safe | Recommendation |
|--------|----------|-----------|----------------|
| httpOnly + Secure + SameSite=Strict cookie | ✅ | ✅ | **Best for refresh tokens** |
| httpOnly + Secure + SameSite=Lax cookie | ✅ | Partial | Good default |
| In-memory variable (JS) | Partial | ✅ | Good for access tokens in SPAs |
| localStorage | ❌ | ✅ | **Avoid** — exposed to XSS |
| sessionStorage | ❌ | ✅ | **Avoid** — exposed to XSS |

**Preferred pattern for SPAs**: Store refresh token in httpOnly cookie. Store access token in memory only (JS variable). On page reload, call `/auth/refresh` to get a new access token.

### Mobile / Server Applications
Use OS keychain (iOS Keychain, Android Keystore) or secure environment variables. Never store tokens in shared preferences, plain files, or source code.

## Token Validation and Verification

Verify every token on every request. Follow this exact order:

1. **Parse** the JWT and extract the header.
2. **Check algorithm** — reject if `alg` is not in your allowlist. Never trust the token's `alg` field blindly.
3. **Select key** — use `kid` header to look up the correct verification key. Sanitize `kid` — never use it in file paths or SQL.
4. **Verify signature** — using the pinned algorithm and selected key.
5. **Check `exp`** — reject expired tokens. Allow ≤30s clock skew maximum.
6. **Check `nbf`** — reject tokens not yet valid.
7. **Check `iss`** — must match your expected issuer.
8. **Check `aud`** — must include your service's audience identifier.
9. **Extract claims** — use validated claims for authorization.

## Token Revocation Strategies

JWTs are stateless — revocation requires a server-side mechanism:

1. **Short expiry + refresh rotation**: Primary strategy. Access tokens expire in minutes. Refresh tokens rotated on each use. Compromised access token has limited window.
2. **Token blocklist**: Store revoked `jti` values in Redis/DB with TTL matching token expiry. Check on each request. Use for immediate revocation (logout, password change).
3. **Token versioning**: Store a `token_version` per user in DB. Encode version in JWT. Increment on logout/password change. Reject tokens with old version.
4. **Refresh token family tracking**: Track token lineage. If a previously-rotated refresh token is reused, revoke the entire family (indicates theft).

## Key Rotation

1. **Generate new key pair** with a new `kid` identifier.
2. **Publish both old and new public keys** via JWKS endpoint (`/.well-known/jwks.json`).
3. **Start signing new tokens** with the new key.
4. **Wait for old tokens to expire** (max access token lifetime).
5. **Remove old public key** from JWKS endpoint.

JWKS endpoint response format:
```json
{
  "keys": [
    { "kty": "EC", "kid": "key-2024-06", "crv": "P-256", "x": "...", "y": "..." },
    { "kty": "EC", "kid": "key-2024-01", "crv": "P-256", "x": "...", "y": "..." }
  ]
}
```

Rotate keys every 90 days minimum. Use a key management service (AWS KMS, GCP KMS, HashiCorp Vault) to store private keys. Never store private keys in source code or environment variables in production.

## Security Best Practices

- Set `exp` to 5–15 minutes for access tokens.
- Always validate `iss`, `aud`, `exp`, `nbf` on every request.
- Pin signing algorithm in verification code — never read from token.
- Use asymmetric keys (RS256/ES256/EdDSA) for multi-service systems.
- Generate secrets with cryptographic RNG: `openssl rand -base64 64`.
- Never log full JWTs — log only `jti` or a hash.
- Transmit tokens only over HTTPS.
- Set refresh token cookies: `httpOnly`, `Secure`, `SameSite=Strict`, `Path=/auth/refresh`.
- Implement rate limiting on `/auth/refresh` and `/auth/login`.
- Invalidate all refresh tokens on password change.
- Use `jti` claim for critical tokens to enable individual revocation.

## Common Vulnerabilities

### `alg: "none"` Attack
Attacker modifies header to `{"alg":"none"}` and removes signature. **Fix**: Always pin expected algorithm — never accept `none`.

### Algorithm Confusion (RS256 → HS256)
Attacker changes `alg` to HS256 and signs with the RSA public key as HMAC secret. **Fix**: Pin algorithm per key. Never allow algorithm switching.

### Weak HMAC Secrets
Short or predictable secrets can be brute-forced. **Fix**: Use ≥256 bits of cryptographic randomness. Never use passwords, English words, or short strings.

### Token Leakage via URL
Tokens in query strings end up in server logs, browser history, and Referer headers. **Fix**: Send tokens in `Authorization` header or httpOnly cookies only.

### `kid` Injection
Attacker manipulates `kid` to read arbitrary files or inject SQL. **Fix**: Validate `kid` against an allowlist. Never concatenate into paths or queries.

### Unbounded Token Lifetime
Tokens without `exp` or with very long expiry. **Fix**: Always set short `exp`. Require `exp` claim in validation.

## Implementation Examples

### Node.js (Express + jsonwebtoken)

```js
import jwt from 'jsonwebtoken';
import crypto from 'crypto';

// --- Configuration ---
const ACCESS_SECRET = process.env.JWT_ACCESS_SECRET;  // ≥32 bytes random
const REFRESH_SECRET = process.env.JWT_REFRESH_SECRET;
const ACCESS_EXPIRY = '15m';
const REFRESH_EXPIRY = '7d';

// --- Token Generation ---
function generateTokens(user) {
  const jti = crypto.randomUUID();
  const accessToken = jwt.sign(
    { sub: user.id, roles: user.roles, jti },
    ACCESS_SECRET,
    { expiresIn: ACCESS_EXPIRY, issuer: 'auth.example.com', audience: 'api.example.com' }
  );
  const refreshToken = jwt.sign(
    { sub: user.id, jti: crypto.randomUUID() },
    REFRESH_SECRET,
    { expiresIn: REFRESH_EXPIRY, issuer: 'auth.example.com' }
  );
  // Store refreshToken jti in DB for revocation tracking
  return { accessToken, refreshToken };
}

// --- Middleware: Verify Access Token ---
function authenticate(req, res, next) {
  const header = req.headers.authorization;
  if (!header?.startsWith('Bearer ')) return res.status(401).json({ error: 'Missing token' });
  try {
    const decoded = jwt.verify(header.slice(7), ACCESS_SECRET, {
      algorithms: ['HS256'],         // Pin algorithm
      issuer: 'auth.example.com',
      audience: 'api.example.com',
      clockTolerance: 30,
    });
    req.user = decoded;
    next();
  } catch (err) {
    return res.status(401).json({ error: 'Invalid token' });
  }
}

// --- Refresh Endpoint ---
app.post('/auth/refresh', (req, res) => {
  const token = req.cookies.refreshToken;
  if (!token) return res.status(401).json({ error: 'No refresh token' });
  try {
    const decoded = jwt.verify(token, REFRESH_SECRET, { algorithms: ['HS256'] });
    // Check jti against DB blocklist; reject if revoked
    // Issue new tokens (rotation)
    const tokens = generateTokens({ id: decoded.sub, roles: decoded.roles });
    // Revoke old refresh token jti in DB
    res.cookie('refreshToken', tokens.refreshToken, {
      httpOnly: true, secure: true, sameSite: 'strict', path: '/auth/refresh',
      maxAge: 7 * 24 * 60 * 60 * 1000,
    });
    res.json({ accessToken: tokens.accessToken });
  } catch {
    res.status(401).json({ error: 'Invalid refresh token' });
  }
});
```

### Python (PyJWT + Flask)

```python
import jwt
import uuid
from datetime import datetime, timedelta, timezone
from functools import wraps
from flask import Flask, request, jsonify, make_response

ACCESS_SECRET = "load-from-env-min-32-bytes"  # Use os.environ in production
REFRESH_SECRET = "different-secret-also-32-bytes"
ALGORITHM = "HS256"

def generate_tokens(user_id: str, roles: list[str]) -> dict:
    now = datetime.now(timezone.utc)
    access = jwt.encode({
        "sub": user_id, "roles": roles, "jti": str(uuid.uuid4()),
        "exp": now + timedelta(minutes=15),
        "iat": now, "iss": "auth.example.com", "aud": "api.example.com",
    }, ACCESS_SECRET, algorithm=ALGORITHM)
    refresh = jwt.encode({
        "sub": user_id, "jti": str(uuid.uuid4()),
        "exp": now + timedelta(days=7), "iat": now,
    }, REFRESH_SECRET, algorithm=ALGORITHM)
    return {"access_token": access, "refresh_token": refresh}

def require_auth(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        header = request.headers.get("Authorization", "")
        if not header.startswith("Bearer "):
            return jsonify(error="Missing token"), 401
        try:
            decoded = jwt.decode(header[7:], ACCESS_SECRET,
                algorithms=[ALGORITHM],  # Pin algorithm
                issuer="auth.example.com", audience="api.example.com",
                options={"require": ["exp", "sub", "iss", "aud"]})
            request.user = decoded
        except jwt.ExpiredSignatureError:
            return jsonify(error="Token expired"), 401
        except jwt.InvalidTokenError:
            return jsonify(error="Invalid token"), 401
        return f(*args, **kwargs)
    return decorated

@app.route("/auth/refresh", methods=["POST"])
def refresh():
    token = request.cookies.get("refresh_token")
    if not token:
        return jsonify(error="No refresh token"), 401
    try:
        decoded = jwt.decode(token, REFRESH_SECRET, algorithms=[ALGORITHM])
        # Validate jti against DB; reject if revoked
        tokens = generate_tokens(decoded["sub"], decoded.get("roles", []))
        resp = make_response(jsonify(access_token=tokens["access_token"]))
        resp.set_cookie("refresh_token", tokens["refresh_token"],
            httponly=True, secure=True, samesite="Strict", path="/auth/refresh",
            max_age=7*24*3600)
        return resp
    except jwt.InvalidTokenError:
        return jsonify(error="Invalid refresh token"), 401
```

### Go (golang-jwt/jwt/v5)

```go
package auth

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"net/http"
	"strings"
	"time"
	"github.com/golang-jwt/jwt/v5"
)

var accessSecret = []byte("load-from-env-min-32-bytes")

type Claims struct {
	Roles []string `json:"roles"`
	jwt.RegisteredClaims
}

func GenerateAccessToken(userID string, roles []string) (string, error) {
	jti := make([]byte, 16)
	rand.Read(jti)
	claims := Claims{
		Roles: roles,
		RegisteredClaims: jwt.RegisteredClaims{
			Subject:   userID,
			Issuer:    "auth.example.com",
			Audience:  jwt.ClaimStrings{"api.example.com"},
			ExpiresAt: jwt.NewNumericDate(time.Now().Add(15 * time.Minute)),
			IssuedAt:  jwt.NewNumericDate(time.Now()),
			ID:        hex.EncodeToString(jti),
		},
	}
	return jwt.NewWithClaims(jwt.SigningMethodHS256, claims).SignedString(accessSecret)
}

func AuthMiddleware(next http.Handler) http.Handler {
	parser := jwt.NewParser(
		jwt.WithValidMethods([]string{"HS256"}), // Pin algorithm
		jwt.WithIssuer("auth.example.com"),
		jwt.WithAudience("api.example.com"),
		jwt.WithLeeway(30*time.Second),
	)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		auth := r.Header.Get("Authorization")
		if !strings.HasPrefix(auth, "Bearer ") {
			http.Error(w, `{"error":"missing token"}`, http.StatusUnauthorized)
			return
		}
		token, err := parser.ParseWithClaims(auth[7:], &Claims{},
			func(t *jwt.Token) (interface{}, error) {
				if _, ok := t.Method.(*jwt.SigningMethodHMAC); !ok {
					return nil, fmt.Errorf("unexpected signing method: %v", t.Header["alg"])
				}
				return accessSecret, nil
			})
		if err != nil || !token.Valid {
			http.Error(w, `{"error":"invalid token"}`, http.StatusUnauthorized)
			return
		}
		// Attach claims to request context, call next handler
		next.ServeHTTP(w, r)
	})
}
```

## Example Input/Output

**Login request:**
```
POST /auth/login
Content-Type: application/json
{"email": "user@example.com", "password": "correct-password"}
```

**Login response:**
```json
{
  "access_token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1c2VyXzhhM2YiLCJyb2xlcyI6WyJhZG1pbiJdLCJleHAiOjE3MTkwMDAwMDB9.signature",
  "token_type": "bearer",
  "expires_in": 900
}
```
Set-Cookie: `refreshToken=<opaque>; HttpOnly; Secure; SameSite=Strict; Path=/auth/refresh`

**Authenticated API call:**
```
GET /api/users/me
Authorization: Bearer eyJhbGciOiJIUzI1Ni...
→ 200 {"id": "user_8a3f", "email": "user@example.com", "roles": ["admin"]}
```

**Expired token:**
```
GET /api/users/me
Authorization: Bearer <expired-token>
→ 401 {"error": "Token expired"}
```

**Refresh flow:**
```
POST /auth/refresh
Cookie: refreshToken=<valid-refresh-token>
→ 200 {"access_token": "<new-access-token>", "expires_in": 900}
+ Set-Cookie: refreshToken=<new-rotated-refresh-token>; ...
```

**Invalid/revoked refresh token:**
```
POST /auth/refresh
Cookie: refreshToken=<revoked-token>
→ 401 {"error": "Invalid refresh token"}
```
