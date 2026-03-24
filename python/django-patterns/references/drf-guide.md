# Django REST Framework Deep Dive

## Table of Contents

- [Custom Authentication](#custom-authentication)
- [Throttling](#throttling)
- [Filtering with django-filter](#filtering-with-django-filter)
- [Pagination Strategies](#pagination-strategies)
- [Nested Serializers](#nested-serializers)
- [Writable Nested Serializers](#writable-nested-serializers)
- [ViewSet Actions](#viewset-actions)
- [Custom Permissions](#custom-permissions)
- [API Versioning](#api-versioning)
- [Schema Generation with drf-spectacular](#schema-generation-with-drf-spectacular)
- [Testing APIs with APIClient](#testing-apis-with-apiclient)

---

## Custom Authentication

### Token Authentication with Expiry

```python
from rest_framework.authentication import TokenAuthentication
from rest_framework.exceptions import AuthenticationFailed
from django.utils import timezone
from datetime import timedelta

class ExpiringTokenAuthentication(TokenAuthentication):
    """Token that expires after a configurable duration."""
    keyword = "Bearer"
    token_expiry = timedelta(hours=24)

    def authenticate_credentials(self, key):
        user, token = super().authenticate_credentials(key)

        if timezone.now() - token.created > self.token_expiry:
            token.delete()
            raise AuthenticationFailed("Token has expired.")

        return user, token
```

### API Key Authentication

```python
from rest_framework.authentication import BaseAuthentication
from rest_framework.exceptions import AuthenticationFailed

class APIKeyAuthentication(BaseAuthentication):
    """Authenticate via X-API-Key header."""

    def authenticate(self, request):
        api_key = request.META.get("HTTP_X_API_KEY")
        if not api_key:
            return None  # Let other authenticators try

        try:
            key_obj = APIKey.objects.select_related("user").get(
                key=api_key, is_active=True
            )
        except APIKey.DoesNotExist:
            raise AuthenticationFailed("Invalid API key.")

        if key_obj.expires_at and key_obj.expires_at < timezone.now():
            raise AuthenticationFailed("API key has expired.")

        key_obj.last_used = timezone.now()
        key_obj.save(update_fields=["last_used"])

        return (key_obj.user, key_obj)

    def authenticate_header(self, request):
        return "X-API-Key"
```

### JWT with SimpleJWT Customization

```python
# pip install djangorestframework-simplejwt
# settings.py
from datetime import timedelta

SIMPLE_JWT = {
    "ACCESS_TOKEN_LIFETIME": timedelta(minutes=15),
    "REFRESH_TOKEN_LIFETIME": timedelta(days=7),
    "ROTATE_REFRESH_TOKENS": True,
    "BLACKLIST_AFTER_ROTATION": True,
    "AUTH_HEADER_TYPES": ("Bearer",),
    "TOKEN_OBTAIN_SERIALIZER": "apps.users.serializers.CustomTokenObtainPairSerializer",
}

# Custom claims in JWT
from rest_framework_simplejwt.serializers import TokenObtainPairSerializer

class CustomTokenObtainPairSerializer(TokenObtainPairSerializer):
    @classmethod
    def get_token(cls, user):
        token = super().get_token(user)
        token["email"] = user.email
        token["is_staff"] = user.is_staff
        token["roles"] = list(user.groups.values_list("name", flat=True))
        return token

# urls.py
from rest_framework_simplejwt.views import TokenObtainPairView, TokenRefreshView

urlpatterns = [
    path("api/token/", TokenObtainPairView.as_view(), name="token_obtain_pair"),
    path("api/token/refresh/", TokenRefreshView.as_view(), name="token_refresh"),
]
```

### Multi-Authentication Setup

```python
REST_FRAMEWORK = {
    "DEFAULT_AUTHENTICATION_CLASSES": [
        "rest_framework_simplejwt.authentication.JWTAuthentication",
        "apps.core.authentication.APIKeyAuthentication",
        "rest_framework.authentication.SessionAuthentication",  # Last: for browsable API
    ],
}
```

---

## Throttling

### Built-in Throttle Classes

```python
# settings.py
REST_FRAMEWORK = {
    "DEFAULT_THROTTLE_CLASSES": [
        "rest_framework.throttling.AnonRateThrottle",
        "rest_framework.throttling.UserRateThrottle",
    ],
    "DEFAULT_THROTTLE_RATES": {
        "anon": "100/hour",
        "user": "1000/hour",
        "burst": "60/minute",
        "login": "5/minute",
    },
}
```

### Custom Throttle for Specific Endpoints

```python
from rest_framework.throttling import SimpleRateThrottle

class LoginRateThrottle(SimpleRateThrottle):
    """Throttle login attempts by IP."""
    scope = "login"

    def get_cache_key(self, request, view):
        ip = self.get_ident(request)
        return self.cache_format % {"scope": self.scope, "ident": ip}


class BurstRateThrottle(SimpleRateThrottle):
    """Short-term burst protection."""
    scope = "burst"

    def get_cache_key(self, request, view):
        if request.user.is_authenticated:
            return self.cache_format % {"scope": self.scope, "ident": request.user.pk}
        return self.cache_format % {"scope": self.scope, "ident": self.get_ident(request)}


# Apply per-view
class LoginView(APIView):
    throttle_classes = [LoginRateThrottle]

    def post(self, request):
        ...
```

### Scoped Throttling for Different Actions

```python
from rest_framework.throttling import ScopedRateThrottle

REST_FRAMEWORK = {
    "DEFAULT_THROTTLE_RATES": {
        "uploads": "10/hour",
        "exports": "5/day",
        "contacts": "20/minute",
    },
}

class UploadView(APIView):
    throttle_classes = [ScopedRateThrottle]
    throttle_scope = "uploads"

class ExportView(APIView):
    throttle_classes = [ScopedRateThrottle]
    throttle_scope = "exports"
```

---

## Filtering with django-filter

### Setup

```bash
pip install django-filter
```

```python
# settings.py
INSTALLED_APPS += ["django_filters"]

REST_FRAMEWORK = {
    "DEFAULT_FILTER_BACKENDS": [
        "django_filters.rest_framework.DjangoFilterBackend",
        "rest_framework.filters.SearchFilter",
        "rest_framework.filters.OrderingFilter",
    ],
}
```

### Basic FilterSet

```python
import django_filters
from apps.products.models import Product

class ProductFilter(django_filters.FilterSet):
    min_price = django_filters.NumberFilter(field_name="price", lookup_expr="gte")
    max_price = django_filters.NumberFilter(field_name="price", lookup_expr="lte")
    name = django_filters.CharFilter(lookup_expr="icontains")
    category = django_filters.ModelChoiceFilter(queryset=Category.objects.all())
    status = django_filters.ChoiceFilter(choices=Product.Status.choices)
    created_after = django_filters.DateFilter(field_name="created_at", lookup_expr="gte")
    created_before = django_filters.DateFilter(field_name="created_at", lookup_expr="lte")
    tags = django_filters.CharFilter(method="filter_tags")

    class Meta:
        model = Product
        fields = ["status", "category"]

    def filter_tags(self, queryset, name, value):
        """Custom filter method for comma-separated tags."""
        tags = [t.strip() for t in value.split(",")]
        return queryset.filter(tags__name__in=tags).distinct()

# Usage in ViewSet
class ProductViewSet(viewsets.ModelViewSet):
    filterset_class = ProductFilter
    search_fields = ["name", "description"]  # ?search=keyword
    ordering_fields = ["price", "created_at", "name"]  # ?ordering=-price
    ordering = ["-created_at"]  # Default ordering
```

### Advanced FilterSet Patterns

```python
class OrderFilter(django_filters.FilterSet):
    # Range filter
    total = django_filters.RangeFilter()  # ?total_min=100&total_max=500

    # Multiple choice
    status = django_filters.MultipleChoiceFilter(choices=Order.STATUS_CHOICES)
    # ?status=pending&status=shipped

    # Boolean filter
    has_discount = django_filters.BooleanFilter(
        field_name="discount", lookup_expr="gt", label="Has discount"
    )

    # Related model filter
    customer_email = django_filters.CharFilter(
        field_name="customer__email", lookup_expr="icontains"
    )

    # Date range with named params
    date_range = django_filters.DateFromToRangeFilter(field_name="created_at")
    # ?date_range_after=2024-01-01&date_range_before=2024-12-31

    class Meta:
        model = Order
        fields = {
            "status": ["exact"],
            "total": ["gte", "lte"],
        }
```

---

## Pagination Strategies

### Page Number Pagination (Simple)

```python
from rest_framework.pagination import PageNumberPagination

class StandardPagination(PageNumberPagination):
    page_size = 25
    page_size_query_param = "page_size"
    max_page_size = 100
```

Response: `{"count": 123, "next": "?page=2", "previous": null, "results": [...]}`

### Limit/Offset Pagination

```python
from rest_framework.pagination import LimitOffsetPagination

class LimitOffsetPagination(LimitOffsetPagination):
    default_limit = 25
    max_limit = 100
```

Response: `{"count": 123, "next": "?limit=25&offset=25", "results": [...]}`

### Cursor Pagination (Best for Large Datasets)

```python
from rest_framework.pagination import CursorPagination

class CreatedAtCursorPagination(CursorPagination):
    page_size = 25
    ordering = "-created_at"
    cursor_query_param = "cursor"
```

Response: `{"next": "?cursor=cD0yMDI0...", "previous": null, "results": [...]}`

**Why cursor pagination?**
- Consistent results even when data changes between pages
- No COUNT query — much faster on large tables
- Cannot jump to arbitrary pages (trade-off)

### Custom Pagination with Metadata

```python
from rest_framework.pagination import PageNumberPagination
from rest_framework.response import Response

class CustomPagination(PageNumberPagination):
    page_size = 25
    page_size_query_param = "page_size"

    def get_paginated_response(self, data):
        return Response({
            "meta": {
                "total_count": self.page.paginator.count,
                "page": self.page.number,
                "page_size": self.get_page_size(self.request),
                "total_pages": self.page.paginator.num_pages,
                "has_next": self.page.has_next(),
                "has_previous": self.page.has_previous(),
            },
            "results": data,
        })

    def get_paginated_response_schema(self, schema):
        """For drf-spectacular schema generation."""
        return {
            "type": "object",
            "properties": {
                "meta": {
                    "type": "object",
                    "properties": {
                        "total_count": {"type": "integer"},
                        "page": {"type": "integer"},
                        "page_size": {"type": "integer"},
                        "total_pages": {"type": "integer"},
                    },
                },
                "results": schema,
            },
        }
```

---

## Nested Serializers

### Read-Only Nested Serializers

```python
class CategorySerializer(serializers.ModelSerializer):
    class Meta:
        model = Category
        fields = ["id", "name", "slug"]

class TagSerializer(serializers.ModelSerializer):
    class Meta:
        model = Tag
        fields = ["id", "name"]

class ProductListSerializer(serializers.ModelSerializer):
    category = CategorySerializer(read_only=True)
    tags = TagSerializer(many=True, read_only=True)
    author = serializers.StringRelatedField()

    class Meta:
        model = Product
        fields = ["id", "name", "price", "category", "tags", "author"]
```

### Different Serializers for Read/Write

```python
class ProductSerializer(serializers.ModelSerializer):
    # Read: nested object; Write: just the ID
    category = CategorySerializer(read_only=True)
    category_id = serializers.PrimaryKeyRelatedField(
        queryset=Category.objects.all(),
        source="category",
        write_only=True,
    )

    # Read: nested list; Write: list of IDs
    tags = TagSerializer(many=True, read_only=True)
    tag_ids = serializers.PrimaryKeyRelatedField(
        queryset=Tag.objects.all(),
        source="tags",
        many=True,
        write_only=True,
    )

    class Meta:
        model = Product
        fields = ["id", "name", "price", "category", "category_id", "tags", "tag_ids"]
```

### Depth-Limited Serialization

```python
class ProductSerializer(serializers.ModelSerializer):
    class Meta:
        model = Product
        fields = "__all__"
        depth = 1  # Auto-nest one level deep (read-only)
        # Warning: depth makes all nested fields read-only and can expose too much data
```

---

## Writable Nested Serializers

### Creating Nested Objects

```python
class OrderItemSerializer(serializers.ModelSerializer):
    class Meta:
        model = OrderItem
        fields = ["id", "product", "quantity", "price"]
        read_only_fields = ["id", "price"]

class OrderSerializer(serializers.ModelSerializer):
    items = OrderItemSerializer(many=True)

    class Meta:
        model = Order
        fields = ["id", "customer", "items", "total", "status", "created_at"]
        read_only_fields = ["id", "total", "status", "created_at"]

    def create(self, validated_data):
        items_data = validated_data.pop("items")
        order = Order.objects.create(**validated_data)

        order_items = []
        for item_data in items_data:
            item_data["price"] = item_data["product"].price * item_data["quantity"]
            order_items.append(OrderItem(order=order, **item_data))
        OrderItem.objects.bulk_create(order_items)

        order.total = sum(item.price for item in order_items)
        order.save(update_fields=["total"])
        return order

    def update(self, instance, validated_data):
        items_data = validated_data.pop("items", None)

        # Update order fields
        for attr, value in validated_data.items():
            setattr(instance, attr, value)
        instance.save()

        if items_data is not None:
            # Replace all items (simpler than diffing)
            instance.items.all().delete()
            order_items = []
            for item_data in items_data:
                item_data["price"] = item_data["product"].price * item_data["quantity"]
                order_items.append(OrderItem(order=instance, **item_data))
            OrderItem.objects.bulk_create(order_items)

            instance.total = sum(item.price for item in order_items)
            instance.save(update_fields=["total"])

        return instance

    def validate_items(self, value):
        if not value:
            raise serializers.ValidationError("Order must have at least one item.")
        return value
```

### Using drf-writable-nested

```bash
pip install drf-writable-nested
```

```python
from drf_writable_nested import WritableNestedModelSerializer

class OrderSerializer(WritableNestedModelSerializer):
    items = OrderItemSerializer(many=True)

    class Meta:
        model = Order
        fields = ["id", "customer", "items", "total"]
    # Automatically handles create/update of nested items
```

### Nested Serializer with Through Model

```python
class MembershipSerializer(serializers.ModelSerializer):
    """Serializer for M2M through model."""
    user = UserSerializer(read_only=True)
    user_id = serializers.PrimaryKeyRelatedField(
        queryset=User.objects.all(), source="user", write_only=True
    )

    class Meta:
        model = Membership
        fields = ["id", "user", "user_id", "role", "joined_at"]

class TeamSerializer(serializers.ModelSerializer):
    members = MembershipSerializer(source="membership_set", many=True, read_only=True)

    class Meta:
        model = Team
        fields = ["id", "name", "members"]
```

---

## ViewSet Actions

### Custom Actions

```python
from rest_framework.decorators import action
from rest_framework.response import Response
from rest_framework import status

class ProductViewSet(viewsets.ModelViewSet):
    queryset = Product.objects.all()
    serializer_class = ProductSerializer

    # Detail action: /api/products/{pk}/publish/
    @action(detail=True, methods=["post"], url_path="publish")
    def publish(self, request, pk=None):
        product = self.get_object()
        product.status = Product.Status.PUBLISHED
        product.published_at = timezone.now()
        product.save(update_fields=["status", "published_at"])
        return Response(ProductSerializer(product).data)

    # List action: /api/products/export/
    @action(detail=False, methods=["get"])
    def export(self, request):
        queryset = self.filter_queryset(self.get_queryset())
        serializer = self.get_serializer(queryset, many=True)
        return Response(serializer.data)

    # Action with custom serializer
    @action(
        detail=True,
        methods=["post"],
        serializer_class=ProductReviewSerializer,
        permission_classes=[permissions.IsAuthenticated],
    )
    def review(self, request, pk=None):
        product = self.get_object()
        serializer = ProductReviewSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        serializer.save(product=product, author=request.user)
        return Response(serializer.data, status=status.HTTP_201_CREATED)

    # Bulk action
    @action(detail=False, methods=["post"], url_path="bulk-archive")
    def bulk_archive(self, request):
        ids = request.data.get("ids", [])
        if not ids:
            return Response(
                {"error": "No IDs provided"}, status=status.HTTP_400_BAD_REQUEST
            )
        updated = Product.objects.filter(pk__in=ids).update(
            status=Product.Status.ARCHIVED
        )
        return Response({"archived": updated})
```

### Overriding Standard Actions

```python
class ProductViewSet(viewsets.ModelViewSet):
    def perform_create(self, serializer):
        serializer.save(created_by=self.request.user)

    def perform_update(self, serializer):
        instance = serializer.save(modified_by=self.request.user)
        AuditLog.log("update", instance, self.request.user)

    def perform_destroy(self, instance):
        # Soft delete instead of hard delete
        instance.status = "archived"
        instance.save(update_fields=["status"])

    def get_serializer_class(self):
        actions = {
            "list": ProductListSerializer,
            "retrieve": ProductDetailSerializer,
            "create": ProductCreateSerializer,
            "update": ProductUpdateSerializer,
            "partial_update": ProductUpdateSerializer,
        }
        return actions.get(self.action, ProductSerializer)

    def get_permissions(self):
        if self.action in ("create", "update", "partial_update", "destroy"):
            return [permissions.IsAdminUser()]
        return [permissions.AllowAny()]
```

---

## Custom Permissions

### Object-Level Permissions

```python
from rest_framework.permissions import BasePermission, SAFE_METHODS

class IsOwnerOrReadOnly(BasePermission):
    """Object owner can edit; everyone else gets read-only."""
    def has_object_permission(self, request, view, obj):
        if request.method in SAFE_METHODS:
            return True
        return obj.owner == request.user


class IsAdminOrOwner(BasePermission):
    """Admin has full access; owner has object-level access."""
    def has_permission(self, request, view):
        return request.user and request.user.is_authenticated

    def has_object_permission(self, request, view, obj):
        return request.user.is_staff or obj.owner == request.user


class HasAPIScope(BasePermission):
    """Check API key scopes for fine-grained access."""
    required_scopes = []

    def has_permission(self, request, view):
        if not hasattr(request, "auth") or not request.auth:
            return False

        token_scopes = getattr(request.auth, "scopes", [])
        required = getattr(view, "required_scopes", self.required_scopes)
        return all(scope in token_scopes for scope in required)
```

### Role-Based Permissions

```python
class HasRole(BasePermission):
    """Check if user belongs to a specific group/role."""

    def __init__(self, *roles):
        self.roles = roles

    def has_permission(self, request, view):
        if not request.user.is_authenticated:
            return False
        user_roles = set(request.user.groups.values_list("name", flat=True))
        return bool(user_roles & set(self.roles))


# Factory function (since DRF instantiates permission classes)
def has_role(*roles):
    class RolePermission(BasePermission):
        def has_permission(self, request, view):
            if not request.user.is_authenticated:
                return False
            return request.user.groups.filter(name__in=roles).exists()
    return RolePermission


# Usage
class AdminDashboardView(APIView):
    permission_classes = [has_role("admin", "manager")]
```

### Combining Permissions

```python
from rest_framework.permissions import AND, OR, NOT

# Django REST Framework 3.15+ supports boolean operators
class ProductViewSet(viewsets.ModelViewSet):
    def get_permissions(self):
        if self.action == "destroy":
            return [(IsAdminUser | IsOwnerOrReadOnly)()]
        return [IsAuthenticatedOrReadOnly()]
```

---

## API Versioning

### URL Path Versioning (Recommended)

```python
# settings.py
REST_FRAMEWORK = {
    "DEFAULT_VERSIONING_CLASS": "rest_framework.versioning.URLPathVersioning",
    "DEFAULT_VERSION": "v1",
    "ALLOWED_VERSIONS": ["v1", "v2"],
}

# urls.py
urlpatterns = [
    path("api/<version>/products/", ProductViewSet.as_view({"get": "list"})),
    # Or with router:
    path("api/v1/", include("apps.api.v1.urls")),
    path("api/v2/", include("apps.api.v2.urls")),
]
```

### Namespace Versioning (Alternative)

```python
REST_FRAMEWORK = {
    "DEFAULT_VERSIONING_CLASS": "rest_framework.versioning.NamespaceVersioning",
}

# urls.py
urlpatterns = [
    path("api/v1/", include("apps.api.urls", namespace="v1")),
    path("api/v2/", include("apps.api.urls", namespace="v2")),
]
```

### Version-Specific Serializers

```python
class ProductViewSet(viewsets.ModelViewSet):
    def get_serializer_class(self):
        if self.request.version == "v2":
            return ProductSerializerV2
        return ProductSerializerV1

class ProductSerializerV1(serializers.ModelSerializer):
    class Meta:
        model = Product
        fields = ["id", "name", "price"]

class ProductSerializerV2(serializers.ModelSerializer):
    """V2 adds category and tags."""
    category = CategorySerializer()
    tags = TagSerializer(many=True)

    class Meta:
        model = Product
        fields = ["id", "name", "price", "category", "tags", "created_at"]
```

### Accept Header Versioning

```python
REST_FRAMEWORK = {
    "DEFAULT_VERSIONING_CLASS": "rest_framework.versioning.AcceptHeaderVersioning",
}
# Client sends: Accept: application/json; version=2
```

---

## Schema Generation with drf-spectacular

### Setup

```bash
pip install drf-spectacular
```

```python
# settings.py
INSTALLED_APPS += ["drf_spectacular"]

REST_FRAMEWORK = {
    "DEFAULT_SCHEMA_CLASS": "drf_spectacular.openapi.AutoSchema",
}

SPECTACULAR_SETTINGS = {
    "TITLE": "My Project API",
    "DESCRIPTION": "API documentation for My Project",
    "VERSION": "1.0.0",
    "SERVE_INCLUDE_SCHEMA": False,
    "SCHEMA_PATH_PREFIX": "/api/",
    "COMPONENT_SPLIT_REQUEST": True,  # Separate request/response schemas
    "ENUM_NAME_OVERRIDES": {
        "ProductStatusEnum": "apps.products.models.Product.Status",
    },
}

# urls.py
from drf_spectacular.views import SpectacularAPIView, SpectacularSwaggerView, SpectacularRedocView

urlpatterns = [
    path("api/schema/", SpectacularAPIView.as_view(), name="schema"),
    path("api/docs/", SpectacularSwaggerView.as_view(url_name="schema"), name="swagger-ui"),
    path("api/redoc/", SpectacularRedocView.as_view(url_name="schema"), name="redoc"),
]
```

### Decorating Views for Better Schemas

```python
from drf_spectacular.utils import extend_schema, extend_schema_view, OpenApiParameter, OpenApiExample
from drf_spectacular.types import OpenApiTypes

@extend_schema_view(
    list=extend_schema(
        summary="List products",
        description="Returns paginated list of products with filtering support.",
        parameters=[
            OpenApiParameter("status", OpenApiTypes.STR, enum=["draft", "published", "archived"]),
            OpenApiParameter("min_price", OpenApiTypes.DECIMAL, description="Minimum price filter"),
        ],
        tags=["Products"],
    ),
    retrieve=extend_schema(summary="Get product detail", tags=["Products"]),
    create=extend_schema(
        summary="Create a product",
        tags=["Products"],
        examples=[
            OpenApiExample(
                "Basic product",
                value={"name": "Widget", "price": "29.99", "category_id": 1},
                request_only=True,
            ),
        ],
    ),
)
class ProductViewSet(viewsets.ModelViewSet):
    ...

    @extend_schema(
        summary="Publish a product",
        responses={200: ProductSerializer},
        tags=["Products"],
    )
    @action(detail=True, methods=["post"])
    def publish(self, request, pk=None):
        ...
```

### Custom Schema Extensions

```python
from drf_spectacular.extensions import OpenApiSerializerFieldExtension

# For custom fields not auto-detected
class EncryptedFieldSchemaExtension(OpenApiSerializerFieldExtension):
    target_class = "apps.core.fields.EncryptedTextField"

    def map_serializer_field(self, auto_schema, direction):
        return {"type": "string", "writeOnly": direction == "request"}
```

---

## Testing APIs with APIClient

### Basic Test Setup

```python
import pytest
from rest_framework.test import APIClient
from rest_framework import status
from apps.users.tests.factories import UserFactory
from apps.products.tests.factories import ProductFactory

@pytest.fixture
def api_client():
    return APIClient()

@pytest.fixture
def authenticated_client(api_client):
    user = UserFactory()
    api_client.force_authenticate(user=user)
    return api_client

@pytest.fixture
def admin_client(api_client):
    admin = UserFactory(is_staff=True)
    api_client.force_authenticate(user=admin)
    return api_client
```

### Testing CRUD Operations

```python
@pytest.mark.django_db
class TestProductAPI:
    endpoint = "/api/v1/products/"

    def test_list_products(self, authenticated_client):
        ProductFactory.create_batch(5)
        response = authenticated_client.get(self.endpoint)
        assert response.status_code == status.HTTP_200_OK
        assert len(response.data["results"]) == 5

    def test_create_product(self, admin_client):
        category = CategoryFactory()
        payload = {
            "name": "New Product",
            "price": "29.99",
            "category_id": category.pk,
        }
        response = admin_client.post(self.endpoint, payload, format="json")
        assert response.status_code == status.HTTP_201_CREATED
        assert response.data["name"] == "New Product"
        assert Product.objects.count() == 1

    def test_update_product(self, admin_client):
        product = ProductFactory()
        payload = {"name": "Updated Name"}
        response = admin_client.patch(
            f"{self.endpoint}{product.pk}/", payload, format="json"
        )
        assert response.status_code == status.HTTP_200_OK
        product.refresh_from_db()
        assert product.name == "Updated Name"

    def test_delete_product(self, admin_client):
        product = ProductFactory()
        response = admin_client.delete(f"{self.endpoint}{product.pk}/")
        assert response.status_code == status.HTTP_204_NO_CONTENT
        assert Product.objects.count() == 0

    def test_unauthorized_create(self, api_client):
        response = api_client.post(self.endpoint, {"name": "Test"}, format="json")
        assert response.status_code == status.HTTP_401_UNAUTHORIZED
```

### Testing Authentication

```python
@pytest.mark.django_db
class TestAuthentication:
    def test_jwt_login(self, api_client):
        user = UserFactory()
        user.set_password("testpass123")
        user.save()

        response = api_client.post("/api/token/", {
            "email": user.email,
            "password": "testpass123",
        })
        assert response.status_code == status.HTTP_200_OK
        assert "access" in response.data
        assert "refresh" in response.data

        # Use the token
        api_client.credentials(HTTP_AUTHORIZATION=f"Bearer {response.data['access']}")
        response = api_client.get("/api/v1/products/")
        assert response.status_code == status.HTTP_200_OK

    def test_api_key_auth(self, api_client):
        api_key = APIKeyFactory()
        api_client.credentials(HTTP_X_API_KEY=api_key.key)
        response = api_client.get("/api/v1/products/")
        assert response.status_code == status.HTTP_200_OK
```

### Testing Filters, Pagination, and Permissions

```python
@pytest.mark.django_db
class TestProductFiltering:
    def test_filter_by_status(self, authenticated_client):
        ProductFactory(status="published")
        ProductFactory(status="draft")
        response = authenticated_client.get("/api/v1/products/?status=published")
        assert len(response.data["results"]) == 1

    def test_search(self, authenticated_client):
        ProductFactory(name="Organic Coffee")
        ProductFactory(name="Regular Tea")
        response = authenticated_client.get("/api/v1/products/?search=coffee")
        assert len(response.data["results"]) == 1

    def test_ordering(self, authenticated_client):
        ProductFactory(price=10)
        ProductFactory(price=30)
        ProductFactory(price=20)
        response = authenticated_client.get("/api/v1/products/?ordering=price")
        prices = [p["price"] for p in response.data["results"]]
        assert prices == sorted(prices)

    def test_pagination(self, authenticated_client):
        ProductFactory.create_batch(30)
        response = authenticated_client.get("/api/v1/products/?page_size=10")
        assert len(response.data["results"]) == 10
        assert response.data["meta"]["total_count"] == 30

@pytest.mark.django_db
class TestPermissions:
    def test_owner_can_edit(self, api_client):
        owner = UserFactory()
        product = ProductFactory(owner=owner)
        api_client.force_authenticate(user=owner)
        response = api_client.patch(
            f"/api/v1/products/{product.pk}/",
            {"name": "Updated"},
            format="json",
        )
        assert response.status_code == status.HTTP_200_OK

    def test_non_owner_cannot_edit(self, api_client):
        other_user = UserFactory()
        product = ProductFactory()
        api_client.force_authenticate(user=other_user)
        response = api_client.patch(
            f"/api/v1/products/{product.pk}/",
            {"name": "Hacked"},
            format="json",
        )
        assert response.status_code == status.HTTP_403_FORBIDDEN
```

### Testing Query Performance

```python
@pytest.mark.django_db
class TestQueryPerformance:
    def test_list_query_count(self, authenticated_client, django_assert_num_queries):
        ProductFactory.create_batch(20)
        with django_assert_num_queries(3):  # auth + count + select
            authenticated_client.get("/api/v1/products/")

    def test_detail_query_count(self, authenticated_client, django_assert_num_queries):
        product = ProductFactory()
        with django_assert_num_queries(2):  # auth + select
            authenticated_client.get(f"/api/v1/products/{product.pk}/")
```

### Testing File Uploads

```python
@pytest.mark.django_db
def test_upload_image(admin_client):
    from django.core.files.uploadedfile import SimpleUploadedFile

    image = SimpleUploadedFile(
        "test.jpg", b"\xff\xd8\xff\xe0" + b"\x00" * 100, content_type="image/jpeg"
    )
    response = admin_client.post(
        "/api/v1/products/",
        {"name": "With Image", "price": "10.00", "image": image},
        format="multipart",
    )
    assert response.status_code == status.HTTP_201_CREATED
```
