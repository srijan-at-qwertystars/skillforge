# Vitest Troubleshooting Guide

## Table of Contents

- [Module Resolution Failures](#module-resolution-failures)
- [ESM/CJS Interop Problems](#esmcjs-interop-problems)
- [Mock Hoisting Issues](#mock-hoisting-issues)
- [Memory Leaks in Test Suites](#memory-leaks-in-test-suites)
- [Slow Tests Diagnosis](#slow-tests-diagnosis)
- [Coverage Gaps with v8 Provider](#coverage-gaps-with-v8-provider)
- [Snapshot Serializer Conflicts](#snapshot-serializer-conflicts)
- [jsdom Limitations](#jsdom-limitations)
- [CI-Specific Failures](#ci-specific-failures)

---

## Module Resolution Failures

### Symptom: "Cannot find module" or "Failed to resolve import"

**Path aliases not resolving:**

```ts
// ❌ Error: Cannot find module '@/utils/helpers'
import { format } from '@/utils/helpers';
```

Fix: Ensure Vite `resolve.alias` matches your `tsconfig.json` paths:

```ts
// vitest.config.ts
import { defineConfig } from 'vitest/config';
import path from 'path';

export default defineConfig({
  resolve: {
    alias: {
      '@': path.resolve(__dirname, 'src'),
      '@utils': path.resolve(__dirname, 'src/utils'),
    },
  },
});
```

Or use `vite-tsconfig-paths` plugin to auto-sync:

```ts
import tsconfigPaths from 'vite-tsconfig-paths';
export default defineConfig({
  plugins: [tsconfigPaths()],
});
```

**Node.js built-in modules:**

```ts
// ❌ Error in jsdom environment: Cannot find module 'fs'
import fs from 'fs';
```

Fix: Node built-ins aren't available in browser-like environments. Use conditional environment comments or restructure:

```ts
// @vitest-environment node
import fs from 'fs';
```

**Importing from `node_modules` fails:**

```ts
// Dependency not pre-bundled
export default defineConfig({
  test: {
    server: {
      deps: {
        inline: ['problematic-package'],
      },
    },
  },
});
```

### Symptom: ".css/.svg/.png imports fail"

```ts
export default defineConfig({
  test: {
    css: false, // Disable CSS processing (default)
    // Or handle with a mock:
    alias: {
      '\\.(css|less|scss)$': new URL('./mocks/style-mock.ts', import.meta.url).pathname,
    },
  },
});
```

---

## ESM/CJS Interop Problems

### Symptom: "require is not defined" or "exports is not defined"

Vitest runs in ESM mode by default. CJS-only packages need special handling.

```ts
export default defineConfig({
  test: {
    server: {
      deps: {
        inline: ['cjs-only-package'],
        fallbackCJS: true,
      },
    },
  },
});
```

### Symptom: "ERR_REQUIRE_ESM"

A CJS dependency tries to `require()` an ESM package.

```ts
export default defineConfig({
  test: {
    deps: {
      optimizer: {
        ssr: {
          include: ['esm-package-required-by-cjs'],
        },
      },
    },
  },
});
```

### Symptom: Default Import is `{ default: ... }` Object

```ts
// ❌ Got: { default: { myFunction } } instead of { myFunction }
import pkg from 'some-cjs-package';

// ✅ Fix: use named imports
import { myFunction } from 'some-cjs-package';

// Or access .default explicitly
const actualPkg = pkg.default ?? pkg;
```

### Symptom: `__dirname` / `__filename` Not Defined

ESM doesn't have `__dirname`. Use `import.meta.url`:

```ts
import { fileURLToPath } from 'url';
import { dirname } from 'path';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
```

---

## Mock Hoisting Issues

### Symptom: Mock Not Applied — Real Module Executes

`vi.mock()` is hoisted to file top, but the factory must not reference variables defined below it.

```ts
// ❌ BROKEN: `mockFn` is not yet defined when vi.mock runs (hoisted)
const mockFn = vi.fn();
vi.mock('./api', () => ({ fetchUser: mockFn }));

// ✅ FIX: Use vi.hoisted() to declare variables before hoisting
const { mockFn } = vi.hoisted(() => ({
  mockFn: vi.fn(),
}));
vi.mock('./api', () => ({ fetchUser: mockFn }));
```

### Symptom: `vi.mock` with Dynamic Path Fails

```ts
// ❌ BROKEN: vi.mock requires a string literal
const path = './api';
vi.mock(path, () => ({}));

// ✅ FIX: Always use string literals
vi.mock('./api', () => ({}));
```

### Symptom: Partial Mock Doesn't Preserve Originals

```ts
// ❌ Overwrites all exports
vi.mock('./utils', () => ({
  formatDate: vi.fn(() => '2025-01-01'),
}));

// ✅ Spread actual module
vi.mock('./utils', async (importOriginal) => {
  const actual = await importOriginal<typeof import('./utils')>();
  return { ...actual, formatDate: vi.fn(() => '2025-01-01') };
});
```

### Symptom: Mock Leaks Between Test Files

```ts
// ✅ Always restore mocks between tests
afterEach(() => {
  vi.restoreAllMocks();
});

// For module-level mocks, use vi.resetModules()
afterEach(() => {
  vi.resetModules();
});
```

---

## Memory Leaks in Test Suites

### Symptom: Tests Slow Down or OOM Over Time

**Identify leaks:**

```bash
vitest run --reporter=hanging-process  # Shows processes that won't exit
vitest run --logHeapUsage              # Log heap per test file
node --expose-gc ./node_modules/.bin/vitest run  # Enable GC logging
```

**Common causes and fixes:**

1. **Unclosed handles** — database connections, servers, intervals:

```ts
afterEach(() => {
  vi.useRealTimers();        // Restore real timers
  vi.restoreAllMocks();
});

afterAll(async () => {
  await db.close();          // Close DB connections
  server.close();            // Close HTTP servers
  clearInterval(heartbeat);  // Clear intervals
});
```

2. **Large closures in mocks:**

```ts
// ❌ Captures large data in closure
const bigData = generateMassiveDataset();
vi.mock('./data', () => ({ getData: () => bigData }));

// ✅ Generate inside factory or use smaller fixtures
vi.mock('./data', () => ({
  getData: () => ({ id: 1, name: 'test' }),
}));
```

3. **Module cache bloat with `vi.resetModules()`:**

```ts
// Only call resetModules when you genuinely need fresh module state
// Don't call it in every afterEach unless necessary
```

4. **Use `pool: 'forks'` for isolation:**

```ts
export default defineConfig({
  test: {
    pool: 'forks',           // Full process isolation
    poolOptions: {
      forks: { maxForks: 4 },
    },
  },
});
```

---

## Slow Tests Diagnosis

### Step 1: Identify Slow Tests

```bash
vitest run --reporter=verbose   # Shows per-test timing
vitest run --reporter=json --outputFile=results.json  # Machine-readable
```

### Step 2: Common Causes

**Heavy setup files:**

```ts
// ❌ Expensive global setup runs for every test file
// test/setup.ts
import { seedDatabase } from './seed';  // 2s per file
await seedDatabase();

// ✅ Use globalSetup for one-time expensive operations
export default defineConfig({
  test: {
    globalSetup: ['./test/global-setup.ts'],  // Runs once
    setupFiles: ['./test/light-setup.ts'],     // Keep this fast
  },
});
```

**Unnecessary serialization with `pool: 'forks'`:**

```ts
// Switch to threads if you don't need full isolation
export default defineConfig({
  test: {
    pool: 'threads',  // Shared memory, faster IPC
  },
});
```

**Too many mock resets:**

```ts
// ❌ Resetting modules re-evaluates all imports
afterEach(() => vi.resetModules());

// ✅ Only reset when testing module-level side effects
// Use vi.restoreAllMocks() for most cases
```

### Step 3: Optimize

```ts
export default defineConfig({
  test: {
    // Parallelize test files
    fileParallelism: true,

    // Run tests in suite concurrently when safe
    sequence: {
      concurrent: true,
    },

    // Cache transformed modules
    cache: { dir: './node_modules/.vitest' },

    // Shard across CI nodes
    // vitest run --shard=1/4
  },
});
```

**Profile startup time:**

```bash
vitest run --reporter=verbose 2>&1 | head -20  # Check time-to-first-test
```

---

## Coverage Gaps with v8 Provider

### Symptom: Uncovered Lines That Are Actually Tested

v8 coverage works at the engine level and can report differently than istanbul.

**Known v8 quirks:**

1. **Arrow functions on same line as declaration:**

```ts
// v8 may not mark the arrow body as covered
export const add = (a: number, b: number) => a + b;

// Fix: Use block body
export const add = (a: number, b: number) => {
  return a + b;
};
```

2. **Default parameter values:**

```ts
// v8 may show default as uncovered if always called with args
function greet(name = 'World') { return `Hello, ${name}`; }
```

3. **Switch fallthrough and ternaries:**

```ts
// Complex ternaries may show partial coverage
// Break into explicit if/else for accurate coverage
```

### Symptom: Coverage Includes Test Files

```ts
coverage: {
  include: ['src/**/*.ts'],
  exclude: [
    'src/**/*.test.ts',
    'src/**/*.spec.ts',
    'src/**/*.d.ts',
    'src/**/index.ts',      // Re-export barrels
    'src/**/*.stories.tsx',  // Storybook
  ],
},
```

### Switch to Istanbul for Accuracy

```bash
npm install -D @vitest/coverage-istanbul
```

```ts
coverage: {
  provider: 'istanbul', // More accurate branch coverage
},
```

### Merging Coverage from Multiple Runs

```bash
# Run unit and integration separately, merge reports
vitest run --project unit --coverage --coverage.reporter=json
vitest run --project integration --coverage --coverage.reporter=json
# Use nyc merge or c8 merge to combine JSON reports
npx c8 report --reporter=lcov --temp-directory=./coverage
```

---

## Snapshot Serializer Conflicts

### Symptom: Snapshots Change Unexpectedly

**OS-specific line endings:**

```ts
// vitest.config.ts
export default defineConfig({
  test: {
    snapshotSerializers: ['./test/normalize-serializer.ts'],
  },
});
```

```ts
// test/normalize-serializer.ts
export default {
  serialize(val: string) {
    return val.replace(/\r\n/g, '\n');
  },
  test(val: unknown) {
    return typeof val === 'string' && val.includes('\r\n');
  },
};
```

**Dates, IDs, and non-deterministic values:**

```ts
// Use property matchers for dynamic values
expect(user).toMatchSnapshot({
  id: expect.any(String),
  createdAt: expect.any(Date),
});

// Or use inline snapshots with replacements
const sanitized = JSON.parse(
  JSON.stringify(result, (key, val) =>
    key === 'id' ? '<ID>' : val
  )
);
expect(sanitized).toMatchSnapshot();
```

**React component serialization:**

```bash
npm install -D @testing-library/jest-dom
```

Avoid snapshotting entire component trees — snapshot meaningful subsets:

```ts
// ❌ Brittle: entire tree
expect(container).toMatchSnapshot();

// ✅ Targeted: specific element
expect(getByRole('button')).toMatchSnapshot();
```

---

## jsdom Limitations

### Missing APIs

jsdom does not implement:

| API | Status | Workaround |
|-----|--------|------------|
| `IntersectionObserver` | Not supported | Mock manually |
| `ResizeObserver` | Not supported | Mock manually |
| `matchMedia` | Partial | Stub with `vi.stubGlobal` |
| `canvas` / `WebGL` | Not supported | Use `jest-canvas-mock` or browser mode |
| `Web Animations API` | Not supported | Mock or use browser mode |
| Navigation API | Not supported | Mock `window.location` |
| `localStorage` | Basic | Works but no size limits |
| `fetch` | Node 18+ built-in | Available natively |

### Common jsdom Mocks

```ts
// test/setup.ts
import { vi } from 'vitest';

// IntersectionObserver
const IntersectionObserverMock = vi.fn(() => ({
  disconnect: vi.fn(),
  observe: vi.fn(),
  unobserve: vi.fn(),
  takeRecords: vi.fn(() => []),
}));
vi.stubGlobal('IntersectionObserver', IntersectionObserverMock);

// ResizeObserver
vi.stubGlobal('ResizeObserver', vi.fn(() => ({
  disconnect: vi.fn(),
  observe: vi.fn(),
  unobserve: vi.fn(),
})));

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
});

// scrollTo
window.scrollTo = vi.fn() as any;
window.HTMLElement.prototype.scrollIntoView = vi.fn();
```

### When to Switch to Browser Mode

Use browser mode (`@vitest/browser`) when you need:

- Real CSS computation (`getComputedStyle`)
- Layout/rendering tests
- Canvas/WebGL
- Real IntersectionObserver/ResizeObserver behavior
- Accurate event propagation

---

## CI-Specific Failures

### Symptom: Tests Pass Locally but Fail in CI

**Timing-related flakes:**

```ts
// ❌ Hardcoded delays break on slow CI
await new Promise(r => setTimeout(r, 100));
expect(element).toBeVisible();

// ✅ Use waitFor or polling
import { waitFor } from '@testing-library/react';
await waitFor(() => expect(element).toBeVisible());

// ✅ Or use fake timers
vi.useFakeTimers();
vi.advanceTimersByTime(100);
```

**Increase timeouts for CI:**

```ts
export default defineConfig({
  test: {
    testTimeout: process.env.CI ? 15000 : 5000,
    hookTimeout: process.env.CI ? 30000 : 10000,
  },
});
```

**File system case sensitivity:**

macOS is case-insensitive; Linux CI is case-sensitive.

```ts
// ❌ Works on macOS, fails on Linux
import { Utils } from './utils'; // file is actually 'Utils.ts'
```

### Symptom: Out of Memory in CI

```yaml
# Increase Node.js heap
- run: npx vitest run
  env:
    NODE_OPTIONS: '--max-old-space-size=4096'
```

```ts
// Reduce parallelism
export default defineConfig({
  test: {
    pool: 'forks',
    poolOptions: {
      forks: {
        maxForks: 2,  // CI typically has fewer cores
      },
    },
    fileParallelism: true,
    maxConcurrency: 5,
  },
});
```

### Symptom: Snapshot Mismatches in CI

```bash
# Always run with --update locally before pushing
vitest run --update

# CI should fail on mismatches (default behavior)
vitest run  # Exits non-zero if snapshots differ
```

### Sharding for Parallel CI Jobs

```yaml
# GitHub Actions matrix example
strategy:
  matrix:
    shard: [1/4, 2/4, 3/4, 4/4]
steps:
  - run: npx vitest run --shard=${{ matrix.shard }}
```

### GitHub Actions Reporter

```ts
export default defineConfig({
  test: {
    reporters: process.env.CI
      ? ['dot', 'github-actions']   // PR annotations
      : ['default'],
  },
});
```
