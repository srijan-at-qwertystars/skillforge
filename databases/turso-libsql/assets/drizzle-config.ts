/**
 * Drizzle ORM Configuration for Turso
 *
 * Install:
 *   npm install drizzle-orm @libsql/client
 *   npm install -D drizzle-kit
 *
 * Commands:
 *   npx drizzle-kit generate   — Generate migration SQL from schema changes
 *   npx drizzle-kit migrate    — Apply migrations to Turso
 *   npx drizzle-kit push       — Push schema directly (dev only)
 *   npx drizzle-kit studio     — Open Drizzle Studio GUI
 *
 * Environment variables:
 *   TURSO_DATABASE_URL  — libsql://dbname-org.turso.io
 *   TURSO_AUTH_TOKEN    — JWT auth token
 */

import type { Config } from "drizzle-kit";

export default {
  // Path to your schema definitions
  schema: "./src/db/schema.ts",

  // Output directory for generated migration files
  out: "./drizzle",

  // Use "turso" dialect for Turso/libSQL
  dialect: "turso",

  dbCredentials: {
    url: process.env.TURSO_DATABASE_URL!,
    authToken: process.env.TURSO_AUTH_TOKEN,
  },

  // Optional: verbose logging during migrations
  verbose: true,

  // Optional: require confirmation before applying destructive changes
  strict: true,
} satisfies Config;


// ============================================================
// Example schema file (save as src/db/schema.ts)
// ============================================================
//
// import { sqliteTable, text, integer, real } from "drizzle-orm/sqlite-core";
// import { sql } from "drizzle-orm";
//
// export const users = sqliteTable("users", {
//   id: integer("id").primaryKey({ autoIncrement: true }),
//   name: text("name").notNull(),
//   email: text("email").notNull().unique(),
//   createdAt: text("created_at")
//     .notNull()
//     .default(sql`(datetime('now'))`),
// });
//
// export const posts = sqliteTable("posts", {
//   id: integer("id").primaryKey({ autoIncrement: true }),
//   title: text("title").notNull(),
//   content: text("content").notNull(),
//   authorId: integer("author_id")
//     .notNull()
//     .references(() => users.id),
//   createdAt: text("created_at")
//     .notNull()
//     .default(sql`(datetime('now'))`),
// });


// ============================================================
// Example database client (save as src/db/index.ts)
// ============================================================
//
// import { drizzle } from "drizzle-orm/libsql";
// import { createClient } from "@libsql/client";
// import * as schema from "./schema";
//
// const client = createClient({
//   url: process.env.TURSO_DATABASE_URL!,
//   authToken: process.env.TURSO_AUTH_TOKEN,
// });
//
// export const db = drizzle(client, { schema });
//
// // Usage:
// // import { db } from "./db";
// // import { users } from "./db/schema";
// // import { eq } from "drizzle-orm";
// //
// // const allUsers = await db.select().from(users);
// // const user = await db.select().from(users).where(eq(users.id, 1));
// // await db.insert(users).values({ name: "Alice", email: "alice@example.com" });
