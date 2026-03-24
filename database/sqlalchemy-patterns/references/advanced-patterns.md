# SQLAlchemy 2.0 Advanced Patterns

> Dense reference for polymorphic inheritance, custom types, composite columns, association proxies, hybrid attributes, events, versioning, soft delete, multi-tenancy, and write-only relationships.

---

## Table of Contents

1. [Polymorphic Associations (Inheritance)](#1-polymorphic-associations-inheritance)
2. [Custom Types](#2-custom-types)
3. [Composite Columns](#3-composite-columns)
4. [Association Proxies](#4-association-proxies)
5. [Hybrid Attributes Deep-Dive](#5-hybrid-attributes-deep-dive)
6. [Event System](#6-event-system)
7. [Versioning Patterns](#7-versioning-patterns)
8. [Soft Delete Mixins](#8-soft-delete-mixins)
9. [Multi-Tenancy](#9-multi-tenancy)
10. [Write-Only Relationships](#10-write-only-relationships)

---

## 1. Polymorphic Associations (Inheritance)

SQLAlchemy supports three inheritance mapping strategies. All use `polymorphic_on` (discriminator column) and `polymorphic_identity` (per-class value).

### Single Table Inheritance

All classes share one table. Fastest queries, but nullable columns for subclass-specific fields.

```python
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column
from sqlalchemy import String

class Base(DeclarativeBase):
    pass

class Employee(Base):
    __tablename__ = "employees"

    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(100))
    type: Mapped[str] = mapped_column(String(50))

    # Subclass-specific (nullable in single-table)
    manager_data: Mapped[str | None] = mapped_column(String(200))
    engineer_data: Mapped[str | None] = mapped_column(String(200))

    __mapper_args__ = {
        "polymorphic_identity": "employee",
        "polymorphic_on": "type",
    }

class Manager(Employee):
    # No __tablename__ — shares parent table
    manager_data: Mapped[str | None] = mapped_column(String(200), use_existing_column=True)

    __mapper_args__ = {
        "polymorphic_identity": "manager",
    }

class Engineer(Employee):
    engineer_data: Mapped[str | None] = mapped_column(String(200), use_existing_column=True)

    __mapper_args__ = {
        "polymorphic_identity": "engineer",
    }
```

**Querying:**
```python
# Returns Manager and Engineer instances via polymorphic dispatch
all_employees = session.scalars(select(Employee)).all()

# Query specific subclass only
managers = session.scalars(select(Manager)).all()
```

### Joined Table Inheritance

Each subclass has its own table with FK to parent. Clean schema, slight JOIN overhead.

```python
class Employee(Base):
    __tablename__ = "employees"

    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(100))
    type: Mapped[str] = mapped_column(String(50))

    __mapper_args__ = {
        "polymorphic_identity": "employee",
        "polymorphic_on": "type",
    }

class Manager(Employee):
    __tablename__ = "managers"

    id: Mapped[int] = mapped_column(ForeignKey("employees.id"), primary_key=True)
    department: Mapped[str] = mapped_column(String(100))

    __mapper_args__ = {
        "polymorphic_identity": "manager",
    }

class Engineer(Employee):
    __tablename__ = "engineers"

    id: Mapped[int] = mapped_column(ForeignKey("employees.id"), primary_key=True)
    language: Mapped[str] = mapped_column(String(50))

    __mapper_args__ = {
        "polymorphic_identity": "engineer",
    }
```

### Concrete Table Inheritance

Each class has a fully independent table. No JOINs but no unified querying without UNION.

```python
from sqlalchemy.orm import ConcreteBase

class Employee(ConcreteBase, Base):
    __tablename__ = "employees"

    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(100))
    type: Mapped[str] = mapped_column(String(50))

    __mapper_args__ = {
        "polymorphic_identity": "employee",
        "concrete": True,
    }

class Manager(Employee):
    __tablename__ = "managers"

    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(100))
    department: Mapped[str] = mapped_column(String(100))
    type: Mapped[str] = mapped_column(String(50))

    __mapper_args__ = {
        "polymorphic_identity": "manager",
        "concrete": True,
    }
```

### When to Use Which

| Strategy | Schema Cleanliness | Query Speed | Flexibility |
|----------|-------------------|-------------|-------------|
| Single Table | Low (nullables) | Fastest (no JOINs) | Limited subclass columns |
| Joined Table | High | Medium (JOINs) | Best for distinct subclass data |
| Concrete Table | High | Slow (UNIONs for base queries) | Full independence |

---

## 2. Custom Types

### TypeDecorator — Transform Values

```python
from sqlalchemy.types import TypeDecorator, String
import json

class JSONEncoded(TypeDecorator):
    """Store Python dicts/lists as JSON strings."""
    impl = String
    cache_ok = True  # REQUIRED in 2.0

    def process_bind_param(self, value, dialect):
        if value is not None:
            return json.dumps(value, default=str)
        return None

    def process_result_value(self, value, dialect):
        if value is not None:
            return json.loads(value)
        return None

    def coerce_compared_value(self, op, value):
        return self.impl
```

### Enum-backed Types

```python
import enum
from sqlalchemy import Enum

class Status(enum.Enum):
    ACTIVE = "active"
    INACTIVE = "inactive"
    SUSPENDED = "suspended"

class User(Base):
    __tablename__ = "users"
    id: Mapped[int] = mapped_column(primary_key=True)
    status: Mapped[Status] = mapped_column(
        Enum(Status, native_enum=True, values_callable=lambda e: [x.value for x in e]),
        default=Status.ACTIVE,
    )
```

### Encrypted Type (Pattern)

```python
class EncryptedString(TypeDecorator):
    impl = String
    cache_ok = True

    def __init__(self, key: str, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._key = key

    def process_bind_param(self, value, dialect):
        if value is not None:
            return encrypt(value, self._key)  # your encrypt fn
        return None

    def process_result_value(self, value, dialect):
        if value is not None:
            return decrypt(value, self._key)
        return None
```

---

## 3. Composite Columns

Map multiple DB columns to a single Python value object.

```python
from sqlalchemy.orm import composite, Mapped, mapped_column
from dataclasses import dataclass

@dataclass
class Address:
    street: str
    city: str
    state: str
    zip_code: str

class User(Base):
    __tablename__ = "users"

    id: Mapped[int] = mapped_column(primary_key=True)
    street: Mapped[str] = mapped_column(String(200))
    city: Mapped[str] = mapped_column(String(100))
    state: Mapped[str] = mapped_column(String(2))
    zip_code: Mapped[str] = mapped_column(String(10))

    address: Mapped[Address] = composite(
        Address, "street", "city", "state", "zip_code"
    )

# Usage:
user.address = Address("123 Main", "Portland", "OR", "97201")
user.address.city  # → "Portland"

# Querying:
stmt = select(User).where(User.address == Address("123 Main", "Portland", "OR", "97201"))
```

### Money Composite (Common Pattern)

```python
@dataclass
class Money:
    amount: int  # cents
    currency: str

    @property
    def dollars(self) -> float:
        return self.amount / 100

class Product(Base):
    __tablename__ = "products"
    id: Mapped[int] = mapped_column(primary_key=True)
    price_amount: Mapped[int] = mapped_column()
    price_currency: Mapped[str] = mapped_column(String(3), default="USD")

    price: Mapped[Money] = composite(Money, "price_amount", "price_currency")
```

---

## 4. Association Proxies

Simplify access to attributes across relationships.

### Basic — Flatten Nested Attribute

```python
from sqlalchemy.ext.associationproxy import association_proxy

class User(Base):
    __tablename__ = "users"
    id: Mapped[int] = mapped_column(primary_key=True)
    keywords: Mapped[list["UserKeyword"]] = relationship(back_populates="user")

    # Proxy: user.keyword_names → ["python", "sql"] instead of [UserKeyword(...), ...]
    keyword_names: AssociationProxy[list[str]] = association_proxy(
        "keywords", "keyword_value",
        creator=lambda v: UserKeyword(keyword_value=v),
    )

class UserKeyword(Base):
    __tablename__ = "user_keywords"
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), primary_key=True)
    keyword_value: Mapped[str] = mapped_column(String(50), primary_key=True)
    user: Mapped["User"] = relationship(back_populates="keywords")

# Usage:
user.keyword_names.append("python")  # creates UserKeyword automatically
user.keyword_names  # → ["python"]
```

### M2M with Extra Data on Association

```python
class User(Base):
    __tablename__ = "users"
    id: Mapped[int] = mapped_column(primary_key=True)
    memberships: Mapped[list["Membership"]] = relationship(back_populates="user")
    teams: AssociationProxy[list["Team"]] = association_proxy("memberships", "team")

class Team(Base):
    __tablename__ = "teams"
    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(100))

class Membership(Base):
    __tablename__ = "memberships"
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), primary_key=True)
    team_id: Mapped[int] = mapped_column(ForeignKey("teams.id"), primary_key=True)
    role: Mapped[str] = mapped_column(String(50))  # extra data on association
    user: Mapped["User"] = relationship(back_populates="memberships")
    team: Mapped["Team"] = relationship()

# user.teams → [Team(...), Team(...)] — skips Membership objects
```

### Querying Through Proxies

```python
from sqlalchemy.ext.associationproxy import AssociationProxy

# Filter users who have keyword "python"
stmt = select(User).where(User.keyword_names.contains("python"))
```

---

## 5. Hybrid Attributes Deep-Dive

### Basic Hybrid with Expression

```python
from sqlalchemy.ext.hybrid import hybrid_property, hybrid_method
from sqlalchemy import case, func

class Order(Base):
    __tablename__ = "orders"
    id: Mapped[int] = mapped_column(primary_key=True)
    subtotal: Mapped[int] = mapped_column()  # cents
    tax: Mapped[int] = mapped_column()  # cents
    discount: Mapped[int] = mapped_column(default=0)

    @hybrid_property
    def total(self) -> int:
        return self.subtotal + self.tax - self.discount

    @total.expression
    @classmethod
    def total(cls):
        return cls.subtotal + cls.tax - cls.discount

    @total.setter
    def total(self, value: int):
        self.subtotal = value - self.tax + self.discount
```

### Hybrid with Different SQL Logic

```python
class User(Base):
    __tablename__ = "users"
    id: Mapped[int] = mapped_column(primary_key=True)
    first_name: Mapped[str] = mapped_column(String(50))
    last_name: Mapped[str] = mapped_column(String(50))

    @hybrid_property
    def is_admin(self) -> bool:
        return self.role == "admin"

    @is_admin.expression
    @classmethod
    def is_admin(cls):
        return cls.role == "admin"

    @hybrid_property
    def name_length(self) -> int:
        return len(self.first_name) + len(self.last_name)

    @name_length.expression
    @classmethod
    def name_length(cls):
        return func.length(cls.first_name) + func.length(cls.last_name)
```

### Hybrid Methods (Parameterized)

```python
class Interval(Base):
    __tablename__ = "intervals"
    id: Mapped[int] = mapped_column(primary_key=True)
    start: Mapped[int] = mapped_column()
    end: Mapped[int] = mapped_column()

    @hybrid_method
    def contains(self, point: int) -> bool:
        return self.start <= point <= self.end

    @contains.expression
    @classmethod
    def contains(cls, point: int):
        return and_(cls.start <= point, cls.end >= point)

# Both work:
interval.contains(5)  # Python: True/False
select(Interval).where(Interval.contains(5))  # SQL WHERE
```

### Hybrid with Case Expressions

```python
class Employee(Base):
    __tablename__ = "employees"
    id: Mapped[int] = mapped_column(primary_key=True)
    salary: Mapped[int] = mapped_column()

    @hybrid_property
    def salary_grade(self) -> str:
        if self.salary > 100000:
            return "senior"
        elif self.salary > 50000:
            return "mid"
        return "junior"

    @salary_grade.expression
    @classmethod
    def salary_grade(cls):
        return case(
            (cls.salary > 100000, "senior"),
            (cls.salary > 50000, "mid"),
            else_="junior",
        )

# select(Employee).where(Employee.salary_grade == "senior")
```

---

## 6. Event System

### Mapper Events

```python
from sqlalchemy import event
from sqlalchemy.orm import Session

@event.listens_for(User, "before_insert")
def user_before_insert(mapper, connection, target):
    target.slug = slugify(target.name)
    target.created_at = datetime.utcnow()

@event.listens_for(User, "before_update")
def user_before_update(mapper, connection, target):
    target.updated_at = datetime.utcnow()

@event.listens_for(User, "after_delete")
def user_after_delete(mapper, connection, target):
    audit_log(action="delete", entity="user", entity_id=target.id)
```

### Session Events

```python
@event.listens_for(Session, "before_flush")
def before_flush(session, flush_context, instances):
    for obj in session.new:
        if hasattr(obj, "validate"):
            obj.validate()
    for obj in session.dirty:
        if hasattr(obj, "on_update"):
            obj.on_update()

@event.listens_for(Session, "after_commit")
def after_commit(session):
    # Dispatch domain events, invalidate caches, etc.
    pass

@event.listens_for(Session, "after_soft_rollback")
def after_rollback(session, previous_transaction):
    log.warning("Transaction rolled back")
```

### Attribute Events

```python
@event.listens_for(User.email, "set")
def validate_email(target, value, oldvalue, initiator):
    if value and "@" not in value:
        raise ValueError(f"Invalid email: {value}")
    return value

@event.listens_for(User.status, "set")
def on_status_change(target, value, oldvalue, initiator):
    if oldvalue != value:
        target.status_changed_at = datetime.utcnow()
```

### Connection/Engine Events

```python
@event.listens_for(engine, "connect")
def set_sqlite_pragma(dbapi_conn, connection_record):
    cursor = dbapi_conn.cursor()
    cursor.execute("PRAGMA journal_mode=WAL")
    cursor.execute("PRAGMA foreign_keys=ON")
    cursor.close()

@event.listens_for(engine, "before_cursor_execute")
def log_slow_queries(conn, cursor, statement, parameters, context, executemany):
    conn.info.setdefault("query_start_time", []).append(time.time())

@event.listens_for(engine, "after_cursor_execute")
def check_slow_queries(conn, cursor, statement, parameters, context, executemany):
    total = time.time() - conn.info["query_start_time"].pop()
    if total > 0.5:
        log.warning(f"Slow query ({total:.2f}s): {statement[:200]}")
```

### Event Propagation Control

```python
# propagate=True: event fires for subclasses too
@event.listens_for(Base, "before_insert", propagate=True)
def set_id_on_all_models(mapper, connection, target):
    if not target.id:
        target.id = generate_uuid()

# Remove a listener
event.remove(User, "before_insert", user_before_insert)

# One-shot listener
@event.listens_for(User, "after_insert", once=True)
def first_user_only(mapper, connection, target):
    send_welcome_notification(target)
```

---

## 7. Versioning Patterns

### Optimistic Locking with version_id_col

```python
class Document(Base):
    __tablename__ = "documents"

    id: Mapped[int] = mapped_column(primary_key=True)
    title: Mapped[str] = mapped_column(String(200))
    content: Mapped[str] = mapped_column(Text)
    version: Mapped[int] = mapped_column(default=1)

    __mapper_args__ = {
        "version_id_col": version,  # auto-incremented, checked on UPDATE
    }

# On concurrent modification → raises StaleDataError
# Catch and retry or merge:
from sqlalchemy.orm.exc import StaleDataError
try:
    session.commit()
except StaleDataError:
    session.rollback()
    # Re-fetch and retry
```

### History Table Pattern (Audit Trail)

```python
class ArticleHistory(Base):
    __tablename__ = "article_history"

    id: Mapped[int] = mapped_column(primary_key=True)
    article_id: Mapped[int] = mapped_column(ForeignKey("articles.id"), index=True)
    title: Mapped[str] = mapped_column(String(200))
    content: Mapped[str] = mapped_column(Text)
    changed_by: Mapped[str] = mapped_column(String(100))
    changed_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    operation: Mapped[str] = mapped_column(String(10))  # INSERT, UPDATE, DELETE

class Article(Base):
    __tablename__ = "articles"

    id: Mapped[int] = mapped_column(primary_key=True)
    title: Mapped[str] = mapped_column(String(200))
    content: Mapped[str] = mapped_column(Text)
    version: Mapped[int] = mapped_column(default=1)

    __mapper_args__ = {"version_id_col": version}

# Auto-record history via event
@event.listens_for(Article, "after_update")
def article_after_update(mapper, connection, target):
    connection.execute(
        ArticleHistory.__table__.insert().values(
            article_id=target.id,
            title=target.title,
            content=target.content,
            changed_by=get_current_user(),
            operation="UPDATE",
        )
    )
```

### Temporal Table Mixin

```python
class TemporalMixin:
    """Track valid_from/valid_to for bitemporal data."""
    valid_from: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )
    valid_to: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    @hybrid_property
    def is_current(self) -> bool:
        return self.valid_to is None

    @is_current.expression
    @classmethod
    def is_current(cls):
        return cls.valid_to.is_(None)
```

---

## 8. Soft Delete Mixins

### Basic Soft Delete

```python
from sqlalchemy.ext.hybrid import hybrid_property

class SoftDeleteMixin:
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    @hybrid_property
    def is_deleted(self) -> bool:
        return self.deleted_at is not None

    @is_deleted.expression
    @classmethod
    def is_deleted(cls):
        return cls.deleted_at.isnot(None)

    def soft_delete(self):
        self.deleted_at = datetime.utcnow()

    def restore(self):
        self.deleted_at = None
```

### Auto-Filtering via Session Events

```python
from sqlalchemy import event
from sqlalchemy.orm import Session

@event.listens_for(Session, "do_orm_execute")
def _apply_soft_delete_filter(execute_state):
    """Automatically exclude soft-deleted rows unless explicitly requested."""
    if (
        execute_state.is_select
        and not execute_state.is_column_load
        and not execute_state.is_relationship_load
        and not execute_state.execution_options.get("include_deleted", False)
    ):
        execute_state.statement = execute_state.statement.options(
            with_loader_criteria(
                SoftDeleteMixin,
                lambda cls: cls.deleted_at.is_(None),
                include_aliases=True,
            )
        )

# Normal queries auto-exclude deleted:
session.scalars(select(User)).all()  # only non-deleted

# Opt-in to include deleted:
session.scalars(
    select(User).execution_options(include_deleted=True)
).all()
```

### Soft Delete with Cascade

```python
@event.listens_for(User, "after_update")
def cascade_soft_delete(mapper, connection, target):
    if target.deleted_at is not None:
        connection.execute(
            update(Post).where(Post.author_id == target.id).values(
                deleted_at=target.deleted_at
            )
        )
```

---

## 9. Multi-Tenancy

### Row-Based Multi-Tenancy

Each table has a `tenant_id` column; queries auto-filter by current tenant.

```python
from contextvars import ContextVar

current_tenant: ContextVar[str] = ContextVar("current_tenant")

class TenantMixin:
    tenant_id: Mapped[str] = mapped_column(String(50), index=True)

# Auto-filter queries by tenant
@event.listens_for(Session, "do_orm_execute")
def _filter_by_tenant(execute_state):
    if execute_state.is_select:
        tenant = current_tenant.get(None)
        if tenant:
            execute_state.statement = execute_state.statement.options(
                with_loader_criteria(
                    TenantMixin,
                    lambda cls: cls.tenant_id == current_tenant.get(),
                    include_aliases=True,
                )
            )

# Auto-set tenant_id on insert
@event.listens_for(Session, "before_flush")
def _set_tenant_id(session, flush_context, instances):
    tenant = current_tenant.get(None)
    if tenant:
        for obj in session.new:
            if isinstance(obj, TenantMixin):
                obj.tenant_id = tenant

# FastAPI middleware
@app.middleware("http")
async def tenant_middleware(request: Request, call_next):
    tenant = request.headers.get("X-Tenant-ID")
    token = current_tenant.set(tenant)
    try:
        return await call_next(request)
    finally:
        current_tenant.reset(token)
```

### Schema-Based Multi-Tenancy

Each tenant gets a separate database schema (PostgreSQL).

```python
from sqlalchemy import event, text

def get_tenant_schema() -> str:
    return current_tenant.get("public")

@event.listens_for(engine, "before_cursor_execute")
def set_search_path(conn, cursor, statement, parameters, context, executemany):
    schema = get_tenant_schema()
    cursor.execute(f"SET search_path TO {schema}, public")

# Or per-session:
def get_tenant_session(tenant_schema: str) -> Session:
    session = SessionLocal()
    session.execute(text(f"SET search_path TO {tenant_schema}, public"))
    return session
```

### Schema Creation for New Tenants

```python
def create_tenant_schema(engine, schema_name: str):
    with engine.begin() as conn:
        conn.execute(text(f"CREATE SCHEMA IF NOT EXISTS {schema_name}"))
        # Create tables in tenant schema
        for table in Base.metadata.sorted_tables:
            table.schema = schema_name
            table.create(conn, checkfirst=True)
            table.schema = None  # reset
```

---

## 10. Write-Only Relationships

New in SQLAlchemy 2.0. Prevents loading the entire collection; you add/remove items but query explicitly.

```python
from sqlalchemy.orm import WriteOnlyMapped, relationship

class User(Base):
    __tablename__ = "users"

    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(100))

    # Write-only: never auto-loads posts into memory
    posts: WriteOnlyMapped[list["Post"]] = relationship(
        back_populates="author",
        cascade="all, delete-orphan",
        passive_deletes=True,
    )

class Post(Base):
    __tablename__ = "posts"

    id: Mapped[int] = mapped_column(primary_key=True)
    title: Mapped[str] = mapped_column(String(200))
    author_id: Mapped[int] = mapped_column(ForeignKey("users.id"))
    author: Mapped["User"] = relationship(back_populates="posts")
```

### Operations on Write-Only Collections

```python
# Add items (no loading)
user.posts.add(Post(title="New Post"))
user.posts.add_all([Post(title="A"), Post(title="B")])

# Remove items (no loading)
user.posts.remove(some_post)

# Query the collection explicitly
stmt = user.posts.select().where(Post.title.contains("SQL"))
posts = session.scalars(stmt).all()

# Count without loading
count_stmt = select(func.count()).select_from(user.posts.select().subquery())
count = session.scalar(count_stmt)

# Paginate
page = session.scalars(
    user.posts.select().order_by(Post.id).offset(20).limit(10)
).all()
```

### When to Use Write-Only

- **Large collections**: Users with thousands of posts, orders, logs
- **Append-heavy patterns**: Event sourcing, audit logs
- **Async contexts**: Avoids accidental lazy loads
- **Memory-sensitive**: Never materializes the full collection

### Migrating from dynamic to write_only

```python
# Old (deprecated in 2.0):
posts: Mapped[list["Post"]] = relationship(lazy="dynamic")

# New:
posts: WriteOnlyMapped[list["Post"]] = relationship()

# API changes:
# Old: user.posts.filter_by(...)  → New: user.posts.select().where(...)
# Old: user.posts.append(p)       → New: user.posts.add(p)
# Old: user.posts.count()         → New: select(func.count()).select_from(user.posts.select().subquery())
```
