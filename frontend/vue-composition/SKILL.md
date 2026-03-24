---
name: vue-composition
description: >
  Vue 3 Composition API: script setup, reactivity (ref, reactive, computed, watch, watchEffect,
  shallowRef, triggerRef), lifecycle hooks, composables, provide/inject, template refs, defineProps,
  defineEmits, defineModel, withDefaults, slots, Pinia (defineStore, storeToRefs, setup stores),
  VueUse composables, TypeScript typing, async/Suspense, performance, testing with @vue/test-utils,
  and Options API migration. Use when writing Vue 3 SFCs, composables, or stores with Composition API.
  Do NOT use for Vue 2, Options API-only code, Nuxt server routes, or non-Vue frameworks (React, Svelte, Angular).
---

# Vue 3 Composition API

Always use `<script setup lang="ts">`. Prefer `ref` over `reactive`. Extract reusable logic into `use*` composables. Type everything.

## Script Setup

Top-level bindings are auto-exposed to template. This is the default for all new components.

```vue
<script setup lang="ts">
import { ref, computed, onMounted } from 'vue'
const count = ref(0)
const doubled = computed(() => count.value * 2)
const increment = () => count.value++
onMounted(() => console.log('ready'))
</script>
<template>
  <button @click="increment">{{ count }} ({{ doubled }})</button>
</template>
```

Use plain `setup()` only for `inheritAttrs: false` or `expose()`:

```ts
export default defineComponent({
  inheritAttrs: false,
  setup(props, { attrs, slots, emit, expose }) {
    expose({ publicMethod })
    return { /* template bindings */ }
  }
})
```

## Reactivity

### ref and reactive

```ts
const count = ref(0)                              // Ref<number> — use .value in script
const user = reactive({ name: 'Ada', age: 30 })   // deeply reactive object
```

Prefer `ref` for all values. `reactive` loses reactivity on reassignment and destructuring.

### computed

```ts
const full = computed(() => `${first.value} ${last.value}`)          // read-only
const name = computed({                                               // writable
  get: () => `${first.value} ${last.value}`,
  set: (val: string) => { [first.value, last.value] = val.split(' ') }
})
```

### watch and watchEffect

```ts
watch(count, (newVal, oldVal) => { /* ... */ })                         // single ref
watch([a, b], ([newA, newB], [oldA, oldB]) => { /* ... */ })            // multiple
watch(() => route.params.id, (id) => fetchUser(id), { immediate: true }) // getter
watch(state, handler, { deep: true })                                    // deep (expensive)

const stop = watchEffect(() => { console.log(count.value) })  // auto-track, runs immediately
stop()  // manual cleanup

watchPostEffect(() => { /* access updated DOM */ })

// onWatcherCleanup (3.5+)
watchEffect(() => {
  const ctrl = new AbortController()
  fetch(url.value, { signal: ctrl.signal })
  onWatcherCleanup(() => ctrl.abort())
})
```

### shallowRef and triggerRef

```ts
const data = shallowRef({ items: [] })   // only .value reassignment triggers
data.value.items.push('x')               // NO trigger
data.value = { items: ['x'] }            // triggers
data.value.items.push('x'); triggerRef(data)  // force trigger after mutation
```

## Lifecycle Hooks

```ts
onBeforeMount(() => {})
onMounted(() => {})            // DOM ready — fetch data, set up listeners
onBeforeUpdate(() => {})
onUpdated(() => {})            // DOM re-rendered
onBeforeUnmount(() => {})
onUnmounted(() => {})          // cleanup: timers, listeners, subscriptions
onActivated(() => {})          // <KeepAlive> activated
onDeactivated(() => {})        // <KeepAlive> deactivated
onErrorCaptured((err, instance, info) => false)  // return false stops propagation
onServerPrefetch(async () => { /* SSR data fetch */ })
```

All hooks must be called synchronously during `setup()`. Never call inside `setTimeout` or after `await`.

## Composables

Name `useX`. Accept `MaybeRefOrGetter<T>` inputs. Return plain object of refs.

```ts
// composables/useFetch.ts
import { ref, watchEffect, toValue, type MaybeRefOrGetter } from 'vue'

export function useFetch<T>(url: MaybeRefOrGetter<string>) {
  const data = ref<T | null>(null)
  const error = ref<Error | null>(null)
  const loading = ref(false)

  async function execute() {
    loading.value = true; error.value = null
    try {
      const res = await fetch(toValue(url))
      data.value = await res.json()
    } catch (e) { error.value = e as Error }
    finally { loading.value = false }
  }

  watchEffect(() => { toValue(url); execute() })
  return { data, error, loading, execute }
}

// Usage
const { data: users, loading } = useFetch<User[]>('/api/users')
```

Conventions:
- Use `toValue()` to unwrap `MaybeRefOrGetter` inputs.
- Return plain object of refs — allows destructuring without reactivity loss.
- Clean up side effects in `onUnmounted` or `onWatcherCleanup`.

## Props and Emits

### defineProps with TypeScript

```vue
<script setup lang="ts">
interface Props { title: string; count?: number; items?: string[] }

// withDefaults pattern
const props = withDefaults(defineProps<Props>(), {
  count: 0,
  items: () => [],  // factory for non-primitives
})

// Destructured with defaults (Vue 3.5+) — stays reactive
const { title, count = 0 } = defineProps<Props>()
</script>
```

### defineEmits

```vue
<script setup lang="ts">
const emit = defineEmits<{
  update: [id: number, value: string]
  delete: [id: number]
}>()
emit('update', 1, 'new value')
</script>
```

### defineModel (Vue 3.4+)

Replaces manual `modelValue` prop + `update:modelValue` emit:

```vue
<script setup lang="ts">
const model = defineModel<string>({ required: true })           // default v-model
const title = defineModel<string>('title', { default: '' })     // v-model:title
</script>
<template><input v-model="model" /></template>
```

## Provide / Inject

```ts
// keys.ts — typed injection keys
import type { InjectionKey, Ref } from 'vue'
export const ThemeKey: InjectionKey<Ref<'light' | 'dark'>> = Symbol('theme')

// Provider
const theme = ref<'light' | 'dark'>('light')
provide(ThemeKey, theme)

// Consumer (any depth)
const theme = inject(ThemeKey)                  // Ref<'light'|'dark'> | undefined
const theme = inject(ThemeKey, ref('light'))    // with default — no undefined
```

Always use `InjectionKey<T>` for type safety.

## Template Refs

```vue
<script setup lang="ts">
import { ref, onMounted, useTemplateRef } from 'vue'
const inputEl = useTemplateRef<HTMLInputElement>('input')  // Vue 3.5+
const canvas = ref<HTMLCanvasElement | null>(null)          // classic approach
onMounted(() => {
  inputEl.value?.focus()
  const ctx = canvas.value?.getContext('2d')
})
</script>
<template>
  <input ref="input" />
  <canvas ref="canvas" />
</template>
```

Component refs: type as `InstanceType<typeof MyComponent>`.

## Slots

```vue
<script setup lang="ts">
import { useSlots } from 'vue'
const slots = useSlots()
const hasHeader = computed(() => !!slots.header)
</script>
<template>
  <header v-if="hasHeader"><slot name="header" /></header>
  <main><slot /></main>
  <slot name="item" v-for="item in items" :item="item" :index="i" />
</template>
```

## Pinia Store Integration

### Setup Store (preferred)

```ts
export const useCartStore = defineStore('cart', () => {
  const items = ref<CartItem[]>([])
  const total = computed(() => items.value.reduce((s, i) => s + i.price * i.qty, 0))
  function addItem(item: CartItem) { items.value.push(item) }
  function clear() { items.value = [] }
  return { items, total, addItem, clear }
})
```

### Options Store

```ts
export const useUserStore = defineStore('user', {
  state: () => ({ name: '', token: '' }),
  getters: { isLoggedIn: (state) => !!state.token },
  actions: {
    async login(creds: Credentials) {
      const res = await api.login(creds)
      this.token = res.token; this.name = res.name
    }
  }
})
```

### Using stores in components

```vue
<script setup lang="ts">
import { storeToRefs } from 'pinia'
const store = useCartStore()
const { items, total } = storeToRefs(store)  // reactive refs for state/getters
const { addItem, clear } = store              // actions destructure directly
</script>
```

**Critical**: Never destructure state/getters directly — use `storeToRefs`. Actions can be destructured directly.

## VueUse Essentials

```ts
import { useStorage, useFetch, useEventListener, useDark, useToggle } from '@vueuse/core'

const settings = useStorage('app-settings', { theme: 'light', lang: 'en' })  // localStorage sync
const { data, isFetching, error } = useFetch('/api/data').json()              // reactive fetch
useEventListener(window, 'resize', handler)                                    // auto-cleanup
useEventListener(buttonRef, 'click', handler)                                  // works with refs
const isDark = useDark(); const toggleDark = useToggle(isDark)                 // dark mode
```

Guard browser APIs with `onMounted` or `isClient` for SSR safety.

## TypeScript Integration

### Typing composable returns

```ts
interface UseAuthReturn {
  user: Ref<User | null>
  isAuthenticated: ComputedRef<boolean>
  login: (creds: Credentials) => Promise<void>
  logout: () => void
}
export function useAuth(): UseAuthReturn {
  const user = ref<User | null>(null)
  const isAuthenticated = computed(() => !!user.value)
  return { user, isAuthenticated, login, logout }
}
```

### Typing refs, events, and generic components

```ts
const el = ref<HTMLDivElement | null>(null)
const comp = ref<InstanceType<typeof MyComponent> | null>(null)
function handleInput(e: Event) { console.log((e.target as HTMLInputElement).value) }
```

```vue
<!-- Generic components (3.3+) -->
<script setup lang="ts" generic="T extends { id: number }">
defineProps<{ items: T[]; selected?: T }>()
defineEmits<{ select: [item: T] }>()
</script>
```

## Async Patterns

### Suspense + async setup

```vue
<!-- Parent -->
<Suspense>
  <AsyncChild />
  <template #fallback>Loading...</template>
</Suspense>

<!-- AsyncChild.vue — top-level await makes component async -->
<script setup lang="ts">
const data = await fetchData()
</script>
```

### SSR prefetch

```vue
<script setup lang="ts">
const data = ref<Data | null>(null)
onServerPrefetch(async () => { data.value = await fetchData() })
onMounted(async () => {
  if (!data.value) data.value = await fetchData()  // client fallback
})
</script>
```

## Performance

```ts
import { shallowRef, markRaw, effectScope } from 'vue'

// shallowRef: skip deep reactivity for large objects
const tableData = shallowRef<Row[]>([])
tableData.value = [...tableData.value, newRow]       // reassign to trigger

// markRaw: exclude from reactivity (third-party instances)
const chart = markRaw(new ChartInstance())

// effectScope: batch and dispose effects together
const scope = effectScope()
scope.run(() => {
  const x = computed(() => { /* ... */ })
  watch(source, () => { /* ... */ })
})
scope.stop()  // disposes all effects inside

// Prefer computed over methods for template-used derived data (cached until deps change)
```

## Testing

### Components with Pinia

```ts
import { mount } from '@vue/test-utils'
import { createTestingPinia } from '@pinia/testing'

test('renders and interacts', async () => {
  const wrapper = mount(MyComponent, {
    props: { title: 'Hello' },
    global: { plugins: [createTestingPinia({ stubActions: false })] }
  })
  await wrapper.find('button').trigger('click')
  expect(wrapper.text()).toContain('1')
})
```

### Composables

```ts
// Simple — test directly
test('useCounter', () => {
  const { count, increment } = useCounter()
  expect(count.value).toBe(0); increment(); expect(count.value).toBe(1)
})

// With lifecycle — use withSetup helper
function withSetup<T>(composable: () => T): [T, App] {
  let result!: T
  const app = createApp({ setup() { result = composable(); return () => {} } })
  app.mount(document.createElement('div'))
  return [result, app]
}
test('composable with onMounted', () => {
  const [result, app] = withSetup(() => useMyHook())
  expect(result.ready.value).toBe(true)
  app.unmount()
})
```

## Migration from Options API

Migrate when: component exceeds 200 lines, logic is reused, or TypeScript typing is needed.

| Options API | Composition API |
|---|---|
| `data()` | `ref()` / `reactive()` |
| `computed: {}` | `computed()` |
| `methods: {}` | plain functions |
| `watch: {}` | `watch()` / `watchEffect()` |
| `mounted()` | `onMounted()` |
| `this.$emit()` | `defineEmits()` |
| `this.$refs` | `ref()` + template ref |
| `mixins` | composables |

Both APIs coexist. Migrate incrementally. Extract mixins to composables first.

## Common Gotchas

```ts
// ❌ Destructuring reactive → loses reactivity
const { count } = reactive({ count: 0 })  // plain number
const { count } = toRefs(state)           // ✅ Ref<number>
const { name } = storeToRefs(store)       // ✅ for Pinia stores

// ❌ Reassigning reactive → old proxy lost
state = reactive({ items: ['new'] })
Object.assign(state, { items: ['new'] })  // ✅ mutate in place

// ❌ Hooks after await → never fire
await fetchData(); onMounted(() => {})     // ❌
onMounted(() => {}); await fetchData()     // ✅ hooks before await
```

See [troubleshooting.md](references/troubleshooting.md) for full coverage of reactivity pitfalls, watch timing, memory leaks, SSR mismatches, and more.

## Extended Resources

### references/

In-depth reference docs for specific topics. Use when the sections above need more detail.

- **[advanced-patterns.md](references/advanced-patterns.md)** — Renderless components, headless UI, state machines, optimistic updates, virtual scrolling, WebSocket composable, vee-validate integration, debounced/throttled computed, `effectScope` for library authors, dependency injection patterns.
- **[troubleshooting.md](references/troubleshooting.md)** — Reactivity pitfalls (destructuring, ref vs reactive), watch timing, computed side effects, memory leaks, template ref timing with `v-if`, async setup gotchas, SSR hydration mismatches, Pinia store reactivity loss, TypeScript generic component issues.
- **[testing-guide.md](references/testing-guide.md)** — Vitest + `@vue/test-utils` setup, testing composables in isolation, mocking composables, testing provide/inject, async setup testing, snapshot testing, Pinia store testing, router-dependent components.

### scripts/

Executable helpers (bash). Run with `./scripts/<name>.sh`.

- **[init-vue-project.sh](scripts/init-vue-project.sh)** — Scaffold Vue 3 + TS + Vite project with Pinia, VueUse, Vue Router, strict TS, example composable, and test setup.
- **[generate-composable.sh](scripts/generate-composable.sh)** — Generate a new `useX` composable with types, lifecycle, cleanup, test file, and barrel export.
- **[migrate-options-to-composition.sh](scripts/migrate-options-to-composition.sh)** — Analyze an Options API `.vue` file, print migration mapping, generate Composition API template.

### assets/

Copy-paste-ready TypeScript templates. Grab and customize.

- **[composable-template.ts](assets/composable-template.ts)** — Standard composable with options pattern, SSR safety, AbortController cleanup, debounce, and TypeScript generics.
- **[pinia-store-template.ts](assets/pinia-store-template.ts)** — Setup store with state, getters, actions, optimistic updates, `$reset`, persistence plugin config, and HMR support.
- **[form-composable.ts](assets/form-composable.ts)** — Form handling: field validation rules, dirty/touched tracking, submit with loading/error, reset, and common validators.
- **[fetch-composable.ts](assets/fetch-composable.ts)** — Data fetching: loading/error states, in-memory caching, AbortController, retry with backoff, pagination (offset + cursor).
- **[vitest-setup.ts](assets/vitest-setup.ts)** — Test setup file: global config, browser API mocks, `mountWithPinia`, `mountAsync`, `withSetup` for composables, `mockFetch` factory.
