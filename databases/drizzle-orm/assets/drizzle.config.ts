// drizzle.config.ts — Complete configuration template with all options annotated
//
// Docs: https://orm.drizzle.team/docs/drizzle-config-file

import { defineConfig } from 'drizzle-kit';

export default defineConfig({
  // ─── Schema ──────────────────────────────────────────────────────────
  // Path(s) to your schema file(s). Relative to project root.
  // Accepts a single file, array of files, or glob pattern.
  schema: './src/db/schema.ts',
  // schema: './src/db/schema/*.ts',           // glob for multi-file schemas
  // schema: ['./src/db/users.ts', './src/db/posts.ts'],  // explicit list

  // ─── Output ──────────────────────────────────────────────────────────
  // Directory for generated migration files and snapshots.
  out: './drizzle',

  // ─── Dialect ─────────────────────────────────────────────────────────
  // Database dialect. Determines SQL flavor for generated migrations.
  // Options: 'postgresql' | 'mysql' | 'sqlite' | 'turso'
  dialect: 'postgresql',

  // ─── Database Credentials ────────────────────────────────────────────
  // Connection details for push, pull, migrate, and studio commands.
  // Structure varies by dialect.

  dbCredentials: {
    // PostgreSQL / MySQL / Turso — connection URL
    url: process.env.DATABASE_URL!,

    // Turso-specific: auth token
    // authToken: process.env.TURSO_AUTH_TOKEN,

    // Alternative: individual connection parameters (PostgreSQL)
    // host: process.env.DB_HOST,
    // port: Number(process.env.DB_PORT),
    // user: process.env.DB_USER,
    // password: process.env.DB_PASSWORD,
    // database: process.env.DB_NAME,
    // ssl: true,  // or { rejectUnauthorized: false }
  },

  // ─── Schema Filter ───────────────────────────────────────────────────
  // Which database schemas to include in introspection/migrations.
  // Default: ['public'] for PostgreSQL.
  // schemaFilter: ['public', 'auth', 'billing'],

  // ─── Table Filters ───────────────────────────────────────────────────
  // Glob patterns to include/exclude specific tables.
  // tablesFilter: ['users', 'posts', '!_migrations'],  // include users/posts, exclude _migrations

  // ─── Migrations ──────────────────────────────────────────────────────
  // Migration table name (where Drizzle tracks applied migrations).
  // Default: '__drizzle_migrations'
  // migrations: {
  //   table: '__drizzle_migrations',
  //   schema: 'public',        // schema for the migrations table (pg only)
  // },

  // ─── Verbose Logging ─────────────────────────────────────────────────
  // Print all SQL statements during push/migrate operations.
  verbose: true,

  // ─── Strict Mode ─────────────────────────────────────────────────────
  // Always ask for confirmation for data-loss operations (drop table, drop column).
  strict: true,

  // ─── Breakpoints ─────────────────────────────────────────────────────
  // Insert `-- breakpoint` comments between SQL statements in migration files.
  // Useful when migration runners don't support multi-statement execution.
  // Default: true
  // breakpoints: true,

  // ─── Introspect ──────────────────────────────────────────────────────
  // Configuration for `drizzle-kit pull` command.
  // introspect: {
  //   casing: 'camel',  // 'preserve' (default) | 'camel' — column name casing in generated TS
  // },

  // ─── Entities ────────────────────────────────────────────────────────
  // Fine-grained control over which entities to manage.
  // entities: {
  //   roles: {
  //     provider: 'supabase',  // or 'neon' — manages provider-specific roles
  //     exclude: ['supabase_admin'],
  //     include: [],
  //   },
  // },
});
