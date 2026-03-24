"""
Shared pytest fixtures for Django testing.

Place in the project root (next to manage.py) or in a tests/ directory.
Requires: pytest-django, factory-boy, rest_framework

Usage in tests:
    def test_something(api_client, user):
        api_client.force_authenticate(user=user)
        response = api_client.get("/api/v1/resource/")
        assert response.status_code == 200
"""
import pytest
from rest_framework.test import APIClient
import factory
from django.contrib.auth import get_user_model

User = get_user_model()


# =============================================================================
# User Factories
# =============================================================================

class UserFactory(factory.django.DjangoModelFactory):
    """Factory for creating test users."""

    class Meta:
        model = User
        django_get_or_create = ("username",)

    username = factory.Sequence(lambda n: f"user{n}")
    email = factory.LazyAttribute(lambda obj: f"{obj.username}@example.com")
    first_name = factory.Faker("first_name")
    last_name = factory.Faker("last_name")
    is_active = True

    @factory.post_generation
    def password(self, create, extracted, **kwargs):
        password = extracted or "testpass123"
        self.set_password(password)
        if create:
            self.save(update_fields=["password"])


class AdminFactory(UserFactory):
    """Factory for creating admin/staff users."""
    is_staff = True
    is_superuser = True
    username = factory.Sequence(lambda n: f"admin{n}")


# =============================================================================
# Client Fixtures
# =============================================================================

@pytest.fixture
def api_client():
    """Unauthenticated DRF API client."""
    return APIClient()


@pytest.fixture
def user(db):
    """A regular test user."""
    return UserFactory()


@pytest.fixture
def admin_user(db):
    """A staff/superuser."""
    return AdminFactory()


@pytest.fixture
def authenticated_client(api_client, user):
    """API client authenticated as a regular user."""
    api_client.force_authenticate(user=user)
    return api_client


@pytest.fixture
def admin_client(api_client, admin_user):
    """API client authenticated as an admin."""
    api_client.force_authenticate(user=admin_user)
    return api_client


# =============================================================================
# Django Test Client Fixtures
# =============================================================================

@pytest.fixture
def logged_in_client(client, user):
    """Django test client with a logged-in user (session-based)."""
    client.force_login(user)
    return client


# =============================================================================
# Database Fixtures
# =============================================================================

@pytest.fixture
def enable_db(db):
    """Explicitly enable DB access (alias for db fixture)."""
    pass


@pytest.fixture
def transactional(transactional_db):
    """Use real transactions (needed for testing on_commit hooks, Celery tasks)."""
    pass


# =============================================================================
# Utility Fixtures
# =============================================================================

@pytest.fixture
def sample_image():
    """Create a minimal valid JPEG for upload tests."""
    from django.core.files.uploadedfile import SimpleUploadedFile

    # Minimal 1x1 JPEG
    jpeg_bytes = (
        b"\xff\xd8\xff\xe0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00"
        b"\xff\xdb\x00C\x00\x08\x06\x06\x07\x06\x05\x08\x07\x07\x07\t\t"
        b"\x08\n\x0c\x14\r\x0c\x0b\x0b\x0c\x19\x12\x13\x0f\x14\x1d\x1a"
        b"\x1f\x1e\x1d\x1a\x1c\x1c $.\x27 \"*\x1c\x1c(7),01444\x1f\x27"
        b"9=82<.342\xff\xc0\x00\x0b\x08\x00\x01\x00\x01\x01\x01\x11\x00"
        b"\xff\xc4\x00\x1f\x00\x00\x01\x05\x01\x01\x01\x01\x01\x01\x00"
        b"\x00\x00\x00\x00\x00\x00\x00\x01\x02\x03\x04\x05\x06\x07\x08"
        b"\t\n\x0b\xff\xda\x00\x08\x01\x01\x00\x00?\x00T\xdb\x9e\xa7#"
        b"\xf1\xd5\x00\x00\x00\xff\xd9"
    )
    return SimpleUploadedFile("test.jpg", jpeg_bytes, content_type="image/jpeg")


@pytest.fixture
def mailoutbox(settings):
    """Capture sent emails in a list."""
    from django.core import mail

    settings.EMAIL_BACKEND = "django.core.mail.backends.locmem.EmailBackend"
    return mail.outbox


@pytest.fixture(autouse=True)
def _use_dummy_cache(settings):
    """Use dummy cache in tests to avoid cross-test pollution."""
    settings.CACHES = {
        "default": {
            "BACKEND": "django.core.cache.backends.dummy.DummyCache",
        }
    }
