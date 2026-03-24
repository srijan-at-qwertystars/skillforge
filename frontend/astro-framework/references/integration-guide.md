# Astro Framework Integration Guide

## Table of Contents

- [React in Astro](#react-in-astro)
  - [Setup and Configuration](#react-setup-and-configuration)
  - [State Management](#react-state-management)
  - [Context and Providers](#react-context-and-providers)
  - [Hooks and Side Effects](#react-hooks-and-side-effects)
- [Vue in Astro](#vue-in-astro)
  - [Setup and Configuration](#vue-setup-and-configuration)
  - [Composition API](#vue-composition-api)
  - [Pinia State Management](#pinia-state-management)
- [Svelte in Astro](#svelte-in-astro)
  - [Setup and Configuration](#svelte-setup-and-configuration)
  - [Stores](#svelte-stores)
  - [Transitions and Animations](#svelte-transitions-and-animations)
- [Sharing State Between Frameworks](#sharing-state-between-frameworks)
  - [Nano Stores](#nano-stores)
  - [Custom Events](#custom-events)
  - [URL State](#url-state)
- [UI Component Libraries](#ui-component-libraries)
  - [shadcn/ui in Astro](#shadcnui-in-astro)
  - [Radix UI in Astro](#radix-ui-in-astro)
  - [Headless UI in Astro](#headless-ui-in-astro)
- [CMS Integrations](#cms-integrations)
  - [Contentful](#contentful)
  - [Sanity](#sanity)
  - [Strapi](#strapi)
  - [WordPress Headless](#wordpress-headless)
- [Authentication Patterns](#authentication-patterns)
  - [Clerk](#clerk)
  - [Auth.js (NextAuth)](#authjs-nextauth)
  - [Lucia](#lucia)
- [Database Integration](#database-integration)
  - [Drizzle ORM](#drizzle-orm)
  - [Prisma](#prisma)
  - [Astro DB](#astro-db-integration)

---

## React in Astro

### React Setup and Configuration

```bash
npx astro add react
```

This adds `@astrojs/react`, `react`, and `react-dom` to your project. When using React alongside other JSX frameworks (Preact, Solid), scope with `include`/`exclude`:

```js
// astro.config.mjs
import react from '@astrojs/react';
import solid from '@astrojs/solid-js';

export default defineConfig({
  integrations: [
    react({ include: ['**/react/*'] }),
    solid({ include: ['**/solid/*'] }),
  ],
});
```

### React State Management

React state works normally within hydrated islands. Each island is an independent React tree:

```tsx
// src/components/react/TodoList.tsx
import { useState, useCallback } from 'react';

interface Todo {
  id: number;
  text: string;
  done: boolean;
}

export default function TodoList({ initial = [] }: { initial?: Todo[] }) {
  const [todos, setTodos] = useState<Todo[]>(initial);
  const [input, setInput] = useState('');

  const addTodo = useCallback(() => {
    if (!input.trim()) return;
    setTodos((prev) => [...prev, { id: Date.now(), text: input, done: false }]);
    setInput('');
  }, [input]);

  const toggleTodo = useCallback((id: number) => {
    setTodos((prev) =>
      prev.map((t) => (t.id === id ? { ...t, done: !t.done } : t))
    );
  }, []);

  return (
    <div>
      <div>
        <input value={input} onChange={(e) => setInput(e.target.value)}
               onKeyDown={(e) => e.key === 'Enter' && addTodo()} />
        <button onClick={addTodo}>Add</button>
      </div>
      <ul>
        {todos.map((todo) => (
          <li key={todo.id} onClick={() => toggleTodo(todo.id)}
              style={{ textDecoration: todo.done ? 'line-through' : 'none' }}>
            {todo.text}
          </li>
        ))}
      </ul>
    </div>
  );
}
```

```astro
---
import TodoList from '../components/react/TodoList';
const initialTodos = await fetchTodos();
---
<TodoList client:load initial={initialTodos} />
```

### React Context and Providers

Context works within a single React island. To share context across islands, wrap them in a common provider component:

```tsx
// src/components/react/ThemeProvider.tsx
import { createContext, useContext, useState, type ReactNode } from 'react';

type Theme = 'light' | 'dark';

const ThemeContext = createContext<{
  theme: Theme;
  toggle: () => void;
}>({ theme: 'light', toggle: () => {} });

export function ThemeProvider({ children }: { children: ReactNode }) {
  const [theme, setTheme] = useState<Theme>('light');
  const toggle = () => setTheme((t) => (t === 'light' ? 'dark' : 'light'));
  return (
    <ThemeContext.Provider value={{ theme, toggle }}>
      {children}
    </ThemeContext.Provider>
  );
}

export const useTheme = () => useContext(ThemeContext);
```

```tsx
// src/components/react/AppShell.tsx
import { ThemeProvider } from './ThemeProvider';
import Navbar from './Navbar';
import Sidebar from './Sidebar';

// Wrap multiple components in one island to share context
export default function AppShell() {
  return (
    <ThemeProvider>
      <Navbar />
      <Sidebar />
    </ThemeProvider>
  );
}
```

```astro
<AppShell client:load />
```

### React Hooks and Side Effects

Standard React hooks work in hydrated islands. `useEffect` only runs on the client — for SSR data, fetch in Astro frontmatter and pass as props. Use `AbortController` in `useEffect` cleanup for fetch cancellation.

---

## Vue in Astro

### Vue Setup and Configuration

```bash
npx astro add vue
```

Enable Vue-specific features via the integration config:

```js
// astro.config.mjs
import vue from '@astrojs/vue';

export default defineConfig({
  integrations: [
    vue({
      appEntrypoint: '/src/pages/_app',  // For global Vue plugins
      jsx: true,                          // Enable JSX support
    }),
  ],
});
```

To install global Vue plugins (router, Pinia), create an app entrypoint:

```ts
// src/pages/_app.ts
import type { App } from 'vue';
import { createPinia } from 'pinia';

export default (app: App) => {
  app.use(createPinia());
};
```

### Vue Composition API

Use `<script setup lang="ts">` with `defineProps`, `defineEmits`, `ref`, `computed`, and `watch`. Vue components work as Astro islands with `client:*` directives:

```vue
<!-- src/components/vue/Counter.vue -->
<script setup lang="ts">
import { ref, computed } from 'vue';
const props = defineProps<{ initial?: number }>();
const count = ref(props.initial ?? 0);
const doubled = computed(() => count.value * 2);
</script>

<template>
  <button @click="count++">{{ count }} (×2 = {{ doubled }})</button>
</template>
```

```astro
<Counter client:visible :initial="5" />
```

### Pinia State Management

Register Pinia via the `appEntrypoint` in `@astrojs/vue` config. Define stores using the Composition API style with `defineStore`:

```ts
// src/stores/cart.ts
import { defineStore } from 'pinia';
import { ref, computed } from 'vue';

export const useCartStore = defineStore('cart', () => {
  const items = ref<CartItem[]>([]);
  const total = computed(() =>
    items.value.reduce((sum, i) => sum + i.price * i.quantity, 0)
  );
  function addItem(product: CartItem) { items.value.push(product); }
  return { items, total, addItem };
});
```

Use in Vue components with `const cart = useCartStore()`. Pinia state is shared across Vue components within the same island.

---

## Svelte in Astro

### Svelte Setup and Configuration

```bash
npx astro add svelte
```

```js
// astro.config.mjs
import svelte from '@astrojs/svelte';

export default defineConfig({
  integrations: [svelte()],
});
```

Svelte 5 runes (`$state`, `$derived`, `$effect`) work in Astro:

```svelte
<!-- src/components/svelte/Counter.svelte -->
<script lang="ts">
  interface Props {
    initial?: number;
    step?: number;
  }

  let { initial = 0, step = 1 }: Props = $props();
  let count = $state(initial);
  let doubled = $derived(count * 2);

  function increment() { count += step; }
  function decrement() { count -= step; }
</script>

<div class="counter">
  <button onclick={decrement}>-</button>
  <span>{count} (doubled: {doubled})</span>
  <button onclick={increment}>+</button>
</div>

<style>
  .counter {
    display: flex;
    align-items: center;
    gap: 0.5rem;
  }
</style>
```

### Svelte Stores

Svelte stores work across components within the same island:

```ts
// src/stores/notifications.ts
import { writable, derived } from 'svelte/store';

interface Notification {
  id: string;
  type: 'success' | 'error' | 'info';
  message: string;
}

export const notifications = writable<Notification[]>([]);

export const unreadCount = derived(notifications, ($n) => $n.length);

export function addNotification(type: Notification['type'], message: string) {
  const id = crypto.randomUUID();
  notifications.update((n) => [...n, { id, type, message }]);
  setTimeout(() => removeNotification(id), 5000);
}

export function removeNotification(id: string) {
  notifications.update((n) => n.filter((item) => item.id !== id));
}
```

```svelte
<!-- src/components/svelte/NotificationList.svelte -->
<script>
  import { notifications, removeNotification } from '../../stores/notifications';
</script>

{#each $notifications as notif (notif.id)}
  <div class="notification {notif.type}" transition:fly={{ y: -20, duration: 300 }}>
    <p>{notif.message}</p>
    <button onclick={() => removeNotification(notif.id)}>×</button>
  </div>
{/each}
```

### Svelte Transitions and Animations

Svelte transitions work in Astro islands. Use `in:fly`, `out:fade`, `animate:flip` on elements within `{#each}` blocks. Import from `svelte/transition` and `svelte/animate`. All Svelte animation features work when the component is hydrated with a `client:*` directive.

---

## Sharing State Between Frameworks

### Nano Stores

Use `nanostores` to share reactive state between React, Vue, Svelte, and Astro:

```bash
npm install nanostores @nanostores/react @nanostores/vue
```

```ts
// src/stores/shared.ts
import { atom, map, computed } from 'nanostores';

// Simple atom
export const $count = atom(0);

// Map for complex state
export const $user = map<{ name: string; email: string; loggedIn: boolean }>({
  name: '',
  email: '',
  loggedIn: false,
});

// Computed values
export const $greeting = computed($user, (user) =>
  user.loggedIn ? `Hello, ${user.name}!` : 'Please sign in'
);

// Actions
export function increment() { $count.set($count.get() + 1); }
export function login(name: string, email: string) {
  $user.set({ name, email, loggedIn: true });
}
```

Use in React:
```tsx
// src/components/react/SharedCounter.tsx
import { useStore } from '@nanostores/react';
import { $count, increment } from '../../stores/shared';

export default function SharedCounter() {
  const count = useStore($count);
  return <button onClick={increment}>React: {count}</button>;
}
```

Use in Vue:
```vue
<!-- src/components/vue/SharedCounter.vue -->
<script setup>
import { useStore } from '@nanostores/vue';
import { $count, increment } from '../../stores/shared';
const count = useStore($count);
</script>

<template>
  <button @click="increment">Vue: {{ count }}</button>
</template>
```

Use in Svelte:
```svelte
<!-- src/components/svelte/SharedCounter.svelte -->
<script>
  import { $count, increment } from '../../stores/shared';
</script>

<!-- Svelte stores are natively compatible with nanostores -->
<button onclick={increment}>Svelte: {$count}</button>
```

### Custom Events

For simple cross-framework communication, use typed `CustomEvent` wrappers around `window.dispatchEvent` and `window.addEventListener`. Create a typed `emit(event, detail)` and `on(event, handler)` utility. This works across any framework without dependencies.

### URL State

Share state via URL search parameters using `URLSearchParams` and `history.replaceState`. Works across any framework and survives navigation.

---

## UI Component Libraries

### shadcn/ui in Astro

shadcn/ui works in Astro via the React integration:

```bash
npx astro add react tailwind
npx shadcn@latest init
```

```json
// components.json
{
  "$schema": "https://ui.shadcn.com/schema.json",
  "style": "default",
  "rsc": false,
  "tsx": true,
  "tailwind": {
    "config": "tailwind.config.mjs",
    "css": "src/styles/globals.css",
    "baseColor": "slate"
  },
  "aliases": {
    "components": "@/components/ui",
    "utils": "@/lib/utils"
  }
}
```

```bash
npx shadcn@latest add button dialog dropdown-menu
```

```astro
---
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogTrigger } from '@/components/ui/dialog';
---
<!-- Static button — no JS shipped -->
<Button variant="outline">Static Button</Button>

<!-- Interactive dialog — needs client directive -->
<Dialog client:load>
  <DialogTrigger asChild>
    <Button variant="default">Open Dialog</Button>
  </DialogTrigger>
  <DialogContent>
    <h2>Dialog Title</h2>
    <p>Dialog content goes here.</p>
  </DialogContent>
</Dialog>
```

### Radix UI in Astro

Install individual Radix packages (`@radix-ui/react-dropdown-menu`, etc.). Use them as standard React components in Astro with `client:load` for interactivity. All Radix primitives (Dialog, Popover, Tabs, etc.) work out of the box.

### Headless UI in Astro

Install `@headlessui/react` or `@headlessui/vue`. Components (Combobox, Dialog, Listbox, Menu, etc.) work as standard framework components with `client:load`. Headless UI provides behavior and accessibility; you supply all styling.

---

## CMS Integrations

### Contentful

```ts
// src/lib/contentful.ts
import contentful from 'contentful';

const client = contentful.createClient({
  space: import.meta.env.CONTENTFUL_SPACE_ID,
  accessToken: import.meta.env.CONTENTFUL_ACCESS_TOKEN,
});

export async function getBlogPosts() {
  const entries = await client.getEntries({
    content_type: 'blogPost',
    order: ['-fields.publishDate'],
    include: 2,
  });
  return entries.items.map((item) => ({
    id: item.sys.id,
    slug: item.fields.slug,
    title: item.fields.title,
    body: item.fields.body,
    publishDate: item.fields.publishDate,
    heroImage: item.fields.heroImage?.fields?.file?.url,
  }));
}
```

Use as a Content Collection loader:
```ts
// content.config.ts
const contentfulBlog = defineCollection({
  loader: async () => {
    const posts = await getBlogPosts();
    return posts.map((p) => ({ id: p.slug, ...p }));
  },
  schema: z.object({
    title: z.string(),
    body: z.any(),
    publishDate: z.coerce.date(),
    heroImage: z.string().url().optional(),
  }),
});
```

### Sanity

```bash
npm install @sanity/client @sanity/image-url
```

```ts
// src/lib/sanity.ts
import { createClient } from '@sanity/client';
import imageUrlBuilder from '@sanity/image-url';

export const sanityClient = createClient({
  projectId: import.meta.env.SANITY_PROJECT_ID,
  dataset: 'production',
  apiVersion: '2024-01-01',
  useCdn: true,
});

const builder = imageUrlBuilder(sanityClient);
export function urlFor(source: any) { return builder.image(source); }

export async function getPosts() {
  return sanityClient.fetch(
    `*[_type == "post" && !(_id in path("drafts.**"))] | order(publishedAt desc) {
      _id,
      title,
      slug,
      "excerpt": array::join(string::split(pt::text(body), "")[0..200], ""),
      publishedAt,
      mainImage,
      "author": author->{ name, image }
    }`
  );
}
```

### Strapi

Create a fetch wrapper using `STRAPI_URL` and `STRAPI_TOKEN` env vars. Call the REST API at `/api/<content-type>` with Bearer token auth. Use query params for population (`populate=*`), sorting, and pagination. Parse `{ data }` from responses.

### WordPress Headless

Fetch from the WP REST API at `${WP_URL}/wp-json/wp/v2/posts?_embed` with pagination via `page` and `per_page` params. Use `_embed` to include featured images and authors. Map `post.title.rendered`, `post.content.rendered`, and embedded media. For GraphQL, install the WPGraphQL plugin and query `${WP_URL}/graphql`.
```

---

## Authentication Patterns

### Clerk

Install `@clerk/astro`, add `clerk()` to integrations with `output: 'server'`. Use `clerkMiddleware` with `createRouteMatcher` to protect routes. Access auth state via `Astro.locals.auth()` in pages. Clerk provides pre-built UI components for sign-in/sign-up.

### Auth.js (NextAuth)

Install `auth-astro` and `@auth/core`. Configure providers (GitHub, Google, etc.) in `auth.config.ts` with `defineConfig`. Use `getSession(Astro.request)` in pages to check auth state. Auth.js handles OAuth flows via `/api/auth/*` routes automatically.

### Lucia

```bash
npm install lucia @lucia-auth/adapter-drizzle
```

```ts
// src/lib/auth.ts
import { Lucia } from 'lucia';
import { DrizzleAdapter } from '@lucia-auth/adapter-drizzle';
import { db, userTable, sessionTable } from './db';

const adapter = new DrizzleAdapter(db, sessionTable, userTable);

export const lucia = new Lucia(adapter, {
  sessionCookie: {
    attributes: { secure: import.meta.env.PROD },
  },
  getUserAttributes: (attributes) => ({
    username: attributes.username,
    email: attributes.email,
  }),
});

declare module 'lucia' {
  interface Register {
    Lucia: typeof lucia;
    DatabaseUserAttributes: { username: string; email: string };
  }
}
```

```ts
// src/middleware.ts
import { lucia } from './lib/auth';
import { defineMiddleware } from 'astro:middleware';

export const onRequest = defineMiddleware(async (context, next) => {
  const sessionId = context.cookies.get(lucia.sessionCookieName)?.value ?? null;
  if (!sessionId) {
    context.locals.user = null;
    context.locals.session = null;
    return next();
  }

  const { session, user } = await lucia.validateSession(sessionId);
  if (session?.fresh) {
    const cookie = lucia.createSessionCookie(session.id);
    context.cookies.set(cookie.name, cookie.value, cookie.attributes);
  }
  if (!session) {
    const cookie = lucia.createBlankSessionCookie();
    context.cookies.set(cookie.name, cookie.value, cookie.attributes);
  }

  context.locals.session = session;
  context.locals.user = user;
  return next();
});
```

---

## Database Integration

### Drizzle ORM

```bash
npm install drizzle-orm better-sqlite3
npm install -D drizzle-kit @types/better-sqlite3
```

```ts
// src/db/schema.ts
import { sqliteTable, text, integer } from 'drizzle-orm/sqlite-core';

export const users = sqliteTable('users', {
  id: text('id').primaryKey(),
  email: text('email').notNull().unique(),
  username: text('username').notNull(),
  hashedPassword: text('hashed_password').notNull(),
  createdAt: integer('created_at', { mode: 'timestamp' }).notNull(),
});

export const posts = sqliteTable('posts', {
  id: integer('id').primaryKey({ autoIncrement: true }),
  title: text('title').notNull(),
  slug: text('slug').notNull().unique(),
  content: text('content').notNull(),
  authorId: text('author_id').notNull().references(() => users.id),
  published: integer('published', { mode: 'boolean' }).default(false),
  createdAt: integer('created_at', { mode: 'timestamp' }).notNull(),
});
```

```ts
// src/db/index.ts
import { drizzle } from 'drizzle-orm/better-sqlite3';
import Database from 'better-sqlite3';
import * as schema from './schema';

const sqlite = new Database('data.db');
export const db = drizzle(sqlite, { schema });
```

```ts
// drizzle.config.ts
import { defineConfig } from 'drizzle-kit';

export default defineConfig({
  schema: './src/db/schema.ts',
  out: './drizzle',
  dialect: 'sqlite',
  dbCredentials: { url: 'data.db' },
});
```

Use in Astro pages and endpoints:
```astro
---
import { db } from '../db';
import { posts, users } from '../db/schema';
import { eq } from 'drizzle-orm';

const allPosts = await db.select()
  .from(posts)
  .leftJoin(users, eq(posts.authorId, users.id))
  .where(eq(posts.published, true));
---
```

### Prisma

Install `prisma` and `@prisma/client`. Define schema in `prisma/schema.prisma`. Create a singleton client in `src/lib/prisma.ts` to prevent multiple instances in development:

```ts
import { PrismaClient } from '@prisma/client';
const globalForPrisma = globalThis as unknown as { prisma: PrismaClient };
export const prisma = globalForPrisma.prisma || new PrismaClient();
if (import.meta.env.DEV) globalForPrisma.prisma = prisma;
```

Run `npx prisma generate` after schema changes. Use in pages and endpoints.

### Astro DB Integration

Astro DB is built in and uses libSQL (Turso) in production. Define tables in `db/config.ts` with `defineTable` and `column.*` types. Seed dev data in `db/seed.ts`. Query with built-in Drizzle ORM (`import { db, Table } from 'astro:db'`). For production, set `ASTRO_DB_REMOTE_URL` and `ASTRO_DB_APP_TOKEN` env vars and build with `astro build --remote`. See the main SKILL.md for full Astro DB documentation.
