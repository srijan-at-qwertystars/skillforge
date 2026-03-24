# htmx Advanced Patterns

## Table of Contents

- [Multi-Step Forms / Wizards](#multi-step-forms--wizards)
- [Lazy Loading](#lazy-loading)
- [Infinite Scroll Deep Dive](#infinite-scroll-deep-dive)
- [Drag-and-Drop with Sortable](#drag-and-drop-with-sortable)
- [Modal Dialogs](#modal-dialogs)
- [Tabs](#tabs)
- [Inline Editing with Validation](#inline-editing-with-validation)
- [Bulk Operations](#bulk-operations)
- [File Uploads with Progress](#file-uploads-with-progress)
- [Server-Sent Events Patterns](#server-sent-events-patterns)
- [WebSocket Chat](#websocket-chat)
- [Content Negotiation](#content-negotiation)
- [Response Targeting with hx-swap-oob](#response-targeting-with-hx-swap-oob)

---

## Multi-Step Forms / Wizards

Use `hx-target` to swap wizard step content within a container. Each step submits to the server, which validates and returns the next step or errors.

```html
<div id="wizard">
  <form hx-post="/wizard/step1" hx-target="#wizard" hx-swap="innerHTML">
    <h2>Step 1: Account Info</h2>
    <input name="email" type="email" required>
    <input name="password" type="password" required minlength="8">
    <button type="submit">Next →</button>
  </form>
</div>
```

Server response for step 2 (returned on successful step 1 validation):

```html
<form hx-post="/wizard/step2" hx-target="#wizard" hx-swap="innerHTML">
  <h2>Step 2: Profile</h2>
  <input type="hidden" name="token" value="abc123">
  <input name="display_name" required>
  <input name="avatar_url" type="url">
  <button hx-get="/wizard/step1" hx-target="#wizard">← Back</button>
  <button type="submit">Next →</button>
</form>
```

**Key patterns:**
- Store intermediate state server-side (session or signed hidden fields)
- Return the current step's form on validation failure with error messages inline
- Use `hx-indicator` on submit buttons to show progress between steps
- Add a progress bar OOB update with each step:

```html
<!-- OOB progress bar update returned alongside each step -->
<div id="progress" hx-swap-oob="true">
  <div class="progress-bar" style="width: 66%">Step 2 of 3</div>
</div>
```

## Lazy Loading

Load expensive content after initial page render:

```html
<!-- Loads immediately when element enters DOM -->
<div hx-get="/dashboard/chart" hx-trigger="load" hx-swap="innerHTML">
  <div class="skeleton-loader">Loading chart...</div>
</div>

<!-- Loads only when scrolled into view -->
<div hx-get="/dashboard/activity" hx-trigger="revealed" hx-swap="innerHTML">
  <div class="skeleton-loader">Loading activity...</div>
</div>

<!-- Loads when 50% visible (IntersectionObserver) -->
<div hx-get="/dashboard/metrics"
     hx-trigger="intersect threshold:0.5"
     hx-swap="innerHTML">
  <div class="skeleton-loader">Loading metrics...</div>
</div>
```

**Staggered loading** — delay expensive sections:

```html
<div hx-get="/heavy-section" hx-trigger="load delay:500ms" hx-swap="innerHTML">
  Loading...
</div>
```

**Conditional lazy load** — load based on user interaction:

```html
<details>
  <summary hx-get="/section/details"
           hx-trigger="click once"
           hx-target="next .content"
           hx-swap="innerHTML">
    Show Details
  </summary>
  <div class="content"></div>
</details>
```

## Infinite Scroll Deep Dive

The sentinel pattern — last item triggers the next page load:

```html
<div id="feed">
  <article class="post">...</article>
  <article class="post">...</article>
  <!-- Sentinel: triggers when revealed -->
  <div hx-get="/feed?page=2&after=cursor_abc"
       hx-trigger="revealed"
       hx-swap="outerHTML"
       hx-indicator="#load-more-spinner">
    <span id="load-more-spinner" class="htmx-indicator">Loading more...</span>
  </div>
</div>
```

Server returns the next batch plus a new sentinel (or nothing if exhausted):

```html
<article class="post">...</article>
<article class="post">...</article>
<!-- New sentinel for page 3 -->
<div hx-get="/feed?page=3&after=cursor_xyz"
     hx-trigger="revealed"
     hx-swap="outerHTML">
  <span class="htmx-indicator">Loading more...</span>
</div>
```

**Cursor-based pagination** (preferred over offset for live data):

```python
# Server: use last item's ID/timestamp as cursor
items = Item.objects.filter(created_at__lt=cursor).order_by('-created_at')[:20]
next_cursor = items[-1].created_at.isoformat() if items else None
```

**Click-to-load variant** (better for accessibility):

```html
<button hx-get="/feed?page=2"
        hx-target="#feed"
        hx-swap="beforeend"
        hx-indicator="this">
  Load More <span class="htmx-indicator">⏳</span>
</button>
```

## Drag-and-Drop with Sortable

Combine htmx with SortableJS for server-persisted reordering:

```html
<script src="https://cdn.jsdelivr.net/npm/sortablejs@1.15/Sortable.min.js"></script>

<ul id="task-list" class="sortable-list">
  <li data-id="1" class="task-item">Task A</li>
  <li data-id="2" class="task-item">Task B</li>
  <li data-id="3" class="task-item">Task C</li>
</ul>

<script>
new Sortable(document.getElementById('task-list'), {
  animation: 150,
  ghostClass: 'sortable-ghost',
  onEnd: function(evt) {
    const order = Array.from(evt.to.children).map(el => el.dataset.id);
    htmx.ajax('POST', '/tasks/reorder', {
      target: '#task-list',
      swap: 'innerHTML',
      values: { order: JSON.stringify(order) }
    });
  }
});
</script>
```

**Server handler:**

```python
@app.post("/tasks/reorder")
def reorder_tasks():
    order = json.loads(request.form["order"])
    for position, task_id in enumerate(order):
        Task.query.get(task_id).position = position
    db.session.commit()
    return render_template("tasks/_list.html", tasks=Task.query.order_by(Task.position))
```

## Modal Dialogs

Load modal content from the server:

```html
<!-- Trigger -->
<button hx-get="/contacts/new"
        hx-target="#modal-container"
        hx-swap="innerHTML">
  Add Contact
</button>

<!-- Modal container (always in page) -->
<div id="modal-container"></div>
```

Server returns the modal markup:

```html
<div id="modal-backdrop" class="modal-backdrop" hx-on:click="closeModal()">
  <div class="modal-content" hx-on:click="event.stopPropagation()">
    <h2>New Contact</h2>
    <form hx-post="/contacts"
          hx-target="#contact-list"
          hx-swap="beforeend"
          hx-on::after-request="closeModal()">
      <input name="name" required>
      <input name="email" type="email" required>
      <button type="submit">Save</button>
      <button type="button" onclick="closeModal()">Cancel</button>
    </form>
  </div>
</div>

<script>
function closeModal() {
  document.getElementById('modal-container').innerHTML = '';
}
document.addEventListener('keydown', e => {
  if (e.key === 'Escape') closeModal();
});
</script>
```

**Confirmation modal pattern** — replace `hx-confirm` with a custom modal:

```html
<button hx-get="/confirm-delete/42"
        hx-target="#modal-container"
        hx-swap="innerHTML">
  Delete
</button>
```

## Tabs

```html
<div id="tabs" hx-target="#tab-content" hx-swap="innerHTML">
  <button hx-get="/tabs/overview" class="tab active"
          hx-on::after-request="setActiveTab(this)">Overview</button>
  <button hx-get="/tabs/details" class="tab"
          hx-on::after-request="setActiveTab(this)">Details</button>
  <button hx-get="/tabs/history" class="tab"
          hx-on::after-request="setActiveTab(this)">History</button>
</div>
<div id="tab-content">
  <!-- initial tab content rendered server-side -->
</div>

<script>
function setActiveTab(el) {
  document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
  el.classList.add('active');
}
</script>
```

**URL-aware tabs** with `hx-push-url`:

```html
<button hx-get="/tabs/details" hx-push-url="/project/42/details"
        class="tab">Details</button>
```

## Inline Editing with Validation

Click-to-edit with server-side validation and error display:

```html
<!-- View mode -->
<tr id="contact-5">
  <td hx-get="/contacts/5/edit/name" hx-trigger="dblclick"
      hx-swap="outerHTML">John Doe</td>
  <td hx-get="/contacts/5/edit/email" hx-trigger="dblclick"
      hx-swap="outerHTML">john@example.com</td>
</tr>
```

Server returns inline form for a single field:

```html
<td>
  <form hx-put="/contacts/5/field/name"
        hx-target="#contact-5"
        hx-swap="outerHTML"
        hx-on:keydown="if(event.key==='Escape') htmx.ajax('GET','/contacts/5','#contact-5')">
    <input name="value" value="John Doe" autofocus
           hx-on:blur="this.form.requestSubmit()">
    <span class="error" id="name-error"></span>
  </form>
</td>
```

On validation failure, server returns 422 with the form showing errors. Configure htmx to swap on 422:

```javascript
// In htmx 2.x config
htmx.config.responseHandling = [
  { code: "204", swap: false },
  { code: "[23]..", swap: true },
  { code: "422", swap: true, error: false },  // swap validation errors
  { code: "[45]..", swap: false, error: true }
];
```

## Bulk Operations

Select-all pattern with a hidden form:

```html
<form id="bulk-form" hx-swap="innerHTML" hx-target="#item-list">
  <div class="toolbar">
    <input type="checkbox" id="select-all"
           hx-on:click="toggleAll(this.checked)">
    <select name="action">
      <option value="archive">Archive</option>
      <option value="delete">Delete</option>
      <option value="export">Export</option>
    </select>
    <button hx-post="/items/bulk" hx-include="#bulk-form"
            hx-confirm="Apply to selected items?">Apply</button>
  </div>
  <div id="item-list">
    <div class="item"><input type="checkbox" name="ids" value="1"> Item 1</div>
    <div class="item"><input type="checkbox" name="ids" value="2"> Item 2</div>
  </div>
</form>

<script>
function toggleAll(checked) {
  document.querySelectorAll('input[name="ids"]').forEach(cb => cb.checked = checked);
}
</script>
```

## File Uploads with Progress

htmx supports file uploads natively. Use `hx-encoding="multipart/form-data"`:

```html
<form hx-post="/upload"
      hx-encoding="multipart/form-data"
      hx-target="#upload-result"
      hx-indicator="#upload-progress">
  <input type="file" name="files" multiple accept="image/*">
  <button type="submit">Upload</button>
</form>
<div id="upload-progress" class="htmx-indicator">
  <progress id="upload-bar" value="0" max="100"></progress>
</div>
<div id="upload-result"></div>

<script>
htmx.on('htmx:xhr:progress', function(evt) {
  if (evt.detail.lengthComputable) {
    const pct = (evt.detail.loaded / evt.detail.total) * 100;
    document.getElementById('upload-bar').value = pct;
  }
});
</script>
```

## Server-Sent Events Patterns

Use the `sse` extension for streaming server updates:

```html
<script src="https://unpkg.com/htmx-ext-sse@2/sse.js"></script>

<!-- Listen for named events -->
<div hx-ext="sse" sse-connect="/events/dashboard">
  <div sse-swap="cpu-update" hx-swap="innerHTML">CPU: --</div>
  <div sse-swap="memory-update" hx-swap="innerHTML">Memory: --</div>
  <div sse-swap="alerts" hx-swap="beforeend"><!-- alerts append here --></div>
</div>
```

**Server (Node/Express):**

```javascript
app.get('/events/dashboard', (req, res) => {
  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('Connection', 'keep-alive');

  const interval = setInterval(() => {
    res.write(`event: cpu-update\ndata: <span>CPU: ${getCPU()}%</span>\n\n`);
    res.write(`event: memory-update\ndata: <span>Mem: ${getMem()}%</span>\n\n`);
  }, 2000);

  req.on('close', () => clearInterval(interval));
});
```

**Close SSE connection** — use `sse-close` or swap the container away:

```html
<button hx-on:click="htmx.find('[sse-connect]').removeAttribute('sse-connect')">
  Stop Updates
</button>
```

## WebSocket Chat

Full bidirectional chat with the `ws` extension:

```html
<script src="https://unpkg.com/htmx-ext-ws@2/ws.js"></script>

<div hx-ext="ws" ws-connect="/ws/chat/room1">
  <div id="chat-messages" style="height:400px; overflow-y:auto;"></div>
  <form ws-send hx-on::ws-after-send="this.reset()">
    <input name="message" placeholder="Type a message..." autocomplete="off" required>
    <button type="submit">Send</button>
  </form>
</div>
```

**Server broadcasts HTML fragments:**

```javascript
// On receiving a message from a client, broadcast to all:
wss.on('connection', (ws) => {
  ws.on('message', (raw) => {
    const data = JSON.parse(raw);
    const html = `<div id="chat-messages" hx-swap-oob="beforeend">
      <p><strong>${escapeHtml(data.user)}</strong>: ${escapeHtml(data.message)}</p>
    </div>`;
    wss.clients.forEach(client => client.send(html));
  });
});
```

## Content Negotiation

Serve htmx partials, full pages, and JSON from the same endpoint:

```python
@app.get("/contacts")
def contacts():
    data = get_contacts(request.args.get("q"))
    # htmx request → partial HTML
    if request.headers.get("HX-Request"):
        return render_template("contacts/_rows.html", contacts=data)
    # JSON API client
    if request.accept_mimetypes.best == "application/json":
        return jsonify([c.to_dict() for c in data])
    # Full page
    return render_template("contacts/index.html", contacts=data)
```

Use `HX-Target` header to return different partials based on what's being targeted:

```python
if request.headers.get("HX-Target") == "search-results":
    return render_template("contacts/_search_results.html", contacts=data)
elif request.headers.get("HX-Target") == "contact-table":
    return render_template("contacts/_table.html", contacts=data)
```

## Response Targeting with hx-swap-oob

### Multi-region updates

A single response can update any number of regions by including `hx-swap-oob` elements:

```html
<!-- Primary response (swapped into hx-target) -->
<tr id="row-42">
  <td>Updated Item</td>
  <td>$29.99</td>
</tr>

<!-- OOB: update cart badge -->
<span id="cart-count" hx-swap-oob="true">3</span>

<!-- OOB: prepend notification -->
<div id="notifications" hx-swap-oob="afterbegin">
  <div class="toast success">Item updated!</div>
</div>

<!-- OOB: update timestamp -->
<time id="last-updated" hx-swap-oob="true">Just now</time>
```

### OOB with hx-swap="none"

When you only need OOB updates (no primary target):

```html
<button hx-post="/toggle-status/42" hx-swap="none">Toggle</button>
```

Server returns only OOB elements — nothing goes into the trigger element.

### Event-based alternative to OOB

For complex multi-region updates, prefer `HX-Trigger` response header + event listeners:

```python
# Server
response = HttpResponse(render_to_string("row.html", ctx))
response["HX-Trigger"] = json.dumps({
    "itemUpdated": {"id": 42, "name": "Widget"},
    "cartChanged": {"count": 3}
})
```

```html
<!-- Listeners react to server-triggered events -->
<div hx-get="/cart/badge" hx-trigger="cartChanged from:body" hx-target="this">
  <span class="badge">2</span>
</div>
<div hx-get="/notifications/latest" hx-trigger="itemUpdated from:body"
     hx-target="this" hx-swap="innerHTML">
</div>
```

This decouples the response from the DOM structure — the server doesn't need to know the page layout.

### OOB Select pattern

Use `hx-select-oob` on the triggering element to extract OOB content from within the response:

```html
<button hx-get="/dashboard"
        hx-target="#main-content"
        hx-select="#main-content"
        hx-select-oob="#sidebar-stats:innerHTML, #notification-count:innerHTML">
  Refresh Dashboard
</button>
```

The server returns a full page; htmx extracts `#main-content` for the target and pulls `#sidebar-stats` and `#notification-count` for OOB updates.
