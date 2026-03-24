---
name: htmx-patterns
description: >
  USE when writing htmx attributes, building hypermedia-driven UIs, adding hx-get/hx-post/hx-put/hx-patch/hx-delete,
  configuring hx-swap/hx-target/hx-trigger, implementing active search, infinite scroll, inline editing, click-to-edit,
  bulk operations, out-of-band swaps (hx-swap-oob), progressive enhancement with hx-boost, browser history with hx-push-url,
  loading indicators (hx-indicator), htmx extensions (sse, ws, head-support, preload, json-enc, multi-swap),
  server-side partial templates for htmx, or integrating htmx with Express/Django/Flask/Rails/Go backends.
  DO NOT USE for React, Vue, Angular, Svelte, or SPA framework questions. DO NOT USE for general JavaScript DOM manipulation
  unrelated to htmx. DO NOT USE for REST API design without htmx context.
---

# htmx Patterns (2.x)

## Philosophy

htmx extends HTML as a hypermedia. Return HTML from the server, not JSON. Any element issues HTTP requests. Any element updates any part of the DOM. Use progressive enhancement. No build step. ~14 KB gzipped.

Key principles:
- HTML is the transfer format (HTML over the wire)
- Server renders all markup; client swaps fragments
- Attributes on HTML elements replace client-side JS
- Works with any backend that returns HTML
- Use `hx-` or `data-hx-` prefix (both valid in 2.x)

Install: `<script src="https://unpkg.com/htmx.org@2"></script>`

## Core Request Attributes

Issue HTTP requests from any element:

```html
<button hx-get="/api/items">Load</button>
<form hx-post="/api/items">...</form>
<button hx-put="/api/items/1">Update</button>
<button hx-patch="/api/items/1">Patch</button>
<button hx-delete="/api/items/1?confirm=true">Delete</button>
```

**htmx 2.x change:** `hx-delete` sends params as query strings (not form-encoded body), matching HTTP spec.

By default, `<form>` includes all inputs. Non-form elements include themselves. Use `hx-include` to pull in additional inputs.

## Targeting — hx-target

Specify where the response HTML lands using a CSS selector:

```html
<button hx-get="/fragment" hx-target="#results">Search</button>
<div id="results"><!-- response goes here --></div>
```

Special values: `this` (the element itself), `closest <selector>`, `find <selector>`, `next <selector>`, `previous <selector>`.

## Swapping — hx-swap

Control how content is inserted. Strategies:

| Value         | Behavior                                   |
|---------------|-------------------------------------------|
| `innerHTML`   | Replace target's children (default)       |
| `outerHTML`   | Replace the entire target element         |
| `beforebegin` | Insert before the target                  |
| `afterbegin`  | Insert inside target, before first child  |
| `beforeend`   | Insert inside target, after last child    |
| `afterend`    | Insert after the target                   |
| `delete`      | Delete the target element                 |
| `none`        | No swap; still process response headers   |

Modifiers (append to swap value):

```html
<div hx-get="/data" hx-swap="innerHTML swap:300ms settle:500ms scroll:top show:top focus-scroll:true">
```

- `swap:<time>` — delay before old content is removed
- `settle:<time>` — delay before new content settles
- `scroll:top|bottom` — scroll target after swap
- `show:top|bottom` — scroll element into viewport
- `transition:true` — use View Transitions API (Chrome 111+, Safari 18+)

## Triggering — hx-trigger

Control when requests fire:

```html
<!-- Default: click for buttons/links, submit for forms, change for inputs -->
<input hx-get="/search" hx-trigger="keyup changed delay:300ms" hx-target="#results">

<!-- Multiple triggers -->
<div hx-get="/poll" hx-trigger="every 5s, click">

<!-- Modifiers -->
<input hx-get="/validate" hx-trigger="keyup changed delay:500ms">
<div hx-get="/news" hx-trigger="load">
<div hx-get="/more" hx-trigger="revealed">
<div hx-get="/more" hx-trigger="intersect once threshold:0.5">
```

Modifiers: `once`, `changed`, `delay:<time>`, `throttle:<time>`, `from:<selector>`, `target:<selector>`, `consume`, `queue:first|last|all|none`.

**htmx 2.x change:** Use `hx-on:<event>` (colon syntax, kebab-case) for inline event handlers:
```html
<button hx-get="/data" hx-on:htmx:before-request="showSpinner()">Load</button>
```

## CSS Transitions

htmx adds/removes CSS classes during swap lifecycle:

1. `htmx-request` — added to element (or hx-indicator target) when request starts
2. `htmx-swapping` — added to target during swap phase
3. `htmx-settling` — added to target during settle phase
4. `htmx-added` — added to new content during settle phase

```css
.fade-me-in.htmx-added { opacity: 0; }
.fade-me-in { opacity: 1; transition: opacity 300ms ease-in; }
```

Use View Transitions API for animated swaps:
```html
<div hx-get="/page" hx-swap="innerHTML transition:true">
```

## Loading Indicators — hx-indicator

Show a spinner while request is in-flight:

```html
<button hx-get="/slow" hx-indicator="#spinner">Load</button>
<span id="spinner" class="htmx-indicator">Loading...</span>
```

```css
.htmx-indicator { display: none; }
.htmx-request .htmx-indicator, .htmx-request.htmx-indicator { display: inline; }
```

The `htmx-request` class is added to the indicator's parent (or the indicator itself if targeted directly).

## Request Headers (sent by htmx)

Every htmx request includes these headers — use server-side to detect htmx requests:

| Header          | Value                                    |
|-----------------|------------------------------------------|
| `HX-Request`    | `true` — always present on htmx requests |
| `HX-Target`     | CSS id of the target element             |
| `HX-Trigger`    | CSS id of the triggered element          |
| `HX-Trigger-Name` | `name` attribute of triggered element  |
| `HX-Boosted`    | `true` if request is via hx-boost        |
| `HX-Current-URL`| Current browser URL                      |
| `HX-Prompt`     | User response from `hx-prompt`           |

Server-side check pattern:
```python
# Flask
if request.headers.get("HX-Request"):
    return render_template("partial.html")
return render_template("full.html")
```

## Response Headers (sent by server)

Control client behavior from the server:

| Header           | Effect                                         |
|------------------|-------------------------------------------------|
| `HX-Redirect`    | Client-side redirect to URL                    |
| `HX-Refresh`     | Full page refresh if `true`                    |
| `HX-Retarget`    | CSS selector — override hx-target              |
| `HX-Reswap`      | Override hx-swap strategy                      |
| `HX-Trigger`     | Trigger client-side events (JSON for multiple) |
| `HX-Trigger-After-Settle` | Trigger events after settle phase      |
| `HX-Trigger-After-Swap`   | Trigger events after swap phase        |
| `HX-Push-Url`    | Push URL into browser history                  |
| `HX-Replace-Url` | Replace current URL without history entry      |

```python
# Django — trigger a toast notification
response = HttpResponse(render_to_string("row.html", ctx))
response["HX-Trigger"] = json.dumps({"showToast": "Item saved"})
return response
```

## Boosting — hx-boost

Progressive enhancement: convert all links and forms inside a container to AJAX:

```html
<div hx-boost="true">
  <a href="/about">About</a>         <!-- becomes AJAX GET, swaps body -->
  <form action="/login" method="post"> <!-- becomes AJAX POST -->
    ...
  </form>
</div>
```

Boosted requests swap `<body>` by default. They push URL to history automatically. Add `hx-push-url="false"` to suppress. Use `hx-boost="false"` on individual elements to opt out.

## History — hx-push-url / hx-replace-url

```html
<a hx-get="/page/2" hx-push-url="true">Page 2</a>
<a hx-get="/page/2" hx-replace-url="true">Page 2</a>  <!-- no back button entry -->
<a hx-get="/page/2" hx-push-url="/custom-url">Page 2</a>  <!-- custom URL -->
```

htmx saves/restores page snapshots in `localStorage` for back/forward navigation.

## Validation — hx-validate

```html
<form hx-post="/submit" hx-validate="true">
  <input type="email" required name="email">
  <button type="submit">Submit</button>
</form>
```

When `hx-validate="true"`, htmx triggers HTML5 constraint validation before issuing requests. Non-form elements with `hx-validate` validate enclosing form inputs.

## Out-of-Band Swaps — hx-swap-oob

Update multiple unrelated DOM regions in one response:

**Server response:**
```html
<!-- Primary content swapped into hx-target -->
<div id="item-list">...updated list...</div>

<!-- OOB: also update the cart counter -->
<span id="cart-count" hx-swap-oob="true">5</span>

<!-- OOB: prepend to notification area -->
<div id="alerts" hx-swap-oob="afterbegin">
  <p class="alert">Item added!</p>
</div>
```

OOB elements must have an `id` matching an existing DOM element. `hx-swap-oob="true"` defaults to `outerHTML`. Use any swap strategy: `innerHTML`, `beforeend`, etc.

Combine with `hx-swap="none"` when the primary response is only OOB updates:
```html
<button hx-post="/toggle-fav" hx-swap="none">★</button>
```

## Extensions (htmx 2.x)

Extensions are separate scripts in 2.x (not bundled). Load explicitly:

```html
<script src="https://unpkg.com/htmx-ext-head-support@2/head-support.js"></script>
<body hx-ext="head-support">
```

Key extensions:

| Extension      | Purpose                                         |
|----------------|--------------------------------------------------|
| `head-support` | Merge `<head>` changes (title, meta, CSS)        |
| `preload`      | Preload linked content on mousedown/hover        |
| `sse`          | Server-Sent Events streaming                    |
| `ws`           | WebSocket bidirectional communication            |
| `json-enc`     | Send request body as JSON instead of form-encoded|
| `multi-swap`   | Swap multiple targets in one response via selectors|
| `morph`        | DOM diffing swap preserving focus/scroll/input   |

SSE example:
```html
<div hx-ext="sse" sse-connect="/events" sse-swap="message">
  <!-- Server-pushed messages swapped here -->
</div>
```

WebSocket example:
```html
<div hx-ext="ws" ws-connect="/chat">
  <form ws-send>
    <input name="message"><button>Send</button>
  </form>
  <div id="messages"></div>
</div>
```

## Server-Side Patterns

### Partial Templates

Return only the fragment, not the full page. Detect htmx requests via `HX-Request` header:

```python
# Express.js
app.get("/contacts", (req, res) => {
  const contacts = getContacts(req.query.q);
  if (req.headers["hx-request"]) {
    return res.render("contacts/_rows", { contacts });  // partial
  }
  res.render("contacts/index", { contacts });            // full page
});
```

```go
// Go (net/http)
func contacts(w http.ResponseWriter, r *http.Request) {
    data := getContacts(r.URL.Query().Get("q"))
    if r.Header.Get("HX-Request") == "true" {
        tmpl.ExecuteTemplate(w, "rows.html", data)
        return
    }
    tmpl.ExecuteTemplate(w, "index.html", data)
}
```

```ruby
# Rails
def index
  @contacts = Contact.search(params[:q])
  if request.headers["HX-Request"]
    render partial: "contacts/rows", locals: { contacts: @contacts }
  else
    render :index
  end
end
```

### Django Integration

```python
# views.py
from django.http import HttpResponse
from django.template.loader import render_to_string

def contact_list(request):
    contacts = Contact.objects.filter(name__icontains=request.GET.get("q", ""))
    if request.headers.get("HX-Request"):
        html = render_to_string("contacts/_rows.html", {"contacts": contacts})
        return HttpResponse(html)
    return render(request, "contacts/index.html", {"contacts": contacts})
```

## UI Patterns

### Active Search

```html
<input type="search" name="q"
       hx-get="/contacts/search"
       hx-trigger="input changed delay:300ms, search"
       hx-target="#results"
       hx-indicator="#search-spinner"
       placeholder="Search contacts...">
<span id="search-spinner" class="htmx-indicator">⏳</span>
<table><tbody id="results"><!-- rows swapped here --></tbody></table>
```

### Infinite Scroll

```html
<tbody id="items">
  <!-- existing rows -->
  <tr hx-get="/items?page=2"
      hx-trigger="revealed"
      hx-swap="afterend"
      hx-select="tbody > tr">
    <td>Loading...</td>
  </tr>
</tbody>
```

Server returns next page rows + a new sentinel row (or nothing when exhausted).

### Inline / Click-to-Edit

```html
<!-- View mode -->
<div hx-get="/contact/1/edit" hx-trigger="click" hx-swap="outerHTML">
  <span>John Doe</span> <span>john@example.com</span>
</div>
```

Server returns edit form:
```html
<form hx-put="/contact/1" hx-swap="outerHTML">
  <input name="name" value="John Doe">
  <input name="email" value="john@example.com">
  <button>Save</button>
  <button hx-get="/contact/1" hx-swap="outerHTML">Cancel</button>
</form>
```

Server PUT response returns the view-mode div again.

### Bulk Operations

```html
<form hx-delete="/contacts/batch" hx-target="#contact-table" hx-confirm="Delete selected?">
  <input type="checkbox" name="ids" value="1">
  <input type="checkbox" name="ids" value="2">
  <input type="checkbox" name="ids" value="3">
  <button>Delete Selected</button>
</form>
```

### Delete Row with Animation

```html
<tr id="row-42">
  <td>Item 42</td>
  <td>
    <button hx-delete="/items/42"
            hx-target="closest tr"
            hx-swap="outerHTML swap:500ms"
            hx-confirm="Delete?">🗑</button>
  </td>
</tr>
```

```css
tr.htmx-swapping { opacity: 0; transition: opacity 500ms ease-out; }
```

## htmx vs React/SPA: When to Choose

**Choose htmx when:**
- Content-heavy sites (blogs, dashboards, admin panels, CRUD apps)
- Server-rendered apps adding interactivity incrementally
- Small teams wanting to avoid JS build toolchains
- SEO matters and you want real HTML responses
- Backend team owns the full stack

**Choose React/SPA when:**
- Rich offline-first or real-time collaborative apps
- Complex client-side state (drag-and-drop builders, spreadsheets)
- Mobile app code sharing (React Native)
- Existing large React ecosystem investment
- Heavy client-side computation or animations

**htmx strengths:** No build step, tiny bundle, works with any backend, progressive enhancement, reduced complexity.
**htmx weakness:** Not suited for complex client-only interactions, less ecosystem for component libraries.

## Additional Resources

### references/

In-depth guides for complex scenarios:

- **[advanced-patterns.md](references/advanced-patterns.md)** — Multi-step forms/wizards, lazy loading, infinite scroll deep dive, drag-and-drop with SortableJS, modal dialogs, tabs, inline editing with validation, bulk operations, file uploads with progress, SSE streaming patterns, WebSocket chat, content negotiation, advanced OOB swap patterns with `hx-select-oob`
- **[troubleshooting.md](references/troubleshooting.md)** — Event bubbling fixes, CSRF token handling (Django/Rails/Express), cache busting, CSP header configuration, debugging with `htmx.logAll()`, swap timing issues, history cache problems, script evaluation (`hx-on:`, hyperscript), CORS setup, 422 validation error handling with `response-targets` extension
- **[backend-integration.md](references/backend-integration.md)** — Server-side patterns for Express/Fastify, Django, Flask/FastAPI, Go (net/http, Echo, Fiber), Rails, Phoenix LiveView comparison, partial template rendering strategies, OOB helper functions, response header usage patterns

### scripts/

Project tooling (run with `./scripts/<name>.sh`):

- **[setup-project.sh](scripts/setup-project.sh)** — Bootstrap an htmx project with Express, Flask, or Go backend, Tailwind CSS, and live reload. Usage: `./scripts/setup-project.sh my-app express`
- **[create-component.sh](scripts/create-component.sh)** — Generate htmx component templates: modal, infinite-scroll, inline-edit, search, tabs, file-upload. Usage: `./scripts/create-component.sh modal ./templates`
- **[analyze-htmx.sh](scripts/analyze-htmx.sh)** — Analyze HTML files for htmx usage statistics, extension detection, swap strategies, and potential issues (missing targets, old syntax, CSRF gaps). Usage: `./scripts/analyze-htmx.sh ./templates`

### assets/

Production-ready templates and starter code:

- **[express-server.js](assets/express-server.js)** — Express server with htmx detection middleware, CSRF protection, partial rendering, OOB swap helpers, HX-Trigger response helpers, and example CRUD routes
- **[base-layout.html](assets/base-layout.html)** — HTML base layout with htmx 2.x CDN, htmx config (responseHandling for 422), loading bar, toast notifications, CSRF injection, skeleton loaders, modal container, error handling
- **[components.html](assets/components.html)** — 12 copy-paste htmx components: active search, modal, tabs, infinite scroll, inline edit, bulk operations, file upload with progress, custom confirmation dialog, lazy loading, toast system, sortable list, typeahead/autocomplete
- **[htmx-django-views.py](assets/htmx-django-views.py)** — Django views with HtmxMiddleware, HtmxMixin for CBVs, fluent HtmxResponse builder, `@htmx_partial` decorator, CRUD views with validation, inline editing, infinite scroll pagination, and template examples

## Common Pitfalls and Anti-Patterns

1. **Returning JSON instead of HTML** — htmx expects HTML fragments. Use `json-enc` extension only for sending JSON; responses must still be HTML.
2. **Forgetting hx-target** — without it, the triggering element itself is the target. This often blanks out your button.
3. **Swapping full pages** — return only the fragment you need, not `<html>...</html>`. Use `hx-select` if you must filter a full response.
4. **Not handling HX-Request header** — serve partials for htmx requests, full pages for direct navigation. This enables progressive enhancement.
5. **Overusing hx-swap-oob** — OOB is powerful but makes responses harder to reason about. Prefer HX-Trigger events for complex multi-region updates.
6. **Missing hx-swap="none"** — when the response is only OOB elements or only triggers headers, set `hx-swap="none"` to avoid blanking the target.
7. **Using hx-on instead of hx-on:** — htmx 2.x requires the colon syntax with kebab-case event names.
8. **Ignoring error responses** — htmx does not swap on error status codes (4xx/5xx) by default. Use `htmx:responseError` event or `htmx.config.responseHandling` to customize.
9. **DELETE body params** — htmx 2.x sends DELETE params as query strings, not body. Update server-side parsing accordingly.
10. **Not using hx-confirm for destructive actions** — always add `hx-confirm="Are you sure?"` on delete/destroy operations.
