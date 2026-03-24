# Astro Troubleshooting Guide

## Table of Contents

- [Hydration Errors](#hydration-errors)
  - [Framework Component Mismatches](#framework-component-mismatches)
  - [Missing Client Directives](#missing-client-directives)
  - [Hydration Mismatch Debugging](#hydration-mismatch-debugging)
- [Build Failures](#build-failures)
  - [SSR vs Static Conflicts](#ssr-vs-static-conflicts)
  - [Adapter Issues](#adapter-issues)
  - [Module Resolution Errors](#module-resolution-errors)
- [Content Collection Errors](#content-collection-errors)
  - [Schema Validation Failures](#schema-validation-failures)
  - [Loader Errors](#loader-errors)
  - [Migration from Astro 4 to 5](#migration-from-astro-4-to-5)
- [Image Optimization Failures](#image-optimization-failures)
  - [Sharp Installation Issues](#sharp-installation-issues)
  - [Remote Image Errors](#remote-image-errors)
  - [Build-Time Image Errors](#build-time-image-errors)
- [View Transition Glitches](#view-transition-glitches)
  - [State Persistence Issues](#state-persistence-issues)
  - [Scroll Position Problems](#scroll-position-problems)
  - [Third-Party Script Conflicts](#third-party-script-conflicts)
- [TypeScript Issues](#typescript-issues)
  - [Strictness Configuration](#strictness-configuration)
  - [Type Generation Errors](#type-generation-errors)
  - [Framework Component Types](#framework-component-types)
- [Tailwind CSS in Astro](#tailwind-css-in-astro)
  - [Purging Issues](#purging-issues)
  - [Class Conflicts with Scoped Styles](#class-conflicts-with-scoped-styles)
  - [Dark Mode Configuration](#dark-mode-configuration)
- [Deployment Adapter Gotchas](#deployment-adapter-gotchas)
  - [Vercel](#vercel)
  - [Netlify](#netlify)
  - [Cloudflare](#cloudflare)
  - [Node.js Standalone](#nodejs-standalone)
- [Vite Config Conflicts](#vite-config-conflicts)
  - [Plugin Ordering](#plugin-ordering)
  - [Environment Variables](#environment-variables)
  - [Dependency Optimization](#dependency-optimization)
- [Performance Issues](#performance-issues)
  - [Slow Builds with Large Content](#slow-builds-with-large-content)
  - [Bundle Size Problems](#bundle-size-problems)
  - [Memory Issues During Build](#memory-issues-during-build)

---

## Hydration Errors

### Framework Component Mismatches

**Problem**: Error like `Hydration failed because the initial UI does not match what was rendered on the server` or `There was an error hydrating this component`.

**Causes and Fixes**:

1. **Date/time-dependent rendering** — Content that differs between server and client:
```jsx
// BAD: Different on server vs client
function Greeting() {
  return <p>Current time: {new Date().toLocaleTimeString()}</p>;
}

// FIX: Use client:only to skip SSR, or useEffect for client-side values
function Greeting() {
  const [time, setTime] = useState('');
  useEffect(() => setTime(new Date().toLocaleTimeString()), []);
  return <p>Current time: {time || 'Loading...'}</p>;
}
```

2. **Browser-only APIs used during SSR**:
```jsx
// BAD: window doesn't exist on the server
function Component() {
  const width = window.innerWidth;
  return <p>{width > 768 ? 'Desktop' : 'Mobile'}</p>;
}

// FIX: Guard browser APIs or use client:only
<Component client:only="react" />

// Or guard in component:
const width = typeof window !== 'undefined' ? window.innerWidth : 1024;
```

3. **Multiple JSX frameworks without `include`/`exclude`**:
```js
// BAD: React and Preact both try to handle .jsx
integrations: [react(), preact()]

// FIX: Scope each framework to specific directories
integrations: [
  react({ include: ['**/react/*'] }),
  preact({ include: ['**/preact/*'] }),
]
```

### Missing Client Directives

**Problem**: Framework component renders as static HTML with no interactivity.

**Fix**: Add a `client:*` directive. Without one, the component is rendered to HTML at build time and no JavaScript is shipped:

```astro
<!-- No interactivity — renders static HTML only -->
<Counter />

<!-- Interactive — hydrates on the client -->
<Counter client:load />
```

**Choosing the right directive**:
- `client:load` — Immediately needed (navigation, critical UI)
- `client:idle` — Not immediately needed (newsletter forms, secondary UI)
- `client:visible` — Below the fold (comments, footer widgets)
- `client:media="(min-width: 768px)"` — Only on matching viewports
- `client:only="react"` — Skip SSR entirely (canvas, maps, browser-dependent UI)

### Hydration Mismatch Debugging

Enable Vite's HMR overlay in `astro.config.mjs` under `vite.server.hmr.overlay: true`. Debug steps: check `typeof window` conditionals, random/date values without `useEffect`, invalid HTML nesting, browser extension injection, and try `client:only` to isolate SSR mismatches.

---

## Build Failures

### SSR vs Static Conflicts

**Problem**: `getStaticPaths() is not supported in server mode` or `Cannot use Astro.params in static mode without getStaticPaths`.

**Fixes**:

```astro
---
// In static mode (output: 'static'), dynamic routes MUST export getStaticPaths
export async function getStaticPaths() {
  // Return all possible param values
  return [
    { params: { slug: 'post-1' } },
    { params: { slug: 'post-2' } },
  ];
}
---
```

```astro
---
// In server mode (output: 'server'), DON'T use getStaticPaths
// unless the page has `export const prerender = true`
const { slug } = Astro.params;
const post = await getPost(slug);
if (!post) return Astro.redirect('/404');
---
```

**Mixing modes** — Use `prerender` export to opt individual pages:

```astro
---
// src/pages/about.astro — Prerender this page even in server mode
export const prerender = true;
---
```

```astro
---
// src/pages/dashboard.astro — Ensure this is server-rendered
// (only needed if default is static and you want SSR for this page)
export const prerender = false; // Requires output: 'server' in config
---
```

### Adapter Issues

**Problem**: `Cannot use server-rendered pages without an adapter` or adapter-specific build errors.

**Checklist**:
1. Install the adapter: `npx astro add vercel` (or netlify, cloudflare, node)
2. Ensure the adapter is in `astro.config.mjs`:
```js
import vercel from '@astrojs/vercel';
export default defineConfig({
  output: 'server',
  adapter: vercel(),
});
```
3. Check adapter version compatibility with your Astro version
4. Some adapters have specific Node.js version requirements

**Platform-specific adapter configs**:
```js
// Vercel — edge vs serverless
adapter: vercel({
  edgeMiddleware: true,
  webAnalytics: { enabled: true },
})

// Cloudflare — specify runtime
adapter: cloudflare({
  platformProxy: { enabled: true },
})

// Node — standalone vs middleware
adapter: node({ mode: 'standalone' }) // or 'middleware'
```

### Module Resolution Errors

**Problem**: `Cannot find module` or `Failed to resolve import`.

**Fixes**: Clear cache with `rm -rf node_modules/.astro`, reinstall deps, check case-sensitivity (Linux is case-sensitive). For aliases, configure `vite.resolve.alias` in `astro.config.mjs` (e.g., `'@': '/src'`).

---

## Content Collection Errors

### Schema Validation Failures

**Problem**: `Content collection schema validation error` with Zod error details.

**Debugging**:

```ts
// The error output shows exactly which field failed. Common fixes:

// Problem: date field receives string
date: z.date() // Fails on "2024-01-15"
date: z.coerce.date() // Fix: coerce string to Date

// Problem: optional field not marked as such
image: z.string() // Fails when frontmatter omits image
image: z.string().optional() // Fix: mark optional

// Problem: field has unexpected values
tags: z.array(z.string()) // Fails on tags: "javascript"
tags: z.array(z.string()).default([]) // Fix: add default
// Or transform single values:
tags: z.union([z.string(), z.array(z.string())]).transform(
  (val) => Array.isArray(val) ? val : [val]
)
```

**Image schema validation** — Use the `image()` helper from Astro:
```ts
import { defineCollection, z } from 'astro:content';
// DON'T: heroImage: z.string()
// DO: Use image() for optimizable image references
const blog = defineCollection({
  schema: ({ image }) => z.object({
    title: z.string(),
    heroImage: image().optional(),
    // Refine to enforce dimensions
    cover: image().refine((img) => img.width >= 1080, {
      message: 'Cover image must be at least 1080px wide',
    }).optional(),
  }),
});
```

### Loader Errors

**Problem**: Content collection returns empty or throws loader errors in Astro 5.

**Checklist**:
1. Ensure `content.config.ts` is at project root (not `src/content/config.ts` like Astro 4)
2. Use the correct loader:
```ts
// Astro 5 — use glob loader explicitly
import { glob } from 'astro/loaders';
const blog = defineCollection({
  loader: glob({ pattern: '**/*.{md,mdx}', base: './src/content/blog' }),
  schema: z.object({ /* ... */ }),
});
```
3. Check that the glob pattern matches your files
4. Verify the `base` path is relative to the project root

### Migration from Astro 4 to 5

Key content collection changes:

```ts
// Astro 4 (OLD)
// - Config at src/content/config.ts
// - Type: 'content' or 'data'
// - post.slug, post.render()

// Astro 5 (NEW)
// - Config at content.config.ts (project root)
// - Uses loader: glob() or file()
// - post.id (not .slug), render(post) (not post.render())

// Migration example:
// OLD (Astro 4):
const blog = defineCollection({
  type: 'content',
  schema: z.object({ title: z.string() }),
});
const { Content } = await post.render();

// NEW (Astro 5):
import { glob } from 'astro/loaders';
const blog = defineCollection({
  loader: glob({ pattern: '**/*.md', base: './src/content/blog' }),
  schema: z.object({ title: z.string() }),
});
import { render } from 'astro:content';
const { Content } = await render(post);
```

---

## Image Optimization Failures

### Sharp Installation Issues

**Problem**: `Could not find Sharp` or `sharp - Installation error`.

```bash
# Fix: reinstall sharp with platform-specific binaries
npm install sharp --force

# For Docker or CI:
npm install --os=linux --cpu=x64 sharp

# If using pnpm:
pnpm add sharp --force

# For Apple Silicon (M1/M2/M3):
npm install --os=darwin --cpu=arm64 sharp
```

If Sharp continues to fail, switch to the `squoosh` image service (slower but pure JS):
```js
// astro.config.mjs
export default defineConfig({
  image: {
    service: { entrypoint: 'astro/assets/services/squoosh' },
  },
});
```

### Remote Image Errors

**Problem**: `Could not transform image` or `Failed to fetch remote image`.

```js
// Fix: allowlist remote domains
export default defineConfig({
  image: {
    domains: ['images.unsplash.com', 'cdn.sanity.io'],
    remotePatterns: [
      { protocol: 'https', hostname: '**.cloudinary.com' },
      { protocol: 'https', hostname: '*.amazonaws.com' },
    ],
  },
});
```

For remote images, always provide `width` and `height`:
```astro
<Image
  src="https://example.com/photo.jpg"
  alt="Description"
  width={800}
  height={600}
  inferSize={false}
/>
<!-- Or use inferSize to auto-detect (slower builds) -->
<Image src="https://example.com/photo.jpg" alt="Photo" inferSize />
```

### Build-Time Image Errors

**Problem**: Images in `public/` can't be optimized; images referenced by string path fail.

```astro
---
// DON'T: String paths to images won't be optimized
// <Image src="/images/hero.jpg" /> // This won't work for src/assets images

// DO: Import images for optimization
import heroImage from '../assets/hero.jpg';
---
<Image src={heroImage} alt="Hero" />

<!-- For dynamic images, use import.meta.glob -->
---
const images = import.meta.glob<{ default: ImageMetadata }>(
  '../assets/gallery/*.{jpg,png,webp}'
);
const imagePaths = Object.entries(images);
---
{imagePaths.map(async ([path, resolver]) => {
  const { default: img } = await resolver();
  return <Image src={img} alt={path} width={400} />;
})}
```

---

## View Transition Glitches

### State Persistence Issues

**Problem**: State is lost, scripts don't re-run, or interactive elements break after navigation.

```astro
<!-- Fix 1: Use transition:persist for stateful elements -->
<Counter client:load transition:persist />

<!-- Fix 2: Re-run scripts on every navigation -->
<script>
  // This runs on initial load AND every view transition
  document.addEventListener('astro:page-load', () => {
    // Re-initialize event listeners, third-party libraries, etc.
    initDropdowns();
    initTooltips();
  });
</script>

<!-- Fix 3: Use is:inline for scripts that must re-execute -->
<script is:inline>
  // Inline scripts re-execute on every page load with View Transitions
  console.log('Page loaded:', window.location.pathname);
</script>
```

**Problem**: Global state (stores, singletons) duplicated or stale after transition.

```ts
// Use a module-level singleton that checks for existing state
let instance: AppState | null = null;

export function getAppState(): AppState {
  if (!instance) {
    instance = new AppState();
  }
  return instance;
}
```

### Scroll Position Problems

**Problem**: Page scrolls to wrong position after transition, or scroll position isn't restored.

```astro
<script>
  // Fix: Save and restore scroll for specific containers
  document.addEventListener('astro:before-swap', () => {
    const sidebar = document.getElementById('sidebar');
    if (sidebar) {
      sessionStorage.setItem('sidebarScroll', String(sidebar.scrollTop));
    }
  });

  document.addEventListener('astro:after-swap', () => {
    const sidebar = document.getElementById('sidebar');
    const saved = sessionStorage.getItem('sidebarScroll');
    if (sidebar && saved) {
      sidebar.scrollTop = parseInt(saved, 10);
    }
  });
</script>

<!-- Prevent scroll reset for same-page tab navigation -->
<a href="/page#section" data-astro-history="replace">Section</a>
```

### Third-Party Script Conflicts

**Problem**: Analytics, chat widgets, or other third-party scripts break after View Transition navigation.

```astro
<script>
  // Re-initialize third-party scripts after every navigation
  document.addEventListener('astro:page-load', () => {
    // Google Analytics
    if (typeof gtag === 'function') {
      gtag('config', 'G-XXXXX', { page_path: window.location.pathname });
    }

    // Re-initialize widgets that attach to DOM
    if (window.twttr) window.twttr.widgets.load();
  });
</script>

<!-- For scripts that MUST NOT re-execute, use transition:persist on a wrapper -->
<div transition:persist id="chat-widget">
  <script is:inline src="https://chat-widget.example.com/loader.js"></script>
</div>
```

---

## TypeScript Issues

### Strictness Configuration

**Problem**: TypeScript errors from Astro's generated types or overly strict config.

```json
// tsconfig.json — Astro's recommended base configs:
// "astro/tsconfigs/base" — Minimal type-checking
// "astro/tsconfigs/strict" — Recommended
// "astro/tsconfigs/strictest" — Maximum strictness

{
  "extends": "astro/tsconfigs/strict",
  "compilerOptions": {
    "baseUrl": ".",
    "paths": {
      "@/*": ["src/*"],
      "@components/*": ["src/components/*"]
    }
  }
}
```

### Type Generation Errors

**Problem**: `Cannot find module 'astro:content'` or missing types.

```bash
# Regenerate Astro types
npx astro sync

# This creates .astro/ directory with type definitions
# Make sure tsconfig includes it:
```

```json
{
  "extends": "astro/tsconfigs/strict",
  "include": [".astro/types.d.ts", "**/*"],
  "exclude": ["dist"]
}
```

**Problem**: Content collection types don't update after schema changes.

```bash
# Re-run sync to regenerate collection types
npx astro sync
# Types are generated in .astro/types.d.ts
```

### Framework Component Types

**Problem**: TypeScript errors when passing props between Astro and framework components.

```tsx
// React component with proper typing
interface Props {
  title: string;
  count?: number;
  children?: React.ReactNode; // Use for slot content
}

export default function Widget({ title, count = 0 }: Props) {
  return <div>{title}: {count}</div>;
}
```

```astro
---
// In Astro, framework components accept typed props
import Widget from '../components/Widget';
---
<!-- TypeScript validates these props -->
<Widget client:load title="Score" count={42} />
```

---

## Tailwind CSS in Astro

### Purging Issues

**Problem**: Tailwind classes missing in production build.

Astro's Tailwind integration automatically configures content paths. If classes are still purged:

```js
// tailwind.config.mjs
export default {
  content: [
    './src/**/*.{astro,html,js,jsx,md,mdx,svelte,ts,tsx,vue}',
    // Add paths for external packages using Tailwind classes
    './node_modules/@my-org/ui/**/*.{js,ts,jsx,tsx}',
  ],
};
```

**Problem**: Dynamic class names are purged:
```astro
<!-- BAD: Dynamic class construction — Tailwind can't detect these -->
<div class={`text-${color}-500`}>Text</div>

<!-- FIX: Use full class names with a safelist or conditional -->
<div class:list={[
  color === 'red' && 'text-red-500',
  color === 'blue' && 'text-blue-500',
  color === 'green' && 'text-green-500',
]}>Text</div>

<!-- Or safelist in config -->
```

```js
// tailwind.config.mjs
export default {
  safelist: [
    'text-red-500', 'text-blue-500', 'text-green-500',
    { pattern: /bg-(red|blue|green)-(100|500|900)/ },
  ],
};
```

### Class Conflicts with Scoped Styles

**Problem**: Astro's scoped styles conflict with Tailwind utility classes.

```astro
<!-- Scoped styles can override Tailwind. Use is:global or @apply -->
<style>
  /* This scoped style may conflict with Tailwind's h1 utilities */
  h1 { font-size: 2rem; }
</style>

<!-- Fix: Use Tailwind classes directly and avoid conflicting scoped styles -->
<h1 class="text-4xl font-bold">Title</h1>

<!-- Or use @apply in scoped styles -->
<style>
  h1 { @apply text-4xl font-bold; }
</style>
```

### Dark Mode Configuration

Set `darkMode: 'class'` in `tailwind.config.mjs`. Persist across View Transitions with an `is:inline` script that reads `localStorage.getItem('theme')`, toggles the `dark` class on `<html>`, and listens for `astro:after-swap` to reapply.

---

## Deployment Adapter Gotchas

### Vercel

**Common issues**:

1. **Edge vs Serverless** — Edge functions have a smaller API surface (no `fs`, limited Node.js APIs):
```js
// Use serverless (default) for full Node.js compatibility
adapter: vercel() // defaults to serverless

// Only use edge if you need it for performance
adapter: vercel({ edgeMiddleware: true })
```

2. **Environment variables** — Must be configured in Vercel dashboard:
```bash
# Local .env works in dev, but for production:
# Set variables in Vercel dashboard → Settings → Environment Variables
# Access with import.meta.env.VARIABLE_NAME
```

3. **Image optimization** — Use Vercel's built-in service:
```js
export default defineConfig({
  adapter: vercel({ imageService: true }),
});
```

### Netlify

**Common issues**: Set build command to `npm run build` and publish to `dist` in `netlify.toml`. Use `adapter: netlify({ edgeMiddleware: true })` for edge features. Place `_headers` and `_redirects` in `public/` for static builds.

### Cloudflare

**Common issues**: Enable `nodejs_compat` flag in `wrangler.toml` for Node.js APIs. Use `adapter: cloudflare({ platformProxy: { enabled: true } })`. Access env vars via `context.locals.runtime.env`. Pages serves from `dist/`, Workers Sites uses KV storage.

### Node.js Standalone

**Common issues**: Override defaults with `HOST=0.0.0.0 PORT=8080 node dist/server/entry.mjs`. For Express/Fastify integration, use `adapter: node({ mode: 'middleware' })` and import the handler from `dist/server/entry.mjs`.

---

## Vite Config Conflicts

### Plugin Ordering

**Problem**: Custom Vite plugins conflict with Astro's.

Add plugins under `vite.plugins`. Use `vite.ssr.noExternal` to force-bundle packages (e.g., UI libraries) and `vite.ssr.external` to keep packages external (e.g., native modules).

### Environment Variables

**Problem**: Environment variables undefined or not loading.

Only `PUBLIC_`-prefixed variables are available in client code; all variables are available server-side (frontmatter, endpoints, middleware). For type safety, declare `ImportMetaEnv` in `src/env.d.ts`.

### Dependency Optimization

**Problem**: `Optimized dependency changed. Reloading.` loop or slow dev startup.

Use `vite.optimizeDeps.include` to pre-bundle specific packages and `exclude` for linked/local packages.

---

## Performance Issues

### Slow Builds with Large Content

**Problem**: Build takes too long with hundreds or thousands of content pages.

**Fixes**:

1. **Use incremental builds** — Content Layer API (Astro 5) caches unchanged entries:
```ts
// Custom loaders can skip unchanged entries
const digest = generateDigest(entry);
if (store.get(entry.id)?.digest === digest) continue; // Skip unchanged
```

2. **Reduce image processing** — Pre-optimize images or limit sizes:
```js
export default defineConfig({
  image: {
    service: {
      entrypoint: 'astro/assets/services/sharp',
      config: { limitInputPixels: false },
    },
  },
});
```

3. **Parallelize builds** — Use `--parallel` flag or increase Node memory:
```bash
NODE_OPTIONS="--max-old-space-size=8192" npx astro build
```

4. **Split large collections** — Break monolithic collections into smaller ones with specific glob patterns.

### Bundle Size Problems

**Problem**: JavaScript bundle is larger than expected.

**Debugging**:
```bash
# Analyze the bundle
npx astro build
# Check dist/_astro/ for large .js files

# Use Vite's built-in rollup visualizer
npm install -D rollup-plugin-visualizer
```

```js
import { visualizer } from 'rollup-plugin-visualizer';
export default defineConfig({
  vite: {
    plugins: [visualizer({ open: true, gzipSize: true })],
  },
});
```

**Common causes**:
- Using `client:load` when `client:idle` or `client:visible` would suffice
- Importing entire libraries instead of tree-shakeable submodules
- Framework components that could be Astro components (no interactivity needed)

### Memory Issues During Build

**Problem**: `JavaScript heap out of memory`.

**Fix**: Set `NODE_OPTIONS="--max-old-space-size=8192"` before `astro build`. Reduce usage by pre-optimizing images, using `import.meta.glob` with `{ eager: false }`, and avoiding loading all content entries in a single page.
