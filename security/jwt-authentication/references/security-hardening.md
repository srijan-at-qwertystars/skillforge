# JWT Security Hardening Guide

## Table of Contents

- [Defense-in-Depth JWT Architecture](#defense-in-depth-jwt-architecture)
- [Content Security Policy for Token-Bearing SPAs](#content-security-policy-for-token-bearing-spas)
- [Rate Limiting Auth Endpoints](#rate-limiting-auth-endpoints)
- [Brute-Force Protection for Token Secrets](#brute-force-protection-for-token-secrets)
- [Log Safety — Tokens and Sensitive Data](#log-safety--tokens-and-sensitive-data)
- [OWASP JWT Cheat Sheet Recommendations](#owasp-jwt-cheat-sheet-recommendations)
- [Security Headers for Auth Endpoints](#security-headers-for-auth-endpoints)
- [Monitoring and Alerting on Suspicious Token Patterns](#monitoring-and-alerting-on-suspicious-token-patterns)
- [Incident Response: Mass Token Revocation](#incident-response-mass-token-revocation)
- [Compliance Considerations](#compliance-considerations)

---

## Defense-in-Depth JWT Architecture

No single security control is sufficient. Layer multiple defenses so that failure of one layer doesn't result in a full compromise.

### Layered security model

```
┌─────────────────────────────────────────────────────────┐
│  Layer 1: Transport Security                            │
│  • TLS 1.3 everywhere (HTTPS, gRPC TLS, WSS)           │
│  • Certificate pinning for mobile apps                  │
│  • HSTS with preload                                    │
├─────────────────────────────────────────────────────────┤
│  Layer 2: Token Construction                            │
│  • Asymmetric signing (ES256/RS256)                     │
│  • Short expiry (5–15 min access, 7d refresh)           │
│  • Minimal claims (no sensitive data in payload)        │
│  • Unique jti for every token                           │
├─────────────────────────────────────────────────────────┤
│  Layer 3: Token Validation                              │
│  • Algorithm pinning (never trust alg header)           │
│  • Full claim validation (iss, aud, exp, nbf)           │
│  • Signature verification with correct key (kid-based)  │
│  • Revocation check (blocklist or version check)        │
├─────────────────────────────────────────────────────────┤
│  Layer 4: Token Storage & Transmission                  │
│  • httpOnly + Secure + SameSite=Strict cookies          │
│  • Access token in memory only (browser)                │
│  • Encrypted storage on mobile (Keychain/Keystore)      │
│  • No tokens in URLs or logs                            │
├─────────────────────────────────────────────────────────┤
│  Layer 5: Infrastructure Controls                       │
│  • Rate limiting on auth endpoints                      │
│  • WAF rules for JWT-specific attacks                   │
│  • Network segmentation for auth servers                │
│  • Key management in HSM/KMS                            │
├─────────────────────────────────────────────────────────┤
│  Layer 6: Monitoring & Response                         │
│  • Token reuse detection alerts                         │
│  • Anomalous auth pattern detection                     │
│  • Mass revocation capability                           │
│  • Incident response playbooks                          │
└─────────────────────────────────────────────────────────┘
```

### Implementation checklist

```yaml
# security-checklist.yml — validate before deployment
transport:
  - tls_version: "1.3"             # Minimum TLS 1.3
  - hsts_max_age: 31536000         # 1 year
  - hsts_preload: true
  - hsts_include_subdomains: true

token_construction:
  - algorithm: "ES256"             # or RS256
  - access_token_ttl: "15m"
  - refresh_token_ttl: "7d"
  - include_jti: true
  - include_iat: true
  - include_nbf: true
  - no_pii_in_claims: true         # No email, name, phone in access token

validation:
  - algorithm_allowlist: ["ES256"]
  - validate_iss: true
  - validate_aud: true
  - validate_exp: true
  - clock_tolerance: "30s"
  - check_revocation: true

storage:
  - browser_access_token: "memory"
  - browser_refresh_token: "httponly_cookie"
  - cookie_secure: true
  - cookie_samesite: "strict"
  - mobile: "platform_keychain"

infrastructure:
  - rate_limit_login: "10/min per IP"
  - rate_limit_refresh: "30/min per user"
  - key_storage: "kms"             # AWS KMS, GCP KMS, Azure Key Vault, or HashiCorp Vault
  - key_rotation_interval: "90d"
```

---

## Content Security Policy for Token-Bearing SPAs

SPAs that manage JWTs in JavaScript are XSS targets. A strong CSP is the primary defense against XSS-based token theft.

### Recommended CSP for JWT-bearing SPAs

```
Content-Security-Policy:
  default-src 'none';
  script-src 'self';
  style-src 'self';
  img-src 'self' data:;
  font-src 'self';
  connect-src 'self' https://api.example.com;
  frame-ancestors 'none';
  base-uri 'self';
  form-action 'self';
  require-trusted-types-for 'script';
```

### Critical directives for token security

```javascript
// Express middleware
app.use((req, res, next) => {
  // Generate nonce per request for any inline scripts
  const nonce = crypto.randomBytes(16).toString('base64');
  res.locals.nonce = nonce;

  res.setHeader('Content-Security-Policy', [
    "default-src 'none'",
    `script-src 'self' 'nonce-${nonce}'`,     // No 'unsafe-inline', no 'unsafe-eval'
    "style-src 'self' 'unsafe-inline'",        // Inline styles are lower risk
    "connect-src 'self' https://api.example.com",  // Restrict where XHR/fetch can go
    "frame-ancestors 'none'",                   // Prevent clickjacking
    "base-uri 'self'",                          // Prevent base tag hijacking
    "form-action 'self'",                       // Prevent form data exfiltration
    "require-trusted-types-for 'script'"        // Trusted Types — prevents DOM XSS
  ].join('; '));

  next();
});
```

### Why each directive matters for JWT security

| Directive | Prevents | JWT Relevance |
|-----------|----------|---------------|
| `script-src 'self'` (no `unsafe-inline`) | XSS via injected scripts | Attacker can't run JS to steal in-memory tokens |
| `connect-src` restricted | Data exfiltration | Stolen token can't be sent to attacker's server |
| `frame-ancestors 'none'` | Clickjacking | Prevents framing to trick users into auth actions |
| `require-trusted-types-for 'script'` | DOM XSS | Blocks `innerHTML`, `eval` — common XSS vectors |

### Trusted Types for DOM XSS prevention

```javascript
// Define a Trusted Types policy — only this policy can create injectable HTML
if (window.trustedTypes?.createPolicy) {
  const escapePolicy = trustedTypes.createPolicy('default', {
    createHTML: (input) => DOMPurify.sanitize(input),
    createScriptURL: (input) => {
      if (new URL(input).origin === location.origin) return input;
      throw new TypeError('Blocked script URL: ' + input);
    }
  });
}
```

### CSP reporting for token theft detection

```
Content-Security-Policy-Report-Only:
  default-src 'self';
  report-uri /api/csp-report;
  report-to csp-endpoint;
```

```javascript
// Monitor CSP violations — may indicate XSS attempts targeting tokens
app.post('/api/csp-report', express.json({ type: 'application/csp-report' }), (req, res) => {
  const violation = req.body['csp-report'];
  logger.warn('CSP violation', {
    blockedUri: violation['blocked-uri'],
    violatedDirective: violation['violated-directive'],
    documentUri: violation['document-uri'],
    // Alert if connect-src violated — may be token exfiltration attempt
    severity: violation['violated-directive'].startsWith('connect-src') ? 'HIGH' : 'MEDIUM'
  });
  res.sendStatus(204);
});
```

---

## Rate Limiting Auth Endpoints

Auth endpoints are high-value targets. Rate limit aggressively — legitimate users rarely trigger limits.

### Endpoint-specific limits

| Endpoint | Limit | Window | Key | Rationale |
|----------|-------|--------|-----|-----------|
| `POST /login` | 10 | 1 min | IP | Credential stuffing prevention |
| `POST /login` | 5 | 1 min | username | Account-specific brute force |
| `POST /refresh` | 30 | 1 min | user_id | Refresh shouldn't be rapid |
| `POST /token` (OAuth) | 20 | 1 min | client_id | Client credential abuse |
| `POST /introspect` | 100 | 1 min | client_id | Higher limit for machine-to-machine |
| `POST /revoke` | 50 | 1 min | user_id | Legitimate mass logout scenario |
| `GET /.well-known/jwks.json` | 100 | 1 min | IP | Prevent DoS on key endpoint |

### Implementation with sliding window (Redis)

```python
import redis, time, hashlib

r = redis.Redis()

def rate_limit(key: str, limit: int, window_seconds: int) -> bool:
    """Sliding window rate limiter. Returns True if request is allowed."""
    now = time.time()
    pipeline = r.pipeline()

    # Remove entries outside the window
    pipeline.zremrangebyscore(key, 0, now - window_seconds)
    # Add current request
    pipeline.zadd(key, {f"{now}:{hashlib.md5(str(now).encode()).hexdigest()[:8]}": now})
    # Count requests in window
    pipeline.zcard(key)
    # Set expiry on the key itself
    pipeline.expire(key, window_seconds)

    results = pipeline.execute()
    request_count = results[2]

    return request_count <= limit

# Usage in middleware
def login_rate_limit(request):
    ip_key = f"rl:login:ip:{request.remote_addr}"
    user_key = f"rl:login:user:{request.json.get('username', 'unknown')}"

    if not rate_limit(ip_key, limit=10, window_seconds=60):
        raise TooManyRequestsError("Too many login attempts from this IP")

    if not rate_limit(user_key, limit=5, window_seconds=60):
        raise TooManyRequestsError("Too many login attempts for this account")
```

### Node.js with `express-rate-limit`

```javascript
import rateLimit from 'express-rate-limit';
import RedisStore from 'rate-limit-redis';

const loginLimiter = rateLimit({
  store: new RedisStore({ sendCommand: (...args) => redisClient.sendCommand(args) }),
  windowMs: 60 * 1000,         // 1 minute
  max: 10,                      // 10 requests per window
  standardHeaders: true,        // Return rate limit info in headers
  legacyHeaders: false,
  keyGenerator: (req) => req.ip,
  handler: (req, res) => {
    res.status(429).json({
      error: 'too_many_requests',
      message: 'Too many login attempts. Try again later.',
      retry_after: Math.ceil(req.rateLimit.resetTime / 1000)
    });
  }
});

const refreshLimiter = rateLimit({
  store: new RedisStore({ sendCommand: (...args) => redisClient.sendCommand(args) }),
  windowMs: 60 * 1000,
  max: 30,
  keyGenerator: (req) => {
    // Rate limit by user ID extracted from the refresh token
    try {
      const claims = decodeRefreshToken(req.body.refresh_token);
      return `refresh:${claims.sub}`;
    } catch {
      return `refresh:${req.ip}`;
    }
  }
});

app.post('/auth/login', loginLimiter, loginHandler);
app.post('/auth/refresh', refreshLimiter, refreshHandler);
```

### Progressive delays (exponential backoff)

```python
def get_login_delay(username: str) -> float:
    """Exponentially increase delay after failed attempts."""
    failures = int(r.get(f"login_failures:{username}") or 0)
    if failures == 0:
        return 0
    # 1s, 2s, 4s, 8s, 16s, max 30s
    return min(2 ** (failures - 1), 30)

def record_login_failure(username: str):
    key = f"login_failures:{username}"
    r.incr(key)
    r.expire(key, 3600)  # Reset after 1 hour of no failures

def record_login_success(username: str):
    r.delete(f"login_failures:{username}")
```

---

## Brute-Force Protection for Token Secrets

### HS256 secret strength

HS256 uses HMAC-SHA256 — the secret must be at least 256 bits (32 bytes) to match the algorithm's security level. Shorter secrets can be brute-forced.

```python
import secrets

# WRONG: weak secrets
secret = "mysecret"                    # 8 bytes, trivially brute-forced
secret = "my-jwt-secret-key-2025"      # Dictionary words, weak

# CORRECT: cryptographically random 256-bit secret
secret = secrets.token_hex(32)         # 64 hex chars = 256 bits
secret = secrets.token_urlsafe(32)     # 43 base64url chars ≈ 256 bits

# Store in environment, never in code
# export JWT_SECRET=$(openssl rand -hex 32)
```

### Offline brute-force attacks on HS256

If an attacker obtains a valid JWT signed with HS256, they can attempt offline brute-force:

```bash
# Attacker's approach (for awareness — not instructions)
# hashcat can crack weak HS256 secrets at ~1 billion attempts/sec on modern GPUs
# A 10-character alphanumeric secret: cracked in hours
# A 32-byte random secret: 2^256 attempts — computationally infeasible
```

**Mitigations:**

1. Use secrets ≥ 256 bits, cryptographically random.
2. Prefer asymmetric algorithms (RS256, ES256) — no shared secret to brute-force.
3. Rotate secrets periodically — limits the window for offline attacks.
4. Keep tokens short-lived — reduces the value of cracking an old secret.

### Protection at the infrastructure level

```yaml
# HashiCorp Vault: generate and manage JWT signing keys
# vault write auth/jwt/config \
#   jwt_signing_key_size=256 \
#   rotation_period=2160h    # 90 days

# AWS KMS: use a KMS key for HMAC signing
# aws kms create-key --key-spec HMAC_256 --key-usage GENERATE_VERIFY_MAC
```

---

## Log Safety — Tokens and Sensitive Data

### What to log

```json
{
  "event": "token_validated",
  "timestamp": "2025-07-01T12:00:00Z",
  "user_id": "user_921",
  "token_jti": "abc123",
  "token_iss": "auth.example.com",
  "token_exp": "2025-07-01T12:15:00Z",
  "client_ip": "192.168.1.100",
  "user_agent_hash": "sha256:a1b2c3...",
  "request_path": "/api/users",
  "result": "success"
}
```

### What NEVER to log

```python
# NEVER log these:
logger.info(f"Token: {token}")                    # Full token = credential leak
logger.info(f"Authorization: {request.headers}")   # Contains Bearer token
logger.info(f"Refresh token: {refresh_token}")     # Long-lived credential
logger.info(f"Cookie: {request.cookies}")           # May contain token
logger.info(f"Request body: {request.body}")        # May contain credentials
logger.info(f"JWT secret: {secret}")                # Signing key
logger.debug(f"Decoded payload: {payload}")         # May contain PII
```

### Implementing log sanitization

```python
import re

SENSITIVE_PATTERNS = [
    (re.compile(r'(Bearer\s+)[A-Za-z0-9\-_\.]+'), r'\1[REDACTED]'),
    (re.compile(r'(eyJ[A-Za-z0-9\-_]+\.eyJ[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]+)'), '[JWT_REDACTED]'),
    (re.compile(r'(refresh_token["\s:=]+)[^\s,}"]+'), r'\1[REDACTED]'),
    (re.compile(r'(password["\s:=]+)[^\s,}"]+'), r'\1[REDACTED]'),
    (re.compile(r'(secret["\s:=]+)[^\s,}"]+'), r'\1[REDACTED]'),
]

class SanitizingFormatter(logging.Formatter):
    def format(self, record):
        message = super().format(record)
        for pattern, replacement in SENSITIVE_PATTERNS:
            message = pattern.sub(replacement, message)
        return message

# Apply to all handlers
formatter = SanitizingFormatter('%(asctime)s %(levelname)s %(message)s')
for handler in logging.root.handlers:
    handler.setFormatter(formatter)
```

```javascript
// Express middleware: sanitize request logs
function sanitizeForLogging(obj) {
  const sanitized = { ...obj };
  const sensitiveKeys = ['authorization', 'cookie', 'x-api-key', 'refresh_token', 'password'];

  for (const key of Object.keys(sanitized)) {
    if (sensitiveKeys.includes(key.toLowerCase())) {
      sanitized[key] = '[REDACTED]';
    }
  }
  return sanitized;
}

app.use((req, res, next) => {
  logger.info({
    method: req.method,
    path: req.path,
    headers: sanitizeForLogging(req.headers),
    // Never log req.body for auth endpoints
    body: req.path.startsWith('/auth/') ? '[REDACTED]' : req.body
  });
  next();
});
```

### Log aggregation safety

```yaml
# Ensure your log pipeline doesn't capture tokens:
# - Nginx access logs: don't log Authorization header
# - AWS ALB access logs: include token by default — disable or mask
# - Datadog/Splunk: create processing rules to redact JWT patterns

# Nginx: custom log format without Authorization
log_format safe_format '$remote_addr - $remote_user [$time_local] '
                       '"$request" $status $body_bytes_sent '
                       '"$http_referer"';
# Default combined format includes full request headers — avoid it
```

---

## OWASP JWT Cheat Sheet Recommendations

Summary of [OWASP JWT Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/JSON_Web_Token_for_Java_Cheat_Sheet.html) with implementation guidance.

### 1. Algorithm pinning

```python
# ALWAYS specify the expected algorithm — never rely on the token's header
payload = jwt.decode(token, key, algorithms=["ES256"])  # Pinned

# NEVER do this:
payload = jwt.decode(token, key)  # Accepts whatever the token says — vulnerable
```

### 2. Token integrity: use strong keys

| Algorithm | Minimum Key Size |
|-----------|-----------------|
| HS256 | 256-bit (32-byte) secret |
| HS384 | 384-bit (48-byte) secret |
| HS512 | 512-bit (64-byte) secret |
| RS256 | 2048-bit RSA key (prefer 4096) |
| ES256 | P-256 curve |

### 3. Mandatory claim validation

```javascript
// Every verification MUST check these:
const { payload } = await jwtVerify(token, key, {
  algorithms: ['ES256'],               // Pin algorithm
  issuer: 'https://auth.example.com',  // Exact match
  audience: 'https://api.example.com', // Exact match
  clockTolerance: 30,                  // Max 30s skew
  // exp and nbf are checked automatically by most libraries
});

// Additionally validate:
if (!payload.jti) throw new Error('Missing jti');
if (!payload.sub) throw new Error('Missing sub');
```

### 4. Token lifetime limits

| Token Type | Maximum Lifetime | Rationale |
|------------|-----------------|-----------|
| Access token | 15 minutes | Limits window if stolen |
| Refresh token | 7–14 days | Balance security with UX |
| ID token (OIDC) | 1 hour | Identity assertion, not for API auth |
| One-time token (email verify, password reset) | 15–60 minutes | Single use, short window |

### 5. Input validation on token parsing

```python
def safe_decode(token: str, key, algorithms: list) -> dict:
    # Reject obviously malformed tokens before crypto operations
    if not isinstance(token, str):
        raise ValueError("Token must be a string")
    if len(token) > 10_000:  # No legitimate JWT is this large
        raise ValueError("Token exceeds maximum length")
    if token.count('.') != 2:
        raise ValueError("Malformed JWT structure")

    # Now decode with full validation
    return jwt.decode(token, key, algorithms=algorithms,
                      audience="api.example.com",
                      issuer="auth.example.com")
```

### 6. Avoid JWT for sessions when possible

OWASP recommends using server-side sessions for web applications when you can. JWTs are appropriate for:
- Stateless API authentication
- Microservice-to-microservice auth
- Short-lived, scoped access tokens

JWTs are NOT ideal for:
- Long-lived browser sessions (use server-side sessions + cookies)
- Storing large amounts of user state

---

## Security Headers for Auth Endpoints

### Recommended headers for all auth responses

```javascript
function authSecurityHeaders(req, res, next) {
  // Prevent caching of auth responses
  res.set({
    'Cache-Control': 'no-store, no-cache, must-revalidate, private',
    'Pragma': 'no-cache',
    'Expires': '0',

    // Prevent MIME sniffing
    'X-Content-Type-Options': 'nosniff',

    // Clickjacking protection (supplement to frame-ancestors CSP)
    'X-Frame-Options': 'DENY',

    // XSS protection (legacy browsers)
    'X-XSS-Protection': '0',  // Disabled — can cause info leaks; rely on CSP instead

    // Prevent referrer leakage of tokens
    'Referrer-Policy': 'strict-origin-when-cross-origin',

    // Permissions policy — restrict browser features
    'Permissions-Policy': 'camera=(), microphone=(), geolocation=()',
  });

  next();
}

app.use('/auth/*', authSecurityHeaders);
app.use('/oauth/*', authSecurityHeaders);
app.use('/.well-known/*', authSecurityHeaders);
```

### HSTS for auth domains

```
Strict-Transport-Security: max-age=31536000; includeSubDomains; preload
```

```javascript
// Force HTTPS redirect at application level (defense-in-depth)
app.use((req, res, next) => {
  if (req.header('x-forwarded-proto') !== 'https' && process.env.NODE_ENV === 'production') {
    return res.redirect(301, `https://${req.hostname}${req.url}`);
  }
  next();
});
```

### Cache-Control is critical

Auth endpoints MUST return `Cache-Control: no-store`. Without this:

- Proxies may cache responses containing tokens.
- Browser back/forward cache may expose tokens.
- CDNs may serve cached tokens to different users.

```python
# FastAPI: ensure no caching on auth endpoints
from fastapi import Response

@app.post("/auth/login")
async def login(response: Response):
    response.headers["Cache-Control"] = "no-store"
    response.headers["Pragma"] = "no-cache"
    # ... issue tokens
```

### JWKS endpoint headers

```javascript
// JWKS is public data but should be cacheable and protected from abuse
app.get('/.well-known/jwks.json', (req, res) => {
  res.set({
    'Cache-Control': 'public, max-age=3600',  // Cache for 1 hour
    'Content-Type': 'application/json',
    'X-Content-Type-Options': 'nosniff',
    'Access-Control-Allow-Origin': '*',        // JWKS is intentionally public
  });
  res.json(jwksData);
});
```

---

## Monitoring and Alerting on Suspicious Token Patterns

### What to monitor

#### 1. Refresh token reuse (critical)

Refresh token reuse indicates a stolen token. Both the legitimate user and attacker have the same token — one will attempt to use it after it's been rotated.

```python
# In refresh endpoint
def handle_refresh(refresh_token: str):
    record = db.get_refresh_token(refresh_token)

    if record and record.revoked:
        # ALERT: Token reuse detected — potential compromise
        alert.critical("refresh_token_reuse", {
            "user_id": record.user_id,
            "token_family": record.family_id,
            "original_issued_at": record.created_at,
            "reuse_ip": request.remote_addr,
            "original_ip": record.issued_to_ip,
        })

        # Revoke entire token family
        db.revoke_token_family(record.family_id)
        raise AuthError("Session compromised")
```

#### 2. Abnormal token velocity

```python
# Alert if a user's tokens are being refreshed too frequently
def check_refresh_velocity(user_id: str):
    key = f"refresh_count:{user_id}"
    count = r.incr(key)
    r.expire(key, 3600)  # 1-hour window

    if count > 50:  # More than 50 refreshes/hour is suspicious
        alert.warn("high_refresh_velocity", {
            "user_id": user_id,
            "count_per_hour": count,
            "threshold": 50,
        })
```

#### 3. Geographic impossibility

```python
def check_geo_anomaly(user_id: str, current_ip: str):
    last_auth = db.get_last_auth_event(user_id)
    if not last_auth:
        return

    current_location = geoip.lookup(current_ip)
    last_location = geoip.lookup(last_auth.ip)

    # Calculate if travel between locations is physically possible
    distance_km = haversine(current_location, last_location)
    time_diff_hours = (time.time() - last_auth.timestamp) / 3600
    max_possible_km = time_diff_hours * 1000  # ~1000 km/h (fast jet)

    if distance_km > max_possible_km:
        alert.warn("impossible_travel", {
            "user_id": user_id,
            "from": last_location,
            "to": current_location,
            "distance_km": distance_km,
            "time_hours": time_diff_hours,
        })
```

#### 4. Token farms (mass token generation)

```python
# Alert on unusual volume of token issuance
def monitor_token_issuance():
    # Per-IP: detect credential stuffing
    ip_count = r.incr(f"tokens_issued:ip:{request.remote_addr}")
    r.expire(f"tokens_issued:ip:{request.remote_addr}", 300)
    if ip_count > 100:  # 100 tokens from one IP in 5 min
        alert.critical("token_farm_detected", {
            "ip": request.remote_addr,
            "count": ip_count,
            "window": "5m",
        })

    # Global: detect broad attacks
    global_count = r.incr("tokens_issued:global")
    r.expire("tokens_issued:global", 60)
    if global_count > 1000:  # 1000 tokens/min globally
        alert.critical("mass_token_issuance", {
            "count": global_count,
            "window": "1m",
        })
```

### Structured alert events

```javascript
// Standardized auth event schema for SIEM integration
const authEvent = {
  timestamp: new Date().toISOString(),
  event_type: 'auth.token.refresh_reuse',     // Dot-separated category
  severity: 'critical',                         // info, warn, critical
  user_id: claims.sub,
  session_id: claims.jti,
  client: {
    ip: req.ip,
    user_agent_hash: hashUA(req.headers['user-agent']),
    geo: geoLookup(req.ip),
  },
  details: {
    token_family: familyId,
    reuse_count: reuseCount,
    original_ip: originalIp,
  },
  action_taken: 'family_revoked',
};

// Send to SIEM (Splunk, Elastic, Datadog)
siem.emit(authEvent);
```

### Dashboard metrics

| Metric | Alert Threshold | Severity |
|--------|----------------|----------|
| Failed token validations / min | > 100 per service | warn |
| Refresh token reuse events | > 0 | critical |
| Login failures / IP / hour | > 50 | warn |
| Tokens issued / min (global) | > 500 (adjust to baseline) | warn |
| Distinct IPs per user / hour | > 10 | warn |
| `alg: none` attempts | > 0 | critical |
| Unknown `kid` in token header | > 10 / min | warn |

---

## Incident Response: Mass Token Revocation

When a signing key is compromised or a widespread token theft is discovered, you need to revoke all tokens immediately.

### Scenario 1: Signing key compromised

All tokens signed with the compromised key are potentially forged. You cannot trust any of them.

```python
# Emergency key rotation procedure
def emergency_key_rotation(compromised_kid: str):
    # 1. Generate new key pair immediately
    new_kid, new_private, new_public = generate_key_pair()

    # 2. Remove compromised public key from JWKS (stop accepting tokens signed with it)
    jwks_store.remove_key(compromised_kid)

    # 3. Add new public key to JWKS
    jwks_store.add_key(new_kid, new_public)

    # 4. Switch signing to new key
    config.set_signing_key(new_kid, new_private)

    # 5. Invalidate ALL refresh tokens (force everyone to re-login)
    db.execute("UPDATE refresh_tokens SET revoked = TRUE WHERE signing_kid = %s",
               compromised_kid)

    # 6. Increment global token version (for version-based validation)
    db.execute("UPDATE system_config SET value = value + 1 WHERE key = 'global_token_version'")

    # 7. Flush JWKS caches across all services
    publish_event("jwks_invalidate", {"compromised_kid": compromised_kid})

    # 8. Alert security team
    alert.critical("signing_key_compromised", {
        "kid": compromised_kid,
        "action": "emergency_rotation",
        "all_tokens_invalidated": True,
    })

    # 9. Log for audit
    audit_log.record("INCIDENT", f"Signing key {compromised_kid} compromised and rotated")
```

### Scenario 2: Mass account compromise (credential stuffing)

```python
def mass_revocation_by_user_list(compromised_user_ids: list[str]):
    # 1. Revoke all refresh tokens for affected users
    db.execute(
        "UPDATE refresh_tokens SET revoked = TRUE WHERE user_id = ANY(%s)",
        compromised_user_ids
    )

    # 2. Increment token version for each user
    db.execute(
        "UPDATE users SET token_version = token_version + 1 WHERE id = ANY(%s)",
        compromised_user_ids
    )

    # 3. Add all active JTIs to blocklist
    active_jtis = db.query(
        "SELECT jti, exp FROM active_tokens WHERE user_id = ANY(%s)",
        compromised_user_ids
    )
    for jti, exp in active_jtis:
        ttl = max(exp - int(time.time()), 0)
        if ttl > 0:
            redis.setex(f"revoked:{jti}", ttl, "1")

    # 4. Force password reset
    db.execute(
        "UPDATE users SET must_reset_password = TRUE WHERE id = ANY(%s)",
        compromised_user_ids
    )

    # 5. Notify users
    for user_id in compromised_user_ids:
        notification_service.send(user_id, "security_alert", {
            "message": "Suspicious activity detected. Your sessions have been terminated.",
            "action_required": "Reset your password."
        })
```

### Scenario 3: Global emergency (complete system compromise)

```python
def global_token_revocation():
    """Nuclear option: invalidate ALL tokens across the entire system."""

    # 1. Increment global token epoch
    new_epoch = db.execute(
        "UPDATE system_config SET value = value + 1 WHERE key = 'token_epoch' RETURNING value"
    ).scalar()

    # 2. All token validation must now check: token.epoch == current_epoch
    # Tokens without the epoch claim or with old epoch are rejected

    # 3. Revoke ALL refresh tokens
    count = db.execute("UPDATE refresh_tokens SET revoked = TRUE WHERE revoked = FALSE").rowcount

    # 4. Rotate all signing keys
    emergency_key_rotation(current_signing_kid)

    # 5. Publish cache invalidation to all services
    publish_event("global_token_revocation", {
        "new_epoch": new_epoch,
        "timestamp": datetime.utcnow().isoformat(),
        "revoked_refresh_tokens": count,
    })

    logger.critical(f"GLOBAL TOKEN REVOCATION: epoch={new_epoch}, revoked={count} refresh tokens")
```

### Token epoch validation

```python
# Add epoch checking to validation middleware
CURRENT_EPOCH = int(db.get_config("token_epoch"))

def validate_token(token: str) -> dict:
    payload = jwt.decode(token, key, algorithms=["ES256"],
                         audience="api.example.com",
                         issuer="auth.example.com")

    # Check token epoch
    token_epoch = payload.get("epoch", 0)
    if token_epoch < CURRENT_EPOCH:
        raise AuthError("Token invalidated by global revocation")

    return payload

# Include epoch in token issuance
def issue_token(user_id: str) -> str:
    return jwt.encode({
        "sub": user_id,
        "epoch": CURRENT_EPOCH,
        "exp": datetime.utcnow() + timedelta(minutes=15),
        # ... other claims
    }, private_key, algorithm="ES256")
```

### Communication template

```markdown
## Security Incident: Token Revocation Notice

**Severity:** [Critical/High]
**Time of Detection:** [ISO timestamp]
**Affected Users:** [Count or "All users"]

### What Happened
[Brief description without exposing implementation details]

### Actions Taken
1. All active sessions have been terminated.
2. Signing keys have been rotated.
3. Affected users must re-authenticate.
[4. Password resets required (if applicable)]

### User Impact
- All users will need to log in again.
- No further action required unless notified of password reset.

### Internal Follow-up
- [ ] Post-incident review scheduled
- [ ] Root cause analysis
- [ ] Control improvements identified
```

---

## Compliance Considerations

### GDPR and PII in tokens

JWTs are base64url-encoded — NOT encrypted. Any PII in a JWT payload is readable by anyone who intercepts the token.

#### What counts as PII in tokens

| Claim | PII? | Recommendation |
|-------|------|----------------|
| `sub` (opaque user ID) | No (if opaque) | Safe — use UUIDs, not emails |
| `email` | Yes | Remove from access tokens — use `sub` + server-side lookup |
| `name` | Yes | Remove from access tokens |
| `phone` | Yes | Never include in tokens |
| `role`, `permissions` | No | Safe |
| `tenant_id` | Possibly | Safe if it's an opaque ID, not a company name |
| `ip` | Yes (in GDPR context) | Don't embed client IP in tokens |

#### GDPR-compliant token design

```json
// WRONG: PII in access token
{
  "sub": "john.doe@example.com",
  "name": "John Doe",
  "email": "john.doe@example.com",
  "phone": "+1-555-0100",
  "role": "admin"
}

// CORRECT: opaque identifiers only
{
  "sub": "usr_a1b2c3d4",
  "role": "admin",
  "tid": "tenant_x9y8z7"
}
// API resolves PII from sub via server-side lookup when needed
```

#### Right to be forgotten and JWTs

```python
# When a user exercises their right to erasure:
def handle_gdpr_erasure(user_id: str):
    # 1. Revoke all tokens immediately (they contain the user's sub)
    revoke_all_user_tokens(user_id)

    # 2. Tokens already issued will expire naturally (they only contain sub)
    # If tokens contained PII, you'd need to wait for all to expire
    # or maintain a blocklist until expiry

    # 3. Delete user data from all systems
    delete_user_data(user_id)

    # 4. Log the erasure (for compliance audit)
    audit_log.record("GDPR_ERASURE", user_id=user_id, timestamp=datetime.utcnow())
```

### SOC 2 key management requirements

SOC 2 Type II requires demonstrable controls around cryptographic key management.

#### Key management controls

```yaml
# SOC 2 key management policy (document and enforce)
key_management:
  generation:
    - method: "Hardware Security Module (HSM) or cloud KMS"
    - minimum_key_size:
        rsa: 2048           # Prefer 4096
        ec: "P-256"
        hmac: 256            # bits
    - entropy_source: "CSPRNG (OS-provided)"

  storage:
    - private_keys: "HSM, AWS KMS, GCP Cloud KMS, or Azure Key Vault"
    - never_in: "source code, environment variables in plaintext, configuration files"
    - access_control: "Minimum necessary personnel with audit trail"

  rotation:
    - schedule: "Every 90 days or on suspected compromise"
    - procedure: "Documented runbook with overlap period"
    - audit_trail: "Log all rotation events with who/when/why"

  destruction:
    - method: "Cryptographic erasure via KMS key deletion"
    - retention: "Maintain audit logs of destroyed keys for 7 years"
    - verification: "Confirm key is irrecoverable after destruction"

  access_audit:
    - frequency: "Quarterly access review"
    - logging: "All key access operations logged to SIEM"
    - alerting: "Alert on unauthorized key access attempts"
```

#### Implementing auditable key operations

```python
class AuditedKeyManager:
    def __init__(self, kms_client, audit_logger):
        self.kms = kms_client
        self.audit = audit_logger

    def create_signing_key(self, kid: str, algorithm: str, requested_by: str) -> str:
        key_id = self.kms.create_key(
            KeySpec='ECC_NIST_P256' if algorithm == 'ES256' else 'RSA_2048',
            KeyUsage='SIGN_VERIFY',
            Tags=[{'Key': 'kid', 'Value': kid}]
        )
        self.audit.log({
            'action': 'key_created',
            'kid': kid,
            'algorithm': algorithm,
            'kms_key_id': key_id,
            'requested_by': requested_by,
            'timestamp': datetime.utcnow().isoformat(),
        })
        return key_id

    def rotate_key(self, old_kid: str, new_kid: str, reason: str, requested_by: str):
        new_key_id = self.create_signing_key(new_kid, 'ES256', requested_by)
        self.audit.log({
            'action': 'key_rotated',
            'old_kid': old_kid,
            'new_kid': new_kid,
            'reason': reason,
            'requested_by': requested_by,
            'timestamp': datetime.utcnow().isoformat(),
        })
        return new_key_id

    def schedule_key_destruction(self, kid: str, days: int, requested_by: str):
        self.kms.schedule_key_deletion(KeyId=kid, PendingWindowInDays=days)
        self.audit.log({
            'action': 'key_destruction_scheduled',
            'kid': kid,
            'destruction_date': (datetime.utcnow() + timedelta(days=days)).isoformat(),
            'requested_by': requested_by,
            'timestamp': datetime.utcnow().isoformat(),
        })
```

### PCI DSS considerations

If tokens are used in payment flows:

- Tokens must NOT contain cardholder data (PAN, CVV, expiry).
- Token validation endpoints must be in the Cardholder Data Environment (CDE) if they process payment data.
- Key management must follow PCI DSS Requirement 3.5–3.7 (cryptographic key lifecycle).
- Token transmission must use TLS 1.2+ (Requirement 4.1).

### HIPAA considerations

If tokens are used in healthcare applications:

- Tokens must NOT contain Protected Health Information (PHI) — patient names, diagnoses, MRNs.
- If PHI must be in a token (rare, discouraged), use JWE (encrypted tokens).
- Audit all token issuance and validation events (access logging requirement).
- Implement automatic session termination (token expiry) — HIPAA §164.312(a)(2)(iii).
