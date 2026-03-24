# SvelteKit Migration Guide

## Table of Contents

- [Svelte 4 → Svelte 5 Migration](#svelte-4--svelte-5-migration)
  - [Stores → Runes](#stores--runes)
  - [Reactive Declarations → $derived](#reactive-declarations--derived)
  - [$: Side Effects → $effect](#-side-effects--effect)
  - [Slots → Snippets](#slots--snippets)
  - [Event Forwarding → Callback Props](#event-forwarding--callback-props)
  - [createEventDispatcher → Callback Props](#createeventdispatcher--callback-props)
  - [beforeUpdate/afterUpdate → $effect.pre/$effect](#beforeupdateafterupdate--effectpreeffect)
  - [Component Composition Changes](#component-composition-changes)
  - [Svelte 5 Automated Migration Tool](#svelte-5-automated-migration-tool)
- [SvelteKit 1 → SvelteKit 2 Migration](#sveltekit-1--sveltekit-2-migration)
  - [Breaking Changes](#breaking-changes)
  - [New Features in SvelteKit 2](#new-features-in-sveltekit-2)
  - [Step-by-Step Upgrade Process](#step-by-step-upgrade-process)
- [React → SvelteKit Migration](#react--sveltekit-migration)
  - [Component Model Comparison](#component-model-comparison)
  - [State Management](#state-management)
  - [Routing Comparison](#routing-comparison)
  - [Data Fetching Equivalents](#data-fetching-equivalents)
  - [Side Effects and Lifecycle](#side-effects-and-lifecycle)
  - [Styling](#styling)
  - [Common Patterns Side by Side](#common-patterns-side-by-side)
- [Next.js → SvelteKit Migration](#nextjs--sveltekit-migration)
  - [Architecture Comparison](#architecture-comparison)
  - [Routing Mapping](#routing-mapping)
  - [Data Fetching Migration](#data-fetching-migration)
  - [API Routes](#api-routes)
  - [Middleware → Hooks](#middleware--hooks)
  - [Migration Path](#migration-path)

---

## Svelte 4 → Svelte 5 Migration

Svelte 5 replaces stores and reactive declarations with runes — compiler-level
reactivity primitives. Svelte 5 is backward-compatible; old syntax still works
but is deprecated.

### Stores → Runes

**Writable stores → $state:**

```svelte
<!-- Svelte 4 -->
<script>
  import { writable } from 'svelte/store';
  const count = writable(0);
</script>
<button on:click={() => $count++}>Count: {$count}</button>

<!-- Svelte 5 -->
<script>
  let count = $state(0);
</script>
<button onclick={() => count++}>Count: {count}</button>
```

**Shared module stores → shared .svelte.ts state:**

```ts
// Svelte 4 — src/lib/stores.ts
import { writable, derived } from 'svelte/store';
export const count = writable(0);
export const doubled = derived(count, $c => $c * 2);
export function increment() { count.update(n => n + 1); }
export function reset() { count.set(0); }

// Svelte 5 — src/lib/stores.svelte.ts
let count = $state(0);
let doubled = $derived(count * 2);
export function getCount() { return count; }
export function getDoubled() { return doubled; }
export function increment() { count++; }
export function reset() { count = 0; }
```

```svelte
<!-- Svelte 4 usage -->
<script>
  import { count, doubled, increment } from '$lib/stores';
</script>
<p>{$count} × 2 = {$doubled}</p>
<button on:click={increment}>+1</button>

<!-- Svelte 5 usage -->
<script>
  import { getCount, getDoubled, increment } from '$lib/stores.svelte';
</script>
<p>{getCount()} × 2 = {getDoubled()}</p>
<button onclick={increment}>+1</button>
```

**Note:** In Svelte 5, you must expose reactive state through getter functions
(or use `get` accessors on classes/objects) so consumers read the current value.
Exporting a `$state` variable directly exports the initial value, not a live binding.

**Readable stores → $state + exports:**

```ts
// Svelte 4
import { readable } from 'svelte/store';
export const time = readable(new Date(), (set) => {
  const id = setInterval(() => set(new Date()), 1000);
  return () => clearInterval(id);
});

// Svelte 5 — src/lib/time.svelte.ts
let time = $state(new Date());
let interval: ReturnType<typeof setInterval> | null = null;

export function startClock() {
  interval = setInterval(() => { time = new Date(); }, 1000);
}

export function stopClock() {
  if (interval) clearInterval(interval);
}

export function getTime() { return time; }
```

**Custom stores → classes with runes:**

```ts
// Svelte 4 — custom store
function createTodos() {
  const { subscribe, set, update } = writable<Todo[]>([]);
  return {
    subscribe,
    add: (text: string) => update(todos => [...todos, { id: Date.now(), text, done: false }]),
    toggle: (id: number) => update(todos =>
      todos.map(t => t.id === id ? { ...t, done: !t.done } : t)
    ),
    remove: (id: number) => update(todos => todos.filter(t => t.id !== id))
  };
}
export const todos = createTodos();

// Svelte 5 — class with runes
// src/lib/todos.svelte.ts
export class TodoStore {
  items = $state<Todo[]>([]);
  remaining = $derived(this.items.filter(t => !t.done).length);

  add(text: string) {
    this.items.push({ id: Date.now(), text, done: false });
  }
  toggle(id: number) {
    const todo = this.items.find(t => t.id === id);
    if (todo) todo.done = !todo.done;
  }
  remove(id: number) {
    this.items = this.items.filter(t => t.id !== id);
  }
}
```

### Reactive Declarations → $derived

```svelte
<!-- Svelte 4 -->
<script>
  let count = 0;
  $: doubled = count * 2;
  $: quadrupled = doubled * 2;
  $: if (count > 10) console.log('High count!');
  $: formatted = `Count is ${count}`;
  $: ({ first, last } = fullName.split(' '));
</script>

<!-- Svelte 5 -->
<script>
  let count = $state(0);
  let doubled = $derived(count * 2);
  let quadrupled = $derived(doubled * 2);
  let formatted = $derived(`Count is ${count}`);

  // Complex derivations use $derived.by
  let parts = $derived.by(() => {
    const [first, last] = fullName.split(' ');
    return { first, last };
  });

  // Side-effect reactive statements → $effect
  $effect(() => {
    if (count > 10) console.log('High count!');
  });
</script>
```

**Key differences:**
- `$derived` is lazy — only recomputes when read (Svelte 4 `$:` ran eagerly)
- `$derived` cannot produce side effects (no assignments, no API calls)
- Use `$derived.by(() => ...)` for multi-statement derivations
- `$derived` auto-tracks dependencies (no need to reference variables on the right side of `$:`)

### $: Side Effects → $effect

```svelte
<!-- Svelte 4 -->
<script>
  let count = 0;
  $: document.title = `Count: ${count}`;
  $: console.log('Count changed:', count);
  $: {
    if (count > 0) {
      localStorage.setItem('count', String(count));
    }
  }
</script>

<!-- Svelte 5 -->
<script>
  let count = $state(0);

  $effect(() => {
    document.title = `Count: ${count}`;
  });

  $effect(() => {
    console.log('Count changed:', count);
  });

  $effect(() => {
    if (count > 0) {
      localStorage.setItem('count', String(count));
    }
  });
</script>
```

**Cleanup pattern:**

```svelte
<!-- Svelte 4 — onDestroy for cleanup -->
<script>
  import { onDestroy } from 'svelte';
  const interval = setInterval(() => { /* ... */ }, 1000);
  onDestroy(() => clearInterval(interval));
</script>

<!-- Svelte 5 — $effect with return cleanup -->
<script>
  $effect(() => {
    const interval = setInterval(() => { /* ... */ }, 1000);
    return () => clearInterval(interval);
  });
</script>
```

**Important `$effect` rules:**
- Runs after DOM update (like `afterUpdate`, not `beforeUpdate`)
- Use `$effect.pre()` for before-DOM-update effects
- Avoid setting `$state` inside `$effect` — prefer `$derived` instead
- `$effect` only runs in component context or `$effect.root`

### Slots → Snippets

```svelte
<!-- Svelte 4 — default slot -->
<div class="card">
  <slot />
</div>

<!-- Svelte 5 — default children snippet -->
<script>
  let { children } = $props();
</script>
<div class="card">
  {@render children()}
</div>
```

```svelte
<!-- Svelte 4 — named slots -->
<div class="card">
  <header><slot name="header" /></header>
  <main><slot /></main>
  <footer><slot name="footer">Default footer</slot></footer>
</div>

<!-- Svelte 5 — named snippets -->
<script>
  import type { Snippet } from 'svelte';
  let { header, children, footer }: {
    header: Snippet;
    children: Snippet;
    footer?: Snippet;
  } = $props();
</script>
<div class="card">
  <header>{@render header()}</header>
  <main>{@render children()}</main>
  <footer>
    {#if footer}
      {@render footer()}
    {:else}
      Default footer
    {/if}
  </footer>
</div>
```

```svelte
<!-- Svelte 4 — slot props -->
<ul>
  {#each items as item}
    <li><slot {item} index={i} /></li>
  {/each}
</ul>

<!-- Parent -->
<List {items} let:item let:index>
  <span>{index}: {item.name}</span>
</List>

<!-- Svelte 5 — snippet with parameters -->
<script>
  import type { Snippet } from 'svelte';
  let { items, row }: {
    items: Item[];
    row: Snippet<[Item, number]>;
  } = $props();
</script>
<ul>
  {#each items as item, i}
    <li>{@render row(item, i)}</li>
  {/each}
</ul>

<!-- Parent -->
<List {items}>
  {#snippet row(item, index)}
    <span>{index}: {item.name}</span>
  {/snippet}
</List>
```

### Event Forwarding → Callback Props

```svelte
<!-- Svelte 4 — event dispatching and forwarding -->
<!-- Child.svelte -->
<script>
  import { createEventDispatcher } from 'svelte';
  const dispatch = createEventDispatcher();
</script>
<button on:click={() => dispatch('select', { id: 1 })}>Select</button>
<!-- Also forward native events -->
<input on:input />

<!-- Parent -->
<Child on:select={(e) => handleSelect(e.detail)} />

<!-- Svelte 5 — callback props -->
<!-- Child.svelte -->
<script>
  let { onselect, oninput }: {
    onselect?: (data: { id: number }) => void;
    oninput?: (e: Event) => void;
  } = $props();
</script>
<button onclick={() => onselect?.({ id: 1 })}>Select</button>
<input {oninput} />

<!-- Parent -->
<Child onselect={(data) => handleSelect(data)} />
```

**Key change:** Events are now just props. No more `createEventDispatcher`,
no `on:` directive, no `e.detail` wrapper. Data goes directly.

### createEventDispatcher → Callback Props

```svelte
<!-- Svelte 4 -->
<script>
  import { createEventDispatcher } from 'svelte';
  const dispatch = createEventDispatcher<{
    save: { title: string; body: string };
    cancel: void;
    delete: { id: number };
  }>();

  function handleSave() {
    dispatch('save', { title, body });
  }
</script>
<button on:click={handleSave}>Save</button>
<button on:click={() => dispatch('cancel')}>Cancel</button>

<!-- Parent -->
<Editor on:save={e => save(e.detail)} on:cancel={goBack} on:delete={e => remove(e.detail.id)} />

<!-- Svelte 5 -->
<script lang="ts">
  let { onsave, oncancel, ondelete }: {
    onsave?: (data: { title: string; body: string }) => void;
    oncancel?: () => void;
    ondelete?: (data: { id: number }) => void;
  } = $props();

  function handleSave() {
    onsave?.({ title, body });
  }
</script>
<button onclick={handleSave}>Save</button>
<button onclick={() => oncancel?.()}>Cancel</button>

<!-- Parent -->
<Editor onsave={(data) => save(data)} oncancel={goBack} ondelete={(data) => remove(data.id)} />
```

### beforeUpdate/afterUpdate → $effect.pre/$effect

```svelte
<!-- Svelte 4 -->
<script>
  import { beforeUpdate, afterUpdate } from 'svelte';

  beforeUpdate(() => {
    // Runs before DOM update
    previousScrollHeight = container.scrollHeight;
  });

  afterUpdate(() => {
    // Runs after DOM update
    if (container.scrollHeight !== previousScrollHeight) {
      container.scrollTop = container.scrollHeight;
    }
  });
</script>

<!-- Svelte 5 -->
<script>
  let container: HTMLDivElement;
  let previousScrollHeight = $state(0);

  $effect.pre(() => {
    // Runs before DOM update — track dependencies explicitly
    previousScrollHeight = container?.scrollHeight ?? 0;
  });

  $effect(() => {
    // Runs after DOM update
    if (container && container.scrollHeight !== previousScrollHeight) {
      container.scrollTop = container.scrollHeight;
    }
  });
</script>
```

### Component Composition Changes

**`on:` directive removal:**

```svelte
<!-- Svelte 4 -->
<button on:click={handler}>Click</button>
<button on:click|preventDefault|stopPropagation={handler}>Click</button>
<input on:input={handler} on:focus={focusHandler} />

<!-- Svelte 5 -->
<button onclick={handler}>Click</button>
<button onclick={(e) => { e.preventDefault(); e.stopPropagation(); handler(e); }}>Click</button>
<input oninput={handler} onfocus={focusHandler} />
```

**Component instantiation (imperative API):**

```ts
// Svelte 4
import MyComponent from './MyComponent.svelte';
const component = new MyComponent({
  target: document.getElementById('app'),
  props: { name: 'world' }
});
component.$set({ name: 'updated' });
component.$destroy();

// Svelte 5
import { mount, unmount } from 'svelte';
import MyComponent from './MyComponent.svelte';
const component = mount(MyComponent, {
  target: document.getElementById('app')!,
  props: { name: 'world' }
});
// To update: use $state in props
unmount(component);
```

### Svelte 5 Automated Migration Tool

```bash
# Run the automated migration script
npx sv migrate svelte-5

# What it does:
# - Converts on:event to onevent props
# - Converts <slot> to {@render children()}
# - Converts createEventDispatcher to callback props
# - Converts $: reactive declarations to $derived/$effect
# - Converts writable/readable to $state

# What it does NOT do:
# - Convert shared store files (.ts → .svelte.ts)
# - Fix complex reactive patterns that need manual review
# - Update tests

# After running, manually review and fix:
# 1. Shared state modules (rename .ts → .svelte.ts, refactor exports)
# 2. Complex $effect patterns (avoid infinite loops)
# 3. Test files using component APIs
```

---

## SvelteKit 1 → SvelteKit 2 Migration

### Breaking Changes

**1. Requires Svelte 4+ (and works with Svelte 5):**

```bash
npm install @sveltejs/kit@2 svelte@5
```

**2. Top-level promises in load auto-unwrap removed:**

```ts
// SvelteKit 1 — promises in load were auto-awaited
export const load = async () => {
  return {
    streamed: {
      comments: fetchComments() // Promise auto-streamed
    }
  };
};

// SvelteKit 2 — return promises directly (no streamed wrapper)
export const load = async () => {
  return {
    comments: fetchComments() // Just return the promise, it streams
  };
};
```

**3. `goto()` changes:**

```ts
// SvelteKit 1
goto('/page', { replaceState: true, noScroll: true });

// SvelteKit 2 — renamed options
goto('/page', { replaceState: true, noScroll: true }); // Same (no change here)
// But state must be serializable
goto('/page', { state: { myData: 'value' } }); // state must be JSON-serializable
```

**4. `resolvePath` replaced with `resolveRoute`:**

```ts
// SvelteKit 1
import { resolvePath } from '@sveltejs/kit';
const path = resolvePath('/blog/[slug]', { slug: 'hello' });

// SvelteKit 2
import { resolveRoute } from '$app/paths';
const path = resolveRoute('/blog/[slug]', { slug: 'hello' });
```

**5. `$page` store → `page` from `$app/state`:**

```svelte
<!-- SvelteKit 1 -->
<script>
  import { page } from '$app/stores';
</script>
<p>URL: {$page.url.pathname}</p>

<!-- SvelteKit 2 (with Svelte 5) -->
<script>
  import { page } from '$app/state';
</script>
<p>URL: {page.url.pathname}</p>
```

**6. Cookie path now required:**

```ts
// SvelteKit 1
cookies.set('name', 'value');           // path defaulted to current

// SvelteKit 2
cookies.set('name', 'value', { path: '/' }); // path is REQUIRED
cookies.delete('name', { path: '/' });        // path is REQUIRED
```

**7. Top-level `+error.svelte` renamed:**

```
SvelteKit 1: src/routes/+error.svelte (handled root errors)
SvelteKit 2: src/error.html (static fallback for fatal errors)
            src/routes/+error.svelte (handles load/render errors as before)
```

### New Features in SvelteKit 2

- **Shallow routing:** `pushState()` and `replaceState()` for URL changes without navigation
- **`$app/state`:** Reactive page/navigating/updated state (replaces stores with Svelte 5)
- **Improved streaming:** Return promises directly from load (no `streamed` wrapper)
- **`reroute` hook:** Rewrite URLs before routing
- **Granular `invalidate`:** More specific dependency tracking

### Step-by-Step Upgrade Process

```bash
# 1. Update dependencies
npm install @sveltejs/kit@2 svelte@5 vite@5 @sveltejs/vite-plugin-svelte@4

# 2. Update adapter
npm install @sveltejs/adapter-auto@3  # or your specific adapter

# 3. Run the migration tool
npx sv migrate sveltekit-2

# 4. Fix breaking changes manually
# - Add { path: '/' } to all cookies.set/delete calls
# - Replace resolvePath with resolveRoute
# - Remove `streamed` wrapper from load returns
# - Update $page to page from $app/state (if using Svelte 5)

# 5. Test thoroughly
npm run check
npm run build
npm run test
```

---

## React → SvelteKit Migration

### Component Model Comparison

```jsx
// React component
import { useState, useEffect, useMemo } from 'react';

interface Props {
  title: string;
  count?: number;
  children: React.ReactNode;
  onAction?: (id: string) => void;
}

export function Card({ title, count = 0, children, onAction }: Props) {
  const [isOpen, setIsOpen] = useState(false);
  const doubled = useMemo(() => count * 2, [count]);

  useEffect(() => {
    document.title = title;
    return () => { document.title = 'App'; };
  }, [title]);

  return (
    <div className={`card ${isOpen ? 'open' : ''}`}>
      <h2 onClick={() => setIsOpen(!isOpen)}>{title} ({doubled})</h2>
      {isOpen && <div className="content">{children}</div>}
      <button onClick={() => onAction?.('123')}>Action</button>
    </div>
  );
}
```

```svelte
<!-- Svelte 5 equivalent -->
<script lang="ts">
  import type { Snippet } from 'svelte';

  let { title, count = 0, children, onaction }: {
    title: string;
    count?: number;
    children: Snippet;
    onaction?: (id: string) => void;
  } = $props();

  let isOpen = $state(false);
  let doubled = $derived(count * 2);

  $effect(() => {
    document.title = title;
    return () => { document.title = 'App'; };
  });
</script>

<div class="card" class:open={isOpen}>
  <h2 onclick={() => isOpen = !isOpen}>{title} ({doubled})</h2>
  {#if isOpen}
    <div class="content">{@render children()}</div>
  {/if}
  <button onclick={() => onaction?.('123')}>Action</button>
</div>
```

**Key differences:**
- No JSX — Svelte uses an HTML superset template syntax
- No virtual DOM — Svelte compiles to direct DOM updates
- No hooks rules — runes don't have ordering requirements
- `class:name={condition}` replaces template literal class concatenation
- `{#if}`, `{#each}`, `{#await}` blocks replace JSX conditional rendering
- Styles are scoped by default in `<style>` blocks

### State Management

| React | Svelte 5 | Notes |
|-------|----------|-------|
| `useState(0)` | `let x = $state(0)` | Direct assignment instead of setter |
| `useReducer(reducer, init)` | Class with `$state` | Methods mutate state directly |
| `useMemo(() => x*2, [x])` | `$derived(x * 2)` | Auto-tracked, no dependency array |
| `useCallback(fn, [deps])` | Just use the function | No stale closure issues |
| `useRef(null)` | `let el: HTMLElement` with `bind:this` | For DOM refs |
| `useRef(value)` | Regular `let` variable | For mutable non-reactive refs |
| `useContext` | `getContext`/`setContext` | Called during init, not re-renders |
| `React.createContext` | `setContext(key, value)` | No Provider wrapper needed |
| Redux/Zustand | `.svelte.ts` with `$state` | Module-level reactive state |

```tsx
// React Context + Provider
const ThemeContext = React.createContext('light');

function App() {
  return (
    <ThemeContext.Provider value="dark">
      <Child />
    </ThemeContext.Provider>
  );
}

function Child() {
  const theme = useContext(ThemeContext);
  return <div className={theme}>...</div>;
}
```

```svelte
<!-- Svelte equivalent -->
<!-- App.svelte -->
<script>
  import { setContext } from 'svelte';
  setContext('theme', 'dark');
</script>
<Child />

<!-- Child.svelte -->
<script>
  import { getContext } from 'svelte';
  const theme = getContext<string>('theme');
</script>
<div class={theme}>...</div>
```

### Routing Comparison

| React Router / Tanstack | SvelteKit | Notes |
|------------------------|-----------|-------|
| `<Route path="/blog/:slug">` | `src/routes/blog/[slug]/+page.svelte` | File-based routing |
| `useParams()` | `$props()` via load, or `$page.params` | Params from load function |
| `<Link to="/about">` | `<a href="/about">` | Standard HTML anchors |
| `useNavigate()` | `goto()` from `$app/navigation` | Programmatic navigation |
| `<Navigate to="/login">` | `redirect(303, '/login')` | In load functions |
| `useSearchParams()` | `$page.url.searchParams` | URL search parameters |
| `<Outlet />` | `{@render children()}` in `+layout.svelte` | Nested routes |
| Route guards | `+layout.server.ts` load | Redirect in load function |
| `loader` (React Router) | `+page.server.ts` load | Data loading |

### Data Fetching Equivalents

```tsx
// React — useEffect + useState
function Posts() {
  const [posts, setPosts] = useState<Post[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<Error | null>(null);

  useEffect(() => {
    fetch('/api/posts')
      .then(r => r.json())
      .then(setPosts)
      .catch(setError)
      .finally(() => setLoading(false));
  }, []);

  if (loading) return <div>Loading...</div>;
  if (error) return <div>Error: {error.message}</div>;
  return <ul>{posts.map(p => <li key={p.id}>{p.title}</li>)}</ul>;
}
```

```ts
// SvelteKit — load function (no loading/error state needed)
// src/routes/posts/+page.server.ts
export const load = async ({ fetch }) => {
  const posts = await fetch('/api/posts').then(r => r.json());
  return { posts };
};
```

```svelte
<!-- src/routes/posts/+page.svelte -->
<script>
  let { data } = $props();
</script>
<ul>
  {#each data.posts as post (post.id)}
    <li>{post.title}</li>
  {/each}
</ul>
<!-- Loading and error states handled by SvelteKit automatically -->
```

```tsx
// React Query / SWR pattern
function Posts() {
  const { data, isLoading, error } = useQuery({
    queryKey: ['posts'],
    queryFn: () => fetch('/api/posts').then(r => r.json())
  });
}
```

```ts
// SvelteKit equivalent: load function with invalidation
export const load = async ({ fetch, depends }) => {
  depends('app:posts');
  const posts = await fetch('/api/posts').then(r => r.json());
  return { posts };
};
// Re-fetch: invalidate('app:posts')
```

### Side Effects and Lifecycle

| React | Svelte 5 | Notes |
|-------|----------|-------|
| `useEffect(() => {}, [])` | `onMount(() => {})` | Run once on mount |
| `useEffect(() => {}, [dep])` | `$effect(() => { dep; })` | Auto-tracked dependencies |
| `useEffect(() => cleanup, [])` | `$effect(() => { return cleanup; })` | Cleanup on unmount/re-run |
| `useLayoutEffect` | `$effect.pre()` | Before DOM paint |
| `React.memo()` | N/A (automatic) | Svelte auto-optimizes |
| `useDeferredValue` | N/A | Use `$state.raw` for performance |

### Styling

```tsx
// React — CSS modules, styled-components, Tailwind
import styles from './Card.module.css';
<div className={styles.card}>...</div>

// Or inline styles
<div style={{ backgroundColor: 'red', fontSize: '16px' }}>...</div>
```

```svelte
<!-- Svelte — scoped styles built-in -->
<div class="card">...</div>

<style>
  .card {
    background-color: white;
    border-radius: 8px;
    padding: 1rem;
  }
  /* Styles are automatically scoped to this component */
</style>

<!-- Inline styles also work -->
<div style="background-color: {color}; font-size: 16px;">...</div>
<div style:background-color={color} style:font-size="16px">...</div>
```

### Common Patterns Side by Side

**Conditional rendering:**

```tsx
// React
{isVisible && <Modal />}
{status === 'loading' ? <Spinner /> : <Content />}
```

```svelte
<!-- Svelte -->
{#if isVisible}
  <Modal />
{/if}

{#if status === 'loading'}
  <Spinner />
{:else}
  <Content />
{/if}
```

**List rendering:**

```tsx
// React
{items.map(item => <Item key={item.id} {...item} />)}
```

```svelte
<!-- Svelte -->
{#each items as item (item.id)}
  <Item {...item} />
{/each}
```

**Form handling:**

```tsx
// React
const [email, setEmail] = useState('');
<input value={email} onChange={e => setEmail(e.target.value)} />
```

```svelte
<!-- Svelte -->
<script>
  let email = $state('');
</script>
<input bind:value={email} />
```

**Refs:**

```tsx
// React
const inputRef = useRef<HTMLInputElement>(null);
useEffect(() => { inputRef.current?.focus(); }, []);
<input ref={inputRef} />
```

```svelte
<!-- Svelte -->
<script>
  let inputEl: HTMLInputElement;
  $effect(() => { inputEl?.focus(); });
</script>
<input bind:this={inputEl} />
```

---

## Next.js → SvelteKit Migration

### Architecture Comparison

| Concept | Next.js (App Router) | SvelteKit |
|---------|---------------------|-----------|
| Framework | React-based | Svelte-based |
| Routing | `app/` directory file-based | `src/routes/` file-based |
| Server components | React Server Components | Server load functions |
| Client components | `'use client'` directive | All `.svelte` files (hydrated) |
| API routes | `app/api/route.ts` | `src/routes/api/+server.ts` |
| Middleware | `middleware.ts` (edge) | `hooks.server.ts` (flexible) |
| Data fetching | `fetch` in server components | `load` functions |
| Forms | Server Actions | Form Actions |
| Metadata | `generateMetadata` | `<svelte:head>` |
| Static gen | `generateStaticParams` | `export const prerender = true` |

### Routing Mapping

```
Next.js (App Router)              →    SvelteKit
─────────────────                      ────────
app/page.tsx                           src/routes/+page.svelte
app/about/page.tsx                     src/routes/about/+page.svelte
app/blog/[slug]/page.tsx               src/routes/blog/[slug]/+page.svelte
app/[...slug]/page.tsx                 src/routes/[...slug]/+page.svelte
app/shop/[[...slug]]/page.tsx          src/routes/shop/[[slug]]/+page.svelte
app/layout.tsx                         src/routes/+layout.svelte
app/loading.tsx                        Streaming in +page.server.ts
app/error.tsx                          src/routes/+error.svelte
app/not-found.tsx                      src/routes/+error.svelte (404)
app/(marketing)/page.tsx               src/routes/(marketing)/+page.svelte
app/api/posts/route.ts                 src/routes/api/posts/+server.ts
```

### Data Fetching Migration

```tsx
// Next.js — Server Component with fetch
// app/posts/page.tsx
async function PostsPage() {
  const posts = await fetch('https://api.example.com/posts', {
    next: { revalidate: 60 }
  }).then(r => r.json());

  return (
    <ul>
      {posts.map(post => <li key={post.id}>{post.title}</li>)}
    </ul>
  );
}
export default PostsPage;
```

```ts
// SvelteKit — Server load function
// src/routes/posts/+page.server.ts
export const load = async ({ fetch }) => {
  const posts = await fetch('https://api.example.com/posts').then(r => r.json());
  return { posts };
};
```

```svelte
<!-- src/routes/posts/+page.svelte -->
<script>
  let { data } = $props();
</script>
<ul>
  {#each data.posts as post (post.id)}
    <li>{post.title}</li>
  {/each}
</ul>
```

**Next.js revalidation → SvelteKit invalidation:**

```ts
// Next.js
// revalidatePath('/posts')
// revalidateTag('posts')

// SvelteKit
import { invalidate } from '$app/navigation';
invalidate('/api/posts');
invalidate('app:posts');
```

### API Routes

```ts
// Next.js — app/api/posts/route.ts
import { NextResponse } from 'next/server';

export async function GET(request: Request) {
  const posts = await db.getPosts();
  return NextResponse.json(posts);
}

export async function POST(request: Request) {
  const body = await request.json();
  const post = await db.createPost(body);
  return NextResponse.json(post, { status: 201 });
}
```

```ts
// SvelteKit — src/routes/api/posts/+server.ts
import { json } from '@sveltejs/kit';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = async () => {
  const posts = await db.getPosts();
  return json(posts);
};

export const POST: RequestHandler = async ({ request }) => {
  const body = await request.json();
  const post = await db.createPost(body);
  return json(post, { status: 201 });
};
```

### Middleware → Hooks

```ts
// Next.js — middleware.ts
import { NextResponse } from 'next/server';
import type { NextRequest } from 'next/server';

export function middleware(request: NextRequest) {
  const token = request.cookies.get('session');
  if (!token && request.nextUrl.pathname.startsWith('/dashboard')) {
    return NextResponse.redirect(new URL('/login', request.url));
  }
  return NextResponse.next();
}

export const config = { matcher: ['/dashboard/:path*'] };
```

```ts
// SvelteKit — src/hooks.server.ts
import { redirect, type Handle } from '@sveltejs/kit';

export const handle: Handle = async ({ event, resolve }) => {
  const token = event.cookies.get('session');

  if (token) {
    event.locals.user = await verifyToken(token);
  }

  if (event.url.pathname.startsWith('/dashboard') && !event.locals.user) {
    redirect(303, '/login');
  }

  return resolve(event);
};
```

### Migration Path

**Step-by-step approach for a gradual migration:**

1. **Set up SvelteKit project** alongside existing Next.js app
2. **Migrate static pages first** — about, pricing, docs (easiest)
3. **Migrate layouts** — convert `layout.tsx` to `+layout.svelte`
4. **Migrate data fetching** — server components → server load functions
5. **Migrate API routes** — route handlers → +server.ts
6. **Migrate forms** — server actions → form actions
7. **Migrate auth** — middleware → hooks.server.ts
8. **Migrate state** — React Context/Redux → Svelte runes + context
9. **Migrate tests** — Jest/RTL → Vitest + @testing-library/svelte

**Key mental model shifts:**
- No virtual DOM — updates are compiled, not diffed
- No `use client`/`use server` — separation is via file naming (+page.svelte vs +page.server.ts)
- No `useState` setter functions — just assign directly (`count = 5`)
- No dependency arrays — reactivity is auto-tracked
- No `key` prop for lists — use `(id)` in `{#each}` blocks
- Scoped styles by default — no CSS-in-JS library needed
- Progressive enhancement is a first-class pattern — forms work without JS
