#!/usr/bin/env bash
# setup-drizzle.sh — Initialize Drizzle ORM in an existing project
#
# Usage: ./setup-drizzle.sh [--dialect postgres|mysql|sqlite|turso]
#
# Detects package manager, installs dependencies, creates config and schema files.
# Run from your project root directory.

set -euo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}ℹ${NC} $*"; }
ok()    { echo -e "${GREEN}✓${NC} $*"; }
warn()  { echo -e "${YELLOW}⚠${NC} $*"; }
error() { echo -e "${RED}✗${NC} $*" >&2; }
die()   { error "$@"; exit 1; }

# --- Detect package manager ---
detect_pm() {
  if [ -f "bun.lockb" ] || [ -f "bun.lock" ]; then
    echo "bun"
  elif [ -f "pnpm-lock.yaml" ]; then
    echo "pnpm"
  elif [ -f "yarn.lock" ]; then
    echo "yarn"
  elif [ -f "package-lock.json" ]; then
    echo "npm"
  elif command -v bun &>/dev/null; then
    echo "bun"
  elif command -v pnpm &>/dev/null; then
    echo "pnpm"
  elif command -v yarn &>/dev/null; then
    echo "yarn"
  else
    echo "npm"
  fi
}

# --- Parse args ---
DIALECT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dialect)
      DIALECT="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 [--dialect postgres|mysql|sqlite|turso]"
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

# --- Pre-checks ---
[ -f "package.json" ] || die "No package.json found. Run from your project root."

PM=$(detect_pm)
info "Detected package manager: ${PM}"

# --- Choose dialect ---
if [ -z "$DIALECT" ]; then
  echo ""
  echo "Select database dialect:"
  echo "  1) postgresql"
  echo "  2) mysql"
  echo "  3) sqlite"
  echo "  4) turso (LibSQL)"
  echo ""
  read -rp "Choice [1-4]: " choice
  case "$choice" in
    1) DIALECT="postgresql" ;;
    2) DIALECT="mysql" ;;
    3) DIALECT="sqlite" ;;
    4) DIALECT="turso" ;;
    *) die "Invalid choice" ;;
  esac
fi

info "Using dialect: ${DIALECT}"

# --- Determine packages ---
DEPS="drizzle-orm"
DEV_DEPS="drizzle-kit"
DB_CONFIG_DIALECT="$DIALECT"
DRIVER_IMPORT=""
DRIZZLE_IMPORT=""
CLIENT_SETUP=""

case "$DIALECT" in
  postgresql|postgres)
    DEPS="$DEPS postgres"
    DB_CONFIG_DIALECT="postgresql"
    DRIVER_IMPORT="import postgres from 'postgres';"
    DRIZZLE_IMPORT="import { drizzle } from 'drizzle-orm/postgres-js';"
    CLIENT_SETUP="const client = postgres(process.env.DATABASE_URL!);
export const db = drizzle(client, { schema });"
    ;;
  mysql)
    DEPS="$DEPS mysql2"
    DB_CONFIG_DIALECT="mysql"
    DRIVER_IMPORT="import mysql from 'mysql2/promise';"
    DRIZZLE_IMPORT="import { drizzle } from 'drizzle-orm/mysql2';"
    CLIENT_SETUP="const pool = await mysql.createPool(process.env.DATABASE_URL!);
export const db = drizzle(pool, { schema });"
    ;;
  sqlite)
    DEPS="$DEPS better-sqlite3"
    DEV_DEPS="$DEV_DEPS @types/better-sqlite3"
    DB_CONFIG_DIALECT="sqlite"
    DRIVER_IMPORT="import Database from 'better-sqlite3';"
    DRIZZLE_IMPORT="import { drizzle } from 'drizzle-orm/better-sqlite3';"
    CLIENT_SETUP="const sqlite = new Database(process.env.DATABASE_URL ?? 'local.db');
export const db = drizzle(sqlite, { schema });"
    ;;
  turso|libsql)
    DEPS="$DEPS @libsql/client"
    DB_CONFIG_DIALECT="turso"
    DRIVER_IMPORT="import { createClient } from '@libsql/client';"
    DRIZZLE_IMPORT="import { drizzle } from 'drizzle-orm/libsql';"
    CLIENT_SETUP="const client = createClient({
  url: process.env.TURSO_DATABASE_URL!,
  authToken: process.env.TURSO_AUTH_TOKEN!,
});
export const db = drizzle(client, { schema });"
    ;;
  *)
    die "Unsupported dialect: $DIALECT"
    ;;
esac

# --- Install dependencies ---
info "Installing dependencies..."

install_cmd() {
  case "$PM" in
    bun)  echo "bun add" ;;
    pnpm) echo "pnpm add" ;;
    yarn) echo "yarn add" ;;
    npm)  echo "npm install" ;;
  esac
}

install_dev_cmd() {
  case "$PM" in
    bun)  echo "bun add -d" ;;
    pnpm) echo "pnpm add -D" ;;
    yarn) echo "yarn add -D" ;;
    npm)  echo "npm install -D" ;;
  esac
}

eval "$(install_cmd) $DEPS"
eval "$(install_dev_cmd) $DEV_DEPS"
ok "Dependencies installed"

# --- Create directory structure ---
SCHEMA_DIR="src/db"
MIGRATIONS_DIR="drizzle"

mkdir -p "$SCHEMA_DIR"
mkdir -p "$MIGRATIONS_DIR"
ok "Created directories: ${SCHEMA_DIR}/, ${MIGRATIONS_DIR}/"

# --- Create drizzle.config.ts ---
if [ ! -f "drizzle.config.ts" ]; then
  cat > drizzle.config.ts << EOF
import { defineConfig } from 'drizzle-kit';

export default defineConfig({
  schema: './${SCHEMA_DIR}/schema.ts',
  out: './${MIGRATIONS_DIR}',
  dialect: '${DB_CONFIG_DIALECT}',
  dbCredentials: {
    url: process.env.DATABASE_URL!,
  },
});
EOF
  ok "Created drizzle.config.ts"
else
  warn "drizzle.config.ts already exists — skipped"
fi

# --- Create schema file ---
SCHEMA_FILE="${SCHEMA_DIR}/schema.ts"
if [ ! -f "$SCHEMA_FILE" ]; then
  case "$DIALECT" in
    postgresql|postgres)
      cat > "$SCHEMA_FILE" << 'EOF'
import { pgTable, serial, text, timestamp, boolean, varchar, integer, index } from 'drizzle-orm/pg-core';
import { relations } from 'drizzle-orm';

export const users = pgTable('users', {
  id: serial('id').primaryKey(),
  name: text('name').notNull(),
  email: varchar('email', { length: 255 }).notNull().unique(),
  createdAt: timestamp('created_at').defaultNow().notNull(),
  isActive: boolean('is_active').default(true),
});

export const posts = pgTable('posts', {
  id: serial('id').primaryKey(),
  title: text('title').notNull(),
  content: text('content'),
  published: boolean('published').default(false),
  authorId: integer('author_id').references(() => users.id, { onDelete: 'cascade' }).notNull(),
  createdAt: timestamp('created_at').defaultNow().notNull(),
}, (table) => [
  index('posts_author_idx').on(table.authorId),
]);

export const usersRelations = relations(users, ({ many }) => ({
  posts: many(posts),
}));

export const postsRelations = relations(posts, ({ one }) => ({
  author: one(users, { fields: [posts.authorId], references: [users.id] }),
}));
EOF
      ;;
    mysql)
      cat > "$SCHEMA_FILE" << 'EOF'
import { mysqlTable, serial, varchar, text, timestamp, boolean, int, index } from 'drizzle-orm/mysql-core';
import { relations } from 'drizzle-orm';

export const users = mysqlTable('users', {
  id: serial('id').primaryKey(),
  name: varchar('name', { length: 255 }).notNull(),
  email: varchar('email', { length: 255 }).notNull().unique(),
  createdAt: timestamp('created_at').defaultNow().notNull(),
  isActive: boolean('is_active').default(true),
});

export const posts = mysqlTable('posts', {
  id: serial('id').primaryKey(),
  title: varchar('title', { length: 255 }).notNull(),
  content: text('content'),
  published: boolean('published').default(false),
  authorId: int('author_id').references(() => users.id).notNull(),
  createdAt: timestamp('created_at').defaultNow().notNull(),
}, (table) => [
  index('posts_author_idx').on(table.authorId),
]);

export const usersRelations = relations(users, ({ many }) => ({
  posts: many(posts),
}));

export const postsRelations = relations(posts, ({ one }) => ({
  author: one(users, { fields: [posts.authorId], references: [users.id] }),
}));
EOF
      ;;
    sqlite|turso|libsql)
      cat > "$SCHEMA_FILE" << 'EOF'
import { sqliteTable, integer, text } from 'drizzle-orm/sqlite-core';
import { relations, sql } from 'drizzle-orm';

export const users = sqliteTable('users', {
  id: integer('id').primaryKey({ autoIncrement: true }),
  name: text('name').notNull(),
  email: text('email').notNull().unique(),
  createdAt: text('created_at').default(sql`(current_timestamp)`).notNull(),
  isActive: integer('is_active', { mode: 'boolean' }).default(true),
});

export const posts = sqliteTable('posts', {
  id: integer('id').primaryKey({ autoIncrement: true }),
  title: text('title').notNull(),
  content: text('content'),
  published: integer('published', { mode: 'boolean' }).default(false),
  authorId: integer('author_id').references(() => users.id, { onDelete: 'cascade' }).notNull(),
  createdAt: text('created_at').default(sql`(current_timestamp)`).notNull(),
});

export const usersRelations = relations(users, ({ many }) => ({
  posts: many(posts),
}));

export const postsRelations = relations(posts, ({ one }) => ({
  author: one(users, { fields: [posts.authorId], references: [users.id] }),
}));
EOF
      ;;
  esac
  ok "Created ${SCHEMA_FILE}"
else
  warn "${SCHEMA_FILE} already exists — skipped"
fi

# --- Create db client file ---
CLIENT_FILE="${SCHEMA_DIR}/index.ts"
if [ ! -f "$CLIENT_FILE" ]; then
  cat > "$CLIENT_FILE" << EOF
${DRIZZLE_IMPORT}
${DRIVER_IMPORT}
import * as schema from './schema';

${CLIENT_SETUP}
EOF
  ok "Created ${CLIENT_FILE}"
else
  warn "${CLIENT_FILE} already exists — skipped"
fi

# --- Create .env.example ---
if [ ! -f ".env.example" ]; then
  case "$DIALECT" in
    postgresql|postgres)
      echo "DATABASE_URL=postgresql://user:password@localhost:5432/mydb" > .env.example
      ;;
    mysql)
      echo "DATABASE_URL=mysql://user:password@localhost:3306/mydb" > .env.example
      ;;
    sqlite)
      echo "DATABASE_URL=local.db" > .env.example
      ;;
    turso|libsql)
      cat > .env.example << 'EOF'
TURSO_DATABASE_URL=libsql://your-db.turso.io
TURSO_AUTH_TOKEN=your-auth-token
EOF
      ;;
  esac
  ok "Created .env.example"
fi

# --- Add scripts to package.json ---
info "Add these scripts to your package.json:"
echo ""
echo '  "db:generate": "drizzle-kit generate",'
echo '  "db:migrate":  "drizzle-kit migrate",'
echo '  "db:push":     "drizzle-kit push",'
echo '  "db:pull":     "drizzle-kit pull",'
echo '  "db:studio":   "drizzle-kit studio"'
echo ""

# --- Summary ---
echo ""
echo -e "${GREEN}═══════════════════════════════════════${NC}"
echo -e "${GREEN}  Drizzle ORM setup complete!${NC}"
echo -e "${GREEN}═══════════════════════════════════════${NC}"
echo ""
echo "  Dialect:    ${DIALECT}"
echo "  Schema:     ${SCHEMA_FILE}"
echo "  Client:     ${CLIENT_FILE}"
echo "  Config:     drizzle.config.ts"
echo "  Migrations: ${MIGRATIONS_DIR}/"
echo ""
echo "Next steps:"
echo "  1. Copy .env.example to .env and set your DATABASE_URL"
echo "  2. Edit ${SCHEMA_FILE} to define your tables"
echo "  3. Run: npx drizzle-kit push   (for dev)"
echo "  4. Run: npx drizzle-kit studio (to browse data)"
echo ""
