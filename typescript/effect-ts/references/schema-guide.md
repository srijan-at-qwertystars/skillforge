# Effect Schema Deep Dive

## Table of Contents

- [Primitive and Literal Schemas](#primitive-and-literal-schemas)
- [Compound Schemas](#compound-schemas)
- [Branded Types](#branded-types)
- [Schema Transformations and Filters](#schema-transformations-and-filters)
- [Decoding vs Encoding Asymmetry](#decoding-vs-encoding-asymmetry)
- [Class-Based Schemas](#class-based-schemas)
- [Property Signatures and Optional Fields](#property-signatures-and-optional-fields)
- [Schema Composition and Extension](#schema-composition-and-extension)
- [Integration with HTTP APIs](#integration-with-http-apis)
- [Common Patterns and Recipes](#common-patterns-and-recipes)

---

## Primitive and Literal Schemas

### Built-in Primitives

```typescript
import { Schema } from "effect"

Schema.String        // string
Schema.Number        // number
Schema.Boolean       // boolean
Schema.BigInt        // bigint (decodes from string)
Schema.Date          // Date (decodes from string via DateFromString)
Schema.Void          // void
Schema.Undefined     // undefined
Schema.Null          // null
Schema.Never         // never (always fails)
Schema.Unknown       // unknown (always succeeds)
Schema.Any           // any
Schema.Object        // object
Schema.Symbol        // symbol
```

### Literals

```typescript
Schema.Literal("admin")                     // "admin"
Schema.Literal("admin", "user", "guest")    // "admin" | "user" | "guest"
Schema.Literal(42)                          // 42
Schema.Literal(true)                        // true
Schema.Null                                 // null
```

### Template Literals

```typescript
// `user-${string}`
Schema.TemplateLiteral(Schema.Literal("user-"), Schema.String)

// `v${number}`
Schema.TemplateLiteral(Schema.Literal("v"), Schema.Number)
```

### Enums

```typescript
enum Status {
  Active = "active",
  Inactive = "inactive",
}

const StatusSchema = Schema.Enums(Status)
// Decodes: "active" | "inactive" → Status.Active | Status.Inactive
```

---

## Compound Schemas

### Struct

```typescript
const User = Schema.Struct({
  id: Schema.Number,
  name: Schema.String,
  email: Schema.String,
})

type User = typeof User.Type        // { id: number; name: string; email: string }
type UserEncoded = typeof User.Encoded // same shape when no transforms
```

### Arrays and Tuples

```typescript
// Array of strings
Schema.Array(Schema.String)         // string[]

// Non-empty array
Schema.NonEmptyArray(Schema.String) // readonly [string, ...string[]]

// Typed tuple
Schema.Tuple(Schema.String, Schema.Number) // readonly [string, number]

// Tuple with rest
Schema.Tuple(
  [Schema.String, Schema.Number],    // fixed elements
  Schema.Boolean                     // rest element
)
// readonly [string, number, ...boolean[]]
```

### Records

```typescript
// Record<string, number>
Schema.Record({ key: Schema.String, value: Schema.Number })

// Map-like with specific key types
Schema.Record({
  key: Schema.String.pipe(Schema.pattern(/^[a-z]+$/)),
  value: Schema.Number
})
```

### Union and Discriminated Unions

```typescript
// Simple union
Schema.Union(Schema.String, Schema.Number)

// Discriminated union (preferred — better error messages and performance)
const Shape = Schema.Union(
  Schema.Struct({ _tag: Schema.Literal("Circle"), radius: Schema.Number }),
  Schema.Struct({ _tag: Schema.Literal("Square"), side: Schema.Number }),
)
```

### Nullable and Optional Wrappers

```typescript
// T | null
Schema.NullOr(Schema.String)

// T | undefined
Schema.UndefinedOr(Schema.String)

// T | null | undefined
Schema.NullishOr(Schema.String)

// Option<T> — decodes from T | null into Option
Schema.OptionFromNullishOr(Schema.String, null)
```

---

## Branded Types

Branded types add a phantom tag to prevent mixing structurally identical types.

```typescript
// Define a branded type
const UserId = Schema.String.pipe(Schema.brand("UserId"))
type UserId = typeof UserId.Type // string & Brand<"UserId">

const OrderId = Schema.String.pipe(Schema.brand("OrderId"))
type OrderId = typeof OrderId.Type // string & Brand<"OrderId">

// These are compile-time incompatible:
// const uid: UserId = "abc" as OrderId // ✗ Type error

// Decode creates branded values
const uid = Schema.decodeUnknownSync(UserId)("user-123")
// uid is UserId
```

### Branded with Validation

```typescript
const Email = Schema.String.pipe(
  Schema.pattern(/^[^@]+@[^@]+\.[^@]+$/),
  Schema.brand("Email")
)
type Email = typeof Email.Type // string & Brand<"Email">

const PositiveInt = Schema.Number.pipe(
  Schema.int(),
  Schema.positive(),
  Schema.brand("PositiveInt")
)
```

---

## Schema Transformations and Filters

### Filters (Refinements)

Filters narrow a type without changing its shape:

```typescript
const Age = Schema.Number.pipe(
  Schema.int(),
  Schema.between(0, 150),
)

const NonEmptyString = Schema.String.pipe(
  Schema.nonEmptyString()
)

const Email = Schema.String.pipe(
  Schema.pattern(/^[^@]+@[^@]+\.[^@]+$/),
  Schema.annotations({ message: () => "Invalid email format" })
)
```

Built-in filters:
- **String:** `minLength`, `maxLength`, `length`, `pattern`, `nonEmptyString`, `trimmed`, `lowercased`, `uppercased`, `startsWith`, `endsWith`, `includes`
- **Number:** `int`, `positive`, `nonNegative`, `negative`, `between`, `greaterThan`, `lessThan`, `finite`, `multipleOf`
- **Array:** `minItems`, `maxItems`, `itemsCount`

### Transformations

Transformations change the shape between Encoded and Type:

```typescript
// String → Number
const NumberFromString = Schema.transform(
  Schema.String,  // from (Encoded)
  Schema.Number,  // to (Type)
  {
    strict: true,
    decode: (s) => parseFloat(s),
    encode: (n) => String(n),
  }
)

// DateFromString (built-in)
Schema.DateFromString  // string → Date

// Trim on decode
const TrimmedString = Schema.transform(
  Schema.String,
  Schema.String,
  {
    strict: true,
    decode: (s) => s.trim(),
    encode: (s) => s,
  }
)
```

### Effectful Transformations

When decode/encode can fail:

```typescript
const SafeNumberFromString = Schema.transformOrFail(
  Schema.String,
  Schema.Number,
  {
    strict: true,
    decode: (s, _, ast) => {
      const n = parseFloat(s)
      return isNaN(n)
        ? ParseResult.fail(new ParseResult.Type(ast, s, "Not a number"))
        : ParseResult.succeed(n)
    },
    encode: (n) => ParseResult.succeed(String(n)),
  }
)
```

### Chaining Filters and Transforms

```typescript
const Price = Schema.String.pipe(
  Schema.transform(Schema.Number, {
    strict: true,
    decode: (s) => parseFloat(s),
    encode: (n) => n.toFixed(2),
  }),
  Schema.positive(),
  Schema.brand("Price")
)
// Encoded: string, Type: number & Brand<"Price">
```

---

## Decoding vs Encoding Asymmetry

Schema is bidirectional. The `Type` (decoded) and `Encoded` types can differ.

```typescript
const Event = Schema.Struct({
  name: Schema.String,
  timestamp: Schema.DateFromString,  // string ↔ Date
  count: Schema.NumberFromString,    // string ↔ number
})

type EventType = typeof Event.Type
// { name: string; timestamp: Date; count: number }

type EventEncoded = typeof Event.Encoded
// { name: string; timestamp: string; count: string }
```

### Decode (external → internal)

```typescript
const decoded = Schema.decodeUnknownSync(Event)({
  name: "click",
  timestamp: "2024-01-15T10:00:00Z",
  count: "42",
})
// { name: "click", timestamp: Date(2024-01-15...), count: 42 }
```

### Encode (internal → external)

```typescript
const encoded = Schema.encodeSync(Event)(decoded)
// { name: "click", timestamp: "2024-01-15T10:00:00.000Z", count: "42" }
```

### When to Use Which

| Function | Input | Output | Use Case |
|----------|-------|--------|----------|
| `decodeUnknownSync` | `unknown` | `Type` | External data (API responses, user input) |
| `decodeSync` | `Encoded` | `Type` | Known-shape data (DB rows, parsed JSON) |
| `encodeSync` | `Type` | `Encoded` | Serializing for API/storage |
| `decodeUnknown` | `unknown` | `Effect<Type, ParseError>` | Effectful composition |
| `decode` | `Encoded` | `Effect<Type, ParseError>` | Effectful with known input |

---

## Class-Based Schemas

`Schema.Class` creates a class with built-in schema, structural equality, and nice `toString`.

```typescript
class User extends Schema.Class<User>("User")({
  id: Schema.Number,
  name: Schema.String,
  email: Schema.String,
}) {}

// Instances are created via `new` (validated)
const user = new User({ id: 1, name: "Alice", email: "a@b.com" })

// Schema is attached
const decoded = Schema.decodeUnknownSync(User)({ id: 1, name: "Alice", email: "a@b.com" })

// Structural equality
new User({ id: 1, name: "A", email: "a@b" }).equals(new User({ id: 1, name: "A", email: "a@b" }))
// true
```

### Tagged Errors with Schema

```typescript
class NotFoundError extends Schema.TaggedError<NotFoundError>()(
  "NotFoundError",
  { entity: Schema.String, id: Schema.String }
) {}

class ValidationError extends Schema.TaggedError<ValidationError>()(
  "ValidationError",
  { field: Schema.String, message: Schema.String }
) {}

// Usage
const program = Effect.gen(function* () {
  return yield* Effect.fail(new NotFoundError({ entity: "User", id: "123" }))
})
// Type: Effect<never, NotFoundError, never>
```

### Tagged Request (for Effect RPC)

```typescript
class GetUser extends Schema.TaggedRequest<GetUser>()(
  "GetUser",
  {
    failure: NotFoundError,
    success: User,
    payload: { id: Schema.String },
  }
) {}
```

### Extending Classes

```typescript
class BaseEntity extends Schema.Class<BaseEntity>("BaseEntity")({
  id: Schema.String,
  createdAt: Schema.DateFromString,
}) {}

class User extends BaseEntity.extend<User>("User")({
  name: Schema.String,
  email: Schema.String,
}) {}
// Has: id, createdAt, name, email
```

---

## Property Signatures and Optional Fields

### Optional Properties

```typescript
const User = Schema.Struct({
  name: Schema.String,
  bio: Schema.optional(Schema.String),       // bio?: string | undefined
})
// Type: { name: string; bio?: string | undefined }
// Encoded: { name: string; bio?: string | undefined }
```

### Optional with Default

```typescript
const Config = Schema.Struct({
  port: Schema.optional(Schema.Number, { default: () => 3000 }),
  host: Schema.optional(Schema.String, { default: () => "localhost" }),
})
// Encoded: { port?: number; host?: string }
// Type: { port: number; host: string }  — always present after decode
```

### Optional to Required (exact)

```typescript
const User = Schema.Struct({
  nickname: Schema.optional(Schema.String, { exact: true }),
})
// Type: { nickname?: string }  — no undefined, just missing key
```

### optionalWith and as:"Option"

```typescript
const User = Schema.Struct({
  bio: Schema.optionalWith(Schema.String, { as: "Option" }),
})
// Encoded: { bio?: string }
// Type: { bio: Option<string> }  — None when missing, Some when present
```

### Read-only Properties

All Schema.Struct properties are readonly by default in the type output.

```typescript
const Point = Schema.Struct({
  x: Schema.Number,
  y: Schema.Number,
})
// Type: { readonly x: number; readonly y: number }

// Mutable version
const MutablePoint = Schema.mutable(Point)
// Type: { x: number; y: number }
```

---

## Schema Composition and Extension

### Struct Spreading

```typescript
const Address = Schema.Struct({
  street: Schema.String,
  city: Schema.String,
  zip: Schema.String,
})

const Person = Schema.Struct({
  name: Schema.String,
  ...Address.fields,   // spread fields
})
// { name: string; street: string; city: string; zip: string }
```

### extend

```typescript
const TimestampFields = Schema.Struct({
  createdAt: Schema.DateFromString,
  updatedAt: Schema.DateFromString,
})

const User = Schema.Struct({
  id: Schema.Number,
  name: Schema.String,
}).pipe(Schema.extend(TimestampFields))
```

### pick and omit

```typescript
const UserSummary = User.pipe(Schema.pick("id", "name"))
// { id: number; name: string }

const UserUpdate = User.pipe(Schema.omit("id", "createdAt"))
// { name: string; email: string; updatedAt: Date }
```

### partial and required

```typescript
// All fields optional
const UserPatch = Schema.partial(User)

// Specific fields optional
const UserCreate = Schema.Struct({
  name: Schema.String,
  email: Schema.String,
  bio: Schema.optional(Schema.String),
})
```

### Recursive Schemas

```typescript
interface Category {
  readonly name: string
  readonly children: ReadonlyArray<Category>
}

const Category: Schema.Schema<Category> = Schema.Struct({
  name: Schema.String,
  children: Schema.suspend(() => Schema.Array(Category)),
})
```

### Schema.compose — Chaining Schemas

```typescript
// NumberFromString: string → number
// Then filter to positive
const PositiveFromString = Schema.compose(
  Schema.NumberFromString,
  Schema.Number.pipe(Schema.positive())
)
```

---

## Integration with HTTP APIs

### Request Body Validation

```typescript
import { HttpRouter, HttpServerRequest, HttpServerResponse } from "@effect/platform"

const CreateUserBody = Schema.Struct({
  name: Schema.String.pipe(Schema.nonEmptyString()),
  email: Schema.String.pipe(Schema.pattern(/^[^@]+@[^@]+\.[^@]+$/)),
  role: Schema.optional(Schema.Literal("admin", "user"), { default: () => "user" as const }),
})

const createUser = HttpRouter.post(
  "/users",
  Effect.gen(function* () {
    const body = yield* HttpServerRequest.schemaBodyJson(CreateUserBody)
    const user = yield* userService.create(body)
    return HttpServerResponse.json(user, { status: 201 })
  })
)
```

### Response Schemas

```typescript
const UserResponse = Schema.Struct({
  id: Schema.String,
  name: Schema.String,
  createdAt: Schema.DateFromString,
})

const fetchUser = (id: string) =>
  Effect.gen(function* () {
    const client = yield* HttpClient.HttpClient
    const response = yield* client.get(`/users/${id}`)
    return yield* HttpClientResponse.schemaBodyJson(UserResponse)(response)
  }).pipe(Effect.scoped)
```

### URL Parameters and Query Strings

```typescript
import { HttpServerRequest, HttpRouter } from "@effect/platform"

const UserParams = Schema.Struct({
  id: Schema.String.pipe(Schema.nonEmptyString()),
})

const PaginationQuery = Schema.Struct({
  page: Schema.optional(Schema.NumberFromString, { default: () => 1 }),
  limit: Schema.optional(Schema.NumberFromString, { default: () => 20 }),
})

const listUsers = HttpRouter.get(
  "/users",
  Effect.gen(function* () {
    const query = yield* HttpServerRequest.schemaSearchParams(PaginationQuery)
    const users = yield* userService.list(query.page, query.limit)
    return HttpServerResponse.json(users)
  })
)
```

### API Client with Schema Validation

```typescript
const makeApiClient = Effect.gen(function* () {
  const client = (yield* HttpClient.HttpClient).pipe(
    HttpClient.filterStatusOk,
    HttpClient.mapRequest(HttpClientRequest.prependUrl("https://api.example.com")),
  )

  return {
    getUser: (id: string) =>
      client.get(`/users/${id}`).pipe(
        Effect.flatMap(HttpClientResponse.schemaBodyJson(UserResponse)),
        Effect.scoped,
        Effect.withSpan("api.getUser", { attributes: { userId: id } }),
      ),
    createUser: (data: typeof CreateUserBody.Type) =>
      HttpClientRequest.post(`/users`).pipe(
        HttpClientRequest.schemaBodyJson(CreateUserBody)(data),
        Effect.flatMap((req) => client.execute(req)),
        Effect.flatMap(HttpClientResponse.schemaBodyJson(UserResponse)),
        Effect.scoped,
        Effect.withSpan("api.createUser"),
      ),
  }
})
```

---

## Common Patterns and Recipes

### JSON-Safe Schema

For schemas that must round-trip through JSON:

```typescript
const JsonSafeDate = Schema.DateFromString
// Encode: Date → string, Decode: string → Date

// DON'T: Schema.Date alone doesn't survive JSON.stringify
```

### Pagination Schema

```typescript
const Paginated = <A, I, R>(itemSchema: Schema.Schema<A, I, R>) =>
  Schema.Struct({
    items: Schema.Array(itemSchema),
    total: Schema.Number.pipe(Schema.int(), Schema.nonNegative()),
    page: Schema.Number.pipe(Schema.int(), Schema.positive()),
    pageSize: Schema.Number.pipe(Schema.int(), Schema.positive()),
    hasMore: Schema.Boolean,
  })

const UserPage = Paginated(User)
```

### API Error Schema

```typescript
const ApiErrorBody = Schema.Struct({
  error: Schema.Struct({
    code: Schema.String,
    message: Schema.String,
    details: Schema.optional(Schema.Unknown),
  }),
})
```

### Schema as Validator (standalone)

```typescript
const isValidEmail = Schema.is(Email)
// (input: unknown) => input is Email

if (isValidEmail(value)) {
  // value is Email
}

// Assertion
Schema.asserts(Email)(value)
// throws ParseError if invalid, narrows type if valid
```
