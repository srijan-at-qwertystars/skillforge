# Angular Signals — Advanced Patterns

## Table of Contents

- [Custom Signal Utilities](#custom-signal-utilities)
- [Signal-Based State Management](#signal-based-state-management)
- [Fine-Grained Reactivity](#fine-grained-reactivity)
- [Nested Signals](#nested-signals)
- [Signal Equality Functions](#signal-equality-functions)
- [RxJS ↔ Signal Interop Deep Dive](#rxjs--signal-interop-deep-dive)
- [Zoneless Architecture](#zoneless-architecture)
- [Performance Optimization](#performance-optimization)

---

## Custom Signal Utilities

### Toggle Signal

```typescript
import { signal, WritableSignal } from '@angular/core';

function toggleSignal(initial = false): WritableSignal<boolean> & { toggle: () => void } {
  const s = signal(initial) as WritableSignal<boolean> & { toggle: () => void };
  s.toggle = () => s.update(v => !v);
  return s;
}

// Usage
const isOpen = toggleSignal();
isOpen.toggle(); // true
isOpen.toggle(); // false
```

### History Signal (Undo/Redo)

```typescript
import { signal, computed, WritableSignal, Signal } from '@angular/core';

interface HistorySignal<T> {
  value: WritableSignal<T>;
  undo: () => void;
  redo: () => void;
  canUndo: Signal<boolean>;
  canRedo: Signal<boolean>;
}

function historySignal<T>(initial: T, maxHistory = 50): HistorySignal<T> {
  const past = signal<T[]>([]);
  const future = signal<T[]>([]);
  const current = signal(initial);

  return {
    value: {
      ...current,
      set(val: T) {
        past.update(p => [...p.slice(-maxHistory), current()]);
        future.set([]);
        current.set(val);
      },
      update(fn: (v: T) => T) {
        this.set(fn(current()));
      },
    } as WritableSignal<T>,
    undo() {
      const p = past();
      if (!p.length) return;
      future.update(f => [current(), ...f]);
      current.set(p[p.length - 1]);
      past.update(p => p.slice(0, -1));
    },
    redo() {
      const f = future();
      if (!f.length) return;
      past.update(p => [...p, current()]);
      current.set(f[0]);
      future.update(f => f.slice(1));
    },
    canUndo: computed(() => past().length > 0),
    canRedo: computed(() => future().length > 0),
  };
}
```

### Debounced Signal

```typescript
import { signal, effect, Signal, Injector, runInInjectionContext } from '@angular/core';

function debouncedSignal<T>(source: Signal<T>, delayMs: number, injector: Injector): Signal<T> {
  const debounced = signal(source());
  runInInjectionContext(injector, () => {
    effect((onCleanup) => {
      const val = source();
      const timer = setTimeout(() => debounced.set(val), delayMs);
      onCleanup(() => clearTimeout(timer));
    });
  });
  return debounced.asReadonly();
}
```

### Array Signal Helpers

```typescript
function arraySignal<T>(initial: T[] = []) {
  const s = signal<T[]>(initial);
  return Object.assign(s, {
    push: (item: T) => s.update(a => [...a, item]),
    remove: (pred: (item: T) => boolean) => s.update(a => a.filter(i => !pred(i))),
    clear: () => s.set([]),
    updateItem: (pred: (i: T) => boolean, fn: (i: T) => T) =>
      s.update(a => a.map(i => pred(i) ? fn(i) : i)),
  });
}
```

---

## Signal-Based State Management

### Service-Level Signal Store (No Library)

```typescript
import { Injectable, signal, computed } from '@angular/core';

interface AppState {
  user: User | null;
  theme: 'light' | 'dark';
  notifications: Notification[];
}

@Injectable({ providedIn: 'root' })
export class AppStore {
  // Private writable state
  private readonly _user = signal<User | null>(null);
  private readonly _theme = signal<'light' | 'dark'>('light');
  private readonly _notifications = signal<Notification[]>([]);

  // Public readonly signals
  readonly user = this._user.asReadonly();
  readonly theme = this._theme.asReadonly();
  readonly notifications = this._notifications.asReadonly();

  // Derived state
  readonly isLoggedIn = computed(() => this._user() !== null);
  readonly unreadCount = computed(() =>
    this._notifications().filter(n => !n.read).length
  );
  readonly displayName = computed(() => this._user()?.name ?? 'Guest');

  // Actions
  login(user: User) { this._user.set(user); }
  logout() { this._user.set(null); this._notifications.set([]); }
  toggleTheme() { this._theme.update(t => t === 'light' ? 'dark' : 'light'); }
  addNotification(n: Notification) { this._notifications.update(ns => [n, ...ns]); }
  markRead(id: string) {
    this._notifications.update(ns =>
      ns.map(n => n.id === id ? { ...n, read: true } : n)
    );
  }
}
```

### Slice Pattern — Composable State Slices

```typescript
function createSlice<T extends object>(initial: T) {
  const state = signal(initial);
  return {
    select: <K extends keyof T>(key: K) => computed(() => state()[key]),
    patch: (partial: Partial<T>) => state.update(s => ({ ...s, ...partial })),
    reset: () => state.set(initial),
    snapshot: () => state(),
  };
}

// Usage
const uiSlice = createSlice({ sidebarOpen: true, modal: null as string | null });
const sidebarOpen = uiSlice.select('sidebarOpen'); // Signal<boolean>
uiSlice.patch({ sidebarOpen: false });
```

---

## Fine-Grained Reactivity

### How Signal Dependency Tracking Works

Signals use a **producer-consumer** graph. When a `computed()` or `effect()` executes:
1. Angular records every signal read (producer) during execution
2. On re-run, old dependencies are dropped, new ones are tracked (dynamic deps)
3. Only direct consumers are notified — no component tree walks

### Granular Updates in Templates

```typescript
@Component({
  template: `
    <!-- Only this text node updates when firstName changes -->
    <span>{{ firstName() }}</span>
    <!-- Independent — does NOT re-evaluate when firstName changes -->
    <span>{{ itemCount() }}</span>
  `,
})
export class ProfileComponent {
  firstName = input.required<string>();
  items = signal<Item[]>([]);
  itemCount = computed(() => this.items().length);
}
```

### Avoid Over-Wrapping — Keep Signals Flat

```typescript
// BAD: signal wrapping a signal
const inner = signal(0);
const outer = signal(inner); // Signal<WritableSignal<number>> — confusing

// GOOD: use computed for derivation
const base = signal(0);
const derived = computed(() => base() * 2);
```

---

## Nested Signals

### When to Use Nested Signals

Nested signals (signals containing other signals) are rare but useful for **independent update granularity**:

```typescript
interface FormField<T> {
  value: WritableSignal<T>;
  dirty: WritableSignal<boolean>;
  errors: Signal<string[]>;
}

function createField<T>(initial: T, validators: ((v: T) => string | null)[]): FormField<T> {
  const value = signal(initial);
  const dirty = signal(false);
  const errors = computed(() => validators.map(v => v(value())).filter(Boolean) as string[]);
  return { value, dirty, errors };
}

// Each field updates independently
const nameField = createField('', [v => v.length < 2 ? 'Too short' : null]);
const emailField = createField('', [v => v.includes('@') ? null : 'Invalid email']);

// Aggregate validity — only recalculates when relevant field errors change
const isFormValid = computed(() =>
  nameField.errors().length === 0 && emailField.errors().length === 0
);
```

---

## Signal Equality Functions

### Default: `Object.is` (Strict Reference Equality)

```typescript
const obj = signal({ x: 1 });
obj.set({ x: 1 }); // DOES notify — different reference
```

### Custom Equality — Shallow Object Comparison

```typescript
function shallowEqual<T extends object>(a: T, b: T): boolean {
  const keysA = Object.keys(a) as (keyof T)[];
  const keysB = Object.keys(b) as (keyof T)[];
  if (keysA.length !== keysB.length) return false;
  return keysA.every(k => Object.is(a[k], b[k]));
}

const config = signal({ page: 1, size: 10 }, { equal: shallowEqual });
config.set({ page: 1, size: 10 }); // NO notification — shallow equal
```

### Custom Equality — Array by ID

```typescript
const items = signal<Item[]>([], {
  equal: (a, b) =>
    a.length === b.length && a.every((item, i) => item.id === b[i].id),
});
```

### Computed Equality

```typescript
const stats = computed(() => ({
  total: items().length,
  active: items().filter(i => i.active).length,
}), { equal: (a, b) => a.total === b.total && a.active === b.active });
```

---

## RxJS ↔ Signal Interop Deep Dive

### toSignal() — Full Options

```typescript
import { toSignal } from '@angular/core/rxjs-interop';

// 1. Basic — value is T | undefined
const data = toSignal(data$);

// 2. With initial value — value is T (no undefined)
const data = toSignal(data$, { initialValue: [] });

// 3. requireSync — source MUST emit synchronously (BehaviorSubject, startWith)
const data = toSignal(data$, { requireSync: true });

// 4. manualCleanup — don't auto-unsubscribe on DestroyRef
const data = toSignal(data$, { manualCleanup: true });

// 5. rejectErrors — errors set signal to undefined instead of throwing
const data = toSignal(data$, { rejectErrors: true });
```

### toObservable() — Behavior Details

```typescript
import { toObservable } from '@angular/core/rxjs-interop';

const count = signal(0);
const count$ = toObservable(count);
// Emits asynchronously (via microtask) — NOT synchronous
// Deduplicates via signal equality — won't re-emit if value is "equal"
```

### Advanced Interop Patterns

```typescript
// Pattern: Debounced search with RxJS operators + signal result
@Injectable({ providedIn: 'root' })
export class SearchService {
  private query = signal('');
  private destroyRef = inject(DestroyRef);

  results = toSignal(
    toObservable(this.query).pipe(
      debounceTime(300),
      distinctUntilChanged(),
      switchMap(q => q ? this.http.get<Result[]>(`/api/search?q=${q}`) : of([])),
    ),
    { initialValue: [] }
  );

  search(q: string) { this.query.set(q); }
}
```

```typescript
// Pattern: Combining signals with observables for complex async flows
const userId = signal<number>(1);
const userPosts$ = toObservable(userId).pipe(
  switchMap(id => this.http.get<Post[]>(`/api/users/${id}/posts`)),
  catchError(() => of([])),
);
const posts = toSignal(userPosts$, { initialValue: [] });
```

### outputFromObservable / outputToObservable

```typescript
import { outputFromObservable, outputToObservable } from '@angular/core/rxjs-interop';

// Create output from an observable stream
tick = outputFromObservable(interval(1000)); // OutputRef<number>

// Convert a child's output to an observable
ngAfterViewInit() {
  const saved$ = outputToObservable(this.childRef.saved);
  saved$.pipe(takeUntilDestroyed(this.destroyRef)).subscribe(item => { ... });
}
```

### takeUntilDestroyed — Lifecycle-Aware Unsubscribe

```typescript
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';

// In injection context (constructor / field initializer):
data$ = source$.pipe(takeUntilDestroyed());

// Outside injection context — pass DestroyRef explicitly:
ngOnInit() {
  source$.pipe(takeUntilDestroyed(this.destroyRef)).subscribe();
}
```

---

## Zoneless Architecture

### Full Zoneless Setup

```typescript
// app.config.ts
import { provideExperimentalZonelessChangeDetection } from '@angular/core';

export const appConfig: ApplicationConfig = {
  providers: [
    provideExperimentalZonelessChangeDetection(),
    provideRouter(routes),
    provideHttpClient(),
  ],
};

// angular.json — remove zone.js polyfill
// "polyfills": []   ← remove "zone.js" entry
```

### What Triggers Change Detection in Zoneless Mode

| Trigger | Works? | Notes |
|---------|--------|-------|
| Signal update read in template | ✅ | Primary mechanism |
| `input()` binding changes | ✅ | Signal-based inputs auto-notify |
| Template event handlers `(click)` | ✅ | Triggers CD after handler |
| `async` pipe | ✅ | Calls `markForCheck()` internally |
| `setTimeout` / `setInterval` | ❌ | Must update a signal to trigger CD |
| `fetch()` / `XMLHttpRequest` | ❌ | Must update a signal on completion |
| Third-party DOM events | ❌ | Use `NgZone.run()` or update signal |
| `markForCheck()` | ✅ | Still works as escape hatch |

### Zoneless-Compatible Async Pattern

```typescript
@Component({ ... })
export class DataComponent {
  data = signal<Item[]>([]);
  loading = signal(false);

  async loadData() {
    this.loading.set(true);
    try {
      const res = await fetch('/api/items');
      this.data.set(await res.json()); // triggers CD
    } finally {
      this.loading.set(false); // triggers CD
    }
  }
}
```

### Hybrid Migration (Keep Zone.js, Add Signals)

```typescript
// Step 1: Add OnPush + signals to individual components
@Component({
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `{{ count() }}`,
})
export class CounterCmp {
  count = signal(0);
}

// Step 2: Convert services from BehaviorSubject to signal
// Step 3: Convert inputs/outputs/queries to signal versions
// Step 4: Remove zone.js when all components are signal-based
```

---

## Performance Optimization

### Signal Read Coalescing

Multiple signal updates before a CD cycle are coalesced — only the final value triggers re-render:

```typescript
const a = signal(1);
const b = signal(2);
const sum = computed(() => a() + b());

// Both updates happen before next CD cycle — sum recalculates once
a.set(10);
b.set(20);
// sum() → 30 (single recalculation)
```

### Avoid Expensive Computations in computed()

```typescript
// BAD: Recomputes full sort on every signal read
const sorted = computed(() => [...items()].sort(expensiveComparator));

// GOOD: Cache or memoize the expensive operation
const sorted = computed(() => {
  const list = items();
  return list.length > 1000
    ? memoizedSort(list, expensiveComparator)
    : [...list].sort(expensiveComparator);
}, { equal: (a, b) => a.length === b.length && a.every((v, i) => v === b[i]) });
```

### Lazy Initialization with computed()

`computed()` is lazy — it won't execute until first read. Use this to defer expensive setup:

```typescript
// This derivation won't run until first template read
readonly chartData = computed(() => transformForChart(this.rawData()));
```

### untracked() for Performance

```typescript
effect(() => {
  const name = this.name();            // tracked — re-runs on name change
  const config = untracked(this.config); // NOT tracked — avoids unnecessary re-runs
  saveToStorage(name, config());
});
```

### OnPush + Signals = Optimal Default

Always pair `ChangeDetectionStrategy.OnPush` with signals. This skips the component in the CD tree unless a signal it reads has changed. In zoneless mode, `OnPush` is the default behavior for all components.
