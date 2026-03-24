# Review: mongodb-patterns

**Reviewed:** SKILL.md + 4 references, 5 scripts, 6 assets
**Date:** 2025-07-17

## Scores

Accuracy: 4/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 5/5
Overall: 4.8/5

## Structure Check

- [x] **YAML frontmatter:** Has `name` and `description` fields — both present and well-formed.
- [x] **Positive triggers:** 17 positive trigger phrases covering schema design, aggregation, indexing, replica sets, sharding, change streams, transactions, mongoose, performance tuning, connection pooling, bucket/outlier patterns, anti-patterns, TTL index, compound index.
- [x] **Negative triggers:** 11 negative trigger phrases — SQL, PostgreSQL, MySQL, DynamoDB, Redis, Elasticsearch, Neo4j, Cassandra, CockroachDB, SQLite, relational normalization.
- [x] **Under 500 lines:** SKILL.md is 417 lines. ✓
- [x] **Imperative voice:** Uses imperative throughout ("Embed when", "Follow the filter → project → transform order", "Place first for index use", "Order fields: Equality → Sort → Range"). ✓
- [x] **Examples:** Rich code examples in every section — embedding vs referencing, polymorphic, bucket, outlier, aggregation pipeline, indexing (7 types), replica sets, sharding (4 strategies), change streams, transactions, explain plans, profiler, connection pooling, write concern, mongoose. ✓
- [x] **Links to references/scripts:** Tables at bottom link to 3 references, 3 scripts, and 2 assets with descriptions. ✓

### Minor structural notes
- `references/mongoose-guide.md` exists on disk but is **not listed** in the SKILL.md references table. This is unreferenced content that won't be discovered by consumers.
- Duplicate assets: `docker-compose.yaml` and `docker-compose-mongo.yml` serve overlapping purposes (3-node replica set). The second adds Mongo Express UI and auto-init, which is better for dev — but having two unlabeled may confuse users.
- Duplicate scripts: `health-check.sh` and `mongo-health-check.sh` do the same job with slightly different approaches. `index-analyzer.sh` and `index-analyzer.js` overlap (bash+mongosh vs Node.js). SKILL.md only references one of each pair, but the extras sit in the directory.

## Content Check

### Verified correct ✓
- **16MB BSON document limit** — confirmed current in MongoDB 7. ✓
- **100MB aggregation RAM default** — confirmed; `allowDiskUse: true` bypasses it. ✓ (Note: MongoDB 6+ added `allowDiskUseByDefault` server param — not mentioned but acceptable omission.)
- **60-second default transaction timeout** — confirmed. ✓
- **ESR rule (Equality → Sort → Range)** — correctly stated and demonstrated. ✓
- **Multikey index limit** (max one array field per compound index) — correct. ✓
- **One text index per collection** — correct. ✓
- **Change streams require replica set** — correct. ✓
- **Read preferences table** — all 5 modes accurately described. ✓
- **`$indexStats`** for auditing unused indexes — correct. ✓
- **`$group` blocking stage** with 100MB RAM limit — correct. ✓

### Issues found

1. **Shard key "immutable" claim is outdated (Medium):**
   SKILL.md line 236 says: *"Shard key is immutable after creation. Choose carefully."*
   Since MongoDB 5.0, `reshardCollection` allows completely changing a shard key. Since 4.4, `refineCollectionShardKey` allows adding suffix fields. The statement was true pre-5.0 but is misleading for MongoDB 7 users. Should say: *"Shard key is difficult to change after creation — MongoDB 5.0+ supports `reshardCollection` but it's heavyweight. Choose carefully."*

2. **Transaction 1000-doc limit presented as hard rule (Low):**
   SKILL.md line 304 says: *"Limit to 1000 docs modified."*
   This is a **best practice recommendation**, not a hard technical limit. MongoDB has no hard-coded 1000-doc cap. The phrasing should clarify: *"Best practice: limit to ~1000 docs modified per transaction."*

### Missing gotchas (minor, non-blocking)
- No mention of `allowDiskUseByDefault` server parameter (MongoDB 6+).
- Sharding section doesn't mention `reshardCollection` or `refineCollectionShardKey`.
- No mention of the 16MB oplog entry size limit for single transactions.

### Examples correctness
- All JavaScript/mongosh code examples are syntactically correct. ✓
- Aggregation pipeline example follows stated ordering rules. ✓
- Docker Compose files are valid YAML with correct mongo:7 images. ✓
- Terraform config uses correct `mongodbatlas` provider resources. ✓
- Mongoose TypeScript template compiles conceptually (proper generic signatures, discriminators, virtuals, middleware). ✓
- Shell scripts use `set -euo pipefail`, proper option parsing, and safe credential masking. ✓

## Trigger Check

### Would it trigger correctly?
- "How do I design a MongoDB schema?" → **Yes** (matches "MongoDB schema design")
- "Optimize my MongoDB aggregation pipeline" → **Yes** (matches "MongoDB aggregation")
- "MongoDB compound index ordering" → **Yes** (matches "compound index", "MongoDB indexing")
- "Mongoose discriminator pattern" → **Yes** (matches "mongoose schema")
- "MongoDB bucket pattern for time series" → **Yes** (matches "bucket pattern")
- "MongoDB connection pool settings" → **Yes** (matches "MongoDB connection pooling")
- "Change streams resume token" → **Yes** (matches "change streams")

### False trigger check
- "Optimize my PostgreSQL query" → **No** (excluded by "PostgreSQL queries")
- "DynamoDB single-table design" → **No** (excluded by "DynamoDB patterns")
- "SQL JOIN optimization" → **No** (excluded by "SQL database design")
- "Redis cache invalidation" → **No** (excluded by "Redis caching")
- "Elasticsearch full-text search" → **No** (excluded by "Elasticsearch queries")

Trigger quality is excellent — comprehensive positive keywords with explicit negative exclusions for all major competing databases.

## Summary

Issues: 2

1. Shard key immutability claim is outdated for MongoDB 5.0+ (line 236) — should mention `reshardCollection`.
2. Transaction 1000-doc limit stated as hard rule instead of best practice (line 304).

Both issues are minor accuracy nuances — the core advice ("choose carefully", "keep transactions short") remains sound. No dimension scores ≤ 2, overall is 4.8 — no GitHub issue filing required.

## Verdict: **PASS**
