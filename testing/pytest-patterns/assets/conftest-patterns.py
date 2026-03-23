"""
Comprehensive conftest.py template — common pytest fixture patterns.

Copy the fixtures you need into your project's conftest.py and adapt them
to your stack.  Each fixture includes comments explaining *why* a particular
scope or teardown strategy was chosen.
"""

from __future__ import annotations

import os
import tempfile
from collections.abc import AsyncGenerator, Generator
from pathlib import Path
from typing import Any
from unittest.mock import MagicMock

import pytest


# =============================================================================
# 1. DATABASE SESSION FIXTURE  (scope: function)
# =============================================================================
# Function-scoped so every test starts with a clean transaction.
# The SAVEPOINT / ROLLBACK strategy avoids slow CREATE/DROP cycles while
# keeping tests fully isolated.


@pytest.fixture()
def db_session():
    """
    Provide a transactional database session that rolls back after each test.

    Uses nested transactions (SAVEPOINT) so the test can call session.commit()
    without actually persisting data.
    """
    from sqlalchemy import create_engine
    from sqlalchemy.orm import Session

    engine = create_engine("sqlite:///:memory:")

    # Create tables — swap with your Base.metadata for real projects.
    # Base.metadata.create_all(engine)

    connection = engine.connect()
    transaction = connection.begin()

    # Bind a session to the *connection* so we control the outer transaction.
    session = Session(bind=connection)

    # Start a SAVEPOINT so `session.commit()` inside tests doesn't break
    # the outer rollback.
    session.begin_nested()

    yield session

    # Teardown: roll back the outer transaction — nothing is persisted.
    session.close()
    transaction.rollback()
    connection.close()
    engine.dispose()


# =============================================================================
# 2. TEST CLIENT FIXTURES  (scope: function)
# =============================================================================
# Function-scoped because client state (cookies, headers) should not leak
# between tests.


# --- FastAPI ---
@pytest.fixture()
def fastapi_client(db_session):
    """
    Create a FastAPI TestClient with the DB session overridden.

    The `db_session` fixture is injected so every request uses the same
    transactional session that will be rolled back.
    """
    from fastapi.testclient import TestClient

    from myapp.main import app  # adjust import to your project
    from myapp.deps import get_db  # your dependency function

    def _override_get_db():
        yield db_session

    app.dependency_overrides[get_db] = _override_get_db

    with TestClient(app) as client:
        yield client

    # Clean up overrides so other tests aren't affected.
    app.dependency_overrides.clear()


# --- Flask ---
@pytest.fixture()
def flask_client():
    """
    Create a Flask test client with testing mode enabled.
    """
    from myapp import create_app  # adjust import

    app = create_app(testing=True)
    app.config["TESTING"] = True

    with app.test_client() as client:
        with app.app_context():
            yield client


# =============================================================================
# 3. AUTHENTICATED USER FIXTURE  (scope: function)
# =============================================================================
# Depends on the client fixture so you can make requests as a logged-in user.


@pytest.fixture()
def auth_headers(fastapi_client) -> dict[str, str]:
    """
    Register + log in a test user and return authorization headers.

    Reuse these headers in tests that require authentication:
        response = fastapi_client.get("/me", headers=auth_headers)
    """
    user_data = {
        "email": "test@example.com",
        "password": "S3cure!Pass",
        "name": "Test User",
    }
    fastapi_client.post("/auth/register", json=user_data)

    login_resp = fastapi_client.post(
        "/auth/login",
        json={"email": user_data["email"], "password": user_data["password"]},
    )
    token = login_resp.json()["access_token"]
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture()
def authenticated_client(fastapi_client, auth_headers):
    """
    A convenience fixture that returns the client *and* headers together.
    Useful when most tests in a module need auth.
    """
    fastapi_client.headers.update(auth_headers)
    yield fastapi_client


# =============================================================================
# 4. TEMP DIRECTORY & FILE FIXTURES  (scope: function)
# =============================================================================
# Use `tmp_path` (built-in) when possible. These fixtures add common patterns
# on top of it.


@pytest.fixture()
def sample_csv(tmp_path: Path) -> Path:
    """
    Write a sample CSV to a temp directory and return the path.

    `tmp_path` is built-in and function-scoped — each test gets its own
    temporary directory that is cleaned up automatically.
    """
    csv_file = tmp_path / "data.csv"
    csv_file.write_text(
        "id,name,score\n"
        "1,Alice,95\n"
        "2,Bob,87\n"
        "3,Charlie,72\n"
    )
    return csv_file


@pytest.fixture()
def populated_dir(tmp_path: Path) -> Path:
    """
    Create a temp directory tree for tests that walk or glob directories.
    """
    (tmp_path / "subdir").mkdir()
    (tmp_path / "subdir" / "nested.txt").write_text("nested content")
    (tmp_path / "readme.md").write_text("# Hello")
    (tmp_path / "config.json").write_text('{"debug": true}')
    return tmp_path


# =============================================================================
# 5. ENVIRONMENT VARIABLE FIXTURES  (scope: function)
# =============================================================================
# Always restore originals in teardown to prevent cross-test pollution.


@pytest.fixture()
def env_vars(monkeypatch) -> None:
    """
    Set environment variables for the duration of a single test.

    Uses `monkeypatch` (built-in) which automatically restores originals.
    Prefer this over manually patching os.environ.
    """
    monkeypatch.setenv("DATABASE_URL", "sqlite:///:memory:")
    monkeypatch.setenv("SECRET_KEY", "test-secret-key-do-not-use-in-prod")
    monkeypatch.setenv("DEBUG", "1")
    monkeypatch.setenv("LOG_LEVEL", "DEBUG")


@pytest.fixture()
def clean_env(monkeypatch) -> None:
    """
    Remove potentially interfering env vars so tests run in a known state.
    """
    for var in ("DATABASE_URL", "SECRET_KEY", "AWS_ACCESS_KEY_ID"):
        monkeypatch.delenv(var, raising=False)


# =============================================================================
# 6. MOCK SERVICE FIXTURES  (scope: function)
# =============================================================================
# Encapsulate common mocks so tests don't repeat boilerplate.


@pytest.fixture()
def mock_email_service(mocker) -> MagicMock:
    """
    Replace the email service with a mock.  Returns the mock so tests can
    assert on calls:
        mock_email_service.send.assert_called_once_with(...)

    `mocker` comes from the pytest-mock plugin and patches are automatically
    undone after the test.
    """
    mock = mocker.patch("myapp.services.email.EmailService")
    instance = mock.return_value
    instance.send.return_value = {"status": "sent", "message_id": "test-123"}
    return instance


@pytest.fixture()
def mock_http_client(mocker) -> MagicMock:
    """
    Mock an HTTP client (e.g. httpx.AsyncClient) to avoid real network calls.
    """
    mock = mocker.patch("myapp.clients.http.AsyncClient")
    instance = mock.return_value.__aenter__.return_value
    instance.get.return_value = MagicMock(
        status_code=200,
        json=lambda: {"ok": True},
    )
    return instance


@pytest.fixture()
def mock_cache(mocker) -> MagicMock:
    """
    Replace Redis/cache backend with a simple dict-backed mock.
    """
    store: dict[str, Any] = {}
    mock = mocker.patch("myapp.cache.redis_client")
    mock.get = MagicMock(side_effect=lambda k: store.get(k))
    mock.set = MagicMock(side_effect=lambda k, v, **kw: store.__setitem__(k, v))
    mock.delete = MagicMock(side_effect=lambda k: store.pop(k, None))
    return mock


# =============================================================================
# 7. FIXTURE COMPOSITION  (scope: varies)
# =============================================================================
# Higher-level fixtures that combine simpler ones. This keeps individual
# tests clean — they request one fixture instead of five.


@pytest.fixture()
def full_test_context(
    db_session,
    fastapi_client,
    auth_headers,
    mock_email_service,
    env_vars,
):
    """
    An all-in-one context for integration tests that need everything.

    Fixture composition lets you build 'scenarios' without repeating setup
    logic in every test function.
    """

    class _Context:
        session = db_session
        client = fastapi_client
        headers = auth_headers
        email = mock_email_service

    return _Context()


# =============================================================================
# 8. SESSION-SCOPED FIXTURES  (scope: session)
# =============================================================================
# Expensive, read-only resources that are safe to share across all tests.


@pytest.fixture(scope="session")
def test_data_dir() -> Path:
    """
    Return the path to the static test data directory.

    Session-scoped because the directory is read-only — no risk of one test
    affecting another.
    """
    return Path(__file__).parent / "data"


@pytest.fixture(scope="session")
def large_dataset(test_data_dir: Path) -> list[dict[str, Any]]:
    """
    Load a large JSON dataset once for the entire test run.

    Parsing is slow, so session scope avoids doing it N times.
    """
    import json

    data_file = test_data_dir / "large_dataset.json"
    if data_file.exists():
        return json.loads(data_file.read_text())
    return []


# =============================================================================
# 9. ASYNC FIXTURES  (requires pytest-asyncio)
# =============================================================================


@pytest.fixture()
async def async_db_session() -> AsyncGenerator:
    """
    Async version of the database session fixture.

    Works with async ORMs like SQLAlchemy 2.0 async or Tortoise.
    """
    from sqlalchemy.ext.asyncio import AsyncSession, create_async_engine

    engine = create_async_engine("sqlite+aiosqlite:///:memory:")

    async with AsyncSession(engine) as session:
        async with session.begin():
            yield session
            # Rollback happens automatically when the context exits
            # without a commit.

    await engine.dispose()


# =============================================================================
# 10. AUTOUSE FIXTURES  (scope: function)
# =============================================================================
# autouse=True means the fixture runs for *every* test in its scope without
# being explicitly requested. Use sparingly — implicit behaviour can surprise.


@pytest.fixture(autouse=True)
def _reset_caches():
    """
    Clear application-level caches between tests.

    autouse is appropriate here because stale caches are a common source of
    flaky tests, and every test benefits from a clean slate.
    """
    # Example: myapp.cache.clear()
    yield
    # Teardown: clear again in case a test populated the cache.
    # myapp.cache.clear()


@pytest.fixture(autouse=True)
def _freeze_time(request):
    """
    Optionally freeze time for tests marked with @pytest.mark.freeze_time.

    Shows how to combine autouse with marker-based opt-in behaviour.
    """
    marker = request.node.get_closest_marker("freeze_time")
    if marker is None:
        yield
        return

    import freezegun

    frozen = marker.args[0] if marker.args else "2024-01-15T12:00:00Z"
    with freezegun.freeze_time(frozen):
        yield
