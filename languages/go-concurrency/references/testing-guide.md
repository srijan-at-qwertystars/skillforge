# Testing Concurrent Go Code

Comprehensive guide to writing reliable tests for concurrent Go programs.

## Table of Contents

- [Race Detector Usage](#race-detector-usage)
- [Testing with Timeouts](#testing-with-timeouts)
- [Deterministic Testing with Channels](#deterministic-testing-with-channels)
- [Goroutine Leak Detection with goleak](#goroutine-leak-detection-with-goleak)
- [Testing Context Cancellation](#testing-context-cancellation)
- [Benchmarking Concurrent Code](#benchmarking-concurrent-code)
- [Fuzz Testing Concurrent Operations](#fuzz-testing-concurrent-operations)
- [Table-Driven Concurrent Tests](#table-driven-concurrent-tests)
- [Testing with errgroup](#testing-with-errgroup)

---

## Race Detector Usage

### Basic Usage

```bash
# Run all tests with race detection
go test -race ./...

# Run specific test with race detection
go test -race -run TestMyFunction ./pkg/...

# Build binary with race detection for integration tests
go build -race -o app_race .
./app_race

# Run with race detection in CI (recommended)
go test -race -count=1 -timeout=5m ./...
```

### Configuring Race Detector Behavior

```bash
# Environment variables for race detector
GORACE="halt_on_error=1"           # stop on first race (default: 0, logs and continues)
GORACE="log_path=race.log"         # write reports to file instead of stderr
GORACE="history_size=5"            # increase stack trace depth (default: 1, range: 0-7)
GORACE="atexit_sleep_ms=0"         # don't sleep on exit (useful in CI)

# Combined
GORACE="halt_on_error=1 history_size=3" go test -race ./...
```

### Running Tests Multiple Times to Surface Races

```bash
# Run each test 100 times — races are timing-dependent
go test -race -count=100 ./...

# With stress tool (golang.org/x/tools/cmd/stress)
go install golang.org/x/tools/cmd/stress@latest
stress -p 4 go test -race ./pkg/mypackage
```

### Interpreting Race Detector Output

```
WARNING: DATA RACE
Read at 0x00c0000b4018 by goroutine 8:    ← what was read and by which goroutine
  main.(*Counter).Get()
      /app/counter.go:15 +0x3c           ← file and line number

Previous write at 0x00c0000b4018 by goroutine 7:  ← conflicting write
  main.(*Counter).Increment()
      /app/counter.go:11 +0x50

Goroutine 8 (running) created at:         ← where the goroutine was spawned
  main.TestCounter()
      /app/counter_test.go:22 +0x88

Goroutine 7 (finished) created at:
  main.TestCounter()
      /app/counter_test.go:20 +0x68
```

**Action:** Look at both file:line references. Protect the shared variable with a mutex
or atomic operation.

---

## Testing with Timeouts

### Context-Based Timeouts (Preferred)

```go
func TestSlowOperation(t *testing.T) {
    ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
    defer cancel()

    result, err := SlowOperation(ctx)
    if err != nil {
        t.Fatalf("unexpected error: %v", err)
    }
    if result != expected {
        t.Errorf("got %v, want %v", result, expected)
    }
}
```

### Testing That Operations Complete Within Time

```go
func TestCompletesInTime(t *testing.T) {
    done := make(chan struct{})
    go func() {
        defer close(done)
        DoWork()
    }()

    select {
    case <-done:
        // success
    case <-time.After(3 * time.Second):
        t.Fatal("operation did not complete within 3 seconds")
    }
}
```

### Testing Timeouts Fire Correctly

```go
func TestOperationTimesOut(t *testing.T) {
    ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
    defer cancel()

    _, err := SlowOperation(ctx)
    if !errors.Is(err, context.DeadlineExceeded) {
        t.Errorf("expected DeadlineExceeded, got: %v", err)
    }
}
```

### Global Test Timeout

```bash
# Set timeout for entire test binary
go test -timeout=30s ./...

# Per-test timeout via t.Deadline() (Go 1.15+)
func TestWithDeadline(t *testing.T) {
    deadline, ok := t.Deadline()
    if ok {
        ctx, cancel := context.WithDeadline(context.Background(), deadline)
        defer cancel()
        runTest(ctx)
    }
}
```

---

## Deterministic Testing with Channels

Use channels to create deterministic ordering in tests, avoiding `time.Sleep`.

### Synchronization Barriers

```go
func TestPipeline(t *testing.T) {
    // Use channels to enforce ordering
    step1Done := make(chan struct{})
    step2Done := make(chan struct{})

    var result int

    go func() {
        result = ComputeStep1()
        close(step1Done)
    }()

    go func() {
        <-step1Done // wait for step 1
        result = ComputeStep2(result)
        close(step2Done)
    }()

    <-step2Done
    if result != expectedFinal {
        t.Errorf("got %d, want %d", result, expectedFinal)
    }
}
```

### Testing Producer-Consumer

```go
func TestProducerConsumer(t *testing.T) {
    ctx, cancel := context.WithCancel(context.Background())
    defer cancel()

    ch := Producer(ctx, []int{1, 2, 3, 4, 5})

    var got []int
    for v := range ch {
        got = append(got, v)
    }

    // Don't assert order for concurrent operations — sort first
    sort.Ints(got)
    want := []int{1, 2, 3, 4, 5}
    if !reflect.DeepEqual(got, want) {
        t.Errorf("got %v, want %v", got, want)
    }
}
```

### Injecting Controllable Dependencies

```go
type Clock interface {
    Now() time.Time
    After(d time.Duration) <-chan time.Time
}

type fakeClock struct {
    now  time.Time
    ch   chan time.Time
}

func (f *fakeClock) Now() time.Time                          { return f.now }
func (f *fakeClock) After(d time.Duration) <-chan time.Time   { return f.ch }
func (f *fakeClock) Advance(d time.Duration)                  { f.now = f.now.Add(d); f.ch <- f.now }

func TestRateLimiterWithFakeClock(t *testing.T) {
    clock := &fakeClock{now: time.Now(), ch: make(chan time.Time, 1)}
    limiter := NewRateLimiter(clock, 10) // 10 req/s

    // First request succeeds
    if !limiter.Allow() {
        t.Error("expected first request to be allowed")
    }

    // Advance time to allow next request
    clock.Advance(200 * time.Millisecond)
    if !limiter.Allow() {
        t.Error("expected request after time advance to be allowed")
    }
}
```

---

## Goroutine Leak Detection with goleak

### Installation

```bash
go get go.uber.org/goleak
```

### TestMain Hook (Recommended)

```go
package mypackage_test

import (
    "testing"
    "go.uber.org/goleak"
)

func TestMain(m *testing.M) {
    goleak.VerifyTestMain(m)
}
```

### Per-Test Usage

```go
func TestNoLeak(t *testing.T) {
    defer goleak.VerifyNone(t)

    ctx, cancel := context.WithCancel(context.Background())
    ch := StartWorker(ctx)
    cancel()     // must trigger worker shutdown
    <-ch         // wait for worker to exit
}
```

### Ignoring Known Goroutines

```go
func TestMain(m *testing.M) {
    goleak.VerifyTestMain(m,
        goleak.IgnoreTopFunction("go.opencensus.io/stats/view.(*worker).start"),
        goleak.IgnoreTopFunction("database/sql.(*DB).connectionOpener"),
    )
}
```

### What It Catches

goleak snapshots goroutines at the start and end of a test. Extra goroutines at
the end are reported as leaks. Common causes:

- Goroutines blocked on channel sends/receives with no cancellation
- Background goroutines started without cleanup
- HTTP servers not shut down
- Tickers not stopped

---

## Testing Context Cancellation

### Test That Work Stops on Cancel

```go
func TestStopsOnCancel(t *testing.T) {
    ctx, cancel := context.WithCancel(context.Background())

    results := make(chan int, 100)
    go ProcessItems(ctx, items, results)

    // Let it process some items
    for range 5 {
        <-results
    }

    cancel() // cancel the context

    // Verify it stops producing results
    time.Sleep(50 * time.Millisecond) // brief wait for propagation

    select {
    case _, ok := <-results:
        if ok {
            // Might get one more in-flight result — that's OK
        }
    default:
    }

    // Key assertion: goroutine exited (use goleak or NumGoroutine)
}
```

### Test That Error Is ctx.Err()

```go
func TestReturnsCancelError(t *testing.T) {
    ctx, cancel := context.WithCancel(context.Background())
    cancel() // cancel immediately

    err := DoWork(ctx)
    if !errors.Is(err, context.Canceled) {
        t.Errorf("got %v, want context.Canceled", err)
    }
}

func TestReturnsDeadlineError(t *testing.T) {
    ctx, cancel := context.WithTimeout(context.Background(), 1*time.Nanosecond)
    defer cancel()
    time.Sleep(1 * time.Millisecond) // ensure deadline passes

    err := DoWork(ctx)
    if !errors.Is(err, context.DeadlineExceeded) {
        t.Errorf("got %v, want context.DeadlineExceeded", err)
    }
}
```

### Test Propagation Through Layers

```go
func TestCancelPropagates(t *testing.T) {
    ctx, cancel := context.WithCancel(context.Background())

    // Track which layers saw the cancellation
    var layer1Cancelled, layer2Cancelled atomic.Bool

    go func() {
        err := Layer1(ctx) // internally calls Layer2(ctx)
        if errors.Is(err, context.Canceled) {
            layer1Cancelled.Store(true)
        }
    }()

    cancel()
    time.Sleep(100 * time.Millisecond)

    if !layer1Cancelled.Load() {
        t.Error("layer 1 did not observe cancellation")
    }
}
```

---

## Benchmarking Concurrent Code

### Basic Concurrent Benchmark

```go
func BenchmarkWorkerPool(b *testing.B) {
    ctx := context.Background()
    b.RunParallel(func(pb *testing.PB) {
        for pb.Next() {
            DoWork(ctx)
        }
    })
}
```

### Benchmarking Different Concurrency Levels

```go
func BenchmarkPool(b *testing.B) {
    for _, workers := range []int{1, 2, 4, 8, 16, 32, 64} {
        b.Run(fmt.Sprintf("workers=%d", workers), func(b *testing.B) {
            pool := NewPool(workers)
            defer pool.Close()
            b.ResetTimer()
            b.RunParallel(func(pb *testing.PB) {
                for pb.Next() {
                    pool.Submit(work)
                }
            })
        })
    }
}
```

### Benchmarking Lock Contention

```go
func BenchmarkMutexVsRWMutex(b *testing.B) {
    b.Run("Mutex", func(b *testing.B) {
        var mu sync.Mutex
        var val int
        b.RunParallel(func(pb *testing.PB) {
            for pb.Next() {
                mu.Lock()
                val++
                mu.Unlock()
            }
        })
    })

    b.Run("RWMutex-Write", func(b *testing.B) {
        var mu sync.RWMutex
        var val int
        b.RunParallel(func(pb *testing.PB) {
            for pb.Next() {
                mu.Lock()
                val++
                mu.Unlock()
            }
        })
    })

    b.Run("Atomic", func(b *testing.B) {
        var val atomic.Int64
        b.RunParallel(func(pb *testing.PB) {
            for pb.Next() {
                val.Add(1)
            }
        })
    })
}
```

### Running Benchmarks

```bash
# Basic benchmark
go test -bench=. -benchmem ./...

# With CPU profile
go test -bench=BenchmarkPool -cpuprofile=cpu.out ./...
go tool pprof cpu.out

# Compare before/after with benchstat
go install golang.org/x/perf/cmd/benchstat@latest
go test -bench=. -count=10 ./... > old.txt
# ... make changes ...
go test -bench=. -count=10 ./... > new.txt
benchstat old.txt new.txt
```

---

## Fuzz Testing Concurrent Operations

### Basic Concurrent Fuzz Test

```go
func FuzzConcurrentMap(f *testing.F) {
    f.Add("key1", "value1")
    f.Add("key2", "value2")

    f.Fuzz(func(t *testing.T, key, value string) {
        m := NewConcurrentMap()
        var wg sync.WaitGroup

        // Concurrent writes
        for range 10 {
            wg.Add(1)
            go func() {
                defer wg.Done()
                m.Set(key, value)
            }()
        }

        // Concurrent reads
        for range 10 {
            wg.Add(1)
            go func() {
                defer wg.Done()
                m.Get(key)
            }()
        }

        wg.Wait()

        // Verify invariant: key exists with correct value
        got, ok := m.Get(key)
        if !ok {
            t.Errorf("key %q not found after concurrent writes", key)
        }
        if got != value {
            t.Errorf("got %q, want %q", got, value)
        }
    })
}
```

### Fuzz Testing with Race Detector

```bash
# Fuzz tests + race detector find deep concurrency bugs
go test -fuzz=FuzzConcurrentMap -race -fuzztime=30s ./...
```

### Fuzz Testing Channel Operations

```go
func FuzzPipeline(f *testing.F) {
    f.Add(uint(5), uint(3))

    f.Fuzz(func(t *testing.T, numItems, numWorkers uint) {
        if numItems == 0 || numWorkers == 0 || numItems > 1000 || numWorkers > 100 {
            t.Skip()
        }

        ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
        defer cancel()

        items := make([]int, numItems)
        for i := range items {
            items[i] = i
        }

        results := ProcessPipeline(ctx, items, int(numWorkers))

        var got []int
        for r := range results {
            got = append(got, r)
        }

        if len(got) != len(items) {
            t.Errorf("got %d results, want %d", len(got), len(items))
        }
    })
}
```

---

## Table-Driven Concurrent Tests

### Pattern

```go
func TestWorkerPool(t *testing.T) {
    tests := []struct {
        name       string
        numJobs    int
        numWorkers int
        wantCount  int
        timeout    time.Duration
    }{
        {"single worker single job", 1, 1, 1, 1 * time.Second},
        {"multiple workers", 100, 10, 100, 5 * time.Second},
        {"more workers than jobs", 5, 20, 5, 1 * time.Second},
        {"single worker many jobs", 50, 1, 50, 10 * time.Second},
    }

    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            t.Parallel() // run table entries concurrently

            ctx, cancel := context.WithTimeout(context.Background(), tt.timeout)
            defer cancel()

            results := RunPool(ctx, tt.numJobs, tt.numWorkers)

            var count int
            for range results {
                count++
            }

            if count != tt.wantCount {
                t.Errorf("got %d results, want %d", count, tt.wantCount)
            }
        })
    }
}
```

### Testing Error Scenarios

```go
func TestConcurrentErrors(t *testing.T) {
    tests := []struct {
        name      string
        failAt    int  // which job to fail at
        wantErr   bool
        wantDone  int  // minimum completed before error
    }{
        {"no errors", -1, false, 10},
        {"first job fails", 0, true, 0},
        {"middle job fails", 5, true, 4},
        {"last job fails", 9, true, 9},
    }

    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            t.Parallel()

            var completed atomic.Int32
            ctx, cancel := context.WithCancel(context.Background())
            defer cancel()

            g, ctx := errgroup.WithContext(ctx)
            for i := range 10 {
                g.Go(func() error {
                    if i == tt.failAt {
                        return fmt.Errorf("job %d failed", i)
                    }
                    completed.Add(1)
                    return nil
                })
            }

            err := g.Wait()
            if (err != nil) != tt.wantErr {
                t.Errorf("error = %v, wantErr %v", err, tt.wantErr)
            }
        })
    }
}
```

---

## Testing with errgroup

### Testing errgroup Cancellation

```go
func TestErrgroupCancelsOnError(t *testing.T) {
    g, ctx := errgroup.WithContext(context.Background())

    // This goroutine will fail
    g.Go(func() error {
        return errors.New("intentional failure")
    })

    // This goroutine should observe cancellation
    cancelled := make(chan bool, 1)
    g.Go(func() error {
        select {
        case <-ctx.Done():
            cancelled <- true
            return ctx.Err()
        case <-time.After(5 * time.Second):
            cancelled <- false
            return nil
        }
    })

    err := g.Wait()
    if err == nil {
        t.Fatal("expected error")
    }

    if !<-cancelled {
        t.Error("second goroutine was not cancelled")
    }
}
```

### Testing errgroup.SetLimit

```go
func TestErrgroupConcurrencyLimit(t *testing.T) {
    g, _ := errgroup.WithContext(context.Background())
    g.SetLimit(3)

    var maxConcurrent atomic.Int32
    var current atomic.Int32

    for range 20 {
        g.Go(func() error {
            cur := current.Add(1)
            defer current.Add(-1)

            // Track peak concurrency
            for {
                old := maxConcurrent.Load()
                if cur <= old || maxConcurrent.CompareAndSwap(old, cur) {
                    break
                }
            }

            time.Sleep(10 * time.Millisecond)
            return nil
        })
    }

    if err := g.Wait(); err != nil {
        t.Fatal(err)
    }

    peak := maxConcurrent.Load()
    if peak > 3 {
        t.Errorf("peak concurrency was %d, want <= 3", peak)
    }
}
```

### Testing errgroup Result Collection

```go
func TestErrgroupResultCollection(t *testing.T) {
    g, ctx := errgroup.WithContext(context.Background())
    g.SetLimit(5)

    var mu sync.Mutex
    results := make(map[int]int)

    for i := range 10 {
        g.Go(func() error {
            select {
            case <-ctx.Done():
                return ctx.Err()
            default:
            }

            result := compute(i)

            mu.Lock()
            results[i] = result
            mu.Unlock()
            return nil
        })
    }

    if err := g.Wait(); err != nil {
        t.Fatal(err)
    }

    if len(results) != 10 {
        t.Errorf("got %d results, want 10", len(results))
    }
}
```

### Helper: assertEventually

For assertions that depend on goroutines completing asynchronously:

```go
func assertEventually(t *testing.T, condition func() bool, timeout time.Duration, msg string) {
    t.Helper()
    deadline := time.Now().Add(timeout)
    for time.Now().Before(deadline) {
        if condition() {
            return
        }
        time.Sleep(10 * time.Millisecond)
    }
    t.Errorf("condition not met within %v: %s", timeout, msg)
}

// Usage:
assertEventually(t, func() bool {
    return server.ConnectionCount() == 0
}, 5*time.Second, "connections should drain")
```
