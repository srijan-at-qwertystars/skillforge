# OAuth 2.0 Troubleshooting Guide

## Table of Contents

- [Redirect URI Mismatches](#redirect-uri-mismatches)
- [CORS Errors with Token Endpoints](#cors-errors-with-token-endpoints)
- [Token Expiry and Silent Refresh Failures](#token-expiry-and-silent-refresh-failures)
- [PKCE Verifier/Challenge Mismatch](#pkce-verifierchallenge-mismatch)
- [State Parameter Validation](#state-parameter-validation)
- [Clock Skew with JWT Validation](#clock-skew-with-jwt-validation)
- [Refresh Token Rotation Gotchas](#refresh-token-rotation-gotchas)
- [Third-Party Cookie Blocking (SPA)](#third-party-cookie-blocking-spa)
- [Mobile Deep Link Redirect Issues](#mobile-deep-link-redirect-issues)
- [Debugging with OAuth Tools](#debugging-with-oauth-tools)

---

## Redirect URI Mismatches

**Symptom**: `redirect_uri_mismatch`, `invalid_redirect_uri`, or `The redirect_uri does not match the registered redirect URI` error after user authenticates.

### Common Causes

1. **Trailing slash mismatch**: `https://app.example.com/callback` vs `https://app.example.com/callback/`
2. **Scheme mismatch**: `http://` registered but requesting with `https://`, or vice versa.
3. **Port mismatch**: `http://localhost:3000/callback` registered but running on port 3001.
4. **Case sensitivity**: Some providers perform case-sensitive matching — `https://App.example.com/callback` ≠ `https://app.example.com/callback`.
5. **Missing registration**: The redirect URI was never added to the OAuth app configuration at the provider.
6. **Query parameter differences**: Some providers strip or reject URIs with query parameters.
7. **URL encoding differences**: Encoded vs unencoded characters in the path.

### Debugging Steps

```bash
# Print exactly what you're sending
echo "Registered: https://app.example.com/callback"
echo "Requested:  $(grep redirect_uri .env | cut -d= -f2)"
# Compare character by character — watch for invisible characters
diff <(echo "https://app.example.com/callback") <(echo "$REDIRECT_URI") | cat -A
```

### Fixes

- Copy the exact redirect URI from your application code and paste it into the provider's OAuth app settings.
- Ensure environment variables do not have trailing whitespace or newlines.
- For local development, register `http://localhost:PORT/callback` (most providers allow `http://` for localhost).
- Use `http://127.0.0.1:PORT/callback` if `localhost` doesn't work (some providers treat them differently).

---

## CORS Errors with Token Endpoints

**Symptom**: `Access to fetch at 'https://auth.example.com/oauth2/token' has been blocked by CORS policy` in the browser console.

### Why This Happens

The token endpoint is a server-to-server endpoint. Most authorization servers do **not** set CORS headers on `/token` because browser-based token exchange is insecure for confidential clients.

### Solutions

1. **Use a Backend-for-Frontend (BFF) pattern**: Route token requests through your own server, which forwards them to the authorization server. The browser only communicates with your backend.

   ```
   Browser → Your Backend (/api/auth/token) → Authorization Server (/oauth2/token)
   ```

2. **Use the provider's JavaScript SDK**: Google, Microsoft, Auth0, and others provide SDKs that handle token exchange without direct `/token` calls (using iframe-based flows or popup redirects).

3. **Check provider CORS configuration**: Some providers (Auth0, Okta, Keycloak) let you configure allowed CORS origins. Add your SPA's origin to the allowed list.

4. **For development only**: Use a proxy in your dev server config:

   ```javascript
   // vite.config.js
   export default {
     server: {
       proxy: {
         '/oauth2': {
           target: 'https://auth.example.com',
           changeOrigin: true,
         },
       },
     },
   };
   ```

### Never Do This

- Do not disable CORS checks in production.
- Do not send `client_secret` from the browser — use PKCE for public clients.

---

## Token Expiry and Silent Refresh Failures

**Symptom**: API calls start failing with `401 Unauthorized` after a period of time. Silent refresh via hidden iframes fails without clear errors.

### Common Causes

1. **Access token expired and refresh was not attempted**: No proactive refresh logic; token used after expiry.
2. **Refresh token also expired**: Long user inactivity exceeding the refresh token's absolute lifetime.
3. **Silent refresh iframe blocked**: Third-party cookie restrictions prevent the hidden iframe from maintaining the session (see [Third-Party Cookie Blocking](#third-party-cookie-blocking-spa)).
4. **Race condition on refresh**: Multiple concurrent API calls all detect an expired token and trigger simultaneous refresh requests, causing some to fail.
5. **Network error during refresh**: Offline or flaky network causes the refresh call to fail; the application doesn't retry.

### Solutions

```javascript
// Mutex-based refresh to prevent race conditions
let refreshPromise = null;

async function refreshAccessToken(refreshToken) {
  if (refreshPromise) return refreshPromise;

  refreshPromise = (async () => {
    try {
      const response = await fetch('/oauth2/token', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({
          grant_type: 'refresh_token',
          refresh_token: refreshToken,
          client_id: CLIENT_ID,
        }),
      });

      if (!response.ok) throw new Error('Refresh failed');
      return await response.json();
    } finally {
      refreshPromise = null;
    }
  })();

  return refreshPromise;
}
```

- Implement proactive refresh: refresh the token 60 seconds before expiry, not after it fails.
- Add retry logic with exponential backoff for network errors during refresh.
- If `invalid_grant` is returned, the refresh token is revoked — redirect to login.

---

## PKCE Verifier/Challenge Mismatch

**Symptom**: `invalid_grant` error when exchanging the authorization code, even though the code is valid. The error message may include "code_verifier failed verification" or "PKCE validation failed".

### Common Causes

1. **Different verifier sent at token exchange**: The code verifier sent to `/token` does not match the one used to generate the challenge sent to `/authorize`.
2. **Verifier not stored correctly**: The verifier was lost between the authorization redirect and the callback (page reload cleared in-memory state, or session storage was not used).
3. **Encoding mismatch**: The challenge was computed with standard Base64 instead of Base64URL (no padding, URL-safe characters).
4. **Using `plain` method but server expects `S256`**: Or vice versa.
5. **Verifier length out of spec**: Must be 43-128 characters. Some libraries generate shorter or longer values.

### Debugging

```javascript
// Verify your PKCE implementation locally
import crypto from 'node:crypto';

const verifier = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'; // example
const expectedChallenge = crypto
  .createHash('sha256')
  .update(verifier)
  .digest('base64url'); // Note: base64url, NOT base64

console.log('Challenge:', expectedChallenge);
// Compare with what was sent to /authorize
```

### Fixes

- Store the code verifier in `sessionStorage` (browser) or server-side session before redirecting to the authorization endpoint.
- Use `base64url` encoding (no `+`, `/`, or `=` padding). In Node.js, use `.digest('base64url')`. In browsers, use a proper Base64URL encoder.
- Always use `code_challenge_method=S256` — never `plain`.
- Verify the verifier is exactly the same string — no whitespace, no newlines, no truncation.

---

## State Parameter Validation

**Symptom**: CSRF attacks on the callback endpoint, or `state mismatch` errors in your OAuth library.

### Common Causes

1. **State not stored before redirect**: The application generates `state` but doesn't persist it, so it can't validate on callback.
2. **Session lost between redirect and callback**: Different server instance handles the callback (load balancer without sticky sessions), or the session cookie expired.
3. **State stored in `localStorage` but cleared**: Browser privacy settings or extensions clear storage.
4. **Double-submit / browser back button**: User hits the callback URL twice; the state was already consumed on the first hit.

### Best Practices

```javascript
// Generate and store state
function initiateAuthFlow() {
  const state = crypto.randomUUID();
  const nonce = crypto.randomUUID();

  // Use a cookie for state — survives redirects and works across load balancers
  document.cookie = `oauth_state=${state}; path=/; max-age=600; SameSite=Lax; Secure`;

  const authUrl = new URL('https://auth.example.com/authorize');
  authUrl.searchParams.set('state', state);
  // ... other params
  window.location.href = authUrl.toString();
}

// Validate state on callback
function handleCallback() {
  const params = new URLSearchParams(window.location.search);
  const returnedState = params.get('state');
  const storedState = getCookie('oauth_state');

  if (!returnedState || returnedState !== storedState) {
    throw new Error('State mismatch — possible CSRF attack');
  }

  // Clear the state cookie immediately after validation
  document.cookie = 'oauth_state=; path=/; max-age=0';
}
```

- Use a short-lived cookie (5-10 minutes) for state — it survives redirects and works across server instances.
- Delete the state immediately after successful validation — one-time use only.
- Include a timestamp or nonce in the state to detect replays.

---

## Clock Skew with JWT Validation

**Symptom**: JWT validation fails intermittently with "token expired" or "token not yet valid" errors, even though tokens were just issued.

### Why This Happens

- The authorization server's clock is ahead of or behind the resource server's clock.
- Containers and VMs may have significant clock drift, especially after hibernation.
- `nbf` (not before) claims cause failures if the client's clock is slightly behind the issuer's clock.

### Solutions

```javascript
// Allow clock skew tolerance in JWT validation
import jwt from 'jsonwebtoken';

const decoded = jwt.verify(token, publicKey, {
  algorithms: ['RS256'],
  issuer: 'https://auth.example.com',
  audience: 'https://api.example.com',
  clockTolerance: 30, // Allow 30 seconds of clock skew
});
```

```python
# Python - PyJWT clock skew tolerance
import jwt

decoded = jwt.decode(
    token,
    public_key,
    algorithms=["RS256"],
    issuer="https://auth.example.com",
    audience="https://api.example.com",
    leeway=datetime.timedelta(seconds=30),
)
```

### Best Practices

- Allow 30-60 seconds of clock tolerance — enough for typical drift, not so much that it weakens security.
- Synchronize all servers with NTP. For containers, ensure the host's clock is synced.
- Log clock skew incidents — frequent occurrences indicate infrastructure issues.
- Never set clock tolerance above 5 minutes — it becomes a security risk.

---

## Refresh Token Rotation Gotchas

**Symptom**: Users get logged out unexpectedly. Refresh attempts fail with `invalid_grant`. Multiple browser tabs cause token rotation conflicts.

### The Multi-Tab Problem

When refresh token rotation is enabled, each refresh invalidates the previous token. If two browser tabs simultaneously detect an expired access token and both try to refresh:

1. Tab A refreshes → gets new access token + new refresh token RT2.
2. Tab B refreshes with the old refresh token RT1 → fails because RT1 was already invalidated by Tab A's refresh.
3. Some authorization servers treat reuse of a rotated token as a breach and revoke the entire grant.

### Solutions

1. **Coordinate refresh across tabs** using `BroadcastChannel`:

   ```javascript
   const channel = new BroadcastChannel('oauth-token-refresh');

   channel.onmessage = (event) => {
     if (event.data.type === 'TOKEN_REFRESHED') {
       tokenStore.update(event.data.tokens);
     }
   };

   async function refreshToken() {
     const tokens = await performRefresh();
     tokenStore.update(tokens);
     channel.postMessage({ type: 'TOKEN_REFRESHED', tokens });
   }
   ```

2. **Use a BFF pattern**: The server handles token storage and refresh. Browser tabs share the same session cookie, so refresh coordination is handled server-side.

3. **Grace period**: Some authorization servers (e.g., Auth0) allow a short grace period where the old refresh token is still valid after rotation. Configure this to 30-60 seconds to handle race conditions.

### Rotation + Persistence

- If using refresh token rotation, store the latest refresh token atomically — if the application crashes between receiving a new token and storing it, the old token is already invalid.
- Use a transaction or atomic write to update both access and refresh tokens together.

---

## Third-Party Cookie Blocking (SPA)

**Symptom**: Silent token refresh via hidden iframes stops working. Users are forced to re-authenticate frequently. Affects Safari (ITP), Firefox (ETP), Chrome (with third-party cookie deprecation).

### Why This Happens

Silent refresh traditionally works by loading the authorization server in a hidden iframe. The authorization server's session cookie is a "third-party cookie" relative to your application's domain. When browsers block third-party cookies, the iframe cannot access the session, and silent refresh fails.

### Solutions (in order of preference)

1. **Backend-for-Frontend (BFF)** — Recommended

   Move OAuth token management to your backend. The browser communicates with your server via first-party cookies. Your server handles token refresh directly with the authorization server.

   ```
   Browser ↔ Your Server (first-party cookies) ↔ Authorization Server
   ```

2. **Refresh token rotation (no iframe)**

   Use a refresh token stored in an `HttpOnly; Secure; SameSite=Strict` cookie managed by your BFF. Refresh via a direct API call to your backend, not via iframe.

3. **Service worker token management**

   Intercept API requests in a service worker, manage tokens in the worker's scope, and refresh proactively. No iframe needed.

4. **Use the provider's SDK**

   Auth0's `auth0-spa-js` and Microsoft's `msal-browser` have built-in fallback mechanisms for when iframe-based refresh fails (e.g., falling back to refresh tokens).

### What Doesn't Work Anymore

- Hidden iframe-based silent refresh on cross-origin authorization servers.
- `prompt=none` authorization requests in iframes when third-party cookies are blocked.
- Session check iframes (`check_session_iframe` from OIDC Session Management).

---

## Mobile Deep Link Redirect Issues

**Symptom**: OAuth callback doesn't return to the app. The browser opens instead of the app. Universal/App Links fail intermittently.

### Common Issues

1. **Custom URL scheme conflicts**: `myapp://callback` can be intercepted by other apps that register the same scheme. Use Universal Links (iOS) or App Links (Android) instead.

2. **Universal Links / App Links not configured**: Missing `apple-app-site-association` or `assetlinks.json` files, or they're not served correctly.

3. **In-app browser vs system browser**: Embedded WebViews (`WKWebView`, Android `WebView`) don't share the system browser's cookies or credential store. Use `ASWebAuthenticationSession` (iOS) or Custom Tabs (Android).

4. **Redirect URI not claimed**: The OS can't route the redirect URI back to the app because the deep link configuration is incorrect.

### iOS Configuration

```json
// apple-app-site-association (hosted at https://app.example.com/.well-known/apple-app-site-association)
{
  "applinks": {
    "apps": [],
    "details": [
      {
        "appID": "TEAM_ID.com.example.myapp",
        "paths": ["/oauth/callback"]
      }
    ]
  }
}
```

```swift
// Use ASWebAuthenticationSession
let session = ASWebAuthenticationSession(
    url: authURL,
    callbackURLScheme: "https", // Use Universal Links
    completionHandler: { callbackURL, error in
        guard let url = callbackURL else { return }
        let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value
        // Exchange code for tokens
    }
)
session.prefersEphemeralWebBrowserSession = true
session.start()
```

### Android Configuration

```json
// assetlinks.json (hosted at https://app.example.com/.well-known/assetlinks.json)
[
  {
    "relation": ["delegate_permission/common.handle_all_urls"],
    "target": {
      "namespace": "android_app",
      "package_name": "com.example.myapp",
      "sha256_cert_fingerprints": ["AA:BB:CC:..."]
    }
  }
]
```

### Best Practices

- Use `https://` redirect URIs with Universal Links / App Links instead of custom schemes.
- Use `ASWebAuthenticationSession` (iOS 12+) and Custom Tabs (Android) — never embedded WebViews.
- Set `prefersEphemeralWebBrowserSession = true` (iOS) to avoid sharing the browser's session cookies.
- Verify the `apple-app-site-association` and `assetlinks.json` files are served with `Content-Type: application/json` and no redirects.

---

## Debugging with OAuth Tools

### Browser Developer Tools

1. **Network tab**: Filter by the authorization server's domain. Inspect `/authorize`, `/token`, and `/userinfo` requests.
2. **Check redirect chain**: Look for 302 redirects to spot where the flow fails. Pay attention to the `Location` header.
3. **Console errors**: CORS issues, JavaScript errors during callback handling, and iframe loading failures appear here.
4. **Application tab → Cookies/Storage**: Verify session cookies, state parameters, and PKCE verifiers are stored correctly.

### Command-Line Debugging

```bash
# Decode a JWT (access token or ID token)
echo 'eyJhbGciOi...' | cut -d. -f2 | base64 -d 2>/dev/null | jq .

# Test token endpoint directly
curl -s -X POST https://auth.example.com/oauth2/token \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'grant_type=client_credentials' \
  -d 'client_id=YOUR_CLIENT_ID' \
  -d 'client_secret=YOUR_CLIENT_SECRET' \
  -d 'scope=api:read' | jq .

# Introspect a token
curl -s -X POST https://auth.example.com/oauth2/introspect \
  -u 'client_id:client_secret' \
  -d 'token=ACCESS_TOKEN' | jq .

# Fetch OIDC discovery document
curl -s https://auth.example.com/.well-known/openid-configuration | jq .

# Fetch JWKS (public keys)
curl -s https://auth.example.com/.well-known/jwks.json | jq .

# Verify JWT signature with a JWKS
# Use a tool like step-cli:
step crypto jwt verify --jwks https://auth.example.com/.well-known/jwks.json < token.jwt
```

### Dedicated Tools

| Tool                           | Purpose                                              |
|--------------------------------|------------------------------------------------------|
| [jwt.io](https://jwt.io)      | Decode and verify JWTs in the browser                |
| [OAuth 2.0 Playground (Google)](https://developers.google.com/oauthplayground) | Test Google OAuth flows interactively |
| [oauth.tools](https://oauth.tools) | Test various OAuth flows with any provider      |
| [step-cli](https://smallstep.com/docs/step-cli) | CLI tool for JWT creation, verification, and JWKS |
| [Postman](https://postman.com) | Built-in OAuth 2.0 authorization with flow support   |
| [Insomnia](https://insomnia.rest) | REST client with OAuth 2.0 flow support            |

### Logging Checklist

When debugging OAuth flows, log the following (but never log token values):

- [ ] Authorization request URL (with parameters)
- [ ] Redirect URI used
- [ ] Scopes requested vs scopes granted
- [ ] Error code and description from the authorization server
- [ ] Token endpoint response status code
- [ ] Token expiration times
- [ ] Client ID used
- [ ] Grant type used
- [ ] PKCE code challenge method
- [ ] State parameter (for correlation, not security)

### Common Error Codes Reference

| Error                        | Meaning                                              | Fix                                   |
|------------------------------|------------------------------------------------------|---------------------------------------|
| `invalid_request`            | Malformed request, missing params                    | Check required parameters             |
| `invalid_client`             | Client authentication failed                         | Verify client_id and client_secret    |
| `invalid_grant`              | Code expired, already used, or PKCE mismatch         | Check code expiry, PKCE verifier      |
| `unauthorized_client`        | Client not authorized for this grant type             | Check client registration             |
| `unsupported_grant_type`     | Grant type not supported by server                    | Verify grant type spelling            |
| `invalid_scope`              | Requested scope is invalid or unknown                 | Check available scopes                |
| `access_denied`              | User denied consent or policy blocked                 | Check consent screen, policies        |
| `interaction_required`       | Silent auth failed, user must interact                | Fall back to interactive login        |
| `login_required`             | No active session, user must log in                   | Redirect to login                     |
| `consent_required`           | User hasn't consented to requested scopes             | Prompt for consent                    |
| `temporarily_unavailable`    | Auth server is overloaded                             | Retry with backoff                    |
