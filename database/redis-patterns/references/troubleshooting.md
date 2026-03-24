# Redis Troubleshooting Guide

Comprehensive guide to diagnosing and resolving Redis production issues: slow commands,
memory problems, replication lag, cluster issues, and persistence failures.

---

## Table of Contents

1. [Slow Command Diagnosis](#slow-command-diagnosis)
   - [SLOWLOG](#slowlog)
   - [Latency Monitoring](#latency-monitoring)
   - [LATENCY DOCTOR](#latency-doctor)
   - [Common Slow Command Patterns](#common-slow-command-patterns)
2. [Memory Issues](#memory-issues)
   - [Memory Fragmentation](#memory-fragmentation)
   - [Big Key Detection](#big-key-detection)
   - [Hot Key Detection](#hot-key-detection)
   - [MEMORY DOCTOR](#memory-doctor)
   - [Memory Usage Analysis](#memory-usage-analysis)
3. [Connection Issues](#connection-issues)
   - [maxclients Exhaustion](#maxclients-exhaustion)
   - [Timeout Configuration](#timeout-configuration)
   - [Connection Debugging](#connection-debugging)
4. [Replication Issues](#replication-issues)
   - [Replication Lag](#replication-lag)
   - [Full Resync Storms](#full-resync-storms)
   - [Replication Buffer Overflow](#replication-buffer-overflow)
5. [Cluster Issues](#cluster-issues)
   - [Split-Brain Scenarios](#split-brain-scenarios)
   - [Slot Migration Problems](#slot-migration-problems)
   - [CLUSTER INFO Diagnostics](#cluster-info-diagnostics)
6. [Persistence Issues](#persistence-issues)
   - [AOF Rewrite Problems](#aof-rewrite-problems)
   - [RDB Fork Failures](#rdb-fork-failures)
   - [Hybrid Persistence](#hybrid-persistence)
7. [Eviction Policy Behavior](#eviction-policy-behavior)
8. [Diagnostic Commands Reference](#diagnostic-commands-reference)

---

## Slow Command Diagnosis

### SLOWLOG

The SLOWLOG records commands exceeding a configurable execution time threshold. It measures
only server-side execution time (not network latency).

**Configuration:**
```redis
# Set threshold in microseconds (default: 10000 = 10ms)
CONFIG SET slowlog-log-slower-than 10000

# Set max log entries (default: 128)
CONFIG SET slowlog-max-len 256

# Log ALL commands (for debugging only — high overhead)
CONFIG SET slowlog-log-slower-than 0

# Disable slow log
CONFIG SET slowlog-log-slower-than -1
```

**Usage:**
```redis
# Get last N slow log entries
SLOWLOG GET 25

# Each entry contains:
# 1) Unique ID
# 2) Unix timestamp
# 3) Execution time (microseconds)
# 4) Command + arguments
# 5) Client IP:port
# 6) Client name (if set)

# Example output:
# 1) 1) (integer) 42
#    2) (integer) 1700000000
#    3) (integer) 15230          ← 15.2ms
#    4) 1) "KEYS"
#       2) "user:*"             ← problematic pattern
#    5) "10.0.0.5:52314"
#    6) "web-app-1"

# Check log length
SLOWLOG LEN

# Reset log
SLOWLOG RESET
```

**Analyzing Slow Log Entries:**
```bash
# Export slow log for analysis
redis-cli SLOWLOG GET 1000 | tee slowlog_dump.txt

# One-liner: find most common slow commands
redis-cli SLOWLOG GET 1000 | grep -oP '"[A-Z]+"' | sort | uniq -c | sort -rn
```

### Latency Monitoring

Redis has a built-in latency monitoring framework that tracks latency spikes by event type.

**Enable latency monitoring:**
```redis
# Set threshold (ms) — events exceeding this are recorded
CONFIG SET latency-monitor-threshold 5
```

**Latency commands:**
```redis
# Latest latency spike per event type
LATENCY LATEST
# Output: event_name, timestamp, latency_ms, max_latency_ms

# History for a specific event
LATENCY HISTORY command
LATENCY HISTORY fast-command
LATENCY HISTORY fork

# Reset latency data
LATENCY RESET
```

**Event types tracked:**
- `command` — slow regular commands
- `fast-command` — O(1)/O(log N) commands exceeding threshold
- `fork` — fork() for RDB/AOF (can cause latency spikes)
- `aof-fsync-always` — AOF fsync latency
- `aof-write` — AOF write latency
- `aof-rewrite-diff-write` — AOF rewrite diff writes
- `expire-cycle` — key expiration cycle
- `eviction-cycle` — eviction processing cycle
- `eviction-del` — individual eviction deletions

**CLI latency tools:**
```bash
# Continuous latency sampling (Ctrl+C to stop)
redis-cli --latency

# Latency with history (15-second intervals)
redis-cli --latency-history -i 15

# Latency distribution histogram
redis-cli --latency-dist

# Intrinsic latency test (measures system, not Redis)
redis-cli --intrinsic-latency 10    # 10-second test
```

### LATENCY DOCTOR

Automated diagnosis of latency issues:
```redis
LATENCY DOCTOR
```

Output example:
```
Dave, I have a few latency reports for you:

- command: 2 latency spikes (1ms/15ms). Worst all time event 15ms.
  Worst case latency is within acceptable range (0ms..50ms).

- fork: 1 latency spike (48ms). Worst all time event 48ms.
  I have a few suggestions:
  1. You have a big dataset (4GB). fork() can be slow.
  2. Consider using BGSAVE only during off-peak hours.
  3. Consider enabling activedefrag or restarting to reduce fragmentation.
```

### Common Slow Command Patterns

| Pattern                          | Fix                                                |
|----------------------------------|----------------------------------------------------|
| `KEYS *` or `KEYS pattern`      | Replace with `SCAN` with COUNT                     |
| `SMEMBERS` on large sets         | Use `SSCAN` for iteration                          |
| `HGETALL` on large hashes        | Use `HSCAN` or `HMGET` for specific fields         |
| `LRANGE 0 -1` on large lists     | Paginate with offset/count                         |
| `SORT` on large datasets          | Pre-sort with sorted sets                          |
| `FLUSHDB` / `FLUSHALL`           | Use `FLUSHDB ASYNC` / `FLUSHALL ASYNC`             |
| `DEL` on large keys               | Use `UNLINK` for async deletion                    |
| Long-running Lua scripts          | Break into smaller operations, use time limits     |
| `SUBSCRIBE` on busy channels      | Use consumer groups with streams                   |
| `CLUSTER NODES` frequently        | Cache results, don't call in hot paths             |

---

## Memory Issues

### Memory Fragmentation

Memory fragmentation occurs when the allocator has free memory that Redis can't use
efficiently, leading to higher RSS than expected.

**Check fragmentation ratio:**
```redis
INFO memory

# Key fields:
# used_memory: 1073741824       (memory allocated by Redis)
# used_memory_rss: 1610612736   (memory reported by OS)
# mem_fragmentation_ratio: 1.50  (rss / used — ideal: 1.0-1.5)
# mem_fragmentation_bytes: 536870912
```

**Interpreting the ratio:**
- `< 1.0` — Redis is using swap (CRITICAL — severe performance impact)
- `1.0 - 1.5` — Healthy
- `1.5 - 2.0` — Moderate fragmentation; consider active defrag
- `> 2.0` — High fragmentation; active defrag or restart needed

**Active defragmentation (Redis 4+):**
```redis
CONFIG SET activedefrag yes
CONFIG SET active-defrag-enabled yes

# Tuning thresholds
CONFIG SET active-defrag-threshold-lower 10   # start defrag at 10% fragmentation
CONFIG SET active-defrag-threshold-upper 100  # max effort at 100% fragmentation
CONFIG SET active-defrag-cycle-min 1          # min CPU % for defrag
CONFIG SET active-defrag-cycle-max 25         # max CPU % for defrag
CONFIG SET active-defrag-max-scan-fields 1000 # fields scanned per cycle
```

**When to restart instead:**
- Fragmentation ratio > 3.0 and active defrag isn't reducing it
- After major data migration or bulk deletes
- During scheduled maintenance windows

### Big Key Detection

Big keys cause latency spikes (serialization, deletion, replication) and memory issues.

**Built-in scan:**
```bash
# Scan all keys and report largest per type
redis-cli --bigkeys

# Sample output:
# [00.00%] Biggest string found so far '"cache:api:large"' with 1048576 bytes
# [25.00%] Biggest hash found so far '"user:profiles"' with 50000 fields
# [50.00%] Biggest list found so far '"queue:pending"' with 100000 items
#
# -------- summary -------
# Biggest string found '"cache:api:large"' has 1048576 bytes
# Biggest hash found '"user:profiles"' has 50000 fields
# Biggest list found '"queue:pending"' has 100000 items
```

**Manual investigation:**
```redis
# Check memory usage of specific keys
MEMORY USAGE user:profiles SAMPLES 0     # exact count (slower)
MEMORY USAGE user:profiles SAMPLES 5     # sampled estimate (faster)

# Check key type and encoding
TYPE user:profiles
OBJECT ENCODING user:profiles
OBJECT IDLETIME user:profiles

# Check collection sizes
HLEN user:profiles
LLEN queue:pending
SCARD large:set
ZCARD large:zset
XLEN stream:events
```

**Scanning for big keys programmatically:**
```bash
#!/bin/bash
# Find keys using more than 1MB
redis-cli --scan --pattern '*' | while read key; do
  size=$(redis-cli MEMORY USAGE "$key" 2>/dev/null)
  if [ -n "$size" ] && [ "$size" -gt 1048576 ]; then
    echo "$key: $size bytes"
  fi
done
```

**Remediation:**
- Split large hashes into sharded hashes: `user:profiles:{0-99}`, `user:profiles:{100-199}`
- Cap lists with `LTRIM` after push operations
- Use `UNLINK` instead of `DEL` to delete big keys asynchronously
- Set `lazyfree-lazy-expire yes`, `lazyfree-lazy-server-del yes` for automatic async cleanup

### Hot Key Detection

Hot keys receive disproportionate traffic, causing CPU bottlenecks on the hosting shard.

**Detection methods:**
```bash
# Monitor command frequency (CAUTION: high overhead, use briefly)
redis-cli MONITOR | head -10000 | awk '{print $NF}' | sort | uniq -c | sort -rn | head 20

# redis-cli with --hotkeys (requires maxmemory-policy with LFU)
redis-cli --hotkeys

# Check LFU frequency counter for specific keys
OBJECT FREQ mykey     # requires LFU policy enabled
```

**Mitigation strategies:**
- **Read replicas:** Route read traffic to replicas for hot read keys
- **Local caching:** Use client-side caching for hot read keys
- **Key sharding:** Split hot hash into multiple keys across slots
- **Rate limiting:** Throttle access to hot keys at application level

### MEMORY DOCTOR

Automated memory health analysis:
```redis
MEMORY DOCTOR
```

Output identifies issues like:
- High fragmentation requiring defragmentation
- Peak memory much higher than current (suggests bursty workload)
- RSS overhead from allocator metadata
- Suggestions for configuration changes

**Additional memory commands:**
```redis
# Detailed memory statistics
MEMORY STATS

# Memory usage of specific key with sampling
MEMORY USAGE mykey SAMPLES 5

# Purge allocator pages (jemalloc)
MEMORY PURGE

# Memory allocation report
MEMORY MALLOC-STATS
```

### Memory Usage Analysis

```redis
# Comprehensive memory overview
INFO memory

# Key metrics to monitor:
# used_memory              — total allocated by Redis
# used_memory_rss          — resident set size (OS-reported)
# used_memory_peak         — historical peak
# used_memory_dataset      — data stored (minus overhead)
# used_memory_overhead     — internal overhead (buffers, metadata)
# used_memory_lua          — Lua engine memory
# used_memory_functions    — Redis Functions memory
# maxmemory                — configured limit
# mem_fragmentation_ratio  — fragmentation indicator
# mem_allocator            — jemalloc, libc, etc.
```

**Per-database key counts:**
```redis
INFO keyspace
# db0:keys=1500000,expires=450000,avg_ttl=3600000
```

---

## Connection Issues

### maxclients Exhaustion

```redis
# Check current connections vs limit
INFO clients
# connected_clients: 4500
# maxclients: 5000
# blocked_clients: 12
# tracking_clients: 0

CONFIG GET maxclients
# "maxclients" "5000"
```

**Diagnosis:**
```redis
# List all connected clients
CLIENT LIST

# Filter by specific criteria
CLIENT LIST TYPE normal    # exclude pub/sub, replicas
CLIENT LIST ID 1 2 3      # specific client IDs

# Count by type
CLIENT INFO
```

**Common causes and fixes:**
- Connection leaks: Ensure clients use connection pooling and close connections
- Too many app instances: Size connection pools to total < maxclients
- Idle connections: Set `timeout` to auto-close idle clients
- Blocked clients: Check for long `BRPOP`/`BLPOP` with excessive timeouts

```redis
# Set idle timeout (seconds) — 0 = disabled
CONFIG SET timeout 300

# Kill specific client
CLIENT KILL ID 12345

# Kill clients by filter
CLIENT KILL MAXAGE 3600     # idle for 1+ hour
```

**OS-level limits:**
```bash
# Check file descriptor limit
ulimit -n

# Increase for Redis process
# In /etc/security/limits.conf:
# redis soft nofile 65536
# redis hard nofile 65536

# Or in systemd service file:
# [Service]
# LimitNOFILE=65536
```

### Timeout Configuration

```redis
# Client idle timeout (seconds, 0=disabled)
CONFIG SET timeout 300

# TCP keepalive (seconds, 0=disabled, recommended: 60)
CONFIG SET tcp-keepalive 60

# Cluster node timeout (ms, default: 15000)
CONFIG SET cluster-node-timeout 15000

# Replica timeout (seconds)
CONFIG SET repl-timeout 60
```

### Connection Debugging

```bash
# Test connectivity
redis-cli -h <host> -p <port> PING

# Check with TLS
redis-cli --tls --cert /path/to/cert --key /path/to/key --cacert /path/to/ca PING

# Connection latency
redis-cli -h <host> --latency

# Monitor all commands in real time (CAUTION: production impact)
redis-cli MONITOR

# Check TCP connections at OS level
ss -tnp | grep 6379 | wc -l
netstat -an | grep 6379 | awk '{print $6}' | sort | uniq -c
```

---

## Replication Issues

### Replication Lag

```redis
# On the master — check connected replicas
INFO replication
# role:master
# connected_slaves:2
# slave0:ip=10.0.0.2,port=6379,state=online,offset=123456789,lag=0
# slave1:ip=10.0.0.3,port=6379,state=online,offset=123456700,lag=1
# master_repl_offset:123456789

# On the replica
INFO replication
# role:slave
# master_link_status:up
# master_last_io_seconds_ago:0
# master_sync_in_progress:0
# slave_repl_offset:123456789
# slave_read_repl_offset:123456789
```

**Lag indicators:**
- `lag` field in master's slave info (seconds since last ACK)
- `master_repl_offset` - `slave_repl_offset` = byte lag
- `master_link_status:down` = replication broken

**Common causes:**
- Network latency between master and replica
- Replica under heavy read load (slow to apply writes)
- Large RDB transfer during full resync
- Slow disk I/O on replica
- Output buffer overflow causing disconnection

**Fixes:**
```redis
# Increase replication backlog (prevents full resync on brief disconnects)
CONFIG SET repl-backlog-size 256mb

# Increase output buffer limits for replicas
CONFIG SET client-output-buffer-limit "slave 512mb 256mb 60"

# Diskless replication (faster for slow disks)
CONFIG SET repl-diskless-sync yes
CONFIG SET repl-diskless-sync-delay 5
```

### Full Resync Storms

When multiple replicas disconnect and reconnect simultaneously, they each trigger a full
RDB transfer, overloading the master.

**Prevention:**
```redis
# Large enough backlog to absorb temporary disconnections
CONFIG SET repl-backlog-size 512mb
CONFIG SET repl-backlog-ttl 3600

# Stagger replica reconnections
CONFIG SET repl-diskless-sync-delay 10   # wait for more replicas

# Use diskless sync to avoid multiple RDB writes
CONFIG SET repl-diskless-sync yes
```

### Replication Buffer Overflow

```redis
# Check client output buffer limits
CONFIG GET client-output-buffer-limit
# "slave 256mb 64mb 60"
# Meaning: hard limit 256mb, soft limit 64mb for 60 seconds

# Monitor buffer usage
CLIENT LIST TYPE replica
# Look for omem (output buffer memory) values
```

---

## Cluster Issues

### Split-Brain Scenarios

Split-brain occurs when network partitions cause replicas to promote while the original
master is still running, resulting in two masters for the same slots.

**Detection:**
```redis
CLUSTER INFO
# cluster_state:ok              (or "fail" if partitioned)
# cluster_slots_assigned:16384
# cluster_slots_ok:16384
# cluster_known_nodes:6

CLUSTER NODES
# Look for multiple masters covering the same slots
```

**Prevention:**
```redis
# Require minimum replicas before accepting writes
CONFIG SET min-replicas-to-write 1
CONFIG SET min-replicas-max-lag 10

# Appropriate cluster-node-timeout (not too short)
CONFIG SET cluster-node-timeout 15000
```

**Recovery:**
```bash
# After partition heals, check for conflicts
redis-cli --cluster check <any-node>:6379

# Fix slot assignment issues
redis-cli --cluster fix <any-node>:6379

# Manual failover if needed (run on replica)
CLUSTER FAILOVER TAKEOVER    # force, use cautiously
```

### Slot Migration Problems

```redis
# Check for stuck migrations
CLUSTER NODES | grep -E 'migrating|importing'

# Fix stuck slot migration
CLUSTER SETSLOT <slot> STABLE    # on both source and target nodes

# Full cluster health check
redis-cli --cluster check <node>:6379

# Rebalance slots
redis-cli --cluster rebalance <node>:6379 --cluster-use-empty-masters
```

### CLUSTER INFO Diagnostics

```redis
CLUSTER INFO

# Critical fields:
# cluster_state: ok/fail
# cluster_slots_assigned: 16384         (must be 16384)
# cluster_slots_ok: 16384              (should equal assigned)
# cluster_slots_pfail: 0               (partially failing slots)
# cluster_slots_fail: 0                (failed slots)
# cluster_known_nodes: 6               (expected node count)
# cluster_size: 3                      (number of masters)
# cluster_current_epoch: 12            (config epoch)
# cluster_stats_messages_sent: 50000   (gossip messages)
# cluster_stats_messages_received: 49950
```

---

## Persistence Issues

### AOF Rewrite Problems

AOF rewrites compact the append-only file by creating a minimal set of commands to
reconstruct the current dataset.

**Common issues:**
```redis
# Check AOF status
INFO persistence
# aof_enabled: 1
# aof_rewrite_in_progress: 0
# aof_last_rewrite_status: ok
# aof_last_bgrewriteaof_status: ok
# aof_current_size: 1073741824
# aof_base_size: 536870912

# Trigger manual rewrite
BGREWRITEAOF
```

**AOF rewrite failures:**
- **Insufficient disk space:** AOF rewrite creates a temp file; need 2x current AOF space
- **fork() failure:** Insufficient memory for copy-on-write (see RDB fork section)
- **Slow disk I/O:** Rewrite takes too long, accumulates diff buffer
- **Corrupted AOF file:** Use `redis-check-aof --fix` to repair

```bash
# Check and fix corrupted AOF
redis-check-aof --fix appendonly.aof

# Verify AOF integrity
redis-check-aof appendonly.aof
```

**Tuning AOF rewrites:**
```redis
# Trigger rewrite when AOF is 100% larger than last rewrite
CONFIG SET auto-aof-rewrite-percentage 100

# Minimum AOF size before auto-rewrite triggers
CONFIG SET auto-aof-rewrite-min-size 64mb

# fsync policy
CONFIG SET appendfsync everysec          # balanced (recommended)
# CONFIG SET appendfsync always          # safest, slowest
# CONFIG SET appendfsync no              # fastest, OS decides

# Allow fsync during rewrite (reduces latency spikes)
CONFIG SET no-appendfsync-on-rewrite yes  # caution: brief durability gap
```

### RDB Fork Failures

`BGSAVE` and AOF rewrites use `fork()` to create a child process. This can fail or cause
latency spikes on large datasets.

**fork() overhead:**
- Linux copy-on-write means fork() is fast, but page table duplication scales with dataset
- ~10-20ms per GB of dataset for fork()
- Write-heavy workloads cause more CoW page copies, increasing child memory usage

**Diagnosis:**
```redis
INFO persistence
# rdb_last_bgsave_status: ok
# rdb_last_bgsave_time_sec: 12
# rdb_current_bgsave_time_sec: -1
# rdb_last_cow_size: 536870912       # CoW memory used during last save

LATENCY HISTORY fork
```

**Fixes:**
```bash
# Enable memory overcommit (CRITICAL for fork)
echo 1 > /proc/sys/vm/overcommit_memory
# Or persist in /etc/sysctl.conf:
# vm.overcommit_memory=1

# Disable THP (reduces fork latency)
echo never > /sys/kernel/mm/transparent_hugepage/enabled
```

```redis
# Use diskless RDB for replication (avoids disk I/O)
CONFIG SET repl-diskless-sync yes

# Schedule RDB saves during low-traffic periods
CONFIG SET save ""                    # disable auto RDB if using AOF
CONFIG SET save "86400 1"             # or once daily
```

### Hybrid Persistence

Combines RDB snapshot with AOF tail for fast recovery with minimal data loss:

```redis
CONFIG SET aof-use-rdb-preamble yes   # enable hybrid
CONFIG SET appendonly yes
```

**Recovery order:** Redis loads the RDB portion first (fast), then replays AOF tail (minimal).

---

## Eviction Policy Behavior

When `maxmemory` is reached, Redis applies the configured eviction policy.

### Policy Comparison

| Policy              | Scope         | Algorithm | Best For                          |
|---------------------|---------------|-----------|-----------------------------------|
| `noeviction`        | —             | —         | Primary DB (errors on write)      |
| `allkeys-lru`       | All keys      | LRU       | General-purpose cache             |
| `volatile-lru`      | Keys with TTL | LRU       | Mixed persistent + cache keys     |
| `allkeys-lfu`       | All keys      | LFU       | Frequency-based popularity cache  |
| `volatile-lfu`      | Keys with TTL | LFU       | Frequency-based with TTL keys     |
| `allkeys-random`    | All keys      | Random    | Uniform access patterns           |
| `volatile-random`   | Keys with TTL | Random    | Random eviction of expiring keys  |
| `volatile-ttl`      | Keys with TTL | Shortest  | Prefer evicting near-expiry keys  |

### Debugging Eviction

```redis
INFO stats
# evicted_keys: 50000          # total keys evicted since start
# keyspace_hits: 9000000
# keyspace_misses: 1000000

INFO memory
# used_memory: 4294967296      # at or near maxmemory
# maxmemory: 4294967296
# maxmemory_policy: allkeys-lru

# Check if eviction is currently happening
INFO stats | grep evicted
```

**Warning signs:**
- High `evicted_keys` count with increasing `keyspace_misses` = thrashing
- `used_memory` consistently at `maxmemory` = need more memory or better TTLs
- `volatile-*` policy with no TTL keys = no eviction candidates → OOM errors

**Tuning:**
```redis
# LFU tuning (Redis 4+)
CONFIG SET lfu-log-factor 10       # higher = slower frequency counter growth
CONFIG SET lfu-decay-time 1        # minutes between frequency counter decay

# Eviction sampling (higher = more accurate, slightly slower)
CONFIG SET maxmemory-samples 10    # default 5, recommended 10
```

---

## Diagnostic Commands Reference

Quick reference for essential troubleshooting commands:

```redis
# Server overview
INFO all
INFO server
INFO clients
INFO memory
INFO stats
INFO replication
INFO persistence
INFO keyspace

# Performance
SLOWLOG GET 50
LATENCY LATEST
LATENCY DOCTOR
MEMORY DOCTOR

# Memory
MEMORY USAGE <key> SAMPLES 5
MEMORY STATS
MEMORY MALLOC-STATS
MEMORY PURGE
DBSIZE

# Client management
CLIENT LIST
CLIENT INFO
CLIENT GETNAME
CLIENT KILL ID <id>
CLIENT NO-EVICT ON          # protect admin connection from eviction
CLIENT NO-TOUCH ON          # don't update LRU/LFU for admin queries

# Key inspection
TYPE <key>
OBJECT ENCODING <key>
OBJECT IDLETIME <key>
OBJECT FREQ <key>           # requires LFU policy
OBJECT HELP
DEBUG OBJECT <key>          # detailed info (debug builds)
TTL <key>
PTTL <key>

# Scanning
SCAN 0 MATCH "pattern:*" COUNT 1000 TYPE string
HSCAN key 0 COUNT 100
SSCAN key 0 COUNT 100
ZSCAN key 0 COUNT 100

# Cluster
CLUSTER INFO
CLUSTER NODES
CLUSTER SLOTS
CLUSTER KEYSLOT <key>
CLUSTER COUNTKEYSINSLOT <slot>
CLUSTER GETKEYSINSLOT <slot> <count>
```

```bash
# CLI diagnostic flags
redis-cli --bigkeys                  # scan for largest keys per type
redis-cli --memkeys                  # scan for keys using most memory
redis-cli --hotkeys                  # scan for hottest keys (LFU required)
redis-cli --latency                  # continuous latency sampling
redis-cli --latency-history -i 15    # latency with history
redis-cli --latency-dist             # latency histogram
redis-cli --intrinsic-latency 10     # system latency baseline
redis-cli --stat                     # live server stats
redis-cli --scan --pattern 'key:*'   # scan matching keys
```
