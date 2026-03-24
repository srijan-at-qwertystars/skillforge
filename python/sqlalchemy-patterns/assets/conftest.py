"""
Pytest conftest.py with SQLAlchemy fixtures for both sync and async testing.

Features:
- Session-scoped engine (create tables once)
- Per-test session with transaction rollback (no DB pollution)
- Async variants using pytest-asyncio
- Factory fixture for creating test data

Requirements:
    pip install pytest pytest-asyncio sqlalchemy aiosqlite

Usage:
    def test_create_user(db_session):
        user = User(email="test@example.com", name="Test")
        db_session.add(user)
        db_session.flush()
        assert user.id is not None
        # Transaction rolls back automatically after test

    @pytest.mark.asyncio
    async def test_async_create_user(async_db_session):
        user = User(email="test@example.com", name="Test")
        async_db_session.add(user)
        await async_db_session.flush()
        assert user.id is not None
"""

import pytest
import pytest_asyncio
from sqlalchemy import create_engine, event
from sqlalchemy.ext.asyncio import (
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)
from sqlalchemy.orm import Session, sessionmaker

# Replace with your actual Base import
from myapp.models import Base


# ---------------------------------------------------------------------------
# Sync fixtures
# ---------------------------------------------------------------------------


@pytest.fixture(scope="session")
def engine():
    """Create a test engine (session-scoped — tables created once)."""
    engine = create_engine(
        "sqlite:///:memory:",
        echo=False,
    )
    Base.metadata.create_all(engine)
    yield engine
    Base.metadata.drop_all(engine)
    engine.dispose()


@pytest.fixture()
def db_session(engine):
    """Per-test database session with automatic rollback.

    Uses a nested transaction pattern:
    1. Open a connection and begin a transaction.
    2. Bind the session to this connection.
    3. After the test, roll back the transaction — all changes are discarded.
    """
    connection = engine.connect()
    transaction = connection.begin()
    session = Session(bind=connection, join_transaction_block=True)

    # If the test code calls session.commit(), restart a nested transaction
    # so the outer transaction can still be rolled back.
    nested = connection.begin_nested()

    @event.listens_for(session, "after_transaction_end")
    def restart_savepoint(session, transaction_end):
        nonlocal nested
        if transaction_end.nested and not transaction_end._parent.nested:
            nested = connection.begin_nested()

    yield session

    session.close()
    transaction.rollback()
    connection.close()


# ---------------------------------------------------------------------------
# Async fixtures
# ---------------------------------------------------------------------------


@pytest_asyncio.fixture(scope="session")
async def async_engine():
    """Create an async test engine (session-scoped)."""
    engine = create_async_engine(
        "sqlite+aiosqlite:///:memory:",
        echo=False,
    )
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    yield engine

    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)
    await engine.dispose()


@pytest_asyncio.fixture()
async def async_db_session(async_engine):
    """Per-test async session with automatic rollback."""
    async with async_engine.connect() as connection:
        transaction = await connection.begin()
        session = AsyncSession(
            bind=connection,
            expire_on_commit=False,
            join_transaction_block=True,
        )

        nested = await connection.begin_nested()

        @event.listens_for(session.sync_session, "after_transaction_end")
        def restart_savepoint(sync_session, transaction_end):
            nonlocal nested
            if transaction_end.nested and not transaction_end._parent.nested:
                # Use run_sync-compatible savepoint restart
                nonlocal connection
                nested = connection.sync_connection.begin_nested()

        yield session

        await session.close()
        await transaction.rollback()


# ---------------------------------------------------------------------------
# Factory fixtures
# ---------------------------------------------------------------------------


@pytest.fixture()
def user_factory(db_session):
    """Factory for creating test users.

    Usage:
        def test_something(user_factory):
            user = user_factory(name="Alice")
            assert user.id is not None
    """
    from myapp.models import User  # import your model

    def _create_user(**kwargs):
        defaults = {
            "email": f"user_{id(kwargs)}@test.com",
            "name": "Test User",
        }
        defaults.update(kwargs)
        user = User(**defaults)
        db_session.add(user)
        db_session.flush()
        return user

    return _create_user


@pytest_asyncio.fixture()
async def async_user_factory(async_db_session):
    """Async factory for creating test users."""
    from myapp.models import User

    async def _create_user(**kwargs):
        defaults = {
            "email": f"user_{id(kwargs)}@test.com",
            "name": "Test User",
        }
        defaults.update(kwargs)
        user = User(**defaults)
        async_db_session.add(user)
        await async_db_session.flush()
        return user

    return _create_user
