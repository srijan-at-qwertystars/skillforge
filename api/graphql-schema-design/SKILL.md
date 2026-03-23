---
name: graphql-schema-design
description: >
  Use when user designs GraphQL schemas, asks about types/queries/mutations/subscriptions,
  Relay-style connections, GraphQL error handling, schema-first vs code-first, or
  GraphQL federation/stitching. Do NOT use for REST API design, gRPC, or GraphQL
  client-side queries (Apollo Client, urql) unless schema-related.
---

# GraphQL Schema Design

## Schema-First vs Code-First

**Schema-first (SDL-first):** Write `.graphql` files, generate resolvers/types. Language-agnostic contract readable by all teams. Works with GraphQL Inspector, Apollo GraphOS. Downside: manual sync without codegen.

**Code-first:** Define schema programmatically (Pothos, Nexus, TypeGraphQL, Strawberry). Full type safety, IDE refactoring, no drift. Downside: schema shape less visible without tooling.

**Recommendation:** Use code-first with SDL export for CI validation. Run `graphql-inspector diff` on every PR.


## Naming Conventions

### Types — PascalCase, domain nouns

```graphql
type User { ... }
type OrderLineItem { ... }
type ShippingAddress { ... }
```

### Fields — camelCase, descriptive

```graphql
type User {
  id: ID!
  emailAddress: String!
  createdAt: DateTime!
  isVerified: Boolean!
}
```

### Mutations — verb-noun, dedicated payload

```graphql
type Mutation {
  createUser(input: CreateUserInput!): CreateUserPayload!
  updateOrder(input: UpdateOrderInput!): UpdateOrderPayload!
  cancelSubscription(id: ID!): CancelSubscriptionPayload!
}
```

### Enums — SCREAMING_SNAKE_CASE values, PascalCase type

```graphql
enum OrderStatus {
  PENDING
  CONFIRMED
  SHIPPED
  DELIVERED
  CANCELLED
}
```


## Relay-Style Connection Pagination

Adopt the Relay connection spec for all list fields. Future-proofs for metadata, edge attributes, and bidirectional paging.

```graphql
type Query {
  users(first: Int, after: String, last: Int, before: String, filter: UserFilter): UserConnection!
}

type UserConnection {
  edges: [UserEdge!]!
  pageInfo: PageInfo!
  totalCount: Int
}
type UserEdge {
  node: User!
  cursor: String!
}
type PageInfo {
  hasNextPage: Boolean!
  hasPreviousPage: Boolean!
  startCursor: String
  endCursor: String
}
```

### Rules

- Make cursors opaque (base64-encode the key).
- Support forward (`first`/`after`) and backward (`last`/`before`) paging.
- Add `totalCount` only when cheaply computable.
- Add edge-level fields when the relationship carries data:

```graphql
type TeamMemberEdge {
  node: User!
  cursor: String!
  role: TeamRole!
  joinedAt: DateTime!
}
```


## Input Types for Mutations

Wrap mutation arguments in a single `Input` type. Simplifies codegen, enables validation, allows additive evolution.

```graphql
input CreateUserInput {
  name: String!
  emailAddress: String!
  role: UserRole = MEMBER
}

type CreateUserPayload {
  user: User
  errors: [UserError!]!
}
```

### Rules

- One input per mutation (`<MutationName>Input`), one payload per mutation (`<MutationName>Payload`).
- Include `errors` field on every payload for domain errors.
- Never reuse input types across unrelated mutations.


## Error Handling

### Pattern 1 — Union result types (recommended)

Model success and failure as explicit union members. Clients use `__typename` to exhaustively match.

```graphql
union CreateUserResult = CreateUserSuccess | ValidationError | NotAuthorizedError

type CreateUserSuccess { user: User! }

type ValidationError {
  field: String!
  message: String!
}

type NotAuthorizedError { message: String! }

type Mutation {
  createUser(input: CreateUserInput!): CreateUserResult!
}
```

**Pros:** Type-safe. Errors are schema contract.

### Pattern 2 — Errors field on payload

```graphql
type CreateUserPayload {
  user: User
  errors: [UserError!]!
}
type UserError {
  field: String
  message: String!
  code: ErrorCode!
}
enum ErrorCode {
  VALIDATION_FAILED
  NOT_FOUND
  ALREADY_EXISTS
  UNAUTHORIZED
}
```

**Pros:** Simpler client code. Works well with codegen.

### Pattern 3 — Top-level errors array

Use the built-in GraphQL `errors` array with `extensions`. Reserve for infrastructure errors (auth, rate limits), not domain errors.

```json
{
  "errors": [
    {
      "message": "Rate limit exceeded",
      "extensions": { "code": "RATE_LIMITED", "retryAfter": 30 }
    }
  ]
}
```

**Recommendation:** Use union result types or payload error fields for domain errors. Use top-level `errors` only for infrastructure/transport concerns.


## Nullability Strategy

### Nullable-by-default (recommended)

- Start every new field as nullable.
- Tighten to non-null (`!`) only when the value is guaranteed by data integrity.
- Non-null fields trigger *null bubbling*: a null value nullifies the nearest nullable parent. Overusing `!` cascades partial failures.

### When to use non-null

- `id: ID!` — always present. `__typename` — always present.
- Fields backed by `NOT NULL` columns with no external dependency.
- Connection structural fields: `edges`, `pageInfo`.

### When to stay nullable

- Fields from external services that may be unavailable.
- Fields added during evolution where existing records lack data.
- Computed fields that can fail independently.

```graphql
type Product {
  id: ID!
  name: String!           # always present
  description: String     # optional
  price: Money!           # required business data
  rating: Float           # may not have ratings yet
  manufacturer: Company   # external service — nullable
}
```


## N+1 Problem and DataLoader

The N+1 problem: fetching a list triggers one query per item for related data.

### DataLoader

Batch and deduplicate database calls per request tick.

```javascript
const userLoader = new DataLoader(async (userIds) => {
  const users = await db.users.findMany({ where: { id: { in: userIds } } });
  const map = new Map(users.map(u => [u.id, u]));
  return userIds.map(id => map.get(id) ?? new Error(`User ${id} not found`));
});

// In resolver
const resolvers = {
  Post: {
    author: (post, _, { loaders }) => loaders.userLoader.load(post.authorId),
  },
};
```

### Rules

- Create a new DataLoader per request. Never share globally.
- Maintain input-output order.
- Clear cache after mutations.
- Combine with `@defer` or lookahead for further optimization.


## Schema Evolution

### Additive changes only

- Add new fields, types, arguments (with defaults), enum values freely.
- Never remove or rename without deprecation.

### Deprecation

Use `@deprecated` with a reason and migration path.

```graphql
type User {
  name: String! @deprecated(reason: "Use `displayName` instead. Removal: 2026-01.")
  displayName: String!
}
```

### Breaking change prevention

- Run `graphql-inspector diff` in CI.
- Track field usage with Apollo GraphOS. Only remove zero-usage fields.
- Add new required arguments with defaults to avoid breaking queries.
- Avoid URL-based versioning. Evolve additively. Use `@deprecated` for sunsetting.


## Federation and Stitching

### Apollo Federation v2

Each subgraph owns a schema slice. Apollo Router (Rust) composes them into a supergraph.

```graphql
# -- Users subgraph --
type User @key(fields: "id") {
  id: ID!
  name: String!
  email: String!
}

# -- Orders subgraph --
type User @key(fields: "id") {
  id: ID!
  orders: [Order!]!
}

type Order @key(fields: "id") {
  id: ID!
  total: Money!
  placedAt: DateTime!
}
```

### Key directives

| Directive          | Purpose                                        |
| ------------------ | ---------------------------------------------- |
| `@key`             | Declare entity identity fields                 |
| `@shareable`       | Allow multiple subgraphs to resolve a field    |
| `@external`        | Reference a field defined in another subgraph  |
| `@requires`        | Declare fields needed before resolving         |
| `@provides`        | Declare fields this subgraph can supply        |
| `@override`        | Migrate field ownership between subgraphs      |
| `@interfaceObject` | Compose polymorphic types across subgraphs     |

### Rules

- Map each subgraph to one bounded context / domain.
- Batch all `__resolveReference` calls with DataLoader.
- Validate composition in CI with `rover supergraph compose`.
- Migrate from Federation v1 incrementally — upgrade router first, then subgraphs.
- Prefer Apollo Router (Rust) over the Node.js gateway for performance.

### Schema stitching

Use when merging schemas without Federation runtime. `@graphql-tools/stitch` merges at the gateway level. Less opinionated but requires manual conflict resolution.


## Custom Scalars

Define custom scalars for domain types. Use `@specifiedBy` to link to format specs.

```graphql
scalar DateTime @specifiedBy(url: "https://scalars.graphql.org/andimarek/date-time")
scalar URL @specifiedBy(url: "https://scalars.graphql.org/andimarek/url")
scalar JSON
scalar EmailAddress
scalar Money
```

### Rules

- Validate on parse — reject malformed values at the schema boundary.
- Serialize consistently (ISO 8601 for dates, RFC 3986 for URLs).
- Use `graphql-scalars` library for common scalars.
- Document format in the schema description.

```graphql
"""
ISO 8601 date-time string (e.g., 2025-07-14T12:00:00Z).
"""
scalar DateTime
```


## Authorization Patterns

### Directive-based authorization

Declare access rules in SDL. Enforce via directive transformer or middleware.

```graphql
directive @auth(requires: Role!) on FIELD_DEFINITION | OBJECT
enum Role { USER ADMIN SUPER_ADMIN }

type Mutation {
  deleteUser(id: ID!): DeleteUserPayload! @auth(requires: ADMIN)
}
type User {
  email: String! @auth(requires: USER)
  internalNotes: String @auth(requires: ADMIN)
}
```

### Resolver-level authorization

Check permissions inside resolvers. Better for complex, context-dependent rules.

```javascript
const resolvers = {
  Mutation: {
    deleteUser: (_, { id }, ctx) => {
      if (!ctx.user || ctx.user.role !== 'ADMIN') {
        throw new ForbiddenError('Admin access required');
      }
      return userService.delete(id);
    },
  },
};
```

### Rules

- Default-deny: require auth for all operations unless explicitly public.
- Check object-level ownership (BOLA/IDOR prevention), not just role.
- Pass auth context (JWT claims, scopes) via resolver context.
- Disable introspection in production.
- Add auth regression tests to CI.


## Query Complexity and Depth Limiting

Prevent abusive queries from overloading the server.

### Depth limiting

Reject queries exceeding max nesting depth (typically 7–10).

```javascript
import depthLimit from 'graphql-depth-limit';

const server = new ApolloServer({
  schema,
  validationRules: [depthLimit(10)],
});
```

### Complexity analysis

Assign cost per field. Reject queries exceeding a budget.

```graphql
type Query {
  users(first: Int): UserConnection! # cost: first * 2
  user(id: ID!): User               # cost: 1
}
```

```javascript
import { createComplexityRule, simpleEstimator, fieldExtensionsEstimator } from 'graphql-query-complexity';

const complexityRule = createComplexityRule({
  maximumComplexity: 1000,
  estimators: [fieldExtensionsEstimator(), simpleEstimator({ defaultComplexity: 1 })],
  onComplete: (complexity) => console.log('Query complexity:', complexity),
});
```

### Rules

- Depth limit: 7–10 for most APIs. Complexity budget: 500–1000.
- Multiply list field costs by `first`/`last` argument value.
- Log rejected queries. Use persisted queries for high-traffic endpoints.


## Subscription Design Patterns

### When to use subscriptions

- Real-time UI updates (chat, notifications, dashboards).
- Event-driven data where polling is wasteful.
- Avoid for infrequent changes — use polling or cache invalidation.

### Schema design

```graphql
type Subscription {
  orderStatusChanged(orderId: ID!): OrderStatusEvent!
  newMessage(channelId: ID!): Message!
  userPresenceChanged: PresenceEvent!
}
type OrderStatusEvent {
  order: Order!
  previousStatus: OrderStatus!
  newStatus: OrderStatus!
  changedAt: DateTime!
}
```

### Rules

- Name fields as events (`orderStatusChanged`, not `order`).
- Include context in the payload — avoid forcing follow-up queries.
- Filter server-side with arguments (`orderId`, `channelId`).
- Use `graphql-ws` (not deprecated `subscriptions-transport-ws`).
- Authenticate on connection init, not per message.
- Apply rate limiting to subscription connections.
- Clean up resources on client disconnect.

```javascript
const resolvers = {
  Subscription: {
    newMessage: {
      subscribe: (_, { channelId }, { pubsub }) =>
        pubsub.asyncIterableIterator(`MESSAGE_ADDED_${channelId}`),
    },
  },
};
```

<!-- tested: pass -->
