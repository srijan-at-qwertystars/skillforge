#!/usr/bin/env bash
# alembic-setup.sh — Initialize Alembic in an existing SQLAlchemy project with async support
#
# Usage:
#   ./alembic-setup.sh <database_url> [models_import_path]
#
# Examples:
#   ./alembic-setup.sh "postgresql+asyncpg://user:pass@localhost/mydb" "myapp.models"
#   ./alembic-setup.sh "sqlite+aiosqlite:///./app.db"
#
# The models_import_path defaults to "app.models" if not specified.
# It should be a Python import path where Base is importable from.
#
# Requires: alembic, sqlalchemy already installed in the environment.

set -euo pipefail

DATABASE_URL="${1:?Usage: $0 <database_url> [models_import_path]}"
MODELS_PATH="${2:-app.models}"

# Check alembic is installed
if ! command -v alembic &> /dev/null; then
    echo "Error: alembic not found. Install it: pip install alembic" >&2
    exit 1
fi

# Don't overwrite existing alembic setup
if [ -d "alembic" ] || [ -f "alembic.ini" ]; then
    echo "Error: Alembic already initialized (alembic/ or alembic.ini exists)." >&2
    echo "Remove them first if you want to reinitialize." >&2
    exit 1
fi

echo "Initializing Alembic with async support..."
echo "  Database URL: ${DATABASE_URL%%@*}@***"
echo "  Models path:  $MODELS_PATH"

# Initialize alembic directory
alembic init alembic

# ---- Replace env.py with async-capable version ----
cat > alembic/env.py << ENVPY
import asyncio
import os
import sys
from logging.config import fileConfig

from sqlalchemy import pool
from sqlalchemy.ext.asyncio import async_engine_from_config
from alembic import context

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from ${MODELS_PATH} import Base  # noqa: E402

config = context.config
if config.config_file_name is not None:
    fileConfig(config.config_file_name)

target_metadata = Base.metadata


def get_url():
    return os.environ.get("DATABASE_URL", config.get_main_option("sqlalchemy.url"))


def run_migrations_offline():
    context.configure(
        url=get_url(),
        target_metadata=target_metadata,
        literal_binds=True,
        compare_type=True,
        compare_server_default=True,
    )
    with context.begin_transaction():
        context.run_migrations()


def do_run_migrations(connection):
    is_sqlite = connection.dialect.name == "sqlite"
    context.configure(
        connection=connection,
        target_metadata=target_metadata,
        compare_type=True,
        compare_server_default=True,
        render_as_batch=is_sqlite,
    )
    with context.begin_transaction():
        context.run_migrations()


async def run_async_migrations():
    configuration = config.get_section(config.config_ini_section, {})
    configuration["sqlalchemy.url"] = get_url()
    connectable = async_engine_from_config(
        configuration, prefix="sqlalchemy.", poolclass=pool.NullPool,
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
ENVPY

# ---- Update alembic.ini with database URL and better file template ----
sed -i "s|^sqlalchemy.url = .*|sqlalchemy.url = ${DATABASE_URL}|" alembic.ini

# Add file template for readable migration filenames
sed -i '/^\[alembic\]/a file_template = %%(year)d_%%(month).2d_%%(day).2d_%%(hour).2d%%(minute).2d-%%(rev)s_%%(slug)s\ntruncate_slug_length = 40\ntimezone = UTC' alembic.ini

echo ""
echo "✅ Alembic initialized with async support."
echo ""
echo "Next steps:"
echo "  1. Ensure '$MODELS_PATH' is importable and exports 'Base'"
echo "  2. alembic revision --autogenerate -m 'initial'"
echo "  3. alembic upgrade head"
echo ""
echo "To override URL at runtime: export DATABASE_URL=..."
