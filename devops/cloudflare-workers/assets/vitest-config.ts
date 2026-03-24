// Vitest configuration for Cloudflare Workers
// Uses @cloudflare/vitest-pool-workers for real Workers runtime testing
//
// Install:
//   npm install -D vitest @cloudflare/vitest-pool-workers
//
// Run:
//   npx vitest run         # single run
//   npx vitest             # watch mode
//   npx vitest --coverage  # with coverage (install @vitest/coverage-v8)

import { defineWorkersProject } from "@cloudflare/vitest-pool-workers/config";

export default defineWorkersProject({
  test: {
    // Test file patterns
    include: ["test/**/*.test.ts", "test/**/*.spec.ts"],
    exclude: ["test/e2e/**", "node_modules/**"],

    // Pool configuration — runs tests inside Workers runtime
    poolOptions: {
      workers: {
        // Use your actual wrangler.toml for bindings, vars, etc.
        wrangler: {
          configPath: "./wrangler.toml",
          // Override environment for tests
          // environment: "test",
        },

        // Miniflare overrides (take precedence over wrangler.toml)
        miniflare: {
          compatibilityDate: "2024-09-23",
          compatibilityFlags: ["nodejs_compat"],

          // Mock bindings for tests (override wrangler.toml bindings)
          kvNamespaces: ["KV"],
          d1Databases: ["DB"],
          r2Buckets: ["BUCKET"],
          durableObjects: {
            MY_OBJECT: "MyDurableObject",
          },

          // Test environment variables
          bindings: {
            ENVIRONMENT: "test",
            JWT_SECRET: "test-secret-do-not-use-in-production",
          },
        },

        // Run tests in a single worker (faster, shared state)
        singleWorker: true,
      },
    },

    // Global setup/teardown
    // globalSetup: ["./test/global-setup.ts"],

    // Coverage configuration
    coverage: {
      provider: "v8",
      include: ["src/**/*.ts"],
      exclude: ["src/**/*.test.ts", "src/**/*.d.ts"],
      reporter: ["text", "json", "html"],
      thresholds: {
        lines: 80,
        functions: 80,
        branches: 70,
        statements: 80,
      },
    },

    // Timeouts
    testTimeout: 10_000,
    hookTimeout: 10_000,

    // Reporter
    reporters: ["verbose"],
  },
});

// =============================================================================
// Test helpers — put in test/helpers.ts
// =============================================================================
//
// import { env } from "cloudflare:test";
//
// // Seed D1 database before tests
// export async function seedDatabase() {
//   await env.DB.exec(`
//     CREATE TABLE IF NOT EXISTS items (
//       id INTEGER PRIMARY KEY AUTOINCREMENT,
//       name TEXT NOT NULL,
//       description TEXT,
//       tags TEXT DEFAULT '[]',
//       created_at TEXT DEFAULT (datetime('now')),
//       updated_at TEXT
//     );
//   `);
// }
//
// // Clear all test data
// export async function clearDatabase() {
//   await env.DB.exec("DELETE FROM items;");
// }
//
// // Create test request with auth headers
// export function authedRequest(path: string, options: RequestInit = {}): Request {
//   const headers = new Headers(options.headers);
//   headers.set("Authorization", "Bearer test-token");
//   headers.set("Content-Type", "application/json");
//   return new Request(`https://test.example.com${path}`, { ...options, headers });
// }
