---
name: svelte-patterns
description:
  positive: "Use when user builds with Svelte or SvelteKit, asks about Svelte 5 runes ($state, $derived, $effect), SvelteKit routing, load functions, form actions, server-side rendering, or Svelte component patterns."
  negative: "Do NOT use for React (use react-state-management or nextjs-patterns skills), Vue.js, Angular, or vanilla JavaScript frameworks."
---

# Svelte & SvelteKit Patterns

## Svelte 5 Runes

### $state — Reactive State

Declare reactive variables with `$state`. Only use for values that drive UI updates.

```svelte
<script>
  let count = $state(0);
  let user = $state({ name: 'Alice', age: 30 });
</script>
<button onclick={() => count++}>{count}</button>
```

- Arrays/objects are deeply reactive via proxies. Use `$state.raw(value)` for large objects replaced wholesale — avoids proxy overhead.
- Use `$state.snapshot(value)` to get a plain non-reactive copy for logging or external APIs.
- Class instances are NOT proxied — define `$state` fields inside the class:

```ts
class Counter {
  count = $state(0);
  increment() { this.count++; }
}
```

### $derived — Computed Values

Derive values from reactive state. Must be pure — no side effects.

```svelte
<script>
  let count = $state(0);
  let doubled = $derived(count * 2);
  let summary = $derived.by(() => {
    return count > 10 ? 'high' : 'low';
  });
</script>
```

Prefer `$derived` over `$effect` for any value computation. Use `$derived.by()` for multi-statement derivations.

### $effect — Side Effects

Run code when dependencies change. Only for external side effects (DOM, network, timers).

```svelte
<script>
  let query = $state('');
  $effect(() => {
    const controller = new AbortController();
    fetch(`/api/search?q=${query}`, { signal: controller.signal });
    return () => controller.abort(); // always return cleanup
  });
</script>
```

- Never update `$state` that the same effect depends on — causes infinite loops.
- Effects only run in the browser, never during SSR.
- Do not make the effect callback async. Use `$effect.pre` to run before DOM updates.

### $props, $bindable, $inspect

```svelte
<script lang="ts">
  interface Props { title: string; count?: number; children?: import('svelte').Snippet; }
  let { title, count = 0, children, ...rest }: Props = $props();
</script>
<h1 {...rest}>{title}: {count}</h1>
```

Two-way binding: declare with `$bindable`, parent opts in with `bind:`:

```svelte
<script>
  let { value = $bindable('') } = $props();
</script>
<input bind:value />
```

`$inspect(value)` logs on every change — stripped in production.

## Reactivity

Svelte 5 tracks dependencies at property level — accessing `obj.name` only rerenders when `name` changes.

```ts
let items = $state([{ name: 'a', done: false }]);
items[0].done = true; // deep reactivity — triggers update

let data = $state.raw(largeResponse);
data = newResponse;   // raw — only reassignment triggers update
```

## Component Patterns

### Snippets (Replaces Slots)

```svelte
<!-- Card.svelte -->
<script>
  let { header, children } = $props();
</script>
<div class="card">
  {#if header}{@render header()}{/if}
  {@render children?.()}
</div>

<!-- Usage -->
<Card>
  {#snippet header()}<h2>Title</h2>{/snippet}
  {#snippet children()}<p>Body</p>{/snippet}
</Card>
```

Snippets with parameters for render delegation:

```svelte
<List items={users}>
  {#snippet row(item)}<span>{item.name}</span>{/snippet}
</List>
```

### Events, Context, Lifecycle

Use callback props instead of `createEventDispatcher`:

```svelte
<script>
  let { onSubmit } = $props();
</script>
<button onclick={() => onSubmit('data')}>Submit</button>
```

Context: `setContext('key', value)` in provider, `getContext('key')` in consumer.

Lifecycle: `onMount` (client only), `onDestroy` for cleanup. `$effect` replaces `beforeUpdate`/`afterUpdate`.

## SvelteKit Routing

```
src/routes/
├── +page.svelte            → /
├── +layout.svelte          → shared layout
├── about/+page.svelte      → /about
├── blog/[slug]/+page.svelte → /blog/:slug
├── (auth)/login/+page.svelte → /login (route group)
└── api/users/+server.ts    → /api/users
```

- `[param]` dynamic, `[...rest]` catch-all, `(group)` layout group without URL segment.
- `+error.svelte` — error boundary. `+layout.svelte` — wraps child pages.

Page options in `+page.ts` or `+layout.ts`:

```ts
export const ssr = true;        // default
export const csr = true;        // default
export const prerender = false;
export const trailingSlash = 'never';
```

## Load Functions

### Universal (+page.ts) — runs server and client:

```ts
import type { PageLoad } from './$types';
export const load: PageLoad = async ({ params, fetch }) => {
  const res = await fetch(`/api/posts/${params.slug}`);
  return { post: await res.json() };
};
```

### Server (+page.server.ts) — runs only on server, use for DB/secrets/auth:

```ts
import type { PageServerLoad } from './$types';
import { redirect } from '@sveltejs/kit';
export const load: PageServerLoad = async ({ locals, depends }) => {
  if (!locals.user) redirect(303, '/login');
  depends('app:dashboard');
  return { user: locals.user, stats: await db.getStats(locals.user.id) };
};
```

### Streaming — return unawaited promises to stream data:

```ts
export const load: PageServerLoad = async ({ locals }) => {
  return { user: locals.user, slowData: db.getSlowData() };
};
```

Use `{#await data.slowData}...{:then value}...{/await}` in the template.

## Form Actions

```ts
// src/routes/login/+page.server.ts
import { fail, redirect } from '@sveltejs/kit';
import type { Actions } from './$types';

export const actions: Actions = {
  default: async ({ request }) => {
    const data = await request.formData();
    const email = data.get('email') as string;
    if (!email) return fail(400, { email, missing: true });
    const user = await auth.login(email, data.get('password') as string);
    if (!user) return fail(400, { email, incorrect: true });
    redirect(303, '/dashboard');
  },
  logout: async ({ cookies }) => {
    cookies.delete('session', { path: '/' });
    redirect(303, '/');
  }
};
```

```svelte
<script>
  import { enhance } from '$app/forms';
  let { form } = $props();
</script>
<form method="POST" use:enhance>
  <input name="email" value={form?.email ?? ''} />
  {#if form?.missing}<p class="error">Email required</p>{/if}
  <button>Log In</button>
</form>
<form method="POST" action="?/logout" use:enhance><button>Log Out</button></form>
```

- `use:enhance` adds AJAX with progressive enhancement. Forms work without JS by default.
- Use `fail()` to return errors preserving form input.
- Named actions via `action="?/actionName"`.

## API Routes (+server.ts)

```ts
import { json, error } from '@sveltejs/kit';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = async ({ url }) => {
  const posts = await db.getPosts(Number(url.searchParams.get('limit') ?? 10));
  return json(posts);
};

export const POST: RequestHandler = async ({ request, locals }) => {
  if (!locals.user) error(401, 'Unauthorized');
  return json(await db.createPost(await request.json()), { status: 201 });
};
```

Stream with `new Response(readableStream, { headers: { 'Content-Type': 'text/event-stream' } })`.

## Hooks

### Server Hooks (src/hooks.server.ts)

```ts
import type { Handle, HandleFetch, HandleServerError } from '@sveltejs/kit';

export const handle: Handle = async ({ event, resolve }) => {
  const session = event.cookies.get('session');
  event.locals.user = session ? await getUser(session) : null;
  return resolve(event);
};

export const handleFetch: HandleFetch = async ({ request, fetch }) => {
  if (request.url.startsWith('https://api.internal/'))
    request.headers.set('Authorization', `Bearer ${API_KEY}`);
  return fetch(request);
};

export const handleError: HandleServerError = async ({ error }) => {
  console.error(error);
  return { message: 'Internal error' };
};
```

Client hooks (`src/hooks.client.ts`): export `handleError: HandleClientError` for client-side error reporting.

## State Management

### Shared State with Runes

Create reactive state in `.svelte.ts` files:

```ts
// src/lib/stores/counter.svelte.ts
let count = $state(0);
export function useCounter() {
  return {
    get count() { return count; },
    increment() { count++; },
    reset() { count = 0; }
  };
}
```

Legacy `writable`/`derived` stores still work. Prefer runes-based shared state in new code.

## Styling

```svelte
<style>
  p { color: blue; }                   /* scoped by default */
  :global(body) { margin: 0; }        /* global escape */
  .wrapper :global(p) { color: red; } /* scoped parent, global child */
</style>
```

- Use `style:--theme-color="blue"` for CSS variable theming.
- Tailwind: install via `npx svelte-add tailwindcss`.

## Transitions and Animations

```svelte
<script>
  import { fade, fly, slide } from 'svelte/transition';
  import { tweened } from 'svelte/motion';
  let visible = $state(true);
</script>
{#if visible}
  <div transition:fade>Fades in/out</div>
  <div in:fly={{ y: 50 }} out:fade>Flies in, fades out</div>
{/if}
```

- `transition:` both directions. `in:`/`out:` separate. `animate:flip` for list reordering.
- `tweened`/`spring` — motion stores for interpolated values.

## SSR / SSG / SPA Modes

Full SSG: set `export const prerender = true` in root `+layout.ts` and use `adapter-static`.

SPA mode: set `export const ssr = false` in root layout, use `adapter-static` with `fallback: 'index.html'`.

Mix modes per route — some prerendered, some SSR.

## Deployment

```js
// svelte.config.js — pick one adapter
import adapter from '@sveltejs/adapter-node';      // self-hosted: node build/index.js
import adapter from '@sveltejs/adapter-static';     // static: fallback: '404.html'
import adapter from '@sveltejs/adapter-vercel';     // Vercel: runtime: 'nodejs22.x'
import adapter from '@sveltejs/adapter-cloudflare'; // CF Workers/Pages
export default { kit: { adapter: adapter() } };
```

- adapter-node: set `PORT`, `HOST`, `ORIGIN` env vars.
- adapter-cloudflare: access platform bindings via `platform.env` in server load/hooks.

## Testing

```ts
// Unit — Vitest
import { describe, it, expect } from 'vitest';
describe('formatDate', () => {
  it('formats ISO dates', () => expect(formatDate('2025-01-01')).toBe('Jan 1, 2025'));
});

// Component — @testing-library/svelte
import { render, screen, fireEvent } from '@testing-library/svelte';
it('increments', async () => {
  render(Counter, { props: { initial: 0 } });
  await fireEvent.click(screen.getByRole('button'));
  expect(screen.getByText('1')).toBeInTheDocument();
});

// E2E — Playwright
import { test, expect } from '@playwright/test';
test('login', async ({ page }) => {
  await page.goto('/login');
  await page.fill('input[name="email"]', 'user@test.com');
  await page.click('button[type="submit"]');
  await expect(page).toHaveURL('/dashboard');
});
```

## Anti-Patterns

### Overusing $effect for derived values

```ts
// BAD — extra renders, unnecessary effect
let count = $state(0);
let doubled = $state(0);
$effect(() => { doubled = count * 2; });
// GOOD
let doubled = $derived(count * 2);
```

### Updating state inside its own effect — causes infinite loops.

### Async effect callbacks — cleanup won't work, deps after `await` not tracked. Trigger async inside sync effects instead.

### Breaking SSR

- Do not access `window`/`document`/`localStorage` at top-level script scope.
- Guard browser-only code: `import { browser } from '$app/environment'`.
- Never use `$effect` for values needed during SSR — use `$derived`.

### Mutating props — use callback props instead of mutating prop objects directly.

### Ignoring progressive enhancement — build forms that work without JS first, add `use:enhance` for improved UX.
