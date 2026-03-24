---
name: sveltekit-framework
description: >
  USE when building SvelteKit apps, Svelte 5 components, SvelteKit routing, load functions,
  form actions, API routes, SSR/SSG/SPA configuration, hooks, adapters, or deploying SvelteKit.
  USE when user mentions SvelteKit, Svelte 5, runes ($state, $derived, $effect, $props),
  +page.svelte, +layout.svelte, +server.ts, svelte.config.js, or `npx sv create`.
  USE for SvelteKit authentication, error handling, environment variables ($env), or adapter config.
  DO NOT USE for Svelte 4 legacy syntax (export let, $: reactive statements), React, Next.js,
  Vue, Nuxt, Angular, Astro, or non-Svelte frameworks. DO NOT USE for general HTML/CSS/JS
  without SvelteKit context.
---

# SvelteKit Framework Skill (SvelteKit 2.x + Svelte 5)

## Project Setup

Scaffold with the Svelte CLI:
```bash
npx sv create my-app    # prompts: template, TS/JS, integrations
cd my-app && npm install
npm run dev              # http://localhost:5173
```

### Key Config Files

**svelte.config.js** — main SvelteKit configuration:
```js
import adapter from '@sveltejs/adapter-auto';
import { vitePreprocess } from '@sveltejs/vite-plugin-svelte';

/** @type {import('@sveltejs/kit').Config} */
const config = {
  preprocess: vitePreprocess(),
  kit: {
    adapter: adapter(),
    alias: { '$components': './src/lib/components' }
  }
};
export default config;
```

**vite.config.ts** — uses `sveltekit()` plugin from `@sveltejs/kit/vite`. Extend with standard Vite options.

### Project Structure
```
src/
├── routes/           # file-based routing
│   ├── +page.svelte          # / route
│   ├── +layout.svelte        # root layout
│   ├── +error.svelte         # error boundary
│   ├── +page.ts              # universal load
│   ├── +page.server.ts       # server load + form actions
│   ├── about/+page.svelte    # /about route
│   ├── blog/[slug]/+page.svelte  # /blog/:slug dynamic
│   ├── api/items/+server.ts  # API endpoint
│   └── (auth)/login/+page.svelte # route group (no URL segment)
├── lib/              # $lib alias
│   ├── components/
│   ├── server/       # server-only ($lib/server)
│   └── utils.ts
├── hooks.server.ts   # server hooks
├── hooks.client.ts   # client hooks
├── app.html          # HTML template
├── app.d.ts          # type declarations
└── app.css
static/
```

## Svelte 5 Runes

Always use runes. Never use legacy `export let` or `$:` reactive statements.

### $state — Reactive State
```svelte
<script>
  let count = $state(0);
  let user = $state({ name: 'Alice', age: 30 });
  let items = $state(['apple', 'banana']);
</script>

<button onclick={() => count++}>Clicked {count} times</button>
```
Mutating objects/arrays is reactive: `items.push('cherry')` triggers updates.

### $derived — Computed Values
```svelte
<script>
  let count = $state(0);
  let doubled = $derived(count * 2);
  let expensive = $derived.by(() => {
    return someExpensiveComputation(count);
  });
</script>
```

### $effect — Side Effects
```svelte
<script>
  let count = $state(0);
  $effect(() => {
    document.title = `Count: ${count}`;
    return () => { /* cleanup */ };
  });
  $effect.pre(() => { /* runs before DOM update */ });
</script>
```

### $props — Component Props
```svelte
<!-- Button.svelte -->
<script>
  let { label, variant = 'primary', onclick, ...rest } = $props();
</script>
<button class={variant} {onclick} {...rest}>{label}</button>
```

### $bindable — Two-Way Binding Props
```svelte
<!-- TextInput.svelte -->
<script>
  let { value = $bindable(''), placeholder = '' } = $props();
</script>
<input bind:value {placeholder} />

<!-- Parent usage -->
<script>
  let search = $state('');
</script>
<TextInput bind:value={search} />
```

## File-Based Routing

| File | Purpose |
|------|---------|
| `+page.svelte` | Page component (renders at route URL) |
| `+page.ts` | Universal load function (runs server + client) |
| `+page.server.ts` | Server-only load + form actions |
| `+layout.svelte` | Layout wrapping child routes (uses `{@render children()}`) |
| `+layout.ts` | Universal layout load |
| `+layout.server.ts` | Server-only layout load |
| `+error.svelte` | Error boundary for route segment |
| `+server.ts` | API endpoint (GET, POST, PUT, DELETE, PATCH) |

### Route Patterns
```
src/routes/
  [id]/+page.svelte           → /123 (dynamic param)
  [...rest]/+page.svelte      → /a/b/c (rest param)
  [[optional]]/+page.svelte   → / or /value (optional param)
  (group)/nested/+page.svelte → /nested (group removed from URL)
```

### Layout with Snippet
```svelte
<!-- +layout.svelte -->
<script>
  let { children } = $props();
</script>
<nav><!-- nav content --></nav>
<main>{@render children()}</main>
<footer><!-- footer --></footer>
```

## Load Functions

### Universal Load (+page.ts / +layout.ts)
Runs on server during SSR, then on client for navigation:
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
Server-only; access DB, secrets, filesystem:
```ts
// src/routes/dashboard/+page.server.ts
import type { PageServerLoad } from './$types';
import { db } from '$lib/server/db';

export const load: PageServerLoad = async ({ locals }) => {
  const user = locals.user;
  const stats = await db.getStats(user.id);
  return { user, stats };
};
```

Access load data in page components via `$props()`:
```svelte
<script>
  let { data } = $props();
</script>
<h1>{data.post.title}</h1>
```

## Form Actions

Define in `+page.server.ts`. Work without JS (progressive enhancement).

### Default Action
```ts
// src/routes/contact/+page.server.ts
import type { Actions } from './$types';
import { fail } from '@sveltejs/kit';

export const actions: Actions = {
  default: async ({ request }) => {
    const data = await request.formData();
    const email = data.get('email') as string;
    if (!email) return fail(400, { email, missing: true });
    await sendEmail(email, data.get('message') as string);
    return { success: true };
  }
};
```

### Named Actions
```ts
export const actions: Actions = {
  login: async ({ request, cookies }) => {
    const data = await request.formData();
    const user = await authenticate(data);
    if (!user) return fail(401, { invalid: true });
    cookies.set('session', user.token, { path: '/', httpOnly: true });
    return { success: true };
  },
  register: async ({ request }) => { /* ... */ }
};
```

### Form Component with use:enhance
```svelte
<script>
  import { enhance } from '$app/forms';
  let { form } = $props();
</script>

<form method="POST" action="?/login" use:enhance>
  <input name="email" type="email" required />
  <input name="password" type="password" required />
  <button>Log in</button>
  {#if form?.invalid}<p class="error">Invalid credentials</p>{/if}
</form>
```
`use:enhance` prevents full reload, updates `form` prop automatically. Custom enhance:
```svelte
<form method="POST" use:enhance={({ formData, cancel }) => {
  // pre-submit logic
  return async ({ result, update }) => {
    if (result.type === 'success') showToast('Saved!');
    await update(); // apply default behavior
  };
}}>
```

## API Routes (+server.ts)

```ts
// src/routes/api/items/+server.ts
import { json, error } from '@sveltejs/kit';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = async ({ url }) => {
  const limit = Number(url.searchParams.get('limit') ?? 10);
  const items = await db.items.findMany({ take: limit });
  return json(items);
};

export const POST: RequestHandler = async ({ request }) => {
  const body = await request.json();
  if (!body.name) throw error(400, 'Name is required');
  const item = await db.items.create({ data: body });
  return json(item, { status: 201 });
};
```

## Error Handling

### Expected Errors (user-facing)
```ts
import { error, redirect } from '@sveltejs/kit';

// In load or action:
throw error(404, { message: 'Not found' });
throw redirect(303, '/login');
```

### +error.svelte
```svelte
<script>
  import { page } from '$app/state';
</script>
<h1>{page.status}</h1>
<p>{page.error?.message}</p>
```

### Unexpected Errors
Caught by `handleError` hook. Never expose stack traces to users.

## Hooks (src/hooks.server.ts)

Use `sequence()` to compose multiple hooks. See `assets/hooks.server.ts` for a production-ready template.

```ts
import type { Handle } from '@sveltejs/kit';
import { sequence } from '@sveltejs/kit/hooks';

const auth: Handle = async ({ event, resolve }) => {
  const token = event.cookies.get('session');
  event.locals.user = token ? await verifyToken(token) : null;
  return resolve(event);
};

export const handle = sequence(auth);
```

Declare `locals` types in `src/app.d.ts`:
```ts
declare global {
  namespace App {
    interface Locals { user: User | null; }
    interface Error { message: string; id?: string; }
  }
}
export {};
```

## Page Options

Set per-route in `+page.ts` or `+layout.ts`:
```ts
export const ssr = true;        // server-side render (default: true)
export const csr = true;        // client-side render (default: true)
export const prerender = false; // static prerender at build time
export const trailingSlash = 'never'; // 'always' | 'never' | 'ignore'
```

Full SSG: set `prerender = true` in root `+layout.ts` + use `adapter-static`.
SPA mode: set `ssr = false` in root `+layout.ts`.

## Adapters

Install the adapter, set in `svelte.config.js`:

| Adapter | Package | Use Case |
|---------|---------|----------|
| Auto | `@sveltejs/adapter-auto` | Auto-detects platform (default) |
| Node | `@sveltejs/adapter-node` | Self-hosted Node.js server |
| Static | `@sveltejs/adapter-static` | Fully pre-rendered static site |
| Vercel | `@sveltejs/adapter-vercel` | Vercel deployment |
| Netlify | `@sveltejs/adapter-netlify` | Netlify deployment |
| Cloudflare | `@sveltejs/adapter-cloudflare` | Cloudflare Pages/Workers |

```js
// svelte.config.js — Node adapter example
import adapter from '@sveltejs/adapter-node';
const config = {
  kit: {
    adapter: adapter({ out: 'build' })
  }
};
```

Build & run: `npm run build && node build/index.js`

## Environment Variables

Prefix public vars with `PUBLIC_`. Use `.env` for local development.

| Module | Access | Timing |
|--------|--------|--------|
| `$env/static/private` | Server only | Build-time (tree-shaken) |
| `$env/static/public` | Server + Client | Build-time |
| `$env/dynamic/private` | Server only | Runtime |
| `$env/dynamic/public` | Server + Client | Runtime |

```ts
// +page.server.ts (server-only)
import { DATABASE_URL } from '$env/static/private';
import { env } from '$env/dynamic/private';
const secret = env.API_SECRET;

// +page.svelte or any client code
import { PUBLIC_API_URL } from '$env/static/public';
```

Never import `$env/static/private` or `$env/dynamic/private` in client code — build will fail.

## State Management

Use `$state` in `.svelte.ts` files for shared reactive state:
```ts
// src/lib/stores/counter.svelte.ts
export function createCounter(initial = 0) {
  let count = $state(initial);
  return {
    get count() { return count; },
    increment() { count++; },
    reset() { count = initial; }
  };
}
```
For app-wide state, use `setContext`/`getContext` in root layout or create module-level singletons.

## Authentication Pattern

Protect routes with a layout server load that checks `locals.user` (set by hooks):

```ts
// src/routes/(protected)/+layout.server.ts
import { redirect } from '@sveltejs/kit';
import type { LayoutServerLoad } from './$types';

export const load: LayoutServerLoad = async ({ locals }) => {
  if (!locals.user) throw redirect(303, '/login');
  return { user: locals.user };
};
```

## Testing

### Unit Tests (Vitest)
```ts
// src/lib/utils.test.ts
import { describe, it, expect } from 'vitest';
import { formatDate } from './utils';
describe('formatDate', () => {
  it('formats ISO date', () => {
    expect(formatDate('2024-01-15')).toBe('January 15, 2024');
  });
});
```
Run: `npx vitest run`

### E2E Tests (Playwright)
```ts
// tests/home.test.ts
import { test, expect } from '@playwright/test';
test('homepage loads', async ({ page }) => {
  await page.goto('/');
  await expect(page.locator('h1')).toBeVisible();
});
```
Run: `npx playwright test`

## Common Pitfalls

1. **Importing private env in client code** — build error. Use `$env/static/public` or `$env/dynamic/public` only.
2. **Forgetting `use:enhance`** — forms do full page reload without it. Add `use:enhance` for SPA behavior.
3. **Mutating `$derived` values** — derived state is read-only. Use `$state` for mutable data.
4. **Using `export let` in Svelte 5** — deprecated. Use `let { prop } = $props()`.
5. **Missing `children` render** — layout must include `{@render children()}`.
6. **Server-only code in universal load** — `+page.ts` runs on client too. Use `+page.server.ts` for DB/secrets.
7. **Not typing `locals`** — declare `App.Locals` in `src/app.d.ts`.
8. **`redirect()` outside load/action** — must be used in load, actions, or handlers only.
9. **Adapter mismatch** — `adapter-static` cannot handle server routes. Use `adapter-node` for SSR.
10. **`$effect` for derived state** — use `$derived`, not `$effect` with assignment.

## References

In-depth guides for advanced topics, troubleshooting, and migration:

| File | Description |
|------|-------------|
| `references/advanced-patterns.md` | Svelte 5 runes deep dive (`$state.raw`, `$state.snapshot`, `$effect.pre`, `$effect.root`), snippets, component composition, streaming/parallel load patterns, invalidation, service workers, shallow routing, preloading, content negotiation, WebSocket/SSE integration |
| `references/troubleshooting.md` | Hydration errors, SSR-only code issues, adapter-specific problems, Vite plugin conflicts, environment variable gotchas, module resolution, form action redirects, cookie edge cases, prerendering failures, deployment per adapter |
| `references/migration-guide.md` | Svelte 4→5 migration (stores→runes, `createEventDispatcher`→callback props, slots→snippets), SvelteKit 1→2 migration, breaking changes, codemods (`npx sv migrate`) |

## Scripts

Automation scripts in `scripts/`. Run from the SvelteKit project root.

| Script | Usage | Description |
|--------|-------|-------------|
| `scripts/setup-project.sh` | `./setup-project.sh my-app` | Bootstrap SvelteKit + Svelte 5 with Tailwind, TypeScript, Vitest, Playwright, ESLint, Prettier |
| `scripts/create-route.sh` | `./create-route.sh blog/[slug] --full` | Generate route with `+page.svelte`, `+page.server.ts`, `+layout`, `+error` files |
| `scripts/check-routes.sh` | `./check-routes.sh --verbose` | Analyze route tree, detect conflicts, list routes with params and file types |

## Assets

Production-ready templates and configs in `assets/`. Copy into your project and customize.

| File | Description |
|------|-------------|
| `assets/svelte.config.js` | SvelteKit config with adapter-auto, path aliases, CSP, prerender options |
| `assets/route-template.svelte` | Complete route with load data, form actions, error handling, SEO, streaming |
| `assets/hooks.server.ts` | Production hooks: auth, rate limiting, request logging, security headers, error handling |
| `assets/docker-compose.yml` | Docker Compose for dev: SvelteKit + PostgreSQL + Redis + Adminer + Mailpit |
<!-- tested: pass -->
