# Astro Advanced Patterns

## Table of Contents

- [Content Collections Advanced](#content-collections-advanced)
  - [References Between Collections](#references-between-collections)
  - [Computed Fields](#computed-fields)
  - [Custom Loaders](#custom-loaders)
- [View Transitions](#view-transitions)
  - [Persist Directives](#persist-directives)
  - [transition:name](#transitionname)
  - [transition:animate](#transitionanimate)
  - [Swap Functions](#swap-functions)
  - [Lifecycle Events](#lifecycle-events)
- [Middleware Chaining and Auth Patterns](#middleware-chaining-and-auth-patterns)
  - [Chaining with sequence()](#chaining-with-sequence)
  - [Auth Middleware Pattern](#auth-middleware-pattern)
  - [CORS Middleware](#cors-middleware)
  - [Rate Limiting Middleware](#rate-limiting-middleware)
- [Server Endpoints for REST APIs](#server-endpoints-for-rest-apis)
  - [Full CRUD Example](#full-crud-example)
  - [Error Handling Pattern](#error-handling-pattern)
  - [File Uploads](#file-uploads)
- [Integration Patterns (Islands with Shared State)](#integration-patterns-islands-with-shared-state)
  - [Nano Stores for Cross-Framework State](#nano-stores-for-cross-framework-state)
  - [React Island](#react-island)
  - [Vue Island](#vue-island)
  - [Svelte Island](#svelte-island)
  - [Solid Island](#solid-island)
- [Internationalization (i18n) Routing](#internationalization-i18n-routing)
  - [Built-in i18n Configuration](#built-in-i18n-configuration)
  - [Language Switcher Component](#language-switcher-component)
  - [Translated Content Collections](#translated-content-collections)
- [Astro DB (libSQL) Integration](#astro-db-libsql-integration)
  - [Defining Tables](#defining-tables)
  - [Seeding Data](#seeding-data)
  - [Querying with Drizzle ORM](#querying-with-drizzle-orm)
- [Actions (Type-Safe Form Handling)](#actions-type-safe-form-handling)
  - [Defining Actions](#defining-actions)
  - [Calling Actions from Forms](#calling-actions-from-forms)
  - [Calling Actions from Client Components](#calling-actions-from-client-components)
- [Server Islands](#server-islands)
  - [Configuring Server Islands](#configuring-server-islands)
  - [Fallback Content](#fallback-content)
  - [Caching Strategies](#caching-strategies)

---

## Content Collections Advanced

### References Between Collections

Link entries across collections using `reference()`:

```ts
// src/content.config.ts
import { defineCollection, reference } from 'astro:content';
import { glob } from 'astro/loaders';
import { z } from 'astro/zod';

const authors = defineCollection({
  loader: glob({ pattern: '**/*.json', base: './src/content/authors' }),
  schema: z.object({
    name: z.string(),
    bio: z.string(),
    avatar: z.string(),
  }),
});

const blog = defineCollection({
  loader: glob({ pattern: '**/*.{md,mdx}', base: './src/content/blog' }),
  schema: z.object({
    title: z.string(),
    author: reference('authors'),        // single reference
    relatedPosts: z.array(reference('blog')).default([]),  // array of references
    pubDate: z.coerce.date(),
  }),
});

export const collections = { authors, blog };
```

Resolve references when querying:

```astro
---
import { getEntry } from 'astro:content';

const post = await getEntry('blog', 'my-post');
const author = await getEntry(post.data.author);  // resolves the reference

const relatedPosts = await Promise.all(
  post.data.relatedPosts.map(ref => getEntry(ref))
);
---
<p>By {author.data.name}</p>
```

### Computed Fields

Transform or derive fields in the schema using `.transform()`:

```ts
const blog = defineCollection({
  loader: glob({ pattern: '**/*.md', base: './src/content/blog' }),
  schema: z.object({
    title: z.string(),
    pubDate: z.coerce.date(),
    rawTags: z.array(z.string()).default([]),
  }).transform((data) => ({
    ...data,
    slug: data.title.toLowerCase().replace(/\s+/g, '-').replace(/[^\w-]/g, ''),
    isRecent: (Date.now() - data.pubDate.getTime()) < 30 * 24 * 60 * 60 * 1000,
    tags: data.rawTags.map(t => t.toLowerCase()),
    readingTime: undefined as number | undefined,  // computed at render time
  })),
});
```

### Custom Loaders

Build loaders for any data source — APIs, databases, CMSes:

```ts
// src/loaders/api-loader.ts
import type { Loader } from 'astro/loaders';

export function apiLoader(endpoint: string): Loader {
  return {
    name: 'api-loader',
    load: async ({ store, logger, parseData }) => {
      logger.info(`Fetching from ${endpoint}`);
      const response = await fetch(endpoint);
      const items = await response.json();

      store.clear();

      for (const item of items) {
        const data = await parseData({
          id: String(item.id),
          data: item,
        });
        store.set({ id: String(item.id), data });
      }
    },
  };
}
```

Use in content config:

```ts
// src/content.config.ts
import { apiLoader } from './loaders/api-loader';

const products = defineCollection({
  loader: apiLoader('https://api.example.com/products'),
  schema: z.object({
    name: z.string(),
    price: z.number(),
    category: z.string(),
  }),
});
```

Incremental loader with meta store (caches last-modified timestamps):

```ts
export function incrementalApiLoader(endpoint: string): Loader {
  return {
    name: 'incremental-api-loader',
    load: async ({ store, meta, logger, parseData }) => {
      const lastFetch = meta.get('lastFetch');
      const url = lastFetch
        ? `${endpoint}?since=${lastFetch}`
        : endpoint;

      const response = await fetch(url);
      const items = await response.json();

      if (!lastFetch) store.clear();

      for (const item of items) {
        if (item.deleted) {
          store.delete(String(item.id));
        } else {
          const data = await parseData({ id: String(item.id), data: item });
          store.set({ id: String(item.id), data });
        }
      }

      meta.set('lastFetch', new Date().toISOString());
    },
  };
}
```

---

## View Transitions

### Persist Directives

Keep interactive component state across page navigations:

```astro
<!-- Audio player keeps playing during navigation -->
<AudioPlayer client:load transition:persist />

<!-- Persist with explicit name (for components on different pages) -->
<VideoPlayer client:load transition:persist="media-player" />

<!-- Persist a regular HTML element's DOM state -->
<div transition:persist="sidebar">
  <nav>...</nav>
</div>
```

Rules:
- The component must appear on both the old and new page.
- Use the same `transition:persist` name if the component's position differs between pages.
- Works with all client directives.
- Persisted islands are NOT re-rendered; they keep their exact DOM and JS state.

### transition:name

Assign unique identifiers for paired animations across pages:

```astro
<!-- List page: src/pages/blog/index.astro -->
{posts.map(post => (
  <article>
    <img transition:name={`hero-${post.id}`} src={post.image} alt="" />
    <h2 transition:name={`title-${post.id}`}>
      <a href={`/blog/${post.id}`}>{post.data.title}</a>
    </h2>
  </article>
))}

<!-- Detail page: src/pages/blog/[id].astro -->
<img transition:name={`hero-${id}`} src={post.data.image} alt="" />
<h1 transition:name={`title-${id}`}>{post.data.title}</h1>
```

Rules:
- Names must be unique per page (no duplicates on the same page).
- Pairs are matched across pages by name.
- Unpaired elements use the default page-level transition.

### transition:animate

Control the animation style per element:

```astro
<!-- Built-in animations -->
<h1 transition:animate="fade">Fades in/out</h1>
<div transition:animate="slide">Slides from the side</div>
<p transition:animate="initial">Browser default (morph)</p>
<nav transition:animate="none">No animation</nav>

<!-- Customized built-in -->
---
import { fade, slide } from 'astro:transitions';
---
<div transition:animate={fade({ duration: '0.5s' })}>Slow fade</div>
<div transition:animate={slide({ duration: '0.3s', direction: 'right' })}>Slide right</div>

<!-- Fully custom animation -->
<div transition:animate={{
  old: {
    name: 'customOut',
    duration: '0.4s',
    easing: 'ease-in',
    fillMode: 'forwards',
  },
  new: {
    name: 'customIn',
    duration: '0.4s',
    easing: 'ease-out',
    fillMode: 'backwards',
  },
}}>
  Custom animation
</div>

<style is:global>
  @keyframes customOut {
    to { opacity: 0; transform: scale(0.95); }
  }
  @keyframes customIn {
    from { opacity: 0; transform: scale(1.05); }
  }
</style>
```

### Swap Functions

Override how the new page DOM replaces the old page:

```astro
---
import { ViewTransitions } from 'astro:transitions';
---
<head>
  <ViewTransitions />
  <script>
    import { swapFunctions } from 'astro:transitions/client';

    document.addEventListener('astro:before-swap', (event) => {
      // Preserve a specific DOM node across navigations
      const persistedEl = document.querySelector('#chat-widget');
      if (persistedEl) {
        const newDoc = event.newDocument;
        const target = newDoc.querySelector('#chat-widget');
        if (target) {
          target.replaceWith(persistedEl.cloneNode(true));
        }
      }
    });
  </script>
</head>
```

Custom swap function (Astro 4.15+):

```ts
document.addEventListener('astro:before-swap', (event) => {
  event.swap = () => {
    // Use the default implementation as a starting point
    swapFunctions.deselectScripts(event.newDocument);
    swapFunctions.swapRootAttributes(event.newDocument);
    swapFunctions.swapHeadElements(event.newDocument);

    // Custom body swap: animate old content out, new content in
    const oldBody = document.body;
    const newBody = event.newDocument.body;
    document.body.replaceWith(newBody);

    swapFunctions.saveFocus();
  };
});
```

### Lifecycle Events

Listen for transition lifecycle events:

```ts
// Fires before navigation starts
document.addEventListener('astro:before-preparation', (event) => {
  // event.to: destination URL
  // event.navigationType: 'push' | 'replace' | 'traverse'
  // event.from: source URL
});

// Fires before DOM swap
document.addEventListener('astro:before-swap', (event) => {
  // event.newDocument: the parsed new page DOM
  // event.swap: override swap function
});

// Fires after swap, before animations complete
document.addEventListener('astro:after-swap', () => {
  // Re-initialize third-party scripts
});

// Fires after all transitions complete
document.addEventListener('astro:page-load', () => {
  // Page is fully loaded and interactive
  // Also fires on initial page load
});
```

---

## Middleware Chaining and Auth Patterns

### Chaining with sequence()

Compose multiple middleware functions:

```ts
// src/middleware.ts
import { defineMiddleware, sequence } from 'astro:middleware';

const logging = defineMiddleware(async (context, next) => {
  const start = performance.now();
  const response = await next();
  const duration = performance.now() - start;
  console.log(`${context.request.method} ${context.url.pathname} - ${duration.toFixed(1)}ms`);
  return response;
});

const security = defineMiddleware(async (context, next) => {
  const response = await next();
  response.headers.set('X-Content-Type-Options', 'nosniff');
  response.headers.set('X-Frame-Options', 'DENY');
  response.headers.set('Referrer-Policy', 'strict-origin-when-cross-origin');
  return response;
});

const auth = defineMiddleware(async (context, next) => {
  const protectedPaths = ['/dashboard', '/admin', '/api/protected'];
  const isProtected = protectedPaths.some(p => context.url.pathname.startsWith(p));

  if (isProtected) {
    const token = context.cookies.get('auth_token')?.value;
    if (!token) return context.redirect('/login');
    try {
      context.locals.user = await verifyJWT(token);
    } catch {
      context.cookies.delete('auth_token');
      return context.redirect('/login');
    }
  }

  return next();
});

// Executed in order: logging → security → auth
export const onRequest = sequence(logging, security, auth);
```

### Auth Middleware Pattern

Full JWT auth with role-based access:

```ts
// src/middleware.ts
import { defineMiddleware } from 'astro:middleware';
import { verifyToken, type User } from './lib/auth';

const roleRequired: Record<string, string[]> = {
  '/admin': ['admin'],
  '/dashboard': ['admin', 'editor'],
  '/api/admin': ['admin'],
};

export const onRequest = defineMiddleware(async (context, next) => {
  const token = context.cookies.get('session')?.value;
  let user: User | null = null;

  if (token) {
    try { user = await verifyToken(token); } catch { /* expired */ }
  }

  context.locals.user = user;

  // Check role-based access
  for (const [path, roles] of Object.entries(roleRequired)) {
    if (context.url.pathname.startsWith(path)) {
      if (!user) return context.redirect('/login');
      if (!roles.includes(user.role)) {
        return new Response('Forbidden', { status: 403 });
      }
    }
  }

  return next();
});
```

Type `locals` in `src/env.d.ts`:

```ts
/// <reference types="astro/client" />
declare namespace App {
  interface Locals {
    user: import('./lib/auth').User | null;
  }
}
```

### CORS Middleware

```ts
const cors = defineMiddleware(async (context, next) => {
  if (!context.url.pathname.startsWith('/api/')) return next();

  if (context.request.method === 'OPTIONS') {
    return new Response(null, {
      status: 204,
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
        'Access-Control-Allow-Headers': 'Content-Type, Authorization',
        'Access-Control-Max-Age': '86400',
      },
    });
  }

  const response = await next();
  response.headers.set('Access-Control-Allow-Origin', '*');
  return response;
});
```

### Rate Limiting Middleware

```ts
const rateLimit = new Map<string, { count: number; resetAt: number }>();

const rateLimiter = defineMiddleware(async (context, next) => {
  if (!context.url.pathname.startsWith('/api/')) return next();

  const ip = context.clientAddress;
  const now = Date.now();
  const window = 60_000; // 1 minute
  const maxRequests = 60;

  const entry = rateLimit.get(ip);
  if (!entry || now > entry.resetAt) {
    rateLimit.set(ip, { count: 1, resetAt: now + window });
  } else if (entry.count >= maxRequests) {
    return new Response('Too Many Requests', {
      status: 429,
      headers: { 'Retry-After': String(Math.ceil((entry.resetAt - now) / 1000)) },
    });
  } else {
    entry.count++;
  }

  return next();
});
```

---

## Server Endpoints for REST APIs

### Full CRUD Example

```ts
// src/pages/api/posts/index.ts
import type { APIRoute } from 'astro';
import { db } from '../../lib/db';

export const GET: APIRoute = async ({ url }) => {
  const page = Number(url.searchParams.get('page')) || 1;
  const limit = Math.min(Number(url.searchParams.get('limit')) || 20, 100);
  const offset = (page - 1) * limit;

  const [posts, total] = await Promise.all([
    db.posts.findMany({ skip: offset, take: limit, orderBy: { createdAt: 'desc' } }),
    db.posts.count(),
  ]);

  return Response.json({
    data: posts,
    meta: { page, limit, total, totalPages: Math.ceil(total / limit) },
  });
};

export const POST: APIRoute = async ({ request, locals }) => {
  if (!locals.user) return new Response('Unauthorized', { status: 401 });

  const body = await request.json();
  const { title, content } = body;

  if (!title || !content) {
    return Response.json({ error: 'title and content required' }, { status: 400 });
  }

  const post = await db.posts.create({
    data: { title, content, authorId: locals.user.id },
  });

  return Response.json(post, { status: 201 });
};
```

```ts
// src/pages/api/posts/[id].ts
import type { APIRoute } from 'astro';

export const GET: APIRoute = async ({ params }) => {
  const post = await db.posts.findUnique({ where: { id: params.id } });
  if (!post) return Response.json({ error: 'Not found' }, { status: 404 });
  return Response.json(post);
};

export const PUT: APIRoute = async ({ params, request, locals }) => {
  if (!locals.user) return new Response('Unauthorized', { status: 401 });
  const body = await request.json();
  const post = await db.posts.update({ where: { id: params.id }, data: body });
  return Response.json(post);
};

export const DELETE: APIRoute = async ({ params, locals }) => {
  if (!locals.user) return new Response('Unauthorized', { status: 401 });
  await db.posts.delete({ where: { id: params.id } });
  return new Response(null, { status: 204 });
};
```

### Error Handling Pattern

Wrapper for consistent error responses:

```ts
// src/lib/api-utils.ts
import type { APIRoute, APIContext } from 'astro';

export function withErrorHandling(handler: APIRoute): APIRoute {
  return async (context: APIContext) => {
    try {
      return await handler(context);
    } catch (error) {
      console.error(`API Error: ${context.url.pathname}`, error);

      if (error instanceof ValidationError) {
        return Response.json({ error: error.message, fields: error.fields }, { status: 400 });
      }

      return Response.json(
        { error: 'Internal Server Error' },
        { status: 500 },
      );
    }
  };
}

// Usage:
export const POST: APIRoute = withErrorHandling(async ({ request }) => {
  const data = await request.json();
  // ... handler logic, thrown errors are caught
  return Response.json({ success: true });
});
```

### File Uploads

```ts
// src/pages/api/upload.ts
import type { APIRoute } from 'astro';
import { writeFile } from 'node:fs/promises';
import { join } from 'node:path';

export const POST: APIRoute = async ({ request }) => {
  const formData = await request.formData();
  const file = formData.get('file') as File | null;

  if (!file) return Response.json({ error: 'No file provided' }, { status: 400 });

  const maxSize = 5 * 1024 * 1024; // 5MB
  if (file.size > maxSize) {
    return Response.json({ error: 'File too large' }, { status: 413 });
  }

  const buffer = Buffer.from(await file.arrayBuffer());
  const ext = file.name.split('.').pop();
  const filename = `${crypto.randomUUID()}.${ext}`;
  await writeFile(join('uploads', filename), buffer);

  return Response.json({ filename, size: file.size }, { status: 201 });
};
```

---

## Integration Patterns (Islands with Shared State)

### Nano Stores for Cross-Framework State

Install: `npm install nanostores @nanostores/react @nanostores/vue @nanostores/solid`

```ts
// src/stores/cart.ts
import { atom, computed } from 'nanostores';

export interface CartItem {
  id: string;
  name: string;
  price: number;
  quantity: number;
}

export const $cartItems = atom<CartItem[]>([]);

export const $cartTotal = computed($cartItems, (items) =>
  items.reduce((sum, item) => sum + item.price * item.quantity, 0)
);

export function addToCart(item: Omit<CartItem, 'quantity'>) {
  const items = $cartItems.get();
  const existing = items.find(i => i.id === item.id);
  if (existing) {
    $cartItems.set(items.map(i =>
      i.id === item.id ? { ...i, quantity: i.quantity + 1 } : i
    ));
  } else {
    $cartItems.set([...items, { ...item, quantity: 1 }]);
  }
}

export function removeFromCart(id: string) {
  $cartItems.set($cartItems.get().filter(i => i.id !== id));
}
```

### React Island

```tsx
// src/components/CartButton.tsx
import { useStore } from '@nanostores/react';
import { $cartItems, $cartTotal } from '../stores/cart';

export default function CartButton() {
  const items = useStore($cartItems);
  const total = useStore($cartTotal);

  return (
    <button className="cart-button">
      🛒 {items.length} items (${total.toFixed(2)})
    </button>
  );
}
```

### Vue Island

```vue
<!-- src/components/AddToCart.vue -->
<script setup lang="ts">
import { useStore } from '@nanostores/vue';
import { addToCart } from '../stores/cart';

const props = defineProps<{ id: string; name: string; price: number }>();

function handleAdd() {
  addToCart({ id: props.id, name: props.name, price: props.price });
}
</script>

<template>
  <button @click="handleAdd">Add to Cart — ${{ price.toFixed(2) }}</button>
</template>
```

### Svelte Island

```svelte
<!-- src/components/CartCount.svelte -->
<script lang="ts">
  import { $cartItems } from '../stores/cart';
</script>

<span class="badge">{$cartItems.length}</span>
```

### Solid Island

```tsx
// src/components/CartTotal.tsx
import { useStore } from '@nanostores/solid';
import { $cartTotal } from '../stores/cart';

export default function CartTotal() {
  const total = useStore($cartTotal);
  return <span>Total: ${total().toFixed(2)}</span>;
}
```

Using all islands together:

```astro
---
import CartButton from '../components/CartButton.tsx';
import AddToCart from '../components/AddToCart.vue';
import CartCount from '../components/CartCount.svelte';
import CartTotal from '../components/CartTotal.tsx';
---
<nav>
  <CartButton client:load />
  <CartCount client:load />
</nav>
<main>
  <AddToCart client:visible id="p1" name="Widget" price={9.99} />
  <CartTotal client:load />
</main>
```

---

## Internationalization (i18n) Routing

### Built-in i18n Configuration

```js
// astro.config.mjs
import { defineConfig } from 'astro/config';

export default defineConfig({
  i18n: {
    defaultLocale: 'en',
    locales: ['en', 'es', 'fr', 'de', 'ja'],
    routing: {
      prefixDefaultLocale: false,  // / instead of /en/
      // redirectToDefaultLocale: false,  // don't redirect /en/ to /
    },
    fallback: {
      es: 'en',
      de: 'en',
    },
  },
});
```

Route structure:

```
src/pages/
├── index.astro           → /          (English - default)
├── about.astro           → /about
├── es/
│   ├── index.astro       → /es/       (Spanish)
│   └── about.astro       → /es/about
├── fr/
│   ├── index.astro       → /fr/       (French)
│   └── about.astro       → /fr/about
```

Access i18n utilities in components:

```astro
---
import { getRelativeLocaleUrl } from 'astro:i18n';

const currentLocale = Astro.currentLocale; // 'en', 'es', etc.
const spanishHome = getRelativeLocaleUrl('es', '/');
---
<a href={spanishHome}>Español</a>
```

### Language Switcher Component

```astro
---
// src/components/LanguageSwitcher.astro
import { getRelativeLocaleUrl } from 'astro:i18n';

const localeNames: Record<string, string> = {
  en: 'English',
  es: 'Español',
  fr: 'Français',
  de: 'Deutsch',
  ja: '日本語',
};

const currentLocale = Astro.currentLocale ?? 'en';
const currentPath = Astro.url.pathname.replace(`/${currentLocale}`, '') || '/';
---
<nav aria-label="Language">
  <ul>
    {Object.entries(localeNames).map(([locale, name]) => (
      <li>
        <a
          href={getRelativeLocaleUrl(locale, currentPath)}
          aria-current={locale === currentLocale ? 'page' : undefined}
        >
          {name}
        </a>
      </li>
    ))}
  </ul>
</nav>
```

### Translated Content Collections

```ts
// src/content.config.ts
const docs = defineCollection({
  loader: glob({ pattern: '**/*.md', base: './src/content/docs' }),
  schema: z.object({
    title: z.string(),
    locale: z.enum(['en', 'es', 'fr']),
    translationKey: z.string(),  // shared key across translations
  }),
});
```

```
src/content/docs/
├── en/
│   └── getting-started.md   # translationKey: "getting-started"
├── es/
│   └── getting-started.md   # translationKey: "getting-started"
└── fr/
    └── getting-started.md   # translationKey: "getting-started"
```

Query translated content:

```astro
---
const locale = Astro.currentLocale ?? 'en';
const docs = await getCollection('docs', ({ data }) => data.locale === locale);
---
```

---

## Astro DB (libSQL) Integration

### Defining Tables

```ts
// db/config.ts
import { defineDb, defineTable, column, NOW } from 'astro:db';

const Comment = defineTable({
  columns: {
    id: column.number({ primaryKey: true }),
    postSlug: column.text(),
    author: column.text(),
    body: column.text(),
    likes: column.number({ default: 0 }),
    createdAt: column.date({ default: NOW }),
  },
  indexes: [
    { on: ['postSlug'] },
  ],
});

const User = defineTable({
  columns: {
    id: column.text({ primaryKey: true }),
    email: column.text({ unique: true }),
    name: column.text(),
    role: column.text({ default: 'user' }),
  },
});

export default defineDb({
  tables: { Comment, User },
});
```

### Seeding Data

```ts
// db/seed.ts
import { db, Comment, User } from 'astro:db';

export default async function seed() {
  await db.insert(User).values([
    { id: 'usr_1', email: 'admin@example.com', name: 'Admin', role: 'admin' },
    { id: 'usr_2', email: 'writer@example.com', name: 'Writer', role: 'editor' },
  ]);

  await db.insert(Comment).values([
    { postSlug: 'hello-world', author: 'Alice', body: 'Great post!' },
    { postSlug: 'hello-world', author: 'Bob', body: 'Very helpful.' },
  ]);
}
```

### Querying with Drizzle ORM

Astro DB uses Drizzle ORM under the hood:

```astro
---
import { db, Comment, eq, desc } from 'astro:db';

// Select all comments for a post
const comments = await db
  .select()
  .from(Comment)
  .where(eq(Comment.postSlug, 'hello-world'))
  .orderBy(desc(Comment.createdAt));

// Insert
await db.insert(Comment).values({
  postSlug: 'hello-world',
  author: 'New User',
  body: 'Another comment',
});

// Update
await db
  .update(Comment)
  .set({ likes: 5 })
  .where(eq(Comment.id, 1));

// Delete
await db.delete(Comment).where(eq(Comment.id, 1));
```

Remote database for production — push schema:

```bash
astro db push --remote   # push schema changes to hosted libSQL
astro db execute db/seed.ts --remote  # seed remote DB
```

---

## Actions (Type-Safe Form Handling)

### Defining Actions

```ts
// src/actions/index.ts
import { defineAction } from 'astro:actions';
import { z } from 'astro:schema';

export const server = {
  newsletter: {
    subscribe: defineAction({
      accept: 'form',
      input: z.object({
        email: z.string().email('Invalid email'),
        name: z.string().min(1, 'Name required'),
      }),
      handler: async ({ email, name }) => {
        await addToNewsletter(email, name);
        return { success: true, message: `Welcome, ${name}!` };
      },
    }),
  },

  comment: {
    create: defineAction({
      accept: 'json',
      input: z.object({
        postSlug: z.string(),
        body: z.string().min(1).max(1000),
      }),
      handler: async ({ postSlug, body }, context) => {
        const user = context.locals.user;
        if (!user) throw new ActionError({ code: 'UNAUTHORIZED' });
        return await db.insert(Comment).values({ postSlug, body, author: user.name });
      },
    }),
  },
};
```

### Calling Actions from Forms

```astro
---
// src/pages/newsletter.astro
import { actions } from 'astro:actions';

const result = Astro.getActionResult(actions.newsletter.subscribe);
---
<form method="POST" action={actions.newsletter.subscribe}>
  <input name="name" type="text" required />
  <input name="email" type="email" required />
  <button type="submit">Subscribe</button>
</form>

{result?.error && <p class="error">{result.error.message}</p>}
{result?.data && <p class="success">{result.data.message}</p>}
```

With progressive enhancement (works without JS, enhances with JS):

```astro
---
import { actions } from 'astro:actions';
---
<form method="POST" action={actions.newsletter.subscribe}>
  <input name="email" type="email" required />
  <button type="submit">Subscribe</button>
</form>

<script>
  import { actions } from 'astro:actions';
  import { navigate } from 'astro:transitions/client';

  const form = document.querySelector('form')!;
  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    const formData = new FormData(form);
    const { data, error } = await actions.newsletter.subscribe(formData);
    if (data) navigate('/thank-you');
    if (error) alert(error.message);
  });
</script>
```

### Calling Actions from Client Components

```tsx
// src/components/CommentForm.tsx (React)
import { actions } from 'astro:actions';

export default function CommentForm({ postSlug }: { postSlug: string }) {
  const [body, setBody] = useState('');

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    const { data, error } = await actions.comment.create({ postSlug, body });
    if (error) console.error(error.message);
    else setBody('');
  }

  return (
    <form onSubmit={handleSubmit}>
      <textarea value={body} onChange={(e) => setBody(e.target.value)} />
      <button type="submit">Post Comment</button>
    </form>
  );
}
```

---

## Server Islands

Server Islands render dynamic, personalized content on the server while the rest of the page remains statically cached. They load asynchronously after the initial page load.

### Configuring Server Islands

```js
// astro.config.mjs
export default defineConfig({
  output: 'hybrid',       // or 'server'
  adapter: vercel(),
});
```

Mark a component as a server island with `server:defer`:

```astro
---
// src/pages/index.astro
import UserGreeting from '../components/UserGreeting.astro';
import RecommendedPosts from '../components/RecommendedPosts.astro';
---
<!-- Static shell loads instantly -->
<h1>Welcome to our blog</h1>
<article>...static content...</article>

<!-- Server island: rendered on-demand, streamed in -->
<UserGreeting server:defer />
<RecommendedPosts server:defer />
```

The server island component:

```astro
---
// src/components/UserGreeting.astro
const user = Astro.locals.user;
---
{user ? (
  <p>Welcome back, {user.name}!</p>
) : (
  <a href="/login">Sign in</a>
)}
```

### Fallback Content

Show placeholder content while the server island loads:

```astro
<UserGreeting server:defer>
  <div slot="fallback" class="skeleton">
    <div class="skeleton-text" style="width: 200px; height: 1em;"></div>
  </div>
</UserGreeting>
```

### Caching Strategies

Control caching with response headers in the server island component:

```astro
---
// Short cache for personalized content
Astro.response.headers.set('Cache-Control', 'private, max-age=60');

// Or no cache for real-time data
Astro.response.headers.set('Cache-Control', 'no-store');
---
```

Server islands are ideal for:
- User-specific content (greetings, avatars, settings)
- Authenticated sections on otherwise public pages
- Real-time data (stock prices, live scores)
- A/B test variants
- Shopping cart widgets on product pages
