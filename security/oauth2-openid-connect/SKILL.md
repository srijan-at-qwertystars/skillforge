---
name: oauth2-openid-connect
description:
  positive: "Use when user implements OAuth 2.0 or OpenID Connect, asks about authorization code flow with PKCE, client credentials, token exchange, ID tokens, scopes, or OAuth security hardening."
  negative: "Do NOT use for JWT token structure (use jwt-authentication skill), basic session auth, API key auth, or SAML."
---

# OAuth 2.0 & OpenID Connect

Standards: RFC 6749 (OAuth 2.0), RFC 9700 (OAuth 2.0 Security BCP, Jan 2025), OAuth 2.1 draft, OpenID Connect Core 1.0.

## Grant Types

### Authorization Code + PKCE (Default for all clients)

Use for: Web apps, SPAs, mobile apps, CLI tools with browser redirect.

PKCE is mandatory for ALL clients per RFC 9700 and OAuth 2.1—including confidential clients.

```
┌──────┐      ┌─────────┐      ┌────────────┐      ┌──────────┐
│ User │      │ Client  │      │ Auth Server│      │ Resource │
└──┬───┘      └────┬────┘      └─────┬──────┘      └────┬─────┘
   │               │                 │                   │
   │  1. Click     │                 │                   │
   │  "Login"      │                 │                   │
   │──────────────>│                 │                   │
   │               │                 │                   │
   │               │ 2. Generate     │                   │
   │               │ code_verifier   │                   │
   │               │ code_challenge  │                   │
   │               │ = SHA256(v)     │                   │
   │               │                 │                   │
   │               │ 3. /authorize?  │                   │
   │               │ response_type=  │                   │
   │               │ code&           │                   │
   │               │ code_challenge= │                   │
   │               │ X&state=Y       │                   │
   │<──────────────│────────────────>│                   │
   │               │                 │                   │
   │  4. Login +   │                 │                   │
   │  consent      │                 │                   │
   │──────────────────────────────-->│                   │
   │               │                 │                   │
   │               │ 5. Redirect     │                   │
   │               │ ?code=Z&state=Y │                   │
   │<──────────────│<────────────────│                   │
   │               │                 │                   │
   │               │ 6. POST /token  │                   │
   │               │ grant_type=     │                   │
   │               │ authorization_  │                   │
   │               │ code&           │                   │
   │               │ code=Z&         │                   │
   │               │ code_verifier=V │                   │
   │               │────────────────>│                   │
   │               │                 │                   │
   │               │ 7. {access_     │                   │
   │               │ token, id_token,│                   │
   │               │ refresh_token}  │                   │
   │               │<────────────────│                   │
   │               │                 │                   │
   │               │ 8. API call     │                   │
   │               │ Authorization:  │                   │
   │               │ Bearer <token>  │                   │
   │               │────────────────────────────────────>│
   │               │                 │                   │
```

PKCE implementation:

```python
import hashlib, base64, secrets

# Step 2: Generate PKCE pair
code_verifier = secrets.token_urlsafe(64)[:128]
code_challenge = base64.urlsafe_b64encode(
    hashlib.sha256(code_verifier.encode()).digest()
).rstrip(b"=").decode()

# Step 3: Include in authorization request
auth_url = (
    f"{issuer}/authorize?"
    f"response_type=code&"
    f"client_id={client_id}&"
    f"redirect_uri={redirect_uri}&"
    f"scope=openid profile email&"
    f"state={secrets.token_urlsafe(32)}&"
    f"code_challenge={code_challenge}&"
    f"code_challenge_method=S256"
)

# Step 6: Exchange code with verifier
token_response = requests.post(f"{issuer}/token", data={
    "grant_type": "authorization_code",
    "code": auth_code,
    "redirect_uri": redirect_uri,
    "client_id": client_id,
    "code_verifier": code_verifier,
})
```

### Client Credentials

Use for: Service-to-service (machine-to-machine). No user context.

```python
token_response = requests.post(f"{issuer}/token", data={
    "grant_type": "client_credentials",
    "client_id": service_client_id,
    "client_secret": service_client_secret,
    "scope": "api:read api:write",
})
```

Never use client credentials where a user context is needed. Resulting tokens have no `sub` claim tied to a user.

### Device Authorization (RFC 8628)

Use for: Input-constrained devices (TVs, IoT, CLI without browser).

```
Device ──POST /device/authorize──> Auth Server
         {client_id, scope}
         <── {device_code, user_code, verification_uri}

Device shows: "Go to https://example.com/device and enter code: ABCD-1234"

Device polls POST /token {grant_type=urn:ietf:params:oauth:grant-type:device_code,
                          device_code=X}
         until user completes auth or timeout.
```

### Refresh Token

Use for: Obtaining new access tokens without re-authentication.

```python
token_response = requests.post(f"{issuer}/token", data={
    "grant_type": "refresh_token",
    "refresh_token": stored_refresh_token,
    "client_id": client_id,
})
# Always store the new refresh_token from the response (rotation).
```

## Grant Type Decision Matrix

```
┌──────────────────────────┬────────────────────────────────┐
│ Scenario                 │ Grant Type                     │
├──────────────────────────┼────────────────────────────────┤
│ Web app (server-side)    │ Authorization Code + PKCE      │
│ SPA (browser)            │ Auth Code + PKCE (via BFF)     │
│ Mobile / native app      │ Authorization Code + PKCE      │
│ Service-to-service       │ Client Credentials             │
│ TV / IoT / CLI           │ Device Authorization           │
│ Legacy (password grant)  │ REMOVED in OAuth 2.1. Migrate. │
│ Implicit flow            │ REMOVED in OAuth 2.1. Migrate. │
└──────────────────────────┴────────────────────────────────┘
```

## OpenID Connect Layer

OIDC adds identity on top of OAuth 2.0. Request `openid` scope to receive an ID token.

### Discovery

Fetch provider metadata from `{issuer}/.well-known/openid-configuration`:

```json
{
  "issuer": "https://auth.example.com",
  "authorization_endpoint": "https://auth.example.com/authorize",
  "token_endpoint": "https://auth.example.com/token",
  "userinfo_endpoint": "https://auth.example.com/userinfo",
  "jwks_uri": "https://auth.example.com/.well-known/jwks.json",
  "scopes_supported": ["openid", "profile", "email", "offline_access"],
  "response_types_supported": ["code"],
  "id_token_signing_alg_values_supported": ["RS256"]
}
```

### ID Token

A signed JWT containing identity claims. Validate before trusting:

1. Verify signature against JWKS from `jwks_uri`.
2. Check `iss` matches the expected issuer.
3. Check `aud` contains your `client_id`.
4. Check `exp` > current time, `iat` is reasonable.
5. Check `nonce` matches the one sent in the authorization request.
6. For `at_hash`, verify it matches the access token hash.

Standard claims: `sub`, `name`, `email`, `email_verified`, `picture`, `locale`.

### Userinfo Endpoint

Fetch additional claims with the access token:

```
GET /userinfo
Authorization: Bearer <access_token>

Response: {"sub": "user123", "name": "Jane Doe", "email": "jane@example.com"}
```

Use userinfo when you need claims not included in the ID token, or when tokens are too large.

## Scopes Design

```
openid              → Required for OIDC. Returns sub claim.
profile             → name, family_name, picture, locale, etc.
email               → email, email_verified
offline_access      → Issues refresh token
api:read            → Custom: read access to API
api:write           → Custom: write access to API
orders:manage       → Custom: domain-specific permission
```

Design scopes as `resource:action`. Keep them coarse enough to be meaningful at consent time. Avoid per-endpoint scopes—use them for logical capability groups.

## Token Management

### Access Tokens

- Short-lived: 5–15 minutes.
- Use as Bearer token in `Authorization` header. Never in query strings (OAuth 2.1).
- Prefer opaque tokens for first-party APIs (validated via introspection).
- Use JWTs for distributed/third-party APIs where introspection is impractical.

### Refresh Tokens

- Long-lived but constrained. Bind to client.
- Implement **rotation**: issue a new refresh token with every use. Invalidate the old one.
- Detect reuse of an already-rotated refresh token → revoke the entire token family (breach signal).
- Store server-side or in secure HTTP-only cookies. Never in localStorage.

### Token Rotation Flow

```
Client ──refresh_token_1──> Auth Server
       <── access_token_2, refresh_token_2
       (refresh_token_1 is now invalid)

Client ──refresh_token_2──> Auth Server
       <── access_token_3, refresh_token_3

Attacker ──refresh_token_1──> Auth Server
         <── ERROR: token reuse detected
         (All tokens in family revoked)
```

### Token Introspection (RFC 7662)

Resource servers validate opaque tokens:

```
POST /introspect
token=<access_token>&token_type_hint=access_token

Response: {"active": true, "scope": "api:read", "sub": "user123", "exp": 1700000000}
```

### Token Revocation (RFC 7009)

```
POST /revoke
token=<refresh_token>&token_type_hint=refresh_token
```

Revoke refresh tokens on logout, password change, or suspected compromise.

## Security Requirements

### PKCE — Mandatory

Always use `S256` method. Never use `plain`. Generate a new `code_verifier` per request.

### State Parameter

Bind to user session. Verify on callback. Prevents CSRF on the authorization endpoint.

```python
state = secrets.token_urlsafe(32)
session["oauth_state"] = state
# On callback:
assert request.args["state"] == session.pop("oauth_state")
```

### Redirect URI Validation

- Register exact redirect URIs. No wildcards (OAuth 2.1).
- Compare using exact string match—no pattern matching.
- Mobile apps: use HTTPS App Links / Universal Links. Avoid custom URI schemes.

### Token Binding

Bind tokens to TLS channel (mTLS, DPoP) when possible. Prevents token export/replay.

DPoP (Demonstrating Proof-of-Possession) example header:

```
POST /token
DPoP: <signed JWT proving possession of private key>
Authorization: DPoP <access_token>
```

## Backend-for-Frontend (BFF) Pattern

For SPAs: move all OAuth logic to a backend proxy. The browser never sees tokens.

```
┌─────────┐    cookie     ┌─────┐   access_token   ┌─────────┐
│ Browser │──────────────>│ BFF │──────────────────>│   API   │
│  (SPA)  │<──────────────│     │<──────────────────│ Server  │
└─────────┘  HTTP-only    └─────┘                   └─────────┘
             SameSite
             Secure
```

BFF responsibilities:
- Handle authorization code + PKCE flow as a confidential client.
- Store tokens server-side (encrypted, in-memory or secure store).
- Issue HTTP-only, Secure, SameSite=Lax/Strict session cookies to browser.
- Proxy API requests, attaching the access token.
- Handle token refresh transparently.
- Implement CSRF protection on all BFF endpoints.

```typescript
// Express.js BFF token proxy example
app.get("/auth/callback", async (req, res) => {
  const { code, state } = req.query;
  if (state !== req.session.oauthState) return res.status(403).send("Invalid state");

  const tokens = await exchangeCode(code, req.session.codeVerifier);
  req.session.accessToken = tokens.access_token;
  req.session.refreshToken = tokens.refresh_token;
  req.session.tokenExpiry = Date.now() + tokens.expires_in * 1000;
  res.redirect("/");
});

app.use("/api", async (req, res, next) => {
  if (Date.now() > req.session.tokenExpiry) {
    const tokens = await refreshAccessToken(req.session.refreshToken);
    req.session.accessToken = tokens.access_token;
    req.session.refreshToken = tokens.refresh_token;
    req.session.tokenExpiry = Date.now() + tokens.expires_in * 1000;
  }
  req.headers.authorization = `Bearer ${req.session.accessToken}`;
  proxy.web(req, res, { target: API_SERVER });
});
```

## OIDC Session Management & Logout

### RP-Initiated Logout

Redirect user to end the session at the provider:

```
GET /logout?
  id_token_hint=<id_token>&
  post_logout_redirect_uri=https://app.example.com/logged-out&
  state=<state>
```

### Back-Channel Logout

Provider sends a logout token to registered endpoints:

```
POST /backchannel-logout
logout_token=<signed JWT with sub and sid claims>
```

On receipt: invalidate all sessions for the `sub`/`sid`. Respond 200 OK.

### Front-Channel Logout

Provider loads an iframe pointing to your logout URL. Less reliable—prefer back-channel.

## Provider Integration Patterns

### Auth0

```python
# .env
AUTH0_DOMAIN=your-tenant.auth0.com
AUTH0_CLIENT_ID=xxx
AUTH0_CLIENT_SECRET=yyy
AUTH0_AUDIENCE=https://api.example.com

# Discovery: https://your-tenant.auth0.com/.well-known/openid-configuration
# Use audience parameter to get an access token for your API.
```

### Okta

```python
OKTA_ISSUER=https://your-org.okta.com/oauth2/default
# Discovery: {OKTA_ISSUER}/.well-known/openid-configuration
# Use default authorization server or create custom ones per API.
```

### Keycloak

```python
KEYCLOAK_ISSUER=https://keycloak.example.com/realms/your-realm
# Discovery: {KEYCLOAK_ISSUER}/.well-known/openid-configuration
# Configure clients in realm settings. Use confidential client type for BFF.
```

### Google

```python
GOOGLE_ISSUER=https://accounts.google.com
# Discovery: https://accounts.google.com/.well-known/openid-configuration
# Scopes: openid, profile, email. Use consent prompt for offline_access.
```

For all providers: always fetch discovery document at startup. Cache JWKS with TTL. Do not hardcode endpoints.

## Common Vulnerabilities

### CSRF on Authorization Endpoint

**Attack**: Attacker initiates OAuth flow, tricks victim into completing it → victim's account linked to attacker's identity.
**Fix**: Validate `state` parameter. Bind to user session.

### Open Redirect via redirect_uri

**Attack**: Attacker modifies `redirect_uri` to exfiltrate the authorization code.
**Fix**: Exact match registered redirect URIs only. No wildcard, no pattern matching.

### Token Leakage

**Attack**: Tokens exposed via referrer headers, browser history, or logs.
**Fix**: Never put tokens in URLs. Use POST for token exchange. Set `Referrer-Policy: no-referrer`. Use BFF pattern for SPAs.

### Authorization Code Injection

**Attack**: Attacker injects a stolen authorization code into victim's session.
**Fix**: PKCE binds the code to the original client. Always use PKCE.

### Mix-Up Attacks

**Attack**: When using multiple providers, attacker tricks client into sending code to wrong provider's token endpoint.
**Fix**: Validate `iss` in the authorization response (RFC 9207). Compare provider metadata per-request.

### Refresh Token Theft

**Attack**: Stolen refresh token used to mint new access tokens indefinitely.
**Fix**: Token rotation + reuse detection. Bind tokens to client (mTLS/DPoP). Short refresh token lifetimes for public clients.

## Checklist

```
[ ] PKCE with S256 on every authorization request
[ ] State parameter validated against session
[ ] Exact redirect URI matching, no wildcards
[ ] HTTPS on all endpoints, no exceptions
[ ] Tokens never in URLs or localStorage
[ ] Access tokens short-lived (5–15 min)
[ ] Refresh token rotation with reuse detection
[ ] ID token signature and claims validated
[ ] Discovery document fetched, not hardcoded
[ ] BFF pattern for browser-based apps
[ ] Back-channel logout implemented
[ ] CSRF protection on all callback endpoints
[ ] Token revocation on logout and password change
[ ] Sender-constrained tokens (DPoP/mTLS) where feasible
```
