---
name: sqlalchemy-patterns
description: >
  USE when writing Python code that imports sqlalchemy, uses ORM models with DeclarativeBase/mapped_column/Mapped,
  builds SQL queries with select/insert/update/delete, configures engines or sessions, writes Alembic migrations,
  defines relationships (one-to-many, many-to-many), uses async SQLAlchemy (AsyncSession, create_async_engine),
  implements TypeDecorator or hybrid_property, or asks about N+1 queries, eager loading, connection pooling,
  or SQLAlchemy testing fixtures.
  DO NOT USE for Drizzle ORM (JavaScript), Django ORM, Tortoise ORM, Peewee, raw SQL without SQLAlchemy,
  or general FastAPI routing that does not involve database models or sessions.
  TRIGGERS: "SQLAlchemy", "mapped_column", "DeclarativeBase", "Session.execute", "create_engine",
  "selectinload", "joinedload", "Alembic", "relationship()", "Mapped[", "AsyncSession".
---

# SQLAlchemy 2.0 Patterns

## Architecture

SQLAlchemy has two layers. **Core** handles SQL expression language, engines, connections, and connection pools. **ORM** adds declarative mapping, sessions, relationships, and identity maps on top of Core. Always use 2.0-style APIs: `select()` over `Query`, `DeclarativeBase` over `declarative_base()`, `mapped_column()` over `Column()`.

## Engine and Connection

### Engine Creation

```python
from sqlalchemy import create_engine
from sqlalchemy.ext.asyncio import create_async_engine

# Sync
engine = create_engine(
    "postgresql+psycopg://user:pass@localhost:5432/mydb",
    pool_size=10,
    max_overflow=20,
    pool_pre_ping=True,       # detect stale connections
    pool_recycle=3600,         # recycle connections after 1h
    echo=False,                # True only in dev
)

# Async — requires async driver (asyncpg, aiomysql, aiosqlite)
async_engine = create_async_engine(
    "postgresql+asyncpg://user:pass@localhost:5432/mydb",
    pool_size=10,
    max_overflow=20,
)
```

### URL Construction and Connections

```python
from sqlalchemy import URL
url = URL.create(drivername="postgresql+psycopg", username="user",
    password="secret", host="localhost", port=5432, database="mydb")
engine = create_engine(url)

# Core connection (auto-commit off in 2.0 — explicit commit required)
with engine.connect() as conn:
    result = conn.execute(text("SELECT 1"))
    conn.commit()

# Begin block — auto-commits on success, rolls back on exception
with engine.begin() as conn:
    conn.execute(text("INSERT INTO t VALUES (:v)"), {"v": 1})
```

## Declarative Mapping

### Base Class

```python
from sqlalchemy.orm import DeclarativeBase
from sqlalchemy import MetaData

naming_convention = {
    "ix": "ix_%(column_0_label)s", "uq": "uq_%(table_name)s_%(column_0_N_name)s",
    "ck": "ck_%(table_name)s_%(constraint_name)s",
    "fk": "fk_%(table_name)s_%(column_0_name)s_%(referred_table_name)s",
    "pk": "pk_%(table_name)s",
}

class Base(DeclarativeBase):
    metadata = MetaData(naming_convention=naming_convention)
```

### Model Definition

```python
from sqlalchemy.orm import Mapped, mapped_column, relationship
from sqlalchemy import String, ForeignKey, func
from datetime import datetime
from typing import Optional

class User(Base):
    __tablename__ = "users"
    id: Mapped[int] = mapped_column(primary_key=True)
    email: Mapped[str] = mapped_column(String(255), unique=True, index=True)
    name: Mapped[str] = mapped_column(String(100))
    bio: Mapped[Optional[str]]  # nullable inferred from Optional
    created_at: Mapped[datetime] = mapped_column(server_default=func.now())
    posts: Mapped[list["Post"]] = relationship(back_populates="author")
```

- `Mapped[int]` → NOT NULL. `Mapped[Optional[int]]` → nullable.
- Use `mapped_column()` for column config. Bare `Mapped[str]` works for simple non-null strings.
- Always set `back_populates` on both sides of a relationship.

## Relationships

### One-to-Many

```python
class Post(Base):
    __tablename__ = "posts"
    id: Mapped[int] = mapped_column(primary_key=True)
    title: Mapped[str] = mapped_column(String(200))
    author_id: Mapped[int] = mapped_column(ForeignKey("users.id"))
    author: Mapped["User"] = relationship(back_populates="posts")
    tags: Mapped[list["Tag"]] = relationship(secondary="post_tags", back_populates="posts")
```

### Many-to-Many

```python
from sqlalchemy import Table, Column, Integer, ForeignKey

post_tags = Table(
    "post_tags",
    Base.metadata,
    Column("post_id", Integer, ForeignKey("posts.id"), primary_key=True),
    Column("tag_id", Integer, ForeignKey("tags.id"), primary_key=True),
)

class Tag(Base):
    __tablename__ = "tags"
    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(50), unique=True)
    posts: Mapped[list["Post"]] = relationship(
        secondary=post_tags, back_populates="tags"
    )
```

### Self-Referential

```python
class Category(Base):
    __tablename__ = "categories"
    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(100))
    parent_id: Mapped[Optional[int]] = mapped_column(ForeignKey("categories.id"))

    children: Mapped[list["Category"]] = relationship(back_populates="parent")
    parent: Mapped[Optional["Category"]] = relationship(
        back_populates="children", remote_side=[id]
    )
```

## Core Expressions

```python
from sqlalchemy import select, insert, update, delete, text, and_, or_, func, exists, case

stmt = select(User).where(and_(User.name.ilike("%alice%"), User.created_at >= "2024-01-01"))
stmt = insert(User).values(email="a@b.com", name="Alice").returning(User.id)
stmt = update(User).where(User.id == 1).values(name="Bob")
stmt = delete(User).where(User.id == 1)
stmt = select(func.count(User.id), User.name).group_by(User.name)

# Subquery
subq = select(func.count(Post.id)).where(Post.author_id == User.id).scalar_subquery()
stmt = select(User.name, subq.label("post_count"))

# EXISTS
stmt = select(User).where(exists().where(Post.author_id == User.id))

# CASE
stmt = select(User.name,
    case((User.bio.is_(None), "No bio"), else_="Has bio").label("status"))
```

## ORM Querying

```python
from sqlalchemy.orm import Session

with Session(engine) as session:
    user = session.get(User, 1)                                        # by primary key
    user = session.execute(select(User).where(User.email == "a@b.com")).scalar_one_or_none()
    users = session.scalars(select(User).order_by(User.name)).all()    # list of ORM objects

    # Join
    stmt = (select(User, Post).join(Post, User.id == Post.author_id)
            .where(Post.title.contains("sql")))
    rows = session.execute(stmt).all()  # list of (User, Post) tuples

    # Pagination
    stmt = select(User).order_by(User.id).offset(20).limit(10)
```

Result methods: `scalar_one()` (exactly one or raise), `scalar_one_or_none()`, `scalars().all()`, `scalars().first()`.

## Eager Loading

Default `lazy="select"` causes N+1. Fix with loader options:

```python
from sqlalchemy.orm import joinedload, selectinload, subqueryload, contains_eager

stmt = select(Post).options(joinedload(Post.author))          # JOIN, best for *-to-one
stmt = select(User).options(selectinload(User.posts))         # IN clause, best for *-to-many
stmt = select(User).options(subqueryload(User.posts))         # subquery alternative

# contains_eager — when you already JOIN manually
stmt = (select(Post).join(Post.author)
        .options(contains_eager(Post.author)).where(User.name == "Alice"))

# Chained for nested relationships
stmt = select(User).options(selectinload(User.posts).joinedload(Post.tags))
```

**Decision guide**: `joinedload` for *-to-one, `selectinload` for *-to-many, `contains_eager` when you already join.

## Async Support

```python
from sqlalchemy.ext.asyncio import (
    create_async_engine, AsyncSession, async_sessionmaker,
)

async_engine = create_async_engine("postgresql+asyncpg://user:pass@host/db")
AsyncSessionLocal = async_sessionmaker(
    async_engine, expire_on_commit=False, class_=AsyncSession
)

async def get_user(user_id: int) -> User | None:
    async with AsyncSessionLocal() as session:
        return await session.get(User, user_id)

async def list_users() -> list[User]:
    async with AsyncSessionLocal() as session:
        result = await session.scalars(select(User))
        return result.all()

# Streaming large result sets
async def stream_users():
    async with AsyncSessionLocal() as session:
        async for user in await session.stream_scalars(select(User)):
            yield user

# Accessing lazy-loaded attributes in async — use awaitable_attrs
async def get_user_posts(user_id: int):
    async with AsyncSessionLocal() as session:
        user = await session.get(User, user_id)
        posts = await user.awaitable_attrs.posts  # NOT user.posts
        return posts
```

Async rules: never share `AsyncSession` across tasks. Set `expire_on_commit=False`. Use `run_sync` for sync-only operations. Call `await engine.dispose()` on shutdown.

## Transactions

```python
# Session auto-begins a transaction. Explicit commit required.
with Session(engine) as session:
    session.add(User(email="x@y.com", name="X"))
    session.commit()  # flushes + commits
    # session.rollback() to discard

# Nested transaction / savepoint
with Session(engine) as session:
    session.begin()
    session.add(user1)
    nested = session.begin_nested()  # SAVEPOINT
    try:
        session.add(user2_might_fail)
        session.flush()
        nested.commit()
    except Exception:
        nested.rollback()  # rolls back to savepoint only
    session.commit()  # commits user1

# Async transactions
async with AsyncSessionLocal() as session:
    async with session.begin():
        session.add(User(email="a@b.com", name="A"))
    # auto-commits on exit, rolls back on exception
```

## Alembic Migrations

### Setup

```bash
pip install alembic
alembic init alembic              # sync projects
alembic init -t async alembic     # async projects
```

In `alembic/env.py`, set `target_metadata = Base.metadata` and override URL from env vars:

```python
from myapp.models import Base
target_metadata = Base.metadata
import os
db_url = os.environ.get("DATABASE_URL")
if db_url:
    config.set_main_option("sqlalchemy.url", db_url)
```

### Workflow

```bash
alembic revision --autogenerate -m "add users table"  # generate from model diff
alembic upgrade head                                   # apply all
alembic downgrade -1                                   # rollback one step
alembic current                                        # show current revision
```

Always review autogenerated migrations — Alembic cannot detect column renames, some type changes, or constraint modifications.

## Events and Hooks

```python
from sqlalchemy import event

# Mapper-level events
@event.listens_for(User, "before_insert")
def set_defaults(mapper, connection, target):
    if not target.name:
        target.name = target.email.split("@")[0]

@event.listens_for(User, "after_update")
def log_update(mapper, connection, target):
    print(f"Updated user {target.id}")

# Session-level events
@event.listens_for(Session, "before_flush")
def validate_before_flush(session, flush_context, instances):
    for obj in session.new:
        if isinstance(obj, User) and not obj.email:
            raise ValueError("Email required")

# Attribute-level events
@event.listens_for(User.email, "set")
def normalize_email(target, value, oldvalue, initiator):
    if value:
        target.email = value.lower().strip()
```

## Hybrid Properties

```python
from sqlalchemy.ext.hybrid import hybrid_property

class User(Base):
    __tablename__ = "users"
    id: Mapped[int] = mapped_column(primary_key=True)
    first_name: Mapped[str] = mapped_column(String(50))
    last_name: Mapped[str] = mapped_column(String(50))

    @hybrid_property
    def full_name(self) -> str:
        return f"{self.first_name} {self.last_name}"

    @full_name.expression
    @classmethod
    def full_name(cls):
        return cls.first_name + " " + cls.last_name

# Works at instance level AND in queries:
# session.scalars(select(User).where(User.full_name == "Alice Smith"))
```

## Custom Types

```python
from sqlalchemy.types import TypeDecorator, String
import json

class JSONEncodedDict(TypeDecorator):
    impl = String
    cache_ok = True

    def process_bind_param(self, value, dialect):
        if value is not None:
            return json.dumps(value)
        return None

    def process_result_value(self, value, dialect):
        if value is not None:
            return json.loads(value)
        return None

# Usage
class Config(Base):
    __tablename__ = "configs"
    id: Mapped[int] = mapped_column(primary_key=True)
    data: Mapped[dict] = mapped_column(JSONEncodedDict(1024))
```

Always set `cache_ok = True` on custom types to enable query caching.

## Performance

### N+1 Detection

Enable SQL echo in dev to spot repeated queries:

```python
engine = create_engine(url, echo=True)
# Watch logs for repeated SELECT patterns when iterating relationships
```

### Bulk Operations

```python
from sqlalchemy import insert

# FAST: Core bulk insert (bypasses ORM identity map)
with Session(engine) as session:
    session.execute(
        insert(User),
        [{"email": f"u{i}@x.com", "name": f"User{i}"} for i in range(10000)],
    )
    session.commit()

# SLOWER: ORM bulk (tracks objects in session)
session.add_all([User(email=f"u{i}@x.com", name=f"User{i}") for i in range(10000)])
session.commit()

# Bulk update
from sqlalchemy import update
session.execute(
    update(User).where(User.created_at < "2024-01-01").values(name="Archived")
)
```

Use Core `insert()` for thousands of rows. Use ORM `add()`/`add_all()` when you need events, defaults, or relationship cascades.

## Testing Patterns

```python
import pytest
from sqlalchemy import create_engine
from sqlalchemy.orm import Session

@pytest.fixture(scope="session")
def engine():
    engine = create_engine("sqlite:///:memory:")
    Base.metadata.create_all(engine)
    yield engine
    engine.dispose()

@pytest.fixture()
def db_session(engine):
    connection = engine.connect()
    transaction = connection.begin()
    session = Session(bind=connection)
    yield session
    session.close()
    transaction.rollback()
    connection.close()

def test_create_user(db_session):
    user = User(email="test@test.com", name="Test")
    db_session.add(user)
    db_session.flush()
    assert user.id is not None
    # transaction rolls back automatically — no DB pollution
```

See [`assets/conftest.py`](assets/conftest.py) for async fixtures, factory patterns, and savepoint handling.

## Common Pitfalls

1. **Detached instance error** — accessing relationship after `session.close()`. Fix: eager load before closing, or set `expire_on_commit=False`.
2. **Legacy Query API** — `session.query(User)` still works but is legacy. Use `session.execute(select(User))`.
3. **Implicit autocommit removed** — 2.0 requires explicit `session.commit()` or `connection.commit()`.
4. **Async lazy loading** — accessing `user.posts` without `await` in async raises `MissingGreenlet`. Use `selectinload` or `awaitable_attrs`.
5. **Missing `back_populates`** — causes inconsistent in-memory state between related objects.
6. **`expire_on_commit=True` (default)** — attributes become stale after commit, triggering new SELECT. Set to `False` in async or API contexts.
7. **No naming convention on MetaData** — Alembic generates non-deterministic constraint names, causing migration churn. Always set `naming_convention`.
8. **`bulk_save_objects` is deprecated** — use Core `insert()` for bulk inserts in 2.0.

## Additional Resources

### References (`references/`)

- **[advanced-patterns.md](references/advanced-patterns.md)** — Polymorphic inheritance, multi-tenancy, sharding, versioned rows, soft deletes, association proxy, composite keys, JSON/JSONB, arrays, full-text search, CTEs, window functions, lateral joins, custom compilation, dogpile.cache.
- **[troubleshooting.md](references/troubleshooting.md)** — DetachedInstanceError, N+1, session scope, greenlet_spawn, identity map, stale data, migration conflicts, pool exhaustion, thread safety, autoflush, cascade deletes, loader conflicts, bulk vs ORM.
- **[alembic-guide.md](references/alembic-guide.md)** — Setup, sync/async env.py, autogenerate, type comparators, manual/data migrations, multi-database, branch management, downgrades, testing, CI, enum changes, type changes, SQLite batch ops.

### Templates (`assets/`)

- **[base-model.py](assets/base-model.py)** — Base with id, timestamps, soft delete mixin, repr, naming conventions.
- **[repository-pattern.py](assets/repository-pattern.py)** — Generic async repository: CRUD, pagination, dynamic filtering.
- **[async-session.py](assets/async-session.py)** — Async session factory with FastAPI deps and lifecycle.
- **[alembic-env.py](assets/alembic-env.py)** — Production env.py: sync/async, env var URL, SQLite batch, schema filter.
- **[conftest.py](assets/conftest.py)** — Pytest: sync/async engines, rollback sessions, factories.

### Scripts (`scripts/`)

