#!/usr/bin/env bash
# fastapi-init.sh — Scaffold a FastAPI project with production-ready structure
#
# Usage: ./fastapi-init.sh <project-name>
# Example: ./fastapi-init.sh my-api
#
# Creates:
#   <project-name>/
#   ├── app/
#   │   ├── __init__.py
#   │   ├── main.py
#   │   ├── core/
#   │   │   ├── __init__.py
#   │   │   ├── config.py
#   │   │   ├── database.py
#   │   │   └── security.py
#   │   ├── models/
#   │   ├── schemas/
#   │   ├── routers/
#   │   ├── services/
#   │   └── dependencies.py
#   ├── tests/
#   │   ├── __init__.py
#   │   └── conftest.py
#   ├── alembic/
#   ├── pyproject.toml
#   ├── Dockerfile
#   ├── docker-compose.yml
#   ├── .env.example
#   └── .gitignore

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <project-name>"
    echo "Example: $0 my-api"
    exit 1
fi

PROJECT="$1"
# Convert dashes to underscores for Python package name
PKG_NAME="${PROJECT//-/_}"

if [ -d "$PROJECT" ]; then
    echo "Error: Directory '$PROJECT' already exists."
    exit 1
fi

echo "🚀 Creating FastAPI project: $PROJECT"

# Create directory structure
mkdir -p "$PROJECT"/{app/{core,models,schemas,routers,services},tests,alembic/versions}

# --- app/__init__.py ---
cat > "$PROJECT/app/__init__.py" << 'EOF'
EOF

# --- app/main.py ---
cat > "$PROJECT/app/main.py" << 'PYEOF'
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.core.config import settings
from app.core.database import engine
from app.routers import health


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Startup
    yield
    # Shutdown
    await engine.dispose()


app = FastAPI(
    title=settings.project_name,
    version="0.1.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.allowed_origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(health.router)
PYEOF

# --- app/core/__init__.py ---
touch "$PROJECT/app/core/__init__.py"

# --- app/core/config.py ---
cat > "$PROJECT/app/core/config.py" << 'PYEOF'
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env", env_file_encoding="utf-8", extra="ignore"
    )

    project_name: str = "FastAPI App"
    debug: bool = False
    database_url: str = "postgresql+asyncpg://postgres:postgres@localhost:5432/app"
    secret_key: str = "change-me-in-production"
    access_token_expire_minutes: int = 30
    allowed_origins: list[str] = ["http://localhost:3000"]
    redis_url: str = "redis://localhost:6379/0"


settings = Settings()
PYEOF

# --- app/core/database.py ---
cat > "$PROJECT/app/core/database.py" << 'PYEOF'
from collections.abc import AsyncGenerator

from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.orm import DeclarativeBase

from app.core.config import settings

engine = create_async_engine(
    settings.database_url,
    pool_size=10,
    max_overflow=20,
    pool_pre_ping=True,
    echo=settings.debug,
)

SessionLocal = async_sessionmaker(
    bind=engine,
    class_=AsyncSession,
    expire_on_commit=False,
)


class Base(DeclarativeBase):
    pass


async def get_db() -> AsyncGenerator[AsyncSession, None]:
    async with SessionLocal() as session:
        try:
            yield session
            await session.commit()
        except Exception:
            await session.rollback()
            raise
PYEOF

# --- app/core/security.py ---
cat > "$PROJECT/app/core/security.py" << 'PYEOF'
from datetime import datetime, timedelta

from jose import JWTError, jwt
from passlib.context import CryptContext

from app.core.config import settings

pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")
ALGORITHM = "HS256"


def hash_password(password: str) -> str:
    return pwd_context.hash(password)


def verify_password(plain: str, hashed: str) -> bool:
    return pwd_context.verify(plain, hashed)


def create_access_token(subject: str, expires_delta: timedelta | None = None) -> str:
    expire = datetime.utcnow() + (
        expires_delta or timedelta(minutes=settings.access_token_expire_minutes)
    )
    return jwt.encode({"sub": subject, "exp": expire}, settings.secret_key, algorithm=ALGORITHM)


def decode_access_token(token: str) -> str | None:
    try:
        payload = jwt.decode(token, settings.secret_key, algorithms=[ALGORITHM])
        return payload.get("sub")
    except JWTError:
        return None
PYEOF

# --- app/dependencies.py ---
cat > "$PROJECT/app/dependencies.py" << 'PYEOF'
from fastapi import Depends, HTTPException, status
from fastapi.security import OAuth2PasswordBearer
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_db
from app.core.security import decode_access_token

oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/auth/token")


async def get_current_user(
    token: str = Depends(oauth2_scheme),
    db: AsyncSession = Depends(get_db),
):
    user_id = decode_access_token(token)
    if not user_id:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or expired token",
            headers={"WWW-Authenticate": "Bearer"},
        )
    # Replace with actual user lookup
    # user = await db.get(User, int(user_id))
    # if not user:
    #     raise HTTPException(status_code=401, detail="User not found")
    # return user
    return {"id": user_id}
PYEOF

# --- app/models/__init__.py ---
touch "$PROJECT/app/models/__init__.py"

# --- app/schemas/__init__.py ---
touch "$PROJECT/app/schemas/__init__.py"

# --- app/routers/__init__.py ---
touch "$PROJECT/app/routers/__init__.py"

# --- app/routers/health.py ---
cat > "$PROJECT/app/routers/health.py" << 'PYEOF'
from fastapi import APIRouter

router = APIRouter(tags=["health"])


@router.get("/health", include_in_schema=False)
async def health_check():
    return {"status": "ok"}
PYEOF

# --- app/services/__init__.py ---
touch "$PROJECT/app/services/__init__.py"

# --- tests/__init__.py ---
touch "$PROJECT/tests/__init__.py"

# --- tests/conftest.py ---
cat > "$PROJECT/tests/conftest.py" << 'PYEOF'
import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from app.core.database import Base, get_db
from app.main import app

TEST_DB_URL = "sqlite+aiosqlite:///./test.db"

test_engine = create_async_engine(TEST_DB_URL, connect_args={"check_same_thread": False})
TestSession = async_sessionmaker(bind=test_engine, class_=AsyncSession, expire_on_commit=False)


@pytest.fixture(scope="session", autouse=True)
async def setup_db():
    async with test_engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    yield
    async with test_engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)
    await test_engine.dispose()


@pytest.fixture
async def db_session():
    async with TestSession() as session:
        yield session
        await session.rollback()


@pytest.fixture
async def client(db_session):
    async def override():
        yield db_session

    app.dependency_overrides[get_db] = override
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
        yield c
    app.dependency_overrides.clear()
PYEOF

# --- alembic/env.py ---
cat > "$PROJECT/alembic/env.py" << 'PYEOF'
import asyncio
from logging.config import fileConfig

from alembic import context
from sqlalchemy.ext.asyncio import create_async_engine

from app.core.config import settings
from app.core.database import Base

config = context.config
if config.config_file_name is not None:
    fileConfig(config.config_file_name)

target_metadata = Base.metadata


def run_migrations_offline():
    context.configure(url=settings.database_url, target_metadata=target_metadata, literal_binds=True)
    with context.begin_transaction():
        context.run_migrations()


def do_run_migrations(connection):
    context.configure(connection=connection, target_metadata=target_metadata)
    with context.begin_transaction():
        context.run_migrations()


async def run_migrations_online():
    engine = create_async_engine(settings.database_url)
    async with engine.connect() as connection:
        await connection.run_sync(do_run_migrations)
    await engine.dispose()


if context.is_offline_mode():
    run_migrations_offline()
else:
    asyncio.run(run_migrations_online())
PYEOF

# --- alembic.ini ---
cat > "$PROJECT/alembic.ini" << 'EOF'
[alembic]
script_location = alembic
sqlalchemy.url = driver://user:pass@localhost/dbname

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
EOF

# --- pyproject.toml ---
cat > "$PROJECT/pyproject.toml" << EOF
[project]
name = "$PKG_NAME"
version = "0.1.0"
description = "FastAPI application"
requires-python = ">=3.11"
dependencies = [
    "fastapi>=0.115.0",
    "uvicorn[standard]>=0.30.0",
    "pydantic-settings>=2.0.0",
    "sqlalchemy[asyncio]>=2.0.0",
    "asyncpg>=0.29.0",
    "alembic>=1.13.0",
    "python-jose[cryptography]>=3.3.0",
    "passlib[bcrypt]>=1.7.4",
    "python-multipart>=0.0.9",
    "httpx>=0.27.0",
]

[project.optional-dependencies]
dev = [
    "pytest>=8.0.0",
    "pytest-asyncio>=0.23.0",
    "pytest-cov>=5.0.0",
    "aiosqlite>=0.20.0",
    "ruff>=0.5.0",
    "mypy>=1.10.0",
]

[tool.pytest.ini_options]
asyncio_mode = "auto"
testpaths = ["tests"]

[tool.ruff]
target-version = "py311"
line-length = 100

[tool.ruff.lint]
select = ["E", "F", "I", "N", "W", "UP"]
EOF

# --- Dockerfile ---
cat > "$PROJECT/Dockerfile" << 'DEOF'
# Stage 1: Builder
FROM python:3.12-slim AS builder
WORKDIR /build
COPY pyproject.toml .
RUN pip install --no-cache-dir --prefix=/install .

# Stage 2: Runtime
FROM python:3.12-slim
WORKDIR /app
COPY --from=builder /install /usr/local
COPY . .
EXPOSE 8000
CMD ["gunicorn", "app.main:app", "-k", "uvicorn.workers.UvicornWorker", "-w", "4", "--bind", "0.0.0.0:8000"]
DEOF

# --- docker-compose.yml ---
cat > "$PROJECT/docker-compose.yml" << 'YEOF'
services:
  app:
    build: .
    ports:
      - "8000:8000"
    env_file: .env
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_started
    volumes:
      - ./app:/app/app
    command: uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload

  db:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: app
    ports:
      - "5432:5432"
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    ports:
      - "6379:6379"

volumes:
  pgdata:
YEOF

# --- .env.example ---
cat > "$PROJECT/.env.example" << 'EOF'
PROJECT_NAME=FastAPI App
DEBUG=true
DATABASE_URL=postgresql+asyncpg://postgres:postgres@localhost:5432/app
SECRET_KEY=change-me-in-production
ALLOWED_ORIGINS=["http://localhost:3000"]
REDIS_URL=redis://localhost:6379/0
EOF

# --- .gitignore ---
cat > "$PROJECT/.gitignore" << 'EOF'
__pycache__/
*.py[cod]
.env
*.db
.venv/
dist/
*.egg-info/
.ruff_cache/
.mypy_cache/
.pytest_cache/
htmlcov/
.coverage
EOF

echo ""
echo "✅ Project '$PROJECT' created successfully!"
echo ""
echo "Next steps:"
echo "  cd $PROJECT"
echo "  python -m venv .venv && source .venv/bin/activate"
echo "  pip install -e '.[dev]'"
echo "  cp .env.example .env"
echo "  docker compose up -d db redis"
echo "  uvicorn app.main:app --reload"
