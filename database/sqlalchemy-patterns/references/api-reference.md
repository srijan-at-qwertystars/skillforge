# SQLAlchemy 2.0 API Reference

> Quick-lookup reference for Session, select(), Column types, relationship(), mapped_column(), engine/pool configuration, and query API.

---

## Table of Contents

1. [Session API](#1-session-api)
2. [select() and Query Patterns](#2-select-and-query-patterns)
3. [Column Types](#3-column-types)
4. [relationship() Options](#4-relationship-options)
5. [mapped_column() Options](#5-mapped_column-options)
6. [Engine Configuration](#6-engine-configuration)
7. [Pool Configuration](#7-pool-configuration)
8. [Query API: New Style vs Legacy](#8-query-api-new-style-vs-legacy)

---

## 1. Session API

### Core Methods

| Method | Effect | Flushes? | Commits? |
|--------|--------|----------|----------|
| `add(obj)` | Schedule INSERT (new) or track (detached) | No | No |
| `add_all([obj, ...])` | Batch `add()` | No | No |
| `flush()` | Send pending SQL to DB, stay in transaction | Yes | No |
| `commit()` | `flush()` then commit transaction | Yes | Yes |
| `rollback()` | Discard all uncommitted changes | No | No |
| `close()` | Release connection, expunge all objects | No | No |
| `expire(obj)` | Mark attributes stale; reload on next access | No | No |
| `expire_all()` | Expire all objects in identity map | No | No |
| `refresh(obj)` | Immediately reload object from DB | No | No |
| `merge(obj)` | Merge detached/external object into session | No | No |
| `delete(obj)` | Schedule DELETE | No | No |
| `expunge(obj)` | Remove object from session (no DB effect) | No | No |
| `get(Model, pk)` | Fetch by PK (identity map first, then DB) | No | No |
| `execute(stmt)` | Execute a SQL statement, return `Result` | Auto* | No |
| `scalars(stmt)` | Execute, return `ScalarResult` (first column) | Auto* | No |

*Auto-flush before execute if `autoflush=True` (default).

### Session Configuration

```python
from sqlalchemy.orm import sessionmaker, Session

SessionLocal = sessionmaker(
    bind=engine,
    autoflush=True,           # flush before queries (default True)
    expire_on_commit=False,   # keep attributes accessible after commit
    class_=Session,           # or AsyncSession for async
)
```

### Session Lifecycle Patterns

```python
# Pattern 1: Context manager (recommended)
with SessionLocal() as session:
    with session.begin():
        session.add(User(name="Alice"))
    # auto-commit on success, auto-rollback on exception

# Pattern 2: Manual
session = SessionLocal()
try:
    session.add(User(name="Alice"))
    session.commit()
except Exception:
    session.rollback()
    raise
finally:
    session.close()

# Pattern 3: Nested transactions (savepoints)
with SessionLocal() as session:
    with session.begin():
        session.add(user1)
        try:
            with session.begin_nested():  # SAVEPOINT
                session.add(user2)  # may fail
        except IntegrityError:
            pass  # user2 rolled back, user1 still pending
```

### AsyncSession Differences

```python
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

async_session = async_sessionmaker(async_engine, expire_on_commit=False)

async with async_session() as session:
    async with session.begin():
        session.add(User(name="Alice"))

    # Explicit operations need await:
    result = await session.execute(select(User))
    user = await session.get(User, 1)
    await session.refresh(user)
    await session.commit()

    # Streaming:
    async for row in await session.stream(select(User)):
        process(row)
```

---

## 2. select() and Query Patterns

### Building Statements

```python
from sqlalchemy import select, insert, update, delete, and_, or_, not_, func, text, case, literal

# Basic select
stmt = select(User)
stmt = select(User).where(User.id == 1)
stmt = select(User.id, User.name)  # specific columns → Row tuples

# Filtering
stmt = select(User).where(
    and_(
        User.age >= 18,
        or_(User.role == "admin", User.role == "mod"),
        User.name.ilike("%alice%"),
        User.id.in_([1, 2, 3]),
        User.email.is_not(None),
        not_(User.is_banned),
    )
)
stmt = select(User).filter_by(name="Alice", is_active=True)  # kwargs shorthand

# Ordering
stmt = select(User).order_by(User.name.asc(), User.id.desc())
stmt = select(User).order_by(User.name.asc().nulls_last())

# Pagination
stmt = select(User).order_by(User.id).offset(20).limit(10)

# Distinct
stmt = select(User.role).distinct()

# Group By / Having
stmt = (
    select(User.role, func.count(User.id).label("cnt"))
    .group_by(User.role)
    .having(func.count(User.id) > 5)
)
```

### Joins

```python
# Implicit (relationship-based)
stmt = select(User).join(User.posts)
stmt = select(User).outerjoin(User.posts)

# Explicit
stmt = select(User, Post).join(Post, User.id == Post.author_id)
stmt = select(User).join(Post, User.id == Post.author_id, isouter=True)

# Multiple joins
stmt = (
    select(User)
    .join(User.posts)
    .join(Post.comments)
    .where(Comment.text.contains("help"))
)

# Self-join
from sqlalchemy.orm import aliased
manager = aliased(User, name="manager")
stmt = select(User, manager).join(manager, User.manager_id == manager.id)
```

### Subqueries and CTEs

```python
# Subquery
subq = select(func.count(Post.id)).where(Post.author_id == User.id).correlate(User).scalar_subquery()
stmt = select(User, subq.label("post_count"))

# Subquery as FROM
subq = select(Post.author_id, func.count(Post.id).label("cnt")).group_by(Post.author_id).subquery()
stmt = select(User.name, subq.c.cnt).join(subq, User.id == subq.c.author_id)

# CTE
active_users = (
    select(User.id, User.name)
    .where(User.is_active == True)
    .cte("active_users")
)
stmt = select(active_users.c.name, func.count(Post.id)).join(
    Post, Post.author_id == active_users.c.id
).group_by(active_users.c.name)

# Recursive CTE (tree traversal)
hierarchy = (
    select(Category.id, Category.name, Category.parent_id)
    .where(Category.parent_id.is_(None))
    .cte("hierarchy", recursive=True)
)
hierarchy = hierarchy.union_all(
    select(Category.id, Category.name, Category.parent_id)
    .join(hierarchy, Category.parent_id == hierarchy.c.id)
)
stmt = select(hierarchy)
```

### Result Processing

```python
result = session.execute(stmt)

# Single object
result.scalar_one()              # exactly one or raise
result.scalar_one_or_none()      # one or None, raise if >1
result.scalar()                  # first column of first row or None
result.first()                   # first Row or None

# Multiple objects
result.all()                     # list of Row tuples
result.scalars().all()           # list of first-column values
result.scalars().unique().all()  # deduplicated (for joined eager loads)

# Iteration
for row in result:
    print(row.User, row.Post)    # named tuple access

# Mappings
for row in result.mappings():
    print(row["name"], row["email"])

# Shorthand
users = session.scalars(select(User)).all()
user = session.scalar(select(User).where(User.id == 1))
```

### DML Statements

```python
# Insert
session.execute(insert(User).values(name="Alice", email="a@b.com"))
session.execute(insert(User), [{"name": "A"}, {"name": "B"}])  # bulk

# Update
session.execute(update(User).where(User.id == 1).values(name="Bob"))
session.execute(update(User).where(User.is_active == False).values(deleted_at=func.now()))

# Delete
session.execute(delete(User).where(User.id == 1))

# Returning (PostgreSQL, SQLite 3.35+)
result = session.execute(
    insert(User).values(name="Alice").returning(User.id, User.created_at)
)
new_id, created = result.one()

# Upsert (PostgreSQL)
from sqlalchemy.dialects.postgresql import insert as pg_insert
stmt = pg_insert(User).values(email="a@b.com", name="Alice")
stmt = stmt.on_conflict_do_update(
    index_elements=["email"],
    set_={"name": stmt.excluded.name, "updated_at": func.now()},
)
```

---

## 3. Column Types

### Standard Types

| SQLAlchemy Type | Python Type | SQL (PostgreSQL) | Notes |
|-----------------|-------------|-------------------|-------|
| `Integer` | `int` | `INTEGER` | |
| `BigInteger` | `int` | `BIGINT` | |
| `SmallInteger` | `int` | `SMALLINT` | |
| `Float` | `float` | `FLOAT` | Approximate |
| `Numeric(p, s)` | `Decimal` | `NUMERIC(p,s)` | Exact decimal |
| `String(n)` | `str` | `VARCHAR(n)` | |
| `Text` | `str` | `TEXT` | Unbounded |
| `Boolean` | `bool` | `BOOLEAN` | |
| `Date` | `date` | `DATE` | |
| `Time` | `time` | `TIME` | |
| `DateTime(tz)` | `datetime` | `TIMESTAMP` | `timezone=True` for tz-aware |
| `Interval` | `timedelta` | `INTERVAL` | |
| `LargeBinary` | `bytes` | `BYTEA` | |
| `Uuid` | `uuid.UUID` | `UUID` | New in 2.0 |
| `Enum` | `enum.Enum` | `VARCHAR` or native | |

### PostgreSQL-Specific

```python
from sqlalchemy.dialects.postgresql import (
    JSONB, ARRAY, INET, CIDR, MACADDR, TSVECTOR,
    INT4RANGE, TSTZRANGE, UUID as PG_UUID, HSTORE,
)

class Model(Base):
    __tablename__ = "models"
    id: Mapped[int] = mapped_column(primary_key=True)
    data: Mapped[dict] = mapped_column(JSONB)
    tags: Mapped[list[str]] = mapped_column(ARRAY(String))
    ip: Mapped[str] = mapped_column(INET)
    search_vector: Mapped[str] = mapped_column(TSVECTOR)
```

### Type Annotation Shortcuts

```python
from typing import Annotated

# Reusable type aliases
intpk = Annotated[int, mapped_column(primary_key=True)]
str50 = Annotated[str, mapped_column(String(50))]
str255 = Annotated[str, mapped_column(String(255))]
created_ts = Annotated[datetime, mapped_column(DateTime(timezone=True), server_default=func.now())]
updated_ts = Annotated[datetime, mapped_column(
    DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
)]
```

---

## 4. relationship() Options

```python
from sqlalchemy.orm import relationship

relationship(
    argument,                      # target class name (str) or class
    secondary=None,                # M2M association table
    back_populates=None,           # bidirectional partner attribute name
    backref=None,                  # auto-create reverse (prefer back_populates)
    uselist=True,                  # False for scalar (one-to-one)
    lazy="select",                 # loading strategy (see table)
    cascade="save-update, merge",  # cascade operations
    passive_deletes=False,         # True to rely on DB CASCADE
    order_by=None,                 # default ordering
    primaryjoin=None,              # custom join condition
    secondaryjoin=None,            # custom M2M join
    foreign_keys=None,             # explicit FK columns
    remote_side=None,              # for self-referential
    viewonly=False,                # read-only relationship
    overlaps=None,                 # silence overlap warnings
    innerjoin=False,               # use INNER JOIN for joinedload
    info=None,                     # custom metadata dict
)
```

### lazy Options

| Value | Behavior | Best For |
|-------|----------|----------|
| `"select"` | Lazy load on access (default) | General use (sync only) |
| `"selectin"` | Batch SELECT...IN on parent load | Collections |
| `"joined"` | JOIN on parent load | Scalar/small relations |
| `"subquery"` | Subquery on parent load | Deep nesting |
| `"immediate"` | Separate SELECT immediately | Rare |
| `"noload"` | Never load (always empty) | Write-only intent |
| `"raise"` | Raise on access | Catch N+1 bugs |
| `"write_only"` | `WriteOnlyMapped` behavior | Large collections |
| `"dynamic"` | Returns Query (deprecated) | Migrate to write_only |

### cascade Options

| Value | Effect |
|-------|--------|
| `"save-update"` | Add child when parent added (default) |
| `"merge"` | Merge child when parent merged (default) |
| `"delete"` | Delete child when parent deleted |
| `"delete-orphan"` | Delete child when removed from parent |
| `"expunge"` | Expunge child when parent expunged |
| `"refresh-expire"` | Refresh/expire child with parent |
| `"all"` | All of the above except delete-orphan |

Common combo: `cascade="all, delete-orphan", passive_deletes=True`

---

## 5. mapped_column() Options

```python
from sqlalchemy.orm import mapped_column

mapped_column(
    __type=None,                   # SQL type (String(50), Integer, etc.)
    *args,                         # positional: ForeignKey, constraints
    init=True,                     # include in dataclass __init__
    repr=True,                     # include in dataclass __repr__
    default=None,                  # Python default value
    default_factory=None,          # callable for mutable defaults
    nullable=None,                 # inferred from Mapped[X | None]
    primary_key=False,             # PK column
    autoincrement="auto",          # auto-increment (True/False/"auto")
    unique=False,                  # UNIQUE constraint
    index=False,                   # create index
    name=None,                     # column name (if different from attribute)
    key=None,                      # mapper key (rarely needed)
    server_default=None,           # DDL DEFAULT (func.now(), text("0"))
    server_onupdate=None,          # DDL ON UPDATE
    onupdate=None,                 # Python-side on update
    insert_default=None,           # default for INSERT only
    comment=None,                  # column comment in DDL
    info=None,                     # custom metadata dict
    type_=None,                    # alternative to positional type
    sort_order=None,               # controls column ordering in CREATE TABLE
    use_existing_column=False,     # reuse column from parent (inheritance)
    deferred=False,                # defer loading until accessed
    deferred_group=None,           # group deferred columns
    deferred_raiseload=False,      # raise on deferred access
    active_history=False,          # track old values on change
    compare=True,                  # include in dataclass comparison
    kw_only=False,                 # keyword-only in dataclass __init__
)
```

### Nullability Rules

```python
id: Mapped[int]              # NOT NULL (inferred)
name: Mapped[str | None]     # NULLABLE (inferred)
age: Mapped[int] = mapped_column(nullable=True)  # explicit override
```

### Type Inference

```python
# These are equivalent:
name: Mapped[str] = mapped_column()           # infers VARCHAR
name: Mapped[str] = mapped_column(String)     # explicit type

# Override inferred type:
name: Mapped[str] = mapped_column(String(50)) # VARCHAR(50)
data: Mapped[dict] = mapped_column(JSONB)     # override to JSONB
```

---

## 6. Engine Configuration

```python
from sqlalchemy import create_engine
from sqlalchemy.ext.asyncio import create_async_engine

engine = create_engine(
    url,                           # "dialect+driver://user:pass@host:port/db"
    echo=False,                    # log SQL (True for debug)
    echo_pool=False,               # log pool events
    pool_size=5,                   # see Pool Configuration
    max_overflow=10,
    pool_timeout=30,
    pool_recycle=-1,
    pool_pre_ping=False,
    poolclass=None,                # QueuePool, NullPool, StaticPool
    isolation_level=None,          # "SERIALIZABLE", "READ COMMITTED", etc.
    execution_options=None,        # dict of execution options
    connect_args=None,             # dict passed to DBAPI connect()
    query_cache_size=500,          # compiled query cache size
    logging_name=None,             # logger name for this engine
    hide_parameters=False,         # hide params in logs (security)
    json_serializer=None,          # custom JSON serializer for JSONB
    json_deserializer=None,        # custom JSON deserializer
)
```

### URL Formats

```python
# PostgreSQL
"postgresql+psycopg2://user:pass@host:5432/db"   # sync (psycopg2)
"postgresql+psycopg://user:pass@host:5432/db"     # sync (psycopg3)
"postgresql+asyncpg://user:pass@host:5432/db"     # async

# MySQL
"mysql+pymysql://user:pass@host:3306/db"          # sync
"mysql+aiomysql://user:pass@host:3306/db"         # async

# SQLite
"sqlite:///path/to/db.sqlite"                     # file
"sqlite:///:memory:"                              # in-memory
"sqlite+aiosqlite:///path/to/db.sqlite"           # async

# Connection string with options
"postgresql://user:pass@host/db?sslmode=require&connect_timeout=10"
```

### connect_args Examples

```python
# PostgreSQL SSL
engine = create_engine(url, connect_args={
    "sslmode": "verify-full",
    "sslrootcert": "/path/to/ca.pem",
})

# SQLite WAL mode
engine = create_engine("sqlite:///app.db", connect_args={
    "check_same_thread": False,  # for multi-threaded apps
})

# MySQL charset
engine = create_engine(url, connect_args={
    "charset": "utf8mb4",
})
```

---

## 7. Pool Configuration

```python
from sqlalchemy.pool import QueuePool, NullPool, StaticPool, AsyncAdaptedQueuePool

engine = create_engine(
    url,
    poolclass=QueuePool,           # default for most dialects
    pool_size=5,                   # persistent connections (default 5)
    max_overflow=10,               # extra connections above pool_size (default 10)
    pool_timeout=30,               # seconds to wait for connection (default 30)
    pool_recycle=3600,             # recycle connections after N seconds (-1 = never)
    pool_pre_ping=True,            # test connection viability before checkout
    pool_reset_on_return="rollback",  # "rollback", "commit", or None
    pool_use_lifo=False,           # True = reuse most-recent connection
)
```

### Pool Classes

| Class | Use Case |
|-------|----------|
| `QueuePool` | Default. Connection pool with overflow. |
| `NullPool` | No pooling. New connection per request. Serverless/CLI. |
| `StaticPool` | Single connection, reused. In-memory SQLite testing. |
| `AsyncAdaptedQueuePool` | Default for async engines. |
| `SingletonThreadPool` | One connection per thread. SQLite default. |

### Pool Sizing Guidelines

```
pool_size = expected_concurrent_connections
max_overflow = burst_capacity
total_max = pool_size + max_overflow ≤ database max_connections / num_app_instances
```

```python
# Production web app (gunicorn with 4 workers)
# DB max_connections = 100 → per worker: 100/4 = 25
engine = create_engine(url, pool_size=15, max_overflow=10)

# Background worker
engine = create_engine(url, pool_size=3, max_overflow=2)

# Serverless (Lambda, Cloud Functions)
engine = create_engine(url, poolclass=NullPool)

# Testing with in-memory SQLite
engine = create_engine("sqlite://", poolclass=StaticPool)
```

### Pool Monitoring

```python
pool = engine.pool
print(f"Size: {pool.size()}")
print(f"Checked out: {pool.checkedout()}")
print(f"Overflow: {pool.overflow()}")
print(f"Checked in: {pool.checkedin()}")
```

---

## 8. Query API: New Style vs Legacy

### Migration Table

| Legacy (1.x) | New Style (2.0) |
|---------------|-----------------|
| `session.query(User)` | `session.execute(select(User))` |
| `session.query(User).get(1)` | `session.get(User, 1)` |
| `session.query(User).filter_by(name="A")` | `select(User).where(User.name == "A")` |
| `session.query(User).filter(User.id > 5)` | `select(User).where(User.id > 5)` |
| `query.all()` | `session.scalars(stmt).all()` |
| `query.first()` | `session.scalars(stmt).first()` |
| `query.one()` | `session.execute(stmt).scalar_one()` |
| `query.one_or_none()` | `session.execute(stmt).scalar_one_or_none()` |
| `query.count()` | `session.scalar(select(func.count()).select_from(User))` |
| `query.join(Post)` | `select(User).join(Post)` |
| `query.options(...)` | `select(User).options(...)` |
| `query.order_by(User.name)` | `select(User).order_by(User.name)` |
| `query.limit(10).offset(20)` | `select(User).limit(10).offset(20)` |
| `query.distinct()` | `select(User).distinct()` |
| `query.group_by(User.role)` | `select(User.role).group_by(User.role)` |
| `query.having(...)` | `select(...).group_by(...).having(...)` |
| `query.subquery()` | `select(...).subquery()` |
| `query.exists()` | `select(User).exists()` |
| `query.update({...})` | `session.execute(update(User).values(...))` |
| `query.delete()` | `session.execute(delete(User).where(...))` |

### Key Behavioral Differences

```python
# 1.x: query returns ORM objects directly
users = session.query(User).all()  # → [User, User, ...]

# 2.0: execute returns Row objects; use scalars() for ORM objects
result = session.execute(select(User))
rows = result.all()               # → [Row(User), Row(User), ...]
users = result.scalars().all()    # → [User, User, ...]

# Shorthand:
users = session.scalars(select(User)).all()  # → [User, User, ...]

# 2.0: Multi-entity queries return Row tuples
result = session.execute(select(User, Post).join(Post))
for user, post in result:  # tuple unpacking
    print(user.name, post.title)
```

### Enabling 2.0 Warnings in 1.4

```python
# Add to engine to catch legacy API usage during migration
engine = create_engine(url, future=True)  # raises on legacy patterns
Session = sessionmaker(bind=engine, future=True)
```
