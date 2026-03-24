# htmx Troubleshooting Guide

Diagnosis and solutions for common htmx issues in development and production.

## Table of Contents

- [Swap Timing Problems](#swap-timing-problems)
- [Event Bubbling Issues](#event-bubbling-issues)
- [History Cache Issues](#history-cache-issues)
- [CORS with htmx](#cors-with-htmx)
- [Content-Type Negotiation](#content-type-negotiation)
- [Debugging with htmx.logAll()](#debugging-with-htmxlogall)
- [Extension Conflicts](#extension-conflicts)
- [Memory Leaks with Polling](#memory-leaks-with-polling)
- [SSE Reconnection](#sse-reconnection)
- [Handling 4xx/5xx Responses](#handling-4xx5xx-responses)
- [Common Mistakes and Fixes](#common-mistakes-and-fixes)
- [Performance Optimization](#performance-optimization)

---

## Swap Timing Problems

### Symptom: CSS transitions don't animate

**Cause:** The swap happens too fast for the browser to register the initial state.

```html
<!-- ❌ Transition won't animate — swap is instantaneous -->
<div hx-get="/data" hx-swap="innerHTML">Load</div>
```

**Fix:** Add swap and settle delays:

```html
<!-- ✅ Give browser time to apply transition classes -->
<div hx-get="/data" hx-swap="innerHTML swap:100ms settle:300ms">Load</div>
```

```css
/* Ensure transition CSS is defined */
.htmx-swapping { opacity: 0; transition: opacity 0.1s ease-out; }
.htmx-settling { opacity: 1; transition: opacity 0.3s ease-in; }
```

### Symptom: Element flashes before animating out

**Cause:** The new content is inserted before the old content's exit animation
completes.

**Fix:** Use `swap:` modifier to delay content replacement:

```html
<button hx-delete="/items/1" hx-target="closest tr" hx-swap="outerHTML swap:500ms">
  Delete
</button>
```

```css
tr.htmx-swapping {
  opacity: 0;
  transform: translateX(-100%);
  transition: all 500ms ease-out;
}
```

### Symptom: htmx-settling class never applied

**Cause:** The new content doesn't share element IDs with old content.
htmx uses ID matching to determine which elements should get settling
transitions.

```html
<!-- ❌ No ID matching → no settle transition -->
<div><p>Old content</p></div>
<!-- Response: -->
<div><p>New content</p></div>

<!-- ✅ Matching IDs → settle transition applied -->
<div id="card"><p id="card-text">Old content</p></div>
<!-- Response: -->
<div id="card"><p id="card-text">New content</p></div>
```

### Symptom: OOB swap timing conflicts

**Cause:** Multiple OOB swaps targeting overlapping DOM regions.

**Fix:** Ensure OOB targets don't nest within each other:

```html
<!-- ❌ #parent contains #child — timing conflict -->
<div id="parent" hx-swap-oob="true">
  <div id="child">...</div>
</div>
<div id="child" hx-swap-oob="true">Updated</div>

<!-- ✅ Non-overlapping targets -->
<div id="header-count" hx-swap-oob="true">42</div>
<div id="footer-count" hx-swap-oob="true">42</div>
```

---

## Event Bubbling Issues

### Symptom: Click handler fires on parent instead of child

**Cause:** htmx events bubble up the DOM by default. A parent with `hx-get`
will capture clicks from child elements.

```html
<!-- ❌ Clicking any child triggers the parent's request -->
<div hx-get="/parent-data" hx-target="#result">
  <button>Child Button</button>  <!-- Also triggers /parent-data -->
</div>
```

**Fix:** Use `hx-trigger` with `consume` or explicit selectors:

```html
<!-- ✅ Option 1: Explicit trigger on parent only on direct clicks -->
<div hx-get="/parent-data" hx-target="#result" hx-trigger="click target:div">
  <button hx-get="/child-data" hx-target="#result">Child Button</button>
</div>

<!-- ✅ Option 2: Use consume modifier on child -->
<div hx-get="/parent-data" hx-target="#result">
  <button hx-get="/child-data" hx-target="#result"
          hx-trigger="click consume">Child Button</button>
</div>
```

### Symptom: Events trigger multiple requests

**Cause:** Both `hx-trigger` and default trigger fire.

```html
<!-- ❌ Form submits twice — button click + form submit -->
<form hx-post="/data" hx-target="#result">
  <button hx-post="/data" hx-target="#result">Submit</button>
</form>
```

**Fix:** Only one element should have the `hx-post`:

```html
<!-- ✅ Remove duplicate attribute -->
<form hx-post="/data" hx-target="#result">
  <button type="submit">Submit</button>
</form>
```

### Symptom: Dynamically added elements don't trigger htmx

**Cause:** Elements added by non-htmx JavaScript aren't processed by htmx.

**Fix:** Call `htmx.process()` after adding new content:

```javascript
const newContent = document.createElement("div");
newContent.innerHTML = '<button hx-get="/data">Load</button>';
document.body.appendChild(newContent);
htmx.process(newContent);  // Initialize htmx on new element
```

### Symptom: hx-trigger="from:..." not working

**Cause:** The `from:` selector must match an element that exists when
htmx initializes the trigger.

```html
<!-- ❌ #dynamic-button doesn't exist yet -->
<div hx-get="/data" hx-trigger="click from:#dynamic-button">Wait</div>

<!-- ✅ Use body as relay with custom events instead -->
<div hx-get="/data" hx-trigger="customEvent from:body">Wait</div>
<button _="on click send customEvent to body">Trigger</button>
```

---

## History Cache Issues

### Symptom: Back button shows stale content

**Cause:** htmx caches page content in localStorage for history navigation.
Default cache size is 10 pages.

**Fix:** Configure cache size or disable:

```html
<!-- Adjust cache size -->
<meta name="htmx-config" content='{"historyCacheSize": 20}'>

<!-- Disable history cache entirely -->
<meta name="htmx-config" content='{"historyCacheSize": 0}'>
```

### Symptom: Back button shows unstyled HTML

**Cause:** CSS/JS loaded dynamically aren't restored from history cache.

**Fix:** Use the `head-support` extension:

```html
<script src="https://unpkg.com/htmx-ext-head-support@2.0.3/head-support.js"></script>
<body hx-ext="head-support">
  <!-- head elements now properly tracked during navigation -->
</body>
```

### Symptom: History breaks with hx-boost on complex pages

**Cause:** hx-boost replaces the entire `<body>` by default. Complex
layouts with iframes or heavy JavaScript state are lost.

**Fix:** Use targeted navigation instead of boost:

```html
<!-- ❌ hx-boost replaces everything -->
<body hx-boost="true">

<!-- ✅ Target a specific content area -->
<nav>
  <a hx-get="/page1" hx-target="#content" hx-push-url="true">Page 1</a>
  <a hx-get="/page2" hx-target="#content" hx-push-url="true">Page 2</a>
</nav>
<div id="content"><!-- Only this updates --></div>
```

### Symptom: Forms resubmit on back navigation

**Cause:** History cache restores the form but browser auto-fills and
user accidentally resubmits.

**Fix:** Clear form or show confirmation on `htmx:historyRestore`:

```javascript
document.body.addEventListener("htmx:historyRestore", (e) => {
  document.querySelectorAll("form").forEach(form => form.reset());
});
```

---

## CORS with htmx

### Symptom: Cross-origin htmx requests blocked

**Cause:** htmx sends custom headers (`HX-Request`, `HX-Target`, etc.)
that trigger CORS preflight requests.

**Server-side fix (Express example):**

```javascript
const cors = require("cors");
app.use(cors({
  origin: "https://your-frontend.com",
  allowedHeaders: [
    "Content-Type",
    "HX-Request",
    "HX-Target",
    "HX-Trigger",
    "HX-Current-URL",
    "HX-Boosted",
  ],
  exposedHeaders: [
    "HX-Trigger",
    "HX-Trigger-After-Swap",
    "HX-Trigger-After-Settle",
    "HX-Push-Url",
    "HX-Redirect",
    "HX-Refresh",
    "HX-Retarget",
    "HX-Reswap",
    "HX-Replace-Url",
    "HX-Location",
    "HX-Reselect",
  ],
}));
```

### Symptom: HX-Trigger response header not accessible in JS

**Cause:** Custom response headers aren't exposed to JavaScript by default
in cross-origin responses.

**Fix:** Add `Access-Control-Expose-Headers`:

```http
Access-Control-Expose-Headers: HX-Trigger, HX-Trigger-After-Swap, HX-Push-Url
```

### Symptom: Cookies not sent with cross-origin htmx requests

**Fix:** Configure htmx to include credentials:

```html
<meta name="htmx-config" content='{"withCredentials": true}'>
```

Server must also respond with:

```http
Access-Control-Allow-Credentials: true
Access-Control-Allow-Origin: https://your-frontend.com  <!-- NOT * -->
```

---

## Content-Type Negotiation

### Symptom: Server returns JSON instead of HTML

**Cause:** Server defaults to `application/json` for API endpoints.
htmx requires `text/html` responses.

**Fix:** Check `HX-Request` header and return appropriate content:

```python
# Django
def items(request):
    items = Item.objects.all()
    if request.headers.get("HX-Request"):
        return render(request, "partials/items.html", {"items": items})
    if request.content_type == "application/json":
        return JsonResponse(list(items.values()), safe=False)
    return render(request, "items.html", {"items": items})
```

### Symptom: htmx ignores server response

**Cause:** Response `Content-Type` is not `text/html`. htmx only swaps
HTML content.

**Fix:** Ensure server sends correct Content-Type:

```python
# Flask — always return text/html for htmx
@app.route("/data")
def data():
    html = render_template("partials/data.html", data=get_data())
    return html, 200, {"Content-Type": "text/html; charset=utf-8"}
```

### Symptom: File upload response not processed

**Cause:** Multipart form encoding confuses content negotiation.

**Fix:** Let htmx handle encoding automatically. Don't set `enctype`
if using `hx-post` for non-file forms:

```html
<!-- ✅ For file uploads -->
<form hx-post="/upload" hx-encoding="multipart/form-data" hx-target="#result">
  <input type="file" name="document">
  <button>Upload</button>
</form>
```

---

## Debugging with htmx.logAll()

### Enable Full Logging

```javascript
// In browser console or in a script tag
htmx.logAll();
```

This outputs every htmx event to the console including:
- `htmx:configRequest` — before request is sent
- `htmx:beforeRequest` — request is about to go
- `htmx:afterRequest` — response received
- `htmx:beforeSwap` — about to swap content
- `htmx:afterSwap` — content swapped
- `htmx:afterSettle` — settling complete

### Targeted Event Logging

```javascript
// Log specific events only
document.body.addEventListener("htmx:configRequest", (e) => {
  console.log("Request config:", {
    verb: e.detail.verb,
    path: e.detail.path,
    headers: e.detail.headers,
    parameters: e.detail.parameters,
  });
});

document.body.addEventListener("htmx:beforeSwap", (e) => {
  console.log("Swap details:", {
    target: e.detail.target,
    serverResponse: e.detail.xhr.responseText.substring(0, 200),
    isError: e.detail.isError,
  });
});
```

### Debug Response Inspection

```javascript
// Intercept all responses for debugging
document.body.addEventListener("htmx:afterRequest", (e) => {
  const xhr = e.detail.xhr;
  console.table({
    URL: xhr.responseURL,
    Status: xhr.status,
    "Content-Type": xhr.getResponseHeader("Content-Type"),
    "HX-Trigger": xhr.getResponseHeader("HX-Trigger"),
    "HX-Retarget": xhr.getResponseHeader("HX-Retarget"),
    "Response Length": xhr.responseText.length,
  });
});
```

### Common Debug Patterns

```javascript
htmx.logAll();  // Enable full event logging

// Check if element is htmx-enabled
htmx.closest(element, "[hx-get], [hx-post], [hx-put], [hx-delete]");

// Manually trigger an htmx request
htmx.trigger(document.querySelector("#my-button"), "click");

// Force htmx to re-process element (after dynamic DOM changes)
htmx.process(document.querySelector("#dynamic-content"));

// Log all responses with status and headers
document.body.addEventListener("htmx:afterRequest", (e) => {
  const xhr = e.detail.xhr;
  console.table({
    URL: xhr.responseURL, Status: xhr.status,
    "HX-Trigger": xhr.getResponseHeader("HX-Trigger"),
  });
});
```

---

## Extension Conflicts

### Symptom: Two extensions modify the same behavior

Common conflicts: `response-targets` + `multi-swap` (both modify swap targeting),
`morph` + `head-support` (both process response HTML).

**Fix:** Order extensions and scope them carefully:

```html
<script src="htmx.org.js"></script>
<script src="idiomorph-ext.js"></script>
<script src="head-support.js"></script>
<script src="response-targets.js"></script>

<body hx-ext="morph, head-support">
  <!-- response-targets scoped to this form only -->
  <form hx-ext="response-targets" hx-post="/submit" hx-target-422="#errors">
  </form>
</body>
```

### Symptom: Extension not activating

**Checklist:**
1. Script loaded before htmx elements?
2. `hx-ext` attribute set on element or ancestor?
3. Extension name matches exactly? (`morph` not `idiomorph`)

```html
<!-- ❌ Wrong --> <body hx-ext="idiomorph">
<!-- ✅ Correct --> <body hx-ext="morph">
```

Disable extensions per-element: `<div hx-ext="ignore:morph">`

---

## Memory Leaks with Polling

### Symptom: Browser slows down over time with polling

**Cause:** Each poll response adds new DOM nodes or event listeners that
accumulate.

**Fix:** Ensure polling replaces content rather than appending:

```html
<!-- ❌ Appending creates unbounded growth -->
<div hx-get="/updates" hx-trigger="every 5s" hx-swap="beforeend">

<!-- ✅ Replacing content prevents growth -->
<div hx-get="/updates" hx-trigger="every 5s" hx-swap="innerHTML">
```

### Symptom: Polling continues after element is removed

**Cause:** htmx polling is tied to the DOM element. If element is removed
via JS (not htmx), polling may persist.

**Fix:** Use htmx to remove elements, or manually clean up:

```javascript
// Remove element AND cancel its polling
htmx.remove(document.getElementById("polling-element"));

// Or: remove element and trigger cleanup
const el = document.getElementById("polling-element");
el.dispatchEvent(new Event("htmx:abort"));
el.remove();
```

### Symptom: Multiple poll timers after swap

**Cause:** If a swap replaces an element that was polling, and the new
element also polls, the old timer may still be running.

**Fix:** Use `outerHTML` swap so the old element (and its timer) is removed:

```html
<!-- ✅ outerHTML replaces the element, cleaning up old timers -->
<div id="status" hx-get="/status" hx-trigger="every 5s" hx-swap="outerHTML">
  Status: Running
</div>
```

### Conditional Polling Stop

```html
<!-- Stop polling when condition met -->
<div hx-get="/job/status" hx-trigger="every 2s [!isComplete]"
     hx-target="this" hx-swap="outerHTML">
  <span id="status">Processing...</span>
  <script>var isComplete = false;</script>
</div>
```

Server returns without polling trigger when done:

```html
<div>
  <span id="status">✅ Complete!</span>
  <!-- No hx-trigger → polling stops -->
</div>
```

---

## SSE Reconnection

### Symptom: SSE connection drops and doesn't reconnect

**Cause:** The htmx SSE extension reconnects automatically, but not all
disconnection types are handled.

**Fix:** Configure reconnect behavior:

```html
<div hx-ext="sse" sse-connect="/events"
     sse-reconnect="5000">  <!-- Reconnect after 5 seconds -->
  <div sse-swap="message">Waiting...</div>
</div>
```

### Symptom: SSE floods server after reconnect

**Cause:** All clients reconnect simultaneously after a server restart,
creating a thundering herd.

**Fix:** Add jitter to reconnection on the server:

```python
# Flask — use retry field to stagger reconnections
@app.route("/events")
def events():
    def generate():
        import random
        retry_ms = 3000 + random.randint(0, 2000)  # 3-5 second jitter
        yield f"retry: {retry_ms}\n\n"
        while True:
            data = get_next_event()
            yield f"event: message\ndata: {data}\n\n"
    return Response(generate(), mimetype="text/event-stream")
```

### Symptom: SSE events missed during reconnection

**Fix:** Use `Last-Event-ID` header and server-side event tracking:

```python
@app.route("/events")
def events():
    last_id = request.headers.get("Last-Event-ID", "0")

    def generate():
        events = get_events_since(int(last_id))
        for event in events:
            yield f"id: {event.id}\nevent: update\ndata: {event.html}\n\n"
        # Then switch to live streaming
        for event in stream_live_events():
            yield f"id: {event.id}\nevent: update\ndata: {event.html}\n\n"

    return Response(generate(), mimetype="text/event-stream")
```

### SSE Heartbeat to Detect Dead Connections

```python
def generate():
    while True:
        event = get_event_nonblocking()
        if event:
            yield f"event: update\ndata: {event.html}\n\n"
        else:
            yield ": heartbeat\n\n"  # Comment-only keep-alive
        time.sleep(1)
```

---

## Handling 4xx/5xx Responses

### Default Behavior

By default, htmx does **not** swap content for responses with error status
codes (4xx, 5xx). The element remains unchanged.

### Swap Error Responses

Use the `response-targets` extension to target different elements based on
status code:

```html
<script src="https://unpkg.com/htmx-ext-response-targets@2.0.2/response-targets.js"></script>

<form hx-post="/submit" hx-ext="response-targets"
      hx-target="#success-area" hx-target-422="#form-errors"
      hx-target-500="#server-error" hx-target-4*="#client-error">
  <input name="email" required>
  <button>Submit</button>
</form>
<div id="success-area"></div>
<div id="form-errors"></div>
<div id="client-error"></div>
<div id="server-error"></div>
```

### Global Error Handling

```javascript
document.body.addEventListener("htmx:responseError", (e) => {
  const status = e.detail.xhr.status;
  const target = e.detail.target;

  if (status === 401) {
    window.location.href = "/login";
    return;
  }

  if (status === 403) {
    target.innerHTML = '<div class="alert error">Access denied</div>';
    return;
  }

  if (status === 429) {
    const retryAfter = e.detail.xhr.getResponseHeader("Retry-After") || 5;
    target.innerHTML = `<div class="alert warning">Rate limited. Retrying in ${retryAfter}s...</div>`;
    setTimeout(() => htmx.trigger(e.detail.elt, "htmx:trigger"), retryAfter * 1000);
    return;
  }

  if (status >= 500) {
    target.innerHTML = '<div class="alert error">Server error. Please try again.</div>';
  }
});
```

### Custom beforeSwap for Error Response Handling

```javascript
document.body.addEventListener("htmx:beforeSwap", (e) => {
  // Allow 422 responses to swap (for validation errors)
  if (e.detail.xhr.status === 422) {
    e.detail.shouldSwap = true;
    e.detail.isError = false;
  }

  // Redirect on 401
  if (e.detail.xhr.status === 401) {
    e.detail.shouldSwap = false;
    window.location.href = "/login";
  }
});
```

### Retry with Exponential Backoff

```javascript
document.body.addEventListener("htmx:sendError", (e) => {
  const elt = e.detail.elt;
  let retries = parseInt(elt.dataset.retries || "0");

  if (retries < 3) {
    elt.dataset.retries = retries + 1;
    const delay = Math.pow(2, retries) * 1000; // 1s, 2s, 4s
    setTimeout(() => htmx.trigger(elt, "retry"), delay);
  } else {
    elt.dataset.retries = "0";
    const target = document.querySelector(elt.getAttribute("hx-target") || "this");
    target.innerHTML = '<div class="alert error">Request failed after 3 retries.</div>';
  }
});
```

---

## Common Mistakes and Fixes

### Missing ID on OOB target

```html
<!-- ❌ No id → OOB swap silently fails -->
<span hx-swap-oob="true">Updated count: 5</span>

<!-- ✅ Must have matching id -->
<span id="count" hx-swap-oob="true">Updated count: 5</span>
```

### Using hx-on incorrectly

```html
<!-- ❌ hx-on uses htmx event names without the htmx: prefix -->
<button hx-get="/data" hx-on:htmx:after-request="alert('wrong')">

<!-- ✅ Use hx-on with shorthand (no htmx: prefix, use :: separator) -->
<button hx-get="/data" hx-on::after-request="alert('done')">
```

### Forgetting hx-target with hx-swap

```html
<!-- ❌ Without hx-target, swaps into the triggering element -->
<button hx-get="/user-details" hx-swap="innerHTML">View Details</button>
<!-- Result: button's text is replaced with user details! -->

<!-- ✅ Always specify target when swapping elsewhere -->
<button hx-get="/user-details" hx-target="#detail-panel" hx-swap="innerHTML">
  View Details
</button>
```

### Incorrect hx-vals syntax

```html
<!-- ❌ Missing quotes around JSON -->
<button hx-post="/action" hx-vals={key: value}>Go</button>

<!-- ✅ Single quotes wrapping valid JSON -->
<button hx-post="/action" hx-vals='{"key": "value"}'>Go</button>

<!-- ✅ Or use JavaScript evaluation -->
<button hx-post="/action" hx-vals="js:{key: getSomeValue()}">Go</button>
```

### Polling element removed by parent swap

```html
<!-- ❌ Parent swap removes the polling child -->
<div id="parent" hx-get="/content" hx-trigger="click" hx-target="this">
  <div hx-get="/status" hx-trigger="every 5s">Status: OK</div>
</div>
<!-- After click: polling element is replaced, timer lost -->

<!-- ✅ Keep polling element outside the swap target -->
<div id="content-area" hx-get="/content" hx-trigger="click" hx-target="this">
  Static content
</div>
<div hx-get="/status" hx-trigger="every 5s" hx-target="this" hx-swap="innerHTML">
  Status: OK
</div>
```

---

## Performance Tips

- **Return minimal HTML fragments** — never full pages for htmx requests
- **Use `hx-select`** to extract a fragment from a full page response: `hx-select="#content"`
- **Lazy load** below-the-fold content with `hx-trigger="revealed"`
- **Preload on hover** with the preload extension: `preload="mouseover"`
- **Cache server-side partials** — they're usually small and frequently requested
- **Debounce inputs** — always use `delay:300ms` on search/typeahead triggers
- **Throttle scroll triggers** — `hx-trigger="scroll throttle:500ms from:window"`
