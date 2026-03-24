---
name: jest-testing
description: |
  Expert skill for writing and debugging Jest tests in JavaScript/TypeScript projects. Covers test structure (describe/it/test), matchers, async testing, mocking (jest.fn/jest.mock/jest.spyOn/manual mocks), module mocking, timer mocking, snapshot testing, setup/teardown, parameterized tests, code coverage, configuration, transformers (ts-jest/@swc/jest/babel-jest), custom matchers, React component testing with @testing-library/react, and performance optimization. Triggers: "Jest", "jest.mock", "jest.fn", "jest.spyOn", "test suite", "snapshot testing", "describe block", "toMatchSnapshot", "jest.config", "__mocks__", "jest --coverage", "test.each". NOT for Vitest. NOT for Mocha/Chai. NOT for Playwright/Cypress E2E testing. NOT for pytest or other non-JS test frameworks. NOT for Storybook interaction tests.
---

# Jest Testing Skill

## Test Structure

Use `describe` to group related tests. Use `test` or `it` (aliases) for individual cases. Nest `describe` blocks for sub-grouping.

```ts
// Input: "Write tests for a calculator add function"
// Output:
describe('Calculator', () => {
  describe('add', () => {
    test('adds two positive numbers', () => {
      expect(add(2, 3)).toBe(5);
    });

    test('handles negative numbers', () => {
      expect(add(-1, -2)).toBe(-3);
    });

    test.todo('handles overflow');
  });
});
```

Use `test.only` to isolate a single test during debugging. Use `test.skip` to temporarily disable. Never commit `.only`.

## Matchers

### Equality
- `toBe(value)` — strict `===` equality, use for primitives
- `toEqual(value)` — deep equality, use for objects/arrays
- `toStrictEqual(value)` — deep equality + checks `undefined` properties and array sparseness

### Truthiness
- `toBeTruthy()`, `toBeFalsy()`, `toBeNull()`, `toBeUndefined()`, `toBeDefined()`

### Numbers
- `toBeGreaterThan(n)`, `toBeGreaterThanOrEqual(n)`, `toBeLessThan(n)`, `toBeCloseTo(n, digits)`

### Strings
- `toMatch(/regex/)`, `toMatch('substring')`

### Arrays / Iterables
- `toContain(item)` — strict equality check in array
- `toContainEqual(item)` — deep equality check in array
- `toHaveLength(n)`

### Objects
- `toHaveProperty('path')`, `toHaveProperty('path', value)`
- `toMatchObject(subset)` — partial deep match

### Exceptions
```ts
// Input: "Test that a function throws"
// Output:
test('throws on invalid input', () => {
  expect(() => parseJSON('{')).toThrow();
  expect(() => parseJSON('{')).toThrow(SyntaxError);
  expect(() => parseJSON('{')).toThrow(/Unexpected/);
});
```

### Negation
Chain `.not` before any matcher: `expect(value).not.toBe(other)`.

### Asymmetric Matchers
Use inside `toEqual`/`toHaveBeenCalledWith` for partial matching:
```ts
expect(obj).toEqual(expect.objectContaining({ id: expect.any(Number) }));
expect(arr).toEqual(expect.arrayContaining([1, 2]));
expect(str).toEqual(expect.stringMatching(/^hello/));
```

## Async Testing

### async/await (preferred)
```ts
test('fetches user', async () => {
  const user = await fetchUser(1);
  expect(user.name).toBe('Alice');
});
```

### resolves / rejects
```ts
test('resolves with data', async () => {
  await expect(fetchUser(1)).resolves.toEqual({ name: 'Alice' });
});

test('rejects on not found', async () => {
  await expect(fetchUser(999)).rejects.toThrow('Not found');
});
```

### done callback (legacy — avoid in new code)
```ts
test('callback style', (done) => {
  fetchData((err, data) => {
    expect(data).toBe('value');
    done();
  });
});
```

Always return or await the promise. A test with an unhandled async operation passes falsely.

## Mocking

### jest.fn() — standalone mock functions
```ts
// Input: "Mock a callback passed to a function"
// Output:
const callback = jest.fn();
forEach([1, 2, 3], callback);

expect(callback).toHaveBeenCalledTimes(3);
expect(callback).toHaveBeenNthCalledWith(1, 1);

// Mock return values
const getter = jest.fn()
  .mockReturnValueOnce('first')
  .mockReturnValueOnce('second')
  .mockReturnValue('default');

// Mock implementation
const compute = jest.fn().mockImplementation((x: number) => x * 2);
```

### jest.mock() — module mocking
Place at file top level. Jest hoists `jest.mock()` calls above imports.

```ts
// Input: "Mock an API module"
// Output:
import { getUser } from './api';
jest.mock('./api');
const mockedGetUser = getUser as jest.MockedFunction<typeof getUser>;

test('uses mocked API', async () => {
  mockedGetUser.mockResolvedValue({ id: 1, name: 'Alice' });
  const user = await mockedGetUser(1);
  expect(user.name).toBe('Alice');
});
```

### Partial module mocking
```ts
jest.mock('./utils', () => ({
  ...jest.requireActual('./utils'),
  formatDate: jest.fn(() => '2024-01-01'),
}));
```

### jest.spyOn() — spy on existing methods
```ts
const spy = jest.spyOn(Math, 'random').mockReturnValue(0.5);
expect(rollDice()).toBe(4);
spy.mockRestore(); // always restore
```

### Manual mocks (__mocks__ directory)
Create `__mocks__/axios.ts` adjacent to `node_modules` for third-party modules, or `__mocks__/myModule.ts` adjacent to the source file for local modules. Call `jest.mock('axios')` or `jest.mock('./myModule')` to activate.

```ts
// __mocks__/axios.ts
export default {
  get: jest.fn(() => Promise.resolve({ data: {} })),
  post: jest.fn(() => Promise.resolve({ data: {} })),
};
```

### Mock cleanup
```ts
afterEach(() => {
  jest.restoreAllMocks(); // restores spyOn originals
});
// Or in jest.config: restoreMocks: true
```

Prefer `restoreAllMocks` over `clearAllMocks` or `resetAllMocks` — it clears state AND restores original implementations.

## Timer Mocking

```ts
// Input: "Test a debounce function"
// Output:
beforeEach(() => jest.useFakeTimers());
afterEach(() => jest.useRealTimers());

test('debounce delays execution', () => {
  const fn = jest.fn();
  const debounced = debounce(fn, 300);

  debounced();
  expect(fn).not.toHaveBeenCalled();

  jest.advanceTimersByTime(300);
  expect(fn).toHaveBeenCalledTimes(1);
});
```

Key timer APIs:
- `jest.advanceTimersByTime(ms)` — advance by specific duration
- `jest.runAllTimers()` — exhaust all timers (careful with recursive timers)
- `jest.runOnlyPendingTimers()` — run currently queued timers only
- `jest.advanceTimersToNextTimer()` — advance to next timer

## Snapshot Testing

### File snapshots
```ts
test('renders correctly', () => {
  const tree = renderer.create(<Button label="OK" />).toJSON();
  expect(tree).toMatchSnapshot();
});
// First run: creates __snapshots__/Component.test.ts.snap
// Subsequent runs: compares against stored snapshot
// Update: jest --updateSnapshot or press 'u' in watch mode
```

### Inline snapshots
```ts
test('serializes config', () => {
  expect(getConfig()).toMatchInlineSnapshot(`
    {
      "debug": false,
      "port": 3000,
    }
  `);
});
// Jest writes/updates the snapshot argument automatically
```

Keep snapshots small and focused. Large snapshots become noise — prefer explicit assertions for critical values.

## Setup and Teardown

```ts
describe('Database tests', () => {
  beforeAll(async () => { await db.connect(); });
  afterAll(async () => { await db.disconnect(); });
  beforeEach(async () => { await db.clear(); });
  afterEach(() => { jest.restoreAllMocks(); });

  test('inserts record', async () => { /* ... */ });
});
```

Scoping: hooks in a `describe` only apply to tests in that block. Top-level hooks apply to all tests in the file.

## Parameterized Tests

### test.each
```ts
// Input: "Test multiple input/output pairs for a function"
// Output:
test.each([
  { input: '',       expected: true },
  { input: 'hello',  expected: false },
  { input: '  ',     expected: true },
])('isEmpty("$input") returns $expected', ({ input, expected }) => {
  expect(isEmpty(input)).toBe(expected);
});

// Tagged template literal form:
test.each`
  a    | b    | sum
  ${1} | ${2} | ${3}
  ${2} | ${3} | ${5}
`('$a + $b = $sum', ({ a, b, sum }) => {
  expect(a + b).toBe(sum);
});
```

### describe.each
```ts
describe.each(['postgres', 'mysql', 'sqlite'])('Database: %s', (dialect) => {
  test('connects', async () => { /* ... */ });
  test('queries', async () => { /* ... */ });
});
```

## Custom Matchers

```ts
// Input: "Create a custom matcher for date ranges"
// Output:
expect.extend({
  toBeWithinRange(received: number, floor: number, ceiling: number) {
    const pass = received >= floor && received <= ceiling;
    return {
      pass,
      message: () =>
        `expected ${received} ${pass ? 'not ' : ''}to be within [${floor}, ${ceiling}]`,
    };
  },
});

declare module 'expect' {
  interface Matchers<R> {
    toBeWithinRange(floor: number, ceiling: number): R;
  }
}

test('value in range', () => {
  expect(100).toBeWithinRange(90, 110);
  expect(50).not.toBeWithinRange(90, 110);
});
```

## React Component Testing

Use `@testing-library/react`. Test behavior, not implementation.

```tsx
// Input: "Test a login form component"
// Output:
import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { LoginForm } from './LoginForm';

test('submits credentials', async () => {
  const onSubmit = jest.fn();
  render(<LoginForm onSubmit={onSubmit} />);

  await userEvent.type(screen.getByLabelText(/email/i), 'a@b.com');
  await userEvent.type(screen.getByLabelText(/password/i), 'secret');
  await userEvent.click(screen.getByRole('button', { name: /log in/i }));

  await waitFor(() => {
    expect(onSubmit).toHaveBeenCalledWith({ email: 'a@b.com', password: 'secret' });
  });
});
```

### Testing hooks
```tsx
import { renderHook, act } from '@testing-library/react';
import { useCounter } from './useCounter';

test('increments counter', () => {
  const { result } = renderHook(() => useCounter());
  act(() => result.current.increment());
  expect(result.current.count).toBe(1);
});
```

### Testing with providers
```tsx
function renderWithProviders(ui: React.ReactElement) {
  return render(
    <QueryClientProvider client={new QueryClient()}>
      <ThemeProvider>{ui}</ThemeProvider>
    </QueryClientProvider>
  );
}
```

Query priority: `getByRole` > `getByLabelText` > `getByText` > `getByTestId`. Prefer accessible queries.

## Jest Configuration

### jest.config.ts
```ts
import type { Config } from 'jest';

const config: Config = {
  testEnvironment: 'jsdom',             // 'node' for backend
  roots: ['<rootDir>/src'],
  testMatch: ['**/*.test.ts(x)?'],
  setupFilesAfterEnv: ['<rootDir>/jest.setup.ts'],
  moduleNameMapper: {
    '^@/(.*)$': '<rootDir>/src/$1',     // path aliases
    '\\.(css|less|scss)$': 'identity-obj-proxy', // CSS modules
  },
  transform: {
    '^.+\\.tsx?$': ['ts-jest', { tsconfig: 'tsconfig.jest.json' }],
  },
  collectCoverageFrom: ['src/**/*.{ts,tsx}', '!src/**/*.d.ts'],
  coverageThreshold: {
    global: { branches: 80, functions: 80, lines: 80, statements: 80 },
  },
};
export default config;
```

### Transformers
| Transformer | Use case | Speed |
|---|---|---|
| `ts-jest` | Full TypeScript type-checking | Slower |
| `@swc/jest` | Fast transpilation, no type-check | Fastest |
| `babel-jest` | Babel ecosystem, custom plugins | Medium |

### Projects (monorepo)
```ts
const config: Config = {
  projects: [
    { displayName: 'client', testEnvironment: 'jsdom', testMatch: ['<rootDir>/packages/client/**/*.test.ts'] },
    { displayName: 'server', testEnvironment: 'node', testMatch: ['<rootDir>/packages/server/**/*.test.ts'] },
  ],
};
```

## Code Coverage

Run with `jest --coverage`. Configure thresholds to enforce minimums:
```ts
coverageThreshold: {
  global: { branches: 80, functions: 80, lines: 80, statements: 80 },
  './src/critical/': { branches: 95, functions: 95, lines: 95, statements: 95 },
}
```

Exclude generated/test files: `coveragePathIgnorePatterns: ['/node_modules/', '/__tests__/']`.

## Performance Optimization

- Use `@swc/jest` or `esbuild-jest` instead of `ts-jest` for 2-5x faster transforms
- Set `maxWorkers: '50%'` in CI to avoid resource contention
- Use `--onlyChanged` or `--changedSince=main` for incremental runs
- Use `--shard=1/3` to parallelize across CI machines
- Avoid top-level `beforeAll` with expensive setup — use `jest.isolateModules` for module-level isolation
- Set `testTimeout: 10000` globally; keep individual tests under 5s
- Use `--bail=1` in CI to fail fast on first broken test
- Prefer `jest.spyOn` over `jest.mock` when possible — spies are lighter

## Common Patterns

### Testing error boundaries
```tsx
const spy = jest.spyOn(console, 'error').mockImplementation(() => {});
render(<ErrorBoundary><BrokenComponent /></ErrorBoundary>);
expect(screen.getByText(/something went wrong/i)).toBeInTheDocument();
spy.mockRestore();
```

### Mocking environment variables
```ts
const originalEnv = process.env;
beforeEach(() => { process.env = { ...originalEnv, NODE_ENV: 'test' }; });
afterEach(() => { process.env = originalEnv; });
```

### Testing async error handling
```ts
test('handles API failure', async () => {
  jest.spyOn(api, 'fetch').mockRejectedValue(new Error('Network'));
  render(<UserProfile id={1} />);
  expect(await screen.findByText(/error/i)).toBeInTheDocument();
});
```

### Module isolation
```ts
test('isolated module state', () => {
  jest.isolateModules(() => {
    const { counter } = require('./counter');
    expect(counter.value).toBe(0);
  });
});
```

## References

Detailed reference documents in `references/`:

- **[advanced-patterns.md](references/advanced-patterns.md)** — Custom test environments, custom reporters, global setup/teardown, test sequencers, worker threads, module name mapper with path aliases, MSW integration, error boundary testing, renderHook patterns, jest-extended matchers
- **[troubleshooting.md](references/troubleshooting.md)** — "Cannot find module" fixes, ESM/CJS transform failures, jest.mock hoisting gotchas, memory leak diagnosis, flaky async test remedies, snapshot workflows, slow test diagnosis, open handles detection, moduleNameMapper vs pathsToModuleNameMapper
- **[api-reference.md](references/api-reference.md)** — Complete Jest API: globals (describe/test/expect), all matchers, mock function API (jest.fn/spyOn/mock/reset/restore), timer API, configuration options, CLI flags

## Scripts

Executable helpers in `scripts/`:

- **[setup-jest.sh](scripts/setup-jest.sh)** — Configure Jest for TypeScript (`--swc` or `--ts-jest`), with optional `--react` flag for Testing Library. Installs deps, generates config, creates setup files.
- **[find-slow-tests.sh](scripts/find-slow-tests.sh)** — Run Jest with timing analysis. Shows slowest suites/tests, flags those exceeding threshold, prints optimization suggestions.
- **[migrate-to-jest.sh](scripts/migrate-to-jest.sh)** — Migrate from Mocha/Jasmine. Auto-detects framework, scans for patterns needing changes, shows syntax mappings, optionally transforms imports.

## Assets

Templates and configs in `assets/`:

- **[jest.config.ts](assets/jest.config.ts)** — Production config with TypeScript, @swc/jest, path aliases, coverage thresholds, CI-aware settings, monorepo support
- **[setup-files.ts](assets/setup-files.ts)** — Setup file with custom matchers (toBeWithinRange, toResolveWithin, toBeISODateString), Testing Library import, lifecycle hooks
- **[test-utils.tsx](assets/test-utils.tsx)** — Custom render with providers (QueryClient, Router, Theme), userEvent setup, async helpers, debug utilities
- **[mock-factory.ts](assets/mock-factory.ts)** — Generic `createFactory<T>()` for entities, mock service/class creators, localStorage/router/event mocks
- **[msw-handlers.ts](assets/msw-handlers.ts)** — MSW server setup with CRUD handler factory, auth handlers, error/network/slow response helpers

<!-- tested: pass -->
