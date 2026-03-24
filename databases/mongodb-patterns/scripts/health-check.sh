#!/usr/bin/env bash
# =============================================================================
# health-check.sh — MongoDB health check dashboard
#
# Checks: replication status, connections, WiredTiger cache, oplog window,
#          lock percentage, disk usage, slow queries, and ticket availability.
#
# USAGE:
#   ./health-check.sh [OPTIONS]
#
# OPTIONS:
#   -u, --uri URI        MongoDB connection URI (default: mongodb://localhost:27017)
#   --json               Output as JSON
#   --warn-lag SECS      Replication lag warning threshold (default: 10)
#   --warn-conn PCT      Connection usage warning % (default: 80)
#   --warn-cache PCT     Cache usage warning % (default: 90)
#   --warn-oplog HRS     Minimum oplog window hours (default: 24)
#   -h, --help           Show this help
#
# REQUIREMENTS:
#   mongosh (MongoDB Shell) must be installed and on PATH
#
# EXAMPLES:
#   ./health-check.sh
#   ./health-check.sh -u "mongodb://admin:pass@host:27017/?authSource=admin"
#   ./health-check.sh --warn-lag 5 --warn-cache 85
# =============================================================================

set -euo pipefail

URI="mongodb://localhost:27017"
JSON_OUTPUT=false
WARN_LAG=10
WARN_CONN=80
WARN_CACHE=90
WARN_OPLOG=24

usage() {
  head -n 21 "$0" | grep '^#' | sed 's/^# \?//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -u|--uri) URI="$2"; shift 2 ;;
    --json) JSON_OUTPUT=true; shift ;;
    --warn-lag) WARN_LAG="$2"; shift 2 ;;
    --warn-conn) WARN_CONN="$2"; shift 2 ;;
    --warn-cache) WARN_CACHE="$2"; shift 2 ;;
    --warn-oplog) WARN_OPLOG="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

SCRIPT=$(cat <<'MONGOSCRIPT'
const jsonOutput = JSON_OUTPUT_VAL;
const WARN_LAG = WARN_LAG_VAL;
const WARN_CONN = WARN_CONN_VAL;
const WARN_CACHE = WARN_CACHE_VAL;
const WARN_OPLOG = WARN_OPLOG_VAL;

const health = { checks: [], warnings: [], errors: [], timestamp: new Date().toISOString() };

function addCheck(name, value, status, detail) {
  health.checks.push({ name, value, status, detail: detail || "" });
  if (status === "WARN") health.warnings.push(name);
  if (status === "FAIL") health.errors.push(name);
}

try {
  const ss = db.serverStatus();

  // ---- SERVER INFO ----
  addCheck("Server Version", ss.version, "OK");
  addCheck("Uptime", `${Math.floor(ss.uptime / 3600)}h ${Math.floor((ss.uptime % 3600) / 60)}m`, "OK");

  // ---- CONNECTIONS ----
  const conn = ss.connections;
  const connPct = ((conn.current / (conn.current + conn.available)) * 100).toFixed(1);
  const connStatus = parseFloat(connPct) >= WARN_CONN ? "WARN" : "OK";
  addCheck("Connections",
    `${conn.current} / ${conn.current + conn.available} (${connPct}%)`,
    connStatus,
    connStatus === "WARN" ? `Above ${WARN_CONN}% threshold` : ""
  );

  // ---- WIREDTIGER CACHE ----
  const cache = ss.wiredTiger.cache;
  const cacheMax = cache["maximum bytes configured"];
  const cacheUsed = cache["bytes currently in the cache"];
  const cacheDirty = cache["tracked dirty bytes in the cache"];
  const cachePct = ((cacheUsed / cacheMax) * 100).toFixed(1);
  const dirtyPct = ((cacheDirty / cacheMax) * 100).toFixed(1);
  const cacheStatus = parseFloat(cachePct) >= WARN_CACHE ? "WARN" : "OK";
  addCheck("WiredTiger Cache",
    `${(cacheUsed / 1073741824).toFixed(2)} / ${(cacheMax / 1073741824).toFixed(2)} GB (${cachePct}%)`,
    cacheStatus,
    `Dirty: ${dirtyPct}%`
  );

  // ---- WIREDTIGER TICKETS ----
  const tickets = ss.wiredTiger.concurrentTransactions;
  const readAvail = tickets.read.available;
  const writeAvail = tickets.write.available;
  const readTotal = tickets.read.totalTickets;
  const writeTotal = tickets.write.totalTickets;
  const ticketStatus = (readAvail < 10 || writeAvail < 10) ? "WARN" : "OK";
  addCheck("WT Tickets",
    `Read: ${readAvail}/${readTotal} avail, Write: ${writeAvail}/${writeTotal} avail`,
    ticketStatus,
    ticketStatus === "WARN" ? "Low ticket availability — possible concurrency bottleneck" : ""
  );

  // ---- GLOBAL LOCK ----
  const gl = ss.globalLock;
  const queuedReaders = gl.currentQueue.readers;
  const queuedWriters = gl.currentQueue.writers;
  const lockStatus = (queuedReaders + queuedWriters > 10) ? "WARN" : "OK";
  addCheck("Lock Queue",
    `Readers: ${queuedReaders}, Writers: ${queuedWriters}`,
    lockStatus,
    lockStatus === "WARN" ? "Operations queuing for locks" : ""
  );

  // ---- OPCOUNTERS ----
  const ops = ss.opcounters;
  addCheck("Opcounters (since start)",
    `insert: ${ops.insert}, query: ${ops.query}, update: ${ops.update}, delete: ${ops.delete}`,
    "OK"
  );

  // ---- REPLICATION ----
  try {
    const rsStatus = rs.status();
    const primary = rsStatus.members.find(m => m.stateStr === "PRIMARY");
    const secondaries = rsStatus.members.filter(m => m.stateStr === "SECONDARY");

    addCheck("Replica Set", `${rsStatus.set} — ${rsStatus.members.length} members`, "OK");

    if (primary) {
      addCheck("Primary", primary.name, "OK");
    } else {
      addCheck("Primary", "NO PRIMARY", "FAIL", "No primary detected — cluster cannot accept writes!");
    }

    secondaries.forEach(sec => {
      if (primary && primary.optimeDate && sec.optimeDate) {
        const lagSec = (primary.optimeDate - sec.optimeDate) / 1000;
        const lagStatus = lagSec > WARN_LAG ? "WARN" : "OK";
        addCheck(`Secondary ${sec.name}`, `lag: ${lagSec}s, health: ${sec.health}`,
          lagStatus,
          lagStatus === "WARN" ? `Lag exceeds ${WARN_LAG}s threshold` : ""
        );
      } else {
        addCheck(`Secondary ${sec.name}`, `state: ${sec.stateStr}, health: ${sec.health}`,
          sec.health === 1 ? "OK" : "FAIL"
        );
      }
    });

    // ---- OPLOG ----
    try {
      const oplog = db.getSiblingDB("local").oplog.rs.stats();
      const firstEntry = db.getSiblingDB("local").oplog.rs.find().sort({ $natural: 1 }).limit(1).next();
      const lastEntry = db.getSiblingDB("local").oplog.rs.find().sort({ $natural: -1 }).limit(1).next();

      if (firstEntry && lastEntry) {
        const windowSec = lastEntry.ts.getTime() - firstEntry.ts.getTime();
        const windowHrs = (windowSec / 3600).toFixed(1);
        const oplogSizeMB = (oplog.maxSize / 1048576).toFixed(0);
        const oplogUsedMB = (oplog.size / 1048576).toFixed(0);
        const oplogStatus = parseFloat(windowHrs) < WARN_OPLOG ? "WARN" : "OK";
        addCheck("Oplog Window",
          `${windowHrs} hours (${oplogUsedMB} / ${oplogSizeMB} MB)`,
          oplogStatus,
          oplogStatus === "WARN" ? `Below ${WARN_OPLOG}h minimum` : ""
        );
      }
    } catch (e) {
      addCheck("Oplog", "Could not read oplog", "WARN", e.message);
    }
  } catch (e) {
    addCheck("Replication", "Not a replica set or not authorized", "INFO", e.message);
  }

  // ---- DATABASE SIZES ----
  try {
    const dbs = db.adminCommand({ listDatabases: 1 });
    const dbSizes = dbs.databases.map(d => `${d.name}: ${(d.sizeOnDisk / 1073741824).toFixed(2)}GB`).join(", ");
    const totalGB = (dbs.totalSize / 1073741824).toFixed(2);
    addCheck("Disk Usage", `Total: ${totalGB} GB`, "OK", dbSizes);
  } catch (e) {
    addCheck("Disk Usage", "Not authorized to list databases", "WARN");
  }

  // ---- SLOW QUERIES (from profiler) ----
  try {
    const profile = db.getProfilingStatus();
    if (profile.was > 0) {
      const slowCount = db.system.profile.countDocuments({ millis: { $gt: profile.slowms } });
      addCheck("Profiler", `Level ${profile.was}, slowms: ${profile.slowms}, slow queries: ${slowCount}`, "OK");
    } else {
      addCheck("Profiler", "Disabled", "INFO", "Enable with: db.setProfilingLevel(1, {slowms: 100})");
    }
  } catch (e) { /* skip */ }

} catch (e) {
  addCheck("Connection", "FAILED", "FAIL", e.message);
}

// ---- OUTPUT ----
if (jsonOutput) {
  printjson(health);
} else {
  print("\n╔══════════════════════════════════════════════════════╗");
  print("║         MongoDB Health Check Report                 ║");
  print("╚══════════════════════════════════════════════════════╝");
  print(`  Timestamp: ${health.timestamp}\n`);

  health.checks.forEach(c => {
    const icon = c.status === "OK" ? "✅" : c.status === "WARN" ? "⚠️ " : c.status === "FAIL" ? "❌" : "ℹ️ ";
    print(`  ${icon} ${c.name}: ${c.value}`);
    if (c.detail) print(`     ${c.detail}`);
  });

  print("\n──────────────────────────────────────────────────────");
  if (health.errors.length > 0) {
    print(`  ❌ ERRORS (${health.errors.length}): ${health.errors.join(", ")}`);
  }
  if (health.warnings.length > 0) {
    print(`  ⚠️  WARNINGS (${health.warnings.length}): ${health.warnings.join(", ")}`);
  }
  if (health.errors.length === 0 && health.warnings.length === 0) {
    print("  ✅ All checks passed");
  }
  print("──────────────────────────────────────────────────────\n");
}
MONGOSCRIPT
)

SCRIPT="${SCRIPT//JSON_OUTPUT_VAL/$( $JSON_OUTPUT && echo true || echo false )}"
SCRIPT="${SCRIPT//WARN_LAG_VAL/$WARN_LAG}"
SCRIPT="${SCRIPT//WARN_CONN_VAL/$WARN_CONN}"
SCRIPT="${SCRIPT//WARN_CACHE_VAL/$WARN_CACHE}"
SCRIPT="${SCRIPT//WARN_OPLOG_VAL/$WARN_OPLOG}"

mongosh "$URI" --quiet --eval "$SCRIPT"
