# RabbitMQ Troubleshooting Guide

## Table of Contents

- [Memory Alarms and Flow Control](#memory-alarms-and-flow-control)
- [Unacknowledged Message Buildup](#unacknowledged-message-buildup)
- [Channel Churn](#channel-churn)
- [Connection Leaks](#connection-leaks)
- [Split-Brain in Clusters](#split-brain-in-clusters)
- [Network Partition Handling Strategies](#network-partition-handling-strategies)
- [Queue Length Growing Unbounded](#queue-length-growing-unbounded)
- [Consumer Utilization Low](#consumer-utilization-low)
- [TLS Handshake Failures](#tls-handshake-failures)
- [Disk Alarm](#disk-alarm)
- [Diagnostic Commands Quick Reference](#diagnostic-commands-quick-reference)

---

## Memory Alarms and Flow Control

### Symptoms

- Publishers block (connections show `blocking` or `blocked` state)
- Management UI shows red memory alarm banner
- Log entry: `vm_memory_high_watermark set. Publishers will be blocked`
- `rabbitmqctl status` shows `{memory, [{alarm, true}]}`

### Root Causes

1. **Consumers too slow or disconnected** — messages accumulate in memory
2. **Too many queues with in-memory messages** — classic queues hold messages in RAM
3. **Large message payloads** — individual large messages consume disproportionate memory
4. **Management stats database** — the internal stats DB can consume significant memory on busy clusters
5. **Erlang process heap fragmentation** — long-running node with high churn
6. **Connection/channel metadata** — thousands of connections each carry overhead

### Diagnosis

```bash
# Check current memory usage breakdown
rabbitmqctl status | grep -A 30 "Memory"

# Detailed memory breakdown via API
curl -s -u admin:pass http://localhost:15672/api/nodes/rabbit@$(hostname) | \
  python3 -c "import sys,json; m=json.load(sys.stdin)['memory']; [print(f'{k}: {v/1048576:.1f} MB') for k,v in sorted(m.items(), key=lambda x:-x[1])]"

# Check per-queue memory usage
rabbitmqctl list_queues name memory messages --formatter=json | \
  python3 -c "import sys,json; qs=json.load(sys.stdin); [print(f\"{q['name']}: {q['memory']/1048576:.1f}MB ({q['messages']} msgs)\") for q in sorted(qs, key=lambda x:-x['memory'])[:20]]"

# Check connection count
rabbitmqctl list_connections state --formatter=json | \
  python3 -c "import sys,json; cs=json.load(sys.stdin); print(f\"Total: {len(cs)}\"); from collections import Counter; [print(f\"  {s}: {c}\") for s,c in Counter(c['state'] for c in cs).items()]"
```

### Resolution

```ini
# rabbitmq.conf — Tune memory watermark
vm_memory_high_watermark.relative = 0.6          # Default 0.4, raise if dedicated host
vm_memory_high_watermark_paging_ratio = 0.75      # Start paging to disk at 75% of watermark

# Or set absolute limit
# vm_memory_high_watermark.absolute = 4GB
```

**Immediate actions:**
1. **Purge backed-up queues** if messages are expendable: `rabbitmqctl purge_queue <name>`
2. **Restart stuck consumers** to drain queues
3. **Enable lazy queues** for large backlogs: messages go to disk, reducing RAM pressure
4. **Increase node RAM** if consistently near the watermark

**Long-term fixes:**
1. Switch to quorum queues (better memory management via Raft log segments on disk)
2. Set `x-max-length` on queues to cap message count
3. Set `x-message-ttl` to expire stale messages
4. Use `x-overflow: reject-publish` for backpressure instead of unbounded growth
5. Reduce management stats collection interval if stats DB is large: `management.rates_mode = none`

---

## Unacknowledged Message Buildup

### Symptoms

- Queue shows high `unacked` count in management UI
- `messages_ready` is low but `messages_unacknowledged` grows
- Consumer appears connected but not making progress
- Memory increases even though queue depth looks "normal"

### Root Causes

1. **Consumer processing is stuck** — deadlock, infinite loop, or blocked I/O
2. **Prefetch too high** — consumer grabs many messages but processes slowly
3. **Missing ack call** — application bug where `basic_ack` is never called on some code paths
4. **Consumer crash without nack** — unacked messages stay in limbo until connection closes
5. **Auto-ack disabled but manual ack forgotten** — common beginner mistake

### Diagnosis

```bash
# List queues with unacked counts
rabbitmqctl list_queues name messages_ready messages_unacknowledged consumers

# List consumers with prefetch and unacked count
rabbitmqctl list_consumers queue_name channel_pid ack_required prefetch_count

# Check consumer utilization per queue (via API)
curl -s -u admin:pass http://localhost:15672/api/queues/%2F/ | \
  python3 -c "
import sys, json
for q in json.load(sys.stdin):
    unacked = q.get('messages_unacknowledged', 0)
    if unacked > 0:
        print(f\"{q['name']}: ready={q.get('messages_ready',0)} unacked={unacked} consumers={q.get('consumers',0)}\")
"
```

### Resolution

1. **Fix the consumer code** — ensure every code path calls `ack`, `nack`, or `reject`
2. **Lower prefetch_count** — reduce to 1-10 for debugging, then tune upward
3. **Set consumer timeout** (RabbitMQ 3.12+):
   ```ini
   # rabbitmq.conf — kill consumers that don't ack within 30 minutes
   consumer_timeout = 1800000
   ```
4. **Restart stuck consumers** — closing the channel/connection returns unacked messages to the queue
5. **Add heartbeats** to detect dead consumers faster: `heartbeat=60`

### Prevention

```python
# Pattern: always ack/nack in a try/finally
def safe_consumer(ch, method, properties, body):
    try:
        process(body)
        ch.basic_ack(delivery_tag=method.delivery_tag)
    except Exception:
        ch.basic_nack(delivery_tag=method.delivery_tag, requeue=False)
```

---

## Channel Churn

### Symptoms

- `rabbitmqctl list_channels` shows rapidly changing channel PIDs
- Management UI shows high channel creation/closure rate
- Erlang process count grows
- CPU usage elevated due to channel lifecycle overhead
- Log messages about channel open/close events

### Root Causes

1. **Opening a new channel per message** instead of reusing channels
2. **Short-lived connections** where each request creates a connection + channel
3. **Channel errors** (e.g., publishing to non-existent exchange) cause channel closure and recreation
4. **Channel-per-request in web frameworks** without pooling

### Diagnosis

```bash
# Channel count and creation rate
rabbitmqctl list_channels pid connection number consumer_count | wc -l

# Watch channel count over time
watch -n 5 'rabbitmqctl list_channels 2>/dev/null | wc -l'

# Check for channel errors in logs
grep -i "channel error" /var/log/rabbitmq/rabbit@$(hostname).log | tail -20
```

### Resolution

1. **Reuse channels** — open one channel per thread/goroutine, keep it open for the lifetime of the thread
2. **Use channel pools** — in web applications, maintain a pool of channels
3. **Fix channel errors** — channel exceptions (e.g., 404 NOT_FOUND, 406 PRECONDITION_FAILED) close the channel. Fix the root cause.
4. **One connection, multiple channels** — channels are cheap; connections are expensive. Use one TCP connection with multiple channels.

```python
# Anti-pattern: channel per publish
def bad_publish(connection, message):
    channel = connection.channel()  # New channel every time!
    channel.basic_publish(exchange='', routing_key='q', body=message)
    channel.close()

# Correct: reuse channel
class Publisher:
    def __init__(self, connection):
        self.channel = connection.channel()
        self.channel.confirm_delivery()

    def publish(self, message):
        self.channel.basic_publish(exchange='', routing_key='q', body=message)
```

---

## Connection Leaks

### Symptoms

- Connection count grows continuously over time
- `rabbitmqctl list_connections` shows many idle/stale connections
- File descriptor exhaustion (`too many open files`)
- Memory growth correlated with connection count
- Error: `cannot accept connection, too many file descriptors in use`

### Root Causes

1. **Missing `connection.close()` in error paths** — connections left open on exceptions
2. **Thread/process spawning new connections without cleanup**
3. **Reconnect logic that doesn't close old connections** — common with retry wrappers
4. **Serverless/ephemeral environments** — functions spawn connections that outlive the function
5. **No heartbeat configured** — dead connections not detected by broker

### Diagnosis

```bash
# List connections with age and state
rabbitmqctl list_connections user peer_host state connected_at recv_oct send_oct

# Count connections per source host
rabbitmqctl list_connections peer_host --formatter=json | \
  python3 -c "
import sys, json
from collections import Counter
conns = json.load(sys.stdin)
for host, count in Counter(c['peer_host'] for c in conns).most_common(20):
    print(f'{host}: {count} connections')
"

# Check file descriptor usage
rabbitmqctl status | grep -A 5 "file_descriptors"

# Monitor connection count over time
watch -n 10 'rabbitmqctl list_connections 2>/dev/null | wc -l'
```

### Resolution

1. **Always close connections in finally/defer blocks**:
   ```python
   connection = None
   try:
       connection = pika.BlockingConnection(params)
       # ... use connection ...
   finally:
       if connection and connection.is_open:
           connection.close()
   ```
2. **Enable heartbeats**: `heartbeat=60` — broker closes connections after 2 missed heartbeats
3. **Set connection limits** per vhost:
   ```bash
   rabbitmqctl set_vhost_limits -p /production '{"max-connections": 500}'
   ```
4. **Use connection pooling** in application frameworks
5. **Monitor and alert** on connection count crossing thresholds
6. **Increase file descriptor limit** if legitimate connections are high:
   ```bash
   # /etc/systemd/system/rabbitmq-server.service.d/limits.conf
   [Service]
   LimitNOFILE=65536
   ```

---

## Split-Brain in Clusters

### Symptoms

- Management UI shows "Network partition detected" warning
- Queues exist on different nodes with different messages (data divergence)
- Some clients can publish/consume, others cannot (depends on which partition they connect to)
- `rabbitmqctl cluster_status` shows `{partitions, [['rabbit@node2']]}` (non-empty partitions list)
- Log entry: `Mnesia reports that this node is partitioned from`

### Root Causes

1. **Network interruption** between cluster nodes (even briefly)
2. **Node unresponsive** due to GC pause, CPU saturation, or disk I/O stall
3. **Firewall rules changed** blocking inter-node traffic (ports 4369, 25672)
4. **DNS resolution failure** for node hostnames
5. **Clock skew** large enough to trigger Erlang distribution timeouts

### Diagnosis

```bash
# Check partition status
rabbitmqctl cluster_status

# Check Erlang distribution connectivity
rabbitmqctl eval 'net_adm:ping('"'"'rabbit@node2'"'"').'

# Verify node connectivity
rabbitmqctl eval 'nodes().'

# Check for partition entries in logs
grep -i "partition" /var/log/rabbitmq/rabbit@$(hostname).log | tail -20

# Test inter-node connectivity
# Port 4369 (epmd) and 25672 (distribution)
nc -zv node2 4369
nc -zv node2 25672
```

### Resolution

**Immediate:** Restart the minority-side nodes to rejoin:
```bash
# On the partitioned node(s):
rabbitmqctl stop_app
rabbitmqctl start_app
# OR for stubborn partitions:
rabbitmqctl stop_app
rabbitmqctl reset      # WARNING: loses all data on this node
rabbitmqctl join_cluster rabbit@node1
rabbitmqctl start_app
```

**Prevention:** Configure automatic partition handling (see next section).

---

## Network Partition Handling Strategies

RabbitMQ offers three strategies for automatic partition recovery. Set in `rabbitmq.conf`:

### autoheal (Default-ish, Simple)

```ini
cluster_partition_handling = autoheal
```

- **Behavior:** When a partition is detected, RabbitMQ picks a "winning" partition (the one with the most connected clients). Nodes in the losing partition restart automatically and resync.
- **Data impact:** Messages in the losing partition's non-replicated classic queues are lost.
- **Best for:** Small clusters (2-3 nodes) where simplicity is preferred. Tolerable message loss.
- **Risk:** The "winning" side may not have the latest data. Brief availability gap during node restart.

### pause_minority (Recommended for Safety)

```ini
cluster_partition_handling = pause_minority
```

- **Behavior:** Nodes in the minority partition pause (stop serving clients). When the partition heals, they automatically resume. If exactly 50/50, both sides pause.
- **Data impact:** Minority-side clients lose connectivity. No data divergence. Data consistency preserved.
- **Best for:** Clusters of 3+ nodes where data consistency is critical. Financial, transactional workloads.
- **Risk:** Minority-side clients must reconnect to majority nodes. Requires odd-numbered cluster (3, 5, 7) to avoid 50/50 stalemate.

### pause_if_all_down

```ini
cluster_partition_handling = pause_if_all_down
cluster_partition_handling.pause_if_all_down.nodes = rabbit@node1, rabbit@node2
cluster_partition_handling.pause_if_all_down.recover = autoheal
```

- **Behavior:** A node pauses if it loses contact with ALL listed nodes. Otherwise continues serving.
- **Best for:** Specific topologies where certain nodes are "anchor" nodes.
- **Risk:** Complex to configure correctly. Rarely needed.

### Strategy Comparison

| Strategy | Consistency | Availability | Complexity | Recommendation |
|----------|------------|--------------|------------|----------------|
| `autoheal` | Weak (data loss possible) | Good (auto-recovery) | Low | Dev/staging, non-critical |
| `pause_minority` | Strong (no divergence) | Reduced (minority pauses) | Medium | **Production default** |
| `pause_if_all_down` | Configurable | Configurable | High | Special topologies only |
| `ignore` | None (divergence!) | Maximum | None | **Never use in production** |

### Quorum Queues and Partitions

Quorum queues (Raft-based) handle partitions inherently better than classic queues:
- A quorum queue remains available as long as a majority of replicas are reachable
- No data loss — Raft consensus ensures consistency
- Strongly recommended for all durable queues in clustered deployments

---

## Queue Length Growing Unbounded

### Symptoms

- Queue depth in management UI growing continuously
- Memory alarm may trigger if classic queues
- Disk usage growing if lazy or quorum queues
- `messages_ready` count increases over time

### Root Causes

1. **No consumers or consumers disconnected**
2. **Consumer processing rate < publisher rate** (sustained)
3. **No TTL set** — messages never expire
4. **No max-length set** — queue grows without bound
5. **Consumer errors** — messages being requeued in a loop (nack with `requeue=True`)
6. **Poison messages** blocking consumers (consumer can't process, requeues, gets same message)

### Diagnosis

```bash
# Show queue depths with rates
curl -s -u admin:pass http://localhost:15672/api/queues/%2F/ | \
  python3 -c "
import sys, json
for q in json.load(sys.stdin):
    depth = q.get('messages', 0)
    pub_rate = q.get('message_stats', {}).get('publish_details', {}).get('rate', 0)
    del_rate = q.get('message_stats', {}).get('deliver_get_details', {}).get('rate', 0)
    ack_rate = q.get('message_stats', {}).get('ack_details', {}).get('rate', 0)
    if depth > 100:
        print(f\"{q['name']}: depth={depth} pub={pub_rate:.1f}/s del={del_rate:.1f}/s ack={ack_rate:.1f}/s consumers={q.get('consumers',0)}\")
"

# Check for redelivered messages (poison message indicator)
rabbitmqctl list_queues name messages_ready messages_unacknowledged redelivered
```

### Resolution

**Immediate:**
1. **Scale consumers** — add more consumer instances
2. **Purge if expendable**: `rabbitmqctl purge_queue <queue_name>`
3. **Set TTL retroactively** via policy:
   ```bash
   rabbitmqctl set_policy ttl-24h ".*" '{"message-ttl": 86400000}' --apply-to queues
   ```

**Preventive:**
```python
# Declare queues with safety limits
channel.queue_declare(queue='events', durable=True, arguments={
    'x-queue-type': 'quorum',
    'x-max-length': 1000000,
    'x-overflow': 'reject-publish',   # Backpressure to publishers
    'x-message-ttl': 86400000,        # 24h TTL
    'x-delivery-limit': 5             # Max redeliveries (quorum only)
})
```

**Handle poison messages:**
```python
def on_message(ch, method, properties, body):
    death_count = 0
    if properties.headers and 'x-death' in properties.headers:
        death_count = sum(d.get('count', 0) for d in properties.headers['x-death'])

    if death_count > 5:
        # Poison message — send to parking lot, don't requeue
        ch.basic_reject(delivery_tag=method.delivery_tag, requeue=False)
        return

    try:
        process(body)
        ch.basic_ack(delivery_tag=method.delivery_tag)
    except Exception:
        ch.basic_nack(delivery_tag=method.delivery_tag, requeue=True)
```

---

## Consumer Utilization Low

### Symptoms

- Queue depth growing despite consumers being connected
- Management UI shows low consumer utilization percentage (< 50%)
- Messages not being delivered even though queue has messages

### Understanding Consumer Utilization

Consumer utilization measures the fraction of time a consumer is ready to receive messages. 100% means the consumer is always ready. Low utilization means the consumer is often busy (unacked messages at prefetch limit) or the broker can't deliver fast enough.

### Root Causes

1. **Prefetch too low** — consumer acks one message, broker delivers next, round-trip latency wasted
2. **Consumer processing too slow** — bottleneck in message handler
3. **Network latency** between consumer and broker — each ack/deliver round-trip adds latency
4. **Single consumer on high-throughput queue** — one consumer can't keep up
5. **Synchronous processing** — consumer does blocking I/O per message

### Diagnosis

```bash
# Check consumer utilization via API
curl -s -u admin:pass http://localhost:15672/api/queues/%2F/ | \
  python3 -c "
import sys, json
for q in json.load(sys.stdin):
    util = q.get('consumer_utilisation')
    if util is not None and util < 0.9 and q.get('consumers', 0) > 0:
        print(f\"{q['name']}: utilization={util:.1%} consumers={q['consumers']} prefetch=? depth={q.get('messages',0)}\")
"

# Check prefetch settings
rabbitmqctl list_consumers queue_name channel_pid prefetch_count
```

### Resolution

1. **Increase prefetch** — allows broker to pipeline message delivery:
   ```python
   # Increase from default 1 to higher value
   channel.basic_qos(prefetch_count=50)  # Experiment: 20-100
   ```
2. **Add more consumers** — horizontal scaling
3. **Async/concurrent processing** — process multiple messages concurrently:
   ```python
   # Use threading or async to process messages concurrently
   from concurrent.futures import ThreadPoolExecutor
   executor = ThreadPoolExecutor(max_workers=10)

   def on_message(ch, method, properties, body):
       future = executor.submit(process, body)
       future.add_done_callback(
           lambda f: ch.basic_ack(delivery_tag=method.delivery_tag)
       )
   ```
4. **Reduce processing time** — optimize the message handler, cache, batch DB writes
5. **Co-locate consumer with broker** — reduce network latency

---

## TLS Handshake Failures

### Symptoms

- Clients fail to connect with TLS errors
- Log: `SSL: hello: tls_handshake.erl: ... handshake_failure`
- Log: `TLS server: ... received CLIENT ALERT: Fatal - Certificate Unknown`
- Connections succeed on port 5672 (plain AMQP) but fail on 5671 (TLS)
- `openssl s_client` shows handshake errors

### Root Causes

1. **Certificate expired** — server or CA certificate past expiry date
2. **Hostname mismatch** — certificate CN/SAN doesn't match connection hostname
3. **CA not trusted** — client doesn't have the CA cert in its trust store
4. **TLS version mismatch** — server requires TLS 1.3 but client only supports 1.2
5. **Cipher suite mismatch** — no common cipher between client and server
6. **Client certificate required but not provided** — `fail_if_no_peer_cert = true`
7. **Wrong file permissions** — RabbitMQ can't read cert/key files
8. **PEM file format issues** — wrong encoding, missing intermediate certs

### Diagnosis

```bash
# Test TLS connectivity
openssl s_client -connect rabbitmq:5671 -CAfile /path/to/ca.pem \
  -cert /path/to/client.pem -key /path/to/client-key.pem

# Check certificate expiry
openssl x509 -in /etc/rabbitmq/ssl/server.pem -noout -dates

# Check certificate CN/SAN
openssl x509 -in /etc/rabbitmq/ssl/server.pem -noout -text | grep -A 2 "Subject Alternative Name"

# Verify cert chain
openssl verify -CAfile /etc/rabbitmq/ssl/ca.pem /etc/rabbitmq/ssl/server.pem

# Check RabbitMQ TLS config
rabbitmqctl eval 'application:get_env(rabbit, ssl_options).'

# Check file permissions
ls -la /etc/rabbitmq/ssl/

# Check RabbitMQ logs for TLS errors
grep -i "tls\|ssl\|certificate\|handshake" /var/log/rabbitmq/rabbit@$(hostname).log | tail -30
```

### Resolution

1. **Renew expired certificates:**
   ```bash
   # Verify dates
   openssl x509 -in server.pem -noout -dates
   # Regenerate if expired, restart RabbitMQ
   systemctl restart rabbitmq-server
   ```

2. **Fix hostname mismatch** — regenerate certificate with correct CN/SAN:
   ```bash
   openssl req -new -x509 -days 365 -key server-key.pem -out server.pem \
     -subj "/CN=rabbitmq.example.com" \
     -addext "subjectAltName=DNS:rabbitmq.example.com,DNS:rabbit1,DNS:rabbit2,IP:10.0.0.1"
   ```

3. **Ensure compatible TLS versions:**
   ```ini
   # rabbitmq.conf — allow both TLS 1.2 and 1.3
   ssl_options.versions.1 = tlsv1.3
   ssl_options.versions.2 = tlsv1.2
   ```

4. **Fix file permissions:**
   ```bash
   chown rabbitmq:rabbitmq /etc/rabbitmq/ssl/*
   chmod 400 /etc/rabbitmq/ssl/server-key.pem
   chmod 444 /etc/rabbitmq/ssl/server.pem /etc/rabbitmq/ssl/ca.pem
   ```

5. **Include intermediate certificates** — concatenate into the cert file:
   ```bash
   cat server.pem intermediate.pem > server-chain.pem
   ```

---

## Disk Alarm

### Symptoms

- Publishers block (same as memory alarm)
- Management UI shows red disk alarm
- Log: `disk free space has dropped below the configured limit`
- `rabbitmqctl status` shows disk alarm active

### Root Causes

1. **Message store** — persistent messages consuming disk
2. **Raft log segments** — quorum queues write Raft logs to disk
3. **Log files** — RabbitMQ logs filling the partition
4. **Mnesia database** — cluster metadata growth
5. **Other processes** — non-RabbitMQ processes filling the same partition

### Diagnosis

```bash
# Check disk usage
df -h /var/lib/rabbitmq/

# Check RabbitMQ data directory size
du -sh /var/lib/rabbitmq/mnesia/

# Check individual subdirectories
du -sh /var/lib/rabbitmq/mnesia/rabbit@$(hostname)/*

# Disk alarm status
rabbitmqctl status | grep -A 5 "disk"

# Check configured disk limit
rabbitmqctl environment | grep disk_free_limit
```

### Resolution

**Immediate:**
1. **Free disk space** — delete old logs, temporary files
2. **Purge large queues** if messages are expendable
3. **Increase disk** — expand partition or add storage

**Configuration:**
```ini
# rabbitmq.conf — Set disk free limit
disk_free_limit.relative = 1.5    # 1.5x RAM (recommended)
# OR absolute:
# disk_free_limit.absolute = 5GB

# Log rotation
log.file.rotation.date = $D0      # Rotate daily
log.file.rotation.size = 104857600 # Rotate at 100MB
log.file.rotation.count = 7       # Keep 7 files
```

**Preventive:**
1. Put RabbitMQ data on a dedicated partition — prevents other apps from triggering the alarm
2. Set message TTL and queue length limits to prevent unbounded growth
3. Monitor disk usage and alert at 70% capacity
4. Use quorum queues judiciously — they write more to disk than classic queues
5. Enable log rotation to prevent log accumulation

---

## Diagnostic Commands Quick Reference

### Node Health

```bash
# Overall node status
rabbitmqctl status

# Health check (exits non-zero if unhealthy)
rabbitmq-diagnostics check_running
rabbitmq-diagnostics check_local_alarms
rabbitmq-diagnostics check_port_connectivity

# Comprehensive health check
rabbitmq-diagnostics status --formatter=json

# Erlang runtime info
rabbitmqctl eval 'erlang:system_info(process_count).'
rabbitmqctl eval 'erlang:memory().'
```

### Cluster Health

```bash
# Cluster status and partitions
rabbitmqctl cluster_status

# Check if all nodes are running
rabbitmq-diagnostics check_running --node rabbit@node1
rabbitmq-diagnostics check_running --node rabbit@node2
rabbitmq-diagnostics check_running --node rabbit@node3

# List cluster members
rabbitmqctl eval 'rabbit_nodes:list_members().'
```

### Queue Diagnostics

```bash
# All queues with details
rabbitmqctl list_queues name type state messages consumers memory \
  messages_ready messages_unacknowledged

# Queue info for specific queue
rabbitmqctl list_queues name messages consumers --filter 'name=order.processing'

# Quorum queue leader/follower info
rabbitmqctl list_queues name type leader followers online
```

### Connection and Channel Diagnostics

```bash
# All connections
rabbitmqctl list_connections user peer_host peer_port state channels ssl \
  connected_at heartbeat

# All channels
rabbitmqctl list_channels pid connection number consumer_count \
  messages_unacknowledged prefetch_count

# Connection/channel count
rabbitmqctl list_connections | wc -l
rabbitmqctl list_channels | wc -l
```

### Exchange and Binding Diagnostics

```bash
# All exchanges
rabbitmqctl list_exchanges name type durable auto_delete

# All bindings
rabbitmqctl list_bindings source_name destination_name routing_key

# Trace message routing (enable rabbitmq_tracing plugin)
rabbitmq-plugins enable rabbitmq_tracing
rabbitmqctl trace_on -p /production
```

### Management API Quick Queries

```bash
# Cluster overview
curl -s -u admin:pass http://localhost:15672/api/overview | python3 -m json.tool

# Node list with stats
curl -s -u admin:pass http://localhost:15672/api/nodes

# All alarms
curl -s -u admin:pass http://localhost:15672/api/health/checks/alarms

# Specific queue details
curl -s -u admin:pass http://localhost:15672/api/queues/%2F/order.processing

# Publish a test message (debugging)
curl -s -u admin:pass -X POST http://localhost:15672/api/exchanges/%2F/amq.default/publish \
  -H "Content-Type: application/json" \
  -d '{"properties":{},"routing_key":"test.queue","payload":"test","payload_encoding":"string"}'
```
