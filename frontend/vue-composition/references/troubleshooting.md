# Vue Composition API Troubleshooting

> Diagnose and fix common issues. Each section: symptom → cause → fix → prevention.

## Table of Contents

- [Reactivity Pitfalls](#reactivity-pitfalls)
  - [Destructuring Reactive Objects](#destructuring-reactive-objects)
  - [ref vs reactive Confusion](#ref-vs-reactive-confusion)
  - [Reactivity Lost on Reassignment](#reactivity-lost-on-reassignment)
  - [Unwrapping Gotchas](#unwrapping-gotchas)
- [Watch and WatchEffect Issues](#watch-and-watcheffect-issues)
  - [watch vs watchEffect Timing](#watch-vs-watcheffect-timing)
  - [Watch Not Firing](#watch-not-firing)
  - [watchEffect Infinite Loop](#watcheffect-infinite-loop)
- [Computed Side Effects](#computed-side-effects)
- [Memory Leaks with Watchers](#memory-leaks-with-watchers)
- [Template Ref Timing with v-if](#template-ref-timing-with-v-if)
- [Async Setup Gotchas](#async-setup-gotchas)
- [SSR Hydration Mismatches](#ssr-hydration-mismatches)
- [Pinia Store Reactivity Loss](#pinia-store-reactivity-loss)
- [TypeScript Generic Component Issues](#typescript-generic-component-issues)

---

## Reactivity Pitfalls

### Destructuring Reactive Objects

**Symptom**: Template doesn't update when reactive state changes.

```ts
// ❌ BUG: count is a plain number, not reactive
const state = reactive({ count: 0, name: 'Vue' })
const { count, name } = state

// ✅ FIX 1: Use toRefs
const { count, name } = toRefs(state) // Ref<number>, Ref<string>

// ✅ FIX 2: Use ref instead of reactive (preferred)
const count = ref(0)
const name = ref('Vue')

// ✅ FIX 3: Access on state directly
state.count++ // reactive
```

**Prevention**: Default to `ref()` for all state. Reserve `reactive()` for objects you never destructure.

### ref vs reactive Confusion

**Symptom**: `.value` errors, reactivity silently lost.

```ts
// ❌ Common mistake: wrapping ref in reactive
const data = reactive({ count: ref(0) })
data.count // auto-unwrapped — but confusing

// ❌ Common mistake: ref with object, then treating like reactive
const user = ref({ name: 'Ada' })
user.name // ❌ undefined — need user.value.name

// ✅ Rules
// - Use ref() for primitives AND objects
// - Always access via .value in <script>
// - Never access .value in <template> (auto-unwrapped)
const count = ref(0)       // count.value in script, {{ count }} in template
const user = ref({ name: 'Ada' }) // user.value.name in script
```

**Decision chart**:
- Primitive → `ref`
- Object/array → `ref` (default) or `reactive` (if never reassigned/destructured)
- Store state → `ref` inside setup store
- Composable return → always `ref`

### Reactivity Lost on Reassignment

**Symptom**: Reactive object stops updating after reassignment.

```ts
// ❌ BUG: Variable reassignment breaks reactive proxy reference
let state = reactive({ items: [] })
state = reactive({ items: ['new'] }) // Components still watch old proxy

// ✅ FIX 1: Mutate in place
Object.assign(state, { items: ['new'] })

// ✅ FIX 2: Use ref (reassignment via .value works)
const state = ref({ items: [] })
state.value = { items: ['new'] } // ✅ reactive
```

### Unwrapping Gotchas

**Symptom**: Need `.value` in places you don't expect, or don't need it where you do.

```ts
// Refs auto-unwrap inside reactive()
const count = ref(0)
const state = reactive({ count }) // state.count — NO .value needed

// Refs do NOT auto-unwrap in arrays or Maps
const list = reactive([ref(1), ref(2)])
list[0].value // ❌ must use .value
list[0]       // This is a Ref, not a number

// Refs auto-unwrap in templates (top-level only)
// {{ count }}    ✅ auto-unwrapped
// {{ obj.count }} ✅ if obj is reactive and count is ref inside it
// {{ arr[0] }}    ❌ shows Ref object if arr is reactive([ref(...)])
```

---

## Watch and WatchEffect Issues

### watch vs watchEffect Timing

**Symptom**: Callback fires at unexpected times or not at all.

| Feature | `watch` | `watchEffect` |
|---|---|---|
| **Runs immediately** | No (unless `immediate: true`) | Yes |
| **Tracks dependencies** | Explicit (first arg) | Automatic |
| **Old value access** | Yes (`(newVal, oldVal)`) | No |
| **Lazy** | Yes | No |
| **Flush timing** | `pre` (default) | `pre` (default) |

```ts
// ❌ watch not firing on first render
watch(userId, async (id) => {
  user.value = await fetchUser(id)
})
// Component mounts, userId already has value → no callback

// ✅ FIX: immediate: true
watch(userId, async (id) => {
  user.value = await fetchUser(id)
}, { immediate: true })

// ✅ ALT: watchEffect (auto-runs immediately)
watchEffect(async () => {
  user.value = await fetchUser(userId.value)
})
```

### Watch Not Firing

**Symptom**: Changed reactive data but watch callback never runs.

```ts
// ❌ Watching reactive object property directly (not a getter)
const state = reactive({ page: 1 })
watch(state.page, () => {}) // Watches the NUMBER 1, not the reactive prop

// ✅ FIX: Use a getter
watch(() => state.page, (newPage) => { /* fires */ })

// ❌ Watching deep object without deep: true
const filters = ref({ status: 'active', page: 1 })
watch(filters, () => {}) // won't fire on filters.value.page = 2

// ✅ FIX: deep: true
watch(filters, () => {}, { deep: true })

// ✅ ALT: Watch specific nested property
watch(() => filters.value.page, (newPage) => {})
```

### watchEffect Infinite Loop

**Symptom**: Browser freezes, "Maximum call stack size exceeded."

```ts
// ❌ BUG: Modifying a tracked dependency inside watchEffect
const items = ref<string[]>([])
watchEffect(() => {
  items.value = items.value.filter(i => i !== '') // Reads AND writes items → infinite loop
})

// ✅ FIX: Use watch instead (explicitly track source)
watch(items, (current) => {
  const filtered = current.filter(i => i !== '')
  if (filtered.length !== current.length) {
    items.value = filtered
  }
}, { deep: true })

// ✅ FIX 2: Separate trigger from effect
const rawItems = ref<string[]>([])
const cleanItems = computed(() => rawItems.value.filter(i => i !== ''))
```

---

## Computed Side Effects

**Symptom**: Unexpected behavior, stale data, or effects firing unpredictably.

```ts
// ❌ ANTI-PATTERN: Side effects in computed
const displayName = computed(() => {
  analytics.track('name-accessed') // ❌ side effect!
  localStorage.setItem('last', name.value) // ❌ side effect!
  return name.value.toUpperCase()
})

// ✅ FIX: Use watchEffect for side effects
const displayName = computed(() => name.value.toUpperCase())
watchEffect(() => {
  analytics.track('name-accessed')
  localStorage.setItem('last', name.value)
})
```

**Rules for computed**:
- Pure function only — no mutations, API calls, DOM access, or logging
- Must return a value
- Vue may skip re-evaluation if deps haven't changed (caching)
- Use `watch`/`watchEffect` for side effects

---

## Memory Leaks with Watchers

**Symptom**: Memory grows over time, effects run after component unmount.

### Global Event Listeners

```ts
// ❌ LEAK: Listener never removed
onMounted(() => {
  window.addEventListener('resize', handleResize)
})

// ✅ FIX: Clean up in onUnmounted
onMounted(() => {
  window.addEventListener('resize', handleResize)
})
onUnmounted(() => {
  window.removeEventListener('resize', handleResize)
})

// ✅ BETTER: useEventListener from VueUse (auto-cleanup)
useEventListener(window, 'resize', handleResize)
```

### Watchers Created Outside Component Context

```ts
// ❌ LEAK: Watcher created in setTimeout — no auto-cleanup
onMounted(() => {
  setTimeout(() => {
    watch(source, handler) // Orphaned — runs forever
  }, 1000)
})

// ✅ FIX: Store stop handle and call it
let stopWatch: (() => void) | null = null
onMounted(() => {
  setTimeout(() => {
    stopWatch = watch(source, handler)
  }, 1000)
})
onUnmounted(() => stopWatch?.())
```

### Intervals and Timers

```ts
// ❌ LEAK
onMounted(() => {
  setInterval(poll, 5000) // Runs forever
})

// ✅ FIX
let timer: ReturnType<typeof setInterval>
onMounted(() => { timer = setInterval(poll, 5000) })
onUnmounted(() => clearInterval(timer))

// ✅ BETTER: useIntervalFn from VueUse
const { pause, resume } = useIntervalFn(poll, 5000)
```

### AbortController for Fetch

```ts
// ❌ LEAK: Pending fetch continues after unmount
watchEffect(async () => {
  const res = await fetch(`/api/data?q=${query.value}`)
  data.value = await res.json()
})

// ✅ FIX: onWatcherCleanup (Vue 3.5+)
watchEffect(async () => {
  const ctrl = new AbortController()
  onWatcherCleanup(() => ctrl.abort())
  try {
    const res = await fetch(`/api/data?q=${query.value}`, { signal: ctrl.signal })
    data.value = await res.json()
  } catch (e) {
    if (!(e instanceof DOMException && e.name === 'AbortError')) throw e
  }
})
```

---

## Template Ref Timing with v-if

**Symptom**: `ref.value` is `null` even after `onMounted`.

```vue
<script setup lang="ts">
const show = ref(false)
const el = ref<HTMLDivElement | null>(null)

onMounted(() => {
  console.log(el.value) // null! — element isn't rendered yet (show is false)
})

// ❌ Bad: accessing ref before element exists
function doSomething() {
  el.value!.focus() // May crash if show is false
}
</script>
<template>
  <div v-if="show" ref="el">Content</div>
</template>
```

### Fixes

```ts
// ✅ FIX 1: Watch the ref
watch(el, (element) => {
  if (element) element.focus()
})

// ✅ FIX 2: Use watchPostEffect for DOM timing
watchPostEffect(() => {
  if (el.value) el.value.focus()
})

// ✅ FIX 3: nextTick after changing v-if condition
async function showAndFocus() {
  show.value = true
  await nextTick()
  el.value?.focus()
}

// ✅ FIX 4: Optional chaining (defensive)
function doSomething() {
  el.value?.focus() // Safe — no crash if null
}
```

### v-for Template Refs

```vue
<script setup lang="ts">
// Array of refs for v-for items
const itemRefs = ref<HTMLElement[]>([])

// Vue 3.5+: useTemplateRef
const items = useTemplateRef<HTMLElement[]>('items')
</script>
<template>
  <div v-for="item in list" :key="item.id" ref="itemRefs">{{ item.name }}</div>
</template>
```

**Note**: Ref array order is NOT guaranteed to match source array order.

---

## Async Setup Gotchas

**Symptom**: Lifecycle hooks don't fire, component never renders, or "inject() can only be used inside setup()" errors.

### Rules

1. Register ALL lifecycle hooks BEFORE any `await`
2. Call `inject()` BEFORE any `await`
3. Wrap parent with `<Suspense>` if using top-level `await`

```ts
// ❌ BUG: onMounted registered after await — never fires
const data = await fetchData()
onMounted(() => console.log('ready')) // ❌ Too late

// ✅ FIX: Hooks first, then await
onMounted(() => console.log('ready'))
const data = await fetchData()
```

```ts
// ❌ BUG: inject after await
const data = await fetchData()
const theme = inject(ThemeKey) // ❌ Error: inject() outside setup()

// ✅ FIX
const theme = inject(ThemeKey) // ✅ Before await
onMounted(() => {})            // ✅ Before await
const data = await fetchData()
```

### Suspense Requirements

```vue
<!-- ❌ Component with top-level await but no Suspense wrapper -->
<!-- App.vue -->
<AsyncComponent />  <!-- Renders nothing, no error -->

<!-- ✅ FIX -->
<Suspense>
  <AsyncComponent />
  <template #fallback>Loading...</template>
</Suspense>
```

### Error Handling with Async Setup

```vue
<!-- Parent must use onErrorCaptured or errorCaptured option -->
<script setup lang="ts">
onErrorCaptured((err, instance, info) => {
  if (info === 'setup function') {
    setupError.value = err
    return false // prevent propagation
  }
})
</script>
<template>
  <div v-if="setupError">Failed: {{ setupError.message }}</div>
  <Suspense v-else>
    <AsyncChild />
    <template #fallback>Loading...</template>
  </Suspense>
</template>
```

---

## SSR Hydration Mismatches

**Symptom**: Console warning "Hydration node mismatch", flickering content, or DOM elements doubling.

### Common Causes and Fixes

#### Browser-Only APIs

```ts
// ❌ BUG: window/document access during SSR
const width = ref(window.innerWidth) // ReferenceError on server

// ✅ FIX: Guard with onMounted or check environment
const width = ref(0)
onMounted(() => { width.value = window.innerWidth })

// ✅ ALT: VueUse
import { useWindowSize } from '@vueuse/core'
const { width } = useWindowSize() // SSR-safe internally
```

#### Date/Time Rendering

```ts
// ❌ BUG: Different time on server vs client
const now = ref(new Date().toLocaleString()) // Mismatch!

// ✅ FIX: Render on client only
const now = ref('')
onMounted(() => { now.value = new Date().toLocaleString() })
```

```vue
<!-- ✅ ALT: ClientOnly wrapper (Nuxt) -->
<ClientOnly>
  <span>{{ new Date().toLocaleString() }}</span>
  <template #fallback>Loading time...</template>
</ClientOnly>
```

#### Random Values / IDs

```ts
// ❌ BUG: Different random values server vs client
const id = ref(`el-${Math.random().toString(36).slice(2)}`)

// ✅ FIX: useId() (Vue 3.5+ / Nuxt)
import { useId } from 'vue'
const id = useId() // Consistent across SSR/client
```

#### Conditional Rendering Based on Client State

```vue
<!-- ❌ BUG: v-if based on localStorage (unavailable on server) -->
<div v-if="isLoggedIn">Welcome</div>

<!-- ✅ FIX: onMounted + ClientOnly / Suspense -->
<script setup lang="ts">
const isLoggedIn = ref(false) // Default for SSR
onMounted(() => {
  isLoggedIn.value = !!localStorage.getItem('token')
})
</script>
```

---

## Pinia Store Reactivity Loss

**Symptom**: Store values don't update in component when store changes.

### Destructuring State/Getters

```ts
// ❌ BUG: Destructured values are plain (not reactive)
const store = useUserStore()
const { name, isLoggedIn } = store // name is 'Ada' (string), won't update
store.name = 'Grace' // Component still shows 'Ada'

// ✅ FIX: storeToRefs for state and getters
const { name, isLoggedIn } = storeToRefs(store)
// name is Ref<string>, isLoggedIn is ComputedRef<boolean>

// Actions can be destructured directly (they're functions)
const { login, logout } = store // ✅ Fine
```

### Store Outside Component

```ts
// ❌ BUG: Using store before Pinia is installed
// utils/auth.ts
const store = useAuthStore() // ❌ Error: getActivePinia was called with no active Pinia

// ✅ FIX: Call inside functions, not at module top level
export function checkAuth() {
  const store = useAuthStore() // ✅ Called when Pinia is active
  return store.isLoggedIn
}

// ✅ ALT: Accept store as parameter
export function checkAuth(store: ReturnType<typeof useAuthStore>) {
  return store.isLoggedIn
}
```

### Computed from Store (Options Store)

```ts
// ❌ BUG: Computed wrapping non-reactive destructured value
const store = useUserStore()
const { name } = store // plain string
const greeting = computed(() => `Hello ${name}`) // Never updates

// ✅ FIX
const store = useUserStore()
const greeting = computed(() => `Hello ${store.name}`) // Direct access — reactive
// OR
const { name } = storeToRefs(store)
const greeting = computed(() => `Hello ${name.value}`)
```

### $reset with Setup Stores

```ts
// ❌ BUG: $reset() not available on setup stores
const store = useCartStore() // setup store
store.$reset() // ❌ Error: $reset not available

// ✅ FIX: Implement reset manually in setup store
export const useCartStore = defineStore('cart', () => {
  const items = ref<CartItem[]>([])
  const total = computed(() => items.value.reduce((s, i) => s + i.price, 0))

  function $reset() {
    items.value = []
  }

  return { items, total, $reset }
})
```

---

## TypeScript Generic Component Issues

### Generic Prop Inference Failures

**Symptom**: TypeScript can't infer generic type from props.

```vue
<!-- ❌ Type error or 'unknown' inference -->
<script setup lang="ts" generic="T">
const props = defineProps<{
  items: T[]
  renderItem: (item: T) => string
}>()
</script>
```

```vue
<!-- Usage: T should be inferred from items -->
<MyList :items="users" :render-item="(u) => u.name" />
<!-- Sometimes TS infers T as 'unknown' instead of 'User' -->
```

**Fixes**:

```vue
<!-- ✅ FIX 1: Add constraint -->
<script setup lang="ts" generic="T extends Record<string, any>">
defineProps<{ items: T[]; renderItem: (item: T) => string }>()
</script>

<!-- ✅ FIX 2: Ensure items array is properly typed -->
<MyList :items="users as User[]" :render-item="(u: User) => u.name" />
```

### defineExpose with Generics

```ts
// ❌ BUG: Exposed methods lose generic types
// Parent accessing ref to generic child

// ✅ FIX: Type the component ref explicitly
const listRef = ref<InstanceType<typeof MyList<User>> | null>(null)
// Note: This syntax may not work in all Vue versions.

// ✅ WORKAROUND: Define a non-generic interface
interface MyListExposed {
  scrollTo: (index: number) => void
  getSelected: () => unknown
}
const listRef = ref<MyListExposed | null>(null)
```

### Generic Composables

```ts
// ❌ BUG: Type narrowing lost in composable return
function useList<T>(items: Ref<T[]>) {
  const selected = ref<T | null>(null) // Ref<T | null> becomes Ref<unknown | null>
  return { selected }
}

// ✅ FIX: Explicit return type
interface UseListReturn<T> {
  selected: Ref<T | null>
  select: (item: T) => void
}

function useList<T>(items: Ref<T[]>): UseListReturn<T> {
  const selected = ref<T | null>(null) as Ref<T | null>
  const select = (item: T) => { selected.value = item }
  return { selected, select }
}
```

### Typing Event Handlers in Generic Components

```vue
<script setup lang="ts" generic="T extends { id: string | number }">
const emit = defineEmits<{
  select: [item: T]
  delete: [id: T['id']]
}>()
// T['id'] correctly narrows to string | number based on T
</script>
```

### Common TS Config for Vue

```json
// tsconfig.json — required settings for Vue + TS
{
  "compilerOptions": {
    "target": "ESNext",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "strict": true,
    "jsx": "preserve",
    "jsxImportSource": "vue",
    "types": ["vite/client"],
    "paths": { "@/*": ["./src/*"] }
  },
  "include": ["src/**/*.ts", "src/**/*.tsx", "src/**/*.vue"],
  "references": [{ "path": "./tsconfig.node.json" }]
}
```
