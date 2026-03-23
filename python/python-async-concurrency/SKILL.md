---
name: python-async-concurrency
description:
  positive: "Use when user writes async Python code, asks about asyncio, TaskGroups, async/await patterns, event loops, async generators, semaphores, or choosing between asyncio vs threading vs multiprocessing."
  negative: "Do NOT use for synchronous Python, basic Python syntax, or JavaScript/TypeScript async patterns."
---

# Python Async & Concurrency Patterns

## Asyncio Fundamentals

### Event Loop
The event loop runs coroutines, schedules callbacks, and manages I/O. Use `asyncio.run()` as the single entry point. Never create event loops manually in application code.

```python
import asyncio

async def main():
    result = await fetch_data()
    print(result)

asyncio.run(main())
```

### Coroutines, Tasks, and Futures
- **Coroutine**: Defined with `async def`. Does nothing until awaited or wrapped in a Task.
- **Task**: Wraps a coroutine for concurrent execution via `asyncio.create_task()`.
- **Future**: Low-level awaitable representing an eventual result. Rarely used directly.

```python
async def main():
    result = await compute()            # sequential
    task = asyncio.create_task(compute()) # concurrent
    result = await task
```

Always hold references to created tasks to prevent garbage collection:

```python
background_tasks = set()
task = asyncio.create_task(coro())
background_tasks.add(task)
task.add_done_callback(background_tasks.discard)
```

---

## TaskGroup (Python 3.11+)

Prefer `TaskGroup` over `gather()` for structured concurrency. All tasks are scoped to the context manager. If any task raises, the group cancels the others and raises `ExceptionGroup`.

```python
async def main():
    async with asyncio.TaskGroup() as tg:
        t1 = tg.create_task(fetch("url1"))
        t2 = tg.create_task(fetch("url2"))
        t3 = tg.create_task(fetch("url3"))
    # All tasks complete here; access results via t1.result(), etc.
    print(t1.result(), t2.result(), t3.result())
```

### TaskGroup vs gather

| Feature | `TaskGroup` | `gather()` |
|---|---|---|
| Error handling | Cancels siblings, raises `ExceptionGroup` | Optionally returns exceptions inline |
| Task scoping | All tasks bound to context | No scoping; tasks can leak |
| Cancellation | Automatic on failure | Manual |
| Python version | 3.11+ | 3.4+ |

Use `gather()` only when you need `return_exceptions=True` or must support Python < 3.11.

```python
results = await asyncio.gather(*tasks, return_exceptions=True)
for r in results:
    if isinstance(r, Exception):
        log.error(f"Task failed: {r}")
```

Handle `ExceptionGroup` with `except*`:

```python
try:
    async with asyncio.TaskGroup() as tg:
        tg.create_task(might_fail())
        tg.create_task(might_also_fail())
except* ValueError as eg:
    for exc in eg.exceptions:
        log.error(f"ValueError: {exc}")
except* OSError as eg:
    for exc in eg.exceptions:
        log.error(f"OSError: {exc}")
```

## Concurrency Primitives

### Semaphore — Limit Concurrent Access

```python
sem = asyncio.Semaphore(10)
async def limited_fetch(url: str) -> str:
    async with sem:
        return await fetch(url)
```

Use `BoundedSemaphore` to catch release-without-acquire bugs.

### Lock — Mutual Exclusion

```python
lock = asyncio.Lock()
async with lock:
    data = await read_state()
    await write_state(data + 1)
```

### Event — Signal between coroutines

```python
shutdown_event = asyncio.Event()

async def worker():
    while not shutdown_event.is_set():
        await do_work()
        await asyncio.sleep(1)

# To signal: shutdown_event.set()
```

### Condition — Complex state waits

```python
condition = asyncio.Condition()
async with condition:
    await condition.wait_for(lambda: len(buffer) > 0)
    item = buffer.pop(0)
```

### Queue — Producer-Consumer

```python
queue: asyncio.Queue[int] = asyncio.Queue(maxsize=100)

async def producer():
    for i in range(50):
        await queue.put(i)  # blocks if full (backpressure)

async def consumer():
    while True:
        item = await queue.get()
        await process(item)
        queue.task_done()
```

## Async Generators

Yield values asynchronously. Clean up with `aclosing()`.

```python
from contextlib import aclosing

async def stream_pages(url: str):
    page = 1
    while True:
        data = await fetch_page(url, page)
        if not data:
            break
        yield data
        page += 1

async def main():
    async with aclosing(stream_pages("/api")) as pages:
        async for page in pages:
            process(page)
```

### Async Comprehensions

```python
results = [item async for item in stream_pages("/api")]
```

## Async Context Managers

Use `@asynccontextmanager` for resource lifecycle management.

```python
from contextlib import asynccontextmanager

@asynccontextmanager
async def db_transaction(pool):
    conn = await pool.acquire()
    tx = await conn.begin()
    try:
        yield conn
        await tx.commit()
    except Exception:
        await tx.rollback()
        raise
    finally:
        await pool.release(conn)
```

---

## Timeouts

### asyncio.timeout (Python 3.11+)

```python
async def fetch_with_timeout():
    async with asyncio.timeout(5.0):
        return await slow_operation()
    # Raises TimeoutError if exceeded
```

### asyncio.wait_for (older API)

```python
try:
    result = await asyncio.wait_for(slow_operation(), timeout=5.0)
except TimeoutError:
    log.warning("Operation timed out")
```

### asyncio.timeout with deadline rescheduling

```python
async with asyncio.timeout(10.0) as cm:
    data = await phase_one()
    cm.reschedule(asyncio.get_event_loop().time() + 20.0)  # extend deadline
    await phase_two(data)
```

---

## asyncio vs threading vs multiprocessing

| Criteria | asyncio | threading | multiprocessing |
|---|---|---|---|
| Best for | High-concurrency I/O | Moderate I/O with blocking libs | CPU-bound parallelism |
| GIL impact | N/A (single-threaded) | Limits CPU parallelism | Bypasses GIL |
| Memory overhead | Very low (coroutines) | Low (shared memory) | High (per-process) |
| Concurrency scale | 10K+ tasks | 100s of threads | 10s of processes |
| Data sharing | No locks needed | Requires locks | IPC (queues, pipes) |

### Decision Guide
1. **I/O-bound, high concurrency** (web scraping, API calls, websockets) → `asyncio`
2. **I/O-bound, blocking libraries** (legacy DB drivers, file I/O) → `threading`
3. **CPU-bound** (data processing, image transforms) → `multiprocessing`
4. **Mixed** → `asyncio` + `run_in_executor` / `to_thread`

---

## Common Patterns

### Producer-Consumer with Graceful Shutdown

```python
SENTINEL = object()

async def producer(queue: asyncio.Queue, num_consumers: int):
    async for item in data_source():
        await queue.put(item)
    for _ in range(num_consumers):
        await queue.put(SENTINEL)

async def consumer(queue: asyncio.Queue, sem: asyncio.Semaphore):
    while True:
        item = await queue.get()
        if item is SENTINEL:
            queue.task_done()
            break
        async with sem:
            await process(item)
        queue.task_done()

async def main():
    queue = asyncio.Queue(maxsize=100)
    sem = asyncio.Semaphore(20)
    num_consumers = 5
    async with asyncio.TaskGroup() as tg:
        tg.create_task(producer(queue, num_consumers))
        for _ in range(num_consumers):
            tg.create_task(consumer(queue, sem))
    await queue.join()
```

### Rate Limiting

Use `asyncio.Semaphore` for simple concurrency caps. For requests-per-second, use `aiolimiter` or `aiometer`.

```python
# Simple: cap concurrent requests
sem = asyncio.Semaphore(10)
async def rate_limited_fetch(url):
    async with sem:
        return await fetch(url)
```

### Connection Pooling

```python
class AsyncPool:
    def __init__(self, factory, max_size: int = 10):
        self._factory = factory
        self._pool: asyncio.Queue = asyncio.Queue(maxsize=max_size)
        self._size = 0
        self._max_size = max_size

    @asynccontextmanager
    async def connection(self):
        if self._pool.empty() and self._size < self._max_size:
            conn = await self._factory()
            self._size += 1
        else:
            conn = await self._pool.get()
        try:
            yield conn
        finally:
            await self._pool.put(conn)
```

### Graceful Shutdown

```python
import signal

async def shutdown(sig=None):
    tasks = [t for t in asyncio.all_tasks() if t is not asyncio.current_task()]
    for task in tasks:
        task.cancel()
    await asyncio.gather(*tasks, return_exceptions=True)

loop = asyncio.get_event_loop()
for s in (signal.SIGINT, signal.SIGTERM):
    loop.add_signal_handler(s, lambda s=s: asyncio.create_task(shutdown(s)))
```

---

## Testing with pytest-asyncio

Configure in `pyproject.toml`:

```toml
[tool.pytest.ini_options]
asyncio_mode = "auto"
```

### Async Tests and Fixtures

```python
import pytest

@pytest.mark.asyncio
async def test_fetch_data():
    result = await fetch_data("test-url")
    assert result.status == 200

@pytest.fixture
async def db_conn():
    conn = await create_connection()
    yield conn
    await conn.close()

@pytest.mark.asyncio
async def test_query(db_conn):
    rows = await db_conn.fetch("SELECT 1")
    assert len(rows) == 1
```

### Mocking Async Functions

```python
from unittest.mock import AsyncMock, patch

@pytest.mark.asyncio
async def test_with_mock():
    mock_fetch = AsyncMock(return_value={"key": "value"})
    with patch("mymodule.fetch_data", mock_fetch):
        result = await process_data()
    assert result["key"] == "value"
    mock_fetch.assert_awaited_once()
```

---

## Debugging

### Enable Debug Mode

```python
asyncio.run(main(), debug=True)
# Or: PYTHONASYNCIODEBUG=1 python app.py
```

Debug mode logs unawaited coroutines, slow callbacks (>100ms), and unclosed resources.

### Task Introspection

```python
for task in asyncio.all_tasks():
    print(f"{task.get_name()}: {task.get_coro()}")
```

Python 3.14+ adds CLI introspection: `python -m asyncio ps <PID>` and `python -m asyncio pstree <PID>`.

### Name Your Tasks

```python
task = asyncio.create_task(handler(req), name=f"handle-{req.id}")
```

---

## Anti-Patterns

### 1. Blocking the Event Loop

```python
# WRONG: blocks all other coroutines
async def bad():
    time.sleep(5)           # blocks!
    data = requests.get(url) # blocks!

# CORRECT: use async equivalents or offload
async def good():
    await asyncio.sleep(5)
    async with aiohttp.ClientSession() as s:
        async with s.get(url) as resp:
            data = await resp.text()
```

### 2. Fire-and-Forget Tasks

```python
# WRONG: task may be GC'd, errors silently lost
async def bad():
    asyncio.create_task(background_work())

# CORRECT: track the task
async def good():
    task = asyncio.create_task(background_work())
    background_tasks.add(task)
    task.add_done_callback(background_tasks.discard)
```

### 3. Missing await

```python
# WRONG: coroutine is created but never executed
async def bad():
    fetch_data()  # RuntimeWarning: coroutine never awaited

# CORRECT
async def good():
    await fetch_data()
```

### 4. Unhandled gather failures

```python
# WRONG: one failure may go unnoticed
results = await asyncio.gather(task_a(), task_b())

# CORRECT: use TaskGroup or return_exceptions
results = await asyncio.gather(task_a(), task_b(), return_exceptions=True)
```

---

## Integration with Synchronous Code

### Run Blocking Code in Async Context

```python
# Python 3.9+
result = await asyncio.to_thread(blocking_io_function, arg1, arg2)

# CPU-bound with ProcessPoolExecutor
from concurrent.futures import ProcessPoolExecutor
loop = asyncio.get_running_loop()
with ProcessPoolExecutor() as pool:
    result = await loop.run_in_executor(pool, heavy_computation, data)
```

### Call Async from Sync Code

```python
# Top-level entry
asyncio.run(main())

# From another thread with a running loop:
future = asyncio.run_coroutine_threadsafe(async_work(), loop)
result = future.result(timeout=10)
```
