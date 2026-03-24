# Advanced OAuth 2.0 Patterns

## Table of Contents

- [Token Introspection (RFC 7662)](#token-introspection-rfc-7662)
- [Token Exchange (RFC 8693)](#token-exchange-rfc-8693)
- [DPoP — Demonstrating Proof of Possession (RFC 9449)](#dpop--demonstrating-proof-of-possession-rfc-9449)
- [PAR — Pushed Authorization Requests (RFC 9126)](#par--pushed-authorization-requests-rfc-9126)
- [RAR — Rich Authorization Requests (RFC 9396)](#rar--rich-authorization-requests-rfc-9396)
- [CIBA — Client Initiated Backchannel Authentication (OIDC)](#ciba--client-initiated-backchannel-authentication-oidc)
- [Device Authorization Grant — Deep Dive](#device-authorization-grant--deep-dive)
- [Federated Identity Patterns](#federated-identity-patterns)
- [Multi-Tenant OAuth](#multi-tenant-oauth)
- [OAuth for Microservices](#oauth-for-microservices)

---

## Token Introspection (RFC 7662)

Token introspection lets a resource server validate an opaque token by querying the authorization server directly. Use this when tokens are not self-contained JWTs or when you need real-time revocation checks.

### Request

```http
POST /oauth2/introspect HTTP/1.1
Host: auth.example.com
Content-Type: application/x-www-form-urlencoded
Authorization: Basic <base64(client_id:client_secret)>

token=eyJhbGciOiJSUzI1NiIs...&
token_type_hint=access_token
```

### Response

```json
{
  "active": true,
  "scope": "read:users write:users",
  "client_id": "my-service",
  "username": "jane@example.com",
  "token_type": "Bearer",
  "exp": 1700000000,
  "iat": 1699996400,
  "sub": "user-abc-123",
  "aud": "https://api.example.com",
  "iss": "https://auth.example.com"
}
```

### Implementation Guidelines

- **Cache introspection results** for short periods (30-60s) to reduce load. Use the `exp` claim as a cache TTL upper bound.
- **Always check `"active": true`** before granting access. An inactive token must be rejected immediately.
- **Authenticate the introspection call** — the authorization server must verify the caller is an authorized resource server. Use client credentials (Basic auth or `client_assertion`).
- **Use `token_type_hint`** to speed up lookup when the authorization server supports multiple token types.
- **Prefer JWT access tokens** when latency is critical. Reserve introspection for opaque tokens, high-security scenarios, or when real-time revocation is required.

### When to Use Introspection vs JWT Validation

| Criterion                  | JWT Validation        | Token Introspection     |
|----------------------------|-----------------------|-------------------------|
| Latency                    | Low (local)           | Higher (network call)   |
| Revocation support         | Only via short expiry | Real-time               |
| Token size in requests     | Larger                | Smaller (opaque)        |
| Authorization server load  | None                  | Per-request             |
| Offline validation         | Yes                   | No                      |

---

## Token Exchange (RFC 8693)

Token exchange enables a service to swap one token for another — for example, exchanging a user's access token for a more narrowly scoped token to call a downstream service. This is the foundation of the "token relay" pattern in microservices.

### Grant Type

```
urn:ietf:params:oauth:grant-type:token-exchange
```

### Request

```http
POST /oauth2/token HTTP/1.1
Host: auth.example.com
Content-Type: application/x-www-form-urlencoded
Authorization: Basic <base64(client_id:client_secret)>

grant_type=urn:ietf:params:oauth:grant-type:token-exchange&
subject_token=eyJhbGciOiJSUzI1NiIs...&
subject_token_type=urn:ietf:params:oauth:token-type:access_token&
audience=https://downstream-api.example.com&
scope=read:orders&
requested_token_type=urn:ietf:params:oauth:token-type:access_token
```

### Response

```json
{
  "access_token": "eyJhbGciOiJSUzI1NiIs...",
  "issued_token_type": "urn:ietf:params:oauth:token-type:access_token",
  "token_type": "Bearer",
  "expires_in": 300,
  "scope": "read:orders"
}
```

### Token Types

| URI                                                    | Description         |
|--------------------------------------------------------|---------------------|
| `urn:ietf:params:oauth:token-type:access_token`       | OAuth access token  |
| `urn:ietf:params:oauth:token-type:refresh_token`      | OAuth refresh token |
| `urn:ietf:params:oauth:token-type:id_token`           | OIDC ID token       |
| `urn:ietf:params:oauth:token-type:saml1`              | SAML 1.1 assertion  |
| `urn:ietf:params:oauth:token-type:saml2`              | SAML 2.0 assertion  |
| `urn:ietf:params:oauth:token-type:jwt`                | Generic JWT         |

### Key Parameters

- **`subject_token`**: The token representing the principal (user) on whose behalf the request is made.
- **`actor_token`** (optional): The token representing the acting party (the service making the call). Used for delegation and impersonation scenarios.
- **`audience`**: The target service that will consume the exchanged token.
- **`scope`**: Request a narrower set of scopes for the exchanged token.
- **`requested_token_type`**: The desired type of the new token.

### Use Cases

1. **Scope narrowing**: A gateway receives a broad-scope token and exchanges it for a narrower token before forwarding to a downstream service.
2. **Audience restriction**: Exchange a token valid for `api.example.com` for one scoped to `payments.internal.example.com`.
3. **Cross-domain federation**: Exchange a SAML assertion from an enterprise IdP for an OAuth access token.
4. **Impersonation**: An admin service exchanges its own token + a subject token to act on behalf of a user.
5. **Token format conversion**: Exchange an opaque token for a JWT or vice versa.

### Security Considerations

- Always validate the `subject_token` before issuing an exchanged token.
- Log all token exchange operations for audit trails.
- Enforce that exchanged tokens have equal or narrower scopes — never escalate privileges.
- Set short expiration on exchanged tokens (5 minutes or less for internal service calls).

---

## DPoP — Demonstrating Proof of Possession (RFC 9449)

DPoP binds access tokens to a client's cryptographic key pair, preventing stolen tokens from being used by attackers. Unlike mTLS-based token binding, DPoP works at the application layer and does not require TLS client certificates.

### How DPoP Works

1. The client generates an asymmetric key pair (e.g., ES256) and keeps the private key secure.
2. For each request, the client creates a signed DPoP proof JWT containing:
   - `jti`: Unique identifier for the proof
   - `htm`: HTTP method (e.g., `POST`)
   - `htu`: HTTP URI of the request
   - `iat`: Issued-at timestamp
   - `ath`: Hash of the access token (when used with a resource server)
3. The DPoP proof is sent in the `DPoP` header.

### Token Request with DPoP

```http
POST /oauth2/token HTTP/1.1
Host: auth.example.com
Content-Type: application/x-www-form-urlencoded
DPoP: eyJhbGciOiJFUzI1NiIsInR5cCI6ImRwb3Arand0IiwiandrIjp7Imt0eSI6...

grant_type=authorization_code&
code=AUTH_CODE&
redirect_uri=https://app.example.com/callback&
client_id=CLIENT_ID&
code_verifier=VERIFIER
```

### DPoP Proof JWT Structure

```json
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
{
  "jti": "unique-proof-id",
  "htm": "POST",
  "htu": "https://auth.example.com/oauth2/token",
  "iat": 1699996400,
  "ath": "fUHyO2r2Z3DZ53EsNrWBb0xWXoaNy59IiKCAqksmQEo"
}
```

### Using DPoP-Bound Tokens at Resource Servers

```http
GET /api/users HTTP/1.1
Host: api.example.com
Authorization: DPoP eyJhbGciOiJSUzI1NiIs...
DPoP: eyJhbGciOiJFUzI1NiIsInR5cCI6ImRwb3Arand0Iiw...
```

Note: The `Authorization` scheme is `DPoP`, not `Bearer`.

### Validation at the Resource Server

1. Extract the DPoP proof from the `DPoP` header.
2. Verify the proof JWT signature using the embedded `jwk`.
3. Confirm `htm` and `htu` match the current request.
4. Verify `iat` is within acceptable clock skew.
5. Check `jti` has not been seen before (replay protection).
6. Verify the `ath` claim matches the hash of the access token.
7. Confirm the `jwk` thumbprint in the proof matches the `cnf.jkt` claim in the access token.

### Implementation Tips

- Use `ES256` (P-256) for DPoP keys — good balance of security and performance.
- Store the DPoP private key in secure, non-exportable storage (Web Crypto API's `extractable: false`, OS keychain).
- Generate a fresh `jti` for every DPoP proof — UUIDs work well.
- Keep DPoP proof `iat` timestamps tight (within 1-2 minutes of server time).

---

## PAR — Pushed Authorization Requests (RFC 9126)

PAR moves authorization parameters from the front-channel (browser redirect URL) to the back-channel (server-to-server POST). This prevents parameter tampering by the user agent and avoids URL length limitations.

### Flow

```
1. Client POSTs authorization parameters to the PAR endpoint:
   POST /oauth2/par
     client_id=CLIENT_ID&
     client_secret=CLIENT_SECRET&    (confidential clients)
     response_type=code&
     redirect_uri=https://app.example.com/callback&
     scope=openid profile&
     code_challenge=CHALLENGE&
     code_challenge_method=S256&
     state=RANDOM_STATE

2. Authorization server returns a request_uri:
   {
     "request_uri": "urn:ietf:params:oauth:request_uri:abc123",
     "expires_in": 60
   }

3. Client redirects user to authorization endpoint with only the request_uri:
   GET /authorize?
     client_id=CLIENT_ID&
     request_uri=urn:ietf:params:oauth:request_uri:abc123
```

### Benefits

- **Parameter integrity**: Parameters cannot be modified by the user agent or browser extensions.
- **No URL length limits**: Complex authorization requests with many scopes or claims are not constrained by URL length.
- **Confidential client authentication**: The PAR request authenticates the client, ensuring only registered clients can initiate flows.
- **Reduced information leakage**: Authorization parameters are not visible in browser history, referrer headers, or server logs.

### When to Use PAR

- Financial-grade APIs (FAPI) — PAR is required in FAPI 2.0.
- Authorization requests with complex parameters (RAR, many scopes, request objects).
- High-security environments where front-channel parameter integrity is critical.
- Any application that benefits from server-authenticated authorization initiation.

---

## RAR — Rich Authorization Requests (RFC 9396)

RAR replaces simple scope strings with structured JSON objects for fine-grained authorization. Use when `scope` values are insufficient to express the required level of detail.

### Authorization Details Structure

```json
{
  "authorization_details": [
    {
      "type": "payment_initiation",
      "instructedAmount": {
        "amount": "150.00",
        "currency": "EUR"
      },
      "creditorName": "Merchant Corp",
      "creditorAccount": {
        "iban": "DE89370400440532013000"
      }
    },
    {
      "type": "account_information",
      "actions": ["read"],
      "datatypes": ["balance", "transactions"],
      "identifier": "DE89370400440532013000"
    }
  ]
}
```

### Using RAR with PAR

RAR is commonly combined with PAR to push complex authorization details securely:

```http
POST /oauth2/par HTTP/1.1
Host: auth.example.com
Content-Type: application/x-www-form-urlencoded

client_id=CLIENT_ID&
response_type=code&
redirect_uri=https://app.example.com/callback&
authorization_details=%5B%7B%22type%22%3A%22payment_initiation%22%2C...%7D%5D&
code_challenge=CHALLENGE&
code_challenge_method=S256
```

### Use Cases

- **Open Banking / PSD2**: Express specific payment amounts, accounts, and transaction types.
- **Healthcare**: Authorize access to specific patient records or data categories.
- **Document management**: Grant access to specific documents or folders rather than broad "read" or "write".

### Implementation Notes

- Define a clear schema for each `type` value — document and version your authorization detail types.
- The `authorization_details` parameter can be used alongside traditional `scope`.
- Returned tokens should include the granted `authorization_details` so resource servers can enforce them.
- Validate authorization details at both the authorization server and the resource server.

---

## CIBA — Client Initiated Backchannel Authentication (OIDC)

CIBA enables authentication without a browser redirect. The client initiates authentication directly with the authorization server, which then contacts the user on a separate device or channel (push notification, SMS, etc.).

### Flow

```
1. Client sends authentication request to the backchannel endpoint:
   POST /bc-authorize
     scope=openid&
     client_id=CLIENT_ID&
     client_notification_token=NOTIFICATION_TOKEN&   (push mode)
     login_hint=user@example.com&
     binding_message=Authorize payment of $150

2. Authorization server returns an auth_req_id:
   {
     "auth_req_id": "abc123",
     "expires_in": 120,
     "interval": 5
   }

3. Authorization server contacts user (push notification, SMS, etc.)

4. User authenticates on their device

5. Client obtains tokens:
   - Poll mode: POST /token with grant_type=urn:openid:params:grant-type:ciba
   - Push mode: Authorization server sends tokens to client's notification endpoint
   - Ping mode: Authorization server pings client, client fetches tokens
```

### Delivery Modes

| Mode   | Description                                           | Use Case                    |
|--------|-------------------------------------------------------|-----------------------------|
| `poll` | Client polls the token endpoint                       | Simple integration          |
| `ping` | Server notifies client, client fetches tokens         | Efficient, moderate complexity |
| `push` | Server pushes tokens directly to client endpoint      | Real-time, complex setup    |

### Use Cases

- **Point-of-sale**: Customer authorizes payment via phone notification while at a terminal.
- **Call center**: Agent initiates authentication; customer confirms on their mobile device.
- **IoT**: Device requests authorization; user approves on a separate app.
- **Passwordless login**: User receives a push notification to approve a login attempt.

### Security Considerations

- Validate `binding_message` is displayed to the user to prevent social engineering.
- Set short expiry on `auth_req_id` (2-5 minutes).
- Use signed authentication requests (`request` parameter as JWT) for integrity.
- Protect the notification endpoint with TLS and verify the `client_notification_token`.

---

## Device Authorization Grant — Deep Dive

### Polling Best Practices

```javascript
async function pollForToken(deviceCode, interval, expiresIn) {
  const deadline = Date.now() + expiresIn * 1000;
  let pollInterval = interval * 1000;

  while (Date.now() < deadline) {
    await sleep(pollInterval);

    const response = await fetch('/oauth2/token', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        grant_type: 'urn:ietf:params:oauth:grant-type:device_code',
        device_code: deviceCode,
        client_id: CLIENT_ID,
      }),
    });

    const data = await response.json();

    if (response.ok) return data;

    switch (data.error) {
      case 'authorization_pending':
        break; // continue polling
      case 'slow_down':
        pollInterval += 5000; // increase interval by 5 seconds
        break;
      case 'expired_token':
        throw new Error('Device code expired — restart flow');
      case 'access_denied':
        throw new Error('User denied authorization');
      default:
        throw new Error(`Unexpected error: ${data.error}`);
    }
  }

  throw new Error('Device code expired — restart flow');
}
```

### User Experience

- Display the `user_code` prominently in large, readable text.
- Show the `verification_uri` and, if available, `verification_uri_complete` (includes user_code in the URL).
- Provide a QR code encoding `verification_uri_complete` for mobile users.
- Show a countdown timer based on `expires_in`.
- Update the UI immediately when polling succeeds (display success state).

### Security

- Use short device codes (8 characters) with high entropy.
- Rate-limit the verification endpoint to prevent brute-force of user codes.
- Bind the device code to the requesting client — do not allow other clients to use it.

---

## Federated Identity Patterns

### Identity Brokering

An identity broker sits between your application and multiple upstream IdPs, providing a single integration point:

```
User → Your App → Identity Broker (Keycloak, Auth0) → Upstream IdP (Google, SAML, LDAP)
```

Benefits:
- Single OAuth/OIDC integration for your app regardless of upstream IdP protocol.
- Centralized session management, token mapping, and claims transformation.
- Add or remove IdPs without changing application code.

### Account Linking

When users can authenticate via multiple IdPs, link accounts by:

1. Match on verified email address (only if `email_verified: true` from both providers).
2. Prompt the user to link manually after authenticating with both providers.
3. Store a mapping table: `(internal_user_id, provider, provider_subject_id)`.

**Never auto-link on unverified email** — an attacker can register a matching email on a third-party IdP to hijack accounts.

### Just-In-Time (JIT) Provisioning

Create user accounts automatically on first login via a federated IdP:

```javascript
async function handleOidcCallback(idToken, accessToken) {
  const claims = verifyIdToken(idToken);
  let user = await db.users.findByProvider(claims.iss, claims.sub);

  if (!user) {
    const userinfo = await fetchUserinfo(accessToken);
    user = await db.users.create({
      email: userinfo.email,
      name: userinfo.name,
      providers: [{ issuer: claims.iss, subject: claims.sub }],
    });
  }

  return createSession(user);
}
```

### Cross-Domain SSO

For organizations with multiple domains or applications:

- Use a central authorization server as the SSO hub.
- Implement front-channel logout (`end_session_endpoint`) for browser-based logout across apps.
- Implement back-channel logout (logout tokens sent server-to-server) for reliable session termination.
- Track session state with `session_state` and `check_session_iframe` for continuous SSO monitoring.

---

## Multi-Tenant OAuth

### Tenant Isolation Strategies

1. **Separate authorization servers per tenant**: Maximum isolation but highest operational cost.
2. **Shared authorization server with tenant-scoped resources**: Use custom claims or scopes to isolate tenants.
3. **Shared authorization server with tenant parameter**: Pass `tenant_id` as a custom parameter; include it in tokens.

### Token Design for Multi-Tenancy

Include tenant context in access tokens:

```json
{
  "sub": "user-abc-123",
  "iss": "https://auth.example.com",
  "aud": "https://api.example.com",
  "tenant_id": "tenant-xyz",
  "roles": ["admin"],
  "scope": "read:users write:users",
  "exp": 1700000000
}
```

### Enforcement

- **Always validate `tenant_id`** at the resource server — never trust the client to provide it.
- **Prevent cross-tenant token use**: Reject tokens where `tenant_id` does not match the requested resource's tenant.
- **Scope tenant-specific API keys and client registrations** — each tenant should have its own OAuth client credentials.

### Dynamic Client Registration (RFC 7591)

For SaaS platforms where tenants bring their own IdP:

```http
POST /oauth2/register HTTP/1.1
Host: auth.example.com
Content-Type: application/json
Authorization: Bearer INITIAL_ACCESS_TOKEN

{
  "redirect_uris": ["https://tenant-app.example.com/callback"],
  "client_name": "Tenant XYZ App",
  "grant_types": ["authorization_code", "refresh_token"],
  "response_types": ["code"],
  "token_endpoint_auth_method": "client_secret_basic"
}
```

---

## OAuth for Microservices

### Token Relay Pattern

The API gateway validates the incoming user token and relays it (or an exchanged token) to downstream services:

```
Client → API Gateway → Service A → Service B
         (validate)    (relay)      (relay)
```

Implementation:
1. Gateway validates the access token (JWT or introspection).
2. Gateway forwards the token in the `Authorization` header to downstream services.
3. Each service validates the token independently and enforces its own scopes.
4. For scope narrowing, use token exchange at each hop.

### Service-to-Service Authentication

For internal service calls without user context:

```javascript
// Service A calls Service B using client credentials
async function callServiceB(endpoint) {
  const token = await getClientCredentialsToken({
    tokenUrl: 'https://auth.internal/oauth2/token',
    clientId: process.env.SERVICE_A_CLIENT_ID,
    clientSecret: process.env.SERVICE_A_CLIENT_SECRET,
    scope: 'service-b:read',
  });

  return fetch(`https://service-b.internal${endpoint}`, {
    headers: { Authorization: `Bearer ${token}` },
  });
}
```

### Token Caching for Services

Cache client credentials tokens to avoid hitting the token endpoint on every request:

```javascript
class TokenCache {
  #cache = new Map();

  async getToken(audience, scopes) {
    const key = `${audience}:${scopes.join(',')}`;
    const cached = this.#cache.get(key);

    if (cached && cached.expiresAt > Date.now() + 60_000) {
      return cached.accessToken;
    }

    const token = await requestClientCredentialsToken(audience, scopes);
    this.#cache.set(key, {
      accessToken: token.access_token,
      expiresAt: Date.now() + token.expires_in * 1000,
    });

    return token.access_token;
  }
}
```

### Sidecar / Service Mesh Token Handling

In service mesh architectures (Istio, Linkerd), offload token validation to the sidecar proxy:

- **Istio**: Configure `RequestAuthentication` and `AuthorizationPolicy` resources to validate JWTs at the Envoy sidecar level.
- **Linkerd**: Use policy resources with external authorization servers.
- **Benefit**: Application code does not need to handle token validation — the mesh enforces it transparently.

```yaml
# Istio RequestAuthentication
apiVersion: security.istio.io/v1
kind: RequestAuthentication
metadata:
  name: jwt-auth
spec:
  jwtRules:
    - issuer: "https://auth.example.com"
      jwksUri: "https://auth.example.com/.well-known/jwks.json"
      audiences:
        - "https://api.example.com"
      forwardOriginalToken: true
```

### Distributed Tracing with OAuth

Include correlation IDs alongside tokens for observability:

- Pass `X-Request-ID` or `traceparent` headers through the service chain.
- Log `client_id`, `sub`, `scope`, and `tenant_id` from the token at each service (never log the token itself).
- Correlate token exchange events with trace IDs for end-to-end audit trails.
