# MongoDB Troubleshooting Guide

## Table of Contents

- [Slow Queries](#slow-queries)
  - [Using explain() Effectively](#using-explain-effectively)
  - [Reading Execution Stats](#reading-execution-stats)
  - [Covered Queries](#covered-queries)
  - [Common Slow Query Patterns](#common-slow-query-patterns)
- [Memory Issues](#memory-issues)
  - [WiredTiger Cache Tuning](#wiredtiger-cache-tuning)
  - [Diagnosing Memory Pressure](#diagnosing-memory-pressure)
  - [Aggregation Memory Limits](#aggregation-memory-limits)
- [Connection Pool Exhaustion](#connection-pool-exhaustion)
  - [Diagnosing Connection Issues](#diagnosing-connection-issues)
  - [Connection Pool Sizing](#connection-pool-sizing)
  - [Connection Leak Detection](#connection-leak-detection)
- [Replication Lag](#replication-lag)
  - [Measuring Lag](#measuring-lag)
  - [Common Causes](#common-causes)
  - [Fixing Replication Lag](#fixing-replication-lag)
- [Sharding Hotspots](#sharding-hotspots)
  - [Identifying Hotspots](#identifying-hotspots)
  - [Shard Key Problems](#shard-key-problems)
  - [Jumbo Chunks](#jumbo-chunks)
  - [Balancer Tuning](#balancer-tuning)
- [Index Selection Problems](#index-selection-problems)
  - [Index Not Being Used](#index-not-being-used)
  - [Wrong Index Selected](#wrong-index-selected)
  - [Index Intersection](#index-intersection)
  - [Unused and Redundant Indexes](#unused-and-redundant-indexes)
- [Write Concern Errors](#write-concern-errors)
  - [Write Concern Levels](#write-concern-levels)
  - [Common Write Concern Errors](#common-write-concern-errors)
  - [Diagnosing Write Failures](#diagnosing-write-failures)
- [Lock Contention](#lock-contention)
  - [Understanding MongoDB Locks](#understanding-mongodb-locks)
  - [Identifying Lock Contention](#identifying-lock-contention)
  - [Reducing Lock Contention](#reducing-lock-contention)
- [Migration from RDBMS Pitfalls](#migration-from-rdbms-pitfalls)
  - [Schema Design Anti-Patterns](#schema-design-anti-patterns)
  - [Query Translation Mistakes](#query-translation-mistakes)
  - [Transaction Over-Use](#transaction-over-use)
  - [Missing Denormalization](#missing-denormalization)
  - [Migration Strategy](#migration-strategy)

---

## Slow Queries

### Using explain() Effectively

```javascript
// Three verbosity levels
db.orders.find({ status: "active" }).explain("queryPlanner");      // default: plan only
db.orders.find({ status: "active" }).explain("executionStats");    // + execution metrics
db.orders.find({ status: "active" }).explain("allPlansExecution"); // + rejected plan stats

// Aggregation explain
db.orders.explain("executionStats").aggregate([
  { $match: { status: "active" } },
  { $group: { _id: "$customerId", total: { $sum: "$amount" } } }
]);

// Profile slow queries automatically
db.setProfilingLevel(1, { slowms: 50 });

// Query the profiler
db.system.profile.find({
  millis: { $gt: 100 },
  ns: "mydb.orders"
}).sort({ ts: -1 }).limit(10);
```

### Reading Execution Stats

```javascript
const stats = db.orders.find({ status: "active", amount: { $gt: 100 } })
  .explain("executionStats");

// Key metrics to check:
// 1. COLLSCAN vs IXSCAN
stats.queryPlanner.winningPlan.stage
// COLLSCAN = full collection scan (bad for large collections)
// IXSCAN = index scan (good)

// 2. Documents examined vs returned ratio
stats.executionStats.totalDocsExamined    // docs MongoDB read
stats.executionStats.nReturned            // docs returned to client
// Ideal: ratio close to 1.0. Ratio > 10 = inefficient query

// 3. Keys examined
stats.executionStats.totalKeysExamined    // index entries scanned
// If keysExamined >> nReturned, index not selective enough

// 4. Execution time
stats.executionStats.executionTimeMillis  // total time

// 5. Sort in memory
stats.executionStats.executionStages.sortStage
// If present with memUsage high, add sort fields to index

// Red flags in explain output:
// - stage: "COLLSCAN" on large collections
// - totalDocsExamined >> nReturned
// - "SORT" stage with large memUsage (risk of 100MB sort limit)
// - "FETCH" after "IXSCAN" when all fields could be covered by index
```

### Covered Queries

A covered query is answered entirely from the index without touching documents — the fastest possible query.

```javascript
// Index
db.orders.createIndex({ status: 1, customerId: 1, amount: 1 });

// Covered query: only request indexed fields, exclude _id
db.orders.find(
  { status: "active", customerId: "cust123" },
  { status: 1, customerId: 1, amount: 1, _id: 0 }
).explain("executionStats");
// totalDocsExamined: 0 (no document fetches!)
// totalKeysExamined ≈ nReturned

// NOT covered (requesting non-indexed field):
db.orders.find(
  { status: "active" },
  { status: 1, orderDate: 1, _id: 0 }  // orderDate not in index
);

// NOT covered (including _id without it in index):
db.orders.find({ status: "active" }, { status: 1, amount: 1 });
// _id included by default — must explicitly exclude
```

### Common Slow Query Patterns

```javascript
// 1. Regex without prefix anchor — cannot use index
db.users.find({ name: /smith/i });             // COLLSCAN
db.users.find({ name: /^Smith/ });             // IXSCAN (anchored)

// 2. $ne and $nin — scan entire index
db.orders.find({ status: { $ne: "cancelled" } });   // scans all
// Fix: query for specific values you want
db.orders.find({ status: { $in: ["active", "shipped", "delivered"] } });

// 3. Large $in arrays
db.orders.find({ productId: { $in: arrayOf10000Ids } });
// Fix: batch into smaller $in queries or restructure

// 4. Unindexed $or branches
db.coll.find({ $or: [{ a: 1 }, { b: 2 }] });
// Each branch needs its own index

// 5. Array field queries without multikey index considerations
db.orders.find({ "items.sku": "ABC123" });
// Multikey indexes have limitations with compound keys and sorts

// 6. Sorting without index support
db.orders.find({ status: "active" }).sort({ amount: -1 });
// If no index covers both filter + sort, sort happens in memory
// Fix: compound index { status: 1, amount: -1 }

// 7. Skip() with large offsets
db.products.find().sort({ _id: 1 }).skip(100000).limit(20);
// Fix: range-based pagination
db.products.find({ _id: { $gt: lastSeenId } }).sort({ _id: 1 }).limit(20);
```

---

## Memory Issues

### WiredTiger Cache Tuning

```javascript
// Check current cache usage
db.serverStatus().wiredTiger.cache
// Key fields:
//   "bytes currently in the cache"
//   "maximum bytes configured"
//   "tracked dirty bytes in the cache"
//   "pages evicted by application threads" — if high, cache too small

// Default: 50% of (RAM - 1GB), minimum 256MB
// Set in mongod.conf:
// storage:
//   wiredTiger:
//     engineConfig:
//       cacheSizeGB: 4

// Runtime adjustment (requires restart-free in 7.0+)
db.adminCommand({
  setParameter: 1,
  wiredTigerEngineRuntimeConfig: "cache_size=4G"
});
```

**Cache sizing guidelines:**
- Working set (frequently accessed data + indexes) should fit in cache
- Monitor "pages read into cache" vs "pages evicted" — high eviction = cache pressure
- Dirty cache ratio > 20% sustained = increase cache or reduce write rate
- Reserved: OS needs ~15-20% of RAM for filesystem cache

### Diagnosing Memory Pressure

```javascript
// Server status memory metrics
const ss = db.serverStatus();

// WiredTiger cache stats
const cache = ss.wiredTiger.cache;
console.log("Cache size:", cache["maximum bytes configured"] / 1024 / 1024, "MB");
console.log("In cache:", cache["bytes currently in the cache"] / 1024 / 1024, "MB");
console.log("Dirty:", cache["tracked dirty bytes in the cache"] / 1024 / 1024, "MB");
console.log("Read into cache:", cache["pages read into cache"]);
console.log("Evicted:", cache["pages evicted by application threads"]);

// High eviction by app threads = critical — queries doing eviction work
if (cache["pages evicted by application threads"] > 0) {
  console.warn("Application thread eviction detected — increase cache!");
}

// Index sizes — ensure frequently used indexes fit in RAM
db.orders.stats().indexSizes
// { "_id_": 2048000, "status_1_date_-1": 5120000 }

// Total index size for database
db.stats().indexSize  // bytes

// Per-collection memory use
db.orders.stats({ scale: 1048576 });  // scale to MB
```

### Aggregation Memory Limits

```javascript
// Default: 100MB per pipeline stage in memory
// Exceeded: "Sort exceeded memory limit" or "Exceeded memory limit"

// Option 1: Enable disk use
db.orders.aggregate([...], { allowDiskUse: true });

// Option 2: Reduce data early in pipeline
db.orders.aggregate([
  { $match: { date: { $gte: ISODate("2024-01-01") } } },  // filter first
  { $project: { amount: 1, category: 1 } },                // drop fields
  { $group: { _id: "$category", total: { $sum: "$amount" } } }
]);

// Option 3: Increase per-stage limit (MongoDB 6.0+, use cautiously)
db.adminCommand({
  setParameter: 1,
  internalQueryMaxBlockingSortMemoryUsageBytes: 209715200  // 200MB
});

// $group memory optimization: use $accumulator sparingly
// $push into arrays grows unbounded — use $topN/$bottomN instead
db.orders.aggregate([
  { $group: {
    _id: "$category",
    topOrders: { $topN: { n: 10, sortBy: { amount: -1 }, output: "$amount" } }
  }}
]);
```

---

## Connection Pool Exhaustion

### Diagnosing Connection Issues

```javascript
// Check current connections
db.serverStatus().connections
// {
//   "current": 150,      // active connections
//   "available": 51050,  // remaining capacity
//   "totalCreated": 5000 // total since startup
// }

// Per-client connection tracking
db.currentOp(true).inprog.length  // all operations including idle

// Find long-running operations holding connections
db.currentOp({ "secs_running": { $gte: 30 }, "op": { $ne: "none" } });

// Connection source breakdown
db.aggregate([
  { $currentOp: { allUsers: true, idleConnections: true } },
  { $group: { _id: "$appName", count: { $sum: 1 } } },
  { $sort: { count: -1 } }
]);
```

**maxPoolSize defaults:**
| Driver | Default | Max |
|---|---|---|
| Node.js | 100 | Unlimited |
| Python (PyMongo) | 100 | Unlimited |
| Java | 100 | Unlimited |
| mongosh | 1 | 1 |

### Connection Pool Sizing

```javascript
// Node.js driver — configure pool
const client = new MongoClient(uri, {
  maxPoolSize: 50,          // max connections per mongos/mongod
  minPoolSize: 5,           // pre-warm connections
  maxIdleTimeMS: 30000,     // close idle connections after 30s
  waitQueueTimeoutMS: 5000, // fail if can't get connection in 5s
  connectTimeoutMS: 10000,
  serverSelectionTimeoutMS: 15000,
  socketTimeoutMS: 300000,  // 5 minutes for long operations
  maxConnecting: 2          // concurrent connection establishment limit
});

// Connection string equivalent
// mongodb://host:27017/?maxPoolSize=50&minPoolSize=5&maxIdleTimeMS=30000

// Rule of thumb: maxPoolSize = ceil(concurrent_operations / mongos_count)
// For 200 concurrent ops across 4 mongos: maxPoolSize = 50 per mongos

// Atlas connection limits:
// M10: 350, M20: 700, M30: 1500, M40: 3000, M50: 5000, M60+: 16000+
```

### Connection Leak Detection

```javascript
// Symptom: "current" connections grows steadily, never drops
// Common causes:
// 1. Not closing MongoClient on app shutdown
// 2. Creating new MongoClient per request
// 3. Unclosed cursors or change streams

// BAD: new client per request
app.get("/users", async (req, res) => {
  const client = new MongoClient(uri);  // leak!
  await client.connect();
  const users = await client.db("app").collection("users").find().toArray();
  res.json(users);
  // client never closed
});

// GOOD: shared client
const client = new MongoClient(uri);
await client.connect();

app.get("/users", async (req, res) => {
  const users = await client.db("app").collection("users").find().toArray();
  res.json(users);
});

// Cleanup on shutdown
process.on("SIGTERM", async () => {
  await client.close();
  process.exit(0);
});

// Monitor for leaks
setInterval(() => {
  const stats = db.serverStatus().connections;
  if (stats.current > THRESHOLD) {
    console.error(`Connection count high: ${stats.current}`);
  }
}, 60000);
```

---

## Replication Lag

### Measuring Lag

```javascript
// Check replica set status
rs.status()
// Look at each member's optimeDate — difference from primary = lag

// Quick lag check
rs.printSecondaryReplicationInfo()
// Output:
// source: mongo2:27017
//   syncedTo: Mon Jun 01 2024 12:00:00
//   0 secs (0 hrs) behind the primary

// Oplog window — how far back secondaries can recover
rs.printReplicationInfo()
// Output:
// configured oplog size: 2048MB
// log length start to end: 172800secs (48hrs)

// Programmatic lag monitoring
function checkLag() {
  const status = rs.status();
  const primary = status.members.find(m => m.stateStr === "PRIMARY");
  status.members
    .filter(m => m.stateStr === "SECONDARY")
    .forEach(sec => {
      const lagMs = primary.optimeDate - sec.optimeDate;
      console.log(`${sec.name}: ${lagMs / 1000}s behind`);
    });
}
```

### Common Causes

1. **Write-heavy workload:** Primary generates oplog entries faster than secondaries apply
2. **Network latency:** Slow link between primary and secondary
3. **Slow disk on secondary:** Can't write oplog entries fast enough
4. **Long-running operations:** Blocking operations on secondary delay replication
5. **Index builds:** Building indexes on secondary blocks replication (pre-7.0)
6. **Large documents/transactions:** Single oplog entries that take long to apply

### Fixing Replication Lag

```javascript
// 1. Check if secondary has I/O bottleneck
db.serverStatus().wiredTiger.concurrentTransactions
// If write tickets exhausted, secondary can't keep up

// 2. Increase oplog size (prevent falling off oplog)
db.adminCommand({ replSetResizeOplog: 1, size: 4096 });  // MB

// 3. Reduce write concern for non-critical writes
db.logs.insertOne(
  { msg: "non-critical" },
  { writeConcern: { w: 1 } }  // don't wait for secondary
);

// 4. Use secondary reads to reduce primary load
db.orders.find().readPref("secondaryPreferred", [{ region: "us-east" }]);

// 5. Check for blocking operations on secondary
db.currentOp({ "active": true, "$or": [
  { "secs_running": { $gte: 10 } },
  { "waitingForLock": true }
]});

// 6. For persistent lag, consider:
// - Upgrading secondary hardware (SSD, more RAM)
// - Reducing write volume (batch writes, fewer indexes)
// - Adding more secondaries to distribute read load
```

---

## Sharding Hotspots

### Identifying Hotspots

```javascript
// Check chunk distribution across shards
db.adminCommand({ balancerStatus: 1 });
sh.status();

// Chunk counts per shard
use config
db.chunks.aggregate([
  { $match: { ns: "mydb.orders" } },
  { $group: { _id: "$shard", count: { $sum: 1 } } },
  { $sort: { count: -1 } }
]);

// Check data size per shard
db.orders.getShardDistribution();
// Output shows: data, docs, chunks, estimated data per chunk per shard

// Monitor operations per shard
db.adminCommand({
  aggregate: 1,
  pipeline: [{ $currentOp: { allUsers: true } },
    { $group: { _id: "$shard", ops: { $sum: 1 } } }
  ],
  cursor: {}
});
```

### Shard Key Problems

```javascript
// PROBLEM: Monotonic shard key (all inserts go to last chunk)
sh.shardCollection("mydb.events", { timestamp: 1 });
// Fix: Use hashed shard key or compound key
sh.shardCollection("mydb.events", { timestamp: "hashed" });
sh.shardCollection("mydb.events", { tenantId: 1, timestamp: 1 });

// PROBLEM: Low cardinality shard key
sh.shardCollection("mydb.orders", { status: 1 });
// Only 5 possible values → max 5 chunks → can't balance
// Fix: use higher cardinality key

// PROBLEM: Shard key doesn't match query patterns
sh.shardCollection("mydb.orders", { region: "hashed" });
// Range queries on region hit all shards (scatter-gather)
// Fix: ranged shard key if range queries dominate

// Evaluate shard key distribution before sharding
db.orders.aggregate([
  { $group: { _id: "$candidateShardKey", count: { $sum: 1 } } },
  { $group: {
    _id: null,
    distinctValues: { $sum: 1 },
    maxFreq: { $max: "$count" },
    minFreq: { $min: "$count" },
    avgFreq: { $avg: "$count" }
  }}
]);
```

### Jumbo Chunks

```javascript
// Jumbo chunks are too large to split or move — causes imbalance
db.getSiblingDB("config").chunks.find({ jumbo: true });

// Clear jumbo flag after data has been reduced
db.adminCommand({
  clearJumboFlag: "mydb.orders",
  bounds: [{ shardKey: MinKey }, { shardKey: MaxKey }]
});

// Prevent: ensure shard key has high cardinality
// Refine shard key (MongoDB 5.0+)
db.adminCommand({
  refineCollectionShardKey: "mydb.orders",
  key: { existingKey: 1, _id: 1 }  // add _id for more granularity
});
```

### Balancer Tuning

```javascript
// Check balancer state
sh.getBalancerState();       // enabled/disabled
sh.isBalancerRunning();      // actively migrating?

// Set balancer window (run only during low-traffic hours)
db.getSiblingDB("config").settings.updateOne(
  { _id: "balancer" },
  { $set: {
    activeWindow: { start: "02:00", stop: "06:00" }
  }},
  { upsert: true }
);

// Disable balancer for maintenance
sh.stopBalancer();
// Re-enable
sh.startBalancer();

// Increase chunk migration concurrency (default: 1)
db.adminCommand({
  configureCollectionBalancing: "mydb.orders",
  chunkSize: 128  // MB, default 128
});
```

---

## Index Selection Problems

### Index Not Being Used

```javascript
// 1. Check if index exists
db.orders.getIndexes();

// 2. Force index hint to verify it helps
db.orders.find({ status: "active" }).hint({ status: 1 }).explain("executionStats");

// 3. Common reasons index is ignored:
// a) Query shape doesn't match index
db.orders.createIndex({ status: 1, date: 1 });
db.orders.find({ date: { $gt: ISODate() } });  // no status filter → can't use

// b) $ne, $nin, $not prevent index use
db.orders.find({ status: { $ne: "cancelled" } });

// c) Type mismatch
db.orders.createIndex({ userId: 1 });
db.orders.find({ userId: "123" });     // string
db.orders.find({ userId: 123 });       // number — different index entries!

// d) Collation mismatch
db.orders.createIndex({ name: 1 }, { collation: { locale: "en", strength: 2 } });
db.orders.find({ name: "test" });  // no collation specified → can't use index
db.orders.find({ name: "test" }).collation({ locale: "en", strength: 2 });  // works
```

### Wrong Index Selected

```javascript
// MongoDB query planner caches winning plans
// Clear plan cache after adding new indexes
db.orders.getPlanCache().clear();

// View cached plans
db.orders.getPlanCache().list();

// Force specific index with hint
db.orders.find({ status: "active", amount: { $gt: 100 } })
  .hint({ status: 1, amount: 1 })
  .explain("executionStats");

// Use compound index instead of relying on index intersection
// BAD: two separate indexes
db.orders.createIndex({ status: 1 });
db.orders.createIndex({ amount: 1 });
// GOOD: one compound index (almost always faster)
db.orders.createIndex({ status: 1, amount: 1 });
```

### Index Intersection

```javascript
// MongoDB can intersect two indexes but it's rarely optimal
db.orders.find({ status: "active", customerId: "c1" }).explain("executionStats");
// If using AND_SORTED or AND_HASH stage, it's intersecting indexes
// Fix: create compound index instead

// Check for index intersection in explain
const plan = db.orders.find({ a: 1, b: 2 }).explain();
// Look for: inputStage.stage === "AND_SORTED" or "AND_HASH"
```

### Unused and Redundant Indexes

```javascript
// Find unused indexes (MongoDB 3.2+)
// $indexStats shows usage since last mongod restart
db.orders.aggregate([{ $indexStats: {} }]).forEach(idx => {
  console.log(
    idx.name,
    "accesses:", idx.accesses.ops,
    "since:", idx.accesses.since
  );
});

// Redundant index detection
// Index { a: 1, b: 1 } makes { a: 1 } redundant (left-prefix rule)
// Keep: { a: 1, b: 1 }   Drop: { a: 1 }

// Drop unused indexes (careful — monitor in production first)
db.orders.dropIndex("status_1");

// Hide index before dropping (MongoDB 4.4+) — test impact without risk
db.orders.hideIndex("status_1");
// If no performance regression after monitoring period:
db.orders.dropIndex("status_1");
// If regression detected:
db.orders.unhideIndex("status_1");
```

---

## Write Concern Errors

### Write Concern Levels

```javascript
// w: 0 — Fire and forget (no acknowledgment)
// w: 1 — Primary acknowledged (default)
// w: "majority" — Majority of voting members acknowledged
// w: <number> — Specific number of members acknowledged
// j: true — Written to journal on acknowledged members

// Connection-level default
const client = new MongoClient(uri, {
  writeConcern: { w: "majority", j: true, wtimeout: 5000 }
});

// Per-operation override
db.orders.insertOne(
  { item: "x" },
  { writeConcern: { w: 1, j: false } }  // faster, less durable
);
```

### Common Write Concern Errors

```javascript
// Error: "waiting for replication timed out"
// Cause: secondaries can't acknowledge within wtimeout
// Fix: increase wtimeout or check replication lag
db.orders.insertOne(
  { item: "x" },
  { writeConcern: { w: "majority", wtimeout: 30000 } }  // 30s
);

// Error: "not enough data-bearing members"
// Cause: w > available voting members (e.g., w:3 with only 2 members up)
// Fix: check rs.status() for member health

// Error: "write concern failed due to not enough members"
// Cause: member is down or network partition
rs.status().members.forEach(m => {
  console.log(m.name, m.stateStr, m.health);
});

// Retryable writes (enabled by default in 4.2+)
// Automatically retries on transient network errors
const client = new MongoClient(uri, { retryWrites: true });
```

### Diagnosing Write Failures

```javascript
// Check write concern configuration
db.adminCommand({ getDefaultRWConcern: 1 });

// MongoDB 5.0+: cluster-wide default write concern
db.adminCommand({
  setDefaultRWConcern: 1,
  defaultWriteConcern: { w: "majority", wtimeout: 10000 }
});

// Monitor write concern latency
db.serverStatus().opLatencies.writes
// Check p50, p95, p99 latencies

// If writes consistently slow with w:"majority":
// 1. Check replication lag (slow secondaries)
// 2. Check journal commit interval
// 3. Consider w:1 for non-critical data (logs, analytics)
// 4. Batch writes to amortize write concern overhead
```

---

## Lock Contention

### Understanding MongoDB Locks

MongoDB uses multi-granularity locking:
- **Global lock:** Rare; some admin commands
- **Database lock:** `createCollection`, `dropDatabase`
- **Collection lock:** Rename, index creation (background)
- **Document lock:** WiredTiger uses document-level concurrency control (MVCC)

```javascript
// Check lock stats
db.serverStatus().locks
// Key lock types:
// "Global" — global lock
// "Database" — database-level
// "Collection" — collection-level
// "oplog" — replication oplog

// Active lock holders
db.currentOp({
  "waitingForLock": true,
  "active": true
});
```

### Identifying Lock Contention

```javascript
// Find operations waiting for locks
db.currentOp().inprog.filter(op =>
  op.waitingForLock === true
);

// Check lock acquisition times in profiler
db.setProfilingLevel(1, { slowms: 50 });
db.system.profile.find({
  "locks.Global.acquireCount": { $exists: true }
}).sort({ ts: -1 }).limit(10);

// WiredTiger concurrent transaction tickets
const wt = db.serverStatus().wiredTiger.concurrentTransactions;
console.log("Read tickets:", wt.read.available, "/", wt.read.totalTickets);
console.log("Write tickets:", wt.write.available, "/", wt.write.totalTickets);
// If available tickets consistently near 0 → contention

// MongoDB 8.0: use workingMillis metric
db.system.profile.find().sort({ ts: -1 }).limit(5).forEach(op => {
  console.log(op.op, "working:", op.workingMillis, "ms", "total:", op.millis, "ms");
});
```

### Reducing Lock Contention

```javascript
// 1. Keep transactions short
// BAD: long transaction
session.startTransaction();
await longRunningComputation();  // holds locks
await collection.updateMany(...);
await session.commitTransaction();

// GOOD: compute first, then short transaction
const results = await longRunningComputation();
session.startTransaction();
await collection.updateMany(...);  // minimal lock time
await session.commitTransaction();

// 2. Avoid large batch operations in a single transaction
// BAD: update 100k docs in one transaction
await collection.updateMany({ status: "old" }, { $set: { status: "archived" } });

// GOOD: batch in smaller chunks
const batchSize = 1000;
let modified = 0;
while (true) {
  const result = await collection.updateMany(
    { status: "old" },
    { $set: { status: "archived" } },
    { limit: batchSize }  // not supported — use find + bulkWrite
  );
  if (result.modifiedCount === 0) break;
  modified += result.modifiedCount;
  await new Promise(r => setTimeout(r, 100));  // yield
}

// 3. Use background index builds (default in 4.2+)
db.orders.createIndex({ status: 1 });  // automatically background

// 4. Avoid full-collection operations during peak hours
// Schedule: db.repairDatabase(), compact, validate for off-peak
```

---

## Migration from RDBMS Pitfalls

### Schema Design Anti-Patterns

```javascript
// ANTI-PATTERN 1: Direct table-to-collection mapping (over-normalization)
// RDBMS: users, addresses, phone_numbers tables with JOINs
// BAD MongoDB:
db.users.findOne({ _id: 1 });         // { name: "Alice" }
db.addresses.find({ userId: 1 });      // separate lookup
db.phones.find({ userId: 1 });         // another lookup
// = 3 round trips instead of 1

// GOOD MongoDB: embed related data
db.users.findOne({ _id: 1 });
// { name: "Alice",
//   addresses: [{ type: "home", street: "123 Main" }],
//   phones: [{ type: "mobile", number: "555-0100" }] }

// ANTI-PATTERN 2: Using MongoDB as a relational DB with $lookup everywhere
// $lookup is a LEFT OUTER JOIN — it's expensive. Embed when:
// - Data is read together
// - Child data is bounded (not unbounded arrays)
// - Child rarely updated independently

// ANTI-PATTERN 3: Storing IDs as strings when they should be ObjectIds
// BAD: { userId: "507f1f77bcf86cd799439011" }  // string
// GOOD: { userId: ObjectId("507f1f77bcf86cd799439011") }
// Mismatched types = queries silently return no results
```

### Query Translation Mistakes

```javascript
// SQL: SELECT * FROM orders WHERE status IN ('active','pending') ORDER BY date DESC LIMIT 10
// Wrong: multiple queries
db.orders.find({ status: "active" });
db.orders.find({ status: "pending" });
// Right: single query
db.orders.find({ status: { $in: ["active", "pending"] } }).sort({ date: -1 }).limit(10);

// SQL: SELECT category, COUNT(*), SUM(amount) FROM orders GROUP BY category HAVING COUNT(*) > 5
// MongoDB:
db.orders.aggregate([
  { $group: { _id: "$category", count: { $sum: 1 }, total: { $sum: "$amount" } } },
  { $match: { count: { $gt: 5 } } }
]);

// SQL: SELECT * FROM orders o JOIN customers c ON o.custId = c.id WHERE c.vip = true
// Don't default to $lookup — consider embedding VIP flag in orders
// If needed:
db.orders.aggregate([
  { $lookup: { from: "customers", localField: "custId", foreignField: "_id", as: "customer" } },
  { $unwind: "$customer" },
  { $match: { "customer.vip": true } }
]);
// Better: denormalize
db.orders.find({ "customer.vip": true });  // embedded customer summary
```

### Transaction Over-Use

```javascript
// RDBMS habit: wrap everything in transactions
// MongoDB: single-document operations are already atomic

// UNNECESSARY TRANSACTION:
session.startTransaction();
await db.orders.insertOne({ _id: 1, items: [...], total: 99.99 }, { session });
await session.commitTransaction();
// Single insertOne is already atomic — no transaction needed

// NEEDED TRANSACTION:
// When updating multiple documents that must be consistent
session.startTransaction();
await db.accounts.updateOne({ _id: "A" }, { $inc: { balance: -100 } }, { session });
await db.accounts.updateOne({ _id: "B" }, { $inc: { balance: 100 } }, { session });
await session.commitTransaction();

// BETTER: redesign to avoid transactions
// Instead of two account updates, use a single transfer document
// and update balances via change stream or materialized view
```

### Missing Denormalization

```javascript
// RDBMS: normalized, avoid data duplication
// MongoDB: strategic denormalization improves read performance

// Example: e-commerce order
// RDBMS way (normalized):
{ orderId: 1, customerId: 101, items: [{ productId: 201 }] }
// Requires joins to get customer name, product name, price

// MongoDB way (denormalized):
{
  orderId: 1,
  customer: { id: 101, name: "Alice", email: "alice@ex.com" },
  items: [{ productId: 201, name: "Widget", price: 9.99, qty: 2 }],
  total: 19.98,
  orderDate: ISODate("2024-06-01")
}
// One read gets everything needed to display the order

// Trade-off: when customer changes name, update denormalized copies
// Acceptable if reads >> writes (which is typical for orders)
```

### Migration Strategy

```javascript
// 1. Dual-write phase: write to both RDBMS and MongoDB
// 2. Shadow read: read from both, compare results
// 3. MongoDB primary: read from MongoDB, write to both
// 4. Cut over: MongoDB only

// Schema mapping checklist:
// - Identify entity relationships (1:1, 1:N, M:N)
// - 1:1 → embed
// - 1:few → embed array
// - 1:many (bounded) → embed array with subset pattern
// - 1:many (unbounded) → reference with parent ID
// - M:N → embed IDs on the "more queried" side
// - Joins used in critical queries → denormalize
// - Secondary tables rarely queried alone → embed

// Data migration script skeleton
async function migrateTable(sqlPool, mongoCollection, tableName, transform) {
  const batchSize = 5000;
  let offset = 0;
  while (true) {
    const [rows] = await sqlPool.query(
      `SELECT * FROM ${tableName} LIMIT ? OFFSET ?`,
      [batchSize, offset]
    );
    if (rows.length === 0) break;
    const docs = rows.map(transform);
    await mongoCollection.insertMany(docs, { ordered: false });
    offset += batchSize;
    console.log(`Migrated ${offset} rows from ${tableName}`);
  }
}
```
