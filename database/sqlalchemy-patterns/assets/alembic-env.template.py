"""
Alembic env.py template with support for:
- Sync and async engines
- Multi-database migrations
- Environment variable overrides
- Table include/exclude filtering

Usage:
    Copy to your alembic/env.py and adjust the imports at the top.

Configuration:
    Set DATABASE_URL env var or edit alembic.ini sqlalchemy.url.
    For async: set ASYNC_MODE=true env var or configure below.
    For multi-db: see MULTI_DB_URLS section below.
"""

import asyncio
import os
from logging.config import fileConfig

from alembic import context
from sqlalchemy import engine_from_config, pool, text
from sqlalchemy.engine import Connection

# ---------------------------------------------------------------------------
# CONFIGURE THESE: Import your Base metadata
# ---------------------------------------------------------------------------
# from myapp.models.base import Base
# target_metadata = Base.metadata

# Placeholder — replace with your actual metadata
target_metadata = None  # type: ignore[assignment]

# ---------------------------------------------------------------------------
# Alembic Config
# ---------------------------------------------------------------------------
config = context.config

if config.config_file_name is not None:
    fileConfig(config.config_file_name)

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------
ASYNC_MODE = os.environ.get("ASYNC_MODE", "false").lower() == "true"

# Tables to exclude from autogenerate (e.g., spatial, third-party)
EXCLUDE_TABLES: set[str] = {"spatial_ref_sys", "alembic_version"}

# Multi-database URLs (optional)
# Set these to enable multi-database migrations
MULTI_DB_URLS: dict[str, str] = {
    # "secondary": "postgresql://user:pass@host/secondary_db",
}


def get_url() -> str:
    """Get database URL from environment or alembic.ini."""
    return os.environ.get(
        "DATABASE_URL", config.get_main_option("sqlalchemy.url", "")
    )


def include_name(name: str | None, type_: str, parent_names: dict) -> bool:
    """Filter tables/objects for autogenerate."""
    if type_ == "table" and name in EXCLUDE_TABLES:
        return False
    return True


def include_object(object, name, type_, reflected, compare_to) -> bool:
    """Additional filtering for autogenerate.

    Skip objects not in target_metadata (e.g., views, extensions).
    """
    if type_ == "table" and name in EXCLUDE_TABLES:
        return False
    return True


# ---------------------------------------------------------------------------
# Offline (SQL script) migrations
# ---------------------------------------------------------------------------
def run_migrations_offline() -> None:
    """Run migrations in 'offline' mode — generates SQL script."""
    url = get_url()
    context.configure(
        url=url,
        target_metadata=target_metadata,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
        include_name=include_name,
        include_object=include_object,
        compare_type=True,
        compare_server_default=True,
    )
    with context.begin_transaction():
        context.run_migrations()


# ---------------------------------------------------------------------------
# Online (sync) migrations
# ---------------------------------------------------------------------------
def do_run_migrations(connection: Connection) -> None:
    """Configure and run migrations on a connection."""
    context.configure(
        connection=connection,
        target_metadata=target_metadata,
        include_name=include_name,
        include_object=include_object,
        compare_type=True,
        compare_server_default=True,
        render_as_batch=True,  # Required for SQLite ALTER TABLE support
    )
    with context.begin_transaction():
        context.run_migrations()


def run_migrations_online_sync() -> None:
    """Run migrations in 'online' mode with a sync engine."""
    configuration = config.get_section(config.config_ini_section, {})
    configuration["sqlalchemy.url"] = get_url()
    connectable = engine_from_config(
        configuration,
        prefix="sqlalchemy.",
        poolclass=pool.NullPool,
    )
    with connectable.connect() as connection:
        do_run_migrations(connection)


# ---------------------------------------------------------------------------
# Online (async) migrations
# ---------------------------------------------------------------------------
async def run_migrations_online_async() -> None:
    """Run migrations in 'online' mode with an async engine."""
    from sqlalchemy.ext.asyncio import create_async_engine

    connectable = create_async_engine(get_url(), poolclass=pool.NullPool)
    async with connectable.connect() as connection:
        await connection.run_sync(do_run_migrations)
    await connectable.dispose()


# ---------------------------------------------------------------------------
# Multi-database migrations (optional)
# ---------------------------------------------------------------------------
def run_multi_db_migrations() -> None:
    """Run migrations against multiple databases.

    Enable by populating MULTI_DB_URLS above.
    Each database should have its own metadata and migration versioning.
    """
    from sqlalchemy import create_engine

    # Primary database
    primary_engine = create_engine(get_url(), poolclass=pool.NullPool)
    with primary_engine.connect() as conn:
        do_run_migrations(conn)

    # Secondary databases
    for db_name, db_url in MULTI_DB_URLS.items():
        print(f"Running migrations for: {db_name}")
        engine = create_engine(db_url, poolclass=pool.NullPool)
        with engine.connect() as conn:
            do_run_migrations(conn)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
if context.is_offline_mode():
    run_migrations_offline()
elif MULTI_DB_URLS:
    run_multi_db_migrations()
elif ASYNC_MODE:
    asyncio.run(run_migrations_online_async())
else:
    run_migrations_online_sync()
