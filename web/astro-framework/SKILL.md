---
name: astro-framework
description: >-
  Use this skill when working with Astro framework projects (.astro files, astro.config.mjs,
  src/pages/, src/content/, content.config.ts), building content-driven websites, blogs, docs sites,
  marketing pages, or portfolios with Astro. Triggers: creating/editing .astro components, configuring
  content collections, adding client directives (client:load, client:idle, client:visible), setting up
  SSR adapters (Vercel, Netlify, Cloudflare, Node), using astro:assets or Image component, writing
  Astro middleware, creating API routes in src/pages/api/, integrating React/Vue/Svelte/Solid islands,
  configuring view transitions, or deploying Astro sites.
  Do NOT use for: pure React/Next.js/Nuxt/SvelteKit/Remix projects without Astro, general HTML/CSS
  questions unrelated to Astro, Node.js/Express backend APIs, or static site generators like Hugo/Jekyll/11ty.
---

# Astro Framework

## Architecture

Astro is a content-driven web framework. Core principles:

- **Zero JS by default.** Astro renders all components to static HTML at build time. No client JS ships unless explicitly opted in.
- **Islands architecture.** Interactive UI components ("islands") hydrate independently. Each island loads its own JS in isolation.
- **Partial hydration.** Use client directives to control when/if a component hydrates. Mix static and interactive content on one page.
- **Multi-framework.** Use React, Vue, Svelte, Solid, Preact, or Lit components in the same project. Each renders as an island.
- **Server Islands (Astro 5).** Mix cached static HTML with dynamic server-rendered components for personalization without sacrificing static performance.

## Project Structure

```
├── astro.config.mjs          # Astro configuration
├── src/
│   ├── pages/                # File-based routing (*.astro, *.md, *.mdx)
│   │   └── api/              # Server endpoints (*.ts, *.js)
│   ├── layouts/              # Layout components
│   ├── components/           # UI components (.astro, .tsx, .vue, .svelte)
│   ├── content/              # Content collection source files
│   │   ├── blog/             # Collection: blog posts
│   │   └── docs/             # Collection: documentation
│   ├── styles/               # Global stylesheets
│   ├── middleware.ts          # Request/response middleware
│   └── content.config.ts     # Content collection schemas (Astro 5)
├── public/                   # Static assets (copied verbatim, no processing)
└── package.json
```

In Astro 5, content config lives at `src/content.config.ts` (not inside `content/`).

## Routing

### File-Based Routes

Every file in `src/pages/` becomes a route:

```
src/pages/index.astro        → /
src/pages/about.astro        → /about
src/pages/blog/index.astro   → /blog
src/pages/blog/first.md      → /blog/first
```

### Dynamic Routes

Use bracket notation for dynamic segments:

```astro
// src/pages/blog/[slug].astro
---
export function getStaticPaths() {
  return [
    { params: { slug: 'post-1' } },
    { params: { slug: 'post-2' } },
  ];
}
const { slug } = Astro.params;
---
<h1>{slug}</h1>
```

### Rest Parameters

Catch-all routes with `[...path]`:

```astro
// src/pages/docs/[...path].astro
---
export function getStaticPaths() {
  return [
    { params: { path: 'getting-started' } },
    { params: { path: 'guides/routing' } },
    { params: { path: undefined } },  // matches /docs
  ];
}
---
```

## Components

### .astro Syntax

Two parts separated by `---` fences: frontmatter (JS/TS) and template (HTML-like):

```astro
---
// Frontmatter: runs at build time (server only)
import Layout from '../layouts/Base.astro';
import Counter from '../components/Counter.tsx';

interface Props {
  title: string;
  tags?: string[];
}

const { title, tags = [] } = Astro.props;
const formattedDate = new Date().toLocaleDateString();
---

<Layout title={title}>
  <h1>{title}</h1>
  <p>Published: {formattedDate}</p>
  <ul>
    {tags.map(tag => <li>{tag}</li>)}
  </ul>
  <Counter client:visible />
  <slot />
</Layout>
```

### Expressions

Use `{}` for JS expressions in templates. Conditionals and iteration:

```astro
{showBanner && <Banner />}
{items.map(item => <Card title={item.title} />)}
{condition ? <A /> : <B />}
```

### Slots

Named and default slots for composition:

```astro
// Card.astro
<div class="card">
  <div class="header"><slot name="header" /></div>
  <div class="body"><slot /></div>
  <div class="footer"><slot name="footer">Default footer</slot></div>
</div>

// Usage:
<Card>
  <h2 slot="header">Title</h2>
  <p>Body content goes in the default slot.</p>
</Card>
```

### Props

Define with `Astro.props`. Use TypeScript `Props` interface for type safety:

```astro
---
interface Props {
  variant: 'primary' | 'secondary';
  size?: 'sm' | 'md' | 'lg';
}
const { variant, size = 'md' } = Astro.props;
---
<button class={`btn-${variant} btn-${size}`}><slot /></button>
```

## Content Collections

### Define Collections (Astro 5)

```ts
// src/content.config.ts
import { defineCollection } from 'astro:content';
import { glob } from 'astro/loaders';
import { z } from 'astro/zod';

const blog = defineCollection({
  loader: glob({ pattern: '**/*.{md,mdx}', base: './src/content/blog' }),
  schema: z.object({
    title: z.string(),
    description: z.string(),
    pubDate: z.coerce.date(),
    updatedDate: z.coerce.date().optional(),
    heroImage: z.string().optional(),
    tags: z.array(z.string()).default([]),
    draft: z.boolean().default(false),
  }),
});

export const collections = { blog };
```

### Query Collections

```astro
---
import { getCollection, getEntry } from 'astro:content';

// Get all published posts
const posts = await getCollection('blog', ({ data }) => !data.draft);

// Sort by date
const sorted = posts.sort((a, b) => b.data.pubDate.valueOf() - a.data.pubDate.valueOf());

// Get single entry by ID
const entry = await getEntry('blog', 'my-post');

// Render content
const { Content, headings } = await entry.render();
---
<Content />
```

## Framework Integrations

Install integrations via `npx astro add react` (or vue, svelte, solid, preact, lit).

```js
// astro.config.mjs
import { defineConfig } from 'astro/config';
import react from '@astrojs/react';
import vue from '@astrojs/vue';
import svelte from '@astrojs/svelte';

export default defineConfig({
  integrations: [react(), vue(), svelte()],
});
```

Use framework components as islands inside .astro files:

```astro
---
import ReactCounter from './Counter.tsx';
import VueWidget from './Widget.vue';
import SvelteToggle from './Toggle.svelte';
---
<ReactCounter client:load />
<VueWidget client:visible />
<SvelteToggle client:idle />
```

## Client Directives

Control hydration behavior. Without a directive, framework components render as static HTML only.

| Directive | When it hydrates | Use case |
|-----------|-----------------|----------|
| `client:load` | Immediately on page load | Critical interactive UI (nav menus, auth forms) |
| `client:idle` | After page load, when browser is idle | Non-critical UI (analytics widgets, chat) |
| `client:visible` | When scrolled into viewport | Below-fold content (carousels, comments) |
| `client:media="(query)"` | When CSS media query matches | Mobile-only components, responsive UI |
| `client:only="react"` | Client-only, no SSR | Components using browser APIs (canvas, window) |

```astro
<SearchBar client:load />                           <!-- Immediate -->
<CommentSection client:visible />                   <!-- When scrolled into view -->
<MobileMenu client:media="(max-width: 768px)" />   <!-- Media query match -->
<ThreeScene client:only="react" />                  <!-- Client-only, no SSR -->
```

**Rule:** Never add a client directive to `.astro` components. They are server-only.

## Styling

- **Scoped CSS:** `<style>` in .astro files is auto-scoped to that component.
- **Global styles:** Use `<style is:global>` or `import '../styles/global.css'` in frontmatter.
- **Tailwind:** Install with `npx astro add tailwind`. Use utility classes directly in templates.
- **CSS Modules:** `import styles from './Component.module.css'` then `class={styles.wrapper}`.

```astro
<style>
  h1 { color: navy; }        /* Scoped: only this component's <h1> */
</style>
<style is:global>
  body { margin: 0; }        /* Global: affects entire page */
</style>
```

## Data Fetching

All frontmatter runs at build time (or request time in SSR). Use top-level `await`:

```astro
---
// Remote API
const posts = await fetch('https://api.example.com/posts').then(r => r.json());
// Content collections (preferred for local content)
import { getCollection } from 'astro:content';
const blogs = await getCollection('blog', ({ data }) => !data.draft);
---
```

Prefer `getCollection` over legacy `Astro.glob` for new projects.

## SSR and Adapters

### Output Modes

```js
// astro.config.mjs
export default defineConfig({
  output: 'static',   // Default: full static build
  output: 'server',   // Full SSR: all pages rendered on request
  output: 'hybrid',   // Static by default, opt-in SSR per page
});
```

In hybrid mode, opt into SSR per page:

```astro
---
export const prerender = false; // This page uses SSR
---
```

### Adapters

Install: `npx astro add vercel` (or node, netlify, cloudflare).

```js
// astro.config.mjs — pick one adapter for your target
import vercel from '@astrojs/vercel';       // or @astrojs/node, @astrojs/netlify, @astrojs/cloudflare
export default defineConfig({
  output: 'server',
  adapter: vercel(),                        // node({ mode: 'standalone' }), netlify(), cloudflare()
});
```

## View Transitions

Enable smooth, SPA-like page transitions without a JS framework:

```astro
---
// src/layouts/Base.astro
import { ViewTransitions } from 'astro:transitions';
---
<html>
  <head>
    <ViewTransitions />
  </head>
  <body>
    <slot />
  </body>
</html>
```

Customize per-element transitions:

```astro
<h1 transition:name="title" transition:animate="slide">{title}</h1>
<img transition:name={`hero-${slug}`} src={image} alt="" />
```

Built-in animations: `fade`, `slide`, `initial`, `none`. Create custom animations:

```astro
---
import { fade } from 'astro:transitions';
---
<div transition:animate={fade({ duration: '0.3s' })}>Content</div>
```

Persist interactive state across navigations:

```astro
<Counter client:load transition:persist />
```

## Image Optimization

Use `astro:assets` for build-time image processing:

```astro
---
import { Image } from 'astro:assets';
import heroImage from '../assets/hero.jpg';
---
<!-- Optimized: auto format conversion, resize, lazy loading -->
<Image src={heroImage} width={800} height={400} alt="Hero image" />

<!-- Remote images (must specify dimensions) -->
<Image
  src="https://example.com/photo.jpg"
  width={600}
  height={400}
  alt="Remote photo"
/>
```

For responsive images (Astro 5.10+), add `widths` and `sizes` props. Configure allowed remote domains in `astro.config.mjs` under `image.domains`.

## Middleware

Create `src/middleware.ts`. Export `onRequest`:

```ts
// src/middleware.ts
import { defineMiddleware } from 'astro:middleware';

export const onRequest = defineMiddleware(async (context, next) => {
  // Before route handler
  const token = context.cookies.get('session')?.value;
  if (context.url.pathname.startsWith('/dashboard') && !token) {
    return context.redirect('/login');
  }

  context.locals.user = token ? await validateToken(token) : null;

  const response = await next();
  // After route handler
  response.headers.set('X-Custom-Header', 'value');
  return response;
});
```

Access locals in pages: `const { user } = Astro.locals;`

Chain middleware with `sequence`:

```ts
import { sequence } from 'astro:middleware';
export const onRequest = sequence(authMiddleware, loggingMiddleware);
```

## Server Endpoints (API Routes)

Place in `src/pages/api/`. Export named HTTP method handlers:

```ts
// src/pages/api/posts.ts
import type { APIRoute } from 'astro';

export const GET: APIRoute = async ({ request, url }) => {
  const limit = Number(url.searchParams.get('limit')) || 10;
  const posts = await db.getPosts(limit);
  return new Response(JSON.stringify(posts), {
    status: 200,
    headers: { 'Content-Type': 'application/json' },
  });
};

export const POST: APIRoute = async ({ request }) => {
  const body = await request.json();
  const post = await db.createPost(body);
  return new Response(JSON.stringify(post), { status: 201 });
};
```

Dynamic API routes:

```ts
// src/pages/api/posts/[id].ts
export const GET: APIRoute = ({ params }) => {
  const { id } = params;
  return new Response(JSON.stringify({ id }));
};
```

For static output, export `getStaticPaths`. For SSR, set `output: 'server'` or `export const prerender = false`.

## Deployment

- **Static** (`output: 'static'`): `astro build` → deploy `dist/` to any static host (GitHub Pages, S3, Netlify, Vercel).
- **SSR** (`output: 'server'`): Requires adapter. Vercel: `vercel deploy`. Netlify: push to Git. Node: `node dist/server/entry.mjs`. Cloudflare: `wrangler pages deploy dist/`.
- **Docker** (Node adapter): Build image with `@astrojs/node` in standalone mode.

## Common Pitfalls

1. **Adding client directives to .astro components.** Only framework components (React, Vue, Svelte, Solid) accept client directives. `.astro` components are always server-rendered.
2. **Forgetting `getStaticPaths` for dynamic routes in static mode.** Static builds require all paths known at build time. Export `getStaticPaths` from dynamic route pages.
3. **Using browser APIs in frontmatter.** Frontmatter runs on the server. `window`, `document`, `localStorage` are unavailable. Use these only inside `client:only` components.
4. **Importing images as strings.** Use `import img from './img.png'` (returns metadata object), not string paths. Pass the import to `<Image src={img} />`.
5. **Missing adapter for SSR.** `output: 'server'` or `'hybrid'` requires an adapter. Build fails without one.
6. **Mutating content collection data.** Collection entries are read-only. Transform data in frontmatter or components, not in the collection config.
7. **Not setting dimensions for remote images.** `<Image>` requires explicit `width`/`height` for remote URLs since Astro cannot introspect them at build time.
8. **Using `Astro.glob` in Astro 5.** Prefer `getCollection` with the Content Layer API. `Astro.glob` is legacy and lacks type safety.
9. **SSR endpoints returning plain objects.** Always return a `Response` object from API routes, not raw JS objects.
10. **View transitions breaking client state.** Add `transition:persist` to interactive islands that must retain state across navigations.

## Supplemental Resources

**`references/`** — `advanced-patterns.md` (content collections, view transitions, middleware, REST APIs, cross-framework state, i18n, Astro DB, Actions, Server Islands), `troubleshooting.md` (hydration, client directives, SSR adapters, images, CSS, schemas, deployment), `deployment-guide.md` (static/SSR/hybrid/Docker/edge/CI-CD).

**`scripts/`** — `create-astro-project.sh` (scaffold with integrations), `content-collection-scaffold.sh` (collection boilerplate), `lighthouse-audit.sh` (audit with thresholds). All executable, use `--help`.

**`assets/`** — `astro.config.mjs` (production config template), `blog-layout.astro` (SEO meta, view transitions, dark mode), `content-config.ts` (multi-collection with references), `docker-compose.yml` (SSR with Postgres/Nginx/Redis).

<!-- tested: pass -->
