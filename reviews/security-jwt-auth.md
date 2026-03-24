# Review: jwt-auth

Accuracy: 4/5
Completeness: 5/5
Actionability: 4/5
Trigger quality: 5/5
Overall: 4.5/5

Issues:

## Structure ✅

- YAML frontmatter has `name` and `description` ✅
- Description includes positive triggers (12 trigger phrases) AND negative triggers (8 exclusions) ✅
- SKILL.md body: 455 lines (under 500 limit) ✅
- Imperative voice, no filler ✅
- Examples with input/output (login, refresh, expired, authenticated call) ✅
- `references/`, `scripts/`, and `assets/` all linked from SKILL.md with relative paths ✅

## Content Issues

### 1. `scripts/decode-jwt.sh` — ANALYSIS section produces no output (BUG)

**Severity: High**

Lines 131–203 use `python3 << 'PYEOF'` inside a piped `if...fi` block. The heredoc
uses literal placeholder strings (`PAYLOAD_PLACEHOLDER`, `TOKEN_PLACEHOLDER`) intended to be
replaced by `sed` after the block. However, `python3 << 'PYEOF'` *runs* the Python script
(which fails on `json.loads('''PAYLOAD_PLACEHOLDER''')` and exits), rather than echoing it.
The `sed | python3` pipeline on line 203 receives empty input.

**Result:** The "▸ ANALYSIS" section (expiry status, issuer, subject, token size) is always
blank. Confirmed by running the script with a test JWT.

**Fix:** Change `python3 << 'PYEOF'` to `cat << 'PYEOF'` on line 131 so the script text is
echoed to stdout for sed substitution before being piped to the final `python3`.

### 2. `scripts/generate-keys.sh` — `$2` parameter conflict (BUG)

**Severity: Medium**

Line 22 assigns `OUTPUT_DIR="${2:-keys}"`, but the `rs256` case on line 192 also uses
`"${2:-2048}"` as the RSA key size. Running `./generate-keys.sh rs256 4096` sets
`OUTPUT_DIR=4096` (creating a directory named "4096") while correctly passing 4096 as bits.

**Fix:** Use a dedicated flag or positional argument for output directory, separate from the
algorithm-specific bits parameter.

### 3. SKILL.md Node.js refresh endpoint — `decoded.roles` is undefined (BUG)

**Severity: Medium**

Line 234: `generateTokens({ id: decoded.sub, roles: decoded.roles })` reads `roles` from the
decoded refresh token. But the refresh token payload (lines 199–200) only contains `sub` and
`jti` — no `roles` claim. After refresh, the new access token would have `roles: undefined`,
effectively stripping the user's permissions.

The asset template `middleware-express.js` correctly handles this with
`const user = { id: storedToken.userId, roles: [] }; // Fetch roles from DB`. The inline
SKILL.md example should match.

### 4. SKILL.md Python example — undefined `app` variable (MINOR)

**Severity: Low**

Line 292: `@app.route("/auth/refresh", methods=["POST"])` references `app` which is never
instantiated in the example. Should add `app = Flask(__name__)` or note it's a snippet.

### 5. Node.js library inconsistency (MINOR)

**Severity: Low**

The SKILL.md inline Node.js example (lines 179–245) uses `jsonwebtoken`, while:
- `references/security-checklist.md` (line 295) recommends `jose` as preferred
- `assets/middleware-express.js` uses `jose`

Web search confirms `jose` is the current recommendation for new Node.js projects (ESM
support, broader algorithm coverage, active maintenance). The inline example should either
use `jose` or note that `jsonwebtoken` is the legacy option.

## Content Verified ✅

- **RFC 7519 claims** (iss, sub, aud, exp, nbf, iat, jti): All 7 registered claims correctly
  described with accurate purposes. Confirmed against RFC and IANA registry.
- **RFC 8693 token exchange**: Correctly referenced in advanced-patterns.md.
- **Signing algorithms**: HS256/RS256/ES256/EdDSA descriptions accurate. Correct minimum key
  sizes (256-bit HMAC, 2048-bit RSA, P-256 curve).
- **golang-jwt/jwt/v5 API**: `ParseWithClaims`, `WithValidMethods`, `WithIssuer`,
  `WithLeeway`, `SigningMethodHS256` — all verified against current API docs.
- **PyJWT API**: `jwt.decode()` with `algorithms`, `options.require`, `leeway`, `issuer`,
  `audience` — all correct per PyJWT 2.x docs.
- **Security vulnerabilities**: `alg:none` attack, RS256→HS256 confusion, `kid` injection,
  weak HMAC secrets — all accurately described with correct mitigations.
- **Token storage guidance**: httpOnly/Secure/SameSite cookie recommendations align with OWASP
  best practices.
- **JWKS format** (`assets/jwks-endpoint.json`): Valid structure with EC, RSA, OKP, and
  encryption key entries. Correct `kty`, `crv`, `use`, `alg` values.
- **Key rotation procedure**: Correct 5-step process with grace period.

## Missing Gotchas (minor)

- No mention of JWS header injection via unvalidated `typ` claim (RFC 8725 §3.11).
- No warning about refresh token race conditions in SPAs with concurrent requests (covered in
  troubleshooting.md but not in main SKILL.md).
- Asset templates' `TokenStore` classes throw `NotImplementedError` — an AI copying verbatim
  would get runtime errors. Could add in-memory implementations for development/testing.

## Trigger Quality ✅

- **Would trigger for JWT auth queries**: Yes — 12 positive trigger phrases cover the JWT
  vocabulary comprehensively ("JWT token", "bearer token", "refresh token rotation",
  "JWT middleware", "stateless authentication", etc.).
- **Would falsely trigger for session-based auth?**: No — explicitly excluded: "session-based
  auth without tokens", "cookie-only session management".
- **Would falsely trigger for OAuth2 server setup?**: No — explicitly excluded: "OAuth2
  authorization server setup", "OpenID Connect provider implementation".
- **Edge case**: An OAuth2 resource server using JWT bearer tokens would correctly trigger this
  skill (not excluded).

## Reviewer Notes

The skill is comprehensive and well-organized. The SKILL.md covers JWT fundamentals, security
hardening, and implementation patterns at a level where an AI could implement JWT auth from
this alone. The three reference documents (advanced patterns, troubleshooting, security
checklist) provide excellent depth. The asset templates are production-quality with proper
token family tracking, reuse detection, and role-based auth.

The main issues are script bugs (decode-jwt.sh non-functional analysis, generate-keys.sh
parameter conflict) and the inline example roles bug. None affect the core instructional
content.

---

Reviewed: 2025-07-17
Verdict: **PASS** (with noted issues for fix)
