#!/usr/bin/env bash
# ==============================================================================
# init-prisma.sh — Initialize Prisma ORM in an existing Node.js/TypeScript project
#
# Usage:
#   ./init-prisma.sh                          # defaults: postgresql, prisma/schema.prisma
#   ./init-prisma.sh mysql                    # use mysql provider
#   ./init-prisma.sh postgresql myapp         # custom migration name
#   DB_URL="postgresql://..." ./init-prisma.sh  # override DATABASE_URL
#
# What it does:
#   1. Installs prisma + @prisma/client
#   2. Initializes prisma with chosen datasource provider
#   3. Configures DATABASE_URL in .env
#   4. Generates Prisma Client
#   5. Creates and applies initial migration
# ==============================================================================

set -euo pipefail

PROVIDER="${1:-postgresql}"
MIGRATION_NAME="${2:-init}"

VALID_PROVIDERS="postgresql mysql sqlite sqlserver mongodb cockroachdb"
if ! echo "$VALID_PROVIDERS" | grep -qw "$PROVIDER"; then
  echo "❌ Invalid provider: $PROVIDER"
  echo "   Valid providers: $VALID_PROVIDERS"
  exit 1
fi

echo "🔧 Initializing Prisma with provider: $PROVIDER"

# --- Step 1: Install dependencies ---
if [ -f "package.json" ]; then
  echo "📦 Installing prisma and @prisma/client..."
  npm install prisma --save-dev --quiet
  npm install @prisma/client --quiet
else
  echo "❌ No package.json found. Run 'npm init -y' first."
  exit 1
fi

# --- Step 2: Initialize Prisma ---
if [ -d "prisma" ] && [ -f "prisma/schema.prisma" ]; then
  echo "⚠️  prisma/schema.prisma already exists — skipping init."
else
  echo "🏗️  Running prisma init..."
  npx prisma init --datasource-provider "$PROVIDER"
fi

# --- Step 3: Configure DATABASE_URL ---
DEFAULT_URLS=(
  ["postgresql"]="postgresql://user:password@localhost:5432/mydb?schema=public"
  ["mysql"]="mysql://user:password@localhost:3306/mydb"
  ["sqlite"]="file:./dev.db"
  ["sqlserver"]="sqlserver://localhost:1433;database=mydb;user=sa;password=Password123"
  ["mongodb"]="mongodb://localhost:27017/mydb"
  ["cockroachdb"]="postgresql://root@localhost:26257/mydb?sslmode=disable"
)

if [ -n "${DB_URL:-}" ]; then
  echo "🔗 Setting DATABASE_URL from environment..."
  if [ -f ".env" ]; then
    # Replace existing DATABASE_URL or append
    if grep -q "^DATABASE_URL=" .env; then
      sed -i "s|^DATABASE_URL=.*|DATABASE_URL=\"$DB_URL\"|" .env
    else
      echo "DATABASE_URL=\"$DB_URL\"" >> .env
    fi
  else
    echo "DATABASE_URL=\"$DB_URL\"" > .env
  fi
fi

echo ""
echo "📄 Current .env DATABASE_URL:"
grep "DATABASE_URL" .env 2>/dev/null || echo "   (not set — edit .env manually)"
echo ""

# --- Step 4: Generate Prisma Client ---
echo "⚙️  Generating Prisma Client..."
npx prisma generate

# --- Step 5: Create initial migration (skip for MongoDB) ---
if [ "$PROVIDER" = "mongodb" ]; then
  echo "📌 MongoDB detected — using 'db push' instead of migrations."
  echo "   Run: npx prisma db push"
elif [ "$PROVIDER" = "sqlite" ]; then
  echo "🗄️  SQLite detected — creating initial migration..."
  npx prisma migrate dev --name "$MIGRATION_NAME" 2>/dev/null || {
    echo "⚠️  Migration skipped — update schema.prisma with models first, then run:"
    echo "   npx prisma migrate dev --name $MIGRATION_NAME"
  }
else
  echo "📋 To create your initial migration after adding models:"
  echo "   npx prisma migrate dev --name $MIGRATION_NAME"
  echo ""
  echo "   Make sure DATABASE_URL in .env is correct first!"
fi

# --- Step 6: Add seed script hint ---
echo ""
echo "🌱 To set up seeding, add to package.json:"
echo '   "prisma": { "seed": "tsx prisma/seed.ts" }'
echo ""

# --- Step 7: Add prisma to .gitignore if needed ---
if [ -f ".gitignore" ]; then
  if ! grep -q "node_modules" .gitignore; then
    echo "node_modules/" >> .gitignore
  fi
  # Never commit .env with DB credentials
  if ! grep -q "^\.env$" .gitignore; then
    echo ".env" >> .gitignore
    echo "📝 Added .env to .gitignore"
  fi
fi

echo "✅ Prisma initialized! Next steps:"
echo "   1. Edit prisma/schema.prisma — add your models"
echo "   2. Set DATABASE_URL in .env"
echo "   3. Run: npx prisma migrate dev --name init"
echo "   4. Run: npx prisma generate"
