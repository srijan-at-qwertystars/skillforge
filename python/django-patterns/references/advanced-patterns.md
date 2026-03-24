# Advanced Django Patterns

## Table of Contents

- [Custom Managers and QuerySets](#custom-managers-and-querysets)
- [Database Functions and Expressions](#database-functions-and-expressions)
- [Window Functions](#window-functions)
- [CTEs with Raw SQL](#ctes-with-raw-sql)
- [Multi-Database Routing](#multi-database-routing)
- [Custom Model Fields](#custom-model-fields)
- [Abstract Models vs Proxy Models](#abstract-models-vs-proxy-models)
- [GenericForeignKey and Content Types](#genericforeignkey-and-content-types)
- [Custom Template Tags and Filters](#custom-template-tags-and-filters)
- [Class-Based View Mixins](#class-based-view-mixins)
- [Custom Middleware Patterns](#custom-middleware-patterns)
- [Signal Best Practices and Anti-Patterns](#signal-best-practices-and-anti-patterns)
- [Django Channels for WebSockets](#django-channels-for-websockets)

---

## Custom Managers and QuerySets

### Chaining Custom QuerySets

The preferred pattern is to define methods on a custom `QuerySet` and expose it via `as_manager()` or a custom `Manager`. This allows method chaining:

```python
class ArticleQuerySet(models.QuerySet):
    def published(self):
        return self.filter(status="published", published_at__lte=timezone.now())

    def by_author(self, user):
        return self.filter(author=user)

    def with_comment_count(self):
        return self.annotate(comment_count=Count("comments"))

    def popular(self, min_comments=10):
        return self.with_comment_count().filter(comment_count__gte=min_comments)

    def recent(self, days=30):
        cutoff = timezone.now() - timedelta(days=days)
        return self.filter(published_at__gte=cutoff)


class ArticleManager(models.Manager):
    def get_queryset(self):
        return ArticleQuerySet(self.model, using=self._db)

    def published(self):
        return self.get_queryset().published()

    # Manager-only methods (not chainable from QuerySet)
    def create_draft(self, title, author, **kwargs):
        return self.create(title=title, author=author, status="draft", **kwargs)


class Article(models.Model):
    objects = ArticleManager()

    # Alternative: simpler approach when no manager-only methods needed
    # objects = ArticleQuerySet.as_manager()
```

Usage with chaining:

```python
Article.objects.published().by_author(user).popular().recent(days=7)
```

### Multiple Managers

```python
class Article(models.Model):
    objects = models.Manager()                    # Default — all objects
    published = PublishedManager()                # Only published
    # First manager defined becomes the default for admin, dumpdata, etc.
```

### Overriding `get_queryset` for Soft Deletes

```python
class SoftDeleteQuerySet(models.QuerySet):
    def delete(self):
        return self.update(deleted_at=timezone.now())

    def hard_delete(self):
        return super().delete()

    def alive(self):
        return self.filter(deleted_at__isnull=True)

    def dead(self):
        return self.filter(deleted_at__isnull=False)


class SoftDeleteManager(models.Manager):
    def get_queryset(self):
        return SoftDeleteQuerySet(self.model, using=self._db).alive()


class SoftDeleteModel(models.Model):
    deleted_at = models.DateTimeField(null=True, blank=True, db_index=True)

    objects = SoftDeleteManager()
    all_objects = SoftDeleteQuerySet.as_manager()  # includes soft-deleted

    def delete(self, using=None, keep_parents=False):
        self.deleted_at = timezone.now()
        self.save(update_fields=["deleted_at"])

    def hard_delete(self):
        super().delete()

    class Meta:
        abstract = True
```

---

## Database Functions and Expressions

### Built-in Database Functions

```python
from django.db.models.functions import (
    Coalesce, Greatest, Least, NullIf,
    Lower, Upper, Trim, Length, Substr, Concat, Replace,
    ExtractYear, ExtractMonth, TruncDate, TruncMonth,
    Cast, JSONObject,
)
from django.db.models import Value, CharField, IntegerField

# Coalesce — first non-null value
Product.objects.annotate(
    display_name=Coalesce("marketing_name", "name", output_field=CharField())
)

# String operations
User.objects.annotate(
    full_name=Concat("first_name", Value(" "), "last_name"),
    email_domain=Substr("email", models.F("email").find("@") + 1),
    name_length=Length("username"),
)

# Date extraction
Order.objects.annotate(
    order_year=ExtractYear("created_at"),
    order_month=TruncMonth("created_at"),
).values("order_month").annotate(total=Sum("amount"))

# JSONObject (Django 4.2+, PostgreSQL)
Product.objects.annotate(
    summary=JSONObject(name="name", price="price", status="status")
)
```

### Custom Database Functions

```python
from django.db.models import Func

class ArrayLength(Func):
    function = "array_length"
    template = "%(function)s(%(expressions)s, 1)"
    output_field = IntegerField()

class DateDiff(Func):
    function = "DATE_PART"
    template = "%(function)s('day', %(expressions)s)"
    output_field = IntegerField()

    def __init__(self, end, start, **extra):
        super().__init__(end - start, **extra)

# PostgreSQL-specific: full-text search
class SearchRank(Func):
    function = "ts_rank"
    output_field = models.FloatField()

# Usage
from django.contrib.postgres.search import SearchVector, SearchQuery, SearchRank

Product.objects.annotate(
    search=SearchVector("name", "description", config="english"),
    rank=SearchRank(SearchVector("name", "description"), SearchQuery("organic coffee")),
).filter(search=SearchQuery("organic coffee")).order_by("-rank")
```

### Conditional Expressions

```python
from django.db.models import Case, When, Value, IntegerField, Sum

# Conditional annotation
Order.objects.annotate(
    priority=Case(
        When(total__gte=1000, then=Value(1)),
        When(total__gte=500, then=Value(2)),
        When(total__gte=100, then=Value(3)),
        default=Value(4),
        output_field=IntegerField(),
    )
)

# Conditional aggregation
User.objects.aggregate(
    active_count=Count("id", filter=Q(is_active=True)),
    inactive_count=Count("id", filter=Q(is_active=False)),
    premium_revenue=Sum("orders__total", filter=Q(orders__is_premium=True)),
)
```

---

## Window Functions

Window functions perform calculations across a set of rows related to the current row without collapsing them.

```python
from django.db.models import Window, F, RowRange
from django.db.models.functions import Rank, DenseRank, RowNumber, Lag, Lead, NthValue

# Rank within a partition
Employee.objects.annotate(
    department_rank=Window(
        expression=Rank(),
        partition_by=F("department"),
        order_by=F("salary").desc(),
    )
)

# Running total
Transaction.objects.annotate(
    running_total=Window(
        expression=Sum("amount"),
        partition_by=F("account_id"),
        order_by=F("created_at").asc(),
        frame=RowRange(start=None, end=0),  # unbounded preceding to current row
    )
)

# Lag/Lead — access previous/next row values
SalesData.objects.annotate(
    prev_month_sales=Window(
        expression=Lag("total_sales", offset=1),
        partition_by=F("region"),
        order_by=F("month").asc(),
    ),
    next_month_sales=Window(
        expression=Lead("total_sales", offset=1),
        partition_by=F("region"),
        order_by=F("month").asc(),
    ),
    month_over_month=F("total_sales") - Window(
        expression=Lag("total_sales", offset=1),
        partition_by=F("region"),
        order_by=F("month").asc(),
    ),
)

# Percentile ranking
Student.objects.annotate(
    percentile=Window(
        expression=PercentRank(),
        order_by=F("score").asc(),
    )
)
```

---

## CTEs with Raw SQL

Django ORM does not natively support CTEs (`WITH` clauses). Use `.raw()` or the `django-cte` package.

### Using `.raw()`

```python
def get_category_tree(root_id):
    """Recursive CTE for hierarchical data (PostgreSQL, SQLite 3.8.3+)."""
    return Category.objects.raw("""
        WITH RECURSIVE category_tree AS (
            SELECT id, name, parent_id, 0 AS depth
            FROM myapp_category
            WHERE id = %s

            UNION ALL

            SELECT c.id, c.name, c.parent_id, ct.depth + 1
            FROM myapp_category c
            INNER JOIN category_tree ct ON c.parent_id = ct.id
        )
        SELECT * FROM category_tree
        ORDER BY depth, name
    """, [root_id])
```

### Using `django-cte` Package

```python
# pip install django-cte
from django_cte import With

cte = With(
    Order.objects.values("customer_id").annotate(
        total_spent=Sum("amount"),
        order_count=Count("id"),
    )
)

top_customers = (
    cte.join(Customer, id=cte.col.customer_id)
    .with_cte(cte)
    .annotate(
        total_spent=cte.col.total_spent,
        order_count=cte.col.order_count,
    )
    .filter(total_spent__gte=1000)
    .order_by("-total_spent")
)
```

### Raw SQL with Named Columns

```python
# When raw() result doesn't map cleanly to a model
from django.db import connection

def monthly_revenue_report(year):
    with connection.cursor() as cursor:
        cursor.execute("""
            WITH monthly AS (
                SELECT
                    DATE_TRUNC('month', created_at) AS month,
                    SUM(total) AS revenue,
                    COUNT(*) AS order_count
                FROM orders_order
                WHERE EXTRACT(YEAR FROM created_at) = %s
                GROUP BY DATE_TRUNC('month', created_at)
            )
            SELECT
                month,
                revenue,
                order_count,
                revenue - LAG(revenue) OVER (ORDER BY month) AS mom_change
            FROM monthly
            ORDER BY month
        """, [year])
        columns = [col[0] for col in cursor.description]
        return [dict(zip(columns, row)) for row in cursor.fetchall()]
```

---

## Multi-Database Routing

### Configuration

```python
# settings.py
DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.postgresql",
        "NAME": "primary_db",
    },
    "replica": {
        "ENGINE": "django.db.backends.postgresql",
        "NAME": "replica_db",
        "TEST": {"MIRROR": "default"},  # Use default in tests
    },
    "analytics": {
        "ENGINE": "django.db.backends.postgresql",
        "NAME": "analytics_db",
    },
}

DATABASE_ROUTERS = ["config.routers.PrimaryReplicaRouter", "config.routers.AnalyticsRouter"]
```

### Router Implementation

```python
# config/routers.py
import random

class PrimaryReplicaRouter:
    """Route reads to replica, writes to primary."""

    def db_for_read(self, model, **hints):
        if model._meta.app_label == "analytics":
            return None  # Let another router handle it
        return "replica"

    def db_for_write(self, model, **hints):
        if model._meta.app_label == "analytics":
            return None
        return "default"

    def allow_relation(self, obj1, obj2, **hints):
        db_set = {"default", "replica"}
        if obj1._state.db in db_set and obj2._state.db in db_set:
            return True
        return None

    def allow_migrate(self, db, app_label, model_name=None, **hints):
        if app_label == "analytics":
            return None
        return db == "default"


class AnalyticsRouter:
    """Route analytics models to the analytics database."""
    route_app_labels = {"analytics"}

    def db_for_read(self, model, **hints):
        if model._meta.app_label in self.route_app_labels:
            return "analytics"
        return None

    def db_for_write(self, model, **hints):
        if model._meta.app_label in self.route_app_labels:
            return "analytics"
        return None

    def allow_migrate(self, db, app_label, **hints):
        if app_label in self.route_app_labels:
            return db == "analytics"
        return None
```

### Forcing a Specific Database

```python
# Override router for a specific query
User.objects.using("default").get(pk=user_id)  # Force read from primary

# Atomic transactions on a specific database
from django.db import transaction

with transaction.atomic(using="default"):
    order = Order.objects.create(...)
    OrderItem.objects.bulk_create(items)
```

---

## Custom Model Fields

### Encrypted Field Example

```python
import base64
from cryptography.fernet import Fernet
from django.conf import settings
from django.db import models

class EncryptedTextField(models.TextField):
    """Transparently encrypts/decrypts text in the database."""

    def __init__(self, *args, **kwargs):
        kwargs["max_length"] = kwargs.get("max_length", 1000)
        super().__init__(*args, **kwargs)

    def _get_fernet(self):
        return Fernet(settings.FIELD_ENCRYPTION_KEY)

    def get_prep_value(self, value):
        if value is None:
            return value
        f = self._get_fernet()
        return base64.b64encode(f.encrypt(value.encode())).decode()

    def from_db_value(self, value, expression, connection):
        if value is None:
            return value
        f = self._get_fernet()
        return f.decrypt(base64.b64decode(value.encode())).decode()

    def deconstruct(self):
        name, path, args, kwargs = super().deconstruct()
        return name, path, args, kwargs
```

### Comma-Separated List Field

```python
class CommaSeparatedField(models.TextField):
    """Store a list as comma-separated values."""

    def from_db_value(self, value, expression, connection):
        if not value:
            return []
        return [item.strip() for item in value.split(",")]

    def get_prep_value(self, value):
        if isinstance(value, list):
            return ",".join(str(v) for v in value)
        return value

    def to_python(self, value):
        if isinstance(value, list):
            return value
        if not value:
            return []
        return [item.strip() for item in value.split(",")]
```

---

## Abstract Models vs Proxy Models

### Abstract Models — Shared Fields and Behavior

```python
class TimeStampedModel(models.Model):
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        abstract = True  # No database table created


class Publishable(models.Model):
    published_at = models.DateTimeField(null=True, blank=True)
    is_published = models.BooleanField(default=False)

    def publish(self):
        self.is_published = True
        self.published_at = timezone.now()
        self.save(update_fields=["is_published", "published_at"])

    class Meta:
        abstract = True


# Multiple inheritance from abstract models
class Article(TimeStampedModel, Publishable):
    title = models.CharField(max_length=200)
    body = models.TextField()
    # Gets: created_at, updated_at, published_at, is_published, publish()
    # Single table: myapp_article
```

### Proxy Models — Same Table, Different Behavior

```python
class Order(models.Model):
    STATUS_CHOICES = [("pending", "Pending"), ("shipped", "Shipped"), ("delivered", "Delivered")]
    status = models.CharField(max_length=20, choices=STATUS_CHOICES)
    total = models.DecimalField(max_digits=10, decimal_places=2)


class PendingOrderManager(models.Manager):
    def get_queryset(self):
        return super().get_queryset().filter(status="pending")


class PendingOrder(Order):
    """Proxy model: same table, filtered queryset, custom methods."""
    objects = PendingOrderManager()

    def approve(self):
        self.status = "shipped"
        self.save(update_fields=["status"])

    class Meta:
        proxy = True
        ordering = ["-created_at"]
```

**When to use which:**

| Feature | Abstract Model | Proxy Model |
|---------|---------------|-------------|
| Creates DB table | No | No (uses parent's) |
| Adds fields | Yes | No |
| Custom methods | Yes | Yes |
| Custom manager | Yes | Yes |
| Different Meta | Yes | Yes |
| Separate admin | N/A | Yes |
| `isinstance` check | No | Yes (is instance of parent) |

---

## GenericForeignKey and Content Types

### Setting Up Generic Relations

```python
from django.contrib.contenttypes.fields import GenericForeignKey, GenericRelation
from django.contrib.contenttypes.models import ContentType

class Comment(models.Model):
    """A comment that can be attached to any model."""
    content_type = models.ForeignKey(ContentType, on_delete=models.CASCADE)
    object_id = models.PositiveIntegerField()
    content_object = GenericForeignKey("content_type", "object_id")

    text = models.TextField()
    author = models.ForeignKey(User, on_delete=models.CASCADE)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        indexes = [
            models.Index(fields=["content_type", "object_id"]),
        ]


class Article(models.Model):
    title = models.CharField(max_length=200)
    comments = GenericRelation(Comment)  # Reverse relation


class Product(models.Model):
    name = models.CharField(max_length=200)
    comments = GenericRelation(Comment)
```

### Querying Generic Relations

```python
# Add comment to any model
article = Article.objects.get(pk=1)
Comment.objects.create(content_object=article, text="Great article!", author=user)

# Reverse query via GenericRelation
article.comments.all()
article.comments.filter(author=user)

# Forward query
comment = Comment.objects.select_related("content_type").first()
obj = comment.content_object  # Fetches the related object (extra query)

# Prefetch generic relations (avoid N+1)
from django.contrib.contenttypes.prefetch import GenericPrefetch

comments = Comment.objects.prefetch_related(
    GenericPrefetch("content_object", [Article.objects.all(), Product.objects.all()])
)
```

### Activity Log with Content Types

```python
class ActivityLog(models.Model):
    class Action(models.TextChoices):
        CREATE = "create"
        UPDATE = "update"
        DELETE = "delete"

    user = models.ForeignKey(User, on_delete=models.SET_NULL, null=True)
    action = models.CharField(max_length=10, choices=Action.choices)
    content_type = models.ForeignKey(ContentType, on_delete=models.CASCADE)
    object_id = models.PositiveIntegerField()
    content_object = GenericForeignKey()
    changes = models.JSONField(default=dict)
    timestamp = models.DateTimeField(auto_now_add=True)

    @classmethod
    def log(cls, user, action, instance, changes=None):
        return cls.objects.create(
            user=user,
            action=action,
            content_object=instance,
            changes=changes or {},
        )
```

---

## Custom Template Tags and Filters

### Directory Structure

```
apps/core/
├── templatetags/
│   ├── __init__.py
│   └── core_tags.py
```

### Custom Filters

```python
# apps/core/templatetags/core_tags.py
from django import template
from django.utils.safestring import mark_safe
import json

register = template.Library()

@register.filter
def currency(value, symbol="$"):
    """Usage: {{ price|currency }} or {{ price|currency:"€" }}"""
    try:
        return f"{symbol}{float(value):,.2f}"
    except (ValueError, TypeError):
        return value

@register.filter
def truncate_middle(value, length=30):
    """Truncate in the middle: 'longfilename.txt' → 'longfi...me.txt'"""
    value = str(value)
    if len(value) <= length:
        return value
    keep = (length - 3) // 2
    return f"{value[:keep]}...{value[-keep:]}"

@register.filter(is_safe=True)
def json_script_data(value):
    """Serialize to JSON for use in <script> tags."""
    return mark_safe(json.dumps(value))
```

### Custom Tags

```python
@register.simple_tag(takes_context=True)
def query_string(context, **kwargs):
    """Modify query string: {% query_string page=2 sort="name" %}"""
    request = context["request"]
    params = request.GET.copy()
    for key, value in kwargs.items():
        if value is None:
            params.pop(key, None)
        else:
            params[key] = value
    return f"?{params.urlencode()}" if params else ""

@register.inclusion_tag("components/pagination.html", takes_context=True)
def pagination(context, page_obj, **kwargs):
    """Reusable pagination component: {% pagination page_obj %}"""
    return {
        "page_obj": page_obj,
        "request": context["request"],
        "query_params": context["request"].GET.urlencode(),
    }

# Block-level tag using @register.tag and a Node
class CacheNode(template.Node):
    """Custom cache tag with versioning."""
    def __init__(self, nodelist, expire_time, fragment_name, vary_on):
        self.nodelist = nodelist
        self.expire_time = expire_time
        self.fragment_name = fragment_name
        self.vary_on = vary_on

    def render(self, context):
        from django.core.cache import cache
        vary_key = ":".join(str(v.resolve(context)) for v in self.vary_on)
        cache_key = f"template.cache.{self.fragment_name}.{vary_key}"
        value = cache.get(cache_key)
        if value is None:
            value = self.nodelist.render(context)
            cache.set(cache_key, value, self.expire_time)
        return value
```

---

## Class-Based View Mixins

### Common Mixin Patterns

```python
from django.contrib.auth.mixins import LoginRequiredMixin, UserPassesTestMixin
from django.http import JsonResponse

class AjaxResponseMixin:
    """Return JSON for AJAX requests, HTML otherwise."""
    def dispatch(self, request, *args, **kwargs):
        self.is_ajax = request.headers.get("X-Requested-With") == "XMLHttpRequest"
        return super().dispatch(request, *args, **kwargs)

    def render_to_response(self, context, **kwargs):
        if self.is_ajax:
            return JsonResponse(self.get_ajax_data(context))
        return super().render_to_response(context, **kwargs)

    def get_ajax_data(self, context):
        return {"results": list(context["object_list"].values())}


class OwnershipMixin:
    """Filter queryset to only objects owned by the current user."""
    owner_field = "owner"

    def get_queryset(self):
        qs = super().get_queryset()
        return qs.filter(**{self.owner_field: self.request.user})


class StaffRequiredMixin(UserPassesTestMixin):
    """Restrict view to staff users."""
    def test_func(self):
        return self.request.user.is_staff


class FormMessageMixin:
    """Add success/error messages to form views."""
    success_message = ""
    error_message = "Please correct the errors below."

    def form_valid(self, form):
        from django.contrib import messages
        if self.success_message:
            messages.success(self.request, self.success_message)
        return super().form_valid(form)

    def form_invalid(self, form):
        from django.contrib import messages
        messages.error(self.request, self.error_message)
        return super().form_invalid(form)


class MultipleFormsMixin:
    """Handle multiple forms in a single view."""
    form_classes = {}

    def get_forms(self, form_classes=None):
        if form_classes is None:
            form_classes = self.form_classes
        return {
            key: cls(**self.get_form_kwargs())
            for key, cls in form_classes.items()
        }

    def get_context_data(self, **kwargs):
        context = super().get_context_data(**kwargs)
        context["forms"] = self.get_forms()
        return context
```

### MRO (Method Resolution Order) Tips

```python
# Mixin order matters: left to right, first match wins
# Put mixins BEFORE the base view class
class ProductCreateView(
    LoginRequiredMixin,       # 1st: check auth
    StaffRequiredMixin,       # 2nd: check permission
    FormMessageMixin,         # 3rd: add messages
    CreateView,               # Last: base view
):
    model = Product
    form_class = ProductForm
    success_message = "Product created successfully."
```

---

## Custom Middleware Patterns

### Rate Limiting Middleware

```python
from django.core.cache import cache
from django.http import JsonResponse
import time

class RateLimitMiddleware:
    """Simple rate limiting per IP address."""

    def __init__(self, get_response):
        self.get_response = get_response
        self.rate_limit = 100          # requests
        self.rate_window = 60          # seconds

    def __call__(self, request):
        if request.path.startswith("/api/"):
            ip = self._get_client_ip(request)
            cache_key = f"rate_limit:{ip}"
            requests_made = cache.get(cache_key, 0)

            if requests_made >= self.rate_limit:
                return JsonResponse(
                    {"error": "Rate limit exceeded"},
                    status=429,
                    headers={"Retry-After": str(self.rate_window)},
                )
            cache.set(cache_key, requests_made + 1, self.rate_window)

        return self.get_response(request)

    def _get_client_ip(self, request):
        xff = request.META.get("HTTP_X_FORWARDED_FOR")
        return xff.split(",")[0].strip() if xff else request.META.get("REMOTE_ADDR")
```

### Request Context Middleware (Thread-Local Alternative)

```python
import contextvars
import uuid

request_id_var = contextvars.ContextVar("request_id", default=None)
current_user_var = contextvars.ContextVar("current_user", default=None)

class RequestContextMiddleware:
    """Set context variables for access anywhere in the request cycle."""

    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        request_id = request.headers.get("X-Request-ID", str(uuid.uuid4()))
        request.request_id = request_id

        token_rid = request_id_var.set(request_id)
        token_user = current_user_var.set(
            request.user if hasattr(request, "user") else None
        )

        response = self.get_response(request)
        response["X-Request-ID"] = request_id

        request_id_var.reset(token_rid)
        current_user_var.reset(token_user)
        return response
```

### Exception Handling Middleware

```python
import logging
import traceback
from django.http import JsonResponse

logger = logging.getLogger(__name__)

class APIExceptionMiddleware:
    """Catch unhandled exceptions in API views and return JSON errors."""

    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        return self.get_response(request)

    def process_exception(self, request, exception):
        if not request.path.startswith("/api/"):
            return None

        logger.exception(
            "Unhandled exception in %s %s", request.method, request.path,
            extra={"request_id": getattr(request, "request_id", "unknown")},
        )

        status = getattr(exception, "status_code", 500)
        return JsonResponse(
            {
                "error": str(exception) if status < 500 else "Internal server error",
                "type": type(exception).__name__,
            },
            status=status,
        )
```

---

## Signal Best Practices and Anti-Patterns

### Best Practices

```python
# 1. Keep signal handlers small — delegate to service functions
@receiver(post_save, sender=Order)
def on_order_created(sender, instance, created, **kwargs):
    if created:
        OrderService.send_confirmation_email(instance)
        OrderService.notify_warehouse(instance)

# 2. Always accept **kwargs for forward compatibility
@receiver(post_save, sender=User)
def on_user_save(sender, instance, created, **kwargs):  # ← **kwargs required
    pass

# 3. Use dispatch_uid to prevent duplicate registrations
post_save.connect(on_user_save, sender=User, dispatch_uid="create_user_profile")

# 4. Register signals in AppConfig.ready()
class UsersConfig(AppConfig):
    name = "apps.users"
    def ready(self):
        import apps.users.signals  # noqa: F401
```

### Anti-Patterns to Avoid

```python
# ❌ Heavy computation in signal handlers — blocks the request
@receiver(post_save, sender=Order)
def bad_handler(sender, instance, **kwargs):
    generate_pdf_invoice(instance)      # Slow!
    send_email(instance)                # Slow!
    update_analytics(instance)          # Slow!

# ✅ Offload to Celery tasks
@receiver(post_save, sender=Order)
def good_handler(sender, instance, created, **kwargs):
    if created:
        process_new_order.delay(instance.pk)

# ❌ Signal handler that triggers another signal (cascading signals)
@receiver(post_save, sender=Order)
def update_customer_stats(sender, instance, **kwargs):
    instance.customer.order_count = instance.customer.orders.count()
    instance.customer.save()  # Triggers Customer post_save!

# ✅ Use update() to avoid triggering signals
@receiver(post_save, sender=Order)
def update_customer_stats(sender, instance, created, **kwargs):
    if created:
        Customer.objects.filter(pk=instance.customer_id).update(
            order_count=F("order_count") + 1
        )

# ❌ Using signals for same-app logic (tight coupling disguised as decoupling)
# ✅ Instead, call service functions directly in your view/service
```

### When to Use Signals vs Direct Calls

| Use Signals | Use Direct Calls |
|------------|-----------------|
| Cross-app side effects | Same-app logic |
| Third-party app integration | Business logic flow |
| Audit logging | Data validation |
| Cache invalidation | Creating related objects |

---

## Django Channels for WebSockets

### Installation and Setup

```bash
pip install channels channels-redis
```

```python
# settings.py
INSTALLED_APPS = [
    "daphne",     # Must be before django.contrib.staticfiles
    ...,
    "channels",
]

ASGI_APPLICATION = "config.asgi.application"

CHANNEL_LAYERS = {
    "default": {
        "BACKEND": "channels_redis.core.RedisChannelLayer",
        "CONFIG": {"hosts": [("redis", 6379)]},
    },
}
```

### ASGI Configuration

```python
# config/asgi.py
import os
from django.core.asgi import get_asgi_application
from channels.routing import ProtocolTypeRouter, URLRouter
from channels.auth import AuthMiddlewareStack
from channels.security.websocket import AllowedHostsOriginValidator

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "config.settings.production")
django_asgi = get_asgi_application()

from apps.chat import routing  # Import after django setup

application = ProtocolTypeRouter({
    "http": django_asgi,
    "websocket": AllowedHostsOriginValidator(
        AuthMiddlewareStack(
            URLRouter(routing.websocket_urlpatterns)
        )
    ),
})
```

### WebSocket Consumer

```python
# apps/chat/consumers.py
import json
from channels.generic.websocket import AsyncJsonWebsocketConsumer
from channels.db import database_sync_to_async

class ChatConsumer(AsyncJsonWebsocketConsumer):
    async def connect(self):
        self.room_name = self.scope["url_route"]["kwargs"]["room_name"]
        self.room_group_name = f"chat_{self.room_name}"
        self.user = self.scope["user"]

        if self.user.is_anonymous:
            await self.close()
            return

        await self.channel_layer.group_add(self.room_group_name, self.channel_name)
        await self.accept()
        await self.send_json({"type": "connection_established", "room": self.room_name})

    async def disconnect(self, close_code):
        await self.channel_layer.group_discard(self.room_group_name, self.channel_name)

    async def receive_json(self, content):
        message = content.get("message", "").strip()
        if not message:
            return

        await self.save_message(message)

        await self.channel_layer.group_send(
            self.room_group_name,
            {
                "type": "chat.message",
                "message": message,
                "username": self.user.username,
            },
        )

    async def chat_message(self, event):
        """Handler for chat.message type events."""
        await self.send_json({
            "type": "chat_message",
            "message": event["message"],
            "username": event["username"],
        })

    @database_sync_to_async
    def save_message(self, message):
        from apps.chat.models import Message
        Message.objects.create(room_name=self.room_name, user=self.user, text=message)
```

### WebSocket Routing

```python
# apps/chat/routing.py
from django.urls import re_path
from . import consumers

websocket_urlpatterns = [
    re_path(r"ws/chat/(?P<room_name>\w+)/$", consumers.ChatConsumer.as_asgi()),
]
```

### JWT Authentication for WebSockets

```python
from channels.middleware import BaseMiddleware
from channels.db import database_sync_to_async
from rest_framework_simplejwt.tokens import AccessToken
from django.contrib.auth import get_user_model

User = get_user_model()

class JWTAuthMiddleware(BaseMiddleware):
    async def __call__(self, scope, receive, send):
        query_string = scope.get("query_string", b"").decode()
        params = dict(p.split("=", 1) for p in query_string.split("&") if "=" in p)
        token = params.get("token")

        if token:
            scope["user"] = await self.get_user(token)
        return await super().__call__(scope, receive, send)

    @database_sync_to_async
    def get_user(self, token_str):
        try:
            token = AccessToken(token_str)
            return User.objects.get(pk=token["user_id"])
        except Exception:
            from django.contrib.auth.models import AnonymousUser
            return AnonymousUser()
```
