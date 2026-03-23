/**
 * http-service-template.ts — Template for an Effect-based HTTP service with layers.
 *
 * Copy this file into your project and adapt the routes, services, and layers.
 *
 * Run with: npx tsx http-service-template.ts
 * Requires: effect, @effect/platform, @effect/platform-node
 */

import { Context, Data, Effect, Layer, Schema } from "effect"
import {
  HttpMiddleware,
  HttpRouter,
  HttpServer,
  HttpServerRequest,
  HttpServerResponse,
} from "@effect/platform"
import { NodeHttpServer, NodeRuntime } from "@effect/platform-node"
import { createServer } from "node:http"

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

class NotFoundError extends Data.TaggedError("NotFoundError")<{
  entity: string
  id: string
}> {}

class ValidationError extends Data.TaggedError("ValidationError")<{
  field: string
  reason: string
}> {}

// ---------------------------------------------------------------------------
// Schemas
// ---------------------------------------------------------------------------

const UserSchema = Schema.Struct({
  id: Schema.String,
  name: Schema.String,
  email: Schema.String,
})

const CreateUserBody = Schema.Struct({
  name: Schema.String.pipe(Schema.nonEmptyString()),
  email: Schema.String.pipe(Schema.nonEmptyString()),
})

type User = typeof UserSchema.Type

// ---------------------------------------------------------------------------
// Services
// ---------------------------------------------------------------------------

class UserRepository extends Context.Tag("UserRepository")<
  UserRepository,
  {
    readonly findById: (id: string) => Effect.Effect<User, NotFoundError>
    readonly findAll: () => Effect.Effect<ReadonlyArray<User>>
    readonly create: (data: typeof CreateUserBody.Type) => Effect.Effect<User>
  }
>() {}

// ---------------------------------------------------------------------------
// Layers
// ---------------------------------------------------------------------------

const UserRepositoryLive = Layer.succeed(UserRepository, {
  findById: (id) =>
    id === "1"
      ? Effect.succeed({ id: "1", name: "Alice", email: "alice@example.com" })
      : Effect.fail(new NotFoundError({ entity: "User", id })),
  findAll: () =>
    Effect.succeed([
      { id: "1", name: "Alice", email: "alice@example.com" },
      { id: "2", name: "Bob", email: "bob@example.com" },
    ]),
  create: (data) =>
    Effect.succeed({ id: crypto.randomUUID(), ...data }),
})

// ---------------------------------------------------------------------------
// Error Handler
// ---------------------------------------------------------------------------

const withErrorHandling = <R>(
  effect: Effect.Effect<HttpServerResponse.HttpServerResponse, NotFoundError | ValidationError, R>,
): Effect.Effect<HttpServerResponse.HttpServerResponse, never, R> =>
  effect.pipe(
    Effect.catchTags({
      NotFoundError: (err) =>
        HttpServerResponse.json(
          { error: `${err.entity} not found: ${err.id}` },
          { status: 404 },
        ),
      ValidationError: (err) =>
        HttpServerResponse.json(
          { error: `Validation failed on ${err.field}: ${err.reason}` },
          { status: 400 },
        ),
    }),
  )

// ---------------------------------------------------------------------------
// Routes
// ---------------------------------------------------------------------------

const router = HttpRouter.empty.pipe(
  HttpRouter.get(
    "/health",
    HttpServerResponse.json({ status: "ok" }),
  ),

  HttpRouter.get(
    "/users",
    Effect.gen(function* () {
      const repo = yield* UserRepository
      const users = yield* repo.findAll()
      return HttpServerResponse.json(users)
    }),
  ),

  HttpRouter.get(
    "/users/:id",
    Effect.gen(function* () {
      const repo = yield* UserRepository
      const params = yield* HttpRouter.params
      const user = yield* repo.findById(params.id)
      return HttpServerResponse.json(user)
    }).pipe(withErrorHandling),
  ),

  HttpRouter.post(
    "/users",
    Effect.gen(function* () {
      const repo = yield* UserRepository
      const body = yield* HttpServerRequest.schemaBodyJson(CreateUserBody)
      const user = yield* repo.create(body)
      return HttpServerResponse.json(user, { status: 201 })
    }).pipe(withErrorHandling),
  ),
)

// ---------------------------------------------------------------------------
// Server
// ---------------------------------------------------------------------------

const server = router.pipe(
  HttpServer.serve(HttpMiddleware.logger),
  Layer.provide(UserRepositoryLive),
  Layer.provide(NodeHttpServer.layer(createServer, { port: 3000 })),
)

NodeRuntime.runMain(Layer.launch(server))
