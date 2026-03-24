# Secure Token Storage Patterns

## Overview

Token storage is one of the most critical security decisions in OAuth2 implementations. The right approach depends on your platform and threat model.

**Core principle**: Minimize token exposure. Store tokens in the most restricted storage available for your platform, and never expose them to JavaScript when possible.

---

## Web Applications (Server-Side Rendered)

### Recommended: Server-Side Session

```
Browser ←→ [Session Cookie (ID only)] ←→ Server [Session Store: tokens]
```

- Access token and refresh token stored in server-side session (Redis, DB, memory)
- Browser only receives an opaque session ID in an HttpOnly cookie
- Tokens never reach the client

```javascript
// Express.js example
app.get('/auth/callback', async (req, res) => {
  const tokens = await exchangeCode(req.query.code);

  // Store tokens in server session — never sent to browser
  req.session.accessToken = tokens.access_token;
  req.session.refreshToken = encrypt(tokens.refresh_token);
  req.session.expiresAt = Date.now() + tokens.expires_in * 1000;

  res.redirect('/dashboard');
});

// API proxy — attach token server-side
app.use('/api', async (req, res, next) => {
  if (!req.session.accessToken) return res.status(401).json({ error: 'Unauthenticated' });

  if (Date.now() > req.session.expiresAt - 30000) {
    const refreshed = await refreshToken(decrypt(req.session.refreshToken));
    req.session.accessToken = refreshed.access_token;
    req.session.expiresAt = Date.now() + refreshed.expires_in * 1000;
  }

  req.headers['authorization'] = `Bearer ${req.session.accessToken}`;
  next();
});
```

**Cookie settings:**
```javascript
cookie: {
  httpOnly: true,     // Not accessible via JavaScript
  secure: true,       // HTTPS only
  sameSite: 'lax',    // CSRF protection
  maxAge: 86400000,   // 24 hours
  path: '/',
  domain: '.example.com',  // Share across subdomains if needed
}
```

---

## Single-Page Applications (SPA)

### Option 1: BFF Pattern (Recommended)

Backend for Frontend — a thin server-side proxy that handles OAuth and stores tokens.

```
SPA ←→ [HttpOnly Cookie] ←→ BFF Server ←→ [Bearer Token] ←→ Resource API
```

- SPA never sees tokens
- BFF handles auth flow, token refresh, and proxies API calls
- HttpOnly cookies for session management
- Eliminates XSS-based token theft entirely

```javascript
// BFF proxy (Express)
app.use('/api', requireSession, async (req, res) => {
  const token = await getValidToken(req.session);
  const apiRes = await fetch(`${API_BASE}${req.path}`, {
    method: req.method,
    headers: {
      'Authorization': `Bearer ${token}`,
      'Content-Type': req.headers['content-type'],
    },
    body: ['POST', 'PUT', 'PATCH'].includes(req.method) ? JSON.stringify(req.body) : undefined,
  });
  res.status(apiRes.status).json(await apiRes.json());
});
```

### Option 2: In-Memory Storage (When No BFF Available)

Store tokens only in JavaScript memory — never in `localStorage` or `sessionStorage`.

```javascript
// Token stored only in closure — lost on page refresh
const createTokenStore = () => {
  let accessToken = null;
  let expiresAt = 0;

  return {
    setToken(token, expiresIn) {
      accessToken = token;
      expiresAt = Date.now() + expiresIn * 1000;
    },
    getToken() {
      if (!accessToken || Date.now() > expiresAt - 30000) return null;
      return accessToken;
    },
    clear() {
      accessToken = null;
      expiresAt = 0;
    },
  };
};

const tokenStore = createTokenStore();
```

**Tradeoffs:**
- ✅ Not accessible to XSS via DOM APIs
- ❌ Lost on page refresh (user must re-authenticate or use silent auth)
- ❌ XSS can still make authenticated requests while the page is active

### What NOT to Do

```javascript
// ❌ NEVER store tokens in localStorage
localStorage.setItem('access_token', token);
// Why: Accessible to any JavaScript on the page, including XSS payloads.
// Persists indefinitely. Shared across tabs.

// ❌ NEVER store tokens in sessionStorage
sessionStorage.setItem('access_token', token);
// Why: Still accessible to XSS. Only marginally better (per-tab).

// ❌ NEVER store tokens in cookies set by JavaScript
document.cookie = `access_token=${token}`;
// Why: Accessible to XSS. If not HttpOnly, it's equivalent to localStorage.

// ❌ NEVER store tokens in URL parameters or fragments
window.location.hash = `#access_token=${token}`;
// Why: Leaks via referrer headers, browser history, server logs.
```

---

## Mobile Applications

### iOS: Keychain Services

```swift
import Security

struct TokenStorage {
    private static let service = "com.example.app.oauth"

    static func save(token: String, forKey key: String) throws {
        let data = token.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            // kSecAttrAccessibleWhenUnlockedThisDeviceOnly for higher security
        ]

        SecItemDelete(query as CFDictionary) // Remove existing
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw TokenStorageError.saveFailed(status)
        }
    }

    static func load(forKey key: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func delete(forKey key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// Usage
try TokenStorage.save(token: accessToken, forKey: "access_token")
try TokenStorage.save(token: refreshToken, forKey: "refresh_token")
let token = try TokenStorage.load(forKey: "access_token")
```

**Keychain access levels:**
| Level | Description | Use For |
|-------|-------------|---------|
| `AfterFirstUnlockThisDeviceOnly` | Available after first unlock | Refresh tokens (recommended) |
| `WhenUnlockedThisDeviceOnly` | Available only when device is unlocked | Access tokens |
| `WhenPasscodeSetThisDeviceOnly` | Requires device passcode to be set | Highest security tokens |

### Android: EncryptedSharedPreferences + Keystore

```kotlin
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

class TokenStorage(context: Context) {
    private val masterKey = MasterKey.Builder(context)
        .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
        .build()

    private val prefs = EncryptedSharedPreferences.create(
        context,
        "oauth_tokens",
        masterKey,
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
    )

    fun saveToken(key: String, token: String) {
        prefs.edit().putString(key, token).apply()
    }

    fun getToken(key: String): String? {
        return prefs.getString(key, null)
    }

    fun deleteToken(key: String) {
        prefs.edit().remove(key).apply()
    }

    fun clearAll() {
        prefs.edit().clear().apply()
    }
}

// Usage
val storage = TokenStorage(applicationContext)
storage.saveToken("access_token", accessToken)
storage.saveToken("refresh_token", refreshToken)
val token = storage.getToken("access_token")
```

**Android security notes:**
- `EncryptedSharedPreferences` uses Android Keystore-backed keys
- Keys are hardware-backed on supported devices (StrongBox)
- Do NOT use plain `SharedPreferences` for tokens
- Do NOT store tokens in SQLite without encryption
- Consider `BiometricPrompt` for step-up access to sensitive tokens

---

## Desktop Applications

### Recommended: OS Credential Managers

| OS | API | Library |
|----|-----|---------|
| macOS | Keychain Services | `security` CLI or `keyring` (Python) |
| Windows | Credential Manager / DPAPI | `keyring` (Python), `CredWrite` (C#) |
| Linux | Secret Service (GNOME Keyring / KWallet) | `keyring` (Python), `libsecret` |

```python
# Python cross-platform example using keyring
import keyring

SERVICE_NAME = "com.example.app"

def save_token(key: str, token: str):
    keyring.set_password(SERVICE_NAME, key, token)

def load_token(key: str) -> str | None:
    return keyring.get_password(SERVICE_NAME, key)

def delete_token(key: str):
    keyring.delete_password(SERVICE_NAME, key)
```

---

## Summary Matrix

| Platform | Access Token | Refresh Token | Mechanism |
|----------|-------------|---------------|-----------|
| Server-side web | Server session/memory | Encrypted in DB or session | HttpOnly session cookie |
| SPA (with BFF) | BFF server memory | BFF server/DB | HttpOnly session cookie to BFF |
| SPA (no BFF) | In-memory variable | In-memory or silent auth | Closure-scoped variable |
| iOS | Keychain (WhenUnlocked) | Keychain (AfterFirstUnlock) | Keychain Services API |
| Android | EncryptedSharedPrefs | EncryptedSharedPrefs | Android Keystore |
| Desktop | OS credential manager | OS credential manager | keyring / Credential Manager |
| CLI tool | Temp file (0600) or memory | OS credential manager | Short-lived process |

---

## Additional Security Measures

1. **Encrypt refresh tokens at rest** — even in server-side storage, use application-level encryption
2. **Bind tokens to device/client** — use DPoP or mTLS certificate binding
3. **Set absolute token lifetimes** — refresh tokens should expire (e.g., 30 days max)
4. **Implement token rotation** — issue new refresh token on each use
5. **Revoke on security events** — password change, suspicious activity, logout
6. **Log token usage** — audit trail for issued and used tokens
7. **Use short-lived access tokens** — 5–15 minutes reduces the window of compromise
