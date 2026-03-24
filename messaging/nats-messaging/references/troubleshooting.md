# NATS Troubleshooting Guide

Comprehensive diagnostics and fixes for production NATS issues.

## Table of Contents

- [1. Slow Consumers](#1-slow-consumers)
- [2. Message Loss Diagnosis](#2-message-loss-diagnosis)
- [3. JetStream Storage Issues](#3-jetstream-storage-issues)
- [4. Cluster Split-Brain](#4-cluster-split-brain)
- [5. Authentication Failures](#5-authentication-failures)
- [6. Connection Draining](#6-connection-draining)
- [7. Memory Pressure](#7-memory-pressure)
- [8. Consumer Stall](#8-consumer-stall)
- [9. Stream Repair](#9-stream-repair)
- [10. Monitoring with Prometheus](#10-monitoring-with-prometheus)
- [11. Common Error Messages](#11-common-error-messages)

---

## 1. Slow Consumers

### Detection

Server logs:
```
[WRN] 192.168.1.40:52130 - cid:87 - "orders-processor" - Slow Consumer Detected
[WRN] 192.168.1.40:52130 - cid:87 - Slow Consumer (Dropped: 1482)
```

```bash
# Sort connections by pending bytes (slow consumers at top)
nats server report connections --sort pending

# HTTP API alternative
curl -s http://localhost:8222/connz?sort=pending&limit=10 | \
  jq '.connections[] | select(.pending_bytes > 0) | {cid, name, pending_bytes, slow_consumer}'
```

### Root Causes

| Cause | Diagnostic | Fix |
|-------|-----------|-----|
| Blocking handler (sync DB, HTTP) | Handler latency >10ms avg | Move to async processing, use buffered channels |
| Broad wildcard subscription | Subscription matches too many subjects | Narrow filter, use queue groups |
| Insufficient consumer throughput | Single consumer can't keep up | Add queue group members, use pull consumer with batching |
| Network bottleneck | High RTT between client and server | Co-locate, increase write_deadline |
| Client garbage collection | Periodic latency spikes | Tune GC, use off-heap buffers |

### Fixes

**Server-side: increase buffer and deadline**
```hcl
# nats-server.conf
max_pending: 67108864    # 64MB per connection (default 64MB)
write_deadline: "10s"     # Time before dropping slow connection
```

**Client-side: set pending limits**
```go
sub, _ := nc.Subscribe("events.>", handler)
sub.SetPendingLimits(500_000, 256*1024*1024)  // 500K msgs or 256MB
```

**JetStream: enable flow control on push consumers**
```bash
nats consumer add ORDERS flow-processor \
  --deliver-subject=deliver.orders \
  --flow-control \
  --idle-heartbeat=5s \
  --ack-explicit \
  --max-pending=10000
```

**Scale with queue groups**
```go
for i := 0; i < workerCount; i++ {
    nc.QueueSubscribe("orders.created", "order-workers", handler)
}
```

**Batch processing for JetStream pull consumers**
```go
sub, _ := js.PullSubscribe("orders.>", "batch-processor")
msgs, _ := sub.Fetch(100, nats.MaxWait(5*time.Second))
for _, msg := range msgs {
    process(msg)
    msg.Ack()
}
```

---

## 2. Message Loss Diagnosis

### Core NATS vs JetStream

Core NATS is **at-most-once**: no subscribers means message dropped. This is by design. Use JetStream for persistence.

### Diagnosis Checklist

```bash
# 1. Check stream state
nats stream info ORDERS
#   Messages: 1,482,901 | First Seq: 102 | Last Seq: 1,483,002 | Num Deleted: 214
# If First Seq > 1, messages were evicted by retention limits

# 2. Check consumer state
nats consumer info ORDERS order-processor
#   Num Ack Pending: 140    <- delivered but not acked
#   Num Redelivered:  23    <- re-sent after ack timeout

# 3. Check for advisory events
nats sub '$JS.EVENT.ADVISORY.>' --count=10
```

### Common Causes and Fixes

| Symptom | Cause | Fix |
|---------|-------|-----|
| `First Sequence` advances | Stream limits exceeded, oldest evicted | Increase `max_msgs`, `max_bytes`, or `max_age` |
| `Num Ack Pending` grows | Consumer not acking | Fix exception before `msg.Ack()`, increase `ack_wait` |
| `Num Redelivered` climbs | Ack timeout too short | Increase `ack_wait` to cover processing time |
| `MAX_DELIVERIES` advisory | Message exceeded `max_deliver` limit | Fix poison message, implement DLQ |
| Messages never arrive | Wrong subject filter on consumer | Check `FilterSubject` matches publish subjects |

### Publish-Side Verification

```go
ack, err := js.Publish("orders.created", data)
if err != nil {
    log.Printf("Publish failed: %v", err)
}
log.Printf("Published: stream=%s seq=%d duplicate=%v", ack.Stream, ack.Sequence, ack.Duplicate)
```

### Consumer-Side Verification

```go
var lastSeq uint64
handler := func(msg jetstream.Msg) {
    meta, _ := msg.Metadata()
    if meta.Sequence.Stream != lastSeq+1 && lastSeq > 0 {
        log.Printf("GAP detected: expected seq %d, got %d", lastSeq+1, meta.Sequence.Stream)
    }
    lastSeq = meta.Sequence.Stream
    msg.Ack()
}
```

---

## 3. JetStream Storage Issues

### Storage Exhaustion

```bash
# Check JetStream resource usage
nats account info
#   Memory:  950MB / 1.0GB (95%)  <- critical
#   Storage: 45GB / 50GB (90%)    <- warning

# Detailed view
curl -s http://localhost:8222/jsz | jq '{
    memory_used: .memory,
    memory_reserved: .reserved_memory,
    store_used: .store,
    store_reserved: .reserved_store
}'

# Check disk space
df -h /data/nats/jetstream
```

**Error:** `nats: insufficient resources` or `JetStream resource limits exceeded`

### Cleanup Procedures

```bash
# Purge all messages from a stream
nats stream purge ORDERS --force

# Keep only last N messages
nats stream purge ORDERS --keep 1000

# Delete entire stream
nats stream rm OLD_EVENTS --force

# Find and remove stale consumers
for s in $(nats stream ls -n); do
    echo "=== $s ==="
    nats consumer ls "$s" 2>/dev/null | head -20
done

# Remove specific consumer
nats consumer rm ORDERS stale-consumer --force
```

### Stream Storage Tuning

```bash
# Tighten retention limits
nats stream edit ORDERS \
  --max-msgs 10000000 \
  --max-bytes 10GB \
  --max-age 72h \
  --discard old
```

### Disk Performance Issues

```bash
# Check I/O latency
iostat -x 1 5

# JetStream uses fsync for durability
fio --name=sync-test --rw=write --bs=4k --size=1G --fsync=1 --numjobs=1
```

### File Corruption Recovery

```bash
# If JetStream data is corrupted:
# Option 1: Restore from backup
nats stream restore ORDERS /backup/orders-latest.tar.gz

# Option 2: Delete local data and let Raft re-replicate from healthy peers
systemctl stop nats-server
rm -rf /data/nats/jetstream/streams/ORDERS
systemctl start nats-server
```

---

## 4. Cluster Split-Brain

### How Raft Works in NATS

Each JetStream stream has its own Raft group. A **meta leader** coordinates stream/consumer creation. Each stream has a **stream leader** for writes.

- 3-node cluster: quorum = 2, tolerates 1 failure
- 5-node cluster: quorum = 3, tolerates 2 failures
- **Never run 2-node or 4-node clusters**

### Detection

```bash
# Check cluster state
nats server report jetstream
# Server  | Streams | Messages | Meta Leader
# nats-1  |     12  |    1.2M  | yes
# nats-2  |     12  |    1.2M  |
# nats-3* |      0  |       0  |          <- partitioned

# Check individual stream replicas
nats stream info ORDERS --json | jq '.cluster'

# No meta leader = all JetStream API calls fail
# Error: "nats: no JetStream meta leader found"
```

### Diagnosis

```bash
# Check cluster routes (port 6222)
curl -s http://nats-1:8222/routez | jq '.routes[] | {remote_id, ip, port, rtt}'

# Network connectivity
nc -zv nats-2.example.com 6222
nc -zv nats-3.example.com 6222
```

### Recovery

```bash
# Force leader stepdown
nats stream cluster step-down ORDERS
nats consumer cluster step-down ORDERS order-processor

# Monitor recovery
watch -n 2 'nats stream info ORDERS --json | jq ".cluster.replicas[]"'

# If a node is permanently lost, scale down replicas temporarily
nats stream edit ORDERS --replicas=1
# Add replacement node, then restore replicas
nats stream edit ORDERS --replicas=3
```

---

## 5. Authentication Failures

### Debug Mode

```bash
# Start server with debug and verbose flags for auth troubleshooting
nats-server -c nats.conf -DV
```

### Common Auth Errors

**NKey mismatch:**
```bash
# Verify NKey pair matches
nsc describe user -a MyAccount -n MyUser

# Test connection
nats pub test "hello" --nkey /path/to/user.nk
```

**JWT expired:**
```bash
# Check expiration
nsc describe user -a MyAccount -n MyUser --json | jq '.exp'

# Reissue credentials
nsc generate creds -a MyAccount -n MyUser -o /path/to/user.creds
nsc push -A
```

**Permission violations:**
```
[ERR] Permissions Violation for Publish to "orders.create"
```
```bash
nsc describe user -a MyAccount -n MyUser --json | jq '.nats | {pub, sub}'
```

**Account connection limit:**
```bash
curl -s 'http://localhost:8222/accountz?acc=ORDERS' | jq '{
    num_connections: .num_connections,
    max_connections: .limits.max_connections
}'
```

---

## 6. Connection Draining

### When Drain Fails

```go
// BAD: Drain blocks forever if messages keep arriving
nc.Drain()

// GOOD: Drain with context timeout
ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
defer cancel()

done := make(chan struct{})
go func() {
    nc.Drain()
    close(done)
}()

select {
case <-done:
    log.Println("Drain completed")
case <-ctx.Done():
    log.Println("Drain timed out, forcing close")
    nc.Close()
}
```

### Graceful Shutdown Pattern

```go
sigCh := make(chan os.Signal, 1)
signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

go func() {
    <-sigCh
    // 1. Stop accepting new work
    for _, sub := range subscriptions {
        sub.Unsubscribe()
    }
    // 2. Finish in-flight work
    wg.Wait()
    // 3. Drain connection
    nc.Drain()
    os.Exit(0)
}()
```

### Server-Side Lame Duck

Lame duck mode gracefully drains a server:
1. Server stops accepting new connections
2. Existing connections receive lame-duck notification
3. Clients reconnect to other cluster nodes

```hcl
lame_duck_duration: "30s"
lame_duck_grace_period: "10s"
```

---

## 7. Memory Pressure

### Diagnosis

```bash
# Server memory
curl -s http://localhost:8222/varz | jq '{
    mem_bytes: .mem,
    mem_mb: (.mem / 1048576 | floor),
    connections: .connections,
    subscriptions: .subscriptions,
    slow_consumers: .slow_consumers
}'

# JetStream memory
curl -s http://localhost:8222/jsz | jq '{
    memory_used: .memory,
    memory_reserved: .reserved_memory
}'

# Per-connection memory hogs
curl -s 'http://localhost:8222/connz?sort=pending&limit=20' | \
    jq '.connections[] | {cid, name, pending_bytes, subscriptions}'
```

### Common Causes

| Cause | Detection | Fix |
|-------|-----------|-----|
| Too many connections | `/varz` connections count | Set `max_connections`, connection pooling |
| Memory-backed streams | `/jsz` memory_used near max | Switch to file storage |
| Subscription explosion | `/subsz` millions of subs | Audit subs, use queue groups |
| Reconnect buffer bloat | Client `ReconnectBufSize` | Reduce buffer size |
| Slow consumer pending | `/connz` high pending_bytes | Fix slow consumer (section 1) |
| Ephemeral consumer leak | Consumer count grows | Set `InactiveThreshold`, audit disconnects |

### Fixes

```bash
# Reduce JetStream memory allocation
# Edit nats-server.conf: jetstream { max_mem: 1GB }

# Switch memory streams to file storage (requires recreation)
nats stream rm CACHE --force
nats stream add CACHE --subjects="cache.>" --storage=file --max-age=1h

# Find ephemeral consumer leaks
for s in $(nats stream ls -n); do
    count=$(nats consumer ls "$s" -n 2>/dev/null | wc -l)
    [ "$count" -gt 50 ] && echo "WARNING: $s has $count consumers"
done
```

---

## 8. Consumer Stall

### Symptoms

- Consumer stops receiving despite stream having new messages
- `Num Ack Pending` at `MaxAckPending` limit
- Pull consumer `Fetch` returns empty repeatedly

### Diagnosis

```bash
nats consumer info ORDERS my-consumer --json | jq '{
    ack_pending: .num_ack_pending,
    max_ack_pending: .config.max_ack_pending,
    redelivered: .num_redelivered,
    waiting: .num_waiting,
    ack_floor: .ack_floor.stream_seq,
    delivered: .delivered.stream_seq
}'
```

### Causes and Fixes

**MaxAckPending saturated (push consumers):**
```bash
nats consumer edit ORDERS my-consumer --max-pending 5000
```

**Poison message (handler crashes on specific message):**
```go
func handler(msg jetstream.Msg) {
    meta, _ := msg.Metadata()
    if meta.NumDelivered > 3 {
        log.Printf("Poison message: seq=%d", meta.Sequence.Stream)
        js.Publish("dlq.orders", msg.Data())
        msg.Term()  // Stop redelivery
        return
    }
    msg.Ack()
}
```

**AckWait too short:**
```bash
nats consumer edit ORDERS my-consumer --ack-wait 60s
```

**Consumer reset (nuclear option):**
```bash
nats consumer rm ORDERS stalled-consumer --force
nats consumer add ORDERS stalled-consumer \
  --filter "orders.>" --ack explicit --max-deliver 5 \
  --ack-wait 60s --deliver-policy last
```

---

## 9. Stream Repair

### Detecting Corruption

Server logs show on startup:
```
[ERR] JetStream stream 'ORDERS' could not be restored: bad header detected
```

### Repair Procedures

**Re-replicate from healthy peers:**
```bash
# Stop affected node, remove corrupted data, restart
systemctl stop nats-server
rm -rf /data/nats/jetstream/streams/ORDERS
systemctl start nats-server
# Raft replicates from healthy peers automatically
```

**Restore from backup:**
```bash
nats stream rm ORDERS --force
nats stream restore ORDERS /backup/orders-latest.tar.gz
nats stream info ORDERS  # Verify
```

**Stream compaction issues:**
```bash
# Compaction needs temporary disk space
df -h /data/nats/jetstream
# Free space if needed:
nats stream purge LEAST_IMPORTANT --force
```

---

## 10. Monitoring with Prometheus

### Exporter Setup

```bash
prometheus-nats-exporter \
  -varz -connz -routez -subsz -jsz -leafz -gatewayz \
  -port 7777 \
  http://nats-1:8222 http://nats-2:8222 http://nats-3:8222
```

### Critical Alert Rules

```yaml
groups:
  - name: nats-alerts
    rules:
      - alert: NATSServerDown
        expr: up{job="nats"} == 0
        for: 30s
        labels: { severity: critical }

      - alert: NATSSlowConsumers
        expr: nats_varz_slow_consumers > 0
        for: 2m
        labels: { severity: warning }

      - alert: NATSJetStreamStorageCritical
        expr: (nats_server_jetstream_store_used / nats_server_jetstream_store_reserved) > 0.90
        for: 5m
        labels: { severity: critical }

      - alert: NATSNoMetaLeader
        expr: nats_server_jetstream_meta_leader == 0
        for: 30s
        labels: { severity: critical }

      - alert: NATSClusterRouteDown
        expr: nats_routez_num_routes < 2
        for: 1m
        labels: { severity: critical }
```

### Key Metrics

| Metric | Warning | Critical |
|--------|---------|----------|
| `nats_varz_slow_consumers` | > 0 for 2min | > 5 for 5min |
| JetStream storage % | > 75% | > 90% |
| JetStream memory % | > 70% | > 85% |
| Connection count | > 85% max | > 95% max |
| Consumer ack pending | > 1000 | > 5000 |

---

## 11. Common Error Messages

| Error | Cause | Fix |
|-------|-------|-----|
| `nats: no JetStream meta leader found` | No Raft quorum | Ensure majority of nodes running |
| `nats: insufficient resources` | JetStream limits hit | Increase limits, purge old data |
| `nats: maximum consumers limit reached` | Account limit | Increase via nsc |
| `nats: stream not found` | Wrong name or deleted | `nats stream ls` to verify |
| `nats: no responders` | No service listening | Check service subscription |
| `nats: timeout` | Request timeout expired | Increase timeout, check service |
| `nats: maximum payload exceeded` | Message too large | Use object store for large payloads |
| `nats: stale connection` | Missed heartbeats | Check network, adjust ping settings |
| `TLS handshake error: x509` | CA not trusted | Add CA to `ca_file` |
| `Permissions Violation` | Missing permission | Update user permissions |

### Quick Diagnostic Commands

```bash
nats server info                          # Server version and config
nats server ping --count 3                # Cluster connectivity
nats server report connections --sort pending  # Find slow consumers
nats server report jetstream              # JetStream cluster state
nats stream info STREAM_NAME              # Stream health
nats consumer info STREAM CONSUMER        # Consumer health
curl -sf http://localhost:8222/healthz    # Health check
curl -s http://localhost:8222/varz | jq   # Full server stats
```
