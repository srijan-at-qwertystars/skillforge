# Advanced SQLAlchemy Patterns

> Dense reference for advanced SQLAlchemy 2.0 patterns. Each section is self-contained with copy-paste examples.

## Table of Contents

1. [Polymorphic Inheritance](#polymorphic-inheritance)
2. [Multi-Tenancy](#multi-tenancy)
3. [Sharding & Horizontal Partitioning](#sharding--horizontal-partitioning)
4. [Versioned Rows / History Tables](#versioned-rows--history-tables)
5. [Soft Deletes](#soft-deletes)
6. [Association Proxy](#association-proxy)
7. [Composite Keys](#composite-keys)
8. [JSON Columns](#json-columns)
9. [Array Columns (PostgreSQL)](#array-columns-postgresql)
10. [Full-Text Search](#full-text-search)
11. [CTEs (Common Table Expressions)](#ctes-common-table-expressions)
12. [Window Functions](#window-functions)
13. [Lateral Joins](#lateral-joins)
14. [Custom Compilation](#custom-compilation)
15. [Query Caching & dogpile.cache](#query-caching--dogpilecache)

---

## Polymorphic Inheritance

### Single Table Inheritance

All subclasses share one table. Best when subclasses have few unique columns.

```python
from sqlalchemy.orm import Mapped, mapped_column, DeclarativeBase
from sqlalchemy import String

class Base(DeclarativeBase):
    pass

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
    department: Mapped[str | None] = mapped_column(String(100))
    __mapper_args__ = {"polymorphic_identity": "manager"}

class Engineer(Employee):
    language: Mapped[str | None] = mapped_column(String(50))
    __mapper_args__ = {"polymorphic_identity": "engineer"}
```

Query all employees: `select(Employee)` returns Manager/Engineer instances automatically.
Query one type: `select(Manager)` adds `WHERE type = 'manager'`.

### Joined Table Inheritance

Each subclass has its own table joined via FK. Best for subclasses with many unique columns.

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
    budget: Mapped[int] = mapped_column(default=0)
    __mapper_args__ = {"polymorphic_identity": "manager"}

class Engineer(Employee):
    __tablename__ = "engineers"
    id: Mapped[int] = mapped_column(ForeignKey("employees.id"), primary_key=True)
    language: Mapped[str] = mapped_column(String(50))
    github_url: Mapped[str | None] = mapped_column(String(200))
    __mapper_args__ = {"polymorphic_identity": "engineer"}
```

### Concrete Table Inheritance

Each class has a fully independent table. No JOINs needed for single-type queries but polymorphic queries use UNION.

```python
from sqlalchemy.orm import ConcreteBase

class Employee(ConcreteBase, Base):
    __tablename__ = "employees"
    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(100))
    __mapper_args__ = {
        "polymorphic_identity": "employee",
        "concrete": True,
    }

class Manager(Employee):
    __tablename__ = "managers"
    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(100))
    department: Mapped[str] = mapped_column(String(100))
    __mapper_args__ = {
        "polymorphic_identity": "manager",
        "concrete": True,
    }
```

**When to use which:**
| Pattern | Pros | Cons |
|---------|------|------|
| Single table | Fast queries, simple schema | Sparse columns, no NOT NULL on subclass cols |
| Joined table | Normalized, subclass columns can be NOT NULL | JOINs on every query |
| Concrete table | No JOINs for single type, fully independent | UNION for polymorphic queries, duplicated columns |

---

## Multi-Tenancy

### Schema-Per-Tenant (PostgreSQL)

Each tenant gets a separate PostgreSQL schema. Use `search_path` or schema translation.

```python
from sqlalchemy import event, text

class TenantBase(DeclarativeBase):
    pass

class TenantUser(TenantBase):
    __tablename__ = "users"
    __table_args__ = {"schema": "tenant"}  # template schema
    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(100))

def get_tenant_engine(tenant_schema: str):
    """Create engine with schema translation for a specific tenant."""
    engine = create_engine(
        "postgresql+psycopg://user:pass@localhost/multitenant",
        execution_options={
            "schema_translate_map": {"tenant": tenant_schema}
        },
    )
    return engine

# Or set search_path per connection
@event.listens_for(engine, "before_cursor_execute", retval=True)
def set_search_path(conn, cursor, statement, parameters, context, executemany):
    tenant = get_current_tenant()  # from context var, thread-local, etc.
    cursor.execute(f"SET search_path TO {tenant}, public")
    return statement, parameters
```

**Creating tenant schemas:**

```python
def create_tenant_schema(engine, schema_name: str):
    with engine.begin() as conn:
        conn.execute(text(f"CREATE SCHEMA IF NOT EXISTS {schema_name}"))
        # Create tables in the new schema
        conn.execute(text(f"SET search_path TO {schema_name}"))
        TenantBase.metadata.create_all(conn)
```

### Row-Level Multi-Tenancy

All tenants share tables. Filter by `tenant_id` on every query.

```python
from sqlalchemy import event
from sqlalchemy.orm import Session

class TenantMixin:
    tenant_id: Mapped[int] = mapped_column(index=True)

class User(TenantMixin, Base):
    __tablename__ = "users"
    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(100))

# Auto-filter all queries by tenant
@event.listens_for(Session, "do_orm_execute")
def filter_by_tenant(execute_state):
    if execute_state.is_select:
        tenant_id = get_current_tenant_id()
        execute_state.statement = execute_state.statement.options(
            with_loader_criteria(TenantMixin, TenantMixin.tenant_id == tenant_id)
        )

# Auto-set tenant_id on insert
@event.listens_for(Session, "before_flush")
def set_tenant_on_new(session, flush_context, instances):
    tenant_id = get_current_tenant_id()
    for obj in session.new:
        if isinstance(obj, TenantMixin):
            obj.tenant_id = tenant_id
```

Also consider PostgreSQL Row-Level Security (RLS) as a database-enforced complement.

---

## Sharding & Horizontal Partitioning

### SQLAlchemy Horizontal Sharding

```python
from sqlalchemy.ext.horizontal_shard import ShardedSession
from sqlalchemy.orm import sessionmaker

engines = {
    "shard_us": create_engine("postgresql://user:pass@us-db/app"),
    "shard_eu": create_engine("postgresql://user:pass@eu-db/app"),
}

def shard_chooser(mapper, instance, clause=None):
    """Determine shard based on instance data."""
    if instance is not None:
        return "shard_us" if instance.region == "US" else "shard_eu"
    return "shard_us"

def id_chooser(query, ident):
    """Determine which shards to query for a given identity."""
    return ["shard_us", "shard_eu"]

def execute_chooser(context):
    """Determine which shards to execute a query against."""
    return ["shard_us", "shard_eu"]

Session = sessionmaker(
    class_=ShardedSession,
    shards=engines,
    shard_chooser=shard_chooser,
    id_chooser=id_chooser,
    execute_chooser=execute_chooser,
)
```

### Table Partitioning (PostgreSQL native)

Let PostgreSQL handle partitioning; SQLAlchemy just maps to the parent table.

```python
class Measurement(Base):
    __tablename__ = "measurements"
    __table_args__ = {
        "postgresql_partition_by": "RANGE (recorded_at)",
    }
    id: Mapped[int] = mapped_column(primary_key=True)
    recorded_at: Mapped[datetime] = mapped_column(primary_key=True)
    value: Mapped[float]
```

Create partitions via raw SQL in migrations:
```sql
CREATE TABLE measurements_2024_q1 PARTITION OF measurements
    FOR VALUES FROM ('2024-01-01') TO ('2024-04-01');
```

---

## Versioned Rows / History Tables

Track all changes to a model using a history table.

```python
from sqlalchemy import event, inspect
from datetime import datetime

class UserHistory(Base):
    __tablename__ = "user_history"
    history_id: Mapped[int] = mapped_column(primary_key=True)
    id: Mapped[int]  # original user id
    name: Mapped[str] = mapped_column(String(100))
    email: Mapped[str] = mapped_column(String(255))
    version: Mapped[int]
    changed_at: Mapped[datetime] = mapped_column(default=datetime.utcnow)
    operation: Mapped[str] = mapped_column(String(10))  # INSERT/UPDATE/DELETE

class User(Base):
    __tablename__ = "users"
    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(100))
    email: Mapped[str] = mapped_column(String(255))
    version: Mapped[int] = mapped_column(default=1)

@event.listens_for(User, "after_update")
def create_history_on_update(mapper, connection, target):
    state = inspect(target)
    changes = {}
    for attr in state.attrs:
        hist = attr.history
        if hist.has_changes():
            changes[attr.key] = hist.deleted[0] if hist.deleted else None

    if changes:
        connection.execute(
            insert(UserHistory).values(
                id=target.id,
                name=target.name,
                email=target.email,
                version=target.version,
                operation="UPDATE",
            )
        )
        connection.execute(
            update(User.__table__)
            .where(User.__table__.c.id == target.id)
            .values(version=User.__table__.c.version + 1)
        )
```

**Temporal tables approach** — use `valid_from`/`valid_to` columns for point-in-time queries:

```python
class UserVersion(Base):
    __tablename__ = "user_versions"
    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"))
    name: Mapped[str] = mapped_column(String(100))
    valid_from: Mapped[datetime]
    valid_to: Mapped[datetime | None]  # NULL = current version

# Query state at a point in time
stmt = (
    select(UserVersion)
    .where(UserVersion.user_id == 1)
    .where(UserVersion.valid_from <= point_in_time)
    .where(or_(UserVersion.valid_to.is_(None), UserVersion.valid_to > point_in_time))
)
```

---

## Soft Deletes

Mark rows as deleted without removing them.

```python
from sqlalchemy import event
from sqlalchemy.orm import Session

class SoftDeleteMixin:
    deleted_at: Mapped[datetime | None] = mapped_column(default=None, index=True)
    is_deleted: Mapped[bool] = mapped_column(default=False, index=True)

    def soft_delete(self):
        self.deleted_at = datetime.utcnow()
        self.is_deleted = True

    def restore(self):
        self.deleted_at = None
        self.is_deleted = False

class User(SoftDeleteMixin, Base):
    __tablename__ = "users"
    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(100))

# Auto-filter soft-deleted rows from all queries
@event.listens_for(Session, "do_orm_execute")
def exclude_soft_deleted(execute_state):
    if (
        execute_state.is_select
        and not execute_state.execution_options.get("include_deleted", False)
    ):
        execute_state.statement = execute_state.statement.options(
            with_loader_criteria(
                SoftDeleteMixin,
                lambda cls: cls.is_deleted == False,
                include_aliases=True,
            )
        )

# Query including deleted rows
stmt = select(User).execution_options(include_deleted=True)
```

---

## Association Proxy

Simplify access to data across association tables.

```python
from sqlalchemy.ext.associationproxy import association_proxy, AssociationProxy

class User(Base):
    __tablename__ = "users"
    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(100))

    user_keywords: Mapped[list["UserKeyword"]] = relationship(
        back_populates="user", cascade="all, delete-orphan"
    )
    # Proxy: user.keywords returns list of Keyword objects
    keywords: AssociationProxy[list["Keyword"]] = association_proxy(
        "user_keywords", "keyword",
        creator=lambda kw: UserKeyword(keyword=kw),
    )

class UserKeyword(Base):
    __tablename__ = "user_keywords"
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), primary_key=True)
    keyword_id: Mapped[int] = mapped_column(ForeignKey("keywords.id"), primary_key=True)
    special_key: Mapped[str | None] = mapped_column(String(50))

    user: Mapped["User"] = relationship(back_populates="user_keywords")
    keyword: Mapped["Keyword"] = relationship()

class Keyword(Base):
    __tablename__ = "keywords"
    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(64))

# Usage:
# user.keywords.append(Keyword(name="python"))
# user.keywords → [Keyword(name="python"), ...]
```

For scalar proxies through a one-to-one:
```python
class User(Base):
    ...
    profile: Mapped["Profile"] = relationship()
    avatar_url: AssociationProxy[str] = association_proxy("profile", "avatar_url")
```

---

## Composite Keys

```python
class OrderItem(Base):
    __tablename__ = "order_items"
    order_id: Mapped[int] = mapped_column(ForeignKey("orders.id"), primary_key=True)
    product_id: Mapped[int] = mapped_column(ForeignKey("products.id"), primary_key=True)
    quantity: Mapped[int]
    unit_price: Mapped[float]

    order: Mapped["Order"] = relationship(back_populates="items")
    product: Mapped["Product"] = relationship()

# Get by composite key
item = session.get(OrderItem, (order_id, product_id))
```

### Composite Column Values

```python
from sqlalchemy.orm import composite

class Point:
    def __init__(self, x: float, y: float):
        self.x = x
        self.y = y
    def __composite_values__(self):
        return self.x, self.y
    def __eq__(self, other):
        return self.x == other.x and self.y == other.y

class Location(Base):
    __tablename__ = "locations"
    id: Mapped[int] = mapped_column(primary_key=True)
    x: Mapped[float]
    y: Mapped[float]
    position: Mapped[Point] = composite(Point, "x", "y")

# Query: session.scalars(select(Location).where(Location.position == Point(1.0, 2.0)))
```

---

## JSON Columns

### Native JSON (PostgreSQL, MySQL, SQLite 3.38+)

```python
from sqlalchemy import JSON
from sqlalchemy.dialects.postgresql import JSONB

class Product(Base):
    __tablename__ = "products"
    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(200))
    metadata_: Mapped[dict] = mapped_column("metadata", JSON, default=dict)
    # PostgreSQL — use JSONB for indexing and operators
    attrs: Mapped[dict] = mapped_column(JSONB, default=dict)

# Querying JSON fields
stmt = select(Product).where(Product.attrs["color"].astext == "red")
stmt = select(Product).where(Product.attrs["specs"]["weight"].as_float() > 5.0)

# PostgreSQL JSONB operators
stmt = select(Product).where(Product.attrs.has_key("color"))
stmt = select(Product).where(Product.attrs.contains({"color": "red"}))

# Update JSON (must flag mutation for change detection)
from sqlalchemy.orm.attributes import flag_modified
product.attrs["color"] = "blue"
flag_modified(product, "attrs")
session.commit()
```

### MutableDict for automatic change tracking

```python
from sqlalchemy.ext.mutable import MutableDict

class Product(Base):
    __tablename__ = "products"
    id: Mapped[int] = mapped_column(primary_key=True)
    attrs: Mapped[dict] = mapped_column(MutableDict.as_mutable(JSONB), default=dict)

# Now changes are detected automatically — no flag_modified needed
product.attrs["color"] = "blue"
session.commit()  # change detected
```

---

## Array Columns (PostgreSQL)

```python
from sqlalchemy.dialects.postgresql import ARRAY
from sqlalchemy import String, Integer

class Post(Base):
    __tablename__ = "posts"
    id: Mapped[int] = mapped_column(primary_key=True)
    title: Mapped[str] = mapped_column(String(200))
    tags: Mapped[list[str]] = mapped_column(ARRAY(String(50)), default=list)
    scores: Mapped[list[int]] = mapped_column(ARRAY(Integer), default=list)

# Queries
stmt = select(Post).where(Post.tags.contains(["python", "sql"]))  # has both
stmt = select(Post).where(Post.tags.overlap(["python", "rust"]))   # has any
stmt = select(Post).where(Post.tags.any("python"))                 # has one
stmt = select(Post).where(Post.tags[0] == "featured")              # index access

# Aggregation
from sqlalchemy import func
stmt = select(func.unnest(Post.tags).label("tag"), func.count()).group_by("tag")
```

---

## Full-Text Search

### PostgreSQL tsvector/tsquery

```python
from sqlalchemy.dialects.postgresql import TSVECTOR
from sqlalchemy import func, Index

class Article(Base):
    __tablename__ = "articles"
    id: Mapped[int] = mapped_column(primary_key=True)
    title: Mapped[str] = mapped_column(String(300))
    body: Mapped[str] = mapped_column()
    search_vector: Mapped[str | None] = mapped_column(TSVECTOR)

    __table_args__ = (
        Index("ix_article_search", "search_vector", postgresql_using="gin"),
    )

# Generate tsvector with trigger or in application
# Application-side:
stmt = (
    update(Article)
    .where(Article.id == article_id)
    .values(
        search_vector=func.to_tsvector("english", Article.title + " " + Article.body)
    )
)

# Search
stmt = (
    select(Article)
    .where(Article.search_vector.match("python & sqlalchemy"))
    .order_by(func.ts_rank(Article.search_vector, func.to_tsquery("python & sqlalchemy")).desc())
)

# Without stored vector — computed at query time (slower)
stmt = select(Article).where(
    func.to_tsvector("english", Article.title).match("sqlalchemy")
)
```

---

## CTEs (Common Table Expressions)

```python
from sqlalchemy import select, func, literal

# Simple CTE
active_users = (
    select(User.id, User.name)
    .where(User.is_deleted == False)
    .cte("active_users")
)
stmt = select(active_users.c.name, func.count(Post.id)).join(
    Post, Post.author_id == active_users.c.id
).group_by(active_users.c.name)

# Recursive CTE — e.g., org chart / category tree
hierarchy = (
    select(
        Category.id,
        Category.name,
        Category.parent_id,
        literal(0).label("depth"),
    )
    .where(Category.parent_id.is_(None))
    .cte("hierarchy", recursive=True)
)

hierarchy_alias = hierarchy.alias()
category_alias = Category.__table__.alias()

hierarchy = hierarchy.union_all(
    select(
        category_alias.c.id,
        category_alias.c.name,
        category_alias.c.parent_id,
        (hierarchy_alias.c.depth + 1).label("depth"),
    ).join(hierarchy_alias, category_alias.c.parent_id == hierarchy_alias.c.id)
)

stmt = select(hierarchy)
```

---

## Window Functions

```python
from sqlalchemy import func, select, over

# Row number within partition
stmt = select(
    User.name,
    Post.title,
    func.row_number().over(
        partition_by=Post.author_id,
        order_by=Post.created_at.desc(),
    ).label("rn"),
)

# Running total
stmt = select(
    Order.id,
    Order.amount,
    func.sum(Order.amount).over(
        order_by=Order.created_at,
        rows=(None, 0),  # ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ).label("running_total"),
)

# Rank and dense_rank
stmt = select(
    User.name,
    func.count(Post.id).label("post_count"),
    func.rank().over(order_by=func.count(Post.id).desc()).label("rank"),
).join(Post).group_by(User.id, User.name)

# Lead / Lag
stmt = select(
    Order.id,
    Order.amount,
    func.lag(Order.amount, 1).over(order_by=Order.created_at).label("prev_amount"),
    func.lead(Order.amount, 1).over(order_by=Order.created_at).label("next_amount"),
)

# Filter: get only the latest post per user
subq = (
    select(
        Post,
        func.row_number()
        .over(partition_by=Post.author_id, order_by=Post.created_at.desc())
        .label("rn"),
    ).subquery()
)
stmt = select(subq).where(subq.c.rn == 1)
```

---

## Lateral Joins

PostgreSQL `LATERAL` subquery — correlated subquery in FROM clause.

```python
from sqlalchemy import lateral

# Get top-3 most recent posts per user
latest_posts = (
    select(Post)
    .where(Post.author_id == User.id)
    .order_by(Post.created_at.desc())
    .limit(3)
    .correlate(User)
    .lateral("latest_posts")
)

stmt = (
    select(User.name, latest_posts.c.title, latest_posts.c.created_at)
    .join(latest_posts, true())
    .order_by(User.name, latest_posts.c.created_at.desc())
)
```

---

## Custom Compilation

Create custom SQL constructs that compile differently per dialect.

```python
from sqlalchemy.ext.compiler import compiles
from sqlalchemy.sql.expression import ClauseElement, Executable

class CreateMaterializedView(Executable, ClauseElement):
    inherit_cache = True

    def __init__(self, name, selectable):
        self.name = name
        self.selectable = selectable

@compiles(CreateMaterializedView)
def compile_create_mat_view(element, compiler, **kw):
    return f"CREATE MATERIALIZED VIEW {element.name} AS {compiler.process(element.selectable)}"

@compiles(CreateMaterializedView, "sqlite")
def compile_create_mat_view_sqlite(element, compiler, **kw):
    # SQLite doesn't support materialized views — fall back to regular view
    return f"CREATE VIEW {element.name} AS {compiler.process(element.selectable)}"

# Usage
stmt = select(User.name, func.count(Post.id).label("cnt")).join(Post).group_by(User.name)
create_mv = CreateMaterializedView("user_post_counts", stmt)
with engine.begin() as conn:
    conn.execute(create_mv)
```

### Custom SQL Functions

```python
from sqlalchemy.sql.functions import GenericFunction
from sqlalchemy import Integer

class array_length(GenericFunction):
    type = Integer()
    name = "array_length"
    inherit_cache = True

# Now usable in queries: select(array_length(Post.tags, 1))
```

---

## Query Caching & dogpile.cache

### Built-in Query Caching

SQLAlchemy 2.0 caches compiled SQL statements by default. Custom types must set `cache_ok = True`.

### dogpile.cache Integration

```python
from dogpile.cache import make_region

region = make_region().configure(
    "dogpile.cache.redis",
    arguments={"host": "localhost", "port": 6379, "db": 0},
    expiration_time=3600,
)

@region.cache_on_arguments()
def get_user_by_id(user_id: int) -> dict:
    with Session(engine) as session:
        user = session.get(User, user_id)
        if user:
            return {"id": user.id, "name": user.name, "email": user.email}
        return None

def invalidate_user_cache(user_id: int):
    get_user_by_id.invalidate(user_id)

# Cache query results with key generation
@region.cache_on_arguments(namespace="user_list")
def list_active_users(page: int, per_page: int) -> list[dict]:
    with Session(engine) as session:
        stmt = (
            select(User)
            .where(User.is_deleted == False)
            .order_by(User.name)
            .offset((page - 1) * per_page)
            .limit(per_page)
        )
        users = session.scalars(stmt).all()
        return [{"id": u.id, "name": u.name} for u in users]

# Invalidate on write
@event.listens_for(User, "after_update")
@event.listens_for(User, "after_insert")
@event.listens_for(User, "after_delete")
def invalidate_user_caches(mapper, connection, target):
    invalidate_user_cache(target.id)
    region.invalidate(hard=False)  # soft invalidate list caches
```

**Important:** Always serialize ORM results to dicts/dataclasses before caching. Never cache live ORM objects — they hold session references that become invalid.
