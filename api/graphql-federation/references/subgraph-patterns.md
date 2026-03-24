# Subgraph Patterns — Apollo Federation v2

## Table of Contents

- [Entity Design Philosophy](#entity-design-philosophy)
  - [Single Ownership](#single-ownership)
  - [Shared Ownership](#shared-ownership)
  - [Choosing an Ownership Model](#choosing-an-ownership-model)
- [@key Variations](#key-variations)
  - [Simple Keys](#simple-keys)
  - [Composite Keys](#composite-keys)
  - [Compound (Nested) Keys](#compound-nested-keys)
  - [Multi-Key Entities](#multi-key-entities)
  - [Non-Resolvable Keys](#non-resolvable-keys)
- [Value Types with @shareable](#value-types-with-shareable)
  - [When to Use Value Types](#when-to-use-value-types)
  - [Pitfalls of Over-Sharing](#pitfalls-of-over-sharing)
- [Computed Fields with @requires](#computed-fields-with-requires)
  - [Basic Usage](#basic-usage)
  - [Nested @requires](#nested-requires)
  - [Performance Implications](#performance-implications)
- [Interface Entities](#interface-entities)
  - [Defining Interface Entities](#defining-interface-entities)
  - [Resolving Interface Entities](#resolving-interface-entities)
- [Union Entities](#union-entities)
- [Subscriptions in Federation](#subscriptions-in-federation)
  - [Router-Level Subscriptions](#router-level-subscriptions)
  - [Callback-Based Subscriptions](#callback-based-subscriptions)
  - [Limitations](#limitations)
- [Error Handling Patterns](#error-handling-patterns)
  - [Partial Data with Errors](#partial-data-with-errors)
  - [Error Propagation Across Subgraphs](#error-propagation-across-subgraphs)
  - [Result Union Pattern](#result-union-pattern)
- [N+1 Problem in Resolvers](#n1-problem-in-resolvers)
  - [The Problem](#the-problem)
  - [DataLoader Solution](#dataloader-solution)
  - [Batch Entity Resolution](#batch-entity-resolution)
  - [Per-Request DataLoader Scoping](#per-request-dataloader-scoping)
- [Pagination Across Subgraphs](#pagination-across-subgraphs)
  - [Cursor-Based Pagination](#cursor-based-pagination)
  - [Cross-Subgraph Pagination Challenges](#cross-subgraph-pagination-challenges)
  - [Recommended Patterns](#recommended-patterns)

---

## Entity Design Philosophy

Entities are the backbone of federation — they represent domain objects shared across subgraph boundaries. How you model entity ownership determines the flexibility, performance, and maintainability of your supergraph.

### Single Ownership

In the single-ownership model, exactly one subgraph is the **canonical source** for an entity. It defines the `@key`, the core fields, and the primary reference resolver. Other subgraphs **extend** the entity by declaring only the `@key` fields and their contributed fields.

```graphql
# Products subgraph (owner)
type Product @key(fields: "upc") {
  upc: String!
  name: String!
  price: Int!
  description: String
  category: Category!
}

# Reviews subgraph (contributor)
type Product @key(fields: "upc") {
  upc: String!          # key only — not owned here
  reviews: [Review!]!   # contributed field
  averageRating: Float  # contributed computed field
}

# Inventory subgraph (contributor)
type Product @key(fields: "upc") {
  upc: String!
  inStock: Boolean!
  warehouseLocation: String
}
```

**Advantages:**
- Clear ownership; easy to reason about which team controls which fields
- Simpler composition — fewer chances of conflicting field definitions
- Straightforward reference resolvers

**When to use:** Default choice. Most entities should have a single owner.

### Shared Ownership

Some types are genuinely shared — no single subgraph "owns" them. These are typically value types (like `Money`, `Address`, `GeoCoordinates`) that multiple subgraphs define identically.

```graphql
# In both products and orders subgraphs
type Money @shareable {
  amount: Int!
  currency: String!
}
```

For entity-level shared ownership, every subgraph defining the entity must produce identical values for shared fields. This is rare and should be approached carefully.

### Choosing an Ownership Model

| Signal                            | Recommendation          |
|-----------------------------------|-------------------------|
| One team manages the data source  | Single ownership        |
| Field is derived from entity data | Single owner extends    |
| Type has no identity (no @key)    | Value type, @shareable  |
| Field is identical across sources | @shareable              |
| Field is computed from external   | @requires in contributor|

---

## @key Variations

### Simple Keys

The most common form — a single scalar field identifies the entity:

```graphql
type User @key(fields: "id") {
  id: ID!
  name: String!
  email: String!
}
```

The reference resolver receives `{ id: "123" }` and looks up the user.

### Composite Keys

When a single field is insufficient, use multiple top-level fields:

```graphql
type OrderItem @key(fields: "orderId itemIndex") {
  orderId: ID!
  itemIndex: Int!
  product: Product!
  quantity: Int!
}
```

The reference resolver receives `{ orderId: "abc", itemIndex: 2 }`. Both fields are required for resolution.

**When to use:** Junction tables, compound primary keys in databases, or types scoped to a parent.

### Compound (Nested) Keys

Keys can reference nested object fields:

```graphql
type Review @key(fields: "id author { id }") {
  id: ID!
  author: User!
  body: String!
  rating: Int!
}
```

The reference resolver receives `{ id: "r1", author: { id: "u1" } }`. This is useful when the identity requires context from a related entity.

**Caveats:**
- The nested type (`User`) does not need to be an entity itself in this subgraph
- Nested keys add complexity to reference resolvers
- Avoid deeply nested keys — they increase query plan complexity

### Multi-Key Entities

An entity can declare multiple `@key` directives, providing alternative lookup paths:

```graphql
type User @key(fields: "id") @key(fields: "email") @key(fields: "username") {
  id: ID!
  email: String!
  username: String!
  displayName: String
}
```

The router chooses the most efficient key based on what data is available in the query plan. This is particularly useful when different subgraphs naturally reference the entity by different identifiers.

```typescript
// Reference resolver must handle all key shapes
User: {
  __resolveReference(ref) {
    if (ref.id) return userService.getById(ref.id);
    if (ref.email) return userService.getByEmail(ref.email);
    if (ref.username) return userService.getByUsername(ref.username);
    return null;
  }
}
```

### Non-Resolvable Keys

A subgraph may define an entity stub with `resolvable: false` to reference an entity without providing a resolver:

```graphql
type User @key(fields: "id", resolvable: false) {
  id: ID!
}
```

This tells composition: "I reference this entity by key but I cannot resolve it." Use this when a subgraph needs to return an entity as a field type but doesn't own any fields on it.

---

## Value Types with @shareable

### When to Use Value Types

Value types are non-entity types that appear identically in multiple subgraphs. They have no `@key` and no identity — they're pure data containers.

```graphql
# Defined identically in multiple subgraphs
type Money @shareable {
  amount: Int!
  currency: String!
}

type PageInfo @shareable {
  hasNextPage: Boolean!
  hasPreviousPage: Boolean!
  startCursor: String
  endCursor: String
}

type GeoCoordinates @shareable {
  latitude: Float!
  longitude: Float!
}
```

### Pitfalls of Over-Sharing

- **Divergent implementations:** If subgraph A returns `amount` in cents and subgraph B in dollars, clients get inconsistent data. Shared fields must have identical semantics.
- **Composition fragility:** Adding a required field to a shared type in one subgraph breaks composition unless all subgraphs update simultaneously.
- **Recommendation:** Extract shared value types into a shared schema package or code-gen them from a single source.

---

## Computed Fields with @requires

### Basic Usage

`@requires` tells the router to fetch specified fields from their owning subgraph before calling the requiring resolver:

```graphql
# Shipping subgraph
type Product @key(fields: "upc") {
  upc: String!
  weight: Int @external
  dimensions: Dimensions @external
  shippingCost: Float! @requires(fields: "weight dimensions { width height depth }")
}
```

The resolver receives the product representation with `weight` and `dimensions` populated:

```typescript
Product: {
  shippingCost(product) {
    // product.weight and product.dimensions are available
    const volume = product.dimensions.width *
                   product.dimensions.height *
                   product.dimensions.depth;
    return calculateShipping(product.weight, volume);
  }
}
```

### Nested @requires

You can require fields from nested entities:

```graphql
type OrderItem @key(fields: "id") {
  id: ID!
  product: Product! @external
  quantity: Int!
  totalWeight: Float! @requires(fields: "product { weight }")
}
```

### Performance Implications

Every `@requires` directive adds at least one extra subgraph fetch to the query plan. Consider:

- **Batching:** The router batches multiple entity fetches to the same subgraph. A `@requires` on a list of 100 items results in a single batched request, not 100 individual ones.
- **Caching:** If the required fields are commonly queried, they may already be in the query plan — no extra fetch needed.
- **Alternatives:** If the requiring subgraph has direct access to the data (e.g., same database), consider owning the field directly instead of using `@requires`.

---

## Interface Entities

Federation v2.3+ supports interface entities with `@key`:

### Defining Interface Entities

```graphql
interface Media @key(fields: "id") {
  id: ID!
  title: String!
  url: String!
}

type Book implements Media @key(fields: "id") {
  id: ID!
  title: String!
  url: String!
  isbn: String!
  author: String!
}

type Movie implements Media @key(fields: "id") {
  id: ID!
  title: String!
  url: String!
  director: String!
  duration: Int!
}
```

### Resolving Interface Entities

The reference resolver must return concrete types with `__typename`:

```typescript
Media: {
  __resolveReference(ref) {
    const item = mediaService.getById(ref.id);
    return { ...item, __typename: item.type === 'book' ? 'Book' : 'Movie' };
  }
}
```

Another subgraph can extend the interface entity:

```graphql
interface Media @key(fields: "id") {
  id: ID!
  recommendations: [Media!]!  # contributed field on the interface
}
```

---

## Union Entities

Unions of entities allow polymorphic queries across subgraphs:

```graphql
# Search subgraph
union SearchResult = Product | User | Article

type Query {
  search(term: String!): [SearchResult!]!
}

type Product @key(fields: "upc") {
  upc: String!
}

type User @key(fields: "id") {
  id: ID!
}

type Article @key(fields: "slug") {
  slug: String!
}
```

The search resolver returns entity stubs with `__typename` and key fields. The router fetches full entity data from the owning subgraphs:

```typescript
search: (_, { term }) => {
  const results = searchIndex.query(term);
  return results.map(r => ({
    __typename: r.type,
    ...(r.type === 'Product' ? { upc: r.id } : {}),
    ...(r.type === 'User' ? { id: r.id } : {}),
    ...(r.type === 'Article' ? { slug: r.id } : {}),
  }));
}
```

---

## Subscriptions in Federation

### Router-Level Subscriptions

Apollo Router supports subscriptions via WebSocket and HTTP callback protocols. Subscriptions are resolved by a single subgraph — the router proxies the connection:

```yaml
# router.yaml
subscription:
  enabled: true
  mode:
    passthrough:
      all:
        path: /ws
      subgraphs:
        reviews:
          path: /subscriptions
```

```graphql
# Reviews subgraph
type Subscription {
  reviewAdded(productUpc: String!): Review!
}
```

### Callback-Based Subscriptions

For scalable production setups, use the callback protocol instead of persistent WebSocket connections:

```yaml
subscription:
  enabled: true
  mode:
    callback:
      public_url: https://router.example.com/callback
      listen: 0.0.0.0:4040
      path: /callback
      heartbeat_interval: 5s
```

### Limitations

- A subscription field must be fully resolvable by a single subgraph
- The subscription payload can reference entities from other subgraphs — the router will resolve them
- Subscription events cannot trigger cross-subgraph entity resolution for the subscription root type itself
- Use subscriptions sparingly — prefer webhooks or server-sent events for high-throughput event streams

---

## Error Handling Patterns

### Partial Data with Errors

Federation inherently supports partial data. If one subgraph fails, the router returns data from successful subgraphs and includes errors:

```json
{
  "data": {
    "product": {
      "name": "Widget",
      "price": 1999,
      "reviews": null
    }
  },
  "errors": [
    {
      "message": "Could not fetch reviews",
      "path": ["product", "reviews"],
      "extensions": {
        "code": "SUBREQUEST_FAILED",
        "service": "reviews"
      }
    }
  ]
}
```

Configure nullability carefully:
- `reviews: [Review!]!` — a failure nullifies the entire parent object
- `reviews: [Review!]` — reviews becomes null but the product is still returned
- For resilience, prefer nullable fields for cross-subgraph references

### Error Propagation Across Subgraphs

Subgraph errors are propagated to clients with service metadata. Standardize error codes:

```typescript
throw new GraphQLError('Product not found', {
  extensions: {
    code: 'PRODUCT_NOT_FOUND',
    http: { status: 404 },
  },
});
```

### Result Union Pattern

For expected error states, use union types instead of throwing:

```graphql
type Query {
  product(upc: String!): ProductResult!
}

union ProductResult = Product | ProductNotFound | ProductUnavailable

type ProductNotFound {
  upc: String!
  message: String!
}

type ProductUnavailable {
  upc: String!
  availableAt: DateTime
}
```

This makes errors part of the schema contract and avoids reliance on error extensions.

---

## N+1 Problem in Resolvers

### The Problem

Without batching, entity resolution triggers one database query per entity reference:

```
Query: { topProducts }         → 1 query → [P1, P2, P3, ..., P50]
Product.__resolveReference(P1) → 1 query
Product.__resolveReference(P2) → 1 query
...                            → 50 queries total for a single list!
```

### DataLoader Solution

DataLoader batches and deduplicates within a single tick of the event loop:

```typescript
import DataLoader from 'dataloader';

function createLoaders() {
  return {
    productByUpc: new DataLoader<string, Product>(async (upcs) => {
      const products = await db.products.findMany({
        where: { upc: { in: [...upcs] } },
      });
      const productMap = new Map(products.map(p => [p.upc, p]));
      // MUST return in same order as input keys
      return upcs.map(upc => productMap.get(upc) || new Error(`Product ${upc} not found`));
    }),
  };
}
```

### Batch Entity Resolution

Apollo Server 4 supports batch reference resolvers natively:

```typescript
Product: {
  async __resolveReference(representations) {
    // representations is an array when batching is enabled
    const upcs = representations.map(r => r.upc);
    const products = await productService.getByUpcs(upcs);
    const productMap = new Map(products.map(p => [p.upc, p]));
    return representations.map(r => productMap.get(r.upc) ?? null);
  }
}
```

Enable in subgraph setup:

```typescript
const server = new ApolloServer({
  schema: buildSubgraphSchema({ typeDefs, resolvers }),
  allowBatchedHttpRequests: true,
});
```

### Per-Request DataLoader Scoping

DataLoaders must be scoped per request to avoid cache leaks across users:

```typescript
const server = new ApolloServer({
  schema: buildSubgraphSchema({ typeDefs, resolvers }),
});

app.use('/graphql', expressMiddleware(server, {
  context: async ({ req }) => ({
    userId: req.headers['x-user-id'],
    loaders: createLoaders(), // fresh loaders per request
  }),
}));
```

---

## Pagination Across Subgraphs

### Cursor-Based Pagination

Follow the Relay Connection specification for consistent pagination:

```graphql
type Query {
  products(first: Int, after: String, last: Int, before: String): ProductConnection!
}

type ProductConnection {
  edges: [ProductEdge!]!
  pageInfo: PageInfo!
  totalCount: Int
}

type ProductEdge {
  node: Product!
  cursor: String!
}

type PageInfo @shareable {
  hasNextPage: Boolean!
  hasPreviousPage: Boolean!
  startCursor: String
  endCursor: String
}
```

### Cross-Subgraph Pagination Challenges

- **Cannot paginate across subgraph boundaries:** If products are in subgraph A and reviews are in subgraph B, you cannot page through "all reviews for all products" as a unified list.
- **Sort order conflicts:** Sorting by a field owned by one subgraph while paginating a list from another requires all data in one place.
- **Total counts:** Each subgraph can only count its own data.

### Recommended Patterns

1. **Keep paginated lists in one subgraph:** The subgraph owning the list handles pagination end-to-end.
2. **Entity fields are not paginated across boundaries:** Cross-subgraph entity resolution enriches individual items but doesn't control list pagination.
3. **Search/aggregation subgraph:** For cross-domain pagination (e.g., unified search), create a dedicated subgraph backed by an index (Elasticsearch, Algolia) that returns entity stubs.

```graphql
# Search subgraph
type Query {
  search(term: String!, first: Int, after: String): SearchConnection!
}

type SearchConnection {
  edges: [SearchEdge!]!
  pageInfo: PageInfo!
}

type SearchEdge {
  node: SearchResult!
  cursor: String!
  score: Float!
}

union SearchResult = Product | Article | User
```

The search subgraph returns entity references; the router resolves full data from owning subgraphs.
