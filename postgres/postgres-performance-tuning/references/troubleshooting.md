# PostgreSQL Performance Troubleshooting

Systematic diagnosis and remediation of common PostgreSQL performance problems: plan regressions, bloat, wraparound, replication lag, temp files, checkpoint spikes, OOM, connection exhaustion, long transactions, stuck queries, and index bloat.

---

## Table of Contents

1. [Sudden Query Regression](#sudden-query-regression)
2. [Table Bloat Diagnosis and Remediation](#table-bloat-diagnosis-and-remediation)
3. [Transaction ID Wraparound Prevention](#transaction-id-wraparound-prevention)
4. [Replication Lag Diagnosis](#replication-lag-diagnosis)
5. [Temp File Usage and Disk Spilling](#temp-file-usage-and-disk-spilling)
6. [Checkpoint Spikes and WAL Write Storms](#checkpoint-spikes-and-wal-write-storms)
7. [OOM Killer Interaction on Linux](#oom-killer-interaction-on-linux)
8. [Too Many Connections](#too-many-connections)
9. [Long-Running Transaction Detection and Kill](#long-running-transaction-detection-and-kill)
10. [pg_stat_activity Interpretation](#pg_stat_activity-interpretation)
11. [Index Bloat Detection and Reindexing](#index-bloat-detection-and-reindexing)

---

## Sudden Query Regression

A query that was fast yesterday is slow today. Common root causes:

### Plan Flip After ANALYZE

`ANALYZE` updates table statistics. New statistics can cause the planner to choose a different plan.

**Diagnosis:**
```sql
-- Check when statistics were last updated
SELECT schemaname, relname, last_analyze, last_autoanalyze,
       n_live_tup, n_dead_tup, n_mod_since_analyze
FROM pg_stat_user_tables
WHERE relname = 'your_table';
```

**Identify the old vs new plan:**
```sql
-- Compare plans with different statistics targets
SET default_statistics_target = 100;   -- default
EXPLAIN (ANALYZE, BUFFERS) SELECT ...;

SET default_statistics_target = 1000;  -- more granular stats
ANALYZE your_table;
EXPLAIN (ANALYZE, BUFFERS) SELECT ...;
```

**Fix:**
- Increase `default_statistics_target` for columns with skewed distributions:
  ```sql
  ALTER TABLE orders ALTER COLUMN status SET STATISTICS 1000;
  ANALYZE orders;
  ```
- Create extended statistics for correlated columns (PG 10+):
  ```sql
  CREATE STATISTICS orders_stats (dependencies, ndistinct, mcv)
  ON status, region FROM orders;
  ANALYZE orders;
  ```

### Config Change Side Effects

Changes to `work_mem`, `random_page_cost`, `effective_cache_size`, or `cpu_*` costs alter plan choices.

**Diagnosis:**
```sql
-- Check current non-default settings
SELECT name, setting, source
FROM pg_settings
WHERE source NOT IN ('default', 'override')
AND name IN ('work_mem', 'random_page_cost', 'effective_cache_size',
             'seq_page_cost', 'cpu_tuple_cost', 'cpu_index_tuple_cost',
             'cpu_operator_cost', 'enable_seqscan', 'enable_indexscan',
             'enable_hashjoin', 'enable_mergejoin', 'enable_nestloop');
```

```sql
-- Show settings that affect a specific plan (PG 12+)
EXPLAIN (ANALYZE, SETTINGS) SELECT ...;
```

### Statistics Drift

Data distribution changes over time. The default autovacuum `analyze` threshold may be too coarse for rapidly changing tables.

**Fix:**
```sql
-- Increase analyze frequency for rapidly changing tables
ALTER TABLE hot_table SET (
    autovacuum_analyze_scale_factor = 0.02,   -- 2% instead of 10% default
    autovacuum_analyze_threshold = 1000
);
```

### Emergency: Force a Specific Plan

When you need immediate relief while investigating:

```sql
-- Discourage specific scan types (per session or transaction)
SET enable_seqscan = off;       -- force index usage
SET enable_hashjoin = off;       -- force nested loop or merge join
SET enable_nestloop = off;       -- force hash or merge join

-- Pin a plan shape with pg_hint_plan (extension)
/*+ SeqScan(orders) HashJoin(orders customers) */ SELECT ...;
```

**Warning:** These are temporary workarounds. Fix the root cause (statistics, indexes, data model).

---

## Table Bloat Diagnosis and Remediation

Dead tuples accumulate when VACUUM cannot reclaim space (long transactions, aggressive writes, misconfigured autovacuum).

### Diagnosis

```sql
-- Quick bloat estimate using pgstattuple extension
CREATE EXTENSION IF NOT EXISTS pgstattuple;

SELECT * FROM pgstattuple('your_table');
-- Key fields: dead_tuple_percent, free_space, free_percent

-- For large tables, use the approx variant (much faster)
SELECT * FROM pgstattuple_approx('your_table');
```

```sql
-- Bloat estimation without extensions (heuristic based on pg_class)
SELECT
    schemaname, tablename,
    pg_size_pretty(pg_relation_size(schemaname || '.' || tablename)) AS table_size,
    n_dead_tup,
    n_live_tup,
    CASE WHEN n_live_tup > 0
        THEN round(100.0 * n_dead_tup / n_live_tup, 1)
        ELSE 0
    END AS dead_pct,
    last_autovacuum,
    last_autoanalyze
FROM pg_stat_user_tables
WHERE n_dead_tup > 10000
ORDER BY n_dead_tup DESC;
```

### Remediation Options

#### Option 1: VACUUM (online, safe)

```sql
VACUUM VERBOSE your_table;
```

Reclaims dead tuple space for reuse **within** the table, but does **not** return space to the OS. The table file size stays the same. Sufficient if the table will grow back to the same size.

#### Option 2: VACUUM FULL (offline, locks table)

```sql
VACUUM FULL your_table;
```

Rewrites the entire table, reclaiming all dead space. **Takes an ACCESS EXCLUSIVE lock** — blocks all reads and writes. Only use during maintenance windows.

#### Option 3: pg_repack (online, preferred)

```sql
-- Install extension
CREATE EXTENSION pg_repack;
```

```bash
# Repack a table without locking (online)
pg_repack -d mydb -t your_table

# Repack a specific index
pg_repack -d mydb -i idx_your_table_pkey

# Repack all tables in a database
pg_repack -d mydb
```

**How pg_repack works:**
1. Creates a shadow copy of the table
2. Copies live data to the shadow table
3. Applies accumulated changes via a trigger
4. Swaps table names in a brief lock
5. Drops the old table

**Advantages over VACUUM FULL:**
- Only holds a brief ACCESS EXCLUSIVE lock at the end (swap)
- Table remains readable/writable during repacking
- Also repacks indexes

**Requirements:**
- Enough disk space for a full copy of the table
- Table must have a primary key or unique index with NOT NULL columns

#### Option 4: CLUSTER (offline, locks table)

```sql
CLUSTER your_table USING idx_your_table_date;
```

Physically reorders the table by the specified index and removes bloat. Useful when physical ordering improves range scan performance. Takes ACCESS EXCLUSIVE lock like VACUUM FULL.

### Prevention

```sql
-- Aggressive autovacuum for high-write tables
ALTER TABLE hot_table SET (
    autovacuum_vacuum_scale_factor = 0.01,     -- vacuum at 1% dead tuples
    autovacuum_vacuum_threshold = 1000,
    autovacuum_vacuum_cost_delay = 2,          -- faster vacuuming (default 2ms PG14+, 20ms older)
    autovacuum_vacuum_cost_limit = 1000        -- more work per cycle
);
```

---

## Transaction ID Wraparound Prevention

PostgreSQL uses 32-bit transaction IDs (XIDs). After ~2 billion transactions, wraparound occurs: all past data becomes "in the future" and invisible. PostgreSQL forces a shutdown to prevent data loss.

### Monitoring XID Age

```sql
-- Check database XID age (critical threshold: 2 billion)
SELECT datname,
       age(datfrozenxid) AS xid_age,
       pg_size_pretty(pg_database_size(datname)) AS db_size
FROM pg_database
ORDER BY age(datfrozenxid) DESC;

-- Check per-table XID age
SELECT schemaname, relname,
       age(relfrozenxid) AS xid_age,
       pg_size_pretty(pg_relation_size(oid)) AS size,
       last_autovacuum
FROM pg_stat_user_tables
JOIN pg_class ON pg_stat_user_tables.relid = pg_class.oid
WHERE age(relfrozenxid) > 100000000  -- tables older than 100M transactions
ORDER BY age(relfrozenxid) DESC;
```

### Warning Levels

| XID Age | Status | Action |
|---------|--------|--------|
| < 200M | Normal | Autovacuum handles this |
| 200M – 500M | Watch | Ensure autovacuum is working |
| 500M – 1B | Warning | Investigate why autovacuum isn't freezing |
| 1B – 1.5B | Critical | Manual VACUUM FREEZE, increase autovacuum resources |
| > 1.5B | Emergency | Drop everything, run VACUUM FREEZE immediately |
| 2B | Shutdown | PostgreSQL refuses to start new transactions |

### Emergency Response

```sql
-- 1. Identify the worst offender
SELECT c.oid::regclass, age(c.relfrozenxid), pg_size_pretty(pg_relation_size(c.oid))
FROM pg_class c
JOIN pg_namespace n ON c.relnamespace = n.oid
WHERE c.relkind = 'r' AND n.nspname NOT IN ('pg_catalog', 'information_schema')
ORDER BY age(c.relfrozenxid) DESC
LIMIT 10;

-- 2. Kill any long-running transactions blocking vacuum
SELECT pid, age(backend_xid) AS xid_age, state, query
FROM pg_stat_activity
WHERE backend_xid IS NOT NULL
ORDER BY age(backend_xid) DESC;

SELECT pg_terminate_backend(pid);  -- kill the blocking session

-- 3. Run aggressive VACUUM FREEZE
VACUUM (FREEZE, VERBOSE) problem_table;

-- 4. If the table is huge, increase maintenance resources temporarily
SET maintenance_work_mem = '2GB';
SET vacuum_cost_delay = 0;        -- no throttling
VACUUM (FREEZE, VERBOSE) problem_table;
```

### Prevention

```sql
-- In postgresql.conf
autovacuum_freeze_max_age = 200000000          -- trigger anti-wraparound at 200M (default)
vacuum_freeze_min_age = 50000000               -- freeze tuples older than 50M XIDs
vacuum_freeze_table_age = 150000000            -- full-table freeze scan at 150M
```

Set up monitoring alerts for `age(datfrozenxid) > 500000000`.

---

## Replication Lag Diagnosis

### Streaming Replication

```sql
-- On PRIMARY: check replication slots and lag
SELECT slot_name, active,
       pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) AS lag_bytes,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS lag_pretty
FROM pg_replication_slots;

-- On PRIMARY: check connected standbys
SELECT client_addr, state, sent_lsn, write_lsn, flush_lsn, replay_lsn,
       pg_wal_lsn_diff(sent_lsn, replay_lsn) AS replay_lag_bytes,
       write_lag, flush_lag, replay_lag  -- interval columns (PG 10+)
FROM pg_stat_replication;

-- On REPLICA: check lag from replica's perspective
SELECT now() - pg_last_xact_replay_timestamp() AS replication_delay;
```

**Common causes of streaming replication lag:**
- Network bandwidth/latency between primary and replica
- Disk I/O on the replica (especially during heavy write bursts)
- Replica running expensive queries that block WAL replay (`hot_standby_feedback`, `max_standby_*_delay`)
- Large transactions producing massive WAL volume
- Replica falling behind during maintenance operations

**Fixes:**
```sql
-- On replica: allow queries to be cancelled to keep up with WAL replay
ALTER SYSTEM SET max_standby_streaming_delay = '5s';  -- default 30s
ALTER SYSTEM SET max_standby_archive_delay = '5s';

-- On primary: use synchronous_commit = 'local' to avoid lag causing primary slowdowns
ALTER SYSTEM SET synchronous_commit = 'local';
```

### Logical Replication

```sql
-- Check logical replication slot lag
SELECT slot_name, plugin, active,
       pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn) AS lag_bytes,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) AS lag_pretty
FROM pg_replication_slots
WHERE slot_type = 'logical';

-- Check subscription status on the subscriber
SELECT subname, pid, relid::regclass, received_lsn, last_msg_send_time,
       last_msg_receipt_time, latest_end_lsn
FROM pg_stat_subscription;
```

**Common causes of logical replication lag:**
- Large table initial sync (COPY phase)
- Missing indexes on subscriber tables (applying changes is slow)
- Schema conflicts (subscriber table has constraints or triggers slowing apply)
- Publisher generating high WAL volume with many small transactions

**Critical:** Inactive replication slots prevent WAL recycling. Monitor for `active = false` slots and drop unused ones:

```sql
-- Check WAL retained by slots
SELECT slot_name, active,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS wal_retained
FROM pg_replication_slots
WHERE NOT active;

-- Drop an unused slot (WARNING: subscriber will need re-sync)
SELECT pg_drop_replication_slot('unused_slot_name');
```

---

## Temp File Usage and Disk Spilling

When operations exceed `work_mem`, PostgreSQL spills intermediate results to temp files on disk. This is orders of magnitude slower than in-memory processing.

### Detection

```sql
-- Enable temp file logging
ALTER SYSTEM SET log_temp_files = 0;  -- log ALL temp files (0 = all, or set KB threshold)
SELECT pg_reload_conf();
```

Log output:
```
LOG:  temporary file: path "base/pgsql_tmp/pgsql_tmp1234.5", size 104857600
STATEMENT:  SELECT ... ORDER BY ... 
```

```sql
-- Check current temp file usage per session
SELECT pid, query,
       temp_blks_read, temp_blks_written,
       pg_size_pretty((temp_blks_written * 8192)::bigint) AS temp_written
FROM pg_stat_activity
JOIN pg_stat_statements USING (queryid)
WHERE temp_blks_written > 0;
```

```sql
-- Top queries by temp file usage (requires pg_stat_statements)
SELECT query, calls,
       temp_blks_read, temp_blks_written,
       pg_size_pretty((temp_blks_written * 8192)::bigint) AS temp_written_total,
       pg_size_pretty((temp_blks_written * 8192 / calls)::bigint) AS temp_written_per_call
FROM pg_stat_statements
WHERE temp_blks_written > 0
ORDER BY temp_blks_written DESC
LIMIT 20;
```

### Diagnosis in EXPLAIN

```sql
EXPLAIN (ANALYZE, BUFFERS) SELECT ... ORDER BY large_column;
```

```
Sort (actual time=500..2500 rows=1000000)
  Sort Key: large_column
  Sort Method: external merge  Disk: 256000kB    ← SPILLING TO DISK
  Buffers: temp read=32000 written=32000          ← temp file I/O
```

**Sort methods:**
| Method | Meaning |
|--------|---------|
| `quicksort Memory: XkB` | Fit in memory ✓ |
| `top-N heapsort Memory: XkB` | Fit in memory, used with LIMIT ✓ |
| `external merge Disk: XkB` | Spilled to disk ✗ |
| `external sort Disk: XkB` | Spilled to disk ✗ |

Hash Join/Hash Aggregate nodes also report batches when spilling:
```
HashAggregate (actual time=...)
  Batches: 8  Memory Usage: 4096kB  Disk Usage: 128000kB  ← SPILLING
```

### Remediation

```sql
-- Option 1: Increase work_mem for the specific query
SET work_mem = '256MB';
SELECT ... ORDER BY large_column;
RESET work_mem;

-- Option 2: Increase globally (careful — multiplied by connections × sort operations)
ALTER SYSTEM SET work_mem = '64MB';  -- default is 4MB

-- Option 3: Set per-user or per-database
ALTER DATABASE analytics SET work_mem = '256MB';
ALTER USER reporting_user SET work_mem = '256MB';
```

**work_mem sizing rule of thumb:**
```
Available RAM = Total RAM - shared_buffers - OS cache needs
Max work_mem = Available RAM / (max_connections × estimated_sorts_per_query)
```

A connection running a complex query might allocate `work_mem` multiple times (once per sort/hash node). Set conservatively for OLTP; set higher per-session for analytics.

### Temp File Disk Space

```bash
# Check temp file directory usage
du -sh $PGDATA/base/pgsql_tmp/

# Or use a dedicated temp tablespace on fast storage
```

```sql
-- Use a dedicated tablespace for temp files
CREATE TABLESPACE fast_temp LOCATION '/ssd/pg_tmp';
ALTER SYSTEM SET temp_tablespaces = 'fast_temp';
```

---

## Checkpoint Spikes and WAL Write Storms

Checkpoints flush all dirty buffers to disk. Poorly tuned checkpoints cause I/O spikes that stall queries.

### Symptoms

- Periodic latency spikes every few minutes
- `pg_stat_bgwriter` shows high `buffers_backend` (backends doing their own writes instead of bgwriter)
- Disk I/O graphs show sharp spikes at regular intervals

### Diagnosis

```sql
SELECT checkpoints_timed, checkpoints_req,
       buffers_checkpoint, buffers_clean, buffers_backend,
       pg_size_pretty(buffers_checkpoint * 8192::bigint) AS checkpoint_written,
       pg_size_pretty(buffers_backend * 8192::bigint) AS backend_written
FROM pg_stat_bgwriter;
```

**Key indicators:**
- `checkpoints_req` >> `checkpoints_timed`: Checkpoints happening too frequently (WAL filling up before `checkpoint_timeout`)
- `buffers_backend` >> `buffers_clean` + `buffers_checkpoint`: Backends forced to write dirty pages themselves (bgwriter not keeping up)

```sql
-- Check checkpoint frequency in logs
-- Enable in postgresql.conf:
-- log_checkpoints = on
-- Logs: "checkpoint complete: wrote X buffers (Y%); ... distance=Z"
```

### Tuning

```
# postgresql.conf — Spread checkpoint I/O over time

# Increase WAL size to reduce checkpoint frequency
max_wal_size = '4GB'              # default 1GB; increase for write-heavy workloads
min_wal_size = '1GB'              # default 80MB

# Spread checkpoint writes over 90% of the checkpoint interval
checkpoint_completion_target = 0.9  # default 0.9 (already optimal in PG 14+)

# Increase checkpoint interval
checkpoint_timeout = '15min'       # default 5min; 15-30min for write-heavy

# Background writer should clean dirty pages proactively
bgwriter_lru_maxpages = 200        # default 100
bgwriter_lru_multiplier = 4.0      # default 2.0
bgwriter_delay = '50ms'            # default 200ms; more frequent passes
```

### WAL Write Storms

Bulk operations (large DELETEs, bulk INSERTs, `CREATE INDEX`) generate massive WAL volume, triggering forced checkpoints.

**Mitigation:**
```sql
-- For bulk operations, disable WAL archiving temporarily (if acceptable)
-- Or use unlogged tables for staging data
CREATE UNLOGGED TABLE staging_data AS SELECT ...;

-- For CREATE INDEX, use CONCURRENTLY to spread WAL over time
CREATE INDEX CONCURRENTLY idx_new ON large_table (column);

-- Batch large DELETEs to spread WAL
DELETE FROM large_table WHERE id IN (
    SELECT id FROM large_table WHERE condition LIMIT 10000
);
-- Repeat in a loop with brief pauses
```

---

## OOM Killer Interaction on Linux

The Linux OOM killer can terminate PostgreSQL processes when the system runs out of memory.

### Diagnosis

```bash
# Check if OOM killer struck
dmesg | grep -i "out of memory"
dmesg | grep -i "killed process"

# Check PostgreSQL logs for unexpected restarts
grep -i "server process.*was terminated by signal 9" /var/log/postgresql/*.log
```

### Prevention

#### 1. Disable Memory Overcommit

```bash
# /etc/sysctl.conf
vm.overcommit_memory = 2        # don't overcommit; only allocate what's available
vm.overcommit_ratio = 80        # allow allocation of 80% of RAM + swap

# Apply immediately
sysctl -p
```

| vm.overcommit_memory | Behavior |
|---------------------|----------|
| 0 (default) | Heuristic overcommit — kernel guesses if there's enough memory |
| 1 | Always overcommit — never say no (dangerous) |
| 2 | Strict — commit limit = swap + RAM × overcommit_ratio |

**Recommendation:** `vm.overcommit_memory = 2` prevents the OOM killer from ever being invoked, but PostgreSQL will get "out of memory" errors instead. This is recoverable; OOM kills are not.

#### 2. Protect PostgreSQL from OOM Killer

```bash
# Find the postmaster PID
PG_PID=$(head -1 /var/lib/postgresql/data/postmaster.pid)

# Set OOM score adjustment (-1000 = never kill, 0 = default, +1000 = kill first)
echo -1000 > /proc/$PG_PID/oom_score_adj

# For systemd-managed PostgreSQL (persistent across restarts)
# In /lib/systemd/system/postgresql.service or override:
[Service]
OOMScoreAdjust=-1000
```

#### 3. Right-Size PostgreSQL Memory

```
# Total PostgreSQL memory budget should leave ~25% for OS cache + other processes
shared_buffers = '8GB'                  # ~25% of RAM for dedicated DB servers
effective_cache_size = '24GB'           # 75% of RAM (shared_buffers + OS cache estimate)
work_mem = '64MB'                       # per-sort/hash; max_connections × this × parallel ops
maintenance_work_mem = '2GB'            # for VACUUM, CREATE INDEX
max_connections × work_mem < available RAM  # critical constraint
```

**Common OOM scenarios:**
- `work_mem` too high + many connections = memory explosion
- Many parallel workers each allocating `work_mem`
- Large `maintenance_work_mem` during concurrent VACUUM/INDEX operations
- Connection surge without PgBouncer

---

## Too Many Connections

"FATAL: too many connections for role" or "sorry, too many clients already"

### Diagnosis Beyond PgBouncer

```sql
-- Current connection count vs limit
SELECT count(*) AS current_connections,
       (SELECT setting::int FROM pg_settings WHERE name = 'max_connections') AS max_connections
FROM pg_stat_activity;

-- Connections by state
SELECT state, count(*)
FROM pg_stat_activity
GROUP BY state
ORDER BY count(*) DESC;

-- Connections by application/user
SELECT usename, application_name, client_addr, count(*)
FROM pg_stat_activity
GROUP BY usename, application_name, client_addr
ORDER BY count(*) DESC;

-- Connections by wait event (what are they doing?)
SELECT wait_event_type, wait_event, count(*)
FROM pg_stat_activity
WHERE state != 'idle'
GROUP BY wait_event_type, wait_event
ORDER BY count(*) DESC;
```

### Common Causes and Fixes

**1. Idle connections hogging slots:**
```sql
-- Find long-idle connections
SELECT pid, usename, application_name, state, state_change,
       now() - state_change AS idle_duration
FROM pg_stat_activity
WHERE state = 'idle'
AND now() - state_change > interval '10 minutes'
ORDER BY state_change;

-- Set idle connection timeout (PG 14+)
ALTER SYSTEM SET idle_session_timeout = '10min';
SELECT pg_reload_conf();
```

**2. "Idle in transaction" connections:**
```sql
-- These hold locks and prevent VACUUM
SELECT pid, usename, state, now() - xact_start AS xact_duration, query
FROM pg_stat_activity
WHERE state = 'idle in transaction'
ORDER BY xact_start;

-- Set timeout for abandoned transactions
ALTER SYSTEM SET idle_in_transaction_session_timeout = '5min';
SELECT pg_reload_conf();
```

**3. Connection leak in application code:**
```sql
-- Track connections over time
SELECT date_trunc('minute', backend_start) AS minute, count(*)
FROM pg_stat_activity
GROUP BY 1
ORDER BY 1 DESC
LIMIT 60;
```

If connections only grow and never drop, the application is leaking. Fix in application code.

**4. Connection pooling not configured:**

Every framework/app server maintains its own pool. Without a centralized pooler, 10 app servers × 20 connections = 200 backend connections.

**Solution:** PgBouncer or pgcat in front of PostgreSQL:
```
max_connections (PostgreSQL) = 100-200 (with pooler)
Pool size (PgBouncer) = max_connections - reserved_connections - superuser_connections
App server pools each connect to PgBouncer (can have 1000+ app-side connections)
```

**5. Superuser reserved connections:**
```sql
-- Always reserve connections for emergency admin access
ALTER SYSTEM SET superuser_reserved_connections = 5;  -- default is 3
-- In PG 16+: reserved_connections for non-superuser reserved connections
```

---

## Long-Running Transaction Detection and Kill

Long transactions prevent VACUUM from reclaiming dead tuples, hold locks, and cause bloat.

### Detection

```sql
-- Find long-running transactions
SELECT pid, usename, application_name, client_addr,
       now() - xact_start AS xact_duration,
       now() - query_start AS query_duration,
       state,
       LEFT(query, 200) AS query_preview
FROM pg_stat_activity
WHERE xact_start IS NOT NULL
AND now() - xact_start > interval '5 minutes'
ORDER BY xact_start;

-- Check if long transactions are blocking VACUUM
SELECT pid, usename,
       now() - xact_start AS xact_duration,
       backend_xmin,
       age(backend_xmin) AS xmin_age
FROM pg_stat_activity
WHERE backend_xmin IS NOT NULL
ORDER BY age(backend_xmin) DESC;
```

**`backend_xmin`** is the oldest transaction ID visible to this backend. If it's very old, VACUUM cannot freeze or remove tuples newer than this XID.

### Safe Kill Procedures

```sql
-- Step 1: Try graceful cancellation (cancels current query, not the session)
SELECT pg_cancel_backend(pid);

-- Step 2: Wait a few seconds. If still running, terminate the session
SELECT pg_terminate_backend(pid);

-- Step 3: For truly stuck backends (rare), OS-level kill
-- Find the process and send SIGTERM
-- sudo kill -15 <pid>
-- Last resort: SIGKILL (may require crash recovery)
-- sudo kill -9 <pid>
```

**Batch terminate idle-in-transaction sessions:**
```sql
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE state = 'idle in transaction'
AND now() - state_change > interval '30 minutes'
AND pid != pg_backend_pid();  -- don't kill yourself
```

### Prevention

```sql
-- Auto-kill idle-in-transaction sessions
ALTER SYSTEM SET idle_in_transaction_session_timeout = '5min';

-- Per-user timeout for batch jobs
ALTER USER batch_user SET statement_timeout = '30min';

-- Application-level: set statement_timeout per query class
SET statement_timeout = '10s';
SELECT ...; -- will be cancelled if it takes more than 10s
RESET statement_timeout;
```

---

## pg_stat_activity Interpretation

`pg_stat_activity` is the primary view for real-time session diagnostics.

### Key Columns

| Column | What It Tells You |
|--------|------------------|
| `pid` | Backend process ID (for `pg_cancel_backend` / `pg_terminate_backend`) |
| `datname` | Database this backend is connected to |
| `usename` | Connected user |
| `application_name` | Application identifier (set by client) |
| `client_addr` | Client IP address |
| `backend_start` | When this connection was established |
| `xact_start` | When the current transaction started (NULL if no active transaction) |
| `query_start` | When the current/last query started |
| `state_change` | When `state` last changed |
| `state` | Current state (see below) |
| `wait_event_type` | Category of wait event (NULL if not waiting) |
| `wait_event` | Specific wait event |
| `query` | Text of the current/last query |
| `backend_xid` | Transaction ID if the backend has written data |
| `backend_xmin` | Oldest visible transaction horizon for this backend |

### State Values

| State | Meaning | Concern? |
|-------|---------|----------|
| `active` | Executing a query right now | Normal |
| `idle` | Connected but not in a transaction | Normal if brief; leak if persistent |
| `idle in transaction` | In an open transaction but not executing | **Dangerous** — holds locks, blocks VACUUM |
| `idle in transaction (aborted)` | Transaction errored but not rolled back | **Fix immediately** — needs ROLLBACK |
| `fastpath function call` | Executing a fast-path function | Rare, normal |
| `disabled` | `track_activities` is off | Turn it on |

### Wait Event Types

| Wait Event Type | Meaning | Common Events |
|----------------|---------|---------------|
| `LWLock` | Lightweight lock contention | `buffer_mapping`, `WALWrite`, `lock_manager` |
| `Lock` | Heavyweight lock wait | `relation`, `transactionid`, `tuple` |
| `BufferPin` | Waiting for buffer pin | Buffer contention |
| `Activity` | Background worker waiting | `WalSenderMain`, `AutoVacuumMain` |
| `Client` | Waiting for client | `ClientRead` (idle connections) |
| `IO` | Waiting for I/O | `DataFileRead`, `WALSync`, `WALWrite` |
| `IPC` | Inter-process communication | `MessageQueueSend`, `ParallelFinish` |

### Common Diagnostic Patterns

**Find what's blocking what:**
```sql
SELECT blocked.pid AS blocked_pid,
       blocked.query AS blocked_query,
       blocking.pid AS blocking_pid,
       blocking.query AS blocking_query,
       blocking.state AS blocking_state
FROM pg_stat_activity blocked
JOIN pg_locks bl ON bl.pid = blocked.pid AND NOT bl.granted
JOIN pg_locks gl ON gl.pid != blocked.pid
    AND gl.locktype = bl.locktype
    AND gl.database IS NOT DISTINCT FROM bl.database
    AND gl.relation IS NOT DISTINCT FROM bl.relation
    AND gl.page IS NOT DISTINCT FROM bl.page
    AND gl.tuple IS NOT DISTINCT FROM bl.tuple
    AND gl.granted
JOIN pg_stat_activity blocking ON blocking.pid = gl.pid;
```

**Active queries sorted by duration:**
```sql
SELECT pid, now() - query_start AS duration, state, LEFT(query, 100) AS query
FROM pg_stat_activity
WHERE state = 'active' AND pid != pg_backend_pid()
ORDER BY query_start;
```

---

## Index Bloat Detection and Reindexing

B-tree indexes accumulate bloat over time as pages are split but never merged (except in PG 17+ which has bottom-up deletion improvements).

### Detection

```sql
-- Using pgstattuple extension
CREATE EXTENSION IF NOT EXISTS pgstattuple;

SELECT indexrelname,
       pg_size_pretty(pg_relation_size(indexrelid)) AS index_size,
       idx_scan,
       (pgstatindex(indexrelid::regclass)).leaf_fragmentation AS fragmentation_pct,
       (pgstatindex(indexrelid::regclass)).avg_leaf_density AS density_pct
FROM pg_stat_user_indexes
JOIN pg_index USING (indexrelid)
WHERE pg_relation_size(indexrelid) > 1024 * 1024  -- > 1MB
ORDER BY pg_relation_size(indexrelid) DESC;
```

**Thresholds:**
| Metric | Healthy | Investigate | Reindex |
|--------|---------|-------------|---------|
| `leaf_fragmentation` | < 10% | 10-30% | > 30% |
| `avg_leaf_density` | > 70% | 50-70% | < 50% |

### Heuristic Bloat Estimate Without Extensions

```sql
-- Compare actual index size to estimated minimal size
SELECT
    schemaname || '.' || indexrelname AS index,
    pg_size_pretty(pg_relation_size(indexrelid)) AS actual_size,
    pg_size_pretty(
        pg_relation_size(indrelid) * (SELECT count(*) FROM pg_attribute
            WHERE attrelid = indrelid AND attnum = ANY(indkey))::float
        / GREATEST(1, array_length(indkey, 1) * 8.0)
    ) AS estimated_min,
    idx_scan
FROM pg_stat_user_indexes
JOIN pg_index USING (indexrelid)
WHERE pg_relation_size(indexrelid) > 10 * 1024 * 1024  -- > 10MB
ORDER BY pg_relation_size(indexrelid) DESC;
```

### REINDEX Strategies

#### REINDEX (blocking)
```sql
-- Takes a lock on the table; blocks writes
REINDEX INDEX idx_orders_customer_id;
REINDEX TABLE orders;
```

#### REINDEX CONCURRENTLY (PG 12+, online)
```sql
-- Does not block reads or writes; builds new index in background
REINDEX INDEX CONCURRENTLY idx_orders_customer_id;
REINDEX TABLE CONCURRENTLY orders;
```

**REINDEX CONCURRENTLY caveats:**
- Uses more disk space (builds new index before dropping old)
- Takes longer than regular REINDEX
- Cannot run inside a transaction block
- Leaves invalid indexes if it fails (check `pg_index.indisvalid`)

```sql
-- Check for invalid indexes left by failed REINDEX CONCURRENTLY
SELECT indexrelid::regclass, indisvalid, indisready
FROM pg_index
WHERE NOT indisvalid;

-- Drop and recreate invalid indexes
DROP INDEX CONCURRENTLY idx_invalid_index;
CREATE INDEX CONCURRENTLY idx_new_index ON table (...);
```

#### pg_repack for Indexes

```bash
# Repack a specific index online
pg_repack -d mydb -i idx_orders_customer_id

# Repack all indexes on a table
pg_repack -d mydb -t orders --only-indexes
```

### When to Reindex

- After massive DELETE operations (e.g., purging old data)
- After significant UPDATE storms on indexed columns
- When `pg_stat_user_indexes.idx_scan` is high but query performance has degraded
- When index size is >2-3× the estimated minimal size
- Periodically (e.g., weekly) for very write-heavy tables
