# RabbitMQ Troubleshooting Guide

## Table of Contents

- [Connection Churn](#connection-churn)
- [Channel Leaks](#channel-leaks)
- [Memory Alarms](#memory-alarms)
- [Disk Alarms](#disk-alarms)
- [Unacked Message Buildup](#unacked-message-buildup)
- [Consumer Cancellation](#consumer-cancellation)
- [Queue Mirroring Lag (Pre-4.0)](#queue-mirroring-lag-pre-40)
- [Network Partitions](#network-partitions)
- [Slow Consumers](#slow-consumers)
- [Message Ordering Guarantees](#message-ordering-guarantees)
- [Cluster Recovery Procedures](#cluster-recovery-procedures)
- [Diagnostic Commands Reference](#diagnostic-commands-reference)

---

## Connection Churn

### Symptoms

- High `rabbitmq_connections_opened_total` / `rabbitmq_connections_closed_total` rates
- Elevated CPU on broker nodes
- `connection_created` / `connection_closed` events flood the log
- File descriptor exhaustion (`too many open files`)

### Root Causes

- Application creates a new connection per publish/consume operation
- Connection pool misconfiguration (too small, no reuse)
- Short-lived serverless functions (Lambda, Cloud Functions) connecting directly
- Load balancer health checks opening TCP connections

### Solutions

```python
# BAD: connection per message
def publish(msg):
    conn = pika.BlockingConnection(...)  # churn!
    ch = conn.channel()
    ch.basic_publish(...)
    conn.close()

# GOOD: reuse connection, one per process
class Publisher:
    def __init__(self):
        self.conn = pika.BlockingConnection(
            pika.ConnectionParameters(
                host='localhost',
                heartbeat=60,
                blocked_connection_timeout=300
            )
        )
        self.channel = self.conn.channel()
        self.channel.confirm_delivery()

    def publish(self, msg):
        self.channel.basic_publish(...)
```

**Additional mitigations:**
- Set `connection_max` in `rabbitmq.conf` to prevent runaway connections
- Use connection pooling libraries (e.g., `aio-pika` pool for async Python)
- For serverless, use an intermediary service or Amazon MQ proxy
- Configure load balancer health checks to use TCP-only (no AMQP handshake)
- Monitor with: `rabbitmqctl list_connections name peer_host state`

---

## Channel Leaks

### Symptoms

- Channel count per connection grows without bound
- `channel_max` exceeded errors
- Memory usage climbs steadily
- `rabbitmqctl list_channels` shows thousands of channels

### Root Causes

- Opening a new channel per operation without closing it
- Exception paths that skip `channel.close()`
- Channel created inside loops without cleanup

### Solutions

```python
# BAD: channel leak
for msg in messages:
    ch = conn.channel()  # leak!
    ch.basic_publish(...)
    # never closed

# GOOD: reuse or use context manager
ch = conn.channel()
for msg in messages:
    ch.basic_publish(...)
ch.close()

# BEST: context manager pattern
class ChannelContext:
    def __init__(self, connection):
        self.connection = connection

    def __enter__(self):
        self.channel = self.connection.channel()
        return self.channel

    def __exit__(self, *args):
        if self.channel.is_open:
            self.channel.close()
```

**Diagnostics:**
```bash
# Count channels per connection
rabbitmqctl list_connections name channels | sort -t$'\t' -k2 -rn | head -20

# Set channel limit in rabbitmq.conf
# channel_max = 128
```

---

## Memory Alarms

### Symptoms

- `rabbit_alarm: memory resource limit` in logs
- Publishers block (connections enter `blocking` or `blocked` state)
- Management UI shows memory alarm (red indicator)
- `rabbitmqctl status` shows `{resource_alarm, memory}` active

### Root Causes

- Queues with millions of messages in RAM (classic queues pre-CQv2)
- Too many connections/channels consuming memory
- Large messages held in memory-mapped queues
- Erlang process heap fragmentation
- Insufficient RAM for the workload

### Solutions

```ini
# rabbitmq.conf — tune watermark
# Fraction of total RAM (default 0.4)
vm_memory_high_watermark.relative = 0.7

# Or absolute value
vm_memory_high_watermark.absolute = 4GB

# Paging watermark — start paging before alarm triggers
vm_memory_high_watermark_paging_ratio = 0.75
```

**Immediate relief:**
```bash
# Check current memory breakdown
rabbitmqctl status | grep -A 20 'memory'

# Force GC on all queues
rabbitmqctl eval 'rabbit_amqqueue:foreach(fun(Q) -> rabbit_amqqueue:force_all_gc() end).'

# Purge a specific queue (data loss!)
rabbitmqctl purge_queue <queue_name>
```

**Long-term fixes:**
- Migrate to quorum queues (Raft-based, efficient memory use)
- Set `x-max-length` or `x-max-length-bytes` with DLX overflow policy
- Add consumers to drain queues faster
- Use streams for high-volume, many-consumer workloads
- Upgrade RAM or scale the cluster horizontally

---

## Disk Alarms

### Symptoms

- `rabbit_alarm: disk resource limit` in logs
- All publishers block globally
- Management UI shows disk alarm
- Node may refuse new connections

### Root Causes

- Message store consuming disk space (persistent messages in queues/streams)
- WAL (Write-Ahead Log) segments growing for quorum queues
- Log files filling disk (verbose logging)
- Other processes consuming disk on the same volume

### Solutions

```ini
# rabbitmq.conf — set appropriate disk limit
disk_free_limit.absolute = 5GB
# Or relative to RAM (recommended)
disk_free_limit.relative = 2.0
```

**Immediate relief:**
```bash
# Check disk usage by RabbitMQ data directory
du -sh /var/lib/rabbitmq/mnesia/

# Check disk free space
df -h /var/lib/rabbitmq/

# Purge unnecessary queues
rabbitmqctl list_queues name messages | awk '$2 > 100000' | while read q m; do
    echo "Queue $q has $m messages"
done

# Truncate logs
rabbitmqctl rotate_logs
```

**Long-term fixes:**
- Move RabbitMQ data directory to a dedicated volume
- Set message TTL and max-length on all queues
- Configure log rotation in `rabbitmq.conf`:
  ```ini
  log.file.rotation.date = $D0
  log.file.rotation.count = 7
  log.file.rotation.size = 104857600
  ```
- Monitor disk usage with Prometheus alerts

---

## Unacked Message Buildup

### Symptoms

- `messages_unacked` grows steadily on a queue
- Consumer prefetch buffer is full, no new messages delivered
- Memory usage increases
- `consumer_timeout` (default 30 min in 3.12+) triggers consumer cancellation

### Root Causes

- Consumer processing takes too long without acking
- Exception in consumer handler prevents ack
- Prefetch too high — consumer gets more messages than it can process
- Consumer deadlock or thread starvation

### Solutions

```python
# Always ack/nack in a try/finally
def callback(ch, method, properties, body):
    try:
        result = process(body)
        ch.basic_ack(delivery_tag=method.delivery_tag)
    except RecoverableError:
        ch.basic_nack(delivery_tag=method.delivery_tag, requeue=True)
    except Exception:
        ch.basic_nack(delivery_tag=method.delivery_tag, requeue=False)  # to DLX
```

```ini
# rabbitmq.conf — consumer timeout (milliseconds, 0 = disabled)
consumer_timeout = 1800000  # 30 minutes (default in 3.12+)

# For long-running consumers, increase or disable
# consumer_timeout = 0
```

**Diagnostics:**
```bash
# Find queues with high unacked counts
rabbitmqctl list_queues name messages_ready messages_unacknowledged consumers

# Find consumers with outstanding unacked messages
rabbitmqctl list_consumers queue_name channel_pid ack_required prefetch_count
```

---

## Consumer Cancellation

### Symptoms

- Consumers silently stop receiving messages
- `basic.cancel` notification received
- Consumer count drops to zero on a queue
- Application logs show "consumer cancelled" events

### Root Causes

- `consumer_timeout` exceeded (consumer didn't ack within the timeout)
- Queue deleted while consumer was attached
- HA failover — classic mirrored queue leader changed (pre-4.0)
- Node went down hosting the queue leader
- Manual cancellation via management UI

### Solutions

```python
# Handle consumer cancellation notification
def on_cancel(method_frame):
    logger.warning(f"Consumer cancelled: {method_frame}")
    reconnect_and_reconsume()

channel.add_on_cancel_callback(on_cancel)

# For pika, handle connection/channel closure too
def on_close(channel, reason):
    logger.warning(f"Channel closed: {reason}")
    reconnect()

channel.add_on_close_callback(on_close)
```

```java
// Java — set consumer cancellation listener
channel.basicConsume("queue", false, new DefaultConsumer(channel) {
    @Override
    public void handleCancel(String consumerTag) {
        logger.warn("Consumer cancelled: " + consumerTag);
        reconnect();
    }
});
```

**Best practices:**
- Always implement reconnection logic
- Use quorum queues — they handle leader election transparently
- Set `x-cancel-on-ha-failover: false` for classic mirrored queues (pre-4.0)
- Monitor consumer counts and alert when zero

---

## Queue Mirroring Lag (Pre-4.0)

> **Note**: Classic mirrored queues are removed in RabbitMQ 4.0. Migrate to quorum queues.

### Symptoms

- Mirror sync status shows `unsynchronised`
- Consumer sees message gaps after failover
- `rabbitmqctl list_queues name slave_pids synchronised_slave_pids` shows mismatches

### Root Causes

- Network latency between nodes
- Slow mirror nodes (disk I/O, CPU)
- High message rate exceeding mirror sync capacity
- New mirror added to a queue with existing messages

### Solutions

```bash
# Check sync status
rabbitmqctl list_queues name pid slave_pids synchronised_slave_pids

# Force sync (blocks queue during sync!)
rabbitmqctl sync_queue <queue_name>

# Set automatic sync policy
rabbitmqctl set_policy ha-sync ".*" \
  '{"ha-mode":"exactly","ha-params":2,"ha-sync-mode":"automatic"}' \
  --apply-to queues
```

**Migration to quorum queues:**
```bash
# Step 1: Drain the mirrored queue
# Step 2: Delete the mirrored queue
# Step 3: Declare as quorum queue
rabbitmqadmin declare queue name=my-queue durable=true \
  arguments='{"x-queue-type":"quorum"}'
```

---

## Network Partitions

### Symptoms

- Management UI shows "Network partition detected"
- Split-brain: queues exist on multiple nodes independently
- `rabbitmqctl cluster_status` shows `{partitions, [nodes]}`
- Messages published to different sides of the partition diverge

### Partition Handling Strategies

```ini
# rabbitmq.conf — choose ONE strategy

# pause_minority (RECOMMENDED for most cases)
# Nodes in the minority partition pause and refuse connections
cluster_partition_handling = pause_minority

# autoheal
# Broker automatically picks a winner and restarts losers
# May lose messages on losing side
cluster_partition_handling = autoheal

# ignore (NOT recommended for production)
# Manual intervention required
cluster_partition_handling = ignore
```

### pause_minority vs autoheal

| Aspect | pause_minority | autoheal |
|---|---|---|
| Data safety | ✅ Higher — minority pauses | ⚠️ Losing side may drop messages |
| Availability | ❌ Minority side unavailable | ✅ Both sides continue, then merge |
| Recovery | Automatic when partition heals | Automatic — loser restarts |
| Best for | Data consistency priority | Availability priority |
| Cluster size | Odd-numbered (3, 5, 7) | Any size |
| With quorum queues | Recommended | Works but less safe |

### Recovery Procedure

```bash
# 1. Identify partition status
rabbitmqctl cluster_status

# 2. If using 'ignore' mode, manually restart minority nodes
rabbitmqctl stop_app    # on minority node
rabbitmqctl start_app

# 3. Verify recovery
rabbitmqctl cluster_status
rabbitmqctl list_queues name pid slave_pids

# 4. Force-reset a node that won't rejoin
rabbitmqctl stop_app
rabbitmqctl force_reset
rabbitmqctl join_cluster rabbit@healthy-node
rabbitmqctl start_app
```

### Prevention

- Use reliable networks with low latency between nodes
- Set `net_ticktime` appropriately (default 60s):
  ```ini
  # rabbitmq.conf
  net_ticktime = 60
  ```
- Use `pause_minority` with 3+ node clusters
- Deploy across availability zones with dedicated low-latency links
- Monitor network health between nodes

---

## Slow Consumers

### Symptoms

- `messages_ready` grows while `messages_unacked` is at prefetch limit
- Queue depth increases over time
- Memory alarms triggered by queue growth
- Consumer utilization metric is low in management UI

### Root Causes

- Consumer processing is I/O bound (database, external API calls)
- Single-threaded consumer on a high-volume queue
- Prefetch too low — consumer idle between message batches
- Consumer performing synchronous operations that could be async

### Solutions

**Scale horizontally:**
```bash
# Run more consumer processes
for i in $(seq 1 $DESIRED_CONSUMERS); do
    python consumer.py --queue=tasks &
done
```

**Optimize prefetch:**
```python
# Increase prefetch for I/O-bound consumers
channel.basic_qos(prefetch_count=50)
```

**Batch processing:**
```python
# Accumulate and batch-process
batch = []
def callback(ch, method, properties, body):
    batch.append((method.delivery_tag, body))
    if len(batch) >= 100:
        process_batch([b for _, b in batch])
        for tag, _ in batch:
            ch.basic_ack(delivery_tag=tag)
        batch.clear()
```

**Use streams for fan-out:**
If multiple consumers need the same data, switch to streams instead of duplicating messages across multiple queues.

**Monitoring query:**
```bash
# Find slow consumer queues
rabbitmqctl list_queues name messages_ready messages_unacknowledged consumers \
  | awk '$2 > 10000 { print "ALERT:", $1, "has", $2, "ready msgs with", $4, "consumers" }'
```

---

## Message Ordering Guarantees

### What RabbitMQ Guarantees

1. **Single publisher → single queue → single consumer**: Messages delivered in publish order
2. **Multiple publishers → single queue**: No global order guarantee across publishers
3. **Single publisher → fanout exchange → multiple queues**: Each queue gets messages in publish order
4. **Redelivery**: Redelivered messages (`redelivered=true`) may arrive out of order

### Common Ordering Pitfalls

| Scenario | Ordering Preserved? | Solution |
|---|---|---|
| Multiple consumers on one queue | ❌ No | Use single active consumer or consistent hash exchange |
| Message rejected and requeued | ❌ No | Use DLX instead of requeue |
| Priority queue | ❌ No (by design) | Don't use priority if ordering matters |
| Quorum queue with delivery limit | ✅ Yes (within deliveries) | N/A |
| Consumer prefetch > 1 | ⚠️ Processing order not guaranteed | Process sequentially or use prefetch=1 |

### Single Active Consumer

Ensure only one consumer processes a queue at a time:

```python
channel.queue_declare(queue='ordered-tasks', durable=True, arguments={
    'x-queue-type': 'quorum',
    'x-single-active-consumer': True
})
```

### Per-Key Ordering with Consistent Hash

```python
# Messages with the same routing key go to the same queue
channel.exchange_declare(exchange='ordered', exchange_type='x-consistent-hash')
# Bind N queues, each with one consumer
```

---

## Cluster Recovery Procedures

### Single Node Recovery

```bash
# 1. Check RabbitMQ status
systemctl status rabbitmq-server
journalctl -u rabbitmq-server --since "1 hour ago"

# 2. Check Erlang VM
rabbitmqctl status

# 3. If node won't start, check logs
tail -100 /var/log/rabbitmq/rabbit@$(hostname).log

# 4. Common fixes
rabbitmq-diagnostics check_running
rabbitmq-diagnostics check_local_alarms

# 5. Reset if corrupted (LAST RESORT — loses all data)
rabbitmqctl stop_app
rabbitmqctl force_reset
rabbitmqctl start_app
```

### Cluster Node Recovery

```bash
# 1. Check cluster status from a healthy node
rabbitmqctl cluster_status

# 2. On the failed node, try starting
rabbitmqctl start_app

# 3. If it can't rejoin, force reset and rejoin
rabbitmqctl stop_app
rabbitmqctl force_reset
rabbitmqctl join_cluster rabbit@healthy-node
rabbitmqctl start_app

# 4. Verify quorum queue leaders are balanced
rabbitmq-queues rebalance quorum
```

### Full Cluster Recovery (All Nodes Down)

```bash
# 1. Find the last node to shut down (most up-to-date data)
# Check force_boot marker or Mnesia/Khepri state

# 2. Start that node FIRST
rabbitmqctl force_boot  # on the last node to stop
systemctl start rabbitmq-server

# 3. Start other nodes (they will sync from the first)
systemctl start rabbitmq-server  # on each remaining node

# 4. Verify cluster
rabbitmqctl cluster_status
rabbitmq-queues check_if_node_is_quorum_critical
```

### Quorum Queue Recovery

```bash
# Check quorum queue health
rabbitmq-queues quorum_status <queue_name>

# If a member is permanently lost, delete it
rabbitmq-queues delete_member <queue_name> rabbit@lost-node

# Add a new member
rabbitmq-queues add_member <queue_name> rabbit@new-node

# Rebalance leaders across nodes
rabbitmq-queues rebalance quorum
```

---

## Diagnostic Commands Reference

```bash
# Node health
rabbitmq-diagnostics check_running
rabbitmq-diagnostics check_local_alarms
rabbitmq-diagnostics check_port_connectivity
rabbitmq-diagnostics status

# Cluster health
rabbitmq-diagnostics check_if_any_deprecated_features_are_used
rabbitmq-diagnostics cluster_status

# Queue diagnostics
rabbitmqctl list_queues name type messages consumers memory state
rabbitmq-queues check_if_node_is_quorum_critical

# Connection diagnostics
rabbitmqctl list_connections name peer_host state channels
rabbitmqctl list_channels connection name consumer_count messages_unacknowledged

# Consumer diagnostics
rabbitmqctl list_consumers queue_name channel_pid ack_required prefetch_count

# Environment and config
rabbitmqctl environment
rabbitmq-diagnostics runtime_thread_stats

# Log analysis
rabbitmq-diagnostics log_tail -N 100
rabbitmq-diagnostics log_tail_stream

# Memory breakdown
rabbitmq-diagnostics memory_breakdown
```
