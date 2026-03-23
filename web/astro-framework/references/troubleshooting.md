# Astro Troubleshooting Guide

## Table of Contents

- [Hydration Mismatches with Framework Components](#hydration-mismatches-with-framework-components)
- [Client Directive Not Working](#client-directive-not-working)
- [Build Errors with SSR Adapters](#build-errors-with-ssr-adapters)
- [Image Optimization Failures](#image-optimization-failures)
- [CSS Specificity Issues with Scoped Styles](#css-specificity-issues-with-scoped-styles)
- [Content Collection Schema Errors](#content-collection-schema-errors)
- [Dynamic Imports and Code Splitting](#dynamic-imports-and-code-splitting)
- [Deployment-Specific Issues](#deployment-specific-issues)
  - [Vercel](#vercel)
  - [Cloudflare Workers / Pages](#cloudflare-workers--pages)
  - [Netlify](#netlify)
  - [Docker / Node](#docker--node)

---

## Hydration Mismatches with Framework Components

### Symptoms
- Console warning: "Hydration mismatch" or "Text content does not match server-rendered HTML"
- Component renders correctly on server but flickers or re-renders on client
- Interactive elements fail to respond after initial render

### Common Causes & Fixes

**1. Date/time rendering differs between server and client:**

```tsx
// ❌ BAD — Date formatting differs between server (UTC) and client (local TZ)
function PostDate({ date }: { date: Date }) {
  return <span>{date.toLocaleDateString()}</span>;
}

// ✅ FIX — Use consistent formatting or client:only
function PostDate({ date }: { date: Date }) {
  return <span>{date.toISOString().split('T')[0]}</span>;
}

// ✅ OR — Use client:only to skip SSR entirely
<PostDate client:only="react" date={post.pubDate} />
```

**2. Browser-specific APIs used during render:**

```tsx
// ❌ BAD — window is undefined on server
function ThemeToggle() {
  const [dark, setDark] = useState(window.matchMedia('(prefers-color-scheme: dark)').matches);
  // ...
}

// ✅ FIX — Guard with useEffect or use client:only
function ThemeToggle() {
  const [dark, setDark] = useState(false);
  useEffect(() => {
    setDark(window.matchMedia('(prefers-color-scheme: dark)').matches);
  }, []);
  // ...
}
```

**3. Random values or IDs differ between server/client:**

```tsx
// ❌ BAD — crypto.randomUUID() produces different values on server vs client
const id = crypto.randomUUID();

// ✅ FIX — Use React.useId() or pass ID as a prop
import { useId } from 'react';
function Input() {
  const id = useId();
  return <><label htmlFor={id}>Name</label><input id={id} /></>;
}
```

**4. Extension-injected DOM nodes:**
Browser extensions (Grammarly, password managers) inject elements into the DOM, causing mismatches. This is usually benign — suppress with `suppressHydrationWarning`.

---

## Client Directive Not Working

### Symptoms
- Component renders as static HTML, no interactivity
- No JavaScript loads for the component
- Event handlers (onClick, onChange) don't fire

### Diagnostic Checklist

**1. Applied to a `.astro` component instead of a framework component:**

```astro
<!-- ❌ WRONG — .astro components cannot hydrate -->
<MyAstroComponent client:load />

<!-- ✅ RIGHT — Only framework components accept client directives -->
<MyReactComponent client:load />
```

**2. Missing framework integration:**

```bash
# Check if the integration is installed
npx astro add react  # or vue, svelte, solid, preact
```

Verify `astro.config.mjs`:

```js
import react from '@astrojs/react';
export default defineConfig({
  integrations: [react()],
});
```

**3. Component doesn't export a default export:**

```tsx
// ❌ BAD — Named exports won't work as islands
export function Counter() { ... }

// ✅ FIX — Must be default export
export default function Counter() { ... }
```

**4. Component imports server-only code:**

```tsx
// ❌ BAD — Importing Node.js modules in a client component
import fs from 'node:fs';

// ✅ FIX — Keep server logic in .astro frontmatter, pass data as props
```

**5. `client:visible` never triggers:**
The element might have zero height/width. Inspect the DOM — the island wrapper needs visible dimensions.

```astro
<!-- ❌ Component has no height before hydration -->
<div style="height: 0; overflow: hidden;">
  <HeavyComponent client:visible />
</div>

<!-- ✅ Give the wrapper placeholder dimensions -->
<div style="min-height: 200px;">
  <HeavyComponent client:visible />
</div>
```

**6. `client:media` query doesn't match:**
Check the media query syntax. It must be a valid CSS media query string:

```astro
<!-- ❌ Wrong syntax -->
<Menu client:media="mobile" />

<!-- ✅ Correct CSS media query -->
<Menu client:media="(max-width: 768px)" />
```

---

## Build Errors with SSR Adapters

### "Cannot find adapter" or "No adapter installed"

```bash
# Install the adapter
npx astro add vercel    # or node, netlify, cloudflare

# Verify config
cat astro.config.mjs    # should have adapter import and usage
```

### Node.js built-in module errors in edge/serverless

```
Error: Module "node:fs" is not supported in Cloudflare Workers
```

**Fix:** Don't use Node.js APIs with edge adapters. Use Web APIs instead:

```ts
// ❌ Node.js API — breaks on Cloudflare/Vercel Edge
import { readFile } from 'node:fs/promises';

// ✅ Web API — works everywhere
const data = await fetch('https://api.example.com/data').then(r => r.json());
```

For Cloudflare, use `@astrojs/cloudflare` with `runtime: { mode: 'local' }` for dev:

```js
import cloudflare from '@astrojs/cloudflare';
export default defineConfig({
  output: 'server',
  adapter: cloudflare(),
});
```

### "Top-level await is not available" (Node adapter)

Ensure Node.js 18+ and the adapter uses `mode: 'standalone'`:

```js
import node from '@astrojs/node';
export default defineConfig({
  output: 'server',
  adapter: node({ mode: 'standalone' }),
});
```

### "Mixed content" errors with hybrid mode

Every SSR page must export `prerender = false`:

```astro
---
// This page is SSR in hybrid mode
export const prerender = false;
---
```

If you forget, the page builds statically and API calls at request time fail.

### Adapter version mismatch

Keep Astro and adapter versions in sync:

```bash
npx astro@latest --version
npm update @astrojs/vercel @astrojs/node @astrojs/netlify @astrojs/cloudflare
```

---

## Image Optimization Failures

### "Image not found" or "Cannot resolve image"

```astro
<!-- ❌ BAD — String paths bypass optimization -->
<Image src="/images/hero.jpg" alt="" width={800} height={400} />

<!-- ✅ FIX — Use ESM imports for local images -->
---
import heroImg from '../assets/hero.jpg';
---
<Image src={heroImg} alt="" width={800} height={400} />
```

### Remote image errors

```
Error: Could not load image https://example.com/photo.jpg
```

**Fix:** Add domains to `astro.config.mjs`:

```js
export default defineConfig({
  image: {
    domains: ['example.com', 'cdn.example.com'],
    // OR allow all remotes (not recommended for production):
    // remotePatterns: [{ protocol: 'https' }],
  },
});
```

Remote images require explicit `width` and `height`:

```astro
<!-- ❌ Missing dimensions -->
<Image src="https://example.com/photo.jpg" alt="" />

<!-- ✅ Explicit dimensions -->
<Image src="https://example.com/photo.jpg" width={600} height={400} alt="" />
```

### Sharp installation failures

```
Error: Cannot find module 'sharp'
```

```bash
# Reinstall sharp with platform-specific binaries
npm install sharp --force

# For Docker: install system dependencies
# Alpine: apk add --no-cache vips-dev
# Debian: apt-get install -y libvips-dev
```

### Images not optimized in dev mode

This is expected. Astro only fully optimizes images during `astro build`. In dev, images serve as-is or with basic processing.

---

## CSS Specificity Issues with Scoped Styles

### Symptoms
- Styles don't apply to child components
- Styles leak between components
- Framework component styles override Astro scoped styles

### Scoped styles use attribute selectors

Astro compiles `<style>` to scoped selectors like `h1[data-astro-cid-xyz]`. This means:

```astro
<!-- Parent.astro -->
<style>
  /* This only styles h1 elements rendered by THIS component */
  h1 { color: red; }

  /* ❌ This won't style h1 inside <Child /> */
</style>
<h1>Red</h1>
<Child />
```

**Fix — Use `:global()` to reach into children:**

```astro
<style>
  /* Style all h1 elements rendered inside this component's subtree */
  :global(h1) { color: red; }

  /* Scoped parent, global child */
  .wrapper :global(h1) { color: red; }
</style>
```

### Framework component styles conflict

React/Vue/Svelte components bring their own styles. Astro scoped styles can't reach into them:

```astro
<style>
  /* ❌ Won't style elements inside ReactComponent */
  .react-wrapper button { color: blue; }

  /* ✅ Use :global() */
  .react-wrapper :global(button) { color: blue; }
</style>
<div class="react-wrapper">
  <ReactComponent client:load />
</div>
```

### Style ordering issues

Astro bundles CSS in component order. If two components style the same element, the later import wins. Force ordering with `is:inline`:

```astro
<!-- Force this style to be in the page, not bundled -->
<style is:inline>
  .override { color: red !important; }
</style>
```

### Tailwind classes not applying

```bash
# Ensure Tailwind integration is installed
npx astro add tailwind

# Check content paths in tailwind.config.mjs
export default {
  content: ['./src/**/*.{astro,html,js,jsx,md,mdx,svelte,ts,tsx,vue}'],
};
```

If dynamic classes don't work, Tailwind purges them. Use complete class names:

```astro
<!-- ❌ Dynamic classes get purged -->
<div class={`text-${color}-500`}>

<!-- ✅ Use full class names -->
<div class={color === 'red' ? 'text-red-500' : 'text-blue-500'}>
```

---

## Content Collection Schema Errors

### "Collection not found" or "No collections defined"

**Astro 5:** Config must be at `src/content.config.ts` (not `src/content/config.ts`).

```
src/
├── content.config.ts     ← Correct for Astro 5
├── content/
│   └── blog/             ← Collection source files
```

### Schema validation errors

```
Error: blog → "my-post.md" frontmatter does not match collection schema.
  - title: Required
```

**Fix:** Ensure all required fields are present in frontmatter:

```md
---
title: "My Post"          # Required by schema
description: "A post"     # Required by schema
pubDate: 2024-01-15       # Required by schema
draft: false              # Has default, optional in frontmatter
---
```

Use `.optional()` or `.default()` for non-required fields:

```ts
schema: z.object({
  title: z.string(),                       // required
  description: z.string().optional(),      // can be omitted
  draft: z.boolean().default(false),       // omitted = false
  tags: z.array(z.string()).default([]),   // omitted = []
})
```

### Date parsing issues

```ts
// ❌ z.date() fails on YAML date strings
pubDate: z.date(),

// ✅ Use z.coerce.date() to parse date strings
pubDate: z.coerce.date(),
```

### Glob loader pattern not matching files

```ts
// ❌ Wrong base path (relative to project root, not to config file)
loader: glob({ pattern: '**/*.md', base: 'content/blog' }),

// ✅ Correct: relative to project root
loader: glob({ pattern: '**/*.md', base: './src/content/blog' }),
```

### "Cannot render entry" errors

Make sure to call `.render()` on the entry, not on the data:

```astro
---
const entry = await getEntry('blog', 'my-post');
const { Content } = await entry.render();  // ✅ render the entry
---
<Content />
```

---

## Dynamic Imports and Code Splitting

### Dynamic component imports

```astro
---
// ❌ BAD — Dynamic imports don't work in .astro frontmatter the way you'd expect
const Component = await import(`../components/${name}.astro`);

// ✅ FIX — Use a map of known components
import Alert from '../components/Alert.astro';
import Card from '../components/Card.astro';
import Hero from '../components/Hero.astro';

const components = { Alert, Card, Hero };
const Component = components[name];
---
{Component && <Component {...props} />}
```

### Framework component dynamic imports

```tsx
// React lazy loading works inside client islands
import { lazy, Suspense } from 'react';
const HeavyChart = lazy(() => import('./HeavyChart'));

export default function Dashboard() {
  return (
    <Suspense fallback={<p>Loading chart...</p>}>
      <HeavyChart />
    </Suspense>
  );
}
```

### Large bundle warnings

```
Warning: Large chunk detected (>500kB)
```

**Fix strategies:**

1. **Audit client directives** — remove unnecessary `client:load`, switch to `client:visible` or `client:idle`.
2. **Split heavy framework components** — lazy-load within the island.
3. **Use `client:only`** for components that don't need SSR, reducing double-bundling.
4. **Check for accidental server code in client bundles** — large data imports or server libraries.

```bash
# Analyze bundle size
npx astro build
npx vite-bundle-visualizer  # if using Vite plugin
```

### Import.meta.glob patterns

```ts
// Collect all markdown files (Vite glob import)
const posts = import.meta.glob('./posts/**/*.md');

// Eager loading (includes content)
const posts = import.meta.glob('./posts/**/*.md', { eager: true });

// Prefer getCollection() over import.meta.glob for content
import { getCollection } from 'astro:content';
const posts = await getCollection('blog');  // ✅ Better: typed, validated
```

---

## Deployment-Specific Issues

### Vercel

**"Function timed out" in SSR:**

```js
// astro.config.mjs — increase timeout
export default defineConfig({
  output: 'server',
  adapter: vercel({
    maxDuration: 30,  // seconds (default: 10 for hobby, 60 for pro)
  }),
});
```

**Static files not found (404):**

Ensure `vercel.json` routes to the Astro handler:

```json
{
  "buildCommand": "astro build",
  "outputDirectory": "dist"
}
```

For monorepos, set the root directory in Vercel project settings.

**Image optimization conflicts:**

Vercel has its own image optimization. Disable one:

```js
// Use Astro's image optimization (recommended)
export default defineConfig({
  adapter: vercel({ imageService: true }),  // uses Vercel's service
  // OR disable Vercel's and use Astro's sharp:
  // adapter: vercel(),
  // image: { service: { entrypoint: 'astro/assets/services/sharp' } },
});
```

**Environment variables not available:**

Prefix with `PUBLIC_` for client-side access. Server-side vars work without prefix:

```ts
// Server (frontmatter, middleware, endpoints)
const apiKey = import.meta.env.API_KEY;

// Client (must be PUBLIC_)
const publicKey = import.meta.env.PUBLIC_STRIPE_KEY;
```

### Cloudflare Workers / Pages

**"Module not found: node:*" errors:**

Cloudflare Workers don't support all Node.js APIs. Enable Node.js compat:

```toml
# wrangler.toml
compatibility_flags = ["nodejs_compat"]
```

Or avoid Node.js APIs and use Web APIs / Cloudflare-specific APIs.

**KV/D1/R2 bindings not accessible:**

Access bindings through the Astro runtime:

```ts
// src/pages/api/data.ts
import type { APIRoute } from 'astro';

export const GET: APIRoute = async ({ locals }) => {
  const runtime = locals.runtime;
  const kv = runtime.env.MY_KV_NAMESPACE;
  const value = await kv.get('key');
  return Response.json({ value });
};
```

**Build output too large:**

Cloudflare Workers have a 10MB compressed limit (25MB for paid). Split routes or use Pages:

```bash
# Use Pages instead of Workers for larger sites
npx wrangler pages deploy dist/
```

### Netlify

**Serverless function cold starts:**

```js
export default defineConfig({
  output: 'server',
  adapter: netlify({
    edgeMiddleware: true,  // Use edge for faster middleware
  }),
});
```

**Redirects not working:**

Astro generates `_redirects` automatically. For custom redirects, add to `public/_redirects`:

```
/old-path  /new-path  301
/api/*     /.netlify/functions/entry  200
```

**Build cache issues:**

```bash
# Clear Netlify build cache
netlify build --clear
```

**Environment variables:**

Set in Netlify UI or `netlify.toml`:

```toml
[build.environment]
NODE_VERSION = "20"
```

### Docker / Node

**"EACCES: permission denied" on port 80:**

```dockerfile
# Run as non-root on a high port, use reverse proxy for port 80
EXPOSE 4321
ENV HOST=0.0.0.0
ENV PORT=4321
USER node
CMD ["node", "dist/server/entry.mjs"]
```

**Missing sharp in Docker:**

```dockerfile
# Alpine
RUN apk add --no-cache vips-dev build-base

# Debian
RUN apt-get update && apt-get install -y libvips-dev
```

**Health check not responding:**

The Node adapter needs `mode: 'standalone'` to start its own HTTP server:

```js
adapter: node({ mode: 'standalone' }),  // not 'middleware'
```

Add a health endpoint:

```ts
// src/pages/api/health.ts
export const GET = () => Response.json({ status: 'ok' });
```

**Static assets not served:**

In standalone mode, the Node adapter serves static assets from `dist/client/`. Ensure `client` directory is in the Docker image:

```dockerfile
COPY dist/ ./dist/
# dist/client/ has static assets
# dist/server/ has the SSR server
```
