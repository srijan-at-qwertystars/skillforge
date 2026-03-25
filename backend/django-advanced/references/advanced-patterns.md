# Django Advanced Patterns Reference

> Dense, actionable reference for Django 5.x advanced patterns.
> Each section includes production-ready code you can adapt directly.

## Table of Contents

- [Custom Model Managers & QuerySets](#custom-model-managers--querysets)
- [Multi-Database Routing](#multi-database-routing)
- [Database Transactions](#database-transactions)
- [Custom Middleware Patterns](#custom-middleware-patterns)
- [Signal Best Practices](#signal-best-practices)
- [Form Processing Patterns](#form-processing-patterns)
- [Admin Customization](#admin-customization)
- [Custom Template Tags & Filters](#custom-template-tags--filters)
- [Context Processors](#context-processors)
- [File Storage Backends](#file-storage-backends)
- [Custom Authentication Backends](#custom-authentication-backends)

---

## Custom Model Managers & QuerySets

### Pattern: Custom QuerySet + Manager (chainable API)

```python
from django.db import models
from django.utils import timezone

class ArticleQuerySet(models.QuerySet):
    def published(self):
        return self.filter(status="published", pub_date__lte=timezone.now())

    def by_author(self, user):
        return self.filter(author=user)

    def with_stats(self):
        return self.annotate(
            comment_count=models.Count("comments"),
            avg_rating=models.Avg("reviews__score"),
        )

    def popular(self, min_views=1000):
        return self.filter(view_count__gte=min_views)

# Manager from QuerySet — all QuerySet methods become Manager methods
class ArticleManager(models.Manager):
    def get_queryset(self):
        return ArticleQuerySet(self.model, using=self._db)

    # Delegate — allows Article.objects.published().popular()
    def published(self):
        return self.get_queryset().published()

class Article(models.Model):
    title = models.CharField(max_length=200)
    status = models.CharField(max_length=20, default="draft")
    pub_date = models.DateTimeField(null=True, blank=True)
    author = models.ForeignKey("auth.User", on_delete=models.CASCADE)
    view_count = models.PositiveIntegerField(default=0)

    objects = ArticleManager()

    class Meta:
        ordering = ["-pub_date"]
```

### Pattern: as_manager() shortcut

```python
class OrderQuerySet(models.QuerySet):
    def pending(self):
        return self.filter(status="pending")

    def completed(self):
        return self.filter(status="completed")

    def total_revenue(self):
        return self.aggregate(total=models.Sum("amount"))["total"] or 0

class Order(models.Model):
    amount = models.DecimalField(max_digits=10, decimal_places=2)
    status = models.CharField(max_length=20)

    objects = OrderQuerySet.as_manager()
    # Order.objects.pending().total_revenue()
```

### Pattern: Multiple managers

```python
class Article(models.Model):
    objects = models.Manager()            # default — all rows
    published = PublishedManager()        # filtered
    # Always keep default `objects` first so Django uses it for admin/relations
```

**Rules:**
- Put `objects = models.Manager()` first when adding custom managers.
- Use QuerySet subclasses for chainable methods; Manager for entry points.
- Never put row-level logic in managers — use model methods instead.

---

## Multi-Database Routing

### Settings

```python
DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.postgresql",
        "NAME": "primary_db",
        "HOST": "primary.db.example.com",
    },
    "replica": {
        "ENGINE": "django.db.backends.postgresql",
        "NAME": "primary_db",
        "HOST": "replica.db.example.com",
        "TEST": {"MIRROR": "default"},
    },
    "analytics": {
        "ENGINE": "django.db.backends.postgresql",
        "NAME": "analytics_db",
    },
}
DATABASE_ROUTERS = ["myproject.routers.PrimaryReplicaRouter", "myproject.routers.AnalyticsRouter"]
```

### Router implementation

```python
# myproject/routers.py

class PrimaryReplicaRouter:
    """Route reads to replica, writes to primary."""

    def db_for_read(self, model, **hints):
        return "replica"

    def db_for_write(self, model, **hints):
        return "default"

    def allow_relation(self, obj1, obj2, **hints):
        db_set = {"default", "replica"}
        if obj1._state.db in db_set and obj2._state.db in db_set:
            return True
        return None

    def allow_migrate(self, db, app_label, model_name=None, **hints):
        return True


class AnalyticsRouter:
    """Route analytics app to separate database."""
    route_app_labels = {"analytics"}

    def db_for_read(self, model, **hints):
        if model._meta.app_label in self.route_app_labels:
            return "analytics"
        return None

    def db_for_write(self, model, **hints):
        if model._meta.app_label in self.route_app_labels:
            return "analytics"
        return None

    def allow_relation(self, obj1, obj2, **hints):
        if (obj1._meta.app_label in self.route_app_labels or
                obj2._meta.app_label in self.route_app_labels):
            return obj1._meta.app_label == obj2._meta.app_label
        return None

    def allow_migrate(self, db, app_label, model_name=None, **hints):
        if app_label in self.route_app_labels:
            return db == "analytics"
        return None
```

### Manual routing

```python
# Explicit database selection
User.objects.using("replica").all()

# Saving to specific database
user.save(using="default")

# Cross-database atomic (each DB gets its own transaction)
from django.db import transaction
with transaction.atomic(using="default"):
    Order.objects.create(...)
with transaction.atomic(using="analytics"):
    AnalyticsEvent.objects.create(...)
```

---

## Database Transactions

### atomic() — basic and nested

```python
from django.db import transaction

# Context manager
with transaction.atomic():
    order = Order.objects.create(customer=customer, total=100)
    OrderItem.objects.create(order=order, product=product, qty=1)
    product.stock = models.F("stock") - 1
    product.save(update_fields=["stock"])

# Decorator
@transaction.atomic
def transfer_funds(from_account, to_account, amount):
    from_account.balance = models.F("balance") - amount
    from_account.save(update_fields=["balance"])
    to_account.balance = models.F("balance") + amount
    to_account.save(update_fields=["balance"])

# Nested atomic blocks create savepoints
with transaction.atomic():                      # outer
    Order.objects.create(...)
    with transaction.atomic():                  # savepoint
        try:
            risky_operation()
        except SomeError:
            pass  # savepoint rolled back, outer continues
```

### Manual savepoints

```python
with transaction.atomic():
    do_setup()
    sid = transaction.savepoint()
    try:
        do_risky_work()
    except Exception:
        transaction.savepoint_rollback(sid)
        do_fallback_work()
    else:
        transaction.savepoint_commit(sid)
    do_cleanup()  # always runs
```

### on_commit() — defer side effects until commit succeeds

```python
from django.db import transaction

def send_order_email(order_id):
    order = Order.objects.get(pk=order_id)
    # send email...

with transaction.atomic():
    order = Order.objects.create(...)
    # Email only sent if the transaction commits successfully
    transaction.on_commit(lambda: send_order_email(order.pk))

# With Celery
with transaction.atomic():
    order = Order.objects.create(...)
    transaction.on_commit(lambda: process_order.delay(order.pk))

# Django 5.x: on_commit with robust=True (won't break on handler errors)
transaction.on_commit(send_notification, robust=True)
```

### select_for_update() — row-level locking

```python
with transaction.atomic():
    account = Account.objects.select_for_update().get(pk=account_id)
    account.balance -= amount
    account.save(update_fields=["balance"])

# skip_locked=True — skip locked rows (useful for job queues)
with transaction.atomic():
    job = Job.objects.select_for_update(skip_locked=True).filter(
        status="pending"
    ).first()
    if job:
        job.status = "processing"
        job.save(update_fields=["status"])
```

---

## Custom Middleware Patterns

### Rate limiting middleware

```python
import time
from django.core.cache import cache
from django.http import JsonResponse

class RateLimitMiddleware:
    def __init__(self, get_response):
        self.get_response = get_response
        self.rate_limit = 100  # requests per minute

    def __call__(self, request):
        if request.path.startswith("/api/"):
            ip = self._get_client_ip(request)
            key = f"ratelimit:{ip}"
            count = cache.get(key, 0)
            if count >= self.rate_limit:
                return JsonResponse({"error": "Rate limit exceeded"}, status=429)
            cache.set(key, count + 1, timeout=60)
        return self.get_response(request)

    def _get_client_ip(self, request):
        xff = request.META.get("HTTP_X_FORWARDED_FOR")
        return xff.split(",")[0].strip() if xff else request.META.get("REMOTE_ADDR")
```

### Correlation ID middleware

```python
import uuid
import logging

logger = logging.getLogger(__name__)

class CorrelationIDMiddleware:
    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        correlation_id = request.META.get("HTTP_X_CORRELATION_ID", str(uuid.uuid4()))
        request.correlation_id = correlation_id

        response = self.get_response(request)
        response["X-Correlation-ID"] = correlation_id
        return response
```

### Async middleware (Django 5.x)

```python
class AsyncTimingMiddleware:
    async_capable = True
    sync_capable = False

    def __init__(self, get_response):
        self.get_response = get_response

    async def __call__(self, request):
        import time
        start = time.monotonic()
        response = await self.get_response(request)
        response["X-Duration"] = f"{time.monotonic() - start:.4f}"
        return response
```

### Middleware ordering (in MIDDLEWARE list)

```
SecurityMiddleware          # first — sets security headers
SessionMiddleware           # session before auth
CommonMiddleware            # URL rewriting
CsrfViewMiddleware          # CSRF before views
AuthenticationMiddleware    # auth before permission checks
YourCustomMiddleware        # after auth for access to request.user
MessageMiddleware           # messages
XFrameOptionsMiddleware     # last — response headers
```

---

## Signal Best Practices

### When to use signals vs. alternatives

| Use signals for | Don't use signals for |
|---|---|
| Cross-app decoupling | Intra-app business logic |
| Cache invalidation | Direct model operations |
| Audit logging | Cascading saves (use `save()`) |
| Notification triggers | Anything that needs error handling |
| Third-party app hooks | Flow control |

### Robust signal patterns

```python
# signals.py
from django.db.models.signals import post_save, pre_delete
from django.dispatch import receiver
from django.core.cache import cache

@receiver(post_save, sender="myapp.Product")
def invalidate_product_cache(sender, instance, created, **kwargs):
    cache.delete(f"product:{instance.pk}")
    cache.delete("product_list")

@receiver(pre_delete, sender="myapp.Product")
def log_product_deletion(sender, instance, **kwargs):
    import logging
    logging.getLogger("audit").info(
        f"Product deleted: {instance.pk} - {instance.name}"
    )
```

### Always connect in AppConfig.ready()

```python
# apps.py
class MyAppConfig(AppConfig):
    default_auto_field = "django.db.models.BigAutoField"
    name = "myapp"

    def ready(self):
        import myapp.signals  # noqa: F401
```

### Preventing infinite signal loops

```python
@receiver(post_save, sender=Product)
def update_search_index(sender, instance, **kwargs):
    if kwargs.get("raw"):        # skip during loaddata
        return
    if not kwargs.get("update_fields"):  # skip if triggered by our own update
        return
    # Safe to proceed
    SearchIndex.objects.update_or_create(
        content_type="product", object_id=instance.pk,
        defaults={"text": instance.name}
    )
```

### Custom signals

```python
from django.dispatch import Signal

order_completed = Signal()  # No providing_args in Django 5.x

# Emit
order_completed.send(sender=Order, order=order, user=request.user)

# Receive
@receiver(order_completed)
def handle_order_completed(sender, order, user, **kwargs):
    send_confirmation_email(order, user)
```

---

## Form Processing Patterns

### Multi-step form wizard

```python
from django.contrib.sessions.backends.db import SessionStore

class StepOneForm(forms.Form):
    name = forms.CharField(max_length=100)
    email = forms.EmailField()

class StepTwoForm(forms.Form):
    address = forms.CharField(widget=forms.Textarea)
    phone = forms.CharField(max_length=20)

def step_one(request):
    if request.method == "POST":
        form = StepOneForm(request.POST)
        if form.is_valid():
            request.session["step_one_data"] = form.cleaned_data
            return redirect("step_two")
    else:
        form = StepOneForm()
    return render(request, "step_one.html", {"form": form})

def step_two(request):
    step_one_data = request.session.get("step_one_data")
    if not step_one_data:
        return redirect("step_one")
    if request.method == "POST":
        form = StepTwoForm(request.POST)
        if form.is_valid():
            # Combine and save
            all_data = {**step_one_data, **form.cleaned_data}
            Customer.objects.create(**all_data)
            del request.session["step_one_data"]
            return redirect("success")
    else:
        form = StepTwoForm()
    return render(request, "step_two.html", {"form": form})
```

### Formsets with inline editing

```python
from django.forms import inlineformset_factory

OrderItemFormSet = inlineformset_factory(
    Order, OrderItem,
    fields=["product", "quantity", "price"],
    extra=1, can_delete=True,
)

def edit_order(request, pk):
    order = get_object_or_404(Order, pk=pk)
    if request.method == "POST":
        formset = OrderItemFormSet(request.POST, instance=order)
        if formset.is_valid():
            formset.save()
            return redirect("order_detail", pk=order.pk)
    else:
        formset = OrderItemFormSet(instance=order)
    return render(request, "edit_order.html", {"formset": formset, "order": order})
```

### Custom form field with validation

```python
class PhoneField(forms.CharField):
    def clean(self, value):
        value = super().clean(value)
        import re
        if value and not re.match(r"^\+?[\d\s\-()]{7,15}$", value):
            raise forms.ValidationError("Enter a valid phone number.")
        return value

class ContactForm(forms.Form):
    name = forms.CharField(max_length=100)
    phone = PhoneField(required=False)

    def clean(self):
        cleaned = super().clean()
        # Cross-field validation
        if not cleaned.get("phone") and not cleaned.get("email"):
            raise forms.ValidationError("Provide either phone or email.")
        return cleaned
```

---

## Admin Customization

### Advanced ModelAdmin

```python
from django.contrib import admin
from django.utils.html import format_html
from django.urls import reverse

@admin.register(Product)
class ProductAdmin(admin.ModelAdmin):
    list_display = ["name", "price", "category_link", "stock_status", "created_at"]
    list_filter = ["category", "status", ("created_at", admin.DateFieldListFilter)]
    search_fields = ["name", "description", "sku"]
    list_editable = ["price"]
    list_per_page = 50
    readonly_fields = ["created_at", "updated_at"]
    autocomplete_fields = ["category"]
    date_hierarchy = "created_at"
    prepopulated_fields = {"slug": ("name",)}
    fieldsets = [
        (None, {"fields": ["name", "slug", "description"]}),
        ("Pricing", {"fields": ["price", "discount_price"], "classes": ["collapse"]}),
        ("Metadata", {"fields": ["created_at", "updated_at"], "classes": ["collapse"]}),
    ]

    def category_link(self, obj):
        url = reverse("admin:myapp_category_change", args=[obj.category.pk])
        return format_html('<a href="{}">{}</a>', url, obj.category.name)
    category_link.short_description = "Category"

    def stock_status(self, obj):
        if obj.stock > 10:
            color = "green"
        elif obj.stock > 0:
            color = "orange"
        else:
            color = "red"
        return format_html('<span style="color: {};">{}</span>', color, obj.stock)
    stock_status.short_description = "Stock"

    def get_queryset(self, request):
        return super().get_queryset(request).select_related("category")
```

### Custom admin actions

```python
import csv
from django.http import HttpResponse

@admin.action(description="Export selected as CSV")
def export_as_csv(modeladmin, request, queryset):
    response = HttpResponse(content_type="text/csv")
    response["Content-Disposition"] = "attachment; filename=export.csv"
    writer = csv.writer(response)
    fields = [f.name for f in queryset.model._meta.fields]
    writer.writerow(fields)
    for obj in queryset:
        writer.writerow([getattr(obj, f) for f in fields])
    return response

@admin.register(Order)
class OrderAdmin(admin.ModelAdmin):
    actions = [export_as_csv]
```

### Custom admin views

```python
from django.urls import path
from django.template.response import TemplateResponse

@admin.register(Report)
class ReportAdmin(admin.ModelAdmin):
    def get_urls(self):
        urls = super().get_urls()
        custom = [
            path("dashboard/", self.admin_site.admin_view(self.dashboard_view),
                 name="myapp_report_dashboard"),
        ]
        return custom + urls

    def dashboard_view(self, request):
        context = {
            **self.admin_site.each_context(request),
            "stats": Order.objects.aggregate(
                total=models.Sum("amount"),
                count=models.Count("id"),
            ),
        }
        return TemplateResponse(request, "admin/dashboard.html", context)
```

---

## Custom Template Tags & Filters

### Setup

```
myapp/
  templatetags/
    __init__.py
    myapp_tags.py
```

### Custom filters

```python
# myapp/templatetags/myapp_tags.py
from django import template
from django.utils.safestring import mark_safe
import json

register = template.Library()

@register.filter
def currency(value, symbol="$"):
    """{{ product.price|currency:"€" }}"""
    try:
        return f"{symbol}{float(value):,.2f}"
    except (ValueError, TypeError):
        return value

@register.filter(is_safe=True)
def json_dump(value):
    """{{ data|json_dump }}"""
    return mark_safe(json.dumps(value))

@register.filter
def truncate_words_html(value, length=30):
    """Truncate preserving HTML tags."""
    from django.utils.text import Truncator
    return Truncator(value).words(length, html=True)
```

### Custom tags

```python
@register.simple_tag(takes_context=True)
def active_url(context, url_name):
    """{% active_url 'product_list' %} → 'active' or ''"""
    request = context["request"]
    from django.urls import reverse
    return "active" if request.path == reverse(url_name) else ""

@register.inclusion_tag("components/pagination.html", takes_context=True)
def render_pagination(context, page_obj):
    """{% render_pagination page_obj %}"""
    return {"page_obj": page_obj, "request": context["request"]}
```

### Usage in template

```django
{% load myapp_tags %}
<p>{{ product.price|currency:"$" }}</p>
<li class="{% active_url 'home' %}"><a href="{% url 'home' %}">Home</a></li>
{% render_pagination page_obj %}
```

---

## Context Processors

```python
# myapp/context_processors.py
from django.conf import settings

def site_settings(request):
    """Makes site config available in all templates."""
    return {
        "SITE_NAME": getattr(settings, "SITE_NAME", "My Site"),
        "SITE_VERSION": getattr(settings, "SITE_VERSION", "1.0"),
        "DEBUG": settings.DEBUG,
    }

def user_notifications(request):
    """Inject unread notification count."""
    if request.user.is_authenticated:
        count = request.user.notifications.filter(read=False).count()
        return {"unread_notifications": count}
    return {"unread_notifications": 0}
```

### Register in settings

```python
TEMPLATES = [{
    "BACKEND": "django.template.backends.django.DjangoTemplates",
    "OPTIONS": {
        "context_processors": [
            "django.template.context_processors.request",
            "django.contrib.auth.context_processors.auth",
            "django.contrib.messages.context_processors.messages",
            "myapp.context_processors.site_settings",
            "myapp.context_processors.user_notifications",
        ],
    },
}]
```

---

## File Storage Backends

### Custom S3-compatible storage (without django-storages)

```python
from django.core.files.storage import Storage
from django.core.files.base import ContentFile
import boto3
from botocore.exceptions import ClientError

class S3Storage(Storage):
    def __init__(self, bucket_name=None, region=None):
        self.bucket_name = bucket_name or settings.AWS_STORAGE_BUCKET_NAME
        self.region = region or settings.AWS_S3_REGION_NAME
        self.client = boto3.client("s3", region_name=self.region)

    def _save(self, name, content):
        self.client.upload_fileobj(content, self.bucket_name, name)
        return name

    def _open(self, name, mode="rb"):
        response = self.client.get_object(Bucket=self.bucket_name, Key=name)
        return ContentFile(response["Body"].read())

    def exists(self, name):
        try:
            self.client.head_object(Bucket=self.bucket_name, Key=name)
            return True
        except ClientError:
            return False

    def url(self, name):
        return f"https://{self.bucket_name}.s3.amazonaws.com/{name}"

    def delete(self, name):
        self.client.delete_object(Bucket=self.bucket_name, Key=name)
```

### Using django-storages (recommended)

```python
# settings.py
STORAGES = {
    "default": {
        "BACKEND": "storages.backends.s3boto3.S3Boto3Storage",
    },
    "staticfiles": {
        "BACKEND": "storages.backends.s3boto3.S3StaticStorage",
    },
}
AWS_STORAGE_BUCKET_NAME = "my-bucket"
AWS_S3_REGION_NAME = "us-east-1"
AWS_S3_CUSTOM_DOMAIN = f"{AWS_STORAGE_BUCKET_NAME}.s3.amazonaws.com"
```

---

## Custom Authentication Backends

### Email-based authentication

```python
from django.contrib.auth.backends import ModelBackend
from django.contrib.auth import get_user_model

User = get_user_model()

class EmailBackend(ModelBackend):
    def authenticate(self, request, username=None, password=None, **kwargs):
        email = kwargs.get("email", username)
        try:
            user = User.objects.get(email=email)
        except User.DoesNotExist:
            User().set_password(password)  # timing attack mitigation
            return None
        if user.check_password(password) and self.user_can_authenticate(user):
            return user
        return None
```

### Token/API key authentication

```python
class APIKeyBackend(ModelBackend):
    def authenticate(self, request, **kwargs):
        api_key = request.META.get("HTTP_X_API_KEY")
        if not api_key:
            return None
        try:
            key_obj = APIKey.objects.select_related("user").get(
                key=api_key, is_active=True
            )
            key_obj.last_used = timezone.now()
            key_obj.save(update_fields=["last_used"])
            return key_obj.user
        except APIKey.DoesNotExist:
            return None
```

### Register backends

```python
AUTHENTICATION_BACKENDS = [
    "myapp.auth_backends.EmailBackend",
    "myapp.auth_backends.APIKeyBackend",
    "django.contrib.auth.backends.ModelBackend",  # fallback
]
```

**Rule:** Always include `ModelBackend` as a fallback. Order matters — first match wins.
