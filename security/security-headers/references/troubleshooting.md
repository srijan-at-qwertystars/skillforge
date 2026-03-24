# Security Headers Troubleshooting Guide

Common issues when implementing HTTP security headers and how to resolve them.

---

## Table of Contents

1. [CSP Breaking Inline Styles and Scripts](#csp-breaking-inline-styles-and-scripts)
2. [Google Analytics / Tag Manager with CSP](#google-analytics--tag-manager-with-csp)
3. [Third-Party Widget CSP Conflicts](#third-party-widget-csp-conflicts)
4. [CORS vs CORP Confusion](#cors-vs-corp-confusion)
5. [HSTS Causing Dev Environment Issues](#hsts-causing-dev-environment-issues)
6. [Mixed Content Problems](#mixed-content-problems)
7. [frame-ancestors vs X-Frame-Options Precedence](#frame-ancestors-vs-x-frame-options-precedence)
8. [Testing Headers Locally vs Production](#testing-headers-locally-vs-production)
9. [Quick Diagnostic Checklist](#quick-diagnostic-checklist)

---

## CSP Breaking Inline Styles and Scripts

### Symptoms

- Page renders without styling (FOUC or unstyled content).
- JavaScript functionality stops working.
- Console shows: `Refused to execute inline script because it violates the following Content Security Policy directive: "script-src ..."`.
- Console shows: `Refused to apply inline style because it violates the following Content Security Policy directive: "style-src ..."`.

### Root Cause

CSP blocks all inline `<script>`, `<style>`, `style=""` attributes, and `on*` event handlers by default when `script-src` or `style-src` doesn't include `'unsafe-inline'`.

### Solutions

**Option 1: Add nonces (recommended)**

```javascript
// Generate nonce per request
const nonce = crypto.randomBytes(16).toString('base64');

// Set in CSP header
`script-src 'self' 'nonce-${nonce}'; style-src 'self' 'nonce-${nonce}'`

// Add to every inline element
// <script nonce="NONCE_VALUE">...</script>
// <style nonce="NONCE_VALUE">...</style>
```

**Option 2: Move to external files**

```html
<!-- Before: inline script -->
<script>initApp();</script>

<!-- After: external file -->
<script src="/js/init.js"></script>
```

**Option 3: Use hashes for static inline scripts**

```bash
# Get the hash from the browser console error message, or generate it:
echo -n 'initApp();' | openssl dgst -sha256 -binary | openssl base64
```

```
script-src 'self' 'sha256-HASH_VALUE'
```

**For inline styles specifically:**

CSS-in-JS libraries (styled-components, Emotion) inject `<style>` tags at runtime. Options:

1. **Nonces:** Pass the nonce to the CSS-in-JS library's SSR configuration.
   - styled-components: Use `ServerStyleSheet` with nonce in `__webpack_nonce__`.
   - Emotion: Set `nonce` in the Emotion cache configuration.
2. **`'unsafe-inline'` in `style-src` only:** Less dangerous than in `script-src`, since style injection has limited attack surface (CSS exfiltration is possible but less severe than XSS). Acceptable as a pragmatic tradeoff.

**For inline event handlers (`onclick`, `onload`, etc.):**

These cannot use nonces. You must refactor to `addEventListener`:

```html
<!-- Before -->
<button onclick="submit()">Send</button>

<!-- After -->
<button id="submit-btn">Send</button>
<script nonce="NONCE">
  document.getElementById('submit-btn').addEventListener('click', submit);
</script>
```

Or use `'unsafe-hashes'` with the handler's hash (CSP Level 3, limited support):

```
script-src 'unsafe-hashes' 'sha256-HASH_OF_HANDLER_BODY'
```

---

## Google Analytics / Tag Manager with CSP

### The Problem

Google Tag Manager (GTM) and Google Analytics (GA4) inject inline scripts, load scripts from multiple Google domains, and use `eval()`-like patterns. A strict CSP will block most of their functionality.

### GA4 (gtag.js) — Direct Integration

```
script-src 'self' 'nonce-{NONCE}' https://www.googletagmanager.com;
img-src 'self' https://www.google-analytics.com https://www.googletagmanager.com;
connect-src 'self' https://www.google-analytics.com https://analytics.google.com https://region1.google-analytics.com https://*.google-analytics.com;
```

Add nonce to the gtag script tag:

```html
<script nonce="NONCE" async src="https://www.googletagmanager.com/gtag/js?id=G-XXXXXX"></script>
<script nonce="NONCE">
  window.dataLayer = window.dataLayer || [];
  function gtag(){dataLayer.push(arguments);}
  gtag('js', new Date());
  gtag('config', 'G-XXXXXX');
</script>
```

### Google Tag Manager — Full Setup

GTM is the hardest to secure with CSP because it loads arbitrary tags configured in the GTM console. Each tag may load scripts from different domains.

**Approach 1: strict-dynamic (best option with GTM)**

```
script-src 'nonce-{NONCE}' 'strict-dynamic';
```

Add nonce to the GTM container script. `strict-dynamic` propagates trust to scripts GTM loads. This covers most tags but not those that inject scripts via `document.write`.

**Approach 2: Server-side GTM (recommended for strict CSP)**

Use a server-side GTM container. This moves tag execution to your server, eliminating the need for client-side permissions for third-party domains.

**Approach 3: Custom GTM template with nonce support**

GTM custom templates can access a nonce variable. Create custom templates that pass the nonce to injected scripts.

**Common GTM domains to allowlist (if not using strict-dynamic):**

```
script-src https://www.googletagmanager.com https://tagmanager.google.com;
img-src https://www.googletagmanager.com https://ssl.gstatic.com https://www.gstatic.com;
style-src https://tagmanager.google.com https://fonts.googleapis.com;
font-src https://fonts.gstatic.com;
```

**Warning:** GTM can load ANY tag configured in the console — you cannot create a comprehensive allowlist from the CSP side alone. Audit your GTM container for all loaded resources.

---

## Third-Party Widget CSP Conflicts

### Common Widgets and Required CSP

**Intercom:**

```
script-src https://widget.intercom.io https://js.intercomcdn.com;
connect-src https://api-iam.intercom.io wss://nexus-websocket-a.intercom.io https://uploads.intercomcdn.com;
img-src https://static.intercomassets.com https://downloads.intercomcdn.com;
font-src https://js.intercomcdn.com;
frame-src https://intercom-sheets.com;
media-src https://js.intercomcdn.com;
```

**Stripe:**

```
script-src https://js.stripe.com;
frame-src https://js.stripe.com https://hooks.stripe.com;
connect-src https://api.stripe.com;
```

**YouTube embeds:**

```
frame-src https://www.youtube.com https://www.youtube-nocookie.com;
img-src https://img.youtube.com https://i.ytimg.com;
```

**Sentry error reporting:**

```
script-src https://browser.sentry-cdn.com;
connect-src https://*.ingest.sentry.io;
```

**reCAPTCHA:**

```
script-src https://www.google.com/recaptcha/ https://www.gstatic.com/recaptcha/;
frame-src https://www.google.com/recaptcha/ https://recaptcha.google.com/recaptcha/;
```

### Strategy for Multiple Widgets

1. Start with `Content-Security-Policy-Report-Only` and enable all widgets.
2. Collect violation reports to identify all required domains.
3. Add domains to the appropriate directives.
4. Switch to enforcement.
5. Document every allowlisted domain and why it's needed — review quarterly.

### Dynamic Widget Loading

If widgets are loaded conditionally (e.g., chat widget only on support pages), consider using different CSP policies for different routes:

```javascript
// Express middleware
app.use('/support/*', (req, res, next) => {
  // Permissive CSP for support pages with chat widget
  res.setHeader('Content-Security-Policy', supportCSP);
  next();
});

app.use('/*', (req, res, next) => {
  // Strict CSP for all other pages
  res.setHeader('Content-Security-Policy', strictCSP);
  next();
});
```

---

## CORS vs CORP Confusion

### What Each Does

| Header | Direction | Purpose |
|---|---|---|
| **CORS** (`Access-Control-Allow-Origin`) | Set by **resource server** | "Who can **read** my responses via JavaScript?" |
| **CORP** (`Cross-Origin-Resource-Policy`) | Set by **resource server** | "Who can **load** my resources at all?" |
| **COEP** (`Cross-Origin-Embedder-Policy`) | Set by **embedding page** | "I require all embedded resources to opt in (via CORS or CORP)." |
| **COOP** (`Cross-Origin-Opener-Policy`) | Set by **any page** | "I want my browsing context group isolated." |

### Common Confusion Scenarios

**"I set CORS headers but images still fail to load"**

CORS controls **JavaScript access** to responses, not loading. An `<img>` tag loads cross-origin images without CORS. But if the embedding page has `Cross-Origin-Embedder-Policy: require-corp`, the image server must respond with `Cross-Origin-Resource-Policy: cross-origin` OR the `<img>` must use `crossorigin` attribute with proper CORS headers on the server.

**"I set CORP same-origin but my CDN assets won't load"**

`CORP: same-origin` blocks ALL cross-origin loads of that resource. If your assets are on a CDN (different origin), they need `CORP: cross-origin` or `CORP: same-site` (if same registered domain).

**"COEP is breaking all my third-party images"**

`COEP: require-corp` requires all embedded resources to have CORP headers or be loaded with CORS. Options:

1. Ask third parties to add `Cross-Origin-Resource-Policy: cross-origin`.
2. Proxy resources through your origin.
3. Use `COEP: credentialless` instead — less strict, omits credentials on no-CORS cross-origin requests instead of blocking them.

**"Do I need all three (CORP + COEP + COOP)?"**

Only if you need cross-origin isolation (`SharedArrayBuffer`, high-resolution `performance.now()`). For most apps, you don't need these. Set `COOP: same-origin-allow-popups` if you use OAuth popups.

### Decision Tree

```
Need SharedArrayBuffer or high-res timers?
├── Yes → Set COOP: same-origin + COEP: require-corp
│         All embedded resources need CORP or CORS
└── No  → Skip COEP/COOP
          Set CORP: same-origin on YOUR resources (prevents others from loading them)
          Skip CORP on intentionally public resources (CDN assets, public APIs)
```

---

## HSTS Causing Dev Environment Issues

### Symptoms

- `localhost` or dev domain redirects to HTTPS and can't be accessed.
- Browser shows `NET::ERR_CERT_AUTHORITY_INVALID` on dev URLs.
- Can't access HTTP dev server after testing production HSTS config.

### Root Causes

1. **HSTS set on `localhost`:** If your dev server sends HSTS, the browser remembers and forces HTTPS on localhost.
2. **`includeSubDomains` with local subdomains:** If `example.com` has HSTS with `includeSubDomains` and you use `dev.example.com` pointing to localhost, the browser forces HTTPS.
3. **HSTS preload on TLD:** If your domain is HSTS-preloaded, all subdomains are forced to HTTPS permanently.

### Solutions

**Clear HSTS for a specific domain (Chrome):**

1. Navigate to `chrome://net-internals/#hsts`
2. Enter the domain under "Delete domain security policies"
3. Click "Delete"

**Clear HSTS for a specific domain (Firefox):**

1. Close all tabs for the domain
2. Clear history for that domain (Ctrl+Shift+Del → select domain)
3. Or edit `SiteSecurityServiceState.txt` in profile directory

**Prevent HSTS in development:**

```javascript
// Only set HSTS in production
if (process.env.NODE_ENV === 'production') {
  app.use(helmet.hsts({
    maxAge: 31536000,
    includeSubDomains: true,
    preload: true
  }));
}
```

```nginx
# Nginx: only in production server block
# Do NOT include HSTS in dev/staging configs
# server {
#   listen 443 ssl;
#   server_name dev.example.com;
#   # NO add_header Strict-Transport-Security here
# }
```

**Use a separate domain for dev:**

Don't use subdomains of your HSTS-preloaded production domain for development. Use a completely separate domain (e.g., `myapp-dev.test`).

**Start HSTS with a short max-age:**

```
# Testing (5 minutes)
Strict-Transport-Security: max-age=300

# Staging (1 day)
Strict-Transport-Security: max-age=86400

# Production (1 year + preload)
Strict-Transport-Security: max-age=31536000; includeSubDomains; preload
```

---

## Mixed Content Problems

### Symptoms

- Browser console: `Mixed Content: The page at 'https://...' was loaded over HTTPS, but requested an insecure resource 'http://...'`.
- Resources silently fail to load (passive mixed content may be blocked without errors in some browsers).
- Yellow/broken lock icon in the address bar.

### Types of Mixed Content

| Type | Examples | Browser Behavior |
|---|---|---|
| **Active** (blockable) | Scripts, stylesheets, iframes, XHR/fetch, fonts | Blocked by default |
| **Passive** (optionally blockable) | Images, audio, video | Historically allowed with warning; increasingly blocked |

### Solutions

**1. Fix resource URLs**

```html
<!-- Before -->
<script src="http://cdn.example.com/lib.js"></script>
<img src="http://images.example.com/logo.png">

<!-- After: protocol-relative (works but not recommended) -->
<script src="//cdn.example.com/lib.js"></script>

<!-- After: explicit HTTPS (recommended) -->
<script src="https://cdn.example.com/lib.js"></script>
<img src="https://images.example.com/logo.png">
```

**2. Use CSP `upgrade-insecure-requests`**

```
Content-Security-Policy: upgrade-insecure-requests
```

This tells the browser to upgrade all HTTP resource requests to HTTPS **before** fetching. Covers `<img>`, `<script>`, `<link>`, XHR, etc. Does NOT upgrade navigation (links). Does NOT fix resources where the HTTPS version doesn't exist.

**3. Find all mixed content sources**

```bash
# Search codebase for http:// references
grep -rn 'http://' --include='*.html' --include='*.js' --include='*.css' --include='*.ts' --include='*.jsx' --include='*.tsx' src/

# Check for protocol-relative URLs that might resolve to HTTP
grep -rn 'src="//' --include='*.html' src/
```

**4. Common mixed content sources:**

- Hardcoded HTTP URLs in database content (CMS, user-generated content)
- Third-party API endpoints using HTTP
- Legacy image/asset URLs
- Inline CSS with `url(http://...)`
- Fonts loaded over HTTP

**5. Use report-only to find violations before enforcing:**

```
Content-Security-Policy-Report-Only: default-src https:; report-to mixed-content-reports
```

---

## frame-ancestors vs X-Frame-Options Precedence

### The Rules

1. **CSP `frame-ancestors` takes precedence** over `X-Frame-Options` in all modern browsers.
2. If both are present and conflict, `frame-ancestors` wins.
3. `X-Frame-Options` is only used when `frame-ancestors` is absent.
4. `frame-ancestors` is NOT subject to `default-src` fallback — if omitted, framing is unrestricted by CSP.

### Common Conflicts

**Scenario 1: Headers contradict each other**

```
X-Frame-Options: DENY
Content-Security-Policy: frame-ancestors 'self' https://partner.com
```

Result: Modern browsers allow framing from `self` and `partner.com` (CSP wins). IE11 and very old browsers follow `X-Frame-Options: DENY` and block all framing.

**Scenario 2: Only X-Frame-Options set**

```
X-Frame-Options: SAMEORIGIN
```

Result: Works everywhere but less flexible — can't allowlist specific external origins.

**Scenario 3: Only frame-ancestors set**

```
Content-Security-Policy: frame-ancestors 'none'
```

Result: Works in all modern browsers. IE11 ignores it and allows framing.

### Best Practice

Set both for maximum compatibility:

```
Content-Security-Policy: frame-ancestors 'none'
X-Frame-Options: DENY
```

Or if you need to allow specific origins:

```
Content-Security-Policy: frame-ancestors 'self' https://partner.com
X-Frame-Options: SAMEORIGIN
```

Note: `X-Frame-Options` cannot express "allow from partner.com" — `ALLOW-FROM` was never widely supported and is now deprecated. Only CSP `frame-ancestors` supports multiple specific origins.

### Key Difference in Scope

- `X-Frame-Options` applies to the **response** it's set on.
- `frame-ancestors` applies to the **page being embedded** — it's set on the page that might be framed.
- Neither applies to `<object>`, `<embed>`, or `<applet>` — use `object-src 'none'` in CSP for those.

---

## Testing Headers Locally vs Production

### Local Development Challenges

| Issue | Why It Happens | Solution |
|---|---|---|
| HSTS forces HTTPS on localhost | HSTS cookie cached from previous test | Clear HSTS state (see HSTS section); use a different port |
| CSP blocks hot-reload | Webpack dev server injects inline scripts | Use a relaxed CSP in dev, or add nonces to the dev server |
| CSP blocks eval | Webpack's default devtool uses `eval()` | Set `devtool: 'source-map'` instead of `'eval'`; or add `'unsafe-eval'` in dev only |
| COEP blocks local resources | Resources on different ports are cross-origin | Skip COEP in dev or serve everything on same port |
| Localhost is not "secure context" for some APIs | HTTP localhost IS a secure context in most browsers | Use `localhost` not `127.0.0.1` |

### Recommended Dev vs Production Headers

```javascript
const isDev = process.env.NODE_ENV !== 'production';

const cspDirectives = {
  defaultSrc: ["'self'"],
  scriptSrc: isDev
    ? ["'self'", "'unsafe-inline'", "'unsafe-eval'"]  // Allow HMR
    : ["'self'", `'nonce-${nonce}'`, "'strict-dynamic'"],
  styleSrc: isDev
    ? ["'self'", "'unsafe-inline'"]  // Allow CSS HMR
    : ["'self'", `'nonce-${nonce}'`],
  connectSrc: isDev
    ? ["'self'", 'ws://localhost:*']  // Allow WebSocket HMR
    : ["'self'"],
  imgSrc: ["'self'", 'data:'],
  objectSrc: ["'none'"],
  baseUri: ["'none'"],
};
```

### Testing Tools

**curl — quick header check:**

```bash
curl -sI https://localhost:3000 | grep -iE '(content-security|strict-transport|x-content|x-frame|referrer|permissions|cross-origin)'
```

**Browser DevTools:**

1. Network tab → click request → Headers sub-tab → look at Response Headers.
2. Console tab → CSP violations appear as errors with the violated directive.
3. Application tab → check "Frames" for security info including cross-origin isolation status.

**Automated testing in CI:**

```javascript
// Supertest (Node.js)
const request = require('supertest');
const app = require('./app');

describe('Security Headers', () => {
  it('should set all security headers', async () => {
    const res = await request(app).get('/');
    expect(res.headers['content-security-policy']).toBeDefined();
    expect(res.headers['strict-transport-security']).toBeDefined();
    expect(res.headers['x-content-type-options']).toBe('nosniff');
    expect(res.headers['x-frame-options']).toBe('DENY');
    expect(res.headers['referrer-policy']).toBe('strict-origin-when-cross-origin');
  });
});
```

### Local Testing with Production-Like Headers

**Option 1: Nginx reverse proxy locally**

Run nginx locally with production-like security headers, proxy to your dev server:

```nginx
server {
    listen 443 ssl;
    server_name local.myapp.com;
    ssl_certificate /path/to/local-cert.pem;
    ssl_certificate_key /path/to/local-key.pem;

    # Production-like security headers
    add_header Content-Security-Policy "default-src 'self'" always;
    add_header Strict-Transport-Security "max-age=300" always;
    # ... other headers

    location / {
        proxy_pass http://localhost:3000;
    }
}
```

**Option 2: mkcert for local HTTPS**

```bash
# Install mkcert
brew install mkcert  # macOS
mkcert -install
mkcert localhost 127.0.0.1 ::1
# Use generated certs with your dev server
```

**Option 3: Conditional middleware**

Use the same middleware in dev and prod but with adjusted values. Log CSP violations in dev to console instead of silently blocking.

---

## Quick Diagnostic Checklist

When security headers aren't working as expected:

1. **Check which layer sets headers**: Is it the app, reverse proxy, CDN, or hosting provider? Use `curl -sI` to see actual response headers.

2. **Check for duplicates**: Multiple layers may set the same header. Duplicate CSP headers are combined (more restrictive). Duplicate `X-Frame-Options` may behave unpredictably.

3. **Check CSP `default-src` fallback**: If a specific directive isn't set, `default-src` applies. If you set `default-src 'self'` and don't set `connect-src`, API calls to external domains fail.

4. **Check the browser console**: CSP violations include the violated directive, blocked URI, and sometimes a `sample` of the blocked code. This is the fastest debugging path.

5. **Check report-only vs enforce**: `Content-Security-Policy-Report-Only` does NOT block anything. Verify you're using the right header.

6. **Test in multiple browsers**: CSP Level 3 features (`strict-dynamic`, Trusted Types) have varying support. Test in Chrome, Firefox, Safari.

7. **Check for meta tag vs header conflicts**: A `<meta http-equiv="Content-Security-Policy">` on the page can conflict with the HTTP header. The most restrictive policy wins (they combine).

8. **Verify `always` flag in Nginx**: Without `always`, Nginx only adds headers to 2xx/3xx responses, not error pages. Use `add_header ... always;`.

9. **Check CDN caching**: If your CDN caches responses, it might cache old headers. Purge cache after header changes.

10. **Check header size limits**: Very long CSP headers (>8KB) may be truncated by proxies or servers. Split into multiple policies or reduce directive count.
