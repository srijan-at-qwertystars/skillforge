---
name: passkey-webauthn
description: >
  Use this skill when implementing WebAuthn, FIDO2, or Passkey authentication flows.
  TRIGGER when: code calls navigator.credentials.create(), navigator.credentials.get(),
  imports @simplewebauthn/server, @simplewebauthn/browser, py_webauthn, webauthn-rs,
  or java-webauthn-server; user asks about passkeys, passwordless login, FIDO2,
  WebAuthn registration/authentication ceremonies, attestation, assertion,
  discoverable credentials, conditional UI, passkey autofill, platform authenticators,
  security keys, or migrating from passwords to passkeys.
  DO NOT TRIGGER when: implementing OAuth/OIDC, SAML, basic password auth, JWT tokens,
  API key auth, session management, or general cryptography unrelated to WebAuthn.
---

# WebAuthn / Passkeys Implementation Guide

## Architecture

WebAuthn (W3C Level 2, Level 3 draft) + CTAP2 (FIDO Alliance) = FIDO2 stack.

**Three principals:**
- **Relying Party (RP):** Your server. Identified by `rpId` (a domain, e.g. `example.com`). Must serve over HTTPS.
- **Client:** Browser or OS. Executes WebAuthn JS API, mediates between RP and authenticator.
- **Authenticator:** Holds private keys, performs crypto. Two types:
  - **Platform authenticator:** Built into device (Touch ID, Face ID, Windows Hello, Android biometrics).
  - **Roaming authenticator:** External hardware (YubiKey, Titan Key) via USB/NFC/BLE.

**Core flow:** Asymmetric keypair per credential. Private key never leaves authenticator. RP stores public key. Authentication = sign a challenge with private key, RP verifies with public key. Phishing-resistant: credentials are origin-bound.

## Passkeys vs Traditional WebAuthn

| Aspect | Traditional WebAuthn | Passkeys (synced) |
|---|---|---|
| Storage | Device-bound (single authenticator) | Cloud-synced (iCloud Keychain, Google Password Manager, 1Password) |
| Survivability | Lost if device lost | Survive device loss, sync across devices |
| Discoverability | May be non-discoverable | Always discoverable (resident credentials) |
| User verification | Configurable | Typically required |
| Recovery | Need backup authenticator | Cloud backup handles recovery |

**Device-bound passkeys** exist too (e.g. hardware security keys). Not synced. Use when compliance requires non-exportable keys.

## Registration Flow (Attestation Ceremony)

### 1. Server generates options

```typescript
// Using @simplewebauthn/server
import { generateRegistrationOptions } from '@simplewebauthn/server';

const options = await generateRegistrationOptions({
  rpName: 'My App',
  rpID: 'example.com',
  userName: user.email,
  userID: isoUint8Array.fromUTF8String(user.id),
  attestationType: 'none',  // 'none' | 'indirect' | 'direct' | 'enterprise'
  authenticatorSelection: {
    residentKey: 'required',        // Force discoverable credential (passkey)
    userVerification: 'preferred',  // 'required' | 'preferred' | 'discouraged'
    authenticatorAttachment: 'platform', // or 'cross-platform' or omit for both
  },
  excludeCredentials: existingCredentials.map(c => ({
    id: c.credentialID,
    transports: c.transports,
  })),
  supportedAlgorithmIDs: [-7, -257], // ES256, RS256
});

// Store options.challenge in session, send options to client
```

### 2. Client calls navigator.credentials.create()

```typescript
import { startRegistration } from '@simplewebauthn/browser';

const attResp = await startRegistration({ optionsJSON: options });
// Send attResp to server for verification
```

**Raw API equivalent:**
```javascript
const credential = await navigator.credentials.create({
  publicKey: {
    challenge: Uint8Array.from(atob(options.challenge), c => c.charCodeAt(0)),
    rp: { name: 'My App', id: 'example.com' },
    user: {
      id: Uint8Array.from(userId, c => c.charCodeAt(0)),
      name: 'user@example.com',
      displayName: 'User Name',
    },
    pubKeyCredParams: [
      { alg: -7, type: 'public-key' },   // ES256 (preferred)
      { alg: -257, type: 'public-key' },  // RS256 (fallback)
    ],
    authenticatorSelection: {
      residentKey: 'required',
      userVerification: 'preferred',
    },
    timeout: 300000,
    attestation: 'none',
  },
});
```

### 3. Server verifies registration

```typescript
import { verifyRegistrationResponse } from '@simplewebauthn/server';

const verification = await verifyRegistrationResponse({
  response: attResp,
  expectedChallenge: storedChallenge,
  expectedOrigin: 'https://example.com',
  expectedRPID: 'example.com',
});

if (verification.verified && verification.registrationInfo) {
  const { credential, credentialDeviceType, credentialBackedUp } = verification.registrationInfo;
  // Store: credential.id, credential.publicKey, credential.counter,
  //        credentialDeviceType, credentialBackedUp, transports
}
```

## Authentication Flow (Assertion Ceremony)

### 1. Server generates options

```typescript
import { generateAuthenticationOptions } from '@simplewebauthn/server';

const options = await generateAuthenticationOptions({
  rpID: 'example.com',
  userVerification: 'preferred',
  // For discoverable credentials (passkeys), omit allowCredentials
  // For non-discoverable, provide allowCredentials list:
  allowCredentials: userCredentials.map(c => ({
    id: c.credentialID,
    transports: c.transports,
  })),
});
```

### 2. Client calls navigator.credentials.get()

```typescript
import { startAuthentication } from '@simplewebauthn/browser';

const assertionResp = await startAuthentication({ optionsJSON: options });
// Send assertionResp to server
```

### 3. Server verifies authentication

```typescript
import { verifyAuthenticationResponse } from '@simplewebauthn/server';

const verification = await verifyAuthenticationResponse({
  response: assertionResp,
  expectedChallenge: storedChallenge,
  expectedOrigin: 'https://example.com',
  expectedRPID: 'example.com',
  credential: {
    id: storedCredential.credentialID,
    publicKey: storedCredential.publicKey,
    counter: storedCredential.counter,
    transports: storedCredential.transports,
  },
});

if (verification.verified) {
  // Update counter: storedCredential.counter = verification.authenticationInfo.newCounter
  // Issue session token
}
```

## Server-Side Verification Checklist

Always verify these during both registration and authentication:
1. **Challenge:** Matches the one issued by server. Reject replays. Use cryptographically random, single-use challenges (≥16 bytes).
2. **Origin:** Matches expected origin exactly (`https://example.com`). Reject mismatches.
3. **rpId:** Hash matches the SHA-256 of expected RP ID. Prevents credential theft across domains.
4. **Signature:** Valid against stored public key (authentication) or self-consistent (registration with attestation).
5. **Counter:** Greater than stored counter. Detect cloned authenticators. Note: passkeys synced via cloud may report counter=0 always—handle gracefully.
6. **User Presence (UP):** Flag must be set (user interacted with authenticator).
7. **User Verification (UV):** Flag must match your policy. If `userVerification: 'required'`, UV must be set.
8. **Attestation:** If using `direct`/`enterprise`, validate attestation certificate chain against trusted roots.

## Conditional UI (Passkey Autofill)

Enable passkeys in the browser autofill dropdown—no modal, no separate button.

```html
<!-- Add 'webauthn' to autocomplete, must come last -->
<input type="text" name="username" autocomplete="username webauthn" />
```

```typescript
// Check support, then start conditional authentication
if (await PublicKeyCredential.isConditionalMediationAvailable?.()) {
  const abortController = new AbortController();

  const options = await fetchAuthOptionsFromServer();

  const assertionResp = await navigator.credentials.get({
    publicKey: options,
    mediation: 'conditional',
    signal: abortController.signal,
  });

  // User selected a passkey from autofill → verify on server
  await verifyOnServer(assertionResp);
}
```

Requirements: credentials must be discoverable (resident). Set `residentKey: 'required'` during registration. Works on Chrome 108+, Safari 16+, Edge 108+, Firefox 122+.

## Discoverable vs Non-Discoverable Credentials

- **Discoverable (resident):** Stored on authenticator, keyed by rpId. Authenticator can enumerate them without `allowCredentials`. Required for passkeys and conditional UI. Uses authenticator storage (limited on hardware keys, unlimited on platform/cloud).
- **Non-discoverable (server-side):** Credential ID stored on server only. Server must provide `allowCredentials` list. User must identify themselves first (e.g. enter username). Cannot be used with conditional UI.

Always prefer discoverable credentials for passkey flows. Use `residentKey: 'required'` in `authenticatorSelection`.

## Attestation Types

| Type | Use case | Privacy | Verification |
|---|---|---|---|
| `none` | Most apps. No attestation needed. | Best | No certificate chain |
| `indirect` | Anonymized attestation. | Good | Verify anonymization CA |
| `direct` | Enterprise, regulated. Full device attestation. | Lowest | Verify manufacturer CA |
| `enterprise` | Managed devices only. Includes device identifiers. | Minimal | Verify enterprise CA |

Use `none` unless you have a specific compliance requirement. Attestation adds complexity and may reduce authenticator compatibility.

## User Verification (UV)

Controls whether authenticator verifies user identity (biometric, PIN) vs just presence (touch).

- `required`: Authenticator MUST verify user. Use for sensitive operations (payment, account changes). Fails if authenticator cannot perform UV.
- `preferred`: Authenticator SHOULD verify user if capable. Default for most flows. Falls back to presence-only.
- `discouraged`: Skip UV. Fastest flow. Use when UP alone is sufficient.

Check `flags.uv` in the authenticator data response to confirm UV was performed.

## Cross-Device Authentication (Hybrid Transport)

Allows using a phone as authenticator for a desktop session via caBLE (cloud-assisted BLE).

Flow: Desktop shows QR code → User scans with phone → Phone authenticates via BLE relay → Desktop receives assertion.

Configure by including `'hybrid'` in transports:
```typescript
allowCredentials: [{
  id: credentialId,
  type: 'public-key',
  transports: ['hybrid', 'internal'],
}]
```

Browser handles QR code display and BLE negotiation. No server-side changes needed beyond listing `hybrid` transport.

## Database Schema

```sql
CREATE TABLE users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email TEXT UNIQUE NOT NULL,
  display_name TEXT NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE webauthn_credentials (
  credential_id BYTEA PRIMARY KEY,          -- raw credential ID from authenticator
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  public_key BYTEA NOT NULL,                -- COSE-encoded public key
  counter BIGINT NOT NULL DEFAULT 0,        -- signature counter
  transports TEXT[],                        -- ['internal','hybrid','usb','nfc','ble']
  device_type TEXT NOT NULL,                -- 'singleDevice' | 'multiDevice'
  backed_up BOOLEAN NOT NULL DEFAULT false, -- cloud-synced passkey?
  aaguid UUID,                              -- authenticator model identifier
  created_at TIMESTAMPTZ DEFAULT NOW(),
  last_used_at TIMESTAMPTZ,
  friendly_name TEXT                        -- user-assigned label
);

CREATE INDEX idx_credentials_user_id ON webauthn_credentials(user_id);
```

Key storage rules:
- Store `credential_id` as binary, not base64. Index it as primary key.
- Store `public_key` as COSE-encoded bytes. Do not convert to PEM for storage.
- Track `device_type` and `backed_up` to distinguish synced passkeys from device-bound keys.
- Store `transports` array from registration response—needed for `allowCredentials` in authentication.

## Python Example (py_webauthn)

```python
from webauthn import generate_registration_options, verify_registration_response
from webauthn import generate_authentication_options, verify_authentication_response
from webauthn.helpers.structs import (
    AuthenticatorSelectionCriteria,
    ResidentKeyRequirement,
    UserVerificationRequirement,
    PublicKeyCredentialDescriptor,
)

# Registration
reg_options = generate_registration_options(
    rp_id="example.com",
    rp_name="My App",
    user_id=user.id.encode(),
    user_name=user.email,
    authenticator_selection=AuthenticatorSelectionCriteria(
        resident_key=ResidentKeyRequirement.REQUIRED,
        user_verification=UserVerificationRequirement.PREFERRED,
    ),
)
# Send reg_options to client, store reg_options.challenge in session

# Verify registration
reg_verification = verify_registration_response(
    credential=client_response,
    expected_challenge=stored_challenge,
    expected_origin="https://example.com",
    expected_rp_id="example.com",
)
# Store reg_verification.credential_id, .credential_public_key, .sign_count
```

## Migration from Passwords to Passkeys

### Progressive enrollment strategy:
1. **After password login**, prompt user to create a passkey. Do not force—offer as upgrade.
2. **Store passkey alongside password**. User can use either method during transition.
3. **Track passkey coverage**. When user has passkeys on all their devices, offer to disable password.
4. **Never remove password silently**. Always let user control fallback options.

### Implementation pattern:
```typescript
// After successful password authentication:
if (await PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable()) {
  const shouldPrompt = !user.hasPasskey && !user.dismissedPasskeyPrompt;
  if (shouldPrompt) {
    showPasskeyRegistrationModal();
  }
}
```

### Account recovery considerations:
- Synced passkeys survive device loss via cloud backup.
- For device-bound credentials, require users to register ≥2 authenticators.
- Provide a recovery flow: email magic link → re-register new passkey.
- Never allow passkey registration from an unauthenticated state.

## Browser and Platform Support

| Platform | Passkey Creation | Passkey Auth | Conditional UI | Hybrid/Cross-Device |
|---|---|---|---|---|
| Chrome 108+ (desktop) | ✅ | ✅ | ✅ | ✅ |
| Chrome (Android) | ✅ | ✅ | ✅ | ✅ |
| Safari 16+ (macOS) | ✅ | ✅ | ✅ | ✅ |
| Safari (iOS 16+) | ✅ | ✅ | ✅ | ✅ |
| Edge 108+ | ✅ | ✅ | ✅ | ✅ |
| Firefox 122+ | ✅ | ✅ | ✅ | Limited |
| Windows Hello | ✅ | ✅ | ✅ | Via phone |
| Android 9+ | ✅ | ✅ | ✅ | ✅ |

Feature detection:
```javascript
// Platform authenticator available?
const available = await PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable();
// Conditional UI supported?
const conditionalOk = await PublicKeyCredential.isConditionalMediationAvailable?.();
```

## Recommended Libraries

| Language | Library | Install |
|---|---|---|
| JS/TS | `@simplewebauthn/server` + `@simplewebauthn/browser` | `npm i @simplewebauthn/server @simplewebauthn/browser` |
| Python | `py_webauthn` | `pip install webauthn` |
| Rust | `webauthn-rs` | `cargo add webauthn-rs` |
| Java | `java-webauthn-server` (Yubico) | Maven: `com.yubico:webauthn-server-core` |
| Go | `go-webauthn` | `go get github.com/go-webauthn/webauthn` |
| PHP | `web-auth/webauthn-framework` | `composer require web-auth/webauthn-lib` |

## Common Pitfalls and Security Considerations

1. **HTTPS required.** WebAuthn API is unavailable on HTTP (except localhost for dev).
2. **rpId must be a registrable domain.** Cannot use IP addresses. Must match or be a parent of the page origin. Setting `rpId: 'example.com'` allows subdomains like `auth.example.com`.
3. **Challenge reuse.** Generate a fresh cryptographically random challenge per ceremony. Never reuse. Expire after 5 minutes max.
4. **Counter handling.** Synced passkeys may always return counter=0. Do not reject counter=0 when `deviceType === 'multiDevice'`. For `singleDevice`, strictly enforce counter increment.
5. **Storing credential IDs.** Use binary/bytea, not base64 strings. Base64url encoding varies across libraries.
6. **Multiple credentials per user.** Always support multiple passkeys per account. Users have multiple devices.
7. **excludeCredentials during registration.** Always send to prevent duplicate credential creation.
8. **Attestation overkill.** Use `'none'` unless regulatory requirements demand device attestation. Direct attestation reduces privacy and compatibility.
9. **Timeout too short.** Set `timeout: 300000` (5 min) for registration. Users need time for biometrics/PIN setup.
10. **Missing transports.** Always store and replay `transports` from registration. Without them, browsers cannot optimize authenticator selection.
11. **Origin validation.** Compare full origin including scheme and port. `https://example.com` ≠ `https://example.com:8443`.
12. **Subdomain credentials.** If `rpId: 'example.com'`, credentials work on `sub.example.com`. Plan rpId carefully—it cannot be changed after credential creation.
13. **User handle ≠ username.** `user.id` (user handle) must be an opaque identifier, not PII. Max 64 bytes. Do not use email or username.

## Example: Full Registration + Authentication (SimpleWebAuthn)

**Input:** User clicks "Add Passkey" button.

**Server (registration options):**
```json
{
  "challenge": "dGhpcyBpcyBhIHRlc3QgY2hhbGxlbmdl",
  "rp": { "name": "My App", "id": "example.com" },
  "user": { "id": "dXNlcl8xMjM", "name": "alice@example.com", "displayName": "Alice" },
  "pubKeyCredParams": [{ "alg": -7, "type": "public-key" }],
  "authenticatorSelection": { "residentKey": "required", "userVerification": "preferred" },
  "timeout": 300000,
  "attestation": "none"
}
```

**Client response (sent to server):**
```json
{
  "id": "ABCDef12345...",
  "rawId": "ABCDef12345...",
  "type": "public-key",
  "response": {
    "attestationObject": "o2NmbXRkbm9uZWdhdHRTdG10oGhhdXRo...",
    "clientDataJSON": "eyJ0eXBlIjoid2ViYXV0aG4uY3JlYXRlIi..."
  },
  "authenticatorAttachment": "platform",
  "clientExtensionResults": {}
}
```

**Server output (after verification):**
```json
{
  "verified": true,
  "registrationInfo": {
    "credential": {
      "id": "ABCDef12345...",
      "publicKey": "<COSE-encoded bytes>",
      "counter": 0
    },
    "credentialDeviceType": "multiDevice",
    "credentialBackedUp": true
  }
}
```

**Input:** User visits login page with conditional UI enabled.

**Server (authentication options, no allowCredentials for discoverable flow):**
```json
{
  "challenge": "cmFuZG9tX2NoYWxsZW5nZV9ieXRlcw",
  "rpId": "example.com",
  "userVerification": "preferred",
  "timeout": 300000
}
```

**Client response (after user selects passkey from autofill):**
```json
{
  "id": "ABCDef12345...",
  "rawId": "ABCDef12345...",
  "type": "public-key",
  "response": {
    "authenticatorData": "SZYN5YgOjGh0NBcPZHZgW4/krrmihjLHmVzzuoMdl2MF...",
    "clientDataJSON": "eyJ0eXBlIjoid2ViYXV0aG4uZ2V0Iiw...",
    "signature": "MEUCIQDsN1Xdb...",
    "userHandle": "dXNlcl8xMjM"
  },
  "authenticatorAttachment": "platform",
  "clientExtensionResults": {}
}
```

**Server output:**
```json
{
  "verified": true,
  "authenticationInfo": {
    "newCounter": 1,
    "credentialDeviceType": "multiDevice",
    "credentialBackedUp": true,
    "userVerified": true
  }
}
```
