// vitest.config.template.ts — Production-ready Vitest configuration
//
// Usage: Copy to your project root as `vitest.config.ts` and adjust values.
// Requires: vitest, @vitest/coverage-v8, @vitest/ui (optional)

import { defineConfig } from 'vitest/config'
import path from 'path'

export default defineConfig({
  resolve: {
    alias: {
      '@': path.resolve(__dirname, 'src'),
      '@components': path.resolve(__dirname, 'src/components'),
      '@utils': path.resolve(__dirname, 'src/utils'),
      '@test': path.resolve(__dirname, 'test'),
    },
  },

  test: {
    // ── Globals ──────────────────────────────────────────────────────
    globals: true, // enable describe/it/expect without imports

    // ── Environment ──────────────────────────────────────────────────
    // 'node' for server code, 'jsdom' for DOM, 'happy-dom' for faster DOM
    environment: 'jsdom',

    // ── File patterns ────────────────────────────────────────────────
    include: ['src/**/*.{test,spec}.{ts,tsx,js,jsx}'],
    exclude: ['node_modules', 'dist', 'build', '.next', 'e2e', 'cypress'],

    // ── Setup ────────────────────────────────────────────────────────
    setupFiles: ['./vitest.setup.ts'],
    // globalSetup: ['./vitest.global-setup.ts'], // one-time setup (DB, server, etc.)

    // ── Execution ────────────────────────────────────────────────────
    pool: 'forks', // 'threads' | 'forks' | 'vmThreads'
    poolOptions: {
      forks: {
        minForks: 1,
        maxForks: process.env.CI ? 2 : 4,
      },
    },
    fileParallelism: true,
    maxConcurrency: 5,
    isolate: true,

    // ── Timeouts ─────────────────────────────────────────────────────
    testTimeout: process.env.CI ? 30000 : 10000,
    hookTimeout: 15000,

    // ── Retries and bail ─────────────────────────────────────────────
    retry: process.env.CI ? 2 : 0,
    bail: process.env.CI ? 5 : 0,

    // ── Reporters ────────────────────────────────────────────────────
    reporters: process.env.CI
      ? ['default', 'junit']
      : ['default'],
    outputFile: {
      junit: './test-results/junit.xml',
    },

    // ── Mock defaults ────────────────────────────────────────────────
    restoreMocks: true,
    clearMocks: true,
    mockReset: false,
    unstubEnvs: true,
    unstubGlobals: true,

    // ── CSS ──────────────────────────────────────────────────────────
    css: true,

    // ── Snapshots ────────────────────────────────────────────────────
    snapshotFormat: {
      printBasicPrototype: false,
    },

    // ── Coverage ─────────────────────────────────────────────────────
    coverage: {
      provider: 'v8',
      enabled: false, // enable via --coverage flag or CI
      reporter: ['text', 'html', 'lcov', 'json-summary'],
      reportsDirectory: './coverage',
      include: ['src/**/*.{ts,tsx,js,jsx}'],
      exclude: [
        '**/*.test.*',
        '**/*.spec.*',
        '**/*.d.ts',
        '**/types/**',
        '**/index.{ts,js}',
        '**/__mocks__/**',
        '**/__fixtures__/**',
      ],
      all: true,
      clean: true,
      thresholds: {
        lines: 80,
        branches: 75,
        functions: 80,
        statements: 80,
      },
    },

    // ── Type checking (uncomment to enable) ──────────────────────────
    // typecheck: {
    //   enabled: true,
    //   tsconfig: './tsconfig.json',
    //   include: ['**/*.test-d.ts'],
    // },

    // ── Watch mode ───────────────────────────────────────────────────
    watchExclude: ['**/node_modules/**', '**/dist/**', '**/coverage/**'],
    forceRerunTriggers: ['**/vitest.config.*', '**/vitest.setup.*'],
  },
})
