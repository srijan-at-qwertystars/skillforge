# WebAuthn Troubleshooting Guide

## Table of Contents

- [Origin Mismatch Errors](#origin-mismatch-errors)
- [rpId Problems](#rpid-problems)
- [Challenge Encoding Issues](#challenge-encoding-issues)
- [Timeout Handling](#timeout-handling)
- [Credential Not Found](#credential-not-found)
- [Browser Compatibility Quirks](#browser-compatibility-quirks)
- [iOS-Specific Issues](#ios-specific-issues)
- [Android-Specific Issues](#android-specific-issues)
- [Localhost Development Setup](#localhost-development-setup)
- [Debug Tools and Techniques](#debug-tools-and-techniques)
- [Error Code Reference](#error-code-reference)

---

## Origin Mismatch Errors

The origin in `clientDataJSON` must exactly match the expected origin on the server.

### Common Causes

1. **Scheme mismatch**: Server expects `https://example.com` but client sends `http://example.com`.
2. **Port mismatch**: `https://example.com` ≠ `https://example.com:8443`. Default ports (443, 80)
   are omitted from the origin string.
3. **Subdomain mismatch**: `https://www.example.com` ≠ `https://example.com`. These are
   different origins.
4. **Trailing slash**: Origins never include a trailing slash. `https://example.com/` is wrong.
5. **Reverse proxy issues**: Load balancer strips HTTPS; app sees `http://` internally.

### Diagnosis

```typescript
// Decode clientDataJSON to inspect the origin the browser sent
const clientData = JSON.parse(
  Buffer.from(response.clientDataJSON, 'base64url').toString('utf8')
);
console.log('Client origin:', clientData.origin);
console.log('Expected origin:', expectedOrigin);
// Compare character-by-character if they look identical
```

### Fixes

```typescript
// For reverse proxy setups, trust the X-Forwarded-Proto header
const origin = req.headers['x-forwarded-proto'] === 'https'
  ? `https://${req.headers.host}`
  : `${req.protocol}://${req.headers.host}`;

// SimpleWebAuthn accepts an array of origins
const verification = await verifyRegistrationResponse({
  response: attResp,
  expectedOrigin: ['https://example.com', 'https://www.example.com'],
  expectedRPID: 'example.com',
  expectedChallenge: storedChallenge,
});
```

### Native App Origins

- **Android**: Origin format is `android:apk-key-hash:<sha256-hash>`. Configure via
  `assetlinks.json` at `https://example.com/.well-known/assetlinks.json`.
- **iOS**: Origin uses the web origin if using ASWebAuthenticationSession. For native passkeys,
  configure `apple-app-site-association` at `https://example.com/.well-known/apple-app-site-association`.
  Apple caches this file for up to 24 hours.

---

## rpId Problems

The RP ID must be a registrable domain (or subdomain) matching the page origin.

### Rules

- rpId must be equal to or a registrable suffix of the page's effective domain.
- `login.example.com` can use rpId `example.com` (parent domain) ✅
- `login.example.com` can use rpId `login.example.com` (exact match) ✅
- `example.com` cannot use rpId `login.example.com` (child domain) ❌
- rpId cannot be an IP address ❌
- rpId cannot be a public suffix (`com`, `co.uk`, `github.io`) ❌

### Hash Verification

The authenticator data contains the SHA-256 hash of the rpId. Verify manually:

```bash
# Compute expected rpId hash
echo -n "example.com" | openssl dgst -sha256 -binary | base64
# Compare with first 32 bytes of authenticatorData
```

### Changing rpId

**You cannot change the rpId after credentials are created.** All existing credentials become
invalid. If you must change domains:

1. Register new credentials on the new rpId while both domains are active.
2. Migrate users gradually with re-registration flows.
3. Keep the old domain serving WebAuthn for a transition period.

### Related Origins (WebAuthn Level 3 Draft)

The W3C is developing a "related origins" proposal allowing an rpId to be used across related
domains via a `.well-known/webauthn` file:

```json
// https://example.com/.well-known/webauthn
{
  "origins": [
    "https://login.example.com",
    "https://app.example.com"
  ]
}
```

This is not yet widely supported — check browser compatibility before relying on it.

---

## Challenge Encoding Issues

Challenges must be cryptographically random, properly encoded, and single-use.

### Common Encoding Bugs

1. **Base64 vs Base64URL**: WebAuthn spec uses base64url (no padding, URL-safe characters).
   Standard base64 uses `+/=` which will cause mismatches.

```typescript
// WRONG: standard base64
const challenge = Buffer.from(randomBytes).toString('base64');

// RIGHT: base64url
const challenge = Buffer.from(randomBytes).toString('base64url');
// or with @simplewebauthn: challenge encoding is handled automatically
```

2. **Double encoding**: Encoding the challenge twice (once on server, once by the library).
3. **String comparison vs byte comparison**: Always compare the decoded bytes, not the encoded
   strings. Different base64url implementations may differ in padding.

### Minimum Requirements

- At least 16 bytes of cryptographic randomness (128 bits).
- Single-use: delete or invalidate after verification attempt (success or failure).
- Time-bound: expire challenges after 5 minutes maximum.
- Store server-side (session or cache), never in client-accessible storage.

### Debugging Challenge Mismatches

```typescript
// Log both sides for comparison
console.log('Stored challenge (hex):', Buffer.from(storedChallenge, 'base64url').toString('hex'));

const clientData = JSON.parse(
  Buffer.from(response.clientDataJSON, 'base64url').toString()
);
console.log('Client challenge (hex):', Buffer.from(clientData.challenge, 'base64url').toString('hex'));
```

---

## Timeout Handling

WebAuthn ceremonies can time out if the user takes too long to interact with the authenticator.

### Default Timeouts

| Ceremony | Recommended Timeout | Rationale |
|----------|-------------------|-----------|
| Registration | 300,000ms (5 min) | Users need time for biometric setup, PIN creation |
| Authentication | 300,000ms (5 min) | Cross-device flows require QR scan + phone unlock |
| Conditional UI | 300,000ms (5 min) | User may not interact immediately |

### Handling Timeout Errors

```typescript
try {
  const credential = await navigator.credentials.create({ publicKey: options });
} catch (e) {
  if (e.name === 'NotAllowedError') {
    // User cancelled OR timeout. The browser does not distinguish these.
    // Show a retry option, not an error message.
    showRetryPrompt();
  }
}
```

### Server-Side Challenge Expiry

```typescript
// Use a TTL cache for challenges
const challengeStore = new Map<string, { challenge: string; expiresAt: number }>();

function storeChallenge(sessionId: string, challenge: string): void {
  challengeStore.set(sessionId, {
    challenge,
    expiresAt: Date.now() + 5 * 60 * 1000,
  });
}

function getAndDeleteChallenge(sessionId: string): string | null {
  const entry = challengeStore.get(sessionId);
  challengeStore.delete(sessionId);
  if (!entry || Date.now() > entry.expiresAt) return null;
  return entry.challenge;
}
```

---

## Credential Not Found

Authentication fails because the authenticator cannot find a matching credential.

### Diagnosis Checklist

1. **Wrong rpId**: Credential was registered with a different rpId than the one in the
   authentication request.
2. **Non-discoverable credential without allowCredentials**: If the credential is not discoverable
   (resident), you must provide its ID in `allowCredentials`.
3. **Deleted passkey**: User may have deleted the passkey from their device/password manager.
4. **Different device**: Credential exists on another device. Check if hybrid transport is offered.
5. **Browser profile**: Credentials are tied to the browser profile (Chrome profiles, Firefox
   containers).

### Graceful Fallback

```typescript
try {
  const assertion = await navigator.credentials.get({ publicKey: options });
  await verifyOnServer(assertion);
} catch (e) {
  if (e.name === 'NotAllowedError') {
    // Show alternative authentication methods
    showAlternativeAuth(['password', 'magic-link', 'recovery-code']);
  }
}
```

### Server-Side: Credential Lookup Failures

```typescript
// After receiving an assertion, look up the credential
const credential = await db.findCredentialById(assertionResponse.id);
if (!credential) {
  // Credential ID not in database — possible causes:
  // 1. User deleted their account
  // 2. Credential was registered on a different environment (staging vs prod)
  // 3. Database migration lost the credential
  logger.warn('Unknown credential ID', { credentialId: assertionResponse.id });
  return res.status(401).json({ error: 'credential_not_found' });
}
```

---

## Browser Compatibility Quirks

### Chrome

- Conditional UI supported since Chrome 108.
- Hybrid transport fully supported.
- `PublicKeyCredential.isConditionalMediationAvailable()` returns a promise (not all browsers do).
- Chrome on Android uses Google Password Manager for synced passkeys.

### Safari

- Conditional UI since Safari 16 (macOS Ventura, iOS 16).
- Passkeys are synced via iCloud Keychain — requires iCloud signed in and Keychain enabled.
- Safari may not fire `AbortError` when conditional UI is aborted in some versions.
- `autocomplete="username webauthn"` — the `webauthn` token must be last.
- Safari on iOS does NOT support WebAuthn in WKWebView — use ASWebAuthenticationSession.

### Firefox

- Conditional UI since Firefox 122.
- Hybrid/cross-device support is limited compared to Chrome and Safari.
- Firefox uses its own credential storage (not OS-level) on desktop.
- On Android, Firefox delegates to the OS credential manager (Android 14+).

### Edge

- Follows Chrome's behavior (Chromium-based) since Edge 108.
- Windows Hello integration for platform authenticator.
- Hybrid flows use the phone-as-authenticator via Chromium's caBLE implementation.

### Cross-Browser Testing Matrix

```typescript
// Feature detection — never user-agent sniff
const checks = {
  webauthnSupported: !!window.PublicKeyCredential,
  platformAuthAvailable: await PublicKeyCredential
    .isUserVerifyingPlatformAuthenticatorAvailable(),
  conditionalUIAvailable: await PublicKeyCredential
    .isConditionalMediationAvailable?.() ?? false,
};
```

---

## iOS-Specific Issues

### Common Problems

1. **WKWebView not supported**: WebAuthn only works in Safari and SFSafariViewController/
   ASWebAuthenticationSession. In-app browsers using WKWebView will silently fail.
2. **iCloud Keychain required**: Passkeys require iCloud Keychain enabled. Users with it
   disabled cannot create or use synced passkeys.
3. **apple-app-site-association caching**: Apple CDN caches this file. Changes take up to
   24 hours to propagate. Use `https://app-site-association.cdn-apple.com/a/v1/<domain>`
   to check the cached version.
4. **Simulator limitations**: iOS Simulator supports passkeys but with limitations. Test on
   real devices for production confidence.
5. **Focus loss**: If the app loses focus during a WebAuthn ceremony (e.g., user switches apps),
   the ceremony may fail silently.

### Associated Domains Setup

```json
// https://example.com/.well-known/apple-app-site-association
{
  "webcredentials": {
    "apps": ["ABCDE12345.com.example.myapp"]
  }
}
```

The file must be served with `Content-Type: application/json` and no redirects.

---

## Android-Specific Issues

### Common Problems

1. **Credential Manager API**: Android 14+ uses Credential Manager. Older versions use FIDO2 API.
   Behavior differs between the two.
2. **Origin format**: Native Android apps use `android:apk-key-hash:<sha256>` as the origin,
   not a web URL. The hash is the SHA-256 of the APK signing certificate.
3. **Asset Links**: Must configure `assetlinks.json` at
   `https://example.com/.well-known/assetlinks.json`:

```json
[{
  "relation": ["delegate_permission/common.handle_all_urls",
               "delegate_permission/common.get_login_creds"],
  "target": {
    "namespace": "android_app",
    "package_name": "com.example.myapp",
    "sha256_cert_fingerprints": ["AA:BB:CC:..."]
  }
}]
```

4. **Chrome Custom Tabs**: WebAuthn works in Chrome Custom Tabs but not in all WebView
   configurations.
5. **Google Password Manager sync**: Passkeys created in Chrome on Android sync via Google
   Password Manager. Users must have a Google account with sync enabled.

### Debug: Verifying Asset Links

```bash
# Check if Google has fetched and validated your asset links
curl -s "https://digitalassetlinks.googleapis.com/v1/statements:list?source.web.site=https://example.com&relation=delegate_permission/common.get_login_creds" | python3 -m json.tool
```

---

## Localhost Development Setup

WebAuthn requires a secure context. `localhost` is treated as secure by browsers.

### Quick Setup

```bash
# Option 1: Use localhost directly (simplest)
# Most browsers treat localhost as a secure context
# Start your dev server on http://localhost:8080
# Set rpId to 'localhost'

# Option 2: Use mkcert for proper HTTPS
brew install mkcert  # or: apt install mkcert
mkcert -install      # install local CA
mkcert localhost 127.0.0.1 ::1
# Creates localhost+2.pem and localhost+2-key.pem
```

### Development Configuration

```typescript
const isDev = process.env.NODE_ENV === 'development';

const rpID = isDev ? 'localhost' : 'example.com';
const origin = isDev ? 'http://localhost:3000' : 'https://example.com';
// Note: http://localhost works for WebAuthn (secure context exception)
// But https://localhost with mkcert is more realistic for testing
```

### Pitfalls

- `127.0.0.1` is NOT the same as `localhost` for WebAuthn. Use `localhost` as the rpId.
- Port numbers are part of the origin: `http://localhost:3000` ≠ `http://localhost:8080`.
- Credentials created on `localhost` cannot be used in production — always use separate rpIds.
- Some browsers restrict features on `http://localhost` that work on `https://` — use mkcert
  for full compatibility testing.
- ngrok/tunnels: The tunnel URL becomes the origin. rpId must match the tunnel hostname.

---

## Debug Tools and Techniques

### Browser DevTools

1. **Chrome**: `chrome://webauthn` — virtual authenticator for testing without hardware.
   - Enable in DevTools → More tools → WebAuthn
   - Create virtual authenticators (platform, cross-platform, with/without UV)
   - Inspect registered credentials, export private keys for debugging

2. **Application tab**: Check stored credentials in the WebAuthn section.

3. **Console logging**: Decode and inspect `clientDataJSON` and `authenticatorData`:

```javascript
// In browser console after a ceremony
function inspectWebAuthnResponse(response) {
  const clientData = JSON.parse(
    new TextDecoder().decode(response.response.clientDataJSON)
  );
  console.log('Type:', clientData.type);     // "webauthn.create" or "webauthn.get"
  console.log('Origin:', clientData.origin);
  console.log('Challenge:', clientData.challenge);

  // For authenticatorData, first 32 bytes are rpId hash
  const authData = new Uint8Array(response.response.authenticatorData || response.response.attestationObject);
  console.log('rpId hash:', Array.from(authData.slice(0, 32), b => b.toString(16).padStart(2, '0')).join(''));
}
```

### Server-Side Debugging

```typescript
// Wrap verification in detailed error logging
try {
  const verification = await verifyRegistrationResponse({ /* ... */ });
} catch (e) {
  console.error('Verification failed:', {
    error: e.message,
    expectedOrigin,
    expectedRPID,
    challengeLength: storedChallenge?.length,
    responseKeys: Object.keys(attResp.response),
  });
  throw e;
}
```

### Online Tools

- **webauthn.me**: Test WebAuthn flows in-browser, check feature support.
- **webauthn.io**: Interactive demo for registration and authentication.
- **passkeys.dev**: Comprehensive device support matrix and testing tools.
- **FIDO Conformance Tools**: Official test suite for FIDO2 server certification.

### Network Debugging

Use browser Network tab to verify:
- Registration/authentication options are fetched correctly.
- Challenge is present and properly encoded in the options.
- The verification response from the server includes detailed error messages.

---

## Error Code Reference

| Error Name | When It Occurs | Likely Cause |
|-----------|---------------|--------------|
| `NotAllowedError` | `create()` or `get()` | User denied, timeout, or no matching credential |
| `InvalidStateError` | `create()` | Credential already exists (excludeCredentials matched) |
| `NotSupportedError` | `create()` | None of the requested algorithms are supported |
| `SecurityError` | `create()` or `get()` | RP ID doesn't match origin, or not a secure context |
| `AbortError` | `create()` or `get()` | `AbortController.abort()` was called |
| `TypeError` | `create()` or `get()` | Malformed options (missing required fields) |
| `ConstraintError` | `create()` | Authenticator can't satisfy requirements (e.g., UV on key without PIN) |
| `UnknownError` | `create()` or `get()` | Internal authenticator or browser error |

### Error Handling Pattern

```typescript
async function handleWebAuthnError(error: Error, ceremony: 'registration' | 'authentication') {
  const messages: Record<string, string> = {
    NotAllowedError: 'Authentication was cancelled or timed out. Please try again.',
    InvalidStateError: 'This authenticator is already registered. Try signing in instead.',
    NotSupportedError: 'Your authenticator is not supported. Please try a different one.',
    SecurityError: 'Security error. Please ensure you are on the correct website.',
    AbortError: '', // Silent — intentional abort
    ConstraintError: 'Your authenticator cannot meet the security requirements.',
  };

  const message = messages[error.name] || 'An unexpected error occurred. Please try again.';
  if (message) showErrorToUser(message);

  // Always log the full error for debugging
  console.error(`WebAuthn ${ceremony} error:`, error.name, error.message);
}
```
