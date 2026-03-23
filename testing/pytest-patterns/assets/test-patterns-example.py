"""
Example test file — pytest best practices & patterns.

This module demonstrates idiomatic pytest patterns you can adapt for your own
projects.  Each section is annotated so it doubles as a learning resource.

Requires:
    pytest, pytest-asyncio, pytest-mock, pytest-snapshot (syrupy)
"""

from __future__ import annotations

import re
from dataclasses import dataclass

import pytest


# =============================================================================
# SYSTEM UNDER TEST  (inline for demo purposes — normally lives in src/)
# =============================================================================

@dataclass
class User:
    id: int
    name: str
    email: str
    is_active: bool = True


class UserService:
    """Minimal service to demonstrate testing patterns."""

    def __init__(self, db, email_client=None):
        self.db = db
        self.email_client = email_client

    def get_user(self, user_id: int) -> User:
        user = self.db.get(user_id)
        if user is None:
            raise LookupError(f"User {user_id} not found")
        return user

    def create_user(self, name: str, email: str) -> User:
        if not re.match(r"^[^@]+@[^@]+\.[^@]+$", email):
            raise ValueError(f"Invalid email: {email}")
        user = User(id=len(self.db) + 1, name=name, email=email)
        self.db[user.id] = user
        if self.email_client:
            self.email_client.send_welcome(email)
        return user

    def deactivate_user(self, user_id: int) -> User:
        user = self.get_user(user_id)
        user.is_active = False
        return user

    async def fetch_remote_profile(self, user_id: int) -> dict:
        """Simulate an async network call."""
        user = self.get_user(user_id)
        return {"id": user.id, "name": user.name, "source": "remote"}


# =============================================================================
# MODULE-SCOPED FIXTURES
# =============================================================================
# Module scope is appropriate for read-only seed data that every test in this
# file can share safely.


@pytest.fixture(scope="module")
def seed_users() -> dict[int, User]:
    """Seed data shared across all tests in this module (read-only)."""
    return {
        1: User(id=1, name="Alice", email="alice@example.com"),
        2: User(id=2, name="Bob", email="bob@example.com"),
        3: User(id=3, name="Charlie", email="charlie@example.com", is_active=False),
    }


# =============================================================================
# FUNCTION-SCOPED FIXTURES
# =============================================================================
# Function scope (the default) guarantees each test gets its own copy,
# preventing cross-test pollution when tests mutate state.


@pytest.fixture()
def user_db(seed_users) -> dict[int, User]:
    """Return a *copy* of seed_users so each test can mutate freely."""
    return {uid: User(**vars(u)) for uid, u in seed_users.items()}


@pytest.fixture()
def service(user_db) -> UserService:
    """UserService wired to the per-test database copy."""
    return UserService(db=user_db)


@pytest.fixture()
def service_with_email(user_db, mocker) -> UserService:
    """UserService with a mocked email client already attached."""
    mock_email = mocker.MagicMock()
    mock_email.send_welcome.return_value = True
    return UserService(db=user_db, email_client=mock_email)


# =============================================================================
# 1. CLASS-BASED TEST ORGANIZATION
# =============================================================================
# Group related tests into classes. No __init__ needed — pytest discovers
# classes whose names start with "Test".


class TestUserLookup:
    """Tests for UserService.get_user()."""

    def test_returns_existing_user(self, service):
        user = service.get_user(1)
        assert user.name == "Alice"
        assert user.email == "alice@example.com"

    def test_raises_on_missing_user(self, service):
        # pytest.raises as context manager — the `match` kwarg checks the
        # exception message against a regex.
        with pytest.raises(LookupError, match=r"User 999 not found"):
            service.get_user(999)

    def test_returns_inactive_user(self, service):
        """get_user() returns inactive users too — filtering is the caller's job."""
        user = service.get_user(3)
        assert user.is_active is False


# =============================================================================
# 2. PARAMETRIZE WITH IDS AND MARKS
# =============================================================================
# @pytest.mark.parametrize generates one test per set of arguments.
# `id` strings make output readable; `marks` let you tag individual cases.


class TestUserCreation:
    """Tests for UserService.create_user()."""

    @pytest.mark.parametrize(
        ("name", "email"),
        [
            pytest.param("Dana", "dana@example.com", id="simple-email"),
            pytest.param("Eve", "eve@sub.domain.org", id="subdomain-email"),
            pytest.param("Frank", "frank+tag@example.com", id="plus-addressed"),
        ],
    )
    def test_create_valid_user(self, service, name, email):
        user = service.create_user(name, email)
        assert user.name == name
        assert user.email == email
        assert user.is_active is True

    @pytest.mark.parametrize(
        "bad_email",
        [
            pytest.param("not-an-email", id="no-at-sign"),
            pytest.param("@missing-local.com", id="empty-local-part"),
            pytest.param("user@", id="empty-domain"),
            pytest.param("", id="empty-string"),
        ],
    )
    def test_rejects_invalid_email(self, service, bad_email):
        with pytest.raises(ValueError, match=r"Invalid email"):
            service.create_user("Test", bad_email)

    @pytest.mark.slow  # mark individual tests for selective execution
    def test_create_many_users_performance(self, service):
        """Ensure bulk creation stays within acceptable bounds."""
        for i in range(500):
            service.create_user(f"User{i}", f"user{i}@example.com")
        assert len(service.db) > 500  # seed_users + new


# =============================================================================
# 3. MOCKING WITH pytest-mock  (mocker fixture)
# =============================================================================


class TestEmailIntegration:
    """Demonstrate mocking with the `mocker` fixture from pytest-mock."""

    def test_sends_welcome_email_on_creation(self, service_with_email):
        service_with_email.create_user("Grace", "grace@example.com")

        # Assert the mock was called with the expected argument.
        service_with_email.email_client.send_welcome.assert_called_once_with(
            "grace@example.com"
        )

    def test_skips_email_when_client_absent(self, service):
        """No email client → no error, no email sent."""
        user = service.create_user("Heidi", "heidi@example.com")
        assert user.name == "Heidi"
        # Nothing to assert on the email client — it's None.

    def test_mock_side_effect(self, service_with_email):
        """Use side_effect to simulate an email service failure."""
        service_with_email.email_client.send_welcome.side_effect = ConnectionError(
            "SMTP unreachable"
        )
        with pytest.raises(ConnectionError, match="SMTP unreachable"):
            service_with_email.create_user("Ivan", "ivan@example.com")


# =============================================================================
# 4. EXCEPTION TESTING PATTERNS
# =============================================================================


class TestExceptionPatterns:
    """Various ways to test exceptions in pytest."""

    def test_raises_with_match(self, service):
        """Use `match` for regex-based message checking."""
        with pytest.raises(LookupError, match=r"User \d+ not found"):
            service.get_user(42)

    def test_inspect_exception_attributes(self, service):
        """Access the exception object via `as exc_info` for richer assertions."""
        with pytest.raises(ValueError) as exc_info:
            service.create_user("Test", "bad-email")

        assert "Invalid email" in str(exc_info.value)
        assert exc_info.type is ValueError

    def test_does_not_raise(self, service):
        """Explicitly verify that no exception is raised (clarity > implicitness)."""
        # If this line raises, the test fails — no special helper needed.
        user = service.get_user(1)
        assert user is not None


# =============================================================================
# 5. ASYNC TEST EXAMPLES  (requires pytest-asyncio)
# =============================================================================
# With asyncio_mode = "auto" in pyproject.toml, every `async def test_*` is
# collected automatically. Otherwise, decorate with @pytest.mark.asyncio.


class TestAsyncOperations:
    """Async test patterns using pytest-asyncio."""

    async def test_fetch_remote_profile(self, service):
        profile = await service.fetch_remote_profile(1)
        assert profile["name"] == "Alice"
        assert profile["source"] == "remote"

    async def test_fetch_remote_missing_user(self, service):
        with pytest.raises(LookupError, match=r"User 404 not found"):
            await service.fetch_remote_profile(404)

    async def test_concurrent_fetches(self, service):
        """Run multiple async operations concurrently."""
        import asyncio

        results = await asyncio.gather(
            service.fetch_remote_profile(1),
            service.fetch_remote_profile(2),
        )
        assert len(results) == 2
        assert {r["name"] for r in results} == {"Alice", "Bob"}


# =============================================================================
# 6. SNAPSHOT TESTING  (requires syrupy)
# =============================================================================
# Snapshot tests capture a "golden" output and compare future runs against it.
# Run `pytest --snapshot-update` to accept new/changed snapshots.


class TestSnapshotPatterns:
    """Snapshot testing with syrupy."""

    def test_user_repr_snapshot(self, service, snapshot):
        """Snapshot the repr of a User for regression detection."""
        user = service.get_user(1)
        assert repr(user) == snapshot

    def test_user_dict_snapshot(self, service, snapshot):
        """Snapshot a serialised dict — useful for API response contracts."""
        user = service.get_user(1)
        user_dict = {
            "id": user.id,
            "name": user.name,
            "email": user.email,
            "is_active": user.is_active,
        }
        assert user_dict == snapshot


# =============================================================================
# 7. FIXTURE USAGE ACROSS SCOPES
# =============================================================================
# This class uses a class-scoped fixture to demonstrate lifecycle differences.


class TestClassScopedFixture:
    """Show that class-scoped fixtures persist across methods in the class."""

    @pytest.fixture(autouse=True, scope="class")
    def _shared_state(self):
        """
        Class-scoped: created once, shared by all test methods in this class.
        Good for expensive setup that tests only *read* (not mutate).
        """
        self.__class__.call_count = 0

    def test_first(self):
        self.__class__.call_count += 1
        assert self.__class__.call_count == 1

    def test_second(self):
        self.__class__.call_count += 1
        # Both methods share the same instance, so count is cumulative.
        assert self.__class__.call_count == 2


# =============================================================================
# 8. ADVANCED PARAMETRIZE — INDIRECT & CONDITIONAL XFAIL
# =============================================================================


@pytest.mark.parametrize(
    ("user_id", "expected_name"),
    [
        pytest.param(1, "Alice", id="active-user"),
        pytest.param(3, "Charlie", id="inactive-user"),
        pytest.param(
            999,
            None,
            id="missing-user",
            marks=pytest.mark.xfail(raises=LookupError, reason="expected miss"),
        ),
    ],
)
def test_lookup_various_users(service, user_id, expected_name):
    """
    xfail marks let you document *known* failure cases in-line without
    skipping them.  If the code is later fixed, pytest alerts you that the
    xfail is no longer needed.
    """
    user = service.get_user(user_id)
    assert user.name == expected_name


# =============================================================================
# 9. MONKEYPATCH & ENVIRONMENT
# =============================================================================


class TestEnvironmentDependentBehaviour:
    """Patterns for testing code that reads env vars or config."""

    def test_debug_mode_enabled(self, monkeypatch):
        monkeypatch.setenv("DEBUG", "1")
        # Simulate code that checks DEBUG
        assert os.environ.get("DEBUG") == "1"

    def test_missing_env_var_uses_default(self, monkeypatch):
        monkeypatch.delenv("DATABASE_URL", raising=False)
        url = os.environ.get("DATABASE_URL", "sqlite:///:memory:")
        assert url == "sqlite:///:memory:"


# ---------------------------------------------------------------------------
# Required import for the environment tests above
# ---------------------------------------------------------------------------
import os  # noqa: E402 — intentionally placed after the class for readability
