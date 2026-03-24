# SolidJS Troubleshooting Guide

## Table of Contents
- [Destructuring Props Kills Reactivity](#destructuring-props-kills-reactivity)
- [Accessing Signals Without Calling Them](#accessing-signals-without-calling-them)
- [Stale Closures in Effects](#stale-closures-in-effects)
- [Store Mutation Outside produce](#store-mutation-outside-produce)
- [JSX Differences from React](#jsx-differences-from-react)
- [Hydration Issues](#hydration-issues)
- [Async in Effects](#async-in-effects)
- [Conditional Rendering Mistakes](#conditional-rendering-mistakes)
- [Context Pitfalls](#context-pitfalls)
- [Common TypeScript Issues](#common-typescript-issues)

---

## Destructuring Props Kills Reactivity

Props are reactive getters on a Proxy object. Destructuring extracts the value once and discards the getter.

```tsx
// ❌ BROKEN — title is a static snapshot, never updates
function Heading({ title }: { title: string }) {
  return <h1>{title}</h1>;
}

// ❌ BROKEN — same issue with rest spread
function Card(props: CardProps) {
  const { title, ...rest } = props; // title frozen at mount
  return <div>{title}</div>;
}

// ✅ CORRECT — access props directly
function Heading(props: { title: string }) {
  return <h1>{props.title}</h1>;
}

// ✅ CORRECT — use splitProps for separating
function Card(props: CardProps) {
  const [local, others] = splitProps(props, ["title"]);
  return <div {...others}>{local.title}</div>;
}

// ✅ CORRECT — mergeProps for defaults
function Button(props: { variant?: string }) {
  const merged = mergeProps({ variant: "primary" }, props);
  return <button class={merged.variant}>{merged.children}</button>;
}
```

**Rule:** Never destructure `props` in function parameters or component body.

---

## Accessing Signals Without Calling Them

Signals are functions. Passing them without `()` passes the getter, not the value.

```tsx
const [count, setCount] = createSignal(0);

// ❌ BROKEN — passes the function itself, renders "[Function]" or nothing
<p>Count: {count}</p>

// ✅ CORRECT — call the signal to read its value
<p>Count: {count()}</p>

// ❌ BROKEN — comparison against the function, always truthy
if (count) { /* always true! */ }

// ✅ CORRECT
if (count() > 0) { /* reactive check */ }

// ❌ SUBTLE BUG — logs function, not value
console.log("value:", count);

// ✅ CORRECT
console.log("value:", count());
```

**Exception:** Pass the getter (without `()`) when a component/primitive expects an accessor:
```tsx
<Show when={count()}>  // when expects a value
<MyComponent signal={count}>  // if MyComponent calls signal() internally
```

---

## Stale Closures in Effects

Unlike React, Solid effects don't re-create closures on every render. A closure captures the signal reference, but you must call it inside the effect to get the current value.

```tsx
const [count, setCount] = createSignal(0);

// ❌ STALE — captures count() at creation time
const increment = () => {
  const current = count(); // read once
  setTimeout(() => setCount(current + 1), 1000); // uses stale value
};

// ✅ CORRECT — read count() inside the timeout
const increment = () => {
  setTimeout(() => setCount(count() + 1), 1000);
};

// ✅ BEST — use functional setter to avoid stale reads entirely
const increment = () => {
  setTimeout(() => setCount(c => c + 1), 1000);
};

// ❌ STALE in event handlers with captured values
createEffect(() => {
  const val = count(); // tracked
  document.addEventListener("click", () => {
    console.log(val); // stale! captures value, not signal
  });
});

// ✅ CORRECT — read signal inside handler
createEffect(() => {
  const handler = () => console.log(count()); // always current
  document.addEventListener("click", handler);
  onCleanup(() => document.removeEventListener("click", handler));
});
```

---

## Store Mutation Outside produce

Directly mutating store objects bypasses Solid's tracking. Changes won't trigger updates.

```tsx
import { createStore, produce } from "solid-js/store";

const [store, setStore] = createStore({ todos: [{ text: "Buy milk", done: false }] });

// ❌ BROKEN — direct mutation, no reactivity triggered
store.todos[0].done = true;
store.todos.push({ text: "New", done: false });

// ✅ CORRECT — path syntax
setStore("todos", 0, "done", true);

// ✅ CORRECT — produce for Immer-like mutation
setStore(produce((draft) => {
  draft.todos[0].done = true;
  draft.todos.push({ text: "New", done: false });
}));

// ✅ CORRECT — reconcile for replacing with server data
import { reconcile } from "solid-js/store";
setStore("todos", reconcile(serverTodos, { key: "id" }));

// ❌ BROKEN — spreading loses proxy tracking
const todo = { ...store.todos[0] }; // plain object, not reactive
todo.done = true; // does nothing

// ✅ CORRECT — always go through setStore
setStore("todos", 0, "done", true);
```

---

## JSX Differences from React

### No re-renders means no useMemo equivalent needed
Component functions run once. Expressions in JSX are already reactive. You don't need `useMemo` to avoid recalculation — `createMemo` is for expensive computations read in multiple places.

```tsx
// React thinking (unnecessary in Solid):
const displayName = createMemo(() => `${props.first} ${props.last}`);

// Solid reality: just use the expression inline, it's fine
<p>{props.first} {props.last}</p>  // only updates when props change
```

### Attribute differences
| React | Solid | Notes |
|-------|-------|-------|
| `className` | `class` | Solid uses native HTML attributes |
| `htmlFor` | `for` | Same reason |
| `onChange` | `onInput` | `onChange` fires on blur in Solid (native behavior) |
| `style={{ fontSize: 16 }}` | `style={{ "font-size": "16px" }}` | Kebab-case, string values |
| `dangerouslySetInnerHTML` | `innerHTML` | Direct attribute |
| `ref={myRef}` | `ref={myRef}` | But refs are plain variables, not `useRef` objects |
| `key={id}` | N/A | Use `<For>` with keyed callback instead |

### Event handlers
```tsx
// Solid uses native events by default (not synthetic):
<input onInput={(e) => setValue(e.currentTarget.value)} />

// Event delegation for common events (click, input, etc.):
// Solid auto-delegates these. Custom events need "on:" prefix:
<div on:customEvent={(e) => handleCustom(e)} />

// Capture phase:
<div onClickCapture={() => {}} />  // React
<div oncapture:click={() => {}} /> // Solid
```

### No children array
```tsx
// React: React.Children.map(children, ...)
// Solid: children is a getter, use children() helper for resolved children
import { children } from "solid-js";

function Wrapper(props) {
  const resolved = children(() => props.children);
  createEffect(() => {
    console.log("Children:", resolved.toArray());
  });
  return <div>{resolved()}</div>;
}
```

---

## Hydration Issues

Hydration errors occur when server HTML doesn't match client rendering.

### Common causes and fixes

```tsx
// ❌ Non-deterministic rendering
function Clock() {
  return <span>{new Date().toLocaleTimeString()}</span>; // differs server vs client
}

// ✅ Use onMount for client-only values
function Clock() {
  const [time, setTime] = createSignal("");
  onMount(() => setTime(new Date().toLocaleTimeString()));
  return <span>{time()}</span>;
}

// ❌ Browser-only APIs at module scope
const width = window.innerWidth; // crashes during SSR

// ✅ Guard with isServer or use onMount
import { isServer } from "solid-js/web";
const width = isServer ? 0 : window.innerWidth;

// ❌ Mutating DOM before hydration completes
document.title = "My App"; // at module scope

// ✅ Put in onMount
onMount(() => { document.title = "My App"; });
```

### Use `clientOnly` for browser-dependent components
```tsx
import { clientOnly } from "@solidjs/start";
const Chart = clientOnly(() => import("./Chart"));
// Renders fallback on server, hydrates on client
```

---

## Async in Effects

`createEffect` tracking stops at the first `await`. Signals read after `await` are not tracked.

```tsx
// ❌ BROKEN — signals after await are not tracked
createEffect(async () => {
  const id = userId();  // tracked
  const res = await fetch(`/api/${id}`);
  const data = await res.json();
  setName(data[filter()]); // filter() NOT tracked — read after await
});

// ✅ CORRECT — read all deps before await
createEffect(async () => {
  const id = userId();     // tracked
  const f = filter();      // tracked — read before await
  const res = await fetch(`/api/${id}`);
  const data = await res.json();
  setName(data[f]);
});

// ✅ BEST — use createResource for async data
const [user] = createResource(userId, async (id) => {
  const res = await fetch(`/api/${id}`);
  return res.json();
});
```

---

## Conditional Rendering Mistakes

Components run once. Early returns and ternaries behave differently than React.

```tsx
// ❌ BROKEN — early return evaluated once, never re-checked
function Profile(props) {
  if (!props.user) return <p>No user</p>; // stuck here forever
  return <h1>{props.user.name}</h1>;
}

// ✅ CORRECT — use <Show> for conditional content
function Profile(props) {
  return (
    <Show when={props.user} fallback={<p>No user</p>}>
      {(user) => <h1>{user().name}</h1>}
    </Show>
  );
}

// ❌ BROKEN — ternary outside JSX evaluated once
function Status(props) {
  const message = props.active ? "Active" : "Inactive"; // frozen
  return <span>{message}</span>;
}

// ✅ CORRECT — put ternary in JSX or use createMemo
function Status(props) {
  return <span>{props.active ? "Active" : "Inactive"}</span>;
}
```

---

## Context Pitfalls

```tsx
// ❌ BROKEN — passing plain value loses reactivity
const ThemeCtx = createContext();
function Provider(props) {
  const [theme, setTheme] = createSignal("light");
  return (
    // value={theme()} passes a static string
    <ThemeCtx.Provider value={theme()}>
      {props.children}
    </ThemeCtx.Provider>
  );
}

// ✅ CORRECT — pass the signal or an object with signals/setters
function Provider(props) {
  const [theme, setTheme] = createSignal("light");
  return (
    <ThemeCtx.Provider value={{ theme, setTheme }}>
      {props.children}
    </ThemeCtx.Provider>
  );
}
// Consumer: const { theme, setTheme } = useContext(ThemeCtx); theme() to read
```

---

## Common TypeScript Issues

```tsx
// Ref typing — use definite assignment assertion
let inputRef!: HTMLInputElement;
<input ref={inputRef} />

// Component props — use ParentProps for children
import { ParentProps } from "solid-js";
function Layout(props: ParentProps<{ title: string }>) {
  return <div>{props.title}{props.children}</div>;
}

// Custom directive typing — extend JSX.Directives
declare module "solid-js" {
  namespace JSX {
    interface Directives { tooltip: string; }
  }
}

// Generic components
function List<T>(props: { items: T[]; render: (item: T) => JSX.Element }) {
  return <For each={props.items}>{props.render}</For>;
}
```
