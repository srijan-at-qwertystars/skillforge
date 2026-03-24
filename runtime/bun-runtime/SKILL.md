---
name: bun-runtime
description: >
  Use when using Bun as a JavaScript/TypeScript runtime, package manager, bundler, or test runner,
  building HTTP servers with Bun.serve, using Bun shell scripting, or migrating from Node.js to Bun.
  Also use for Bun-specific APIs like Bun.file, Bun.write, bun:sqlite, bun:ffi, Bun.$, and
  Bun.env. Covers installation, configuration, Docker deployment, and performance optimization.
  Do NOT use for Node.js-specific APIs without Bun, Deno runtime, browser JavaScript, or general
  npm/yarn package management without Bun.
---

# Bun Runtime Skill

## Installation

Install Bun via the official script or package managers:

```bash
# macOS / Linux
curl -fsSL https://bun.sh/install | bash

# Homebrew
brew install oven-sh/bun/bun

# npm (global)
npm install -g bun

# Windows (PowerShell)
powershell -c "irm bun.sh/install.ps1 | iex"

# Upgrade
bun upgrade
```

Initialize a new project with `bun init`. This creates `package.json`, `tsconfig.json`, and an entry file.

## Runtime: Running TypeScript and JavaScript

Run any `.ts`, `.tsx`, `.js`, `.jsx` file directly — no transpiler configuration needed:

```bash
bun run index.ts
bun run app.jsx
```

Key runtime features:
- **TypeScript and JSX** transpiled on the fly using JavaScriptCore. No `tsc` build step required.
- **Top-level await** supported by default.
- **ESM and CommonJS** both supported. Use `import`/`export` or `require()`.
- **`bun run <script>`** executes `package.json` scripts 30x faster than `npm run`.
- Install `@types/bun` for full type definitions in editors.

## Bun.serve(): HTTP Server and WebSocket

Create high-performance HTTP servers with `Bun.serve()`:

```typescript
const server = Bun.serve({
  port: 3000,
  fetch(req) {
    const url = new URL(req.url);
    if (url.pathname === "/api") {
      return Response.json({ message: "hello" });
    }
    return new Response("Not Found", { status: 404 });
  },
});
console.log(`Listening on ${server.url}`);
```

### Streaming Responses

```typescript
Bun.serve({
  fetch(req) {
    const stream = new ReadableStream({
      start(controller) {
        controller.enqueue("chunk 1\n");
        controller.enqueue("chunk 2\n");
        controller.close();
      },
    });
    return new Response(stream, { headers: { "Content-Type": "text/plain" } });
  },
});
```

### WebSocket Support

Declare a `websocket` handler alongside `fetch`. Upgrade HTTP requests to WebSocket in `fetch`:

```typescript
Bun.serve({
  fetch(req, server) {
    if (new URL(req.url).pathname === "/ws") {
      if (server.upgrade(req, { data: { userId: "abc" } })) return;
      return new Response("Upgrade failed", { status: 500 });
    }
    return new Response("OK");
  },
  websocket: {
    open(ws) { console.log("connected", ws.data.userId); },
    message(ws, msg) { ws.send(`echo: ${msg}`); },
    close(ws, code, reason) { console.log("closed", code); },
  },
});
```

### TLS

Pass `tls` option with `key` and `cert` (as file paths or `BunFile`):

```typescript
Bun.serve({
  port: 443,
  tls: { key: Bun.file("key.pem"), cert: Bun.file("cert.pem") },
  fetch(req) { return new Response("Secure"); },
});
```

### Static File Routes

Use the `static` option to serve pre-rendered responses at specific paths:

```typescript
Bun.serve({
  static: {
    "/": new Response(await Bun.file("public/index.html").text(), {
      headers: { "Content-Type": "text/html" },
    }),
  },
  fetch(req) { return new Response("Fallback"); },
});
```

## Package Manager

Bun's package manager is a drop-in npm replacement, 30x faster:

```bash
bun install              # Install all dependencies
bun add express          # Add a dependency
bun add -d vitest        # Add dev dependency
bun remove lodash        # Remove a dependency
bun update               # Update all packages
bun add --exact react    # Pin exact version
```

- **Lockfile**: `bun.lock` (text-based). Commit to version control.
- **Workspaces**: Declare in `package.json` with `"workspaces": ["packages/*"]`.
- **Overrides**: Use `"overrides"` in `package.json` to force dependency versions.
- **Global cache**: Packages are cached globally; installs hardlink from cache.
- **`bunfig.toml`**: Configure registry, scopes, install behavior.

```toml
# bunfig.toml
[install]
peer = false
optional = true

[install.scopes]
"@myorg" = { token = "$NPM_TOKEN", url = "https://npm.myorg.com/" }
```

## Bundler: bun build

Bundle JavaScript/TypeScript for browser, Bun, or Node targets:

```bash
bun build ./src/index.ts --outdir ./dist
bun build ./src/index.ts --outdir ./dist --target browser --minify
bun build ./src/index.ts --outdir ./dist --splitting --sourcemap=external
```

Programmatic API:

```typescript
const result = await Bun.build({
  entrypoints: ["./src/index.ts"],
  outdir: "./dist",
  target: "browser",   // "browser" | "bun" | "node"
  splitting: true,
  sourcemap: "external",
  minify: true,
  plugins: [myPlugin],
});
if (!result.success) {
  console.error(result.logs);
}
```

Targets: `browser` (default, Web APIs), `bun` (Bun APIs), `node` (Node.js APIs).

## Test Runner: bun test

Jest-compatible test runner with first-class TypeScript support:

```bash
bun test                     # Run all tests
bun test --watch             # Watch mode
bun test --coverage          # Coverage report
bun test --timeout 10000     # Custom timeout
bun test tests/auth.test.ts  # Specific file
```

Write tests using `describe`, `it`/`test`, and `expect`:

```typescript
import { describe, it, expect, beforeAll, afterEach, mock } from "bun:test";

describe("math", () => {
  it("adds numbers", () => {
    expect(2 + 2).toBe(4);
  });

  it("handles async", async () => {
    const result = await Promise.resolve(42);
    expect(result).toBeGreaterThan(0);
  });
});
```

### Mocking

```typescript
import { mock } from "bun:test";

const fn = mock((x: number) => x * 2);
fn(3);
expect(fn).toHaveBeenCalledWith(3);
expect(fn.mock.calls).toHaveLength(1);

// Module mocking
mock.module("./db", () => ({ query: mock(() => []) }));
```

### Snapshots

```typescript
it("matches snapshot", () => {
  expect({ name: "bun", version: 1 }).toMatchSnapshot();
});
```

### DOM Testing with happy-dom

Install `happy-dom`, then add to `bunfig.toml`:

```toml
[test]
preload = ["happy-dom"]
```

## Bun Shell (Bun.$)

Cross-platform shell scripting in JavaScript/TypeScript:

```typescript
import { $ } from "bun";

// Run commands — stdout is captured
const result = await $`ls -la`.text();

// Interpolation is safe (auto-escaped)
const name = "my file.txt";
await $`cat ${name}`;

// Pipe commands
const count = await $`find . -name "*.ts" | wc -l`.text();

// Check exit code
const { exitCode } = await $`grep -r "TODO" src/`.nothrow();

// Environment variables
await $`echo $HOME`;

// Redirect output
await $`echo "hello" > output.txt`;
```

Use `$.cwd()` to set working directory. Use `.quiet()` to suppress output. Use `.nothrow()` to prevent throwing on non-zero exit codes.

## File I/O

### Bun.file() — Lazy File Reference

```typescript
const file = Bun.file("data.json");
console.log(file.size);                    // Bytes
console.log(file.type);                    // MIME type
const exists = await file.exists();

const text = await file.text();            // Read as string
const json = await file.json();            // Parse JSON
const bytes = await file.bytes();          // Uint8Array
const buf = await file.arrayBuffer();      // ArrayBuffer
```

### Bun.write() — Write Files

```typescript
await Bun.write("output.txt", "Hello Bun");
await Bun.write("data.json", JSON.stringify(data, null, 2));
await Bun.write("copy.txt", Bun.file("original.txt"));   // Copy file
await Bun.write("bin.dat", new Uint8Array([0xDE, 0xAD])); // Binary
```

### Glob

```typescript
const glob = new Bun.Glob("**/*.ts");
for await (const path of glob.scan({ cwd: "./src" })) {
  console.log(path);
}
```

## SQLite (bun:sqlite)

Built-in, zero-dependency SQLite with synchronous API:

```typescript
import { Database } from "bun:sqlite";

const db = new Database("app.db");
db.run("PRAGMA journal_mode = WAL");  // Enable WAL for concurrency

db.run("CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY, name TEXT, email TEXT)");

// Prepared statements
const insert = db.prepare("INSERT INTO users (name, email) VALUES (?, ?)");
insert.run("Alice", "alice@example.com");

const find = db.prepare("SELECT * FROM users WHERE email = ?");
const user = find.get("alice@example.com");

const all = db.prepare("SELECT * FROM users").all();

// Transactions
const insertMany = db.transaction((users: { name: string; email: string }[]) => {
  for (const u of users) insert.run(u.name, u.email);
});
insertMany([{ name: "Bob", email: "bob@b.com" }, { name: "Carol", email: "carol@c.com" }]);
```

Use `.as(MyClass)` to return typed instances. Use `:memory:` for in-memory databases.

## FFI (bun:ffi)

Call native C/Zig/Rust shared libraries from JavaScript:

```typescript
import { dlopen, FFIType, suffix } from "bun:ffi";

const lib = dlopen(`./libmath.${suffix}`, {
  add: { args: [FFIType.i32, FFIType.i32], returns: FFIType.i32 },
});

console.log(lib.symbols.add(2, 3)); // 5
lib.close();
```

Supported types: `i8`, `i16`, `i32`, `i64`, `u8`, `u16`, `u32`, `u64`, `f32`, `f64`, `ptr`, `cstring`, `void`. Use `suffix` for platform-correct extension (`.so`, `.dylib`, `.dll`).

## Node.js Compatibility

Bun implements most Node.js built-in modules:
- **Fully supported**: `fs`, `path`, `os`, `crypto`, `http`, `https`, `net`, `url`, `util`, `events`, `stream`, `buffer`, `child_process`, `assert`, `querystring`, `string_decoder`, `zlib`, `tty`, `readline`
- **Partially supported**: `worker_threads`, `cluster`, `dgram`, `dns`
- Import via `node:` prefix or bare specifier: `import fs from "node:fs"`.
- Most npm packages work unchanged. Run `bun install && bun run start` on existing Node.js projects.

## Environment Variables

Bun loads `.env` files automatically in this order: `.env.local`, `.env.development`/`.env.production` (based on `NODE_ENV`), `.env`.

```typescript
const dbUrl = Bun.env.DATABASE_URL;         // Read env var
const port = Bun.env.PORT ?? "3000";

// process.env also works
const secret = process.env.SECRET_KEY;
```

Use `--env-file=.env.custom` to load a specific env file.

## Hot Reloading

Two modes for development:

```bash
bun --watch run index.ts   # Hard restart on file change
bun --hot run index.ts     # Soft reload, preserves state
```

- **`--watch`**: Restarts the entire process when imported files change. Use for CLI tools, scripts.
- **`--hot`**: Reloads modules without restarting. `Bun.serve()` handlers update in place. Use for HTTP servers.

## Macros

Execute code at bundle-time (compile-time code execution):

```typescript
// fetch-version.ts (the macro)
export function getVersion(): string {
  return "1.2.3"; // evaluated at build time, inlined as constant
}

// app.ts (consumer)
import { getVersion } from "./fetch-version" with { type: "macro" };
console.log(getVersion()); // Inlined at build time
```

Macros run during bundling. Return values must be serializable. Use for build-time constants, code generation, and embedding static data.

## Plugins

Extend Bun's module resolution and loading:

```typescript
// preload.ts
import { plugin } from "bun";

plugin({
  name: "yaml-loader",
  setup(build) {
    const { load } = require("js-yaml");
    build.onLoad({ filter: /\.yaml$/ }, async (args) => {
      const text = await Bun.file(args.path).text();
      return { contents: `export default ${JSON.stringify(load(text))}`, loader: "js" };
    });
  },
});
```

Register plugins via `bunfig.toml`:

```toml
preload = ["./preload.ts"]
```

Plugins can intercept `onLoad` and `onResolve` for custom file types and module resolution.

## Performance

- **Startup**: Bun starts 4x faster than Node.js due to JavaScriptCore and native code.
- **Install**: `bun install` is up to 30x faster than `npm install` using global cache and hardlinks.
- **HTTP**: `Bun.serve()` handles significantly more requests/sec than Node.js `http` module.
- **Memory**: Lower baseline memory usage than Node.js.
- **Bundling**: `bun build` is faster than esbuild and webpack for most workloads.

Optimize further:
- Use `Bun.serve()` over Express/Koa for raw performance.
- Prefer `bun:sqlite` synchronous API over async database drivers for single-server workloads.
- Use `Bun.file()` / `Bun.write()` instead of `fs` for I/O — they use optimized system calls.
- Use `--smol` flag to reduce memory usage at the cost of some performance.

## Docker Deployment

Use the official `oven/bun` image. See [assets/Dockerfile](assets/Dockerfile) for a full multi-stage production template.

```dockerfile
FROM oven/bun:1
WORKDIR /app
COPY package.json bun.lock ./
RUN bun install --frozen-lockfile --production
COPY . .
USER bun
EXPOSE 3000
CMD ["bun", "run", "src/index.ts"]
```

## Common Patterns and Best Practices

- **Project init**: `bun init` scaffolds `package.json`, `tsconfig.json`, entry file.
- **Scripts**: Define in `package.json`, run with `bun run <name>`. Faster than `npm run`.
- **Executable scripts**: Use `#!/usr/bin/env bun` shebang for CLI tools.
- **Monorepos**: Use `workspaces` in `package.json`. `bun install` links workspace packages.
- **Migrate from Node.js**: Replace `node` with `bun`, `npm` with `bun`. See [migration guide](references/migration-guide.md).
- **Error handling**: `Bun.serve()` supports `error(err)` handler for uncaught errors.
- **Graceful shutdown**: Listen for `process.on("SIGTERM")` and call `server.stop()`.
- **Prefer `bun:` imports**: Use `bun:sqlite`, `bun:test`, `bun:ffi` for built-in modules.
- **Use `bunfig.toml`** for project-level Bun configuration (test settings, plugins, install options).

## References

- **[references/advanced-patterns.md](references/advanced-patterns.md)** — Bun.serve (WebSocket pub/sub, SSE, HTTP/2, graceful shutdown, clustering), Bun Shell deep dive, bundler plugins, Bun.build (tree shaking, code splitting, CSS), test runner advanced, bun:sqlite (transactions, FTS5, migrations), bun:ffi, Bun.password/CryptoHasher, S3 client, Semver API.
- **[references/troubleshooting.md](references/troubleshooting.md)** — npm compatibility (native modules, node-gyp), Node.js API gaps, bundler vs runtime differences, TypeScript gotchas, lockfile conflicts, memory leaks, Docker optimization, CI/CD, Express migration pitfalls.
- **[references/migration-guide.md](references/migration-guide.md)** — Node.js → Bun: npm→bun, npx→bunx, Jest→bun test, webpack→bun build, Express→Bun.serve/Hono/Elysia, fs→Bun.file, crypto→Bun.password, worker_threads→Web Workers, child_process→Bun.$, dotenv removal, tsconfig, Docker, step-by-step checklist.

## Scripts

- **[scripts/scaffold-bun-project.sh](scripts/scaffold-bun-project.sh)** — Scaffold a Bun project (`--type api|cli|library|fullstack`, `--framework hono|elysia|none`).
- **[scripts/migrate-from-node.sh](scripts/migrate-from-node.sh)** — Analyze a Node.js project for Bun compatibility, generate migration checklist.
- **[scripts/bun-benchmark.sh](scripts/bun-benchmark.sh)** — Benchmark Bun vs Node.js (startup, file I/O, JSON, crypto, HTTP, install).

## Assets

- **[assets/bunfig.toml](assets/bunfig.toml)** — Production-ready Bun configuration template.
- **[assets/server.ts](assets/server.ts)** — Bun.serve template with WebSocket, static files, CORS, graceful shutdown.

<!-- tested: pass -->
