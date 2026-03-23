---
name: event-driven-architecture
description:
  positive: "Use when user designs event-driven systems, asks about event sourcing, CQRS, saga pattern (orchestration vs choreography), outbox pattern, idempotent consumers, domain events, or event schema evolution."
  negative: "Do NOT use for Kafka-specific configuration (use kafka-event-streaming skill), message queue setup, or synchronous request-response API design."
---

# Event-Driven Architecture

## Fundamentals: Events vs Commands vs Queries

Distinguish three message types — conflating them causes architectural confusion.

| Type    | Intent               | Direction       | Naming       | Example            |
|---------|----------------------|-----------------|--------------|--------------------|
| Event   | Notify what happened | Publisher → N   | Past tense   | `OrderPlaced`      |
| Command | Request an action    | Sender → 1      | Imperative   | `PlaceOrder`       |
| Query   | Request data         | Requester → 1   | Question     | `GetOrderStatus`   |

```
  Command               Event                   Query
  ┌──────┐   ┌──────┐   ┌──────┐   ┌──────┐   ┌──────┐   ┌──────┐
  │Sender│──▶│Target│   │Source│──▶│Fan-  │   │Caller│──▶│Read  │
  └──────┘   └──────┘   └──────┘   │out   │   └──────┘   │Model │
                                    └──┬───┘              └──────┘
                                  ┌────┼────┐
                                  ▼    ▼    ▼
                                 S1   S2   S3
```

- Events are immutable facts. Never modify a published event.
- Commands target a single handler. Return success/failure.
- Queries never mutate state.

## Event Types

**Domain events** — internal to a bounded context, carry rich business semantics:
```typescript
interface OrderPlaced {
  type: "OrderPlaced";
  aggregateId: string;
  version: number;
  data: { orderId: string; customerId: string; items: OrderItem[]; totalAmount: number };
  metadata: { correlationId: string; causationId: string; timestamp: string; userId: string };
}
```

**Integration events** — cross bounded-context. Keep payloads minimal, avoid leaking internals:
```typescript
interface OrderPlacedIntegration {
  type: "integration.order.placed.v1";
  orderId: string;
  customerId: string;
  totalAmount: number;
  occurredAt: string;
}
```

**Notification events** — signal without state. Consumers query the source for details. Use when payloads are large or change frequently.

## Event Sourcing

Store state as an append-only sequence of events instead of mutable rows.

```
┌──────────────────────────────────────────────────┐
│                   Event Store                    │
├─────┬─────────────┬─────────┬────────────────────┤
│ Seq │ AggregateId │ Version │ Event              │
├─────┼─────────────┼─────────┼────────────────────┤
│ 1   │ order-123   │ 1       │ OrderCreated       │
│ 2   │ order-123   │ 2       │ ItemAdded          │
│ 3   │ order-123   │ 3       │ OrderConfirmed     │
└─────┴─────────────┴─────────┴────────────────────┘
```

### Rebuilding State
```typescript
function rebuildOrder(events: OrderEvent[]): OrderState {
  return events.reduce((state, event) => {
    switch (event.type) {
      case "OrderCreated":
        return { ...state, id: event.data.orderId, status: "created", items: [] };
      case "ItemAdded":
        return { ...state, items: [...state.items, event.data.item] };
      case "OrderConfirmed":
        return { ...state, status: "confirmed" };
      default: return state;
    }
  }, {} as OrderState);
}
```

### Snapshots

Take periodic snapshots to avoid replaying the full event stream.
```typescript
async function loadAggregate(id: string): Promise<OrderState> {
  const snapshot = await store.getLatestSnapshot(id);
  const events = await store.getEvents(id, { afterVersion: snapshot?.version ?? 0 });
  return events.reduce(applyEvent, snapshot?.state ?? {});
}
```
- Take snapshots every N events (e.g., 100) or on a schedule.
- Store snapshots separately from the event stream.
- Validate snapshot + replay matches full replay.

### Projections

Build read-optimized views by processing the event stream.
```
┌──────────────┐     ┌─────────────────┐     ┌─────────────────┐
│ Event Store  │────▶│ OrderSummary    │────▶│ orders_summary  │
│              │     │ Projector       │     │ (PostgreSQL)    │
└──────────────┘     └─────────────────┘     └─────────────────┘
               ────▶ CustomerOrders Projector ──▶ (Elasticsearch)
```
Projections are disposable — rebuild them by replaying events from the store.

## CQRS (Command Query Responsibility Segregation)

Separate write and read paths into distinct models.

```
                   ┌─────────────┐
  Commands ───────▶│ Write Model │───────▶ Event Store
                   └─────────────┘              │
                                                ▼
                                         ┌────────────┐
                                         │ Event Bus  │
                                         └─────┬──────┘
                   ┌─────────────┐              │
  Queries ────────▶│ Read Model  │◀─────────────┘
                   └─────────────┘   (projections update async)
```

```typescript
// Command side — enforces invariants, emits events
class OrderCommandHandler {
  async handle(cmd: PlaceOrderCommand): Promise<void> {
    const order = await this.repository.load(cmd.orderId);
    order.place(cmd.items, cmd.customerId);
    await this.repository.save(order);
  }
}
// Query side — optimized for reads, eventually consistent
class OrderQueryHandler {
  async handle(query: GetOrderSummary): Promise<OrderSummaryDto> {
    return this.readDb.query("SELECT * FROM order_summaries WHERE order_id = $1", [query.orderId]);
  }
}
```

**Eventual consistency mitigation:**
- Return the write result directly to the issuing client (causal consistency).
- Poll or subscribe until read model reflects the change (read-your-writes).
- Include expected version in queries; return stale indicator if not caught up.

## Saga Patterns

Manage distributed transactions across services using compensating actions.

### Orchestration — central orchestrator drives the workflow

```
┌──────────────┐
│  Order Saga  │
│ Orchestrator │
└──────┬───────┘
       ├──▶ Reserve Inventory ──▶ Success
       ├──▶ Process Payment ───▶ Success
       ├──▶ Ship Order ────────▶ Success
       │    On failure at any step:
       ├──◀ Compensate: Release Inventory
       ├──◀ Compensate: Refund Payment
       └──◀ Compensate: Cancel Shipment
```

```typescript
class OrderSagaOrchestrator {
  private state: SagaState = "STARTED";
  async execute(orderId: string): Promise<void> {
    try {
      await this.inventoryService.reserve(orderId);
      this.state = "INVENTORY_RESERVED";
      await this.paymentService.charge(orderId);
      this.state = "PAYMENT_PROCESSED";
      await this.shippingService.ship(orderId);
      this.state = "COMPLETED";
    } catch {
      await this.compensate(orderId);
    }
  }
  private async compensate(orderId: string): Promise<void> {
    switch (this.state) {
      case "PAYMENT_PROCESSED": await this.paymentService.refund(orderId); // fall through
      case "INVENTORY_RESERVED": await this.inventoryService.release(orderId);
    }
    this.state = "COMPENSATED";
  }
}
```

### Choreography — each service reacts to events autonomously

```
OrderService         InventoryService      PaymentService
     │                      │                     │
     │──OrderPlaced───────▶│                     │
     │                      │──InventoryReserved─▶│
     │                      │                     │──PaymentCharged──▶...
     │             On failure (PaymentFailed):    │
     │                      │◀─PaymentFailed──────│
     │◀─InventoryReleased──│                     │
```

| Factor      | Orchestration                | Choreography              |
|-------------|------------------------------|---------------------------|
| Complexity  | Central, explicit flow       | Distributed, implicit     |
| Coupling    | Orchestrator knows services  | Services are independent  |
| Visibility  | Single place to monitor      | Requires distributed trace|
| Best for    | Complex multi-step workflows | Simple reactive pipelines |

Use state machines to model saga states. Persist saga state to survive crashes.

## Outbox Pattern

Guarantee atomicity between local DB writes and event publishing.

```
┌─────────────────────────────────────────┐
│            Service Database             │
│  ┌──────────────┐  ┌────────────────┐   │
│  │ orders       │  │ outbox         │   │
│  │ (business)   │  │ (events)       │   │
│  └──────────────┘  └───────┬────────┘   │
│        SINGLE TRANSACTION  │            │
└────────────────────────────┼────────────┘
                             ▼
                  ┌────────────────────┐
                  │  Relay / Publisher  │
                  │  (Polling or CDC)  │
                  └─────────┬──────────┘
                            ▼
                     ┌─────────────┐
                     │ Event Broker│
                     └─────────────┘
```

```typescript
async function placeOrder(order: Order): Promise<void> {
  await db.transaction(async (tx) => {
    await tx.insert("orders", order);
    await tx.insert("outbox", {
      id: uuid(), aggregateType: "Order", aggregateId: order.id,
      eventType: "OrderPlaced",
      payload: JSON.stringify({ orderId: order.id, items: order.items }),
      createdAt: new Date(), published: false,
    });
  });
}
// Polling publisher — runs on a schedule
async function publishOutboxEvents(): Promise<void> {
  const events = await db.query(
    "SELECT * FROM outbox WHERE published = false ORDER BY created_at LIMIT 100"
  );
  for (const event of events) {
    await broker.publish(event.eventType, event.payload);
    await db.update("outbox", { id: event.id }, { published: true });
  }
}
```

| Relay Strategy     | Mechanism                           | Trade-offs                       |
|--------------------|-------------------------------------|----------------------------------|
| Polling Publisher   | Periodically query outbox table    | Simple; adds DB load; latency    |
| CDC (Debezium)     | Stream DB transaction log to broker| Low latency; operational overhead|
| Listen/Notify      | DB triggers push to relay process  | DB-specific; moderate complexity |

Prefer CDC for high-throughput systems. Use polling for simplicity at lower scale.

## Event Schema Design

### Event Envelope — wrap every event in a standard structure

```typescript
interface EventEnvelope<T> {
  eventId: string;          // Unique event ID (UUID)
  eventType: string;        // e.g., "order.placed.v1"
  aggregateId: string;
  aggregateType: string;
  version: number;          // Schema version
  occurredAt: string;       // ISO 8601
  correlationId: string;    // Trace across services
  causationId: string;      // ID of causing event/command
  data: T;
}
```

### Versioning Strategies

**Backward compatible (safe):** Add optional fields with defaults. Deprecate but keep old fields.
**Breaking changes:** Publish new event type (`OrderPlaced.v2`). Run both versions in parallel during migration. Retire old version after all consumers migrate.

```
v1: { orderId, amount }
v2: { orderId, amount, currency }    ← optional field (backward compatible)
v3: { orderId, lineItems[] }         ← structural change (breaking → new type)
```

### Schema Registry Integration

Register schemas in CI/CD. Reject incompatible changes before deployment.
```yaml
- name: Validate schema compatibility
  run: |
    schema-registry-cli check \
      --subject "order-events-value" \
      --schema schemas/order-placed.avsc \
      --compatibility BACKWARD_TRANSITIVE
```

## Idempotent Consumers

Design consumers to safely handle duplicate deliveries.

```typescript
async function handleEvent(event: EventEnvelope<OrderPlaced>): Promise<void> {
  const existing = await db.query("SELECT 1 FROM processed_events WHERE event_id = $1", [event.eventId]);
  if (existing) return;
  await db.transaction(async (tx) => {
    await tx.insert("shipments", { orderId: event.data.orderId, status: "pending" });
    await tx.insert("processed_events", { eventId: event.eventId, processedAt: new Date() });
  });
}
```

| Strategy              | Mechanism                                | Use When                        |
|-----------------------|------------------------------------------|---------------------------------|
| Idempotency key table | Store processed event IDs in DB          | Default choice                  |
| Natural idempotency   | Use upsert/PUT semantics                 | State replacement operations    |
| Inbox pattern         | Consumer-side outbox for received events | Strong ordering guarantees      |
| TTL-based dedup store | Redis SET with expiry for event IDs      | High-throughput, bounded window |

- Always process event + record dedup marker in the same transaction.
- Set a TTL on the dedup store (e.g., 7 days) to bound storage growth.
- Make the business operation itself idempotent where possible (upserts over inserts).

## Ordering Guarantees and Partitioning

```
Topic: orders
┌─────────────┬─────────────┬─────────────┬─────────────┐
│ Partition 0 │ Partition 1 │ Partition 2 │ Partition 3 │
│ order-001   │ order-002   │ order-003   │ order-004   │
│ order-005   │ order-006   │ order-007   │ order-008   │
└─────────────┴─────────────┴─────────────┴─────────────┘
  Partition key = orderId → guarantees per-order ordering
```

- Partition by aggregate ID to guarantee per-entity ordering.
- Never rely on cross-partition ordering.
- Use sequence numbers within an aggregate for optimistic concurrency.
- Global ordering requires a single partition (kills throughput) — avoid it.

## Error Handling

### Dead Letter Queues
```
                  ┌──────────┐   Success   ┌──────────┐
  Event ────────▶│ Consumer │───────────▶│ Processed│
                  └────┬─────┘             └──────────┘
                       │ Failure (after N retries)
                       ▼
                  ┌──────────┐
                  │   DLQ    │──▶ Alert + Manual Review
                  └──────────┘
```

### Retry Policies and Circuit Breakers
```typescript
const retryPolicy = {
  maxRetries: 5,
  backoff: "exponential",     // 1s, 2s, 4s, 8s, 16s
  jitter: true,               // Avoid thundering herd
  retryableErrors: ["TIMEOUT", "SERVICE_UNAVAILABLE"],
  nonRetryable: ["VALIDATION_ERROR", "SCHEMA_MISMATCH"],
};

const circuitBreaker = new CircuitBreaker(paymentService.charge, {
  failureThreshold: 5,        // Open after 5 failures
  resetTimeout: 30_000,       // Half-open after 30s
});
// States: CLOSED (normal) → OPEN (failing) → HALF_OPEN (testing recovery)
```

- Separate transient errors (retry) from permanent errors (DLQ immediately).
- Monitor DLQ size — growth signals systemic problems.
- Provide tooling to replay DLQ events after root cause is fixed.

## Testing Event-Driven Systems

### Event Store Testing
```typescript
describe("Order aggregate", () => {
  it("emits OrderPlaced on valid order", () => {
    const order = new Order();
    order.place({ customerId: "c1", items: [{ sku: "A", qty: 2 }] });
    expect(order.uncommittedEvents).toEqual([
      expect.objectContaining({ type: "OrderPlaced", data: expect.objectContaining({ customerId: "c1" }) }),
    ]);
  });
  it("rejects duplicate placement", () => {
    const order = rebuildFrom([orderPlacedEvent]);
    expect(() => order.place({ customerId: "c1", items: [] })).toThrow("Order already placed");
  });
});
```

### Consumer Contract Tests
```typescript
describe("ShipmentConsumer contract", () => {
  it("handles OrderPlaced v1", async () => {
    const event = buildEvent("OrderPlaced", { orderId: "o1", items: [/*...*/] });
    await consumer.handle(event);
    expect((await db.get("shipments", "o1")).status).toBe("pending");
  });
  it("ignores unknown fields (forward compatibility)", async () => {
    const event = buildEvent("OrderPlaced", { orderId: "o1", items: [/*...*/], newField: "ignored" });
    await consumer.handle(event); // Must not throw
  });
});
```

### Integration Testing
```typescript
it("completes order flow end-to-end", async () => {
  await commandBus.send(new PlaceOrderCommand({ orderId: "o1", items }));
  await expectEventually(() => {
    const events = testEventStore.getEvents("o1");
    expect(events.map(e => e.type)).toEqual(["OrderPlaced", "InventoryReserved", "PaymentCharged", "OrderCompleted"]);
  });
  await expectEventually(() => expect(readModel.get("o1").status).toBe("completed"));
});
```

## Common Anti-Patterns

| Anti-Pattern | Problem | Fix |
|---|---|---|
| Event-carried state transfer overuse | Full entity state in every event; consumers cache stale copies | Use notification events + API queries, or publish only deltas |
| Lacking idempotency | Duplicates cause double charges, duplicate shipments | Implement idempotency key checks with transactional dedup |
| Too fine-grained events | `FieldXUpdated` per attribute creates event storms | Model meaningful domain events: `OrderShipped` not `OrderStatusFieldChanged` |
| Synchronous event handling | Blocking until all consumers finish defeats async purpose | Publish asynchronously; accept eventual consistency |
| Missing correlation IDs | Cannot trace operations across services | Propagate `correlationId`; set `causationId` to triggering event's ID |
| No schema evolution strategy | Breaking schema changes crash consumers in production | Schema registry with compatibility checks in CI; version types explicitly |
| Unbounded event replay | Replaying millions of events takes hours | Implement snapshots; checkpoint projections; archive old events |
| Ignoring aggregate ordering | `OrderShipped` processed before `OrderCreated` | Partition by aggregate ID; use sequence numbers; buffer out-of-order |

<!-- tested: pass -->
