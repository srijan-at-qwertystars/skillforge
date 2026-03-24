#!/usr/bin/env bash
#
# scaffold-bun-project.sh — Scaffold a new Bun project
#
# Usage:
#   scaffold-bun-project.sh <project-name> [options]
#
# Options:
#   --type <type>         Project type: api, cli, library, fullstack (default: api)
#   --framework <fw>      Framework: hono, elysia, none (default: none)
#   --git                 Initialize git repository (default: true)
#   --no-git              Skip git initialization
#   -h, --help            Show this help message
#
# Examples:
#   scaffold-bun-project.sh my-api --type api --framework hono
#   scaffold-bun-project.sh my-cli --type cli
#   scaffold-bun-project.sh my-lib --type library
#   scaffold-bun-project.sh my-app --type fullstack --framework elysia
#
# Requirements: bun must be installed (https://bun.sh)
#

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()   { echo -e "${GREEN}✓${NC} $1"; }
info()  { echo -e "${BLUE}→${NC} $1"; }
warn()  { echo -e "${YELLOW}⚠${NC} $1"; }
error() { echo -e "${RED}✗${NC} $1" >&2; }

usage() {
  head -25 "$0" | tail -20 | sed 's/^# \?//'
  exit 0
}

# Defaults
PROJECT_TYPE="api"
FRAMEWORK="none"
INIT_GIT=true
PROJECT_NAME=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --type)      PROJECT_TYPE="$2"; shift 2 ;;
    --framework) FRAMEWORK="$2"; shift 2 ;;
    --git)       INIT_GIT=true; shift ;;
    --no-git)    INIT_GIT=false; shift ;;
    -h|--help)   usage ;;
    -*)          error "Unknown option: $1"; usage ;;
    *)           PROJECT_NAME="$1"; shift ;;
  esac
done

if [[ -z "$PROJECT_NAME" ]]; then
  error "Project name is required"
  usage
fi

if [[ ! "$PROJECT_TYPE" =~ ^(api|cli|library|fullstack)$ ]]; then
  error "Invalid project type: $PROJECT_TYPE (must be api, cli, library, or fullstack)"
  exit 1
fi

if [[ ! "$FRAMEWORK" =~ ^(hono|elysia|none)$ ]]; then
  error "Invalid framework: $FRAMEWORK (must be hono, elysia, or none)"
  exit 1
fi

if ! command -v bun &>/dev/null; then
  error "Bun is not installed. Install it: curl -fsSL https://bun.sh/install | bash"
  exit 1
fi

if [[ -d "$PROJECT_NAME" ]]; then
  error "Directory '$PROJECT_NAME' already exists"
  exit 1
fi

echo ""
info "Scaffolding Bun project: ${PROJECT_NAME}"
info "Type: ${PROJECT_TYPE} | Framework: ${FRAMEWORK}"
echo ""

# Create project directory
mkdir -p "$PROJECT_NAME"
cd "$PROJECT_NAME"

# ─── package.json ────────────────────────────────────────────────
create_package_json() {
  local scripts_block=""
  local main_field=""

  case $PROJECT_TYPE in
    api)
      main_field='"module": "src/index.ts",'
      scripts_block='"dev": "bun --hot run src/index.ts",
    "start": "bun run src/index.ts",
    "build": "bun build src/index.ts --outdir dist --target bun --minify",
    "test": "bun test",
    "lint": "bunx tsc --noEmit"'
      ;;
    cli)
      main_field='"module": "src/cli.ts",
  "bin": { "'"$PROJECT_NAME"'": "src/cli.ts" },'
      scripts_block='"dev": "bun run src/cli.ts",
    "build": "bun build src/cli.ts --outdir dist --target bun --minify",
    "test": "bun test",
    "lint": "bunx tsc --noEmit"'
      ;;
    library)
      main_field='"module": "src/index.ts",
  "types": "src/index.ts",'
      scripts_block='"build": "bun build src/index.ts --outdir dist --target bun",
    "test": "bun test",
    "lint": "bunx tsc --noEmit",
    "prepublishOnly": "bun run build && bun run test"'
      ;;
    fullstack)
      main_field='"module": "src/server.ts",'
      scripts_block='"dev": "bun --hot run src/server.ts",
    "start": "bun run src/server.ts",
    "build": "bun build src/server.ts --outdir dist --target bun --minify",
    "test": "bun test",
    "lint": "bunx tsc --noEmit"'
      ;;
  esac

  cat > package.json <<EOF
{
  "name": "${PROJECT_NAME}",
  "version": "0.1.0",
  ${main_field}
  "private": true,
  "scripts": {
    ${scripts_block}
  },
  "devDependencies": {
    "@types/bun": "latest"
  }
}
EOF
}

# ─── tsconfig.json ───────────────────────────────────────────────
create_tsconfig() {
  cat > tsconfig.json <<'EOF'
{
  "compilerOptions": {
    "target": "esnext",
    "module": "esnext",
    "moduleResolution": "bundler",
    "allowImportingTsExtensions": true,
    "noEmit": true,
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "forceConsistentCasingInFileNames": true,
    "types": ["bun-types"],
    "baseUrl": ".",
    "paths": {
      "@/*": ["src/*"]
    }
  },
  "include": ["src/**/*.ts", "src/**/*.tsx", "test/**/*.ts"],
  "exclude": ["node_modules", "dist"]
}
EOF
}

# ─── bunfig.toml ─────────────────────────────────────────────────
create_bunfig() {
  cat > bunfig.toml <<'EOF'
[test]
coverage = true
coverageSkipTestFiles = true

[install]
peer = false
EOF
}

# ─── .gitignore ──────────────────────────────────────────────────
create_gitignore() {
  cat > .gitignore <<'EOF'
node_modules/
dist/
*.log
.env.local
.env.*.local
.DS_Store
coverage/
EOF
}

# ─── .env ────────────────────────────────────────────────────────
create_env() {
  cat > .env <<EOF
PORT=3000
NODE_ENV=development
EOF

  cat > .env.example <<EOF
PORT=3000
NODE_ENV=development
# DATABASE_URL=
# API_KEY=
EOF
}

# ─── Source files ─────────────────────────────────────────────────
create_api_source() {
  mkdir -p src

  if [[ "$FRAMEWORK" == "hono" ]]; then
    cat > src/index.ts <<'EOF'
import { Hono } from "hono";
import { cors } from "hono/cors";
import { logger } from "hono/logger";

const app = new Hono();

app.use("*", cors());
app.use("*", logger());

app.get("/", (c) => c.json({ message: "Hello from Bun + Hono!" }));

app.get("/health", (c) => c.json({ status: "ok", uptime: process.uptime() }));

app.get("/api/hello/:name", (c) => {
  const name = c.req.param("name");
  return c.json({ message: `Hello, ${name}!` });
});

export default app;
EOF
  elif [[ "$FRAMEWORK" == "elysia" ]]; then
    cat > src/index.ts <<'EOF'
import { Elysia } from "elysia";

const app = new Elysia()
  .get("/", () => ({ message: "Hello from Bun + Elysia!" }))
  .get("/health", () => ({ status: "ok", uptime: process.uptime() }))
  .get("/api/hello/:name", ({ params: { name } }) => ({
    message: `Hello, ${name}!`,
  }))
  .listen(Bun.env.PORT ?? 3000);

console.log(`🦊 Elysia running at ${app.server?.url}`);
EOF
  else
    cat > src/index.ts <<'EOF'
const server = Bun.serve({
  port: Bun.env.PORT ?? 3000,

  async fetch(req) {
    const url = new URL(req.url);

    if (url.pathname === "/") {
      return Response.json({ message: "Hello from Bun!" });
    }

    if (url.pathname === "/health") {
      return Response.json({ status: "ok", uptime: process.uptime() });
    }

    return new Response("Not Found", { status: 404 });
  },

  error(err) {
    console.error(err);
    return Response.json({ error: "Internal Server Error" }, { status: 500 });
  },
});

console.log(`🚀 Server running at ${server.url}`);
EOF
  fi
}

create_cli_source() {
  mkdir -p src
  cat > src/cli.ts <<'EOF'
#!/usr/bin/env bun

const args = process.argv.slice(2);
const command = args[0];

function printHelp() {
  console.log(`
Usage: ${process.argv[1]} <command> [options]

Commands:
  greet <name>    Greet someone
  version         Show version
  help            Show this help message
`);
}

switch (command) {
  case "greet": {
    const name = args[1] ?? "World";
    console.log(`Hello, ${name}!`);
    break;
  }
  case "version":
    console.log("0.1.0");
    break;
  case "help":
  default:
    printHelp();
}
EOF
  chmod +x src/cli.ts
}

create_library_source() {
  mkdir -p src
  cat > src/index.ts <<'EOF'
/**
 * Add two numbers.
 */
export function add(a: number, b: number): number {
  return a + b;
}

/**
 * Subtract two numbers.
 */
export function subtract(a: number, b: number): number {
  return a - b;
}

/**
 * Clamp a number between min and max.
 */
export function clamp(value: number, min: number, max: number): number {
  return Math.min(Math.max(value, min), max);
}
EOF
}

create_fullstack_source() {
  mkdir -p src public

  if [[ "$FRAMEWORK" == "hono" ]]; then
    cat > src/server.ts <<'EOF'
import { Hono } from "hono";
import { cors } from "hono/cors";
import { serveStatic } from "hono/bun";

const app = new Hono();

app.use("*", cors());

// API routes
app.get("/api/hello", (c) => c.json({ message: "Hello from the API!" }));

// Static files
app.use("/*", serveStatic({ root: "./public" }));

export default app;
EOF
  elif [[ "$FRAMEWORK" == "elysia" ]]; then
    cat > src/server.ts <<'EOF'
import { Elysia } from "elysia";
import { staticPlugin } from "@elysiajs/static";

const app = new Elysia()
  .use(staticPlugin({ prefix: "/", assets: "public" }))
  .get("/api/hello", () => ({ message: "Hello from the API!" }))
  .listen(Bun.env.PORT ?? 3000);

console.log(`🦊 Server running at ${app.server?.url}`);
EOF
  else
    cat > src/server.ts <<'EOF'
const server = Bun.serve({
  port: Bun.env.PORT ?? 3000,

  static: {
    "/": new Response(await Bun.file("public/index.html").text(), {
      headers: { "Content-Type": "text/html" },
    }),
  },

  async fetch(req) {
    const url = new URL(req.url);

    if (url.pathname.startsWith("/api/")) {
      if (url.pathname === "/api/hello") {
        return Response.json({ message: "Hello from the API!" });
      }
      return Response.json({ error: "Not Found" }, { status: 404 });
    }

    // Serve static files from public/
    const file = Bun.file(`public${url.pathname}`);
    if (await file.exists()) return new Response(file);

    return new Response("Not Found", { status: 404 });
  },
});

console.log(`🚀 Server running at ${server.url}`);
EOF
  fi

  cat > public/index.html <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>${PROJECT_NAME}</title>
  <style>
    body { font-family: system-ui, sans-serif; max-width: 600px; margin: 4rem auto; padding: 0 1rem; }
    h1 { color: #f472b6; }
  </style>
</head>
<body>
  <h1>Welcome to ${PROJECT_NAME}</h1>
  <p>Built with Bun 🧄</p>
</body>
</html>
EOF
}

# ─── Test files ──────────────────────────────────────────────────
create_tests() {
  mkdir -p test

  case $PROJECT_TYPE in
    api|fullstack)
      cat > test/index.test.ts <<'EOF'
import { describe, it, expect } from "bun:test";

describe("API", () => {
  it("should return hello message", async () => {
    // Adjust the import/fetch based on your setup
    const response = await fetch("http://localhost:3000/");
    expect(response.status).toBe(200);
    const body = await response.json();
    expect(body).toHaveProperty("message");
  });
});
EOF
      ;;
    cli)
      cat > test/cli.test.ts <<'EOF'
import { describe, it, expect } from "bun:test";
import { $ } from "bun";

describe("CLI", () => {
  it("should greet by name", async () => {
    const output = await $`bun run src/cli.ts greet Bun`.text();
    expect(output.trim()).toBe("Hello, Bun!");
  });

  it("should show version", async () => {
    const output = await $`bun run src/cli.ts version`.text();
    expect(output.trim()).toBe("0.1.0");
  });
});
EOF
      ;;
    library)
      cat > test/index.test.ts <<'EOF'
import { describe, it, expect } from "bun:test";
import { add, subtract, clamp } from "../src/index";

describe("add", () => {
  it("adds two numbers", () => {
    expect(add(2, 3)).toBe(5);
  });
});

describe("subtract", () => {
  it("subtracts two numbers", () => {
    expect(subtract(5, 3)).toBe(2);
  });
});

describe("clamp", () => {
  it("clamps within range", () => {
    expect(clamp(5, 0, 10)).toBe(5);
    expect(clamp(-1, 0, 10)).toBe(0);
    expect(clamp(15, 0, 10)).toBe(10);
  });
});
EOF
      ;;
  esac
}

# ─── Dockerfile ──────────────────────────────────────────────────
create_dockerfile() {
  if [[ "$PROJECT_TYPE" == "library" ]]; then
    return
  fi

  local entry_file="src/index.ts"
  [[ "$PROJECT_TYPE" == "fullstack" ]] && entry_file="src/server.ts"

  cat > Dockerfile <<EOF
FROM oven/bun:1 AS base
WORKDIR /app

FROM base AS deps
COPY package.json bun.lock ./
RUN bun install --frozen-lockfile --production

FROM base AS build
COPY package.json bun.lock ./
RUN bun install --frozen-lockfile
COPY . .
RUN bun build ./${entry_file} --outdir ./dist --target bun --minify

FROM base AS production
COPY --from=deps /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
EOF

  if [[ "$PROJECT_TYPE" == "fullstack" ]]; then
    echo "COPY --from=build /app/public ./public" >> Dockerfile
  fi

  cat >> Dockerfile <<'EOF'
USER bun
EXPOSE 3000
CMD ["bun", "run", "dist/index.js"]
EOF
}

# ─── README.md ───────────────────────────────────────────────────
create_readme() {
  cat > README.md <<EOF
# ${PROJECT_NAME}

A ${PROJECT_TYPE} project built with Bun.

## Getting Started

\`\`\`bash
bun install
bun run dev
\`\`\`

## Scripts

- \`bun run dev\` — Start development server with hot reload
- \`bun test\` — Run tests
- \`bun run build\` — Build for production
- \`bun run lint\` — Type check with TypeScript

## Tech Stack

- [Bun](https://bun.sh) — Runtime, package manager, bundler, test runner
EOF

  if [[ "$FRAMEWORK" == "hono" ]]; then
    echo "- [Hono](https://hono.dev) — Web framework" >> README.md
  elif [[ "$FRAMEWORK" == "elysia" ]]; then
    echo "- [Elysia](https://elysiajs.com) — Web framework" >> README.md
  fi
}

# ─── Execute ─────────────────────────────────────────────────────
create_package_json
create_tsconfig
create_bunfig
create_gitignore
create_env
create_tests
create_dockerfile
create_readme

case $PROJECT_TYPE in
  api)       create_api_source ;;
  cli)       create_cli_source ;;
  library)   create_library_source ;;
  fullstack) create_fullstack_source ;;
esac

log "Project structure created"

# Install dependencies
info "Installing dependencies..."
DEPS=""
case $FRAMEWORK in
  hono)
    DEPS="hono"
    [[ "$PROJECT_TYPE" == "fullstack" ]] && DEPS="hono"
    ;;
  elysia)
    DEPS="elysia"
    [[ "$PROJECT_TYPE" == "fullstack" ]] && DEPS="elysia @elysiajs/static"
    ;;
esac

bun install --silent
if [[ -n "$DEPS" ]]; then
  bun add $DEPS --silent
fi
log "Dependencies installed"

# Initialize git
if [[ "$INIT_GIT" == true ]]; then
  git init --quiet
  git add -A
  git commit -m "Initial commit: ${PROJECT_TYPE} project scaffolded with Bun" --quiet
  log "Git repository initialized"
fi

echo ""
log "Project '${PROJECT_NAME}' created successfully!"
echo ""
echo "  cd ${PROJECT_NAME}"
if [[ "$PROJECT_TYPE" == "library" ]]; then
  echo "  bun test"
else
  echo "  bun run dev"
fi
echo ""
