/**
 * repository-pattern.ts — Repository pattern template with Effect services.
 *
 * Demonstrates:
 * - Context.Tag for service interfaces
 * - Layer.effect for implementations with dependencies
 * - Tagged errors for domain failures
 * - Schema for data validation
 * - Composable layers with dependency injection
 *
 * Copy and adapt for your domain entities.
 */

import { Context, Data, Effect, Layer, Option, Schema } from "effect"

// ---------------------------------------------------------------------------
// Domain Models (Schema)
// ---------------------------------------------------------------------------

const EntityId = Schema.String.pipe(Schema.brand("EntityId"))
type EntityId = typeof EntityId.Type

const UserSchema = Schema.Struct({
  id: EntityId,
  name: Schema.String.pipe(Schema.nonEmptyString()),
  email: Schema.String.pipe(Schema.nonEmptyString()),
  role: Schema.Literal("admin", "user", "guest"),
  createdAt: Schema.DateFromString,
  updatedAt: Schema.DateFromString,
})
type User = typeof UserSchema.Type

const CreateUserInput = UserSchema.pipe(Schema.omit("id", "createdAt", "updatedAt"))
type CreateUserInput = typeof CreateUserInput.Type

const UpdateUserInput = Schema.partial(CreateUserInput)
type UpdateUserInput = typeof UpdateUserInput.Type

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

class NotFoundError extends Data.TaggedError("NotFoundError")<{
  entity: string
  id: string
}> {}

class DuplicateError extends Data.TaggedError("DuplicateError")<{
  entity: string
  field: string
  value: string
}> {}

class DatabaseError extends Data.TaggedError("DatabaseError")<{
  operation: string
  cause: unknown
}> {}

// ---------------------------------------------------------------------------
// Database Service (low-level)
// ---------------------------------------------------------------------------

class DatabaseClient extends Context.Tag("DatabaseClient")<
  DatabaseClient,
  {
    readonly query: <T>(sql: string, params?: unknown[]) => Effect.Effect<T[], DatabaseError>
    readonly queryOne: <T>(sql: string, params?: unknown[]) => Effect.Effect<Option.Option<T>, DatabaseError>
    readonly execute: (sql: string, params?: unknown[]) => Effect.Effect<void, DatabaseError>
  }
>() {}

// ---------------------------------------------------------------------------
// Repository Interface
// ---------------------------------------------------------------------------

class UserRepository extends Context.Tag("UserRepository")<
  UserRepository,
  {
    readonly findById: (id: EntityId) => Effect.Effect<User, NotFoundError | DatabaseError>
    readonly findByEmail: (email: string) => Effect.Effect<Option.Option<User>, DatabaseError>
    readonly findAll: (options?: { limit?: number; offset?: number }) => Effect.Effect<User[], DatabaseError>
    readonly create: (input: CreateUserInput) => Effect.Effect<User, DuplicateError | DatabaseError>
    readonly update: (id: EntityId, input: UpdateUserInput) => Effect.Effect<User, NotFoundError | DatabaseError>
    readonly delete: (id: EntityId) => Effect.Effect<void, NotFoundError | DatabaseError>
  }
>() {}

// ---------------------------------------------------------------------------
// Repository Implementation
// ---------------------------------------------------------------------------

const UserRepositoryLive = Layer.effect(
  UserRepository,
  Effect.gen(function* () {
    const db = yield* DatabaseClient

    return {
      findById: (id) =>
        Effect.gen(function* () {
          const result = yield* db.queryOne<User>(
            "SELECT * FROM users WHERE id = $1",
            [id],
          )
          return yield* Option.match(result, {
            onNone: () => Effect.fail(new NotFoundError({ entity: "User", id })),
            onSome: Effect.succeed,
          })
        }),

      findByEmail: (email) =>
        db.queryOne<User>("SELECT * FROM users WHERE email = $1", [email]),

      findAll: (options) =>
        db.query<User>(
          "SELECT * FROM users ORDER BY created_at DESC LIMIT $1 OFFSET $2",
          [options?.limit ?? 50, options?.offset ?? 0],
        ),

      create: (input) =>
        Effect.gen(function* () {
          const existing = yield* db.queryOne<User>(
            "SELECT id FROM users WHERE email = $1",
            [input.email],
          )
          if (Option.isSome(existing)) {
            return yield* Effect.fail(
              new DuplicateError({ entity: "User", field: "email", value: input.email }),
            )
          }
          const id = crypto.randomUUID() as EntityId
          const now = new Date()
          yield* db.execute(
            "INSERT INTO users (id, name, email, role, created_at, updated_at) VALUES ($1, $2, $3, $4, $5, $6)",
            [id, input.name, input.email, input.role, now, now],
          )
          return { id, ...input, createdAt: now, updatedAt: now }
        }),

      update: (id, input) =>
        Effect.gen(function* () {
          const existing = yield* db.queryOne<User>(
            "SELECT * FROM users WHERE id = $1",
            [id],
          )
          if (Option.isNone(existing)) {
            return yield* Effect.fail(new NotFoundError({ entity: "User", id }))
          }
          const now = new Date()
          const updated: User = {
            ...existing.value,
            ...input,
            updatedAt: now,
          }
          yield* db.execute(
            "UPDATE users SET name=$2, email=$3, role=$4, updated_at=$5 WHERE id=$1",
            [id, updated.name, updated.email, updated.role, now],
          )
          return updated
        }),

      delete: (id) =>
        Effect.gen(function* () {
          const existing = yield* db.queryOne<User>(
            "SELECT id FROM users WHERE id = $1",
            [id],
          )
          if (Option.isNone(existing)) {
            return yield* Effect.fail(new NotFoundError({ entity: "User", id }))
          }
          yield* db.execute("DELETE FROM users WHERE id = $1", [id])
        }),
    }
  }),
)

// ---------------------------------------------------------------------------
// In-Memory Implementation (for testing)
// ---------------------------------------------------------------------------

const InMemoryDatabaseClient = Layer.succeed(DatabaseClient, (() => {
  const store = new Map<string, Map<string, unknown>>()
  store.set("users", new Map())

  return {
    query: <T>(_sql: string, _params?: unknown[]) =>
      Effect.succeed([...store.get("users")!.values()] as T[]),

    queryOne: <T>(_sql: string, params?: unknown[]) => {
      const id = params?.[0] as string
      const row = store.get("users")!.get(id)
      return Effect.succeed(row ? Option.some(row as T) : Option.none())
    },

    execute: (_sql: string, params?: unknown[]) => {
      const id = params?.[0] as string
      if (_sql.startsWith("INSERT")) {
        store.get("users")!.set(id, {
          id,
          name: params?.[1],
          email: params?.[2],
          role: params?.[3],
          createdAt: params?.[4],
          updatedAt: params?.[5],
        })
      } else if (_sql.startsWith("DELETE")) {
        store.get("users")!.delete(id)
      }
      return Effect.void
    },
  }
})())

// ---------------------------------------------------------------------------
// Layer Composition
// ---------------------------------------------------------------------------

// Production: UserRepository → DatabaseClient → real DB
// export const ProductionLayer = UserRepositoryLive.pipe(Layer.provide(PostgresDatabaseClient))

// Testing: UserRepository → InMemoryDatabaseClient
export const TestLayer = UserRepositoryLive.pipe(Layer.provide(InMemoryDatabaseClient))

// ---------------------------------------------------------------------------
// Usage Example
// ---------------------------------------------------------------------------

const program = Effect.gen(function* () {
  const repo = yield* UserRepository

  const user = yield* repo.create({
    name: "Alice",
    email: "alice@example.com",
    role: "admin",
  })
  yield* Effect.log(`Created user: ${user.id}`)

  const found = yield* repo.findById(user.id)
  yield* Effect.log(`Found user: ${found.name}`)

  const updated = yield* repo.update(user.id, { name: "Alice Updated" })
  yield* Effect.log(`Updated user: ${updated.name}`)

  yield* repo.delete(user.id)
  yield* Effect.log("Deleted user")
})

// Run with test layer
Effect.runPromise(program.pipe(Effect.provide(TestLayer))).catch(console.error)
