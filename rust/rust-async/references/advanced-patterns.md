# Advanced Rust Async Patterns

## Table of Contents
- [Custom Future Implementations](#custom-future-implementations)
- [Pin Deep Dive](#pin-deep-dive)
- [Async Trait Methods (RPITIT)](#async-trait-methods-rpitit)
- [Tower Service Trait and Middleware](#tower-service-trait-and-middleware)
- [Connection Pooling](#connection-pooling)
- [Async State Machines](#async-state-machines)
- [Structured Concurrency with JoinSet](#structured-concurrency-with-joinset)
- [Task Cancellation Safety](#task-cancellation-safety)
- [Backpressure Patterns](#backpressure-patterns)
- [Async Closures](#async-closures)
- [Async Drop Workarounds](#async-drop-workarounds)
- [FuturesUnordered and Buffered Streams](#futuresunordered-and-buffered-streams)
- [Retry Patterns](#retry-patterns)
- [Circuit Breakers](#circuit-breakers)

---

## Custom Future Implementations

Implement `Future` manually when you need precise control over polling, state transitions, or zero-cost wrappers.

### Delay Future (Timer Example)
```rust
use std::future::Future;
use std::pin::Pin;
use std::task::{Context, Poll};
use std::time::{Duration, Instant};
use tokio::time::Sleep;

/// A future that completes after a duration, returning elapsed time.
struct Delay {
    deadline: Instant,
    sleep: Pin<Box<Sleep>>,
}

impl Delay {
    fn new(dur: Duration) -> Self {
        Self {
            deadline: Instant::now() + dur,
            sleep: Box::pin(tokio::time::sleep(dur)),
        }
    }
}

impl Future for Delay {
    type Output = Duration;

    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        match self.sleep.as_mut().poll(cx) {
            Poll::Ready(()) => Poll::Ready(self.deadline.elapsed() + Duration::from_nanos(0)),
            Poll::Pending => Poll::Pending,
        }
    }
}
```

### Fused Future (Polled at Most Once)
```rust
use std::future::Future;
use std::pin::Pin;
use std::task::{Context, Poll};

/// Wraps a future so it returns Poll::Pending forever after first completion.
struct Fuse<F> {
    inner: Option<F>,
}

impl<F: Future + Unpin> Future for Fuse<F> {
    type Output = F::Output;

    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        match self.inner.as_mut() {
            Some(f) => match Pin::new(f).poll(cx) {
                Poll::Ready(val) => {
                    self.inner = None;
                    Poll::Ready(val)
                }
                Poll::Pending => Poll::Pending,
            },
            None => Poll::Pending, // Already completed
        }
    }
}
```

### Yield-Once Future
```rust
/// Yields to the runtime exactly once, then completes.
struct YieldNow(bool);

impl Future for YieldNow {
    type Output = ();
    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<()> {
        if self.0 {
            Poll::Ready(())
        } else {
            self.0 = true;
            cx.waker().wake_by_ref(); // Schedule re-poll immediately
            Poll::Pending
        }
    }
}
```

**Key rules for custom futures:**
- Always register the waker via `cx.waker()` before returning `Pending`.
- Never block in `poll()`. Return `Pending` and arrange for a wakeup.
- Futures must be safe to drop at any suspension point.

---

## Pin Deep Dive

### Why Pin Exists
Async state machines are self-referential: after an `.await` point, the compiler-generated future may hold references to its own local variables. Moving such a value invalidates those internal references. `Pin<P>` prevents the pointee from being moved.

### Pin Projection with pin-project
```rust
use pin_project::pin_project;

#[pin_project]
struct TimedFuture<F> {
    #[pin]    // This field is pinned (for futures/streams)
    inner: F,
    started: Instant, // This field is NOT pinned (plain data)
}

impl<F: Future> Future for TimedFuture<F> {
    type Output = (F::Output, Duration);

    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        let this = self.project(); // Safe pin projection
        // this.inner: Pin<&mut F>   — pinned access
        // this.started: &mut Instant — mutable reference
        match this.inner.poll(cx) {
            Poll::Ready(val) => Poll::Ready((val, this.started.elapsed())),
            Poll::Pending => Poll::Pending,
        }
    }
}
```

### Stack Pinning with pin_mut! / pin!
```rust
use tokio::pin;

async fn example() {
    let fut = some_async_fn();
    pin!(fut); // fut is now Pin<&mut impl Future> on the stack
    // Can now pass to select!, poll manually, etc.

    tokio::select! {
        result = &mut fut => println!("{result:?}"),
        _ = tokio::time::sleep(Duration::from_secs(5)) => {
            // fut not yet done, but still valid — can retry in next iteration
        }
    }
}
```

### Pin Safety Rules
| Operation | Allowed? | Why |
|-----------|----------|-----|
| `Pin::new(&mut val)` where `T: Unpin` | ✅ | Unpin types can move freely |
| `Pin::new_unchecked(&mut val)` | ⚠️ unsafe | You guarantee it won't move |
| Moving out of `Pin<Box<T>>` | ❌ | Violates pinning invariant |
| `pin_project` field access | ✅ | Crate enforces projection safety |
| Swapping pinned values | ❌ | Would move the pointee |

### When to Use What
- **`Box::pin(fut)`**: Heap-pin when storing futures in collections or returning `Pin<Box<dyn Future>>`.
- **`tokio::pin!(fut)` / `std::pin::pin!(fut)`**: Stack-pin for `select!` branches or manual polling.
- **`pin_project`**: When implementing Future/Stream on structs containing pinned fields.
- **`Unpin`**: Most types. If your type is `Unpin`, pinning is a no-op.

---

## Async Trait Methods (RPITIT)

### Rust 1.75+ Native Async Traits
Rust 1.75 stabilized return-position `impl Trait` in traits (RPITIT), enabling native async trait methods:

```rust
// Native async trait — no macro needed (Rust 1.75+)
trait Repository {
    async fn find(&self, id: u64) -> Option<Record>;
    async fn save(&self, record: &Record) -> Result<(), Error>;
}

struct PgRepository { pool: sqlx::PgPool }

impl Repository for PgRepository {
    async fn find(&self, id: u64) -> Option<Record> {
        sqlx::query_as("SELECT * FROM records WHERE id = $1")
            .bind(id as i64)
            .fetch_optional(&self.pool)
            .await
            .ok()
            .flatten()
    }

    async fn save(&self, record: &Record) -> Result<(), Error> {
        sqlx::query("INSERT INTO records (id, data) VALUES ($1, $2)")
            .bind(record.id as i64)
            .bind(&record.data)
            .execute(&self.pool)
            .await?;
        Ok(())
    }
}
```

### Limitations and When to Use `async-trait`
Native async traits have limitations in some scenarios:

```rust
// ❌ Native async traits can't be used as trait objects by default
// The returned future's type is unnameable and not dyn-compatible
fn use_repo(repo: &dyn Repository) { /* compile error */ }

// ✅ Use #[async_trait] when you NEED trait objects (dyn dispatch)
#[async_trait::async_trait]
trait DynRepository: Send + Sync {
    async fn find(&self, id: u64) -> Option<Record>;
}
// This desugars to -> Pin<Box<dyn Future<Output = ...> + Send + '_>>
// Heap-allocates each call, but enables dyn Repository
```

### Send Bounds with Async Traits
```rust
// Native async traits: returned future is Send if all captured data is Send
trait SendService {
    // Add Send bound explicitly when needed for spawning
    fn process(&self, data: Data) -> impl Future<Output = Result<()>> + Send;
}

// With async-trait: Send is default, opt out with #[async_trait(?Send)]
#[async_trait::async_trait(?Send)]
trait LocalService {
    async fn process(&self, data: Data) -> Result<()>;
}
```

---

## Tower Service Trait and Middleware

### The Service Trait
Tower's `Service` trait is the foundation for all middleware/request processing:

```rust
pub trait Service<Request> {
    type Response;
    type Error;
    type Future: Future<Output = Result<Self::Response, Self::Error>>;

    fn poll_ready(&mut self, cx: &mut Context<'_>) -> Poll<Result<(), Self::Error>>;
    fn call(&mut self, req: Request) -> Self::Future;
}
```

### Building Custom Middleware
```rust
use tower::{Layer, Service};
use std::task::{Context, Poll};
use std::time::Instant;

// 1. Define the Layer (factory)
#[derive(Clone)]
struct TimingLayer;

impl<S> Layer<S> for TimingLayer {
    type Service = TimingService<S>;
    fn layer(&self, inner: S) -> Self::Service {
        TimingService { inner }
    }
}

// 2. Define the Service (wrapper)
#[derive(Clone)]
struct TimingService<S> {
    inner: S,
}

impl<S, Req> Service<Req> for TimingService<S>
where
    S: Service<Req>,
    S::Future: Send + 'static,
    S::Response: Send + 'static,
    S::Error: Send + 'static,
{
    type Response = S::Response;
    type Error = S::Error;
    type Future = Pin<Box<dyn Future<Output = Result<S::Response, S::Error>> + Send>>;

    fn poll_ready(&mut self, cx: &mut Context<'_>) -> Poll<Result<(), Self::Error>> {
        self.inner.poll_ready(cx)
    }

    fn call(&mut self, req: Req) -> Self::Future {
        let start = Instant::now();
        let fut = self.inner.call(req);
        Box::pin(async move {
            let result = fut.await;
            tracing::info!(elapsed_ms = %start.elapsed().as_millis(), "request processed");
            result
        })
    }
}

// 3. Apply to axum Router
let app = Router::new()
    .route("/api", get(handler))
    .layer(TimingLayer);
```

### tower::ServiceBuilder — Composing Layers
```rust
use tower::ServiceBuilder;
use tower_http::{trace::TraceLayer, timeout::TimeoutLayer, limit::ConcurrencyLimitLayer};

let app = Router::new()
    .route("/api", get(handler))
    .layer(
        ServiceBuilder::new()
            .layer(TraceLayer::new_for_http())
            .layer(TimeoutLayer::new(Duration::from_secs(30)))
            .layer(ConcurrencyLimitLayer::new(100))
            // Layers execute top-to-bottom on request, bottom-to-top on response
    );
```

---

## Connection Pooling

### bb8 (Async Connection Pool)
```rust
use bb8::Pool;
use bb8_postgres::PostgresConnectionManager;
use tokio_postgres::NoTls;

let manager = PostgresConnectionManager::new_from_stringlike(
    "host=localhost dbname=myapp user=postgres", NoTls
)?;
let pool = Pool::builder()
    .max_size(20)
    .min_idle(Some(5))
    .connection_timeout(Duration::from_secs(5))
    .idle_timeout(Some(Duration::from_secs(300)))
    .build(manager)
    .await?;

// Use a connection from the pool
let conn = pool.get().await?; // Returns to pool on drop
let rows = conn.query("SELECT * FROM users WHERE id = $1", &[&user_id]).await?;
```

### deadpool (Alternative Pool)
```rust
use deadpool_postgres::{Config, Runtime, Pool};
use tokio_postgres::NoTls;

let mut cfg = Config::new();
cfg.host = Some("localhost".into());
cfg.dbname = Some("myapp".into());
cfg.user = Some("postgres".into());
let pool: Pool = cfg.create_pool(Some(Runtime::Tokio1), NoTls)?;

let client = pool.get().await?;
let row = client.query_one("SELECT 1 + 1 AS result", &[]).await?;
```

### sqlx Built-in Pooling
```rust
use sqlx::postgres::PgPoolOptions;

let pool = PgPoolOptions::new()
    .max_connections(20)
    .min_connections(5)
    .acquire_timeout(Duration::from_secs(5))
    .idle_timeout(Duration::from_secs(300))
    .max_lifetime(Duration::from_secs(1800))
    .connect("postgres://postgres@localhost/myapp")
    .await?;

// Compile-time checked queries
let user = sqlx::query_as!(User, "SELECT * FROM users WHERE id = $1", id)
    .fetch_optional(&pool)
    .await?;
```

**Pool sizing rule of thumb:** `connections = (2 * CPU cores) + disk spindles`. For SSDs, start with `CPU cores * 2` and benchmark.

---

## Async State Machines

Encode protocol states in the type system to prevent illegal transitions:

```rust
// Type-state pattern for an async connection
struct Disconnected;
struct Connected { stream: TcpStream }
struct Authenticated { stream: TcpStream, token: String }

struct Connection<S> { state: S }

impl Connection<Disconnected> {
    async fn connect(self, addr: &str) -> Result<Connection<Connected>> {
        let stream = TcpStream::connect(addr).await?;
        Ok(Connection { state: Connected { stream } })
    }
}

impl Connection<Connected> {
    async fn authenticate(mut self, creds: &Credentials) -> Result<Connection<Authenticated>> {
        let token = send_auth(&mut self.state.stream, creds).await?;
        Ok(Connection { state: Authenticated { stream: self.state.stream, token } })
    }
}

impl Connection<Authenticated> {
    async fn query(&mut self, sql: &str) -> Result<Vec<Row>> {
        send_query(&mut self.state.stream, &self.state.token, sql).await
    }
}

// Usage — compiler enforces correct ordering:
let conn = Connection { state: Disconnected }
    .connect("localhost:5432").await?
    .authenticate(&creds).await?;
let rows = conn.query("SELECT 1").await?;
```

### Enum-Based State Machine with Async Transitions
```rust
enum DownloadState {
    Idle,
    Downloading { progress: f64, handle: JoinHandle<Vec<u8>> },
    Complete { data: Vec<u8> },
    Failed { error: String, retries: u32 },
}

impl DownloadState {
    async fn step(self, url: &str) -> Self {
        match self {
            Self::Idle => {
                let url = url.to_string();
                let handle = tokio::spawn(async move {
                    reqwest::get(&url).await.unwrap().bytes().await.unwrap().to_vec()
                });
                Self::Downloading { progress: 0.0, handle }
            }
            Self::Downloading { handle, .. } => match handle.await {
                Ok(data) => Self::Complete { data },
                Err(e) => Self::Failed { error: e.to_string(), retries: 0 },
            },
            Self::Failed { retries, .. } if retries < 3 => Self::Idle, // Retry
            other => other,
        }
    }
}
```

---

## Structured Concurrency with JoinSet

### Spawn with Abort-on-Drop
```rust
use tokio::task::JoinSet;

async fn fetch_all(urls: Vec<String>) -> Vec<Result<String, reqwest::Error>> {
    let mut set = JoinSet::new();

    for url in urls {
        set.spawn(async move {
            reqwest::get(&url).await?.text().await
        });
    }

    let mut results = Vec::new();
    while let Some(res) = set.join_next().await {
        match res {
            Ok(Ok(body)) => results.push(Ok(body)),
            Ok(Err(e)) => results.push(Err(e)),
            Err(join_err) => eprintln!("Task panicked: {join_err}"),
        }
    }
    results
    // If this function is cancelled, JoinSet drops → all tasks aborted
}
```

### JoinSet with Abort on First Error
```rust
async fn fetch_all_or_fail(urls: Vec<String>) -> Result<Vec<String>> {
    let mut set = JoinSet::new();
    for url in urls {
        set.spawn(async move { reqwest::get(&url).await?.text().await });
    }

    let mut results = Vec::new();
    while let Some(res) = set.join_next().await {
        match res {
            Ok(Ok(body)) => results.push(body),
            Ok(Err(e)) => {
                set.abort_all(); // Cancel remaining tasks
                return Err(e.into());
            }
            Err(join_err) => {
                set.abort_all();
                return Err(anyhow::anyhow!("task panicked: {join_err}"));
            }
        }
    }
    Ok(results)
}
```

### Bounded Concurrency with JoinSet
```rust
async fn bounded_fetch(urls: Vec<String>, max_concurrent: usize) -> Vec<String> {
    let mut set = JoinSet::new();
    let mut results = Vec::new();
    let mut url_iter = urls.into_iter();

    // Fill initial batch
    for url in url_iter.by_ref().take(max_concurrent) {
        set.spawn(async move { reqwest::get(&url).await?.text().await });
    }

    // As each completes, spawn next
    while let Some(res) = set.join_next().await {
        if let Ok(Ok(body)) = res {
            results.push(body);
        }
        if let Some(url) = url_iter.next() {
            set.spawn(async move { reqwest::get(&url).await?.text().await });
        }
    }
    results
}
```

---

## Task Cancellation Safety

A future is **cancellation-safe** if dropping it at any `.await` point doesn't lose data or leave inconsistent state.

### Cancellation-Safe vs Unsafe Operations
| Operation | Safe? | Why |
|-----------|-------|-----|
| `tokio::sync::mpsc::Receiver::recv()` | ✅ | No data lost on drop |
| `tokio::io::AsyncReadExt::read()` | ✅ | Partial read data in buffer |
| `tokio::sync::Mutex::lock()` | ✅ | Just stops waiting |
| `futures::StreamExt::next()` | ❌ | May lose an item |
| `tokio::io::AsyncReadExt::read_exact()` | ❌ | Partial fill lost on cancel |
| Multi-step operations without checkpointing | ❌ | Intermediate state lost |

### Making Operations Cancellation-Safe
```rust
// UNSAFE: if cancelled between read and process, data is lost
async fn unsafe_pipeline(rx: &mut mpsc::Receiver<Data>) {
    let data = rx.recv().await.unwrap(); // step 1
    process(data).await;                  // step 2 — if cancelled here, data gone
}

// SAFE: use select! carefully, re-queue on cancellation
async fn safe_pipeline(rx: &mut mpsc::Receiver<Data>, token: &CancellationToken) {
    loop {
        tokio::select! {
            Some(data) = rx.recv() => {
                // Process to completion without further select! cancellation points
                process(data).await;
            }
            _ = token.cancelled() => break,
        }
    }
}
```

### Cancellation Guard Pattern
```rust
struct CancelGuard<T> {
    data: Option<T>,
    tx: mpsc::Sender<T>,
}

impl<T> Drop for CancelGuard<T> {
    fn drop(&mut self) {
        if let Some(data) = self.data.take() {
            // Re-queue data if we're dropped before processing
            let _ = self.tx.try_send(data);
        }
    }
}

async fn cancellation_safe_process(rx: &mut mpsc::Receiver<Data>, tx: mpsc::Sender<Data>) {
    if let Some(data) = rx.recv().await {
        let mut guard = CancelGuard { data: Some(data), tx };
        process(guard.data.as_ref().unwrap()).await;
        guard.data = None; // Mark as processed — drop won't re-queue
    }
}
```

---

## Backpressure Patterns

### Bounded Channels (Primary Mechanism)
```rust
// Producer slows down when buffer is full
let (tx, mut rx) = mpsc::channel::<Work>(100);

// Producer — send().await blocks when at capacity
tokio::spawn(async move {
    for item in work_items {
        tx.send(item).await.unwrap(); // Backpressure here
    }
});
```

### Semaphore-Based Concurrency Limiting
```rust
let semaphore = Arc::new(Semaphore::new(50)); // Max 50 concurrent ops

async fn rate_limited_fetch(sem: &Semaphore, url: &str) -> Result<String> {
    let _permit = sem.acquire().await?; // Wait for capacity
    let resp = reqwest::get(url).await?.text().await?;
    Ok(resp) // Permit released on drop
}
```

### Token Bucket Rate Limiter
```rust
use governor::{Quota, RateLimiter};
use std::num::NonZeroU32;

let limiter = RateLimiter::direct(Quota::per_second(NonZeroU32::new(100).unwrap()));

async fn rate_limited_call(limiter: &RateLimiter</* ... */>) {
    limiter.until_ready().await; // Blocks until token available
    do_api_call().await;
}
```

---

## Async Closures

### Current Pattern (Fn returning Future)
```rust
// Async closures don't have stable syntax yet. Use closures returning futures:
async fn retry<F, Fut, T, E>(f: F, max_retries: u32) -> Result<T, E>
where
    F: Fn() -> Fut,
    Fut: Future<Output = Result<T, E>>,
{
    let mut attempts = 0;
    loop {
        match f().await {
            Ok(val) => return Ok(val),
            Err(e) if attempts < max_retries => {
                attempts += 1;
                tokio::time::sleep(Duration::from_millis(100 * attempts as u64)).await;
            }
            Err(e) => return Err(e),
        }
    }
}

// Usage
retry(|| async { reqwest::get("https://api.example.com").await }, 3).await?;
```

### Move Semantics with Async Closures
```rust
let client = reqwest::Client::new();
let urls: Vec<String> = get_urls();

// Clone what the closure captures
let fetcher = {
    let client = client.clone();
    move |url: String| {
        let client = client.clone(); // Clone again for each invocation
        async move {
            client.get(&url).send().await?.text().await
        }
    }
};

let results = futures::future::join_all(urls.into_iter().map(fetcher)).await;
```

---

## Async Drop Workarounds

Rust doesn't support `async fn drop()`. Here are practical workarounds:

### Explicit Async Cleanup Method
```rust
struct DbConnection { pool: PgPool, temp_table: String }

impl DbConnection {
    /// Must be called before dropping to clean up temp tables.
    async fn close(self) -> Result<()> {
        sqlx::query(&format!("DROP TABLE IF EXISTS {}", self.temp_table))
            .execute(&self.pool)
            .await?;
        Ok(())
    }
}

// Usage — wrap in a scope guard
async fn use_connection(pool: &PgPool) -> Result<()> {
    let conn = DbConnection::new(pool).await?;
    let result = do_work(&conn).await;
    conn.close().await?; // Explicit async cleanup
    result
}
```

### Spawn Cleanup in Synchronous Drop
```rust
impl Drop for DbConnection {
    fn drop(&mut self) {
        let pool = self.pool.clone();
        let table = std::mem::take(&mut self.temp_table);
        // Fire-and-forget cleanup task
        tokio::spawn(async move {
            let _ = sqlx::query(&format!("DROP TABLE IF EXISTS {table}"))
                .execute(&pool)
                .await;
        });
    }
}
```

### AsyncDrop Guard Pattern
```rust
struct AsyncDropGuard<F: Future<Output = ()>> {
    cleanup: Option<F>,
}

impl<F: Future<Output = ()>> AsyncDropGuard<F> {
    async fn run(mut self) {
        if let Some(f) = self.cleanup.take() {
            f.await;
        }
    }
}
```

---

## FuturesUnordered and Buffered Streams

### FuturesUnordered — Maximum Throughput
```rust
use futures::stream::{FuturesUnordered, StreamExt};

let mut futs = FuturesUnordered::new();
for url in &urls {
    futs.push(fetch(url));
}

// Process results as they complete (not in order)
while let Some(result) = futs.next().await {
    handle(result);
}
```

### Buffered Streams — Ordered with Concurrency Limit
```rust
use futures::stream::{self, StreamExt};

let results: Vec<_> = stream::iter(urls)
    .map(|url| async move { fetch(&url).await })
    .buffered(10)        // Max 10 concurrent, results IN ORDER
    .collect()
    .await;

// buffer_unordered: Max 10 concurrent, results as they complete
let results: Vec<_> = stream::iter(urls)
    .map(|url| async move { fetch(&url).await })
    .buffer_unordered(10)
    .collect()
    .await;
```

### FuturesUnordered vs JoinSet
| Feature | FuturesUnordered | JoinSet |
|---------|-----------------|---------|
| Spawns on runtime | ❌ (polled in current task) | ✅ (each is a tokio task) |
| Send bound required | ❌ | ✅ |
| Cancel on drop | ❌ (futures dropped) | ✅ (tasks aborted) |
| Work stealing | ❌ | ✅ |
| Best for | CPU-light I/O futures | CPU-heavy or many futures |

---

## Retry Patterns

### Manual Exponential Backoff
```rust
async fn retry_with_backoff<F, Fut, T, E>(
    f: F,
    max_retries: u32,
    base_delay: Duration,
) -> Result<T, E>
where
    F: Fn() -> Fut,
    Fut: Future<Output = Result<T, E>>,
    E: std::fmt::Display,
{
    let mut delay = base_delay;
    for attempt in 0..=max_retries {
        match f().await {
            Ok(val) => return Ok(val),
            Err(e) if attempt < max_retries => {
                tracing::warn!(attempt, error = %e, "retrying after {delay:?}");
                tokio::time::sleep(delay).await;
                delay = delay.mul_f64(2.0).min(Duration::from_secs(30)); // Cap at 30s
            }
            Err(e) => return Err(e),
        }
    }
    unreachable!()
}
```

### Using the `backon` Crate
```rust
use backon::{ExponentialBuilder, Retryable};

let content = (|| async { reqwest::get("https://api.example.com").await?.text().await })
    .retry(ExponentialBuilder::default()
        .with_min_delay(Duration::from_millis(100))
        .with_max_delay(Duration::from_secs(10))
        .with_max_times(5))
    .await?;
```

### Tower Retry Middleware
```rust
use tower::retry::{Retry, Policy};

#[derive(Clone)]
struct RetryPolicy { max_retries: usize }

impl<Req: Clone, Res, E> Policy<Req, Res, E> for RetryPolicy {
    type Future = futures::future::Ready<()>;

    fn retry(&mut self, _req: &mut Req, result: &mut Result<Res, E>) -> Option<Self::Future> {
        if self.max_retries > 0 && result.is_err() {
            self.max_retries -= 1;
            Some(futures::future::ready(()))
        } else {
            None
        }
    }

    fn clone_request(&mut self, req: &Req) -> Option<Req> {
        Some(req.clone())
    }
}
```

---

## Circuit Breakers

Prevent cascading failures by stopping calls to unhealthy services:

```rust
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::sync::Arc;

#[derive(Clone)]
struct CircuitBreaker {
    failure_count: Arc<AtomicU32>,
    last_failure: Arc<AtomicU64>,
    threshold: u32,
    reset_timeout: Duration,
}

#[derive(Debug, PartialEq)]
enum CircuitState { Closed, Open, HalfOpen }

impl CircuitBreaker {
    fn new(threshold: u32, reset_timeout: Duration) -> Self {
        Self {
            failure_count: Arc::new(AtomicU32::new(0)),
            last_failure: Arc::new(AtomicU64::new(0)),
            threshold,
            reset_timeout,
        }
    }

    fn state(&self) -> CircuitState {
        let failures = self.failure_count.load(Ordering::Relaxed);
        if failures < self.threshold {
            return CircuitState::Closed;
        }
        let last = self.last_failure.load(Ordering::Relaxed);
        let elapsed = Duration::from_millis(
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH).unwrap()
                .as_millis() as u64 - last
        );
        if elapsed > self.reset_timeout {
            CircuitState::HalfOpen
        } else {
            CircuitState::Open
        }
    }

    async fn call<F, Fut, T, E>(&self, f: F) -> Result<T, CircuitError<E>>
    where
        F: FnOnce() -> Fut,
        Fut: Future<Output = Result<T, E>>,
    {
        match self.state() {
            CircuitState::Open => Err(CircuitError::Open),
            state => {
                match f().await {
                    Ok(val) => {
                        if state == CircuitState::HalfOpen {
                            self.failure_count.store(0, Ordering::Relaxed);
                        }
                        Ok(val)
                    }
                    Err(e) => {
                        self.failure_count.fetch_add(1, Ordering::Relaxed);
                        let now = std::time::SystemTime::now()
                            .duration_since(std::time::UNIX_EPOCH).unwrap()
                            .as_millis() as u64;
                        self.last_failure.store(now, Ordering::Relaxed);
                        Err(CircuitError::Inner(e))
                    }
                }
            }
        }
    }
}

#[derive(Debug)]
enum CircuitError<E> {
    Open,
    Inner(E),
}
```

**Usage:**
```rust
let breaker = CircuitBreaker::new(5, Duration::from_secs(30));

match breaker.call(|| fetch_from_service()).await {
    Ok(data) => process(data),
    Err(CircuitError::Open) => use_fallback(),
    Err(CircuitError::Inner(e)) => handle_error(e),
}
```
