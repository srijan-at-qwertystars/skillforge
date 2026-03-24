# NATS Advanced Patterns

Actionable patterns for production NATS deployments beyond basic pub/sub and simple JetStream.

## Table of Contents

- [1. JetStream Mirrors and Sources](#1-jetstream-mirrors-and-sources)
- [2. Message De-Duplication](#2-message-de-duplication)
- [3. Flow Control and Heartbeats](#3-flow-control-and-heartbeats)
- [4. Service API Pattern](#4-service-api-pattern)
- [5. NATS Micro Framework](#5-nats-micro-framework)
- [6. Subject Mapping and Transforms](#6-subject-mapping-and-transforms)
- [7. Account Import/Export](#7-account-importexport)
- [8. WebSocket Gateway](#8-websocket-gateway)
- [9. MQTT Bridge](#9-mqtt-bridge)
- [10. Request/Reply at Scale](#10-requestreply-at-scale)
- [11. Header-Based Routing](#11-header-based-routing)
- [12. Exactly-Once Processing Patterns](#12-exactly-once-processing-patterns)
- [13. Dead Letter Queues](#13-dead-letter-queues)
- [14. Multi-Stream Workflows](#14-multi-stream-workflows)

---

## 1. JetStream Mirrors and Sources

### Mirrors — Read-Only Replicas

A mirror is a byte-for-byte read-only copy of another stream. Use for:
- Geographic read replicas (reduce latency for consumers in other regions)
- Disaster recovery (passive standby)
- Offloading analytics consumers from the primary stream

```bash
# Create primary stream in dc-east
nats stream add ORDERS --subjects="orders.>" --storage=file --replicas=3

# Create mirror in dc-west (no subjects — mirrors the source exactly)
nats stream add ORDERS_MIRROR --mirror=ORDERS --storage=file --replicas=3
```

```go
js.AddStream(&nats.StreamConfig{
    Name:     "ORDERS_MIRROR",
    Storage:  nats.FileStorage,
    Replicas: 3,
    Mirror: &nats.StreamSource{
        Name: "ORDERS",
        // Optional: filter by subject within the source
        // FilterSubject: "orders.us.>",
        // Optional: connect to source in a different domain
        // External: &nats.ExternalStream{
        //     APIPrefix:     "$JS.dc-east.API",
        //     DeliverPrefix: "$JS.dc-east.DELIVER",
        // },
    },
})
```

**Key constraints:**
- Mirrors cannot have their own subjects (they replicate the source)
- A stream can be either a mirror OR have sources, not both
- Mirror lag is visible via `nats stream info ORDERS_MIRROR` → `Mirror Lag`
- Cross-domain mirrors require External API/Deliver prefixes

### Sources — Aggregate Multiple Streams

Sources pull messages from one or more streams into a single aggregate stream. Use for:
- Merging regional streams into a global view
- Creating filtered aggregates (e.g., all errors from all services)
- Cross-account data sharing

```bash
# Regional streams
nats stream add ORDERS_US --subjects="orders.us.>"
nats stream add ORDERS_EU --subjects="orders.eu.>"

# Global aggregate
nats stream add ORDERS_GLOBAL \
  --source=ORDERS_US --source=ORDERS_EU \
  --subjects="" --storage=file
```

```go
js.AddStream(&nats.StreamConfig{
    Name:    "ORDERS_GLOBAL",
    Storage: nats.FileStorage,
    Sources: []*nats.StreamSource{
        {Name: "ORDERS_US"},
        {Name: "ORDERS_EU"},
        // With subject transforms (NATS 2.10+):
        // {Name: "ORDERS_EU", SubjectTransforms: []nats.SubjectTransformConfig{
        //     {Source: "orders.eu.>", Destination: "global.orders.eu.>"},
        // }},
    },
})
```

**Source vs Mirror differences:**

| Feature | Mirror | Source |
|---------|--------|--------|
| Count | Exactly one | One or more |
| Own subjects | No | Yes (optional) |
| Direction | Read-only replica | Aggregation |
| Transforms | No | Yes (2.10+) |

---

## 2. Message De-Duplication

JetStream de-duplicates using the `Nats-Msg-Id` header within the stream's `Duplicates` window.

### Publisher-Side Dedup

```go
// Set dedup window on the stream
js.AddStream(&nats.StreamConfig{
    Name:       "PAYMENTS",
    Subjects:   []string{"payments.>"},
    Duplicates: 5 * time.Minute, // window for dedup tracking
})

// Publish with idempotency key
msg := &nats.Msg{
    Subject: "payments.charge",
    Data:    []byte(`{"id":"pay-9001","amount":99.95}`),
    Header:  nats.Header{"Nats-Msg-Id": []string{"pay-9001-v1"}},
}
ack, err := js.PublishMsg(msg)
// Re-publishing with same Nats-Msg-Id within 5 minutes → server returns ack
// with Duplicate=true, message is NOT stored again

if ack.Duplicate {
    log.Println("Duplicate detected, not stored again")
}
```

### Idempotency Key Strategies

```go
// Strategy 1: Entity ID + version (best for event sourcing)
header.Set("Nats-Msg-Id", fmt.Sprintf("%s-v%d", entityID, version))

// Strategy 2: Hash of payload (content-addressed)
hash := sha256.Sum256(payload)
header.Set("Nats-Msg-Id", hex.EncodeToString(hash[:16]))

// Strategy 3: Upstream correlation ID (pass-through dedup)
header.Set("Nats-Msg-Id", incomingRequest.Header.Get("X-Idempotency-Key"))
```

**Tuning the dedup window:**
- Too short → duplicates sneak through during retries
- Too long → more server memory for tracking (each ID ≈ 64 bytes)
- Rule of thumb: 2× your maximum expected retry window
- Check memory cost: `curl -s localhost:8222/jsz | jq '.streams[].state.num_subjects'`

---

## 3. Flow Control and Heartbeats

### Push Consumer Flow Control

Flow control prevents the server from overwhelming slow push consumers. Instead of dropping messages (slow consumer), the server pauses delivery and waits for the client to signal readiness.

```bash
nats consumer add ORDERS flow-processor \
  --deliver-subject=deliver.orders \
  --flow-control \
  --idle-heartbeat=5s \
  --ack-explicit \
  --max-pending=10000
```

```go
js.Subscribe("orders.>", handler,
    nats.Durable("flow-processor"),
    nats.ManualAck(),
    nats.EnableFlowControl(),
    nats.IdleHeartbeat(5*time.Second),
    nats.MaxAckPending(10000),
)
```

**How it works:**
1. Server sends up to `MaxAckPending` messages
2. When limit reached, server sends a flow control marker (empty message with status header)
3. Client library automatically responds to the marker
4. Server resumes delivery after receiving the response
5. If no messages for `IdleHeartbeat` duration, server sends a heartbeat so the client knows the connection is alive

### Pull Consumer Heartbeats

For long-running `Fetch` or `Consume` calls, heartbeats detect stalled connections:

```go
// New API (nats.go v1.31+)
cons, _ := js.OrderedConsumer(ctx, "ORDERS")
iter, _ := cons.Messages(
    jetstream.PullHeartbeat(5 * time.Second),
)
for {
    msg, err := iter.Next()
    if errors.Is(err, jetstream.ErrNoHeartbeat) {
        log.Println("Heartbeat missed — connection may be stale")
        // Reconnect or recreate consumer
        break
    }
    msg.Ack()
}
```

### Idle Heartbeat vs Flow Control

| Mechanism | Purpose | Direction |
|-----------|---------|-----------|
| Idle Heartbeat | Detect dead connections when no messages flowing | Server → Client |
| Flow Control | Backpressure to prevent overwhelming client | Server → Client → Server |

**Always enable both for push consumers in production.**

---

## 4. Service API Pattern

The NATS Service API (`$SRV`) provides built-in service discovery, health checks, and statistics without external infrastructure.

### Registering a Service

```go
import "github.com/nats-io/nats.go/micro"

srv, _ := micro.AddService(nc, micro.Config{
    Name:        "order-service",
    Version:     "1.2.0",
    Description: "Manages order lifecycle",
    // Metadata visible in discovery
    Metadata: map[string]string{
        "team":   "commerce",
        "region": "us-east-1",
    },
})

// Add endpoint groups
orders := srv.AddGroup("orders")
orders.AddEndpoint("create", micro.HandlerFunc(func(req micro.Request) {
    // Process order creation
    order := createOrder(req.Data())
    req.Respond(order)
}))

orders.AddEndpoint("get", micro.HandlerFunc(func(req micro.Request) {
    req.Respond(getOrder(req.Data()))
}))
```

### Discovering Services

```bash
# List all services
nats micro ls

# Get service info
nats micro info order-service

# Get service stats (latency, error count, request count)
nats micro stats order-service

# Ping all instances of a service
nats micro ping order-service
```

**Programmatic discovery:**

```go
// Subscribe to service discovery responses
nc.Subscribe("$SRV.INFO", func(m *nats.Msg) {
    var info micro.Info
    json.Unmarshal(m.Data, &info)
    fmt.Printf("Service: %s v%s (id: %s)\n", info.Name, info.Version, info.ID)
})
nc.Publish("$SRV.INFO", nil) // Request info from all services
```

### Service API Subjects

| Subject | Description |
|---------|-------------|
| `$SRV.PING` | Ping all services |
| `$SRV.PING.<name>` | Ping specific service |
| `$SRV.INFO` | Get info from all services |
| `$SRV.INFO.<name>` | Get info from specific service |
| `$SRV.STATS` | Get stats from all services |
| `$SRV.STATS.<name>` | Get stats from specific service |

---

## 5. NATS Micro Framework

`micro` is the Go framework for building NATS-native microservices. It wraps the Service API with ergonomic handlers, automatic stats collection, and health endpoints.

### Full Microservice Example

```go
package main

import (
    "encoding/json"
    "log"
    "os"
    "os/signal"

    "github.com/nats-io/nats.go"
    "github.com/nats-io/nats.go/micro"
)

func main() {
    nc, _ := nats.Connect(os.Getenv("NATS_URL"),
        nats.Name("user-service"),
        nats.MaxReconnects(-1),
    )
    defer nc.Drain()

    srv, _ := micro.AddService(nc, micro.Config{
        Name:    "user-service",
        Version: "2.0.0",
        // Custom error handler
        ErrorHandler: func(srv micro.Service, e *micro.NATSError) {
            log.Printf("service error: subject=%s err=%v", e.Subject, e.Error)
        },
    })

    // Endpoints auto-register under the service subject namespace
    root := srv.AddGroup("users")

    root.AddEndpoint("lookup", micro.HandlerFunc(func(req micro.Request) {
        var query struct{ Email string }
        json.Unmarshal(req.Data(), &query)

        user, err := db.FindByEmail(query.Email)
        if err != nil {
            req.Error("NOT_FOUND", "user not found", nil)
            return
        }
        data, _ := json.Marshal(user)
        req.Respond(data)
    }))

    root.AddEndpoint("create", micro.HandlerFunc(func(req micro.Request) {
        // req.Headers() for header access
        // req.Subject() for full subject
        user := createUser(req.Data())
        data, _ := json.Marshal(user)
        req.Respond(data,
            micro.WithHeaders(micro.Headers{
                "X-Created-Id": []string{user.ID},
            }),
        )
    }))

    // Block until signal
    sig := make(chan os.Signal, 1)
    signal.Notify(sig, os.Interrupt)
    <-sig
    srv.Stop()
}
```

### Client Calling a Micro Service

```go
// Request-reply to a micro endpoint
resp, _ := nc.Request("users.lookup", []byte(`{"email":"alice@example.com"}`), 5*time.Second)

// With headers
msg := &nats.Msg{
    Subject: "users.create",
    Data:    []byte(`{"name":"Bob","email":"bob@example.com"}`),
    Header:  nats.Header{"Authorization": []string{"Bearer token123"}},
}
resp, _ = nc.RequestMsg(msg, 5*time.Second)
```

---

## 6. Subject Mapping and Transforms

Subject mapping transforms subjects at the server level — no client changes needed. Available since NATS 2.8+ (enhanced in 2.10+).

### Server-Level Mappings

```hcl
# nats-server.conf
mappings = {
    # Simple rename: old subject → new subject
    "legacy.orders.create": "orders.created"

    # Wildcard mapping: rewrite hierarchy
    # orders.us.created → region.us.orders.created
    "orders.*.created": "region.{{wildcard(1)}}.orders.created"

    # Partitioned mapping: distribute across N subjects
    # requests.* → partitioned across 10 subjects
    "requests.*": "partitioned.requests.{{partition(10,1)}}"

    # Weighted mapping: canary deployments
    "api.handler": [
        { destination: "api.handler.v1", weight: 90 },
        { destination: "api.handler.v2", weight: 10 }
    ]
}
```

### Account-Level Mappings

```hcl
accounts {
    ORDERS {
        users: [{ nkey: "U..." }]
        mappings = {
            # Transform subjects within this account
            "order.*.*": "orders.{{wildcard(1)}}.events.{{wildcard(2)}}"
        }
    }
}
```

### Stream Subject Transforms (2.10+)

Transform subjects as messages enter a stream:

```go
js.AddStream(&nats.StreamConfig{
    Name:     "ORDERS_NORMALIZED",
    Subjects: []string{"raw.orders.>"},
    SubjectTransform: &nats.SubjectTransformConfig{
        Source:      "raw.orders.>",
        Destination: "normalized.orders.>",
    },
})
// Publishing to "raw.orders.us.created" stores as "normalized.orders.us.created"
```

### Transform Functions Reference

| Function | Example | Description |
|----------|---------|-------------|
| `{{wildcard(N)}}` | `{{wildcard(1)}}` | Nth wildcard token (1-indexed) |
| `{{partition(N,M)}}` | `{{partition(10,1)}}` | Hash-partition into N buckets using Mth token |
| `{{SplitFromLeft(N)}}` | `{{SplitFromLeft(2)}}` | First N tokens from wildcarded segment |
| `{{SplitFromRight(N)}}` | `{{SplitFromRight(1)}}` | Last N tokens from wildcarded segment |

---

## 7. Account Import/Export

Accounts provide multi-tenant isolation. Imports/exports control cross-account data flow.

### Export Types

**Stream export** — share a subject for subscribers in other accounts:

```hcl
accounts {
    BILLING {
        users: [{ nkey: "U..." }]
        exports: [
            # Public stream export (any account can import)
            { stream: "billing.events.>", accounts: ["*"] }

            # Private stream export (specific accounts only)
            { stream: "billing.internal.>", accounts: ["ORDERS"] }
        ]
    }
}
```

**Service export** — share a request/reply endpoint:

```hcl
accounts {
    AUTH_SVC {
        users: [{ nkey: "U..." }]
        exports: [
            {
                service: "auth.validate"
                accounts: ["*"]
                # Response type: single reply (default), stream, or chunked
                response_type: "Singleton"
            }
        ]
    }
}
```

### Import with Subject Mapping

```hcl
accounts {
    ORDERS {
        users: [{ nkey: "U..." }]
        imports: [
            # Import stream — map to local subject namespace
            {
                stream: { account: BILLING, subject: "billing.events.>" }
                prefix: "external.billing"
                # Results in: external.billing.events.>
            }

            # Import service — map to local subject
            {
                service: { account: AUTH_SVC, subject: "auth.validate" }
                to: "svc.auth.check"
                # Local code calls "svc.auth.check", routed to AUTH_SVC's "auth.validate"
            }
        ]
    }
}
```

### JWT-Based Exports/Imports (Operator Mode)

```bash
# Export from billing account
nsc add export --account billing --subject "billing.events.>" --service --name "billing-events"

# Import into orders account
nsc add import --account orders \
  --src-account billing \
  --remote-subject "billing.events.>" \
  --local-subject "ext.billing.events.>" \
  --name "billing-events"

# Push updated account JWTs
nsc push -A
```

---

## 8. WebSocket Gateway

NATS supports WebSocket connections natively — no proxy needed. Essential for browser clients.

### Server Configuration

```hcl
websocket {
    listen: "0.0.0.0:9222"

    # TLS is required for production WebSocket (browsers enforce wss://)
    tls {
        cert_file: "/etc/nats/certs/ws-cert.pem"
        key_file:  "/etc/nats/certs/ws-key.pem"
    }

    # Allow non-TLS for development only
    # no_tls: true

    # Compression (reduces bandwidth, adds CPU)
    compression: true

    # CORS headers for browser clients
    # same_origin: false
    # allowed_origins: ["https://app.example.com"]

    # JWT auth for WebSocket connections
    # jwt_cookie: "nats_jwt"

    # Handshake timeout
    handshake_timeout: "5s"
}
```

### Browser Client (JavaScript)

```javascript
import { connect, StringCodec } from "nats.ws";  // npm install nats.ws

const nc = await connect({
    servers: "wss://nats.example.com:9222",
    // Token auth
    // token: "my-token",
    // User/pass
    // user: "webapp", pass: "secret",
    // JWT + NKey (browser-compatible)
    // authenticator: credsAuthenticator(new TextEncoder().encode(credsFile)),
});

const sc = StringCodec();

// Subscribe
const sub = nc.subscribe("notifications.>");
(async () => {
    for await (const msg of sub) {
        console.log(`[${msg.subject}]: ${sc.decode(msg.data)}`);
    }
})();

// Publish
nc.publish("chat.room1", sc.encode(JSON.stringify({ user: "alice", text: "Hello!" })));

// Request/Reply
const resp = await nc.request("api.user.lookup", sc.encode('{"id":"u1"}'), { timeout: 5000 });
console.log("User:", sc.decode(resp.data));

// Drain on page unload
window.addEventListener("beforeunload", () => nc.drain());
```

### Extracting Auth from WebSocket Headers

Use `jwt_cookie` to accept a JWT from a browser cookie:

```hcl
websocket {
    listen: "0.0.0.0:9222"
    jwt_cookie: "nats_auth_token"
    no_tls: true  # dev only
}
```

The browser sets the cookie; NATS extracts the JWT automatically on WebSocket upgrade.

---

## 9. MQTT Bridge

NATS can act as a full MQTT 3.1.1 broker. MQTT clients connect directly — messages bridge to NATS subjects transparently.

### Server Configuration

```hcl
mqtt {
    listen: "0.0.0.0:1883"

    # TLS for MQTT
    # tls {
    #     cert_file: "/etc/nats/certs/mqtt-cert.pem"
    #     key_file:  "/etc/nats/certs/mqtt-key.pem"
    # }

    # Maximum number of MQTT connections
    # max_connections: 10000

    # Ack wait for QoS 1 messages
    ack_wait: "30s"

    # Maximum number of pending acks per session
    max_ack_pending: 100
}

# JetStream is required for MQTT QoS 1 and retained messages
jetstream {
    store_dir: "/data/jetstream"
}
```

### Subject Mapping: MQTT ↔ NATS

MQTT topics are automatically mapped to NATS subjects:
- MQTT `/` → NATS `.` (separator conversion)
- MQTT `+` → NATS `*` (single-level wildcard)
- MQTT `#` → NATS `>` (multi-level wildcard)

| MQTT Topic | NATS Subject |
|-----------|-------------|
| `devices/temp/sensor1` | `devices.temp.sensor1` |
| `devices/+/sensor1` | `devices.*.sensor1` |
| `devices/#` | `devices.>` |

### Bidirectional Communication

```python
# Python NATS client subscribing to MQTT-published messages
nc = await nats.connect("nats://localhost:4222")

# MQTT client publishes to "devices/temp/sensor1"
# NATS subscriber receives on "devices.temp.sensor1"
sub = await nc.subscribe("devices.temp.*")
async for msg in sub.messages:
    print(f"Sensor data: {msg.data.decode()}")
```

```python
# MQTT client (paho-mqtt)
import paho.mqtt.client as mqtt

client = mqtt.Client()
client.connect("localhost", 1883)

# This message is available to NATS subscribers on "devices.temp.sensor1"
client.publish("devices/temp/sensor1", '{"value": 23.5}', qos=1)
```

### MQTT QoS Mapping

| MQTT QoS | NATS Behavior |
|----------|--------------|
| QoS 0 | Core NATS pub/sub (fire-and-forget) |
| QoS 1 | JetStream persisted with at-least-once delivery |
| QoS 2 | Not supported (downgraded to QoS 1) |

---

## 10. Request/Reply at Scale

### Scatter-Gather Pattern

Send a request to multiple responders and collect all replies:

```go
// Create unique inbox
inbox := nats.NewInbox()
responses := make(chan *nats.Msg, 100)

// Subscribe to replies before publishing
sub, _ := nc.ChanSubscribe(inbox, responses)
defer sub.Unsubscribe()

// Publish request with reply inbox (no queue group → all subscribers get it)
nc.PublishRequest("pricing.quote", inbox, []byte(`{"sku":"WIDGET-100"}`))

// Collect responses with timeout
timeout := time.After(3 * time.Second)
var quotes []*nats.Msg
for {
    select {
    case msg := <-responses:
        quotes = append(quotes, msg)
    case <-timeout:
        goto done
    }
}
done:
log.Printf("Received %d pricing quotes", len(quotes))
```

### Request with Headers for Routing

```go
// Requester adds routing hints
msg := &nats.Msg{
    Subject: "compute.transform",
    Reply:   nc.NewRespInbox(),
    Data:    payload,
    Header: nats.Header{
        "X-Priority": []string{"high"},
        "X-Region":   []string{"us-east"},
    },
}
resp, _ := nc.RequestMsg(msg, 10*time.Second)
```

### Request/Reply with Queue Groups (Load-Balanced Services)

```go
// Service instances — only one handles each request
for i := 0; i < workerCount; i++ {
    nc.QueueSubscribe("svc.orders.validate", "validators", func(m *nats.Msg) {
        result := validateOrder(m.Data)
        m.Respond(result)
    })
}

// Client — sends request, gets one reply
resp, err := nc.Request("svc.orders.validate", orderData, 5*time.Second)
```

### Chunked Responses (Large Replies)

For responses too large for a single message:

```go
// Responder: send chunked reply
func handleLargeQuery(m *nats.Msg) {
    results := queryDatabase()
    for i, chunk := range chunkSlice(results, 100) {
        data, _ := json.Marshal(chunk)
        msg := &nats.Msg{
            Subject: m.Reply,
            Data:    data,
            Header:  nats.Header{
                "X-Chunk-Index": []string{strconv.Itoa(i)},
                "X-Chunk-Total": []string{strconv.Itoa(len(chunks))},
            },
        }
        nc.PublishMsg(msg)
    }
}
```

---

## 11. Header-Based Routing

NATS headers (2.2+) enable metadata-driven routing without encoding routing info in subjects.

### Priority-Based Processing

```go
// Publisher: tag messages with priority
msg := &nats.Msg{
    Subject: "tasks.process",
    Data:    taskPayload,
    Header: nats.Header{
        "X-Priority":    []string{"critical"},
        "X-Retry-Count": []string{"0"},
        "X-Tenant":      []string{"acme-corp"},
        "X-Schema-Ver":  []string{"3"},
    },
}
nc.PublishMsg(msg)

// Consumer: route based on header
nc.Subscribe("tasks.process", func(m *nats.Msg) {
    priority := m.Header.Get("X-Priority")
    switch priority {
    case "critical":
        handleCritical(m)
    case "high":
        handleHigh(m)
    default:
        handleNormal(m)
    }
})
```

### Content-Type Negotiation

```go
// Publisher specifies format
msg.Header.Set("Content-Type", "application/protobuf")
msg.Header.Set("X-Schema", "order.v2.OrderCreated")

// Consumer handles multiple formats
func handler(m *nats.Msg) {
    switch m.Header.Get("Content-Type") {
    case "application/protobuf":
        decodeProtobuf(m.Data)
    case "application/json":
        decodeJSON(m.Data)
    default:
        log.Printf("Unknown content type: %s", m.Header.Get("Content-Type"))
        m.Nak() // negative ack for redelivery to another consumer
    }
}
```

### Trace Context Propagation (OpenTelemetry)

```go
import "go.opentelemetry.io/otel/propagation"

// Inject trace context into NATS headers
func injectTrace(ctx context.Context, msg *nats.Msg) {
    carrier := propagation.MapCarrier{}
    otel.GetTextMapPropagator().Inject(ctx, carrier)
    for k, v := range carrier {
        msg.Header.Set(k, v)
    }
}

// Extract trace context from NATS headers
func extractTrace(msg *nats.Msg) context.Context {
    carrier := propagation.MapCarrier{}
    for key := range msg.Header {
        carrier.Set(key, msg.Header.Get(key))
    }
    return otel.GetTextMapPropagator().Extract(context.Background(), carrier)
}
```

---

## 12. Exactly-Once Processing Patterns

Combining publisher dedup, consumer idempotency, and double-ack for exactly-once semantics.

### Full Pattern

```go
// 1. Publisher dedup: same Nats-Msg-Id → stored only once
msg := &nats.Msg{
    Subject: "payments.charge",
    Data:    chargeJSON,
    Header:  nats.Header{"Nats-Msg-Id": []string{chargeID}},
}
pubAck, _ := js.PublishMsg(msg, nats.ExpectLastSequence(expectedSeq))
// ExpectLastSequence adds optimistic concurrency control

// 2. Consumer idempotency: track processed IDs
func processCharge(m jetstream.Msg) {
    msgID := m.Headers().Get("Nats-Msg-Id")

    // Idempotency check against your store (Redis, DB, KV)
    if alreadyProcessed(msgID) {
        m.Ack() // Ack without reprocessing
        return
    }

    // Process in a transaction
    err := db.WithTx(func(tx *sql.Tx) error {
        if err := applyCharge(tx, m.Data()); err != nil {
            return err
        }
        return markProcessed(tx, msgID) // Same transaction
    })

    if err != nil {
        m.Nak() // Negative ack → redelivery
        return
    }

    // 3. Double-ack: wait for server confirmation
    m.DoubleAck(context.Background())
}
```

### Optimistic Concurrency with Expected Sequence

```go
// Publish only if stream is at expected sequence (prevents duplicates from races)
ack, err := js.PublishMsg(msg,
    nats.ExpectLastSequence(42),          // Fail if last seq != 42
    nats.ExpectLastMsgId("prev-msg-id"),  // Fail if last msg ID doesn't match
    nats.ExpectStream("PAYMENTS"),        // Fail if wrong stream
)
if err != nil {
    // Handle conflict — another publisher wrote first
}
```

---

## 13. Dead Letter Queues

NATS doesn't have built-in DLQ, but you can implement it with `MaxDeliver` + advisory subscriptions.

### Implementation

```go
// Stream with consumer that limits redelivery
js.AddStream(&nats.StreamConfig{
    Name:     "ORDERS",
    Subjects: []string{"orders.>"},
})

// DLQ stream for failed messages
js.AddStream(&nats.StreamConfig{
    Name:     "ORDERS_DLQ",
    Subjects: []string{"dlq.orders.>"},
})

// Consumer with max delivery limit
js.AddConsumer("ORDERS", &nats.ConsumerConfig{
    Durable:    "order-processor",
    AckPolicy:  nats.AckExplicitPolicy,
    MaxDeliver: 5,
    FilterSubject: "orders.>",
})

// Subscribe to max-delivery advisory → move to DLQ
nc.Subscribe("$JS.EVENT.ADVISORY.CONSUMER.MAX_DELIVERIES.ORDERS.order-processor",
    func(m *nats.Msg) {
        var advisory struct {
            Stream   string `json:"stream"`
            Consumer string `json:"consumer"`
            StreamSeq uint64 `json:"stream_seq"`
        }
        json.Unmarshal(m.Data, &advisory)

        // Fetch the original message from the stream by sequence
        rawMsg, _ := js.GetMsg("ORDERS", advisory.StreamSeq)

        // Republish to DLQ with original metadata
        dlqMsg := &nats.Msg{
            Subject: "dlq." + rawMsg.Subject,
            Data:    rawMsg.Data,
            Header:  rawMsg.Header,
        }
        dlqMsg.Header.Set("X-Original-Subject", rawMsg.Subject)
        dlqMsg.Header.Set("X-Original-Sequence", strconv.FormatUint(advisory.StreamSeq, 10))
        dlqMsg.Header.Set("X-Failure-Reason", "max_deliveries_exceeded")
        js.PublishMsg(dlqMsg)
    },
)
```

---

## 14. Multi-Stream Workflows

### Saga Pattern with JetStream

```go
// Each step publishes to the next stream
// Step 1: Order created → payment stream
js.Publish("orders.created", orderJSON,
    nats.MsgId(orderID+"-created"))

// Payment service consumes orders.created, publishes result
js.Subscribe("orders.created", func(m jetstream.Msg) {
    result := processPayment(m.Data())
    if result.Success {
        js.Publish("payments.completed", result.JSON(),
            nats.MsgId(orderID+"-paid"))
    } else {
        // Compensating action: publish rollback event
        js.Publish("orders.cancelled", cancelJSON,
            nats.MsgId(orderID+"-cancel"))
    }
    m.Ack()
})

// Inventory service consumes payments.completed
// Shipping service consumes inventory.reserved
// Each step can trigger compensating transactions on failure
```

### Event Sourcing with KV for Snapshots

```go
// Events in a stream
js.AddStream(&nats.StreamConfig{
    Name:     "ACCOUNT_EVENTS",
    Subjects: []string{"account.events.>"},
})

// Snapshots in KV
kv, _ := js.CreateKeyValue(&nats.KeyValueConfig{
    Bucket:  "account-snapshots",
    History: 3,
})

// Build aggregate from events, snapshot periodically
func rebuildAccount(accountID string) *Account {
    // Try snapshot first
    if entry, err := kv.Get("account." + accountID); err == nil {
        var acct Account
        json.Unmarshal(entry.Value(), &acct)
        // Replay events after snapshot sequence
        // ...
        return &acct
    }
    // No snapshot — replay all events
    // ...
}
```
