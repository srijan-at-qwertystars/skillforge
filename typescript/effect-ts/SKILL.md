---
name: effect-ts
description: >
  Use when writing TypeScript with the `effect` library (Effect-TS). TRIGGER on: imports from "effect", "effect/*", "@effect/platform", "@effect/platform-node", "@effect/cli", "@effect/sql"; usage of Effect.gen, Effect.pipe, Layer, Schema.Struct, Data.TaggedError, Context.GenericTag, Effect.succeed/fail/tryPromise, Stream, Fiber, Scope; any mention of Effect-TS, effect-ts, or "the Effect library". DO NOT trigger on: plain async/await Promise code without Effect imports, Zod-only schemas, fp-ts code, RxJS observables, general TypeScript without Effect dependency, NestJS/Express middleware patterns not using Effect.
---

# Effect-TS (Effect 3.x)

Effect is a TypeScript library for building type-safe, composable, production-grade applications. It provides structured concurrency, typed errors, dependency injection, and a "missing standard library" for TypeScript.

## Core Type: `Effect<A, E, R>`

```
Effect<Success, Error, Requirements>
```

- `A` — success value type
- `E` — expected error type (typed, tracked in the channel)
- `R` — required services/dependencies (provided via Layer)

When `E` is `never`, the effect cannot fail. When `R` is `never`, no dependencies are needed.

## Creating Effects

```typescript
import { Effect } from "effect"

// Pure values
Effect.succeed(42)                        // Effect<number, never, never>
Effect.fail(new Error("boom"))            // Effect<never, Error, never>

// Lazy sync computation
Effect.sync(() => Date.now())             // Effect<number, never, never>

// Sync that may throw
Effect.try(() => JSON.parse(input))       // Effect<unknown, UnknownException, never>

// From Promise (CANNOT reject)
Effect.promise(() => fetch("/healthy"))   // Effect<Response, never, never>

// From Promise (CAN reject) — prefer this for real APIs
Effect.tryPromise({
  try: () => fetch("/api/data"),
  catch: (err) => new HttpError({ message: String(err) })
})                                        // Effect<Response, HttpError, never>
```

**Rule:** Use `Effect.tryPromise` over `Effect.promise` unless rejection is truly impossible. Always supply a `catch` mapper for typed errors.

## Composing Effects

### pipe (data-last)

```typescript
import { Effect, pipe } from "effect"

const program = pipe(
  Effect.succeed(5),
  Effect.map((n) => n * 2),
  Effect.flatMap((n) => n > 0 ? Effect.succeed(n) : Effect.fail("negative"))
)
```

### Pipeable method style (preferred in 3.x)

```typescript
const program = Effect.succeed(5).pipe(
  Effect.map((n) => n * 2),
  Effect.flatMap((n) => Effect.succeed(n + 1)),
  Effect.tap((n) => Effect.log(`Result: ${n}`))
)
```

### Effect.gen (generator style — recommended for sequential logic)

```typescript
const program = Effect.gen(function* () {
  const user = yield* fetchUser(id)
  const posts = yield* fetchPosts(user.id)
  return { user, posts }
})
```

**Rule:** Prefer `Effect.gen` for multi-step sequential logic. Use `pipe` for simple 1-2 step transformations.

## Error Handling

### Tagged Errors (always prefer these)

```typescript
import { Data } from "effect"

class HttpError extends Data.TaggedError("HttpError")<{
  status: number
  message: string
}> {}

class ValidationError extends Data.TaggedError("ValidationError")<{
  field: string
  reason: string
}> {}
```

### Catching specific errors by tag

```typescript
const handled = program.pipe(
  Effect.catchTag("HttpError", (err) =>
    Effect.succeed(`Fallback for HTTP ${err.status}`)
  )
)
// Error channel: ValidationError (HttpError removed)

// Catch multiple tags exhaustively
const fullyHandled = program.pipe(
  Effect.catchTags({
    HttpError: (err) => Effect.succeed("http fallback"),
    ValidationError: (err) => Effect.succeed("validation fallback"),
  })
)
// Error channel: never
```

### Other error combinators

```typescript
// Catch all errors
Effect.catchAll(program, (err) => Effect.succeed("default"))

// Transform error type
Effect.mapError(program, (err) => new AppError({ cause: err }))

// Provide fallback value
Effect.orElseSucceed(program, () => "default")

// Retry on failure
Effect.retry(program, { times: 3 })
```

## Services and Dependency Injection

### Define a service

```typescript
import { Context, Effect, Layer } from "effect"

class UserRepo extends Context.Tag("UserRepo")<
  UserRepo,
  {
    readonly findById: (id: string) => Effect.Effect<User, NotFoundError>
    readonly save: (user: User) => Effect.Effect<void>
  }
>() {}
```

### Use a service in an effect

```typescript
const program = Effect.gen(function* () {
  const repo = yield* UserRepo
  const user = yield* repo.findById("123")
  return user
})
// Type: Effect<User, NotFoundError, UserRepo>
```

### Create a Layer (implementation)

```typescript
const UserRepoLive = Layer.succeed(UserRepo, {
  findById: (id) => Effect.tryPromise(() => db.query(`SELECT * FROM users WHERE id = $1`, [id])),
  save: (user) => Effect.tryPromise(() => db.query(`INSERT INTO users ...`, [user])),
})
```

### Layer with dependencies

```typescript
const UserRepoLive = Layer.effect(
  UserRepo,
  Effect.gen(function* () {
    const db = yield* Database
    return {
      findById: (id) => db.query(id),
      save: (user) => db.insert(user),
    }
  })
)
```

### Provide layers and run

```typescript
const appLayer = UserRepoLive.pipe(Layer.provide(DatabaseLive))

Effect.runPromise(
  program.pipe(Effect.provide(appLayer))
)
```

**Rule:** Build layers bottom-up. Compose with `Layer.provide`. Never call `Effect.runPromise` except at the application entry point.

## Concurrency

```typescript
// Run effects in parallel
const results = yield* Effect.all([fetchA, fetchB, fetchC], { concurrency: "unbounded" })

// Bounded concurrency (prefer for large collections)
yield* Effect.all(tasks, { concurrency: 10 })

// Race — first to succeed wins
yield* Effect.race(fetchFromCacheEffect, fetchFromDbEffect)

// Fork a fiber for background work
const fiber = yield* Effect.fork(longRunningTask)
// ... do other work ...
const result = yield* Fiber.join(fiber)

// Interrupt a fiber
yield* Fiber.interrupt(fiber)
```

**Rule:** Always set `concurrency` when processing collections. Unbounded parallelism on large arrays will exhaust resources.

## Resource Management (Scope)

```typescript
import { Effect, Scope } from "effect"

const acquireDbConnection = Effect.acquireRelease(
  Effect.tryPromise(() => pool.connect()),   // acquire
  (conn) => Effect.sync(() => conn.release()) // release (guaranteed)
)

const program = Effect.gen(function* () {
  const conn = yield* acquireDbConnection
  return yield* conn.query("SELECT 1")
})

// Scope ensures release even on error/interruption
Effect.runPromise(Effect.scoped(program))
```

## Schema (Validation, Encoding, Decoding)

```typescript
import { Schema } from "effect"

const User = Schema.Struct({
  id: Schema.Number,
  name: Schema.String,
  email: Schema.String,
  createdAt: Schema.DateFromString,
})

// Extract types
type UserDecoded = typeof User.Type      // { id: number; name: string; email: string; createdAt: Date }
type UserEncoded = typeof User.Encoded   // { id: number; name: string; email: string; createdAt: string }

// Decode (parse + validate + transform)
const user = Schema.decodeUnknownSync(User)({
  id: 1, name: "Alice", email: "a@b.com", createdAt: "2024-01-01"
})

// Decode as Effect (for composition)
const decodeUser = Schema.decodeUnknown(User)
const program = decodeUser(rawData) // Effect<User, ParseError, never>

// Encode (reverse transform)
Schema.encodeSync(User)(user) // back to encoded form

// Schema for tagged errors
class ApiError extends Schema.TaggedError<ApiError>()("ApiError", {
  status: Schema.Number,
  message: Schema.String,
}) {}
```

### Custom transformations

```typescript
const Trimmed = Schema.String.pipe(
  Schema.transform(Schema.String, {
    decode: (s) => s.trim(),
    encode: (s) => s,
  })
)
```

**Rule:** Use `Schema.decodeUnknown` (not `Schema.decode`) for external/untrusted data. Use `Schema.decode` only when the input type is already known.

## Streaming (Stream, Sink)

```typescript
import { Stream, Sink, Effect } from "effect"

// Create streams
const numbers = Stream.fromIterable([1, 2, 3, 4, 5])
const fromEffect = Stream.fromEffect(fetchUser("1"))

// Transform
const doubled = numbers.pipe(Stream.map((n) => n * 2))

// Filter
const evens = numbers.pipe(Stream.filter((n) => n % 2 === 0))

// Consume with Sink
const sum = yield* numbers.pipe(Stream.run(Sink.sum))

// Chunked processing with concurrency
const processed = stream.pipe(
  Stream.mapEffect((item) => processItem(item), { concurrency: 5 })
)
```

## Config

```typescript
import { Config, Effect } from "effect"

const program = Effect.gen(function* () {
  const port = yield* Config.number("PORT")
  const host = yield* Config.string("HOST")
  const dbUrl = yield* Config.string("DATABASE_URL").pipe(Config.withDefault("localhost"))
  return { port, host, dbUrl }
})

// Config reads from environment variables by default.
// Override with ConfigProvider for testing:
import { ConfigProvider, Layer } from "effect"

const testConfig = ConfigProvider.fromMap(new Map([
  ["PORT", "3000"],
  ["HOST", "localhost"],
]))
const testLayer = Layer.setConfigProvider(testConfig)
```

## Testing

```typescript
import { Effect, Layer } from "effect"
import { it, expect } from "vitest"

// Mock a service with Layer.succeed
const MockUserRepo = Layer.succeed(UserRepo, {
  findById: (id) => Effect.succeed({ id, name: "Test User" }),
  save: () => Effect.void,
})

it("finds user", async () => {
  const result = await Effect.runPromise(
    program.pipe(Effect.provide(MockUserRepo))
  )
  expect(result.name).toBe("Test User")
})

// Use TestContext for deterministic clock/random
import { TestContext, TestClock } from "effect"

const testProgram = Effect.gen(function* () {
  yield* TestClock.adjust("1 hour")
  // time-dependent logic now uses test clock
})

await Effect.runPromise(testProgram.pipe(Effect.provide(TestContext.TestContext)))
```

## HTTP Client (@effect/platform)

```typescript
import { HttpClient, HttpClientRequest, HttpClientResponse } from "@effect/platform"
import { NodeHttpClient } from "@effect/platform-node"

const fetchTodo = Effect.gen(function* () {
  const client = yield* HttpClient.HttpClient
  const response = yield* client.get("https://jsonplaceholder.typicode.com/todos/1")
  const todo = yield* HttpClientResponse.schemaBodyJson(TodoSchema)(response)
  return todo
}).pipe(Effect.scoped)

// Provide the platform layer
Effect.runPromise(fetchTodo.pipe(Effect.provide(NodeHttpClient.layer)))
```

## HTTP Server (@effect/platform)

```typescript
import { HttpRouter, HttpServer, HttpServerResponse } from "@effect/platform"
import { NodeHttpServer } from "@effect/platform-node"
import { createServer } from "node:http"

const router = HttpRouter.empty.pipe(
  HttpRouter.get("/health", HttpServerResponse.text("ok")),
  HttpRouter.get("/users/:id", Effect.gen(function* () {
    const repo = yield* UserRepo
    const user = yield* repo.findById("1")
    return HttpServerResponse.json(user)
  }))
)

const server = router.pipe(
  HttpServer.serve(),
  Layer.provide(NodeHttpServer.layer(createServer, { port: 3000 }))
)

Layer.launch(server).pipe(Effect.runFork)
```

## Running Effects

```typescript
// At application boundary only:
Effect.runSync(effect)          // Synchronous — throws on async or failure
Effect.runPromise(effect)       // Returns Promise<A> — rejects on failure
Effect.runFork(effect)          // Returns Fiber — non-blocking

// In libraries/modules: NEVER call run*. Return Effect values instead.
```

## Pattern: Migrating from Promise-based code

```typescript
// BEFORE (Promise)
async function getUser(id: string): Promise<User> {
  const res = await fetch(`/api/users/${id}`)
  if (!res.ok) throw new Error(`HTTP ${res.status}`)
  return res.json()
}

// AFTER (Effect)
const getUser = (id: string) =>
  Effect.gen(function* () {
    const client = yield* HttpClient.HttpClient
    const response = yield* client.get(`/api/users/${id}`).pipe(
      Effect.catchTag("ResponseError", (err) =>
        Effect.fail(new HttpError({ status: err.response.status, message: "Request failed" }))
      )
    )
    return yield* HttpClientResponse.schemaBodyJson(UserSchema)(response)
  }).pipe(Effect.scoped)
```

## Common Pitfalls

1. **Calling `Effect.runPromise` inside effects** — never nest runtime calls. Compose with `flatMap`/`gen` instead.
2. **Using `Effect.promise` for fallible promises** — use `Effect.tryPromise` with explicit `catch` mapper.
3. **Forgetting `Effect.scoped`** — HTTP responses, file handles, and DB connections acquired via `acquireRelease` need a scope.
4. **Unbounded `Effect.all`** — always set `{ concurrency: N }` for collections of unknown size.
5. **Returning `Promise` from service methods** — service methods should return `Effect`, not `Promise`.
6. **Ignoring the error channel** — don't use `as any` or `catchAll(() => Effect.void)` to silence errors. Handle them explicitly.
7. **Constructing layers at call sites** — build layers once, provide at composition root.
8. **Using `Schema.decode` for untrusted input** — use `Schema.decodeUnknown` which accepts `unknown`.

## Performance Notes

- Effects are lazy descriptions — no work happens until `run*` is called.
- `Effect.gen` has minimal overhead; use it freely.
- `Stream` is chunked internally for throughput — prefer `Stream` over manual batching.
- Fibers are lightweight (not OS threads) — thousands are fine.
- `Layer.merge` shares resources across consumers; use it to avoid duplicate initialization.
- Use `Effect.cached` or `Effect.cachedWithTTL` for expensive computations that should be memoized.

## Key Imports

```typescript
// Core
import { Effect, pipe, Layer, Context, Schema, Data, Config, Stream, Sink, Fiber, Scope, Match, Schedule } from "effect"

// Platform (HTTP, filesystem, etc.)
import { HttpClient, HttpClientRequest, HttpClientResponse, HttpRouter, HttpServer, HttpServerResponse } from "@effect/platform"
import { NodeHttpClient, NodeHttpServer } from "@effect/platform-node"
import { BunHttpServer } from "@effect/platform-bun"

// SQL
import { SqlClient } from "@effect/sql"
import { PgClient } from "@effect/sql-pg"
```
