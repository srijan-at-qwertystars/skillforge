# SvelteKit Advanced Patterns

## Table of Contents

- [Svelte 5 Runes Deep Dive](#svelte-5-runes-deep-dive)
- [Component Composition](#component-composition)
- [Advanced Load Patterns](#advanced-load-patterns)
- [Service Workers](#service-workers)
- [Shallow Routing](#shallow-routing)
- [Preloading Strategies](#preloading-strategies)
- [Content Negotiation](#content-negotiation)
- [WebSocket Integration](#websocket-integration)
- [Real-Time Updates](#real-time-updates)

---

## Svelte 5 Runes Deep Dive

### $state.raw — Non-Proxied State

Use `$state.raw` when deep reactivity is unnecessary (large arrays, immutable data, external library objects). Values are not wrapped in a proxy; only reassignment triggers updates.

```svelte
<script>
  // Large dataset — avoid deep proxy overhead
  let rows = $state.raw(fetchLargeDataset());

  function updateRows(newRows) {
    rows = newRows; // reassignment triggers update
  }

  // Objects from external libs that break with proxies
  let map = $state.raw(new Map());
  function addEntry(k, v) {
    const next = new Map(map);
    next.set(k, v);
    map = next;
  }
</script>
```

**When to use:** Immutable data patterns, library objects (D3 scales, Map/Set), datasets >1k items, objects with getters/setters that break under proxying.

### $state.snapshot — Read the Underlying Value

`$state.snapshot` strips the proxy and returns a plain object. Essential for serialization, logging, or passing state to non-Svelte code.

```svelte
<script>
  let form = $state({ name: '', email: '' });

  function submit() {
    const plain = $state.snapshot(form);
    console.log(plain);              // plain object, no proxy
    localStorage.setItem('draft', JSON.stringify(plain));
    fetch('/api/submit', { method: 'POST', body: JSON.stringify(plain) });
  }

  // structuredClone works too but $state.snapshot is more explicit
</script>
```

### $effect.pre — Before DOM Update

Runs before the DOM is updated. Use for measuring DOM state that will change, scrolling adjustments, or preparing data that the render depends on.

```svelte
<script>
  let messages = $state([]);
  let container;

  $effect.pre(() => {
    // Measure scroll position before new messages shift layout
    if (container) {
      const isAtBottom = container.scrollTop + container.clientHeight >= container.scrollHeight - 20;
      if (isAtBottom) {
        // Schedule scroll-to-bottom after DOM updates
        tick().then(() => container.scrollTo(0, container.scrollHeight));
      }
    }
  });
</script>

<div bind:this={container} class="messages">
  {#each messages as msg}
    <p>{msg.text}</p>
  {/each}
</div>
```

### $effect.root — Detached Effect Scope

Creates an effect scope not tied to component lifecycle. Returns a cleanup function. Use for global subscriptions or effects managed outside components.

```ts
// src/lib/analytics.svelte.ts
export function trackPageViews() {
  const cleanup = $effect.root(() => {
    $effect(() => {
      const url = window.location.pathname;
      analytics.track('pageview', { url });
    });
  });
  // Call cleanup() when done
  return cleanup;
}
```

---

## Component Composition

### Snippets (Replacing Slots)

Snippets replace slots in Svelte 5. They are typed, composable, and can be passed as props.

```svelte
<!-- Card.svelte -->
<script>
  import type { Snippet } from 'svelte';
  let { header, children, footer }: {
    header: Snippet;
    children: Snippet;
    footer?: Snippet<[{ close: () => void }]>;
  } = $props();
</script>

<div class="card">
  <div class="card-header">{@render header()}</div>
  <div class="card-body">{@render children()}</div>
  {#if footer}
    <div class="card-footer">{@render footer({ close: () => dialog.close() })}</div>
  {/if}
</div>
```

```svelte
<!-- Usage -->
<Card>
  {#snippet header()}
    <h2>Title</h2>
  {/snippet}
  <p>Body content (children snippet)</p>
  {#snippet footer(props)}
    <button onclick={props.close}>Close</button>
  {/snippet}
</Card>
```

### Render Delegation Pattern

```svelte
<!-- DataTable.svelte -->
<script>
  import type { Snippet } from 'svelte';
  let { data, row }: { data: any[]; row: Snippet<[any, number]> } = $props();
</script>

<table>
  <tbody>
    {#each data as item, i}
      <tr>{@render row(item, i)}</tr>
    {/each}
  </tbody>
</table>
```

### Compound Components with Context

```svelte
<!-- Tabs.svelte -->
<script>
  import { setContext } from 'svelte';
  let { children } = $props();
  let activeTab = $state(0);
  setContext('tabs', {
    get active() { return activeTab; },
    setActive(i) { activeTab = i; }
  });
</script>
<div class="tabs">{@render children()}</div>
```

```svelte
<!-- Tab.svelte -->
<script>
  import { getContext } from 'svelte';
  let { index, children } = $props();
  const tabs = getContext('tabs');
</script>
<button class:active={tabs.active === index} onclick={() => tabs.setActive(index)}>
  {@render children()}
</button>
```

---

## Advanced Load Patterns

### Streaming with Promises

Return promises in load to stream data — the page renders immediately with available data while slow parts resolve.

```ts
// +page.server.ts
export const load: PageServerLoad = async ({ params }) => {
  return {
    fast: await db.getPost(params.id),       // awaited — available immediately
    comments: db.getComments(params.id),      // NOT awaited — streams in
    related: db.getRelatedPosts(params.id)    // NOT awaited — streams in
  };
};
```

```svelte
<!-- +page.svelte -->
<script>
  let { data } = $props();
</script>

<h1>{data.fast.title}</h1>

{#await data.comments}
  <p>Loading comments...</p>
{:then comments}
  {#each comments as c}<p>{c.body}</p>{/each}
{:catch error}
  <p>Failed to load comments</p>
{/await}
```

### Parallel Data Loading

```ts
// +page.server.ts
export const load: PageServerLoad = async ({ fetch }) => {
  const [users, posts, stats] = await Promise.all([
    fetch('/api/users').then(r => r.json()),
    fetch('/api/posts').then(r => r.json()),
    fetch('/api/stats').then(r => r.json())
  ]);
  return { users, posts, stats };
};
```

### Invalidation and Rerunning Loads

```svelte
<script>
  import { invalidate, invalidateAll } from '$app/navigation';

  async function refresh() {
    await invalidate('app:posts');   // rerun loads that depend on 'app:posts'
  }
  async function refreshAll() {
    await invalidateAll();           // rerun ALL active loads
  }
</script>
```

```ts
// +page.server.ts
export const load: PageServerLoad = async ({ depends }) => {
  depends('app:posts');              // register custom dependency
  return { posts: await db.getPosts() };
};
```

### Shared Load Data (Parent Access)

```ts
// +page.ts
export const load: PageLoad = async ({ parent }) => {
  const { user } = await parent();   // access parent layout load data
  return { userPosts: await fetchPosts(user.id) };
};
```

**Caution:** `await parent()` creates a waterfall. Only use when you genuinely need the parent's data.

---

## Service Workers

Create `src/service-worker.ts` (or `.js`) — SvelteKit registers it automatically.

```ts
// src/service-worker.ts
/// <reference types="@sveltejs/kit" />
/// <reference no-default-lib="true"/>
/// <reference lib="esnext" />
/// <reference lib="webworker" />
import { build, files, version } from '$service-worker';

const CACHE = `cache-${version}`;
const ASSETS = [...build, ...files];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE).then((cache) => cache.addAll(ASSETS))
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then(async (keys) => {
      for (const key of keys) {
        if (key !== CACHE) await caches.delete(key);
      }
    })
  );
});

self.addEventListener('fetch', (event) => {
  if (event.request.method !== 'GET') return;
  event.respondWith(
    caches.match(event.request).then((cached) => cached || fetch(event.request))
  );
});
```

---

## Shallow Routing

Update the URL without triggering navigation or rerunning load functions. Useful for modals, filters, tab state.

```svelte
<script>
  import { pushState, replaceState } from '$app/navigation';
  import { page } from '$app/state';

  function openModal(item) {
    pushState(`/items/${item.id}`, { showModal: true, item });
  }

  function closeModal() {
    history.back();
  }
</script>

{#if page.state.showModal}
  <Modal item={page.state.item} onclose={closeModal} />
{/if}
```

**Key rules:** State must be serializable (or use the state parameter). Only affects the current page — doesn't run load functions.

---

## Preloading Strategies

### data-sveltekit-preload-data

Preloads data (runs load functions) on hover/tap:

```svelte
<a href="/blog/post-1" data-sveltekit-preload-data="hover">Read post</a>
```

Values: `"hover"` (default on `<body>`), `"tap"`, `"off"`.

### data-sveltekit-preload-code

Preloads only the JavaScript (not data):

```svelte
<a href="/about" data-sveltekit-preload-code="eager">About</a>
```

Values: `"eager"` (immediately), `"viewport"` (when visible), `"hover"`, `"tap"`, `"off"`.

### Programmatic Preloading

```ts
import { preloadData, preloadCode } from '$app/navigation';
await preloadData('/dashboard');   // preload data + code
await preloadCode('/settings');    // preload code only
```

---

## Content Negotiation

A single route can serve different content types based on the Accept header:

```ts
// src/routes/posts/[id]/+server.ts
import { json } from '@sveltejs/kit';

export const GET: RequestHandler = async ({ params, request }) => {
  const post = await db.getPost(params.id);
  const accept = request.headers.get('accept') ?? '';

  if (accept.includes('application/json')) {
    return json(post);
  }

  // Return HTML for browsers
  return new Response(renderHTML(post), {
    headers: { 'Content-Type': 'text/html' }
  });
};
```

When a route has both `+page.svelte` and `+server.ts`, SvelteKit routes GET requests to the page (HTML) or the endpoint (JSON/other) based on the Accept header.

---

## WebSocket Integration

SvelteKit doesn't provide built-in WebSocket support. Attach to the server via the adapter or use a separate WS server.

### With adapter-node

```ts
// src/hooks.server.ts
import type { Handle } from '@sveltejs/kit';
import { WebSocketServer } from 'ws';
import { server } from '$app/server'; // not yet stable — use vite plugin

// Alternative: attach in vite.config.ts plugin
export default {
  plugins: [
    sveltekit(),
    {
      name: 'websocket',
      configureServer(server) {
        const wss = new WebSocketServer({ server: server.httpServer });
        wss.on('connection', (ws) => {
          ws.on('message', (data) => {
            wss.clients.forEach((client) => client.send(data));
          });
        });
      }
    }
  ]
};
```

### Client-Side Connection

```svelte
<script>
  let messages = $state([]);
  let ws;

  $effect(() => {
    ws = new WebSocket(`ws://${location.host}/ws`);
    ws.onmessage = (e) => messages.push(JSON.parse(e.data));
    ws.onclose = () => setTimeout(() => ws = new WebSocket(ws.url), 1000);
    return () => ws?.close();
  });

  function send(msg) {
    ws?.send(JSON.stringify(msg));
  }
</script>
```

---

## Real-Time Updates

### Server-Sent Events (SSE)

Simpler than WebSockets for server-to-client streaming:

```ts
// src/routes/api/events/+server.ts
export const GET: RequestHandler = async ({ request }) => {
  const stream = new ReadableStream({
    start(controller) {
      const encoder = new TextEncoder();
      const interval = setInterval(() => {
        const data = JSON.stringify({ time: Date.now() });
        controller.enqueue(encoder.encode(`data: ${data}\n\n`));
      }, 1000);

      request.signal.addEventListener('abort', () => {
        clearInterval(interval);
        controller.close();
      });
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
<script>
  let events = $state([]);

  $effect(() => {
    const source = new EventSource('/api/events');
    source.onmessage = (e) => {
      events = [...events, JSON.parse(e.data)];
    };
    return () => source.close();
  });
</script>
```

### Polling with Invalidation

```svelte
<script>
  import { invalidate } from '$app/navigation';

  $effect(() => {
    const interval = setInterval(() => invalidate('app:notifications'), 30000);
    return () => clearInterval(interval);
  });
</script>
```
