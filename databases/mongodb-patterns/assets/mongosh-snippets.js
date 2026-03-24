// =============================================================================
// mongosh-snippets.js — Useful mongosh commands for administration & debugging
//
// USAGE:
//   mongosh < mongosh-snippets.js           (run all)
//   mongosh --eval "load('mongosh-snippets.js')"
//   Or copy-paste individual snippets into a mongosh session.
// =============================================================================

// ─── SERVER INFO ──────────────────────────────────────────────────────────────

// Quick server overview
function serverOverview() {
  const ss = db.serverStatus();
  const info = {
    version: ss.version,
    uptime: `${Math.floor(ss.uptime / 3600)}h ${Math.floor((ss.uptime % 3600) / 60)}m`,
    connections: `${ss.connections.current} / ${ss.connections.current + ss.connections.available}`,
    opcounters: ss.opcounters,
    storageEngine: ss.storageEngine.name
  };
  printjson(info);
}

// ─── DATABASE & COLLECTION STATS ──────────────────────────────────────────────

// All database sizes
function dbSizes() {
  const dbs = db.adminCommand({ listDatabases: 1 });
  dbs.databases
    .sort((a, b) => b.sizeOnDisk - a.sizeOnDisk)
    .forEach(d => {
      print(`${d.name.padEnd(25)} ${(d.sizeOnDisk / 1024 / 1024).toFixed(2).padStart(10)} MB`);
    });
  print(`${"TOTAL".padEnd(25)} ${(dbs.totalSize / 1024 / 1024).toFixed(2).padStart(10)} MB`);
}

// Collection sizes for current database
function collectionSizes() {
  const results = [];
  db.getCollectionNames().forEach(coll => {
    try {
      const stats = db[coll].stats();
      results.push({
        name: coll,
        docs: stats.count,
        dataMB: (stats.size / 1024 / 1024).toFixed(2),
        storageMB: (stats.storageSize / 1024 / 1024).toFixed(2),
        indexMB: (stats.totalIndexSize / 1024 / 1024).toFixed(2),
        indexes: stats.nindexes,
        avgDocBytes: stats.count > 0 ? Math.round(stats.size / stats.count) : 0
      });
    } catch (e) { /* skip views */ }
  });
  results.sort((a, b) => parseFloat(b.dataMB) - parseFloat(a.dataMB));
  console.table(results);
}

// ─── INDEX ANALYSIS ───────────────────────────────────────────────────────────

// All indexes with usage stats for current database
function indexUsage() {
  db.getCollectionNames().forEach(coll => {
    print(`\n=== ${coll} ===`);
    try {
      const indexes = db[coll].getIndexes();
      const stats = db[coll].aggregate([{ $indexStats: {} }]).toArray();
      const statsMap = {};
      stats.forEach(s => { statsMap[s.name] = s.accesses.ops; });

      indexes.forEach(idx => {
        const ops = statsMap[idx.name] || 0;
        const flag = (idx.name !== "_id_" && ops === 0) ? " ⚠️  UNUSED" : "";
        print(`  ${idx.name.padEnd(40)} ops: ${String(ops).padStart(8)}  key: ${JSON.stringify(idx.key)}${flag}`);
      });
    } catch (e) { print(`  (skipped: ${e.message})`); }
  });
}

// Find redundant indexes (prefix of another index)
function redundantIndexes() {
  db.getCollectionNames().forEach(coll => {
    try {
      const indexes = db[coll].getIndexes();
      for (let i = 0; i < indexes.length; i++) {
        const keysI = Object.keys(indexes[i].key);
        for (let j = 0; j < indexes.length; j++) {
          if (i === j) continue;
          const keysJ = Object.keys(indexes[j].key);
          if (keysI.length >= keysJ.length) continue;
          const isPrefix = keysI.every((k, idx) =>
            k === keysJ[idx] && indexes[i].key[k] === indexes[j].key[k]
          );
          if (isPrefix) {
            print(`[${coll}] "${indexes[i].name}" is prefix of "${indexes[j].name}" — consider dropping`);
          }
        }
      }
    } catch (e) { /* skip */ }
  });
}

// ─── QUERY DEBUGGING ──────────────────────────────────────────────────────────

// Quick explain helper
function quickExplain(collection, query, projection) {
  const explain = db[collection].find(query, projection || {}).explain("executionStats");
  const es = explain.executionStats;
  const qp = explain.queryPlanner;
  return {
    plan: qp.winningPlan.stage || qp.winningPlan.inputStage?.stage,
    index: qp.winningPlan.inputStage?.indexName || "none",
    nReturned: es.nReturned,
    docsExamined: es.totalDocsExamined,
    keysExamined: es.totalKeysExamined,
    timeMs: es.executionTimeMillis,
    ratio: es.totalDocsExamined > 0 ? (es.nReturned / es.totalDocsExamined).toFixed(3) : "N/A"
  };
}

// Show slow queries from profiler
function slowQueries(minMs, limit) {
  minMs = minMs || 100;
  limit = limit || 20;
  return db.system.profile.find({ millis: { $gt: minMs } })
    .sort({ ts: -1 })
    .limit(limit)
    .toArray()
    .map(q => ({
      ts: q.ts,
      op: q.op,
      ns: q.ns,
      ms: q.millis,
      plan: q.planSummary,
      docsExamined: q.docsExamined,
      nReturned: q.nreturned,
      command: JSON.stringify(q.command || q.query).substring(0, 120)
    }));
}

// Enable/disable profiler
function profilerOn(slowms) { db.setProfilingLevel(1, { slowms: slowms || 100 }); print(`Profiler ON (slowms: ${slowms || 100})`); }
function profilerOff() { db.setProfilingLevel(0); print("Profiler OFF"); }

// ─── REPLICATION ──────────────────────────────────────────────────────────────

// Compact replica set status
function replStatus() {
  try {
    const status = rs.status();
    print(`Replica Set: ${status.set}`);
    status.members.forEach(m => {
      let lag = "";
      if (m.stateStr === "SECONDARY") {
        const primary = status.members.find(p => p.stateStr === "PRIMARY");
        if (primary && primary.optimeDate && m.optimeDate) {
          lag = ` (lag: ${((primary.optimeDate - m.optimeDate) / 1000).toFixed(1)}s)`;
        }
      }
      print(`  ${m.stateStr.padEnd(12)} ${m.name.padEnd(25)} health: ${m.health}${lag}`);
    });
  } catch (e) {
    print("Not a replica set member");
  }
}

// ─── CONNECTIONS ──────────────────────────────────────────────────────────────

// Connection details
function connectionInfo() {
  const ss = db.serverStatus();
  const conn = ss.connections;
  printjson({
    current: conn.current,
    available: conn.available,
    totalCreated: conn.totalCreated,
    usagePct: ((conn.current / (conn.current + conn.available)) * 100).toFixed(1) + "%"
  });
}

// Connections grouped by client application
function connectionsByApp() {
  const ops = db.currentOp(true).inprog;
  const apps = {};
  ops.forEach(op => {
    const app = op.appName || "unknown";
    apps[app] = (apps[app] || 0) + 1;
  });
  Object.entries(apps)
    .sort((a, b) => b[1] - a[1])
    .forEach(([app, count]) => print(`  ${app.padEnd(40)} ${count}`));
}

// ─── WIREDTIGER CACHE ─────────────────────────────────────────────────────────

// Cache status
function cacheStatus() {
  const cache = db.serverStatus().wiredTiger.cache;
  const maxGB = cache["maximum bytes configured"] / 1073741824;
  const usedGB = cache["bytes currently in the cache"] / 1073741824;
  const dirtyGB = cache["tracked dirty bytes in the cache"] / 1073741824;
  printjson({
    maxGB: maxGB.toFixed(2),
    usedGB: usedGB.toFixed(2),
    dirtyGB: dirtyGB.toFixed(2),
    usedPct: ((usedGB / maxGB) * 100).toFixed(1) + "%",
    dirtyPct: ((dirtyGB / maxGB) * 100).toFixed(1) + "%"
  });
}

// ─── CURRENT OPERATIONS ───────────────────────────────────────────────────────

// Long-running operations
function longRunningOps(minSeconds) {
  minSeconds = minSeconds || 5;
  return db.currentOp({
    active: true,
    secs_running: { $gt: minSeconds }
  }).inprog.map(op => ({
    opId: op.opid,
    op: op.op,
    ns: op.ns,
    secs: op.secs_running,
    plan: op.planSummary,
    client: op.client,
    app: op.appName,
    desc: (op.command ? JSON.stringify(op.command) : "").substring(0, 100)
  }));
}

// Kill long-running ops (use with caution)
function killLongOps(minSeconds) {
  minSeconds = minSeconds || 60;
  const ops = db.currentOp({ active: true, secs_running: { $gt: minSeconds } }).inprog;
  ops.forEach(op => {
    print(`Killing opId ${op.opid}: ${op.op} on ${op.ns} (${op.secs_running}s)`);
    db.killOp(op.opid);
  });
  print(`Killed ${ops.length} operation(s)`);
}

// ─── OPLOG ────────────────────────────────────────────────────────────────────

// Oplog summary
function oplogInfo() {
  try {
    const stats = db.getSiblingDB("local").oplog.rs.stats();
    const first = db.getSiblingDB("local").oplog.rs.find().sort({ $natural: 1 }).limit(1).next();
    const last = db.getSiblingDB("local").oplog.rs.find().sort({ $natural: -1 }).limit(1).next();
    const windowSec = last.ts.getTime() - first.ts.getTime();
    printjson({
      sizeMB: (stats.maxSize / 1048576).toFixed(0),
      usedMB: (stats.size / 1048576).toFixed(0),
      entries: stats.count,
      windowHours: (windowSec / 3600).toFixed(1),
      firstEntry: first.ts,
      lastEntry: last.ts
    });
  } catch (e) {
    print("Cannot read oplog (not a replica set or not authorized)");
  }
}

// ─── DATA MANAGEMENT ──────────────────────────────────────────────────────────

// Sample documents from a collection
function sampleDocs(collName, n) {
  return db[collName].aggregate([{ $sample: { size: n || 5 } }]).toArray();
}

// Schema shape analysis (field names and types from sample)
function schemaShape(collName, sampleSize) {
  const docs = db[collName].aggregate([{ $sample: { size: sampleSize || 100 } }]).toArray();
  const fields = {};
  docs.forEach(doc => {
    function scan(obj, prefix) {
      Object.entries(obj).forEach(([key, val]) => {
        const path = prefix ? `${prefix}.${key}` : key;
        const type = Array.isArray(val) ? "array" : typeof val;
        if (!fields[path]) fields[path] = new Set();
        fields[path].add(val === null ? "null" : type);
        if (type === "object" && val !== null && !Array.isArray(val)) {
          scan(val, path);
        }
      });
    }
    scan(doc, "");
  });
  Object.entries(fields)
    .sort(([a], [b]) => a.localeCompare(b))
    .forEach(([path, types]) => {
      print(`  ${path.padEnd(40)} ${[...types].join(", ")}`);
    });
}

// ─── USER & ROLE MANAGEMENT ──────────────────────────────────────────────────

// List all users with roles
function listUsers() {
  const users = db.adminCommand({ usersInfo: 1 }).users;
  users.forEach(u => {
    const roles = u.roles.map(r => `${r.role}@${r.db}`).join(", ");
    print(`  ${u.user.padEnd(25)} ${u.db.padEnd(15)} ${roles}`);
  });
}

// ─── QUICK COMMANDS ───────────────────────────────────────────────────────────

print("=== mongosh-snippets loaded ===");
print("Available functions:");
print("  serverOverview()          — Quick server info");
print("  dbSizes()                 — All database sizes");
print("  collectionSizes()         — Collection sizes for current db");
print("  indexUsage()              — Index stats with usage counts");
print("  redundantIndexes()        — Find prefix-redundant indexes");
print("  quickExplain(coll, query) — Compact explain output");
print("  slowQueries(minMs, limit) — Slow queries from profiler");
print("  profilerOn(slowms)        — Enable profiler");
print("  profilerOff()             — Disable profiler");
print("  replStatus()              — Replica set status");
print("  connectionInfo()          — Connection pool stats");
print("  connectionsByApp()        — Connections by app name");
print("  cacheStatus()             — WiredTiger cache stats");
print("  longRunningOps(minSecs)   — Find long ops");
print("  killLongOps(minSecs)      — Kill long ops (caution!)");
print("  oplogInfo()               — Oplog size and window");
print("  sampleDocs(coll, n)       — Random sample from collection");
print("  schemaShape(coll, n)      — Infer schema from sample");
print("  listUsers()               — All users and roles");
