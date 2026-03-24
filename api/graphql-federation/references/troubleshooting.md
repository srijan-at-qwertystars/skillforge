# Troubleshooting — Apollo Federation v2

## Table of Contents

- [Composition Errors](#composition-errors)
  - [Conflicting Type Definitions](#conflicting-type-definitions)
  - [Missing @key Directive](#missing-key-directive)
  - [Inconsistent Nullability](#inconsistent-nullability)
  - [Invalid @requires References](#invalid-requires-references)
  - [@shareable Violations](#shareable-violations)
  - [Enum and Input Type Conflicts](#enum-and-input-type-conflicts)
- [Router Errors](#router-errors)
  - [Router Fails to Start](#router-fails-to-start)
  - [Query Planning Failures](#query-planning-failures)
  - [Query Plan Performance](#query-plan-performance)
  - [Router OOM or High Memory Usage](#router-oom-or-high-memory-usage)
- [Subgraph Unreachable](#subgraph-unreachable)
  - [Connection Refused / Timeout](#connection-refused--timeout)
  - [Health Check Failures](#health-check-failures)
  - [DNS Resolution Issues](#dns-resolution-issues)
  - [TLS/SSL Errors](#tlsssl-errors)
- [Entity Resolution Failures](#entity-resolution-failures)
  - [Missing __resolveReference](#missing-__resolvereference)
  - [Null Entity Resolution](#null-entity-resolution)
  - [Type Mismatch in Representation](#type-mismatch-in-representation)
  - [Batch Resolution Errors](#batch-resolution-errors)
- [Circular Dependencies](#circular-dependencies)
  - [Detecting Cycles](#detecting-cycles)
  - [Breaking Circular Dependencies](#breaking-circular-dependencies)
- [Schema Check Failures](#schema-check-failures)
  - [Breaking Changes Detected](#breaking-changes-detected)
  - [Non-Breaking vs Breaking Changes](#non-breaking-vs-breaking-changes)
  - [Operation Check Failures](#operation-check-failures)
- [Supergraph Drift](#supergraph-drift)
  - [Symptoms](#symptoms)
  - [Diagnosis](#diagnosis)
  - [Resolution](#resolution)
- [CORS with Router](#cors-with-router)
  - [Preflight Request Failures](#preflight-request-failures)
  - [Configuration](#configuration)
  - [Common Mistakes](#common-mistakes)
- [Performance Issues](#performance-issues)
  - [Slow Query Plans](#slow-query-plans)
  - [N+1 Queries in Subgraphs](#n1-queries-in-subgraphs)
  - [Large Response Assembly](#large-response-assembly)
- [Debugging Techniques](#debugging-techniques)
  - [Query Plan Inspection](#query-plan-inspection)
  - [Router Logging](#router-logging)
  - [Subgraph Tracing](#subgraph-tracing)

---

## Composition Errors

Composition errors occur when `rover supergraph compose` or GraphOS fails to merge subgraph schemas into a valid supergraph.

### Conflicting Type Definitions

**Error:** `FIELD_TYPE_MISMATCH` — Field "X.y" has type "String" in subgraph "A" but type "Int" in subgraph "B"

**Cause:** Two subgraphs define the same field on the same type with different return types.

**Fix:**

```graphql
# WRONG — subgraph A
type Product @key(fields: "upc") {
  upc: String!
  price: Int!     # conflict
}

# WRONG — subgraph B
type Product @key(fields: "upc") {
  upc: String!
  price: Float!   # conflict
}

# FIX — align types across all subgraphs
type Product @key(fields: "upc") {
  upc: String!
  price: Float!   # same type everywhere
}
```

If both subgraphs legitimately resolve the field, both must use `@shareable` and return the same type.

### Missing @key Directive

**Error:** `KEY_MISSING_ON_BASE` — Type "Product" is an entity in subgraph "A" but is missing @key in subgraph "B"

**Cause:** A subgraph references entity fields but doesn't declare `@key`.

**Fix:** Add `@key` to every subgraph that contributes fields to an entity:

```graphql
# Subgraph B must include @key
type Product @key(fields: "upc") {
  upc: String!
  reviews: [Review!]!
}
```

### Inconsistent Nullability

**Error:** `FIELD_NULLABILITY_MISMATCH` — Field "User.email" is non-nullable in subgraph "A" but nullable in subgraph "B"

**Cause:** One subgraph defines `email: String!` and another defines `email: String`.

**Fix:** Align nullability. The composed supergraph uses the **most restrictive** definition. If any subgraph marks it nullable, clients may receive null.

**Best practice:** Agree on nullability contracts in a shared schema definition.

### Invalid @requires References

**Error:** `REQUIRES_INVALID_FIELD` — @requires references field "weight" which does not exist in any subgraph

**Cause:** The `@external` field referenced in `@requires` doesn't exist in the owning subgraph.

**Fix:**

1. Verify the field exists in the owning subgraph
2. Ensure the field name and type match exactly
3. Declare the field as `@external` in the requiring subgraph

```graphql
# Owning subgraph must have:
type Product @key(fields: "upc") {
  upc: String!
  weight: Int!   # must exist here
}

# Requiring subgraph:
type Product @key(fields: "upc") {
  upc: String!
  weight: Int @external           # matches owner's field
  shippingCost: Float @requires(fields: "weight")
}
```

### @shareable Violations

**Error:** `FIELD_NOT_SHAREABLE` — Field "Product.name" is defined in multiple subgraphs but is not marked @shareable

**Cause:** Multiple subgraphs resolve the same field without declaring it as shareable.

**Fix:** Either:
1. Mark the field `@shareable` in all subgraphs that define it
2. Remove the field from all but the owning subgraph
3. Use `@override` if migrating ownership

### Enum and Input Type Conflicts

**Error:** `ENUM_VALUE_MISMATCH` — Enum "OrderStatus" has different values across subgraphs

**Cause:** Subgraphs define the same enum with different values.

**Fix:** Enums must be **identical** across subgraphs or defined in only one subgraph. If different subgraphs need different values, compose a superset using `@inaccessible` for internal-only values:

```graphql
enum OrderStatus {
  PENDING
  PROCESSING
  SHIPPED
  DELIVERED
  INTERNAL_REVIEW @inaccessible  # only used by this subgraph
}
```

---

## Router Errors

### Router Fails to Start

**Symptoms:** Router exits immediately with an error.

**Common causes and fixes:**

| Error | Cause | Fix |
|-------|-------|-----|
| `invalid supergraph schema` | Corrupted or v1 supergraph | Re-compose with matching Rover version |
| `address already in use` | Port conflict | Change `supergraph.listen` port |
| `APOLLO_KEY not set` | Managed federation without credentials | Set `APOLLO_KEY` and `APOLLO_GRAPH_REF` env vars |
| `failed to parse config` | Invalid router.yaml | Validate YAML syntax and schema |

**Debug:** Run with verbose logging:

```bash
APOLLO_ROUTER_LOG=debug router --config router.yaml --supergraph supergraph.graphql
```

### Query Planning Failures

**Error:** `QUERY_PLANNING_FAILED` — Could not plan query

**Causes:**
- Entity has no valid resolution path (missing `@key` or `__resolveReference`)
- Circular `@requires` dependencies
- Ambiguous field ownership without `@shareable`

**Debug:** Enable query plan logging:

```yaml
# router.yaml
supergraph:
  query_planning:
    experimental_log_on_plan_failure: true
plugins:
  experimental.expose_query_plan: true
```

Request the query plan:

```bash
curl -H "Apollo-Query-Plan-Experimental: true" \
  -H "Content-Type: application/json" \
  -d '{"query":"{ product(upc:\"1\") { name reviews { body } } }"}' \
  http://localhost:4000/graphql
```

### Query Plan Performance

**Symptoms:** First requests to new queries are slow (seconds). Subsequent requests are fast.

**Cause:** Query plan computation is expensive for complex schemas. Plans are cached in memory.

**Fixes:**
1. **Warm the cache:** Send common queries at startup
2. **Increase plan cache size:**
   ```yaml
   supergraph:
     query_planning:
       cache:
         in_memory:
           limit: 1000  # default is 100
   ```
3. **Simplify schema:** Reduce cross-subgraph entity chains. Flatten deeply nested relationships.

### Router OOM or High Memory Usage

**Causes:**
- Large query plan cache
- Large supergraph schema (100+ types, deep nesting)
- Many concurrent in-flight requests

**Fixes:**
1. Reduce query plan cache size
2. Set request size limits:
   ```yaml
   limits:
     http_max_request_bytes: 2000000  # 2MB
     max_depth: 15
     max_height: 200
   ```
3. Enable request deduplication to reduce concurrent subgraph requests

---

## Subgraph Unreachable

### Connection Refused / Timeout

**Error:** `SUBREQUEST_HTTP_ERROR` — Connection refused to subgraph "products"

**Checklist:**
1. Is the subgraph running? `curl http://products:4001/graphql`
2. Is the `routing_url` correct in the supergraph config?
3. Can the router reach the subgraph network? (Docker networking, Kubernetes service names)
4. Is there a firewall or security group blocking the connection?

**Quick test:**

```bash
# From inside the router container
curl -X POST -H "Content-Type: application/json" \
  -d '{"query":"{ __typename }"}' \
  http://products:4001/graphql
```

### Health Check Failures

**Error:** Router marks subgraph as unhealthy.

Configure health checks:

```yaml
health_check:
  listen: 0.0.0.0:8088
  enabled: true
  path: /health
```

The router's `/health` endpoint returns 200 only when all subgraphs are reachable. For individual subgraph health:

```bash
# Check each subgraph individually
for sg in products:4001 reviews:4002 users:4003; do
  echo -n "$sg: "
  curl -sf -X POST -H "Content-Type: application/json" \
    -d '{"query":"{ __typename }"}' \
    "http://$sg/graphql" && echo "OK" || echo "FAIL"
done
```

### DNS Resolution Issues

**Symptoms:** `SUBREQUEST_HTTP_ERROR` with "dns error" in router logs.

**In Docker Compose:** Use service names matching the `docker-compose.yml` service definitions.

**In Kubernetes:** Use fully qualified service names: `http://products.default.svc.cluster.local:4001/graphql`

### TLS/SSL Errors

**Error:** `certificate verify failed` or `ssl handshake error`

**Fixes:**
1. Use correct scheme (`https://` vs `http://`)
2. For internal services with self-signed certs:
   ```yaml
   tls:
     subgraph:
       all:
         certificate_authorities: /etc/ssl/certs/internal-ca.pem
   ```

---

## Entity Resolution Failures

### Missing __resolveReference

**Symptoms:** Runtime error: "Could not resolve entity of type Product." Composition succeeds but queries fail.

**Cause:** A subgraph declares `@key` on a type but doesn't implement `__resolveReference`.

**Fix:**

```typescript
const resolvers = {
  Product: {
    __resolveReference(ref: { upc: string }, ctx) {
      return ctx.dataSources.products.getByUpc(ref.upc);
    },
  },
};
```

**Note:** Subgraphs using `@key(fields: "id", resolvable: false)` do not need a reference resolver.

### Null Entity Resolution

**Symptoms:** Fields from a contributing subgraph return `null` unexpectedly.

**Causes:**
1. `__resolveReference` returns `null` — the entity doesn't exist in this subgraph's data source
2. Key field mismatch — the representation has a different key field name/type than expected
3. Data consistency — the entity exists in subgraph A but not in subgraph B

**Debug:**

```typescript
__resolveReference(ref, ctx) {
  console.log('Resolving Product with ref:', JSON.stringify(ref));
  const result = ctx.dataSources.products.getByUpc(ref.upc);
  if (!result) console.warn(`Product not found: ${ref.upc}`);
  return result;
}
```

### Type Mismatch in Representation

**Symptoms:** `__resolveReference` receives unexpected field types.

**Example:** Key field `id` is `ID!` (string) in schema but the resolver expects a number.

```typescript
// WRONG — id comes as string from the router
__resolveReference(ref) {
  return db.products.findById(ref.id); // ref.id is "123" (string), not 123 (number)
}

// FIX — parse the key field
__resolveReference(ref) {
  return db.products.findById(parseInt(ref.id, 10));
}
```

### Batch Resolution Errors

**Symptoms:** Some entities in a batch resolve to wrong items or null.

**Cause:** Batch resolver doesn't return results in the same order as input.

**Fix:** Always map results back to input order:

```typescript
async __resolveReference(representations) {
  const ids = representations.map(r => r.id);
  const results = await db.findByIds(ids);
  const resultMap = new Map(results.map(r => [r.id, r]));
  // MUST return in same order as input
  return representations.map(r => resultMap.get(r.id) ?? null);
}
```

---

## Circular Dependencies

### Detecting Cycles

**Symptoms:**
- Infinite query plan generation
- Stack overflow in composition
- Extremely slow query plan computation

**Example cycle:**

```
User → orders → Order → items → Product → reviews → Review → author → User
```

**Detection:**

```bash
# Use rover to inspect composition warnings
rover supergraph compose --config supergraph.yaml 2>&1 | grep -i "circular\|cycle"
```

### Breaking Circular Dependencies

**Strategy 1: Use @provides to short-circuit**

Instead of resolving full entities across all subgraphs, provide key fields inline:

```graphql
# Reviews subgraph
type Review {
  author: User @provides(fields: "name")
}
type User @key(fields: "id") {
  id: ID! @external
  name: String! @external  # provided inline, no hop to Users subgraph
}
```

**Strategy 2: Flatten the graph**

Move related fields into the same subgraph if they're always queried together.

**Strategy 3: Non-resolvable stubs**

Use `resolvable: false` to break the chain:

```graphql
type User @key(fields: "id", resolvable: false) {
  id: ID!
}
```

---

## Schema Check Failures

### Breaking Changes Detected

**Error in CI:** `rover subgraph check` fails with breaking changes.

**Common breaking changes:**
- Removing a field
- Changing a field's type
- Making a nullable field non-nullable
- Removing an enum value
- Removing a type

**Non-breaking changes (safe to deploy):**
- Adding a field
- Adding an optional argument
- Adding an enum value
- Deprecating a field
- Adding a type

### Non-Breaking vs Breaking Changes

| Change | Breaking? | Mitigation |
|--------|-----------|------------|
| Remove field | Yes | Deprecate first; remove after clients stop using |
| Change field type | Yes | Add new field, deprecate old |
| Add required argument | Yes | Use default value to make optional |
| Remove enum value | Yes | Check usage in GraphOS |
| Make nullable → non-nullable | Yes | Only safe if no client expects null |
| Add optional field | No | Safe |
| Add enum value | No | Clients should handle unknown values |
| Deprecate field | No | Use @deprecated directive |

### Operation Check Failures

**Error:** `OPERATIONS_CHECK_FAILURE` — Field "Product.legacyId" is being removed but is used by 15 operations.

**Fix:**
1. Check which clients use the field: `rover subgraph check` with `--query-count-threshold` and `--query-percentage-threshold`
2. Contact client teams to migrate
3. Deprecate the field and set a removal date
4. Override the check if usage is from deprecated clients: `--ignore` flag

---

## Supergraph Drift

### Symptoms

- Queries work against local compose but fail in production
- Fields return unexpected data
- Schema in GraphOS doesn't match deployed subgraphs

### Diagnosis

```bash
# Compare local vs managed supergraph
rover supergraph compose --config supergraph.yaml > local-supergraph.graphql
rover supergraph fetch my-graph@prod > remote-supergraph.graphql
diff local-supergraph.graphql remote-supergraph.graphql

# Check individual subgraphs
rover subgraph introspect http://products:4001/graphql > deployed-products.graphql
rover subgraph fetch my-graph@prod --name products > published-products.graphql
diff deployed-products.graphql published-products.graphql
```

### Resolution

1. **Republish drifted subgraphs:** `rover subgraph publish` with the correct schema
2. **Enforce CI/CD:** Never deploy a subgraph without publishing its schema
3. **Use managed federation:** Router polls for schema updates automatically
4. **Schema registry as source of truth:** Introspect and compare on a schedule

---

## CORS with Router

### Preflight Request Failures

**Symptoms:** Browser shows CORS error. `OPTIONS` request returns 403 or no CORS headers.

### Configuration

```yaml
# router.yaml
cors:
  origins:
    - https://app.example.com
    - https://staging.example.com
  allow_headers:
    - Content-Type
    - Authorization
    - X-Request-ID
    - Apollo-Require-Preflight
  methods:
    - GET
    - POST
    - OPTIONS
  allow_credentials: true
  max_age: 86400  # 24 hours — reduces preflight requests
```

### Common Mistakes

1. **Missing `Apollo-Require-Preflight` header:**
   Apollo Client sends this header by default. Add it to `allow_headers`.

2. **Wildcard `*` with credentials:**
   ```yaml
   # WRONG — browsers reject wildcard + credentials
   cors:
     origins:
       - "*"
     allow_credentials: true
   ```
   Fix: List specific origins.

3. **Forgetting OPTIONS method:**
   The router must handle preflight OPTIONS requests.

4. **Multiple CORS layers:**
   If a reverse proxy (nginx, ALB) also adds CORS headers, you get duplicate headers that browsers reject. Configure CORS in only one layer.

---

## Performance Issues

### Slow Query Plans

**Symptoms:** p99 latency spikes on first occurrence of a query shape.

**Investigation:**

```yaml
# Enable query plan timing in telemetry
telemetry:
  instrumentation:
    instruments:
      default_requirement_level: info
```

**Fixes:**
- Reduce schema complexity: fewer cross-subgraph relationships
- Increase plan cache: `query_planning.cache.in_memory.limit`
- Use persisted queries: clients send a hash instead of the full query

### N+1 Queries in Subgraphs

**Symptoms:** Subgraph response times scale linearly with list size. Database shows many identical queries.

**Detection:**

```typescript
// Add query counting in development
let queryCount = 0;
const originalQuery = db.query;
db.query = (...args) => { queryCount++; return originalQuery(...args); };
// Log queryCount after each request
```

**Fix:** Use DataLoader. See [subgraph-patterns.md](./subgraph-patterns.md#n1-problem-in-resolvers).

### Large Response Assembly

**Symptoms:** Router memory spikes on large queries. Slow response assembly.

**Fixes:**
1. Set response size limits:
   ```yaml
   limits:
     max_depth: 15
     max_height: 200
     max_aliases: 30
   ```
2. Use `@defer` for non-critical fields:
   ```graphql
   query {
     product(upc: "1") {
       name
       ... @defer {
         reviews { body rating }
       }
     }
   }
   ```

---

## Debugging Techniques

### Query Plan Inspection

Request the query plan to understand how the router splits and routes your query:

```bash
curl -H "Content-Type: application/json" \
  -H "Apollo-Query-Plan-Experimental: true" \
  -d '{"query":"{ product(upc:\"1\") { name reviews { body } } }"}' \
  http://localhost:4000/graphql | jq '.extensions.queryPlan'
```

### Router Logging

```bash
# Increase log verbosity
APOLLO_ROUTER_LOG=debug,hyper=info,tower=info router --config router.yaml --supergraph supergraph.graphql

# Filter for specific components
APOLLO_ROUTER_LOG="apollo_router::query_planner=trace,apollo_router::services::subgraph=debug" router ...
```

### Subgraph Tracing

Enable OpenTelemetry in subgraphs to correlate traces across services:

```typescript
import { ApolloServer } from '@apollo/server';
import { ApolloServerPluginInlineTrace } from '@apollo/server/plugin/inlineTrace';

const server = new ApolloServer({
  schema: buildSubgraphSchema({ typeDefs, resolvers }),
  plugins: [ApolloServerPluginInlineTrace()],
});
```

In the router, enable federated tracing export:

```yaml
telemetry:
  exporters:
    tracing:
      otlp:
        enabled: true
        endpoint: http://collector:4317
        protocol: grpc
  instrumentation:
    spans:
      mode: spec_compliant
```

This gives you end-to-end trace visibility: client → router → subgraph(s) → data sources.
