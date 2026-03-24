# Rust Async Troubleshooting Guide

## Table of Contents
- [Future is Not Send Errors](#future-is-not-send-errors)
- [Lifetime Issues with Async](#lifetime-issues-with-async)
- [Holding MutexGuard Across Await](#holding-mutexguard-across-await)
- [Blocking the Runtime](#blocking-the-runtime)
- [Task Starvation](#task-starvation)
- [Stack Overflow in Deeply Nested Futures](#stack-overflow-in-deeply-nested-futures)
- [Debugging with tokio-console](#debugging-with-tokio-console)
- [Performance Profiling](#performance-profiling)
- [Memory Leaks from Forgotten JoinHandles](#memory-leaks-from-forgotten-joinhandles)
- [Channel Deadlocks](#channel-deadlocks)
- [Timeout Gotchas](#timeout-gotchas)
- [Executor Panics](#executor-panics)
- [Trait Object Limitations with Async](#trait-object-limitations-with-async)

---

## Future is Not Send Errors

### The Error
```
error: future cannot be sent between threads safely
   |     required by a bound in `tokio::spawn`
   |     within `impl Future<Output = ()>`, the trait `Send` is not implemented for `Rc<String>`
```

### Why It Happens
`tokio::spawn` requires the future to be `Send` because the multi-threaded runtime may move the task between worker threads. Any non-Send type held **across** an `.await` point prevents the entire future from being `Send`.

### Common Non-Send Types
| Type | Why | Fix |
|------|-----|-----|
| `Rc<T>` | Not thread-safe ref count | Use `Arc<T>` |
| `std::sync::MutexGuard` | OS mutex tied to thread | Scope the guard, use `tokio::sync::Mutex` |
| `Cell<T>`, `RefCell<T>` | Not thread-safe interior mutability | Use `Arc<Mutex<T>>` or atomics |
| `*mut T`, `*const T` | Raw pointers not Send | Wrap in a Send newtype (unsafe) |
| `dyn Trait` (without `+ Send`) | Trait object defaults | Add `+ Send` bound |

### Fixing Strategies

**Strategy 1: Scope non-Send values so they don't cross `.await`**
```rust
// ❌ MutexGuard held across await
async fn bad(data: &std::sync::Mutex<Vec<String>>) {
    let guard = data.lock().unwrap();
    let item = guard[0].clone();
    drop(guard); // Not enough — compiler sees guard's type in the future
    async_work(&item).await;
}

// ✅ Scope the guard in a block
async fn good(data: &std::sync::Mutex<Vec<String>>) {
    let item = {
        let guard = data.lock().unwrap();
        guard[0].clone()
    }; // guard dropped here, before any .await
    async_work(&item).await;
}
```

**Strategy 2: Use `current_thread` runtime**
```rust
// If Send is too restrictive (e.g., GUI integration)
#[tokio::main(flavor = "current_thread")]
async fn main() {
    // Spawned tasks don't need Send in single-threaded runtime
    let data = Rc::new("hello".to_string());
    tokio::task::spawn_local(async move {
        println!("{data}");
    });
}
```

**Strategy 3: Move owned data into the future**
```rust
// ❌ Borrowing non-Send data
let data = Rc::new(vec![1, 2, 3]);
tokio::spawn(async {
    println!("{:?}", data); // data is Rc — not Send
});

// ✅ Convert to Arc
let data = Arc::new(vec![1, 2, 3]);
tokio::spawn(async move {
    println!("{:?}", data); // Arc is Send
});
```

### Debugging Send Errors
The error message shows which type breaks `Send`. Look for the line mentioning "within `impl Future`... `Send` is not implemented for `SomeType`". Trace that type to where it's alive across an `.await`.

---

## Lifetime Issues with Async

### Borrowing Across Spawned Tasks
```rust
// ❌ Can't borrow local data in spawned task
async fn process(data: &str) {
    tokio::spawn(async {
        println!("{data}"); // ERROR: borrowed data in 'static future
    });
}

// ✅ Option 1: Own the data
async fn process(data: &str) {
    let owned = data.to_string();
    tokio::spawn(async move {
        println!("{owned}");
    });
}

// ✅ Option 2: Use Arc for shared data
async fn process(data: Arc<String>) {
    let data = data.clone();
    tokio::spawn(async move {
        println!("{data}");
    });
}

// ✅ Option 3: Use scope (tokio-scoped or async-scoped crate)
// Allows borrowing from the parent scope safely
```

### Async Functions Returning References
```rust
// ❌ Async fn can't return references to local data
async fn get_name() -> &str {
    let name = fetch_name().await;
    &name // ERROR: returns reference to local
}

// ✅ Return owned data
async fn get_name() -> String {
    fetch_name().await
}

// ✅ If borrowing from input, lifetime must be explicit
async fn get_field<'a>(record: &'a Record) -> &'a str {
    // OK: returned reference lives as long as input
    &record.name
}
```

### Self-Referential Futures
```rust
// This pattern creates a self-referential future:
async fn problematic() {
    let data = vec![1, 2, 3];
    let reference = &data[0]; // reference to local
    some_async_op().await;     // future holds both data AND reference
    println!("{reference}");   // this works — the compiler handles it via Pin
}
// The compiler generates a self-referential state machine.
// This is WHY Pin exists — to prevent moving the future while references are live.
```

---

## Holding MutexGuard Across Await

### The Problem
```rust
// ❌ Compile error with tokio::spawn, or deadlock with tokio::sync::Mutex
async fn bad(mutex: &std::sync::Mutex<Vec<u32>>) {
    let mut guard = mutex.lock().unwrap();
    guard.push(async_fetch().await); // Guard held across await!
    // With std::sync::Mutex: blocks the runtime thread
    // The future is NOT Send — can't use with tokio::spawn
}
```

### Solutions

**Solution 1: Scope the lock**
```rust
async fn good(mutex: &std::sync::Mutex<Vec<u32>>) {
    let value = async_fetch().await; // Do async work first
    mutex.lock().unwrap().push(value); // Then lock briefly
}
```

**Solution 2: Use tokio::sync::Mutex**
```rust
async fn good(mutex: &tokio::sync::Mutex<Vec<u32>>) {
    let mut guard = mutex.lock().await;
    guard.push(async_fetch().await); // OK with tokio Mutex
    // But: holds the lock for the entire async_fetch duration
    // Other tasks waiting on this mutex are blocked
}
```

**Solution 3: Clone-modify-replace**
```rust
async fn good(data: &Arc<std::sync::Mutex<Vec<u32>>>) {
    let current = data.lock().unwrap().clone(); // Clone under short lock
    let new_value = async_compute(&current).await;
    data.lock().unwrap().push(new_value); // Short lock to update
}
```

### Decision Tree
```
Need to hold lock across .await?
├── No → Use std::sync::Mutex (faster)
├── Yes, short duration → Use tokio::sync::Mutex
└── Yes, long duration → Restructure:
    ├── Actor pattern (channel + dedicated task)
    ├── RwLock if mostly reads
    └── Clone-modify-replace
```

---

## Blocking the Runtime

### Symptoms
- Other tasks stop making progress
- Timeouts fire unexpectedly
- Health checks fail
- Throughput drops to zero periodically

### Common Causes and Fixes

```rust
// ❌ Blocking file I/O
let data = std::fs::read_to_string("large.json")?;
// ✅
let data = tokio::fs::read_to_string("large.json").await?;

// ❌ Blocking DNS resolution
let addrs = std::net::ToSocketAddrs::to_socket_addrs(&"example.com:443")?;
// ✅
let addrs = tokio::net::lookup_host("example.com:443").await?;

// ❌ CPU-heavy computation
let hash = argon2::hash(password); // Takes 100ms+
// ✅
let hash = tokio::task::spawn_blocking(move || argon2::hash(password)).await?;

// ❌ Synchronous HTTP call
let resp = ureq::get("https://api.example.com").call()?;
// ✅
let resp = reqwest::get("https://api.example.com").await?;

// ❌ Thread::sleep
std::thread::sleep(Duration::from_secs(1));
// ✅
tokio::time::sleep(Duration::from_secs(1)).await;
```

### Detecting Blocking with tokio-console
```rust
// In Cargo.toml
[dependencies]
console-subscriber = "0.4"

// In main.rs
#[tokio::main]
async fn main() {
    console_subscriber::init(); // Replaces tracing_subscriber
    // ...
}
```
Run `tokio-console` in another terminal — it shows tasks that poll for too long.

---

## Task Starvation

### What It Is
Some tasks never get CPU time because other tasks monopolize the runtime threads.

### Causes
1. **Long-running poll**: A future that does heavy work in `poll()` without yielding.
2. **Too many CPU-bound tasks on the async runtime**: Saturates all worker threads.
3. **Unfair select!**: Using `biased;` with a hot branch that always wins.

### Fixes
```rust
// Yield periodically in CPU-heavy async loops
async fn process_large_batch(items: Vec<Item>) {
    for (i, item) in items.iter().enumerate() {
        process(item);
        if i % 100 == 0 {
            tokio::task::yield_now().await; // Let other tasks run
        }
    }
}

// Use spawn_blocking for CPU work
let result = tokio::task::spawn_blocking(move || {
    items.into_iter().map(|i| heavy_compute(i)).collect::<Vec<_>>()
}).await?;

// Use a dedicated runtime for CPU work
let cpu_runtime = tokio::runtime::Builder::new_multi_thread()
    .worker_threads(2)
    .thread_name("cpu-worker")
    .build()?;

let result = cpu_runtime.spawn(async move {
    // CPU-heavy work here won't starve the main runtime
}).await?;
```

---

## Stack Overflow in Deeply Nested Futures

### The Problem
Each `.await` adds to the future's state machine size. Deeply nested/recursive futures can overflow the stack.

```rust
// ❌ Recursive async — each level adds to future size
async fn traverse(node: &Node) -> u64 {
    let mut sum = node.value;
    for child in &node.children {
        sum += traverse(child).await; // Deep recursion = stack overflow
    }
    sum
}
```

### Solutions
```rust
// ✅ Box the recursive future to heap-allocate
fn traverse(node: &Node) -> Pin<Box<dyn Future<Output = u64> + '_>> {
    Box::pin(async move {
        let mut sum = node.value;
        for child in &node.children {
            sum += traverse(child).await;
        }
        sum
    })
}

// ✅ Convert recursion to iteration with an explicit stack
async fn traverse_iterative(root: &Node) -> u64 {
    let mut stack = vec![root];
    let mut sum = 0;
    while let Some(node) = stack.pop() {
        sum += node.value;
        stack.extend(&node.children);
    }
    sum
}

// ✅ Increase stack size for deeply nested futures
let rt = tokio::runtime::Builder::new_multi_thread()
    .thread_stack_size(8 * 1024 * 1024) // 8 MB stack
    .build()?;
```

---

## Debugging with tokio-console

### Setup
```toml
# Cargo.toml
[dependencies]
console-subscriber = "0.4"
tokio = { version = "1", features = ["full", "tracing"] }
```

```rust
// main.rs — replace tracing_subscriber::init()
console_subscriber::init();
```

```bash
# Terminal 1: Run your app
RUSTFLAGS="--cfg tokio_unstable" cargo run

# Terminal 2: Connect the console
cargo install tokio-console
tokio-console
```

### What It Shows
- **Tasks view**: All spawned tasks, their state (idle/running/blocked), poll times.
- **Resources view**: Mutexes, semaphores, and their waiters.
- **Long polls**: Tasks that take >100μs to poll (indicates blocking).
- **Waker stats**: How often tasks are woken and by whom.

### Key Metrics to Watch
| Metric | Healthy | Problem |
|--------|---------|---------|
| Poll duration | < 100μs | > 1ms indicates blocking |
| Idle tasks | Proportional to load | Many idle = possible deadlock |
| Wakes | Matches expected events | Excessive = busy-waiting |
| Task count | Stable under load | Growing = leak |

---

## Performance Profiling

### Measuring Async Performance
```rust
// Per-request timing with tracing
#[instrument(skip_all)]
async fn handle_request(req: Request) -> Response {
    let _span = tracing::info_span!("db_query").entered();
    let data = db.query().await;
    drop(_span);

    let _span = tracing::info_span!("serialize").entered();
    let response = serialize(data);
    response
}
```

### Flamegraph for Async
```bash
# Install
cargo install flamegraph

# Profile (needs root on Linux or perf_event_paranoid=-1)
cargo flamegraph --bin myapp

# For async, use tokio-tracing integration
# Shows time spent in spans, not just CPU functions
```

### Benchmarking Async Code
```rust
// Using criterion with tokio
use criterion::{criterion_group, criterion_main, Criterion};

fn bench_async_fn(c: &mut Criterion) {
    let rt = tokio::runtime::Runtime::new().unwrap();

    c.bench_function("async_operation", |b| {
        b.iter(|| rt.block_on(async { my_async_fn().await }))
    });
}

criterion_group!(benches, bench_async_fn);
criterion_main!(benches);
```

### Common Performance Issues
| Symptom | Cause | Fix |
|---------|-------|-----|
| High CPU, low throughput | Blocking in async | Move to spawn_blocking |
| Memory growing | Unbounded channels/tasks | Add bounds, track JoinHandles |
| Latency spikes | Lock contention | Shard data, use RwLock |
| Slow under load | No backpressure | Add semaphore/bounded channels |
| P99 >> P50 | Head-of-line blocking | Use FuturesUnordered |

---

## Memory Leaks from Forgotten JoinHandles

### The Problem
```rust
// ❌ Spawned task runs forever — no way to cancel or detect failure
tokio::spawn(async {
    loop {
        do_background_work().await;
        tokio::time::sleep(Duration::from_secs(60)).await;
    }
});
// JoinHandle dropped — task is "detached", runs until process exit
```

### Solutions
```rust
// ✅ Use JoinSet to track all tasks
let mut set = JoinSet::new();
set.spawn(background_worker());
// When set drops, all tasks are aborted

// ✅ Store handles and abort on shutdown
struct App {
    workers: Vec<JoinHandle<()>>,
}

impl App {
    async fn shutdown(self) {
        for handle in self.workers {
            handle.abort();
            let _ = handle.await;
        }
    }
}

// ✅ Use CancellationToken for cooperative shutdown
let token = CancellationToken::new();
let child = token.child_token();
tokio::spawn(async move {
    loop {
        tokio::select! {
            _ = child.cancelled() => break,
            _ = do_work() => {}
        }
    }
});
// Later:
token.cancel(); // All child tokens also cancel
```

---

## Channel Deadlocks

### Common Deadlock Scenarios

**Scenario 1: Sender blocks, receiver never polled**
```rust
// ❌ Deadlock: single task sends and receives on bounded channel
let (tx, mut rx) = mpsc::channel(1);
tx.send(1).await.unwrap();
tx.send(2).await.unwrap(); // BLOCKS — channel full, receiver never polled
let val = rx.recv().await;  // Never reached

// ✅ Separate sender and receiver into different tasks
let (tx, mut rx) = mpsc::channel(1);
tokio::spawn(async move {
    tx.send(1).await.unwrap();
    tx.send(2).await.unwrap();
});
while let Some(val) = rx.recv().await {
    println!("{val}");
}
```

**Scenario 2: Circular dependency**
```rust
// ❌ A waits for B, B waits for A
let (tx_a, mut rx_a) = mpsc::channel(1);
let (tx_b, mut rx_b) = mpsc::channel(1);

tokio::spawn(async move {
    let val = rx_b.recv().await.unwrap(); // Wait for B first
    tx_a.send(val).await.unwrap();
});
tokio::spawn(async move {
    let val = rx_a.recv().await.unwrap(); // Wait for A first — DEADLOCK
    tx_b.send(val).await.unwrap();
});

// ✅ Break the cycle: one side sends first
tokio::spawn(async move {
    tx_b.send(42).await.unwrap(); // Send first, break the cycle
    let val = rx_a.recv().await.unwrap();
});
```

**Scenario 3: All senders dropped while receiver waits**
```rust
// Not a deadlock, but a hang: receiver waits forever
let (tx, mut rx) = mpsc::channel::<i32>(10);
drop(tx); // All senders gone
// rx.recv().await returns None — but only if ALL tx clones are dropped
// If one clone is held somewhere (e.g., stored in a struct), recv hangs.
```

### Debugging Channels
- **Bounded channels**: If all `send()` calls hang, the receiver isn't consuming.
- **Check all clones**: Every `tx.clone()` extends the channel's lifetime.
- **Use `try_send()`** for non-blocking send with diagnostics.
- **Add `tokio::time::timeout`** around channel operations to detect hangs.

---

## Timeout Gotchas

### Timeout Doesn't Cancel the Inner Future's Side Effects
```rust
// The HTTP request may still complete on the server side
match timeout(Duration::from_secs(5), client.post(url).send()).await {
    Ok(Ok(resp)) => handle(resp),
    Ok(Err(e)) => eprintln!("request failed: {e}"),
    Err(_) => {
        // The future is DROPPED, but the server already received the request
        // For idempotent operations, this is fine
        // For non-idempotent, you need request-level cancellation tokens
        eprintln!("timed out");
    }
}
```

### Nested Timeouts
```rust
// ❌ Inner timeout is meaningless if outer is shorter
timeout(Duration::from_secs(1),
    timeout(Duration::from_secs(10), slow_op()) // This 10s timeout never fires
).await;

// ✅ Use the tightest timeout at each level
timeout(Duration::from_secs(10), async {
    let data = timeout(Duration::from_secs(3), fetch_data()).await??;
    let result = timeout(Duration::from_secs(5), process(data)).await??;
    Ok::<_, anyhow::Error>(result)
}).await?
```

### Timeout with Graceful Fallback
```rust
async fn fetch_with_fallback(url: &str) -> Data {
    match timeout(Duration::from_secs(5), fetch_from_primary(url)).await {
        Ok(Ok(data)) => data,
        Ok(Err(e)) => {
            tracing::warn!("primary failed: {e}, using cache");
            fetch_from_cache(url).await
        }
        Err(_) => {
            tracing::warn!("primary timed out, using cache");
            fetch_from_cache(url).await
        }
    }
}
```

---

## Executor Panics

### Task Panics Don't Crash the Runtime
```rust
// Panic in spawned task is captured in JoinHandle
let handle = tokio::spawn(async {
    panic!("oh no"); // This does NOT crash the process
});

match handle.await {
    Ok(val) => println!("success: {val:?}"),
    Err(e) if e.is_panic() => {
        let panic_msg = e.into_panic();
        eprintln!("task panicked: {panic_msg:?}");
    }
    Err(e) => eprintln!("task cancelled: {e}"),
}
```

### Catching Panics Globally
```rust
// Set a panic hook for logging
std::panic::set_hook(Box::new(|info| {
    tracing::error!("panic: {info}");
}));

// Or use catch_unwind for critical paths
let result = std::panic::AssertUnwindSafe(async {
    risky_operation().await
});
match futures::FutureExt::catch_unwind(result).await {
    Ok(val) => val,
    Err(panic) => {
        tracing::error!("caught panic: {panic:?}");
        default_value()
    }
}
```

### Detached Task Panics (Silent Failures)
```rust
// ❌ Panic goes unnoticed — JoinHandle is dropped
tokio::spawn(async {
    important_work().await; // If this panics, nobody knows
});

// ✅ Always handle JoinHandle results
let handle = tokio::spawn(async { important_work().await });
if let Err(e) = handle.await {
    tracing::error!("critical task failed: {e}");
    initiate_recovery().await;
}

// ✅ Or use JoinSet which collects all results
let mut set = JoinSet::new();
set.spawn(important_work());
while let Some(result) = set.join_next().await {
    if let Err(e) = result {
        tracing::error!("task failed: {e}");
    }
}
```

---

## Trait Object Limitations with Async

### The Problem
Async methods return opaque, uniquely-typed futures. This prevents using them in trait objects:

```rust
trait Service {
    async fn call(&self, req: Request) -> Response;
}

// ❌ Can't create dyn Service — async fn return type is unnameable
fn use_service(svc: &dyn Service) { /* compile error */ }
```

### Solutions

**Solution 1: `#[async_trait]` (heap allocation per call)**
```rust
#[async_trait::async_trait]
trait Service: Send + Sync {
    async fn call(&self, req: Request) -> Response;
}
// Desugars to: fn call(&self, req: Request) -> Pin<Box<dyn Future<...> + Send + '_>>

fn use_service(svc: &dyn Service) { /* works! */ }
```

**Solution 2: Manual desugaring (avoid the macro)**
```rust
trait Service: Send + Sync {
    fn call(&self, req: Request) -> Pin<Box<dyn Future<Output = Response> + Send + '_>>;
}

impl Service for MyService {
    fn call(&self, req: Request) -> Pin<Box<dyn Future<Output = Response> + Send + '_>> {
        Box::pin(async move {
            // actual implementation
            self.handle(req).await
        })
    }
}
```

**Solution 3: Enum dispatch (zero allocation)**
```rust
enum AnyService {
    Http(HttpService),
    Grpc(GrpcService),
    Mock(MockService),
}

impl AnyService {
    async fn call(&self, req: Request) -> Response {
        match self {
            Self::Http(s) => s.call(req).await,
            Self::Grpc(s) => s.call(req).await,
            Self::Mock(s) => s.call(req).await,
        }
    }
}
// No heap allocation, but requires knowing all variants at compile time
```

**Solution 4: Generic with static dispatch**
```rust
// Use generics instead of trait objects when possible
async fn process<S: Service>(service: &S, req: Request) -> Response {
    service.call(req).await
    // Monomorphized — no dynamic dispatch, no allocation
}
```
