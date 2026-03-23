# Jest to Vitest Migration Guide

## Table of Contents

- [Overview](#overview)
- [Config Mapping](#config-mapping)
- [API Differences](#api-differences)
- [Mock Migration](#mock-migration)
- [Timer Migration](#timer-migration)
- [Snapshot Format Differences](#snapshot-format-differences)
- [Coverage Tool Changes](#coverage-tool-changes)
- [Feature Parity Gaps](#feature-parity-gaps)
- [Step-by-Step Migration](#step-by-step-migration)
- [Automated Migration Script](#automated-migration-script)

---

## Overview

Vitest is API-compatible with Jest for most use cases. Migration is largely mechanical: swap packages, update config, and replace `jest.*` globals with `vi.*`.

**What stays the same:**
- `describe`, `it`, `test`, `expect` — identical API
- `beforeEach`, `afterEach`, `beforeAll`, `afterAll` — identical
- `expect` matchers — same built-in matchers
- `.only`, `.skip`, `.todo`, `.each` — identical
- Snapshot testing — compatible format

**What changes:**
- Configuration format (jest.config → vitest.config)
- Mock API namespace (`jest.*` → `vi.*`)
- Module system (CJS → ESM)
- Some edge-case behaviors in mocking and timers

---

## Config Mapping

### jest.config.js → vitest.config.ts

| Jest Config | Vitest Config | Notes |
|---|---|---|
| `testEnvironment: 'jsdom'` | `test.environment: 'jsdom'` | Same value |
| `testMatch` | `test.include` | Glob patterns |
| `testPathIgnorePatterns` | `test.exclude` | Glob patterns |
| `moduleNameMapper` | `resolve.alias` | Vite-style aliases |
| `transform` | Vite plugins | No need for ts-jest/babel-jest |
| `setupFilesAfterFramework` | `test.setupFiles` | Array of paths |
| `globals` | `test.globals: true` | `false` recommended |
| `collectCoverageFrom` | `test.coverage.include` | Glob patterns |
| `coverageThreshold` | `test.coverage.thresholds` | Slightly different shape |
| `testTimeout` | `test.testTimeout` | Same concept |
| `maxWorkers` | `test.poolOptions.threads.maxThreads` | Pool-specific |
| `verbose` | `test.reporters: ['verbose']` | Use reporters |
| `watchPathIgnorePatterns` | `test.watchExclude` | Glob patterns |
| `moduleFileExtensions` | Not needed | Vite handles all |
| `transformIgnorePatterns` | `test.server.deps.external` | Different mechanism |

### Side-by-Side Config Example

**Jest:**

```js
// jest.config.js
module.exports = {
  testEnvironment: 'jsdom',
  testMatch: ['<rootDir>/src/**/*.test.{ts,tsx}'],
  moduleNameMapper: {
    '^@/(.*)$': '<rootDir>/src/$1',
    '\\.(css|less)$': 'identity-obj-proxy',
  },
  transform: {
    '^.+\\.tsx?$': 'ts-jest',
  },
  setupFilesAfterFramework: ['<rootDir>/test/setup.ts'],
  collectCoverageFrom: ['src/**/*.ts', '!src/**/*.d.ts'],
  coverageThreshold: {
    global: { branches: 80, functions: 80, lines: 80, statements: 80 },
  },
};
```

**Vitest:**

```ts
// vitest.config.ts
import { defineConfig } from 'vitest/config';
import path from 'path';

export default defineConfig({
  resolve: {
    alias: {
      '@': path.resolve(__dirname, 'src'),
    },
  },
  test: {
    environment: 'jsdom',
    include: ['src/**/*.test.{ts,tsx}'],
    setupFiles: ['./test/setup.ts'],
    css: false,
    coverage: {
      provider: 'v8',
      include: ['src/**/*.ts'],
      exclude: ['src/**/*.d.ts'],
      thresholds: { branches: 80, functions: 80, lines: 80, statements: 80 },
    },
  },
});
```

---

## API Differences

### Import Changes

```ts
// Jest (with globals — no import needed)
describe('test', () => { ... });

// Vitest (explicit imports — recommended)
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
describe('test', () => { ... });

// Vitest (with globals: true — Jest-compatible, no imports needed)
// vitest.config.ts: test: { globals: true }
```

### Namespace Change: jest.* → vi.*

| Jest | Vitest | Notes |
|------|--------|-------|
| `jest.fn()` | `vi.fn()` | Identical behavior |
| `jest.mock()` | `vi.mock()` | Hoisted in both |
| `jest.spyOn()` | `vi.spyOn()` | Identical behavior |
| `jest.useFakeTimers()` | `vi.useFakeTimers()` | See timer section |
| `jest.useRealTimers()` | `vi.useRealTimers()` | Identical |
| `jest.clearAllMocks()` | `vi.clearAllMocks()` | Identical |
| `jest.resetAllMocks()` | `vi.resetAllMocks()` | Identical |
| `jest.restoreAllMocks()` | `vi.restoreAllMocks()` | Identical |
| `jest.requireActual()` | `vi.importActual()` | **Async** in Vitest |
| `jest.requireMock()` | `vi.importMock()` | **Async** in Vitest |
| `jest.setTimeout()` | `vi.setConfig({ testTimeout })` | Different API |
| `jest.advanceTimersByTime()` | `vi.advanceTimersByTime()` | Identical |
| `jest.runAllTimers()` | `vi.runAllTimers()` | Identical |
| `jest.runOnlyPendingTimers()` | `vi.runOnlyPendingTimers()` | Identical |

### Vitest-Only Features (No Jest Equivalent)

```ts
// vi.hoisted — declare variables used in vi.mock factories
const { mockFn } = vi.hoisted(() => ({ mockFn: vi.fn() }));
vi.mock('./api', () => ({ fetch: mockFn }));

// vi.stubGlobal — type-safe global stubbing
vi.stubGlobal('fetch', vi.fn());

// vi.stubEnv — stub environment variables
vi.stubEnv('API_URL', 'http://test');

// expectTypeOf — type-level assertions
import { expectTypeOf } from 'vitest';
expectTypeOf(fn).returns.toBeString();

// In-source testing
if (import.meta.vitest) { /* ... */ }
```

---

## Mock Migration

### jest.fn() → vi.fn()

```ts
// Jest
const mock = jest.fn();
const mockImpl = jest.fn((x) => x + 1);
const mockReturnValue = jest.fn().mockReturnValue(42);
const mockResolvedValue = jest.fn().mockResolvedValue('data');

// Vitest — identical, just change namespace
const mock = vi.fn();
const mockImpl = vi.fn((x) => x + 1);
const mockReturnValue = vi.fn().mockReturnValue(42);
const mockResolvedValue = vi.fn().mockResolvedValue('data');
```

### jest.mock() → vi.mock()

```ts
// Jest
jest.mock('./api');  // Automock
jest.mock('./api', () => ({
  fetchUser: jest.fn().mockResolvedValue({ id: 1 }),
}));

// Vitest — identical pattern, but use vi.hoisted for variables
vi.mock('./api');  // Automock
vi.mock('./api', () => ({
  fetchUser: vi.fn().mockResolvedValue({ id: 1 }),
}));
```

### jest.requireActual() → vi.importActual() (ASYNC)

```ts
// Jest (synchronous)
jest.mock('./utils', () => {
  const actual = jest.requireActual('./utils');
  return { ...actual, format: jest.fn() };
});

// Vitest (async — use importOriginal parameter or vi.importActual)
vi.mock('./utils', async (importOriginal) => {
  const actual = await importOriginal<typeof import('./utils')>();
  return { ...actual, format: vi.fn() };
});
```

### jest.spyOn() → vi.spyOn()

```ts
// Jest
jest.spyOn(console, 'log').mockImplementation();
jest.spyOn(obj, 'method').mockReturnValue('mocked');

// Vitest — identical
vi.spyOn(console, 'log').mockImplementation(() => {});
vi.spyOn(obj, 'method').mockReturnValue('mocked');
```

### Manual Mocks (__mocks__)

Jest's `__mocks__` directory convention works in Vitest with `vi.mock()`:

```
src/
  __mocks__/
    axios.ts        # Auto-used when vi.mock('axios') has no factory
  api.ts
  __mocks__/
    api.ts          # Auto-used when vi.mock('./api') has no factory
```

---

## Timer Migration

### Basic Timer Migration

```ts
// Jest
jest.useFakeTimers();
jest.advanceTimersByTime(1000);
jest.runAllTimers();
jest.useRealTimers();

// Vitest — identical API
vi.useFakeTimers();
vi.advanceTimersByTime(1000);
vi.runAllTimers();
vi.useRealTimers();
```

### Modern vs Legacy Fake Timers

Jest had `jest.useFakeTimers('modern')` vs `jest.useFakeTimers('legacy')`. Vitest only has the modern equivalent (backed by `@sinonjs/fake-timers`).

```ts
// Jest (legacy timers — no direct Vitest equivalent)
jest.useFakeTimers('legacy');

// Vitest — always modern, with configuration
vi.useFakeTimers({
  shouldAdvanceTime: false,
  toFake: ['setTimeout', 'setInterval', 'Date'],  // Selective faking
});
```

### Async Timer Considerations

```ts
// Vitest provides async timer APIs for Promise-based code
await vi.advanceTimersByTimeAsync(1000);
await vi.runAllTimersAsync();
await vi.runOnlyPendingTimersAsync();

// Jest doesn't have these — had to use workarounds like:
// jest.advanceTimersByTime(1000); await Promise.resolve();
```

### System Time Mocking

```ts
// Jest
jest.useFakeTimers().setSystemTime(new Date('2025-01-01'));

// Vitest
vi.useFakeTimers();
vi.setSystemTime(new Date('2025-01-01'));
// Or combined:
vi.useFakeTimers({ now: new Date('2025-01-01') });
```

---

## Snapshot Format Differences

### Compatibility

Vitest snapshot format is largely compatible with Jest. Most snapshots work without changes.

### Key Differences

1. **Snapshot file location** — Same convention: `__snapshots__/file.test.ts.snap`
2. **Inline snapshots** — Same syntax: `toMatchInlineSnapshot()`
3. **Serialization** — Minor formatting differences may require `--update`

### Migration Steps

```bash
# After switching to Vitest, update all snapshots
npx vitest run --update

# Review snapshot diffs in version control
git diff -- '**/*.snap'
```

### Custom Serializers

```ts
// Jest
// In jest.config.js: snapshotSerializers: ['my-serializer']

// Vitest
// In vitest.config.ts:
export default defineConfig({
  test: {
    snapshotSerializers: ['./test/my-serializer.ts'],
  },
});
```

Serializer interface is the same (jest-serializer compatible):

```ts
export default {
  test(val: unknown): boolean {
    return val instanceof MyClass;
  },
  serialize(val: MyClass, config: any, indent: string, depth: number, refs: any, printer: any): string {
    return `MyClass { ${printer(val.toJSON())} }`;
  },
};
```

---

## Coverage Tool Changes

### Jest → Vitest Coverage Comparison

| Jest | Vitest | Notes |
|------|--------|-------|
| Built-in istanbul | `@vitest/coverage-istanbul` | Separate install |
| `--coverage` flag | `--coverage` flag | Same CLI flag |
| `coverageProvider: 'v8'` | `coverage.provider: 'v8'` | v8 is default |
| `coverageReporters` | `coverage.reporter` | Same reporter names |
| `coverageDirectory` | `coverage.reportsDirectory` | Different key name |
| `collectCoverageFrom` | `coverage.include` | Same glob patterns |
| `coveragePathIgnorePatterns` | `coverage.exclude` | Same glob patterns |

### Installation

```bash
# Remove Jest coverage
npm uninstall babel-plugin-istanbul

# Install Vitest coverage
npm install -D @vitest/coverage-v8
# Or for istanbul:
npm install -D @vitest/coverage-istanbul
```

### Config Migration

```ts
// Jest
coverageThreshold: {
  global: { branches: 80, functions: 80, lines: 80, statements: 80 },
  './src/critical/': { branches: 100, lines: 100 },
}

// Vitest
coverage: {
  thresholds: {
    branches: 80,
    functions: 80,
    lines: 80,
    statements: 80,
    // Per-file/glob thresholds via configuration
  },
}
```

---

## Feature Parity Gaps

### Features Jest Has That Vitest Handles Differently

| Feature | Jest | Vitest | Notes |
|---------|------|--------|-------|
| `--bail` | `--bail=N` | `--bail=N` | Same behavior |
| `--findRelatedTests` | Built-in | `--changed` | Git-based in Vitest |
| `--changedSince` | Built-in | `--changed HEAD~1` | Similar |
| `jest.retryTimes()` | Built-in | `retry` option | `it('name', () => {}, { retry: 3 })` |
| `jest.setTimeout()` | Per-test | `vi.setConfig()` | Different API |
| Global setup/teardown | `globalSetup` | `test.globalSetup` | Same concept |
| Watch plugins | Plugin system | Built-in shortcuts | Vitest watch is more capable |
| Projects | `projects: []` | `vitest.workspace.ts` | Different format |
| `moduleDirectories` | Configurable | Not needed | Vite resolves automatically |

### Vitest Features Not in Jest

- **Vite plugin pipeline** — reuses your Vite config, transforms, and plugins
- **Browser mode** — real browser testing without Puppeteer/Playwright wrapper
- **In-source testing** — `if (import.meta.vitest)` blocks
- **Type testing** — `expectTypeOf` for compile-time assertions
- **Benchmarking** — built-in `bench()` API
- **Native ESM** — no transpilation needed
- **HMR watch** — instant re-runs via Vite's module graph
- **Workspace support** — first-class monorepo multi-project config

---

## Step-by-Step Migration

### 1. Install Vitest and Remove Jest

```bash
# Remove Jest ecosystem
npm uninstall jest ts-jest babel-jest @types/jest jest-environment-jsdom \
  babel-plugin-istanbul @jest/globals identity-obj-proxy

# Install Vitest
npm install -D vitest
npm install -D @vitest/coverage-v8       # Coverage
npm install -D jsdom                      # If using jsdom environment
npm install -D @vitest/ui                 # Optional: UI dashboard
```

### 2. Create vitest.config.ts

Convert your jest.config using the mapping table above.

### 3. Update package.json Scripts

```json
{
  "scripts": {
    "test": "vitest run",
    "test:watch": "vitest",
    "test:coverage": "vitest run --coverage",
    "test:ui": "vitest --ui"
  }
}
```

### 4. Update Imports in Test Files

```bash
# If not using globals: true, add imports to each test file
# The jest-to-vitest.sh script automates this
```

### 5. Replace jest.* with vi.*

```bash
# Automated replacement (see jest-to-vitest.sh script)
# Key replacements:
# jest.fn()           → vi.fn()
# jest.mock()         → vi.mock()
# jest.spyOn()        → vi.spyOn()
# jest.useFakeTimers  → vi.useFakeTimers
# jest.requireActual  → vi.importActual  (note: now async!)
```

### 6. Update Setup Files

```ts
// Replace @testing-library/jest-dom import
// Old:
import '@testing-library/jest-dom';
// New:
import '@testing-library/jest-dom/vitest';
```

### 7. Handle jest.requireActual → vi.importActual

This is the most impactful change — `vi.importActual` is async:

```ts
// Find all jest.requireActual usages and convert:
vi.mock('./module', async (importOriginal) => {
  const actual = await importOriginal();
  return { ...actual, myFn: vi.fn() };
});
```

### 8. Update CI Pipeline

```yaml
# Replace jest commands
- run: npx vitest run --reporter=dot
- run: npx vitest run --coverage
```

### 9. Update Snapshots

```bash
npx vitest run --update
git add -- '**/*.snap'
```

### 10. Validate

```bash
npx vitest run          # All tests pass
npx vitest run --coverage  # Coverage thresholds met
```

---

## Automated Migration Script

Use the provided `scripts/jest-to-vitest.sh` for automated file transformation. It handles:

- Renaming `jest.*` calls to `vi.*`
- Adding Vitest imports
- Updating config files
- Converting `jest.requireActual` to `vi.importActual`

For large codebases, also consider:

```bash
npx vitest-codemod  # Community codemod tool
```

Review all changes manually after automated migration — edge cases around async `importActual` and custom Jest extensions need human review.
