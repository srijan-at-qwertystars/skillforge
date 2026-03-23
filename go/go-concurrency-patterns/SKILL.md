---
name: go-concurrency-patterns
description:
  positive: "Use when user writes concurrent Go code, asks about goroutines, channels, select statements, sync.WaitGroup, sync.Mutex, errgroup, context cancellation, worker pools, fan-in/fan-out, or race condition debugging."
  negative: "Do NOT use for basic Go syntax, Go module management, or non-concurrency Go patterns."
---

# Go Concurrency Patterns

## Goroutine Lifecycle Management

Always track goroutine completion. Never fire-and-forget.

```go
var wg sync.WaitGroup
for i := 0; i < n; i++ {
    wg.Add(1)
    go func(id int) {
        defer wg.Done()
        process(id)
    }(i) // pass loop var explicitly to avoid closure capture bugs
}
wg.Wait()
```

Cancel long-running goroutines via context:

```go
ctx, cancel := context.WithCancel(context.Background())
defer cancel()
go func() {
    for {
        select {
        case <-ctx.Done():
            return
        default:
            doWork()
        }
    }
}()
```

Rules:
- Call `wg.Add(1)` before `go`, not inside the goroutine.
- `defer wg.Done()` as the first line in the goroutine body.
- Every goroutine must have a termination path.

## Channel Patterns

### Unbuffered vs Buffered

```go
sync := make(chan int)      // blocks until both sides ready (handoff)
async := make(chan int, 10) // blocks only when buffer full
```

Size buffered channels to known workload, not arbitrary large numbers.

### Directional Channels

```go
func producer(out chan<- int) { out <- 42 }
func consumer(in <-chan int)  { v := <-in }
```

### Closing and Ranging

Only the sender closes. Never close from the receiver.

```go
go func() {
    defer close(ch)
    for _, item := range items { ch <- item }
}()
for val := range ch { process(val) }
```

Nil channel behavior: send or receive blocks forever. Use nil channels in `select` to disable a case dynamically.

## Select Statement Patterns

```go
// Timeout
select {
case r := <-ch:   handle(r)
case <-time.After(5 * time.Second): return ErrTimeout
}

// Context cancellation
select {
case r := <-ch:   handle(r)
case <-ctx.Done(): return ctx.Err()
}

// Non-blocking
select {
case ch <- val: // sent
default:        // skip if not ready
}
```

### Priority Select

`select` picks randomly among ready cases. Enforce priority with nesting:

```go
for {
    select {
    case <-high:
        handleHigh()
    default:
        select {
        case <-high: handleHigh()
        case <-low:  handleLow()
        }
    }
}
```

### Disable Case with Nil

```go
var ch1, ch2 <-chan int = src1, src2
for ch1 != nil || ch2 != nil {
    select {
    case v, ok := <-ch1:
        if !ok { ch1 = nil; continue }
        process(v)
    case v, ok := <-ch2:
        if !ok { ch2 = nil; continue }
        process(v)
    }
}
```

## sync Package

### Mutex / RWMutex

```go
var mu sync.Mutex
mu.Lock()
sharedState++
mu.Unlock()
```

Use `RWMutex` when reads vastly outnumber writes:

```go
var rw sync.RWMutex
rw.RLock(); val := m[key]; rw.RUnlock()
rw.Lock();  m[key] = v;   rw.Unlock()
```

### Once

```go
var once sync.Once
var db *sql.DB
func GetDB() *sql.DB {
    once.Do(func() { db = connectDB() })
    return db
}
```

### Pool

Reuse expensive objects to reduce GC pressure:

```go
var bufPool = sync.Pool{New: func() any { return new(bytes.Buffer) }}
buf := bufPool.Get().(*bytes.Buffer)
buf.Reset()
defer bufPool.Put(buf)
```

Pool contents may be collected at any GC cycle. Do not store state-dependent objects.

### Map

Use `sync.Map` for stable key sets read by many goroutines, or disjoint key sets per goroutine. Prefer regular `map` + `sync.RWMutex` for most cases.

```go
var m sync.Map
m.Store("key", "value")
val, _ := m.Load("key")
m.Range(func(k, v any) bool { fmt.Println(k, v); return true })
```

## errgroup for Structured Concurrency

```go
import "golang.org/x/sync/errgroup"

g, ctx := errgroup.WithContext(ctx)
for _, url := range urls {
    url := url
    g.Go(func() error { return fetch(ctx, url) })
}
if err := g.Wait(); err != nil {
    return err // first error from any goroutine
}
```

`WithContext` cancels the derived context on first error. Limit concurrency with `g.SetLimit(10)`.

| Feature | WaitGroup | errgroup |
|---|---|---|
| Wait for completion | Yes | Yes |
| Error propagation | No | Yes (first error) |
| Context cancellation | No | Yes |
| Concurrency limiting | No | Yes (SetLimit) |

Use errgroup for any production concurrent work that can fail.

## Context Propagation

```go
// WithCancel — manual cancellation
ctx, cancel := context.WithCancel(parentCtx)
defer cancel()

// WithTimeout — auto-cancel after duration
ctx, cancel := context.WithTimeout(parentCtx, 30*time.Second)
defer cancel()

// WithValue — request-scoped metadata only
type ctxKey string
ctx = context.WithValue(ctx, ctxKey("reqID"), "abc-123")
```

Rules:
- Pass `ctx` as the first function parameter.
- Always `defer cancel()` immediately after creation.
- Check `ctx.Done()` in long-running loops.
- Never store contexts in structs.
- Never use `WithValue` for function parameters or optional args.

## Fan-In, Fan-Out, Pipeline

### Fan-Out — distribute work

```go
func fanOut(in <-chan int, n int) []<-chan int {
    outs := make([]<-chan int, n)
    for i := range outs {
        ch := make(chan int)
        outs[i] = ch
        go func() {
            defer close(ch)
            for v := range in { ch <- process(v) }
        }()
    }
    return outs
}
```

### Fan-In — merge channels

```go
func fanIn(chs ...<-chan int) <-chan int {
    var wg sync.WaitGroup
    out := make(chan int)
    for _, ch := range chs {
        wg.Add(1)
        go func(c <-chan int) {
            defer wg.Done()
            for v := range c { out <- v }
        }(ch)
    }
    go func() { wg.Wait(); close(out) }()
    return out
}
```

### Pipeline — chain stages

```go
func generate(nums ...int) <-chan int {
    out := make(chan int)
    go func() { defer close(out); for _, n := range nums { out <- n } }()
    return out
}
func square(in <-chan int) <-chan int {
    out := make(chan int)
    go func() { defer close(out); for n := range in { out <- n * n } }()
    return out
}
// Usage: results := square(square(generate(2, 3, 4)))
```

Add `ctx.Done()` checks to every pipeline stage for clean shutdown.

## Worker Pool

```go
func workerPool(ctx context.Context, jobs <-chan Job, n int) <-chan Result {
    results := make(chan Result)
    var wg sync.WaitGroup
    for i := 0; i < n; i++ {
        wg.Add(1)
        go func() {
            defer wg.Done()
            for job := range jobs {
                select {
                case <-ctx.Done(): return
                default: results <- job.Execute()
                }
            }
        }()
    }
    go func() { wg.Wait(); close(results) }()
    return results
}
```

Semaphore-based alternative using `golang.org/x/sync/semaphore`:

```go
sem := semaphore.NewWeighted(int64(max))
for _, t := range tasks {
    sem.Acquire(ctx, 1)
    go func(t Task) { defer sem.Release(1); t.Run() }(t)
}
sem.Acquire(ctx, int64(max)) // wait for all
```

## Rate Limiting

```go
// Fixed rate
limiter := time.NewTicker(100 * time.Millisecond)
defer limiter.Stop()
for req := range requests {
    <-limiter.C
    go handle(req)
}

// Burst rate — pre-fill buffer for initial burst
bursty := make(chan struct{}, 3)
for i := 0; i < 3; i++ { bursty <- struct{}{} }
go func() {
    for range time.Tick(200 * time.Millisecond) { bursty <- struct{}{} }
}()
for req := range requests {
    <-bursty
    go handle(req)
}
```

## Race Condition Detection

```bash
go test -race ./...
go run -race main.go
go build -race -o myapp
```

Run `-race` in CI. Detects data races at runtime (~2-10x slowdown).

### Common Data Races

```go
// BUG: concurrent map access
go func() { m["a"] = 1 }()
go func() { _ = m["a"] }()
// FIX: sync.Mutex or sync.Map

// BUG: unsynchronized counter
var c int
for i := 0; i < 100; i++ { go func() { c++ }() }
// FIX: atomic.AddInt64 or mutex

// BUG: concurrent slice append
go func() { s = append(s, 1) }()
go func() { s = append(s, 2) }()
// FIX: mutex or collect via channel
```

## Channel vs Mutex Decision Guide

Use **channels** when:
- Transferring data ownership between goroutines.
- Coordinating goroutines (fan-in, fan-out, pipelines).
- Signaling events (done, cancel, ready).

Use **mutex** when:
- Protecting a shared data structure (map, slice, struct field).
- Simple read/write guarding on a single resource.
- Performance-critical sections where channel overhead matters.

Rule: *communicating* → channels. *Protecting state* → mutex.

## Graceful Shutdown

```go
func main() {
    ctx, stop := signal.NotifyContext(context.Background(),
        syscall.SIGINT, syscall.SIGTERM)
    defer stop()

    srv := &http.Server{Addr: ":8080"}
    go func() {
        if err := srv.ListenAndServe(); err != http.ErrServerClosed {
            log.Fatal(err)
        }
    }()

    <-ctx.Done()
    shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
    defer cancel()
    srv.Shutdown(shutdownCtx)
}
```

## Anti-Patterns

**Goroutine leak** — no reader for channel:
```go
ch := make(chan int)
go func() { ch <- compute() }() // blocks forever if nobody reads
// FIX: use make(chan int, 1) or ensure a reader exists
```

**Closing channel twice** — panics:
```go
close(ch); close(ch) // PANIC
// FIX: close once from sender. Use sync.Once if multiple closers possible.
```

**Forgetting defer cancel()** — leaks context resources:
```go
ctx, cancel := context.WithTimeout(parent, time.Minute)
// MISSING: defer cancel()
```

**Sending on closed channel** — panics:
```go
close(ch); ch <- v // PANIC
// FIX: only sender closes, after all sends complete.
```

**Sleeping instead of synchronizing**:
```go
go process()
time.Sleep(time.Second) // BUG: race, unreliable
// FIX: use WaitGroup, errgroup, or channel signal.
```