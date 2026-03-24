#!/usr/bin/env bash
# sqlalchemy-init.sh — Scaffold a SQLAlchemy 2.0 project
#
# Usage:
#   ./sqlalchemy-init.sh <project_name> [postgres|sqlite|mysql]
#
# Examples:
#   ./sqlalchemy-init.sh myapp postgres
#   ./sqlalchemy-init.sh myapp sqlite
#
# Creates:
#   <project_name>/
#   ├── <project_name>/
#   │   ├── __init__.py
#   │   ├── models/
#   │   │   ├── __init__.py
#   │   │   └── base.py
#   │   ├── repositories/
#   │   │   ├── __init__.py
#   │   │   └── base.py
#   │   └── db.py
#   ├── alembic/
#   │   ├── env.py
#   │   ├── script.py.mako
#   │   └── versions/
#   ├── tests/
#   │   ├── __init__.py
#   │   └── conftest.py
#   ├── alembic.ini
#   ├── pyproject.toml
#   └── .env.example

set -euo pipefail

PROJECT_NAME="${1:?Usage: $0 <project_name> [postgres|sqlite|mysql]}"
DB_TYPE="${2:-postgres}"

# Validate DB type
case "$DB_TYPE" in
    postgres|postgresql) DB_TYPE="postgres" ;;
    sqlite) ;;
    mysql) ;;
    *) echo "Error: Unsupported database type '$DB_TYPE'. Use: postgres, sqlite, mysql" >&2; exit 1 ;;
esac

# Set driver info based on DB type
case "$DB_TYPE" in
    postgres)
        SYNC_DRIVER="postgresql+psycopg"
        ASYNC_DRIVER="postgresql+asyncpg"
        SYNC_PACKAGE="psycopg[binary]"
        ASYNC_PACKAGE="asyncpg"
        DEFAULT_URL="postgresql+asyncpg://user:password@localhost:5432/${PROJECT_NAME}"
        ;;
    sqlite)
        SYNC_DRIVER="sqlite"
        ASYNC_DRIVER="sqlite+aiosqlite"
        SYNC_PACKAGE=""
        ASYNC_PACKAGE="aiosqlite"
        DEFAULT_URL="sqlite+aiosqlite:///./${PROJECT_NAME}.db"
        ;;
    mysql)
        SYNC_DRIVER="mysql+pymysql"
        ASYNC_DRIVER="mysql+aiomysql"
        SYNC_PACKAGE="pymysql"
        ASYNC_PACKAGE="aiomysql"
        DEFAULT_URL="mysql+aiomysql://user:password@localhost:3306/${PROJECT_NAME}"
        ;;
esac

echo "Creating SQLAlchemy project: $PROJECT_NAME (database: $DB_TYPE)"

# Create directory structure
mkdir -p "$PROJECT_NAME"/{${PROJECT_NAME}/{models,repositories},alembic/versions,tests}

# ---- pyproject.toml ----
cat > "$PROJECT_NAME/pyproject.toml" << 'PYPROJECT'
[project]
name = "PROJECT_NAME_PLACEHOLDER"
version = "0.1.0"
requires-python = ">=3.11"
dependencies = [
    "sqlalchemy>=2.0",
    "alembic>=1.13",
PYPROJECT

# Add DB-specific dependencies
{
    if [ -n "$ASYNC_PACKAGE" ]; then echo "    \"$ASYNC_PACKAGE\","; fi
    if [ -n "$SYNC_PACKAGE" ]; then echo "    \"$SYNC_PACKAGE\","; fi
    cat << 'PYPROJECT'
]

[project.optional-dependencies]
dev = [
    "pytest>=8.0",
    "pytest-asyncio>=0.23",
]
PYPROJECT
} >> "$PROJECT_NAME/pyproject.toml"

sed -i "s/PROJECT_NAME_PLACEHOLDER/$PROJECT_NAME/" "$PROJECT_NAME/pyproject.toml"

# ---- .env.example ----
cat > "$PROJECT_NAME/.env.example" << EOF
DATABASE_URL=$DEFAULT_URL
EOF

# ---- Package __init__.py files ----
touch "$PROJECT_NAME/${PROJECT_NAME}/__init__.py"
touch "$PROJECT_NAME/${PROJECT_NAME}/models/__init__.py"
touch "$PROJECT_NAME/${PROJECT_NAME}/repositories/__init__.py"
touch "$PROJECT_NAME/tests/__init__.py"

# ---- models/base.py ----
cat > "$PROJECT_NAME/${PROJECT_NAME}/models/base.py" << 'MODELS'
from datetime import datetime
from typing import Optional

from sqlalchemy import MetaData, func
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column

NAMING_CONVENTION = {
    "ix": "ix_%(column_0_label)s",
    "uq": "uq_%(table_name)s_%(column_0_N_name)s",
    "ck": "ck_%(table_name)s_%(constraint_name)s",
    "fk": "fk_%(table_name)s_%(column_0_name)s_%(referred_table_name)s",
    "pk": "pk_%(table_name)s",
}


class Base(DeclarativeBase):
    metadata = MetaData(naming_convention=NAMING_CONVENTION)

    id: Mapped[int] = mapped_column(primary_key=True)
    created_at: Mapped[datetime] = mapped_column(server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        server_default=func.now(), onupdate=func.now()
    )

    def __repr__(self) -> str:
        return f"<{self.__class__.__name__}(id={self.id})>"
MODELS

# ---- models/__init__.py (re-export Base) ----
cat > "$PROJECT_NAME/${PROJECT_NAME}/models/__init__.py" << 'INIT'
from .base import Base

__all__ = ["Base"]
INIT

# ---- db.py ----
cat > "$PROJECT_NAME/${PROJECT_NAME}/db.py" << 'DB'
import os
from contextlib import asynccontextmanager
from typing import AsyncGenerator

from sqlalchemy.ext.asyncio import (
    AsyncEngine,
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)


def get_engine(url: str | None = None, echo: bool = False) -> AsyncEngine:
    database_url = url or os.environ.get("DATABASE_URL")
    if not database_url:
        raise ValueError("Set DATABASE_URL or pass url=")
    return create_async_engine(
        database_url,
        pool_pre_ping=True,
        echo=echo,
    )


def get_session_factory(engine: AsyncEngine) -> async_sessionmaker[AsyncSession]:
    return async_sessionmaker(
        bind=engine,
        class_=AsyncSession,
        expire_on_commit=False,
    )


engine = get_engine() if os.environ.get("DATABASE_URL") else None
AsyncSessionLocal = get_session_factory(engine) if engine else None


@asynccontextmanager
async def get_session() -> AsyncGenerator[AsyncSession, None]:
    if AsyncSessionLocal is None:
        raise RuntimeError("Database not configured. Set DATABASE_URL.")
    async with AsyncSessionLocal() as session:
        try:
            yield session
            await session.commit()
        except Exception:
            await session.rollback()
            raise
DB

# ---- repositories/base.py ----
cat > "$PROJECT_NAME/${PROJECT_NAME}/repositories/base.py" << 'REPO'
from typing import Any, Generic, Sequence, TypeVar

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import DeclarativeBase

T = TypeVar("T", bound=DeclarativeBase)


class BaseRepository(Generic[T]):
    def __init__(self, session: AsyncSession, model: type[T]) -> None:
        self.session = session
        self.model = model

    async def get(self, id: int) -> T | None:
        return await self.session.get(self.model, id)

    async def list(self, *, limit: int = 100, offset: int = 0) -> Sequence[T]:
        stmt = select(self.model).offset(offset).limit(limit)
        result = await self.session.scalars(stmt)
        return result.all()

    async def create(self, **kwargs: Any) -> T:
        obj = self.model(**kwargs)
        self.session.add(obj)
        await self.session.flush()
        await self.session.refresh(obj)
        return obj

    async def update(self, id: int, **kwargs: Any) -> T:
        obj = await self.get(id)
        if obj is None:
            raise ValueError(f"{self.model.__name__} {id} not found")
        for k, v in kwargs.items():
            setattr(obj, k, v)
        await self.session.flush()
        return obj

    async def delete(self, id: int) -> None:
        obj = await self.get(id)
        if obj is None:
            raise ValueError(f"{self.model.__name__} {id} not found")
        await self.session.delete(obj)
        await self.session.flush()

    async def count(self) -> int:
        result = await self.session.execute(
            select(func.count(self.model.id))
        )
        return result.scalar_one()
REPO

# ---- alembic.ini ----
cat > "$PROJECT_NAME/alembic.ini" << ALEMBIC
[alembic]
script_location = alembic
file_template = %%(year)d_%%(month).2d_%%(day).2d_%%(hour).2d%%(minute).2d-%%(rev)s_%%(slug)s
truncate_slug_length = 40
timezone = UTC
sqlalchemy.url = $DEFAULT_URL

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
datefmt = %H:%M:%S
ALEMBIC

# ---- alembic/env.py ----
cat > "$PROJECT_NAME/alembic/env.py" << 'ENVPY'
import asyncio
import os
import sys
from logging.config import fileConfig

from sqlalchemy import pool
from sqlalchemy.ext.asyncio import async_engine_from_config
from alembic import context

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from APP_PLACEHOLDER.models import Base  # noqa: E402

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
    )
    with context.begin_transaction():
        context.run_migrations()


def do_run_migrations(connection):
    is_sqlite = connection.dialect.name == "sqlite"
    context.configure(
        connection=connection,
        target_metadata=target_metadata,
        compare_type=True,
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

sed -i "s/APP_PLACEHOLDER/$PROJECT_NAME/" "$PROJECT_NAME/alembic/env.py"

# ---- alembic/script.py.mako ----
cat > "$PROJECT_NAME/alembic/script.py.mako" << 'MAKO'
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
MAKO

# ---- tests/conftest.py ----
cat > "$PROJECT_NAME/tests/conftest.py" << 'CONFTEST'
import pytest
import pytest_asyncio
from sqlalchemy import create_engine, event
from sqlalchemy.ext.asyncio import AsyncSession, create_async_engine
from sqlalchemy.orm import Session

from APP_PLACEHOLDER.models import Base


@pytest.fixture(scope="session")
def engine():
    engine = create_engine("sqlite:///:memory:")
    Base.metadata.create_all(engine)
    yield engine
    engine.dispose()


@pytest.fixture()
def db_session(engine):
    connection = engine.connect()
    transaction = connection.begin()
    session = Session(bind=connection, join_transaction_block=True)
    yield session
    session.close()
    transaction.rollback()
    connection.close()


@pytest_asyncio.fixture(scope="session")
async def async_engine():
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    yield engine
    await engine.dispose()


@pytest_asyncio.fixture()
async def async_db_session(async_engine):
    async with async_engine.connect() as connection:
        transaction = await connection.begin()
        session = AsyncSession(bind=connection, expire_on_commit=False)
        yield session
        await session.close()
        await transaction.rollback()
CONFTEST

sed -i "s/APP_PLACEHOLDER/$PROJECT_NAME/" "$PROJECT_NAME/tests/conftest.py"

echo ""
echo "✅ Project '$PROJECT_NAME' created with $DB_TYPE support."
echo ""
echo "Next steps:"
echo "  cd $PROJECT_NAME"
echo "  pip install -e '.[dev]'"
echo "  cp .env.example .env   # edit DATABASE_URL"
echo "  alembic revision --autogenerate -m 'initial'"
echo "  alembic upgrade head"
