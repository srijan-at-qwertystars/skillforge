---
name: nuxt-framework
description: >
  Nuxt 3 full-stack Vue framework skill covering auto-imports, file-based routing, Nitro server
  routes, data fetching (useFetch, useAsyncData, $fetch), useState, middleware, layouts, plugins,
  modules, Nuxt DevTools, hybrid rendering (SSR/SSG/SPA/ISR per route via routeRules), deployment
  presets (Vercel, Netlify, Cloudflare Workers, Node), SEO (useHead, useSeoMeta), Nuxt Content,
  Nuxt Image, error handling (createError, showError), and production patterns.
  Triggers: Nuxt app, Nuxt 3, Vue SSR, Nitro server, Nuxt module, nuxt.config, useFetch,
  useAsyncData, Nuxt Content, NuxtHub, Nuxt Image, file-based routing with Vue.
  NOT for plain Vue SPA without SSR, NOT for React/Next.js, NOT for Nuxt 2.
---

# Nuxt 3 Framework Skill

## Project Structure

Always scaffold with `npx nuxi@latest init <project>`. Canonical directory layout:

```
app.vue                 # Root component (or use pages/)
pages/                  # File-based routing
components/             # Auto-imported Vue components
composables/            # Auto-imported composables (useXxx)
utils/                  # Auto-imported utility functions
layouts/                # Named layouts
middleware/             # Route middleware
plugins/                # App plugins (client/server)
server/
  api/                  # API routes (Nitro)
  middleware/           # Server middleware
  routes/               # Non-API server routes
  utils/                # Server-only utilities
assets/                 # Processed assets (CSS, images)
public/                 # Static assets served at /
content/                # Markdown/YAML for @nuxt/content
nuxt.config.ts          # Framework configuration
app.config.ts           # Runtime app configuration
```

## Auto-Imports

Nuxt auto-imports from `components/`, `composables/`, and `utils/`. Vue APIs (`ref`, `computed`, `watch`) and Nuxt composables (`useFetch`, `useRoute`, `useState`) are available globally.

- Never manually import auto-imported items; it creates duplicates.
- Use `#imports` alias when explicit import is needed (e.g., in non-Nuxt files).
- Configure in `nuxt.config.ts`:

```ts
export default defineNuxtConfig({
  imports: {
    dirs: ['stores'] // add custom auto-import dirs
  },
  components: {
    dirs: ['~/components/ui'] // customize component dirs
  }
})
```

## File-Based Routing

Files in `pages/` become routes automatically. Use `<NuxtPage />` in `app.vue` or layouts.

| File                        | Route              |
|-----------------------------|--------------------|
| `pages/index.vue`           | `/`                |
| `pages/about.vue`           | `/about`           |
| `pages/blog/[slug].vue`     | `/blog/:slug`      |
| `pages/users/[id]/edit.vue` | `/users/:id/edit`  |
| `pages/[...slug].vue`       | Catch-all route    |

```vue
<!-- pages/blog/[slug].vue -->
<script setup lang="ts">
const route = useRoute()
const slug = route.params.slug as string
</script>
```

Use `definePageMeta` for page-level config:

```vue
<script setup lang="ts">
definePageMeta({
  layout: 'admin',
  middleware: ['auth'],
  keepalive: true
})
</script>
```

Navigate with `<NuxtLink to="/about">` (never `<a>` for internal links) or `navigateTo('/path')`.

## Layouts

Define in `layouts/`. Default layout is `layouts/default.vue`. Use `<slot />` for page content.

```vue
<!-- layouts/admin.vue -->
<template>
  <div>
    <AdminSidebar />
    <main><slot /></main>
  </div>
</template>
```

Assign per page: `definePageMeta({ layout: 'admin' })`. Disable: `definePageMeta({ layout: false })`.

## Middleware

Route middleware in `middleware/`. Named middleware applied via `definePageMeta`.

```ts
// middleware/auth.ts
export default defineNuxtRouteMiddleware((to, from) => {
  const user = useAuthUser()
  if (!user.value) {
    return navigateTo('/login')
  }
})
```

Global middleware: suffix with `.global.ts` (e.g., `middleware/log.global.ts`).
Inline middleware: define directly in `definePageMeta({ middleware: [(to, from) => {}] })`.

## Plugins

Run code before app mounts. Place in `plugins/`. Suffix `.client.ts` or `.server.ts` for env-specific.

```ts
// plugins/api.ts
export default defineNuxtPlugin((nuxtApp) => {
  const api = $fetch.create({
    baseURL: '/api',
    onResponseError({ response }) {
      if (response.status === 401) navigateTo('/login')
    }
  })
  return { provide: { api } }
})
```

Access via `const { $api } = useNuxtApp()`.

## Data Fetching

### useFetch — primary composable for API calls

```vue
<script setup lang="ts">
const { data, status, error, refresh } = await useFetch('/api/posts', {
  query: { page: 1 },
  pick: ['id', 'title'],        // reduce payload
  transform: (posts) => posts.map(p => ({ ...p, date: new Date(p.date) })),
  watch: [page],                // refetch on reactive change
  lazy: true,                   // don't block navigation
  server: false                 // client-only fetch
})
</script>
```

### useAsyncData — when not calling a URL directly

```vue
<script setup lang="ts">
const { data: post } = await useAsyncData(
  `post-${slug}`,
  () => queryContent('/blog').where({ slug }).findOne()
)
</script>
```

### $fetch — imperative fetches (event handlers, server routes)

```ts
// In event handlers or server routes only — never in setup (causes double fetch)
async function submitForm() {
  await $fetch('/api/submit', { method: 'POST', body: formData })
}
```

**Rules:**
- Use `useFetch`/`useAsyncData` in `<script setup>` — they deduplicate SSR/client calls.
- Never use bare `$fetch` in component setup — it fires on both server and client.
- Use `lazy: true` for non-critical data to avoid blocking navigation.
- Use `getCachedData` option to implement custom client-side caching.

## Server Routes (Nitro)

File-based API routes in `server/api/`. HTTP method in filename: `posts.get.ts`, `posts.post.ts`.

```ts
// server/api/posts.get.ts
export default defineEventHandler(async (event) => {
  const query = getQuery(event)
  const posts = await db.select().from(postsTable).limit(query.limit ?? 20)
  return posts
})

// server/api/posts.post.ts
export default defineEventHandler(async (event) => {
  const body = await readBody(event)
  const validated = postSchema.parse(body)
  const post = await db.insert(postsTable).values(validated).returning()
  return post
})

// server/api/posts/[id].get.ts
export default defineEventHandler(async (event) => {
  const id = getRouterParam(event, 'id')
  const post = await db.select().from(postsTable).where(eq(postsTable.id, id)).get()
  if (!post) throw createError({ statusCode: 404, statusMessage: 'Post not found' })
  return post
})
```

Server middleware in `server/middleware/`:

```ts
// server/middleware/log.ts
export default defineEventHandler((event) => {
  console.log(`${event.method} ${getRequestURL(event)}`)
})
```

Server utilities in `server/utils/` are auto-imported within server context.

## useState — SSR-Safe Shared State

```ts
// composables/useCounter.ts
export const useCounter = () => useState<number>('counter', () => 0)
```

- SSR-serialized automatically — survives hydration.
- For complex state, use Pinia with `@pinia/nuxt` module.
- Never use plain `ref()` for shared state across components — it leaks between requests in SSR.

## Error Handling

### In server routes

```ts
throw createError({ statusCode: 400, statusMessage: 'Validation failed', data: errors })
```

### In components

```ts
// Trigger full-screen error page
showError({ statusCode: 404, statusMessage: 'Page not found' })

// Clear error and navigate away
clearError({ redirect: '/' })
```

### Error page

```vue
<!-- error.vue (project root) -->
<script setup lang="ts">
const props = defineProps<{ error: { statusCode: number; statusMessage: string } }>()
</script>
<template>
  <div>
    <h1>{{ error.statusCode }}</h1>
    <p>{{ error.statusMessage }}</p>
    <button @click="clearError({ redirect: '/' })">Go Home</button>
  </div>
</template>
```

Use `<NuxtErrorBoundary>` for component-level error isolation.

## SEO — useHead & useSeoMeta

```vue
<script setup lang="ts">
// Reactive, type-safe SEO meta
useSeoMeta({
  title: () => post.value?.title ?? 'My Site',
  description: () => post.value?.excerpt,
  ogTitle: () => post.value?.title,
  ogDescription: () => post.value?.excerpt,
  ogImage: () => post.value?.image,
  twitterCard: 'summary_large_image'
})

// Additional head elements
useHead({
  htmlAttrs: { lang: 'en' },
  link: [{ rel: 'canonical', href: `https://example.com${route.path}` }],
  script: [{
    type: 'application/ld+json',
    innerHTML: JSON.stringify({
      '@context': 'https://schema.org',
      '@type': 'Article',
      headline: post.value?.title
    })
  }]
})
</script>
```

Prefer `useSeoMeta` over manual `useHead` meta arrays — it validates property names and prevents errors.

## Hybrid Rendering — routeRules

Configure per-route rendering in `nuxt.config.ts`:

```ts
export default defineNuxtConfig({
  routeRules: {
    '/':            { prerender: true },              // SSG at build time
    '/blog/**':     { isr: 3600 },                    // ISR: regenerate hourly
    '/api/**':      { cors: true, headers: { 'cache-control': 'no-store' } },
    '/admin/**':    { ssr: false },                    // SPA mode
    '/dashboard':   { swr: 60 },                      // Stale-while-revalidate
    '/old-page':    { redirect: '/new-page' }          // Redirect
  }
})
```

| Mode       | Config                  | Behavior                                    |
|------------|-------------------------|---------------------------------------------|
| SSR        | default                 | Rendered on server per request              |
| SSG        | `prerender: true`       | Pre-rendered at build time                  |
| SPA        | `ssr: false`            | Client-only rendering                       |
| ISR        | `isr: <seconds>`        | Cached static, revalidated on interval      |
| SWR        | `swr: <seconds>`        | Serve stale, revalidate in background       |

Full static site: set `ssr: false` globally or run `npx nuxi generate`.

## Deployment

Nitro auto-detects platform. Override with `nitro.preset`:

```ts
export default defineNuxtConfig({
  nitro: {
    preset: 'vercel'  // 'netlify' | 'cloudflare-pages' | 'cloudflare-module' | 'node-server' | 'bun'
  }
})
```

**Vercel:** Zero-config. Supports SSR, SSG, ISR, edge functions. Push to Git → auto-deployed.
**Netlify:** Use `netlify` preset. Supports SSR via serverless functions, SSG via `nuxi generate`.
**Cloudflare:** Use `cloudflare-pages` or `cloudflare-module` (Workers). Access KV/D1/R2 via `hubKV()`, `hubDatabase()`, `hubBlob()` with NuxtHub module.
**Node:** Use `node-server` preset. Build with `npx nuxi build`, run with `node .output/server/index.mjs`.

Environment variables: use `runtimeConfig` in `nuxt.config.ts`, access via `useRuntimeConfig()`. Prefix public vars with `NUXT_PUBLIC_`.

```ts
export default defineNuxtConfig({
  runtimeConfig: {
    secretKey: '',          // NUXT_SECRET_KEY env var, server-only
    public: {
      apiBase: ''           // NUXT_PUBLIC_API_BASE env var, client+server
    }
  }
})
```

## Modules

Install and register in `nuxt.config.ts`:

```ts
export default defineNuxtConfig({
  modules: [
    '@nuxt/content',    // Markdown/YAML content layer
    '@nuxt/image',      // Optimized images
    '@pinia/nuxt',      // State management
    '@nuxt/ui',         // UI component library
    '@nuxtjs/i18n',     // Internationalization
    '@nuxt/devtools',   // Dev inspector
    '@nuxt/test-utils', // Testing utilities
    '@nuxtseo/module'   // SEO (sitemap, robots, og-image)
  ]
})
```

### Nuxt Content

```vue
<script setup lang="ts">
const { data } = await useAsyncData('blog', () =>
  queryContent('/blog').where({ published: true }).sort({ date: -1 }).limit(10).find()
)
</script>
<template>
  <ContentRenderer :value="data" />
</template>
```

### Nuxt Image

```vue
<NuxtImg src="/hero.jpg" width="800" height="400" format="webp" loading="lazy" alt="Hero" sizes="sm:100vw md:50vw lg:800px" />
<NuxtPicture src="/hero.jpg" format="avif,webp" />
```

## Nuxt DevTools

Enabled by default in dev. Toggle with `Shift+Alt+D`. Provides: component inspector, route visualization, payload viewer, composable state.

## Examples

### Input: "Create a blog with Nuxt Content"

```
content/blog/hello-world.md        # frontmatter: title, date, description
pages/blog/index.vue               # queryContent('/blog').find()
pages/blog/[slug].vue              # queryContent(route.path).findOne()
nuxt.config.ts                     # modules: ['@nuxt/content']
```

Output: SSR blog at `/blog` with individual post pages, auto-generated routes from Markdown.

### Input: "Add auth middleware that protects /dashboard"

```ts
// middleware/auth.ts
export default defineNuxtRouteMiddleware((to) => {
  const { loggedIn } = useUserSession()
  if (!loggedIn.value) return navigateTo('/login')
})
```

```vue
<!-- pages/dashboard.vue -->
<script setup lang="ts">
definePageMeta({ middleware: ['auth'], layout: 'admin' })
const { data } = await useFetch('/api/dashboard/stats')
</script>
```

Output: Unauthenticated users redirected to `/login`. Dashboard loads with server-fetched stats.

### Input: "Deploy to Cloudflare with D1 database"

```ts
// nuxt.config.ts
export default defineNuxtConfig({
  modules: ['nuxthub'],
  hub: { database: true },
  nitro: { preset: 'cloudflare-pages' }
})

// server/api/users.get.ts — access D1 via hubDatabase()
export default defineEventHandler(async () => {
  return await hubDatabase().prepare('SELECT * FROM users').all()
})
```

### Input: "Configure hybrid rendering for marketing + app"

```ts
export default defineNuxtConfig({
  routeRules: {
    '/':           { prerender: true },     // SSG
    '/blog/**':    { isr: 3600 },           // ISR hourly
    '/app/**':     { ssr: false },           // SPA
    '/api/**':     { cors: true }            // CORS
  }
})
```

## Skill Resources

### references/

| File | Contents |
|------|----------|
| [advanced-patterns.md](references/advanced-patterns.md) | Nuxt layers, custom module authoring, Nitro plugins/hooks, runtime config vs app config, server middleware, WebSocket support, caching strategies (routeRules/SWR/prerender/defineCachedEventHandler), Pinia integration patterns |
| [troubleshooting.md](references/troubleshooting.md) | Hydration mismatches (browser APIs, non-deterministic values, third-party libs), auto-import conflicts, composable SSR gotchas (useState vs ref), build errors, module compatibility, Nitro deployment issues, performance debugging |
| [api-reference.md](references/api-reference.md) | Complete composable reference: useFetch, useAsyncData, useState, useRoute, useRouter, useCookie, useRuntimeConfig, useHead, useSeoMeta, useNuxtApp, useRequestHeaders. Lifecycle hooks (app + Vue), nuxt.config.ts full options |

### scripts/

| Script | Usage |
|--------|-------|
| [setup-nuxt.sh](scripts/setup-nuxt.sh) | `./setup-nuxt.sh <name>` — Scaffold Nuxt 3 project with Pinia, ESLint, testing, starter files, directory structure |
| [check-hydration.sh](scripts/check-hydration.sh) | `./check-hydration.sh [dir]` — Static analysis for hydration mismatch risks (browser APIs, bare $fetch, non-serializable useState, module-level refs) |
| [deploy-preset.sh](scripts/deploy-preset.sh) | `./deploy-preset.sh <platform>` — Configure deployment for Vercel, Netlify, Cloudflare Pages, or Node.js (creates config files + Dockerfile) |

### assets/

| Template | Purpose |
|----------|---------|
| [nuxt.config.ts](assets/nuxt.config.ts) | Production-ready config with modules, route rules, runtime config, Nitro, image optimization, TypeScript, environment overrides |
| [server-api-template.ts](assets/server-api-template.ts) | Nitro API route patterns: GET/POST/PUT/DELETE with Zod validation, cached handlers, error handling |
| [composable-template.ts](assets/composable-template.ts) | 5 composable patterns: SSR-safe state, data fetching, client-only (media query), auth with cookies, form with validation |
| [middleware-template.ts](assets/middleware-template.ts) | Auth guard, role-based access, guest-only, global auth init, route validation, server middleware (Nitro JWT) |
| [error-page.vue](assets/error-page.vue) | Custom error.vue with status-aware messages, dark mode, error stack display, styled actions |
<!-- tested: pass -->
