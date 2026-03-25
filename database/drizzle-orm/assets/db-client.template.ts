// db-client.template.ts — Database client setup for multiple runtimes
//
// Copy the section matching your runtime to src/db/index.ts.
// Always import your schema for relational query support.

import * as schema from './schema';

// ═══════════════════════════════════════════════════════════════════════════════
// Node.js — PostgreSQL (node-postgres / pg)
// npm i drizzle-orm pg && npm i -D @types/pg
// ═══════════════════════════════════════════════════════════════════════════════

// import { drizzle } from 'drizzle-orm/node-postgres';
// import { Pool } from 'pg';
//
// const pool = new Pool({
//   connectionString: process.env.DATABASE_URL!,
//   max: 20,                       // Tune based on your DB's max_connections
//   idleTimeoutMillis: 30_000,
//   connectionTimeoutMillis: 5_000,
//   allowExitOnIdle: true,
// });
//
// export const db = drizzle(pool, { schema, logger: process.env.NODE_ENV === 'development' });
//
// // Graceful shutdown
// process.on('SIGTERM', () => pool.end());
// process.on('SIGINT', () => pool.end());

// ═══════════════════════════════════════════════════════════════════════════════
// Node.js — PostgreSQL (postgres.js — also works in Bun/Deno)
// npm i drizzle-orm postgres
// ═══════════════════════════════════════════════════════════════════════════════

// import { drizzle } from 'drizzle-orm/postgres-js';
// import postgres from 'postgres';
//
// const client = postgres(process.env.DATABASE_URL!, {
//   max: 10,
//   idle_timeout: 20,
//   connect_timeout: 10,
//   prepare: true,                 // Reuse query plans (faster for repeated queries)
// });
//
// export const db = drizzle(client, { schema });
//
// process.on('SIGTERM', () => client.end());

// ═══════════════════════════════════════════════════════════════════════════════
// Node.js — MySQL (mysql2)
// npm i drizzle-orm mysql2
// ═══════════════════════════════════════════════════════════════════════════════

// import { drizzle } from 'drizzle-orm/mysql2';
// import mysql from 'mysql2/promise';
//
// const pool = mysql.createPool({
//   uri: process.env.DATABASE_URL!,
//   connectionLimit: 10,
//   waitForConnections: true,
//   enableKeepAlive: true,
//   keepAliveInitialDelay: 10_000,
// });
//
// export const db = drizzle(pool, { schema, mode: 'default' });

// ═══════════════════════════════════════════════════════════════════════════════
// Node.js — SQLite (better-sqlite3)
// npm i drizzle-orm better-sqlite3 && npm i -D @types/better-sqlite3
// ═══════════════════════════════════════════════════════════════════════════════

// import { drizzle } from 'drizzle-orm/better-sqlite3';
// import Database from 'better-sqlite3';
//
// const sqlite = new Database(process.env.DATABASE_URL ?? 'sqlite.db');
// sqlite.pragma('journal_mode = WAL');       // Better concurrent read performance
// sqlite.pragma('foreign_keys = ON');        // Enforce FK constraints
//
// export const db = drizzle(sqlite, { schema });

// ═══════════════════════════════════════════════════════════════════════════════
// Bun — SQLite (bun:sqlite)
// bun add drizzle-orm
// ═══════════════════════════════════════════════════════════════════════════════

// import { drizzle } from 'drizzle-orm/bun-sqlite';
// import { Database } from 'bun:sqlite';
//
// const sqlite = new Database(process.env.DATABASE_URL ?? 'sqlite.db', {
//   create: true,
// });
//
// export const db = drizzle(sqlite, { schema });

// ═══════════════════════════════════════════════════════════════════════════════
// Turso / libSQL (works in Node.js, Bun, edge)
// npm i drizzle-orm @libsql/client
// ═══════════════════════════════════════════════════════════════════════════════

// import { drizzle } from 'drizzle-orm/libsql';
// import { createClient } from '@libsql/client';
//
// const client = createClient({
//   url: process.env.TURSO_DATABASE_URL!,
//   authToken: process.env.TURSO_AUTH_TOKEN,
// });
//
// export const db = drizzle(client, { schema });

// ═══════════════════════════════════════════════════════════════════════════════
// Neon Serverless (HTTP — Vercel Edge, Cloudflare Workers)
// npm i drizzle-orm @neondatabase/serverless
// ═══════════════════════════════════════════════════════════════════════════════

// import { drizzle } from 'drizzle-orm/neon-http';
// import { neon } from '@neondatabase/serverless';
//
// const sql = neon(process.env.DATABASE_URL!);
// export const db = drizzle(sql, { schema });

// ═══════════════════════════════════════════════════════════════════════════════
// Cloudflare D1 (Workers)
// npm i drizzle-orm
// ═══════════════════════════════════════════════════════════════════════════════

// // In your Worker handler:
// import { drizzle } from 'drizzle-orm/d1';
//
// export default {
//   async fetch(request: Request, env: Env) {
//     const db = drizzle(env.DB, { schema });
//     const users = await db.query.users.findMany();
//     return Response.json(users);
//   },
// };

// ═══════════════════════════════════════════════════════════════════════════════
// Vercel Postgres
// npm i drizzle-orm @vercel/postgres
// ═══════════════════════════════════════════════════════════════════════════════

// import { drizzle } from 'drizzle-orm/vercel-postgres';
// import { sql } from '@vercel/postgres';
//
// export const db = drizzle(sql, { schema });

// ═══════════════════════════════════════════════════════════════════════════════
// Programmatic migration (add to app startup or deploy script)
// ═══════════════════════════════════════════════════════════════════════════════

// import { migrate } from 'drizzle-orm/node-postgres/migrator';
// // or: drizzle-orm/postgres-js/migrator, drizzle-orm/mysql2/migrator, etc.
//
// async function runMigrations() {
//   console.log('Running migrations...');
//   await migrate(db, { migrationsFolder: './drizzle' });
//   console.log('Migrations complete');
// }
//
// if (process.env.RUN_MIGRATIONS === 'true') {
//   runMigrations().catch(console.error);
// }
