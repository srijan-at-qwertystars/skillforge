#!/usr/bin/env bash
# =============================================================================
# index-analyzer.sh — Analyze MongoDB indexes for issues
#
# Finds unused, duplicate, and missing indexes across all collections.
#
# USAGE:
#   ./index-analyzer.sh [OPTIONS]
#
# OPTIONS:
#   -u, --uri URI        MongoDB connection URI (default: mongodb://localhost:27017)
#   -d, --db DATABASE    Database to analyze (required)
#   -c, --collection COL Analyze specific collection (default: all)
#   --min-ops N          Minimum ops to consider index "used" (default: 10)
#   --json               Output as JSON
#   -h, --help           Show this help
#
# REQUIREMENTS:
#   mongosh (MongoDB Shell) must be installed and on PATH
#
# EXAMPLES:
#   ./index-analyzer.sh -d myapp
#   ./index-analyzer.sh -u "mongodb://user:pass@host:27017" -d production
#   ./index-analyzer.sh -d myapp -c orders --min-ops 100
# =============================================================================

set -euo pipefail

# Defaults
URI="mongodb://localhost:27017"
DB=""
COLLECTION=""
MIN_OPS=10
JSON_OUTPUT=false

usage() {
  head -n 20 "$0" | grep '^#' | sed 's/^# \?//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -u|--uri) URI="$2"; shift 2 ;;
    -d|--db) DB="$2"; shift 2 ;;
    -c|--collection) COLLECTION="$2"; shift 2 ;;
    --min-ops) MIN_OPS="$2"; shift 2 ;;
    --json) JSON_OUTPUT=true; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

if [[ -z "$DB" ]]; then
  echo "ERROR: --db is required"
  usage
fi

# Build mongosh script
SCRIPT=$(cat <<'MONGOSCRIPT'
const dbName = DB_NAME;
const targetColl = TARGET_COLL;
const minOps = MIN_OPS_VAL;
const jsonOutput = JSON_OUTPUT_VAL;

const db = db.getSiblingDB(dbName);
const collections = targetColl ? [targetColl] : db.getCollectionNames().filter(c => !c.startsWith("system."));

const results = {
  unused: [],
  duplicate: [],
  missingForeignKeys: [],
  stats: { totalIndexes: 0, totalUnused: 0, totalDuplicate: 0 }
};

// ---- UNUSED INDEXES ----
collections.forEach(collName => {
  try {
    const indexStats = db[collName].aggregate([{ $indexStats: {} }]).toArray();
    indexStats.forEach(idx => {
      results.stats.totalIndexes++;
      if (idx.name === "_id_") return;
      if (idx.accesses.ops < minOps) {
        results.unused.push({
          collection: collName,
          index: idx.name,
          key: idx.key,
          ops: idx.accesses.ops,
          since: idx.accesses.since
        });
        results.stats.totalUnused++;
      }
    });
  } catch (e) {
    // skip views, timeseries system collections, etc.
  }
});

// ---- DUPLICATE / REDUNDANT INDEXES ----
collections.forEach(collName => {
  try {
    const indexes = db[collName].getIndexes();
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
          results.duplicate.push({
            collection: collName,
            redundantIndex: indexes[i].name,
            redundantKey: indexes[i].key,
            coveredByIndex: indexes[j].name,
            coveredByKey: indexes[j].key
          });
          results.stats.totalDuplicate++;
        }
      }
    }
  } catch (e) { /* skip */ }
});

// ---- MISSING INDEXES (check $lookup foreign fields via profiler) ----
try {
  const slowQueries = db.system.profile.find({
    planSummary: "COLLSCAN",
    millis: { $gt: 50 }
  }).sort({ ts: -1 }).limit(50).toArray();

  const collscanCollections = new Set();
  slowQueries.forEach(q => {
    const ns = q.ns ? q.ns.split(".").slice(1).join(".") : "";
    if (ns) collscanCollections.add(ns);
  });
  if (collscanCollections.size > 0) {
    results.missingForeignKeys = Array.from(collscanCollections).map(c => ({
      collection: c,
      note: "COLLSCAN detected in profiler — check query patterns and add indexes"
    }));
  }
} catch (e) {
  // profiler may not be enabled
}

// ---- OUTPUT ----
if (jsonOutput) {
  printjson(results);
} else {
  print("\n========================================");
  print(" MongoDB Index Analysis Report");
  print("========================================");
  print(`Database: ${dbName}`);
  print(`Total indexes scanned: ${results.stats.totalIndexes}`);
  print("");

  if (results.unused.length > 0) {
    print("--- UNUSED INDEXES ---");
    results.unused.forEach(u => {
      print(`  [${u.collection}] ${u.index} (${u.ops} ops since ${u.since})`);
      print(`    Key: ${JSON.stringify(u.key)}`);
    });
    print(`  Total: ${results.unused.length} unused indexes\n`);
  } else {
    print("--- UNUSED INDEXES: None found ---\n");
  }

  if (results.duplicate.length > 0) {
    print("--- REDUNDANT INDEXES (prefix of another) ---");
    results.duplicate.forEach(d => {
      print(`  [${d.collection}] ${d.redundantIndex} ${JSON.stringify(d.redundantKey)}`);
      print(`    covered by: ${d.coveredByIndex} ${JSON.stringify(d.coveredByKey)}`);
    });
    print(`  Total: ${results.duplicate.length} redundant indexes\n`);
  } else {
    print("--- REDUNDANT INDEXES: None found ---\n");
  }

  if (results.missingForeignKeys.length > 0) {
    print("--- COLLECTIONS WITH COLLSCAN (possible missing indexes) ---");
    results.missingForeignKeys.forEach(m => {
      print(`  [${m.collection}] ${m.note}`);
    });
    print("");
  }

  print("========================================");
  print(" Recommendations:");
  if (results.unused.length > 0) {
    print("  - Review unused indexes; consider hiding before dropping:");
    print("    db.collection.hideIndex('indexName')");
  }
  if (results.duplicate.length > 0) {
    print("  - Drop redundant prefix indexes to save write overhead and RAM");
  }
  print("  - Enable profiler to detect missing indexes:");
  print("    db.setProfilingLevel(1, { slowms: 100 })");
  print("========================================\n");
}
MONGOSCRIPT
)

# Substitute variables into script
SCRIPT="${SCRIPT//DB_NAME/\"$DB\"}"
SCRIPT="${SCRIPT//TARGET_COLL/\"$COLLECTION\"}"
SCRIPT="${SCRIPT//MIN_OPS_VAL/$MIN_OPS}"
if $JSON_OUTPUT; then
  SCRIPT="${SCRIPT//JSON_OUTPUT_VAL/true}"
else
  SCRIPT="${SCRIPT//JSON_OUTPUT_VAL/false}"
fi

mongosh "$URI" --quiet --eval "$SCRIPT"
