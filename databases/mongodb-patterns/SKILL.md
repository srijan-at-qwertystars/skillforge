---
name: mongodb-patterns
description: >
  MongoDB schema design, aggregation pipelines, indexing, replica sets, sharding, change streams,
  transactions, and performance tuning patterns. Use when: MongoDB schema design, MongoDB aggregation,
  MongoDB indexing, replica set configuration, MongoDB sharding, document modeling, MongoDB performance,
  mongoose schema, MongoDB query optimization, bucket pattern, outlier pattern, MongoDB anti-patterns,
  MongoDB connection pooling, change streams, MongoDB transactions, compound index, TTL index.
  Do NOT use for: SQL database design, PostgreSQL queries, MySQL optimization, DynamoDB patterns,
  Redis caching, Elasticsearch queries, Neo4j graph queries, Cassandra data modeling, CockroachDB,
  SQLite operations, relational database normalization.
---

# MongoDB Patterns

## Schema Design

### Embedding vs Referencing Decision

Embed when:
- Data is read together in a single query (1:1 or 1:few).
- Child data is bounded (will not grow beyond ~100 items).
- Atomicity is required — embedded updates are atomic.
- Child data belongs exclusively to the parent.

Reference when:
- Related data grows unboundedly (1:many, many:many).
- Child data is accessed independently or shared across parents.
- Document would exceed 16MB BSON limit.
- Write contention on parent doc is high.

```js
// EMBEDDED — order with line items (bounded, always read together)
{
  _id: ObjectId("..."),
  customerId: ObjectId("..."),
  status: "shipped",
  items: [
    { sku: "ABC123", qty: 2, price: 29.99 },
    { sku: "DEF456", qty: 1, price: 49.99 }
  ],
  total: 109.97
}

// REFERENCED — user with posts (unbounded, accessed independently)
// users collection
{ _id: ObjectId("u1"), name: "Alice", email: "alice@example.com" }
// posts collection
{ _id: ObjectId("p1"), authorId: ObjectId("u1"), title: "...", body: "..." }
```

### Polymorphic Pattern

Store heterogeneous documents in one collection with a `type` discriminator. Add type-specific fields as needed. Index the `type` field for filtered queries.

```js
// Single "vehicles" collection
{ type: "car", make: "Toyota", doors: 4, fuelType: "hybrid" }
{ type: "truck", make: "Ford", towCapacity: 12000, bedLength: 6.5 }
{ type: "motorcycle", make: "Ducati", engineCC: 1200 }
// Query: db.vehicles.find({ type: "car", fuelType: "hybrid" })
```

### Bucket Pattern

Group time-series or high-frequency data into fixed-size buckets to reduce document count and improve read throughput.

```js
// Instead of one doc per sensor reading, bucket by hour
{
  sensorId: "temp-01",
  bucket: ISODate("2024-03-15T14:00:00Z"), // hour boundary
  count: 60,
  readings: [
    { ts: ISODate("2024-03-15T14:00:12Z"), val: 22.5 },
    { ts: ISODate("2024-03-15T14:01:08Z"), val: 22.7 }
    // ... up to 60 readings per bucket
  ],
  min: 22.1, max: 23.4, avg: 22.8 // precomputed aggregates
}
// Use $push with $slice to cap array size; create new bucket doc when full.
```

### Outlier Pattern

Handle documents where a subset has disproportionately large arrays. Keep data embedded for the common case; overflow to a separate collection.

```js
// Normal user — reviews embedded
{ _id: "user1", name: "Alice", reviews: [ /* 5 reviews */ ], hasOverflow: false }

// Power user — flag overflow, store excess separately
{ _id: "user2", name: "Bob", reviews: [ /* first 50 */ ], hasOverflow: true }
// overflow collection
{ userId: "user2", reviews: [ /* reviews 51-500 */ ] }
// App reads: if hasOverflow, also query overflow collection.
```

## Aggregation Pipeline

### Stage Ordering (Critical for Performance)

Follow the **filter → project → transform → sort → limit** order:

1. `$match` — filter early to reduce documents. Uses indexes only when first or preceded by `$sort`.
2. `$project` / `$addFields` — drop unused fields before memory-heavy stages.
3. `$lookup` — join after filtering. Index the foreign field. Use pipeline form for filtered joins.
4. `$unwind` — expand arrays only after filtering.
5. `$group` — blocking stage; minimize input size.
6. `$sort` — blocking; pair with `$limit` for top-k optimization.
7. `$limit` / `$skip` — final pagination.

```js
// Optimized pipeline: total spend per active customer, top 10
db.orders.aggregate([
  { $match: { status: "completed", createdAt: { $gte: ISODate("2024-01-01") } } },
  { $project: { customerId: 1, total: 1 } },
  { $group: { _id: "$customerId", totalSpent: { $sum: "$total" } } },
  { $sort: { totalSpent: -1 } },
  { $limit: 10 },
  { $lookup: { from: "customers", localField: "_id", foreignField: "_id", as: "customer" } },
  { $unwind: "$customer" },
  { $project: { name: "$customer.name", totalSpent: 1 } }
])
```

### Key Operators

| Operator | Use | Note |
|----------|-----|------|
| `$match` | Filter docs | Place first for index use |
| `$group` | Aggregate values | Blocking; uses 100MB RAM default |
| `$lookup` | Left outer join | Index foreign field; use pipeline form for conditions |
| `$unwind` | Flatten arrays | Adds `preserveNullAndEmptyArrays` option |
| `$facet` | Multiple pipelines on same input | Each sub-pipeline gets full input; blocking |
| `$merge` / `$out` | Write results | `$merge` for upsert into existing collection |
| `$bucket` | Group into ranges | Good for histograms |
| `$graphLookup` | Recursive lookup | Traverse tree/graph structures |

Set `{ allowDiskUse: true }` for pipelines exceeding 100MB RAM limit.

## Indexing Strategies

### ESR Rule for Compound Indexes

Order fields: **Equality → Sort → Range**.

```js
// Query: find active users in age range, sorted by name
db.users.find({ status: "active", age: { $gte: 21, $lte: 35 } }).sort({ name: 1 })
// Index: equality first, then sort, then range
db.users.createIndex({ status: 1, name: 1, age: 1 })
```

### Index Types

```js
// COMPOUND — multi-field queries; leftmost prefix rule applies
db.orders.createIndex({ customerId: 1, createdAt: -1 })

// MULTIKEY — auto-created for array fields; max one array field per compound index
db.products.createIndex({ tags: 1 })

// TEXT — full-text search; one per collection
db.articles.createIndex({ title: "text", body: "text" })
// Query: db.articles.find({ $text: { $search: "mongodb patterns" } })

// WILDCARD — dynamic schemas with unpredictable fields
db.events.createIndex({ "metadata.$**": 1 })

// PARTIAL — index subset of docs; saves space and write overhead
db.users.createIndex(
  { email: 1 },
  { partialFilterExpression: { email: { $exists: true } } }
)

// TTL — auto-delete docs after expiry
db.sessions.createIndex({ createdAt: 1 }, { expireAfterSeconds: 3600 })

// UNIQUE — enforce uniqueness
db.users.createIndex({ email: 1 }, { unique: true })
```

### Index Anti-patterns

- Too many indexes (>10 per collection) slow writes.
- Unused indexes waste RAM — audit with `$indexStats`.
- Indexing low-cardinality fields (e.g., boolean) alone is wasteful.
- Compound indexes that don't follow ESR rule underperform.
- Missing index on `$lookup` foreign field causes full collection scan.

## Replica Sets

### Configuration

```js
// Initialize a 3-node replica set (1 primary + 2 secondaries)
rs.initiate({
  _id: "myReplicaSet",
  members: [
    { _id: 0, host: "mongo1:27017", priority: 2 },  // preferred primary
    { _id: 1, host: "mongo2:27017", priority: 1 },
    { _id: 2, host: "mongo3:27017", priority: 1 }
  ]
})
// Use odd number of voting members (3, 5, 7) to ensure majority.
// Add arbiter only when even-member set is unavoidable.
```

### Read Preferences

| Mode | Consistency | Latency | Use Case |
|------|------------|---------|----------|
| `primary` | Strong | Higher | Default; transactions require this |
| `primaryPreferred` | Strong (fallback stale) | Medium | Tolerate brief stale reads on failover |
| `secondary` | Eventual | Lower | Analytics, reporting, dashboards |
| `secondaryPreferred` | Eventual (fallback strong) | Lower | Read-heavy offload |
| `nearest` | Eventual | Lowest | Geo-distributed; latency-sensitive |

```js
// Node.js driver — read from nearest with max staleness
const client = new MongoClient(uri, {
  readPreference: "nearest",
  readPreferenceTags: [{ region: "us-east" }],
  maxStalenessSeconds: 90
});
```

## Sharding

### Shard Key Selection Criteria

- **High cardinality** — many distinct values for even distribution.
- **Low frequency** — no single value dominates writes.
- **Non-monotonic** — avoid auto-increment IDs (cause hotspots with range sharding).
- Shard key is immutable after creation. Choose carefully.

### Strategies

```js
// RANGE — good for range queries on the shard key; risk of hotspots
sh.shardCollection("mydb.logs", { timestamp: 1 })

// HASH — even write distribution; scatter-gather on range queries
sh.shardCollection("mydb.users", { _id: "hashed" })

// ZONE — data locality (geo, compliance, tiered storage)
sh.addShardTag("shard-eu", "EU")
sh.addTagRange("mydb.users", { region: "EU" }, { region: "EU~" }, "EU")
// Routes EU user data to EU shard for GDPR compliance.

// COMPOUND SHARD KEY — balance distribution and query targeting
sh.shardCollection("mydb.events", { tenantId: 1, _id: 1 })
```

## Change Streams

```js
// Watch a collection for inserts and updates
const pipeline = [{ $match: { operationType: { $in: ["insert", "update"] } } }];
const changeStream = db.collection("orders").watch(pipeline, { fullDocument: "updateLookup" });

changeStream.on("change", (event) => {
  console.log(event.operationType, event.fullDocument);
  // Store event._id (resume token) for crash recovery
});

// Resume after failure using stored resume token
const resumed = db.collection("orders").watch(pipeline, { resumeAfter: storedToken });
```

Requirements: replica set or sharded cluster (not standalone). Size oplog for expected downtime window.

## Transactions

```js
const session = client.startSession();
try {
  session.startTransaction({
    readConcern: { level: "snapshot" },
    writeConcern: { w: "majority" },
    readPreference: "primary" // required for transactions
  });

  await db.collection("accounts").updateOne(
    { _id: fromAcct }, { $inc: { balance: -amount } }, { session }
  );
  await db.collection("accounts").updateOne(
    { _id: toAcct }, { $inc: { balance: amount } }, { session }
  );
  await db.collection("transfers").insertOne(
    { from: fromAcct, to: toAcct, amount, ts: new Date() }, { session }
  );

  await session.commitTransaction();
} catch (e) {
  await session.abortTransaction();
  throw e;
} finally {
  session.endSession();
}
```

Rules: keep transactions short (<60s default timeout). Limit to 1000 docs modified. Prefer schema design that avoids needing transactions.

## Performance Tuning

### Explain Plans

```js
// Check query execution plan
db.orders.find({ status: "pending" }).explain("executionStats")
// Key fields to check:
//   executionStats.totalDocsExamined — should be close to nReturned
//   executionStats.executionStages.stage — "IXSCAN" good, "COLLSCAN" bad
//   queryPlanner.winningPlan.inputStage.indexName — which index was used
```

### Database Profiler

```js
// Enable profiler for slow queries (>100ms)
db.setProfilingLevel(1, { slowms: 100 })
// Review slow queries
db.system.profile.find().sort({ ts: -1 }).limit(5)
// Disable in production after analysis: db.setProfilingLevel(0)
```

### Connection Pooling

```js
// Node.js driver — configure pool size based on concurrency
const client = new MongoClient(uri, {
  maxPoolSize: 50,        // max concurrent connections
  minPoolSize: 5,         // keep warm connections
  maxIdleTimeMS: 30000,   // close idle connections after 30s
  waitQueueTimeoutMS: 5000 // fail fast if pool exhausted
});
// Rule of thumb: maxPoolSize = expected_concurrent_ops * 1.5
// Monitor with: db.serverStatus().connections
```

### Write Concern Tuning

```js
// Fast writes (risk data loss on crash): { w: 1, j: false }
// Durable writes: { w: "majority", j: true }
// Use majority for critical data; w:1 for ephemeral/log data.
```

## Common Anti-patterns

| Anti-pattern | Problem | Fix |
|-------------|---------|-----|
| Unbounded array growth | Hits 16MB limit; degrades perf | Use bucket or outlier pattern |
| Massive `$lookup` without filters | Full collection scan on join | Filter before `$lookup`; index foreign key |
| `$where` / JS expressions in queries | No index use; JS eval is slow | Use standard query operators |
| Storing files as Base64 in documents | Wastes RAM and storage | Use GridFS for files >1MB |
| No read preference on read-heavy apps | Overloads primary | Use `secondaryPreferred` for reads |
| Single-field indexes for every query | Too many indexes; write penalty | Use compound indexes with ESR |
| Ignoring `explain()` output | Undetected collection scans | Profile queries before production |
| Using transactions for everything | Unnecessary overhead | Design schema to avoid multi-doc writes |
| Default connection pool in production | Pool exhaustion under load | Tune `maxPoolSize` to match concurrency |
| Monotonic shard key (e.g., timestamp) | Write hotspot on one shard | Use hashed sharding or compound key |

## Mongoose Schema Patterns

```js
const mongoose = require("mongoose");

// Discriminator pattern (polymorphic)
const vehicleSchema = new mongoose.Schema({ make: String, year: Number }, { discriminatorKey: "type" });
const Vehicle = mongoose.model("Vehicle", vehicleSchema);
const Car = Vehicle.discriminator("Car", new mongoose.Schema({ doors: Number }));
const Truck = Vehicle.discriminator("Truck", new mongoose.Schema({ towCapacity: Number }));

// Virtual populate (reference without storing array of IDs on parent)
const authorSchema = new mongoose.Schema({ name: String });
authorSchema.virtual("posts", { ref: "Post", localField: "_id", foreignField: "author" });
const postSchema = new mongoose.Schema({ title: String, author: { type: mongoose.Schema.Types.ObjectId, ref: "Author" } });

// Lean queries for read-only performance
const users = await User.find({ active: true }).lean(); // returns plain objects, ~5x faster

// Index declaration in schema
postSchema.index({ author: 1, createdAt: -1 }); // compound index
postSchema.index({ title: "text", body: "text" }); // text index
```

## References

Deep-dive reference documents for advanced topics:

| Reference | Description |
|-----------|-------------|
| [`references/advanced-patterns.md`](references/advanced-patterns.md) | Subset, computed, extended reference, schema versioning, tree structures, attribute & approximation patterns. Aggregation optimization ($lookup tuning, $merge/$out materialized views, Atlas $search). Time-series collections, change stream patterns (pre/post images, exactly-once), queryable encryption & CSFLE, advanced indexing (covered queries, hidden indexes, columnstore). |
| [`references/troubleshooting.md`](references/troubleshooting.md) | Slow query diagnosis (profiler, explain plans), index usage analysis (unused/duplicate/missing), lock contention, WiredTiger cache pressure, replication lag, connection pool exhaustion, oplog sizing, storage engine issues (compaction, checkpoints, journal), upgrade path gotchas & FCV. |
| [`references/aggregation-reference.md`](references/aggregation-reference.md) | Complete pipeline stage reference ($match through $documents), all expression operators (comparison, arithmetic, string, array, date, conditional, type), accumulator operators (basic, array, statistical with $median/$percentile), window functions ($setWindowFields, ranking, running calculations), Atlas Search integration (operators, scoring, facets, vector search). |

## Scripts

Executable helper scripts in `scripts/`:

| Script | Purpose | Usage |
|--------|---------|-------|
| [`scripts/index-analyzer.sh`](scripts/index-analyzer.sh) | Find unused, duplicate, and missing indexes across collections. Uses mongosh. | `./scripts/index-analyzer.sh -d mydb` |
| [`scripts/health-check.sh`](scripts/health-check.sh) | Dashboard: replication, connections, cache, oplog, locks, disk. Configurable thresholds. | `./scripts/health-check.sh -u "mongodb://..."` |
| [`scripts/backup-restore.sh`](scripts/backup-restore.sh) | Backup/restore with mongodump/mongorestore. Supports replica sets, oplog, compression, retention. | `./scripts/backup-restore.sh backup -d mydb --oplog` |

## Assets

Templates and utilities in `assets/`:

| Asset | Description |
|-------|-------------|
| [`assets/docker-compose.yaml`](assets/docker-compose.yaml) | Docker Compose for a 3-node MongoDB 7 replica set with keyfile auth, health checks, and named volumes. |
| [`assets/mongosh-snippets.js`](assets/mongosh-snippets.js) | Collection of mongosh helper functions: `serverOverview()`, `indexUsage()`, `quickExplain()`, `slowQueries()`, `replStatus()`, `cacheStatus()`, `schemaShape()`, and more. Load with `load('mongosh-snippets.js')`. |

<!-- tested: pass -->
