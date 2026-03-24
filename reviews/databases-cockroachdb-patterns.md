# QA Review: databases/cockroachdb-patterns

**Reviewer**: Copilot QA  
**Date**: 2025-07-18  
**Skill path**: `~/skillforge/databases/cockroachdb-patterns/`

---

## A. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter | ✅ Pass | `name`, `description` with +/- triggers present |
| Line count | ✅ Pass | 489 lines (limit: 500) |
| Imperative voice | ✅ Pass | Consistent throughout ("Use", "Never use", "Keep", "Monitor") |
| Code examples | ✅ Pass | Extensive examples for every section (SQL, Python, Bash) |
| References linked | ✅ Pass | 3 reference docs (multi-region, troubleshooting, migration) — all present |
| Scripts linked | ✅ Pass | 3 scripts (setup, health-check, backup) — all present and executable (`chmod +x`) |
| Assets linked | ✅ Pass | 5 assets (docker-compose, schema SQL, Go/Python retry, Helm values) — all present |

**Verdict**: Structure is exemplary. Well-organized with clear sections, decision matrix table, anti-patterns list, and comprehensive supporting materials.

---

## B. Content Check

### Verified Correct
- **Follower reads 4.2s staleness**: Confirmed via CockroachDB docs — `follower_read_timestamp()` returns `statement_timestamp() - 4.2s`
- **REGIONAL BY ROW / crdb_region**: Syntax and automatic column behavior confirmed correct
- **CREATE INDEX CONCURRENTLY**: Supported syntax confirmed
- **SAVEPOINT cockroach_restart retry pattern**: Correct canonical pattern for 40001 retries
- **Hash-sharded index syntax**: `USING HASH WITH (bucket_count = N)` confirmed
- **Multi-region setup**: `ALTER DATABASE ... PRIMARY REGION` / `ADD REGION` syntax correct
- **Changefeed syntax**: `CREATE CHANGEFEED FOR TABLE ... INTO 'kafka://...'` correct
- **Backup/Restore syntax**: `BACKUP INTO` / `RESTORE FROM LATEST IN` correct
- **Range size ~64 MiB**: Confirmed default

### Issues Found

#### 🔴 Inaccuracy: READ COMMITTED isolation (Medium severity)
**Line 445**: States "all transactions are serializable (no READ COMMITTED option by default)"  
**Reality**: As of CockroachDB v24.1, READ COMMITTED isolation is **fully supported and enabled by default**. Transactions requesting READ COMMITTED now get true READ COMMITTED semantics. The current statement is outdated and could mislead users migrating from PostgreSQL.  
**Fix**: Update to note that v24.1+ supports READ COMMITTED by default, while older versions silently promoted to SERIALIZABLE.

#### 🟡 Imprecision: GC TTL default (Low severity)
**Line 264**: States "default 4 hours"  
**Reality**: The default changed from 25 hours (90,000s) to 4 hours (14,400s) in v23.1 for CockroachDB Dedicated. Self-hosted deployments may still use 25 hours depending on version. Should note version dependency.  
**Fix**: Qualify as "default 4h in v23.1+; previously 25h".

#### 🟡 Missing content: Super Regions (Low severity)
No mention of super regions (`ALTER DATABASE ... ADD SUPER REGION`) for data domiciling/compliance, which is an important multi-region feature for regulated industries.

#### 🟡 Missing content: Row-Level TTL (Low severity)
No mention of CockroachDB's built-in row-level TTL (`WITH (ttl_expiration_expression = ...)`) for automatic data expiration — a commonly used feature for time-series and compliance use cases.

---

## C. Trigger Check

### Positive Triggers Assessment
| Trigger | Specificity | Risk of False Trigger |
|---------|------------|----------------------|
| `CockroachDB` | ✅ Excellent | None |
| `CRDB` | ✅ Excellent | None |
| `cockroach sql` | ✅ Excellent | None |
| `hash-sharded index` | ✅ Excellent | None |
| `regional by row` | ✅ Excellent | None |
| `CRDB changefeed` | ✅ Excellent | None |
| `follower reads` | ✅ Good | Minimal (Spanner term differs) |
| `AS OF SYSTEM TIME` | ✅ Good | Minimal (CRDB-specific syntax) |
| `distributed SQL database` | ⚠️ Broad | Could match YugabyteDB, TiDB, Spanner |
| `multi-region database` | ⚠️ Broad | Could match Spanner, PlanetScale, YugabyteDB |
| `serializable transactions` | ⚠️ Broad | Could match any DB with serializable isolation |
| `changefeeds` | ⚠️ Moderate | Could match generic CDC discussions |

### Negative Triggers Assessment
- ✅ Correctly excludes: PostgreSQL (without CRDB), MySQL, MongoDB, SQLite, DynamoDB, single-node, general SQL tutorial
- ⚠️ **Missing negatives**: YugabyteDB, TiDB, Google Cloud Spanner, CockroachDB alternatives — these are the most likely false-trigger sources from the broad positive triggers

### PostgreSQL False-Trigger Risk
**Low-Medium**. The negative trigger "PostgreSQL without CockroachDB" should prevent most false triggers. However, the broad triggers (`distributed SQL database`, `multi-region database`) could fire for PostgreSQL with Citus or other distributed PostgreSQL extensions. Overall trigger design is solid for the primary use case.

---

## D. Scoring

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 4 / 5 | READ COMMITTED claim is outdated for v24.1+. GC TTL default is imprecise. All other syntax and concepts verified correct. |
| **Completeness** | 4 / 5 | Excellent coverage of core topics. Missing super regions, row-level TTL. Strong supporting materials (3 reference docs, 3 scripts, 5 assets). |
| **Actionability** | 5 / 5 | Outstanding. Every concept backed by copy-paste-ready code. Decision matrix for locality patterns. Anti-patterns list. Docker Compose for local testing. Go + Python retry implementations. Helm chart for K8s deployment. |
| **Trigger Quality** | 4 / 5 | 8/12 positive triggers are CockroachDB-specific and excellent. 4 broad triggers pose minor false-trigger risk. Missing negative triggers for competing distributed SQL databases. |

### Overall: **4.25 / 5.0** ✅

---

## E. Recommendations

1. **Update READ COMMITTED section** (accuracy fix): Revise PostgreSQL compatibility notes to reflect v24.1+ READ COMMITTED support.
2. **Add version note to GC TTL**: Qualify the 4-hour default with version context.
3. **Add super regions**: Brief section or mention in multi-region configuration.
4. **Add row-level TTL**: Brief section or anti-pattern note.
5. **Tighten triggers**: Add negative triggers for `YugabyteDB`, `TiDB`, `Google Spanner`. Consider qualifying broad positives (e.g., "distributed SQL database" → "CockroachDB distributed SQL").

---

## F. Issue Filing

**Not required** — overall score 4.25 ≥ 4.0 and no dimension ≤ 2.

---

## G. Test Result

**PASS** — skill is production-quality with minor improvements recommended.
