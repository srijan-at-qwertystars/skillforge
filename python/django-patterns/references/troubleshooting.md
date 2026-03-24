# Django Troubleshooting Guide

## Table of Contents

- [N+1 Query Problems](#n1-query-problems)
- [Migration Conflicts](#migration-conflicts)
- [Circular Imports](#circular-imports)
- [CORS Issues](#cors-issues)
- [Static Files in Production](#static-files-in-production)
- [Database Connection Pooling](#database-connection-pooling)
- [Memory Leaks](#memory-leaks)
- [Slow Queries](#slow-queries)
- [Celery Integration Gotchas](#celery-integration-gotchas)
- [CSRF Token Issues with SPAs](#csrf-token-issues-with-spas)
- [Timezone Handling](#timezone-handling)
- [Common Error Messages](#common-error-messages)

---

## N+1 Query Problems

### Detecting with django-debug-toolbar

```bash
pip install django-debug-toolbar
```

```python
# settings/dev.py
INSTALLED_APPS += ["debug_toolbar"]
MIDDLEWARE.insert(0, "debug_toolbar.middleware.DebugToolbarMiddleware")
INTERNAL_IPS = ["127.0.0.1"]

# urls.py (dev only)
if settings.DEBUG:
    import debug_toolbar
    urlpatterns += [path("__debug__/", include(debug_toolbar.urls))]
```

Look for the SQL panel — if you see duplicate queries scaling with the number of objects, you have an N+1 problem.

### Detecting Programmatically

```python
# In tests: assert query count
from django.test.utils import override_settings

@pytest.mark.django_db
def test_no_n_plus_one(api_client, django_assert_num_queries):
    ProductFactory.create_batch(50)
    with django_assert_num_queries(2):  # 1 count + 1 select
        api_client.get("/api/products/")

# In development: log query counts
import logging
from django.db import connection, reset_queries

def log_queries(func):
    """Decorator to log query count for a function."""
    def wrapper(*args, **kwargs):
        reset_queries()
        result = func(*args, **kwargs)
        logger = logging.getLogger("django.db")
        logger.debug(f"{func.__name__}: {len(connection.queries)} queries")
        return result
    return wrapper
```

### Detecting with nplusone Library

```bash
pip install nplusone
```

```python
# settings/dev.py
INSTALLED_APPS += ["nplusone.ext.django"]
MIDDLEWARE.insert(0, "nplusone.ext.django.NPlusOneMiddleware")
NPLUSONE_RAISE = True  # Raise exception on N+1 (dev only)
NPLUSONE_LOGGER = logging.getLogger("nplusone")
```

### Fixing with select_related / prefetch_related

```python
# ❌ N+1: Each order.customer triggers a separate query
orders = Order.objects.all()
for order in orders:
    print(order.customer.name)  # N extra queries

# ✅ ForeignKey/OneToOne → select_related (SQL JOIN)
orders = Order.objects.select_related("customer", "customer__profile").all()

# ✅ Reverse FK / ManyToMany → prefetch_related (separate query)
customers = Customer.objects.prefetch_related("orders", "orders__items").all()

# ✅ Filtered prefetch with Prefetch object
from django.db.models import Prefetch

authors = Author.objects.prefetch_related(
    Prefetch(
        "books",
        queryset=Book.objects.filter(published=True).select_related("publisher"),
        to_attr="published_books",
    )
)
for author in authors:
    for book in author.published_books:  # No extra queries
        print(book.publisher.name)       # Also no extra query (select_related)
```

### Fixing in DRF Serializers

```python
class OrderViewSet(viewsets.ModelViewSet):
    def get_queryset(self):
        qs = Order.objects.all()
        if self.action == "list":
            qs = qs.select_related("customer").prefetch_related("items__product")
        elif self.action == "retrieve":
            qs = qs.select_related(
                "customer", "customer__profile"
            ).prefetch_related(
                "items__product__category",
                "status_history",
            )
        return qs
```

---

## Migration Conflicts

### Problem: Two Developers Created Migrations for the Same App

```
django.db.migrations.exceptions.NodeNotFoundError
# or
CommandError: Conflicting migrations detected
```

### Fix: Merge Migrations

```bash
# Auto-merge if no conflicts in fields:
python manage.py makemigrations --merge

# If there are real conflicts, manually resolve:
# 1. Delete one conflicting migration
# 2. Re-run makemigrations
# 3. Verify with: python manage.py migrate --check
```

### Problem: Migration Depends on Deleted Migration

```bash
# Find the broken dependency chain
python manage.py showmigrations --plan | grep -i "FAIL\|ERROR"

# Fake the migration if already applied in DB
python manage.py migrate app_name 0015 --fake

# Squash old migrations to clean up
python manage.py squashmigrations app_name 0001 0020
```

### Problem: Migration Can't Be Reversed

```python
# Always provide reverse functions for RunPython
def forward_func(apps, schema_editor):
    User = apps.get_model("users", "User")
    User.objects.filter(email="").update(email="unknown@example.com")

def reverse_func(apps, schema_editor):
    User = apps.get_model("users", "User")
    User.objects.filter(email="unknown@example.com").update(email="")

class Migration(migrations.Migration):
    operations = [
        migrations.RunPython(forward_func, reverse_func),
    ]
```

### Problem: Circular Migration Dependencies

```python
# Use string references instead of direct imports
class Migration(migrations.Migration):
    dependencies = [
        ("orders", "0001_initial"),
    ]
    operations = [
        migrations.AddField(
            model_name="order",
            name="customer",
            field=models.ForeignKey(
                to="customers.Customer",  # String reference — no import needed
                on_delete=models.CASCADE,
            ),
        ),
    ]
```

### Zero-Downtime Migration Tips

```python
# For renaming columns, use a 3-step migration:
# Step 1: Add new column (nullable)
# Step 2: Backfill data, deploy code that writes to both
# Step 3: Remove old column after full deployment

# For adding NOT NULL columns:
# Step 1: Add column as nullable with db_default
# Step 2: Backfill existing rows
# Step 3: Add NOT NULL constraint
migrations.AddField(
    model_name="product",
    name="sku",
    field=models.CharField(max_length=50, null=True),  # Start nullable
)
# Then in next migration:
migrations.AlterField(
    model_name="product",
    name="sku",
    field=models.CharField(max_length=50, default="UNKNOWN"),  # Now required
)
```

---

## Circular Imports

### Problem: Two Apps Import Each Other's Models

```python
# ❌ apps/orders/models.py
from apps.users.models import User  # Direct import

# apps/users/models.py
from apps.orders.models import Order  # Circular!
```

### Fix: String References in ForeignKey

```python
# ✅ Use string reference
class Order(models.Model):
    customer = models.ForeignKey("users.User", on_delete=models.CASCADE)
```

### Fix: Lazy Imports

```python
# ✅ Import inside function, not at module level
def get_user_orders(user_id):
    from apps.orders.models import Order  # Lazy import
    return Order.objects.filter(customer_id=user_id)
```

### Fix: Use django.apps.apps.get_model

```python
from django.apps import apps

def get_order_model():
    return apps.get_model("orders", "Order")

# In signals, migrations, and other late-binding contexts
def my_signal_handler(sender, instance, **kwargs):
    Order = apps.get_model("orders", "Order")
    Order.objects.filter(customer=instance).update(active=False)
```

### Fix: Move Shared Logic to a Service Layer

```python
# apps/core/services.py — no model imports at module level
def create_order_for_user(user_id, items):
    from apps.users.models import User
    from apps.orders.models import Order, OrderItem

    user = User.objects.get(pk=user_id)
    order = Order.objects.create(customer=user)
    OrderItem.objects.bulk_create([OrderItem(order=order, **item) for item in items])
    return order
```

---

## CORS Issues

### Problem: SPA Frontend Gets CORS Errors

```
Access to XMLHttpRequest at 'http://localhost:8000/api/' from origin
'http://localhost:3000' has been blocked by CORS policy
```

### Fix: Install django-cors-headers

```bash
pip install django-cors-headers
```

```python
# settings.py
INSTALLED_APPS += ["corsheaders"]

MIDDLEWARE = [
    "corsheaders.middleware.CorsMiddleware",  # Must be BEFORE CommonMiddleware
    "django.middleware.common.CommonMiddleware",
    ...,
]

# Development
CORS_ALLOWED_ORIGINS = [
    "http://localhost:3000",
    "http://127.0.0.1:3000",
]

# Or allow all in development (NOT production)
CORS_ALLOW_ALL_ORIGINS = DEBUG

# Production
CORS_ALLOWED_ORIGINS = [
    "https://myapp.example.com",
]

# Allow credentials (cookies, auth headers)
CORS_ALLOW_CREDENTIALS = True

# Custom headers
CORS_ALLOW_HEADERS = list(default_headers) + ["X-Custom-Header"]
```

### Preflight Requests

```python
# If you see OPTIONS requests failing, ensure:
# 1. CorsMiddleware is high enough in MIDDLEWARE
# 2. CORS_ALLOW_METHODS includes the methods you use
CORS_ALLOW_METHODS = ["DELETE", "GET", "OPTIONS", "PATCH", "POST", "PUT"]
```

---

## Static Files in Production

### Problem: Static Files Return 404 in Production

Django does NOT serve static files when `DEBUG=False`. You need a separate solution.

### Fix: WhiteNoise (Simplest)

```bash
pip install whitenoise
```

```python
# settings/prod.py
MIDDLEWARE = [
    "django.middleware.security.SecurityMiddleware",
    "whitenoise.middleware.WhiteNoiseMiddleware",  # Right after SecurityMiddleware
    ...,
]

STORAGES = {
    "staticfiles": {
        "BACKEND": "whitenoise.storage.CompressedManifestStaticFilesStorage",
    },
}

STATIC_ROOT = BASE_DIR / "staticfiles"
STATIC_URL = "/static/"
```

```bash
# Collect static files before deploy
python manage.py collectstatic --noinput
```

### Fix: Cloud Storage (S3)

```bash
pip install django-storages boto3
```

```python
# settings/prod.py
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
STATIC_URL = f"https://{AWS_S3_CUSTOM_DOMAIN}/static/"
```

### Fix: Nginx (Recommended for High Traffic)

```nginx
# nginx.conf
server {
    location /static/ {
        alias /app/staticfiles/;
        expires 365d;
        add_header Cache-Control "public, immutable";
    }

    location /media/ {
        alias /app/media/;
        expires 30d;
    }

    location / {
        proxy_pass http://django:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

---

## Database Connection Pooling

### Problem: "Too Many Connections" or Slow Queries Under Load

Django opens a new connection per request by default. Under load this exhausts the database connection limit.

### Fix: Django 4.1+ CONN_MAX_AGE + CONN_HEALTH_CHECKS

```python
DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.postgresql",
        "NAME": "mydb",
        "CONN_MAX_AGE": 600,          # Keep connections for 10 minutes
        "CONN_HEALTH_CHECKS": True,    # Check connection before reuse (Django 4.1+)
    }
}
```

### Fix: PgBouncer (Production)

```ini
# pgbouncer.ini
[databases]
mydb = host=db-server port=5432 dbname=mydb

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432
auth_type = md5
pool_mode = transaction       # Best for Django
max_client_conn = 400
default_pool_size = 20
min_pool_size = 5
reserve_pool_size = 5
```

```python
# settings.py — point Django at PgBouncer
DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.postgresql",
        "HOST": "pgbouncer",
        "PORT": "6432",
        "NAME": "mydb",
        "CONN_MAX_AGE": 0,  # Let PgBouncer handle pooling
        "OPTIONS": {
            "options": "-c search_path=public",
        },
        "DISABLE_SERVER_SIDE_CURSORS": True,  # Required for PgBouncer transaction mode
    }
}
```

### Fix: django-db-connection-pool

```bash
pip install django-db-connection-pool[postgresql]
```

```python
DATABASES = {
    "default": {
        "ENGINE": "dj_db_conn_pool.backends.postgresql",
        "POOL_OPTIONS": {
            "POOL_SIZE": 10,
            "MAX_OVERFLOW": 10,
            "RECYCLE": 300,
        },
    }
}
```

---

## Memory Leaks

### Common Causes and Fixes

#### 1. QuerySet Caching

```python
# ❌ Loading entire table into memory
all_users = list(User.objects.all())  # Millions of rows → OOM

# ✅ Use iterator() for large querysets
for user in User.objects.iterator(chunk_size=2000):
    process_user(user)

# ✅ Use values()/values_list() when you don't need model instances
emails = User.objects.values_list("email", flat=True)
```

#### 2. DEBUG=True in Production

```python
# When DEBUG=True, Django stores ALL SQL queries in memory
# settings/prod.py
DEBUG = False  # ALWAYS
```

#### 3. Signal Handler Accumulation

```python
# ❌ Connecting signals inside views/functions (each request adds another handler)
def my_view(request):
    post_save.connect(my_handler, sender=User)  # Memory leak!

# ✅ Connect signals once in AppConfig.ready()
class UsersConfig(AppConfig):
    def ready(self):
        import apps.users.signals  # noqa
```

#### 4. Celery Worker Memory

```python
# celery.py — configure max tasks per worker before restart
app.conf.worker_max_tasks_per_child = 1000
app.conf.worker_max_memory_per_child = 200_000  # 200MB in KB
```

#### 5. File Handle Leaks

```python
# ❌ Not closing files
f = open("data.csv")
data = f.read()
# f is never closed

# ✅ Use context managers
with open("data.csv") as f:
    data = f.read()

# ✅ Django's File handling
from django.core.files.uploadedfile import InMemoryUploadedFile
# For large uploads, use FILE_UPLOAD_MAX_MEMORY_SIZE to control memory
FILE_UPLOAD_MAX_MEMORY_SIZE = 5 * 1024 * 1024  # 5MB, then write to temp file
```

### Profiling Memory

```bash
pip install objgraph memory_profiler
```

```python
# Add to a management command for profiling
from memory_profiler import profile

@profile
def my_memory_heavy_function():
    # Your code here
    pass

# tracemalloc for tracking allocations
import tracemalloc

tracemalloc.start()
# ... run code ...
snapshot = tracemalloc.take_snapshot()
for stat in snapshot.statistics("lineno")[:10]:
    print(stat)
```

---

## Slow Queries

### Identifying Slow Queries

```python
# settings/dev.py — log all queries
LOGGING = {
    "version": 1,
    "handlers": {"console": {"class": "logging.StreamHandler"}},
    "loggers": {
        "django.db.backends": {
            "level": "DEBUG",
            "handlers": ["console"],
        },
    },
}

# PostgreSQL: log slow queries
# postgresql.conf
# log_min_duration_statement = 200  # Log queries > 200ms
```

### Common Fixes

```python
# 1. Add indexes for filter/order fields
class Meta:
    indexes = [
        models.Index(fields=["status", "created_at"]),
        models.Index(fields=["email"], name="email_idx"),
        # Partial index (PostgreSQL)
        models.Index(
            fields=["status"],
            condition=Q(status="active"),
            name="active_status_idx",
        ),
    ]

# 2. Use .only() / .defer() to limit loaded fields
Product.objects.only("id", "name", "price").filter(status="active")
Product.objects.defer("description", "full_spec").all()  # Skip large text fields

# 3. Use .values() / .values_list() when you don't need model instances
Product.objects.values("id", "name").filter(status="active")

# 4. Use .exists() instead of .count() > 0
if Product.objects.filter(status="active").exists():  # Stops at first match
    pass

# 5. Use .explain() to check query plan
print(Product.objects.filter(category=5).explain(analyze=True))

# 6. Batch large updates
from django.db.models import Q
import itertools

def batch_update(queryset, batch_size=1000):
    pks = list(queryset.values_list("pk", flat=True))
    for i in range(0, len(pks), batch_size):
        batch = pks[i:i + batch_size]
        queryset.model.objects.filter(pk__in=batch).update(processed=True)
```

---

## Celery Integration Gotchas

### Setup

```python
# config/celery.py
import os
from celery import Celery

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "config.settings.production")

app = Celery("config")
app.config_from_object("django.conf:settings", namespace="CELERY")
app.autodiscover_tasks()

# settings.py
CELERY_BROKER_URL = os.environ.get("CELERY_BROKER_URL", "redis://localhost:6379/0")
CELERY_RESULT_BACKEND = os.environ.get("CELERY_RESULT_BACKEND", "redis://localhost:6379/1")
CELERY_ACCEPT_CONTENT = ["json"]
CELERY_TASK_SERIALIZER = "json"
CELERY_RESULT_SERIALIZER = "json"
CELERY_TIMEZONE = "UTC"
```

### Gotcha 1: Passing Model Instances to Tasks

```python
# ❌ NEVER pass model instances — they can't be serialized, or are stale
@shared_task
def bad_task(order):  # Receives a model instance — FAILS
    process_order(order)

# ✅ Pass primary keys and re-fetch
@shared_task
def good_task(order_id):
    try:
        order = Order.objects.get(pk=order_id)
    except Order.DoesNotExist:
        return  # Object was deleted between enqueue and execution
    process_order(order)
```

### Gotcha 2: Database Transactions and Task Timing

```python
# ❌ Task runs before transaction commits — object doesn't exist yet
def create_order(request):
    with transaction.atomic():
        order = Order.objects.create(...)
        process_order.delay(order.pk)  # Task may run before commit!

# ✅ Use transaction.on_commit
def create_order(request):
    with transaction.atomic():
        order = Order.objects.create(...)
        transaction.on_commit(lambda: process_order.delay(order.pk))
```

### Gotcha 3: Task Retries and Idempotency

```python
from celery import shared_task
from celery.utils.log import get_task_logger

logger = get_task_logger(__name__)

@shared_task(
    bind=True,
    max_retries=3,
    default_retry_delay=60,
    autoretry_for=(ConnectionError, TimeoutError),
    retry_backoff=True,
    retry_jitter=True,
)
def send_notification(self, user_id, message):
    """Idempotent task — safe to retry."""
    from apps.notifications.models import Notification

    # Idempotency key prevents duplicate sends
    notif, created = Notification.objects.get_or_create(
        user_id=user_id,
        message=message,
        defaults={"status": "pending"},
    )
    if not created and notif.status == "sent":
        return "already_sent"

    try:
        send_email(notif)
        notif.status = "sent"
        notif.save(update_fields=["status"])
    except Exception as exc:
        logger.warning("Notification %s failed: %s", notif.pk, exc)
        raise self.retry(exc=exc)
```

### Gotcha 4: Celery Worker Database Connections

```python
# Workers may have stale database connections after restarts
# Fix: close connections before each task
from django.db import close_old_connections
from celery.signals import task_prerun

@task_prerun.connect
def close_old_connections_on_task_prerun(**kwargs):
    close_old_connections()
```

---

## CSRF Token Issues with SPAs

### Problem: 403 Forbidden — CSRF Token Missing

When a frontend SPA (React, Vue, etc.) makes POST requests to Django, CSRF tokens must be handled explicitly.

### Fix 1: Use CSRF Cookie (Recommended for Same-Origin SPAs)

```python
# settings.py
CSRF_COOKIE_HTTPONLY = False  # Allow JavaScript to read the cookie
CSRF_COOKIE_SAMESITE = "Lax"  # Or "None" if cross-origin (requires Secure)
```

```javascript
// Frontend: Read CSRF token from cookie and include in requests
function getCookie(name) {
    const value = `; ${document.cookie}`;
    const parts = value.split(`; ${name}=`);
    if (parts.length === 2) return parts.pop().split(';').shift();
}

fetch('/api/orders/', {
    method: 'POST',
    headers: {
        'Content-Type': 'application/json',
        'X-CSRFToken': getCookie('csrftoken'),
    },
    credentials: 'include',  // Send cookies
    body: JSON.stringify(data),
});
```

### Fix 2: Provide a CSRF Token Endpoint

```python
from django.middleware.csrf import get_token
from django.http import JsonResponse

def csrf_token_view(request):
    return JsonResponse({"csrfToken": get_token(request)})
```

### Fix 3: JWT-Based API (No CSRF Needed)

```python
# If using JWT for API auth, exempt API views from CSRF
REST_FRAMEWORK = {
    "DEFAULT_AUTHENTICATION_CLASSES": [
        "rest_framework_simplejwt.authentication.JWTAuthentication",
    ],
}
# JWTAuthentication doesn't use cookies, so CSRF is not applicable.
# SessionAuthentication DOES require CSRF — don't mix them carelessly.
```

### Fix 4: Exempt Specific Views

```python
from django.views.decorators.csrf import csrf_exempt, ensure_csrf_cookie

@csrf_exempt  # Use sparingly — only for webhook endpoints, etc.
def stripe_webhook(request):
    # Verify with Stripe signature instead
    pass

@ensure_csrf_cookie  # Force CSRF cookie to be set
def spa_entry_point(request):
    return render(request, "index.html")
```

---

## Timezone Handling

### Problem: Dates Are Off by Hours, or "RuntimeWarning: DateTimeField received a naive datetime"

### Setup

```python
# settings.py
USE_TZ = True  # Always True (default in Django 4+)
TIME_ZONE = "UTC"  # Store in UTC, display in user's timezone
```

### Common Mistakes and Fixes

```python
from django.utils import timezone
import datetime

# ❌ Using datetime.now() — creates naive datetime
now = datetime.datetime.now()

# ✅ Using timezone.now() — creates aware datetime in UTC
now = timezone.now()

# ❌ Comparing naive and aware datetimes
if my_datetime > datetime.datetime(2024, 1, 1):  # RuntimeWarning!
    pass

# ✅ Make datetimes aware
from django.utils.timezone import make_aware
aware_dt = make_aware(datetime.datetime(2024, 1, 1))

# ✅ Or use timezone directly
if my_datetime > timezone.datetime(2024, 1, 1, tzinfo=datetime.timezone.utc):
    pass

# Converting to user's timezone for display
from django.utils.timezone import localtime
user_tz = pytz.timezone("America/New_York")
local_dt = localtime(timezone.now(), user_tz)
```

### Per-User Timezone

```python
# Middleware to activate user's timezone
import zoneinfo
from django.utils import timezone

class UserTimezoneMiddleware:
    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        if request.user.is_authenticated and hasattr(request.user, "timezone"):
            tz = zoneinfo.ZoneInfo(request.user.timezone)
            timezone.activate(tz)
        else:
            timezone.deactivate()
        return self.get_response(request)
```

### Timezone-Aware Queries

```python
from django.utils import timezone
import datetime

# Get all orders from today in the server's timezone
today_start = timezone.now().replace(hour=0, minute=0, second=0, microsecond=0)
Order.objects.filter(created_at__gte=today_start)

# Get orders from a specific date in a specific timezone
import zoneinfo
eastern = zoneinfo.ZoneInfo("America/New_York")
start = datetime.datetime(2024, 3, 15, 0, 0, tzinfo=eastern)
end = datetime.datetime(2024, 3, 16, 0, 0, tzinfo=eastern)
Order.objects.filter(created_at__range=(start, end))
```

---

## Common Error Messages

### "Apps aren't loaded yet"

```python
# Cause: Importing models before django.setup() runs
# Fix: Use lazy imports or ensure django.setup() is called first

# In scripts:
import django
os.environ.setdefault("DJANGO_SETTINGS_MODULE", "config.settings")
django.setup()
from apps.users.models import User  # Now safe
```

### "No such table" / "relation does not exist"

```bash
# Run migrations
python manage.py migrate

# Check if migrations are pending
python manage.py showmigrations | grep "\[ \]"

# If table was manually dropped, fake migration to re-apply
python manage.py migrate app_name zero --fake
python manage.py migrate app_name
```

### "Field 'X' expected a number but got 'Y'"

```python
# Common with UUIDField and URL parameters
# Fix: Ensure URL converters match field types
path("<uuid:pk>/", view)  # Not <int:pk> for UUID primary keys
```

### "UNIQUE constraint failed"

```python
# Use get_or_create or update_or_create
obj, created = MyModel.objects.get_or_create(
    unique_field=value,
    defaults={"other_field": other_value},
)

# Or handle IntegrityError
from django.db import IntegrityError
try:
    MyModel.objects.create(unique_field=value)
except IntegrityError:
    obj = MyModel.objects.get(unique_field=value)
```

### "Maximum recursion depth exceeded"

```python
# Common cause: Overriding save() and calling self.save() inside a signal
# Fix: Use update() instead, or add a guard flag

def save(self, *args, **kwargs):
    if not self._state.adding and self.tracker.has_changed("status"):
        self.handle_status_change()
    super().save(*args, **kwargs)  # Always call super()
```

### "connection already closed"

```python
# Cause: Database connection timed out (common in Celery workers)
# Fix: Close old connections
from django.db import close_old_connections
close_old_connections()

# Or set CONN_MAX_AGE appropriately
DATABASES["default"]["CONN_MAX_AGE"] = 600
DATABASES["default"]["CONN_HEALTH_CHECKS"] = True
```
