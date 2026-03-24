# Nuxt 3 Advanced Patterns

## Table of Contents
- [Nuxt Layers](#nuxt-layers)
- [Custom Module Authoring](#custom-module-authoring)
- [Nitro Plugins & Hooks](#nitro-plugins--hooks)
- [Runtime Config vs App Config](#runtime-config-vs-app-config)
- [Server Middleware](#server-middleware)
- [WebSocket Support](#websocket-support)
- [Caching Strategies](#caching-strategies)
- [Pinia Integration Patterns](#pinia-integration-patterns)

---

## Nuxt Layers

Layers extend or compose Nuxt applications — share components, composables, pages, config, and server routes across projects. Unlike modules, layers look like normal Nuxt apps.

### Creating a Layer

```
my-layer/
  nuxt.config.ts          # Layer config (merged with consumer)
  components/             # Auto-imported into consumer
  composables/            # Auto-imported into consumer
  pages/                  # Merged with consumer pages
  server/                 # Merged server routes
  assets/
  public/
```

```ts
// my-layer/nuxt.config.ts
export default defineNuxtConfig({
  // Layer-specific config — merged with consumer
})
```

### Consuming Layers

```ts
// nuxt.config.ts (consumer app)
export default defineNuxtConfig({
  extends: [
    './layers/base',                          // Local layer
    'github:org/nuxt-layer#main',             // GitHub remote
    '@my-org/shared-layer',                   // npm package
  ]
})
```

### When to Use Layers vs Modules

| Use Case | Layers | Modules |
|----------|--------|---------|
| Share components/composables/pages | ✅ | ❌ |
| Theming / design system | ✅ | ⚠️ |
| Build-time hooks & Nuxt Kit APIs | ❌ | ✅ |
| Auto-register plugins/middleware programmatically | ❌ | ✅ |
| Third-party integrations (analytics, auth) | ❌ | ✅ |
| Monorepo feature slicing | ✅ | ✅ |

---

## Custom Module Authoring

Modules run at build time and extend Nuxt using `@nuxt/kit` APIs.

### Module Skeleton

```ts
// modules/my-module/index.ts
import { defineNuxtModule, createResolver, addComponent, addImports, addServerHandler } from '@nuxt/kit'

export default defineNuxtModule({
  meta: {
    name: 'my-module',
    configKey: 'myModule',
    compatibility: { nuxt: '>=3.0.0' }
  },
  defaults: {
    enabled: true,
    prefix: 'My'
  },
  setup(options, nuxt) {
    if (!options.enabled) return

    const { resolve } = createResolver(import.meta.url)

    // Add a component
    addComponent({
      name: `${options.prefix}Button`,
      filePath: resolve('runtime/components/Button.vue')
    })

    // Add a composable auto-import
    addImports({
      name: 'useMyFeature',
      from: resolve('runtime/composables/useMyFeature')
    })

    // Add a server API route
    addServerHandler({
      route: '/api/_my-module/health',
      handler: resolve('runtime/server/api/health.get')
    })

    // Hook into Nuxt lifecycle
    nuxt.hook('pages:extend', (pages) => {
      pages.push({
        name: 'my-module-dashboard',
        path: '/my-module',
        file: resolve('runtime/pages/dashboard.vue')
      })
    })
  }
})
```

### Key @nuxt/kit APIs

| API | Purpose |
|-----|---------|
| `addComponent()` | Register component |
| `addImports()` / `addImportsDir()` | Register composables/utils |
| `addServerHandler()` | Add server route/middleware |
| `addPlugin()` | Add client/server plugin |
| `addLayout()` | Add layout |
| `extendPages()` | Modify page routes |
| `addTypeTemplate()` | Generate type declarations |
| `createResolver()` | Resolve module-relative paths |

### Registering a Nitro Plugin from a Module

```ts
setup(options, nuxt) {
  const { resolve } = createResolver(import.meta.url)
  nuxt.hook('nitro:config', (nitroConfig) => {
    nitroConfig.plugins = nitroConfig.plugins || []
    nitroConfig.plugins.push(resolve('runtime/server/plugins/db'))
  })
}
```

---

## Nitro Plugins & Hooks

Nitro plugins run once when the server starts. Place in `server/plugins/`.

### Server Plugin Pattern

```ts
// server/plugins/db.ts
import { consola } from 'consola'

export default defineNitroPlugin((nitroApp) => {
  // Initialize on startup
  const db = createDatabaseConnection()
  consola.success('Database connected')

  // Hook into request lifecycle
  nitroApp.hooks.hook('request', (event) => {
    event.context.db = db
  })

  // Cleanup on close
  nitroApp.hooks.hook('close', async () => {
    await db.close()
  })
})
```

### Key Nitro Hooks

| Hook | When | Use Case |
|------|------|----------|
| `request` | Every incoming request | Attach context, logging |
| `beforeResponse` | Before sending response | Modify headers, transform |
| `afterResponse` | After response sent | Analytics, cleanup |
| `error` | On unhandled error | Error reporting |
| `close` | Server shutdown | Cleanup connections |
| `render:html` | SSR HTML rendering | Inject scripts/styles |
| `render:response` | SSR response ready | Modify full response |

---

## Runtime Config vs App Config

### Runtime Config (`runtimeConfig`)

Server-only secrets + public client vars. Overridden by env vars at runtime.

```ts
// nuxt.config.ts
export default defineNuxtConfig({
  runtimeConfig: {
    dbUrl: '',                    // NUXT_DB_URL — server only
    apiSecret: '',                // NUXT_API_SECRET — server only
    public: {
      apiBase: '/api',            // NUXT_PUBLIC_API_BASE — client + server
      appName: 'My App'           // NUXT_PUBLIC_APP_NAME — client + server
    }
  }
})
```

```ts
// In server routes
const config = useRuntimeConfig()
config.dbUrl        // ✅ server-only value
config.public.apiBase // ✅ public value

// In components
const config = useRuntimeConfig()
config.public.apiBase // ✅ public value
config.dbUrl          // ❌ undefined on client
```

### App Config (`app.config.ts`)

Build-time, reactive, HMR-supported, fully public. For theming, feature flags, UI settings.

```ts
// app.config.ts
export default defineAppConfig({
  ui: {
    primary: 'blue',
    rounded: 'lg'
  },
  featureFlags: {
    newDashboard: true
  }
})
```

```ts
// Anywhere (client + server)
const appConfig = useAppConfig()
appConfig.ui.primary // 'blue' — reactive, updates with HMR
```

### Decision Matrix

| Need | Use |
|------|-----|
| API keys, DB URLs, secrets | `runtimeConfig` (server) |
| Public API base URL, env-dependent | `runtimeConfig.public` |
| Theme colors, feature flags, UI config | `app.config.ts` |
| Values that change per deployment | `runtimeConfig` + env vars |
| Values baked at build time | `app.config.ts` |

---

## Server Middleware

Runs on every server request before route handlers. Place in `server/middleware/`.

```ts
// server/middleware/auth.ts
export default defineEventHandler((event) => {
  const url = getRequestURL(event)

  // Skip non-API routes
  if (!url.pathname.startsWith('/api/')) return

  const token = getHeader(event, 'authorization')?.replace('Bearer ', '')
  if (!token) {
    throw createError({ statusCode: 401, statusMessage: 'Unauthorized' })
  }

  // Attach user to context for downstream handlers
  event.context.user = verifyToken(token)
})
```

```ts
// server/middleware/cors.ts
export default defineEventHandler((event) => {
  setResponseHeaders(event, {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, Authorization',
  })
  if (event.method === 'OPTIONS') {
    event.node.res.statusCode = 204
    event.node.res.end()
  }
})
```

---

## WebSocket Support

Nitro has built-in WebSocket support via CrossWS.

### Enable WebSocket

```ts
// nuxt.config.ts
export default defineNuxtConfig({
  nitro: {
    experimental: {
      websocket: true
    }
  }
})
```

### WebSocket Server Route

```ts
// server/routes/_ws.ts
export default defineWebSocketHandler({
  open(peer) {
    console.log(`[ws] Connected: ${peer}`)
    peer.send(JSON.stringify({ type: 'welcome', message: 'Connected!' }))
  },
  message(peer, message) {
    const data = JSON.parse(message.text())
    // Broadcast to all peers
    peer.publish('chat', JSON.stringify({ user: data.user, text: data.text }))
    peer.subscribe('chat')
  },
  close(peer) {
    console.log(`[ws] Disconnected: ${peer}`)
  },
  error(peer, error) {
    console.error(`[ws] Error:`, error)
  }
})
```

### Client-Side Connection

```ts
// composables/useWebSocket.ts
export const useWebSocket = () => {
  const ws = ref<WebSocket | null>(null)
  const messages = ref<any[]>([])

  const connect = () => {
    if (import.meta.server) return
    const protocol = location.protocol === 'https:' ? 'wss:' : 'ws:'
    ws.value = new WebSocket(`${protocol}//${location.host}/_ws`)
    ws.value.onmessage = (event) => {
      messages.value.push(JSON.parse(event.data))
    }
  }

  const send = (data: any) => {
    ws.value?.send(JSON.stringify(data))
  }

  onMounted(connect)
  onUnmounted(() => ws.value?.close())

  return { messages, send }
}
```

---

## Caching Strategies

### Route Rules (nuxt.config.ts)

```ts
export default defineNuxtConfig({
  routeRules: {
    // SSG — pre-rendered at build time
    '/':              { prerender: true },
    '/about':         { prerender: true },

    // ISR — cached, revalidated on interval
    '/blog/**':       { isr: 3600 },          // 1 hour

    // SWR — serve stale, revalidate in background
    '/products/**':   { swr: 60 },            // 60s stale window

    // SPA — client-only rendering
    '/admin/**':      { ssr: false },

    // API caching
    '/api/public/**': { cache: { maxAge: 300 } },

    // CDN headers
    '/assets/**':     { headers: { 'cache-control': 'public, max-age=31536000, immutable' } }
  }
})
```

### useFetch Caching with getCachedData

```ts
const { data } = await useFetch('/api/posts', {
  key: 'posts-list',
  getCachedData(key, nuxtApp) {
    // Return cached data if available and fresh
    return nuxtApp.payload.data[key] || nuxtApp.static.data[key]
  }
})
```

### Nitro Storage Cache

```ts
// server/api/expensive.get.ts
export default defineCachedEventHandler(async (event) => {
  // This result is cached
  const data = await expensiveOperation()
  return data
}, {
  maxAge: 60 * 60,       // Cache 1 hour
  staleMaxAge: 60 * 60 * 24, // Serve stale up to 24h
  swr: true,              // Revalidate in background
  name: 'expensive-data',
  getKey: (event) => getQuery(event).id as string
})
```

### Prerendering Specific Routes

```ts
// nuxt.config.ts
export default defineNuxtConfig({
  nitro: {
    prerender: {
      routes: ['/sitemap.xml', '/robots.txt'],
      crawlLinks: true     // Auto-discover links to prerender
    }
  }
})
```

---

## Pinia Integration Patterns

### Setup

```ts
// nuxt.config.ts
export default defineNuxtConfig({
  modules: ['@pinia/nuxt'],
  pinia: {
    storesDirs: ['./stores/**']   // Auto-import stores
  }
})
```

### Setup Store Pattern (Recommended)

```ts
// stores/auth.ts
export const useAuthStore = defineStore('auth', () => {
  const user = ref<User | null>(null)
  const isLoggedIn = computed(() => !!user.value)

  async function login(credentials: { email: string; password: string }) {
    user.value = await $fetch('/api/auth/login', {
      method: 'POST',
      body: credentials
    })
  }

  async function logout() {
    await $fetch('/api/auth/logout', { method: 'POST' })
    user.value = null
  }

  return { user, isLoggedIn, login, logout }
})
```

### SSR-Safe Store Hydration

```vue
<script setup lang="ts">
const authStore = useAuthStore()

// Fetch during SSR, hydrate on client — use callOnce to avoid refetch
await callOnce('auth-init', async () => {
  await authStore.fetchCurrentUser()
})
</script>
```

### Using storeToRefs for Reactivity

```vue
<script setup lang="ts">
import { storeToRefs } from 'pinia'

const authStore = useAuthStore()
const { user, isLoggedIn } = storeToRefs(authStore) // Reactive refs
const { login, logout } = authStore                  // Actions (not refs)
</script>
```

### Persisted State

```ts
// plugins/pinia-persist.client.ts
import piniaPersistedstate from 'pinia-plugin-persistedstate'

export default defineNuxtPlugin(({ $pinia }) => {
  $pinia.use(piniaPersistedstate)
})
```

```ts
// stores/preferences.ts
export const usePreferencesStore = defineStore('preferences', () => {
  const theme = ref<'light' | 'dark'>('light')
  const locale = ref('en')
  return { theme, locale }
}, {
  persist: {
    storage: piniaPluginPersistedstate.cookies(), // SSR-safe
  }
})
```

### Key Pinia + Nuxt Rules

1. **Never initialize store state with browser APIs** (`localStorage`, `window`) — breaks SSR
2. **Use `storeToRefs()`** for destructuring reactive state — plain destructuring loses reactivity
3. **Use `callOnce()` or `useAsyncData()`** for SSR data fetching in stores
4. **Place stores in `/stores`** directory for auto-import
5. **Prefer setup store syntax** for Composition API alignment and better TypeScript inference
