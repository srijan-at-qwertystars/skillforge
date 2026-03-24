# Nuxt 3 Troubleshooting Guide

## Table of Contents
- [Hydration Mismatches](#hydration-mismatches)
- [Auto-Import Conflicts](#auto-import-conflicts)
- [Composable SSR Gotchas](#composable-ssr-gotchas)
- [Build Errors](#build-errors)
- [Module Compatibility](#module-compatibility)
- [Nitro Deployment Issues](#nitro-deployment-issues)
- [Performance Issues](#performance-issues)
- [Common Runtime Errors](#common-runtime-errors)

---

## Hydration Mismatches

### Symptom
`[Vue warn]: Hydration text/node mismatch` — server-rendered HTML differs from client-rendered DOM.

### Cause 1: Browser-Only APIs in Setup

```vue
<!-- ❌ BAD — window/document undefined on server -->
<script setup>
const width = ref(window.innerWidth)
const theme = ref(localStorage.getItem('theme'))
</script>

<!-- ✅ FIX — defer to client -->
<script setup>
const width = ref(0)
const theme = ref('light')

onMounted(() => {
  width.value = window.innerWidth
  theme.value = localStorage.getItem('theme') || 'light'
})
</script>
```

### Cause 2: Non-Deterministic Values

```vue
<!-- ❌ BAD — different value on server vs client -->
<template>
  <span>{{ Math.random() }}</span>
  <span>{{ new Date().toLocaleTimeString() }}</span>
  <span>{{ crypto.randomUUID() }}</span>
</template>

<!-- ✅ FIX — generate on client only or use useState -->
<script setup>
const id = useState('unique-id', () => crypto.randomUUID()) // SSR-safe, generated once
const time = ref('')
onMounted(() => { time.value = new Date().toLocaleTimeString() })
</script>
```

### Cause 3: Third-Party Libraries Manipulating DOM

```vue
<!-- ❌ BAD — library expects browser DOM -->
<script setup>
import SomeChartLib from 'chart-lib'
const chart = new SomeChartLib('#chart') // Fails on server
</script>

<!-- ✅ FIX — use ClientOnly or lazy import -->
<template>
  <ClientOnly>
    <LazyChartComponent :data="chartData" />
    <template #fallback>
      <div class="skeleton-chart" />
    </template>
  </ClientOnly>
</template>
```

### Cause 4: Conditional Rendering Based on Client State

```vue
<!-- ❌ BAD — server doesn't know screen size -->
<template>
  <MobileNav v-if="isMobile" />
  <DesktopNav v-else />
</template>

<!-- ✅ FIX — use CSS media queries or defer detection -->
<script setup>
const isMobile = ref(false)
onMounted(() => {
  isMobile.value = window.innerWidth < 768
})
</script>
<template>
  <MobileNav v-if="isMobile" />
  <DesktopNav v-else />
</template>
```

### Quick Diagnosis

```bash
# In browser devtools console, check for hydration warnings
# Look for: "[Vue warn]: Hydration"
# The warning includes the mismatched element/text

# In nuxt.config.ts, enable debug:
export default defineNuxtConfig({
  debug: true  // Extra logging for hydration issues
})
```

---

## Auto-Import Conflicts

### Symptom
Wrong function called, TypeScript errors about ambiguous imports, or unexpected behavior from composables.

### Cause 1: Name Collision Between Custom and Library Composables

```ts
// composables/useAuth.ts — your custom composable
export const useAuth = () => { /* ... */ }

// A module also provides useAuth — CONFLICT
```

**Fix:** Rename your composable, or disable auto-import for the conflicting module:

```ts
// nuxt.config.ts
export default defineNuxtConfig({
  imports: {
    // Exclude specific auto-imports
    exclude: ['useAuth']
  }
})
```

### Cause 2: Duplicate Exports from composables/ and utils/

```ts
// composables/format.ts
export const formatDate = (d: Date) => d.toISOString()

// utils/format.ts
export const formatDate = (d: Date) => d.toLocaleDateString() // CONFLICT!
```

**Fix:** Use unique names or consolidate into one file.

### Cause 3: Components from Multiple Directories

```ts
// components/Button.vue AND components/ui/Button.vue — which one wins?
```

**Fix:** Use `pathPrefix` to namespace:

```ts
// nuxt.config.ts
export default defineNuxtConfig({
  components: [
    { path: '~/components/ui', prefix: 'Ui' }  // <UiButton />
  ]
})
```

### Debugging Auto-Imports

```bash
# See all auto-imported items:
npx nuxi info

# Check .nuxt/imports.d.ts for the resolved auto-imports
cat .nuxt/imports.d.ts

# Check .nuxt/components.d.ts for component resolution
cat .nuxt/components.d.ts
```

---

## Composable SSR Gotchas

### useState vs ref — The Critical Difference

```ts
// ❌ DANGEROUS — plain ref leaks state between SSR requests
// In SSR, module-level refs are SHARED across all users
const globalCounter = ref(0) // Shared across all requests!

// ✅ SAFE — useState is request-scoped in SSR
export const useCounter = () => useState<number>('counter', () => 0)
```

**Rule:** Never use module-level `ref()` for shared state. Always use `useState()` or Pinia stores in SSR contexts.

### Composable Timing — Setup Context Required

```ts
// ❌ BAD — composables called outside setup context
setTimeout(() => {
  const route = useRoute() // ERROR: nuxt instance not available
}, 1000)

// ✅ GOOD — call in setup, store the result
const route = useRoute()
setTimeout(() => {
  console.log(route.path) // Use the already-resolved ref
}, 1000)
```

### useFetch in Wrong Context

```ts
// ❌ BAD — $fetch in setup causes double-fetch (SSR + client)
const data = ref(null)
data.value = await $fetch('/api/data')

// ✅ GOOD — useFetch deduplicates SSR/client
const { data } = await useFetch('/api/data')
```

### useCookie — Serialization Pitfall

```ts
// ❌ BAD — non-serializable value
const cookie = useCookie('user')
cookie.value = { name: 'John', handler: () => {} } // Functions not serializable!

// ✅ GOOD — JSON-serializable only
cookie.value = { name: 'John', role: 'admin' }
```

### watch() Not Firing on SSR

```ts
// watch() only fires on client by default during hydration
// If you need server-side watch, use computed or direct logic
const route = useRoute()
const data = await useFetch('/api/items', {
  query: { category: route.query.category },
  watch: [() => route.query.category] // Refetches reactively on client
})
```

---

## Build Errors

### ERROR: "Cannot find module '#imports'"

**Cause:** `.nuxt` directory is stale or missing.

```bash
rm -rf .nuxt .output node_modules/.cache
npx nuxi prepare
npx nuxi build
```

### ERROR: "Pre-transform error" / Vite Transform Errors

**Cause:** Incompatible dependency or ESM/CJS mix.

```ts
// nuxt.config.ts — force transpile problematic package
export default defineNuxtConfig({
  build: {
    transpile: ['problematic-package']
  }
})
```

### ERROR: "RollupError: Could not resolve..."

**Cause:** Package uses Node.js built-ins not available in target env.

```ts
// nuxt.config.ts
export default defineNuxtConfig({
  vite: {
    resolve: {
      alias: {
        // Polyfill or stub missing modules
      }
    }
  },
  nitro: {
    // For server-side, make external
    externals: {
      inline: ['problematic-package']
    }
  }
})
```

### ERROR: "'X' is not exported from '#imports'"

**Cause:** Auto-import not recognized after adding new composable.

```bash
npx nuxi cleanup   # Remove .nuxt, .output
npx nuxi prepare   # Regenerate types
# Restart dev server
```

### ERROR: TypeScript Errors in .vue Files

```bash
# Regenerate auto-import types
npx nuxi typecheck
# If persists, check tsconfig.json extends .nuxt/tsconfig.json
```

### ERROR: "Cannot access '_sharedRuntimeConfig' before initialization"

**Cause:** Nitro version mismatch. Pin versions:

```json
{
  "overrides": {
    "nitropack": "2.9.x"
  }
}
```

---

## Module Compatibility

### Check Module Compatibility

```bash
# List installed modules and their Nuxt version compatibility
npx nuxi info

# Check module's package.json for:
# "nuxt": { "compatibility": { "nuxt": ">=3.0.0" } }
```

### Common Module Issues

| Module | Issue | Fix |
|--------|-------|-----|
| `@nuxtjs/axios` | Nuxt 2 only | Use `useFetch` / `$fetch` |
| `@nuxtjs/auth` | Nuxt 2 only | Use `sidebase/nuxt-auth` or `@nuxt/auth-utils` |
| `@nuxtjs/pwa` | Nuxt 2 only | Use `@vite-pwa/nuxt` |
| `@nuxtjs/vuetify` | Nuxt 2 only | Use `vuetify-nuxt-module` |
| `@nuxtjs/composition-api` | Nuxt 2 only | Built into Nuxt 3 |
| `@nuxt/bridge` | Migration tool | Remove after full Nuxt 3 migration |

### Forcing Transpilation for CJS Modules

```ts
// nuxt.config.ts
export default defineNuxtConfig({
  build: {
    transpile: [
      'legacy-cjs-module',
      /some-regex-pattern/
    ]
  }
})
```

---

## Nitro Deployment Issues

### .output Directory Empty After Build

```bash
# Use nuxi CLI (not bare nuxt command)
npx nuxi build

# Clean first if stale
rm -rf .nuxt .output
npx nuxi build

# Verify output exists
ls -la .output/server/index.mjs
```

### Cloudflare Workers: Node.js API Errors

```ts
// nuxt.config.ts
export default defineNuxtConfig({
  nitro: {
    preset: 'cloudflare-pages',
    // Enable Node.js compat for Workers
    cloudflare: {
      pages: {
        routes: { exclude: ['/api/*'] }
      }
    }
  }
})
```

Also set in `wrangler.toml`:
```toml
compatibility_flags = ["nodejs_compat"]
```

### Vercel: Function Size Too Large

```ts
// nuxt.config.ts — split server into smaller functions
export default defineNuxtConfig({
  nitro: {
    preset: 'vercel',
    vercel: {
      functions: {
        maxDuration: 30
      }
    }
  }
})
```

Reduce bundle: externalize large deps, use dynamic imports, check `.output/server` size.

### Netlify: 500 Errors on SSR Routes

```bash
# Ensure using correct preset
# nuxt.config.ts: nitro.preset = 'netlify'

# Check Netlify function logs
netlify functions:log

# Ensure node version matches
# netlify.toml
[build]
  command = "npx nuxi build"
  publish = ".output/public"
  NODE_VERSION = "20"
```

### Environment Variables Not Loading

```bash
# Nuxt runtime config env vars MUST be prefixed:
# Server-only: NUXT_<KEY> (e.g., NUXT_DB_URL)
# Public: NUXT_PUBLIC_<KEY> (e.g., NUXT_PUBLIC_API_BASE)

# ❌ Wrong: API_KEY=xxx (not picked up)
# ✅ Right: NUXT_API_KEY=xxx (maps to runtimeConfig.apiKey)
```

---

## Performance Issues

### Slow Dev Server Startup

```ts
// nuxt.config.ts
export default defineNuxtConfig({
  // Reduce modules in dev
  $development: {
    modules: [] // Remove heavy modules in dev if not needed
  },
  vite: {
    optimizeDeps: {
      include: ['vue', 'vue-router'] // Pre-bundle common deps
    }
  }
})
```

### Large Client Bundle

```bash
# Analyze bundle
npx nuxi analyze

# Common fixes:
# 1. Use dynamic imports: const Component = defineAsyncComponent(() => import('./Heavy.vue'))
# 2. Set heavy pages to client-only: routeRules: { '/heavy': { ssr: false } }
# 3. Use tree-shakeable imports: import { specific } from 'large-lib'
```

---

## Common Runtime Errors

### "Nuxt instance is not available"

**Cause:** Composable called outside `<script setup>`, plugin `setup()`, or middleware.

```ts
// ❌ Cannot use composables in:
// - setTimeout/setInterval callbacks
// - Promise .then() chains
// - Event listeners registered after setup

// ✅ Capture the composable result in setup, use the ref later
```

### "useState key already exists with different value"

**Cause:** Conflicting `useState` keys across components.

```ts
// ❌ Two components using same key with different defaults
useState('data', () => [])        // Component A
useState('data', () => 'string')  // Component B — conflict!

// ✅ Use unique, descriptive keys
useState('user-list-data', () => [])
useState('dashboard-summary', () => 'string')
```

### "$fetch is not a function" in Server Routes

**Cause:** Using client `$fetch` syntax in Nitro handlers.

```ts
// ❌ In server routes, $fetch is from ofetch, not Nuxt
import { $fetch } from 'ofetch' // Explicit import in server context

// ✅ Or use Nitro's built-in fetch
export default defineEventHandler(async () => {
  const data = await $fetch('https://api.example.com/data') // Works in Nitro
  return data
})
```

### Page Not Found After Adding to pages/

```bash
# Restart dev server — route generation is cached
# Check .nuxt/routes.mjs for your route
# Ensure file uses .vue extension and correct naming:
# pages/my-page.vue → /my-page
# pages/[id].vue → /:id
```
