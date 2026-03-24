---
name: solid-js
description: >
  SolidJS framework skill covering reactive primitives (createSignal, createEffect, createMemo, createResource),
  control flow (Show, For, Switch/Match, Index, Suspense, ErrorBoundary), stores (createStore, produce, reconcile),
  context, SolidStart (file-based routing, server functions, SSR/SSG), JSX compilation, props handling
  (mergeProps, splitProps), lifecycle (onMount, onCleanup), Solid Router, lazy loading, portals, styling,
  and testing with solid-testing-library. Includes advanced patterns (batch, untrack, on, custom directives,
  streaming SSR, islands architecture), troubleshooting guide, full API reference, migration scripts,
  and project templates. Triggers on: SolidJS, Solid app, createSignal, createEffect, createMemo,
  createResource, createStore, SolidStart, Solid Router, solid-js.
  NOT for React, NOT for Vue, NOT for Svelte, NOT for Angular, NOT for SOLID principles in OOP.
---

# SolidJS Skill

## Core Mental Model

SolidJS uses **fine-grained reactivity** with **no virtual DOM** and **no component re-renders**.
Components execute once. Only the exact DOM nodes bound to changed signals update.
JSX compiles to direct DOM instructions, not `createElement` calls.
**Never destructure props or store values** — it breaks reactivity. Use `mergeProps`/`splitProps`.

## Reactive Primitives

### createSignal — Reactive state atom

```tsx
import { createSignal } from "solid-js";

const [count, setCount] = createSignal(0);
// Read: count() — always call as function
// Write: setCount(5) or setCount(prev => prev + 1)

// Custom equality:
const [data, setData] = createSignal(obj, { equals: (a, b) => a.id === b.id });
```

### createEffect — Side-effect that auto-tracks dependencies

```tsx
import { createEffect, on } from "solid-js";

createEffect(() => console.log("Count is", count())); // auto-tracks

// Explicit tracking with `on`:
createEffect(on(count, (val, prev) => {
  console.log(`Changed from ${prev} to ${val}`);
}, { defer: true }));
```

### createMemo — Derived/computed value (cached)

```tsx
import { createMemo } from "solid-js";
const doubled = createMemo(() => count() * 2);
// Read: doubled() — recalculates only when count() changes
```

### createResource — Async data fetching with loading/error states

```tsx
import { createResource, Suspense } from "solid-js";

const fetchUser = async (id: string) => (await fetch(`/api/users/${id}`)).json();

const [userId, setUserId] = createSignal("1");
const [user, { mutate, refetch }] = createResource(userId, fetchUser);

// user()        — data (undefined while loading)
// user.loading  — boolean
// user.error    — error object or undefined
// user.state    — "unresolved" | "pending" | "ready" | "refreshing" | "errored"
```

## Control Flow Components

Always use these instead of JS ternaries/maps for optimal reactivity.

### Show — Conditional rendering
```tsx
import { Show } from "solid-js";
<Show when={user()} fallback={<p>Loading...</p>}>
  {(u) => <p>Hello, {u().name}</p>}
</Show>
```

### For — Keyed list iteration (items may reorder)
```tsx
import { For } from "solid-js";
<For each={items()}>
  {(item, index) => <li>{index()}: {item.name}</li>}
</For>
// index is a signal (call as function). item is the value.
```

### Index — Indexed iteration (items are fixed, values change)
```tsx
import { Index } from "solid-js";
<Index each={items()}>
  {(item, index) => <li>{index}: {item().name}</li>}
</Index>
// index is a number. item is a signal (call as function).
```

### Switch/Match — Multi-branch conditional
```tsx
import { Switch, Match } from "solid-js";
<Switch fallback={<p>Not found</p>}>
  <Match when={state() === "loading"}><Spinner /></Match>
  <Match when={state() === "error"}><Error /></Match>
  <Match when={state() === "ready"}><Content /></Match>
</Switch>
```

### Suspense / ErrorBoundary
```tsx
import { Suspense, ErrorBoundary } from "solid-js";
<ErrorBoundary fallback={(err, reset) => (
  <div>
    <p>Error: {err.message}</p>
    <button onClick={reset}>Retry</button>
  </div>
)}>
  <Suspense fallback={<Spinner />}>
    <AsyncComponent />
  </Suspense>
</ErrorBoundary>
```

## Stores — Deep reactive objects

Import from `"solid-js/store"`, never from `"solid-js"`.

### createStore
```tsx
import { createStore } from "solid-js/store";
const [state, setState] = createStore({
  users: [{ id: 1, name: "Alice" }],
  filter: "",
});
// Path syntax for surgical updates:
setState("users", 0, "name", "Alicia");
// Functional update at path:
setState("users", u => u.id === 1, "name", "Bob");
```

### produce — Immer-like mutable syntax
```tsx
import { produce } from "solid-js/store";
setState(produce((draft) => {
  draft.users.push({ id: 2, name: "Carol" });
  draft.users[0].name = "Updated";
}));
```

### reconcile — Diff-and-patch for external data
```tsx
import { reconcile } from "solid-js/store";
setState("users", reconcile(serverUsers, { key: "id" }));
```

## Props Handling

### mergeProps — Set defaults without breaking reactivity
```tsx
import { mergeProps } from "solid-js";
function Button(props) {
  const merged = mergeProps({ variant: "primary", size: "md" }, props);
  return <button class={`btn-${merged.variant} btn-${merged.size}`}>{merged.children}</button>;
}
```

### splitProps — Separate prop groups
```tsx
import { splitProps } from "solid-js";
function Input(props) {
  const [local, inputProps] = splitProps(props, ["label", "error"]);
  return (
    <div>
      <label>{local.label}</label>
      <input {...inputProps} />
      <Show when={local.error}><span class="error">{local.error}</span></Show>
    </div>
  );
}
```

**Anti-pattern:** `const { label, ...rest } = props;` — breaks reactivity.

## Context
```tsx
import { createContext, useContext, createSignal } from "solid-js";
const ThemeCtx = createContext<"light" | "dark">("light");

function ThemeProvider(props) {
  const [theme] = createSignal<"light" | "dark">("light");
  return <ThemeCtx.Provider value={theme()}>{props.children}</ThemeCtx.Provider>;
}

function ThemedButton() {
  const theme = useContext(ThemeCtx);
  return <button class={`btn-${theme}`}>Click</button>;
}
```

## Lifecycle
```tsx
import { createSignal, onMount, onCleanup } from "solid-js";
function Timer() {
  const [count, setCount] = createSignal(0);
  onMount(() => {
    const id = setInterval(() => setCount(c => c + 1), 1000);
    onCleanup(() => clearInterval(id));
  });
  return <p>{count()}</p>;
}
```
`onMount` runs once after initial render. `onCleanup` runs when owner scope is disposed.

## Refs
```tsx
function AutoFocus() {
  let inputRef!: HTMLInputElement;
  onMount(() => inputRef.focus());
  return <input ref={inputRef} />;
}
// Callback ref: <input ref={(el) => { /* el is the DOM node */ }} />
```

## Lazy Loading & Portals
```tsx
import { lazy } from "solid-js";
import { Portal } from "solid-js/web";

const Dashboard = lazy(() => import("./Dashboard")); // code splitting

function Modal(props) {
  return (
    <Portal mount={document.getElementById("modal-root")!}>
      <div class="modal">{props.children}</div>
    </Portal>
  );
}
```

## Solid Router
```tsx
import { Router, Route, A, useParams, useNavigate } from "@solidjs/router";

function App() {
  return (
    <Router>
      <Route path="/" component={Home} />
      <Route path="/users/:id" component={UserDetail} />
      <Route path="*404" component={NotFound} />
    </Router>
  );
}

function UserDetail() {
  const params = useParams<{ id: string }>();
  const navigate = useNavigate();
  return <div>User {params.id}</div>;
}
// Use <A href="/users/1"> instead of <a> for client-side navigation.
```

### Route data loading
```tsx
import { cache, createAsync } from "@solidjs/router";
const getUser = cache(async (id: string) => {
  return (await fetch(`/api/users/${id}`)).json();
}, "user");

function UserPage() {
  const params = useParams();
  const user = createAsync(() => getUser(params.id));
  return <Show when={user()}>{(u) => <h1>{u().name}</h1>}</Show>;
}
```

## SolidStart

### Project setup
```bash
npm init solid@latest my-app  # Select SolidStart template
cd my-app && npm install && npm run dev
```

### File-based routing
```
src/routes/
├── index.tsx          → /
├── about.tsx          → /about
├── users/
│   ├── index.tsx      → /users
│   └── [id].tsx       → /users/:id
└── [...404].tsx       → catch-all 404
```

### Server functions
```tsx
"use server";
export async function getUser(id: string) {
  const db = await getDB();
  return db.users.findUnique({ where: { id } }); // runs on server only
}
```
```tsx
import { createAsync } from "@solidjs/router";
import { getUser } from "./api";
export default function UserPage() {
  const user = createAsync(() => getUser("1"));
  return <Show when={user()}>{(u) => <h1>{u().name}</h1>}</Show>;
}
```

### SSR/SSG configuration
```ts
// app.config.ts
import { defineConfig } from "@solidjs/start/config";
export default defineConfig({
  server: { preset: "node-server" }, // SSR (default). Use "static" for SSG.
});
```

## Styling
```tsx
// CSS Modules (recommended):
import styles from "./Button.module.css";
<button class={styles.primary}>Click</button>

// Inline styles (object syntax, kebab-case keys):
<div style={{ "background-color": "red", padding: "10px" }}>Content</div>

// classList for conditional classes:
<div classList={{ active: isActive(), disabled: isDisabled() }}>Item</div>
```
Use `class` not `className`. Use `classList` for conditional classes.

## Testing
```bash
npm i -D vitest jsdom @solidjs/testing-library @testing-library/user-event @testing-library/jest-dom
```
```tsx
// Counter.test.tsx
import { render, screen, fireEvent } from "@solidjs/testing-library";
import { describe, it, expect } from "vitest";
import Counter from "./Counter";

describe("Counter", () => {
  it("increments on click", async () => {
    render(() => <Counter />);  // Always wrap in () =>
    const button = screen.getByRole("button");
    expect(button).toHaveTextContent("0");
    fireEvent.click(button);
    expect(button).toHaveTextContent("1");
  });
});
```
```ts
// vitest.config.ts
import { defineConfig } from "vitest/config";
import solidPlugin from "vite-plugin-solid";
export default defineConfig({
  plugins: [solidPlugin()],
  test: { environment: "jsdom", globals: true, transformMode: { web: [/\.[jt]sx?$/] } },
});
```

## Critical Anti-Patterns

| Anti-Pattern | Why It Breaks | Fix |
|---|---|---|
| `const { x } = props` | Reads value once, loses reactivity | `splitProps` or access `props.x` |
| `const v = store.x` | Captures value, not reactive binding | Access `store.x` inline in JSX |
| Using `.map()` in JSX | No keyed diffing, recreates all nodes | Use `<For>` or `<Index>` |
| `async` in `createEffect` | Tracking stops at first `await` | Derive signal first, fetch in resource |
| `className` attribute | Not valid in Solid JSX | Use `class` |
| Returning early in components | Component body runs once; early return breaks rendering | Use `<Show>` for conditional content |

## Example: Full Component

**Input:** "Build a todo app component with add/delete."

**Output:**
```tsx
import { createSignal, For } from "solid-js";

function TodoApp() {
  const [todos, setTodos] = createSignal<{ id: number; text: string }[]>([]);
  const [input, setInput] = createSignal("");
  let nextId = 0;

  const addTodo = () => {
    const text = input().trim();
    if (!text) return;
    setTodos(prev => [...prev, { id: nextId++, text }]);
    setInput("");
  };

  return (
    <div>
      <input value={input()} onInput={(e) => setInput(e.currentTarget.value)} />
      <button onClick={addTodo}>Add</button>
      <For each={todos()}>
        {(todo) => (
          <div>
            <span>{todo.text}</span>
            <button onClick={() => setTodos(p => p.filter(t => t.id !== todo.id))}>Delete</button>
          </div>
        )}
      </For>
    </div>
  );
}
export default TodoApp;
```

## Example: Data Fetching with Loading/Error

**Input:** "Fetch and display a user profile with loading and error states."

**Output:**
```tsx
import { createSignal, createResource, Switch, Match } from "solid-js";

const fetchProfile = async (id: string) => {
  const res = await fetch(`/api/profile/${id}`);
  if (!res.ok) throw new Error("Failed to load profile");
  return res.json();
};

function Profile() {
  const [userId] = createSignal("1");
  const [profile] = createResource(userId, fetchProfile);
  return (
    <Switch>
      <Match when={profile.loading}><p>Loading...</p></Match>
      <Match when={profile.error}><p>Error: {profile.error.message}</p></Match>
      <Match when={profile()}>{(p) => <div><h1>{p().name}</h1><p>{p().email}</p></div>}</Match>
    </Switch>
  );
}
```

## Supplementary Files

### References (deep-dive documentation)

| File | Description |
|------|-------------|
| `references/advanced-patterns.md` | Custom primitives, batch/untrack/on, custom directives, Solid Transition Group, streaming SSR, islands architecture |
| `references/troubleshooting.md` | Common pitfalls: destructured props, uncalled signals, stale closures, store mutation, JSX differences from React, hydration issues |
| `references/api-reference.md` | Complete API: createSignal, createEffect, createMemo, createResource, createStore, produce, reconcile, createContext, control flow components, lifecycle, transitions |

### Scripts (executable helpers)

| File | Description |
|------|-------------|
| `scripts/setup-solid.sh` | Scaffold a SolidJS or SolidStart project with recommended config. Usage: `./setup-solid.sh my-app [--start]` |
| `scripts/migrate-from-react.sh` | Scan for React patterns and suggest SolidJS equivalents (useState→createSignal, className→class, etc.) |
| `scripts/check-reactivity.sh` | Detect reactivity-breaking patterns: destructured props, uncalled signals, async effects, direct store mutation |

### Assets (templates and configs)

| File | Description |
|------|-------------|
| `assets/solid-component.tsx` | Component template with signals, effects, cleanup, splitProps, Show |
| `assets/solid-store.tsx` | Store pattern with context provider, produce, derived values |
| `assets/solid-start-route.tsx` | SolidStart route with cache, createAsync, ErrorBoundary, SEO meta |
| `assets/vite.config.ts` | Vite config for SolidJS with Vitest testing setup and path aliases |
<!-- tested: pass -->
