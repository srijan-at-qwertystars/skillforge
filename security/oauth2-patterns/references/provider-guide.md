# OAuth 2.0 Provider Integration Guide

Provider-specific configuration, discovery URLs, required scopes, token endpoint details, and gotchas for the most commonly used OAuth/OIDC providers.

---

## Google

### Discovery URL

```
https://accounts.google.com/.well-known/openid-configuration
```

### Key Endpoints

| Endpoint          | URL                                                  |
|-------------------|------------------------------------------------------|
| Authorization     | `https://accounts.google.com/o/oauth2/v2/auth`       |
| Token             | `https://oauth2.googleapis.com/token`                 |
| Userinfo          | `https://openidconnect.googleapis.com/v1/userinfo`    |
| JWKS              | `https://www.googleapis.com/oauth2/v3/certs`          |
| Revocation        | `https://oauth2.googleapis.com/revoke`                |

### Required Scopes

| Scope                                          | Data                             |
|------------------------------------------------|----------------------------------|
| `openid`                                       | Subject identifier (`sub`)       |
| `email`                                        | Email address, `email_verified`  |
| `profile`                                      | Name, picture, locale            |
| `https://www.googleapis.com/auth/drive.readonly` | Google Drive read access       |

### Token Endpoint Configuration

- **Auth method**: `client_secret_post` (send `client_secret` in POST body) or `client_secret_basic` (HTTP Basic auth).
- **Content-Type**: `application/x-www-form-urlencoded`.
- **PKCE**: Supported and recommended.

### Gotchas

1. **Refresh tokens are only issued on first consent**. To force a new refresh token, add `prompt=consent&access_type=offline` to the authorization request.
2. **`access_type=offline`** is required to get a refresh token at all. Without it, you only get an access token.
3. **Token expiry**: Access tokens expire in 1 hour. Refresh tokens do not expire unless revoked, but inactive refresh tokens (unused for 6 months) may be invalidated.
4. **Google-specific `hd` claim**: For Google Workspace accounts, the ID token includes an `hd` (hosted domain) claim. Validate this if restricting access to a specific organization.
5. **Incremental authorization**: You can request additional scopes later by including previously granted scopes plus new ones. Google will only show consent for the new scopes.
6. **Unverified apps**: Apps requesting sensitive scopes must go through Google's verification process, or users see a scary warning screen. Use only approved scopes in production.

---

## GitHub

### Key Endpoints

GitHub does **not** support OIDC discovery. There is no `/.well-known/openid-configuration`.

| Endpoint          | URL                                                  |
|-------------------|------------------------------------------------------|
| Authorization     | `https://github.com/login/oauth/authorize`            |
| Token             | `https://github.com/login/oauth/access_token`         |
| User API          | `https://api.github.com/user`                         |
| User Emails API   | `https://api.github.com/user/emails`                  |

### Required Scopes

| Scope             | Data                                          |
|-------------------|-----------------------------------------------|
| (no scope)        | Public profile info                           |
| `read:user`       | Read user profile data                        |
| `user:email`      | Read user email addresses                     |
| `repo`            | Full repository access                        |
| `read:org`        | Read organization membership                  |

### Token Endpoint Configuration

- **Auth method**: Send `client_id` and `client_secret` in the POST body.
- **Content-Type**: `application/x-www-form-urlencoded`.
- **Accept header**: You **must** set `Accept: application/json` to receive JSON responses. Without it, GitHub returns `application/x-www-form-urlencoded`.
- **PKCE**: Not supported.

### Gotchas

1. **No OIDC support**: GitHub does not issue ID tokens. You must call the `/user` API endpoint to get user information.
2. **No refresh tokens** (classic OAuth apps): Tokens do not expire by default. GitHub Apps support token expiration and refresh.
3. **`Accept: application/json`**: Without this header on the token endpoint, you get form-encoded responses instead of JSON.
4. **Email may be private**: The `/user` endpoint may return `null` for `email`. Use `/user/emails` to get the user's verified email addresses.
5. **GitHub Apps vs OAuth Apps**: GitHub Apps are the newer model with more granular permissions, installation-based access, and token expiration. Prefer GitHub Apps for new integrations.
6. **Rate limiting**: API calls are rate-limited to 5,000 requests/hour per authenticated user. Token endpoint calls are not rate-limited in the same way but are subject to abuse detection.

---

## Microsoft / Azure AD (Entra ID)

### Discovery URL

```
# Single-tenant
https://login.microsoftonline.com/{tenant-id}/v2.0/.well-known/openid-configuration

# Multi-tenant
https://login.microsoftonline.com/common/v2.0/.well-known/openid-configuration

# Organizations only (no personal accounts)
https://login.microsoftonline.com/organizations/v2.0/.well-known/openid-configuration

# Consumers only (personal Microsoft accounts)
https://login.microsoftonline.com/consumers/v2.0/.well-known/openid-configuration
```

### Key Endpoints

| Endpoint          | URL                                                                    |
|-------------------|------------------------------------------------------------------------|
| Authorization     | `https://login.microsoftonline.com/{tenant}/oauth2/v2.0/authorize`     |
| Token             | `https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token`         |
| Userinfo          | `https://graph.microsoft.com/oidc/userinfo`                            |
| JWKS              | `https://login.microsoftonline.com/{tenant}/discovery/v2.0/keys`       |

### Required Scopes

| Scope                          | Data                                   |
|--------------------------------|----------------------------------------|
| `openid`                       | Subject identifier                     |
| `profile`                      | Name, preferred username               |
| `email`                        | Email address                          |
| `User.Read`                    | Microsoft Graph user profile           |
| `offline_access`               | Refresh token                          |

### Token Endpoint Configuration

- **Auth method**: `client_secret_post` or `client_secret_basic`. Supports `private_key_jwt` and certificate-based auth.
- **Content-Type**: `application/x-www-form-urlencoded`.
- **PKCE**: Supported and recommended for SPAs and mobile apps.

### Gotchas

1. **Always use `/v2.0/` endpoints**. The v1.0 endpoints are legacy and have different token formats.
2. **Multi-tenant `iss` validation**: When using `common` or `organizations`, the `iss` claim contains the tenant ID. You must validate the `iss` dynamically, not against a static value.
3. **`offline_access` scope required**: Unlike some providers, Microsoft requires explicitly requesting `offline_access` to receive a refresh token.
4. **Graph API scopes use resource-based format**: e.g., `https://graph.microsoft.com/.default` or `User.Read`. These are different from standard OIDC scopes.
5. **Token audience**: Access tokens for Microsoft Graph have `aud: "https://graph.microsoft.com"`. Tokens for your own API have your app's `Application ID URI` as the audience.
6. **Consent framework**: Azure AD has admin consent for organization-wide scopes. Some scopes require a tenant admin to grant consent before users can authenticate.
7. **ID token `oid` vs `sub`**: The `sub` claim is pairwise (unique per application). Use `oid` (object ID) if you need a consistent user identifier across multiple applications in the same tenant.

---

## Auth0

### Discovery URL

```
https://{your-domain}.auth0.com/.well-known/openid-configuration
# or custom domain:
https://auth.yourdomain.com/.well-known/openid-configuration
```

### Key Endpoints

| Endpoint          | URL                                                  |
|-------------------|------------------------------------------------------|
| Authorization     | `https://{domain}/authorize`                          |
| Token             | `https://{domain}/oauth/token`                        |
| Userinfo          | `https://{domain}/userinfo`                           |
| JWKS              | `https://{domain}/.well-known/jwks.json`              |
| Revocation        | `https://{domain}/oauth/revoke`                       |

### Required Scopes

| Scope             | Data                                          |
|-------------------|-----------------------------------------------|
| `openid`          | Subject identifier                            |
| `profile`         | Name, nickname, picture                       |
| `email`           | Email address, `email_verified`               |
| `offline_access`  | Refresh token                                 |

### Token Endpoint Configuration

- **Auth method**: `client_secret_post` (default for SPAs), `client_secret_basic`, or `private_key_jwt`.
- **Content-Type**: `application/x-www-form-urlencoded` or `application/json` (Auth0 accepts both).
- **PKCE**: Supported and required for SPAs (native applications).

### Gotchas

1. **`audience` parameter is required** to get an access token for your API. Without it, Auth0 returns an opaque token valid only for `/userinfo`.
2. **Refresh token rotation**: Must be enabled in the Auth0 dashboard under Application Settings. Disabled by default.
3. **Rate limits**: Auth0 has aggressive rate limits on the `/oauth/token` endpoint — 300 requests per minute on free/developer plans.
4. **Custom domains**: Using a custom domain (`auth.yourdomain.com`) avoids third-party cookie issues and improves UX.
5. **Management API tokens**: These are separate from user tokens. Use `client_credentials` grant with the Management API audience to get them.
6. **Actions/Rules**: Auth0 Actions (formerly Rules) execute during the login flow. They can modify tokens, deny access, or enrich user profiles. Be aware of their impact on token contents.
7. **Token format**: With an `audience`, Auth0 issues JWTs. Without, it issues opaque tokens.

---

## Okta

### Discovery URL

```
# Org authorization server
https://{your-domain}.okta.com/.well-known/openid-configuration

# Custom authorization server
https://{your-domain}.okta.com/oauth2/{authServerId}/.well-known/openid-configuration

# Default custom authorization server
https://{your-domain}.okta.com/oauth2/default/.well-known/openid-configuration
```

### Key Endpoints

| Endpoint          | URL                                                              |
|-------------------|------------------------------------------------------------------|
| Authorization     | `https://{domain}/oauth2/{serverId}/v1/authorize`                |
| Token             | `https://{domain}/oauth2/{serverId}/v1/token`                    |
| Userinfo          | `https://{domain}/oauth2/{serverId}/v1/userinfo`                 |
| JWKS              | `https://{domain}/oauth2/{serverId}/v1/keys`                     |
| Introspect        | `https://{domain}/oauth2/{serverId}/v1/introspect`               |
| Revoke            | `https://{domain}/oauth2/{serverId}/v1/revoke`                   |

### Required Scopes

| Scope             | Data                                          |
|-------------------|-----------------------------------------------|
| `openid`          | Subject identifier                            |
| `profile`         | Name, locale, timezone                        |
| `email`           | Email, `email_verified`                       |
| `groups`          | Group memberships (custom auth server only)   |
| `offline_access`  | Refresh token                                 |

### Token Endpoint Configuration

- **Auth method**: `client_secret_basic` (default), `client_secret_post`, `client_secret_jwt`, or `private_key_jwt`.
- **Content-Type**: `application/x-www-form-urlencoded`.
- **PKCE**: Supported and enforced for SPA and native app client types.

### Gotchas

1. **Org authorization server vs custom authorization server**: The org authorization server (`/.well-known/openid-configuration` without a path) can only issue ID tokens and access tokens for Okta APIs. For your own APIs, use a custom authorization server.
2. **Custom claims require a custom authorization server**: You cannot add custom claims to tokens from the org authorization server.
3. **`groups` scope**: Only available on custom authorization servers. Must be configured in the authorization server's claims settings.
4. **Refresh token rotation**: Configurable per authorization server. Can set a grace period for concurrent use.
5. **DPoP**: Okta supports DPoP on custom authorization servers. Must be enabled in the application settings.
6. **Inline hooks**: Okta can call external services during token issuance to modify claims. Useful for fetching external data to include in tokens.

---

## Keycloak

### Discovery URL

```
https://{host}/realms/{realm}/.well-known/openid-configuration
```

### Key Endpoints

| Endpoint          | URL                                                          |
|-------------------|--------------------------------------------------------------|
| Authorization     | `https://{host}/realms/{realm}/protocol/openid-connect/auth` |
| Token             | `https://{host}/realms/{realm}/protocol/openid-connect/token`|
| Userinfo          | `https://{host}/realms/{realm}/protocol/openid-connect/userinfo` |
| JWKS              | `https://{host}/realms/{realm}/protocol/openid-connect/certs` |
| Introspect        | `https://{host}/realms/{realm}/protocol/openid-connect/token/introspect` |
| End Session       | `https://{host}/realms/{realm}/protocol/openid-connect/logout` |

### Required Scopes

| Scope             | Data                                          |
|-------------------|-----------------------------------------------|
| `openid`          | Subject identifier                            |
| `profile`         | Name, username, locale                        |
| `email`           | Email, `email_verified`                       |
| `roles`           | Realm and client roles                        |
| `offline_access`  | Refresh token with offline scope              |

### Token Endpoint Configuration

- **Auth method**: `client_secret_basic`, `client_secret_post`, `client_secret_jwt`, `private_key_jwt`, or mTLS.
- **Content-Type**: `application/x-www-form-urlencoded`.
- **PKCE**: Supported. Can be enforced per client in the admin console.

### Gotchas

1. **Realm-specific URLs**: Every endpoint includes the realm name. Make sure you're using the correct realm.
2. **Role mapping**: Keycloak has both realm roles and client roles. Token mappers control which roles appear in the access token. By default, roles may appear under `realm_access.roles` and `resource_access.{client_id}.roles`.
3. **Client scopes**: Scopes in Keycloak are defined as "client scopes" and assigned to clients. The `roles` scope must be explicitly added to get role claims.
4. **Token lifespan**: Configured at the realm level. Short-lived access tokens (5 minutes default) and longer session lifetimes (30 minutes default) — adjust based on your needs.
5. **Self-hosted security**: You are responsible for TLS termination, database security, and keeping Keycloak updated. Run behind a reverse proxy (nginx, Traefik) with HTTPS.
6. **Admin API**: Keycloak has a comprehensive REST API for managing realms, users, clients, and roles programmatically.
7. **Quarkus-based (v17+)**: Keycloak migrated from WildFly to Quarkus. Configuration is now via `conf/keycloak.conf` or environment variables, not standalone.xml.

---

## AWS Cognito

### Discovery URL

```
https://cognito-idp.{region}.amazonaws.com/{userPoolId}/.well-known/openid-configuration
```

### Key Endpoints

| Endpoint          | URL                                                                  |
|-------------------|----------------------------------------------------------------------|
| Authorization     | `https://{domain}.auth.{region}.amazoncognito.com/oauth2/authorize`  |
| Token             | `https://{domain}.auth.{region}.amazoncognito.com/oauth2/token`      |
| Userinfo          | `https://{domain}.auth.{region}.amazoncognito.com/oauth2/userInfo`   |
| JWKS              | `https://cognito-idp.{region}.amazonaws.com/{userPoolId}/.well-known/jwks.json` |
| Revocation        | `https://{domain}.auth.{region}.amazoncognito.com/oauth2/revoke`     |

### Required Scopes

| Scope                        | Data                                   |
|------------------------------|----------------------------------------|
| `openid`                     | Subject identifier                     |
| `profile`                    | Name, locale, timezone                 |
| `email`                      | Email, `email_verified`                |
| `aws.cognito.signin.user.admin` | Full user attribute access          |
| `phone`                      | Phone number, `phone_number_verified`  |

### Token Endpoint Configuration

- **Auth method**: `client_secret_basic` for confidential clients. Public clients (no secret) use PKCE.
- **Content-Type**: `application/x-www-form-urlencoded`.
- **PKCE**: Supported for public clients.

### Gotchas

1. **Custom domain required for branded UI**: The default Cognito domain (`xxx.auth.region.amazoncognito.com`) cannot be customized without setting up a custom domain.
2. **Token customization is limited**: Cognito's pre-token-generation Lambda trigger can add custom claims, but you cannot remove default claims or change the token format.
3. **No standard `iss` format**: The issuer is `https://cognito-idp.{region}.amazonaws.com/{userPoolId}` — different from typical OIDC issuers.
4. **Access token scopes**: Cognito uses "resource servers" to define custom scopes. Scopes follow the format `{resourceServerIdentifier}/{scopeName}`.
5. **Refresh token expiration**: Configurable from 60 minutes to 10 years. No rotation by default — the same refresh token is reused until it expires.
6. **User pool vs identity pool**: User pools handle authentication (OAuth/OIDC). Identity pools handle authorization (mapping tokens to AWS IAM credentials). They serve different purposes.
7. **Hosted UI limitations**: The built-in hosted UI has limited customization. For full control, build your own UI and call the Cognito APIs directly.
8. **Pricing**: Cognito charges per monthly active user (MAU). Free tier covers 50,000 MAUs with the Essentials tier.
