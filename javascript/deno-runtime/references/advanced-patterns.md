# Deno 2.x Advanced Patterns

## Table of Contents

- [Workspaces (Monorepo Support)](#workspaces-monorepo-support)
- [node_modules Support](#node_modules-support)
- [npm/JSR Hybrid Imports](#npmjsr-hybrid-imports)
- [Import Maps](#import-maps)
- [Deno.cron — Scheduled Tasks](#denocron--scheduled-tasks)
- [Deno KV Queues (Deno.Queue)](#deno-kv-queues-denoqueue)
- [BroadcastChannel](#broadcastchannel)
- [Web Workers](#web-workers)
- [Deno.Command — Subprocess Management](#denocommand--subprocess-management)
- [Custom Runtimes with deno_core](#custom-runtimes-with-deno_core)
- [Embedding Deno](#embedding-deno)
- [Performance Profiling (V8 Flags)](#performance-profiling-v8-flags)
- [deno serve — Multi-threaded HTTP](#deno-serve--multi-threaded-http)
- [Deno Compile — Standalone Binaries](#deno-compile--standalone-binaries)
- [Advanced Testing Patterns](#advanced-testing-patterns)
- [Streaming and Server-Sent Events](#streaming-and-server-sent-events)

---

## Workspaces (Monorepo Support)

Deno 2.x supports workspaces for managing multiple packages in a single repository. Each member has its own `deno.json` with independent dependencies, tasks, and configuration.

### Root Configuration

```jsonc
// deno.json (repository root)
{
  "workspace": ["./packages/core", "./packages/api", "./packages/web", "./packages/shared"]
}
```

### Member Configuration

```jsonc
// packages/core/deno.json
{
  "name": "@myorg/core",
  "version": "1.0.0",
  "exports": "./mod.ts",
  "imports": {
    "@std/assert": "jsr:@std/assert@^1"
  }
}
```

### Cross-Package References

```typescript
// packages/api/main.ts — import from sibling workspace member
import { validate } from "@myorg/core";
```

### Workspace Tasks

```bash
# Run task in specific workspace member
deno task --filter="@myorg/api" dev

# Run tests across all workspace members
deno test --workspace
```

### Key Rules

- Each member must have a `deno.json` with `name` and `version`
- Members can import each other via their `name` field
- The root `deno.json` should not contain `name`/`version` (it's the workspace root)
- Lock files are shared at the workspace root
- Each member can have its own `compilerOptions`, `imports`, and `tasks`

---

## node_modules Support

Deno 2.x fully supports `node_modules/` and `package.json` for backward compatibility with existing Node.js projects.

### Automatic Detection

When a `package.json` exists, Deno automatically:
1. Reads dependencies from `package.json`
2. Creates a `node_modules/` folder
3. Resolves bare specifiers through `node_modules/`

```bash
# Deno auto-installs when package.json is present
deno run main.ts  # Reads package.json, installs to node_modules/
```

### Explicit node_modules Mode

```jsonc
// deno.json
{
  "nodeModulesDir": "auto"   // auto | manual | none
}
```

- `"auto"` — Deno manages `node_modules/` automatically
- `"manual"` — You run `deno install` to populate `node_modules/`
- `"none"` — Uses Deno's global cache (no local node_modules)

### Using package.json Alongside deno.json

```jsonc
// package.json
{
  "dependencies": {
    "express": "^4.18.0",
    "prisma": "^5.0.0"
  }
}
```

```jsonc
// deno.json (coexists with package.json)
{
  "imports": {
    "@std/path": "jsr:@std/path@^1"
  },
  "tasks": {
    "dev": "deno run --allow-net --allow-read --allow-env src/main.ts"
  }
}
```

```typescript
// src/main.ts — mix npm (from package.json) and JSR (from deno.json)
import express from "express";
import { join } from "@std/path";
```

---

## npm/JSR Hybrid Imports

Deno 2.x allows mixing npm and JSR imports seamlessly.

### Import Specifier Types

```typescript
// JSR imports (Deno-native registry, TypeScript-first)
import { assertEquals } from "jsr:@std/assert@^1";

// npm imports (npm registry compatibility)
import chalk from "npm:chalk@^5";

// HTTPS imports (URL-based, legacy Deno style)
import { serve } from "https://deno.land/std@0.224.0/http/server.ts";

// Bare specifiers (resolved via import map in deno.json)
import { z } from "zod";
```

### Centralized Dependency Management

```jsonc
// deno.json — import map section
{
  "imports": {
    // JSR packages
    "@std/assert": "jsr:@std/assert@^1",
    "@std/path": "jsr:@std/path@^1",
    "oak": "jsr:@oak/oak@^17",
    "hono": "jsr:@hono/hono@^4",

    // npm packages
    "zod": "npm:zod@^3.23",
    "drizzle-orm": "npm:drizzle-orm@^0.33",
    "lodash-es": "npm:lodash-es@^4.17",

    // Path aliases
    "@/": "./src/",
    "#lib/": "./lib/"
  }
}
```

### Adding and Removing Dependencies

```bash
# Add JSR packages
deno add jsr:@std/assert jsr:@oak/oak

# Add npm packages
deno add npm:zod npm:drizzle-orm

# Remove packages
deno remove zod

# Check for outdated packages
deno outdated

# Update packages
deno outdated --update
```

---

## Import Maps

Import maps centralize module resolution. They replace the need for `tsconfig.json` paths or bundler aliases.

### Basic Import Map

```jsonc
// deno.json
{
  "imports": {
    "react": "npm:react@^18",
    "react-dom": "npm:react-dom@^18",
    "@/components/": "./src/components/",
    "@/utils/": "./src/utils/"
  }
}
```

### Scoped Imports

```jsonc
// deno.json — different versions for different paths
{
  "imports": {
    "lodash": "npm:lodash@^4.17"
  },
  "scopes": {
    "./legacy/": {
      "lodash": "npm:lodash@^3.10"
    }
  }
}
```

### External Import Map File

```jsonc
// deno.json
{
  "importMap": "./import_map.json"
}
```

```json
// import_map.json
{
  "imports": {
    "preact": "https://esm.sh/preact@10.19.3",
    "preact/": "https://esm.sh/preact@10.19.3/"
  }
}
```

---

## Deno.cron — Scheduled Tasks

Deno provides a built-in cron API for scheduling recurring tasks. On Deno Deploy, cron jobs are distributed and persistent.

### Basic Usage

```typescript
// Schedule a task to run every hour
Deno.cron("hourly-cleanup", "0 * * * *", async () => {
  console.log("Running hourly cleanup...");
  const kv = await Deno.openKv();
  const old = kv.list({ prefix: ["temp"] });
  for await (const entry of old) {
    await kv.delete(entry.key);
  }
});

// Every 5 minutes
Deno.cron("health-check", "*/5 * * * *", async () => {
  const res = await fetch("https://api.example.com/health");
  if (!res.ok) {
    console.error("Health check failed:", res.status);
  }
});

// Daily at midnight UTC
Deno.cron("daily-report", "0 0 * * *", async () => {
  await generateAndSendReport();
});

// Weekdays at 9 AM
Deno.cron("weekday-digest", "0 9 * * 1-5", () => {
  console.log("Sending weekday digest");
});
```

### Cron with Backoff (Deno Deploy)

On Deno Deploy, failed cron handlers are automatically retried with exponential backoff. Keep handlers idempotent.

```typescript
Deno.cron("sync-data", "*/30 * * * *", async () => {
  const kv = await Deno.openKv();
  const lastSync = await kv.get(["sync", "lastRun"]);

  // Idempotent: skip if already ran recently
  if (lastSync.value && Date.now() - (lastSync.value as number) < 25 * 60 * 1000) {
    return;
  }

  await syncExternalData();
  await kv.set(["sync", "lastRun"], Date.now());
});
```

---

## Deno KV Queues (Deno.Queue)

Deno KV includes a built-in message queue for reliable, ordered background job processing.

### Enqueuing Messages

```typescript
const kv = await Deno.openKv();

// Enqueue a message (will be delivered to a listener)
await kv.enqueue({ type: "send-email", to: "user@example.com", subject: "Welcome" });

// Enqueue with delay (delivered after 30 seconds)
await kv.enqueue(
  { type: "reminder", userId: "u001" },
  { delay: 30_000 }
);

// Enqueue with keysIfUndelivered (dead-letter tracking)
await kv.enqueue(
  { type: "critical-task", id: "t001" },
  { keysIfUndelivered: [["failed_jobs", "t001"]] }
);
```

### Listening for Messages

```typescript
const kv = await Deno.openKv();

kv.listenQueue(async (message: unknown) => {
  const msg = message as { type: string; [key: string]: unknown };

  switch (msg.type) {
    case "send-email":
      await sendEmail(msg.to as string, msg.subject as string);
      break;
    case "reminder":
      await processReminder(msg.userId as string);
      break;
    default:
      console.warn("Unknown message type:", msg.type);
  }
});

// Keep the process running to receive messages
Deno.serve(() => new Response("Queue worker running"));
```

### Atomic Enqueue

```typescript
const kv = await Deno.openKv();

// Atomically update data AND enqueue a notification
await kv.atomic()
  .set(["orders", "o001"], { status: "shipped", updatedAt: Date.now() })
  .enqueue({ type: "order-shipped", orderId: "o001" })
  .commit();
```

---

## BroadcastChannel

The Web Standard `BroadcastChannel` API enables communication between Deno isolates, workers, and (on Deno Deploy) across edge regions.

### Basic Cross-Worker Communication

```typescript
// main.ts
const channel = new BroadcastChannel("app-events");

channel.onmessage = (event: MessageEvent) => {
  console.log("Received:", event.data);
};

// Send a message to all listeners on this channel
channel.postMessage({ type: "user-login", userId: "u001" });
```

### Multi-Instance Coordination (Deno Deploy)

```typescript
const channel = new BroadcastChannel("cache-invalidation");

// Listen for cache invalidation events from other instances
channel.onmessage = (event: MessageEvent) => {
  const { key } = event.data;
  localCache.delete(key);
  console.log(`Cache invalidated: ${key}`);
};

// When data changes, notify all instances
async function updateUser(id: string, data: Record<string, unknown>) {
  const kv = await Deno.openKv();
  await kv.set(["users", id], data);
  channel.postMessage({ key: `user:${id}` });
}
```

### Chat Room Example

```typescript
Deno.serve((req) => {
  if (req.headers.get("upgrade") === "websocket") {
    const { socket, response } = Deno.upgradeWebSocket(req);
    const channel = new BroadcastChannel("chat");

    channel.onmessage = (e: MessageEvent) => {
      socket.send(JSON.stringify(e.data));
    };

    socket.onmessage = (e) => {
      channel.postMessage(JSON.parse(e.data));
    };

    socket.onclose = () => channel.close();
    return response;
  }
  return new Response("WebSocket only", { status: 400 });
});
```

---

## Web Workers

Deno supports Web Workers for CPU-intensive parallel computation.

### Creating a Worker

```typescript
// main.ts
const worker = new Worker(
  new URL("./worker.ts", import.meta.url).href,
  {
    type: "module",
    deno: {
      permissions: {
        read: true,
        net: ["api.example.com"],
      },
    },
  }
);

worker.postMessage({ type: "process", data: largeDataSet });

worker.onmessage = (event: MessageEvent) => {
  console.log("Worker result:", event.data);
};

worker.onerror = (event) => {
  console.error("Worker error:", event.message);
};
```

```typescript
// worker.ts
self.onmessage = async (event: MessageEvent) => {
  const { type, data } = event.data;

  if (type === "process") {
    const result = await heavyComputation(data);
    self.postMessage({ type: "result", result });
  }
};

function heavyComputation(data: unknown[]): unknown {
  // CPU-intensive work runs in parallel, off the main thread
  return data;
}
```

### Worker Pool Pattern

```typescript
class WorkerPool {
  private workers: Worker[] = [];
  private queue: Array<{ data: unknown; resolve: (v: unknown) => void }> = [];
  private idle: Worker[] = [];

  constructor(workerUrl: string, size: number) {
    for (let i = 0; i < size; i++) {
      const worker = new Worker(workerUrl, { type: "module" });
      worker.onmessage = (e: MessageEvent) => {
        this.idle.push(worker);
        this.processQueue();
        // Resolve the pending promise
      };
      this.workers.push(worker);
      this.idle.push(worker);
    }
  }

  async run(data: unknown): Promise<unknown> {
    return new Promise((resolve) => {
      this.queue.push({ data, resolve });
      this.processQueue();
    });
  }

  private processQueue() {
    while (this.idle.length > 0 && this.queue.length > 0) {
      const worker = this.idle.pop()!;
      const task = this.queue.shift()!;
      worker.onmessage = (e: MessageEvent) => {
        this.idle.push(worker);
        task.resolve(e.data);
        this.processQueue();
      };
      worker.postMessage(task.data);
    }
  }

  terminate() {
    this.workers.forEach((w) => w.terminate());
  }
}
```

---

## Deno.Command — Subprocess Management

`Deno.Command` is the stable API for spawning and managing subprocesses.

### Basic Usage

```typescript
// Capture output
const cmd = new Deno.Command("git", {
  args: ["log", "--oneline", "-10"],
  stdout: "piped",
  stderr: "piped",
});

const { code, stdout, stderr } = await cmd.output();
const output = new TextDecoder().decode(stdout);

if (code !== 0) {
  const err = new TextDecoder().decode(stderr);
  throw new Error(`Git failed: ${err}`);
}
console.log(output);
```

### Streaming I/O

```typescript
const cmd = new Deno.Command("ffmpeg", {
  args: ["-i", "input.mp4", "-f", "mp4", "-movflags", "frag_keyframe+empty_moov", "pipe:1"],
  stdout: "piped",
  stderr: "piped",
});

const child = cmd.spawn();

// Stream stdout
const reader = child.stdout.getReader();
while (true) {
  const { done, value } = await reader.read();
  if (done) break;
  // Process chunks
}

const status = await child.status;
```

### Piping Between Commands

```typescript
// Equivalent to: cat file.txt | grep "pattern" | wc -l
const cat = new Deno.Command("cat", {
  args: ["file.txt"],
  stdout: "piped",
});

const grep = new Deno.Command("grep", {
  args: ["pattern"],
  stdin: "piped",
  stdout: "piped",
});

const catChild = cat.spawn();
const grepChild = grep.spawn();

catChild.stdout.pipeTo(grepChild.stdin);

const { stdout } = await grepChild.output();
console.log(new TextDecoder().decode(stdout));
```

### Writing to stdin

```typescript
const cmd = new Deno.Command("python3", {
  args: ["-c", "import sys; print(sys.stdin.read().upper())"],
  stdin: "piped",
  stdout: "piped",
});

const child = cmd.spawn();

const writer = child.stdin.getWriter();
await writer.write(new TextEncoder().encode("hello world"));
await writer.close();

const { stdout } = await child.output();
console.log(new TextDecoder().decode(stdout)); // "HELLO WORLD"
```

---

## Custom Runtimes with deno_core

The `deno_core` Rust crate lets you build custom JavaScript/TypeScript runtimes with Deno's V8 integration.

### Minimal Custom Runtime (Rust)

```rust
// Cargo.toml
// [dependencies]
// deno_core = "0.300"  # Check latest version
// tokio = { version = "1", features = ["full"] }

use deno_core::*;

#[op2]
#[string]
fn op_hello(#[string] name: String) -> String {
    format!("Hello, {}!", name)
}

deno_core::extension!(
    my_extension,
    ops = [op_hello],
);

#[tokio::main]
async fn main() {
    let mut runtime = JsRuntime::new(RuntimeOptions {
        extensions: vec![my_extension::init_ops()],
        ..Default::default()
    });

    runtime
        .execute_script("<main>", ascii_str!(
            r#"const result = Deno.core.ops.op_hello("World");
               console.log(result);"#
        ))
        .unwrap();
}
```

### Adding Async Ops

```rust
#[op2(async)]
#[string]
async fn op_fetch_url(#[string] url: String) -> Result<String, AnyError> {
    let body = reqwest::get(&url).await?.text().await?;
    Ok(body)
}

deno_core::extension!(
    http_ext,
    ops = [op_fetch_url],
);
```

### Use Cases for Custom Runtimes

- **Embedded scripting** — Add JS/TS scripting to your Rust application
- **Serverless platforms** — Build custom FaaS runtimes with specific APIs
- **Game engines** — Embed scripting with custom ops for game logic
- **CLI tools** — Create domain-specific tools with JS extensibility
- **Edge compute** — Build specialized edge runtimes

---

## Embedding Deno

You can embed the full Deno runtime in Rust applications for complete Node/npm compatibility.

### Using deno_runtime

```rust
use deno_runtime::deno_core;
use deno_runtime::worker::MainWorker;
use deno_runtime::worker::WorkerOptions;

async fn run_script(path: &str) {
    let main_module = deno_core::resolve_path(path, &std::env::current_dir().unwrap()).unwrap();
    let mut worker = MainWorker::bootstrap_from_options(
        main_module.clone(),
        WorkerOptions::default(),
    );
    worker.execute_main_module(&main_module).await.unwrap();
    worker.run_event_loop(false).await.unwrap();
}
```

### Key Differences

| Feature | `deno_core` | `deno_runtime` |
|---------|-------------|----------------|
| V8 engine | ✅ | ✅ |
| Custom ops | ✅ | ✅ |
| Node.js compat | ❌ | ✅ |
| npm support | ❌ | ✅ |
| Permissions | ❌ | ✅ |
| Web APIs (fetch, etc.) | ❌ | ✅ |
| Binary size | ~20MB | ~60MB+ |

---

## Performance Profiling (V8 Flags)

Deno exposes V8 engine flags for profiling and tuning.

### V8 Flags

```bash
# List all V8 flags
deno run --v8-flags=--help script.ts

# CPU profiling
deno run --v8-flags=--prof script.ts
# Process the generated v8.log:
# node --prof-process v8.log > profile.txt

# Heap snapshot
deno run --v8-flags=--heap-prof script.ts

# Trace optimizations/deoptimizations
deno run --v8-flags=--trace-opt,--trace-deopt script.ts

# Increase heap size (default ~1.7GB)
deno run --v8-flags=--max-old-space-size=4096 script.ts

# Expose GC for manual triggering
deno run --v8-flags=--expose-gc script.ts
```

### Built-in Profiling

```bash
# Deno's built-in benchmarking
deno bench bench.ts

# Coverage profiling
deno test --coverage=cov && deno coverage cov --lcov > cov.lcov
```

### Runtime Performance Tips

```typescript
// Use typed arrays for large data
const buffer = new Float64Array(1_000_000);

// Prefer Web Streams over manual buffering
const file = await Deno.open("large.bin");
const stream = file.readable;

// Use structured clone for worker data transfer
worker.postMessage(data, [data.buffer]); // Transfer, not copy

// Batch KV operations with atomic()
const atomic = kv.atomic();
for (const item of items) {
  atomic.set(["items", item.id], item);
}
await atomic.commit();
```

---

## deno serve — Multi-threaded HTTP

`deno serve` enables multi-threaded HTTP serving using Deno's built-in load balancer.

```typescript
// main.ts — export default fetch handler
export default {
  fetch(req: Request): Response {
    return new Response(`Hello from ${Deno.pid}`);
  },
};
```

```bash
# Run with multiple parallel workers
deno serve --parallel --port=8000 main.ts

# Specify worker count
deno serve --parallel=4 --port=8000 main.ts
```

---

## Deno Compile — Standalone Binaries

### Advanced Compilation

```bash
# Cross-compile for different targets
deno compile --target=x86_64-unknown-linux-gnu --output=app-linux src/main.ts
deno compile --target=aarch64-apple-darwin --output=app-mac-arm src/main.ts
deno compile --target=x86_64-pc-windows-msvc --output=app.exe src/main.ts

# Embed static assets
deno compile --include=./static --include=./templates src/main.ts

# With permissions baked in
deno compile --allow-net --allow-read=./data --allow-env=API_KEY src/main.ts
```

### Reading Embedded Files

```typescript
// Access embedded files at runtime
const html = await Deno.readTextFile(new URL("./static/index.html", import.meta.url));
```

---

## Advanced Testing Patterns

### Snapshot Testing

```typescript
import { assertSnapshot } from "@std/testing/snapshot";

Deno.test("snapshot test", async (t) => {
  const result = generateReport();
  await assertSnapshot(t, result);
});
```

```bash
# Update snapshots
deno test --allow-read --allow-write -- --update
```

### BDD-Style Testing

```typescript
import { describe, it, beforeEach } from "@std/testing/bdd";
import { assertEquals } from "@std/assert";

describe("UserService", () => {
  let service: UserService;

  beforeEach(() => {
    service = new UserService();
  });

  it("should create user", () => {
    const user = service.create("Alice");
    assertEquals(user.name, "Alice");
  });

  describe("validation", () => {
    it("should reject empty names", () => {
      // ...
    });
  });
});
```

### Mocking and Stubbing

```typescript
import { stub, spy, assertSpyCalls } from "@std/testing/mock";

Deno.test("mock example", () => {
  const fetchStub = stub(globalThis, "fetch", () =>
    Promise.resolve(new Response('{"ok":true}'))
  );

  try {
    // test code that calls fetch
    assertSpyCalls(fetchStub, 1);
  } finally {
    fetchStub.restore();
  }
});
```

---

## Streaming and Server-Sent Events

### Server-Sent Events

```typescript
Deno.serve((req) => {
  const url = new URL(req.url);
  if (url.pathname === "/events") {
    const body = new ReadableStream({
      start(controller) {
        const encoder = new TextEncoder();
        let id = 0;

        const timer = setInterval(() => {
          const data = JSON.stringify({ time: new Date().toISOString(), id: ++id });
          controller.enqueue(encoder.encode(`id: ${id}\ndata: ${data}\n\n`));
        }, 1000);

        req.signal.addEventListener("abort", () => {
          clearInterval(timer);
          controller.close();
        });
      },
    });

    return new Response(body, {
      headers: {
        "Content-Type": "text/event-stream",
        "Cache-Control": "no-cache",
        "Connection": "keep-alive",
      },
    });
  }
  return new Response("Not Found", { status: 404 });
});
```

### Streaming JSON Responses

```typescript
Deno.serve(async (req) => {
  const stream = new ReadableStream({
    async start(controller) {
      const encoder = new TextEncoder();
      const kv = await Deno.openKv();

      for await (const entry of kv.list({ prefix: ["records"] })) {
        controller.enqueue(encoder.encode(JSON.stringify(entry.value) + "\n"));
      }
      controller.close();
    },
  });

  return new Response(stream, {
    headers: { "Content-Type": "application/x-ndjson" },
  });
});
```
