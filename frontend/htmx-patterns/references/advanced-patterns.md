# Advanced htmx Patterns

Comprehensive guide to complex htmx techniques beyond the basics.

## Table of Contents

- [Nested Out-of-Band Swaps](#nested-out-of-band-swaps)
- [Morphing with Idiomorph](#morphing-with-idiomorph)
- [View Transitions API](#view-transitions-api)
- [Optimistic UI](#optimistic-ui)
- [Offline Support Strategies](#offline-support-strategies)
- [State Management Without JavaScript](#state-management-without-javascript)
- [Complex Form Workflows](#complex-form-workflows)
- [Real-Time Collaboration Patterns](#real-time-collaboration-patterns)
- [CSRF Handling Across Frameworks](#csrf-handling-across-frameworks)

---

## Nested Out-of-Band Swaps

OOB (Out-of-Band) swaps let you update multiple DOM regions from a single server
response. The primary content swaps into `hx-target`; additional elements with
`hx-swap-oob` attributes get placed into their matching IDs elsewhere on the page.

### Basic Multi-Region Update

```html
<!-- Trigger: add an item -->
<button hx-post="/items" hx-target="#item-list" hx-swap="beforeend">
  Add Item
</button>

<!-- Regions to update -->
<ul id="item-list"></ul>
<span id="item-count">0 items</span>
<div id="recent-activity"></div>
```

Server response updates three regions at once:

```html
<!-- Primary swap: appended into #item-list -->
<li>New Item</li>

<!-- OOB: replaces #item-count content -->
<span id="item-count" hx-swap-oob="true">5 items</span>

<!-- OOB: prepends into #recent-activity -->
<div id="recent-activity" hx-swap-oob="afterbegin">
  <p class="activity">Item added at 10:32 AM</p>
</div>
```

### Nested OOB Within OOB Elements

When an OOB element contains elements with `hx-swap-oob`, only the outermost
OOB applies. **Solution — flatten OOB elements at root level:**

```html
<li>New Item</li>
<div id="sidebar" hx-swap-oob="outerHTML">
  <div id="sidebar"><nav>Updated sidebar</nav></div>
</div>
<span id="badge" hx-swap-oob="innerHTML">3</span>
```

### Conditional OOB Patterns

Server-side logic decides which OOB fragments to include:

```python
# Django view
def add_item(request):
    item = Item.objects.create(name=request.POST["name"])
    html = render_to_string("partials/item_row.html", {"item": item})

    # Conditionally add OOB fragments
    if item.is_urgent:
        html += render_to_string("partials/oob_alert.html", {"item": item})

    count = Item.objects.count()
    html += f'<span id="item-count" hx-swap-oob="true">{count} items</span>'

    return HttpResponse(html)
```

### OOB with Different Swap Strategies

```html
<!-- Replace entire element -->
<div id="stats" hx-swap-oob="outerHTML">
  <div id="stats"><h3>Updated Stats</h3></div>
</div>

<!-- Append to existing content -->
<ul id="log" hx-swap-oob="beforeend">
  <li>New log entry</li>
</ul>

<!-- Prepend notification -->
<div id="toasts" hx-swap-oob="afterbegin">
  <div class="toast success">Saved!</div>
</div>
```

---

## Morphing with Idiomorph

Idiomorph is a DOM morphing algorithm that intelligently merges new HTML into
existing DOM, preserving focus state, scroll positions, CSS animations, and
form input values. Unlike `innerHTML` or `outerHTML` swaps, morphing diffs the
old and new DOM trees.

### Setup

```html
<script src="https://unpkg.com/htmx.org@2.0.4"></script>
<script src="https://unpkg.com/idiomorph@0.3.0/dist/idiomorph-ext.min.js"></script>

<!-- Enable globally -->
<body hx-ext="morph">
  <!-- All swaps can now use morph -->
</body>
```

### Using Morph Swap Strategy

```html
<!-- Morph the entire target -->
<div hx-get="/dashboard" hx-swap="morph" hx-target="#dashboard">
  Refresh Dashboard
</div>

<!-- Morph innerHTML only -->
<div hx-get="/table" hx-swap="morph:innerHTML" hx-target="#data-table">
  Update Table
</div>

<!-- Morph outerHTML (replace element itself) -->
<div hx-get="/card" hx-swap="morph:outerHTML" hx-target="#user-card">
  Refresh Card
</div>
```

### Benefits Over Standard Swaps

| Feature              | innerHTML/outerHTML | morph (Idiomorph)      |
|----------------------|---------------------|------------------------|
| Focus preservation   | ❌ Lost             | ✅ Preserved           |
| Scroll position      | ❌ Reset            | ✅ Preserved           |
| CSS animations       | ❌ Restart          | ✅ Continue            |
| Form input values    | ❌ Lost             | ✅ Preserved           |
| Video/audio playback | ❌ Restart          | ✅ Continue            |
| DOM event listeners  | ❌ Removed          | ✅ Preserved on stable |

### Morphing Lists with ID Stability

Idiomorph matches elements by `id` first, then by structure. Always include
stable IDs on list items for optimal diffing:

```html
<!-- Server response — list with stable IDs -->
<ul id="todo-list">
  <li id="todo-1" class="done">Buy groceries</li>
  <li id="todo-2">Walk the dog</li>
  <li id="todo-3" class="new">Read htmx docs</li>  <!-- new item -->
</ul>
```

### Morph with Polling (Live Dashboard)

```html
<div id="dashboard" hx-get="/dashboard" hx-trigger="every 5s"
     hx-swap="morph:outerHTML">
  <div id="cpu-gauge" style="--value: 45%">CPU: 45%</div>
  <div id="mem-gauge" style="--value: 72%">Memory: 72%</div>
  <table id="process-table">
    <tr id="proc-1"><td>nginx</td><td>2.3%</td></tr>
    <tr id="proc-2"><td>postgres</td><td>15.1%</td></tr>
  </table>
</div>
```

Morphing keeps CSS transitions smooth because only changed attributes/text
are updated, not entire subtrees.

---

## View Transitions API

The View Transitions API provides native browser animations between DOM states.
htmx integrates with it via the `transition:true` swap modifier.

### Basic View Transitions

```html
<!-- Enable per-element -->
<a hx-get="/about" hx-target="#main" hx-swap="innerHTML transition:true"
   hx-push-url="true">
  About Us
</a>

<!-- Enable globally -->
<meta name="htmx-config" content='{"globalViewTransitions": true}'>
```

### Custom Transition Animations

```css
/* Default cross-fade */
::view-transition-old(root) {
  animation: fade-out 0.3s ease-in;
}
::view-transition-new(root) {
  animation: fade-in 0.3s ease-out;
}

/* Slide transition for specific elements */
#main-content {
  view-transition-name: main-content;
}
::view-transition-old(main-content) {
  animation: slide-out-left 0.3s ease-in;
}
::view-transition-new(main-content) {
  animation: slide-in-right 0.3s ease-out;
}

@keyframes slide-out-left {
  to { transform: translateX(-100%); opacity: 0; }
}
@keyframes slide-in-right {
  from { transform: translateX(100%); opacity: 0; }
}
```

### Named Transitions for Different Content Types

```html
<!-- Give elements unique transition names -->
<img src="/avatar.jpg" style="view-transition-name: hero-image;">
<h1 style="view-transition-name: page-title;">Dashboard</h1>
<div id="content" style="view-transition-name: main-content;">...</div>
```

```css
/* Each named region animates independently */
::view-transition-old(hero-image) {
  animation: scale-down 0.4s ease-in;
}
::view-transition-new(hero-image) {
  animation: scale-up 0.4s ease-out;
}
```

### Progressive Enhancement for View Transitions

```css
/* Only apply when browser supports view transitions */
@supports (view-transition-name: test) {
  #content { view-transition-name: content; }

  ::view-transition-old(content) {
    animation: fade-slide-out 0.25s ease;
  }
  ::view-transition-new(content) {
    animation: fade-slide-in 0.25s ease;
  }
}
```

---

## Optimistic UI

Show the expected result immediately while the server processes the request.
Roll back if the server returns an error.

### Optimistic Delete

```html
<tr id="row-42">
  <td>Item 42</td>
  <td>
    <button hx-delete="/items/42" hx-target="closest tr" hx-swap="outerHTML"
            _="on click add .optimistic-hide to closest <tr/>
               on htmx:responseError remove .optimistic-hide from closest <tr/>
                 then call showToast('Delete failed')">
      Delete
    </button>
  </td>
</tr>
```

```css
.optimistic-hide {
  opacity: 0.3;
  pointer-events: none;
  transition: opacity 0.2s;
}
```

### Optimistic Add with Rollback

```html
<form hx-post="/comments" hx-target="#comments" hx-swap="beforeend"
      _="on submit
           set comment to (<input[name='body']/>'s value)
           put `<div class='comment optimistic'>${comment}</div>` before end of #comments
         on htmx:responseError
           remove .optimistic from #comments
           call showToast('Failed to post comment')
         on htmx:afterSwap
           remove .optimistic from #comments">
  <input name="body" required>
  <button>Post</button>
</form>
```

### Optimistic Toggle

```html
<button hx-post="/items/42/toggle" hx-target="this" hx-swap="outerHTML"
        _="on click toggle .active on me
           on htmx:responseError toggle .active on me">
  <span class="status">Active</span>
</button>
```

---

## Offline Support Strategies

htmx is server-dependent, but you can add resilience for intermittent
connectivity.

### Service Worker Caching for Partials

```javascript
// sw.js — cache htmx partial responses
self.addEventListener("fetch", (event) => {
  if (event.request.headers.get("HX-Request") === "true") {
    event.respondWith(
      fetch(event.request)
        .then((response) => {
          const clone = response.clone();
          caches.open("htmx-partials").then((cache) => {
            cache.put(event.request, clone);
          });
          return response;
        })
        .catch(() => caches.match(event.request))
    );
  }
});
```

### Offline Detection and User Feedback

```html
<div id="offline-banner" style="display:none" class="alert warning">
  You are offline. Changes will sync when reconnected.
</div>

<script>
window.addEventListener("offline", () => {
  document.getElementById("offline-banner").style.display = "block";
  document.body.setAttribute("hx-disable", "");
});
window.addEventListener("online", () => {
  document.getElementById("offline-banner").style.display = "none";
  document.body.removeAttribute("hx-disable");
});
</script>
```

### Queue Requests for Replay

```javascript
const requestQueue = [];

document.body.addEventListener("htmx:sendError", (e) => {
  requestQueue.push({
    method: e.detail.requestConfig.verb,
    url: e.detail.requestConfig.path,
    body: e.detail.requestConfig.parameters,
  });
  localStorage.setItem("htmx-queue", JSON.stringify(requestQueue));
});

window.addEventListener("online", async () => {
  const queue = JSON.parse(localStorage.getItem("htmx-queue") || "[]");
  for (const req of queue) {
    await fetch(req.url, { method: req.method, body: req.body });
  }
  localStorage.removeItem("htmx-queue");
  location.reload();
});
```

---

## State Management Without JavaScript

htmx can manage complex UI state entirely through server-rendered HTML
and hypermedia controls.

### Server-Side State via Hidden Inputs

```html
<div id="wizard">
  <input type="hidden" name="step" value="2">
  <input type="hidden" name="plan" value="pro">
  <h2>Step 2: Billing Info</h2>
  <input name="card_number" placeholder="Card number">
  <button hx-post="/wizard/step3" hx-target="#wizard" hx-swap="outerHTML"
          hx-include="closest div">
    Next
  </button>
</div>
```

### CSS-Driven State with hx-classes / class-tools

```html
<script src="https://unpkg.com/htmx-ext-class-tools@2.0.1/class-tools.js"></script>

<!-- Toggle classes based on server response -->
<div hx-get="/status" hx-trigger="every 5s" hx-target="this" hx-swap="outerHTML"
     class="status-indicator" classes="add connected:1s, remove disconnected">
  Connected
</div>
```

### Data Attributes as State

```html
<!-- Server sets data attributes to control client behavior -->
<div id="player" data-playing="false" data-track-id="42"
     hx-get="/player/status" hx-trigger="every 1s" hx-swap="morph:outerHTML">
  <button hx-post="/player/toggle" hx-target="#player" hx-swap="outerHTML">
    Play
  </button>
  <progress value="30" max="240"></progress>
</div>
```

### Shared State via Inherited Attributes

```html
<!-- Parent sets context for all children -->
<div hx-headers='{"X-Workspace": "ws-123"}' hx-vals='{"org": "acme"}'>
  <button hx-get="/projects">Load Projects</button>
  <button hx-get="/members">Load Members</button>
  <!-- Both requests include workspace header and org value -->
</div>
```

---

## Complex Form Workflows

### Multi-Step Wizard

Each step is a server-rendered partial. The server tracks progress.

```html
<!-- Step 1 -->
<form id="wizard" hx-post="/wizard/step1" hx-target="#wizard" hx-swap="outerHTML">
  <h2>Step 1 of 3: Personal Info</h2>
  <div class="progress"><div style="width:33%"></div></div>
  <input name="name" required placeholder="Full Name">
  <input name="email" type="email" required placeholder="Email">
  <button type="submit">Next →</button>
</form>
```

Server response for step 2:

```html
<form id="wizard" hx-post="/wizard/step2" hx-target="#wizard" hx-swap="outerHTML">
  <h2>Step 2 of 3: Preferences</h2>
  <div class="progress"><div style="width:66%"></div></div>
  <input type="hidden" name="name" value="Jane Doe">
  <input type="hidden" name="email" value="jane@example.com">
  <select name="plan">
    <option value="free">Free</option>
    <option value="pro">Pro</option>
  </select>
  <button type="button" hx-get="/wizard/step1?restore=true"
          hx-target="#wizard" hx-swap="outerHTML">← Back</button>
  <button type="submit">Next →</button>
</form>
```

### Dependent/Cascading Selects

```html
<label>Country</label>
<select name="country" hx-get="/regions" hx-target="#region-select"
        hx-trigger="change" hx-indicator="#region-loading">
  <option value="">Select country...</option>
  <option value="us">United States</option>
  <option value="ca">Canada</option>
</select>
<span id="region-loading" class="htmx-indicator">Loading...</span>

<label>Region</label>
<div id="region-select">
  <select name="region" disabled>
    <option>Select country first</option>
  </select>
</div>
```

Server response for `/regions?country=us`:

```html
<select name="region" hx-get="/cities" hx-target="#city-select"
        hx-trigger="change" hx-indicator="#city-loading">
  <option value="">Select state...</option>
  <option value="ca">California</option>
  <option value="ny">New York</option>
  <option value="tx">Texas</option>
</select>
```

### Drag-and-Drop Reordering

Uses the Sortable.js library alongside htmx:

```html
<script src="https://cdn.jsdelivr.net/npm/sortablejs@1.15.0/Sortable.min.js"></script>

<ul id="sortable-list" class="sortable">
  <li data-id="1">Item 1</li>
  <li data-id="2">Item 2</li>
  <li data-id="3">Item 3</li>
</ul>

<script>
new Sortable(document.getElementById("sortable-list"), {
  animation: 150,
  onEnd: function(evt) {
    const order = Array.from(evt.to.children).map(el => el.dataset.id);
    htmx.ajax("POST", "/reorder", {
      target: "#sortable-list",
      swap: "innerHTML",
      values: { order: order.join(",") }
    });
  }
});
</script>
```

### Dynamic Form Fields (Add/Remove)

```html
<div id="line-items">
  <div class="line-item">
    <input name="items[0].name" placeholder="Item">
    <input name="items[0].qty" type="number" value="1">
    <button type="button" hx-delete="/line-items/remove"
            hx-target="closest .line-item" hx-swap="outerHTML">×</button>
  </div>
</div>
<button type="button" hx-get="/line-items/add?index=1"
        hx-target="#line-items" hx-swap="beforeend">
  + Add Line Item
</button>
```

---

## Real-Time Collaboration Patterns

### Presence Indicators via SSE

```html
<div hx-ext="sse" sse-connect="/presence/stream">
  <div id="online-users" sse-swap="presence">
    <!-- Server pushes updated user list -->
  </div>
</div>
```

Server (Python/Flask):

```python
@app.route("/presence/stream")
def presence_stream():
    def generate():
        while True:
            users = get_online_users()
            html = render_template("partials/online_users.html", users=users)
            yield f"event: presence\ndata: {html}\n\n"
            time.sleep(5)
    return Response(generate(), mimetype="text/event-stream")
```

### Collaborative Editing with Conflict Resolution

```html
<!-- Include version for optimistic concurrency -->
<form hx-put="/docs/42" hx-target="#editor" hx-swap="outerHTML">
  <input type="hidden" name="version" value="7">
  <textarea name="content">Document text...</textarea>
  <button type="submit">Save</button>
</form>
```

Server returns conflict resolution UI when versions mismatch:

```html
<div id="editor" class="conflict">
  <h3>Conflict Detected</h3>
  <div class="diff">
    <div class="theirs"><h4>Their changes</h4><pre>...</pre></div>
    <div class="yours"><h4>Your changes</h4><pre>...</pre></div>
  </div>
  <button hx-post="/docs/42/resolve?strategy=theirs"
          hx-target="#editor" hx-swap="outerHTML">Use Theirs</button>
  <button hx-post="/docs/42/resolve?strategy=yours"
          hx-target="#editor" hx-swap="outerHTML">Use Yours</button>
</div>
```

### Live Cursors / Activity Feed

```html
<div hx-ext="sse" sse-connect="/collab/42/events">
  <!-- Cursor positions update in real time -->
  <div id="cursors" sse-swap="cursors" hx-swap="innerHTML"></div>

  <!-- Activity feed prepends new entries -->
  <div id="activity" sse-swap="activity" hx-swap="afterbegin"></div>
</div>
```

---

## CSRF Handling Across Frameworks

### Django

```html
<!-- Template-level: include token in all htmx requests -->
<body hx-headers='{"X-CSRFToken": "{{ csrf_token }}"}'>
```

```python
# Or use django-htmx middleware (recommended)
# settings.py
MIDDLEWARE = [
    "django.middleware.csrf.CsrfViewMiddleware",
    "django_htmx.middleware.HtmxMiddleware",
]
```

### Flask (Flask-WTF)

```html
<meta name="csrf-token" content="{{ csrf_token() }}">
<script>
document.body.addEventListener("htmx:configRequest", (e) => {
  e.detail.headers["X-CSRFToken"] =
    document.querySelector("meta[name=csrf-token]").content;
});
</script>
```

### Express.js (csurf/csrf-csrf)

```javascript
const { doubleCsrf } = require("csrf-csrf");
const { doubleCsrfProtection, generateToken } = doubleCsrf({ getSecret: () => SECRET });

app.use(doubleCsrfProtection);
app.use((req, res, next) => {
  res.locals.csrfToken = generateToken(req, res);
  next();
});
```

```html
<body hx-headers='{"X-CSRF-Token": "<%= csrfToken %>"}'>
```

### Go (gorilla/csrf)

```go
import "github.com/gorilla/csrf"

func main() {
    CSRF := csrf.Protect([]byte("32-byte-long-auth-key-here"))
    http.ListenAndServe(":8000", CSRF(router))
}

func handler(w http.ResponseWriter, r *http.Request) {
    data := map[string]interface{}{
        "csrfToken": csrf.Token(r),
    }
    tmpl.Execute(w, data)
}
```

```html
<body hx-headers='{"X-CSRF-Token": "{{.csrfToken}}"}'>
```

### Rails

```html
<meta name="csrf-token" content="<%= form_authenticity_token %>">
<script>
document.body.addEventListener("htmx:configRequest", (e) => {
  e.detail.headers["X-CSRF-Token"] =
    document.querySelector("meta[name=csrf-token]").content;
});
</script>
```

### Spring Boot

```html
<meta name="_csrf" th:content="${_csrf.token}">
<meta name="_csrf_header" th:content="${_csrf.headerName}">
<script>
document.body.addEventListener("htmx:configRequest", (e) => {
  e.detail.headers[document.querySelector("meta[name=_csrf_header]").content] =
    document.querySelector("meta[name=_csrf]").content;
});
</script>
```

### Phoenix

```html
<body hx-headers={"{'x-csrf-token': '#{Plug.CSRFProtection.get_csrf_token()}'}"}>
```

---

## Additional Advanced Techniques

### Lazy Evaluation with hx-disable

```html
<div id="deferred-section" hx-disable>
  <button hx-get="/expensive-data" hx-target="#result">Load</button>
</div>
<button _="on click remove @hx-disable from #deferred-section
           then call htmx.process(#deferred-section)">Enable</button>
```

### Request Deduplication

```html
<button hx-post="/submit" hx-target="#result"
        hx-trigger="click queue:first" hx-disabled-elt="this">Submit</button>
```

### Chaining Sequential Requests

Use `HX-Trigger` response header to chain dependent operations:

```python
def create_item(request):
    item = Item.objects.create(...)
    response = HttpResponse(render_to_string("partials/item.html", {"item": item}))
    response["HX-Trigger"] = json.dumps({"itemCreated": {"id": item.id}})
    return response
```

```html
<div id="related" hx-get="/items/related" hx-trigger="itemCreated from:body"
     hx-vals="js:{id: event.detail.id}" hx-target="this">
</div>
```

### Prefetching with the Preload Extension

```html
<script src="https://unpkg.com/htmx-ext-preload@2.1.0/preload.js"></script>
<body hx-ext="preload">
  <a hx-get="/page2" preload>Page 2</a>
  <a hx-get="/page3" preload="mouseover">Page 3 (preloads on hover)</a>
</body>
```
