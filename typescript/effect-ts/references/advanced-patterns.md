# Effect-TS Advanced Patterns

## Table of Contents

- [Layer Composition](#layer-composition)
- [Scope and Resource Management](#scope-and-resource-management)
- [Fiber Management](#fiber-management)
- [Ref, Queue, and Hub](#ref-queue-and-hub)
- [Schedule and Retry Policies](#schedule-and-retry-policies)
- [Cause: Defects vs Failures](#cause-defects-vs-failures)
- [Custom Annotations and Tracing](#custom-annotations-and-tracing)
- [Platform-Specific Patterns](#platform-specific-patterns)

---

## Layer Composition

### Layer.merge — Combining Independent Layers

`Layer.merge` combines two layers that do not depend on each other into a single layer providing both services.

```typescript
import { Layer } from "effect"

// Two independent services
const AppLayer = Layer.merge(DatabaseLive, CacheLive)
// Provides: Database | Cache
// Requires: union of both layers' requirements
```

**Key behavior:** `Layer.merge` shares initialization — if both layers require the same dependency, it is created once.

### Layer.provide — Wiring Dependencies

`Layer.provide` feeds one layer's output into another layer's requirements.

```typescript
const UserRepoLive = Layer.effect(
  UserRepo,
  Effect.gen(function* () {
    const db = yield* Database
    return { findById: (id) => db.query(id) }
  })
)

// Wire Database into UserRepo
const FullLayer = UserRepoLive.pipe(Layer.provide(DatabaseLive))
// FullLayer provides UserRepo, requires nothing (assuming DatabaseLive is self-contained)
```

### Layer.provideMerge — Provide and Keep

When you want to provide a dependency **and** also expose it to the final app:

```typescript
const AppLayer = UserRepoLive.pipe(Layer.provideMerge(DatabaseLive))
// Provides: UserRepo | Database
```

### Layer.effect vs Layer.scoped

- `Layer.effect` — creates a layer from an `Effect`. Suitable when no cleanup is needed.
- `Layer.scoped` — creates a layer from a scoped `Effect`. Use when the service acquires resources that must be released.

```typescript
const DatabaseLive = Layer.scoped(
  Database,
  Effect.gen(function* () {
    const pool = yield* Effect.acquireRelease(
      Effect.tryPromise(() => createPool(config)),
      (pool) => Effect.promise(() => pool.end())
    )
    return { query: (sql) => Effect.tryPromise(() => pool.query(sql)) }
  })
)
```

### ManagedRuntime

`ManagedRuntime` creates a runtime with pre-built layers, useful for integrating Effect into non-Effect entry points (e.g., Express middleware, AWS Lambda handlers).

```typescript
import { ManagedRuntime } from "effect"

const runtime = ManagedRuntime.make(AppLayer)

// In an Express route handler
app.get("/users/:id", async (req, res) => {
  const result = await runtime.runPromise(
    Effect.gen(function* () {
      const repo = yield* UserRepo
      return yield* repo.findById(req.params.id)
    })
  )
  res.json(result)
})

// Cleanup when shutting down
process.on("SIGTERM", () => runtime.dispose())
```

### Layer Composition Patterns

```typescript
// Diamond dependency — shared initialization
//   AppConfig
//   /      \
// Database  Cache
//   \      /
//   UserRepo

const AppConfigLive = Layer.succeed(AppConfig, { dbUrl: "...", cacheUrl: "..." })

const DatabaseLive = Layer.effect(Database, Effect.gen(function* () {
  const config = yield* AppConfig
  return makeDatabaseClient(config.dbUrl)
}))

const CacheLive = Layer.effect(Cache, Effect.gen(function* () {
  const config = yield* AppConfig
  return makeCacheClient(config.cacheUrl)
}))

const UserRepoLive = Layer.effect(UserRepo, Effect.gen(function* () {
  const db = yield* Database
  const cache = yield* Cache
  return makeUserRepo(db, cache)
}))

// Compose bottom-up
const InfraLayer = Layer.merge(DatabaseLive, CacheLive).pipe(
  Layer.provide(AppConfigLive)
)
const AppLayer = UserRepoLive.pipe(Layer.provide(InfraLayer))
```

---

## Scope and Resource Management

### acquireRelease

Guarantees cleanup even on error or fiber interruption.

```typescript
const managedFile = Effect.acquireRelease(
  Effect.sync(() => fs.openSync("/tmp/data.txt", "r")),  // acquire
  (fd) => Effect.sync(() => fs.closeSync(fd))              // release
)

// Must wrap in Effect.scoped to finalize
const program = Effect.scoped(
  Effect.gen(function* () {
    const fd = yield* managedFile
    return yield* readFromFd(fd)
  })
)
```

### addFinalizer

Add cleanup logic at any point within a scope without needing the acquire/release pattern:

```typescript
const program = Effect.gen(function* () {
  yield* Effect.addFinalizer(() =>
    Effect.log("Cleaning up...").pipe(Effect.orDie)
  )
  // ... do work ...
  yield* Effect.log("Working...")
})

// Run with scope
Effect.runPromise(Effect.scoped(program))
// Output: "Working..." then "Cleaning up..."
```

### Nested Scopes

Scopes can be nested. Inner scopes finalize before outer scopes:

```typescript
const program = Effect.scoped(
  Effect.gen(function* () {
    const outerConn = yield* acquireDbConnection
    yield* Effect.scoped(
      Effect.gen(function* () {
        const tempFile = yield* acquireTempFile
        // tempFile released here, outerConn still alive
      })
    )
    // outerConn still alive here
  })
)
// outerConn released here
```

### Layer as Scope

Layers automatically manage scope. Resources acquired in `Layer.scoped` are released when the layer is finalized (typically at program exit or `ManagedRuntime.dispose()`).

---

## Fiber Management

### fork — Background Execution

```typescript
const program = Effect.gen(function* () {
  // Fork returns immediately with a Fiber handle
  const fiber = yield* Effect.fork(longComputation)

  // Do other work concurrently
  yield* doSomethingElse()

  // Wait for the fiber's result
  const result = yield* Fiber.join(fiber)
  return result
})
```

### forkDaemon — Outlive Parent

`Effect.forkDaemon` creates a fiber that survives the parent's scope:

```typescript
const program = Effect.gen(function* () {
  // This fiber keeps running even if the parent exits
  yield* Effect.forkDaemon(backgroundHealthCheck)
  return "started"
})
```

### forkScoped — Tied to Scope

`Effect.forkScoped` ties the fiber to the current scope:

```typescript
const program = Effect.scoped(
  Effect.gen(function* () {
    const fiber = yield* Effect.forkScoped(periodicTask)
    yield* doWork()
    // fiber is automatically interrupted when scope closes
  })
)
```

### Interrupt

```typescript
const program = Effect.gen(function* () {
  const fiber = yield* Effect.fork(longTask)
  yield* Effect.sleep("5 seconds")
  yield* Fiber.interrupt(fiber) // cancel the fiber
})
```

### Racing

```typescript
// First to succeed wins, losers are interrupted
const result = yield* Effect.race(fetchFromCache, fetchFromDb)

// Race with fallback
const result = yield* Effect.raceFirst(primaryStrategy, fallbackStrategy)

// All must succeed, but cancel all if any fails
const [a, b] = yield* Effect.all([taskA, taskB], {
  concurrency: "unbounded",
  mode: "either" // returns first success, interrupts others
})
```

### Fiber.await vs Fiber.join

- `Fiber.join` — re-raises the fiber's error in the caller. Propagates typed errors.
- `Fiber.await` — returns an `Exit` value. Caller decides how to handle success/failure.

```typescript
const exit = yield* Fiber.await(fiber)
Exit.match(exit, {
  onSuccess: (value) => Effect.log(`Got: ${value}`),
  onFailure: (cause) => Effect.log(`Failed: ${Cause.pretty(cause)}`)
})
```

---

## Ref, Queue, and Hub

### Ref — Mutable State

Thread-safe mutable reference. All updates are atomic.

```typescript
import { Ref, Effect } from "effect"

const counter = Effect.gen(function* () {
  const ref = yield* Ref.make(0)
  yield* Ref.update(ref, (n) => n + 1)
  yield* Ref.update(ref, (n) => n + 1)
  const value = yield* Ref.get(ref)
  return value // 2
})
```

`Ref.modify` — atomic read-modify-write returning a derived value:

```typescript
const [oldValue, _] = yield* Ref.modify(ref, (n) => [n, n + 1])
```

### Queue — Concurrent FIFO

```typescript
import { Queue, Effect } from "effect"

const program = Effect.gen(function* () {
  const queue = yield* Queue.bounded<string>(100)

  // Producer
  yield* Effect.fork(
    Effect.forever(
      queue.offer("message").pipe(Effect.delay("1 second"))
    )
  )

  // Consumer
  const msg = yield* Queue.take(queue) // blocks until available
  yield* Effect.log(`Received: ${msg}`)
})
```

Queue variants:
- `Queue.bounded(n)` — back-pressures when full
- `Queue.unbounded` — no limit (use cautiously)
- `Queue.dropping(n)` — drops new items when full
- `Queue.sliding(n)` — drops oldest items when full

### Hub — Pub/Sub

Every subscriber gets every message published after subscribing.

```typescript
import { Hub, Effect } from "effect"

const program = Effect.gen(function* () {
  const hub = yield* Hub.bounded<string>(100)

  // Two subscribers, each gets all messages
  const sub1 = yield* Hub.subscribe(hub)
  const sub2 = yield* Hub.subscribe(hub)

  yield* Hub.publish(hub, "event-1")

  const msg1 = yield* Queue.take(sub1)
  const msg2 = yield* Queue.take(sub2)
  // msg1 === msg2 === "event-1"
})
```

---

## Schedule and Retry Policies

### Built-in Schedules

```typescript
import { Schedule, Effect } from "effect"

// Fixed interval
Schedule.fixed("5 seconds")

// Exponential backoff
Schedule.exponential("100 millis")

// Exponential with max delay cap
Schedule.exponential("100 millis").pipe(
  Schedule.either(Schedule.spaced("30 seconds"))
)

// Limited recurrences
Schedule.recurs(5)

// Combine: exponential backoff, max 5 retries, max 30s between
const policy = Schedule.exponential("200 millis").pipe(
  Schedule.compose(Schedule.recurs(5)),
  Schedule.union(Schedule.spaced("30 seconds"))
)
```

### Retry with Schedule

```typescript
const resilientFetch = fetchData.pipe(
  Effect.retry(
    Schedule.exponential("200 millis").pipe(
      Schedule.compose(Schedule.recurs(5))
    )
  )
)
```

### Retry with Filters

```typescript
const retryPolicy = Effect.retry(fetchData, {
  times: 3,
  while: (err) => err._tag === "HttpError" && err.status >= 500,
  schedule: Schedule.exponential("500 millis")
})
```

### Repeat with Schedule

```typescript
// Repeat an effect on a schedule
const poll = fetchStatus.pipe(
  Effect.repeat(Schedule.spaced("10 seconds"))
)

// Repeat until a condition
const waitForReady = checkStatus.pipe(
  Effect.repeat({
    until: (status) => status === "ready",
    schedule: Schedule.spaced("1 second")
  })
)
```

### Schedule Combinators

```typescript
// Jitter — adds randomness to avoid thundering herd
Schedule.jittered(Schedule.exponential("200 millis"))

// Intersect — both schedules must agree to continue
Schedule.intersect(Schedule.recurs(5), Schedule.spaced("1 second"))

// Union — either schedule allows continuation
Schedule.union(Schedule.recurs(3), Schedule.spaced("10 seconds"))

// tapOutput — log/observe each schedule output
Schedule.exponential("200 millis").pipe(
  Schedule.tapOutput((duration) => Effect.log(`Next delay: ${duration}`))
)
```

---

## Cause: Defects vs Failures

### The Distinction

- **Failures** (`Cause.Fail`) — expected errors, tracked in the `E` channel. Created with `Effect.fail`.
- **Defects** (`Cause.Die`) — unexpected errors, bugs. Created by uncaught exceptions or `Effect.die`.
- **Interruptions** (`Cause.Interrupt`) — fiber was interrupted.

```typescript
import { Cause, Effect } from "effect"

// Failure — typed, expected
Effect.fail(new HttpError({ status: 404 }))

// Defect — untyped, unexpected
Effect.die(new Error("invariant violated"))

// orDie — convert failures to defects (when you've exhausted error handling)
effect.pipe(Effect.orDie)

// sandbox — expose the full Cause in the error channel
effect.pipe(
  Effect.sandbox,
  Effect.catchAll((cause) => {
    if (Cause.isFailure(cause)) { /* handle expected */ }
    if (Cause.isDie(cause)) { /* handle defect */ }
    if (Cause.isInterrupted(cause)) { /* handle interruption */ }
    return Effect.void
  })
)
```

### Inspecting Cause

```typescript
const program = effect.pipe(
  Effect.catchAllCause((cause) => {
    const prettyPrint = Cause.pretty(cause)
    const failures = Cause.failures(cause)    // Chunk of E values
    const defects = Cause.defects(cause)      // Chunk of unknown
    const isInterrupted = Cause.isInterrupted(cause)
    return Effect.log(prettyPrint)
  })
)
```

### Parallel Cause

When multiple fibers fail simultaneously, `Cause.Parallel` combines them:

```typescript
// Both tasks fail — Cause is Parallel(Fail(errA), Fail(errB))
Effect.all([failingTaskA, failingTaskB], { concurrency: "unbounded" })
```

---

## Custom Annotations and Tracing

### Span and withSpan

Effect has built-in tracing with spans:

```typescript
import { Effect } from "effect"

const fetchUser = (id: string) =>
  Effect.gen(function* () {
    const repo = yield* UserRepo
    return yield* repo.findById(id)
  }).pipe(Effect.withSpan("fetchUser", { attributes: { userId: id } }))

const program = Effect.gen(function* () {
  const user = yield* fetchUser("123")
  const posts = yield* fetchPosts(user.id)
  return { user, posts }
}).pipe(Effect.withSpan("handleRequest"))
```

### Annotations

Add metadata to effects for logging and observability:

```typescript
const program = Effect.gen(function* () {
  yield* Effect.annotateCurrentSpan("requestId", requestId)
  yield* Effect.annotateCurrentSpan("userId", userId)
  // All logs within this span carry these annotations
  yield* Effect.log("Processing request")
})
```

### Log Annotations

```typescript
const program = Effect.gen(function* () {
  yield* Effect.log("Starting").pipe(
    Effect.annotateLogs("module", "auth")
  )
}).pipe(Effect.annotateLogs("service", "api"))
```

### Custom Log Levels

```typescript
yield* Effect.logDebug("verbose info")
yield* Effect.logInfo("standard info")
yield* Effect.logWarning("something concerning")
yield* Effect.logError("something failed")
yield* Effect.logFatal("critical failure")
```

### Setting Up a Tracer

```typescript
import { NodeSdk } from "@effect/opentelemetry"
import { OTLPTraceExporter } from "@opentelemetry/exporter-trace-otlp-http"
import { BatchSpanProcessor } from "@opentelemetry/sdk-trace-base"

const TracingLayer = NodeSdk.layer(() => ({
  resource: { serviceName: "my-service" },
  spanProcessor: new BatchSpanProcessor(
    new OTLPTraceExporter({ url: "http://localhost:4318/v1/traces" })
  ),
}))

// Add to your app layer
const AppLayer = Layer.merge(AppServicesLayer, TracingLayer)
```

---

## Platform-Specific Patterns

### FileSystem (@effect/platform)

```typescript
import { FileSystem } from "@effect/platform"
import { NodeFileSystem } from "@effect/platform-node"

const readConfig = Effect.gen(function* () {
  const fs = yield* FileSystem.FileSystem
  const content = yield* fs.readFileString("/etc/app/config.json")
  return yield* Schema.decodeUnknown(ConfigSchema)(JSON.parse(content))
}).pipe(Effect.provide(NodeFileSystem.layer))
```

### HttpClient

```typescript
import { HttpClient, HttpClientRequest, HttpClientResponse } from "@effect/platform"
import { NodeHttpClient } from "@effect/platform-node"

const apiClient = Effect.gen(function* () {
  const client = (yield* HttpClient.HttpClient).pipe(
    HttpClient.filterStatusOk,
    HttpClient.mapRequest(HttpClientRequest.prependUrl("https://api.example.com")),
    HttpClient.mapRequest(HttpClientRequest.bearerToken("my-token"))
  )
  return client
})

const getUser = (id: string) =>
  Effect.gen(function* () {
    const client = yield* apiClient
    const response = yield* client.get(`/users/${id}`)
    return yield* HttpClientResponse.schemaBodyJson(UserSchema)(response)
  }).pipe(Effect.scoped)
```

### HttpServer — Middleware Pattern

```typescript
import { HttpRouter, HttpServer, HttpServerRequest, HttpServerResponse, HttpMiddleware } from "@effect/platform"

// Custom middleware
const withRequestId = HttpMiddleware.make((app) =>
  Effect.gen(function* () {
    const request = yield* HttpServerRequest.HttpServerRequest
    const requestId = request.headers["x-request-id"] ?? crypto.randomUUID()
    return yield* app.pipe(
      Effect.annotateLogs("requestId", requestId),
      Effect.withSpan("http.request", {
        attributes: {
          "http.method": request.method,
          "http.url": request.url,
        },
      })
    )
  })
)

const router = HttpRouter.empty.pipe(
  HttpRouter.get("/health", HttpServerResponse.text("ok")),
  HttpRouter.get("/users/:id", getUserHandler),
  HttpRouter.post("/users", createUserHandler),
)

const app = router.pipe(
  withRequestId,
  HttpServer.serve(HttpMiddleware.logger),
)
```

### Command — Running Subprocesses

```typescript
import { Command } from "@effect/platform"
import { NodeCommandExecutor } from "@effect/platform-node"

const runGitStatus = Effect.gen(function* () {
  const command = Command.make("git", "status", "--porcelain")
  const result = yield* Command.string(command)
  return result.trim().split("\n")
}).pipe(Effect.provide(NodeCommandExecutor.layer))
```

### KeyValueStore

```typescript
import { KeyValueStore } from "@effect/platform"
import { NodeKeyValueStore } from "@effect/platform-node"

const cacheLayer = NodeKeyValueStore.layerFileSystem("/tmp/app-cache")

const program = Effect.gen(function* () {
  const store = yield* KeyValueStore.KeyValueStore
  yield* store.set("key", "value")
  const value = yield* store.get("key")
  return value
}).pipe(Effect.provide(cacheLayer))
```
