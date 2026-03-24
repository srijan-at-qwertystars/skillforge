# FastAPI Database Patterns

## Table of Contents

- [Async SQLAlchemy 2.0 Setup](#async-sqlalchemy-20-setup)
  - [AsyncSession and Async Engine](#asyncsession-and-async-engine)
  - [Declarative Models](#declarative-models)
- [Repository Pattern](#repository-pattern)
- [Unit of Work Pattern](#unit-of-work-pattern)
- [Migrations with Alembic](#migrations-with-alembic)
- [Connection Pooling](#connection-pooling)
- [Read Replicas](#read-replicas)
- [Soft Deletes](#soft-deletes)
- [Pagination (Cursor vs Offset)](#pagination-cursor-vs-offset)
- [Bulk Operations](#bulk-operations)
- [Raw SQL](#raw-sql)
- [Database Testing Fixtures](#database-testing-fixtures)
- [Multi-Database Setup](#multi-database-setup)

---

## Async SQLAlchemy 2.0 Setup

### AsyncSession and Async Engine

```python
from sqlalchemy.ext.asyncio import (
    create_async_engine,
    async_sessionmaker,
    AsyncSession,
    AsyncEngine,
)
from sqlalchemy.orm import DeclarativeBase

# Engine — one per application
engine: AsyncEngine = create_async_engine(
    "postgresql+asyncpg://user:pass@localhost:5432/mydb",
    pool_size=10,
    max_overflow=20,
    pool_pre_ping=True,       # Verify connections before use
    pool_recycle=3600,         # Recycle connections after 1 hour
    echo=False,                # Set True for SQL logging in dev
)

# Session factory — creates sessions per request
SessionLocal = async_sessionmaker(
    bind=engine,
    class_=AsyncSession,
    expire_on_commit=False,    # Required for async — prevents lazy load errors
)

# FastAPI dependency
async def get_db() -> AsyncGenerator[AsyncSession, None]:
    async with SessionLocal() as session:
        yield session
```

### Declarative Models

```python
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship
from sqlalchemy import String, ForeignKey, DateTime, func
from datetime import datetime

class Base(DeclarativeBase):
    pass

class TimestampMixin:
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )

class User(TimestampMixin, Base):
    __tablename__ = "users"

    id: Mapped[int] = mapped_column(primary_key=True)
    email: Mapped[str] = mapped_column(String(255), unique=True, index=True)
    name: Mapped[str] = mapped_column(String(100))
    is_active: Mapped[bool] = mapped_column(default=True)

    posts: Mapped[list["Post"]] = relationship(back_populates="author", lazy="selectin")

class Post(TimestampMixin, Base):
    __tablename__ = "posts"

    id: Mapped[int] = mapped_column(primary_key=True)
    title: Mapped[str] = mapped_column(String(200))
    content: Mapped[str]
    author_id: Mapped[int] = mapped_column(ForeignKey("users.id"))

    author: Mapped["User"] = relationship(back_populates="posts")
```

---

## Repository Pattern

Encapsulate data access behind a clean interface. Keeps business logic independent of ORM.

```python
from sqlalchemy import select, func
from sqlalchemy.ext.asyncio import AsyncSession
from typing import Generic, TypeVar, Type

T = TypeVar("T", bound=Base)

class BaseRepository(Generic[T]):
    """Generic repository with common CRUD operations."""

    def __init__(self, session: AsyncSession, model: Type[T]):
        self.session = session
        self.model = model

    async def get_by_id(self, id: int) -> T | None:
        return await self.session.get(self.model, id)

    async def get_all(
        self, *, offset: int = 0, limit: int = 100
    ) -> list[T]:
        result = await self.session.execute(
            select(self.model).offset(offset).limit(limit)
        )
        return list(result.scalars().all())

    async def create(self, **kwargs) -> T:
        instance = self.model(**kwargs)
        self.session.add(instance)
        await self.session.flush()  # Get ID without committing
        await self.session.refresh(instance)
        return instance

    async def update(self, id: int, **kwargs) -> T | None:
        instance = await self.get_by_id(id)
        if not instance:
            return None
        for key, value in kwargs.items():
            setattr(instance, key, value)
        await self.session.flush()
        await self.session.refresh(instance)
        return instance

    async def delete(self, id: int) -> bool:
        instance = await self.get_by_id(id)
        if not instance:
            return False
        await self.session.delete(instance)
        await self.session.flush()
        return True

    async def count(self) -> int:
        result = await self.session.execute(
            select(func.count()).select_from(self.model)
        )
        return result.scalar_one()


class UserRepository(BaseRepository[User]):
    def __init__(self, session: AsyncSession):
        super().__init__(session, User)

    async def get_by_email(self, email: str) -> User | None:
        result = await self.session.execute(
            select(User).where(User.email == email)
        )
        return result.scalar_one_or_none()

    async def get_active_users(self) -> list[User]:
        result = await self.session.execute(
            select(User).where(User.is_active == True)
        )
        return list(result.scalars().all())

    async def search(self, query: str) -> list[User]:
        result = await self.session.execute(
            select(User).where(
                User.name.ilike(f"%{query}%") | User.email.ilike(f"%{query}%")
            )
        )
        return list(result.scalars().all())


# FastAPI dependency
def get_user_repo(db: AsyncSession = Depends(get_db)) -> UserRepository:
    return UserRepository(db)

@router.get("/users/{user_id}")
async def get_user(user_id: int, repo: UserRepository = Depends(get_user_repo)):
    user = await repo.get_by_id(user_id)
    if not user:
        raise HTTPException(404, "User not found")
    return user
```

---

## Unit of Work Pattern

Coordinate multiple repositories within a single transaction.

```python
class UnitOfWork:
    def __init__(self, session_factory: async_sessionmaker):
        self.session_factory = session_factory

    async def __aenter__(self):
        self.session = self.session_factory()
        self.users = UserRepository(self.session)
        self.posts = PostRepository(self.session)
        return self

    async def __aexit__(self, exc_type, exc_val, exc_tb):
        if exc_type:
            await self.rollback()
        await self.session.close()

    async def commit(self):
        await self.session.commit()

    async def rollback(self):
        await self.session.rollback()


# Usage in FastAPI
async def get_uow() -> AsyncGenerator[UnitOfWork, None]:
    async with UnitOfWork(SessionLocal) as uow:
        yield uow

@router.post("/users/{user_id}/posts")
async def create_user_post(
    user_id: int,
    post_data: PostCreate,
    uow: UnitOfWork = Depends(get_uow),
):
    user = await uow.users.get_by_id(user_id)
    if not user:
        raise HTTPException(404, "User not found")

    post = await uow.posts.create(
        title=post_data.title,
        content=post_data.content,
        author_id=user.id,
    )
    await uow.commit()
    return post
```

---

## Migrations with Alembic

### Initial Setup

```bash
pip install alembic
alembic init alembic
```

### Async Alembic Configuration

```python
# alembic/env.py
import asyncio
from logging.config import fileConfig
from sqlalchemy.ext.asyncio import create_async_engine
from alembic import context
from app.database import Base
from app.config import settings

config = context.config
if config.config_file_name is not None:
    fileConfig(config.config_file_name)

target_metadata = Base.metadata

def run_migrations_offline():
    url = settings.database_url
    context.configure(url=url, target_metadata=target_metadata, literal_binds=True)
    with context.begin_transaction():
        context.run_migrations()

def do_run_migrations(connection):
    context.configure(connection=connection, target_metadata=target_metadata)
    with context.begin_transaction():
        context.run_migrations()

async def run_migrations_online():
    engine = create_async_engine(settings.database_url)
    async with engine.connect() as connection:
        await connection.run_sync(do_run_migrations)
    await engine.dispose()

if context.is_offline_mode():
    run_migrations_offline()
else:
    asyncio.run(run_migrations_online())
```

### Common Alembic Commands

```bash
# Generate migration from model changes
alembic revision --autogenerate -m "add users table"

# Apply all pending migrations
alembic upgrade head

# Rollback one migration
alembic downgrade -1

# Show current revision
alembic current

# Show migration history
alembic history --verbose

# Generate empty migration for custom SQL
alembic revision -m "add index on email"
```

### Data Migration Example

```python
# alembic/versions/xxxx_backfill_slugs.py
from alembic import op
import sqlalchemy as sa

def upgrade():
    conn = op.get_bind()
    # Backfill slug from title
    result = conn.execute(sa.text("SELECT id, title FROM posts WHERE slug IS NULL"))
    for row in result:
        slug = row.title.lower().replace(" ", "-")
        conn.execute(
            sa.text("UPDATE posts SET slug = :slug WHERE id = :id"),
            {"slug": slug, "id": row.id},
        )

def downgrade():
    op.execute("UPDATE posts SET slug = NULL")
```

---

## Connection Pooling

### Configuration Guide

```python
engine = create_async_engine(
    "postgresql+asyncpg://user:pass@localhost/db",

    # Pool sizing — tune based on workload
    pool_size=10,          # Steady-state connections (default: 5)
    max_overflow=20,       # Extra connections under load (default: 10)
    # Total max connections = pool_size + max_overflow = 30

    # Health checks
    pool_pre_ping=True,    # Test connection before use (catches stale connections)
    pool_recycle=3600,     # Recreate connections after 1 hour

    # Timeouts
    pool_timeout=30,       # Wait up to 30s for a connection from the pool

    # For debugging
    echo_pool="debug",     # Log pool checkout/checkin events
)
```

### Sizing Guidelines

```
Minimum connections (pool_size):
  - Low traffic:      2-5
  - Medium traffic:    5-15
  - High traffic:      15-30
  
Max connections (pool_size + max_overflow):
  - Should not exceed PostgreSQL max_connections / num_app_instances
  - PostgreSQL default max_connections = 100
  - With 4 app instances: max 25 connections each

Formula: pool_size = num_concurrent_requests * avg_query_duration / avg_request_duration
```

### Monitoring Pool Status

```python
@router.get("/debug/pool", include_in_schema=False)
async def pool_status():
    pool = engine.pool
    return {
        "pool_size": pool.size(),
        "checked_in": pool.checkedin(),
        "checked_out": pool.checkedout(),
        "overflow": pool.overflow(),
    }
```

---

## Read Replicas

### Routing Reads to Replica

```python
from sqlalchemy.ext.asyncio import create_async_engine, async_sessionmaker

write_engine = create_async_engine("postgresql+asyncpg://user:pass@primary/db")
read_engine = create_async_engine("postgresql+asyncpg://user:pass@replica/db")

WriteSession = async_sessionmaker(bind=write_engine, class_=AsyncSession, expire_on_commit=False)
ReadSession = async_sessionmaker(bind=read_engine, class_=AsyncSession, expire_on_commit=False)

async def get_write_db() -> AsyncGenerator[AsyncSession, None]:
    async with WriteSession() as session:
        yield session

async def get_read_db() -> AsyncGenerator[AsyncSession, None]:
    async with ReadSession() as session:
        yield session

# Use read replica for GET endpoints
@router.get("/users/")
async def list_users(db: AsyncSession = Depends(get_read_db)):
    return (await db.execute(select(User))).scalars().all()

# Use primary for writes
@router.post("/users/")
async def create_user(data: UserCreate, db: AsyncSession = Depends(get_write_db)):
    user = User(**data.model_dump())
    db.add(user)
    await db.commit()
    return user
```

### Automatic Read/Write Routing

```python
class RoutingSession:
    """Dependency that provides read or write session based on HTTP method."""

    @staticmethod
    async def for_request(request: Request) -> AsyncGenerator[AsyncSession, None]:
        if request.method in ("GET", "HEAD", "OPTIONS"):
            async with ReadSession() as session:
                yield session
        else:
            async with WriteSession() as session:
                try:
                    yield session
                    await session.commit()
                except Exception:
                    await session.rollback()
                    raise

@router.get("/users/")
async def list_users(db: AsyncSession = Depends(RoutingSession.for_request)):
    ...
```

---

## Soft Deletes

### Mixin for Soft Deletes

```python
from sqlalchemy import DateTime, func, event
from sqlalchemy.orm import Mapped, mapped_column, Query
from datetime import datetime

class SoftDeleteMixin:
    deleted_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), default=None, index=True
    )

    @property
    def is_deleted(self) -> bool:
        return self.deleted_at is not None

class User(SoftDeleteMixin, TimestampMixin, Base):
    __tablename__ = "users"
    id: Mapped[int] = mapped_column(primary_key=True)
    email: Mapped[str] = mapped_column(String(255), unique=True)
    name: Mapped[str] = mapped_column(String(100))
```

### Repository with Soft Delete Support

```python
class SoftDeleteRepository(BaseRepository[T]):
    async def get_all(self, *, include_deleted: bool = False, **kwargs) -> list[T]:
        query = select(self.model)
        if not include_deleted and hasattr(self.model, "deleted_at"):
            query = query.where(self.model.deleted_at.is_(None))
        return list((await self.session.execute(query)).scalars().all())

    async def soft_delete(self, id: int) -> bool:
        instance = await self.get_by_id(id)
        if not instance:
            return False
        instance.deleted_at = func.now()
        await self.session.flush()
        return True

    async def restore(self, id: int) -> T | None:
        instance = await self.get_by_id(id)
        if not instance:
            return None
        instance.deleted_at = None
        await self.session.flush()
        return instance
```

---

## Pagination (Cursor vs Offset)

### Offset Pagination (Simple, Not for Large Tables)

```python
from pydantic import BaseModel

class PaginatedResponse(BaseModel, Generic[T]):
    items: list[T]
    total: int
    page: int
    pages: int

async def paginate_offset(
    session: AsyncSession,
    query,
    page: int = 1,
    size: int = 20,
) -> PaginatedResponse:
    # Count total
    count_query = select(func.count()).select_from(query.subquery())
    total = (await session.execute(count_query)).scalar_one()

    # Fetch page
    items = (
        await session.execute(query.offset((page - 1) * size).limit(size))
    ).scalars().all()

    return PaginatedResponse(
        items=items,
        total=total,
        page=page,
        pages=(total + size - 1) // size,
    )

@router.get("/users/")
async def list_users(
    page: int = Query(1, ge=1),
    size: int = Query(20, ge=1, le=100),
    db: AsyncSession = Depends(get_db),
):
    query = select(User).where(User.is_active == True).order_by(User.id)
    return await paginate_offset(db, query, page, size)
```

### Cursor Pagination (Preferred for Large Datasets)

```python
from pydantic import BaseModel
from typing import Any

class CursorPage(BaseModel, Generic[T]):
    items: list[T]
    next_cursor: str | None
    has_more: bool

import base64, json

def encode_cursor(data: dict) -> str:
    return base64.urlsafe_b64encode(json.dumps(data).encode()).decode()

def decode_cursor(cursor: str) -> dict:
    return json.loads(base64.urlsafe_b64decode(cursor.encode()).decode())

async def paginate_cursor(
    session: AsyncSession,
    query,
    cursor: str | None = None,
    limit: int = 20,
    order_column=None,  # e.g., User.id
) -> CursorPage:
    if cursor:
        cursor_data = decode_cursor(cursor)
        query = query.where(order_column > cursor_data["last_id"])

    query = query.order_by(order_column).limit(limit + 1)
    results = list((await session.execute(query)).scalars().all())

    has_more = len(results) > limit
    items = results[:limit]

    next_cursor = None
    if has_more and items:
        next_cursor = encode_cursor({"last_id": items[-1].id})

    return CursorPage(items=items, next_cursor=next_cursor, has_more=has_more)

@router.get("/users/")
async def list_users(
    cursor: str | None = None,
    limit: int = Query(20, ge=1, le=100),
    db: AsyncSession = Depends(get_db),
):
    query = select(User).where(User.is_active == True)
    return await paginate_cursor(db, query, cursor, limit, User.id)
```

---

## Bulk Operations

### Bulk Insert

```python
async def bulk_create_users(
    session: AsyncSession, users_data: list[dict]
) -> list[User]:
    # Method 1: ORM bulk insert (tracks objects)
    users = [User(**data) for data in users_data]
    session.add_all(users)
    await session.flush()
    return users

    # Method 2: Core insert (faster, no object tracking)
    await session.execute(insert(User), users_data)
    await session.commit()
```

### Bulk Update

```python
from sqlalchemy import update

async def deactivate_users(session: AsyncSession, user_ids: list[int]):
    await session.execute(
        update(User)
        .where(User.id.in_(user_ids))
        .values(is_active=False, updated_at=func.now())
    )
    await session.commit()

# Bulk update with different values per row
async def update_user_roles(session: AsyncSession, updates: list[dict]):
    # [{"id": 1, "role": "admin"}, {"id": 2, "role": "user"}]
    await session.execute(update(User), updates)  # Requires "id" as PK match
    await session.commit()
```

### Bulk Upsert (Insert or Update)

```python
from sqlalchemy.dialects.postgresql import insert as pg_insert

async def upsert_users(session: AsyncSession, users_data: list[dict]):
    stmt = pg_insert(User).values(users_data)
    stmt = stmt.on_conflict_do_update(
        index_elements=["email"],  # Conflict on unique email
        set_={
            "name": stmt.excluded.name,
            "updated_at": func.now(),
        },
    )
    await session.execute(stmt)
    await session.commit()
```

### Batch Processing with Chunks

```python
async def process_in_batches(
    session: AsyncSession,
    items: list[dict],
    batch_size: int = 500,
):
    for i in range(0, len(items), batch_size):
        batch = items[i : i + batch_size]
        session.add_all([MyModel(**item) for item in batch])
        await session.flush()  # Send to DB without full commit
    await session.commit()  # Single commit at the end
```

---

## Raw SQL

### When to Use Raw SQL

Use raw SQL for: complex reports, database-specific features (window functions,
CTEs, recursive queries), performance-critical queries, migrations.

```python
from sqlalchemy import text

# Simple raw query
async def get_user_stats(session: AsyncSession):
    result = await session.execute(text("""
        SELECT
            u.id,
            u.name,
            COUNT(p.id) AS post_count,
            MAX(p.created_at) AS last_post_at
        FROM users u
        LEFT JOIN posts p ON p.author_id = u.id
        WHERE u.is_active = true
        GROUP BY u.id, u.name
        ORDER BY post_count DESC
        LIMIT 10
    """))
    return [dict(row._mapping) for row in result]

# Parameterized query (always use for user input)
async def search_users(session: AsyncSession, query: str):
    result = await session.execute(
        text("SELECT * FROM users WHERE name ILIKE :query"),
        {"query": f"%{query}%"},  # Parameters prevent SQL injection
    )
    return [dict(row._mapping) for row in result]

# CTE example
async def get_user_rankings(session: AsyncSession):
    result = await session.execute(text("""
        WITH user_scores AS (
            SELECT
                author_id,
                SUM(likes) AS total_likes,
                RANK() OVER (ORDER BY SUM(likes) DESC) AS rank
            FROM posts
            GROUP BY author_id
        )
        SELECT u.name, us.total_likes, us.rank
        FROM user_scores us
        JOIN users u ON u.id = us.author_id
        WHERE us.rank <= 100
    """))
    return [dict(row._mapping) for row in result]
```

---

## Database Testing Fixtures

### Complete Test Setup with Isolated Database

```python
# conftest.py
import pytest
import asyncio
from sqlalchemy.ext.asyncio import create_async_engine, async_sessionmaker, AsyncSession
from httpx import AsyncClient, ASGITransport
from app.database import Base, get_db
from app.main import app

TEST_DB_URL = "postgresql+asyncpg://test:test@localhost:5432/test_db"

@pytest.fixture(scope="session")
def event_loop():
    loop = asyncio.new_event_loop()
    yield loop
    loop.close()

@pytest.fixture(scope="session")
async def test_engine():
    engine = create_async_engine(TEST_DB_URL, echo=False)
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    yield engine
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)
    await engine.dispose()

@pytest.fixture
async def db_session(test_engine):
    """Per-test session with automatic rollback."""
    async with test_engine.connect() as conn:
        trans = await conn.begin()
        session = AsyncSession(bind=conn, expire_on_commit=False)
        try:
            yield session
        finally:
            await trans.rollback()
            await session.close()

@pytest.fixture
async def client(db_session):
    """Test client with dependency override."""
    async def override_get_db():
        yield db_session

    app.dependency_overrides[get_db] = override_get_db
    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
    ) as c:
        yield c
    app.dependency_overrides.clear()

# Factory fixtures for creating test data
@pytest.fixture
def user_factory(db_session):
    async def create_user(**kwargs) -> User:
        defaults = {"email": f"user-{uuid4()}@test.com", "name": "Test User"}
        defaults.update(kwargs)
        user = User(**defaults)
        db_session.add(user)
        await db_session.flush()
        return user
    return create_user
```

### Using SQLite for Fast Tests

```python
# For projects that don't need Postgres-specific features
TEST_DB_URL = "sqlite+aiosqlite:///./test.db"

@pytest.fixture(scope="session")
async def test_engine():
    engine = create_async_engine(
        TEST_DB_URL,
        connect_args={"check_same_thread": False},
    )
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    yield engine
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)
    await engine.dispose()
```

---

## Multi-Database Setup

### Multiple Engines

```python
from sqlalchemy.ext.asyncio import create_async_engine, async_sessionmaker

# Primary database (users, auth)
primary_engine = create_async_engine("postgresql+asyncpg://user:pass@primary/main_db")
PrimarySession = async_sessionmaker(bind=primary_engine, class_=AsyncSession, expire_on_commit=False)

# Analytics database (events, metrics)
analytics_engine = create_async_engine("postgresql+asyncpg://user:pass@analytics/analytics_db")
AnalyticsSession = async_sessionmaker(bind=analytics_engine, class_=AsyncSession, expire_on_commit=False)

# Dependencies
async def get_primary_db() -> AsyncGenerator[AsyncSession, None]:
    async with PrimarySession() as session:
        yield session

async def get_analytics_db() -> AsyncGenerator[AsyncSession, None]:
    async with AnalyticsSession() as session:
        yield session

# Route using specific database
@router.get("/users/")
async def list_users(db: AsyncSession = Depends(get_primary_db)):
    return (await db.execute(select(User))).scalars().all()

@router.get("/analytics/pageviews")
async def get_pageviews(db: AsyncSession = Depends(get_analytics_db)):
    return (await db.execute(select(PageView))).scalars().all()
```

### Separate Bases for Each Database

```python
class PrimaryBase(DeclarativeBase):
    pass

class AnalyticsBase(DeclarativeBase):
    pass

# Models use the appropriate base
class User(PrimaryBase):
    __tablename__ = "users"
    ...

class PageView(AnalyticsBase):
    __tablename__ = "pageviews"
    ...

# Create tables on the right engines
@asynccontextmanager
async def lifespan(app: FastAPI):
    async with primary_engine.begin() as conn:
        await conn.run_sync(PrimaryBase.metadata.create_all)
    async with analytics_engine.begin() as conn:
        await conn.run_sync(AnalyticsBase.metadata.create_all)
    yield
    await primary_engine.dispose()
    await analytics_engine.dispose()
```

### Cross-Database Queries

```python
@router.get("/users/{user_id}/activity")
async def user_activity(
    user_id: int,
    primary_db: AsyncSession = Depends(get_primary_db),
    analytics_db: AsyncSession = Depends(get_analytics_db),
):
    user = await primary_db.get(User, user_id)
    if not user:
        raise HTTPException(404, "User not found")

    events = (await analytics_db.execute(
        select(UserEvent).where(UserEvent.user_id == user_id).limit(50)
    )).scalars().all()

    return {"user": user, "recent_events": events}
```
