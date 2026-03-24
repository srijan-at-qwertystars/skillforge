---
name: cqrs-event-sourcing
description: >
  Guide for implementing CQRS (Command Query Responsibility Segregation) and Event Sourcing patterns.
  Covers aggregate design, command/event handlers, event stores, projections, snapshots, sagas,
  eventual consistency, idempotency, event versioning/upcasting, and testing.
  TRIGGER when: user mentions "CQRS", "event sourcing", "event store", "command query separation",
  "event replay", "aggregate root", "domain events", "projections", "read model", "write model",
  "command handler", "event handler", "process manager", "saga pattern" with event sourcing.
  NOT for simple CRUD apps, NOT for traditional ORM patterns, NOT for message queues without
  event sourcing, NOT for basic pub/sub messaging, NOT for REST API design without CQRS context.
---

# CQRS and Event Sourcing

## Core Concepts

### CQRS — Command Query Responsibility Segregation
- Separate write model (commands) from read model (queries) at the application level.
- Commands mutate state, return void or an acknowledgment. Queries return data, never mutate.
- Write model enforces invariants; read model is denormalized for fast queries.
- Can be applied without Event Sourcing (use separate DB tables/views for reads).

### Event Sourcing
- Persist state as an ordered sequence of immutable domain events, not as current-state rows.
- Reconstruct aggregate state by replaying events from the event store.
- Events are facts — never delete or mutate them.
- Event store is the single source of truth; read models are derived projections.

### When They Combine
- CQRS provides the architectural split; Event Sourcing provides the persistence mechanism.
- Commands → Aggregate → Events → Event Store (write side).
- Events → Projections → Read Store (read side, eventually consistent).

## Architecture Rules

### Aggregates
- An aggregate is a consistency boundary. One command targets one aggregate.
- Aggregate loads its history (replay events), validates the command, emits new events.
- Keep aggregates small — split when they grow beyond 5-7 event types.
- Never access external services or other aggregates inside an aggregate.

### Command Handlers
- Accept a command, load the aggregate, invoke behavior, persist new events.
- Validate authorization and basic input before calling the aggregate.
- Make handlers idempotent: use command IDs to detect and reject duplicates.

### Event Handlers / Projections
- Subscribe to events and update denormalized read models.
- Each projection serves one query use case — create as many as needed.
- Projections must be rebuildable from scratch by replaying all events.
- Handle events idempotently (use event position/sequence for deduplication).

### Sagas / Process Managers
- Coordinate multi-aggregate workflows by reacting to events and issuing commands.
- Maintain their own state (which events have been seen, which steps completed).
- Implement compensating actions for failure scenarios.
- Every step must be idempotent and retriable.

### Event Store
- Append-only, immutable log of events per aggregate stream.
- Each event: `stream_id`, `event_type`, `data`, `metadata`, `version`, `timestamp`.
- Use optimistic concurrency: expect a specific version when appending.
- Partition streams by aggregate ID for scalability.

### Snapshots
- Periodically serialize aggregate state to avoid replaying thousands of events.
- Store snapshot version alongside; on load: restore snapshot + replay events after it.
- Take snapshots every N events (e.g., 50-100) or on a schedule.
- Snapshots are an optimization — system must work without them.

### Event Versioning and Upcasting
- Version every event schema (e.g., `OrderCreated_v1`, `OrderCreated_v2`).
- Never change the meaning of an existing event — create a new version.
- Implement upcasters: transform old event versions to latest on read.
- Use weak schema (add optional fields) to minimize breaking changes.

### Idempotency
- Commands: deduplicate using a unique command/correlation ID.
- Events: consumers track last-processed position; skip already-seen events.
- Projections: use upsert semantics or check event sequence before applying.

### Eventual Consistency
- Read models lag behind write model — design UIs for this (optimistic UI, polling).
- Measure and monitor projection lag in production.
- For user-facing writes, consider returning the command result directly (write-through).
- Never query the read model inside a command handler.

## Implementation Patterns

### TypeScript — Aggregate + Command Handler

```typescript
// --- Domain Events ---
interface DomainEvent {
  readonly type: string;
  readonly data: Record<string, unknown>;
  readonly metadata: { timestamp: string; version: number };
}

interface OrderCreated extends DomainEvent {
  type: 'OrderCreated';
  data: { orderId: string; customerId: string; items: Array<{ sku: string; qty: number }> };
}

interface OrderConfirmed extends DomainEvent {
  type: 'OrderConfirmed';
  data: { orderId: string; confirmedAt: string };
}

// --- Aggregate ---
class OrderAggregate {
  private status: 'draft' | 'confirmed' | 'cancelled' = 'draft';
  private uncommitted: DomainEvent[] = [];

  static rehydrate(events: DomainEvent[]): OrderAggregate {
    const agg = new OrderAggregate();
    events.forEach(e => agg.apply(e, false));
    return agg;
  }

  create(cmd: { orderId: string; customerId: string; items: Array<{ sku: string; qty: number }> }) {
    if (this.status !== 'draft') throw new Error('Order already created');
    this.apply({
      type: 'OrderCreated',
      data: { orderId: cmd.orderId, customerId: cmd.customerId, items: cmd.items },
      metadata: { timestamp: new Date().toISOString(), version: 1 },
    });
  }

  confirm() {
    if (this.status !== 'draft') throw new Error('Cannot confirm');
    this.apply({
      type: 'OrderConfirmed',
      data: { orderId: '', confirmedAt: new Date().toISOString() },
      metadata: { timestamp: new Date().toISOString(), version: 1 },
    });
  }

  private apply(event: DomainEvent, isNew = true) {
    switch (event.type) {
      case 'OrderCreated': this.status = 'draft'; break;
      case 'OrderConfirmed': this.status = 'confirmed'; break;
    }
    if (isNew) this.uncommitted.push(event);
  }

  getUncommitted(): DomainEvent[] { return [...this.uncommitted]; }
}

// --- Command Handler ---
class ConfirmOrderHandler {
  constructor(private eventStore: EventStore) {}

  async execute(cmd: { orderId: string; commandId: string }) {
    if (await this.eventStore.isDuplicate(cmd.commandId)) return; // idempotency
    const events = await this.eventStore.load(cmd.orderId);
    const order = OrderAggregate.rehydrate(events);
    order.confirm();
    await this.eventStore.append(cmd.orderId, order.getUncommitted(), events.length);
  }
}
```

### Python — Event Store + Projection

```python
import json
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any

@dataclass(frozen=True)
class Event:
    stream_id: str
    event_type: str
    data: dict[str, Any]
    version: int
    timestamp: str = field(default_factory=lambda: datetime.now(timezone.utc).isoformat())

class EventStore:
    """Append-only in-memory event store with optimistic concurrency."""
    def __init__(self):
        self._streams: dict[str, list[Event]] = {}

    def append(self, stream_id: str, events: list[Event], expected_version: int) -> None:
        stream = self._streams.setdefault(stream_id, [])
        if len(stream) != expected_version:
            raise ConcurrencyError(f"Expected {expected_version}, got {len(stream)}")
        stream.extend(events)

    def load(self, stream_id: str) -> list[Event]:
        return list(self._streams.get(stream_id, []))

class ConcurrencyError(Exception):
    pass

# --- Projection ---
class OrderSummaryProjection:
    """Builds a read model from events. Rebuildable from scratch."""
    def __init__(self):
        self.orders: dict[str, dict] = {}

    def handle(self, event: Event) -> None:
        if event.event_type == "OrderCreated":
            self.orders[event.stream_id] = {
                "id": event.stream_id,
                "customer": event.data["customer_id"],
                "status": "draft",
                "item_count": len(event.data["items"]),
            }
        elif event.event_type == "OrderConfirmed":
            if event.stream_id in self.orders:
                self.orders[event.stream_id]["status"] = "confirmed"

    def rebuild(self, store: EventStore, stream_ids: list[str]) -> None:
        self.orders.clear()
        for sid in stream_ids:
            for event in store.load(sid):
                self.handle(event)
```

### Java — Axon Framework Aggregate (Spring Boot)

```java
@Aggregate
public class OrderAggregate {
    @AggregateIdentifier
    private String orderId;
    private String status;

    @CommandHandler
    public OrderAggregate(CreateOrderCommand cmd) {
        AggregateLifecycle.apply(new OrderCreatedEvent(cmd.getOrderId(), cmd.getCustomerId()));
    }

    @EventSourcingHandler
    public void on(OrderCreatedEvent event) {
        this.orderId = event.getOrderId();
        this.status = "CREATED";
    }

    @CommandHandler
    public void handle(ConfirmOrderCommand cmd) {
        if (!"CREATED".equals(this.status)) throw new IllegalStateException("Cannot confirm");
        AggregateLifecycle.apply(new OrderConfirmedEvent(this.orderId));
    }

    @EventSourcingHandler
    public void on(OrderConfirmedEvent event) {
        this.status = "CONFIRMED";
    }
}
```

### C# — Marten Event Store

```csharp
// Aggregate
public class Order {
    public Guid Id { get; private set; }
    public string Status { get; private set; } = "Draft";

    public void Apply(OrderCreated e) { Id = e.OrderId; Status = "Draft"; }
    public void Apply(OrderConfirmed e) { Status = "Confirmed"; }
}

// Command handler using Marten
public class ConfirmOrderHandler {
    private readonly IDocumentSession _session;

    public async Task Handle(ConfirmOrder cmd) {
        var stream = await _session.Events.FetchStreamAsync(cmd.OrderId);
        var order = stream.Aggregate<Order>();
        if (order.Status != "Draft") throw new InvalidOperationException();
        _session.Events.Append(cmd.OrderId, new OrderConfirmed(cmd.OrderId));
        await _session.SaveChangesAsync();
    }
}
```

## Event Versioning Example

```typescript
// Upcaster: transform v1 events to v2 on read
function upcast(event: StoredEvent): DomainEvent {
  if (event.type === 'OrderCreated' && event.version === 1) {
    return {
      type: 'OrderCreated',
      data: {
        ...event.data,
        currency: event.data.currency ?? 'USD', // added in v2
      },
      metadata: { ...event.metadata, version: 2 },
    };
  }
  return event;
}
```

## Testing Event-Sourced Systems

### Given-When-Then Pattern
Test aggregates in isolation using event-based assertions:

```typescript
describe('OrderAggregate', () => {
  it('should confirm a draft order', () => {
    // Given: order was created
    const history = [orderCreatedEvent({ orderId: '1', customerId: 'c1', items: [] })];
    const order = OrderAggregate.rehydrate(history);

    // When: confirm
    order.confirm();

    // Then: OrderConfirmed event emitted
    const uncommitted = order.getUncommitted();
    expect(uncommitted).toHaveLength(1);
    expect(uncommitted[0].type).toBe('OrderConfirmed');
  });

  it('should reject confirming an already confirmed order', () => {
    const history = [
      orderCreatedEvent({ orderId: '1', customerId: 'c1', items: [] }),
      orderConfirmedEvent({ orderId: '1' }),
    ];
    const order = OrderAggregate.rehydrate(history);
    expect(() => order.confirm()).toThrow('Cannot confirm');
  });
});
```

### Projection Tests
```python
def test_order_summary_projection():
    proj = OrderSummaryProjection()
    proj.handle(Event("order-1", "OrderCreated", {"customer_id": "c1", "items": [{"sku": "A"}]}, 1))
    assert proj.orders["order-1"]["status"] == "draft"
    assert proj.orders["order-1"]["item_count"] == 1

    proj.handle(Event("order-1", "OrderConfirmed", {}, 2))
    assert proj.orders["order-1"]["status"] == "confirmed"
```

## Framework Selection Guide

| Framework    | Language | Event Store    | Aggregates | Projections | Snapshots | Upcasting |
|-------------|----------|---------------|------------|-------------|-----------|-----------|
| Axon        | Java     | Axon Server   | Built-in   | Async/sync  | Yes       | Yes       |
| EventStoreDB| Any (gRPC)| Native       | App-level  | Built-in    | Yes       | App-level |
| Marten      | C#       | PostgreSQL    | Built-in   | Rich        | Yes       | Yes       |
| Eventuous   | C#       | Pluggable     | Built-in   | Yes         | Yes       | Yes       |

## When NOT to Use CQRS/Event Sourcing

**Do not use when:**
- Application is simple CRUD with no complex domain logic.
- Team lacks experience — the learning curve is steep; start with simpler patterns.
- Strong consistency is non-negotiable and cannot tolerate eventual consistency.
- Read/write ratio does not justify separate models.
- No audit trail or temporal query requirements exist.
- Domain has no complex invariants or cross-aggregate workflows.

**Prefer instead:**
- Standard CRUD with ORM for simple domains.
- Change Data Capture (CDC) for audit needs without full event sourcing.
- CQRS without Event Sourcing (separate read/write DBs) for scaling reads only.
- Domain Events without full sourcing for decoupled communication.

## Checklist: Production Readiness

- [ ] Events are immutable and versioned with upcasters for schema evolution.
- [ ] Command handlers are idempotent (deduplicate by command ID).
- [ ] Event handlers / projections are idempotent (track position).
- [ ] Projections are rebuildable from the full event log.
- [ ] Snapshot strategy defined for long-lived aggregates.
- [ ] Concurrency control via optimistic locking on stream version.
- [ ] Monitoring: projection lag, event store throughput, failed handlers.
- [ ] Dead letter queue for events that fail processing.
- [ ] Integration tests use Given-When-Then on real aggregate replay.
- [ ] Saga compensating actions tested for all failure paths.

## Input/Output Examples

**Input:** "Implement an event-sourced order aggregate in TypeScript"
**Output:** Aggregate class with `rehydrate()`, command methods emitting typed events, `apply()` for state transitions, `getUncommitted()` for persistence. Command handler loading stream, calling aggregate, appending events with optimistic concurrency.

**Input:** "Add a projection for order search"
**Output:** Event handler subscribing to `OrderCreated`, `OrderConfirmed`, `OrderCancelled` events, upserting into a denormalized search-optimized read model (e.g., Elasticsearch or SQL view), with position tracking for idempotency and a `rebuild()` method.

**Input:** "How do I handle event schema changes?"
**Output:** Version events (`OrderCreated_v1` → `OrderCreated_v2`), implement an upcaster function that transforms v1 → v2 on read by adding default values for new fields. Never mutate stored events. Register upcasters in the deserialization pipeline.

**Input:** "Design a saga for order fulfillment"
**Output:** Process manager listening to `OrderConfirmed` → sends `ReserveInventory` command → on `InventoryReserved` → sends `ProcessPayment` → on `PaymentProcessed` → sends `ShipOrder`. On `PaymentFailed` → sends `ReleaseInventory` (compensating action). Each step idempotent with correlation ID tracking.

## Supplementary Materials

### References (Deep-Dive Guides)

| File | Contents |
|------|----------|
| `references/advanced-patterns.md` | Process managers/sagas (orchestration vs choreography, compensation), event-driven microservices (outbox pattern, integration events), CQRS with GraphQL, multi-tenant event stores, DDD tactical patterns with ES, read model rebuilding strategies (blue-green), event store partitioning, temporal/bitemporal queries, crypto-shredding for GDPR |
| `references/troubleshooting.md` | Diagnosing and fixing: event versioning hell (upcaster chains), projection lag (batching, parallelization, DLQ), idempotency failures (dedup keys, optimistic concurrency), aggregate boundary mistakes (sizing heuristics, splitting), eventual consistency debugging (reservation pattern), snapshot corruption (versioned recovery), event ordering issues (gap detection), split-brain scenarios (quorum, fencing tokens) |
| `references/framework-comparison.md` | EventStoreDB vs Axon Framework vs Marten vs Eventuous vs Custom — feature matrix, performance benchmarks, language support, hosting options, licensing, community maturity, decision tree, migration paths |

### Scripts (Executable Helpers)

| File | Purpose |
|------|---------|
| `scripts/event-store-setup.sh` | Set up EventStoreDB locally via Docker with all projections enabled. Commands: `start`, `stop`, `status`, `logs`. Health-check polling included. |
| `scripts/replay-events.sh` | Template for replaying events to rebuild projections. Supports `--projection`, `--from-position`, `--batch-size`, `--dry-run`. Customization points marked with TODO. |
| `scripts/generate-aggregate.sh` | Scaffold a complete aggregate: events, commands, aggregate root, command handler, and test file. Supports TypeScript (`--lang ts`) and Python (`--lang py`). Custom events via `--events`. |

### Assets (Templates and Configs)

| File | Contents |
|------|----------|
| `assets/aggregate-template.ts` | TypeScript aggregate root with rehydration, snapshot support, command methods with invariant enforcement, event application |
| `assets/event-store-schema.sql` | PostgreSQL schema: events table with optimistic concurrency function, snapshots, projection checkpoints, outbox, dead-letter queue, command deduplication, NOTIFY trigger, utility views |
| `assets/projection-template.ts` | Read model projection handler with idempotent batch processing, checkpointing, rebuild support, example OrderSummaryProjection |
| `assets/saga-template.ts` | Process manager/saga with full state machine: OrderConfirmed → ReserveInventory → ProcessPayment → ShipOrder, compensation paths, timeout handling |
| `assets/docker-compose.yml` | EventStoreDB + PostgreSQL dev environment with health checks, auto-applied schema, persistent volumes |

<!-- tested: pass -->
