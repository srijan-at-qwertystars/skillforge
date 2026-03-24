# SQLAlchemy Troubleshooting Guide

> Diagnosis and fixes for common SQLAlchemy issues. Each section: symptom → cause → fix → prevention.

## Table of Contents

1. [DetachedInstanceError](#detachedinstanceerror)
2. [N+1 Query Problem (Lazy Loading)](#n1-query-problem-lazy-loading)
3. [Session Scope Management](#session-scope-management)
4. [greenlet_spawn Errors in Async](#greenlet_spawn-errors-in-async)
5. [Identity Map Confusion](#identity-map-confusion)
6. [Stale Data Reads](#stale-data-reads)
7. [Migration Conflicts with Autogenerate](#migration-conflicts-with-autogenerate)
8. [Connection Pool Exhaustion](#connection-pool-exhaustion)
9. [Thread Safety Violations](#thread-safety-violations)
10. [Implicit Autoflush Problems](#implicit-autoflush-problems)
11. [Cascade Delete Gotchas](#cascade-delete-gotchas)
12. [Relationship Loading Strategy Conflicts](#relationship-loading-strategy-conflicts)
13. [Bulk vs ORM Performance](#bulk-vs-orm-performance)

---

## DetachedInstanceError

### Symptom
```
sqlalchemy.orm.exc.DetachedInstanceError: Instance <User at 0x...> is not bound
to a Session; attribute refresh operation cannot proceed
```

### Cause
Accessing a lazy-loaded relationship or expired attribute after the session is closed.

```python
# Broken
def get_user():
    with Session(engine) as session:
        user = session.get(User, 1)
    return user  # session closed

user = get_user()
print(user.posts)  # DetachedInstanceError — posts not loaded, session gone
```

### Fixes

**1. Eager load before closing:**
```python
def get_user():
    with Session(engine) as session:
        stmt = select(User).where(User.id == 1).options(selectinload(User.posts))
        return session.scalar(stmt)
```

**2. Set `expire_on_commit=False`:**
```python
Session = sessionmaker(engine, expire_on_commit=False)
# Attributes won't expire after commit — but values may be stale
```

**3. Keep session open through the request lifecycle** (web apps):
```python
# FastAPI dependency
async def get_db():
    async with AsyncSessionLocal() as session:
        yield session  # open for entire request
```

### Prevention
- Default to `selectinload`/`joinedload` for relationships you know you'll access.
- In API contexts, always set `expire_on_commit=False`.
- Use DTOs/Pydantic models: convert ORM objects to plain objects while session is open.

---

## N+1 Query Problem (Lazy Loading)

### Symptom
Iterating over a collection triggers one query per item:
```
SELECT * FROM users                    -- 1 query
SELECT * FROM posts WHERE user_id = 1  -- N queries
SELECT * FROM posts WHERE user_id = 2
SELECT * FROM posts WHERE user_id = 3
...
```

### Detection

```python
# Enable echo to see queries
engine = create_engine(url, echo=True)

# Or use sqlalchemy event-based counter
from sqlalchemy import event

query_count = 0

@event.listens_for(engine, "before_cursor_execute")
def count_queries(conn, cursor, statement, parameters, context, executemany):
    global query_count
    query_count += 1

# In tests: assert query_count == expected
```

### Fix

```python
# joinedload — single query with JOIN (best for *-to-one)
stmt = select(Post).options(joinedload(Post.author))

# selectinload — second query with IN clause (best for *-to-many)
stmt = select(User).options(selectinload(User.posts))

# Nested: load posts and each post's tags
stmt = select(User).options(
    selectinload(User.posts).selectinload(Post.tags)
)

# Set default loading strategy on the relationship
class User(Base):
    posts: Mapped[list["Post"]] = relationship(
        back_populates="author", lazy="selectin"
    )
```

### Prevention
- **Never use `lazy="select"` (the default) for relationships accessed in loops.**
- Set `lazy="selectin"` or `lazy="joined"` on relationships that are always needed.
- Use `raiseload` to make lazy loading an error during development:
```python
stmt = select(User).options(raiseload("*"))
# Raises if any relationship is lazy-loaded — forces explicit loading
```

---

## Session Scope Management

### Symptom
Stale data, concurrent modification issues, or `InvalidRequestError: This session is in 'committed' state`.

### Cause
Reusing a single session across requests, threads, or long-lived processes.

### Rules

| Context | Scope | Pattern |
|---------|-------|---------|
| Web request | Per-request | Dependency injection / middleware |
| CLI script | Per-operation | `with Session() as s:` block |
| Background job | Per-job | New session per task |
| Tests | Per-test | Fixture with rollback |

### Web App Pattern (FastAPI)

```python
from contextlib import asynccontextmanager

async def get_db() -> AsyncGenerator[AsyncSession, None]:
    async with AsyncSessionLocal() as session:
        try:
            yield session
            await session.commit()
        except Exception:
            await session.rollback()
            raise

@app.get("/users/{user_id}")
async def get_user(user_id: int, db: AsyncSession = Depends(get_db)):
    return await db.get(User, user_id)
```

### Background Worker Pattern

```python
# Celery task — new session per task
@celery_app.task
def process_order(order_id: int):
    with Session(engine) as session:
        order = session.get(Order, order_id)
        order.status = "processed"
        session.commit()
    # session is closed and returned to pool
```

### Anti-patterns
- ❌ Global session shared across threads
- ❌ Long-lived session that spans multiple operations without clearing
- ❌ Passing ORM objects between different sessions

---

## greenlet_spawn Errors in Async

### Symptom
```
sqlalchemy.exc.MissingGreenlet: greenlet_spawn has not been called; can't call
await_only() here. Was IO attempted in an unexpected place?
```

### Cause
Lazy-loading a relationship or accessing an expired attribute in async code. SQLAlchemy's async layer requires explicit `await`, but lazy loads are synchronous.

### Fixes

**1. Eager load:**
```python
stmt = select(User).options(selectinload(User.posts))
user = await session.scalar(stmt)
print(user.posts)  # already loaded — no lazy load
```

**2. Use `awaitable_attrs` (SQLAlchemy 2.0.13+):**
```python
user = await session.get(User, 1)
posts = await user.awaitable_attrs.posts  # async-safe lazy load
```

**3. Use `run_sync` for sync-only operations:**
```python
async with AsyncSessionLocal() as session:
    def do_work(sync_session):
        user = sync_session.get(User, 1)
        return user.posts  # sync lazy load is fine here

    posts = await session.run_sync(do_work)
```

**4. Set `expire_on_commit=False`:**
```python
AsyncSessionLocal = async_sessionmaker(engine, expire_on_commit=False)
# Prevents expiration that triggers lazy reloads
```

### Prevention
- Always use `selectinload` / `joinedload` in async code.
- Set `lazy="selectin"` as default on frequently accessed relationships.
- Run `raiseload("*")` in development to catch unintended lazy loads.

---

## Identity Map Confusion

### Symptom
Querying the same row returns the same Python object (expected), but objects seem to have outdated values, or changes to one reference don't appear on another.

### Cause
SQLAlchemy's identity map ensures one Python object per primary key per session. `session.get(User, 1)` always returns the same instance within a session. But:
- After `session.expire_all()` or `session.commit()`, attributes are lazily refreshed on next access.
- A second `session.execute(select(User))` merges results into existing identity map objects.

### Fixes

```python
# Force refresh from DB
session.expire(user)         # expire specific instance
session.refresh(user)        # immediately reload from DB
session.expire_all()         # expire all loaded instances

# Get fresh data bypassing identity map
stmt = select(User).where(User.id == 1).execution_options(populate_existing=True)
```

### Key Points
- Identity map is **per-session**. Different sessions have different maps.
- `expire_on_commit=True` (default) expires everything after commit.
- In long-running sessions, call `session.expire_all()` before reading if concurrent writes are possible.

---

## Stale Data Reads

### Symptom
Reading data that was just updated by another process/session, but getting old values.

### Cause
- Session's identity map caches loaded objects.
- Autoflush may not be triggered before a read.
- Transaction isolation level may prevent seeing uncommitted changes.

### Fixes

```python
# 1. Start a new session for fresh reads
with Session(engine) as session:
    user = session.get(User, 1)  # fresh from DB

# 2. Expire and re-read within existing session
session.expire(user)
session.refresh(user)

# 3. Use populate_existing for specific queries
stmt = select(User).execution_options(populate_existing=True)

# 4. Set isolation level per-transaction for critical reads
with engine.connect().execution_options(
    isolation_level="READ COMMITTED"
) as conn:
    result = conn.execute(select(User))
```

---

## Migration Conflicts with Autogenerate

### Symptom
- Autogenerate produces empty or incorrect migrations.
- Multiple developers create conflicting migration heads.
- `alembic upgrade head` fails with "Multiple head revisions."

### Fixes

**Empty migrations — models not imported:**
```python
# In env.py — import ALL model modules before setting target_metadata
from myapp.models.user import User      # noqa: F401
from myapp.models.post import Post      # noqa: F401
from myapp.models import Base
target_metadata = Base.metadata
```

**Multiple heads:**
```bash
# See all heads
alembic heads

# Merge heads
alembic merge heads -m "merge branches"

# Then upgrade
alembic upgrade head
```

**Autogenerate misses changes:**
Alembic cannot detect: column renames, table renames, some type changes, CHECK constraints, or changes to server defaults.

```python
# Manual migration for column rename
def upgrade():
    op.alter_column("users", "name", new_column_name="full_name")

# Manual migration for type change
def upgrade():
    op.alter_column(
        "users", "age",
        existing_type=sa.String(10),
        type_=sa.Integer(),
        postgresql_using="age::integer",
    )
```

### Prevention
- Set naming conventions on `MetaData` — ensures deterministic constraint names.
- Use a single `Base` across all models.
- Import all models in `env.py`.
- Review every autogenerated migration before applying.

---

## Connection Pool Exhaustion

### Symptom
```
sqlalchemy.exc.TimeoutError: QueuePool limit of size 5 overflow 10 reached,
connection timed out, timeout 30.00
```

### Cause
All connections checked out and not returned. Usually from:
- Unclosed sessions.
- Forgetting to use context managers.
- Long-running transactions holding connections.
- Background tasks not returning connections.

### Diagnosis

```python
from sqlalchemy import event

@event.listens_for(engine, "checkout")
def log_checkout(dbapi_connection, connection_record, connection_proxy):
    import traceback
    connection_record.info["traceback"] = traceback.format_stack()

@event.listens_for(engine, "checkin")
def log_checkin(dbapi_connection, connection_record):
    connection_record.info.pop("traceback", None)

# Monitor pool status
print(engine.pool.status())  # checked out, overflow, pool size
```

### Fixes

```python
# 1. Increase pool size
engine = create_engine(url, pool_size=20, max_overflow=30, pool_timeout=60)

# 2. Use NullPool for serverless / short-lived processes
from sqlalchemy.pool import NullPool
engine = create_engine(url, poolclass=NullPool)

# 3. Always use context managers
with Session(engine) as session:
    ...  # guaranteed cleanup

# 4. Detect and recycle stale connections
engine = create_engine(url, pool_pre_ping=True, pool_recycle=1800)

# 5. For async — dispose properly on shutdown
async def shutdown():
    await async_engine.dispose()
```

### Prevention
- **Always** use `with Session(engine) as session:` or dependency injection.
- Set `pool_pre_ping=True` for long-running applications.
- Monitor pool status in production (expose as metric).

---

## Thread Safety Violations

### Symptom
Random `ProgrammingError`, corrupted state, or crashes under concurrent access.

### Cause
`Session` is **not thread-safe**. Sharing a session between threads causes undefined behavior.

### Rules
- **Engine:** thread-safe, share freely.
- **Session:** NOT thread-safe, one per thread.
- **Connection:** NOT thread-safe.
- **ORM objects:** NOT safe to share across sessions.

### Fix with scoped_session (thread-local)

```python
from sqlalchemy.orm import scoped_session, sessionmaker

SessionFactory = sessionmaker(engine)
ScopedSession = scoped_session(SessionFactory)

# Each thread gets its own session
def thread_work():
    session = ScopedSession()
    try:
        user = session.get(User, 1)
        session.commit()
    finally:
        ScopedSession.remove()  # must call to release
```

### Async
Async sessions must not be shared across tasks:
```python
# Each task gets its own session
async def process_item(item_id: int):
    async with AsyncSessionLocal() as session:
        item = await session.get(Item, item_id)
        item.processed = True
        await session.commit()
```

---

## Implicit Autoflush Problems

### Symptom
`IntegrityError` during a query (not during an explicit flush/commit), or unexpected SQL emissions.

### Cause
`Session.autoflush = True` (default) flushes pending changes to the DB before every query. If pending objects violate constraints, the query raises.

```python
with Session(engine) as session:
    user = User(email=None)  # email is NOT NULL
    session.add(user)
    # This query triggers autoflush, which tries to INSERT user → IntegrityError
    other = session.scalars(select(User).where(User.id == 99)).first()
```

### Fixes

```python
# 1. Disable autoflush temporarily
with session.no_autoflush:
    result = session.scalars(select(User)).all()
    # pending objects are NOT flushed

# 2. Disable autoflush globally (not recommended — breaks identity map guarantees)
Session = sessionmaker(engine, autoflush=False)

# 3. Fix the root cause: validate before adding
user = User(email=email)
if not user.email:
    raise ValueError("Email required")
session.add(user)
```

### Best Practice
Keep autoflush enabled but validate data before `session.add()`. Use `session.no_autoflush` for read-only queries where pending writes shouldn't affect results.

---

## Cascade Delete Gotchas

### Symptom
- Orphan child rows left in DB after parent deletion.
- `IntegrityError` on parent delete due to FK constraints.
- Children deleted when you only wanted to disassociate them.

### Cause
Confusion between SQLAlchemy cascades (`cascade` on relationship) and database-level cascades (`ondelete` on ForeignKey).

### The Two Cascade Systems

```python
class User(Base):
    __tablename__ = "users"
    id: Mapped[int] = mapped_column(primary_key=True)
    posts: Mapped[list["Post"]] = relationship(
        back_populates="author",
        cascade="all, delete-orphan",  # ORM-level cascade
    )

class Post(Base):
    __tablename__ = "posts"
    id: Mapped[int] = mapped_column(primary_key=True)
    author_id: Mapped[int] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"),  # DB-level cascade
    )
    author: Mapped["User"] = relationship(back_populates="posts")
```

**ORM cascade** (`cascade="all, delete-orphan"`):
- Works when you delete via `session.delete(user)`.
- SQLAlchemy loads all children and issues individual DELETEs.
- Fires events (`before_delete`, etc.).
- ⚠️ Does NOT work with bulk `session.execute(delete(User))`.

**DB cascade** (`ondelete="CASCADE"`):
- Works at database level — even for bulk deletes.
- No ORM events fired.
- Set `passive_deletes=True` on relationship to tell SQLAlchemy to trust DB cascade:

```python
posts: Mapped[list["Post"]] = relationship(
    back_populates="author",
    cascade="all, delete-orphan",
    passive_deletes=True,  # don't load children — let DB cascade handle it
)
```

### Common Mistakes

```python
# ❌ Bulk delete — ORM cascade NOT triggered
session.execute(delete(User).where(User.id == 1))
# Children still exist → FK violation if no DB cascade

# ✅ ORM delete — cascade triggered
user = session.get(User, 1)
session.delete(user)
session.commit()

# ✅ Bulk delete with DB cascade
# Requires ondelete="CASCADE" on FK
session.execute(delete(User).where(User.id == 1))
```

---

## Relationship Loading Strategy Conflicts

### Symptom
`InvalidRequestError` about conflicting loader options, or unexpected query patterns.

### Cause
Mixing conflicting loader strategies on the same path.

### Rules

```python
# ❌ Conflicting strategies on same relationship
stmt = select(User).options(
    joinedload(User.posts),
    selectinload(User.posts),  # CONFLICT
)

# ✅ Different strategies for different levels
stmt = select(User).options(
    selectinload(User.posts).joinedload(Post.author),
)

# ✅ Override default strategy
class User(Base):
    posts: Mapped[list["Post"]] = relationship(lazy="selectin")

# Override for specific query
stmt = select(User).options(lazyload(User.posts))  # override to lazy
```

### Wildcard Loading

```python
from sqlalchemy.orm import raiseload, lazyload

# Raise error on any unloaded relationship (dev/debug)
stmt = select(User).options(raiseload("*"))

# Explicitly load only what you need
stmt = select(User).options(
    raiseload("*"),
    selectinload(User.posts),  # only posts loaded
)
```

---

## Bulk vs ORM Performance

### When to Use What

| Operation | Rows | Use | Why |
|-----------|------|-----|-----|
| Insert | < 100 | `session.add_all()` | Events, defaults, relationships |
| Insert | 100–10K | Core `insert()` | 10-50x faster, bypasses identity map |
| Insert | > 10K | `COPY` / bulk loader | Use psycopg `copy_from` or DB tool |
| Update | targeted | ORM `.attribute = value` | Tracked changes, events |
| Update | bulk | Core `update()` | Single SQL, no object loading |
| Delete | targeted | `session.delete(obj)` | Cascade, events |
| Delete | bulk | Core `delete()` | Single SQL (ensure DB cascades set) |
| Read | need objects | `session.scalars()` | Full ORM features |
| Read | need data only | Core `session.execute()` | Rows, no ORM overhead |

### Performance Comparison

```python
import time

# ORM: ~5s for 100K rows
start = time.time()
session.add_all([User(email=f"u{i}@x.com", name=f"User{i}") for i in range(100_000)])
session.commit()
print(f"ORM: {time.time() - start:.1f}s")

# Core: ~0.3s for 100K rows
start = time.time()
session.execute(
    insert(User),
    [{"email": f"u{i}@x.com", "name": f"User{i}"} for i in range(100_000)],
)
session.commit()
print(f"Core: {time.time() - start:.1f}s")

# insertmanyvalues (SQLAlchemy 2.0) — even faster with supported drivers
engine = create_engine(url, insertmanyvalues_page_size=10000)
```

### Chunked Bulk Insert

```python
def bulk_insert_chunked(session, model, data: list[dict], chunk_size: int = 5000):
    """Insert large datasets in chunks to manage memory."""
    for i in range(0, len(data), chunk_size):
        chunk = data[i : i + chunk_size]
        session.execute(insert(model), chunk)
        session.flush()  # write to DB but keep transaction open
    session.commit()
```
