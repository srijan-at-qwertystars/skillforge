# Advanced RxJS Patterns

> Dense reference for advanced RxJS usage. RxJS 7.x+ assumed throughout.

## Table of Contents

- [Custom Operators](#custom-operators)
  - [Pipeable Operators](#pipeable-operators)
  - [MonoTypeOperatorFunction vs OperatorFunction](#monotype-vs-type-changing)
  - [Legacy Operators (patch style)](#legacy-operators)
  - [Stateful Custom Operators](#stateful-custom-operators)
- [Higher-Order Observable Strategies In Depth](#higher-order-observable-strategies-in-depth)
  - [switchMap Internals](#switchmap-internals)
  - [mergeMap Concurrency Control](#mergemap-concurrency-control)
  - [concatMap Ordering Guarantees](#concatmap-ordering-guarantees)
  - [exhaustMap for Debounce-at-Source](#exhaustmap-for-debounce-at-source)
  - [Choosing the Right Strategy](#choosing-the-right-strategy)
- [Backpressure Handling](#backpressure-handling)
  - [Lossy Strategies](#lossy-strategies)
  - [Lossless Strategies](#lossless-strategies)
  - [Custom Backpressure](#custom-backpressure)
- [Schedulers Deep Dive](#schedulers-deep-dive)
  - [queueScheduler](#queuescheduler)
  - [asyncScheduler](#asyncscheduler)
  - [asapScheduler](#asapscheduler)
  - [animationFrameScheduler](#animationframescheduler)
  - [TestScheduler](#testscheduler)
  - [Scheduler Injection Patterns](#scheduler-injection-patterns)
- [Window and Buffer Operators](#window-and-buffer-operators)
  - [buffer / bufferTime / bufferCount / bufferWhen / bufferToggle](#buffer-variants)
  - [window / windowTime / windowCount / windowWhen / windowToggle](#window-variants)
  - [Batching Patterns](#batching-patterns)
- [expand for Recursive Operations](#expand-for-recursive-operations)
  - [Paginated API Fetching](#paginated-api-fetching)
  - [Tree Traversal](#tree-traversal)
  - [Recursive Retry with State](#recursive-retry-with-state)
- [Multicast Strategies Comparison](#multicast-strategies-comparison)
  - [share()](#share)
  - [shareReplay()](#sharereplay)
  - [connectable()](#connectable)
  - [connect() operator](#connect-operator)
  - [Subject Manual Multicast](#subject-manual-multicast)
  - [Decision Matrix](#decision-matrix)

---

## Custom Operators

### Pipeable Operators

A pipeable operator is a function that takes an Observable and returns an Observable.

```typescript
import { Observable, OperatorFunction, MonoTypeOperatorFunction } from 'rxjs';
import { map, filter } from 'rxjs';

// Type-changing operator: input type differs from output type
function mapToLength(): OperatorFunction<string, number> {
  return (source: Observable<string>) =>
    source.pipe(map(val => val.length));
}

// Usage
of('hello', 'world').pipe(mapToLength()).subscribe(console.log); // 5, 5
```

### MonoType vs Type-Changing

```typescript
// MonoTypeOperatorFunction<T> — input and output share same type
function filterPositive(): MonoTypeOperatorFunction<number> {
  return (source: Observable<number>) =>
    source.pipe(filter(n => n > 0));
}

// OperatorFunction<T, R> — input type T, output type R
function toJson<T>(): OperatorFunction<string, T> {
  return (source: Observable<string>) =>
    source.pipe(map(s => JSON.parse(s) as T));
}
```

### Legacy Operators

Legacy (patch-style) operators mutated `Observable.prototype`. **Do not use** in new code.

```typescript
// LEGACY — do not use
Observable.prototype.myOperator = function() { /* ... */ };

// MODERN — always use pipeable
function myOperator(): MonoTypeOperatorFunction<number> {
  return source$ => new Observable(subscriber => {
    const sub = source$.subscribe({
      next(val) { subscriber.next(val * 2); },
      error(err) { subscriber.error(err); },
      complete() { subscriber.complete(); }
    });
    return () => sub.unsubscribe();
  });
}
```

### Stateful Custom Operators

Operators that maintain internal state across emissions:

```typescript
import { Observable, OperatorFunction } from 'rxjs';

// Emit only values that differ by more than `threshold` from the last emitted
function distinctByDelta(threshold: number): MonoTypeOperatorFunction<number> {
  return (source: Observable<number>) =>
    new Observable(subscriber => {
      let lastEmitted: number | undefined;
      return source.subscribe({
        next(val) {
          if (lastEmitted === undefined || Math.abs(val - lastEmitted) >= threshold) {
            lastEmitted = val;
            subscriber.next(val);
          }
        },
        error(err) { subscriber.error(err); },
        complete() { subscriber.complete(); }
      });
    });
}

// Rate-limiting operator: emit at most one value per `ms` milliseconds
function rateLimit<T>(ms: number): MonoTypeOperatorFunction<T> {
  return (source: Observable<T>) =>
    new Observable(subscriber => {
      let lastEmitTime = 0;
      return source.subscribe({
        next(val) {
          const now = Date.now();
          if (now - lastEmitTime >= ms) {
            lastEmitTime = now;
            subscriber.next(val);
          }
        },
        error(err) { subscriber.error(err); },
        complete() { subscriber.complete(); }
      });
    });
}
```

**Key rules for custom operators:**
1. Always return the teardown function (unsubscribe from source).
2. Forward both `error` and `complete` to the subscriber.
3. Use `new Observable()` constructor for stateful operators.
4. Compose existing operators via `.pipe()` for stateless transforms.

---

## Higher-Order Observable Strategies In Depth

### switchMap Internals

`switchMap` subscribes to each new inner observable and **unsubscribes from the previous**.

```
Source:  --a--------b--------c--|
Inner a: ---1--2--3              (cancelled at b)
Inner b:           ---4--5       (cancelled at c)
Inner c:                    ---6--7--|
Output: -----1--2-----4--5-----6--7--|
```

**Cancellation semantics:** When the source emits, `switchMap`:
1. Unsubscribes from the current inner observable (triggers its teardown).
2. Calls the projection function with the new value.
3. Subscribes to the returned inner observable.

**When to use:** Autocomplete/typeahead, route navigation, any "latest wins" scenario.

**Gotcha:** If the inner observable performs a side effect (POST request), cancellation does NOT abort the server-side operation — only the client-side subscription.

### mergeMap Concurrency Control

```typescript
// Unlimited concurrency (default)
source$.pipe(mergeMap(val => doWork(val)));

// Limited concurrency — at most 3 concurrent inner subscriptions
source$.pipe(mergeMap(val => doWork(val), 3));
```

Concurrency parameter is the second argument. Queued items subscribe when a slot opens.

```
Source:       --a--b--c--d--e--|    (concurrency: 2)
Inner a:       --1--|
Inner b:          --2--|
Inner c (queued):    --3--|        (starts after a completes)
Inner d (queued):       --4--|     (starts after b completes)
Inner e (queued):          --5--|
Output:       ----1--2--3--4--5--|
```

### concatMap Ordering Guarantees

`concatMap` = `mergeMap` with concurrency of 1.

**Critical for:** sequential writes, ordered processing, transaction-like sequences.

```typescript
// Each save must complete before the next starts
saveQueue$.pipe(
  concatMap(item => this.api.save(item))  // strict order preserved
).subscribe();
```

**Warning:** If inner observables never complete, the queue blocks forever.

### exhaustMap for Debounce-at-Source

`exhaustMap` ignores new source emissions while an inner observable is active.

```
Source:  --a--b--c--------d--e--|
Inner a: ---1--2--|
                          Inner d: ---3--|
Output: -----1--2-----------3--|
                  ^ b and c ignored, e ignored
```

**Use for:** Form submissions, login buttons, any action where re-triggering during processing is unwanted.

### Choosing the Right Strategy

| Scenario | Operator | Why |
|----------|----------|-----|
| Typeahead search | `switchMap` | Only latest search matters |
| File upload queue | `concatMap` | Order and completion matter |
| Analytics events | `mergeMap` | Fire-and-forget, parallel OK |
| Form submit button | `exhaustMap` | Prevent double-submit |
| Parallel with limit | `mergeMap(fn, N)` | Controlled parallelism |
| Paginated loading | `concatMap` or `expand` | Sequential pages |

---

## Backpressure Handling

When a producer emits faster than a consumer can process.

### Lossy Strategies

Drop values the consumer can't handle:

```typescript
import { throttleTime, auditTime, sampleTime, debounceTime } from 'rxjs';

// throttleTime: emit first value, then ignore for duration
fastSource$.pipe(throttleTime(100)); // first value per 100ms window

// auditTime: wait for duration, then emit last value
fastSource$.pipe(auditTime(100)); // last value per 100ms window

// sampleTime: emit latest value at regular intervals
fastSource$.pipe(sampleTime(200)); // snapshot every 200ms

// debounceTime: wait for silence, then emit
fastSource$.pipe(debounceTime(300)); // emit after 300ms of no activity

// Custom: take latest N per time window
fastSource$.pipe(
  bufferTime(100),
  filter(buf => buf.length > 0),
  map(buf => buf[buf.length - 1]) // keep only latest from each batch
);
```

### Lossless Strategies

Preserve all values by buffering:

```typescript
import { bufferTime, bufferCount, concatMap, delay } from 'rxjs';

// Buffer by time: collect into arrays
fastSource$.pipe(
  bufferTime(500),
  filter(buf => buf.length > 0),
  concatMap(batch => processBatch(batch)) // sequential batch processing
);

// Buffer by count
fastSource$.pipe(
  bufferCount(50),
  concatMap(batch => processBatch(batch))
);

// concatMap itself provides backpressure — queues until inner completes
fastSource$.pipe(
  concatMap(item => processItem(item)) // natural backpressure
);
```

### Custom Backpressure

```typescript
// Pull-based: consumer requests next item only when ready
function pullBased<T>(process: (val: T) => Observable<unknown>): MonoTypeOperatorFunction<T> {
  return (source: Observable<T>) =>
    source.pipe(
      concatMap(val =>
        process(val).pipe(
          last(),
          map(() => val)
        )
      )
    );
}
```

---

## Schedulers Deep Dive

Schedulers control **when** subscriptions start and **when** notifications are delivered.

### queueScheduler

Executes synchronously in a trampoline queue. Prevents stack overflow for recursive operations.

```typescript
import { queueScheduler, scheduled, of } from 'rxjs';
import { concatAll } from 'rxjs';

// Without queueScheduler: potential stack overflow for deep recursion
// With queueScheduler: each step queued, stack stays flat
scheduled([of(1), of(2), of(3)], queueScheduler).pipe(
  concatAll()
).subscribe(console.log);
```

**Use:** Recursive/iterative synchronous operations. Rarely needed directly.

### asyncScheduler

Schedules via `setInterval` / `setTimeout`. Default for `interval()`, `timer()`, `delay()`.

```typescript
import { asyncScheduler, of } from 'rxjs';
import { observeOn, subscribeOn } from 'rxjs';

// Force async emission
of(1, 2, 3).pipe(
  observeOn(asyncScheduler)  // each next() called via setTimeout
).subscribe(console.log);    // prints after current synchronous code finishes

// subscribeOn: schedule the subscription itself
of(1, 2, 3).pipe(
  subscribeOn(asyncScheduler) // subscribe happens in next microtask
);
```

### asapScheduler

Schedules via microtask (`Promise.resolve().then(...)`). Faster than `asyncScheduler`, but still async.

```typescript
import { asapScheduler, of } from 'rxjs';
import { observeOn } from 'rxjs';

of(1, 2, 3).pipe(
  observeOn(asapScheduler) // microtask queue — before next macrotask
).subscribe(console.log);
```

### animationFrameScheduler

Schedules via `requestAnimationFrame`. Aligns with browser repaint cycle (~16ms / 60fps).

```typescript
import { animationFrameScheduler, interval } from 'rxjs';
import { map, takeWhile } from 'rxjs';

// Smooth animation: emit on each frame
const smoothScroll$ = interval(0, animationFrameScheduler).pipe(
  map(frame => frame * 2),        // pixels per frame
  takeWhile(pos => pos < 1000)    // stop at 1000px
);

// Animation with elapsed time
const start = animationFrameScheduler.now();
interval(0, animationFrameScheduler).pipe(
  map(() => animationFrameScheduler.now() - start),
  map(elapsed => easeInOut(elapsed / duration)),
  takeWhile(progress => progress < 1, true)
);
```

### TestScheduler

Virtual time — no real delays. See [troubleshooting.md](./troubleshooting.md) for gotchas.

```typescript
import { TestScheduler } from 'rxjs/testing';

const scheduler = new TestScheduler((actual, expected) => {
  expect(actual).toEqual(expected);
});

scheduler.run(({ cold, expectObservable }) => {
  const source = cold('  --a--b--c--|');
  const expected = '     --A--B--C--|';
  expectObservable(source.pipe(map(v => v.toUpperCase()))).toBe(expected);
});
```

### Scheduler Injection Patterns

Inject schedulers for testability:

```typescript
function pollData(
  url: string,
  intervalMs: number,
  scheduler: SchedulerLike = asyncScheduler
): Observable<Data> {
  return timer(0, intervalMs, scheduler).pipe(
    switchMap(() => fetchData(url))
  );
}

// In production
pollData('/api/status', 5000);

// In tests
const testScheduler = new TestScheduler(/* ... */);
testScheduler.run(({ expectObservable }) => {
  expectObservable(pollData('/api/status', 5000, testScheduler));
});
```

---

## Window and Buffer Operators

Both group emissions. **Buffer** collects into arrays. **Window** emits inner Observables.

### Buffer Variants

```typescript
import {
  buffer, bufferTime, bufferCount, bufferWhen, bufferToggle
} from 'rxjs';

// buffer: collect until notifier emits
source$.pipe(buffer(flushSignal$));

// bufferTime(ms): collect for `ms` milliseconds
source$.pipe(bufferTime(1000)); // emit array every 1s

// bufferTime(ms, null, maxSize): flush early if maxSize reached
source$.pipe(bufferTime(1000, null, 100)); // flush at 1s OR 100 items

// bufferCount(count): collect N items
source$.pipe(bufferCount(10)); // emit array of 10

// bufferCount(count, skip): sliding window
source$.pipe(bufferCount(3, 1)); // [1,2,3], [2,3,4], [3,4,5]...

// bufferWhen: dynamic buffer boundaries
source$.pipe(bufferWhen(() => timer(randomMs())));

// bufferToggle: open/close windows explicitly
source$.pipe(bufferToggle(openings$, opening => closing$));
```

### Window Variants

Window operators are like buffer but emit Observables instead of arrays:

```typescript
import { window, windowTime, windowCount } from 'rxjs';
import { mergeAll, toArray } from 'rxjs';

// window: split into sub-observables at notifier emissions
source$.pipe(
  windowTime(1000),
  mergeMap(win$ => win$.pipe(toArray())) // same as bufferTime(1000)
);

// Key advantage: can apply operators to each window independently
source$.pipe(
  windowTime(5000),
  mergeMap(win$ => win$.pipe(
    take(3),          // at most 3 items per 5s window
    map(v => v * 2)
  ))
);
```

### Batching Patterns

```typescript
// Batch API calls: collect IDs, fetch in bulk
itemId$.pipe(
  bufferTime(100, null, 50),   // batch by 100ms or 50 items
  filter(ids => ids.length > 0),
  mergeMap(ids => this.api.getBatch(ids), 3) // max 3 concurrent batch requests
);

// Event batching for analytics
userAction$.pipe(
  bufferTime(5000),
  filter(events => events.length > 0),
  concatMap(batch => this.analytics.sendBatch(batch))
);

// Rate-limited processing
tasks$.pipe(
  bufferTime(1000),
  filter(t => t.length > 0),
  concatMap(batch =>
    from(batch).pipe(
      concatMap(task => processTask(task)),
      delay(100) // 100ms between each task in batch
    )
  )
);
```

---

## expand for Recursive Operations

`expand` recursively projects each value, subscribing to the returned observable. Emits all intermediate values.

### Paginated API Fetching

```typescript
import { expand, EMPTY, reduce } from 'rxjs';

interface PagedResponse<T> {
  data: T[];
  nextCursor?: string;
}

function fetchAllPages<T>(firstUrl: string): Observable<T[]> {
  return this.http.get<PagedResponse<T>>(firstUrl).pipe(
    expand(response =>
      response.nextCursor
        ? this.http.get<PagedResponse<T>>(`${firstUrl}?cursor=${response.nextCursor}`)
        : EMPTY  // EMPTY stops recursion
    ),
    map(response => response.data),
    reduce((all, page) => [...all, ...page], [] as T[])
  );
}
```

### Tree Traversal

```typescript
interface TreeNode {
  id: string;
  children?: string[];
}

function traverseTree(rootId: string): Observable<TreeNode> {
  return this.getNode(rootId).pipe(
    expand(node =>
      node.children?.length
        ? from(node.children).pipe(mergeMap(id => this.getNode(id)))
        : EMPTY
    )
  );
}
```

### Recursive Retry with State

```typescript
// Retry with increasing delay and state tracking
function retryWithBackoff<T>(
  factory: (attempt: number) => Observable<T>,
  maxRetries: number
): Observable<T> {
  return of(0).pipe(
    expand(attempt =>
      attempt >= maxRetries
        ? EMPTY
        : factory(attempt).pipe(
            map(() => maxRetries + 1), // success: emit value > max to stop
            catchError(() =>
              timer(Math.pow(2, attempt) * 1000).pipe(map(() => attempt + 1))
            )
          )
    ),
    filter(attempt => attempt > maxRetries),
    take(1),
    switchMap(attempt => factory(attempt - 1))
  );
}
```

---

## Multicast Strategies Comparison

### share()

Refcounted multicast using a Subject. Resets on complete/error/refCount drop to 0.

```typescript
const shared$ = source$.pipe(share());

// Configuration (RxJS 7+)
const shared$ = source$.pipe(share({
  connector: () => new ReplaySubject(1),  // custom subject
  resetOnError: true,                      // re-create subject on error
  resetOnComplete: true,                   // re-create on complete
  resetOnRefCountZero: true                // re-create when all unsubscribe
}));
```

### shareReplay()

Like `share()` but replays `bufferSize` emissions to late subscribers.

```typescript
// CORRECT: always use refCount: true
const cached$ = source$.pipe(
  shareReplay({ bufferSize: 1, refCount: true })
);

// DANGEROUS: refCount defaults to false — subscription never released
const leaky$ = source$.pipe(shareReplay(1)); // DON'T DO THIS
```

**refCount behavior:**
- `refCount: true` — when subscriber count drops to 0, unsubscribe from source.
- `refCount: false` (default) — source subscription persists forever after first subscribe.

### connectable()

Creates a ConnectableObservable. Subscription to source only starts on `connect()`.

```typescript
import { connectable, interval, Subject } from 'rxjs';

const source$ = interval(1000);
const multicasted$ = connectable(source$, { connector: () => new Subject() });

// Set up subscribers first
multicasted$.subscribe(a => console.log('A:', a));
multicasted$.subscribe(b => console.log('B:', b));

// Then start the source
const connection = multicasted$.connect();

// Later: stop
connection.unsubscribe();
```

### connect() operator

Inline multicast within a pipe. Replaces deprecated `publish()`.

```typescript
import { connect, merge, filter, map } from 'rxjs';

source$.pipe(
  connect(shared$ => merge(
    shared$.pipe(filter(x => x % 2 === 0), map(x => `even: ${x}`)),
    shared$.pipe(filter(x => x % 2 !== 0), map(x => `odd: ${x}`))
  ))
);
```

### Subject Manual Multicast

Full control, but you manage subscriptions manually.

```typescript
const subject = new ReplaySubject<Data>(1);

// Single subscription to source
source$.subscribe(subject);

// Multiple consumers
subject.subscribe(consumerA);
subject.subscribe(consumerB);
```

### Decision Matrix

| Need | Strategy | Config |
|------|----------|--------|
| Share HTTP result, no late subscribers | `share()` | default |
| Cache latest value for late subscribers | `shareReplay()` | `{ bufferSize: 1, refCount: true }` |
| Cache and persist even with 0 subscribers | `shareReplay()` | `{ bufferSize: 1, refCount: false }` |
| Share but split into multiple pipes | `connect()` | — |
| Manual connect/disconnect control | `connectable()` | — |
| Full control, external triggering | `Subject` / `BehaviorSubject` | manual |
| Replay last N to new subscribers | `shareReplay()` or `ReplaySubject` | `bufferSize: N` |
