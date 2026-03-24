# SvelteKit Troubleshooting Guide

## Table of Contents

- [Hydration Mismatches](#hydration-mismatches)
- [$state Reactivity Gotchas](#state-reactivity-gotchas)
  - [Object Mutation Issues](#object-mutation-issues)
  - [Array Method Gotchas](#array-method-gotchas)
  - [Reassignment vs Mutation with $state.raw](#reassignment-vs-mutation-with-stateraw)
- [Form Action Issues](#form-action-issues)
  - [Redirect vs Return](#redirect-vs-return)
  - [Missing Form Data](#missing-form-data)
  - [CSRF and Cross-Origin Forms](#csrf-and-cross-origin-forms)
- [Load Function Debugging](#load-function-debugging)
  - [Waterfall Detection](#waterfall-detection)
  - [Load Not Re-Running](#load-not-re-running)
  - [Data Not Available in Component](#data-not-available-in-component)
- [Prerender Errors with Dynamic Content](#prerender-errors-with-dynamic-content)
- [Rune Initialization Errors](#rune-initialization-errors)
- [CORS in API Routes](#cors-in-api-routes)
- [Cookies in Load Functions](#cookies-in-load-functions)
- [Adapter-Specific Issues](#adapter-specific-issues)
  - [Vercel: Edge vs Serverless](#vercel-edge-vs-serverless)
  - [Cloudflare: Module Workers](#cloudflare-module-workers)
  - [Node Adapter](#node-adapter)
  - [Static Adapter](#static-adapter)
- [Deployment Troubleshooting](#deployment-troubleshooting)
  - [General Deployment Issues](#general-deployment-issues)
  - [Vercel Deployment](#vercel-deployment)
  - [Cloudflare Pages Deployment](#cloudflare-pages-deployment)
  - [Docker Deployment](#docker-deployment)
- [Common TypeScript Errors](#common-typescript-errors)
- [Performance Issues](#performance-issues)

---

## Hydration Mismatches

**Symptom:** Console warning "Hydration failed" or content flickers on load.

**Cause:** Server-rendered HTML differs from client-rendered DOM.

### Common Triggers and Fixes

**1. Browser-only APIs in component body:**

```svelte
<!-- ❌ Date.now() differs between server and client -->
<script>
  let timestamp = Date.now();
</script>
<p>{timestamp}</p>

<!-- ✅ Use $effect or onMount for browser-only values -->
<script>
  import { browser } from '$app/environment';
  let timestamp = $state(0);

  $effect(() => {
    timestamp = Date.now();
  });
</script>
<p>{timestamp || 'Loading...'}</p>
```

**2. `localStorage` / `sessionStorage` access:**

```svelte
<!-- ❌ Crashes on server, mismatches on client -->
<script>
  let theme = localStorage.getItem('theme') ?? 'light';
</script>

<!-- ✅ Guard with browser check or use $effect -->
<script>
  import { browser } from '$app/environment';
  let theme = $state('light');

  $effect(() => {
    theme = localStorage.getItem('theme') ?? 'light';
  });
</script>
```

**3. Random values or UUIDs:**

```svelte
<!-- ❌ Different on server vs client -->
<script>
  let id = crypto.randomUUID();
</script>

<!-- ✅ Generate in load function and pass as data -->
<!-- +page.server.ts -->
<!-- export const load = () => ({ id: crypto.randomUUID() }); -->
```

**4. Third-party scripts modifying DOM:**

```svelte
<!-- ✅ Load browser-only components dynamically -->
<script>
  import { browser } from '$app/environment';
  import { onMount } from 'svelte';

  let MapComponent: any = $state(null);

  onMount(async () => {
    MapComponent = (await import('$lib/components/Map.svelte')).default;
  });
</script>

{#if MapComponent}
  <MapComponent />
{:else}
  <div class="map-placeholder">Loading map...</div>
{/if}
```

**5. Extensions modifying DOM:** Browser extensions injecting elements cause mismatches.
No fix needed — these warnings from extensions are harmless.

---

## $state Reactivity Gotchas

### Object Mutation Issues

**Symptom:** Updating a property doesn't trigger a re-render.

```svelte
<script>
  // ✅ $state creates deep reactive proxy — mutations auto-track
  let user = $state({ name: 'Alice', settings: { theme: 'dark' } });
  user.name = 'Bob';                    // ✅ Triggers update
  user.settings.theme = 'light';        // ✅ Triggers update (deep)

  // ❌ Spreading creates a new non-reactive object
  let copy = { ...user };
  copy.name = 'Charlie';               // ❌ Not reactive — copy is plain object

  // ❌ Destructuring loses reactivity
  let { name } = user;
  name = 'Dave';                        // ❌ Updates local variable, not user.name

  // ✅ To create a new reactive copy:
  let copy2 = $state({ ...user });     // New reactive state from spread
</script>
```

**Symptom:** Replacing an entire object doesn't trigger derived updates.

```svelte
<script>
  let config = $state({ host: 'localhost', port: 3000 });
  let url = $derived(`http://${config.host}:${config.port}`);

  // ✅ Replacing the whole object works fine
  config = { host: 'example.com', port: 443 };

  // ✅ Mutating properties works fine
  config.port = 8080;
</script>
```

### Array Method Gotchas

```svelte
<script>
  let items = $state([1, 2, 3]);

  // ✅ Mutating methods trigger updates with $state
  items.push(4);        // ✅ Works
  items.splice(0, 1);   // ✅ Works
  items[0] = 10;        // ✅ Works
  items.sort();          // ✅ Works

  // ❌ With $state.raw, mutations do NOT trigger
  let rawItems = $state.raw([1, 2, 3]);
  rawItems.push(4);     // ❌ No update

  // ✅ With $state.raw, use reassignment
  rawItems = [...rawItems, 4];  // ✅ Works
</script>
```

**Gotcha: `filter`/`map`/`slice` return new arrays but don't trigger updates
on the original:**

```svelte
<script>
  let items = $state([1, 2, 3, 4, 5]);

  // ❌ Does nothing — filtered is a new array, items unchanged
  items.filter(x => x > 2);

  // ✅ Reassign to trigger update
  items = items.filter(x => x > 2);
</script>
```

### Reassignment vs Mutation with $state.raw

```svelte
<script>
  let data = $state.raw({ count: 0, items: [] });

  // ❌ These do NOT trigger updates with $state.raw
  data.count++;
  data.items.push('new');

  // ✅ Must reassign the entire variable
  data = { ...data, count: data.count + 1 };
  data = { ...data, items: [...data.items, 'new'] };
</script>
```

---

## Form Action Issues

### Redirect vs Return

**Symptom:** Form submits but nothing happens, or redirect doesn't work.

```ts
// +page.server.ts
import { fail, redirect } from '@sveltejs/kit';

export const actions = {
  login: async ({ request, cookies }) => {
    const data = await request.formData();

    // ❌ Using return after redirect — redirect is thrown, not returned
    // return redirect(303, '/dashboard');

    // ✅ redirect() throws — it must not be in a try/catch that swallows it
    redirect(303, '/dashboard');
  }
};
```

**Critical:** `redirect()` and `error()` throw exceptions. Never catch them:

```ts
// ❌ BAD: try/catch swallows the redirect
try {
  const user = await authenticate(email, password);
  if (user) redirect(303, '/dashboard');
} catch (e) {
  // This catches the redirect too!
  return fail(500, { error: 'Something went wrong' });
}

// ✅ GOOD: Let redirect/error propagate
const user = await authenticate(email, password);
if (!user) return fail(401, { error: 'Invalid credentials' });
redirect(303, '/dashboard');
```

**Returning data from actions:**

```ts
export const actions = {
  create: async ({ request }) => {
    const data = await request.formData();
    const title = data.get('title') as string;

    if (!title) {
      // fail() returns data accessible via the `form` prop
      return fail(400, { title, missing: true });
    }

    await db.create({ title });
    // Return success data (accessible via form prop)
    return { success: true };
  }
};
```

### Missing Form Data

**Symptom:** `formData.get()` returns `null`.

```svelte
<!-- ❌ Missing name attribute -->
<input type="text" value={title} />

<!-- ✅ Must have name attribute for FormData -->
<input type="text" name="title" value={title} />

<!-- ❌ Button outside form -->
<form method="POST">
  <input name="title" />
</form>
<button>Submit</button>

<!-- ✅ Button inside form or use form attribute -->
<form method="POST" id="myform">
  <input name="title" />
  <button>Submit</button>
</form>
```

### CSRF and Cross-Origin Forms

SvelteKit automatically checks the `Origin` header for POST requests. If your form
is submitted from a different origin, it will be rejected with 403.

```ts
// svelte.config.js — configure CSRF
export default {
  kit: {
    csrf: {
      checkOrigin: true // default: true. Set false only for API-only routes
    }
  }
};
```

For API routes that accept cross-origin requests, handle CORS headers manually instead
of disabling CSRF globally.

---

## Load Function Debugging

### Waterfall Detection

**Symptom:** Page loads slowly despite fast individual queries.

```ts
// ❌ Sequential waterfall — each await blocks the next
export const load = async ({ fetch }) => {
  const user = await fetch('/api/user').then(r => r.json());
  const posts = await fetch(`/api/posts?author=${user.id}`).then(r => r.json());
  const comments = await fetch('/api/comments').then(r => r.json());
  return { user, posts, comments };
};

// ✅ Parallelize independent fetches
export const load = async ({ fetch }) => {
  const userPromise = fetch('/api/user').then(r => r.json());
  const commentsPromise = fetch('/api/comments').then(r => r.json());
  const user = await userPromise;
  const [posts, comments] = await Promise.all([
    fetch(`/api/posts?author=${user.id}`).then(r => r.json()),
    commentsPromise
  ]);
  return { user, posts, comments };
};
```

**Tip:** Use the browser's Network tab waterfall view to visualize sequential requests.
SvelteKit's fetch calls during SSR appear in server logs.

### Load Not Re-Running

**Symptom:** Navigating to a different URL with the same route doesn't update data.

```ts
// ❌ Load uses a hardcoded value — never invalidates
export const load = async () => {
  const posts = await db.getPosts();
  return { posts };
};

// ✅ Load depends on params — re-runs when params change
export const load = async ({ params }) => {
  const post = await db.getPost(params.slug);
  return { post };
};

// ✅ Load depends on URL — re-runs when URL changes
export const load = async ({ url }) => {
  const page = Number(url.searchParams.get('page') ?? 1);
  const posts = await db.getPosts({ page });
  return { posts, page };
};
```

**Force re-run with `depends()` and `invalidate()`:**

```ts
// +page.server.ts
export const load = async ({ depends }) => {
  depends('app:posts');
  const posts = await db.getPosts();
  return { posts };
};

// In component: invalidate('app:posts') to force reload
```

### Data Not Available in Component

**Symptom:** `data` prop is undefined or missing expected properties.

```svelte
<!-- ❌ Wrong: declaring data as $state instead of $props -->
<script>
  let data = $state({}); // This is new empty state, not load data
</script>

<!-- ✅ Correct: destructure from $props -->
<script>
  let { data } = $props();
</script>
<h1>{data.title}</h1>
```

**Layout data merging:** Child pages access both their own data and parent layout data:

```ts
// +layout.server.ts returns { user }
// +page.server.ts returns { posts }

// In +page.svelte, data contains { user, posts } (merged)
```

If layout and page return the same key, the page's value wins.

---

## Prerender Errors with Dynamic Content

**Symptom:** Build fails with "Cannot prerender pages with actions" or similar errors.

### Pages with Form Actions

```ts
// ❌ Can't prerender pages that have form actions
// +page.server.ts
export const prerender = true; // Error!
export const actions = { default: async () => { /* ... */ } };

// ✅ Remove prerender, or remove actions
export const prerender = false; // Or just don't set it
```

### Dynamic API Calls in Prerendered Pages

```ts
// ❌ Fetching dynamic data during prerender
export const prerender = true;
export const load = async ({ fetch }) => {
  const data = await fetch('https://api.example.com/live-data'); // Will use build-time data
  return { data: await data.json() };
};

// ✅ If data changes, don't prerender — or accept stale build-time data
```

### Missing Entries for Dynamic Routes

```ts
// ❌ SvelteKit can't discover all /blog/[slug] pages automatically
// Build error: "404 /blog/some-post"

// ✅ Provide entries explicitly
export const entries = async () => {
  const posts = await db.getAllSlugs();
  return posts.map(slug => ({ slug }));
};
export const prerender = true;
```

### Links to Non-Prerendered Pages

```ts
// ❌ Prerendered page links to a non-prerendered page
// SvelteKit crawls links and tries to prerender them

// ✅ Use data-sveltekit-preload-data="off" or configure prerender.handleMissingId
// svelte.config.js
export default {
  kit: {
    prerender: {
      handleHttpError: 'warn',        // Don't fail on broken links
      handleMissingId: 'warn',        // Don't fail on missing #anchors
      entries: ['/', '/about', '/blog'] // Explicit entry points
    }
  }
};
```

---

## Rune Initialization Errors

### "Cannot access X before initialization"

**Symptom:** Runtime error about accessing a rune variable before initialization.

```svelte
<!-- ❌ Using $derived before the $state it depends on is declared -->
<script>
  let doubled = $derived(count * 2); // Error: count not yet declared
  let count = $state(0);
</script>

<!-- ✅ Declare $state before $derived that uses it -->
<script>
  let count = $state(0);
  let doubled = $derived(count * 2);
</script>
```

### "Runes are only available inside .svelte and .svelte.ts files"

```ts
// ❌ Using runes in a regular .ts file
// src/lib/store.ts
let count = $state(0); // Error!

// ✅ Rename to .svelte.ts
// src/lib/store.svelte.ts
let count = $state(0); // Works!
```

### "$state can only be used as a variable declaration initializer"

```ts
// ❌ Using $state in an expression
let count;
count = $state(0); // Error!

// ✅ Must be in the declaration
let count = $state(0);

// ❌ Using $state in a function parameter
function init(val = $state(0)) {} // Error!

// ✅ Use $state only in variable declarations or class fields
function init(initialVal: number) {
  let val = $state(initialVal);
  return { get val() { return val; } };
}
```

### "$effect can only be used inside a component or $effect.root"

```ts
// ❌ $effect at module top level in .svelte.ts
// src/lib/watcher.svelte.ts
$effect(() => { /* ... */ }); // Error outside component lifecycle

// ✅ Wrap in $effect.root (returns cleanup function)
const cleanup = $effect.root(() => {
  $effect(() => {
    console.log('Watching...');
  });
});

// Or use inside a component where it has a lifecycle context
```

---

## CORS in API Routes

### Setting CORS Headers

```ts
// src/routes/api/data/+server.ts
import { json } from '@sveltejs/kit';
import type { RequestHandler } from './$types';

const ALLOWED_ORIGINS = ['https://example.com', 'https://app.example.com'];

export const GET: RequestHandler = async ({ request }) => {
  const origin = request.headers.get('origin') ?? '';
  const headers: Record<string, string> = {};

  if (ALLOWED_ORIGINS.includes(origin)) {
    headers['Access-Control-Allow-Origin'] = origin;
    headers['Access-Control-Allow-Credentials'] = 'true';
  }

  const data = await fetchData();
  return json(data, { headers });
};

// Handle preflight OPTIONS request
export const OPTIONS: RequestHandler = async ({ request }) => {
  const origin = request.headers.get('origin') ?? '';
  const headers: Record<string, string> = {
    'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, Authorization',
    'Access-Control-Max-Age': '86400'
  };

  if (ALLOWED_ORIGINS.includes(origin)) {
    headers['Access-Control-Allow-Origin'] = origin;
    headers['Access-Control-Allow-Credentials'] = 'true';
  }

  return new Response(null, { status: 204, headers });
};
```

### Global CORS via Hooks

```ts
// src/hooks.server.ts
import type { Handle } from '@sveltejs/kit';

export const handle: Handle = async ({ event, resolve }) => {
  // Only apply to /api routes
  if (event.url.pathname.startsWith('/api')) {
    if (event.request.method === 'OPTIONS') {
      return new Response(null, {
        status: 204,
        headers: {
          'Access-Control-Allow-Origin': '*',
          'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
          'Access-Control-Allow-Headers': 'Content-Type, Authorization'
        }
      });
    }
  }

  const response = await resolve(event);

  if (event.url.pathname.startsWith('/api')) {
    response.headers.set('Access-Control-Allow-Origin', '*');
  }

  return response;
};
```

---

## Cookies in Load Functions

### Setting Cookies

**Symptom:** `cookies.set()` doesn't work or cookie disappears.

```ts
// ❌ Missing required 'path' option (SvelteKit requires it)
cookies.set('session', token);

// ✅ Always specify path
cookies.set('session', token, {
  path: '/',
  httpOnly: true,
  sameSite: 'lax',
  secure: true,
  maxAge: 60 * 60 * 24 * 7 // 7 days
});
```

### Reading Cookies in Universal Load

```ts
// ❌ Can't access cookies in +page.ts (universal load)
// +page.ts
export const load = async ({ cookies }) => { // Error: cookies not available
  const session = cookies.get('session');
};

// ✅ Access cookies in +page.server.ts (server load)
// +page.server.ts
export const load = async ({ cookies }) => {
  const session = cookies.get('session');
  return { isLoggedIn: !!session };
};

// ✅ Or read via document.cookie on client (not recommended)
// ✅ Or pass cookie data from layout.server.ts through the data prop
```

### Cookie Not Sent with Fetch

```ts
// ❌ External fetch doesn't include cookies
export const load = async ({ fetch }) => {
  const res = await fetch('https://api.example.com/me');
  // Cookies NOT sent to external domains
};

// ✅ Use handleFetch hook to add credentials
// src/hooks.server.ts
export const handleFetch = async ({ request, fetch, event }) => {
  if (request.url.startsWith('https://api.example.com')) {
    const session = event.cookies.get('session');
    request.headers.set('Authorization', `Bearer ${session}`);
  }
  return fetch(request);
};
```

---

## Adapter-Specific Issues

### Vercel: Edge vs Serverless

**Edge Functions:**
- Runs at CDN edge, lower latency
- Limited Node.js APIs (no `fs`, `child_process`, etc.)
- 25MB max bundle size
- Shorter execution time limits

```ts
// svelte.config.js — per-route runtime selection
import adapter from '@sveltejs/adapter-vercel';

export default {
  kit: {
    adapter: adapter({
      runtime: 'nodejs22.x', // Default runtime for all routes
      regions: ['iad1'],
      split: true // Split each route into separate functions
    })
  }
};
```

```ts
// src/routes/api/fast/+server.ts — edge per route
export const config = {
  runtime: 'edge'
};
```

**Common Vercel issues:**
- `FUNCTION_INVOCATION_TIMEOUT`: Increase timeout in vercel.json or optimize queries
- `EDGE_FUNCTION_INVOCATION_FAILED`: Check for Node.js-only APIs in edge routes
- Cold starts: Use edge runtime or Vercel's fluid compute for latency-sensitive routes

### Cloudflare: Module Workers

**Symptom:** "Cannot find module" or "X is not a function" errors.

Cloudflare Workers use a different module system. Key differences:
- No `node:` built-in modules (use `cloudflare:` equivalents or polyfills)
- No `__dirname`, `__filename`, `process.env` (use platform env bindings)
- `fetch` is available globally but behaves differently

```ts
// svelte.config.js for Cloudflare Pages
import adapter from '@sveltejs/adapter-cloudflare';

export default {
  kit: {
    adapter: adapter({
      routes: {
        include: ['/*'],
        exclude: ['<all>'] // Exclude static assets
      }
    })
  }
};
```

```ts
// Access Cloudflare bindings (KV, D1, R2, etc.)
// src/app.d.ts
declare global {
  namespace App {
    interface Platform {
      env: {
        MY_KV: KVNamespace;
        MY_DB: D1Database;
        MY_BUCKET: R2Bucket;
      };
    }
  }
}

// +page.server.ts
export const load = async ({ platform }) => {
  const value = await platform?.env.MY_KV.get('key');
  return { value };
};
```

### Node Adapter

**Common issues:**

```bash
# ❌ "Cannot find module './handler.js'" after build
# Make sure you're running from the correct directory
node build/index.js  # Not just node build

# Set required env vars
PORT=3000 HOST=0.0.0.0 ORIGIN=https://myapp.com node build

# ❌ "ORIGIN must be set" error
# ORIGIN is required for CSRF protection in production
ORIGIN=https://myapp.com node build
```

```ts
// svelte.config.js — Node adapter options
import adapter from '@sveltejs/adapter-node';

export default {
  kit: {
    adapter: adapter({
      out: 'build',
      precompress: true,  // Generate .gz and .br files
      envPrefix: 'APP_'   // Only expose APP_* env vars
    })
  }
};
```

### Static Adapter

**Common issues:**

```ts
// ❌ "Not all pages could be prerendered"
// Static adapter requires ALL pages to be prerenderable

// ✅ Set fallback for SPA mode
import adapter from '@sveltejs/adapter-static';

export default {
  kit: {
    adapter: adapter({
      pages: 'build',
      assets: 'build',
      fallback: '200.html',  // SPA fallback
      precompress: true
    })
  }
};

// ✅ Root layout must enable prerender for fully static
// src/routes/+layout.ts
export const prerender = true;
export const ssr = true; // or false for pure SPA
```

---

## Deployment Troubleshooting

### General Deployment Issues

**"Top-level await is not available" in build output:**

```ts
// ❌ Top-level await in server modules may fail with some bundler targets
// src/lib/server/db.ts
const db = await initializeDatabase(); // May fail

// ✅ Use lazy initialization
let _db: Database | null = null;
export async function getDb() {
  if (!_db) _db = await initializeDatabase();
  return _db;
}
```

**Assets returning 404 after deployment:**

```ts
// svelte.config.js — set base path if not deployed at root
export default {
  kit: {
    paths: {
      base: '/my-app'  // If deployed at example.com/my-app/
    }
  }
};
```

### Vercel Deployment

```json
// vercel.json for SvelteKit
{
  "framework": "sveltekit",
  "buildCommand": "npm run build",
  "installCommand": "npm ci",
  "functions": {
    "api/**/*.ts": {
      "maxDuration": 30
    }
  }
}
```

### Cloudflare Pages Deployment

```toml
# wrangler.toml — for local development with Cloudflare bindings
name = "my-sveltekit-app"
compatibility_date = "2024-01-01"

[vars]
PUBLIC_SITE_NAME = "My App"

[[kv_namespaces]]
binding = "MY_KV"
id = "abc123"
```

```bash
# Build and deploy
npm run build
npx wrangler pages deploy .svelte-kit/cloudflare

# Local dev with bindings
npx wrangler pages dev -- npm run dev
```

### Docker Deployment

```dockerfile
# Dockerfile for SvelteKit with Node adapter
FROM node:22-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build
RUN npm prune --production

FROM node:22-alpine
WORKDIR /app
COPY --from=builder /app/build ./build
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/package.json ./

ENV PORT=3000
ENV HOST=0.0.0.0
EXPOSE 3000
CMD ["node", "build"]
```

```bash
# Build and run
docker build -t my-sveltekit-app .
docker run -p 3000:3000 -e ORIGIN=https://myapp.com my-sveltekit-app
```

---

## Common TypeScript Errors

### "Cannot find module './$types'"

```bash
# Generated types are missing — run the dev server to generate them
npm run dev
# Or run check
npx svelte-check

# Make sure tsconfig.json extends SvelteKit's config
# tsconfig.json should contain:
# "extends": "./.svelte-kit/tsconfig.json"
```

### "Type 'PageData' is not assignable"

```ts
// ❌ Type mismatch between load return and page expectations
// Ensure load function return type matches what the component uses

// +page.server.ts
export const load = async () => {
  return { posts: await db.getPosts() }; // returns { posts: Post[] }
};

// +page.svelte — data type is inferred from load
// let { data }: { data: { posts: Post[] } } = $props(); // Manual typing
// Better: let { data } = $props(); // Types auto-inferred from $types
```

### "Property does not exist on type 'App.Locals'"

```ts
// src/app.d.ts — declare your custom types
declare global {
  namespace App {
    interface Locals {
      user: { id: string; email: string; role: string } | null;
    }
    interface Error {
      message: string;
      code?: string;
    }
    interface PageData {
      // Shared across all pages
    }
    interface PageState {
      // For shallow routing state
      showModal?: boolean;
    }
  }
}
export {};
```

---

## Performance Issues

### Large Bundle Size

```bash
# Analyze bundle
npx vite-bundle-visualizer

# Check for accidentally imported server code in client
# Look for $lib/server/ imports in +page.svelte or +page.ts (not +page.server.ts)
```

### Slow Load Functions

```ts
// Use streaming for slow data
export const load = async () => {
  return {
    fast: await db.getFastData(),       // Blocks render
    slow: db.getSlowData()              // Streams — doesn't block
  };
};
```

### Memory Leaks with $effect

```svelte
<script>
  // ❌ Event listener not cleaned up
  $effect(() => {
    window.addEventListener('resize', handleResize);
    // Missing cleanup!
  });

  // ✅ Return cleanup function
  $effect(() => {
    window.addEventListener('resize', handleResize);
    return () => window.removeEventListener('resize', handleResize);
  });
</script>
```

### Unnecessary Reactivity

```svelte
<script>
  // ❌ Expensive computation re-runs on every change
  let filtered = $derived(
    hugeArray.filter(item => item.matches(criteria)).sort(compareFn)
  );

  // ✅ Use $derived.by for complex derivations with early exit
  let filtered = $derived.by(() => {
    if (!criteria) return hugeArray;
    return hugeArray.filter(item => item.matches(criteria)).sort(compareFn);
  });
</script>
```
