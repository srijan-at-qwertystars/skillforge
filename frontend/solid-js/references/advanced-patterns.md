# SolidJS Advanced Patterns

## Table of Contents
- [Custom Primitives](#custom-primitives)
- [Nested Reactivity](#nested-reactivity)
- [Batching with batch()](#batching-with-batch)
- [Opting Out with untrack()](#opting-out-with-untrack)
- [Explicit Tracking with on()](#explicit-tracking-with-on)
- [Fine-Grained DOM Updates](#fine-grained-dom-updates)
- [Custom Directives](#custom-directives)
- [Solid Transition Group](#solid-transition-group)
- [Streaming SSR](#streaming-ssr)
- [Islands Architecture](#islands-architecture)

---

## Custom Primitives

Build reusable reactive abstractions by composing core primitives. Return accessors (getters), not raw values.

```tsx
import { createSignal, createEffect, onCleanup, Accessor } from "solid-js";

// Custom primitive: tracks mouse position
function createMousePosition(): { x: Accessor<number>; y: Accessor<number> } {
  const [x, setX] = createSignal(0);
  const [y, setY] = createSignal(0);

  const handler = (e: MouseEvent) => { setX(e.clientX); setY(e.clientY); };
  window.addEventListener("mousemove", handler);
  onCleanup(() => window.removeEventListener("mousemove", handler));

  return { x, y };
}

// Custom primitive: debounced signal
function createDebouncedSignal<T>(initial: T, delay: number) {
  const [value, setValue] = createSignal(initial);
  const [debounced, setDebounced] = createSignal(initial);
  let timeout: ReturnType<typeof setTimeout>;

  createEffect(() => {
    const v = value();
    clearTimeout(timeout);
    timeout = setTimeout(() => setDebounced(() => v), delay);
  });
  onCleanup(() => clearTimeout(timeout));

  return [debounced, setValue] as const;
}

// Custom primitive: localStorage-backed signal
function createStoredSignal<T>(key: string, initial: T) {
  const stored = localStorage.getItem(key);
  const [value, setValue] = createSignal<T>(
    stored ? JSON.parse(stored) : initial
  );
  createEffect(() => localStorage.setItem(key, JSON.stringify(value())));
  return [value, setValue] as const;
}
```

**Community library:** [`solid-primitives`](https://primitives.solidjs.community/) — 50+ production-ready primitives (media queries, intersection observer, geolocation, etc.).

---

## Nested Reactivity

Stores track each nested property independently. Updating `state.user.name` only re-renders DOM nodes reading that exact path.

```tsx
import { createStore } from "solid-js/store";

const [state, setState] = createStore({
  user: { name: "Alice", prefs: { theme: "dark", lang: "en" } },
  items: [{ id: 1, done: false }, { id: 2, done: true }],
});

// Only the span reading prefs.theme updates:
setState("user", "prefs", "theme", "light");

// Update matching items — only affected <li> nodes re-render:
setState("items", (item) => item.id === 1, "done", true);

// Nested signal pattern for maximum granularity:
import { createSignal } from "solid-js";
function createTodo(text: string) {
  const [done, setDone] = createSignal(false);
  return { text, get done() { return done(); }, toggle: () => setDone(d => !d) };
}
```

---

## Batching with batch()

Group multiple signal updates into one flush. Effects and DOM updates run once after the batch completes.

```tsx
import { createSignal, createEffect, batch } from "solid-js";

const [firstName, setFirstName] = createSignal("John");
const [lastName, setLastName] = createSignal("Doe");

// Without batch: effect runs twice (once per set call)
// With batch: effect runs once after both updates
createEffect(() => console.log(`${firstName()} ${lastName()}`));

batch(() => {
  setFirstName("Jane");
  setLastName("Smith");
});
// Logs "Jane Smith" once

// Note: setState on stores is automatically batched.
// batch() is mainly needed when updating multiple independent signals.
```

---

## Opting Out with untrack()

Read a signal's current value without subscribing to it. The enclosing computation won't re-run when that signal changes.

```tsx
import { createSignal, createEffect, untrack } from "solid-js";

const [count, setCount] = createSignal(0);
const [label, setLabel] = createSignal("Count");

createEffect(() => {
  // Re-runs when label changes, but NOT when count changes
  console.log(`${label()}: ${untrack(count)}`);
});

// Common use: read config/initial values in effects without tracking
createEffect(() => {
  const threshold = untrack(getThreshold); // read once, don't track
  if (count() > threshold) alert("Exceeded!");
});
```

---

## Explicit Tracking with on()

Specify exactly which signals trigger re-execution. Useful for effects that read many signals but should only react to specific ones.

```tsx
import { createSignal, createEffect, on } from "solid-js";

const [a, setA] = createSignal(0);
const [b, setB] = createSignal(0);

// Only re-runs when `a` changes; reads `b` without tracking:
createEffect(on(a, (aVal) => {
  console.log(`a=${aVal}, b=${b()}`); // b is read but not tracked
}));

// Multiple dependencies:
createEffect(on([a, b], ([aVal, bVal], prev) => {
  console.log(`Changed from ${prev} to [${aVal}, ${bVal}]`);
}));

// Defer initial run (skip mount, fire only on updates):
createEffect(on(a, (val, prev) => {
  console.log(`a updated: ${prev} → ${val}`);
}, { defer: true }));
```

---

## Fine-Grained DOM Updates

Solid compiles JSX to direct DOM operations. No virtual DOM diffing. Each reactive expression becomes a targeted DOM update.

```tsx
// This JSX compiles to approximately:
// const el = document.createElement("div");
// const text = document.createTextNode("");
// createEffect(() => text.data = count());  ← only this text node updates
function Counter() {
  const [count, setCount] = createSignal(0);
  return <div>Count: {count()}</div>;
}

// Optimize expensive lists: use <Index> when items are fixed positions
// and <For> when items may reorder.
// Avoid: items().map(...) — recreates all DOM nodes on every change.
```

---

## Custom Directives

Encapsulate reusable DOM behavior. A directive is a function receiving `(element, accessor)`.

```tsx
import { Accessor, onCleanup } from "solid-js";

// Declare for TypeScript:
declare module "solid-js" {
  namespace JSX {
    interface Directives {
      clickOutside: () => void;
      longpress: () => void;
    }
  }
}

// Directive: detect clicks outside element
function clickOutside(el: HTMLElement, accessor: Accessor<() => void>) {
  const handler = (e: MouseEvent) => {
    if (!el.contains(e.target as Node)) accessor()();
  };
  document.addEventListener("click", handler);
  onCleanup(() => document.removeEventListener("click", handler));
}

// Directive: long press detection
function longpress(el: HTMLElement, accessor: Accessor<() => void>) {
  let timeout: ReturnType<typeof setTimeout>;
  el.addEventListener("pointerdown", () => { timeout = setTimeout(accessor(), 500); });
  el.addEventListener("pointerup", () => clearTimeout(timeout));
  onCleanup(() => clearTimeout(timeout));
}

// Usage (must import directive to avoid tree-shaking):
function Dropdown() {
  const [open, setOpen] = createSignal(false);
  return (
    <div use:clickOutside={() => setOpen(false)}>
      <button use:longpress={() => console.log("Long pressed!")}>Menu</button>
      <Show when={open()}><ul>...</ul></Show>
    </div>
  );
}
// IMPORTANT: import the directive even if unused as a value:
// false && clickOutside; // prevents tree-shaking
```

---

## Solid Transition Group

Animate elements entering/leaving the DOM. Install: `npm i solid-transition-group`.

```tsx
import { Transition, TransitionGroup } from "solid-transition-group";
import { createSignal, Show, For } from "solid-js";

// Single element transition (CSS-based):
function FadePanel() {
  const [show, setShow] = createSignal(true);
  return (
    <>
      <button onClick={() => setShow(s => !s)}>Toggle</button>
      <Transition name="fade">
        <Show when={show()}><div class="panel">Content</div></Show>
      </Transition>
    </>
  );
}
// CSS: .fade-enter-active, .fade-exit-active { transition: opacity 0.3s; }
//      .fade-enter, .fade-exit-to { opacity: 0; }

// JS animation hooks:
<Transition
  onEnter={(el, done) => {
    el.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 300 }).finished.then(done);
  }}
  onExit={(el, done) => {
    el.animate([{ opacity: 1 }, { opacity: 0 }], { duration: 300 }).finished.then(done);
  }}
>
  <Show when={visible()}><div>Animated</div></Show>
</Transition>

// List transitions:
<TransitionGroup name="list">
  <For each={items()}>{(item) => <div>{item.name}</div>}</For>
</TransitionGroup>

// Transition modes: "outin" (exit then enter) | "inout" (enter then exit)
<Transition name="slide" mode="outin">...</Transition>
```

---

## Streaming SSR

SolidStart streams HTML to the client as async data resolves, reducing Time to First Byte.

```ts
// app.config.ts — enable streaming
import { defineConfig } from "@solidjs/start/config";
export default defineConfig({
  server: { preset: "node-server" },   // supports streaming
  // Streaming is enabled by default in SSR mode
});
```

```tsx
// Route with streamed async data:
import { Suspense } from "solid-js";
import { createAsync } from "@solidjs/router";

const getAnalytics = cache(async () => {
  const res = await fetch("/api/analytics");
  return res.json();
}, "analytics");

export default function Dashboard() {
  const data = createAsync(() => getAnalytics());
  return (
    <div>
      <h1>Dashboard</h1>  {/* Sent immediately */}
      <Suspense fallback={<p>Loading analytics...</p>}>
        <Show when={data()}>{(d) => <Chart data={d()} />}</Show>
      </Suspense>  {/* Streamed when data resolves */}
    </div>
  );
}
```

**How it works:** Server sends the HTML shell immediately. `<Suspense>` boundaries mark stream points. As each async boundary resolves, the server flushes the HTML chunk + a `<script>` tag that swaps the fallback.

---

## Islands Architecture

Use `clientOnly` in SolidStart to create "islands" — components that only hydrate on the client while the rest stays static.

```tsx
import { clientOnly } from "@solidjs/start";

// Heavy interactive component — only runs in browser
const InteractiveChart = clientOnly(() => import("./Chart"));
const RichEditor = clientOnly(() => import("./Editor"));

export default function Page() {
  return (
    <article>
      <h1>Static heading (no JS)</h1>
      <p>Static content (no JS)</p>
      <InteractiveChart fallback={<p>Loading chart...</p>} />
      <RichEditor fallback={<p>Loading editor...</p>} />
    </article>
  );
}
```

**When to use islands:**
- Components needing browser APIs (canvas, WebGL, localStorage)
- Heavy interactive widgets (editors, charts, maps)
- Third-party libraries not SSR-compatible

**Combine with streaming SSR** for optimal performance: static content renders instantly, islands stream in as they hydrate.
