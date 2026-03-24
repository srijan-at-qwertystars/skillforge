# Vitest API Reference

## Table of Contents

- [Test Suite Functions](#test-suite-functions)
- [Lifecycle Hooks](#lifecycle-hooks)
- [vi Object — Mock Utilities](#vi-object--mock-utilities)
- [expect Matchers](#expect-matchers)
- [Asymmetric Matchers](#asymmetric-matchers)
- [Mock Function Properties](#mock-function-properties)
- [Test Context API](#test-context-api)
- [Snapshot API](#snapshot-api)
- [Type Testing API (expectTypeOf)](#type-testing-api-expecttypeof)
- [Benchmarking API](#benchmarking-api)
- [Configuration Reference](#configuration-reference)

---

## Test Suite Functions

### test / it

```ts
test(name: string, fn: TestFunction, timeout?: number)
test(name: string, options: TestOptions, fn: TestFunction)
it(name: string, fn: TestFunction, timeout?: number)
```

Aliases: `test` and `it` are identical.

### Variants

| Function | Description |
|----------|-------------|
| `test(name, fn)` | Standard test |
| `test.skip(name, fn)` | Skip this test |
| `test.only(name, fn)` | Run only this test (debug use) |
| `test.todo(name)` | Placeholder for future test |
| `test.fails(name, fn)` | Expect this test to fail |
| `test.concurrent(name, fn)` | Run test in parallel |
| `test.sequential(name, fn)` | Force sequential within concurrent suite |
| `test.each(cases)(name, fn)` | Parameterized test |
| `test.skipIf(condition)(name, fn)` | Conditional skip |
| `test.runIf(condition)(name, fn)` | Conditional run |
| `test.extend(fixtures)` | Create test with custom fixtures |
| `test.for(cases)(name, fn)` | Data-driven test (alternative to each) |
| `test.scoped(fn)` | Run with scoped setup |

### describe

```ts
describe(name: string, fn: () => void)
```

| Function | Description |
|----------|-------------|
| `describe(name, fn)` | Group related tests |
| `describe.skip(name, fn)` | Skip entire suite |
| `describe.only(name, fn)` | Run only this suite |
| `describe.todo(name)` | Placeholder suite |
| `describe.concurrent(name, fn)` | Run all tests in suite concurrently |
| `describe.sequential(name, fn)` | Force sequential in concurrent parent |
| `describe.shuffle(name, fn)` | Randomize test order within suite |
| `describe.each(cases)(name, fn)` | Parameterized suite |
| `describe.skipIf(cond)(name, fn)` | Conditional skip |
| `describe.runIf(cond)(name, fn)` | Conditional run |

### test.each Formats

```ts
// Array of arrays
test.each([
  [1, 2, 3],
  [4, 5, 9],
])('add(%i, %i) = %i', (a, b, expected) => {
  expect(a + b).toBe(expected)
})

// Array of objects
test.each([
  { input: 'hello', expected: 'HELLO' },
  { input: 'world', expected: 'WORLD' },
])('uppercase "$input" → "$expected"', ({ input, expected }) => {
  expect(input.toUpperCase()).toBe(expected)
})

// Tagged template literal
test.each`
  a    | b    | sum
  ${1} | ${2} | ${3}
  ${3} | ${4} | ${7}
`('$a + $b = $sum', ({ a, b, sum }) => {
  expect(a + b).toBe(sum)
})
```

### Printf Formatting in test.each Names

| Token | Type |
|-------|------|
| `%s` | String |
| `%d` / `%i` | Integer |
| `%f` | Float |
| `%j` | JSON |
| `%o` | Object |
| `%%` | Literal `%` |
| `$variable` | Object property (with object args) |

---

## Lifecycle Hooks

```ts
beforeAll(fn: () => Awaitable<void>, timeout?: number)
afterAll(fn: () => Awaitable<void>, timeout?: number)
beforeEach(fn: () => Awaitable<void>, timeout?: number)
afterEach(fn: () => Awaitable<void>, timeout?: number)
```

### Execution Order

```
beforeAll
  beforeEach → test 1 → afterEach
  beforeEach → test 2 → afterEach
afterAll
```

### Hook Return Value for Teardown

```ts
beforeEach(() => {
  const server = startServer()
  return () => server.close() // returned fn runs as teardown
})
```

### Setup Files

```ts
// vitest.config.ts
test: {
  setupFiles: ['./vitest.setup.ts'],
  globalSetup: ['./vitest.global-setup.ts'], // runs once for entire suite
}
```

**Global setup** exports `setup` and `teardown` functions:
```ts
// vitest.global-setup.ts
export async function setup() {
  await startDatabase()
}
export async function teardown() {
  await stopDatabase()
}
```

---

## vi Object — Mock Utilities

### Mock Functions

| Method | Description |
|--------|-------------|
| `vi.fn()` | Create a mock function |
| `vi.fn(implementation)` | Create with implementation |
| `vi.spyOn(obj, method)` | Spy on existing method |
| `vi.spyOn(obj, prop, 'get')` | Spy on getter |
| `vi.spyOn(obj, prop, 'set')` | Spy on setter |
| `vi.mocked(fn)` | Cast function to mocked type (TypeScript) |
| `vi.mocked(fn, { deep: true })` | Deep mock typing |

### Module Mocking

| Method | Description |
|--------|-------------|
| `vi.mock(path)` | Auto-mock module (all exports → `vi.fn()`) |
| `vi.mock(path, factory)` | Mock with custom factory |
| `vi.mock(path, { spy: true })` | Keep real impl but make all exports spies |
| `vi.importActual<T>(path)` | Import real module inside factory |
| `vi.importMock<T>(path)` | Import auto-mocked module |
| `vi.unmock(path)` | Remove mock for module |
| `vi.doMock(path, factory)` | Non-hoisted mock (for dynamic imports) |
| `vi.doUnmock(path)` | Non-hoisted unmock |
| `vi.resetModules()` | Clear module cache |
| `vi.hoisted(factory)` | Declare hoisted variable for use in mock factories |

### Timer Mocking

| Method | Description |
|--------|-------------|
| `vi.useFakeTimers(config?)` | Replace timer APIs with fakes |
| `vi.useRealTimers()` | Restore real timers |
| `vi.advanceTimersByTime(ms)` | Fast-forward time |
| `vi.advanceTimersByTimeAsync(ms)` | Async version |
| `vi.advanceTimersToNextTimer()` | Advance to next pending timer |
| `vi.advanceTimersToNextTimerAsync()` | Async version |
| `vi.runAllTimers()` | Run all pending timers |
| `vi.runAllTimersAsync()` | Async version |
| `vi.runOnlyPendingTimers()` | Run only currently pending |
| `vi.runOnlyPendingTimersAsync()` | Async version |
| `vi.setSystemTime(date)` | Set fake `Date.now()` |
| `vi.getMockedSystemTime()` | Get current fake time |
| `vi.getRealSystemTime()` | Get real system time |
| `vi.getTimerCount()` | Number of pending timers |
| `vi.isFakeTimers()` | Check if fake timers active |

### vi.useFakeTimers Config

```ts
vi.useFakeTimers({
  toFake: ['setTimeout', 'setInterval', 'Date'], // which APIs to fake
  now: new Date('2024-01-01'),                    // initial Date.now()
  shouldAdvanceTime: false,                        // auto-advance?
  advanceTimeDelta: 20,                            // ms to advance per tick
  shouldClearNativeTimers: false,                  // clear native timers?
})
```

### Global Stubs

| Method | Description |
|--------|-------------|
| `vi.stubGlobal(name, value)` | Stub a global variable |
| `vi.unstubAllGlobals()` | Restore all stubbed globals |
| `vi.stubEnv(name, value)` | Stub `process.env` variable |
| `vi.unstubAllEnvs()` | Restore all stubbed env vars |

### Mock State Management

| Method | Description |
|--------|-------------|
| `vi.clearAllMocks()` | Clear call history for all mocks |
| `vi.resetAllMocks()` | Clear history + reset implementations |
| `vi.restoreAllMocks()` | Restore original implementations |

### Miscellaneous

| Method | Description |
|--------|-------------|
| `vi.waitFor(callback, options?)` | Retry callback until it passes |
| `vi.waitUntil(callback, options?)` | Wait for truthy return |
| `vi.dynamicImportSettled()` | Wait for dynamic imports to settle |

### vi.waitFor

```ts
// Retry assertion until it passes (useful for async state)
await vi.waitFor(() => {
  expect(element.textContent).toBe('loaded')
}, {
  timeout: 5000,   // max wait time
  interval: 100,   // check every N ms
})
```

---

## expect Matchers

### Equality

| Matcher | Description |
|---------|-------------|
| `.toBe(value)` | Strict equality (`===`, `Object.is`) |
| `.toEqual(value)` | Deep equality (ignores `undefined` properties) |
| `.toStrictEqual(value)` | Deep equality (checks `undefined` props + class instances) |

### Truthiness

| Matcher | Description |
|---------|-------------|
| `.toBeTruthy()` | Truthy check |
| `.toBeFalsy()` | Falsy check |
| `.toBeNull()` | `=== null` |
| `.toBeUndefined()` | `=== undefined` |
| `.toBeDefined()` | `!== undefined` |
| `.toBeNaN()` | `Number.isNaN` |

### Numbers

| Matcher | Description |
|---------|-------------|
| `.toBeGreaterThan(n)` | `>` |
| `.toBeGreaterThanOrEqual(n)` | `>=` |
| `.toBeLessThan(n)` | `<` |
| `.toBeLessThanOrEqual(n)` | `<=` |
| `.toBeCloseTo(n, digits?)` | Float comparison (default 5 digits) |

### Strings

| Matcher | Description |
|---------|-------------|
| `.toMatch(regexp \| string)` | Regex or substring match |
| `.toContain(string)` | Substring check |
| `.toHaveLength(n)` | String/array length |

### Arrays / Iterables

| Matcher | Description |
|---------|-------------|
| `.toContain(item)` | Shallow `===` check |
| `.toContainEqual(item)` | Deep equality check |
| `.toHaveLength(n)` | Array length |

### Objects

| Matcher | Description |
|---------|-------------|
| `.toHaveProperty(path, value?)` | Property exists (dot notation ok) |
| `.toMatchObject(subset)` | Object contains subset |
| `.toEqual(value)` | Deep equality |

### Exceptions

| Matcher | Description |
|---------|-------------|
| `.toThrow()` | Throws anything |
| `.toThrow(message)` | Throws with message (string or regex) |
| `.toThrowError(message)` | Alias for `.toThrow()` |
| `.toThrowErrorMatchingSnapshot()` | Thrown error matches snapshot |
| `.toThrowErrorMatchingInlineSnapshot()` | Inline snapshot variant |

### Promises

```ts
await expect(promise).resolves.toBe('value')
await expect(promise).rejects.toThrow('error')
await expect(promise).resolves.toEqual({ id: 1 })
```

### Mock Matchers

| Matcher | Description |
|---------|-------------|
| `.toHaveBeenCalled()` | Called at least once |
| `.toHaveBeenCalledTimes(n)` | Called exactly n times |
| `.toHaveBeenCalledWith(...args)` | Called with specific args |
| `.toHaveBeenLastCalledWith(...args)` | Last call had these args |
| `.toHaveBeenNthCalledWith(n, ...args)` | Nth call had these args |
| `.toHaveReturned()` | Returned (didn't throw) |
| `.toHaveReturnedTimes(n)` | Returned n times |
| `.toHaveReturnedWith(value)` | Returned specific value |
| `.toHaveLastReturnedWith(value)` | Last return was value |
| `.toHaveNthReturnedWith(n, value)` | Nth return was value |

### Modifiers

| Modifier | Description |
|----------|-------------|
| `.not` | Negate the matcher |
| `.soft` | Non-throwing assertion (collect all failures) |
| `.resolves` | Unwrap resolved promise |
| `.rejects` | Unwrap rejected promise |

### Soft Assertions

```ts
it('collects all failures', () => {
  expect.soft(1).toBe(2)    // records failure, continues
  expect.soft('a').toBe('b') // records failure, continues
  // test reports both failures at end
})
```

---

## Asymmetric Matchers

Use inside `toEqual`, `toHaveBeenCalledWith`, etc. to match partially.

| Matcher | Description |
|---------|-------------|
| `expect.anything()` | Matches anything except `null`/`undefined` |
| `expect.any(Constructor)` | Matches any instance of Constructor |
| `expect.stringContaining(str)` | String contains substring |
| `expect.stringMatching(regexp)` | String matches regex |
| `expect.arrayContaining(arr)` | Array contains all items |
| `expect.objectContaining(obj)` | Object contains subset |
| `expect.not.arrayContaining(arr)` | Array does NOT contain items |
| `expect.not.objectContaining(obj)` | Object does NOT contain subset |
| `expect.not.stringContaining(str)` | String does NOT contain |
| `expect.not.stringMatching(regexp)` | String does NOT match |
| `expect.closeTo(n, digits?)` | Asymmetric float comparison |

### Usage Example

```ts
expect(fn).toHaveBeenCalledWith(
  expect.objectContaining({ id: expect.any(Number) }),
  expect.stringMatching(/^user-/),
)

expect(result).toEqual({
  id: expect.any(Number),
  name: expect.any(String),
  createdAt: expect.any(Date),
  tags: expect.arrayContaining(['active']),
})
```

---

## Mock Function Properties

Given `const fn = vi.fn()`:

| Property | Description |
|----------|-------------|
| `fn.mock.calls` | `any[][]` — all call arguments |
| `fn.mock.results` | `{ type: 'return' \| 'throw', value: any }[]` |
| `fn.mock.instances` | `any[]` — `this` context for each call |
| `fn.mock.lastCall` | `any[]` — arguments of most recent call |
| `fn.mock.contexts` | `any[]` — `this` for each call |

### Mock Configuration Methods

| Method | Description |
|--------|-------------|
| `.mockReturnValue(value)` | Default return value |
| `.mockReturnValueOnce(value)` | One-time return value |
| `.mockResolvedValue(value)` | Default `Promise.resolve(value)` |
| `.mockResolvedValueOnce(value)` | One-time resolved value |
| `.mockRejectedValue(error)` | Default `Promise.reject(error)` |
| `.mockRejectedValueOnce(error)` | One-time rejected value |
| `.mockImplementation(fn)` | Replace implementation |
| `.mockImplementationOnce(fn)` | One-time implementation |
| `.mockReturnThis()` | Return `this` |
| `.mockClear()` | Clear call history |
| `.mockReset()` | Clear history + reset return values |
| `.mockRestore()` | Restore original (only for spies) |
| `.mockName(name)` | Set mock name (for error messages) |
| `.getMockName()` | Get mock name |
| `.getMockImplementation()` | Get current implementation |

---

## Test Context API

Each test callback receives a context object:

```ts
it('test', (context) => { /* ... */ })
// or destructured:
it('test', ({ expect, task, skip, onTestFailed, onTestFinished }) => {})
```

### Context Properties

| Property | Type | Description |
|----------|------|-------------|
| `task` | `TaskMeta` | Test metadata (name, id, file, suite, mode) |
| `expect` | `ExpectStatic` | Scoped expect (required for concurrent tests) |
| `skip` | `(reason?: string) => void` | Dynamically skip test |

### Context Methods

| Method | Description |
|--------|-------------|
| `onTestFailed(fn)` | Hook that runs if test fails |
| `onTestFinished(fn)` | Hook that runs when test finishes (pass or fail) |

### Extending Context with test.extend

```ts
interface MyFixtures {
  db: Database
  user: User
}

const test = base.extend<MyFixtures>({
  db: async ({}, use) => {
    const db = await connectDB()
    await use(db)
    await db.close()
  },
  user: async ({ db }, use) => {
    const user = await db.createUser({ name: 'Test' })
    await use(user)
    await db.deleteUser(user.id)
  },
})
```

---

## Snapshot API

| Method | Description |
|--------|-------------|
| `expect(val).toMatchSnapshot(hint?)` | File snapshot (`.snap` file) |
| `expect(val).toMatchInlineSnapshot(str?)` | Inline snapshot in test file |
| `expect(val).toMatchFileSnapshot(path)` | Compare against external file |
| `expect(fn).toThrowErrorMatchingSnapshot()` | Snapshot of thrown error |
| `expect(fn).toThrowErrorMatchingInlineSnapshot()` | Inline error snapshot |
| `expect.addSnapshotSerializer(serializer)` | Register custom serializer |

### Snapshot Serializer Interface

```ts
interface SnapshotSerializer {
  test(value: unknown): boolean
  print(value: unknown, serialize: (val: unknown) => string, indent: (str: string) => string): string
}
```

### Snapshot CLI Flags

| Flag | Description |
|------|-------------|
| `--update` / `-u` | Update snapshots |
| `--snapshot.summary` | Show snapshot summary |
| `--snapshot.max-file-size` | Max snapshot file size |

---

## Type Testing API (expectTypeOf)

For `.test-d.ts` files with `typecheck.enabled: true`.

| Method | Description |
|--------|-------------|
| `expectTypeOf<T>()` | Start type assertion chain |
| `expectTypeOf(value)` | Infer type from runtime value |
| `.toBeString()` | Type is `string` |
| `.toBeNumber()` | Type is `number` |
| `.toBeBoolean()` | Type is `boolean` |
| `.toBeFunction()` | Type is a function |
| `.toBeObject()` | Type is an object |
| `.toBeArray()` | Type is an array |
| `.toBeNull()` | Type is `null` |
| `.toBeUndefined()` | Type is `undefined` |
| `.toBeNever()` | Type is `never` |
| `.toBeAny()` | Type is `any` |
| `.toBeUnknown()` | Type is `unknown` |
| `.toBeVoid()` | Type is `void` |
| `.toBeSymbol()` | Type is `symbol` |
| `.toBeNullable()` | Type includes `null` or `undefined` |
| `.toEqualTypeOf<U>()` | Exact type match |
| `.toMatchTypeOf<U>()` | Assignable to U |
| `.not` | Negate |
| `.parameter(n)` | Nth parameter type |
| `.parameters` | Tuple of all parameter types |
| `.returns` | Return type |
| `.resolves` | Unwrap `Promise<T>` to `T` |
| `.items` | Array element type |
| `.toHaveProperty(name)` | Type has property |
| `.toBeCallableWith(...args)` | Function accepts these args |
| `.toBeConstructibleWith(...args)` | Constructor accepts these args |
| `.extract<U>()` | Extract matching union member |
| `.exclude<U>()` | Exclude matching union member |

---

## Benchmarking API

```ts
import { bench, describe } from 'vitest'

bench(name: string, fn: BenchFunction, options?: BenchOptions)
```

### BenchOptions

| Option | Type | Description |
|--------|------|-------------|
| `iterations` | `number` | Min iterations |
| `time` | `number` | Min time (ms) |
| `warmupTime` | `number` | Warmup duration (ms) |
| `warmupIterations` | `number` | Warmup iterations |
| `throws` | `boolean` | Allow bench to throw |
| `setup` | `(task, mode) => void` | Per-iteration setup |
| `teardown` | `(task, mode) => void` | Per-iteration teardown |

### Benchmark CLI

```bash
vitest bench                                 # run all benchmarks
vitest bench --outputJson results.json       # save results
vitest bench --compare baseline.json         # compare against saved
```

---

## Configuration Reference

### Test Runner Options

```ts
export default defineConfig({
  test: {
    // File patterns
    include: ['**/*.{test,spec}.{ts,tsx,js,jsx}'],
    exclude: ['node_modules', 'dist', 'e2e'],
    includeSource: ['src/**/*.ts'],         // in-source testing

    // Environment
    environment: 'node',                    // 'node' | 'jsdom' | 'happy-dom' | 'edge-runtime'
    environmentOptions: {},                 // passed to environment
    globals: true,                          // describe/it/expect without imports

    // Execution
    pool: 'forks',                          // 'threads' | 'forks' | 'vmThreads'
    poolOptions: {
      threads: { minThreads: 1, maxThreads: 4 },
      forks: { minForks: 1, maxForks: 4, singleFork: false },
    },
    fileParallelism: true,                  // run test files in parallel
    maxConcurrency: 5,                      // max concurrent tests in a file
    isolate: true,                          // isolate test environments
    sequence: {
      shuffle: false,                       // randomize order
      concurrent: false,                    // run tests concurrently by default
      seed: 0,                              // shuffle seed
    },

    // Timeouts
    testTimeout: 5000,
    hookTimeout: 10000,
    teardownTimeout: 10000,

    // Retries
    retry: 0,
    bail: 0,                                // stop after N failures (0 = don't bail)

    // Setup / teardown
    setupFiles: ['./vitest.setup.ts'],
    globalSetup: ['./global-setup.ts'],

    // Reporters
    reporters: ['default'],                 // 'default'|'verbose'|'dot'|'json'|'junit'|'html'|'hanging-process'
    outputFile: {
      json: './test-results.json',
      junit: './junit.xml',
    },

    // Snapshot
    snapshotFormat: {
      printBasicPrototype: false,
    },
    snapshotSerializers: [],

    // Mocking
    mockReset: false,                       // reset mocks between tests
    restoreMocks: false,                    // restore spies between tests
    clearMocks: false,                      // clear call history between tests
    unstubEnvs: false,                      // restore env vars between tests
    unstubGlobals: false,                   // restore globals between tests

    // CSS
    css: true,                              // true | false | { modules, include, exclude }

    // Path resolution
    alias: { '@': './src' },
    root: '.',
    dir: '.',

    // Coverage
    coverage: {
      provider: 'v8',                       // 'v8' | 'istanbul'
      enabled: false,
      reporter: ['text', 'html', 'lcov', 'json'],
      reportsDirectory: './coverage',
      include: ['src/**'],
      exclude: ['**/*.test.*', '**/*.d.ts'],
      all: true,
      clean: true,
      thresholds: {
        lines: 80,
        branches: 75,
        functions: 80,
        statements: 80,
        perFile: false,
        autoUpdate: false,
      },
    },

    // Type checking
    typecheck: {
      enabled: false,
      tsconfig: './tsconfig.json',
      checker: 'tsc',                       // 'tsc' | 'vue-tsc'
      include: ['**/*.test-d.ts'],
      ignoreSourceErrors: false,
    },

    // Browser mode
    browser: {
      enabled: false,
      provider: 'playwright',               // 'playwright' | 'webdriverio'
      instances: [{ browser: 'chromium' }],
      headless: true,
    },

    // Benchmark
    benchmark: {
      include: ['**/*.bench.{ts,js}'],
      exclude: ['node_modules'],
      outputJson: undefined,
    },

    // Watch
    watch: true,                             // enable watch mode (default in dev)
    watchExclude: ['**/node_modules/**', '**/dist/**'],
    forceRerunTriggers: ['**/vitest.config.*'],

    // Other
    open: false,                             // open UI/browser automatically
    allowOnly: false,                        // allow .only in CI (set false for CI)
    dangerouslyIgnoreUnhandledErrors: false,
    passWithNoTests: false,
    logHeapUsage: false,
    silent: false,
  },
})
```

### CLI Flags Quick Reference

| Flag | Description |
|------|-------------|
| `vitest` | Run in watch mode |
| `vitest run` | Single run (no watch) |
| `vitest run --coverage` | Run with coverage |
| `vitest --reporter=verbose` | Verbose output |
| `vitest -t "pattern"` | Filter by test name |
| `vitest path/to/test.ts` | Run specific file |
| `vitest --bail=3` | Stop after 3 failures |
| `vitest --changed` | Only changed files (needs git) |
| `vitest --update` / `-u` | Update snapshots |
| `vitest --ui` | Open browser UI |
| `vitest bench` | Run benchmarks |
| `vitest typecheck` | Run type tests |
| `vitest list` | List test files |
| `vitest --project=name` | Run specific workspace project |
| `vitest --sequence.shuffle` | Randomize order |
| `vitest --inspect-brk` | Debug with Node inspector |
| `vitest --no-file-parallelism` | Run files serially |
| `vitest --retry=2` | Retry failed tests |
| `vitest --pool=forks` | Use forks pool |
| `vitest --browser` | Run in browser mode |
