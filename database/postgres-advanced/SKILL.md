---
name: postgres-advanced
description: >
  Advanced PostgreSQL expertise for query optimization (EXPLAIN ANALYZE, B-tree/GIN/GiST/BRIN indexes),
  table partitioning (range, list, hash), CTEs and recursive queries, window functions, JSONB operations,
  full-text search (tsvector/tsquery), materialized views, advisory locks, connection pooling (PgBouncer),
  vacuum/autovacuum tuning, replication (streaming, logical), pg_stat_statements, row-level security,
  custom types/domains, triggers/rules, and extensions (pg_trgm, PostGIS, uuid-ossp). Use when user needs
  PostgreSQL optimization, advanced queries, indexing, partitioning, replication, full-text search, or JSONB.
  NOT for basic SQL CRUD operations. NOT for initial PostgreSQL installation or setup. NOT for other
  databases like MySQL, MongoDB, or SQLite.
---

# Advanced PostgreSQL

## Query Optimization

### EXPLAIN ANALYZE

Always diagnose slow queries with `EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)`. Read plans bottom-up.

```sql
-- Input: slow query on orders table
EXPLAIN (ANALYZE, BUFFERS, COSTS, TIMING)
SELECT o.id, c.name FROM orders o
JOIN customers c ON c.id = o.customer_id
WHERE o.created_at > '2024-01-01' AND o.status = 'active';

-- Output signals to watch:
-- Seq Scan → missing index. Add index on filter columns.
-- Nested Loop with high actual rows → consider hash join (increase work_mem).
-- Rows Removed by Filter: 50000 → index not selective enough.
-- Buffers: shared read=10000 → cold cache or table too large for shared_buffers.
```

Key rules:
- Compare `estimated rows` vs `actual rows`. Large gaps → run `ANALYZE tablename`.
- `Index Only Scan` is ideal. Requires covering index + recent VACUUM.
- Set `track_io_timing = on` for I/O wait visibility.

### Index Types

**B-tree** (default): equality, range, sorting. Use for PKs, FKs, timestamps, scalar WHERE.
```sql
CREATE INDEX idx_orders_created ON orders (created_at);
CREATE INDEX idx_orders_covering ON orders (customer_id) INCLUDE (status, total);
CREATE INDEX idx_orders_active ON orders (created_at) WHERE status = 'active';  -- partial
```

**GIN**: arrays, JSONB, full-text search. Operators: `@>`, `<@`, `&&`, `@@`.
```sql
CREATE INDEX idx_tags_gin ON articles USING gin (tags);
CREATE INDEX idx_data_gin ON events USING gin (payload jsonb_path_ops);
```

**GiST**: geometric, range, spatial (PostGIS), network types, ltree.
```sql
CREATE INDEX idx_location_gist ON stores USING gist (geom);
CREATE INDEX idx_period_gist ON reservations USING gist (during);
```

**BRIN**: very large append-only tables with correlated data. 1000x smaller than B-tree.
```sql
CREATE INDEX idx_logs_brin ON logs USING brin (created_at) WITH (pages_per_range = 32);
```

Index maintenance: drop unused (`SELECT * FROM pg_stat_user_indexes WHERE idx_scan = 0`), rebuild bloated (`REINDEX CONCURRENTLY INDEX idx_name`), limit to 5-7 per write-heavy table.

## Partitioning

### Range Partitioning — time-series, logs, events
```sql
CREATE TABLE events (
    id bigint GENERATED ALWAYS AS IDENTITY,
    created_at timestamptz NOT NULL, payload jsonb
) PARTITION BY RANGE (created_at);

CREATE TABLE events_2024_q1 PARTITION OF events FOR VALUES FROM ('2024-01-01') TO ('2024-04-01');
CREATE TABLE events_2024_q2 PARTITION OF events FOR VALUES FROM ('2024-04-01') TO ('2024-07-01');
ALTER TABLE events DETACH PARTITION events_2024_q1;  -- archival
```

### List Partitioning — categorical data (region, tenant)
```sql
CREATE TABLE orders (id bigint, region text NOT NULL, total numeric) PARTITION BY LIST (region);
CREATE TABLE orders_us PARTITION OF orders FOR VALUES IN ('us-east','us-west');
CREATE TABLE orders_eu PARTITION OF orders FOR VALUES IN ('eu-west','eu-central');
CREATE TABLE orders_default PARTITION OF orders DEFAULT;
```

### Hash Partitioning — even distribution, no natural key
```sql
CREATE TABLE sessions (id uuid PRIMARY KEY, user_id bigint, data jsonb) PARTITION BY HASH (id);
CREATE TABLE sessions_p0 PARTITION OF sessions FOR VALUES WITH (MODULUS 4, REMAINDER 0);
CREATE TABLE sessions_p1 PARTITION OF sessions FOR VALUES WITH (MODULUS 4, REMAINDER 1);
CREATE TABLE sessions_p2 PARTITION OF sessions FOR VALUES WITH (MODULUS 4, REMAINDER 2);
CREATE TABLE sessions_p3 PARTITION OF sessions FOR VALUES WITH (MODULUS 4, REMAINDER 3);
```

Partitioning rules: always filter on partition key (verify with `EXPLAIN`). Create indexes on parent to auto-propagate. Keep partition count < few hundred. Use pg_partman for lifecycle automation.

## CTEs and Recursive Queries

### Standard CTE
```sql
WITH monthly_revenue AS (
    SELECT date_trunc('month', created_at) AS month,
           SUM(total) AS revenue
    FROM orders WHERE status = 'completed'
    GROUP BY 1
)
SELECT month, revenue,
       revenue - LAG(revenue) OVER (ORDER BY month) AS mom_change
FROM monthly_revenue;
```

### Recursive CTE
Traverse hierarchies (org charts, categories, graphs).
```sql
WITH RECURSIVE org_tree AS (
    -- Base case: root nodes
    SELECT id, name, manager_id, 1 AS depth, ARRAY[id] AS path
    FROM employees WHERE manager_id IS NULL
    UNION ALL
    -- Recursive case
    SELECT e.id, e.name, e.manager_id, t.depth + 1, t.path || e.id
    FROM employees e JOIN org_tree t ON e.manager_id = t.id
    WHERE t.depth < 10  -- prevent infinite recursion
)
SELECT * FROM org_tree ORDER BY path;
-- Output: id=1, name='CEO', depth=1 | id=5, name='VP Eng', depth=2 | ...
```

CTE rules: PG12+ inlines non-recursive CTEs (use `MATERIALIZED` to force). Always add depth guard in recursive CTEs. Use `CYCLE` clause (PG14+) for graph traversal.

## Window Functions

```sql
-- Rank, running total, and moving average in one query
SELECT
    date,
    product_id,
    revenue,
    ROW_NUMBER() OVER w AS row_num,
    RANK() OVER w AS rank,
    SUM(revenue) OVER (PARTITION BY product_id ORDER BY date) AS running_total,
    AVG(revenue) OVER (
        PARTITION BY product_id ORDER BY date
        ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
    ) AS moving_avg_7d
FROM daily_sales
WINDOW w AS (PARTITION BY product_id ORDER BY revenue DESC);
```

```sql
-- Find gaps in sequences
SELECT id, next_id, next_id - id AS gap_size
FROM (
    SELECT id, LEAD(id) OVER (ORDER BY id) AS next_id FROM invoices
) sub WHERE next_id - id > 1;
```

Key functions: `ROW_NUMBER`, `RANK`, `DENSE_RANK`, `NTILE`, `LAG`, `LEAD`, `FIRST_VALUE`, `LAST_VALUE`, `NTH_VALUE`.
Frame clauses: `ROWS BETWEEN`, `RANGE BETWEEN`, `GROUPS BETWEEN`.

## JSONB Operations

```sql
-- Extract values
SELECT data->>'name' AS name,                    -- text extraction
       data->'address'->>'city' AS city,          -- nested extraction
       data#>>'{tags,0}' AS first_tag             -- path extraction
FROM users WHERE data @> '{"active": true}';      -- containment check

-- Update JSONB fields
UPDATE users SET data = jsonb_set(data, '{address,zip}', '"90210"')
WHERE id = 1;

-- Remove a key
UPDATE users SET data = data - 'temporary_field';

-- Aggregate into JSONB
SELECT jsonb_agg(jsonb_build_object('id', id, 'name', name)) FROM products;

-- Expand JSONB array
SELECT id, elem->>'name' AS tag_name
FROM articles, jsonb_array_elements(data->'tags') AS elem;
```

Indexing: `CREATE INDEX ON users USING gin (data)` for general, `gin (data jsonb_path_ops)` for `@>`, `((data->>'email'))` for specific keys. Always use `jsonb` not `json`. Extract hot fields into columns for heavy filtering.

## Full-Text Search

```sql
-- Setup: add tsvector column with trigger
ALTER TABLE articles ADD COLUMN search_vector tsvector
    GENERATED ALWAYS AS (
        setweight(to_tsvector('english', coalesce(title,'')), 'A') ||
        setweight(to_tsvector('english', coalesce(body,'')), 'B')
    ) STORED;

CREATE INDEX idx_fts ON articles USING gin (search_vector);

-- Search with ranking
SELECT id, title,
       ts_rank_cd(search_vector, query) AS rank
FROM articles, to_tsquery('english', 'postgres & optimization') AS query
WHERE search_vector @@ query
ORDER BY rank DESC LIMIT 20;

-- Highlight matches
SELECT ts_headline('english', body, to_tsquery('english', 'postgres & optimization'),
    'StartSel=<b>, StopSel=</b>, MaxFragments=3') AS snippet
FROM articles WHERE search_vector @@ to_tsquery('english', 'postgres & optimization');
```

FTS rules: use weighted vectors (`setweight` A-D) for relevance ranking. Use `websearch_to_tsquery` for user-facing search. Combine with `pg_trgm` for fuzzy matching. Create language-specific configs for non-English.

## Materialized Views

```sql
CREATE MATERIALIZED VIEW mv_sales_summary AS
SELECT product_id, date_trunc('day', sold_at) AS day,
       COUNT(*) AS units, SUM(price) AS revenue
FROM sales GROUP BY 1, 2
WITH DATA;

CREATE UNIQUE INDEX idx_mv_sales ON mv_sales_summary (product_id, day);

-- Non-blocking refresh (requires unique index)
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_sales_summary;
```

Rules: always create unique index to enable `CONCURRENTLY` refresh. Schedule via pg_cron — don't refresh on every request. Use for dashboards and aggregations, not real-time data.

## Advisory Locks

```sql
-- Session-level lock (must explicitly unlock)
SELECT pg_advisory_lock(hashtext('import_job_42'));
-- ... perform exclusive work ...
SELECT pg_advisory_unlock(hashtext('import_job_42'));

-- Transaction-level lock (auto-released at COMMIT/ROLLBACK)
SELECT pg_advisory_xact_lock(hashtext('process_queue'));

-- Try-lock (non-blocking, returns boolean)
SELECT pg_try_advisory_lock(12345) AS acquired;
-- Output: acquired=true (got lock) or acquired=false (someone else holds it)

-- Two-key lock for namespacing
SELECT pg_advisory_lock(1, 42);  -- namespace=1, resource=42
```

Rules: use for job coordination, leader election, rate limiting. Prefer transaction-level locks. Don't use with PgBouncer transaction mode.

## Connection Pooling (PgBouncer)

```ini
; pgbouncer.ini
[databases]
mydb = host=127.0.0.1 port=5432 dbname=mydb

[pgbouncer]
listen_port = 6432
pool_mode = transaction          ; recommended for stateless apps
max_client_conn = 1000
default_pool_size = 20           ; actual PG connections per pool
reserve_pool_size = 5
server_idle_timeout = 300
```

Rules: **transaction mode** is most efficient but breaks prepared statements, session vars, advisory locks, temp tables. **Session mode** is safe for all features. Size pools so `default_pool_size * num_dbs` ≤ `max_connections - superuser_reserved`. Set `server_reset_query = DISCARD ALL`.

## Vacuum and Autovacuum Tuning

```sql
-- Check bloat and dead tuples
SELECT schemaname, relname, n_dead_tup, n_live_tup,
       round(n_dead_tup::numeric / GREATEST(n_live_tup, 1) * 100, 2) AS dead_pct,
       last_autovacuum, last_autoanalyze
FROM pg_stat_user_tables
WHERE n_dead_tup > 10000
ORDER BY n_dead_tup DESC;
```

Per-table tuning for hot tables:
```sql
ALTER TABLE orders SET (
    autovacuum_vacuum_scale_factor = 0.01,      -- trigger at 1% dead rows (default 20%)
    autovacuum_vacuum_cost_delay = 2,            -- faster vacuum (default 2ms)
    autovacuum_analyze_scale_factor = 0.005
);
```

Global settings (postgresql.conf):
```
autovacuum_max_workers = 6               # default 3, increase for many tables
autovacuum_vacuum_cost_limit = 800       # default 200, increase for fast I/O
maintenance_work_mem = 1GB               # speed up vacuum on large tables
```

Rules: never disable autovacuum. Watch XID wraparound: `SELECT datname, age(datfrozenxid) FROM pg_database;` — alert if age > 500M. Avoid `VACUUM FULL` (exclusive lock) — use `pg_repack` for online defrag.

## Replication

### Streaming Replication (Physical)
```
-- postgresql.conf (primary)
wal_level = replica
max_wal_senders = 10
wal_keep_size = 1GB

-- pg_hba.conf (primary)
host replication replicator standby_ip/32 scram-sha-256

-- On standby:
pg_basebackup -h primary_ip -D /var/lib/postgresql/data -U replicator -Fp -Xs -P -R
```

### Logical Replication
Selective table replication across PG versions.
```sql
-- On publisher:
CREATE PUBLICATION my_pub FOR TABLE orders, customers;

-- On subscriber:
CREATE SUBSCRIPTION my_sub
    CONNECTION 'host=publisher_ip dbname=mydb user=replicator'
    PUBLICATION my_pub;

-- Monitor lag:
SELECT slot_name, confirmed_flush_lsn, pg_current_wal_lsn(),
       pg_current_wal_lsn() - confirmed_flush_lsn AS lag_bytes
FROM pg_replication_slots;
```

Rules: streaming = full cluster HA, use Patroni/repmgr for failover. Logical = per-table, cross-version, no DDL replication. Monitor lag, alert if slots inactive. Set `wal_level = logical` (superset of `replica`).

## pg_stat_statements

```sql
-- Enable (requires restart once)
-- postgresql.conf: shared_preload_libraries = 'pg_stat_statements'
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- Top 10 slowest queries by total time
SELECT query, calls, total_exec_time::numeric(12,2) AS total_ms,
       mean_exec_time::numeric(12,2) AS mean_ms,
       rows, shared_blks_hit, shared_blks_read
FROM pg_stat_statements
ORDER BY total_exec_time DESC LIMIT 10;

-- Reset statistics periodically
SELECT pg_stat_statements_reset();
```

Rules: set `pg_stat_statements.track = all` for nested statements. Focus on high `total_exec_time`. Compare `shared_blks_hit` vs `shared_blks_read` for cache effectiveness.

## Row-Level Security (RLS)

```sql
-- Multi-tenant isolation
ALTER TABLE documents ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON documents
    USING (tenant_id = current_setting('app.tenant_id')::int);

CREATE POLICY tenant_insert ON documents
    FOR INSERT WITH CHECK (tenant_id = current_setting('app.tenant_id')::int);

-- Set tenant context per request
SET app.tenant_id = '42';
SELECT * FROM documents;  -- only sees tenant_id=42 rows

-- Force RLS on table owner too
ALTER TABLE documents FORCE ROW LEVEL SECURITY;
```

Rules: use `FORCE ROW LEVEL SECURITY` unless owner should bypass. Set context via `set_config('app.tenant_id', $1, true)` for transaction-local scope. Test with `SET ROLE`. Combine `FOR SELECT/INSERT/UPDATE/DELETE` for granular control.

## Custom Types and Domains

```sql
-- Domain: reusable constrained type
CREATE DOMAIN email AS text CHECK (VALUE ~* '^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$');
CREATE DOMAIN positive_int AS integer CHECK (VALUE > 0);

-- Enum type
CREATE TYPE order_status AS ENUM ('pending','processing','shipped','delivered','cancelled');
-- Add value: ALTER TYPE order_status ADD VALUE 'refunded' AFTER 'delivered';

-- Composite type
CREATE TYPE address AS (street text, city text, state text, zip text);
CREATE TABLE customers (id serial PRIMARY KEY, name text, home address);
-- Query: SELECT (home).city FROM customers;
```

Rules: prefer domains over scattered CHECK constraints. Enums are storage-efficient but hard to remove values — use for stable sets. Use composite types sparingly.

## Triggers

```sql
-- Audit trigger: log all changes
CREATE OR REPLACE FUNCTION audit_trigger_fn() RETURNS trigger AS $$
BEGIN
    INSERT INTO audit_log (table_name, operation, old_data, new_data, changed_at)
    VALUES (TG_TABLE_NAME, TG_OP,
            CASE WHEN TG_OP IN ('UPDATE','DELETE') THEN to_jsonb(OLD) END,
            CASE WHEN TG_OP IN ('INSERT','UPDATE') THEN to_jsonb(NEW) END,
            now());
    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER audit_orders
    AFTER INSERT OR UPDATE OR DELETE ON orders
    FOR EACH ROW EXECUTE FUNCTION audit_trigger_fn();

-- updated_at auto-timestamp
CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_updated_at BEFORE UPDATE ON orders
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
```

Rules: keep trigger functions fast (they run inside the transaction). Use `AFTER` for audit, `BEFORE` for modification. Avoid cascading triggers — use `pg_trigger_depth()` to guard. Prefer triggers over rules.

## Extensions

### pg_trgm — Fuzzy Text Search
```sql
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE INDEX idx_name_trgm ON customers USING gin (name gin_trgm_ops);

-- Similarity search (typo-tolerant)
SELECT name, similarity(name, 'Jonh Smith') AS sim
FROM customers WHERE name % 'Jonh Smith' ORDER BY sim DESC LIMIT 5;
-- Output: name='John Smith', sim=0.72

-- Set threshold: SELECT set_limit(0.3);
```

### PostGIS — Geospatial
```sql
CREATE EXTENSION IF NOT EXISTS postgis;
ALTER TABLE stores ADD COLUMN geom geometry(Point, 4326);
CREATE INDEX idx_stores_geom ON stores USING gist (geom);

-- Find stores within 5km
SELECT name, ST_Distance(geom::geography, ST_MakePoint(-73.99, 40.73)::geography) AS dist_m
FROM stores
WHERE ST_DWithin(geom::geography, ST_MakePoint(-73.99, 40.73)::geography, 5000)
ORDER BY dist_m;
```

### uuid-ossp — UUID Generation
```sql
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
-- v4 (random): SELECT uuid_generate_v4();
-- PG13+ alternative (no extension needed): SELECT gen_random_uuid();

CREATE TABLE items (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    name text NOT NULL
);
```

### Other Useful Extensions
- **pg_cron**: schedule jobs (vacuum, refresh mat views) inside PostgreSQL.
- **pgcrypto**: encryption, hashing (`crypt`, `gen_salt`, `pgp_sym_encrypt`).
- **pg_repack**: online table/index reorganization without exclusive locks.
- **hstore**: lightweight key-value store (prefer JSONB for new projects).
- **citext**: case-insensitive text type for email/username columns.

Install pattern: `CREATE EXTENSION IF NOT EXISTS extension_name;`
Check available: `SELECT * FROM pg_available_extensions WHERE name LIKE 'pg_%';`

## References

- **[references/advanced-patterns.md](references/advanced-patterns.md)** — LATERAL joins, GROUPING SETS/CUBE/ROLLUP, recursive CTEs for graph traversal, generate_series tricks, partial/expression/covering indexes, index-only scans, partition pruning, attach/detach, sub-partitioning, pg_partman.
- **[references/troubleshooting.md](references/troubleshooting.md)** — Slow query diagnosis (pg_stat_statements, auto_explain), bloat detection (pgstattuple, pg_repack), lock contention (pg_locks, dependency trees), connection exhaustion, OOM debugging, WAL growth, vacuum/XID wraparound, replication lag.
- **[references/performance-tuning.md](references/performance-tuning.md)** — Memory sizing (shared_buffers, work_mem, effective_cache_size) with reference table by server RAM, PgBouncer setup, autovacuum tuning, checkpoint tuning, planner settings, WAL config, OS tuning (huge pages, vm.overcommit, I/O, network).

## Scripts

- **[scripts/pg-health-check.sh](scripts/pg-health-check.sh)** — Database sizes, table bloat, index usage, cache hit ratio, long-running queries, replication status, XID wraparound, checkpoint stats. Usage: `./pg-health-check.sh [-h HOST] [-p PORT] [-d DB] [-U USER]`
- **[scripts/pg-index-advisor.py](scripts/pg-index-advisor.py)** — Identifies high seq-scan tables, unused/duplicate indexes, suggests missing indexes. Requires psycopg2. Usage: `./pg-index-advisor.py [-H HOST] [-d DB] [--seq-threshold PCT]`
- **[scripts/pg-slow-query-report.sh](scripts/pg-slow-query-report.sh)** — Report from pg_stat_statements: top queries by time, cache ratio, temp I/O, row volume, with recommendations. Usage: `./pg-slow-query-report.sh [-h HOST] [-d DB] [-n TOP_N]`

## Assets

- **[assets/postgresql-tuning.conf](assets/postgresql-tuning.conf)** — Optimized postgresql.conf template for Small/Medium/Large servers with commented rationale for every parameter.
- **[assets/pgbouncer.ini](assets/pgbouncer.ini)** — PgBouncer template with transaction pooling, pool sizing formulas, auth, TLS, and admin console.
- **[assets/monitoring-queries.sql](assets/monitoring-queries.sql)** — 10-section diagnostic SQL: cache ratio, bloat, locks, replication, sizes, sessions, vacuum, checkpoints, WAL, config.
- **[assets/partitioning-template.sql](assets/partitioning-template.sql)** — Range/list/hash/sub-partitioning templates with auto-creation functions, monitoring, and pg_cron scheduling.
<!-- tested: pass -->
