# Server-Side Integration Guide for htmx

Patterns for integrating htmx with major server frameworks.

## Table of Contents

- [Core Concepts](#core-concepts)
- [Django (django-htmx)](#django-django-htmx)
- [Flask](#flask)
- [Express.js](#expressjs)
- [Go (templ + htmx)](#go-templ--htmx)
- [Rails (Turbo vs htmx)](#rails-turbo-vs-htmx)
- [FastAPI](#fastapi)
- [Spring Boot](#spring-boot)
- [Phoenix LiveView Comparison](#phoenix-liveview-comparison)
- [Cross-Framework Patterns](#cross-framework-patterns)

---

## Core Concepts

Every framework integration follows the same pattern:

1. **Detect htmx requests** — Check for the `HX-Request: true` header
2. **Return HTML fragments** — Render a partial template, not a full page
3. **Set response headers** — Use `HX-Trigger`, `HX-Retarget`, `HX-Push-Url` etc.
4. **Handle CSRF** — Framework-specific token injection

```
Browser (full page) ──→ render("page.html")
htmx request        ──→ render("partials/fragment.html")
API client          ──→ return JSON
---

## Django (django-htmx)

### Installation

```bash
pip install django-htmx
```

```python
# settings.py
INSTALLED_APPS = ["django_htmx", ...]
MIDDLEWARE = [
    "django.middleware.csrf.CsrfViewMiddleware",
    "django_htmx.middleware.HtmxMiddleware",  # Adds request.htmx
]
```

### Basic View Pattern

```python
# views.py
from django.shortcuts import render
from django.http import HttpResponse
from django.template.loader import render_to_string

def contact_list(request):
    contacts = Contact.objects.all()
    ctx = {"contacts": contacts}

    if request.htmx:
        return render(request, "contacts/partials/list.html", ctx)
    return render(request, "contacts/list.html", ctx)
```

### Template Structure

```
templates/
  contacts/
    list.html                  ← full page (extends base.html)
    partials/
      list.html                ← just the contact list table
      row.html                 ← single contact row
      form.html                ← contact form partial
      search_results.html      ← search results fragment
```

**Full page template:**

```html
<!-- templates/contacts/list.html -->
{% extends "base.html" %}
{% block content %}
  <h1>Contacts</h1>
  <input type="search" name="q" hx-get="{% url 'contact-search' %}"
         hx-trigger="input changed delay:300ms" hx-target="#contact-table">
  <div id="contact-table">
    {% include "contacts/partials/list.html" %}
  </div>
{% endblock %}
```

**Row partial — the key reusable unit:**

```html
<!-- templates/contacts/partials/row.html -->
<tr id="contact-{{ contact.id }}">
  <td>{{ contact.name }}</td>
  <td>{{ contact.email }}</td>
  <td>
    <button hx-get="{% url 'contact-edit' contact.id %}"
            hx-target="#contact-{{ contact.id }}" hx-swap="outerHTML">Edit</button>
    <button hx-delete="{% url 'contact-delete' contact.id %}"
            hx-target="#contact-{{ contact.id }}" hx-swap="outerHTML swap:500ms"
            hx-confirm="Delete {{ contact.name }}?">Delete</button>
  </td>
</tr>
```

### CRUD Views with OOB Updates

```python
from django_htmx.http import trigger_client_event

def contact_create(request):
    if request.method == "POST":
        form = ContactForm(request.POST)
        if form.is_valid():
            contact = form.save()
            html = render_to_string("contacts/partials/row.html",
                                    {"contact": contact}, request=request)
            count = Contact.objects.count()
            html += f'<span id="contact-count" hx-swap-oob="true">{count}</span>'
            response = HttpResponse(html)
            trigger_client_event(response, "showToast",
                                 {"message": f"Created {contact.name}", "level": "success"})
            return response
        else:
            return render(request, "contacts/partials/form.html",
                          {"form": form}, status=422)
    return render(request, "contacts/partials/form.html", {"form": ContactForm()})
```

### Django CSRF

```html
<body hx-headers='{"X-CSRFToken": "{{ csrf_token }}"}'>
```

---

## Flask

### Project Structure

```
app/
  __init__.py
  routes.py
  templates/
    base.html
    items/
      index.html
      partials/
        list.html
        item.html
        form.html
```

### htmx Detection Helper

```python
from flask import request, render_template

def is_htmx():
    return request.headers.get("HX-Request") == "true"
```

### CRUD Routes

```python
from flask import Flask, request, render_template, make_response
import json

app = Flask(__name__)

@app.route("/items")
def item_list():
    items = Item.query.all()
    if is_htmx():
        return render_template("items/partials/list.html", items=items)
    return render_template("items/index.html", items=items)

@app.route("/items", methods=["POST"])
def item_create():
    name = request.form.get("name")
    item = Item(name=name)
    db.session.add(item)
    db.session.commit()

    html = render_template("items/partials/item.html", item=item)
    count = Item.query.count()
    html += f'<span id="item-count" hx-swap-oob="true">{count} items</span>'

    resp = make_response(html, 201)
    resp.headers["HX-Trigger"] = json.dumps({
        "showToast": {"message": f"Created: {item.name}", "level": "success"}
    })
    return resp

@app.route("/items/<int:id>", methods=["DELETE"])
def item_delete(id):
    item = Item.query.get_or_404(id)
    db.session.delete(item)
    db.session.commit()
    count = Item.query.count()
    return make_response(f'<span id="item-count" hx-swap-oob="true">{count} items</span>')
```

### Flask Template Partials

```html
<!-- templates/items/index.html -->
{% extends "base.html" %}
{% block content %}
  <h1>Items</h1>
  <form hx-post="/items" hx-target="#item-list" hx-swap="beforeend"
        _="on htmx:afterRequest reset() me">
    <input name="name" required placeholder="New item">
    <button type="submit">Add</button>
  </form>
  <div id="item-list">{% include "partials/item_list.html" %}</div>
{% endblock %}
```

```html
<!-- templates/partials/item.html -->
<div id="item-{{ item.id }}" class="item-card">
  <span>{{ item.name }}</span>
  <button hx-delete="/items/{{ item.id }}" hx-target="#item-{{ item.id }}"
          hx-swap="outerHTML swap:300ms" hx-confirm="Delete?">×</button>
</div>
```

### Flask-WTF CSRF

```python
from flask_wtf.csrf import CSRFProtect
csrf = CSRFProtect(app)
# In templates: <body hx-headers='{"X-CSRFToken": "{{ csrf_token() }}"}'>
```

---

## Express.js

### Project Setup

```javascript
// server.js
const express = require("express");
const nunjucks = require("nunjucks");
const app = express();

app.use(express.urlencoded({ extended: true }));
app.use(express.static("public"));

nunjucks.configure("views", { autoescape: true, express: app });

// htmx middleware
app.use((req, res, next) => {
  req.htmx = req.headers["hx-request"] === "true";
  req.htmxTarget = req.headers["hx-target"];
  req.htmxTrigger = req.headers["hx-trigger"];
  req.htmxBoosted = req.headers["hx-boosted"] === "true";

  // Helper to send htmx trigger events
  res.htmxTrigger = (events) => {
    res.set("HX-Trigger", JSON.stringify(events));
    return res;
  };

  next();
});
```

### Route Handlers

```javascript
// routes/items.js
const router = require("express").Router();

router.get("/items", async (req, res) => {
  const items = await Item.findAll();
  const template = req.htmx ? "items/partials/list.njk" : "items/index.njk";
  res.render(template, { items });
});

router.post("/items", async (req, res) => {
  const item = await Item.create({ name: req.body.name });
  const count = await Item.count();

  let html = nunjucks.render("items/partials/item.njk", { item });
  html += `<span id="item-count" hx-swap-oob="true">${count} items</span>`;

  res
    .status(201)
    .set("HX-Trigger", JSON.stringify({
      showToast: { message: `Created ${item.name}`, level: "success" }
    }))
    .send(html);
});

router.delete("/items/:id", async (req, res) => {
  await Item.destroy({ where: { id: req.params.id } });
  const count = await Item.count();
  res.send(`<span id="item-count" hx-swap-oob="true">${count} items</span>`);
});

router.get("/search", async (req, res) => {
  const q = req.query.q || "";
  const items = await Item.findAll({
    where: { name: { [Op.iLike]: `%${q}%` } }
  });
  res.render("items/partials/list.njk", { items });
});

module.exports = router;
```

### Nunjucks Templates

```html
{# views/index.njk — full page extends base #}
{% extends "base.njk" %}
{% block content %}
  <h1>Items</h1>
  <form hx-post="/items" hx-target="#item-list" hx-swap="beforeend">
    <input name="name" required><button>Add</button>
  </form>
  <div id="item-list">{% include "partials/item_list.njk" %}</div>
{% endblock %}
```

```html
{# views/partials/item.njk #}
<div id="item-{{ item.id }}" class="item">
  <span>{{ item.name }}</span>
  <button hx-delete="/items/{{ item.id }}" hx-target="#item-{{ item.id }}"
          hx-swap="outerHTML swap:300ms" hx-confirm="Delete?">×</button>
</div>
```

### Express Error Handling for htmx

```javascript
app.use((err, req, res, next) => {
  if (req.htmx) {
    return res
      .status(err.status || 500)
      .send(`<div class="error">${err.status === 422 ? err.message : 'Something went wrong'}</div>`);
  }
  next(err);
});
```

---

## Go (templ + htmx)

### Project Structure

```
cmd/server/main.go
internal/
  handlers/items.go
  templates/
    layout.templ
    items.templ
    partials.templ
go.mod
```

### Setup with templ

```bash
go install github.com/a-h/templ/cmd/templ@latest
```

### Template Definitions (templ)

```go
// internal/templates/items.templ
package templates

templ ItemsPage(items []Item) {
    @Layout("Items") {
        <h1>Items</h1>
        <form hx-post="/items" hx-target="#item-list" hx-swap="beforeend">
            <input name="name" required/>
            <button type="submit">Add</button>
        </form>
        <div id="item-list">@ItemList(items)</div>
    }
}

templ ItemRow(item Item) {
    <div id={ fmt.Sprintf("item-%d", item.ID) } class="item">
        <span>{ item.Name }</span>
        <button hx-delete={ fmt.Sprintf("/items/%d", item.ID) }
                hx-target={ fmt.Sprintf("#item-%d", item.ID) }
                hx-swap="outerHTML swap:300ms" hx-confirm="Delete?">×</button>
    </div>
}
```

### Handler

```go
package handlers

func isHTMX(r *http.Request) bool {
    return r.Header.Get("HX-Request") == "true"
}

func ItemList(w http.ResponseWriter, r *http.Request) {
    items := db.GetAllItems()
    if isHTMX(r) {
        templates.ItemList(items).Render(r.Context(), w)
        return
    }
    templates.ItemsPage(items).Render(r.Context(), w)
}

func ItemCreate(w http.ResponseWriter, r *http.Request) {
    r.ParseForm()
    item := db.CreateItem(r.FormValue("name"))
    w.Header().Set("HX-Trigger", `{"showToast":{"message":"Item created"}}`)
    w.WriteHeader(http.StatusCreated)
    templates.ItemRow(item).Render(r.Context(), w)
}
```

### Main Server

```go
func main() {
    r := chi.NewRouter()
    r.Get("/items", handlers.ItemList)
    r.Post("/items", handlers.ItemCreate)
    r.Delete("/items/{id}", handlers.ItemDelete)
    http.ListenAndServe(":8080", r)
}
```

---

## Rails (Turbo vs htmx)

### Comparison: Turbo vs htmx

| Feature             | Turbo (default Rails) | htmx                          |
|----------------------|----------------------|-------------------------------|
| Bundling required    | Yes (importmap/esbuild) | No (CDN script tag)        |
| Frame concept        | `<turbo-frame>`      | `hx-target` + `hx-swap`      |
| Streaming            | Turbo Streams        | OOB swaps + SSE               |
| Morphing             | Built-in (8.0+)      | Idiomorph extension           |
| Custom triggers      | Limited              | Extensive (`hx-trigger`)      |
| Progressive enhance  | Moderate             | Strong (works without JS)     |
| Server coupling      | Tight (Rails-only)   | Loose (any server)            |

### htmx in Rails Setup

```html
<!-- app/views/layouts/application.html.erb -->
<!DOCTYPE html>
<html>
<head>
  <script src="https://unpkg.com/htmx.org@2.0.4"></script>
  <meta name="csrf-token" content="<%= form_authenticity_token %>">
  <script>
    document.body.addEventListener("htmx:configRequest", (e) => {
      e.detail.headers["X-CSRF-Token"] =
        document.querySelector('meta[name="csrf-token"]').content;
    });
  </script>
</head>
<body>
  <%= yield %>
</body>
</html>
```

### Rails Controller with htmx

```ruby
class ContactsController < ApplicationController
  def index
    @contacts = Contact.all
    if request.headers["HX-Request"]
      render partial: "contacts/list", locals: { contacts: @contacts }
    else
      render :index
    end
  end

  def create
    @contact = Contact.new(contact_params)
    if @contact.save
      html = render_to_string(partial: "contacts/row", locals: { contact: @contact })
      count = Contact.count
      html += "<span id='contact-count' hx-swap-oob='true'>#{count}</span>"
      render html: html.html_safe, status: :created
    else
      render partial: "contacts/form", locals: { contact: @contact },
             status: :unprocessable_entity
    end
  end

  private

  def contact_params
    params.require(:contact).permit(:name, :email)
  end
end
```

### Rails Partials

```erb
<!-- app/views/contacts/_row.html.erb -->
<tr id="contact-<%= contact.id %>">
  <td><%= contact.name %></td>
  <td><%= contact.email %></td>
  <td>
    <button hx-get="<%= edit_contact_path(contact) %>"
            hx-target="#contact-<%= contact.id %>" hx-swap="outerHTML">
      Edit
    </button>
    <button hx-delete="<%= contact_path(contact) %>"
            hx-target="#contact-<%= contact.id %>" hx-swap="outerHTML swap:300ms"
            hx-confirm="Delete?">
      Delete
    </button>
  </td>
</tr>
```

---

## FastAPI

### Setup with Jinja2

```python
# main.py
from fastapi import FastAPI, Request, Form, HTTPException
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates
from fastapi.staticfiles import StaticFiles

app = FastAPI()
app.mount("/static", StaticFiles(directory="static"), name="static")
templates = Jinja2Templates(directory="templates")

def is_htmx(request: Request) -> bool:
    return request.headers.get("HX-Request") == "true"
```

### FastAPI Routes

```python
@app.get("/items", response_class=HTMLResponse)
async def item_list(request: Request):
    items = await db.get_items()
    template = "items/partials/list.html" if is_htmx(request) else "items/index.html"
    return templates.TemplateResponse(template, {"request": request, "items": items})

@app.post("/items", response_class=HTMLResponse)
async def item_create(request: Request, name: str = Form(...)):
    item = await db.create_item(name)
    count = await db.item_count()
    html = templates.get_template("items/partials/item.html").render(
        {"item": item, "request": request})
    html += f'<span id="item-count" hx-swap-oob="true">{count} items</span>'
    return HTMLResponse(content=html, status_code=201,
        headers={"HX-Trigger": '{"showToast": {"message": "Item created"}}'})
```

### FastAPI SSE

```python
from sse_starlette.sse import EventSourceResponse

@app.get("/events")
async def event_stream(request: Request):
    async def generate():
        while not await request.is_disconnected():
            event = await get_next_event()
            if event:
                html = templates.get_template("partials/event.html").render(
                    {"event": event, "request": request})
                yield {"event": "update", "data": html}
            await asyncio.sleep(1)
    return EventSourceResponse(generate())
```

---

## Spring Boot

### Setup with Thymeleaf

```xml
<!-- pom.xml -->
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-thymeleaf</artifactId>
</dependency>
```

### htmx Detection

```java
// HtmxUtils.java
public class HtmxUtils {
    public static boolean isHtmxRequest(HttpServletRequest request) {
        return "true".equals(request.getHeader("HX-Request"));
    }

    public static String getHxTarget(HttpServletRequest request) {
        return request.getHeader("HX-Target");
    }
}
```

### Controller

```java
@Controller
@RequestMapping("/items")
public class ItemController {
    @Autowired private ItemRepository itemRepo;

    @GetMapping
    public String list(HttpServletRequest request, Model model) {
        model.addAttribute("items", itemRepo.findAll());
        return HtmxUtils.isHtmxRequest(request) ? "items/fragments :: itemList" : "items/index";
    }

    @PostMapping
    public ResponseEntity<String> create(@RequestParam String name) {
        Item item = itemRepo.save(new Item(name));
        long count = itemRepo.count();
        Context ctx = new Context();
        ctx.setVariable("item", item);
        String html = templateEngine.process("items/fragments", Set.of("itemRow"), ctx);
        html += String.format("<span id='item-count' hx-swap-oob='true'>%d items</span>", count);
        return ResponseEntity.status(HttpStatus.CREATED)
            .header("HX-Trigger", "{\"showToast\":{\"message\":\"Item created\"}}")
            .body(html);
    }
}
```

### Thymeleaf Fragments

Use `th:fragment` to define reusable template fragments that htmx can request:

```html
<!-- templates/items/fragments.html -->
<table th:fragment="itemList">
  <tbody>
    <tr th:each="item : ${items}" th:fragment="itemRow" th:id="'item-' + ${item.id}">
      <td th:text="${item.name}">Name</td>
      <td>
        <button th:attr="hx-delete='/items/' + ${item.id}, hx-target='#item-' + ${item.id}"
                hx-swap="outerHTML swap:300ms" hx-confirm="Delete?">Delete</button>
      </td>
    </tr>
  </tbody>
</table>
```

### Spring Security CSRF with htmx

```html
<!-- In layout template -->
<meta name="_csrf" th:content="${_csrf.token}">
<meta name="_csrf_header" th:content="${_csrf.headerName}">
<script>
document.body.addEventListener("htmx:configRequest", (e) => {
  e.detail.headers[document.querySelector('meta[name="_csrf_header"]').content] =
    document.querySelector('meta[name="_csrf"]').content;
});
</script>
```

---

## Phoenix LiveView Comparison

### When to Use htmx vs LiveView

| Scenario                          | Recommendation  |
|-----------------------------------|-----------------|
| Real-time collaborative editing   | LiveView        |
| Server-rendered CRUD with AJAX    | htmx            |
| Persistent WebSocket state        | LiveView        |
| Progressive enhancement priority  | htmx            |
| Elixir/Phoenix backend            | Either          |
| Non-Elixir backend                | htmx            |
| Complex client-side interactions  | LiveView        |
| Simple partial updates            | htmx            |

### htmx in Phoenix (Without LiveView)

```elixir
# item_controller.ex
defmodule MyAppWeb.ItemController do
  use MyAppWeb, :controller

  def index(conn, _params) do
    items = Items.list_items()
    if get_req_header(conn, "hx-request") == ["true"] do
      render(conn, "partials/list.html", items: items, layout: false)
    else
      render(conn, "index.html", items: items)
    end
  end

  def create(conn, %{"name" => name}) do
    {:ok, item} = Items.create_item(%{name: name})
    count = Items.count_items()
    html = render_to_string(MyAppWeb.ItemView, "partials/item.html",
                            item: item, conn: conn)
    html = html <> ~s(<span id="item-count" hx-swap-oob="true">#{count} items</span>)

    conn
    |> put_status(201)
    |> put_resp_header("hx-trigger", Jason.encode!(%{showToast: %{message: "Created"}}))
    |> html(html)
  end
end
```

---

## Cross-Framework Patterns

### Universal htmx Middleware Pattern

Every framework should implement these three concerns:

```
1. Request Detection    → Check HX-Request header
2. Partial Rendering    → Return fragment, not full page
3. Response Headers     → Set HX-Trigger, HX-Retarget, etc.
```

### Template Fragment Strategy

All frameworks benefit from a consistent partial template organization:

```
templates/
  {resource}/
    index.html           ← Full page (extends layout)
    partials/
      list.html          ← Collection rendering
      item.html          ← Single item
      form.html          ← Create/edit form
      form_errors.html   ← Validation error state
```

### OOB Update Helper

```python
# Python universal OOB helper
def oob_swap(element_id, content, strategy="true"):
    return f'<span id="{element_id}" hx-swap-oob="{strategy}">{content}</span>'

# Usage
html = render("partials/item.html", item=item)
html += oob_swap("item-count", f"{count} items")
```

```javascript
// JavaScript universal OOB helper
function oobSwap(id, content, strategy = "true") {
  return `<span id="${id}" hx-swap-oob="${strategy}">${content}</span>`;
}
```

### Error Response Convention

| Status | Response                                        | htmx Behavior         |
|--------|------------------------------------------------|-----------------------|
| 200    | HTML fragment                                   | Normal swap           |
| 201    | HTML fragment + OOB updates                     | Normal swap           |
| 204    | Empty (for delete operations)                   | No swap               |
| 422    | Form with errors + HX-Retarget + HX-Reswap     | Re-render form        |
| 401    | HX-Redirect: /login                             | Client redirect       |
| 500    | Error HTML fragment                              | Show error message    |
