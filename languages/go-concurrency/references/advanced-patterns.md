# Advanced Go Concurrency Patterns

Dense reference for production-grade concurrency patterns beyond the basics.

## Table of Contents

- [Pipeline Stages with Cancellation](#pipeline-stages-with-cancellation)
- [Bounded Parallelism](#bounded-parallelism)
- [Sharded Maps for High-Contention Scenarios](#sharded-maps-for-high-contention-scenarios)
- [Lock-Free Data Structures with Atomic](#lock-free-data-structures-with-atomic)
- [Singleflight for Request Deduplication](#singleflight-for-request-deduplication)
- [Rate Limiting](#rate-limiting)
- [Circuit Breaker Pattern](#circuit-breaker-pattern)
- [Pub/Sub with Channels](#pubsub-with-channels)
- [Graceful Degradation Patterns](#graceful-degradation-patterns)

---

## Pipeline Stages with Cancellation

A pipeline is a series of stages connected by channels where each stage is a group of
goroutines running the same function. Each stage receives values from upstream via inbound
channels, performs work, and sends values downstream via outbound channels.

### Stage Function Signature

```go
// Every stage accepts a context for cancellation and returns a read-only output channel.
type Stage[In, Out any] func(ctx context.Context, in <-chan In) <-chan Out
```

### Cancellable Pipeline Builder

```go
func PipelineStage[In, Out any](
    ctx context.Context,
    in <-chan In,
    fn func(context.Context, In) (Out, error),
) (<-chan Out, <-chan error) {
    out := make(chan Out)
    errc := make(chan error, 1)
    go func() {
        defer close(out)
        defer close(errc)
        for v := range in {
            select {
            case <-ctx.Done():
                errc <- ctx.Err()
                return
            default:
            }
            result, err := fn(ctx, v)
            if err != nil {
                errc <- err
                return
            }
            select {
            case out <- result:
            case <-ctx.Done():
                errc <- ctx.Err()
                return
            }
        }
    }()
    return out, errc
}
```

### Multi-Stage Pipeline with Error Merging

```go
func MergeErrors(ctx context.Context, errChans ...<-chan error) <-chan error {
    var wg sync.WaitGroup
    merged := make(chan error)
    for _, ec := range errChans {
        wg.Add(1)
        go func() {
            defer wg.Done()
            for err := range ec {
                select {
                case merged <- err:
                case <-ctx.Done():
                    return
                }
            }
        }()
    }
    go func() { wg.Wait(); close(merged) }()
    return merged
}
```

### Usage Pattern

```go
ctx, cancel := context.WithCancel(context.Background())
defer cancel()

source := generate(ctx, rawData...)
validated, errs1 := PipelineStage(ctx, source, validate)
transformed, errs2 := PipelineStage(ctx, validated, transform)
stored, errs3 := PipelineStage(ctx, transformed, store)

// Consume results and errors concurrently
go func() {
    for err := range MergeErrors(ctx, errs1, errs2, errs3) {
        log.Printf("pipeline error: %v", err)
        cancel() // cancel on first error, or collect all
    }
}()
for result := range stored {
    fmt.Println(result)
}
```

**Key rules:**
- Always pass context to every stage — enables cascading cancellation.
- Every stage must check `ctx.Done()` both before processing and before sending.
- Close output channels in the same goroutine that writes to them.
- Buffer error channels to prevent goroutine leaks when errors are ignored.

---

## Bounded Parallelism

Control the maximum number of concurrent goroutines to prevent resource exhaustion.

### Semaphore-Based

```go
func ProcessBounded(ctx context.Context, items []Item, maxWorkers int) error {
    sem := make(chan struct{}, maxWorkers)
    g, ctx := errgroup.WithContext(ctx)

    for _, item := range items {
        select {
        case <-ctx.Done():
            break
        case sem <- struct{}{}:
        }
        g.Go(func() error {
            defer func() { <-sem }()
            return process(ctx, item)
        })
    }
    return g.Wait()
}
```

### errgroup.SetLimit (preferred since Go 1.20+)

```go
func ProcessBounded(ctx context.Context, items []Item, maxWorkers int) error {
    g, ctx := errgroup.WithContext(ctx)
    g.SetLimit(maxWorkers)
    for _, item := range items {
        g.Go(func() error {
            return process(ctx, item)
        })
    }
    return g.Wait()
}
```

### Weighted Semaphore (golang.org/x/sync/semaphore)

Use when tasks have variable cost (e.g., memory, connections):

```go
import "golang.org/x/sync/semaphore"

var sem = semaphore.NewWeighted(int64(maxMemoryMB))

func processLargeFile(ctx context.Context, f File) error {
    weight := int64(f.SizeMB)
    if err := sem.Acquire(ctx, weight); err != nil {
        return err
    }
    defer sem.Release(weight)
    return doWork(f)
}
```

---

## Sharded Maps for High-Contention Scenarios

When `sync.Map` or `map+sync.RWMutex` becomes a bottleneck under high write contention,
shard the map to distribute lock contention across N independent mutexes.

### Implementation

```go
const numShards = 64

type ShardedMap[K comparable, V any] struct {
    shards [numShards]struct {
        mu    sync.RWMutex
        items map[K]V
    }
    hasher func(K) uint64
}

func NewShardedMap[K comparable, V any](hasher func(K) uint64) *ShardedMap[K, V] {
    sm := &ShardedMap[K, V]{hasher: hasher}
    for i := range sm.shards {
        sm.shards[i].items = make(map[K]V)
    }
    return sm
}

func (sm *ShardedMap[K, V]) shard(key K) *struct {
    mu    sync.RWMutex
    items map[K]V
} {
    return &sm.shards[sm.hasher(key)%numShards]
}

func (sm *ShardedMap[K, V]) Set(key K, val V) {
    s := sm.shard(key)
    s.mu.Lock()
    s.items[key] = val
    s.mu.Unlock()
}

func (sm *ShardedMap[K, V]) Get(key K) (V, bool) {
    s := sm.shard(key)
    s.mu.RLock()
    v, ok := s.items[key]
    s.mu.RUnlock()
    return v, ok
}

func (sm *ShardedMap[K, V]) Delete(key K) {
    s := sm.shard(key)
    s.mu.Lock()
    delete(s.items, key)
    s.mu.Unlock()
}
```

### When to Use

| Approach | Best For |
|----------|----------|
| `map` + `sync.RWMutex` | General use, moderate contention |
| `sync.Map` | Read-heavy, stable key sets, disjoint writers |
| `ShardedMap` | High write contention, many keys, uniform access |

**Shard count:** Power of 2, typically 32–256. Benchmark to find optimal value.
Use `maphash.String` or FNV for hash functions.

---

## Lock-Free Data Structures with Atomic

### Lock-Free Counter with CAS

```go
type LockFreeCounter struct {
    val atomic.Int64
}

func (c *LockFreeCounter) IncrementIfBelow(limit int64) bool {
    for {
        current := c.val.Load()
        if current >= limit {
            return false
        }
        if c.val.CompareAndSwap(current, current+1) {
            return true
        }
        // CAS failed — another goroutine won the race; retry
    }
}
```

### Lock-Free Stack (Treiber Stack)

```go
type node[T any] struct {
    val  T
    next *node[T]
}

type LockFreeStack[T any] struct {
    head atomic.Pointer[node[T]]
}

func (s *LockFreeStack[T]) Push(val T) {
    n := &node[T]{val: val}
    for {
        old := s.head.Load()
        n.next = old
        if s.head.CompareAndSwap(old, n) {
            return
        }
    }
}

func (s *LockFreeStack[T]) Pop() (T, bool) {
    for {
        old := s.head.Load()
        if old == nil {
            var zero T
            return zero, false
        }
        if s.head.CompareAndSwap(old, old.next) {
            return old.val, true
        }
    }
}
```

### Atomic Value for Config Reload

```go
var cfg atomic.Value // stores *Config

func loadConfig() {
    newCfg := readConfigFromFile()
    cfg.Store(newCfg) // atomic swap, no lock
}

func getConfig() *Config {
    return cfg.Load().(*Config) // lock-free read
}
```

**When to use lock-free:** Only when benchmarks prove mutex is a bottleneck. Lock-free
code is harder to reason about and debug. Prefer `sync.Mutex` for correctness-first code.

---

## Singleflight for Request Deduplication

Collapse concurrent calls for the same key into a single execution.

```go
import "golang.org/x/sync/singleflight"

var group singleflight.Group

func GetUser(ctx context.Context, id string) (*User, error) {
    v, err, shared := group.Do(id, func() (any, error) {
        // Only one goroutine executes this per unique key
        return fetchUserFromDB(ctx, id)
    })
    if shared {
        metrics.Increment("cache.singleflight.shared")
    }
    if err != nil {
        return nil, err
    }
    return v.(*User), nil
}
```

### Singleflight with Cache

```go
func GetUserCached(ctx context.Context, id string) (*User, error) {
    // Check cache first
    if u, ok := cache.Get(id); ok {
        return u, nil
    }
    // Deduplicate concurrent cache misses
    v, err, _ := group.Do("user:"+id, func() (any, error) {
        // Double-check cache inside singleflight
        if u, ok := cache.Get(id); ok {
            return u, nil
        }
        u, err := fetchUserFromDB(ctx, id)
        if err != nil {
            return nil, err
        }
        cache.Set(id, u, 5*time.Minute)
        return u, nil
    })
    if err != nil {
        return nil, err
    }
    return v.(*User), nil
}
```

### DoChan for Context-Aware Singleflight

```go
func GetUserWithTimeout(ctx context.Context, id string) (*User, error) {
    ch := group.DoChan(id, func() (any, error) {
        return fetchUserFromDB(context.Background(), id)
    })
    select {
    case result := <-ch:
        if result.Err != nil {
            return nil, result.Err
        }
        return result.Val.(*User), nil
    case <-ctx.Done():
        return nil, ctx.Err()
    }
}
```

**Caveat:** Singleflight shares errors too. If the single execution fails, all waiters
get the same error. Use `group.Forget(key)` to allow retry on transient errors.

---

## Rate Limiting

### time.Ticker-Based Rate Limiter

```go
func RateLimitedProcess(ctx context.Context, items <-chan Item, rps int) {
    ticker := time.NewTicker(time.Second / time.Duration(rps))
    defer ticker.Stop()
    for item := range items {
        select {
        case <-ctx.Done():
            return
        case <-ticker.C:
            process(item)
        }
    }
}
```

### golang.org/x/time/rate (Token Bucket)

```go
import "golang.org/x/time/rate"

// 10 requests/second with burst of 30
limiter := rate.NewLimiter(rate.Limit(10), 30)

func HandleRequest(ctx context.Context, req Request) error {
    // Wait blocks until token is available or context expires
    if err := limiter.Wait(ctx); err != nil {
        return fmt.Errorf("rate limited: %w", err)
    }
    return processRequest(req)
}

// Non-blocking check
if !limiter.Allow() {
    return ErrRateLimited
}

// Reserve a token (for scheduling)
r := limiter.Reserve()
time.Sleep(r.Delay())
process()
```

### Per-Key Rate Limiting

```go
type PerKeyLimiter struct {
    mu       sync.Mutex
    limiters map[string]*rate.Limiter
    rate     rate.Limit
    burst    int
}

func (pkl *PerKeyLimiter) GetLimiter(key string) *rate.Limiter {
    pkl.mu.Lock()
    defer pkl.mu.Unlock()
    if l, ok := pkl.limiters[key]; ok {
        return l
    }
    l := rate.NewLimiter(pkl.rate, pkl.burst)
    pkl.limiters[key] = l
    return l
}
```

### Adaptive Rate Limiting

```go
func AdaptiveRateLimiter(ctx context.Context, limiter *rate.Limiter) {
    ticker := time.NewTicker(10 * time.Second)
    defer ticker.Stop()
    for {
        select {
        case <-ctx.Done():
            return
        case <-ticker.C:
            errorRate := metrics.GetErrorRate()
            switch {
            case errorRate > 0.5:
                limiter.SetLimit(limiter.Limit() * 0.5) // back off aggressively
            case errorRate > 0.1:
                limiter.SetLimit(limiter.Limit() * 0.8) // back off gently
            case errorRate < 0.01:
                limiter.SetLimit(limiter.Limit() * 1.1) // increase cautiously
            }
        }
    }
}
```

---

## Circuit Breaker Pattern

Prevent cascading failures by stopping calls to a failing downstream service.

### State Machine

```
CLOSED → (failure threshold exceeded) → OPEN
OPEN   → (timeout expires)           → HALF-OPEN
HALF-OPEN → (probe succeeds)         → CLOSED
HALF-OPEN → (probe fails)            → OPEN
```

### Implementation

```go
type State int

const (
    StateClosed State = iota
    StateOpen
    StateHalfOpen
)

type CircuitBreaker struct {
    mu               sync.Mutex
    state            State
    failures         int
    successes        int
    maxFailures      int
    resetTimeout     time.Duration
    halfOpenMax      int
    lastFailureTime  time.Time
}

func NewCircuitBreaker(maxFailures int, resetTimeout time.Duration) *CircuitBreaker {
    return &CircuitBreaker{
        maxFailures:  maxFailures,
        resetTimeout: resetTimeout,
        halfOpenMax:  1,
    }
}

func (cb *CircuitBreaker) Execute(fn func() error) error {
    cb.mu.Lock()
    switch cb.state {
    case StateOpen:
        if time.Since(cb.lastFailureTime) > cb.resetTimeout {
            cb.state = StateHalfOpen
            cb.successes = 0
        } else {
            cb.mu.Unlock()
            return ErrCircuitOpen
        }
    case StateHalfOpen:
        // allow limited probes
    }
    cb.mu.Unlock()

    err := fn()

    cb.mu.Lock()
    defer cb.mu.Unlock()
    if err != nil {
        cb.failures++
        cb.lastFailureTime = time.Now()
        if cb.state == StateHalfOpen || cb.failures >= cb.maxFailures {
            cb.state = StateOpen
        }
        return err
    }

    if cb.state == StateHalfOpen {
        cb.successes++
        if cb.successes >= cb.halfOpenMax {
            cb.state = StateClosed
            cb.failures = 0
        }
    } else {
        cb.failures = 0
    }
    return nil
}

var ErrCircuitOpen = errors.New("circuit breaker is open")
```

### Usage with HTTP Client

```go
var cb = NewCircuitBreaker(5, 30*time.Second)

func CallAPI(ctx context.Context, url string) (*Response, error) {
    var resp *Response
    err := cb.Execute(func() error {
        req, _ := http.NewRequestWithContext(ctx, "GET", url, nil)
        r, err := http.DefaultClient.Do(req)
        if err != nil {
            return err
        }
        if r.StatusCode >= 500 {
            r.Body.Close()
            return fmt.Errorf("server error: %d", r.StatusCode)
        }
        resp = parseResponse(r)
        return nil
    })
    return resp, err
}
```

---

## Pub/Sub with Channels

### Broker Implementation

```go
type Broker[T any] struct {
    mu          sync.RWMutex
    subscribers map[string][]chan T
    bufSize     int
}

func NewBroker[T any](bufSize int) *Broker[T] {
    return &Broker[T]{
        subscribers: make(map[string][]chan T),
        bufSize:     bufSize,
    }
}

func (b *Broker[T]) Subscribe(topic string) <-chan T {
    ch := make(chan T, b.bufSize)
    b.mu.Lock()
    b.subscribers[topic] = append(b.subscribers[topic], ch)
    b.mu.Unlock()
    return ch
}

func (b *Broker[T]) Unsubscribe(topic string, ch <-chan T) {
    b.mu.Lock()
    defer b.mu.Unlock()
    subs := b.subscribers[topic]
    for i, s := range subs {
        if s == ch {
            b.subscribers[topic] = append(subs[:i], subs[i+1:]...)
            close(s)
            return
        }
    }
}

func (b *Broker[T]) Publish(topic string, msg T) {
    b.mu.RLock()
    subs := b.subscribers[topic]
    b.mu.RUnlock()
    for _, ch := range subs {
        select {
        case ch <- msg:
        default:
            // subscriber too slow — drop message or log
        }
    }
}

func (b *Broker[T]) Close() {
    b.mu.Lock()
    defer b.mu.Unlock()
    for topic, subs := range b.subscribers {
        for _, ch := range subs {
            close(ch)
        }
        delete(b.subscribers, topic)
    }
}
```

### Topic-Filtered Subscription

```go
func (b *Broker[T]) SubscribeFunc(topic string, filter func(T) bool) <-chan T {
    raw := b.Subscribe(topic)
    filtered := make(chan T, b.bufSize)
    go func() {
        defer close(filtered)
        for msg := range raw {
            if filter(msg) {
                filtered <- msg
            }
        }
    }()
    return filtered
}
```

---

## Graceful Degradation Patterns

### Timeout with Fallback

```go
func FetchWithFallback(ctx context.Context, primary, fallback func(context.Context) (Data, error)) (Data, error) {
    ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
    defer cancel()

    type result struct {
        data Data
        err  error
    }
    ch := make(chan result, 1)
    go func() {
        d, err := primary(ctx)
        ch <- result{d, err}
    }()

    select {
    case r := <-ch:
        if r.err == nil {
            return r.data, nil
        }
        log.Printf("primary failed: %v, trying fallback", r.err)
    case <-ctx.Done():
        log.Printf("primary timed out, trying fallback")
    }

    // Fallback with separate, longer timeout
    fbCtx, fbCancel := context.WithTimeout(context.Background(), 5*time.Second)
    defer fbCancel()
    return fallback(fbCtx)
}
```

### Hedged Requests

Send the same request to multiple backends; use the first response:

```go
func HedgedRequest(ctx context.Context, fn func(context.Context) (Data, error), delay time.Duration, attempts int) (Data, error) {
    ctx, cancel := context.WithCancel(ctx)
    defer cancel()

    type result struct {
        data Data
        err  error
    }
    ch := make(chan result, attempts)

    for i := range attempts {
        go func() {
            if i > 0 {
                select {
                case <-time.After(delay * time.Duration(i)):
                case <-ctx.Done():
                    return
                }
            }
            d, err := fn(ctx)
            ch <- result{d, err}
        }()
    }

    var lastErr error
    for range attempts {
        select {
        case r := <-ch:
            if r.err == nil {
                return r.data, nil
            }
            lastErr = r.err
        case <-ctx.Done():
            return Data{}, ctx.Err()
        }
    }
    return Data{}, lastErr
}
```

### Bulkhead Pattern (Isolate Failure Domains)

```go
type Bulkhead struct {
    sem chan struct{}
}

func NewBulkhead(maxConcurrent int) *Bulkhead {
    return &Bulkhead{sem: make(chan struct{}, maxConcurrent)}
}

func (b *Bulkhead) Execute(ctx context.Context, fn func() error) error {
    select {
    case b.sem <- struct{}{}:
        defer func() { <-b.sem }()
        return fn()
    case <-ctx.Done():
        return fmt.Errorf("bulkhead: %w", ctx.Err())
    }
}

// Usage: isolate database calls from API calls
var (
    dbBulkhead  = NewBulkhead(20)  // max 20 concurrent DB calls
    apiBulkhead = NewBulkhead(50)  // max 50 concurrent API calls
)
```

### Load Shedding

```go
func LoadSheddingMiddleware(maxInflight int) func(http.Handler) http.Handler {
    inflight := atomic.Int64{}
    return func(next http.Handler) http.Handler {
        return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
            current := inflight.Add(1)
            defer inflight.Add(-1)
            if current > int64(maxInflight) {
                http.Error(w, "service overloaded", http.StatusServiceUnavailable)
                return
            }
            next.ServeHTTP(w, r)
        })
    }
}
```
