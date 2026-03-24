# Advanced CQRS + Event Sourcing Patterns

> Dense reference for patterns beyond basic aggregate/command/event/projection setups.

## Table of Contents

- [1. Process Managers and Sagas](#1-process-managers-and-sagas)
- [2. Event-Driven Microservices with CQRS](#2-event-driven-microservices-with-cqrs)
- [3. CQRS with GraphQL](#3-cqrs-with-graphql)
- [4. Multi-Tenant Event Stores](#4-multi-tenant-event-stores)
- [5. Event Sourcing with DDD Tactical Patterns](#5-event-sourcing-with-ddd-tactical-patterns)
- [6. Read Model Rebuilding Strategies](#6-read-model-rebuilding-strategies)
- [7. Event Store Partitioning](#7-event-store-partitioning)
- [8. Temporal Queries](#8-temporal-queries)

---

## 1. Process Managers and Sagas

### Orchestration vs Choreography

| Aspect | Orchestration (Process Manager) | Choreography |
|--------|-------------------------------|--------------|
| Control | Central coordinator owns workflow | Each service reacts independently |
| Coupling | PM coupled to all participants | Services coupled only to events |
| Visibility | Single place to see workflow state | Trace across service logs |
| Failure handling | PM issues compensating commands | Each service compensates itself |
| Best for | Complex multi-step workflows | Simple event chains, ≤3 steps |

### Process Manager Implementation Rules

1. **State machine**: Model each saga as an explicit state machine with named states and allowed transitions.
2. **Correlation**: Use a `correlationId` on every command and event to link saga steps.
3. **Timeout handling**: Schedule timeout events. If step X doesn't complete within T, fire a timeout event that triggers compensation.
4. **Idempotent steps**: Every command the PM issues must be idempotent — the target aggregate deduplicates by `commandId`.
5. **Persist PM state as events**: The process manager itself is event-sourced. Its state = the events it has seen + commands it has issued.

### Compensation Patterns

```
Happy path:   OrderConfirmed → ReserveInventory → InventoryReserved → ChargePayment → PaymentCharged → ShipOrder
Compensation: PaymentFailed  → ReleaseInventory (undo step 2) → NotifyCustomer (terminal)
```

- **Backward recovery**: Undo completed steps in reverse order.
- **Forward recovery**: Retry failed step with exponential backoff before compensating.
- **Pivot transaction**: The step after which compensation is no longer possible (e.g., "shipped"). Design carefully.

### Saga vs Process Manager Terminology

- **Saga** (original paper): A sequence of local transactions with compensating transactions. No central coordinator.
- **Process Manager**: An explicit object that receives events, maintains state, and dispatches commands. Often called "saga" in frameworks like Axon and NServiceBus — but is technically orchestration.

---

## 2. Event-Driven Microservices with CQRS

### Architecture Topology

```
Service A (Write) ──events──→ Message Broker ──→ Service B (Read/Projection)
                                              ──→ Service C (Saga/PM)
                                              ──→ Service D (Analytics)
```

### Integration Event vs Domain Event

| Domain Event | Integration Event |
|---|---|
| Internal to bounded context | Published across service boundaries |
| Fine-grained, reflects aggregate state change | Coarse-grained, contracts between teams |
| Can change freely | Must be versioned, backward-compatible |
| Stored in event store | Published to broker (Kafka, RabbitMQ, SNS) |

### Outbox Pattern (Transactional Messaging)

Avoid dual-write problems (write to DB + publish to broker):

1. Write events to an `outbox` table in the same DB transaction as the event store append.
2. A background poller or CDC (Change Data Capture) reads the outbox and publishes to the broker.
3. Mark outbox entries as published. Consumers handle duplicates idempotently.

```sql
-- Outbox table (same DB as event store)
CREATE TABLE outbox (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  event_type  TEXT NOT NULL,
  payload     JSONB NOT NULL,
  created_at  TIMESTAMPTZ DEFAULT now(),
  published   BOOLEAN DEFAULT FALSE
);
```

### Event Ordering Guarantees

- **Per-aggregate ordering**: Essential. Use stream version / sequence number.
- **Cross-aggregate ordering**: Generally not guaranteed. Design projections to tolerate out-of-order cross-aggregate events.
- **Kafka**: Ordering within a partition. Key by aggregate ID to get per-aggregate ordering.
- **Global ordering**: Only EventStoreDB's `$all` stream provides this natively. Useful for projections that span aggregates.

---

## 3. CQRS with GraphQL

### Architecture

- **Mutations** = Commands → routed to command handlers → aggregate → events.
- **Queries** = Read from projections via GraphQL resolvers. Projections are purpose-built for query shapes.
- **Subscriptions** = Real-time event push via GraphQL subscriptions, backed by event store catch-up subscriptions.

### Design Rules

1. **Mutations are fire-and-forget or return correlation ID.** Don't return the updated entity — the projection may lag.
2. **Optimistic UI**: Return the command's correlation ID. Client polls or subscribes for the resulting event.
3. **Schema stitching**: Each projection can expose its own GraphQL subgraph. Federate with Apollo Gateway or similar.
4. **Batching**: Use DataLoader to batch projection reads within a single GraphQL request.

### Example Mutation

```graphql
type Mutation {
  confirmOrder(orderId: ID!, commandId: ID!): CommandResult!
}
type CommandResult {
  accepted: Boolean!
  correlationId: ID!
}
```

---

## 4. Multi-Tenant Event Stores

### Isolation Strategies

| Strategy | Isolation | Complexity | Cost |
|----------|-----------|------------|------|
| **Separate databases** per tenant | Full | High (ops overhead) | High |
| **Separate schemas** (PostgreSQL) | Strong | Medium | Medium |
| **Shared table, tenant column** | Logical | Low | Low |
| **Stream prefix** (EventStoreDB) | Logical | Low | Low |

### Implementation: Shared Table with Tenant Column

```sql
CREATE TABLE events (
  id          BIGSERIAL PRIMARY KEY,
  tenant_id   UUID NOT NULL,
  stream_id   TEXT NOT NULL,
  version     INT NOT NULL,
  event_type  TEXT NOT NULL,
  data        JSONB NOT NULL,
  metadata    JSONB NOT NULL,
  created_at  TIMESTAMPTZ DEFAULT now(),
  UNIQUE (tenant_id, stream_id, version)
);
CREATE INDEX idx_events_tenant_stream ON events (tenant_id, stream_id, version);
```

### Tenant-Aware Projections

- Each projection query is scoped by `tenant_id`.
- Rebuild projections per-tenant independently — one tenant's rebuild doesn't affect others.
- In EventStoreDB: use stream naming convention `tenant-{tenantId}-order-{orderId}` and category projections.

### Cross-Tenant Concerns

- **Schema evolution**: Version events globally. Upcasters run regardless of tenant.
- **Rate limiting**: Prevent one tenant from flooding the event store. Implement per-tenant write throttling.
- **Data residency**: For regulated industries, use separate databases per region/tenant.

---

## 5. Event Sourcing with DDD Tactical Patterns

### Aggregate Root as Event-Sourced Entity

- The aggregate root is the only entry point for state changes.
- Value objects within the aggregate are rebuilt from events during rehydration.
- Domain services that need aggregate state must load via event replay, never direct DB access.

### Entity vs Value Object in Event Sourcing

- **Entities** (within aggregate): Identified by local ID. Events reference them: `LineItemAdded { lineItemId, sku, qty }`.
- **Value Objects**: No identity. Embedded in event data. E.g., `Address { street, city, zip }` inside `ShippingAddressChanged`.

### Domain Event Design Rules

1. Events represent **facts that happened**, named in past tense: `OrderShipped`, not `ShipOrder`.
2. Include all data needed to reconstruct state — don't rely on lookups.
3. Avoid "CRUD events" (`OrderUpdated`). Be specific: `OrderItemAdded`, `OrderItemRemoved`, `OrderShippingAddressChanged`.
4. Include `causationId` (the command that caused it) and `correlationId` (the saga/workflow it belongs to).

### Invariant Enforcement

```typescript
// Aggregate enforces invariants BEFORE emitting events
addItem(item: OrderItem) {
  if (this.status !== 'draft') throw new InvariantViolation('Cannot add to non-draft');
  if (this.items.length >= 50) throw new InvariantViolation('Max 50 items per order');
  if (this.items.some(i => i.sku === item.sku)) throw new InvariantViolation('Duplicate SKU');
  this.apply(new OrderItemAdded({ orderId: this.id, ...item }));
}
```

### Anti-Corruption Layer (ACL)

When integrating with external systems that don't use event sourcing:
- Translate external events into domain events at the boundary.
- Never let external schemas leak into your domain events.
- The ACL is an event handler that subscribes to integration events and issues commands to your aggregates.

---

## 6. Read Model Rebuilding Strategies

### Why Rebuild?

- Bug in projection logic (incorrect state accumulated).
- New projection added for a new query use case.
- Schema change in read model.
- Post-incident recovery.

### Strategy Comparison

| Strategy | Downtime | Complexity | Data freshness |
|----------|----------|------------|----------------|
| **Stop-and-replay** | Yes | Low | Stale during rebuild |
| **Blue-green projections** | No | Medium | Live reads from old, build new in background |
| **Live + catch-up** | No | Medium | Old projection serves reads until new catches up |
| **Parallel rebuild** | No | High | Run old and new simultaneously, switch atomically |

### Blue-Green Projection Rebuild (Recommended)

1. Deploy new projection code writing to `orders_v2` table.
2. Start replaying all events from position 0 into `orders_v2`.
3. Once `orders_v2` catches up to live position, atomically switch the read API to point to `orders_v2`.
4. Drop `orders_v1` after verification period.

### Performance Tips

- **Batch writes**: Buffer N events, then flush to read store in a single transaction.
- **Disable indexes** during bulk replay, re-create after.
- **Parallelize by stream**: Replay different aggregate streams on different workers (safe if projections don't cross streams).
- **Checkpoint frequently**: Store the last processed event position. On restart, resume from checkpoint.

---

## 7. Event Store Partitioning

### Partitioning Strategies

| Strategy | Partition key | Use case |
|----------|--------------|----------|
| **By aggregate ID** | `stream_id` | Default. Each aggregate is one partition. |
| **By tenant** | `tenant_id` | Multi-tenant SaaS |
| **By aggregate type** | `order-*`, `user-*` | Category-based queries |
| **By time** | `year-month` | Archival, cold storage |
| **By region** | `us-east`, `eu-west` | Data residency, latency |

### Partitioning in Practice

**PostgreSQL**: Use native table partitioning.
```sql
CREATE TABLE events (
  id BIGSERIAL, tenant_id UUID, stream_id TEXT, version INT,
  event_type TEXT, data JSONB, created_at TIMESTAMPTZ
) PARTITION BY HASH (tenant_id);

CREATE TABLE events_p0 PARTITION OF events FOR VALUES WITH (MODULUS 8, REMAINDER 0);
CREATE TABLE events_p1 PARTITION OF events FOR VALUES WITH (MODULUS 8, REMAINDER 1);
-- ... up to p7
```

**Kafka**: Topic per aggregate type, partition by aggregate ID.

**EventStoreDB**: Streams are the natural partition unit. Use category projections (`$ce-order`) for cross-stream queries.

### Archive and Cold Storage

- Events older than N months → move to cold storage (S3, Glacier).
- Keep snapshots in hot storage for fast aggregate loading.
- Maintain a "pointer" table mapping stream → archive location for historical replays.

---

## 8. Temporal Queries

### Types of Temporal Queries

1. **Point-in-time state**: "What was this order at 2024-01-15T10:00Z?" → Replay events up to that timestamp.
2. **State diff**: "What changed on this order between T1 and T2?" → Filter events in time range.
3. **Historical projection**: "What did our daily revenue dashboard look like last Tuesday?" → Rebuild projection with events up to that timestamp.
4. **Bitemporal queries**: Distinguish between "when it happened" (event time) and "when we recorded it" (transaction time).

### Implementation

```typescript
// Point-in-time aggregate reconstruction
async function getOrderAt(orderId: string, asOf: Date): Promise<OrderState> {
  const events = await eventStore.loadStream(orderId);
  const filtered = events.filter(e => new Date(e.metadata.timestamp) <= asOf);
  return OrderAggregate.rehydrate(filtered).getState();
}
```

### Bitemporal Event Metadata

```typescript
interface EventMetadata {
  eventTime: string;       // When the fact occurred in the real world
  recordedTime: string;    // When the event was appended to the store
  version: number;
  causationId: string;
  correlationId: string;
}
```

### Regulatory and Compliance Uses

- **Audit trail**: Every state change is traceable to a specific event and command.
- **GDPR right to erasure**: Use crypto-shredding — encrypt PII with per-user key, destroy key on erasure request. Events remain but PII is unreadable.
- **SOX compliance**: Temporal queries prove what state existed at audit checkpoints.
