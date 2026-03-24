# Review: mysql-tuning

Accuracy: 4/5
Completeness: 4/5
Actionability: 5/5
Trigger quality: 5/5
Overall: 4.5/5
Issues: [listed below]

---

## Structure Check

- [x] YAML frontmatter has `name` and `description`
- [x] Description includes positive triggers (MySQL slow queries, InnoDB tuning, EXPLAIN, pt-query-digest, etc.) AND negative triggers (PostgreSQL, MongoDB, Redis, MariaDB-specific, NoSQL, SQLite)
- [x] Body under 500 lines (493 lines)
- [x] Imperative voice, no filler — direct commands throughout
- [x] Examples with input/output — SQL queries with BAD/GOOD pairs, expected output columns described
- [x] references/ (3 docs, ~700 lines each) and scripts/ (3 scripts) properly linked from SKILL.md with usage examples
- [x] assets/ (my.cnf.template, monitoring-queries.sql) documented in SKILL.md table

## Content Check — Accuracy Issues

### 1. DATETIME vs TIMESTAMP size claim is wrong (SKILL.md line 303)
**Claim**: "DATETIME → TIMESTAMP: 4 bytes vs 8 bytes"
**Fact**: Since MySQL 5.6.4, DATETIME is 5 bytes (not 8) without fractional seconds. TIMESTAMP is 4 bytes. Savings is 1 byte/row, not 4. The "8 bytes" figure is only correct for DATETIME(6) with microsecond precision, or pre-5.6.4 MySQL.
**Fix**: Change to "5 bytes vs 4 bytes" or "5-8 bytes vs 4-7 bytes (depending on fractional seconds precision)"

### 2. `expire_logs_days` is deprecated (SKILL.md line 265)
The Replication Tuning section uses `expire_logs_days = 7`, which is deprecated in MySQL 8.0 in favor of `binlog_expire_logs_seconds`. The tune-config.sh script correctly uses `binlog_expire_logs_seconds = 604800`, but SKILL.md body does not.
**Fix**: Replace with `binlog_expire_logs_seconds = 604800  # 7 days`

### 3. `innodb_log_file_size` deprecated in 8.0.30+ (SKILL.md line 331)
The Key Variables Reference lists `innodb_log_file_size` without noting it's deprecated in MySQL 8.0.30+ and replaced by `innodb_redo_log_capacity`. The tune-config.sh script correctly uses the new variable, but the SKILL.md body does not mention the migration.
**Fix**: Add `innodb_redo_log_capacity` as the preferred variable for 8.0.30+ alongside or replacing `innodb_log_file_size`

### 4. Duplicate index detection query has false positives (SKILL.md lines 165-171)
The query groups by `COLUMN_NAME` and flags any column appearing in multiple indexes — this incorrectly flags legitimate cases where a column is the leading column of one composite index and included in another. `pt-duplicate-key-checker` is more reliable for this.
**Fix**: Add a caveat or recommend `pt-duplicate-key-checker` as the primary method

### 5. ProxySQL config format is illustrative, not real (SKILL.md lines 237-241)
ProxySQL uses a SQL-like admin interface, not INI-style config blocks. The shown config won't work as-is.
**Fix**: Minor — add a comment noting this is conceptual, or show actual ProxySQL admin SQL

## Content Check — Missing Gotchas

1. **Partition key constraint**: InnoDB requires the partition key to be part of every unique key and the primary key. The partitioning example (line 312) doesn't mention this — a real engineer would hit this immediately.
2. **`innodb_log_file_size` → `innodb_redo_log_capacity` migration path**: Users on 8.0.30+ need to know the old variable is ignored when the new one is set.
3. **TIMESTAMP Y2038 problem**: The schema optimization table recommends TIMESTAMP over DATETIME but doesn't mention the range limit (1970-2038).
4. **Online DDL limitations**: Not all ALTER TABLE operations support `ALGORITHM=INSTANT` or `ALGORITHM=INPLACE` — worth noting when recommending index additions.

## Content Check — Positives

- Scripts are production-grade with argument parsing, error handling, `--help`, and `set -euo pipefail`
- `analyze-slow-queries.sh` gracefully falls back from pt-query-digest to built-in awk analysis
- `tune-config.sh` auto-detects RAM/CPU, supports OLTP/OLAP/mixed + SSD/NVMe/HDD, generates commented config
- `health-check.sh` covers buffer pool, threads, table cache, temp tables, slow queries, locks, I/O, replication
- `monitoring-queries.sql` is comprehensive: 10 categories with alerting thresholds
- `my.cnf.template` has three server-size profiles (small/medium/large)
- Reference docs cover advanced InnoDB internals, performance schema, and troubleshooting in depth
- Anti-patterns section (N+1, implicit type conversion, unbounded IN, missing LIMIT) is practical
- Production checklist is actionable

## Trigger Check

- **Positive triggers**: Comprehensive — covers MySQL slow queries, InnoDB tuning, EXPLAIN, indexing, my.cnf, pt-query-digest, mysqldumpslow, buffer pool, connection pooling, replication, schema optimization
- **Negative triggers**: Explicitly excludes PostgreSQL, MongoDB, Redis, SQLite, MariaDB-specific, NoSQL, general SQL syntax, app-level caching
- **False positive risk for PostgreSQL/MongoDB**: Very low — both explicitly excluded
- **Would trigger for real MySQL tuning queries**: Yes — keyword coverage is thorough
- **Edge case**: "MariaDB tuning" correctly excluded since MariaDB has diverged significantly (e.g., Aria engine, thread pool, Galera-specific config)

## Verdict

**PASS** — High-quality skill with minor accuracy issues that don't impede practical use. The deprecated variable usage and DATETIME size claim should be corrected but are not blocking. Scripts and references are excellent.
