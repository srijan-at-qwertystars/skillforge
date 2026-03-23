---
name: bun-runtime
description: >
  Expert guide for building applications with the Bun JavaScript/TypeScript runtime.
  TRIGGER when: user mentions Bun, bun install, bun add, bun test, bun build, Bun.serve,
  Bun.file, Bun.write, bun:sqlite, bun:ffi, bun:test, Bun.$, bunfig.toml, bunx,
  bun run, bun --hot, bun --watch, bun build --compile, or migrating from Node.js to Bun.
  DO NOT TRIGGER when: user works with Node.js without mentioning Bun, uses Deno exclusively,
  uses generic npm/yarn/pnpm without Bun context, or discusses browser-only JavaScript.
---

# Bun Runtime

## Architecture

Bun is an all-in-one JavaScript/TypeScript toolkit written in Zig with a C++ layer, powered by Apple's JavaScriptCore (JSC) engine — not V8. It unifies runtime, package manager, bundler, and test runner into a single binary.

Key architectural facts:
- JSC compiles JS to native machine code; startup is faster than V8-based runtimes.
- Zig's manual memory management eliminates GC pauses in the runtime layer.
- Single binary: `bun` replaces `node`, `npm`, `npx`, `jest`, `webpack`, `esbuild`.
- Native support for TypeScript, JSX, and TSX — no transpilation step needed.
- Bun reads `tsconfig.json` and applies settings automatically.

## Package Manager

Bun's package manager is a drop-in replacement for npm/yarn/pnpm, 10-30x faster.

```sh
bun install              # Install all deps from package.json
bun add zod              # Add dependency
bun add -d vitest        # Add dev dependency
bun add -g typescript    # Add global package
bun remove express       # Remove dependency
bun update               # Update all deps
bunx create-next-app     # Execute package binary (like npx)
```

### Lockfile

Bun uses a binary lockfile `bun.lockb` for speed. Generate a text lockfile with:

```sh
bun install --yarn       # Produces yarn.lock alongside bun.lockb
```

### bunfig.toml

Configure Bun behavior in `bunfig.toml` at project root:

```toml
[install]
registry = "https://registry.npmjs.org/"

[install.scopes]
"@myorg" = { token = "$NPM_TOKEN", url = "https://npm.pkg.github.com/" }

[test]
coverage = true
coverageReporter = ["text", "lcov"]

[run]
# Shell to use for package.json scripts
shell = "bun"
```

### Workspaces

Declare in `package.json` — identical to npm/yarn:

```json
{
  "workspaces": ["packages/*", "apps/*"]
}
```

Run `bun install` at root. All workspace packages are symlinked automatically.

## Bundler

```sh
bun build ./src/index.ts --outdir ./dist
bun build ./src/index.ts --outfile ./dist/bundle.js --minify
bun build ./src/index.ts --target browser --splitting --format esm
bun build ./src/index.ts --target node --format cjs
bun build ./src/index.ts --target bun         # Bun-optimized output
```

### Bundler API (programmatic)

```ts
const result = await Bun.build({
  entrypoints: ["./src/index.ts"],
  outdir: "./dist",
  minify: true,
  splitting: true,
  format: "esm",
  target: "browser",            // "browser" | "node" | "bun"
  sourcemap: "external",        // "none" | "inline" | "external"
  external: ["fsevents"],       // Exclude from bundle
  naming: "[name]-[hash].[ext]",
  plugins: [myPlugin],
});

if (!result.success) {
  for (const log of result.logs) console.error(log);
}
```

### Bundler Plugins

```ts
import type { BunPlugin } from "bun";

const yamlPlugin: BunPlugin = {
  name: "yaml-loader",
  setup(build) {
    build.onLoad({ filter: /\.ya?ml$/ }, async (args) => {
      const text = await Bun.file(args.path).text();
      const yaml = await import("js-yaml");
      return { exports: { default: yaml.load(text) }, loader: "object" };
    });
  },
};
```

## Standalone Executables & Cross-Compilation

Compile TypeScript/JavaScript into a single portable binary:

```sh
bun build --compile ./cli.ts --outfile mycli
./mycli   # Runs without Bun installed
```

Cross-compile for other platforms:

```sh
bun build --compile --target=bun-linux-x64 ./cli.ts --outfile mycli-linux
bun build --compile --target=bun-windows-x64 ./cli.ts --outfile mycli.exe
bun build --compile --target=bun-darwin-arm64 ./cli.ts --outfile mycli-mac
bun build --compile --target=bun-linux-x64-baseline ./cli.ts --outfile mycli-compat
```

Supported targets: `bun-{linux,darwin,windows}-{x64,arm64}`. Append `-baseline` for older CPUs. Binaries are ~90MB (includes Bun runtime).

## Test Runner

Bun has a built-in Jest-compatible test runner. Test files: `*.test.{ts,tsx,js,jsx}` or `*_test.*` or files in `__tests__/`.

```sh
bun test                        # Run all tests
bun test src/auth                # Run tests in directory
bun test --watch                 # Re-run on file changes
bun test --coverage              # Generate coverage report
bun test --timeout 10000         # Set timeout (ms)
bun test --update-snapshots      # Update snapshot files
bun test --preload ./setup.ts    # Run setup before tests
```

### Writing Tests

```ts
import { describe, test, expect, beforeAll, afterEach, mock, spyOn } from "bun:test";

describe("math", () => {
  test("adds numbers", () => {
    expect(1 + 2).toBe(3);
  });

  test("objects", () => {
    expect({ a: 1 }).toEqual({ a: 1 });
    expect([1, 2, 3]).toContain(2);
    expect("hello").toMatch(/ell/);
  });

  test("async", async () => {
    const val = await Promise.resolve(42);
    expect(val).toBe(42);
  });

  test("throws", () => {
    expect(() => { throw new Error("fail"); }).toThrow("fail");
  });

  test("snapshots", () => {
    expect({ users: ["alice"] }).toMatchSnapshot();
  });
});
```

### Mocking

```ts
import { mock, spyOn } from "bun:test";

// Mock functions
const fn = mock(() => 42);
fn();
expect(fn).toHaveBeenCalledTimes(1);
expect(fn).toHaveReturnedWith(42);

// Spy on methods
const spy = spyOn(console, "log");
console.log("test");
expect(spy).toHaveBeenCalledWith("test");
spy.mockRestore();

// Mock modules
mock.module("./db", () => ({
  query: mock(() => [{ id: 1 }]),
}));
```

### Lifecycle Hooks

```ts
beforeAll(() => { /* once before all tests in file/describe */ });
beforeEach(() => { /* before each test */ });
afterEach(() => { /* after each test */ });
afterAll(() => { /* once after all tests */ });
```

Use `--preload` for global setup across all test files.

## HTTP Server

`Bun.serve()` creates a high-performance HTTP server built on uWebSockets.

```ts
const server = Bun.serve({
  port: 3000,
  fetch(req) {
    const url = new URL(req.url);
    if (url.pathname === "/") return new Response("Hello!");
    if (url.pathname === "/json") {
      return Response.json({ ok: true });
    }
    return new Response("Not Found", { status: 404 });
  },
});
console.log(`Listening on ${server.url}`);
```

### Streaming Responses

```ts
Bun.serve({
  fetch(req) {
    const stream = new ReadableStream({
      async start(controller) {
        for (const chunk of ["Hello ", "World"]) {
          controller.enqueue(new TextEncoder().encode(chunk));
          await Bun.sleep(100);
        }
        controller.close();
      },
    });
    return new Response(stream, {
      headers: { "Content-Type": "text/plain" },
    });
  },
});
```

### WebSocket Server

```ts
Bun.serve({
  port: 3000,
  fetch(req, server) {
    if (new URL(req.url).pathname === "/ws") {
      if (server.upgrade(req, { data: { userId: "abc" } })) return;
      return new Response("Upgrade failed", { status: 500 });
    }
    return new Response("OK");
  },
  websocket: {
    open(ws) { ws.subscribe("chat"); },
    message(ws, msg) { ws.publish("chat", msg); },
    close(ws) { ws.unsubscribe("chat"); },
    drain(ws) { /* backpressure relieved */ },
  },
});
```

WebSocket features: pub/sub topics, per-connection `ws.data`, permessage-deflate compression, binary/text messages.

### TLS

```ts
Bun.serve({
  port: 443,
  tls: {
    cert: Bun.file("./cert.pem"),
    key: Bun.file("./key.pem"),
  },
  fetch(req) { return new Response("Secure!"); },
});
```

## File I/O

```ts
// Read files — returns BunFile (lazy, no read until consumed)
const file = Bun.file("./data.json");
const text = await file.text();           // string
const json = await file.json();           // parsed JSON
const buf = await file.arrayBuffer();     // ArrayBuffer
const bytes = await file.bytes();         // Uint8Array
file.size;                                // size in bytes
file.type;                                // MIME type

// Write files
await Bun.write("./out.txt", "hello");
await Bun.write("./copy.png", Bun.file("./original.png"));
await Bun.write("./data.json", JSON.stringify({ ok: true }));
await Bun.write(Bun.stdout, "Print to stdout\n");

// Check existence
const exists = await Bun.file("./maybe.txt").exists();

// Glob
const glob = new Bun.Glob("**/*.ts");
for await (const path of glob.scan(".")) { console.log(path); }
```

## SQLite (bun:sqlite)

Built-in, synchronous, high-performance SQLite. No npm install needed.

```ts
import { Database } from "bun:sqlite";

const db = new Database("app.db");              // file-backed
const mem = new Database(":memory:");           // in-memory

// Create table
db.run("CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY, name TEXT, email TEXT)");

// Insert
db.run("INSERT INTO users (name, email) VALUES (?, ?)", ["Alice", "alice@example.com"]);

// Query — .all() returns array, .get() returns one row, .values() returns arrays
const users = db.query("SELECT * FROM users WHERE name = ?").all("Alice");
// => [{ id: 1, name: "Alice", email: "alice@example.com" }]

// Prepared statements
const stmt = db.prepare("SELECT * FROM users WHERE id = ?");
const user = stmt.get(1);

// Transactions
const insertMany = db.transaction((entries: { name: string; email: string }[]) => {
  for (const e of entries) {
    db.run("INSERT INTO users (name, email) VALUES (?, ?)", [e.name, e.email]);
  }
});
insertMany([{ name: "Bob", email: "bob@b.com" }, { name: "Carol", email: "carol@c.com" }]);

db.close();
```

## Shell Scripting (Bun.$)

Cross-platform shell via tagged template literals. Import from `bun`.

```ts
import { $ } from "bun";

// Simple command
await $`echo "Hello from Bun shell"`;

// Capture output
const result = await $`ls -la`.text();   // stdout as string
const lines = await $`cat file.txt`.lines(); // stdout as string[]

// Interpolation (auto-escaped)
const name = "my project";
await $`mkdir -p ${name}`;

// Piping
await $`cat data.csv | grep "error" | wc -l`;

// Error handling
try {
  await $`exit 1`;
} catch (e) {
  console.error("Command failed:", e.exitCode);
}

// Quiet mode (suppress stdout)
await $`npm install`.quiet();

// Environment variables
await $`echo $HOME`.env({ HOME: "/custom/home" });
```

## TypeScript & JSX

Bun executes `.ts`, `.tsx`, `.jsx` files directly — no `tsc`, no Babel, no build step.

```sh
bun run app.ts        # Just works
bun run Component.tsx # JSX too
```

Configure JSX in `tsconfig.json`:
```json
{ "compilerOptions": { "jsx": "react-jsx", "jsxImportSource": "react" } }
```

Bun reads `tsconfig.json` paths, `baseUrl`, and `compilerOptions` automatically.

## Environment Variables

Bun auto-loads `.env` files in priority order: `.env.local` → `.env.{development,production}` (by `NODE_ENV`) → `.env`.

Access via `process.env` or `Bun.env`:

```ts
const secret = Bun.env.API_KEY;   // preferred — typed
const also = process.env.API_KEY; // also works
```

Override: `bun --env-file=.env.staging run app.ts`.

## Hot Reloading

```sh
bun --watch run server.ts    # Restart process on file changes
bun --hot run server.ts      # Hot-reload without restarting (preserves state)
```

`--watch`: kills and restarts process. Use for servers.
`--hot`: reloads modules in-place. Use for stateful dev servers. Module-level side effects re-execute; top-level state persists via `globalThis`.

## FFI (bun:ffi)

Call native C/C++/Rust shared libraries from JavaScript:

```ts
import { dlopen, FFIType, ptr } from "bun:ffi";

const lib = dlopen("libcrypto.so", {
  RAND_bytes: {
    args: [FFIType.ptr, FFIType.i32],
    returns: FFIType.i32,
  },
});

const buf = new Uint8Array(32);
lib.symbols.RAND_bytes(ptr(buf), 32);
```

Supported types: `i8`, `i16`, `i32`, `i64`, `u8`, `u16`, `u32`, `u64`, `f32`, `f64`, `ptr`, `cstring`, `bool`, `void`.

## Node.js Compatibility

### Fully supported core modules
`assert`, `buffer`, `child_process`, `console`, `crypto`, `dgram`, `dns`, `events`, `fs`, `http`, `https`, `net`, `os`, `path`, `querystring`, `readline`, `stream`, `string_decoder`, `timers`, `tls`, `url`, `util`, `zlib`.

### Partially supported
`http2` (no `pushStream`), `async_hooks` (`AsyncLocalStorage` only), `cluster` (limited), `worker_threads` (no socket handle IPC), `vm` (basic only). See [troubleshooting.md](references/troubleshooting.md) for full matrix.

### Not supported
`node:inspector`, native C++ addons (non-N-API). Use `bun:ffi` or pure-JS alternatives.

### Web APIs available as globals
`fetch`, `Request`, `Response`, `Headers`, `URL`, `WebSocket`, `ReadableStream`, `WritableStream`, `TextEncoder`, `TextDecoder`, `crypto.subtle`, `structuredClone`, `Blob`, `FormData`, `AbortController`.

## Common Pitfalls & Migration Gotchas

1. **Native addons**: C++ addons won't work. Use `bun:sqlite` instead of `better-sqlite3`, `bcryptjs` instead of `bcrypt`.
2. **Lockfile**: `bun.lockb` is binary. Commit it. For text: `bun install --yarn`.
3. **Global installs**: `bun add -g <pkg>` installs to `~/.bun/bin`. Ensure it's in `$PATH`.
4. **__dirname / __filename**: Available in ESM (unlike Node.js). Bun-idiomatic: `import.meta.dir`, `import.meta.file`.
5. **Module resolution**: Checks `tsconfig.json` paths. Verify `paths`/`baseUrl` if modules resolve differently.
6. **Hot reload caveats**: `--hot` re-executes side effects. Guard init: `globalThis.db ??= new Database("app.db");`
7. **Binary size**: Compiled executables include full runtime (~90MB). Not for size-constrained envs.
8. **Ecosystem gaps**: V8-specific packages (inspector, profiler, `vm` sandboxing) may not work. See [troubleshooting.md](references/troubleshooting.md).

## References
- **[advanced-patterns.md](references/advanced-patterns.md)** — Bun.serve static routes/WebSocket, bun:sqlite WAL/transactions, Bun.build plugins/virtual modules, Bun.$ advanced, bun:ffi pointers/callbacks, standalone executables, macros, monorepo patterns.
- **[troubleshooting.md](references/troubleshooting.md)** — Node.js compatibility matrix, npm package issues, native addons, memory leaks, `--inspect` debugging, common errors, Docker gotchas, CI/CD.
- **[migration-from-node.md](references/migration-from-node.md)** — Step-by-step migration: package management, replacing nodemon/ts-node/jest, Express→Bun.serve, fs→Bun.file, child_process→Bun.$, TS config, shims.

## Scripts

Run with `bash scripts/<name>.sh`:

- **[setup-project.sh](scripts/setup-project.sh)** — Bootstrap a Bun project (`api`, `lib`, or `fullstack` monorepo) with TS, testing, and config.
- **[migrate-from-node.sh](scripts/migrate-from-node.sh)** — Analyze a Node.js project for Bun compatibility (native addons, packages, scripts, configs).
- **[benchmark.sh](scripts/benchmark.sh)** — Benchmark Bun vs Node.js on startup, JSON, file I/O, crypto, and HTTP throughput.

## Assets

- **[bunfig.toml](assets/bunfig.toml)** — Complete bunfig.toml with all common options annotated.
- **[server-template.ts](assets/server-template.ts)** — Production Bun.serve with routing, CORS, WebSocket, logging, and error handling.
- **[Dockerfile](assets/Dockerfile)** — Multi-stage Dockerfile (oven/bun base) with health checks and non-root user.
- **[docker-compose.yml](assets/docker-compose.yml)** — Docker Compose for dev: Bun app + PostgreSQL + Redis with hot reload.
<!-- tested: needs-fix -->
