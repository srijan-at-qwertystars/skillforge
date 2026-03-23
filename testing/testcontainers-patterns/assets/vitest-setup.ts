/**
 * Vitest global setup/teardown with Testcontainers.
 *
 * Starts shared containers before all tests and stops them after.
 * Connection details are exposed via environment variables.
 *
 * Usage:
 *   1. npm install -D testcontainers @testcontainers/postgresql vitest
 *   2. Copy this file to tests/global-setup.ts
 *   3. Add to vitest.config.ts:
 *        export default defineConfig({
 *          test: {
 *            globalSetup: "./tests/global-setup.ts",
 *            testTimeout: 60_000,
 *            hookTimeout: 120_000,
 *          },
 *        });
 *   4. Access env vars in your tests:
 *        process.env.DATABASE_URL
 *        process.env.REDIS_URL
 */

import {
  PostgreSqlContainer,
  type StartedPostgreSqlContainer,
} from "@testcontainers/postgresql";
import {
  GenericContainer,
  type StartedTestContainer,
  Wait,
  Network,
  type StartedNetwork,
} from "testcontainers";

// Container references for teardown
let network: StartedNetwork;
let pgContainer: StartedPostgreSqlContainer;
let redisContainer: StartedTestContainer;

/**
 * Called once before all test files.
 * Starts containers and exports connection info as env vars.
 */
export async function setup(): Promise<void> {
  console.log("\n🐳 Starting Testcontainers...\n");

  // Create a shared network for inter-container communication
  network = await new Network().start();

  // Start containers in parallel for faster setup
  const [pg, redis] = await Promise.all([
    new PostgreSqlContainer("postgres:16-alpine")
      .withDatabase("testdb")
      .withUsername("test")
      .withPassword("test")
      .withNetwork(network)
      .withNetworkAliases("postgres")
      .start(),

    new GenericContainer("redis:7-alpine")
      .withExposedPorts(6379)
      .withWaitStrategy(Wait.forListeningPorts())
      .withNetwork(network)
      .withNetworkAliases("redis")
      .start(),
  ]);

  pgContainer = pg;
  redisContainer = redis;

  // Export connection details as environment variables
  process.env.DATABASE_URL = pgContainer.getConnectionUri();
  process.env.DATABASE_HOST = pgContainer.getHost();
  process.env.DATABASE_PORT = String(pgContainer.getPort());
  process.env.DATABASE_NAME = pgContainer.getDatabase();
  process.env.DATABASE_USER = pgContainer.getUsername();
  process.env.DATABASE_PASSWORD = pgContainer.getPassword();

  process.env.REDIS_URL = `redis://${redisContainer.getHost()}:${redisContainer.getMappedPort(6379)}`;
  process.env.REDIS_HOST = redisContainer.getHost();
  process.env.REDIS_PORT = String(redisContainer.getMappedPort(6379));

  console.log(`  ✅ PostgreSQL: ${process.env.DATABASE_URL}`);
  console.log(`  ✅ Redis:      ${process.env.REDIS_URL}`);
  console.log("");
}

/**
 * Called once after all test files complete.
 * Stops and removes all containers.
 */
export async function teardown(): Promise<void> {
  console.log("\n🐳 Stopping Testcontainers...\n");

  // Stop in reverse order of dependency
  await Promise.all([
    redisContainer?.stop(),
    pgContainer?.stop(),
  ]);

  await network?.stop();

  console.log("  ✅ All containers stopped\n");
}

// ---------------------------------------------------------------------------
// Per-file setup helpers (import in individual test files)
// ---------------------------------------------------------------------------

/**
 * Helper to run SQL against the test database.
 * Import in test files for schema setup.
 *
 * Example:
 *   import { runSQL } from "./global-setup";
 *   beforeAll(async () => {
 *     await runSQL(`
 *       CREATE TABLE IF NOT EXISTS users (
 *         id SERIAL PRIMARY KEY,
 *         name TEXT NOT NULL
 *       )
 *     `);
 *   });
 */
export async function runSQL(sql: string): Promise<void> {
  const { Pool } = await import("pg");
  const pool = new Pool({ connectionString: process.env.DATABASE_URL });
  try {
    await pool.query(sql);
  } finally {
    await pool.end();
  }
}

/**
 * Helper to get a fresh pg Pool for tests.
 *
 * Example:
 *   import { createPool } from "./global-setup";
 *   let pool: Pool;
 *   beforeAll(() => { pool = createPool(); });
 *   afterAll(() => pool.end());
 */
export function createPool() {
  // Dynamic import to avoid requiring pg at module level
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const { Pool } = require("pg");
  return new Pool({ connectionString: process.env.DATABASE_URL });
}
