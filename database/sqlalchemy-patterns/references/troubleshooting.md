# SQLAlchemy 2.0 Troubleshooting Guide

> Diagnosis and fixes for the most common SQLAlchemy production issues.

---

## Table of Contents

1. [N+1 Query Detection and Fixes](#1-n1-query-detection-and-fixes)
2. [Session Management Pitfalls](#2-session-management-pitfalls)
3. [Lazy Loading in Async Context](#3-lazy-loading-in-async-context)
4. [Connection Pool Exhaustion](#4-connection-pool-exhaustion)
5. [Migration Conflicts](#5-migration-conflicts)
6. [Slow Query Debugging](#6-slow-query-debugging)
7. [Memory Issues with Large Result Sets](#7-memory-issues-with-large-result-sets)
8. [Common Error Messages Reference](#8-common-error-messages-reference)

---

## 1. N+1 Query Detection and Fixes

### Symptom

Accessing a relationship in a loop fires one SQL query per parent row:

```
SELECT * FROM users;                    -- 1 query
SELECT * FROM posts WHERE user_id = 1;  -- N queries
SELECT * FROM posts WHERE user_id = 2;
SELECT * FROM posts WHERE user_id = 3;
...
```

### Detection Methods

**Method 1: SQL Echo Logging**
```python
engine = create_engine(url, echo=True)
# Watch for repeated SELECT patterns in logs
```

**Method 2: raiseload — Fail on Lazy Load**
```python
from sqlalchemy.orm import raiseload

# Per-query: error if any relationship is lazy-loaded
stmt = select(User).options(raiseload("*"))

# Per-relationship:
stmt = select(User).options(raiseload(User.posts))
```

**Method 3: Event-Based Counter**
```python
from sqlalchemy import event
import threading

_query_count = threading.local()

@event.listens_for(engine, "before_cursor_execute")
def _count_queries(conn, cursor, stmt, params, context, executemany):
    if not hasattr(_query_count, "count"):
        _query_count.count = 0
    _query_count.count += 1

def get_query_count() -> int:
    return getattr(_query_count, "count", 0)

def reset_query_count():
    _query_count.count = 0

# In tests:
reset_query_count()
users = session.scalars(select(User).options(selectinload(User.posts))).all()
for u in users:
    _ = u.posts  # should NOT trigger extra queries
assert get_query_count() == 2  # 1 for users, 1 for posts (batched)
```

**Method 4: SQLAlchemy Profiling with sqltap**
```bash
pip install sqltap
```
```python
import sqltap
profiler = sqltap.start(engine)
# ... run code ...
stats = profiler.collect()
sqltap.report(stats, "report.html")
```

### Fixes

| Strategy | Use When | Code |
|----------|----------|------|
| `selectinload` | Collections (1-to-many) | `.options(selectinload(User.posts))` |
| `joinedload` | Scalar/small relations | `.options(joinedload(User.profile))` |
| `subqueryload` | Deep nesting | `.options(subqueryload(User.posts))` |
| `immediateload` | Always load | `.options(immediateload(User.profile))` |
| `contains_eager` | Manual JOIN already done | `.join(User.posts).options(contains_eager(User.posts))` |

**Nested eager loading:**
```python
stmt = select(User).options(
    selectinload(User.posts).selectinload(Post.comments).selectinload(Comment.author),
    joinedload(User.profile),
)
```

**Default eager loading on model:**
```python
class User(Base):
    __tablename__ = "users"
    profile: Mapped["Profile"] = relationship(lazy="joined")      # always JOIN
    posts: Mapped[list["Post"]] = relationship(lazy="selectin")    # always batch SELECT
```

---

## 2. Session Management Pitfalls

### Detached Instance Error

**Error:** `DetachedInstanceError: Instance <User> is not bound to a Session; attribute refresh operation cannot proceed`

**Causes:**
- Accessing unloaded attributes after `session.close()` or `session.commit()`
- Returning ORM objects from a `with session:` block, then accessing lazy attributes

**Fixes:**

```python
# Fix 1: expire_on_commit=False (keeps attributes accessible after commit)
SessionLocal = sessionmaker(bind=engine, expire_on_commit=False)

# Fix 2: Eager load everything you need before closing
stmt = select(User).options(selectinload(User.posts), joinedload(User.profile))
user = session.scalar(stmt)
session.close()
# user.posts is still accessible

# Fix 3: Re-attach to a new session
with SessionLocal() as new_session:
    user = new_session.merge(user)  # re-attaches, may re-query
    print(user.posts)

# Fix 4: Access all needed attributes within session scope
with SessionLocal() as session:
    user = session.scalar(select(User).where(User.id == 1))
    data = {"name": user.name, "posts": [p.title for p in user.posts]}
# use `data` dict outside session — no ORM dependency
```

### Identity Map Confusion

The Session's identity map means `session.get(User, 1)` returns the same Python object every time (within the same session).

```python
u1 = session.get(User, 1)
u2 = session.get(User, 1)
assert u1 is u2  # True — same object

# Problem: stale data if another process updated the row
session.expire(u1)      # next access re-queries
session.refresh(u1)     # immediately re-queries

# Nuclear option: expire everything
session.expire_all()
```

### Session Scope Anti-Patterns

```python
# ❌ WRONG: shared session across requests
app.session = Session()  # never do this

# ❌ WRONG: long-lived session
session = Session()
while True:
    process(session)  # session accumulates objects, leaks memory

# ✅ RIGHT: request-scoped session
def get_db():
    with SessionLocal() as session:
        yield session

# ✅ RIGHT: scoped_session for thread-local (legacy apps)
from sqlalchemy.orm import scoped_session
Session = scoped_session(sessionmaker(bind=engine))
# Call Session.remove() at end of request
```

### Flush vs Commit Confusion

```python
session.add(user)
session.flush()   # SQL INSERT sent, but inside transaction — rollback possible
                  # user.id is now populated
session.commit()  # transaction committed — permanent
                  # all objects expired (if expire_on_commit=True)

# Common mistake: relying on auto-flush for IDs
user = User(name="Alice")
session.add(user)
print(user.id)    # None! Not flushed yet
session.flush()
print(user.id)    # 42 — now populated
```

---

## 3. Lazy Loading in Async Context

### The Problem

**Error:** `MissingGreenlet: greenlet_spawn has not been called; can't call await_() here. Was IO attempted in an unexpected place?`

This happens when async code triggers a synchronous lazy load (which requires blocking I/O).

### Fix 1: Always Eager Load with Async

```python
# ALWAYS specify loading strategy with AsyncSession
async with async_session() as session:
    stmt = select(User).options(
        selectinload(User.posts),
        joinedload(User.profile),
    )
    user = (await session.execute(stmt)).scalar_one()
    # user.posts is loaded — no lazy load triggered
```

### Fix 2: AsyncAttrs Mixin

```python
from sqlalchemy.ext.asyncio import AsyncAttrs
from sqlalchemy.orm import DeclarativeBase

class Base(AsyncAttrs, DeclarativeBase):
    pass

# Now you can await lazy attributes:
async with async_session() as session:
    user = await session.get(User, 1)
    posts = await user.awaitable_attrs.posts  # async lazy load
    profile = await user.awaitable_attrs.profile
```

### Fix 3: run_sync for Complex Operations

```python
async with async_session() as session:
    def sync_work(session):
        user = session.get(User, 1)
        # Can freely access lazy-loaded attributes here
        return {"name": user.name, "post_count": len(user.posts)}

    result = await session.run_sync(sync_work)
```

### Async Loading Strategy Matrix

| Approach | Pros | Cons |
|----------|------|------|
| Eager load (`selectinload`) | Predictable, no surprises | Must specify upfront |
| `AsyncAttrs` mixin | Flexible, lazy-like | Each access = separate query |
| `run_sync` | Full sync API available | Blocks the event loop worker |
| `raiseload("*")` | Catches mistakes early | Dev-only safety net |

---

## 4. Connection Pool Exhaustion

### Symptom

**Error:** `TimeoutError: QueuePool limit of size 5 overflow 10 reached, connection timed out, timeout 30.00`

### Diagnosis

```python
# Check pool status
from sqlalchemy import event

@event.listens_for(engine, "checkout")
def log_checkout(dbapi_conn, connection_record, connection_proxy):
    log.debug(f"Pool checkout. Pool size: {engine.pool.size()}, "
              f"Checked out: {engine.pool.checkedout()}, "
              f"Overflow: {engine.pool.overflow()}")

@event.listens_for(engine, "checkin")
def log_checkin(dbapi_conn, connection_record):
    log.debug(f"Pool checkin. Checked out: {engine.pool.checkedout()}")

# Runtime inspection
print(f"Pool size: {engine.pool.size()}")
print(f"Checked out: {engine.pool.checkedout()}")
print(f"Overflow: {engine.pool.overflow()}")
print(f"Checked in: {engine.pool.checkedin()}")
```

### Common Causes and Fixes

**Cause 1: Sessions not closed**
```python
# ❌ Leak
session = Session()
result = session.execute(stmt)
# forgot session.close()

# ✅ Fix: always use context manager
with Session() as session:
    result = session.execute(stmt)
```

**Cause 2: Unfinished iterations**
```python
# ❌ Leak: result not fully consumed, connection held
result = session.execute(select(User))
first = result.first()  # connection still held if more rows exist

# ✅ Fix: close result explicitly or use scalars
result = session.execute(select(User))
first = result.first()
result.close()
```

**Cause 3: Background tasks holding sessions**
```python
# ❌ Leak: FastAPI background task holds session
@app.post("/users")
async def create_user(bg: BackgroundTasks, db: Session = Depends(get_db)):
    user = User(name="test")
    db.add(user); db.commit()
    bg.add_task(send_email, user.email)  # session scope extends to bg task

# ✅ Fix: create separate session in background task
def send_email_task(user_id: int):
    with SessionLocal() as session:
        user = session.get(User, user_id)
        send_email(user.email)
```

**Cause 4: Pool misconfiguration**
```python
# Tune for your workload
engine = create_engine(
    url,
    pool_size=20,          # max persistent connections
    max_overflow=10,       # extra connections beyond pool_size
    pool_timeout=30,       # seconds to wait for connection
    pool_recycle=1800,     # recycle connections after 30min (MySQL needs this)
    pool_pre_ping=True,    # test connection viability before use
)

# For serverless / CLI (no pooling):
from sqlalchemy.pool import NullPool
engine = create_engine(url, poolclass=NullPool)
```

---

## 5. Migration Conflicts

### Multiple Heads

**Error:** `alembic.util.exc.CommandError: Multiple head revisions are present`

```bash
# Diagnose
alembic heads        # shows multiple head revisions
alembic history      # show revision tree

# Fix: merge heads
alembic merge heads -m "merge_branches"
alembic upgrade head
```

### Autogenerate Misses or False Positives

**Autogenerate CANNOT detect:**
- Column renames (shows as drop + add)
- Table renames
- Changes to constraints without name changes
- Data migrations
- Custom DDL

```python
# Manual migration for renames:
def upgrade():
    op.alter_column("users", "name", new_column_name="full_name")

# Exclude tables from autogenerate:
# In env.py:
def include_name(name, type_, parent_names):
    if type_ == "table" and name in ("alembic_version", "spatial_ref_sys"):
        return False
    return True

context.configure(
    connection=connection,
    target_metadata=target_metadata,
    include_name=include_name,
)
```

### Migration Ordering Issues

```python
# Specify explicit dependency
revision = "abc123"
down_revision = "def456"
depends_on = "ghi789"  # ensures ghi789 runs first even if on different branch

# Stamp without running (fix broken state)
# alembic stamp abc123  — marks DB as at revision abc123 without running migrations
```

### Circular FK Dependencies in Migrations

```python
def upgrade():
    # Create tables without FKs first
    op.create_table("users", sa.Column("id", sa.Integer, primary_key=True))
    op.create_table("teams", sa.Column("id", sa.Integer, primary_key=True))

    # Add FKs separately
    op.add_column("users", sa.Column("team_id", sa.Integer))
    op.create_foreign_key("fk_user_team", "users", "teams", ["team_id"], ["id"])
```

---

## 6. Slow Query Debugging

### SQL Logging

```python
# Basic echo
engine = create_engine(url, echo=True)

# Targeted logging
import logging
logging.getLogger("sqlalchemy.engine").setLevel(logging.INFO)   # SQL statements
logging.getLogger("sqlalchemy.pool").setLevel(logging.DEBUG)     # pool events
logging.getLogger("sqlalchemy.orm").setLevel(logging.DEBUG)      # ORM events
```

### Query Compilation Inspection

```python
from sqlalchemy.dialects import postgresql

stmt = select(User).where(User.name == "Alice")

# See compiled SQL with literal values
print(stmt.compile(
    dialect=postgresql.dialect(),
    compile_kwargs={"literal_binds": True}
))
```

### Slow Query Event Hook

```python
import time
from sqlalchemy import event

@event.listens_for(engine, "before_cursor_execute")
def before_execute(conn, cursor, statement, parameters, context, executemany):
    conn.info["query_start"] = time.perf_counter()

@event.listens_for(engine, "after_cursor_execute")
def after_execute(conn, cursor, statement, parameters, context, executemany):
    elapsed = time.perf_counter() - conn.info["query_start"]
    if elapsed > 0.5:  # 500ms threshold
        log.warning(
            f"SLOW QUERY ({elapsed:.3f}s):\n{statement}\nParams: {parameters}"
        )
```

### EXPLAIN Integration

```python
def explain_query(session, stmt, analyze=False):
    """Run EXPLAIN (ANALYZE) on a statement."""
    prefix = "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)" if analyze else "EXPLAIN (FORMAT JSON)"
    result = session.execute(text(f"{prefix} {stmt.compile(dialect=session.bind.dialect)}"))
    return result.scalar()

# Or use SQLAlchemy's prefix:
stmt = select(User).where(User.is_active == True).prefix_with("EXPLAIN ANALYZE")
result = session.execute(stmt)
print(result.all())
```

### Common Performance Fixes

| Problem | Fix |
|---------|-----|
| Missing index | Add `index=True` to `mapped_column()` or create via migration |
| Loading too many columns | Use `load_only(User.id, User.name)` |
| Cartesian product from joinedload | Switch to `selectinload` for collections |
| Repeated queries in loop | Batch with `selectinload` or pre-fetch |
| Large IN clauses | Use subquery instead: `where(User.id.in_(select(sub.c.id)))` |

---

## 7. Memory Issues with Large Result Sets

### Problem

Loading millions of ORM objects materializes full Python objects → OOM.

### Fix 1: yield_per (Server-Side Streaming)

```python
# Sync
for user in session.scalars(select(User)).yield_per(1000):
    process(user)
    # Only 1000 objects in memory at a time

# Async
async for user in await session.stream_scalars(select(User)):
    process(user)
```

### Fix 2: Select Only Needed Columns

```python
# Returns lightweight Row objects, not full ORM instances
rows = session.execute(
    select(User.id, User.name, User.email)
).all()

# Or use load_only on ORM objects
stmt = select(User).options(load_only(User.id, User.name))
```

### Fix 3: Use Core for Bulk Reads

```python
# Core query — no ORM overhead
with engine.connect() as conn:
    result = conn.execute(text("SELECT id, name FROM users"))
    for row in result:
        process(row)
```

### Fix 4: Chunked Processing

```python
def process_in_chunks(session, stmt, chunk_size=1000):
    """Process large result sets in chunks to control memory."""
    offset = 0
    while True:
        chunk = session.scalars(
            stmt.order_by(User.id).offset(offset).limit(chunk_size)
        ).all()
        if not chunk:
            break
        for item in chunk:
            process(item)
        session.expire_all()  # release references
        offset += chunk_size
```

### Fix 5: Expunge Processed Objects

```python
for user in session.scalars(select(User)).yield_per(500):
    process(user)
    session.expunge(user)  # remove from identity map, allow GC
```

### Memory Profiling

```python
# Track identity map size
print(f"Objects in session: {len(session.identity_map)}")

# Use tracemalloc for detailed tracking
import tracemalloc
tracemalloc.start()
# ... run queries ...
snapshot = tracemalloc.take_snapshot()
top_stats = snapshot.statistics("lineno")
for stat in top_stats[:10]:
    print(stat)
```

---

## 8. Common Error Messages Reference

| Error | Cause | Fix |
|-------|-------|-----|
| `DetachedInstanceError` | Accessing attributes after session close | Eager load or `expire_on_commit=False` |
| `MissingGreenlet` | Lazy load in async context | Use `selectinload` or `AsyncAttrs` |
| `StaleDataError` | Concurrent modification with `version_id_col` | Retry with fresh data |
| `IntegrityError` | FK/unique constraint violation | Validate data or use `on_conflict_do_update` |
| `NoResultFound` | `.one()` returned no rows | Use `.one_or_none()` or `.first()` |
| `MultipleResultsFound` | `.one()` returned multiple rows | Add `.limit(1)` or fix query filter |
| `QueuePool limit reached` | Connection pool exhausted | Close sessions properly, increase pool |
| `ObjectNotExecutableError` | Passing select() without `session.execute()` | Use `session.execute(stmt)` not `session.query()` |
| `InvalidRequestError: already attached` | Adding object from one session to another | Use `session.merge()` instead of `session.add()` |
| `SAWarning: relationship X will copy column Y` | Overlapping FK in relationships | Add `overlaps="..."` parameter |
| `MovedIn20Warning` | Using 1.x API in 2.0 mode | Migrate to 2.0 style `select()` |
| `LegacyAPIWarning` | `session.query()` in 2.0 | Switch to `session.execute(select(...))` |
| `ArgumentError: cache_ok` | Custom type missing `cache_ok` | Add `cache_ok = True` to `TypeDecorator` |
