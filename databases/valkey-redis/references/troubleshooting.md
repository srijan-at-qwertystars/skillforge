# Valkey/Redis Troubleshooting Guide

## Table of Contents

- [Memory Issues](#memory-issues)
- [Slow Queries](#slow-queries)
- [Network and Timeout Problems](#network-and-timeout-problems)
- [Cluster Issues](#cluster-issues)
- [Sentinel and Split-Brain](#sentinel-and-split-brain)
- [Replication Problems](#replication-problems)
- [Persistence (AOF/RDB) Issues](#persistence-aofrdb-issues)
- [Client Connection Problems](#client-connection-problems)
- [RESP Protocol Errors](#resp-protocol-errors)
- [Lua Script Debugging](#lua-script-debugging)

---

## Memory Issues

### Diagnosing Memory Usage

```redis
INFO memory
# used_memory:1073741824          # total allocated
# used_memory_human:1.00G
# used_memory_rss:1200000000      # RSS from OS (includes fragmentation)
# mem_fragmentation_ratio:1.12    # rss/used — ideal 1.0-1.5
# used_memory_peak:2147483648     # historical peak

MEMORY DOCTOR                     # automated diagnosis
MEMORY USAGE mykey                # bytes used by specific key
DBSIZE                            # total key count
```

### maxmemory Reached

**Symptoms**: OOM errors, `OOM command not allowed when used memory > 'maxmemory'`.

**Fix**:
1. Check current policy: `CONFIG GET maxmemory-policy`
2. If `noeviction`, switch to `allkeys-lru` for caches: `CONFIG SET maxmemory-policy allkeys-lru`
3. Increase maxmemory if hardware allows: `CONFIG SET maxmemory 4gb`
4. Find and remove large/unnecessary keys (see Big Keys below)
5. Persist config: `CONFIG REWRITE`

### Memory Fragmentation

**Symptoms**: `mem_fragmentation_ratio` > 1.5 (external fragmentation) or < 1.0 (swapping).

**High fragmentation (>1.5)**:
```redis
# Enable active defragmentation (Valkey/Redis 4+)
CONFIG SET activedefrag yes
CONFIG SET active-defrag-enabled yes
CONFIG SET active-defrag-threshold-lower 10    # start when 10% fragmented
CONFIG SET active-defrag-threshold-upper 100   # max effort at 100%
CONFIG SET active-defrag-cycle-min 1           # % CPU min
CONFIG SET active-defrag-cycle-max 25          # % CPU max
```

**Low fragmentation (<1.0)**: System is swapping. Either reduce dataset or add RAM.

### Finding Big Keys

```bash
valkey-cli --bigkeys                 # non-blocking scan
valkey-cli --memkeys --memkeys-samples 100  # detailed analysis
```

**Remediation**: Split large hashes, use `UNLINK` (async delete), compress client-side, use streams with `MAXLEN`.

### Memory Leak Patterns

Check for keys without TTL growing unboundedly with `SCAN` + `TTL` to find no-TTL keys of growing types.

---

## Slow Queries

### Using SLOWLOG

```redis
# Configure slow query threshold (microseconds)
CONFIG SET slowlog-log-slower-than 10000   # 10ms
CONFIG SET slowlog-max-len 128

# View slow queries
SLOWLOG GET 10                             # last 10 slow commands
SLOWLOG LEN                                # total slow queries logged
SLOWLOG RESET                              # clear log

# Output fields: id, timestamp, duration_us, command, client_ip, client_name
```

### Common Causes and Fixes

| Cause | Command | Fix |
|-------|---------|-----|
| Full key scan | `KEYS *` | Use `SCAN` with cursor |
| Large set operations | `SMEMBERS` on 100K set | Use `SSCAN` iterator |
| Blocking saves | `BGSAVE` on large DB | Schedule during low traffic |
| Lua scripts >1ms | `EVAL` complex logic | Simplify or move to app |
| Large `SORT` | `SORT` on big list | Pre-sort or use sorted set |
| `HGETALL` on big hash | Fetching 10K+ fields | Use `HSCAN` or `HMGET` specific fields |

### Latency Monitoring

```redis
# Enable latency monitoring (threshold in ms)
CONFIG SET latency-monitor-threshold 5

# Check latency events
LATENCY LATEST                   # most recent latency spikes
LATENCY HISTORY command          # history for specific event
LATENCY RESET                    # clear history

# Intrinsic latency test (run from server host)
# valkey-cli --intrinsic-latency 10   # 10-second test
```

### Monitoring Live Commands

```bash
# WARNING: MONITOR impacts performance ~50% — use only for debugging, with timeout
timeout 5 valkey-cli MONITOR | head -100
```

---

## Network and Timeout Problems

### Client Timeout Tuning

```
# Server-side idle timeout (0 = disabled)
timeout 300                        # close idle connections after 5min

# TCP keepalive (seconds)
tcp-keepalive 60                   # detect dead peers
```

**Client-side configuration** (ioredis example):
```javascript
const redis = new Redis({
  connectTimeout: 5000,            // 5s connect timeout
  commandTimeout: 2000,            // 2s per command
  retryStrategy(times) {
    return Math.min(times * 200, 5000);  // exponential backoff, max 5s
  },
  maxRetriesPerRequest: 3,
  enableReadyCheck: true,
  lazyConnect: true,
});
```

### Diagnosing Connection Issues

```redis
INFO clients                       # connected_clients, blocked_clients, maxclients
CLIENT LIST                        # all connected clients with idle time, flags
CLIENT LIST TYPE normal            # filter by type
```

### TCP Backlog Issues

**Symptoms**: Connection refused under high load.

```bash
# Check system TCP backlog
sysctl net.core.somaxconn          # should be >= 511
sysctl net.ipv4.tcp_max_syn_backlog

# Fix
sudo sysctl -w net.core.somaxconn=1024
sudo sysctl -w net.ipv4.tcp_max_syn_backlog=1024
```

```
# In redis.conf/valkey.conf
tcp-backlog 511                    # match or less than somaxconn
```

---

## Cluster Issues

### Slot Migration Problems

```redis
CLUSTER INFO                       # cluster_state, slots_assigned, slots_ok
CLUSTER NODES                      # full node list with slot ranges
```

### Fixing Stuck Migrations

```redis
CLUSTER NODES | grep -E "migrating|importing"
CLUSTER SETSLOT <slot> STABLE      # cancel on both source and target
```

### MOVED and ASK Redirects

**MOVED**: Stale slot map — update and retry. **ASK**: Mid-migration — follow redirect once. Most client libraries handle automatically.

### Cross-Slot Errors

**Error**: `CROSSSLOT Keys in request don't hash to the same slot`
**Fix**: Use hash tags: `{user:1001}:profile` and `{user:1001}:settings` share slot.

### Adding/Removing Nodes

```bash
valkey-cli --cluster add-node 10.0.0.4:6379 10.0.0.1:6379
valkey-cli --cluster reshard 10.0.0.1:6379 --cluster-from <id> --cluster-to <id> --cluster-slots 1000 --cluster-yes
valkey-cli --cluster del-node 10.0.0.1:6379 <node-id>  # after resharding slots away
```

---

## Sentinel and Split-Brain

### Split-Brain Scenario

Split-brain occurs when network partition causes Sentinel to promote a replica while the old master is still accepting writes.

**Prevention**:
```
# On master — stop accepting writes if too few replicas connected
min-replicas-to-write 1           # require at least 1 replica
min-replicas-max-lag 10           # replica must be within 10s of master
```

### Diagnosing Sentinel Issues

```redis
# Connect to Sentinel
valkey-cli -p 26379

SENTINEL masters                   # list monitored masters
SENTINEL master mymaster           # details for specific master
SENTINEL replicas mymaster         # replicas of master
SENTINEL sentinels mymaster        # other Sentinels monitoring same master
SENTINEL get-master-addr-by-name mymaster  # current master address
```

### Common Sentinel Problems

**Wrong master after failover**:
```redis
SENTINEL RESET mymaster            # clear Sentinel state, re-discover
```

**Sentinel can't reach master** (false positive):
- Check `down-after-milliseconds` — too low causes false failovers
- Ensure Sentinel nodes span different network zones
- Use `SENTINEL DEBUG sleep 0` to check if Sentinel itself is slow

**Stale Sentinel configuration**:
```bash
# Force Sentinel to rewrite its config
SENTINEL FLUSHCONFIG
```

### Sentinel Quorum

- Deploy odd number of Sentinels (3 or 5)
- Quorum = majority needed to agree on failover
- `sentinel monitor mymaster 10.0.0.1 6379 2` — quorum of 2 (out of 3)
- Place Sentinels in different availability zones

---

## Replication Problems

### Diagnosing Replication Lag

```redis
-- On master: check slave lag in INFO replication (slave0:...,lag=N)
-- On replica: check master_link_status, master_sync_in_progress, slave_repl_offset
INFO replication
```

### Full Resync Issues

**Symptoms**: `master_sync_in_progress:1`, repeated sync breaks.
**Fixes**: Increase backlog (`CONFIG SET repl-backlog-size 256mb`), check network, raise output buffer (`client-output-buffer-limit replica 512mb 128mb 60`).

Ensure `replicaof` is in config file (not just runtime). For slow disks, enable `repl-diskless-sync yes`.

---

## Persistence (AOF/RDB) Issues

### AOF Rewrite Problems

**Symptoms**: High memory during rewrite, failed rewrites. Check `INFO persistence`.

**Fix**: Tune `auto-aof-rewrite-percentage 100`, `auto-aof-rewrite-min-size 64mb`. Schedule `BGREWRITEAOF` during off-peak.

**Corrupted AOF**: `valkey-check-aof --fix appendonly.aof`

### RDB Save Failures

**Error**: `Can't save in background: fork: Cannot allocate memory`

```bash
sudo sysctl -w vm.overcommit_memory=1            # allow overcommit
echo never | sudo tee /sys/kernel/mm/transparent_hugepage/enabled  # disable THP
```

### Choosing Persistence Strategy

| Scenario | Strategy |
|----------|----------|
| Pure cache | No persistence (`save ""`, `appendonly no`) |
| Cache with fast recovery | RDB only |
| Data integrity critical | AOF with `appendfsync everysec` |
| Best of both | Hybrid (`aof-use-rdb-preamble yes`) |
| Maximum durability | AOF with `appendfsync always` (slow) |

---

## Client Connection Problems

### Max Clients Reached

**Error**: `ERR max number of clients reached`

Fix: `CONFIG SET maxclients 20000`. Ensure OS `ulimit -n` > maxclients + 32. Check `INFO clients` and `CLIENT LIST` to identify consumers.

### Connection Pool Exhaustion

Use `enableOfflineQueue: false` to fail fast. Use `scaleReads: 'slave'` in cluster mode. Set `connectTimeout: 5000`, `commandTimeout: 2000`.

### Identifying Problematic Clients

```redis
CLIENT LIST                        # look for idle=300+, qbuf=0
CLIENT KILL ID <client-id>         # kill specific client
```

---

## RESP Protocol Errors

### Common RESP Errors

| Error | Cause | Fix |
|-------|-------|-----|
| `-ERR unknown command` | Renamed or disabled command | Check `rename-command` in config |
| `-WRONGTYPE` | Command on wrong data type | Verify key type with `TYPE key` |
| `-LOADING` | Server loading dataset | Wait, or check load progress with `INFO persistence` |
| `-BUSY` | Lua script running too long | `SCRIPT KILL` or wait; check `lua-time-limit` |
| `-NOSCRIPT` | EVALSHA for unknown script | Fallback to EVAL, or SCRIPT LOAD first |
| `-READONLY` | Write to read-only replica | Connect to master, or check cluster state |
| `-CLUSTERDOWN` | Cluster in failed state | Check `CLUSTER INFO`, fix failed nodes |
| `-MASTERDOWN` | Sentinel can't find master | Check Sentinel config, master health |

### Debugging Protocol Issues

```bash
echo -e "*3\r\n\$3\r\nSET\r\n\$3\r\nfoo\r\n\$3\r\nbar\r\n" | nc localhost 6379  # raw RESP
```

RESP3 (Valkey 7+/Redis 6+): `HELLO 3` to enable typed responses. Most clients auto-negotiate.

---

## Lua Script Debugging

### Script Timeout

**Error**: `-BUSY Redis is busy running a script`
Use `SCRIPT KILL` (only if script hasn't written). Set `CONFIG SET lua-time-limit 5000`.

### Debugging Scripts

Use `redis.log(redis.LOG_WARNING, 'msg')` inside scripts. Interactive debugger (dev only): `valkey-cli --ldb --eval script.lua key1 , arg1`.

### Common Lua Pitfalls

1. **Accessing keys not in KEYS array** — Breaks cluster compatibility
2. **Non-deterministic commands** — `TIME`, `RANDOMKEY` not allowed in scripts intended for replication
3. **Large return values** — Return only what the client needs
4. **String vs number confusion** — Redis returns strings; use `tonumber()`:
   ```lua
   local val = tonumber(redis.call('GET', KEYS[1])) or 0
   ```
5. **Error handling** — Use `redis.pcall()` for recoverable errors:
   ```lua
   local ok, err = pcall(function()
       return redis.call('GET', KEYS[1])
   end)
   if not ok then redis.log(redis.LOG_WARNING, err) end
   ```
