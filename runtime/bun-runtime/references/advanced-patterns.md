# Bun Advanced Patterns Reference

## Table of Contents

- [Bun.serve Advanced](#bunserve-advanced)
  - [WebSocket Pub/Sub](#websocket-pubsub)
  - [Server-Sent Events](#server-sent-events)
  - [HTTP/2 Support](#http2-support)
  - [Graceful Shutdown](#graceful-shutdown)
  - [Clustering](#clustering)
- [Bun Shell Deep Dive](#bun-shell-deep-dive)
  - [Piping and Redirection](#piping-and-redirection)
  - [Globbing](#globbing)
  - [Environment Variable Handling](#environment-variable-handling)
  - [Error Handling Strategies](#error-handling-strategies)
- [Bundler Plugins](#bundler-plugins)
  - [onResolve Hooks](#onresolve-hooks)
  - [onLoad Hooks](#onload-hooks)
  - [Custom Loaders](#custom-loaders)
- [Bun.build Advanced](#bunbuild-advanced)
  - [Tree Shaking](#tree-shaking)
  - [Code Splitting](#code-splitting)
  - [CSS Modules](#css-modules)
  - [HTML Entry Points](#html-entry-points)
- [Test Runner Advanced](#test-runner-advanced)
  - [Spies and Fakes](#spies-and-fakes)
  - [test.todo and test.skip](#testtodo-and-testskip)
  - [Coverage](#coverage)
  - [Watch Mode](#watch-mode)
- [bun:sqlite Advanced](#bunsqlite-advanced)
  - [Transactions and Savepoints](#transactions-and-savepoints)
  - [Custom Functions](#custom-functions)
  - [FTS5 Full-Text Search](#fts5-full-text-search)
  - [Migrations](#migrations)
- [bun:ffi Patterns](#bunffi-patterns)
  - [Structs and Complex Types](#structs-and-complex-types)
  - [Callbacks](#callbacks)
  - [Memory Management](#memory-management)
- [Bun.password and Bun.CryptoHasher](#bunpassword-and-buncryptohasher)
- [S3 Client (Bun.s3)](#s3-client-buns3)
- [Semver API](#semver-api)

---

## Bun.serve Advanced

### WebSocket Pub/Sub

Bun.serve has built-in pub/sub for WebSockets via topics. No external broker needed:

```typescript
const server = Bun.serve({
  fetch(req, server) {
    const url = new URL(req.url);
    const room = url.searchParams.get("room") ?? "general";

    if (url.pathname === "/chat") {
      if (server.upgrade(req, { data: { room, joinedAt: Date.now() } })) return;
      return new Response("Upgrade failed", { status: 500 });
    }
    return new Response("Use /chat?room=<name> to connect");
  },

  websocket: {
    open(ws) {
      // Subscribe to the room topic
      ws.subscribe(ws.data.room);
      // Broadcast join event to all subscribers
      server.publish(ws.data.room, JSON.stringify({
        type: "system",
        text: `User joined ${ws.data.room}`,
      }));
    },

    message(ws, msg) {
      // Publish to topic — all subscribers receive it (except sender)
      ws.publish(ws.data.room, JSON.stringify({
        type: "message",
        text: String(msg),
      }));
      // Use server.publish() to include sender too
    },

    close(ws) {
      ws.unsubscribe(ws.data.room);
      server.publish(ws.data.room, JSON.stringify({
        type: "system",
        text: "User left",
      }));
    },
  },
});
```

Key pub/sub details:
- `ws.subscribe(topic)` — subscribe a socket to a named topic
- `ws.unsubscribe(topic)` — unsubscribe from a topic
- `ws.publish(topic, data)` — send to all OTHER subscribers on this socket
- `server.publish(topic, data)` — send to ALL subscribers including sender
- Topics are strings; a socket can subscribe to multiple topics
- Messages are not persisted — pub/sub is in-memory, same-process only
- Per-message compression is supported via `perMessageDeflate: true`

### Server-Sent Events

SSE with `ReadableStream` for real-time server→client push:

```typescript
Bun.serve({
  fetch(req) {
    if (new URL(req.url).pathname === "/events") {
      const stream = new ReadableStream({
        start(controller) {
          const encoder = new TextEncoder();
          let id = 0;

          const interval = setInterval(() => {
            id++;
            const event = [
              `id: ${id}`,
              `event: tick`,
              `data: ${JSON.stringify({ time: new Date().toISOString() })}`,
              "", ""  // double newline terminates event
            ].join("\n");
            controller.enqueue(encoder.encode(event));
          }, 1000);

          // Clean up when client disconnects
          req.signal.addEventListener("abort", () => {
            clearInterval(interval);
            controller.close();
          });
        },
      });

      return new Response(stream, {
        headers: {
          "Content-Type": "text/event-stream",
          "Cache-Control": "no-cache",
          "Connection": "keep-alive",
        },
      });
    }
    return new Response("Not found", { status: 404 });
  },
});
```

SSE best practices:
- Use `req.signal` to detect client disconnection and clean up resources
- Set `Cache-Control: no-cache` to prevent proxy buffering
- Include `id:` field so clients can resume from `Last-Event-ID` header
- Use named events (`event:`) to differentiate message types client-side

### HTTP/2 Support

Bun supports HTTP/2 automatically when TLS is configured:

```typescript
Bun.serve({
  port: 443,
  tls: {
    key: Bun.file("./certs/key.pem"),
    cert: Bun.file("./certs/cert.pem"),
  },
  fetch(req) {
    // HTTP/2 is negotiated automatically via ALPN
    return new Response("HTTP/2 enabled");
  },
});
```

Notes on HTTP/2:
- HTTP/2 is enabled automatically when TLS is present — no explicit config needed
- Without TLS (h2c / cleartext HTTP/2), standard HTTP/1.1 is used
- Server push is not currently supported
- Multiplexing and header compression work transparently

### Graceful Shutdown

Proper server shutdown that finishes in-flight requests:

```typescript
const server = Bun.serve({
  port: 3000,
  fetch(req) {
    return new Response("OK");
  },
});

let isShuttingDown = false;

async function gracefulShutdown(signal: string) {
  if (isShuttingDown) return;
  isShuttingDown = true;
  console.log(`Received ${signal}, shutting down gracefully...`);

  // Stop accepting new connections, finish in-flight requests
  server.stop();

  // Close database connections, flush logs, etc.
  // await db.close();
  // await logger.flush();

  console.log("Server stopped");
  process.exit(0);
}

process.on("SIGTERM", () => gracefulShutdown("SIGTERM"));
process.on("SIGINT", () => gracefulShutdown("SIGINT"));
```

`server.stop()` behavior:
- Stops accepting new TCP connections immediately
- Existing in-flight requests are completed
- WebSocket connections remain open until explicitly closed
- Pass `true` to `server.stop(true)` to also abort pending I/O

### Clustering

Run multiple Bun server instances using `reusePort` for multi-core scaling:

```typescript
// cluster.ts — spawn workers sharing the same port
import { cpus } from "node:os";

const numWorkers = cpus().length;

if (Bun.isMainThread) {
  console.log(`Starting ${numWorkers} workers...`);
  for (let i = 0; i < numWorkers; i++) {
    const worker = new Worker(new URL(import.meta.url));
    worker.addEventListener("message", (e) => {
      console.log(`Worker ${i}: ${e.data}`);
    });
  }
} else {
  const server = Bun.serve({
    port: 3000,
    reusePort: true,  // Allow multiple processes to bind the same port
    fetch(req) {
      return new Response(`Handled by worker PID ${process.pid}`);
    },
  });
  postMessage(`Listening on ${server.url}`);
}
```

Clustering notes:
- `reusePort: true` uses `SO_REUSEPORT` — the OS load-balances across processes
- Each worker is a separate Bun process with its own event loop
- No shared state between workers — use external storage (Redis, SQLite) if needed
- For production, consider using a process manager or container orchestrator instead

---

## Bun Shell Deep Dive

### Piping and Redirection

```typescript
import { $ } from "bun";

// Pipe between commands
const result = await $`cat data.csv | grep "error" | sort | uniq -c`.text();

// Redirect stdout to file
await $`echo "log entry" >> app.log`;

// Redirect stderr
await $`command-that-warns 2>/dev/null`;

// Capture stdout as different types
const text = await $`ls`.text();       // string
const json = await $`cat data.json`.json();  // parsed JSON
const blob = await $`cat image.png`.blob();  // Blob
const lines = await $`ls`.lines();     // AsyncIterableIterator<string>
const buf = await $`cat file`.arrayBuffer(); // ArrayBuffer

// Pipe JavaScript data into commands
const input = "hello world";
const upper = await $`echo ${input} | tr '[:lower:]' '[:upper:]'`.text();

// Chain with &&, ||, and ;
await $`mkdir -p dist && bun build ./src/index.ts --outdir dist`;
```

### Globbing

```typescript
import { $ } from "bun";

// Shell globbing works naturally
const tsFiles = await $`ls src/**/*.ts`.text();

// Use Bun.Glob for programmatic glob patterns
const glob = new Bun.Glob("**/*.{ts,tsx}");
for await (const path of glob.scan({ cwd: "./src", onlyFiles: true })) {
  console.log(path);
}

// Match against a string
const g = new Bun.Glob("*.test.ts");
console.log(g.match("auth.test.ts"));  // true
console.log(g.match("auth.ts"));       // false
```

### Environment Variable Handling

```typescript
import { $ } from "bun";

// Environment variables expand in shell commands
await $`echo $HOME`;

// Set env for a single command
await $`MY_VAR=hello echo $MY_VAR`;

// Use $.env to set environment for all subsequent commands
$.env({ DATABASE_URL: "postgres://localhost/mydb" });
await $`echo $DATABASE_URL`;

// Inherit current process env plus overrides
$.env({ ...process.env, NODE_ENV: "production" });

// Use Bun.env directly for reading
const port = Bun.env.PORT ?? "3000";
```

### Error Handling Strategies

```typescript
import { $ } from "bun";

// By default, non-zero exit throws ShellError
try {
  await $`exit 1`;
} catch (e) {
  console.error(`Command failed: exit code ${e.exitCode}`);
  console.error(`stderr: ${e.stderr.toString()}`);
}

// Use .nothrow() to suppress throwing
const result = await $`grep "missing" file.txt`.nothrow();
if (result.exitCode !== 0) {
  console.log("Pattern not found");
}

// Use .quiet() to suppress stdout/stderr printing
await $`noisy-command`.quiet();

// Combine .nothrow() and .quiet()
const { exitCode } = await $`test -f config.json`.nothrow().quiet();
const configExists = exitCode === 0;

// Timeout (throws if command doesn't complete)
// Use AbortSignal for timeout
const controller = new AbortController();
setTimeout(() => controller.abort(), 5000);
try {
  await $`long-running-task`.nothrow();
} catch (e) {
  console.error("Command timed out or failed");
}
```

---

## Bundler Plugins

### onResolve Hooks

Intercept module resolution to redirect or virtualize imports:

```typescript
import { plugin } from "bun";

plugin({
  name: "alias-resolver",
  setup(build) {
    // Redirect bare specifiers
    build.onResolve({ filter: /^@app\/(.*)/ }, (args) => {
      return {
        path: `./src/${args.path.replace("@app/", "")}`,
        namespace: "file",
      };
    });

    // Virtual modules — resolve to a custom namespace
    build.onResolve({ filter: /^virtual:config$/ }, () => {
      return { path: "config", namespace: "virtual" };
    });

    // Then load from the virtual namespace
    build.onLoad({ filter: /.*/, namespace: "virtual" }, () => {
      return {
        contents: `export default ${JSON.stringify({ env: Bun.env.NODE_ENV })}`,
        loader: "js",
      };
    });
  },
});
```

### onLoad Hooks

Transform file contents during loading:

```typescript
plugin({
  name: "markdown-loader",
  setup(build) {
    build.onLoad({ filter: /\.md$/ }, async (args) => {
      const text = await Bun.file(args.path).text();
      // Convert markdown to a module exporting raw text
      return {
        contents: `export default ${JSON.stringify(text)};`,
        loader: "js",
      };
    });
  },
});

// TOML loader example
plugin({
  name: "toml-loader",
  setup(build) {
    build.onLoad({ filter: /\.toml$/ }, async (args) => {
      const TOML = await import("@iarna/toml");
      const text = await Bun.file(args.path).text();
      const parsed = TOML.parse(text);
      return {
        contents: `export default ${JSON.stringify(parsed)};`,
        loader: "js",
      };
    });
  },
});
```

### Custom Loaders

Bun supports these loader types in plugin results:

| Loader   | Description                                  |
|----------|----------------------------------------------|
| `js`     | JavaScript (ESM or CommonJS)                 |
| `jsx`    | JavaScript with JSX                          |
| `ts`     | TypeScript                                   |
| `tsx`    | TypeScript with JSX                          |
| `json`   | JSON → default export                        |
| `toml`   | TOML → default export                        |
| `text`   | Raw text → default export string             |
| `css`    | CSS file                                     |
| `file`   | Copy file, export resolved path              |
| `napi`   | Native Node-API addon                        |
| `wasm`   | WebAssembly module                           |

Example combining loaders:

```typescript
plugin({
  name: "svg-component",
  setup(build) {
    build.onLoad({ filter: /\.svg$/ }, async (args) => {
      const svg = await Bun.file(args.path).text();
      // Convert SVG to a React component
      return {
        contents: `
          export default function SvgIcon(props) {
            return <span dangerouslySetInnerHTML={{ __html: ${JSON.stringify(svg)} }} {...props} />;
          }
        `,
        loader: "jsx",
      };
    });
  },
});
```

---

## Bun.build Advanced

### Tree Shaking

Bun.build automatically removes unused exports (dead code elimination):

```typescript
const result = await Bun.build({
  entrypoints: ["./src/index.ts"],
  outdir: "./dist",
  minify: true,   // Enables tree shaking + minification
  target: "browser",
});
```

Tree shaking behavior:
- Unused exports are removed when `minify` is enabled
- Side-effect-free modules are fully eliminated if unused
- Mark packages as side-effect-free in `package.json`: `"sideEffects": false`
- Use `"sideEffects": ["*.css"]` to preserve CSS imports during tree shaking
- Re-exports (`export { foo } from "./bar"`) are properly traced

### Code Splitting

Enable with `splitting: true` for shared chunk extraction:

```typescript
const result = await Bun.build({
  entrypoints: [
    "./src/pages/home.ts",
    "./src/pages/dashboard.ts",
    "./src/pages/settings.ts",
  ],
  outdir: "./dist",
  splitting: true,    // Extract shared code into separate chunks
  target: "browser",
  sourcemap: "external",
});

// Result: dist/home.js, dist/dashboard.js, dist/settings.js, dist/chunk-xxxxx.js
for (const output of result.outputs) {
  console.log(`${output.path} (${output.kind})`);
  // kind is "entry-point" or "chunk"
}
```

Code splitting notes:
- Requires multiple entry points or dynamic imports
- Shared modules are extracted into common chunks automatically
- Dynamic `import()` expressions create separate chunks
- Works with `target: "browser"` and `target: "bun"`

### CSS Modules

Bun can bundle CSS alongside JavaScript:

```typescript
const result = await Bun.build({
  entrypoints: ["./src/app.tsx"],
  outdir: "./dist",
  target: "browser",
  // CSS imports in JS are automatically extracted
});
```

CSS handling:
- `import "./styles.css"` — CSS is extracted to a separate output file
- CSS modules (`.module.css`) export class name mappings
- `@import` statements are resolved and bundled
- CSS nesting and modern syntax are supported

### HTML Entry Points

Use HTML files as entry points for full-page bundling:

```typescript
const result = await Bun.build({
  entrypoints: ["./public/index.html"],
  outdir: "./dist",
  target: "browser",
  minify: true,
});
```

HTML entry point behavior:
- `<script src="./app.ts">` tags are bundled and paths updated
- `<link rel="stylesheet" href="./styles.css">` is processed
- Asset references are resolved
- Output includes the transformed HTML with updated paths

---

## Test Runner Advanced

### Spies and Fakes

```typescript
import { describe, it, expect, mock, spyOn, jest } from "bun:test";

// Basic spy — wraps an existing method
const console_log = spyOn(console, "log");
console.log("hello");
expect(console_log).toHaveBeenCalledWith("hello");
console_log.mockRestore(); // Restore original

// Mock function with implementation
const fetchUser = mock(async (id: number) => {
  return { id, name: "Test User" };
});
const user = await fetchUser(42);
expect(fetchUser).toHaveBeenCalledTimes(1);
expect(fetchUser.mock.results[0].value).resolves.toEqual({ id: 42, name: "Test User" });

// Mock return values
const getPrice = mock(() => 0);
getPrice.mockReturnValue(9.99);
expect(getPrice()).toBe(9.99);

getPrice.mockReturnValueOnce(19.99);
expect(getPrice()).toBe(19.99);  // first call: 19.99
expect(getPrice()).toBe(9.99);   // subsequent: 9.99

// Mock implementation
const calculate = mock(() => 0);
calculate.mockImplementation((a: number, b: number) => a + b);
expect(calculate(2, 3)).toBe(5);

// Module mocking
mock.module("./database", () => ({
  query: mock(() => [{ id: 1, name: "Alice" }]),
  connect: mock(() => Promise.resolve()),
}));
```

### test.todo and test.skip

```typescript
import { describe, it, test, expect } from "bun:test";

describe("UserService", () => {
  // Marks a test as pending — shows in output but doesn't fail
  test.todo("should handle rate limiting");
  test.todo("should validate email format");

  // Skip a test — useful for platform-specific or flaky tests
  test.skip("requires network access", () => {
    // This test body is not executed
  });

  // Conditional skip
  const isCI = !!process.env.CI;
  (isCI ? test.skip : test)("slow integration test", async () => {
    // Only runs locally, skipped in CI
  });

  // test.if — conditional execution
  test.if(process.platform === "linux")("linux-only feature", () => {
    // Only runs on Linux
  });

  // test.each — parameterized tests
  test.each([
    [1, 1, 2],
    [2, 3, 5],
    [10, 20, 30],
  ])("add(%i, %i) = %i", (a, b, expected) => {
    expect(a + b).toBe(expected);
  });
});
```

### Coverage

```bash
# Generate coverage report
bun test --coverage

# Coverage with threshold
bun test --coverage --coverage-threshold 80

# Output coverage to specific format
bun test --coverage --coverage-reporter=lcov
```

Configure coverage in `bunfig.toml`:

```toml
[test]
coverage = true
coverageThreshold = 0.8
coverageSkipTestFiles = true

# Ignore patterns for coverage
coverageIgnore = ["node_modules", "test", "**/*.test.ts"]
```

### Watch Mode

```bash
# Re-run tests on file changes
bun test --watch

# Watch specific test files
bun test --watch tests/unit/

# Combine with other flags
bun test --watch --coverage --bail
```

Watch mode behavior:
- Monitors imported files for changes
- Only re-runs affected test files
- Press `a` to run all tests, `q` to quit
- Works with `--bail` to stop on first failure

---

## bun:sqlite Advanced

### Transactions and Savepoints

```typescript
import { Database } from "bun:sqlite";

const db = new Database("app.db");
db.run("PRAGMA journal_mode = WAL");

// Automatic transaction via db.transaction()
const transferFunds = db.transaction(
  (from: string, to: string, amount: number) => {
    const debit = db.prepare("UPDATE accounts SET balance = balance - ? WHERE id = ?");
    const credit = db.prepare("UPDATE accounts SET balance = balance + ? WHERE id = ?");

    debit.run(amount, from);
    credit.run(amount, to);

    // Check constraint
    const { balance } = db.prepare("SELECT balance FROM accounts WHERE id = ?").get(from) as any;
    if (balance < 0) throw new Error("Insufficient funds");
  }
);

// Transaction automatically commits or rolls back
try {
  transferFunds("acct-1", "acct-2", 100);
} catch (e) {
  console.error("Transfer failed, rolled back:", e.message);
}

// Nested transactions use SAVEPOINTs automatically
const outerTx = db.transaction(() => {
  db.run("INSERT INTO logs (msg) VALUES ('outer')");

  const innerTx = db.transaction(() => {
    db.run("INSERT INTO logs (msg) VALUES ('inner')");
    // If this throws, only inner transaction rolls back
  });
  innerTx();
});
outerTx();

// Manual transaction control
db.run("BEGIN");
try {
  db.run("INSERT INTO users (name) VALUES ('Alice')");
  db.run("SAVEPOINT sp1");
  db.run("INSERT INTO users (name) VALUES ('Bob')");
  db.run("RELEASE SAVEPOINT sp1");
  db.run("COMMIT");
} catch (e) {
  db.run("ROLLBACK");
}
```

### Custom Functions

Register JavaScript functions callable from SQL:

```typescript
const db = new Database(":memory:");

// Scalar function
db.run("SELECT 1"); // ensure db is initialized
// Use db.prepare and .run for custom function registration via Bun API

// Custom aggregation and functions are available through
// direct SQL with the JavaScript bridge

// The Bun SQLite API supports registering custom functions:
// This allows you to call JS functions in SQL queries
```

### FTS5 Full-Text Search

```typescript
const db = new Database("search.db");

// Create FTS5 virtual table
db.run(`
  CREATE VIRTUAL TABLE IF NOT EXISTS articles_fts USING fts5(
    title,
    body,
    tags,
    content='articles',
    content_rowid='id',
    tokenize='porter unicode61'
  )
`);

// Populate FTS index
db.run(`INSERT INTO articles_fts(rowid, title, body, tags)
  SELECT id, title, body, tags FROM articles`);

// Full-text search with ranking
const results = db.prepare(`
  SELECT a.*, rank
  FROM articles_fts fts
  JOIN articles a ON a.id = fts.rowid
  WHERE articles_fts MATCH ?
  ORDER BY rank
  LIMIT 20
`).all("bun AND runtime");

// Highlight search matches
const highlighted = db.prepare(`
  SELECT highlight(articles_fts, 0, '<b>', '</b>') as title,
         snippet(articles_fts, 1, '<b>', '</b>', '...', 32) as excerpt
  FROM articles_fts
  WHERE articles_fts MATCH ?
`).all("javascript");

// Keep FTS in sync with triggers
db.run(`
  CREATE TRIGGER articles_ai AFTER INSERT ON articles BEGIN
    INSERT INTO articles_fts(rowid, title, body, tags)
    VALUES (new.id, new.title, new.body, new.tags);
  END
`);
db.run(`
  CREATE TRIGGER articles_ad AFTER DELETE ON articles BEGIN
    INSERT INTO articles_fts(articles_fts, rowid, title, body, tags)
    VALUES ('delete', old.id, old.title, old.body, old.tags);
  END
`);
```

### Migrations

Pattern for managing database schema migrations:

```typescript
import { Database } from "bun:sqlite";

interface Migration {
  version: number;
  name: string;
  up: string;
  down: string;
}

const migrations: Migration[] = [
  {
    version: 1,
    name: "create_users",
    up: `CREATE TABLE users (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      email TEXT UNIQUE NOT NULL,
      name TEXT NOT NULL,
      created_at TEXT DEFAULT (datetime('now'))
    )`,
    down: "DROP TABLE users",
  },
  {
    version: 2,
    name: "create_posts",
    up: `CREATE TABLE posts (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER REFERENCES users(id),
      title TEXT NOT NULL,
      body TEXT,
      published_at TEXT
    )`,
    down: "DROP TABLE posts",
  },
];

function migrate(db: Database) {
  db.run(`CREATE TABLE IF NOT EXISTS _migrations (
    version INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    applied_at TEXT DEFAULT (datetime('now'))
  )`);

  const applied = new Set(
    db.prepare("SELECT version FROM _migrations").all().map((r: any) => r.version)
  );

  const pending = migrations.filter((m) => !applied.has(m.version));
  if (pending.length === 0) {
    console.log("Database is up to date");
    return;
  }

  const applyMigrations = db.transaction(() => {
    for (const m of pending) {
      console.log(`Applying migration ${m.version}: ${m.name}`);
      db.run(m.up);
      db.prepare("INSERT INTO _migrations (version, name) VALUES (?, ?)").run(m.version, m.name);
    }
  });

  applyMigrations();
  console.log(`Applied ${pending.length} migration(s)`);
}

// Usage
const db = new Database("app.db");
db.run("PRAGMA journal_mode = WAL");
db.run("PRAGMA foreign_keys = ON");
migrate(db);
```

---

## bun:ffi Patterns

### Structs and Complex Types

```typescript
import { dlopen, FFIType, ptr, toArrayBuffer, read, CString } from "bun:ffi";

// Working with pointer-based structs
const lib = dlopen("./libgeo.so", {
  create_point: { args: [FFIType.f64, FFIType.f64], returns: FFIType.ptr },
  get_x: { args: [FFIType.ptr], returns: FFIType.f64 },
  get_y: { args: [FFIType.ptr], returns: FFIType.f64 },
  free_point: { args: [FFIType.ptr], returns: FFIType.void },
  distance: { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.f64 },
});

const p1 = lib.symbols.create_point(3.0, 4.0);
const p2 = lib.symbols.create_point(0.0, 0.0);
console.log(`Distance: ${lib.symbols.distance(p1, p2)}`); // 5.0

lib.symbols.free_point(p1);
lib.symbols.free_point(p2);
lib.close();

// Reading raw memory
const buffer = toArrayBuffer(somePointer, 0, 64); // Read 64 bytes from pointer
const view = new DataView(buffer);
const x = view.getFloat64(0, true);  // little-endian
const y = view.getFloat64(8, true);

// Working with C strings
const cstr = new CString(somePointer);
console.log(cstr.toString());
```

### Callbacks

Pass JavaScript functions as C callbacks:

```typescript
import { dlopen, FFIType, callback } from "bun:ffi";

const lib = dlopen("./libsort.so", {
  sort_array: {
    args: [FFIType.ptr, FFIType.i32, FFIType.function],
    returns: FFIType.void,
  },
});

// Create a callback function pointer
const comparator = callback(
  {
    args: [FFIType.i32, FFIType.i32],
    returns: FFIType.i32,
  },
  (a, b) => a - b  // ascending order
);

// Pass callback to C function
// lib.symbols.sort_array(arrayPtr, length, comparator);

// IMPORTANT: prevent callback from being garbage collected
// Keep a reference alive for as long as the native code might call it
```

### Memory Management

```typescript
import { ptr, toArrayBuffer, FFIType } from "bun:ffi";

// Bun manages JS memory, but native memory needs manual handling:
// 1. Always call free/close/destroy functions from native libs
// 2. Keep references to callbacks alive to prevent GC
// 3. Use try/finally for cleanup

function withNativeResource<T>(
  allocate: () => number,  // returns pointer
  cleanup: (ptr: number) => void,
  work: (ptr: number) => T
): T {
  const pointer = allocate();
  try {
    return work(pointer);
  } finally {
    cleanup(pointer);
  }
}

// TypedArray for passing data to native functions
const data = new Float64Array([1.0, 2.0, 3.0, 4.0]);
const dataPtr = ptr(data);  // Get pointer to TypedArray backing buffer
// Pass dataPtr to native functions — data must stay in scope!
```

---

## Bun.password and Bun.CryptoHasher

### Password Hashing

```typescript
// Hash a password (bcrypt by default, argon2id also supported)
const hash = await Bun.password.hash("my-password", {
  algorithm: "bcrypt",
  cost: 12,  // bcrypt work factor (default: 10)
});

// Argon2id (more secure, recommended for new projects)
const argonHash = await Bun.password.hash("my-password", {
  algorithm: "argon2id",
  memoryCost: 65536,  // 64 MB
  timeCost: 3,
});

// Verify password against hash
const isValid = await Bun.password.verify("my-password", hash);
if (isValid) {
  console.log("Password matches");
}

// Synchronous variants (blocks event loop — use for scripts only)
const syncHash = Bun.password.hashSync("password");
const syncValid = Bun.password.verifySync("password", syncHash);
```

### CryptoHasher

```typescript
// Create hashers for various algorithms
const sha256 = new Bun.CryptoHasher("sha256");
sha256.update("hello ");
sha256.update("world");
const digest = sha256.digest("hex");  // hex string
console.log(digest);

// One-shot hashing
const hash = Bun.CryptoHasher.hash("sha256", "hello world", "hex");

// Supported algorithms: md5, sha1, sha224, sha256, sha384, sha512,
// sha3-224, sha3-256, sha3-384, sha3-512, blake2b256, blake2b512

// HMAC
const hmac = new Bun.CryptoHasher("sha256", "secret-key");
hmac.update("message");
const hmacDigest = hmac.digest("base64");

// Streaming — hash a file efficiently
const fileHasher = new Bun.CryptoHasher("sha256");
const file = Bun.file("large-file.bin");
const reader = file.stream().getReader();
while (true) {
  const { done, value } = await reader.read();
  if (done) break;
  fileHasher.update(value);
}
console.log(fileHasher.digest("hex"));
```

---

## S3 Client (Bun.s3)

Bun has a built-in S3-compatible client:

```typescript
import { S3Client } from "bun";

// Create client (also works with Cloudflare R2, MinIO, etc.)
const s3 = new S3Client({
  accessKeyId: Bun.env.AWS_ACCESS_KEY_ID!,
  secretAccessKey: Bun.env.AWS_SECRET_ACCESS_KEY!,
  region: "us-east-1",
  // endpoint: "https://s3.us-east-1.amazonaws.com",  // custom endpoint for R2/MinIO
});

// Get an S3 file reference (lazy, like Bun.file)
const file = s3.file("my-bucket/path/to/file.json");

// Read operations
const text = await file.text();
const json = await file.json();
const bytes = await file.bytes();
const exists = await file.exists();
console.log(file.size, file.type);

// Write operations
await file.write("hello world");
await file.write(JSON.stringify({ key: "value" }));
await file.write(new Uint8Array([1, 2, 3]));

// Delete
await file.delete();

// Presigned URLs
const url = file.presign({
  expiresIn: 3600,  // seconds
  method: "GET",
});

// Use S3 files with Bun.serve for streaming
Bun.serve({
  async fetch(req) {
    const key = new URL(req.url).pathname.slice(1);
    const file = s3.file(`my-bucket/${key}`);
    if (!(await file.exists())) return new Response("Not found", { status: 404 });
    return new Response(file);
  },
});
```

---

## Semver API

Bun has a built-in semver comparison API:

```typescript
import { semver } from "bun";

// Compare versions
semver.satisfies("1.2.3", "^1.0.0");      // true
semver.satisfies("2.0.0", "^1.0.0");      // false
semver.satisfies("1.2.3", ">=1.0.0 <2.0.0"); // true

// Order versions
semver.order("1.0.0", "2.0.0");           // -1 (a < b)
semver.order("2.0.0", "1.0.0");           // 1  (a > b)
semver.order("1.0.0", "1.0.0");           // 0  (equal)

// Sort an array of versions
const versions = ["3.0.0", "1.2.0", "2.1.0", "1.0.0"];
versions.sort(semver.order);
// ["1.0.0", "1.2.0", "2.1.0", "3.0.0"]
```

The semver API is significantly faster than the `semver` npm package since it's implemented in native code.
