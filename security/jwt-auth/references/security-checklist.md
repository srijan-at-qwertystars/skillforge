# JWT Security Checklist

Comprehensive checklist for securing JWT-based authentication systems. Each item is actionable — check it off during implementation and security review.

## Table of Contents

- [Algorithm Validation](#algorithm-validation)
- [Claim Verification](#claim-verification)
- [Key Management](#key-management)
- [Token Storage](#token-storage)
- [Transport Security](#transport-security)
- [Revocation](#revocation)
- [Logging and Monitoring](#logging-and-monitoring)
- [Compliance Considerations](#compliance-considerations)
- [Implementation Hardening](#implementation-hardening)
- [Operational Security](#operational-security)

---

## Algorithm Validation

### Critical

- [ ] **Pin the expected algorithm in verification code.** Never read `alg` from the token header to decide how to verify. Use an allowlist:
  ```javascript
  jwt.verify(token, key, { algorithms: ['ES256'] }); // GOOD
  jwt.verify(token, key);                             // BAD — trusts token's alg
  ```

- [ ] **Reject `alg: "none"` unconditionally.** Ensure your library does not accept unsigned tokens. Test by crafting a token with `{"alg":"none"}` and empty signature.

- [ ] **Prevent algorithm confusion attacks.** If using RSA (asymmetric), ensure the verifier cannot be tricked into using the public key as an HMAC secret:
  ```python
  # GOOD: explicitly specify algorithm
  jwt.decode(token, rsa_public_key, algorithms=["RS256"])
  # BAD: allows algorithm switching
  jwt.decode(token, rsa_public_key, algorithms=["RS256", "HS256"])
  ```

- [ ] **Use strong algorithms.** Minimum: HS256 (symmetric), RS256 (RSA), ES256 (ECDSA). Preferred: ES256 or EdDSA for new systems.

- [ ] **Reject unknown `kid` values.** Validate `kid` against a known allowlist. Never use `kid` in file paths, SQL queries, or any dynamic lookup without sanitization.

### Recommended

- [ ] **Plan migration path for algorithm upgrades.** Document how to rotate from RS256 → ES256 or HS256 → EdDSA without downtime.
- [ ] **Test with deliberately malformed algorithm headers** (empty string, numeric, array).

---

## Claim Verification

### Critical

- [ ] **Always validate `exp` (expiration).** Reject tokens without `exp`. Set access token `exp` to 5-15 minutes.
  ```python
  jwt.decode(token, key, algorithms=["RS256"],
      options={"require": ["exp"]})
  ```

- [ ] **Always validate `iss` (issuer).** Must match your auth server's identifier exactly:
  ```javascript
  jwt.verify(token, key, { issuer: 'https://auth.example.com' });
  ```

- [ ] **Always validate `aud` (audience).** Each service must reject tokens not intended for it:
  ```python
  jwt.decode(token, key, algorithms=["RS256"], audience="api.example.com")
  ```

- [ ] **Validate `nbf` (not before) when present.** Reject tokens used before their validity window.

- [ ] **Use `sub` (subject) for user identification.** Never rely on mutable claims (name, email) for identity.

### Recommended

- [ ] **Set and validate `iat` (issued at).** Reject tokens with `iat` far in the past (e.g., >24h for access tokens).
- [ ] **Use `jti` (JWT ID) for critical operations.** Enables individual token revocation and replay detection.
- [ ] **Namespace custom claims** to avoid collisions with registered claims or future specs:
  ```json
  { "app:role": "admin", "app:tenant": "t_42" }
  ```
- [ ] **Validate all custom claims** used for authorization decisions against expected types and values.
- [ ] **Limit claim size.** Keep total JWT under 1KB. Large tokens increase latency and risk exceeding header limits.

---

## Key Management

### Critical

- [ ] **Generate cryptographically strong keys.**
  ```bash
  # HMAC (HS256): 256+ bits of randomness
  openssl rand -base64 64

  # RSA: 2048-bit minimum, 4096-bit recommended
  openssl genrsa -out private.pem 4096

  # EC (ES256): P-256 curve
  openssl ecparam -genkey -name prime256v1 -noout -out private-ec.pem

  # EdDSA (Ed25519)
  openssl genpkey -algorithm Ed25519 -out private-ed25519.pem
  ```

- [ ] **Never hardcode secrets in source code.** Load from environment variables, secret managers, or KMS.

- [ ] **Store private keys in a secrets manager.** Use AWS KMS, GCP KMS, Azure Key Vault, or HashiCorp Vault. Not environment variables in production.

- [ ] **Rotate signing keys on a regular schedule.** Minimum: every 90 days. Automate the process.

- [ ] **Use distinct keys for different token types.** Access tokens and refresh tokens should use different signing keys.

- [ ] **Publish public keys via JWKS endpoint** (`/.well-known/jwks.json`). Include `kid` in both keys and token headers.

### Recommended

- [ ] **Support multiple active verification keys** during rotation. Never remove the old key before all tokens signed with it have expired.
- [ ] **Use `kid` (Key ID) in all token headers.** Enables verifiers to select the correct key without trial-and-error.
- [ ] **Set key usage metadata** in JWKS (`use: "sig"` for signing keys, `use: "enc"` for encryption keys).
- [ ] **Monitor key age** and alert when rotation is overdue.
- [ ] **Implement emergency key revocation** — ability to immediately disable a compromised key and force re-authentication.

---

## Token Storage

### Critical (Browser)

- [ ] **Store refresh tokens in httpOnly, Secure, SameSite=Strict cookies only.** Never in localStorage, sessionStorage, or JavaScript-accessible cookies.
  ```javascript
  res.cookie('refreshToken', token, {
    httpOnly: true,
    secure: true,
    sameSite: 'strict',
    path: '/auth/refresh',
    maxAge: 7 * 24 * 3600 * 1000,
  });
  ```

- [ ] **Store access tokens in memory only (JavaScript variable).** Not in any persistent storage. Re-obtain via refresh on page reload.

- [ ] **Set cookie `Path` to the refresh endpoint only** (`/auth/refresh`). This prevents the cookie from being sent on every request.

### Critical (Mobile)

- [ ] **Use platform-secure storage.** iOS Keychain, Android Keystore / EncryptedSharedPreferences.
- [ ] **Never store tokens in plain SharedPreferences, UserDefaults, or files.**
- [ ] **Set appropriate accessibility level.** iOS: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.

### Critical (Server)

- [ ] **Store refresh tokens server-side** (database or Redis) for revocation capability.
- [ ] **Hash stored refresh tokens** (bcrypt or SHA-256) — never store in plaintext.
- [ ] **Use secure environment variables or secret managers** for server-to-server tokens.

### Recommended

- [ ] **Clear all token storage on logout.** Memory, cookies, and server-side records.
- [ ] **Implement token binding** (DPoP) for high-security applications to prevent stolen tokens from being used.

---

## Transport Security

### Critical

- [ ] **Transmit tokens only over HTTPS.** Never send JWTs over unencrypted HTTP.
- [ ] **Set `Secure` flag on all token cookies.** Prevents transmission over HTTP.
- [ ] **Send access tokens in `Authorization: Bearer` header only.** Never in query strings, form data, or URL fragments.
- [ ] **Set HSTS header** to prevent protocol downgrade:
  ```
  Strict-Transport-Security: max-age=63072000; includeSubDomains; preload
  ```

### Recommended

- [ ] **Use TLS 1.2+.** Disable TLS 1.0 and 1.1.
- [ ] **Avoid passing tokens in URLs.** They appear in server logs, browser history, and Referer headers.
- [ ] **Strip tokens from error responses and error logs.** Never echo back a submitted token in a 401 response body.
- [ ] **Set appropriate CORS headers.** Restrict `Access-Control-Allow-Origin` to specific origins. Never use `*` with credentials.

---

## Revocation

### Critical

- [ ] **Implement refresh token rotation.** Issue a new refresh token on every use. Invalidate the old one:
  ```python
  def refresh(old_rt):
      if is_revoked(old_rt.jti):
          revoke_family(old_rt.family_id)
          raise SecurityAlert("Token reuse detected")
      new_rt = issue_new_refresh_token(family_id=old_rt.family_id)
      revoke(old_rt.jti)
      return new_rt
  ```

- [ ] **Detect refresh token reuse** and revoke the entire token family when reuse is detected.

- [ ] **Revoke all refresh tokens on password change** and account compromise.

- [ ] **Revoke all tokens on account lockout or deactivation.**

### Recommended

- [ ] **Implement a token blocklist** (Redis/DB with TTL) for immediate access token revocation when needed (security incidents, manual logout-everywhere).
- [ ] **Use token versioning** — store `token_version` per user, increment on security events, reject tokens with stale versions.
- [ ] **Set TTL on blocklist entries** matching token expiry to prevent unbounded growth.
- [ ] **Implement "logout everywhere"** — revoke all refresh tokens for a user and increment token version.
- [ ] **Broadcast revocation events** in distributed systems (Redis pub/sub, message queue).

---

## Logging and Monitoring

### Critical

- [ ] **Never log full JWT tokens.** Log only `jti`, `sub`, `iss`, and `kid`.
  ```python
  # BAD
  logger.info(f"Auth: {request.headers['Authorization']}")

  # GOOD
  logger.info(f"Auth: sub={claims['sub']} jti={claims['jti']} kid={header['kid']}")
  ```

- [ ] **Log authentication failures** with IP, user-agent, timestamp, and failure reason.

- [ ] **Log token revocation events** including which token, which user, and the reason.

- [ ] **Alert on anomalous patterns:**
  - High rate of invalid signatures (possible key compromise or attack)
  - Refresh token reuse (token theft indicator)
  - Tokens with unknown `kid` values (possible spoofing)
  - Sudden spike in expired token errors (clock issue or attack)

### Recommended

- [ ] **Log refresh token rotation events** for audit trail.
- [ ] **Monitor token issuance rate** per user — flag abnormal spikes.
- [ ] **Track unique `jti` counts** to detect token replay attacks.
- [ ] **Set up dashboards** for: tokens issued/hour, refresh rate, rejection rate, revocation rate.
- [ ] **Log `iat` vs server time** to detect clock skew across services.
- [ ] **Integrate with SIEM** (Splunk, ELK, Datadog) for correlation with other security events.

---

## Compliance Considerations

### GDPR / Privacy

- [ ] **Minimize PII in token claims.** Use opaque identifiers (`sub: "u_8a3f"`) not emails or names.
- [ ] **If tokens contain PII, consider JWE encryption** so intermediaries cannot read claims.
- [ ] **Implement token purging** on account deletion (right to erasure).
- [ ] **Document what data is stored in tokens** in your privacy policy and data processing records.

### PCI-DSS (Payment Systems)

- [ ] **Never store cardholder data in JWTs.**
- [ ] **Use short token lifetimes** (≤15 minutes for access tokens).
- [ ] **Implement strong key management** using HSMs or certified KMS.
- [ ] **Log all authentication events** and retain logs per PCI requirements.
- [ ] **Implement MFA** for administrative and sensitive operations.

### HIPAA (Healthcare)

- [ ] **Encrypt tokens containing PHI** using JWE.
- [ ] **Implement audit logging** for all token-based access to patient data.
- [ ] **Set aggressive token expiry** for sessions accessing health records.
- [ ] **Implement break-the-glass audit** for emergency access patterns.

### SOC 2

- [ ] **Document token lifecycle** in security policies.
- [ ] **Implement and test token revocation** procedures.
- [ ] **Maintain key rotation schedule** with evidence of execution.
- [ ] **Monitor and alert on authentication anomalies.**

### General

- [ ] **Document your JWT security architecture** — algorithms, key management, token lifecycle, revocation strategy.
- [ ] **Conduct periodic security reviews** of JWT implementation (at least annually).
- [ ] **Include JWT-specific test cases in penetration testing** scope (algorithm confusion, key injection, token manipulation).

---

## Implementation Hardening

### Critical

- [ ] **Use well-maintained JWT libraries.** Don't implement JWT parsing/verification yourself.
  - Node.js: `jose` (recommended) or `jsonwebtoken`
  - Python: `PyJWT` or `python-jose`
  - Go: `golang-jwt/jwt/v5`
  - Java: `io.jsonwebtoken:jjwt` or `com.nimbusds:nimbus-jose-jwt`
  - .NET: `Microsoft.IdentityModel.JsonWebTokens`

- [ ] **Keep JWT libraries updated.** Subscribe to security advisories for your library.

- [ ] **Rate-limit authentication endpoints:**
  ```
  POST /auth/login     → 5 requests/minute per IP
  POST /auth/refresh   → 10 requests/minute per user
  POST /auth/token     → 20 requests/minute per client_id
  ```

- [ ] **Validate all input to auth endpoints.** Treat tokens as untrusted input — parse safely, handle malformed input gracefully.

### Recommended

- [ ] **Use parameterized error responses.** Don't reveal why authentication failed:
  ```json
  // GOOD: generic
  { "error": "invalid_credentials" }

  // BAD: reveals internal details
  { "error": "user 'admin@co.com' not found in database" }
  ```

- [ ] **Implement request signing or DPoP** for high-value API endpoints.
- [ ] **Test for JWT-specific vulnerabilities** in CI/CD:
  - Craft `alg:none` tokens and verify rejection
  - Craft RS256→HS256 confusion tokens and verify rejection
  - Test with expired, future-dated, and missing-claim tokens
- [ ] **Set `typ: "JWT"` in headers** and validate it to prevent token type confusion with other JWS/JWE uses.
- [ ] **Use distinct `iss` values** for different environments (dev, staging, prod) to prevent cross-environment token use.

---

## Operational Security

### Critical

- [ ] **Have an incident response plan for key compromise:**
  1. Generate new signing key immediately
  2. Add new key to JWKS
  3. Start signing with new key
  4. Revoke all refresh tokens (force re-authentication)
  5. Remove compromised key from JWKS
  6. Investigate scope of compromise
  7. Notify affected users if required

- [ ] **Automate key rotation** — don't rely on manual processes.
- [ ] **Test your revocation system** regularly. Verify that revoking a token actually blocks access.

### Recommended

- [ ] **Run chaos testing** — simulate key rotation, clock skew, Redis failure, DB failure during auth.
- [ ] **Maintain runbooks** for common JWT-related incidents (mass token revocation, key rotation, library vulnerability patching).
- [ ] **Practice key ceremony** for production key generation (documented, witnessed, auditable).
- [ ] **Keep a key inventory** — know what keys exist, where they're stored, and when they expire.
- [ ] **Version your auth API** so JWT format changes can be rolled out safely.
