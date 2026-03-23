---
name: htmx-patterns
description:
  positive: "Use when user builds with htmx, asks about hx-get, hx-post, hx-swap, hx-target, hx-trigger, htmx events, hypermedia-driven architecture, or server-side HTML rendering with dynamic behavior."
  negative: "Do NOT use for React/Vue/Svelte SPA patterns, REST API design for JSON APIs, or Alpine.js standalone usage."
---

# htmx Patterns for Hypermedia-Driven Applications

## Philosophy

Return HTML from the server, not JSON. Let the server own state, rendering, and business logic. The client declares *how* to update the DOM via `hx-*` attributes—the server decides *what* to render. This is HATEOAS: the response includes the controls (links, forms, buttons) the user can act on next.

## Installation

```html
<script src="https://unpkg.com/htmx.org@2"></script>
```

## Core AJAX Attributes

Issue HTTP requests from any element. The server returns HTML fragments, not JSON.

```html
<button hx-get="/items">Load Items</button>
<button hx-post="/items" hx-vals='{"name":"Widget"}'>Create</button>
<button hx-put="/items/1">Update</button>
<button hx-patch="/items/1">Patch</button>
<button hx-delete="/items/1">Delete</button>
```

Default behavior: replace `innerHTML` of the triggering element with the response.

## hx-swap Strategies

Control how the response HTML is inserted into the DOM.

| Strategy      | Effect                                         |
|---------------|-------------------------------------------------|
| `innerHTML`   | Replace inner content of target (default)       |
| `outerHTML`   | Replace the entire target element               |
| `beforebegin` | Insert before the target element                |
| `afterbegin`  | Insert inside target, before first child        |
| `beforeend`   | Insert inside target, after last child (append) |
| `afterend`    | Insert after the target element                 |
| `delete`      | Remove the target element                       |
| `none`        | Do nothing with the response body               |

### Swap Modifiers

Append modifiers after the strategy, space-separated:

```html
<!-- Delay swap by 1 second -->
<div hx-get="/data" hx-swap="innerHTML swap:1s">Loading...</div>

<!-- Scroll target into view after swap -->
<div hx-get="/messages" hx-swap="beforeend scroll:bottom"></div>

<!-- Use View Transitions API -->
<div hx-get="/page" hx-swap="innerHTML transition:true"></div>

<!-- Combine modifiers -->
<div hx-get="/data" hx-swap="outerHTML swap:200ms settle:100ms scroll:top"></div>
```

## hx-target

Direct the response to a different element than the trigger.

```html
<!-- Target by ID -->
<button hx-get="/results" hx-target="#output">Search</button>
<div id="output"></div>

<!-- Target self -->
<button hx-get="/status" hx-target="this">Refresh</button>

<!-- Relative selectors -->
<button hx-delete="/item/5" hx-target="closest tr" hx-swap="outerHTML">Delete</button>
<button hx-get="/details" hx-target="find .detail-panel">Show</button>
<input hx-get="/validate" hx-target="next .error-msg">
<input hx-get="/validate" hx-target="previous .label">
```

Relative selectors: `closest`, `find`, `next`, `previous`—build reusable components without hardcoded IDs.

## hx-trigger

Control when requests fire. Default: `click` for buttons/links, `change` for inputs/selects, `submit` for forms.

```html
<!-- Explicit trigger -->
<div hx-get="/news" hx-trigger="click">Click me</div>

<!-- Trigger on input change with debounce -->
<input hx-get="/search" hx-trigger="keyup changed delay:300ms" hx-target="#results">

<!-- Trigger when element scrolls into view -->
<div hx-get="/lazy-content" hx-trigger="revealed">Loading...</div>

<!-- Trigger on intersection (visibility threshold) -->
<div hx-get="/ad" hx-trigger="intersect threshold:0.5">Ad slot</div>

<!-- Polling -->
<div hx-get="/notifications" hx-trigger="every 5s">0 notifications</div>

<!-- Custom event -->
<div hx-get="/refresh" hx-trigger="myapp:refresh from:body">Data</div>

<!-- Multiple triggers -->
<input hx-get="/search" hx-trigger="keyup changed delay:300ms, search">

<!-- Load on page load -->
<div hx-get="/initial-data" hx-trigger="load">Loading...</div>
```

### Trigger Modifiers

`changed` (only if value changed), `delay:<time>` (debounce), `throttle:<time>`, `once`, `from:<selector>` (listen elsewhere), `consume` (stop propagation), `queue:first|last|all|none`.

## Request Configuration

### hx-vals — Send Extra Values

```html
<!-- JSON values -->
<button hx-post="/action" hx-vals='{"key":"value","count":5}'>Go</button>

<!-- JavaScript expression (prefix with js:) -->
<button hx-post="/action" hx-vals="js:{time: Date.now()}">Go</button>
```

### hx-headers — Custom Request Headers

```html
<button hx-get="/api" hx-headers='{"X-Custom":"value"}'>Fetch</button>
```

### hx-include — Include Additional Inputs

```html
<!-- Include inputs from another form -->
<button hx-post="/submit" hx-include="#filter-form">Submit</button>

<!-- Include closest form -->
<button hx-post="/submit" hx-include="closest form">Submit</button>
```

### hx-params — Filter Parameters

```html
<!-- Send only specific params -->
<form hx-post="/save" hx-params="name,email">...</form>

<!-- Exclude params -->
<form hx-post="/save" hx-params="not password_confirm">...</form>

<!-- Send no params -->
<button hx-post="/ping" hx-params="none">Ping</button>
```

## OOB Swaps

Update multiple elements from a single response. Elements with `hx-swap-oob` swap into matching DOM elements regardless of `hx-target`.

### Server Response

```html
<!-- Main content (goes to hx-target) -->
<div id="item-list"><p>Updated item list...</p></div>

<!-- OOB: update notification count anywhere on page -->
<span id="notification-count" hx-swap-oob="true">3</span>

<!-- OOB with specific strategy -->
<div id="toast-container" hx-swap-oob="beforeend">
  <div class="toast">Item saved!</div>
</div>
```

### OOB Patterns

Use OOB for toast notifications (`beforeend`), counter/badge updates after CRUD, nav state refresh after login, and sidebar sync when main content changes.

## History and URL Management

```html
<a hx-get="/page/2" hx-push-url="true">Page 2</a>
<button hx-get="/search?q=foo" hx-push-url="/search/foo">Search</button>
<button hx-get="/tab/settings" hx-replace-url="true">Settings</button>
```

Use `hx-push-url` for navigational actions. Use `hx-replace-url` for state changes that shouldn't create history entries.

## hx-boost — Progressive Enhancement

Convert standard links and forms to AJAX automatically:

```html
<body hx-boost="true">
  <a href="/about">About</a>             <!-- AJAX with push-url -->
  <form action="/login" method="post">...</form> <!-- AJAX submit -->
</body>
```

## Loading Indicators

```html
<button hx-get="/slow" hx-indicator="#spinner">Load</button>
<span id="spinner" class="htmx-indicator">Loading...</span>
```

The `htmx-request` class is added to the trigger during requests. Style indicators with:

```css
.htmx-indicator { opacity: 0; transition: opacity 200ms; }
.htmx-request .htmx-indicator { opacity: 1; }
```

## Confirmation and Prompts

```html
<button hx-delete="/items/1" hx-confirm="Delete this item?">Delete</button>
```

## CSS Transitions

htmx adds `htmx-added`, `htmx-settling`, `htmx-swapping` classes during swaps for CSS animations:

```css
.fade-in.htmx-added { opacity: 0; }
.fade-in.htmx-settling { opacity: 1; transition: opacity 300ms; }
```

## Forms

### Inline Validation

```html
<form hx-post="/register" hx-target="this" hx-swap="outerHTML">
  <input name="email" hx-post="/validate/email"
         hx-trigger="change" hx-target="next .error" hx-swap="innerHTML">
  <span class="error"></span>

  <input name="username" hx-post="/validate/username"
         hx-trigger="keyup changed delay:500ms" hx-target="next .error" hx-swap="innerHTML">
  <span class="error"></span>

  <button type="submit">Register</button>
</form>
```

Server returns empty string for valid fields, error HTML for invalid.

### File Upload with Progress

```html
<form hx-post="/upload" hx-encoding="multipart/form-data"
      hx-indicator="#upload-progress">
  <input type="file" name="document">
  <button type="submit">Upload</button>
  <progress id="upload-progress" class="htmx-indicator" value="0" max="100"></progress>
</form>

<script>
htmx.on('#upload-form', 'htmx:xhr:progress', function(evt) {
  htmx.find('#upload-progress').setAttribute('value', evt.detail.loaded/evt.detail.total * 100);
});
</script>
```

### Multi-Step Forms

Return the next step's HTML from the server. Each step is a partial that replaces the form content:

```html
<div id="wizard">
  <form hx-post="/wizard/step1" hx-target="#wizard" hx-swap="innerHTML">
    <input name="name" required>
    <button type="submit">Next →</button>
  </form>
</div>
```

Server responds with step 2's form HTML targeting the same container.

## Infinite Scroll and Pagination

### Infinite Scroll (revealed trigger)

```html
<table id="results">
  <tr>...</tr>
  <!-- Last row triggers next page load -->
  <tr hx-get="/items?page=2" hx-trigger="revealed" hx-swap="afterend" hx-target="this">
    <td>Loading more...</td>
  </tr>
</table>
```

The server returns new rows plus a new sentinel row pointing to page 3.

### Click-to-Load

```html
<div id="feed"><!-- items --></div>
<button id="load-more" hx-get="/feed?cursor=abc123" hx-target="#feed" hx-swap="beforeend">
  Load More
</button>
```

Server returns items and an OOB swap to update the button's `hx-get` with the next cursor.

## Real-Time Updates

### Polling

```html
<div hx-get="/live-score" hx-trigger="every 2s" hx-swap="innerHTML">
  Score: 0-0
</div>
```

### Server-Sent Events (SSE Extension)

```html
<script src="https://unpkg.com/htmx-ext-sse@2/sse.js"></script>

<div hx-ext="sse" sse-connect="/events" sse-swap="message">
  Waiting for updates...
</div>

<!-- Listen for named events -->
<div hx-ext="sse" sse-connect="/events">
  <div sse-swap="notification">No notifications</div>
  <div sse-swap="score-update">Score: 0-0</div>
</div>
```

### WebSocket Extension

```html
<script src="https://unpkg.com/htmx-ext-ws@2/ws.js"></script>

<div hx-ext="ws" ws-connect="/chat-socket">
  <div id="messages"></div>
  <form ws-send>
    <input name="message">
    <button type="submit">Send</button>
  </form>
</div>
```

Server pushes HTML fragments via WebSocket. Include `hx-swap-oob` in pushed messages to target specific elements.

## Extensions

Install extensions separately from htmx core:

| Extension          | Purpose                                           |
|--------------------|---------------------------------------------------|
| `sse`              | Server-Sent Events support                        |
| `ws`               | WebSocket support                                 |
| `response-targets` | Different targets for different HTTP status codes  |
| `head-support`     | Merge `<head>` elements on swap                   |
| `preload`          | Preload linked content on hover/focus             |
| `loading-states`   | Declarative loading states                        |
| `multi-swap`       | Swap multiple targets from a single response      |
| `path-deps`        | Declare path-based dependencies between elements  |

### response-targets — Error Handling by Status Code

```html
<script src="https://unpkg.com/htmx-ext-response-targets@2/response-targets.js"></script>

<body hx-ext="response-targets">
  <form hx-post="/login" hx-target="#content" hx-target-422="#errors" hx-target-5*="#server-error">
    ...
  </form>
  <div id="content"></div>
  <div id="errors"></div>
  <div id="server-error"></div>
</body>
```

## htmx Events

Key lifecycle events: `htmx:beforeRequest`, `htmx:afterRequest`, `htmx:beforeSwap`, `htmx:afterSwap`, `htmx:afterSettle`, `htmx:responseError`, `htmx:sendError`, `htmx:timeout`.

```javascript
document.body.addEventListener('htmx:afterSwap', function(evt) {
  // Re-initialize third-party widgets in swapped content
});

document.body.addEventListener('htmx:responseError', function(evt) {
  alert('Request failed: ' + evt.detail.xhr.status);
});
```

### Inline Event Handlers

```html
<button hx-get="/data" hx-on::after-swap="alert('Loaded!')">Load</button>
<button hx-get="/data" hx-on::before-request="if(!confirm('Sure?')) event.preventDefault()">Load</button>
```

## Response Headers

The server controls client behavior via response headers:

| Header                    | Effect                                          |
|---------------------------|--------------------------------------------------|
| `HX-Redirect`            | Client-side redirect                             |
| `HX-Refresh`             | Full page refresh                                |
| `HX-Retarget`            | Override `hx-target` from server side            |
| `HX-Reswap`              | Override `hx-swap` from server side              |
| `HX-Trigger`             | Trigger client-side events after response        |
| `HX-Trigger-After-Swap`  | Trigger events after swap                        |
| `HX-Trigger-After-Settle`| Trigger events after settle                      |
| `HX-Push-Url`            | Push URL to history from server side             |
| `HX-Replace-Url`         | Replace URL from server side                     |

### Server-Triggered Events

```python
# Python/Flask example
@app.post("/items")
def create_item():
    # ... create item ...
    response = make_response(render_template("item.html", item=item))
    response.headers["HX-Trigger"] = json.dumps({"itemCreated": {"id": item.id}})
    return response
```

```html
<!-- Client listens for the event -->
<div hx-get="/item-count" hx-trigger="itemCreated from:body">Count: 0</div>
```

## Server-Side Patterns

### Return Partial HTML

Return only the fragment that changed, not the entire page:

```python
# Flask
@app.get("/items")
def items():
    items = get_items()
    if request.headers.get("HX-Request"):
        return render_template("partials/item_list.html", items=items)
    return render_template("full_page.html", items=items)
```

### 204 No Content

Return `204` when no DOM update is needed (the request succeeded but there's nothing to swap):

```python
@app.delete("/items/<id>")
def delete_item(id):
    remove_item(id)
    return "", 204
```

Pair with `hx-swap="delete"` on the client to remove the element without server-returned HTML.

### Template Fragments

Organize templates so partials work for both full renders and htmx responses:

```html
<!-- templates/items.html -->
{% extends "base.html" %}
{% block content %}{% include "partials/item_list.html" %}{% endblock %}

<!-- templates/partials/item_list.html (returned directly for htmx) -->
{% for item in items %}
  <div class="item" id="item-{{ item.id }}">{{ item.name }}</div>
{% endfor %}
```

## Backend Integration
| Framework     | Detect htmx Request                              | Notes                                          |
|---------------|---------------------------------------------------|------------------------------------------------|
| Django        | `request.htmx` (via `django-htmx` middleware)     | CSRF: `{% csrf_token %}` in forms, `hx-headers='{"X-CSRFToken":"{{ csrf_token }}"}'` for non-form |
| Flask         | `request.headers.get("HX-Request")`               | Use `flask-htmx` extension; organize Jinja2 partials in `partials/` |
| Go + templ    | `r.Header.Get("HX-Request")`                      | Render individual `templ` components as htmx fragments |
| Rails         | Turbo Frames overlap conceptually                  | htmx is framework-agnostic; Turbo uses custom elements, htmx uses attributes |

## Anti-Patterns

- **Over-fragmenting**: Do not split every element into its own endpoint. Group related updates into meaningful HTML chunks.
- **Too many requests**: Avoid polling every 500ms or triggering on every keystroke without debounce. Use `delay:`, `throttle:`, and `changed` modifiers.
- **Ignoring accessibility**: Set `aria-live="polite"` on dynamically updating regions. Manage focus after swaps. Use semantic HTML in fragments.
- **Duplicating server logic on client**: If you're writing JS to validate or filter data the server handles, move it server-side and return correct HTML.
- **Using htmx as a JSON client**: htmx expects HTML responses. For JSON, use `fetch()` directly.
- **Ignoring HTTP status codes**: Return `422` for validation errors, `204` for no-content deletes, `286` to stop polling. Use `response-targets` extension for status-based routing.
