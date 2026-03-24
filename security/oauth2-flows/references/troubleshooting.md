# OAuth 2.0 / OIDC Troubleshooting Guide

## Table of Contents

- [1. Common OAuth Error Codes](#1-common-oauth-error-codes)
- [2. Authorization Endpoint Failures](#2-authorization-endpoint-failures)
- [3. Token Endpoint Failures](#3-token-endpoint-failures)
- [4. CORS Issues](#4-cors-issues)
- [5. Token Expiry & Refresh Races](#5-token-expiry--refresh-races)
- [6. JWT Debugging](#6-jwt-debugging)
- [7. Provider-Specific Quirks](#7-provider-specific-quirks)
- [8. Security Vulnerabilities](#8-security-vulnerabilities)
- [9. Debugging Checklist](#9-debugging-checklist)

---

## 1. Common OAuth Error Codes

### Authorization Endpoint Errors (RFC 6749 §4.1.2.1)

| Error | Cause | Fix |
|-------|-------|-----|
| `invalid_request` | Missing or duplicate parameters | Check required params: `response_type`, `client_id`, `redirect_uri` |
| `unauthorized_client` | Client not authorized for this grant type | Verify client registration allows `authorization_code` grant |
| `access_denied` | User denied consent or policy blocked | Check consent screen; verify user has required roles |
| `unsupported_response_type` | AS doesn't support requested `response_type` | Use `code` (not `token` — implicit is deprecated) |
| `invalid_scope` | Unknown or malformed scope | Check scope names match exactly (case-sensitive) |
| `server_error` | AS internal error | Check AS logs; retry after delay |
| `temporarily_unavailable` | AS overloaded | Implement exponential backoff |

### Token Endpoint Errors (RFC 6749 §5.2)

| Error | Cause | Fix |
|-------|-------|-----|
| `invalid_request` | Malformed request body | Ensure `Content-Type: application/x-www-form-urlencoded` |
| `invalid_client` | Client authentication failed | Check `client_id`/`client_secret`; verify auth method |
| `invalid_grant` | Code expired, already used, or PKCE mismatch | See [detailed section below](#invalid_grant-deep-dive) |
| `unauthorized_client` | Client not authorized for this grant | Check client's allowed grant types |
| `unsupported_grant_type` | Unknown grant type | Verify grant type string exactly |
| `invalid_scope` | Requested scope exceeds granted scope | Request equal or fewer scopes |

---

## 2. Authorization Endpoint Failures

### Redirect URI Mismatch

**Symptom**: `redirect_uri_mismatch` or `invalid_request` error, often with no redirect.

**Causes:**
```
Registered:  https://app.example.com/callback
Sent:        https://app.example.com/callback/    ← trailing slash
Sent:        http://app.example.com/callback       ← wrong scheme
Sent:        https://APP.example.com/callback      ← case mismatch (path)
Sent:        https://app.example.com/callback?x=1  ← query params
```

**Fix:**
- Exact string match required (OAuth 2.1) — no wildcards, no path prefixes
- Register every redirect URI variant you use (dev, staging, prod)
- URL-encode the `redirect_uri` parameter in the authorization request
- For localhost development: register `http://localhost:PORT/callback` (exact port)
- Some providers (Google) require the port number; others (Auth0) strip it

### State Parameter Failures

**Symptom**: CSRF validation fails on callback.

**Causes:**
- State not stored before redirect (lost on page reload)
- Session cookie lost (SameSite, Secure attributes)
- Multiple tabs: state overwritten by second authorization request
- State stored in localStorage but cleared

**Fix:**
```javascript
// Store state per-authorization, not per-session
const state = crypto.randomBytes(32).toString('hex');
sessionStorage.setItem(`oauth_state_${state}`, JSON.stringify({
  nonce, codeVerifier, returnTo: window.location.href
}));
// On callback:
const stored = sessionStorage.getItem(`oauth_state_${req.query.state}`);
sessionStorage.removeItem(`oauth_state_${req.query.state}`);
if (!stored) throw new Error('CSRF validation failed');
```

### Scope Rejection

**Symptom**: Provider ignores or rejects requested scopes.

**Common issues:**
- Scope names are provider-specific and case-sensitive
- Some scopes require app verification (Google: sensitive/restricted scopes)
- GitHub uses different format: `repo`, `read:user` (colon separator)
- Auth0 requires `audience` parameter for API scopes
- Microsoft requires `.default` suffix for v2.0 endpoint scopes

---

## 3. Token Endpoint Failures

### `invalid_grant` Deep Dive

This is the most common and most confusing OAuth error. Causes:

**1. Authorization code expired**
```
Most providers: 30s–10min lifetime
Google: ~5 minutes
Auth0: 30 seconds (configurable)
Keycloak: 60 seconds (default)
```
Fix: Exchange the code immediately upon receipt.

**2. Authorization code already used**
```
Codes are single-use. If exchanged twice:
- First request succeeds
- Second request fails with invalid_grant
- Some AS revoke all tokens from that grant (security measure)
```
Fix: Ensure no duplicate submissions (disable button, use flag).

**3. PKCE `code_verifier` mismatch**
```
The SHA-256 hash of the code_verifier sent to /token
must exactly match the code_challenge sent to /authorize.
```
Fix: Verify PKCE generation — use the `generate-pkce.sh` script to test.

**4. Redirect URI mismatch at token endpoint**
```
The redirect_uri sent to /token must exactly match
the one sent to /authorize (even though no redirect happens).
```

**5. Client authentication failure**
```
- Wrong client_secret
- Using client_secret_post but server expects client_secret_basic (or vice versa)
- client_id not included in body when using client_secret_basic
```

**6. Refresh token expired or revoked**
```
- Absolute lifetime exceeded (e.g., 30 days)
- Idle timeout exceeded (e.g., 7 days since last use)
- Token family revoked due to replay detection
- User changed password / admin revoked access
- Google: refresh tokens expire if unused for 6 months
```

### Client Authentication Mismatches

**Symptom**: `invalid_client` at the token endpoint.

```
# client_secret_basic — credentials in Authorization header
Authorization: Basic BASE64(client_id:client_secret)
# Must URL-encode client_id and client_secret BEFORE base64 encoding

# client_secret_post — credentials in request body
client_id=CLIENT_ID&client_secret=CLIENT_SECRET

# private_key_jwt — signed JWT assertion
client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer
&client_assertion=eyJhbGciOiJSUzI1NiJ9...
```

**Common mistakes:**
- Mixing up `client_secret_basic` and `client_secret_post`
- Forgetting to URL-encode special characters in client_secret before base64
- JWT assertion: wrong `aud` (must be the token endpoint URL)
- JWT assertion: expired `exp` or `iat` in the future

---

## 4. CORS Issues

### Symptom

```
Access to fetch at 'https://auth.example.com/token' from origin
'https://app.example.com' has been blocked by CORS policy.
```

### Why This Happens

SPAs make cross-origin requests to the token endpoint. If the AS doesn't include proper CORS headers, the browser blocks the response.

### Solutions

**Option 1: AS supports CORS (preferred)**
```
Access-Control-Allow-Origin: https://app.example.com
Access-Control-Allow-Methods: POST
Access-Control-Allow-Headers: Content-Type, Authorization
```

**Option 2: BFF (Backend for Frontend) pattern**
```
SPA → Same-origin BFF proxy → AS token endpoint
```
The BFF handles token exchange server-side, eliminating CORS entirely.

**Option 3: Proxy in development**
```javascript
// vite.config.js
export default {
  server: {
    proxy: {
      '/oauth': { target: 'https://auth.example.com', changeOrigin: true }
    }
  }
};
```

### Preflight Request Failures

The browser sends an `OPTIONS` preflight request before `POST /token`:
```http
OPTIONS /token HTTP/1.1
Origin: https://app.example.com
Access-Control-Request-Method: POST
Access-Control-Request-Headers: content-type
```

If the AS doesn't respond with proper `Access-Control-*` headers, the actual request is never sent. The error appears as a CORS error, but the root cause is the missing preflight response.

---

## 5. Token Expiry & Refresh Races

### Problem: Concurrent Requests During Refresh

```
Request A: access_token expired → starts refresh
Request B: access_token expired → starts refresh (same refresh_token)
Request A: gets new tokens (refresh_token rotated)
Request B: sends OLD refresh_token → invalid_grant (or family revoked!)
```

### Solution: Token Refresh Queue

```javascript
class TokenManager {
  #refreshPromise = null;

  async getAccessToken() {
    if (this.isTokenValid()) return this.accessToken;

    // Deduplicate concurrent refresh attempts
    if (!this.#refreshPromise) {
      this.#refreshPromise = this.#refresh().finally(() => {
        this.#refreshPromise = null;
      });
    }
    await this.#refreshPromise;
    return this.accessToken;
  }

  async #refresh() {
    const res = await fetch('/token', {
      method: 'POST',
      body: new URLSearchParams({
        grant_type: 'refresh_token',
        refresh_token: this.refreshToken,
      }),
    });
    if (!res.ok) {
      // Refresh failed — force re-authentication
      this.clearTokens();
      throw new AuthenticationRequired();
    }
    const data = await res.json();
    this.accessToken = data.access_token;
    this.refreshToken = data.refresh_token; // rotated
    this.expiresAt = Date.now() + data.expires_in * 1000;
  }

  isTokenValid() {
    // Refresh 30 seconds before actual expiry to avoid edge cases
    return this.accessToken && Date.now() < this.expiresAt - 30000;
  }
}
```

### Problem: Clock Skew

Server's `exp` is based on server time, but client checks against local time.

**Fix**: Compute expiry from the response timestamp, not from `exp`:
```javascript
const expiresAt = Date.now() + data.expires_in * 1000;
// NOT: const expiresAt = data.exp * 1000;
```

### Problem: Stale Tokens in Multiple Tabs

**Fix**: Use `BroadcastChannel` to sync token state:
```javascript
const channel = new BroadcastChannel('auth-tokens');
channel.onmessage = (event) => {
  if (event.data.type === 'TOKEN_REFRESHED') {
    this.accessToken = event.data.accessToken;
    this.expiresAt = event.data.expiresAt;
  }
};
// After refresh:
channel.postMessage({
  type: 'TOKEN_REFRESHED',
  accessToken: newAccessToken,
  expiresAt: newExpiresAt,
});
```

---

## 6. JWT Debugging

### Decoding JWTs Locally

**Command line (see `scripts/decode-jwt.sh`):**
```bash
echo 'eyJhbGci...' | cut -d. -f2 | base64 -d 2>/dev/null | jq .
```

**JWT.io** — paste tokens for decoding. **⚠️ NEVER paste production tokens** — JWT.io can see them.

**Self-hosted alternative:**
```bash
npm install -g jwt-cli
jwt decode eyJhbGci...
```

### Common JWT Validation Failures

| Error | Cause | Fix |
|-------|-------|-----|
| `invalid signature` | Wrong key or algorithm | Fetch current JWKS; check `kid` matches |
| `token expired` | `exp` < current time | Check clock sync; re-authenticate |
| `audience mismatch` | `aud` doesn't match expected value | Verify `aud` matches your resource server identifier |
| `issuer mismatch` | `iss` doesn't match expected issuer | Check trailing slashes; compare exactly |
| `algorithm mismatch` | Expected RS256, got HS256 | ALWAYS whitelist expected algorithms (never `alg: none`) |
| `kid not found` | JWKS rotated, cached keys stale | Refresh JWKS when `kid` is unknown; cache with TTL |

### JWKS Caching Strategy

```python
import time, httpx

class JWKSCache:
    def __init__(self, jwks_uri, ttl=3600, min_refresh=60):
        self.jwks_uri = jwks_uri
        self.ttl = ttl
        self.min_refresh = min_refresh
        self._keys = {}
        self._fetched_at = 0

    def get_key(self, kid: str):
        if kid in self._keys and not self._is_expired():
            return self._keys[kid]
        # Unknown kid or cache expired — refresh
        if time.time() - self._fetched_at < self.min_refresh:
            raise KeyError(f"Key {kid} not found (rate-limited)")
        self._refresh()
        if kid not in self._keys:
            raise KeyError(f"Key {kid} not found after JWKS refresh")
        return self._keys[kid]

    def _refresh(self):
        resp = httpx.get(self.jwks_uri)
        jwks = resp.json()
        self._keys = {k["kid"]: k for k in jwks["keys"]}
        self._fetched_at = time.time()

    def _is_expired(self):
        return time.time() - self._fetched_at > self.ttl
```

---

## 7. Provider-Specific Quirks

### Google

**Refresh token limits:**
- Google issues a refresh token **only** on the first authorization with `access_type=offline`
- To force a new refresh token: add `prompt=consent`
- Per-user limit: 100 refresh tokens per client. Oldest revoked when exceeded.
- Refresh tokens expire after 6 months if unused
- Apps in "Testing" mode: refresh tokens expire in 7 days
- Published apps: refresh tokens do not expire (unless unused for 6 months)

**Common issues:**
```
# Must include both to get refresh token:
access_type=offline&prompt=consent

# Google rejects localhost redirect URIs without a port
# Use: http://localhost:8080/callback (not http://localhost/callback)

# Google requires verified domains for production redirect URIs

# Incremental authorization: Google supports requesting additional
# scopes without re-consenting to existing ones
# Use: include_granted_scopes=true
```

### GitHub

**Not a full OIDC provider:**
- No `id_token` issued
- No `/.well-known/openid-configuration`
- No JWKS endpoint
- User identity via `GET /user` API (not standard userinfo)

**Scope format:**
```
# GitHub uses unique scope format:
repo               — Full repository access
read:user          — Read user profile
user:email         — Read user email addresses
admin:org          — Full org access
write:packages     — Write packages

# NOT: openid, profile, email (these are OIDC scopes)
```

**Token endpoint quirks:**
```
# Must request JSON response explicitly:
Accept: application/json

# Default response is form-encoded:
# access_token=xxx&scope=repo&token_type=bearer

# GitHub tokens don't expire by default (classic PATs)
# Fine-grained PATs and OAuth tokens can have expiry
```

**GitHub Apps vs OAuth Apps:**
- OAuth Apps: simpler, user-level tokens
- GitHub Apps: installation-level, JWT-based auth, finer permissions
- Prefer GitHub Apps for new integrations

### Auth0

**Tenant configuration:**
```
# Custom domain: https://auth.yourdomain.com
# Default domain: https://YOUR_TENANT.auth0.com (or .us.auth0.com, .eu.auth0.com)

# API audience is REQUIRED for JWT access tokens:
/authorize?audience=https://api.example.com
# Without audience, you get an opaque token only valid for /userinfo

# Token expiry is set per-API in the Auth0 dashboard
# Refresh token rotation is configured per-application

# Rules vs Actions: Auth0 is migrating from Rules to Actions
# Use Actions for new logic (login, post-login, M2M, etc.)
```

**Silent authentication (SPA):**
```javascript
// Auth0 SPA SDK handles token refresh via hidden iframe
// Requires: "Allowed Web Origins" configured in dashboard
// Third-party cookie blocking breaks silent auth →
//   use Refresh Token Rotation instead
```

**Common Auth0 errors:**
```
"Unauthorized" on /userinfo → Token is opaque; set audience for JWT
"consent_required" → Enable "Allow Skipping User Consent" for first-party apps
"access_denied" (Actions) → Check Action logs in dashboard
"login_required" → Session expired; silent auth failed
```

### Microsoft Entra ID (Azure AD)

**Endpoint versions:**
```
# v2.0 endpoint (recommended):
https://login.microsoftonline.com/{tenant}/oauth2/v2.0/authorize
https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token

# Tenant values:
# "common"       — any Microsoft account or Entra ID
# "organizations" — Entra ID accounts only
# "consumers"    — Microsoft personal accounts only
# "TENANT_ID"    — specific tenant
```

**Scope format:**
```
# Microsoft uses resource URI + permission:
https://graph.microsoft.com/User.Read
https://graph.microsoft.com/Mail.Read
https://graph.microsoft.com/.default   ← all statically consented permissions

# openid, profile, email, offline_access work as expected
# offline_access is required for refresh tokens
```

**Common issues:**
- `AADSTS50011`: Redirect URI mismatch — check "Platform configurations" in app registration
- `AADSTS700016`: App not found in tenant — check `client_id` and tenant
- `AADSTS65001`: Consent not granted — user or admin must consent
- Multi-tenant apps: admin consent required for certain permissions
- Conditional Access policies can block token issuance

### Keycloak

**Configuration:**
```
# Discovery per realm:
https://keycloak.example.com/realms/REALM/.well-known/openid-configuration

# Admin REST API:
https://keycloak.example.com/admin/realms/REALM/...

# Default admin credentials: admin/admin (CHANGE IMMEDIATELY)
```

**Common issues:**
```
# "Invalid redirect URI" → Add URI in: Realm → Clients → Client → Valid Redirect URIs
# Wildcard support: https://app.example.com/* (NOT recommended for production)

# Token exchange not enabled by default:
# Realm → Token Exchange → Enable (or enable for specific clients)

# Mappers: Claims customization via "Client Scopes" → Mappers
# Protocol mappers control what claims appear in tokens

# Realm vs client roles: realm roles are global, client roles are per-client
# Add roles to tokens via mapper: "realm roles" or "client roles"
```

### Okta

**Endpoint structure:**
```
# Custom authorization server:
https://YOUR_DOMAIN.okta.com/oauth2/AUTHORIZATION_SERVER_ID/v1/authorize

# Default server (Org-level):
https://YOUR_DOMAIN.okta.com/oauth2/v1/authorize

# Use custom authorization server for API access tokens
# Org-level server only issues tokens for Okta APIs
```

**Common issues:**
```
# "unsupported_response_type" → Enable grant type in Application → General → Allowed grant types
# "invalid_scope" → Add scope to authorization server → Scopes
# Inline hooks can modify token claims but add latency
# Custom claims: Authorization Server → Claims → Add Claim
```

---

## 8. Security Vulnerabilities

### Authorization Code Injection

**Attack**: Attacker intercepts an authorization code and injects it into a victim's callback URL.

**Mitigation**:
- **PKCE** (primary defense): The attacker doesn't have the `code_verifier`
- **State parameter**: Bound to the user's session
- **Nonce**: For OIDC, validated in the `id_token`
- **Exact redirect URI matching**: Prevents open redirector exploitation

### Token Leakage Vectors

**1. Browser history & referrer headers:**
```
# NEVER put tokens in URLs (query params or fragments)
# OAuth 2.1 mandates: no tokens in URLs

# Set Referrer-Policy to prevent token leakage:
Referrer-Policy: strict-origin-when-cross-origin
```

**2. Logs:**
```
# Tokens often leak into:
# - Server access logs (if in URL)
# - Application debug logs
# - Error tracking services (Sentry, etc.)
# - Browser developer console

# Scrub tokens from logs:
app.use((req, res, next) => {
  const sanitized = { ...req.headers };
  delete sanitized.authorization;
  logger.info({ headers: sanitized, path: req.path });
  next();
});
```

**3. Third-party scripts:**
```
# SPAs: In-memory token storage prevents theft via XSS
# BUT: XSS can still make authenticated requests
# CSP headers reduce XSS risk:
Content-Security-Policy: script-src 'self'; connect-src 'self' https://auth.example.com
```

### Open Redirector Attacks

**Attack**: Attacker uses a legitimate redirect URI that forwards to an evil site, leaking the authorization code.

```
# Vulnerable redirect:
https://app.example.com/callback → reads code → redirects to returnUrl param
# Attacker sets returnUrl=https://evil.com

# Or: app has an open redirector at another path:
https://app.example.com/goto?url=https://evil.com
# Attacker registers as redirect_uri
```

**Mitigation**:
- Exact redirect URI matching (no wildcards)
- Never forward the authorization code to another URL
- Validate `returnUrl` / post-login redirect against an allowlist
- Don't use `localhost` or `127.0.0.1` redirect URIs in production

### PKCE Downgrade Attacks

**Attack**: Attacker removes `code_challenge` from the authorization request.

**Mitigation**: AS must enforce PKCE for all public clients. Require `code_challenge` always (OAuth 2.1 mandates this).

### Token Replay & Substitution

**Attack**: Stolen bearer tokens can be replayed from any client.

**Mitigation**:
- **DPoP**: Binds tokens to a client key pair — stolen tokens are useless
- **mTLS certificate binding**: Same concept using X.509 certificates
- **Short token lifetimes**: Limits the window of exploitation
- **Sender-constrained tokens**: Verify the presenter matches the intended recipient

### ID Token Substitution (OIDC)

**Attack**: Attacker uses an `id_token` issued for a different client.

**Mitigation**:
- Always verify `aud` contains your `client_id`
- Verify `azp` (authorized party) if present
- Verify `nonce` matches the one sent in the authorization request
- Use `at_hash` to bind the id_token to the access token

---

## 9. Debugging Checklist

### Quick Diagnostic Steps

```
□ 1. Check the exact error code and description in the response
□ 2. Decode the JWT (header + payload) — check exp, aud, iss, scope
□ 3. Verify redirect_uri matches EXACTLY (scheme, host, port, path, no trailing slash)
□ 4. Confirm client_id and client_secret are correct
□ 5. Check token_endpoint_auth_method matches what you're sending
□ 6. Verify PKCE: SHA-256(code_verifier) == code_challenge
□ 7. Check clock sync between client and server (NTP)
□ 8. Inspect HTTP request/response with curl -v or browser DevTools
□ 9. Check AS logs for server-side error details
□ 10. Verify TLS certificate chain (especially with mTLS)
```

### Useful curl Commands

```bash
# Test token endpoint directly
curl -v -X POST https://auth.example.com/token \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'grant_type=client_credentials&client_id=ID&client_secret=SECRET&scope=api:read'

# Introspect a token
curl -X POST https://auth.example.com/introspect \
  -u 'resource_server_id:resource_server_secret' \
  -d 'token=ACCESS_TOKEN'

# Fetch OIDC discovery
curl -s https://auth.example.com/.well-known/openid-configuration | jq .

# Fetch JWKS
curl -s https://auth.example.com/.well-known/jwks.json | jq .

# Test with verbose SSL info
curl -v --cert client.pem --key client-key.pem https://auth.example.com/token
```

### HTTP Status Code Meanings at Token Endpoint

| Status | Meaning | Action |
|--------|---------|--------|
| 200 | Success | Parse token response |
| 400 | Bad request (invalid params) | Check error code in response body |
| 401 | Client auth failed | Verify credentials and auth method |
| 403 | Forbidden (policy) | Check client permissions, scopes |
| 429 | Rate limited | Implement backoff; reduce request rate |
| 500 | Server error | Retry with backoff; check AS health |
| 503 | Service unavailable | Retry with backoff |
