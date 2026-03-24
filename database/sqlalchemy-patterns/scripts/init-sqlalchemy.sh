#!/usr/bin/env bash
# ==============================================================================
# init-sqlalchemy.sh — Bootstrap a SQLAlchemy + Alembic project
#
# Usage:
#   ./init-sqlalchemy.sh <project_name> [--async] [--db postgres|sqlite|mysql]
#
# Creates:
#   <project_name>/
#   ├── <project_name>/
#   │   ├── __init__.py
#   │   ├── models/
#   │   │   ├── __init__.py
#   │   │   └── base.py          # DeclarativeBase + mixins
#   │   ├── db/
#   │   │   ├── __init__.py
#   │   │   ├── engine.py        # Engine + session factory
#   │   │   └── session.py       # Session dependency (FastAPI-ready)
#   │   └── repositories/
#   │       └── __init__.py
#   ├── alembic/
#   │   ├── env.py               # Configured for your setup
#   │   └── versions/
#   ├── alembic.ini
#   ├── tests/
#   │   ├── __init__.py
#   │   └── conftest.py          # pytest fixtures for DB testing
#   └── requirements.txt
# ==============================================================================

set -euo pipefail

# --- Defaults ---
ASYNC_MODE=false
DB_TYPE="postgres"

# --- Parse args ---
PROJECT_NAME="${1:?Usage: $0 <project_name> [--async] [--db postgres|sqlite|mysql]}"
shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --async) ASYNC_MODE=true; shift ;;
        --db) DB_TYPE="${2:?--db requires a value}"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

echo "🔧 Creating SQLAlchemy project: $PROJECT_NAME (db=$DB_TYPE, async=$ASYNC_MODE)"

# --- Create directory structure ---
mkdir -p "$PROJECT_NAME"/{$PROJECT_NAME/{models,db,repositories},tests,alembic/versions}

# --- requirements.txt ---
cat > "$PROJECT_NAME/requirements.txt" <<'EOF'
sqlalchemy>=2.0
alembic>=1.12
EOF

case "$DB_TYPE" in
    postgres)
        if $ASYNC_MODE; then
            echo "asyncpg" >> "$PROJECT_NAME/requirements.txt"
            echo "sqlalchemy[asyncio]" >> "$PROJECT_NAME/requirements.txt"
            SYNC_URL='postgresql+psycopg2://user:password@localhost:5432/dbname'
            ASYNC_URL='postgresql+asyncpg://user:password@localhost:5432/dbname'
        else
            echo "psycopg2-binary" >> "$PROJECT_NAME/requirements.txt"
            SYNC_URL='postgresql+psycopg2://user:password@localhost:5432/dbname'
        fi
        ;;
    sqlite)
        SYNC_URL='sqlite:///app.db'
        if $ASYNC_MODE; then
            echo "aiosqlite" >> "$PROJECT_NAME/requirements.txt"
            ASYNC_URL='sqlite+aiosqlite:///app.db'
        fi
        ;;
    mysql)
        if $ASYNC_MODE; then
            echo "aiomysql" >> "$PROJECT_NAME/requirements.txt"
            ASYNC_URL='mysql+aiomysql://user:password@localhost:3306/dbname'
        else
            echo "pymysql" >> "$PROJECT_NAME/requirements.txt"
        fi
        SYNC_URL='mysql+pymysql://user:password@localhost:3306/dbname'
        ;;
    *) echo "Unsupported DB type: $DB_TYPE"; exit 1 ;;
esac

echo "pytest" >> "$PROJECT_NAME/requirements.txt"
if $ASYNC_MODE; then
    echo "pytest-asyncio" >> "$PROJECT_NAME/requirements.txt"
fi

# --- __init__.py files ---
touch "$PROJECT_NAME/$PROJECT_NAME/__init__.py"
touch "$PROJECT_NAME/$PROJECT_NAME/models/__init__.py"
touch "$PROJECT_NAME/$PROJECT_NAME/db/__init__.py"
touch "$PROJECT_NAME/$PROJECT_NAME/repositories/__init__.py"
touch "$PROJECT_NAME/tests/__init__.py"

# --- models/base.py ---
cat > "$PROJECT_NAME/$PROJECT_NAME/models/base.py" <<'PYEOF'
"""Base model with common mixins."""
from datetime import datetime
from sqlalchemy import DateTime, String, func
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column
from sqlalchemy.ext.hybrid import hybrid_property


class Base(DeclarativeBase):
    """Base class for all models."""
    pass


class TimestampMixin:
    """Adds created_at and updated_at columns."""
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )


class SoftDeleteMixin:
    """Adds soft delete support via deleted_at timestamp."""
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
PYEOF

# --- db/engine.py ---
if $ASYNC_MODE; then
cat > "$PROJECT_NAME/$PROJECT_NAME/db/engine.py" <<PYEOF
"""Database engine and session factory."""
import os
from sqlalchemy.ext.asyncio import create_async_engine, async_sessionmaker, AsyncSession

DATABASE_URL = os.environ.get("DATABASE_URL", "$ASYNC_URL")

engine = create_async_engine(
    DATABASE_URL,
    pool_size=10,
    max_overflow=5,
    pool_pre_ping=True,
    echo=os.environ.get("SQL_ECHO", "false").lower() == "true",
)

AsyncSessionLocal = async_sessionmaker(
    engine,
    class_=AsyncSession,
    expire_on_commit=False,
)
PYEOF
else
cat > "$PROJECT_NAME/$PROJECT_NAME/db/engine.py" <<PYEOF
"""Database engine and session factory."""
import os
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker, Session

DATABASE_URL = os.environ.get("DATABASE_URL", "$SYNC_URL")

engine = create_engine(
    DATABASE_URL,
    pool_size=10,
    max_overflow=5,
    pool_pre_ping=True,
    echo=os.environ.get("SQL_ECHO", "false").lower() == "true",
)

SessionLocal = sessionmaker(bind=engine, expire_on_commit=False)
PYEOF
fi

# --- db/session.py (FastAPI-ready dependency) ---
if $ASYNC_MODE; then
cat > "$PROJECT_NAME/$PROJECT_NAME/db/session.py" <<'PYEOF'
"""Session dependency for FastAPI."""
from typing import AsyncGenerator
from sqlalchemy.ext.asyncio import AsyncSession
from .engine import AsyncSessionLocal


async def get_db() -> AsyncGenerator[AsyncSession, None]:
    async with AsyncSessionLocal() as session:
        yield session
PYEOF
else
cat > "$PROJECT_NAME/$PROJECT_NAME/db/session.py" <<'PYEOF'
"""Session dependency for FastAPI."""
from typing import Generator
from sqlalchemy.orm import Session
from .engine import SessionLocal


def get_db() -> Generator[Session, None, None]:
    with SessionLocal() as session:
        yield session
PYEOF
fi

# --- alembic.ini ---
cat > "$PROJECT_NAME/alembic.ini" <<ALEMBICEOF
[alembic]
script_location = alembic
sqlalchemy.url = $SYNC_URL
prepend_sys_path = .

[loggers]
keys = root,sqlalchemy,alembic

[handlers]
keys = console

[formatters]
keys = generic

[logger_root]
level = WARN
handlers = console

[logger_sqlalchemy]
level = WARN
handlers =
qualname = sqlalchemy.engine

[logger_alembic]
level = INFO
handlers =
qualname = alembic

[handler_console]
class = StreamHandler
args = (sys.stderr,)
level = NOTSET
formatter = generic

[formatter_generic]
format = %(levelname)-5.5s [%(name)s] %(message)s
ALEMBICEOF

# --- alembic/script.py.mako ---
cat > "$PROJECT_NAME/alembic/script.py.mako" <<'MAKOEOF'
"""${message}

Revision ID: ${up_revision}
Revises: ${down_revision | comma,n}
Create Date: ${create_date}
"""
from typing import Sequence, Union
from alembic import op
import sqlalchemy as sa
${imports if imports else ""}

revision: str = ${repr(up_revision)}
down_revision: Union[str, None] = ${repr(down_revision)}
branch_labels: Union[str, Sequence[str], None] = ${repr(branch_labels)}
depends_on: Union[str, Sequence[str], None] = ${repr(depends_on)}


def upgrade() -> None:
    ${upgrades if upgrades else "pass"}


def downgrade() -> None:
    ${downgrades if downgrades else "pass"}
MAKOEOF

# --- alembic/env.py ---
if $ASYNC_MODE; then
cat > "$PROJECT_NAME/alembic/env.py" <<PYEOF
"""Alembic environment configuration (async)."""
import asyncio
import os
from logging.config import fileConfig
from alembic import context
from sqlalchemy.ext.asyncio import create_async_engine
from ${PROJECT_NAME}.models.base import Base

config = context.config
if config.config_file_name is not None:
    fileConfig(config.config_file_name)

target_metadata = Base.metadata

def get_url():
    return os.environ.get("DATABASE_URL", config.get_main_option("sqlalchemy.url"))

def run_migrations_offline() -> None:
    context.configure(url=get_url(), target_metadata=target_metadata, literal_binds=True)
    with context.begin_transaction():
        context.run_migrations()

def do_run_migrations(connection):
    context.configure(connection=connection, target_metadata=target_metadata)
    with context.begin_transaction():
        context.run_migrations()

async def run_migrations_online() -> None:
    connectable = create_async_engine(get_url().replace("+psycopg2", "+asyncpg"))
    async with connectable.connect() as connection:
        await connection.run_sync(do_run_migrations)
    await connectable.dispose()

if context.is_offline_mode():
    run_migrations_offline()
else:
    asyncio.run(run_migrations_online())
PYEOF
else
cat > "$PROJECT_NAME/alembic/env.py" <<PYEOF
"""Alembic environment configuration."""
import os
from logging.config import fileConfig
from alembic import context
from sqlalchemy import engine_from_config, pool
from ${PROJECT_NAME}.models.base import Base

config = context.config
if config.config_file_name is not None:
    fileConfig(config.config_file_name)

target_metadata = Base.metadata

def get_url():
    return os.environ.get("DATABASE_URL", config.get_main_option("sqlalchemy.url"))

def run_migrations_offline() -> None:
    context.configure(url=get_url(), target_metadata=target_metadata, literal_binds=True)
    with context.begin_transaction():
        context.run_migrations()

def run_migrations_online() -> None:
    configuration = config.get_section(config.config_ini_section, {})
    configuration["sqlalchemy.url"] = get_url()
    connectable = engine_from_config(configuration, prefix="sqlalchemy.", poolclass=pool.NullPool)
    with connectable.connect() as connection:
        context.configure(connection=connection, target_metadata=target_metadata)
        with context.begin_transaction():
            context.run_migrations()

if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
PYEOF
fi

# --- tests/conftest.py ---
if $ASYNC_MODE; then
cat > "$PROJECT_NAME/tests/conftest.py" <<'PYEOF'
"""Pytest fixtures for async SQLAlchemy testing."""
import pytest
import pytest_asyncio
from sqlalchemy.ext.asyncio import create_async_engine, async_sessionmaker, AsyncSession
from $PROJECT_NAME.models.base import Base


@pytest_asyncio.fixture
async def async_engine():
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    yield engine
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)
    await engine.dispose()


@pytest_asyncio.fixture
async def db_session(async_engine):
    session = async_sessionmaker(async_engine, expire_on_commit=False)
    async with session() as s:
        yield s
PYEOF
else
cat > "$PROJECT_NAME/tests/conftest.py" <<'PYEOF'
"""Pytest fixtures for SQLAlchemy testing."""
import pytest
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker, Session
from $PROJECT_NAME.models.base import Base


@pytest.fixture(scope="session")
def engine():
    engine = create_engine("sqlite:///:memory:")
    Base.metadata.create_all(engine)
    yield engine
    Base.metadata.drop_all(engine)
    engine.dispose()


@pytest.fixture
def db_session(engine):
    """Transaction-scoped session: rolls back after each test."""
    connection = engine.connect()
    transaction = connection.begin()
    session = Session(bind=connection)
    yield session
    session.close()
    transaction.rollback()
    connection.close()
PYEOF
fi

echo ""
echo "✅ Project '$PROJECT_NAME' created successfully!"
echo ""
echo "Next steps:"
echo "  cd $PROJECT_NAME"
echo "  pip install -r requirements.txt"
echo "  # Edit alembic.ini with your database URL"
echo "  # Add models to $PROJECT_NAME/models/"
echo "  alembic revision --autogenerate -m 'initial'"
echo "  alembic upgrade head"
