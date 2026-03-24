# Migration Guide — Apollo Federation v2

## Table of Contents

- [From Monolithic GraphQL](#from-monolithic-graphql)
  - [Assessment Phase](#assessment-phase)
  - [Step 1: Deploy Router in Front of Monolith](#step-1-deploy-router-in-front-of-monolith)
  - [Step 2: Annotate Entities](#step-2-annotate-entities)
  - [Step 3: Extract First Subgraph](#step-3-extract-first-subgraph)
  - [Step 4: Iterate and Decompose](#step-4-iterate-and-decompose)
- [From Schema Stitching](#from-schema-stitching)
  - [Key Differences](#key-differences)
  - [Migration Steps](#migration-steps)
  - [Handling Stitching-Specific Patterns](#handling-stitching-specific-patterns)
- [Incremental Migration with @override](#incremental-migration-with-override)
  - [Basic @override](#basic-override)
  - [Progressive @override with Labels](#progressive-override-with-labels)
  - [Rollback with @override](#rollback-with-override)
  - [Monitoring During Migration](#monitoring-during-migration)
- [Splitting a Monolith into Subgraphs](#splitting-a-monolith-into-subgraphs)
  - [Identifying Domain Boundaries](#identifying-domain-boundaries)
  - [Extraction Order Strategy](#extraction-order-strategy)
  - [Shared Code and Utilities](#shared-code-and-utilities)
  - [Database Considerations](#database-considerations)
- [Data Migration Strategies](#data-migration-strategies)
  - [Shared Database (Phase 1)](#shared-database-phase-1)
  - [Database-per-Subgraph (Phase 2)](#database-per-subgraph-phase-2)
  - [Data Synchronization](#data-synchronization)
  - [Handling Foreign Keys](#handling-foreign-keys)
- [Client Migration](#client-migration)
  - [Why Clients Don't Change](#why-clients-dont-change)
  - [Endpoint Migration](#endpoint-migration)
  - [Subscription Migration](#subscription-migration)
  - [Client-Side Considerations](#client-side-considerations)
- [Testing Federated Schemas](#testing-federated-schemas)
  - [Unit Testing Subgraphs](#unit-testing-subgraphs)
  - [Composition Testing](#composition-testing)
  - [Integration Testing](#integration-testing)
  - [Contract Testing](#contract-testing)
  - [End-to-End Testing](#end-to-end-testing)
- [Rollback Strategies](#rollback-strategies)
  - [Subgraph Rollback](#subgraph-rollback)
  - [Router Rollback](#router-rollback)
  - [Full Rollback to Monolith](#full-rollback-to-monolith)
  - [Feature Flags with @override](#feature-flags-with-override)

---

## From Monolithic GraphQL

### Assessment Phase

Before migrating, evaluate your current state:

**Schema analysis:**

```bash
# Count types, fields, and resolvers in your monolith
grep -c "^type " schema.graphql
grep -c "^\s\+\w\+[:(]" schema.graphql

# Identify entity candidates — types with unique IDs
grep -B1 "id: ID" schema.graphql
```

**Questions to answer:**
1. How many types and fields does your schema have?
2. Which types are queried together most often?
3. Which teams own which parts of the schema?
4. What are the natural domain boundaries?
5. Which fields have cross-domain dependencies?

**Migration readiness checklist:**
- [ ] Schema is documented
- [ ] Resolvers have clear data source boundaries
- [ ] CI/CD pipeline exists for the monolith
- [ ] Monitoring and observability are in place
- [ ] Team is familiar with federation concepts

### Step 1: Deploy Router in Front of Monolith

The safest first step is zero-behavior-change: put the router in front of your existing monolith.

**1. Convert monolith to a subgraph:**

Add federation directives to your schema:

```graphql
extend schema
  @link(url: "https://specs.apollo.dev/federation/v2.7",
    import: ["@key", "@shareable"])

type Product @key(fields: "id") {
  id: ID!
  name: String!
  # ... existing fields
}
```

Update your server setup (Apollo Server example):

```typescript
import { buildSubgraphSchema } from '@apollo/subgraph';

const server = new ApolloServer({
  schema: buildSubgraphSchema({ typeDefs, resolvers }),
});
```

**2. Compose a supergraph:**

```yaml
# supergraph.yaml
federation_version: =2.7.1
subgraphs:
  monolith:
    routing_url: http://monolith:4000/graphql
    schema:
      file: ./monolith-schema.graphql
```

```bash
rover supergraph compose --config supergraph.yaml --output supergraph.graphql
```

**3. Deploy the router:**

```bash
router --config router.yaml --supergraph supergraph.graphql
```

**4. Switch client traffic:**

Point clients to the router endpoint. The behavior is identical — the router forwards everything to the monolith.

### Step 2: Annotate Entities

Identify domain entities and annotate them with `@key`:

```graphql
type User @key(fields: "id") { id: ID!; name: String!; email: String! }
type Product @key(fields: "id") { id: ID!; name: String!; price: Int! }
type Order @key(fields: "id") { id: ID!; total: Int!; user: User! }
type Review @key(fields: "id") { id: ID!; body: String!; product: Product! }
```

Add `__resolveReference` for each entity (in the monolith, these are often trivial):

```typescript
User: {
  __resolveReference(ref) {
    return dataSources.users.getById(ref.id);
  }
}
```

Re-compose and deploy. Still zero behavior change for clients.

### Step 3: Extract First Subgraph

Choose the simplest, most independent domain for the first extraction. Reviews or recommendations are often good candidates.

**1. Create the new subgraph:**

```graphql
# reviews subgraph schema
extend schema
  @link(url: "https://specs.apollo.dev/federation/v2.7",
    import: ["@key", "@external"])

type Review @key(fields: "id") {
  id: ID!
  body: String!
  rating: Int!
  product: Product!
  author: User!
}

type Product @key(fields: "id") {
  id: ID!
  reviews: [Review!]!
  averageRating: Float
}

type User @key(fields: "id") {
  id: ID!
  reviews: [Review!]!
}
```

**2. Implement resolvers and reference resolvers.**

**3. Remove review fields from the monolith.**

**4. Update supergraph config:**

```yaml
subgraphs:
  monolith:
    routing_url: http://monolith:4000/graphql
    schema:
      file: ./monolith-schema.graphql
  reviews:
    routing_url: http://reviews:4002/graphql
    schema:
      file: ./reviews-schema.graphql
```

**5. Compose, test, deploy.**

### Step 4: Iterate and Decompose

Repeat Step 3 for each domain. As the monolith shrinks, extraction becomes easier because remaining types have fewer cross-domain dependencies.

**Typical extraction order:**
1. Reviews/ratings (few dependencies)
2. Search/recommendations (read-only, isolated)
3. Inventory (isolated data source)
4. Users/accounts (widely referenced but stable)
5. Orders (complex, extract last)

---

## From Schema Stitching

### Key Differences

| Aspect | Schema Stitching | Apollo Federation |
|--------|-----------------|-------------------|
| Schema merging | Gateway-defined transforms | Declarative directives in subgraphs |
| Type merging | Manual `merge` config | Automatic via @key |
| Delegation | Explicit `delegateToSchema` | Automatic via query planning |
| Ownership | Gateway knows everything | Subgraphs are self-describing |
| Tooling | Custom gateway code | Rover CLI, GraphOS, Apollo Router |

### Migration Steps

**1. Identify stitched types and their merge configurations.**

```javascript
// Old stitching config
const stitchedSchema = stitchSchemas({
  subschemas: [
    { schema: productsSchema, merge: {
      Product: { selectionSet: '{ id }', fieldName: 'product', args: ({ id }) => ({ id }) }
    }},
    { schema: reviewsSchema, merge: {
      Product: { selectionSet: '{ id }', fieldName: '_productReviews', args: ({ id }) => ({ id }) }
    }},
  ],
});
```

**2. Convert merge configs to federation directives:**

Each `merge.Type.selectionSet` becomes `@key(fields: ...)`. Each merged type gets `__resolveReference` instead of gateway delegation.

**3. Replace gateway with Apollo Router.**

**4. Incrementally migrate one stitched service at a time.**

### Handling Stitching-Specific Patterns

**Type merging → @key + @external:**

```graphql
# Before (stitching gateway config)
Product: { selectionSet: '{ id }', fieldName: 'product' }

# After (federation directive in subgraph)
type Product @key(fields: "id") { id: ID!; ... }
```

**Schema transforms → @inaccessible or custom router plugins:**

If stitching used transforms to rename or filter fields, use `@inaccessible` for hiding or router Rhai scripts for transforms.

**Delegated queries → reference resolvers:**

```typescript
// Before: delegateToSchema({ schema: productsSchema, operation: 'query', fieldName: 'product' })
// After: standard __resolveReference
Product: {
  __resolveReference(ref, ctx) {
    return ctx.dataSources.products.getById(ref.id);
  }
}
```

---

## Incremental Migration with @override

### Basic @override

`@override` transfers field ownership from one subgraph to another without client changes:

```graphql
# New "catalog" subgraph takes over "name" from "monolith"
type Product @key(fields: "id") {
  id: ID!
  name: String! @override(from: "monolith")
}
```

Once deployed:
1. The router sends `name` queries to the new subgraph instead of the monolith
2. The monolith's `name` resolver is no longer called
3. No client changes needed

### Progressive @override with Labels

Roll out ownership gradually using percentage-based labels:

```graphql
type Product @key(fields: "id") {
  id: ID!
  name: String! @override(from: "monolith", label: "percent(5)")
}
```

**Ramp-up schedule:**

```
Week 1: percent(5)   — 5% of traffic to new subgraph
Week 2: percent(25)  — 25% of traffic
Week 3: percent(50)  — 50% of traffic
Week 4: percent(90)  — 90% of traffic
Week 5: percent(100) — fully migrated, remove @override
```

Each change requires a schema publish and supergraph recomposition.

### Rollback with @override

If the new subgraph has issues, instantly roll back by:

1. Reducing the percentage: `percent(0)` sends all traffic back to the original
2. Removing the `@override` directive entirely
3. Republishing the schema

No code changes needed in either subgraph — the router handles the routing.

### Monitoring During Migration

Track these metrics during progressive rollout:

- **Error rate:** Compare error rates between old and new subgraph for the migrated field
- **Latency:** p50, p95, p99 for the field in both subgraphs
- **Data consistency:** Sample responses from both subgraphs and compare
- **Cache hit rate:** Ensure the new subgraph's caching is effective

```yaml
# router.yaml — enable per-subgraph metrics
telemetry:
  exporters:
    metrics:
      prometheus:
        enabled: true
        listen: 0.0.0.0:9090
        path: /metrics
  instrumentation:
    instruments:
      default_requirement_level: info
```

---

## Splitting a Monolith into Subgraphs

### Identifying Domain Boundaries

Use Domain-Driven Design to find natural subgraph boundaries:

**1. List all types and group by domain:**

| Domain | Types | Team |
|--------|-------|------|
| Catalog | Product, Category, Brand | Catalog team |
| Users | User, Account, Profile, Address | Identity team |
| Orders | Order, OrderItem, Payment | Commerce team |
| Reviews | Review, Rating, Comment | Engagement team |
| Inventory | Stock, Warehouse, Shipment | Logistics team |

**2. Identify cross-domain references:**

```
Product ← referenced by → Order, Review, Stock
User ← referenced by → Order, Review, Account
```

These become entity boundaries with `@key`.

**3. Minimize cross-subgraph dependencies:**

If two types are always queried together and owned by the same team, keep them in the same subgraph. Don't split for the sake of splitting.

### Extraction Order Strategy

**Extract by independence, not importance:**

```
Most Independent ──────────────────────────── Most Connected
Reviews → Search → Inventory → Users → Orders → Core/Monolith
```

**Rules of thumb:**
- Start with types that have few incoming references
- Defer types that are referenced by many other types (e.g., User)
- Extract read-heavy domains before write-heavy ones
- Keep transactional boundaries in the same subgraph

### Shared Code and Utilities

**Problem:** The monolith has shared utilities (date formatting, error handling, auth middleware) used by all resolvers.

**Solutions:**
1. **Shared npm/pip package:** Extract utilities into a library consumed by all subgraphs
2. **Copy and evolve:** Initially duplicate utilities; refactor later
3. **Sidecar services:** For complex shared logic (e.g., auth), create a shared service

```
# Project structure after extraction
packages/
  shared-utils/         # shared library
  subgraph-products/    # depends on shared-utils
  subgraph-reviews/     # depends on shared-utils
  subgraph-users/       # depends on shared-utils
```

### Database Considerations

**Phase 1 — Shared database:**

All subgraphs read from the same database. This is the simplest starting point:

```
[Router] → [Products Subgraph] → [Shared DB]
         → [Reviews Subgraph]  → [Shared DB]
         → [Users Subgraph]    → [Shared DB]
```

**Phase 2 — Separate schemas:**

Each subgraph gets its own database schema. Cross-references use IDs only:

```
[Products Subgraph] → [products schema]
[Reviews Subgraph]  → [reviews schema]
[Users Subgraph]    → [users schema]
```

**Phase 3 — Separate databases:**

Full isolation. Each subgraph owns its data entirely:

```
[Products Subgraph] → [Products DB (PostgreSQL)]
[Reviews Subgraph]  → [Reviews DB (MongoDB)]
[Users Subgraph]    → [Users DB (PostgreSQL)]
```

---

## Data Migration Strategies

### Shared Database (Phase 1)

Start here. All subgraphs connect to the same database. This eliminates data migration as a blocker.

**Risks:**
- Schema coupling — changes to tables affect multiple subgraphs
- Permission confusion — which subgraph "owns" which tables?
- Performance — shared connection pool contention

**Mitigation:** Use read-only connections for non-owning subgraphs. The owning subgraph has read-write access.

### Database-per-Subgraph (Phase 2)

Migrate data ownership when subgraph boundaries are stable:

**1. Create the new database and replicate data:**

```sql
-- In the new reviews database
CREATE TABLE reviews AS SELECT * FROM monolith_db.reviews;
CREATE TABLE ratings AS SELECT * FROM monolith_db.ratings;
```

**2. Set up Change Data Capture (CDC) for sync:**

Use Debezium, DMS, or application-level dual-writes to keep databases in sync during the transition.

**3. Switch the subgraph to the new database.**

**4. Verify consistency and remove the old tables.**

### Data Synchronization

For cross-subgraph data needs, use event-driven sync:

```
[Orders Subgraph] --order.created--> [Message Bus] ---> [Inventory Subgraph]
                  --order.shipped--> [Message Bus] ---> [Notifications Subgraph]
```

**Patterns:**
- **Event sourcing:** Subgraphs publish domain events; others consume and project
- **CDC:** Database changes are streamed to consumers via Kafka/Debezium
- **API calls:** Subgraph-to-subgraph REST/gRPC calls (avoid for tight coupling)

### Handling Foreign Keys

In a monolith, `reviews.product_id` is a foreign key to `products.id`. After splitting:

**The reviews subgraph stores `product_id` but doesn't join to the products table.** Instead, it returns a Product entity stub:

```typescript
// Reviews subgraph resolver
Review: {
  product(review) {
    // Return entity reference — router resolves full Product from Products subgraph
    return { __typename: 'Product', id: review.productId };
  }
}
```

No foreign key constraint exists across databases. Data consistency is maintained through:
- Application-level validation
- Event-driven synchronization
- Eventual consistency acceptance

---

## Client Migration

### Why Clients Don't Change

Federation is transparent to clients. The supergraph presents a unified schema:

```graphql
# Client query — works identically before and after federation
query {
  product(id: "1") {
    name           # from products subgraph
    price          # from products subgraph
    reviews {      # from reviews subgraph
      body
      author {     # from users subgraph
        name
      }
    }
    inStock        # from inventory subgraph
  }
}
```

The client sends this to one endpoint (the router). It has no knowledge of subgraphs.

### Endpoint Migration

The only client change is updating the GraphQL endpoint URL:

```typescript
// Before
const client = new ApolloClient({
  uri: 'https://api.example.com/graphql',  // monolith
});

// After
const client = new ApolloClient({
  uri: 'https://gateway.example.com/graphql',  // router
});
```

**Zero-downtime approach:**
1. Deploy the router behind the same URL (using a load balancer or DNS switch)
2. Or configure the monolith as a reverse proxy to the router during transition

### Subscription Migration

Subscriptions require additional client configuration to connect via the router:

```typescript
import { GraphQLWsLink } from '@apollo/client/link/subscriptions';
import { createClient } from 'graphql-ws';

const wsLink = new GraphQLWsLink(createClient({
  url: 'wss://gateway.example.com/ws',  // router WebSocket endpoint
}));
```

Ensure the router has subscription support enabled in `router.yaml`.

### Client-Side Considerations

- **Caching:** Client-side cache keys don't change. `Product:1` is still `Product:1`.
- **Error shape:** Error extensions may include new fields (`service`, `extensions.code`). Clients should handle unknown extensions gracefully.
- **Performance:** Initial requests may be slightly slower (query planning overhead). Subsequent requests benefit from plan caching.
- **Persisted queries:** If using APQ (Automatic Persisted Queries), the router supports them natively. No client changes.

---

## Testing Federated Schemas

### Unit Testing Subgraphs

Test each subgraph in isolation using its own schema:

```typescript
import { ApolloServer } from '@apollo/server';
import { buildSubgraphSchema } from '@apollo/subgraph';

describe('Products Subgraph', () => {
  let server: ApolloServer;

  beforeAll(() => {
    server = new ApolloServer({
      schema: buildSubgraphSchema({ typeDefs, resolvers }),
    });
  });

  it('resolves product by UPC', async () => {
    const result = await server.executeOperation({
      query: '{ product(upc: "1") { name price } }',
    });
    expect(result.body.singleResult.data.product.name).toBe('Widget');
  });

  it('resolves __resolveReference', async () => {
    const result = await server.executeOperation({
      query: '{ _entities(representations: [{ __typename: "Product", upc: "1" }]) { ... on Product { name } } }',
    });
    expect(result.body.singleResult.data._entities[0].name).toBe('Widget');
  });
});
```

### Composition Testing

Validate that subgraph schemas compose successfully:

```bash
# In CI — fail the build if composition fails
rover supergraph compose --config supergraph.yaml --output /dev/null

# Or use rover subgraph check against the registry
rover subgraph check my-graph@staging \
  --name products \
  --schema ./products-schema.graphql
```

**Automate in CI:**

```yaml
# .github/workflows/federation-check.yml
name: Federation Check
on: pull_request

jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install Rover
        run: curl -sSL https://rover.apollo.dev/nix/latest | sh
      - name: Compose supergraph
        run: rover supergraph compose --config supergraph.yaml --output /dev/null
      - name: Check subgraph
        run: rover subgraph check $APOLLO_GRAPH_REF --name $SUBGRAPH_NAME --schema ./schema.graphql
        env:
          APOLLO_KEY: ${{ secrets.APOLLO_KEY }}
```

### Integration Testing

Test cross-subgraph queries against a local federation stack:

```typescript
describe('Federation Integration', () => {
  // Start all subgraphs + router before tests
  // Use docker-compose or programmatic setup

  it('resolves cross-subgraph query', async () => {
    const response = await fetch('http://localhost:4000/graphql', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        query: `{
          product(upc: "1") {
            name
            reviews { body author { name } }
          }
        }`,
      }),
    });
    const { data } = await response.json();
    expect(data.product.name).toBeDefined();
    expect(data.product.reviews).toBeInstanceOf(Array);
  });
});
```

### Contract Testing

Ensure subgraphs fulfill their schema contracts using consumer-driven contract testing:

1. **Producer tests:** Each subgraph verifies it implements its published schema
2. **Consumer tests:** Client teams verify their queries work against the composed supergraph
3. **Pact or similar:** Record expected interactions and replay against subgraphs

### End-to-End Testing

Run E2E tests against the full federation stack in a staging environment:

```bash
# Start the full stack
docker compose -f docker-compose.federation.yml up -d

# Wait for health
until curl -sf http://localhost:4000/health; do sleep 2; done

# Run E2E test suite
npm run test:e2e

# Tear down
docker compose -f docker-compose.federation.yml down
```

---

## Rollback Strategies

### Subgraph Rollback

If a subgraph deployment causes issues:

**1. Redeploy the previous version of the subgraph service.**

```bash
# Kubernetes
kubectl rollout undo deployment/products-subgraph

# Docker Compose
docker compose up -d products --force-recreate  # with previous image tag
```

**2. Republish the previous schema to GraphOS:**

```bash
# If the schema changed
rover subgraph publish my-graph@prod \
  --name products \
  --schema ./previous-products-schema.graphql \
  --routing-url http://products:4001/graphql
```

**3. Verify composition succeeds and router picks up the new supergraph.**

### Router Rollback

If the router itself is the problem:

```bash
# Roll back to previous router version
docker pull ghcr.io/apollographql/router:v1.previous
docker compose up -d router --force-recreate
```

Or revert router configuration:

```bash
git checkout HEAD~1 -- router.yaml
# Restart router with previous config
```

### Full Rollback to Monolith

If federation must be fully reverted:

1. **Point clients back to the monolith endpoint** (DNS switch or load balancer change)
2. **Remove @override directives** from new subgraphs so the monolith resolves all fields
3. **Republish the monolith schema** with all fields restored
4. **Recompose** — the monolith becomes the sole subgraph again
5. **Decommission** the router and extracted subgraphs

**This is why Step 1 (router in front of monolith) is critical** — the monolith still works as a standalone service.

### Feature Flags with @override

Use progressive `@override` as a built-in feature flag:

```graphql
# 0% — all traffic to monolith (effectively disabled)
name: String! @override(from: "monolith", label: "percent(0)")

# Emergency rollback — set to 0% and republish
# Normal operation — gradually increase to 100%
# Full migration — remove @override (new subgraph fully owns the field)
```

This provides the safest migration path: field-by-field, percentage-by-percentage, with instant rollback.
