---
name: clickhouse-analytics
description: >
  Guide for building analytics systems with ClickHouse, the open-source columnar OLAP database
  for real-time analytics at petabyte scale. Use this skill WHEN: writing ClickHouse SQL (CREATE TABLE,
  INSERT, SELECT with aggregations), designing schemas for event/log/time-series analytics, choosing
  MergeTree table engines, building data ingestion pipelines (Kafka, S3, batch inserts, async inserts),
  creating materialized views or projections, setting up distributed clusters, optimizing columnar
  query performance, or comparing ClickHouse vs BigQuery/Snowflake/Druid/TimescaleDB for OLAP
  workloads. Keywords: ClickHouse, OLAP, analytics, columnar, real-time analytics, time series,
  MergeTree, clickhouse-client, clickhouse-server. Do NOT trigger for: OLTP/transactional workloads,
  PostgreSQL/MySQL row-store design, general SQL tutorials unrelated to analytics, or Redis/MongoDB usage.
---

# ClickHouse Analytics

## What ClickHouse Is

ClickHouse is an open-source, column-oriented OLAP database (current release line: v25.x). It processes analytical queries over billions of rows in sub-second time. Use it for event analytics, log analysis, time-series data, real-time dashboards, and ad-hoc analytical queries. Do NOT use it for OLTP, frequent single-row updates, or transactional workloads with ACID guarantees.

## Table Engines

Always use a MergeTree-family engine. Choose by write semantics:

| Engine | Use Case |
|---|---|
| `MergeTree` | Default. Append-only analytical workloads. |
| `ReplacingMergeTree(version)` | Deduplication by ORDER BY key. Keep latest version of a row. |
| `SummingMergeTree((col1, col2))` | Auto-sum numeric columns on merge. Running counters/totals. |
| `AggregatingMergeTree` | Store pre-aggregated states (use with `AggregateFunction` types). |
| `CollapsingMergeTree(sign)` | Logical deletes/updates via sign column (+1/-1 pairs). |
| `VersionedCollapsingMergeTree(sign, ver)` | CollapsingMergeTree with out-of-order insert support. |

Prefix with `Replicated` for HA: `ReplicatedMergeTree('/clickhouse/tables/{shard}/events', '{replica}')`.

```sql
CREATE TABLE events (
    event_date Date,
    event_time DateTime,
    user_id UInt64,
    event_type LowCardinality(String),
    properties String
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_type, user_id, event_time)
SETTINGS index_granularity = 8192;
```

## Schema Design for Columnar Storage

### Type Selection
- Use fixed-width types: `UInt8/16/32/64`, `Int8/16/32/64`, `Float32/64`, `Date`, `DateTime`, `DateTime64`.
- Use `LowCardinality(String)` for columns with < ~10,000 distinct values (status, country, browser). Gives dictionary encoding automatically.
- Use `Enum8`/`Enum16` only when the value set is truly fixed and known at schema time.
- Avoid `Nullable` — it adds a separate bitmask column, increases memory, and breaks some optimizations. Use sentinel values instead (`0`, `''`, `'1970-01-01'`).
- Use `String` only for truly variable-length data. Never store numbers or dates as strings.
- Use `UUID` type for UUIDs, not String.

### Denormalization
Denormalize aggressively. ClickHouse has no foreign keys. JOINs are expensive — flatten data at write time. Store dimension attributes directly in fact tables. Use dictionaries for lookup enrichment instead of JOINs.

```sql
-- GOOD: denormalized
CREATE TABLE page_views (
    ts DateTime,
    user_id UInt64,
    user_country LowCardinality(String),  -- denormalized from users
    url String,
    duration_ms UInt32
) ENGINE = MergeTree() ORDER BY (user_country, ts);

-- BAD: normalized with JOIN at query time
SELECT pv.*, u.country FROM page_views pv JOIN users u ON pv.user_id = u.user_id;
```

## Primary Key and Ordering Key

The `ORDER BY` clause defines both physical sort order and the sparse primary index. The `PRIMARY KEY` can be a prefix of `ORDER BY` (defaults to the full `ORDER BY`).

### Design Rules
1. Place low-cardinality, frequently-filtered columns first (e.g., `tenant_id`, `event_type`).
2. Place time columns next for range scans.
3. Place high-cardinality columns last (e.g., `user_id`, `session_id`).
4. Never put columns you rarely filter on into the ordering key.
5. The ordering key determines compression — similar adjacent values compress better.

```sql
-- Good ordering for multi-tenant analytics
ORDER BY (tenant_id, event_type, toStartOfHour(event_time), user_id)

-- Primary key as prefix (only first 3 columns in sparse index)
PRIMARY KEY (tenant_id, event_type, toStartOfHour(event_time))
ORDER BY (tenant_id, event_type, toStartOfHour(event_time), user_id)
```

Use data skipping indexes for columns not in the ordering key:

```sql
ALTER TABLE events ADD INDEX idx_url url TYPE bloom_filter(0.01) GRANULARITY 4;
ALTER TABLE events ADD INDEX idx_status status TYPE set(100) GRANULARITY 4;
ALTER TABLE events ADD INDEX idx_error error_msg TYPE ngrambf_v1(3, 256, 2, 0) GRANULARITY 4;
```

## Partitioning

Partition by time for most analytics workloads. Keep total partition count between 100–1,000 per table.

```sql
PARTITION BY toYYYYMM(event_date)     -- monthly: good default for most tables
PARTITION BY toYYYYMMDD(event_date)   -- daily: only for very high-volume tables (>1B rows/day)
PARTITION BY (toYYYYMM(event_date), region)  -- compound: only if you DROP by region
```

**Rules:**
- Partition key must be low cardinality. Never partition by user_id or session_id.
- Each partition should have at least millions of rows.
- Partitioning enables efficient `ALTER TABLE DROP PARTITION` for data lifecycle.
- Partitioning does NOT replace the ordering key for query filtering. Queries still need the ordering key for optimal performance.

## Materialized Views

Materialized views execute on INSERT, transforming and routing data to a target table. Use them for pre-aggregation, denormalization, and routing.

```sql
-- Source table
CREATE TABLE raw_events (
    ts DateTime,
    user_id UInt64,
    event LowCardinality(String),
    value Float64
) ENGINE = MergeTree() ORDER BY (event, ts);

-- Aggregated target
CREATE TABLE hourly_stats (
    hour DateTime,
    event LowCardinality(String),
    cnt AggregateFunction(count, UInt64),
    sum_val AggregateFunction(sum, Float64)
) ENGINE = AggregatingMergeTree() ORDER BY (event, hour);

-- Materialized view
CREATE MATERIALIZED VIEW hourly_stats_mv TO hourly_stats AS
SELECT
    toStartOfHour(ts) AS hour,
    event,
    countState() AS cnt,
    sumState(value) AS sum_val
FROM raw_events
GROUP BY hour, event;

-- Query the aggregate (use -Merge combinators)
SELECT hour, event, countMerge(cnt) AS total, sumMerge(sum_val) AS total_val
FROM hourly_stats
GROUP BY hour, event;
```

## Projections

Projections store alternative sort orders or pre-aggregations inside the same table. The optimizer picks them automatically.

```sql
ALTER TABLE events ADD PROJECTION proj_by_user (
    SELECT * ORDER BY (user_id, event_time)
);
ALTER TABLE events MATERIALIZE PROJECTION proj_by_user;

-- Pre-aggregation projection
ALTER TABLE events ADD PROJECTION proj_hourly (
    SELECT toStartOfHour(event_time) AS hour, event_type, count() AS cnt
    GROUP BY hour, event_type
);
ALTER TABLE events MATERIALIZE PROJECTION proj_hourly;
```

**Rules:**
- Each projection increases write amplification and storage. Add only for proven query patterns.
- Projections are not used with `FINAL`.
- Verify usage with `EXPLAIN` — ClickHouse silently falls back if the projection is incomplete.

## Query Optimization

### PREWHERE
`PREWHERE` reads filter columns first, then loads remaining columns only for matching rows. ClickHouse auto-promotes selective WHERE conditions, but use explicitly for control:

```sql
SELECT user_id, properties
FROM events
PREWHERE event_type = 'purchase'   -- small column, high selectivity
WHERE ts >= '2025-01-01';
```

### Approximate Functions
Use approximate functions for dashboards where exactness is unnecessary:

```sql
SELECT uniqHLL12(user_id) AS approx_users FROM events;       -- ~2% error, fast
SELECT quantileTDigest(0.99)(duration_ms) FROM requests;       -- approximate percentile
SELECT uniqCombined(user_id) FROM events;                      -- adaptive precision
```

### Sampling
Define a sampling key for fast approximate queries on large tables:

```sql
CREATE TABLE events_sampled (...)
ENGINE = MergeTree() ORDER BY (event_type, intHash32(user_id))
SAMPLE BY intHash32(user_id);

SELECT count() * 10 AS estimated_total FROM events_sampled SAMPLE 1/10;
```

### General Query Tips
- Avoid `SELECT *` — specify only needed columns. Columnar storage reads only requested columns.
- Push filters into subqueries and CTEs; prefer `WHERE` over `HAVING`.
- Use `LIMIT` early in exploratory queries.
- Avoid `ORDER BY` on large result sets unless essential.
- Use `IN` subqueries over `JOIN` when filtering by a set of IDs.
- Prefer `argMax(value, version)` over self-joins for latest-value queries.

## Data Ingestion Patterns

### Batch Inserts (Preferred)
Insert in batches of 10,000–1,000,000 rows. Each INSERT creates a data part; too many small inserts overwhelm merges.

```sql
INSERT INTO events FORMAT JSONEachRow
{"ts":"2025-01-15 10:00:00","user_id":42,"event":"click","value":1.5}
{"ts":"2025-01-15 10:00:01","user_id":43,"event":"view","value":0.0}
```

### Async Inserts
Enable server-side batching when clients cannot batch themselves (IoT, telemetry, many small producers):

```sql
SET async_insert = 1;
SET wait_for_async_insert = 1;   -- 1 = wait for flush (durable), 0 = fire-and-forget
SET async_insert_max_data_size = 10485760;  -- flush at 10MB
SET async_insert_busy_timeout_ms = 5000;    -- flush every 5s
```

### Kafka Engine
Three-table pattern for streaming ingestion:

```sql
CREATE TABLE events_kafka (
    ts DateTime, user_id UInt64, event String
) ENGINE = Kafka
SETTINGS kafka_broker_list = 'broker:9092',
         kafka_topic_list = 'events',
         kafka_group_name = 'ch_consumer',
         kafka_format = 'JSONEachRow',
         kafka_num_consumers = 4;

CREATE TABLE events (...) ENGINE = MergeTree() ORDER BY (event, ts);

CREATE MATERIALIZED VIEW events_kafka_mv TO events AS
SELECT * FROM events_kafka;
```

### S3 Integration
Read and write directly from S3-compatible storage:

```sql
-- Query S3 data directly
SELECT * FROM s3('https://bucket.s3.amazonaws.com/data/*.parquet', 'Parquet');

-- Insert from S3
INSERT INTO events SELECT * FROM s3('s3://bucket/events/*.csv', 'CSVWithNames');

-- S3-backed MergeTree (ClickHouse Cloud / tiered storage)
CREATE TABLE events_s3 (...) ENGINE = MergeTree() ORDER BY (ts)
SETTINGS storage_policy = 's3_tiered';
```

## Distributed Tables and Cluster Setup

```sql
-- Define cluster in config.xml, then create local + distributed tables
CREATE TABLE events_local ON CLUSTER '{cluster}' (
    ts DateTime, user_id UInt64, event LowCardinality(String)
) ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/events', '{replica}')
ORDER BY (event, ts);

CREATE TABLE events_dist ON CLUSTER '{cluster}' AS events_local
ENGINE = Distributed('{cluster}', default, events_local, rand());
```

**Rules:**
- Write to local tables or use the Distributed table with `insert_distributed_sync = 1` for backpressure.
- Use `rand()` for even sharding; use a column hash for co-located sharding (e.g., `cityHash64(user_id)`).
- Set `distributed_product_mode = 'global'` for distributed JOINs.

## TTL and Data Lifecycle

```sql
CREATE TABLE logs (
    ts DateTime,
    level LowCardinality(String),
    message String
) ENGINE = MergeTree() ORDER BY (level, ts)
TTL ts + INTERVAL 90 DAY DELETE,
    ts + INTERVAL 30 DAY TO VOLUME 'cold_storage';

-- Column-level TTL: drop heavy columns early
ALTER TABLE logs MODIFY COLUMN message String TTL ts + INTERVAL 30 DAY;

-- Manual partition management
ALTER TABLE logs DROP PARTITION '202401';
```

## Dictionaries

Use dictionaries for low-latency key-value lookups instead of JOINs:

```sql
CREATE DICTIONARY geo_dict (
    city_id UInt32,
    city_name String,
    country LowCardinality(String)
) PRIMARY KEY city_id
SOURCE(CLICKHOUSE(TABLE 'geo_cities'))
LAYOUT(HASHED())
LIFETIME(MIN 300 MAX 600);

-- Use in queries
SELECT dictGet('geo_dict', 'country', city_id) AS country FROM events;
```

Dictionary layouts: `FLAT` (fastest, small datasets), `HASHED` (general), `RANGE_HASHED` (temporal lookups), `CACHE` (large datasets, lazy loading), `IP_TRIE` (IP-to-geo).

## User-Defined Functions

```sql
-- SQL UDFs
CREATE FUNCTION toBusinessDay AS (d) ->
    if(toDayOfWeek(d) IN (6, 7), toMonday(d + INTERVAL 7 DAY), d);

-- Executable UDFs for complex logic
CREATE FUNCTION my_scorer AS (x, y) -> x * 0.7 + y * 0.3;
```

## Monitoring and System Tables

```sql
-- Currently running queries
SELECT query_id, elapsed, read_rows, memory_usage, query
FROM system.processes ORDER BY elapsed DESC;

-- Recent query performance
SELECT query, query_duration_ms, read_rows, result_rows, memory_usage
FROM system.query_log
WHERE type = 'QueryFinish' AND event_date = today()
ORDER BY query_duration_ms DESC LIMIT 20;

-- Table sizes and part counts
SELECT table, sum(rows) AS total_rows, sum(bytes_on_disk) AS bytes,
       count() AS part_count
FROM system.parts WHERE active GROUP BY table ORDER BY bytes DESC;

-- Merge activity
SELECT table, elapsed, progress, num_parts, result_part_name
FROM system.merges;

-- Replication status
SELECT database, table, is_leader, total_replicas, active_replicas,
       log_pointer, queue_size
FROM system.replicas;
```

Key system tables: `system.query_log`, `system.parts`, `system.merges`, `system.replicas`, `system.mutations`, `system.metrics`, `system.events`, `system.asynchronous_metrics`, `system.dictionaries`.

## ClickHouse vs Alternatives

| Feature | ClickHouse | BigQuery | Snowflake | Druid | TimescaleDB |
|---|---|---|---|---|---|
| Deployment | Self-hosted / Cloud | Managed | Managed | Self-hosted / Cloud | Self-hosted / Cloud |
| Query Latency | Sub-second | Seconds | Seconds | Sub-second | Milliseconds–seconds |
| Ingestion | Real-time (millions/s) | Streaming + batch | Micro-batch | Real-time | Real-time |
| Cost Model | Compute-based | Per-query scan | Credits | Compute-based | Storage-based |
| Best For | High-volume analytics, logs | Ad-hoc warehouse queries | Multi-workload warehouse | Real-time OLAP dashboards | Time-series on PostgreSQL |
| JOINs | Limited (no FK, hash joins) | Full SQL | Full SQL | Very limited | Full SQL |
| Updates/Deletes | Async mutations, eventual | Full DML | Full DML | Limited | Full DML |

Choose ClickHouse when: sub-second queries on billions of rows, high ingestion rates, self-hosted control, cost-sensitive analytics. Avoid when: complex transactions, frequent updates, small datasets (<1M rows), or need full ANSI SQL JOIN semantics.

## Common Anti-Patterns

1. **Too many small inserts** — Each INSERT creates a part. Batch to 10K+ rows or use async inserts. Never INSERT row-by-row.
2. **Wrong MergeTree variant** — Using MergeTree when you need dedup (use ReplacingMergeTree). Using CollapsingMergeTree without understanding sign semantics.
3. **Over-normalization** — JOINing dimension tables at query time. Denormalize at write time or use dictionaries.
4. **Nullable overuse** — Adds overhead. Use default values instead.
5. **High-cardinality partition keys** — Partitioning by `user_id` creates millions of partitions. Partition by time.
6. **SELECT * in production** — Reads every column from disk. Always specify columns.
7. **Missing ORDER BY design** — Not aligning ORDER BY with query patterns. Requires table rebuild to fix.
8. **Too many projections/MVs** — Each increases write amplification. Add incrementally.
9. **Using ClickHouse for OLTP** — Single-row lookups, frequent updates, transactions. Use PostgreSQL/MySQL.
10. **Ignoring FINAL** — `ReplacingMergeTree` does not deduplicate at query time unless you use `SELECT ... FINAL` or `OPTIMIZE TABLE ... FINAL`.

## Performance Tuning Settings

```sql
-- Memory and parallelism
SET max_memory_usage = 20000000000;           -- 20GB per query
SET max_threads = 16;                          -- parallel query threads
SET max_block_size = 65536;                    -- rows per processing block

-- Insert performance
SET max_insert_block_size = 1048576;           -- rows per insert block
SET min_insert_block_size_rows = 1048576;
SET max_partitions_per_insert_block = 100;

-- Merge tuning
SET background_pool_size = 16;
SET parts_to_throw_insert = 300;               -- error if too many parts

-- Query optimization
SET optimize_read_in_order = 1;                -- skip sort if ORDER BY matches
SET optimize_aggregation_in_order = 1;         -- streaming aggregation
SET compile_expressions = 1;                   -- JIT compilation
SET use_uncompressed_cache = 1;                -- cache uncompressed blocks
SET merge_tree_min_rows_for_concurrent_read = 20000;

-- Distributed query settings
SET distributed_product_mode = 'global';
SET max_distributed_connections = 1024;
SET distributed_aggregation_memory_efficient = 1;

-- Join settings
SET join_algorithm = 'auto';                   -- auto-pick hash/merge/partial
SET max_rows_in_join = 100000000;
```

## Resources

### references/ — Deep-Dive Documentation

| File | Description |
|---|---|
| `references/advanced-patterns.md` | Window functions, array/map operations, WITH FILL for time-series gaps, JSON extraction, approximate algorithms, parameterized views, external dictionaries from multiple sources, integration engines (PostgreSQL, MySQL, S3, Kafka), ClickHouse Keeper setup, and query profiling with system.query_log. |
| `references/troubleshooting.md` | Diagnosing and fixing: slow queries, too many parts, merge bottlenecks, memory limit exceeded, distributed query failures, replication lag, ZooKeeper/Keeper issues, corrupted parts recovery, stuck mutations, and readonly mode. Includes system tables reference. |
| `references/migration-guide.md` | Migrating to ClickHouse from PostgreSQL, MySQL, Elasticsearch, and BigQuery. Covers data type mapping, schema translation, query syntax differences, transfer tools (clickhouse-local, clickhouse-copier, dbt-clickhouse), and ETL pipeline setup. |

### scripts/ — Executable Helpers

| File | Description |
|---|---|
| `scripts/ch-health-check.sh` | Checks server status, replication health, merge activity, disk usage, running queries, parts count, and pending mutations. Supports `--host`, `--port`, `--user`, `--password`, `--secure` flags. |
| `scripts/ch-slow-query-report.sh` | Queries system.query_log for slow queries and formats a report with top queries by duration/memory/data scanned, frequent patterns, and hourly distribution. Use `--threshold MS` to set the slow query cutoff. |
| `scripts/ch-table-stats.sh` | Shows table statistics: row count, disk size, part count, column compression ratios, partition details, and potential issues. Use `--database` and `--table` to drill into a specific table. |

### assets/ — Templates and Boilerplate

| File | Description |
|---|---|
| `assets/analytics-schema.sql` | Complete analytics schema: raw events table (MergeTree), daily aggregation (AggregatingMergeTree), materialized view for auto-aggregation, projection for alternative sort order, and funnel table (SummingMergeTree). Includes TTL and data skipping indexes. |
| `assets/clickhouse-server-config.xml` | Production server config with memory limits, merge settings, compression (LZ4/ZSTD), storage policies (hot/cold tiering), query logging with TTL, and distributed DDL settings. |
| `assets/clickhouse-users.xml` | User configuration with 4 profiles (default, readonly, ingestion, analyst), quotas with rate limits, and row-level security examples via SQL row policies. |
| `assets/grafana-dashboard.json` | Grafana dashboard JSON for ClickHouse monitoring: queries/sec, query latency percentiles, memory usage, active merges, parts count, merge throughput, replication lag, and disk usage gauges. |
| `assets/docker-compose.yml` | Docker Compose for local development: 2 shards × 2 replicas (4 ClickHouse nodes) + 3-node ClickHouse Keeper cluster, with inline XML configs for cluster topology and macros. |
