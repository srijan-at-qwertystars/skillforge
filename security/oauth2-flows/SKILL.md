---
name: oauth2-flows
description: >
  Comprehensive guide for implementing OAuth 2.0/2.1 and OpenID Connect flows, including
  advanced patterns (token exchange, DPoP, PAR, RAR, JAR, mTLS, GNAP), provider integration
  (Google, GitHub, Microsoft Entra ID, Auth0, Keycloak, Okta), troubleshooting, and secure
  token storage. Includes ready-to-use scripts and code templates.

  Use when user mentions "OAuth 2.0", "OAuth 2.1", "OIDC", "OpenID Connect",
  "authorization code flow", "PKCE", "client credentials", "refresh token", "JWT bearer",
  "token exchange", "device code flow", "DPoP", "PAR", "pushed authorization",
  "OIDC discovery", "userinfo endpoint", "scope design", "token rotation",
  "authorization server", "step-up authentication", "token introspection", "GNAP",
  "mTLS client auth", "rich authorization requests", "FAPI", or asks about integrating
  Google/GitHub/Auth0/Keycloak/Okta/Microsoft Entra OAuth. Also use for OAuth debugging,
  token storage best practices, or OIDC provider configuration.

  NOT for basic auth, API key auth, session-based auth without OAuth, SAML, LDAP,
  Kerberos, or general password hashing.
---

# OAuth 2.0 / 2.1 & OpenID Connect Flows

## Core Principles (OAuth 2.1 Draft)

OAuth 2.1 consolidates OAuth 2.0 (RFC 6749) with mandatory security improvements:
- **PKCE required** for ALL authorization code flows (public and confidential clients)
- **Implicit flow removed** — use authorization code + PKCE instead
- **ROPC flow removed** — never collect user passwords in clients
- **No tokens in URLs** — use Authorization header or POST body only
- **Exact redirect URI matching** — no wildcards or partial matches

## Flow Selection Guide

| Scenario | Flow | Grant Type |
|----------|------|------------|
| Web app with backend | Authorization Code + PKCE | `authorization_code` |
| SPA (no backend) | Authorization Code + PKCE | `authorization_code` |
| Mobile/desktop native app | Authorization Code + PKCE | `authorization_code` |
| Service-to-service (M2M) | Client Credentials | `client_credentials` |
| CLI/smart TV/IoT (no browser) | Device Authorization | `urn:ietf:params:oauth:grant-type:device_code` |
| Token delegation across services | Token Exchange (RFC 8693) | `urn:ietf:params:oauth:grant-type:token-exchange` |
| Expired access token | Refresh Token | `refresh_token` |

## 1. Authorization Code Flow + PKCE

### Step 1: Generate PKCE Values
```python
import hashlib, base64, secrets

code_verifier = secrets.token_urlsafe(64)[:128]
code_challenge = base64.urlsafe_b64encode(
    hashlib.sha256(code_verifier.encode()).digest()
).rstrip(b"=").decode()
```

### Step 2: Authorization Request
```
GET /authorize?
  response_type=code
  &client_id=CLIENT_ID
  &redirect_uri=https://app.example.com/callback
  &scope=openid profile email
  &state=RANDOM_CSRF_STATE
  &code_challenge=CODE_CHALLENGE
  &code_challenge_method=S256
  &nonce=RANDOM_NONCE
```
- `state`: CSRF protection — bind to user session, verify on callback
- `nonce`: OIDC replay protection — embed in ID token, verify on receipt

### Step 3: Token Exchange
```http
POST /token
Content-Type: application/x-www-form-urlencoded

grant_type=authorization_code
&code=AUTH_CODE
&redirect_uri=https://app.example.com/callback
&client_id=CLIENT_ID
&client_secret=CLIENT_SECRET
&code_verifier=CODE_VERIFIER
```

### Response
```json
{
  "access_token": "eyJhbGci...",
  "token_type": "Bearer",
  "expires_in": 3600,
  "refresh_token": "dGhpcyBpcyBhIHJlZnJlc2g...",
  "id_token": "eyJhbGciOiJSUzI1NiIs...",
  "scope": "openid profile email"
}
```

## 2. Client Credentials Flow (M2M)

```http
POST /token
Content-Type: application/x-www-form-urlencoded
Authorization: Basic BASE64(client_id:client_secret)

grant_type=client_credentials
&scope=api:read api:write
```
- No user context — `sub` claim is the client itself
- Never issue refresh tokens for this flow
- Use short-lived access tokens (5–15 min)
- For higher security, use `private_key_jwt` or mTLS client auth instead of secrets

## 3. Device Authorization Flow (RFC 8628)

```http
POST /device/authorize
Content-Type: application/x-www-form-urlencoded

client_id=CLIENT_ID&scope=openid profile
```
Response: `{ "device_code": "...", "user_code": "ABCD-1234", "verification_uri": "https://auth.example.com/device", "interval": 5, "expires_in": 600 }`

Client polls `/token` with `grant_type=urn:ietf:params:oauth:grant-type:device_code&device_code=DEVICE_CODE`. Handle `authorization_pending` and `slow_down` errors. Respect `interval`.

## 4. Token Exchange (RFC 8693)

For delegation, impersonation, or cross-service token exchange:
```http
POST /token
Content-Type: application/x-www-form-urlencoded

grant_type=urn:ietf:params:oauth:grant-type:token-exchange
&subject_token=INCOMING_ACCESS_TOKEN
&subject_token_type=urn:ietf:params:oauth:token-type:access_token
&audience=https://api.downstream.example.com
&scope=read write
&requested_token_type=urn:ietf:params:oauth:token-type:access_token
```
- Use `actor_token` + `actor_token_type` for delegation (composite identity)
- Validate `audience` server-side to prevent token forwarding attacks
- Scope of exchanged token should be equal or narrower than original

## 5. Refresh Token Rotation

```http
POST /token
Content-Type: application/x-www-form-urlencoded

grant_type=refresh_token
&refresh_token=CURRENT_REFRESH_TOKEN
&client_id=CLIENT_ID
```
**Rotation rules:**
- Issue a new refresh token with each use; invalidate the old one
- If a revoked refresh token is reused, invalidate the entire grant (token family)
- Set absolute lifetime (e.g., 30 days) and idle timeout (e.g., 7 days)
- Store refresh tokens hashed (SHA-256) server-side; never in localStorage

## 6. OIDC Discovery & UserInfo

### Discovery Document
```
GET /.well-known/openid-configuration
```
Returns endpoints, supported scopes, signing algorithms, etc. Always fetch dynamically; cache with TTL.

### ID Token Validation Checklist
1. Verify JWT signature using keys from `jwks_uri`
2. `iss` matches the provider's issuer URL exactly
3. `aud` contains your `client_id`
4. `exp` > current time; `iat` is reasonable
5. `nonce` matches value sent in authorization request
6. `at_hash` matches hash of access token (if present)

### UserInfo Endpoint
```http
GET /userinfo
Authorization: Bearer ACCESS_TOKEN
```
Returns claims based on granted scopes (`profile`, `email`, `address`, `phone`).

## 7. JWT Access Tokens (RFC 9068)

Structure: `{ "iss", "sub", "aud", "exp", "iat", "jti", "client_id", "scope" }`
- `aud` must be the resource server identifier
- Resource servers validate signature, `iss`, `aud`, `exp`, and `scope`
- Use short lifetimes (5–15 min) — no revocation needed if short enough
- For revocable tokens, use opaque tokens + introspection (RFC 7662) instead

## 8. Scope Design

```
# Resource-based scoping (preferred)
api:users:read    api:users:write
api:orders:read   api:orders:admin

# Avoid overly broad scopes
❌ admin, read, write
✅ org:billing:read, org:members:manage
```
- Define scopes per resource and action
- Use `openid`, `profile`, `email`, `offline_access` for OIDC
- `offline_access` signals the client wants a refresh token

## 9. Provider Integration Patterns

### Google
```
Authorization: https://accounts.google.com/o/oauth2/v2/auth
Token:         https://oauth2.googleapis.com/token
Discovery:     https://accounts.google.com/.well-known/openid-configuration
Scopes:        openid profile email
Note:          Use `access_type=offline&prompt=consent` for refresh tokens
```

### GitHub
```
Authorization: https://github.com/login/oauth/authorize
Token:         https://github.com/login/oauth/access_token
UserInfo:      https://api.github.com/user (not standard OIDC)
Note:          Not a full OIDC provider — no id_token, no discovery document.
               Request `Accept: application/json` on token endpoint.
               Scopes: repo, read:user, user:email
```

### Auth0
```
Discovery:     https://YOUR_DOMAIN/.well-known/openid-configuration
Note:          Set `audience` param for API authorization.
               Use /authorize?audience=https://myapi for JWT access tokens.
               Supports RBAC via permissions in token custom claims.
```

### Keycloak
```
Discovery:     https://HOST/realms/REALM/.well-known/openid-configuration
Note:          Full OIDC support. Use realm roles or client roles.
               Supports token exchange, DPoP, PAR, CIBA natively.
               Admin API at /admin/realms/REALM/...
```

## 10. Security Considerations

### CSRF Protection
- Always use `state` parameter — cryptographic random, bound to session
- Verify `state` on callback before processing the authorization code

### Redirect URI Validation
- Register exact redirect URIs; reject any mismatch
- Never use wildcard subdomains or path prefixes
- For native apps, use `https://` custom schemes or claimed HTTPS URIs (Universal Links / App Links)
- Avoid `http://localhost` in production

### Token Storage
| Platform | Access Token | Refresh Token |
|----------|-------------|---------------|
| Server-side web | Server session/memory | Encrypted DB or session |
| SPA | In-memory variable (NOT localStorage) | HttpOnly Secure SameSite cookie via BFF, or in-memory |
| Mobile native | Secure enclave / Keychain / Keystore | Secure enclave / Keychain / Keystore |

### Additional Security
- Use TLS everywhere — no exceptions
- Validate `iss` and `aud` in every token
- Implement token revocation endpoint (RFC 7009) for logout
- Log token issuance and usage for audit trails

## 11. DPoP — Demonstrating Proof of Possession (RFC 9449)

Binds tokens to a client key pair, preventing stolen token reuse:

```http
POST /token
Content-Type: application/x-www-form-urlencoded
DPoP: eyJhbGciOiJFUzI1NiIsInR5cCI6ImRwb3Arand...

grant_type=authorization_code&code=AUTH_CODE&...
```

DPoP proof JWT payload:
```json
{ "jti": "unique-id", "htm": "POST", "htu": "https://auth.example.com/token", "iat": 1700000000 }
```
- Client generates an asymmetric key pair (ES256 recommended)
- Each request includes a signed DPoP proof in the `DPoP` header
- Token response includes `token_type: "DPoP"` (not Bearer)
- Resource server requests require both `Authorization: DPoP <token>` and a fresh `DPoP` proof header
- Include `dpop_jkt` (JWK thumbprint) in PAR requests to bind authorization codes

## 12. PAR — Pushed Authorization Requests (RFC 9126)

Move authorization parameters to a secure back-channel:
```http
POST /par
Content-Type: application/x-www-form-urlencoded
Authorization: Basic BASE64(client_id:client_secret)

response_type=code
&redirect_uri=https://app.example.com/callback
&scope=openid profile
&code_challenge=...
&code_challenge_method=S256
&state=...
```
Response: `{ "request_uri": "urn:ietf:params:oauth:request_uri:abc123", "expires_in": 60 }`

Then redirect: `GET /authorize?client_id=CLIENT_ID&request_uri=urn:ietf:params:oauth:request_uri:abc123`

**Benefits:** Prevents parameter tampering, avoids URL length limits, keeps sensitive params off the front-channel.

## Reference Guides

Detailed deep-dive documents in `references/`:

### `references/advanced-patterns.md`
Advanced OAuth 2.0/OIDC specifications and patterns:
- **Token Exchange (RFC 8693)** — Delegation, impersonation, cross-service token exchange
- **DPoP (RFC 9449)** — Sender-constrained tokens with proof-of-possession
- **PAR (RFC 9126)** — Pushed Authorization Requests for tamper-proof auth params
- **RAR (RFC 9396)** — Rich Authorization Requests with structured JSON (Open Banking)
- **GNAP (RFC 9635)** — Next-generation authorization protocol overview
- **mTLS Client Auth (RFC 8705)** — Certificate-based client authentication
- **JAR (RFC 9101)** — JWT-Secured Authorization Requests
- **Step-Up Authentication (RFC 9470)** — Dynamic authentication level escalation
- **Token Introspection (RFC 7662)** — Opaque token validation
- **Token Revocation (RFC 7009)** — Token invalidation and cascading
- **FAPI 2.0 / Healthcare / IoT** — Combined pattern profiles

### `references/troubleshooting.md`
Debugging guide for common OAuth/OIDC failures:
- Error codes deep-dive (`invalid_grant`, `invalid_client`, redirect URI mismatch)
- CORS issues with token endpoints and the BFF solution
- Token expiry races and refresh deduplication patterns
- JWT debugging techniques and JWKS caching strategies
- **Provider-specific quirks**: Google refresh token limits, GitHub non-OIDC behavior, Auth0 audience requirement, Microsoft AADSTS errors, Keycloak config, Okta authorization servers
- **Security vulnerabilities**: Authorization code injection, token leakage vectors, open redirectors, PKCE downgrade, token replay

### `references/provider-integration.md`
Step-by-step integration guides for 6 providers:
- **Google** — OAuth consent screen, refresh token caveats, incremental auth
- **GitHub** — OAuth Apps vs GitHub Apps, non-OIDC workarounds, scope format
- **Microsoft Entra ID** — Tenant types, Graph API scopes, Conditional Access
- **Auth0** — Audience parameter, Actions, custom domains, Organizations
- **Keycloak** — Realm config, role mappers, identity brokering, admin API
- **Okta** — Org vs Custom authorization servers, inline hooks, access policies
- **Cross-provider patterns** — User normalization, account linking, multi-provider config

## Scripts

Executable utilities in `scripts/`:

### `scripts/generate-pkce.sh`
Generate PKCE `code_verifier` and `code_challenge` (S256). Supports `--json` and `--env` output formats.

### `scripts/decode-jwt.sh`
Decode and pretty-print JWT tokens. Supports `--header`, `--payload`, `--verify` modes with expiry checking.

### `scripts/oauth2-test-flow.py`
Interactive Python script to test OAuth2 Authorization Code + PKCE flows locally. Starts a temporary HTTP server, opens the browser, handles the callback, and displays tokens. No external dependencies.

## Assets

Reusable code templates and configurations in `assets/`:

| File | Description |
|------|-------------|
| `express-oauth2-middleware.js` | Express.js middleware with Passport for Google, GitHub, generic OIDC |
| `fastapi-oauth2.py` | FastAPI dependency injection for JWT validation, scope/role enforcement |
| `oidc-discovery-template.json` | Example `.well-known/openid-configuration` with all standard fields |
| `token-storage-patterns.md` | Secure token storage: web (HttpOnly/BFF), mobile (Keychain/Keystore), SPA (in-memory) |
| `nginx-oauth2-proxy.conf` | Nginx reverse proxy with oauth2-proxy auth_request integration |

## Examples

### Example 1: "Implement Google sign-in for my Express app"
**Input:** Express.js app needing Google OAuth login
**Output:**
```javascript
// routes/auth.js
const crypto = require('crypto');
const GOOGLE_DISCOVERY = 'https://accounts.google.com/.well-known/openid-configuration';

app.get('/auth/google', (req, res) => {
  const state = crypto.randomBytes(32).toString('hex');
  const nonce = crypto.randomBytes(32).toString('hex');
  const codeVerifier = crypto.randomBytes(64).toString('base64url').slice(0, 128);
  const codeChallenge = crypto.createHash('sha256')
    .update(codeVerifier).digest('base64url');

  req.session.oauthState = { state, nonce, codeVerifier };

  res.redirect(`https://accounts.google.com/o/oauth2/v2/auth?` +
    `response_type=code&client_id=${GOOGLE_CLIENT_ID}` +
    `&redirect_uri=${encodeURIComponent(CALLBACK_URL)}` +
    `&scope=openid%20profile%20email` +
    `&state=${state}&nonce=${nonce}` +
    `&code_challenge=${codeChallenge}&code_challenge_method=S256`);
});

app.get('/auth/google/callback', async (req, res) => {
  const { state, nonce, codeVerifier } = req.session.oauthState;
  if (req.query.state !== state) return res.status(403).send('CSRF detected');

  const tokenRes = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'authorization_code', code: req.query.code,
      redirect_uri: CALLBACK_URL, client_id: GOOGLE_CLIENT_ID,
      client_secret: GOOGLE_CLIENT_SECRET, code_verifier: codeVerifier,
    }),
  });
  const tokens = await tokenRes.json();
  // Validate id_token: verify signature via JWKS, check iss, aud, exp, nonce
  // Create session, store refresh_token encrypted in DB
});
```

### Example 2: "Set up M2M auth between my microservices"
**Input:** Two services needing authenticated API calls
**Output:**
```python
# service_a/auth.py — Token client with caching
import httpx, time

class M2MTokenClient:
    def __init__(self, token_url, client_id, client_secret):
        self.token_url = token_url
        self.client_id = client_id
        self.client_secret = client_secret
        self._token = None
        self._expires_at = 0

    async def get_token(self) -> str:
        if self._token and time.time() < self._expires_at - 30:
            return self._token
        async with httpx.AsyncClient() as client:
            r = await client.post(self.token_url, data={
                "grant_type": "client_credentials",
                "scope": "api:orders:read api:orders:write",
            }, auth=(self.client_id, self.client_secret))
            r.raise_for_status()
            data = r.json()
            self._token = data["access_token"]
            self._expires_at = time.time() + data["expires_in"]
            return self._token

# service_b/middleware.py — Token validation
import jwt, httpx

async def validate_access_token(token: str, jwks_url: str, issuer: str, audience: str):
    jwks = (await httpx.AsyncClient().get(jwks_url)).json()
    header = jwt.get_unverified_header(token)
    key = next(k for k in jwks["keys"] if k["kid"] == header["kid"])
    return jwt.decode(token, jwt.algorithms.RSAAlgorithm.from_jwk(key),
                      algorithms=["RS256"], audience=audience, issuer=issuer)
```

### Example 3: "Add refresh token rotation to my auth server"
**Input:** Auth server needs secure refresh token handling
**Output:**
```python
# Refresh token rotation with family-based revocation
import hashlib, secrets
from datetime import datetime, timedelta

def handle_refresh(db, incoming_refresh_token: str, client_id: str):
    token_hash = hashlib.sha256(incoming_refresh_token.encode()).hexdigest()
    stored = db.get_refresh_token(token_hash)
    if not stored:
        # Possible replay — revoke entire token family
        db.revoke_token_family(family_id=extract_family(incoming_refresh_token))
        raise SecurityError("Refresh token reuse detected")
    if stored["expires_at"] < datetime.utcnow():
        raise ExpiredTokenError()

    db.revoke_refresh_token(token_hash)  # Invalidate used token
    new_refresh = secrets.token_urlsafe(64)
    new_hash = hashlib.sha256(new_refresh.encode()).hexdigest()
    db.store_refresh_token(new_hash, family_id=stored["family_id"],
        expires_at=datetime.utcnow() + timedelta(days=30))
    new_access = mint_jwt_access_token(sub=stored["sub"], scope=stored["scope"])
    return {"access_token": new_access, "refresh_token": new_refresh}
```
