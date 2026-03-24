# htmx Troubleshooting Guide

## Table of Contents

- [Event Bubbling Issues](#event-bubbling-issues)
- [CSRF Token Handling](#csrf-token-handling)
- [Cache Busting](#cache-busting)
- [htmx with CSP Headers](#htmx-with-csp-headers)
- [Debugging with htmx.logAll()](#debugging-with-htmxlogall)
- [Swap Timing Issues](#swap-timing-issues)
- [History Cache Problems](#history-cache-problems)
- [Script Evaluation](#script-evaluation)
- [CORS Issues](#cors-issues)
- [Common 422 Handling Patterns](#common-422-handling-patterns)
- [Miscellaneous Gotchas](#miscellaneous-gotchas)

---

## Event Bubbling Issues

htmx events bubble up the DOM. This causes unexpected triggers when nesting htmx elements.

**Problem:** A button inside an `hx-get` div triggers both the button's and the div's requests.

```html
<!-- BUG: clicking the button fires both requests -->
<div hx-get="/parent-data" hx-trigger="click">
  <button hx-post="/child-action">Do Thing</button>
</div>
```

**Fix 1:** Use `consume` modifier to stop propagation:

```html
<button hx-post="/child-action" hx-trigger="click consume">Do Thing</button>
```

**Fix 2:** Narrow the parent trigger with a CSS selector filter:

```html
<div hx-get="/parent-data" hx-trigger="click target:div">
```

**Fix 3:** Use `hx-on:click` with `stopPropagation`:

```html
<button hx-post="/child-action"
        hx-on:click="event.stopPropagation()">Do Thing</button>
```

**Problem:** `htmx:afterSwap` firing for nested requests.

```javascript
// Use evt.detail.target to scope event handling
document.body.addEventListener('htmx:afterSwap', (evt) => {
  if (evt.detail.target.id === 'my-specific-target') {
    // Handle only this swap
  }
});
```

## CSRF Token Handling

### Django CSRF

Django requires CSRF tokens on POST/PUT/PATCH/DELETE. Configure htmx to send the token automatically:

```html
<body hx-headers='{"X-CSRFToken": "{{ csrf_token }}"}'>
```

Or configure globally via meta tag:

```html
<meta name="csrf-token" content="{{ csrf_token }}">
<script>
document.body.addEventListener('htmx:configRequest', (evt) => {
  evt.detail.headers['X-CSRFToken'] = document.querySelector('meta[name="csrf-token"]').content;
});
</script>
```

### Rails CSRF

```html
<meta name="csrf-token" content="<%= form_authenticity_token %>">
<script>
document.body.addEventListener('htmx:configRequest', (evt) => {
  if (!['GET', 'HEAD'].includes(evt.detail.verb)) {
    evt.detail.headers['X-CSRF-Token'] =
      document.querySelector('meta[name="csrf-token"]').content;
  }
});
</script>
```

### Express (csurf / csrf-csrf)

```javascript
// Server: set cookie
app.use(csrf({ cookie: true }));
app.use((req, res, next) => {
  res.cookie('XSRF-TOKEN', req.csrfToken());
  next();
});

// Client: read from cookie
document.body.addEventListener('htmx:configRequest', (evt) => {
  const token = document.cookie.match(/XSRF-TOKEN=([^;]+)/)?.[1];
  if (token) evt.detail.headers['X-CSRF-Token'] = token;
});
```

### Token refresh after swap

If your CSRF token is in a swapped region, it may become stale. Use OOB to update it:

```html
<!-- Server includes in every response -->
<meta name="csrf-token" content="new_token_value"
      hx-swap-oob="true" id="csrf-meta">
```

## Cache Busting

Browsers and CDNs may cache GET responses, returning stale HTML.

**Problem:** `hx-get` returns cached/old content.

**Fix 1:** Set proper headers server-side:

```python
@app.after_request
def add_htmx_headers(response):
    if request.headers.get("HX-Request"):
        response.headers["Cache-Control"] = "no-store"
        response.headers["Vary"] = "HX-Request"
    return response
```

**Fix 2:** `Vary: HX-Request` header — tells caches that htmx and non-htmx responses differ:

```nginx
# Nginx
location / {
    add_header Vary "HX-Request";
}
```

**Fix 3:** Append cache-buster parameter (last resort):

```html
<div hx-get="/data?_t=${Date.now()}" hx-trigger="load">Loading...</div>
```

Or via event:

```javascript
document.body.addEventListener('htmx:configRequest', (evt) => {
  if (evt.detail.verb === 'GET') {
    evt.detail.parameters['_'] = Date.now();
  }
});
```

## htmx with CSP Headers

Content Security Policy can block htmx's inline event handlers and eval usage.

**Minimal CSP for htmx:**

```
Content-Security-Policy:
  default-src 'self';
  script-src 'self' https://unpkg.com;
  style-src 'self' 'unsafe-inline';
  connect-src 'self';
```

**Problem:** `hx-on:*` attributes use `eval`-like behavior internally.

**Fix:** htmx 2.x supports nonce-based CSP. Set `htmx.config.inlineScriptNonce`:

```html
<meta name="htmx-config" content='{"inlineScriptNonce": "abc123xyz"}'>
```

Generate nonce server-side and include in CSP header:

```
Content-Security-Policy: script-src 'self' 'nonce-abc123xyz';
```

**Problem:** `hx-on` handlers blocked by CSP.

**Fix:** Move logic to `addEventListener` in an external script:

```javascript
// Instead of hx-on:click="doThing()" in HTML
document.body.addEventListener('htmx:afterSwap', (evt) => {
  // ...
});
```

## Debugging with htmx.logAll()

Turn on comprehensive logging in the browser console:

```javascript
// Enable in dev — logs every htmx event with details
htmx.logAll();
```

**Targeted logging** — log specific events only:

```javascript
htmx.logger = function(elt, event, data) {
  if (['htmx:configRequest', 'htmx:afterSwap', 'htmx:responseError'].includes(event)) {
    console.log(`[htmx] ${event}`, { element: elt, data });
  }
};
```

**Debug specific element** — add temporary event listeners:

```javascript
const el = document.getElementById('problem-element');
['htmx:beforeRequest', 'htmx:afterRequest', 'htmx:beforeSwap',
 'htmx:afterSwap', 'htmx:responseError'].forEach(evt => {
  el.addEventListener(evt, e => console.log(evt, e.detail));
});
```

**Browser extension:** Install the htmx debugger extension for Chrome/Firefox for visual event tracking.

**Common things to check in logs:**
- `htmx:configRequest` — verify URL, verb, headers, parameters
- `htmx:beforeSwap` — check response status and content
- `htmx:swapError` — inspect swap failures
- `htmx:responseError` — server returned error status

## Swap Timing Issues

**Problem:** New content's JavaScript doesn't execute or run in wrong order.

Scripts in swapped content execute after the swap. If they depend on DOM elements also being swapped, timing can be tricky.

**Fix:** Use `htmx:afterSettle` event instead of `htmx:afterSwap`:

```javascript
// afterSwap: DOM is updated, but CSS transitions haven't settled
// afterSettle: DOM is updated AND settled (classes applied, transitions started)
document.body.addEventListener('htmx:afterSettle', (evt) => {
  initializeWidgets(evt.detail.target);
});
```

**Problem:** Swap animation not playing.

htmx uses a two-phase swap: remove old content (with `htmx-swapping` class), then insert new content (with `htmx-settling` class). Set swap/settle delays:

```html
<div hx-get="/content"
     hx-swap="innerHTML swap:200ms settle:100ms">
</div>
```

```css
.htmx-swapping { opacity: 0; transition: opacity 200ms; }
```

**Problem:** View Transitions not working.

```html
<!-- Requires transition:true AND Chrome 111+ or Safari 18+ -->
<div hx-get="/page" hx-swap="innerHTML transition:true">
```

Ensure elements have `view-transition-name` CSS property for cross-page animations.

## History Cache Problems

**Problem:** Back button shows stale content.

htmx caches page snapshots in `localStorage` for history navigation. The cache can become stale.

**Fix 1:** Disable history cache entirely:

```html
<meta name="htmx-config" content='{"historyCacheSize": 0}'>
```

**Fix 2:** Refresh on history restore:

```javascript
document.body.addEventListener('htmx:historyRestore', (evt) => {
  // Re-fetch dynamic sections after history restore
  htmx.trigger(document.getElementById('live-data'), 'refreshData');
});
```

**Problem:** History entries accumulate for in-page interactions.

Only use `hx-push-url` for navigation-like actions (page changes, tab switches), not for every AJAX interaction.

**Problem:** `localStorage` full on mobile Safari (5MB limit).

Reduce cache size:

```html
<meta name="htmx-config" content='{"historyCacheSize": 5}'>
```

## Script Evaluation

### hx-on (htmx 2.x colon syntax)

```html
<!-- Correct in 2.x: colon syntax, kebab-case events -->
<button hx-get="/data"
        hx-on::before-request="showSpinner()"
        hx-on::after-request="hideSpinner()">
  Load
</button>

<!-- Standard DOM events also work -->
<input hx-on:keyup="validate(this)">
```

Note: `hx-on:` with single colon = standard DOM events. `hx-on::` with double colon = htmx-namespaced events (shorthand for `hx-on:htmx:`).

### Hyperscript integration

Hyperscript (`_="..."`) works alongside htmx but is a separate project:

```html
<script src="https://unpkg.com/hyperscript.org"></script>
<button hx-get="/data"
        _="on htmx:afterSwap add .highlight to #result then wait 2s then remove .highlight from #result">
  Load
</button>
```

### Script tags in swapped content

By default, htmx evaluates `<script>` tags in swapped content. Disable if unwanted:

```html
<meta name="htmx-config" content='{"allowScriptTags": false}'>
```

**Problem:** Script runs multiple times on repeated swaps.

**Fix:** Use `once` modifier or guard with a flag:

```html
<script>
if (!window._widgetInitialized) {
  window._widgetInitialized = true;
  initWidget();
}
</script>
```

Better: use event listeners outside swapped content.

## CORS Issues

**Problem:** htmx request to a different origin fails.

htmx sends custom headers (`HX-Request`, `HX-Target`, etc.) which trigger CORS preflight.

**Server must allow htmx headers:**

```python
# Flask-CORS
CORS(app, expose_headers=[
    "HX-Redirect", "HX-Refresh", "HX-Retarget", "HX-Reswap",
    "HX-Trigger", "HX-Trigger-After-Settle", "HX-Trigger-After-Swap",
    "HX-Push-Url", "HX-Replace-Url"
], allow_headers=[
    "HX-Request", "HX-Target", "HX-Trigger", "HX-Current-URL",
    "Content-Type"
])
```

```javascript
// Express cors
app.use(cors({
  origin: 'https://frontend.example.com',
  allowedHeaders: ['Content-Type', 'HX-Request', 'HX-Target', 'HX-Trigger', 'HX-Current-URL'],
  exposedHeaders: ['HX-Redirect', 'HX-Refresh', 'HX-Trigger', 'HX-Retarget', 'HX-Reswap']
}));
```

**Problem:** Cookies not sent cross-origin.

```html
<meta name="htmx-config" content='{"withCredentials": true}'>
```

Server must also set `Access-Control-Allow-Credentials: true` and specify exact origin (not `*`).

## Common 422 Handling Patterns

By default, htmx does NOT swap on 4xx/5xx responses. For validation errors (422), you usually want to swap error messages.

### Configure responseHandling (htmx 2.x)

```html
<meta name="htmx-config" content='{
  "responseHandling": [
    {"code": "204", "swap": false},
    {"code": "[23]..", "swap": true},
    {"code": "422", "swap": true, "error": false, "target": "#errors"},
    {"code": "[45]..", "swap": false, "error": true}
  ]
}'>
```

### Per-element error targeting

```html
<form hx-post="/contacts"
      hx-target="#contact-list"
      hx-target-422="#form-errors"
      hx-swap="beforeend">
  <div id="form-errors"></div>
  <input name="email" required>
  <button type="submit">Save</button>
</form>
```

Note: `hx-target-*` (status code targeting) requires the `response-targets` extension:

```html
<script src="https://unpkg.com/htmx-ext-response-targets@2/response-targets.js"></script>
<body hx-ext="response-targets">
```

### Server-side pattern

Return the form with inline errors on 422:

```python
@app.post("/contacts")
def create_contact():
    errors = validate(request.form)
    if errors:
        return render_template("contacts/_form.html",
                             errors=errors,
                             values=request.form), 422
    contact = Contact.create(**request.form)
    return render_template("contacts/_row.html", contact=contact), 201
```

### Toast notification on error

```javascript
document.body.addEventListener('htmx:responseError', (evt) => {
  const status = evt.detail.xhr.status;
  const msg = status === 422 ? 'Validation failed'
            : status === 403 ? 'Permission denied'
            : status >= 500 ? 'Server error — please retry'
            : 'Request failed';
  showToast(msg, 'error');
});
```

## Miscellaneous Gotchas

### Elements disappearing after request

**Cause:** No `hx-target` set, so response replaces the triggering element's innerHTML.

**Fix:** Always set explicit `hx-target` for non-form elements.

### Forms submitting twice

**Cause:** Both native form submit and htmx submit fire.

**Fix:** htmx prevents default automatically when `hx-post`/etc is on a `<form>`. If using `hx-trigger="submit"` on a non-form wrapper, call `event.preventDefault()`.

### Select/checkbox values not included

**Cause:** Element is outside the form or `hx-include` scope.

**Fix:** Use `hx-include="[name='my-select']"` or `hx-include="closest form"`.

### htmx not processing dynamically added content

**Cause:** Content added via non-htmx JavaScript (e.g., `innerHTML`) isn't processed.

**Fix:** Call `htmx.process(element)` after inserting content via JS.

### Memory leaks with polling

**Cause:** `hx-trigger="every 2s"` continues even if element is removed from DOM by parent swap.

htmx handles this automatically — polling stops when the element is removed. But if using `setInterval` in swapped scripts, clean up manually:

```javascript
document.body.addEventListener('htmx:beforeCleanupElement', (evt) => {
  const interval = evt.detail.elt._myInterval;
  if (interval) clearInterval(interval);
});
```

### DELETE params sent as query string (htmx 2.x)

htmx 2.x changed DELETE to send params as query strings (per HTTP spec), not form-encoded body.

**Fix server-side:** Read from query params, not body:

```python
# Flask
@app.delete("/items/<id>")
def delete_item(id):
    confirm = request.args.get("confirm")  # NOT request.form
```

### hx-boost breaks file downloads

Boosted links intercept the response and try to swap HTML. File downloads return binary data.

**Fix:** Opt out individual links from boost:

```html
<a href="/download/report.pdf" hx-boost="false">Download PDF</a>
```
