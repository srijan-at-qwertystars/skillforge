# Jest API Reference

## Table of Contents
- [Globals](#globals)
- [Expect & Matchers](#expect--matchers)
- [Mock Function API](#mock-function-api)
- [The jest Object](#the-jest-object)
- [Timer API](#timer-api)
- [Configuration Options](#configuration-options)

---

## Globals

All globals are auto-available in test files (no import needed).

### Test Definition
| Function | Description |
|----------|-------------|
| `test(name, fn, timeout?)` | Define a test case |
| `it(name, fn, timeout?)` | Alias for `test` |
| `test.only(name, fn)` | Run only this test (debugging) |
| `test.skip(name, fn)` | Skip this test |
| `test.todo(name)` | Placeholder for future test |
| `test.failing(name, fn)` | Test expected to fail |
| `test.each(table)(name, fn)` | Parameterized test |
| `test.concurrent(name, fn)` | Run test concurrently |

### Grouping
| Function | Description |
|----------|-------------|
| `describe(name, fn)` | Group related tests |
| `describe.only(name, fn)` | Run only this group |
| `describe.skip(name, fn)` | Skip this group |
| `describe.each(table)(name, fn)` | Parameterized group |

### Lifecycle Hooks
| Function | Scope | Description |
|----------|-------|-------------|
| `beforeAll(fn, timeout?)` | Once before all tests in block | Heavy setup (DB, server) |
| `afterAll(fn, timeout?)` | Once after all tests in block | Cleanup resources |
| `beforeEach(fn, timeout?)` | Before each test in block | Reset state |
| `afterEach(fn, timeout?)` | After each test in block | Restore mocks |

Hook execution order (nested describes):
```
beforeAll (outer) → beforeAll (inner) →
  beforeEach (outer) → beforeEach (inner) → test → afterEach (inner) → afterEach (outer)
→ afterAll (inner) → afterAll (outer)
```

---

## Expect & Matchers

### Core
| Matcher | Description |
|---------|-------------|
| `.toBe(value)` | Strict equality (`===`) — primitives |
| `.toEqual(value)` | Deep equality — objects/arrays |
| `.toStrictEqual(value)` | Deep equality + undefined props + array sparseness |
| `.not` | Negate any matcher |

### Truthiness
| Matcher | Description |
|---------|-------------|
| `.toBeTruthy()` | Truthy value |
| `.toBeFalsy()` | Falsy value |
| `.toBeNull()` | Strictly `null` |
| `.toBeUndefined()` | Strictly `undefined` |
| `.toBeDefined()` | Not `undefined` |
| `.toBeNaN()` | Is `NaN` |

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
| `.toMatch(regexp\|string)` | Regex or substring match |

### Arrays / Iterables
| Matcher | Description |
|---------|-------------|
| `.toContain(item)` | Strict equality in array |
| `.toContainEqual(item)` | Deep equality in array |
| `.toHaveLength(n)` | `.length` check |

### Objects
| Matcher | Description |
|---------|-------------|
| `.toHaveProperty(path, value?)` | Has property at path |
| `.toMatchObject(subset)` | Partial deep match |

### Exceptions
| Matcher | Description |
|---------|-------------|
| `.toThrow(error?)` | Throws (optionally matching message/class/regex) |

### Snapshots
| Matcher | Description |
|---------|-------------|
| `.toMatchSnapshot(hint?)` | Match file snapshot |
| `.toMatchInlineSnapshot(snap?)` | Match inline snapshot |
| `.toThrowErrorMatchingSnapshot()` | Error message matches snapshot |

### Mock Matchers
| Matcher | Description |
|---------|-------------|
| `.toHaveBeenCalled()` | Mock was called at least once |
| `.toHaveBeenCalledTimes(n)` | Called exactly n times |
| `.toHaveBeenCalledWith(...args)` | Called with specific args |
| `.toHaveBeenLastCalledWith(...args)` | Last call had these args |
| `.toHaveBeenNthCalledWith(n, ...args)` | Nth call had these args |
| `.toHaveReturned()` | Returned (didn't throw) |
| `.toHaveReturnedTimes(n)` | Returned n times |
| `.toHaveReturnedWith(value)` | Returned this value |
| `.toHaveLastReturnedWith(value)` | Last return was this value |

### Asymmetric Matchers
Use inside `toEqual`, `toHaveBeenCalledWith`, etc. for partial matching:
```ts
expect.any(Constructor)            // any instance of type
expect.anything()                  // any value except null/undefined
expect.arrayContaining([...])      // array containing these items
expect.objectContaining({...})     // object containing these props
expect.stringContaining(str)       // string containing substring
expect.stringMatching(regexp)      // string matching regex
expect.not.arrayContaining([...])  // array NOT containing items
expect.not.objectContaining({...}) // object NOT containing props
```

### Utilities
| Function | Description |
|----------|-------------|
| `expect.assertions(n)` | Exactly n assertions must run |
| `expect.hasAssertions()` | At least 1 assertion must run |
| `expect.extend(matchers)` | Add custom matchers |
| `expect.addSnapshotSerializer(serializer)` | Custom snapshot format |

---

## Mock Function API

### Creating Mocks
```ts
const fn = jest.fn();                         // no-op mock
const fn = jest.fn(x => x * 2);              // with implementation
const fn = jest.fn<(a: number) => string>(); // typed (TS)
```

### Mock Return Values
| Method | Description |
|--------|-------------|
| `.mockReturnValue(val)` | Always return `val` |
| `.mockReturnValueOnce(val)` | Return `val` once, then default |
| `.mockResolvedValue(val)` | Return `Promise.resolve(val)` |
| `.mockResolvedValueOnce(val)` | Resolve once |
| `.mockRejectedValue(err)` | Return `Promise.reject(err)` |
| `.mockRejectedValueOnce(err)` | Reject once |
| `.mockImplementation(fn)` | Replace implementation |
| `.mockImplementationOnce(fn)` | Replace once |

### Mock Properties
| Property | Description |
|----------|-------------|
| `.mock.calls` | `Array<Array<any>>` — all call arguments |
| `.mock.results` | `Array<{type, value}>` — return values |
| `.mock.instances` | `Array<any>` — `this` contexts |
| `.mock.lastCall` | Arguments of last call |
| `.mock.contexts` | `Array<any>` — `this` for each call |

### Mock Cleanup
| Method | Clears calls/results | Resets return values | Restores original |
|--------|:---:|:---:|:---:|
| `.mockClear()` | ✅ | ❌ | ❌ |
| `.mockReset()` | ✅ | ✅ | ❌ |
| `.mockRestore()` | ✅ | ✅ | ✅ |

### Spying
```ts
const spy = jest.spyOn(obj, 'method');                     // spy, keep impl
const spy = jest.spyOn(obj, 'method').mockReturnValue(42); // spy + mock
const spy = jest.spyOn(obj, 'prop', 'get');                // getter spy
const spy = jest.spyOn(obj, 'prop', 'set');                // setter spy
```

### Module Mocking
```ts
jest.mock('./module');                        // auto-mock all exports
jest.mock('./module', () => ({ fn: jest.fn() })); // factory mock
jest.mock('./module', () => ({               // partial mock
  ...jest.requireActual('./module'),
  specificFn: jest.fn(),
}));
jest.doMock('./module', factory);            // not hoisted
jest.dontMock('./module');                   // not hoisted unmock
jest.requireActual('./module');              // get real module
jest.requireMock('./module');                // get mocked module
```

### Global Mock Control
| Method | Description |
|--------|-------------|
| `jest.clearAllMocks()` | Clear all mock call/instance data |
| `jest.resetAllMocks()` | Clear + reset return values/implementations |
| `jest.restoreAllMocks()` | Clear + reset + restore originals (spyOn) |
| `jest.resetModules()` | Reset module registry |
| `jest.isolateModules(fn)` | Isolated module registry for `fn` |
| `jest.isolateModulesAsync(fn)` | Async version |

---

## The jest Object

### Module System
| Method | Description |
|--------|-------------|
| `jest.mock(module, factory?, options?)` | Mock a module (hoisted) |
| `jest.unmock(module)` | Unmock a module |
| `jest.doMock(module, factory?)` | Mock without hoisting |
| `jest.dontMock(module)` | Don't mock without hoisting |
| `jest.resetModules()` | Clear module cache |
| `jest.isolateModules(fn)` | Scoped module cache |
| `jest.requireActual(module)` | Import real module |
| `jest.requireMock(module)` | Import mock version |

### Fake Timers (see Timer API below)
### Misc
| Method | Description |
|--------|-------------|
| `jest.setTimeout(ms)` | Set default test timeout |
| `jest.retryTimes(n, options?)` | Retry failing tests |
| `jest.getSeed()` | Get randomization seed |

---

## Timer API

### Setup
```ts
jest.useFakeTimers();              // replace all timers
jest.useFakeTimers({               // selective
  advanceTimers: true,             // auto-advance on await
  doNotFake: ['nextTick'],         // keep some real
  now: new Date('2024-01-01'),     // set system time
  timerLimit: 100,                 // prevent infinite loops
});
jest.useRealTimers();              // restore real timers
```

### Advancing Time
| Method | Description |
|--------|-------------|
| `jest.advanceTimersByTime(ms)` | Advance by ms, firing timers |
| `jest.advanceTimersByTimeAsync(ms)` | Async version (resolves microtasks) |
| `jest.advanceTimersToNextTimer(steps?)` | Advance to next timer |
| `jest.advanceTimersToNextTimerAsync(steps?)` | Async version |
| `jest.runAllTimers()` | Exhaust all timers |
| `jest.runAllTimersAsync()` | Async version |
| `jest.runOnlyPendingTimers()` | Run only currently queued timers |
| `jest.runOnlyPendingTimersAsync()` | Async version |

### Inspection
| Method | Description |
|--------|-------------|
| `jest.getTimerCount()` | Number of pending timers |
| `jest.clearAllTimers()` | Remove all pending timers |
| `jest.now()` | Current fake time (ms since epoch) |

### System Time
```ts
jest.setSystemTime(new Date('2024-06-15'));  // set Date.now()
jest.getRealSystemTime();                    // actual system time
```

---

## Configuration Options

### Essential Options
```ts
import type { Config } from 'jest';
const config: Config = {
  // Test Environment
  testEnvironment: 'node',           // 'node' | 'jsdom' | custom path
  testEnvironmentOptions: {},        // passed to environment constructor

  // Test Discovery
  roots: ['<rootDir>/src'],
  testMatch: ['**/__tests__/**/*.[jt]s?(x)', '**/?(*.)+(spec|test).[jt]s?(x)'],
  testPathIgnorePatterns: ['/node_modules/'],
  testRegex: undefined,              // alternative to testMatch

  // Transforms
  transform: {
    '^.+\\.tsx?$': 'ts-jest',        // or '@swc/jest' or 'babel-jest'
  },
  transformIgnorePatterns: ['/node_modules/'],

  // Module Resolution
  moduleNameMapper: {},
  moduleDirectories: ['node_modules'],
  moduleFileExtensions: ['js', 'jsx', 'ts', 'tsx', 'json', 'node'],
  modulePaths: [],

  // Setup/Teardown
  setupFiles: [],                    // before test framework
  setupFilesAfterEnv: [],            // after test framework (put matchers here)
  globalSetup: undefined,            // path to module
  globalTeardown: undefined,

  // Coverage
  collectCoverage: false,
  collectCoverageFrom: ['src/**/*.{ts,tsx}', '!**/*.d.ts'],
  coverageDirectory: 'coverage',
  coveragePathIgnorePatterns: ['/node_modules/'],
  coverageProvider: 'v8',            // 'v8' | 'babel'
  coverageReporters: ['text', 'lcov', 'clover'],
  coverageThreshold: {
    global: { branches: 80, functions: 80, lines: 80, statements: 80 },
  },

  // Mocking
  automock: false,
  clearMocks: false,                 // auto clearAllMocks after each test
  resetMocks: false,                 // auto resetAllMocks after each test
  restoreMocks: false,               // auto restoreAllMocks after each test

  // Performance
  maxWorkers: '50%',
  workerThreads: false,
  cacheDirectory: '/tmp/jest_cache',
  workerIdleMemoryLimit: undefined,  // e.g. '512MB'

  // Execution
  bail: 0,                           // stop after N failures (0 = don't stop)
  testTimeout: 5000,                 // per-test timeout in ms
  verbose: false,
  errorOnDeprecated: false,
  testSequencer: '@jest/test-sequencer',

  // Reporters
  reporters: ['default'],
  // reporters: ['default', ['jest-junit', { outputDirectory: 'reports' }]],

  // Snapshots
  snapshotFormat: { printBasicPrototype: false },
  snapshotSerializers: [],

  // Projects (monorepo)
  projects: undefined,
  // projects: ['<rootDir>/packages/*'],

  // Advanced
  globals: {},
  preset: undefined,                 // e.g. 'ts-jest'
  runner: 'jest-runner',
  watchPlugins: [],
  watchPathIgnorePatterns: [],
  detectOpenHandles: false,
  forceExit: false,
  injectGlobals: true,               // false = must import from @jest/globals
};
```

### CLI Flags Quick Reference
```bash
jest                              # run all tests
jest --watch                      # watch mode
jest --watchAll                   # watch all files
jest --coverage                   # with coverage
jest --verbose                    # detailed output
jest --bail=1                     # stop on first failure
jest --runInBand                  # serial execution
jest --detectOpenHandles          # find resource leaks
jest --forceExit                  # force exit (avoid if possible)
jest --onlyChanged                # only files changed since last commit
jest --changedSince=main          # changed since branch
jest --shard=1/3                  # shard for CI parallelism
jest -t 'pattern'                 # run tests matching name
jest --testPathPattern='auth'     # run files matching path
jest --updateSnapshot             # update snapshots
jest --ci                         # CI mode (no snapshot auto-update)
jest --json --outputFile=out.json # machine-readable output
jest --logHeapUsage               # show memory per suite
jest --maxWorkers=4               # limit parallelism
jest --passWithNoTests            # don't fail if no tests found
jest --clearCache                 # clear transform cache
jest --showConfig                 # print resolved config
```
