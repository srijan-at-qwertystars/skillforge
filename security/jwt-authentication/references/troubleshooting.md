# JWT Troubleshooting Guide

## Table of Contents

- [Token Rejected but "Looks Valid"](#token-rejected-but-looks-valid)
- [Debugging JWT in Development](#debugging-jwt-in-development)
- ["Invalid Signature" Causes](#invalid-signature-causes)
- [CORS Issues with Authorization Header](#cors-issues-with-authorization-header)
- [Cookie-Based JWT Not Being Sent](#cookie-based-jwt-not-being-sent)
- [Token Too Large for Headers](#token-too-large-for-headers)
- [Key Rotation Gone Wrong](#key-rotation-gone-wrong)
- [Library-Specific Pitfalls](#library-specific-pitfalls)
- [Mobile App Token Storage](#mobile-app-token-storage)
- [JWT with WebSocket Connections](#jwt-with-websocket-connections)

---

## Token Rejected but "Looks Valid"

You decode the token, the claims look correct, but the server returns 401. Common causes:

### Clock skew

The server clock and the issuing server's clock are out of sync. A token with `exp: 1735000000` is rejected if the validating server's clock is even 1 second ahead.

**Diagnosis:**

```bash
# Compare clocks between issuer and verifier
date -u +%s  # Run on both machines
# If difference > 30 seconds, you have clock skew

# Check NTP sync status
timedatectl status
# Look for: "System clock synchronized: yes"
```

**Fix:** Sync clocks with NTP. Add clock tolerance to verification:

```javascript
// Node.js (jose)
const { payload } = await jwtVerify(token, key, {
  clockTolerance: 30  // Allow 30 seconds of skew
});

// Python (PyJWT)
payload = jwt.decode(token, key, algorithms=["RS256"],
                     leeway=timedelta(seconds=30))

// Go (golang-jwt)
parser := jwt.NewParser(jwt.WithLeeway(30 * time.Second))
token, err := parser.Parse(tokenString, keyFunc)
```

### Wrong audience or issuer

The token's `aud` or `iss` doesn't exactly match what the server expects. Common mismatches:

```
Token aud: "https://api.example.com"    Server expects: "api.example.com"         # scheme mismatch
Token aud: "api.example.com/"           Server expects: "api.example.com"          # trailing slash
Token iss: "https://auth.example.com"   Server expects: "https://Auth.example.com" # case mismatch
Token aud: ["api.example.com"]          Server expects: "api.example.com"          # array vs string
```

**Diagnosis:**

```bash
# Decode the token and inspect claims
echo '<token>' | cut -d. -f2 | base64 -d 2>/dev/null | jq .

# Compare exact values
echo "Token aud: $(echo '<token>' | cut -d. -f2 | base64 -d 2>/dev/null | jq -r .aud)"
echo "Expected:  api.example.com"
```

### Expired token not obviously expired

The token may have expired seconds ago, or `nbf` (not before) is in the future.

```python
import datetime
decoded = jwt.decode(token, options={"verify_signature": False})  # Debug only!

exp_time = datetime.datetime.fromtimestamp(decoded["exp"], tz=datetime.timezone.utc)
now = datetime.datetime.now(datetime.timezone.utc)
print(f"Token expired at: {exp_time}")
print(f"Current time:     {now}")
print(f"Difference:       {(now - exp_time).total_seconds()}s")

if "nbf" in decoded:
    nbf_time = datetime.datetime.fromtimestamp(decoded["nbf"], tz=datetime.timezone.utc)
    print(f"Not valid before: {nbf_time}")
    if now < nbf_time:
        print("TOKEN IS NOT YET VALID")
```

### Token version mismatch

If your system uses token versioning, a password change or admin action may have bumped the user's `token_version`, invalidating all existing tokens.

```sql
-- Check the user's current token version
SELECT token_version FROM users WHERE id = 'user_921';
-- Compare with the token's token_version claim
```

---

## Debugging JWT in Development

### jwt.io (browser)

Paste a JWT at [jwt.io](https://jwt.io) to decode header and payload. **Never paste production tokens** — they contain real user data and are valid credentials.

### jwt.ms (Microsoft)

[jwt.ms](https://jwt.ms) — similar to jwt.io, useful for Azure AD / Entra ID tokens. Renders claims with descriptions.

### CLI tools

#### `step-cli` (from Smallstep)

```bash
# Install
brew install step  # macOS
# or: wget https://dl.smallstep.com/cli/docs-cli-install/latest/step-cli_amd64.deb

# Decode without verification
echo '<token>' | step crypto jwt inspect --insecure

# Verify with a key
echo '<token>' | step crypto jwt verify --key public.pem --iss "auth.example.com" --aud "api.example.com"

# Create a token for testing
step crypto jwt sign --key private.pem --iss "auth.example.com" --aud "api.example.com" \
  --sub "test_user" --exp $(date -d '+15 minutes' +%s) --subtle
```

#### `jwt-cli` (Rust-based)

```bash
# Install
cargo install jwt-cli
# or: brew install jwt-cli

# Decode
jwt decode <token>

# Encode (create test tokens)
jwt encode --secret "your-256-bit-secret" --sub "user_921" --exp "+15min" --iss "auth.example.com"

# Decode with time validation
jwt decode <token> --iso8601  # Shows timestamps in human-readable format
```

#### Quick decode with `jq` (no install needed)

```bash
# Decode header
echo '<token>' | cut -d. -f1 | base64 -d 2>/dev/null | jq .

# Decode payload
echo '<token>' | cut -d. -f2 | base64 -d 2>/dev/null | jq .

# One-liner: decode and show expiry in human time
echo '<token>' | cut -d. -f2 | base64 -d 2>/dev/null | jq '{sub, iss, aud, exp: (.exp | todate), iat: (.iat | todate)}'
```

#### Python one-liner

```bash
python3 -c "import jwt,sys; print(jwt.decode(sys.argv[1], options={'verify_signature':False}))" '<token>'
```

### Browser DevTools debugging

```javascript
// Paste in browser console to decode a token from storage or network tab
function decodeJWT(token) {
  const [header, payload] = token.split('.').slice(0, 2).map(
    part => JSON.parse(atob(part.replace(/-/g, '+').replace(/_/g, '/')))
  );
  const exp = new Date(payload.exp * 1000);
  console.table({ ...payload, exp: exp.toISOString(), expired: exp < new Date() });
  return { header, payload };
}
```

---

## "Invalid Signature" Causes

The most frustrating JWT error. The token decodes fine but signature verification fails.

### Wrong key

The most common cause. You're verifying with a different key than the one used to sign.

```bash
# Verify you're using the matching key pair
openssl rsa -in private.pem -pubout -outform PEM | diff - public.pem
# If there's output, the keys don't match

# For EC keys
openssl ec -in ec-private.pem -pubout | diff - ec-public.pem
```

### PEM vs JWK format mismatch

```javascript
// WRONG: passing a JWK object where a PEM/KeyObject is expected
const jwk = { kty: 'RSA', n: '...', e: 'AQAB' };
jwtVerify(token, jwk);  // Error: Key must be KeyLike or Uint8Array

// CORRECT: import the JWK first
import { importJWK } from 'jose';
const key = await importJWK(jwk, 'RS256');
jwtVerify(token, key);
```

```python
# WRONG: passing JWK JSON string as the key
payload = jwt.decode(token, '{"kty":"RSA","n":"..."}', algorithms=["RS256"])

# CORRECT: use the PEM, or construct a key from JWK
from jwt.algorithms import RSAAlgorithm
public_key = RSAAlgorithm.from_jwk(jwk_dict)
payload = jwt.decode(token, public_key, algorithms=["RS256"])
```

### Encoding problems

```bash
# PEM file has wrong line endings (Windows \r\n vs Unix \n)
file private.pem  # Should show "PEM RSA private key"
cat -A private.pem | head -3  # ^M at end = Windows line endings
dos2unix private.pem  # Fix it

# PEM file has extra whitespace or missing newlines
# Must start with -----BEGIN ... KEY----- and end with -----END ... KEY-----
# Each line must be max 64 characters (76 for MIME)
```

### HS256: secret encoding matters

```javascript
// These produce DIFFERENT signatures:
jwt.sign(payload, 'my-secret');                           // String secret
jwt.sign(payload, Buffer.from('my-secret'));               // Buffer from string
jwt.sign(payload, Buffer.from('bXktc2VjcmV0', 'base64')); // Base64-decoded secret

// If auth server uses base64-encoded secret, decode it first:
const secret = Buffer.from(process.env.JWT_SECRET, 'base64');
```

### RS256/ES256: PKCS#1 vs PKCS#8 format

```bash
# PKCS#1 (older format): -----BEGIN RSA PRIVATE KEY-----
# PKCS#8 (modern format): -----BEGIN PRIVATE KEY-----
# Some libraries only accept one format

# Convert PKCS#1 → PKCS#8
openssl pkcs8 -topk8 -inform PEM -outform PEM -nocrypt -in pkcs1-private.pem -out pkcs8-private.pem

# Convert PKCS#8 → PKCS#1
openssl rsa -in pkcs8-private.pem -out pkcs1-private.pem
```

### Token was modified after signing

Even a single byte change in the header or payload invalidates the signature. Check for:
- Proxy or WAF modifying the `Authorization` header.
- URL encoding/decoding altering base64url characters (`+` vs `-`, `/` vs `_`).
- Logging middleware truncating the token.

```bash
# Verify token structure is intact (3 parts, valid base64url)
echo '<token>' | awk -F. '{print NF " parts"; for(i=1;i<=NF;i++) print "Part "i": "length($i)" chars"}'
```

---

## CORS Issues with Authorization Header

### Symptom

Browser sends a preflight `OPTIONS` request. The server doesn't handle it, so the actual request with the JWT never fires.

### Root cause

The `Authorization` header is not a "simple header" per the CORS spec. Any request using it triggers a preflight.

### Fix: server must handle preflight correctly

```javascript
// Express with cors middleware
import cors from 'cors';

app.use(cors({
  origin: ['https://app.example.com'],
  methods: ['GET', 'POST', 'PUT', 'DELETE', 'OPTIONS'],
  allowedHeaders: ['Content-Type', 'Authorization'],  // Must explicitly allow
  credentials: true,       // If using cookies alongside
  maxAge: 86400            // Cache preflight for 24h
}));

// Or manually:
app.options('*', (req, res) => {
  res.set({
    'Access-Control-Allow-Origin': 'https://app.example.com',
    'Access-Control-Allow-Methods': 'GET,POST,PUT,DELETE',
    'Access-Control-Allow-Headers': 'Content-Type,Authorization',
    'Access-Control-Max-Age': '86400'
  });
  res.sendStatus(204);
});
```

```python
# FastAPI
from fastapi.middleware.cors import CORSMiddleware

app.add_middleware(
    CORSMiddleware,
    allow_origins=["https://app.example.com"],
    allow_methods=["*"],
    allow_headers=["Authorization", "Content-Type"],  # Explicit
    allow_credentials=True,
)
```

### Common mistakes

```
# WRONG: wildcard origin with credentials
Access-Control-Allow-Origin: *
Access-Control-Allow-Credentials: true
# Browser rejects this combination

# WRONG: missing Authorization in allowed headers
Access-Control-Allow-Headers: Content-Type
# Authorization header silently dropped

# WRONG: forgetting OPTIONS handler behind auth middleware
# Auth middleware runs BEFORE CORS, rejects preflight with 401
# Fix: place CORS middleware BEFORE auth middleware
```

### Debugging CORS in browser

```javascript
// Check the preflight in Network tab:
// 1. Filter by "OPTIONS" method
// 2. Verify response includes Access-Control-Allow-Headers: Authorization
// 3. If 4xx/5xx on OPTIONS, the server isn't handling preflight

// Quick test with curl:
// curl -X OPTIONS https://api.example.com/endpoint \
//   -H "Origin: https://app.example.com" \
//   -H "Access-Control-Request-Method: GET" \
//   -H "Access-Control-Request-Headers: Authorization" \
//   -v 2>&1 | grep -i "access-control"
```

---

## Cookie-Based JWT Not Being Sent

### SameSite attribute blocking cross-site requests

```
Set-Cookie: token=<jwt>; SameSite=Strict
```

`SameSite=Strict` prevents the cookie from being sent on ANY cross-site request, including top-level navigations from other sites. This breaks OAuth redirect flows and links from emails.

| SameSite Value | Behavior | Use When |
|----------------|----------|----------|
| `Strict` | Never sent cross-site | Refresh token cookies (same-origin API calls only) |
| `Lax` | Sent on top-level navigations (GET) | Session cookies that need to survive redirects |
| `None` | Always sent cross-site (requires `Secure`) | Cross-origin API (e.g., embedded widgets) |

### Path mismatch

```
# Cookie set with:
Set-Cookie: refresh=<jwt>; Path=/api/auth/refresh

# This cookie is NOT sent to:
POST /auth/refresh     ← path doesn't match
POST /api/auth/token   ← path doesn't match
GET  /api/auth/refresh ← sent (matches)

# Fix: ensure the path matches the endpoint exactly
# Or use Path=/ if the cookie needs to be sent to multiple endpoints
```

### Secure flag on HTTP (localhost)

```
Set-Cookie: token=<jwt>; Secure
```

The `Secure` flag means the cookie is only sent over HTTPS. On `http://localhost`, the cookie is silently dropped.

**Fixes for local development:**

```javascript
// Option 1: Conditionally set Secure based on environment
res.cookie('token', jwt, {
  httpOnly: true,
  secure: process.env.NODE_ENV === 'production',
  sameSite: process.env.NODE_ENV === 'production' ? 'strict' : 'lax',
});

// Option 2: Use HTTPS locally
// mkcert localhost
// node --tls-cert localhost.pem --tls-key localhost-key.pem server.js
```

```bash
# Option 3: mkcert for trusted local HTTPS
brew install mkcert  # macOS
mkcert -install
mkcert localhost 127.0.0.1
# Use localhost.pem and localhost-key.pem in your dev server
```

### Domain mismatch

```
# Cookie set by: auth.example.com
Set-Cookie: token=<jwt>; Domain=auth.example.com

# Not sent to: api.example.com (different subdomain)

# Fix: use parent domain
Set-Cookie: token=<jwt>; Domain=.example.com
# Now sent to: auth.example.com, api.example.com, app.example.com
```

### `credentials: 'include'` missing on fetch

```javascript
// WRONG: cookies not sent
fetch('https://api.example.com/data');

// CORRECT: include credentials
fetch('https://api.example.com/data', {
  credentials: 'include'  // Send cookies cross-origin
});

// For same-origin, 'same-origin' (the default) is sufficient
// For cross-origin cookies, MUST use 'include'
```

### Debugging cookie issues

```javascript
// In browser console:
document.cookie  // Shows non-httpOnly cookies
// httpOnly cookies won't appear here but ARE sent — check Network tab

// In DevTools:
// Application tab → Cookies → select domain
// Check: name, value, domain, path, secure, httpOnly, sameSite, expiry
```

---

## Token Too Large for Headers

### Symptoms

- `431 Request Header Fields Too Large` (RFC 6585)
- `400 Bad Request` with message about header size
- `502 Bad Gateway` from reverse proxy
- Request silently fails or hangs

### Diagnosing token size

```bash
# Check token size
echo -n '<token>' | wc -c
# Typical sizes:
#   ~300 bytes:  minimal claims, HS256
#   ~800 bytes:  moderate claims, RS256
#   ~2 KB:       many custom claims, RS256
#   ~4 KB+:      too many claims or embedded permissions

# Check total Authorization header size (includes "Bearer " prefix)
echo -n "Bearer <token>" | wc -c
```

### Proxy and server limits

```nginx
# Nginx: increase header buffer size (default 8 KB total for all headers)
# nginx.conf
large_client_header_buffers 4 16k;

# But this is a band-aid — fix the token size instead
```

```yaml
# AWS ALB: 16 KB max per header, cannot be increased
# If token exceeds this, you must reduce token size

# Cloudflare: 16 KB header limit
# Cannot be changed on free/pro plans
```

### Cookie size limits

```
# Single cookie: 4,096 bytes (name + value + attributes)
# If JWT > ~3,500 bytes, it won't fit in a single cookie

# Workaround: split across multiple cookies (not recommended)
# Better: use reference tokens or claim delegation (see advanced-patterns.md)
```

### Fixes

1. **Remove unnecessary claims** — only include what the API needs for every request.
2. **Use claim delegation** — store permissions externally, reference by ID.
3. **Switch to reference tokens** — opaque token + introspection endpoint.
4. **Use BFF pattern** — tokens stay server-side, browser gets a small session cookie.

See [Token Size Optimization in advanced-patterns.md](advanced-patterns.md#token-size-optimization) for detailed strategies.

---

## Key Rotation Gone Wrong

### Timing issues

**Problem:** New key deployed to signing server before verifiers know about it. Tokens signed with the new key are rejected.

```
Timeline:
  T+0:  Auth server starts signing with new key "key-2025-07"
  T+5s: JWKS cache on API Server 1 still has old keys → rejects new tokens
  T+10m: JWKS cache expires, fetches new keys → works
```

**Fix:** Overlap period. Add the new public key to JWKS BEFORE using it to sign.

```python
# Correct rotation sequence:
# 1. Generate new key pair
new_kid = "key-2025-07"
new_private, new_public = generate_key_pair()

# 2. Add new public key to JWKS (but keep signing with OLD key)
jwks_store.add_key(new_kid, new_public)
# Wait for all caches to refresh (cache_ttl + buffer)
time.sleep(JWKS_CACHE_TTL + 60)

# 3. Switch signing to new key
config.set_signing_key(new_kid, new_private)

# 4. After max_token_lifetime, remove old public key from JWKS
# (all tokens signed with old key have expired)
schedule_removal(old_kid, delay=MAX_TOKEN_LIFETIME)
```

### Cache invalidation

**Problem:** JWKS clients cache aggressively. After rotation, they keep using stale keys.

```javascript
// jose library: createRemoteJWKSet caches by default
import { createRemoteJWKSet } from 'jose';

const JWKS = createRemoteJWKSet(
  new URL('https://auth.example.com/.well-known/jwks.json'),
  {
    cooldownDuration: 30_000,   // Min time between fetches (default 30s)
    cacheMaxAge: 600_000,       // Max cache age (default 10min)
  }
);
// If key rotation happens and cache hasn't expired, new tokens fail

// Fix: on verification failure with "key not found", force a JWKS refresh
async function verifyWithRetry(token) {
  try {
    return await jwtVerify(token, JWKS);
  } catch (err) {
    if (err.code === 'ERR_JWKS_NO_MATCHING_KEY') {
      // Force cache refresh by recreating JWKS
      const freshJWKS = createRemoteJWKSet(
        new URL('https://auth.example.com/.well-known/jwks.json'),
        { cacheMaxAge: 0 }
      );
      return await jwtVerify(token, freshJWKS);
    }
    throw err;
  }
}
```

### `kid` mismatch

**Problem:** Token header has `kid: "key-2025-07"` but JWKS doesn't have that `kid`.

```bash
# Check what kid the token expects
echo '<token>' | cut -d. -f1 | base64 -d 2>/dev/null | jq .kid

# Check what kids the JWKS endpoint has
curl -s https://auth.example.com/.well-known/jwks.json | jq '.keys[].kid'

# If they don't match, either:
# 1. The JWKS hasn't been updated yet (timing issue)
# 2. The kid naming convention changed
# 3. The token was signed by a different auth server
```

### Rollback gone wrong

**Problem:** You rotated to a new key, discovered a bug, rolled back to the old key — but tokens signed with the new key during the window are now invalid and unrecoverable.

**Prevention:** Always keep the previous key in JWKS for at least `max_token_lifetime` after ANY change.

---

## Library-Specific Pitfalls

### Python: PyJWT vs python-jose

```python
# PyJWT: import jwt
import jwt
payload = jwt.decode(token, key, algorithms=["RS256"])

# python-jose: import jose.jwt
from jose import jwt
payload = jwt.decode(token, key, algorithms=["RS256"])

# DANGER: both use `import jwt` or `from jose import jwt`
# If both packages are installed, you may import the wrong one!
```

```bash
# Check which package you actually have
pip show PyJWT       # Package name: PyJWT
pip show python-jose # Package name: python-jose

# They're incompatible — pick one:
# PyJWT: simpler, well-maintained, JWS only
# python-jose: supports JWE, but less actively maintained
# Recommendation: PyJWT for JWS, josepy or authlib for JWE
```

**PyJWT gotchas:**

```python
# PyJWT v2.x breaking changes from v1.x:
# jwt.decode() now REQUIRES algorithms parameter
# jwt.decode() now returns dict (was bytes in some v1 versions)

# jwt.encode() returns str in v2.x (was bytes in v1.x)
token = jwt.encode(payload, key, algorithm="RS256")
# v1: token is bytes → need token.decode('utf-8')
# v2: token is str → use directly
```

### Node.js: `jsonwebtoken` vs `jose`

```javascript
// jsonwebtoken: synchronous, callback-based
import jwt from 'jsonwebtoken';
const token = jwt.sign(payload, secret, { algorithm: 'HS256' });
const decoded = jwt.verify(token, secret);

// jose: async, modern, Web Crypto API, supports JWE/JWK/JWKS
import { SignJWT, jwtVerify } from 'jose';
const token = await new SignJWT(payload)
  .setProtectedHeader({ alg: 'HS256' })
  .sign(secret);
const { payload: decoded } = await jwtVerify(token, secret);
```

**Key differences:**

| Feature | `jsonwebtoken` | `jose` |
|---------|---------------|--------|
| API style | Sync/callback | Async/Promise |
| JWE support | No | Yes |
| JWKS remote fetch | No (need `jwks-rsa`) | Built-in (`createRemoteJWKSet`) |
| Edge runtime (Cloudflare, Deno) | No (needs Node crypto) | Yes (Web Crypto API) |
| Active maintenance | Slower updates | Actively maintained |

**jsonwebtoken gotchas:**

```javascript
// DANGER: jsonwebtoken's verify() with no algorithm restriction
jwt.verify(token, publicKey);  // Accepts ANY algorithm!

// CORRECT: always specify algorithms
jwt.verify(token, publicKey, { algorithms: ['RS256'] });

// DANGER: if secret is a Buffer of a public key and attacker sends HS256 token
// This is the classic key confusion attack
// jose is immune: algorithm is required in options
```

### Go: `golang-jwt/jwt` version differences

```go
// v4 vs v5 breaking changes:
// v5 uses functional options for parser
// v5: jwt.NewParser(jwt.WithValidMethods([]string{"RS256"}))
// v4: jwt.Parse(token, keyFunc) with method check inside keyFunc

// Common mistake: not checking token.Valid
token, err := jwt.Parse(tokenString, keyFunc)
if err != nil {
    // Handle error
}
// ALSO check: token.Valid must be true
if !token.Valid {
    // Token is invalid even without an error in some edge cases
}
```

---

## Mobile App Token Storage

### iOS: Keychain Services

```swift
import Security

func storeToken(_ token: String, forKey key: String) {
    let data = token.data(using: .utf8)!
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrAccount as String: key,
        kSecValueData as String: data,
        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        // kSecAttrAccessibleWhenUnlockedThisDeviceOnly:
        //   - Only accessible when device is unlocked
        //   - Not included in backups
        //   - Not transferred to new devices
    ]
    SecItemDelete(query as CFDictionary)  // Remove existing
    SecItemAdd(query as CFDictionary, nil)
}

func retrieveToken(forKey key: String) -> String? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrAccount as String: key,
        kSecReturnData as String: true
    ]
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess, let data = result as? Data else { return nil }
    return String(data: data, encoding: .utf8)
}
```

### Android: EncryptedSharedPreferences (Jetpack Security)

```kotlin
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKeys

val masterKeyAlias = MasterKeys.getOrCreate(MasterKeys.AES256_GCM_SPEC)

val sharedPrefs = EncryptedSharedPreferences.create(
    "auth_prefs",
    masterKeyAlias,
    context,
    EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
    EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
)

// Store
sharedPrefs.edit().putString("access_token", token).apply()

// Retrieve
val token = sharedPrefs.getString("access_token", null)
```

### Android: Keystore (for higher security)

```kotlin
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.spec.GCMParameterSpec

// Generate AES key in hardware-backed keystore
val keyGenerator = KeyGenerator.getInstance(
    KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore"
)
keyGenerator.init(
    KeyGenParameterSpec.Builder("token_key",
        KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
        .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
        .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
        .setUserAuthenticationRequired(true)  // Require biometric/PIN
        .setUserAuthenticationValidityDurationSeconds(300)  // 5 min
        .build()
)
val secretKey = keyGenerator.generateKey()
```

### Mobile storage comparison

| Platform | Storage | Security Level | Notes |
|----------|---------|----------------|-------|
| iOS | Keychain | High | Hardware-backed on devices with Secure Enclave |
| iOS | UserDefaults | None | **Never use for tokens** |
| Android | EncryptedSharedPreferences | Medium | Software encryption, easy API |
| Android | Keystore | High | Hardware-backed on supported devices |
| Android | SharedPreferences | None | **Never use for tokens** — plaintext on disk |
| React Native | `react-native-keychain` | High | Wraps Keychain (iOS) / Keystore (Android) |
| Flutter | `flutter_secure_storage` | High | Wraps platform-native secure storage |

### Mobile-specific token concerns

- **App backgrounding:** tokens in memory may be lost. Persist securely and restore on foreground.
- **Rooted/jailbroken devices:** secure storage can be bypassed. Consider attestation (SafetyNet/Play Integrity on Android, DeviceCheck on iOS).
- **Token refresh on app launch:** always attempt a silent refresh before showing login UI.
- **Biometric-gated token access:** use Keychain/Keystore with biometric requirement for sensitive operations.

---

## JWT with WebSocket Connections

### Problem

WebSocket connections (`ws://` / `wss://`) in browsers don't support custom headers. You can't send `Authorization: Bearer <token>` during the handshake.

### Solution 1: Ticket pattern (recommended)

Exchange the JWT for a short-lived, single-use ticket via HTTP. Use the ticket as a query parameter during WebSocket connection.

```javascript
// Client
async function connectWebSocket() {
  // Step 1: Get a ticket using the JWT
  const res = await fetch('/api/ws/ticket', {
    headers: { 'Authorization': `Bearer ${accessToken}` }
  });
  const { ticket } = await res.json();

  // Step 2: Connect with the ticket
  const ws = new WebSocket(`wss://api.example.com/ws?ticket=${ticket}`);
  // ...
}
```

```javascript
// Server
const tickets = new Map();  // Or Redis for multi-instance

app.post('/api/ws/ticket', authMiddleware, (req, res) => {
  const ticket = crypto.randomUUID();
  tickets.set(ticket, {
    userId: req.user.sub,
    createdAt: Date.now(),
    used: false
  });
  // Auto-expire after 30 seconds
  setTimeout(() => tickets.delete(ticket), 30_000);
  res.json({ ticket });
});

wss.on('connection', (ws, req) => {
  const url = new URL(req.url, 'wss://base');
  const ticket = url.searchParams.get('ticket');
  const record = tickets.get(ticket);

  if (!record || record.used || (Date.now() - record.createdAt) > 30_000) {
    ws.close(4001, 'Invalid or expired ticket');
    return;
  }

  record.used = true;  // Single-use
  ws.userId = record.userId;
});
```

### Solution 2: First-message authentication

Connect without auth, send JWT as the first message, authenticate before allowing other messages.

```javascript
// Client
const ws = new WebSocket('wss://api.example.com/ws');
ws.onopen = () => {
  ws.send(JSON.stringify({ type: 'auth', token: accessToken }));
};

// Server
wss.on('connection', (ws) => {
  ws.authenticated = false;
  ws.authTimeout = setTimeout(() => {
    if (!ws.authenticated) ws.close(4001, 'Auth timeout');
  }, 5_000);  // Must authenticate within 5 seconds

  ws.on('message', (data) => {
    const msg = JSON.parse(data);

    if (!ws.authenticated) {
      if (msg.type === 'auth') {
        try {
          const claims = validateJWT(msg.token);
          ws.authenticated = true;
          ws.userId = claims.sub;
          clearTimeout(ws.authTimeout);
          ws.send(JSON.stringify({ type: 'auth_ok' }));
        } catch {
          ws.close(4001, 'Invalid token');
        }
      } else {
        ws.close(4001, 'Must authenticate first');
      }
      return;
    }

    // Handle authenticated messages
    handleMessage(ws, msg);
  });
});
```

### Token expiry during long-lived connections

WebSocket connections can live for hours. The JWT used to authenticate may expire during the connection.

```javascript
// Client: send periodic re-auth messages
setInterval(async () => {
  if (ws.readyState === WebSocket.OPEN) {
    const freshToken = await getOrRefreshAccessToken();
    ws.send(JSON.stringify({ type: 'reauth', token: freshToken }));
  }
}, 10 * 60 * 1000);  // Re-auth every 10 minutes

// Server: handle re-auth
ws.on('message', (data) => {
  const msg = JSON.parse(data);
  if (msg.type === 'reauth') {
    try {
      const claims = validateJWT(msg.token);
      if (claims.sub !== ws.userId) {
        ws.close(4001, 'User mismatch');
        return;
      }
      ws.tokenExp = claims.exp;
      ws.send(JSON.stringify({ type: 'reauth_ok' }));
    } catch {
      ws.close(4001, 'Re-auth failed');
    }
  }
});
```
