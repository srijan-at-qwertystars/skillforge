#!/usr/bin/env bash
# nextjs-init.sh — Scaffold a Next.js 15 App Router project
# Usage: ./nextjs-init.sh <project-name>
# Creates a Next.js 15 project with TypeScript, Tailwind CSS, ESLint, and src/ directory.

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <project-name>"
  echo "Example: $0 my-app"
  exit 1
fi

PROJECT_NAME="$1"

if [ -d "$PROJECT_NAME" ]; then
  echo "Error: Directory '$PROJECT_NAME' already exists."
  exit 1
fi

echo "🚀 Creating Next.js 15 App Router project: $PROJECT_NAME"

# Create project with all recommended defaults
npx create-next-app@latest "$PROJECT_NAME" \
  --typescript \
  --tailwind \
  --eslint \
  --app \
  --src-dir \
  --import-alias "@/*" \
  --use-npm \
  --turbopack

cd "$PROJECT_NAME"

# Install common production dependencies
echo "📦 Installing additional dependencies..."
npm install --save zod server-only

# Install common dev dependencies
npm install --save-dev @types/node prettier

# Create base project structure
echo "📁 Creating project structure..."
mkdir -p src/lib
mkdir -p src/components/ui
mkdir -p src/app/api/health

# Add health check endpoint
cat > src/app/api/health/route.ts << 'ROUTE'
export const dynamic = "force-dynamic";

export async function GET() {
  return Response.json({
    status: "healthy",
    timestamp: new Date().toISOString(),
  });
}
ROUTE

# Add a base utility file
cat > src/lib/utils.ts << 'UTILS'
import { type ClassValue, clsx } from "clsx";

export function cn(...inputs: ClassValue[]) {
  return inputs.filter(Boolean).join(" ");
}

export function formatDate(date: Date | string): string {
  return new Intl.DateTimeFormat("en-US", {
    month: "long",
    day: "numeric",
    year: "numeric",
  }).format(new Date(date));
}
UTILS

# Add .env.example
cat > .env.example << 'ENV'
# Server-only (not exposed to browser)
DATABASE_URL=
NEXTAUTH_SECRET=
NEXTAUTH_URL=http://localhost:3000

# Client-side (exposed to browser via NEXT_PUBLIC_ prefix)
NEXT_PUBLIC_APP_URL=http://localhost:3000
ENV

# Add prettier config
cat > .prettierrc << 'PRETTIER'
{
  "semi": true,
  "singleQuote": false,
  "tabWidth": 2,
  "trailingComma": "es5",
  "plugins": ["prettier-plugin-tailwindcss"]
}
PRETTIER

echo ""
echo "✅ Project '$PROJECT_NAME' created successfully!"
echo ""
echo "Next steps:"
echo "  cd $PROJECT_NAME"
echo "  npm run dev"
echo ""
echo "Project structure:"
echo "  src/app/           — App Router pages and layouts"
echo "  src/components/    — React components"
echo "  src/lib/           — Utility functions and shared code"
echo "  src/app/api/       — API route handlers"
