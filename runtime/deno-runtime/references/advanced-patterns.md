# Deno 2.x Advanced Patterns

## Table of Contents

- [Custom Permission Strategies](#custom-permission-strategies)
- [FFI with Rust and C Libraries](#ffi-with-rust-and-c-libraries)
- [Web Workers and Structured Concurrency](#web-workers-and-structured-concurrency)
- [Deno KV Advanced Patterns](#deno-kv-advanced-patterns)
- [Fresh 2.x Islands Architecture](#fresh-2x-islands-architecture)
- [Deno Deploy Edge Functions](#deno-deploy-edge-functions)
- [Testing Strategies](#testing-strategies)
- [Performance Profiling and Optimization](#performance-profiling-and-optimization)
- [WASM Integration](#wasm-integration)

---

## Custom Permission Strategies

### Principle of Least Privilege

Always scope permissions to the minimum required. Use path-specific and host-specific grants:

```bash
# Bad: overly broad
deno run -A server.ts

# Good: scoped to what the app actually needs
deno run \
  --allow-net=0.0.0.0:8000,api.stripe.com \
  --allow-read=./public,./config \
  --allow-env=DATABASE_URL,STRIPE_KEY \
  --deny-write \
  server.ts
```

### Runtime Permission Requests

Request permissions dynamically with `Deno.permissions.request()`:

```typescript
const netStatus = await Deno.permissions.request({
  name: "net",
  host: "api.example.com",
});

if (netStatus.state === "granted") {
  const res = await fetch("https://api.example.com/data");
  console.log(await res.json());
} else {
  console.error("Network permission denied — running in offline mode");
}
```

### Permission Guard Pattern

Create a guard that validates permissions before starting the application:

```typescript
async function requirePermissions(
  perms: Deno.PermissionDescriptor[],
): Promise<void> {
  const denied: string[] = [];
  for (const perm of perms) {
    const status = await Deno.permissions.query(perm);
    if (status.state !== "granted") {
      denied.push(
        `${perm.name}${
          "host" in perm ? `:${perm.host}` : "path" in perm ? `:${perm.path}` : ""
        }`,
      );
    }
  }
  if (denied.length > 0) {
    console.error(`Missing permissions: ${denied.join(", ")}`);
    console.error("Run with: deno run " + denied.map((d) => `--allow-${d}`).join(" "));
    Deno.exit(1);
  }
}

await requirePermissions([
  { name: "net", host: "0.0.0.0:8000" },
  { name: "read", path: "./data" },
  { name: "env", variable: "API_KEY" },
]);
```

### Per-Test Permission Scoping

```typescript
Deno.test({
  name: "reads config file",
  permissions: { read: ["./config"] },
  fn: async () => {
    const config = await Deno.readTextFile("./config/app.json");
    assertEquals(JSON.parse(config).port, 8000);
  },
});

Deno.test({
  name: "no network access allowed",
  permissions: { net: false },
  fn: () => {
    assertRejects(
      () => fetch("https://example.com"),
      Deno.errors.PermissionDenied,
    );
  },
});
```

---

## FFI with Rust and C Libraries

### Loading a Shared Library

```typescript
// Define the foreign symbols interface
const lib = Deno.dlopen("./target/release/libmyrust.so", {
  add: { parameters: ["i32", "i32"], result: "i32" },
  greet: { parameters: ["buffer", "usize"], result: "void" },
  create_handle: { parameters: [], result: "pointer" },
  free_handle: { parameters: ["pointer"], result: "void" },
  async_compute: {
    parameters: ["f64"],
    result: "f64",
    nonblocking: true,  // runs on a separate thread, returns Promise
  },
});

console.log(lib.symbols.add(10, 20)); // 30

// Async FFI — doesn't block the event loop
const result = await lib.symbols.async_compute(3.14);
console.log(result);

lib.close();
```

### Rust Side — Creating a Shared Library

```toml
# Cargo.toml
[lib]
crate-type = ["cdylib"]
```

```rust
// src/lib.rs
#[no_mangle]
pub extern "C" fn add(a: i32, b: i32) -> i32 {
    a + b
}

#[no_mangle]
pub extern "C" fn greet(buf: *const u8, len: usize) {
    let name = unsafe {
        let slice = std::slice::from_raw_parts(buf, len);
        std::str::from_utf8(slice).unwrap_or("world")
    };
    println!("Hello, {name}!");
}
```

### Passing Strings and Buffers

```typescript
function callWithString(lib: Deno.DynamicLibrary<any>, str: string) {
  const encoder = new TextEncoder();
  const encoded = encoder.encode(str);
  const buf = new Uint8Array(encoded.length);
  buf.set(encoded);
  lib.symbols.greet(buf, buf.length);
}

callWithString(lib, "Deno");
```

### Struct Handling via Pointers

```typescript
const lib = Deno.dlopen("./libstructs.so", {
  create_point: { parameters: ["f64", "f64"], result: "pointer" },
  get_point_x: { parameters: ["pointer"], result: "f64" },
  get_point_y: { parameters: ["pointer"], result: "f64" },
  free_point: { parameters: ["pointer"], result: "void" },
});

const point = lib.symbols.create_point(3.0, 4.0);
console.log(lib.symbols.get_point_x(point)); // 3.0
console.log(lib.symbols.get_point_y(point)); // 4.0
lib.symbols.free_point(point);
lib.close();
```

### FFI Callback Pattern

```typescript
const lib = Deno.dlopen("./libcallback.so", {
  register_callback: {
    parameters: ["function"],
    result: "void",
  },
  trigger: { parameters: [], result: "void" },
});

const callback = new Deno.UnsafeCallback(
  { parameters: ["i32"], result: "void" },
  (value: number) => {
    console.log(`Callback received: ${value}`);
  },
);

lib.symbols.register_callback(callback.pointer);
lib.symbols.trigger();
callback.close();
lib.close();
```

---

## Web Workers and Structured Concurrency

### Basic Worker Usage

```typescript
// main.ts
const worker = new Worker(new URL("./worker.ts", import.meta.url).href, {
  type: "module",
  deno: {
    permissions: {
      net: ["api.example.com"],
      read: false,
      write: false,
    },
  },
});

worker.postMessage({ type: "process", data: [1, 2, 3, 4, 5] });

worker.onmessage = (e) => {
  console.log("Result from worker:", e.data);
  worker.terminate();
};
```

```typescript
// worker.ts
self.onmessage = (e: MessageEvent) => {
  if (e.data.type === "process") {
    const result = e.data.data.map((n: number) => n * n);
    self.postMessage({ type: "result", data: result });
  }
};
```

### Worker Pool Pattern

```typescript
class WorkerPool {
  private workers: Worker[] = [];
  private queue: Array<{
    data: unknown;
    resolve: (value: unknown) => void;
    reject: (reason?: unknown) => void;
  }> = [];
  private available: Worker[] = [];

  constructor(workerUrl: string, size: number) {
    for (let i = 0; i < size; i++) {
      const worker = new Worker(workerUrl, { type: "module" });
      worker.onmessage = (e) => this.handleResult(worker, e.data);
      this.workers.push(worker);
      this.available.push(worker);
    }
  }

  private handleResult(worker: Worker, result: unknown) {
    this.available.push(worker);
    const next = this.queue.shift();
    if (next) {
      this.dispatch(next);
    }
  }

  private dispatch(task: typeof this.queue[number]) {
    const worker = this.available.pop()!;
    worker.onmessage = (e) => {
      task.resolve(e.data);
      this.available.push(worker);
      const next = this.queue.shift();
      if (next) this.dispatch(next);
    };
    worker.postMessage(task.data);
  }

  async execute(data: unknown): Promise<unknown> {
    return new Promise((resolve, reject) => {
      const task = { data, resolve, reject };
      if (this.available.length > 0) {
        this.dispatch(task);
      } else {
        this.queue.push(task);
      }
    });
  }

  terminate() {
    this.workers.forEach((w) => w.terminate());
  }
}

// Usage
const pool = new WorkerPool(
  new URL("./worker.ts", import.meta.url).href,
  navigator.hardwareConcurrency,
);

const results = await Promise.all(
  Array.from({ length: 100 }, (_, i) => pool.execute({ index: i })),
);
pool.terminate();
```

### Structured Concurrency with AbortController

```typescript
async function withTimeout<T>(
  fn: (signal: AbortSignal) => Promise<T>,
  ms: number,
): Promise<T> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), ms);
  try {
    return await fn(controller.signal);
  } finally {
    clearTimeout(timer);
  }
}

// Fan-out/fan-in with cancellation
async function fetchAllWithCancel(urls: string[]): Promise<Response[]> {
  const controller = new AbortController();
  try {
    return await Promise.all(
      urls.map((url) => fetch(url, { signal: controller.signal })),
    );
  } catch (err) {
    controller.abort();
    throw err;
  }
}

// Race pattern — first result wins
const result = await withTimeout(
  (signal) =>
    Promise.race([
      fetch("https://api1.example.com/data", { signal }),
      fetch("https://api2.example.com/data", { signal }),
    ]),
  5000,
);
```

---

## Deno KV Advanced Patterns

### Atomic Transactions with Optimistic Locking

```typescript
const kv = await Deno.openKv();

// Transfer balance between accounts atomically
async function transfer(
  from: string,
  to: string,
  amount: number,
): Promise<boolean> {
  let retries = 5;
  while (retries-- > 0) {
    const fromEntry = await kv.get<number>(["accounts", from, "balance"]);
    const toEntry = await kv.get<number>(["accounts", to, "balance"]);

    if (!fromEntry.value || fromEntry.value < amount) {
      throw new Error("Insufficient funds");
    }

    const result = await kv.atomic()
      .check(fromEntry)  // verify versions haven't changed
      .check(toEntry)
      .set(["accounts", from, "balance"], fromEntry.value - amount)
      .set(["accounts", to, "balance"], (toEntry.value ?? 0) + amount)
      .set(["transactions", crypto.randomUUID()], {
        from,
        to,
        amount,
        timestamp: Date.now(),
      })
      .commit();

    if (result.ok) return true;
    // Version conflict — retry
  }
  throw new Error("Transfer failed after retries");
}
```

### Watch for Real-Time Updates

```typescript
const kv = await Deno.openKv();

// Watch multiple keys for changes
const stream = kv.watch([
  ["config", "feature_flags"],
  ["config", "rate_limit"],
]);

for await (const entries of stream) {
  for (const entry of entries) {
    if (entry.value !== null) {
      console.log(`Config changed: ${entry.key} → ${JSON.stringify(entry.value)}`);
    }
  }
}
```

### Queue Processing Pattern

```typescript
const kv = await Deno.openKv();

interface EmailJob {
  type: "email";
  to: string;
  subject: string;
  body: string;
}

interface WebhookJob {
  type: "webhook";
  url: string;
  payload: Record<string, unknown>;
}

type Job = EmailJob | WebhookJob;

// Enqueue with delay
await kv.enqueue(
  { type: "email", to: "user@example.com", subject: "Welcome!", body: "..." } as Job,
  { delay: 5000 },  // delay 5 seconds
);

// Process queue with error handling
kv.listenQueue(async (msg: Job) => {
  try {
    switch (msg.type) {
      case "email":
        await sendEmail(msg);
        break;
      case "webhook":
        await deliverWebhook(msg);
        break;
    }
  } catch (err) {
    // Re-enqueue with exponential backoff
    console.error(`Job failed: ${err}`);
    await kv.enqueue(msg, { delay: 30000 });
  }
});
```

### Secondary Indexes Pattern

```typescript
const kv = await Deno.openKv();

interface User {
  id: string;
  email: string;
  name: string;
  role: "admin" | "user";
}

async function createUser(user: User): Promise<void> {
  const result = await kv.atomic()
    .check({ key: ["users", user.id], versionstamp: null })           // ensure no conflict
    .check({ key: ["users_by_email", user.email], versionstamp: null }) // unique email
    .set(["users", user.id], user)                                     // primary key
    .set(["users_by_email", user.email], user.id)                      // secondary index
    .set(["users_by_role", user.role, user.id], user.id)               // role index
    .commit();

  if (!result.ok) throw new Error("User already exists or email taken");
}

// Lookup by email
async function getUserByEmail(email: string): Promise<User | null> {
  const idEntry = await kv.get<string>(["users_by_email", email]);
  if (!idEntry.value) return null;
  const userEntry = await kv.get<User>(["users", idEntry.value]);
  return userEntry.value;
}

// List all admins
async function getAdmins(): Promise<User[]> {
  const admins: User[] = [];
  for await (const entry of kv.list<string>({ prefix: ["users_by_role", "admin"] })) {
    const user = await kv.get<User>(["users", entry.value]);
    if (user.value) admins.push(user.value);
  }
  return admins;
}
```

---

## Fresh 2.x Islands Architecture

### How Islands Work

Fresh uses island architecture: pages are server-rendered HTML by default.
Only components placed in `islands/` are hydrated on the client, keeping bundle
size minimal.

```
my-app/
├── routes/
│   ├── _app.tsx          # App wrapper (layout)
│   ├── _layout.tsx       # Shared layout
│   ├── index.tsx         # Page route (server-rendered)
│   ├── about.tsx         # Another page
│   └── api/
│       └── users.ts      # API endpoint
├── islands/
│   ├── Counter.tsx        # Interactive — hydrated on client
│   └── SearchBar.tsx      # Interactive — hydrated on client
├── components/
│   └── Header.tsx         # Static — no client JS
├── static/
│   └── styles.css
├── fresh.gen.ts           # Auto-generated manifest
└── deno.json
```

### Island with Server Data

```tsx
// routes/dashboard.tsx — server-rendered page
import Counter from "../islands/Counter.tsx";
import Chart from "../islands/Chart.tsx";

export default async function DashboardPage(req: Request, ctx: FreshContext) {
  // This runs ONLY on the server
  const stats = await fetchStats();

  return (
    <div class="dashboard">
      <h1>Dashboard</h1>
      {/* Static — no JS sent to client */}
      <p>Total users: {stats.totalUsers}</p>

      {/* Island — hydrated on client with serialized props */}
      <Counter initialCount={stats.activeCount} />
      <Chart data={stats.chartData} />
    </div>
  );
}
```

### Nested Islands and Slots

```tsx
// islands/Accordion.tsx
import { Signal, useSignal } from "@preact/signals";
import type { ComponentChildren } from "preact";

interface AccordionProps {
  title: string;
  children: ComponentChildren;  // Server HTML passed as slot
}

export default function Accordion({ title, children }: AccordionProps) {
  const open = useSignal(false);
  return (
    <div class="accordion">
      <button onClick={() => (open.value = !open.value)}>
        {title} {open.value ? "▼" : "▶"}
      </button>
      {open.value && <div class="content">{children}</div>}
    </div>
  );
}
```

### Middleware

```typescript
// routes/_middleware.ts
import { FreshContext } from "$fresh/server.ts";

export async function handler(req: Request, ctx: FreshContext) {
  const start = performance.now();

  // Auth check
  const token = req.headers.get("Authorization")?.replace("Bearer ", "");
  if (ctx.destination === "route" && !token) {
    return new Response("Unauthorized", { status: 401 });
  }

  ctx.state.user = await validateToken(token);

  const resp = await ctx.next();
  const duration = performance.now() - start;
  resp.headers.set("X-Response-Time", `${duration.toFixed(1)}ms`);
  return resp;
}
```

### Plugins and Custom Head

```typescript
// fresh.config.ts
import { defineConfig } from "$fresh/server.ts";
import twindPlugin from "$fresh/plugins/twind.ts";
import twindConfig from "./twind.config.ts";

export default defineConfig({
  plugins: [twindPlugin(twindConfig)],
});
```

---

## Deno Deploy Edge Functions

### Region-Aware Routing

```typescript
Deno.serve((req) => {
  const region = Deno.env.get("DENO_REGION") ?? "unknown";
  const deployment = Deno.env.get("DENO_DEPLOYMENT_ID") ?? "local";

  return Response.json({
    region,
    deployment,
    timestamp: new Date().toISOString(),
  });
});
```

### Edge KV with Caching

```typescript
const kv = await Deno.openKv();

Deno.serve(async (req) => {
  const url = new URL(req.url);
  const cacheKey = ["page_cache", url.pathname];

  // Check cache
  const cached = await kv.get<{ html: string; cachedAt: number }>(cacheKey);
  if (cached.value && Date.now() - cached.value.cachedAt < 60_000) {
    return new Response(cached.value.html, {
      headers: {
        "Content-Type": "text/html",
        "X-Cache": "HIT",
      },
    });
  }

  // Generate page
  const html = await renderPage(url.pathname);

  // Cache for 1 minute
  await kv.set(cacheKey, { html, cachedAt: Date.now() });

  return new Response(html, {
    headers: {
      "Content-Type": "text/html",
      "X-Cache": "MISS",
    },
  });
});
```

### Scheduled Tasks (Cron)

```typescript
// Deno Deploy supports Deno.cron for scheduled tasks
Deno.cron("cleanup old sessions", "0 */6 * * *", async () => {
  const kv = await Deno.openKv();
  const cutoff = Date.now() - 86400_000; // 24 hours ago
  for await (const entry of kv.list<{ createdAt: number }>({ prefix: ["sessions"] })) {
    if (entry.value.createdAt < cutoff) {
      await kv.delete(entry.key);
    }
  }
});

Deno.cron("send daily digest", "0 9 * * *", async () => {
  const users = await getSubscribedUsers();
  for (const user of users) {
    await sendDigestEmail(user);
  }
});
```

### BroadcastChannel for Multi-Isolate Communication

```typescript
const channel = new BroadcastChannel("app-events");

channel.onmessage = (event) => {
  console.log("Received:", event.data);
};

Deno.serve(async (req) => {
  if (req.method === "POST" && new URL(req.url).pathname === "/invalidate") {
    const body = await req.json();
    channel.postMessage({ type: "cache-invalidate", key: body.key });
    return Response.json({ status: "broadcasted" });
  }
  return new Response("OK");
});
```

---

## Testing Strategies

### Mocking and Stubbing

```typescript
import { assertEquals } from "jsr:@std/assert";
import { stub, assertSpyCalls, returnsNext } from "jsr:@std/testing/mock";

// Stub a global function
Deno.test("fetch mock", async () => {
  const fetchStub = stub(
    globalThis,
    "fetch",
    returnsNext([
      new Response(JSON.stringify({ users: ["Alice"] }), { status: 200 }),
    ]),
  );

  try {
    const res = await fetch("https://api.example.com/users");
    assertEquals((await res.json()).users, ["Alice"]);
    assertSpyCalls(fetchStub, 1);
  } finally {
    fetchStub.restore();
  }
});

// Stub Deno APIs
Deno.test("env mock", () => {
  const envStub = stub(Deno.env, "get", (key: string) => {
    if (key === "API_KEY") return "test-key-123";
    return undefined;
  });

  try {
    assertEquals(Deno.env.get("API_KEY"), "test-key-123");
  } finally {
    envStub.restore();
  }
});
```

### Snapshot Testing

```typescript
import { assertSnapshot } from "jsr:@std/testing/snapshot";

Deno.test("config snapshot", async (t) => {
  const config = generateConfig({ env: "production", port: 8000 });
  await assertSnapshot(t, config);
  // First run: creates __snapshots__/test.ts.snap
  // Subsequent runs: asserts against snapshot
  // Update: deno test --allow-read --allow-write -- --update
});

Deno.test("HTML output snapshot", async (t) => {
  const html = renderTemplate({ title: "Home", items: ["a", "b"] });
  await assertSnapshot(t, html);
});
```

### BDD-Style Testing

```typescript
import { describe, it, beforeEach, afterEach } from "jsr:@std/testing/bdd";
import { assertEquals, assertRejects } from "jsr:@std/assert";

describe("UserService", () => {
  let service: UserService;
  let kv: Deno.Kv;

  beforeEach(async () => {
    kv = await Deno.openKv(":memory:");
    service = new UserService(kv);
  });

  afterEach(() => {
    kv.close();
  });

  describe("createUser", () => {
    it("should create a user with valid data", async () => {
      const user = await service.createUser({ name: "Alice", email: "a@b.com" });
      assertEquals(user.name, "Alice");
    });

    it("should reject duplicate emails", async () => {
      await service.createUser({ name: "Alice", email: "a@b.com" });
      await assertRejects(
        () => service.createUser({ name: "Bob", email: "a@b.com" }),
        Error,
        "Email already exists",
      );
    });
  });
});
```

### Integration Testing with Real Server

```typescript
import { assertEquals } from "jsr:@std/assert";

Deno.test("API integration", async () => {
  // Start server
  const ac = new AbortController();
  const server = Deno.serve(
    { port: 0, signal: ac.signal, onListen: () => {} },
    (req) => {
      if (new URL(req.url).pathname === "/health") {
        return Response.json({ status: "ok" });
      }
      return new Response("Not found", { status: 404 });
    },
  );

  const port = server.addr.port;

  try {
    const res = await fetch(`http://localhost:${port}/health`);
    assertEquals(res.status, 200);
    assertEquals((await res.json()).status, "ok");
  } finally {
    ac.abort();
    await server.finished;
  }
});
```

---

## Performance Profiling and Optimization

### Built-in Benchmarking

```typescript
// bench.ts
Deno.bench("JSON.parse small", () => {
  JSON.parse('{"name":"Alice","age":30}');
});

Deno.bench("JSON.parse large", () => {
  JSON.parse(JSON.stringify(Array.from({ length: 1000 }, (_, i) => ({ id: i }))));
});

Deno.bench({
  name: "file read",
  group: "io",
  baseline: true,
  fn: async () => {
    await Deno.readTextFile("./test_data.txt");
  },
});

Deno.bench({
  name: "file read (buffered)",
  group: "io",
  fn: async () => {
    const file = await Deno.open("./test_data.txt");
    const buf = new Uint8Array(4096);
    while ((await file.read(buf)) !== null) { /* drain */ }
    file.close();
  },
});
```

Run with: `deno bench --allow-read bench.ts`

### V8 CPU Profiling

```bash
# Generate V8 CPU profile
deno run --v8-flags=--prof main.ts
# Process the isolate log
deno run --v8-flags=--prof-process isolate-*.log > profile.txt
```

### Memory Optimization Patterns

```typescript
// Stream large files instead of loading into memory
async function processLargeFile(path: string): Promise<number> {
  const file = await Deno.open(path);
  let lines = 0;
  const decoder = new TextDecoder();
  const buf = new Uint8Array(64 * 1024);
  let remaining = "";

  let bytesRead: number | null;
  while ((bytesRead = await file.read(buf)) !== null) {
    const chunk = remaining + decoder.decode(buf.subarray(0, bytesRead), { stream: true });
    const parts = chunk.split("\n");
    remaining = parts.pop()!;
    lines += parts.length;
  }
  if (remaining) lines++;
  file.close();
  return lines;
}

// Use ReadableStream transforms for pipeline processing
async function transformCSV(input: string, output: string) {
  const file = await Deno.open(input);
  const outFile = await Deno.open(output, { write: true, create: true });
  const encoder = new TextEncoder();

  await file.readable
    .pipeThrough(new TextDecoderStream())
    .pipeThrough(new TransformStream({
      transform(chunk, controller) {
        controller.enqueue(chunk.toUpperCase());
      },
    }))
    .pipeThrough(new TextEncoderStream())
    .pipeTo(outFile.writable);
}
```

### Connection Pooling and Caching

```typescript
// Simple in-memory TTL cache
class TTLCache<T> {
  private cache = new Map<string, { value: T; expires: number }>();

  set(key: string, value: T, ttlMs: number): void {
    this.cache.set(key, { value, expires: Date.now() + ttlMs });
  }

  get(key: string): T | undefined {
    const entry = this.cache.get(key);
    if (!entry) return undefined;
    if (Date.now() > entry.expires) {
      this.cache.delete(key);
      return undefined;
    }
    return entry.value;
  }
}

const cache = new TTLCache<unknown>();

Deno.serve(async (req) => {
  const url = new URL(req.url);
  const cached = cache.get(url.pathname);
  if (cached) return Response.json(cached);

  const data = await fetchExpensiveData(url.pathname);
  cache.set(url.pathname, data, 30_000);
  return Response.json(data);
});
```

---

## WASM Integration

### Loading and Running WASM

```typescript
// Load from file
const wasmCode = await Deno.readFile("./module.wasm");
const wasmModule = new WebAssembly.Module(wasmCode);
const wasmInstance = new WebAssembly.Instance(wasmModule, {
  env: {
    log: (ptr: number, len: number) => {
      const memory = wasmInstance.exports.memory as WebAssembly.Memory;
      const bytes = new Uint8Array(memory.buffer, ptr, len);
      console.log(new TextDecoder().decode(bytes));
    },
  },
});

const { add, fibonacci } = wasmInstance.exports as {
  add: (a: number, b: number) => number;
  fibonacci: (n: number) => number;
};

console.log(add(40, 2));       // 42
console.log(fibonacci(10));    // 55
```

### Streaming WASM Compilation

```typescript
// Streaming compilation — starts compiling while downloading
const module = await WebAssembly.compileStreaming(
  fetch("https://example.com/module.wasm"),
);

const instance = await WebAssembly.instantiate(module, {});
```

### WASM with Rust (wasm-bindgen)

Build your Rust project targeting `wasm32-unknown-unknown`:

```bash
cargo build --target wasm32-unknown-unknown --release
wasm-bindgen target/wasm32-unknown-unknown/release/my_lib.wasm \
  --out-dir ./wasm --target deno
```

```typescript
// Import the generated bindings
import init, { process_data } from "./wasm/my_lib.js";

await init();
const result = process_data(new Uint8Array([1, 2, 3, 4]));
console.log(result);
```

### WASM SIMD and Threads

```typescript
// Check for WASM feature support
const features = {
  simd: WebAssembly.validate(
    new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0, 1, 5, 1, 96, 0, 1, 123, 3, 2, 1, 0, 10, 10, 1, 8, 0, 65, 0, 253, 15, 253, 98, 11]),
  ),
};

console.log("WASM SIMD supported:", features.simd);
```

### WASM + Deno.serve for Compute-Heavy Endpoints

```typescript
const wasmCode = await Deno.readFile("./image_processor.wasm");
const module = new WebAssembly.Module(wasmCode);

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("POST only", { status: 405 });

  // Each request gets its own WASM instance (isolated memory)
  const instance = new WebAssembly.Instance(module, {});
  const { memory, resize_image, alloc, dealloc } = instance.exports as any;

  const input = new Uint8Array(await req.arrayBuffer());
  const ptr = alloc(input.length);
  new Uint8Array(memory.buffer).set(input, ptr);

  const resultPtr = resize_image(ptr, input.length, 800, 600);
  const resultLen = new DataView(memory.buffer).getUint32(resultPtr, true);
  const result = new Uint8Array(memory.buffer, resultPtr + 4, resultLen).slice();

  dealloc(ptr, input.length);
  dealloc(resultPtr, resultLen + 4);

  return new Response(result, {
    headers: { "Content-Type": "image/webp" },
  });
});
```
