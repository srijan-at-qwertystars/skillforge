# Bun Advanced Patterns

## Table of Contents

- [Bun.serve Advanced](#bunserve-advanced)
- [bun:sqlite Advanced](#bunsqlite-advanced)
- [Bun.build Plugins](#bunbuild-plugins)
- [Bun.$ Shell Advanced](#bun-shell-advanced)
- [bun:ffi Advanced](#bunffi-advanced)
- [Standalone Executables](#standalone-executables)
- [Macro System](#macro-system)
- [Workspaces & Monorepo Patterns](#workspaces--monorepo-patterns)

---

## Bun.serve Advanced

### Static Routes (tree-based routing)

Bun.serve supports declarative `routes` with params, method dispatch, and wildcards:

```ts
Bun.serve({
  port: 3000,
  routes: {
    "/api/status": new Response("OK"),
    "/users/:id": (req) => new Response(`User ${req.params.id}`),
    "/api/posts": {
      GET: () => Response.json({ posts: [] }),
      POST: async (req) => {
        const body = await req.json();
        return Response.json({ created: true, ...body }, { status: 201 });
      },
    },
    "/assets/*": (req) => new Response(`Static: ${req.params["*"]}`),
  },
  fetch(req) {
    return new Response("Not Found", { status: 404 });
  },
});
```

Route precedence: exact > parameterized > wildcard. Routes are compiled into a radix tree for O(1) lookup.

### WebSocket Upgrade with Data

Attach arbitrary metadata during upgrade — accessible via `ws.data` in all handlers:

```ts
interface WsData {
  userId: string;
  connectedAt: number;
  role: "admin" | "user";
}

Bun.serve<WsData>({
  fetch(req, server) {
    const url = new URL(req.url);
    if (url.pathname === "/ws") {
      const token = url.searchParams.get("token");
      const user = verifyToken(token);
      const upgraded = server.upgrade(req, {
        data: { userId: user.id, connectedAt: Date.now(), role: user.role },
        headers: { "Set-Cookie": `session=${token}` },
      });
      if (!upgraded) return new Response("Upgrade failed", { status: 500 });
      return undefined;
    }
    return new Response("Hello");
  },
  websocket: {
    open(ws) {
      console.log(`${ws.data.userId} connected at ${ws.data.connectedAt}`);
      ws.subscribe("broadcast");
    },
    message(ws, msg) {
      if (ws.data.role === "admin") {
        ws.publish("broadcast", `[ADMIN] ${msg}`);
      } else {
        ws.publish("broadcast", `[${ws.data.userId}] ${msg}`);
      }
    },
    close(ws) { ws.unsubscribe("broadcast"); },
    perMessageDeflate: true,
    maxPayloadLength: 16 * 1024 * 1024,
    idleTimeout: 120,
  },
});
```

### Streaming & Server-Sent Events

```ts
Bun.serve({
  fetch(req) {
    if (new URL(req.url).pathname === "/events") {
      const stream = new ReadableStream({
        async start(controller) {
          const encoder = new TextEncoder();
          let id = 0;
          const interval = setInterval(() => {
            const data = JSON.stringify({ time: Date.now(), id: ++id });
            controller.enqueue(encoder.encode(`id: ${id}\ndata: ${data}\n\n`));
            if (id >= 100) { clearInterval(interval); controller.close(); }
          }, 1000);
        },
      });
      return new Response(stream, {
        headers: {
          "Content-Type": "text/event-stream",
          "Cache-Control": "no-cache",
          Connection: "keep-alive",
        },
      });
    }
    return new Response("Not Found", { status: 404 });
  },
});
```

### Server Configuration Options

```ts
Bun.serve({
  port: 3000,
  hostname: "0.0.0.0",
  reusePort: true,             // multiple workers on same port (Linux)
  ipv6Only: false,
  maxRequestBodySize: 50 * 1024 * 1024,  // 50 MB
  idleTimeout: 30,             // seconds before idle connection drops
  tls: {
    cert: Bun.file("./cert.pem"),
    key: Bun.file("./key.pem"),
    passphrase: "secret",
  },
  error(err) {
    return new Response(`Server Error: ${err.message}`, { status: 500 });
  },
  fetch(req) { return new Response("OK"); },
});
```

---

## bun:sqlite Advanced

### WAL Mode & Performance PRAGMAs

Always set these before any queries for optimal performance:

```ts
import { Database } from "bun:sqlite";

const db = new Database("app.db");
db.run("PRAGMA journal_mode = WAL");     // concurrent reads + writes
db.run("PRAGMA synchronous = NORMAL");   // faster writes, safe with WAL
db.run("PRAGMA busy_timeout = 5000");    // wait 5s on lock instead of failing
db.run("PRAGMA cache_size = -64000");    // 64 MB page cache
db.run("PRAGMA foreign_keys = ON");      // enforce FK constraints
db.run("PRAGMA temp_store = MEMORY");    // temp tables in memory
db.run("PRAGMA mmap_size = 268435456");  // 256 MB memory-mapped I/O
```

Run `PRAGMA optimize` before closing the database to update query planner stats.

### Prepared Statements with Named Parameters

```ts
const stmt = db.prepare("SELECT * FROM users WHERE email = $email AND active = $active");
const user = stmt.get({ $email: "alice@example.com", $active: 1 });

// Reuse across requests — prepared statements are cached
const insert = db.prepare("INSERT INTO events (type, data, ts) VALUES ($type, $data, $ts)");
insert.run({ $type: "click", $data: '{"x":100}', $ts: Date.now() });
```

### Transactions with Savepoints

```ts
const insertUser = db.prepare("INSERT INTO users (name, email) VALUES (?, ?)");
const insertRole = db.prepare("INSERT INTO user_roles (user_id, role) VALUES (?, ?)");

const createUserWithRole = db.transaction((name: string, email: string, role: string) => {
  const result = insertUser.run(name, email);
  insertRole.run(result.lastInsertRowid, role);
  return result.lastInsertRowid;
});

// Nested transactions use savepoints automatically
const batchCreate = db.transaction((users: Array<{ name: string; email: string; role: string }>) => {
  const ids: number[] = [];
  for (const u of users) {
    ids.push(Number(createUserWithRole(u.name, u.email, u.role)));
  }
  return ids;
});

// Transactions auto-rollback on throw
try {
  batchCreate([
    { name: "Alice", email: "alice@a.com", role: "admin" },
    { name: "Bob", email: "bob@b.com", role: "user" },
  ]);
} catch (e) {
  console.error("All inserts rolled back:", e);
}
```

### Returning Column Types

```ts
// .values() returns arrays of arrays (fastest — no object allocation)
const rows = db.query("SELECT id, name FROM users").values();
// => [[1, "Alice"], [2, "Bob"]]

// .all() returns array of objects
// .get() returns single object or null
// .run() returns { changes, lastInsertRowid }
```

---

## Bun.build Plugins

### Plugin Lifecycle Hooks

```ts
import type { BunPlugin } from "bun";

const myPlugin: BunPlugin = {
  name: "advanced-plugin",
  setup(build) {
    // Runs once when bundling starts
    build.onStart(() => {
      console.log("Build started");
    });

    // Intercept module resolution
    build.onResolve({ filter: /^env:/ }, (args) => ({
      path: args.path,
      namespace: "env-ns",
    }));

    // Custom loading for resolved modules
    build.onLoad({ filter: /.*/, namespace: "env-ns" }, (args) => {
      const varName = args.path.replace("env:", "");
      return {
        contents: `export default ${JSON.stringify(process.env[varName] ?? "")}`,
        loader: "js",
      };
    });

    // Runs after bundling completes
    build.onEnd((result) => {
      console.log(`Build finished: ${result.outputs.length} files`);
    });
  },
};
```

### Virtual Modules

Create modules that don't exist on disk:

```ts
const virtualPlugin: BunPlugin = {
  name: "virtual-modules",
  setup(build) {
    build.module("virtual:config", () => ({
      exports: {
        version: "1.0.0",
        env: process.env.NODE_ENV ?? "development",
        features: { auth: true, analytics: false },
      },
      loader: "object",
    }));

    build.module("virtual:routes", () => ({
      contents: `
        export const routes = [
          { path: "/", component: "Home" },
          { path: "/about", component: "About" },
        ];
      `,
      loader: "tsx",
    }));
  },
};
```

Usage in application code:

```ts
import config from "virtual:config";
import { routes } from "virtual:routes";
```

### Custom File Loaders

```ts
const markdownPlugin: BunPlugin = {
  name: "markdown-loader",
  setup(build) {
    build.onLoad({ filter: /\.md$/ }, async (args) => {
      const text = await Bun.file(args.path).text();
      const html = convertMarkdownToHtml(text);
      return {
        exports: { default: html, raw: text },
        loader: "object",
      };
    });
  },
};

// Usage: import readme from "./README.md";
```

---

## Bun.$ Shell Advanced

### Piping and Redirection

```ts
import { $ } from "bun";

// Multi-stage pipe
const count = await $`find ./src -name "*.ts" | xargs grep "TODO" | wc -l`.text();

// Redirect stderr to stdout
const combined = await $`command-that-logs 2>&1`.text();

// Redirect to file
await $`echo "log entry" >> ./app.log`;

// Pipe between Bun processes
await $`bun run generate.ts | bun run transform.ts > output.json`;
```

### Error Handling with .nothrow()

```ts
// Default: throws on non-zero exit
try {
  await $`exit 1`;
} catch (e) {
  console.log(e.exitCode); // 1
  console.log(e.stderr.toString());
}

// .nothrow() — never throws, check exitCode yourself
const result = await $`git diff --exit-code`.nothrow().quiet();
if (result.exitCode !== 0) {
  console.log("Unstaged changes detected");
}

// Global nothrow
$.nothrow();  // all subsequent $ calls won't throw
$.throws(true);  // restore throwing behavior
```

### Environment & Working Directory

```ts
// Per-command environment
await $`deploy.sh`.env({
  NODE_ENV: "production",
  API_KEY: Bun.env.API_KEY!,
  PATH: `${process.env.PATH}:/custom/bin`,
});

// Per-command working directory
await $`bun install`.cwd("/projects/my-app");

// Combine with quiet and nothrow
const { stdout } = await $`ls -la`
  .cwd("/tmp")
  .env({ LANG: "C" })
  .quiet()
  .nothrow();
```

### Reading Output Formats

```ts
const text = await $`uname -a`.text();         // string
const lines = await $`ls`.lines();             // string[]
const blob = await $`cat image.png`.blob();    // Blob
const buf = await $`cat binary`.arrayBuffer(); // ArrayBuffer
const json = await $`echo '{"a":1}'`.json();   // parsed object
```

---

## bun:ffi Advanced

### Pointer Types and Memory

```ts
import { dlopen, FFIType, ptr, read, toBuffer, toArrayBuffer, CString } from "bun:ffi";

const lib = dlopen("./libexample.so", {
  create_buffer: { args: [FFIType.u32], returns: FFIType.ptr },
  free_buffer: { args: [FFIType.ptr], returns: FFIType.void },
  get_string: { args: [], returns: FFIType.cstring },
});

// Working with returned pointers
const bufPtr = lib.symbols.create_buffer(1024);
const jsBuffer = toBuffer(bufPtr, 0, 1024);  // zero-copy view

// Read C string
const str: string = lib.symbols.get_string();

// Always free native memory
lib.symbols.free_buffer(bufPtr);
```

### Callbacks (JSCallback)

```ts
import { JSCallback, FFIType } from "bun:ffi";

const callback = new JSCallback(
  (x: number, y: number) => x + y,
  { args: [FFIType.i32, FFIType.i32], returns: FFIType.i32 }
);

// Pass callback.ptr to native code that expects a function pointer
lib.symbols.register_callback(callback.ptr);

// IMPORTANT: prevent GC by keeping a reference alive
// callback must not be garbage collected while native code holds the pointer
globalThis.__callback = callback;

// Close when done
callback.close();
```

### Struct Simulation

Bun FFI does not auto-marshal structs. Use DataView or TypedArrays:

```ts
// C struct: { int32_t x; int32_t y; float z; }  — 12 bytes
const structBuf = new ArrayBuffer(12);
const view = new DataView(structBuf);
view.setInt32(0, 100, true);   // x = 100 (little-endian)
view.setInt32(4, 200, true);   // y = 200
view.setFloat32(8, 3.14, true); // z = 3.14

lib.symbols.process_point(ptr(new Uint8Array(structBuf)));
```

---

## Standalone Executables

### Cross-Compilation Targets

```sh
# Current platform
bun build --compile ./app.ts --outfile myapp

# All supported targets
bun build --compile --target=bun-linux-x64 ./app.ts --outfile dist/myapp-linux
bun build --compile --target=bun-linux-arm64 ./app.ts --outfile dist/myapp-linux-arm
bun build --compile --target=bun-darwin-x64 ./app.ts --outfile dist/myapp-macos-x64
bun build --compile --target=bun-darwin-arm64 ./app.ts --outfile dist/myapp-macos-arm
bun build --compile --target=bun-windows-x64 ./app.ts --outfile dist/myapp.exe

# Baseline targets for older CPUs (no AVX2)
bun build --compile --target=bun-linux-x64-baseline ./app.ts --outfile dist/myapp-compat
```

### Embedded Assets

```ts
// Import files as embedded assets — bundled into the binary
import icon from "./icon.png" with { type: "file" };
import config from "./config.json" with { type: "file" };

// Access embedded content
const iconData = await (icon as Blob).arrayBuffer();
const configText = await (config as Blob).text();

// List all embedded files
for (const file of Bun.embeddedFiles) {
  console.log(file.name, file.size);
}
```

### Minification & Sourcemaps for Executables

```sh
bun build --compile --minify --sourcemap=external ./app.ts --outfile myapp
```

---

## Macro System

Macros run at **compile time** (transpilation), replacing calls with their computed results:

```ts
// lib/build-info.ts — macro file
export function buildTimestamp() {
  return Date.now();
}

export function gitHash() {
  const proc = Bun.spawnSync(["git", "rev-parse", "HEAD"]);
  return proc.stdout.toString().trim();
}
```

```ts
// app.ts — imports with { type: "macro" }
import { buildTimestamp, gitHash } from "./lib/build-info" with { type: "macro" };

// These are evaluated at build/transpile time, not runtime
console.log(`Built at: ${buildTimestamp()}`);  // inlined as a number literal
console.log(`Commit: ${gitHash()}`);           // inlined as a string literal
```

Use cases: embed build metadata, feature flags, dead-code elimination, constant folding.

**Limitations**: macros must be pure-ish functions. They execute in Bun's transpiler context. Avoid side effects that depend on runtime state.

---

## Workspaces & Monorepo Patterns

### Directory Structure

```
my-monorepo/
├── package.json          # root with "workspaces" field
├── bunfig.toml
├── bun.lockb
├── apps/
│   ├── web/             # deployable app
│   │   └── package.json
│   └── api/
│       └── package.json
├── packages/
│   ├── shared/          # shared library
│   │   └── package.json
│   └── db/
│       └── package.json
```

### Root package.json

```json
{
  "private": true,
  "workspaces": ["apps/*", "packages/*"]
}
```

### Cross-Package Dependencies

```json
// apps/api/package.json
{
  "dependencies": {
    "@myorg/shared": "workspace:*",
    "@myorg/db": "workspace:*"
  }
}
```

### Filtering Commands

```sh
# Run dev in all workspaces
bun --filter '*' dev

# Run only in apps
bun --filter './apps/*' dev

# Exclude specific packages
bun install --filter 'pkg-*' --filter '!pkg-legacy'

# Run tests in a specific workspace
bun --filter '@myorg/shared' test
```

### Workspace-Aware bunfig.toml

```toml
[install]
registry = "https://registry.npmjs.org/"

[install.scopes]
"@myorg" = { url = "https://npm.pkg.github.com/", token = "$GITHUB_TOKEN" }
```

All workspaces share the root `bun.lockb`. Dependencies are hoisted to root `node_modules` when possible, with workspace-specific versions symlinked.
