---
name: security-headers
description: >
  Use when implementing, auditing, or debugging HTTP security headers for web applications.
  Triggers: CSP, Content-Security-Policy, HSTS, Strict-Transport-Security, X-Frame-Options,
  X-Content-Type-Options, Referrer-Policy, Permissions-Policy, COOP, COEP, CORP,
  cross-origin isolation, security headers, Helmet.js, securityheaders.com, Set-Cookie
  security, cookie prefixes, __Host-, __Secure-, Cache-Control security, nonce, strict-dynamic,
  frame-ancestors, report-to, report-uri, CSP reporting, CSP bypass.
  Do NOT trigger for: general HTTP caching strategy, cookie consent banners, CORS
  preflight debugging, OAuth/OIDC token handling, TLS certificate configuration,
  SSL termination, firewall rules, WAF configuration, rate limiting headers.
---

# HTTP Security Headers

## Content-Security-Policy (CSP)

### Core Directives

Set `default-src` as fallback. Override per resource type. Always include `object-src 'none'` and `base-uri 'none'`.

Key directives: `default-src`, `script-src`, `style-src`, `img-src`, `font-src`, `connect-src`, `media-src`, `frame-src`, `frame-ancestors`, `child-src`, `worker-src`, `form-action`, `base-uri`, `object-src`, `manifest-src`.

### Nonces and Hashes

Generate a cryptographically random nonce per response. Apply to every trusted inline `<script>` and `<style>`. Never reuse nonces across responses.

```
Content-Security-Policy: script-src 'nonce-4AEemGb0xJptoIGFP3Nd' 'strict-dynamic'
```

For static inline scripts that never change, use SHA-256/384/512 hashes:

```
Content-Security-Policy: script-src 'sha256-base64encodedHash='
```

### strict-dynamic

`'strict-dynamic'` propagates trust from a nonced/hashed script to scripts it loads at runtime. When present, the browser ignores allowlist entries and `'unsafe-inline'` in `script-src`. Always pair with a nonce or hash. Provides backward-compatible fallback — older browsers ignore `'strict-dynamic'` and use the allowlist.

### CSP Levels

- **Level 1**: Basic allowlist-based policy. No nonce/hash support.
- **Level 2**: Added nonce, hash, `frame-ancestors`, `base-uri`, `child-src`, `form-action`.
- **Level 3**: Added `strict-dynamic`, `report-to`, `worker-src`, `manifest-src`, `navigate-to`.

### report-uri / report-to

`report-uri` (deprecated but widely supported) sends JSON violation reports via POST. `report-to` uses the Reporting API with a `Report-To` response header.

```
Content-Security-Policy: default-src 'self'; report-to csp-endpoint
Report-To: {"group":"csp-endpoint","max_age":10886400,"endpoints":[{"url":"https://example.com/csp-report"}]}
```

Deploy `Content-Security-Policy-Report-Only` first to collect violations without blocking. Aggregate reports with tools like report-uri.com, Sentry, or a custom endpoint.

## Strict-Transport-Security (HSTS)

Force HTTPS for all connections. Set `max-age` to at least 1 year (31536000). Include `includeSubDomains` when all subdomains support HTTPS. Add `preload` and submit to hstspreload.org for browser-level enforcement.

```
Strict-Transport-Security: max-age=31536000; includeSubDomains; preload
```

**Caution**: HSTS is trust-on-first-use. Until preloaded, first visit is vulnerable. Once preloaded, removal takes months — verify all subdomains serve HTTPS before submitting. Start with a short `max-age` (e.g., 300) during rollout, then increase.

## X-Content-Type-Options

Prevent MIME-type sniffing. Always set:

```
X-Content-Type-Options: nosniff
```

Ensures browsers respect the declared `Content-Type`. Blocks script execution from mistyped MIME responses.

## X-Frame-Options and frame-ancestors

`X-Frame-Options` prevents clickjacking:

```
X-Frame-Options: DENY
X-Frame-Options: SAMEORIGIN
```

**Prefer CSP `frame-ancestors`** — it supersedes `X-Frame-Options`, supports multiple origins, and allows granular control:

```
Content-Security-Policy: frame-ancestors 'none'
Content-Security-Policy: frame-ancestors 'self' https://trusted.example.com
```

Set both for backward compatibility with older browsers.

## Referrer-Policy

Control referrer information leakage:

| Value | Behavior |
|---|---|
| `no-referrer` | Never send referrer |
| `strict-origin-when-cross-origin` | Full path same-origin, origin-only cross-origin over HTTPS, nothing on downgrade |
| `same-origin` | Full referrer same-origin only |
| `origin` | Origin only, always |

Recommended default:

```
Referrer-Policy: strict-origin-when-cross-origin
```

Use `no-referrer` for pages with sensitive data in URLs (tokens, PII).

## Permissions-Policy

Restrict browser feature access. Deny features you do not use. Syntax: `feature=()` denies all, `feature=(self)` allows same-origin, `feature=("https://example.com")` allows specific origin.

```
Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=(), fullscreen=(self), usb=(), magnetometer=(), gyroscope=(), accelerometer=()
```

## Cross-Origin Headers (CORP, COEP, COOP)

Required for cross-origin isolation (enables `SharedArrayBuffer`, high-resolution timers).

### Cross-Origin-Resource-Policy (CORP)

Controls which origins can load your resources:

```
Cross-Origin-Resource-Policy: same-origin
Cross-Origin-Resource-Policy: same-site
Cross-Origin-Resource-Policy: cross-origin
```

### Cross-Origin-Embedder-Policy (COEP)

Requires embedded resources to explicitly grant permission via CORS or CORP:

```
Cross-Origin-Embedder-Policy: require-corp
Cross-Origin-Embedder-Policy: credentialless
```

Use `credentialless` as a less restrictive alternative that omits credentials for cross-origin no-CORS requests instead of blocking them.

### Cross-Origin-Opener-Policy (COOP)

Isolates your browsing context group:

```
Cross-Origin-Opener-Policy: same-origin
```

**Full cross-origin isolation** requires both `COOP: same-origin` and `COEP: require-corp`. Verify with `self.crossOriginIsolated` in JavaScript.

## Cache-Control Security

For pages containing sensitive data (account pages, PII, tokens):

```
Cache-Control: no-store, no-cache, must-revalidate, private
Pragma: no-cache
```

Never cache authenticated API responses on shared caches. Set `Cache-Control: no-store` on any response containing credentials, tokens, or session data. Omitting this risks exposing sensitive data via browser back-button, shared proxies, or CDN caches.

## Set-Cookie Security

### Required Attributes

```
Set-Cookie: __Host-session=abc123; Path=/; Secure; HttpOnly; SameSite=Strict
```

| Attribute | Purpose |
|---|---|
| `Secure` | HTTPS-only transmission |
| `HttpOnly` | Blocks JavaScript access (XSS protection) |
| `SameSite=Strict` | No cross-site sending (CSRF protection) |
| `SameSite=Lax` | Cross-site on top-level GET only |
| `SameSite=None; Secure` | Cross-site allowed (requires Secure) |

### Cookie Prefixes

- `__Host-`: Requires `Secure`, `Path=/`, no `Domain`. Strictest — tied to exact host, no subdomain sharing.
- `__Secure-`: Requires `Secure`. Prevents insecure origins from overwriting.

Use `__Host-` for session/auth cookies. Use short `Max-Age` for session cookies. Clear cookies on logout.

## Implementation

### Express / Helmet.js

```javascript
const helmet = require('helmet');
app.use(helmet({
  contentSecurityPolicy: {
    directives: {
      defaultSrc: ["'self'"],
      scriptSrc: ["'self'", `'nonce-${nonce}'`, "'strict-dynamic'"],
      styleSrc: ["'self'", `'nonce-${nonce}'`],
      imgSrc: ["'self'", "data:", "https:"],
      objectSrc: ["'none'"],
      baseUri: ["'none'"],
      frameAncestors: ["'none'"],
      formAction: ["'self'"],
      upgradeInsecureRequests: [],
    },
    reportOnly: false,
  },
  strictTransportSecurity: { maxAge: 31536000, includeSubDomains: true, preload: true },
  referrerPolicy: { policy: 'strict-origin-when-cross-origin' },
  crossOriginEmbedderPolicy: { policy: 'require-corp' },
  crossOriginOpenerPolicy: { policy: 'same-origin' },
  crossOriginResourcePolicy: { policy: 'same-origin' },
}));
```

### Nginx

```nginx
# In HTTPS server block
add_header Content-Security-Policy "default-src 'self'; script-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'" always;
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
add_header X-Content-Type-Options "nosniff" always;
add_header X-Frame-Options "DENY" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header Permissions-Policy "camera=(), microphone=(), geolocation=()" always;
add_header Cross-Origin-Opener-Policy "same-origin" always;
add_header Cross-Origin-Embedder-Policy "require-corp" always;
add_header Cross-Origin-Resource-Policy "same-origin" always;
```

Use `always` to apply headers on error responses too. Place in `server` or `location` blocks. Headers in nested blocks override parent — repeat all headers in each block.

### Apache

```apache
# In <VirtualHost *:443> or .htaccess (requires mod_headers)
Header always set Content-Security-Policy "default-src 'self'; script-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'"
Header always set Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
Header always set X-Content-Type-Options "nosniff"
Header always set X-Frame-Options "DENY"
Header always set Referrer-Policy "strict-origin-when-cross-origin"
Header always set Permissions-Policy "camera=(), microphone=(), geolocation=()"
```

### Next.js

```javascript
// next.config.js
const securityHeaders = [
  { key: 'Content-Security-Policy', value: "default-src 'self'; script-src 'self' 'nonce-${nonce}' 'strict-dynamic'; object-src 'none'; base-uri 'none'" },
  { key: 'Strict-Transport-Security', value: 'max-age=31536000; includeSubDomains; preload' },
  { key: 'X-Content-Type-Options', value: 'nosniff' },
  { key: 'X-Frame-Options', value: 'DENY' },
  { key: 'Referrer-Policy', value: 'strict-origin-when-cross-origin' },
  { key: 'Permissions-Policy', value: 'camera=(), microphone=(), geolocation=()' },
];
module.exports = {
  async headers() {
    return [{ source: '/(.*)', headers: securityHeaders }];
  },
};
```

For nonce-based CSP in Next.js, use middleware to generate per-request nonces and inject via `next/script` with `nonce` prop. See Next.js docs on CSP middleware.

### Cloudflare

Set headers via Transform Rules (Modify Response Header) or Cloudflare Workers:

```javascript
// Cloudflare Worker
addEventListener('fetch', event => {
  event.respondWith(handleRequest(event.request));
});
async function handleRequest(request) {
  const response = await fetch(request);
  const newResponse = new Response(response.body, response);
  newResponse.headers.set('X-Content-Type-Options', 'nosniff');
  newResponse.headers.set('X-Frame-Options', 'DENY');
  newResponse.headers.set('Referrer-Policy', 'strict-origin-when-cross-origin');
  newResponse.headers.set('Strict-Transport-Security', 'max-age=31536000; includeSubDomains; preload');
  newResponse.headers.set('Permissions-Policy', 'camera=(), microphone=(), geolocation=()');
  return newResponse;
}
```

## Testing and Validation

### Automated Scanning

- **securityheaders.com**: Paste URL for letter-grade header audit.
- **Mozilla Observatory** (observatory.mozilla.org): Comprehensive scan including CSP, cookies, HSTS, redirection.
- **CSP Evaluator** (csp-evaluator.withgoogle.com): Analyzes CSP for bypass risks.

### curl Inspection

```bash
# Check all security headers
curl -sI https://example.com | grep -iE '(content-security|strict-transport|x-content-type|x-frame|referrer-policy|permissions-policy|cross-origin|set-cookie|cache-control)'

# Check CSP specifically
curl -sI https://example.com | grep -i content-security-policy

# Verify HSTS
curl -sI https://example.com | grep -i strict-transport
```

### Browser DevTools

Open Network tab → select request → Headers tab. Check `document.securityPolicy` or `self.crossOriginIsolated` in Console. CSP violations appear in Console as errors.

## CSP Reporting

### Report-Only Deployment

Deploy `Content-Security-Policy-Report-Only` header alongside your enforcement header to test new directives without breaking the page:

```
Content-Security-Policy-Report-Only: default-src 'self'; script-src 'nonce-xyz' 'strict-dynamic'; report-to csp-staging
```

### Report Endpoint

Build a report-to endpoint that accepts `application/reports+json` POST bodies. Aggregate by violated-directive + blocked-uri to identify patterns. Filter noise from browser extensions (look for `moz-extension:`, `chrome-extension:` in blocked URIs).

### Progressive Rollout

1. Deploy report-only with permissive policy. Collect baseline violations.
2. Tighten policy iteratively. Monitor reports after each change.
3. Switch to enforcing once violations are resolved or accepted.
4. Keep report-to active in enforcement mode for ongoing monitoring.

## Common Patterns

### Starter CSP (Restrictive Baseline)

```
Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'; upgrade-insecure-requests
```

### Nonce-Based Strict CSP (Recommended)

```
Content-Security-Policy: default-src 'self'; script-src 'nonce-{RANDOM}' 'strict-dynamic' https: 'unsafe-inline'; style-src 'self' 'nonce-{RANDOM}'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; report-to csp-reports
```

The `https:` and `'unsafe-inline'` act as fallbacks for browsers without `strict-dynamic` support. Browsers that support `strict-dynamic` ignore both.

### SPA-Specific CSP

SPAs need `connect-src` for API calls and may need `style-src 'unsafe-inline'` for CSS-in-JS (prefer nonces). Configure `script-src` with nonces for the initial bundle; `strict-dynamic` covers dynamically loaded chunks.

```
Content-Security-Policy: default-src 'self'; script-src 'nonce-{RANDOM}' 'strict-dynamic'; style-src 'self' 'nonce-{RANDOM}'; connect-src 'self' https://api.example.com; img-src 'self' data: blob:; font-src 'self'; object-src 'none'; base-uri 'none'
```

For React: use `<Script nonce={nonce}>`. For Angular: Angular CLI supports CSP nonce via `ngCspNonce` attribute.

## Common Gotchas

### Inline Scripts Breaking CSP

Problem: Adding CSP blocks all inline `<script>` tags and `on*` event handlers.
Fix: Move inline scripts to external files or add nonces. Refactor `onclick`/`onload` handlers to `addEventListener` calls.

### Third-Party Script Challenges

Problem: Tag managers (GTM), analytics, and ad scripts inject arbitrary inline scripts that break strict CSP.
Fix: Use `strict-dynamic` so the nonced loader script can load dependencies. For GTM, use server-side tagging or a custom GTM template with nonce support. Audit all third-party domains — whitelisting a CDN that hosts user-uploaded content (e.g., `cdn.jsdelivr.net`) allows attacker-controlled script execution.

### CSP Bypass Vectors

- **JSONP endpoints** on whitelisted domains allow arbitrary callback execution.
- **Angular/Vue template injection** in CSP-whitelisted CDN scripts can execute arbitrary code.
- **Subdomain takeover** of a whitelisted origin lets attackers host malicious scripts on a trusted domain.
- **`base-uri` omission** allows `<base>` tag injection, redirecting relative script URLs to attacker-controlled servers.
- **Open redirects** on whitelisted origins can redirect script loads to malicious endpoints.

Mitigate: Always set `base-uri 'none'`, `object-src 'none'`. Avoid domain-based allowlists — prefer nonce + `strict-dynamic`. Audit whitelisted domains for JSONP endpoints. Use Subresource Integrity (SRI) on third-party scripts.

### Duplicate Headers

When using both a reverse proxy (Nginx/Apache) and application-level middleware (Helmet), headers may duplicate or conflict. Set headers at one layer only.

### HSTS Preload Pitfalls

Submitting to the preload list is effectively permanent. All subdomains must serve HTTPS. Removing a preloaded domain takes months and requires browser updates. Test thoroughly before submitting.

## Examples

### Input: "Add security headers to my Express app"

Output: Install helmet and configure:

```javascript
const helmet = require('helmet');
const crypto = require('crypto');

app.use((req, res, next) => {
  res.locals.nonce = crypto.randomBytes(16).toString('base64');
  next();
});

app.use((req, res, next) => {
  helmet({
    contentSecurityPolicy: {
      directives: {
        defaultSrc: ["'self'"],
        scriptSrc: ["'self'", `'nonce-${res.locals.nonce}'`, "'strict-dynamic'"],
        styleSrc: ["'self'", `'nonce-${res.locals.nonce}'`],
        imgSrc: ["'self'", "data:"],
        objectSrc: ["'none'"],
        baseUri: ["'none'"],
        frameAncestors: ["'none'"],
        formAction: ["'self'"],
      },
    },
    strictTransportSecurity: { maxAge: 31536000, includeSubDomains: true, preload: true },
    referrerPolicy: { policy: 'strict-origin-when-cross-origin' },
  })(req, res, next);
});
```

### Input: "My CSP is blocking inline scripts after deployment"

Output: Check the browser console for the violated directive and blocked resource. Common fixes:

1. **Move inline scripts to external files** — most reliable solution.
2. **Add nonces** — generate per-request, set on trusted `<script nonce="...">` tags, add `'nonce-VALUE'` to `script-src`.
3. **Add hashes** — for static inline scripts only. Get the hash from the browser console violation message.
4. **Never add `'unsafe-inline'`** — it disables CSP's primary XSS protection and is ignored when nonce/hash is present.

### Input: "Audit security headers for my production site"

Output:

```bash
# Quick header check
curl -sI https://yoursite.com | grep -iE '(content-security|strict-transport|x-content-type|x-frame|referrer-policy|permissions-policy|cross-origin|set-cookie)'

# Check for missing headers — expect all of these:
# Content-Security-Policy, Strict-Transport-Security, X-Content-Type-Options,
# Referrer-Policy, Permissions-Policy, X-Frame-Options

# Validate CSP strength
# Paste your CSP into https://csp-evaluator.withgoogle.com

# Full scan
# Submit URL to https://securityheaders.com and https://observatory.mozilla.org
```

## Reference Documentation

Deep-dive guides in `references/`:

| File | Description |
|---|---|
| [csp-deep-dive.md](references/csp-deep-dive.md) | Complete CSP reference: all directives, nonce patterns (SSR + SPA), hash generation, strict-dynamic with Trusted Types, report-only migration, violation report analysis, Web Workers/Service Workers, eval alternatives, bypass prevention checklist |
| [troubleshooting.md](references/troubleshooting.md) | Common issues: CSP breaking inline code, Google Analytics/GTM with CSP, third-party widget conflicts, CORS vs CORP confusion, HSTS dev issues, mixed content, frame-ancestors precedence, local vs production testing |
| [framework-configs.md](references/framework-configs.md) | Copy-paste configs for Express/Helmet, Next.js, Nuxt.js, Django, Spring Boot, ASP.NET Core, Rails, Nginx, Apache, Caddy, Cloudflare Workers, Vercel, Netlify |

## Scripts

Executable tools in `scripts/`:

| Script | Usage |
|---|---|
| [audit-headers.sh](scripts/audit-headers.sh) | `./audit-headers.sh <url>` — Audit security headers for a URL, score A-F, report missing headers with fix suggestions. Use `-v` for verbose output. |
| [generate-csp.sh](scripts/generate-csp.sh) | `./generate-csp.sh` — Interactive CSP generator. Also supports `--strict` and `--permissive` quick modes. |
| [test-csp-report.sh](scripts/test-csp-report.sh) | `./test-csp-report.sh [--port PORT]` — Start a local CSP violation report collector server for testing report-only mode. |

## Assets

Copy-paste ready templates in `assets/`:

| File | Description |
|---|---|
| [helmet-config.ts](assets/helmet-config.ts) | Complete Helmet.js configuration with nonce middleware, all security headers, Permissions-Policy, and typed options |
| [nginx-security.conf](assets/nginx-security.conf) | Nginx security headers snippet — include in server blocks |
| [nextjs-headers.ts](assets/nextjs-headers.ts) | Next.js security headers (next.config.ts + CSP middleware with nonce) |
| [csp-report-handler.ts](assets/csp-report-handler.ts) | Express router for receiving, normalizing, and aggregating CSP violation reports with stats endpoint |
| [security-headers-test.ts](assets/security-headers-test.ts) | Vitest/Jest test suite verifying all security headers on API responses |
