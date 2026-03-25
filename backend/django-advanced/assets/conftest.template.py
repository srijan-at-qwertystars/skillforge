"""
pytest-django fixtures for API testing with Django REST Framework.

Usage:
  1. Copy to your project root: cp conftest.template.py conftest.py
  2. Adjust model imports and factory definitions for your project
  3. Run: pytest

Requires: pytest-django, factory-boy, rest_framework
  pip install pytest-django factory-boy djangorestframework
"""

import pytest
from django.contrib.auth import get_user_model
from rest_framework.test import APIClient

# ---------------------------------------------------------------------------
# If using factory_boy, uncomment and adapt:
# import factory
# from factory.django import DjangoModelFactory
# ---------------------------------------------------------------------------

User = get_user_model()


# ===========================================================================
# User fixtures
# ===========================================================================

@pytest.fixture
def user_password():
    """Default password for test users."""
    return "TestPass123!"


@pytest.fixture
def user(db, user_password):
    """Create a regular (non-staff) test user."""
    return User.objects.create_user(
        username="testuser",
        email="testuser@example.com",
        password=user_password,
    )


@pytest.fixture
def admin_user(db, user_password):
    """Create a superuser for admin-level tests."""
    return User.objects.create_superuser(
        username="admin",
        email="admin@example.com",
        password=user_password,
    )


@pytest.fixture
def staff_user(db, user_password):
    """Create a staff user (can access admin, but limited permissions)."""
    return User.objects.create_user(
        username="staffuser",
        email="staff@example.com",
        password=user_password,
        is_staff=True,
    )


# ===========================================================================
# API Client fixtures
# ===========================================================================

@pytest.fixture
def api_client():
    """Unauthenticated DRF API client."""
    return APIClient()


@pytest.fixture
def authenticated_client(api_client, user):
    """API client authenticated as a regular user."""
    api_client.force_authenticate(user=user)
    return api_client


@pytest.fixture
def admin_client(api_client, admin_user):
    """API client authenticated as an admin/superuser."""
    api_client.force_authenticate(user=admin_user)
    return api_client


@pytest.fixture
def staff_client(api_client, staff_user):
    """API client authenticated as a staff user."""
    api_client.force_authenticate(user=staff_user)
    return api_client


@pytest.fixture
def token_client(api_client, user):
    """API client authenticated via Token (for token-based auth testing).

    Requires rest_framework.authtoken in INSTALLED_APPS.
    """
    try:
        from rest_framework.authtoken.models import Token
        token, _ = Token.objects.get_or_create(user=user)
        api_client.credentials(HTTP_AUTHORIZATION=f"Token {token.key}")
    except ImportError:
        pytest.skip("rest_framework.authtoken not installed")
    return api_client


# ===========================================================================
# Database & transaction fixtures
# ===========================================================================

@pytest.fixture
def db_no_rollback(request, transactional_db):
    """Use real transactions (for testing on_commit hooks, Celery tasks, etc.).

    Slower than default db fixture — use only when needed.
    """
    pass


# ===========================================================================
# Factory fixtures (uncomment and adapt for your models)
# ===========================================================================

# Example: Product factory
#
# class ProductFactory(DjangoModelFactory):
#     class Meta:
#         model = "products.Product"  # or import directly
#
#     name = factory.Sequence(lambda n: f"Product {n}")
#     price = factory.Faker("pydecimal", left_digits=3, right_digits=2, positive=True)
#     description = factory.Faker("paragraph")
#     is_active = True
#
#
# @pytest.fixture
# def product(db):
#     """Create a single product."""
#     return ProductFactory()
#
#
# @pytest.fixture
# def products(db):
#     """Create a batch of 10 products."""
#     return ProductFactory.create_batch(10)


# ===========================================================================
# Request/response helpers
# ===========================================================================

@pytest.fixture
def json_response():
    """Helper to parse and assert JSON responses."""
    class JSONResponseHelper:
        @staticmethod
        def assert_ok(response, status_code=200):
            assert response.status_code == status_code, (
                f"Expected {status_code}, got {response.status_code}: "
                f"{response.content.decode()[:500]}"
            )
            return response.json() if hasattr(response, "json") else response.data

        @staticmethod
        def assert_created(response):
            return JSONResponseHelper.assert_ok(response, 201)

        @staticmethod
        def assert_no_content(response):
            assert response.status_code == 204
            return None

        @staticmethod
        def assert_bad_request(response):
            return JSONResponseHelper.assert_ok(response, 400)

        @staticmethod
        def assert_unauthorized(response):
            assert response.status_code in (401, 403)
            return response.data if hasattr(response, "data") else None

        @staticmethod
        def assert_not_found(response):
            assert response.status_code == 404

        @staticmethod
        def assert_paginated(response, expected_count=None):
            data = JSONResponseHelper.assert_ok(response)
            assert "results" in data
            assert "count" in data
            if expected_count is not None:
                assert data["count"] == expected_count
            return data

    return JSONResponseHelper()


# ===========================================================================
# Email & async helpers
# ===========================================================================

@pytest.fixture
def mailoutbox(settings):
    """Access sent emails during tests.

    Usage:
        def test_sends_email(mailoutbox):
            send_welcome_email(user)
            assert len(mailoutbox) == 1
            assert mailoutbox[0].subject == "Welcome"
    """
    from django.core import mail
    mail.outbox.clear()
    return mail.outbox


@pytest.fixture(autouse=True)
def _use_in_memory_cache(settings):
    """Use in-memory cache for all tests (no Redis dependency)."""
    settings.CACHES = {
        "default": {
            "BACKEND": "django.core.cache.backends.locmem.LocMemCache",
            "LOCATION": "test-cache",
        }
    }


@pytest.fixture
def celery_eager(settings):
    """Run Celery tasks synchronously during tests.

    Usage:
        def test_async_task(celery_eager):
            result = my_task.delay(arg)
            assert result.get() == expected
    """
    settings.CELERY_TASK_ALWAYS_EAGER = True
    settings.CELERY_TASK_EAGER_PROPAGATES = True


# ===========================================================================
# File upload helpers
# ===========================================================================

@pytest.fixture
def temp_image():
    """Create a temporary image file for upload testing."""
    import io
    from PIL import Image as PILImage
    from django.core.files.uploadedfile import SimpleUploadedFile

    def _create(name="test.png", size=(100, 100), fmt="PNG"):
        image = PILImage.new("RGB", size, color="red")
        buffer = io.BytesIO()
        image.save(buffer, format=fmt)
        buffer.seek(0)
        return SimpleUploadedFile(
            name=name,
            content=buffer.read(),
            content_type=f"image/{fmt.lower()}",
        )

    return _create


@pytest.fixture
def temp_file():
    """Create a temporary file for upload testing."""
    from django.core.files.uploadedfile import SimpleUploadedFile

    def _create(name="test.txt", content=b"test file content", content_type="text/plain"):
        return SimpleUploadedFile(name=name, content=content, content_type=content_type)

    return _create
