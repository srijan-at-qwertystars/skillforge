---
name: astro-framework
description: >
  Use when building content-driven websites with Astro, using Astro islands architecture,
  creating static sites with partial hydration, integrating React/Vue/Svelte components in Astro,
  configuring Astro SSR/SSG, working with Astro content collections, Astro View Transitions,
  Astro Actions, Astro DB, or Astro middleware and server endpoints.
  Do NOT use for React-only SPAs (use Next.js/Remix), Vue-only apps (use Nuxt),
  Svelte-only apps (use SvelteKit), or general static site generators like Hugo/Jekyll without Astro.
---

# Astro Framework

## Project Setup and Structure

Create a new project with `npm create astro@latest`. Key directories:

- `astro.config.mjs` — framework config. `content.config.ts` — content collections (Astro 5+). `db/config.ts` — Astro DB schema.
- `src/pages/` — file-based routing. `src/components/` — reusable components. `src/layouts/` — page templates. `src/content/` — collection source files. `src/assets/` — optimizable images. `src/actions/` — server functions. `src/middleware.ts` — request middleware. `public/` — static assets served as-is.

```js
// astro.config.mjs
import { defineConfig } from 'astro/config';
import react from '@astrojs/react';
export default defineConfig({
  site: 'https://example.com',
  integrations: [react()],
  output: 'static', // 'static' | 'server'
});
```

## Astro Components (.astro Files)

Every `.astro` file has a frontmatter script fence (`---`) and an HTML template:

```astro
---
import Layout from '../layouts/Base.astro';
interface Props { title: string; items?: string[]; }
const { title, items = [] } = Astro.props;
const response = await fetch('https://api.example.com/data');
const data = await response.json();
---
<Layout title={title}>
  <h1>{title}</h1>
  <ul>{items.map((item) => <li>{item}</li>)}</ul>
  {data && <pre>{JSON.stringify(data, null, 2)}</pre>}
</Layout>
```

Named slots for multi-slot composition:

```astro
<!-- Definition -->              <!-- Usage -->
<header>                         <Component>
  <slot name="header" />           <h1 slot="header">Title</h1>
</header>                         <p>Default slot content</p>
<main><slot /></main>            </Component>
```

Template expressions: `{expr}`. Conditionals: `{show && <p>Visible</p>}`. Raw HTML: `set:html={rawHtml}`. Conditional classes: `class:list={['base', { active: isActive }]}`. Grouping: `<Fragment>` or `<>`.

## Pages and Routing

Files in `src/pages/` become routes automatically. Supported extensions: `.astro`, `.md`, `.mdx`, `.ts`, `.js`.

- `src/pages/index.astro` → `/` | `src/pages/about.astro` → `/about`
- `src/pages/blog/[slug].astro` → `/blog/:slug` (dynamic) | `src/pages/[...path].astro` → catch-all/404

Dynamic routes require `getStaticPaths` in static mode:

```astro
---
// src/pages/blog/[slug].astro
import { getCollection, render } from 'astro:content';
export async function getStaticPaths() {
  const posts = await getCollection('blog');
  return posts.map((post) => ({ params: { slug: post.id }, props: { post } }));
}
const { post } = Astro.props;
const { Content } = await render(post);
---
<Content />
```

Create a custom 404 page at `src/pages/404.astro`.

## Layouts

Define layouts as `.astro` components wrapping page content:

```astro
---
// src/layouts/Base.astro
interface Props { title: string; description?: string; }
const { title, description = 'My Astro site' } = Astro.props;
---
<html lang="en">
<head>
  <meta charset="utf-8" /><meta name="viewport" content="width=device-width" />
  <meta name="description" content={description} /><title>{title}</title>
</head>
<body><nav><!-- nav --></nav><main><slot /></main></body>
</html>
```

Nest layouts by wrapping one inside another. Assign layouts to Markdown via frontmatter: `layout: ../../layouts/Post.astro`. The layout receives frontmatter via `Astro.props.frontmatter` and rendered content via `<slot />`.

## Content Collections (Astro 5+)

Define collections in `content.config.ts` at project root using loaders:

```ts
// content.config.ts
import { defineCollection, z } from 'astro:content';
import { glob } from 'astro/loaders';

const blog = defineCollection({
  loader: glob({ pattern: '**/*.{md,mdx}', base: './src/content/blog' }),
  schema: z.object({
    title: z.string(),
    date: z.coerce.date(),
    draft: z.boolean().default(false),
    tags: z.array(z.string()).default([]),
    image: z.string().optional(),
  }),
});

export const collections = { blog };
```

Query collections with full type safety:

```astro
---
import { getCollection, getEntry, render } from 'astro:content';
const posts = (await getCollection('blog', ({ data }) => !data.draft))
  .sort((a, b) => b.data.date.valueOf() - a.data.date.valueOf());
const featured = await getEntry('blog', 'featured-post');
const { Content, headings } = await render(featured);
---
```

In Astro 5, use `post.id` (not `post.slug`). Use `render(post)` (not `post.render()`).

## Islands Architecture

Astro ships zero JavaScript by default. Add interactivity with client directives on framework components:

```astro
---
import Counter from '../components/Counter.jsx';
import Newsletter from '../components/Newsletter.svelte';
import Carousel from '../components/Carousel.vue';
---
<Counter client:load />          <!-- Hydrate immediately on page load -->
<Newsletter client:idle />       <!-- Hydrate when browser is idle -->
<Carousel client:visible />      <!-- Hydrate when scrolled into view -->
<Counter client:media="(min-width: 768px)" />  <!-- At media query match -->
<Counter client:only="react" />  <!-- Client-only, skip SSR (specify framework) -->
```

Without a `client:*` directive, framework components render to static HTML with no JS shipped. Server Islands (Astro 5) mix cached static content with dynamic server-rendered components:

```astro
<UserGreeting server:defer>
  <p slot="fallback">Loading...</p>
</UserGreeting>
```

## Framework Integrations

Install via `npx astro add react` (or vue, svelte, solid, preact, lit). Mix components from different frameworks on the same page. Each needs a `client:*` directive for interactivity. Use `include`/`exclude` patterns when multiple JSX frameworks coexist:

```js
import react from '@astrojs/react';
import svelte from '@astrojs/svelte';
export default defineConfig({
  integrations: [react({ include: ['**/react/*'] }), svelte()],
});
```

## Styling

Scoped styles in `.astro` files apply only to that component by default:

```astro
<style>
  h1 { color: navy; }
</style>
<style is:global>
  :root { --accent: #7c3aed; }
</style>
```

Tailwind CSS: `npx astro add tailwind`. Sass: `npm install sass` (no plugin needed). CSS Modules: import `.module.css` files. Pass class names via `class` prop; use `class:list={['base', { active: isActive }]}` for conditionals.

## Data Fetching

Fetch data in frontmatter (runs at build/request time):

```astro
---
const res = await fetch('https://api.example.com/posts');
const posts = await res.json();
const allPosts = await Astro.glob('./blog/*.md'); // local files
import { getCollection } from 'astro:content';
const blogPosts = await getCollection('blog');    // content collections (preferred)
---
```

API routes as server endpoints in `src/pages/api/`:

```ts
// src/pages/api/search.ts
import type { APIRoute } from 'astro';
export const GET: APIRoute = async ({ url }) => {
  const query = url.searchParams.get('q') || '';
  const results = await searchDatabase(query);
  return new Response(JSON.stringify(results), {
    headers: { 'Content-Type': 'application/json' },
  });
};
export const POST: APIRoute = async ({ request }) => {
  const body = await request.json();
  return new Response(JSON.stringify({ ok: true }), { status: 201 });
};
```

Export HTTP method handlers (`GET`, `POST`, `PUT`, `DELETE`, `PATCH`). Static builds only support `GET`. Use `output: 'server'` for dynamic endpoints.

## SSR and Adapters

Enable SSR with `output: 'server'` and an adapter:

```js
import node from '@astrojs/node';
export default defineConfig({
  output: 'server',
  adapter: node({ mode: 'standalone' }),
});
```

Adapters: `@astrojs/node`, `@astrojs/deno`, `@astrojs/cloudflare`, `@astrojs/vercel`, `@astrojs/netlify`. Install via `npx astro add netlify` (etc.). Opt individual pages into prerendering with `export const prerender = true` in frontmatter. In Astro 5, only `static` and `server` output modes exist (hybrid removed).

## View Transitions

Enable smooth animated page transitions by adding `<ViewTransitions />` to your layout `<head>`:

```astro
---
import { ViewTransitions } from 'astro:transitions';
---
<html><head><ViewTransitions /></head><body><slot /></body></html>
```

Customize per element: `<h1 transition:name="title" transition:animate="slide">Title</h1>`. Built-in animations: `fade`, `slide`, `none`, `initial`. Persist interactive elements across pages with `transition:persist`.

## Image Optimization

Use built-in `<Image>` and `<Picture>` components:

```astro
---
import { Image, Picture } from 'astro:assets';
import heroImage from '../assets/hero.jpg';
---
<Image src={heroImage} alt="Hero" width={800} />
<Picture src={heroImage} formats={['avif', 'webp']} alt="Hero" />
<Image src="https://example.com/photo.jpg" alt="Remote" width={600} height={400} />
```

Store optimizable images in `src/assets/` (not `public/`). Configure remote domains:

```js
export default defineConfig({
  image: { domains: ['example.com'], remotePatterns: [{ protocol: 'https' }] },
});
```

## Middleware

Define middleware in `src/middleware.ts`:

```ts
import { defineMiddleware, sequence } from 'astro:middleware';
const auth = defineMiddleware(async (context, next) => {
  const token = context.request.headers.get('authorization');
  if (context.url.pathname.startsWith('/admin') && !token) {
    return context.redirect('/login', 302);
  }
  context.locals.user = await validateToken(token);
  return next();
});
const logging = defineMiddleware(async (context, next) => {
  console.log(`${context.request.method} ${context.url.pathname}`);
  return next();
});
export const onRequest = sequence(auth, logging);
```

Access `context.locals` in pages via `Astro.locals`. Chain with `sequence()`. Runs on every request in SSR; at build time in static mode.

## Astro DB

Add with `npx astro add db`. Define tables in `db/config.ts`:

```ts
import { defineDb, defineTable, column, NOW } from 'astro:db';
const Comment = defineTable({
  columns: {
    id: column.number({ primaryKey: true }),
    postSlug: column.text(),
    author: column.text(),
    body: column.text(),
    publishedAt: column.date({ default: NOW }),
  },
});
export default defineDb({ tables: { Comment } });
```

Column types: `text()`, `number()`, `boolean()`, `date()`, `json()`. Options: `primaryKey`, `optional`, `default`, `unique`, `references`. Query with built-in Drizzle ORM:

```ts
import { db, Comment, eq } from 'astro:db';
const comments = await db.select().from(Comment).where(eq(Comment.postSlug, 'my-post'));
await db.insert(Comment).values({ postSlug: 'my-post', author: 'Alice', body: 'Great!' });
```

Seed dev data in `db/seed.ts`. For production, set `ASTRO_DB_REMOTE_URL` and `ASTRO_DB_APP_TOKEN` env vars (libSQL/Turso). Build with `astro build --remote`.

## Actions (Type-Safe Server Functions)

Define actions in `src/actions/index.ts`:

```ts
import { defineAction } from 'astro:actions';
import { z } from 'astro:schema';
export const server = {
  subscribe: defineAction({
    accept: 'form',
    input: z.object({ email: z.string().email(), name: z.string().min(1) }),
    handler: async (input) => {
      await db.insert(Subscriber).values(input);
      return { success: true };
    },
  }),
  like: defineAction({
    input: z.object({ postId: z.string() }),
    handler: async ({ postId }) => ({ likes: await incrementLike(postId) }),
  }),
};
```

Call from client-side JavaScript:

```astro
<script>
  import { actions } from 'astro:actions';
  const { data, error } = await actions.like({ postId: 'abc123' });
</script>
```

Use `accept: 'form'` for HTML form submissions. Actions require `output: 'server'` or a server endpoint.

## Internationalization (i18n)

Configure i18n in `astro.config.mjs`:

```js
export default defineConfig({
  i18n: {
    locales: ['en', 'es', 'fr'],
    defaultLocale: 'en',
    prefixDefaultLocale: false,
    routing: { fallbackType: 'rewrite' },
  },
});
```

Organize pages by locale: `src/pages/es/about.astro` → `/es/about`. Use helpers for locale-aware URLs:

```astro
---
import { getRelativeLocaleUrl } from 'astro:i18n';
---
<a href={getRelativeLocaleUrl('es', '/about')}>Acerca de</a>
```

Access `Astro.currentLocale` for the active locale. Use `getAbsoluteLocaleUrl()` for full URLs.

## Deployment

**Static** (default): `astro build` generates `dist/` with static HTML/CSS/JS. Deploy to any static host.

**Server**: Requires an adapter. Configure per platform:

```js
import vercel from '@astrojs/vercel';
export default defineConfig({ output: 'server', adapter: vercel() });
```

Use `export const prerender = true` per page to prerender at build time in server mode. Set `site` for canonical URLs. Add `@astrojs/sitemap` for sitemap.xml. Test with `astro preview`.
