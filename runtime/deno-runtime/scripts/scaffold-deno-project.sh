#!/usr/bin/env bash
# ============================================================================
# scaffold-deno-project.sh
#
# Scaffolds a new Deno 2.x project with proper deno.json, tasks, and
# directory structure.
#
# Usage:
#   ./scaffold-deno-project.sh <project-name> [--type api|fresh|cli|library]
#
# Examples:
#   ./scaffold-deno-project.sh my-api --type api
#   ./scaffold-deno-project.sh my-app --type fresh
#   ./scaffold-deno-project.sh my-tool --type cli
#   ./scaffold-deno-project.sh my-lib --type library
#
# Defaults to --type api if not specified.
# ============================================================================

set -euo pipefail

# ── Helpers ──

usage() {
  cat <<EOF
Usage: $(basename "$0") <project-name> [--type api|fresh|cli|library]

Options:
  --type    Project type (default: api)
              api      — Hono-based REST API with middleware, routes, tests
              fresh    — Fresh framework app with islands architecture
              cli      — Command-line tool with argument parsing
              library  — Reusable library with mod.ts entry point

Examples:
  $(basename "$0") my-api --type api
  $(basename "$0") my-app --type fresh
  $(basename "$0") my-tool --type cli
  $(basename "$0") my-lib --type library
EOF
  exit 1
}

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m    $*"; }
error() { echo -e "\033[1;31m[ERR]\033[0m   $*" >&2; exit 1; }

# ── Parse arguments ──

PROJECT_NAME=""
PROJECT_TYPE="api"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --type)
      shift
      PROJECT_TYPE="${1:-}"
      [[ -z "$PROJECT_TYPE" ]] && error "Missing value for --type"
      ;;
    --help|-h)
      usage
      ;;
    -*)
      error "Unknown flag: $1"
      ;;
    *)
      [[ -n "$PROJECT_NAME" ]] && error "Unexpected argument: $1"
      PROJECT_NAME="$1"
      ;;
  esac
  shift
done

[[ -z "$PROJECT_NAME" ]] && usage

case "$PROJECT_TYPE" in
  api|fresh|cli|library) ;;
  *) error "Invalid project type: $PROJECT_TYPE (must be api, fresh, cli, or library)" ;;
esac

# ── Guard against overwriting ──

[[ -d "$PROJECT_NAME" ]] && error "Directory '$PROJECT_NAME' already exists"

info "Scaffolding $PROJECT_TYPE project: $PROJECT_NAME"
mkdir -p "$PROJECT_NAME"
cd "$PROJECT_NAME"

# ============================================================================
# Project type: API
# ============================================================================
scaffold_api() {
  mkdir -p src/{routes,middleware} tests

  cat > deno.json <<'DENOJ'
{
  "compilerOptions": {
    "strict": true
  },
  "imports": {
    "hono": "jsr:@hono/hono@^4",
    "@std/assert": "jsr:@std/assert@^1",
    "@std/testing": "jsr:@std/testing@^1",
    "~/": "./src/"
  },
  "tasks": {
    "dev": "deno run --watch --allow-net --allow-env --allow-read main.ts",
    "start": "deno run --allow-net --allow-env --allow-read main.ts",
    "test": "deno test --allow-net --allow-read --allow-env",
    "lint": "deno lint",
    "fmt": "deno fmt",
    "check": "deno check main.ts"
  },
  "fmt": { "indentWidth": 2, "singleQuote": true },
  "lint": { "rules": { "tags": ["recommended"] } }
}
DENOJ

  cat > main.ts <<'MAIN'
import { app } from "~/app.ts";

const port = parseInt(Deno.env.get("PORT") ?? "8000");

Deno.serve({ port }, app.fetch);
console.log(`Server running on http://localhost:${port}`);
MAIN

  cat > src/app.ts <<'APP'
import { Hono } from "hono";
import { healthRoute } from "~/routes/health.ts";
import { usersRoute } from "~/routes/users.ts";
import { logger } from "~/middleware/logger.ts";

const app = new Hono();

app.use("*", logger());

app.route("/health", healthRoute);
app.route("/api/users", usersRoute);

export { app };
APP

  cat > src/routes/health.ts <<'HEALTH'
import { Hono } from "hono";

const healthRoute = new Hono();

healthRoute.get("/", (c) => c.json({ status: "ok", timestamp: new Date().toISOString() }));

export { healthRoute };
HEALTH

  cat > src/routes/users.ts <<'USERS'
import { Hono } from "hono";

interface User {
  id: string;
  name: string;
  email: string;
}

const users: User[] = [];

const usersRoute = new Hono();

usersRoute.get("/", (c) => c.json(users));

usersRoute.post("/", async (c) => {
  const body = await c.req.json<Omit<User, "id">>();
  const user: User = { id: crypto.randomUUID(), ...body };
  users.push(user);
  return c.json(user, 201);
});

usersRoute.get("/:id", (c) => {
  const user = users.find((u) => u.id === c.req.param("id"));
  return user ? c.json(user) : c.json({ error: "Not found" }, 404);
});

export { usersRoute };
USERS

  cat > src/middleware/logger.ts <<'LOGGER'
import type { MiddlewareHandler } from "hono";

export function logger(): MiddlewareHandler {
  return async (c, next) => {
    const start = Date.now();
    await next();
    const ms = Date.now() - start;
    console.log(`${c.req.method} ${c.req.path} ${c.res.status} ${ms}ms`);
  };
}
LOGGER

  cat > tests/health_test.ts <<'TEST'
import { assertEquals } from "@std/assert";
import { app } from "~/app.ts";

Deno.test("GET /health returns ok", async () => {
  const res = await app.request("/health");
  assertEquals(res.status, 200);
  const body = await res.json();
  assertEquals(body.status, "ok");
});
TEST

  cat > .gitignore <<'GIT'
.env
*.local
GIT

  cat > README.md <<EOF
# $PROJECT_NAME

Deno 2.x REST API built with Hono.

## Getting Started

\`\`\`bash
deno task dev    # Development with hot reload
deno task test   # Run tests
deno task lint   # Lint code
deno task fmt    # Format code
\`\`\`
EOF
}

# ============================================================================
# Project type: Fresh
# ============================================================================
scaffold_fresh() {
  mkdir -p routes/api islands components static

  cat > deno.json <<'DENOJ'
{
  "compilerOptions": {
    "strict": true,
    "jsx": "react-jsx",
    "jsxImportSource": "preact"
  },
  "imports": {
    "$fresh/": "https://deno.land/x/fresh@1.7.3/",
    "preact": "https://esm.sh/preact@10.22.1",
    "preact/": "https://esm.sh/preact@10.22.1/",
    "@preact/signals": "https://esm.sh/*@preact/signals@1.2.3",
    "@preact/signals-core": "https://esm.sh/*@preact/signals-core@1.7.0",
    "@std/assert": "jsr:@std/assert@^1"
  },
  "tasks": {
    "dev": "deno run -A --watch=static/,routes/ dev.ts",
    "start": "deno run -A main.ts",
    "build": "deno run -A dev.ts build",
    "test": "deno test --allow-read --allow-env"
  },
  "fmt": { "indentWidth": 2, "singleQuote": true },
  "lint": { "rules": { "tags": ["recommended", "fresh"] } }
}
DENOJ

  cat > main.ts <<'MAIN'
/// <reference no-default-lib="true" />
/// <reference lib="dom" />
/// <reference lib="dom.iterable" />
/// <reference lib="dom.asynciterable" />
/// <reference lib="deno.ns" />

import { start } from "$fresh/server.ts";
import manifest from "./fresh.gen.ts";

await start(manifest);
MAIN

  cat > dev.ts <<'DEV'
#!/usr/bin/env -S deno run -A --watch=static/,routes/

import dev from "$fresh/dev.ts";

await dev(import.meta.url, "./main.ts");
DEV

  cat > fresh.gen.ts <<'GEN'
// DO NOT EDIT. This file is auto-generated by Fresh.
// This is a placeholder — run `deno task dev` to regenerate.

import { Manifest } from "$fresh/server.ts";

const manifest: Manifest = {
  routes: {},
  islands: {},
  baseUrl: import.meta.url,
};

export default manifest;
GEN

  cat > routes/index.tsx <<'INDEX'
import Counter from "../islands/Counter.tsx";

export default function Home() {
  return (
    <div style={{ padding: "2rem", fontFamily: "system-ui" }}>
      <h1>Welcome to Fresh</h1>
      <p>This is a server-rendered page with an interactive island below.</p>
      <Counter start={0} />
    </div>
  );
}
INDEX

  cat > routes/api/health.ts <<'HEALTH'
import { Handlers } from "$fresh/server.ts";

export const handler: Handlers = {
  GET(_req, _ctx) {
    return Response.json({ status: "ok", timestamp: new Date().toISOString() });
  },
};
HEALTH

  cat > islands/Counter.tsx <<'COUNTER'
import { useSignal } from "@preact/signals";

interface CounterProps {
  start: number;
}

export default function Counter({ start }: CounterProps) {
  const count = useSignal(start);
  return (
    <div style={{ display: "flex", gap: "1rem", alignItems: "center" }}>
      <button onClick={() => count.value--}>-</button>
      <span style={{ fontSize: "1.5rem" }}>{count}</span>
      <button onClick={() => count.value++}>+</button>
    </div>
  );
}
COUNTER

  cat > components/Header.tsx <<'HEADER'
export default function Header({ title }: { title: string }) {
  return (
    <header style={{ padding: "1rem", borderBottom: "1px solid #ccc" }}>
      <h2>{title}</h2>
    </header>
  );
}
HEADER

  cat > .gitignore <<'GIT'
.env
_fresh/
GIT

  cat > README.md <<EOF
# $PROJECT_NAME

Fresh framework app with islands architecture.

## Getting Started

\`\`\`bash
deno task dev    # Development with hot reload
deno task build  # Production build
deno task start  # Production server
\`\`\`
EOF
}

# ============================================================================
# Project type: CLI
# ============================================================================
scaffold_cli() {
  mkdir -p src tests

  cat > deno.json <<'DENOJ'
{
  "compilerOptions": { "strict": true },
  "imports": {
    "@std/cli": "jsr:@std/cli@^1",
    "@std/fmt": "jsr:@std/fmt@^1",
    "@std/assert": "jsr:@std/assert@^1",
    "~/": "./src/"
  },
  "tasks": {
    "dev": "deno run --allow-read --allow-write --allow-env --watch main.ts",
    "run": "deno run --allow-read --allow-write --allow-env main.ts",
    "test": "deno test --allow-read",
    "compile": "deno compile --allow-read --allow-write --allow-env --output=bin/tool main.ts",
    "lint": "deno lint",
    "fmt": "deno fmt"
  },
  "fmt": { "indentWidth": 2, "singleQuote": true }
}
DENOJ

  cat > main.ts <<'MAIN'
import { parseArgs } from "@std/cli/parse-args";
import { bold, green, red } from "@std/fmt/colors";

const args = parseArgs(Deno.args, {
  boolean: ["help", "verbose"],
  string: ["name", "output"],
  alias: { h: "help", v: "verbose", n: "name", o: "output" },
  default: { name: "world" },
});

if (args.help) {
  console.log(`
${bold("tool")} — A Deno CLI tool

${bold("USAGE:")}
  tool [OPTIONS]

${bold("OPTIONS:")}
  -n, --name <name>    Name to greet (default: world)
  -o, --output <path>  Output file path
  -v, --verbose        Enable verbose output
  -h, --help           Show this help message
`);
  Deno.exit(0);
}

const greeting = `Hello, ${args.name}!`;
console.log(green(bold(greeting)));

if (args.output) {
  await Deno.writeTextFile(args.output, greeting + "\n");
  console.log(`Written to ${args.output}`);
}

if (args.verbose) {
  console.log("Arguments:", args);
}
MAIN

  cat > tests/main_test.ts <<'TEST'
import { assertEquals } from "@std/assert";

Deno.test("parseArgs works correctly", () => {
  // Unit test placeholder
  assertEquals(1 + 1, 2);
});
TEST

  cat > .gitignore <<'GIT'
.env
bin/
GIT

  cat > README.md <<EOF
# $PROJECT_NAME

A Deno CLI tool.

## Usage

\`\`\`bash
deno task run -- --name Alice
deno task compile  # Build standalone binary
\`\`\`
EOF
}

# ============================================================================
# Project type: Library
# ============================================================================
scaffold_library() {
  mkdir -p src tests

  cat > deno.json <<'DENOJ'
{
  "name": "@myorg/mylib",
  "version": "0.1.0",
  "exports": "./mod.ts",
  "compilerOptions": { "strict": true },
  "imports": {
    "@std/assert": "jsr:@std/assert@^1",
    "@std/testing": "jsr:@std/testing@^1"
  },
  "tasks": {
    "test": "deno test",
    "lint": "deno lint",
    "fmt": "deno fmt",
    "doc": "deno doc mod.ts"
  },
  "fmt": { "indentWidth": 2, "singleQuote": true },
  "publish": {
    "include": ["mod.ts", "src/", "deno.json", "README.md", "LICENSE"]
  }
}
DENOJ

  cat > mod.ts <<'MOD'
/**
 * @module
 * Main entry point for the library.
 */

export { greet } from "./src/greet.ts";
export type { GreetOptions } from "./src/greet.ts";
MOD

  cat > src/greet.ts <<'GREET'
/** Options for the greet function. */
export interface GreetOptions {
  /** Name to greet. */
  name: string;
  /** Optional greeting prefix. */
  prefix?: string;
}

/**
 * Returns a greeting string.
 *
 * @example
 * ```ts
 * import { greet } from "./mod.ts";
 * greet({ name: "Alice" }); // "Hello, Alice!"
 * ```
 */
export function greet(options: GreetOptions): string {
  const prefix = options.prefix ?? "Hello";
  return `${prefix}, ${options.name}!`;
}
GREET

  cat > tests/greet_test.ts <<'TEST'
import { assertEquals } from "@std/assert";
import { greet } from "../mod.ts";

Deno.test("greet with default prefix", () => {
  assertEquals(greet({ name: "Alice" }), "Hello, Alice!");
});

Deno.test("greet with custom prefix", () => {
  assertEquals(greet({ name: "Bob", prefix: "Hi" }), "Hi, Bob!");
});
TEST

  cat > .gitignore <<'GIT'
.env
GIT

  cat > README.md <<EOF
# $PROJECT_NAME

A Deno library.

## Usage

\`\`\`typescript
import { greet } from "jsr:@myorg/$PROJECT_NAME";

console.log(greet({ name: "Alice" }));
\`\`\`

## Development

\`\`\`bash
deno task test   # Run tests
deno task doc    # View documentation
deno publish     # Publish to JSR
\`\`\`
EOF
}

# ── Dispatch ──

case "$PROJECT_TYPE" in
  api)     scaffold_api     ;;
  fresh)   scaffold_fresh   ;;
  cli)     scaffold_cli     ;;
  library) scaffold_library ;;
esac

ok "Project '$PROJECT_NAME' ($PROJECT_TYPE) created successfully!"
info "Next steps:"
echo "  cd $PROJECT_NAME"
echo "  deno task dev"
