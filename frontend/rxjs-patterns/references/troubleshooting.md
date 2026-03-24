# RxJS Troubleshooting Guide

> Common issues, pitfalls, and their solutions. Organized by symptom.

## Table of Contents

- [Memory Leaks](#memory-leaks)
  - [Unsubscribed Subscriptions](#unsubscribed-subscriptions)
  - [Hot Observable Leaks](#hot-observable-leaks)
  - [shareReplay Without refCount](#sharereplay-without-refcount)
  - [Event Listener Leaks](#event-listener-leaks)
  - [Detecting Memory Leaks](#detecting-memory-leaks)
- [Cold vs Hot Confusion](#cold-vs-hot-confusion)
  - [Symptom: Multiple HTTP Calls](#symptom-multiple-http-calls)
  - [Symptom: Late Subscriber Gets Nothing](#symptom-late-subscriber-gets-nothing)
  - [Symptom: Side Effects Run Multiple Times](#symptom-side-effects-run-multiple-times)
- [Operator Ordering Mistakes](#operator-ordering-mistakes)
  - [catchError Position](#catcherror-position)
  - [takeUntil Position](#takeuntil-position)
  - [share Position](#share-position)
  - [distinctUntilChanged Position](#distinctuntilchanged-position)
  - [debounceTime Before switchMap](#debouncetime-before-switchmap)
- [Race Conditions](#race-conditions)
  - [combineLatest Initial Emission](#combinelatest-initial-emission)
  - [switchMap Race with Side Effects](#switchmap-race-with-side-effects)
  - [forkJoin with Empty Observables](#forkjoin-with-empty-observables)
  - [Subscription Timing Issues](#subscription-timing-issues)
- [shareReplay refCount Behavior](#sharereplay-refcount-behavior)
- [Marble Testing Gotchas](#marble-testing-gotchas)
  - [Time Progression Rules](#time-progression-rules)
  - [Hot vs Cold in Tests](#hot-vs-cold-in-tests)
  - [Async Operations in Marble Tests](#async-operations-in-marble-tests)
  - [Common Marble Mistakes](#common-marble-mistakes)
- [Angular-Specific Pitfalls](#angular-specific-pitfalls)
  - [ExpressionChangedAfterItHasBeenCheckedError](#expressionchangedafterithasbeencheckederror)
  - [Zone.js Interactions](#zonejs-interactions)
  - [Router Guard Completion](#router-guard-completion)
  - [HttpClient Subscription Gotchas](#httpclient-subscription-gotchas)
  - [OnPush + Observable Gotchas](#onpush--observable-gotchas)
  - [Signals + RxJS Interop Issues](#signals--rxjs-interop-issues)

---

## Memory Leaks

### Unsubscribed Subscriptions

**Symptom:** Component destroyed but callbacks still fire. Memory usage grows over time.

```typescript
// ❌ BUG: subscription never cleaned up
@Component({...})
class MyComponent implements OnInit {
  ngOnInit() {
    interval(1000).subscribe(n => {
      this.counter = n;  // runs forever after component destroyed
    });
  }
}

// ✅ FIX 1: takeUntil pattern
class MyComponent implements OnInit, OnDestroy {
  private destroy$ = new Subject<void>();

  ngOnInit() {
    interval(1000).pipe(
      takeUntil(this.destroy$)
    ).subscribe(n => this.counter = n);
  }

  ngOnDestroy() {
    this.destroy$.next();
    this.destroy$.complete();
  }
}

// ✅ FIX 2: DestroyRef (Angular 16+)
class MyComponent {
  counter = 0;
  constructor() {
    interval(1000).pipe(
      takeUntilDestroyed()  // auto injects DestroyRef in constructor
    ).subscribe(n => this.counter = n);
  }
}

// ✅ FIX 3: Store subscription and unsubscribe
class MyComponent implements OnDestroy {
  private sub!: Subscription;
  ngOnInit() {
    this.sub = interval(1000).subscribe(n => this.counter = n);
  }
  ngOnDestroy() { this.sub.unsubscribe(); }
}
```

### Hot Observable Leaks

**Symptom:** Subject keeps emitting after consumers are gone.

```typescript
// ❌ BUG: Subject referenced in service outlives component
@Injectable({ providedIn: 'root' })
class DataService {
  private data$ = new BehaviorSubject<Data[]>([]);
  // This Subject lives for the app lifetime — any subscription to it
  // in a component must be manually cleaned up
}

// ✅ FIX: Always unsubscribe from long-lived service observables
class MyComponent implements OnDestroy {
  private destroy$ = new Subject<void>();
  constructor(private dataService: DataService) {
    this.dataService.data$.pipe(
      takeUntil(this.destroy$)
    ).subscribe(data => this.render(data));
  }
  ngOnDestroy() { this.destroy$.next(); this.destroy$.complete(); }
}
```

### shareReplay Without refCount

```typescript
// ❌ LEAK: refCount defaults to false — source subscription persists forever
const data$ = this.http.get('/api/data').pipe(
  shareReplay(1)
);

// ✅ FIX: always set refCount: true
const data$ = this.http.get('/api/data').pipe(
  shareReplay({ bufferSize: 1, refCount: true })
);
```

### Event Listener Leaks

```typescript
// ❌ LEAK: fromEvent on component element without cleanup
fromEvent(this.el.nativeElement, 'scroll').subscribe(e => { /* ... */ });

// ✅ FIX
fromEvent(this.el.nativeElement, 'scroll').pipe(
  takeUntil(this.destroy$)
).subscribe(e => { /* ... */ });
```

### Detecting Memory Leaks

1. **Chrome DevTools → Memory → Heap Snapshot**: Take before/after navigating away from component.
2. **`finalize` operator**: Add to observables to confirm teardown:
   ```typescript
   source$.pipe(
     finalize(() => console.log('Unsubscribed!')),
     takeUntil(this.destroy$)
   ).subscribe();
   ```
3. **RxJS Spy** (dev tool): `import { create } from 'rxjs-spy'; create();` — tags and traces subscriptions.

---

## Cold vs Hot Confusion

### Symptom: Multiple HTTP Calls

```typescript
// ❌ BUG: 3 HTTP requests because HttpClient returns cold observables
const users$ = this.http.get<User[]>('/api/users');
users$.subscribe(u => this.list = u);
users$.subscribe(u => this.count = u.length);
users$.subscribe(u => this.first = u[0]);

// ✅ FIX: share the subscription
const users$ = this.http.get<User[]>('/api/users').pipe(
  shareReplay({ bufferSize: 1, refCount: true })
);
```

### Symptom: Late Subscriber Gets Nothing

```typescript
// ❌ BUG: Subject emitted before component subscribed
const result$ = new Subject<string>();
result$.next('data');  // emitted to no one
result$.subscribe(console.log);  // never receives 'data'

// ✅ FIX 1: Use ReplaySubject
const result$ = new ReplaySubject<string>(1);
result$.next('data');
result$.subscribe(console.log);  // receives 'data'

// ✅ FIX 2: Use BehaviorSubject with initial value
const result$ = new BehaviorSubject<string>('');
result$.next('data');
result$.subscribe(console.log);  // receives 'data'
```

### Symptom: Side Effects Run Multiple Times

```typescript
// ❌ BUG: tap runs once per subscriber
const data$ = source$.pipe(
  tap(() => this.analytics.track('loaded')),
  map(transform)
);
data$.subscribe(handlerA);
data$.subscribe(handlerB);  // analytics.track called twice

// ✅ FIX: share before the tap, or share after
const data$ = source$.pipe(
  share(),
  tap(() => this.analytics.track('loaded')),
  map(transform)
);
```

---

## Operator Ordering Mistakes

### catchError Position

```typescript
// ❌ BUG: catchError kills the outer stream — no more retries
source$.pipe(
  switchMap(id => this.api.get(id)),
  catchError(err => of(fallback))
  // After one error, the outer stream completes/continues with fallback
  // but NO MORE switchMap projections will happen from source$
);

// ✅ FIX: catchError INSIDE the inner observable
source$.pipe(
  switchMap(id => this.api.get(id).pipe(
    catchError(err => of(fallback))  // error handled per-request
  ))
);
```

### takeUntil Position

**Rule: `takeUntil` should be the LAST operator in the pipe.**

```typescript
// ❌ BUG: operators after takeUntil may re-subscribe or leak
source$.pipe(
  takeUntil(this.destroy$),
  switchMap(id => this.api.get(id)),  // switchMap's inner sub may outlive destroy$
  shareReplay(1)                      // shareReplay keeps subscription alive
);

// ✅ FIX: takeUntil last
source$.pipe(
  switchMap(id => this.api.get(id)),
  shareReplay({ bufferSize: 1, refCount: true }),
  takeUntil(this.destroy$)
);
```

### share Position

```typescript
// ❌ BUG: share before filter means all subscribers get unfiltered emissions count
source$.pipe(
  share(),
  filter(x => x > 10)  // each subscriber filters independently — fine for logic
  // but share() is counting refs from upstream, not downstream
);

// ✅ Best practice: share after all common transformations
source$.pipe(
  filter(x => x > 10),
  map(x => x * 2),
  share()  // shared result already filtered and mapped
);
```

### distinctUntilChanged Position

```typescript
// ❌ BUG: distinctUntilChanged after map that creates new objects
source$.pipe(
  map(x => ({ value: x })),           // new object reference every time
  distinctUntilChanged()               // never filters (reference equality)
);

// ✅ FIX 1: custom comparator
source$.pipe(
  map(x => ({ value: x })),
  distinctUntilChanged((a, b) => a.value === b.value)
);

// ✅ FIX 2: distinctUntilChanged before creating new objects
source$.pipe(
  distinctUntilChanged(),
  map(x => ({ value: x }))
);
```

### debounceTime Before switchMap

```typescript
// ❌ ISSUE: debounceTime after switchMap doesn't debounce the requests
search$.pipe(
  switchMap(term => this.api.search(term)),  // request fires immediately
  debounceTime(300)                           // debounces results, not requests
);

// ✅ FIX: debounce input before making requests
search$.pipe(
  debounceTime(300),
  switchMap(term => this.api.search(term))
);
```

---

## Race Conditions

### combineLatest Initial Emission

**Symptom:** combineLatest doesn't emit until ALL sources have emitted at least once.

```typescript
// ❌ BUG: if filter$ never emits, nothing renders
combineLatest([data$, filter$]).pipe(
  map(([data, filter]) => applyFilter(data, filter))
);

// ✅ FIX: give filter$ an initial value
combineLatest([data$, filter$.pipe(startWith('all'))]).pipe(
  map(([data, filter]) => applyFilter(data, filter))
);
```

### switchMap Race with Side Effects

```typescript
// ❌ BUG: switchMap cancels client sub but server-side POST already sent
selectedItem$.pipe(
  switchMap(item => this.api.saveItem(item))  // previous save's HTTP still in flight
);

// ✅ FIX 1: exhaustMap — ignore while saving
selectedItem$.pipe(
  exhaustMap(item => this.api.saveItem(item))
);

// ✅ FIX 2: concatMap — queue saves
selectedItem$.pipe(
  concatMap(item => this.api.saveItem(item))
);
```

### forkJoin with Empty Observables

```typescript
// ❌ BUG: forkJoin never emits if any source completes without emitting
forkJoin({
  users: this.api.getUsers(),
  tags: EMPTY  // completes immediately without value — forkJoin never emits
});

// ✅ FIX: provide default for potentially empty observables
forkJoin({
  users: this.api.getUsers(),
  tags: this.api.getTags().pipe(defaultIfEmpty([]))
});
```

### Subscription Timing Issues

```typescript
// ❌ BUG: BehaviorSubject emits synchronously, subscriber misses logic
const data$ = new BehaviorSubject(initialData);
// ... some code that calls data$.next(newData)
data$.pipe(skip(1)).subscribe(handleUpdate);  // might miss updates

// ✅ FIX: subscribe before triggering emissions
const data$ = new BehaviorSubject(initialData);
data$.pipe(skip(1)).subscribe(handleUpdate);
// ... now safe to call data$.next(newData)
```

---

## shareReplay refCount Behavior

Detailed behavior comparison:

```typescript
// refCount: false (DEFAULT — dangerous)
const source$ = interval(1000).pipe(
  take(5),
  shareReplay(1)
);

const sub1 = source$.subscribe(v => console.log('A:', v)); // starts interval
sub1.unsubscribe();  // source keeps running!
// Later...
const sub2 = source$.subscribe(v => console.log('B:', v)); // gets replayed value + continues

// refCount: true (RECOMMENDED)
const source$ = interval(1000).pipe(
  take(5),
  shareReplay({ bufferSize: 1, refCount: true })
);

const sub1 = source$.subscribe(v => console.log('A:', v)); // starts interval
sub1.unsubscribe();  // source unsubscribed — interval stops
// Later...
const sub2 = source$.subscribe(v => console.log('B:', v)); // re-subscribes — starts fresh
```

**When refCount: false is intentional:** Caching data that should persist for the app lifetime (e.g., configuration, feature flags loaded once at startup).

```typescript
// Acceptable: app-level cache that should never re-fetch
@Injectable({ providedIn: 'root' })
class ConfigService {
  readonly config$ = this.http.get<Config>('/api/config').pipe(
    shareReplay(1)  // intentionally refCount: false — cache forever
  );
}
```

---

## Marble Testing Gotchas

### Time Progression Rules

Inside `scheduler.run()`, time works differently:

```typescript
scheduler.run(({ cold, expectObservable }) => {
  // Each `-` is 1ms (not 10ms like outside run())
  // `10ms` syntax for explicit time: `--10ms--a`

  // ❌ WRONG: expecting real-time behavior
  const source = cold('--a|');  // `a` emits at 2ms, not 20ms

  // ✅ Correct frame understanding
  // '-' = 1ms, 'a' = 1ms, '|' = 1ms
  // '--a|' total = 4 frames: frame 0 (-), frame 1 (-), frame 2 (a), frame 3 (|)
});
```

### Hot vs Cold in Tests

```typescript
scheduler.run(({ hot, cold, expectObservable }) => {
  // cold: starts emitting at subscription time (relative)
  const cold$ = cold('--a--b|');

  // hot: emits on absolute timeline; `^` marks subscription point
  const hot$ = hot('--a--^--b--c|');
  //                       ^ subscribers start here, never see 'a'

  // ❌ COMMON MISTAKE: using cold when you need hot for shared sources
  // Cold creates a new producer per subscriber — may not test multicast correctly
});
```

### Async Operations in Marble Tests

```typescript
// ❌ BUG: real HTTP calls don't work with TestScheduler
scheduler.run(({ cold, expectObservable }) => {
  // This won't work — actual HTTP is outside virtual time
  const result = source$.pipe(
    switchMap(() => this.http.get('/api'))  // real async!
  );
  expectObservable(result).toBe(/* won't match */);
});

// ✅ FIX: mock the async operation with cold/hot observables
scheduler.run(({ cold, expectObservable }) => {
  const mockApi = cold('--r|', { r: { data: 'test' } });
  jest.spyOn(service, 'getData').mockReturnValue(mockApi);

  const source = cold('  -a---b|');
  const expected = '     ---r---r|';  // switchMap to mockApi
  expectObservable(source.pipe(switchMap(() => mockApi))).toBe(expected, { r: { data: 'test' } });
});
```

### Common Marble Mistakes

```typescript
// ❌ MISTAKE 1: Forgetting that synchronous emissions are grouped with ()
const sync$ = of(1, 2, 3);
// Marble: '(abc|)'  NOT 'abc|'

// ❌ MISTAKE 2: Values in marble diagrams are strings by default
cold('--a--b|');  // a = 'a', b = 'b' (strings, not variables)
cold('--a--b|', { a: 1, b: 2 });  // a = 1, b = 2 (use values map)

// ❌ MISTAKE 3: Not accounting for debounceTime virtual time
const source   = cold('-a-b-c---|');
// debounceTime(3) in virtual time = 3 frames = '---'
// After c at frame 5, debounce waits 3 more frames
const expected = '     --------c|';  // NOT '---------c|'
// Exact timing depends on operator semantics — use trial and error

// ❌ MISTAKE 4: expectObservable must be called inside run()
scheduler.run(helpers => {
  const { cold, expectObservable } = helpers;
  // ✅ CORRECT: all calls inside run()
  expectObservable(source$.pipe(map(x => x))).toBe('...');
});
// ❌ WRONG: expectObservable outside run()
```

---

## Angular-Specific Pitfalls

### ExpressionChangedAfterItHasBeenCheckedError

**Cause:** Observable emits synchronously during change detection, modifying a value Angular already checked.

```typescript
// ❌ TRIGGERS ERROR:
@Component({
  template: `{{ value }}`
})
class MyComponent implements OnInit {
  value = '';
  ngOnInit() {
    // BehaviorSubject emits synchronously on subscribe — during CD cycle
    this.service.data$.subscribe(v => this.value = v);
  }
}

// ✅ FIX 1: Use async pipe (handles CD automatically)
@Component({
  template: `{{ data$ | async }}`
})
class MyComponent {
  data$ = this.service.data$;
}

// ✅ FIX 2: Delay emission to next CD cycle
ngOnInit() {
  this.service.data$.pipe(
    observeOn(asyncScheduler),  // push to next macrotask
    takeUntil(this.destroy$)
  ).subscribe(v => this.value = v);
}

// ✅ FIX 3: Force change detection
constructor(private cdr: ChangeDetectorRef) {}
ngOnInit() {
  this.service.data$.pipe(takeUntil(this.destroy$)).subscribe(v => {
    this.value = v;
    this.cdr.detectChanges();  // explicit CD after mutation
  });
}
```

### Zone.js Interactions

Zone.js patches async APIs. RxJS operators that use `setTimeout`/`setInterval` trigger change detection.

```typescript
// ❌ PROBLEM: interval triggers CD every second even if value not used in template
interval(1000).subscribe(() => { /* background work */ });

// ✅ FIX: Run outside Angular zone
constructor(private ngZone: NgZone) {}
ngOnInit() {
  this.ngZone.runOutsideAngular(() => {
    interval(1000).pipe(
      takeUntil(this.destroy$)
    ).subscribe(() => {
      // background work — no CD triggered
      if (this.needsUpdate) {
        this.ngZone.run(() => {
          // only trigger CD when actually needed
          this.updateView();
        });
      }
    });
  });
}

// ✅ Zoneless Angular (Angular 18+ experimental):
// With provideExperimentalZonelessChangeDetection(), zone.js is not needed
// Use signals or manual CD triggers
```

### Router Guard Completion

```typescript
// ❌ BUG: Guard observable never completes — navigation hangs
canActivate(): Observable<boolean> {
  return this.auth.user$;  // BehaviorSubject — never completes!
}

// ✅ FIX: take(1) or first() to complete after first emission
canActivate(): Observable<boolean> {
  return this.auth.user$.pipe(
    map(user => !!user),
    take(1)
  );
}
```

### HttpClient Subscription Gotchas

```typescript
// ❌ BUG: Double subscription = double HTTP request
@Component({
  template: `
    <div>{{ users$ | async | json }}</div>
    <div>Count: {{ (users$ | async)?.length }}</div>
  `
})
class UsersComponent {
  users$ = this.http.get<User[]>('/api/users');  // cold — each async creates new sub
}

// ✅ FIX: Share the observable or use a single async pipe
@Component({
  template: `
    <ng-container *ngIf="users$ | async as users">
      <div>{{ users | json }}</div>
      <div>Count: {{ users.length }}</div>
    </ng-container>
  `
})
class UsersComponent {
  users$ = this.http.get<User[]>('/api/users').pipe(
    shareReplay({ bufferSize: 1, refCount: true })
  );
}
```

### OnPush + Observable Gotchas

```typescript
// ❌ BUG: OnPush doesn't detect changes from subscribe()
@Component({
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `{{ data }}`
})
class MyComponent implements OnInit {
  data = '';
  ngOnInit() {
    this.service.getData().subscribe(d => this.data = d);  // CD not triggered
  }
}

// ✅ FIX 1: Use async pipe (triggers markForCheck automatically)
@Component({
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `{{ data$ | async }}`
})
class MyComponent {
  data$ = this.service.getData();
}

// ✅ FIX 2: Manually mark for check
constructor(private cdr: ChangeDetectorRef) {}
ngOnInit() {
  this.service.getData().subscribe(d => {
    this.data = d;
    this.cdr.markForCheck();
  });
}
```

### Signals + RxJS Interop Issues

```typescript
import { toSignal, toObservable } from '@angular/core/rxjs-interop';

// ❌ BUG: toSignal outside injection context
class MyComponent {
  data = toSignal(this.service.data$);  // ERROR: must be in injection context
}

// ✅ FIX: Use in constructor or field initializer with inject()
class MyComponent {
  private service = inject(DataService);
  data = toSignal(this.service.data$, { initialValue: [] });

  // Or in constructor
  constructor() {
    this.data = toSignal(this.service.data$, { initialValue: [] });
  }
}

// ❌ BUG: toSignal without initialValue on observable that doesn't emit synchronously
data = toSignal(this.http.get('/api'));  // type is T | undefined, initial is undefined

// ✅ FIX: Provide initialValue or use requireSync for BehaviorSubjects
data = toSignal(this.http.get('/api'), { initialValue: [] });
syncData = toSignal(this.behaviorSubject$, { requireSync: true }); // no undefined

// ⚠️ toSignal subscribes and auto-unsubscribes on destroy
// ⚠️ toObservable creates a ReplaySubject(1) — first emit is the current signal value
```
