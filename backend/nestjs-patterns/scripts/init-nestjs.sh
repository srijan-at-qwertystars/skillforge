#!/usr/bin/env bash
# =============================================================================
# init-nestjs.sh — Scaffold a NestJS project with common production packages
#
# Usage:
#   ./init-nestjs.sh <project-name> [--orm typeorm|prisma] [--pm npm|yarn|pnpm]
#
# Examples:
#   ./init-nestjs.sh my-api
#   ./init-nestjs.sh my-api --orm prisma --pm pnpm
#
# What it does:
#   1. Creates a new NestJS project using the Nest CLI
#   2. Installs common packages (config, validation, swagger, ORM)
#   3. Generates a recommended folder structure
#   4. Creates base configuration files (.env, docker-compose, etc.)
# =============================================================================

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
PROJECT_NAME=""
ORM="typeorm"
PM="npm"

# ── Parse arguments ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --orm)     ORM="$2"; shift 2 ;;
    --pm)      PM="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 <project-name> [--orm typeorm|prisma] [--pm npm|yarn|pnpm]"
      exit 0 ;;
    *)
      if [[ -z "$PROJECT_NAME" ]]; then
        PROJECT_NAME="$1"; shift
      else
        echo "Error: Unknown argument '$1'"; exit 1
      fi ;;
  esac
done

if [[ -z "$PROJECT_NAME" ]]; then
  echo "Error: Project name is required."
  echo "Usage: $0 <project-name> [--orm typeorm|prisma] [--pm npm|yarn|pnpm]"
  exit 1
fi

# ── Helper ────────────────────────────────────────────────────────────────────
install_cmd() {
  case "$PM" in
    yarn)  echo "yarn add" ;;
    pnpm)  echo "pnpm add" ;;
    *)     echo "npm install" ;;
  esac
}

install_dev_cmd() {
  case "$PM" in
    yarn)  echo "yarn add -D" ;;
    pnpm)  echo "pnpm add -D" ;;
    *)     echo "npm install -D" ;;
  esac
}

INSTALL=$(install_cmd)
INSTALL_DEV=$(install_dev_cmd)

echo "🚀 Creating NestJS project: $PROJECT_NAME (ORM: $ORM, PM: $PM)"

# ── Step 1: Scaffold project ─────────────────────────────────────────────────
if command -v nest &>/dev/null; then
  nest new "$PROJECT_NAME" --package-manager "$PM" --skip-git --strict
else
  npx @nestjs/cli new "$PROJECT_NAME" --package-manager "$PM" --skip-git --strict
fi

cd "$PROJECT_NAME"

# ── Step 2: Install common packages ──────────────────────────────────────────
echo "📦 Installing common packages..."

# Config & validation
$INSTALL @nestjs/config class-validator class-transformer

# Swagger / OpenAPI
$INSTALL @nestjs/swagger

# Health checks
$INSTALL @nestjs/terminus

# Throttling
$INSTALL @nestjs/throttler

# Authentication
$INSTALL @nestjs/passport @nestjs/jwt passport passport-jwt
$INSTALL_DEV @types/passport-jwt

# Logging
$INSTALL nest-winston winston

# Compression & security
$INSTALL compression helmet
$INSTALL_DEV @types/compression

# ORM-specific packages
if [[ "$ORM" == "prisma" ]]; then
  echo "📦 Installing Prisma..."
  $INSTALL @prisma/client
  $INSTALL_DEV prisma
  npx prisma init
elif [[ "$ORM" == "typeorm" ]]; then
  echo "📦 Installing TypeORM..."
  $INSTALL @nestjs/typeorm typeorm pg
fi

# Dev tools
$INSTALL_DEV @golevelup/ts-jest

# ── Step 3: Create folder structure ──────────────────────────────────────────
echo "📁 Creating folder structure..."

mkdir -p src/{common/{decorators,filters,guards,interceptors,pipes,middleware},config,database}
mkdir -p src/{auth,health,users/{dto,entities}}
mkdir -p test

# ── Step 4: Create base config files ─────────────────────────────────────────
echo "📝 Creating configuration files..."

# .env
cat > .env <<'EOF'
# Application
NODE_ENV=development
PORT=3000

# Database
DATABASE_URL=postgresql://postgres:postgres@localhost:5432/${PROJECT_NAME}
DB_HOST=localhost
DB_PORT=5432
DB_USERNAME=postgres
DB_PASSWORD=postgres
DB_NAME=${PROJECT_NAME}

# JWT
JWT_SECRET=change-me-in-production
JWT_EXPIRATION=1h

# Redis (optional)
REDIS_HOST=localhost
REDIS_PORT=6379

# CORS
CORS_ORIGIN=http://localhost:3000
EOF

# .env.example (safe to commit)
cp .env .env.example
sed -i 's/change-me-in-production/your-secret-here/g' .env.example

# Add .env to .gitignore if not already there
grep -qxF '.env' .gitignore 2>/dev/null || echo '.env' >> .gitignore

# Docker compose for local dev
cat > docker-compose.yml <<'EOF'
version: '3.8'
services:
  postgres:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: ${PROJECT_NAME}
    ports:
      - '5432:5432'
    volumes:
      - pgdata:/var/lib/postgresql/data

  redis:
    image: redis:7-alpine
    ports:
      - '6379:6379'

volumes:
  pgdata:
EOF

# Replace placeholder
sed -i "s/\${PROJECT_NAME}/$PROJECT_NAME/g" .env docker-compose.yml .env.example

echo ""
echo "✅ Project '$PROJECT_NAME' created successfully!"
echo ""
echo "Next steps:"
echo "  cd $PROJECT_NAME"
echo "  docker compose up -d          # Start Postgres + Redis"
if [[ "$ORM" == "prisma" ]]; then
  echo "  npx prisma migrate dev        # Run migrations"
else
  echo "  npm run migration:run         # Run migrations (after creating them)"
fi
echo "  $PM run start:dev              # Start dev server"
echo ""
echo "Project structure:"
find src -type d | head -20 | sed 's/^/  /'
