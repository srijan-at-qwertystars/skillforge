#!/usr/bin/env bash
#
# setup-project.sh — Bootstrap a new Bun project with TypeScript, testing, and recommended config.
#
# Usage:
#   ./setup-project.sh <project-name> [--template api|lib|fullstack]
#
# Examples:
#   ./setup-project.sh my-api --template api
#   ./setup-project.sh my-lib --template lib
#   ./setup-project.sh my-app

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────
PROJECT_NAME=""
TEMPLATE="api"

# ── Parse arguments ──────────────────────────────────────────────
usage() {
  echo "Usage: $0 <project-name> [--template api|lib|fullstack]"
  echo ""
  echo "Templates:"
  echo "  api        — HTTP server with Bun.serve, SQLite, testing (default)"
  echo "  lib        — Library with bundler config, exports, testing"
  echo "  fullstack  — Monorepo with apps/ and packages/"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --template)
      TEMPLATE="${2:-api}"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      if [[ -z "$PROJECT_NAME" ]]; then
        PROJECT_NAME="$1"
      else
        echo "Error: unexpected argument '$1'"
        usage
      fi
      shift
      ;;
  esac
done

if [[ -z "$PROJECT_NAME" ]]; then
  echo "Error: project name is required"
  usage
fi

# ── Check Bun is installed ───────────────────────────────────────
if ! command -v bun &>/dev/null; then
  echo "Error: bun is not installed. Install with: curl -fsSL https://bun.sh/install | bash"
  exit 1
fi

echo "🥟 Creating Bun project: $PROJECT_NAME (template: $TEMPLATE)"

# ── Create project directory ─────────────────────────────────────
mkdir -p "$PROJECT_NAME"
cd "$PROJECT_NAME"

# ── Initialize package.json ──────────────────────────────────────
cat > package.json <<EOF
{
  "name": "$PROJECT_NAME",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "bun --watch src/index.ts",
    "start": "bun run src/index.ts",
    "build": "bun build ./src/index.ts --outdir ./dist --target bun --minify",
    "test": "bun test",
    "test:watch": "bun test --watch",
    "test:coverage": "bun test --coverage",
    "lint": "bun run eslint src/",
    "typecheck": "bun run tsc --noEmit",
    "clean": "rm -rf dist node_modules"
  }
}
EOF

# ── TypeScript config ────────────────────────────────────────────
cat > tsconfig.json <<EOF
{
  "compilerOptions": {
    "target": "ESNext",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "types": ["@types/bun"],
    "strict": true,
    "skipLibCheck": true,
    "noEmit": true,
    "esModuleInterop": true,
    "resolveJsonModule": true,
    "isolatedModules": true,
    "forceConsistentCasingInFileNames": true,
    "outDir": "./dist",
    "rootDir": "./src"
  },
  "include": ["src/**/*", "tests/**/*"],
  "exclude": ["node_modules", "dist"]
}
EOF

# ── bunfig.toml ──────────────────────────────────────────────────
cat > bunfig.toml <<'EOF'
[test]
coverage = true
coverageReporter = ["text", "lcov"]

[run]
shell = "bun"
EOF

# ── .gitignore ───────────────────────────────────────────────────
cat > .gitignore <<'EOF'
node_modules/
dist/
*.db
*.db-wal
*.db-shm
.env.local
.env.*.local
coverage/
*.heapsnapshot
EOF

# ── .env example ─────────────────────────────────────────────────
cat > .env.example <<'EOF'
PORT=3000
DATABASE_URL=./data/app.db
NODE_ENV=development
EOF

cp .env.example .env

# ── Create directory structure ───────────────────────────────────
mkdir -p src tests

# ── Template-specific files ──────────────────────────────────────
case "$TEMPLATE" in
  api)
    cat > src/index.ts <<'SRCEOF'
const server = Bun.serve({
  port: Number(Bun.env.PORT) || 3000,
  fetch(req) {
    const url = new URL(req.url);
    if (url.pathname === "/") return Response.json({ status: "ok" });
    if (url.pathname === "/health") return Response.json({ uptime: process.uptime() });
    return new Response("Not Found", { status: 404 });
  },
});

console.log(`🚀 Server running at ${server.url}`);
SRCEOF

    cat > tests/index.test.ts <<'TESTEOF'
import { describe, test, expect } from "bun:test";

describe("server", () => {
  test("responds to health check", async () => {
    const port = Number(Bun.env.PORT) || 3000;
    const res = await fetch(`http://localhost:${port}/health`);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body).toHaveProperty("uptime");
  });
});
TESTEOF
    ;;

  lib)
    cat > src/index.ts <<'SRCEOF'
export function greet(name: string): string {
  return `Hello, ${name}!`;
}
SRCEOF

    cat > tests/index.test.ts <<'TESTEOF'
import { describe, test, expect } from "bun:test";
import { greet } from "../src/index";

describe("greet", () => {
  test("returns greeting", () => {
    expect(greet("World")).toBe("Hello, World!");
  });
});
TESTEOF

    # Update package.json for library
    cat > package.json <<EOF
{
  "name": "$PROJECT_NAME",
  "version": "0.1.0",
  "type": "module",
  "main": "dist/index.js",
  "types": "dist/index.d.ts",
  "exports": {
    ".": {
      "import": "./dist/index.js",
      "types": "./dist/index.d.ts"
    }
  },
  "scripts": {
    "build": "bun build ./src/index.ts --outdir ./dist --target bun",
    "test": "bun test",
    "test:watch": "bun test --watch",
    "prepublishOnly": "bun run build"
  }
}
EOF
    ;;

  fullstack)
    rm -f src/.gitkeep tests/.gitkeep
    rmdir src tests 2>/dev/null || true
    mkdir -p apps/api/src apps/web/src packages/shared/src

    cat > package.json <<EOF
{
  "private": true,
  "workspaces": ["apps/*", "packages/*"],
  "scripts": {
    "dev": "bun --filter '*' dev",
    "test": "bun --filter '*' test",
    "build": "bun --filter '*' build"
  }
}
EOF

    cat > apps/api/package.json <<EOF
{
  "name": "@$PROJECT_NAME/api",
  "private": true,
  "dependencies": { "@$PROJECT_NAME/shared": "workspace:*" },
  "scripts": { "dev": "bun --watch src/index.ts", "test": "bun test" }
}
EOF

    cat > apps/api/src/index.ts <<'SRCEOF'
Bun.serve({
  port: 3001,
  fetch() { return Response.json({ api: true }); },
});
console.log("API running on :3001");
SRCEOF

    cat > packages/shared/package.json <<EOF
{
  "name": "@$PROJECT_NAME/shared",
  "version": "0.1.0",
  "main": "src/index.ts",
  "scripts": { "test": "bun test" }
}
EOF

    cat > packages/shared/src/index.ts <<'SRCEOF'
export const APP_NAME = "my-app";
SRCEOF
    ;;

  *)
    echo "Error: unknown template '$TEMPLATE'. Use: api, lib, or fullstack"
    exit 1
    ;;
esac

# ── Install dependencies ─────────────────────────────────────────
echo "📦 Installing dependencies..."
bun add -d @types/bun 2>/dev/null || echo "Warning: bun add failed (offline?). Run 'bun add -d @types/bun' manually."

echo ""
echo "✅ Project '$PROJECT_NAME' created successfully!"
echo ""
echo "Next steps:"
echo "  cd $PROJECT_NAME"
echo "  bun run dev"
echo ""
