/// <reference types="vitest/config" />
import { defineConfig } from 'vitest/config';
import path from 'path';

export default defineConfig({
  resolve: {
    alias: {
      '@': path.resolve(__dirname, 'src'),
      '@test': path.resolve(__dirname, 'test'),
    },
  },

  test: {
    // Test file discovery
    include: ['src/**/*.{test,spec}.{ts,tsx,js,jsx}'],
    exclude: ['node_modules', 'dist', 'build', 'e2e', '**/*.bench.ts'],

    // Environment — 'node' | 'jsdom' | 'happy-dom' | 'edge-runtime'
    // Override per-file with: // @vitest-environment jsdom
    environment: 'node',

    // Explicit imports preferred over globals for clarity
    globals: false,

    // Setup files run before each test file
    setupFiles: ['./test/setup.ts'],

    // Timeouts
    testTimeout: 5000,
    hookTimeout: 10000,

    // Pool configuration
    pool: 'threads',
    poolOptions: {
      threads: {
        maxThreads: undefined, // Auto-detect based on CPU
        minThreads: 1,
      },
    },

    // Test execution
    sequence: {
      shuffle: false, // Enable to detect order-dependent tests
    },
    fileParallelism: true,
    maxConcurrency: 10,

    // Retry flaky tests (0 = no retry)
    retry: 0,

    // Reporters — adjust for CI vs local
    reporters: process.env.CI
      ? ['dot', 'github-actions', ['junit', { outputFile: 'test-results.xml' }]]
      : ['default'],

    // Coverage configuration
    coverage: {
      provider: 'v8',
      enabled: false, // Enable with --coverage flag
      reporter: ['text', 'json', 'html', 'lcov'],
      reportsDirectory: './coverage',
      include: ['src/**/*.{ts,tsx,js,jsx}'],
      exclude: [
        'src/**/*.{test,spec}.{ts,tsx,js,jsx}',
        'src/**/*.d.ts',
        'src/**/*.stories.{ts,tsx}',
        'src/**/index.{ts,js}', // Re-export barrels
        'src/**/__mocks__/**',
        'src/**/__fixtures__/**',
        'src/types/**',
      ],
      thresholds: {
        lines: 80,
        functions: 80,
        branches: 75,
        statements: 80,
      },
    },

    // Snapshot options
    snapshotFormat: {
      printBasicPrototype: false,
    },

    // CSS handling — set to true if testing CSS modules
    css: false,

    // Mock restoration — auto-restore all mocks after each test
    restoreMocks: true,

    // Type checking (enable for type-level tests)
    // typecheck: {
    //   enabled: true,
    //   include: ['**/*.test-d.ts'],
    // },
  },
});
