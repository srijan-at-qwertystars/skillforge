#!/usr/bin/env bash
# =============================================================================
# init-project.sh — Initialize a new Prisma project with starter schema
#
# Usage:
#   ./init-project.sh <project-name> [database-provider]
#
# Arguments:
#   project-name       Name of the project directory to create
#   database-provider  One of: postgresql, mysql, sqlite, sqlserver, cockroachdb
#                      Default: postgresql
#
# Examples:
#   ./init-project.sh my-api
#   ./init-project.sh my-api mysql
#   ./init-project.sh my-api sqlite
#
# Creates:
#   - Node.js project with TypeScript
#   - Prisma + @prisma/client dependencies
#   - Starter schema with User/Post models
#   - Initial migration
#   - Generated Prisma Client
# =============================================================================
set -euo pipefail

PROJECT_NAME="${1:?Usage: $0 <project-name> [postgresql|mysql|sqlite|sqlserver|cockroachdb]}"
DB_PROVIDER="${2:-postgresql}"

# Validate provider
case "$DB_PROVIDER" in
  postgresql|mysql|sqlite|sqlserver|cockroachdb) ;;
  *) echo "Error: Invalid database provider '$DB_PROVIDER'"; echo "Valid: postgresql, mysql, sqlite, sqlserver, cockroachdb"; exit 1 ;;
esac

echo "🚀 Initializing Prisma project: $PROJECT_NAME (provider: $DB_PROVIDER)"

# Create project directory
mkdir -p "$PROJECT_NAME"
cd "$PROJECT_NAME"

# Initialize Node.js project
echo "📦 Initializing Node.js project..."
npm init -y --quiet

# Install dependencies
echo "📥 Installing dependencies..."
npm install --save-dev prisma typescript ts-node @types/node --quiet
npm install @prisma/client --quiet

# Initialize TypeScript
cat > tsconfig.json << 'TSCONFIG'
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "commonjs",
    "lib": ["ES2022"],
    "outDir": "./dist",
    "rootDir": "./src",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "forceConsistentCasingInFileNames": true,
    "resolveJsonModule": true,
    "declaration": true,
    "declarationMap": true,
    "sourceMap": true
  },
  "include": ["src/**/*"],
  "exclude": ["node_modules", "dist"]
}
TSCONFIG

# Initialize Prisma
echo "🔧 Initializing Prisma..."
npx prisma init --datasource-provider "$DB_PROVIDER" --quiet 2>/dev/null || npx prisma init --datasource-provider "$DB_PROVIDER"

# Write starter schema
cat > prisma/schema.prisma << SCHEMA
// Prisma Schema — $PROJECT_NAME
// Docs: https://pris.ly/d/prisma-schema

generator client {
  provider = "prisma-client-js"
}

datasource db {
  provider = "$DB_PROVIDER"
  url      = env("DATABASE_URL")
}

/// Application user
model User {
  id        Int      @id @default(autoincrement())
  email     String   @unique
  name      String?
  role      Role     @default(USER)
  posts     Post[]
  createdAt DateTime @default(now())
  updatedAt DateTime @updatedAt

  @@index([email])
  @@index([role])
  @@map("users")
}

/// Blog post
model Post {
  id        Int      @id @default(autoincrement())
  title     String
  content   String?
  published Boolean  @default(false)
  author    User     @relation(fields: [authorId], references: [id], onDelete: Cascade)
  authorId  Int
  createdAt DateTime @default(now())
  updatedAt DateTime @updatedAt

  @@index([authorId])
  @@index([published, createdAt(sort: Desc)])
  @@map("posts")
}

enum Role {
  USER
  ADMIN
  MODERATOR
}
SCHEMA

# Create src directory and singleton client
mkdir -p src
cat > src/db.ts << 'CLIENT'
import { PrismaClient } from '@prisma/client';

const globalForPrisma = globalThis as unknown as { prisma: PrismaClient };

export const prisma =
  globalForPrisma.prisma ??
  new PrismaClient({
    log: process.env.NODE_ENV === 'development' ? ['query', 'warn', 'error'] : ['error'],
  });

if (process.env.NODE_ENV !== 'production') {
  globalForPrisma.prisma = prisma;
}
CLIENT

# Create a simple main file
cat > src/index.ts << 'MAIN'
import { prisma } from './db';

async function main() {
  const userCount = await prisma.user.count();
  console.log(`Database connected. Users: ${userCount}`);
}

main()
  .catch(console.error)
  .finally(() => prisma.$disconnect());
MAIN

# Create seed file
mkdir -p prisma
cat > prisma/seed.ts << 'SEED'
import { PrismaClient } from '@prisma/client';

const prisma = new PrismaClient();

async function main() {
  const admin = await prisma.user.upsert({
    where: { email: 'admin@example.com' },
    update: {},
    create: {
      email: 'admin@example.com',
      name: 'Admin User',
      role: 'ADMIN',
      posts: {
        create: {
          title: 'Welcome Post',
          content: 'This is the first post.',
          published: true,
        },
      },
    },
  });

  console.log(`Seeded admin user: ${admin.email}`);
}

main()
  .catch(console.error)
  .finally(() => prisma.$disconnect());
SEED

# Update package.json with scripts and seed config
node -e "
const pkg = require('./package.json');
pkg.scripts = {
  ...pkg.scripts,
  'build': 'tsc',
  'start': 'node dist/index.js',
  'dev': 'ts-node src/index.ts',
  'db:generate': 'prisma generate',
  'db:migrate': 'prisma migrate dev',
  'db:push': 'prisma db push',
  'db:seed': 'prisma db seed',
  'db:studio': 'prisma studio',
  'db:reset': 'prisma migrate reset',
};
pkg.prisma = { seed: 'ts-node prisma/seed.ts' };
require('fs').writeFileSync('package.json', JSON.stringify(pkg, null, 2));
"

# Set up DATABASE_URL for SQLite if chosen
if [ "$DB_PROVIDER" = "sqlite" ]; then
  echo 'DATABASE_URL="file:./dev.db"' > .env
  echo "📊 Generating Prisma Client..."
  npx prisma generate --quiet 2>/dev/null || npx prisma generate
  echo "🗃️  Creating initial migration..."
  npx prisma migrate dev --name init --quiet 2>/dev/null || npx prisma migrate dev --name init
else
  echo ""
  echo "⚠️  Set DATABASE_URL in .env before running migrations."
  echo "📊 Generating Prisma Client..."
  npx prisma generate --quiet 2>/dev/null || npx prisma generate
fi

# Create .gitignore
cat > .gitignore << 'GITIGNORE'
node_modules/
dist/
.env
*.db
*.db-journal
GITIGNORE

echo ""
echo "✅ Project '$PROJECT_NAME' initialized!"
echo ""
echo "Next steps:"
if [ "$DB_PROVIDER" != "sqlite" ]; then
  echo "  1. Edit .env and set DATABASE_URL"
  echo "  2. Run: npm run db:migrate"
else
  echo "  1. Database is ready (SQLite)"
fi
echo "  2. Run: npm run dev"
echo "  3. Run: npm run db:studio    (browse data)"
echo ""
