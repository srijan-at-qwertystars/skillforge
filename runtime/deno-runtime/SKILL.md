---
name: deno-runtime
description: >
  Expert guidance for building with Deno 2.x — the secure TypeScript/JavaScript runtime.
  Covers security permissions, module system (npm:, jsr:, URL imports, import maps),
  deno.json config, built-in tools (fmt, lint, test, bench, compile, doc, task),
  Deno.serve() HTTP server, Fresh framework, Deno Deploy edge functions, Deno KV,
  file system and subprocess APIs, WebSocket, FFI, Web APIs, and Node.js compatibility.
  Use when user needs Deno runtime, Deno 2, Deno Deploy, Fresh framework, Deno KV,
  or secure JavaScript/TypeScript runtime. NOT for Node.js-specific tooling (use node
  patterns), NOT for Bun runtime, NOT for browser JavaScript, NOT for frontend frameworks.
---

# Deno Runtime

## Project Init & deno.json

```bash
deno init my_project && cd my_project  # Creates deno.json, main.ts, main_test.ts
```

deno.json — single config replacing tsconfig, eslintrc, prettierrc, and package.json:

```jsonc
{
  "compilerOptions": { "strict": true, "jsx": "react-jsx", "jsxImportSource": "preact" },
  "imports": {
    "@std/assert": "jsr:@std/assert@^1.0.0",
    "@std/http": "jsr:@std/http@^1.0.0",
    "chalk": "npm:chalk@5",
    "~/": "./src/"
  },
  "tasks": {
    "dev": "deno run --watch --allow-net main.ts",
    "start": "deno run --allow-net --allow-read main.ts",
    "test": "deno test --allow-read"
  },
  "fmt": { "indentWidth": 2, "singleQuote": true, "semiColons": false },
  "lint": { "rules": { "exclude": ["no-unused-vars"] } },
  "lock": true,
  "nodeModulesDir": "auto"
}
```

## Security Model — Permissions

Deno is secure by default. No I/O access unless explicitly granted.

| Flag | Scope | Example |
|------|-------|---------|
| `--allow-read` | File read | `--allow-read=./data,./config` |
| `--allow-write` | File write | `--allow-write=./output` |
| `--allow-net` | Network | `--allow-net=api.example.com` |
| `--allow-env` | Env vars | `--allow-env=DATABASE_URL,API_KEY` |
| `--allow-run` | Subprocesses | `--allow-run=git,deno` |
| `--allow-ffi` | FFI/dlopen | `--allow-ffi=./libexample.so` |
| `--allow-sys` | System info | `--allow-sys=osRelease,hostname` |
| `-A` | All | **Dev only — never in production** |

Deny flags override allows: `--allow-read --deny-read=./secrets`.

```bash
deno run --allow-net=0.0.0.0:8000 --allow-read=./public --allow-env=PORT main.ts
```

## Module System

```typescript
// JSR — Deno-native registry (preferred)
import { assertEquals } from "jsr:@std/assert@^1.0.0";
// npm — any npm package directly
import express from "npm:express@4";
// URL imports — remote ES modules
import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
// Node built-ins via node: specifier
import { readFileSync } from "node:fs";
import { join } from "node:path";
```

Use import maps in deno.json to keep source files clean:

```typescript
// With "imports": { "@std/assert": "jsr:@std/assert@^1.0.0", "~/": "./src/" }
import { assertEquals } from "@std/assert";
import { handler } from "~/routes/api.ts";
```

Dependency management:

```bash
deno add jsr:@std/http          # Add JSR package
deno add npm:express            # Add npm package
deno remove npm:express         # Remove
deno outdated                   # Check updates
```

`deno.lock` auto-generated — commit for reproducible builds.

## TypeScript — Zero Config

Deno runs TypeScript natively. No tsconfig, no tsc, no build step.

```typescript
interface User { id: number; name: string; email: string }
function greet(user: User): string { return `Hello, ${user.name}!`; }
console.log(greet({ id: 1, name: "Alice", email: "a@b.com" }));
// $ deno run main.ts → Hello, Alice!
```

## Built-in Tools

```bash
# Formatter
deno fmt                        # Format all files
deno fmt --check                # CI check (no modify)
# Linter
deno lint                       # Lint all files
# Test runner
deno test                       # Run all tests
deno test --allow-net           # With permissions
deno test --filter "addition"   # Filter by name
deno test --coverage=cov && deno coverage cov  # Coverage
# Benchmarks
deno bench                      # Run bench.ts files
# Compile to standalone binary
deno compile --allow-net --output=myapp main.ts
deno compile --target=x86_64-unknown-linux-gnu --output=myapp-linux main.ts
# Documentation
deno doc main.ts                # View module docs
deno doc --html --output=docs   # Generate HTML docs
# Task runner
deno task dev                   # Run task from deno.json
```

### Test Example

```typescript
import { assertEquals } from "jsr:@std/assert";

Deno.test("addition", () => { assertEquals(2 + 3, 5); });

Deno.test("async fetch", async () => {
  const res = await fetch("https://httpbin.org/get");
  assertEquals(res.status, 200);
});

Deno.test({ name: "scoped perms", permissions: { read: true }, fn: async () => {
  const content = await Deno.readTextFile("./test_data.txt");
  assertEquals(content.length > 0, true);
}});
```

### Benchmark Example

```typescript
Deno.bench("URL parsing", () => { new URL("https://deno.land"); });
Deno.bench("JSON parse", () => { JSON.parse('{"k":"v"}'); });
```

## HTTP Server — Deno.serve()

```typescript
Deno.serve({ port: 8000 }, (req: Request): Response => {
  const url = new URL(req.url);
  if (url.pathname === "/api/hello" && req.method === "GET") {
    return Response.json({ message: "Hello, Deno!" });
  }
  if (url.pathname === "/api/echo" && req.method === "POST") {
    return new Response(req.body, {
      headers: { "content-type": req.headers.get("content-type") ?? "text/plain" },
    });
  }
  return new Response("Not Found", { status: 404 });
});
// $ deno run --allow-net server.ts
// $ curl localhost:8000/api/hello → {"message":"Hello, Deno!"}
```

## WebSocket Server

```typescript
Deno.serve({ port: 8080 }, (req) => {
  if (req.headers.get("upgrade") !== "websocket") {
    return new Response("Expected WebSocket", { status: 400 });
  }
  const { socket, response } = Deno.upgradeWebSocket(req);
  socket.onmessage = (e) => socket.send(`Echo: ${e.data}`);
  socket.onclose = () => console.log("Client disconnected");
  return response;
});
```

## File System API

All operations require `--allow-read` and/or `--allow-write`.

```typescript
// Read
const text = await Deno.readTextFile("./config.json");
const bytes = await Deno.readFile("./image.png");

// Write
await Deno.writeTextFile("./output.txt", "Hello, Deno!");
await Deno.writeFile("./data.bin", new Uint8Array([1, 2, 3]));
await Deno.writeTextFile("./log.txt", "line\n", { append: true });

// Directory ops
await Deno.mkdir("./new_dir", { recursive: true });
for await (const entry of Deno.readDir("./src")) {
  console.log(entry.name, entry.isFile ? "file" : "dir");
}

// Stat, remove, copy, rename
const stat = await Deno.stat("./main.ts");
await Deno.remove("./temp", { recursive: true });
await Deno.copyFile("./src.txt", "./dst.txt");
await Deno.rename("./old.txt", "./new.txt");
```

## Subprocess API — Deno.Command

Requires `--allow-run`.

```typescript
// Capture output
const cmd = new Deno.Command("git", {
  args: ["status", "--porcelain"], stdout: "piped", stderr: "piped",
});
const { code, stdout } = await cmd.output();
console.log(new TextDecoder().decode(stdout));

// Stream to terminal
const proc = new Deno.Command("deno", {
  args: ["test"], stdout: "inherit", stderr: "inherit",
}).spawn();
await proc.status;

// Pipe stdin
const cat = new Deno.Command("cat", { stdin: "piped", stdout: "piped" }).spawn();
const w = cat.stdin.getWriter();
await w.write(new TextEncoder().encode("Hello"));
await w.close();
const out = await cat.output();
console.log(new TextDecoder().decode(out.stdout)); // Hello
```

## Deno KV — Built-in Key-Value Store

```typescript
const kv = await Deno.openKv();  // Local SQLite or Deno Deploy managed

// CRUD with hierarchical keys
await kv.set(["users", "alice"], { name: "Alice", role: "admin" });
const entry = await kv.get(["users", "alice"]);
console.log(entry.value); // { name: "Alice", role: "admin" }

// List by prefix
for await (const e of kv.list({ prefix: ["users"] })) {
  console.log(e.key, e.value);
}

// Atomic transactions with optimistic locking
await kv.atomic()
  .check({ key: ["users", "alice"], versionstamp: entry.versionstamp })
  .set(["users", "alice"], { ...entry.value, role: "superadmin" })
  .commit();

await kv.delete(["users", "bob"]);

// Queue — background job processing
await kv.enqueue({ task: "send_email", to: "alice@example.com" });
kv.listenQueue(async (msg) => { console.log("Processing:", msg); });
```

On Deno Deploy, KV is globally distributed with strong consistency.

## Fresh Framework

Server-rendered, island architecture — zero client JS by default.

```bash
deno run -A jsr:@fresh/init my-app && cd my-app && deno task dev
```

Route handler — `routes/api/users.ts`:

```typescript
import { Handlers } from "$fresh/server.ts";
export const handler: Handlers = {
  GET(_req, _ctx) { return Response.json([{ id: 1, name: "Alice" }]); },
  async POST(req, _ctx) {
    const body = await req.json();
    return Response.json({ created: body }, { status: 201 });
  },
};
```

Island component — `islands/Counter.tsx`:

```tsx
import { useSignal } from "@preact/signals";
export default function Counter() {
  const count = useSignal(0);
  return <button onClick={() => count.value++}>Count: {count}</button>;
}
```

## Deno Deploy — Edge Functions

```bash
deno install -gArf jsr:@deno/deployctl
deployctl deploy --project=my-project main.ts
```

```typescript
// Runs on 35+ global edge regions
Deno.serve((req) => {
  return new Response(`Hello from ${Deno.env.get("DENO_REGION") ?? "local"}!`);
});
```

## Standard Library (@std/)

```typescript
import { join, basename } from "jsr:@std/path";
import { parse as parseCSV } from "jsr:@std/csv";
import { serveDir } from "jsr:@std/http/file-server";
import { delay } from "jsr:@std/async/delay";
import { encodeBase64 } from "jsr:@std/encoding/base64";
import { parse as parseFlags } from "jsr:@std/flags";
```

## Web APIs Compatibility

Standard Web APIs work identically to browsers:

```typescript
const res = await fetch("https://api.github.com/users/denoland");
const data = await res.json();
const hash = await crypto.subtle.digest("SHA-256", new TextEncoder().encode("hello"));
// URL, URLSearchParams, Headers, FormData, Blob, ReadableStream — all available
```

## Node.js Compatibility & Migration

```typescript
// node: built-ins
import fs from "node:fs/promises";
import path from "node:path";
import { Buffer } from "node:buffer";
import { createHash } from "node:crypto";

// npm packages — works directly
import express from "npm:express@4";
const app = express();
app.get("/", (_req, res) => res.json({ runtime: "deno" }));
app.listen(3000);
```

Migration checklist:
1. `require()` → `import` (ESM)
2. Add `node:` prefix: `fs` → `node:fs`
3. `package.json` scripts → `deno.json` tasks
4. Add permission flags
5. Replace `__dirname`: `const __dirname = new URL(".", import.meta.url).pathname;`

## FFI — Foreign Function Interface

Requires `--allow-ffi`.

```typescript
const lib = Deno.dlopen("./libmath.so", {
  add: { parameters: ["i32", "i32"], result: "i32" },
  multiply: { parameters: ["f64", "f64"], result: "f64" },
});
console.log(lib.symbols.add(2, 3));       // 5
console.log(lib.symbols.multiply(2.5, 4)); // 10.0
lib.close();
```

## Workspaces — Monorepo

```jsonc
// deno.json (root)
{ "workspaces": ["./packages/core", "./packages/api"] }

// packages/core/deno.json
{ "name": "@myorg/core", "version": "1.0.0", "exports": "./mod.ts" }
```

```typescript
import { validate } from "@myorg/core";  // Cross-workspace import
```

## Common Patterns

```typescript
// Environment variables (--allow-env)
const port = parseInt(Deno.env.get("PORT") ?? "8000");
import "jsr:@std/dotenv/load";  // Load .env file

// Watch mode
// $ deno run --watch main.ts
// $ deno run --watch --allow-net server.ts
// $ deno test --watch

// Graceful shutdown
const ac = new AbortController();
Deno.addSignalListener("SIGINT", () => ac.abort());
Deno.serve({ port: 8000, signal: ac.signal }, () => new Response("OK"));

// Static file server
import { serveDir } from "jsr:@std/http/file-server";
Deno.serve((req) => serveDir(req, { fsRoot: "./public", quiet: true }));
```

## Production Checklist

- Use granular permissions — never ship with `-A`
- Commit `deno.lock` for reproducible builds
- Prefer `jsr:` over URL imports for standard packages
- Use `deno.json` import maps — avoid inline specifiers in source
- Run `deno lint` and `deno fmt --check` in CI
- Run `deno test --coverage` in CI
- Use `deno compile` for distributable binaries
- Set `"strict": true` in compilerOptions
- Use `Deno.serve()` not deprecated `Deno.listen()` for HTTP
- Use `Deno.Command` not deprecated `Deno.run` for subprocesses

---

## References

In-depth guides in `references/`:

- **[advanced-patterns.md](references/advanced-patterns.md)** — Deno 2.x advanced patterns:
  custom permission strategies, FFI with Rust/C, Web Workers & structured concurrency,
  Deno KV atomic transactions / watch / queues, Fresh 2.x islands, Deno Deploy edge
  functions & cron, testing strategies (mocking, snapshots, BDD), performance profiling,
  WASM integration.

- **[troubleshooting.md](references/troubleshooting.md)** — Debugging common Deno issues:
  Node.js compatibility gaps (incomplete `node:*` polyfills), npm native-addon packages,
  permission denied debugging, import map resolution, lock file conflicts, deno.json vs
  package.json conflicts, TypeScript strict mode errors, Deploy cold start optimization,
  KV consistency gotchas, common error messages reference.

- **[migration-guide.md](references/migration-guide.md)** — Complete Node.js → Deno migration:
  package.json → deno.json, require → import, CommonJS → ESM, Express → Hono/Oak/Fresh,
  Jest → Deno.test, dotenv → Deno.env, fs → Deno file APIs, child_process → Deno.Command,
  node_modules → vendor, CI/CD pipeline changes, Docker multi-stage builds, full checklist.

## Scripts

Executable helper scripts in `scripts/`:

- **[scaffold-deno-project.sh](scripts/scaffold-deno-project.sh)** — Scaffolds a Deno project
  with `--type api|fresh|cli|library`. Generates deno.json, tasks, directory structure, starter
  code, and tests. Usage: `./scripts/scaffold-deno-project.sh my-project --type api`

- **[migrate-from-node.sh](scripts/migrate-from-node.sh)** — Analyzes a Node.js project and
  generates a migration checklist. Detects frameworks, problematic deps, CommonJS usage,
  bare built-in imports. Optionally generates deno.json with `--apply`.
  Usage: `./scripts/migrate-from-node.sh /path/to/node-project --apply`

- **[deno-deploy.sh](scripts/deno-deploy.sh)** — Deploys to Deno Deploy with pre-deploy
  type-checking, env var setup, and post-deploy health checks.
  Usage: `./scripts/deno-deploy.sh --project my-api --production`

## Assets & Templates

Ready-to-use project templates in `assets/`:

- **[deno-api-template/](assets/deno-api-template/)** — Hono-based REST API template:
  - `main.ts` — Full CRUD API with validation, error handling, pagination
  - `deno.json` — Config with tasks (dev, start, test, lint, compile)
  - `Dockerfile` — Multi-stage build (deps → build → runtime, non-root user)

- **[fresh-app-template/](assets/fresh-app-template/)** — Fresh framework app template:
  - `main.ts` — Fresh app entry point
  - `deno.json` — Config with Preact JSX, tasks
  - `routes/index.tsx` — Server-rendered home page
  - `islands/Counter.tsx` — Interactive island component
<!-- tested: pass -->
