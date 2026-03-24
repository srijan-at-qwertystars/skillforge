# Advanced OAuth 2.0 / OIDC Patterns

## Table of Contents

- [1. Token Exchange (RFC 8693)](#1-token-exchange-rfc-8693)
- [2. DPoP — Demonstrating Proof of Possession (RFC 9449)](#2-dpop--demonstrating-proof-of-possession-rfc-9449)
- [3. Pushed Authorization Requests — PAR (RFC 9126)](#3-pushed-authorization-requests--par-rfc-9126)
- [4. Rich Authorization Requests — RAR (RFC 9396)](#4-rich-authorization-requests--rar-rfc-9396)
- [5. GNAP — Grant Negotiation and Authorization Protocol](#5-gnap--grant-negotiation-and-authorization-protocol)
- [6. mTLS Client Authentication (RFC 8705)](#6-mtls-client-authentication-rfc-8705)
- [7. JWT-Secured Authorization Requests — JAR (RFC 9101)](#7-jwt-secured-authorization-requests--jar-rfc-9101)
- [8. Step-Up Authentication (RFC 9470)](#8-step-up-authentication-rfc-9470)
- [9. Token Introspection (RFC 7662)](#9-token-introspection-rfc-7662)
- [10. Token Revocation (RFC 7009)](#10-token-revocation-rfc-7009)
- [11. Combining Patterns](#11-combining-patterns)

---

## 1. Token Exchange (RFC 8693)

Token exchange enables a service to obtain a new security token by presenting an existing one. This supports delegation, impersonation, and cross-domain federation scenarios.

### Grant Type

```
urn:ietf:params:oauth:grant-type:token-exchange
```

### Request Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `grant_type` | Yes | Must be `urn:ietf:params:oauth:grant-type:token-exchange` |
| `subject_token` | Yes | The token representing the subject of the request |
| `subject_token_type` | Yes | Type URI of the subject token |
| `actor_token` | No | Token representing the acting party (for delegation) |
| `actor_token_type` | Conditional | Required if `actor_token` is present |
| `audience` | No | Target service identifier |
| `scope` | No | Desired scopes (must be equal or narrower) |
| `requested_token_type` | No | Desired output token type |
| `resource` | No | Target resource URI (RFC 8707) |

### Token Type URIs

```
urn:ietf:params:oauth:token-type:access_token
urn:ietf:params:oauth:token-type:refresh_token
urn:ietf:params:oauth:token-type:id_token
urn:ietf:params:oauth:token-type:saml1
urn:ietf:params:oauth:token-type:saml2
urn:ietf:params:oauth:token-type:jwt
```

### Delegation vs. Impersonation

**Delegation** — the exchanged token contains both subject and actor identity:
```http
POST /token
Content-Type: application/x-www-form-urlencoded

grant_type=urn:ietf:params:oauth:grant-type:token-exchange
&subject_token=USER_ACCESS_TOKEN
&subject_token_type=urn:ietf:params:oauth:token-type:access_token
&actor_token=SERVICE_A_TOKEN
&actor_token_type=urn:ietf:params:oauth:token-type:access_token
&audience=https://api.service-b.example.com
&scope=orders:read
```

Resulting token contains:
```json
{
  "sub": "user-123",
  "act": { "sub": "service-a-client-id" },
  "aud": "https://api.service-b.example.com",
  "scope": "orders:read"
}
```

**Impersonation** — the exchanged token appears as if the subject issued it directly (no `act` claim). Use only when the acting party is fully trusted.

### Security Considerations

- **Audience restriction**: Always validate `audience` server-side to prevent token forwarding
- **Scope reduction**: Exchanged token scope should never exceed the original
- **Trust boundaries**: Only allow token exchange between pre-registered service pairs
- **Logging**: Log all exchange operations for audit trail with both subject and actor
- **Chain depth**: Limit transitive exchanges (A→B→C) to prevent unbounded delegation

### Example: Microservice Call Chain

```
User → API Gateway → Order Service → Payment Service

1. User authenticates, gets access_token (audience: api-gateway)
2. API Gateway exchanges for token scoped to order-service
3. Order Service exchanges for token scoped to payment-service
   (with act claim preserving original user + gateway identity)
```

---

## 2. DPoP — Demonstrating Proof of Possession (RFC 9449)

DPoP binds access tokens to a client's cryptographic key pair, making stolen tokens unusable without the private key.

### How It Works

1. Client generates an asymmetric key pair (e.g., ES256) — stored securely, never transmitted
2. Each request includes a signed DPoP proof JWT in the `DPoP` header
3. Authorization server binds the issued token to the key's JWK thumbprint (`jkt`)
4. Resource server verifies both the access token and the DPoP proof

### DPoP Proof JWT Structure

**Header:**
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
```

**Payload (for token request):**
```json
{
  "jti": "unique-random-id",
  "htm": "POST",
  "htu": "https://auth.example.com/token",
  "iat": 1700000000
}
```

**Payload (for resource request — includes `ath`):**
```json
{
  "jti": "another-unique-id",
  "htm": "GET",
  "htu": "https://api.example.com/orders",
  "iat": 1700000060,
  "ath": "fUHyO2r2Z3DZ53EsNrWBb0xWXoaNy59IiKCAqksmQEo"
}
```

The `ath` (access token hash) is the base64url-encoded SHA-256 hash of the access token.

### Token Request with DPoP

```http
POST /token
Content-Type: application/x-www-form-urlencoded
DPoP: eyJ0eXAiOiJkcG9wK2p3dCIsImFsZyI6IkVTMjU2IiwiandrIjp7...

grant_type=authorization_code
&code=AUTH_CODE
&redirect_uri=https://app.example.com/callback
&client_id=CLIENT_ID
&code_verifier=CODE_VERIFIER
```

**Response:**
```json
{
  "access_token": "eyJhbGci...",
  "token_type": "DPoP",
  "expires_in": 300
}
```

### Resource Request with DPoP

```http
GET /api/orders HTTP/1.1
Authorization: DPoP eyJhbGci...
DPoP: eyJ0eXAiOiJkcG9wK2p3dCIsImFsZyI6IkVTMjU2...
```

### DPoP Nonce (Server-Provided)

Servers can require a nonce to prevent replay:
```http
HTTP/1.1 401 Unauthorized
DPoP-Nonce: server-provided-nonce-value
```

Client must include `nonce` in next DPoP proof payload.

### Binding DPoP to Authorization Codes via PAR

Include `dpop_jkt` in PAR request to bind the authorization code to a specific key:
```http
POST /par
dpop_jkt=JWK_THUMBPRINT_OF_CLIENT_KEY
&response_type=code
&client_id=CLIENT_ID
&...
```

### Implementation Checklist

- [ ] Generate and securely store EC P-256 key pair
- [ ] Create fresh DPoP proof for every request (unique `jti`, current `iat`)
- [ ] Include `ath` when accessing resource servers
- [ ] Handle `use_dpop_nonce` error by retrying with server nonce
- [ ] Use `DPoP` token type (not `Bearer`) in Authorization header
- [ ] Validate DPoP proof signature, `htm`, `htu`, `iat` freshness, `jti` uniqueness on server

---

## 3. Pushed Authorization Requests — PAR (RFC 9126)

PAR moves authorization parameters from the front-channel (browser URL) to a back-channel (server-to-server POST), preventing parameter tampering.

### Flow

```
1. Client → POST /par (with all auth params) → AS returns request_uri
2. Client → Redirect user to /authorize?client_id=X&request_uri=URN → AS
3. Normal flow continues (callback with code)
```

### PAR Request

```http
POST /par
Content-Type: application/x-www-form-urlencoded
Authorization: Basic BASE64(client_id:client_secret)

response_type=code
&redirect_uri=https://app.example.com/callback
&scope=openid profile email
&code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM
&code_challenge_method=S256
&state=af0ifjsldkj
&nonce=n-0S6_WzA2Mj
```

### PAR Response

```json
{
  "request_uri": "urn:ietf:params:oauth:request_uri:bwc4JK-ESC0w8acc191e-Y1LTC2",
  "expires_in": 60
}
```

### Authorization Redirect

```
GET /authorize?client_id=CLIENT_ID&request_uri=urn:ietf:params:oauth:request_uri:bwc4JK-ESC0w8acc191e-Y1LTC2
```

The authorization server MUST reject any authorization request that includes parameters alongside `request_uri` (except `client_id`).

### Benefits

- **Tamper-proof**: Parameters are submitted directly to the AS, not via the browser
- **No URL length limits**: Complex requests with RAR or many scopes
- **Confidential parameters**: Sensitive scopes or claims not exposed in browser history
- **Server authentication**: Client authenticates when pushing the request
- **DPoP binding**: Can include `dpop_jkt` to bind authorization code to a DPoP key

### When to Use PAR

- High-security environments (finance, healthcare)
- Requests with RAR (rich authorization details)
- When combined with DPoP or FAPI profiles
- Requests with many parameters that exceed URL limits

---

## 4. Rich Authorization Requests — RAR (RFC 9396)

RAR allows clients to express fine-grained authorization requirements beyond simple scope strings using structured JSON.

### Request Parameter

The `authorization_details` parameter is a JSON array:

```json
[
  {
    "type": "payment_initiation",
    "instructedAmount": {
      "currency": "EUR",
      "amount": "123.50"
    },
    "creditorName": "Merchant A",
    "creditorAccount": {
      "iban": "DE02100100109307118603"
    }
  }
]
```

### Common Fields

| Field | Required | Description |
|-------|----------|-------------|
| `type` | Yes | Authorization type identifier (registered or URI) |
| `locations` | No | Resource server URLs where this authorization applies |
| `actions` | No | Actions the client wants to perform |
| `datatypes` | No | Data types the client wants to access |
| `identifier` | No | Specific resource identifier |
| `privileges` | No | Privileges the client wants |

### Example: Open Banking

```http
POST /par
Content-Type: application/x-www-form-urlencoded

response_type=code
&client_id=CLIENT_ID
&authorization_details=[
  {
    "type": "account_information",
    "actions": ["list_accounts", "read_balances", "read_transactions"],
    "locations": ["https://api.bank.example.com"]
  },
  {
    "type": "payment_initiation",
    "instructedAmount": {"currency": "EUR", "amount": "50.00"},
    "creditorAccount": {"iban": "DE89370400440532013000"}
  }
]
```

### RAR in Token Response

The AS includes the granted `authorization_details` in the token response:

```json
{
  "access_token": "...",
  "authorization_details": [
    {
      "type": "payment_initiation",
      "instructedAmount": {"currency": "EUR", "amount": "50.00"},
      "creditorAccount": {"iban": "DE89370400440532013000"}
    }
  ]
}
```

### RAR vs. Scopes

| Feature | Scopes | RAR |
|---------|--------|-----|
| Granularity | Coarse (string labels) | Fine-grained (structured JSON) |
| Transaction-specific | No | Yes (amounts, accounts, resources) |
| Standardization | Varies per provider | Type-based with registered types |
| Use case | API access levels | Financial transactions, healthcare |

RAR and scopes can be used together — scopes for broad API access, RAR for transaction details.

---

## 5. GNAP — Grant Negotiation and Authorization Protocol

GNAP (RFC 9635) is a next-generation protocol designed to replace OAuth 2.0 with a more flexible, interaction-agnostic framework.

### Key Differences from OAuth 2.0

| Aspect | OAuth 2.0 | GNAP |
|--------|-----------|------|
| Client identification | `client_id` string | Key-based or instance reference |
| Request format | Form-encoded | JSON |
| Grant types | Fixed set (code, client_credentials, etc.) | Flexible interaction modes |
| Sender constraint | Optional (DPoP/mTLS bolt-on) | Built-in key binding |
| Multiple access tokens | Not native | Native support |
| Subject info | Separate OIDC layer | Built-in subject requests |

### GNAP Grant Request

```http
POST /gnap/tx
Content-Type: application/json

{
  "access_token": {
    "access": [
      {
        "type": "photo-api",
        "actions": ["read", "write"],
        "locations": ["https://photos.example.com"]
      }
    ]
  },
  "client": {
    "key": {
      "proof": "httpsig",
      "jwk": { "kty": "EC", "crv": "P-256", "x": "...", "y": "..." }
    }
  },
  "interact": {
    "start": ["redirect"],
    "finish": {
      "method": "redirect",
      "uri": "https://app.example.com/callback",
      "nonce": "LKLTI25DK82FX4T4QFZC"
    }
  }
}
```

### GNAP Response (Interaction Required)

```json
{
  "interact": {
    "redirect": "https://auth.example.com/interact/4CF492MLVMSW9MKMXKHQ",
    "finish": "MBDOFXG4Y5CVJCX821LH"
  },
  "continue": {
    "access_token": {
      "value": "80UPRY5NM33OMUKMKSKU",
      "bound": true
    },
    "uri": "https://auth.example.com/gnap/continue",
    "wait": 30
  }
}
```

### When to Consider GNAP

- Greenfield projects with no OAuth 2.0 legacy
- IoT/device scenarios needing flexible interaction models
- Systems requiring multiple simultaneous access tokens
- When sender-constrained tokens are mandatory by default
- **Note**: GNAP is still early in adoption — OAuth 2.0 + extensions remains the pragmatic choice for most production systems as of 2024–2025

---

## 6. mTLS Client Authentication (RFC 8705)

Mutual TLS provides strong client authentication using X.509 certificates, replacing client secrets entirely.

### Two Modes

**1. PKI-Based (`tls_client_auth`)** — Client presents a CA-signed certificate:
```json
{
  "client_id": "my-service",
  "token_endpoint_auth_method": "tls_client_auth",
  "tls_client_auth_subject_dn": "CN=my-service,O=MyOrg,C=US"
}
```

**2. Self-Signed (`self_signed_tls_client_auth`)** — Client registers its certificate directly:
```json
{
  "client_id": "my-service",
  "token_endpoint_auth_method": "self_signed_tls_client_auth",
  "jwks": {
    "keys": [{ "kty": "RSA", "use": "sig", "x5c": ["MIIBIjANBg..."] }]
  }
}
```

### Token Request with mTLS

```bash
curl -X POST https://auth.example.com/token \
  --cert client.pem \
  --key client-key.pem \
  -d "grant_type=client_credentials&client_id=my-service&scope=api:read"
```

No `client_secret` is needed — the TLS handshake proves client identity.

### Certificate-Bound Access Tokens

The AS can bind access tokens to the client certificate:
```json
{
  "access_token": "eyJ...",
  "cnf": {
    "x5t#S256": "bwcK0esc3ACC3DB2Y5_lESsXE8o9ltc05O89jdN-dg2"
  }
}
```

Resource servers verify that the presenting client's certificate thumbprint matches `x5t#S256`.

### mTLS vs. Other Client Auth Methods

| Method | Security | Complexity | Use Case |
|--------|----------|------------|----------|
| `client_secret_basic` | Low | Low | Development, low-security |
| `client_secret_post` | Low | Low | When basic auth is awkward |
| `client_secret_jwt` | Medium | Medium | Shared-secret JWT assertion |
| `private_key_jwt` | High | Medium | Asymmetric JWT assertion |
| `tls_client_auth` | Very High | High | Enterprise, financial APIs |
| `self_signed_tls_client_auth` | High | Medium | When PKI is overkill |

---

## 7. JWT-Secured Authorization Requests — JAR (RFC 9101)

JAR packages authorization parameters into a signed (and optionally encrypted) JWT, ensuring integrity and confidentiality.

### Request Object JWT

```json
{
  "iss": "client-id",
  "aud": "https://auth.example.com",
  "response_type": "code",
  "client_id": "client-id",
  "redirect_uri": "https://app.example.com/callback",
  "scope": "openid profile",
  "state": "af0ifjsldkj",
  "nonce": "n-0S6_WzA2Mj",
  "code_challenge": "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
  "code_challenge_method": "S256",
  "iat": 1700000000,
  "exp": 1700000300,
  "nbf": 1700000000
}
```

### Usage Modes

**Pass by value** — JWT included directly in the request:
```
GET /authorize?client_id=CLIENT_ID&request=eyJhbGciOiJSUzI1NiIs...
```

**Pass by reference** — JWT hosted at a URL:
```
GET /authorize?client_id=CLIENT_ID&request_uri=https://app.example.com/request-objects/abc123
```

### JAR vs. PAR

| Feature | JAR | PAR |
|---------|-----|-----|
| Integrity | JWT signature | Server-side storage |
| Confidentiality | JWT encryption (optional) | Back-channel transport |
| Hosting | Client-hosted or inline | AS-hosted |
| Client auth | Via JWT signature | Via HTTP auth methods |
| FAPI compliance | Yes (FAPI 1.0) | Yes (FAPI 2.0 prefers PAR) |

**FAPI 2.0** prefers PAR over JAR for simplicity, but both are valid.

---

## 8. Step-Up Authentication (RFC 9470)

Step-up authentication allows resource servers to require stronger authentication when the current authentication level is insufficient.

### How It Works

1. Client accesses a resource with a valid access token
2. Resource server determines the operation requires higher assurance
3. Resource server returns `401` with `insufficient_user_authentication` error
4. Client initiates a new authorization request with required `acr_values` or `max_age`
5. User completes step-up (e.g., MFA, biometric)
6. Client retries with the new, stronger token

### Resource Server Challenge

```http
HTTP/1.1 401 Unauthorized
WWW-Authenticate: Bearer error="insufficient_user_authentication",
  error_description="A]higher authentication level is required",
  acr_values="urn:example:mfa",
  max_age=300
```

### Client Step-Up Request

```
GET /authorize?
  response_type=code
  &client_id=CLIENT_ID
  &scope=openid
  &acr_values=urn:example:mfa
  &max_age=300
  &claims={"id_token":{"acr":{"essential":true,"values":["urn:example:mfa"]}}}
```

### Token Claims After Step-Up

```json
{
  "sub": "user-123",
  "acr": "urn:example:mfa",
  "auth_time": 1700000000,
  "amr": ["pwd", "otp"]
}
```

### ACR (Authentication Context Class Reference) Values

```
urn:example:password         — Password only
urn:example:mfa              — Multi-factor authentication
urn:example:mfa:phishing_resistant — FIDO2/WebAuthn
phr                          — Phishing-resistant (common shorthand)
phrh                         — Phishing-resistant hardware-bound
```

### Use Cases

- Financial transactions above a threshold
- Accessing sensitive PII
- Administrative operations
- Consent to high-risk scopes
- Account recovery / credential changes

---

## 9. Token Introspection (RFC 7662)

Introspection allows resource servers to query the authorization server about the state of an opaque access token.

### Request

```http
POST /introspect
Content-Type: application/x-www-form-urlencoded
Authorization: Basic BASE64(resource_server_id:resource_server_secret)

token=ACCESS_TOKEN
&token_type_hint=access_token
```

### Active Token Response

```json
{
  "active": true,
  "sub": "user-123",
  "client_id": "my-app",
  "scope": "openid profile email",
  "iss": "https://auth.example.com",
  "aud": "https://api.example.com",
  "exp": 1700003600,
  "iat": 1700000000,
  "token_type": "Bearer",
  "cnf": {
    "x5t#S256": "..."
  }
}
```

### Inactive Token Response

```json
{
  "active": false
}
```

The AS MUST return `{"active": false}` for expired, revoked, or unknown tokens — never leak details about why a token is inactive.

### Performance Considerations

- **Caching**: Cache introspection responses for short periods (30–60s) to reduce load
- **JWT alternative**: Use JWT access tokens with local validation to avoid introspection round-trips
- **Batch introspection**: Not standardized — consider JWT tokens if you need high throughput
- **Rate limiting**: Protect the introspection endpoint from abuse

### Introspection vs. JWT Validation

| Aspect | Introspection | JWT Validation |
|--------|--------------|----------------|
| Network call | Every validation | Only for JWKS fetch |
| Real-time revocation | Yes | No (until expiry) |
| Token size | Small (opaque) | Larger (claims in token) |
| AS load | Higher | Lower |
| Best for | Revocable tokens, low throughput | High throughput, short-lived tokens |

---

## 10. Token Revocation (RFC 7009)

Token revocation allows clients to notify the AS that a token is no longer needed.

### Request

```http
POST /revoke
Content-Type: application/x-www-form-urlencoded
Authorization: Basic BASE64(client_id:client_secret)

token=REFRESH_TOKEN
&token_type_hint=refresh_token
```

### Response

The AS MUST respond with `200 OK` regardless of whether the token was valid, already revoked, or unknown — this prevents token enumeration.

### Revocation Cascading

- Revoking a **refresh token** SHOULD also revoke associated access tokens
- Revoking an **access token** does NOT revoke the refresh token
- For token families (rotation), revoking one token in the family SHOULD revoke all

### Implementation Notes

- Always revoke on user logout
- Revoke on password change / account compromise
- Revoke on consent withdrawal
- Admin revocation for compromised clients (revoke all tokens for a `client_id`)
- For JWT access tokens, use short expiry + revocation list or introspection

---

## 11. Combining Patterns

### FAPI 2.0 Security Profile (Financial-Grade)

Combines multiple patterns for highest security:
```
PAR + DPoP + RAR + S256 PKCE + exact redirect URI
```

Flow:
1. Client registers with `private_key_jwt` or `tls_client_auth`
2. Client generates DPoP key pair
3. Client pushes authorization request via PAR (with `authorization_details` and `dpop_jkt`)
4. User authenticates and consents
5. Client exchanges code with DPoP proof
6. Resource requests include `Authorization: DPoP <token>` + DPoP proof header

### Healthcare / SMART on FHIR

```
Authorization Code + PKCE + launch scope + FHIR resource scopes + token introspection
```

Scopes: `launch/patient patient/Observation.read patient/MedicationRequest.write`

### IoT Device with Backend

```
Device Authorization Flow + Token Exchange + Certificate-Bound Tokens
```

1. Device gets user code via device authorization
2. User authorizes on a separate device
3. Backend exchanges device token for downstream service tokens with mTLS binding
