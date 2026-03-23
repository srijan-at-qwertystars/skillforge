---
name: celery-task-queues
description: >
  Use this skill when writing, configuring, debugging, or deploying Celery distributed task queues in Python.
  TRIGGER when: code imports celery, kombu, or celery-beat; user asks about async task queues, background jobs,
  periodic/scheduled tasks, task routing, worker scaling, canvas workflows (chain/group/chord), retry strategies,
  or Flower monitoring; user mentions broker setup (Redis/RabbitMQ) for task processing; Django/Flask/FastAPI
  integration with Celery; or production deployment of Celery workers via Docker/systemd.
  DO NOT TRIGGER when: user works with asyncio/aiohttp without Celery, uses a different task queue (RQ, Dramatiq,
  Huey, ARQ), builds pure pub/sub with Redis without task semantics, or uses Kafka/RabbitMQ directly without Celery.
---

# Celery 5.x Task Queue Skill

## Architecture

- **Producer** — app code calling `.delay()`/`.apply_async()` to enqueue tasks
- **Broker** — message transport (Redis/RabbitMQ); holds messages until consumed
- **Worker** — pulls messages from broker, executes tasks, stores results
- **Result Backend** (optional) — stores return values (Redis, PostgreSQL, S3); keep separate from broker

Flow: Producer → Broker → Worker → Result Backend → Producer reads via `AsyncResult`.

## Project Setup

```python
# Standalone: celery_app.py
from celery import Celery
app = Celery("myproject")
app.config_from_object("myproject.celeryconfig")
app.autodiscover_tasks(["myproject.tasks", "myproject.emails"])

# Django: myproject/celery.py
import os
from celery import Celery
os.environ.setdefault("DJANGO_SETTINGS_MODULE", "myproject.settings")
app = Celery("myproject")
app.config_from_object("django.conf:settings", namespace="CELERY")
app.autodiscover_tasks()
# In myproject/__init__.py:
# from .celery import app as celery_app; __all__ = ("celery_app",)
```

```python
# celeryconfig.py
broker_url = "redis://localhost:6379/0"
result_backend = "redis://localhost:6379/1"  # separate DB from broker
task_serializer = "json"
result_serializer = "json"
accept_content = ["json"]
timezone = "UTC"
enable_utc = True
worker_prefetch_multiplier = 1          # 1 for long tasks; higher for short batch
worker_max_tasks_per_child = 200        # recycle to prevent memory leaks
worker_concurrency = 8                  # CPU cores for CPU-bound; 2-4x for I/O
broker_pool_limit = 10
task_acks_late = True                   # ack after execution (requires idempotent tasks)
task_reject_on_worker_lost = True       # requeue on worker crash
task_time_limit = 300                   # hard kill at 5 min
task_soft_time_limit = 240              # SoftTimeLimitExceeded at 4 min
```

Broker URLs: Redis `redis://host:6379/0` (`rediss://` for TLS), RabbitMQ `amqp://user:pass@host:5672/vhost`, SQS `sqs://`.

## Task Definition

### @shared_task vs @app.task

Use `@shared_task` in reusable apps or to avoid circular imports. Use `@app.task` when you have direct access to the app instance.

```python
from celery import shared_task

@shared_task
def add(x, y):
    return x + y

# Call:
result = add.delay(4, 6)       # → AsyncResult
result.get(timeout=10)          # → 10
```

### bind=True — access task instance

```python
@shared_task(bind=True)
def fetch_url(self, url):
    """self gives access to self.request, self.retry(), self.update_state()"""
    try:
        resp = requests.get(url, timeout=10)
        resp.raise_for_status()
        return resp.text[:500]
    except requests.RequestException as exc:
        raise self.retry(exc=exc, countdown=60, max_retries=3)
```

### Rate limits

```python
@shared_task(rate_limit="10/m")   # max 10 calls per minute per worker
def send_email(to, subject, body):
    mail.send(to, subject, body)
```

### Autoretry with exponential backoff

```python
@shared_task(
    bind=True,
    autoretry_for=(ConnectionError, TimeoutError),
    retry_backoff=True,           # exponential: 1s, 2s, 4s, 8s...
    retry_backoff_max=600,        # cap at 10 min
    retry_jitter=True,            # add randomness to prevent thundering herd
    max_retries=5,
)
def call_external_api(self, payload):
    response = requests.post("https://api.example.com/process", json=payload)
    response.raise_for_status()
    return response.json()

# Input: call_external_api.delay({"user_id": 42})
# On ConnectionError → retries at ~1s, ~2s, ~4s, ~8s, ~16s (with jitter, capped at 600s)
# After 5 failures → task moves to FAILURE state
```

## Task Routing and Queues

### Define queues

```python
from kombu import Queue

app.conf.task_queues = (
    Queue("default"),
    Queue("high_priority"),
    Queue("email"),
    Queue("reports"),
)
app.conf.task_default_queue = "default"
```

### Route tasks to queues

```python
app.conf.task_routes = {
    "myapp.tasks.send_email": {"queue": "email"},
    "myapp.tasks.generate_report": {"queue": "reports"},
    "myapp.tasks.process_payment": {"queue": "high_priority"},
    "myapp.tasks.*": {"queue": "default"},          # wildcard fallback
}
```

### Start workers for specific queues

```bash
# Dedicated high-priority worker
celery -A myproject worker -Q high_priority --concurrency=4 -n high@%h

# Worker consuming multiple queues
celery -A myproject worker -Q default,email --concurrency=8 -n general@%h

# Autoscaling worker
celery -A myproject worker -Q reports --autoscale=10,2 -n reports@%h
```

## Periodic Tasks with Celery Beat

### Static schedule in config

```python
from celery.schedules import crontab

app.conf.beat_schedule = {
    "cleanup-every-night": {
        "task": "myapp.tasks.cleanup_old_records",
        "schedule": crontab(hour=3, minute=0),       # daily at 3 AM UTC
        "args": (90,),                                 # delete records older than 90 days
    },
    "health-check-every-5-min": {
        "task": "myapp.tasks.health_check",
        "schedule": 300.0,                             # every 300 seconds
    },
    "weekly-report": {
        "task": "myapp.tasks.generate_weekly_report",
        "schedule": crontab(hour=9, minute=0, day_of_week=1),  # Monday 9 AM
        "kwargs": {"format": "pdf"},
    },
}
```

### Django: database-driven schedules

```bash
pip install django-celery-beat
# settings.py: INSTALLED_APPS = [..., "django_celery_beat"] → run migrate
# Start: celery -A myproject beat --scheduler django_celery_beat.schedulers:DatabaseScheduler
```

Manage periodic tasks from Django admin. Always run exactly ONE beat instance.

```bash
celery -A myproject beat --loglevel=INFO
# Dev only — embed beat in worker: celery -A myproject worker --beat -l INFO
```

## Canvas Patterns

Canvas primitives compose tasks into workflows.

### chain — sequential pipeline

```python
from celery import chain

pipeline = chain(
    fetch_data.s("https://api.example.com/data"),
    transform_data.s(),
    store_results.s(),
)
result = pipeline.apply_async()
# fetch_data → its return passes to transform_data → passes to store_results
```

### group — parallel execution

```python
from celery import group

batch = group(
    process_image.s(img) for img in image_list
)
result = batch.apply_async()
results = result.get()  # list of all return values
```

### chord — parallel + callback

```python
from celery import chord

workflow = chord(
    [fetch_price.s(symbol) for symbol in ["AAPL", "GOOG", "MSFT"]],
    aggregate_prices.s()
)
result = workflow.apply_async()
# All fetch_price tasks run in parallel → their results list passes to aggregate_prices
```

### starmap — apply task to argument tuples

```python
add.starmap([(2, 3), (4, 5), (6, 7)])
# Equivalent to: [add(2,3), add(4,5), add(6,7)]
# Returns: [5, 9, 13]
```

### chain + group composition

```python
workflow = chain(
    fetch_user_ids.s(),
    group(process_user.s(uid) for uid in range(100)),
    summarize_results.s(),
)
```

**Canvas error behavior**: if a task in a chord header fails, the callback is NOT executed and `ChordError` is raised. Attach error handlers with `link_error` on the chord body. In chains, exceptions propagate and halt downstream tasks.

## Error Handling

### Manual retry

```python
@shared_task(bind=True, max_retries=3)
def unreliable_task(self, data):
    try:
        result = external_service.call(data)
    except ServiceUnavailable as exc:
        raise self.retry(exc=exc, countdown=2 ** self.request.retries)  # 1, 2, 4s
    return result
```

### Custom error callback

```python
@shared_task
def error_handler(request, exc, traceback):
    print(f"Task {request.id} failed: {exc}")

add.apply_async((2, 2), link_error=error_handler.s())
```

### SoftTimeLimitExceeded handling

```python
from celery.exceptions import SoftTimeLimitExceeded

@shared_task(soft_time_limit=120)
def long_running(data):
    try:
        for chunk in process(data):
            save(chunk)
    except SoftTimeLimitExceeded:
        cleanup()
        raise  # or return partial results
```

## Monitoring with Flower

```bash
pip install flower
celery -A myproject flower --port=5555
celery -A myproject flower --basic_auth=admin:secret --port=5555  # with auth
```

Provides: real-time worker status, task history, success/failure rates, active/reserved/scheduled counts, traceback inspection. Use `--persistent=True --db=flower.db` to persist across restarts.

## Testing

### Unit test — test logic directly

```python
from myapp.tasks import add

def test_add():
    assert add(2, 3) == 5  # call function directly, no Celery machinery
```

### Eager mode — synchronous execution in tests

```python
# conftest.py
import pytest

@pytest.fixture(scope="session")
def celery_config():
    return {
        "task_always_eager": True,
        "task_eager_propagates": True,  # raise exceptions instead of storing
    }
```

Eager mode skips broker/worker entirely. Good for logic tests. Does NOT test serialization, async behavior, or result backend. Never rely on it for integration testing.

### pytest fixtures with celery.contrib.pytest

```python
# conftest.py
pytest_plugins = ("celery.contrib.pytest",)

@pytest.fixture(scope="session")
def celery_config():
    return {
        "broker_url": "memory://",
        "result_backend": "rpc://",
    }

# test_tasks.py
def test_add_with_worker(celery_app, celery_worker):
    result = add.delay(4, 6)
    assert result.get(timeout=10) == 10
```

### Mock task calls

```python
from unittest.mock import patch

def test_view_enqueues_task():
    with patch("myapp.tasks.send_email.delay") as mock_delay:
        response = client.post("/signup", data={"email": "a@b.com"})
        mock_delay.assert_called_once_with("a@b.com", subject="Welcome")
```

## Production Deployment

See [production-guide.md](references/production-guide.md) for full deployment coverage (systemd, Docker, Kubernetes, monitoring, security). Quick reference:

```bash
# Horizontal: run multiple worker processes/containers
celery -A myproject worker --concurrency=4 -n worker1@%h
celery -A myproject worker --concurrency=4 -n worker2@%h

# Autoscaling: min 2, max 10 processes
celery -A myproject worker --autoscale=10,2

# Eventlet/gevent for I/O-bound (thousands of concurrent tasks)
pip install gevent
celery -A myproject worker --pool=gevent --concurrency=500
```

Ready-to-use templates in [assets/](assets/): `docker-compose.yml`, `celery-systemd.service`, `celerybeat-systemd.service`, `celeryconfig.py`.

## Common Pitfalls

| Pitfall | Fix |
|---|---|
| Passing ORM objects as task args | Pass IDs, re-fetch in task. Objects aren't serializable and go stale. |
| Shared broker and result backend Redis DB | Use separate Redis databases (e.g., `/0` for broker, `/1` for results). |
| Running multiple beat instances | Always run exactly ONE beat process. Use PID file or container singleton. |
| No time limits set | Always set `task_time_limit` and `task_soft_time_limit`. Stuck tasks block workers. |
| Using `acks_late` on non-idempotent tasks | Only enable late acks for tasks safe to re-execute on crash. |
| `task_always_eager` in production | Never. It bypasses the entire broker/worker pipeline. |
| Ignoring `worker_max_tasks_per_child` | Set to 100-500. Prevents memory leaks from accumulating in long-running workers. |
| Large payloads in task args | Keep args small (IDs, keys). Store large data in S3/DB and pass references. |
| Blocking calls inside gevent pool | Use gevent-compatible libraries or switch to prefork pool. |

## Debugging

```bash
# Inspect active tasks
celery -A myproject inspect active

# Inspect reserved (prefetched) tasks
celery -A myproject inspect reserved

# Inspect registered tasks
celery -A myproject inspect registered

# Purge all messages from broker (careful!)
celery -A myproject purge

# Check worker status
celery -A myproject status

# Enable task events for Flower
celery -A myproject worker -l INFO -E
```

### Task state tracking

```python
result = my_task.delay(arg)
result.state    # PENDING → STARTED → SUCCESS / FAILURE / RETRY
result.info     # return value on SUCCESS, exception on FAILURE
result.ready()  # True when finished
result.get(timeout=30, propagate=False)  # get result without re-raising exceptions
```

## Additional Resources

This skill includes supplementary references, scripts, and assets for advanced usage and production deployment.

### references/

Deep-dive documents for advanced topics:

- **[advanced-patterns.md](references/advanced-patterns.md)** — Canvas compositions (chain/group/chord/chunks with complex examples), task inheritance and base classes, custom serializers, signal handlers (`task_prerun`, `task_postrun`, `task_failure`, `worker_ready`), priority queues and routing strategies, rate limiting patterns, result backends comparison, and task state machine with custom states.
- **[troubleshooting.md](references/troubleshooting.md)** — Solutions for common issues: worker not picking up tasks, memory leaks in long-running workers, timezone issues with celery-beat, serialization errors, connection pool exhaustion, tasks stuck in PENDING, broker reconnection, monitoring dead workers, and Django integration problems.
- **[production-guide.md](references/production-guide.md)** — Complete production deployment guide: systemd unit files, Docker Compose full stack, Kubernetes with HPA, monitoring stack (Flower + Prometheus + Grafana), log aggregation, security hardening, and scaling strategies (prefork vs gevent/eventlet).

### scripts/

Ready-to-use operational scripts:

- **[setup-celery-project.sh](scripts/setup-celery-project.sh)** — Scaffold a complete Celery project (app, tasks, config, Dockerfile, docker-compose). Supports `--broker redis|rabbitmq` and `--django` flags.
- **[health-check.py](scripts/health-check.py)** — Check worker health, queue lengths, active/reserved/scheduled tasks. Supports `--json` output. Exit code 0=healthy, 1=issues, 2=no workers.
- **[purge-and-inspect.sh](scripts/purge-and-inspect.sh)** — Wrapper for common `celery inspect` and `celery control` commands: status, active tasks, purge queues, revoke tasks, set rate limits, graceful shutdown.

### assets/

Production-ready configuration templates:

- **[docker-compose.yml](assets/docker-compose.yml)** — Full Celery stack: Redis broker, default + priority workers, beat, Flower. Includes health checks, resource limits, replicas, and persistent volumes.
- **[celery-systemd.service](assets/celery-systemd.service)** — Systemd unit file for Celery workers with security hardening, multi-node support, and environment file configuration.
- **[celerybeat-systemd.service](assets/celerybeat-systemd.service)** — Systemd unit file for Celery beat scheduler.
- **[celeryconfig.py](assets/celeryconfig.py)** — Production-ready configuration template with all important settings commented and explained.
