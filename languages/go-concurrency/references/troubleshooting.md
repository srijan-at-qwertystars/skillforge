# Troubleshooting Go Concurrency Bugs

Practical guide to detecting, diagnosing, and fixing common concurrency bugs in Go.

## Table of Contents

- [Goroutine Leaks](#goroutine-leaks)
- [Deadlock Detection](#deadlock-detection)
- [Data Races](#data-races)
- [Channel Misuse Patterns](#channel-misuse-patterns)
- [Context Cancellation Not Propagating](#context-cancellation-not-propagating)
- [WaitGroup Counter Bugs](#waitgroup-counter-bugs)
- [Mutex Starvation](#mutex-starvation)
- [Performance Debugging with go tool trace](#performance-debugging-with-go-tool-trace)

---

## Goroutine Leaks

A goroutine leak occurs when a goroutine is created but never terminates, consuming memory
and CPU scheduling time indefinitely.

### Detection with runtime.NumGoroutine

```go
func TestNoLeaks(t *testing.T) {
    before := runtime.NumGoroutine()

    // ... run concurrent code ...

    time.Sleep(100 * time.Millisecond) // allow goroutines to exit
    after := runtime.NumGoroutine()
    if after > before+1 {
        t.Errorf("goroutine leak: before=%d after=%d", before, after)
    }
}
```

### Detection with pprof

```bash
# Expose pprof in your application:
# import _ "net/http/pprof"
# go http.ListenAndServe(":6060", nil)

# List goroutines
curl -s http://localhost:6060/debug/pprof/goroutine?debug=1

# Full goroutine dump with stack traces
curl -s http://localhost:6060/debug/pprof/goroutine?debug=2

# Analyze in browser
go tool pprof -http=:8080 http://localhost:6060/debug/pprof/goroutine
```

### Detection with goleak (recommended for tests)

```go
import "go.uber.org/goleak"

func TestMain(m *testing.M) {
    goleak.VerifyTestMain(m)
}

// Or per-test:
func TestSomething(t *testing.T) {
    defer goleak.VerifyNone(t)
    // ... test code ...
}
```

### Common Leak Patterns and Fixes

**1. Blocked channel send (no receiver):**
```go
// BUG: goroutine blocks forever if nobody reads ch
func leak() <-chan int {
    ch := make(chan int)
    go func() {
        result := expensiveComputation()
        ch <- result // blocks forever if caller doesn't read
    }()
    return ch
}

// FIX: use buffered channel so sender doesn't block
func fixed() <-chan int {
    ch := make(chan int, 1) // buffered: sender never blocks
    go func() {
        ch <- expensiveComputation()
    }()
    return ch
}
```

**2. Missing context cancellation in select:**
```go
// BUG: goroutine never exits if input channel stays open
func leak(in <-chan int) {
    go func() {
        for v := range in { process(v) } // blocks if in is never closed
    }()
}

// FIX: add context for cancellation
func fixed(ctx context.Context, in <-chan int) {
    go func() {
        for {
            select {
            case <-ctx.Done():
                return
            case v, ok := <-in:
                if !ok { return }
                process(v)
            }
        }
    }()
}
```

**3. Goroutine blocked on abandoned timer:**
```go
// BUG: time.After creates timer that keeps goroutine alive
func leak(ch <-chan int) {
    for {
        select {
        case v := <-ch:
            process(v)
        case <-time.After(5 * time.Second): // new timer every iteration — leaks!
            return
        }
    }
}

// FIX: reuse timer
func fixed(ch <-chan int) {
    timer := time.NewTimer(5 * time.Second)
    defer timer.Stop()
    for {
        select {
        case v := <-ch:
            if !timer.Stop() {
                <-timer.C
            }
            timer.Reset(5 * time.Second)
            process(v)
        case <-timer.C:
            return
        }
    }
}
```

**4. Leaked HTTP response body:**
```go
// BUG: goroutine doing HTTP call — if caller abandons, body is never closed
// FIX: always close body, use context for cancellation
func fetchWithContext(ctx context.Context, url string) ([]byte, error) {
    req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
    if err != nil {
        return nil, err
    }
    resp, err := http.DefaultClient.Do(req)
    if err != nil {
        return nil, err
    }
    defer resp.Body.Close()
    return io.ReadAll(resp.Body)
}
```

---

## Deadlock Detection

### Go Runtime Detection

Go detects the simplest deadlock: all goroutines are asleep.

```go
// The runtime prints: "fatal error: all goroutines are asleep - deadlock!"
func main() {
    ch := make(chan int)
    <-ch // deadlock: no sender
}
```

**Limitation:** The runtime only detects deadlocks when ALL goroutines are blocked.
If any goroutine is running (even a timer), the deadlock goes undetected.

### go vet

```bash
go vet ./...
# Catches: copied mutexes, unused results of some sync operations
```

### Deadlock Detector (github.com/sasha-s/go-deadlock)

Drop-in replacement for `sync.Mutex` and `sync.RWMutex` that detects potential deadlocks:

```go
import "github.com/sasha-s/go-deadlock"

var mu1 deadlock.Mutex
var mu2 deadlock.Mutex

// Detects lock ordering violations:
// goroutine 1: mu1.Lock() → mu2.Lock()
// goroutine 2: mu2.Lock() → mu1.Lock() → POTENTIAL DEADLOCK reported
```

### Common Deadlock Patterns

**1. Lock ordering violation:**
```go
// BUG: goroutine A locks mu1 then mu2; goroutine B locks mu2 then mu1
// FIX: always acquire locks in consistent order

func transferFixed(from, to *Account, amount int) {
    // Establish consistent ordering by account ID
    first, second := from, to
    if from.ID > to.ID {
        first, second = to, from
    }
    first.mu.Lock()
    defer first.mu.Unlock()
    second.mu.Lock()
    defer second.mu.Unlock()
    from.Balance -= amount
    to.Balance += amount
}
```

**2. Channel deadlock with unbuffered channels:**
```go
// BUG: both sends block because nobody is receiving
ch := make(chan int)
ch <- 1 // blocks: this goroutine can't receive from ch
ch <- 2

// FIX: use goroutines or buffered channel
ch := make(chan int, 2)
ch <- 1
ch <- 2
```

**3. Self-deadlock with sync.Mutex:**
```go
// BUG: same goroutine locks mutex twice
mu.Lock()
doSomething()   // internally calls mu.Lock() again → deadlock
mu.Unlock()

// FIX: use sync.RWMutex for read reentrance, or restructure to avoid nested locks
```

---

## Data Races

### The Race Detector

```bash
go test -race ./...      # test with race detection
go run -race main.go     # run with race detection
go build -race -o app    # build instrumented binary

# Environment variable to control behavior on race detection:
GORACE="halt_on_error=1 log_path=race.log" go test -race ./...
```

**Always run `-race` in CI.** Performance cost: ~2-10x slower, ~5-10x more memory.

### Common Data Race Examples

**1. Unprotected shared variable:**
```go
// BUG
var counter int
var wg sync.WaitGroup
for range 1000 {
    wg.Add(1)
    go func() {
        defer wg.Done()
        counter++ // DATA RACE
    }()
}
wg.Wait()

// FIX option 1: atomic
var counter atomic.Int64
// ... counter.Add(1) ...

// FIX option 2: mutex
var mu sync.Mutex
// ... mu.Lock(); counter++; mu.Unlock() ...

// FIX option 3: channel
counterCh := make(chan int, 1000)
// ... counterCh <- 1 ...
// total := 0; for v := range counterCh { total += v }
```

**2. Concurrent map access:**
```go
// BUG: fatal error: concurrent map writes
m := make(map[string]int)
go func() { m["a"] = 1 }()
go func() { m["b"] = 2 }()

// FIX option 1: sync.RWMutex
var mu sync.RWMutex
mu.Lock(); m["a"] = 1; mu.Unlock()

// FIX option 2: sync.Map
var sm sync.Map
sm.Store("a", 1)
```

**3. Race on slice append:**
```go
// BUG: concurrent slice append is not safe
var results []int
var wg sync.WaitGroup
for i := range 100 {
    wg.Add(1)
    go func() {
        defer wg.Done()
        results = append(results, process(i)) // RACE: slice header is shared
    }()
}

// FIX: use mutex or collect via channel
var mu sync.Mutex
go func() {
    defer wg.Done()
    result := process(i)
    mu.Lock()
    results = append(results, result)
    mu.Unlock()
}()
```

**4. Race on error variable:**
```go
// BUG
var finalErr error
for _, task := range tasks {
    go func() {
        if err := doTask(task); err != nil {
            finalErr = err // RACE
        }
    }()
}

// FIX: use errgroup
g, ctx := errgroup.WithContext(ctx)
for _, task := range tasks {
    g.Go(func() error { return doTask(task) })
}
finalErr = g.Wait() // safe: returns first error
```

### False Positives

The race detector has no false positives. If it reports a race, it's real.
However, it only finds races in executed code paths — not all possible races.

---

## Channel Misuse Patterns

### Sending on a Closed Channel

```go
// PANIC: send on closed channel
ch := make(chan int)
close(ch)
ch <- 1 // panic!

// FIX: use sync.Once for multi-sender close
type SafeChannel struct {
    ch   chan int
    once sync.Once
}

func (sc *SafeChannel) Close() {
    sc.once.Do(func() { close(sc.ch) })
}
```

### Closing a Nil Channel

```go
// PANIC
var ch chan int
close(ch) // panic: close of nil channel

// FIX: always initialize
ch = make(chan int)
```

### Reading from Nil Channel (Blocks Forever)

```go
// BUG: blocks forever
var ch chan int
<-ch // permanent block

// USEFUL: nil channel in select disables that case
func merge(a, b <-chan int) <-chan int {
    out := make(chan int)
    go func() {
        defer close(out)
        for a != nil || b != nil {
            select {
            case v, ok := <-a:
                if !ok { a = nil; continue }
                out <- v
            case v, ok := <-b:
                if !ok { b = nil; continue }
                out <- v
            }
        }
    }()
    return out
}
```

### Double Close

```go
// PANIC: close of closed channel
ch := make(chan int)
close(ch)
close(ch) // panic!

// FIX: track closure state or use sync.Once
```

### Forgetting to Close (Consumer Hangs)

```go
// BUG: consumer blocks forever on range
func produce(ch chan<- int) {
    for i := range 10 {
        ch <- i
    }
    // forgot close(ch)!
}

func consume(ch <-chan int) {
    for v := range ch { // blocks forever after last element
        fmt.Println(v)
    }
}
```

---

## Context Cancellation Not Propagating

### Common Bug: Using Background Instead of Parent Context

```go
// BUG: cancellation of parent ctx doesn't propagate
func handler(ctx context.Context) error {
    // This goroutine ignores parent cancellation!
    go func() {
        doWork(context.Background()) // should use ctx
    }()
    return nil
}

// FIX: pass parent context
func handler(ctx context.Context) error {
    go func() {
        doWork(ctx)
    }()
    return nil
}
```

### Missing ctx.Done() Check in Loops

```go
// BUG: loop never checks for cancellation
func processItems(ctx context.Context, items []Item) error {
    for _, item := range items {
        if err := process(item); err != nil {
            return err
        }
        // Never checks ctx.Done()!
    }
    return nil
}

// FIX: check context in each iteration
func processItems(ctx context.Context, items []Item) error {
    for _, item := range items {
        select {
        case <-ctx.Done():
            return ctx.Err()
        default:
        }
        if err := process(item); err != nil {
            return err
        }
    }
    return nil
}
```

### Cancelled Context Passed to New Operations

```go
// BUG: using already-cancelled context for cleanup
func handler(ctx context.Context) {
    // ctx is cancelled when request completes
    defer cleanup(ctx) // may fail if cleanup needs network calls!
}

// FIX: use a separate context for cleanup
func handler(ctx context.Context) {
    defer func() {
        cleanupCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
        defer cancel()
        cleanup(cleanupCtx)
    }()
}
```

### Not Calling cancel()

```go
// BUG: timer resources leak
ctx, cancel := context.WithTimeout(parentCtx, 5*time.Second)
// forgot defer cancel()!
result := doWork(ctx)

// FIX: always defer cancel
ctx, cancel := context.WithTimeout(parentCtx, 5*time.Second)
defer cancel() // releases timer even if doWork finishes early
```

---

## WaitGroup Counter Bugs

### Add() Inside Goroutine

```go
// BUG: race between wg.Add and wg.Wait
var wg sync.WaitGroup
for range 10 {
    go func() {
        wg.Add(1)    // may execute after wg.Wait() is called!
        defer wg.Done()
        doWork()
    }()
}
wg.Wait() // might return before all goroutines start

// FIX: call Add before launching goroutine
var wg sync.WaitGroup
for range 10 {
    wg.Add(1) // before go func()
    go func() {
        defer wg.Done()
        doWork()
    }()
}
wg.Wait()
```

### Mismatched Add/Done Counts

```go
// BUG: counter goes negative → panic
wg.Add(1)
go func() {
    defer wg.Done()
    if err := doWork(); err != nil {
        wg.Done() // double Done → panic: negative WaitGroup counter
        return
    }
}()

// FIX: single defer wg.Done() at function start
wg.Add(1)
go func() {
    defer wg.Done() // exactly once, always
    if err := doWork(); err != nil {
        log.Println(err)
        return
    }
}()
```

### Reusing WaitGroup Before Wait Returns

```go
// BUG: reusing before Wait() returns is a race
wg.Wait()
wg.Add(1) // OK only if Wait() has fully returned

// FIX: use a new WaitGroup or ensure sequential execution
```

---

## Mutex Starvation

### Problem: Writers Starved by Readers

With `sync.RWMutex`, a continuous stream of readers can starve writers:

```go
// Scenario: readers keep acquiring RLock, writer never gets Lock
var rw sync.RWMutex

// Many goroutines doing:
rw.RLock()
time.Sleep(1 * time.Millisecond) // hold lock briefly but frequently
rw.RUnlock()

// One goroutine trying to write:
rw.Lock() // waits indefinitely if readers overlap
defer rw.Unlock()
```

**Note:** Go's `sync.RWMutex` since Go 1.x gives pending writers priority over new
readers (writer-preferring), which mitigates but doesn't eliminate starvation under
extreme read contention.

### Fixes

**1. Use regular Mutex if write performance matters:**
```go
var mu sync.Mutex // equal priority for all goroutines
```

**2. Batch reads:**
```go
// Instead of many short reads, batch into fewer longer reads
func batchRead(mu *sync.RWMutex, keys []string, data map[string]int) []int {
    mu.RLock()
    defer mu.RUnlock()
    results := make([]int, len(keys))
    for i, k := range keys {
        results[i] = data[k]
    }
    return results
}
```

**3. Use sharded map to reduce contention entirely (see advanced-patterns.md).**

### Detecting Lock Contention

```bash
# Mutex contention profile
go test -bench=. -mutexprofile=mutex.out ./...
go tool pprof mutex.out

# Block profile (time spent waiting for locks/channels)
go test -bench=. -blockprofile=block.out ./...
go tool pprof block.out
```

---

## Performance Debugging with go tool trace

### Capturing a Trace

**Option 1: In tests**
```bash
go test -trace=trace.out ./...
go tool trace trace.out
```

**Option 2: In application code**
```go
import "runtime/trace"

func main() {
    f, _ := os.Create("trace.out")
    defer f.Close()
    trace.Start(f)
    defer trace.Stop()
    // ... application code ...
}
```

**Option 3: HTTP endpoint**
```go
import _ "net/http/pprof"

// Capture 5 seconds of trace:
// curl -o trace.out http://localhost:6060/debug/pprof/trace?seconds=5
// go tool trace trace.out
```

### What to Look For in Traces

| View | Shows | Look For |
|------|-------|----------|
| Goroutine analysis | Per-goroutine execution time | Goroutines spending most time in "sync" or "waiting" |
| Network/Sync blocking | Lock contention, channel waits | Long blocks on mutex or channel operations |
| Scheduler latency | Time between runnable and running | High latency = too many goroutines competing |
| Syscall blocking | OS-level blocking | Excessive file I/O or network calls |
| GC events | Garbage collection pauses | Frequent or long GC pauses affecting latency |

### Profiling Commands Cheat Sheet

```bash
# CPU profile
go test -bench=. -cpuprofile=cpu.out ./...
go tool pprof -http=:8080 cpu.out

# Memory profile
go test -bench=. -memprofile=mem.out ./...
go tool pprof -http=:8080 mem.out

# Goroutine profile (live application)
go tool pprof http://localhost:6060/debug/pprof/goroutine

# Block profile (where goroutines block)
go tool pprof http://localhost:6060/debug/pprof/block

# Mutex contention profile
go tool pprof http://localhost:6060/debug/pprof/mutex

# Trace (5 seconds)
curl -o trace.out http://localhost:6060/debug/pprof/trace?seconds=5
go tool trace trace.out

# Compare profiles (before/after optimization)
go tool pprof -diff_base=before.out after.out
```

### Automated Goroutine Leak Check Script

```bash
#!/bin/bash
# Check for goroutine count growth over time
URL="${1:-http://localhost:6060}"
echo "Monitoring goroutine count at $URL..."
for i in $(seq 1 10); do
    count=$(curl -s "$URL/debug/pprof/goroutine?debug=0" | head -1 | grep -oP 'goroutine profile: total \K[0-9]+')
    echo "$(date +%H:%M:%S) goroutines: $count"
    sleep 5
done
```

### Key Metrics to Monitor

- **runtime.NumGoroutine()**: Should be stable in steady state. Growing = leak.
- **runtime.NumCgoCall()**: Tracks CGo crossings. Each blocks an OS thread.
- **runtime.ReadMemStats()**: `Sys` for total memory, `NumGC` for GC frequency.
- **Mutex wait time** (via pprof): High values indicate contention.
- **Channel block time** (via block profile): Reveals slow consumers/producers.
