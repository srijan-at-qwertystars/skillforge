# JWT Troubleshooting Guide

## Table of Contents

- [Clock Skew Issues](#clock-skew-issues)
- [Token Too Large](#token-too-large)
- [CORS and Cookie Problems](#cors-and-cookie-problems)
- [Refresh Token Rotation Races](#refresh-token-rotation-races)
- [Key Rotation During Deployment](#key-rotation-during-deployment)
- [Mobile Token Storage](#mobile-token-storage)
- [Debugging Invalid Signatures](#debugging-invalid-signatures)
- [Library-Specific Gotchas](#library-specific-gotchas)
- [Common Error Messages and Fixes](#common-error-messages-and-fixes)
- [Token Expiration Edge Cases](#token-expiration-edge-cases)

---

## Clock Skew Issues

### Symptom
Tokens are rejected as expired or "not yet valid" even though they were just issued. Errors like `TokenExpiredError` or `ImmatureSignatureError` appear intermittently.

### Root Cause
The server that issues the token and the server that validates it have different system clocks. Even 30 seconds of drift can cause problems with short-lived tokens.

### Diagnosis

```bash
# Check clock on both servers
date -u +"%Y-%m-%d %H:%M:%S UTC"

# Check NTP sync status
timedatectl status
# or
ntpstat
chronyc tracking

# Compare clocks between two hosts
ssh issuer-host 'date -u +%s' && date -u +%s
```

### Fixes

**1. Configure clock tolerance in your JWT library:**

```javascript
// Node.js (jsonwebtoken)
jwt.verify(token, secret, { clockTolerance: 30 }); // 30 seconds

// Node.js (jose)
const { payload } = await jwtVerify(token, key, { clockTolerance: '30s' });
```

```python
# Python (PyJWT)
jwt.decode(token, key, algorithms=["RS256"], leeway=timedelta(seconds=30))
```

```go
// Go (golang-jwt)
parser := jwt.NewParser(jwt.WithLeeway(30 * time.Second))
```

**2. Fix the actual clock drift:**

```bash
# Enable NTP synchronization
sudo timedatectl set-ntp true

# If using chrony
sudo systemctl enable --now chronyd

# If using systemd-timesyncd
sudo systemctl enable --now systemd-timesyncd
```

**3. For containerized environments:**

```yaml
# Docker: containers inherit host clock, but verify:
docker run --rm alpine date -u

# Kubernetes: ensure nodes have NTP configured
# In pod spec, the clock comes from the node
```

### Rules of Thumb
- Allow ≤30 seconds of clock tolerance. More than that indicates a real infrastructure problem.
- NEVER set clock tolerance to minutes or hours — that defeats the purpose of `exp`.
- Fix clock sync at the infrastructure level; tolerance is a safety net, not a solution.

---

## Token Too Large

### Symptom
HTTP 431 (Request Header Fields Too Large), HTTP 400, or reverse proxy rejecting requests. Tokens work in development but fail in production behind Nginx/Apache/CDN.

### Root Cause
JWT tokens with too many claims exceed HTTP header size limits.

### Diagnosis

```bash
# Check token size
echo -n "$TOKEN" | wc -c

# Typical header limits:
# Nginx default: 4KB per header, 8KB total headers
# Apache default: 8KB total headers
# AWS ALB: 16KB total headers
# Cloudflare: 16KB total headers
# Node.js http: 16KB total headers (configurable)
```

```bash
# Decode and inspect payload size
echo "$TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | python3 -m json.tool | wc -c
```

### Fixes

**1. Reduce claim payload:**

```json
// BAD: embedding full permission tree
{
  "sub": "user_1",
  "permissions": ["users:read", "users:write", "users:delete", "posts:read",
    "posts:write", "posts:delete", "comments:read", "comments:moderate",
    "billing:read", "billing:write", "reports:generate", "admin:settings",
    ...50 more entries...
  ]
}

// GOOD: use role reference, look up permissions server-side
{
  "sub": "user_1",
  "role": "admin",
  "org": "org_42"
}
```

**2. Use claim abbreviations:**

```json
// Instead of verbose custom claims:
{ "organization_id": "org_42", "department_name": "engineering" }

// Use short names:
{ "org": "org_42", "dept": "eng" }
```

**3. Increase server limits (if token size is justified):**

```nginx
# Nginx
http {
    large_client_header_buffers 4 16k;
}
```

```javascript
// Node.js
const server = http.createServer({ maxHeaderSize: 32768 }, app);
```

**4. Use token introspection for permission-heavy use cases:**

```
Client → sends compact JWT (sub, role, exp)
Service → calls /introspect with token to get full permissions
Service → caches introspection result for token lifetime
```

### Size Guidelines
- Target: under 1KB for the full JWT.
- Warning zone: 2-4KB.
- Danger zone: >4KB — will break behind many proxies.

---

## CORS and Cookie Problems

### Symptom
Refresh token cookie not sent on cross-origin requests. `Set-Cookie` header ignored by the browser. 401 errors on refresh endpoint despite valid cookie.

### Diagnosis Checklist

```
□ Is the API on a different origin than the frontend?
□ Is SameSite=None set (required for cross-origin cookies)?
□ Is Secure flag set (required when SameSite=None)?
□ Is the server sending Access-Control-Allow-Credentials: true?
□ Is the client sending credentials: 'include'?
□ Is Access-Control-Allow-Origin set to the specific origin (not *)?
□ Is the cookie Path correct?
□ Are you testing on localhost without HTTPS?
```

### Fixes

**Same-origin setup (preferred):**

```
Frontend: https://app.example.com
API:      https://app.example.com/api
Cookie:   SameSite=Strict; Secure; HttpOnly; Path=/api/auth/refresh
```

**Cross-origin setup (when same-origin is impossible):**

```javascript
// Server (Express)
app.use(cors({
  origin: 'https://app.example.com',  // NOT '*'
  credentials: true,                   // MUST be true
}));

app.post('/auth/refresh', (req, res) => {
  res.cookie('refreshToken', token, {
    httpOnly: true,
    secure: true,           // MUST be true
    sameSite: 'none',       // Required for cross-origin
    path: '/auth/refresh',
    domain: '.example.com', // If sharing across subdomains
    maxAge: 7 * 24 * 3600 * 1000,
  });
});
```

```javascript
// Client (fetch)
fetch('https://api.example.com/auth/refresh', {
  method: 'POST',
  credentials: 'include',  // MUST include cookies
});

// Client (axios)
axios.post('https://api.example.com/auth/refresh', {}, {
  withCredentials: true,    // MUST be true
});
```

**Localhost development:**

```javascript
// For local dev without HTTPS, use SameSite=Lax (not None)
// SameSite=None requires Secure which requires HTTPS
res.cookie('refreshToken', token, {
  httpOnly: true,
  secure: process.env.NODE_ENV === 'production',
  sameSite: process.env.NODE_ENV === 'production' ? 'none' : 'lax',
});
```

### Common Pitfalls
- `Access-Control-Allow-Origin: *` with `credentials: true` is **rejected by browsers**. Must be a specific origin.
- Safari has stricter third-party cookie blocking. Prefer same-origin or use the `Authorization` header with in-memory tokens.
- Chrome's third-party cookie deprecation affects cross-origin cookie flows. Plan migration.

---

## Refresh Token Rotation Races

### Symptom
Users get logged out randomly. Refresh token requests return 401. Happens more in multi-tab scenarios or when the app makes concurrent API calls.

### Root Cause
Two tabs/requests simultaneously use the same refresh token. Tab A rotates it to RT_2, but Tab B still sends the old RT_1, triggering reuse detection.

### Scenario

```
Tab A: POST /refresh (RT_1) ──────────▶ 200: RT_2, new access_token
Tab B: POST /refresh (RT_1) ──────────▶ 401: RT_1 already rotated → REUSE DETECTED
                                          Server revokes entire family
```

### Fixes

**1. Client-side: serialize refresh requests**

```javascript
let refreshPromise = null;

async function getAccessToken() {
  if (isAccessTokenValid()) return accessToken;

  // If a refresh is already in progress, wait for it
  if (refreshPromise) return refreshPromise;

  refreshPromise = (async () => {
    try {
      const res = await fetch('/auth/refresh', {
        method: 'POST',
        credentials: 'include',
      });
      if (!res.ok) throw new Error('Refresh failed');
      const { access_token } = await res.json();
      accessToken = access_token;
      return accessToken;
    } finally {
      refreshPromise = null;
    }
  })();

  return refreshPromise;
}
```

**2. Cross-tab coordination with BroadcastChannel:**

```javascript
const authChannel = new BroadcastChannel('auth');

authChannel.onmessage = (event) => {
  if (event.data.type === 'TOKEN_REFRESHED') {
    accessToken = event.data.accessToken;
  }
  if (event.data.type === 'LOGGED_OUT') {
    redirectToLogin();
  }
};

async function refreshToken() {
  // ... perform refresh ...
  authChannel.postMessage({
    type: 'TOKEN_REFRESHED',
    accessToken: newAccessToken,
  });
}
```

**3. Server-side: grace period for recently-rotated tokens**

```python
ROTATION_GRACE_PERIOD = timedelta(seconds=10)

def refresh(old_token):
    rt = db.get_refresh_token(old_token.jti)

    if rt.replaced_by:
        successor = db.get_refresh_token(rt.replaced_by)
        # Allow if the successor was created very recently (race condition window)
        if successor.issued_at > datetime.now(UTC) - ROTATION_GRACE_PERIOD:
            # Return the same successor tokens instead of revoking
            return get_tokens_for(successor)
        else:
            # Genuine reuse — revoke family
            db.revoke_family(rt.family_id)
            raise TokenReusedError()

    # Normal rotation...
    new_rt = rotate(rt)
    return new_rt
```

### Recommended Approach
Use both client-side serialization AND server-side grace period. The client-side fix prevents most races; the server-side grace period handles edge cases without false-positive family revocations.

---

## Key Rotation During Deployment

### Symptom
After deploying with new JWT signing keys, existing users get 401 errors. Tokens issued with the old key are rejected by new instances that only know the new key.

### Root Cause
Rolling deployment creates a window where some instances have the new key and others have the old key. Or: the old public key was removed from JWKS before old tokens expired.

### Correct Rotation Procedure

```
Timeline:
  T=0    Deploy new key to JWKS (both old + new public keys available)
  T=0    Start signing new tokens with new key (kid=key-2024-07)
  T=0    Old instances still validate old tokens (kid=key-2024-01) ✓
  T+15m  All old access tokens have expired (assuming 15m TTL)
  T+15m  Safe to remove old key from JWKS
  T+7d   All old refresh tokens have expired
  T+7d   Safe to delete old private key material
```

### Implementation

```python
# config.py — key management
SIGNING_KEYS = {
    # Current key — used for signing new tokens
    "key-2024-07": {
        "private": load_key("keys/key-2024-07.pem"),
        "public": load_key("keys/key-2024-07.pub"),
        "status": "active",
    },
    # Previous key — still valid for verification during grace period
    "key-2024-01": {
        "public": load_key("keys/key-2024-01.pub"),
        "status": "retiring",
        "retire_after": datetime(2024, 7, 15, tzinfo=UTC),
    },
}

CURRENT_SIGNING_KID = "key-2024-07"

def get_signing_key():
    """Always sign with the current active key."""
    k = SIGNING_KEYS[CURRENT_SIGNING_KID]
    return k["private"], CURRENT_SIGNING_KID

def get_verification_key(kid: str):
    """Accept any non-retired key for verification."""
    if kid not in SIGNING_KEYS:
        raise InvalidKeyError(f"Unknown kid: {kid}")
    key_info = SIGNING_KEYS[kid]
    if key_info["status"] == "retired":
        raise InvalidKeyError(f"Key {kid} has been retired")
    return key_info["public"]
```

### Blue-Green Deployment

```yaml
# Ensure both blue and green environments have ALL active public keys
# before switching traffic.

# deployment-config.yaml
jwt:
  signing_key_id: "key-2024-07"
  verification_keys:
    - id: "key-2024-07"
      path: "/secrets/jwt/key-2024-07.pub"
    - id: "key-2024-01"
      path: "/secrets/jwt/key-2024-01.pub"
```

### Checklist
- [ ] New public key is in JWKS before any instance signs with it.
- [ ] All instances can verify tokens signed with both old and new keys.
- [ ] Old key is not removed from JWKS until `max_token_lifetime` has elapsed.
- [ ] JWKS caches across services have refreshed (check TTLs).
- [ ] Monitoring alert on `kid not found` errors during rotation.

---

## Mobile Token Storage

### Platform-Specific Secure Storage

**iOS:**

```swift
import Security

func storeToken(_ token: String, forKey key: String) {
    let data = token.data(using: .utf8)!
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrAccount as String: key,
        kSecValueData as String: data,
        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    SecItemDelete(query as CFDictionary)  // Remove old value
    let status = SecItemAdd(query as CFDictionary, nil)
    guard status == errSecSuccess else {
        fatalError("Keychain store failed: \(status)")
    }
}
```

**Android:**

```kotlin
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKeys

val masterKey = MasterKeys.getOrCreate(MasterKeys.AES256_GCM_SPEC)
val prefs = EncryptedSharedPreferences.create(
    "auth_tokens",
    masterKey,
    context,
    EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
    EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
)

// Store
prefs.edit().putString("refresh_token", token).apply()

// Retrieve
val token = prefs.getString("refresh_token", null)
```

**React Native:**

```javascript
// Use react-native-keychain (backed by Keychain/Keystore)
import * as Keychain from 'react-native-keychain';

await Keychain.setGenericPassword('auth', refreshToken, {
  accessible: Keychain.ACCESSIBLE.AFTER_FIRST_UNLOCK_THIS_DEVICE_ONLY,
  service: 'com.example.app.auth',
});

const credentials = await Keychain.getGenericPassword({
  service: 'com.example.app.auth',
});
const token = credentials ? credentials.password : null;
```

### Common Mobile Mistakes

| Mistake | Risk | Fix |
|---------|------|-----|
| Store in `SharedPreferences` / `UserDefaults` (unencrypted) | Readable on rooted/jailbroken devices | Use `EncryptedSharedPreferences` / Keychain |
| Store in app sandbox files | Accessible via backup or file manager | Use OS keychain |
| Include tokens in logs | Leaked via crash reporters | Never log tokens |
| Cache tokens in WebView | Shared across WebView instances | Use native storage, pass via bridge |

---

## Debugging Invalid Signatures

### Step-by-Step Diagnosis

**Step 1: Decode the token header**

```bash
echo "$TOKEN" | cut -d. -f1 | base64 -d 2>/dev/null || \
echo "$TOKEN" | cut -d. -f1 | tr '_-' '/+' | base64 -d
```

Check: Does `alg` match what the server expects? Does `kid` match a known key?

**Step 2: Verify the algorithm matches**

```
Token header says:  { "alg": "RS256", "kid": "key-2024-01" }
Server expects:     algorithms: ["ES256"]
→ MISMATCH — server rejects the token
```

**Step 3: Check the key**

```bash
# If using RSA, verify the public key matches the private key that signed
openssl rsa -in private.pem -pubout 2>/dev/null | diff - public.pem

# If using EC
openssl ec -in private-ec.pem -pubout 2>/dev/null | diff - public-ec.pem
```

**Step 4: Check for encoding issues**

```bash
# JWT uses Base64URL encoding (no padding, - instead of +, _ instead of /)
# Some libraries incorrectly use standard Base64
echo "$TOKEN" | grep -c '[+/=]'
# Should output 0 for a valid JWT
```

**Step 5: Verify with a known-good tool**

```bash
# Using Node.js
node -e "
const jwt = require('jsonwebtoken');
const fs = require('fs');
const key = fs.readFileSync('public.pem');
try {
  const decoded = jwt.verify('$TOKEN', key, { algorithms: ['RS256'] });
  console.log('VALID:', decoded);
} catch(e) {
  console.log('INVALID:', e.message);
}
"
```

### Common Causes

| Cause | How to Identify | Fix |
|-------|----------------|-----|
| Wrong key | `kid` mismatch or no `kid` | Check JWKS endpoint, verify `kid` lookup |
| Algorithm mismatch | Token says RS256, server pins HS256 | Align algorithm config |
| Key format issue | PEM vs JWK confusion | Ensure consistent format |
| Trailing newlines in secret | `HS256` secret has `\n` appended | `secret.trim()` |
| Environment variable encoding | Base64-encoded key not decoded | Decode before use |
| Token modified in transit | Proxy or WAF modifying headers | Check with `curl -v` |

---

## Library-Specific Gotchas

### Node.js — jsonwebtoken

```javascript
// GOTCHA: verify() with a callback swallows errors
jwt.verify(token, secret, (err, decoded) => {
  // If you forget to check err, invalid tokens pass through!
});

// FIX: Use synchronous form or always check err
try {
  const decoded = jwt.verify(token, secret, { algorithms: ['HS256'] });
} catch (err) {
  // handle error
}

// GOTCHA: sign() accepts any algorithm including 'none' by default
jwt.sign(payload, '', { algorithm: 'none' }); // This works!

// FIX: Always pin algorithms in verify()
jwt.verify(token, secret, { algorithms: ['HS256'] }); // Rejects 'none'
```

### Node.js — jose

```javascript
// GOTCHA: importJWK requires algorithm parameter for symmetric keys
const key = await importJWK({ kty: 'oct', k: '...' }, 'HS256'); // Need alg

// GOTCHA: Key objects are not serializable — can't store in Redis/session
// FIX: Store raw key material, import when needed
```

### Python — PyJWT

```python
# GOTCHA: decode() with algorithms=None or unset is DANGEROUS
jwt.decode(token, key)  # Accepts any algorithm! (deprecated behavior)

# FIX: Always specify algorithms
jwt.decode(token, key, algorithms=["RS256"])

# GOTCHA: PyJWT v1 vs v2 breaking changes
# v1: jwt.decode() returns dict, requires verify=True/False
# v2: jwt.decode() requires algorithms=[], removed verify param
# FIX: Pin your PyJWT version, check migration guide

# GOTCHA: EC key format
# PyJWT expects PEM format for EC keys, not raw coordinates
# FIX: Convert JWK to PEM using jwt.algorithms.ECAlgorithm.from_jwk()
from jwt.algorithms import ECAlgorithm
key = ECAlgorithm.from_jwk(jwk_dict)
```

### Go — golang-jwt/jwt/v5

```go
// GOTCHA: ParseWithClaims keyFunc must validate the signing method
token, err := jwt.ParseWithClaims(tokenStr, &Claims{},
    func(t *jwt.Token) (interface{}, error) {
        // MUST CHECK signing method — without this, alg confusion is possible
        if _, ok := t.Method.(*jwt.SigningMethodRSA); !ok {
            return nil, fmt.Errorf("unexpected method: %v", t.Header["alg"])
        }
        return publicKey, nil
    })

// GOTCHA: v5 changed error handling — use errors.Is()
if errors.Is(err, jwt.ErrTokenExpired) {
    // handle expired
}

// GOTCHA: Claims must implement the jwt.Claims interface
// RegisteredClaims already does, but custom claims need embedding
type MyClaims struct {
    Role string `json:"role"`
    jwt.RegisteredClaims  // MUST embed this
}
```

### Java — jjwt (io.jsonwebtoken)

```java
// GOTCHA: Older versions allow alg:none by default
// FIX: Use parserBuilder which rejects none
Jwts.parserBuilder()
    .setSigningKey(key)
    .build()
    .parseClaimsJws(token);  // parseClaimsJws rejects unsigned tokens

// GOTCHA: Key size validation — HS256 needs ≥256-bit key
// FIX: Use Keys.secretKeyFor()
SecretKey key = Keys.secretKeyFor(SignatureAlgorithm.HS256);
```

---

## Common Error Messages and Fixes

| Error Message | Library | Cause | Fix |
|--------------|---------|-------|-----|
| `jwt malformed` | jsonwebtoken | Token is not a valid JWT string | Check token format (3 dot-separated parts) |
| `invalid signature` | jsonwebtoken | Wrong key or token tampered | Verify key matches, check for encoding issues |
| `jwt expired` | jsonwebtoken | Token `exp` has passed | Refresh the token or increase `clockTolerance` |
| `jwt not active` | jsonwebtoken | Token `nbf` is in the future | Check clock sync, add `clockTolerance` |
| `InvalidSignatureError` | PyJWT | Wrong key or algorithm | Check `algorithms` param, verify key format |
| `DecodeError` | PyJWT | Malformed token or wrong padding | Ensure proper Base64URL encoding |
| `ExpiredSignatureError` | PyJWT | Token expired | Add `leeway` parameter |
| `token is unverifiable` | golang-jwt | keyFunc returned error | Check keyFunc logic, verify key type |
| `token signature is invalid` | golang-jwt | Wrong key or method mismatch | Verify signing method check in keyFunc |

---

## Token Expiration Edge Cases

### Issue: Token expires during a long request

```
T=0s:    Client sends request with token (exp = T+2s)
T=0.5s:  API gateway validates token ✓
T=3s:    Backend service validates same token ✗ EXPIRED
```

**Fix**: Validate token only at the entry point (API gateway). Propagate user context internally via trusted headers or mTLS.

### Issue: Token expires between page navigation in SPA

**Fix**: Proactively refresh when token is close to expiry:

```javascript
function shouldRefresh(token) {
  const payload = JSON.parse(atob(token.split('.')[1]));
  const expiresIn = payload.exp - Date.now() / 1000;
  return expiresIn < 60; // Refresh if <60s remaining
}
```

### Issue: System clock jumps backward (NTP correction)

Tokens that were valid suddenly appear to have `iat` in the future. Usually self-correcting but can cause a burst of errors.

**Fix**: Use `clockTolerance`/`leeway` of 30s. Monitor for clock jumps in infrastructure.
