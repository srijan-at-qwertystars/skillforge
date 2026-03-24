# Advanced MongoDB Patterns

## Table of Contents

- [Schema Design Patterns](#schema-design-patterns)
  - [Subset Pattern](#subset-pattern)
  - [Computed Pattern](#computed-pattern)
  - [Extended Reference Pattern](#extended-reference-pattern)
  - [Schema Versioning Pattern](#schema-versioning-pattern)
  - [Tree Structure Patterns](#tree-structure-patterns)
  - [Attribute Pattern](#attribute-pattern)
  - [Approximation Pattern](#approximation-pattern)
  - [Document Versioning Pattern](#document-versioning-pattern)
- [Aggregation Optimization](#aggregation-optimization)
  - [$lookup vs Embedding Trade-offs](#lookup-vs-embedding-trade-offs)
  - [$merge and $out — Materialized Views](#merge-and-out--materialized-views)
  - [$search — Atlas Search Integration](#search--atlas-search-integration)
  - [Pipeline Performance Rules](#pipeline-performance-rules)
- [Time-Series Collections](#time-series-collections)
  - [Collection Creation and Configuration](#collection-creation-and-configuration)
  - [Secondary Indexes](#secondary-indexes)
  - [Querying Time-Series Data](#querying-time-series-data)
  - [Migration from Bucket Pattern](#migration-from-bucket-pattern)
- [Change Stream Advanced Patterns](#change-stream-advanced-patterns)
  - [Pre/Post Image Capture](#prepost-image-capture)
  - [Filtering and Transformation](#filtering-and-transformation)
  - [Distributed Resume Strategy](#distributed-resume-strategy)
  - [Change Stream with Aggregation](#change-stream-with-aggregation)
  - [Exactly-Once Processing](#exactly-once-processing)
- [Queryable Encryption and CSFLE](#queryable-encryption-and-csfle)
  - [CSFLE (Client-Side Field Level Encryption)](#csfle-client-side-field-level-encryption)
  - [Queryable Encryption (7.0+)](#queryable-encryption-70)
  - [Key Management Architecture](#key-management-architecture)
  - [Encryption Algorithm Selection](#encryption-algorithm-selection)
- [Advanced Indexing Strategies](#advanced-indexing-strategies)
  - [Covered Queries](#covered-queries)
  - [Index Intersection](#index-intersection)
  - [Hidden Indexes](#hidden-indexes)
  - [Columnstore Indexes (7.0+)](#columnstore-indexes-70)

---

## Schema Design Patterns

### Subset Pattern

Store the most-accessed subset of a related document's data directly in the parent. Reduces `$lookup` for common read paths while full data lives in its own collection.

**When to use:** Parent documents frequently need a few fields from a related document (e.g., product listings showing the 10 most recent reviews, user profiles showing 5 most recent orders).

```javascript
// products collection — embeds the 10 most recent reviews
{
  _id: ObjectId("prod1"),
  name: "Wireless Mouse",
  price: 29.99,
  recentReviews: [
    { userId: ObjectId("u5"), rating: 5, text: "Great mouse!", date: ISODate("2024-11-10") },
    { userId: ObjectId("u3"), rating: 4, text: "Good value", date: ISODate("2024-11-09") }
    // ... up to 10
  ],
  reviewCount: 487,
  avgRating: 4.3
}

// reviews collection — full review data
{
  _id: ObjectId("rev1"),
  productId: ObjectId("prod1"),
  userId: ObjectId("u5"),
  rating: 5,
  text: "Great mouse!",
  date: ISODate("2024-11-10"),
  helpfulVotes: 12,
  images: ["img1.jpg", "img2.jpg"],
  verified: true
}

// On new review insert, update the subset:
db.products.updateOne(
  { _id: productId },
  {
    $push: { recentReviews: { $each: [newReview], $sort: { date: -1 }, $slice: 10 } },
    $inc: { reviewCount: 1 },
    $set: { avgRating: newAvgRating }
  }
);
```

### Computed Pattern

Pre-compute expensive calculations at write time. Trades more complex writes for dramatically faster reads.

**When to use:** Values derived from aggregations read far more often than underlying data changes (running totals, averages, leaderboard scores).

```javascript
// Store running stats on the document itself
{
  _id: ObjectId("movie1"),
  title: "Inception",
  ratings: {
    count: 15420,
    sum: 63222,
    average: 4.1,
    distribution: { 1: 210, 2: 540, 3: 2100, 4: 5200, 5: 7370 }
  }
}

// On new rating: atomically update computed fields using pipeline update
db.movies.updateOne(
  { _id: movieId },
  [
    { $set: {
      "ratings.count": { $add: ["$ratings.count", 1] },
      "ratings.sum": { $add: ["$ratings.sum", newRating] },
    }},
    { $set: {
      "ratings.average": {
        $round: [{ $divide: ["$ratings.sum", "$ratings.count"] }, 1]
      }
    }}
  ]
);

// Rolling window computed pattern: hourly/daily aggregates
{
  _id: "sensor-01:2024-11-15",
  sensorId: "sensor-01",
  date: ISODate("2024-11-15"),
  hourly: {
    "08": { min: 21.2, max: 23.5, avg: 22.3, count: 60 },
    "09": { min: 22.0, max: 24.1, avg: 23.0, count: 58 }
  },
  daily: { min: 20.1, max: 25.8, avg: 22.7, count: 1440 }
}
```

### Extended Reference Pattern

Copy frequently accessed fields from a referenced document into the referencing document to avoid costly `$lookup`. Accept eventual consistency for duplicated fields.

**When to use:** Read-heavy workloads where joins are expensive and duplicated data changes infrequently (e.g., order storing customer name/address).

```javascript
// orders collection — extended reference to customer
{
  _id: ObjectId("order1"),
  customerId: ObjectId("cust1"),
  // Extended reference: fields read with every order display
  customerSnapshot: {
    name: "Alice Johnson",
    email: "alice@example.com",
    tier: "gold"
  },
  items: [{ sku: "ABC", qty: 2, price: 29.99 }],
  total: 59.98
}

// Sync strategy 1: Change stream listener for near-real-time
const stream = db.customers.watch([
  { $match: { operationType: "update" } }
]);
stream.on("change", async (event) => {
  const { name, email, tier } = event.fullDocument;
  await db.orders.updateMany(
    { customerId: event.documentKey._id },
    { $set: { "customerSnapshot": { name, email, tier } } }
  );
});

// Sync strategy 2: Bulk update on schedule (less time-sensitive data)
db.customers.find({ updatedAt: { $gte: lastSyncTime } }).forEach(cust => {
  db.orders.updateMany(
    { customerId: cust._id },
    { $set: { customerSnapshot: { name: cust.name, email: cust.email, tier: cust.tier } } }
  );
});
```

### Schema Versioning Pattern

Support multiple document shapes in the same collection during incremental migrations. Each document carries a `schemaVersion` field.

```javascript
// Version 1: original schema
{ _id: ObjectId("u1"), schemaVersion: 1, name: "Alice Johnson", address: "123 Main St, Springfield, IL 62701" }

// Version 2: structured address
{
  _id: ObjectId("u2"),
  schemaVersion: 2,
  firstName: "Bob", lastName: "Smith",
  address: { street: "456 Oak Ave", city: "Portland", state: "OR", zip: "97201" }
}

// Application-level migration function
function normalizeUser(doc) {
  if (doc.schemaVersion === 1) {
    const [firstName, ...rest] = doc.name.split(" ");
    return { ...doc, schemaVersion: 2, firstName, lastName: rest.join(" "), address: parseAddress(doc.address) };
  }
  return doc;
}

// Lazy migration: upgrade on read
async function getUser(userId) {
  const user = await db.users.findOne({ _id: userId });
  if (user.schemaVersion < CURRENT_VERSION) {
    const upgraded = normalizeUser(user);
    await db.users.replaceOne({ _id: userId, schemaVersion: user.schemaVersion }, upgraded);
    return upgraded;
  }
  return user;
}

// Batch migration: process in chunks
async function migrateUsers(batchSize = 1000) {
  let processed = 0;
  while (true) {
    const batch = await db.users.find({ schemaVersion: 1 }).limit(batchSize).toArray();
    if (batch.length === 0) break;
    const ops = batch.map(doc => ({
      replaceOne: { filter: { _id: doc._id, schemaVersion: 1 }, replacement: normalizeUser(doc) }
    }));
    await db.users.bulkWrite(ops, { ordered: false });
    processed += batch.length;
  }
}
```

### Tree Structure Patterns

MongoDB supports several patterns for hierarchical data:

#### Parent Reference

```javascript
{ _id: "CEO", parent: null, name: "Alice" }
{ _id: "VP_Eng", parent: "CEO", name: "Bob" }
{ _id: "Dev_Lead", parent: "VP_Eng", name: "Dave" }

// Find children: db.org.find({ parent: "CEO" })
// Index: db.org.createIndex({ parent: 1 })
```

#### Materialized Path

```javascript
{ _id: "Dev_Lead", path: ",CEO,VP_Eng,Dev_Lead,", name: "Dave" }
{ _id: "SRE", path: ",CEO,VP_Eng,Dev_Lead,SRE,", name: "Eve" }

// Find all descendants of VP_Eng:
db.org.find({ path: /,VP_Eng,/ })
// Index: db.org.createIndex({ path: 1 })
```

#### Nested Sets

```javascript
{ _id: "CEO", left: 1, right: 10 }
{ _id: "VP_Eng", left: 2, right: 7 }
{ _id: "Dev_Lead", left: 3, right: 4 }

// Find all descendants of VP_Eng (left=2, right=7):
db.org.find({ left: { $gt: 2 }, right: { $lt: 7 } })
// Fast reads, expensive writes (must renumber on insert/delete)
```

#### $graphLookup for Recursive Traversal

```javascript
// Find entire reporting chain from employee to CEO
db.org.aggregate([
  { $match: { _id: "SRE" } },
  { $graphLookup: {
    from: "org",
    startWith: "$parent",
    connectFromField: "parent",
    connectToField: "_id",
    as: "ancestors",
    maxDepth: 10,
    depthField: "level"
  }}
]);
```

**Pattern selection guide:**

| Pattern | Subtree Query | Ancestor Query | Writes | Best For |
|---------|--------------|----------------|--------|----------|
| Parent Ref | Recursive/$graphLookup | Recursive | Fast | Frequent updates |
| Materialized Path | Regex on path | Parse path | Medium | Read-heavy, moderate updates |
| Nested Sets | Range query (fastest) | Range query | Slow (renumber) | Read-dominant, rare updates |

### Attribute Pattern

Store varied fields as key-value pairs in an array for uniform indexing.

```javascript
// Without: heterogeneous fields, can't index uniformly
{ type: "TV", screenSize: 55, resolution: "4K", hdmiPorts: 3 }
{ type: "Phone", screenSize: 6.1, ram: 8, storage: 256 }

// With attribute pattern:
{
  type: "TV",
  specs: [
    { k: "screenSize", v: 55, unit: "inches" },
    { k: "resolution", v: "4K" },
    { k: "hdmiPorts", v: 3 }
  ]
}

// Single compound index covers queries on ANY spec:
db.products.createIndex({ "specs.k": 1, "specs.v": 1 })
db.products.find({ specs: { $elemMatch: { k: "screenSize", v: { $gte: 50 } } } })
```

### Approximation Pattern

Reduce write frequency for high-volume counters using probabilistic updates.

```javascript
function incrementPageView(pageId) {
  if (Math.random() < 0.01) {
    db.pages.updateOne({ _id: pageId }, { $inc: { viewCount: 100 } });
  }
}

// Adaptive sampling for accuracy at lower volumes:
function adaptiveIncrement(pageId, currentCount) {
  const rate = currentCount < 1000 ? 1.0 : currentCount < 10000 ? 0.1 : 0.01;
  if (Math.random() < rate) {
    db.pages.updateOne({ _id: pageId }, { $inc: { viewCount: Math.round(1 / rate) } });
  }
}
```

### Document Versioning Pattern

Track full history of document changes for audit trails.

```javascript
// Current state in main collection
{ _id: ObjectId("doc1"), title: "Project Plan", content: "Latest...", version: 3 }

// History in separate collection
{ docId: ObjectId("doc1"), version: 1, title: "Project Plan", content: "Initial...",
  changedBy: "alice", changedAt: ISODate("2024-11-01"), changeType: "create" }

// Atomic update with version push
async function updateWithHistory(collName, docId, updates, userId) {
  const session = client.startSession();
  try {
    session.startTransaction();
    const current = await db.collection(collName).findOne({ _id: docId }, { session });
    await db.collection(collName + "_history").insertOne({
      docId: current._id, version: current.version, ...current,
      _id: new ObjectId(), changedBy: userId, changedAt: new Date(), changeType: "update"
    }, { session });
    await db.collection(collName).updateOne(
      { _id: docId },
      { $set: { ...updates, updatedBy: userId, updatedAt: new Date() }, $inc: { version: 1 } },
      { session }
    );
    await session.commitTransaction();
  } finally { session.endSession(); }
}
```

---

## Aggregation Optimization

### $lookup vs Embedding Trade-offs

| Factor | Embed | $lookup |
|--------|-------|---------|
| Read latency | Single doc (fastest) | Join at query time |
| Write amplification | Update parent on child change | Isolated writes |
| Data consistency | Atomic within document | Eventual if denormalized |
| Document growth | Risk of unbounded growth | Stable doc sizes |
| Memory pressure | Large docs waste cache | Smaller working set |

**$lookup optimization strategies:**

```javascript
// BAD: Unfiltered $lookup
db.orders.aggregate([
  { $lookup: { from: "products", localField: "productId", foreignField: "_id", as: "product" } }
]);

// GOOD: Pipeline form with filter — fetch only needed fields
db.orders.aggregate([
  { $match: { status: "pending" } },
  { $lookup: {
    from: "products",
    let: { pid: "$productId" },
    pipeline: [
      { $match: { $expr: { $eq: ["$_id", "$$pid"] } } },
      { $project: { name: 1, price: 1 } }
    ],
    as: "product"
  }}
]);

// CRITICAL: Always index the foreign field in $lookup
db.reviews.createIndex({ productId: 1 });
```

### $merge and $out — Materialized Views

```javascript
// $out: Replace entire target collection (destructive)
db.orders.aggregate([
  { $match: { status: "completed" } },
  { $group: { _id: "$customerId", totalSpent: { $sum: "$total" }, orderCount: { $sum: 1 } } },
  { $out: "customer_spending_summary" }
]);

// $merge: Upsert into existing collection (incremental, preferred)
db.orders.aggregate([
  { $match: { status: "completed", createdAt: { $gte: ISODate("2024-11-01") } } },
  { $group: { _id: "$customerId", monthlySpent: { $sum: "$total" }, monthlyOrders: { $sum: 1 } } },
  { $merge: {
    into: "customer_monthly_stats",
    on: "_id",
    whenMatched: [
      { $set: {
        totalSpent: { $add: ["$monthlySpent", "$$ROOT.totalSpent"] },
        lastUpdated: new Date()
      }}
    ],
    whenNotMatched: "insert"
  }}
]);

// Pattern: initial full build with $out, then periodic deltas with $merge
```

### $search — Atlas Search Integration

```javascript
// Full-text search with scoring, fuzzy matching, highlighting
db.products.aggregate([
  { $search: {
    index: "product_search",
    compound: {
      must: [{ text: { query: "wireless bluetooth", path: "title", fuzzy: { maxEdits: 1 } } }],
      should: [{ text: { query: "premium", path: "description", score: { boost: { value: 2 } } } }],
      filter: [{ range: { path: "price", gte: 10, lte: 100 } }]
    },
    highlight: { path: ["title", "description"] }
  }},
  { $limit: 20 },
  { $project: { title: 1, price: 1, score: { $meta: "searchScore" }, highlights: { $meta: "searchHighlights" } } }
]);

// Autocomplete
db.products.aggregate([
  { $search: { autocomplete: { query: "wire", path: "title", tokenOrder: "sequential" } } },
  { $limit: 10 },
  { $project: { title: 1, _id: 0 } }
]);
```

### Pipeline Performance Rules

1. **$match first** — Enables index usage. Adjacent $match stages auto-merge.
2. **$project before $group** — Reduce field count before blocking stages.
3. **Avoid $unwind on large arrays** — Use `$filter` or `$reduce` instead.
4. **$sort + $limit coalesce** — Adjacent pair uses top-k algorithm (low memory).
5. **$lookup subpipeline** — Always filter inside, not after $unwind.
6. **allowDiskUse: true** — For pipelines exceeding 100MB memory limit.
7. **$facet caveat** — Each sub-pipeline processes ALL input. No index use inside $facet.

```javascript
// Efficient: $filter instead of $unwind + $match + $group
db.orders.aggregate([
  { $project: {
    expensiveItems: { $filter: { input: "$items", cond: { $gte: ["$$this.price", 100] } } }
  }}
]);
```

---

## Time-Series Collections

### Collection Creation and Configuration

```javascript
// Native time-series collection (5.0+)
db.createCollection("sensor_readings", {
  timeseries: {
    timeField: "timestamp",
    metaField: "metadata",
    granularity: "seconds"  // seconds | minutes | hours
  },
  expireAfterSeconds: 86400 * 90  // auto-delete after 90 days
});

// MongoDB 6.3+: fine-grained bucketing
db.createCollection("metrics", {
  timeseries: {
    timeField: "ts",
    metaField: "source",
    bucketMaxSpanSeconds: 3600,
    bucketRoundingSeconds: 3600
  }
});

// Insert (same as any collection)
db.sensor_readings.insertMany([
  { timestamp: ISODate("2024-11-15T10:30:00Z"),
    metadata: { sensorId: "temp-01", location: "warehouse-A" },
    temperature: 22.5, humidity: 45.2 }
]);
```

### Secondary Indexes

```javascript
// Compound on metadata + time (most common)
db.sensor_readings.createIndex({ "metadata.sensorId": 1, timestamp: 1 });

// Measurement field for range queries
db.sensor_readings.createIndex({ "metadata.location": 1, temperature: 1 });

// NOTE: auto-created clustered index on (metaField, timeField)
// — explicit timeField-only index is usually redundant
```

### Querying Time-Series Data

```javascript
// Hourly aggregation with window function
db.sensor_readings.aggregate([
  { $match: { timestamp: { $gte: ISODate("2024-11-15"), $lt: ISODate("2024-11-16") } } },
  { $group: {
    _id: { sensorId: "$metadata.sensorId", hour: { $dateTrunc: { date: "$timestamp", unit: "hour" } } },
    avgTemp: { $avg: "$temperature" }, maxTemp: { $max: "$temperature" }, readings: { $sum: 1 }
  }},
  { $sort: { "_id.sensorId": 1, "_id.hour": 1 } }
]);

// Moving average with $setWindowFields
db.sensor_readings.aggregate([
  { $match: { "metadata.sensorId": "temp-01" } },
  { $setWindowFields: {
    sortBy: { timestamp: 1 },
    output: { movingAvg: { $avg: "$temperature", window: { range: [-1, 0], unit: "hour" } } }
  }}
]);
```

### Migration from Bucket Pattern

```javascript
// Unwind existing manual buckets into native time-series
db.old_buckets.aggregate([
  { $unwind: "$readings" },
  { $project: { _id: 0, timestamp: "$readings.ts", metadata: { sensorId: "$sensorId" }, value: "$readings.val" } },
  { $merge: { into: "ts_readings" } }
]);
// Benefits: auto bucketing, columnar compression (~10x), optimized aggregation, built-in TTL
```

---

## Change Stream Advanced Patterns

### Pre/Post Image Capture

```javascript
// Enable pre/post images (6.0+)
db.runCommand({ collMod: "orders", changeStreamPreAndPostImages: { enabled: true } });

const stream = db.orders.watch([], {
  fullDocument: "updateLookup",
  fullDocumentBeforeChange: "required"  // "required" or "whenAvailable"
});

stream.on("change", (event) => {
  const before = event.fullDocumentBeforeChange;
  const after = event.fullDocument;
  if (before.status !== after.status) {
    console.log(`Order ${event.documentKey._id}: ${before.status} -> ${after.status}`);
  }
});
```

### Filtering and Transformation

```javascript
const pipeline = [
  { $match: {
    $or: [
      { operationType: "insert" },
      { operationType: "update", "updateDescription.updatedFields.status": { $exists: true } }
    ]
  }},
  { $project: { operationType: 1, documentKey: 1, "fullDocument.status": 1, "fullDocument.total": 1 } }
];
const stream = db.orders.watch(pipeline);
```

### Distributed Resume Strategy

```javascript
async function processChangeStream(collName) {
  const saved = await db.collection("change_stream_tokens").findOne({ _id: collName });
  const options = saved?.resumeToken
    ? { resumeAfter: saved.resumeToken }
    : { startAtOperationTime: Timestamp(Math.floor(Date.now() / 1000), 0) };

  const stream = db.collection(collName).watch([], { ...options, fullDocument: "updateLookup" });

  stream.on("change", async (event) => {
    try {
      await handleEvent(event);
      await db.collection("change_stream_tokens").updateOne(
        { _id: collName },
        { $set: { resumeToken: event._id, updatedAt: new Date() } },
        { upsert: true }
      );
    } catch (err) {
      stream.close();
      setTimeout(() => processChangeStream(collName), 5000);
    }
  });
}
```

### Change Stream with Aggregation

```javascript
// Database-level: watch multiple collections
const dbStream = db.watch([
  { $match: { "ns.coll": { $in: ["orders", "payments", "shipments"] } } }
]);

// Enrich events inline
const enriched = db.orders.watch([
  { $match: { operationType: { $in: ["insert", "update"] } } },
  { $addFields: {
    priority: { $switch: {
      branches: [
        { case: { $gte: ["$fullDocument.total", 1000] }, then: "high" },
        { case: { $gte: ["$fullDocument.total", 100] }, then: "medium" }
      ],
      default: "low"
    }}
  }}
]);
```

### Exactly-Once Processing

```javascript
async function processEventExactlyOnce(event) {
  const eventId = event._id._data;
  const session = client.startSession();
  try {
    session.startTransaction();
    const exists = await db.collection("processed_events").findOne({ _id: eventId }, { session });
    if (exists) { await session.abortTransaction(); return; }
    await applyBusinessLogic(event, session);
    await db.collection("processed_events").insertOne({ _id: eventId, processedAt: new Date() }, { session });
    await session.commitTransaction();
  } catch (err) { await session.abortTransaction(); throw err; }
  finally { session.endSession(); }
}

// TTL cleanup for dedup records
db.processed_events.createIndex({ processedAt: 1 }, { expireAfterSeconds: 86400 * 7 });
```

---

## Queryable Encryption and CSFLE

### CSFLE (Client-Side Field Level Encryption)

Encrypts fields client-side before sending to the server. Server never sees plaintext. Available since 4.2.

```javascript
const schemaMap = {
  "mydb.patients": {
    bsonType: "object",
    encryptMetadata: { keyId: [UUID("...")] },
    properties: {
      ssn: {
        encrypt: {
          bsonType: "string",
          algorithm: "AEAD_AES_256_CBC_HMAC_SHA_512-Deterministic"
          // Deterministic: allows equality queries on encrypted field
        }
      },
      medicalRecords: {
        encrypt: {
          bsonType: "array",
          algorithm: "AEAD_AES_256_CBC_HMAC_SHA_512-Random"
          // Random: more secure, no querying
        }
      }
    }
  }
};

const secureClient = new MongoClient(uri, {
  autoEncryption: {
    keyVaultNamespace: "encryption.__keyVault",
    kmsProviders: { aws: { accessKeyId: "...", secretAccessKey: "..." } },
    schemaMap
  }
});

// Usage is transparent
await db.collection("patients").insertOne({ name: "Alice", ssn: "123-45-6789", medicalRecords: [{}] });
await db.collection("patients").findOne({ ssn: "123-45-6789" }); // works (deterministic)
```

### Queryable Encryption (7.0+)

Supports equality AND range queries on encrypted data using structured encryption.

```javascript
const encryptedFieldsMap = {
  "mydb.patients": {
    fields: [
      { path: "ssn", bsonType: "string", queries: [{ queryType: "equality" }] },
      { path: "age", bsonType: "int",
        queries: [{ queryType: "range", min: 0, max: 150, sparsity: 2, precision: 0 }] }, // 8.0+
      { path: "medicalNotes", bsonType: "string" } // encrypted, not queryable
    ]
  }
};

const client = new MongoClient(uri, {
  autoEncryption: {
    keyVaultNamespace: "encryption.__keyVault",
    kmsProviders: { aws: { accessKeyId: "...", secretAccessKey: "..." } },
    encryptedFieldsMap
  }
});

// Both work on encrypted data:
await db.collection("patients").findOne({ ssn: "123-45-6789" });
await db.collection("patients").find({ age: { $gte: 21, $lte: 65 } });
```

### Key Management Architecture

```javascript
// Hierarchy: CMK (in KMS) -> DEK (encrypted in __keyVault) -> field data
const clientEncryption = new ClientEncryption(client, {
  keyVaultNamespace: "encryption.__keyVault",
  kmsProviders: { aws: { accessKeyId: "...", secretAccessKey: "..." } }
});

// Create DEK
const dekId = await clientEncryption.createDataKey("aws", {
  masterKey: { key: "arn:aws:kms:us-east-1:123456789:key/abcd-1234", region: "us-east-1" },
  keyAltNames: ["patient-data-key"]
});

// Rotate DEK (re-wraps with new CMK, does not re-encrypt all data)
await clientEncryption.rewrapManyDataKey(
  { keyAltNames: "patient-data-key" },
  { provider: "aws", masterKey: { key: "arn:aws:kms:...:new-key", region: "us-east-1" } }
);

// Required unique index on key vault
db.getSiblingDB("encryption").getCollection("__keyVault")
  .createIndex({ keyAltNames: 1 }, { unique: true,
    partialFilterExpression: { keyAltNames: { $exists: true } } });
```

### Encryption Algorithm Selection

```
Deterministic (AEAD_AES_256_CBC_HMAC_SHA_512-Deterministic):
  + Supports equality queries ($eq, $in, $ne)
  + Can be used in unique indexes
  - Same plaintext -> same ciphertext (frequency analysis possible)
  Best for: SSN, email, account number

Random (AEAD_AES_256_CBC_HMAC_SHA_512-Random):
  + Same plaintext -> different ciphertext each time
  - No queries possible
  Best for: Medical records, notes, PII not used in queries

Queryable Encryption (Structured Encryption, 7.0+):
  + Equality queries (7.0+), range queries (8.0+)
  - ~2-3x storage overhead for queryable fields
  Best for: New applications needing queries on encrypted data
```

---

## Advanced Indexing Strategies

### Covered Queries

Query is "covered" when the index contains all needed fields — no document fetch.

```javascript
db.users.createIndex({ email: 1, name: 1, status: 1 });

// Covered (all fields in index + projection, _id excluded):
db.users.find({ email: "alice@example.com" }, { _id: 0, name: 1, status: 1 }).explain("executionStats");
// Look for: totalDocsExamined: 0

// NOT covered (address not in index):
db.users.find({ email: "alice@example.com" }, { name: 1, address: 1 });
```

### Index Intersection

```javascript
// Two separate indexes CAN be combined, but compound is almost always faster
db.orders.createIndex({ status: 1 });
db.orders.createIndex({ customerId: 1 });
// Query may use intersection — verify with explain() (look for AND_SORTED stage)
// Recommendation: prefer compound { status: 1, customerId: 1 } over intersection
```

### Hidden Indexes

Test impact of dropping an index without actually dropping it (4.4+).

```javascript
db.orders.hideIndex("status_1_createdAt_-1");
// Monitor performance — if no degradation, safe to drop
db.orders.dropIndex("status_1_createdAt_-1");
// Or unhide if queries degraded:
db.orders.unhideIndex("status_1_createdAt_-1");
```

### Columnstore Indexes (7.0+)

Efficient for analytics scanning many docs but few fields.

```javascript
db.events.createIndex({ "$**": "columnstore" });

// Selective: index only specific fields
db.events.createIndex(
  { "$**": "columnstore" },
  { columnstoreProjection: { eventType: 1, duration: 1, timestamp: 1 } }
);
```
