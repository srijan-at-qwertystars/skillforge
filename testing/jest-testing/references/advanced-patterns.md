# Advanced Jest Patterns

## Table of Contents
- [Custom Test Environment](#custom-test-environment)
- [Custom Reporters](#custom-reporters)
- [Global Setup/Teardown](#global-setupteardown)
- [Custom Test Sequencer](#custom-test-sequencer)
- [Worker Threads](#worker-threads)
- [Module Name Mapper & Path Aliases](#module-name-mapper--path-aliases)
- [Testing with MSW (Mock Service Worker)](#testing-with-msw)
- [Testing Error Boundaries](#testing-error-boundaries)
- [Testing Custom Hooks with renderHook](#testing-custom-hooks-with-renderhook)
- [jest-extended Matchers](#jest-extended-matchers)

---

## Custom Test Environment

Extend `jest-environment-node` or `jest-environment-jsdom` for per-suite isolation (databases, browsers, etc.).

```ts
// environments/database-environment.ts
import NodeEnvironment from 'jest-environment-node';
import type { JestEnvironmentConfig, EnvironmentContext } from '@jest/environment';

class DatabaseEnvironment extends NodeEnvironment {
  private dbUrl: string;

  constructor(config: JestEnvironmentConfig, context: EnvironmentContext) {
    super(config, context);
    // Read from docblock pragmas: @jest-environment-options {"dbUrl": "..."}
    this.dbUrl = config.projectConfig.testEnvironmentOptions.dbUrl as string;
  }

  async setup() {
    await super.setup();
    const db = await createTestDatabase(this.dbUrl);
    this.global.__DB__ = db;
    this.global.__DB_URL__ = db.connectionString;
  }

  async teardown() {
    await (this.global.__DB__ as any)?.destroy();
    await super.teardown();
  }
}

export default DatabaseEnvironment;
```

Per-file override via docblock:
```ts
/**
 * @jest-environment ./environments/database-environment
 * @jest-environment-options {"dbUrl": "postgres://localhost/test"}
 */
test('queries database', async () => {
  const db = (globalThis as any).__DB__;
  const rows = await db.query('SELECT 1');
  expect(rows).toHaveLength(1);
});
```

---

## Custom Reporters

Reporters receive lifecycle hooks for test results. Combine with `'default'` to keep console output.

```ts
// reporters/slack-reporter.ts
import type { Reporter, TestResult, AggregatedResult } from '@jest/reporters';

class SlackReporter implements Reporter {
  onRunStart() { /* optional */ }

  onTestResult(_test: any, testResult: TestResult) {
    if (testResult.numFailingTests > 0) {
      console.log(`❌ ${testResult.testFilePath}: ${testResult.numFailingTests} failures`);
    }
  }

  async onRunComplete(_contexts: Set<any>, results: AggregatedResult) {
    const { numFailedTests, numPassedTests, numTotalTests } = results;
    if (numFailedTests > 0) {
      await sendSlackMessage(`Tests: ${numPassedTests}/${numTotalTests} passed, ${numFailedTests} failed`);
    }
  }

  getLastError() { return undefined; }
}

export default SlackReporter;
```

Config:
```ts
reporters: [
  'default',
  ['./reporters/slack-reporter', { webhookUrl: process.env.SLACK_WEBHOOK }],
],
```

---

## Global Setup/Teardown

Runs once before/after **all** test suites. Use for shared infrastructure (test DB, server, containers).

```ts
// global-setup.ts
import { execSync } from 'child_process';
export default async function globalSetup() {
  // Start test database container
  execSync('docker compose -f docker-compose.test.yml up -d --wait');
  // Store connection info for test environments
  process.env.DATABASE_URL = 'postgres://localhost:5433/test';
}

// global-teardown.ts
import { execSync } from 'child_process';
export default async function globalTeardown() {
  execSync('docker compose -f docker-compose.test.yml down -v');
}
```

**Key constraint**: `globalSetup`/`globalTeardown` run in a separate process from tests. Share state via env vars, temp files, or `globalThis.__MONGO_URI__` patterns.

Config:
```ts
{
  globalSetup: '<rootDir>/global-setup.ts',
  globalTeardown: '<rootDir>/global-teardown.ts',
}
```

---

## Custom Test Sequencer

Control test file execution order for performance or dependency reasons.

```ts
// test-sequencer.ts
import Sequencer from '@jest/test-sequencer';
import type { Test } from 'jest-runner';

class CustomSequencer extends Sequencer {
  sort(tests: Test[]): Test[] {
    // Run integration tests last, unit tests first
    return tests.sort((a, b) => {
      const aIsIntegration = a.path.includes('.integration.');
      const bIsIntegration = b.path.includes('.integration.');
      if (aIsIntegration && !bIsIntegration) return 1;
      if (!aIsIntegration && bIsIntegration) return -1;
      // Then sort by file size (smaller = likely faster)
      return a.duration ?? 0 - (b.duration ?? 0);
    });
  }
}

export default CustomSequencer;
```

Config: `testSequencer: '<rootDir>/test-sequencer.ts'`

---

## Worker Threads

Jest can use worker threads instead of child processes for test parallelization.

```ts
// jest.config.ts
{
  // Use worker threads (faster IPC than child_process)
  workerThreads: true,
  // Control parallelism
  maxWorkers: '50%',        // CI-friendly
  // maxWorkers: 4,          // fixed count
}
```

**When to use**: Worker threads have faster startup and lower memory overhead. Use for large test suites. Not compatible with all custom environments.

For custom parallel computation in tests, use `jest-worker`:
```ts
import { Worker } from 'jest-worker';
const worker = new Worker(require.resolve('./heavy-computation'), {
  enableWorkerThreads: true,
});
const result = await worker.processData(largeDataset);
```

---

## Module Name Mapper & Path Aliases

### Manual mapping
```ts
moduleNameMapper: {
  '^@/(.*)$': '<rootDir>/src/$1',
  '^@components/(.*)$': '<rootDir>/src/components/$1',
  '^@utils/(.*)$': '<rootDir>/src/utils/$1',
  // Static assets
  '\\.(css|less|scss|sass)$': 'identity-obj-proxy',
  '\\.(jpg|jpeg|png|gif|svg)$': '<rootDir>/__mocks__/fileMock.js',
}
```

### Auto-sync with tsconfig using ts-jest
```ts
import { pathsToModuleNameMapper } from 'ts-jest';
import { compilerOptions } from './tsconfig.json';

{
  moduleNameMapper: pathsToModuleNameMapper(compilerOptions.paths, {
    prefix: '<rootDir>/',
  }),
}
```

**Prefer `pathsToModuleNameMapper`** in TypeScript projects — single source of truth, no drift between tsconfig and jest config.

---

## Testing with MSW

MSW intercepts at the network level — no mocking `fetch`/`axios` internals.

### Setup
```ts
// src/mocks/handlers.ts
import { http, HttpResponse } from 'msw';

export const handlers = [
  http.get('/api/users', () =>
    HttpResponse.json([{ id: 1, name: 'Alice' }])
  ),
  http.post('/api/users', async ({ request }) => {
    const body = await request.json();
    return HttpResponse.json({ id: 2, ...body }, { status: 201 });
  }),
  http.get('/api/users/:id', ({ params }) =>
    HttpResponse.json({ id: Number(params.id), name: 'User' })
  ),
];

// src/mocks/server.ts
import { setupServer } from 'msw/node';
import { handlers } from './handlers';
export const server = setupServer(...handlers);
```

### Jest integration (setupFilesAfterEnv)
```ts
import { server } from './src/mocks/server';
beforeAll(() => server.listen({ onUnhandledRequest: 'error' }));
afterEach(() => server.resetHandlers());
afterAll(() => server.close());
```

### Per-test overrides
```ts
import { http, HttpResponse } from 'msw';
import { server } from '../mocks/server';

test('handles server error', async () => {
  server.use(
    http.get('/api/users', () => HttpResponse.json(null, { status: 500 }))
  );
  render(<UserList />);
  expect(await screen.findByText(/error/i)).toBeInTheDocument();
});
```

---

## Testing Error Boundaries

```tsx
import { render, screen } from '@testing-library/react';

// Component that throws
const ThrowingComponent = () => { throw new Error('boom'); };

test('error boundary catches render error', () => {
  // Suppress React error logging in test output
  const consoleSpy = jest.spyOn(console, 'error').mockImplementation(() => {});

  render(
    <ErrorBoundary fallback={<div>Something went wrong</div>}>
      <ThrowingComponent />
    </ErrorBoundary>
  );

  expect(screen.getByText('Something went wrong')).toBeInTheDocument();
  expect(consoleSpy).toHaveBeenCalled();
  consoleSpy.mockRestore();
});

test('error boundary resets on retry', async () => {
  const consoleSpy = jest.spyOn(console, 'error').mockImplementation(() => {});
  let shouldThrow = true;

  const Unstable = () => {
    if (shouldThrow) throw new Error('fail');
    return <div>Recovered</div>;
  };

  const { rerender } = render(
    <ErrorBoundary fallback={<button onClick={() => { shouldThrow = false; }}>Retry</button>}>
      <Unstable />
    </ErrorBoundary>
  );

  await userEvent.click(screen.getByText('Retry'));
  // After state change triggers rerender with shouldThrow=false
  expect(screen.getByText('Recovered')).toBeInTheDocument();
  consoleSpy.mockRestore();
});
```

---

## Testing Custom Hooks with renderHook

```tsx
import { renderHook, act, waitFor } from '@testing-library/react';

// Simple sync hook
test('useCounter increments', () => {
  const { result } = renderHook(() => useCounter(0));
  expect(result.current.count).toBe(0);
  act(() => result.current.increment());
  expect(result.current.count).toBe(1);
});

// Hook with async effects
test('useFetch loads data', async () => {
  const { result } = renderHook(() => useFetch('/api/users'));
  expect(result.current.loading).toBe(true);
  await waitFor(() => expect(result.current.loading).toBe(false));
  expect(result.current.data).toHaveLength(1);
});

// Hook that needs providers (wrapper option)
test('useTheme reads context', () => {
  const wrapper = ({ children }: { children: React.ReactNode }) => (
    <ThemeProvider theme="dark">{children}</ThemeProvider>
  );
  const { result } = renderHook(() => useTheme(), { wrapper });
  expect(result.current.theme).toBe('dark');
});

// Rerender with new props
test('useDebounce updates after delay', () => {
  jest.useFakeTimers();
  const { result, rerender } = renderHook(
    ({ value }) => useDebounce(value, 500),
    { initialProps: { value: 'hello' } }
  );
  expect(result.current).toBe('hello');
  rerender({ value: 'world' });
  expect(result.current).toBe('hello'); // not yet
  act(() => jest.advanceTimersByTime(500));
  expect(result.current).toBe('world');
  jest.useRealTimers();
});
```

---

## jest-extended Matchers

Install: `npm i -D jest-extended`

Setup in `jest.config.ts`:
```ts
setupFilesAfterEnv: ['jest-extended/all'],
```

### Key matchers by category

**Type checks**: `toBeArray()`, `toBeObject()`, `toBeString()`, `toBeNumber()`, `toBeBoolean()`, `toBeFunction()`, `toBeDate()`, `toBeSymbol()`

**Arrays**: `toBeArrayOfSize(n)`, `toIncludeAllMembers([...])`, `toIncludeAnyMembers([...])`, `toIncludeSameMembers([...])`, `toSatisfyAll(predicate)`

**Objects**: `toContainKey(key)`, `toContainKeys([...])`, `toContainAllKeys([...])`, `toContainValue(val)`, `toContainAllValues([...])`

**Strings**: `toStartWith(prefix)`, `toEndWith(suffix)`, `toInclude(sub)`, `toEqualCaseInsensitive(str)`, `toIncludeRepeated(sub, n)`

**Numbers**: `toBePositive()`, `toBeNegative()`, `toBeEven()`, `toBeOdd()`, `toBeWithin(start, end)`

**Dates**: `toBeValidDate()`, `toBeAfter(date)`, `toBeBefore(date)`, `toBeBetween(start, end)`

**Misc**: `toBeEmpty()`, `toBeNil()`, `toBeOneOf([...])`, `toSatisfy(predicate)`, `toBeExtensible()`, `toBeFrozen()`, `toBeSealed()`

```ts
test('jest-extended examples', () => {
  expect([1, 2, 3]).toBeArrayOfSize(3);
  expect({ a: 1, b: 2 }).toContainKeys(['a', 'b']);
  expect('hello world').toStartWith('hello');
  expect(42).toBePositive();
  expect(new Date()).toBeValidDate();
  expect('').toBeEmpty();
  expect([3, 1, 2]).toIncludeSameMembers([1, 2, 3]);
  expect(10).toBeWithin(5, 15);
  expect(values).toSatisfyAll((v) => v > 0);
});
```
