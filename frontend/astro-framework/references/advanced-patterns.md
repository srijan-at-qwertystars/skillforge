# Advanced Astro Patterns

## Table of Contents

- [Content Layer API](#content-layer-api)
  - [Custom Loaders](#custom-loaders)
  - [Remote Content Sources](#remote-content-sources)
  - [Combining Loaders](#combining-loaders)
- [Server Islands](#server-islands)
  - [Architecture Overview](#architecture-overview)
  - [Deferred Rendering](#deferred-rendering)
  - [Caching Strategies](#caching-strategies)
- [Advanced View Transitions](#advanced-view-transitions)
  - [Persistent Elements](#persistent-elements)
  - [Animation Customization](#animation-customization)
  - [Lifecycle Events](#lifecycle-events)
  - [Scroll and State Handling](#scroll-and-state-handling)
- [Dynamic OG Image Generation](#dynamic-og-image-generation)
- [Complex Routing Patterns](#complex-routing-patterns)
  - [i18n with Content Collections](#i18n-with-content-collections)
  - [Redirects and Rewrites](#redirects-and-rewrites)
  - [Route Priority and Ordering](#route-priority-and-ordering)
- [Middleware Chaining](#middleware-chaining)
  - [Composing Middleware](#composing-middleware)
  - [Context and Locals Typing](#context-and-locals-typing)
  - [Error Handling Middleware](#error-handling-middleware)
- [Astro Actions Deep Dive](#astro-actions-deep-dive)
  - [Form Actions](#form-actions)
  - [Progressive Enhancement](#progressive-enhancement)
  - [Error Handling](#error-handling)
  - [Nested and Grouped Actions](#nested-and-grouped-actions)
- [Custom Integrations Development](#custom-integrations-development)
  - [Integration API Hooks](#integration-api-hooks)
  - [Injecting Routes and Components](#injecting-routes-and-components)
  - [Virtual Modules](#virtual-modules)
- [Astro + HTMX Patterns](#astro--htmx-patterns)
- [RSS and Sitemap Generation](#rss-and-sitemap-generation)
- [Asset Handling Pipeline](#asset-handling-pipeline)

---

## Content Layer API

### Custom Loaders

Astro 5's Content Layer API allows defining custom loaders that fetch content from any source. A loader is an object or function that returns entries to populate a collection.

```ts
// content.config.ts
import { defineCollection, z } from 'astro:content';

// Simple function loader — returns an array of entries
const announcements = defineCollection({
  loader: async () => {
    const res = await fetch('https://api.example.com/announcements');
    const data = await res.json();
    return data.map((item: any) => ({
      id: item.slug,
      title: item.title,
      body: item.content,
      pubDate: item.published_at,
    }));
  },
  schema: z.object({
    title: z.string(),
    body: z.string(),
    pubDate: z.coerce.date(),
  }),
});
```

For full control, implement the object loader API with `load()`:

```ts
// src/loaders/notion-loader.ts
import type { Loader, LoaderContext } from 'astro/loaders';

export function notionLoader(databaseId: string): Loader {
  return {
    name: 'notion-loader',
    load: async (context: LoaderContext) => {
      const { store, meta, logger, parseData, generateDigest } = context;

      // Check if we need to refresh — use meta for incremental builds
      const lastSynced = meta.get('lastSynced');
      logger.info(`Fetching Notion database ${databaseId}`);

      const response = await fetchNotionDatabase(databaseId, lastSynced);

      for (const page of response.results) {
        const digest = generateDigest(page);

        // Skip unchanged entries for incremental builds
        if (store.get(page.id)?.digest === digest) continue;

        const data = await parseData({
          id: page.id,
          data: {
            title: page.properties.Name.title[0].plain_text,
            status: page.properties.Status.select.name,
            lastEdited: page.last_edited_time,
          },
        });

        store.set({ id: page.id, data, digest, rendered: { html: page.html } });
      }

      // Track sync time for incremental builds
      meta.set('lastSynced', new Date().toISOString());
    },
    // Optional: define the schema within the loader itself
    schema: z.object({
      title: z.string(),
      status: z.enum(['Draft', 'Published', 'Archived']),
      lastEdited: z.coerce.date(),
    }),
  };
}
```

### Remote Content Sources

Use the built-in loaders for common patterns or create custom ones for APIs:

```ts
// content.config.ts
import { defineCollection, z } from 'astro:content';
import { glob, file } from 'astro/loaders';

// Built-in glob loader for local files
const blog = defineCollection({
  loader: glob({ pattern: '**/*.{md,mdx}', base: './src/content/blog' }),
  schema: z.object({ title: z.string(), date: z.coerce.date() }),
});

// Built-in file loader for JSON/YAML data files
const authors = defineCollection({
  loader: file('src/data/authors.json'),
  schema: z.object({
    name: z.string(),
    avatar: z.string().url(),
    bio: z.string(),
  }),
});

// Custom loader for a headless CMS
const cmsPages = defineCollection({
  loader: async () => {
    const res = await fetch('https://cms.example.com/api/pages', {
      headers: { Authorization: `Bearer ${import.meta.env.CMS_TOKEN}` },
    });
    const pages = await res.json();
    return pages.map((p: any) => ({
      id: p.slug,
      ...p.fields,
    }));
  },
  schema: z.object({
    title: z.string(),
    content: z.string(),
    seo: z.object({
      metaTitle: z.string(),
      metaDescription: z.string(),
    }).optional(),
  }),
});

export const collections = { blog, authors, cmsPages };
```

### Combining Loaders

Create composite loaders that merge content from multiple sources by iterating over an array of loaders and calling each `load()` in sequence within a single loader's `load()` method.

---

## Server Islands

### Architecture Overview

Server Islands let you combine cached static HTML with dynamic server-rendered components. The static shell is served instantly from CDN, then dynamic "islands" are fetched from the server and streamed in.

```astro
---
// src/pages/product/[id].astro
// The page is prerendered at build time (static shell)
export const prerender = true;
import ProductDetails from '../components/ProductDetails.astro';
import PriceWidget from '../components/PriceWidget.astro';
import UserReviews from '../components/UserReviews.astro';
---
<html>
<body>
  <!-- Static content rendered at build time -->
  <ProductDetails productId={Astro.params.id} />

  <!-- Dynamic component fetched from server at request time -->
  <PriceWidget server:defer productId={Astro.params.id}>
    <div slot="fallback" class="skeleton">Loading price...</div>
  </PriceWidget>

  <UserReviews server:defer productId={Astro.params.id}>
    <div slot="fallback">Loading reviews...</div>
  </UserReviews>
</body>
</html>
```

### Deferred Rendering

Server Islands use `server:defer` to mark components for deferred server-side rendering. The fallback slot content is included in the initial HTML and replaced when the server response arrives.

```astro
---
// src/components/CartSummary.astro
// This component runs on the server at request time, even on prerendered pages
const session = Astro.cookies.get('session')?.value;
const cart = session ? await getCart(session) : null;
---
{cart ? (
  <div class="cart-badge">
    <span>{cart.itemCount} items</span>
    <span>${cart.total.toFixed(2)}</span>
  </div>
) : (
  <a href="/login">Sign in</a>
)}
```

### Caching Strategies

Server Islands are fetched via internal `/_server-islands/` endpoints. Add cache headers in middleware for these paths using `Cache-Control: s-maxage=60, stale-while-revalidate=300` to enable CDN caching of dynamic island responses.

---

## Advanced View Transitions

### Persistent Elements

Use `transition:persist` to keep interactive elements alive across page navigations. The DOM element and its state are preserved:

```astro
<!-- Audio player that persists across pages -->
<audio id="player" transition:persist controls>
  <source src="/music/ambient.mp3" type="audio/mp3" />
</audio>

<!-- Island component that keeps its state -->
<VideoPlayer client:load transition:persist id="main-video" />

<!-- Persist a specific island by directive -->
<Counter client:load transition:persist="site-counter" />
```

Use `data-astro-transition-persist` in framework components:

```jsx
// React component
export function MusicPlayer() {
  return <div data-astro-transition-persist="music-player">...</div>;
}
```

### Animation Customization

Define custom animations using the `transition:animate` directive with custom animation objects:

```astro
---
import { fade, slide } from 'astro:transitions';
---
<!-- Built-in animations with duration override -->
<h1 transition:animate={fade({ duration: '0.5s' })}>Title</h1>
<aside transition:animate={slide({ duration: '300ms' })}>Sidebar</aside>

<!-- Fully custom animation -->
<div transition:animate={{
  old: {
    name: 'scaleOut',
    duration: '0.3s',
    easing: 'ease-in',
    fillMode: 'forwards',
  },
  new: {
    name: 'scaleIn',
    duration: '0.3s',
    easing: 'ease-out',
    fillMode: 'backwards',
    delay: '0.15s',
  },
}}>
  Content
</div>

<style>
  @keyframes scaleOut {
    from { opacity: 1; transform: scale(1); }
    to { opacity: 0; transform: scale(0.9); }
  }
  @keyframes scaleIn {
    from { opacity: 0; transform: scale(1.1); }
    to { opacity: 1; transform: scale(1); }
  }
</style>
```

### Lifecycle Events

Listen to View Transition lifecycle events for custom behaviors:

```astro
<script>
  // Fires before the new page DOM is swapped in
  document.addEventListener('astro:before-preparation', (ev) => {
    // Access the direction, from/to URLs
    console.log(`Navigating from ${ev.from} to ${ev.to}`);
    // Modify the new document before swap
    ev.newDocument.title = ev.newDocument.title + ' | MySite';
  });

  // Fires right before the DOM swap
  document.addEventListener('astro:before-swap', (ev) => {
    // Preserve specific DOM state
    const theme = document.documentElement.dataset.theme;
    ev.newDocument.documentElement.dataset.theme = theme;

    // Custom swap implementation
    ev.swap = () => {
      // Implement custom swap logic
      document.body.innerHTML = ev.newDocument.body.innerHTML;
    };
  });

  // Fires after the new page is fully loaded
  document.addEventListener('astro:after-swap', () => {
    // Re-initialize third-party scripts
    initAnalytics();
  });

  // Fires when the page transition is complete (including animations)
  document.addEventListener('astro:page-load', () => {
    // Runs on every navigation AND initial page load
    setupEventListeners();
  });
</script>
```

### Scroll and State Handling

Use `data-astro-history="replace"` on links to prevent scroll reset (useful for tabs). Use `data-astro-reload` on forms to force a full page reload instead of a View Transition.

---

## Dynamic OG Image Generation

Generate Open Graph images dynamically using `@astrojs/og` or Satori:

```ts
// src/pages/og/[slug].png.ts
import type { APIRoute, GetStaticPaths } from 'astro';
import { getCollection } from 'astro:content';
import { html } from 'satori-html';
import satori from 'satori';
import sharp from 'sharp';

export const getStaticPaths: GetStaticPaths = async () => {
  const posts = await getCollection('blog');
  return posts.map((post) => ({
    params: { slug: post.id },
    props: { title: post.data.title, date: post.data.date },
  }));
};

export const GET: APIRoute = async ({ props }) => {
  const { title, date } = props;

  const markup = html`
    <div style="display: flex; flex-direction: column; width: 1200px; height: 630px;
                background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
                padding: 60px; color: white; font-family: 'Inter';">
      <div style="font-size: 64px; font-weight: bold; line-height: 1.2;">${title}</div>
      <div style="font-size: 28px; margin-top: auto; opacity: 0.8;">
        ${date.toLocaleDateString('en-US', { year: 'numeric', month: 'long', day: 'numeric' })}
      </div>
      <div style="font-size: 24px; opacity: 0.6;">mysite.com</div>
    </div>
  `;

  const svg = await satori(markup, {
    width: 1200,
    height: 630,
    fonts: [{ name: 'Inter', data: await loadFont(), weight: 400, style: 'normal' }],
  });

  const png = await sharp(Buffer.from(svg)).png().toBuffer();

  return new Response(png, {
    headers: { 'Content-Type': 'image/png', 'Cache-Control': 'public, max-age=31536000' },
  });
};
```

Reference in your layout with `<meta property="og:image" content={...} />` using the generated route.

---

## Complex Routing Patterns

### i18n with Content Collections

Structure localized content using content collections and dynamic routing:

```ts
// content.config.ts
const docs = defineCollection({
  loader: glob({ pattern: '**/*.mdx', base: './src/content/docs' }),
  schema: z.object({
    title: z.string(),
    locale: z.enum(['en', 'es', 'fr', 'de']),
    translationKey: z.string(), // Links translations together
  }),
});
```

```astro
---
// src/pages/[locale]/docs/[...slug].astro
import { getCollection } from 'astro:content';

export async function getStaticPaths() {
  const docs = await getCollection('docs');
  return docs.map((doc) => ({
    params: { locale: doc.data.locale, slug: doc.id.replace(`${doc.data.locale}/`, '') },
    props: { doc },
  }));
}

const { doc } = Astro.props;
const allDocs = await getCollection('docs');
const translations = allDocs.filter(
  (d) => d.data.translationKey === doc.data.translationKey && d.id !== doc.id
);
---
<nav>
  {translations.map((t) => (
    <a href={`/${t.data.locale}/docs/${t.id}`}>{t.data.locale.toUpperCase()}</a>
  ))}
</nav>
```

### Redirects and Rewrites

Configure redirects in `astro.config.mjs` under `redirects`: simple (`'/old': '/new'`), dynamic (`'/blog/[...slug]': '/articles/[...slug]'`), or with status codes (`{ status: 301, destination: '/new' }`). In SSR, use `Astro.rewrite('/path')` for internal routing without URL change.

### Route Priority and Ordering

Astro resolves routes: static (`/about.astro`) → named dynamic (`/blog/[slug].astro`) → catch-all (`/[...path].astro`). Use `paginate()` from `getStaticPaths` for paginated routes — it provides `page.data`, `page.url.prev`, `page.url.next`, `page.currentPage`, and `page.lastPage`.

---

## Middleware Chaining

### Composing Middleware

Use `sequence()` to chain multiple middleware functions. They execute in order, each calling `next()` to proceed:

```ts
// src/middleware.ts
import { defineMiddleware, sequence } from 'astro:middleware';

const rateLimit = defineMiddleware(async ({ clientAddress, url }, next) => {
  const key = `${clientAddress}:${url.pathname}`;
  if (await isRateLimited(key)) {
    return new Response('Too Many Requests', { status: 429 });
  }
  return next();
});

const cors = defineMiddleware(async ({ request }, next) => {
  if (request.method === 'OPTIONS') {
    return new Response(null, {
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE',
        'Access-Control-Allow-Headers': 'Content-Type, Authorization',
      },
    });
  }
  const response = await next();
  response.headers.set('Access-Control-Allow-Origin', '*');
  return response;
});

const timing = defineMiddleware(async (context, next) => {
  const start = performance.now();
  const response = await next();
  const duration = performance.now() - start;
  response.headers.set('Server-Timing', `total;dur=${duration.toFixed(2)}`);
  return response;
});

export const onRequest = sequence(rateLimit, cors, timing);
```

### Context and Locals Typing

Type `context.locals` for full type safety across middleware and pages:

```ts
// src/env.d.ts
declare namespace App {
  interface Locals {
    user: { id: string; name: string; role: 'admin' | 'user' } | null;
    requestId: string;
    startTime: number;
  }
}
```

### Error Handling Middleware

Wrap `next()` in try-catch for global error handling. Return appropriate HTTP responses for different error types (e.g., `ValidationError` → 400, unknown → 500). Log errors with `context.locals.requestId` for traceability.

---

## Astro Actions Deep Dive

### Form Actions

Use `accept: 'form'` to handle native HTML form submissions:

```ts
// src/actions/index.ts
import { defineAction, ActionError } from 'astro:actions';
import { z } from 'astro:schema';

export const server = {
  contact: defineAction({
    accept: 'form',
    input: z.object({
      name: z.string().min(2),
      email: z.string().email(),
      message: z.string().min(10).max(1000),
      honeypot: z.string().max(0).optional(), // Spam protection
    }),
    handler: async (input) => {
      if (input.honeypot) throw new ActionError({ code: 'FORBIDDEN' });
      await sendEmail(input);
      return { sent: true };
    },
  }),
};
```

### Progressive Enhancement

Actions work without JavaScript when using form actions:

```astro
---
// src/pages/contact.astro
import { actions } from 'astro:actions';

const result = Astro.getActionResult(actions.contact);
const inputValues = result?.error?.fields ?? {};
---
<form method="POST" action={actions.contact}>
  <input name="name" value={inputValues.name ?? ''} required />
  <input type="email" name="email" value={inputValues.email ?? ''} required />
  <textarea name="message" required>{inputValues.message ?? ''}</textarea>
  <input type="hidden" name="honeypot" value="" />
  <button type="submit">Send</button>
</form>

{result?.data?.sent && <p class="success">Message sent!</p>}
{result?.error && <p class="error">{result.error.message}</p>}
```

### Error Handling

Use `ActionError` for structured error responses:

```ts
import { ActionError } from 'astro:actions';

handler: async (input, context) => {
  const user = context.locals.user;
  if (!user) {
    throw new ActionError({
      code: 'UNAUTHORIZED',
      message: 'You must be logged in',
    });
  }
  if (user.role !== 'admin') {
    throw new ActionError({
      code: 'FORBIDDEN',
      message: 'Admin access required',
    });
  }
  // ActionError codes: BAD_REQUEST, UNAUTHORIZED, FORBIDDEN, NOT_FOUND,
  // TIMEOUT, CONFLICT, PRECONDITION_FAILED, PAYLOAD_TOO_LARGE,
  // UNSUPPORTED_MEDIA_TYPE, UNPROCESSABLE_CONTENT, TOO_MANY_REQUESTS,
  // CLIENT_CLOSED_REQUEST, INTERNAL_SERVER_ERROR
}
```

### Nested and Grouped Actions

Organize actions into namespaced groups by nesting objects: `server.user.login`, `server.posts.create`. Call as `actions.user.login({ ... })`.

---

## Custom Integrations Development

### Integration API Hooks

Build custom integrations using the Astro Integration API:

```ts
// my-integration/index.ts
import type { AstroIntegration } from 'astro';

export default function myIntegration(options: { apiKey: string }): AstroIntegration {
  return {
    name: 'my-integration',
    hooks: {
      'astro:config:setup': ({ updateConfig, addMiddleware, injectRoute, injectScript }) => {
        // Modify Astro config
        updateConfig({
          vite: { define: { __API_KEY__: JSON.stringify(options.apiKey) } },
        });

        // Add middleware
        addMiddleware({
          entrypoint: 'my-integration/middleware',
          order: 'pre', // 'pre' | 'post'
        });

        // Inject a route
        injectRoute({
          pattern: '/api/my-endpoint',
          entrypoint: 'my-integration/api-route.ts',
          prerender: false,
        });

        // Inject client-side script
        injectScript('page', `console.log('Integration loaded');`);
      },

      'astro:config:done': ({ config, setAdapter }) => {
        // Access final resolved config
      },

      'astro:build:start': () => {
        // Runs at the start of the build
      },

      'astro:build:done': ({ pages, routes, dir }) => {
        // Post-build processing
        console.log(`Built ${pages.length} pages to ${dir}`);
      },
    },
  };
}
```

### Injecting Routes and Components

Use `injectRoute({ pattern, entrypoint })` to add pages from the integration, and `addClientDirective({ name, entrypoint })` to create custom client directives (e.g., `client:hover`). Both are called within the `astro:config:setup` hook.

### Virtual Modules

Provide data to user code via Vite virtual modules. In the `astro:config:setup` hook, add a Vite plugin that resolves a virtual module ID (e.g., `virtual:my-data`) and returns generated code. Users import as `import { config } from 'virtual:my-data';`.

---

## Astro + HTMX Patterns

Use HTMX with Astro for server-rendered interactivity without client-side frameworks:

```astro
---
// src/pages/index.astro
---
<html>
<head>
  <script src="https://unpkg.com/htmx.org@2"></script>
</head>
<body>
  <!-- Inline editing -->
  <div id="profile" hx-get="/api/profile" hx-trigger="load" hx-swap="innerHTML">
    Loading profile...
  </div>

  <!-- Search with debounce -->
  <input type="search" name="q"
    hx-get="/api/search"
    hx-trigger="keyup changed delay:300ms"
    hx-target="#results"
    hx-indicator="#spinner"
    placeholder="Search..." />
  <span id="spinner" class="htmx-indicator">Searching...</span>
  <div id="results"></div>

  <!-- Infinite scroll -->
  <div id="feed" hx-get="/api/posts?page=1" hx-trigger="load" hx-swap="innerHTML">
    Loading...
  </div>
</body>
</html>
```

Pair with Astro API routes that return HTML fragments (not JSON) via `new Response(html, { headers: { 'Content-Type': 'text/html' } })`. This enables server-rendered interactivity without shipping a client-side framework.

---

## RSS and Sitemap Generation

### RSS Feed

```ts
// src/pages/rss.xml.ts
import rss from '@astrojs/rss';
import { getCollection } from 'astro:content';
import sanitizeHtml from 'sanitize-html';
import MarkdownIt from 'markdown-it';

const parser = new MarkdownIt();

export async function GET(context: { site: URL }) {
  const posts = await getCollection('blog', ({ data }) => !data.draft);

  return rss({
    title: 'My Blog',
    description: 'A blog about web development',
    site: context.site,
    items: posts
      .sort((a, b) => b.data.date.valueOf() - a.data.date.valueOf())
      .map((post) => ({
        title: post.data.title,
        pubDate: post.data.date,
        description: post.data.description,
        categories: post.data.tags,
        link: `/blog/${post.id}/`,
        content: sanitizeHtml(parser.render(post.body ?? ''), {
          allowedTags: sanitizeHtml.defaults.allowedTags.concat(['img']),
        }),
      })),
    customData: `<language>en-us</language>`,
    stylesheet: '/rss/styles.xsl',
  });
}
```

### Sitemap

Add `@astrojs/sitemap` to integrations. Configure with `filter` to exclude pages, `changefreq`, `priority`, `lastmod`, and `i18n` locale mapping. Use `customPages` to include external URLs. Requires the `site` config to be set.

---

## Asset Handling Pipeline

### Image Processing

Astro processes images in `src/assets/` at build time. Configure the image service:

```js
// astro.config.mjs
export default defineConfig({
  image: {
    service: { entrypoint: 'astro/assets/services/sharp' },
    domains: ['images.unsplash.com', 'cdn.example.com'],
    remotePatterns: [{ protocol: 'https', hostname: '**.amazonaws.com' }],
  },
});
```

Use `getImage()` for programmatic image processing — pass `{ src, width, format }` and use the returned `src` and `attributes` in `<picture>` elements for responsive images with format negotiation.

### CSS and Font Handling

Astro processes CSS through Vite. Configure PostCSS via `postcss.config.cjs` with `autoprefixer` and `cssnano`. For fonts, use `<link rel="preload">` with `as="font"` and `crossorigin`, and define `@font-face` with `font-display: swap` for optimal loading.

### Public vs Src Assets

- **`public/`** — Served as-is, no processing. Use for favicons, `robots.txt`, files needing stable URLs.
- **`src/assets/`** — Processed by Vite. Images optimized, CSS bundled, hashed filenames for cache-busting. Import from `src/assets/` for processing; reference `public/` files with absolute paths.
