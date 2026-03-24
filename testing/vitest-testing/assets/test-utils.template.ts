// test-utils.template.ts — Common test utilities for Vitest projects
//
// Usage: Copy to your project as `test/test-utils.ts` and adjust for your stack.
// Import from tests: import { renderWithProviders, createMockUser } from '@test/test-utils'

import { vi, type MockInstance } from 'vitest'

// ── Mock Factories ───────────────────────────────────────────────────

/**
 * Creates a mock user object with sensible defaults.
 * Override any field by passing partial data.
 */
export function createMockUser(overrides: Partial<User> = {}): User {
  return {
    id: Math.floor(Math.random() * 10000),
    name: 'Test User',
    email: 'test@example.com',
    role: 'user',
    createdAt: new Date('2024-01-01'),
    ...overrides,
  }
}

interface User {
  id: number
  name: string
  email: string
  role: 'admin' | 'user' | 'guest'
  createdAt: Date
}

/**
 * Generic factory for creating mock data with auto-incrementing IDs.
 */
export function createFactory<T extends { id: number }>(defaults: Omit<T, 'id'>) {
  let nextId = 1
  return (overrides: Partial<T> = {}): T => {
    return { id: nextId++, ...defaults, ...overrides } as T
  }
}

// Example usage:
// const createPost = createFactory<Post>({ title: 'Test Post', body: 'Content', authorId: 1 })
// const post1 = createPost()              // { id: 1, title: 'Test Post', ... }
// const post2 = createPost({ title: 'Custom' }) // { id: 2, title: 'Custom', ... }

// ── Mock API Response Helper ─────────────────────────────────────────

/**
 * Creates a mock Response object (for fetch mocking).
 */
export function createMockResponse<T>(data: T, options: { status?: number; ok?: boolean } = {}) {
  const { status = 200, ok = true } = options
  return {
    ok,
    status,
    statusText: ok ? 'OK' : 'Error',
    json: () => Promise.resolve(data),
    text: () => Promise.resolve(JSON.stringify(data)),
    headers: new Headers({ 'content-type': 'application/json' }),
    clone: function () { return createMockResponse(data, options) },
  } as unknown as Response
}

/**
 * Stubs global fetch for a test. Returns the mock for assertions.
 */
export function mockFetch<T>(data: T, options?: { status?: number; ok?: boolean }) {
  const mock = vi.fn().mockResolvedValue(createMockResponse(data, options))
  vi.stubGlobal('fetch', mock)
  return mock
}

/**
 * Stubs fetch to return different responses in sequence.
 */
export function mockFetchSequence(responses: Array<{ data: unknown; status?: number; ok?: boolean }>) {
  const mock = vi.fn()
  responses.forEach((resp) => {
    mock.mockResolvedValueOnce(
      createMockResponse(resp.data, { status: resp.status, ok: resp.ok })
    )
  })
  vi.stubGlobal('fetch', mock)
  return mock
}

// ── Timer Helpers ────────────────────────────────────────────────────

/**
 * Wraps a test body with fake timers — automatically restores after.
 */
export async function withFakeTimers(fn: () => void | Promise<void>) {
  vi.useFakeTimers()
  try {
    await fn()
  } finally {
    vi.useRealTimers()
  }
}

/**
 * Runs all pending timers and microtasks (useful for debounce/throttle tests).
 */
export async function flushTimersAndMicrotasks() {
  await vi.runAllTimersAsync()
  // Flush microtask queue
  await new Promise((resolve) => setTimeout(resolve, 0))
}

// ── Assertion Helpers ────────────────────────────────────────────────

/**
 * Asserts that an async function throws with a specific error type and message.
 */
export async function expectAsyncError<E extends Error>(
  fn: () => Promise<unknown>,
  ErrorClass: new (...args: any[]) => E,
  messageMatch?: string | RegExp
) {
  let thrown: Error | undefined
  try {
    await fn()
  } catch (e) {
    thrown = e as Error
  }
  expect(thrown).toBeInstanceOf(ErrorClass)
  if (messageMatch) {
    expect(thrown!.message).toMatch(messageMatch)
  }
  return thrown as E
}

/**
 * Waits until a condition is true, polling at an interval.
 */
export async function waitUntil(
  condition: () => boolean | Promise<boolean>,
  { timeout = 5000, interval = 50 } = {}
): Promise<void> {
  const start = Date.now()
  while (Date.now() - start < timeout) {
    if (await condition()) return
    await new Promise((r) => setTimeout(r, interval))
  }
  throw new Error(`waitUntil timed out after ${timeout}ms`)
}

// ── Spy Helpers ──────────────────────────────────────────────────────

/**
 * Captures all console.error calls during a function execution.
 * Useful for asserting that warnings/errors were or weren't logged.
 */
export function captureConsoleErrors(fn: () => void | Promise<void>) {
  const errors: unknown[][] = []
  const spy = vi.spyOn(console, 'error').mockImplementation((...args) => {
    errors.push(args)
  })
  const result = fn()
  if (result instanceof Promise) {
    return result.then(() => {
      spy.mockRestore()
      return errors
    })
  }
  spy.mockRestore()
  return errors
}

/**
 * Suppresses console output during a test (console.log, warn, error).
 * Returns spies for assertion if needed.
 */
export function silenceConsole() {
  return {
    log: vi.spyOn(console, 'log').mockImplementation(() => {}),
    warn: vi.spyOn(console, 'warn').mockImplementation(() => {}),
    error: vi.spyOn(console, 'error').mockImplementation(() => {}),
  }
}

// ── Environment Helpers ──────────────────────────────────────────────

/**
 * Temporarily sets environment variables for a test block.
 * Restores originals after the callback completes.
 */
export async function withEnv(
  vars: Record<string, string>,
  fn: () => void | Promise<void>
) {
  const originals: Record<string, string | undefined> = {}
  for (const [key, value] of Object.entries(vars)) {
    originals[key] = process.env[key]
    vi.stubEnv(key, value)
  }
  try {
    await fn()
  } finally {
    vi.unstubAllEnvs()
  }
}

// ── Type Utilities ───────────────────────────────────────────────────

/** Deep partial — makes all nested properties optional. */
export type DeepPartial<T> = {
  [P in keyof T]?: T[P] extends object ? DeepPartial<T[P]> : T[P]
}

/** Extract mock type from a function. */
export type MockOf<T extends (...args: any) => any> = MockInstance<
  Parameters<T>,
  ReturnType<T>
>
