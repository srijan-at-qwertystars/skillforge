# Alembic Deep Dive

> Comprehensive guide to Alembic migrations for SQLAlchemy projects. Covers setup through production deployment.

## Table of Contents

1. [Project Setup](#project-setup)
2. [env.py Configuration (Sync)](#envpy-configuration-sync)
3. [env.py Configuration (Async)](#envpy-configuration-async)
4. [Autogenerate](#autogenerate)
5. [Type Comparators](#type-comparators)
6. [Manual Migrations](#manual-migrations)
7. [Data Migrations](#data-migrations)
8. [Multi-Database Migrations](#multi-database-migrations)
9. [Branch Management](#branch-management)
10. [Downgrade Strategies](#downgrade-strategies)
11. [Migration Testing](#migration-testing)
12. [CI Integration](#ci-integration)
13. [Handling Enum Changes](#handling-enum-changes)
14. [Handling Column Type Changes](#handling-column-type-changes)
15. [Batch Operations for SQLite](#batch-operations-for-sqlite)

---

## Project Setup

### Initialize Alembic

```bash
# Standard (sync) setup
pip install alembic
alembic init alembic

# Async setup — generates async env.py template
alembic init -t async alembic

# Resulting structure:
# alembic/
# ├── env.py              # migration environment configuration
# ├── script.py.mako      # migration template
# ├── versions/           # migration files go here
# alembic.ini             # alembic configuration
```

### alembic.ini Configuration

```ini
[alembic]
script_location = alembic
# Use env var for URL — don't hardcode credentials
sqlalchemy.url = postgresql+psycopg://user:pass@localhost/mydb

# Recommended: template for migration filenames
file_template = %%(year)d_%%(month).2d_%%(day).2d_%%(hour).2d%%(minute).2d-%%(rev)s_%%(slug)s
# Produces: 2024_06_15_1430-a1b2c3d4_add_users_table.py

# Truncate long slugs
truncate_slug_length = 40

# Timezone for file_template timestamps
timezone = UTC
```

### Override URL from Environment

Always read the database URL from environment variables in production:

```python
# In env.py
import os

def run_migrations_online():
    url = os.environ.get("DATABASE_URL", config.get_main_option("sqlalchemy.url"))
    # Fix common issue: postgres:// → postgresql://
    if url and url.startswith("postgres://"):
        url = url.replace("postgres://", "postgresql://", 1)
    connectable = engine_from_config(
        config.get_section(config.config_ini_section),
        prefix="sqlalchemy.",
        poolclass=pool.NullPool,
        url=url,
    )
```

---

## env.py Configuration (Sync)

Production-ready sync `env.py`:

```python
import os
import logging
from logging.config import fileConfig

from sqlalchemy import engine_from_config, pool, text
from alembic import context

# Import your models' Base
from myapp.models import Base

config = context.config
if config.config_file_name is not None:
    fileConfig(config.config_file_name)

logger = logging.getLogger("alembic.env")

target_metadata = Base.metadata

def get_url() -> str:
    return os.environ.get("DATABASE_URL", config.get_main_option("sqlalchemy.url"))

def include_name(name, type_, parent_names):
    """Filter which schemas/tables to include in autogenerate."""
    if type_ == "schema":
        return name in [None, "public"]  # only public schema
    return True

def run_migrations_offline():
    """Run migrations in 'offline' mode — generates SQL script."""
    url = get_url()
    context.configure(
        url=url,
        target_metadata=target_metadata,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
        include_name=include_name,
        compare_type=True,
        compare_server_default=True,
    )
    with context.begin_transaction():
        context.run_migrations()

def run_migrations_online():
    """Run migrations against a live database."""
    configuration = config.get_section(config.config_ini_section, {})
    configuration["sqlalchemy.url"] = get_url()

    connectable = engine_from_config(
        configuration,
        prefix="sqlalchemy.",
        poolclass=pool.NullPool,  # don't hold connections
    )

    with connectable.connect() as connection:
        context.configure(
            connection=connection,
            target_metadata=target_metadata,
            include_name=include_name,
            compare_type=True,
            compare_server_default=True,
        )
        with context.begin_transaction():
            context.run_migrations()

if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
```

---

## env.py Configuration (Async)

Production-ready async `env.py`:

```python
import asyncio
import os
import logging
from logging.config import fileConfig

from sqlalchemy import pool
from sqlalchemy.ext.asyncio import async_engine_from_config
from alembic import context

from myapp.models import Base

config = context.config
if config.config_file_name is not None:
    fileConfig(config.config_file_name)

logger = logging.getLogger("alembic.env")
target_metadata = Base.metadata

def get_url() -> str:
    return os.environ.get("DATABASE_URL", config.get_main_option("sqlalchemy.url"))

def run_migrations_offline():
    url = get_url()
    context.configure(
        url=url,
        target_metadata=target_metadata,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
        compare_type=True,
    )
    with context.begin_transaction():
        context.run_migrations()

def do_run_migrations(connection):
    context.configure(
        connection=connection,
        target_metadata=target_metadata,
        compare_type=True,
        compare_server_default=True,
    )
    with context.begin_transaction():
        context.run_migrations()

async def run_async_migrations():
    configuration = config.get_section(config.config_ini_section, {})
    configuration["sqlalchemy.url"] = get_url()

    connectable = async_engine_from_config(
        configuration,
        prefix="sqlalchemy.",
        poolclass=pool.NullPool,
    )

    async with connectable.connect() as connection:
        await connection.run_sync(do_run_migrations)

    await connectable.dispose()

def run_migrations_online():
    asyncio.run(run_async_migrations())

if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
```

---

## Autogenerate

### Basic Usage

```bash
# Generate migration from model diff
alembic revision --autogenerate -m "add users table"

# Always review the generated file before applying
alembic upgrade head
```

### What Autogenerate Detects

| Detected | Not Detected |
|----------|-------------|
| Table additions/removals | Table renames |
| Column additions/removals | Column renames |
| Nullable changes | CHECK constraints (by default) |
| Foreign key changes | Computed/generated columns |
| Index additions/removals | Some type changes |
| Unique constraint changes | Server default changes (by default) |

### Enable Additional Detection

```python
# In env.py — enable type and server default comparison
context.configure(
    connection=connection,
    target_metadata=target_metadata,
    compare_type=True,              # detect column type changes
    compare_server_default=True,    # detect server_default changes
)
```

### Import All Models

Autogenerate only sees models imported before `target_metadata` is set:

```python
# Option 1: Import all modules explicitly
from myapp.models.user import User      # noqa: F401
from myapp.models.post import Post      # noqa: F401
from myapp.models.tag import Tag        # noqa: F401
from myapp.models import Base
target_metadata = Base.metadata

# Option 2: Auto-import all models via package __init__.py
# In myapp/models/__init__.py:
from myapp.models.user import User
from myapp.models.post import Post
from myapp.models.tag import Tag
# Then in env.py:
from myapp.models import Base
```

---

## Type Comparators

Custom type comparators prevent false positives in autogenerate.

```python
from alembic.autogenerate import comparators
from sqlalchemy import String, Text

def compare_type(context, inspected_column, metadata_column, inspected_type, metadata_type):
    """Custom type comparison logic."""
    # Treat String(None) and Text as equivalent
    if isinstance(inspected_type, String) and isinstance(metadata_type, Text):
        return False  # no difference
    if isinstance(inspected_type, Text) and isinstance(metadata_type, String):
        if metadata_type.length is None:
            return False
    # Return None to use default comparison
    return None

# In env.py
context.configure(
    connection=connection,
    target_metadata=target_metadata,
    compare_type=compare_type,
)
```

### Rendering Custom Types

```python
from alembic.autogenerate.render import _render_cmd_body

def render_item(type_, obj, autogen_context):
    """Custom rendering for migration operations."""
    if type_ == "type" and isinstance(obj, MyCustomType):
        autogen_context.imports.add("from myapp.types import MyCustomType")
        return "MyCustomType()"
    return False  # use default rendering

# In env.py
context.configure(
    ...
    render_item=render_item,
)
```

---

## Manual Migrations

Some changes cannot be autogenerated. Create empty migrations and write operations manually.

```bash
alembic revision -m "rename users.name to users.full_name"
```

### Common Manual Operations

```python
from alembic import op
import sqlalchemy as sa

def upgrade():
    # Rename column
    op.alter_column("users", "name", new_column_name="full_name")

    # Add column with default then remove default
    op.add_column("users", sa.Column("status", sa.String(20), server_default="active"))
    # After backfilling existing rows, optionally remove the default:
    # op.alter_column("users", "status", server_default=None)

    # Create index
    op.create_index("ix_users_email", "users", ["email"], unique=True)

    # Add check constraint
    op.create_check_constraint("ck_users_status", "users",
        "status IN ('active', 'inactive', 'banned')")

    # Rename table
    op.rename_table("user_profiles", "profiles")

    # Add composite unique constraint
    op.create_unique_constraint("uq_user_org", "memberships", ["user_id", "org_id"])

    # Drop column (with index removal if needed)
    op.drop_index("ix_users_legacy_field", table_name="users")
    op.drop_column("users", "legacy_field")

def downgrade():
    op.alter_column("users", "full_name", new_column_name="name")
    op.drop_index("ix_users_email", table_name="users")
    op.drop_constraint("ck_users_status", "users", type_="check")
    op.rename_table("profiles", "user_profiles")
    op.drop_constraint("uq_user_org", "memberships", type_="unique")
    op.add_column("users", sa.Column("legacy_field", sa.String(100)))
```

---

## Data Migrations

Combine schema changes with data transformations.

```python
from alembic import op
import sqlalchemy as sa
from sqlalchemy.sql import table, column

def upgrade():
    # 1. Add new column
    op.add_column("users", sa.Column("display_name", sa.String(200)))

    # 2. Backfill data using ad-hoc table reference
    users = table("users",
        column("id", sa.Integer),
        column("first_name", sa.String),
        column("last_name", sa.String),
        column("display_name", sa.String),
    )
    conn = op.get_bind()
    conn.execute(
        users.update().values(
            display_name=users.c.first_name + " " + users.c.last_name
        )
    )

    # 3. Make column non-nullable after backfill
    op.alter_column("users", "display_name", nullable=False)

    # 4. Drop old columns
    op.drop_column("users", "first_name")
    op.drop_column("users", "last_name")

def downgrade():
    op.add_column("users", sa.Column("first_name", sa.String(100)))
    op.add_column("users", sa.Column("last_name", sa.String(100)))

    users = table("users",
        column("display_name", sa.String),
        column("first_name", sa.String),
        column("last_name", sa.String),
    )
    conn = op.get_bind()
    # Best-effort split
    conn.execute(
        users.update().values(
            first_name=sa.func.split_part(users.c.display_name, " ", 1),
            last_name=sa.func.split_part(users.c.display_name, " ", 2),
        )
    )
    op.drop_column("users", "display_name")
```

### Large Data Migration (Batched)

```python
def upgrade():
    conn = op.get_bind()
    users = table("users", column("id", sa.Integer), column("email", sa.String))

    # Process in batches to avoid locking entire table
    batch_size = 1000
    offset = 0
    while True:
        rows = conn.execute(
            sa.select(users.c.id, users.c.email)
            .where(users.c.email.ilike("%@OLD-DOMAIN.COM"))
            .limit(batch_size)
            .offset(offset)
        ).fetchall()

        if not rows:
            break

        for row in rows:
            conn.execute(
                users.update()
                .where(users.c.id == row.id)
                .values(email=row.email.lower().replace("@old-domain.com", "@new-domain.com"))
            )
        offset += batch_size
```

---

## Multi-Database Migrations

### Setup

```ini
# alembic.ini
[alembic]
script_location = alembic

[primary]
sqlalchemy.url = postgresql://user:pass@localhost/primary

[analytics]
sqlalchemy.url = postgresql://user:pass@localhost/analytics
```

### Multi-db env.py

```python
from alembic import context
from sqlalchemy import engine_from_config, pool
import os

# Import all metadata objects
from myapp.models.primary import PrimaryBase
from myapp.models.analytics import AnalyticsBase

# Map database names to metadata
DATABASES = {
    "primary": PrimaryBase.metadata,
    "analytics": AnalyticsBase.metadata,
}

def run_migrations_online():
    for db_name, metadata in DATABASES.items():
        section = config.get_section(db_name)
        url = os.environ.get(f"{db_name.upper()}_DATABASE_URL", section["sqlalchemy.url"])

        engine = engine_from_config(
            {"sqlalchemy.url": url},
            prefix="sqlalchemy.",
            poolclass=pool.NullPool,
        )

        with engine.connect() as connection:
            context.configure(
                connection=connection,
                target_metadata=metadata,
                include_name=lambda name, type_, parent_names:
                    _include_for_db(name, type_, parent_names, db_name),
            )
            with context.begin_transaction():
                context.run_migrations()
```

Alternative: use separate Alembic directories per database:
```bash
alembic -c alembic_primary.ini upgrade head
alembic -c alembic_analytics.ini upgrade head
```

---

## Branch Management

### Working with Multiple Heads

```bash
# List current heads
alembic heads

# Show full history graph
alembic history --verbose

# Merge divergent heads
alembic merge heads -m "merge feature_x and feature_y"

# Merge specific revisions
alembic merge abc123 def456 -m "merge auth and billing"
```

### Branching for Features

```bash
# Create branch from specific revision
alembic revision --head abc123 -m "feature_x step 1" --branch-label feature_x

# Continue on branch
alembic revision --head feature_x -m "feature_x step 2"

# Merge branch back to main
alembic merge heads -m "merge feature_x"
```

### Resolving Conflicts

When two developers create migrations independently:

```bash
# Developer A: abc123 → aaa111
# Developer B: abc123 → bbb222
# After merge: two heads exist

# Create merge migration
alembic merge aaa111 bbb222 -m "merge dev A and B changes"
# This creates a migration with two down_revision entries

alembic upgrade head
```

---

## Downgrade Strategies

### Safe Downgrades

```bash
# Downgrade one step
alembic downgrade -1

# Downgrade to specific revision
alembic downgrade abc123

# Downgrade to base (empty database)
alembic downgrade base

# Generate downgrade SQL without applying
alembic downgrade -1 --sql
```

### Writing Reversible Migrations

```python
def upgrade():
    op.add_column("users", sa.Column("phone", sa.String(20)))
    op.create_index("ix_users_phone", "users", ["phone"])

def downgrade():
    op.drop_index("ix_users_phone", table_name="users")
    op.drop_column("users", "phone")
```

### Irreversible Migrations

Some migrations cannot be safely reversed. Document this clearly:

```python
def upgrade():
    # Destructive: dropping columns with data
    op.drop_column("users", "legacy_field")

def downgrade():
    # WARNING: Data in 'legacy_field' is permanently lost
    op.add_column("users", sa.Column("legacy_field", sa.String(200)))
    # Column will be empty after downgrade — data cannot be recovered
```

---

## Migration Testing

### Test Migrations Up and Down

```python
import pytest
from alembic.config import Config
from alembic import command
from sqlalchemy import create_engine, inspect

@pytest.fixture
def alembic_config():
    config = Config("alembic.ini")
    config.set_main_option("sqlalchemy.url", "sqlite:///test_migrations.db")
    return config

def test_upgrade_to_head(alembic_config):
    """Test that all migrations apply cleanly."""
    command.upgrade(alembic_config, "head")

def test_downgrade_to_base(alembic_config):
    """Test that all migrations can be reversed."""
    command.upgrade(alembic_config, "head")
    command.downgrade(alembic_config, "base")

def test_upgrade_downgrade_cycle(alembic_config):
    """Test full up-down-up cycle."""
    command.upgrade(alembic_config, "head")
    command.downgrade(alembic_config, "base")
    command.upgrade(alembic_config, "head")

def test_migration_creates_expected_tables(alembic_config):
    """Verify specific migration creates expected schema."""
    command.upgrade(alembic_config, "head")
    engine = create_engine(alembic_config.get_main_option("sqlalchemy.url"))
    inspector = inspect(engine)
    tables = inspector.get_table_names()
    assert "users" in tables
    assert "posts" in tables

    columns = {c["name"] for c in inspector.get_columns("users")}
    assert "email" in columns
    assert "created_at" in columns
```

### Verify Model Sync

```python
def test_models_match_migrations(alembic_config):
    """Ensure no pending model changes are unaccounted for."""
    from alembic.autogenerate import compare_metadata
    from myapp.models import Base

    command.upgrade(alembic_config, "head")
    engine = create_engine(alembic_config.get_main_option("sqlalchemy.url"))

    with engine.connect() as conn:
        diff = compare_metadata(
            context=context.MigrationContext.configure(conn),
            metadata=Base.metadata,
        )
    # diff should be empty — no unaccounted changes
    assert not diff, f"Pending model changes not in migrations: {diff}"
```

---

## CI Integration

### GitHub Actions

```yaml
name: Migration Check
on: [pull_request]

jobs:
  migrations:
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:16
        env:
          POSTGRES_USER: test
          POSTGRES_PASSWORD: test
          POSTGRES_DB: test
        ports: ["5432:5432"]
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5

    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.12"

      - run: pip install -r requirements.txt

      - name: Check for single head
        run: |
          heads=$(alembic heads | wc -l)
          if [ "$heads" -gt 1 ]; then
            echo "Multiple migration heads detected! Run: alembic merge heads"
            exit 1
          fi

      - name: Run upgrade
        env:
          DATABASE_URL: postgresql://test:test@localhost:5432/test
        run: alembic upgrade head

      - name: Run downgrade
        env:
          DATABASE_URL: postgresql://test:test@localhost:5432/test
        run: alembic downgrade base

      - name: Check no pending changes
        env:
          DATABASE_URL: postgresql://test:test@localhost:5432/test
        run: |
          alembic upgrade head
          alembic check  # exits non-zero if models differ from migrations
```

### Pre-commit Hook

```bash
#!/bin/bash
# .git/hooks/pre-commit or via pre-commit framework
# Check for multiple migration heads
heads=$(alembic heads 2>/dev/null | wc -l)
if [ "$heads" -gt 1 ]; then
    echo "ERROR: Multiple Alembic heads detected. Merge with: alembic merge heads"
    exit 1
fi
```

---

## Handling Enum Changes

Enums are tricky because PostgreSQL enums are standalone types.

### Adding a Value to PostgreSQL Enum

```python
def upgrade():
    # PostgreSQL: can't add enum values inside a transaction in older versions
    # Use execute with COMMIT
    op.execute("ALTER TYPE status_enum ADD VALUE IF NOT EXISTS 'archived'")

def downgrade():
    # PostgreSQL: Cannot remove enum values. Options:
    # 1. Create new enum without the value and swap (complex)
    # 2. Leave it (pragmatic)
    pass
```

### Replacing an Enum Entirely

```python
def upgrade():
    # 1. Create new enum type
    new_status = sa.Enum("active", "inactive", "archived", "banned", name="status_enum_new")
    new_status.create(op.get_bind())

    # 2. Alter column to use new type
    op.execute(
        "ALTER TABLE users ALTER COLUMN status TYPE status_enum_new "
        "USING status::text::status_enum_new"
    )

    # 3. Drop old enum and rename new
    op.execute("DROP TYPE status_enum")
    op.execute("ALTER TYPE status_enum_new RENAME TO status_enum")

def downgrade():
    old_status = sa.Enum("active", "inactive", name="status_enum_old")
    old_status.create(op.get_bind())
    op.execute(
        "ALTER TABLE users ALTER COLUMN status TYPE status_enum_old "
        "USING status::text::status_enum_old"
    )
    op.execute("DROP TYPE status_enum")
    op.execute("ALTER TYPE status_enum_old RENAME TO status_enum")
```

### Using String Instead of Enum (Simpler)

```python
# Avoid DB-level enums entirely — use String with CHECK constraint
class User(Base):
    __tablename__ = "users"
    status: Mapped[str] = mapped_column(
        String(20),
        default="active",
    )
    __table_args__ = (
        sa.CheckConstraint(
            "status IN ('active', 'inactive', 'archived')",
            name="ck_users_status",
        ),
    )
```

---

## Handling Column Type Changes

### Simple Type Change

```python
def upgrade():
    op.alter_column(
        "users", "age",
        existing_type=sa.String(10),
        type_=sa.Integer(),
        existing_nullable=True,
        # PostgreSQL needs USING for type cast
        postgresql_using="age::integer",
    )

def downgrade():
    op.alter_column(
        "users", "age",
        existing_type=sa.Integer(),
        type_=sa.String(10),
        existing_nullable=True,
        postgresql_using="age::varchar",
    )
```

### Type Change with Data Transformation

```python
def upgrade():
    # Add new column
    op.add_column("orders", sa.Column("amount_cents", sa.Integer()))

    # Transform data
    conn = op.get_bind()
    orders = table("orders",
        column("id", sa.Integer),
        column("amount", sa.Float),
        column("amount_cents", sa.Integer),
    )
    conn.execute(
        orders.update().values(amount_cents=sa.cast(orders.c.amount * 100, sa.Integer))
    )

    # Make non-nullable and drop old
    op.alter_column("orders", "amount_cents", nullable=False)
    op.drop_column("orders", "amount")

def downgrade():
    op.add_column("orders", sa.Column("amount", sa.Float()))
    conn = op.get_bind()
    orders = table("orders",
        column("amount", sa.Float),
        column("amount_cents", sa.Integer),
    )
    conn.execute(orders.update().values(amount=orders.c.amount_cents / 100.0))
    op.drop_column("orders", "amount_cents")
```

---

## Batch Operations for SQLite

SQLite doesn't support `ALTER TABLE` for most operations. Use Alembic's batch mode.

```python
def upgrade():
    # Batch mode: creates new table, copies data, drops old, renames new
    with op.batch_alter_table("users") as batch_op:
        batch_op.add_column(sa.Column("phone", sa.String(20)))
        batch_op.alter_column("name",
            existing_type=sa.String(50),
            type_=sa.String(100),
        )
        batch_op.drop_column("legacy_field")
        batch_op.create_index("ix_users_phone", ["phone"])

def downgrade():
    with op.batch_alter_table("users") as batch_op:
        batch_op.drop_index("ix_users_phone")
        batch_op.add_column(sa.Column("legacy_field", sa.String(200)))
        batch_op.alter_column("name",
            existing_type=sa.String(100),
            type_=sa.String(50),
        )
        batch_op.drop_column("phone")
```

### Configuring Batch Mode Globally

```python
# In env.py — use batch mode for SQLite, normal for others
def run_migrations_online():
    connectable = engine_from_config(...)

    with connectable.connect() as connection:
        is_sqlite = connection.dialect.name == "sqlite"
        context.configure(
            connection=connection,
            target_metadata=target_metadata,
            render_as_batch=is_sqlite,  # batch mode for SQLite only
        )
        with context.begin_transaction():
            context.run_migrations()
```

### Batch Mode Limitations

- Temporarily requires ~2x table storage (copies all data).
- Foreign keys referencing the table may break during the copy.
- Use `naming_convention` on MetaData — batch mode needs deterministic constraint names.
- For large tables, consider running during maintenance windows.

### Naming Convention (Required for Batch Mode)

```python
convention = {
    "ix": "ix_%(column_0_label)s",
    "uq": "uq_%(table_name)s_%(column_0_N_name)s",
    "ck": "ck_%(table_name)s_%(constraint_name)s",
    "fk": "fk_%(table_name)s_%(column_0_name)s_%(referred_table_name)s",
    "pk": "pk_%(table_name)s",
}

class Base(DeclarativeBase):
    metadata = MetaData(naming_convention=convention)
```
