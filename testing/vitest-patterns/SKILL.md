---
name: vitest-patterns
description: >
  Vitest testing patterns, configuration, and best practices. Use when working with Vitest,
  vitest.config.ts, vi.fn, vi.mock, vi.spyOn, vi.stubGlobal, vi.useFakeTimers, test runners
  powered by Vite, describe/it/expect blocks, snapshot testing, component testing, in-source
  testing, bench API, or coverage configuration. Triggers on Vitest imports, vitest.workspace
  files, @vitest/* packages, and migration from Jest to Vitest. Do NOT use for Jest projects
  that do not use Vite, Playwright or Cypress end-to-end tests, pytest, JUnit, or other
  non-Vitest test frameworks.
---

# Vitest Patterns

## What Vitest Is

Vitest is a Vite-native test framework reusing your Vite config, transforms, and plugins. Native ESM, TypeScript, JSX, and CSS modules work without extra transpilers. Vitest 4+ is the current stable line.

**Why over Jest:** shares Vite pipeline (no duplicate babel/ts-jest config), native ESM/TS without shims, HMR-powered watch mode re-runs only affected tests, Jest-compatible API surface, single dependency replaces jest + ts-jest + babel-jest, built-in benchmarking, browser mode, in-source testing, and type testing.

## Configuration

### vitest.config.ts

```ts
import { defineConfig } from 'vitest/config';
export default defineConfig({
  test: {
    include: ['src/**/*.{test,spec}.{ts,tsx,js,jsx}'],
    exclude: ['node_modules', 'dist', 'e2e'],
    globals: false, // prefer explicit imports; set true only for Jest compat
    environment: 'node', // 'jsdom' | 'happy-dom' | 'edge-runtime'
    setupFiles: ['./test/setup.ts'],
    testTimeout: 5000,
  },
});
```

Per-file environment override via magic comment: `// @vitest-environment jsdom`

### Workspaces

Create `vitest.workspace.ts` at the repo root for monorepos:

```ts
import { defineWorkspace } from 'vitest/config';
export default defineWorkspace([
  'packages/*',
  { name: 'unit', test: { include: ['src/**/*.test.ts'], environment: 'node' } },
  { name: 'browser', test: { include: ['src/**/*.browser.test.ts'], environment: 'happy-dom' } },
]);
```

Each project needs a unique `name`. Run specific project: `vitest --project unit`.

## Test Syntax

```ts
import { describe, it, expect, beforeEach, afterEach } from 'vitest';

describe('UserService', () => {
  it('creates user with valid email', () => {
    const user = createUser('a@b.com');
    expect(user.email).toBe('a@b.com');
    expect(user.id).toBeDefined();
  });
  it('rejects invalid email', () => {
    expect(() => createUser('bad')).toThrow('Invalid email');
  });
});
```

### test.each

```ts
test.each([
  [1, 2, 3],
  [-1, 1, 0],
])('add(%i, %i) = %i', (a, b, expected) => {
  expect(add(a, b)).toBe(expected);
});
// Object syntax:
test.each([
  { input: 'hello', expected: 5 },
])('length of "$input" is $expected', ({ input, expected }) => {
  expect(input.length).toBe(expected);
});
```

Vitest 4+ adds `aroundEach` and `aroundAll` hooks for wrapping setup/teardown around test execution.

## Mocking

### vi.fn — Standalone Mock Functions

```ts
const handler = vi.fn();
handler('arg1');
expect(handler).toHaveBeenCalledWith('arg1');
// With implementation:
const double = vi.fn((n: number) => n * 2);
// Chained returns:
const getter = vi.fn().mockReturnValueOnce('first').mockReturnValue('default');
```

### vi.mock — Module Mocking (Hoisted)

`vi.mock` is **hoisted** to file top — runs before all imports.

```ts
vi.mock('../api', () => ({
  fetchUser: vi.fn().mockResolvedValue({ id: 1, name: 'Alice' }),
}));
import { fetchUser } from '../api';
```

Use `vi.importActual` to keep some exports real:

```ts
vi.mock('../utils', async () => {
  const actual = await vi.importActual<typeof import('../utils')>('../utils');
  return { ...actual, formatDate: vi.fn(() => '2025-01-01') };
});
```

### vi.spyOn — Preferred for Single Methods

Less brittle than vi.mock, not hoisted. Prefer this as default over vi.mock.

```ts
import * as mathUtils from './mathUtils';
const spy = vi.spyOn(mathUtils, 'add').mockReturnValue(42);
spy.mockRestore(); // restores original
// Spy on getters:
vi.spyOn(obj, 'prop', 'get').mockReturnValue('mocked');
```

### vi.stubGlobal

```ts
vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response('ok')));
```

### Automocking

```ts
vi.mock('./heavy-dep'); // no factory = automock all exports (return undefined, track calls)
```

### Mock Cleanup

```ts
afterEach(() => {
  vi.restoreAllMocks(); // restores spies to originals — prefer this
});
// vi.clearAllMocks() clears history only; vi.resetAllMocks() resets to bare vi.fn()
```

## Snapshot Testing

```ts
expect(result).toMatchSnapshot();
expect(format(data)).toMatchInlineSnapshot(`"formatted result"`); // stored in source
```

Update: `vitest run --update` or press `u` in watch mode. Review snapshot diffs in PRs like code.

## Fake Timers

```ts
beforeEach(() => vi.useFakeTimers());
afterEach(() => vi.useRealTimers());

it('debounces', () => {
  const cb = vi.fn();
  debounce(cb, 300)();
  expect(cb).not.toHaveBeenCalled();
  vi.advanceTimersByTime(300);
  expect(cb).toHaveBeenCalledOnce();
});
// vi.runAllTimers(), vi.runOnlyPendingTimers(), vi.advanceTimersToNextTimer()
// vi.setSystemTime(new Date('2025-06-01')) — mock Date.now()
// In async contexts use await vi.advanceTimersByTimeAsync()
```

## TypeScript Support

Vitest handles TS natively via Vite's esbuild transform. No ts-jest, no babel needed. Types are **stripped**, not checked — run `tsc --noEmit` separately. Path aliases resolve through Vite's `resolve.alias`.

Type-level testing:

```ts
import { expectTypeOf } from 'vitest';
expectTypeOf(fn).toBeFunction();
expectTypeOf(fn).parameter(0).toBeString();
expectTypeOf(fn).returns.toMatchTypeOf<Promise<User>>();
```

## Coverage

Install: `npm install -D @vitest/coverage-v8` (or `@vitest/coverage-istanbul`).

```ts
test: {
  coverage: {
    provider: 'v8', // faster, engine-level; use 'istanbul' for granular branches
    reporter: ['text', 'json', 'html', 'lcov'],
    include: ['src/**/*.ts'],
    exclude: ['src/**/*.test.ts', 'src/**/*.d.ts'],
    thresholds: { lines: 80, functions: 80, branches: 75, statements: 80 },
  },
}
```

Run: `vitest run --coverage`. Thresholds cause non-zero exit — use in CI gates.

## Browser Mode

Stable in Vitest 4+. Runs tests in real browsers via Playwright or WebDriverIO.

```bash
npm install -D @vitest/browser-playwright
```

```ts
import { playwright } from '@vitest/browser-playwright';
export default defineConfig({
  test: {
    browser: { enabled: true, provider: playwright(), instances: [{ browser: 'chromium' }] },
  },
});
```

Use when testing CSS, layout, real DOM APIs, IntersectionObserver. Use jsdom/happy-dom for faster unit tests.

## Component Testing

Install framework package: `@vitest/browser-react`, `@vitest/browser-vue`, or `@vitest/browser-svelte`.

```ts
// React with browser mode
import { render } from '@vitest/browser-react';
const { getByRole } = render(<Button onClick={onClick} label="Go" />);
await getByRole('button').click();
expect(onClick).toHaveBeenCalledOnce();
```

Without browser mode, use `@testing-library/react` with `environment: 'jsdom'`.

## In-Source Testing

Write tests alongside implementation; tree-shaken from production builds.

```ts
export function add(a: number, b: number) { return a + b; }
if (import.meta.vitest) {
  const { it, expect } = import.meta.vitest;
  it('adds numbers', () => { expect(add(1, 2)).toBe(3); });
}
```

Config: set `test.includeSource: ['src/**/*.ts']` and `define: { 'import.meta.vitest': 'undefined' }`. Use sparingly for small utilities only.

## Concurrent Tests and Isolation

```ts
describe.concurrent('parallel', () => {
  it('A', async () => { /* runs in parallel */ });
  it('B', async () => { /* runs in parallel */ });
});
it.concurrent('individual', async () => { /* ... */ });
```

Pool options: `threads` (default, fastest, shared memory), `forks` (full process isolation — use when tests leak state), `vmThreads` (VM contexts for heavy mocking). Set `sequence.shuffle: true` to catch hidden order dependencies.

## Filtering and Running Tests

```bash
vitest math                          # files matching "math"
vitest --testNamePattern="user login" # filter by test name
vitest --project unit                # workspace project
vitest --changed                     # git-affected tests only
vitest --changed HEAD~1              # since last commit
```

Code-level: `it.only()`, `it.skip()`, `it.todo()`, `it.skipIf(condition)()`, `it.runIf(condition)()`.

## Watch Mode and HMR

`vitest` defaults to watch mode using Vite's module graph. Keys: `a` re-run all, `f` failed only, `u` update snapshots, `p` filter filename, `t` filter test name. Use `vitest run` for single-run (CI).

## Benchmarking

```ts
import { bench, describe } from 'vitest';
describe('sorting', () => {
  bench('Array.sort', () => { [3,1,2].sort(); });
  bench('custom', () => { customSort([3,1,2]); }, { iterations: 1000, time: 2000 });
});
```

Run: `vitest bench`. Use `.bench.ts` extension. Never mix `bench` and `test` in the same file.

## Custom Matchers

```ts
expect.extend({
  toBeWithinRange(received: number, floor: number, ceiling: number) {
    const pass = received >= floor && received <= ceiling;
    return { pass, message: () => `expected ${received} within ${floor}–${ceiling}` };
  },
});
// TypeScript: augment vitest module — Assertion and AsymmetricMatchersContaining interfaces
```

Put custom matchers in a setup file registered via `setupFiles`.

## Environment Setup

| Environment | Package | Use For |
|---|---|---|
| `node` | built-in | APIs, utilities, server code |
| `jsdom` | `jsdom` | DOM testing without real browser |
| `happy-dom` | `happy-dom` | Faster jsdom alternative |
| `edge-runtime` | `@edge-runtime/vm` | Cloudflare Workers, Vercel Edge |

Setup file pattern:

```ts
// test/setup.ts
import '@testing-library/jest-dom/vitest';
import { cleanup } from '@testing-library/react';
import { afterEach } from 'vitest';
afterEach(() => cleanup());
```

## Migration from Jest

1. `npm uninstall jest ts-jest babel-jest @types/jest && npm install -D vitest`
2. Replace scripts: `"test": "vitest run"`, `"test:watch": "vitest"`
3. Create `vitest.config.ts` — map `testEnvironment` → `environment`, `moduleNameMapper` → Vite `resolve.alias`, `collectCoverageFrom` → `coverage.include`, `coverageThreshold` → `coverage.thresholds`
4. Replace `jest.*` with `vi.*` in test files: `jest.fn()` → `vi.fn()`, `jest.mock()` → `vi.mock()`, `jest.spyOn()` → `vi.spyOn()`, `jest.useFakeTimers()` → `vi.useFakeTimers()`, `jest.requireActual()` → `vi.importActual()`
5. Add `import { describe, it, expect, vi } from 'vitest'` unless using `globals: true`
6. Automated codemod: `npx vitest-codemod`. Snapshot files are largely compatible — run `--update` if formatting differs.

## CI/CD Integration

```yaml
- run: npx vitest run --reporter=dot --reporter=junit --outputFile=test-results.xml
- run: npx vitest run --coverage --coverage.reporter=lcov
```

Reporters: `default` (terminal), `verbose`, `dot` (CI), `junit` (XML), `json`, `html`, `github-actions` (PR annotations), `hanging-process` (debug leaks). Shard across CI nodes: `--shard=1/3`, `--shard=2/3`, `--shard=3/3`. Use `--changed` in PR pipelines. Cache `node_modules`.

## Common Anti-Patterns

- **Over-mocking with vi.mock** — prefer `vi.spyOn` for single functions; `vi.mock` hides integration bugs.
- **Setting globals: true by default** — explicit imports make dependencies clear.
- **Skipping mock cleanup** — always `vi.restoreAllMocks()` in `afterEach`.
- **Testing implementation details** — assert observable behavior, not internal calls.
- **Using vi.mock with dynamic paths** — factory arg must be a string literal; dynamic paths break hoisting.
- **Ignoring snapshot diffs** — snapshots are assertions; review them in PRs.
- **Relying on test order** — enable `sequence.shuffle` to catch hidden dependencies.
- **Nesting describes > 3 levels** — flatten with descriptive test names.
- **Synchronous timer APIs in async tests** — use `await vi.advanceTimersByTimeAsync()`.
- **Forgetting vi.useRealTimers()** — fake timers leak between tests if not restored.
- **Mixing bench and test files** — keep `.bench.ts` and `.test.ts` separate.

## Resources

### References

| File | Description |
|------|-------------|
| `references/advanced-patterns.md` | Type testing (`expectTypeOf`), custom pool workers, module graph testing, dependency pre-bundling, test sequencers, custom reporters, monorepo workspaces, Vitest UI, and plugin authoring |
| `references/troubleshooting.md` | Module resolution failures, ESM/CJS interop, mock hoisting, memory leaks, slow test diagnosis, v8 coverage gaps, snapshot serializer conflicts, jsdom limitations, CI failures |
| `references/migration-from-jest.md` | Complete Jest→Vitest migration: config mapping, API differences (`jest.*`→`vi.*`), async `importActual`, timer migration, snapshot format, coverage tool changes, feature parity |

### Scripts

| File | Description |
|------|-------------|
| `scripts/vitest-init.sh` | Initialize Vitest in an existing project — detects framework (React/Vue/Svelte/Node), generates config, installs deps, creates setup file |
| `scripts/vitest-coverage-check.sh` | Run coverage and enforce thresholds — parses JSON summary, exits non-zero on failure, configurable per-metric thresholds |
| `scripts/jest-to-vitest.sh` | Automated migration — transforms `jest.*` → `vi.*`, updates imports, handles `requireActual` → `importActual`, flags async review items |

### Assets (Copy-Ready Config Files)

| File | Description |
|------|-------------|
| `assets/vitest.config.ts` | Production-ready Vitest config with coverage, reporters, pool settings, CI detection |
| `assets/vitest-workspace.ts` | Monorepo workspace config — unit, component, integration, and edge runtime projects |
| `assets/setup-files.ts` | Test setup with custom matchers (`toBeWithinRange`, `toBeISODate`, `toResolveWithin`), browser API stubs, cleanup |
| `assets/component-test-utils.tsx` | React/Vue component testing helpers — provider wrappers, mock fetch, IntersectionObserver mock, test data factories |

<!-- tested: pass -->
