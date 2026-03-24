---
name: sqlalchemy-patterns
description: >
  SQLAlchemy 2.0 ORM and database toolkit patterns. Use when: writing SQLAlchemy models, ORM queries, session management, relationship mapping (one-to-many, many-to-many), Alembic migrations, async SQLAlchemy with AsyncSession, SQLAlchemy 2.0 style with Mapped/mapped_column, database engine configuration, hybrid properties, event listeners, connection pooling, custom types, bulk operations, eager/lazy loading. Do NOT use for: Django ORM, Prisma, Drizzle, TypeORM, Sequelize, raw SQL without SQLAlchemy context, MongoDB or NoSQL databases, database administration tasks without ORM context, SQLAlchemy versions before 1.4.
---

# SQLAlchemy 2.0 Patterns

## Installation
```bash
pip install sqlalchemy[asyncio] psycopg2-binary  # sync PostgreSQL
pip install sqlalchemy[asyncio] asyncpg           # async PostgreSQL
pip install alembic                                # migrations
```

## Engine & Connection Pooling
```python
from sqlalchemy import create_engine
from sqlalchemy.ext.asyncio import create_async_engine

# Sync
engine = create_engine(
    "postgresql+psycopg2://user:pass@localhost:5432/mydb",
    pool_size=10, max_overflow=5, pool_recycle=3600, pool_pre_ping=True,
)
# Async
async_engine = create_async_engine(
    "postgresql+asyncpg://user:pass@localhost:5432/mydb",
    pool_size=10, max_overflow=5, pool_pre_ping=True,
)
```
Pool options: `pool_size` (max persistent, default 5), `max_overflow` (extra beyond pool_size, default 10), `pool_recycle` (seconds before recycling — use for MySQL), `pool_pre_ping` (test before use). For serverless/CLI: `from sqlalchemy.pool import NullPool; create_engine(..., poolclass=NullPool)`.

## Session Management
```python
from sqlalchemy.orm import sessionmaker, Session
from sqlalchemy.ext.asyncio import async_sessionmaker, AsyncSession

# Sync
SessionLocal = sessionmaker(bind=engine, expire_on_commit=False)
with SessionLocal() as session:
    with session.begin():
        session.add(User(name="Alice"))  # auto-commit on exit, rollback on exception

# Async — never share AsyncSession across tasks
async_session = async_sessionmaker(async_engine, expire_on_commit=False)
async with async_session() as session:
    async with session.begin():
        session.add(User(name="Alice"))

# FastAPI dependency injection
def get_db() -> Generator[Session, None, None]:
    with SessionLocal() as session:
        yield session

async def get_async_db() -> AsyncGenerator[AsyncSession, None]:
    async with async_session() as session:
        yield session
```

## Declarative Mapping (2.0 Style)
```python
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column
from sqlalchemy import String, DateTime, func
from datetime import datetime

class Base(DeclarativeBase):
    pass

class User(Base):
    __tablename__ = "users"
    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(100))
    email: Mapped[str] = mapped_column(String(255), unique=True, index=True)
    bio: Mapped[str | None] = mapped_column(String(500))  # nullable
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
```
Rules: `Mapped[str]` = NOT NULL, `Mapped[str | None]` = nullable. `mapped_column()` infers type from annotation; pass SQL type for constraints: `String(100)`. Never mix old `Column()` with `Mapped`/`mapped_column`.

## Relationships

### One-to-Many
```python
class User(Base):
    __tablename__ = "users"
    id: Mapped[int] = mapped_column(primary_key=True)
    posts: Mapped[list["Post"]] = relationship(back_populates="author")

class Post(Base):
    __tablename__ = "posts"
    id: Mapped[int] = mapped_column(primary_key=True)
    author_id: Mapped[int] = mapped_column(ForeignKey("users.id"))
    author: Mapped["User"] = relationship(back_populates="posts")
```

### Many-to-Many
```python
post_tags = Table("post_tags", Base.metadata,
    Column("post_id", ForeignKey("posts.id"), primary_key=True),
    Column("tag_id", ForeignKey("tags.id"), primary_key=True),
)
class Tag(Base):
    __tablename__ = "tags"
    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(50), unique=True)
    posts: Mapped[list["Post"]] = relationship(secondary=post_tags, back_populates="tags")
# On Post: tags: Mapped[list["Tag"]] = relationship(secondary=post_tags, back_populates="posts")
```

### Self-Referential
```python
class Category(Base):
    __tablename__ = "categories"
    id: Mapped[int] = mapped_column(primary_key=True)
    parent_id: Mapped[int | None] = mapped_column(ForeignKey("categories.id"))
    children: Mapped[list["Category"]] = relationship(back_populates="parent")
    parent: Mapped["Category | None"] = relationship(back_populates="children", remote_side=[id])
```

Always use `back_populates` (not `backref`) for explicit, type-safe bidirectional relationships. Cascade: `cascade="all, delete-orphan", passive_deletes=True`.

## Query Patterns
```python
from sqlalchemy import select, and_, or_, func

# Single row
user = session.execute(select(User).where(User.id == 1)).scalar_one_or_none()
# Async: user = (await session.execute(stmt)).scalar_one_or_none()

# Multiple rows
users = session.scalars(select(User).where(User.is_active == True).order_by(User.name)).all()

# Filtering
stmt = select(User).where(and_(
    User.age >= 18,
    or_(User.role == "admin", User.role == "moderator"),
    User.email.ilike("%@example.com"),
    User.name.in_(["Alice", "Bob"]),
    User.deleted_at.is_(None),
))

# Joins
stmt = select(User).join(User.posts).where(Post.title.contains("SQLAlchemy"))
stmt = select(User, Post).join(Post, User.id == Post.author_id)  # explicit
stmt = select(User).outerjoin(User.posts)  # outer join

# Aggregations
stmt = select(User.role, func.count(User.id).label("count"),
    func.avg(User.age).label("avg_age"),
).group_by(User.role).having(func.count(User.id) > 5)
# → [("admin", 12, 34.5), ("user", 100, 28.1)]

# Subquery
subq = select(func.max(Post.created_at).label("latest")).where(
    Post.author_id == User.id).correlate(User).scalar_subquery()
stmt = select(User, subq.label("latest_post_at"))

# CTE
active = select(User.id, User.name).where(User.is_active == True).cte("active")
stmt = select(active.c.name, func.count(Post.id)).join(
    Post, Post.author_id == active.c.id).group_by(active.c.name)

# Pagination
stmt = select(User).order_by(User.id).offset(20).limit(10)
```

## Eager/Lazy Loading
```python
from sqlalchemy.orm import selectinload, joinedload, raiseload

# selectinload: 2 queries (parent + IN for children). Best for collections.
stmt = select(User).options(selectinload(User.posts))

# joinedload: 1 query with JOIN. Best for scalar/small relations.
stmt = select(User).options(joinedload(User.profile))

# Nested eager loading
stmt = select(User).options(selectinload(User.posts).selectinload(Post.comments))

# raiseload: error on lazy load (catches N+1 at dev time)
stmt = select(User).options(raiseload(User.posts))
```
Model-level default: `relationship(..., lazy="selectin")`. Prefer per-query `.options()` for flexibility.

## Hybrid Properties & Column Properties
```python
from sqlalchemy.ext.hybrid import hybrid_property
from sqlalchemy.orm import column_property

class User(Base):
    __tablename__ = "users"
    first_name: Mapped[str] = mapped_column(String(50))
    last_name: Mapped[str] = mapped_column(String(50))

    # hybrid_property: works in Python AND SQL
    @hybrid_property
    def full_name(self) -> str:
        return f"{self.first_name} {self.last_name}"

    @full_name.expression
    @classmethod
    def full_name(cls):
        return func.concat(cls.first_name, " ", cls.last_name)

    # column_property: SQL-only computed column
    display_name: Mapped[str] = column_property(first_name + " " + last_name)

# user.full_name → "John Doe"
# select(User).where(User.full_name == "John Doe")  ✓
```

## Event Listeners
```python
from sqlalchemy import event

@event.listens_for(User, "before_insert")
def set_created(mapper, connection, target):
    target.created_at = datetime.utcnow()

@event.listens_for(Session, "after_commit")
def after_commit(session):
    print("Committed")

@event.listens_for(engine, "connect")
def on_connect(dbapi_conn, connection_record):
    dbapi_conn.execute("SET timezone='UTC'")
```

## Mixins
```python
class TimestampMixin:
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now())

class SoftDeleteMixin:
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    @hybrid_property
    def is_deleted(self) -> bool:
        return self.deleted_at is not None

class User(TimestampMixin, SoftDeleteMixin, Base):
    __tablename__ = "users"
    id: Mapped[int] = mapped_column(primary_key=True)
```

## Custom Types
```python
from sqlalchemy.types import TypeDecorator, Text
import json

class JSONEncoded(TypeDecorator):
    impl = Text
    cache_ok = True  # required in SQLAlchemy 2.0
    def process_bind_param(self, value, dialect):
        return json.dumps(value) if value is not None else None
    def process_result_value(self, value, dialect):
        return json.loads(value) if value is not None else None

# Usage: settings: Mapped[dict] = mapped_column(JSONEncoded)
# For PostgreSQL, prefer native JSONB: from sqlalchemy.dialects.postgresql import JSONB
```

## Alembic Integration
```bash
alembic init alembic            # sync setup
alembic init -t async alembic   # async setup
```
```python
# alembic/env.py — set target_metadata and URL
from myapp.models import Base
import os
target_metadata = Base.metadata
config.set_main_option("sqlalchemy.url", os.environ["DATABASE_URL"])

# Async env.py — replace run_migrations_online:
import asyncio
from sqlalchemy.ext.asyncio import create_async_engine

def run_migrations_online():
    connectable = create_async_engine(config.get_main_option("sqlalchemy.url"))
    async def do_run():
        async with connectable.connect() as connection:
            await connection.run_sync(lambda conn: (
                context.configure(connection=conn, target_metadata=target_metadata),
                context.run_migrations(),
            ))
        await connectable.dispose()
    asyncio.run(do_run())
```
```bash
alembic revision --autogenerate -m "add users table"
alembic upgrade head          # apply all
alembic downgrade -1          # rollback one
```
Always review autogenerated migrations — they miss renamed columns (shows as drop+add), data migrations, and custom constraints.

## Testing
```python
import pytest
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

@pytest.fixture
def db_session():
    engine = create_engine("sqlite:///:memory:")
    Base.metadata.create_all(engine)
    with sessionmaker(bind=engine)() as session:
        yield session
    engine.dispose()

# Async testing
import pytest_asyncio
from sqlalchemy.ext.asyncio import create_async_engine, async_sessionmaker

@pytest_asyncio.fixture
async def async_db():
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    async with async_sessionmaker(engine, expire_on_commit=False)() as session:
        yield session
    await engine.dispose()

# Transaction rollback per test (real DB)
@pytest.fixture
def db_session(engine):
    conn = engine.connect()
    txn = conn.begin()
    session = Session(bind=conn)
    yield session
    session.close()
    txn.rollback()
    conn.close()
```

## Performance Optimization

### N+1 Detection
```python
engine = create_engine(..., echo=True)  # log all SQL
stmt = select(User).options(raiseload("*"))  # error on any lazy load
```

### Bulk Operations
```python
from sqlalchemy import insert, update

# Core bulk insert (fastest, bypasses ORM events)
session.execute(insert(User), [{"name": "A", "email": "a@x.com"}, {"name": "B", "email": "b@x.com"}])

# ORM bulk
session.add_all([User(name="A"), User(name="B")]); session.flush()

# Bulk update
session.execute(update(User).where(User.is_active == False).values(deleted_at=func.now()))

# PostgreSQL upsert
from sqlalchemy.dialects.postgresql import insert as pg_insert
stmt = pg_insert(User).values(data)
stmt = stmt.on_conflict_do_update(index_elements=["email"],
    set_={"name": stmt.excluded.name, "updated_at": func.now()})
session.execute(stmt)
```

### Streaming & Column Selection
```python
# Stream large results
for user in session.scalars(select(User)).yield_per(1000): process(user)
async for user in await session.stream_scalars(select(User)): process(user)

# Select only needed columns (returns Row tuples, not ORM objects)
rows = session.execute(select(User.id, User.name)).all()
```

## Type Annotation Patterns
```python
from typing import Annotated

intpk = Annotated[int, mapped_column(primary_key=True)]
str50 = Annotated[str, mapped_column(String(50))]
str255 = Annotated[str, mapped_column(String(255))]

class User(Base):
    __tablename__ = "users"
    id: Mapped[intpk]
    name: Mapped[str50]
    email: Mapped[str255]
```

### Generic Repository
```python
from typing import TypeVar, Generic, Type
T = TypeVar("T", bound=Base)

class Repository(Generic[T]):
    def __init__(self, session: Session, model: Type[T]):
        self.session = session
        self.model = model
    def get(self, id: int) -> T | None:
        return self.session.get(self.model, id)
    def list(self, **filters) -> list[T]:
        return list(self.session.scalars(select(self.model).filter_by(**filters)).all())
    def create(self, **kwargs) -> T:
        obj = self.model(**kwargs)
        self.session.add(obj); self.session.flush()
        return obj
```

## Common Pitfalls
- **Detached instance error**: accessing attributes after session close → set `expire_on_commit=False` or eager load
- **Lazy load in async**: triggers sync I/O → always use `selectinload`/`joinedload` with async sessions
- **N+1 queries**: loop accessing relationships → use `.options(selectinload(...))` per query
- **Missing `await`**: all async session/engine operations require `await`
- **Stale connections**: set `pool_pre_ping=True` on long-lived engines
- **Forgetting `cache_ok`**: custom `TypeDecorator` subclasses must set `cache_ok = True`
