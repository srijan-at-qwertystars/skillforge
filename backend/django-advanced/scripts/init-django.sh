#!/usr/bin/env bash
# ==============================================================================
# init-django.sh — Scaffold a Django project with best-practice structure
#
# Usage:
#   ./init-django.sh <project_name> [--with-drf] [--with-celery] [--with-docker]
#
# Creates:
#   <project_name>/
#   ├── config/                    # Project configuration (settings, urls, wsgi, asgi)
#   │   ├── settings/
#   │   │   ├── __init__.py
#   │   │   ├── base.py           # Shared settings
#   │   │   ├── dev.py            # Development overrides
#   │   │   └── prod.py           # Production overrides
#   │   ├── urls.py
#   │   ├── wsgi.py
#   │   └── asgi.py
#   ├── apps/                     # Django apps directory
#   ├── static/                   # Project-level static files
#   ├── templates/                # Project-level templates
#   ├── requirements/
#   │   ├── base.txt
#   │   ├── dev.txt
#   │   └── prod.txt
#   ├── .env.example
#   ├── .gitignore
#   ├── manage.py
#   └── pytest.ini
#
# Requirements: Python 3.10+, pip
# ==============================================================================

set -euo pipefail

# --- Argument parsing ---
PROJECT_NAME="${1:-}"
WITH_DRF=false
WITH_CELERY=false
WITH_DOCKER=false

if [[ -z "$PROJECT_NAME" ]]; then
    echo "Usage: $0 <project_name> [--with-drf] [--with-celery] [--with-docker]"
    exit 1
fi

shift
for arg in "$@"; do
    case "$arg" in
        --with-drf)    WITH_DRF=true ;;
        --with-celery) WITH_CELERY=true ;;
        --with-docker) WITH_DOCKER=true ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done

echo "🚀 Creating Django project: $PROJECT_NAME"

# --- Create virtual environment ---
if [[ ! -d ".venv" ]]; then
    echo "📦 Creating virtual environment..."
    python3 -m venv .venv
fi
# shellcheck disable=SC1091
source .venv/bin/activate

# --- Install Django ---
pip install --quiet --upgrade pip
pip install --quiet django

# --- Create project directory ---
mkdir -p "$PROJECT_NAME"
cd "$PROJECT_NAME"

# --- Django startproject with 'config' as project package ---
django-admin startproject config .

# --- Restructure settings into split configuration ---
mkdir -p config/settings
mv config/settings.py config/settings/base.py

# config/settings/__init__.py — auto-select settings module
cat > config/settings/__init__.py << 'PYEOF'
import os
env = os.environ.get("DJANGO_ENV", "dev")
if env == "production":
    from .prod import *  # noqa: F401,F403
else:
    from .dev import *   # noqa: F401,F403
PYEOF

# Patch base.py: replace hardcoded SECRET_KEY and DEBUG
python3 << 'PYSCRIPT'
import re

with open("config/settings/base.py", "r") as f:
    content = f.read()

# Replace SECRET_KEY line
content = re.sub(
    r"SECRET_KEY = .*",
    'SECRET_KEY = os.environ.get("DJANGO_SECRET_KEY", "change-me-in-production")',
    content,
)

# Replace DEBUG line
content = re.sub(
    r"DEBUG = .*",
    'DEBUG = os.environ.get("DJANGO_DEBUG", "True").lower() in ("true", "1", "yes")',
    content,
)

# Add os import if not present
if "import os" not in content:
    content = "import os\n" + content

# Replace ALLOWED_HOSTS
content = re.sub(
    r"ALLOWED_HOSTS = \[\]",
    'ALLOWED_HOSTS = os.environ.get("DJANGO_ALLOWED_HOSTS", "localhost,127.0.0.1").split(",")',
    content,
)

# Add AUTH_USER_MODEL placeholder
content += """

# Custom user model (uncomment and create before first migrate)
# AUTH_USER_MODEL = "accounts.CustomUser"

# Default primary key type
DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"
"""

with open("config/settings/base.py", "w") as f:
    f.write(content)
PYSCRIPT

# config/settings/dev.py
cat > config/settings/dev.py << 'PYEOF'
"""Development settings."""
from .base import *  # noqa: F401,F403

DEBUG = True
ALLOWED_HOSTS = ["*"]

# Debug toolbar
# INSTALLED_APPS += ["debug_toolbar"]
# MIDDLEWARE.insert(0, "debug_toolbar.middleware.DebugToolbarMiddleware")
# INTERNAL_IPS = ["127.0.0.1"]

# Use SQLite for development (override for PostgreSQL as needed)
DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.sqlite3",
        "NAME": BASE_DIR / "db.sqlite3",
    }
}

# Email to console
EMAIL_BACKEND = "django.core.mail.backends.console.EmailBackend"

# Disable caching in dev
CACHES = {
    "default": {
        "BACKEND": "django.core.cache.backends.locmem.LocMemCache",
    }
}
PYEOF

# config/settings/prod.py
cat > config/settings/prod.py << 'PYEOF'
"""Production settings — all secrets via environment variables."""
import os
from .base import *  # noqa: F401,F403

DEBUG = False
SECRET_KEY = os.environ["DJANGO_SECRET_KEY"]
ALLOWED_HOSTS = os.environ.get("DJANGO_ALLOWED_HOSTS", "").split(",")
CSRF_TRUSTED_ORIGINS = os.environ.get("DJANGO_CSRF_ORIGINS", "").split(",")

# PostgreSQL
DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.postgresql",
        "NAME": os.environ["DB_NAME"],
        "USER": os.environ["DB_USER"],
        "PASSWORD": os.environ["DB_PASSWORD"],
        "HOST": os.environ.get("DB_HOST", "localhost"),
        "PORT": os.environ.get("DB_PORT", "5432"),
        "CONN_MAX_AGE": 600,
        "CONN_HEALTH_CHECKS": True,
    }
}

# Security
SECURE_SSL_REDIRECT = True
SECURE_HSTS_SECONDS = 63072000
SECURE_HSTS_INCLUDE_SUBDOMAINS = True
SECURE_HSTS_PRELOAD = True
SESSION_COOKIE_SECURE = True
CSRF_COOKIE_SECURE = True
SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")
SECURE_CONTENT_TYPE_NOSNIFF = True
X_FRAME_OPTIONS = "DENY"

# Static files (WhiteNoise)
MIDDLEWARE.insert(1, "whitenoise.middleware.WhiteNoiseMiddleware")
STORAGES = {
    "staticfiles": {
        "BACKEND": "whitenoise.storage.CompressedManifestStaticFilesStorage",
    },
}
STATIC_ROOT = BASE_DIR / "staticfiles"

# Redis cache
CACHES = {
    "default": {
        "BACKEND": "django.core.cache.backends.redis.RedisCache",
        "LOCATION": os.environ.get("REDIS_URL", "redis://127.0.0.1:6379/1"),
    }
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
    "root": {"handlers": ["console"], "level": "WARNING"},
    "loggers": {
        "django": {"handlers": ["console"], "level": "WARNING"},
    },
}
PYEOF

# --- Create directory structure ---
mkdir -p apps static templates requirements

# --- Requirements files ---
cat > requirements/base.txt << 'EOF'
Django>=5.0,<6.0
psycopg[binary]>=3.1
whitenoise>=6.5
django-environ>=0.11
EOF

cat > requirements/dev.txt << 'EOF'
-r base.txt
django-debug-toolbar>=4.2
pytest>=8.0
pytest-django>=4.7
pytest-cov>=4.1
factory-boy>=3.3
ipython>=8.0
EOF

cat > requirements/prod.txt << 'EOF'
-r base.txt
gunicorn>=21.2
uvicorn[standard]>=0.27
EOF

# --- DRF support ---
if $WITH_DRF; then
    echo "djangorestframework>=3.15" >> requirements/base.txt
    echo "django-filter>=23.5" >> requirements/base.txt
    echo "drf-spectacular>=0.27" >> requirements/base.txt
fi

# --- Celery support ---
if $WITH_CELERY; then
    echo "celery[redis]>=5.3" >> requirements/base.txt
    echo "django-celery-beat>=2.5" >> requirements/base.txt

    cat > config/celery.py << 'PYEOF'
import os
from celery import Celery

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "config.settings")
app = Celery("config")
app.config_from_object("django.conf:settings", namespace="CELERY")
app.autodiscover_tasks()
PYEOF

    cat > config/__init__.py << 'PYEOF'
from .celery import app as celery_app

__all__ = ("celery_app",)
PYEOF
fi

# --- .env.example ---
cat > .env.example << 'EOF'
DJANGO_ENV=dev
DJANGO_SECRET_KEY=change-me-to-a-random-50-char-string
DJANGO_DEBUG=True
DJANGO_ALLOWED_HOSTS=localhost,127.0.0.1
DJANGO_CSRF_ORIGINS=http://localhost:8000

DB_NAME=mydb
DB_USER=myuser
DB_PASSWORD=mypassword
DB_HOST=localhost
DB_PORT=5432

REDIS_URL=redis://127.0.0.1:6379/1

CELERY_BROKER_URL=redis://127.0.0.1:6379/0
EOF

# --- .gitignore ---
cat > .gitignore << 'EOF'
__pycache__/
*.py[cod]
*.so
.venv/
venv/
.env
db.sqlite3
*.log
staticfiles/
media/
.coverage
htmlcov/
dist/
*.egg-info/
.mypy_cache/
.pytest_cache/
node_modules/
EOF

# --- pytest.ini ---
cat > pytest.ini << 'EOF'
[pytest]
DJANGO_SETTINGS_MODULE = config.settings
python_files = tests.py test_*.py *_tests.py
addopts = --reuse-db --no-migrations -q
EOF

# --- Docker support ---
if $WITH_DOCKER; then
    cat > Dockerfile << 'DOCKERFILE'
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq-dev && rm -rf /var/lib/apt/lists/*

COPY requirements/ requirements/
RUN pip install --no-cache-dir -r requirements/prod.txt

COPY . .
RUN python manage.py collectstatic --noinput 2>/dev/null || true

EXPOSE 8000
CMD ["gunicorn", "config.wsgi:application", "--bind", "0.0.0.0:8000", "--workers", "3"]
DOCKERFILE

    cat > docker-compose.yml << 'YAMLEOF'
services:
  web:
    build: .
    env_file: .env
    ports:
      - "8000:8000"
    depends_on:
      - db
      - redis
    volumes:
      - static:/app/staticfiles
      - media:/app/media

  db:
    image: postgres:16-alpine
    environment:
      POSTGRES_DB: ${DB_NAME:-mydb}
      POSTGRES_USER: ${DB_USER:-myuser}
      POSTGRES_PASSWORD: ${DB_PASSWORD:-mypassword}
    volumes:
      - pgdata:/var/lib/postgresql/data
    ports:
      - "5432:5432"

  redis:
    image: redis:7-alpine
    ports:
      - "6379:6379"

volumes:
  static:
  media:
  pgdata:
YAMLEOF
fi

echo ""
echo "✅ Project '$PROJECT_NAME' created successfully!"
echo ""
echo "Next steps:"
echo "  cd $PROJECT_NAME"
echo "  source ../.venv/bin/activate"
echo "  pip install -r requirements/dev.txt"
echo "  cp .env.example .env"
echo "  python manage.py migrate"
echo "  python manage.py createsuperuser"
echo "  python manage.py runserver"
