# Vitest Troubleshooting Guide

## Table of Contents

- [Module Resolution Errors](#module-resolution-errors)
- [ESM / CJS Interop Issues](#esm--cjs-interop-issues)
- [Transform Errors](#transform-errors)
- [Slow Tests Diagnosis](#slow-tests-diagnosis)
- [Memory Leaks](#memory-leaks)
- [Watch Mode Issues](#watch-mode-issues)
- [Coverage Gaps and Problems](#coverage-gaps-and-problems)
- [CI-Specific Problems](#ci-specific-problems)
- [Mocking Issues](#mocking-issues)
- [Debugging with VS Code](#debugging-with-vs-code)
- [Debugging with Chrome DevTools](#debugging-with-chrome-devtools)
- [Pool and Worker Issues](#pool-and-worker-issues)
- [TypeScript and Type Errors](#typescript-and-type-errors)
- [Environment Issues (jsdom/happy-dom)](#environment-issues-jsdomhappy-dom)
- [Common Error Messages Reference](#common-error-messages-reference)

---

## Module Resolution Errors

### "Failed to resolve import '@/...'"

Vitest does **not** read `tsconfig.json` paths by default. Fix with one of:

**Option 1 — Config aliases:**
```ts
// vitest.config.ts
import { defineConfig } from 'vitest/config'
import path from 'path'

export default defineConfig({
  resolve: {
    alias: {
      '@': path.resolve(__dirname, 'src'),
      '@utils': path.resolve(__dirname, 'src/utils'),
    },
  },
})
```

**Option 2 — vite-tsconfig-paths plugin:**
```bash
npm install -D vite-tsconfig-paths
```
```ts
import tsconfigPaths from 'vite-tsconfig-paths'
export default defineConfig({
  plugins: [tsconfigPaths()],
})
```

### "Cannot find module './file'" (Correct Path Exists)

- Check `include`/`exclude` patterns in config
- Verify file extensions match: `.ts` vs `.tsx` vs `.js`
- Check for case-sensitivity issues (Linux is case-sensitive, macOS is not)
- Verify the module isn't in `server.deps.external`

### "Module not found" for node_modules Dependency

```ts
// vitest.config.ts
export default defineConfig({
  test: {
    deps: {
      optimizer: {
        web: {
          include: ['problematic-package'],
        },
      },
    },
  },
})
```

---

## ESM / CJS Interop Issues

### "require() of ES Module is not supported"

This happens when a dependency ships ESM-only but Vitest tries CJS resolution.

**Fix 1 — Force ESM resolution:**
```ts
export default defineConfig({
  test: {
    deps: {
      optimizer: {
        ssr: {
          include: ['esm-only-package'],
        },
      },
    },
  },
})
```

**Fix 2 — Inline the dependency:**
```ts
export default defineConfig({
  test: {
    server: {
      deps: {
        inline: ['esm-only-package'],
      },
    },
  },
})
```

### "Must use import to load ES Module"

Your config or setup file might be using `require()`. Solutions:
- Rename config to `.mts` extension
- Add `"type": "module"` to `package.json`
- Convert `require()` calls to dynamic `import()`

### Default Export Not Working

```ts
// Common with CJS/ESM interop
import pkg from 'cjs-package'
// pkg might be { default: actualExport } — unwrap it:
const actual = pkg.default ?? pkg
```

### "exports" Field Resolution

If a package uses `exports` in `package.json` with conditions:
```ts
export default defineConfig({
  resolve: {
    conditions: ['import', 'module', 'browser', 'default'],
  },
})
```

---

## Transform Errors

### "Unexpected token" / Syntax Error in node_modules

A dependency contains syntax (JSX, TS, etc.) that needs transformation:

```ts
export default defineConfig({
  test: {
    server: {
      deps: {
        inline: ['package-with-untranspiled-code'],
      },
    },
  },
})
```

### "Failed to parse source" for CSS/SCSS

```ts
export default defineConfig({
  test: {
    css: true, // enable CSS processing
    // OR mock CSS modules:
    css: {
      modules: { classNameStrategy: 'non-scoped' },
    },
  },
})
```

### SVG / Asset Import Failures

```ts
// vitest.config.ts — mock static assets
export default defineConfig({
  test: {
    alias: {
      '\\.(jpg|jpeg|png|gif|svg)$': '<rootDir>/test/__mocks__/fileMock.ts',
    },
  },
})
```

```ts
// test/__mocks__/fileMock.ts
export default 'test-file-stub'
```

---

## Slow Tests Diagnosis

### Profiling Test Duration

```bash
# Show per-test timing
vitest run --reporter=verbose

# Profile with Node inspector
node --cpu-prof ./node_modules/.bin/vitest run
```

### Common Causes and Fixes

| Cause | Fix |
|-------|-----|
| Large dependency trees being transformed | Add stable deps to `server.deps.external` |
| Heavy test isolation (default) | Use `--no-isolate` if tests don't share state |
| Too many workers | Limit with `--pool-options.threads.maxThreads=4` |
| Slow environment setup | Use `happy-dom` instead of `jsdom` (~2-3x faster) |
| Unnecessary CSS processing | Set `css: false` if not testing styles |
| File watchers overhead (watch mode) | Narrow `include` patterns |
| Serial test execution | Use `describe.concurrent` for independent tests |

### Optimization Config

```ts
export default defineConfig({
  test: {
    pool: 'threads',
    poolOptions: {
      threads: {
        minThreads: 1,
        maxThreads: 4,
      },
    },
    environment: 'happy-dom', // faster than jsdom
    css: false,
    isolate: false,           // ⚠️ only if tests are truly independent
    fileParallelism: true,    // default, run files in parallel
  },
})
```

### Detecting Slow Imports

```bash
# Trace module resolution
DEBUG=vite:resolve vitest run path/to/slow-test.test.ts
```

---

## Memory Leaks

### Symptoms
- Tests slow down progressively
- Worker processes crash with "JavaScript heap out of memory"
- OOM errors in CI

### Common Causes and Fixes

**Uncleared timers/intervals:**
```ts
afterEach(() => {
  vi.restoreAllMocks()
  vi.useRealTimers()
})
```

**Retained DOM references (jsdom):**
```ts
import { cleanup } from '@testing-library/react'
afterEach(() => cleanup())
```

**Large objects in closures:**
```ts
// BAD — retains largeData across all tests
const largeData = generateMassiveDataset()

// GOOD — create per-test, garbage collected
let largeData: DataSet
beforeEach(() => { largeData = generateMassiveDataset() })
afterEach(() => { largeData = null! })
```

**Module mock accumulation:**
```ts
afterEach(() => {
  vi.restoreAllMocks()
  vi.resetModules() // clear module cache
})
```

### Diagnosing Memory Issues

```bash
# Run with heap size limit to detect leaks early
node --max-old-space-size=512 ./node_modules/.bin/vitest run

# Generate heap snapshot
node --inspect ./node_modules/.bin/vitest run
# Then use chrome://inspect to take heap snapshots
```

### Using `--pool=forks` to Isolate Memory

Forks provide better memory isolation since each worker is a separate process:
```ts
export default defineConfig({
  test: {
    pool: 'forks',
    poolOptions: {
      forks: {
        singleFork: false,  // separate process per test file
      },
    },
  },
})
```

---

## Watch Mode Issues

### Tests Not Re-Running on File Change

- Check `include` patterns match your test files
- Verify the file system watcher limit (Linux):
  ```bash
  # Check current limit
  cat /proc/sys/fs/inotify/max_user_watches
  # Increase if needed
  echo 'fs.inotify.max_user_watches=524288' | sudo tee -a /etc/sysctl.conf
  sudo sysctl -p
  ```
- WSL2: Use polling mode if native watchers fail:
  ```ts
  export default defineConfig({
    server: {
      watch: {
        usePolling: true,
        interval: 1000,
      },
    },
  })
  ```

### Watch Mode Hangs or Uses Excessive CPU

- Exclude large directories: `watchExclude: ['**/node_modules/**', '**/dist/**']`
- Reduce the scope of watched files via narrower `include` patterns

### Watch Mode Not Detecting New Files

Vitest watch may not pick up new files without a restart if they don't match an existing glob. Restart `vitest` after adding files in new directories.

---

## Coverage Gaps and Problems

### Coverage Shows 0% for Untested Files

```ts
test: {
  coverage: {
    all: true, // include files with no test imports
    include: ['src/**/*.{ts,tsx}'],
  },
}
```

### Coverage Numbers Differ Between Local and CI

- Ensure identical Node.js versions
- Use the same coverage provider (V8 vs Istanbul)
- V8 coverage can vary slightly across platforms; use Istanbul for cross-platform consistency
- Check that no files are conditionally excluded

### "Coverage provider not found"

```bash
npm install -D @vitest/coverage-v8
# or
npm install -D @vitest/coverage-istanbul
```

### Specific Lines Not Covered Despite Being Tested

V8 coverage instruments at the bytecode level, which can differ from source-level coverage:
- Add `/* v8 ignore next */` or `/* v8 ignore start/stop */` for intentionally uncovered lines
- For Istanbul: `/* istanbul ignore next */`

### Threshold Enforcement

```ts
coverage: {
  thresholds: {
    lines: 80,
    branches: 75,
    functions: 80,
    statements: 80,
    perFile: true,        // enforce per file, not just global
    autoUpdate: false,    // don't auto-lower thresholds
  },
},
```

---

## CI-Specific Problems

### Tests Pass Locally but Fail in CI

| Issue | Fix |
|-------|-----|
| Timezone-dependent tests | Use `vi.setSystemTime()` or set `TZ=UTC` env |
| Race conditions in parallel tests | Add `--sequence.concurrent=false` |
| Resource limits | Reduce workers: `--pool-options.threads.maxThreads=2` |
| Missing browsers (browser mode) | Install via `npx playwright install --with-deps` |
| Flaky async tests | Increase `testTimeout` for CI |
| File system case sensitivity | Linux CI is case-sensitive; macOS local is not |

### CI-Optimized Config

```ts
export default defineConfig({
  test: {
    // CI-specific overrides
    ...(process.env.CI && {
      pool: 'forks',
      poolOptions: { forks: { singleFork: false } },
      maxConcurrency: 2,
      testTimeout: 30000,
      retry: 2,
      bail: 5,
    }),
  },
})
```

### GitHub Actions: Process Killed / OOM

```yaml
env:
  NODE_OPTIONS: '--max-old-space-size=4096'
```

### Caching in CI

```yaml
- uses: actions/cache@v4
  with:
    path: node_modules/.vite
    key: vitest-${{ runner.os }}-${{ hashFiles('**/vitest.config.*') }}
```

---

## Mocking Issues

### "vi.mock() factory cannot reference variables in file scope"

This is the most common mocking error. Variables in the file scope are NOT available in `vi.mock()` factories because the factory is hoisted.

```ts
// ❌ WRONG
const mockValue = 'test'
vi.mock('./mod', () => ({ fn: () => mockValue })) // mockValue is undefined

// ✅ CORRECT
const mockValue = vi.hoisted(() => 'test')
vi.mock('./mod', () => ({ fn: () => mockValue }))
```

### Mock Not Applied / Real Module Runs

- Ensure `vi.mock()` path matches the import path exactly
- Check for re-exports — you might need to mock the source module
- Dynamic imports bypass `vi.mock()` — use `vi.importMock()` instead
- `vi.mock()` only works at the top level of test files

### Mocks Leaking Between Tests

```ts
// In vitest.config.ts
test: {
  mockReset: true,     // reset all mocks between tests
  restoreMocks: true,  // restore original implementations
  clearMocks: true,    // clear call history
}
// Or per-file:
afterEach(() => {
  vi.restoreAllMocks()
})
```

### Timer Mocks Not Working

```ts
// Ensure timers are faked BEFORE the code that uses them
vi.useFakeTimers()

const callback = vi.fn()
setTimeout(callback, 1000)

// ❌ Wrong: time hasn't advanced
expect(callback).toHaveBeenCalled()

// ✅ Correct: advance time first
vi.advanceTimersByTime(1000)
expect(callback).toHaveBeenCalled()

// Don't forget cleanup
afterEach(() => vi.useRealTimers())
```

---

## Debugging with VS Code

### launch.json Configuration

```json
{
  "version": "0.2.0",
  "configurations": [
    {
      "type": "node",
      "request": "launch",
      "name": "Debug Current Test File",
      "autoAttachChildProcesses": true,
      "skipFiles": ["<node_internals>/**", "**/node_modules/**"],
      "program": "${workspaceRoot}/node_modules/vitest/vitest.mjs",
      "args": ["run", "${relativeFile}"],
      "smartStep": true,
      "console": "integratedTerminal"
    },
    {
      "type": "node",
      "request": "launch",
      "name": "Debug All Tests",
      "autoAttachChildProcesses": true,
      "skipFiles": ["<node_internals>/**", "**/node_modules/**"],
      "program": "${workspaceRoot}/node_modules/vitest/vitest.mjs",
      "args": ["run"],
      "smartStep": true,
      "console": "integratedTerminal"
    }
  ]
}
```

### Quick Debug (No Config Needed)

1. Open VS Code's **JavaScript Debug Terminal** (Ctrl+Shift+P → "JavaScript Debug Terminal")
2. Run `npx vitest run path/to/test.ts`
3. Breakpoints will be hit automatically

### VS Code Extension

Install the official **Vitest** extension (`vitest.explorer`):
- Run/debug individual tests from the editor gutter
- Inline coverage display
- Watch mode integration
- Requires VS Code ≥1.77, Vitest ≥1.4.0

---

## Debugging with Chrome DevTools

```bash
# Start Vitest with Node inspector
node --inspect-brk ./node_modules/.bin/vitest run

# For a specific test file
node --inspect-brk ./node_modules/.bin/vitest run src/utils.test.ts
```

1. Open `chrome://inspect` in Chrome
2. Click "inspect" on the Node target
3. Sources panel → set breakpoints → press "Resume" (F8)

### For Browser Mode

```bash
vitest --inspect-brk --browser --no-file-parallelism
```

---

## Pool and Worker Issues

### Segfaults / Native Module Crashes

Native modules (e.g., `bcrypt`, `sharp`) often crash with `threads` pool:
```ts
test: {
  pool: 'forks', // separate processes, safer for native modules
}
```

### "Worker terminated unexpectedly"

- Increase memory: `NODE_OPTIONS='--max-old-space-size=4096'`
- Switch pool: `pool: 'forks'`
- Check for infinite loops or heavy computation in test setup

### Choosing the Right Pool

| Pool | Isolation | Speed | Native Module Support | Memory |
|------|-----------|-------|-----------------------|--------|
| `threads` | Shared memory | Fastest | ❌ Limited | Lower |
| `forks` | Process-level | Medium | ✅ Full | Higher |
| `vmThreads` | VM context | Slow | ❌ Limited | Higher |

---

## TypeScript and Type Errors

### "Cannot find name 'describe'/'it'/'expect'"

When using `globals: true`, add to `tsconfig.json`:
```json
{
  "compilerOptions": {
    "types": ["vitest/globals"]
  }
}
```

### Type Errors in Mock Returns

```ts
// Use vi.mocked() for proper typing
import { fetchUser } from './api'
vi.mock('./api')

const mockedFetchUser = vi.mocked(fetchUser)
mockedFetchUser.mockResolvedValue({ id: 1, name: 'Test' }) // fully typed
```

---

## Environment Issues (jsdom/happy-dom)

### "document is not defined" / "window is not defined"

Set the environment:
```ts
test: { environment: 'jsdom' }
```
Or per-file via magic comment:
```ts
// @vitest-environment jsdom
```

### jsdom Missing APIs

jsdom doesn't implement everything. Common gaps:
- `window.matchMedia` — mock it in setup:
  ```ts
  Object.defineProperty(window, 'matchMedia', {
    value: vi.fn().mockImplementation((query) => ({
      matches: false,
      media: query,
      onchange: null,
      addListener: vi.fn(),
      removeListener: vi.fn(),
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
      dispatchEvent: vi.fn(),
    })),
  })
  ```
- `IntersectionObserver`, `ResizeObserver` — mock similarly or use packages like `jsdom-testing-mocks`
- `fetch` — use `vi.stubGlobal('fetch', vi.fn())`

### happy-dom vs jsdom

| Feature | jsdom | happy-dom |
|---------|-------|-----------|
| Speed | Slower | ~2-3x faster |
| API completeness | More complete | Partial |
| Community | Larger | Growing |
| Best for | Accurate DOM testing | Fast unit tests |

---

## Common Error Messages Reference

| Error | Cause | Quick Fix |
|-------|-------|-----------|
| `Failed to resolve import` | Path alias not configured | Add `resolve.alias` or `vite-tsconfig-paths` |
| `require() of ES Module` | CJS/ESM mismatch | Inline dep or use `server.deps.inline` |
| `ReferenceError: describe is not defined` | Missing globals config | Add `globals: true` or import from `vitest` |
| `TypeError: vi.mock is not a function` | `vi` not imported | `import { vi } from 'vitest'` or enable globals |
| `Segmentation fault` | Native module in threads | Switch to `pool: 'forks'` |
| `Test timed out` | Unresolved promise or slow async | Increase `testTimeout` or fix hanging promise |
| `Snapshot mismatch` | Output changed | Review diff, update with `--update` if correct |
| `Cannot mock a module that is already loaded` | Import order issue | Ensure `vi.mock()` is before imports (it's hoisted, but dynamic imports may bypass) |
| `ENOMEM` / OOM | Memory leak or too many workers | Reduce workers, increase heap, use `pool: 'forks'` |
| `ENOSPC: no space left on device` (watch) | inotify limit reached | Increase `max_user_watches` |
