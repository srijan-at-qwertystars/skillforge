# Advanced Celery Patterns

## Table of Contents

- [Canvas Workflow Patterns](#canvas-workflow-patterns)
  - [Chain — Sequential Pipelines](#chain--sequential-pipelines)
  - [Group — Parallel Fan-Out](#group--parallel-fan-out)
  - [Chord — Fan-Out with Callback](#chord--fan-out-with-callback)
  - [Map and Starmap](#map-and-starmap)
  - [Chunks — Batched Parallel Processing](#chunks--batched-parallel-processing)
  - [Complex Compositions](#complex-compositions)
- [Task Inheritance and Base Classes](#task-inheritance-and-base-classes)
- [Custom Serializers](#custom-serializers)
- [Signal Handlers](#signal-handlers)
- [Priority Queues and Task Routing](#priority-queues-and-task-routing)
- [Rate Limiting Patterns](#rate-limiting-patterns)
- [Result Backends Comparison](#result-backends-comparison)
- [Task State Machine and Custom States](#task-state-machine-and-custom-states)

---

## Canvas Workflow Patterns

Canvas primitives compose tasks into complex workflows. All primitives return
`Signature` objects that can be further combined before calling `.apply_async()`.

### Chain — Sequential Pipelines

Each task's return value becomes the first argument of the next task.

```python
from celery import chain

# Simple pipeline
pipeline = chain(
    extract.s(source_url),
    transform.s(schema="v2"),
    load.s(table="events"),
)
result = pipeline.apply_async()
final = result.get(timeout=120)

# Using the | operator (equivalent)
pipeline = extract.s(source_url) | transform.s(schema="v2") | load.s(table="events")
```

**Immutable signatures** — prevent the previous task's result from being passed:

```python
# .si() creates an immutable signature — ignores parent return value
pipeline = chain(
    setup_environment.si(env="prod"),
    run_migration.si(version="3.2"),
    send_notification.si(channel="#deploys"),
)
```

**Error handling in chains** — exceptions propagate and halt downstream tasks:

```python
@shared_task(bind=True)
def safe_transform(self, data):
    try:
        return do_transform(data)
    except ValidationError as exc:
        # Log and return sentinel so chain continues
        logger.error(f"Transform failed: {exc}")
        return {"error": str(exc), "partial": data}
```

### Group — Parallel Fan-Out

Execute tasks concurrently. Results are collected in order.

```python
from celery import group

# Process 1000 images in parallel batches
batch = group(
    resize_image.s(img_id, width=800, height=600)
    for img_id in image_ids
)
group_result = batch.apply_async()

# Iterate results as they complete
for result in group_result:
    if result.ready():
        print(result.get())

# Or wait for all
all_results = group_result.get(timeout=300)
```

**Partial group failure** — by default one failure doesn't cancel others:

```python
group_result = batch.apply_async()
group_result.get(propagate=False)  # returns results + exceptions without raising

for result in group_result.results:
    if result.failed():
        print(f"Task {result.id} failed: {result.result}")
    else:
        print(f"Task {result.id} succeeded: {result.result}")
```

### Chord — Fan-Out with Callback

Parallel header tasks + a callback that receives all results.

```python
from celery import chord

# Fetch prices in parallel, then aggregate
workflow = chord(
    header=[fetch_price.s(sym) for sym in ["AAPL", "GOOG", "MSFT", "AMZN"]],
    body=aggregate_and_report.s(report_type="daily"),
)
result = workflow.apply_async()
```

**Chord error handling** — if any header task fails, the callback gets a `ChordError`:

```python
@shared_task
def on_chord_error(request, exc, traceback):
    logger.error(f"Chord {request.id} failed: {exc}")

workflow = chord(
    [fetch_price.s(sym) for sym in symbols],
    aggregate_and_report.s(),
)
workflow.apply_async(link_error=on_chord_error.s())
```

**Chord with minimum success count** (Celery 5.3+):

```python
from celery import chord

# Only need 3 out of 5 to succeed
workflow = chord(
    header=[scrape_source.s(url) for url in urls],
    body=merge_results.s(),
)
# Handle partial failures in the callback
@shared_task
def merge_results(results):
    valid = [r for r in results if not isinstance(r, Exception)]
    if len(valid) < 3:
        raise RuntimeError("Too few successful scrapes")
    return combine(valid)
```

### Map and Starmap

Apply a single task to many arguments without creating a full group.

```python
# map — each item is passed as a single argument
result = process_record.map([record1, record2, record3]).apply_async()

# starmap — each item is unpacked as positional arguments
result = add.starmap([
    (2, 3),
    (4, 5),
    (10, 20),
]).apply_async()
# Returns: [5, 9, 30]
```

### Chunks — Batched Parallel Processing

Split a large iterable into chunks for parallel processing.

```python
# Process 10,000 items in chunks of 100
result = process_item.chunks(
    [(item_id,) for item_id in range(10000)],
    100,  # chunk size
).apply_async()

# Each chunk runs as a single task processing 100 items
# Total: 100 tasks instead of 10,000
```

**Chunks vs Group**: Use chunks when individual items are small and you want to
reduce task overhead. Use group when each item needs its own task for
isolation/retry.

### Complex Compositions

Nest canvas primitives to build multi-stage workflows.

```python
from celery import chain, group, chord

# ETL pipeline: extract → parallel transform → load
etl_workflow = chain(
    extract_from_api.s(endpoint="/users"),
    # Fan out: transform each partition in parallel
    group(
        transform_partition.s(partition=i)
        for i in range(4)
    ),
    # Merge and load
    merge_partitions.s(),
    load_to_warehouse.s(table="dim_users"),
)

# Multi-stage pipeline with error handling
robust_workflow = chain(
    validate_input.s(data),
    chord(
        [process_shard.s(shard_id=i) for i in range(10)],
        combine_shards.s(),
    ),
    post_process.s(),
    notify_completion.si(channel="#data-pipeline"),
)
robust_workflow.apply_async(link_error=pipeline_error_handler.s())
```

**Dynamic fan-out** — generate parallel tasks based on a previous task's result:

```python
@shared_task
def get_user_ids():
    return list(User.objects.values_list("id", flat=True))

@shared_task
def process_users(user_ids):
    # Create a group dynamically and execute it
    job = group(process_single_user.s(uid) for uid in user_ids)
    return job.apply_async()

# Trigger
chain(get_user_ids.s(), process_users.s()).apply_async()
```

---

## Task Inheritance and Base Classes

Create reusable base classes with shared behavior.

```python
from celery import Task

class DatabaseTask(Task):
    """Base task that manages DB connections."""
    _db = None
    abstract = True  # prevents registration as a standalone task

    @property
    def db(self):
        if self._db is None:
            self._db = create_db_connection()
        return self._db

    def after_return(self, status, retval, task_id, args, kwargs, einfo):
        """Called after task returns — clean up connections."""
        if self._db is not None:
            self._db.close()
            self._db = None

    def on_failure(self, exc, task_id, args, kwargs, einfo):
        """Called on task failure — send alert."""
        send_alert(f"Task {self.name} failed: {exc}")

    def on_retry(self, exc, task_id, args, kwargs, einfo):
        """Called on task retry."""
        logger.warning(f"Task {self.name} retrying: {exc}")


@shared_task(base=DatabaseTask, bind=True)
def query_users(self, query):
    return self.db.execute(query).fetchall()


@shared_task(base=DatabaseTask, bind=True)
def insert_record(self, table, data):
    self.db.execute(f"INSERT INTO {table} ...", data)
    self.db.commit()
```

**Lifecycle hooks available on Task**:

| Hook | When |
|---|---|
| `before_start(task_id, args, kwargs)` | Just before execution |
| `after_return(status, retval, task_id, args, kwargs, einfo)` | After task returns (success or failure) |
| `on_failure(exc, task_id, args, kwargs, einfo)` | On exception |
| `on_retry(exc, task_id, args, kwargs, einfo)` | On retry |
| `on_success(retval, task_id, args, kwargs)` | On success |

---

## Custom Serializers

Register custom serializers for complex data types.

```python
import msgpack
from kombu.serialization import register

def msgpack_dumps(obj):
    return msgpack.packb(obj, use_bin_type=True)

def msgpack_loads(data):
    return msgpack.unpackb(data, raw=False)

register(
    "msgpack",
    msgpack_dumps,
    msgpack_loads,
    content_type="application/x-msgpack",
    content_encoding="binary",
)

# Configure Celery to use it
app.conf.update(
    task_serializer="msgpack",
    result_serializer="msgpack",
    accept_content=["msgpack", "json"],  # accept both
)
```

**Serializer comparison**:

| Serializer | Speed | Size | Safety | Types |
|---|---|---|---|---|
| JSON | Medium | Medium | Safe | Primitives only |
| msgpack | Fast | Small | Safe | Primitives + binary |
| pickle | Medium | Medium | **Unsafe** | Any Python object |
| yaml | Slow | Large | Unsafe | Most Python types |

**Rule**: Never accept `pickle` from untrusted sources. Use JSON in production
unless you have a specific need for another format.

---

## Signal Handlers

Celery signals let you hook into task and worker lifecycle events.

```python
from celery.signals import (
    task_prerun,
    task_postrun,
    task_failure,
    task_success,
    task_retry,
    worker_ready,
    worker_shutting_down,
    celeryd_init,
)

@task_prerun.connect
def task_prerun_handler(sender=None, task_id=None, task=None, args=None, kwargs=None, **kw):
    """Called before every task executes."""
    logger.info(f"Starting task {task.name}[{task_id}]")
    # Attach timing info
    task._start_time = time.monotonic()

@task_postrun.connect
def task_postrun_handler(sender=None, task_id=None, task=None, retval=None,
                         state=None, args=None, kwargs=None, **kw):
    """Called after every task completes (success or failure)."""
    elapsed = time.monotonic() - getattr(task, "_start_time", 0)
    metrics.histogram("celery.task.duration", elapsed, tags=[f"task:{task.name}"])

@task_failure.connect
def task_failure_handler(sender=None, task_id=None, exception=None,
                         traceback=None, einfo=None, args=None, kwargs=None, **kw):
    """Called when a task raises an exception."""
    sentry_sdk.capture_exception(exception)
    logger.error(f"Task {sender.name}[{task_id}] failed: {exception}")

@task_success.connect
def task_success_handler(sender=None, result=None, **kw):
    """Called when task completes successfully."""
    metrics.increment("celery.task.success", tags=[f"task:{sender.name}"])

@worker_ready.connect
def worker_ready_handler(sender=None, **kw):
    """Called when a worker is fully started and ready to accept tasks."""
    logger.info(f"Worker ready: {sender.hostname}")
    register_worker_in_consul(sender.hostname)

@worker_shutting_down.connect
def worker_shutdown_handler(sender=None, sig=None, how=None, **kw):
    """Called when worker begins graceful shutdown."""
    logger.info(f"Worker shutting down: {sig}")
    deregister_worker_from_consul(sender.hostname)

@celeryd_init.connect
def worker_init_handler(sender=None, conf=None, **kw):
    """Called before worker is fully initialized — configure logging, connections."""
    setup_sentry(conf.get("SENTRY_DSN"))
```

**Scoping signals to specific tasks**:

```python
@task_prerun.connect(sender=process_payment)
def payment_prerun(sender=None, task_id=None, **kw):
    """Only fires for the process_payment task."""
    audit_log(f"Payment task {task_id} starting")
```

---

## Priority Queues and Task Routing

### Broker-level priority (RabbitMQ)

RabbitMQ supports message priorities 0–9 (higher = more urgent).

```python
from kombu import Queue

app.conf.task_queues = [
    Queue("default", queue_arguments={"x-max-priority": 10}),
]

# Send with priority
process_order.apply_async(args=[order_id], priority=9)       # urgent
generate_report.apply_async(args=[report_id], priority=1)    # background
```

### Redis priority simulation

Redis doesn't support native priorities. Simulate with multiple queues:

```python
from kombu import Queue

app.conf.task_queues = [
    Queue("high"),
    Queue("default"),
    Queue("low"),
]

# Workers consume in priority order
# celery -A myproject worker -Q high,default,low
# Worker drains "high" first, then "default", then "low"
```

### Dynamic routing

```python
class TaskRouter:
    def route_for_task(self, task, args=None, kwargs=None):
        if task.startswith("myapp.tasks.critical"):
            return {"queue": "high", "priority": 9}
        if task.startswith("myapp.tasks.reports"):
            return {"queue": "low", "priority": 1}
        return {"queue": "default"}

app.conf.task_routes = (TaskRouter(),)
```

### Routing by argument inspection

```python
class SmartRouter:
    def route_for_task(self, task, args=None, kwargs=None):
        if task == "myapp.tasks.process_order":
            order_value = kwargs.get("amount", 0) if kwargs else 0
            if order_value > 10000:
                return {"queue": "high_value"}
        return None  # fall through to default routing

app.conf.task_routes = (SmartRouter(),)
```

---

## Rate Limiting Patterns

### Per-task rate limit

```python
@shared_task(rate_limit="100/m")  # 100 per minute per worker
def send_notification(user_id, message):
    push_service.send(user_id, message)

@shared_task(rate_limit="5/s")    # 5 per second per worker
def call_external_api(endpoint):
    return requests.get(endpoint).json()
```

### Per-queue rate limit via dedicated workers

```python
# Config
app.conf.task_routes = {
    "myapp.tasks.send_sms": {"queue": "sms"},
}

# Start a rate-limited worker for the SMS queue
# celery -A myproject worker -Q sms --concurrency=1 -n sms@%h
# With concurrency=1 and task rate_limit="1/s", you get 1 SMS/sec globally
```

### Global rate limiting with Redis

```python
import redis
from celery import shared_task

redis_client = redis.Redis()

@shared_task(bind=True, max_retries=10)
def rate_limited_api_call(self, endpoint, payload):
    key = f"ratelimit:{endpoint}"
    current = redis_client.incr(key)
    if current == 1:
        redis_client.expire(key, 60)  # 60-second window
    if current > 100:  # max 100 calls per minute globally
        raise self.retry(countdown=10)
    return requests.post(endpoint, json=payload).json()
```

### Token bucket with Redis

```python
import time
import redis

redis_client = redis.Redis()

def acquire_token(bucket_name, rate, capacity):
    """Token bucket rate limiter."""
    now = time.time()
    pipe = redis_client.pipeline()
    pipe.hgetall(bucket_name)
    result = pipe.execute()[0]

    tokens = float(result.get(b"tokens", capacity))
    last = float(result.get(b"last", now))

    elapsed = now - last
    tokens = min(capacity, tokens + elapsed * rate)

    if tokens >= 1:
        tokens -= 1
        pipe.hset(bucket_name, mapping={"tokens": tokens, "last": now})
        pipe.execute()
        return True
    return False

@shared_task(bind=True, max_retries=20)
def api_call_with_token_bucket(self, endpoint):
    if not acquire_token("api:bucket", rate=10, capacity=50):
        raise self.retry(countdown=2)
    return requests.get(endpoint).json()
```

---

## Result Backends Comparison

| Backend | Speed | Persistence | Scalability | Best For |
|---|---|---|---|---|
| **Redis** | Very fast | Volatile (unless AOF) | Good | Most use cases; fast result lookups |
| **RabbitMQ (RPC)** | Fast | Volatile | Limited | Request-reply; results consumed once |
| **PostgreSQL/MySQL** | Medium | Durable | Good | When you need queryable result history |
| **Django ORM** | Medium | Durable | Moderate | Django apps wanting admin integration |
| **S3** | Slow | Durable | Excellent | Large results, archival, compliance |
| **Memcached** | Very fast | Volatile | Good | Ephemeral results, no persistence needed |
| **Filesystem** | Varies | Durable | Poor | Dev/testing only |

### Redis backend

```python
result_backend = "redis://localhost:6379/1"
result_expires = 3600  # results expire after 1 hour
```

- Fastest for most workloads
- Use a separate Redis DB or instance from broker
- Set `result_expires` to avoid memory bloat
- Enable AOF persistence if results must survive restarts

### RabbitMQ RPC backend

```python
result_backend = "rpc://"
result_persistent = False  # default; results are transient
```

- Results sent as direct reply messages
- Each result can only be consumed once (no `.get()` from multiple places)
- Good for request-reply patterns

### Database backends

```python
# PostgreSQL
result_backend = "db+postgresql://user:pass@host/dbname"

# SQLite (dev only)
result_backend = "db+sqlite:///results.db"

# Django ORM
CELERY_RESULT_BACKEND = "django-db"
# Requires: pip install django-celery-results
# Add 'django_celery_results' to INSTALLED_APPS, run migrate
```

### S3 backend

```python
result_backend = "s3://"
s3_access_key_id = "..."
s3_secret_access_key = "..."
s3_bucket = "celery-results"
s3_region = "us-east-1"
```

- Excellent for large result payloads (>1 MB)
- Built-in durability and lifecycle policies
- Slow for frequent small-result lookups

---

## Task State Machine and Custom States

### Built-in states

```
PENDING → STARTED → SUCCESS
                  → FAILURE
                  → RETRY → STARTED → ...
REVOKED (task cancelled before execution)
```

- `PENDING` — task is unknown to the backend (not yet run or result expired)
- `STARTED` — worker has begun execution (requires `task_track_started=True`)
- `SUCCESS` — completed successfully
- `FAILURE` — raised an unhandled exception
- `RETRY` — awaiting retry after a failure
- `REVOKED` — cancelled via `revoke()`

### Custom states for progress reporting

```python
from celery import shared_task

@shared_task(bind=True)
def import_dataset(self, filepath):
    total_rows = count_rows(filepath)
    processed = 0

    for batch in read_batches(filepath, size=1000):
        process_batch(batch)
        processed += len(batch)
        self.update_state(
            state="PROGRESS",
            meta={
                "current": processed,
                "total": total_rows,
                "percent": int(100 * processed / total_rows),
            },
        )

    return {"processed": processed, "status": "complete"}
```

**Reading custom state from the caller**:

```python
result = import_dataset.delay("/data/large.csv")

# Poll for progress
while not result.ready():
    info = result.info
    if result.state == "PROGRESS":
        print(f"Progress: {info['percent']}%")
    time.sleep(1)

print(f"Done: {result.get()}")
```

### Custom state machine for multi-phase tasks

```python
TASK_STATES = ("VALIDATING", "DOWNLOADING", "PROCESSING", "UPLOADING", "COMPLETE")

@shared_task(bind=True)
def data_pipeline(self, source_url, destination):
    self.update_state(state="VALIDATING", meta={"phase": 1, "total_phases": 4})
    validate_source(source_url)

    self.update_state(state="DOWNLOADING", meta={"phase": 2, "total_phases": 4})
    local_path = download(source_url)

    self.update_state(state="PROCESSING", meta={"phase": 3, "total_phases": 4})
    processed = transform(local_path)

    self.update_state(state="UPLOADING", meta={"phase": 4, "total_phases": 4})
    upload(processed, destination)

    return {"state": "COMPLETE", "destination": destination}
```

### Registering custom states for Flower visibility

```python
from celery.states import state, STARTED

# Define custom states with precedence
PROGRESS = state("PROGRESS", STARTED)  # treated as "in progress"
```

Custom states appear in Flower's task detail view and can be filtered in the
task history.
