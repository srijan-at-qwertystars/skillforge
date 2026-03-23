import { defineWorkspace } from 'vitest/config';

/**
 * Monorepo workspace configuration for Vitest.
 * Defines separate test projects with independent environments and settings.
 *
 * Run all:          vitest
 * Run one project:  vitest --project unit
 * Run multiple:     vitest --project unit --project components
 */
export default defineWorkspace([
  // Unit tests — fast, Node environment, for business logic and utilities
  {
    name: 'unit',
    root: '.',
    test: {
      include: ['packages/*/src/**/*.test.ts', 'packages/*/src/**/*.spec.ts'],
      exclude: ['**/*.integration.test.ts', '**/*.browser.test.ts'],
      environment: 'node',
      setupFiles: ['./test/setup-unit.ts'],
      testTimeout: 5000,
    },
  },

  // Component tests — jsdom environment for React/Vue component testing
  {
    name: 'components',
    root: '.',
    test: {
      include: ['packages/*/src/**/*.test.tsx', 'packages/*/src/**/*.spec.tsx'],
      environment: 'jsdom',
      setupFiles: ['./test/setup-dom.ts'],
      css: true,
      testTimeout: 10000,
    },
  },

  // Integration tests — longer timeouts, process isolation
  {
    name: 'integration',
    root: '.',
    test: {
      include: ['packages/*/tests/**/*.integration.test.ts'],
      environment: 'node',
      pool: 'forks', // Full isolation for DB/network tests
      poolOptions: {
        forks: { maxForks: 2 },
      },
      testTimeout: 30000,
      hookTimeout: 30000,
      setupFiles: ['./test/setup-integration.ts'],
    },
  },

  // Edge runtime tests — for Cloudflare Workers, Vercel Edge
  {
    name: 'edge',
    root: '.',
    test: {
      include: ['packages/edge/src/**/*.test.ts'],
      environment: 'edge-runtime',
      testTimeout: 10000,
    },
  },

  // Individual packages with their own config
  'packages/standalone-pkg/vitest.config.ts',
]);
