---
name: deno-runtime
description: >
  Expert guidance for building applications with the Deno runtime (2.x+).
  TRIGGER when: user mentions "Deno", code imports from "jsr:", "deno.land/std",
  or "@std/", project has deno.json/deno.jsonc, code uses Deno.serve, Deno.test,
  Deno.openKv, Deno.dlopen, Deno.Command, user mentions "deno deploy", "deno compile",
  "deno task", "deno bench", "Fresh framework", "Fresh islands", "JSR", "jsr:",
  "deno.land", or asks about Deno permissions (--allow-read/write/net/env/ffi/run).
  NOT for Node.js-only projects, Bun runtime, browser-only JavaScript, or general
  TypeScript without Deno context. Do not trigger for npm/npx/yarn/pnpm commands
  unless used alongside Deno's npm: specifier compatibility.
---

# Deno Runtime (2.x) — Skill Reference

## Core Concepts

Deno is a secure-by-default JavaScript/TypeScript runtime built on V8 and Rust. It runs TypeScript natively — no `tsconfig.json` or build step required. Deno 2.x added full npm/Node.js compatibility while preserving its security model.

### Key Differentiators from Node.js
- **Secure by default**: No file/network/env access unless explicitly granted
- **Native TypeScript**: Direct execution of `.ts` files, no transpilation setup
- **Web-standard APIs**: `fetch`, `Request`, `Response`, `URL`, `WebSocket`, `crypto`, streams
- **Built-in toolchain**: formatter, linter, test runner, bundler, LSP, benchmarker
- **Single executable deploys**: `deno compile` creates standalone binaries

## Permissions Model

Deno denies all privileged access by default. Grant permissions via CLI flags:

```
--allow-read[=<paths>]    Filesystem read (e.g., --allow-read=./data,./config)
--allow-write[=<paths>]   Filesystem write
--allow-net[=<hosts>]     Network access (e.g., --allow-net=api.example.com:443)
--allow-env[=<vars>]      Environment variables (e.g., --allow-env=DATABASE_URL,API_KEY)
--allow-run[=<programs>]  Subprocess execution
--allow-ffi               Foreign function interface (native libraries)
--allow-sys               System info (hostname, OS release, etc.)
-A / --allow-all          Grant all permissions (dev only — never in production)
```

**Deny flags** override allows for fine-grained control:
```
--deny-net=evil.com       Block specific host even with --allow-net
--deny-read=/etc/passwd   Block specific path even with --allow-read
```

In `deno.json` tasks, embed permissions directly:
```jsonc
{
  "tasks": {
    "dev": "deno run --allow-net --allow-read --allow-env --watch src/main.ts",
    "start": "deno run --allow-net=0.0.0.0:8000 --allow-read=./static --allow-env=DATABASE_URL src/main.ts"
  }
}
```

## deno.json Configuration

Central project config — replaces `package.json`, `tsconfig.json`, `.eslintrc`, `.prettierrc`:

```jsonc
{
  "compilerOptions": {
    "strict": true,
    "jsx": "react-jsx",
    "jsxImportSource": "preact"
  },
  "imports": {
    "@std/assert": "jsr:@std/assert@^1",
    "@std/path": "jsr:@std/path@^1",
    "@std/http": "jsr:@std/http@^1",
    "oak": "jsr:@oak/oak@^17",
    "zod": "npm:zod@^3.23"
  },
  "tasks": {
    "dev": "deno run --watch --allow-net --allow-read --allow-env src/main.ts",
    "test": "deno test --allow-read --allow-net",
    "lint": "deno lint",
    "fmt": "deno fmt",
    "compile": "deno compile --output=build/app --allow-net src/main.ts"
  },
  "lint": {
    "rules": { "exclude": ["no-unused-vars"] }
  },
  "fmt": {
    "indentWidth": 2,
    "singleQuote": true
  },
  "exclude": ["node_modules/", "build/"]
}
```

### Workspaces (Monorepos)

```jsonc
// deno.json (root)
{
  "workspace": ["./packages/core", "./packages/api", "./packages/web"]
}
```
Each sub-package has its own `deno.json` with independent dependencies and tasks.

## Standard Library (@std via JSR)

Import via JSR — the modern Deno-native registry with semver:

```typescript
import { assertEquals, assertThrows } from "@std/assert";
import { join, basename } from "@std/path";
import { parse as parseCSV } from "@std/csv";
import { encodeBase64 } from "@std/encoding/base64";
import { delay } from "@std/async/delay";
import { serveDir } from "@std/http/file-server";
```

Add to project: `deno add jsr:@std/assert jsr:@std/path`

Common packages: `@std/assert`, `@std/path`, `@std/fs`, `@std/http`, `@std/csv`, `@std/json`, `@std/yaml`, `@std/encoding`, `@std/async`, `@std/collections`, `@std/crypto`, `@std/dotenv`, `@std/fmt`, `@std/log`, `@std/streams`, `@std/uuid`.

## npm Compatibility

Deno 2.x runs most npm packages via the `npm:` specifier:

```typescript
import express from "npm:express@^4.18";
import chalk from "npm:chalk@^5";
import { z } from "npm:zod@^3.23";
```

Or declare in `deno.json` imports map and use bare specifiers:
```jsonc
{ "imports": { "zod": "npm:zod@^3.23" } }
```
```typescript
import { z } from "zod";
```

Deno also supports `package.json` and `node_modules/` for existing Node projects.

## HTTP Server (Deno.serve)

The built-in server API uses web-standard `Request`/`Response`:

```typescript
Deno.serve({ port: 8000 }, async (req: Request): Promise<Response> => {
  const url = new URL(req.url);

  if (req.method === "GET" && url.pathname === "/api/health") {
    return Response.json({ status: "ok" });
  }

  if (req.method === "POST" && url.pathname === "/api/data") {
    const body = await req.json();
    return Response.json({ received: body }, { status: 201 });
  }

  return new Response("Not Found", { status: 404 });
});
```

Run with `deno serve` for multi-threaded HTTP (uses `--parallel` flag):
```bash
deno serve --parallel --allow-net main.ts
```

Export a default `fetch` handler for `deno serve`:
```typescript
export default {
  fetch(req: Request): Response {
    return new Response("Hello from deno serve!");
  },
};
```

### WebSocket Server

```typescript
Deno.serve((req) => {
  if (req.headers.get("upgrade") === "websocket") {
    const { socket, response } = Deno.upgradeWebSocket(req);
    socket.onopen = () => console.log("Client connected");
    socket.onmessage = (e) => socket.send(`Echo: ${e.data}`);
    socket.onclose = () => console.log("Client disconnected");
    return response;
  }
  return new Response("Use WebSocket", { status: 400 });
});
```

## Testing (Deno.test)

Built-in test runner — no dependencies needed:

```typescript
import { assertEquals, assertRejects } from "@std/assert";

Deno.test("sync test", () => {
  assertEquals(2 + 2, 4);
});

Deno.test("async test", async () => {
  const res = await fetch("https://httpbin.org/get");
  assertEquals(res.status, 200);
});

Deno.test({
  name: "with permissions",
  permissions: { net: true, read: true },
  fn: async () => {
    const data = await Deno.readTextFile("./test-data.txt");
    assertEquals(data.length > 0, true);
  },
});

// Test steps (subtests)
Deno.test("user workflow", async (t) => {
  await t.step("create user", () => { /* ... */ });
  await t.step("verify user", () => { /* ... */ });
});
```

Run tests:
```bash
deno test                          # All tests
deno test --filter="user"          # Filter by name
deno test --coverage=cov_profile   # Collect coverage
deno coverage cov_profile          # View coverage report
deno test --watch                  # Re-run on changes
deno test --doc                    # Test code blocks in JSDoc/markdown
```

## Deno KV (Key-Value Store)

Built-in persistent KV store — works locally and on Deno Deploy:

```typescript
const kv = await Deno.openKv();   // local SQLite-backed store

// Set a value (keys are arrays for hierarchical organization)
await kv.set(["users", "u001"], { name: "Alice", email: "alice@example.com" });

// Get a value
const entry = await kv.get(["users", "u001"]);
console.log(entry.value);  // { name: "Alice", email: "alice@example.com" }

// List by prefix
const iter = kv.list({ prefix: ["users"] });
for await (const entry of iter) {
  console.log(entry.key, entry.value);
}

// Atomic transactions
await kv.atomic()
  .set(["users", "u002"], { name: "Bob" })
  .set(["users_count"], new Deno.KvU64(2n))
  .commit();

// Delete
await kv.delete(["users", "u001"]);
```

## Deno Deploy

Serverless edge platform for Deno apps. Deploy via GitHub integration or CLI:

```bash
# Install deployctl
deno install -gArf jsr:@deno/deployctl

# Deploy
deployctl deploy --project=my-app --prod src/main.ts
```

Environment variables configured via the Deno Deploy dashboard or CLI.
Deno KV is automatically available as a managed, globally-replicated store.

## Fresh Framework

Full-stack web framework with islands architecture (ship zero JS by default):

```bash
# Create project
deno run -Ar jsr:@fresh/init my-app
cd my-app && deno task dev
```

Key concepts:
- **File-based routing** in `routes/` — each file exports a handler/component
- **Islands** in `islands/` — interactive components hydrated on the client
- **Middleware** — `_middleware.ts` files for auth, logging, etc.
- **Handlers** — export `handler` object with HTTP method functions

```typescript
// routes/api/users.ts — API route
export const handler = {
  async GET(_req: Request, ctx: FreshContext) {
    const users = await getUsers();
    return Response.json(users);
  },
  async POST(req: Request, _ctx: FreshContext) {
    const body = await req.json();
    const user = await createUser(body);
    return Response.json(user, { status: 201 });
  },
};
```

## Compile (Standalone Binaries)

```bash
deno compile --allow-net --allow-read src/main.ts            # Basic
deno compile --output=build/app --target=x86_64-unknown-linux-gnu src/main.ts  # Cross-compile
deno compile --include=./static --allow-read src/main.ts     # Embed assets
# Targets: x86_64-unknown-linux-gnu, aarch64-unknown-linux-gnu,
#   x86_64-pc-windows-msvc, x86_64-apple-darwin, aarch64-apple-darwin
```

## FFI (Foreign Function Interface)

Call native C/Rust shared libraries from Deno:

```typescript
const lib = Deno.dlopen("./libmath.so", {
  add: { parameters: ["i32", "i32"], result: "i32" },
  multiply: { parameters: ["f64", "f64"], result: "f64", nonblocking: true },
});

const sum = lib.symbols.add(3, 4);          // 7 (synchronous)
const product = await lib.symbols.multiply(2.5, 3.0); // 7.5 (async/nonblocking)

lib.close();
```

Run with: `deno run --allow-ffi ffi_example.ts`

## JSR Package Registry

JSR is the TypeScript-native registry for Deno (and Node/Bun):

```bash
# Add packages
deno add jsr:@std/assert jsr:@oak/oak

# Publish your own package
deno publish
```

`deno.json` for publishing:
```jsonc
{
  "name": "@myorg/mylib",
  "version": "1.0.0",
  "exports": "./mod.ts"
}
```

## Formatting, Linting & Type-Checking

```bash
deno fmt                       # Format all files (--check to verify only)
deno lint                      # Lint all files (--fix to auto-fix)
deno check src/main.ts         # Type-check without running
```

## Subprocess (Deno.Command)

```typescript
const cmd = new Deno.Command("git", {
  args: ["status", "--short"],
  stdout: "piped",
  stderr: "piped",
});

const { code, stdout, stderr } = await cmd.output();
const out = new TextDecoder().decode(stdout);
console.log(out);
```

## Common Patterns & Best Practices

1. **Scope permissions** — use specific paths/hosts, never `-A` in production
2. **Use `deno.json` imports** — centralize dependency versions via import maps
3. **Prefer `@std/` over npm** — when a std equivalent exists, use it
4. **Use `deno.lock`** — auto-generated lockfile for reproducible builds
5. **Use `deno task`** — define scripts in `deno.json`
6. **Type-check separately**: `deno check src/main.ts` (runtime skips type-check for speed)

## Examples

### Example 1: REST API with KV

```typescript
const kv = await Deno.openKv();
Deno.serve({ port: 8000 }, async (req) => {
  const url = new URL(req.url);
  if (url.pathname === "/api/items" && req.method === "GET") {
    const items = [];
    for await (const entry of kv.list({ prefix: ["items"] })) items.push(entry.value);
    return Response.json(items);
  }
  if (url.pathname === "/api/items" && req.method === "POST") {
    const item = await req.json();
    const id = crypto.randomUUID();
    await kv.set(["items", id], { id, ...item });
    return Response.json({ id, ...item }, { status: 201 });
  }
  return new Response("Not Found", { status: 404 });
});
```

### Example 2: CLI Compiled to Binary

```typescript
import { parse } from "@std/csv";
const filename = Deno.args[0];
if (!filename) { console.error("Usage: csv2json <file.csv>"); Deno.exit(1); }
const records = parse(await Deno.readTextFile(filename), { skipFirstRow: true });
console.log(JSON.stringify(records, null, 2));
```
```bash
deno compile --allow-read --output=csv2json csv2json.ts
```

### Example 3: Testing

```typescript
import { assertEquals } from "@std/assert";
Deno.test("createUser returns user with id", () => {
  const user = createUser("Alice");
  assertEquals(user.name, "Alice");
  assertEquals(typeof user.id, "string");
});
```

### Example 4: deno.json for a Full Project

**Input**: "Set up a Deno project config"

**Output**:
```jsonc
{
  "compilerOptions": { "strict": true, "jsx": "react-jsx", "jsxImportSource": "preact" },
  "imports": {
    "@std/assert": "jsr:@std/assert@^1",
    "@std/http": "jsr:@std/http@^1",
    "oak": "jsr:@oak/oak@^17",
    "zod": "npm:zod@^3.23"
  },
  "tasks": {
    "dev": "deno run --watch --allow-net --allow-read --allow-env src/main.ts",
    "test": "deno test --allow-read",
    "build": "deno compile --output=dist/app --allow-net src/main.ts"
  },
  "fmt": { "indentWidth": 2, "singleQuote": true },
  "exclude": ["dist/", "node_modules/"]
}
```

## References

Deep-dive documents for advanced topics:

- **[references/advanced-patterns.md](references/advanced-patterns.md)** — Deno 2.x workspaces, `Deno.cron`, KV queues, `BroadcastChannel`, Web Workers, `Deno.Command`, custom runtimes with `deno_core`, embedding Deno, performance profiling (V8 flags), import maps, `deno serve` multi-threading, streaming/SSE patterns
- **[references/troubleshooting.md](references/troubleshooting.md)** — Permission denied patterns, import resolution errors, npm compatibility issues, TypeScript strict mode, debugging (`--inspect`, VS Code), `DENO_DIR` caching, lock file conflicts, Node.js migration guide, Deno Deploy failures, KV issues
- **[references/fresh-framework.md](references/fresh-framework.md)** — Fresh 2.x islands architecture, route handlers, dynamic routes, middleware, layouts, static files, plugins, form submissions, WebSocket, state management, error handling, Deno Deploy, SEO (meta/sitemap/robots.txt/JSON-LD), streaming/partials, testing

## Scripts

Ready-to-use scripts for common Deno workflows:

| Script | Purpose | Usage |
|--------|---------|-------|
| [scripts/deno-project-init.sh](scripts/deno-project-init.sh) | Scaffold a new Deno project with config, tests, CI | `./deno-project-init.sh my-app [--fresh\|--oak\|--minimal]` |
| [scripts/node-to-deno.sh](scripts/node-to-deno.sh) | Migrate Node.js projects to Deno (import analysis, deno.json creation) | `./node-to-deno.sh ./my-node-app [--dry-run]` |
| [scripts/deno-benchmark.ts](scripts/deno-benchmark.ts) | Benchmarking examples using `Deno.bench()` | `deno bench scripts/deno-benchmark.ts` |

## Assets (Templates)

Copy-paste templates for common project files:

| Asset | Purpose |
|-------|---------|
| [assets/deno-config-template.json](assets/deno-config-template.json) | Comprehensive `deno.json` with tasks, imports, lint, fmt, test, bench config |
| [assets/fresh-route-template.tsx](assets/fresh-route-template.tsx) | Fresh route handler with island component pattern |
| [assets/oak-server-template.ts](assets/oak-server-template.ts) | Oak middleware server with CRUD routes, CORS, error handling, request logging |
| [assets/github-actions-deno.yml](assets/github-actions-deno.yml) | CI/CD workflow: lint, fmt, type-check, test with coverage, optional deploy |
| [assets/dockerfile-deno](assets/dockerfile-deno) | Multi-stage Dockerfile with dependency caching, non-root user, health check |
