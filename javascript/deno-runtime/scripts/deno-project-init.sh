#!/usr/bin/env bash
#
# deno-project-init.sh — Scaffold a new Deno 2.x project
#
# Usage:
#   ./deno-project-init.sh <project-name> [--fresh] [--oak] [--minimal]
#
# Options:
#   --fresh     Scaffold a Fresh framework project
#   --oak       Include Oak HTTP framework setup
#   --minimal   Minimal project (just deno.json + main.ts)
#
# Examples:
#   ./deno-project-init.sh my-api
#   ./deno-project-init.sh my-app --fresh
#   ./deno-project-init.sh my-service --oak
#   ./deno-project-init.sh my-lib --minimal
#

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log() { echo -e "${GREEN}✓${NC} $1"; }
info() { echo -e "${BLUE}→${NC} $1"; }
error() { echo -e "${RED}✗${NC} $1" >&2; exit 1; }

# Parse arguments
PROJECT_NAME="${1:-}"
TEMPLATE="standard"

if [[ -z "$PROJECT_NAME" ]]; then
  echo -e "${BOLD}Usage:${NC} $0 <project-name> [--fresh|--oak|--minimal]"
  exit 1
fi

shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --fresh)   TEMPLATE="fresh" ;;
    --oak)     TEMPLATE="oak" ;;
    --minimal) TEMPLATE="minimal" ;;
    *) error "Unknown option: $1" ;;
  esac
  shift
done

# Check for Deno
if ! command -v deno &> /dev/null; then
  error "Deno is not installed. Install from https://deno.land"
fi

DENO_VERSION=$(deno --version | head -1 | awk '{print $2}')
info "Using Deno ${DENO_VERSION}"

# Fresh template delegates to Fresh's own init
if [[ "$TEMPLATE" == "fresh" ]]; then
  info "Scaffolding Fresh project..."
  deno run -Ar jsr:@fresh/init "$PROJECT_NAME"
  log "Fresh project created at ./${PROJECT_NAME}"
  echo -e "\n  cd ${PROJECT_NAME} && deno task dev\n"
  exit 0
fi

# Create project directory
if [[ -d "$PROJECT_NAME" ]]; then
  error "Directory '${PROJECT_NAME}' already exists"
fi

mkdir -p "${PROJECT_NAME}/src" "${PROJECT_NAME}/tests"
cd "$PROJECT_NAME"

info "Creating ${TEMPLATE} project: ${PROJECT_NAME}"

# --- deno.json ---
if [[ "$TEMPLATE" == "minimal" ]]; then
  cat > deno.json << 'DENOEOF'
{
  "tasks": {
    "dev": "deno run --watch src/main.ts",
    "test": "deno test"
  },
  "fmt": {
    "indentWidth": 2,
    "singleQuote": true
  }
}
DENOEOF
else
  cat > deno.json << 'DENOEOF'
{
  "compilerOptions": {
    "strict": true
  },
  "imports": {
    "@std/assert": "jsr:@std/assert@^1",
    "@std/path": "jsr:@std/path@^1",
    "@std/http": "jsr:@std/http@^1",
    "@std/dotenv": "jsr:@std/dotenv@^0.225"
  },
  "tasks": {
    "dev": "deno run --watch --allow-net --allow-read --allow-env src/main.ts",
    "start": "deno run --allow-net --allow-read --allow-env src/main.ts",
    "test": "deno test --allow-read --allow-net",
    "lint": "deno lint",
    "fmt": "deno fmt",
    "check": "deno check src/main.ts",
    "compile": "deno compile --output=build/app --allow-net --allow-read --allow-env src/main.ts"
  },
  "lint": {
    "rules": {
      "tags": ["recommended"]
    }
  },
  "fmt": {
    "indentWidth": 2,
    "singleQuote": true
  },
  "exclude": ["build/", "node_modules/"]
}
DENOEOF
fi

log "Created deno.json"

# Add Oak dependency if needed
if [[ "$TEMPLATE" == "oak" ]]; then
  cat > deno.json << 'DENOEOF'
{
  "compilerOptions": {
    "strict": true
  },
  "imports": {
    "@std/assert": "jsr:@std/assert@^1",
    "@std/path": "jsr:@std/path@^1",
    "@std/dotenv": "jsr:@std/dotenv@^0.225",
    "oak": "jsr:@oak/oak@^17"
  },
  "tasks": {
    "dev": "deno run --watch --allow-net --allow-read --allow-env src/main.ts",
    "start": "deno run --allow-net --allow-read --allow-env src/main.ts",
    "test": "deno test --allow-read --allow-net",
    "lint": "deno lint",
    "fmt": "deno fmt",
    "check": "deno check src/main.ts"
  },
  "lint": {
    "rules": {
      "tags": ["recommended"]
    }
  },
  "fmt": {
    "indentWidth": 2,
    "singleQuote": true
  },
  "exclude": ["build/", "node_modules/"]
}
DENOEOF
fi

# --- src/main.ts ---
if [[ "$TEMPLATE" == "oak" ]]; then
  cat > src/main.ts << 'TSEOF'
import { Application, Router } from "oak";

const router = new Router();

router.get("/", (ctx) => {
  ctx.response.body = { message: "Hello from Oak + Deno!" };
});

router.get("/api/health", (ctx) => {
  ctx.response.body = { status: "ok", timestamp: new Date().toISOString() };
});

const app = new Application();

app.use(async (ctx, next) => {
  const start = performance.now();
  await next();
  const ms = (performance.now() - start).toFixed(1);
  ctx.response.headers.set("X-Response-Time", `${ms}ms`);
  console.log(`${ctx.request.method} ${ctx.request.url.pathname} — ${ms}ms`);
});

app.use(router.routes());
app.use(router.allowedMethods());

const port = Number(Deno.env.get("PORT") ?? 8000);
console.log(`🦕 Oak server running on http://localhost:${port}`);
await app.listen({ port });
TSEOF
elif [[ "$TEMPLATE" == "minimal" ]]; then
  cat > src/main.ts << 'TSEOF'
console.log("Hello from Deno!");
TSEOF
else
  cat > src/main.ts << 'TSEOF'
const port = Number(Deno.env.get("PORT") ?? 8000);

Deno.serve({ port }, async (req: Request): Promise<Response> => {
  const url = new URL(req.url);

  if (url.pathname === "/" && req.method === "GET") {
    return Response.json({ message: "Hello from Deno!" });
  }

  if (url.pathname === "/api/health" && req.method === "GET") {
    return Response.json({ status: "ok", timestamp: new Date().toISOString() });
  }

  return new Response("Not Found", { status: 404 });
});

console.log(`🦕 Server running on http://localhost:${port}`);
TSEOF
fi

log "Created src/main.ts"

# --- tests/main_test.ts ---
cat > tests/main_test.ts << 'TSEOF'
import { assertEquals } from "@std/assert";

Deno.test("sanity check", () => {
  assertEquals(1 + 1, 2);
});

Deno.test("string operations", () => {
  const greeting = "Hello, Deno!";
  assertEquals(greeting.includes("Deno"), true);
  assertEquals(greeting.length, 12);
});
TSEOF

log "Created tests/main_test.ts"

# --- .gitignore ---
cat > .gitignore << 'EOF'
# Deno
.deno/
node_modules/

# Build output
build/
dist/

# Environment
.env
.env.local
.env.*.local

# OS
.DS_Store
Thumbs.db

# Coverage
cov_profile/
coverage/
EOF

log "Created .gitignore"

# --- .github/workflows/ci.yml ---
mkdir -p .github/workflows
cat > .github/workflows/ci.yml << 'YMLEOF'
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: denoland/setup-deno@v2
        with:
          deno-version: v2.x

      - name: Check formatting
        run: deno fmt --check

      - name: Lint
        run: deno lint

      - name: Type check
        run: deno check src/main.ts

      - name: Run tests
        run: deno test --allow-read --allow-net
YMLEOF

log "Created .github/workflows/ci.yml"

# --- README.md ---
cat > README.md << EOF
# ${PROJECT_NAME}

Built with [Deno](https://deno.land) ${DENO_VERSION}.

## Getting Started

\`\`\`bash
# Development (with file watching)
deno task dev

# Run tests
deno task test

# Lint & format
deno task lint
deno task fmt

# Type check
deno task check
\`\`\`

## Project Structure

\`\`\`
${PROJECT_NAME}/
├── deno.json         # Config, dependencies, tasks
├── src/
│   └── main.ts       # Entry point
├── tests/
│   └── main_test.ts  # Tests
└── .github/
    └── workflows/
        └── ci.yml    # CI pipeline
\`\`\`
EOF

log "Created README.md"

# Initialize git
if command -v git &> /dev/null; then
  git init -q
  log "Initialized git repository"
fi

echo ""
echo -e "${GREEN}${BOLD}Project '${PROJECT_NAME}' created!${NC}"
echo ""
echo "  cd ${PROJECT_NAME}"
echo "  deno task dev"
echo ""
