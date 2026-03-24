# CockroachDB Troubleshooting Guide

## Table of Contents

- [Transaction Retry Errors (40001)](#transaction-retry-errors-40001)
  - [Understanding Retry Errors](#understanding-retry-errors)
  - [Common Causes](#common-causes)
  - [Diagnosing Retries](#diagnosing-retries)
  - [Reducing Retry Frequency](#reducing-retry-frequency)
- [Contention Analysis](#contention-analysis)
  - [Identifying Contention](#identifying-contention)
  - [Lock Wait Queues](#lock-wait-queues)
  - [Resolving Contention](#resolving-contention)
- [Hot Ranges](#hot-ranges)
  - [Detecting Hotspots](#detecting-hotspots)
  - [Sequential Key Hotspots](#sequential-key-hotspots)
  - [Mitigating Hotspots](#mitigating-hotspots)
- [Leaseholder Rebalancing](#leaseholder-rebalancing)
  - [Checking Leaseholder Distribution](#checking-leaseholder-distribution)
  - [Manual Rebalancing](#manual-rebalancing)
  - [Rebalancing Settings](#rebalancing-settings)
- [Clock Skew and max-offset](#clock-skew-and-max-offset)
  - [How CockroachDB Uses Clocks](#how-cockroachdb-uses-clocks)
  - [Detecting Clock Skew](#detecting-clock-skew)
  - [Resolving Clock Issues](#resolving-clock-issues)
- [Node Decommissioning Stuck](#node-decommissioning-stuck)
  - [Decommission Process](#decommission-process)
  - [Diagnosing Stuck Decommission](#diagnosing-stuck-decommission)
  - [Forcing Decommission](#forcing-decommission)
- [Changefeed Lag](#changefeed-lag)
  - [Monitoring Changefeed Progress](#monitoring-changefeed-progress)
  - [Common Lag Causes](#common-lag-causes)
  - [Resolving Lag Issues](#resolving-lag-issues)
- [OOM on Large Imports](#oom-on-large-imports)
  - [Memory Pressure During Import](#memory-pressure-during-import)
  - [Preventing OOM](#preventing-oom)
  - [Alternative Import Strategies](#alternative-import-strategies)
- [Slow Schema Changes](#slow-schema-changes)
  - [Schema Change Mechanics](#schema-change-mechanics)
  - [Diagnosing Slow DDL](#diagnosing-slow-ddl)
  - [Schema Change Best Practices](#schema-change-best-practices)
- [Range Splits and Merges](#range-splits-and-merges)
  - [Understanding Range Lifecycle](#understanding-range-lifecycle)
  - [Diagnosing Range Issues](#diagnosing-range-issues)
  - [Tuning Range Behavior](#tuning-range-behavior)
- [Admission Control](#admission-control)
  - [How Admission Control Works](#how-admission-control-works)
  - [Diagnosing Throttling](#diagnosing-throttling)
  - [Tuning Admission Control](#tuning-admission-control)
- [General Diagnostic Toolkit](#general-diagnostic-toolkit)

---

## Transaction Retry Errors (40001)

### Understanding Retry Errors

CockroachDB uses **serializable** isolation. When two transactions conflict,
one receives a `40001` (serialization failure) error and must retry. This is
not a bug — it's the expected mechanism for maintaining correctness.

Error message pattern:
```
ERROR: restart transaction: TransactionRetryWithProtoRefreshError:
  WriteTooOldError: ... (SQLSTATE 40001)
```

### Common Causes

1. **Write-write conflicts**: Two transactions update the same row
2. **Read-write conflicts**: Transaction A reads a row that Transaction B
   subsequently modifies before A commits
3. **Write skew**: Transactions read overlapping data and write to different
   rows, creating a cycle
4. **Long-running transactions**: Hold read timestamps for extended periods,
   increasing conflict windows
5. **Timestamp pushing**: CockroachDB's MVCC pushes timestamps forward, which
   can cascade into retries

### Diagnosing Retries

```sql
-- Check transaction retry rate
SELECT
    name,
    count
FROM crdb_internal.node_metrics
WHERE name LIKE '%txn.restart%' OR name LIKE '%txn.abort%'
ORDER BY name;

-- Find statements with high retry counts
SELECT
    metadata ->> 'query' AS query,
    statistics -> 'statistics' -> 'cnt' AS exec_count,
    statistics -> 'statistics' -> 'maxRetries' AS max_retries
FROM crdb_internal.statement_statistics
WHERE (statistics -> 'statistics' -> 'maxRetries')::INT > 0
ORDER BY (statistics -> 'statistics' -> 'maxRetries')::INT DESC
LIMIT 20;

-- Active contention events
SELECT * FROM crdb_internal.cluster_contention_events
ORDER BY count DESC LIMIT 20;
```

### Reducing Retry Frequency

1. **Keep transactions short**: Minimize rows touched and execution time
2. **Use SELECT FOR UPDATE**: Acquire locks early to prevent conflicts
   ```sql
   BEGIN;
   SELECT * FROM accounts WHERE id = $1 FOR UPDATE;
   UPDATE accounts SET balance = balance - 100 WHERE id = $1;
   COMMIT;
   ```
3. **Reduce transaction scope**: Split large transactions into smaller batches
4. **Use single-statement implicit transactions** where possible
5. **Add client-side retry logic**: Always implement retry with exponential backoff
6. **Avoid reading and then writing** the same data — use UPDATE with expressions

## Contention Analysis

### Identifying Contention

```sql
-- Top contended tables/indexes
SELECT
    table_id,
    index_id,
    key,
    count AS contention_count
FROM crdb_internal.cluster_contention_events
ORDER BY count DESC
LIMIT 20;

-- Currently blocked transactions
SELECT
    blocking_txn_id,
    waiting_txn_id,
    contending_key
FROM crdb_internal.cluster_locks
WHERE granted = false;

-- Contention time per statement
SELECT
    metadata ->> 'query' AS query,
    statistics -> 'statistics' ->> 'contentionTime' AS contention_time
FROM crdb_internal.statement_statistics
WHERE (statistics -> 'statistics' -> 'contentionTime' ->> 'mean')::FLOAT > 0
ORDER BY (statistics -> 'statistics' -> 'contentionTime' ->> 'mean')::FLOAT DESC
LIMIT 10;
```

### Lock Wait Queues

CockroachDB v22.2+ provides observability into lock wait queues:

```sql
-- View active lock holders and waiters
SELECT
    lock_key_pretty,
    txn_id,
    granted,
    contended
FROM crdb_internal.cluster_locks
WHERE contended = true;
```

### Resolving Contention

- **Redesign hot keys**: Use UUID PKs, avoid sequential writes to same row
- **SELECT FOR UPDATE early**: Acquire locks at transaction start
- **Reduce transaction duration**: Less time = smaller conflict window
- **Partition writes**: Shard counters across multiple rows
- **Use UPSERT** instead of SELECT-then-INSERT patterns

## Hot Ranges

### Detecting Hotspots

```sql
-- Find hot ranges by QPS
SELECT
    range_id,
    table_name,
    index_name,
    start_pretty,
    end_pretty,
    queries_per_second,
    lease_holder
FROM crdb_internal.ranges
ORDER BY queries_per_second DESC
LIMIT 10;

-- Hot ranges from DB Console
-- Navigate to Advanced Debug > Hot Ranges
```

In the DB Console, check the **Hot Ranges** page under Advanced Debug for a
visual breakdown.

### Sequential Key Hotspots

The most common hotspot cause is sequential primary keys:

```sql
-- PROBLEM: All inserts go to the last range
CREATE TABLE logs (
    id INT PRIMARY KEY DEFAULT unique_rowid(),
    message STRING
);

-- SOLUTION: Use UUID
CREATE TABLE logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    message STRING
);

-- SOLUTION: Hash-sharded index for sequential data
CREATE TABLE timeseries (
    ts TIMESTAMPTZ NOT NULL,
    value FLOAT,
    PRIMARY KEY (ts) USING HASH WITH (bucket_count = 16)
);
```

### Mitigating Hotspots

1. Switch from `SERIAL`/`INT` to `UUID` primary keys
2. Use hash-sharded indexes for sequential workloads
3. Prepend tenant ID to primary key for multi-tenant workloads
4. Split hot ranges manually:
   ```sql
   ALTER TABLE hot_table SPLIT AT VALUES ('split-point-key');
   ```
5. Increase range split threshold if ranges are splitting too aggressively

## Leaseholder Rebalancing

### Checking Leaseholder Distribution

```sql
-- Leaseholder distribution per node
SELECT
    lease_holder,
    count(*) AS range_count
FROM crdb_internal.ranges
GROUP BY lease_holder
ORDER BY range_count DESC;

-- Per-table leaseholder distribution
SELECT
    lease_holder,
    table_name,
    count(*) AS range_count
FROM crdb_internal.ranges
GROUP BY lease_holder, table_name
ORDER BY range_count DESC;
```

### Manual Rebalancing

```sql
-- Move lease for a specific range
ALTER RANGE <range_id> RELOCATE LEASE TO <node_id>;

-- Scatter ranges for a table (force rebalancing)
ALTER TABLE orders SCATTER;

-- Unsplit ranges (remove manual splits)
ALTER TABLE orders UNSPLIT ALL;
```

### Rebalancing Settings

```sql
-- Adjust rebalancing aggressiveness
SET CLUSTER SETTING kv.allocator.load_based_rebalancing = 'leases and replicas';

-- Range rebalance rate
SET CLUSTER SETTING kv.snapshot_rebalance.max_rate = '64MiB';

-- Lease transfer rate
SET CLUSTER SETTING kv.allocator.lease_rebalance_threshold = 0.05;
```

## Clock Skew and max-offset

### How CockroachDB Uses Clocks

CockroachDB uses Hybrid Logical Clocks (HLC) that combine wall-clock time
with a logical counter. Nodes reject operations if clock skew exceeds
`--max-offset` (default: 500ms).

### Detecting Clock Skew

```bash
# Check node status for clock offset
cockroach node status --insecure --host=localhost:26257 \
  --format=table --decommission

# Verify NTP synchronization
timedatectl status
chronyc tracking
ntpq -p
```

```sql
-- Check clock offset from SQL
SELECT node_id, address,
       (metrics->>'clock-offset.meannanos')::FLOAT / 1e6 AS offset_ms
FROM crdb_internal.gossip_nodes;
```

**Symptom**: Nodes crash with `clock synchronization error: this node is more
than 500ms away from at least half of the known nodes`.

### Resolving Clock Issues

1. **Ensure NTP/chrony is running** on all nodes
2. **Use the same NTP source** across all nodes
3. **Increase max-offset** if network latency is high (not recommended for
   most deployments):
   ```bash
   cockroach start --max-offset=1000ms ...
   ```
4. **For cloud deployments**: Use cloud provider NTP services (Google, AWS, Azure)
5. **Monitor continuously**: Alert when clock offset exceeds 200ms

## Node Decommissioning Stuck

### Decommission Process

```bash
# Graceful decommission (moves all ranges off the node)
cockroach node decommission <node_id> --insecure --host=localhost:26257
```

Decommissioning:
1. Marks node as "decommissioning"
2. Moves all replicas to other nodes
3. Marks node as "decommissioned" when all replicas are moved

### Diagnosing Stuck Decommission

```sql
-- Check decommission progress
SELECT node_id, is_decommissioning, is_draining, ranges, replicas
FROM crdb_internal.gossip_liveness;

-- Find ranges still on the decommissioning node
SELECT range_id, table_name, replicas
FROM crdb_internal.ranges
WHERE <node_id> = ANY(replicas);

-- Check if ranges can't move (constraint violations)
SHOW ZONE CONFIGURATIONS;
```

Common causes:
1. **Insufficient nodes**: Removing a node would violate replication factor
2. **Zone constraints**: Constraints prevent replicas from moving to available nodes
3. **Node is unreachable**: Network partition prevents replica transfer
4. **Under-replicated ranges**: Other ranges are already degraded

### Forcing Decommission

```bash
# If a node is dead and will not return:
cockroach node decommission <node_id> --insecure --host=localhost:26257 --wait=none

# For truly stuck cases, wait for automatic replica recovery.
# CockroachDB will re-replicate ranges from dead nodes after 5 minutes by default.

# Adjust dead node detection timeout
cockroach sql --insecure -e \
  "SET CLUSTER SETTING server.time_until_store_dead = '5m0s';"
```

## Changefeed Lag

### Monitoring Changefeed Progress

```sql
-- Check changefeed status and high-water mark
SELECT
    job_id,
    description,
    status,
    high_water_timestamp,
    error,
    running_status
FROM [SHOW CHANGEFEED JOBS]
ORDER BY created DESC;

-- Changefeed metrics
SELECT name, value
FROM crdb_internal.node_metrics
WHERE name LIKE '%changefeed%'
ORDER BY name;
```

### Common Lag Causes

1. **Sink backpressure**: Kafka/webhook sink can't keep up with event volume
2. **Schema changes**: Backfilling after schema change pauses the feed
3. **Large initial scan**: First scan of a large table takes time
4. **GC overtaking changefeed**: If lag > GC TTL, changefeed fails
5. **Resource constraints**: Insufficient CPU/memory on changefeed coordinator
6. **Network issues**: Connectivity problems to the sink

### Resolving Lag Issues

```sql
-- Increase changefeed parallelism
SET CLUSTER SETTING changefeed.sink_io_workers = 16;

-- Reduce resolved timestamp frequency (less overhead)
-- In changefeed creation:
-- WITH resolved = '30s'

-- Increase memory budget for changefeeds
SET CLUSTER SETTING changefeed.memory.per_changefeed_limit = '1GiB';

-- If changefeed failed, restart from a specific timestamp
-- Cancel old job and create new one with cursor:
CANCEL JOB <job_id>;
CREATE CHANGEFEED FOR TABLE orders
INTO 'kafka://...'
WITH cursor = '<high_water_timestamp from failed job>';

-- Extend GC TTL to prevent GC overtaking changefeed
ALTER TABLE orders CONFIGURE ZONE USING gc.ttlseconds = 86400;
```

## OOM on Large Imports

### Memory Pressure During Import

`IMPORT INTO` and `IMPORT TABLE` load data through SQL nodes and can consume
significant memory, especially for:
- Large CSV/AVRO files
- Tables with many secondary indexes
- Concurrent imports

### Preventing OOM

```sql
-- Reduce import batch size
SET CLUSTER SETTING bulkio.import.batch_size = '32MiB';

-- Limit concurrent import processors
SET CLUSTER SETTING bulkio.import.max_import_parallelism = 2;

-- Drop secondary indexes before import, recreate after
DROP INDEX idx_orders_customer;
IMPORT INTO orders (...) CSV DATA ('gs://...');
CREATE INDEX idx_orders_customer ON orders (customer_id);
```

```bash
# Increase node memory allocation
cockroach start --cache=.25 --max-sql-memory=.25 ...
# .25 = 25% of total memory for each (cache and SQL memory)
```

### Alternative Import Strategies

1. **Split large files**: Break files into smaller chunks (< 500MB each)
2. **Use IMPORT INTO** instead of IMPORT TABLE for existing tables
3. **Batch inserts**: For smaller datasets, use multi-row INSERT batches
4. **Use `cockroach import`**: CLI-based import may be more memory-efficient
5. **Disable automatic statistics during import**:
   ```sql
   SET CLUSTER SETTING sql.stats.automatic_collection.enabled = false;
   IMPORT INTO ...;
   SET CLUSTER SETTING sql.stats.automatic_collection.enabled = true;
   ```

## Slow Schema Changes

### Schema Change Mechanics

CockroachDB schema changes are **online** — they don't block reads or writes.
They work through a multi-phase state machine:

1. **Write-only**: New index/column accepts writes but isn't visible to reads
2. **Delete-and-write-only**: Handles deletes and writes
3. **Backfill**: Populates the new structure with existing data
4. **Public**: Schema change is complete

### Diagnosing Slow DDL

```sql
-- Check running schema changes
SHOW JOBS WHERE job_type = 'SCHEMA CHANGE' AND status = 'running';

-- Detailed job progress
SELECT
    job_id,
    description,
    status,
    fraction_completed,
    running_status,
    created,
    finished
FROM [SHOW JOBS]
WHERE job_type = 'SCHEMA CHANGE'
ORDER BY created DESC;

-- Schema change GC jobs (cleanup)
SHOW JOBS WHERE job_type = 'SCHEMA CHANGE GC';
```

### Schema Change Best Practices

1. **One DDL per statement**: Never wrap DDL in explicit transactions
2. **Avoid concurrent schema changes on the same table**
3. **Create indexes CONCURRENTLY** for large tables
4. **Add columns with defaults carefully**: Adding `NOT NULL` columns with
   defaults requires backfilling every row
5. **Monitor progress**: Large backfills can take hours on big tables
6. **Schedule during low-traffic windows**: Backfills compete for I/O
7. **Increase schema change speed limit** if cluster has spare capacity:
   ```sql
   SET CLUSTER SETTING bulkio.index_backfill.batch_size = 50000;
   ```

## Range Splits and Merges

### Understanding Range Lifecycle

- **Split**: When a range exceeds ~128 MiB (2× target of 64 MiB), it splits into two
- **Merge**: When adjacent ranges are both below ~48 MiB (3/4 of target), they merge
- Splits also happen based on load (queries per second)

### Diagnosing Range Issues

```sql
-- Count ranges per table
SELECT
    table_name,
    count(*) AS range_count,
    sum(range_size_mb) AS total_size_mb
FROM crdb_internal.ranges
GROUP BY table_name
ORDER BY range_count DESC;

-- Find very small ranges (merge candidates)
SELECT range_id, table_name, range_size_mb
FROM crdb_internal.ranges
WHERE range_size_mb < 1
ORDER BY range_size_mb ASC
LIMIT 20;

-- Find large ranges (split candidates)
SELECT range_id, table_name, range_size_mb
FROM crdb_internal.ranges
WHERE range_size_mb > 128
ORDER BY range_size_mb DESC
LIMIT 20;
```

### Tuning Range Behavior

```sql
-- Adjust default range size (per table)
ALTER TABLE large_table CONFIGURE ZONE USING
    range_min_bytes = 134217728,  -- 128 MiB
    range_max_bytes = 536870912;  -- 512 MiB

-- Manual split
ALTER TABLE events SPLIT AT VALUES ('2024-01-01');

-- Remove all manual splits
ALTER TABLE events UNSPLIT ALL;

-- Load-based splitting threshold
SET CLUSTER SETTING kv.range_split.by_load_enabled = true;
SET CLUSTER SETTING kv.range_split.load_qps_threshold = 2500;
```

## Admission Control

### How Admission Control Works

CockroachDB v22.1+ includes admission control that throttles work to prevent
overload. It manages queues for:

- **SQL KV response** (reads)
- **SQL SQL response** (SQL processing)
- **SQL-KV-stores** (writes to disk)

When a node is overloaded, admission control queues incoming requests to
prevent cascading failures.

### Diagnosing Throttling

```sql
-- Check admission control metrics
SELECT name, value
FROM crdb_internal.node_metrics
WHERE name LIKE '%admission%'
ORDER BY name;

-- Key metrics to watch:
-- admission.wait_durations.kv-stores (write queuing)
-- admission.wait_durations.sql-kv-response (read queuing)
-- admission.granter.io_tokens_exhausted_duration.kv-stores (disk saturation)
```

Symptoms of admission control activation:
- Increased query latency with "queued" status in slow query log
- `admission.wait_durations` metrics increasing
- IO tokens exhausted metrics rising

### Tuning Admission Control

```sql
-- Enable/disable admission control
SET CLUSTER SETTING admission.kv.enabled = true;
SET CLUSTER SETTING admission.sql_kv_response.enabled = true;
SET CLUSTER SETTING admission.sql_sql_response.enabled = true;

-- Adjust disk bandwidth (for write admission)
SET CLUSTER SETTING kvadmission.store.provisioned_bandwidth = '500MiB/s';
```

Generally, do **not** disable admission control — it prevents cascading
failures. Instead, address the root cause of overload:
- Add more nodes
- Optimize heavy queries
- Reduce write throughput
- Upgrade disk I/O capacity

## General Diagnostic Toolkit

### Essential Commands

```bash
# Collect full diagnostic bundle
cockroach debug zip diagnostic.zip --insecure --host=localhost:26257

# Node status with decommission info
cockroach node status --insecure --host=localhost:26257

# Check store details
cockroach debug range ls --insecure --host=localhost:26257

# Network connectivity test
cockroach debug doctor cluster --insecure --host=localhost:26257
```

### Essential SQL Queries

```sql
-- Cluster version
SELECT crdb_internal.node_executable_version();

-- All running jobs
SHOW JOBS;

-- Statement statistics
SELECT * FROM crdb_internal.statement_statistics
ORDER BY (statistics -> 'statistics' -> 'svcLat' ->> 'mean')::FLOAT DESC
LIMIT 20;

-- Active queries
SELECT query, phase, application_name
FROM [SHOW CLUSTER STATEMENTS]
WHERE application_name NOT LIKE '$ internal%';

-- Transaction statistics
SELECT * FROM crdb_internal.transaction_statistics
ORDER BY (statistics -> 'statistics' -> 'svcLat' ->> 'mean')::FLOAT DESC
LIMIT 20;

-- Disk usage per store
SELECT node_id, store_id, used, available, capacity
FROM crdb_internal.kv_store_status;
```

### Health Check Query

```sql
-- Quick cluster health check
SELECT
    (SELECT count(*) FROM crdb_internal.gossip_nodes) AS total_nodes,
    (SELECT count(*) FROM crdb_internal.gossip_nodes
     WHERE expiration > now()) AS live_nodes,
    (SELECT count(*) FROM crdb_internal.ranges
     WHERE array_length(replicas, 1) < 3) AS under_replicated_ranges,
    (SELECT count(*) FROM crdb_internal.ranges
     WHERE array_length(replicas, 1) > 3) AS over_replicated_ranges,
    (SELECT count(*) FROM [SHOW JOBS]
     WHERE status = 'running' AND job_type = 'SCHEMA CHANGE') AS running_schema_changes;
```
