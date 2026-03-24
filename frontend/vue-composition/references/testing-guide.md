# Testing Vue Composition API

> Comprehensive guide for testing Vue 3 components and composables with Vitest and @vue/test-utils.

## Table of Contents

- [Setup and Configuration](#setup-and-configuration)
- [Component Testing Basics](#component-testing-basics)
- [Testing Composables in Isolation](#testing-composables-in-isolation)
- [Mocking Composables](#mocking-composables)
- [Testing Provide/Inject](#testing-provideinject)
- [Testing Async Setup](#testing-async-setup)
- [Vitest Integration](#vitest-integration)
- [Component Testing vs Composable Unit Testing](#component-testing-vs-composable-unit-testing)
- [Snapshot Testing with Composition API](#snapshot-testing-with-composition-api)
- [Testing Pinia Stores](#testing-pinia-stores)
- [Testing Patterns Cookbook](#testing-patterns-cookbook)

---

## Setup and Configuration

### Install Dependencies

```bash
npm install -D vitest @vue/test-utils @pinia/testing happy-dom
```

### Vitest Configuration

```ts
// vitest.config.ts
import { defineConfig } from 'vitest/config'
import vue from '@vitejs/plugin-vue'
import { fileURLToPath } from 'node:url'

export default defineConfig({
  plugins: [vue()],
  test: {
    environment: 'happy-dom', // or 'jsdom'
    globals: true,            // no need to import describe, it, expect
    setupFiles: ['./src/test/setup.ts'],
    include: ['src/**/*.{test,spec}.{ts,tsx}'],
    coverage: {
      provider: 'v8',
      include: ['src/**/*.{ts,vue}'],
      exclude: ['src/test/**', 'src/**/*.d.ts'],
    },
  },
  resolve: {
    alias: {
      '@': fileURLToPath(new URL('./src', import.meta.url)),
    },
  },
})
```

### Test Setup File

```ts
// src/test/setup.ts
import { config } from '@vue/test-utils'
import { createTestingPinia } from '@pinia/testing'

// Global plugins for all tests
config.global.plugins = [
  createTestingPinia({ createSpy: vi.fn }),
]

// Global stubs
config.global.stubs = {
  Teleport: true,
  Transition: false,
  TransitionGroup: false,
}
```

---

## Component Testing Basics

### Mounting with script setup

```ts
import { mount } from '@vue/test-utils'
import Counter from '@/components/Counter.vue'

describe('Counter', () => {
  it('renders initial count', () => {
    const wrapper = mount(Counter, {
      props: { initial: 5 },
    })
    expect(wrapper.text()).toContain('5')
  })

  it('increments on click', async () => {
    const wrapper = mount(Counter)
    await wrapper.find('[data-testid="increment"]').trigger('click')
    expect(wrapper.text()).toContain('1')
  })

  it('emits update event', async () => {
    const wrapper = mount(Counter)
    await wrapper.find('button').trigger('click')
    expect(wrapper.emitted('update')).toHaveLength(1)
    expect(wrapper.emitted('update')![0]).toEqual([1])
  })
})
```

### Props and Slots

```ts
it('renders with slots', () => {
  const wrapper = mount(Card, {
    props: { title: 'Hello' },
    slots: {
      default: '<p>Body content</p>',
      footer: '<button>Action</button>',
    },
  })
  expect(wrapper.find('p').text()).toBe('Body content')
  expect(wrapper.find('button').text()).toBe('Action')
})

it('renders scoped slots', () => {
  const wrapper = mount(DataList, {
    props: { items: ['a', 'b', 'c'] },
    slots: {
      item: `<template #item="{ item, index }">
        <span>{{ index }}: {{ item }}</span>
      </template>`,
    },
  })
  expect(wrapper.text()).toContain('0: a')
})
```

### v-model Testing

```ts
it('supports v-model', async () => {
  const wrapper = mount(TextInput, {
    props: {
      modelValue: 'hello',
      'onUpdate:modelValue': (val: string) => wrapper.setProps({ modelValue: val }),
    },
  })

  await wrapper.find('input').setValue('world')
  expect(wrapper.props('modelValue')).toBe('world')
  expect(wrapper.emitted('update:modelValue')![0]).toEqual(['world'])
})
```

### Testing defineModel (Vue 3.4+)

```ts
it('two-way binds with defineModel', async () => {
  const wrapper = mount(SearchInput, {
    props: {
      modelValue: '',
      'onUpdate:modelValue': (e: string) => wrapper.setProps({ modelValue: e }),
    },
  })
  const input = wrapper.find('input')
  await input.setValue('vue')
  expect(wrapper.props('modelValue')).toBe('vue')
})
```

---

## Testing Composables in Isolation

### Simple Composables (No Lifecycle)

Test directly without mounting a component:

```ts
// composables/useCounter.ts
export function useCounter(initial = 0) {
  const count = ref(initial)
  const increment = () => count.value++
  const decrement = () => count.value--
  const reset = () => { count.value = initial }
  return { count, increment, decrement, reset }
}

// composables/__tests__/useCounter.test.ts
import { useCounter } from '../useCounter'

describe('useCounter', () => {
  it('starts at initial value', () => {
    const { count } = useCounter(10)
    expect(count.value).toBe(10)
  })

  it('increments and decrements', () => {
    const { count, increment, decrement } = useCounter()
    increment()
    expect(count.value).toBe(1)
    decrement()
    expect(count.value).toBe(0)
  })

  it('resets to initial', () => {
    const { count, increment, reset } = useCounter(5)
    increment(); increment()
    reset()
    expect(count.value).toBe(5)
  })
})
```

### Composables with Lifecycle Hooks

Use a `withSetup` helper to provide component context:

```ts
// test/helpers.ts
import { createApp, type App } from 'vue'

export function withSetup<T>(composable: () => T): { result: T; app: App } {
  let result!: T
  const app = createApp({
    setup() {
      result = composable()
      return () => {}
    },
  })
  app.mount(document.createElement('div'))
  return { result, app }
}
```

```ts
// composables/useWindowSize.ts
export function useWindowSize() {
  const width = ref(0)
  const height = ref(0)

  const update = () => {
    width.value = window.innerWidth
    height.value = window.innerHeight
  }

  onMounted(() => {
    update()
    window.addEventListener('resize', update)
  })
  onUnmounted(() => window.removeEventListener('resize', update))

  return { width, height }
}

// Test
describe('useWindowSize', () => {
  it('reads window dimensions on mount', () => {
    // happy-dom sets defaults; override if needed
    Object.defineProperty(window, 'innerWidth', { value: 1024, writable: true })
    Object.defineProperty(window, 'innerHeight', { value: 768, writable: true })

    const { result, app } = withSetup(() => useWindowSize())
    expect(result.width.value).toBe(1024)
    expect(result.height.value).toBe(768)
    app.unmount() // triggers cleanup
  })
})
```

### Composables with Reactive Inputs

```ts
// composables/useSearch.ts
export function useSearch<T>(items: Ref<T[]>, query: Ref<string>, key: keyof T) {
  return computed(() =>
    items.value.filter(item =>
      String(item[key]).toLowerCase().includes(query.value.toLowerCase())
    )
  )
}

// Test
it('filters items by query', () => {
  const items = ref([{ name: 'Vue' }, { name: 'React' }, { name: 'Svelte' }])
  const query = ref('v')
  const results = useSearch(items, query, 'name')

  expect(results.value).toHaveLength(1)
  expect(results.value[0].name).toBe('Vue')

  query.value = '' // all items
  expect(results.value).toHaveLength(3)
})
```

---

## Mocking Composables

### vi.mock for Module-Level Mocking

```ts
// Component uses useFetch internally
import { mount } from '@vue/test-utils'
import UserList from '@/components/UserList.vue'
import { useFetch } from '@/composables/useFetch'

vi.mock('@/composables/useFetch', () => ({
  useFetch: vi.fn(),
}))

describe('UserList', () => {
  it('renders users from fetch', () => {
    vi.mocked(useFetch).mockReturnValue({
      data: ref([{ id: 1, name: 'Ada' }]),
      loading: ref(false),
      error: ref(null),
      execute: vi.fn(),
    })

    const wrapper = mount(UserList)
    expect(wrapper.text()).toContain('Ada')
  })

  it('shows loading state', () => {
    vi.mocked(useFetch).mockReturnValue({
      data: ref(null),
      loading: ref(true),
      error: ref(null),
      execute: vi.fn(),
    })

    const wrapper = mount(UserList)
    expect(wrapper.find('[data-testid="spinner"]').exists()).toBe(true)
  })
})
```

### Partial Mocking

```ts
// Mock only specific exports
vi.mock('@/composables/useAuth', async () => {
  const actual = await vi.importActual<typeof import('@/composables/useAuth')>('@/composables/useAuth')
  return {
    ...actual,
    useAuth: vi.fn(() => ({
      ...actual.useAuth(),
      login: vi.fn().mockResolvedValue(true), // Override just login
    })),
  }
})
```

### Inline Composable Mocking (No vi.mock)

```ts
// For composables injected via provide/inject
it('works with mocked dependency', () => {
  const mockAuth = {
    user: ref({ name: 'Test User' }),
    isAuthenticated: computed(() => true),
    login: vi.fn(),
    logout: vi.fn(),
  }

  const wrapper = mount(Profile, {
    global: {
      provide: {
        [AuthKey as symbol]: mockAuth,
      },
    },
  })

  expect(wrapper.text()).toContain('Test User')
})
```

---

## Testing Provide/Inject

### Providing Values in Tests

```ts
import { mount } from '@vue/test-utils'
import ThemeConsumer from '@/components/ThemeConsumer.vue'
import { ThemeKey } from '@/injection-keys'

describe('ThemeConsumer', () => {
  it('uses provided theme', () => {
    const wrapper = mount(ThemeConsumer, {
      global: {
        provide: {
          [ThemeKey as symbol]: ref('dark'),
        },
      },
    })
    expect(wrapper.classes()).toContain('dark')
  })

  it('uses default when no provider', () => {
    const wrapper = mount(ThemeConsumer)
    expect(wrapper.classes()).toContain('light') // default
  })
})
```

### Testing Provider + Consumer Together

```ts
import ProviderWrapper from '@/components/NotificationProvider.vue'
import Consumer from '@/components/NotificationConsumer.vue'

it('provider passes data to consumer', async () => {
  const wrapper = mount(ProviderWrapper, {
    slots: {
      default: () => h(Consumer),
    },
  })

  // Trigger notification via consumer
  await wrapper.findComponent(Consumer).find('button').trigger('click')
  expect(wrapper.text()).toContain('Notification sent')
})
```

---

## Testing Async Setup

### Components with Top-Level Await

Components using `await` in `<script setup>` require `<Suspense>`.

```ts
import { mount, flushPromises } from '@vue/test-utils'
import { defineComponent, h, Suspense } from 'vue'
import AsyncUserProfile from '@/components/AsyncUserProfile.vue'

// Helper to wrap in Suspense
function mountSuspense(component: any, options = {}) {
  return mount(
    defineComponent({
      render() {
        return h(Suspense, null, {
          default: () => h(component, options),
          fallback: () => h('div', 'Loading...'),
        })
      },
    })
  )
}

describe('AsyncUserProfile', () => {
  beforeEach(() => {
    vi.spyOn(global, 'fetch').mockResolvedValue({
      json: () => Promise.resolve({ name: 'Ada', role: 'Engineer' }),
    } as Response)
  })

  it('shows fallback then content', async () => {
    const wrapper = mountSuspense(AsyncUserProfile)
    expect(wrapper.text()).toContain('Loading...')

    await flushPromises()
    expect(wrapper.text()).toContain('Ada')
  })
})
```

### Testing Async Composables

```ts
import { flushPromises } from '@vue/test-utils'

describe('useFetch', () => {
  it('fetches data and updates state', async () => {
    vi.spyOn(global, 'fetch').mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({ id: 1, name: 'Test' }),
    } as Response)

    const { data, loading, error } = useFetch<{ id: number; name: string }>('/api/test')
    expect(loading.value).toBe(true)

    await flushPromises()

    expect(loading.value).toBe(false)
    expect(error.value).toBeNull()
    expect(data.value).toEqual({ id: 1, name: 'Test' })
  })

  it('handles fetch error', async () => {
    vi.spyOn(global, 'fetch').mockRejectedValue(new Error('Network error'))

    const { data, error } = useFetch('/api/test')
    await flushPromises()

    expect(data.value).toBeNull()
    expect(error.value?.message).toBe('Network error')
  })
})
```

---

## Vitest Integration

### Test Utilities

```ts
// src/test/utils.ts
import { mount, type MountingOptions } from '@vue/test-utils'
import { createTestingPinia } from '@pinia/testing'
import { type Component, h, Suspense } from 'vue'

// Standard mount with Pinia
export function mountWithPinia<T extends Component>(
  component: T,
  options: MountingOptions<any> = {}
) {
  return mount(component, {
    ...options,
    global: {
      ...options.global,
      plugins: [
        createTestingPinia({ createSpy: vi.fn }),
        ...(options.global?.plugins ?? []),
      ],
    },
  })
}

// Mount async component in Suspense
export async function mountAsync<T extends Component>(
  component: T,
  options: MountingOptions<any> = {}
) {
  const wrapper = mount(
    defineComponent({
      render: () => h(Suspense, null, {
        default: () => h(component as any, options.props),
        fallback: () => h('div', 'Loading...'),
      }),
    }),
    { global: options.global }
  )
  await flushPromises()
  return wrapper
}
```

### Custom Matchers

```ts
// src/test/matchers.ts
import { expect } from 'vitest'

expect.extend({
  toBeVisible(wrapper) {
    const element = wrapper.element ?? wrapper
    const isVisible = element.style.display !== 'none'
      && !element.hasAttribute('hidden')
      && element.style.visibility !== 'hidden'

    return {
      pass: isVisible,
      message: () => `expected element to ${isVisible ? 'not ' : ''}be visible`,
    }
  },
})

// Usage: expect(wrapper.find('.modal')).toBeVisible()
```

### Fake Timers

```ts
describe('useDebounce', () => {
  beforeEach(() => { vi.useFakeTimers() })
  afterEach(() => { vi.useRealTimers() })

  it('debounces value updates', () => {
    const source = ref('initial')
    const debounced = useDebouncedRef(source, 300)

    source.value = 'changed'
    expect(debounced.value).toBe('initial') // not updated yet

    vi.advanceTimersByTime(300)
    expect(debounced.value).toBe('changed') // now updated
  })
})
```

---

## Component Testing vs Composable Unit Testing

### When to Test What

| Test composable directly | Test via component |
|---|---|
| Pure logic (math, transforms) | Template rendering |
| State management | User interactions |
| No DOM/lifecycle deps | Integration with other components |
| Reused across components | Component-specific behavior |
| Easy to isolate | Needs global plugins |

### Composable Unit Test

```ts
// Fast, isolated, no DOM
describe('useFilter', () => {
  it('filters items by predicate', () => {
    const items = ref([1, 2, 3, 4, 5])
    const predicate = ref((n: number) => n > 3)
    const filtered = useFilter(items, predicate)

    expect(filtered.value).toEqual([4, 5])
    predicate.value = (n) => n % 2 === 0
    expect(filtered.value).toEqual([2, 4])
  })
})
```

### Component Integration Test

```ts
// Tests composable + template + interactions together
describe('FilteredList', () => {
  it('filters list when search input changes', async () => {
    const wrapper = mount(FilteredList, {
      props: { items: ['Apple', 'Banana', 'Cherry'] },
    })

    await wrapper.find('input').setValue('an')
    const items = wrapper.findAll('li')
    expect(items).toHaveLength(1)
    expect(items[0].text()).toBe('Banana')
  })
})
```

---

## Snapshot Testing with Composition API

### Basic Snapshots

```ts
it('matches snapshot', () => {
  const wrapper = mount(UserCard, {
    props: { name: 'Ada', role: 'Engineer' },
  })
  expect(wrapper.html()).toMatchSnapshot()
})
```

### Inline Snapshots

```ts
it('renders correctly', () => {
  const wrapper = mount(Badge, { props: { label: 'New' } })
  expect(wrapper.html()).toMatchInlineSnapshot(`
    "<span class="badge badge-default">New</span>"
  `)
})
```

### Snapshot Tips for Composition API

```ts
// Avoid snapshots with dynamic data (dates, IDs)
// ❌ Fragile — snapshot changes every run
const wrapper = mount(TimestampedItem)
expect(wrapper.html()).toMatchSnapshot()

// ✅ Mock dynamic values first
vi.setSystemTime(new Date('2024-01-01'))
const wrapper = mount(TimestampedItem)
expect(wrapper.html()).toMatchSnapshot()

// ✅ Or snapshot only stable parts
expect(wrapper.find('.content').html()).toMatchSnapshot()
```

---

## Testing Pinia Stores

### Setup with @pinia/testing

```ts
import { setActivePinia, createPinia } from 'pinia'
import { createTestingPinia } from '@pinia/testing'

describe('useCartStore', () => {
  beforeEach(() => {
    setActivePinia(createPinia()) // Real Pinia for unit tests
  })

  it('adds items to cart', () => {
    const store = useCartStore()
    store.addItem({ id: 1, name: 'Widget', price: 10, qty: 1 })

    expect(store.items).toHaveLength(1)
    expect(store.total).toBe(10)
  })

  it('computes total correctly', () => {
    const store = useCartStore()
    store.addItem({ id: 1, name: 'A', price: 10, qty: 2 })
    store.addItem({ id: 2, name: 'B', price: 5, qty: 1 })

    expect(store.total).toBe(25)
  })
})
```

### Testing Stores in Components

```ts
describe('CartView with store', () => {
  it('renders cart items', () => {
    const wrapper = mount(CartView, {
      global: {
        plugins: [
          createTestingPinia({
            initialState: {
              cart: {
                items: [
                  { id: 1, name: 'Widget', price: 10, qty: 1 },
                ],
              },
            },
          }),
        ],
      },
    })

    expect(wrapper.text()).toContain('Widget')
    expect(wrapper.text()).toContain('$10')
  })

  it('calls addItem on button click', async () => {
    const pinia = createTestingPinia({ createSpy: vi.fn })
    const wrapper = mount(CartView, {
      global: { plugins: [pinia] },
    })

    const store = useCartStore()
    await wrapper.find('[data-testid="add-item"]').trigger('click')
    expect(store.addItem).toHaveBeenCalled()
  })
})
```

### Testing Store Actions with API Calls

```ts
describe('useAuthStore actions', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  it('login sets user and token', async () => {
    vi.spyOn(global, 'fetch').mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({ token: 'abc123', user: { name: 'Ada' } }),
    } as Response)

    const store = useAuthStore()
    await store.login({ email: 'ada@test.com', password: 'pass' })

    expect(store.token).toBe('abc123')
    expect(store.user?.name).toBe('Ada')
    expect(store.isLoggedIn).toBe(true)
  })

  it('login handles errors', async () => {
    vi.spyOn(global, 'fetch').mockRejectedValue(new Error('Network error'))

    const store = useAuthStore()
    await expect(store.login({ email: '', password: '' })).rejects.toThrow()
    expect(store.isLoggedIn).toBe(false)
  })
})
```

### Testing Store Subscriptions

```ts
it('triggers $subscribe on state change', () => {
  const store = useCartStore()
  const callback = vi.fn()
  store.$subscribe(callback)

  store.addItem({ id: 1, name: 'A', price: 10, qty: 1 })

  expect(callback).toHaveBeenCalledWith(
    expect.objectContaining({ type: 'direct' }),
    expect.objectContaining({ items: expect.any(Array) })
  )
})
```

---

## Testing Patterns Cookbook

### Testing Router-Dependent Components

```ts
import { createRouter, createMemoryHistory } from 'vue-router'

function mountWithRouter(component: Component, route = '/') {
  const router = createRouter({
    history: createMemoryHistory(),
    routes: [
      { path: '/', component: { template: '<div />' } },
      { path: '/users/:id', component: { template: '<div />' } },
    ],
  })
  router.push(route)

  return mount(component, {
    global: { plugins: [router] },
  })
}

it('shows user details for route param', async () => {
  const wrapper = mountWithRouter(UserDetail, '/users/42')
  await wrapper.router.isReady()
  expect(wrapper.text()).toContain('User #42')
})
```

### Testing Teleport Content

```ts
it('renders modal in teleport', () => {
  const wrapper = mount(Modal, {
    props: { show: true },
    global: {
      stubs: { Teleport: true }, // Renders inline instead of teleporting
    },
  })
  expect(wrapper.find('.modal-content').exists()).toBe(true)
})
```

### Testing Error Boundaries

```ts
it('catches and displays errors', async () => {
  const BrokenComponent = defineComponent({
    setup() { throw new Error('Oops') },
    template: '<div />',
  })

  const wrapper = mount(ErrorBoundary, {
    slots: { default: () => h(BrokenComponent) },
  })

  await flushPromises()
  expect(wrapper.text()).toContain('Something went wrong')
})
```

### Testing Watchers

```ts
it('watcher reacts to prop changes', async () => {
  const wrapper = mount(SearchResults, {
    props: { query: 'vue' },
  })

  // Mock fetch for new query
  vi.spyOn(global, 'fetch').mockResolvedValue({
    json: () => Promise.resolve([{ id: 1, title: 'React guide' }]),
  } as Response)

  await wrapper.setProps({ query: 'react' })
  await flushPromises()

  expect(wrapper.text()).toContain('React guide')
})
```

### Testing nextTick and DOM Updates

```ts
it('updates DOM after state change', async () => {
  const wrapper = mount(Counter)

  wrapper.vm.count = 5  // Direct state change (if exposed)
  await nextTick()       // Wait for DOM update

  expect(wrapper.find('.count').text()).toBe('5')
})
```
