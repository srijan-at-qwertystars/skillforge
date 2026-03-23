---
name: mongodb-patterns
description:
  positive: "Use when user works with MongoDB, asks about document schema design, embedding vs referencing, MongoDB indexes, aggregation pipeline, transactions, Mongoose ODM, or MongoDB Atlas features."
  negative: "Do NOT use for PostgreSQL, MySQL, Redis, or other databases. Do NOT use for general NoSQL concepts without MongoDB specifics."
---

# MongoDB Patterns & Best Practices

## Schema Design: Embedding vs Referencing

Use embedding when:
- One-to-few or one-to-one relationships
- Data is always read together
- Child data has no independent meaning
- Document stays well under 16 MB limit

Use referencing when:
- One-to-many or many-to-many relationships
- Data is read independently or shared across documents
- Child documents grow unboundedly
- Frequent updates to the referenced data

```js
// Embedded: user with addresses (one-to-few)
{
  _id: ObjectId("..."),
  name: "Alice",
  addresses: [
    { street: "123 Main", city: "Portland", type: "home" },
    { street: "456 Oak", city: "Seattle", type: "work" }
  ]
}

// Referenced: orders pointing to products (many-to-many)
// orders collection
{ _id: ObjectId("..."), userId: ObjectId("..."), productIds: [ObjectId("..."), ObjectId("...")] }
// products collection
{ _id: ObjectId("..."), name: "Widget", price: 29.99 }
```

## Common Schema Design Patterns
### Attribute Pattern
Collapse many similar fields into a key-value array. Use for products with variable attributes.
```js
{ _id: 1, name: "Jacket", attributes: [
    { k: "color", v: "blue" },
    { k: "size", v: "L" },
    { k: "material", v: "nylon" }
]}
// Index: { "attributes.k": 1, "attributes.v": 1 }
```
### Bucket Pattern
Group time-series or event data into fixed-size buckets. Reduce document count and index overhead.
```js
{ sensorId: "temp-01", date: ISODate("2025-01-15"),
  readings: [
    { ts: ISODate("2025-01-15T00:00:00Z"), val: 22.5 },
    { ts: ISODate("2025-01-15T00:05:00Z"), val: 22.7 }
  ],
  count: 2, sum: 45.2 }
```
### Computed Pattern
Pre-calculate aggregated values on write to avoid expensive reads.
```js
{ productId: ObjectId("..."), totalReviews: 142, avgRating: 4.3 }
// Update on new review:
db.products.updateOne({ _id: productId }, {
  $inc: { totalReviews: 1 },
  $set: { avgRating: newAvg }
})
```
### Extended Reference Pattern
Copy frequently accessed fields from the referenced document to avoid $lookup.
```js
// Order stores denormalized customer info
{ _id: ObjectId("..."), customerId: ObjectId("..."),
  customerName: "Alice", customerEmail: "alice@example.com",
  items: [...], total: 89.99 }
```
### Outlier Pattern
Handle documents that exceed normal array bounds by flagging and overflowing.
```js
{ _id: "popular-post", title: "Viral Article", commentCount: 50000,
  hasOverflow: true,
  comments: [ /* first 500 comments */ ] }
// Overflow collection stores the rest
{ postId: "popular-post", page: 2, comments: [ /* next 500 */ ] }
```
### Subset Pattern
Store a subset (e.g., most recent items) in the main document; full data lives elsewhere.
```js
{ _id: ObjectId("..."), title: "Product X",
  recentReviews: [ /* last 10 reviews */ ] }
// Full reviews in separate collection
```
### Polymorphic Pattern
Store different entity types in a single collection distinguished by a type field.
```js
{ type: "car", make: "Toyota", wheels: 4, doors: 4 }
{ type: "truck", make: "Ford", wheels: 6, payload: 5000 }
// Query all vehicles: db.vehicles.find({ make: "Toyota" })
```

## Indexing Strategies
### Index Types
```js
// Compound index — follow ESR rule (Equality, Sort, Range)
db.orders.createIndex({ status: 1, createdAt: -1, amount: 1 })

// Multikey index — automatically indexes array elements
db.posts.createIndex({ tags: 1 })

// Text index — full-text search
db.articles.createIndex({ title: "text", body: "text" })

// Wildcard index — dynamic or unpredictable field names
db.logs.createIndex({ "metadata.$**": 1 })

// Partial index — index only matching documents, smaller and faster
db.users.createIndex({ email: 1 }, { partialFilterExpression: { active: true } })

// TTL index — auto-delete documents after expiry
db.sessions.createIndex({ createdAt: 1 }, { expireAfterSeconds: 3600 })

// Unique index — enforce uniqueness
db.users.createIndex({ email: 1 }, { unique: true })
```
### ESR Rule for Compound Indexes
Order fields as: **Equality → Sort → Range** for optimal performance.
```js
// Query: find active orders, sort by date, filter amount > 100
db.orders.find({ status: "active", amount: { $gt: 100 } }).sort({ createdAt: -1 })

// Optimal index (ESR):
db.orders.createIndex({ status: 1, createdAt: -1, amount: 1 })
// status = Equality, createdAt = Sort, amount = Range
```
### Index Optimization
```js
// Use explain() to verify index usage
db.orders.find({ status: "active" }).explain("executionStats")
// Look for: stage: "IXSCAN" (good), stage: "COLLSCAN" (bad)

// Covered query — all fields in the index, no document fetch
db.orders.find({ status: "active" }, { status: 1, createdAt: 1, _id: 0 })
// Requires index: { status: 1, createdAt: 1 }

// Check index usage stats
db.orders.aggregate([{ $indexStats: {} }])

// Index prefix rule: index { a: 1, b: 1, c: 1 } supports queries on
// { a }, { a, b }, { a, b, c } — but NOT { b, c } alone
```

## Aggregation Pipeline
### Core Stages
```js
db.orders.aggregate([
  // $match — filter early to reduce pipeline volume
  { $match: { status: "completed", date: { $gte: ISODate("2025-01-01") } } },

  // $project — include/exclude fields, compute new ones
  { $project: { customerId: 1, total: 1, month: { $month: "$date" } } },

  // $group — aggregate values
  { $group: { _id: "$customerId", totalSpent: { $sum: "$total" }, count: { $sum: 1 } } },

  // $sort and $limit — always pair $limit after $sort
  { $sort: { totalSpent: -1 } },
  { $limit: 10 }
])
```
### $lookup (Join)
```js
db.orders.aggregate([
  { $lookup: {
      from: "customers",
      localField: "customerId",
      foreignField: "_id",
      as: "customer"
  }},
  { $unwind: "$customer" }  // flatten single-element array
])
// Always index the foreignField in the joined collection
```
### $facet (Multiple Aggregations in One Pass)
```js
db.products.aggregate([
  { $facet: {
      priceRanges: [
        { $bucket: { groupBy: "$price", boundaries: [0, 25, 50, 100, Infinity] } }
      ],
      topRated: [
        { $sort: { rating: -1 } }, { $limit: 5 }
      ],
      totalCount: [
        { $count: "count" }
      ]
  }}
])
```
### $merge (Write Results to Collection)
```js
db.orders.aggregate([
  { $group: { _id: "$customerId", lifetimeValue: { $sum: "$total" } } },
  { $merge: { into: "customer_stats", on: "_id", whenMatched: "replace" } }
])
```
### Pipeline Optimization Rules
- Place `$match` first to leverage indexes and reduce data volume.
- Use `$project` early to drop unnecessary fields.
- Pair `$sort` with `$limit` immediately after.
- Enable `allowDiskUse: true` for large datasets exceeding 100 MB memory limit.
- Use `explain("executionStats")` to inspect pipeline stages.

## Transactions
### Multi-Document Transactions
```js
const session = client.startSession();
try {
  session.startTransaction({
    readConcern: { level: "snapshot" },
    writeConcern: { w: "majority" },
    readPreference: "primary"
  });

  await db.collection("accounts").updateOne(
    { _id: fromId }, { $inc: { balance: -amount } }, { session }
  );
  await db.collection("accounts").updateOne(
    { _id: toId }, { $inc: { balance: amount } }, { session }
  );
  await db.collection("transfers").insertOne(
    { from: fromId, to: toId, amount, date: new Date() }, { session }
  );

  await session.commitTransaction();
} catch (error) {
  await session.abortTransaction();
  throw error;
} finally {
  session.endSession();
}
```
### Transaction Retry Logic
```js
async function runWithRetry(txnFunc, client, maxRetries = 3) {
  const session = client.startSession();
  try {
    for (let attempt = 0; attempt < maxRetries; attempt++) {
      try {
        await session.withTransaction(txnFunc, {
          readConcern: { level: "snapshot" },
          writeConcern: { w: "majority" }
        });
        return; // success
      } catch (error) {
        if (error.hasErrorLabel("TransientTransactionError") && attempt < maxRetries - 1) {
          continue; // retry
        }
        throw error;
      }
    }
  } finally {
    session.endSession();
  }
}
```
### Transaction Guidelines
- Keep transactions short — long-running transactions hold locks and degrade performance.
- Limit to 1000 documents modified per transaction when possible.
- Require replica set or sharded cluster (not standalone).
- Use `session.withTransaction()` for automatic retry on transient errors.
- Prefer single-document atomicity when possible — no transaction needed.

## Mongoose ODM Patterns
### Schema Definition with Validation
```js
const userSchema = new mongoose.Schema({
  email: { type: String, required: true, unique: true, lowercase: true, trim: true },
  name: { type: String, required: true, minlength: 2, maxlength: 100 },
  role: { type: String, enum: ["user", "admin", "moderator"], default: "user" },
  profile: {
    bio: { type: String, maxlength: 500 },
    avatar: String
  },
  createdAt: { type: Date, default: Date.now, immutable: true }
}, { timestamps: true });
```
### Virtuals
```js
userSchema.virtual("displayName").get(function () {
  return `${this.name} (${this.role})`;
});
// Enable virtuals in JSON: { toJSON: { virtuals: true } }
```
### Middleware (Hooks)
```js
userSchema.pre("save", async function (next) {
  if (this.isModified("password")) {
    this.password = await bcrypt.hash(this.password, 12);
  }
  next();
});

userSchema.post("findOneAndDelete", async function (doc) {
  if (doc) await Comment.deleteMany({ userId: doc._id });
});
```
### Populate (Reference Resolution)
```js
const postSchema = new mongoose.Schema({
  author: { type: mongoose.Schema.Types.ObjectId, ref: "User" },
  title: String, body: String
});

// Populate on query
const posts = await Post.find().populate("author", "name email").lean();
```
### Lean Queries
Use `.lean()` for read-only operations — returns plain JS objects, skips Mongoose overhead.
```js
const users = await User.find({ active: true }).lean(); // 2-5x faster reads
```
### Discriminators (Inheritance)
```js
const eventSchema = new mongoose.Schema({ date: Date, location: String });
const Event = mongoose.model("Event", eventSchema);

const ClickEvent = Event.discriminator("ClickEvent",
  new mongoose.Schema({ element: String, page: String }));
const PurchaseEvent = Event.discriminator("PurchaseEvent",
  new mongoose.Schema({ productId: ObjectId, amount: Number }));
// All stored in "events" collection with __t discriminator key
```

## Query Optimization
### Projection — Fetch Only Needed Fields
```js
db.users.find({ active: true }, { name: 1, email: 1, _id: 0 })
```
### Cursor-Based Pagination (Prefer Over skip/limit)
```js
// First page
const page1 = await db.orders.find().sort({ _id: 1 }).limit(20).toArray();

// Next page — use last document's _id as cursor
const lastId = page1[page1.length - 1]._id;
const page2 = await db.orders.find({ _id: { $gt: lastId } }).sort({ _id: 1 }).limit(20).toArray();
```
### Read Preferences
```js
// Read from secondaries for analytics (eventual consistency)
db.reports.find().readPref("secondaryPreferred");

// Read from primary for real-time data (strong consistency)
db.accounts.find().readPref("primary");
```

## Change Streams

```js
const pipeline = [{ $match: { operationType: { $in: ["insert", "update"] } } }];
const changeStream = db.collection("orders").watch(pipeline, { fullDocument: "updateLookup" });

changeStream.on("change", (change) => {
  console.log(change.operationType, change.fullDocument);
});

// Resume after failure using resume token
const resumeToken = change._id;
const resumed = collection.watch(pipeline, { resumeAfter: resumeToken });
```
### Change Stream Guidelines
- Require replica set or sharded cluster.
- Store resume tokens persistently for crash recovery.
- Use pipeline filters to reduce event volume.
- Prefer `next()` over event emitters in serverless contexts.
- Use `fullDocument: "updateLookup"` only when needed — adds a read per event.

## Sharding Strategies
### Shard Key Selection Criteria
- **High cardinality** — many distinct values to distribute evenly.
- **Low frequency** — no single value dominates writes.
- **Non-monotonic** — avoid sequential keys (e.g., ObjectId, timestamps) for ranged sharding.
### Hashed vs Ranged Sharding
```js
// Hashed — even distribution, no range queries on shard key
sh.shardCollection("mydb.events", { userId: "hashed" })

// Ranged — supports range queries, risk of hot spots with sequential keys
sh.shardCollection("mydb.logs", { timestamp: 1 })

// Compound shard key — balance distribution with query targeting
sh.shardCollection("mydb.orders", { region: 1, orderId: 1 })
```
### Zone Sharding (Data Locality)
```js
// Assign data to specific shards by region
sh.addShardTag("shard01", "US")
sh.addTagRange("mydb.users", { region: "US" }, { region: "US~" }, "US")
```

## Security
### Authentication and Authorization
```js
// Create user with role-based access
db.createUser({
  user: "appUser",
  pwd: "securePassword",
  roles: [{ role: "readWrite", db: "myapp" }]
})

// Enable authentication in mongod.conf
// security:
//   authorization: enabled
```
### Field-Level Encryption (Client-Side)
```js
// MongoDB CSFLE — encrypt sensitive fields before storage
const encryptedFieldsMap = {
  "mydb.users": {
    fields: [
      { path: "ssn", bsonType: "string", keyId: dataKeyId,
        queries: { queryType: "equality" } },
      { path: "medicalRecord", bsonType: "object", keyId: dataKeyId }
    ]
  }
};
// Use AutoEncryptionOpts in MongoClient for transparent encryption
```
### Security Checklist
- Enable authentication and RBAC in all environments.
- Use TLS/SSL for all connections. Enable audit logging for compliance.
- Restrict network access with IP allowlists or VPC peering.
- Rotate credentials regularly. Use SCRAM-SHA-256 or x.509 certificates.
- Apply field-level encryption for PII and sensitive data.

## Common Anti-Patterns
### Unbounded Arrays
Never let arrays grow without limit. Use the bucket or outlier pattern instead.
```js
// BAD: pushing to an unbounded array
db.posts.updateOne({ _id: postId }, { $push: { comments: newComment } })
// Array grows forever → exceeds 16 MB → performance degrades

// GOOD: separate collection or bucket pattern
db.comments.insertOne({ postId, text: "...", createdAt: new Date() })
```
### Missing Indexes
Run `explain()` on every query in production. A COLLSCAN on a large collection causes full table scans.
```js
// Detect missing indexes
db.orders.find({ customerId: id }).explain("executionStats")
// If totalDocsExamined >> nReturned, add an index
```
### Unnecessary $lookup
Avoid $lookup in hot paths. Denormalize with the extended reference pattern for frequently joined data.
### Over-Normalization
Do not replicate a relational schema in MongoDB. Embed data read together.
### Deep Pagination with skip()
`skip(10000)` scans and discards 10,000 documents. Use cursor-based pagination.
### Large Documents as Queues
Do not use MongoDB as a message queue. Use change streams or a dedicated queue.
### Ignoring Write Concern
Use `w: "majority"` for critical writes. Default `w: 1` risks data loss on failover.
```js
db.payments.insertOne(doc, { writeConcern: { w: "majority", j: true } })
```
