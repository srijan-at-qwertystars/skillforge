---
name: angular-signals
description: >
  Guide for Angular Signals reactive primitives (Angular 17+). Covers signal(), computed(), effect(),
  input()/input.required(), output(), model(), viewChild/viewChildren/contentChild/contentChildren
  signal queries, linkedSignal(), resource()/httpResource(), toSignal(), toObservable(), rxjs-interop,
  zoneless change detection, OnPush + signals, untracked(), DestroyRef, NgRx SignalStore patterns,
  and migration from @Input/@Output/@ViewChild decorators to signal functions.
  Triggers: "Angular signals", "signal()", "computed signal", "effect()", "zoneless Angular",
  "input signal", "model signal", "linkedSignal", "Angular resource API", "NgRx SignalStore",
  "signal-based component", "toSignal", "toObservable", "Angular rxjs-interop".
  NOT for AngularJS (1.x). NOT for React/Vue/Solid signals. NOT for RxJS-only patterns without
  signal interop. NOT for Angular Material or CDK unless signal-specific.
---

# Angular Signals

## Core Primitives

### signal() — Writable Reactive State

Create a writable signal. Read by calling as function. Write with `set()` or `update()`.

```typescript
import { signal } from '@angular/core';

const count = signal(0);          // WritableSignal<number>
count();                          // read: 0
count.set(5);                     // write absolute
count.update(v => v + 1);        // write relative: 6
```

Provide a custom equality function to skip unnecessary updates:

```typescript
const user = signal({ name: 'Ada' }, { equal: (a, b) => a.name === b.name });
```

### computed() — Derived Read-Only Signal

Lazily evaluated and memoized. Automatically tracks dependencies.

```typescript
import { computed } from '@angular/core';

const count = signal(3);
const doubled = computed(() => count() * 2);  // Signal<number>, read-only
doubled(); // 6
```

Never write to signals inside `computed()`. Never call async code inside `computed()`.

### effect() — Side Effects on Signal Changes

Runs in an injection context. Auto-tracks signal reads. Re-runs when dependencies change.

```typescript
import { effect } from '@angular/core';

effect(() => {
  console.log(`Count is now: ${count()}`);
});
```

Use `effect` for: logging, localStorage sync, DOM manipulation, analytics events.
Do NOT use `effect` to set other signals — use `computed()` or `linkedSignal()` instead.

Cleanup callback pattern:

```typescript
effect((onCleanup) => {
  const id = setInterval(() => tick(), 1000);
  onCleanup(() => clearInterval(id));
});
```

---

## Component Signal APIs

### input() / input.required() — Signal Inputs

Replace `@Input()` decorator. Return `InputSignal<T>` (read-only signal).

```typescript
// BEFORE (decorator):
@Input() name: string = '';
@Input({ required: true }) id!: number;

// AFTER (signal):
import { input } from '@angular/core';

name = input('');                  // InputSignal<string>, default ''
id = input.required<number>();     // InputSignal<number>, required
aliased = input('', { alias: 'userName' }); // bind as [userName]
```

Template binding unchanged: `<child [name]="parentValue" [id]="parentId" />`.
Access in component via `this.name()`, `this.id()`.

### output() — Signal Outputs

Replace `@Output()` + `EventEmitter`. Return `OutputEmitterRef<T>`.

```typescript
// BEFORE:
@Output() saved = new EventEmitter<Item>();

// AFTER:
import { output } from '@angular/core';

saved = output<Item>();            // OutputEmitterRef<Item>
// emit:
this.saved.emit(item);
```

Template binding unchanged: `<child (saved)="onSave($event)" />`.

### model() — Two-Way Binding Signal

Writable signal for two-way `[(ngModel)]`-style bindings between parent and child.

```typescript
import { model } from '@angular/core';

// Child component:
value = model(0);                  // ModelSignal<number>
value = model.required<string>();  // required variant

// Read: this.value()
// Write: this.value.set(42)  — emits to parent automatically
```

Parent template: `<child [(value)]="parentSignal" />`.

---

## Signal Queries (View/Content Children)

Replace `@ViewChild`, `@ViewChildren`, `@ContentChild`, `@ContentChildren` decorators.

```typescript
import { viewChild, viewChildren, contentChild, contentChildren } from '@angular/core';

// Single child (returns Signal<T | undefined>):
header = viewChild(HeaderComponent);
headerRef = viewChild('headerRef');              // template ref
headerReq = viewChild.required(HeaderComponent); // Signal<T>, throws if missing

// Multiple children (returns Signal<readonly T[]>):
items = viewChildren(ItemComponent);

// Content projection queries:
toggle = contentChild(ToggleComponent);
toggles = contentChildren(ToggleComponent);
```

Use in `computed()` or `effect()` — no need for `ngAfterViewInit`:

```typescript
itemCount = computed(() => this.items().length);
```

---

## linkedSignal() — Writable Computed Signal

A computed signal you can also write to. Resets when source signals change. Available Angular 19+.

```typescript
import { linkedSignal } from '@angular/core';

// Shorthand — resets to derived value when source changes:
const items = signal(['a', 'b', 'c']);
const count = linkedSignal(() => items().length);
count();        // 3
count.set(99);  // locally override
items.set([]);  // count resets to 0

// Object form with previous value access:
const selectedId = signal(1);
const editName = linkedSignal({
  source: selectedId,
  computation: (id, previous) => {
    // Reset to empty string on source change
    return '';
  },
});
```

Use linkedSignal when local editable state must reset on upstream changes (forms, detail views).

---

## resource() / httpResource() — Async Data Loading

Signal-based async data fetching. Auto-reloads when param signals change. Angular 19+.

### resource()

```typescript
import { resource, signal } from '@angular/core';

const userId = signal(1);
const userRes = resource({
  params: () => ({ id: userId() }),
  loader: async ({ params }) => {
    const res = await fetch(`/api/users/${params.id}`);
    return res.json();
  },
});

// Template usage:
// userRes.value() — data | undefined,  userRes.isLoading() — boolean
// userRes.error() — error | undefined, userRes.status() — ResourceStatus
```

### httpResource()

Built on `HttpClient`. Respects interceptors. Angular 19.2+.

```typescript
import { httpResource } from '@angular/common/http';

const id = signal(1);
const todoRes = httpResource<Todo>(() => `/api/todos/${id()}`);

// Advanced with options:
const usersRes = httpResource<User[]>(() => ({
  url: '/api/users',
  params: { sort: sortField() },
  headers: { 'X-Custom': headerVal() },
}));
```

---

## RxJS Interop

Import from `@angular/core/rxjs-interop`.

### toSignal() — Observable → Signal

```typescript
import { toSignal } from '@angular/core/rxjs-interop';

// Requires injection context (constructor or field initializer)
const route$ = this.route.params;
const params = toSignal(route$);               // Signal<Params | undefined>
const params2 = toSignal(route$, { initialValue: {} }); // Signal<Params>
const params3 = toSignal(route$, { requireSync: true }); // BehaviorSubject-like
```

### toObservable() — Signal → Observable

```typescript
import { toObservable } from '@angular/core/rxjs-interop';

const count = signal(0);
const count$ = toObservable(count);  // Observable<number>
count$.pipe(debounceTime(300)).subscribe(v => console.log(v));
```

### outputToObservable() / outputFromObservable()

Bridge between signal outputs and RxJS:

```typescript
import { outputToObservable, outputFromObservable } from '@angular/core/rxjs-interop';

// Output → Observable
const saved$ = outputToObservable(this.childRef.saved);

// Observable → Output (in component class)
tick = outputFromObservable(interval(1000));
```

---

## Zoneless Change Detection

Remove Zone.js entirely. Angular 18+.

### Setup

```typescript
// app.config.ts
import { provideExperimentalZonelessChangeDetection } from '@angular/core';

export const appConfig: ApplicationConfig = {
  providers: [
    provideExperimentalZonelessChangeDetection(),
  ],
};
```

Remove `zone.js` from `angular.json` polyfills. Change detection triggers in zoneless:
- Signal updates read in templates
- Component input changes via `setInput()`
- Template/host event listeners
- `markForCheck()` calls
- Async pipe subscriptions

Async operations (setTimeout, fetch) do NOT trigger CD. Use signals to propagate async state.

### OnPush + Signals

`OnPush` + signals is the recommended default even with Zone.js:

```typescript
@Component({
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `<span>{{ count() }}</span>`,
})
export class CounterComponent {
  count = signal(0);
  increment() { this.count.update(v => v + 1); } // triggers CD automatically
}
```

---

## Utilities

### untracked() — Read Without Subscribing

Read a signal's value inside `computed()` or `effect()` without creating a dependency.

```typescript
import { untracked } from '@angular/core';

effect(() => {
  const name = this.name();              // tracked — re-runs on change
  const id = untracked(() => this.id()); // NOT tracked — read once
  console.log(`${name} has id ${id}`);
});
```

### DestroyRef — Lifecycle Cleanup

Register cleanup callbacks. Inject via `inject(DestroyRef)`.
```typescript
import { DestroyRef, inject } from '@angular/core';

export class MyComponent {
  private destroyRef = inject(DestroyRef);

  ngOnInit() {
    const sub = someObservable$.subscribe();
    this.destroyRef.onDestroy(() => sub.unsubscribe());
  }
}
```

Pair with `takeUntilDestroyed()` from rxjs-interop:

```typescript
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';

// In injection context (constructor/field initializer):
obs$ = source$.pipe(takeUntilDestroyed());

// Outside injection context — pass DestroyRef:
source$.pipe(takeUntilDestroyed(this.destroyRef)).subscribe();
```

---

## NgRx SignalStore

Functional, signal-based state management. Install: `npm i @ngrx/signals`.

### Basic Store

```typescript
import { signalStore, withState, withComputed, withMethods, patchState } from '@ngrx/signals';
import { computed } from '@angular/core';

type Todo = { id: string; title: string; done: boolean };

export const TodoStore = signalStore(
  { providedIn: 'root' },
  withState({
    todos: [] as Todo[],
    loading: false,
    filter: 'all' as 'all' | 'active' | 'done',
  }),
  withComputed(({ todos, filter }) => ({
    filteredTodos: computed(() => {
      const f = filter();
      return f === 'all' ? todos() : todos().filter(t => t.done === (f === 'done'));
    }),
    doneCount: computed(() => todos().filter(t => t.done).length),
  })),
  withMethods((store) => ({
    addTodo(title: string) {
      patchState(store, { todos: [...store.todos(), { id: crypto.randomUUID(), title, done: false }] });
    },
    toggleTodo(id: string) {
      patchState(store, { todos: store.todos().map(t => t.id === id ? { ...t, done: !t.done } : t) });
    },
    setFilter(filter: 'all' | 'active' | 'done') {
      patchState(store, { filter });
    },
    setLoading(loading: boolean) {
      patchState(store, { loading });
    },
  })),
);
```

### Using in Components

```typescript
@Component({
  providers: [TodoStore], // or use providedIn: 'root' for global
  template: `
    @for (todo of store.filteredTodos(); track todo.id) {
      <div (click)="store.toggleTodo(todo.id)">{{ todo.title }}</div>
    }
  `,
})
export class TodoListComponent {
  readonly store = inject(TodoStore);
}
```

### Store Features

- `withEntities<T>()` — entity collection management
- `withHooks({ onInit, onDestroy })` — lifecycle hooks
- `rxMethod()` — bridge RxJS streams into store methods
- `signalStoreFeature()` — reusable, composable store features

---

## Migration Cheat Sheet

| Decorator Pattern | Signal Equivalent | Notes |
|---|---|---|
| `@Input() x: T` | `x = input<T>()` | Read via `x()` |
| `@Input({ required: true }) x!: T` | `x = input.required<T>()` | Required, no default |
| `@Output() e = new EventEmitter<T>()` | `e = output<T>()` | Emit via `e.emit(val)` |
| `@ViewChild(Comp) c!: Comp` | `c = viewChild(Comp)` | Signal, no lifecycle hook needed |
| `@ViewChildren(Comp) c!: QueryList<Comp>` | `c = viewChildren(Comp)` | `Signal<readonly Comp[]>` |
| `@ContentChild(Comp) c!: Comp` | `c = contentChild(Comp)` | Signal-based |
| `@ContentChildren(Comp) c!: QueryList<Comp>` | `c = contentChildren(Comp)` | Signal-based |
| `ngOnChanges` + `@Input` | `computed()` / `effect()` on `input()` | Reactive derivation |
| `BehaviorSubject` for state | `signal()` | Simpler, synchronous |
| `combineLatest` for derived | `computed()` | Auto-tracked |
| Manual subscribe + unsubscribe | `toSignal()` + `DestroyRef` | Auto-cleanup |

### Migration Schematics

```bash
ng generate @angular/core:signal-input-migration    # @Input → input()
ng generate @angular/core:signal-queries-migration   # @ViewChild → viewChild()
ng generate @angular/core:output-migration           # @Output → output()
```

---

## Anti-Patterns

- Do NOT set signals inside `computed()` — use `linkedSignal()` instead
- Do NOT use `effect()` to sync two signals — use `computed()` or `linkedSignal()`
- Do NOT mutate signal object values in-place — produce new references
- Do NOT wrap every Observable in `toSignal()` — keep RxJS for complex async streams
- Do NOT nest `effect()` inside `effect()` — flatten or restructure
- Do NOT call `effect()` outside injection context without providing `Injector`

## Example: Full Signal-Based Component

```typescript
@Component({
  selector: 'app-user-card',
  standalone: true,
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <h2>{{ fullName() }}</h2>
    <p>Posts: {{ postCount() }}</p>
    <button (click)="posts.reload()">Reload</button>
    @if (posts.isLoading()) { <spinner /> }
    @for (post of posts.value() ?? []; track post.id) {
      <article>{{ post.title }}</article>
    }
  `,
})
export class UserCardComponent {
  userId = input.required<number>();
  fullName = input('');
  selected = output<number>();
  posts = resource({
    params: () => ({ uid: this.userId() }),
    loader: async ({ params }) => (await fetch(`/api/users/${params.uid}/posts`)).json() as Promise<Post[]>,
  });
  postCount = computed(() => this.posts.value()?.length ?? 0);
}
```
