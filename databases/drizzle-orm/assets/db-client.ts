// db-client.ts — Database client setup templates for common Drizzle drivers
//
// Pick the section matching your database provider, copy to your project,
// and update imports/env vars. Always pass { schema } to enable db.query.* API.

import * as schema from './schema';

// ════════════════════════════════════════════════════════════════════════
// OPTION 1: PostgreSQL with postgres-js (recommended for most projects)
// ════════════════════════════════════════════════════════════════════════
// npm i drizzle-orm postgres

import { drizzle } from 'drizzle-orm/postgres-js';
import postgres from 'postgres';

// Long-running server
const client = postgres(process.env.DATABASE_URL!, {
  max: 10,                    // connection pool size
  idle_timeout: 20,           // seconds before idle connection is closed
  connect_timeout: 10,        // seconds to wait for connection
});
export const db = drizzle(client, { schema });

// Dev mode: singleton to avoid pool exhaustion during HMR
// const globalForDb = globalThis as unknown as { conn: postgres.Sql | undefined };
// const conn = globalForDb.conn ?? postgres(process.env.DATABASE_URL!);
// if (process.env.NODE_ENV !== 'production') globalForDb.conn = conn;
// export const db = drizzle(conn, { schema });

// ════════════════════════════════════════════════════════════════════════
// OPTION 2: PostgreSQL with node-postgres (pg)
// ════════════════════════════════════════════════════════════════════════
// npm i drizzle-orm pg
// npm i -D @types/pg

// import { drizzle } from 'drizzle-orm/node-postgres';
// import { Pool } from 'pg';
//
// const pool = new Pool({
//   connectionString: process.env.DATABASE_URL!,
//   max: 20,
//   idleTimeoutMillis: 30000,
//   connectionTimeoutMillis: 5000,
// });
// export const db = drizzle(pool, { schema });

// ════════════════════════════════════════════════════════════════════════
// OPTION 3: Neon Serverless (HTTP — for Edge/serverless)
// ════════════════════════════════════════════════════════════════════════
// npm i drizzle-orm @neondatabase/serverless

// import { neon } from '@neondatabase/serverless';
// import { drizzle } from 'drizzle-orm/neon-http';
//
// // HTTP mode: one-shot queries, no persistent connection — perfect for edge
// const sql = neon(process.env.DATABASE_URL!);
// export const db = drizzle(sql, { schema });

// ════════════════════════════════════════════════════════════════════════
// OPTION 4: Neon Serverless (WebSocket — for serverless with pooling)
// ════════════════════════════════════════════════════════════════════════
// npm i drizzle-orm @neondatabase/serverless ws
// npm i -D @types/ws

// import { Pool, neonConfig } from '@neondatabase/serverless';
// import { drizzle } from 'drizzle-orm/neon-serverless';
// import ws from 'ws';
//
// neonConfig.webSocketConstructor = ws;
// const pool = new Pool({ connectionString: process.env.DATABASE_URL! });
// export const db = drizzle(pool, { schema });

// ════════════════════════════════════════════════════════════════════════
// OPTION 5: Vercel Postgres
// ════════════════════════════════════════════════════════════════════════
// npm i drizzle-orm @vercel/postgres

// import { drizzle } from 'drizzle-orm/vercel-postgres';
// import { sql as vercelSql } from '@vercel/postgres';
//
// export const db = drizzle(vercelSql, { schema });

// ════════════════════════════════════════════════════════════════════════
// OPTION 6: PlanetScale (MySQL serverless)
// ════════════════════════════════════════════════════════════════════════
// npm i drizzle-orm @planetscale/database

// import { drizzle } from 'drizzle-orm/planetscale-serverless';
// import { Client } from '@planetscale/database';
//
// const client = new Client({
//   host: process.env.DATABASE_HOST!,
//   username: process.env.DATABASE_USERNAME!,
//   password: process.env.DATABASE_PASSWORD!,
// });
// export const db = drizzle(client, { schema });

// ════════════════════════════════════════════════════════════════════════
// OPTION 7: MySQL with mysql2
// ════════════════════════════════════════════════════════════════════════
// npm i drizzle-orm mysql2

// import { drizzle } from 'drizzle-orm/mysql2';
// import mysql from 'mysql2/promise';
//
// const pool = await mysql.createPool({
//   uri: process.env.DATABASE_URL!,
//   waitForConnections: true,
//   connectionLimit: 10,
// });
// export const db = drizzle(pool, { schema });

// ════════════════════════════════════════════════════════════════════════
// OPTION 8: SQLite with better-sqlite3
// ════════════════════════════════════════════════════════════════════════
// npm i drizzle-orm better-sqlite3
// npm i -D @types/better-sqlite3

// import { drizzle } from 'drizzle-orm/better-sqlite3';
// import Database from 'better-sqlite3';
//
// const sqlite = new Database(process.env.DATABASE_URL ?? 'local.db');
// sqlite.pragma('journal_mode = WAL');        // better concurrent performance
// sqlite.pragma('foreign_keys = ON');          // enforce FK constraints
// export const db = drizzle(sqlite, { schema });

// ════════════════════════════════════════════════════════════════════════
// OPTION 9: Turso / LibSQL
// ════════════════════════════════════════════════════════════════════════
// npm i drizzle-orm @libsql/client

// import { drizzle } from 'drizzle-orm/libsql';
// import { createClient } from '@libsql/client';
//
// const client = createClient({
//   url: process.env.TURSO_DATABASE_URL!,
//   authToken: process.env.TURSO_AUTH_TOKEN!,
// });
// export const db = drizzle(client, { schema });

// ════════════════════════════════════════════════════════════════════════
// OPTION 10: Cloudflare D1
// ════════════════════════════════════════════════════════════════════════
// npm i drizzle-orm

// import { drizzle } from 'drizzle-orm/d1';
//
// // D1 is accessed via worker bindings, not a connection string.
// // In your Worker's fetch handler:
// export default {
//   async fetch(request: Request, env: { DB: D1Database }) {
//     const db = drizzle(env.DB, { schema });
//     // ... use db
//   },
// };

// ════════════════════════════════════════════════════════════════════════
// OPTION 11: Bun SQLite (built-in)
// ════════════════════════════════════════════════════════════════════════

// import { drizzle } from 'drizzle-orm/bun-sqlite';
// import { Database } from 'bun:sqlite';
//
// const sqlite = new Database('local.db');
// export const db = drizzle(sqlite, { schema });

// ════════════════════════════════════════════════════════════════════════
// Programmatic Migrations (run at app startup)
// ════════════════════════════════════════════════════════════════════════

// PostgreSQL
// import { migrate } from 'drizzle-orm/postgres-js/migrator';
// await migrate(db, { migrationsFolder: './drizzle' });

// SQLite
// import { migrate } from 'drizzle-orm/better-sqlite3/migrator';
// migrate(db, { migrationsFolder: './drizzle' });

// LibSQL / Turso
// import { migrate } from 'drizzle-orm/libsql/migrator';
// await migrate(db, { migrationsFolder: './drizzle' });
