# Advanced Vue Composition API Patterns

> Dense reference for advanced patterns. Each section is self-contained with copy-paste examples.

## Table of Contents

- [Renderless Components with Composables](#renderless-components-with-composables)
- [Headless UI Patterns](#headless-ui-patterns)
- [State Machines with Composables](#state-machines-with-composables)
- [Optimistic Updates](#optimistic-updates)
- [Virtual Scrolling Composable](#virtual-scrolling-composable)
- [WebSocket Composable](#websocket-composable)
- [Form Validation Composable (vee-validate)](#form-validation-composable-vee-validate)
- [Debounced and Throttled Computed](#debounced-and-throttled-computed)
- [effectScope for Library Authors](#effectscope-for-library-authors)
- [Dependency Injection Patterns](#dependency-injection-patterns)

---

## Renderless Components with Composables

Renderless components expose logic via scoped slots. Pair with composables for maximum reuse.

### Pattern: Composable + Renderless Wrapper

```ts
// composables/useToggle.ts
import { ref } from 'vue'

export function useToggle(initial = false) {
  const isOpen = ref(initial)
  const open = () => { isOpen.value = true }
  const close = () => { isOpen.value = false }
  const toggle = () => { isOpen.value = !isOpen.value }
  return { isOpen, open, close, toggle }
}
```

```vue
<!-- components/RenderlessToggle.vue -->
<script setup lang="ts">
import { useToggle } from '@/composables/useToggle'
const state = useToggle()
</script>
<template>
  <slot v-bind="state" />
</template>
```

```vue
<!-- Usage — consumer controls rendering -->
<RenderlessToggle v-slot="{ isOpen, toggle }">
  <button @click="toggle">{{ isOpen ? 'Hide' : 'Show' }}</button>
  <div v-if="isOpen">Content here</div>
</RenderlessToggle>
```

### When to use renderless vs composable directly

| Use composable directly | Use renderless component |
|---|---|
| Logic in `<script setup>` | Logic shared across templates without script |
| Full TypeScript control needed | Slot-based composition (design systems) |
| No template coupling | Need to wrap third-party UI components |

---

## Headless UI Patterns

Headless components provide behavior without markup. The consumer provides all UI.

### Headless Dropdown

```ts
// composables/useDropdown.ts
import { ref, computed, onMounted, onUnmounted } from 'vue'

export function useDropdown<T>(options: { items: T[]; labelKey?: keyof T }) {
  const isOpen = ref(false)
  const selectedIndex = ref(-1)
  const selected = computed(() =>
    selectedIndex.value >= 0 ? options.items[selectedIndex.value] : null
  )

  const toggle = () => { isOpen.value = !isOpen.value }
  const select = (index: number) => {
    selectedIndex.value = index
    isOpen.value = false
  }

  const onKeydown = (e: KeyboardEvent) => {
    if (!isOpen.value) return
    switch (e.key) {
      case 'ArrowDown':
        e.preventDefault()
        selectedIndex.value = Math.min(selectedIndex.value + 1, options.items.length - 1)
        break
      case 'ArrowUp':
        e.preventDefault()
        selectedIndex.value = Math.max(selectedIndex.value - 1, 0)
        break
      case 'Enter':
        e.preventDefault()
        if (selectedIndex.value >= 0) select(selectedIndex.value)
        break
      case 'Escape':
        isOpen.value = false
        break
    }
  }

  onMounted(() => document.addEventListener('keydown', onKeydown))
  onUnmounted(() => document.removeEventListener('keydown', onKeydown))

  return {
    isOpen, selected, selectedIndex,
    toggle, select,
    triggerProps: computed(() => ({
      'aria-expanded': isOpen.value,
      'aria-haspopup': 'listbox' as const,
      onClick: toggle,
    })),
    listProps: computed(() => ({
      role: 'listbox' as const,
    })),
    getOptionProps: (index: number) => ({
      role: 'option' as const,
      'aria-selected': selectedIndex.value === index,
      onClick: () => select(index),
    }),
  }
}
```

```vue
<script setup lang="ts">
const items = ['Apple', 'Banana', 'Cherry']
const { isOpen, selected, triggerProps, listProps, getOptionProps } = useDropdown({ items })
</script>
<template>
  <div>
    <button v-bind="triggerProps">{{ selected ?? 'Pick a fruit' }}</button>
    <ul v-if="isOpen" v-bind="listProps">
      <li v-for="(item, i) in items" :key="i" v-bind="getOptionProps(i)">{{ item }}</li>
    </ul>
  </div>
</template>
```

### Headless Tabs

```ts
// composables/useTabs.ts
import { ref, computed } from 'vue'

export function useTabs<T extends string>(tabs: T[], initial?: T) {
  const activeTab = ref<T>(initial ?? tabs[0]) as Ref<T>

  return {
    activeTab: computed(() => activeTab.value),
    setTab: (tab: T) => { activeTab.value = tab },
    isActive: (tab: T) => activeTab.value === tab,
    getTabProps: (tab: T) => ({
      role: 'tab' as const,
      'aria-selected': activeTab.value === tab,
      onClick: () => { activeTab.value = tab },
    }),
    getPanelProps: (tab: T) => ({
      role: 'tabpanel' as const,
      hidden: activeTab.value !== tab,
    }),
  }
}
```

---

## State Machines with Composables

Model complex UI states explicitly. Eliminates impossible states.

### Finite State Machine Composable

```ts
// composables/useMachine.ts
import { ref, computed, readonly } from 'vue'

type MachineConfig<TState extends string, TEvent extends string> = {
  initial: TState
  states: Record<TState, {
    on?: Partial<Record<TEvent, TState>>
    enter?: () => void
    exit?: () => void
  }>
}

export function useMachine<TState extends string, TEvent extends string>(
  config: MachineConfig<TState, TEvent>
) {
  const current = ref<TState>(config.initial) as Ref<TState>

  config.states[config.initial]?.enter?.()

  const send = (event: TEvent) => {
    const stateConfig = config.states[current.value]
    const nextState = stateConfig.on?.[event]
    if (!nextState) return false

    stateConfig.exit?.()
    current.value = nextState
    config.states[nextState]?.enter?.()
    return true
  }

  const can = (event: TEvent) => {
    return !!config.states[current.value].on?.[event]
  }

  return {
    state: readonly(current),
    send,
    can,
    matches: (...states: TState[]) => states.includes(current.value),
  }
}
```

### Usage: Async Operation State Machine

```ts
const { state, send, matches } = useMachine({
  initial: 'idle' as const,
  states: {
    idle: { on: { FETCH: 'loading' } },
    loading: {
      on: { SUCCESS: 'success', ERROR: 'error' },
      enter: () => fetchData(),
    },
    success: { on: { FETCH: 'loading', RESET: 'idle' } },
    error: { on: { RETRY: 'loading', RESET: 'idle' } },
  },
})

// Template
// v-if="matches('loading')" → show spinner
// v-if="matches('error')"   → show retry button
// @click="send('FETCH')"    → trigger fetch
```

---

## Optimistic Updates

Update UI immediately, rollback on failure. Essential for responsive UIs.

```ts
// composables/useOptimistic.ts
import { ref, type Ref } from 'vue'

export function useOptimistic<T>(source: Ref<T>) {
  const optimistic = ref<T>() as Ref<T>
  const isPending = ref(false)
  const error = ref<Error | null>(null)

  // Resolve the current value (optimistic if pending, otherwise source)
  const value = computed(() => isPending.value ? optimistic.value : source.value)

  async function apply(
    newValue: T,
    mutation: () => Promise<void>
  ) {
    const previous = source.value
    optimistic.value = newValue
    isPending.value = true
    error.value = null

    try {
      await mutation()
      source.value = newValue // Commit
    } catch (e) {
      error.value = e as Error
      // Rollback — optimistic.value is discarded because isPending goes false
    } finally {
      isPending.value = false
    }
  }

  return { value, isPending, error, apply }
}
```

### Usage: Todo Toggle

```ts
const todos = ref<Todo[]>([])
const { value: optimisticTodos, apply } = useOptimistic(todos)

async function toggleTodo(id: number) {
  const updated = todos.value.map(t =>
    t.id === id ? { ...t, done: !t.done } : t
  )
  await apply(updated, () => api.patch(`/todos/${id}/toggle`))
}
```

---

## Virtual Scrolling Composable

Render only visible items for large lists. Avoids DOM bloat.

```ts
// composables/useVirtualScroll.ts
import { ref, computed, onMounted, onUnmounted, type Ref } from 'vue'

interface VirtualScrollOptions {
  itemHeight: number
  overscan?: number
}

export function useVirtualScroll<T>(
  items: Ref<T[]>,
  containerRef: Ref<HTMLElement | null>,
  options: VirtualScrollOptions
) {
  const { itemHeight, overscan = 5 } = options
  const scrollTop = ref(0)
  const containerHeight = ref(0)

  const totalHeight = computed(() => items.value.length * itemHeight)

  const startIndex = computed(() =>
    Math.max(0, Math.floor(scrollTop.value / itemHeight) - overscan)
  )

  const endIndex = computed(() =>
    Math.min(
      items.value.length,
      Math.ceil((scrollTop.value + containerHeight.value) / itemHeight) + overscan
    )
  )

  const visibleItems = computed(() =>
    items.value.slice(startIndex.value, endIndex.value).map((item, i) => ({
      item,
      index: startIndex.value + i,
      style: {
        position: 'absolute' as const,
        top: `${(startIndex.value + i) * itemHeight}px`,
        height: `${itemHeight}px`,
        width: '100%',
      },
    }))
  )

  const offsetY = computed(() => startIndex.value * itemHeight)

  function onScroll() {
    if (!containerRef.value) return
    scrollTop.value = containerRef.value.scrollTop
  }

  onMounted(() => {
    if (containerRef.value) {
      containerHeight.value = containerRef.value.clientHeight
      containerRef.value.addEventListener('scroll', onScroll, { passive: true })
    }
  })

  onUnmounted(() => {
    containerRef.value?.removeEventListener('scroll', onScroll)
  })

  return {
    visibleItems,
    totalHeight,
    offsetY,
    containerStyle: { overflow: 'auto', position: 'relative' as const },
    listStyle: computed(() => ({ height: `${totalHeight.value}px`, position: 'relative' as const })),
  }
}
```

### Usage

```vue
<script setup lang="ts">
const containerRef = ref<HTMLElement | null>(null)
const items = ref(Array.from({ length: 10000 }, (_, i) => ({ id: i, label: `Item ${i}` })))
const { visibleItems, containerStyle, listStyle } = useVirtualScroll(items, containerRef, {
  itemHeight: 40,
})
</script>
<template>
  <div ref="containerRef" :style="{ ...containerStyle, height: '400px' }">
    <div :style="listStyle">
      <div v-for="{ item, style } in visibleItems" :key="item.id" :style="style">
        {{ item.label }}
      </div>
    </div>
  </div>
</template>
```

---

## WebSocket Composable

Reactive WebSocket with auto-reconnect and typed messages.

```ts
// composables/useWebSocket.ts
import { ref, onUnmounted, type Ref } from 'vue'

interface UseWebSocketOptions {
  autoReconnect?: boolean
  maxRetries?: number
  retryInterval?: number
  onMessage?: (data: unknown) => void
  protocols?: string | string[]
}

type WSStatus = 'CONNECTING' | 'OPEN' | 'CLOSING' | 'CLOSED'

export function useWebSocket(url: string, options: UseWebSocketOptions = {}) {
  const {
    autoReconnect = true,
    maxRetries = 5,
    retryInterval = 3000,
  } = options

  const data = ref<unknown>(null)
  const status = ref<WSStatus>('CLOSED')
  const error = ref<Event | null>(null)
  let ws: WebSocket | null = null
  let retries = 0
  let retryTimer: ReturnType<typeof setTimeout> | null = null

  function connect() {
    if (ws?.readyState === WebSocket.OPEN) return
    status.value = 'CONNECTING'
    ws = new WebSocket(url, options.protocols)

    ws.onopen = () => {
      status.value = 'OPEN'
      retries = 0
    }

    ws.onmessage = (event) => {
      try {
        data.value = JSON.parse(event.data)
      } catch {
        data.value = event.data
      }
      options.onMessage?.(data.value)
    }

    ws.onerror = (e) => { error.value = e }

    ws.onclose = () => {
      status.value = 'CLOSED'
      if (autoReconnect && retries < maxRetries) {
        retries++
        retryTimer = setTimeout(connect, retryInterval)
      }
    }
  }

  function send(payload: unknown) {
    if (ws?.readyState !== WebSocket.OPEN) return false
    ws.send(typeof payload === 'string' ? payload : JSON.stringify(payload))
    return true
  }

  function close() {
    if (retryTimer) clearTimeout(retryTimer)
    retries = maxRetries // prevent reconnect
    ws?.close()
  }

  connect()
  onUnmounted(close)

  return { data, status, error, send, close, connect }
}
```

### Usage

```ts
const { data, status, send } = useWebSocket('wss://api.example.com/ws')

watch(data, (msg) => {
  if (msg?.type === 'notification') notifications.value.push(msg)
})

function sendMessage(text: string) {
  send({ type: 'chat', text })
}
```

---

## Form Validation Composable (vee-validate)

Integrate vee-validate with Composition API for declarative validation.

### Setup with Zod

```ts
import { useForm, useField } from 'vee-validate'
import { toTypedSchema } from '@vee-validate/zod'
import { z } from 'zod'

const schema = toTypedSchema(
  z.object({
    email: z.string().email('Invalid email'),
    password: z.string().min(8, 'Min 8 characters'),
    confirmPassword: z.string(),
  }).refine(d => d.password === d.confirmPassword, {
    message: 'Passwords must match',
    path: ['confirmPassword'],
  })
)
```

### Form Composable Integration

```vue
<script setup lang="ts">
const { handleSubmit, errors, resetForm, meta } = useForm({
  validationSchema: schema,
  initialValues: { email: '', password: '', confirmPassword: '' },
})

const { value: email } = useField<string>('email')
const { value: password } = useField<string>('password')
const { value: confirmPassword } = useField<string>('confirmPassword')

const onSubmit = handleSubmit(async (values) => {
  await api.register(values)
})
</script>
<template>
  <form @submit="onSubmit">
    <input v-model="email" />
    <span v-if="errors.email">{{ errors.email }}</span>

    <input v-model="password" type="password" />
    <span v-if="errors.password">{{ errors.password }}</span>

    <input v-model="confirmPassword" type="password" />
    <span v-if="errors.confirmPassword">{{ errors.confirmPassword }}</span>

    <button :disabled="!meta.valid || meta.pending" type="submit">Register</button>
  </form>
</template>
```

### Custom Composable Wrapping vee-validate

```ts
export function useLoginForm() {
  const { handleSubmit, errors, isSubmitting } = useForm({
    validationSchema: toTypedSchema(z.object({
      email: z.string().email(),
      password: z.string().min(1, 'Required'),
    })),
  })

  const { value: email } = useField<string>('email')
  const { value: password } = useField<string>('password')

  const submit = handleSubmit(async (values) => {
    await authStore.login(values)
  })

  return { email, password, errors, isSubmitting, submit }
}
```

---

## Debounced and Throttled Computed

### Debounced Ref

```ts
import { ref, watch } from 'vue'

export function useDebouncedRef<T>(source: Ref<T>, delay = 300) {
  const debounced = ref(source.value) as Ref<T>
  let timer: ReturnType<typeof setTimeout>

  watch(source, (val) => {
    clearTimeout(timer)
    timer = setTimeout(() => { debounced.value = val }, delay)
  })

  return debounced
}

// Usage
const search = ref('')
const debouncedSearch = useDebouncedRef(search, 500)
watch(debouncedSearch, (q) => fetchResults(q))
```

### Throttled Computed

```ts
export function useThrottledComputed<T>(getter: () => T, interval = 200) {
  const value = ref<T>(getter()) as Ref<T>
  let lastRun = 0
  let timer: ReturnType<typeof setTimeout> | null = null

  watchEffect(() => {
    const result = getter()
    const now = Date.now()
    if (now - lastRun >= interval) {
      value.value = result
      lastRun = now
    } else if (!timer) {
      timer = setTimeout(() => {
        value.value = getter()
        lastRun = Date.now()
        timer = null
      }, interval - (now - lastRun))
    }
  })

  return readonly(value)
}
```

### VueUse Shortcut

```ts
import { refDebounced, refThrottled } from '@vueuse/core'

const search = ref('')
const debouncedSearch = refDebounced(search, 500)
const throttledScroll = refThrottled(scrollY, 100)
```

---

## effectScope for Library Authors

`effectScope` groups reactive effects for collective disposal. Essential for libraries/composables that create many watchers.

### Basic Usage

```ts
import { effectScope, onScopeDispose } from 'vue'

const scope = effectScope()

scope.run(() => {
  const counter = ref(0)
  const doubled = computed(() => counter.value * 2)

  watch(counter, () => console.log('changed'))
  watchEffect(() => console.log(doubled.value))

  // onScopeDispose runs when scope.stop() is called
  onScopeDispose(() => {
    console.log('cleaning up')
  })
})

scope.stop() // All effects disposed, onScopeDispose callbacks run
```

### Shared Composable Pattern

Create a composable that shares state across consumers. Only one instance exists.

```ts
import { effectScope, type EffectScope } from 'vue'

function createSharedComposable<T>(composable: () => T): () => T {
  let subscribers = 0
  let state: T | undefined
  let scope: EffectScope | undefined

  return () => {
    subscribers++
    if (!scope) {
      scope = effectScope(true) // detached
      state = scope.run(composable)!
    }

    // getCurrentScope ensures cleanup when consumer unmounts
    if (getCurrentScope()) {
      onScopeDispose(() => {
        subscribers--
        if (subscribers <= 0) {
          scope?.stop()
          scope = undefined
          state = undefined
        }
      })
    }

    return state!
  }
}

// Usage — all components share the same mouse position
export const useSharedMouse = createSharedComposable(() => {
  const x = ref(0)
  const y = ref(0)
  useEventListener(window, 'mousemove', (e) => {
    x.value = e.clientX
    y.value = e.clientY
  })
  return { x, y }
})
```

### Nested Scopes

```ts
const parentScope = effectScope()

parentScope.run(() => {
  const childScope = effectScope() // auto-collected by parent

  childScope.run(() => {
    watch(source, handler)
  })

  // childScope is stopped when parentScope.stop() is called

  const detachedScope = effectScope(true) // NOT auto-collected
  // Must be manually stopped
})
```

---

## Dependency Injection Patterns

### Typed Injection Keys with Factory Defaults

```ts
// injection-keys.ts
import type { InjectionKey, Ref } from 'vue'

export interface NotificationService {
  notify: (msg: string, type?: 'info' | 'error' | 'success') => void
  notifications: Ref<Notification[]>
  dismiss: (id: string) => void
}

export const NotificationKey: InjectionKey<NotificationService> = Symbol('notification')
```

### Provider Component Pattern

```vue
<!-- NotificationProvider.vue -->
<script setup lang="ts">
import { provide, ref } from 'vue'
import { NotificationKey, type NotificationService } from '@/injection-keys'

const notifications = ref<Notification[]>([])

const service: NotificationService = {
  notifications,
  notify(msg, type = 'info') {
    const id = crypto.randomUUID()
    notifications.value.push({ id, msg, type })
    setTimeout(() => service.dismiss(id), 5000)
  },
  dismiss(id) {
    notifications.value = notifications.value.filter(n => n.id !== id)
  },
}

provide(NotificationKey, service)
</script>
<template>
  <slot />
  <TransitionGroup name="notification">
    <div v-for="n in notifications" :key="n.id" :class="n.type">
      {{ n.msg }}
    </div>
  </TransitionGroup>
</template>
```

### Consumer Composable with Validation

```ts
// composables/useNotification.ts
export function useNotification(): NotificationService {
  const service = inject(NotificationKey)
  if (!service) {
    throw new Error('useNotification() requires <NotificationProvider> ancestor')
  }
  return service
}
```

### Plugin-based Injection

```ts
// plugins/api.ts
import type { InjectionKey } from 'vue'
import type { App } from 'vue'

export interface ApiClient {
  get: <T>(url: string) => Promise<T>
  post: <T>(url: string, body: unknown) => Promise<T>
}

export const ApiKey: InjectionKey<ApiClient> = Symbol('api')

export function createApiPlugin(baseUrl: string) {
  const client: ApiClient = {
    async get(url) {
      const res = await fetch(`${baseUrl}${url}`)
      return res.json()
    },
    async post(url, body) {
      const res = await fetch(`${baseUrl}${url}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      })
      return res.json()
    },
  }

  return {
    install(app: App) {
      app.provide(ApiKey, client)
    },
  }
}

// main.ts
app.use(createApiPlugin('https://api.example.com'))

// Any component
const api = inject(ApiKey)!
const users = await api.get<User[]>('/users')
```

### Hierarchical Injection (Override at Any Level)

```ts
// Grandparent provides base theme
provide(ThemeKey, { primary: '#007bff', mode: 'light' })

// Parent overrides for a section
const parentTheme = inject(ThemeKey)!
provide(ThemeKey, { ...parentTheme, mode: 'dark' }) // override mode, keep primary

// Child gets the overridden theme
const theme = inject(ThemeKey) // { primary: '#007bff', mode: 'dark' }
```
