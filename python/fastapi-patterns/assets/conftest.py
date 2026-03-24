"""Pytest conftest.py template for FastAPI projects.

Provides:
  - Async test client (httpx)
  - Isolated test database with automatic rollback
  - Auth fixtures (JWT token generation)
  - Factory fixtures for creating test data

Usage: Copy to your tests/ directory. Adjust imports for your project layout.
"""
import asyncio
from collections.abc import AsyncGenerator
from typing import Any
from uuid import uuid4

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import (
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)

from app.core.config import settings
from app.core.database import Base, get_db
from app.core.security import create_access_token
from app.main import app

# ---------------------------------------------------------------------------
# Test database setup
# ---------------------------------------------------------------------------

TEST_DB_URL = "sqlite+aiosqlite:///./test.db"
# For Postgres: "postgresql+asyncpg://test:test@localhost:5432/test_db"

test_engine = create_async_engine(
    TEST_DB_URL,
    connect_args={"check_same_thread": False},  # SQLite only
    echo=False,
)
TestSession = async_sessionmaker(
    bind=test_engine, class_=AsyncSession, expire_on_commit=False
)


# ---------------------------------------------------------------------------
# Session-scoped: create/drop tables once per test session
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def event_loop():
    """Create a single event loop for the entire test session."""
    loop = asyncio.new_event_loop()
    yield loop
    loop.close()


@pytest.fixture(scope="session", autouse=True)
async def setup_database():
    """Create all tables at session start, drop at session end."""
    async with test_engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    yield
    async with test_engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)
    await test_engine.dispose()


# ---------------------------------------------------------------------------
# Per-test fixtures
# ---------------------------------------------------------------------------

@pytest.fixture
async def db_session() -> AsyncGenerator[AsyncSession, None]:
    """Provide a transactional database session that rolls back after each test."""
    async with test_engine.connect() as conn:
        trans = await conn.begin()
        session = AsyncSession(bind=conn, expire_on_commit=False)
        try:
            yield session
        finally:
            await trans.rollback()
            await session.close()


@pytest.fixture
async def client(db_session: AsyncSession) -> AsyncGenerator[AsyncClient, None]:
    """Async HTTP client with database dependency overridden."""
    async def override_get_db():
        yield db_session

    app.dependency_overrides[get_db] = override_get_db

    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
    ) as c:
        yield c

    app.dependency_overrides.clear()


# ---------------------------------------------------------------------------
# Auth fixtures
# ---------------------------------------------------------------------------

@pytest.fixture
def test_user_id() -> str:
    """A stable test user ID."""
    return "test-user-00000000"


@pytest.fixture
def auth_token(test_user_id: str) -> str:
    """A valid JWT token for the test user."""
    return create_access_token(subject=test_user_id)


@pytest.fixture
def auth_headers(auth_token: str) -> dict[str, str]:
    """Authorization headers with a valid Bearer token."""
    return {"Authorization": f"Bearer {auth_token}"}


@pytest.fixture
def admin_headers() -> dict[str, str]:
    """Authorization headers for an admin user."""
    token = create_access_token(subject="admin-user-id")
    return {"Authorization": f"Bearer {token}"}


# ---------------------------------------------------------------------------
# Factory helpers
# ---------------------------------------------------------------------------

@pytest.fixture
def make_auth_headers():
    """Factory to create auth headers for any user ID."""
    def _make(user_id: str = "test-user") -> dict[str, str]:
        token = create_access_token(subject=user_id)
        return {"Authorization": f"Bearer {token}"}
    return _make


# Uncomment and adapt for your models:
#
# @pytest.fixture
# def user_factory(db_session: AsyncSession):
#     """Factory for creating User instances in tests."""
#     async def _create(**kwargs: Any) -> User:
#         defaults = {
#             "email": f"user-{uuid4().hex[:8]}@test.com",
#             "name": "Test User",
#             "is_active": True,
#         }
#         defaults.update(kwargs)
#         user = User(**defaults)
#         db_session.add(user)
#         await db_session.flush()
#         await db_session.refresh(user)
#         return user
#     return _create
