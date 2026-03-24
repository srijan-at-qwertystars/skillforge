---
name: go-concurrency
description: >
  Go concurrency patterns and primitives. Triggers: goroutines, channels, select statement,
  sync.Mutex, sync.WaitGroup, sync.Once, sync.Pool, sync.Map, sync.RWMutex, sync.Cond,
  context.WithCancel, context.WithTimeout, context.WithDeadline, context.WithValue,
  fan-in, fan-out, pipeline, worker pool, semaphore, errgroup, race condition, -race flag,
  atomic operations, graceful shutdown, signal handling, channel deadlock, goroutine leak,
  GOMAXPROCS, concurrent Go code, Go parallelism, structured concurrency, done channel.
  Does NOT trigger for: generic Go syntax, Go modules, Go testing unrelated to concurrency,
  Go HTTP routing, Go database queries, Go JSON parsing, Go CLI tools, Go generics,
  Go interfaces, Go error handling without goroutines, non-Go concurrency (Rust async,
  Python asyncio, Java threads).
---
# Go Concurrency Patterns
## Goroutines
Launch with `go`. Each starts with ~8KB stack that grows dynamically. Runtime multiplexes goroutines onto OS threads controlled by `GOMAXPROCS` (defaults to `runtime.NumCPU()`).
```go
var wg sync.WaitGroup
wg.Add(1)
go func() { defer wg.Done(); doWork() }()
wg.Wait()
```
Never fire-and-forget goroutines — always ensure exit via WaitGroup, context, or done channel.

**Lifecycle:** A goroutine runs until its function returns. No external kill mechanism exists —
design for cooperative cancellation via context or done channels.

**Stack growth:** Starts at ~8KB, grows up to 1GB by default. The runtime copies the stack to
larger allocations as needed — no segmented stacks since Go 1.4.

Set `GOMAXPROCS` explicitly only for CPU-bound tuning: `runtime.GOMAXPROCS(4)`.
## Channels
### Unbuffered vs Buffered
```go
ch := make(chan int)     // unbuffered: blocks sender until receiver ready
ch := make(chan int, 10) // buffered: blocks only when full
```
### Directional types
```go
func producer(out chan<- int) { out <- 1; close(out) }  // send-only
func consumer(in <-chan int)  { for v := range in { use(v) } } // recv-only
```
### Closing and ranging
```go
ch := make(chan string, 3)
ch <- "a"; ch <- "b"; ch <- "c"; close(ch)
for msg := range ch { fmt.Println(msg) } // iterates until closed
val, ok := <-ch // ok=false when closed and drained
```
**Rules:** Only sender closes. Never close nil channel. Never send on closed channel (panics).
## Select Statement
### Multiplexing
```go
select {
case msg := <-ch1: handle(msg)
case msg := <-ch2: handle(msg)
case ch3 <- val:   // sent
}
```
### Default (non-blocking), Timeout, Done channel
```go
select {                           // non-blocking poll
case msg := <-ch: process(msg)
default:
}
select {                           // timeout
case res := <-ch: use(res)
case <-time.After(3 * time.Second): log.Println("timeout")
}
func worker(done <-chan struct{}, jobs <-chan int) { // done pattern
    for { select {
    case <-done: return
    case j, ok := <-jobs: if !ok { return }; process(j)
    }}
}
```
## sync Package
### Mutex / RWMutex
```go
var mu sync.Mutex
mu.Lock(); sharedState++; mu.Unlock()

var rw sync.RWMutex
rw.RLock(); v := shared; rw.RUnlock()  // concurrent readers OK
rw.Lock(); shared = v + 1; rw.Unlock() // exclusive writer
```
### WaitGroup
```go
var wg sync.WaitGroup
for i := range 10 {  // Go 1.22+ integer range
    wg.Add(1)
    go func() { defer wg.Done(); process(i) }() // per-iteration var safe in 1.22+
}
wg.Wait()
```
Call `wg.Add(1)` before `go func()`, never inside the goroutine.
### Once
```go
var once sync.Once
var conn *DB
func GetDB() *DB { once.Do(func() { conn = openDB() }); return conn }
```
### Pool
```go
var bufPool = sync.Pool{New: func() any { return new(bytes.Buffer) }}
buf := bufPool.Get().(*bytes.Buffer)
buf.Reset()
defer bufPool.Put(buf)
```
Reduces GC pressure for frequently allocated/freed objects.
### Map
```go
var m sync.Map
m.Store("key", 42)
val, ok := m.Load("key") // 42, true
m.Range(func(k, v any) bool { fmt.Println(k, v); return true })
```
Prefer `map` + `sync.RWMutex` for general use. Use `sync.Map` for read-heavy or disjoint-writer workloads.
### Cond
```go
cond := sync.NewCond(&sync.Mutex{})
go func() { cond.L.Lock(); for !ready { cond.Wait() }; cond.L.Unlock() }()
cond.L.Lock(); ready = true; cond.Signal(); cond.L.Unlock() // or Broadcast()
```
`Wait()` atomically releases lock and suspends; re-acquires on wake. Always check condition in a loop.
## Context
Pass `ctx context.Context` as first parameter. Never store in structs.
### WithCancel / WithTimeout / WithDeadline
```go
ctx, cancel := context.WithCancel(context.Background())
defer cancel()
ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
defer cancel() // always defer — releases timer resources
ctx, cancel := context.WithDeadline(ctx, time.Now().Add(10*time.Second))
defer cancel()
```
### WithValue
```go
type ctxKey string
ctx := context.WithValue(parent, ctxKey("reqID"), "abc-123")
id := ctx.Value(ctxKey("reqID")).(string)
```
Use typed keys. Never use for optional params or control flow.
### Propagation
Check `ctx.Done()` in long-running loops and pass through call chains:
```go
for {
    select {
    case <-ctx.Done(): return ctx.Err()
    default: doBatchWork()
    }
}
```
## Common Patterns
### Pipeline
```go
func gen(nums ...int) <-chan int {
    out := make(chan int)
    go func() { for _, n := range nums { out <- n }; close(out) }()
    return out
}
func square(in <-chan int) <-chan int {
    out := make(chan int)
    go func() { for n := range in { out <- n * n }; close(out) }()
    return out
}
// for v := range square(gen(2,3,4)) { fmt.Println(v) } → 4 9 16
```
### Fan-Out / Fan-In
```go
func fanOut(in <-chan int, n int) []<-chan int {
    chs := make([]<-chan int, n)
    for i := range n { chs[i] = square(in) }
    return chs
}
func fanIn(chs ...<-chan int) <-chan int {
    var wg sync.WaitGroup
    out := make(chan int)
    for _, ch := range chs {
        wg.Add(1)
        go func() { defer wg.Done(); for v := range ch { out <- v } }()
    }
    go func() { wg.Wait(); close(out) }()
    return out
}
```
### Worker Pool
```go
func workerPool(ctx context.Context, jobs <-chan Job, results chan<- Result, n int) {
    var wg sync.WaitGroup
    for range n {
        wg.Add(1)
        go func() {
            defer wg.Done()
            for j := range jobs {
                select {
                case <-ctx.Done(): return
                case results <- process(j):
                }
            }
        }()
    }
    go func() { wg.Wait(); close(results) }()
}
```
### Semaphore
```go
sem := make(chan struct{}, maxConcurrent)
for _, item := range items {
    sem <- struct{}{}
    go func() { defer func() { <-sem }(); process(item) }()
}
for range maxConcurrent { sem <- struct{}{} } // wait for all
```
## Error Handling in Goroutines
### errgroup (preferred)
```go
g, ctx := errgroup.WithContext(ctx)
for _, url := range urls {
    g.Go(func() error { return fetch(ctx, url) })
}
if err := g.Wait(); err != nil { log.Fatal(err) }
// First error cancels ctx; all goroutines see ctx.Done()
```
Use `g.SetLimit(n)` to bound concurrency within errgroup.

### errgroup with result collection
```go
type Result struct { URL string; Body []byte; Err error }
g, ctx := errgroup.WithContext(ctx)
g.SetLimit(10)
resultCh := make(chan Result, len(urls))
for _, url := range urls {
    g.Go(func() error {
        body, err := fetch(ctx, url)
        resultCh <- Result{url, body, err}
        return err
    })
}
err := g.Wait()
close(resultCh)
```
### Error channel
```go
errs := make(chan error, len(tasks))
for _, t := range tasks { go func() { errs <- doTask(t) }() }
for range len(tasks) {
    if err := <-errs; err != nil { log.Println("failed:", err) }
}
```
## Race Conditions
### Detection
```bash
go test -race ./...   # always run in CI; ~10x slowdown
go run -race main.go
```
### Atomic operations (lock-free)
```go
var counter atomic.Int64
counter.Add(1)
counter.Store(0)
val := counter.Load() // 0
```
Use `atomic` for simple counters/flags. Use `sync.Mutex` for multi-field state.

### Common data race example
```go
// RACE: concurrent map write
m := make(map[string]int)
go func() { m["a"] = 1 }()
go func() { m["b"] = 2 }() // fatal error: concurrent map writes
// FIX: use sync.Mutex or sync.Map
```
## Channel Patterns
### Generator
```go
func fib(ctx context.Context) <-chan int {
    ch := make(chan int)
    go func() {
        defer close(ch)
        a, b := 0, 1
        for { select { case <-ctx.Done(): return; case ch <- a: a, b = b, a+b } }
    }()
    return ch
}
```
### Or-channel (first signal wins from N channels)
```go
func or(chs ...<-chan struct{}) <-chan struct{} {
    switch len(chs) {
    case 0: return nil
    case 1: return chs[0]
    }
    done := make(chan struct{})
    go func() {
        defer close(done)
        select { case <-chs[0]:; case <-chs[1]:; case <-or(append(chs[2:], done)...): }
    }()
    return done
}
```
### Or-done (wrap reads with cancellation)
```go
func orDone(ctx context.Context, in <-chan int) <-chan int {
    out := make(chan int)
    go func() {
        defer close(out)
        for { select {
        case <-ctx.Done(): return
        case v, ok := <-in:
            if !ok { return }
            select { case out <- v:; case <-ctx.Done(): return }
        }}
    }()
    return out
}
```
### Tee (duplicate channel into two)
```go
func tee(ctx context.Context, in <-chan int) (<-chan int, <-chan int) {
    o1, o2 := make(chan int), make(chan int)
    go func() {
        defer close(o1); defer close(o2)
        for v := range orDone(ctx, in) {
            c1, c2 := o1, o2
            for range 2 { select { case c1 <- v: c1 = nil; case c2 <- v: c2 = nil; case <-ctx.Done(): return } }
        }
    }()
    return o1, o2
}
```
### Bridge (flatten channel-of-channels)
```go
func bridge(ctx context.Context, chanCh <-chan <-chan int) <-chan int {
    out := make(chan int)
    go func() {
        defer close(out)
        for { select {
        case <-ctx.Done(): return
        case ch, ok := <-chanCh:
            if !ok { return }
            for v := range orDone(ctx, ch) { out <- v }
        }}
    }()
    return out
}
```
## Graceful Shutdown
### HTTP server with signal handling
```go
func main() {
    ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
    defer stop()
    srv := &http.Server{Addr: ":8080", Handler: mux}
    go func() {
        if err := srv.ListenAndServe(); err != http.ErrServerClosed { log.Fatal(err) }
    }()
    <-ctx.Done()
    shutCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
    defer cancel()
    if err := srv.Shutdown(shutCtx); err != nil { log.Fatal(err) }
}
```### Drain pattern
```go
close(jobsCh)    // 1. stop accepting new work
wg.Wait()        // 2. wait for in-flight work
close(resultsCh) // 3. close output
```

## Testing Concurrent Code
```bash
go test -race -count=100 ./...  # repeat to surface timing bugs
```
- Always use `-race` in CI. Use `-count=N` for flaky-prone tests.
- Call `t.Parallel()` for concurrent subtests.
- Synchronize with WaitGroup/channels, never `time.Sleep`.
- Detect goroutine leaks: `go.uber.org/goleak` with `goleak.VerifyMain(m)`.
```go
func TestConcurrent(t *testing.T) {
    t.Parallel()
    ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
    defer cancel()
    ch := produce(ctx)
    var got []int
    for v := range ch { got = append(got, v) }
    require.Equal(t, expected, got)
}
```
## Go 1.22+ Patterns
### Per-iteration variable scoping
```go
for i, v := range slice {
    go func() { fmt.Println(i, v) }() // safe in 1.22+: each iteration owns i, v
}
```
### Integer range syntax
```go
for i := range 10 { go func() { work(i) }() }
```
### sourcegraph/conc (structured concurrency)
```go
p := pool.New().WithMaxGoroutines(10).WithContext(ctx)
for _, url := range urls {
    p.Go(func(ctx context.Context) error { return fetch(ctx, url) })
}
if err := p.Wait(); err != nil { handleErr(err) }
```
Provides panic recovery, result collection, and context-aware goroutine pools.

### iter package (Go 1.23+)
```go
// Range-over-func iterators enable lazy, composable sequences
func Filter[T any](seq iter.Seq[T], pred func(T) bool) iter.Seq[T] {
    return func(yield func(T) bool) {
        for v := range seq { if pred(v) { if !yield(v) { return } } }
    }
}
// Combine with goroutines for concurrent iteration over filtered results
```
## Common Gotchas
| Gotcha | Fix |
|--------|-----|
| Goroutine leak: blocked on channel | Use `ctx.Done()` or `done` channel in every `select` |
| Deadlock: all goroutines asleep | Ensure sender closes channel; use buffered channels appropriately |
| Closure capture (pre-1.22) | Pass as param: `go func(v int) { use(v) }(v)` |
| Send on closed channel (panic) | Only sender closes; use `sync.Once` for multi-sender close |
| Nil channel blocks forever | Initialize before use; use nil to disable `select` cases intentionally |
| WaitGroup.Add after goroutine starts | Call `wg.Add(1)` before `go func()` |
| Copied Mutex (silent bug) | Use pointer receivers; run `go vet` to detect |
| Race on error variable | Return errors via channels or errgroup, not shared vars |

## Performance
**Scheduling:** M:N model (goroutines on OS threads). Work-stealing, preemptive since Go 1.14. Goroutines yield at function calls, channel ops, and async preemption points.
**GOMAXPROCS:** Default = NumCPU. In containers, use `go.uber.org/automaxprocs`:
```go
import _ "go.uber.org/automaxprocs" // auto-detect cgroup CPU quota
```
**Contention profiling:**
```bash
go test -bench=. -mutexprofile=mutex.out ./...
go tool pprof -http=:6060 mutex.out
```
Use `net/http/pprof` in production for goroutine dumps and blocking profiles.

**Goroutine pool sizing:** For I/O-bound work, use more goroutines than CPUs. For CPU-bound,
match GOMAXPROCS. Use benchmarks to find the sweet spot — measure, don't guess.
## Real-World: Concurrent Web Scraper
```go
func scrape(ctx context.Context, urls []string, workers int) (map[string]string, error) {
    g, ctx := errgroup.WithContext(ctx)
    g.SetLimit(workers)
    var mu sync.Mutex
    results := make(map[string]string)
    for _, url := range urls {
        g.Go(func() error {
            req, _ := http.NewRequestWithContext(ctx, "GET", url, nil)
            resp, err := http.DefaultClient.Do(req)
            if err != nil { return err }
            defer resp.Body.Close()
            body, err := io.ReadAll(resp.Body)
            if err != nil { return err }
            mu.Lock(); results[url] = string(body); mu.Unlock()
            return nil
        })
    }
    return results, g.Wait()
}
// Input: urls=["https://example.com","https://go.dev"], workers=5
// Output: map[string]string with URL→HTML, or first error
```

## Reference Documentation
Detailed guides in `references/`:

| File | Contents |
|------|----------|
| [advanced-patterns.md](references/advanced-patterns.md) | Pipeline stages with cancellation, bounded parallelism, sharded maps, lock-free structures with atomic, singleflight deduplication, rate limiting (time.Ticker, x/time/rate), circuit breaker, pub/sub with channels, graceful degradation (hedged requests, bulkhead, load shedding) |
| [troubleshooting.md](references/troubleshooting.md) | Goroutine leak detection (runtime.NumGoroutine, pprof, goleak), deadlock detection (go vet, go-deadlock), data race examples/fixes, channel misuse patterns, context cancellation bugs, WaitGroup counter bugs, mutex starvation, performance debugging with `go tool trace` |
| [testing-guide.md](references/testing-guide.md) | Race detector usage (-race flag, GORACE env), testing with timeouts, deterministic testing with channels, goleak for leak detection, testing context cancellation, benchmarking concurrent code (RunParallel, benchstat), fuzz testing, table-driven concurrent tests, testing with errgroup |

## Scripts
Executable scripts in `scripts/`:

| Script | Purpose |
|--------|---------|
| [init-concurrent-project.sh](scripts/init-concurrent-project.sh) | Scaffold a Go project with concurrency-ready structure: go module, errgroup/singleflight/semaphore deps, worker pool template, Makefile with race detection targets |
| [race-detector.sh](scripts/race-detector.sh) | Run `go test -race` and `go vet`, parse output, summarize findings with file locations and suggested fixes |
| [goroutine-profiler.sh](scripts/goroutine-profiler.sh) | Profile goroutine usage: capture pprof profiles at intervals, detect goroutine count growth, report potential leaks, generate flamegraph commands |

## Copy-Paste Templates
Production-ready templates in `assets/`:

| File | Description |
|------|-------------|
| [worker-pool.go](assets/worker-pool.go) | Generic worker pool with configurable workers, job queue, results channel, panic recovery, graceful shutdown, and stats tracking |
| [pipeline.go](assets/pipeline.go) | Type-safe pipeline framework: Generate, Map, Filter, FanOut/FanIn, Batch, Tee, OrDone, Take — all with context cancellation and error propagation |
| [graceful-server.go](assets/graceful-server.go) | HTTP server with signal handling, connection draining, health/ready/metrics endpoints, request timeout middleware, panic recovery, structured logging |
| [rate-limiter.go](assets/rate-limiter.go) | Per-key token bucket rate limiter with burst support, automatic stale entry cleanup, Wait/Allow/AllowN methods, and HTTP middleware |
