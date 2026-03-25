#!/usr/bin/env bash
# init-drizzle.sh — Set up Drizzle ORM in an existing Node.js/Bun project
#
# Usage:
#   ./init-drizzle.sh [--dialect pg|mysql|sqlite|turso] [--driver pg|postgres|mysql2|better-sqlite3|libsql|bun-sqlite]
#
# What it does:
#   1. Installs drizzle-orm and drizzle-kit
#   2. Installs the appropriate database driver
#   3. Creates drizzle.config.ts
#   4. Creates initial schema file at src/db/schema.ts
#   5. Creates database client at src/db/index.ts
#
# Examples:
#   ./init-drizzle.sh --dialect pg --driver postgres
#   ./init-drizzle.sh --dialect sqlite --driver better-sqlite3
#   ./init-drizzle.sh --dialect turso --driver libsql

set -euo pipefail

# ─── Defaults ───────────────────────────────────────────────────────────────────
DIALECT=""
DRIVER=""
PKG_MANAGER="npm"

# ─── Parse args ─────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dialect) DIALECT="$2"; shift 2 ;;
    --driver)  DRIVER="$2";  shift 2 ;;
    --pm)      PKG_MANAGER="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--dialect pg|mysql|sqlite|turso] [--driver pg|postgres|mysql2|better-sqlite3|libsql|bun-sqlite] [--pm npm|pnpm|yarn|bun]"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ─── Detect package manager ────────────────────────────────────────────────────
if [ -z "$PKG_MANAGER" ] || [ "$PKG_MANAGER" = "npm" ]; then
  if [ -f "bun.lockb" ]; then PKG_MANAGER="bun"
  elif [ -f "pnpm-lock.yaml" ]; then PKG_MANAGER="pnpm"
  elif [ -f "yarn.lock" ]; then PKG_MANAGER="yarn"
  else PKG_MANAGER="npm"
  fi
fi

install_cmd() {
  local dev_flag=""
  case "$PKG_MANAGER" in
    npm)  dev_flag="-D"; [ "${2:-}" != "dev" ] && dev_flag="" ;;
    pnpm) dev_flag="-D"; [ "${2:-}" != "dev" ] && dev_flag="" ;;
    yarn) dev_flag="--dev"; [ "${2:-}" != "dev" ] && dev_flag="" ;;
    bun)  dev_flag="-d"; [ "${2:-}" != "dev" ] && dev_flag="" ;;
  esac
  $PKG_MANAGER ${PKG_MANAGER == "npm" && echo "install" || echo "add"} $dev_flag "$1"
}

# ─── Interactive selection if not provided ──────────────────────────────────────
if [ -z "$DIALECT" ]; then
  echo "Select database dialect:"
  echo "  1) postgresql"
  echo "  2) mysql"
  echo "  3) sqlite"
  echo "  4) turso"
  read -rp "Choice [1-4]: " choice
  case "$choice" in
    1) DIALECT="postgresql" ;;
    2) DIALECT="mysql" ;;
    3) DIALECT="sqlite" ;;
    4) DIALECT="turso" ;;
    *) echo "Invalid choice"; exit 1 ;;
  esac
fi

# Normalize dialect name
case "$DIALECT" in
  pg|postgres|postgresql) DIALECT="postgresql" ;;
  mysql)                  DIALECT="mysql" ;;
  sqlite)                 DIALECT="sqlite" ;;
  turso|libsql)           DIALECT="turso" ;;
  *) echo "Unknown dialect: $DIALECT"; exit 1 ;;
esac

# ─── Set default driver if not provided ─────────────────────────────────────────
if [ -z "$DRIVER" ]; then
  case "$DIALECT" in
    postgresql) DRIVER="pg" ;;
    mysql)      DRIVER="mysql2" ;;
    sqlite)     DRIVER="better-sqlite3" ;;
    turso)      DRIVER="libsql" ;;
  esac
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Drizzle ORM Setup"
echo "  Dialect: $DIALECT"
echo "  Driver:  $DRIVER"
echo "  PM:      $PKG_MANAGER"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ─── Install dependencies ──────────────────────────────────────────────────────
echo ""
echo "📦 Installing drizzle-orm..."
$PKG_MANAGER add drizzle-orm

echo "📦 Installing drizzle-kit (dev)..."
$PKG_MANAGER add -D drizzle-kit

echo "📦 Installing driver: $DRIVER..."
case "$DRIVER" in
  pg)
    $PKG_MANAGER add pg
    $PKG_MANAGER add -D @types/pg
    ;;
  postgres)
    $PKG_MANAGER add postgres
    ;;
  mysql2)
    $PKG_MANAGER add mysql2
    ;;
  better-sqlite3)
    $PKG_MANAGER add better-sqlite3
    $PKG_MANAGER add -D @types/better-sqlite3
    ;;
  libsql)
    $PKG_MANAGER add @libsql/client
    ;;
  bun-sqlite)
    echo "  (bun:sqlite is built-in, no install needed)"
    ;;
  *)
    echo "Unknown driver: $DRIVER"
    exit 1
    ;;
esac

# ─── Create directory structure ─────────────────────────────────────────────────
mkdir -p src/db
mkdir -p drizzle

# ─── Generate drizzle.config.ts ─────────────────────────────────────────────────
if [ ! -f "drizzle.config.ts" ]; then
  echo "📝 Creating drizzle.config.ts..."

  DB_CREDS=""
  case "$DIALECT" in
    turso)
      DB_CREDS="    url: process.env.TURSO_DATABASE_URL!,
    authToken: process.env.TURSO_AUTH_TOKEN,"
      ;;
    *)
      DB_CREDS="    url: process.env.DATABASE_URL!,"
      ;;
  esac

  cat > drizzle.config.ts <<EOF
import { defineConfig } from 'drizzle-kit';

export default defineConfig({
  dialect: '${DIALECT}',
  schema: './src/db/schema.ts',
  out: './drizzle',
  dbCredentials: {
${DB_CREDS}
  },
  verbose: true,
  strict: true,
});
EOF
else
  echo "⏭️  drizzle.config.ts already exists, skipping"
fi

# ─── Generate schema file ──────────────────────────────────────────────────────
if [ ! -f "src/db/schema.ts" ]; then
  echo "📝 Creating src/db/schema.ts..."

  case "$DIALECT" in
    postgresql)
      cat > src/db/schema.ts <<'EOF'
import { pgTable, serial, text, varchar, boolean, timestamp, integer, index } from 'drizzle-orm/pg-core';
import { relations } from 'drizzle-orm';

export const users = pgTable('users', {
  id: serial('id').primaryKey(),
  name: text('name').notNull(),
  email: varchar('email', { length: 320 }).notNull().unique(),
  isActive: boolean('is_active').default(true),
  createdAt: timestamp('created_at').defaultNow().notNull(),
  updatedAt: timestamp('updated_at').defaultNow().notNull().$onUpdate(() => new Date()),
}, (t) => [
  index('users_email_idx').on(t.email),
]);

export const posts = pgTable('posts', {
  id: serial('id').primaryKey(),
  title: text('title').notNull(),
  content: text('content'),
  authorId: integer('author_id').notNull().references(() => users.id),
  createdAt: timestamp('created_at').defaultNow().notNull(),
}, (t) => [
  index('posts_author_idx').on(t.authorId),
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
      cat > src/db/schema.ts <<'EOF'
import { mysqlTable, serial, int, varchar, boolean, timestamp, text, index } from 'drizzle-orm/mysql-core';
import { relations } from 'drizzle-orm';

export const users = mysqlTable('users', {
  id: serial('id').primaryKey(),
  name: varchar('name', { length: 255 }).notNull(),
  email: varchar('email', { length: 320 }).notNull().unique(),
  isActive: boolean('is_active').default(true),
  createdAt: timestamp('created_at').defaultNow().notNull(),
  updatedAt: timestamp('updated_at').defaultNow().notNull().$onUpdate(() => new Date()),
}, (t) => [index('users_email_idx').on(t.email)]);

export const posts = mysqlTable('posts', {
  id: serial('id').primaryKey(),
  title: varchar('title', { length: 255 }).notNull(),
  content: text('content'),
  authorId: int('author_id').notNull().references(() => users.id),
  createdAt: timestamp('created_at').defaultNow().notNull(),
}, (t) => [index('posts_author_idx').on(t.authorId)]);

export const usersRelations = relations(users, ({ many }) => ({
  posts: many(posts),
}));

export const postsRelations = relations(posts, ({ one }) => ({
  author: one(users, { fields: [posts.authorId], references: [users.id] }),
}));
EOF
      ;;
    sqlite|turso)
      cat > src/db/schema.ts <<'EOF'
import { sqliteTable, integer, text, index } from 'drizzle-orm/sqlite-core';
import { relations } from 'drizzle-orm';

export const users = sqliteTable('users', {
  id: integer('id').primaryKey({ autoIncrement: true }),
  name: text('name').notNull(),
  email: text('email').notNull().unique(),
  isActive: integer('is_active', { mode: 'boolean' }).default(true),
  createdAt: integer('created_at', { mode: 'timestamp' }).$defaultFn(() => new Date()),
  updatedAt: integer('updated_at', { mode: 'timestamp' }).$defaultFn(() => new Date()).$onUpdate(() => new Date()),
}, (t) => [index('users_email_idx').on(t.email)]);

export const posts = sqliteTable('posts', {
  id: integer('id').primaryKey({ autoIncrement: true }),
  title: text('title').notNull(),
  content: text('content'),
  authorId: integer('author_id').notNull().references(() => users.id),
  createdAt: integer('created_at', { mode: 'timestamp' }).$defaultFn(() => new Date()),
}, (t) => [index('posts_author_idx').on(t.authorId)]);

export const usersRelations = relations(users, ({ many }) => ({
  posts: many(posts),
}));

export const postsRelations = relations(posts, ({ one }) => ({
  author: one(users, { fields: [posts.authorId], references: [users.id] }),
}));
EOF
      ;;
  esac
else
  echo "⏭️  src/db/schema.ts already exists, skipping"
fi

# ─── Generate db client ────────────────────────────────────────────────────────
if [ ! -f "src/db/index.ts" ]; then
  echo "📝 Creating src/db/index.ts..."

  case "$DRIVER" in
    pg)
      cat > src/db/index.ts <<'EOF'
import { drizzle } from 'drizzle-orm/node-postgres';
import { Pool } from 'pg';
import * as schema from './schema';

const pool = new Pool({
  connectionString: process.env.DATABASE_URL!,
  max: 20,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 5000,
});

export const db = drizzle(pool, { schema });
EOF
      ;;
    postgres)
      cat > src/db/index.ts <<'EOF'
import { drizzle } from 'drizzle-orm/postgres-js';
import postgres from 'postgres';
import * as schema from './schema';

const client = postgres(process.env.DATABASE_URL!, {
  max: 10,
  idle_timeout: 20,
});

export const db = drizzle(client, { schema });
EOF
      ;;
    mysql2)
      cat > src/db/index.ts <<'EOF'
import { drizzle } from 'drizzle-orm/mysql2';
import mysql from 'mysql2/promise';
import * as schema from './schema';

const pool = mysql.createPool({
  uri: process.env.DATABASE_URL!,
  connectionLimit: 10,
  waitForConnections: true,
});

export const db = drizzle(pool, { schema, mode: 'default' });
EOF
      ;;
    better-sqlite3)
      cat > src/db/index.ts <<'EOF'
import { drizzle } from 'drizzle-orm/better-sqlite3';
import Database from 'better-sqlite3';
import * as schema from './schema';

const sqlite = new Database(process.env.DATABASE_URL ?? 'sqlite.db');
sqlite.pragma('journal_mode = WAL');

export const db = drizzle(sqlite, { schema });
EOF
      ;;
    bun-sqlite)
      cat > src/db/index.ts <<'EOF'
import { drizzle } from 'drizzle-orm/bun-sqlite';
import { Database } from 'bun:sqlite';
import * as schema from './schema';

const sqlite = new Database(process.env.DATABASE_URL ?? 'sqlite.db');

export const db = drizzle(sqlite, { schema });
EOF
      ;;
    libsql)
      cat > src/db/index.ts <<'EOF'
import { drizzle } from 'drizzle-orm/libsql';
import { createClient } from '@libsql/client';
import * as schema from './schema';

const client = createClient({
  url: process.env.TURSO_DATABASE_URL!,
  authToken: process.env.TURSO_AUTH_TOKEN,
});

export const db = drizzle(client, { schema });
EOF
      ;;
  esac
else
  echo "⏭️  src/db/index.ts already exists, skipping"
fi

# ─── Add scripts to package.json ────────────────────────────────────────────────
if command -v node &>/dev/null && [ -f "package.json" ]; then
  echo "📝 Adding drizzle scripts to package.json..."
  node -e "
    const pkg = require('./package.json');
    pkg.scripts = pkg.scripts || {};
    pkg.scripts['db:generate'] = pkg.scripts['db:generate'] || 'drizzle-kit generate';
    pkg.scripts['db:migrate']  = pkg.scripts['db:migrate']  || 'drizzle-kit migrate';
    pkg.scripts['db:push']     = pkg.scripts['db:push']     || 'drizzle-kit push';
    pkg.scripts['db:pull']     = pkg.scripts['db:pull']     || 'drizzle-kit pull';
    pkg.scripts['db:studio']   = pkg.scripts['db:studio']   || 'drizzle-kit studio';
    require('fs').writeFileSync('package.json', JSON.stringify(pkg, null, 2) + '\n');
  "
fi

# ─── Add DATABASE_URL to .env.example ───────────────────────────────────────────
if [ ! -f ".env.example" ]; then
  echo "📝 Creating .env.example..."
  case "$DIALECT" in
    postgresql) echo "DATABASE_URL=postgresql://user:password@localhost:5432/mydb" > .env.example ;;
    mysql)      echo "DATABASE_URL=mysql://user:password@localhost:3306/mydb" > .env.example ;;
    sqlite)     echo "DATABASE_URL=sqlite.db" > .env.example ;;
    turso)
      cat > .env.example <<'EOF'
TURSO_DATABASE_URL=libsql://your-db.turso.io
TURSO_AUTH_TOKEN=your-token
EOF
      ;;
  esac
fi

echo ""
echo "✅ Drizzle ORM setup complete!"
echo ""
echo "Next steps:"
echo "  1. Set DATABASE_URL in your .env file"
echo "  2. Edit src/db/schema.ts with your tables"
echo "  3. Run: npx drizzle-kit push    (dev — apply schema directly)"
echo "  4. Run: npx drizzle-kit generate (prod — create migration files)"
echo "  5. Run: npx drizzle-kit studio   (browse data visually)"
