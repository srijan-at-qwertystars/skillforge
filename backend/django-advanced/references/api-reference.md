# Django API Reference

> Quick-lookup reference for Django ORM, settings, URL routing, middleware,
> signals, management commands, testing utilities, and DRF.

## Table of Contents

- [ORM QuerySet Methods](#orm-queryset-methods)
- [Field Lookups](#field-lookups)
- [Aggregation Functions](#aggregation-functions)
- [Expressions & Functions](#expressions--functions)
- [Model Field Types](#model-field-types)
- [Settings Reference](#settings-reference)
- [URL Routing](#url-routing)
- [Middleware Hooks](#middleware-hooks)
- [Signal Reference](#signal-reference)
- [Management Command API](#management-command-api)
- [Testing Utilities](#testing-utilities)
- [DRF Serializer Fields & Options](#drf-serializer-fields--options)

---

## ORM QuerySet Methods

### Retrieval

| Method | Description | Returns |
|---|---|---|
| `all()` | All objects | QuerySet |
| `filter(**kwargs)` | Objects matching conditions | QuerySet |
| `exclude(**kwargs)` | Objects NOT matching conditions | QuerySet |
| `get(**kwargs)` | Single object (raises DoesNotExist/MultipleObjectsReturned) | Instance |
| `first()` | First object or None | Instance/None |
| `last()` | Last object or None | Instance/None |
| `earliest(*fields)` | Earliest by field | Instance |
| `latest(*fields)` | Latest by field | Instance |
| `in_bulk(id_list)` | Dict of {id: instance} | dict |

### Creation & Update

| Method | Description |
|---|---|
| `create(**kwargs)` | Create and save in one step |
| `get_or_create(**kwargs, defaults={})` | Get existing or create (returns `(obj, created)`) |
| `update_or_create(**kwargs, defaults={})` | Update existing or create (returns `(obj, created)`) |
| `bulk_create(objs, batch_size=None)` | Insert multiple objects efficiently |
| `bulk_update(objs, fields, batch_size=None)` | Update multiple objects efficiently |
| `update(**kwargs)` | Mass update, returns count (no signals fired) |

### Deletion

| Method | Description |
|---|---|
| `delete()` | Delete matching objects, returns `(count, {type: count})` |

### Ordering & Limiting

| Method | Description |
|---|---|
| `order_by(*fields)` | Sort (`"-field"` for descending) |
| `reverse()` | Reverse order |
| `distinct(*fields)` | Remove duplicates (PostgreSQL supports field-level) |
| `values(*fields)` | Return dicts instead of model instances |
| `values_list(*fields, flat=False)` | Return tuples (or flat list with single field) |
| `none()` | Return empty QuerySet |

### Optimization

| Method | Description |
|---|---|
| `select_related(*fields)` | JOIN FK/OneToOne in single query |
| `prefetch_related(*fields)` | Separate query for M2M/reverse FK |
| `Prefetch(lookup, queryset, to_attr)` | Custom prefetch with filtered queryset |
| `only(*fields)` | Load only specified fields |
| `defer(*fields)` | Skip loading specified fields |
| `select_for_update(skip_locked, of, no_key)` | Row-level lock |
| `iterator(chunk_size=2000)` | Stream results without caching |

### Set Operations

| Method | Description |
|---|---|
| `union(*querysets, all=False)` | SQL UNION |
| `intersection(*querysets)` | SQL INTERSECT |
| `difference(*querysets)` | SQL EXCEPT |

### Aggregation & Annotation

| Method | Description |
|---|---|
| `aggregate(**kwargs)` | Compute aggregate over entire QuerySet → dict |
| `annotate(**kwargs)` | Add computed field to each object → QuerySet |
| `count()` | Count objects (SQL COUNT) |
| `exists()` | True if any objects match (SQL EXISTS) |

### Evaluation

| Method | Description |
|---|---|
| `len(qs)` | Evaluate and count (prefer `.count()`) |
| `list(qs)` | Force evaluation to list |
| `bool(qs)` | True if non-empty (prefer `.exists()`) |
| `qs[5:10]` | Slice (SQL LIMIT/OFFSET) |
| `repr(qs)` | Force evaluation |

### Raw SQL

| Method | Description |
|---|---|
| `raw(sql, params)` | Execute raw SQL, return model instances |
| `connection.cursor()` | Direct database cursor for non-model queries |

---

## Field Lookups

Use with `filter()`, `exclude()`, `get()`: `Model.objects.filter(field__lookup=value)`

| Lookup | SQL Equivalent | Example |
|---|---|---|
| `exact` | `= value` | `name__exact="Django"` |
| `iexact` | `ILIKE value` | `name__iexact="django"` |
| `contains` | `LIKE '%val%'` | `name__contains="ang"` |
| `icontains` | `ILIKE '%val%'` | `name__icontains="ang"` |
| `startswith` | `LIKE 'val%'` | `name__startswith="Dj"` |
| `istartswith` | `ILIKE 'val%'` | `name__istartswith="dj"` |
| `endswith` | `LIKE '%val'` | `name__endswith="go"` |
| `iendswith` | `ILIKE '%val'` | `name__iendswith="GO"` |
| `in` | `IN (...)` | `id__in=[1, 2, 3]` |
| `gt` | `>` | `price__gt=100` |
| `gte` | `>=` | `price__gte=100` |
| `lt` | `<` | `price__lt=50` |
| `lte` | `<=` | `price__lte=50` |
| `range` | `BETWEEN` | `date__range=(start, end)` |
| `isnull` | `IS NULL / IS NOT NULL` | `email__isnull=True` |
| `regex` | `~ 'pattern'` | `name__regex=r"^[A-Z]"` |
| `iregex` | `~* 'pattern'` | `name__iregex=r"^[a-z]"` |
| `date` | Cast to date | `created__date=date(2024,1,1)` |
| `year` | Extract year | `created__year=2024` |
| `month` | Extract month | `created__month=6` |
| `day` | Extract day | `created__day=15` |
| `week` | ISO week number | `created__week=25` |
| `week_day` | Day of week (1=Sun) | `created__week_day=2` |
| `iso_week_day` | ISO day (1=Mon) | `created__iso_week_day=1` |
| `quarter` | Quarter (1-4) | `created__quarter=2` |
| `hour` | Extract hour | `created__hour=14` |
| `minute` | Extract minute | `created__minute=30` |
| `second` | Extract second | `created__second=0` |
| `time` | Cast to time | `created__time=time(14,30)` |

### Relation spanning

```python
# Traverse relations with double underscores
Book.objects.filter(author__name="Tolkien")
Book.objects.filter(author__profile__country="UK")
```

---

## Aggregation Functions

All from `django.db.models`:

| Function | Description | Example |
|---|---|---|
| `Avg(field)` | Average value | `Avg("price")` |
| `Count(field, distinct=False)` | Count (optionally distinct) | `Count("id", distinct=True)` |
| `Max(field)` | Maximum value | `Max("price")` |
| `Min(field)` | Minimum value | `Min("price")` |
| `Sum(field)` | Sum of values | `Sum("quantity")` |
| `StdDev(field, sample=False)` | Standard deviation | `StdDev("price")` |
| `Variance(field, sample=False)` | Variance | `Variance("price")` |

### Usage patterns

```python
# Aggregate → dict
Product.objects.aggregate(avg=Avg("price"), total=Count("id"))
# → {"avg": Decimal("29.99"), "total": 150}

# Annotate → per-object
Category.objects.annotate(
    product_count=Count("products"),
    avg_price=Avg("products__price"),
).filter(product_count__gt=5)

# Grouped aggregation
from django.db.models.functions import TruncMonth
Order.objects.annotate(month=TruncMonth("created")).values("month").annotate(
    revenue=Sum("total"), orders=Count("id")
).order_by("month")
```

---

## Expressions & Functions

### Core expressions

| Expression | Description |
|---|---|
| `F("field")` | Reference a model field |
| `Q(condition)` | Composable query condition (`&`, `\|`, `~`) |
| `Value(val)` | Wrap a Python value for use in expressions |
| `Subquery(queryset)` | Use queryset as subquery |
| `OuterRef("field")` | Reference outer query field in subquery |
| `Exists(queryset)` | SQL EXISTS subquery |
| `Case(When(...), default=...)` | Conditional expression (SQL CASE) |
| `When(condition, then=value)` | Branch in Case expression |
| `RawSQL(sql, params)` | Inline raw SQL in expressions |

### Database functions

From `django.db.models.functions`:

| Category | Functions |
|---|---|
| **Text** | `Upper`, `Lower`, `Length`, `Trim`, `LTrim`, `RTrim`, `Replace`, `Concat`, `Left`, `Right`, `Reverse`, `Substr`, `StrIndex`, `Repeat`, `Ord`, `Chr`, `MD5`, `SHA1`, `SHA224`, `SHA256`, `SHA384`, `SHA512` |
| **Math** | `Abs`, `ACos`, `ASin`, `ATan`, `ATan2`, `Ceil`, `Cos`, `Cot`, `Degrees`, `Exp`, `Floor`, `Ln`, `Log`, `Mod`, `Pi`, `Power`, `Radians`, `Random`, `Round`, `Sign`, `Sin`, `Sqrt`, `Tan` |
| **Date/Time** | `Now`, `TruncYear`, `TruncQuarter`, `TruncMonth`, `TruncWeek`, `TruncDay`, `TruncDate`, `TruncTime`, `TruncHour`, `TruncMinute`, `TruncSecond`, `ExtractYear`, `ExtractMonth`, `ExtractDay`, `ExtractHour`, `ExtractMinute`, `ExtractSecond`, `ExtractWeekDay`, `ExtractIsoWeekDay`, `ExtractWeek`, `ExtractIsoYear`, `ExtractQuarter` |
| **Window** | `Rank`, `DenseRank`, `RowNumber`, `Lag`, `Lead`, `FirstValue`, `LastValue`, `NthValue`, `Ntile`, `PercentRank`, `CumeDist` |
| **Comparison** | `Coalesce`, `Greatest`, `Least`, `NullIf` |
| **Type** | `Cast`, `JSONObject` (Django 4.2+) |

### Window function example

```python
from django.db.models import Window, F
from django.db.models.functions import Rank, RowNumber

Product.objects.annotate(
    category_rank=Window(
        expression=Rank(),
        partition_by=[F("category_id")],
        order_by=F("price").desc(),
    ),
    row_num=Window(
        expression=RowNumber(),
        order_by=F("created_at"),
    ),
)
```

---

## Model Field Types

### Common fields

| Field | Key Arguments |
|---|---|
| `CharField(max_length)` | `max_length` required |
| `TextField()` | Unlimited text |
| `IntegerField()` | -2B to 2B |
| `BigIntegerField()` | -9.2E18 to 9.2E18 |
| `PositiveIntegerField()` | 0 to 2B |
| `FloatField()` | Double-precision float |
| `DecimalField(max_digits, decimal_places)` | Exact decimal |
| `BooleanField(default=False)` | True/False |
| `DateField(auto_now, auto_now_add)` | Date only |
| `DateTimeField(auto_now, auto_now_add)` | Date + time |
| `TimeField()` | Time only |
| `DurationField()` | timedelta |
| `EmailField(max_length=254)` | Validated email |
| `URLField(max_length=200)` | Validated URL |
| `UUIDField(default=uuid.uuid4)` | UUID |
| `SlugField(max_length=50)` | URL-safe slug |
| `FileField(upload_to)` | File upload |
| `ImageField(upload_to)` | Image upload (requires Pillow) |
| `JSONField(default=dict)` | JSON data |
| `BinaryField()` | Raw binary data |
| `GenericIPAddressField()` | IPv4/IPv6 |

### Django 5.x fields

| Field | Description |
|---|---|
| `GeneratedField(expression, output_field, db_persist)` | Database-computed column |
| `db_default=Value(...)` | Database-level default (any field) |

### Relationship fields

| Field | Description |
|---|---|
| `ForeignKey(to, on_delete)` | Many-to-one |
| `OneToOneField(to, on_delete)` | One-to-one |
| `ManyToManyField(to, through=None)` | Many-to-many |

### Common field options

| Option | Description |
|---|---|
| `null=True` | Allow NULL in database |
| `blank=True` | Allow empty in forms |
| `default=value` | Python-level default |
| `db_default=expr` | Database-level default (Django 5.x) |
| `db_index=True` | Create database index |
| `unique=True` | Enforce uniqueness |
| `choices=[(val, label)]` | Restrict values |
| `validators=[func]` | Additional validation |
| `verbose_name="label"` | Human-readable name |
| `help_text="..."` | Form help text |
| `editable=False` | Exclude from forms/admin |
| `db_column="col"` | Custom column name |
| `db_comment="..."` | Database column comment (Django 5.x) |

---

## Settings Reference

### Critical production settings

```python
DEBUG = False
SECRET_KEY = os.environ["DJANGO_SECRET_KEY"]
ALLOWED_HOSTS = ["yourdomain.com"]
CSRF_TRUSTED_ORIGINS = ["https://yourdomain.com"]

# Security
SECURE_SSL_REDIRECT = True
SECURE_HSTS_SECONDS = 63072000
SECURE_HSTS_INCLUDE_SUBDOMAINS = True
SECURE_HSTS_PRELOAD = True
SESSION_COOKIE_SECURE = True
CSRF_COOKIE_SECURE = True
SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")
X_FRAME_OPTIONS = "DENY"
SECURE_CONTENT_TYPE_NOSNIFF = True

# Database
DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.postgresql",
        "NAME": os.environ["DB_NAME"],
        "USER": os.environ["DB_USER"],
        "PASSWORD": os.environ["DB_PASSWORD"],
        "HOST": os.environ["DB_HOST"],
        "PORT": os.environ.get("DB_PORT", "5432"),
        "CONN_MAX_AGE": 600,
        "CONN_HEALTH_CHECKS": True,
    }
}

# Caching
CACHES = {
    "default": {
        "BACKEND": "django.core.cache.backends.redis.RedisCache",
        "LOCATION": os.environ.get("REDIS_URL", "redis://127.0.0.1:6379/1"),
    }
}

# Static/Media
STATIC_URL = "/static/"
STATIC_ROOT = BASE_DIR / "staticfiles"
MEDIA_URL = "/media/"
MEDIA_ROOT = BASE_DIR / "media"

# Email
EMAIL_BACKEND = "django.core.mail.backends.smtp.EmailBackend"
DEFAULT_FROM_EMAIL = "noreply@yourdomain.com"

# Logging
LOGGING = {
    "version": 1,
    "disable_existing_loggers": False,
    "handlers": {
        "console": {"class": "logging.StreamHandler"},
        "file": {"class": "logging.FileHandler", "filename": "django.log"},
    },
    "root": {"handlers": ["console", "file"], "level": "WARNING"},
    "loggers": {
        "django": {"handlers": ["console"], "level": "WARNING"},
        "myapp": {"handlers": ["console", "file"], "level": "INFO"},
    },
}
```

---

## URL Routing

### Path converters

```python
from django.urls import path, re_path, include

urlpatterns = [
    path("products/", views.product_list, name="product_list"),
    path("products/<int:pk>/", views.product_detail, name="product_detail"),
    path("products/<slug:slug>/", views.product_by_slug, name="product_slug"),
    path("users/<uuid:user_id>/", views.user_profile, name="user_profile"),
    path("files/<path:file_path>/", views.serve_file, name="serve_file"),

    # Include app URLs
    path("api/", include("myapp.api_urls")),
    path("api/v2/", include(("myapp.api_v2_urls", "myapp"), namespace="v2")),

    # Regex (use only when path converters are insufficient)
    re_path(r"^archive/(?P<year>\d{4})/(?P<month>\d{2})/$", views.archive),
]
```

### Built-in converters

| Converter | Matches | Example |
|---|---|---|
| `str` | Any non-empty string (no `/`) | `<str:name>` |
| `int` | Zero or positive integer | `<int:pk>` |
| `slug` | Slug string (letters, numbers, `-`, `_`) | `<slug:slug>` |
| `uuid` | UUID | `<uuid:id>` |
| `path` | Any non-empty string (includes `/`) | `<path:file>` |

### Custom converter

```python
class FourDigitYearConverter:
    regex = r"[0-9]{4}"

    def to_python(self, value):
        return int(value)

    def to_url(self, value):
        return f"{value:04d}"

from django.urls import register_converter
register_converter(FourDigitYearConverter, "yyyy")
# Usage: path("archive/<yyyy:year>/", views.archive)
```

### Reversing URLs

```python
from django.urls import reverse
url = reverse("product_detail", kwargs={"pk": 42})
# Template: {% url 'product_detail' pk=42 %}
```

---

## Middleware Hooks

| Method | When Called | Can Return |
|---|---|---|
| `__init__(self, get_response)` | Server startup (once) | — |
| `__call__(self, request)` | Every request | HttpResponse |
| `process_view(request, view_func, args, kwargs)` | Before view | HttpResponse or None |
| `process_exception(request, exception)` | On unhandled exception | HttpResponse or None |
| `process_template_response(request, response)` | If response has `.render()` | TemplateResponse |

### Execution order

```
Request:   SecurityMW → SessionMW → CommonMW → CsrfMW → AuthMW → YourMW → View
Response:  View → YourMW → AuthMW → CsrfMW → CommonMW → SessionMW → SecurityMW
```

---

## Signal Reference

### Built-in model signals

| Signal | Sender | When | Key kwargs |
|---|---|---|---|
| `pre_init` | Model class | Before `__init__` | `args`, `kwargs` |
| `post_init` | Model class | After `__init__` | `instance` |
| `pre_save` | Model class | Before `save()` | `instance`, `raw`, `using`, `update_fields` |
| `post_save` | Model class | After `save()` | `instance`, `created`, `raw`, `using`, `update_fields` |
| `pre_delete` | Model class | Before `delete()` | `instance`, `using`, `origin` |
| `post_delete` | Model class | After `delete()` | `instance`, `using`, `origin` |
| `m2m_changed` | Through model | M2M relationship change | `action`, `instance`, `pk_set`, `model` |

### m2m_changed actions

| Action | When |
|---|---|
| `pre_add` | Before objects added |
| `post_add` | After objects added |
| `pre_remove` | Before objects removed |
| `post_remove` | After objects removed |
| `pre_clear` | Before all objects cleared |
| `post_clear` | After all objects cleared |

### Request signals

| Signal | When |
|---|---|
| `request_started` | HTTP request begins |
| `request_finished` | HTTP request completes |
| `got_request_exception` | Unhandled exception during request |

### Management signals

| Signal | When |
|---|---|
| `pre_migrate` | Before migrations run |
| `post_migrate` | After migrations complete |

---

## Management Command API

### Command structure

```python
from django.core.management.base import BaseCommand, CommandError

class Command(BaseCommand):
    help = "Description of what this command does"

    def add_arguments(self, parser):
        # Positional
        parser.add_argument("app_label", type=str)

        # Optional
        parser.add_argument("--days", type=int, default=30, help="Number of days")
        parser.add_argument("--dry-run", action="store_true", help="Preview only")
        parser.add_argument("--format", choices=["json", "csv"], default="json")
        parser.add_argument("--verbosity", type=int, default=1)  # built-in

    def handle(self, *args, **options):
        if options["dry_run"]:
            self.stdout.write("Dry run mode")
            return

        try:
            result = do_work(options["app_label"], options["days"])
        except Exception as e:
            raise CommandError(f"Failed: {e}")

        self.stdout.write(self.style.SUCCESS(f"Done: {result}"))

    # Style helpers: self.style.SUCCESS, WARNING, ERROR, NOTICE, SQL_FIELD, HTTP_INFO
```

### Calling commands programmatically

```python
from django.core.management import call_command
from io import StringIO

out = StringIO()
call_command("migrate", "--run-syncdb", stdout=out)
print(out.getvalue())
```

---

## Testing Utilities

### Django TestCase classes

| Class | Features |
|---|---|
| `TestCase` | Transactions rolled back after each test (fast) |
| `TransactionTestCase` | Real transactions (slower, needed for testing commits) |
| `LiveServerTestCase` | Starts actual server (for Selenium/browser tests) |
| `SimpleTestCase` | No database access (for logic/utility tests) |

### Test client

```python
from django.test import TestCase, Client

class MyTests(TestCase):
    def setUp(self):
        self.client = Client()
        self.user = User.objects.create_user("test", password="pass")

    def test_login_required(self):
        resp = self.client.get("/dashboard/")
        self.assertEqual(resp.status_code, 302)

    def test_authenticated(self):
        self.client.force_login(self.user)
        resp = self.client.get("/dashboard/")
        self.assertEqual(resp.status_code, 200)

    def test_post(self):
        self.client.force_login(self.user)
        resp = self.client.post("/api/items/", {"name": "Test"},
                                content_type="application/json")
        self.assertEqual(resp.status_code, 201)
        self.assertEqual(resp.json()["name"], "Test")
```

### Assertions

| Assertion | Description |
|---|---|
| `assertContains(resp, text, count, status_code)` | Response contains text |
| `assertNotContains(resp, text)` | Response doesn't contain text |
| `assertRedirects(resp, url, status_code, target_status)` | Redirect check |
| `assertTemplateUsed(resp, template_name)` | Template was rendered |
| `assertFormError(resp, form, field, errors)` | Form field error |
| `assertNumQueries(num)` | Exact query count (context manager) |
| `assertQuerySetEqual(qs, values)` | QuerySet matches values |

### RequestFactory vs Client

```python
from django.test import RequestFactory

factory = RequestFactory()
request = factory.get("/products/")
request.user = self.user

# Call view directly — no middleware, no URL routing
response = ProductListView.as_view()(request)
```

### pytest-django markers

```python
import pytest

@pytest.mark.django_db                    # allows database access
@pytest.mark.django_db(transaction=True)  # real transactions
@pytest.mark.parametrize("status", ["active", "archived"])
def test_filter_by_status(status):
    ...
```

---

## DRF Serializer Fields & Options

### Core field arguments (all fields)

| Argument | Default | Description |
|---|---|---|
| `read_only` | False | Include in output only |
| `write_only` | False | Include in input only |
| `required` | True | Must be provided on create |
| `default` | — | Default value if not provided |
| `allow_null` | False | Accept None |
| `source` | field name | Attribute to read from |
| `validators` | [] | Additional validators |
| `error_messages` | {} | Custom error messages |
| `label` | — | Human-readable label |
| `help_text` | — | Description text |

### Field types

| Field | Key Options |
|---|---|
| `CharField` | `max_length`, `min_length`, `allow_blank`, `trim_whitespace` |
| `EmailField` | `max_length` |
| `URLField` | `max_length` |
| `SlugField` | `max_length`, `allow_unicode` |
| `RegexField` | `regex` |
| `IntegerField` | `max_value`, `min_value` |
| `FloatField` | `max_value`, `min_value` |
| `DecimalField` | `max_digits`, `decimal_places`, `max_value`, `min_value` |
| `BooleanField` | — |
| `NullBooleanField` | — (deprecated, use `BooleanField(allow_null=True)`) |
| `DateTimeField` | `format`, `input_formats` |
| `DateField` | `format`, `input_formats` |
| `TimeField` | `format`, `input_formats` |
| `DurationField` | — |
| `ChoiceField` | `choices` |
| `MultipleChoiceField` | `choices` |
| `FileField` | `max_length`, `allow_empty_file`, `use_url` |
| `ImageField` | `max_length`, `allow_empty_file`, `use_url` |
| `ListField` | `child`, `allow_empty`, `min_length`, `max_length` |
| `DictField` | `child`, `allow_empty` |
| `JSONField` | `binary` |
| `UUIDField` | `format` (`hex_verbose`, `hex`, `int`, `urn`) |
| `IPAddressField` | `protocol` (`both`, `IPv4`, `IPv6`) |
| `SerializerMethodField` | `method_name` |

### Relational fields

| Field | Description |
|---|---|
| `PrimaryKeyRelatedField` | Represent relation by PK |
| `StringRelatedField` | Represent by `__str__()` (read-only) |
| `SlugRelatedField` | Represent by slug field |
| `HyperlinkedRelatedField` | Represent by URL |
| `HyperlinkedIdentityField` | URL to the object itself |

### Serializer Meta options

```python
class ProductSerializer(serializers.ModelSerializer):
    class Meta:
        model = Product
        fields = ["id", "name", "price"]     # or "__all__"
        exclude = ["internal_notes"]          # alternative to fields
        read_only_fields = ["id", "created_at"]
        extra_kwargs = {
            "price": {"min_value": 0, "required": True},
            "name": {"max_length": 200},
        }
        depth = 1  # auto-expand nested relations (use sparingly)
```

### Validation patterns

```python
class OrderSerializer(serializers.Serializer):
    # Field-level validation
    def validate_quantity(self, value):
        if value < 1:
            raise serializers.ValidationError("Quantity must be at least 1.")
        return value

    # Object-level validation (cross-field)
    def validate(self, attrs):
        if attrs["start_date"] > attrs["end_date"]:
            raise serializers.ValidationError("Start date must be before end date.")
        return attrs

    # Custom validators
    from rest_framework.validators import UniqueTogetherValidator
    class Meta:
        validators = [
            UniqueTogetherValidator(
                queryset=Order.objects.all(),
                fields=["customer", "product"],
            )
        ]
```

### DRF APIClient for testing

```python
from rest_framework.test import APIClient, APITestCase

class ProductAPITests(APITestCase):
    def setUp(self):
        self.client = APIClient()
        self.user = User.objects.create_user("testuser", password="pass")
        self.client.force_authenticate(user=self.user)

    def test_create_product(self):
        resp = self.client.post("/api/products/", {"name": "Widget", "price": "9.99"})
        self.assertEqual(resp.status_code, 201)
        self.assertEqual(resp.data["name"], "Widget")

    def test_list_products(self):
        Product.objects.create(name="A", price=10)
        resp = self.client.get("/api/products/")
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(len(resp.data["results"]), 1)
```
