/**
 * Turso/libSQL TypeScript Client Template
 *
 * Supports three modes:
 *   1. Remote — direct connection to Turso (serverless, edge)
 *   2. Embedded replica — local SQLite file synced from Turso (long-running servers)
 *   3. Local file — pure SQLite for development/testing
 *
 * Install:
 *   npm install @libsql/client
 *
 * Environment variables:
 *   TURSO_DATABASE_URL  — libsql://dbname-org.turso.io
 *   TURSO_AUTH_TOKEN    — JWT auth token
 *   TURSO_LOCAL_DB      — (optional) local replica file path
 *   NODE_ENV            — development | production
 */

import { createClient, type Client, type ResultSet } from "@libsql/client";

// --- Client Configuration ---

interface TursoConfig {
  mode: "remote" | "replica" | "local";
  url: string;
  syncUrl?: string;
  authToken?: string;
  syncInterval?: number; // seconds
}

function getConfig(): TursoConfig {
  const isDev = process.env.NODE_ENV !== "production";

  // Local development — no Turso account needed
  if (isDev && !process.env.TURSO_DATABASE_URL) {
    return {
      mode: "local",
      url: "file:dev.db",
    };
  }

  // Embedded replica — local reads, remote writes
  if (process.env.TURSO_LOCAL_DB) {
    return {
      mode: "replica",
      url: `file:${process.env.TURSO_LOCAL_DB}`,
      syncUrl: process.env.TURSO_DATABASE_URL!,
      authToken: process.env.TURSO_AUTH_TOKEN,
      syncInterval: 60,
    };
  }

  // Remote — direct to Turso
  return {
    mode: "remote",
    url: process.env.TURSO_DATABASE_URL!,
    authToken: process.env.TURSO_AUTH_TOKEN,
  };
}

// --- Singleton Client ---

let _client: Client | null = null;

export function getClient(): Client {
  if (_client) return _client;

  const config = getConfig();

  switch (config.mode) {
    case "local":
      _client = createClient({ url: config.url });
      break;

    case "replica":
      _client = createClient({
        url: config.url,
        syncUrl: config.syncUrl,
        authToken: config.authToken,
        syncInterval: config.syncInterval,
      });
      break;

    case "remote":
      _client = createClient({
        url: config.url,
        authToken: config.authToken,
      });
      break;
  }

  console.log(`[turso] Connected in ${config.mode} mode`);
  return _client;
}

// --- Helper Functions ---

/** Execute a query with retry logic for transient failures */
export async function executeWithRetry(
  sql: string,
  args: (string | number | null | bigint | ArrayBuffer)[] = [],
  maxRetries = 3
): Promise<ResultSet> {
  const client = getClient();

  for (let attempt = 1; attempt <= maxRetries; attempt++) {
    try {
      return await client.execute({ sql, args });
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      const isTransient =
        message.includes("fetch failed") ||
        message.includes("TIMEOUT") ||
        message.includes("network");

      if (!isTransient || attempt === maxRetries) throw err;

      const delay = Math.min(1000 * 2 ** (attempt - 1), 10000);
      console.warn(`[turso] Retry ${attempt}/${maxRetries} after ${delay}ms`);
      await new Promise((r) => setTimeout(r, delay));
    }
  }

  throw new Error("Unreachable");
}

/** Sync embedded replica (no-op for remote/local modes) */
export async function sync(): Promise<void> {
  const client = getClient();
  if ("sync" in client && typeof client.sync === "function") {
    await client.sync();
  }
}

/** Graceful shutdown — final sync and close */
export async function shutdown(): Promise<void> {
  if (_client) {
    try {
      await sync();
    } catch {
      // Best effort
    }
    _client.close();
    _client = null;
    console.log("[turso] Connection closed");
  }
}

// --- Usage Example ---

async function main() {
  const client = getClient();

  // Create table
  await client.execute(`
    CREATE TABLE IF NOT EXISTS users (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      email TEXT NOT NULL UNIQUE,
      created_at TEXT NOT NULL DEFAULT (datetime('now'))
    )
  `);

  // Insert
  await client.execute({
    sql: "INSERT OR IGNORE INTO users (name, email) VALUES (?, ?)",
    args: ["Alice", "alice@example.com"],
  });

  // Sync replica after write
  await sync();

  // Query
  const result = await client.execute("SELECT * FROM users");
  console.log("Users:", result.rows);

  // Batch insert
  const batchResults = await client.batch(
    [
      { sql: "INSERT OR IGNORE INTO users (name, email) VALUES (?, ?)", args: ["Bob", "bob@example.com"] },
      { sql: "INSERT OR IGNORE INTO users (name, email) VALUES (?, ?)", args: ["Carol", "carol@example.com"] },
      { sql: "SELECT count(*) as total FROM users", args: [] },
    ],
    "write"
  );
  console.log("Total users:", batchResults[2].rows[0].total);

  // Transaction
  const tx = await client.transaction("write");
  try {
    await tx.execute({
      sql: "UPDATE users SET name = ? WHERE email = ?",
      args: ["Alice Updated", "alice@example.com"],
    });
    await tx.commit();
  } catch {
    await tx.rollback();
  }

  await shutdown();
}

// Run if executed directly
main().catch(console.error);
