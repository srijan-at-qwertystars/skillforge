// ============================================================================
// vitest-setup.ts — Vitest configuration for Vue + @vue/test-utils
// ============================================================================
// Drop into: src/test/setup.ts (or wherever vitest.config.ts points setupFiles)
//
// Includes:
//   - Global test-utils configuration
//   - Pinia testing setup
//   - Component mounting helpers
//   - Composable testing utilities
//   - Common mocks (IntersectionObserver, ResizeObserver, matchMedia)
// ============================================================================

import { config } from '@vue/test-utils'
import { createTestingPinia } from '@pinia/testing'
import {
  createApp,
  defineComponent,
  h,
  Suspense,
  nextTick,
  type App,
  type Component,
} from 'vue'
import { mount, flushPromises, type MountingOptions } from '@vue/test-utils'
import { vi } from 'vitest'

// ============================================================================
// Global Test Configuration
// ============================================================================

// Default plugins for all component mounts
config.global.plugins = [
  createTestingPinia({ createSpy: vi.fn }),
]

// Stub Teleport by default (renders content inline)
config.global.stubs = {
  Teleport: true,
}

// ============================================================================
// Browser API Mocks
// ============================================================================

// IntersectionObserver
class MockIntersectionObserver {
  readonly root = null
  readonly rootMargin = ''
  readonly thresholds: readonly number[] = []

  constructor(private callback: IntersectionObserverCallback) {}
  observe() {}
  unobserve() {}
  disconnect() {}
  takeRecords(): IntersectionObserverEntry[] { return [] }
}
globalThis.IntersectionObserver = MockIntersectionObserver as unknown as typeof IntersectionObserver

// ResizeObserver
class MockResizeObserver {
  constructor(private callback: ResizeObserverCallback) {}
  observe() {}
  unobserve() {}
  disconnect() {}
}
globalThis.ResizeObserver = MockResizeObserver as unknown as typeof ResizeObserver

// matchMedia
Object.defineProperty(window, 'matchMedia', {
  writable: true,
  value: vi.fn().mockImplementation((query: string) => ({
    matches: false,
    media: query,
    onchange: null,
    addListener: vi.fn(),
    removeListener: vi.fn(),
    addEventListener: vi.fn(),
    removeEventListener: vi.fn(),
    dispatchEvent: vi.fn(),
  })),
})

// scrollTo
Element.prototype.scrollTo = vi.fn() as unknown as typeof Element.prototype.scrollTo
window.scrollTo = vi.fn() as unknown as typeof window.scrollTo

// ============================================================================
// Component Mounting Helpers
// ============================================================================

/**
 * Mount a component with Pinia pre-configured.
 *
 * @example
 * const wrapper = mountWithPinia(MyComponent, {
 *   props: { title: 'Hello' },
 * })
 */
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
      stubs: {
        Teleport: true,
        ...(options.global?.stubs as Record<string, unknown> ?? {}),
      },
    },
  })
}

/**
 * Mount a component that uses top-level await (requires Suspense).
 * Automatically waits for async resolution.
 *
 * @example
 * const wrapper = await mountAsync(AsyncComponent, {
 *   props: { userId: 1 },
 * })
 */
export async function mountAsync<T extends Component>(
  component: T,
  options: MountingOptions<any> = {}
) {
  const wrapper = mount(
    defineComponent({
      name: 'SuspenseWrapper',
      render() {
        return h(Suspense, null, {
          default: () => h(component as any, options.props ?? {}),
          fallback: () => h('div', { 'data-testid': 'suspense-fallback' }, 'Loading...'),
        })
      },
    }),
    {
      global: {
        ...options.global,
        plugins: [
          createTestingPinia({ createSpy: vi.fn }),
          ...(options.global?.plugins ?? []),
        ],
      },
    }
  )
  await flushPromises()
  return wrapper
}

/**
 * Mount a component with router mock.
 *
 * @example
 * const wrapper = mountWithRouter(MyComponent, {
 *   route: { params: { id: '42' } },
 * })
 */
export function mountWithRouter<T extends Component>(
  component: T,
  options: MountingOptions<any> & {
    route?: Partial<{
      path: string
      params: Record<string, string>
      query: Record<string, string>
      hash: string
    }>
  } = {}
) {
  const { route: routeOverrides = {}, ...mountOptions } = options

  const mockRoute = {
    path: '/',
    params: {},
    query: {},
    hash: '',
    ...routeOverrides,
  }

  const mockRouter = {
    push: vi.fn(),
    replace: vi.fn(),
    go: vi.fn(),
    back: vi.fn(),
    forward: vi.fn(),
    currentRoute: { value: mockRoute },
    resolve: vi.fn(),
    isReady: vi.fn(() => Promise.resolve()),
  }

  return mount(component, {
    ...mountOptions,
    global: {
      ...mountOptions.global,
      mocks: {
        $route: mockRoute,
        $router: mockRouter,
        ...(mountOptions.global?.mocks ?? {}),
      },
    },
  })
}

// ============================================================================
// Composable Testing Utilities
// ============================================================================

/**
 * Test a composable that requires component lifecycle context.
 * Creates a minimal app, runs the composable in setup(), and returns the result.
 *
 * @example
 * const { result, app } = withSetup(() => useMyComposable())
 * expect(result.data.value).toBe(null)
 * app.unmount() // triggers onUnmounted
 */
export function withSetup<T>(composable: () => T): { result: T; app: App } {
  let result!: T
  const app = createApp({
    setup() {
      result = composable()
      return () => h('div')
    },
  })
  app.use(createTestingPinia({ createSpy: vi.fn }))
  app.mount(document.createElement('div'))
  return { result, app }
}

/**
 * Test a composable with provide/inject dependencies.
 *
 * @example
 * const { result, app } = withSetupAndProvide(
 *   () => useTheme(),
 *   { [ThemeKey]: ref('dark') }
 * )
 */
export function withSetupAndProvide<T>(
  composable: () => T,
  provides: Record<string | symbol, unknown>
): { result: T; app: App } {
  let result!: T
  const app = createApp({
    setup() {
      result = composable()
      return () => h('div')
    },
  })

  // Register provides before mounting
  for (const [key, value] of Object.entries(provides)) {
    app.provide(key, value)
  }
  for (const sym of Object.getOwnPropertySymbols(provides)) {
    app.provide(sym, provides[sym as unknown as string])
  }

  app.use(createTestingPinia({ createSpy: vi.fn }))
  app.mount(document.createElement('div'))
  return { result, app }
}

// ============================================================================
// Async Test Helpers
// ============================================================================

/**
 * Wait for a specific number of Vue update ticks.
 */
export async function waitTicks(count = 1): Promise<void> {
  for (let i = 0; i < count; i++) {
    await nextTick()
  }
}

/**
 * Wait for a condition to become true, with timeout.
 *
 * @example
 * await waitFor(() => wrapper.find('.loaded').exists())
 */
export async function waitFor(
  condition: () => boolean,
  options: { timeout?: number; interval?: number } = {}
): Promise<void> {
  const { timeout = 5000, interval = 50 } = options
  const start = Date.now()

  while (!condition()) {
    if (Date.now() - start > timeout) {
      throw new Error(`waitFor timed out after ${timeout}ms`)
    }
    await new Promise(resolve => setTimeout(resolve, interval))
    await nextTick()
  }
}

// ============================================================================
// Mock Factories
// ============================================================================

/**
 * Create a mock fetch that returns specified responses.
 *
 * @example
 * const restore = mockFetch({ '/api/users': [{ id: 1, name: 'Ada' }] })
 * // ... test ...
 * restore()
 */
export function mockFetch(
  responses: Record<string, unknown>,
  options: { status?: number; delay?: number } = {}
): () => void {
  const { status = 200, delay = 0 } = options

  const spy = vi.spyOn(globalThis, 'fetch').mockImplementation(
    async (input: RequestInfo | URL) => {
      const url = typeof input === 'string' ? input : input.toString()

      if (delay > 0) {
        await new Promise(resolve => setTimeout(resolve, delay))
      }

      const data = responses[url]
      if (data === undefined) {
        return new Response('Not Found', { status: 404 })
      }

      return new Response(JSON.stringify(data), {
        status,
        headers: { 'Content-Type': 'application/json' },
      })
    }
  )

  return () => spy.mockRestore()
}

// ============================================================================
// Usage in vitest.config.ts:
// ============================================================================
//
// export default defineConfig({
//   test: {
//     environment: 'happy-dom',
//     globals: true,
//     setupFiles: ['./src/test/setup.ts'],  // Point to this file
//   },
// })
