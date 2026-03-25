# Django Troubleshooting Guide

> Diagnosis-first troubleshooting for common Django production issues.
> Each section: symptoms → root cause → fix → prevention.

## Table of Contents

- [N+1 Queries](#n1-queries)
- [Slow Migrations](#slow-migrations)
- [Circular Imports](#circular-imports)
- [Migration Conflicts](#migration-conflicts)
- [Memory Leaks](#memory-leaks)
- [CSRF Issues](#csrf-issues)
- [Static Files in Production](#static-files-in-production)
- [Database Connection Pooling](#database-connection-pooling)
- [Celery Integration Issues](#celery-integration-issues)
- [Timezone Pitfalls](#timezone-pitfalls)

---

## N+1 Queries

### Symptoms
- Pages load slowly with many database queries (100+ for a list view)
- django-debug-toolbar shows duplicate queries with different IDs

### Detection

```python
# Install django-debug-toolbar
# pip install django-debug-toolbar

# settings.py (development only)
INSTALLED_APPS += ["debug_toolbar"]
MIDDLEWARE.insert(0, "debug_toolbar.middleware.DebugToolbarMiddleware")
INTERNAL_IPS = ["127.0.0.1"]

# urls.py
if settings.DEBUG:
    import debug_toolbar
    urlpatterns += [path("__debug__/", include(debug_toolbar.urls))]
```

### Programmatic detection with nplusone

```python
# pip install nplusone
INSTALLED_APPS += ["nplusone.ext.django"]
MIDDLEWARE.insert(0, "nplusone.ext.django.NPlusOneMiddleware")
NPLUSONE_RAISE = True  # raise exception on N+1 in tests
NPLUSONE_LOG_LEVEL = logging.WARNING
```

### Fixes

```python
# BEFORE (N+1): Each book.author triggers a separate query
books = Book.objects.all()
for book in books:
    print(book.author.name)     # N+1!
    print(book.publisher.name)  # N+1 again!

# AFTER: FK/OneToOne — use select_related (SQL JOIN)
books = Book.objects.select_related("author", "publisher").all()

# AFTER: M2M/reverse FK — use prefetch_related (2 queries total)
authors = Author.objects.prefetch_related("books")

# AFTER: Filtered prefetch
from django.db.models import Prefetch
authors = Author.objects.prefetch_related(
    Prefetch("books", queryset=Book.objects.filter(published=True), to_attr="pub_books")
)

# Admin N+1 — override get_queryset
class BookAdmin(admin.ModelAdmin):
    list_display = ["title", "author", "publisher"]
    list_select_related = ["author", "publisher"]
```

### Prevention
- Always check the SQL panel in debug-toolbar after adding list views
- Use `assertNumQueries()` in tests
- Add `list_select_related` in admin classes

---

## Slow Migrations

### Symptoms
- `migrate` hangs for minutes on production tables
- Database locks cause request timeouts during deployment

### Root causes
- Adding NOT NULL column without default to large table
- Creating index on large table (blocks writes)
- Data migration iterating row-by-row

### Fixes

```python
# 1. Add nullable column first, backfill, then add NOT NULL
# Step 1: nullable
migrations.AddField("myapp", "Product", "sku",
    field=models.CharField(max_length=50, null=True))

# Step 2: data migration to backfill
def backfill_sku(apps, schema_editor):
    Product = apps.get_model("myapp", "Product")
    Product.objects.filter(sku__isnull=True).update(sku=Concat(Value("SKU-"), Cast("id", CharField())))

# Step 3: alter to NOT NULL
migrations.AlterField("myapp", "Product", "sku",
    field=models.CharField(max_length=50))

# 2. Create index concurrently (PostgreSQL)
from django.contrib.postgres.operations import AddIndexConcurrently

class Migration(migrations.Migration):
    atomic = False  # required for concurrent index
    operations = [
        AddIndexConcurrently(
            model_name="product",
            index=models.Index(fields=["sku"], name="product_sku_idx"),
        ),
    ]

# 3. Batch data migrations
def batch_update(apps, schema_editor):
    Product = apps.get_model("myapp", "Product")
    batch_size = 1000
    while True:
        batch = list(Product.objects.filter(needs_update=True)[:batch_size])
        if not batch:
            break
        for p in batch:
            p.computed_field = compute(p)
        Product.objects.bulk_update(batch, ["computed_field"])
```

### Prevention
- Run `python manage.py sqlmigrate app_name 0001` to review SQL before applying
- Use `--plan` flag: `python manage.py migrate --plan`
- Never deploy schema changes and data migrations in the same release
- Use `AddIndexConcurrently` for large PostgreSQL tables

---

## Circular Imports

### Symptoms
- `ImportError: cannot import name 'X' from partially initialized module`
- `AppRegistryNotReady` exception at startup

### Root causes
- Model A imports Model B, Model B imports Model A
- Signals importing models at module level
- Forms/serializers importing views or vice versa

### Fixes

```python
# 1. Use string references for ForeignKey
class Order(models.Model):
    product = models.ForeignKey("products.Product", on_delete=models.CASCADE)
    # NOT: from products.models import Product

# 2. Lazy imports inside functions
def get_user_orders(user):
    from orders.models import Order  # import here, not at top
    return Order.objects.filter(user=user)

# 3. Use apps.get_model() in data migrations
def forwards(apps, schema_editor):
    Product = apps.get_model("products", "Product")
    Order = apps.get_model("orders", "Order")

# 4. Move shared logic to a utils module
# BAD: models.py imports from views.py
# GOOD: both import from utils.py

# 5. Import signals in AppConfig.ready()
class OrdersConfig(AppConfig):
    def ready(self):
        from . import signals  # noqa: F401
```

### Prevention
- Never import models at module level across apps
- Use string references for all cross-app ForeignKey/M2M fields
- Keep `models.py` free of business logic imports

---

## Migration Conflicts

### Symptoms
- `CommandError: Conflicting migrations detected`
- Multiple developers created migrations from the same base

### Fixes

```bash
# Auto-merge (works for non-conflicting changes)
python manage.py makemigrations --merge

# Manual resolution
# 1. Identify conflicting migrations
python manage.py showmigrations app_name

# 2. If both add fields, merge is safe — Django handles it
# 3. If both modify the same field, manually edit the merged migration

# 4. Nuclear option (dev only): squash and reset
python manage.py squashmigrations app_name 0001 0010
```

### Prevention
- Coordinate migration creation in team (one at a time)
- Run `makemigrations --check` in CI to detect missing migrations
- Squash migrations periodically: `python manage.py squashmigrations app 0001 0020`

---

## Memory Leaks

### Symptoms
- Worker memory grows continuously, eventually OOM-killed
- Gunicorn workers restart frequently

### Common causes and fixes

```python
# 1. Unbounded querysets — use iterator()
# BAD: loads all objects into memory
for product in Product.objects.all():
    process(product)

# GOOD: streams in chunks
for product in Product.objects.iterator(chunk_size=2000):
    process(product)

# 2. DEBUG = True in production — logs all queries!
# ALWAYS ensure DEBUG = False in production

# 3. Large file uploads without cleanup
from django.core.files.uploadhandler import TemporaryFileUploadHandler
FILE_UPLOAD_HANDLERS = [
    "django.core.files.uploadhandler.TemporaryFileUploadHandler",
]
FILE_UPLOAD_MAX_MEMORY_SIZE = 2621440  # 2.5 MB

# 4. Gunicorn max-requests to recycle workers
# gunicorn --max-requests 1000 --max-requests-jitter 50

# 5. Cached properties on long-lived objects
# Use @cached_property carefully — clear when no longer needed
```

### Diagnosis tools

```bash
# Memory profiling
pip install memory-profiler objgraph

# In code
from memory_profiler import profile

@profile
def memory_heavy_function():
    # ... code to profile ...
    pass

# Gunicorn with memory monitoring
gunicorn app.wsgi --workers 4 --max-requests 1000 --max-requests-jitter 50
```

---

## CSRF Issues

### Symptoms
- `403 Forbidden: CSRF verification failed`
- AJAX POST requests fail
- Form submissions fail after deploy

### Diagnosis and fixes

```python
# 1. Missing {% csrf_token %} in form
# ALWAYS include in POST forms:
# <form method="POST">{% csrf_token %} ... </form>

# 2. AJAX requests — pass CSRF token in header
"""
// JavaScript
function getCookie(name) {
    let value = `; ${document.cookie}`;
    let parts = value.split(`; ${name}=`);
    if (parts.length === 2) return parts.pop().split(';').shift();
}

fetch('/api/endpoint/', {
    method: 'POST',
    headers: {
        'X-CSRFToken': getCookie('csrftoken'),
        'Content-Type': 'application/json',
    },
    body: JSON.stringify(data),
});
"""

# 3. CSRF_TRUSTED_ORIGINS (Django 4.0+, required for cross-origin)
CSRF_TRUSTED_ORIGINS = [
    "https://yourdomain.com",
    "https://www.yourdomain.com",
    "https://staging.yourdomain.com",
]

# 4. CSRF with DRF — SessionAuthentication requires CSRF
REST_FRAMEWORK = {
    "DEFAULT_AUTHENTICATION_CLASSES": [
        "rest_framework.authentication.TokenAuthentication",  # no CSRF needed
        # "rest_framework.authentication.SessionAuthentication",  # requires CSRF
    ],
}

# 5. CSRF_COOKIE_SECURE / CSRF_COOKIE_HTTPONLY mismatch
# If CSRF_COOKIE_HTTPONLY=True, JS cannot read the cookie
# Use {% csrf_token %} hidden input instead
CSRF_COOKIE_HTTPONLY = False  # allow JS to read for AJAX
CSRF_COOKIE_SECURE = True    # HTTPS only
```

---

## Static Files in Production

### Symptoms
- CSS/JS returns 404 in production
- `collectstatic` doesn't include all files
- Stale cached files after deployment

### Setup with WhiteNoise

```python
# pip install whitenoise

# settings.py
MIDDLEWARE = [
    "django.middleware.security.SecurityMiddleware",
    "whitenoise.middleware.WhiteNoiseMiddleware",  # after SecurityMiddleware
    # ... rest
]

STATIC_URL = "/static/"
STATIC_ROOT = BASE_DIR / "staticfiles"

# Compression + caching (forever-cacheable hashed filenames)
STORAGES = {
    "staticfiles": {
        "BACKEND": "whitenoise.storage.CompressedManifestStaticFilesStorage",
    },
}

# Collect before deployment
# python manage.py collectstatic --noinput
```

### Nginx setup (for large deployments)

```nginx
location /static/ {
    alias /var/www/app/staticfiles/;
    expires 30d;
    add_header Cache-Control "public, immutable";
    access_log off;
}

location /media/ {
    alias /var/www/app/media/;
    expires 7d;
    add_header X-Content-Type-Options nosniff;
}
```

### Common mistakes

```python
# 1. STATIC_ROOT not set → collectstatic has nowhere to collect to
STATIC_ROOT = BASE_DIR / "staticfiles"  # REQUIRED for production

# 2. App static files not found → check STATICFILES_DIRS
STATICFILES_DIRS = [BASE_DIR / "static"]  # project-level static

# 3. Forgetting to run collectstatic in Dockerfile
# Dockerfile
# RUN python manage.py collectstatic --noinput

# 4. ManifestStaticFilesStorage errors — missing source files
# Fix: ensure all referenced files exist, run collectstatic with --clear
# python manage.py collectstatic --clear --noinput
```

---

## Database Connection Pooling

### Symptoms
- `OperationalError: too many connections`
- Intermittent `connection already closed` errors
- High latency on first request after idle period

### Django built-in persistent connections

```python
DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.postgresql",
        "NAME": "mydb",
        "CONN_MAX_AGE": 600,      # seconds (0 = close after each request)
        "CONN_HEALTH_CHECKS": True,  # Django 4.1+ — verify before reuse
    }
}
```

### PgBouncer (recommended for production)

```ini
# pgbouncer.ini
[databases]
mydb = host=localhost port=5432 dbname=mydb

[pgbouncer]
listen_addr = 127.0.0.1
listen_port = 6432
pool_mode = transaction    # recommended for Django
max_client_conn = 200
default_pool_size = 20
min_pool_size = 5
```

```python
# Django connects to PgBouncer, not directly to PostgreSQL
DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.postgresql",
        "HOST": "127.0.0.1",
        "PORT": "6432",  # PgBouncer port
        "NAME": "mydb",
        "CONN_MAX_AGE": 0,  # let PgBouncer manage pooling
        "OPTIONS": {
            "options": "-c statement_timeout=30000",
        },
    }
}
```

### Django 5.x connection pool backend

```python
# Django 5.1+ built-in connection pooling (PostgreSQL)
DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.postgresql",
        "NAME": "mydb",
        "OPTIONS": {
            "pool": True,                # enable built-in pooling
            "pool_options": {
                "min_size": 2,
                "max_size": 10,
            },
        },
    }
}
```

---

## Celery Integration Issues

### Task not discovered

```python
# 1. Ensure celery.py is in your project package
# myproject/celery.py
import os
from celery import Celery

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "myproject.settings")
app = Celery("myproject")
app.config_from_object("django.conf:settings", namespace="CELERY")
app.autodiscover_tasks()

# 2. Import in __init__.py
# myproject/__init__.py
from .celery import app as celery_app
__all__ = ("celery_app",)

# 3. Tasks must be in tasks.py (autodiscover convention)
# myapp/tasks.py
from celery import shared_task

@shared_task
def process_order(order_id):
    order = Order.objects.get(pk=order_id)
    # ...
```

### Task called but nothing happens

```python
# Common mistake: calling task function directly instead of .delay()
process_order(order.pk)       # runs synchronously! Not a Celery task!
process_order.delay(order.pk) # correct — sends to broker

# Check broker connection
# celery -A myproject inspect ping
```

### Race condition with database

```python
# BAD: object may not be committed yet when worker picks up task
order = Order.objects.create(...)
process_order.delay(order.pk)  # worker may get DoesNotExist!

# GOOD: use on_commit
from django.db import transaction

with transaction.atomic():
    order = Order.objects.create(...)
    transaction.on_commit(lambda: process_order.delay(order.pk))
```

### Celery settings

```python
# settings.py
CELERY_BROKER_URL = "redis://localhost:6379/0"
CELERY_RESULT_BACKEND = "redis://localhost:6379/1"
CELERY_ACCEPT_CONTENT = ["json"]
CELERY_TASK_SERIALIZER = "json"
CELERY_RESULT_SERIALIZER = "json"
CELERY_TIMEZONE = "UTC"
CELERY_TASK_TRACK_STARTED = True
CELERY_TASK_TIME_LIMIT = 300  # hard limit in seconds
CELERY_TASK_SOFT_TIME_LIMIT = 240  # soft limit — raises SoftTimeLimitExceeded
CELERY_WORKER_MAX_TASKS_PER_CHILD = 1000  # restart worker after N tasks (memory leak prevention)
CELERY_TASK_ALWAYS_EAGER = False  # True only for testing without broker
```

---

## Timezone Pitfalls

### Symptoms
- Dates shift by hours when displayed
- Scheduled tasks run at wrong times
- `DateTimeField` stores unexpected values

### Core rules

```python
# settings.py
USE_TZ = True          # ALWAYS True in Django 5.x
TIME_ZONE = "UTC"      # store everything in UTC

# NEVER use datetime.now() — use timezone.now()
from django.utils import timezone

# BAD
import datetime
now = datetime.datetime.now()           # naive, ignores timezone!

# GOOD
now = timezone.now()                    # aware, respects USE_TZ

# Creating aware datetimes
aware_dt = timezone.make_aware(
    datetime.datetime(2024, 1, 15, 10, 30),
    timezone=timezone.get_fixed_timezone(60)  # UTC+1
)
```

### Template display

```django
{# Converts UTC to user's timezone #}
{% load tz %}
{% timezone "America/New_York" %}
    {{ event.start_time }}
{% endtimezone %}

{# Or per-value #}
{{ event.start_time|timezone:"Europe/London" }}
```

### Common traps

```python
# 1. Comparing naive and aware datetimes
# RuntimeWarning: DateTimeField received a naive datetime
# Fix: always use timezone.now()

# 2. Filtering by date ignores timezone
# BAD: misses timezone conversion
Event.objects.filter(start_time__date=datetime.date.today())
# GOOD: use timezone-aware range
today = timezone.now().date()
Event.objects.filter(
    start_time__gte=timezone.make_aware(datetime.datetime.combine(today, datetime.time.min)),
    start_time__lt=timezone.make_aware(datetime.datetime.combine(today + datetime.timedelta(days=1), datetime.time.min)),
)

# 3. Celery timezone mismatch
CELERY_TIMEZONE = "UTC"  # must match Django TIME_ZONE
CELERY_ENABLE_UTC = True

# 4. JSON serialization loses timezone info
# Use DRF's DateTimeField which handles this correctly
# Or: value.isoformat() to preserve timezone offset
```
