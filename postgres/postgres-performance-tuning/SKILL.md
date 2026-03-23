---
name: postgres-performance-tuning
description: >
  Use when user asks about PostgreSQL query optimization, slow queries, EXPLAIN ANALYZE interpretation,
  index strategy, pg_stat views, connection pooling (PgBouncer), vacuum tuning, or postgresql.conf tuning.
  Do NOT use for basic SQL syntax, PostgreSQL installation, schema design philosophy, or other databases
  (MySQL, MongoDB).
---

# PostgreSQL Performance Tuning

## Reading EXPLAIN ANALYZE Output

Always run with BUFFERS and SETTINGS for full diagnostics:

```sql
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT) SELECT ...;
```

### Key fields in each node

| Field | Meaning |
|---|---|
| `cost=0.42..128.17` | Startup cost .. total cost (in arbitrary planner units) |
| `rows=1000` | Estimated rows the node will return |
| `actual time=0.03..12.5` | Wall-clock ms for first row .. all rows |
| `rows=987` | Actual rows returned |
| `loops=1` | Times this node executed (watch for high loops in nested loops) |
| `Buffers: shared hit=42 read=3` | Pages from cache vs disk. High `read` = cold cache or table too large for RAM |
| `I/O Timings` | Requires `track_io_timing = on`. Shows actual disk wait |

### Sample output walkthrough

```
Nested Loop  (cost=1.00..5000.00 rows=100 actual time=0.05..45.30 rows=98 loops=1)
  -> Index Scan using idx_orders_user on orders  (cost=0.42..8.44 rows=1 actual time=0.02..0.03 rows=1 loops=1)
        Index Cond: (user_id = 42)
        Buffers: shared hit=3
  -> Index Scan using idx_items_order on order_items  (cost=0.56..40.12 rows=100 actual time=0.01..0.35 rows=98 loops=1)
        Index Cond: (order_id = orders.id)
        Buffers: shared hit=120 read=5
Planning Time: 0.2 ms
Execution Time: 45.8 ms
```

**Red flags to watch for:**
- `Seq Scan` on large tables when an index scan is expected — missing or unusable index.
- `actual rows` vastly different from `rows` estimate — run `ANALYZE` on the table.
- `loops=10000` on an inner node — sign of N+1 join pattern; consider a hash or merge join.
- `Buffers: ... read=` much larger than `hit=` — working set exceeds `shared_buffers`.
- `Sort Method: external merge Disk` — `work_mem` too low for this query.

---

## Index Types and When to Use Each

### B-tree (default)
Use for equality (`=`), range (`<`, `>`, `BETWEEN`), sorting, and `IS NULL`. Covers 90%+ of indexing needs.

```sql
CREATE INDEX idx_orders_created ON orders (created_at);
```

### GIN (Generalized Inverted Index)
Use for full-text search (`tsvector`), JSONB containment (`@>`), array overlap (`&&`), and trigram similarity (`pg_trgm`).

```sql
CREATE INDEX idx_docs_fts ON documents USING gin(to_tsvector('english', body));
CREATE INDEX idx_data_jsonb ON events USING gin(payload jsonb_path_ops);
```

### GiST (Generalized Search Tree)
Use for geometric/spatial data (PostGIS), range types, and nearest-neighbor (`<->`) queries.

```sql
CREATE INDEX idx_geo ON locations USING gist(coordinates);
```

### BRIN (Block Range Index)
Use for naturally ordered large tables (time-series, append-only logs). Tiny on disk. Only effective when physical row order correlates with the indexed column.

```sql
CREATE INDEX idx_logs_ts ON logs USING brin(created_at) WITH (pages_per_range = 32);
```

### Hash
Use only for pure equality lookups. Not WAL-logged before PG 10. Rarely better than B-tree; consider only when B-tree overhead matters on very large, equality-only columns.

```sql
CREATE INDEX idx_sessions_token ON sessions USING hash(token);
```

---

## Composite Index Design

### Column ordering rules
1. Put equality columns first (`WHERE status = 'active'`).
2. Put the range/sort column last (`WHERE created_at > '2025-01-01'`).
3. The index is usable for any left prefix of its columns.

```sql
-- Supports: WHERE tenant_id = 1 AND status = 'active' AND created_at > now() - interval '7d'
-- Also supports: WHERE tenant_id = 1
-- Does NOT support: WHERE status = 'active' (skips leading column)
CREATE INDEX idx_orders_composite ON orders (tenant_id, status, created_at);
```

### Covering indexes (INCLUDE)
Add columns the query SELECTs to enable index-only scans:

```sql
CREATE INDEX idx_orders_cover ON orders (user_id, status) INCLUDE (total, created_at);
```

### Partial indexes
Index only the rows that matter:

```sql
CREATE INDEX idx_active_orders ON orders (created_at) WHERE status = 'pending';
```

### Expression indexes
Index computed values to avoid function calls at query time:

```sql
CREATE INDEX idx_users_lower_email ON users (lower(email));
```

---

## Common Query Anti-Patterns and Fixes

### N+1 queries
**Problem:** ORM loops issuing one query per parent row.
**Fix:** Use `JOIN` or batch `WHERE id = ANY($1::int[])`. In ORMs, enable eager loading.

### Implicit type casts
**Problem:** `WHERE varchar_col = 123` forces a cast; index cannot be used.
**Fix:** Match types exactly: `WHERE varchar_col = '123'`.

### Functions on indexed columns
**Problem:** `WHERE LOWER(email) = 'x@y.com'` skips the B-tree index on `email`.
**Fix:** Create an expression index on `lower(email)`, or store pre-lowered values.

### SELECT * with large rows
**Problem:** Fetches TOASTed columns even when unused, causing excess I/O.
**Fix:** Select only needed columns. Use covering indexes for index-only scans.

### Missing LIMIT on existence checks
**Problem:** `SELECT count(*) FROM t WHERE cond` scans all matches.
**Fix:** `SELECT EXISTS (SELECT 1 FROM t WHERE cond)` — stops at first match.

### OR conditions defeating indexes
**Problem:** `WHERE a = 1 OR b = 2` — cannot use a single composite index.
**Fix:** Rewrite as `UNION ALL` of two indexed queries, or use a GIN index with `btree_gin`.

---

## postgresql.conf Key Settings

### Memory

| Setting | Guideline | Notes |
|---|---|---|
| `shared_buffers` | 25% of RAM (start), up to 40% | PostgreSQL page cache. Monitor cache hit ratio > 99% |
| `effective_cache_size` | 50–75% of RAM | Hint to planner about OS cache; does not allocate memory |
| `work_mem` | 4–64 MB | Per-sort/hash operation. `work_mem × max_connections × ops` must fit in RAM |
| `maintenance_work_mem` | 256 MB – 2 GB | For VACUUM, CREATE INDEX. Set higher during bulk loads |
| `huge_pages` | `try` or `on` | Reduces TLB misses on Linux; configure OS `vm.nr_hugepages` |

### WAL & Checkpoints

| Setting | Guideline |
|---|---|
| `wal_buffers` | 64 MB (or `-1` for auto) |
| `checkpoint_completion_target` | `0.9` |
| `max_wal_size` | 2–8 GB depending on write volume |
| `min_wal_size` | 1 GB |

### Parallelism

| Setting | Guideline |
|---|---|
| `max_parallel_workers_per_gather` | 2–4 for OLTP, up to 8 for analytics |
| `max_parallel_workers` | Number of CPU cores |
| `parallel_tuple_cost` | Lower (e.g., 0.01) to encourage parallel plans |

### Planner

| Setting | When to change |
|---|---|
| `random_page_cost` | Set to `1.1` on SSD (default 4.0 assumes spinning disk) |
| `effective_io_concurrency` | `200` for SSD, `2` for HDD |
| `default_statistics_target` | Increase to 500–1000 for columns with skewed distributions |

---

## Vacuum and Autovacuum Tuning

### Why vacuum matters
Dead tuples from UPDATE/DELETE are not reclaimed until VACUUM runs. Table bloat causes larger sequential scans, wasted buffer cache, and eventually transaction ID wraparound (forced shutdown).

### Critical autovacuum parameters

```
autovacuum_max_workers = 4               -- default 3; raise for many tables
autovacuum_naptime = 30s                 -- default 1min; lower for high-churn DBs
autovacuum_vacuum_scale_factor = 0.05    -- default 0.2; vacuum at 5% dead tuples
autovacuum_vacuum_threshold = 50         -- absolute minimum dead tuples
autovacuum_analyze_scale_factor = 0.02   -- re-analyze at 2% changed rows
autovacuum_vacuum_cost_delay = 2ms       -- default 2ms; set to 0 on fast storage
autovacuum_vacuum_cost_limit = 1000      -- default 200; raise to let vacuum work faster
```

### Per-table overrides for hot tables

```sql
ALTER TABLE events SET (
  autovacuum_vacuum_scale_factor = 0.01,
  autovacuum_vacuum_threshold = 1000,
  autovacuum_analyze_scale_factor = 0.005
);
```

### Monitoring vacuum health

```sql
SELECT relname, n_dead_tup, n_live_tup,
       round(n_dead_tup::numeric / greatest(n_live_tup, 1) * 100, 2) AS dead_pct,
       last_autovacuum, last_autoanalyze
FROM pg_stat_user_tables
ORDER BY n_dead_tup DESC
LIMIT 20;
```

Watch for `dead_pct > 10%` or `last_autovacuum` being hours/days old on active tables.

---

## Connection Pooling with PgBouncer

### Why pool
PostgreSQL forks a process per connection (~5–10 MB each). At 500+ connections, memory and context-switching overhead dominates. PgBouncer multiplexes thousands of client connections into a small pool of server connections.

### Recommended PgBouncer settings

```ini
[pgbouncer]
pool_mode = transaction          ; best for web apps; session mode for PREPARE/SET
max_client_conn = 2000
default_pool_size = 25           ; server connections per db/user pair
reserve_pool_size = 5            ; burst headroom
reserve_pool_timeout = 3
server_idle_timeout = 300
server_lifetime = 3600
log_connections = 0
log_disconnections = 0
```

### PostgreSQL side adjustments
- Set `max_connections` to `default_pool_size × db_count + overhead` (e.g., 100–200).
- Reduce `work_mem` if pool size is small (fewer concurrent queries).

### Transaction mode caveats
Cannot use `SET`, `PREPARE`, `LISTEN/NOTIFY`, temp tables, or advisory locks across queries. Use `SET LOCAL` inside explicit transactions instead.

---

## pg_stat_statements and pg_stat_user_tables

### Enable pg_stat_statements

```
shared_preload_libraries = 'pg_stat_statements'
pg_stat_statements.max = 10000
pg_stat_statements.track = all
```

### Find slowest queries by total time

```sql
SELECT queryid, calls, total_exec_time::int AS total_ms,
       mean_exec_time::int AS avg_ms,
       rows, shared_blks_hit, shared_blks_read
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 20;
```

### Find cache-miss-heavy queries

```sql
SELECT queryid, calls,
       shared_blks_read AS disk_reads,
       shared_blks_hit AS cache_hits,
       round(shared_blks_read::numeric / greatest(shared_blks_hit + shared_blks_read, 1) * 100, 2) AS miss_pct
FROM pg_stat_statements
WHERE shared_blks_read > 1000
ORDER BY shared_blks_read DESC
LIMIT 10;
```

### Key pg_stat_user_tables columns

| Column | Use |
|---|---|
| `seq_scan` / `seq_tup_read` | High values on large tables → missing index |
| `idx_scan` / `idx_tup_fetch` | Confirms index usage |
| `n_tup_ins/upd/del` | Write rate per table |
| `n_dead_tup` | Dead tuples awaiting vacuum |
| `last_autovacuum` | Check vacuum is keeping up |

### Find tables needing indexes

```sql
SELECT schemaname, relname, seq_scan, idx_scan,
       seq_tup_read, n_live_tup
FROM pg_stat_user_tables
WHERE seq_scan > 100 AND n_live_tup > 10000
ORDER BY seq_tup_read DESC
LIMIT 15;
```

---

## Partitioning Strategies

### When to partition
- Tables exceeding 50–100 GB or 100M+ rows.
- Queries consistently filter on the partition key.
- Need fast bulk deletes (drop partition instead of DELETE).

### Range partitioning (most common)

```sql
CREATE TABLE events (
    id bigint GENERATED ALWAYS AS IDENTITY,
    created_at timestamptz NOT NULL,
    payload jsonb
) PARTITION BY RANGE (created_at);

CREATE TABLE events_2025_q1 PARTITION OF events
    FOR VALUES FROM ('2025-01-01') TO ('2025-04-01');
CREATE TABLE events_2025_q2 PARTITION OF events
    FOR VALUES FROM ('2025-04-01') TO ('2025-07-01');
```

### Hash partitioning
Distribute evenly when no natural range key exists:

```sql
CREATE TABLE sessions (id uuid, data jsonb)
    PARTITION BY HASH (id);
CREATE TABLE sessions_p0 PARTITION OF sessions FOR VALUES WITH (MODULUS 4, REMAINDER 0);
CREATE TABLE sessions_p1 PARTITION OF sessions FOR VALUES WITH (MODULUS 4, REMAINDER 1);
```

### Partition maintenance
- Automate creation of future partitions (cron or pg_partman).
- Detach and drop old partitions: `ALTER TABLE events DETACH PARTITION events_2023_q1;`
- Each partition inherits parent indexes but can have its own autovacuum settings.
- Always include the partition key in queries to enable partition pruning.

---

## Lock Contention Diagnosis

### View current locks

```sql
SELECT pid, locktype, relation::regclass, mode, granted, waitstart
FROM pg_locks
WHERE NOT granted
ORDER BY waitstart;
```

### Find blocking queries

```sql
SELECT blocked.pid AS blocked_pid,
       blocked_activity.query AS blocked_query,
       blocking.pid AS blocking_pid,
       blocking_activity.query AS blocking_query,
       blocked.locktype
FROM pg_locks blocked
JOIN pg_locks blocking
    ON blocking.locktype = blocked.locktype
   AND blocking.relation = blocked.relation
   AND blocking.pid != blocked.pid
   AND blocking.granted
JOIN pg_stat_activity blocked_activity ON blocked.pid = blocked_activity.pid
JOIN pg_stat_activity blocking_activity ON blocking.pid = blocking_activity.pid
WHERE NOT blocked.granted;
```

### Common lock contention causes and fixes
- **Long-running transactions** holding `RowExclusiveLock` — set `idle_in_transaction_session_timeout`.
- **ALTER TABLE on hot tables** — use `lock_timeout` and retry. Use `CREATE INDEX CONCURRENTLY` instead of `CREATE INDEX`.
- **VACUUM FULL** takes `AccessExclusiveLock` — prefer `pg_repack` for online de-bloating.
- **Heavy UPDATE contention on same rows** — consider `SELECT ... FOR UPDATE SKIP LOCKED` for queue patterns.
- **Advisory locks** leaking in connection-pooled setups — avoid advisory locks with PgBouncer transaction mode.

### Prevent lock escalation
```sql
SET lock_timeout = '5s';           -- fail fast instead of waiting
SET idle_in_transaction_session_timeout = '30s';
SET statement_timeout = '60s';     -- hard upper bound per query
```

## References

| File | When to read |
|------|-------------|
| `references/advanced-explain-analysis.md` | Deep EXPLAIN interpretation: JSON/YAML formats, auto_explain, node types (Memoize, Incremental Sort, etc.), JIT stats, parallel plans, CTE materialization |
| `references/troubleshooting.md` | Plan regressions, table/index bloat, XID wraparound, replication lag, OOM killer, checkpoint spikes, connection exhaustion |
| `references/monitoring-queries.md` | 25+ production SQL queries with thresholds for database, table, index, query, lock, replication, WAL, and autovacuum monitoring |

## Scripts

| Script | Usage |
|--------|-------|
| `scripts/pg-health-check.sh` | Comprehensive health report: cache ratio, connections, dead tuples, index usage, replication, TXID age |
| `scripts/find-missing-indexes.sh` | Identifies tables needing indexes and suggests CREATE INDEX statements |
| `scripts/explain-analyze-wrapper.sh <query>` | Safe EXPLAIN ANALYZE in rolled-back transaction; highlights slow nodes; supports `--json`, `--no-execute` |
| `scripts/vacuum-status.sh` | Vacuum health: dead tuples, stale autovacuum, running workers, wraparound risk |

## Assets

| File | Description |
|------|-------------|
| `assets/postgresql.conf.optimized` | Tuned config template for 16GB/4CPU/SSD baseline with scaling comments |
| `assets/pgbouncer.ini.template` | Production PgBouncer config with pool size formulas and TLS stubs |
| `assets/pg-partman-setup.sql` | pg_partman time-based partitioning setup with retention policy |
| `assets/performance-baseline.sql` | Captures snapshots for performance trend tracking and comparison |
| `assets/alerting-queries.sql` | 10 single-value queries for monitoring systems (Prometheus, Datadog) with thresholds |

<!-- tested: pass -->
