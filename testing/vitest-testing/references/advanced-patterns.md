# Vitest Advanced Patterns

## Table of Contents

- [Module Factory Mocking](#module-factory-mocking)
- [vi.hoisted — Sharing State in Hoisted Mocks](#vihoisted--sharing-state-in-hoisted-mocks)
- [Partial Mocks with importOriginal](#partial-mocks-with-importoriginal)
- [Class Mocking Strategies](#class-mocking-strategies)
- [Automocking with spy: true](#automocking-with-spy-true)
- [Custom Matchers (expect.extend)](#custom-matchers-expectextend)
- [Snapshot Serializers](#snapshot-serializers)
- [Test Context and Custom Fixtures](#test-context-and-custom-fixtures)
- [Fixture Patterns (test.extend)](#fixture-patterns-testextend)
- [Workspace Configuration Deep-Dive](#workspace-configuration-deep-dive)
- [Browser Mode Setup](#browser-mode-setup)
- [Type Testing with expectTypeOf](#type-testing-with-expecttypeof)
- [Benchmarking API](#benchmarking-api)
- [In-Source Testing](#in-source-testing)
- [Concurrent and Sequential Control](#concurrent-and-sequential-control)
- [Dynamic Test Generation](#dynamic-test-generation)

---

## Module Factory Mocking

`vi.mock()` calls are **hoisted to the top** of the file before any imports execute, regardless of where you write them. The factory function replaces the module entirely.

### Full Module Mock with Factory

```ts
vi.mock('./api', () => ({
  fetchUser: vi.fn().mockResolvedValue({ id: 1, name: 'Mock User' }),
  fetchPosts: vi.fn().mockResolvedValue([]),
  // default export
  default: vi.fn(() => 'mocked default'),
}))

import { fetchUser, fetchPosts } from './api'
// fetchUser and fetchPosts are already mocked
```

### Auto-Mock (No Factory)

```ts
// All exports become vi.fn() — returns undefined by default
vi.mock('./service')

import { calculate } from './service'
// calculate is vi.fn()
```

### Controlling Mock Per-Test

```ts
import { fetchUser } from './api'
vi.mock('./api', () => ({
  fetchUser: vi.fn(),
}))

it('returns user', async () => {
  vi.mocked(fetchUser).mockResolvedValueOnce({ id: 1, name: 'Alice' })
  const result = await fetchUser()
  expect(result).toEqual({ id: 1, name: 'Alice' })
})

it('throws error', async () => {
  vi.mocked(fetchUser).mockRejectedValueOnce(new Error('Network error'))
  await expect(fetchUser()).rejects.toThrow('Network error')
})
```

### vi.mocked() for Type Safety

```ts
import { complexFn } from './utils'
vi.mock('./utils')

// vi.mocked() wraps the import with mock types
const mockedFn = vi.mocked(complexFn)
mockedFn.mockReturnValue('typed result') // full IntelliSense
```

---

## vi.hoisted — Sharing State in Hoisted Mocks

Because `vi.mock()` is hoisted, normal file-scope variables are **not accessible** inside factory functions. Use `vi.hoisted()` to declare variables that are also hoisted.

```ts
// Both the variable and the mock are hoisted together
const mockFetch = vi.hoisted(() => vi.fn())

vi.mock('./api', () => ({
  fetchData: mockFetch,
}))

import { fetchData } from './api'

it('uses hoisted mock', () => {
  mockFetch.mockReturnValue('data')
  expect(fetchData()).toBe('data')
})
```

### Complex Hoisted Setup

```ts
const { mockDb, mockLogger } = vi.hoisted(() => ({
  mockDb: {
    query: vi.fn(),
    connect: vi.fn(),
    disconnect: vi.fn(),
  },
  mockLogger: {
    info: vi.fn(),
    error: vi.fn(),
  },
}))

vi.mock('./database', () => ({ default: mockDb }))
vi.mock('./logger', () => ({ default: mockLogger }))
```

### When to Use vi.hoisted vs. Regular Variables

| Scenario | Use |
|----------|-----|
| Variable needed inside `vi.mock()` factory | `vi.hoisted()` |
| Variable only used in test bodies | Regular `const`/`let` |
| Shared mock instance across factory and tests | `vi.hoisted()` |
| Setup logic that must run before imports | `vi.hoisted()` |

---

## Partial Mocks with importOriginal

Override specific exports while keeping the rest real.

```ts
vi.mock('./utils', async (importOriginal) => {
  const actual = await importOriginal<typeof import('./utils')>()
  return {
    ...actual,
    formatDate: vi.fn(() => '2024-01-01'),
    // add, subtract, etc. remain real implementations
  }
})
```

### Partial Mock of Default Export

```ts
vi.mock('./config', async (importOriginal) => {
  const actual = await importOriginal<typeof import('./config')>()
  return {
    ...actual,
    default: {
      ...actual.default,
      apiUrl: 'http://test-api.local',
    },
  }
})
```

---

## Class Mocking Strategies

### Full Class Replacement

```ts
vi.mock('./UserService', () => ({
  UserService: vi.fn().mockImplementation(() => ({
    getUser: vi.fn().mockResolvedValue({ id: 1, name: 'Test' }),
    createUser: vi.fn().mockResolvedValue({ id: 2 }),
    deleteUser: vi.fn().mockResolvedValue(true),
  })),
}))
```

### Class with Static Methods

```ts
vi.mock('./Database', () => {
  const MockDatabase = vi.fn().mockImplementation(() => ({
    query: vi.fn(),
    close: vi.fn(),
  }))
  // Static methods
  MockDatabase.connect = vi.fn().mockResolvedValue(new MockDatabase())
  MockDatabase.getInstance = vi.fn()
  return { Database: MockDatabase }
})
```

### Spy on Class Methods (Prototype)

```ts
import { UserService } from './UserService'

const spy = vi.spyOn(UserService.prototype, 'getUser')
spy.mockResolvedValue({ id: 1, name: 'Spied' })

const service = new UserService()
await service.getUser(1) // uses spy
expect(spy).toHaveBeenCalledWith(1)
spy.mockRestore()
```

### Abstract Class / Interface Mocking

```ts
// Create a concrete mock from an interface
const createMockRepository = (): UserRepository => ({
  findById: vi.fn(),
  findAll: vi.fn().mockResolvedValue([]),
  save: vi.fn().mockImplementation(async (user) => ({ ...user, id: 1 })),
  delete: vi.fn().mockResolvedValue(true),
})

it('uses repository', async () => {
  const repo = createMockRepository()
  const service = new UserService(repo)
  await service.getUser(1)
  expect(repo.findById).toHaveBeenCalledWith(1)
})
```

---

## Automocking with spy: true

Keep real implementations but make all exports spy-able.

```ts
vi.mock('./calculator', { spy: true })

import { add, multiply } from './calculator'

it('calls real function but can assert', () => {
  const result = add(2, 3)
  expect(result).toBe(5) // real implementation runs
  expect(add).toHaveBeenCalledWith(2, 3) // also a spy
})
```

---

## Custom Matchers (expect.extend)

### Defining Custom Matchers

```ts
// vitest.setup.ts
import { expect } from 'vitest'

expect.extend({
  toBeWithinRange(received: number, floor: number, ceiling: number) {
    const pass = received >= floor && received <= ceiling
    return {
      pass,
      message: () =>
        `expected ${received} ${pass ? 'not ' : ''}to be within range [${floor}, ${ceiling}]`,
      actual: received,
      expected: `${floor} - ${ceiling}`,
    }
  },

  toBeValidEmail(received: string) {
    const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/
    const pass = emailRegex.test(received)
    return {
      pass,
      message: () => `expected "${received}" ${pass ? 'not ' : ''}to be a valid email`,
    }
  },

  async toResolveWithin(received: Promise<unknown>, ms: number) {
    const start = Date.now()
    try {
      await Promise.race([
        received,
        new Promise((_, reject) =>
          setTimeout(() => reject(new Error('timeout')), ms)
        ),
      ])
      const elapsed = Date.now() - start
      return {
        pass: true,
        message: () => `expected promise not to resolve within ${ms}ms (resolved in ${elapsed}ms)`,
      }
    } catch {
      return {
        pass: false,
        message: () => `expected promise to resolve within ${ms}ms`,
      }
    }
  },
})
```

### TypeScript Declaration

```ts
// vitest.d.ts
import 'vitest'

interface CustomMatchers<R = unknown> {
  toBeWithinRange(floor: number, ceiling: number): R
  toBeValidEmail(): R
  toResolveWithin(ms: number): R
}

declare module 'vitest' {
  interface Assertion<T = any> extends CustomMatchers<T> {}
  interface AsymmetricMatchersContaining extends CustomMatchers {}
}
```

---

## Snapshot Serializers

Register custom serializers to control snapshot output for domain objects.

```ts
// vitest.setup.ts
import { expect } from 'vitest'

expect.addSnapshotSerializer({
  test: (val) => val instanceof Date,
  print: (val) => `Date<${(val as Date).toISOString()}>`,
})

expect.addSnapshotSerializer({
  test: (val) =>
    val && typeof val === 'object' && 'type' in val && 'payload' in val,
  print: (val, serialize) => {
    const action = val as { type: string; payload: unknown }
    return `Action {\n  type: ${action.type}\n  payload: ${serialize(action.payload)}\n}`
  },
})

// In tests:
it('snapshot with custom serializer', () => {
  expect(new Date('2024-06-15')).toMatchInlineSnapshot(`Date<2024-06-15T00:00:00.000Z>`)
})
```

### File Snapshots

```ts
expect(generatedHtml).toMatchFileSnapshot('./fixtures/expected-output.html')
```

---

## Test Context and Custom Fixtures

Every test receives a context object as its first argument.

### Built-in Context Properties

```ts
it('has context', ({ task, expect, skip, onTestFailed, onTestFinished }) => {
  console.log(task.name) // "has context"
  console.log(task.id)   // unique test ID

  // Conditional skip
  if (!process.env.CI) skip('CI only')

  // Per-test hooks
  onTestFailed(({ errors }) => {
    console.log('Test failed:', errors)
  })
  onTestFinished(({ state }) => {
    console.log('Test ended with state:', state)
  })
})
```

---

## Fixture Patterns (test.extend)

Create reusable, composable test fixtures inspired by Playwright.

```ts
// test-fixtures.ts
import { test as base } from 'vitest'

interface DatabaseFixture {
  db: Database
  seedData: (records: any[]) => Promise<void>
}

export const test = base.extend<DatabaseFixture>({
  db: async ({}, use) => {
    const db = await Database.connect(':memory:')
    await db.migrate()
    await use(db) // provide to test
    await db.close() // teardown after test
  },

  seedData: async ({ db }, use) => {
    // fixtures can depend on other fixtures
    const seed = async (records: any[]) => {
      for (const record of records) await db.insert(record)
    }
    await use(seed)
  },
})

// In test files:
import { test } from './test-fixtures'

test('queries seeded data', async ({ db, seedData }) => {
  await seedData([{ name: 'Alice' }, { name: 'Bob' }])
  const users = await db.query('SELECT * FROM users')
  expect(users).toHaveLength(2)
})
```

### Composing Fixtures

```ts
import { test as dbTest } from './db-fixtures'

export const test = dbTest.extend<{ api: TestApiClient }>({
  api: async ({ db }, use) => {
    const app = createApp(db)
    const server = await app.listen(0)
    const client = new TestApiClient(`http://localhost:${server.port}`)
    await use(client)
    await server.close()
  },
})
```

---

## Workspace Configuration Deep-Dive

### Multi-Environment Workspace

```ts
// vitest.workspace.ts
import { defineWorkspace } from 'vitest/config'

export default defineWorkspace([
  {
    test: {
      name: 'node-unit',
      include: ['packages/server/**/*.test.ts'],
      environment: 'node',
      pool: 'threads',
      setupFiles: ['./packages/server/test/setup.ts'],
    },
  },
  {
    test: {
      name: 'browser-components',
      include: ['packages/ui/**/*.test.tsx'],
      environment: 'jsdom',
      pool: 'forks',
      setupFiles: ['./packages/ui/test/setup.ts'],
      css: true,
    },
  },
  {
    test: {
      name: 'integration',
      include: ['tests/integration/**/*.test.ts'],
      environment: 'node',
      testTimeout: 30000,
      hookTimeout: 30000,
      pool: 'forks',
      poolOptions: { forks: { singleFork: true } },
    },
  },
])
```

### Per-Project Config with defineProject

```ts
// packages/client/vitest.config.ts
import { defineProject } from 'vitest/config'
import react from '@vitejs/plugin-react'

export default defineProject({
  plugins: [react()],
  test: {
    environment: 'jsdom',
    setupFiles: ['./test/setup.ts'],
    // these options are NOT allowed in defineProject:
    // coverage, reporters, resolveSnapshotPath
  },
})
```

### Running Specific Projects

```bash
vitest --project=node-unit
vitest --project=node-unit --project=integration
```

---

## Browser Mode Setup

### Playwright Provider

```bash
npm install -D @vitest/browser playwright
```

```ts
import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: {
    browser: {
      enabled: true,
      provider: 'playwright',
      instances: [
        { browser: 'chromium' },
        { browser: 'firefox' },
        { browser: 'webkit' },
      ],
      headless: true,
    },
  },
})
```

### WebDriverIO Provider

```bash
npm install -D @vitest/browser webdriverio
```

```ts
import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: {
    browser: {
      enabled: true,
      provider: 'webdriverio',
      instances: [
        { browser: 'chrome' },
      ],
      headless: true,
    },
  },
})
```

### Browser-Specific Test APIs

```ts
import { page, userEvent } from '@vitest/browser/context'

it('fills form', async () => {
  const input = page.getByLabelText(/username/i)
  await userEvent.fill(input, 'Alice')
  await expect.element(input).toHaveValue('Alice')
})
```

### Workspace: Split Node + Browser Tests

```ts
export default defineWorkspace([
  {
    test: {
      name: 'unit',
      include: ['src/**/*.test.ts'],
      environment: 'node',
    },
  },
  {
    test: {
      name: 'browser',
      include: ['src/**/*.browser.test.ts'],
      browser: {
        enabled: true,
        provider: 'playwright',
        instances: [{ browser: 'chromium' }],
      },
    },
  },
])
```

---

## Type Testing with expectTypeOf

Type tests use `.test-d.ts` extension and run at compile time via `tsc`.

### Core Assertions

```ts
import { expectTypeOf } from 'vitest'
import { createUser, type User } from './users'

test('createUser types', () => {
  // Function signatures
  expectTypeOf(createUser).toBeFunction()
  expectTypeOf(createUser).parameter(0).toMatchTypeOf<{ name: string }>()
  expectTypeOf(createUser).returns.toEqualTypeOf<Promise<User>>()

  // Type relationships
  expectTypeOf<User>().toMatchTypeOf<{ id: number; name: string }>()
  expectTypeOf<User>().not.toBeAny()
  expectTypeOf<User>().not.toBeNever()

  // Extract and inspect
  expectTypeOf<User>().toHaveProperty('id')
  expectTypeOf<User['id']>().toBeNumber()

  // Generics
  expectTypeOf<Promise<string>>().resolves.toBeString()
  expectTypeOf<Map<string, number>>().toEqualTypeOf<Map<string, number>>()

  // Callable
  type Callback = (a: string) => number
  expectTypeOf<Callback>().toBeCallableWith('hello')
  expectTypeOf<Callback>().returns.toBeNumber()
})
```

### Enable in Config

```ts
test: {
  typecheck: {
    enabled: true,
    tsconfig: './tsconfig.json',
    include: ['**/*.test-d.ts'],
    checker: 'tsc',  // or 'vue-tsc' for Vue
  },
}
```

---

## Benchmarking API

### Writing Benchmarks

```ts
// sort.bench.ts
import { bench, describe } from 'vitest'

describe('Array sorting', () => {
  const data = Array.from({ length: 10000 }, () => Math.random())

  bench('Array.sort', () => {
    [...data].sort((a, b) => a - b)
  })

  bench('custom quicksort', () => {
    quickSort([...data])
  }, {
    iterations: 100,
    time: 1000,       // minimum time in ms
    warmupTime: 200,  // warmup before measuring
    warmupIterations: 5,
  })
})
```

### Running and Comparing

```bash
vitest bench
vitest bench --outputJson baseline.json        # save results
vitest bench --compare baseline.json           # compare against saved
```

### Benchmark Config Options

```ts
test: {
  benchmark: {
    include: ['**/*.bench.ts'],
    exclude: ['node_modules'],
    outputJson: './bench-results.json',
  },
}
```

---

## In-Source Testing

Write tests alongside production code — stripped in production builds.

```ts
// src/math.ts
export function fibonacci(n: number): number {
  if (n <= 1) return n
  return fibonacci(n - 1) + fibonacci(n - 2)
}

if (import.meta.vitest) {
  const { it, expect } = import.meta.vitest
  it('fibonacci', () => {
    expect(fibonacci(0)).toBe(0)
    expect(fibonacci(5)).toBe(5)
    expect(fibonacci(10)).toBe(55)
  })
}
```

Config to enable:
```ts
export default defineConfig({
  define: { 'import.meta.vitest': 'undefined' }, // tree-shake in production
  test: { includeSource: ['src/**/*.ts'] },
})
```

---

## Concurrent and Sequential Control

```ts
// All tests in suite run in parallel
describe.concurrent('parallel suite', () => {
  it('test A', async ({ expect }) => { /* ... */ })
  it('test B', async ({ expect }) => { /* ... */ })
})

// Force sequential within a concurrent parent
describe.concurrent('mostly parallel', () => {
  it('parallel A', async () => {})
  it('parallel B', async () => {})
  describe.sequential('must be ordered', () => {
    it('step 1', async () => {})
    it('step 2', async () => {})
  })
})
```

> **Important:** Always use the `expect` from test context (not global) in concurrent tests to avoid snapshot conflicts.

---

## Dynamic Test Generation

```ts
const testCases = [
  { input: 'hello', expected: 'HELLO' },
  { input: 'world', expected: 'WORLD' },
  { input: '', expected: '' },
]

describe('toUpperCase', () => {
  test.each(testCases)('converts "$input" to "$expected"', ({ input, expected }) => {
    expect(input.toUpperCase()).toBe(expected)
  })

  // Tagged template literal form
  test.each`
    a    | b    | sum
    ${1} | ${2} | ${3}
    ${3} | ${4} | ${7}
  `('$a + $b = $sum', ({ a, b, sum }) => {
    expect(a + b).toBe(sum)
  })
})
```
