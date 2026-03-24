---
name: mongodb-patterns
description: >
  MongoDB 7.x/8.x patterns: CRUD, aggregation ($match, $group, $lookup, $unwind,
  $project, $merge), indexing (compound, text, geospatial, TTL, partial, wildcard),
  schema design (embedding vs referencing, polymorphic, bucket, outlier), replica
  sets, sharding, transactions, change streams, Atlas Search/Vector Search,
  Mongoose ODM, performance tuning (explain, profiler, $queryStats), security
  (SCRAM-SHA-256, x.509, RBAC, Queryable Encryption).
  TRIGGERS: MongoDB, mongosh, aggregation pipeline, MongoDB Atlas, MongoDB replica
  set, mongoose, BSON, MongoDB indexes, change streams, mongod, $lookup, sharding
  key, ObjectId, GridFS, MongoDB Compass.
  NOT for PostgreSQL, MySQL, Redis, DynamoDB, CouchDB, or general NoSQL concepts
  without MongoDB context.
---

# MongoDB Patterns

## CRUD Operations

### Insert
```javascript
// insertOne returns { acknowledged, insertedId }
db.orders.insertOne({ item: "widget", qty: 25, price: 9.99, tags: ["sale"] });

// insertMany with ordered:false continues on error
db.orders.insertMany([
  { item: "bolt", qty: 100, price: 1.50 },
  { item: "nut", qty: 200, price: 0.75 }
], { ordered: false });
```

### Read
```javascript
// Projection: include fields (1) or exclude (0), never mix except _id
db.orders.find({ qty: { $gte: 50 } }, { item: 1, qty: 1, _id: 0 });

// Cursor methods chain: filter → sort → skip → limit
db.orders.find({ price: { $lt: 10 } }).sort({ qty: -1 }).skip(10).limit(5);
```

### Update
```javascript
// updateOne with upsert — creates doc if no match
db.orders.updateOne(
  { item: "widget" },
  { $set: { qty: 30 }, $currentDate: { lastModified: true } },
  { upsert: true }
);

// findOneAndUpdate returns the modified document
db.orders.findOneAndUpdate(
  { item: "bolt" },
  { $inc: { qty: -10 } },
  { returnDocument: "after", projection: { item: 1, qty: 1 } }
);

// bulkWrite for mixed operations (MongoDB 8.0: 56% faster bulk writes)
db.orders.bulkWrite([
  { updateMany: { filter: { price: { $lt: 2 } }, update: { $set: { discount: true } } } },
  { deleteMany: { filter: { qty: 0 } } }
]);
```

### Delete
```javascript
db.orders.deleteOne({ item: "obsolete" });
db.orders.deleteMany({ qty: { $lt: 1 }, status: "cancelled" });
```

---

## Aggregation Pipeline

### Core Stages
```javascript
db.sales.aggregate([
  // $match: filter early to reduce pipeline data volume
  { $match: { status: "completed", date: { $gte: ISODate("2024-01-01") } } },

  // $lookup: left outer join
  { $lookup: {
      from: "products",
      localField: "productId",
      foreignField: "_id",
      as: "product"
  }},

  // $unwind: deconstruct array (preserveNullAndEmptyArrays keeps non-matches)
  { $unwind: { path: "$product", preserveNullAndEmptyArrays: true } },

  // $group: aggregate values
  { $group: {
      _id: { category: "$product.category", month: { $month: "$date" } },
      totalRevenue: { $sum: { $multiply: ["$qty", "$price"] } },
      avgOrderSize: { $avg: "$qty" },
      orderCount: { $sum: 1 }
  }},

  // $project: reshape output
  { $project: {
      _id: 0,
      category: "$_id.category",
      month: "$_id.month",
      totalRevenue: { $round: ["$totalRevenue", 2] },
      avgOrderSize: 1,
      orderCount: 1
  }},

  // $sort then $limit
  { $sort: { totalRevenue: -1 } },
  { $limit: 10 }
]);
```

See [advanced-patterns.md](references/advanced-patterns.md) for `$facet`, `$bucket`, `$graphLookup`, `$merge`, `$out`, `$setWindowFields`, and pipeline optimization.

---

## Indexing Strategies

### Compound Index (ESR Rule: Equality → Sort → Range)
```javascript
// Query: find active users in region, sorted by createdAt
// Optimal order: equality(status, region) → sort(createdAt) → range(age)
db.users.createIndex({ status: 1, region: 1, createdAt: -1, age: 1 });
```

### Text Index
```javascript
db.articles.createIndex({ title: "text", body: "text" }, { weights: { title: 10, body: 1 } });
db.articles.find({ $text: { $search: "\"mongodb\" aggregation -deprecated" } },
                  { score: { $meta: "textScore" } }).sort({ score: { $meta: "textScore" } });
```

### Geospatial (2dsphere)
```javascript
db.places.createIndex({ location: "2dsphere" });
db.places.find({ location: {
  $near: { $geometry: { type: "Point", coordinates: [-73.97, 40.77] }, $maxDistance: 5000 }
}});
```

### TTL Index (Auto-expire documents)
```javascript
// Documents expire 30 days after createdAt
db.sessions.createIndex({ createdAt: 1 }, { expireAfterSeconds: 2592000 });
```

### Partial Index (Index subset of documents)
```javascript
// Only index active orders — smaller index, faster writes
db.orders.createIndex(
  { customerId: 1, orderDate: -1 },
  { partialFilterExpression: { status: "active" } }
);
```

### Wildcard Index (Dynamic/polymorphic schemas)
```javascript
db.products.createIndex({ "attributes.$**": 1 });
// Supports queries on any subfield: attributes.color, attributes.size, etc.
```

---

## Schema Design Patterns

### Embedding vs Referencing Decision Matrix
| Factor               | Embed                        | Reference                    |
|----------------------|------------------------------|------------------------------|
| Read pattern         | Data read together           | Data read independently      |
| Cardinality          | 1:few or 1:many (bounded)    | 1:many (unbounded), many:many|
| Document size        | Combined < 16MB              | Risk of exceeding 16MB       |
| Write pattern        | Infrequent child updates     | Frequent independent updates |
| Atomicity needed     | Yes (single-doc atomicity)   | Can use transactions         |

### Polymorphic Pattern
```javascript
// Single collection, different shapes, shared base fields
{ _id: 1, type: "book", title: "MongoDB Guide", isbn: "978-...", pages: 400 }
{ _id: 2, type: "video", title: "MongoDB Course", url: "https://...", duration: 3600 }
// Query all: db.media.find({ title: /MongoDB/ })
// Query specific: db.media.find({ type: "book", pages: { $gt: 300 } })
```

### Bucket Pattern (Time-series / IoT)
```javascript
// Group measurements into time buckets — reduces document count
{ sensorId: "temp-01", bucketStart: ISODate("2024-06-01T00:00:00Z"), count: 60,
  measurements: [{ ts: ISODate("...T00:00Z"), value: 22.5 }, ...],
  summary: { min: 22.1, max: 23.4, avg: 22.8 } }
// Native time-series collections (7.x/8.x — automatic bucketing, 200% faster aggs in 8.0):
db.createCollection("temperatures", {
  timeseries: { timeField: "ts", metaField: "sensorId", granularity: "minutes" }
});
```

### Outlier Pattern
```javascript
// Main doc (99%): { _id: "movie1", title: "Film", fans: ["u1","u2"], fanCount: 2 }
// Outlier (1%): { _id: "movie2", title: "Blockbuster", hasOverflow: true, fanCount: 500000 }
// Overflow: separate collection { movieId: "movie2", fans: ["u3", ...] }
```

### Subset Pattern
```javascript
// Embed only recent subset; full data in separate collection
{ _id: "p1", name: "Widget", recentReviews: [/* last 10 */], reviewCount: 2847 }
// Full reviews: db.reviews.find({ productId: "p1" })
```

---

## Replica Sets

```javascript
// Initialize a 3-node replica set
rs.initiate({
  _id: "myRS",
  members: [
    { _id: 0, host: "mongo1:27017", priority: 2 },  // preferred primary
    { _id: 1, host: "mongo2:27017", priority: 1 },
    { _id: 2, host: "mongo3:27017", priority: 1 }
  ]
});

// Read preference: balance reads across secondaries
db.orders.find().readPref("secondaryPreferred");

// Write concern: majority ensures durability
db.orders.insertOne({ item: "x" }, { writeConcern: { w: "majority", wtimeout: 5000 } });
```

---

## Sharding

```javascript
// Enable sharding on database and shard a collection
sh.enableSharding("ecommerce");

// Hashed shard key: even distribution, no range queries on shard key
sh.shardCollection("ecommerce.orders", { customerId: "hashed" });

// Ranged shard key: supports range queries, risk of hot spots
sh.shardCollection("ecommerce.logs", { timestamp: 1 });

// Compound shard key: balance distribution + query isolation
sh.shardCollection("ecommerce.events", { tenantId: 1, eventDate: 1 });
```
**Shard key selection rules**: high cardinality, low frequency, non-monotonic. Avoid `_id` (ObjectId) as sole ranged shard key — causes insert hotspot on last chunk. MongoDB 8.0 supports resharding up to 50x faster.

---

## Transactions

```javascript
const session = client.startSession();
try {
  session.startTransaction({
    readConcern: { level: "snapshot" },
    writeConcern: { w: "majority" },
    readPreference: "primary"
  });

  const accounts = client.db("bank").collection("accounts");
  await accounts.updateOne({ _id: "A" }, { $inc: { balance: -100 } }, { session });
  await accounts.updateOne({ _id: "B" }, { $inc: { balance: 100 } }, { session });

  await session.commitTransaction();
} catch (e) {
  await session.abortTransaction();
  throw e;
} finally {
  await session.endSession();
}
// Keep transactions short (<60s default timeout). Avoid cross-shard when possible.
// MongoDB 8.0: batch inserts in transactions generate fewer oplog entries.
```

---

## Change Streams

```javascript
// Watch for real-time changes — resume on failure with resumeToken
const pipeline = [
  { $match: { "fullDocument.status": "urgent", operationType: { $in: ["insert", "update"] } } }
];
const changeStream = db.collection("tickets").watch(pipeline, {
  fullDocument: "updateLookup",       // include full doc on updates
  fullDocumentBeforeChange: "required" // MongoDB 6.0+: include pre-image
});

changeStream.on("change", (event) => {
  console.log(event.operationType, event.fullDocument);
  // Store event._id (resumeToken) for crash recovery
});

// Resume after failure:
const resumedStream = db.collection("tickets").watch(pipeline, {
  resumeAfter: savedResumeToken
});
```

---

## Atlas Features

```javascript
// Atlas Search (Lucene-based full-text search)
db.products.aggregate([
  { $search: {
      index: "product_search",
      compound: {
        must: [{ text: { query: "wireless", path: "description" } }],
        filter: [{ range: { path: "price", gte: 10, lte: 100 } }]
      }
  }},
  { $limit: 20 },
  { $project: { name: 1, price: 1, score: { $meta: "searchScore" } } }
]);

// Atlas Vector Search (MongoDB 7.0+, enhanced in 8.0 with quantized vectors)
db.docs.aggregate([
  { $vectorSearch: {
      index: "vector_index",
      path: "embedding",
      queryVector: [0.1, 0.2, ...],  // 1536-dim for OpenAI embeddings
      numCandidates: 150,
      limit: 10
  }}
]);
```

---

## Mongoose ODM Patterns

```javascript
import mongoose from 'mongoose';
const { Schema, model } = mongoose;

const userSchema = new Schema({
  email:    { type: String, required: true, unique: true, lowercase: true, trim: true },
  name:     { type: String, required: true, maxlength: 100 },
  role:     { type: String, enum: ['user', 'admin', 'moderator'], default: 'user' },
  profile:  { bio: String, avatar: String },
  teamId:   { type: Schema.Types.ObjectId, ref: 'Team' },
}, { timestamps: true, toJSON: { virtuals: true } });

userSchema.virtual('isAdmin').get(function() { return this.role === 'admin'; });
userSchema.pre('save', async function(next) { /* middleware */ next(); });
userSchema.statics.findByEmail = function(email) {
  return this.findOne({ email: email.toLowerCase() });
};
const User = model('User', userSchema);

// Populate references; lean() returns plain objects (2-5x faster)
const user = await User.findById(id).populate('teamId', 'name -_id').lean();

// Aggregation passes pipeline directly to MongoDB driver
const stats = await User.aggregate([
  { $group: { _id: "$role", count: { $sum: 1 } } }
]);
```

---

## Performance Tuning

### Explain Plans
```javascript
// Use "executionStats" to see actual performance
db.orders.find({ status: "active" }).explain("executionStats");
// Key metrics:
//   executionStats.totalDocsExamined — should be close to nReturned
//   executionStats.executionStages.stage — IXSCAN good, COLLSCAN bad
//   queryPlanner.winningPlan.inputStage — shows index used

// Aggregation explain
db.orders.explain("executionStats").aggregate([...]);
```

### Database Profiler
```javascript
// Level 0: off, 1: slow ops, 2: all ops
db.setProfilingLevel(1, { slowms: 100 });
// MongoDB 8.0: use workingMillis for server processing time (excludes network)
db.system.profile.find({ millis: { $gt: 100 } }).sort({ ts: -1 }).limit(5);
```

### Common Fixes
- **COLLSCAN → IXSCAN**: Add index matching query predicates (ESR rule)
- **High docsExamined/nReturned ratio**: Refine index or add covered query projection
- **Sort in memory**: Add sort fields to index; avoid in-memory sorts >100MB
- **$lookup slow**: Index the foreign field; consider embedding if read-heavy

See [troubleshooting.md](references/troubleshooting.md) for comprehensive diagnosis and fixes.

---

## Security

### Authentication
```javascript
// SCRAM-SHA-256 (default in 7.x/8.x)
mongosh "mongodb://user:pass@host:27017/mydb?authMechanism=SCRAM-SHA-256"

// x.509 certificate auth
mongosh --tls --tlsCertificateKeyFile client.pem \
  --tlsCAFile ca.pem --authenticationMechanism MONGODB-X509
```

### Role-Based Access Control (RBAC)
```javascript
db.createUser({ user: "appUser", pwd: passwordPrompt(),
  roles: [{ role: "readWrite", db: "ecommerce" }, { role: "read", db: "analytics" }]
});

// Custom role: read + specific collection write
db.createRole({
  role: "orderProcessor",
  privileges: [{
    resource: { db: "ecommerce", collection: "orders" },
    actions: ["find", "update", "insert"]
  }],
  roles: [{ role: "read", db: "ecommerce" }]
});
```

### Queryable Encryption (MongoDB 7.0+)
```javascript
const encryptedClient = new MongoClient(uri, { autoEncryption: {
  keyVaultNamespace: "encryption.__keyVault",
  kmsProviders: { aws: { accessKeyId: "...", secretAccessKey: "..." } },
  encryptedFieldsMap: { "mydb.patients": { fields: [
    { path: "ssn", bsonType: "string", queries: { queryType: "equality" } },
    { path: "billing.amount", bsonType: "int", queries: { queryType: "range" } } // 8.0: range queries
  ]}}
}});
```

---

## Quick Reference: mongosh Commands

```javascript
show dbs                          // list databases
use mydb                          // switch database
show collections                  // list collections
db.stats()                        // database statistics
db.coll.getIndexes()              // list indexes
db.coll.createIndex({f:1})        // create index
db.coll.countDocuments({f:"v"})   // count with filter
db.coll.estimatedDocumentCount()  // fast approximate count
db.currentOp()                    // running operations
db.killOp(opId)                   // kill an operation
sh.status()                       // sharding status
```

---

## Reference Guides

Deep-dive documentation in `references/`:

| Guide | Topics |
|-------|--------|
| [advanced-patterns.md](references/advanced-patterns.md) | Aggregation deep dive ($facet, $bucket, $graphLookup, $merge, $out, $setWindowFields), Atlas Search (Lucene analyzers, autocomplete, compound queries, facets), Atlas Vector Search (hybrid search, embeddings), Queryable Encryption (equality + range), time series collections, schema versioning, capped collections |
| [troubleshooting.md](references/troubleshooting.md) | Slow queries (explain analysis, covered queries), WiredTiger cache tuning, connection pool exhaustion, replication lag, sharding hotspots, index selection problems, write concern errors, lock contention, RDBMS migration pitfalls |
| [mongoose-guide.md](references/mongoose-guide.md) | Schemas (types, validation, nested), virtuals, methods/statics/query helpers, middleware (document, query, aggregate, error), population, discriminators, lean queries, transactions, plugins, connection management, migration strategies, full TypeScript integration |

---

## Scripts

Operational scripts in `scripts/` (all `chmod +x`):

| Script | Purpose | Usage |
|--------|---------|-------|
| [mongo-health-check.sh](scripts/mongo-health-check.sh) | Checks replica set status, connections, oplog window, disk/cache usage, slow ops | `./mongo-health-check.sh --uri "mongodb+srv://..."` |
| [index-analyzer.js](scripts/index-analyzer.js) | Finds unused, redundant, and missing indexes across collections | `node index-analyzer.js --db myapp --unused-days 7` |
| [backup-restore.sh](scripts/backup-restore.sh) | mongodump/mongorestore wrapper with compression, Atlas support, retention | `./backup-restore.sh backup --db myapp --gzip` |

---

## Assets

Templates and configurations in `assets/`:

| Asset | Description |
|-------|-------------|
| [aggregation-templates.js](assets/aggregation-templates.js) | Ready-to-use pipelines: daily revenue, top products, cohort analysis, funnel, moving averages, sessionization, ETL with $merge, data quality |
| [mongoose-model-template.ts](assets/mongoose-model-template.ts) | Full TypeScript Mongoose model with typed methods, statics, virtuals, query helpers, middleware, indexes, and plugins |
| [docker-compose-mongo.yml](assets/docker-compose-mongo.yml) | Docker Compose for 3-node replica set with auto-init and Mongo Express UI |
| [mongosh-snippets.js](assets/mongosh-snippets.js) | Helper functions for mongosh: collection stats, schema shape, index usage, slow queries, replica lag, field distribution, large docs |
| [atlas-terraform.tf](assets/atlas-terraform.tf) | Terraform config for Atlas: project, cluster, users, network access, search index, alerts |

<!-- tested: pass -->
