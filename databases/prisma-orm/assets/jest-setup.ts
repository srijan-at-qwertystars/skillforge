// =============================================================================
// Jest Test Setup for Prisma
//
// Features:
//   - Deep-mocked PrismaClient for unit tests
//   - Test database connection for integration tests
//   - Cleanup utilities (truncate all tables)
//   - Transaction-based test isolation
//
// Setup:
//   npm install --save-dev jest @jest/globals ts-jest jest-mock-extended
//
// In jest.config.ts:
//   {
//     preset: 'ts-jest',
//     testEnvironment: 'node',
//     setupFilesAfterSetup: ['./jest-setup.ts'],
//   }
//
// Usage:
//   // Unit test — import the mock
//   import { prismaMock } from './jest-setup';
//
//   // Integration test — import the real client
//   import { prismaTest, cleanupDatabase } from './jest-setup';
// =============================================================================

import { PrismaClient } from '@prisma/client';
import { mockDeep, DeepMockProxy } from 'jest-mock-extended';

// ---------------------------------------------------------------------------
// Unit Test Mock
// ---------------------------------------------------------------------------

/**
 * Deep-mocked PrismaClient for unit tests.
 * All methods return undefined by default — configure with .mockResolvedValue().
 *
 * Example:
 *   prismaMock.user.findMany.mockResolvedValue([
 *     { id: 1, email: 'test@example.com', name: 'Test' },
 *   ]);
 */
export const prismaMock: DeepMockProxy<PrismaClient> = mockDeep<PrismaClient>();

/**
 * Reset all mocks between tests.
 * Called automatically via beforeEach if this file is in setupFilesAfterSetup.
 */
beforeEach(() => {
  // Reset mock implementations and call history
  jest.clearAllMocks();
});

// ---------------------------------------------------------------------------
// Integration Test Client
// ---------------------------------------------------------------------------

/**
 * Real PrismaClient connected to the test database.
 * Uses TEST_DATABASE_URL environment variable.
 *
 * ⚠ Ensure TEST_DATABASE_URL points to a disposable test database!
 */
export const prismaTest = new PrismaClient({
  datasources: {
    db: {
      url: process.env.TEST_DATABASE_URL ?? process.env.DATABASE_URL,
    },
  },
  log: [{ level: 'error', emit: 'stdout' }],
});

// ---------------------------------------------------------------------------
// Cleanup Utilities
// ---------------------------------------------------------------------------

/**
 * Delete all data from all tables (respects FK constraints).
 * Call in beforeEach or afterEach for test isolation.
 *
 * Usage:
 *   beforeEach(async () => {
 *     await cleanupDatabase();
 *   });
 */
export async function cleanupDatabase(): Promise<void> {
  // Order matters — delete child tables first to respect foreign keys.
  // Adjust this list to match your schema models.
  const deleteOperations = [
    prismaTest.post.deleteMany(),
    prismaTest.session.deleteMany(),
    prismaTest.account.deleteMany(),
    prismaTest.user.deleteMany(),
  ];

  await prismaTest.$transaction(deleteOperations);
}

/**
 * Alternative: Truncate all tables using raw SQL (PostgreSQL).
 * Faster than deleteMany for large test suites.
 */
export async function truncateAllTables(): Promise<void> {
  const tables = await prismaTest.$queryRaw<{ tablename: string }[]>`
    SELECT tablename FROM pg_tables
    WHERE schemaname = 'public'
    AND tablename NOT LIKE '_prisma_%'
  `;

  if (tables.length === 0) return;

  const tableNames = tables.map((t) => `"${t.tablename}"`).join(', ');
  await prismaTest.$executeRawUnsafe(
    `TRUNCATE TABLE ${tableNames} CASCADE`
  );
}

// ---------------------------------------------------------------------------
// Transaction-Based Test Isolation
// ---------------------------------------------------------------------------

/**
 * Run a test inside a transaction that auto-rolls back.
 * Each test gets a clean state without manual cleanup.
 *
 * Usage:
 *   it('creates a user', () =>
 *     withTestTransaction(async (tx) => {
 *       const user = await tx.user.create({ data: { email: 'test@example.com' } });
 *       expect(user.email).toBe('test@example.com');
 *     })
 *   );
 */
export async function withTestTransaction(
  fn: (tx: Omit<PrismaClient, '$connect' | '$disconnect' | '$on' | '$transaction' | '$use' | '$extends'>) => Promise<void>
): Promise<void> {
  try {
    await prismaTest.$transaction(async (tx) => {
      await fn(tx);
      // Force rollback by throwing
      throw new RollbackError();
    });
  } catch (e) {
    if (!(e instanceof RollbackError)) {
      throw e;
    }
  }
}

class RollbackError extends Error {
  constructor() {
    super('Transaction rollback for test isolation');
    this.name = 'RollbackError';
  }
}

// ---------------------------------------------------------------------------
// Test Factories
// ---------------------------------------------------------------------------

/**
 * Factory helpers for creating test data with sensible defaults.
 * Override any field as needed.
 */
export const factories = {
  user: (overrides: Partial<Parameters<typeof prismaTest.user.create>[0]['data']> = {}) => ({
    email: `test-${Date.now()}-${Math.random().toString(36).slice(2)}@example.com`,
    name: 'Test User',
    ...overrides,
  }),

  post: (authorId: string | number, overrides: Record<string, unknown> = {}) => ({
    title: 'Test Post',
    slug: `test-post-${Date.now()}-${Math.random().toString(36).slice(2)}`,
    content: 'Test content',
    authorId,
    ...overrides,
  }),
};

// ---------------------------------------------------------------------------
// Global Setup / Teardown
// ---------------------------------------------------------------------------

// Disconnect after all tests in the suite
afterAll(async () => {
  await prismaTest.$disconnect();
});
