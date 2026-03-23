# WebAuthn Advanced Patterns

## Table of Contents

- [Enterprise Attestation](#enterprise-attestation)
- [Cross-Device Flows (caBLE/Hybrid)](#cross-device-flows-cablehybrid)
- [Conditional UI Deep Dive](#conditional-ui-deep-dive)
- [Credential Backup State Handling](#credential-backup-state-handling)
- [Multi-Device Credential Management](#multi-device-credential-management)
- [Account Recovery Without Passwords](#account-recovery-without-passwords)
- [Step-Up Authentication](#step-up-authentication)
- [Combining Passkeys with Other MFA](#combining-passkeys-with-other-mfa)
- [FIDO Metadata Service (MDS3)](#fido-metadata-service-mds3)
- [Authenticator Selection Criteria](#authenticator-selection-criteria)

---

## Enterprise Attestation

Enterprise attestation (`attestation: 'enterprise'`) allows organizations to uniquely identify
authenticator models and individual devices during credential registration. Unlike `'none'` or
`'direct'`, enterprise attestation may include device serial numbers, AAGUIDs, and manufacturer
certificates that tie a credential to a specific hardware device.

### When to Use

- **Regulated industries** requiring hardware-backed credential proof (finance, healthcare, government).
- **Device compliance enforcement** — only organization-issued security keys are permitted.
- **Audit trails** — track which specific authenticator created each credential.
- **Zero-trust architectures** where authenticator identity is part of the trust decision.

### Implementation

```typescript
const options = await generateRegistrationOptions({
  rpName: 'Enterprise Corp',
  rpID: 'enterprise.example.com',
  userName: user.email,
  userID: isoUint8Array.fromUTF8String(user.id),
  attestationType: 'enterprise',
  authenticatorSelection: {
    residentKey: 'required',
    userVerification: 'required',
    authenticatorAttachment: 'cross-platform', // hardware keys
  },
});
```

### Validating Enterprise Attestation

1. Parse the `attestationObject` from the registration response.
2. Extract the attestation statement (`attStmt`) and format (`fmt`).
3. For `packed` format: verify the x5c certificate chain against your trusted enterprise CA.
4. Extract the AAGUID from authenticator data — cross-reference against FIDO MDS3 or your allowlist.
5. Store the attestation certificate fingerprint for device tracking.

### Privacy Considerations

Enterprise attestation exposes device-identifying information. Only request it in managed
environments where users consent to device tracking. Browsers may gate enterprise attestation
behind enterprise policy (Chrome requires the `SecurityKeyPermitAttestation` policy for
specific RP IDs).

---

## Cross-Device Flows (caBLE/Hybrid)

The hybrid transport (formerly caBLE v2 — cloud-assisted BLE) enables authentication on one
device using a passkey stored on another. Common scenario: signing in on a desktop by scanning
a QR code with a phone.

### Protocol Flow

1. **Desktop browser** generates a QR code containing a one-time pairing key and tunnel server URL.
2. **Phone** scans QR code, extracts tunnel parameters.
3. **Phone** establishes encrypted tunnel to desktop via cloud relay (not direct BLE in most cases).
4. **Phone** performs WebAuthn ceremony locally (biometric/PIN), sends signed assertion through tunnel.
5. **Desktop** receives assertion, forwards to RP server for verification.
6. After first pairing, subsequent connections use BLE advertisements (no QR needed).

### Server Configuration

No special server-side changes are needed — hybrid is a transport-layer concern. However:

```typescript
// Include 'hybrid' in stored transports during registration
const storedTransports = registrationResponse.response.getTransports();
// Typically returns: ['internal', 'hybrid']

// Replay transports in authentication options
allowCredentials: [{
  id: credentialId,
  type: 'public-key',
  transports: ['hybrid', 'internal'], // both must be listed
}]
```

### Fallback URL Extension (Draft)

The W3C is developing a fallback URL extension for hybrid transport. When no matching passkey is
found on the phone, the browser can redirect to a fallback URL instead of failing silently:

```typescript
extensions: {
  fallbackUrl: 'https://example.com/auth/alternative'
}
```

### Troubleshooting Hybrid Flows

- Requires Bluetooth enabled on both devices.
- Both devices must have internet connectivity for the cloud relay.
- iOS requires Safari; Chrome on iOS cannot initiate hybrid flows.
- First-time pairing requires QR scan; subsequent connections happen via BLE proximity.

---

## Conditional UI Deep Dive

Conditional UI integrates passkey authentication into the browser's autofill mechanism —
no modal dialogs or separate buttons needed.

### Requirements

1. Input field with `autocomplete="username webauthn"` (webauthn token must come last).
2. Call `navigator.credentials.get()` with `mediation: 'conditional'` **before** user interaction.
3. Credentials must be discoverable (registered with `residentKey: 'required'`).
4. Page must be served over HTTPS (or localhost).

### Lifecycle Management

```typescript
class ConditionalUIManager {
  private abortController: AbortController | null = null;

  async start(): Promise<void> {
    if (!await PublicKeyCredential.isConditionalMediationAvailable?.()) return;

    this.abortController = new AbortController();
    const options = await fetch('/api/auth/options').then(r => r.json());

    try {
      const assertion = await navigator.credentials.get({
        publicKey: {
          challenge: base64urlToBuffer(options.challenge),
          rpId: options.rpId,
          userVerification: 'preferred',
          timeout: 300000,
        },
        mediation: 'conditional',
        signal: this.abortController.signal,
      });
      await this.verifyAssertion(assertion);
    } catch (e) {
      if (e.name !== 'AbortError') console.error('Conditional UI failed:', e);
    }
  }

  abort(): void {
    this.abortController?.abort();
    this.abortController = null;
  }
}
```

### Key Behaviors

- **Abort before modal**: Always abort conditional UI before starting a modal WebAuthn ceremony
  (e.g., if user clicks "Sign in with security key").
- **Page navigation**: Conditional UI is automatically aborted on navigation.
- **Multiple inputs**: Only one conditional `get()` call can be active per page.
- **Empty state**: If no passkeys exist for the RP, the autofill dropdown simply won't show
  WebAuthn entries — no error is thrown.

---

## Credential Backup State Handling

WebAuthn Level 2+ exposes two flags in the authenticator data that indicate backup eligibility
and backup state of a credential.

### Flags

| Flag | Bit | Meaning |
|------|-----|---------|
| `BE` (Backup Eligible) | bit 3 | Credential **can** be backed up (multi-device capable) |
| `BS` (Backup State) | bit 4 | Credential **is** currently backed up |

### Device Type Mapping

| BE | BS | `credentialDeviceType` | `credentialBackedUp` | Description |
|----|----|-----------------------|---------------------|-------------|
| 0  | 0  | `singleDevice`        | `false`             | Hardware security key, device-bound |
| 1  | 0  | `multiDevice`         | `false`             | Eligible for sync but not yet synced |
| 1  | 1  | `multiDevice`         | `true`              | Synced passkey (iCloud, Google, etc.) |
| 0  | 1  | *(invalid)*           | *(invalid)*         | Should never occur — reject |

### Policy Enforcement

```typescript
function enforceCredentialPolicy(
  deviceType: string,
  backedUp: boolean,
  requiredLevel: 'any' | 'hardware-bound' | 'synced'
): boolean {
  switch (requiredLevel) {
    case 'hardware-bound':
      return deviceType === 'singleDevice';
    case 'synced':
      return deviceType === 'multiDevice' && backedUp;
    case 'any':
      return true;
  }
}
```

### Counter Handling by Device Type

- **singleDevice**: Strictly enforce counter increment. Counter regression indicates cloning.
- **multiDevice**: Counter may be 0 or non-incrementing. Do NOT reject counter=0 for synced
  passkeys. Some providers (Apple, Google) always report counter=0 for synced credentials.

---

## Multi-Device Credential Management

Users accumulate passkeys across devices and password managers. RPs must provide UX for managing them.

### Credential Inventory Endpoint

```typescript
// GET /api/user/credentials
interface CredentialListItem {
  id: string;              // base64url credential ID (truncated for display)
  friendlyName: string;    // "iPhone 15", "Chrome on MacBook"
  createdAt: string;
  lastUsedAt: string | null;
  deviceType: 'singleDevice' | 'multiDevice';
  backedUp: boolean;
  transports: AuthenticatorTransport[];
  aaguid: string;          // map to device name via MDS3
}
```

### Best Practices

1. **Always allow multiple credentials per account.** Users have multiple devices.
2. **Show last-used timestamp** to help users identify stale credentials.
3. **Map AAGUID to human-readable names** using FIDO MDS3 metadata.
4. **Warn before deleting the last credential** — user may lock themselves out.
5. **Require re-authentication** (step-up) before adding or deleting credentials.
6. **Label credentials automatically** using User-Agent and transport hints at registration time.

---

## Account Recovery Without Passwords

Fully passwordless accounts need robust recovery flows that don't fall back to passwords.

### Recovery Strategy Hierarchy

1. **Synced passkeys** — Primary defense. Cloud-backed credentials survive device loss automatically.
2. **Multiple registered authenticators** — Encourage users to register passkeys on ≥2 devices.
3. **Recovery codes** — One-time-use codes generated at registration. Store hashed server-side.
4. **Authenticated device transfer** — Use an existing authenticated session to register a new passkey.
5. **Identity verification** — Email/SMS magic link → temporary session → forced passkey registration.

### Implementation: Recovery Code Flow

```typescript
// At registration, generate recovery codes
function generateRecoveryCodes(count = 8): string[] {
  const codes: string[] = [];
  for (let i = 0; i < count; i++) {
    const buf = crypto.getRandomValues(new Uint8Array(5));
    codes.push(Array.from(buf, b => b.toString(16).padStart(2, '0')).join(''));
  }
  return codes; // Display to user once, store hashed
}

// Recovery endpoint
app.post('/api/auth/recover', async (req, res) => {
  const { email, recoveryCode } = req.body;
  const user = await findUserByEmail(email);
  const valid = await verifyRecoveryCode(user.id, recoveryCode);
  if (!valid) return res.status(401).json({ error: 'Invalid recovery code' });

  // Issue short-lived recovery session — user MUST register a new passkey
  const recoveryToken = await issueRecoverySession(user.id, { maxAge: 600 });
  res.json({ recoveryToken, mustRegisterPasskey: true });
});
```

### Anti-Patterns

- ❌ Allowing password as recovery fallback (defeats passwordless security model).
- ❌ SMS-only recovery (SIM swap vulnerable).
- ❌ Allowing passkey registration from an unauthenticated state.
- ❌ Recovery links that don't expire or are reusable.

---

## Step-Up Authentication

Step-up authentication requires a stronger authentication ceremony for sensitive operations
(e.g., changing email, financial transactions, admin actions).

### Implementation Pattern

```typescript
app.post('/api/account/change-email', requireAuth, async (req, res) => {
  const lastAuthAt = req.session.lastStepUpAuth;
  const stepUpMaxAge = 300_000; // 5 minutes

  if (!lastAuthAt || Date.now() - lastAuthAt > stepUpMaxAge) {
    return res.status(403).json({
      error: 'step_up_required',
      challenge: await generateAuthenticationOptions({
        rpID: 'example.com',
        userVerification: 'required', // enforce biometric/PIN
        allowCredentials: await getUserCredentials(req.user.id),
      }),
    });
  }

  // Proceed with email change
  await updateEmail(req.user.id, req.body.newEmail);
});
```

### Key Design Decisions

- **Require `userVerification: 'required'`** for step-up — don't accept presence-only.
- **Time-box step-up sessions** — typically 5-15 minutes.
- **Consider authenticator type** — for highest assurance, require device-bound credentials.
- **Log step-up events** separately for audit trails.

---

## Combining Passkeys with Other MFA

Passkeys alone satisfy multi-factor authentication (something you have + something you are/know).
However, some compliance frameworks or high-security scenarios require additional factors.

### Passkey + Additional Factor Patterns

| Combination | Use Case | Implementation |
|-------------|----------|----------------|
| Passkey + PIN/password | Legacy compliance requiring "knowledge factor" | Prompt for PIN after passkey assertion |
| Passkey + TOTP | Defense-in-depth for admin accounts | Require TOTP code after passkey auth |
| Passkey + Push notification | Out-of-band confirmation | Send push after passkey, require approval |
| Passkey + Hardware token | AAL3 scenarios | Require device-bound passkey from specific authenticator |

### Important Consideration

Adding factors on top of passkeys introduces friction and may reduce adoption. Evaluate whether
the additional factor genuinely improves security or is merely compliance theater. Passkeys with
`userVerification: 'required'` already provide two factors (possession + biometric/PIN).

---

## FIDO Metadata Service (MDS3)

The FIDO Metadata Service provides a global registry of certified authenticator metadata.
RPs can query MDS3 to validate authenticator models, check certification levels, and detect
revoked or compromised devices.

### Integration

```typescript
import { MetadataService } from '@simplewebauthn/server';

// Initialize MDS (fetch and cache the metadata BLOB)
await MetadataService.initialize({
  verificationMode: 'permissive', // or 'strict' for enterprise
});

// During registration verification, look up the authenticator
const statement = await MetadataService.getStatement(aaguid);
if (statement) {
  console.log('Authenticator:', statement.description);
  console.log('Certification Level:', statement.protocolFamily);
  console.log('Status:', statement.statusReports[0]?.status);

  // Check for revocation
  const isRevoked = statement.statusReports.some(
    r => r.status === 'REVOKED' || r.status === 'USER_VERIFICATION_BYPASS'
  );
  if (isRevoked) throw new Error('Authenticator is revoked');
}
```

### BLOB Refresh Strategy

- Download the signed BLOB from `https://mds3.fidoalliance.org/` periodically (daily or weekly).
- Verify the BLOB JWT signature against the FIDO Alliance root certificate.
- Cache locally — avoid fetching on every registration.
- Monitor `statusReports` for `ATTESTATION_KEY_COMPROMISE` and `REVOKED` statuses.

---

## Authenticator Selection Criteria

When to constrain which authenticators users can register.

### Policy Matrix

| Requirement | `authenticatorAttachment` | `residentKey` | `userVerification` | Attestation | MDS Check |
|------------|--------------------------|---------------|-------------------|-------------|-----------|
| Consumer passkeys | omit (any) | `required` | `preferred` | `none` | No |
| Enterprise security keys | `cross-platform` | `preferred` | `required` | `direct` | AAGUID allowlist |
| High-assurance (AAL3) | `cross-platform` | `required` | `required` | `enterprise` | FIDO L2+ cert |
| Passwordless consumer | `platform` | `required` | `preferred` | `none` | No |

### AAGUID Allowlisting

```typescript
const ALLOWED_AAGUIDS = new Set([
  'd8522d9f-575b-4866-88a9-ba99fa02f35b', // YubiKey 5
  'ee882879-721c-4913-9775-3dfcce97072a', // YubiKey 5 FIPS
  '2fc0579f-8113-47ea-b116-bb5a8db9202a', // YubiKey Bio
]);

function validateAuthenticator(aaguid: string): boolean {
  return ALLOWED_AAGUIDS.has(aaguid);
}
```

For consumer-facing apps, avoid AAGUID restrictions — they reduce compatibility and frustrate users.
Reserve allowlisting for regulated enterprise environments.
