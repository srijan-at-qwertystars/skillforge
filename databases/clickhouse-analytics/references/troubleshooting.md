# ClickHouse Troubleshooting Guide

## Table of Contents

- [Slow Queries](#slow-queries)
- [Too Many Parts Error](#too-many-parts-error)
- [Merge Bottlenecks](#merge-bottlenecks)
- [Memory Limit Exceeded](#memory-limit-exceeded)
- [Distributed Query Failures](#distributed-query-failures)
- [Replication Lag](#replication-lag)
- [ZooKeeper / Keeper Issues](#zookeeper--keeper-issues)
- [Corrupted Parts Recovery](#corrupted-parts-recovery)
- [Mutation Stuck](#mutation-stuck)
- [Table Stuck in Readonly Mode](#table-stuck-in-readonly-mode)
- [Diagnostic System Tables Reference](#diagnostic-system-tables-reference)

---

## Slow Queries

### Symptoms
- Queries taking seconds or minutes when sub-second is expected.
- High CPU usage during query execution.
- Dashboard timeouts.

### Diagnosis

**Step 1: Identify slow queries from query_log**

```sql
SELECT
    query_start_time,
    query_duration_ms,
    read_rows,
    formatReadableSize(read_bytes) AS data_read,
    formatReadableSize(memory_usage) AS peak_memory,
    query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today() - 1
  AND query_duration_ms > 1000
ORDER BY query_duration_ms DESC
LIMIT 20;
```

**Step 2: Check currently running queries**

```sql
SELECT
    query_id,
    user,
    elapsed,
    formatReadableSize(read_bytes) AS data_read,
    formatReadableSize(memory_usage) AS mem,
    query
FROM system.processes
ORDER BY elapsed DESC;
```

**Step 3: Examine the query plan**

```sql
EXPLAIN SELECT ... ;          -- logical plan
EXPLAIN PIPELINE SELECT ... ; -- physical pipeline
EXPLAIN ESTIMATE SELECT ... ; -- estimated rows/bytes to read
```

### Common Causes and Fixes

| Cause | Fix |
|---|---|
| Full table scan (no filter on ORDER BY key) | Rewrite query to filter on ordering key columns |
| `SELECT *` reading unnecessary columns | Specify only needed columns |
| Large JOIN with unsorted right table | Use dictionaries, IN subquery, or pre-aggregate |
| No PREWHERE optimization | Add explicit `PREWHERE` on selective columns |
| Missing data skipping index | Add `bloom_filter`, `set`, or `minmax` index |
| Too many parts (fragmented reads) | Optimize table or wait for background merges |
| Large GROUP BY cardinality | Use approximate functions (`uniq` instead of `uniqExact`) |
| Sorting large result sets | Remove unnecessary `ORDER BY` or add `LIMIT` |

**Kill a runaway query:**

```sql
KILL QUERY WHERE query_id = 'abc123';
-- or kill all queries by a user
KILL QUERY WHERE user = 'analyst' AND elapsed > 300;
```

---

## Too Many Parts Error

### Symptoms
- Error: `DB::Exception: Too many parts (N). Merges are processing significantly slower than inserts`
- Inserts start failing with code 252.
- `parts_to_throw_insert` threshold exceeded.

### Diagnosis

```sql
-- Check parts per partition per table
SELECT
    database,
    table,
    partition,
    count() AS part_count,
    sum(rows) AS total_rows,
    formatReadableSize(sum(bytes_on_disk)) AS size
FROM system.parts
WHERE active
GROUP BY database, table, partition
HAVING part_count > 50
ORDER BY part_count DESC;
```

### Root Causes

1. **Too many small inserts** — Each INSERT creates a new part. Inserting row-by-row or in tiny batches is the #1 cause.
2. **High-cardinality partition key** — Partitioning by user_id or session_id creates millions of partitions.
3. **Merges can't keep up** — Background merge pool is too small, or disk I/O is saturated.
4. **Materialized views multiplying parts** — Each MV destination gets its own parts from each insert.

### Fixes

```sql
-- Force merge
OPTIMIZE TABLE db.table FINAL;

-- Force merge for a specific partition
OPTIMIZE TABLE db.table PARTITION '202501' FINAL;
```

**Configuration adjustments:**

```xml
<!-- Increase merge parallelism -->
<merge_tree>
    <background_pool_size>32</background_pool_size>
    <!-- Raise the threshold temporarily (default: 300) -->
    <parts_to_throw_insert>600</parts_to_throw_insert>
    <parts_to_delay_insert>300</parts_to_delay_insert>
    <max_delay_to_insert>60</max_delay_to_insert>
</merge_tree>
```

**Long-term fixes:**
- Enable async inserts: `SET async_insert = 1` — server-side batching.
- Batch inserts to 10K–1M rows per INSERT.
- Simplify partition key (monthly instead of daily).
- Reduce number of materialized views per source table.

---

## Merge Bottlenecks

### Symptoms
- Parts count growing despite inserts stopping.
- `system.merges` shows long-running or stalled merges.
- Disk space growing faster than expected.

### Diagnosis

```sql
-- Active merges
SELECT
    database,
    table,
    elapsed,
    progress,
    num_parts AS merging_parts,
    formatReadableSize(total_size_bytes_compressed) AS size,
    formatReadableSize(memory_usage) AS mem
FROM system.merges
ORDER BY elapsed DESC;

-- Merge throughput over time
SELECT
    toStartOfHour(event_time) AS hour,
    countIf(event_type = 'MergeParts') AS merges_completed,
    sumIf(rows, event_type = 'MergeParts') AS rows_merged
FROM system.part_log
WHERE event_date >= today() - 1
GROUP BY hour
ORDER BY hour;
```

### Fixes

1. **Increase background_pool_size** (default 16, set to CPU core count or higher):
   ```xml
   <background_pool_size>32</background_pool_size>
   ```

2. **Check disk I/O saturation** — merges are I/O bound. Use `iostat` or check:
   ```sql
   SELECT * FROM system.asynchronous_metrics WHERE metric LIKE '%Disk%';
   ```

3. **Reduce write amplification** — fewer materialized views, fewer projections.

4. **Partition pruning** — ensure old partitions are dropped via TTL or manual `DROP PARTITION`.

5. **vertical_merge_algorithm_min_rows_to_activate** — for wide tables, enable vertical merges:
   ```sql
   ALTER TABLE t MODIFY SETTING
       vertical_merge_algorithm_min_rows_to_activate = 1,
       vertical_merge_algorithm_min_columns_to_activate = 11;
   ```

---

## Memory Limit Exceeded

### Symptoms
- Error: `DB::Exception: Memory limit (for query) exceeded: would use X GiB (attempt to allocate Y), maximum: Z GiB`
- Exception code 241.
- Query killed mid-execution.

### Diagnosis

```sql
-- Find memory-heavy queries
SELECT
    query_start_time,
    formatReadableSize(memory_usage) AS peak_memory,
    formatReadableSize(read_bytes) AS data_read,
    query_duration_ms,
    query
FROM system.query_log
WHERE type IN ('QueryFinish', 'ExceptionWhileProcessing')
  AND memory_usage > 5000000000  -- > 5GB
ORDER BY memory_usage DESC
LIMIT 10;

-- Check current server memory
SELECT
    metric,
    formatReadableSize(value) AS val
FROM system.asynchronous_metrics
WHERE metric IN ('MemoryTracking', 'MemoryResident', 'OSMemoryTotal');
```

### Common Causes and Fixes

| Cause | Fix |
|---|---|
| Large GROUP BY with high cardinality | Use `max_rows_to_group_by` with overflow mode |
| Large hash JOIN | Switch to `partial_merge` or `auto` join algorithm |
| Sorting huge result sets | Add LIMIT, avoid unnecessary ORDER BY |
| Reading too many columns | SELECT only needed columns |
| Large IN subquery | Materialize the subquery result first |

**Per-query memory tuning:**

```sql
-- Increase per-query limit
SET max_memory_usage = 30000000000;  -- 30 GB

-- Allow spilling to disk for GROUP BY
SET max_bytes_before_external_group_by = 5000000000;  -- 5 GB

-- Allow spilling to disk for ORDER BY
SET max_bytes_before_external_sort = 5000000000;

-- Allow spilling to disk for JOINs
SET join_algorithm = 'partial_merge';  -- or 'auto'
SET max_rows_in_join = 100000000;

-- Enable two-level aggregation for distributed queries
SET group_by_two_level_threshold = 100000;
```

**Server-level limits:**

```xml
<max_server_memory_usage_to_ram_ratio>0.8</max_server_memory_usage_to_ram_ratio>
<max_memory_usage>20000000000</max_memory_usage>
<max_memory_usage_for_user>40000000000</max_memory_usage_for_user>
```

---

## Distributed Query Failures

### Symptoms
- Error: `DB::NetException: Connection refused` or timeout errors.
- Partial results from distributed queries.
- Error: `All connection tries failed` for specific shards.

### Diagnosis

```sql
-- Check cluster topology
SELECT * FROM system.clusters;

-- Check which shards are reachable
SELECT
    cluster,
    shard_num,
    replica_num,
    host_name,
    port,
    is_local
FROM system.clusters
WHERE cluster = 'my_cluster';

-- Check distributed query errors
SELECT
    query_start_time,
    exception,
    query
FROM system.query_log
WHERE type = 'ExceptionWhileProcessing'
  AND exception LIKE '%Distributed%'
ORDER BY query_start_time DESC
LIMIT 10;
```

### Common Causes and Fixes

| Cause | Fix |
|---|---|
| Network partition between nodes | Check firewall rules, verify connectivity on ports 9000/9440 |
| Schema mismatch across shards | Ensure identical DDL on all shards (`ON CLUSTER` for schema changes) |
| DNS resolution failure | Verify hostnames resolve on all nodes |
| Resource exhaustion on a shard | Check memory/CPU/disk on the failing shard |
| Distributed table misconfiguration | Verify cluster name, database, and table in Distributed engine |

**Distributed query settings for reliability:**

```sql
-- Skip unavailable shards (return partial results)
SET skip_unavailable_shards = 1;

-- Prefer local replicas to reduce network
SET prefer_localhost_replica = 1;

-- Increase connection timeout
SET distributed_connections_pool_size = 1024;
SET connect_timeout_with_failover_ms = 5000;

-- For distributed INSERTs, wait for all shards
SET insert_distributed_sync = 1;
```

---

## Replication Lag

### Symptoms
- Data appears on one replica but not another.
- `system.replicas` shows `queue_size > 0` or `inserts_in_queue > 0`.
- Dashboard shows stale data.

### Diagnosis

```sql
-- Replication status overview
SELECT
    database,
    table,
    is_leader,
    is_readonly,
    total_replicas,
    active_replicas,
    queue_size,
    inserts_in_queue,
    merges_in_queue,
    log_pointer,
    last_queue_update,
    absolute_delay
FROM system.replicas
WHERE absolute_delay > 0 OR queue_size > 0
ORDER BY absolute_delay DESC;

-- Replication queue details
SELECT
    database,
    table,
    type,
    create_time,
    source_replica,
    num_tries,
    last_exception,
    postpone_reason
FROM system.replication_queue
WHERE num_tries > 0
ORDER BY create_time;
```

### Fixes

```sql
-- Force replica sync
SYSTEM SYNC REPLICA db.table_name;

-- Restart replication fetches
SYSTEM RESTART REPLICA db.table_name;

-- If a specific entry is stuck, drop and re-fetch
SYSTEM DROP REPLICA 'replica_name' FROM TABLE db.table_name;

-- Check if the issue is network (fetch from other replica)
SYSTEM SYNC REPLICA db.table_name STRICT;
```

**Common causes:**
- Slow network between replicas.
- Disk I/O bottleneck on the lagging replica.
- Keeper/ZooKeeper connectivity issues.
- Large mutations blocking replication queue.

---

## ZooKeeper / Keeper Issues

### Symptoms
- Error: `Coordination::Exception: Connection loss` or `Session expired`.
- Tables enter readonly mode.
- DDL operations (`ON CLUSTER`) hang.

### Diagnosis

```bash
# Check Keeper health (4-letter commands)
echo ruok | nc keeper-host 9181    # Should return: imok
echo stat | nc keeper-host 9181    # Leader/follower status
echo mntr | nc keeper-host 9181    # Metrics
echo srvr | nc keeper-host 9181    # Server details
```

```sql
-- Check ZooKeeper connectivity from ClickHouse
SELECT * FROM system.zookeeper WHERE path = '/clickhouse';

-- Check for ZooKeeper-related errors
SELECT * FROM system.errors WHERE name LIKE '%ZooKeeper%' OR name LIKE '%Keeper%';

-- Replicated table metadata health
SELECT database, table, zookeeper_path, replica_path
FROM system.replicas
WHERE is_session_expired;
```

### Common Issues and Fixes

**Session expired:**
- Keeper session timeout too short. Increase `session_timeout_ms` (default 30s, try 60s).
- Keeper nodes overloaded. Move Keeper to dedicated nodes.

**Connection refused:**
- Keeper not running. Check process and logs.
- Firewall blocking ports 9181 (client) or 9234 (raft).

**Too many znodes / large snapshots:**
- Clean up stale metadata:
  ```sql
  -- List tables in ZooKeeper
  SELECT * FROM system.zookeeper WHERE path = '/clickhouse/tables';
  ```
- Remove orphaned table paths (backup first, use with caution):
  ```bash
  clickhouse-keeper-client -h keeper-host -p 9181
  # rmr /clickhouse/tables/old_shard/dropped_table
  ```

**Split brain after network partition:**
- Ensure an odd number of Keeper nodes (3 or 5).
- After recovery, SYSTEM RESTART REPLICA on affected tables.

---

## Corrupted Parts Recovery

### Symptoms
- Error: `Cannot attach part ... checksum mismatch` or `Broken part detected`.
- Table fails to load on server restart.
- Queries return errors for specific partitions.

### Diagnosis

```sql
-- Check for detached parts
SELECT
    database,
    table,
    partition_id,
    name,
    reason,
    disk
FROM system.detached_parts;

-- Check part integrity
SELECT
    database,
    table,
    name,
    active,
    rows,
    bytes_on_disk,
    modification_time
FROM system.parts
WHERE database = 'mydb' AND table = 'mytable'
ORDER BY modification_time DESC;
```

### Recovery Procedures

**For replicated tables (safest — re-fetch from healthy replica):**

```sql
-- Drop the corrupted part; it will be re-fetched from another replica
ALTER TABLE db.table DROP DETACHED PART 'part_name';

-- Or restart the replica to trigger automatic recovery
SYSTEM RESTORE REPLICA db.table;

-- Force re-sync
SYSTEM SYNC REPLICA db.table;
```

**For non-replicated tables:**

```bash
# 1. Stop ClickHouse
# 2. Move corrupted part directory out
mv /var/lib/clickhouse/data/db/table/broken_part_name \
   /tmp/clickhouse_broken_parts/

# 3. Start ClickHouse — it will skip the missing part
# 4. Re-insert the data if needed
```

**Check and repair checksums:**

```sql
CHECK TABLE db.table;
-- Returns list of parts with checksum status

-- If parts are auto-detached, try re-attaching
ALTER TABLE db.table ATTACH PART 'part_name';
```

**Prevention:**
- Use replicated tables (data redundancy across replicas).
- Enable checksums (default: on).
- Monitor disk health (SMART, filesystem errors).
- Use ECC RAM.

---

## Mutation Stuck

### Symptoms
- `ALTER TABLE ... UPDATE/DELETE` submitted but never completes.
- `system.mutations` shows `is_done = 0` for extended periods.
- New mutations queue up behind the stuck one.

### Diagnosis

```sql
-- Check mutation status
SELECT
    database,
    table,
    mutation_id,
    command,
    create_time,
    is_done,
    latest_failed_part,
    latest_fail_reason,
    parts_to_do_names,
    parts_to_do
FROM system.mutations
WHERE is_done = 0
ORDER BY create_time;
```

### Common Causes

1. **Corrupted part blocking mutation** — mutation fails on a specific part repeatedly.
2. **Disk full** — no space to write the mutated part.
3. **Conflicting merge** — part is being merged while mutation tries to process it.
4. **Too many parts** — mutation waiting for parts count to decrease.

### Fixes

```sql
-- Kill a stuck mutation
KILL MUTATION WHERE mutation_id = 'mutation_id_here';

-- Kill all mutations on a table
KILL MUTATION WHERE database = 'mydb' AND table = 'mytable';

-- Alternative: remove the problematic part, then mutation proceeds
ALTER TABLE db.table DROP PART 'problematic_part_name';
```

**Best practices for mutations:**
- Mutations are async and rewrite entire parts. Avoid frequent UPDATE/DELETE.
- Use `ReplacingMergeTree` or `CollapsingMergeTree` instead of mutations for logical updates.
- Monitor `system.mutations` after submitting ALTER TABLE UPDATE/DELETE.
- Use `mutations_sync = 2` in the ALTER statement to wait for completion on all replicas.

---

## Table Stuck in Readonly Mode

### Symptoms
- Error: `DB::Exception: Table is in readonly mode`
- INSERT and ALTER operations rejected.
- SELECT queries still work.

### Diagnosis

```sql
-- Check which tables are readonly
SELECT
    database,
    table,
    is_readonly,
    is_session_expired,
    future_parts,
    queue_size,
    absolute_delay
FROM system.replicas
WHERE is_readonly = 1;
```

### Common Causes and Fixes

**1. Keeper session expired:**
```sql
-- Check session status
SELECT * FROM system.replicas WHERE is_session_expired = 1;

-- Fix: restart Keeper connection
SYSTEM RESTART REPLICA db.table;
```

**2. Disk full:**
```bash
# Check disk usage
df -h /var/lib/clickhouse/
du -sh /var/lib/clickhouse/data/*/

# Free space: drop old partitions, remove temporary files
```

```sql
ALTER TABLE db.table DROP PARTITION '202301';
SYSTEM DROP DNS CACHE;
SYSTEM DROP COMPILED EXPRESSION CACHE;
```

**3. ZooKeeper metadata inconsistency:**
```sql
-- Try to recover metadata
SYSTEM RESTORE REPLICA db.table;

-- If that fails, drop and re-create the table from another replica
-- (ensure you have a healthy replica first)
```

**4. Too many parts (insert protection):**
```sql
-- Check parts count
SELECT count() FROM system.parts WHERE database = 'mydb' AND table = 'mytable' AND active;

-- Force merge to reduce parts
OPTIMIZE TABLE db.mytable FINAL;
```

**5. Manual readonly flag:**
```sql
-- Check if readonly was set intentionally
SELECT value FROM system.settings WHERE name = 'readonly';
-- If readonly = 1 or 2, it was set in the profile/session. Reset it.
```

---

## Diagnostic System Tables Reference

| Table | Purpose |
|---|---|
| `system.query_log` | Historical query performance, errors, resource usage |
| `system.processes` | Currently running queries |
| `system.parts` | Data parts per table (row count, size, active status) |
| `system.merges` | Currently running merge operations |
| `system.mutations` | Status of ALTER UPDATE/DELETE operations |
| `system.replicas` | Replication health per table |
| `system.replication_queue` | Pending replication tasks |
| `system.detached_parts` | Parts that were detached (corrupt or manual) |
| `system.errors` | Error counters by type |
| `system.metrics` | Real-time server metrics (connections, queries, merges) |
| `system.events` | Cumulative event counters since server start |
| `system.asynchronous_metrics` | Periodically calculated metrics (memory, disk, CPU) |
| `system.trace_log` | CPU/real-time profiler stack traces |
| `system.part_log` | Part lifecycle events (create, merge, remove) |
| `system.clusters` | Cluster topology and shard/replica config |
| `system.zookeeper` | Browse ZooKeeper/Keeper metadata tree |
| `system.dictionaries` | Dictionary status, load time, hit rate |
| `system.disks` | Disk space and mount points |
| `system.storage_policies` | Storage policy configurations |

### Quick Health Check Query

```sql
SELECT
    (SELECT count() FROM system.processes) AS running_queries,
    (SELECT count() FROM system.merges) AS active_merges,
    (SELECT countIf(is_readonly) FROM system.replicas) AS readonly_tables,
    (SELECT countIf(absolute_delay > 300) FROM system.replicas) AS lagging_replicas,
    (SELECT countIf(is_done = 0) FROM system.mutations) AS pending_mutations,
    (SELECT formatReadableSize(value) FROM system.asynchronous_metrics
     WHERE metric = 'MemoryTracking') AS memory_used;
```
