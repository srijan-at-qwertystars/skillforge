/**
 * Production Jest configuration for TypeScript projects.
 * Covers path aliases, coverage thresholds, and transformer setup.
 * Copy to project root and customize as needed.
 */
import type { Config } from 'jest';
// Uncomment to auto-sync path aliases from tsconfig:
// import { pathsToModuleNameMapper } from 'ts-jest';
// import { compilerOptions } from './tsconfig.json';

const config: Config = {
  // -- Environment --
  testEnvironment: 'node', // 'jsdom' for React/browser code
  testEnvironmentOptions: {
    // jsdom options (only when testEnvironment: 'jsdom')
    // url: 'http://localhost',
  },

  // -- Test Discovery --
  roots: ['<rootDir>/src'],
  testMatch: [
    '**/__tests__/**/*.test.ts(x)?',
    '**/*.test.ts(x)?',
    '**/*.spec.ts(x)?',
  ],
  testPathIgnorePatterns: ['/node_modules/', '/dist/', '/build/'],

  // -- Transform --
  // Option A: @swc/jest (fastest, no type-checking)
  transform: {
    '^.+\\.tsx?$': '@swc/jest',
  },
  // Option B: ts-jest (slower, with type-checking)
  // transform: {
  //   '^.+\\.tsx?$': ['ts-jest', {
  //     tsconfig: 'tsconfig.json',
  //     diagnostics: { warnOnly: true },
  //   }],
  // },
  transformIgnorePatterns: [
    '/node_modules/(?!(esm-only-package)/)', // add ESM packages here
  ],

  // -- Module Resolution --
  moduleNameMapper: {
    // Path aliases (keep in sync with tsconfig paths)
    '^@/(.*)$': '<rootDir>/src/$1',
    '^@components/(.*)$': '<rootDir>/src/components/$1',
    '^@utils/(.*)$': '<rootDir>/src/utils/$1',
    '^@hooks/(.*)$': '<rootDir>/src/hooks/$1',
    '^@services/(.*)$': '<rootDir>/src/services/$1',
    // Static assets
    '\\.(css|less|scss|sass)$': 'identity-obj-proxy',
    '\\.(jpg|jpeg|png|gif|webp|avif|svg)$': '<rootDir>/__mocks__/fileMock.js',
  },
  // Auto-sync from tsconfig (alternative to manual mapping above):
  // moduleNameMapper: pathsToModuleNameMapper(compilerOptions.paths, {
  //   prefix: '<rootDir>/',
  // }),
  moduleFileExtensions: ['ts', 'tsx', 'js', 'jsx', 'json', 'node'],

  // -- Setup --
  setupFilesAfterEnv: ['<rootDir>/jest.setup.ts'],
  // globalSetup: '<rootDir>/global-setup.ts',
  // globalTeardown: '<rootDir>/global-teardown.ts',

  // -- Coverage --
  collectCoverageFrom: [
    'src/**/*.{ts,tsx}',
    '!src/**/*.d.ts',
    '!src/**/index.{ts,tsx}',       // barrel files
    '!src/**/*.stories.{ts,tsx}',   // Storybook
    '!src/**/__tests__/**',         // test files
    '!src/**/types/**',             // type-only files
    '!src/main.{ts,tsx}',           // entry points
  ],
  coverageDirectory: 'coverage',
  coverageProvider: 'v8',
  coverageReporters: ['text', 'text-summary', 'lcov', 'clover'],
  coverageThreshold: {
    global: {
      branches: 80,
      functions: 80,
      lines: 80,
      statements: 80,
    },
    // Stricter thresholds for critical paths
    // './src/auth/': { branches: 95, functions: 95, lines: 95, statements: 95 },
  },

  // -- Mock Behavior --
  clearMocks: true,      // auto jest.clearAllMocks() after each test
  restoreMocks: true,    // auto jest.restoreAllMocks() after each test

  // -- Performance --
  maxWorkers: process.env.CI ? '50%' : '70%',
  workerIdleMemoryLimit: '512MB',
  cacheDirectory: '<rootDir>/.jest-cache',

  // -- Execution --
  testTimeout: 10_000,
  bail: process.env.CI ? 1 : 0,
  verbose: !!process.env.CI,

  // -- Snapshots --
  snapshotFormat: {
    printBasicPrototype: false,
  },

  // -- Reporters --
  reporters: [
    'default',
    // ['jest-junit', { outputDirectory: 'reports', outputName: 'jest-results.xml' }],
  ],

  // -- Projects (monorepo) --
  // projects: [
  //   { displayName: 'client', testEnvironment: 'jsdom', testMatch: ['<rootDir>/packages/client/**/*.test.ts(x)?'] },
  //   { displayName: 'server', testEnvironment: 'node', testMatch: ['<rootDir>/packages/server/**/*.test.ts'] },
  // ],
};

export default config;
