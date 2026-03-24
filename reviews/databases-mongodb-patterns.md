# QA Review: databases/mongodb-patterns

**Reviewer:** Copilot CLI (automated)
**Date:** 2025-07-17
**Skill path:** `~/skillforge/databases/mongodb-patterns/`

---

## a. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter | ✅ Pass | `name`, `description` with TRIGGERS/NOT-for present |
| Line count | ✅ Pass | 499 lines (limit: 500) |
| Imperative voice | ✅ Pass | Direct commands and patterns throughout |
| Code examples | ✅ Pass | Every section has runnable code blocks |
| References linked | ✅ Pass | 3 reference guides (advanced-patterns, troubleshooting, mongoose-guide) — all exist with substantive content (973–1,246 lines each) |
| Scripts linked | ✅ Pass | 3 scripts (health-check, index-analyzer, backup-restore) — all exist (288–355 lines) |
| Assets linked | ✅ Pass | 5 assets (aggregation-templates, mongoose-model, docker-compose, mongosh-snippets, atlas-terraform) — all exist (171–421 lines) |
| Total supporting files | — | 11 files, 5,902 lines of supplementary content |

---

## b. Content Check

### Verified Claims (web-search confirmed)

| Claim in SKILL.md | Verified? | Source |
|--------------------|-----------|--------|
| MongoDB 8.0: 56% faster bulk writes | ✅ Accurate | MongoDB 8.0 release notes, SD Times, I-Programmer |
| Resharding up to 50x faster | ✅ Accurate | Percona, InfoQ, BytePlus docs |
| `workingMillis` profiler metric (8.0) | ✅ Accurate | MongoDB 8.0 release notes |
| Quantized vectors in 8.0 | ✅ Accurate | MongoDB 8.0 release notes |
| 200% faster time-series aggregations (8.0) | ✅ Accurate | Multiple sources |
| Queryable Encryption range queries (8.0) | ✅ Accurate | MongoDB 8.0 release notes |
| Oplog optimization for transactions (8.0) | ✅ Accurate | Alibaba Cloud, BytePlus docs |

### Issues Found

| Severity | Location | Issue |
|----------|----------|-------|
| Minor | Line 241 | `sh.enableSharding("ecommerce")` is deprecated since MongoDB 6.0 and is a no-op in 7.x/8.x. Modern code should use `sh.shardCollection()` directly. The skill should note this deprecation or remove the call. |
| Nitpick | Line 252 | "Avoid `_id` (ObjectId) as sole ranged shard key" — correct advice but could link to MongoDB docs for the `_id` limitation rationale. |

### Missing Content (minor gaps, not blocking)

- No mention of MongoDB 8.0's `bulkWrite` command (new server-side command for multi-collection bulk ops, distinct from `db.collection.bulkWrite()`)
- No coverage of `$queryStats` aggregation stage (mentioned in description but absent from body)
- Connection string URI format (SRV vs standard) not covered in main file (may be in references)

---

## c. Trigger Check

### Positive Triggers Analysis

| Trigger | MongoDB-specific? | Risk of false positive |
|---------|-------------------|----------------------|
| MongoDB, mongosh, mongod | ✅ Unique | None |
| aggregation pipeline | ⚠️ Moderate | Could match Elasticsearch or general data pipeline discussions |
| MongoDB Atlas | ✅ Unique | None |
| mongoose, BSON, ObjectId | ✅ Unique | None |
| $lookup, GridFS | ✅ Unique | None |
| sharding key | ⚠️ Low | Could match general sharding, but combined with other triggers minimizes risk |
| change streams | ⚠️ Low | Term exists in other event-streaming contexts |
| MongoDB Compass, MongoDB indexes | ✅ Unique | None |
| replica set | ⚠️ Low | Generic term, but in MongoDB context is well-understood |

### Negative Triggers

Explicit exclusions: PostgreSQL, MySQL, Redis, DynamoDB, CouchDB, general NoSQL — **well-defined boundary**.

### Cross-trigger Test

- **PostgreSQL query** → Would NOT trigger (excluded explicitly) ✅
- **Redis caching pattern** → Would NOT trigger (excluded explicitly) ✅
- **"NoSQL schema design"** (no MongoDB context) → Would NOT trigger (excluded) ✅
- **"aggregation pipeline for data ETL"** → Could false-trigger ⚠️ but low risk given other trigger words needed in practice

**Verdict:** Triggers are well-scoped with minimal false-positive risk.

---

## d. Scoring

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 4 | All MongoDB 8.0 claims verified. Minor issue: `sh.enableSharding()` deprecated since 6.0 but shown without deprecation note. |
| **Completeness** | 5 | Comprehensive: CRUD, aggregation, 6 index types, 5 schema patterns, replica sets, sharding, transactions, change streams, Atlas Search/Vector, Mongoose, performance tuning, security, mongosh reference. 11 supporting files (5,902 lines). |
| **Actionability** | 5 | Every section has copy-paste-ready code. Includes decision matrix for embedding vs referencing, ESR indexing rule, explain plan interpretation, 3 operational scripts, 5 asset templates. |
| **Trigger quality** | 4 | Strong positive triggers (13 MongoDB-specific terms). Clear negative boundary (6 excluded technologies). Minor ambiguity with "aggregation pipeline" and "replica set" in isolation. |

**Overall: 4.5 / 5.0** ✅

---

## e. Action Items

1. **[Minor]** Add deprecation note to `sh.enableSharding()` on line 241 or replace with a comment explaining it's no longer required in 7.x+
2. **[Minor]** Add `$queryStats` example (mentioned in description but missing from body)
3. **[Nitpick]** Consider adding MongoDB 8.0 `bulkWrite` server command coverage in advanced-patterns.md

---

## f. GitHub Issues

**Not required.** Overall score (4.5) ≥ 4.0 and no dimension ≤ 2.

---

## g. SKILL.md Tag

`<!-- tested: pass -->` appended to SKILL.md.
