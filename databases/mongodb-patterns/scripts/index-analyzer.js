#!/usr/bin/env node
// ============================================================================
// index-analyzer.js — MongoDB Index Analyzer
// ============================================================================
// Analyzes collection indexes for unused, redundant, and potentially missing
// indexes. Connects to a MongoDB instance and inspects all collections in the
// specified database.
//
// Usage:
//   node index-analyzer.js                          # localhost:27017, test db
//   node index-analyzer.js --db myapp               # specific database
//   node index-analyzer.js --uri "mongodb+srv://..." --db prod
//   node index-analyzer.js --collection orders      # single collection
//   node index-analyzer.js --unused-days 7          # unused within 7 days
//   node index-analyzer.js --json                   # JSON output
//
// Requirements: Node.js 18+, mongodb driver (npm install mongodb)
//
// Options:
//   --uri           MongoDB connection URI (default: mongodb://localhost:27017)
//   --db            Database name (default: test)
//   --collection    Analyze a single collection (default: all)
//   --unused-days   Days threshold for "unused" index (default: 7)
//   --json          Output results as JSON
//   --help          Show help
// ============================================================================

const { MongoClient } = require("mongodb");

// Parse command-line arguments
const args = process.argv.slice(2);
const opts = {
  uri: "mongodb://localhost:27017",
  db: "test",
  collection: null,
  unusedDays: 7,
  json: false,
};

for (let i = 0; i < args.length; i++) {
  switch (args[i]) {
    case "--uri":
      opts.uri = args[++i];
      break;
    case "--db":
      opts.db = args[++i];
      break;
    case "--collection":
      opts.collection = args[++i];
      break;
    case "--unused-days":
      opts.unusedDays = parseInt(args[++i], 10);
      break;
    case "--json":
      opts.json = true;
      break;
    case "--help":
      console.log(
        [
          "Usage: node index-analyzer.js [options]",
          "",
          "Options:",
          "  --uri <uri>           MongoDB connection URI",
          "  --db <name>           Database name (default: test)",
          "  --collection <name>   Analyze single collection",
          "  --unused-days <n>     Days threshold for unused (default: 7)",
          "  --json                Output as JSON",
          "  --help                Show this help",
        ].join("\n")
      );
      process.exit(0);
  }
}

// Index analysis utilities

function isPrefix(shorter, longer) {
  const shortKeys = Object.keys(shorter);
  const longKeys = Object.keys(longer);
  if (shortKeys.length >= longKeys.length) return false;
  return shortKeys.every(
    (key, i) => key === longKeys[i] && shorter[key] === longer[key]
  );
}

function findRedundantIndexes(indexes) {
  const redundant = [];
  for (let i = 0; i < indexes.length; i++) {
    for (let j = 0; j < indexes.length; j++) {
      if (i === j) continue;
      if (isPrefix(indexes[i].key, indexes[j].key)) {
        // indexes[i] is a prefix of indexes[j] → indexes[i] is redundant
        if (
          !indexes[i].unique &&
          !indexes[i].sparse &&
          !indexes[i].partialFilterExpression
        ) {
          redundant.push({
            redundant: indexes[i].name,
            redundantKey: indexes[i].key,
            coveredBy: indexes[j].name,
            coveredByKey: indexes[j].key,
          });
        }
      }
    }
  }
  // Deduplicate
  const seen = new Set();
  return redundant.filter((r) => {
    const key = r.redundant;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

function findUnusedIndexes(indexStats, thresholdDays) {
  const threshold = new Date(Date.now() - thresholdDays * 24 * 60 * 60 * 1000);
  return indexStats
    .filter((stat) => {
      if (stat.name === "_id_") return false; // never drop _id
      const ops = stat.accesses?.ops ?? 0;
      const since = stat.accesses?.since
        ? new Date(stat.accesses.since)
        : new Date();
      return ops === 0 && since < threshold;
    })
    .map((stat) => ({
      name: stat.name,
      key: stat.key,
      accesses: stat.accesses?.ops ?? 0,
      since: stat.accesses?.since,
    }));
}

function suggestMissingIndexes(collStats, indexes) {
  const suggestions = [];
  const indexKeyStrings = indexes.map((idx) =>
    JSON.stringify(Object.keys(idx.key))
  );

  // Check if collection has no indexes besides _id
  if (indexes.length <= 1 && collStats.count > 10000) {
    suggestions.push({
      reason: "Large collection with only _id index",
      suggestion:
        "Analyze query patterns with db.setProfilingLevel(1) and add indexes for frequent queries",
    });
  }

  // Check for large collection with many indexes (write overhead)
  if (indexes.length > 10) {
    suggestions.push({
      reason: `${indexes.length} indexes — each write updates all indexes`,
      suggestion:
        "Review index usage and drop unused indexes to improve write performance",
    });
  }

  return suggestions;
}

async function analyzeCollection(db, collName) {
  const coll = db.collection(collName);
  const report = {
    collection: collName,
    indexes: [],
    unused: [],
    redundant: [],
    suggestions: [],
    totalIndexSize: 0,
  };

  try {
    // Get indexes
    const indexes = await coll.indexes();
    report.indexes = indexes.map((idx) => ({
      name: idx.name,
      key: idx.key,
      unique: idx.unique || false,
      sparse: idx.sparse || false,
      partial: !!idx.partialFilterExpression,
      ttl: idx.expireAfterSeconds != null,
    }));

    // Get index usage stats
    const indexStats = await coll
      .aggregate([{ $indexStats: {} }])
      .toArray();

    // Get collection stats
    const stats = await db.command({ collStats: collName });
    report.totalIndexSize = stats.totalIndexSize || 0;

    // Analyze
    report.unused = findUnusedIndexes(indexStats, opts.unusedDays);
    report.redundant = findRedundantIndexes(indexes);
    report.suggestions = suggestMissingIndexes(stats, indexes);
  } catch (err) {
    report.error = err.message;
  }

  return report;
}

function formatBytes(bytes) {
  if (bytes < 1024) return bytes + " B";
  if (bytes < 1048576) return (bytes / 1024).toFixed(1) + " KB";
  if (bytes < 1073741824) return (bytes / 1048576).toFixed(1) + " MB";
  return (bytes / 1073741824).toFixed(2) + " GB";
}

function printReport(reports) {
  console.log("\n══════════════════════════════════════════════════");
  console.log("  MongoDB Index Analysis Report");
  console.log("  Database:", opts.db);
  console.log("  Date:", new Date().toISOString());
  console.log("══════════════════════════════════════════════════\n");

  let totalIssues = 0;

  for (const report of reports) {
    if (report.error) {
      console.log(`▸ ${report.collection} — ERROR: ${report.error}\n`);
      continue;
    }

    const issues =
      report.unused.length +
      report.redundant.length +
      report.suggestions.length;
    totalIssues += issues;
    const status = issues === 0 ? "✓" : "⚠";

    console.log(
      `▸ ${report.collection} ${status} (${report.indexes.length} indexes, ${formatBytes(report.totalIndexSize)})`
    );

    // List all indexes
    for (const idx of report.indexes) {
      const flags = [
        idx.unique ? "unique" : "",
        idx.sparse ? "sparse" : "",
        idx.partial ? "partial" : "",
        idx.ttl ? "TTL" : "",
      ]
        .filter(Boolean)
        .join(", ");
      const flagStr = flags ? ` [${flags}]` : "";
      console.log(
        `    ${idx.name}: ${JSON.stringify(idx.key)}${flagStr}`
      );
    }

    // Unused indexes
    if (report.unused.length > 0) {
      console.log(`\n  ⚠ Unused indexes (0 ops in ${opts.unusedDays}+ days):`);
      for (const u of report.unused) {
        console.log(
          `    DROP: ${u.name} ${JSON.stringify(u.key)} (${u.accesses} ops since ${u.since})`
        );
      }
    }

    // Redundant indexes
    if (report.redundant.length > 0) {
      console.log("\n  ⚠ Redundant indexes (prefix covered by another):");
      for (const r of report.redundant) {
        console.log(
          `    DROP: ${r.redundant} ${JSON.stringify(r.redundantKey)}`
        );
        console.log(
          `      covered by: ${r.coveredBy} ${JSON.stringify(r.coveredByKey)}`
        );
      }
    }

    // Suggestions
    if (report.suggestions.length > 0) {
      console.log("\n  ℹ Suggestions:");
      for (const s of report.suggestions) {
        console.log(`    ${s.reason}`);
        console.log(`    → ${s.suggestion}`);
      }
    }

    console.log("");
  }

  // Summary
  console.log("──────────────────────────────────────────────────");
  console.log(
    `  Collections analyzed: ${reports.length}`
  );
  console.log(
    `  Total indexes: ${reports.reduce((s, r) => s + r.indexes.length, 0)}`
  );
  console.log(
    `  Unused: ${reports.reduce((s, r) => s + r.unused.length, 0)}`
  );
  console.log(
    `  Redundant: ${reports.reduce((s, r) => s + r.redundant.length, 0)}`
  );
  console.log(
    `  Total index size: ${formatBytes(reports.reduce((s, r) => s + r.totalIndexSize, 0))}`
  );
  console.log("──────────────────────────────────────────────────\n");
}

async function main() {
  const client = new MongoClient(opts.uri);
  try {
    await client.connect();
    const db = client.db(opts.db);

    let collections;
    if (opts.collection) {
      collections = [opts.collection];
    } else {
      const colls = await db.listCollections().toArray();
      collections = colls
        .filter(
          (c) =>
            c.type === "collection" &&
            !c.name.startsWith("system.")
        )
        .map((c) => c.name)
        .sort();
    }

    if (collections.length === 0) {
      console.log("No collections found in database:", opts.db);
      return;
    }

    const reports = [];
    for (const collName of collections) {
      reports.push(await analyzeCollection(db, collName));
    }

    if (opts.json) {
      console.log(JSON.stringify(reports, null, 2));
    } else {
      printReport(reports);
    }
  } catch (err) {
    console.error("Error:", err.message);
    process.exit(1);
  } finally {
    await client.close();
  }
}

main();
