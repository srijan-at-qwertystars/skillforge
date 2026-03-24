# SolidJS API Reference

## Table of Contents
- [Reactive Primitives](#reactive-primitives)
- [Reactive Utilities](#reactive-utilities)
- [Stores](#stores)
- [Component APIs](#component-apis)
- [Control Flow Components](#control-flow-components)
- [Lifecycle](#lifecycle)
- [Rendering](#rendering)
- [Transitions](#transitions)

---

## Reactive Primitives

### createSignal

```tsx
function createSignal<T>(
  initialValue: T,
  options?: { equals?: false | ((prev: T, next: T) => boolean); name?: string }
): [Accessor<T>, Setter<T>];
```

| Parameter | Description |
|-----------|-------------|
| `initialValue` | Starting value |
| `options.equals` | Custom equality fn. `false` = always update |
| Returns `[getter, setter]` | `getter()` reads, `setter(val)` or `setter(prev => next)` writes |

```tsx
const [count, setCount] = createSignal(0);
setCount(5);                    // direct value
setCount(prev => prev + 1);    // functional update
const [obj, setObj] = createSignal({a: 1}, { equals: false }); // always notify
```

### createEffect

```tsx
function createEffect<T>(fn: (prev: T) => T, initialValue?: T): void;
```

Auto-tracks signals read inside `fn`. Runs after render, re-runs when dependencies change. Returns nothing. **Not for derived values** — use `createMemo` for that.

```tsx
createEffect(() => console.log(count()));
createEffect((prev) => {
  console.log("prev:", prev, "next:", count());
  return count();
}, 0);
```

### createMemo

```tsx
function createMemo<T>(
  fn: (prev: T) => T,
  initialValue?: T,
  options?: { equals?: false | ((prev: T, next: T) => boolean) }
): Accessor<T>;
```

Cached derived value. Only recalculates when tracked dependencies change. Read with `()`.

```tsx
const doubled = createMemo(() => count() * 2);
const filtered = createMemo(() => items().filter(i => i.active));
```

### createResource

```tsx
function createResource<T, U>(
  source: Accessor<U> | false | null | undefined,
  fetcher: (source: U, info: { value: T | undefined; refetching: boolean | unknown }) => T | Promise<T>,
  options?: { initialValue?: T; name?: string; storage?: (init: T) => [Accessor<T>, Setter<T>] }
): [Resource<T>, { mutate: Setter<T>; refetch: (info?: unknown) => void }];
```

| Property | Type | Description |
|----------|------|-------------|
| `resource()` | `T \| undefined` | Current data |
| `resource.loading` | `boolean` | True while fetching |
| `resource.error` | `unknown` | Error if rejected |
| `resource.state` | `"unresolved" \| "pending" \| "ready" \| "refreshing" \| "errored"` | Current state |
| `resource.latest` | `T \| undefined` | Last successful value (persists during refetch) |
| `mutate(val)` | | Directly set data without fetching |
| `refetch(info?)` | | Re-trigger the fetcher |

```tsx
const [user, { mutate, refetch }] = createResource(userId, fetchUser);
// Without source signal:
const [data] = createResource(fetchAllUsers);
```

---

## Reactive Utilities

### batch

```tsx
function batch<T>(fn: () => T): T;
```

Defers downstream updates until `fn` completes. Useful when updating multiple independent signals.

### untrack

```tsx
function untrack<T>(fn: () => T): T;
```

Reads signals inside `fn` without creating dependencies.

### on

```tsx
function on<T, U>(
  deps: Accessor<T> | Accessor<T>[],
  fn: (value: T, prev: T, prevReturn?: U) => U,
  options?: { defer?: boolean }
): (prev?: U) => U;
```

Explicit dependency declaration for effects. `defer: true` skips first run.

```tsx
createEffect(on(count, (val, prev) => console.log(prev, "→", val)));
createEffect(on([a, b], ([aVal, bVal]) => {}));
```

### createRoot

```tsx
function createRoot<T>(fn: (dispose: () => void) => T): T;
```

Creates a new reactive scope. Call `dispose` to clean up all effects/computations inside.

### createRenderEffect

Like `createEffect` but runs during render (before DOM insertion). Used for reading DOM layout.

---

## Stores

Import from `"solid-js/store"`.

### createStore

```tsx
function createStore<T extends object>(
  initialValue: T
): [Store<T>, SetStoreFunction<T>];
```

**setState path syntax patterns:**
```tsx
const [state, setState] = createStore({ list: [{ id: 1, name: "A" }] });

setState("list", 0, "name", "B");                         // by index + key
setState("list", { from: 0, to: 4 }, "name", "X");       // range
setState("list", (item) => item.id === 1, "name", "C");   // filter predicate
setState("list", [0, 2], "name", "D");                    // multiple indices
setState(key, val);                                        // top-level key
setState(prev => ({ ...prev, key: val }));                 // functional update
```

### produce

```tsx
function produce<T>(fn: (draft: T) => void): (state: T) => T;
```

Immer-like mutable API for store updates.

```tsx
setState(produce((draft) => {
  draft.list.push({ id: 2, name: "New" });
  draft.list[0].name = "Updated";
  draft.list.splice(1, 1); // removes index 1
}));
```

### reconcile

```tsx
function reconcile<T>(
  value: T,
  options?: { key?: string | null; merge?: boolean }
): (state: T) => T;
```

Diffs external data against the store and applies minimal updates. Use `key` for array identity.

```tsx
setState("users", reconcile(serverUsers, { key: "id" }));
```

### unwrap

```tsx
function unwrap<T>(store: T): T;
```

Returns the underlying plain object (non-reactive). Useful for serialization.

---

## Component APIs

### mergeProps

```tsx
function mergeProps<T extends object[]>(...sources: T): MergeProps<T>;
```

Merges prop objects reactively. Later sources override earlier ones.

```tsx
const merged = mergeProps({ variant: "primary", size: "md" }, props);
```

### splitProps

```tsx
function splitProps<T, K extends (keyof T)[]>(
  props: T,
  ...keys: K[]
): [...SplitProps<T, K>];
```

Splits props into groups without breaking reactivity.

```tsx
const [local, inputProps] = splitProps(props, ["label", "error"]);
const [a, b, rest] = splitProps(props, ["x"], ["y"]); // multiple groups
```

### children

```tsx
function children(fn: () => JSX.Element): ResolvedChildren;
```

Resolves and memoizes `props.children` for manipulation.

```tsx
const resolved = children(() => props.children);
resolved.toArray(); // flat array of DOM nodes
resolved();         // resolved JSX
```

### createContext / useContext

```tsx
function createContext<T>(defaultValue?: T): Context<T>;
function useContext<T>(context: Context<T>): T;
```

```tsx
const MyCtx = createContext<{ count: Accessor<number> }>();

// Provider
<MyCtx.Provider value={{ count }}>...</MyCtx.Provider>

// Consumer
const ctx = useContext(MyCtx); // ctx.count()
```

---

## Control Flow Components

### Show

```tsx
<Show when={condition()} fallback={<Fallback />}>
  {(item) => <Content data={item()} />}
</Show>
```

Renders children when `when` is truthy. Callback form narrows type and receives accessor.

### For

```tsx
<For each={list()} fallback={<Empty />}>
  {(item, index) => <div>{index()}: {item.name}</div>}
</For>
```

Keyed iteration. `item` is the value, `index` is an accessor. Items may reorder without recreation.

### Index

```tsx
<Index each={list()} fallback={<Empty />}>
  {(item, index) => <div>{index}: {item().name}</div>}
</Index>
```

Non-keyed iteration. `item` is an accessor, `index` is a number. Items are fixed, values update.

### Switch / Match

```tsx
<Switch fallback={<Default />}>
  <Match when={cond1()}><A /></Match>
  <Match when={cond2()}>{(val) => <B data={val()} />}</Match>
</Switch>
```

### Suspense

```tsx
<Suspense fallback={<Loading />}>
  <AsyncChild />
</Suspense>
```

Shows fallback while any child `createResource` or `lazy` component is loading.

### ErrorBoundary

```tsx
<ErrorBoundary fallback={(err, reset) => (
  <div>
    <p>{err.message}</p>
    <button onClick={reset}>Retry</button>
  </div>
)}>
  <MayFail />
</ErrorBoundary>
```

### Portal

```tsx
import { Portal } from "solid-js/web";
<Portal mount={document.body}>
  <Modal />
</Portal>
```

Renders children into a different DOM node. Default mount is `document.body`.

### Dynamic

```tsx
import { Dynamic } from "solid-js/web";
<Dynamic component={MyComponent} someProp="value" />
<Dynamic component="div" class="wrapper">Content</Dynamic>
```

Renders a component or HTML tag dynamically from a variable.

---

## Lifecycle

### onMount

```tsx
function onMount(fn: () => void): void;
```

Runs once after initial render. Equivalent to `createEffect` that only runs once. Non-tracking.

### onCleanup

```tsx
function onCleanup(fn: () => void): void;
```

Registers cleanup for the current reactive scope. Runs when the scope is re-evaluated or disposed.

```tsx
createEffect(() => {
  const id = setInterval(() => tick(), 1000);
  onCleanup(() => clearInterval(id)); // cleans up on re-run and dispose
});
```

### onError

```tsx
function onError(fn: (err: unknown) => void): void;
```

Catches errors in child scopes (similar to ErrorBoundary but programmatic).

---

## Rendering

### render

```tsx
import { render } from "solid-js/web";
const dispose = render(() => <App />, document.getElementById("root")!);
// dispose() to unmount
```

### hydrate

```tsx
import { hydrate } from "solid-js/web";
hydrate(() => <App />, document.getElementById("root")!);
```

### isServer

```tsx
import { isServer } from "solid-js/web";
if (!isServer) { /* browser-only code */ }
```

### lazy

```tsx
const Component = lazy(() => import("./Component"));
// Use with <Suspense> for loading state
```

Code-splits a component. Returns a component that loads on first render.

---

## Transitions

### startTransition

```tsx
function startTransition(fn: () => void): Promise<void>;
```

Marks state updates as non-urgent. UI remains responsive during expensive updates.

### useTransition

```tsx
function useTransition(): [pending: Accessor<boolean>, start: (fn: () => void) => Promise<void>];
```

```tsx
const [pending, start] = useTransition();
start(() => setHeavyState(newVal));
// pending() === true while transition is in progress
<button disabled={pending()}>
  {pending() ? "Loading..." : "Go"}
</button>
```
