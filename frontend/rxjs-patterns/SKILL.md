---
name: rxjs-patterns
description: >
  RxJS reactive programming patterns for TypeScript/JavaScript. Use when writing,
  reviewing, or debugging Observable streams, pipeable operators, Subjects, marble
  tests, or Angular reactive integrations (HttpClient, reactive forms, router).
  Covers creation, transformation, filtering, combination, error handling,
  multicasting, higher-order mapping, memory leak prevention, and TestScheduler.
  Do NOT use for plain Promises, async/await without Observables, non-reactive
  event handling, Redux/NgRx store logic, or general TypeScript questions
  unrelated to reactive streams.
---

# RxJS Reactive Programming Patterns

## Core Concepts

**Observable** — lazy push collection; emits 0..N values, then completes or errors.
Cold observables create a new producer per subscriber. Hot observables share a producer.

**Observer** — object with `next`, `error`, `complete` callbacks.

**Subscription** — represents execution of an Observable. Call `unsubscribe()` to release resources.

**Operators** — pure functions composed via `.pipe()`. Never mutate source observables.

**Subject** — both Observable and Observer. Multicasts to multiple subscribers.

**Scheduler** — controls when emissions happen (`asyncScheduler`, `queueScheduler`, `animationFrameScheduler`).

## Imports (RxJS 7.2+)

Import everything from `rxjs` directly. The `rxjs/operators` path is deprecated.

```typescript
// CORRECT — RxJS 7.2+
import { map, filter, switchMap, combineLatest, of, from } from 'rxjs';

// DEPRECATED — do not use
import { map } from 'rxjs/operators';
```

## Creation Operators

```typescript
import { of, from, interval, timer, fromEvent, defer, EMPTY, throwError } from 'rxjs';
import { ajax } from 'rxjs/ajax';

of(1, 2, 3);                        // emit 1, 2, 3 then complete
from([10, 20]);                      // emit 10, 20 from iterable
from(fetch('/api'));                  // emit resolved Promise value
interval(1000);                      // emit 0, 1, 2… every 1s
timer(2000, 1000);                   // wait 2s, then emit every 1s
fromEvent(button, 'click');          // emit click events
ajax.getJSON('/api/users');          // HTTP GET → emit JSON body
defer(() => from(fetch('/api')));    // create fresh Observable per subscriber
EMPTY;                               // complete immediately, emit nothing
throwError(() => new Error('fail')); // emit error immediately
```

## Transformation Operators

```typescript
import { map, switchMap, mergeMap, concatMap, exhaustMap, scan, reduce, tap } from 'rxjs';

// map: transform each value
source$.pipe(map(x => x * 2));
// Input:  --1--2--3--|
// Output: --2--4--6--|

// switchMap: cancel previous inner, subscribe to new
search$.pipe(switchMap(term => http.get(`/search?q=${term}`)));
// Use for: typeahead, route changes, latest-wins scenarios

// mergeMap: run all inner observables concurrently
clicks$.pipe(mergeMap(() => http.post('/track')));
// Use for: fire-and-forget, parallel requests

// concatMap: queue inner observables, run sequentially
queue$.pipe(concatMap(item => processItem(item)));
// Use for: ordered writes, sequential processing

// exhaustMap: ignore new emissions while inner is active
submit$.pipe(exhaustMap(() => http.post('/submit')));
// Use for: prevent duplicate form submissions

// scan: accumulate state over time (like reduce but emits each step)
clicks$.pipe(scan((count) => count + 1, 0));
// Input:  --x--x--x--|
// Output: --1--2--3--|

// reduce: accumulate, emit final value on complete
source$.pipe(reduce((acc, val) => acc + val, 0));

// tap: side effects without modifying the stream
source$.pipe(tap(val => console.log('debug:', val)));
```

### Higher-Order Observable Strategies

| Strategy    | Operator      | Concurrency | Order     | Cancels Previous |
|------------|---------------|-------------|-----------|-----------------|
| Switch     | `switchMap`   | 1           | Latest    | Yes             |
| Merge      | `mergeMap`    | Unlimited   | Arrival   | No              |
| Concat     | `concatMap`   | 1           | Preserved | No              |
| Exhaust    | `exhaustMap`  | 1           | First     | No (ignores)    |

## Filtering Operators

```typescript
import {
  filter, take, takeUntil, takeWhile, skip, first, last,
  debounceTime, throttleTime, distinctUntilChanged, auditTime, sampleTime
} from 'rxjs';

source$.pipe(filter(x => x > 5));
source$.pipe(take(3));                          // first 3 values then complete
source$.pipe(takeUntil(destroy$));              // complete when destroy$ emits
source$.pipe(skip(2));                          // skip first 2 values
source$.pipe(first(x => x > 10));              // first match, then complete
source$.pipe(debounceTime(300));                // wait 300ms of silence
source$.pipe(throttleTime(1000));               // at most one value per 1s
source$.pipe(distinctUntilChanged());           // skip consecutive duplicates
source$.pipe(distinctUntilChanged((a, b) => a.id === b.id)); // custom comparator
source$.pipe(auditTime(500));                   // emit latest after each 500ms window
```

## Combination Operators

```typescript
import {
  combineLatest, merge, concat, forkJoin, zip, withLatestFrom, race
} from 'rxjs';

// combineLatest: emit latest from each when any emits (all must emit once first)
combineLatest([obs1$, obs2$]).pipe(map(([a, b]) => a + b));

// merge: interleave emissions from multiple sources
merge(clicks$, keypresses$, touches$);

// concat: subscribe sequentially, next starts after previous completes
concat(init$, data$, cleanup$);

// forkJoin: emit last value from each when ALL complete (parallel Promise.all analog)
forkJoin({ user: getUser$, prefs: getPrefs$ });
// Output: { user: {...}, prefs: {...} }

// zip: pair emissions by index
zip(letters$, numbers$);
// Input:  letters: --a--b--c--|  numbers: --1--2--3--|
// Output: --[a,1]--[b,2]--[c,3]--|

// withLatestFrom: combine with latest from another (only when source emits)
clicks$.pipe(withLatestFrom(currentUser$));

// race: use first observable to emit
race(primaryApi$, fallbackApi$);

// RxJS 7 *With operators (use inside pipe)
import { mergeWith, concatWith, zipWith, combineLatestWith, raceWith } from 'rxjs';
source$.pipe(mergeWith(other$));
```

## Error Handling

```typescript
import { catchError, retry, retryWhen, throwError, EMPTY, timer } from 'rxjs';
import { mergeMap, delayWhen } from 'rxjs';

// catchError: intercept errors, return fallback observable
source$.pipe(
  catchError(err => {
    console.error(err);
    return of(fallbackValue);   // recover with default
  })
);

// catchError: rethrow transformed error
source$.pipe(catchError(err => throwError(() => new AppError(err))));

// retry: resubscribe N times on error
http.get('/api').pipe(retry(3));

// retry with configuration (RxJS 7+)
http.get('/api').pipe(retry({ count: 3, delay: 1000 }));

// Exponential backoff retry
http.get('/api').pipe(
  retry({
    count: 4,
    delay: (error, retryCount) => timer(Math.pow(2, retryCount) * 1000)
  })
);

// catchError + EMPTY: swallow error, complete silently
source$.pipe(catchError(() => EMPTY));
```

## Multicasting & Subjects

```typescript
import {
  share, shareReplay, Subject, BehaviorSubject, ReplaySubject, AsyncSubject,
  connectable, connect
} from 'rxjs';

// share: multicast with refcount; resubscribes when new subscriber after completion
const shared$ = source$.pipe(share());

// shareReplay: cache last N emissions for late subscribers
const cached$ = source$.pipe(shareReplay({ bufferSize: 1, refCount: true }));
// ALWAYS set refCount: true to avoid memory leaks

// BehaviorSubject: requires initial value, emits current value to new subscribers
const state$ = new BehaviorSubject<number>(0);
state$.next(1);
state$.getValue(); // 1 (synchronous read)

// ReplaySubject: replays N past values to new subscribers
const replay$ = new ReplaySubject<string>(3); // buffer last 3

// AsyncSubject: emits only the last value, only on complete
const async$ = new AsyncSubject<number>();

// connect (RxJS 7+): replaces deprecated publish/refCount
source$.pipe(connect(shared => merge(
  shared.pipe(filter(x => x > 5)),
  shared.pipe(filter(x => x <= 5))
)));
```

### Hot vs Cold

| Type | Producer Created     | Example                  | Multicast? |
|------|---------------------|--------------------------|------------|
| Cold | Per subscriber      | `of()`, `from()`, `ajax` | No         |
| Hot  | Before subscription | `fromEvent`, Subject     | Yes        |

Use `share()` or `shareReplay()` to make cold observables hot.

## Memory Leak Prevention

### Pattern 1: takeUntil with destroy signal (Components)

```typescript
class MyComponent implements OnDestroy {
  private destroy$ = new Subject<void>();

  ngOnInit() {
    this.data$.pipe(takeUntil(this.destroy$)).subscribe(d => this.render(d));
  }

  ngOnDestroy() {
    this.destroy$.next();
    this.destroy$.complete();
  }
}
```

### Pattern 2: Angular async pipe (preferred in templates)

```html
<!-- Auto-subscribes and auto-unsubscribes -->
<div *ngIf="user$ | async as user">{{ user.name }}</div>
<li *ngFor="let item of items$ | async">{{ item }}</li>
```

### Pattern 3: DestroyRef (Angular 16+)

```typescript
import { DestroyRef, inject } from '@angular/core';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';

class MyComponent {
  private destroyRef = inject(DestroyRef);
  data$ = this.http.get('/api').pipe(takeUntilDestroyed(this.destroyRef));
}
```

### Rules
- Never subscribe in a constructor; use `ngOnInit` or equivalent lifecycle hook.
- Finite observables (HTTP calls) auto-complete but still benefit from cancellation.
- Infinite observables (interval, fromEvent, Subject) MUST be unsubscribed.
- Avoid `.subscribe()` in Angular templates; use `async` pipe instead.

## Common Patterns

### Typeahead Search

```typescript
searchInput$.pipe(
  debounceTime(300),
  distinctUntilChanged(),
  filter(term => term.length >= 2),
  switchMap(term => this.searchService.search(term).pipe(
    catchError(() => of([]))
  ))
);
```

### Polling with Pause/Resume

```typescript
const isActive$ = new BehaviorSubject(true);
isActive$.pipe(
  switchMap(active => active ? timer(0, 5000) : EMPTY),
  switchMap(() => http.get('/api/status')),
  retry({ count: 3, delay: 1000 })
);
```

### Request Cancellation — previous request auto-cancelled by switchMap

```typescript
route.params.pipe(switchMap(params => http.get(`/api/items/${params.id}`)));
```

### Optimistic Update with Rollback

```typescript
updateItem$.pipe(
  tap(item => this.store.optimisticUpdate(item)),
  concatMap(item => this.api.save(item).pipe(
    catchError(err => {
      this.store.rollback(item);
      return throwError(() => err);
    })
  ))
);
```

## Angular Integration

### HttpClient (returns cold Observable, auto-completes)

```typescript
@Injectable({ providedIn: 'root' })
export class UserService {
  constructor(private http: HttpClient) {}
  getUsers(): Observable<User[]> {
    return this.http.get<User[]>('/api/users').pipe(retry(2), catchError(this.handleError));
  }
}
```

### Reactive Forms

```typescript
this.form.get('email')!.valueChanges.pipe(
  debounceTime(400),
  distinctUntilChanged(),
  switchMap(email => this.validateEmail(email)),
  takeUntil(this.destroy$)
).subscribe(result => this.emailError = result);
```

### Route Params

```typescript
this.route.paramMap.pipe(
  map(params => params.get('id')!),
  distinctUntilChanged(),
  switchMap(id => this.service.getItem(id)),
  takeUntil(this.destroy$)
).subscribe(item => this.item = item);
```

## Testing with TestScheduler

### Setup

```typescript
import { TestScheduler } from 'rxjs/testing';

const scheduler = new TestScheduler((actual, expected) => {
  expect(actual).toEqual(expected);
});
```

### Marble Syntax

| Symbol | Meaning                                 |
|--------|-----------------------------------------|
| `-`    | 1 frame of time (1ms in run mode)       |
| `a-z`  | Emitted value                           |
| `\|`   | Complete                                |
| `#`    | Error                                   |
| `()`   | Synchronous group                       |
| `^`    | Subscription point (hot observables)    |
| `!`    | Unsubscription point                    |
| `10ms` | Explicit time passage                   |

### Example: Testing an Operator Pipeline

```typescript
scheduler.run(({ cold, hot, expectObservable }) => {
  const source =  cold('--a--b--c--|');
  const expected =      '--A--B--C--|';
  const result = source.pipe(map(v => v.toUpperCase()));
  expectObservable(result).toBe(expected, { A: 'A', B: 'B', C: 'C' });
});
```

### Example: Testing debounceTime

```typescript
scheduler.run(({ cold, expectObservable }) => {
  const source   = cold('-a--bc--d---|');
  expectObservable(source.pipe(debounceTime(20))).toBe('----b---d---|');
});
```

## RxJS 7+ Migration Guide

### Deprecated → Replacement

| Deprecated                          | Use Instead                              |
|------------------------------------|------------------------------------------|
| `toPromise()`                      | `firstValueFrom()` / `lastValueFrom()`   |
| `import from 'rxjs/operators'`     | `import from 'rxjs'`                     |
| `combineLatest` (operator)         | `combineLatestWith`                      |
| `merge` (operator)                 | `mergeWith`                              |
| `zip` (operator)                   | `zipWith`                                |
| `concat` (operator)               | `concatWith`                             |
| `race` (operator)                  | `raceWith`                               |
| `publish()`, `publishReplay()`     | `share()`, `shareReplay()`, `connect()`  |
| `multicast()`                      | `connectable()`, `connect()`             |
| `pluck('a', 'b')`                 | `map(x => x.a.b)`                        |

### Promise Interop (RxJS 7+)

```typescript
import { firstValueFrom, lastValueFrom } from 'rxjs';
const user = await firstValueFrom(user$);
const final = await lastValueFrom(counter$);
const val = await firstValueFrom(source$, { defaultValue: null });
```

## Performance Guidelines

- Prefer `switchMap` over `mergeMap` when only the latest result matters — cancels stale work.
- Use `shareReplay({ bufferSize: 1, refCount: true })` — `refCount: true` prevents stale subscriptions.
- Avoid nested subscribes — flatten with higher-order operators.
- Use `distinctUntilChanged()` before expensive operations.
- Prefer `async` pipe over manual subscription. Use `trackBy` with `*ngFor`.
- Limit `mergeMap` concurrency: `mergeMap(fn, 5)` caps parallel inner subs.

### Anti-Patterns

```typescript
// BAD: nested subscribe — memory leak, no cancellation
outer$.subscribe(a => { inner$.subscribe(b => { }); });
// GOOD: outer$.pipe(switchMap(a => inner$)).subscribe();

// BAD: shareReplay without refCount — subscription never released
source$.pipe(shareReplay(1));
// GOOD:
source$.pipe(shareReplay({ bufferSize: 1, refCount: true }));
```

## Additional Resources

### Reference Docs (`references/`)

Detailed deep-dive documents for advanced topics:

| Document | Description |
|----------|-------------|
| [advanced-patterns.md](references/advanced-patterns.md) | Custom operators (pipeable + legacy), higher-order strategies in depth, backpressure handling, schedulers (queue/async/animationFrame), window/buffer batching, `expand` recursion, multicast comparison |
| [troubleshooting.md](references/troubleshooting.md) | Memory leaks, cold vs hot confusion, operator ordering mistakes, race conditions, `shareReplay` refCount behavior, marble testing gotchas, Angular-specific pitfalls (ExpressionChanged, zone.js) |
| [angular-integration.md](references/angular-integration.md) | Reactive forms + valueChanges, route params, HttpClient interceptors, NgRx/ComponentStore, signal interop (toSignal/toObservable), async pipe best practices, OnPush + observables |

### Scripts (`scripts/`)

Executable helpers — run directly from the command line:

| Script | Description |
|--------|-------------|
| [init-rxjs-project.sh](scripts/init-rxjs-project.sh) | Scaffold a new RxJS playground with npm, TypeScript, ts-node, and a starter file |
| [operator-finder.sh](scripts/operator-finder.sh) | Interactive tool: describe what you need, get operator suggestions with examples |
| [marble-test-generator.sh](scripts/marble-test-generator.sh) | Generate marble test templates for any operator with TestScheduler setup |

### Assets (`assets/`)

Copy-paste-ready TypeScript templates:

| Template | Description |
|----------|-------------|
| [custom-operator.ts](assets/custom-operator.ts) | Custom operator patterns — MonoType, type-changing, stateful, with proper generics |
| [reactive-service.ts](assets/reactive-service.ts) | Angular service with BehaviorSubject state, loading/error states, CRUD operations |
| [unsubscribe-patterns.ts](assets/unsubscribe-patterns.ts) | All unsubscribe strategies compared: takeUntil, async pipe, Subscription, DestroyRef |
| [polling-with-backoff.ts](assets/polling-with-backoff.ts) | Production poller with exponential backoff, jitter, pause/resume, error recovery |
| [typeahead-search.ts](assets/typeahead-search.ts) | Complete typeahead with debounce, switchMap, loading states, keyboard navigation |
