---
name: vue-composition-api
description:
  positive: "Use when user builds with Vue.js 3, asks about Composition API, ref/reactive, composables, Pinia state management, Vue Router, Nuxt 3, or Vue component patterns."
  negative: "Do NOT use for React (use react-state-management skill), Svelte (use svelte-patterns skill), Angular, or Vue 2 Options API migration."
---

# Vue 3 Composition API & Ecosystem Patterns

## Composition API Fundamentals

Use `<script setup>` as the default. Declare reactive state with `ref` for primitives and `reactive` for objects. Derive state with `computed`. Run side effects with `watch` or `watchEffect`.

```vue
<script setup lang="ts">
import { ref, reactive, computed, watch, watchEffect } from 'vue'

const count = ref(0)
const state = reactive({ name: 'Vue', version: 3 })
const doubled = computed(() => count.value * 2)

watch(count, (newVal, oldVal) => {
  console.log(`count changed: ${oldVal} → ${newVal}`)
})

watchEffect(() => {
  console.log(`current count: ${count.value}`)
})
</script>
```

- `ref` — wraps a value; access via `.value` in script, auto-unwrapped in template.
- `reactive` — deep reactive proxy for objects/arrays. Do NOT reassign the whole object.
- `computed` — cached getter. Returns a readonly ref.
- `watch` — explicit source, gives old/new values. Use `{ immediate: true }` to run on init.
- `watchEffect` — auto-tracks dependencies. Runs immediately. Use for logging/side effects.

## Script Setup & Compiler Macros

`<script setup>` is the recommended SFC authoring mode. Use compiler macros — they require no imports.

```vue
<script setup lang="ts">
interface Props {
  title: string
  count?: number
  items?: string[]
}

const props = withDefaults(defineProps<Props>(), {
  count: 0,
  items: () => [],
})

const emit = defineEmits<{
  update: [value: string]
  delete: [id: number]
}>()

defineExpose({ reset() { /* exposed to parent via template ref */ } })

// Vue 3.5+: reactive props destructure with defaults
const { title, count = 0 } = defineProps<Props>()
</script>
```

- `defineProps` — declare props with type-only or runtime syntax.
- `defineEmits` — declare emitted events with typed payloads.
- `defineExpose` — explicitly expose public instance properties.
- `withDefaults` — provide default values for type-only props.
- `defineModel` — two-way binding macro (Vue 3.4+).

## Composables

Name composables with `use` prefix. Accept refs or primitives as arguments. Return an object of refs and functions. Clean up side effects in `onUnmounted`.

```ts
// composables/useFetch.ts
import { ref, watchEffect, toValue, type MaybeRefOrGetter } from 'vue'

export function useFetch<T>(url: MaybeRefOrGetter<string>) {
  const data = ref<T | null>(null)
  const error = ref<Error | null>(null)
  const isLoading = ref(false)

  watchEffect(async (onCleanup) => {
    const controller = new AbortController()
    onCleanup(() => controller.abort())

    isLoading.value = true
    error.value = null

    try {
      const res = await fetch(toValue(url), { signal: controller.signal })
      data.value = await res.json()
    } catch (e) {
      if (e instanceof Error && e.name !== 'AbortError') {
        error.value = e
      }
    } finally {
      isLoading.value = false
    }
  })

  return { data, error, isLoading }
}
```

### Composable rules

- Keep each composable focused on one concern.
- Accept `MaybeRefOrGetter<T>` for flexible inputs; use `toValue()` internally.
- Return plain object of refs (not a reactive object) so callers can destructure.
- Encapsulate lifecycle hooks (`onMounted`, `onUnmounted`) inside the composable.
- Avoid shared mutable state unless building a singleton store pattern.

## Reactivity In Depth

| API | Use case |
|-----|----------|
| `ref` | Primitives, DOM refs, any single value |
| `reactive` | Objects/arrays where you access nested properties |
| `shallowRef` | Large objects where only top-level replacement triggers updates |
| `shallowReactive` | Objects where only top-level property changes trigger updates |
| `toRef(obj, 'key')` | Create a ref linked to a reactive object property |
| `toRefs(obj)` | Destructure a reactive object without losing reactivity |
| `readonly` | Prevent mutation of reactive state |
| `toValue(source)` | Unwrap ref, getter, or plain value (Vue 3.3+) |
| `useTemplateRef('name')` | Bind template refs explicitly (Vue 3.5+) |

```ts
import { effectScope } from 'vue'

const scope = effectScope()
scope.run(() => {
  const counter = ref(0)
  watchEffect(() => console.log(counter.value))
})
scope.stop() // disposes all effects created inside
```

Use `effectScope` to batch and dispose watchers/computed in composables or non-component contexts.

## Component Patterns

### Props & Events

```vue
<script setup lang="ts">
const props = defineProps<{ modelValue: string; disabled?: boolean }>()
const emit = defineEmits<{ 'update:modelValue': [value: string] }>()
</script>

<template>
  <input
    :value="modelValue"
    :disabled="disabled"
    @input="emit('update:modelValue', ($event.target as HTMLInputElement).value)"
  />
</template>
```

### v-model (Vue 3.4+ defineModel)

```vue
<script setup lang="ts">
const modelValue = defineModel<string>({ required: true })
const loading = defineModel<boolean>('loading', { default: false })
</script>

<template>
  <input v-model="modelValue" />
</template>
```

### Slots

```vue
<template>
  <div class="card">
    <header v-if="$slots.header"><slot name="header" /></header>
    <slot :item="currentItem" /> <!-- scoped slot -->
    <footer><slot name="footer">Default footer</slot></footer>
  </div>
</template>
```

### Provide / Inject

```ts
// Parent — provide a ref to keep reactivity
import { provide, ref } from 'vue'
const theme = ref('dark')
provide('theme', theme)

// Child (any depth)
const theme = inject<Ref<string>>('theme', ref('light'))
```

Use `InjectionKey<T>` for type safety: `export const ThemeKey: InjectionKey<Ref<string>> = Symbol('theme')`

### Teleport

Use `<Teleport to="body">` to render modals/overlays outside the component DOM tree.

## Pinia State Management

Prefer setup syntax for Composition API consistency.

```ts
// stores/useAuthStore.ts
import { defineStore } from 'pinia'
import { ref, computed } from 'vue'

export const useAuthStore = defineStore('auth', () => {
  // state
  const user = ref<User | null>(null)
  const token = ref<string | null>(null)

  // getters
  const isAuthenticated = computed(() => !!token.value)
  const displayName = computed(() => user.value?.name ?? 'Guest')

  // actions
  async function login(credentials: Credentials) {
    const res = await api.login(credentials)
    user.value = res.user
    token.value = res.token
  }

  function logout() {
    user.value = null
    token.value = null
  }

  return { user, token, isAuthenticated, displayName, login, logout }
})
```

### Pinia patterns

- One store per domain (`useAuthStore`, `useCartStore`, `useSettingsStore`).
- Setup syntax: `defineStore('id', () => { ... })` for full Composition API power.
- `storeToRefs(store)` to destructure state/getters without losing reactivity.

### Persisted state plugin

```ts
import { createPinia } from 'pinia'
import piniaPersistedstate from 'pinia-plugin-persistedstate'

const pinia = createPinia()
pinia.use(piniaPersistedstate)

// In store definition:
export const useSettingsStore = defineStore('settings', () => {
  const locale = ref('en')
  return { locale }
}, {
  persist: true, // saves to localStorage by default
})
```

## Vue Router

```ts
import { createRouter, createWebHistory } from 'vue-router'

const router = createRouter({
  history: createWebHistory(),
  routes: [
    { path: '/', component: () => import('./pages/Home.vue') },
    {
      path: '/dashboard',
      component: () => import('./pages/Dashboard.vue'),
      meta: { requiresAuth: true },
      children: [
        { path: 'settings', component: () => import('./pages/Settings.vue') },
      ],
    },
    { path: '/:pathMatch(.*)*', component: () => import('./pages/NotFound.vue') },
  ],
})

// Global navigation guard
router.beforeEach((to, from) => {
  const auth = useAuthStore()
  if (to.meta.requiresAuth && !auth.isAuthenticated) {
    return { path: '/login', query: { redirect: to.fullPath } }
  }
})
```

### In-component navigation

```vue
<script setup lang="ts">
import { useRouter, useRoute, onBeforeRouteLeave } from 'vue-router'
const router = useRouter()
const route = useRoute()
onBeforeRouteLeave(() => {
  if (hasUnsavedChanges.value) return confirm('Discard changes?')
})
</script>
```

Lazy-load all route components with dynamic `import()`. Use route `meta` for auth guards, breadcrumbs, and layout selection.

## Lifecycle Hooks

| Hook | When |
|------|------|
| `onMounted` | DOM ready — fetch data, attach listeners |
| `onUnmounted` | Cleanup intervals, listeners, subscriptions |
| `onUpdated` | After reactive state change causes re-render |
| `onErrorCaptured` | Handle errors from child components |
| `onActivated` / `onDeactivated` | `<KeepAlive>` activate/deactivate |
| `onServerPrefetch` | SSR-only async data fetch |

Prefer encapsulating setup/teardown in composables rather than scattering lifecycle hooks across components.

### TypeScript Integration

Generic components (Vue 3.3+):

```vue
<script setup lang="ts" generic="T extends { id: number }">
defineProps<{ items: T[]; selected?: T }>()
defineEmits<{ select: [item: T] }>()
</script>
```

Typed provide/inject — use `InjectionKey<T>`:

```ts
export const UserServiceKey: InjectionKey<UserService> = Symbol()
```

Component instance typing:

```ts
const compRef = useTemplateRef<InstanceType<typeof MyComponent>>('myComp')
```

## Performance

- **`v-once`** — render static content once; skip future patches.
- **`v-memo`** — memoize template subtrees: `<div v-memo="[item.id, selected]">`.
- **`<KeepAlive>`** — cache component instances: `<KeepAlive :max="5"><component :is="view" /></KeepAlive>`.
- **Async components** — `defineAsyncComponent(() => import('./Heavy.vue'))`.
- **`shallowRef`** — avoid deep reactivity on large data structures.
- **Virtual scrolling** — use `vue-virtual-scroller` for long lists.
- **Tree-shaking** — import only what you need; unused APIs are eliminated at build.

## Testing

### Component testing (Vitest + Vue Test Utils)

```ts
import { describe, it, expect } from 'vitest'
import { mount } from '@vue/test-utils'
import Counter from './Counter.vue'

describe('Counter', () => {
  it('increments count on click', async () => {
    const wrapper = mount(Counter, { props: { initial: 0 } })
    await wrapper.find('button').trigger('click')
    expect(wrapper.text()).toContain('1')
  })
})
```

### Composable testing

```ts
import { useCounter } from './useCounter'

it('increments', () => {
  const { count, increment } = useCounter(0)
  increment()
  expect(count.value).toBe(1)
})
```

Test composables with lifecycle hooks by wrapping in a host component or `withSetup` helper.

### Pinia store testing

```ts
import { setActivePinia, createPinia } from 'pinia'
beforeEach(() => setActivePinia(createPinia()))

it('logs in', async () => {
  const store = useAuthStore()
  await store.login({ email: 'a@b.com', password: 'pass' })
  expect(store.isAuthenticated).toBe(true)
})
```

## Nuxt 3 Essentials

### Auto-imports

Nuxt 3 auto-imports Vue APIs (`ref`, `computed`, `watch`), composables from `composables/`, and utilities from `utils/`.

### Data fetching

```vue
<script setup lang="ts">
// SSR-safe fetch — deduplicates between server and client
const { data: posts, pending, error } = await useFetch('/api/posts')

// Custom async logic with cache key
const { data: user } = await useAsyncData('user', () => $fetch(`/api/users/${route.params.id}`))

// Reactive query params
const search = ref('')
const { data: results } = await useFetch('/api/search', {
  query: { q: search },
  watch: [search],
})
</script>
```

- Use `useFetch` for standard API calls — handles SSR hydration automatically.
- Use `useAsyncData` for custom async logic. Use `$fetch` for client-only mutations.
- Use `lazy: true` for non-blocking fetches with loading states.

### Server routes

```ts
// server/api/users/[id].get.ts
export default defineEventHandler(async (event) => {
  const id = getRouterParam(event, 'id')
  return await db.user.findUnique({ where: { id: Number(id) } })
})
```

### Middleware

```ts
// middleware/auth.ts
export default defineNuxtRouteMiddleware((to) => {
  if (!useAuthStore().isAuthenticated) return navigateTo('/login')
})
```

Apply with `definePageMeta({ middleware: 'auth' })` in page components.

### Nuxt patterns

- `useState` for SSR-safe shared state. `useRuntimeConfig()` for env config.
- `useHead()` / `useSeoMeta()` for document head. Keep secrets in `server/` only.

## Anti-Patterns

### Do NOT mutate props

```ts
// ❌ props.items.push(newItem)
// ✅ emit('add-item', newItem)
```

### Do NOT reassign reactive objects

```ts
// ❌ state = reactive({ count: 1 }) — watchers on old object are orphaned
// ✅ state.count = 1
// ✅ const state = ref({ count: 0 }); state.value = { count: 1 }
```

### Do NOT destructure reactive without toRefs

```ts
// ❌ const { name } = reactive({ name: 'Vue' }) — loses reactivity
// ✅ const { name } = toRefs(reactive({ name: 'Vue' }))
```

### Avoid over-using watchers

```ts
// ❌ watch(items, (val) => { itemCount.value = val.length })
// ✅ const itemCount = computed(() => items.value.length)
```

### Avoid global reactive singletons in SSR

```ts
// ❌ const globalState = reactive({ user: null }) — shared across requests
// ✅ const user = useState('user', () => null) — per-request isolation
```

### Clean up side effects

```ts
onMounted(() => {
  const id = setInterval(poll, 5000)
  onUnmounted(() => clearInterval(id))
})
```

<!-- tested: pass -->
