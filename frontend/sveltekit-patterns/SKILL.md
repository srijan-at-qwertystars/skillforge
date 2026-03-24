---
name: sveltekit-patterns
description: >
  Use when building full-stack web apps with SvelteKit, using Svelte 5 runes,
  SvelteKit routing, form actions, load functions, server-side rendering, hooks,
  API routes, environment variables, authentication patterns, or deploying
  SvelteKit apps. Covers SvelteKit 2.x with Svelte 5 including $state, $derived,
  $effect, $props, $bindable, $inspect, adapters, SSR/CSR/prerendering, shallow
  routing, progressive enhancement, and testing. Do NOT use for Svelte 3/4 legacy
  code without SvelteKit, React/Next.js apps, Vue/Nuxt apps, Astro sites, or
  general JavaScript frameworks without Svelte.
---

# SvelteKit 2.x with Svelte 5 Patterns

## Project Setup and Structure

Scaffold with `npx sv create my-app`. Key directories: `src/routes/` (file-based routing — `+page.svelte`, `+page.ts`, `+page.server.ts`, `+layout.svelte`, `+error.svelte`, `+server.ts`), `src/lib/` (aliased as `$lib`, shared components/utils), `src/lib/server/` (server-only code), `static/` (public assets), `src/hooks.server.ts` and `src/hooks.client.ts` (hooks), `src/app.html` (HTML shell).

```js
// svelte.config.js
import adapter from '@sveltejs/adapter-auto';
import { vitePreprocess } from '@sveltejs/vite-plugin-svelte';
export default {
  preprocess: vitePreprocess(),
  kit: { adapter: adapter(), alias: { '$components': 'src/lib/components' } }
};
```

## Svelte 5 Runes

Runes are compiler-level reactivity primitives. Use them in `.svelte` files and in `.svelte.ts`/`.svelte.js` modules.

### $state — Reactive State

```svelte
<script>
  let count = $state(0);
  let user = $state({ name: 'Alice', age: 30 });
  let items = $state([1, 2, 3]);
</script>
<button onclick={() => count++}>Count: {count}</button>
```

Deep mutations auto-track: `user.name = 'Bob'` and `items.push(4)` trigger updates. Use `$state.raw()` for non-deep reactivity on large objects.

### $derived — Computed Values

```svelte
<script>
  let count = $state(0);
  let doubled = $derived(count * 2);
  let sorted = $derived.by(() => [...items].sort((a, b) => a - b)); // complex derivations
</script>
```

Never produce side effects in `$derived`. It recomputes lazily when dependencies change.

### $effect — Side Effects

```svelte
<script>
  let count = $state(0);
  $effect(() => {
    document.title = `Count: ${count}`;
    return () => { /* cleanup on re-run or destroy */ };
  });
</script>
```

Use sparingly — prefer `$derived` for computed values. Avoid setting `$state` inside `$effect` (infinite loops). Use `$effect.pre()` to run before DOM updates.

### $props and $bindable

```svelte
<!-- Button.svelte -->
<script lang="ts">
  let { label, variant = 'primary', onclick }: {
    label: string; variant?: 'primary' | 'secondary'; onclick?: () => void;
  } = $props();
</script>
<button class={variant} {onclick}>{label}</button>

<!-- TextInput.svelte — two-way binding with $bindable -->
<script lang="ts">
  let { value = $bindable('') }: { value: string } = $props();
</script>
<input bind:value />

<!-- Parent usage -->
<script>
  let search = $state('');
</script>
<TextInput bind:value={search} />
```

Rest props: `let { label, ...rest } = $props();` then spread with `{...rest}`.

### $inspect — Dev-Only Debugging

```svelte
<script>
  let count = $state(0);
  $inspect(count); // logs on change, stripped in prod
  $inspect(count).with(console.trace); // custom inspector
</script>
```

## Routing

### File-Based Routes

`src/routes/+page.svelte` → `/`, `src/routes/about/+page.svelte` → `/about`, `src/routes/blog/[slug]/+page.svelte` → `/blog/:slug`, `src/routes/[...rest]/+page.svelte` → catch-all, `src/routes/items/[[optional]]/+page.svelte` → optional param.

Access params in load functions via `params.slug`.

### Route Groups and Layouts

Group without affecting URL using parentheses: `src/routes/(auth)/login/` → `/login`. Each group can have its own `+layout.svelte`.

`+layout.svelte` wraps child routes using `{@render children()}` (Svelte 5 snippet):

```svelte
<script>
  let { children } = $props();
</script>
<nav>...</nav>
<main>{@render children()}</main>
```

Reset layout inheritance with `+page@.svelte` (root) or `+page@(group).svelte`.

### Error Pages

`+error.svelte` catches errors from load functions. The nearest one in the route tree renders:

```svelte
<script>
  import { page } from '$app/state';
</script>
<h1>{page.status}: {page.error?.message}</h1>
```

## Load Functions

### Universal Load (+page.ts / +layout.ts)

Runs on server during SSR, then on client during navigation:

```ts
// src/routes/blog/[slug]/+page.ts
import type { PageLoad } from './$types';

export const load: PageLoad = async ({ params, fetch }) => {
  const res = await fetch(`/api/posts/${params.slug}`);
  const post = await res.json();
  return { post };
};
```

### Server Load (+page.server.ts / +layout.server.ts)

Runs only on the server. Access databases, secrets, file system:

```ts
// src/routes/dashboard/+page.server.ts
import type { PageServerLoad } from './$types';
import { db } from '$lib/server/db';

export const load: PageServerLoad = async ({ locals }) => {
  const user = locals.user;
  const stats = await db.getStats(user.id);
  return { stats };
};
```

### Data Flow and Invalidation

Access data in components via the `data` prop:

```svelte
<script>
  let { data } = $props();
</script>
<h1>{data.post.title}</h1>
```

Invalidate and reload data programmatically:

```ts
import { invalidate, invalidateAll } from '$app/navigation';
invalidate('/api/posts');   // Re-run loads depending on this URL
invalidate('app:auth');     // Custom identifier
invalidateAll();            // Re-run all load functions
```

Register dependencies in load: `depends('app:auth')`.

## Form Actions

### Default and Named Actions

```ts
// src/routes/login/+page.server.ts
import type { Actions } from './$types';
import { fail, redirect } from '@sveltejs/kit';

export const actions: Actions = {
  default: async ({ request, cookies }) => {
    const data = await request.formData();
    const email = data.get('email') as string;
    const password = data.get('password') as string;

    const user = await authenticate(email, password);
    if (!user) return fail(401, { email, error: 'Invalid credentials' });

    cookies.set('session', user.token, { path: '/', httpOnly: true });
    redirect(303, '/dashboard');
  },
  logout: async ({ cookies }) => {
    cookies.delete('session', { path: '/' });
    redirect(303, '/login');
  }
};
```

### Form with Progressive Enhancement

```svelte
<script>
  import { enhance } from '$app/forms';
  let { form } = $props();
</script>

<form method="POST" use:enhance>
  <input name="email" value={form?.email ?? ''} />
  <input name="password" type="password" />
  {#if form?.error}<p class="error">{form.error}</p>{/if}
  <button>Log In</button>
</form>

<!-- Named action -->
<form method="POST" action="?/logout" use:enhance>
  <button>Log Out</button>
</form>
```

Custom `use:enhance` for loading states:

```svelte
<form method="POST" use:enhance={() => {
  loading = true;
  return async ({ update }) => {
    await update();
    loading = false;
  };
}}>
```

## Hooks

### Server Hooks (src/hooks.server.ts)

```ts
import type { Handle, HandleFetch, HandleServerError } from '@sveltejs/kit';

export const handle: Handle = async ({ event, resolve }) => {
  const session = event.cookies.get('session');
  if (session) event.locals.user = await getUserFromSession(session);
  const response = await resolve(event, {
    filterSerializedResponseHeaders: (name) => name === 'content-type'
  });
  return response;
};

export const handleFetch: HandleFetch = async ({ request, fetch }) => {
  // Intercept outgoing server-side fetches (add auth, proxy, etc.)
  return fetch(request);
};

export const handleError: HandleServerError = async ({ error }) => {
  console.error(error);
  return { message: 'Internal server error', code: 'UNEXPECTED' };
};
```

Compose multiple handlers with `sequence()` from `@sveltejs/kit/hooks`.

### Client Hooks (src/hooks.client.ts)

Export `handleError` to customize client-side error reporting. Same signature minus `event`.

## API Routes (+server.ts)

```ts
// src/routes/api/posts/+server.ts
import { json, error } from '@sveltejs/kit';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = async ({ url }) => {
  const posts = await db.getPosts(Number(url.searchParams.get('limit') ?? 10));
  return json(posts);
};

export const POST: RequestHandler = async ({ request, locals }) => {
  if (!locals.user) error(401, 'Unauthorized');
  const post = await db.createPost(await request.json());
  return json(post, { status: 201 });
};

export const DELETE: RequestHandler = async ({ params }) => {
  await db.deletePost(params.id);
  return new Response(null, { status: 204 });
};
```

### Streaming Responses

```ts
export const GET: RequestHandler = async () => {
  const stream = new ReadableStream({
    async start(controller) {
      for await (const chunk of generateData()) {
        controller.enqueue(new TextEncoder().encode(chunk));
      }
      controller.close();
    }
  });
  return new Response(stream, { headers: { 'Content-Type': 'text/event-stream' } });
};
```

## SSR, CSR, and Prerendering

Configure per-page in `+page.ts` or `+page.server.ts`:

```ts
export const ssr = true;           // Server-side render (default)
export const csr = true;           // Hydrate on client (default)
export const prerender = false;    // Static generation at build time
export const trailingSlash = 'never'; // 'always' | 'ignore'
```

Set `prerender = true` on static pages. Set `ssr = false` for client-only pages (e.g., admin dashboards with browser-only deps). Apply to entire groups via `+layout.ts`.

## Adapters

Install the adapter for your target platform:

| Adapter | Package | Use Case |
|---------|---------|----------|
| Auto | `@sveltejs/adapter-auto` | Auto-detect platform (default) |
| Node | `@sveltejs/adapter-node` | Self-hosted Node.js server |
| Static | `@sveltejs/adapter-static` | Fully static site / SPA |
| Vercel | `@sveltejs/adapter-vercel` | Vercel deployment |
| Netlify | `@sveltejs/adapter-netlify` | Netlify deployment |
| Cloudflare | `@sveltejs/adapter-cloudflare` | Cloudflare Pages/Workers |

For `adapter-static`, set `prerender = true` in root `+layout.ts`. For SPA mode, add a fallback: `adapter({ fallback: '200.html' })`.

## Environment Variables

Use `.env` for local dev. Four modules available:

```ts
import { SECRET_KEY } from '$env/static/private';    // Server-only, build-time (best perf)
import { PUBLIC_API_URL } from '$env/static/public';  // Client-safe, build-time (PUBLIC_ prefix)
import { env } from '$env/dynamic/private';            // Server-only, runtime
import { env } from '$env/dynamic/public';             // Client-safe, runtime
```

Prefer `static` for build-time inlining. Use `dynamic` for pre-built artifacts across environments (Docker). Never import `private` modules in client code.

## State Management

### Runes Replace Stores

Use `$state` in `.svelte.ts` files instead of writable stores:

```ts
// src/lib/counter.svelte.ts
let count = $state(0);
export function getCount() { return count; }
export function increment() { count++; }
```

### Context API

Pass reactive state down the tree. Wrap in getter functions so consumers read correctly:

```svelte
<!-- Parent: setContext('theme', () => theme) -->
<!-- Child: const theme = getContext('theme')() -->
```

## Shallow Routing and Preloading

Update URL/history without full navigation (modals, tabs):

```svelte
<script>
  import { pushState } from '$app/navigation';
  import { page } from '$app/state';

  async function openModal(href) {
    const { data } = await preloadData(href);
    pushState(href, { showModal: true, detail: data });
  }
</script>

{#if page.state.showModal}
  <Modal data={page.state.detail} onclose={() => history.back()} />
{/if}
```

Preload on hover for instant navigation: `<a data-sveltekit-preload-data="hover">`.

## Error Handling

**Expected errors**: Throw with `error()` from `@sveltejs/kit` — message shown to users:

```ts
import { error } from '@sveltejs/kit';
export const load = async ({ params }) => {
  const post = await db.getPost(params.slug);
  if (!post) error(404, { message: 'Post not found' });
  return { post };
};
```

**Unexpected errors**: Unhandled exceptions become generic 500. Customize via `handleError` hook. Never expose internals. The nearest `+error.svelte` renders for both types.

## Authentication Patterns

Cookie-based session in `hooks.server.ts`: read cookie → verify token → set `event.locals.user`. Protect routes in `+layout.server.ts`:

```ts
// src/routes/(protected)/+layout.server.ts
import { redirect } from '@sveltejs/kit';
export const load = async ({ locals }) => {
  if (!locals.user) redirect(303, '/login');
  return { user: locals.user };
};
```

For OAuth: initiate via form actions, handle callback in `+server.ts`, exchange code for token, set cookie, redirect. Use `arctic` or `lucia` libraries to simplify.

## Deployment and Building

Build with `npm run build`. Preview with `npm run preview`. For `adapter-node`: run `node build/index.js`, configure `PORT`/`HOST`/`ORIGIN`. For `adapter-static`: upload `build/` to any static host. Set `config.kit.paths.base` for non-root deploys.

## Testing

```ts
// Vitest unit test — src/lib/utils.test.ts
import { describe, it, expect } from 'vitest';
import { formatDate } from '$lib/utils';
describe('formatDate', () => {
  it('formats ISO dates', () => expect(formatDate('2024-01-15')).toBe('January 15, 2024'));
});
```

Configure `vitest.config.ts` to resolve `$lib` aliases. Use `@testing-library/svelte` for component tests.

```ts
// Playwright E2E — e2e/app.test.ts
import { test, expect } from '@playwright/test';
test('login flow', async ({ page }) => {
  await page.goto('/login');
  await page.fill('input[name="email"]', 'user@test.com');
  await page.fill('input[name="password"]', 'password');
  await page.click('button[type="submit"]');
  await expect(page).toHaveURL('/dashboard');
});
```

## Progressive Enhancement

SvelteKit forms work without JavaScript. `use:enhance` upgrades them to SPA-style without full page reloads. Build features that function at the HTML level first, then layer interactivity.

- Forms: use `method="POST"` with `<form>`, add `use:enhance` for AJAX
- Links: standard `<a>` tags work for navigation; SvelteKit intercepts for client-side routing
- Disable JS enhancement per-link: `<a data-sveltekit-reload>`
- Disable preloading on sensitive links: `<a data-sveltekit-preload-data="off">`
- Always handle the no-JS case in form actions — return data from actions, not just redirects

## References (`references/`)
- **`advanced-patterns.md`** — $state.raw/snapshot, fine-grained reactivity, class fields, param matchers, layout groups, breaking out of layouts, streaming, parallel loading, universal vs server load, tRPC, progressive enhancement, snapshots, service workers, page options, env vars, WebSocket/SSE
- **`troubleshooting.md`** — Hydration mismatches, $state gotchas, form action redirect/return, load waterfalls, prerender errors, rune init errors, CORS, cookies, adapter issues (Vercel/Cloudflare/Node/Static), deployment, TypeScript errors, performance
- **`migration-guide.md`** — Svelte 4→5 (stores→runes, $:→$derived/$effect, slots→snippets, events→callbacks), SvelteKit 1→2, React→SvelteKit, Next.js→SvelteKit

## Scripts (`scripts/`, executable, self-contained with `--help`)
- **`scaffold-sveltekit-project.sh`** — `./scaffold-sveltekit-project.sh my-app --template blog|saas|api --css tailwind|uno|vanilla --auth lucia|authjs|none`
- **`sveltekit-route-generator.sh`** — `./sveltekit-route-generator.sh /blog/[slug] --layout --api --error --dry-run`

## Assets (`assets/`, copy into projects)
- **`svelte.config.js`** — Production config with aliases, CSP, prerender, adapter examples
- **`hooks.server.ts`** — Auth, CSP/security headers, request logging, error handling via `sequence()`
- **`+layout.server.ts`** — Root layout with user session pattern, protected route example
<!-- tested: pass -->
