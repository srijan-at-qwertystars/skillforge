// drizzle.config.template.ts — Production-ready drizzle-kit configuration
//
// Copy to your project root as drizzle.config.ts and adjust paths/dialect.
//
// Supports: postgresql | mysql | sqlite | turso

import { defineConfig } from 'drizzle-kit';

export default defineConfig({
  // ─── Database dialect ─────────────────────────────────────────────────────────
  // Options: 'postgresql' | 'mysql' | 'sqlite' | 'turso'
  dialect: 'postgresql',

  // ─── Schema location ─────────────────────────────────────────────────────────
  // Single file or glob pattern for multi-file schemas
  schema: './src/db/schema.ts',
  // schema: './src/db/schema/*.ts',    // Glob for split schema files

  // ─── Migration output directory ───────────────────────────────────────────────
  out: './drizzle',

  // ─── Database credentials ─────────────────────────────────────────────────────
  dbCredentials: {
    // PostgreSQL / MySQL / SQLite
    url: process.env.DATABASE_URL!,

    // Turso-specific (uncomment and remove url above):
    // url: process.env.TURSO_DATABASE_URL!,
    // authToken: process.env.TURSO_AUTH_TOKEN,
  },

  // ─── Safety options ───────────────────────────────────────────────────────────
  verbose: true,    // Log generated SQL during operations
  strict: true,     // Prompt before destructive changes (drops, renames)

  // ─── Schema filtering (PostgreSQL) ────────────────────────────────────────────
  // Only process specific schemas (useful for multi-schema setups)
  // schemaFilter: ['public', 'billing'],

  // ─── Table filtering ─────────────────────────────────────────────────────────
  // Only process specific tables (useful for large databases)
  // tablesFilter: ['users', 'posts', 'tags'],

  // ─── Migration table config ───────────────────────────────────────────────────
  // Customize the table that tracks applied migrations
  // migrations: {
  //   table: '__drizzle_migrations',
  //   schema: 'public',
  // },

  // ─── Breakpoints ─────────────────────────────────────────────────────────────
  // Add SQL breakpoint comments for splitting migration execution
  // breakpoints: true,
});
