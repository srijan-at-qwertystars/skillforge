# OAuth 2.0 / OIDC Provider Integration Guides

## Table of Contents

- [1. Google](#1-google)
- [2. GitHub](#2-github)
- [3. Microsoft Entra ID](#3-microsoft-entra-id)
- [4. Auth0](#4-auth0)
- [5. Keycloak](#5-keycloak)
- [6. Okta](#6-okta)
- [7. Cross-Provider Patterns](#7-cross-provider-patterns)

---

## 1. Google

### App Registration

1. Go to [Google Cloud Console](https://console.cloud.google.com/) → APIs & Services → Credentials
2. Click **Create Credentials** → **OAuth client ID**
3. Select application type (Web application, iOS, Android, Desktop)
4. Configure **Authorized redirect URIs** (exact match required)
5. Note your `client_id` and `client_secret`
6. Configure OAuth Consent Screen: app name, support email, scopes, authorized domains

### Endpoints

```
Discovery:     https://accounts.google.com/.well-known/openid-configuration
Authorization: https://accounts.google.com/o/oauth2/v2/auth
Token:         https://oauth2.googleapis.com/token
UserInfo:      https://openidconnect.googleapis.com/v1/userinfo
JWKS:          https://www.googleapis.com/oauth2/v3/certs
Revocation:    https://oauth2.googleapis.com/revoke
```

### Scopes

```
# OIDC standard
openid                    — OpenID Connect authentication
profile                   — Name, picture, locale
email                     — Email address and verified status

# Google APIs (examples)
https://www.googleapis.com/auth/calendar.readonly
https://www.googleapis.com/auth/drive.file
https://www.googleapis.com/auth/gmail.readonly

# Sensitive/restricted scopes require Google verification review
```

### Authorization Request

```
GET https://accounts.google.com/o/oauth2/v2/auth?
  response_type=code
  &client_id=CLIENT_ID.apps.googleusercontent.com
  &redirect_uri=https://app.example.com/auth/google/callback
  &scope=openid%20profile%20email
  &state=RANDOM_STATE
  &nonce=RANDOM_NONCE
  &code_challenge=CODE_CHALLENGE
  &code_challenge_method=S256
  &access_type=offline
  &prompt=consent
  &include_granted_scopes=true
```

- `access_type=offline` — request a refresh token
- `prompt=consent` — force consent screen (required to get refresh token after first auth)
- `include_granted_scopes=true` — incremental authorization (keep previously granted scopes)

### Token Exchange

```http
POST https://oauth2.googleapis.com/token
Content-Type: application/x-www-form-urlencoded

grant_type=authorization_code
&code=AUTH_CODE
&redirect_uri=https://app.example.com/auth/google/callback
&client_id=CLIENT_ID.apps.googleusercontent.com
&client_secret=CLIENT_SECRET
&code_verifier=CODE_VERIFIER
```

### UserInfo Mapping

```json
{
  "sub": "110248495921238986420",
  "name": "Jane Doe",
  "given_name": "Jane",
  "family_name": "Doe",
  "picture": "https://lh3.googleusercontent.com/...",
  "email": "jane@example.com",
  "email_verified": true,
  "locale": "en"
}
```

### Logout

Google does not support OIDC `end_session_endpoint`. To log out:

1. Revoke the token:
```http
POST https://oauth2.googleapis.com/revoke
Content-Type: application/x-www-form-urlencoded
token=REFRESH_TOKEN_OR_ACCESS_TOKEN
```

2. Clear your application session locally.

### Google-Specific Notes

- **Refresh token limits**: Max 100 per user per client. Oldest auto-revoked.
- **Testing mode**: Refresh tokens expire in 7 days while app is in testing.
- **Service accounts**: Use for server-to-server. Sign JWT, exchange for access token.
- **Workforce Identity Federation**: Allows external IdPs to get Google tokens without service account keys.

---

## 2. GitHub

### App Registration

**GitHub OAuth App:**
1. Go to GitHub → Settings → Developer settings → OAuth Apps → New OAuth App
2. Set Application name, Homepage URL, Authorization callback URL
3. Note `client_id` and generate `client_secret`

**GitHub App (recommended for new projects):**
1. Settings → Developer settings → GitHub Apps → New GitHub App
2. Configure permissions (more granular than OAuth scopes)
3. Set callback URL and webhook URL (optional)
4. Generate private key for JWT authentication

### Endpoints

```
Authorization: https://github.com/login/oauth/authorize
Token:         https://github.com/login/oauth/access_token
User API:      https://api.github.com/user
User emails:   https://api.github.com/user/emails
```

**⚠️ GitHub is NOT a full OIDC provider:**
- No `id_token`
- No OIDC discovery document
- No JWKS endpoint
- No standard userinfo endpoint

### Scopes

```
# Repository
repo                  — Full control of private repositories
repo:status           — Access commit status
repo:deployment       — Access deployment status
public_repo           — Access public repositories only

# User
read:user             — Read user profile data
user:email            — Read user email addresses
user:follow           — Follow and unfollow users

# Organization
read:org              — Read org and team membership
admin:org             — Full control of orgs and teams

# Other
gist                  — Create and manage gists
notifications         — Access notifications
write:packages        — Upload packages to GitHub Packages
delete:packages       — Delete packages
admin:gpg_key         — Manage GPG keys
```

### Authorization Request

```
GET https://github.com/login/oauth/authorize?
  client_id=CLIENT_ID
  &redirect_uri=https://app.example.com/auth/github/callback
  &scope=read:user%20user:email
  &state=RANDOM_STATE
  &allow_signup=true
```

- `allow_signup=true|false` — allow/disallow sign-up during OAuth flow

### Token Exchange

```http
POST https://github.com/login/oauth/access_token
Accept: application/json
Content-Type: application/x-www-form-urlencoded

client_id=CLIENT_ID
&client_secret=CLIENT_SECRET
&code=AUTH_CODE
&redirect_uri=https://app.example.com/auth/github/callback
```

**⚠️ Must include `Accept: application/json`** — default response is form-encoded.

### Response

```json
{
  "access_token": "gho_xxxxxxxxxxxx",
  "token_type": "bearer",
  "scope": "read:user,user:email"
}
```

- No `refresh_token` (classic OAuth tokens don't expire)
- No `id_token`
- No `expires_in` (for classic tokens)

### User Identity

```http
GET https://api.github.com/user
Authorization: Bearer gho_xxxxxxxxxxxx
Accept: application/vnd.github+json
```

```json
{
  "login": "janedoe",
  "id": 12345678,
  "avatar_url": "https://avatars.githubusercontent.com/u/12345678",
  "name": "Jane Doe",
  "email": "jane@example.com",
  "two_factor_authentication": true
}
```

For email (if profile email is private):
```http
GET https://api.github.com/user/emails
```

```json
[
  { "email": "jane@example.com", "primary": true, "verified": true },
  { "email": "jane@work.com", "primary": false, "verified": true }
]
```

### Logout

GitHub has no logout endpoint. Revoke via Settings → Applications → Revoke, or via API:
```http
DELETE https://api.github.com/applications/CLIENT_ID/grant
Authorization: Basic BASE64(client_id:client_secret)
Content-Type: application/json

{ "access_token": "gho_xxxxxxxxxxxx" }
```

### GitHub-Specific Notes

- **GitHub Apps vs OAuth Apps**: Prefer GitHub Apps — more granular permissions, installation tokens, higher rate limits
- **Token prefixes**: `gho_` (OAuth), `ghp_` (PAT), `ghs_` (GitHub App installation)
- **Device flow**: GitHub supports device flow for CLI tools (see RFC 8628)
- **PKCE**: GitHub does not support PKCE as of 2024 (relies on client_secret)

---

## 3. Microsoft Entra ID

### App Registration

1. Go to [Entra ID portal](https://entra.microsoft.com/) → App registrations → New registration
2. Set name, supported account types, redirect URI
3. Note Application (client) ID and Directory (tenant) ID
4. Certificates & secrets → New client secret (or upload certificate)
5. API permissions → Add permissions → Microsoft Graph → select permissions
6. For multi-tenant: admin consent may be required

### Account Types

| Setting | Tenant Value | Description |
|---------|-------------|-------------|
| Single tenant | `TENANT_ID` | Only this org's accounts |
| Multi-tenant | `organizations` | Any Entra ID org account |
| Multi-tenant + personal | `common` | Any Microsoft account |
| Personal only | `consumers` | Microsoft personal accounts |

### Endpoints (v2.0)

```
Discovery:     https://login.microsoftonline.com/{tenant}/v2.0/.well-known/openid-configuration
Authorization: https://login.microsoftonline.com/{tenant}/oauth2/v2.0/authorize
Token:         https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token
UserInfo:      https://graph.microsoft.com/oidc/userinfo
JWKS:          https://login.microsoftonline.com/{tenant}/discovery/v2.0/keys
Logout:        https://login.microsoftonline.com/{tenant}/oauth2/v2.0/logout
```

### Scopes

```
# OIDC standard
openid profile email offline_access

# Microsoft Graph
https://graph.microsoft.com/User.Read
https://graph.microsoft.com/Mail.Read
https://graph.microsoft.com/Calendars.ReadWrite
https://graph.microsoft.com/Files.Read.All

# .default scope — requests all statically consented permissions
https://graph.microsoft.com/.default

# Custom API scopes
api://CLIENT_ID/access_as_user
```

### Authorization Request

```
GET https://login.microsoftonline.com/common/oauth2/v2.0/authorize?
  response_type=code
  &client_id=CLIENT_ID
  &redirect_uri=https://app.example.com/auth/microsoft/callback
  &scope=openid%20profile%20email%20offline_access%20https://graph.microsoft.com/User.Read
  &state=RANDOM_STATE
  &nonce=RANDOM_NONCE
  &code_challenge=CODE_CHALLENGE
  &code_challenge_method=S256
  &response_mode=query
```

### Token Exchange

```http
POST https://login.microsoftonline.com/common/oauth2/v2.0/token
Content-Type: application/x-www-form-urlencoded

grant_type=authorization_code
&code=AUTH_CODE
&redirect_uri=https://app.example.com/auth/microsoft/callback
&client_id=CLIENT_ID
&client_secret=CLIENT_SECRET
&code_verifier=CODE_VERIFIER
&scope=openid%20profile%20email%20offline_access
```

### UserInfo Mapping

Standard OIDC userinfo is available, but Microsoft Graph provides richer data:

```http
GET https://graph.microsoft.com/v1.0/me
Authorization: Bearer ACCESS_TOKEN
```

```json
{
  "id": "48d31887-5fad-4d73-a9f5-3c356e68a038",
  "displayName": "Jane Doe",
  "givenName": "Jane",
  "surname": "Doe",
  "mail": "jane@contoso.com",
  "userPrincipalName": "jane@contoso.onmicrosoft.com",
  "jobTitle": "Software Engineer",
  "officeLocation": "Building 1"
}
```

### Logout

```
GET https://login.microsoftonline.com/common/oauth2/v2.0/logout?
  post_logout_redirect_uri=https://app.example.com
```

### Entra ID-Specific Notes

- **Conditional Access**: Policies can block token issuance based on device, location, risk
- **AADSTS errors**: Prefix `AADSTS` followed by error code — searchable in Microsoft docs
- **Application permissions vs Delegated permissions**: Application = daemon/service; Delegated = on behalf of user
- **Certificate authentication**: Preferred over client secrets for production (client secrets expire)
- **On-behalf-of flow**: Exchange user token for downstream API token (similar to token exchange)

---

## 4. Auth0

### App Registration

1. Go to [Auth0 Dashboard](https://manage.auth0.com/) → Applications → Create Application
2. Select app type (Regular Web, SPA, Native, Machine to Machine)
3. Configure Allowed Callback URLs, Allowed Logout URLs, Allowed Web Origins
4. Note Domain, Client ID, Client Secret (for confidential clients)
5. Create an API: APIs → Create API → Set identifier (audience) and signing algorithm

### Endpoints

```
Discovery:     https://YOUR_DOMAIN/.well-known/openid-configuration
Authorization: https://YOUR_DOMAIN/authorize
Token:         https://YOUR_DOMAIN/oauth/token
UserInfo:      https://YOUR_DOMAIN/userinfo
JWKS:          https://YOUR_DOMAIN/.well-known/jwks.json
Logout:        https://YOUR_DOMAIN/v2/logout
Revocation:    https://YOUR_DOMAIN/oauth/revoke
```

### Scopes

```
# OIDC standard
openid profile email

# Refresh token
offline_access

# Custom API scopes (defined per API in dashboard)
read:messages
write:messages
admin:users

# Auth0 Management API scopes
read:users
update:users
create:users
```

### Authorization Request

```
GET https://YOUR_DOMAIN/authorize?
  response_type=code
  &client_id=CLIENT_ID
  &redirect_uri=https://app.example.com/callback
  &scope=openid%20profile%20email%20offline_access
  &audience=https://api.example.com
  &state=RANDOM_STATE
  &nonce=RANDOM_NONCE
  &code_challenge=CODE_CHALLENGE
  &code_challenge_method=S256
```

**⚠️ `audience` is critical**: Without it, Auth0 returns an opaque access token usable only at `/userinfo`. With `audience`, it returns a JWT access token for your API.

### Token Exchange

```http
POST https://YOUR_DOMAIN/oauth/token
Content-Type: application/x-www-form-urlencoded

grant_type=authorization_code
&code=AUTH_CODE
&redirect_uri=https://app.example.com/callback
&client_id=CLIENT_ID
&client_secret=CLIENT_SECRET
&code_verifier=CODE_VERIFIER
```

### UserInfo Mapping

```json
{
  "sub": "auth0|507f1f77bcf86cd799439011",
  "name": "Jane Doe",
  "nickname": "janedoe",
  "picture": "https://s.gravatar.com/avatar/...",
  "email": "jane@example.com",
  "email_verified": true,
  "updated_at": "2024-01-15T10:30:00.000Z"
}
```

### Custom Claims via Actions

```javascript
// Auth0 Action: Login / Post Login
exports.onExecutePostLogin = async (event, api) => {
  const namespace = 'https://api.example.com';
  api.accessToken.setCustomClaim(`${namespace}/roles`, event.authorization.roles);
  api.idToken.setCustomClaim(`${namespace}/roles`, event.authorization.roles);
};
```

### Logout

```
GET https://YOUR_DOMAIN/v2/logout?
  client_id=CLIENT_ID
  &returnTo=https://app.example.com
```

`returnTo` must be listed in "Allowed Logout URLs" in the dashboard.

### Auth0-Specific Notes

- **Custom domains**: Use a custom domain for production to avoid third-party cookie issues
- **Refresh token rotation**: Enable per-application in dashboard → Settings → Refresh Token Rotation
- **Rate limits**: Varies by plan — check Auth0 rate limit headers
- **Universal Login vs Embedded Login**: Universal (redirect) is recommended — more secure, easier to customize
- **Organizations**: Multi-tenant feature — separate login experiences per org
- **Connections**: Social (Google, GitHub), database, enterprise (SAML, OIDC), passwordless

---

## 5. Keycloak

### Setup & App Registration

1. Access Admin Console: `https://keycloak.example.com/admin`
2. Create a Realm (or use existing): Realm Settings → Create
3. Create a Client: Clients → Create client
   - Client type: OpenID Connect
   - Client ID: your-app
   - Client authentication: On (confidential) or Off (public)
   - Valid redirect URIs: `https://app.example.com/callback`
   - Web origins: `https://app.example.com` (for CORS)
4. Note Client ID and Client Secret (from Credentials tab)

### Endpoints

```
# All endpoints discoverable via:
Discovery: https://KEYCLOAK_HOST/realms/REALM/.well-known/openid-configuration

Authorization: https://KEYCLOAK_HOST/realms/REALM/protocol/openid-connect/auth
Token:         https://KEYCLOAK_HOST/realms/REALM/protocol/openid-connect/token
UserInfo:      https://KEYCLOAK_HOST/realms/REALM/protocol/openid-connect/userinfo
JWKS:          https://KEYCLOAK_HOST/realms/REALM/protocol/openid-connect/certs
Logout:        https://KEYCLOAK_HOST/realms/REALM/protocol/openid-connect/logout
Introspect:    https://KEYCLOAK_HOST/realms/REALM/protocol/openid-connect/token/introspect
Revoke:        https://KEYCLOAK_HOST/realms/REALM/protocol/openid-connect/revoke
Device Auth:   https://KEYCLOAK_HOST/realms/REALM/protocol/openid-connect/auth/device

# Admin API:
https://KEYCLOAK_HOST/admin/realms/REALM/...
```

### Scopes

```
# Default OIDC scopes (pre-configured)
openid profile email address phone
offline_access          — triggers refresh token issuance

# Custom scopes: Client Scopes → Create → Add to client as "Default" or "Optional"
# Scopes control which claims appear in tokens via Protocol Mappers
```

### Authorization Request

```
GET https://KEYCLOAK_HOST/realms/REALM/protocol/openid-connect/auth?
  response_type=code
  &client_id=your-app
  &redirect_uri=https://app.example.com/callback
  &scope=openid%20profile%20email
  &state=RANDOM_STATE
  &nonce=RANDOM_NONCE
  &code_challenge=CODE_CHALLENGE
  &code_challenge_method=S256
```

### Token Exchange

```http
POST https://KEYCLOAK_HOST/realms/REALM/protocol/openid-connect/token
Content-Type: application/x-www-form-urlencoded

grant_type=authorization_code
&code=AUTH_CODE
&redirect_uri=https://app.example.com/callback
&client_id=your-app
&client_secret=CLIENT_SECRET
&code_verifier=CODE_VERIFIER
```

### UserInfo Mapping

```json
{
  "sub": "f1d2d2f9-24a8-4e7a-a8e1-3c5b1e7d8a9f",
  "name": "Jane Doe",
  "preferred_username": "janedoe",
  "given_name": "Jane",
  "family_name": "Doe",
  "email": "jane@example.com",
  "email_verified": true,
  "realm_access": {
    "roles": ["user", "admin"]
  },
  "resource_access": {
    "your-app": {
      "roles": ["app-admin"]
    }
  }
}
```

### Roles & Claims Customization

```
# Realm Roles: global to the realm
Realm Settings → Realm Roles → Add Role

# Client Roles: scoped to a specific client
Clients → your-app → Roles → Add Role

# Include roles in tokens:
Client Scopes → roles → Mappers → realm roles (mapper type: User Realm Role)

# Custom attribute mapper:
Client Scopes → your-scope → Mappers → Create
→ Mapper type: User Attribute
→ User Attribute: department
→ Token Claim Name: department
→ Add to ID token: ON, Add to access token: ON
```

### Logout

**RP-Initiated Logout:**
```
GET https://KEYCLOAK_HOST/realms/REALM/protocol/openid-connect/logout?
  id_token_hint=ID_TOKEN
  &post_logout_redirect_uri=https://app.example.com
  &state=RANDOM_STATE
```

**Back-Channel Logout (server-to-server):**
Configure in Client → Settings → Back-Channel Logout URL

### Keycloak-Specific Notes

- **Token exchange**: Must be enabled per client (fine-grained permissions)
- **Themes**: Customizable login pages via themes (FreeMarker templates)
- **Identity brokering**: Keycloak can act as a proxy to external IdPs (Google, GitHub, SAML)
- **User Federation**: Connect to LDAP/AD for user storage
- **Admin REST API**: Full management API — clients, users, roles, sessions
- **Supported advanced features**: DPoP, PAR, CIBA, token exchange, device flow, mTLS

---

## 6. Okta

### App Registration

1. Go to [Okta Admin Console](https://YOUR_DOMAIN-admin.okta.com/)
2. Applications → Create App Integration
3. Select OIDC - OpenID Connect and application type
4. Configure sign-in redirect URIs and sign-out redirect URIs
5. Note Client ID and Client Secret
6. Create Authorization Server: Security → API → Add Authorization Server
7. Add scopes: Authorization Server → Scopes → Add Scope
8. Add claims: Authorization Server → Claims → Add Claim
9. Configure access policies: Authorization Server → Access Policies

### Endpoints

```
# Custom Authorization Server (recommended for APIs):
Discovery:     https://YOUR_DOMAIN.okta.com/oauth2/AUTH_SERVER_ID/.well-known/openid-configuration
Authorization: https://YOUR_DOMAIN.okta.com/oauth2/AUTH_SERVER_ID/v1/authorize
Token:         https://YOUR_DOMAIN.okta.com/oauth2/AUTH_SERVER_ID/v1/token
UserInfo:      https://YOUR_DOMAIN.okta.com/oauth2/AUTH_SERVER_ID/v1/userinfo
JWKS:          https://YOUR_DOMAIN.okta.com/oauth2/AUTH_SERVER_ID/v1/keys
Introspect:    https://YOUR_DOMAIN.okta.com/oauth2/AUTH_SERVER_ID/v1/introspect
Revoke:        https://YOUR_DOMAIN.okta.com/oauth2/AUTH_SERVER_ID/v1/revoke
Logout:        https://YOUR_DOMAIN.okta.com/oauth2/AUTH_SERVER_ID/v1/logout

# Org Authorization Server (Okta APIs only):
Discovery:     https://YOUR_DOMAIN.okta.com/.well-known/openid-configuration
Authorization: https://YOUR_DOMAIN.okta.com/oauth2/v1/authorize
Token:         https://YOUR_DOMAIN.okta.com/oauth2/v1/token

# "default" is the built-in custom authorization server:
# https://YOUR_DOMAIN.okta.com/oauth2/default/...
```

### Scopes

```
# OIDC standard
openid profile email address phone
offline_access

# Custom scopes (defined per authorization server)
api:read
api:write
admin:manage

# Okta API scopes (org authorization server only)
okta.users.manage
okta.apps.manage
```

### Authorization Request

```
GET https://YOUR_DOMAIN.okta.com/oauth2/default/v1/authorize?
  response_type=code
  &client_id=CLIENT_ID
  &redirect_uri=https://app.example.com/callback
  &scope=openid%20profile%20email%20offline_access
  &state=RANDOM_STATE
  &nonce=RANDOM_NONCE
  &code_challenge=CODE_CHALLENGE
  &code_challenge_method=S256
```

### Token Exchange

```http
POST https://YOUR_DOMAIN.okta.com/oauth2/default/v1/token
Content-Type: application/x-www-form-urlencoded

grant_type=authorization_code
&code=AUTH_CODE
&redirect_uri=https://app.example.com/callback
&client_id=CLIENT_ID
&client_secret=CLIENT_SECRET
&code_verifier=CODE_VERIFIER
```

### UserInfo Mapping

```json
{
  "sub": "00uid4BxXw6I6TV4m0g3",
  "name": "Jane Doe",
  "given_name": "Jane",
  "family_name": "Doe",
  "preferred_username": "jane@example.com",
  "email": "jane@example.com",
  "email_verified": true,
  "locale": "en-US",
  "zoneinfo": "America/Los_Angeles",
  "updated_at": 1705312200
}
```

### Custom Claims

In Okta Admin Console: Security → API → Authorization Server → Claims → Add Claim

Or via inline hooks for dynamic claims:
```json
{
  "commands": [
    {
      "type": "com.okta.access.patch",
      "value": [
        { "op": "add", "path": "/claims/roles", "value": ["admin", "user"] }
      ]
    }
  ]
}
```

### Logout

```
GET https://YOUR_DOMAIN.okta.com/oauth2/default/v1/logout?
  id_token_hint=ID_TOKEN
  &post_logout_redirect_uri=https://app.example.com
  &state=RANDOM_STATE
```

### Okta-Specific Notes

- **Org vs Custom Authorization Server**: Use custom for API tokens; org server only for Okta APIs
- **Access Policies & Rules**: Control who gets tokens and with which scopes
- **Inline Hooks**: Modify tokens/registration dynamically via webhook
- **Okta SDKs**: Available for React, Angular, Vue, iOS, Android, Java, .NET
- **Factor enrollment**: MFA factors configured per user or policy
- **Workforce vs Customer Identity**: Okta (workforce), Auth0 (customer identity, owned by Okta)

---

## 7. Cross-Provider Patterns

### Normalizing User Identity

Different providers return user data in different formats. Normalize to a common schema:

```javascript
function normalizeUser(provider, profile) {
  switch (provider) {
    case 'google':
      return {
        id: profile.sub,
        email: profile.email,
        emailVerified: profile.email_verified,
        name: profile.name,
        picture: profile.picture,
        provider: 'google',
      };
    case 'github':
      return {
        id: String(profile.id),
        email: profile.email, // may be null — fetch from /user/emails
        emailVerified: null,  // GitHub doesn't provide this in profile
        name: profile.name || profile.login,
        picture: profile.avatar_url,
        provider: 'github',
      };
    case 'microsoft':
      return {
        id: profile.id || profile.sub,
        email: profile.mail || profile.userPrincipalName,
        emailVerified: null,  // not in Graph /me response
        name: profile.displayName,
        picture: null,        // requires separate /me/photo request
        provider: 'microsoft',
      };
    case 'auth0':
      return {
        id: profile.sub,
        email: profile.email,
        emailVerified: profile.email_verified,
        name: profile.name || profile.nickname,
        picture: profile.picture,
        provider: 'auth0',
      };
  }
}
```

### Account Linking

When the same user authenticates via multiple providers:

```sql
-- Users table
CREATE TABLE users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email TEXT UNIQUE,
  name TEXT,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- Linked identities
CREATE TABLE user_identities (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES users(id),
  provider TEXT NOT NULL,         -- 'google', 'github', 'microsoft'
  provider_user_id TEXT NOT NULL, -- sub/id from provider
  access_token_enc TEXT,          -- encrypted
  refresh_token_enc TEXT,         -- encrypted
  UNIQUE (provider, provider_user_id)
);

-- On login: check if identity exists → link to existing user or create new
```

### Multi-Provider Discovery Configuration

```javascript
const providers = {
  google: {
    discoveryUrl: 'https://accounts.google.com/.well-known/openid-configuration',
    clientId: process.env.GOOGLE_CLIENT_ID,
    clientSecret: process.env.GOOGLE_CLIENT_SECRET,
    scopes: ['openid', 'profile', 'email'],
    isOidc: true,
  },
  github: {
    authorizationUrl: 'https://github.com/login/oauth/authorize',
    tokenUrl: 'https://github.com/login/oauth/access_token',
    userInfoUrl: 'https://api.github.com/user',
    clientId: process.env.GITHUB_CLIENT_ID,
    clientSecret: process.env.GITHUB_CLIENT_SECRET,
    scopes: ['read:user', 'user:email'],
    isOidc: false,  // No discovery, no id_token
  },
  microsoft: {
    discoveryUrl: 'https://login.microsoftonline.com/common/v2.0/.well-known/openid-configuration',
    clientId: process.env.MICROSOFT_CLIENT_ID,
    clientSecret: process.env.MICROSOFT_CLIENT_SECRET,
    scopes: ['openid', 'profile', 'email', 'offline_access'],
    isOidc: true,
  },
};
```

### Logout Across Providers

| Provider | Logout Mechanism | Notes |
|----------|-----------------|-------|
| Google | Token revocation only | No RP-initiated logout endpoint |
| GitHub | API revocation | No logout endpoint |
| Microsoft | `end_session_endpoint` | Supports RP-initiated logout, front-channel, back-channel |
| Auth0 | `/v2/logout` | Custom endpoint (not standard OIDC) |
| Keycloak | `end_session_endpoint` | Full OIDC logout support (RP-initiated, back-channel) |
| Okta | `end_session_endpoint` | Full OIDC logout support |
