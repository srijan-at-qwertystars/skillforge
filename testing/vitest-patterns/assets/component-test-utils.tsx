/**
 * Component testing utility helpers for React and Vue.
 * Provides typed render wrappers, mock providers, and common testing patterns.
 *
 * Usage: Copy and adapt for your project. Uncomment the framework section you need.
 */
import { vi } from 'vitest';
import type { ReactElement, ReactNode } from 'react';

// ═══════════════════════════════════════════════════════════════════════════
// REACT UTILITIES
// Requires: @testing-library/react, @testing-library/user-event
// ═══════════════════════════════════════════════════════════════════════════

// Uncomment and adapt for your React project:
//
// import { render, type RenderOptions } from '@testing-library/react';
// import userEvent from '@testing-library/user-event';
//
// // ─── Custom Render with Providers ──────────────────────────────────────
// interface WrapperProps {
//   children: ReactNode;
// }
//
// /**
//  * Wraps components in common providers (router, theme, store, etc.)
//  * Extend with your app's providers.
//  */
// function AllProviders({ children }: WrapperProps) {
//   return (
//     // Add your providers here:
//     // <ThemeProvider theme={testTheme}>
//     //   <QueryClientProvider client={testQueryClient}>
//     //     <MemoryRouter>
//           <>{children}</>
//     //     </MemoryRouter>
//     //   </QueryClientProvider>
//     // </ThemeProvider>
//   );
// }
//
// /**
//  * Custom render that wraps component in providers and sets up userEvent.
//  * Returns everything from @testing-library/react's render, plus `user`.
//  *
//  * @example
//  * const { getByRole, user } = renderWithProviders(<MyButton />);
//  * await user.click(getByRole('button'));
//  */
// export function renderWithProviders(
//   ui: ReactElement,
//   options?: Omit<RenderOptions, 'wrapper'>
// ) {
//   const user = userEvent.setup();
//   return {
//     user,
//     ...render(ui, { wrapper: AllProviders, ...options }),
//   };
// }

// ─── Mock Navigation / Router ───────────────────────────────────────────

/**
 * Creates a mock Next.js router (App Router).
 * Adapt for React Router or other routing libraries.
 */
export function createMockRouter(overrides: Record<string, unknown> = {}) {
  return {
    back: vi.fn(),
    forward: vi.fn(),
    push: vi.fn(),
    replace: vi.fn(),
    refresh: vi.fn(),
    prefetch: vi.fn().mockResolvedValue(undefined),
    pathname: '/',
    query: {},
    asPath: '/',
    ...overrides,
  };
}

// ─── Mock Fetch / API Helpers ───────────────────────────────────────────

/**
 * Creates a mock fetch that returns structured responses.
 *
 * @example
 * const mockFetch = createMockFetch({ users: [{ id: 1 }] });
 * vi.stubGlobal('fetch', mockFetch);
 */
export function createMockFetch(data: unknown, options?: { status?: number; ok?: boolean }) {
  const { status = 200, ok = true } = options ?? {};
  return vi.fn().mockResolvedValue({
    ok,
    status,
    json: vi.fn().mockResolvedValue(data),
    text: vi.fn().mockResolvedValue(JSON.stringify(data)),
    headers: new Headers({ 'content-type': 'application/json' }),
    clone: vi.fn().mockReturnThis(),
  });
}

/**
 * Creates a mock fetch that rejects or returns error status.
 */
export function createMockFetchError(
  message = 'Internal Server Error',
  status = 500
) {
  return createMockFetch({ error: message }, { status, ok: false });
}

// ─── Async Testing Helpers ──────────────────────────────────────────────

/**
 * Wait for a condition to be true, polling at intervals.
 * Useful when @testing-library/react's waitFor is not available.
 */
export async function waitForCondition(
  condition: () => boolean | Promise<boolean>,
  { timeout = 3000, interval = 50 } = {}
): Promise<void> {
  const start = Date.now();
  while (Date.now() - start < timeout) {
    if (await condition()) return;
    await new Promise((r) => setTimeout(r, interval));
  }
  throw new Error(`Condition not met within ${timeout}ms`);
}

/**
 * Flush all pending promises (microtask queue).
 * Useful after triggering state updates.
 */
export function flushPromises(): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, 0));
}

// ─── Mock Intersection Observer ─────────────────────────────────────────

type IntersectionCallback = (entries: IntersectionObserverEntry[]) => void;

/**
 * Creates a controllable IntersectionObserver mock.
 *
 * @example
 * const { triggerIntersect } = mockIntersectionObserver();
 * render(<LazyImage src="test.png" />);
 * triggerIntersect([{ isIntersecting: true }]);
 */
export function mockIntersectionObserver() {
  let callback: IntersectionCallback | null = null;
  const observedElements = new Set<Element>();

  const mock = vi.fn((cb: IntersectionCallback) => {
    callback = cb;
    return {
      observe: vi.fn((el: Element) => observedElements.add(el)),
      unobserve: vi.fn((el: Element) => observedElements.delete(el)),
      disconnect: vi.fn(() => observedElements.clear()),
      takeRecords: vi.fn(() => []),
    };
  });

  vi.stubGlobal('IntersectionObserver', mock);

  return {
    mock,
    triggerIntersect(entries: Partial<IntersectionObserverEntry>[]) {
      const fullEntries = entries.map((entry) => ({
        boundingClientRect: {} as DOMRectReadOnly,
        intersectionRatio: entry.isIntersecting ? 1 : 0,
        intersectionRect: {} as DOMRectReadOnly,
        isIntersecting: false,
        rootBounds: null,
        target: document.createElement('div'),
        time: Date.now(),
        ...entry,
      }));
      callback?.(fullEntries as IntersectionObserverEntry[]);
    },
    getObservedElements: () => observedElements,
  };
}

// ─── Media Query Mock ───────────────────────────────────────────────────

/**
 * Mock matchMedia with controllable matches.
 *
 * @example
 * const { setMatches } = mockMatchMedia();
 * setMatches('(min-width: 768px)', true);
 */
export function mockMatchMedia() {
  const queries = new Map<string, boolean>();

  const mock = vi.fn((query: string) => ({
    matches: queries.get(query) ?? false,
    media: query,
    onchange: null,
    addListener: vi.fn(),
    removeListener: vi.fn(),
    addEventListener: vi.fn(),
    removeEventListener: vi.fn(),
    dispatchEvent: vi.fn(),
  }));

  vi.stubGlobal('matchMedia', mock);

  return {
    mock,
    setMatches(query: string, matches: boolean) {
      queries.set(query, matches);
    },
  };
}

// ═══════════════════════════════════════════════════════════════════════════
// VUE UTILITIES
// Requires: @testing-library/vue or @vue/test-utils
// ═══════════════════════════════════════════════════════════════════════════

// Uncomment and adapt for your Vue project:
//
// import { mount, type MountingOptions } from '@vue/test-utils';
// import type { Component } from 'vue';
//
// /**
//  * Mount a Vue component with common plugins pre-configured.
//  *
//  * @example
//  * const wrapper = mountWithPlugins(MyComponent, {
//  *   props: { title: 'Test' },
//  * });
//  * expect(wrapper.text()).toContain('Test');
//  */
// export function mountWithPlugins<T extends Component>(
//   component: T,
//   options?: MountingOptions<any>
// ) {
//   return mount(component, {
//     global: {
//       plugins: [
//         // Add your Vue plugins: router, pinia, i18n, etc.
//         // createTestingPinia({ createSpy: vi.fn }),
//       ],
//       stubs: {
//         // Stub heavy child components
//         // 'HeavyChart': true,
//       },
//     },
//     ...options,
//   });
// }

// ─── Test Data Factories ────────────────────────────────────────────────

/**
 * Generic factory for creating test data with defaults and overrides.
 *
 * @example
 * const createUser = createFactory({ id: '1', name: 'Test', email: 'test@example.com' });
 * const user = createUser({ name: 'Alice' });
 * // { id: '1', name: 'Alice', email: 'test@example.com' }
 */
export function createFactory<T extends Record<string, unknown>>(defaults: T) {
  let counter = 0;
  return (overrides?: Partial<T>): T => {
    counter++;
    return { ...defaults, ...overrides } as T;
  };
}

/**
 * Create an array of test entities.
 *
 * @example
 * const users = createMany(createUser, 5, (i) => ({ id: String(i) }));
 */
export function createMany<T>(
  factory: (overrides?: Partial<T>) => T,
  count: number,
  overridesFn?: (index: number) => Partial<T>
): T[] {
  return Array.from({ length: count }, (_, i) =>
    factory(overridesFn?.(i))
  );
}
