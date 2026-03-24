---
name: rust-async
description: >
  USE when writing Rust async/await code, tokio runtime, Future trait, Pin/Unpin,
  async I/O, channels (mpsc/oneshot/broadcast/watch), tokio::spawn, JoinSet,
  select!/join!, async streams, axum/reqwest/tower HTTP, graceful shutdown,
  CancellationToken, tracing instrumentation, spawn_blocking, async tests,
  async error handling, or diagnosing Send bounds / hold-lock-across-await bugs.
  USE when Cargo.toml includes tokio, futures, async-trait, tower, axum, reqwest,
  hyper, tokio-util, tokio-stream, or tracing.
  DO NOT USE for synchronous Rust, general Rust ownership/borrowing questions,
  Zig, Go, C++ coroutines, or JavaScript async/Promise patterns.
  DO NOT USE for Rust GUI frameworks, embedded no_std, or WASM-only async runtimes.
---

# Rust Async Patterns

## Async Fundamentals

### Future Trait and Poll
Every async fn desugars to a state machine implementing `Future`. Core signature:
```rust
pub trait Future {
    type Output;
    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output>;
}
// Poll::Ready(val) — done. Poll::Pending — not yet, runtime re-polls via Waker in cx.
```

### Pin, Unpin, async/await
- `Pin<&mut T>` guarantees the pointee won't move. Required for self-referential async state machines.
- Most types are `Unpin` (safe to move when pinned). Use `pin_project` crate for safe projections.
- `Box::pin(future)` for heap pinning. `tokio::pin!(fut)` / `std::pin::pin!(fut)` for stack pinning.
- `async fn foo() -> T` returns `impl Future<Output = T>`. Nothing runs until `.await`ed or polled.
- `.await` suspends the task, yields to runtime. Every `.await` is a suspension/resumption boundary.

## Tokio Runtime

### Configuration
```rust
#[tokio::main]                                    // multi-thread default
async fn main() { /* ... */ }
#[tokio::main(flavor = "current_thread")]          // single-threaded
async fn main() { /* ... */ }

// Manual construction with tuning
let rt = tokio::runtime::Builder::new_multi_thread()
    .worker_threads(4).enable_all().build().unwrap();
rt.block_on(async { /* ... */ });
```
- `rt-multi-thread`: Work-stealing scheduler. Use for servers, I/O-heavy workloads.
- `current_thread`: No Send requirement on spawned futures. Use for CLI tools, tests.

## Spawning Tasks

### tokio::spawn
```rust
let handle: tokio::task::JoinHandle<String> = tokio::spawn(async {
    // This runs concurrently. The future MUST be Send + 'static.
    "result".to_string()
});
let result = handle.await.unwrap(); // JoinError if task panics
```

### JoinSet — Managing Groups of Tasks
```rust
use tokio::task::JoinSet;

let mut set = JoinSet::new();
for i in 0..10 {
    set.spawn(async move { i * 2 });
}
while let Some(res) = set.join_next().await {
    println!("Got: {}", res.unwrap());
}
```
Use `JoinSet` over collecting `Vec<JoinHandle>` — it handles cancellation on drop and provides structured concurrency.

### spawn_blocking — Offloading CPU/Blocking Work
```rust
let result = tokio::task::spawn_blocking(|| {
    // Runs on a dedicated blocking thread pool.
    // Use for CPU-heavy computation, synchronous I/O, or FFI calls.
    expensive_sync_computation()
}).await.unwrap();
```
Never call blocking code directly on the async runtime — it starves other tasks.

## Channels

### mpsc — Multi-Producer, Single-Consumer
```rust
let (tx, mut rx) = tokio::sync::mpsc::channel::<String>(100); // bounded
let tx2 = tx.clone(); // clone for additional producers
tokio::spawn(async move { tx.send("hello".into()).await.unwrap(); });
tokio::spawn(async move { tx2.send("world".into()).await.unwrap(); });
// Receiver
while let Some(msg) = rx.recv().await {
    println!("{msg}");
}
```
Use bounded channels (with backpressure) in production. Unbounded channels risk OOM.

### oneshot — Single-Value Response
```rust
let (tx, rx) = tokio::sync::oneshot::channel::<u64>();
tokio::spawn(async move { tx.send(42).unwrap(); });
let val = rx.await.unwrap(); // 42
```
Pattern: attach a oneshot::Sender to mpsc commands for request/response (actor model).

### broadcast — Multi-Consumer Fan-Out
```rust
let (tx, _) = tokio::sync::broadcast::channel::<String>(16);
let mut rx1 = tx.subscribe();
let mut rx2 = tx.subscribe();
tx.send("event".into()).unwrap();
assert_eq!(rx1.recv().await.unwrap(), "event");
assert_eq!(rx2.recv().await.unwrap(), "event");
```

### watch — Latest-Value Sharing
```rust
let (tx, mut rx) = tokio::sync::watch::channel("initial");
tx.send("updated").unwrap();
rx.changed().await.unwrap();
assert_eq!(*rx.borrow(), "updated");
```
Use for configuration/state that consumers only need the latest value of.

## Synchronization Primitives

### tokio::sync::Mutex vs std::sync::Mutex
- Use `tokio::sync::Mutex` when you need to hold the lock across `.await` points.
- Use `std::sync::Mutex` (wrapped in `Arc`) when the critical section is short and synchronous — it's faster and doesn't require `.await` to lock.
- **NEVER hold std::sync::Mutex across an .await point** — it blocks the runtime thread.

```rust
// tokio Mutex — safe across await
let data = Arc::new(tokio::sync::Mutex::new(vec![]));
let d = data.clone();
tokio::spawn(async move {
    let mut lock = d.lock().await;
    lock.push(fetch_data().await); // OK: holding across await
});

// std Mutex — fast synchronous access
let data = Arc::new(std::sync::Mutex::new(0u64));
let d = data.clone();
tokio::spawn(async move {
    *d.lock().unwrap() += 1; // OK: no await while held
});
```

### RwLock, Semaphore, Notify
```rust
// RwLock — multiple readers OR one writer
let lock = tokio::sync::RwLock::new(HashMap::new());
let r = lock.read().await;
drop(r);
let mut w = lock.write().await;

// Semaphore — limit concurrent access
let sem = Arc::new(tokio::sync::Semaphore::new(10));
let permit = sem.acquire().await.unwrap();
drop(permit);

// Notify — wake waiting tasks
let notify = Arc::new(tokio::sync::Notify::new());
let n = notify.clone();
tokio::spawn(async move { n.notified().await; });
notify.notify_one();
```

## Async I/O

### AsyncRead / AsyncWrite / tokio::fs
```rust
use tokio::io::{AsyncReadExt, AsyncWriteExt, BufReader};

let file = tokio::fs::File::open("data.txt").await?;
let mut reader = BufReader::new(file);
let mut contents = String::new();
reader.read_to_string(&mut contents).await?;

let mut file = tokio::fs::File::create("out.txt").await?;
file.write_all(b"hello async").await?;
```
Always use `tokio::fs` instead of `std::fs` in async contexts.

## TCP / UDP Networking

```rust
use tokio::net::{TcpListener, TcpStream};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

let listener = TcpListener::bind("0.0.0.0:8080").await?;
loop {
    let (mut socket, _addr) = listener.accept().await?;
    tokio::spawn(async move {
        let mut buf = [0u8; 1024];
        let n = socket.read(&mut buf).await.unwrap();
        socket.write_all(&buf[..n]).await.unwrap();
    });
}
```

## Select and Join

### tokio::select! — Race Multiple Futures
```rust
tokio::select! {
    val = async_op_a() => println!("A: {val:?}"),
    val = async_op_b() => println!("B: {val:?}"),
    _ = tokio::time::sleep(Duration::from_secs(5)) => println!("timeout"),
}
// First branch to complete runs. Others are DROPPED (cancelled).
// Add `biased;` as first token to check branches in order (prioritize shutdown signals).
```

### tokio::join! and futures::join_all
```rust
let (a, b, c) = tokio::join!(fetch_a(), fetch_b(), fetch_c());

// Dynamic number of futures
let futures: Vec<_> = urls.iter().map(|u| fetch(u)).collect();
let results: Vec<_> = futures::future::join_all(futures).await;

// try_join! — short-circuit on first error
let (a, b) = tokio::try_join!(fallible_a(), fallible_b())?;
```

## Timeouts and Intervals

```rust
use tokio::time::{timeout, sleep, interval, Duration};

// Timeout — wrap any future with a deadline
match timeout(Duration::from_secs(5), slow_operation()).await {
    Ok(result) => println!("completed: {result:?}"),
    Err(_) => eprintln!("timed out"),
}

// Interval — periodic ticks (use MissedTickBehavior::Skip to avoid bursts)
let mut tick = interval(Duration::from_secs(1));
loop { tick.tick().await; do_periodic_work().await; }
```

## Streams

```rust
use tokio_stream::{StreamExt, wrappers::IntervalStream};

let stream = IntervalStream::new(tokio::time::interval(Duration::from_millis(100)));
let mut stream = stream.take(5);
while let Some(_instant) = stream.next().await { println!("tick"); }

// async-stream crate for generator-like syntax
use async_stream::stream;
let s = stream! { for i in 0..3 { yield fetch_item(i).await; } };
tokio::pin!(s);
while let Some(item) = s.next().await { /* ... */ }
```

## Error Handling

### Pattern: thiserror for Libraries, anyhow for Applications
```rust
#[derive(Debug, thiserror::Error)]
enum AppError {
    #[error("database error: {0}")]
    Db(#[from] sqlx::Error),
    #[error("HTTP error: {0}")]
    Http(#[from] reqwest::Error),
    #[error("not found: {0}")]
    NotFound(String),
}

async fn run() -> anyhow::Result<()> {
    let data = fetch_data().await.context("fetching data failed")?;
    process(data).await?;
    Ok(())
}
```

## HTTP: reqwest, axum, tower

### reqwest — Async HTTP Client
```rust
let client = reqwest::Client::new(); // reuse — it pools connections
let resp = client.get("https://api.example.com/data")
    .header("Authorization", "Bearer token")
    .timeout(Duration::from_secs(10))
    .send().await?.json::<serde_json::Value>().await?;
```

### axum — Async HTTP Server
```rust
use axum::{Router, routing::{get, post}, extract::{State, Json, Path}, response::IntoResponse};
use std::sync::Arc;
use tokio::sync::RwLock;

#[derive(Clone)]
struct AppState { db: Arc<RwLock<Vec<String>>> }

async fn list_items(State(state): State<AppState>) -> Json<Vec<String>> {
    Json(state.db.read().await.clone())
}

async fn create_item(
    State(state): State<AppState>,
    Json(item): Json<String>,
) -> impl IntoResponse {
    state.db.write().await.push(item);
    (axum::http::StatusCode::CREATED, "created")
}

#[tokio::main]
async fn main() {
    let state = AppState { db: Arc::new(RwLock::new(vec![])) };
    let app = Router::new()
        .route("/items", get(list_items).post(create_item))
        .with_state(state);
    let listener = tokio::net::TcpListener::bind("0.0.0.0:3000").await.unwrap();
    axum::serve(listener, app).await.unwrap();
}
```

### tower Middleware
```rust
use tower_http::{trace::TraceLayer, timeout::TimeoutLayer, cors::CorsLayer};
let app = Router::new()
    .route("/api", get(handler))
    .layer(TraceLayer::new_for_http())
    .layer(TimeoutLayer::new(Duration::from_secs(30)))
    .layer(CorsLayer::permissive());
// Layer order: last added wraps outermost (executes first on request, last on response).
```

## Graceful Shutdown

```rust
use tokio_util::sync::CancellationToken;
use tokio::signal;

#[tokio::main]
async fn main() {
    let token = CancellationToken::new();

    // Spawn signal listener
    let shutdown_token = token.clone();
    tokio::spawn(async move {
        signal::ctrl_c().await.unwrap();
        shutdown_token.cancel();
    });

    // Worker loop respects cancellation
    let worker_token = token.clone();
    let worker = tokio::spawn(async move {
        loop {
            tokio::select! {
                _ = worker_token.cancelled() => { break; }
                _ = do_work() => {}
            }
        }
        cleanup().await;
    });

    // Axum server with graceful shutdown
    let listener = tokio::net::TcpListener::bind("0.0.0.0:3000").await.unwrap();
    axum::serve(listener, app)
        .with_graceful_shutdown(async move { token.cancelled().await })
        .await.unwrap();

    worker.await.unwrap();
}
```
Pass `CancellationToken` children via `token.child_token()` for hierarchical shutdown.

## Testing Async Code

```rust
#[tokio::test]
async fn test_basic() { assert_eq!(my_async_fn().await, 42); }

#[tokio::test(flavor = "current_thread")]
async fn test_single_thread() { /* ... */ }

#[tokio::test(start_paused = true)] // mock time — sleeps resolve instantly
async fn test_with_mock_time() {
    let start = tokio::time::Instant::now();
    tokio::time::sleep(Duration::from_secs(60)).await;
    assert!(start.elapsed() >= Duration::from_secs(60)); // virtual time advanced
}
```

## Performance

### Task Budgeting and Yielding
Tokio preempts tasks after a poll budget. Long CPU loops should yield:
```rust
for item in large_collection {
    process(item);
    tokio::task::yield_now().await;
}
```

### spawn_blocking + rayon
```rust
let result = tokio::task::spawn_blocking(move || {
    use rayon::prelude::*;
    data.par_iter().map(|x| heavy_compute(x)).collect::<Vec<_>>()
}).await.unwrap();
```

### Performance Killers to Avoid
- Blocking the runtime (std::fs, std::net, heavy CPU without spawn_blocking)
- Unbounded channels (OOM under load) — always use bounded with backpressure
- Cloning large data across tasks — use `Arc` or channels

## Tracing and Observability

```rust
use tracing::{info, instrument};
use tracing_subscriber::{fmt, EnvFilter, layer::SubscriberExt, util::SubscriberInitExt};

tracing_subscriber::registry()
    .with(EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()))
    .with(fmt::layer().json())
    .init();

#[instrument(skip(db), fields(user_id = %user_id))]
async fn get_user(db: &Pool, user_id: u64) -> Result<User> {
    info!("fetching user");
    db.query("SELECT ...").await
}
// #[instrument] on async fns creates spans with timing. skip() large args. fields() adds context.
```

## Common Pitfalls

### 1. Holding a Lock Across .await
```rust
// BUG: std::sync::MutexGuard is NOT Send — compile error or deadlock
let guard = std_mutex.lock().unwrap();
async_call().await; // WRONG: guard held across await

// FIX: drop guard before await, or use tokio::sync::Mutex
{
    let mut guard = std_mutex.lock().unwrap();
    *guard += 1;
} // guard dropped
async_call().await;
```

### 2. Blocking in Async Context
```rust
// WRONG                                       // RIGHT
std::fs::read_to_string("f.txt").unwrap();     tokio::fs::read_to_string("f.txt").await?;
```

### 3. Send Bounds on Spawned Futures
`tokio::spawn` requires `Send + 'static`. Common fixes:
- Move owned data into the async block with `move`.
- Clone `Arc<T>` before the spawn, move the clone in.
- Don't hold non-Send guards (like `MutexGuard`) across `.await`.
- Use `current_thread` runtime if Send is impractical.

### 4. Forgetting to .await
Compiler warns "unused implementor of Future". Always `.await` or `tokio::spawn` async calls.

### 5. select! Cancellation Safety
Not all futures are cancellation-safe. `tokio::sync::mpsc::Receiver::recv` is safe; `futures::StreamExt::next` may not be. Check tokio docs per method.

## Additional Resources

### References (Deep Dives)

| File | Topics |
|------|--------|
| `references/advanced-patterns.md` | Custom Future impls, Pin projection, async traits (RPITIT Rust 1.75+), tower Service/middleware, connection pooling (bb8/deadpool/sqlx), async state machines, JoinSet structured concurrency, cancellation safety, backpressure, async closures, async drop workarounds, FuturesUnordered, buffered streams, retry patterns (backon, tower-retry), circuit breakers |
| `references/troubleshooting.md` | "future is not Send" fixes, lifetime issues, MutexGuard across await, blocking the runtime, task starvation, stack overflow in nested futures, tokio-console debugging, performance profiling, JoinHandle memory leaks, channel deadlocks, timeout gotchas, executor panics, trait object async limitations |
| `references/axum-guide.md` | Router (nested, merged, fallback), extractors (Path/Query/Json/State/custom), middleware (from_fn, tower layers, ordering), error handling (IntoResponse, thiserror/anyhow), WebSocket, SSE, multipart uploads, shared state patterns (Arc, sub-states), testing (oneshot, integration), tower-http deployment stack |

### Scripts (Executable Tools)

| Script | Purpose | Usage |
|--------|---------|-------|
| `scripts/async-project-init.sh` | Scaffold async Rust project (tokio+axum+sqlx+tracing) with full directory structure | `./scripts/async-project-init.sh my-api` |
| `scripts/tokio-bench.sh` | Benchmark spawn overhead, channel throughput, I/O latency | `./scripts/tokio-bench.sh [spawn\|channel\|io\|all]` |
| `scripts/check-async-issues.sh` | Detect async anti-patterns: blocking calls, locks across await, unbounded channels | `./scripts/check-async-issues.sh ./my-project` |

### Assets (Copy-Paste Templates)

| File | Description |
|------|-------------|
| `assets/Cargo.toml` | Production async deps: tokio, axum, sqlx, tower, tracing, reqwest, futures |
| `assets/main.rs` | Production main: tracing init, DB pool, graceful shutdown, axum server |
| `assets/error.rs` | Unified `AppError` with `IntoResponse`, thiserror variants, anyhow integration |
| `assets/middleware.rs` | Tower middleware: request ID, logging, JWT auth, rate limiting |

<!-- tested: pass -->
