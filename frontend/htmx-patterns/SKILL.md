---
name: htmx-patterns
description: >
  Generate htmx-powered hypermedia-driven UI patterns. Use when user needs htmx,
  hypermedia-driven apps, HTML-over-the-wire, AJAX without JavaScript,
  server-rendered interactive UI, partial page updates, hx-get/hx-post markup,
  htmx with Django/Flask/Express/Go/Rails, infinite scroll, active search,
  click-to-edit, lazy loading, or WebSocket/SSE streaming.
  NOT for React/Vue/Angular SPAs, NOT for full JavaScript frameworks,
  NOT for REST API design, NOT for static site generators.
---

# htmx Patterns

Return HTML fragments from the server. Never return JSON for UI updates. Every response is a rendered partial.

## Setup

```html
<script src="https://unpkg.com/htmx.org@2.0.4"></script>
<!-- Optional: hyperscript -->
<script src="https://unpkg.com/hyperscript.org@0.9.14"></script>
```

## Core HTTP Attributes

Issue requests declaratively. The server returns HTML fragments.

```html
<button hx-get="/items">Load</button>
<form hx-post="/items" hx-target="#list">
  <input name="title" required>
  <button type="submit">Create</button>
</form>
<button hx-put="/items/1">Update</button>
<button hx-patch="/items/1">Partial Update</button>
<button hx-delete="/items/1" hx-confirm="Delete?">Remove</button>
```

Always set `hx-target` when the response should replace a different element than the trigger.

## Targeting (hx-target)

```html
<!-- CSS selector -->
<button hx-get="/data" hx-target="#results">Load</button>
<!-- Relative selectors -->
<button hx-get="/row" hx-target="closest tr">Update Row</button>
<button hx-get="/next" hx-target="next .panel">Load Next</button>
<button hx-get="/prev" hx-target="previous .panel">Load Prev</button>
<!-- this = the triggering element itself -->
<div hx-get="/self" hx-target="this">Replace Me</div>
<!-- find within children -->
<div hx-get="/child" hx-target="find .slot">Fill Slot</div>
```

## Swap Strategies (hx-swap)

Control where returned HTML is placed relative to target.

| Value         | Effect                                      |
|---------------|---------------------------------------------|
| `innerHTML`   | Replace target's children (default)         |
| `outerHTML`   | Replace the entire target element           |
| `beforebegin` | Insert before target as sibling             |
| `afterbegin`  | Insert as first child of target             |
| `beforeend`   | Insert as last child of target (append)     |
| `afterend`    | Insert after target as sibling              |
| `delete`      | Remove the target element                   |
| `none`        | No swap; use for side-effect-only requests  |

### Swap Modifiers

```html
<!-- Settle delay for CSS transitions -->
<div hx-get="/data" hx-swap="innerHTML swap:300ms settle:500ms">Load</div>
<!-- Scroll into view after swap -->
<div hx-get="/more" hx-swap="beforeend scroll:bottom">Append</div>
<!-- Focus scroll on specific element -->
<div hx-get="/item" hx-swap="innerHTML focus-scroll:true">Load</div>
<!-- Show target window position -->
<div hx-get="/top" hx-swap="innerHTML show:top">Top</div>
<!-- View Transition API -->
<div hx-get="/page" hx-swap="innerHTML transition:true">Navigate</div>
```

## Triggers (hx-trigger)

```html
<!-- Default: click for buttons/links, submit for forms, change for inputs -->
<input hx-get="/search" hx-trigger="keyup changed delay:500ms"
       hx-target="#results" name="q">
<!-- Multiple events -->
<div hx-get="/data" hx-trigger="click, keyup[key=='Enter'] from:body">Load</div>
```

### Trigger Modifiers

| Modifier          | Effect                                         |
|-------------------|-------------------------------------------------|
| `changed`         | Fire only if element value changed              |
| `once`            | Fire only once                                  |
| `delay:500ms`     | Debounce—wait 500ms after last event            |
| `throttle:200ms`  | Throttle—fire at most every 200ms               |
| `from:<selector>` | Listen on a different element                   |
| `every 5s`        | Poll every 5 seconds                            |
| `revealed`        | Fire when element scrolls into viewport         |
| `intersect`       | Fire on intersection observer trigger           |
| `load`            | Fire on page load                               |
| `[expr]`          | Event filter: `keyup[key=='Enter']`             |
| `consume`         | Prevent event propagation                       |
| `queue:first`     | Queue strategy: first, last, all, none          |

```html
<!-- Poll with condition to stop -->
<div hx-get="/status" hx-trigger="every 2s[!done]"
     hx-target="this" hx-swap="outerHTML">Checking...</div>
<!-- Intersection observer with threshold -->
<img hx-get="/image/5" hx-trigger="intersect once threshold:0.5"
     hx-swap="outerHTML">
```

## Loading Indicators (hx-indicator)

```html
<button hx-get="/slow" hx-indicator="#spinner">Load</button>
<span id="spinner" class="htmx-indicator">Loading...</span>
```

htmx adds `htmx-request` class to the indicator during requests. Style:

```css
.htmx-indicator { display: none; }
.htmx-request .htmx-indicator, .htmx-request.htmx-indicator { display: inline; }
```

## CSS Transitions

htmx applies lifecycle classes for animations:

```css
/* Fade out old content */
.htmx-swapping { opacity: 0; transition: opacity 0.3s ease-out; }
/* Fade in new content */
.htmx-added { opacity: 0; }
.htmx-settling { opacity: 1; transition: opacity 0.3s ease-in; }
```

Preserve element IDs across swaps for smooth transitions. htmx matches old/new elements by ID and applies settle transitions.

## Boosting (hx-boost)

Convert standard navigation to AJAX. Apply to a container to boost all child links/forms.

```html
<body hx-boost="true">
  <!-- All <a> and <form> elements now use AJAX automatically -->
  <nav>
    <a href="/about">About</a>         <!-- AJAX GET, swaps body -->
    <a href="/contact">Contact</a>
  </nav>
  <form action="/login" method="post"> <!-- AJAX POST, swaps body -->
    <input name="user"><button>Login</button>
  </form>
</body>
```

Opt out individual elements: `<a href="/file.pdf" hx-boost="false">Download</a>`

## History (hx-push-url / hx-replace-url)

```html
<!-- Push new entry to browser history -->
<a hx-get="/page/2" hx-push-url="true" hx-target="#content">Page 2</a>
<!-- Push a custom URL -->
<button hx-get="/api/data" hx-push-url="/dashboard">Dashboard</button>
<!-- Replace current history entry (no back) -->
<a hx-get="/tab/2" hx-replace-url="true" hx-target="#tabs">Tab 2</a>
```

Server can override via response headers: `HX-Push-Url` or `HX-Replace-Url`.

## Forms and Validation

```html
<form hx-post="/contacts" hx-target="#contact-list" hx-swap="beforeend"
      hx-indicator="#form-spinner">
  <input name="name" required minlength="2">
  <input name="email" type="email" required>
  <button type="submit">Add</button>
  <span id="form-spinner" class="htmx-indicator">Saving...</span>
</form>
```

### Server-Side Validation Pattern

Return the form with errors on 422. Use `HX-Retarget` and `HX-Reswap` headers to redirect the response:

Server response (on validation failure):
```http
HTTP/1.1 422 Unprocessable Entity
HX-Retarget: #contact-form
HX-Reswap: outerHTML
```
```html
<form id="contact-form" hx-post="/contacts">
  <input name="email" value="bad" class="error">
  <span class="error-msg">Invalid email</span>
  <button>Retry</button>
</form>
```

### Include Extra Values

```html
<button hx-post="/action" hx-vals='{"key": "value"}'>Go</button>
<button hx-post="/action" hx-include="[name='csrf']">Go</button>
<div hx-post="/save" hx-headers='{"X-CSRF-Token": "abc123"}'>Save</div>
```

## Out-of-Band Swaps (hx-swap-oob)

Update multiple page regions from a single response. Main response swaps normally; additional elements with `hx-swap-oob` swap into their matching IDs.

Server response:
```html
<!-- Main response: swapped into hx-target -->
<tr><td>New Item</td><td>Active</td></tr>
<!-- OOB: swapped into #item-count by matching id -->
<span id="item-count" hx-swap-oob="true">Total: 43</span>
<!-- OOB with swap strategy -->
<div id="notifications" hx-swap-oob="afterbegin">
  <div class="alert">Item created!</div>
</div>
```

## Request Headers (sent by htmx)

| Header              | Value                                    |
|---------------------|------------------------------------------|
| `HX-Request`        | `true` — identifies htmx requests        |
| `HX-Target`         | ID of the target element                 |
| `HX-Trigger`        | ID of the triggered element              |
| `HX-Trigger-Name`   | Name attribute of triggered element      |
| `HX-Current-URL`    | Current browser URL                      |
| `HX-Prompt`         | User response from `hx-prompt`           |
| `HX-Boosted`        | `true` if boosted request                |

## Response Headers (sent by server)

| Header                     | Effect                                    |
|----------------------------|-------------------------------------------|
| `HX-Trigger`               | Trigger client-side event after settle    |
| `HX-Trigger-After-Swap`    | Trigger event after swap                  |
| `HX-Trigger-After-Settle`  | Trigger event after settle                |
| `HX-Redirect`              | Client-side redirect                      |
| `HX-Refresh`               | Full page refresh if `true`               |
| `HX-Push-Url`              | Push URL to history                       |
| `HX-Replace-Url`           | Replace current URL in history            |
| `HX-Reswap`                | Override hx-swap strategy                 |
| `HX-Retarget`              | Override hx-target with CSS selector      |
| `HX-Reselect`              | Select subset of response to swap         |
| `HX-Location`              | Client-side redirect without full reload  |

### Triggering Events from Server

```http
HX-Trigger: {"showMessage": {"level": "success", "text": "Saved!"}}
```

Listen in JS: `document.body.addEventListener("showMessage", (e) => { ... })`

## WebSocket (hx-ws)

```html
<div hx-ext="ws" ws-connect="/ws/chat">
  <div id="messages"></div>
  <form ws-send>
    <input name="message"><button>Send</button>
  </form>
</div>
```

Server sends HTML fragments; htmx swaps them into matching target IDs.

## Server-Sent Events (SSE)

```html
<div hx-ext="sse" sse-connect="/events">
  <div hx-trigger="sse:notification" hx-get="/notifications"
       hx-target="this" hx-swap="innerHTML">
    Waiting for updates...
  </div>
  <!-- Direct swap from SSE data -->
  <div sse-swap="message">Awaiting messages...</div>
</div>
```

## Extensions

```html
<!-- Load extension -->
<script src="https://unpkg.com/htmx-ext-response-targets@2.0.2/response-targets.js"></script>
<!-- Use extension -->
<form hx-post="/submit" hx-ext="response-targets" hx-target-422="#errors">
  <input name="data"><button>Submit</button>
  <div id="errors"></div>
</form>
```

Key extensions: `response-targets`, `loading-states`, `multi-swap`, `path-deps`, `preload`, `remove-me`, `head-support`, `class-tools`.

## Hyperscript Integration

Use `_` attribute for client-side behavior without JavaScript files:

```html
<button hx-delete="/items/1" hx-target="closest tr" hx-swap="outerHTML swap:500ms"
        _="on htmx:beforeSwap add .fade-out to closest <tr/>">
  Delete
</button>
<input type="text" _="on input if my.value.length > 100
                        add .warning to me else remove .warning from me">
<div _="on showMessage(detail) from body put detail.text into me
        then wait 3s then transition my opacity to 0 then remove me">
</div>
```

## Progressive Enhancement

Always provide fallback behavior for non-JS environments:

```html
<!-- Works without JS (full page), enhanced with JS (AJAX) -->
<form action="/search" method="get"
      hx-get="/search" hx-target="#results" hx-push-url="true"
      hx-trigger="submit, keyup changed delay:500ms from:find input">
  <input name="q" placeholder="Search...">
  <button type="submit">Search</button>
</form>
<div id="results"><!-- server-rendered initial results --></div>
```

## Server Framework Integration

### Detect htmx Requests

```python
# Django (with django-htmx)
def view(request):
    template = "partial.html" if request.htmx else "full.html"
    return render(request, template, ctx)
```
```python
# Flask
@app.route("/items")
def items():
    if request.headers.get("HX-Request"):
        return render_template("partials/items.html", items=items)
    return render_template("items.html", items=items)
```
```javascript
// Express
app.get("/items", (req, res) => {
  const template = req.headers["hx-request"] ? "partials/items" : "items";
  res.render(template, { items });
});
```
```go
// Go
func handler(w http.ResponseWriter, r *http.Request) {
    tmpl := "full.html"
    if r.Header.Get("HX-Request") == "true" {
        tmpl = "partial.html"
    }
    t.ExecuteTemplate(w, tmpl, data)
}
```
```ruby
# Rails
def index
  if request.headers["HX-Request"]
    render partial: "items/list", locals: { items: @items }
  else
    render :index
  end
end
```

### CSRF Token Handling

```html
<!-- Django -->
<body hx-headers='{"X-CSRFToken": "{{ csrf_token }}"}'>
<!-- Rails -->
<meta name="csrf-token" content="<%= form_authenticity_token %>">
<body hx-headers='{"X-CSRF-Token": document.querySelector("meta[name=csrf-token]").content}'>
```

Or configure globally:
```javascript
document.body.addEventListener("htmx:configRequest", (e) => {
  e.detail.headers["X-CSRF-Token"] = document.querySelector("meta[name=csrf-token]").content;
});
```

## Common Patterns

### Active Search
```html
<input type="search" name="q" hx-get="/search" hx-trigger="input changed delay:300ms"
       hx-target="#results" hx-indicator="#search-spinner" hx-push-url="true">
<span id="search-spinner" class="htmx-indicator">🔍</span>
<div id="results"></div>
```

### Infinite Scroll
```html
<div id="items">
  <!-- rendered items -->
  <div hx-get="/items?page=2" hx-trigger="revealed" hx-swap="afterend"
       hx-indicator="#load-more-spinner">
    <span id="load-more-spinner" class="htmx-indicator">Loading...</span>
  </div>
</div>
```
Server returns next batch + new sentinel with `page=3`.

### Click-to-Edit
```html
<!-- Display -->
<div hx-target="this" hx-swap="outerHTML">
  <span>John Doe</span>
  <button hx-get="/contacts/1/edit">Edit</button>
</div>
<!-- Server returns on edit click: -->
<form hx-put="/contacts/1" hx-target="this" hx-swap="outerHTML">
  <input name="name" value="John Doe">
  <button type="submit">Save</button>
  <button hx-get="/contacts/1">Cancel</button>
</form>
```

### Lazy Loading
```html
<div hx-get="/dashboard/chart" hx-trigger="revealed" hx-swap="outerHTML">
  <div class="skeleton-loader" style="height:300px"></div>
</div>
```

### Bulk Update
```html
<form hx-post="/items/bulk" hx-target="#item-table" hx-swap="outerHTML">
  <table id="item-table">
    <tr><td><input type="checkbox" name="ids" value="1"></td><td>Item 1</td>
        <td><select name="status_1"><option>Active</option><option>Archived</option></select></td></tr>
    <tr><td><input type="checkbox" name="ids" value="2"></td><td>Item 2</td>
        <td><select name="status_2"><option>Active</option><option>Archived</option></select></td></tr>
  </table>
  <button type="submit">Update Selected</button>
</form>
```

### Delete with Fade Out
```html
<tr>
  <td>Item</td>
  <td><button hx-delete="/items/1" hx-target="closest tr"
              hx-swap="outerHTML swap:500ms"
              hx-confirm="Delete this item?">Delete</button></td>
</tr>
```
```css
tr.htmx-swapping { opacity: 0; transition: opacity 500ms ease-out; }
```

### Polling with Stop Condition
```html
<div hx-get="/jobs/42/status" hx-trigger="load, every 2s[status!='complete']"
     hx-target="this" hx-swap="outerHTML">
  <span class="status">running</span>
</div>
```
Server returns element without polling trigger when job completes.

## Key Principles

1. **Return HTML, not JSON.** Server renders fragments; browser swaps them in.
2. **Use partials.** Composable server templates renderable independently.
3. **Minimize JS.** Use `hx-*` and hyperscript `_`. JS only for complex orchestration.
4. **Progressive enhancement.** Always include `action`/`method` on forms, `href` on links.
5. **Leverage OOB swaps.** Update counters, notifications, dependent regions in one response.
6. **Use response headers.** `HX-Trigger` for events, `HX-Retarget`/`HX-Reswap` for validation.
7. **ID stability.** Consistent IDs across responses for transitions and OOB targeting.
8. **Debounce inputs.** Always use `delay:` on search/typeahead triggers.
9. **Confirm destructive actions.** Use `hx-confirm` on delete operations.
10. **Cache partials.** Server-side cache frequently requested fragments.
