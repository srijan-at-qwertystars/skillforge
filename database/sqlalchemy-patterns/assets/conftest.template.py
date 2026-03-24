"""
Pytest fixtures for SQLAlchemy testing.

Provides:
- Sync and async session fixtures
- Transaction rollback per test (fast, isolated)
- In-memory SQLite for unit tests
- Real database option for integration tests
- Factory fixtures for test data

Usage:
    Copy to tests/conftest.py in your project.
    Adjust the Base import at the top.

Requirements:
    pip install pytest pytest-asyncio sqlalchemy aiosqlite
"""

import os
from typing import Generator

import pytest

# ---------------------------------------------------------------------------
# CONFIGURE: Import your Base
# ---------------------------------------------------------------------------
# from myapp.models.base import Base
from sqlalchemy.orm import DeclarativeBase


class Base(DeclarativeBase):
    """Placeholder — replace with your actual Base import."""

    pass


# ===========================================================================
# SYNC FIXTURES
# ===========================================================================

from sqlalchemy import create_engine, event
from sqlalchemy.orm import Session, sessionmaker

# Use real DB for integration tests if DATABASE_URL is set
TEST_DATABASE_URL = os.environ.get("TEST_DATABASE_URL", "sqlite:///:memory:")


@pytest.fixture(scope="session")
def engine():
    """Create engine once per test session."""
    engine = create_engine(
        TEST_DATABASE_URL,
        echo=os.environ.get("SQL_ECHO", "false").lower() == "true",
    )
    Base.metadata.create_all(engine)
    yield engine
    Base.metadata.drop_all(engine)
    engine.dispose()


@pytest.fixture
def db_session(engine) -> Generator[Session, None, None]:
    """Transaction-scoped session — auto-rolls back after each test.

    This is the recommended pattern for fast, isolated tests:
    - Each test runs inside a transaction
    - The transaction is rolled back after the test
    - No data persists between tests
    - Much faster than recreating tables
    """
    connection = engine.connect()
    transaction = connection.begin()
    session = Session(bind=connection)

    # Handle nested transactions (savepoints) within tests
    @event.listens_for(session, "after_transaction_end")
    def restart_savepoint(session, transaction):
        if transaction.nested and not transaction._parent.nested:
            session.begin_nested()

    yield session

    session.close()
    transaction.rollback()
    connection.close()


@pytest.fixture
def db_session_committed(engine) -> Generator[Session, None, None]:
    """Session that actually commits — use for integration tests.

    WARNING: Data persists! Clean up in teardown.
    """
    session = sessionmaker(bind=engine, expire_on_commit=False)()
    yield session
    session.rollback()
    session.close()
    # Clean up: truncate all tables
    with engine.begin() as conn:
        for table in reversed(Base.metadata.sorted_tables):
            conn.execute(table.delete())


# ===========================================================================
# ASYNC FIXTURES
# ===========================================================================

try:
    import pytest_asyncio
    from sqlalchemy.ext.asyncio import (
        AsyncSession,
        async_sessionmaker,
        create_async_engine,
    )

    ASYNC_TEST_URL = os.environ.get(
        "TEST_DATABASE_URL_ASYNC", "sqlite+aiosqlite:///:memory:"
    )

    @pytest_asyncio.fixture(scope="session")
    async def async_engine():
        """Create async engine once per test session."""
        engine = create_async_engine(ASYNC_TEST_URL, echo=False)
        async with engine.begin() as conn:
            await conn.run_sync(Base.metadata.create_all)
        yield engine
        async with engine.begin() as conn:
            await conn.run_sync(Base.metadata.drop_all)
        await engine.dispose()

    @pytest_asyncio.fixture
    async def async_db_session(async_engine) -> AsyncSession:
        """Async session with transaction rollback per test."""
        async with async_engine.connect() as connection:
            transaction = await connection.begin()
            session = AsyncSession(bind=connection, expire_on_commit=False)
            yield session
            await session.close()
            await transaction.rollback()

except ImportError:
    pass  # pytest-asyncio or aiosqlite not installed


# ===========================================================================
# FACTORY FIXTURES
# ===========================================================================


class ModelFactory:
    """Generic factory for creating test model instances.

    Usage in tests:
        def test_user(factory, db_session):
            user = factory.create(User, name="Alice", email="alice@test.com")
            assert user.id is not None
    """

    def __init__(self, session: Session):
        self.session = session

    def create(self, model_class, **kwargs):
        """Create and flush a model instance."""
        obj = model_class(**kwargs)
        self.session.add(obj)
        self.session.flush()
        return obj

    def create_batch(self, model_class, count: int, **kwargs):
        """Create multiple instances with the same kwargs."""
        objects = [model_class(**kwargs) for _ in range(count)]
        self.session.add_all(objects)
        self.session.flush()
        return objects


@pytest.fixture
def factory(db_session) -> ModelFactory:
    """Model factory bound to the test session."""
    return ModelFactory(db_session)


# ===========================================================================
# QUERY COUNTER (for N+1 detection in tests)
# ===========================================================================


class QueryCounter:
    """Count SQL queries executed during a block.

    Usage:
        def test_no_n_plus_one(db_session, query_counter):
            with query_counter:
                users = db_session.scalars(
                    select(User).options(selectinload(User.posts))
                ).all()
                for u in users:
                    _ = u.posts
            assert query_counter.count <= 2  # 1 for users + 1 for posts
    """

    def __init__(self, engine):
        self.engine = engine
        self.count = 0
        self._listener = None

    def _on_execute(self, conn, cursor, statement, parameters, context, executemany):
        self.count += 1

    def __enter__(self):
        self.count = 0
        event.listen(self.engine, "before_cursor_execute", self._on_execute)
        return self

    def __exit__(self, *args):
        event.remove(self.engine, "before_cursor_execute", self._on_execute)


@pytest.fixture
def query_counter(engine) -> QueryCounter:
    """Query counter for N+1 detection."""
    return QueryCounter(engine)
