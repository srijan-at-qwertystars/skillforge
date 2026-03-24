# Multi-stage Django Dockerfile
# - Uses slim Python base for smaller images
# - Proper layer caching: dependencies before source code
# - Non-root user for security
#
# Build:
#   docker build -t myapp .
#   docker build --target development -t myapp:dev .
#
# Run:
#   docker run -p 8000:8000 --env-file .env myapp

# =============================================================================
# Stage 1: Base — system deps + Python packages
# =============================================================================
FROM python:3.12-slim AS base

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

# System dependencies (cached unless Dockerfile changes)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        gcc \
        libpq-dev \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Python dependencies (cached unless requirements change)
COPY requirements/ requirements/
RUN pip install -r requirements/base.txt

# =============================================================================
# Stage 2: Development — includes dev dependencies and runs with source mount
# =============================================================================
FROM base AS development

RUN pip install -r requirements/dev.txt

# Create non-root user
RUN addgroup --system django && adduser --system --ingroup django django
USER django

EXPOSE 8000

CMD ["python", "manage.py", "runserver", "0.0.0.0:8000"]

# =============================================================================
# Stage 3: Production — optimized, non-root, static files collected
# =============================================================================
FROM base AS production

RUN pip install -r requirements/prod.txt

# Copy source code (after deps for caching)
COPY . .

# Collect static files
RUN DJANGO_SECRET_KEY=build-placeholder \
    DJANGO_SETTINGS_MODULE=config.settings.production \
    python manage.py collectstatic --noinput 2>/dev/null || true

# Create non-root user
RUN addgroup --system django && \
    adduser --system --ingroup django django && \
    chown -R django:django /app

USER django

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/health/')" || exit 1

CMD ["gunicorn", "config.wsgi:application", \
     "--bind", "0.0.0.0:8000", \
     "--workers", "4", \
     "--threads", "2", \
     "--timeout", "30", \
     "--max-requests", "1000", \
     "--max-requests-jitter", "50", \
     "--access-logfile", "-", \
     "--error-logfile", "-"]
