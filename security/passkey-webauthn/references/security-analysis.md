# WebAuthn Security Analysis

## Table of Contents

- [Threat Model Overview](#threat-model-overview)
- [Phishing Resistance Proof](#phishing-resistance-proof)
- [Relay and Adversary-in-the-Middle Attacks](#relay-and-adversary-in-the-middle-attacks)
- [Token Binding](#token-binding)
- [Attestation Trust Chain](#attestation-trust-chain)
- [Credential Cloning Risks](#credential-cloning-risks)
- [User Verification Bypass Scenarios](#user-verification-bypass-scenarios)
- [Comparison with TOTP/SMS/Push MFA](#comparison-with-totpsmspush-mfa)
- [NIST 800-63B AAL Levels](#nist-800-63b-aal-levels)
- [Compliance Considerations](#compliance-considerations)

---

## Threat Model Overview

WebAuthn is designed to resist the following threat classes:

| Threat | Protection Mechanism | Residual Risk |
|--------|---------------------|---------------|
| Phishing | Origin-bound credentials | None for credential theft; social engineering persists |
| Credential theft (server breach) | Public keys only stored server-side | Attacker gets public keys — useless without private key |
| Credential theft (client) | Private keys in hardware secure element | Physical extraction attacks (expensive, targeted) |
| Replay attacks | Single-use challenges + signature counters | Counter=0 for synced passkeys weakens replay detection |
| Man-in-the-middle | TLS + origin binding in clientDataJSON | Compromised TLS CA could enable MITM (unlikely) |
| Authenticator cloning | Signature counter monitoring | Synced passkeys intentionally "clone" — counter not reliable |
| Account takeover | Multi-factor (possession + biometric/PIN) | Device theft + biometric bypass (very difficult) |

### Trust Boundaries

```
┌─────────────────────────────────────────────────────────┐
│ Authenticator (Secure Element / TEE)                     │
│  • Private key storage                                   │
│  • Signature generation                                  │
│  • User verification (biometric/PIN)                     │
│  • Counter management                                    │
│  TRUST: Highest — hardware-protected, tamper-resistant   │
├─────────────────────────────────────────────────────────┤
│ Client (Browser / OS)                                    │
│  • WebAuthn API mediation                                │
│  • Origin enforcement                                    │
│  • TLS termination                                       │
│  TRUST: Medium — relies on browser correctness           │
├─────────────────────────────────────────────────────────┤
│ Relying Party (Server)                                   │
│  • Challenge generation                                  │
│  • Signature verification                                │
│  • Public key storage                                    │
│  • Session management                                    │
│  TRUST: Medium — must implement verification correctly   │
├─────────────────────────────────────────────────────────┤
│ Network                                                  │
│  TRUST: None — assumed hostile, protected by TLS         │
└─────────────────────────────────────────────────────────┘
```

---

## Phishing Resistance Proof

WebAuthn provides **cryptographic** phishing resistance, not just user-behavioral.

### How It Works

1. During registration, the authenticator binds the credential to the **RP ID** (domain).
   The private key is associated with a specific rpId hash.

2. During authentication, the authenticator:
   a. Receives the rpId from the browser (which enforces origin policy).
   b. Computes SHA-256(rpId) and matches against stored credential metadata.
   c. **Refuses to sign** if the rpId doesn't match any stored credential.

3. The browser includes the **full page origin** in `clientDataJSON`, which is signed by
   the authenticator. The server verifies this matches the expected origin.

### Why Phishing Fails

```
Legitimate site: https://bank.example.com (rpId: bank.example.com)
Phishing site:   https://bank-example.com (rpId: bank-example.com)

1. Attacker sets up phishing page at bank-example.com
2. User visits phishing page, passkey autofill activates
3. Browser sends rpId "bank-example.com" to authenticator
4. Authenticator has NO credential for rpId "bank-example.com"
5. Authentication fails — no credential to sign with
6. Even if attacker proxies the challenge from the real site,
   the authenticator still won't sign for the wrong rpId
```

### What Phishing Resistance Does NOT Prevent

- **Post-authentication session hijacking**: If the user authenticates on the real site and an
  attacker steals the session token afterward (e.g., via XSS), WebAuthn cannot prevent this.
- **Social engineering**: Attacker convinces user to perform actions on the legitimate site.
- **Real-time phishing proxies**: An attacker cannot steal the credential, but they could
  potentially ride an active session if they MITM the entire TLS connection (requires
  compromised CA or user ignoring certificate warnings).

---

## Relay and Adversary-in-the-Middle Attacks

### Traditional AiTM Against Passwords/OTP

```
User → [Phishing Proxy] → Real Server
     ← [Phishing Proxy] ←
     
1. Proxy forwards login page to user
2. User enters password + OTP on proxy
3. Proxy relays credentials to real server in real-time
4. Proxy captures session token
5. Attacker has authenticated session
```

This attack works against passwords, TOTP, SMS codes, and push notifications.

### Why AiTM Fails Against WebAuthn

```
User → [Phishing Proxy at evil.com] → Real Server (bank.com)

1. Proxy forwards WebAuthn challenge from bank.com
2. User's browser sends rpId "evil.com" to authenticator (browser enforces real origin)
3. Authenticator has no credential for "evil.com" → FAILS
4. Even if proxy claims rpId is "bank.com", the BROWSER overrides with actual origin
5. The browser is the trust anchor — it will NOT lie about the origin
```

### Edge Case: Compromised Browser

If the browser itself is compromised (malware, modified browser binary), the origin
enforcement breaks down. This is out of scope for WebAuthn's threat model — a compromised
browser can steal any credential type, not just WebAuthn.

### Evilginx and Similar Tools

Tools like Evilginx can perform real-time phishing against TOTP/SMS/push. Against WebAuthn:
- Evilginx cannot relay WebAuthn ceremonies because the authenticator binds to the proxy's
  origin, not the real server's origin.
- The resulting signature is invalid for the real server.
- This is the key advantage: **phishing resistance is cryptographic, not behavioral**.

---

## Token Binding

Token Binding (RFC 8471) ties authentication tokens to the TLS connection, preventing token
export and replay.

### WebAuthn and Token Binding

`clientDataJSON` includes an optional `tokenBinding` field:

```json
{
  "type": "webauthn.get",
  "challenge": "...",
  "origin": "https://example.com",
  "tokenBinding": {
    "status": "present",
    "id": "<base64url-encoded-token-binding-id>"
  }
}
```

### Current State

Token Binding has been **deprecated in Chromium** (removed in Chrome 120) and is not supported
in Safari or Firefox. The WebAuthn spec still references it but practical implementations
should not rely on it.

### Alternative: Session Binding

Instead of Token Binding, bind sessions to the client using:

1. **DPoP (Demonstrating Proof-of-Possession)**: Bind access tokens to a client-generated
   key pair (RFC 9449).
2. **Device-bound session cookies**: Use secure, HttpOnly, SameSite=Strict cookies with
   short lifetimes.
3. **Mutual TLS (mTLS)**: Client certificates bound to the TLS connection.

---

## Attestation Trust Chain

Attestation lets the RP verify the make and model of the authenticator at registration time.

### Trust Chain Structure

```
FIDO Alliance Root CA
    │
    ├── Authenticator Manufacturer CA (e.g., Yubico)
    │       │
    │       ├── Batch Attestation Certificate (shared across device batch)
    │       │       │
    │       │       └── Device creates credential, signs with batch key
    │       │
    │       └── Individual Attestation Certificate (enterprise)
    │               │
    │               └── Device creates credential, signs with unique key
    │
    └── Another Manufacturer CA
```

### Attestation Formats

| Format | Description | Verification Method |
|--------|-------------|-------------------|
| `packed` | Most common. Self-attestation or x5c certificate chain. | Verify x5c chain to trusted root |
| `tpm` | TPM-based attestation (Windows Hello). | Verify TPM certificate, AIK, certInfo |
| `android-key` | Android hardware-backed keystore. | Verify certificate chain to Google root |
| `android-safetynet` | Deprecated. Used SafetyNet API. | Do not use — replaced by android-key |
| `fido-u2f` | Legacy U2F authenticators. | Verify the single attestation certificate |
| `apple` | Apple Anonymous Attestation. | Verify nonce and Apple certificate chain |
| `none` | No attestation provided. | Nothing to verify — trust the credential |

### Verification Process

```typescript
// Pseudocode for packed attestation verification
function verifyPackedAttestation(attStmt, authData, clientDataHash) {
  const { sig, x5c, alg } = attStmt;
  
  if (x5c) {
    // Full attestation: verify certificate chain
    const attestCert = x5c[0];
    const chain = x5c.slice(1);
    
    // 1. Verify certificate chain to a trusted root
    verifyCertificateChain(attestCert, chain, TRUSTED_ROOTS);
    
    // 2. Verify the signature over authData || clientDataHash
    const signedData = Buffer.concat([authData, clientDataHash]);
    verifySignature(attestCert.publicKey, sig, signedData, alg);
    
    // 3. Extract AAGUID and check against MDS3 for device info
    const aaguid = extractAAGUID(authData);
    const metadata = await MDS3.lookup(aaguid);
    
    // 4. Check for revocation or compromise status
    if (metadata?.statusReports?.some(r => r.status === 'REVOKED')) {
      throw new Error('Authenticator revoked');
    }
  } else {
    // Self-attestation: verify sig with credential public key
    const credentialPublicKey = extractPublicKey(authData);
    const signedData = Buffer.concat([authData, clientDataHash]);
    verifySignature(credentialPublicKey, sig, signedData, alg);
  }
}
```

---

## Credential Cloning Risks

### Device-Bound Credentials (singleDevice)

Physical security keys store private keys in a secure element that is designed to resist
extraction. Cloning requires:
- Physical access to the authenticator.
- Side-channel attacks or fault injection against the secure element.
- Cost: $10,000+ per key in a lab environment.

**Signature counter** is the primary defense. If two devices use the same credential, the
counter will diverge:

```typescript
function detectCloning(storedCounter: number, assertionCounter: number, deviceType: string): void {
  if (deviceType === 'singleDevice' && assertionCounter <= storedCounter) {
    // Counter went backward or didn't increment — possible clone
    // Action: flag the credential, alert the user, require re-registration
    throw new Error('Possible credential cloning detected');
  }
}
```

### Synced Credentials (multiDevice)

Synced passkeys are intentionally replicated across devices via cloud sync (iCloud Keychain,
Google Password Manager, 1Password, etc.). This is a feature, not a vulnerability, but it
changes the security model:

- **Counter is unreliable**: Many sync providers set counter to 0 for all operations.
- **"Something you have" weakens**: The credential exists on all synced devices.
- **Cloud account compromise**: If an attacker compromises the user's iCloud/Google account,
  they may access synced passkeys.

### Risk Mitigation

| Risk | Mitigation |
|------|-----------|
| Cloud account compromise | Require cloud account 2FA; monitor for suspicious sync |
| Lost/stolen device | Remote wipe via cloud provider; revoke specific credentials |
| Counter manipulation | For singleDevice: enforce strictly. For multiDevice: ignore counter |
| Unauthorized sync | Enterprise: use device-bound credentials; disable cloud sync via MDM |

---

## User Verification Bypass Scenarios

### Scenario 1: Downgrade Attack

RP requests `userVerification: 'preferred'` but authenticator performs UV and the RP doesn't
check the UV flag in the response.

**Impact**: Authenticator may skip UV (touch-only), and RP unknowingly accepts low-assurance
authentication.

**Fix**: Always check the UV flag when your policy requires it:

```typescript
const { flags } = verification.authenticationInfo;
if (securityPolicy.requiresUV && !flags.uv) {
  throw new Error('User verification required but not performed');
}
```

### Scenario 2: Authenticator Without UV Capability

An authenticator that cannot perform UV (old U2F keys without PIN) is used with
`userVerification: 'preferred'`. The browser falls back to UP-only.

**Fix**: Use `userVerification: 'required'` for sensitive operations. This causes the ceremony
to fail if the authenticator cannot perform UV, rather than silently downgrading.

### Scenario 3: Biometric Bypass

Physical attacks against biometric sensors (e.g., fingerprint molds, photo-based face unlock).
Modern authenticators use liveness detection and secure enclaves, making this difficult but
not impossible.

**Fix**: Combine with additional factors for highest-value operations. Monitor for anomalous
authentication patterns.

### Scenario 4: PIN Brute Force

Authenticators with PIN-based UV have retry limits (typically 8 attempts before lockout for
FIDO2 PINs). However:
- Some authenticators allow unlimited attempts before firmware updates.
- PIN complexity requirements vary by authenticator vendor.

---

## Comparison with TOTP/SMS/Push MFA

| Property | WebAuthn/Passkeys | TOTP (Authenticator App) | SMS OTP | Push Notification |
|----------|------------------|--------------------------|---------|-------------------|
| **Phishing resistant** | ✅ Cryptographic | ❌ Code can be phished | ❌ Code can be phished | ⚠️ Push fatigue attacks |
| **Relay resistant** | ✅ Origin-bound | ❌ Real-time relay | ❌ Real-time relay | ⚠️ Approve on wrong prompt |
| **Replay resistant** | ✅ Challenge + counter | ✅ Time-window limited | ✅ Single-use | ✅ Single-use |
| **Server breach impact** | 🟢 Public keys only | 🔴 TOTP secrets exposed | 🟡 Phone numbers exposed | 🟡 Push tokens exposed |
| **User experience** | ✅ Single gesture | ⚠️ Open app, copy code | ⚠️ Wait for SMS, copy code | ✅ Single tap |
| **Offline capable** | ✅ Yes | ✅ Yes | ❌ Needs cell service | ❌ Needs internet |
| **Account recovery** | ⚠️ Requires planning | ✅ Backup codes | ✅ Phone number | ⚠️ Device-bound |
| **Deployment cost** | 🟡 Integration effort | 🟢 Simple to add | 🔴 Per-SMS cost | 🟡 Push infrastructure |

### Key Differentiator: Server Breach Resilience

If an attacker breaches the RP server:
- **Passwords**: Attacker gets hashed passwords. Offline cracking possible.
- **TOTP**: Attacker gets TOTP secrets. Can generate valid codes immediately.
- **WebAuthn**: Attacker gets public keys. **Completely useless** — cannot derive private keys.

This is WebAuthn's strongest security property beyond phishing resistance.

---

## NIST 800-63B AAL Levels

NIST SP 800-63B defines Authentication Assurance Levels that map to WebAuthn configurations.

### AAL1 — Single Factor

- Any single authentication factor.
- WebAuthn with `userVerification: 'discouraged'` (UP only) meets AAL1.
- Not recommended — provides minimal assurance.

### AAL2 — Multi-Factor

- Two distinct authentication factors required.
- WebAuthn with `userVerification: 'required'` meets AAL2 with a single ceremony because it
  combines possession (private key) + inherence (biometric) or knowledge (PIN).
- TOTP meets AAL2 when combined with a password.
- SMS OTP: NIST considers SMS a "restricted" authenticator at AAL2 due to SIM swap risks.

### AAL3 — Hardware-Backed Multi-Factor

- Requires a hardware-based authenticator with verifier impersonation resistance.
- WebAuthn with a **hardware security key** (device-bound credential, direct/enterprise attestation
  verifying hardware) meets AAL3.
- **Synced passkeys generally do NOT meet AAL3** — private key material leaves the hardware
  secure element for cloud sync.
- Device-bound platform authenticators (Windows Hello with TPM, Android StrongBox) may qualify
  for AAL3 with appropriate attestation.

### Mapping WebAuthn to AAL

| AAL | WebAuthn Configuration | Attestation | Key Type |
|-----|----------------------|-------------|----------|
| AAL1 | UV: discouraged | none | Any |
| AAL2 | UV: required | none | Any (synced or device-bound) |
| AAL3 | UV: required | direct/enterprise | Device-bound only (singleDevice) |

---

## Compliance Considerations

### PCI DSS 4.0

- Requires MFA for administrative access to cardholder data environments.
- WebAuthn with `userVerification: 'required'` satisfies MFA requirements.
- Passkeys are explicitly recognized as phishing-resistant MFA.

### HIPAA

- Requires "unique user identification" and "authentication" safeguards.
- WebAuthn meets these requirements. Consider device-bound credentials for covered entities
  handling PHI.

### SOC 2

- Trust Service Criteria CC6.1 requires logical access controls.
- WebAuthn provides strong authentication. Document your authenticator policy in your
  security program.

### GDPR Considerations

- Biometric data (fingerprint, face) processed by the authenticator locally. The biometric
  template **never leaves the device** — the RP receives only a boolean UV flag.
- No biometric data is transmitted or stored server-side.
- Enterprise attestation may transmit device identifiers — ensure this is covered in your
  privacy policy and data processing agreements.

### Federal Government (US)

- Executive Order 14028 and OMB M-22-09 mandate phishing-resistant MFA for federal agencies.
- FIDO2/WebAuthn with hardware authenticators is the recommended implementation.
- CISA strongly recommends migration from SMS/TOTP to phishing-resistant methods.

### Financial Services

- FFIEC guidance recommends risk-based MFA.
- WebAuthn with enterprise attestation and device-bound credentials provides the strongest
  posture for high-value financial transactions.
- Consider step-up authentication with `userVerification: 'required'` for wire transfers
  and account changes.

### Recommendation Summary

For most applications: Use passkeys (synced, AAL2) for primary authentication. Reserve
device-bound credentials (AAL3) for admin access, financial operations, and regulated
environments. Always plan recovery flows that don't fall back to phishable methods.
