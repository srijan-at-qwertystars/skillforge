# SvelteKit Troubleshooting Guide

## Table of Contents

- [Hydration Errors](#hydration-errors)
- [SSR-Only Code Issues](#ssr-only-code-issues)
- [Adapter-Specific Problems](#adapter-specific-problems)
- [Vite Plugin Conflicts](#vite-plugin-conflicts)
- [Environment Variable Gotchas](#environment-variable-gotchas)
- [Module Resolution Errors](#module-resolution-errors)
- [Form Action Redirect Issues](#form-action-redirect-issues)
- [Cookie Handling Edge Cases](#cookie-handling-edge-cases)
- [Prerendering Failures](#prerendering-failures)
- [Deployment Issues Per Adapter](#deployment-issues-per-adapter)

---

## Hydration Errors

### Symptom: "Hydration failed because the server-rendered HTML didn't match the client"

**Common causes and fixes:**

1. **Browser extensions inject HTML.** Test in incognito mode. This is rarely your bug.

2. **Date/time rendering differs between server and client:**
   ```svelte
   <!-- BAD: different on server vs client -->
   <p>{new Date().toLocaleString()}</p>

   <!-- FIX: format on client only -->
   <script>
     import { browser } from '$app/environment';
     let time = $state('');
     $effect(() => { time = new Date().toLocaleString(); });
   </script>
   <p>{browser ? time : ''}</p>
   ```

3. **Random values differ between SSR and CSR:**
   ```ts
   // BAD: different ID on server vs client
   const id = Math.random().toString(36);

   // FIX: generate in load function (runs once on server, passed to client)
   export const load = () => ({ id: crypto.randomUUID() });
   ```

4. **Conditional rendering based on `window`/`document`:**
   ```svelte
   <!-- BAD: server renders without this, client renders with it -->
   {#if typeof window !== 'undefined'}
     <MobileMenu />
   {/if}

   <!-- FIX: use $effect to set flag after mount -->
   <script>
     let mounted = $state(false);
     $effect(() => { mounted = true; });
   </script>
   {#if mounted}
     <MobileMenu />
   {/if}
   ```

5. **Invalid HTML nesting** (`<p>` inside `<p>`, `<div>` inside `<a>`). Browser fixes nesting differently than server output. Fix the HTML.

6. **Third-party scripts modifying DOM.** Wrap in `{#if browser}` or load in `onMount`-equivalent `$effect`.

---

## SSR-Only Code Issues

### Using `$app/environment`

```ts
import { browser, building, dev, version } from '$app/environment';
```

- `browser` — `true` in the browser, `false` on the server during SSR
- `building` — `true` during `npm run build` (prerendering phase)
- `dev` — `true` during `npm run dev`

### Symptom: "window is not defined" / "document is not defined"

Code referencing browser globals runs during SSR.

```svelte
<script>
  import { browser } from '$app/environment';

  // BAD: runs during SSR
  const width = window.innerWidth;

  // FIX: guard with browser check
  let width = $state(0);
  $effect(() => {
    width = window.innerWidth;
  });

  // FIX for imports: dynamic import
  let Chart;
  $effect(() => {
    import('chart.js').then(m => { Chart = m.default; });
  });
</script>
```

### Symptom: "Cannot use $effect during SSR"

`$effect` only runs in the browser — this is correct behavior. If you see this error, you're calling a function containing `$effect` during server-side module evaluation. Ensure `$effect` is only used inside component `<script>` blocks or functions called from them.

### Dynamic imports for browser-only libraries

```svelte
<script>
  import { browser } from '$app/environment';

  let MapComponent = $state(null);
  $effect(() => {
    if (browser) {
      import('$lib/components/Map.svelte').then(m => {
        MapComponent = m.default;
      });
    }
  });
</script>

{#if MapComponent}
  <MapComponent />
{/if}
```

---

## Adapter-Specific Problems

### adapter-node

**Problem: Server doesn't start after build.**
```bash
# Check the output directory matches config
node build/index.js
# Default port is 3000. Override:
PORT=8080 node build/index.js
HOST=0.0.0.0 PORT=3000 node build/index.js
```

**Problem: Environment variables not available at runtime.**
Use `$env/dynamic/private` instead of `$env/static/private` for runtime env vars with adapter-node.

**Problem: Static assets not served.**
Ensure `static/` contents are copied. Check `config.kit.paths.assets` isn't misconfigured.

### adapter-static

**Problem: "Cannot use server-side features with adapter-static."**
All routes must be prerenderable. Remove or guard:
- `+page.server.ts` files with form actions
- `+server.ts` API routes
- Dynamic routes without `entries()` export

```ts
// For dynamic routes, provide entries:
export const entries = () => {
  return [{ slug: 'hello' }, { slug: 'world' }];
};
export const prerender = true;
```

**Problem: 404 on direct URL access (SPA mode).**
Configure your hosting to serve `index.html` as fallback:
```js
// svelte.config.js
adapter: adapter({ fallback: '200.html' })  // or 'index.html'
```

### adapter-vercel

**Problem: Function size too large.**
Split routes into separate serverless functions:
```js
adapter: adapter({
  split: true  // each route = separate function
})
```

**Problem: ISR not working.**
```ts
// +page.server.ts
export const config = {
  isr: { expiration: 60 }  // revalidate every 60s
};
```

### adapter-cloudflare

**Problem: Node.js built-ins not available.**
Cloudflare Workers don't support all Node APIs. Use the `nodejs_compat` flag or polyfill.

**Problem: Can't access `platform.env` (D1, KV, R2).**
```ts
// +page.server.ts
export const load: PageServerLoad = async ({ platform }) => {
  const db = platform.env.DB;  // D1 binding
  const results = await db.prepare('SELECT * FROM users').all();
  return { users: results.results };
};
```

---

## Vite Plugin Conflicts

### Symptom: Build fails with cryptic Vite errors

1. **Plugin order matters.** `sveltekit()` must be first:
   ```ts
   // vite.config.ts
   export default defineConfig({
     plugins: [
       sveltekit(),    // MUST be first
       otherPlugin()
     ]
   });
   ```

2. **Duplicate Svelte instances.** Check `node_modules` for multiple Svelte versions:
   ```bash
   find node_modules -name "svelte" -type d -maxdepth 3
   npm ls svelte
   ```
   Fix with `overrides` (npm) or `resolutions` (pnpm/yarn) in package.json.

3. **CSS plugin conflicts.** PostCSS/Tailwind issues:
   ```bash
   # Ensure postcss.config.js exists at project root
   # Use vitePreprocess() for built-in PostCSS support
   ```

4. **Hot Module Replacement (HMR) broken.** Clear `.svelte-kit` and restart:
   ```bash
   rm -rf .svelte-kit node_modules/.vite
   npm run dev
   ```

---

## Environment Variable Gotchas

### Problem: "Cannot find module '$env/static/private'"

- Ensure the variable exists in `.env` (or system env) at build time for `static` imports.
- For runtime vars, use `$env/dynamic/private`.
- Variable names are case-sensitive.

### Problem: "Unexpected token" importing env vars

```ts
// BAD: destructuring doesn't work
import { DATABASE_URL, API_KEY } from '$env/static/private';
// This is actually CORRECT syntax — if it fails, check:
// 1. Variable is defined in .env
// 2. No syntax errors in .env (no spaces around =)
// 3. Restart dev server after changing .env
```

### Problem: Public env vars undefined on client

Variables MUST be prefixed with `PUBLIC_`:
```env
# .env
PUBLIC_API_URL=https://api.example.com    ✓ accessible on client
API_SECRET=secret123                       ✗ server only
```

### Problem: Env vars empty in production

- `$env/static/*` is replaced at **build time**. Ensure vars exist during `npm run build`.
- `$env/dynamic/*` reads at **runtime**. Use for vars that differ per environment.
- With adapter-node, runtime vars are read from `process.env`.
- With adapter-cloudflare, use `platform.env`.

### Problem: `.env` not loaded

SvelteKit uses Vite's `.env` loading. Files loaded (in order):
```
.env                # always
.env.local          # always, gitignored
.env.[mode]         # e.g., .env.development
.env.[mode].local   # e.g., .env.development.local
```

---

## Module Resolution Errors

### Problem: "$lib/..." module not found

1. Check `tsconfig.json` has correct paths:
   ```json
   {
     "extends": "./.svelte-kit/tsconfig.json"
   }
   ```
2. Ensure `.svelte-kit/` is generated: run `npx svelte-kit sync`.
3. Custom aliases go in `svelte.config.js`:
   ```js
   kit: {
     alias: {
       '$components': './src/lib/components',
       '$utils': './src/lib/utils'
     }
   }
   ```

### Problem: "Cannot find module" for .svelte files in tests

```ts
// vitest.config.ts — must extend SvelteKit's Vite config
import { defineConfig } from 'vitest/config';
import { sveltekit } from '@sveltejs/kit/vite';

export default defineConfig({
  plugins: [sveltekit()],
  test: {
    include: ['src/**/*.test.ts']
  }
});
```

### Problem: Default imports from CommonJS modules fail

```ts
// BAD: may fail with CJS modules
import pkg from 'some-cjs-package';

// FIX: use named imports or dynamic import
import { specificExport } from 'some-cjs-package';
// or
const pkg = await import('some-cjs-package');
```

### Problem: "The request url ... is outside of Vite serving allow list"

Add the directory to `server.fs.allow` in `vite.config.ts`:
```ts
export default defineConfig({
  server: { fs: { allow: ['..'] } }
});
```

---

## Form Action Redirect Issues

### Problem: Redirect after form action doesn't work

```ts
// +page.server.ts
export const actions = {
  default: async ({ request }) => {
    // Process form...

    // BAD: return redirect (wrong)
    // return redirect(303, '/success');

    // CORRECT: throw redirect
    throw redirect(303, '/success');
  }
};
```

### Problem: `use:enhance` prevents redirect

Custom `use:enhance` must handle redirects:
```svelte
<form method="POST" use:enhance={() => {
  return async ({ result }) => {
    if (result.type === 'redirect') {
      goto(result.location);
    } else {
      await applyAction(result);
    }
  };
}}>
```

### Problem: "POST body missing" or data not received

```ts
// Ensure you're reading formData, not JSON:
const data = await request.formData();  // ✓ for form actions
const body = await request.json();      // ✗ form actions use formData

// For file uploads, ensure enctype:
// <form method="POST" enctype="multipart/form-data">
```

### Problem: Action returns data but form prop is null

Ensure you're using `$props()` to access the form prop, not a store:
```svelte
<script>
  let { form } = $props();  // ✓ Svelte 5
  // NOT: import { page } from '$app/stores';
</script>
```

---

## Cookie Handling Edge Cases

### Problem: Cookies not set in production

```ts
cookies.set('session', token, {
  path: '/',           // REQUIRED: must specify path
  httpOnly: true,
  secure: true,        // requires HTTPS in production
  sameSite: 'lax',
  maxAge: 60 * 60 * 24 * 7  // 7 days
});
```

**Common mistakes:**
- Missing `path: '/'` — cookie only applies to current route
- `secure: true` on HTTP — cookie silently not set
- `sameSite: 'strict'` — breaks OAuth redirects

### Problem: Cookies not readable in load functions

```ts
// +page.server.ts
export const load: PageServerLoad = async ({ cookies }) => {
  const session = cookies.get('session');
  // cookies.get() only reads cookies from the request
  // cookies set in the same request cycle are available via cookies.get()
};
```

### Problem: Cookies not sent to external APIs

SvelteKit's `fetch` inside load functions automatically forwards cookies for same-origin requests. For external APIs, use `handleFetch` hook:
```ts
export const handleFetch: HandleFetch = async ({ request, fetch, event }) => {
  if (request.url.startsWith('https://api.example.com')) {
    const session = event.cookies.get('session');
    request.headers.set('Authorization', `Bearer ${session}`);
  }
  return fetch(request);
};
```

### Problem: Cookie size limit exceeded

Cookies have a ~4KB limit. For large session data:
- Store session ID in cookie, full data in DB/Redis
- Use multiple cookies (not recommended)
- Use `locals` to pass data within a single request

---

## Prerendering Failures

### Problem: "Could not prerender — encountered a non-prerenderable route"

Dynamic server routes can't be prerendered without `entries()`:
```ts
// +page.server.ts
export const prerender = true;

// For dynamic routes, provide all possible param values:
export const entries = async () => {
  const posts = await db.getAllPostSlugs();
  return posts.map(slug => ({ slug }));
};
```

### Problem: "500 Internal Server Error during prerender"

1. Check that all data dependencies are available at build time.
2. APIs called during prerender must be accessible from the build environment.
3. Guard runtime-only code:
   ```ts
   import { building } from '$app/environment';
   if (!building) {
     // runtime-only code
   }
   ```

### Problem: Prerendered page has stale data

Prerendering runs at build time. Data is frozen. Solutions:
- Use client-side fetching for dynamic data
- Rebuild/redeploy when data changes
- Use ISR with adapter-vercel: `export const config = { isr: { expiration: 60 } };`

### Problem: Prerender crawl misses pages

SvelteKit crawls from the entry point. Link to all pages or specify them:
```js
// svelte.config.js
kit: {
  prerender: {
    entries: ['/', '/about', '/blog', '/api/sitemap.xml'],
    crawl: true   // follow links (default: true)
  }
}
```

---

## Deployment Issues Per Adapter

### adapter-node

```bash
# Build
npm run build

# Run (env vars for adapter-node)
HOST=0.0.0.0 PORT=3000 ORIGIN=https://example.com node build/index.js
```

**ORIGIN is required** for form actions and CSRF protection. Without it, POST requests return 403.

**Reverse proxy (nginx):**
```nginx
server {
    listen 80;
    server_name example.com;
    location / {
        proxy_pass http://localhost:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```
Set `PROTOCOL_HEADER=x-forwarded-proto` and `HOST_HEADER=x-forwarded-host` for correct URL resolution behind a proxy.

### adapter-static

Deploy `build/` to any static host. Configure URL rewriting for SPA fallback if `ssr = false`.

### adapter-vercel

```json
// vercel.json (usually not needed)
{
  "framework": "sveltekit"
}
```

**Edge functions:**
```ts
export const config = {
  runtime: 'edge'
};
```

### adapter-cloudflare

```toml
# wrangler.toml
name = "my-app"
compatibility_date = "2024-01-01"
compatibility_flags = ["nodejs_compat"]

[site]
bucket = ".svelte-kit/cloudflare"
```

Deploy: `npx wrangler pages deploy .svelte-kit/cloudflare`

### adapter-netlify

Mostly zero-config. For edge functions:
```ts
export const config = {
  runtime: 'edge'
};
```

Add `netlify.toml` for redirects if using SPA mode:
```toml
[[redirects]]
  from = "/*"
  to = "/200.html"
  status = 200
```
