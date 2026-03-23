---
name: deno-patterns
description:
  positive: "Use when user works with Deno runtime, asks about deno.json, Deno permissions, npm: specifiers, jsr: registry, Deno.serve, Fresh framework, Deno Deploy, or migrating from Node to Deno."
  negative: "Do NOT use for Node.js (use node-streams skill), Bun runtime, or browser JavaScript."
---

# Deno 2 Runtime Patterns and Best Practices

## Fundamentals

Deno 2 is a secure TypeScript/JavaScript runtime built on V8 with first-class TypeScript support — no transpilation step required. Key traits:

- Single executable ships with formatter, linter, test runner, bundler, LSP, and documentation generator.
- Secure by default: all system access denied unless explicitly granted via permission flags.
- Native ES modules only (no CommonJS in Deno code). Supports top-level `await`.
- Ships Web Platform APIs (fetch, Request, Response, WebSocket, crypto, streams).
- Full npm compatibility via `npm:` specifiers. Supports `package.json` alongside `deno.json`.

## deno.json Configuration

Use `deno.json` (or `deno.jsonc`) as the single config source. It replaces tsconfig, import maps, and npm scripts.

```jsonc
{
  "imports": {
    "@std/http": "jsr:@std/http@^1.0.0",
    "@std/assert": "jsr:@std/assert@^1.0.0",
    "express": "npm:express@^4.21.0",
    "@/": "./src/"
  },
  "tasks": {
    "dev": "deno run --watch --allow-net --allow-read src/main.ts",
    "test": "deno test --allow-env --allow-read",
    "lint": "deno lint",
    "fmt": "deno fmt"
  },
  "compilerOptions": {
    "strict": true,
    "jsx": "react-jsx",
    "jsxImportSource": "preact"
  },
  "fmt": {
    "useTabs": false,
    "lineWidth": 100,
    "indentWidth": 2,
    "singleQuote": true,
    "include": ["src/"],
    "exclude": ["dist/"]
  },
  "lint": {
    "include": ["src/"],
    "rules": {
      "tags": ["recommended"],
      "exclude": ["no-unused-vars"]
    }
  },
  "lock": true,
  "nodeModulesDir": "auto",
  "vendor": true
}
```

Key fields:
- `imports` — bare specifier map (replaces separate import_map.json).
- `tasks` — named commands run via `deno task <name>`.
- `lock` — generate/check deno.lock for integrity. Always use in production.
- `vendor` — cache remote deps locally for offline builds.
- `nodeModulesDir` — set to `"auto"` to create node_modules when npm deps exist.
- `compilerOptions` — same as tsconfig fields.

## Module System

### Import Styles

```ts
// JSR registry (preferred for Deno-native packages)
import { join } from "jsr:@std/path@^1.0.0";

// npm specifier (any npm package)
import express from "npm:express@4";

// Node built-in compat
import { readFileSync } from "node:fs";
import { EventEmitter } from "node:events";

// URL import (pinned, less common in Deno 2)
import { serve } from "https://deno.land/std@0.224.0/http/server.ts";

// Local imports (use path aliases from import map)
import { handler } from "@/handlers/api.ts";
```

### Import Map in deno.json

Map bare specifiers to concrete URLs, npm, or jsr modules in the `"imports"` field. Use `@/` prefix for project-internal aliases. Add entries via CLI:

```sh
deno add @std/fs           # adds jsr:@std/fs to imports
deno add npm:lodash        # adds npm:lodash to imports
```

### JSR Registry

Publish and consume TypeScript-first packages at `jsr.io`. Packages under `@std/` are the official Deno standard library. JSR modules work in Deno, Node.js, and Bun.

## Permissions

Deno denies all system access by default. Grant with `--allow-*`, deny overrides with `--deny-*`.

```sh
deno run --allow-read=./data,./config --allow-net=api.example.com main.ts  # granular
deno run --allow-read --deny-read=./secrets main.ts                        # deny within allow

--allow-read[=paths]      # File system read
--allow-write[=paths]     # File system write
--allow-net[=hosts]       # Network access
--allow-env[=vars]        # Environment variables
--allow-run[=cmds]        # Subprocess execution
--allow-ffi               # Foreign function interface
--allow-sys               # System info
--allow-all               # All permissions (dev only)
```

### Permission Sets in deno.json (Deno 2.5+)

```jsonc
{
  "permissions": {
    "server": {
      "read": ["./static", "./templates"],
      "net": ["0.0.0.0:8000"],
      "env": ["DATABASE_URL"]
    }
  },
  "tasks": {
    "serve": "deno run -P=server src/main.ts"
  }
}
```

Check permissions at runtime:

```ts
const status = await Deno.permissions.query({ name: "read", path: "./data" });
if (status.state === "granted") {
  const data = await Deno.readTextFile("./data/config.json");
}
```

## Standard Library (@std/)

All `@std/` modules live on JSR. Add via `deno add @std/<module>`.

```ts
// Path manipulation
import { join, resolve, extname } from "@std/path";

// File system utilities
import { ensureDir, copy, walk } from "@std/fs";

// Assertions (testing)
import { assertEquals, assertThrows, assertRejects } from "@std/assert";

// Async utilities
import { delay, deadline, retry } from "@std/async";

// Streams
import { toText, toBlob, readAll } from "@std/streams";

// HTTP helpers
import { serveDir, serveFile } from "@std/http/file-server";

// UUID, encoding, formatting
import { v4 } from "@std/uuid";
import { encodeBase64 } from "@std/encoding/base64";
```

## HTTP Server (Deno.serve)

Use `Deno.serve` for high-performance HTTP. It uses web-standard Request/Response.

```ts
Deno.serve({ port: 8000 }, async (req: Request): Promise<Response> => {
  const url = new URL(req.url);

  if (url.pathname === "/api/health") {
    return Response.json({ status: "ok" });
  }

  if (url.pathname === "/api/data" && req.method === "POST") {
    const body = await req.json();
    return Response.json({ received: body }, { status: 201 });
  }

  return new Response("Not Found", { status: 404 });
});
```

### Streaming SSE Response

```ts
Deno.serve((_req) => {
  const body = new ReadableStream({
    start(controller) {
      const enc = new TextEncoder();
      let i = 0;
      const id = setInterval(() => {
        controller.enqueue(enc.encode(`data: tick ${i++}\n\n`));
        if (i > 5) { clearInterval(id); controller.close(); }
      }, 1000);
    },
  });
  return new Response(body, { headers: { "content-type": "text/event-stream" } });
});
```

## Fresh Framework

Fresh is Deno's full-stack web framework using Preact, islands architecture, and file-based routing. Zero build step; TypeScript compiled on the fly.

### Project Structure

```
routes/           # File-based routing (maps to URLs)
  index.tsx       # GET /
  api/data.ts     # API route (no UI)
  [slug].tsx      # Dynamic route
islands/          # Interactive components (JS shipped to client)
  Counter.tsx
components/       # Server-only components (no JS shipped)
static/           # Static assets
main.ts           # Entry point
dev.ts            # Dev server with HMR
```

### Route Handler

```ts
// routes/api/users.ts
import { Handlers } from "$fresh/server.ts";

export const handler: Handlers = {
  async GET(_req, ctx) {
    const users = await fetchUsers();
    return Response.json(users);
  },
  async POST(req, _ctx) {
    const body = await req.json();
    const user = await createUser(body);
    return Response.json(user, { status: 201 });
  },
};
```

### Island Component

```tsx
// islands/Counter.tsx
import { useSignal } from "@preact/signals";

export default function Counter(props: { start: number }) {
  const count = useSignal(props.start);
  return (
    <div>
      <p>Count: {count}</p>
      <button onClick={() => count.value++}>+1</button>
    </div>
  );
}
```

### Page with Island

```tsx
// routes/index.tsx
import Counter from "../islands/Counter.tsx";

export default function Home() {
  return (
    <main>
      <h1>Welcome</h1>
      <Counter start={0} />  {/* Only this ships JS */}
    </main>
  );
}
```

## Deno KV

Built-in key-value store. Works locally (SQLite-backed) and on Deno Deploy (globally replicated).

```ts
const kv = await Deno.openKv();

// Set a value
await kv.set(["users", "u123"], { name: "Alice", role: "admin" });

// Get a value
const entry = await kv.get<{ name: string }>(["users", "u123"]);
console.log(entry.value?.name); // "Alice"

// List by prefix
const iter = kv.list<{ name: string }>({ prefix: ["users"] });
for await (const entry of iter) {
  console.log(entry.key, entry.value);
}

// Delete
await kv.delete(["users", "u123"]);
```

### Atomic Operations

```ts
const kv = await Deno.openKv();

// Atomic check-and-set (optimistic concurrency)
const entry = await kv.get(["counters", "visits"]);
const res = await kv.atomic()
  .check(entry) // fails if value changed since read
  .set(["counters", "visits"], (entry.value as number ?? 0) + 1)
  .commit();

if (!res.ok) console.log("Conflict — retry");
```

### KV Queues

```ts
const kv = await Deno.openKv();

// Enqueue a message
await kv.enqueue({ type: "email", to: "user@example.com" });

// Listen for messages
kv.listenQueue(async (msg: { type: string; to: string }) => {
  if (msg.type === "email") await sendEmail(msg.to);
});
```

### KV Watch

```ts
const kv = await Deno.openKv();
const stream = kv.watch([["config", "theme"]]);
for await (const entries of stream) {
  console.log("Config changed:", entries[0].value);
}
```

## npm Compatibility

### Importing npm Packages

```ts
import chalk from "npm:chalk@5";      // Direct specifier (no install step)
import { z } from "npm:zod@3";
// Or map in deno.json imports: { "zod": "npm:zod@^3.22.0" }
import { z } from "zod";              // Then use bare specifier
```

Deno reads `package.json` if present. Set `nodeModulesDir: "auto"` in `deno.json` when npm packages need node_modules (e.g., Prisma).

### Limitations

- Native C++ addons may not work or need `--allow-ffi`.
- CommonJS-only packages work but edge cases may need `createRequire`.
- Webpack/Babel plugins do not run in Deno.

## Testing

```ts
import { assertEquals, assertThrows, assertRejects } from "@std/assert";

// Basic test
Deno.test("addition works", () => {
  assertEquals(2 + 2, 4);
});

// Async test
Deno.test("fetch returns 200", async () => {
  const res = await fetch("https://example.com");
  assertEquals(res.status, 200);
});

// Test with permissions
Deno.test({ name: "read file", permissions: { read: true } }, async () => {
  const text = await Deno.readTextFile("./test-data/sample.txt");
  assertEquals(text.includes("hello"), true);
});

// Subtests (BDD-style)
Deno.test("math operations", async (t) => {
  await t.step("multiply", () => assertEquals(3 * 4, 12));
  await t.step("divide", () => assertEquals(10 / 2, 5));
});

// Snapshot testing
import { assertSnapshot } from "@std/testing/snapshot";
Deno.test("snapshot", async (t) => {
  await assertSnapshot(t, { key: "value" });
});
```

Run tests:

```sh
deno test                              # all tests
deno test --filter "math"              # filter by name
deno test --coverage=./cov             # collect coverage
deno coverage ./cov --lcov > cov.lcov  # export lcov report
```

## Deno Deploy

Serverless edge platform for Deno. Zero config, sub-50ms cold starts, no containers.

- Automatic deployments from GitHub push. Preview deployments on every PR.
- Supports `Deno.serve`, Deno KV (globally replicated), Web Crypto, and fetch.

### Deploy-Ready Server

```ts
const kv = await Deno.openKv(); // SQLite locally, global replicated on Deploy

Deno.serve(async (req) => {
  if (new URL(req.url).pathname === "/visit") {
    await kv.atomic().sum(["visits"], 1n).commit();
    const entry = await kv.get(["visits"]);
    return Response.json({ visits: entry.value });
  }
  return new Response("Hello from the edge!");
});
```

Deploy via CLI: `deployctl deploy --project=my-app --prod main.ts`

## CLI Tools

```sh
deno compile --allow-net src/server.ts       # AOT compile to single binary
deno install --global jsr:@std/http/file-server  # install global CLI tool
deno bench bench/*.ts                        # run benchmarks
deno doc src/lib.ts                          # generate docs from JSDoc
deno jupyter --install                       # Deno Jupyter kernel
deno publish                                 # publish to JSR
deno info main.ts                            # show dependency tree
```

### Benchmarking

```ts
Deno.bench("string concat", () => { let s = ""; for (let i = 0; i < 1000; i++) s += "x"; });
Deno.bench("array join", () => { const a: string[] = []; for (let i = 0; i < 1000; i++) a.push("x"); a.join(""); });
```

## FFI (Foreign Function Interface)

Call C/Rust shared libraries via `Deno.dlopen`. Requires `--allow-ffi --unstable-ffi`.

```ts
const lib = Deno.dlopen("./libmath.so", {
  add: { parameters: ["i32", "i32"], result: "i32" },
});
console.log(lib.symbols.add(3, 4)); // 7
lib.close();
```

Supported types: `i8`–`i64`, `u8`–`u64`, `f32`, `f64`, `pointer`, `buffer`, `void`.

## Migration from Node.js

### Step-by-Step

1. **Replace require with import** — convert `require()` to ES `import`.
2. **Add npm: prefix** — `import x from "npm:pkg"` or use import map.
3. **Use node: for built-ins** — `import fs from "node:fs"`.
4. **Translate scripts** — move npm scripts to `deno.json` tasks.
5. **Add permissions** — audit which system resources each entry point needs.
6. **Generate lock file** — `deno cache --lock=deno.lock --lock-write main.ts`.

### Common Gotchas

- `__dirname`/`__filename` → use `import.meta.dirname` / `import.meta.filename` (Deno 2+).
- `process.env` → `Deno.env.get("VAR")` or import from `"node:process"`.
- `Buffer` → import from `"node:buffer"` or use `Uint8Array`.
- `setTimeout` returns a number, not a `Timeout` object.
- `.env` files need `--env` flag: `deno run --env main.ts`.

## Anti-Patterns

- **Using `--allow-all` in production.** Specify granular permissions. Use permission sets.
- **Skipping the lock file.** Commit `deno.lock`. Run `deno cache --lock-write` to update.
- **Dynamic imports for everything.** Use static imports for tree shaking and faster startup.
- **Ignoring `deno lint` and `deno fmt`.** Run both in CI. Configure in deno.json.
- **Using `Deno.run` (deprecated).** Use `new Deno.Command()` for subprocesses.
- **Importing from `deno.land/x` without pinning.** Pin versions or migrate to JSR.
- **Reaching for Express when `Deno.serve` suffices.** A simple router covers most API needs.
- **Storing secrets in deno.json.** Use env variables with `--allow-env=SPECIFIC_VAR`.
