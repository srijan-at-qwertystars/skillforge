# Effect-TS Migration Guide

## Table of Contents

- [Promise Chains to Effect](#promise-chains-to-effect)
- [fp-ts to Effect](#fp-ts-to-effect)
- [Zod to Effect Schema](#zod-to-effect-schema)
- [Express/Fastify to @effect/platform HttpServer](#expressfastify-to-effectplatform-httpserver)
- [Incremental Adoption Strategies](#incremental-adoption-strategies)

---

## Promise Chains to Effect

### Basic async/await → Effect.gen

```typescript
// ❌ BEFORE: Promise
async function getUser(id: string): Promise<User> {
  const res = await fetch(`/api/users/${id}`)
  if (!res.ok) throw new Error(`HTTP ${res.status}`)
  return res.json()
}

// ✅ AFTER: Effect
import { Effect } from "effect"

const getUser = (id: string) =>
  Effect.gen(function* () {
    const res = yield* Effect.tryPromise({
      try: () => fetch(`/api/users/${id}`),
      catch: (err) => new HttpError({ message: String(err) }),
    })
    if (!res.ok) {
      return yield* Effect.fail(new HttpError({ status: res.status, message: "Not OK" }))
    }
    return yield* Effect.tryPromise({
      try: () => res.json() as Promise<User>,
      catch: () => new ParseError({ message: "Invalid JSON" }),
    })
  })
// Type: Effect<User, HttpError | ParseError, never>
```

### try/catch → Effect.catchTag

```typescript
// ❌ BEFORE
async function processOrder(id: string) {
  try {
    const order = await fetchOrder(id)
    const receipt = await chargePayment(order)
    await sendConfirmation(receipt)
  } catch (err) {
    if (err instanceof PaymentError) {
      await refund(id)
    }
    throw err
  }
}

// ✅ AFTER
const processOrder = (id: string) =>
  Effect.gen(function* () {
    const order = yield* fetchOrder(id)
    const receipt = yield* chargePayment(order)
    yield* sendConfirmation(receipt)
  }).pipe(
    Effect.catchTag("PaymentError", (err) =>
      refund(id).pipe(Effect.flatMap(() => Effect.fail(err)))
    )
  )
```

### Promise.all → Effect.all

```typescript
// ❌ BEFORE
const [users, posts, comments] = await Promise.all([
  fetchUsers(),
  fetchPosts(),
  fetchComments(),
])

// ✅ AFTER
const [users, posts, comments] = yield* Effect.all(
  [fetchUsers(), fetchPosts(), fetchComments()],
  { concurrency: "unbounded" }
)
```

### Promise.race → Effect.race

```typescript
// ❌ BEFORE
const result = await Promise.race([fetchFromCache(key), fetchFromDb(key)])

// ✅ AFTER
const result = yield* Effect.race(fetchFromCache(key), fetchFromDb(key))
// Loser is automatically interrupted
```

### setTimeout → Effect.sleep

```typescript
// ❌ BEFORE
await new Promise((resolve) => setTimeout(resolve, 1000))

// ✅ AFTER
yield* Effect.sleep("1 second")
```

### Retry Logic

```typescript
// ❌ BEFORE
async function fetchWithRetry(url: string, retries = 3): Promise<Response> {
  for (let i = 0; i < retries; i++) {
    try {
      return await fetch(url)
    } catch (err) {
      if (i === retries - 1) throw err
      await new Promise((r) => setTimeout(r, 1000 * Math.pow(2, i)))
    }
  }
  throw new Error("unreachable")
}

// ✅ AFTER
import { Schedule } from "effect"

const fetchWithRetry = (url: string) =>
  Effect.tryPromise(() => fetch(url)).pipe(
    Effect.retry(
      Schedule.exponential("1 second").pipe(
        Schedule.compose(Schedule.recurs(3))
      )
    )
  )
```

### Resource Cleanup

```typescript
// ❌ BEFORE
let conn: Connection | null = null
try {
  conn = await pool.connect()
  const result = await conn.query("SELECT 1")
  return result
} finally {
  conn?.release()
}

// ✅ AFTER
const program = Effect.gen(function* () {
  const conn = yield* Effect.acquireRelease(
    Effect.tryPromise(() => pool.connect()),
    (conn) => Effect.promise(() => conn.release())
  )
  return yield* Effect.tryPromise(() => conn.query("SELECT 1"))
})
Effect.runPromise(Effect.scoped(program))
```

---

## fp-ts to Effect

### Core Type Mapping

| fp-ts | Effect |
|-------|--------|
| `Either<E, A>` | `Either<A, E>` (note: swapped) or `Effect<A, E>` |
| `Option<A>` | `Option<A>` (same concept) |
| `TaskEither<E, A>` | `Effect<A, E>` |
| `Task<A>` | `Effect<A>` |
| `IO<A>` | `Effect<A>` |
| `Reader<R, A>` | `Effect<A, never, R>` |
| `ReaderTaskEither<R, E, A>` | `Effect<A, E, R>` |

### pipe and flow

```typescript
// fp-ts
import { pipe, flow } from "fp-ts/function"
import * as TE from "fp-ts/TaskEither"

const program = pipe(
  TE.right(42),
  TE.map((n) => n * 2),
  TE.chain((n) => TE.right(n + 1))
)

// Effect — pipe is the same concept
import { Effect, pipe } from "effect"

const program = pipe(
  Effect.succeed(42),
  Effect.map((n) => n * 2),
  Effect.flatMap((n) => Effect.succeed(n + 1))
)

// Or use pipeable method style (idiomatic Effect 3.x)
const program = Effect.succeed(42).pipe(
  Effect.map((n) => n * 2),
  Effect.flatMap((n) => Effect.succeed(n + 1))
)
```

### Either

```typescript
// fp-ts
import * as E from "fp-ts/Either"
const result: E.Either<Error, number> = E.right(42)
pipe(result, E.map((n) => n * 2), E.getOrElse(() => 0))

// Effect
import { Either } from "effect"
const result: Either.Either<number, Error> = Either.right(42)
// Note: Either<A, E> — success first in Effect
Either.match(result, {
  onLeft: () => 0,
  onRight: (n) => n * 2,
})
```

### Option

```typescript
// fp-ts
import * as O from "fp-ts/Option"
const value = pipe(O.some(42), O.map((n) => n * 2), O.getOrElse(() => 0))

// Effect
import { Option } from "effect"
const value = Option.some(42).pipe(
  Option.map((n) => n * 2),
  Option.getOrElse(() => 0)
)
```

### TaskEither → Effect

```typescript
// fp-ts
import * as TE from "fp-ts/TaskEither"

const fetchUser = (id: string): TE.TaskEither<Error, User> =>
  TE.tryCatch(
    () => fetch(`/users/${id}`).then((r) => r.json()),
    (err) => new Error(String(err))
  )

const program = pipe(
  fetchUser("1"),
  TE.chain((user) => fetchPosts(user.id)),
  TE.map((posts) => posts.length)
)

await pipe(program, TE.getOrElse((err) => T.of(0)))()

// Effect
const fetchUser = (id: string) =>
  Effect.tryPromise({
    try: () => fetch(`/users/${id}`).then((r) => r.json()),
    catch: (err) => new Error(String(err)),
  })

const program = Effect.gen(function* () {
  const user = yield* fetchUser("1")
  const posts = yield* fetchPosts(user.id)
  return posts.length
})

await Effect.runPromise(program.pipe(Effect.orElseSucceed(() => 0)))
```

### Reader → Context.Tag + Layer

```typescript
// fp-ts
import * as R from "fp-ts/Reader"
import * as RTE from "fp-ts/ReaderTaskEither"

interface Deps { db: Database; logger: Logger }

const getUser = (id: string): RTE.ReaderTaskEither<Deps, Error, User> =>
  (deps) => deps.db.query(id)

// Effect — explicit service tags
class Database extends Context.Tag("Database")<Database, { query: (id: string) => Effect.Effect<User> }>() {}
class Logger extends Context.Tag("Logger")<Logger, { log: (msg: string) => Effect.Effect<void> }>() {}

const getUser = (id: string) =>
  Effect.gen(function* () {
    const db = yield* Database
    return yield* db.query(id)
  })
// Type: Effect<User, never, Database>
```

### Validation → Schema

```typescript
// fp-ts — io-ts
import * as t from "io-ts"
const UserCodec = t.type({
  id: t.number,
  name: t.string,
})

// Effect — Schema
const UserSchema = Schema.Struct({
  id: Schema.Number,
  name: Schema.String,
})
```

---

## Zod to Effect Schema

### Basic Type Mapping

| Zod | Effect Schema |
|-----|---------------|
| `z.string()` | `Schema.String` |
| `z.number()` | `Schema.Number` |
| `z.boolean()` | `Schema.Boolean` |
| `z.date()` | `Schema.DateFromSelf` |
| `z.literal("x")` | `Schema.Literal("x")` |
| `z.enum(["a","b"])` | `Schema.Literal("a","b")` |
| `z.null()` | `Schema.Null` |
| `z.undefined()` | `Schema.Undefined` |
| `z.any()` | `Schema.Any` |
| `z.unknown()` | `Schema.Unknown` |

### Object Schemas

```typescript
// Zod
const User = z.object({
  id: z.number(),
  name: z.string(),
  email: z.string().email(),
})
type User = z.infer<typeof User>

// Effect Schema
const User = Schema.Struct({
  id: Schema.Number,
  name: Schema.String,
  email: Schema.String.pipe(Schema.pattern(/^[^@]+@[^@]+\.[^@]+$/)),
})
type User = typeof User.Type
```

### Optional and Default

```typescript
// Zod
z.object({
  name: z.string(),
  bio: z.string().optional(),
  role: z.string().default("user"),
})

// Effect Schema
Schema.Struct({
  name: Schema.String,
  bio: Schema.optional(Schema.String),
  role: Schema.optional(Schema.String, { default: () => "user" }),
})
```

### Arrays

```typescript
// Zod
z.array(z.string())
z.array(z.string()).nonempty()
z.array(z.string()).min(1).max(10)

// Effect Schema
Schema.Array(Schema.String)
Schema.NonEmptyArray(Schema.String)
Schema.Array(Schema.String).pipe(Schema.minItems(1), Schema.maxItems(10))
```

### Union and Discriminated Union

```typescript
// Zod
z.union([z.string(), z.number()])
z.discriminatedUnion("type", [
  z.object({ type: z.literal("a"), value: z.string() }),
  z.object({ type: z.literal("b"), count: z.number() }),
])

// Effect Schema
Schema.Union(Schema.String, Schema.Number)
Schema.Union(
  Schema.Struct({ type: Schema.Literal("a"), value: Schema.String }),
  Schema.Struct({ type: Schema.Literal("b"), count: Schema.Number }),
)
```

### Refinements

```typescript
// Zod
z.string().min(1).max(100).regex(/^[a-z]+$/)
z.number().int().positive().lte(1000)

// Effect Schema
Schema.String.pipe(Schema.minLength(1), Schema.maxLength(100), Schema.pattern(/^[a-z]+$/))
Schema.Number.pipe(Schema.int(), Schema.positive(), Schema.lessThanOrEqualTo(1000))
```

### Transforms

```typescript
// Zod
z.string().transform((s) => s.trim().toLowerCase())
z.string().transform((s) => parseInt(s, 10))

// Effect Schema
Schema.transform(Schema.String, Schema.String, {
  strict: true,
  decode: (s) => s.trim().toLowerCase(),
  encode: (s) => s,
})
Schema.NumberFromString // built-in for string → number
```

### parse / safeParse

```typescript
// Zod
const result = User.safeParse(data)
if (result.success) { result.data }
else { result.error }

User.parse(data) // throws on failure

// Effect Schema — sync
const decoded = Schema.decodeUnknownSync(User)(data) // throws ParseError on failure

// Effect Schema — Effect (preferred)
const decoded = yield* Schema.decodeUnknown(User)(data)
// Effect<User, ParseError, never>

// Effect Schema — either
const result = Schema.decodeUnknownEither(User)(data)
Either.match(result, {
  onLeft: (error) => { /* ParseError */ },
  onRight: (user) => { /* User */ },
})
```

### Key Differences

1. **Bidirectional**: Effect Schema supports encode+decode; Zod is decode-only (parse).
2. **Effect integration**: Schema errors compose naturally in Effect pipelines.
3. **Performance**: Effect Schema uses dual (encode/decode) optimization.
4. **Class support**: `Schema.Class` provides structural equality and toString.
5. **No `.extend()`**: Use `Schema.extend` or spread `.fields` instead of method chaining.

---

## Express/Fastify to @effect/platform HttpServer

### Basic Server

```typescript
// ❌ BEFORE: Express
import express from "express"
const app = express()
app.use(express.json())

app.get("/health", (req, res) => {
  res.send("ok")
})

app.get("/users/:id", async (req, res) => {
  try {
    const user = await db.findUser(req.params.id)
    res.json(user)
  } catch (err) {
    res.status(500).json({ error: "Internal error" })
  }
})

app.listen(3000)

// ✅ AFTER: @effect/platform
import { HttpRouter, HttpServer, HttpServerResponse, HttpMiddleware } from "@effect/platform"
import { NodeHttpServer } from "@effect/platform-node"
import { createServer } from "node:http"

const router = HttpRouter.empty.pipe(
  HttpRouter.get("/health", HttpServerResponse.text("ok")),
  HttpRouter.get("/users/:id",
    Effect.gen(function* () {
      const repo = yield* UserRepo
      const params = yield* HttpRouter.params
      const user = yield* repo.findById(params.id)
      return HttpServerResponse.json(user)
    })
  ),
)

const server = router.pipe(
  HttpServer.serve(HttpMiddleware.logger),
  Layer.provide(NodeHttpServer.layer(createServer, { port: 3000 })),
)

Layer.launch(server).pipe(Effect.provide(UserRepoLive), Effect.runFork)
```

### Middleware

```typescript
// ❌ BEFORE: Express middleware
app.use((req, res, next) => {
  const start = Date.now()
  res.on("finish", () => {
    console.log(`${req.method} ${req.url} - ${Date.now() - start}ms`)
  })
  next()
})

// ✅ AFTER: Effect middleware
const withTiming = HttpMiddleware.make((app) =>
  Effect.gen(function* () {
    const request = yield* HttpServerRequest.HttpServerRequest
    return yield* app.pipe(
      Effect.withSpan(`${request.method} ${request.url}`),
      Effect.tap(() => Effect.log("Request completed"))
    )
  })
)

const app = router.pipe(withTiming, HttpServer.serve())
```

### Request Body Parsing

```typescript
// ❌ BEFORE: Express
app.post("/users", (req, res) => {
  const { name, email } = req.body // untyped, needs manual validation
})

// ✅ AFTER: Effect — schema-validated
const CreateUser = Schema.Struct({
  name: Schema.String.pipe(Schema.nonEmptyString()),
  email: Schema.String.pipe(Schema.pattern(/^[^@]+@[^@]+\.[^@]+$/)),
})

HttpRouter.post("/users",
  Effect.gen(function* () {
    const body = yield* HttpServerRequest.schemaBodyJson(CreateUser)
    // body is fully typed and validated
    const user = yield* userService.create(body)
    return HttpServerResponse.json(user, { status: 201 })
  })
)
```

### Error Handling

```typescript
// ❌ BEFORE: Express error handler
app.use((err, req, res, next) => {
  if (err instanceof NotFoundError) return res.status(404).json({ error: err.message })
  if (err instanceof ValidationError) return res.status(400).json({ error: err.message })
  res.status(500).json({ error: "Internal server error" })
})

// ✅ AFTER: Effect — typed error handling per route or globally
const withErrorHandler = <E>(
  effect: Effect.Effect<HttpServerResponse.HttpServerResponse, E>
) =>
  effect.pipe(
    Effect.catchTags({
      NotFoundError: (err) =>
        HttpServerResponse.json({ error: err.message }, { status: 404 }),
      ValidationError: (err) =>
        HttpServerResponse.json({ error: err.message }, { status: 400 }),
    }),
    Effect.catchAll((err) =>
      HttpServerResponse.json({ error: "Internal server error" }, { status: 500 })
    )
  )
```

### Dependency Injection

```typescript
// ❌ BEFORE: Express — manual wiring
const db = new Database(process.env.DATABASE_URL)
const userRepo = new UserRepository(db)
const userService = new UserService(userRepo)

app.get("/users/:id", async (req, res) => {
  const user = await userService.getUser(req.params.id)
  res.json(user)
})

// ✅ AFTER: Effect — Layer-based DI
const AppLayer = Layer.mergeAll(
  UserServiceLive,
  UserRepoLive,
  DatabaseLive,
).pipe(Layer.provide(ConfigLive))

const server = router.pipe(
  HttpServer.serve(),
  Layer.provide(AppLayer),
  Layer.provide(NodeHttpServer.layer(createServer, { port: 3000 })),
)
```

---

## Incremental Adoption Strategies

### Strategy 1: Effect at the Boundary

Start by wrapping existing Promise-based code with Effect at API boundaries:

```typescript
// Existing code (unchanged)
class UserService {
  async getUser(id: string): Promise<User> { /* ... */ }
}

// New Effect wrapper
const getUserEffect = (id: string) =>
  Effect.tryPromise({
    try: () => existingUserService.getUser(id),
    catch: (err) => new ServiceError({ cause: err }),
  })
```

### Strategy 2: ManagedRuntime Bridge

Use `ManagedRuntime` to integrate Effect into existing Express/Fastify apps:

```typescript
import { ManagedRuntime } from "effect"

// Build your Effect layers
const runtime = ManagedRuntime.make(
  Layer.mergeAll(UserRepoLive, DatabaseLive, CacheLive)
)

// Use in existing Express routes
app.get("/users/:id", async (req, res, next) => {
  try {
    const user = await runtime.runPromise(
      Effect.gen(function* () {
        const repo = yield* UserRepo
        return yield* repo.findById(req.params.id)
      })
    )
    res.json(user)
  } catch (err) {
    next(err)
  }
})

// Clean shutdown
process.on("SIGTERM", () => runtime.dispose())
```

### Strategy 3: Bottom-Up Service Migration

1. Start with leaf services (database, cache, external APIs)
2. Create Effect service interfaces with Context.Tag
3. Implement as Layers
4. Gradually move business logic into Effect.gen
5. Eventually replace Express with @effect/platform

```
Phase 1: Database → Effect Layer (keep Express)
Phase 2: Business logic → Effect.gen (keep Express, use ManagedRuntime)
Phase 3: API routes → @effect/platform HttpRouter
Phase 4: Remove Express
```

### Strategy 4: Schema First

Replace Zod/Joi/Yup with Effect Schema without changing anything else:

```typescript
// Replace Zod schemas with Effect Schema
// Before: import { z } from "zod"
// After:
import { Schema } from "effect"

const UserSchema = Schema.Struct({
  id: Schema.Number,
  name: Schema.String.pipe(Schema.nonEmptyString()),
})

// Use sync parsing in existing code
const user = Schema.decodeUnknownSync(UserSchema)(req.body)
```

### Migration Checklist

- [ ] Install `effect` and `@effect/platform` packages
- [ ] Set up `tsconfig.json` with `strict: true` and `exactOptionalPropertyTypes: true`
- [ ] Replace validation library with `Schema`
- [ ] Create `Context.Tag` interfaces for core services
- [ ] Implement `Layer` for each service
- [ ] Wrap Promise-based functions with `Effect.tryPromise`
- [ ] Convert error handling to tagged errors (`Data.TaggedError`)
- [ ] Move sequential logic to `Effect.gen`
- [ ] Add concurrency controls (`Effect.all` with `concurrency`)
- [ ] Replace manual retry loops with `Schedule`
- [ ] Add resource management (`acquireRelease`)
- [ ] Set up tracing with `withSpan`
- [ ] Migrate HTTP server to `@effect/platform` (optional, can keep Express)
- [ ] Remove `run*` calls from non-entry-point code
