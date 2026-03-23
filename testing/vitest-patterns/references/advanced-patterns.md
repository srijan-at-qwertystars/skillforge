# Advanced Vitest Patterns

## Table of Contents

- [Type Testing](#type-testing)
- [Custom Pool Workers](#custom-pool-workers)
- [Module Graph Testing](#module-graph-testing)
- [Dependency Pre-Bundling Control](#dependency-pre-bundling-control)
- [Test Sequencers](#test-sequencers)
- [Custom Reporters](#custom-reporters)
- [Workspace Configurations for Monorepos](#workspace-configurations-for-monorepos)
- [Vitest UI](#vitest-ui)
- [Extending Vitest with Plugins](#extending-vitest-with-plugins)

---

## Type Testing

Vitest includes `expectTypeOf` for compile-time type assertions that run alongside runtime tests.

### Basic Type Assertions

```ts
import { expectTypeOf } from 'vitest';

// Primitive types
expectTypeOf<string>().toBeString();
expectTypeOf<number>().toBeNumber();
expectTypeOf<boolean>().toBeBoolean();

// Function signatures
expectTypeOf(myFunction).toBeFunction();
expectTypeOf(myFunction).parameter(0).toBeString();
expectTypeOf(myFunction).parameter(1).toBeNumber();
expectTypeOf(myFunction).returns.toMatchTypeOf<Promise<User>>();
```

### Complex Type Assertions

```ts
// Object shape matching
expectTypeOf<{ name: string; age: number }>().toMatchTypeOf<{ name: string }>();

// Generic type testing
expectTypeOf<Map<string, number>>().toEqualTypeOf<Map<string, number>>();

// Union and intersection types
expectTypeOf<'a' | 'b'>().toMatchTypeOf<string>();

// Branded types
type UserId = string & { __brand: 'UserId' };
expectTypeOf<UserId>().toMatchTypeOf<string>();
expectTypeOf<string>().not.toMatchTypeOf<UserId>();
```

### Type Testing for Library Authors

```ts
import { assertType, expectTypeOf } from 'vitest';

// Verify overloads resolve correctly
declare function parse(input: string): object;
declare function parse(input: string, strict: true): Record<string, unknown>;

expectTypeOf(parse).toBeCallableWith('json');
expectTypeOf(parse('json', true)).toEqualTypeOf<Record<string, unknown>>();

// Verify type inference in generics
function identity<T>(value: T): T { return value; }
expectTypeOf(identity('hello')).toBeString();
expectTypeOf(identity(42)).toBeNumber();

// assertType for inline type checking
assertType<string>(someValue); // compile error if not string
```

### typecheck Configuration

```ts
// vitest.config.ts
export default defineConfig({
  test: {
    typecheck: {
      enabled: true,
      tsconfig: './tsconfig.json',
      include: ['**/*.{test,spec}-d.{ts,tsx}'],
      checker: 'tsc', // or 'vue-tsc' for Vue projects
    },
  },
});
```

Name type test files with `-d` suffix: `utils.test-d.ts`.

---

## Custom Pool Workers

Vitest supports custom test runner pools beyond the built-in `threads`, `forks`, and `vmThreads`.

### Built-in Pools Comparison

| Pool | Isolation | Speed | Use Case |
|------|-----------|-------|----------|
| `threads` | Worker threads (shared memory) | Fastest | Default for most projects |
| `forks` | Child processes | Moderate | Tests that leak state, native addons |
| `vmThreads` | VM contexts in threads | Moderate | Heavy mocking, environment isolation |

### Custom Pool Implementation

```ts
// my-pool.ts
import type { ProcessPool, WorkspaceSpec } from 'vitest/node';

export default function customPool(): ProcessPool {
  return {
    name: 'my-pool',
    async runTests(specs: WorkspaceSpec[], invalidates: string[]) {
      for (const [project, testFile] of specs) {
        // Custom test execution logic
        const config = project.config;
        // Run tests with custom isolation strategy
      }
    },
    async collectTests(specs: WorkspaceSpec[]) {
      // Optional: custom test collection
    },
    async close() {
      // Cleanup resources
    },
  };
}
```

```ts
// vitest.config.ts
export default defineConfig({
  test: {
    pool: './my-pool.ts',
    poolOptions: {
      // Custom options passed to your pool
      myPool: { maxWorkers: 4 },
    },
  },
});
```

---

## Module Graph Testing

Leverage Vite's module graph to test module relationships and dependency chains.

### Accessing the Module Graph

```ts
import { createServer } from 'vite';

const server = await createServer({ configFile: './vite.config.ts' });
await server.pluginContainer.buildStart({});

// Transform a module to populate the graph
await server.transformRequest('src/index.ts');

const graph = server.moduleGraph;
const mod = graph.getModuleById('/absolute/path/src/index.ts');

// Inspect importers and imported modules
console.log('Imported by:', [...(mod?.importers ?? [])].map(m => m.url));
console.log('Imports:', [...(mod?.importedModules ?? [])].map(m => m.url));

await server.close();
```

### Testing for Circular Dependencies

```ts
import { describe, it, expect } from 'vitest';

function detectCircular(graph: Map<string, Set<string>>): string[][] {
  const cycles: string[][] = [];
  const visited = new Set<string>();
  const stack = new Set<string>();

  function dfs(node: string, path: string[]) {
    if (stack.has(node)) {
      const cycleStart = path.indexOf(node);
      cycles.push(path.slice(cycleStart));
      return;
    }
    if (visited.has(node)) return;
    visited.add(node);
    stack.add(node);
    for (const dep of graph.get(node) ?? []) {
      dfs(dep, [...path, node]);
    }
    stack.delete(node);
  }

  for (const node of graph.keys()) dfs(node, []);
  return cycles;
}

describe('Module Graph', () => {
  it('has no circular dependencies', () => {
    const cycles = detectCircular(buildModuleGraph());
    expect(cycles).toEqual([]);
  });
});
```

---

## Dependency Pre-Bundling Control

Vitest uses Vite's dependency optimization. Control what gets pre-bundled in tests.

### Configuration

```ts
export default defineConfig({
  test: {
    deps: {
      optimizer: {
        web: {
          include: ['lodash-es', '@headlessui/react'],
          exclude: ['my-esm-package'],
        },
        ssr: {
          include: ['problematic-cjs-dep'],
        },
      },
      // Force external packages to be inlined
      inline: [/my-monorepo-package/],
      // Treat packages as external (not transformed)
      external: [/node_modules/],
    },
    server: {
      deps: {
        // Inline packages that don't play well with ESM
        inline: ['some-cjs-only-lib'],
        // Fallback CJS resolution
        fallbackCJS: true,
      },
    },
  },
});
```

### When to Adjust Pre-Bundling

- **CJS-only dependencies** that fail ESM import → add to `inline`
- **Large ESM deps** that slow startup → add to optimizer `include`
- **Packages with side effects** on import → consider `external`
- **Monorepo packages** with source TS → add to `inline`

---

## Test Sequencers

Control the order tests execute with custom sequencers.

### Built-in Sequencer Options

```ts
export default defineConfig({
  test: {
    sequence: {
      shuffle: true,         // Randomize to catch order dependencies
      seed: 12345,           // Fixed seed for reproducible shuffle
      concurrent: false,     // Run describes sequentially by default
      setupFiles: 'list',    // 'list' (sequential) or 'parallel'
    },
  },
});
```

### Custom Sequencer

```ts
// my-sequencer.ts
import type { TestSequencer, WorkspaceSpec } from 'vitest/node';

export default class PrioritySequencer implements TestSequencer {
  async sort(files: WorkspaceSpec[]): Promise<WorkspaceSpec[]> {
    // Run critical tests first
    return files.sort(([, a], [, b]) => {
      const priority = (f: string) => {
        if (f.includes('critical')) return 0;
        if (f.includes('integration')) return 1;
        return 2;
      };
      return priority(a) - priority(b);
    });
  }

  async shard(files: WorkspaceSpec[]): Promise<WorkspaceSpec[]> {
    // Custom sharding logic for CI
    return files;
  }
}
```

```ts
// vitest.config.ts
export default defineConfig({
  test: {
    sequence: {
      sequencer: './my-sequencer.ts',
    },
  },
});
```

---

## Custom Reporters

Build reporters to control test output format and side effects.

### Reporter Interface

```ts
import type { Reporter, File, TaskResultPack } from 'vitest/reporters';

export default class MyReporter implements Reporter {
  onInit(ctx: any) {
    // Called when Vitest starts
  }

  onCollected(files?: File[]) {
    // Called after test collection
    console.log(`Collected ${files?.length ?? 0} test files`);
  }

  onTaskUpdate(packs: TaskResultPack[]) {
    // Called on each test result — use for streaming output
    for (const [id, result] of packs) {
      if (result?.state === 'fail') {
        console.error(`FAIL: ${id}`);
      }
    }
  }

  onFinished(files?: File[], errors?: unknown[]) {
    // Called after all tests complete
    const total = files?.reduce((sum, f) =>
      sum + (f.tasks?.length ?? 0), 0) ?? 0;
    console.log(`Finished: ${total} tests`);
  }

  onWatcherRerun(files: string[], trigger?: string) {
    console.log(`Rerunning due to: ${trigger}`);
  }
}
```

### Using Custom Reporters

```ts
export default defineConfig({
  test: {
    reporters: [
      'default',                    // Keep default terminal output
      './my-reporter.ts',           // Add custom reporter
      ['junit', { outputFile: 'results.xml' }],
    ],
  },
});
```

### Slack Notification Reporter Example

```ts
export default class SlackReporter implements Reporter {
  async onFinished(files?: File[]) {
    const failed = files?.filter(f =>
      f.tasks?.some(t => t.result?.state === 'fail')
    );
    if (failed?.length) {
      await fetch(process.env.SLACK_WEBHOOK!, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          text: `🔴 ${failed.length} test files failed`,
        }),
      });
    }
  }
}
```

---

## Workspace Configurations for Monorepos

### Full Workspace Configuration

```ts
// vitest.workspace.ts
import { defineWorkspace } from 'vitest/config';

export default defineWorkspace([
  // Glob patterns for packages with their own vitest.config
  'packages/*/vitest.config.ts',

  // Inline project definitions
  {
    name: 'shared-unit',
    root: './packages/shared',
    test: {
      include: ['src/**/*.test.ts'],
      environment: 'node',
      setupFiles: ['../../test/setup-unit.ts'],
    },
  },
  {
    name: 'web-components',
    root: './packages/web',
    test: {
      include: ['src/**/*.test.tsx'],
      environment: 'jsdom',
      setupFiles: ['../../test/setup-dom.ts'],
      css: true,
    },
  },
  {
    name: 'api-integration',
    root: './packages/api',
    test: {
      include: ['tests/**/*.integration.test.ts'],
      environment: 'node',
      testTimeout: 30000,
      hookTimeout: 30000,
      pool: 'forks', // Isolation for DB tests
    },
  },
]);
```

### Workspace-Level Configuration Sharing

```ts
// vitest.shared.ts — shared config fragment
import type { UserConfig } from 'vitest/config';

export const sharedConfig: UserConfig['test'] = {
  globals: false,
  restoreMocks: true,
  coverage: {
    provider: 'v8',
    reporter: ['text', 'lcov'],
    thresholds: { lines: 80, branches: 75 },
  },
};
```

```ts
// packages/api/vitest.config.ts
import { defineConfig, mergeConfig } from 'vitest/config';
import { sharedConfig } from '../../vitest.shared';

export default defineConfig({
  test: mergeConfig(sharedConfig, {
    include: ['src/**/*.test.ts'],
    environment: 'node',
  }),
});
```

### Running Workspace Projects

```bash
vitest --project shared-unit          # Single project
vitest --project shared-unit --project web-components  # Multiple
vitest --workspace ./custom-workspace.ts               # Custom workspace file
```

---

## Vitest UI

Interactive browser-based test dashboard.

### Setup

```bash
npm install -D @vitest/ui
```

```bash
vitest --ui                # Open UI at http://localhost:51204
vitest --ui --open false   # Start without auto-opening browser
```

### UI Features

- **Test tree view** — collapsible test files and suites
- **Module graph visualization** — see imports and dependencies
- **Source code viewer** — view test source inline with results
- **Console output** — per-test console logs
- **Error details** — formatted diffs and stack traces
- **Filtering** — by status (pass/fail/skip), name pattern, file
- **Coverage viewer** — inline coverage overlay (when run with `--coverage`)

### Configuration

```ts
export default defineConfig({
  test: {
    ui: true,        // Enable UI reporter
    open: true,      // Auto-open browser
    api: {
      port: 51204,   // Custom port
      host: '0.0.0.0', // Allow external access (CI preview)
    },
  },
});
```

---

## Extending Vitest with Plugins

### Vite Plugin Compatibility

Vitest reuses Vite plugins. Any Vite plugin in your config works in tests automatically.

```ts
import vue from '@vitejs/plugin-vue';
import tsconfigPaths from 'vite-tsconfig-paths';

export default defineConfig({
  plugins: [vue(), tsconfigPaths()],
  test: {
    // Tests use the same plugins
  },
});
```

### Custom Vitest Plugin

```ts
import type { Plugin } from 'vitest/config';

function vitestAutoCleanup(): Plugin {
  return {
    name: 'vitest-auto-cleanup',
    config() {
      return {
        test: {
          setupFiles: [new URL('./auto-cleanup.ts', import.meta.url).pathname],
        },
      };
    },
  };
}

export default defineConfig({
  plugins: [vitestAutoCleanup()],
});
```

### Transform Plugin for Test Files

```ts
function testFileTransform(): Plugin {
  return {
    name: 'test-transform',
    enforce: 'pre',
    transform(code, id) {
      if (!id.includes('.test.')) return;
      // Inject test utilities, modify imports, etc.
      return {
        code: `import { setupTestContext } from '#test-utils';\n${code}`,
        map: null,
      };
    },
  };
}
```

### Hooks Available to Plugins in Test Context

| Hook | When | Use Case |
|------|------|----------|
| `configResolved` | After config merged | Read final config |
| `transform` | Each module load | Inject code, modify imports |
| `resolveId` | Module resolution | Custom module aliases |
| `load` | Module loading | Virtual modules for tests |
| `configureServer` | Dev server setup | Custom middleware |
