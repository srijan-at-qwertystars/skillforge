# Angular Signals — API Reference

## Table of Contents

- [Core: signal()](#signal)
- [Core: computed()](#computed)
- [Core: effect()](#effect)
- [Component: input()](#input)
- [Component: output()](#output)
- [Component: model()](#model)
- [Queries: viewChild()](#viewchild)
- [Queries: viewChildren()](#viewchildren)
- [Queries: contentChild()](#contentchild)
- [Queries: contentChildren()](#contentchildren)
- [RxJS Interop: toSignal()](#tosignal)
- [RxJS Interop: toObservable()](#toobservable)
- [Advanced: linkedSignal()](#linkedsignal)
- [Advanced: resource()](#resource)
- [Advanced: httpResource()](#httpresource)
- [Utility: untracked()](#untracked)
- [Lifecycle: DestroyRef](#destroyref)
- [RxJS Interop: takeUntilDestroyed()](#takeuntildestroyed)
- [RxJS Interop: outputToObservable()](#outputtoobservable)
- [RxJS Interop: outputFromObservable()](#outputfromobservable)

---

## `signal()`

**Import:** `@angular/core`
**Since:** Angular 16

Creates a writable reactive signal.

```typescript
function signal<T>(initialValue: T, options?: SignalOptions<T>): WritableSignal<T>;
```

**SignalOptions:**
```typescript
interface SignalOptions<T> {
  equal?: (a: T, b: T) => boolean;  // default: Object.is
}
```

**WritableSignal members:**
```typescript
interface WritableSignal<T> extends Signal<T> {
  (): T;                              // read current value
  set(value: T): void;                // replace value
  update(fn: (current: T) => T): void; // derive new value from current
  asReadonly(): Signal<T>;            // return read-only view
}
```

**Examples:**
```typescript
const count = signal(0);                                    // WritableSignal<number>
const user = signal<User | null>(null);                     // WritableSignal<User | null>
const cfg = signal({ a: 1 }, { equal: (x, y) => x.a === y.a }); // custom equality
count.set(5);
count.update(v => v + 1);
const ro: Signal<number> = count.asReadonly();
```

---

## `computed()`

**Import:** `@angular/core`
**Since:** Angular 16

Creates a read-only signal derived from other signals. Lazy and memoized.

```typescript
function computed<T>(computation: () => T, options?: ComputedOptions<T>): Signal<T>;
```

**ComputedOptions:**
```typescript
interface ComputedOptions<T> {
  equal?: (a: T, b: T) => boolean;  // default: Object.is
}
```

**Behavior:**
- Lazy: won't execute until first read
- Memoized: caches result until a dependency changes
- Dynamic deps: tracks only signals read in the latest execution
- Must be pure: no side effects, no signal writes, no async

```typescript
const doubled = computed(() => count() * 2);
const fullName = computed(() => `${first()} ${last()}`);
const filtered = computed(
  () => items().filter(i => i.active),
  { equal: (a, b) => a.length === b.length }
);
```

---

## `effect()`

**Import:** `@angular/core`
**Since:** Angular 16

Registers a side-effect callback that re-runs when tracked signals change.

```typescript
function effect(
  fn: (onCleanup: (cleanupFn: () => void) => void) => void,
  options?: CreateEffectOptions
): EffectRef;
```

**CreateEffectOptions:**
```typescript
interface CreateEffectOptions {
  injector?: Injector;          // required if outside injection context
  manualCleanup?: boolean;      // if true, effect is not auto-destroyed (default: false)
  // allowSignalWrites was deprecated in Angular 19 (now always allowed)
}
```

**EffectRef:**
```typescript
interface EffectRef {
  destroy(): void;  // manually destroy the effect
}
```

**Cleanup pattern:**
```typescript
effect((onCleanup) => {
  const sub = source$.subscribe(v => handle(v));
  onCleanup(() => sub.unsubscribe());
});
```

**With injector (outside injection context):**
```typescript
effect(() => doSomething(sig()), { injector: this.injector });
```

---

## `input()`

**Import:** `@angular/core`
**Since:** Angular 17.1

Signal-based component input. Replaces `@Input()` decorator.

```typescript
function input<T>(): InputSignal<T | undefined>;
function input<T>(initialValue: T): InputSignal<T>;
function input<T>(initialValue: T, opts: InputOptions<T>): InputSignal<T>;

// Required variant:
input.required<T>(): InputSignal<T>;
input.required<T>(opts: InputOptions<T>): InputSignal<T>;
```

**InputOptions:**
```typescript
interface InputOptions<T, TransformT = T> {
  alias?: string;                                     // public binding name
  transform?: (value: TransformT) => T;               // transform on input
}
```

**InputSignal:** Read-only — call as function to get value, no `.set()`.

```typescript
// Optional with default
name = input('');                              // InputSignal<string>
// Optional without default
label = input<string>();                       // InputSignal<string | undefined>
// Required
id = input.required<number>();                 // InputSignal<number>
// With alias
userName = input('', { alias: 'user-name' }); // bind as [user-name]
// With transform
disabled = input(false, { transform: booleanAttribute }); // accepts '' → true
count = input(0, { transform: numberAttribute });
```

---

## `output()`

**Import:** `@angular/core`
**Since:** Angular 17.3

Signal-based component output. Replaces `@Output()` + `EventEmitter`.

```typescript
function output<T = void>(opts?: OutputOptions): OutputEmitterRef<T>;
```

**OutputOptions:**
```typescript
interface OutputOptions {
  alias?: string;  // public event name
}
```

**OutputEmitterRef:**
```typescript
interface OutputEmitterRef<T> {
  emit(value: T): void;
  subscribe(fn: (value: T) => void): OutputRefSubscription;
}
```

```typescript
saved = output<Item>();                    // OutputEmitterRef<Item>
closed = output<void>();                   // OutputEmitterRef<void>
aliased = output<string>({ alias: 'on-change' });

this.saved.emit(item);
this.closed.emit();
```

---

## `model()`

**Import:** `@angular/core`
**Since:** Angular 17.2

Two-way binding signal. Writable from both parent and child.

```typescript
function model<T>(): ModelSignal<T | undefined>;
function model<T>(initialValue: T): ModelSignal<T>;
model.required<T>(): ModelSignal<T>;
```

**ModelSignal:** Extends `WritableSignal<T>` — can `.set()` and `.update()`.

```typescript
// Child:
value = model(0);                     // ModelSignal<number>
value = model.required<string>();     // required
// Parent template:
// <child [(value)]="parentSignal" />
```

Writing in child emits `valueChange` event to parent automatically.

---

## `viewChild()`

**Import:** `@angular/core`
**Since:** Angular 17.2

Signal-based view query. Replaces `@ViewChild()`.

```typescript
function viewChild<T>(locator: Type<T> | string): Signal<T | undefined>;
function viewChild<T>(locator: Type<T> | string, opts: { read: Type<T> }): Signal<T | undefined>;

viewChild.required<T>(locator: Type<T> | string): Signal<T>;
viewChild.required<T>(locator: Type<T> | string, opts: { read: Type<T> }): Signal<T>;
```

```typescript
header = viewChild(HeaderComponent);             // Signal<HeaderComponent | undefined>
headerRef = viewChild<ElementRef>('header');      // template ref variable
canvas = viewChild.required<ElementRef>('canvas', { read: ElementRef }); // required
```

---

## `viewChildren()`

**Import:** `@angular/core`
**Since:** Angular 17.2

Signal-based view query for multiple elements. Replaces `@ViewChildren()`.

```typescript
function viewChildren<T>(locator: Type<T> | string): Signal<readonly T[]>;
function viewChildren<T>(locator: Type<T> | string, opts: { read: Type<T> }): Signal<readonly T[]>;
```

```typescript
items = viewChildren(ItemComponent);                    // Signal<readonly ItemComponent[]>
inputs = viewChildren<ElementRef>('inputRef', { read: ElementRef });
```

---

## `contentChild()`

**Import:** `@angular/core`
**Since:** Angular 17.2

Signal-based content query. Replaces `@ContentChild()`.

```typescript
function contentChild<T>(locator: Type<T> | string): Signal<T | undefined>;
function contentChild<T>(locator: Type<T> | string, opts: { read: Type<T>, descendants?: boolean }): Signal<T | undefined>;

contentChild.required<T>(locator: Type<T> | string): Signal<T>;
```

```typescript
toggle = contentChild(ToggleDirective);               // Signal<ToggleDirective | undefined>
tmpl = contentChild.required(TemplateRef);            // Signal<TemplateRef<any>>
```

---

## `contentChildren()`

**Import:** `@angular/core`
**Since:** Angular 17.2

Signal-based content query for multiple projected elements. Replaces `@ContentChildren()`.

```typescript
function contentChildren<T>(
  locator: Type<T> | string,
  opts?: { read?: Type<T>, descendants?: boolean }
): Signal<readonly T[]>;
```

```typescript
tabs = contentChildren(TabComponent);                            // Signal<readonly TabComponent[]>
templates = contentChildren(TemplateRef, { descendants: true }); // include deep children
```

---

## `toSignal()`

**Import:** `@angular/core/rxjs-interop`
**Since:** Angular 16

Converts an RxJS Observable to a Signal. Subscribes immediately.

```typescript
function toSignal<T>(source: Observable<T>): Signal<T | undefined>;
function toSignal<T>(source: Observable<T>, opts: { initialValue: T }): Signal<T>;
function toSignal<T>(source: Observable<T>, opts: { requireSync: true }): Signal<T>;
function toSignal<T>(source: Observable<T>, opts: ToSignalOptions<T>): Signal<T>;
```

**ToSignalOptions:**
```typescript
interface ToSignalOptions<T> {
  initialValue?: T;                // value before first emission
  requireSync?: boolean;           // source must emit synchronously (BehaviorSubject)
  injector?: Injector;             // for use outside injection context
  manualCleanup?: boolean;         // don't auto-unsubscribe on DestroyRef (default: false)
  rejectErrors?: boolean;          // errors reset signal to undefined (default: false)
  equal?: (a: T, b: T) => boolean; // custom equality
}
```

```typescript
const params = toSignal(this.route.params);                           // Signal<Params | undefined>
const params = toSignal(this.route.params, { initialValue: {} });     // Signal<Params>
const val = toSignal(behaviorSub$, { requireSync: true });            // Signal<T>
const data = toSignal(data$, { injector: this.injector });            // outside injection context
```

---

## `toObservable()`

**Import:** `@angular/core/rxjs-interop`
**Since:** Angular 16

Converts a Signal to an RxJS Observable. Emits asynchronously via microtask.

```typescript
function toObservable<T>(source: Signal<T>, opts?: ToObservableOptions): Observable<T>;
```

**ToObservableOptions:**
```typescript
interface ToObservableOptions {
  injector?: Injector;  // for use outside injection context
}
```

```typescript
const count$ = toObservable(this.count);
count$.pipe(debounceTime(300), distinctUntilChanged()).subscribe(v => handle(v));
```

**Note:** Emits via microtask scheduling — not synchronous. Deduplicates values via the signal's equality function.

---

## `linkedSignal()`

**Import:** `@angular/core`
**Since:** Angular 19

A writable computed signal. Recomputes when source signals change, but can be locally overridden.

```typescript
// Shorthand form:
function linkedSignal<T>(computation: () => T, options?: SignalOptions<T>): WritableSignal<T>;

// Object form (with previous value):
function linkedSignal<S, T>(opts: {
  source: () => S;
  computation: (source: S, previous?: { source: S; value: T }) => T;
  equal?: (a: T, b: T) => boolean;
}): WritableSignal<T>;
```

```typescript
// Shorthand: resets when source changes
const items = signal(['a', 'b']);
const count = linkedSignal(() => items().length);
count.set(99);         // local override
items.set(['x']);       // count resets to 1

// Object form: access previous values
const selected = linkedSignal({
  source: () => this.userId(),
  computation: (userId, previous) => {
    if (previous && previous.source === userId) return previous.value;
    return ''; // reset on user change
  },
});
```

---

## `resource()`

**Import:** `@angular/core`
**Since:** Angular 19

Reactive async data loader. Auto-reloads when parameter signals change.

```typescript
function resource<T, P>(opts: ResourceOptions<T, P>): ResourceRef<T>;
```

**ResourceOptions:**
```typescript
interface ResourceOptions<T, P> {
  params: () => P;                                         // reactive params (tracked)
  loader: (opts: { params: P; abortSignal: AbortSignal }) => Promise<T>;
  equal?: (a: T, b: T) => boolean;
  injector?: Injector;
}
```

**ResourceRef:**
```typescript
interface ResourceRef<T> {
  value: Signal<T | undefined>;           // current data
  status: Signal<ResourceStatus>;         // Idle | Loading | Resolved | Error | Reloading
  isLoading: Signal<boolean>;
  error: Signal<unknown | undefined>;
  reload(): void;                         // force re-fetch
  set(value: T): void;                    // locally override (until next reload)
  update(fn: (v: T | undefined) => T): void;
  hasValue(): boolean;
}
```

**ResourceStatus enum:** `Idle` | `Loading` | `Reloading` | `Resolved` | `Error` | `Local`

```typescript
const userRes = resource({
  params: () => ({ id: this.userId() }),
  loader: async ({ params, abortSignal }) => {
    const res = await fetch(`/api/users/${params.id}`, { signal: abortSignal });
    if (!res.ok) throw new Error('Failed');
    return res.json() as Promise<User>;
  },
});
```

---

## `httpResource()`

**Import:** `@angular/common/http`
**Since:** Angular 19.2

Signal-based HTTP resource using `HttpClient`. Supports interceptors.

```typescript
function httpResource<T>(url: () => string | HttpResourceRequest): HttpResourceRef<T>;
```

**HttpResourceRequest:**
```typescript
interface HttpResourceRequest {
  url: string;
  method?: string;                    // default: 'GET'
  headers?: HttpHeaders | Record<string, string>;
  params?: HttpParams | Record<string, string>;
  body?: any;
  reportProgress?: boolean;
  withCredentials?: boolean;
  transferCache?: boolean | { includeHeaders?: string[] };
}
```

```typescript
// Simple URL
const todos = httpResource<Todo[]>(() => `/api/todos`);

// With options
const users = httpResource<User[]>(() => ({
  url: '/api/users',
  params: { page: page().toString(), sort: sortField() },
  headers: { Authorization: `Bearer ${token()}` },
}));
```

---

## `untracked()`

**Import:** `@angular/core`
**Since:** Angular 16

Reads a signal's value without creating a dependency in the current reactive context.

```typescript
function untracked<T>(fn: () => T): T;
```

```typescript
effect(() => {
  const name = this.name();                        // tracked
  const config = untracked(() => this.config());   // NOT tracked
  save(name, config);
});

computed(() => {
  const items = this.items();                      // tracked
  const len = untracked(() => this.pageSize());    // NOT tracked
  return items.slice(0, len);
});
```

---

## `DestroyRef`

**Import:** `@angular/core`
**Since:** Angular 16

Injectable token for registering cleanup callbacks on component/directive/service destruction.

```typescript
abstract class DestroyRef {
  abstract onDestroy(fn: () => void): () => void;  // returns unregister function
}
```

```typescript
private destroyRef = inject(DestroyRef);

ngOnInit() {
  const sub = obs$.subscribe(v => this.handle(v));
  this.destroyRef.onDestroy(() => sub.unsubscribe());
}
```

---

## `takeUntilDestroyed()`

**Import:** `@angular/core/rxjs-interop`
**Since:** Angular 16

RxJS operator that completes an observable when the injection context is destroyed.

```typescript
function takeUntilDestroyed(destroyRef?: DestroyRef): MonoTypeOperatorFunction<T>;
```

```typescript
// In injection context (field/constructor):
data$ = source$.pipe(takeUntilDestroyed());

// Outside injection context:
ngOnInit() {
  source$.pipe(takeUntilDestroyed(this.destroyRef)).subscribe();
}
```

---

## `outputToObservable()`

**Import:** `@angular/core/rxjs-interop`
**Since:** Angular 17.3

Converts a component output to an RxJS Observable.

```typescript
function outputToObservable<T>(ref: OutputRef<T>): Observable<T>;
```

```typescript
const saved$ = outputToObservable(this.childRef.saved);
saved$.pipe(takeUntilDestroyed(this.destroyRef)).subscribe(item => handle(item));
```

---

## `outputFromObservable()`

**Import:** `@angular/core/rxjs-interop`
**Since:** Angular 17.3

Creates a component output from an RxJS Observable.

```typescript
function outputFromObservable<T>(obs: Observable<T>): OutputEmitterRef<T>;
```

```typescript
tick = outputFromObservable(interval(1000));
// Parent: <child (tick)="onTick($event)" />
```
