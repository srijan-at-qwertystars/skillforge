---
name: nats-messaging
description: >
  Guide for building systems with NATS messaging. Use when: implementing NATS pub/sub,
  request/reply patterns, JetStream streams and consumers, NATS KV store, NATS object store,
  queue groups for load balancing, lightweight cloud-native messaging, NATS clustering,
  NATS security with TLS/NKeys/JWTs, NATS on Kubernetes, or comparing NATS vs alternatives.
  Do NOT use when: implementing Kafka for log aggregation or stream processing pipelines,
  RabbitMQ for complex routing with exchanges and bindings, general pub/sub systems without
  NATS specifics, AMQP/MQTT/STOMP protocol work, or Redis Streams for caching-adjacent messaging.
---

# NATS Messaging System

## When to Choose NATS

Choose NATS for low-latency (<1ms), high-throughput (8M+ msgs/sec) cloud-native messaging.
Choose Kafka for durable log-based event streaming, long-term replay, and analytics pipelines.
Choose RabbitMQ for complex routing, dead-letter exchanges, and legacy AMQP protocol support.

NATS strengths: single binary, zero external dependencies, built-in clustering, multi-tenancy,
request/reply, and optional persistence via JetStream. Ideal for microservice communication,
IoT/edge, control planes, and service mesh data planes.

## Core Concepts

### Subjects
Use dot-separated hierarchical naming. Wildcards: `*` matches one token, `>` matches one or more.
```
orders.us.new     # specific subject
orders.*.new      # matches orders.us.new, orders.eu.new
orders.>          # matches orders.us.new, orders.eu.shipped.confirmed
```

### Publish/Subscribe
Fire-and-forget fan-out. All subscribers receive every message. No persistence by default.

### Request/Reply
Synchronous RPC-like pattern. Client publishes with an auto-generated inbox reply subject.
Server subscribes, processes, and replies. First response wins; others are discarded.

### Queue Groups
Load-balance messages across subscribers sharing a queue group name. Only one member per
group receives each message. No server-side configuration needed—subscribers declare the
group name on subscribe.

## Server Configuration

### Minimal Server (`nats-server.conf`)
```
listen: 0.0.0.0:4222
server_name: nats-1

jetstream {
  store_dir: /data/jetstream
  max_memory_store: 1GB
  max_file_store: 100GB
}

# Monitoring
http_port: 8222
```

### Clustering (3-Node)
```
cluster {
  name: production
  listen: 0.0.0.0:6222
  routes: [
    nats-route://nats-1:6222
    nats-route://nats-2:6222
    nats-route://nats-3:6222
  ]
}
```
Set `jetstream` with `replicas: 3` on streams for HA. Minimum 3 nodes for quorum.

### TLS Configuration
```
tls {
  cert_file: "/etc/nats/server-cert.pem"
  key_file:  "/etc/nats/server-key.pem"
  ca_file:   "/etc/nats/ca-cert.pem"
  verify:    true   # enforce mutual TLS
}
```

### Authentication & Authorization

**NKey auth** (preferred — Ed25519 challenge/response, no shared secrets):
```
authorization {
  users = [
    {
      nkey: "UABC..."
      permissions = {
        publish = ["orders.>", "events.>"]
        subscribe = ["replies.>"]
      }
    }
  ]
}
```
Generate keys: `nk -gen user -pubout` → seed (`SU...`) + public key (`U...`).

**JWT/Credentials auth** for multi-tenant production:
```
operator: /etc/nats/operator.jwt
resolver: {
  type: full
  dir: /etc/nats/jwt
}
```
Clients use `.creds` files containing JWT + NKey seed. Manage with `nsc` CLI.

## JetStream

### Create a Stream
Streams capture messages on subjects for persistence, replay, and durable delivery.
```
# CLI
nats stream add ORDERS \
  --subjects "orders.>" \
  --retention limits \
  --max-msgs 1000000 \
  --max-age 72h \
  --storage file \
  --replicas 3 \
  --max-msg-size 1MB
```

Retention policies:
- `limits`: retain until limits (count/size/age) are hit (default)
- `interest`: retain only while active consumers exist
- `workqueue`: delete after acknowledgment (each message delivered once)

### Create a Consumer
```
# Durable pull consumer
nats consumer add ORDERS order-processor \
  --filter "orders.us.>" \
  --deliver all \
  --ack explicit \
  --max-deliver 5 \
  --ack-wait 30s \
  --pull
```

Consumer types:
- **Pull**: client explicitly fetches batches. Use for services that control throughput.
- **Push**: server delivers messages to a subject. Use for real-time event handlers.

### Exactly-Once Delivery
Enable message deduplication with publish-time message IDs:
```go
js.Publish("orders.new", data, nats.MsgId("order-12345"))
// Server deduplicates within the dedup window (default 2min)
```
Combine with `ack explicit` and idempotent consumers for end-to-end exactly-once.

## KV Store

Built on JetStream. Use for configuration, feature flags, session state, leader election.

```
# CLI
nats kv add CONFIG --replicas 3 --history 5 --ttl 24h
nats kv put CONFIG app.timeout "30s"
nats kv get CONFIG app.timeout
# Output: app.timeout > 30s (revision 1)
nats kv watch CONFIG  # real-time change notifications
```

Operations: `put`, `get`, `delete`, `purge`, `watch`, `keys`, `history`.
Each key supports revision tracking and CAS (Compare-And-Swap) updates via revision number.

## Object Store

Built on JetStream. Use for config files, ML models, certificates — not multi-GB blobs.

```
# CLI
nats object add ASSETS --replicas 3
nats object put ASSETS ./model.bin --name ml-model-v2
nats object get ASSETS ml-model-v2 --output ./downloaded-model.bin
nats object watch ASSETS  # observe changes
```

Objects are automatically chunked (default 128KB). Supports versioning and metadata.

## Client Libraries

### Go (nats.go)
```go
import (
    "github.com/nats-io/nats.go"
    "github.com/nats-io/nats.go/jetstream"
)

// Connect with options
nc, err := nats.Connect("nats://localhost:4222",
    nats.UserCredentials("user.creds"),
    nats.MaxReconnects(-1),
    nats.ReconnectWait(2 * time.Second),
)
defer nc.Close()

// Pub/Sub
nc.Publish("events.user.login", []byte(`{"user":"alice"}`))
nc.Subscribe("events.>", func(msg *nats.Msg) {
    log.Printf("received: %s", msg.Data)
})

// Queue group
nc.QueueSubscribe("orders.new", "order-workers", func(msg *nats.Msg) {
    processOrder(msg.Data)
    // only one worker in "order-workers" receives each message
})

// Request/Reply
resp, err := nc.Request("api.users.get", []byte(`{"id":1}`), 5*time.Second)

// JetStream
js, _ := jetstream.New(nc)
js.CreateStream(ctx, jetstream.StreamConfig{
    Name:     "EVENTS",
    Subjects: []string{"events.>"},
    Storage:  jetstream.FileStorage,
    Replicas: 3,
})
js.Publish(ctx, "events.order.created", []byte(`{"order":1}`))

// Pull consumer
cons, _ := js.CreateOrUpdateConsumer(ctx, "EVENTS", jetstream.ConsumerConfig{
    Durable:   "event-processor",
    AckPolicy: jetstream.AckExplicitPolicy,
})
msgs, _ := cons.Fetch(10)
for msg := range msgs.Messages() {
    process(msg)
    msg.Ack()
}

// KV Store
kv, _ := js.CreateKeyValue(ctx, jetstream.KeyValueConfig{Bucket: "config"})
kv.Put(ctx, "feature.dark-mode", []byte("true"))
entry, _ := kv.Get(ctx, "feature.dark-mode")
// entry.Value() == []byte("true"), entry.Revision() == 1
```

### Python (nats-py)
```python
import asyncio
import nats
from nats.js.api import StreamConfig, ConsumerConfig, AckPolicy

async def main():
    nc = await nats.connect(
        "nats://localhost:4222",
        user_credentials="user.creds",
        max_reconnect_attempts=-1,
    )

    # Pub/Sub
    async def handler(msg):
        print(f"Received on {msg.subject}: {msg.data.decode()}")

    await nc.subscribe("events.>", cb=handler)
    await nc.publish("events.user.login", b'{"user":"alice"}')

    # Queue group
    await nc.subscribe("orders.new", queue="order-workers", cb=process_order)

    # Request/Reply
    resp = await nc.request("api.users.get", b'{"id":1}', timeout=5)

    # JetStream
    js = nc.jetstream()
    await js.add_stream(StreamConfig(
        name="EVENTS", subjects=["events.>"], retention="limits"
    ))
    ack = await js.publish("events.order.created", b'{"order":1}')

    # Pull subscribe
    sub = await js.pull_subscribe("events.>", durable="processor")
    msgs = await sub.fetch(10, timeout=5)
    for msg in msgs:
        await msg.ack()

    # KV Store
    kv = await js.create_key_value(bucket="config")
    await kv.put("feature.dark-mode", b"true")
    entry = await kv.get("feature.dark-mode")
    # entry.value == b"true"

    await nc.close()

asyncio.run(main())
```

### Node.js (nats.js)
```javascript
import { connect, StringCodec, AckPolicy } from "nats";

const nc = await connect({
  servers: "nats://localhost:4222",
  maxReconnectAttempts: -1,
});
const sc = StringCodec();

// Pub/Sub
const sub = nc.subscribe("events.>");
(async () => {
  for await (const msg of sub) {
    console.log(`Received on ${msg.subject}: ${sc.decode(msg.data)}`);
  }
})();
nc.publish("events.user.login", sc.encode('{"user":"alice"}'));

// Queue group
const qsub = nc.subscribe("orders.new", { queue: "order-workers" });

// Request/Reply
const resp = await nc.request("api.users.get", sc.encode('{"id":1}'), { timeout: 5000 });

// JetStream
const jsm = await nc.jetstreamManager();
await jsm.streams.add({
  name: "EVENTS", subjects: ["events.>"], retention: "limits",
});
const js = nc.jetstream();
await js.publish("events.order.created", sc.encode('{"order":1}'));

// Pull consumer
const consumer = await js.consumers.get("EVENTS", "processor");
const messages = await consumer.fetch({ max_messages: 10, expires: 5000 });
for await (const msg of messages) {
  msg.ack();
}

// KV Store
const kv = await js.views.kv("config");
await kv.put("feature.dark-mode", sc.encode("true"));
const entry = await kv.get("feature.dark-mode");

await nc.close();
```

## Monitoring

### Built-in HTTP Endpoints (port 8222)
```
GET /varz          # server info, connections, memory, CPU
GET /connz         # active connections detail
GET /subsz         # subscription routing info
GET /jsz           # JetStream account/stream/consumer stats
GET /healthz       # health check (returns 200 if healthy)
```

### Prometheus + Grafana
Deploy `nats-server-exporter` as a sidecar or standalone:
```yaml
# prometheus.yml scrape config
- job_name: nats
  static_configs:
    - targets: ["nats-exporter:7777"]
```
Key metrics: `nats_server_connections`, `nats_server_msgs_in/out`,
`nats_jetstream_stream_messages`, `nats_jetstream_consumer_num_pending`.

### CLI Monitoring
```
nats server report jetstream  # stream/consumer health
nats server report connections
nats server ping              # cluster-wide latency check
```

## Kubernetes Deployment

### Helm Chart (recommended)
```bash
helm repo add nats https://nats-io.github.io/k8s/helm/charts/
helm repo update
```

**Production `values.yaml`:**
```yaml
nats:
  image: nats:2.10-alpine
  jetstream:
    enabled: true
    fileStore:
      pvc:
        size: 50Gi
        storageClassName: fast-ssd
    memoryStore:
      maxSize: 1Gi

cluster:
  enabled: true
  replicas: 3

auth:
  enabled: true
  resolver:
    type: full
    dir: /etc/nats-config/jwt

tls:
  secret:
    name: nats-tls
  ca: ca.crt
  cert: tls.crt
  key: tls.key

exporter:
  enabled: true
  serviceMonitor:
    enabled: true

podDisruptionBudget:
  enabled: true
  minAvailable: 2

resources:
  requests:
    cpu: 500m
    memory: 512Mi
  limits:
    cpu: "2"
    memory: 2Gi

affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - topologyKey: kubernetes.io/hostname
```
```bash
helm install nats nats/nats -f values.yaml -n messaging --create-namespace
```

### Leaf Nodes (Multi-Cluster / Edge)
Connect remote clusters or edge nodes to a central NATS cluster:
```
leafnodes {
  remotes [
    { url: "nats-leaf://central-nats:7422", credentials: "leaf.creds" }
  ]
}
```
Leaf nodes transparently extend subject routing across clusters without full mesh.

## Production Checklist

- [ ] Enable TLS on all client and cluster connections
- [ ] Use NKey or JWT auth — never deploy with no auth in production
- [ ] Set JetStream storage limits (`max_file_store`, `max_memory_store`)
- [ ] Deploy 3+ nodes for clustering (odd number for quorum)
- [ ] Use `replicas: 3` on streams for high availability
- [ ] Set explicit `ack_wait` and `max_deliver` on consumers
- [ ] Configure `max_payload` (default 1MB) per deployment needs
- [ ] Enable Prometheus exporter and set alerts on pending messages
- [ ] Set pod anti-affinity in Kubernetes for node distribution
- [ ] Use PVCs with fast storage class for JetStream file store
- [ ] Configure reconnect logic in all clients (`MaxReconnects: -1`)
- [ ] Test failover: kill a node and verify consumers rebalance

## Common Patterns

### Service Mesh with Request/Reply
Services register on `api.<service>.<method>` subjects. Callers use `nc.Request()`.
Multiple instances use queue groups for automatic load balancing.

### Event Sourcing with JetStream
Publish domain events to streams. Use `workqueue` retention for command handlers.
Use `limits` retention for event logs with replay capability.

### Distributed Config with KV
Store config in KV buckets. Services watch for changes and hot-reload without restarts.
Use CAS updates (`kv.Update(key, value, lastRevision)`) to prevent write conflicts.

### Fan-Out with Filtered Consumers
One stream captures `events.>`. Create per-service consumers with subject filters
(`events.billing.>`, `events.shipping.>`) for targeted delivery without multiple streams.
