#!/usr/bin/env bash
# =============================================================================
# setup-celery-project.sh — Scaffold a Celery project with standard structure
#
# Usage:
#   ./setup-celery-project.sh <project_name> [--broker redis|rabbitmq] [--django]
#
# Examples:
#   ./setup-celery-project.sh myproject
#   ./setup-celery-project.sh myproject --broker rabbitmq
#   ./setup-celery-project.sh myproject --django
#
# Creates:
#   <project_name>/
#   ├── <project_name>/
#   │   ├── __init__.py
#   │   ├── celery.py        # Celery app instance
#   │   ├── celeryconfig.py  # Configuration
#   │   └── tasks.py         # Example tasks
#   ├── requirements.txt
#   ├── Dockerfile
#   └── docker-compose.yml
# =============================================================================
set -euo pipefail

PROJECT_NAME="${1:-}"
BROKER="redis"
DJANGO=false

if [[ -z "$PROJECT_NAME" ]]; then
    echo "Usage: $0 <project_name> [--broker redis|rabbitmq] [--django]"
    exit 1
fi

# Parse optional args
shift
while [[ $# -gt 0 ]]; do
    case "$1" in
        --broker)
            BROKER="${2:-redis}"
            shift 2
            ;;
        --django)
            DJANGO=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

echo "Scaffolding Celery project: $PROJECT_NAME (broker: $BROKER, django: $DJANGO)"

# Create directory structure
mkdir -p "$PROJECT_NAME/$PROJECT_NAME"

# --- requirements.txt ---
cat > "$PROJECT_NAME/requirements.txt" <<EOF
celery[redis]>=5.3,<6.0
flower>=2.0
EOF

if [[ "$BROKER" == "rabbitmq" ]]; then
    echo "amqp>=5.1" >> "$PROJECT_NAME/requirements.txt"
fi

if [[ "$DJANGO" == true ]]; then
    cat >> "$PROJECT_NAME/requirements.txt" <<EOF
django>=4.2
django-celery-beat>=2.5
django-celery-results>=2.5
EOF
fi

# --- Broker URL ---
if [[ "$BROKER" == "rabbitmq" ]]; then
    BROKER_URL="amqp://guest:guest@localhost:5672//"
    RESULT_BACKEND="rpc://"
else
    BROKER_URL="redis://localhost:6379/0"
    RESULT_BACKEND="redis://localhost:6379/1"
fi

# --- __init__.py ---
if [[ "$DJANGO" == true ]]; then
    cat > "$PROJECT_NAME/$PROJECT_NAME/__init__.py" <<EOF
from .celery import app as celery_app

__all__ = ("celery_app",)
EOF
else
    cat > "$PROJECT_NAME/$PROJECT_NAME/__init__.py" <<EOF
EOF
fi

# --- celery.py ---
if [[ "$DJANGO" == true ]]; then
    cat > "$PROJECT_NAME/$PROJECT_NAME/celery.py" <<PYEOF
import os
from celery import Celery

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "${PROJECT_NAME}.settings")

app = Celery("${PROJECT_NAME}")
app.config_from_object("django.conf:settings", namespace="CELERY")
app.autodiscover_tasks()
PYEOF
else
    cat > "$PROJECT_NAME/$PROJECT_NAME/celery.py" <<PYEOF
from celery import Celery

app = Celery("${PROJECT_NAME}")
app.config_from_object("${PROJECT_NAME}.celeryconfig")
app.autodiscover_tasks(["${PROJECT_NAME}.tasks"])

if __name__ == "__main__":
    app.start()
PYEOF
fi

# --- celeryconfig.py ---
cat > "$PROJECT_NAME/$PROJECT_NAME/celeryconfig.py" <<PYEOF
"""Celery configuration for ${PROJECT_NAME}."""

# Broker
broker_url = "${BROKER_URL}"
result_backend = "${RESULT_BACKEND}"

# Serialization
task_serializer = "json"
result_serializer = "json"
accept_content = ["json"]

# Timezone
timezone = "UTC"
enable_utc = True

# Worker
worker_prefetch_multiplier = 1
worker_max_tasks_per_child = 200
worker_concurrency = 8

# Task execution
task_acks_late = True
task_reject_on_worker_lost = True
task_time_limit = 300
task_soft_time_limit = 240
task_track_started = True

# Results
result_expires = 3600  # 1 hour

# Broker connection
broker_pool_limit = 10
broker_connection_retry_on_startup = True
PYEOF

# --- tasks.py ---
cat > "$PROJECT_NAME/$PROJECT_NAME/tasks.py" <<'PYEOF'
"""Example Celery tasks."""

from celery import shared_task
from celery.utils.log import get_task_logger

logger = get_task_logger(__name__)


@shared_task
def add(x, y):
    """Simple example task."""
    return x + y


@shared_task(
    bind=True,
    autoretry_for=(ConnectionError, TimeoutError),
    retry_backoff=True,
    retry_backoff_max=600,
    retry_jitter=True,
    max_retries=5,
)
def reliable_task(self, data):
    """Task with automatic retry and exponential backoff."""
    logger.info(f"Processing: {data}")
    # Replace with actual work
    return {"status": "done", "data": data}


@shared_task(bind=True)
def long_running_task(self, total_items):
    """Task with progress reporting."""
    for i in range(total_items):
        # Do work...
        self.update_state(
            state="PROGRESS",
            meta={"current": i + 1, "total": total_items},
        )
    return {"processed": total_items}
PYEOF

# --- Dockerfile ---
cat > "$PROJECT_NAME/Dockerfile" <<DOCKERFILE
FROM python:3.12-slim

RUN groupadd -r celery && useradd -r -g celery celery
WORKDIR /srv/app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

USER celery
CMD ["celery", "-A", "${PROJECT_NAME}", "worker", "--loglevel=INFO"]
DOCKERFILE

# --- docker-compose.yml ---
cat > "$PROJECT_NAME/docker-compose.yml" <<COMPOSEFILE
version: "3.8"
services:
  redis:
    image: redis:7-alpine
    ports:
      - "6379:6379"
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 3

  worker:
    build: .
    command: celery -A ${PROJECT_NAME} worker --loglevel=INFO --concurrency=4
    depends_on:
      redis:
        condition: service_healthy
    environment:
      CELERY_BROKER_URL: redis://redis:6379/0
      CELERY_RESULT_BACKEND: redis://redis:6379/1

  beat:
    build: .
    command: celery -A ${PROJECT_NAME} beat --loglevel=INFO
    depends_on:
      redis:
        condition: service_healthy
    environment:
      CELERY_BROKER_URL: redis://redis:6379/0

  flower:
    build: .
    command: celery -A ${PROJECT_NAME} flower --port=5555
    ports:
      - "5555:5555"
    depends_on:
      redis:
        condition: service_healthy
    environment:
      CELERY_BROKER_URL: redis://redis:6379/0
COMPOSEFILE

echo ""
echo "Project scaffolded at ./$PROJECT_NAME/"
echo ""
echo "Next steps:"
echo "  cd $PROJECT_NAME"
echo "  python -m venv venv && source venv/bin/activate"
echo "  pip install -r requirements.txt"
echo "  celery -A $PROJECT_NAME worker --loglevel=INFO"
echo ""
echo "Or with Docker:"
echo "  cd $PROJECT_NAME && docker compose up"
