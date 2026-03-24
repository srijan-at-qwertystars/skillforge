---
name: vitest-testing
description: >
  Comprehensive guide for writing, configuring, and debugging tests with Vitest (v3+), the
  Vite-native testing framework. Covers setup, unit/component/integration testing, advanced
  mocking (vi.mock/vi.fn/vi.spyOn/vi.hoisted/module factories/class mocking), snapshot testing,
  coverage (v8/istanbul), workspace/monorepo configs, browser mode (Playwright/WebDriverIO),
  benchmarking, type testing (expectTypeOf), test context and fixtures (test.extend), custom
  matchers, snapshot serializers, concurrent tests, in-source testing, environment config
  (jsdom/happy-dom/node), lifecycle hooks, reporters, CI integration, and troubleshooting.
  Includes reference docs, helper scripts, and production templates.
  USE when: setting up Vitest, writing any kind of Vitest test, configuring vitest.config.ts,
  mocking modules or dependencies, debugging test failures, setting up coverage or CI pipelines,
  optimizing slow test suites, configuring workspace/monorepo testing, using browser mode,
  writing benchmarks or type tests, creating custom matchers or snapshot serializers.
  DO NOT USE when: answering Jest-specific questions without Vitest context, configuring Playwright
  or Cypress for e2e testing, non-JavaScript/TypeScript testing, configuring Mocha/Jasmine/Karma,
  or general Vite build questions unrelated to testing.
---
# Vitest Testing Framework

## Skill Resources

### Reference Documentation
- **[references/advanced-patterns.md](references/advanced-patterns.md)** — Module factory mocking, vi.hoisted, partial mocks, class mocking, automocking, custom matchers, snapshot serializers, test context/fixtures, workspace deep-dive, browser mode setup, type testing, benchmarking API, concurrent control
- **[references/troubleshooting.md](references/troubleshooting.md)** — Module resolution errors, ESM/CJS issues, transform errors, slow test diagnosis, memory leaks, watch mode problems, coverage gaps, CI-specific issues, debugging with VS Code and Chrome DevTools, pool/worker issues
- **[references/api-reference.md](references/api-reference.md)** — Complete API: test/describe variants, lifecycle hooks, vi object methods, expect matchers, asymmetric matchers, mock properties, test context API, snapshot API, type testing API, benchmarking API, full configuration reference

### Scripts
- **[scripts/setup-vitest.sh](scripts/setup-vitest.sh)** — Auto-detect framework (React/Vue/Svelte), install deps, generate config and setup files
- **[scripts/coverage-check.sh](scripts/coverage-check.sh)** — Run coverage, check against thresholds, output summary table with per-file breakdown

### Templates
- **[assets/vitest.config.template.ts](assets/vitest.config.template.ts)** — Production config with coverage, reporters, path aliases, CI-aware settings, pool config
- **[assets/test-utils.template.ts](assets/test-utils.template.ts)** — Mock factories, fetch stubs, timer helpers, assertion utilities, console capture, env helpers
- **[assets/ci-workflow.template.yml](assets/ci-workflow.template.yml)** — GitHub Actions workflow with matrix testing, coverage upload, artifact storage
## Installation
```bash
npm install -D vitest
npm install -D @vitest/coverage-v8    # coverage
npm install -D @vitest/ui             # UI mode
npm install -D @vitest/browser playwright  # browser mode
```
Add to `package.json`:
```json
{ "scripts": {
    "test": "vitest", "test:run": "vitest run",
    "test:coverage": "vitest run --coverage",
    "test:ui": "vitest --ui", "test:bench": "vitest bench"
} }
```
Requires Vite >=6.0.0 and Node.js >=20.0.0.
## Configuration — vitest.config.ts
Use `defineConfig` from `vitest/config` (not `vite`):
```ts
import { defineConfig } from 'vitest/config'
export default defineConfig({
  test: {
    globals: true,                    // describe/it/expect without imports
    environment: 'jsdom',             // 'node' | 'jsdom' | 'happy-dom'
    setupFiles: ['./vitest.setup.ts'],
    include: ['**/*.{test,spec}.{ts,tsx,js,jsx}'],
    exclude: ['node_modules', 'dist', 'e2e'],
    testTimeout: 10000,
    reporters: ['default'],           // 'verbose' | 'json' | 'junit' | 'html'
    pool: 'forks',                    // 'threads' | 'forks' | 'vmThreads'
    css: true,
    alias: { '@': './src' },
    coverage: {
      provider: 'v8',                 // 'v8' (default) | 'istanbul'
      reporter: ['text', 'html', 'json', 'lcov'],
      reportsDirectory: './coverage',
      include: ['src/**/*.{ts,tsx}'],
      exclude: ['**/*.test.*', '**/*.d.ts'],
      thresholds: { lines: 80, branches: 80, functions: 80, statements: 80 },
    },
  },
})
```
Per-file environment override via magic comment: `// @vitest-environment happy-dom`
When using `globals: true`, add to `tsconfig.json`:
```json
{ "compilerOptions": { "types": ["vitest/globals"] } }
```
## Test Syntax
```ts
import { describe, it, expect, test } from 'vitest'
describe('Calculator', () => {
  it('adds two numbers', () => {
    expect(1 + 2).toBe(3)
  })
  it('handles async', async () => {
    const result = await fetchData()
    expect(result).toEqual({ id: 1, name: 'test' })
  })
  test.each([
    [1, 2, 3],
    [0, 0, 0],
    [-1, 1, 0],
  ])('add(%i, %i) = %i', (a, b, expected) => {
    expect(a + b).toBe(expected)
  })
  test.todo('implement subtraction')
  test.skip('skipped test', () => {})
})
```
### Concurrent Tests
```ts
describe.concurrent('parallel suite', () => {
  it('test 1', async () => { /* runs in parallel */ })
  it('test 2', async () => { /* runs in parallel */ })
})
it.concurrent('standalone parallel test', async () => {})
```
## Matchers
```ts
// Equality
expect(value).toBe(3)                    // strict ===
expect(obj).toEqual({ a: 1 })            // deep equality
expect(obj).toStrictEqual({ a: 1 })      // deep + type equality
// Truthiness
expect(val).toBeTruthy()
expect(val).toBeFalsy()
expect(val).toBeNull()
expect(val).toBeUndefined()
expect(val).toBeDefined()
// Numbers
expect(num).toBeGreaterThan(3)
expect(num).toBeLessThanOrEqual(10)
expect(0.1 + 0.2).toBeCloseTo(0.3, 5)
// Strings
expect(str).toMatch(/pattern/)
expect(str).toContain('substring')
// Arrays/Iterables
expect(arr).toContain('item')
expect(arr).toContainEqual({ id: 1 })
expect(arr).toHaveLength(3)
// Objects
expect(obj).toHaveProperty('key', 'value')
expect(obj).toMatchObject({ subset: true })
// Exceptions
expect(() => fn()).toThrow()
expect(() => fn()).toThrowError('message')
// Promises
await expect(promise).resolves.toBe('value')
await expect(promise).rejects.toThrow('error')
// Asymmetric
expect(obj).toEqual(expect.objectContaining({ id: 1 }))
expect(arr).toEqual(expect.arrayContaining([1, 2]))
expect(str).toEqual(expect.stringContaining('part'))
expect(val).toEqual(expect.any(Number))
```
### Custom Matchers
```ts
expect.extend({
  toBeWithinRange(received: number, floor: number, ceiling: number) {
    const pass = received >= floor && received <= ceiling
    return {
      pass,
      message: () => `expected ${received} to be within [${floor}, ${ceiling}]`,
    }
  },
})
// Usage: expect(100).toBeWithinRange(90, 110)
```
## Mocking
### vi.fn() — Mock Functions
```ts
import { vi } from 'vitest'
const mockFn = vi.fn()
mockFn('arg1', 'arg2')
expect(mockFn).toHaveBeenCalledWith('arg1', 'arg2')
expect(mockFn).toHaveBeenCalledTimes(1)
// Return values
const fn = vi.fn()
  .mockReturnValue('default')
  .mockReturnValueOnce('first')
  .mockReturnValueOnce('second')
fn() // 'first', then 'second', then 'default'
// Async
const asyncFn = vi.fn().mockResolvedValue({ data: 1 })
await asyncFn() // { data: 1 }
// Implementation
const impl = vi.fn((x: number) => x * 2)
impl(5) // 10
// Inspection
fn.mock.calls        // all call arguments
fn.mock.results       // [{ type: 'return', value: ... }]
fn.mock.lastCall      // last call arguments
```
### vi.spyOn() — Spy on Methods
```ts
const cart = {
  getTotal: (items: number[]) => items.reduce((a, b) => a + b, 0),
}
const spy = vi.spyOn(cart, 'getTotal')
cart.getTotal([1, 2, 3])
expect(spy).toHaveBeenCalledWith([1, 2, 3])
expect(spy).toHaveReturnedWith(6)
// Override temporarily
spy.mockImplementation(() => 99)
cart.getTotal([1]) // 99
spy.mockRestore()  // restore original
```
### vi.mock() — Module Mocking
```ts
// Full mock — hoisted to top of file automatically
vi.mock('./api', () => ({
  fetchUser: vi.fn().mockResolvedValue({ id: 1, name: 'Test' }),
  fetchPosts: vi.fn().mockResolvedValue([]),
}))
// Partial mock — keep real implementations
vi.mock('./utils', async (importOriginal) => {
  const actual = await importOriginal<typeof import('./utils')>()
  return { ...actual, formatDate: vi.fn(() => '2024-01-01') }
})
// Auto-mock entire module (all exports become vi.fn())
vi.mock('./service')
// Reset between tests
afterEach(() => {
  vi.restoreAllMocks()   // restore spies + clear mocks
})
// vi.clearAllMocks()    — clear call history only
// vi.resetAllMocks()    — clear history + reset implementations
```
### Mocking Globals and Timers
```ts
// Fake timers
vi.useFakeTimers()
setTimeout(fn, 1000)
vi.advanceTimersByTime(1000)
expect(fn).toHaveBeenCalled()
vi.useRealTimers()
// Mock date
vi.setSystemTime(new Date('2024-06-15'))
expect(new Date().toISOString()).toContain('2024-06-15')
vi.useRealTimers()
// Global stubs
vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
  json: () => Promise.resolve({ data: 'mock' }),
}))
vi.unstubAllGlobals()
// Environment variables
vi.stubEnv('API_KEY', 'test-key')
expect(process.env.API_KEY).toBe('test-key')
vi.unstubAllEnvs()
```
## Snapshot Testing
```ts
// File snapshot — creates __snapshots__/*.snap
it('renders correctly', () => {
  expect(render(<Component />)).toMatchSnapshot()
})
// Inline snapshot — writes expected into test file
it('serializes config', () => {
  expect({ port: 3000, host: 'localhost' }).toMatchInlineSnapshot(`
    { "host": "localhost", "port": 3000 }
  `)
})
// File snapshot (custom path)
expect(content).toMatchFileSnapshot('./fixtures/expected.txt')
```
Update snapshots: `vitest run --update` or press `u` in watch mode.
## Lifecycle Hooks
```ts
beforeAll(async () => { /* once before all tests in suite */ })
afterAll(async () => { /* once after all tests */ })
beforeEach(async () => { /* before each test */ })
afterEach(async () => { /* after each test */ })
```
Setup file example (`vitest.setup.ts`):
```ts
import '@testing-library/jest-dom/vitest'
import { cleanup } from '@testing-library/react'
import { afterEach } from 'vitest'
afterEach(() => cleanup())
```
## Coverage
Install provider: `npm install -D @vitest/coverage-v8` (or `@vitest/coverage-istanbul`).
```ts
// vitest.config.ts
test: {
  coverage: {
    provider: 'v8',
    enabled: true,               // or use --coverage CLI flag
    reporter: ['text', 'html', 'lcov'],
    include: ['src/**'],
    exclude: ['**/*.test.*', '**/types/**'],
    all: true,                   // include uncovered files
    thresholds: {
      lines: 80, branches: 75, functions: 80, statements: 80,
      perFile: true,
    },
  },
}
```
V8 is default and faster. Istanbul works everywhere but adds overhead. Since v3.2.0 no accuracy difference.
CLI: `vitest run --coverage` or `vitest run --coverage.enabled --coverage.provider=v8`.
## Workspace Mode (Monorepo)
Create `vitest.workspace.ts` at repo root:
```ts
import { defineWorkspace } from 'vitest/config'
export default defineWorkspace([
  'packages/*',
  {
    test: {
      name: 'server',
      include: ['packages/server/test/**/*.test.ts'],
      environment: 'node',
    },
  },
  {
    test: {
      name: 'client',
      include: ['packages/client/test/**/*.test.ts'],
      environment: 'jsdom',
    },
  },
])
```
Per-project config with `defineProject`:
```ts
// packages/client/vitest.config.ts
import { defineProject } from 'vitest/config'
export default defineProject({
  test: { environment: 'jsdom', setupFiles: ['./setup.ts'] },
})
```
Run specific project: `vitest --project=client`. All project names must be unique.
## Browser Mode
```bash
npm install -D @vitest/browser playwright
```
```ts
import { defineConfig } from 'vitest/config'
export default defineConfig({
  test: {
    browser: {
      enabled: true,
      provider: 'playwright',     // or 'webdriverio'
      instances: [{ browser: 'chromium' }],
    },
  },
})
```
Use separate workspace projects to split browser and Node tests.
## Type Testing
Type test files use `.test-d.ts` extension. Validated at compile time, not runtime.
```ts
// math.test-d.ts
import { expectTypeOf } from 'vitest'
import { add } from './math'
test('add returns number', () => {
  expectTypeOf(add).toBeFunction()
  expectTypeOf(add).parameter(0).toBeNumber()
  expectTypeOf(add).returns.toBeNumber()
  expectTypeOf(add(1, 2)).toEqualTypeOf<number>()
})
test('config type', () => {
  type Config = { port: number; host: string }
  expectTypeOf<Config>().toMatchTypeOf<{ port: number }>()
  expectTypeOf<Config>().not.toBeAny()
})
```
Enable in config:
```ts
test: {
  typecheck: { enabled: true, tsconfig: './tsconfig.json', include: ['**/*.test-d.ts'] },
}
```
Run: `vitest typecheck` or included in `vitest run` when enabled.
## Benchmarking
```ts
// math.bench.ts
import { bench, describe } from 'vitest'
describe('sorting', () => {
  bench('Array.sort', () => { [3, 1, 2].sort() })
  bench('custom sort', () => { customSort([3, 1, 2]) }, { iterations: 1000, time: 500 })
})
```
Run: `vitest bench`. Save: `vitest bench --outputJson results.json`. Compare: `vitest bench --compare previous.json`. API is experimental.
## Test Filtering and CLI
```bash
vitest math                      # filter by filename
vitest -t "adds numbers"         # filter by test name
vitest --reporter=verbose        # change reporter
vitest --bail=3                  # stop after 3 failures
vitest --changed                 # only changed files
vitest --sequence.shuffle        # randomize order
vitest list                      # list files without running
```
Watch mode is default. Use `vitest run` for single run (CI).
## Reporters
```ts
test: {
  reporters: ['default'],  // 'default'|'verbose'|'dot'|'json'|'junit'|'html'
  outputFile: { json: './test-results.json', junit: './junit.xml' },
}
```
## In-Source Testing
```ts
// src/math.ts
export function add(a: number, b: number) { return a + b }
if (import.meta.vitest) {
  const { it, expect } = import.meta.vitest
  it('add', () => { expect(add(1, 2)).toBe(3) })
}
```
Enable:
```ts
export default defineConfig({
  define: { 'import.meta.vitest': 'undefined' }, // strip in production
  test: { includeSource: ['src/**/*.ts'] },
})
```
## Environment Setup
```bash
npm install -D jsdom       # jsdom environment
npm install -D happy-dom   # faster, less complete
```
Setup for React Testing Library:
```ts
// vitest.setup.ts
import '@testing-library/jest-dom/vitest'
import { cleanup } from '@testing-library/react'
import { afterEach } from 'vitest'
afterEach(() => cleanup())
```
## Quick Reference
| Task | Command/API |
|------|------------|
| Run all tests | `vitest run` |
| Watch mode | `vitest` |
| Coverage | `vitest run --coverage` |
| Single file | `vitest run src/math.test.ts` |
| Filter by name | `vitest -t "test name"` |
| Update snapshots | `vitest run --update` |
| Benchmarks | `vitest bench` |
| Type checking | `vitest typecheck` |
| UI mode | `vitest --ui` |
| Specific project | `vitest --project=name` |
