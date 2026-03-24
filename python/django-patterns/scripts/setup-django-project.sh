#!/usr/bin/env bash
# ==============================================================================
# setup-django-project.sh — Scaffold a production-ready Django project
#
# Usage:
#   ./setup-django-project.sh <project_name> [--no-docker] [--no-venv]
#
# Creates a Django project with:
#   - Split settings (base/dev/prod) using django-environ
#   - Common dependencies (DRF, gunicorn, whitenoise, etc.)
#   - Dockerfile (multi-stage) and docker-compose.yml
#   - .env file with generated SECRET_KEY
#   - .gitignore, pytest config
#
# Examples:
#   ./setup-django-project.sh myproject
#   ./setup-django-project.sh myapi --no-docker
# ==============================================================================

set -euo pipefail

# --- Argument Parsing ---
PROJECT_NAME="${1:-}"
SKIP_DOCKER=false
SKIP_VENV=false

if [[ -z "$PROJECT_NAME" ]]; then
    echo "Usage: $0 <project_name> [--no-docker] [--no-venv]"
    exit 1
fi

shift
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-docker) SKIP_DOCKER=true ;;
        --no-venv)   SKIP_VENV=true ;;
        *)           echo "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

# Validate project name
if [[ ! "$PROJECT_NAME" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
    echo "Error: Invalid project name '$PROJECT_NAME'. Use only letters, digits, and underscores."
    exit 1
fi

echo "🚀 Creating Django project: $PROJECT_NAME"

# --- Create project directory ---
mkdir -p "$PROJECT_NAME"
cd "$PROJECT_NAME"

# --- Virtual environment ---
if [[ "$SKIP_VENV" == false ]]; then
    echo "📦 Creating virtual environment..."
    python3 -m venv .venv
    # shellcheck disable=SC1091
    source .venv/bin/activate
fi

# --- Install dependencies ---
echo "📦 Installing dependencies..."
pip install --quiet --upgrade pip setuptools wheel

cat > requirements/base.txt << 'REQS'
Django>=5.0,<6.0
djangorestframework>=3.14,<4.0
django-environ>=0.11,<1.0
django-filter>=24.0,<25.0
django-cors-headers>=4.3,<5.0
whitenoise>=6.6,<7.0
psycopg[binary]>=3.1,<4.0
gunicorn>=22.0,<23.0
REQS

mkdir -p requirements

cat > requirements/dev.txt << 'REQS'
-r base.txt
django-debug-toolbar>=4.3,<5.0
django-extensions>=3.2,<4.0
pytest>=8.0,<9.0
pytest-django>=4.8,<5.0
pytest-cov>=5.0,<6.0
factory-boy>=3.3,<4.0
ipython>=8.0
ruff>=0.4,<1.0
REQS

cat > requirements/prod.txt << 'REQS'
-r base.txt
dj-database-url>=2.1,<3.0
sentry-sdk[django]>=2.0,<3.0
redis>=5.0,<6.0
REQS

pip install --quiet -r requirements/dev.txt 2>/dev/null || echo "⚠️  Some packages may need manual installation"

# --- Create Django project ---
echo "🏗️  Scaffolding Django project..."
django-admin startproject config .

# --- Generate SECRET_KEY ---
SECRET_KEY=$(python3 -c "from django.core.management.utils import get_random_secret_key; print(get_random_secret_key())" 2>/dev/null || python3 -c "import secrets; print(secrets.token_urlsafe(50))")

# --- .env file ---
cat > .env << ENVFILE
# Django
DJANGO_SETTINGS_MODULE=config.settings.development
DJANGO_SECRET_KEY=${SECRET_KEY}
DJANGO_DEBUG=True
DJANGO_ALLOWED_HOSTS=localhost,127.0.0.1

# Database
DATABASE_URL=postgres://postgres:postgres@localhost:5432/${PROJECT_NAME}

# Redis
REDIS_URL=redis://localhost:6379/0
ENVFILE

cat > .env.example << 'ENVFILE'
# Django
DJANGO_SETTINGS_MODULE=config.settings.production
DJANGO_SECRET_KEY=change-me-to-a-real-secret-key
DJANGO_DEBUG=False
DJANGO_ALLOWED_HOSTS=yourdomain.com,www.yourdomain.com

# Database
DATABASE_URL=postgres://user:password@db:5432/dbname

# Redis
REDIS_URL=redis://redis:6379/0
ENVFILE

# --- Split settings ---
echo "⚙️  Creating split settings..."
mkdir -p config/settings

cat > config/settings/__init__.py << 'SETTINGS'
SETTINGS

cat > config/settings/base.py << 'SETTINGS'
"""Base settings shared across all environments."""
import environ
from pathlib import Path

env = environ.Env(
    DJANGO_DEBUG=(bool, False),
    DJANGO_ALLOWED_HOSTS=(list, []),
)

BASE_DIR = Path(__file__).resolve().parent.parent.parent
environ.Env.read_env(BASE_DIR / ".env")

SECRET_KEY = env("DJANGO_SECRET_KEY")
DEBUG = env("DJANGO_DEBUG")
ALLOWED_HOSTS = env("DJANGO_ALLOWED_HOSTS")

INSTALLED_APPS = [
    "django.contrib.admin",
    "django.contrib.auth",
    "django.contrib.contenttypes",
    "django.contrib.sessions",
    "django.contrib.messages",
    "django.contrib.staticfiles",
    # Third party
    "rest_framework",
    "django_filters",
    "corsheaders",
    # Local apps
    # "apps.core",
    # "apps.users",
]

MIDDLEWARE = [
    "django.middleware.security.SecurityMiddleware",
    "corsheaders.middleware.CorsMiddleware",
    "django.contrib.sessions.middleware.SessionMiddleware",
    "django.middleware.common.CommonMiddleware",
    "django.middleware.csrf.CsrfViewMiddleware",
    "django.contrib.auth.middleware.AuthenticationMiddleware",
    "django.contrib.messages.middleware.MessageMiddleware",
    "django.middleware.clickjacking.XFrameOptionsMiddleware",
]

ROOT_URLCONF = "config.urls"

TEMPLATES = [
    {
        "BACKEND": "django.template.backends.django.DjangoTemplates",
        "DIRS": [BASE_DIR / "templates"],
        "APP_DIRS": True,
        "OPTIONS": {
            "context_processors": [
                "django.template.context_processors.debug",
                "django.template.context_processors.request",
                "django.contrib.auth.context_processors.auth",
                "django.contrib.messages.context_processors.messages",
            ],
        },
    },
]

WSGI_APPLICATION = "config.wsgi.application"

DATABASES = {"default": env.db("DATABASE_URL", default="sqlite:///db.sqlite3")}
DATABASES["default"]["CONN_MAX_AGE"] = 600
DATABASES["default"]["CONN_HEALTH_CHECKS"] = True

DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"

# Auth
# AUTH_USER_MODEL = "users.User"

# Internationalization
LANGUAGE_CODE = "en-us"
TIME_ZONE = "UTC"
USE_I18N = True
USE_TZ = True

# Static files
STATIC_URL = "static/"
STATIC_ROOT = BASE_DIR / "staticfiles"
STATICFILES_DIRS = [BASE_DIR / "static"]

# Media files
MEDIA_URL = "media/"
MEDIA_ROOT = BASE_DIR / "media"

# DRF
REST_FRAMEWORK = {
    "DEFAULT_PAGINATION_CLASS": "rest_framework.pagination.PageNumberPagination",
    "PAGE_SIZE": 25,
    "DEFAULT_AUTHENTICATION_CLASSES": [
        "rest_framework.authentication.SessionAuthentication",
    ],
    "DEFAULT_PERMISSION_CLASSES": [
        "rest_framework.permissions.IsAuthenticated",
    ],
    "DEFAULT_FILTER_BACKENDS": [
        "django_filters.rest_framework.DjangoFilterBackend",
        "rest_framework.filters.SearchFilter",
        "rest_framework.filters.OrderingFilter",
    ],
}

# Logging
LOGGING = {
    "version": 1,
    "disable_existing_loggers": False,
    "formatters": {
        "verbose": {
            "format": "{levelname} {asctime} {module} {message}",
            "style": "{",
        },
    },
    "handlers": {
        "console": {
            "class": "logging.StreamHandler",
            "formatter": "verbose",
        },
    },
    "root": {
        "handlers": ["console"],
        "level": "INFO",
    },
    "loggers": {
        "django": {
            "handlers": ["console"],
            "level": env("DJANGO_LOG_LEVEL", default="INFO"),
            "propagate": False,
        },
    },
}
SETTINGS

cat > config/settings/development.py << 'SETTINGS'
"""Development settings."""
from .base import *  # noqa: F401,F403
from .base import INSTALLED_APPS, MIDDLEWARE

DEBUG = True

INSTALLED_APPS += [
    "debug_toolbar",
    "django_extensions",
]

MIDDLEWARE.insert(0, "debug_toolbar.middleware.DebugToolbarMiddleware")

INTERNAL_IPS = ["127.0.0.1"]

CORS_ALLOW_ALL_ORIGINS = True

# Use console email backend in development
EMAIL_BACKEND = "django.core.mail.backends.console.EmailBackend"

# Weaker password validation for dev
AUTH_PASSWORD_VALIDATORS = []
SETTINGS

cat > config/settings/production.py << 'SETTINGS'
"""Production settings — all security hardening enabled."""
from .base import *  # noqa: F401,F403
from .base import MIDDLEWARE, env

DEBUG = False

# Security
SECURE_HSTS_SECONDS = 31536000
SECURE_HSTS_INCLUDE_SUBDOMAINS = True
SECURE_HSTS_PRELOAD = True
SECURE_SSL_REDIRECT = True
SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")
SESSION_COOKIE_SECURE = True
CSRF_COOKIE_SECURE = True
SECURE_CONTENT_TYPE_NOSNIFF = True
SECURE_BROWSER_XSS_FILTER = True
X_FRAME_OPTIONS = "DENY"

# WhiteNoise for static files
MIDDLEWARE.insert(1, "whitenoise.middleware.WhiteNoiseMiddleware")
STORAGES = {
    "staticfiles": {
        "BACKEND": "whitenoise.storage.CompressedManifestStaticFilesStorage",
    },
}

# Cache
CACHES = {
    "default": {
        "BACKEND": "django.core.cache.backends.redis.RedisCache",
        "LOCATION": env("REDIS_URL", default="redis://localhost:6379/0"),
    }
}

# Email
EMAIL_BACKEND = "django.core.mail.backends.smtp.EmailBackend"

# CORS
CORS_ALLOWED_ORIGINS = env.list("CORS_ALLOWED_ORIGINS", default=[])
SETTINGS

# --- Remove old settings.py, update wsgi/asgi ---
rm -f config/settings.py

sed -i "s/config.settings/config.settings.production/g" config/wsgi.py config/asgi.py

# --- Create app directories ---
mkdir -p apps templates static media

cat > apps/__init__.py << 'EOF'
EOF

# --- pytest configuration ---
cat > pytest.ini << 'PYTEST'
[pytest]
DJANGO_SETTINGS_MODULE = config.settings.development
python_files = tests.py test_*.py *_tests.py
python_classes = Test*
python_functions = test_*
addopts = --reuse-db --no-migrations -q
PYTEST

cat > conftest.py << 'CONFTEST'
import pytest
from rest_framework.test import APIClient


@pytest.fixture
def api_client():
    return APIClient()


@pytest.fixture
def user(db, django_user_model):
    return django_user_model.objects.create_user(
        username="testuser",
        email="test@example.com",
        password="testpass123",
    )


@pytest.fixture
def authenticated_client(api_client, user):
    api_client.force_authenticate(user=user)
    return api_client
CONFTEST

# --- .gitignore ---
cat > .gitignore << 'GITIGNORE'
# Python
__pycache__/
*.py[cod]
*.egg-info/
dist/
build/
.eggs/

# Virtual environment
.venv/
venv/

# Django
*.sqlite3
staticfiles/
media/
*.log

# Environment
.env
.env.local

# IDE
.vscode/
.idea/
*.swp
*.swo

# OS
.DS_Store
Thumbs.db

# Coverage
htmlcov/
.coverage
.coverage.*
GITIGNORE

# --- Docker ---
if [[ "$SKIP_DOCKER" == false ]]; then
    echo "🐳 Creating Docker files..."

    cat > Dockerfile << 'DOCKERFILE'
# Multi-stage Dockerfile for Django
FROM python:3.12-slim AS base

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

# Install system dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends gcc libpq-dev && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Install Python dependencies
COPY requirements/base.txt requirements/prod.txt requirements/
RUN pip install --no-cache-dir -r requirements/prod.txt

# --- Production stage ---
FROM base AS production

COPY . .
RUN python manage.py collectstatic --noinput 2>/dev/null || true

EXPOSE 8000

CMD ["gunicorn", "config.wsgi:application", "--bind", "0.0.0.0:8000", "--workers", "4", "--threads", "2"]
DOCKERFILE

    cat > docker-compose.yml << COMPOSE
services:
  web:
    build: .
    ports:
      - "8000:8000"
    env_file: .env
    environment:
      - DJANGO_SETTINGS_MODULE=config.settings.development
      - DATABASE_URL=postgres://postgres:postgres@db:5432/${PROJECT_NAME}
      - REDIS_URL=redis://redis:6379/0
    volumes:
      - .:/app
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_started
    command: python manage.py runserver 0.0.0.0:8000

  db:
    image: postgres:16-alpine
    environment:
      POSTGRES_DB: ${PROJECT_NAME}
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
    ports:
      - "5432:5432"
    volumes:
      - postgres_data:/var/lib/postgresql/data
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
  postgres_data:
COMPOSE

    cat > .dockerignore << 'DOCKERIGNORE'
.venv
.git
__pycache__
*.pyc
.env
.env.local
media/
staticfiles/
.DS_Store
DOCKERIGNORE
fi

# --- Gunicorn config ---
cat > gunicorn.conf.py << 'GUNICORN'
import multiprocessing

bind = "0.0.0.0:8000"
workers = multiprocessing.cpu_count() * 2 + 1
worker_class = "gthread"
threads = 4
timeout = 30
graceful_timeout = 30
keepalive = 5
max_requests = 1000
max_requests_jitter = 50
accesslog = "-"
errorlog = "-"
loglevel = "info"
GUNICORN

# --- Summary ---
echo ""
echo "✅ Project '$PROJECT_NAME' created successfully!"
echo ""
echo "📁 Structure:"
echo "  $PROJECT_NAME/"
echo "  ├── apps/                  # Your Django apps"
echo "  ├── config/settings/       # Split settings (base/dev/prod)"
echo "  ├── requirements/          # Dependency files"
echo "  ├── templates/"
echo "  ├── static/"
echo "  ├── .env                   # Environment variables"
echo "  ├── Dockerfile"
echo "  ├── docker-compose.yml"
echo "  └── gunicorn.conf.py"
echo ""
echo "🚀 Next steps:"
echo "  cd $PROJECT_NAME"
if [[ "$SKIP_VENV" == false ]]; then
    echo "  source .venv/bin/activate"
fi
echo "  python manage.py migrate"
echo "  python manage.py createsuperuser"
echo "  python manage.py runserver"
echo ""
echo "  # Or with Docker:"
echo "  docker compose up --build"
