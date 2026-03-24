# Jest Troubleshooting Guide

## Table of Contents
- ["Cannot find module" Errors](#cannot-find-module-errors)
- [Transform/Transpilation Failures (ESM/CJS)](#transformtranspilation-failures-esmcjs)
- [jest.mock Hoisting Behavior](#jestmock-hoisting-behavior)
- [Memory Leaks in Tests](#memory-leaks-in-tests)
- [Flaky Async Tests](#flaky-async-tests)
- [Snapshot Update Workflows](#snapshot-update-workflows)
- [Slow Test Diagnosis](#slow-test-diagnosis)
- [Open Handles Detection](#open-handles-detection)
- [moduleNameMapper vs pathsToModuleNameMapper](#modulenamemapper-vs-pathstomodulenamemapper)

---

## "Cannot find module" Errors

### Symptoms
```
Cannot find module '@/utils/helpers' from 'src/components/App.test.tsx'
Cannot find module 'some-esm-package' from 'src/index.test.ts'
```

### Causes & Fixes

**1. Missing path alias mapping**
```ts
// jest.config.ts — map your tsconfig paths
moduleNameMapper: {
  '^@/(.*)$': '<rootDir>/src/$1',
}
```

**2. ESM-only package not transformed**
```ts
// Default: node_modules are not transformed. Override for ESM packages:
transformIgnorePatterns: [
  'node_modules/(?!(esm-package|another-esm-pkg)/)',
],
```

**3. Missing file extensions in imports**
```ts
// If your code uses extensionless imports:
moduleFileExtensions: ['ts', 'tsx', 'js', 'jsx', 'json', 'node'],
```

**4. Wrong module directories**
```ts
// If using non-standard module resolution:
moduleDirectories: ['node_modules', 'src'],  // allows bare imports from src/
```

**5. CSS/image/asset imports**
```ts
moduleNameMapper: {
  '\\.(css|less|scss|sass)$': 'identity-obj-proxy',
  '\\.(jpg|jpeg|png|gif|webp|svg)$': '<rootDir>/__mocks__/fileMock.js',
}
// __mocks__/fileMock.js
// module.exports = 'test-file-stub';
```

---

## Transform/Transpilation Failures (ESM/CJS)

### "SyntaxError: Cannot use import statement outside a module"

**Cause**: A dependency ships ESM but Jest expects CJS.

**Fix A — Transform the package:**
```ts
transformIgnorePatterns: [
  '/node_modules/(?!(esm-pkg|another-esm-pkg)/)',
],
transform: {
  '^.+\\.(ts|tsx|js|jsx)$': ['@swc/jest'],
},
```

**Fix B — Native ESM mode (experimental):**
```json
// package.json
{
  "type": "module",
  "scripts": {
    "test": "NODE_OPTIONS='--experimental-vm-modules' jest"
  }
}
```
```ts
// jest.config.ts for ESM
export default {
  transform: {},  // no transform needed for native ESM
  extensionsToTreatAsEsm: ['.ts', '.tsx'],
};
```

### "Unexpected token" in TypeScript files

Ensure your transform config matches file extensions:
```ts
transform: {
  '^.+\\.tsx?$': ['ts-jest', { tsconfig: 'tsconfig.json' }],
  // OR
  '^.+\\.(t|j)sx?$': ['@swc/jest'],
}
```

### "ReferenceError: exports is not defined" / "require is not defined"

Mixed ESM/CJS issue. Ensure consistent module system:
```json
// tsconfig.json
{
  "compilerOptions": {
    "module": "commonjs",      // for CJS Jest
    "esModuleInterop": true,
    "allowSyntheticDefaultImports": true
  }
}
```

---

## jest.mock Hoisting Behavior

### How it works (CJS)
`jest.mock()` calls are **automatically hoisted** to the top of the file by Babel/ts-jest transforms. This means:

```ts
import { foo } from './foo';       // 2. This import runs second
jest.mock('./foo');                 // 1. This is hoisted to run first

// The import sees the mocked version
```

### Common pitfall: accessing variables in factory
```ts
// ❌ WRONG — variable not available during hoisting
const mockValue = 'test';
jest.mock('./config', () => ({ getValue: () => mockValue }));
// ReferenceError: mockValue is not defined

// ✅ FIX — use jest.fn() and set later, or inline
jest.mock('./config', () => ({ getValue: jest.fn() }));
import { getValue } from './config';
const mockedGetValue = getValue as jest.Mock;
beforeEach(() => mockedGetValue.mockReturnValue('test'));

// ✅ ALT — prefix with "mock" for auto-hoisting exception
const mockValue = 'test';  // variables starting with "mock" are hoisted too
jest.mock('./config', () => ({ getValue: () => mockValue }));
```

### ESM mocking (experimental)
In ESM mode, `jest.mock()` hoisting does NOT work. Use:
```ts
import { jest } from '@jest/globals';

// Must use unstable_mockModule + dynamic import
jest.unstable_mockModule('./foo', () => ({
  foo: jest.fn(() => 'mocked'),
}));

// Import AFTER mocking
const { foo } = await import('./foo');
```

### jest.mock vs jest.doMock
- `jest.mock()` — hoisted, applies to all tests in file
- `jest.doMock()` — NOT hoisted, use inside test functions with `require()` or dynamic `import()`

```ts
test('uses different mock per test', () => {
  jest.doMock('./config', () => ({ env: 'staging' }));
  const config = require('./config');
  expect(config.env).toBe('staging');
});
```

---

## Memory Leaks in Tests

### Symptoms
- Jest process grows in memory over time
- Tests slow down during long runs
- "JavaScript heap out of memory" errors
- `--watch` mode becomes unresponsive

### Diagnosis
```bash
# Log heap usage per test suite
jest --logHeapUsage

# Run with Node memory debugging
NODE_OPTIONS='--max-old-space-size=4096' jest

# Detect leaks (requires weak-napi)
jest --detectLeaks
```

### Common causes & fixes

**1. Unclosed resources in tests**
```ts
// ❌ Leaks — server never closed
let server: http.Server;
beforeAll(() => { server = app.listen(3000); });
// Missing afterAll!

// ✅ Fix
afterAll(() => new Promise(resolve => server.close(resolve)));
```

**2. Global state accumulation**
```ts
// ❌ Array grows across tests
const logs: string[] = [];
afterEach(() => { logs.length = 0; });  // ✅ Clear it
```

**3. Uncleared mocks holding references**
```ts
afterEach(() => {
  jest.restoreAllMocks();
  jest.clearAllTimers();
});
```

**4. Large module caches**
```ts
// Isolate modules to prevent cache buildup
jest.isolateModules(() => {
  const heavyModule = require('./heavy');
});
```

**5. Worker memory limits**
```ts
// jest.config.ts — limit worker memory
{
  maxWorkers: 2,
  workerIdleMemoryLimit: '512MB',  // restart workers exceeding this
}
```

---

## Flaky Async Tests

### Symptoms
Tests pass locally but fail intermittently in CI.

### Root causes & fixes

**1. Missing await**
```ts
// ❌ Test passes before assertion runs
test('fetches data', () => {
  fetchData().then(data => expect(data).toBeDefined());  // no await!
});

// ✅ Fix
test('fetches data', async () => {
  const data = await fetchData();
  expect(data).toBeDefined();
});
```

**2. Race conditions with timers**
```ts
// ❌ Real timers = timing-dependent
test('debounce', () => {
  const fn = jest.fn();
  debounce(fn, 100)();
  setTimeout(() => expect(fn).toHaveBeenCalled(), 150);
});

// ✅ Fix — use fake timers
test('debounce', () => {
  jest.useFakeTimers();
  const fn = jest.fn();
  debounce(fn, 100)();
  jest.advanceTimersByTime(100);
  expect(fn).toHaveBeenCalled();
  jest.useRealTimers();
});
```

**3. Shared state between tests**
```ts
// ❌ Test order matters
let counter = 0;
test('first', () => { counter++; expect(counter).toBe(1); });
test('second', () => { expect(counter).toBe(0); }); // fails!

// ✅ Fix — reset in beforeEach
beforeEach(() => { counter = 0; });
```

**4. Not waiting for UI updates**
```tsx
// ❌ Element may not be rendered yet
render(<AsyncComponent />);
expect(screen.getByText('loaded')).toBeInTheDocument();

// ✅ Fix — use findBy (waits) or waitFor
expect(await screen.findByText('loaded')).toBeInTheDocument();
```

**5. Assertion count for async paths**
```ts
test('calls handler on each item', async () => {
  expect.assertions(3);  // ensures all 3 assertions actually run
  // ... async code with 3 expect() calls
});
```

---

## Snapshot Update Workflows

### Interactive update in watch mode
1. Run `jest --watch`
2. When snapshots fail, press `u` to update all, or `i` for interactive mode
3. In interactive mode, review each failure and press `u` or `s` to update/skip

### CI/batch update
```bash
jest --updateSnapshot          # update all
jest --updateSnapshot --testPathPattern='Button'  # update specific files
jest -u -t 'renders correctly'  # update matching test names
```

### Best practices
- Review snapshot diffs in PRs — treat them like code changes
- Keep snapshots small and focused (prefer inline snapshots for small outputs)
- Use `toMatchInlineSnapshot()` for <10 lines — easier to review in diffs
- Delete `.snap` files and regenerate if they become stale
- Add `--ci` flag in CI to fail on missing/outdated snapshots (no auto-update)

### Custom serializers
```ts
// jest.config.ts
snapshotSerializers: ['enzyme-to-json/serializer'],

// Or inline
expect.addSnapshotSerializer({
  test: (val) => val && val.hasOwnProperty('className'),
  print: (val: any) => `ClassName<${val.className}>`,
});
```

---

## Slow Test Diagnosis

### Identify slow tests
```bash
# Show per-test timing
jest --verbose

# Show slowest test suites (built-in)
jest --verbose 2>&1 | grep -E 'Time:|PASS|FAIL'

# Profile with detailed timing
jest --json --outputFile=results.json
# Parse results.json for testResults[].perfStats

# Run serially to isolate
jest --runInBand --verbose
```

### Common causes

| Cause | Fix |
|-------|-----|
| Slow transformer (ts-jest) | Switch to `@swc/jest` (2-5x faster) |
| Large `beforeAll` setup | Move to `globalSetup` or lazy init |
| Real network calls | Mock with MSW or `jest.mock` |
| Real timers/delays | Use `jest.useFakeTimers()` |
| Too many test files in one worker | Increase `maxWorkers` |
| Large snapshot files | Break into smaller, focused snapshots |
| Module re-initialization | Use `jest.isolateModules` selectively |

### Performance config
```ts
{
  // Fast transformer
  transform: { '^.+\\.tsx?$': '@swc/jest' },
  // CI parallelism
  maxWorkers: '50%',
  // Skip coverage in dev
  collectCoverage: process.env.CI === 'true',
  // Cache transforms
  cacheDirectory: '<rootDir>/.jest-cache',
}
```

---

## Open Handles Detection

### Symptom
```
Jest did not exit one second after the test run has completed.
This usually means that there are asynchronous operations that weren't stopped.
```

### Diagnose
```bash
jest --detectOpenHandles                    # show what's leaking
jest --detectOpenHandles --runInBand        # more reliable detection
jest --forceExit                            # last resort (masks bugs)
```

### Common open handle sources

**HTTP servers**
```ts
let server: Server;
beforeAll(() => { server = app.listen(0); });
afterAll((done) => { server.close(done); });
```

**Database connections**
```ts
afterAll(async () => {
  await pool.end();
  await mongoose.disconnect();
});
```

**Timers**
```ts
afterEach(() => jest.useRealTimers());  // clears fake timers
```

**Event listeners / intervals**
```ts
const interval = setInterval(poll, 1000);
afterAll(() => clearInterval(interval));
```

**Unresolved promises**
```ts
// Ensure all promises are awaited or cancelled in teardown
```

---

## moduleNameMapper vs pathsToModuleNameMapper

### moduleNameMapper (Jest native)
Manual regex-to-path mapping in `jest.config.ts`:
```ts
moduleNameMapper: {
  '^@/(.*)$': '<rootDir>/src/$1',
  '^@components/(.*)$': '<rootDir>/src/components/$1',
}
```
- **Pro**: Works with any transformer, no dependencies
- **Con**: Must be kept in sync with `tsconfig.json` paths manually

### pathsToModuleNameMapper (ts-jest utility)
Auto-generates `moduleNameMapper` from `tsconfig.json`:
```ts
import { pathsToModuleNameMapper } from 'ts-jest';
import { compilerOptions } from './tsconfig.json';

export default {
  moduleNameMapper: pathsToModuleNameMapper(compilerOptions.paths, {
    prefix: '<rootDir>/',
  }),
};
```
- **Pro**: Single source of truth, no drift
- **Con**: Requires ts-jest as dependency (even with @swc/jest transformer)

### Decision guide
| Scenario | Recommendation |
|----------|---------------|
| TypeScript project with paths in tsconfig | `pathsToModuleNameMapper` |
| JavaScript project or few aliases | Manual `moduleNameMapper` |
| Using @swc/jest without ts-jest | Manual `moduleNameMapper` |
| Monorepo with shared tsconfig | `pathsToModuleNameMapper` with base tsconfig |

### Gotcha: prefix option
```ts
// tsconfig paths: { "@/*": ["./src/*"] }

// ❌ Wrong — resolves to relative path
pathsToModuleNameMapper(paths)

// ✅ Correct — resolves to absolute path
pathsToModuleNameMapper(paths, { prefix: '<rootDir>/' })
```
