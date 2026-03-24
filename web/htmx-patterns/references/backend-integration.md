# htmx Backend Integration Guide

## Table of Contents

- [General Principles](#general-principles)
- [Express / Fastify (Node.js)](#express--fastify-nodejs)
- [Django (Python)](#django-python)
- [Flask / FastAPI (Python)](#flask--fastapi-python)
- [Go (net/http, Echo, Fiber)](#go-nethttp-echo-fiber)
- [Rails](#rails)
- [Phoenix LiveView Comparison](#phoenix-liveview-comparison)
- [Partial Template Rendering Strategies](#partial-template-rendering-strategies)
- [OOB Swap Patterns](#oob-swap-patterns)
- [Response Header Usage](#response-header-usage)

---

## General Principles

Every htmx backend must handle three concerns:

1. **Detect htmx requests** — check `HX-Request: true` header
2. **Return HTML fragments** — not full pages, not JSON
3. **Use response headers** — `HX-Trigger`, `HX-Redirect`, `HX-Retarget`, etc.

Template organization pattern used across all frameworks:

```
templates/
  contacts/
    index.html          # Full page (extends base layout)
    _list.html           # Partial: table/list of contacts
    _row.html            # Partial: single contact row
    _form.html           # Partial: create/edit form
    _search_results.html # Partial: search results fragment
```

Convention: prefix partials with `_` to distinguish from full-page templates.

## Express / Fastify (Node.js)

### Express with EJS

```javascript
const express = require('express');
const app = express();
app.set('view engine', 'ejs');

// Middleware: detect htmx and set helper
app.use((req, res, next) => {
  req.isHtmx = req.headers['hx-request'] === 'true';
  req.htmxTarget = req.headers['hx-target'];
  req.htmxTrigger = req.headers['hx-trigger'];
  // Helper to render partial or full page
  res.renderPartial = (partial, full, data) => {
    if (req.isHtmx) return res.render(partial, data);
    return res.render(full, data);
  };
  // No-cache for htmx responses
  if (req.isHtmx) res.set('Vary', 'HX-Request');
  next();
});

// CRUD routes
app.get('/contacts', async (req, res) => {
  const contacts = await Contact.search(req.query.q);
  res.renderPartial('contacts/_list', 'contacts/index', { contacts });
});

app.post('/contacts', async (req, res) => {
  const errors = validate(req.body);
  if (errors.length) {
    return res.status(422).render('contacts/_form', { errors, values: req.body });
  }
  const contact = await Contact.create(req.body);
  res.set('HX-Trigger', JSON.stringify({ showToast: 'Contact created' }));
  res.render('contacts/_row', { contact });
});

app.delete('/contacts/:id', async (req, res) => {
  await Contact.delete(req.params.id);
  res.set('HX-Trigger', JSON.stringify({
    showToast: 'Contact deleted',
    contactListChanged: true
  }));
  res.send('');  // Empty response with hx-swap="delete" on client
});
```

### Fastify

```javascript
import Fastify from 'fastify';
import pointOfView from '@fastify/view';
import ejs from 'ejs';

const fastify = Fastify();
await fastify.register(pointOfView, { engine: { ejs } });

// Decorate request with htmx detection
fastify.decorateRequest('isHtmx', false);
fastify.addHook('onRequest', async (req) => {
  req.isHtmx = req.headers['hx-request'] === 'true';
});

fastify.get('/contacts', async (req, reply) => {
  const contacts = await getContacts(req.query.q);
  const template = req.isHtmx ? 'contacts/_list.ejs' : 'contacts/index.ejs';
  return reply.view(template, { contacts });
});

fastify.post('/contacts', async (req, reply) => {
  const errors = validate(req.body);
  if (errors.length) {
    reply.status(422);
    return reply.view('contacts/_form.ejs', { errors, values: req.body });
  }
  const contact = await createContact(req.body);
  reply.header('HX-Trigger', JSON.stringify({ showToast: 'Contact saved' }));
  return reply.view('contacts/_row.ejs', { contact });
});
```

## Django (Python)

### Middleware for htmx detection

```python
# middleware.py
class HtmxMiddleware:
    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        request.htmx = request.headers.get("HX-Request") == "true"
        request.htmx_target = request.headers.get("HX-Target", "")
        request.htmx_trigger = request.headers.get("HX-Trigger", "")
        request.htmx_boosted = request.headers.get("HX-Boosted") == "true"
        return self.get_response(request)
```

### Class-based views with htmx

```python
# views.py
from django.views import View
from django.http import HttpResponse
from django.template.loader import render_to_string
from django.shortcuts import render
import json

class HtmxMixin:
    """Mixin that returns partials for htmx requests."""
    partial_template = None

    def get_template_names(self):
        if self.request.htmx and self.partial_template:
            return [self.partial_template]
        return super().get_template_names()

class ContactListView(HtmxMixin, ListView):
    model = Contact
    template_name = "contacts/index.html"
    partial_template = "contacts/_list.html"
    context_object_name = "contacts"

    def get_queryset(self):
        qs = super().get_queryset()
        q = self.request.GET.get("q")
        if q:
            qs = qs.filter(name__icontains=q)
        return qs

class ContactCreateView(View):
    def post(self, request):
        form = ContactForm(request.POST)
        if not form.is_valid():
            html = render_to_string("contacts/_form.html",
                                    {"form": form}, request=request)
            return HttpResponse(html, status=422)
        contact = form.save()
        response = HttpResponse(
            render_to_string("contacts/_row.html", {"contact": contact})
        )
        response["HX-Trigger"] = json.dumps({"showToast": "Contact created"})
        return response
```

### django-htmx library

The `django-htmx` package provides a polished middleware and request extensions:

```python
# settings.py
INSTALLED_APPS = [..., "django_htmx"]
MIDDLEWARE = [..., "django_htmx.middleware.HtmxMiddleware"]

# views.py — use request.htmx (a rich object)
def contact_list(request):
    contacts = Contact.objects.all()
    if request.htmx:
        if request.htmx.target == "search-results":
            q = request.GET.get("q", "")
            contacts = contacts.filter(name__icontains=q)
            return render(request, "contacts/_search_results.html",
                         {"contacts": contacts})
        return render(request, "contacts/_list.html", {"contacts": contacts})
    return render(request, "contacts/index.html", {"contacts": contacts})
```

## Flask / FastAPI (Python)

### Flask

```python
from flask import Flask, render_template, request, jsonify
from functools import wraps
import json

app = Flask(__name__)

def htmx_aware(full_template, partial_template):
    """Decorator that renders partial for htmx, full page otherwise."""
    def decorator(f):
        @wraps(f)
        def wrapper(*args, **kwargs):
            context = f(*args, **kwargs)
            if request.headers.get("HX-Request"):
                return render_template(partial_template, **context)
            return render_template(full_template, **context)
        return wrapper
    return decorator

@app.route("/contacts")
@htmx_aware("contacts/index.html", "contacts/_list.html")
def contact_list():
    q = request.args.get("q", "")
    contacts = Contact.query.filter(Contact.name.ilike(f"%{q}%")).all()
    return {"contacts": contacts, "query": q}

@app.route("/contacts", methods=["POST"])
def create_contact():
    form = ContactForm(request.form)
    if not form.validate():
        return render_template("contacts/_form.html",
                             form=form), 422
    contact = Contact(**form.data)
    db.session.add(contact)
    db.session.commit()
    response = make_response(render_template("contacts/_row.html", contact=contact))
    response.headers["HX-Trigger"] = json.dumps({"showToast": "Contact saved"})
    return response, 201

@app.after_request
def htmx_cache_control(response):
    if request.headers.get("HX-Request"):
        response.headers["Vary"] = "HX-Request"
    return response
```

### FastAPI with Jinja2

```python
from fastapi import FastAPI, Request, Form, HTTPException
from fastapi.templating import Jinja2Templates
from fastapi.responses import HTMLResponse
import json

app = FastAPI()
templates = Jinja2Templates(directory="templates")

def is_htmx(request: Request) -> bool:
    return request.headers.get("hx-request") == "true"

@app.get("/contacts", response_class=HTMLResponse)
async def contact_list(request: Request, q: str = ""):
    contacts = await Contact.search(q)
    template = "contacts/_list.html" if is_htmx(request) else "contacts/index.html"
    return templates.TemplateResponse(template,
        {"request": request, "contacts": contacts, "query": q})

@app.post("/contacts", response_class=HTMLResponse)
async def create_contact(request: Request,
                         name: str = Form(...),
                         email: str = Form(...)):
    errors = validate_contact(name, email)
    if errors:
        return templates.TemplateResponse("contacts/_form.html",
            {"request": request, "errors": errors,
             "values": {"name": name, "email": email}},
            status_code=422)
    contact = await Contact.create(name=name, email=email)
    response = templates.TemplateResponse("contacts/_row.html",
        {"request": request, "contact": contact})
    response.headers["HX-Trigger"] = json.dumps({"showToast": "Contact created"})
    response.status_code = 201
    return response

# Middleware for Vary header
@app.middleware("http")
async def htmx_vary(request: Request, call_next):
    response = await call_next(request)
    if request.headers.get("hx-request"):
        response.headers["Vary"] = "HX-Request"
    return response
```

## Go (net/http, Echo, Fiber)

### net/http with html/template

```go
package main

import (
    "encoding/json"
    "html/template"
    "net/http"
)

var tmpl = template.Must(template.ParseGlob("templates/**/*.html"))

func isHtmx(r *http.Request) bool {
    return r.Header.Get("HX-Request") == "true"
}

func contactsHandler(w http.ResponseWriter, r *http.Request) {
    contacts := getContacts(r.URL.Query().Get("q"))
    data := map[string]interface{}{"Contacts": contacts}

    if isHtmx(r) {
        w.Header().Set("Vary", "HX-Request")
        tmpl.ExecuteTemplate(w, "contacts/_list.html", data)
        return
    }
    tmpl.ExecuteTemplate(w, "contacts/index.html", data)
}

func createContactHandler(w http.ResponseWriter, r *http.Request) {
    r.ParseForm()
    errors := validateContact(r.Form)
    if len(errors) > 0 {
        w.WriteHeader(422)
        tmpl.ExecuteTemplate(w, "contacts/_form.html",
            map[string]interface{}{"Errors": errors, "Values": r.Form})
        return
    }
    contact := createContact(r.Form)
    trigger, _ := json.Marshal(map[string]string{"showToast": "Contact created"})
    w.Header().Set("HX-Trigger", string(trigger))
    w.WriteHeader(201)
    tmpl.ExecuteTemplate(w, "contacts/_row.html", contact)
}

func main() {
    http.HandleFunc("GET /contacts", contactsHandler)
    http.HandleFunc("POST /contacts", createContactHandler)
    http.ListenAndServe(":8080", nil)
}
```

### Echo framework

```go
func contactRoutes(e *echo.Echo) {
    // Middleware
    e.Use(func(next echo.HandlerFunc) echo.HandlerFunc {
        return func(c echo.Context) error {
            c.Set("htmx", c.Request().Header.Get("HX-Request") == "true")
            if c.Get("htmx").(bool) {
                c.Response().Header().Set("Vary", "HX-Request")
            }
            return next(c)
        }
    })

    e.GET("/contacts", func(c echo.Context) error {
        contacts := getContacts(c.QueryParam("q"))
        if c.Get("htmx").(bool) {
            return c.Render(200, "contacts/_list", contacts)
        }
        return c.Render(200, "contacts/index", contacts)
    })

    e.POST("/contacts", func(c echo.Context) error {
        var input ContactInput
        if err := c.Bind(&input); err != nil {
            return c.Render(422, "contacts/_form", map[string]interface{}{
                "Errors": []string{err.Error()},
            })
        }
        contact := createContact(input)
        c.Response().Header().Set("HX-Trigger",
            `{"showToast": "Contact created"}`)
        return c.Render(201, "contacts/_row", contact)
    })
}
```

### Fiber

```go
func setupRoutes(app *fiber.App) {
    app.Use(func(c *fiber.Ctx) error {
        c.Locals("htmx", c.Get("HX-Request") == "true")
        if c.Locals("htmx").(bool) {
            c.Set("Vary", "HX-Request")
        }
        return c.Next()
    })

    app.Get("/contacts", func(c *fiber.Ctx) error {
        contacts := getContacts(c.Query("q"))
        tmpl := "contacts/index"
        if c.Locals("htmx").(bool) {
            tmpl = "contacts/_list"
        }
        return c.Render(tmpl, fiber.Map{"Contacts": contacts})
    })
}
```

## Rails

### Controller concern

```ruby
# app/controllers/concerns/htmx_aware.rb
module HtmxAware
  extend ActiveSupport::Concern

  included do
    before_action :set_htmx_headers
  end

  private

  def htmx_request?
    request.headers["HX-Request"] == "true"
  end

  def htmx_target
    request.headers["HX-Target"]
  end

  def htmx_boosted?
    request.headers["HX-Boosted"] == "true"
  end

  def set_htmx_headers
    response.headers["Vary"] = "HX-Request" if htmx_request?
  end

  def render_partial_or_full(partial:, full: nil, locals: {})
    if htmx_request?
      render partial: partial, locals: locals
    else
      instance_variables_from_locals(locals)
      render full || partial.sub(%r{/+_}, "/")
    end
  end

  def htmx_trigger(events)
    response.headers["HX-Trigger"] = events.to_json
  end

  def htmx_redirect(url)
    response.headers["HX-Redirect"] = url
    head :ok
  end
end

# app/controllers/contacts_controller.rb
class ContactsController < ApplicationController
  include HtmxAware

  def index
    @contacts = Contact.search(params[:q])
    render_partial_or_full(
      partial: "contacts/list",
      full: "contacts/index",
      locals: { contacts: @contacts }
    )
  end

  def create
    @contact = Contact.new(contact_params)
    if @contact.save
      htmx_trigger(showToast: "Contact created")
      render partial: "contacts/row", locals: { contact: @contact }, status: :created
    else
      render partial: "contacts/form",
             locals: { contact: @contact }, status: :unprocessable_entity
    end
  end

  def destroy
    @contact = Contact.find(params[:id])
    @contact.destroy
    htmx_trigger(showToast: "Contact deleted", contactListChanged: true)
    head :ok
  end
end
```

### Turbo vs htmx

Rails ships with Turbo (Hotwire). Key differences for teams evaluating:

| Aspect         | htmx                           | Turbo                          |
|----------------|--------------------------------|--------------------------------|
| Install        | Script tag, no build           | Bundled via importmap or npm   |
| Frames         | hx-target + any element        | `<turbo-frame>` wrapper needed |
| Streams        | hx-swap-oob, SSE/WS extensions| Turbo Streams (7 actions)      |
| Backend tie-in | Any backend                    | Rails-first                    |
| Config         | HTML attributes                | HTML attributes + conventions  |

## Phoenix LiveView Comparison

Phoenix LiveView maintains server-side state via WebSockets. htmx is stateless HTTP.

| Aspect            | htmx                              | LiveView                         |
|-------------------|------------------------------------|----------------------------------|
| Protocol          | HTTP (stateless)                   | WebSocket (stateful)             |
| State             | Server renders, client is stateless| Server holds process state       |
| Real-time         | SSE/WS extensions, polling         | Built-in via WebSocket           |
| Latency tolerance | Any (HTTP request/response)        | Low latency needed for good UX   |
| Scaling           | Standard HTTP scaling              | Per-connection process on server  |
| Backend           | Any language/framework             | Elixir/Phoenix only              |
| JavaScript        | ~14KB, no build step               | ~30KB, Phoenix JS required       |

**When htmx is better:** Multi-backend teams, simpler CRUD apps, content-heavy sites, when you want stateless HTTP.

**When LiveView is better:** Real-time collaborative apps, complex form state, when team is already on Elixir/Phoenix.

## Partial Template Rendering Strategies

### Strategy 1: Separate partial files (recommended)

```
templates/contacts/
  index.html        →  {% extends "base.html" %} {% include "_list.html" %}
  _list.html        →  <table>{% for c in contacts %}{% include "_row.html" %}{% endfor %}</table>
  _row.html         →  <tr id="contact-{{ c.id }}">...</tr>
  _form.html        →  <form hx-post="/contacts">...</form>
```

Server returns `_list.html` for htmx, `index.html` for full page. Partials compose into full pages.

### Strategy 2: Block extraction (Django/Jinja2)

Use template inheritance with block selection:

```html
<!-- contacts/index.html -->
{% extends "base.html" %}
{% block content %}
  <h1>Contacts</h1>
  {% block contact_list %}
    {% include "contacts/_list.html" %}
  {% endblock %}
{% endblock %}
```

```python
# Render just one block (requires django-render-block or similar)
from render_block import render_block_to_string

def contacts(request):
    ctx = {"contacts": Contact.objects.all()}
    if request.htmx:
        return HttpResponse(
            render_block_to_string("contacts/index.html", "contact_list", ctx))
    return render(request, "contacts/index.html", ctx)
```

### Strategy 3: hx-select (client-side extraction)

Let the client extract fragments from a full-page response:

```html
<button hx-get="/contacts"
        hx-target="#contact-list"
        hx-select="#contact-list">
  Reload List
</button>
```

Simpler server-side (always returns full page), but wastes bandwidth. Use for progressive enhancement of existing server-rendered apps.

## OOB Swap Patterns

### Pattern 1: Inline OOB in response

```python
def create_contact(request):
    contact = Contact.create(**request.form)
    row_html = render_template("contacts/_row.html", contact=contact)
    count_html = f'<span id="contact-count" hx-swap-oob="true">{Contact.count()}</span>'
    toast_html = '<div id="toasts" hx-swap-oob="afterbegin"><div class="toast">Saved!</div></div>'
    return row_html + count_html + toast_html
```

### Pattern 2: OOB helper function

```python
def oob(template, context, target_id, swap="true"):
    html = render_template(template, **context)
    return f'<div id="{target_id}" hx-swap-oob="{swap}">{html}</div>'

def create_contact(request):
    contact = Contact.create(**request.form)
    parts = [
        render_template("contacts/_row.html", contact=contact),
        oob("_count.html", {"count": Contact.count()}, "contact-count"),
        oob("_toast.html", {"msg": "Saved!"}, "toasts", "afterbegin"),
    ]
    return "\n".join(parts)
```

### Pattern 3: HX-Trigger events (preferred for complex updates)

Instead of crafting OOB HTML, emit events and let the page react:

```python
def create_contact(request):
    contact = Contact.create(**request.form)
    response = make_response(render_template("contacts/_row.html", contact=contact))
    response.headers["HX-Trigger"] = json.dumps({
        "contactCreated": {"id": contact.id},
        "flashMessage": {"level": "success", "text": "Contact saved"}
    })
    return response
```

Client-side listeners fetch their own updates:

```html
<span hx-get="/contacts/count"
      hx-trigger="contactCreated from:body"
      hx-target="this"
      hx-swap="innerHTML">0</span>
```

This decouples the server from page structure.

## Response Header Usage

### HX-Trigger — trigger client events

```python
# Single event
response.headers["HX-Trigger"] = "contactListChanged"

# Multiple events with data
response.headers["HX-Trigger"] = json.dumps({
    "showToast": {"message": "Saved!", "type": "success"},
    "updateBadge": {"section": "contacts", "count": 42}
})
```

Listen in HTML:

```html
<div hx-get="/notifications/badge"
     hx-trigger="updateBadge from:body"
     hx-target="this">
</div>
```

Or in JavaScript:

```javascript
document.body.addEventListener('showToast', (evt) => {
  const { message, type } = evt.detail;
  displayToast(message, type);
});
```

### HX-Redirect / HX-Refresh

```python
# Redirect after successful action (replaces full page)
response.headers["HX-Redirect"] = "/contacts"
return response  # Body is ignored

# Force full page refresh
response.headers["HX-Refresh"] = "true"
```

### HX-Retarget / HX-Reswap

Override the client's `hx-target` and `hx-swap` from the server:

```python
# Validation error: retarget to the form itself, reswap to outerHTML
if errors:
    response = make_response(render_template("_form.html", errors=errors), 422)
    response.headers["HX-Retarget"] = "#contact-form"
    response.headers["HX-Reswap"] = "outerHTML"
    return response
```

### HX-Push-Url / HX-Replace-Url

```python
# Server-driven URL management
response.headers["HX-Push-Url"] = f"/contacts/{contact.id}"

# Update URL without adding history entry
response.headers["HX-Replace-Url"] = f"/contacts?page={page}"

# Prevent URL change even if client set hx-push-url
response.headers["HX-Push-Url"] = "false"
```

### Header combination patterns

```python
def after_create(contact):
    """Common pattern: redirect + toast after creating a resource."""
    response = HttpResponse(status=204)
    response["HX-Redirect"] = f"/contacts/{contact.id}"
    response["HX-Trigger"] = json.dumps({
        "showToast": f"Created {contact.name}"
    })
    return response

def after_inline_edit(contact):
    """Common pattern: swap row + update counter + toast."""
    html = render_to_string("contacts/_row.html", {"contact": contact})
    html += render_to_string("contacts/_count_oob.html",
                             {"count": Contact.objects.count()})
    response = HttpResponse(html)
    response["HX-Trigger-After-Settle"] = json.dumps({
        "showToast": "Updated successfully"
    })
    return response
```
