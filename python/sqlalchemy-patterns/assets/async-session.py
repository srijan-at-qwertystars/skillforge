"""
Async session factory with proper lifecycle management.

Provides:
- Engine creation with sensible pool defaults
- Session factory with expire_on_commit=False
- FastAPI dependency for per-request sessions
- Proper startup/shutdown lifecycle
- Context manager for standalone usage

Usage:
    from myapp.db import db

    # At startup
    db.init("postgresql+asyncpg://user:pass@localhost/mydb")

    # FastAPI
    app = FastAPI(lifespan=db.lifespan)

    @app.get("/users/{user_id}")
    async def get_user(user_id: int, session: AsyncSession = Depends(db.get_session)):
        return await session.get(User, user_id)

    # Standalone
    async with db.session() as session:
        user = await session.get(User, 1)
"""

import os
from contextlib import asynccontextmanager
from typing import AsyncGenerator

from sqlalchemy.ext.asyncio import (
    AsyncEngine,
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)


class Database:
    """Manages async engine and session lifecycle."""

    def __init__(self) -> None:
        self._engine: AsyncEngine | None = None
        self._session_factory: async_sessionmaker[AsyncSession] | None = None

    def init(
        self,
        url: str | None = None,
        *,
        pool_size: int = 10,
        max_overflow: int = 20,
        pool_pre_ping: bool = True,
        pool_recycle: int = 3600,
        echo: bool = False,
    ) -> None:
        """Initialize the async engine and session factory.

        Args:
            url: Database URL. Falls back to DATABASE_URL env var.
            pool_size: Number of persistent connections in the pool.
            max_overflow: Max temporary connections above pool_size.
            pool_pre_ping: Test connections before use (detects stale).
            pool_recycle: Seconds before recycling a connection.
            echo: Log all SQL statements (dev only).
        """
        database_url = url or os.environ.get("DATABASE_URL")
        if not database_url:
            raise ValueError("Database URL required. Pass url= or set DATABASE_URL env var.")

        self._engine = create_async_engine(
            database_url,
            pool_size=pool_size,
            max_overflow=max_overflow,
            pool_pre_ping=pool_pre_ping,
            pool_recycle=pool_recycle,
            echo=echo,
        )

        self._session_factory = async_sessionmaker(
            bind=self._engine,
            class_=AsyncSession,
            expire_on_commit=False,  # prevent DetachedInstanceError in async
            autoflush=True,
            autocommit=False,
        )

    @property
    def engine(self) -> AsyncEngine:
        if self._engine is None:
            raise RuntimeError("Database not initialized. Call db.init() first.")
        return self._engine

    @property
    def session_factory(self) -> async_sessionmaker[AsyncSession]:
        if self._session_factory is None:
            raise RuntimeError("Database not initialized. Call db.init() first.")
        return self._session_factory

    @asynccontextmanager
    async def session(self) -> AsyncGenerator[AsyncSession, None]:
        """Context manager for a database session with auto-commit/rollback.

        Usage:
            async with db.session() as session:
                user = await session.get(User, 1)
                user.name = "Updated"
            # auto-commits on clean exit, rolls back on exception
        """
        async with self.session_factory() as session:
            try:
                yield session
                await session.commit()
            except Exception:
                await session.rollback()
                raise

    async def get_session(self) -> AsyncGenerator[AsyncSession, None]:
        """FastAPI dependency that yields a session per request.

        Usage:
            @app.get("/users/{id}")
            async def get_user(id: int, session: AsyncSession = Depends(db.get_session)):
                return await session.get(User, id)
        """
        async with self.session() as session:
            yield session

    async def dispose(self) -> None:
        """Dispose of the engine and release all connections.

        Call on application shutdown.
        """
        if self._engine is not None:
            await self._engine.dispose()
            self._engine = None
            self._session_factory = None

    @asynccontextmanager
    async def lifespan(self, app):  # noqa: ANN001
        """FastAPI lifespan context manager.

        Usage:
            app = FastAPI(lifespan=db.lifespan)
        """
        yield
        await self.dispose()


# Module-level singleton
db = Database()
