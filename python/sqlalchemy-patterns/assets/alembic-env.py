"""
Production-ready Alembic env.py with:
- Async engine support
- Environment variable URL override
- Multi-database support (optional)
- Structured logging
- Type and server default comparison
- SQLite batch mode
- Schema filtering

Replace 'myapp.models' with your actual models package.
"""

import asyncio
import logging
import os
import sys
from logging.config import fileConfig

from sqlalchemy import engine_from_config, pool, text
from sqlalchemy.ext.asyncio import async_engine_from_config
from alembic import context

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Ensure the app package is importable
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

# Import your Base — make sure ALL model modules are imported before this
# so that Base.metadata contains all table definitions.
# Option A: import individual models
# from myapp.models.user import User  # noqa: F401
# from myapp.models.post import Post  # noqa: F401
# Option B: import via package __init__ that re-exports all models
from myapp.models import Base  # noqa: E402

config = context.config

# Set up Python logging from alembic.ini
if config.config_file_name is not None:
    fileConfig(config.config_file_name)

logger = logging.getLogger("alembic.env")

target_metadata = Base.metadata

# Set to True if your project uses async drivers (asyncpg, aiosqlite, etc.)
USE_ASYNC = os.environ.get("ALEMBIC_USE_ASYNC", "false").lower() == "true"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def get_url() -> str:
    """Get database URL from environment or alembic.ini."""
    url = os.environ.get("DATABASE_URL", config.get_main_option("sqlalchemy.url"))
    if not url:
        raise RuntimeError(
            "No database URL configured. Set DATABASE_URL env var "
            "or sqlalchemy.url in alembic.ini."
        )
    # Fix common Heroku-style URL prefix
    if url.startswith("postgres://"):
        url = url.replace("postgres://", "postgresql://", 1)
    return url


def include_name(name, type_, parent_names):
    """Filter which schemas/tables Alembic should manage.

    Customize to exclude specific schemas (e.g., information_schema)
    or tables managed by other tools.
    """
    if type_ == "schema":
        return name in [None, "public"]
    return True


# ---------------------------------------------------------------------------
# Offline mode — generates SQL script without connecting
# ---------------------------------------------------------------------------


def run_migrations_offline() -> None:
    """Run migrations in 'offline' mode."""
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


# ---------------------------------------------------------------------------
# Online mode — sync
# ---------------------------------------------------------------------------


def run_migrations_online_sync() -> None:
    """Run migrations with a sync engine."""
    configuration = config.get_section(config.config_ini_section, {})
    configuration["sqlalchemy.url"] = get_url()

    connectable = engine_from_config(
        configuration,
        prefix="sqlalchemy.",
        poolclass=pool.NullPool,
    )

    with connectable.connect() as connection:
        is_sqlite = connection.dialect.name == "sqlite"

        context.configure(
            connection=connection,
            target_metadata=target_metadata,
            include_name=include_name,
            compare_type=True,
            compare_server_default=True,
            render_as_batch=is_sqlite,  # batch mode for SQLite
        )

        with context.begin_transaction():
            context.run_migrations()


# ---------------------------------------------------------------------------
# Online mode — async
# ---------------------------------------------------------------------------


def do_run_migrations(connection) -> None:
    """Configure context and run migrations (called from async)."""
    is_sqlite = connection.dialect.name == "sqlite"

    context.configure(
        connection=connection,
        target_metadata=target_metadata,
        include_name=include_name,
        compare_type=True,
        compare_server_default=True,
        render_as_batch=is_sqlite,
    )

    with context.begin_transaction():
        context.run_migrations()


async def run_async_migrations() -> None:
    """Run migrations with an async engine."""
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


def run_migrations_online_async() -> None:
    """Entry point for async online migrations."""
    asyncio.run(run_async_migrations())


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if context.is_offline_mode():
    run_migrations_offline()
elif USE_ASYNC:
    run_migrations_online_async()
else:
    run_migrations_online_sync()
