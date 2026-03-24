"""
Django Views Template for htmx Applications

Features:
- HtmxMiddleware for request detection
- HtmxMixin for class-based views (partial/full rendering)
- htmx response helpers (HX-Trigger, HX-Redirect, OOB swaps)
- CRUD view examples with validation and error handling
- Inline editing pattern
- Search with pagination

Usage:
  1. Add HtmxMiddleware to MIDDLEWARE in settings.py
  2. Use HtmxMixin in your views or call htmx helpers directly
  3. Organize templates with _ prefix for partials:
     templates/contacts/index.html     (full page)
     templates/contacts/_list.html     (partial: table body)
     templates/contacts/_row.html      (partial: single row)
     templates/contacts/_form.html     (partial: create/edit form)
"""

import json
from functools import wraps

from django.http import HttpResponse, HttpResponseBadRequest
from django.shortcuts import render, get_object_or_404, redirect
from django.template.loader import render_to_string
from django.views import View
from django.views.generic import ListView
from django.core.paginator import Paginator
from django.utils.decorators import method_decorator
from django.views.decorators.http import require_http_methods


# ═══════════════════════════════════════════════════════════════════════
# Middleware
# ═══════════════════════════════════════════════════════════════════════

class HtmxMiddleware:
    """
    Adds htmx-related attributes to every request:
      request.htmx       — True if HX-Request header is present
      request.htmx_target   — value of HX-Target header
      request.htmx_trigger  — value of HX-Trigger header (the element ID)
      request.htmx_boosted  — True if request came from hx-boost
      request.htmx_current_url — value of HX-Current-URL header

    Add to settings.py:
      MIDDLEWARE = [..., 'yourapp.middleware.HtmxMiddleware']
    """

    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        request.htmx = request.headers.get("HX-Request") == "true"
        request.htmx_target = request.headers.get("HX-Target", "")
        request.htmx_trigger = request.headers.get("HX-Trigger", "")
        request.htmx_boosted = request.headers.get("HX-Boosted") == "true"
        request.htmx_current_url = request.headers.get("HX-Current-URL", "")

        response = self.get_response(request)

        # Ensure caches differentiate htmx vs full-page responses
        if request.htmx:
            response["Vary"] = "HX-Request"

        return response


# ═══════════════════════════════════════════════════════════════════════
# Response Helpers
# ═══════════════════════════════════════════════════════════════════════

class HtmxResponse:
    """
    Fluent builder for htmx-aware responses.

    Usage:
        return (HtmxResponse(html)
                .trigger("showToast", "Item saved")
                .push_url(f"/items/{item.id}")
                .status(201)
                .build())
    """

    def __init__(self, content="", status=200, content_type="text/html"):
        self._content = content
        self._status = status
        self._content_type = content_type
        self._headers = {}
        self._oob_parts = []

    def trigger(self, event, data=None, timing=None):
        """Add an HX-Trigger event. Call multiple times to add multiple events."""
        header = {
            "afterSettle": "HX-Trigger-After-Settle",
            "afterSwap": "HX-Trigger-After-Swap",
        }.get(timing, "HX-Trigger")

        existing = self._headers.get(header, {})
        if isinstance(existing, str):
            existing = {existing: None}
        existing[event] = data
        self._headers[header] = existing
        return self

    def redirect(self, url):
        self._headers["HX-Redirect"] = url
        return self

    def refresh(self):
        self._headers["HX-Refresh"] = "true"
        return self

    def retarget(self, selector):
        self._headers["HX-Retarget"] = selector
        return self

    def reswap(self, strategy):
        self._headers["HX-Reswap"] = strategy
        return self

    def push_url(self, url):
        self._headers["HX-Push-Url"] = url
        return self

    def replace_url(self, url):
        self._headers["HX-Replace-Url"] = url
        return self

    def oob(self, html, target_id, swap="true"):
        """Add an out-of-band swap element to the response."""
        self._oob_parts.append(
            f'<div id="{target_id}" hx-swap-oob="{swap}">{html}</div>'
        )
        return self

    def oob_template(self, template, context, target_id, swap="true"):
        html = render_to_string(template, context)
        return self.oob(html, target_id, swap)

    def status(self, code):
        self._status = code
        return self

    def build(self):
        content = self._content
        if self._oob_parts:
            content += "\n" + "\n".join(self._oob_parts)

        response = HttpResponse(content, status=self._status,
                                content_type=self._content_type)
        for key, value in self._headers.items():
            if isinstance(value, dict):
                response[key] = json.dumps(value)
            else:
                response[key] = str(value)
        return response


def htmx_trigger(response, events, timing=None):
    """
    Shortcut: add HX-Trigger header to an existing response.

    Args:
        response: HttpResponse
        events: str or dict — event name or {event: data, ...}
        timing: None, 'afterSwap', or 'afterSettle'
    """
    header = {
        "afterSettle": "HX-Trigger-After-Settle",
        "afterSwap": "HX-Trigger-After-Swap",
    }.get(timing, "HX-Trigger")
    value = events if isinstance(events, str) else json.dumps(events)
    response[header] = value
    return response


def htmx_redirect(url):
    """Return a response that triggers client-side redirect."""
    response = HttpResponse(status=204)
    response["HX-Redirect"] = url
    return response


def htmx_refresh():
    """Return a response that triggers full page refresh."""
    response = HttpResponse(status=204)
    response["HX-Refresh"] = "true"
    return response


# ═══════════════════════════════════════════════════════════════════════
# View Mixin
# ═══════════════════════════════════════════════════════════════════════

class HtmxMixin:
    """
    Mixin for class-based views. Automatically renders partial templates
    for htmx requests and full templates for normal requests.

    Set `partial_template_name` on your view:

        class ContactListView(HtmxMixin, ListView):
            template_name = "contacts/index.html"
            partial_template_name = "contacts/_list.html"
    """
    partial_template_name = None

    def get_template_names(self):
        if getattr(self.request, "htmx", False) and self.partial_template_name:
            return [self.partial_template_name]
        return super().get_template_names()


# ═══════════════════════════════════════════════════════════════════════
# Decorator
# ═══════════════════════════════════════════════════════════════════════

def htmx_partial(partial_template):
    """
    Decorator that renders a partial template for htmx requests.
    The view function must return a context dict.

    Usage:
        @htmx_partial("contacts/_list.html")
        def contact_list(request):
            return {"contacts": Contact.objects.all()}
    """
    def decorator(view_func):
        @wraps(view_func)
        def wrapper(request, *args, **kwargs):
            context = view_func(request, *args, **kwargs)
            if isinstance(context, HttpResponse):
                return context
            if request.htmx:
                return render(request, partial_template, context)
            # Fall through to normal template resolution
            template = getattr(view_func, 'template_name', None)
            if template:
                return render(request, template, context)
            return render(request, partial_template, context)
        return wrapper
    return decorator


# ═══════════════════════════════════════════════════════════════════════
# Example Views
# ═══════════════════════════════════════════════════════════════════════

# These examples assume a Contact model:
#   class Contact(models.Model):
#       name = models.CharField(max_length=200)
#       email = models.EmailField(unique=True)
#       created_at = models.DateTimeField(auto_now_add=True)

# --- List with Search ---

class ContactListView(HtmxMixin, ListView):
    """
    GET /contacts/?q=search+term

    Full page: contacts/index.html (wraps _list.html in base layout)
    htmx:      contacts/_list.html (just the table rows)
    """
    # model = Contact  # Uncomment with real model
    template_name = "contacts/index.html"
    partial_template_name = "contacts/_list.html"
    context_object_name = "contacts"
    paginate_by = 25

    def get_queryset(self):
        qs = super().get_queryset()
        q = self.request.GET.get("q", "").strip()
        if q:
            qs = qs.filter(name__icontains=q)
        return qs.order_by("-created_at")

    def get_context_data(self, **kwargs):
        ctx = super().get_context_data(**kwargs)
        ctx["query"] = self.request.GET.get("q", "")
        ctx["total_count"] = self.get_queryset().count()
        return ctx


# --- Create ---

class ContactCreateView(View):
    """
    GET /contacts/new/   → render form
    POST /contacts/new/  → create contact, return row + OOB count update
    """

    def get(self, request):
        if request.htmx:
            return render(request, "contacts/_form.html", {"values": {}})
        return render(request, "contacts/new.html", {"values": {}})

    def post(self, request):
        name = request.POST.get("name", "").strip()
        email = request.POST.get("email", "").strip()

        errors = {}
        if len(name) < 2:
            errors["name"] = "Name must be at least 2 characters."
        if "@" not in email:
            errors["email"] = "Enter a valid email address."
        # Uncomment with real model:
        # if Contact.objects.filter(email=email).exists():
        #     errors["email"] = "This email is already in use."

        if errors:
            return (
                HtmxResponse(
                    render_to_string("contacts/_form.html", {
                        "errors": errors,
                        "values": {"name": name, "email": email},
                    }, request=request)
                )
                .retarget("#contact-form")
                .reswap("outerHTML")
                .status(422)
                .build()
            )

        # contact = Contact.objects.create(name=name, email=email)
        # Placeholder for demo:
        contact = type("Contact", (), {"id": 99, "name": name, "email": email})()

        return (
            HtmxResponse(
                render_to_string("contacts/_row.html", {"contact": contact},
                                 request=request)
            )
            .trigger("showToast", f"{contact.name} added successfully")
            .oob_template("contacts/_count.html",
                          {"count": 0},  # Contact.objects.count()
                          "contact-count")
            .status(201)
            .build()
        )


# --- Update (Inline Edit) ---

class ContactUpdateView(View):
    """
    GET  /contacts/<id>/edit/  → render edit form (inline)
    PUT  /contacts/<id>/       → save and return view-mode row
    """

    def get(self, request, pk):
        contact = get_object_or_404(None, pk=pk)  # Contact, pk=pk
        return render(request, "contacts/_edit_form.html", {"contact": contact})

    def put(self, request, pk):
        contact = get_object_or_404(None, pk=pk)  # Contact, pk=pk
        # Parse PUT body
        from django.http import QueryDict
        data = QueryDict(request.body)

        name = data.get("name", "").strip()
        email = data.get("email", "").strip()

        errors = {}
        if len(name) < 2:
            errors["name"] = "Name must be at least 2 characters."
        if "@" not in email:
            errors["email"] = "Enter a valid email address."

        if errors:
            return (
                HtmxResponse(
                    render_to_string("contacts/_edit_form.html", {
                        "contact": contact, "errors": errors,
                    }, request=request)
                )
                .status(422)
                .build()
            )

        contact.name = name
        contact.email = email
        # contact.save()

        return (
            HtmxResponse(
                render_to_string("contacts/_row.html", {"contact": contact},
                                 request=request)
            )
            .trigger("showToast", "Contact updated")
            .build()
        )


# --- Delete ---

@require_http_methods(["DELETE"])
def contact_delete(request, pk):
    """
    DELETE /contacts/<id>/
    Returns empty body; client uses hx-swap="outerHTML swap:300ms" to animate removal.
    OOB updates the contact count.
    """
    contact = get_object_or_404(None, pk=pk)  # Contact, pk=pk
    name = contact.name
    # contact.delete()

    return (
        HtmxResponse("")
        .trigger("showToast", f"{name} deleted")
        .oob(
            "0",  # str(Contact.objects.count())
            "contact-count"
        )
        .build()
    )


# --- Search (function-based view) ---

def contact_search(request):
    """
    GET /contacts/search/?q=term
    Always returns partial (used only by htmx search input).
    """
    q = request.GET.get("q", "").strip()
    contacts = []  # Contact.objects.filter(name__icontains=q)[:20] if q else []
    return render(request, "contacts/_search_results.html", {
        "contacts": contacts,
        "query": q,
    })


# --- Pagination for Infinite Scroll ---

def contact_feed(request):
    """
    GET /contacts/feed/?page=N
    Returns next page of contacts + sentinel for next page (or nothing if last).
    """
    page_num = int(request.GET.get("page", 1))
    all_contacts = []  # Contact.objects.order_by("-created_at")
    paginator = Paginator(all_contacts, 20)
    page = paginator.get_page(page_num)

    return render(request, "contacts/_feed_page.html", {
        "contacts": page.object_list,
        "has_next": page.has_next(),
        "next_page": page.next_page_number() if page.has_next() else None,
    })


# ═══════════════════════════════════════════════════════════════════════
# URL Configuration
# ═══════════════════════════════════════════════════════════════════════

# Add to your urls.py:
#
# from django.urls import path
# from . import views
#
# urlpatterns = [
#     path("contacts/", views.ContactListView.as_view(), name="contact-list"),
#     path("contacts/new/", views.ContactCreateView.as_view(), name="contact-create"),
#     path("contacts/search/", views.contact_search, name="contact-search"),
#     path("contacts/feed/", views.contact_feed, name="contact-feed"),
#     path("contacts/<int:pk>/", views.ContactUpdateView.as_view(), name="contact-update"),
#     path("contacts/<int:pk>/edit/", views.ContactUpdateView.as_view(), name="contact-edit"),
#     path("contacts/<int:pk>/delete/", views.contact_delete, name="contact-delete"),
# ]


# ═══════════════════════════════════════════════════════════════════════
# Template Examples
# ═══════════════════════════════════════════════════════════════════════

# contacts/_row.html:
# <tr id="contact-{{ contact.id }}" class="border-t">
#   <td class="px-4 py-3 cursor-pointer hover:bg-yellow-50"
#       hx-get="{% url 'contact-edit' contact.id %}"
#       hx-trigger="dblclick"
#       hx-target="closest tr"
#       hx-swap="outerHTML">{{ contact.name }}</td>
#   <td class="px-4 py-3">{{ contact.email }}</td>
#   <td class="px-4 py-3">
#     <button hx-delete="{% url 'contact-delete' contact.id %}"
#             hx-target="closest tr"
#             hx-swap="outerHTML swap:300ms"
#             hx-confirm="Delete {{ contact.name }}?"
#             class="text-red-500 hover:text-red-700">Delete</button>
#   </td>
# </tr>

# contacts/_form.html:
# <form id="contact-form"
#       hx-post="{% url 'contact-create' %}"
#       hx-target="#contact-table"
#       hx-swap="beforeend">
#   {% csrf_token %}
#   <div class="mb-4">
#     <label>Name</label>
#     <input name="name" value="{{ values.name|default:'' }}" required
#            class="border rounded px-3 py-2 w-full {% if errors.name %}border-red-500{% endif %}">
#     {% if errors.name %}<p class="text-red-500 text-sm mt-1">{{ errors.name }}</p>{% endif %}
#   </div>
#   <div class="mb-4">
#     <label>Email</label>
#     <input name="email" type="email" value="{{ values.email|default:'' }}" required
#            class="border rounded px-3 py-2 w-full {% if errors.email %}border-red-500{% endif %}">
#     {% if errors.email %}<p class="text-red-500 text-sm mt-1">{{ errors.email }}</p>{% endif %}
#   </div>
#   <button type="submit" class="px-4 py-2 bg-blue-600 text-white rounded">Save</button>
# </form>

# contacts/_count.html:
# <span id="contact-count">{{ count }}</span>

# contacts/_feed_page.html:
# {% for contact in contacts %}
#   {% include "contacts/_row.html" %}
# {% endfor %}
# {% if has_next %}
# <tr hx-get="{% url 'contact-feed' %}?page={{ next_page }}"
#     hx-trigger="revealed"
#     hx-swap="outerHTML">
#   <td colspan="3" class="text-center py-4 text-gray-500">Loading more...</td>
# </tr>
# {% endif %}
