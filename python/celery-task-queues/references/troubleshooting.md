# Celery Troubleshooting Guide

## Table of Contents

- [Worker Not Picking Up Tasks](#worker-not-picking-up-tasks)
- [Memory Leaks in Long-Running Workers](#memory-leaks-in-long-running-workers)
- [Timezone Issues with Celery Beat](#timezone-issues-with-celery-beat)
- [Serialization Errors](#serialization-errors)
- [Connection Pool Exhaustion](#connection-pool-exhaustion)
- [Task Stuck in PENDING State](#task-stuck-in-pending-state)
- [Broker Connection Failures and Reconnection](#broker-connection-failures-and-reconnection)
- [Monitoring Dead Workers](#monitoring-dead-workers)
- [Chord and Group Failures](#chord-and-group-failures)
- [Performance Degradation](#performance-degradation)
- [Django Integration Issues](#django-integration-issues)

---

## Worker Not Picking Up Tasks

### Symptoms

- Tasks are published (visible in broker) but never execute
- `celery inspect active` returns empty
- Queue grows without being consumed

### Common causes and fixes

**1. Worker listening on wrong queue**

```bash
# Check which queues the worker consumes
celery -A myproject inspect active_queues

# Task is routed to "email" but worker only listens on "default"
# Fix: start worker with correct queue
celery -A myproject worker -Q default,email -l INFO
```

**2. Task not registered / not discovered**

```bash
# List registered tasks
celery -A myproject inspect registered

# Common causes:
# - autodiscover_tasks() not finding your module
# - Import error in tasks.py (silent failure)
# - Task module not in INSTALLED_APPS (Django)

# Fix: ensure imports work
python -c "from myapp.tasks import my_task; print(my_task.name)"
```

**3. Mismatched app name**

```python
# Producer uses: celery -A myproject ...
# But task is registered under a different app name
# Verify: task.app should be the same app instance

# Check task name matches what's in the broker message
celery -A myproject inspect registered | grep my_task
```

**4. Prefetch consuming all tasks**

```python
# Worker prefetched all messages but is stuck on a long task
# Other tasks wait in the prefetch buffer
worker_prefetch_multiplier = 1  # set to 1 for long tasks
```

**5. Late ack + visibility timeout (Redis broker)**

```python
# Redis broker: unacked messages become visible again after visibility_timeout (1hr default)
# If tasks take >1hr, they get redelivered
broker_transport_options = {
    "visibility_timeout": 43200,  # 12 hours for very long tasks
}
```

---

## Memory Leaks in Long-Running Workers

### Symptoms

- Worker RSS memory grows continuously
- OOM killer terminates workers
- Performance degrades over time

### Fixes

**1. Limit tasks per child process**

```python
# Recycle worker processes after N tasks
worker_max_tasks_per_child = 200  # default: None (never recycle)
```

```bash
# CLI equivalent
celery -A myproject worker --max-tasks-per-child=200
```

**2. Limit memory per child**

```python
# Recycle when resident memory exceeds limit (KB)
worker_max_memory_per_child = 200000  # ~200MB per child

# Note: only works with prefork pool, checked after each task completes
```

```bash
celery -A myproject worker --max-memory-per-child=200000
```

**3. Common leak sources**

```python
# BAD: accumulating data in module-level variables
_cache = {}

@shared_task
def leaky_task(key, value):
    _cache[key] = value  # never cleared, grows forever

# FIX: use external cache (Redis, memcached) or clear periodically

# BAD: unclosed DB connections
@shared_task
def db_task():
    conn = psycopg2.connect(...)
    cursor = conn.cursor()
    cursor.execute("SELECT ...")
    # connection never closed!

# FIX: use context managers
@shared_task
def db_task():
    with psycopg2.connect(...) as conn:
        with conn.cursor() as cursor:
            cursor.execute("SELECT ...")
```

**4. Django-specific: clear query log**

```python
# Django logs all SQL queries in DEBUG mode
# In celery worker startup:
from django.conf import settings
settings.DEBUG = False  # never run celery workers with DEBUG=True

# Or manually reset:
from django import db
db.reset_queries()
```

**5. Profiling memory**

```bash
# Install memory profiler
pip install objgraph pympler

# In a task:
import objgraph
objgraph.show_growth(limit=10)  # after suspect tasks
```

---

## Timezone Issues with Celery Beat

### Symptoms

- Scheduled tasks fire at wrong times
- Tasks run with timezone offset
- `crontab()` schedules off by hours

### Fixes

**1. Always use UTC internally**

```python
# celeryconfig.py
timezone = "UTC"
enable_utc = True  # always True in Celery 5.x
```

**2. Crontab with timezone-aware scheduling**

```python
from celery.schedules import crontab
import pytz

app.conf.beat_schedule = {
    "daily-us-eastern": {
        "task": "myapp.tasks.daily_report",
        # Run at 9 AM US Eastern (beat converts to UTC internally)
        "schedule": crontab(hour=9, minute=0),
        "options": {"expires": 3600},
    },
}
# Set the Celery timezone to your local zone if crontabs should be local
app.conf.timezone = "US/Eastern"
```

**3. Django + celery-beat timezone mismatch**

```python
# settings.py
TIME_ZONE = "America/New_York"
USE_TZ = True

# Celery must match Django or use UTC
CELERY_TIMEZONE = "America/New_York"  # match Django
CELERY_ENABLE_UTC = True
```

**4. Beat scheduler stores last-run in UTC**

```bash
# The celerybeat-schedule file stores timestamps in UTC
# If you change timezone, remove the schedule file to reset
rm celerybeat-schedule
celery -A myproject beat -l INFO
```

**5. DST transitions**

```python
# Crontab handles DST transitions — tasks may fire twice or be skipped
# during DST changes depending on the timezone library
# Using UTC avoids this entirely
timezone = "UTC"
```

---

## Serialization Errors

### Symptoms

- `kombu.exceptions.EncodeError`
- `TypeError: Object of type X is not JSON serializable`
- `pickle.PicklingError`

### Fixes

**1. Non-serializable task arguments**

```python
# BAD: passing Django model instances
send_email.delay(user)  # User object is not JSON serializable

# FIX: pass IDs, re-fetch in task
send_email.delay(user.id)

@shared_task
def send_email(user_id):
    user = User.objects.get(id=user_id)
    ...
```

**2. Non-serializable return values**

```python
# BAD: returning datetime, Decimal, or custom objects
@shared_task
def get_stats():
    return {
        "timestamp": datetime.now(),     # not JSON-serializable
        "total": Decimal("123.45"),       # not JSON-serializable
    }

# FIX: convert to serializable types
@shared_task
def get_stats():
    return {
        "timestamp": datetime.now().isoformat(),
        "total": float(Decimal("123.45")),
    }
```

**3. Restricting serializers for security**

```python
# NEVER accept pickle from untrusted sources
accept_content = ["json"]           # only JSON
task_serializer = "json"
result_serializer = "json"

# If you must use pickle (trusted internal only):
accept_content = ["json", "pickle"]
task_serializer = "pickle"
# Set: CELERY_ACCEPT_CONTENT and configure message signing
```

**4. Content type mismatch**

```python
# Error: "Refusing to deserialize untrusted content of type pickle"
# Producer sends pickle but worker only accepts JSON

# Fix: ensure all workers and producers use the same serializer
# Or accept both:
accept_content = ["json", "pickle"]
```

**5. Custom object serialization**

```python
import json
from datetime import datetime, date
from decimal import Decimal
from uuid import UUID

class CeleryEncoder(json.JSONEncoder):
    def default(self, obj):
        if isinstance(obj, (datetime, date)):
            return obj.isoformat()
        if isinstance(obj, Decimal):
            return str(obj)
        if isinstance(obj, UUID):
            return str(obj)
        return super().default(obj)

# Register as custom serializer (see advanced-patterns.md)
```

---

## Connection Pool Exhaustion

### Symptoms

- `redis.exceptions.ConnectionError: Too many connections`
- `amqp.exceptions.ResourceError`
- Workers hang when trying to publish results
- Intermittent `ConnectionResetError`

### Fixes

**1. Tune broker pool limit**

```python
# Default is 10 connections per worker
broker_pool_limit = 10  # increase if needed, but monitor

# Set to 0 to disable pooling (not recommended for production)
# Set to None for unlimited (dangerous)
```

**2. Redis max connections**

```python
# Redis server: maxclients 10000 (default)
# Calculate: workers × concurrency × 2 (broker + result) < maxclients

broker_transport_options = {
    "max_connections": 20,  # per worker connection pool
}
```

**3. Result backend connection pool**

```python
# Separate pool for result backend
redis_backend_transport_options = {
    "max_connections": 20,
}
```

**4. Close stale connections**

```python
# RabbitMQ heartbeat to detect dead connections
broker_heartbeat = 10  # seconds
broker_connection_timeout = 30

# Redis: socket timeout
broker_transport_options = {
    "socket_timeout": 5,
    "socket_connect_timeout": 5,
}
```

**5. Monitor connections**

```bash
# Redis: check connected clients
redis-cli info clients | grep connected_clients

# RabbitMQ: check connections
rabbitmqctl list_connections | wc -l
```

---

## Task Stuck in PENDING State

### Symptoms

- `result.state` always returns `PENDING`
- `result.get()` hangs indefinitely
- Task appears to never execute

### Causes and fixes

**1. PENDING is the default for unknown tasks**

```python
# PENDING means "I don't know about this task" — NOT "task is waiting"
# Could mean: task ID is wrong, result expired, or result backend not configured

result = AsyncResult("nonexistent-task-id")
result.state  # "PENDING" — but this task doesn't exist!
```

**2. No result backend configured**

```python
# Without a result backend, state is always PENDING
# Fix: configure result_backend
result_backend = "redis://localhost:6379/1"
```

**3. Result expired**

```python
# Results expire after result_expires (default: 24 hours)
result_expires = 86400  # 24 hours

# If you check state after expiry, it returns PENDING
# Fix: check earlier, or increase expiry time
```

**4. Task ID mismatch**

```python
# Common with eager mode or test doubles
result = my_task.delay(arg)
task_id = result.id  # save this!

# Later:
from celery.result import AsyncResult
result = AsyncResult(task_id)  # use the exact same ID
```

**5. Task not started yet (enable tracking)**

```python
# By default STARTED state is not tracked
task_track_started = True  # enables STARTED state

# Now you can distinguish:
# PENDING = unknown/not-yet-received
# STARTED = worker has begun execution
```

---

## Broker Connection Failures and Reconnection

### Symptoms

- `ConnectionRefusedError` on startup or during operation
- Tasks silently lost during broker outage
- Workers crash and don't reconnect

### Fixes

**1. Enable automatic reconnection**

```python
# Celery retries broker connections automatically by default
broker_connection_retry_on_startup = True  # Celery 5.3+
broker_connection_retry = True             # retry during operation
broker_connection_max_retries = None       # retry forever (default: 100)
```

**2. Configure retry intervals**

```python
# Wait between connection retries
broker_connection_timeout = 30          # connection timeout in seconds

# For Redis
broker_transport_options = {
    "retry_on_timeout": True,
    "socket_timeout": 5,
    "socket_connect_timeout": 5,
}
```

**3. Failover with multiple brokers**

```python
# RabbitMQ cluster failover
broker_url = "amqp://user:pass@host1:5672/vhost"
broker_failover_strategy = "round-robin"
broker_transport_options = {
    "failover_strategy": "round-robin",
    "alternates": [
        "amqp://user:pass@host2:5672/vhost",
        "amqp://user:pass@host3:5672/vhost",
    ],
}

# Redis Sentinel
broker_url = "sentinel://sentinel1:26379/0"
broker_transport_options = {
    "master_name": "mymaster",
    "sentinel_kwargs": {"password": "sentinel_pass"},
    "sentinels": [
        ("sentinel1", 26379),
        ("sentinel2", 26379),
        ("sentinel3", 26379),
    ],
}
```

**4. Handle connection errors in producers**

```python
from kombu.exceptions import OperationalError

try:
    my_task.delay(arg)
except OperationalError as exc:
    logger.error(f"Broker unavailable: {exc}")
    # Fallback: write to DB queue, retry later, or return error to user
```

**5. Late ack for crash safety**

```python
# If worker crashes mid-task, unacked messages return to broker
task_acks_late = True
task_reject_on_worker_lost = True  # requeue if worker is killed

# Only safe for idempotent tasks!
```

---

## Monitoring Dead Workers

### Symptoms

- Worker process exists but doesn't respond
- Tasks pile up with no consumers
- Flower shows worker as offline

### Detection strategies

**1. Ping workers**

```bash
# Check which workers are alive
celery -A myproject inspect ping
# Returns: {"worker@hostname": {"ok": "pong"}}

# No response = dead or unreachable worker
```

**2. Automated health check script**

```python
from celery import current_app

def check_worker_health():
    inspect = current_app.control.inspect()
    ping = inspect.ping()
    if not ping:
        alert("No workers responding!")
        return False

    active = inspect.active()
    reserved = inspect.reserved()
    stats = inspect.stats()

    for worker, info in stats.items():
        pool = info.get("pool", {})
        if pool.get("writes", {}).get("total", 0) == 0:
            alert(f"Worker {worker} may be stuck — no tasks processed")
    return True
```

**3. Worker heartbeat monitoring**

```python
# Workers send heartbeats every 2 seconds (default)
worker_send_task_events = True

# Monitor with event receiver
from celery import Celery

app = Celery(broker="redis://localhost:6379/0")

def monitor():
    with app.connection() as conn:
        recv = app.events.Receiver(conn, handlers={
            "worker-heartbeat": lambda event: print(f"Heartbeat: {event['hostname']}"),
            "worker-offline": lambda event: alert(f"Worker offline: {event['hostname']}"),
        })
        recv.capture(limit=None)
```

**4. Systemd watchdog**

```ini
# systemd can restart workers that stop sending heartbeats
[Service]
WatchdogSec=60
# Worker must call sd_notify("WATCHDOG=1") within 60 seconds
```

**5. External monitoring**

```bash
# Prometheus + Celery exporter
pip install celery-exporter
celery-exporter --broker-url=redis://localhost:6379/0 --listen-address=0.0.0.0:9808

# Grafana alert: absent(celery_workers) for 5m
```

---

## Chord and Group Failures

### Symptoms

- `ChordError` raised unexpectedly
- Chord callback never executes
- Group results missing entries

### Fixes

**1. Chord callback not firing**

```python
# If ANY header task fails, the callback does NOT fire by default
# Fix: handle errors in header tasks
@shared_task
def safe_fetch(url):
    try:
        return requests.get(url).json()
    except Exception as e:
        return {"error": str(e)}  # return error as data instead of raising
```

**2. ChordError with Redis backend**

```python
# Redis chord implementation requires result backend
# Error: "ChordError: depends_on result is None"
# Fix: ensure result_backend is configured and working
result_backend = "redis://localhost:6379/1"
```

**3. Group result ordering**

```python
# Group results are returned in the same order as signatures
batch = group(task.s(i) for i in range(10))
result = batch.apply_async()
results = result.get()  # results[0] corresponds to task.s(0)
```

---

## Performance Degradation

### Quick diagnostics

```bash
# Check queue depths
celery -A myproject inspect active
celery -A myproject inspect reserved
celery -A myproject inspect scheduled

# Check for stuck tasks
celery -A myproject inspect active --timeout=5

# Worker stats
celery -A myproject inspect stats
```

### Common performance fixes

```python
# 1. Reduce prefetch for long tasks
worker_prefetch_multiplier = 1

# 2. Tune concurrency to workload
worker_concurrency = 4        # CPU-bound: match core count
worker_concurrency = 20       # I/O-bound: higher is OK

# 3. Use gevent/eventlet for I/O-bound tasks
# celery -A myproject worker --pool=gevent --concurrency=500

# 4. Disable result backend if unused
task_ignore_result = True     # per-task or globally

# 5. Use transient queues for ephemeral tasks
from kombu import Queue
Queue("transient", delivery_mode=1)  # non-persistent messages
```

---

## Django Integration Issues

### Common problems

**1. AppRegistryNotReady**

```python
# Error: django.core.exceptions.AppRegistryNotReady: Apps aren't loaded yet

# Fix: ensure django.setup() runs before task imports
# myproject/celery.py
import os
from celery import Celery

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "myproject.settings")

app = Celery("myproject")
app.config_from_object("django.conf:settings", namespace="CELERY")
app.autodiscover_tasks()

# myproject/__init__.py
from .celery import app as celery_app
__all__ = ("celery_app",)
```

**2. Database connection issues in workers**

```python
# Workers may get stale DB connections after DB restart
# Fix: close connections after each task
from django.db import close_old_connections
from celery.signals import task_prerun, task_postrun

@task_prerun.connect
def close_old_connections_prerun(**kwargs):
    close_old_connections()

@task_postrun.connect
def close_old_connections_postrun(**kwargs):
    close_old_connections()
```

**3. Circular imports**

```python
# Use @shared_task instead of @app.task to avoid circular imports
# Or use string-based task references:
chain(
    "myapp.tasks.step1",
    "myapp.tasks.step2",
)
```
