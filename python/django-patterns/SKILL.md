---
name: django-patterns
description: >
  Django web framework patterns for Python projects. Use when working with Django projects, Django ORM queries, Django REST Framework (DRF) APIs, Django views (function/class/async), Django models and migrations, Django admin customization, Django middleware, Django signals, Django forms, Django templates, Django authentication, Django URL routing, or Django deployment configuration. Do NOT use for Flask, FastAPI, Starlette, Tornado, Pyramid, Bottle, or other non-Django Python web frameworks. Do NOT use for general Python questions unrelated to Django, SQLAlchemy ORM queries, or standalone REST APIs not using DRF.
---

# Django Patterns

## Project Structure

```
myproject/
├── manage.py
├── requirements/
│   ├── base.txt
│   ├── dev.txt              # -r base.txt + debug-toolbar, factory-boy
│   └── prod.txt             # -r base.txt + gunicorn, whitenoise
├── config/                  # Project-level config
│   ├── settings/
│   │   ├── base.py
│   │   ├── dev.py           # from .base import * ; DEBUG = True
│   │   └── prod.py          # from .base import * ; DEBUG = False
│   ├── urls.py
│   ├── wsgi.py
│   └── asgi.py
├── apps/
│   ├── users/
│   │   ├── models.py
│   │   ├── views.py, urls.py, serializers.py, admin.py
│   │   ├── services.py      # Business logic layer
│   │   ├── selectors.py     # Complex query logic
│   │   ├── signals.py
│   │   ├── tests/
│   │   └── migrations/
│   └── core/                # Shared base models, mixins, utilities
├── templates/
└── static/
```

Put business logic in `services.py`, not views or models. Keep views thin — HTTP in, delegate to services, HTTP out. Put complex querysets in `selectors.py` or custom managers.

## Models and Migrations

### Base model with audit fields

```python
import uuid
from django.db import models

class TimeStampedModel(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    created_at = models.DateTimeField(auto_now_add=True, db_index=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        abstract = True
        ordering = ["-created_at"]
```

### Django 5.x model features

```python
from django.db.models import F
from django.db.models.functions import Lower

class Product(TimeStampedModel):
    class Status(models.TextChoices):
        DRAFT = "draft", "Draft"
        PUBLISHED = "published", "Published"
        ARCHIVED = "archived", "Archived"

    name = models.CharField(max_length=255)
    price = models.DecimalField(max_digits=10, decimal_places=2)
    discount = models.DecimalField(max_digits=5, decimal_places=2, default=0)
    status = models.CharField(max_length=20, choices=Status, default=Status.DRAFT)
    # Django 5: db_default — database-computed default
    sku = models.CharField(max_length=100, db_default="PENDING")
    # Django 5: GeneratedField — database-computed column
    final_price = models.GeneratedField(
        expression=F("price") - F("discount"),
        output_field=models.DecimalField(max_digits=10, decimal_places=2),
        db_persist=True,
    )

    class Meta:
        indexes = [models.Index(fields=["status", "created_at"])]
        constraints = [
            models.CheckConstraint(check=models.Q(price__gte=0), name="price_positive"),
            models.UniqueConstraint(fields=["name", "status"], name="unique_name_status"),
        ]
```

### Custom QuerySet as Manager

```python
class ProductQuerySet(models.QuerySet):
    def published(self):
        return self.filter(status=Product.Status.PUBLISHED)
    def with_order_count(self):
        return self.annotate(order_count=models.Count("order_items"))

# In model: objects = ProductQuerySet.as_manager()
```

### Migration rules

- Rename auto-generated migrations: `makemigrations app --name add_status_field`
- Use `RunPython` with both forward and reverse functions.
- Add `db_index=True` on filter/order fields. Use `AddIndex` for compound indexes.

## Views

### Function-based view

```python
from django.http import JsonResponse
from django.shortcuts import get_object_or_404
from django.views.decorators.http import require_http_methods

@require_http_methods(["GET"])
def product_detail(request, pk):
    product = get_object_or_404(Product, pk=pk)
    return JsonResponse({"id": str(product.pk), "name": product.name})
```

### Class-based view

```python
from django.views.generic import ListView
from django.contrib.auth.mixins import LoginRequiredMixin

class ProductListView(LoginRequiredMixin, ListView):
    model = Product
    paginate_by = 25
    def get_queryset(self):
        qs = super().get_queryset().published()
        if q := self.request.GET.get("q"):
            qs = qs.filter(name__icontains=q)
        return qs
```

### Async view (Django 5.x)

```python
import httpx
from django.http import JsonResponse

async def external_data_view(request):
    async with httpx.AsyncClient() as client:
        resp = await client.get("https://api.example.com/data")
    return JsonResponse(resp.json())
```

Use async views for I/O-bound work. ORM is async-compatible: `await Model.objects.aget()`, `async for obj in qs.aiterator()`.

## URL Routing

```python
# config/urls.py
urlpatterns = [
    path("admin/", admin.site.urls),
    path("api/v1/", include("apps.products.urls", namespace="products")),
]
# apps/products/urls.py
app_name = "products"
urlpatterns = [
    path("", views.ProductListView.as_view(), name="list"),
    path("<uuid:pk>/", views.ProductDetailView.as_view(), name="detail"),
]
```

Always use `app_name` + `namespace`. Reverse: `reverse("products:detail", kwargs={"pk": pk})`.

## Django ORM Patterns

### F expressions — atomic, race-condition-free updates

```python
from django.db.models import F
Product.objects.filter(pk=pk).update(price=F("price") * 1.1)
```

### Q objects — complex lookups

```python
from django.db.models import Q
Product.objects.filter(Q(status="published") & (Q(price__lt=50) | Q(discount__gt=10)))
# Dynamic filter construction
filters = Q()
if category: filters &= Q(category=category)
if min_price: filters &= Q(price__gte=min_price)
Product.objects.filter(filters)
```

### Annotations, subqueries

```python
from django.db.models import Count, Avg, Subquery, OuterRef, Exists

Category.objects.annotate(product_count=Count("products"), avg_price=Avg("products__price"))

latest_order = Order.objects.filter(
    customer=OuterRef("pk")).order_by("-created_at").values("created_at")[:1]
Customer.objects.annotate(last_order=Subquery(latest_order))

Customer.objects.annotate(
    has_orders=Exists(Order.objects.filter(customer=OuterRef("pk")))
).filter(has_orders=True)
```

### Prefetch and select_related — solve N+1

```python
# ForeignKey/OneToOne → select_related (SQL JOIN)
Order.objects.select_related("customer", "customer__profile").all()
# ManyToMany/reverse FK → prefetch_related (separate query)
Author.objects.prefetch_related("books__publisher").all()
# Filtered prefetch
from django.db.models import Prefetch
Author.objects.prefetch_related(
    Prefetch("books", queryset=Book.objects.filter(status="published"), to_attr="published_books")
)
```

### Bulk operations

```python
Product.objects.bulk_create([Product(name=f"Item {i}") for i in range(1000)], batch_size=250)
Product.objects.bulk_update(products, ["price", "status"], batch_size=250)
```

## Django REST Framework

### Serializer

```python
from rest_framework import serializers

class ProductSerializer(serializers.ModelSerializer):
    class Meta:
        model = Product
        fields = ["id", "name", "price", "discount", "final_price", "status", "created_at"]
        read_only_fields = ["id", "created_at", "final_price"]

    def validate_price(self, value):
        if value <= 0:
            raise serializers.ValidationError("Price must be positive.")
        return value

class ProductDetailSerializer(ProductSerializer):
    category = CategorySerializer(read_only=True)
    category_id = serializers.PrimaryKeyRelatedField(
        queryset=Category.objects.all(), source="category", write_only=True)
    class Meta(ProductSerializer.Meta):
        fields = ProductSerializer.Meta.fields + ["category", "category_id", "description"]
```

### ViewSet with router

```python
from rest_framework import viewsets, permissions, filters
from rest_framework.decorators import action
from rest_framework.response import Response
from django_filters.rest_framework import DjangoFilterBackend

class ProductViewSet(viewsets.ModelViewSet):
    queryset = Product.objects.select_related("category").all()
    permission_classes = [permissions.IsAuthenticatedOrReadOnly]
    filter_backends = [DjangoFilterBackend, filters.SearchFilter, filters.OrderingFilter]
    filterset_fields = ["status", "category"]
    search_fields = ["name", "description"]
    ordering_fields = ["price", "created_at"]

    def get_serializer_class(self):
        return ProductSerializer if self.action == "list" else ProductDetailSerializer

    def perform_create(self, serializer):
        serializer.save(created_by=self.request.user)

    @action(detail=True, methods=["post"])
    def publish(self, request, pk=None):
        product = self.get_object()
        product.status = Product.Status.PUBLISHED
        product.save(update_fields=["status", "updated_at"])
        return Response({"status": "published"})

# urls.py
from rest_framework.routers import DefaultRouter
router = DefaultRouter()
router.register(r"products", ProductViewSet, basename="product")
urlpatterns = router.urls
```

### DRF settings

```python
REST_FRAMEWORK = {
    "DEFAULT_PAGINATION_CLASS": "rest_framework.pagination.CursorPagination",
    "PAGE_SIZE": 25,
    "DEFAULT_THROTTLE_CLASSES": ["rest_framework.throttling.AnonRateThrottle"],
    "DEFAULT_THROTTLE_RATES": {"anon": "100/hour"},
    "DEFAULT_AUTHENTICATION_CLASSES": [
        "rest_framework_simplejwt.authentication.JWTAuthentication",
    ],
}
```

## Authentication

### Custom User — define before first migration

```python
from django.contrib.auth.models import AbstractUser

class User(AbstractUser):
    email = models.EmailField(unique=True)
    USERNAME_FIELD = "email"
    REQUIRED_FIELDS = ["username"]
# settings.py: AUTH_USER_MODEL = "users.User"
```

### Custom permission

```python
from rest_framework.permissions import BasePermission

class IsOwnerOrReadOnly(BasePermission):
    def has_object_permission(self, request, view, obj):
        if request.method in ("GET", "HEAD", "OPTIONS"):
            return True
        return obj.owner == request.user
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
        logger.info(f"{request.method} {request.path} {response.status_code} {duration:.3f}s")
        response["X-Request-Duration"] = f"{duration:.3f}"
        return response
```

Middleware order: SecurityMiddleware → WhiteNoise → Session → Auth → Custom.

## Signals

```python
from django.db.models.signals import post_save
from django.dispatch import receiver
from django.conf import settings

@receiver(post_save, sender=settings.AUTH_USER_MODEL)
def create_user_profile(sender, instance, created, **kwargs):
    if created:
        Profile.objects.create(user=instance)

# Register in apps.py ready(): import apps.users.signals
```

Use signals only for decoupled cross-app side effects. For same-app logic, call service functions directly.

## Testing

```python
import pytest
from rest_framework.test import APIClient
import factory

class ProductFactory(factory.django.DjangoModelFactory):
    class Meta:
        model = Product
    name = factory.Sequence(lambda n: f"Product {n}")
    price = factory.Faker("pydecimal", left_digits=3, right_digits=2, positive=True)
    status = Product.Status.PUBLISHED

@pytest.fixture
def api_client():
    return APIClient()

@pytest.mark.django_db
def test_product_list(api_client, user):
    api_client.force_authenticate(user=user)
    ProductFactory.create_batch(3)
    response = api_client.get("/api/v1/products/")
    assert response.status_code == 200
    assert len(response.data["results"]) == 3

def test_query_count(api_client, user, django_assert_num_queries):
    ProductFactory.create_batch(10)
    api_client.force_authenticate(user=user)
    with django_assert_num_queries(2):  # 1 count + 1 select
        api_client.get("/api/v1/products/")
```

## Production Deployment

### Production settings (prod.py)

```python
import os
from .base import *  # noqa
DEBUG = False
SECRET_KEY = os.environ["DJANGO_SECRET_KEY"]
ALLOWED_HOSTS = os.environ.get("ALLOWED_HOSTS", "").split(",")
DATABASES = {"default": {
    "ENGINE": "django.db.backends.postgresql",
    "NAME": os.environ["DB_NAME"], "USER": os.environ["DB_USER"],
    "PASSWORD": os.environ["DB_PASSWORD"], "HOST": os.environ["DB_HOST"],
    "CONN_MAX_AGE": 600, "CONN_HEALTH_CHECKS": True,
}}
MIDDLEWARE.insert(1, "whitenoise.middleware.WhiteNoiseMiddleware")
STORAGES = {"staticfiles": {"BACKEND": "whitenoise.storage.CompressedManifestStaticFilesStorage"}}
STATIC_ROOT = BASE_DIR / "staticfiles"
SECURE_HSTS_SECONDS = 31536000
SECURE_SSL_REDIRECT = True
SESSION_COOKIE_SECURE = True
CSRF_COOKIE_SECURE = True
CACHES = {"default": {
    "BACKEND": "django.core.cache.backends.redis.RedisCache",
    "LOCATION": os.environ.get("REDIS_URL", "redis://localhost:6379/0"),
}}
```

### Gunicorn (gunicorn.conf.py)

```python
import multiprocessing
bind = "0.0.0.0:8000"
workers = multiprocessing.cpu_count() * 2 + 1
worker_class = "gthread"  # Use "uvicorn.workers.UvicornWorker" for async
threads = 4
timeout = 30
```

### Deploy checklist

Run `python manage.py check --deploy` before every release. Verify: `SECRET_KEY` from env, `DEBUG=False`, `ALLOWED_HOSTS` set, HTTPS enforced, `collectstatic` run, migrations applied.

## Django Admin

```python
@admin.register(Product)
class ProductAdmin(admin.ModelAdmin):
    list_display = ["name", "price", "status", "created_at"]
    list_filter = ["status", "created_at"]
    search_fields = ["name"]
    list_editable = ["status"]
    show_facets = admin.ShowFacets.ALWAYS  # Django 5.x facet filters
```

## Key Rules

- Always define `AUTH_USER_MODEL` before first migration.
- Use `select_related`/`prefetch_related` for any view accessing related objects.
- Use `F()` for all in-place field updates to prevent race conditions.
- Use `update_fields` in `.save()` to avoid full-row writes.
- Keep views thin: HTTP in → service → HTTP out.
- Never put secrets in source code — use environment variables.
- Use `bulk_create`/`bulk_update` with `batch_size` for large datasets.
- Run `check --deploy` in CI before every production deploy.

## References

In-depth guides in `references/`:

- **[advanced-patterns.md](references/advanced-patterns.md)** — Custom managers/querysets, database functions, window functions, CTEs, multi-database routing, custom model fields, abstract vs proxy models, GenericForeignKey, content types, custom template tags/filters, CBV mixins, middleware patterns, signals best practices, Django Channels/WebSockets.
- **[troubleshooting.md](references/troubleshooting.md)** — N+1 detection and fixes, migration conflicts, circular imports, CORS, static files in production, connection pooling (PgBouncer), memory leaks, slow queries, Celery gotchas, CSRF with SPAs, timezone handling.
- **[drf-guide.md](references/drf-guide.md)** — DRF deep dive: custom auth (JWT, API keys), throttling, django-filter, pagination strategies, nested serializers, writable nested serializers, ViewSet actions, custom permissions, API versioning, drf-spectacular schemas, API testing.

## Scripts

Executable helpers in `scripts/`:

- **[setup-django-project.sh](scripts/setup-django-project.sh)** — Scaffold a production-ready project with split settings, venv, Docker, .env, and common dependencies. Usage: `./setup-django-project.sh myproject`
- **[check-migrations.sh](scripts/check-migrations.sh)** — Detect missing migrations, conflicts, unapplied migrations, empty migrations, and auto-generated names. Usage: `./check-migrations.sh [manage.py]`
- **[django-security-audit.sh](scripts/django-security-audit.sh)** — Audit security settings: DEBUG, ALLOWED_HOSTS, SECURE_* headers, hardcoded secrets, unsafe deserialization, dependency vulnerabilities. Usage: `./django-security-audit.sh [manage.py]`

## Assets

Reusable templates and configs in `assets/`:

- **[settings/base.py](assets/settings/base.py)** — Production-ready base settings with django-environ, logging, DRF config, security defaults.
- **[settings/development.py](assets/settings/development.py)** — Dev overrides: debug toolbar, relaxed auth, console email, CORS open.
- **[settings/production.py](assets/settings/production.py)** — Full security hardening: HSTS, SSL redirect, secure cookies, WhiteNoise, Redis cache.
- **[docker-compose.yml](assets/docker-compose.yml)** — Django + PostgreSQL + Redis dev stack with health checks.
- **[Dockerfile](assets/Dockerfile)** — Multi-stage build: base → development → production. Non-root user, proper layer caching.
- **[conftest.py](assets/conftest.py)** — pytest fixtures: UserFactory, AdminFactory, api_client, authenticated_client, sample_image, mailoutbox.
<!-- tested: pass -->
