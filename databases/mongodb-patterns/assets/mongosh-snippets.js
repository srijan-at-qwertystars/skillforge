// ============================================================================
// mongosh-snippets.js — Useful mongosh Helper Functions
// ============================================================================
// Load in mongosh:  load("mongosh-snippets.js")
// Or add to ~/.mongoshrc.js for automatic loading.
// ============================================================================

// ---------------------------------------------------------------------------
// Collection Helpers
// ---------------------------------------------------------------------------

/**
 * Show all collections with document counts and sizes (sorted by size desc).
 */
function collStats() {
  const results = [];
  db.getCollectionNames().forEach((name) => {
    try {
      const stats = db.getCollection(name).stats();
      results.push({
        collection: name,
        docs: stats.count,
        sizeMB: (stats.size / 1048576).toFixed(2),
        indexSizeMB: (stats.totalIndexSize / 1048576).toFixed(2),
        avgDocBytes: stats.count > 0 ? Math.round(stats.avgObjSize) : 0,
        indexes: stats.nindexes,
      });
    } catch (e) {
      results.push({ collection: name, error: e.message });
    }
  });
  results.sort((a, b) => parseFloat(b.sizeMB || 0) - parseFloat(a.sizeMB || 0));
  console.table(results);
  return results;
}

/**
 * Show the schema shape of a collection by sampling documents.
 * @param {string} collName - Collection name
 * @param {number} sampleSize - Number of documents to sample
 */
function schemaShape(collName, sampleSize = 100) {
  const fields = {};
  db.getCollection(collName)
    .aggregate([{ $sample: { size: sampleSize } }])
    .forEach((doc) => {
      function traverse(obj, prefix = "") {
        for (const [key, val] of Object.entries(obj)) {
          const path = prefix ? `${prefix}.${key}` : key;
          const type = Array.isArray(val)
            ? "array"
            : val === null
              ? "null"
              : typeof val;
          if (!fields[path]) fields[path] = {};
          fields[path][type] = (fields[path][type] || 0) + 1;
        }
      }
      traverse(doc);
    });

  const result = Object.entries(fields)
    .map(([path, types]) => ({
      field: path,
      types: Object.entries(types)
        .map(([t, c]) => `${t}(${c})`)
        .join(", "),
      coverage: `${Math.round(
        (Object.values(types).reduce((a, b) => a + b, 0) / sampleSize) * 100
      )}%`,
    }))
    .sort((a, b) => a.field.localeCompare(b.field));

  console.table(result);
  return result;
}

// ---------------------------------------------------------------------------
// Index Helpers
// ---------------------------------------------------------------------------

/**
 * Show index usage stats for a collection.
 * @param {string} collName - Collection name
 */
function indexUsage(collName) {
  const stats = db.getCollection(collName).aggregate([{ $indexStats: {} }]).toArray();
  const result = stats.map((s) => ({
    name: s.name,
    key: JSON.stringify(s.key),
    ops: s.accesses.ops,
    since: s.accesses.since.toISOString().slice(0, 19),
  }));
  result.sort((a, b) => a.ops - b.ops);
  console.table(result);
  return result;
}

/**
 * Find duplicate/redundant indexes across all collections.
 */
function findRedundantIndexes() {
  const issues = [];
  db.getCollectionNames().forEach((collName) => {
    const indexes = db.getCollection(collName).getIndexes();
    for (let i = 0; i < indexes.length; i++) {
      for (let j = 0; j < indexes.length; j++) {
        if (i === j) continue;
        const keysI = Object.keys(indexes[i].key);
        const keysJ = Object.keys(indexes[j].key);
        if (keysI.length < keysJ.length) {
          const isPrefix = keysI.every(
            (k, idx) =>
              k === keysJ[idx] && indexes[i].key[k] === indexes[j].key[k]
          );
          if (isPrefix && !indexes[i].unique && !indexes[i].sparse) {
            issues.push({
              collection: collName,
              redundant: `${indexes[i].name} ${JSON.stringify(indexes[i].key)}`,
              coveredBy: `${indexes[j].name} ${JSON.stringify(indexes[j].key)}`,
            });
          }
        }
      }
    }
  });
  if (issues.length === 0) {
    print("No redundant indexes found.");
  } else {
    console.table(issues);
  }
  return issues;
}

// ---------------------------------------------------------------------------
// Query Analysis
// ---------------------------------------------------------------------------

/**
 * Show recent slow queries from the profiler.
 * @param {number} limit - Number of queries to show
 * @param {number} minMs - Minimum duration in ms
 */
function slowQueries(limit = 10, minMs = 100) {
  const queries = db.system.profile
    .find({ millis: { $gt: minMs } })
    .sort({ ts: -1 })
    .limit(limit)
    .toArray();

  const result = queries.map((q) => ({
    op: q.op,
    ns: q.ns,
    millis: q.millis,
    docsExamined: q.docsExamined || 0,
    nReturned: q.nreturned || 0,
    planSummary: q.planSummary || "N/A",
    ts: q.ts.toISOString().slice(0, 19),
  }));

  console.table(result);
  return result;
}

/**
 * Quick explain helper — returns key metrics.
 * @param {object} cursor - A find cursor
 */
function quickExplain(cursor) {
  const explain = cursor.explain("executionStats");
  const stats = explain.executionStats;
  const plan = explain.queryPlanner.winningPlan;

  const result = {
    planStage: plan.stage || plan.inputStage?.stage || "unknown",
    nReturned: stats.nReturned,
    totalKeysExamined: stats.totalKeysExamined,
    totalDocsExamined: stats.totalDocsExamined,
    executionTimeMs: stats.executionTimeMillis,
    efficiency: stats.nReturned > 0
      ? (stats.nReturned / stats.totalDocsExamined).toFixed(3)
      : "N/A",
    indexUsed: plan.inputStage?.indexName || plan.indexName || "none",
  };

  print("\n--- Quick Explain ---");
  for (const [k, v] of Object.entries(result)) {
    print(`  ${k}: ${v}`);
  }
  print("---\n");
  return result;
}

// ---------------------------------------------------------------------------
// Replica Set Helpers
// ---------------------------------------------------------------------------

/**
 * Show replica set lag for all secondaries.
 */
function rsLag() {
  try {
    const status = rs.status();
    const primary = status.members.find((m) => m.stateStr === "PRIMARY");
    if (!primary) { print("No primary found"); return; }

    const result = status.members.map((m) => ({
      name: m.name,
      state: m.stateStr,
      health: m.health === 1 ? "OK" : "DOWN",
      lagSeconds:
        m.stateStr === "SECONDARY"
          ? Math.floor((primary.optimeDate - m.optimeDate) / 1000)
          : 0,
    }));
    console.table(result);
    return result;
  } catch (e) {
    print("Not a replica set: " + e.message);
  }
}

// ---------------------------------------------------------------------------
// Data Helpers
// ---------------------------------------------------------------------------

/**
 * Count documents matching common patterns across a collection.
 * @param {string} collName - Collection name
 * @param {string} field - Field to analyze
 */
function fieldDistribution(collName, field, limit = 20) {
  const result = db
    .getCollection(collName)
    .aggregate([
      { $group: { _id: `$${field}`, count: { $sum: 1 } } },
      { $sort: { count: -1 } },
      { $limit: limit },
    ])
    .toArray();

  const total = db.getCollection(collName).estimatedDocumentCount();
  const formatted = result.map((r) => ({
    value: r._id,
    count: r.count,
    percentage: ((r.count / total) * 100).toFixed(1) + "%",
  }));

  console.table(formatted);
  return formatted;
}

/**
 * Find documents with the largest BSON size.
 * @param {string} collName - Collection name
 * @param {number} limit - Number of results
 */
function largestDocs(collName, limit = 10) {
  const result = db
    .getCollection(collName)
    .aggregate([
      { $addFields: { _docSize: { $bsonSize: "$$ROOT" } } },
      { $sort: { _docSize: -1 } },
      { $limit: limit },
      { $project: { _id: 1, _docSize: 1 } },
    ])
    .toArray();

  const formatted = result.map((r) => ({
    _id: r._id,
    sizeKB: (r._docSize / 1024).toFixed(1),
    sizeBytes: r._docSize,
  }));

  console.table(formatted);
  return formatted;
}

/**
 * Export query results as JSON lines (one doc per line).
 * @param {string} collName - Collection name
 * @param {object} query - Query filter
 * @param {number} limit - Max docs
 */
function exportJsonl(collName, query = {}, limit = 1000) {
  const docs = db.getCollection(collName).find(query).limit(limit).toArray();
  docs.forEach((doc) => print(JSON.stringify(doc)));
  print(`\n--- Exported ${docs.length} documents ---`);
}

// ---------------------------------------------------------------------------
// Operational Helpers
// ---------------------------------------------------------------------------

/**
 * Kill all operations running longer than N seconds.
 * @param {number} seconds - Threshold
 * @param {boolean} dryRun - If true, only lists without killing
 */
function killLongOps(seconds = 60, dryRun = true) {
  const ops = db.currentOp({
    active: true,
    secs_running: { $gte: seconds },
    op: { $ne: "none" },
  }).inprog;

  if (ops.length === 0) {
    print(`No operations running longer than ${seconds}s`);
    return;
  }

  ops.forEach((op) => {
    print(
      `opid=${op.opid} | ${op.op} | ${op.ns || "?"} | ${op.secs_running}s`
    );
    if (!dryRun) {
      db.killOp(op.opid);
      print(`  → Killed`);
    }
  });

  if (dryRun) {
    print(`\n${ops.length} operations found. Run killLongOps(${seconds}, false) to kill.`);
  }
}

/**
 * Show current lock status summary.
 */
function lockStatus() {
  const wt = db.serverStatus().wiredTiger.concurrentTransactions;
  print("\n--- WiredTiger Tickets ---");
  print(`  Read:  ${wt.read.available} available / ${wt.read.totalTickets} total`);
  print(`  Write: ${wt.write.available} available / ${wt.write.totalTickets} total`);

  const ops = db.currentOp({ waitingForLock: true }).inprog;
  if (ops.length > 0) {
    print(`\n  ⚠ ${ops.length} operations waiting for locks`);
  } else {
    print("  ✓ No operations waiting for locks");
  }
}

// ---------------------------------------------------------------------------
// Print available functions on load
// ---------------------------------------------------------------------------

print("\n╔══════════════════════════════════════════════╗");
print("║  mongosh-snippets loaded                     ║");
print("╠══════════════════════════════════════════════╣");
print("║  collStats()             - Collection sizes   ║");
print("║  schemaShape(coll)       - Schema analysis    ║");
print("║  indexUsage(coll)        - Index usage stats  ║");
print("║  findRedundantIndexes()  - Redundant indexes  ║");
print("║  slowQueries(n, ms)      - Recent slow ops    ║");
print("║  quickExplain(cursor)    - Explain summary    ║");
print("║  rsLag()                 - Replica set lag    ║");
print("║  fieldDistribution(c,f)  - Value distribution ║");
print("║  largestDocs(coll)       - Largest documents  ║");
print("║  exportJsonl(coll, q, n) - Export as JSONL    ║");
print("║  killLongOps(secs, dry)  - Kill long ops      ║");
print("║  lockStatus()            - Lock/ticket info   ║");
print("╚══════════════════════════════════════════════╝\n");
