---
name: django-advanced
description: >
  Advanced Django patterns for production apps. Use when: Django models, ORM queries
  (Q/F/Subquery/annotations/aggregations/window functions), class-based views/mixins,
  middleware, signals, caching (per-view/template/low-level), async views, Django REST
  framework (serializers/viewsets/permissions/authentication/throttling/filtering),
  Django Channels/WebSockets, deployment (gunicorn/nginx), migrations, management
  commands, testing, security (CSRF/XSS/CSP), Django 5.x features (db_default/
  GeneratedField). Do NOT use for: Flask, FastAPI, SQLAlchemy without Django, general
  Python unrelated to Django, Node.js/Express, Ruby on Rails, PHP/Laravel.
---

# Advanced Django Patterns

## Models & Django 5.x Features

Use `db_default` for DB-computed defaults. Use `GeneratedField` for DB-generated columns.

```python
from django.db import models
from django.db.models.functions import Now, Lower

class Product(models.Model):
    name = models.CharField(max_length=200)
    price = models.DecimalField(max_digits=10, decimal_places=2)
    created_at = models.DateTimeField(db_default=Now())
    name_lower = models.GeneratedField(
        expression=Lower("name"), output_field=models.CharField(max_length=200), db_persist=True)
    class Meta:
        indexes = [models.Index(fields=["-created_at"], name="recent_idx")]
        constraints = [
            models.CheckConstraint(check=models.Q(price__gte=0), name="positive_price"),
            models.UniqueConstraint(fields=["name"], name="unique_name"),
        ]
```

## Advanced ORM

### Q Objects — OR, AND, NOT, dynamic filters

```python
from django.db.models import Q
Product.objects.filter(Q(price__lt=10) | Q(name__icontains="sale"))
Product.objects.filter(~Q(status="archived"))
# Dynamic
filters = Q()
if category: filters &= Q(category=category)
if min_price: filters &= Q(price__gte=min_price)
Product.objects.filter(filters)
```

### F Expressions — field references, atomic updates

```python
from django.db.models import F
Order.objects.filter(shipped_date__gt=F("due_date"))
Product.objects.filter(pk=1).update(stock=F("stock") - 1)  # atomic
Product.objects.annotate(total=F("price") * F("quantity"))
```

### Subquery, OuterRef, Exists

```python
from django.db.models import Subquery, OuterRef, Exists
latest = Order.objects.filter(customer=OuterRef("pk")).order_by("-created_at")
Customer.objects.annotate(last_order=Subquery(latest.values("created_at")[:1]))
Customer.objects.filter(Exists(Order.objects.filter(customer=OuterRef("pk"), status="active")))
```

### Aggregations & Annotations

```python
from django.db.models import Count, Sum, Avg, Case, When, IntegerField
from django.db.models.functions import TruncMonth
Product.objects.aggregate(avg_price=Avg("price"), total=Count("id"))
# => {"avg_price": Decimal("29.99"), "total": 150}
Category.objects.annotate(num=Count("products"), avg=Avg("products__price")).filter(num__gt=5)
Order.objects.annotate(month=TruncMonth("created_at")).values("month").annotate(
    revenue=Sum("total"), count=Count("id")).order_by("month")
# Conditional
Product.objects.aggregate(
    expensive=Count(Case(When(price__gte=100, then=1), output_field=IntegerField())),
    cheap=Count(Case(When(price__lt=100, then=1), output_field=IntegerField())))
```

### Window Functions

```python
from django.db.models import Window, F
from django.db.models.functions import Rank, RowNumber, Lag
Product.objects.annotate(
    rank=Window(expression=Rank(), partition_by=[F("category")], order_by=F("price").desc()),
    prev_price=Window(expression=Lag("price", 1), order_by=F("created_at")))
```

### Custom Managers

```python
class PublishedManager(models.Manager):
    def get_queryset(self):
        return super().get_queryset().filter(status="published")
    def with_stats(self):
        return self.get_queryset().annotate(views=Count("views"), avg=Avg("reviews__score"))

class Article(models.Model):
    objects = models.Manager()
    published = PublishedManager()
# Article.published.with_stats().filter(avg__gte=4)
```

### Raw SQL (parameterized only — never string-format)

```python
Product.objects.raw("SELECT * FROM app_product WHERE price > %s", [100])
from django.db import connection
with connection.cursor() as c:
    c.execute("SELECT category, COUNT(*) FROM app_product GROUP BY category")
    rows = c.fetchall()
```

## Database Optimization

```python
Order.objects.select_related("customer", "customer__profile")  # FK JOIN
Author.objects.prefetch_related("books__publisher")  # separate query, joined in Python
from django.db.models import Prefetch
Author.objects.prefetch_related(
    Prefetch("books", queryset=Book.objects.filter(published=True), to_attr="pub_books"))
Product.objects.only("name", "price")   # partial load
Product.objects.defer("description")    # skip heavy fields
for p in Product.objects.iterator(chunk_size=2000): process(p)  # low memory
Product.objects.bulk_create([Product(name=f"P{i}") for i in range(1000)], batch_size=500)
Product.objects.bulk_update(products, ["price"], batch_size=500)
```

## Class-Based Views & Mixins

```python
from django.views.generic import ListView, CreateView
from django.contrib.auth.mixins import LoginRequiredMixin, PermissionRequiredMixin

class ProductListView(LoginRequiredMixin, ListView):
    model = Product
    paginate_by = 25
    def get_queryset(self):
        qs = super().get_queryset().select_related("category")
        q = self.request.GET.get("q")
        return qs.filter(Q(name__icontains=q) | Q(description__icontains=q)) if q else qs

class ProductCreateView(PermissionRequiredMixin, CreateView):
    model = Product
    fields = ["name", "price", "category"]
    permission_required = "app.add_product"
    def form_valid(self, form):
        form.instance.created_by = self.request.user
        return super().form_valid(form)
```

## Middleware

```python
import time, logging
logger = logging.getLogger(__name__)

class RequestTimingMiddleware:
    def __init__(self, get_response):
        self.get_response = get_response
    def __call__(self, request):
        start = time.monotonic()
        response = self.get_response(request)
        duration = time.monotonic() - start
        response["X-Request-Duration"] = f"{duration:.4f}"
        if duration > 1.0:
            logger.warning(f"Slow: {request.path} {duration:.2f}s")
        return response
    def process_exception(self, request, exception):
        logger.error(f"Error on {request.path}: {exception}", exc_info=True)
```

## Signals

Use sparingly — prefer model methods or service functions.

```python
from django.db.models.signals import post_save
from django.dispatch import receiver
from django.core.cache import cache

@receiver(post_save, sender=Product)
def invalidate_cache(sender, instance, **kwargs):
    cache.delete(f"product:{instance.pk}")

# Connect in AppConfig.ready():
class MyAppConfig(AppConfig):
    def ready(self):
        import myapp.signals  # noqa: F401
```

## Caching

```python
# Per-view
from django.views.decorators.cache import cache_page
@cache_page(60 * 15)
def product_list(request): ...

# Template: {% load cache %} {% cache 300 sidebar user.id %} ... {% endcache %}

# Low-level
from django.core.cache import cache
def get_product(pk):
    key = f"product:{pk}"
    obj = cache.get(key)
    if obj is None:
        obj = Product.objects.select_related("category").get(pk=pk)
        cache.set(key, obj, timeout=3600)
    return obj

# settings.py
CACHES = {"default": {"BACKEND": "django.core.cache.backends.redis.RedisCache",
    "LOCATION": "redis://127.0.0.1:6379/1"}}
```

## Async Views

```python
import httpx
from django.http import JsonResponse
from asgiref.sync import sync_to_async

async def fetch_external(request):
    async with httpx.AsyncClient() as client:
        resp = await client.get("https://api.example.com/data")
    return JsonResponse(resp.json())

# Async ORM (Django 4.1+)
async def products_api(request):
    products = [p async for p in Product.objects.filter(active=True)]
    return JsonResponse({"products": [p.name for p in products]})

# Wrap complex sync ORM
@sync_to_async
def _stats():
    return Product.objects.aggregate(avg=Avg("price"), total=Count("id"))
async def stats_view(request):
    return JsonResponse(await _stats())
```

## Django REST Framework

### Serializers

```python
from rest_framework import serializers

class ProductSerializer(serializers.ModelSerializer):
    category_name = serializers.CharField(source="category.name", read_only=True)
    class Meta:
        model = Product
        fields = ["id", "name", "price", "category", "category_name"]
        read_only_fields = ["id"]
    def validate_price(self, value):
        if value <= 0: raise serializers.ValidationError("Price must be positive.")
        return value
```

### ViewSets, Permissions, Filtering

```python
from rest_framework import viewsets, permissions, filters
from rest_framework.decorators import action
from rest_framework.response import Response
from django_filters.rest_framework import DjangoFilterBackend

class IsOwnerOrReadOnly(permissions.BasePermission):
    def has_object_permission(self, request, view, obj):
        if request.method in permissions.SAFE_METHODS: return True
        return obj.owner == request.user

class ProductViewSet(viewsets.ModelViewSet):
    queryset = Product.objects.select_related("category")
    serializer_class = ProductSerializer
    permission_classes = [permissions.IsAuthenticated, IsOwnerOrReadOnly]
    filter_backends = [DjangoFilterBackend, filters.SearchFilter, filters.OrderingFilter]
    filterset_fields = ["category", "active"]
    search_fields = ["name", "description"]
    ordering_fields = ["price", "created_at"]
    throttle_scope = "products"

    @action(detail=True, methods=["post"])
    def archive(self, request, pk=None):
        product = self.get_object()
        product.status = "archived"
        product.save(update_fields=["status"])
        return Response({"status": "archived"})
```

### DRF Settings

```python
REST_FRAMEWORK = {
    "DEFAULT_AUTHENTICATION_CLASSES": [
        "rest_framework.authentication.SessionAuthentication",
        "rest_framework.authentication.TokenAuthentication"],
    "DEFAULT_THROTTLE_CLASSES": [
        "rest_framework.throttling.AnonRateThrottle",
        "rest_framework.throttling.UserRateThrottle"],
    "DEFAULT_THROTTLE_RATES": {"anon": "100/hour", "user": "1000/hour", "products": "500/hour"},
    "DEFAULT_PAGINATION_CLASS": "rest_framework.pagination.PageNumberPagination",
    "PAGE_SIZE": 25,
}
```

## Django Channels

```python
import json
from channels.generic.websocket import AsyncWebsocketConsumer

class ChatConsumer(AsyncWebsocketConsumer):
    async def connect(self):
        self.room = self.scope["url_route"]["kwargs"]["room"]
        self.group = f"chat_{self.room}"
        await self.channel_layer.group_add(self.group, self.channel_name)
        await self.accept()
    async def disconnect(self, code):
        await self.channel_layer.group_discard(self.group, self.channel_name)
    async def receive(self, text_data):
        data = json.loads(text_data)
        await self.channel_layer.group_send(self.group, {"type": "chat.message", "message": data["message"]})
    async def chat_message(self, event):
        await self.send(text_data=json.dumps({"message": event["message"]}))

# routing.py
from django.urls import re_path
websocket_urlpatterns = [re_path(r"ws/chat/(?P<room>\w+)/$", ChatConsumer.as_asgi())]
# settings: CHANNEL_LAYERS = {"default": {"BACKEND": "channels_redis.core.RedisChannelLayer",
#     "CONFIG": {"hosts": [("127.0.0.1", 6379)]}}}
```

## Management Commands

```python
from django.core.management.base import BaseCommand
from django.utils import timezone
from datetime import timedelta

class Command(BaseCommand):
    help = "Remove stale records older than N days"
    def add_arguments(self, parser):
        parser.add_argument("--days", type=int, default=90)
        parser.add_argument("--dry-run", action="store_true")
    def handle(self, *args, **options):
        cutoff = timezone.now() - timedelta(days=options["days"])
        qs = StaleModel.objects.filter(updated_at__lt=cutoff)
        count = qs.count()
        if options["dry_run"]:
            self.stdout.write(f"Would delete {count} records")
        else:
            deleted, _ = qs.delete()
            self.stdout.write(self.style.SUCCESS(f"Deleted {deleted} records"))
```

## Testing

```python
from django.test import TestCase, RequestFactory
from unittest.mock import patch

class ProductTests(TestCase):
    @classmethod
    def setUpTestData(cls):
        cls.user = User.objects.create_user("tester", password="pass")
        cls.product = Product.objects.create(name="Widget", price=9.99)

    def test_list_view(self):
        self.client.force_login(self.user)
        resp = self.client.get("/products/")
        self.assertEqual(resp.status_code, 200)
        self.assertContains(resp, "Widget")

    def test_api_create(self):
        self.client.force_login(self.user)
        resp = self.client.post("/api/products/", {"name": "New", "price": "19.99"},
            content_type="application/json")
        self.assertEqual(resp.status_code, 201)

    @patch("myapp.views.external_api_call")
    def test_mock_external(self, mock_call):
        mock_call.return_value = {"status": "ok"}
        resp = self.client.get("/api/external/")
        self.assertEqual(resp.status_code, 200)
        mock_call.assert_called_once()

    def test_with_factory(self):
        request = RequestFactory().get("/products/")
        request.user = self.user
        resp = ProductListView.as_view()(request)
        self.assertEqual(resp.status_code, 200)
```

## Security Settings

```python
DEBUG = False
ALLOWED_HOSTS = ["yourdomain.com"]
SECRET_KEY = os.environ["DJANGO_SECRET_KEY"]
SECURE_SSL_REDIRECT = True
SECURE_HSTS_SECONDS = 63072000
SECURE_HSTS_INCLUDE_SUBDOMAINS = True
SECURE_HSTS_PRELOAD = True
SESSION_COOKIE_SECURE = True
CSRF_COOKIE_SECURE = True
SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")
SECURE_CONTENT_TYPE_NOSNIFF = True
X_FRAME_OPTIONS = "DENY"
# CSP via django-csp
CSP_DEFAULT_SRC = ("'self'",)
CSP_SCRIPT_SRC = ("'self'",)
CSP_STYLE_SRC = ("'self'", "'unsafe-inline'")
```

## Deployment

```bash
# Gunicorn: workers = (2 * CPU) + 1
gunicorn myproject.wsgi:application --bind 0.0.0.0:8000 --workers 5 --timeout 120
# Async: uvicorn myproject.asgi:application --host 0.0.0.0 --port 8000 --workers 4
python manage.py collectstatic --noinput && python manage.py migrate --noinput
```

```nginx
server {
    listen 443 ssl;
    server_name yourdomain.com;
    ssl_certificate /etc/letsencrypt/live/yourdomain.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/yourdomain.com/privkey.pem;
    location /static/ { alias /var/www/app/staticfiles/; expires 30d; }
    location /media/ { alias /var/www/app/media/; expires 7d; }
    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

## Migrations

- Use `makemigrations --name descriptive_name`. Never hand-edit auto-generated files.
- Zero-downtime: add nullable column → deploy → backfill → add NOT NULL.

```python
# Data migration
from django.db import migrations
def populate_slug(apps, schema_editor):
    Product = apps.get_model("myapp", "Product")
    for p in Product.objects.filter(slug=""):
        p.slug = slugify(p.name)
        p.save(update_fields=["slug"])

class Migration(migrations.Migration):
    dependencies = [("myapp", "0005_add_slug")]
    operations = [migrations.RunPython(populate_slug, migrations.RunPython.noop)]
```

---

## Supplementary Resources

### Reference Documentation (`references/`)

| File | Topics Covered |
|---|---|
| [`advanced-patterns.md`](references/advanced-patterns.md) | Custom managers/querysets, multi-DB routing, transactions (atomic/savepoints/on_commit), middleware patterns, signals, forms, admin customization, template tags/filters, context processors, file storage, auth backends |
| [`troubleshooting.md`](references/troubleshooting.md) | N+1 queries & debug-toolbar, slow migrations, circular imports, migration conflicts, memory leaks, CSRF issues, static files in production, connection pooling, Celery issues, timezone pitfalls |
| [`api-reference.md`](references/api-reference.md) | ORM QuerySet methods, field lookups, aggregation functions, expressions, model fields, settings reference, URL routing, middleware hooks, signals, management commands, testing utilities, DRF serializer fields |

### Scripts (`scripts/`)

| Script | Description |
|---|---|
| [`init-django.sh`](scripts/init-django.sh) | Scaffold project with settings split, env management, optional DRF/Celery/Docker (`--with-drf --with-celery --with-docker`) |
| [`manage-ops.sh`](scripts/manage-ops.sh) | Wrapper for common operations: migrate, makemigrations, superuser, collectstatic, shell, test, check, dumpdata, loaddata, squash |

### Templates & Assets (`assets/`)

| File | Description |
|---|---|
| [`settings-base.template.py`](assets/settings-base.template.py) | Production-ready base settings with django-environ, security headers, logging, DRF/Celery config blocks |
| [`docker-compose.template.yml`](assets/docker-compose.template.yml) | Django + PostgreSQL 16 + Redis 7 + Celery worker/beat + Flower monitoring with healthchecks |
| [`conftest.template.py`](assets/conftest.template.py) | pytest-django fixtures: user/admin/staff, API clients, token auth, factory stubs, file uploads, email outbox, Celery eager mode |

<!-- tested: pass -->
