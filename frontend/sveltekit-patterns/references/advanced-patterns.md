# Advanced SvelteKit Patterns

## Table of Contents

- [Svelte 5 Runes In Depth](#svelte-5-runes-in-depth)
  - [$state.raw — Non-Deep Reactivity](#stateraw--non-deep-reactivity)
  - [$state.snapshot — Reading State Snapshots](#statesnapshot--reading-state-snapshots)
  - [Fine-Grained Reactivity](#fine-grained-reactivity)
  - [Class Fields with Runes](#class-fields-with-runes)
- [Advanced Routing](#advanced-routing)
  - [Parameter Matchers](#parameter-matchers)
  - [Layout Groups](#layout-groups)
  - [Breaking Out of Layouts](#breaking-out-of-layouts)
  - [Optional Parameters and Catch-All Routes](#optional-parameters-and-catch-all-routes)
  - [Rest Parameters with Typed Segments](#rest-parameters-with-typed-segments)
- [Streaming with Promises in Load Functions](#streaming-with-promises-in-load-functions)
- [Parallel Data Loading](#parallel-data-loading)
- [Universal vs Server Load Tradeoffs](#universal-vs-server-load-tradeoffs)
- [SvelteKit + tRPC Integration](#sveltekit--trpc-integration)
- [Form Action Progressive Enhancement Deep Dive](#form-action-progressive-enhancement-deep-dive)
- [Snapshot and Restoration](#snapshot-and-restoration)
- [Service Workers](#service-workers)
- [Page Options (ssr/csr/prerender/trailingSlash)](#page-options)
- [Environment Variable Patterns](#environment-variable-patterns)
- [WebSocket Integration](#websocket-integration)

---

## Svelte 5 Runes In Depth

### $state.raw — Non-Deep Reactivity

`$state()` creates deeply reactive proxies — every nested property is tracked. This is
expensive for large objects where you replace rather than mutate:

```svelte
<script lang="ts">
  // Deep reactivity: every property access is proxied
  let items = $state<Item[]>([]);

  // Raw: only reassignment triggers updates, not mutation
  let items = $state.raw<Item[]>([]);

  // Mutation does NOT trigger re-render with $state.raw:
  items.push(newItem); // ❌ No update

  // Reassignment DOES trigger:
  items = [...items, newItem]; // ✅ Triggers update
</script>
```

**When to use `$state.raw`:**
- Large arrays (100+ items) that are replaced wholesale from API responses
- Objects from external libraries that shouldn't be proxied (e.g., D3 selections, map instances)
- Immutable data patterns where you always create new references
- Performance-critical paths where proxy overhead is measurable

**When NOT to use:**
- Small objects/arrays with frequent in-place mutation
- Form state that users interactively edit
- Any state where deep mutation is the natural update pattern

```ts
// src/lib/stores/table-data.svelte.ts
// Pattern: raw state with immutable updates for large datasets
let rows = $state.raw<TableRow[]>([]);
let sortColumn = $state<string>('id');
let sortDirection = $state<'asc' | 'desc'>('asc');

export function setRows(newRows: TableRow[]) {
  rows = newRows; // triggers update
}

export function sortBy(column: string) {
  sortColumn = column;
  sortDirection = sortDirection === 'asc' ? 'desc' : 'asc';
  // Create new array reference to trigger update
  rows = [...rows].sort((a, b) => {
    const cmp = a[column] < b[column] ? -1 : a[column] > b[column] ? 1 : 0;
    return sortDirection === 'asc' ? cmp : -cmp;
  });
}

export function getRows() { return rows; }
export function getSortColumn() { return sortColumn; }
export function getSortDirection() { return sortDirection; }
```

### $state.snapshot — Reading State Snapshots

`$state.snapshot()` creates a plain (non-reactive) deep clone of reactive state. Essential
when passing state to external libraries or APIs that don't understand Svelte proxies:

```svelte
<script lang="ts">
  let formData = $state({
    name: '',
    tags: ['svelte'],
    address: { street: '', city: '' }
  });

  async function submit() {
    // ❌ Sending reactive proxy — may serialize incorrectly
    await fetch('/api', { body: JSON.stringify(formData) });

    // ✅ Send a plain object snapshot
    const snapshot = $state.snapshot(formData);
    await fetch('/api', { body: JSON.stringify(snapshot) });
  }

  function logState() {
    // ❌ Console may show stale/proxy data
    console.log(formData);
    // ✅ See current plain values
    console.log($state.snapshot(formData));
  }
</script>
```

**Key use cases:**
- Sending state to `fetch()`, `localStorage`, `postMessage`, or `structuredClone`
- Comparing previous/current state for change detection
- Passing to third-party libraries (chart libs, form validators) that inspect objects
- Debugging — `$inspect` uses snapshots internally

```ts
// Change detection pattern
let previous = $state.snapshot(formData);

function hasChanges(): boolean {
  const current = $state.snapshot(formData);
  return JSON.stringify(previous) !== JSON.stringify(current);
}
```

### Fine-Grained Reactivity

Svelte 5's reactivity is fine-grained at the property level. Understanding granularity
helps optimize rendering:

```svelte
<script lang="ts">
  let user = $state({ name: 'Alice', avatar: '/alice.png', bio: 'Developer' });

  // Only re-renders when user.name changes, not user.avatar or user.bio
  let greeting = $derived(`Hello, ${user.name}!`);
</script>

<!-- This text node only updates when user.name changes -->
<h1>{user.name}</h1>

<!-- This img only updates when user.avatar changes -->
<img src={user.avatar} alt={user.name} />
```

**Array fine-grained reactivity:**

```svelte
<script lang="ts">
  let todos = $state([
    { id: 1, text: 'Learn Svelte', done: false },
    { id: 2, text: 'Build app', done: false }
  ]);
</script>

<!-- Only the changed todo re-renders when you toggle done -->
{#each todos as todo (todo.id)}
  <label>
    <input type="checkbox" bind:checked={todo.done} />
    {todo.text}
  </label>
{/each}
```

**Keyed each blocks** (`(todo.id)`) are critical: without keys, Svelte may re-render the
entire list on any change.

### Class Fields with Runes

Runes work in class fields, enabling encapsulated reactive state:

```ts
// src/lib/models/counter.svelte.ts
export class Counter {
  count = $state(0);
  doubled = $derived(this.count * 2);

  increment() {
    this.count++;
  }

  decrement() {
    this.count--;
  }

  reset() {
    this.count = 0;
  }
}
```

```svelte
<script lang="ts">
  import { Counter } from '$lib/models/counter.svelte';

  const counter = new Counter();
</script>

<button onclick={() => counter.increment()}>
  {counter.count} (doubled: {counter.doubled})
</button>
```

**Complex class pattern with private state:**

```ts
// src/lib/models/todo-list.svelte.ts
export class TodoList {
  #todos = $state<Todo[]>([]);
  #filter = $state<'all' | 'active' | 'completed'>('all');

  filtered = $derived.by(() => {
    switch (this.#filter) {
      case 'active': return this.#todos.filter(t => !t.done);
      case 'completed': return this.#todos.filter(t => t.done);
      default: return this.#todos;
    }
  });

  remaining = $derived(this.#todos.filter(t => !t.done).length);

  add(text: string) {
    this.#todos.push({ id: crypto.randomUUID(), text, done: false });
  }

  toggle(id: string) {
    const todo = this.#todos.find(t => t.id === id);
    if (todo) todo.done = !todo.done;
  }

  setFilter(filter: 'all' | 'active' | 'completed') {
    this.#filter = filter;
  }
}
```

---

## Advanced Routing

### Parameter Matchers

Restrict route params to specific patterns by defining matchers:

```ts
// src/params/integer.ts
import type { ParamMatcher } from '@sveltejs/kit';

export const match: ParamMatcher = (param) => {
  return /^\d+$/.test(param);
};
```

```ts
// src/params/uuid.ts
import type { ParamMatcher } from '@sveltejs/kit';

export const match: ParamMatcher = (param) => {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(param);
};
```

Use in route filenames: `src/routes/posts/[id=integer]/+page.svelte` — only matches
if `id` passes the `integer` matcher. Non-matching params fall through to other routes
or 404.

```
src/routes/
├── items/[id=integer]/+page.svelte    → /items/42 ✅, /items/abc ❌
├── items/[slug]/+page.svelte          → /items/abc ✅ (fallback)
└── users/[id=uuid]/+page.svelte       → /users/550e8400-... ✅
```

### Layout Groups

Group routes to share layouts without affecting URL paths:

```
src/routes/
├── (marketing)/           → Layout for marketing pages
│   ├── +layout.svelte     → Full-width, flashy header
│   ├── +page.svelte       → / (homepage)
│   ├── pricing/+page.svelte → /pricing
│   └── about/+page.svelte → /about
├── (app)/                 → Layout for app pages
│   ├── +layout.svelte     → Sidebar nav, compact header
│   ├── dashboard/+page.svelte → /dashboard
│   └── settings/+page.svelte → /settings
└── (auth)/                → Layout for auth pages
    ├── +layout.svelte     → Centered card, no nav
    ├── login/+page.svelte → /login
    └── register/+page.svelte → /register
```

Each group has its own `+layout.svelte`, `+layout.server.ts`, `+error.svelte`,
and `+layout.ts`. Groups can also have `+page.svelte` if a group represents
the root route (only one group can claim `/`).

### Breaking Out of Layouts

Reset layout inheritance with the `@` notation:

```
src/routes/
├── +layout.svelte              → Root layout (A)
├── (app)/
│   ├── +layout.svelte          → App layout (B)
│   ├── dashboard/
│   │   ├── +page.svelte        → Uses A → B (normal)
│   │   └── embed/
│   │       └── +page@.svelte   → Uses ONLY root layout (A), skips B
│   └── settings/
│       └── +page@(app).svelte  → Uses A → B (explicit, same as default)
```

- `+page@.svelte` — resets to root layout (skips all intermediate layouts)
- `+page@(group).svelte` — resets to a specific group's layout
- Works on `+layout@.svelte` too, for nested layout resets

### Optional Parameters and Catch-All Routes

```
src/routes/
├── blog/[[lang]]/+page.svelte      → /blog or /blog/en
├── docs/[...path]/+page.svelte     → /docs/a/b/c (rest param)
```

```ts
// +page.ts for [[lang]] optional param
export const load = async ({ params }) => {
  const lang = params.lang ?? 'en'; // defaults to 'en' if not provided
  return { lang };
};
```

```ts
// +page.ts for [...path] rest param
export const load = async ({ params }) => {
  const segments = params.path?.split('/') ?? [];
  return { segments };
};
```

### Rest Parameters with Typed Segments

Combine matchers with rest params for complex routing:

```ts
// src/routes/files/[...path]/+page.server.ts
export const load = async ({ params }) => {
  const path = params.path; // e.g., "docs/2024/report.pdf"
  const segments = path.split('/');
  const filename = segments.pop();
  const directory = segments.join('/');
  return { directory, filename };
};
```

---

## Streaming with Promises in Load Functions

Return unresolved promises from load functions to stream data progressively:

```ts
// src/routes/dashboard/+page.server.ts
export const load = async ({ locals }) => {
  // Fast data — awaited, blocks render
  const user = await db.getUser(locals.userId);

  // Slow data — NOT awaited, streams in later
  const recommendations = db.getRecommendations(locals.userId);
  const analytics = db.getAnalytics(locals.userId);

  return {
    user,                  // Available immediately
    recommendations,       // Promise — streams when resolved
    analytics              // Promise — streams when resolved
  };
};
```

```svelte
<!-- +page.svelte -->
<script lang="ts">
  let { data } = $props();
</script>

<h1>Welcome, {data.user.name}</h1>

{#await data.recommendations}
  <div class="skeleton">Loading recommendations...</div>
{:then recommendations}
  <RecommendationList items={recommendations} />
{:catch error}
  <p>Failed to load recommendations: {error.message}</p>
{/await}

{#await data.analytics}
  <div class="skeleton">Loading analytics...</div>
{:then analytics}
  <AnalyticsChart data={analytics} />
{:catch}
  <p>Analytics unavailable</p>
{/await}
```

**Important:** Only server load functions (`+page.server.ts`) support true streaming.
Universal load functions resolve all promises before sending data to the client.

---

## Parallel Data Loading

SvelteKit runs all load functions for a route tree in parallel by default. Layout and
page loads execute simultaneously:

```ts
// src/routes/(app)/+layout.server.ts
export const load = async ({ locals }) => {
  const user = await db.getUser(locals.userId);    // Runs in parallel with page load
  return { user };
};

// src/routes/(app)/dashboard/+page.server.ts
export const load = async ({ locals }) => {
  const stats = await db.getDashboardStats();       // Runs in parallel with layout load
  return { stats };
};
```

**Avoid waterfalls in a single load function with `Promise.all`:**

```ts
// ❌ Sequential — total time = sum of all fetches
export const load = async ({ fetch }) => {
  const posts = await fetch('/api/posts').then(r => r.json());
  const comments = await fetch('/api/comments').then(r => r.json());
  const tags = await fetch('/api/tags').then(r => r.json());
  return { posts, comments, tags };
};

// ✅ Parallel — total time = slowest fetch
export const load = async ({ fetch }) => {
  const [posts, comments, tags] = await Promise.all([
    fetch('/api/posts').then(r => r.json()),
    fetch('/api/comments').then(r => r.json()),
    fetch('/api/tags').then(r => r.json())
  ]);
  return { posts, comments, tags };
};
```

**Using `parent()` carefully:**

```ts
// Calling parent() creates a waterfall — layout must finish before page runs
export const load = async ({ parent }) => {
  const { user } = await parent();  // ⚠️ Waits for layout load to complete
  const profile = await db.getProfile(user.id);
  return { profile };
};

// Better: access user ID from locals instead of parent()
export const load = async ({ locals }) => {
  const profile = await db.getProfile(locals.userId);
  return { profile };
};
```

---

## Universal vs Server Load Tradeoffs

| Aspect | Universal (`+page.ts`) | Server (`+page.server.ts`) |
|--------|----------------------|---------------------------|
| Runs where | Server (SSR) + Client (navigation) | Server only |
| Direct DB/secret access | ❌ No | ✅ Yes |
| Return non-serializable data | ✅ Functions, classes, components | ❌ Must be JSON-serializable |
| Streaming promises | ❌ All resolved before send | ✅ True streaming |
| Client-side caching | ✅ Cached after first run | ❌ Always fetches from server |
| Bundle size impact | ⚠️ Load code shipped to client | ✅ Never in client bundle |
| `fetch` behavior | Uses SvelteKit's `fetch` | Uses SvelteKit's `fetch` |

**Use universal load when:**
- Returning component constructors, functions, or non-serializable data
- Data comes from a public API and can run client-side on navigation
- You want client-side caching of load results

**Use server load when:**
- Accessing databases, file system, or secrets
- You need streaming for slow data
- You want to keep load logic out of the client bundle
- Working with cookies or server-only auth tokens

```ts
// Universal: returning a component based on data
// +page.ts
export const load = async ({ fetch }) => {
  const { type } = await fetch('/api/widget-type').then(r => r.json());
  const Widget = type === 'chart'
    ? (await import('$lib/widgets/Chart.svelte')).default
    : (await import('$lib/widgets/Table.svelte')).default;
  return { Widget };
};
```

---

## SvelteKit + tRPC Integration

Use `trpc-sveltekit` to integrate tRPC with SvelteKit:

```bash
npm install @trpc/server @trpc/client trpc-sveltekit
```

```ts
// src/lib/server/trpc/router.ts
import { initTRPC } from '@trpc/server';
import type { Context } from './context';
import { z } from 'zod';

const t = initTRPC.context<Context>().create();

export const router = t.router({
  greeting: t.procedure
    .input(z.object({ name: z.string() }))
    .query(({ input }) => `Hello, ${input.name}!`),

  posts: t.router({
    list: t.procedure.query(async () => {
      return db.post.findMany();
    }),
    create: t.procedure
      .input(z.object({ title: z.string(), content: z.string() }))
      .mutation(async ({ input }) => {
        return db.post.create({ data: input });
      })
  })
});

export type AppRouter = typeof router;
```

```ts
// src/lib/server/trpc/context.ts
import type { RequestEvent } from '@sveltejs/kit';

export async function createContext(event: RequestEvent) {
  return { user: event.locals.user };
}

export type Context = Awaited<ReturnType<typeof createContext>>;
```

```ts
// src/hooks.server.ts
import { createTRPCHandle } from 'trpc-sveltekit';
import { router } from '$lib/server/trpc/router';
import { createContext } from '$lib/server/trpc/context';

export const handle = createTRPCHandle({ router, createContext, url: '/api/trpc' });
```

```ts
// src/lib/trpc/client.ts
import { createTRPCProxyClient, httpBatchLink } from '@trpc/client';
import type { AppRouter } from '$lib/server/trpc/router';

export const trpc = createTRPCProxyClient<AppRouter>({
  links: [httpBatchLink({ url: '/api/trpc' })]
});
```

```svelte
<!-- +page.svelte -->
<script lang="ts">
  import { trpc } from '$lib/trpc/client';

  let greeting = $state('');

  async function fetchGreeting() {
    greeting = await trpc.greeting.query({ name: 'World' });
  }
</script>
```

---

## Form Action Progressive Enhancement Deep Dive

### Custom `use:enhance` Callbacks

The `enhance` action accepts a submit callback that returns an update callback:

```svelte
<script lang="ts">
  import { enhance } from '$app/forms';
  import { invalidateAll } from '$app/navigation';

  let submitting = $state(false);
  let optimisticItems = $state<Item[]>([]);

  let { data, form } = $props();
</script>

<form
  method="POST"
  action="?/create"
  use:enhance={({ formData, cancel }) => {
    // BEFORE submit — validate, show optimistic UI, or cancel
    const title = formData.get('title') as string;
    if (!title.trim()) {
      cancel(); // Prevents submission
      return;
    }

    submitting = true;

    // Optimistic update
    const tempItem = { id: `temp-${Date.now()}`, title, pending: true };
    optimisticItems = [...optimisticItems, tempItem];

    return async ({ result, update }) => {
      // AFTER submit — handle result
      submitting = false;

      if (result.type === 'success') {
        // Default update: rerun load functions, update form prop
        await update();
        optimisticItems = [];
      } else if (result.type === 'failure') {
        // Remove optimistic item on failure
        optimisticItems = optimisticItems.filter(i => i.id !== tempItem.id);
        await update(); // Updates form prop with validation errors
      } else if (result.type === 'redirect') {
        // update() handles redirects automatically
        await update();
      } else if (result.type === 'error') {
        // Unexpected error
        optimisticItems = optimisticItems.filter(i => i.id !== tempItem.id);
        await update();
      }
    };
  }}
>
  <input name="title" />
  <button disabled={submitting}>{submitting ? 'Saving...' : 'Create'}</button>
</form>
```

### applyAction vs update

```ts
import { applyAction, deserialize } from '$app/forms';

// update() — re-runs all load functions and updates the page
// applyAction() — applies a result without re-running loads

return async ({ result, update }) => {
  // update({ reset: false }) — prevents form from resetting after success
  await update({ reset: false });

  // applyAction(result) — apply result manually (no load re-run)
  await applyAction(result);
};
```

### File uploads with progress

```svelte
<script lang="ts">
  let progress = $state(0);
</script>

<form
  method="POST"
  action="?/upload"
  enctype="multipart/form-data"
  use:enhance={({ formData }) => {
    // For progress tracking, use XHR instead of default fetch
    return async ({ result, update }) => {
      await update();
    };
  }}
>
  <input type="file" name="avatar" accept="image/*" />
  <button>Upload</button>
</form>
```

---

## Snapshot and Restoration

Preserve ephemeral UI state (scroll position, form inputs) across navigations:

```svelte
<!-- +page.svelte -->
<script lang="ts">
  import type { Snapshot } from './$types';

  let searchQuery = $state('');
  let selectedTab = $state(0);
  let scrollY = $state(0);

  export const snapshot: Snapshot<{
    searchQuery: string;
    selectedTab: number;
    scrollY: number;
  }> = {
    capture: () => ({
      searchQuery,
      selectedTab,
      scrollY: window.scrollY
    }),
    restore: (value) => {
      searchQuery = value.searchQuery;
      selectedTab = value.selectedTab;
      // Restore scroll after DOM update
      tick().then(() => window.scrollTo(0, value.scrollY));
    }
  };
</script>
```

**Snapshot data must be JSON-serializable.** It's stored in the browser's session
history via `history.state`. Snapshots persist across back/forward navigation
but NOT across page reloads.

---

## Service Workers

SvelteKit generates a service worker entry point at `src/service-worker.ts`:

```ts
/// <reference types="@sveltejs/kit" />
/// <reference no-default-lib="true"/>
/// <reference lib="esnext" />
/// <reference lib="webworker" />

import { build, files, version } from '$service-worker';

const CACHE_NAME = `cache-${version}`;
const ASSETS = [...build, ...files];

// Install: cache all static assets
self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => cache.addAll(ASSETS))
  );
});

// Activate: clean up old caches
self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((key) => key !== CACHE_NAME).map((key) => caches.delete(key)))
    )
  );
});

// Fetch: serve from cache, falling back to network
self.addEventListener('fetch', (event) => {
  if (event.request.method !== 'GET') return;

  event.respondWith(
    caches.match(event.request).then((cached) => {
      return cached || fetch(event.request);
    })
  );
});
```

**Available imports from `$service-worker`:**
- `build` — array of URLs for built app files (JS, CSS)
- `files` — array of URLs from `static/` directory
- `version` — unique build identifier (changes each build)
- `base` — the `config.kit.paths.base` value

---

## Page Options

Control rendering behavior per-page or per-layout:

```ts
// +page.ts or +layout.ts
export const ssr = true;                // Server-side render (default: true)
export const csr = true;                // Client-side render/hydrate (default: true)
export const prerender = false;         // Static generate at build (default: false)
export const trailingSlash = 'never';   // 'always' | 'never' | 'ignore'
```

**Combinations and their effects:**

| ssr | csr | Result |
|-----|-----|--------|
| true | true | Full SSR + hydration (default). Best for SEO + interactivity |
| true | false | SSR only, no JS sent. Static HTML, no interactivity |
| false | true | SPA mode. Loading spinner until JS loads |
| false | false | ❌ Nothing renders |

**Prerender behavior:**

```ts
// Prerender specific pages
export const prerender = true;

// Prerender with dynamic entries
export const entries = ['/blog/first-post', '/blog/second-post'];
export const prerender = true;

// Generate entries programmatically
export async function entries() {
  const posts = await db.getAllSlugs();
  return posts.map(slug => ({ slug }));
}
```

**Layout-level options cascade to all child routes:**

```ts
// src/routes/(static)/+layout.ts
export const prerender = true;  // All routes in (static) group are prerendered

// Individual pages can override:
// src/routes/(static)/contact/+page.ts
export const prerender = false; // This specific page is not prerendered
```

---

## Environment Variable Patterns

### Static vs Dynamic: Choosing the Right Module

```ts
// STATIC: Inlined at build time. Dead code elimination works. Best performance.
import { DATABASE_URL } from '$env/static/private';     // Server only
import { PUBLIC_API_URL } from '$env/static/public';     // Client safe

// DYNAMIC: Read at runtime. For pre-built Docker images across environments.
import { env } from '$env/dynamic/private';              // env.DATABASE_URL
import { env } from '$env/dynamic/public';               // env.PUBLIC_API_URL
```

### Docker/CI Pattern

```ts
// Use dynamic env for values that change per deployment
// src/lib/server/config.ts
import { env } from '$env/dynamic/private';

export const config = {
  databaseUrl: env.DATABASE_URL ?? 'postgresql://localhost:5432/dev',
  redisUrl: env.REDIS_URL ?? 'redis://localhost:6379',
  apiSecret: env.API_SECRET ?? (() => { throw new Error('API_SECRET required'); })()
};
```

### Type-safe environment variables

```ts
// src/app.d.ts — declare expected env vars for type checking
declare module '$env/static/private' {
  export const DATABASE_URL: string;
  export const JWT_SECRET: string;
}

declare module '$env/static/public' {
  export const PUBLIC_API_URL: string;
  export const PUBLIC_SITE_NAME: string;
}
```

---

## WebSocket Integration

SvelteKit doesn't natively support WebSocket upgrade, but you can integrate via
the underlying Vite dev server and the Node adapter:

### Development (Vite Plugin)

```ts
// vite.config.ts
import { sveltekit } from '@sveltejs/kit/vite';
import { defineConfig } from 'vite';
import { WebSocketServer } from 'ws';

export default defineConfig({
  plugins: [
    sveltekit(),
    {
      name: 'websocket',
      configureServer(server) {
        const wss = new WebSocketServer({ noServer: true });

        server.httpServer?.on('upgrade', (request, socket, head) => {
          if (request.url === '/ws') {
            wss.handleUpgrade(request, socket, head, (ws) => {
              wss.emit('connection', ws, request);
            });
          }
        });

        wss.on('connection', (ws) => {
          ws.on('message', (data) => {
            const msg = JSON.parse(data.toString());
            // Broadcast to all clients
            wss.clients.forEach((client) => {
              if (client.readyState === 1) {
                client.send(JSON.stringify(msg));
              }
            });
          });
        });
      }
    }
  ]
});
```

### Production (Node Adapter)

```ts
// server.js — custom Node server wrapping SvelteKit
import { handler } from './build/handler.js';
import express from 'express';
import { createServer } from 'http';
import { WebSocketServer } from 'ws';

const app = express();
const server = createServer(app);
const wss = new WebSocketServer({ server, path: '/ws' });

wss.on('connection', (ws) => {
  ws.on('message', (data) => {
    wss.clients.forEach((client) => {
      if (client.readyState === 1) client.send(data.toString());
    });
  });
});

app.use(handler);
server.listen(3000);
```

### Client-Side WebSocket with Runes

```svelte
<script lang="ts">
  let messages = $state<string[]>([]);
  let input = $state('');
  let ws: WebSocket | null = $state(null);
  let connected = $state(false);

  $effect(() => {
    const socket = new WebSocket(`ws://${location.host}/ws`);
    socket.onopen = () => { connected = true; };
    socket.onclose = () => { connected = false; };
    socket.onmessage = (event) => {
      messages = [...messages, event.data];
    };
    ws = socket;

    return () => socket.close();
  });

  function send() {
    if (ws && input.trim()) {
      ws.send(JSON.stringify({ text: input }));
      input = '';
    }
  }
</script>

<div class="chat">
  <div class="status">{connected ? '🟢 Connected' : '🔴 Disconnected'}</div>
  <div class="messages">
    {#each messages as msg}
      <p>{msg}</p>
    {/each}
  </div>
  <form onsubmit={(e) => { e.preventDefault(); send(); }}>
    <input bind:value={input} placeholder="Type a message..." />
    <button disabled={!connected}>Send</button>
  </form>
</div>
```

### Alternative: Server-Sent Events (SSE)

For server-to-client streaming, SSE is simpler and works with all SvelteKit adapters:

```ts
// src/routes/api/events/+server.ts
import type { RequestHandler } from './$types';

export const GET: RequestHandler = async ({ locals }) => {
  const stream = new ReadableStream({
    start(controller) {
      const encoder = new TextEncoder();
      const interval = setInterval(() => {
        const data = JSON.stringify({ time: Date.now() });
        controller.enqueue(encoder.encode(`data: ${data}\n\n`));
      }, 1000);

      return () => clearInterval(interval);
    }
  });

  return new Response(stream, {
    headers: {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache',
      'Connection': 'keep-alive'
    }
  });
};
```

```svelte
<script lang="ts">
  let events = $state<string[]>([]);

  $effect(() => {
    const source = new EventSource('/api/events');
    source.onmessage = (event) => {
      events = [...events, event.data];
    };
    return () => source.close();
  });
</script>
```
