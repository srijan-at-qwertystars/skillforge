---
name: oauth2-patterns
description: >
  Guide for implementing OAuth 2.0 and OAuth 2.1 authorization flows, including
  authorization code grant with PKCE, client credentials, device code flow, refresh
  token rotation, access token management, and OpenID Connect (OIDC) integration.
  Covers token storage security, scope design, provider integration (Google, GitHub,
  Microsoft, Auth0, Okta), and vulnerability mitigation.
  Use when: implementing OAuth 2.0, OAuth 2.1, authorization code flow, PKCE,
  access tokens, refresh tokens, OpenID Connect, OIDC, third-party auth, social login,
  token exchange, or integrating external identity providers.
  Do NOT use when: implementing simple API key authentication, HTTP basic auth,
  session-only auth without external identity providers, JWT-only auth without OAuth
  flows, or SAML-based federation.
---

# OAuth 2.0 / 2.1 Implementation Patterns

## OAuth 2.0 vs 2.1 Key Differences

OAuth 2.1 consolidates security best practices into the core spec. Apply these rules:

- Require PKCE for ALL authorization code flows (public and confidential clients).
- Remove implicit grant and resource owner password credentials (ROPC) grant entirely.
- Enforce exact redirect URI string matching — no wildcards or partial matches.
- Prohibit bearer tokens in URL query parameters; use `Authorization` header or POST body only.
- Require refresh token rotation or sender-constraining for all refresh tokens.
- Mandate HTTPS for all OAuth endpoints with no exceptions.

Treat OAuth 2.1 rules as the baseline even when targeting OAuth 2.0 servers.

## Grant Types

### Authorization Code Grant (+ PKCE) — Primary Flow

Use for: web apps, SPAs, mobile apps, CLI tools with browser redirect.

```
1. Client generates code_verifier (43-128 char cryptographic random string)
2. Client computes code_challenge = BASE64URL(SHA256(code_verifier))
3. Client redirects user to authorization endpoint:
   GET /authorize?
     response_type=code&
     client_id=CLIENT_ID&
     redirect_uri=https://app.example.com/callback&
     scope=openid profile email&
     state=RANDOM_STATE&
     code_challenge=CHALLENGE&
     code_challenge_method=S256
4. User authenticates and consents
5. Authorization server redirects to callback with code and state
6. Client verifies state matches, then exchanges code for tokens:
   POST /token
     grant_type=authorization_code&
     code=AUTH_CODE&
     redirect_uri=https://app.example.com/callback&
     client_id=CLIENT_ID&
     code_verifier=ORIGINAL_VERIFIER
7. Server validates code_verifier against stored challenge, returns tokens
```

### Client Credentials Grant

Use for: service-to-service (M2M) communication with no user context.

```
POST /token
  grant_type=client_credentials&
  client_id=SERVICE_ID&
  client_secret=SERVICE_SECRET&
  scope=api:read api:write
```

Never use for flows involving end users. Store client_secret in environment variables or secret managers — never in source code.

### Device Code Grant

Use for: input-constrained devices (smart TVs, CLI tools, IoT).

```
1. POST /device/code → returns device_code, user_code, verification_uri
2. Display user_code and verification_uri to user
3. Poll POST /token with grant_type=urn:ietf:params:oauth:grant-type:device_code
   and device_code until user completes browser auth
4. Respect interval and slow_down responses; use exponential backoff
```

### Refresh Token Grant

Use to obtain new access tokens without re-authenticating the user.

```
POST /token
  grant_type=refresh_token&
  refresh_token=CURRENT_REFRESH_TOKEN&
  client_id=CLIENT_ID
```

Implement refresh token rotation: invalidate the old refresh token when issuing a new one. Detect reuse of revoked refresh tokens as a breach signal and revoke the entire grant.

### Deprecated Grants — Do Not Implement

- **Implicit grant**: Exposes tokens in URL fragments. Replaced by authorization code + PKCE.
- **Resource Owner Password Credentials (ROPC)**: Requires the app to handle user passwords directly. Use authorization code flow instead.

## PKCE Implementation

Generate the code verifier and challenge at the start of every authorization request:

```javascript
// Node.js PKCE implementation
import crypto from 'node:crypto';

function generateCodeVerifier() {
  return crypto.randomBytes(32).toString('base64url');
}

function generateCodeChallenge(verifier) {
  return crypto.createHash('sha256').update(verifier).digest('base64url');
}

const codeVerifier = generateCodeVerifier();
const codeChallenge = generateCodeChallenge(codeVerifier);
// Store codeVerifier in session; send codeChallenge in /authorize request
```

```python
# Python PKCE implementation
import secrets, hashlib, base64

def generate_code_verifier() -> str:
    return secrets.token_urlsafe(32)

def generate_code_challenge(verifier: str) -> str:
    digest = hashlib.sha256(verifier.encode()).digest()
    return base64.urlsafe_b64encode(digest).rstrip(b"=").decode()
```

Always use `S256` for `code_challenge_method`. Never use `plain` in production.

## Token Types

### Access Tokens
- Short-lived (5-60 minutes typical). Sent via `Authorization: Bearer <token>` header.
- Can be opaque strings or JWTs. Validate JWT access tokens by checking signature, `exp`, `iss`, `aud`, and scopes.

### Refresh Tokens
- Long-lived (hours to days). Used only at the token endpoint, never sent to resource servers.
- Implement rotation: each use returns a new refresh token and invalidates the old one.
- Set absolute expiration (e.g., 30 days) regardless of rotation.

### ID Tokens (OpenID Connect)
- JWT containing user identity claims. Validate signature, `iss`, `aud`, `exp`, `nonce`, and `at_hash`.
- Never use ID tokens as access tokens — they serve different purposes.

## OpenID Connect (OIDC)

OIDC adds an identity layer on top of OAuth 2.0. Include the `openid` scope to receive an ID token.

### Standard Scopes and Claims

| Scope     | Claims Returned                                              |
|-----------|--------------------------------------------------------------|
| `openid`  | `sub` (subject identifier)                                   |
| `profile` | `name`, `given_name`, `family_name`, `picture`, `locale`     |
| `email`   | `email`, `email_verified`                                    |
| `address` | `address` (structured JSON object)                           |
| `phone`   | `phone_number`, `phone_number_verified`                      |

### Userinfo Endpoint

Fetch additional claims after obtaining an access token:

```
GET /userinfo
Authorization: Bearer <access_token>

Response:
{
  "sub": "user-abc-123",
  "name": "Jane Doe",
  "email": "jane@example.com",
  "email_verified": true,
  "picture": "https://example.com/photo.jpg"
}
```

Always verify that the `sub` claim from `/userinfo` matches the `sub` in the ID token.

### Discovery Document

Fetch provider configuration from `/.well-known/openid-configuration`:

```
GET https://accounts.google.com/.well-known/openid-configuration
→ Returns authorization_endpoint, token_endpoint, userinfo_endpoint, jwks_uri, etc.
```

Use this to avoid hardcoding provider URLs.

## Token Storage Security

### Browser (SPA)
- Store access tokens in memory only (JavaScript closure or module-scoped variable).
- Use a backend-for-frontend (BFF) pattern: let the server handle tokens, issue `HttpOnly; Secure; SameSite=Strict` session cookies to the browser.
- Never store tokens in `localStorage` or `sessionStorage` — vulnerable to XSS.

### Mobile Apps
- Use OS secure storage: iOS Keychain, Android Keystore.
- Use system browser (ASWebAuthenticationSession / Custom Tabs) for auth — not embedded WebViews.
- Store refresh tokens in secure storage; keep access tokens in memory.

### Server-Side
- Encrypt tokens at rest using AES-256-GCM or equivalent.
- Store in a database with per-user encryption keys or use a secrets manager (Vault, AWS Secrets Manager).
- Log token operations (issue, refresh, revoke) but never log token values.

## Token Refresh Strategies

Implement proactive refresh to avoid failed API calls:

```javascript
// Proactive token refresh
async function getValidAccessToken(tokenStore) {
  const { accessToken, expiresAt, refreshToken } = tokenStore.get();
  const bufferMs = 60_000; // refresh 60s before expiry
  if (Date.now() < expiresAt - bufferMs) return accessToken;

  const response = await fetch('/oauth/token', {
    method: 'POST',
    body: new URLSearchParams({
      grant_type: 'refresh_token',
      refresh_token: refreshToken,
      client_id: CLIENT_ID,
    }),
  });

  if (!response.ok) {
    tokenStore.clear();
    throw new Error('Token refresh failed — re-authenticate user');
  }

  const tokens = await response.json();
  tokenStore.save(tokens);
  return tokens.access_token;
}
```

Use a mutex or queue to prevent concurrent refresh requests from racing. If refresh fails with `invalid_grant`, redirect the user to re-authenticate.

## Scopes and Permissions Design

- Define granular, resource-specific scopes: `read:users`, `write:orders`, `admin:billing`.
- Request minimum scopes needed. Use incremental authorization to request additional scopes later.
- Document scopes in API reference with clear descriptions of what each permits.
- Map scopes to internal permissions at the resource server — do not trust scope names alone.

Example scope hierarchy:

```
api:read          → read-only access to all resources
api:write         → read + write access
users:read        → read user profiles
users:write       → modify user profiles
admin:*           → full administrative access (restrict to internal clients)
```

## Provider Integration

### Common Provider Endpoints

| Provider  | Discovery URL                                                     |
|-----------|-------------------------------------------------------------------|
| Google    | `https://accounts.google.com/.well-known/openid-configuration`    |
| Microsoft | `https://login.microsoftonline.com/{tenant}/v2.0/.well-known/openid-configuration` |
| GitHub    | No OIDC discovery; use `https://github.com/login/oauth/authorize` and `/access_token` |
| Auth0     | `https://{domain}/.well-known/openid-configuration`               |
| Okta      | `https://{domain}/.well-known/openid-configuration`               |

### Provider-Specific Notes

- **Google**: Requires `access_type=offline` for refresh tokens; only issued on first consent unless `prompt=consent` is set.
- **GitHub**: Does not issue refresh tokens by default; tokens do not expire unless configured. Uses non-standard token endpoint (`Accept: application/json` header required).
- **Microsoft**: Use `/v2.0/` endpoints. Supports multi-tenant via `common` or `organizations` tenant.
- **Auth0**: Configure refresh token rotation in dashboard. Supports custom API audiences via `audience` parameter.
- **Okta**: Use authorization server ID in URL. Supports custom authorization servers for API access.

## Security Best Practices

### State Parameter
Generate a cryptographically random `state` value per authorization request. Store it server-side or in an encrypted cookie. Reject callbacks where `state` does not match.

### Nonce (OIDC)
Include a random `nonce` in authorization requests when requesting ID tokens. Validate the `nonce` claim in the returned ID token matches the stored value.

### Redirect URI Validation
- Register exact redirect URIs — no wildcards, no path traversal.
- Validate the redirect URI on the authorization server with exact string match.
- Use `https://` only; allow `http://localhost` only for development.

### Token Binding
- Use `DPoP` (Demonstration of Proof-of-Possession) headers when supported to bind tokens to a specific client key pair, preventing token theft and replay.

## Common Vulnerabilities and Mitigations

| Vulnerability              | Mitigation                                                         |
|----------------------------|--------------------------------------------------------------------|
| CSRF on callback           | Validate `state` parameter on every callback                      |
| Authorization code interception | Use PKCE with S256 challenge method                           |
| Token leakage via referrer | Set `Referrer-Policy: no-referrer` on callback pages              |
| Token leakage in logs      | Never log token values; log only metadata (expiry, scope, client) |
| Open redirect              | Exact redirect URI matching; reject unregistered URIs             |
| Refresh token theft        | Rotate refresh tokens; detect reuse as breach signal              |
| ID token replay            | Validate `nonce`, `exp`, `aud` claims                             |
| Insufficient scope         | Enforce scopes at resource server; never rely on client-side only |
| Mixed content / downgrade  | Enforce HTTPS on all endpoints; use HSTS headers                  |
| Clickjacking on consent    | Set `X-Frame-Options: DENY` on authorization pages                |

## Libraries and Frameworks

### Node.js / TypeScript
- **passport.js** + `passport-oauth2`: Flexible strategy-based auth middleware. Use with `passport-google-oauth20`, `passport-github2`.
- **next-auth** (Auth.js): Full-stack auth for Next.js with built-in provider support and session management.
- **openid-client**: Certified OIDC relying party library. Use for direct OIDC integration.
- **oslo** / **arctic**: Lightweight OAuth 2.0 libraries by the Lucia auth team.

### Python
- **authlib**: Full-featured OAuth/OIDC client and server library.
- **python-social-auth**: Multi-provider social auth with Django/Flask integration.
- **oauthlib** + **requests-oauthlib**: Low-level OAuth library for custom flows.

### Java / Spring
- **spring-security-oauth2-client**: Authorization code and client credentials flows with auto-configuration.
- **spring-security-oauth2-resource-server**: JWT and opaque token validation for resource servers.
- Configure via `application.yml`:

```yaml
spring:
  security:
    oauth2:
      client:
        registration:
          google:
            client-id: ${GOOGLE_CLIENT_ID}
            client-secret: ${GOOGLE_CLIENT_SECRET}
            scope: openid,profile,email
```

### Go
- **golang.org/x/oauth2**: Standard library for OAuth 2.0 flows.
- **coreos/go-oidc**: OIDC token verification and provider discovery.

Select libraries that are actively maintained, support PKCE, and handle token refresh automatically. Avoid writing custom OAuth flows from scratch.
