# MongoDB Troubleshooting Guide

## Table of Contents

- [Slow Query Diagnosis](#slow-query-diagnosis)
  - [Identifying Slow Queries](#identifying-slow-queries)
  - [Reading Explain Plans](#reading-explain-plans)
  - [Common Slow Query Causes](#common-slow-query-causes)
- [Index Usage Analysis](#index-usage-analysis)
  - [Finding Unused Indexes](#finding-unused-indexes)
  - [Finding Duplicate Indexes](#finding-duplicate-indexes)
  - [Finding Missing Indexes](#finding-missing-indexes)
  - [Index Size and Memory](#index-size-and-memory)
- [Lock Contention](#lock-contention)
  - [Diagnosing Lock Issues](#diagnosing-lock-issues)
  - [Resolving Write Contention](#resolving-write-contention)
  - [Ticket-Based Concurrency](#ticket-based-concurrency)
- [WiredTiger Cache Pressure](#wiredtiger-cache-pressure)
  - [Cache Configuration](#cache-configuration)
  - [Diagnosing Cache Issues](#diagnosing-cache-issues)
  - [Cache Tuning](#cache-tuning)
- [Replication Lag](#replication-lag)
  - [Measuring Lag](#measuring-lag)
  - [Common Causes](#common-causes)
  - [Remediation](#remediation)
- [Connection Pool Exhaustion](#connection-pool-exhaustion)
  - [Diagnosing Connection Issues](#diagnosing-connection-issues)
  - [Pool Configuration](#pool-configuration)
  - [Connection Leak Detection](#connection-leak-detection)
- [Oplog Sizing](#oplog-sizing)
  - [Checking Oplog Status](#checking-oplog-status)
  - [Sizing Guidelines](#sizing-guidelines)
  - [Resizing the Oplog](#resizing-the-oplog)
- [Storage Engine Issues](#storage-engine-issues)
  - [Disk Space](#disk-space)
  - [Compaction](#compaction)
  - [Checkpoint Stalls](#checkpoint-stalls)
  - [Journal and Durability](#journal-and-durability)
- [Upgrade Path Gotchas](#upgrade-path-gotchas)
  - [Version Compatibility](#version-compatibility)
  - [Feature Compatibility Version (FCV)](#feature-compatibility-version-fcv)
  - [Common Upgrade Issues](#common-upgrade-issues)
  - [Rollback Considerations](#rollback-considerations)

---

## Slow Query Diagnosis

### Identifying Slow Queries

```javascript
// Enable profiler for slow queries (>100ms)
db.setProfilingLevel(1, { slowms: 100 });

// Review slow queries sorted by most recent
db.system.profile.find({
  millis: { $gt: 100 }
}).sort({ ts: -1 }).limit(20).forEach(printjson);

// Find the slowest query patterns (grouped by query shape)
db.system.profile.aggregate([
  { $match: { op: { $in: ["query", "command"] } } },
  { $group: {
    _id: { ns: "$ns", command: { $ifNull: ["$command.find", "$command.aggregate"] } },
    avgMs: { $avg: "$millis" },
    maxMs: { $max: "$millis" },
    count: { $sum: 1 },
    totalMs: { $sum: "$millis" }
  }},
  { $sort: { totalMs: -1 } },
  { $limit: 10 }
]);

// Check currently running operations
db.currentOp({
  "active": true,
  "secs_running": { $gt: 5 },
  "op": { $in: ["query", "update", "remove"] }
});

// Kill a long-running operation
db.killOp(opId);

// MongoDB log grep for slow queries (server log)
// grep "Slow query" /var/log/mongodb/mongod.log | tail -20
```

### Reading Explain Plans

```javascript
// Three explain verbosity levels:
// "queryPlanner"      — shows winning plan (default)
// "executionStats"    — shows actual execution metrics
// "allPlansExecution" — shows all candidate plans

const explain = db.orders.find({
  status: "pending",
  createdAt: { $gte: ISODate("2024-01-01") }
}).sort({ total: -1 }).explain("executionStats");

// KEY METRICS TO CHECK:
// explain.executionStats.nReturned          — docs returned
// explain.executionStats.totalDocsExamined  — docs scanned (should be close to nReturned)
// explain.executionStats.totalKeysExamined  — index keys scanned
// explain.executionStats.executionTimeMillis — total time
// explain.queryPlanner.winningPlan.stage     — IXSCAN=good, COLLSCAN=bad

// RATIO CHECK:
// If totalDocsExamined >> nReturned, the query is scanning too many docs
// If totalKeysExamined >> totalDocsExamined, index is not selective enough

// STAGE MEANINGS:
// COLLSCAN      — Full collection scan (no index). Almost always bad.
// IXSCAN        — Index scan. Good.
// FETCH         — Document fetch after index scan.
// SORT          — In-memory sort (blocking). Consider index to avoid.
// SORT_KEY_GEN  — Generating sort keys. Precedes SORT.
// PROJECTION    — Applying projection.
// LIMIT         — Limiting results.
// SKIP          — Skipping documents.
// COUNT_SCAN    — Counting from index (very fast).
// IDHACK        — Query on _id (fastest possible).

// Aggregation explain:
db.orders.explain("executionStats").aggregate([
  { $match: { status: "pending" } },
  { $group: { _id: "$customerId", total: { $sum: "$amount" } } }
]);
```

### Common Slow Query Causes

| Symptom | Diagnosis | Fix |
|---------|-----------|-----|
| COLLSCAN in explain | Missing index | Create appropriate index |
| High docsExamined/nReturned ratio | Non-selective index | Improve index with more fields |
| SORT stage with large input | In-memory sort | Add sort field to index (ESR rule) |
| FETCH after IXSCAN with many docs | Index doesn't cover query | Add projected fields to index |
| $lookup slow | Missing index on foreign key | Index the foreign collection's join field |
| Regex without prefix anchor | Full index/collection scan | Use prefix-anchored regex: `/^prefix/` |
| $in with large array | Many index seeks | Consider breaking into batches |
| $ne / $nin queries | Can't use index efficiently | Restructure query if possible |

---

## Index Usage Analysis

### Finding Unused Indexes

```javascript
// $indexStats shows usage since last mongod restart or index creation
db.orders.aggregate([{ $indexStats: {} }]).forEach(idx => {
  print(`${idx.name}: ${idx.accesses.ops} ops since ${idx.accesses.since}`);
});

// Find indexes with zero usage across all collections
db.getCollectionNames().forEach(coll => {
  db[coll].aggregate([{ $indexStats: {} }]).forEach(idx => {
    if (idx.accesses.ops === 0 && idx.name !== "_id_") {
      print(`UNUSED: ${coll}.${idx.name} (0 ops since ${idx.accesses.since})`);
    }
  });
});

// WARNING: $indexStats resets on restart. Collect over days/weeks before dropping.
// Also check: hidden indexes as safer alternative to dropping
```

### Finding Duplicate Indexes

```javascript
// Find indexes that are prefixes of other indexes (redundant)
function findRedundantIndexes(collName) {
  const indexes = db[collName].getIndexes();
  const redundant = [];

  for (let i = 0; i < indexes.length; i++) {
    const keysI = Object.keys(indexes[i].key);
    for (let j = 0; j < indexes.length; j++) {
      if (i === j) continue;
      const keysJ = Object.keys(indexes[j].key);
      if (keysI.length < keysJ.length) {
        const isPrefix = keysI.every((k, idx) =>
          k === keysJ[idx] && indexes[i].key[k] === indexes[j].key[k]
        );
        if (isPrefix) {
          redundant.push({
            redundant: indexes[i].name,
            coveredBy: indexes[j].name,
            keys: indexes[i].key
          });
        }
      }
    }
  }
  return redundant;
}

// Example: { a: 1 } is redundant if { a: 1, b: 1 } exists
// But { a: 1, b: -1 } is NOT a prefix of { a: 1, b: 1 } (different sort order)
```

### Finding Missing Indexes

```javascript
// Check profiler for queries doing collection scans
db.system.profile.find({
  "planSummary": "COLLSCAN",
  "millis": { $gt: 50 }
}).sort({ ts: -1 }).limit(20).forEach(q => {
  print(`COLLSCAN on ${q.ns}: ${JSON.stringify(q.command)} (${q.millis}ms)`);
});

// Check for queries with high ratio of examined to returned
db.system.profile.find({
  "docsExamined": { $gt: 1000 },
  $expr: { $gt: ["$docsExamined", { $multiply: ["$nreturned", 10] }] }
}).sort({ millis: -1 }).limit(10);

// Log all queries for analysis (warning: high overhead, short-term only)
db.setProfilingLevel(2); // profile ALL operations
// ... collect data ...
db.setProfilingLevel(0); // disable
```

### Index Size and Memory

```javascript
// Total index size for a collection
db.orders.stats().totalIndexSize;

// Per-index sizes
db.orders.stats().indexSizes;

// All collections: index size vs data size
db.getCollectionNames().forEach(coll => {
  const stats = db[coll].stats();
  const dataMB = (stats.size / 1024 / 1024).toFixed(2);
  const indexMB = (stats.totalIndexSize / 1024 / 1024).toFixed(2);
  const ratio = (stats.totalIndexSize / stats.size * 100).toFixed(1);
  print(`${coll}: data=${dataMB}MB, indexes=${indexMB}MB (${ratio}% of data)`);
});

// If total index size > available RAM, performance degrades significantly
// WiredTiger cache should fit the working set of indexes
const serverStatus = db.serverStatus();
const cacheSizeGB = serverStatus.wiredTiger.cache["maximum bytes configured"] / 1024 / 1024 / 1024;
print(`WiredTiger cache: ${cacheSizeGB.toFixed(2)} GB`);
```

---

## Lock Contention

### Diagnosing Lock Issues

```javascript
// Check current lock status
db.serverStatus().locks;

// Global lock info
const globalLock = db.serverStatus().globalLock;
print(`Current queue - readers: ${globalLock.currentQueue.readers}, writers: ${globalLock.currentQueue.writers}`);
print(`Active clients - readers: ${globalLock.activeClients.readers}, writers: ${globalLock.activeClients.writers}`);

// If currentQueue is consistently > 0, you have lock contention

// Find operations holding locks
db.currentOp({
  "waitingForLock": true
}).inprog.forEach(op => {
  print(`OpId ${op.opid}: ${op.op} on ${op.ns}, waiting ${op.waitingForLock}`);
});

// Lock metrics over time (compare successive serverStatus calls)
// Key: locks.Collection.acquireCount vs acquireWaitCount
// If acquireWaitCount is significant fraction of acquireCount, contention exists
```

### Resolving Write Contention

```javascript
// Problem: Many concurrent updates to the same document
// Solution 1: Reduce document-level contention by splitting hot documents
// Before: single counter doc updated 10K times/sec
{ _id: "pageViews", count: 1234567 }

// After: shard counter across N sub-docs, sum on read
{ _id: "pageViews:0", count: 123456 }
{ _id: "pageViews:1", count: 123457 }
// ...
// Write: pick random shard. Read: sum all shards.

// Solution 2: Batch writes with bulkWrite
const ops = updates.map(u => ({ updateOne: { filter: u.filter, update: u.update } }));
await collection.bulkWrite(ops, { ordered: false }); // unordered = parallel execution

// Solution 3: Use the approximation pattern for counters (see advanced-patterns.md)
```

### Ticket-Based Concurrency

```javascript
// WiredTiger uses read/write tickets to limit concurrency
// Default: 128 read tickets, 128 write tickets
const wt = db.serverStatus().wiredTiger.concurrentTransactions;
print(`Read tickets:  available=${wt.read.available}, out=${wt.read.out}, total=${wt.read.totalTickets}`);
print(`Write tickets: available=${wt.write.available}, out=${wt.write.out}, total=${wt.write.totalTickets}`);

// If available tickets consistently near 0, operations are queuing
// Causes: long-running transactions, slow disk I/O, excessive concurrency
// Fix: Optimize slow operations, increase hardware IOPS, or scale horizontally

// Adjust ticket count (rarely needed, usually indicates deeper problem):
// mongod --setParameter wiredTigerConcurrentReadTransactions=256
// mongod --setParameter wiredTigerConcurrentWriteTransactions=256
```

---

## WiredTiger Cache Pressure

### Cache Configuration

```javascript
// Default WiredTiger cache: 50% of (RAM - 1GB) or 256MB, whichever is larger
// Check current configuration
const cacheStats = db.serverStatus().wiredTiger.cache;
const configuredBytes = cacheStats["maximum bytes configured"];
const usedBytes = cacheStats["bytes currently in the cache"];
const dirtyBytes = cacheStats["tracked dirty bytes in the cache"];

print(`Cache configured: ${(configuredBytes / 1024 / 1024 / 1024).toFixed(2)} GB`);
print(`Cache used:       ${(usedBytes / 1024 / 1024 / 1024).toFixed(2)} GB`);
print(`Cache dirty:      ${(dirtyBytes / 1024 / 1024 / 1024).toFixed(2)} GB`);
print(`Usage:            ${(usedBytes / configuredBytes * 100).toFixed(1)}%`);
print(`Dirty ratio:      ${(dirtyBytes / configuredBytes * 100).toFixed(1)}%`);
```

### Diagnosing Cache Issues

```javascript
// Key cache metrics to monitor
const cache = db.serverStatus().wiredTiger.cache;

// Pages read into cache (high = working set doesn't fit)
print(`Pages read: ${cache["pages read into cache"]}`);

// Eviction metrics (high eviction = cache pressure)
print(`Pages evicted - unmodified: ${cache["unmodified pages evicted"]}`);
print(`Pages evicted - modified:   ${cache["modified pages evicted"]}`);

// CRITICAL: If "modified pages evicted" is high, writes are stalling
// because dirty data must be flushed to disk before eviction

// Cache full signals
// cache["bytes currently in the cache"] / cache["maximum bytes configured"] > 0.95
// means cache is nearly full — eviction pressure is high

// Dirty data threshold
// When dirty ratio > 5%, eviction threads become more aggressive
// When dirty ratio > 20%, application threads may stall doing eviction

// Check if app threads are doing eviction (BAD — causes latency spikes):
print(`App thread eviction - pages: ${cache["application threads page evictions"]}`);
```

### Cache Tuning

```
1. Increase cache size (if RAM available):
   mongod --wiredTigerCacheSizeGB 8

2. Reduce working set:
   - Add projections to queries (fetch fewer fields)
   - Archive/delete old data
   - Use TTL indexes for ephemeral data

3. Optimize indexes:
   - Remove unused indexes (they consume cache)
   - Use partial indexes to reduce size
   - Use covered queries (avoid fetching docs)

4. Reduce dirty data:
   - Decrease checkpoint interval (default 60s)
     mongod --setParameter wiredTigerCheckpointDelaySecs=30
   - Increase eviction threads:
     mongod --setParameter wiredTigerEvictionThreadsMin=4
     mongod --setParameter wiredTigerEvictionThreadsMax=8

5. Monitor with:
   mongostat --all  (watch dirty%, used%, flushes)
   mongotop         (collection-level I/O time)
```

---

## Replication Lag

### Measuring Lag

```javascript
// Check replication status
rs.status().members.forEach(m => {
  if (m.stateStr === "SECONDARY") {
    const lagMs = m.optimeDate ?
      (rs.status().members.find(p => p.stateStr === "PRIMARY").optimeDate - m.optimeDate) : "N/A";
    print(`${m.name} (${m.stateStr}): lag = ${lagMs}ms, health = ${m.health}`);
  }
});

// More precise: rs.printSecondaryReplicationInfo()
rs.printSecondaryReplicationInfo();
// Shows: syncedTo, X secs behind primary

// Programmatic lag check
function getReplicationLag() {
  const status = rs.status();
  const primary = status.members.find(m => m.stateStr === "PRIMARY");
  return status.members
    .filter(m => m.stateStr === "SECONDARY")
    .map(m => ({
      name: m.name,
      lagSeconds: (primary.optimeDate - m.optimeDate) / 1000
    }));
}
```

### Common Causes

```
1. WRITE-HEAVY WORKLOAD
   - Primary generates ops faster than secondaries can replay
   - Check: db.serverStatus().opcounters on primary vs secondaries
   - Fix: Scale writes (sharding) or upgrade secondary hardware

2. NETWORK LATENCY
   - High latency between primary and secondary
   - Check: network round-trip between members
   - Fix: Co-locate replica set members, use faster network

3. SLOW SECONDARY DISK I/O
   - Secondary can't write to disk fast enough
   - Check: iostat on secondary, look for high await/util%
   - Fix: Use SSDs, increase IOPS, reduce unnecessary indexes

4. LONG-RUNNING QUERIES ON SECONDARY
   - Queries with read preference "secondary" block replication
   - Check: db.currentOp() on secondary for long ops
   - Fix: Add indexes, use secondary with no read traffic

5. LARGE OPLOG ENTRIES
   - Bulk writes create large oplog entries
   - Check: oplog entry sizes
   - Fix: Break bulk ops into smaller batches

6. INDEX BUILDS ON SECONDARY
   - Background index builds can slow replication
   - Check: db.currentOp() for index build operations
   - Fix: Build indexes during low-traffic periods
```

### Remediation

```javascript
// Emergency: force secondary to sync from a different member
// (useful if sync source has issues)
db.adminCommand({
  replSetSyncFrom: "mongo2:27017"
});

// If secondary is too far behind, resync from scratch:
// 1. Stop the secondary
// 2. Delete data directory
// 3. Restart — it will do an initial sync from the primary

// Adjust oplog apply batch size for faster catch-up:
// mongod --setParameter replBatchLimitOperations=5000

// Monitor with:
// rs.printReplicationInfo()   — oplog size and window
// rs.printSecondaryReplicationInfo() — secondary lag
```

---

## Connection Pool Exhaustion

### Diagnosing Connection Issues

```javascript
// Check server connection counts
const connStats = db.serverStatus().connections;
print(`Current:   ${connStats.current}`);
print(`Available: ${connStats.available}`);
print(`Total created: ${connStats.totalCreated}`);

// If current is near maxIncomingConnections (default 65536), pool is exhausted

// Find connections by app/client
db.currentOp(true).inprog.forEach(op => {
  if (op.client) {
    print(`${op.client} - ${op.appName || "unknown"} - ${op.op} - active: ${op.active}`);
  }
});

// Group connections by app name
db.aggregate([
  { $currentOp: { allUsers: true, idleConnections: true } },
  { $group: { _id: "$appName", count: { $sum: 1 } } },
  { $sort: { count: -1 } }
]);
```

### Pool Configuration

```javascript
// Node.js driver pool settings
const client = new MongoClient(uri, {
  maxPoolSize: 50,            // max connections per mongos/mongod
  minPoolSize: 5,             // pre-warmed connections
  maxIdleTimeMS: 30000,       // close idle connections after 30s
  waitQueueTimeoutMS: 10000,  // timeout waiting for connection
  serverSelectionTimeoutMS: 30000,
  connectTimeoutMS: 10000,
  socketTimeoutMS: 0,         // 0 = no timeout (use maxTimeMS on queries instead)
  maxConnecting: 2            // limit concurrent connection establishment
});

// Sizing formula:
// maxPoolSize = ceil(peakConcurrentOps / mongosCount) * 1.2
// Example: 200 concurrent ops, 2 mongos => maxPoolSize = ceil(200/2) * 1.2 = 120

// Java driver equivalent:
// MongoClientSettings.builder()
//   .applyToConnectionPoolSettings(b -> b.maxSize(50).minSize(5).maxWaitTime(10, SECONDS))
//   .build()

// Python (pymongo):
// MongoClient(uri, maxPoolSize=50, minPoolSize=5, waitQueueTimeoutMS=10000)
```

### Connection Leak Detection

```javascript
// Symptoms of connection leak:
// 1. connections.current grows continuously
// 2. waitQueueTimeoutMS errors in app logs
// 3. "connection pool exhausted" errors

// Check for leaked connections: idle connections that have been open too long
db.currentOp(true).inprog.filter(op =>
  !op.active && op.microsecs_running > 300000000  // idle > 5 min
).forEach(op => {
  print(`Possibly leaked: opId=${op.opid}, client=${op.client}, idle=${op.microsecs_running/1000000}s`);
});

// App-side prevention:
// 1. Always use try/finally to close cursors
// 2. Set socketTimeoutMS and maxTimeMS
// 3. Use connection pool monitoring events:
client.on('connectionPoolCreated', (event) => console.log('Pool created', event));
client.on('connectionCheckedOut', (event) => console.log('Checked out', event));
client.on('connectionCheckedIn', (event) => console.log('Checked in', event));
client.on('connectionPoolCleared', (event) => console.log('Pool cleared', event));
```

---

## Oplog Sizing

### Checking Oplog Status

```javascript
// Oplog info: size, usage, and time window
rs.printReplicationInfo();
// Output:
// configured oplog size:   1024MB
// log length start to end: 172800secs (48hrs)
// oplog first event time:  ...
// oplog last event time:   ...
// now:                     ...

// Detailed oplog stats
const oplogStats = db.getSiblingDB("local").oplog.rs.stats();
print(`Size: ${(oplogStats.size / 1024 / 1024).toFixed(2)} MB`);
print(`Max size: ${(oplogStats.maxSize / 1024 / 1024).toFixed(2)} MB`);
print(`Count: ${oplogStats.count} entries`);

// Oplog growth rate (entries per second)
const first = db.getSiblingDB("local").oplog.rs.find().sort({ $natural: 1 }).limit(1).next();
const last = db.getSiblingDB("local").oplog.rs.find().sort({ $natural: -1 }).limit(1).next();
const windowSecs = (last.ts.getTime() - first.ts.getTime());
const entriesPerSec = oplogStats.count / windowSecs;
print(`Oplog window: ${windowSecs}s (${(windowSecs/3600).toFixed(1)} hours)`);
print(`Entries/sec: ${entriesPerSec.toFixed(2)}`);
```

### Sizing Guidelines

```
MINIMUM oplog window should cover:
- Longest expected maintenance window (secondary offline)
- Network partition recovery time
- Initial sync time for a new replica member
- Change stream consumer downtime

RECOMMENDED: 24-72 hours for production systems

SIZING FORMULA:
  Required oplog size = oplog_growth_rate_MB_per_hour * desired_window_hours

Example:
  Growth rate: 50 MB/hour
  Desired window: 48 hours
  Oplog size: 50 * 48 = 2400 MB (set to 3 GB with margin)

HIGH-WRITE workloads:
  - Bulk inserts/updates generate proportionally large oplog entries
  - An update touching 1 field still creates full oplog entry
  - Index builds generate oplog entries
  - Consider 72+ hours for critical systems
```

### Resizing the Oplog

```javascript
// Resize oplog (4.0+): can be done online without downtime
// Increase oplog to 4GB
db.adminCommand({ replSetResizeOplog: 1, size: 4096 });  // size in MB

// Set minimum retention (4.4+): guarantee minimum hours regardless of size
db.adminCommand({
  replSetResizeOplog: 1,
  size: 4096,
  minRetentionHours: 48  // keep at least 48 hours even if oplog fills up
});

// Verify new size
rs.printReplicationInfo();
```

---

## Storage Engine Issues

### Disk Space

```javascript
// Check database sizes
db.adminCommand({ listDatabases: 1 }).databases.forEach(d => {
  print(`${d.name}: ${(d.sizeOnDisk / 1024 / 1024 / 1024).toFixed(2)} GB`);
});

// Per-collection storage breakdown
db.getCollectionNames().forEach(coll => {
  const stats = db[coll].stats();
  print(`${coll}:`);
  print(`  Data:     ${(stats.size / 1024 / 1024).toFixed(2)} MB`);
  print(`  Storage:  ${(stats.storageSize / 1024 / 1024).toFixed(2)} MB`);
  print(`  Indexes:  ${(stats.totalIndexSize / 1024 / 1024).toFixed(2)} MB`);
  print(`  Padding:  ${((stats.storageSize - stats.size) / stats.storageSize * 100).toFixed(1)}% overhead`);
});

// Disk space alerts
// storageSize >> size indicates fragmentation — consider compact
// freeStorageSize shows reclaimable space within data files
const dbStats = db.stats();
print(`Free storage (reclaimable): ${(dbStats.freeStorageSize / 1024 / 1024).toFixed(2)} MB`);
```

### Compaction

```javascript
// compact reclaims disk space from fragmented collections
// WARNING: blocks operations on the collection during compaction
// Run on secondaries first, then step down primary

// Compact a collection
db.runCommand({ compact: "orders" });

// With free space targeting (6.1+)
db.runCommand({ compact: "orders", freeSpaceTargetMB: 1024 });

// Monitor compact progress
db.currentOp({ "command.compact": { $exists: true } });

// ONLINE COMPACTION strategy (zero downtime for replica sets):
// 1. Compact each secondary one at a time
// 2. Wait for secondary to catch up after compact
// 3. Step down primary: rs.stepDown()
// 4. Compact the former primary (now secondary)
// 5. Done — primary re-elected automatically
```

### Checkpoint Stalls

```javascript
// WiredTiger writes checkpoints every 60 seconds (default)
// If checkpoints take too long, write performance degrades

// Check checkpoint timing
const wtStats = db.serverStatus().wiredTiger;
print(`Checkpoints total: ${wtStats.transaction["transaction checkpoints"]}`);
print(`Checkpoint most recent time (ms): ${wtStats.transaction["transaction checkpoint most recent time (msecs)"]}`);

// If checkpoint time > 60 seconds, checkpoints are overlapping = stall
// Causes:
// 1. Slow disk I/O — upgrade to SSDs or increase IOPS
// 2. Too much dirty data — reduce checkpoint interval
// 3. Large working set — increase cache
// 4. Too many indexes — each index is checkpointed separately

// Tune checkpoint interval:
// mongod --setParameter wiredTigerCheckpointDelaySecs=30
```

### Journal and Durability

```javascript
// Journal is the write-ahead log (WAL) — ensures crash recovery
// Default: journal commits every 100ms (200ms for replica set members)

// Check journal stats
const journal = db.serverStatus().wiredTiger.log;
print(`Log bytes written: ${journal["log bytes written"]}`);
print(`Log sync operations: ${journal["log sync operations"]}`);
print(`Log sync time (ms): ${journal["log sync time duration (usecs)"] / 1000}`);

// If log sync time is high, journal writes are slow = slow disk

// Journal compression (default: snappy)
// Can change to zlib for better compression (higher CPU):
// storage.wiredTiger.engineConfig.journalCompressor: zlib

// Write concern and journal interaction:
// { w: 1, j: false } — acknowledged when in memory (fast, risk on crash)
// { w: 1, j: true }  — acknowledged when journal flushed (slower, durable)
// { w: "majority", j: true } — replicated AND journaled (safest)
```

---

## Upgrade Path Gotchas

### Version Compatibility

```
UPGRADE ORDER (always):
  1. Upgrade all secondaries first (one at a time, rolling)
  2. Step down primary: rs.stepDown()
  3. Upgrade former primary (now secondary)
  4. THEN set featureCompatibilityVersion

SUPPORTED UPGRADE PATHS (must be sequential):
  4.4 -> 5.0 -> 6.0 -> 7.0 -> 8.0
  Cannot skip major versions (e.g., 5.0 -> 7.0 is NOT supported)

DRIVER COMPATIBILITY:
  Always update drivers to versions that support the target MongoDB version
  Check: https://www.mongodb.com/docs/drivers/
  Upgrade driver BEFORE upgrading server
```

### Feature Compatibility Version (FCV)

```javascript
// FCV controls which features are available
// Must match the PREVIOUS version during upgrade for rollback safety

// Check current FCV
db.adminCommand({ getParameter: 1, featureCompatibilityVersion: 1 });

// Set FCV after successful upgrade (cannot be undone once new features used)
db.adminCommand({ setFeatureCompatibilityVersion: "7.0" });

// CRITICAL: Do NOT set FCV to new version until:
// 1. All replica set members are upgraded
// 2. All mongos instances are upgraded (sharded cluster)
// 3. You've verified application compatibility
// 4. You're confident you won't need to rollback

// Setting FCV enables new features but prevents rollback to previous version
// if those features write data in new format
```

### Common Upgrade Issues

```
1. DEPRECATED FEATURES
   - Wire protocol changes: verify driver compatibility first
   - Removed commands: check release notes for deprecations
   - Changed default behavior: e.g., default write concern changed in 5.0

2. INDEX COMPATIBILITY
   - Some index types deprecated across versions
   - Run: db.adminCommand({ listDatabases: 1 }) and check all indexes
   - Rebuild indexes if upgrading across multiple versions

3. AUTHENTICATION CHANGES
   - SCRAM-SHA-256 became default in 4.0+
   - Check: db.adminCommand({ getParameter: 1, authenticationMechanisms: 1 })

4. AGGREGATION CHANGES
   - New stages may not work until FCV is set
   - Some expression behavior changes between versions
   - Test aggregation pipelines against target version

5. CONFIG SERVER PROTOCOL
   - Sharded clusters: config servers must be replica sets (not mirrored)
   - CSRS (Config Server Replica Set) required since 3.4

6. TIME-SERIES / QUERYABLE ENCRYPTION
   - Only available with appropriate FCV
   - Existing data may need migration after enabling
```

### Rollback Considerations

```javascript
// Rollback is possible ONLY if FCV has NOT been advanced
// Once FCV is set to new version AND new-format data is written,
// rollback requires restoring from backup

// Pre-upgrade checklist:
// [ ] Full backup (mongodump or filesystem snapshot)
// [ ] Test upgrade in staging environment
// [ ] Verify driver compatibility
// [ ] Check deprecated features in release notes
// [ ] Ensure oplog is large enough for upgrade duration
// [ ] Plan maintenance window
// [ ] Verify rollback procedure

// Rollback procedure (if FCV not advanced):
// 1. Shut down the upgraded member
// 2. Replace binary with previous version
// 3. Restart
// 4. Member rejoins replica set

// If rollback is not possible (FCV advanced):
// 1. Restore from backup
// 2. Point-in-time recovery using oplog
```
