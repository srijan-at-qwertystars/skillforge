# Review: passkey-webauthn

Accuracy: 5/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 5/5
Overall: 5.0/5

Issues: none

## Structure Check

- **YAML frontmatter**: Has `name` and `description` ✅
- **Positive triggers**: Comprehensive — covers navigator.credentials.create/get, SimpleWebAuthn, py_webauthn, webauthn-rs, java-webauthn-server, passkeys, passwordless login, FIDO2, ceremonies, attestation/assertion, conditional UI, platform authenticators, security keys, migration ✅
- **Negative triggers**: Explicit exclusions for OAuth/OIDC, SAML, basic password auth, JWT, API key auth, session management, general crypto ✅
- **Body length**: 411 lines (under 500) ✅
- **Voice**: Imperative, no filler ✅
- **Examples**: Multiple code examples with input context (registration, authentication, conditional UI, migration prompt, feature detection) ✅
- **references/ linked**: Yes — advanced-patterns.md, troubleshooting.md, security-analysis.md ✅
- **scripts/ linked**: Yes — generate-challenge.py, verify-attestation.py, setup-dev-env.sh ✅
- **assets/ linked**: Yes — schema.sql, webauthn-client.ts, webauthn-server.ts, nginx-https.conf ✅

## Content Verification

### WebAuthn API Calls
- `navigator.credentials.create({ publicKey })` parameters (challenge, rp, user, pubKeyCredParams, authenticatorSelection, attestation, excludeCredentials, timeout) — all correct per W3C spec and MDN ✅
- `navigator.credentials.get({ publicKey, mediation: 'conditional' })` for conditional UI — correct ✅
- Algorithm IDs: -7 (ES256), -257 (RS256) — correct COSE identifiers ✅

### SimpleWebAuthn API (current: v13.x)
- `generateRegistrationOptions`, `verifyRegistrationResponse`, `generateAuthenticationOptions`, `verifyAuthenticationResponse` — correct function names, stable across v10-v13 ✅
- `startRegistration({ optionsJSON })`, `startAuthentication({ optionsJSON })` — correct v10+ browser API ✅
- `verification.registrationInfo.credential` (id, publicKey, counter) — correct v10+ response shape ✅
- `isoUint8Array.fromUTF8String` from `@simplewebauthn/server/helpers` — correct ✅
- `supportedAlgorithmIDs` convenience parameter — correct ✅

### py_webauthn API (current: v2.7.x)
- Import from `webauthn` package — correct ✅
- `generate_registration_options`, `verify_registration_response` — correct function names ✅
- `AuthenticatorSelectionCriteria`, `ResidentKeyRequirement`, `UserVerificationRequirement` from `webauthn.helpers.structs` — correct ✅

### Attestation/Assertion Flow
- Three-step ceremony (server options → client API → server verify) — correct ✅
- Verification checklist (challenge, origin, rpId, signature, counter, UP, UV, attestation) — complete and accurate ✅

### Security Claims
- Phishing resistance via origin binding — cryptographically correct ✅
- AiTM/relay attack resistance — correctly explained (browser enforces real origin) ✅
- Counter=0 for synced passkeys — confirmed behavior ✅
- NIST 800-63B AAL mapping (AAL2 for passkeys w/ UV, AAL3 requires device-bound) — accurate ✅
- Token Binding deprecated in Chrome 120 — correct ✅

### Authenticator Data Flags
- UP=0x01, UV=0x04, BE=0x08, BS=0x10, AT=0x40, ED=0x80 — matches W3C spec and MDN ✅
- BE/BS combination table (singleDevice, multiDevice, invalid) — correct ✅

### Supporting Files Quality
- **schema.sql**: Well-structured PostgreSQL + SQLite schemas with proper binary storage, indexes, and challenge TTL ✅
- **webauthn-client.ts**: Production-quality with AbortController management, error categorization, conditional UI lifecycle ✅
- **webauthn-server.ts**: Complete Express router with credential store interface, session management, challenge single-use enforcement ✅
- **verify-attestation.py**: Correct CBOR parsing, authenticator data layout, packed self-attestation verification ✅
- **generate-challenge.py**: Proper CSPRNG usage, minimum entropy enforcement, base64url encoding ✅
- **setup-dev-env.sh**: Cross-platform mkcert installation, certificate generation, config snippets ✅
- **nginx-https.conf**: Proper security headers including Permissions-Policy for publickey-credentials-*, 310s proxy timeout ✅
- **references/**: Thorough coverage of enterprise attestation, credential backup states, MDS3, step-up auth, compliance frameworks ✅

## Trigger Check

- "implement passkeys" → matches "passkeys" in description ✅
- "WebAuthn authentication" → matches "WebAuthn" in description ✅
- "passwordless login" → matches "passwordless login" in description ✅
- "FIDO2 security key" → matches "FIDO2" and "security keys" ✅
- "passkey autofill" → matches "passkey autofill" ✅
- OAuth flow → excluded by "DO NOT TRIGGER" ✅
- SAML SSO → excluded by "DO NOT TRIGGER" ✅
- password hashing → excluded ("basic password auth") ✅
- JWT token validation → excluded ("JWT tokens") ✅

## Notes

Exceptionally comprehensive skill. Covers the full WebAuthn/passkey implementation lifecycle from registration through authentication, conditional UI, migration strategy, database schema, and security analysis. All API examples verified against current library versions. The 13 common pitfalls section addresses real-world engineering gotchas (rpId immutability, counter=0 for synced passkeys, base64url vs base64, transports replay). Reference documents provide production-grade depth on enterprise attestation, compliance mapping, and troubleshooting.
