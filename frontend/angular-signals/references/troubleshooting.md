# Angular Signals — Troubleshooting Guide

## Table of Contents

- [effect() Pitfalls](#effect-pitfalls)
- [computed() Caching Gotchas](#computed-caching-gotchas)
- [Signal Mutation vs Set](#signal-mutation-vs-set)
- [Circular Dependencies](#circular-dependencies)
- [Memory Leaks with effect()](#memory-leaks-with-effect)
- [Migration Issues: Decorators → Signals](#migration-issues-decorators--signals)
- [Zone.js Removal Problems](#zonejs-removal-problems)
- [Testing Signals](#testing-signals)
- [Common Error Messages](#common-error-messages)

---

## effect() Pitfalls

### 1. Missing Cleanup — Timers and Subscriptions Leak

```typescript
// ❌ BAD: interval never cleared
effect(() => {
  setInterval(() => console.log(count()), 1000);
});

// ✅ FIX: use onCleanup
effect((onCleanup) => {
  const id = setInterval(() => console.log(count()), 1000);
  onCleanup(() => clearInterval(id));
});
```

**Rule:** Any effect that creates subscriptions, timers, event listeners, or WebSocket connections MUST use `onCleanup`.

### 2. Using effect() to Sync Signals (Anti-Pattern)

```typescript
// ❌ BAD: effect to derive state — causes ExpressionChangedAfterItHasBeenChecked
effect(() => {
  this.fullName.set(`${this.firstName()} ${this.lastName()}`);
});

// ✅ FIX: use computed() — no side effect needed
fullName = computed(() => `${this.firstName()} ${this.lastName()}`);
```

If writable derived state is needed, use `linkedSignal()`:

```typescript
// ✅ Writable + derived
fullName = linkedSignal(() => `${this.firstName()} ${this.lastName()}`);
fullName.set('Override Name'); // can be overridden locally
```

### 3. effect() Outside Injection Context

```typescript
// ❌ THROWS: "effect() can only be used within an injection context"
ngOnInit() {
  effect(() => console.log(this.data()));
}

// ✅ FIX: inject Injector and pass it
private injector = inject(Injector);
ngOnInit() {
  effect(() => console.log(this.data()), { injector: this.injector });
}

// ✅ BETTER: define in constructor or field initializer
constructor() {
  effect(() => console.log(this.data()));
}
```

### 4. effect() Runs Before View Is Ready

```typescript
// ❌ viewChild may be undefined during first effect run
header = viewChild(HeaderComponent);
constructor() {
  effect(() => {
    this.header()!.doSomething(); // TypeError: Cannot read property of undefined
  });
}

// ✅ FIX: guard against undefined
constructor() {
  effect(() => {
    const h = this.header();
    if (h) h.doSomething();
  });
}
```

### 5. allowSignalWrites Deprecation

```typescript
// ❌ DEPRECATED in Angular 19+
effect(() => {
  this.derived.set(this.source() * 2);
}, { allowSignalWrites: true });

// In Angular 19+, signal writes in effects are allowed by default,
// but it's still an anti-pattern. Use computed() or linkedSignal() instead.
```

---

## computed() Caching Gotchas

### 1. Impure Functions Break Caching

```typescript
// ❌ BAD: Date.now() is not tracked — computed never updates
const timestamp = computed(() => Date.now());

// ❌ BAD: Math.random() gives stale results
const rand = computed(() => Math.random());

// ✅ FIX: use a signal to hold the changing value
const now = signal(Date.now());
setInterval(() => now.set(Date.now()), 1000);
const timestamp = computed(() => now());
```

### 2. Side Effects in computed()

```typescript
// ❌ BAD: API call inside computed — fires unpredictably
const data = computed(() => {
  fetch('/api/data').then(r => r.json()); // side effect!
  return this.items().length;
});

// ✅ FIX: use resource() for async, keep computed() pure
const data = resource({
  params: () => ({ query: this.query() }),
  loader: ({ params }) => fetch(`/api?q=${params.query}`).then(r => r.json()),
});
```

### 3. computed() Returns Same Reference — Consumers Don't Update

```typescript
// ❌ GOTCHA: returns new array every time, but items are same
const active = computed(() => this.items().filter(i => i.active));
// This WILL notify consumers every time items() changes,
// even if the filtered result is identical

// ✅ FIX: use custom equality
const active = computed(
  () => this.items().filter(i => i.active),
  { equal: (a, b) => a.length === b.length && a.every((v, i) => v.id === b[i].id) }
);
```

### 4. Reading Signal Conditionally = Dynamic Dependencies

```typescript
const result = computed(() => {
  if (this.useCache()) {
    return this.cache(); // only tracked when useCache() is true
  }
  return this.liveData(); // only tracked when useCache() is false
});
// When useCache() flips, dependency tracking changes dynamically.
// This is intentional and correct, but can be surprising.
```

---

## Signal Mutation vs Set

### The Core Rule: Produce New References

```typescript
// ❌ BAD: mutating in place — signal doesn't detect the change
const items = signal<Item[]>([]);
items().push(newItem); // mutates existing array, no notification!

// ✅ FIX: always produce a new reference
items.update(list => [...list, newItem]);
items.set([...items(), newItem]);
```

### Object Properties

```typescript
// ❌ BAD: mutating object in place
const user = signal({ name: 'Ada', age: 30 });
user().name = 'Bob'; // NO notification

// ✅ FIX: new object via spread
user.update(u => ({ ...u, name: 'Bob' }));
```

### Deep Nested Objects

```typescript
// For deeply nested state, consider:
// 1. Flatten your state — separate signals per field
const name = signal('Ada');
const age = signal(30);

// 2. Use immer-style immutable updates if structure is complex
import { produce } from 'immer';
const state = signal(deepObject);
state.update(s => produce(s, draft => { draft.nested.value = 42; }));
```

---

## Circular Dependencies

### Direct Circular — Infinite Loop

```typescript
// ❌ INFINITE LOOP
const a = signal(1);
const b = computed(() => a() + 1);
effect(() => a.set(b())); // a → b → effect → a → b → ...

// ✅ FIX: break the cycle — derive without feeding back
const a = signal(1);
const b = computed(() => a() + 1); // one-way derivation only
```

### Indirect Circular via Services

```typescript
// ❌ Service A reads Service B signal, Service B reads Service A signal
// This compiles but causes stack overflow at runtime

// ✅ FIX: introduce a mediator service or merge the coupled state
@Injectable({ providedIn: 'root' })
export class SharedState {
  readonly a = signal(0);
  readonly b = signal(0);
  readonly combined = computed(() => this.a() + this.b());
}
```

### linkedSignal Circular

```typescript
// ❌ linkedSignal depending on itself (won't compile but conceptually wrong)
// Always ensure linkedSignal's source does not include the linkedSignal's own value
```

---

## Memory Leaks with effect()

### Effects Tied to Component Lifecycle

```typescript
// Effects created in injection context auto-destroy with the component.
// No manual cleanup needed for field-level effects:
export class MyCmp {
  private eff = effect(() => console.log(this.data()));
  // ↑ auto-destroyed when MyCmp is destroyed
}
```

### Effects Created Dynamically — MUST Manage Lifecycle

```typescript
// ❌ BAD: creating effect in a method — runs every call, never destroyed
onClick() {
  effect(() => console.log(this.data())); // LEAK!
}

// ✅ FIX: create once, or use DestroyRef
private effectRef: EffectRef | null = null;
onClick() {
  this.effectRef?.destroy();
  this.effectRef = effect(() => console.log(this.data()), {
    injector: this.injector,
  });
}
```

### Signals in Services — Singleton Caution

```typescript
// providedIn: 'root' services live forever — effects in them never destroy
@Injectable({ providedIn: 'root' })
export class GlobalService {
  constructor() {
    // This effect lives for the entire app lifetime — OK if intentional
    effect(() => localStorage.setItem('theme', this.theme()));
  }
}

// For feature-scoped services, provide at component level:
@Component({
  providers: [FeatureScopedStore], // destroyed with component
})
```

---

## Migration Issues: Decorators → Signals

### 1. Timing Differences — ngOnChanges vs Reactive

```typescript
// BEFORE: ngOnChanges fires after every input change with SimpleChanges
ngOnChanges(changes: SimpleChanges) {
  if (changes['userId']) this.loadUser(changes['userId'].currentValue);
}

// AFTER: use effect() or computed() — runs reactively, no lifecycle hook needed
userId = input.required<number>();
constructor() {
  effect(() => this.loadUser(this.userId()));
}
// ⚠️ Note: effect() runs asynchronously; ngOnChanges was synchronous.
```

### 2. @ViewChild Read Timing

```typescript
// BEFORE: available in ngAfterViewInit
@ViewChild('chart') chart!: ElementRef;
ngAfterViewInit() { this.initChart(this.chart.nativeElement); }

// AFTER: signal query — available reactively
chart = viewChild.required<ElementRef>('chart');
constructor() {
  effect(() => this.initChart(this.chart().nativeElement));
}
// ⚠️ viewChild signal resolves after view init — guard if using optional variant
```

### 3. QueryList Iteration vs Signal Array

```typescript
// BEFORE: QueryList has changes observable, forEach, etc.
@ViewChildren(ItemCmp) items!: QueryList<ItemCmp>;
ngAfterViewInit() {
  this.items.changes.subscribe(list => console.log(list.length));
}

// AFTER: signal array — use computed/effect for change tracking
items = viewChildren(ItemCmp);
itemCount = computed(() => this.items().length);
// No .changes observable — reactivity is built in
```

### 4. @Output + EventEmitter Patterns

```typescript
// BEFORE: EventEmitter supports .pipe() (it extends Subject)
@Output() saved = new EventEmitter<Item>();
// Some code was .pipe()-ing on EventEmitter — this breaks with output()

// AFTER: output() returns OutputEmitterRef — NOT an Observable
saved = output<Item>();
// If you need an observable: use outputToObservable(this.childRef.saved)
```

### 5. Migration Schematics Limitations

```bash
# Official schematics:
ng generate @angular/core:signal-input-migration
ng generate @angular/core:signal-queries-migration
ng generate @angular/core:output-migration

# Limitations:
# - Won't migrate if input has ngOnChanges logic referencing SimpleChanges
# - Won't migrate @ViewChild with { static: true } (no signal equivalent)
# - Won't migrate @ContentChild in directives with complex selectors
# - Always review generated code — schematics are best-effort
```

---

## Zone.js Removal Problems

### 1. Third-Party Libraries That Depend on Zone.js

```typescript
// Symptom: UI doesn't update after library callback
// Libraries that use setTimeout/Promise internally won't trigger CD

// Fix: wrap library callbacks to update signals
thirdPartyLib.onData((data) => {
  this.data.set(data); // signal update triggers CD in zoneless
});
```

### 2. Material/CDK Components

```typescript
// Angular Material 18+ is zoneless-compatible.
// Older versions may have issues with:
// - MatDialog (async open/close)
// - Overlay positioning
// - Autocomplete debounce

// Fix: update to latest Material version
// Or inject ChangeDetectorRef and call markForCheck() as fallback
```

### 3. Router Events Missing CD

```typescript
// Symptom: navigation completes but view doesn't update

// Fix: convert router events to signals
private router = inject(Router);
readonly currentUrl = toSignal(
  this.router.events.pipe(
    filter(e => e instanceof NavigationEnd),
    map(e => (e as NavigationEnd).url),
  ),
  { initialValue: '/' }
);
```

### 4. Forms (Reactive & Template-Driven)

```typescript
// Reactive Forms use internal zone-based CD.
// In zoneless mode, valueChanges still works but view may not update.

// Fix: bridge form values to signals
const nameControl = new FormControl('');
const name = toSignal(nameControl.valueChanges, { initialValue: '' });

// Or use signal-based forms (community packages) for full zoneless support
```

### 5. HttpClient Interceptors

```typescript
// HttpClient works in zoneless if using:
// - resource() / httpResource() — auto-updates signals
// - toSignal(httpCall$) — bridges to signal

// ⚠️ Manual .subscribe() on HttpClient won't trigger CD
// Always update a signal in the subscribe callback
this.http.get<Data>('/api').subscribe(data => this.data.set(data));
```

---

## Testing Signals

### Unit Testing Signals

```typescript
it('should compute derived value', () => {
  const count = signal(5);
  const doubled = computed(() => count() * 2);

  expect(doubled()).toBe(10);
  count.set(3);
  expect(doubled()).toBe(6); // computed updates synchronously
});
```

### Testing Effects

```typescript
it('should run effect on signal change', () => {
  TestBed.configureTestingModule({});
  const log: number[] = [];

  TestBed.runInInjectionContext(() => {
    const val = signal(1);
    effect(() => log.push(val()));

    TestBed.flushEffects(); // flush pending effects
    expect(log).toEqual([1]);

    val.set(2);
    TestBed.flushEffects();
    expect(log).toEqual([1, 2]);
  });
});
```

### Testing Components with Signal Inputs

```typescript
it('should render signal input', () => {
  const fixture = TestBed.createComponent(MyComponent);
  // Use componentRef.setInput() for signal inputs
  fixture.componentRef.setInput('name', 'Ada');
  fixture.detectChanges();
  expect(fixture.nativeElement.textContent).toContain('Ada');
});
```

---

## Common Error Messages

| Error | Cause | Fix |
|-------|-------|-----|
| `NG0600: Writing to signals is not allowed in a computed or template` | Signal `.set()`/`.update()` inside `computed()` | Move write to `effect()` or use `linkedSignal()` |
| `NG0602: effect() can only be used within an injection context` | `effect()` called in `ngOnInit` or method | Move to constructor/field, or pass `{ injector }` |
| `NG0203: inject() must be called from an injection context` | `toSignal()` called outside constructor/field | Pass injector or restructure |
| `ExpressionChangedAfterItHasBeenChecked` | `effect()` writing signals read in template | Use `computed()` instead of `effect()` for derivation |
| `Required input 'x' not provided` | `input.required()` not bound in template | Add `[x]="value"` to parent template |
| Stack overflow | Circular signal dependencies | Break dependency cycle (see Circular Dependencies section) |
