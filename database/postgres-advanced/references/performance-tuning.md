# PostgreSQL Performance Tuning Guide

## Table of Contents

- [Memory Configuration](#memory-configuration)
  - [shared_buffers](#shared_buffers)
  - [work_mem](#work_mem)
  - [effective_cache_size](#effective_cache_size)
  - [maintenance_work_mem](#maintenance_work_mem)
  - [wal_buffers](#wal_buffers)
  - [Memory Sizing Reference Table](#memory-sizing-reference-table)
- [Connection Pooling (PgBouncer)](#connection-pooling-pgbouncer)
  - [Pool Modes](#pool-modes)
  - [Configuration Guide](#configuration-guide)
  - [Monitoring PgBouncer](#monitoring-pgbouncer)
- [Autovacuum Tuning](#autovacuum-tuning)
  - [Global Settings](#global-settings)
  - [Per-Table Tuning](#per-table-tuning)
  - [Monitoring Autovacuum](#monitoring-autovacuum)
- [Checkpoint Tuning](#checkpoint-tuning)
- [Query Planner Settings](#query-planner-settings)
- [WAL Configuration](#wal-configuration)
- [OS-Level Tuning](#os-level-tuning)
  - [Huge Pages](#huge-pages)
  - [vm.overcommit](#vmovercommit)
  - [I/O Scheduler and Filesystem](#io-scheduler-and-filesystem)
  - [Network Tuning](#network-tuning)

---

## Memory Configuration

### shared_buffers

PostgreSQL's main in-memory cache for table and index data blocks.

**Sizing guidelines:**
- **Starting point:** 25% of total system RAM on a dedicated database server
- **Maximum practical:** Rarely beneficial beyond 8-16GB due to OS double-buffering
- **Minimum:** 256MB for any production system

**Why not more?** PostgreSQL relies on the OS page cache for reads beyond shared_buffers.
Allocating too much starves the OS cache and can hurt overall performance.

```
# postgresql.conf examples
# 16GB RAM server:
shared_buffers = 4GB

# 64GB RAM server:
shared_buffers = 16GB

# 256GB RAM server:
shared_buffers = 16GB    # diminishing returns beyond this
```

**Verify effectiveness:**
```sql
-- Cache hit ratio (should be > 99% for OLTP)
SELECT
    sum(blks_hit) AS cache_hits,
    sum(blks_read) AS disk_reads,
    round(sum(blks_hit)::numeric / NULLIF(sum(blks_hit) + sum(blks_read), 0) * 100, 2)
        AS hit_ratio
FROM pg_stat_database;
```

### work_mem

Memory allocated **per sort/hash operation per query**. A single complex query
can use `work_mem` multiple times (one per sort node, hash join, etc.).

**Sizing guidelines:**
- **OLTP (web apps):** 4MB - 16MB
- **OLAP (analytics):** 32MB - 256MB
- **Mixed workload:** 8MB - 32MB globally, increase per-session for analytics

**Calculate safe maximum:**
```
safe_work_mem = (Available RAM - shared_buffers - OS_reserve) /
                (max_active_connections × avg_sorts_per_query)
```

```
# postgresql.conf
work_mem = 16MB                    # global default

# Per-session override for analytics:
# SET work_mem = '256MB';
```

**Detect when work_mem is too low:**
```sql
-- Queries spilling to temp files
SELECT
    LEFT(query, 80) AS query,
    temp_blks_written,
    calls,
    round(mean_exec_time::numeric, 2) AS mean_ms
FROM pg_stat_statements
WHERE temp_blks_written > 0
ORDER BY temp_blks_written DESC
LIMIT 10;

-- In EXPLAIN output, look for:
-- "Sort Method: external merge Disk: 1234kB" → work_mem too low
-- "Hash Batches: 4" → hash join spilling to disk
```

### effective_cache_size

**Not an allocation** — it's a planner hint telling PostgreSQL how much memory
is available for caching (shared_buffers + OS page cache).

**Sizing:** 50-75% of total RAM.

```
# 64GB RAM server with shared_buffers = 16GB:
effective_cache_size = 48GB        # ~75% of RAM

# Conservative estimate:
effective_cache_size = 32GB        # ~50% of RAM
```

**Impact:** Higher values make the planner prefer index scans over sequential scans.
Too low → unnecessary sequential scans on large tables.

### maintenance_work_mem

Memory for VACUUM, CREATE INDEX, ALTER TABLE ADD FOREIGN KEY, and similar operations.

**Sizing:** 512MB - 2GB (only one operation uses this at a time per autovacuum worker).

```
# postgresql.conf
maintenance_work_mem = 1GB

# For very large tables, increase temporarily:
# SET maintenance_work_mem = '4GB';
# CREATE INDEX CONCURRENTLY ...;
```

**Note:** Total maintenance memory = `maintenance_work_mem × autovacuum_max_workers`.
With 6 workers and 1GB each, that's 6GB reserved for maintenance.

### wal_buffers

Buffer for WAL data before writing to disk.

```
# Usually auto-tuned (1/32 of shared_buffers, max 64MB)
wal_buffers = -1                   # auto-tune (recommended)

# Manual override for very high write throughput:
wal_buffers = 64MB
```

### Memory Sizing Reference Table

| Server RAM | shared_buffers | work_mem | effective_cache_size | maintenance_work_mem |
|------------|---------------|----------|---------------------|---------------------|
| 4GB        | 1GB           | 4MB      | 3GB                 | 256MB               |
| 16GB       | 4GB           | 8MB      | 12GB                | 512MB               |
| 32GB       | 8GB           | 16MB     | 24GB                | 1GB                 |
| 64GB       | 16GB          | 16MB     | 48GB                | 1GB                 |
| 128GB      | 16GB          | 32MB     | 96GB                | 2GB                 |
| 256GB      | 16GB          | 32MB     | 192GB               | 2GB                 |

These are starting points — always benchmark with your actual workload.

---

## Connection Pooling (PgBouncer)

### Pool Modes

| Mode | Description | Restrictions | Use Case |
|------|-------------|-------------|----------|
| **session** | Connection held for entire client session | None | Legacy apps, session features |
| **transaction** | Connection held only during transaction | No prepared statements*, no session vars, no advisory locks, no temp tables | Web apps, microservices |
| **statement** | Connection returned after each statement | No multi-statement transactions | Simple read-only queries |

*PgBouncer 1.21+ supports prepared statement forwarding with `max_prepared_statements > 0`.

### Configuration Guide

```ini
; /etc/pgbouncer/pgbouncer.ini

[databases]
; database = connection_string
myapp = host=127.0.0.1 port=5432 dbname=myapp
myapp_ro = host=replica.internal port=5432 dbname=myapp

[pgbouncer]
; --- Connection Settings ---
listen_addr = 0.0.0.0
listen_port = 6432
auth_type = scram-sha-256
auth_file = /etc/pgbouncer/userlist.txt

; --- Pool Mode ---
pool_mode = transaction

; --- Pool Sizing ---
; max_client_conn = maximum simultaneous client connections to PgBouncer
max_client_conn = 1000

; default_pool_size = server connections per user/database pair
; Total PG connections ≈ default_pool_size × number_of_pools
default_pool_size = 25

; reserve_pool_size = extra connections for burst handling
reserve_pool_size = 5
reserve_pool_timeout = 3

; min_pool_size = keep this many connections open even when idle
min_pool_size = 5

; --- Timeouts ---
server_idle_timeout = 300
client_idle_timeout = 0
query_timeout = 0
client_login_timeout = 60

; --- Connection Reset ---
server_reset_query = DISCARD ALL

; --- Logging ---
log_connections = 1
log_disconnections = 1
log_pooler_errors = 1
stats_period = 60

; --- TLS (production) ---
; client_tls_sslmode = require
; client_tls_key_file = /etc/pgbouncer/server.key
; client_tls_cert_file = /etc/pgbouncer/server.crt
```

**Sizing formula:**
```
default_pool_size = max_connections / number_of_application_instances
                    (leave 10-20% headroom for admin/monitoring)
```

### Monitoring PgBouncer

```sql
-- Connect to PgBouncer admin console
-- psql -h 127.0.0.1 -p 6432 -U pgbouncer pgbouncer

SHOW POOLS;     -- active, waiting, server connections per pool
SHOW STATS;     -- queries/sec, bytes, timing
SHOW CLIENTS;   -- connected clients
SHOW SERVERS;   -- backend connections
SHOW CONFIG;    -- current configuration
```

**Key metrics to watch:**
- `cl_waiting > 0` for extended periods → increase pool size
- `sv_active` consistently equals `default_pool_size` → pool saturated
- `avg_query_time` increasing → backend performance issue

---

## Autovacuum Tuning

### Global Settings

```
# postgresql.conf

# --- Worker Configuration ---
autovacuum_max_workers = 6          # default: 3 (increase for many tables)
autovacuum_naptime = 30s            # default: 1min (how often to check)

# --- Thresholds ---
# vacuum triggers when: dead_tuples > threshold + scale_factor * live_tuples
autovacuum_vacuum_threshold = 50           # default: 50
autovacuum_vacuum_scale_factor = 0.1       # default: 0.2 (10% vs 20%)
autovacuum_analyze_threshold = 50          # default: 50
autovacuum_analyze_scale_factor = 0.05     # default: 0.1

# --- I/O Throttling ---
autovacuum_vacuum_cost_delay = 2ms         # default: 2ms (PG12+)
autovacuum_vacuum_cost_limit = 800         # default: -1 (uses vacuum_cost_limit=200)

# --- Freeze Settings ---
autovacuum_freeze_max_age = 200000000      # default: 200M
vacuum_freeze_min_age = 50000000           # default: 50M
vacuum_freeze_table_age = 150000000        # default: 150M

# --- Memory ---
maintenance_work_mem = 1GB                 # speeds up vacuum on large tables
```

### Per-Table Tuning

```sql
-- High-write table: vacuum more aggressively
ALTER TABLE high_write_table SET (
    autovacuum_vacuum_scale_factor = 0.01,      -- 1% dead rows
    autovacuum_vacuum_threshold = 1000,
    autovacuum_vacuum_cost_delay = 0,            -- no throttling
    autovacuum_vacuum_cost_limit = 2000,
    autovacuum_analyze_scale_factor = 0.005
);

-- Large, mostly-read table: vacuum less often
ALTER TABLE large_reference_table SET (
    autovacuum_vacuum_scale_factor = 0.05,
    autovacuum_vacuum_cost_delay = 10            -- gentler I/O
);

-- Table with frequent bulk operations
ALTER TABLE staging_table SET (
    autovacuum_enabled = false                   -- manual vacuum after bulk loads
);
-- IMPORTANT: Always re-enable or manually vacuum!
```

### Monitoring Autovacuum

```sql
-- Currently running autovacuum workers
SELECT pid, datname, relid::regclass AS table_name,
       phase, heap_blks_total, heap_blks_scanned, heap_blks_vacuumed,
       index_vacuum_count, max_dead_tuples, num_dead_tuples
FROM pg_stat_progress_vacuum;

-- Tables overdue for vacuum
SELECT schemaname, relname,
       n_dead_tup, n_live_tup,
       round(n_dead_tup::numeric / GREATEST(n_live_tup, 1) * 100, 2) AS dead_pct,
       last_autovacuum,
       age(now(), last_autovacuum) AS since_last_vacuum
FROM pg_stat_user_tables
WHERE n_dead_tup > 10000
ORDER BY n_dead_tup DESC;
```

---

## Checkpoint Tuning

Checkpoints flush dirty buffers to disk. Too frequent = I/O spikes. Too infrequent = long recovery.

```
# postgresql.conf

# --- Checkpoint Frequency ---
max_wal_size = 4GB                 # default: 1GB (trigger checkpoint at this WAL size)
min_wal_size = 1GB                 # default: 80MB (reclaim WAL below this)
checkpoint_timeout = 15min         # default: 5min (max time between checkpoints)

# --- Checkpoint Spread ---
checkpoint_completion_target = 0.9 # default: 0.9 (spread I/O over 90% of interval)

# --- Logging ---
log_checkpoints = on               # always enable — shows checkpoint stats
checkpoint_warning = 30s           # warn if checkpoints are too frequent
```

**Monitor checkpoint behavior:**
```sql
SELECT
    checkpoints_timed,     -- scheduled checkpoints
    checkpoints_req,       -- forced checkpoints (WAL size exceeded)
    buffers_checkpoint,    -- buffers written during checkpoints
    buffers_clean,         -- buffers written by background writer
    buffers_backend,       -- buffers written by backends (BAD if high)
    maxwritten_clean       -- background writer stopped due to limit
FROM pg_stat_bgwriter;
```

**Warning signs:**
- `checkpoints_req >> checkpoints_timed` → increase `max_wal_size`
- `buffers_backend` is high → increase `shared_buffers` or tune bgwriter
- Frequent `checkpoint_warning` messages → checkpoints happening too often

---

## Query Planner Settings

```
# postgresql.conf — adjust with caution

# --- Cost Model ---
random_page_cost = 1.1             # default: 4.0 (reduce for SSDs, 1.0-1.5)
seq_page_cost = 1.0                # default: 1.0 (baseline)
cpu_tuple_cost = 0.01              # default: 0.01
cpu_index_tuple_cost = 0.005       # default: 0.005
cpu_operator_cost = 0.0025         # default: 0.0025

# For SSD-only systems:
# random_page_cost = 1.1           # nearly equal to seq since no seek penalty
# effective_io_concurrency = 200   # default: 1 (set higher for SSDs)

# --- Parallelism ---
max_parallel_workers_per_gather = 4     # default: 2
max_parallel_workers = 8                 # default: 8
max_parallel_maintenance_workers = 4     # default: 2 (for CREATE INDEX, VACUUM)
parallel_tuple_cost = 0.01              # default: 0.1 (lower = more parallelism)
min_parallel_table_scan_size = 8MB      # default: 8MB
min_parallel_index_scan_size = 512kB    # default: 512kB

# --- Statistics ---
default_statistics_target = 200         # default: 100 (higher = better estimates, slower ANALYZE)
# Per-column: ALTER TABLE t ALTER COLUMN c SET STATISTICS 1000;

# --- Join/Aggregation ---
enable_hashjoin = on
enable_mergejoin = on
enable_nestloop = on
# NEVER disable join types globally — use per-query hints or fix indexes
```

**SSD tuning checklist:**
```sql
ALTER SYSTEM SET random_page_cost = 1.1;
ALTER SYSTEM SET effective_io_concurrency = 200;
ALTER SYSTEM SET maintenance_io_concurrency = 200;  -- PG13+
SELECT pg_reload_conf();
```

---

## WAL Configuration

```
# postgresql.conf

# --- WAL Level ---
wal_level = replica                # 'logical' if using logical replication
max_wal_senders = 10               # connections for streaming replication
max_replication_slots = 10

# --- WAL Size ---
max_wal_size = 4GB                 # max WAL before forced checkpoint
min_wal_size = 1GB                 # keep at least this much WAL

# --- WAL Compression ---
wal_compression = lz4              # PG15+: reduce WAL I/O (options: pglz, lz4, zstd)

# --- Synchronous Commit ---
synchronous_commit = on            # 'off' for ~3x write throughput if you can tolerate
                                   # up to ~600ms of data loss on crash

# --- Full Page Writes ---
full_page_writes = on              # NEVER disable (data corruption risk)

# --- WAL Archiving ---
archive_mode = on
archive_command = 'cp %p /archive/%f'    # or use pgBackRest/WAL-G
```

---

## OS-Level Tuning

### Huge Pages

Reduces TLB misses and page table overhead for large shared_buffers allocations.

```bash
# 1. Calculate required huge pages
# shared_buffers = 16GB, huge page size = 2MB
# Required pages = (16GB / 2MB) + small margin
# = 8192 + 100 = 8292

# Or calculate dynamically:
head -1 /proc/meminfo    # MemTotal
grep Hugepagesize /proc/meminfo   # typically 2048 kB

# 2. Set in /etc/sysctl.conf
vm.nr_hugepages = 8300

# 3. Apply
sysctl -p

# 4. Enable in postgresql.conf
# huge_pages = on         # 'on' = require, 'try' = use if available
```

```
# postgresql.conf
huge_pages = try                   # 'on' to require (fails if not available)
```

### vm.overcommit

Prevents the Linux OOM killer from targeting PostgreSQL.

```bash
# /etc/sysctl.conf

# Option 1: Never overcommit (strictest, safest for databases)
vm.overcommit_memory = 2
vm.overcommit_ratio = 80           # allow commit up to 80% of RAM + swap

# Option 2: Use default heuristic with OOM score adjustment
vm.overcommit_memory = 0
# Then protect postgres process from OOM killer:
# echo -1000 > /proc/$(cat /var/run/postgresql/postmaster.pid | head -1)/oom_score_adj
```

### I/O Scheduler and Filesystem

```bash
# Use 'none' (noop) scheduler for SSDs, 'mq-deadline' for HDDs
echo none > /sys/block/sda/queue/scheduler

# Filesystem mount options for ext4
# /etc/fstab entry:
# /dev/sda1 /pgdata ext4 defaults,noatime,nobarrier 0 2
# noatime: don't update access time metadata (significant IOPS savings)
# nobarrier: only if using battery-backed write cache

# For XFS (recommended for PostgreSQL):
# /dev/sda1 /pgdata xfs defaults,noatime,logbufs=8 0 2
```

```
# postgresql.conf — match to your I/O
effective_io_concurrency = 200     # for SSDs (default: 1)
maintenance_io_concurrency = 200   # PG13+
```

### Network Tuning

```bash
# /etc/sysctl.conf — for high-connection servers

# Increase connection backlog
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096

# TCP keepalive (detect dead connections faster)
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6

# Increase local port range
net.ipv4.ip_local_port_range = 1024 65535
```

```
# postgresql.conf — TCP keepalive
tcp_keepalives_idle = 60
tcp_keepalives_interval = 10
tcp_keepalives_count = 6
```

---

## Quick Tuning Checklist

1. **Set shared_buffers** to 25% of RAM (max ~16GB)
2. **Set effective_cache_size** to 75% of RAM
3. **Set work_mem** based on: (RAM - shared_buffers) / (max_connections × 3)
4. **Set maintenance_work_mem** to 1-2GB
5. **Set random_page_cost** to 1.1 for SSDs
6. **Enable huge_pages** if shared_buffers > 8GB
7. **Tune checkpoints**: max_wal_size=4GB, checkpoint_completion_target=0.9
8. **Tune autovacuum**: increase workers, lower scale_factor for large tables
9. **Use PgBouncer** for connection pooling
10. **Set vm.overcommit_memory=2** to prevent OOM killer
11. **Monitor**: pg_stat_statements, pg_stat_bgwriter, pg_stat_user_tables
