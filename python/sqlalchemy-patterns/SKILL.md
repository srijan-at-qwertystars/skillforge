---
name: sqlalchemy-patterns
description:
  positive: "Use when user works with SQLAlchemy 2.0, asks about declarative models, Session, queries, relationships, migrations with Alembic, async SQLAlchemy, or SQLAlchemy performance tuning."
  negative: "Do NOT use for Django ORM, Prisma (use prisma-orm skill), Drizzle (use drizzle-orm skill), or raw SQL without SQLAlchemy context."
---

# SQLAlchemy 2.0 Patterns & Best Practices

## Fundamentals

Create the engine, session factory, and declarative base:

```python
from sqlalchemy import create_engine
from sqlalchemy.orm import DeclarativeBase, Session, sessionmaker

engine = create_engine("postgresql+psycopg://user:pass@localhost/db", echo=False)
SessionLocal = sessionmaker(bind=engine)

class Base(DeclarativeBase):
    pass
```

- Use `create_engine` once at app startup. Pass `pool_pre_ping=True` for long-lived connections.
- Never share `Session` instances across threads. Create per-request or per-operation.
- Call `Base.metadata.create_all(engine)` only in dev/test. Use Alembic in production.

## Model Definition

Use `Mapped[]` and `mapped_column()` for full type safety:

```python
from datetime import datetime
from typing import Optional
from sqlalchemy import String, Text, func
from sqlalchemy.orm import Mapped, mapped_column

class User(Base):
    __tablename__ = "users"

    id: Mapped[int] = mapped_column(primary_key=True)
    username: Mapped[str] = mapped_column(String(50), unique=True, index=True)
    email: Mapped[str] = mapped_column(String(255), unique=True)
    bio: Mapped[Optional[str]] = mapped_column(Text, default=None)
    is_active: Mapped[bool] = mapped_column(default=True)
    created_at: Mapped[datetime] = mapped_column(server_default=func.now())
```

- `Mapped[str]` = NOT NULL. `Mapped[Optional[str]]` = nullable.
- Set `server_default` for DB-level defaults, `default` for Python-level.
- Use `__table_args__` for composite constraints: `UniqueConstraint`, `Index`, `CheckConstraint`.

## Relationships

### One-to-Many

```python
from sqlalchemy import ForeignKey
from sqlalchemy.orm import relationship

class User(Base):
    __tablename__ = "users"
    id: Mapped[int] = mapped_column(primary_key=True)
    posts: Mapped[list["Post"]] = relationship(back_populates="author", cascade="all, delete-orphan")

class Post(Base):
    __tablename__ = "posts"
    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"))
    author: Mapped["User"] = relationship(back_populates="posts")
```

### Many-to-Many with Association Table

```python
from sqlalchemy import Table, Column, ForeignKey

post_tags = Table(
    "post_tags", Base.metadata,
    Column("post_id", ForeignKey("posts.id"), primary_key=True),
    Column("tag_id", ForeignKey("tags.id"), primary_key=True),
)

class Post(Base):
    __tablename__ = "posts"
    id: Mapped[int] = mapped_column(primary_key=True)
    tags: Mapped[list["Tag"]] = relationship(secondary=post_tags, back_populates="posts")

class Tag(Base):
    __tablename__ = "tags"
    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(50), unique=True)
    posts: Mapped[list["Post"]] = relationship(secondary=post_tags, back_populates="tags")
```

- Always use `back_populates` over `backref` for explicit two-way navigation.
- Use `cascade="all, delete-orphan"` on the parent side when children cannot exist alone.

## Querying

Use the 2.0-style `select()` API — never the legacy `session.query()`:

```python
from sqlalchemy import select, and_, or_, func, exists

# Basic select
stmt = select(User).where(User.username == "alice")
user = session.execute(stmt).scalar_one_or_none()

# Filtering with multiple conditions
stmt = select(Post).where(and_(Post.user_id == 1, Post.is_published == True))

# Join
stmt = select(Post, User).join(User, Post.user_id == User.id)

# Subquery
subq = select(func.count(Post.id)).where(Post.user_id == User.id).correlate(User).scalar_subquery()
stmt = select(User.username, subq.label("post_count"))

# Exists
has_posts = exists().where(Post.user_id == User.id)
stmt = select(User).where(has_posts)

# CTE (Common Table Expression)
cte = select(User.id, func.count(Post.id).label("cnt")).join(Post).group_by(User.id).cte("user_counts")
stmt = select(User, cte.c.cnt).join(cte, User.id == cte.c.id).where(cte.c.cnt > 5)
```

- Use `session.execute(stmt).scalars().all()` to get a list of ORM objects.
- Use `.scalar_one()` when exactly one result is expected, `.scalar_one_or_none()` when zero or one.

## Session Management

```python
# Context manager pattern (preferred)
with Session(engine) as session:
    with session.begin():
        session.add(User(username="alice", email="a@b.com"))
    # auto-commits on exit, auto-rolls-back on exception

# Sessionmaker pattern for web apps
def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
```

- `session.add()` stages an object. `session.flush()` sends SQL without committing. `session.commit()` finalizes.
- `session.expunge(obj)` detaches an object from the session — use to return objects after session closes.
- `session.refresh(obj)` reloads from DB. Use after commit if `expire_on_commit=True` (default).
- For web apps, scope one session per request. Never let sessions span multiple requests.

## Eager & Lazy Loading

```python
from sqlalchemy.orm import selectinload, joinedload, subqueryload, raiseload

# selectinload — best for collections (issues SELECT ... WHERE id IN (...))
stmt = select(User).options(selectinload(User.posts))

# joinedload — best for single-valued (many-to-one), adds LEFT JOIN
stmt = select(Post).options(joinedload(Post.author))

# Nested eager loading
stmt = select(User).options(selectinload(User.posts).selectinload(Post.tags))

# raiseload — raises error if lazy load attempted (catches N+1 at dev time)
stmt = select(User).options(raiseload(User.posts))
```

- Default `lazy='select'` triggers a query on access — fine for single objects, dangerous in loops.
- Use `selectinload` for collections, `joinedload` for scalar relationships.
- Set `lazy="raise"` on relationships during development to detect N+1 issues early.

## Async SQLAlchemy

```python
from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession, async_sessionmaker

async_engine = create_async_engine("postgresql+asyncpg://user:pass@localhost/db")
AsyncSessionLocal = async_sessionmaker(async_engine, expire_on_commit=False)

async def get_users():
    async with AsyncSessionLocal() as session:
        stmt = select(User).options(selectinload(User.posts))
        result = await session.execute(stmt)
        return result.scalars().all()
```

### FastAPI Integration

```python
from fastapi import Depends, FastAPI

app = FastAPI()

async def get_session():
    async with AsyncSessionLocal() as session:
        yield session

@app.get("/users/{user_id}")
async def read_user(user_id: int, session: AsyncSession = Depends(get_session)):
    stmt = select(User).where(User.id == user_id).options(selectinload(User.posts))
    result = await session.execute(stmt)
    return result.scalar_one_or_none()
```

- Set `expire_on_commit=False` on async sessions to avoid `MissingGreenlet` errors.
- Never use lazy loading in async — always eager-load or `await session.refresh(obj, ["relation"])`.
- Use `asyncpg` for PostgreSQL, `aiosqlite` for SQLite.

## Alembic Migrations

```bash
# Initialize
alembic init alembic

# Generate migration from model changes
alembic revision --autogenerate -m "add users table"

# Apply migrations
alembic upgrade head

# Rollback one step
alembic downgrade -1

# Show current revision
alembic current
```

Configure `alembic/env.py`:

```python
from myapp.models import Base
target_metadata = Base.metadata
```

- Alembic runs synchronously — use a sync engine URL even if the app uses async.
- Always review autogenerated migrations before applying. Autogenerate misses: renamed columns, data migrations, custom types.
- Keep migrations small and atomic. One schema change per revision when possible.
- Test migrations bidirectionally: `upgrade` then `downgrade` then `upgrade` again.

## Advanced Queries

### Window Functions

```python
from sqlalchemy import func, over

stmt = select(
    User.username,
    func.row_number().over(order_by=User.created_at).label("row_num"),
    func.rank().over(partition_by=User.department_id, order_by=User.salary.desc()).label("dept_rank"),
)
```

### Hybrid Properties

```python
from sqlalchemy.ext.hybrid import hybrid_property

class User(Base):
    __tablename__ = "users"
    first_name: Mapped[str] = mapped_column(String(50))
    last_name: Mapped[str] = mapped_column(String(50))

    @hybrid_property
    def full_name(self) -> str:
        return f"{self.first_name} {self.last_name}"

    @full_name.expression
    @classmethod
    def full_name(cls):
        return cls.first_name + " " + cls.last_name
```

### Column Property

```python
from sqlalchemy.orm import column_property

class User(Base):
    __tablename__ = "users"
    first_name: Mapped[str] = mapped_column(String(50))
    last_name: Mapped[str] = mapped_column(String(50))
    full_name = column_property(first_name + " " + last_name)
```

## Inheritance Patterns

### Single Table Inheritance

One table, discriminator column. Use when subclasses share most columns.

```python
class Employee(Base):
    __tablename__ = "employees"
    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(100))
    type: Mapped[str] = mapped_column(String(50))
    __mapper_args__ = {"polymorphic_identity": "employee", "polymorphic_on": "type"}

class Manager(Employee):
    manager_data: Mapped[Optional[str]] = mapped_column(String(200), default=None)
    __mapper_args__ = {"polymorphic_identity": "manager"}
```

### Joined Table Inheritance

Separate tables joined via FK. Use when subclasses have distinct columns. Better normalization, more JOINs.

```python
class Manager(Employee):
    __tablename__ = "managers"
    id: Mapped[int] = mapped_column(ForeignKey("employees.id"), primary_key=True)
    department: Mapped[str] = mapped_column(String(100))
    __mapper_args__ = {"polymorphic_identity": "manager"}
```

### Concrete Table Inheritance

Each class has its own full table. Use only when query performance per subclass matters and shared queries are rare. Highest data redundancy.

## Events and Hooks

```python
from sqlalchemy import event

@event.listens_for(User, "before_insert")
def set_default_username(mapper, connection, target):
    if not target.username:
        target.username = target.email.split("@")[0]

@event.listens_for(User, "after_update")
def log_update(mapper, connection, target):
    print(f"User {target.id} updated")

# Session-level events
@event.listens_for(Session, "after_commit")
def after_commit(session):
    print("Transaction committed")
```

- Use `before_insert`/`before_update` for validation and data normalization.
- Use `after_update`/`after_insert` for audit logging and side effects.
- Avoid heavy logic in events — keep them fast to not block DB operations.

## Performance

### N+1 Detection

```python
# Set raiseload globally during development
class Base(DeclarativeBase):
    pass

# Or per-relationship
posts: Mapped[list["Post"]] = relationship(lazy="raise")

# Or per-query
stmt = select(User).options(raiseload("*"))
```

### Bulk Operations

```python
# Bulk insert — bypasses ORM events, fastest
session.execute(User.__table__.insert(), [{"username": "u1", "email": "a@b.com"}, ...])

# ORM bulk insert (preserves some ORM features)
session.add_all([User(username=f"u{i}", email=f"u{i}@b.com") for i in range(1000)])
session.flush()

# Bulk update via Core
from sqlalchemy import update
session.execute(update(User).where(User.is_active == False).values(is_active=True))
```

### Connection Pooling

```python
engine = create_engine(
    "postgresql+psycopg://...",
    pool_size=10,          # maintained connections
    max_overflow=20,       # extra connections under load
    pool_timeout=30,       # wait time for connection
    pool_recycle=1800,     # recycle connections after 30 min
    pool_pre_ping=True,    # verify connection liveness
)
```

- Use Core (`insert()`, `update()`) for bulk operations — 10-100x faster than ORM object creation.
- Profile with `echo=True` or SQLAlchemy's event system to count queries per request.
- Use `deferred(mapped_column(...))` for large text/blob columns rarely accessed.

## Testing

```python
import pytest
from sqlalchemy import create_engine
from sqlalchemy.orm import Session

@pytest.fixture
def engine():
    eng = create_engine("sqlite:///:memory:")
    Base.metadata.create_all(eng)
    yield eng
    eng.dispose()

@pytest.fixture
def db_session(engine):
    connection = engine.connect()
    transaction = connection.begin()
    session = Session(bind=connection)
    yield session
    session.close()
    transaction.rollback()
    connection.close()
```

### Factory Boy Integration

```python
import factory

class UserFactory(factory.alchemy.SQLAlchemyModelFactory):
    class Meta:
        model = User
        sqlalchemy_session_persistence = "flush"

    username = factory.Sequence(lambda n: f"user{n}")
    email = factory.LazyAttribute(lambda o: f"{o.username}@example.com")
```

- Bind `UserFactory._meta.sqlalchemy_session = db_session` in fixtures.
- Use in-memory SQLite for unit tests, a real DB (via Docker) for integration tests.
- Wrap each test in a transaction and rollback — fastest isolation strategy.

## Anti-Patterns

| Anti-Pattern | Fix |
|---|---|
| Lazy loading in loops (N+1) | Use `selectinload` / `joinedload` |
| Accessing detached instance attributes | `expunge` after loading needed attrs, or set `expire_on_commit=False` |
| Long-lived sessions | Scope to request/operation; use context managers |
| `session.query()` (legacy API) | Use `select()` + `session.execute()` |
| Lazy loading in async | Always eager-load or use `await session.refresh()` |
| Sharing sessions across threads | Create one session per thread/task |
| Committing inside loops | Batch operations, commit once |
| Ignoring `flush()` vs `commit()` | `flush()` sends SQL, `commit()` finalizes transaction |
| Raw string SQL in ORM code | Use `text()` or Core constructs for raw SQL |

<!-- tested: pass -->
