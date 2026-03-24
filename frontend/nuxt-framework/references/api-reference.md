# Nuxt 3 API Reference

## Table of Contents
- [Data Fetching Composables](#data-fetching-composables)
- [State Composables](#state-composables)
- [Routing Composables](#routing-composables)
- [Head & SEO Composables](#head--seo-composables)
- [App & Config Composables](#app--config-composables)
- [Utility Composables](#utility-composables)
- [Lifecycle Hooks](#lifecycle-hooks)
- [nuxt.config.ts Reference](#nuxtconfigts-reference)

---

## Data Fetching Composables

### useFetch

Primary composable for URL-based data fetching with SSR deduplication.

```ts
const {
  data,       // Ref<T | null> — response data
  status,     // Ref<'idle' | 'pending' | 'success' | 'error'>
  error,      // Ref<Error | null>
  refresh,    // () => Promise<void> — re-execute
  execute,    // () => Promise<void> — same as refresh
  clear,      // () => void — reset data to default
} = await useFetch<T>(url, options?)
```

**Options:**

| Option | Type | Description |
|--------|------|-------------|
| `method` | `string` | HTTP method (GET, POST, etc.) |
| `query` | `object \| Ref` | Query parameters (reactive) |
| `body` | `any` | Request body (POST/PUT/PATCH) |
| `headers` | `object` | Request headers |
| `baseURL` | `string` | Base URL for request |
| `key` | `string` | Unique key for deduplication (auto-generated from URL) |
| `server` | `boolean` | Fetch on server (default: `true`) |
| `lazy` | `boolean` | Don't block navigation (default: `false`) |
| `immediate` | `boolean` | Fetch immediately (default: `true`) |
| `default` | `() => T` | Factory for default data value |
| `transform` | `(data) => T` | Transform response data |
| `pick` | `string[]` | Pick specific keys from response |
| `watch` | `WatchSource[]` | Reactive sources that trigger refetch |
| `deep` | `boolean` | Deep reactive data (default: `true`) |
| `dedupe` | `'cancel' \| 'defer'` | Deduplication strategy |
| `timeout` | `number` | Request timeout in ms |
| `getCachedData` | `(key, nuxtApp) => T` | Custom cache lookup |
| `onRequest` | `(ctx) => void` | Request interceptor |
| `onResponse` | `(ctx) => void` | Response interceptor |
| `onRequestError` | `(ctx) => void` | Request error interceptor |
| `onResponseError` | `(ctx) => void` | Response error interceptor |

**Examples:**

```ts
// Basic GET
const { data: posts } = await useFetch('/api/posts')

// POST with body
const { data } = await useFetch('/api/posts', {
  method: 'POST',
  body: { title: 'New Post' }
})

// Reactive query params
const page = ref(1)
const { data: items } = await useFetch('/api/items', {
  query: { page, limit: 20 },
  watch: [page]
})

// Transform and pick
const { data: names } = await useFetch('/api/users', {
  transform: (users) => users.map(u => u.name),
})

// Lazy fetch (non-blocking)
const { data, status } = useFetch('/api/heavy', { lazy: true })

// Client-only fetch
const { data } = useFetch('/api/client-data', { server: false })

// Custom caching
const { data } = await useFetch('/api/posts', {
  getCachedData(key, nuxtApp) {
    if (nuxtApp.isHydrating && nuxtApp.payload.data[key]) {
      return nuxtApp.payload.data[key]
    }
    return null // Fetch fresh
  }
})
```

### useAsyncData

General-purpose async data wrapper. Use when not directly calling a URL.

```ts
const {
  data, status, error, refresh, execute, clear
} = await useAsyncData<T>(key, handler, options?)
```

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `key` | `string` | Unique key for deduplication and caching |
| `handler` | `() => Promise<T>` | Async function returning data |
| `options` | `object` | Same as useFetch (minus HTTP options) |

```ts
// Fetch from SDK/ORM
const { data: post } = await useAsyncData(
  `post-${id}`,
  () => queryContent('/blog').where({ id }).findOne()
)

// Multiple async sources
const { data } = await useAsyncData('dashboard', async () => {
  const [stats, users] = await Promise.all([
    $fetch('/api/stats'),
    $fetch('/api/users')
  ])
  return { stats, users }
})
```

### useLazyFetch / useLazyAsyncData

Non-blocking variants — identical to `lazy: true` option.

```ts
// These are equivalent:
const { data } = useLazyFetch('/api/data')
const { data } = useFetch('/api/data', { lazy: true })
```

### useNuxtData

Access cached data from other `useFetch`/`useAsyncData` calls by key.

```ts
const { data: cachedPosts } = useNuxtData('posts')
```

### refreshNuxtData

Globally refresh data by key or all.

```ts
await refreshNuxtData('posts')      // Refresh specific key
await refreshNuxtData()              // Refresh all
```

---

## State Composables

### useState

SSR-safe reactive state shared across components.

```ts
const state = useState<T>(key, init?)
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `key` | `string` | Unique key (scoped per request in SSR) |
| `init` | `() => T` | Factory function for initial value |

```ts
// Simple counter
const count = useState('count', () => 0)
count.value++

// Complex state
const user = useState<User | null>('current-user', () => null)

// In composable
export const useTheme = () => useState<'light' | 'dark'>('theme', () => 'light')
```

**Rules:**
- Values must be JSON serializable (no functions, classes, Symbols, Maps, Sets)
- Init function runs once on server, result hydrated on client
- Same key across components shares the same state instance

### clearNuxtState

Clear specific or all useState values.

```ts
clearNuxtState('count')    // Clear specific
clearNuxtState()           // Clear all
```

---

## Routing Composables

### useRoute

Access current route info (reactive).

```ts
const route = useRoute()
```

| Property | Type | Description |
|----------|------|-------------|
| `route.path` | `string` | Current path (`/blog/hello`) |
| `route.params` | `object` | Route params (`{ slug: 'hello' }`) |
| `route.query` | `object` | Query string (`{ page: '1' }`) |
| `route.hash` | `string` | URL hash (`#section`) |
| `route.name` | `string` | Route name |
| `route.fullPath` | `string` | Full URL with query and hash |
| `route.meta` | `object` | Route meta from `definePageMeta` |
| `route.matched` | `array` | Matched route records |

### useRouter

Programmatic navigation and router instance.

```ts
const router = useRouter()
```

| Method | Description |
|--------|-------------|
| `router.push(path)` | Navigate to path (adds history entry) |
| `router.replace(path)` | Navigate without history entry |
| `router.back()` | Go back |
| `router.forward()` | Go forward |
| `router.go(n)` | Go n steps in history |
| `router.beforeEach(guard)` | Global navigation guard |
| `router.afterEach(hook)` | Post-navigation hook |

```ts
// Programmatic navigation
await navigateTo('/login')                    // Recommended helper
await navigateTo('/login', { replace: true }) // No history entry
await navigateTo({ path: '/user', query: { id: '1' } })
await navigateTo('https://external.com', { external: true })
```

### useLocalePath / useLocaleRoute (with @nuxtjs/i18n)

```ts
const localePath = useLocalePath()
navigateTo(localePath('/about')) // /fr/about (if French locale)
```

---

## Head & SEO Composables

### useHead

Full control over document `<head>`.

```ts
useHead({
  title: 'Page Title',
  titleTemplate: '%s - My Site',
  htmlAttrs: { lang: 'en', dir: 'ltr' },
  bodyAttrs: { class: 'dark' },
  meta: [
    { name: 'description', content: 'Page description' },
    { property: 'og:title', content: 'OG Title' },
    { name: 'robots', content: 'index, follow' }
  ],
  link: [
    { rel: 'canonical', href: 'https://example.com/page' },
    { rel: 'icon', type: 'image/png', href: '/favicon.png' },
    { rel: 'stylesheet', href: 'https://fonts.googleapis.com/css2?family=Inter' }
  ],
  script: [
    { src: 'https://analytics.example.com/script.js', defer: true },
    { type: 'application/ld+json', innerHTML: JSON.stringify(structuredData) }
  ],
  noscript: [
    { innerHTML: 'This site requires JavaScript' }
  ]
})
```

All properties accept reactive values (refs, computed, functions).

### useSeoMeta

Type-safe SEO meta tags — validates property names at build time.

```ts
useSeoMeta({
  title: 'My Page',
  description: 'Page description for search engines',
  ogTitle: 'Open Graph Title',
  ogDescription: 'OG Description',
  ogImage: 'https://example.com/og.jpg',
  ogUrl: 'https://example.com/page',
  ogType: 'article',
  ogSiteName: 'My Site',
  twitterCard: 'summary_large_image',
  twitterTitle: 'Twitter Title',
  twitterDescription: 'Twitter Description',
  twitterImage: 'https://example.com/twitter.jpg',
  twitterSite: '@myhandle',
  robots: 'index, follow',
  author: 'Author Name',
  colorScheme: 'light dark',
  themeColor: '#ffffff'
})
```

### useServerSeoMeta

Same as `useSeoMeta` but only runs on server (no client-side overhead).

```ts
useServerSeoMeta({
  robots: 'index, follow',
  ogImage: 'https://example.com/og.jpg'
})
```

---

## App & Config Composables

### useRuntimeConfig

Access runtime configuration (env vars).

```ts
const config = useRuntimeConfig()

// Server-side (api routes, server middleware, plugins)
config.dbUrl           // Server-only secret
config.public.apiBase  // Public value

// Client-side (components, client plugins)
config.public.apiBase  // Only public values accessible
```

### useAppConfig

Access app.config.ts values (reactive, HMR-supported).

```ts
const appConfig = useAppConfig()
appConfig.ui.primary   // 'blue'
appConfig.theme        // 'dark'
```

### useNuxtApp

Access the Nuxt app instance — plugins, payload, hooks.

```ts
const nuxtApp = useNuxtApp()
```

| Property | Description |
|----------|-------------|
| `nuxtApp.payload` | SSR payload data |
| `nuxtApp.hook(name, fn)` | Register lifecycle hook |
| `nuxtApp.callHook(name)` | Trigger lifecycle hook |
| `nuxtApp.provide(key, value)` | Inject value (from plugins) |
| `nuxtApp.$myPlugin` | Access plugin-provided values |
| `nuxtApp.isHydrating` | Currently hydrating from SSR |
| `nuxtApp.runWithContext(fn)` | Run function with Nuxt context |

```ts
// Access plugin-provided value
const { $api } = useNuxtApp()
await $api('/endpoint')

// Check if hydrating
if (nuxtApp.isHydrating) {
  // Use payload data instead of fetching
}
```

### useRequestEvent (Server Only)

Access the underlying H3 event in SSR context.

```ts
const event = useRequestEvent()
const ip = getRequestIP(event)
```

### useRequestHeaders

Access incoming request headers (SSR).

```ts
const headers = useRequestHeaders(['cookie', 'user-agent'])
// Forward cookies to API calls
const { data } = await useFetch('/api/me', { headers })
```

---

## Utility Composables

### useCookie

Universal cookie management (SSR + client).

```ts
const token = useCookie<string>('auth-token', {
  maxAge: 60 * 60 * 24 * 7,  // 7 days
  secure: true,
  httpOnly: false,             // Must be false for client access
  sameSite: 'lax',
  path: '/',
  default: () => ''
})

token.value = 'new-token'     // Sets cookie
token.value = null             // Deletes cookie
```

### useError

Access the current Nuxt error.

```ts
const error = useError()
// error.value?.statusCode, error.value?.statusMessage
```

### createError / showError / clearError

```ts
// In server routes — throw HTTP error
throw createError({
  statusCode: 404,
  statusMessage: 'Not Found',
  data: { details: 'Resource missing' }
})

// In components — show full-screen error page
showError({ statusCode: 500, statusMessage: 'Something broke' })

// Clear error and optionally redirect
clearError({ redirect: '/' })
```

### definePageMeta

Set page-level metadata (layout, middleware, keepalive, etc.).

```ts
definePageMeta({
  layout: 'admin',
  middleware: ['auth'],
  keepalive: true,
  pageTransition: { name: 'slide' },
  validate: async (route) => {
    return /^\d+$/.test(route.params.id as string)
  }
})
```

### defineNuxtRouteMiddleware

Define route middleware.

```ts
export default defineNuxtRouteMiddleware((to, from) => {
  // Return nothing to continue
  // Return navigateTo() to redirect
  // Return abortNavigation() to cancel
})
```

---

## Lifecycle Hooks

### App Hooks (via useNuxtApp or plugins)

| Hook | When | Use |
|------|------|-----|
| `app:created` | Vue app created | Early setup |
| `app:beforeMount` | Before app mounts | Pre-mount logic |
| `app:mounted` | App mounted | Client-only init |
| `app:error` | Fatal error | Error reporting |
| `app:error:cleared` | Error cleared | Recovery |
| `page:start` | Page navigation starts | Loading indicators |
| `page:finish` | Page navigation ends | Analytics, scroll |
| `page:transition:finish` | Page transition done | Post-transition |
| `link:prefetch` | Link prefetch triggered | Preload data |

```ts
// In plugin
export default defineNuxtPlugin((nuxtApp) => {
  nuxtApp.hook('page:finish', () => {
    // Track page view
  })
  nuxtApp.hook('app:error', (error) => {
    // Report to error tracking service
  })
})
```

### Vue Lifecycle (in setup)

| Hook | SSR | Client | Use |
|------|-----|--------|-----|
| `onBeforeMount` | ❌ | ✅ | Before DOM mount |
| `onMounted` | ❌ | ✅ | DOM ready, browser APIs |
| `onBeforeUpdate` | ❌ | ✅ | Before re-render |
| `onUpdated` | ❌ | ✅ | After re-render |
| `onBeforeUnmount` | ❌ | ✅ | Cleanup before destroy |
| `onUnmounted` | ❌ | ✅ | Final cleanup |
| `onServerPrefetch` | ✅ | ❌ | Server-only data fetch |

---

## nuxt.config.ts Reference

### Core Options

```ts
export default defineNuxtConfig({
  // Rendering
  ssr: true,                          // Enable SSR (default: true)
  compatibilityDate: '2024-11-01',    // API compatibility target

  // App
  app: {
    baseURL: '/',                     // Base URL
    head: {                           // Global <head> defaults
      title: 'My App',
      meta: [{ charset: 'utf-8' }, { name: 'viewport', content: 'width=device-width, initial-scale=1' }],
      link: [],
      script: []
    },
    pageTransition: { name: 'page', mode: 'out-in' },
    layoutTransition: { name: 'layout', mode: 'out-in' }
  },

  // Modules
  modules: [],

  // CSS
  css: ['~/assets/css/main.css'],

  // Runtime Config
  runtimeConfig: {
    secretKey: '',
    public: { apiBase: '' }
  },

  // Route Rules
  routeRules: {
    '/': { prerender: true },
    '/api/**': { cors: true }
  },

  // Auto-Imports
  imports: {
    dirs: ['stores'],
    imports: [{ name: 'default', as: 'axios', from: 'axios' }]
  },

  // Components
  components: {
    dirs: ['~/components']
  },

  // Build
  build: {
    transpile: []
  },

  // Vite
  vite: {
    css: { preprocessorOptions: { scss: { additionalData: '@use "~/assets/scss/vars" as *;' } } },
    plugins: []
  },

  // Nitro (Server)
  nitro: {
    preset: 'node-server',
    compressPublicAssets: true,
    prerender: { routes: ['/sitemap.xml'], crawlLinks: true },
    storage: {},
    routeRules: {}
  },

  // DevTools
  devtools: { enabled: true },

  // TypeScript
  typescript: {
    strict: true,
    typeCheck: true
  },

  // Experimental
  experimental: {
    payloadExtraction: true,
    asyncContext: true,
    typedPages: true
  },

  // Environment overrides
  $development: { devtools: { enabled: true } },
  $production: { devtools: { enabled: false } }
})
```
