# CQRS + Event Sourcing Troubleshooting Guide

> Diagnosis and resolution for the most common production pitfalls.

## Table of Contents

- [1. Event Versioning Hell](#1-event-versioning-hell)
- [2. Projection Lag](#2-projection-lag)
- [3. Idempotency Failures](#3-idempotency-failures)
- [4. Aggregate Root Boundary Mistakes](#4-aggregate-root-boundary-mistakes)
- [5. Eventual Consistency Debugging](#5-eventual-consistency-debugging)
- [6. Snapshot Corruption](#6-snapshot-corruption)
- [7. Event Ordering Issues](#7-event-ordering-issues)
- [8. Split-Brain Scenarios](#8-split-brain-scenarios)

---

## 1. Event Versioning Hell

### Symptoms

- Deserialization errors after deploying new code.
- Projections crash or produce incorrect state after event schema changes.
- Old events in the store are incompatible with new handler logic.
- Aggregate rehydration throws on historical events.

### Root Causes

- **Renamed or removed fields** in event payloads without versioning.
- **Changed event semantics** (e.g., `OrderCreated` now means something different).
- **No upcaster pipeline** — code assumes all events match the latest schema.
- **Coupling projections to event internals** instead of through a stable contract.

### Fixes

1. **Never mutate stored events.** If the schema changes, create a new version (`OrderCreated_v2`).
2. **Implement an upcaster chain** that runs on deserialization:
   ```typescript
   // Register upcasters in order
   const upcasters = [
     { from: 'OrderCreated_v1', to: 'OrderCreated_v2',
       transform: (e) => ({ ...e, data: { ...e.data, currency: e.data.currency ?? 'USD' } }) },
     { from: 'OrderCreated_v2', to: 'OrderCreated_v3',
       transform: (e) => ({ ...e, data: { ...e.data, taxRate: e.data.taxRate ?? 0 } }) },
   ];
   ```
3. **Use weak schemas**: Add new fields as optional with defaults. Avoid removing fields.
4. **Version in the event type name or metadata**, not just in a `version` field.
5. **Test upcasters against real historical data** — dump production events (anonymized) and verify deserialization.

### Prevention

- Code review gate: any PR that changes an event's type definition must include an upcaster.
- Schema registry (e.g., Avro/Protobuf with compatibility checks) for integration events.
- Golden file tests: serialize/deserialize sample events from each version.

---

## 2. Projection Lag

### Symptoms

- User performs action but read model shows stale state.
- Dashboard numbers are behind real-time.
- Monitoring shows growing gap between event store head and projection position.

### Root Causes

- **Slow projection handler** — heavy computation, N+1 queries, or slow downstream store.
- **Single-threaded processing** — one slow event blocks all subsequent events.
- **Unhandled exceptions** — projection crashes and restarts, losing progress or replaying.
- **Backpressure** — event store produces events faster than the projection consumes.
- **Full rebuild in progress** — replaying millions of historical events.

### Diagnosis

```sql
-- Check projection position vs event store head
SELECT
  p.projection_name,
  p.last_processed_position,
  (SELECT MAX(global_position) FROM events) AS store_head,
  (SELECT MAX(global_position) FROM events) - p.last_processed_position AS lag
FROM projection_checkpoints p;
```

### Fixes

1. **Monitor lag as a first-class metric.** Alert when lag exceeds SLA threshold.
2. **Batch processing**: Read events in batches (100-1000), apply in a single DB transaction.
3. **Parallelize by partition**: Process events for different aggregates on different workers.
4. **Circuit-break bad events**: If an event fails N times, send to dead-letter queue, advance position.
   ```typescript
   async function processWithDLQ(event: StoredEvent, handler: ProjectionHandler) {
     try {
       await handler.handle(event);
     } catch (err) {
       if (event.retryCount >= MAX_RETRIES) {
         await deadLetterQueue.enqueue(event, err);
         return; // skip, advance position
       }
       throw err; // retry
     }
   }
   ```
5. **Optimize read model writes**: Use upserts, batch inserts, disable indexes during rebuilds.
6. **Separate fast and slow projections**: Critical projections (user-facing) get dedicated consumers with priority.

### UI Mitigation

- **Optimistic updates**: After a command succeeds, update the UI immediately without waiting for the projection.
- **Polling with position**: Return the write-side position from the command response. Client polls until projection reaches that position.
- **Causal consistency token**: Attach the last-written event position to the user's session. Read queries wait until the projection is at least that far.

---

## 3. Idempotency Failures

### Symptoms

- Duplicate records in read models (e.g., two identical orders).
- Side effects fire twice (double email, double charge).
- Aggregate version conflicts after retries that actually succeeded.

### Root Causes

- **No deduplication key**: Command handlers don't check if a command was already processed.
- **At-least-once delivery** without idempotent consumers.
- **Network retries**: Client retries a "timed out" request that actually succeeded server-side.
- **Projection replayed without clearing** — events applied twice to existing read model state.

### Fixes

**Command-side idempotency:**
```typescript
// Track processed command IDs
async execute(cmd: ConfirmOrder) {
  const key = `cmd:${cmd.commandId}`;
  if (await this.deduplicationStore.exists(key)) return; // already processed
  // ... process command ...
  await this.deduplicationStore.set(key, { processedAt: Date.now() }, TTL_24H);
}
```

**Event-handler idempotency:**
```typescript
// Track last processed position per projection
async handleEvent(event: StoredEvent) {
  const lastPos = await this.checkpoint.getPosition(this.projectionName);
  if (event.globalPosition <= lastPos) return; // already processed
  await this.applyEvent(event);
  await this.checkpoint.setPosition(this.projectionName, event.globalPosition);
}
```

**Aggregate-side idempotency (optimistic concurrency):**
- The event store rejects appends if `expected_version` doesn't match. This naturally prevents duplicate processing if you re-load the aggregate before each command.

### Prevention

- Generate `commandId` on the **client side** (UUID v4). Server-side generation can't detect client retries.
- Use upsert semantics in projections: `INSERT ... ON CONFLICT DO UPDATE`.
- Set TTL on deduplication entries (24h is typical) — commands older than TTL won't be retried.

---

## 4. Aggregate Root Boundary Mistakes

### Symptoms

- **God aggregate**: One aggregate handles hundreds of events, slow to load, frequent version conflicts.
- **Chatty aggregates**: Aggregates call each other directly or query external services.
- **Transactional inconsistency**: Business rules that span aggregates fail in edge cases.
- **High contention**: Multiple users hit the same aggregate simultaneously, causing optimistic concurrency failures.

### Common Mistakes

| Mistake | Problem | Fix |
|---------|---------|-----|
| Order aggregate contains full Customer data | Bloated, coupled | Reference customer by ID only |
| Aggregate queries a read model | Breaks write/read separation | Pass needed data into the command |
| Two aggregates in one transaction | No isolation, can't scale independently | Use saga for coordination |
| Aggregate with 100+ event types | God aggregate | Split by subdomain |
| Aggregate with millions of events | Slow rehydration | Split by lifecycle, use snapshots |

### Sizing Heuristics

- **5-7 event types per aggregate** is a healthy range. More signals a split.
- **If an aggregate is loaded >1000 events without snapshots**, consider splitting.
- **If two parts of the aggregate are modified by different users/workflows**, they should be separate aggregates.

### Splitting Aggregates

Example: `OrderAggregate` grows too large → split into:
- `OrderAggregate` (lifecycle: create, confirm, cancel)
- `OrderFulfillmentAggregate` (pick, pack, ship, deliver)
- `OrderPaymentAggregate` (authorize, capture, refund)

Use a process manager to coordinate between them.

---

## 5. Eventual Consistency Debugging

### Symptoms

- User creates a resource, refreshes, doesn't see it.
- Reports show different numbers depending on when they're run.
- Race conditions between commands that depend on read model state.

### Debugging Checklist

1. **Check projection lag** (see [Section 2](#2-projection-lag)).
2. **Trace the event**: Does the event exist in the store? `SELECT * FROM events WHERE stream_id = ? ORDER BY version`.
3. **Check dead-letter queue**: Was the event rejected by the projection?
4. **Check event handler errors**: Are exceptions being swallowed silently?
5. **Check global position gaps**: Missing positions mean events were lost or the store has gaps.

### Common Debugging Queries

```sql
-- Find events for a specific aggregate that projections may have missed
SELECT global_position, event_type, created_at
FROM events
WHERE stream_id = 'order-12345'
ORDER BY version;

-- Find the projection checkpoint
SELECT * FROM projection_checkpoints
WHERE projection_name = 'order_summary';

-- Find dead-lettered events
SELECT * FROM dead_letter_queue
WHERE created_at > now() - INTERVAL '1 hour'
ORDER BY created_at DESC;
```

### Patterns to Avoid

- **Don't read your own writes through the projection.** After a command, use the command result or event directly.
- **Don't enforce uniqueness via the read model** (e.g., "email must be unique"). The read model may lag. Use a dedicated uniqueness check (reservation pattern) or a lookup stream.
- **Don't use projection data inside command handlers.** The aggregate must have all data it needs passed through the command.

### Reservation Pattern for Uniqueness

```
1. Client: "Register user with email X"
2. Command handler: Try to reserve "email:X" in a reservation table (unique constraint)
3. If reservation succeeds → create UserAggregate
4. If reservation fails → reject with "email already taken"
5. UserCreated event → projection updates read model
```

---

## 6. Snapshot Corruption

### Symptoms

- Aggregate state is wrong after loading from snapshot.
- Errors during rehydration: missing fields, type mismatches.
- Aggregate behaves differently depending on whether it loads from snapshot or full replay.

### Root Causes

- **Snapshot schema out of sync with aggregate code** — new fields added to aggregate but not to snapshot serialization.
- **Bug in snapshot creation logic** — incorrect state captured.
- **Snapshot taken from a buggy aggregate version** — bad state frozen permanently.
- **Deserialization with wrong version** — snapshot format changed but version not bumped.

### Fixes

1. **Version snapshots explicitly**:
   ```typescript
   interface Snapshot {
     aggregateId: string;
     version: number;        // event version at snapshot time
     schemaVersion: number;  // snapshot format version
     state: unknown;
   }
   ```
2. **Validate on load**: If `schemaVersion` doesn't match current, discard snapshot and replay from events.
3. **Snapshot is an optimization, never the source of truth**: The system MUST work without snapshots. If a snapshot is corrupt, fall back to full replay.
4. **Invalidate snapshots on deploy**: When aggregate logic changes, increment `schemaVersion`. Old snapshots auto-invalidate.

### Recovery

```typescript
async function loadAggregate(streamId: string): Promise<Aggregate> {
  const snapshot = await snapshotStore.load(streamId);
  if (snapshot && snapshot.schemaVersion === CURRENT_SCHEMA_VERSION) {
    const aggregate = Aggregate.fromSnapshot(snapshot);
    const newEvents = await eventStore.loadFrom(streamId, snapshot.version + 1);
    newEvents.forEach(e => aggregate.apply(e, false));
    return aggregate;
  }
  // Snapshot missing or stale — full replay
  const allEvents = await eventStore.load(streamId);
  return Aggregate.rehydrate(allEvents);
}
```

---

## 7. Event Ordering Issues

### Symptoms

- Projection state inconsistent with event store.
- Events processed out of sequence cause invalid transitions.
- Missing events in projections (gap in sequence).

### Root Causes

- **Multi-writer race**: Two processes append to the same stream without optimistic concurrency.
- **Broker redelivery**: Message broker redelivers events out of order after consumer restart.
- **Cross-aggregate ordering assumed**: Projection assumes Event A from Aggregate 1 arrives before Event B from Aggregate 2.
- **Global position gaps**: PostgreSQL sequences can have gaps on transaction rollback.

### Fixes

1. **Per-stream optimistic concurrency**: Always append with `expected_version`. The store rejects conflicting writes.
2. **Process events in per-stream order**: A single consumer per stream, or partition by stream ID.
3. **Never assume cross-stream order**: Design projections to handle events from different streams arriving in any order.
4. **Gap detection**:
   ```typescript
   // Detect gaps in global position
   if (event.globalPosition > lastPosition + 1) {
     // Gap detected — wait for missing events or flag for investigation
     await gapBuffer.park(event);
     return;
   }
   ```
5. **Causal ordering with causation chains**: Use `causationId` to enforce processing order within a saga.

### Kafka-Specific

- Key messages by aggregate ID → guarantees per-aggregate order within a partition.
- Don't consume from multiple partitions in a single consumer expecting global order.
- Use transactions (`idempotent producer + transactions`) for exactly-once semantics.

---

## 8. Split-Brain Scenarios

### Symptoms

- Two nodes accept writes to the same aggregate with conflicting events.
- After network heal, event streams have diverged.
- Read models on different nodes show different data.

### Root Causes

- **Network partition** splits cluster into two independently operating groups.
- **No quorum enforcement** — minority partition continues accepting writes.
- **Leader election failure** — two nodes believe they're the leader.

### Prevention

1. **Quorum-based writes**: Require majority of nodes to acknowledge before confirming a write. Minority partition becomes read-only.
2. **Fencing tokens**: Each leader gets a monotonically increasing token. Event store rejects writes with stale tokens.
   ```
   Leader A (token 5) → partition → Leader B elected (token 6)
   After heal: Leader A tries to write with token 5 → rejected (token < 6)
   ```
3. **Single-writer per stream**: Assign each aggregate stream to a specific node. Only that node can append.
4. **Consensus protocols**: Use Raft/Paxos for leader election and log replication (EventStoreDB cluster does this internally).

### Recovery After Split-Brain

| Strategy | When to use | Risk |
|----------|-------------|------|
| **Last writer wins** | Low-conflict data, metrics | Data loss |
| **Manual merge** | Critical business data | Slow, human error |
| **Conflict events** | All cases | Complexity |
| **Discard minority** | Quorum-based systems | Minority data lost |

**Conflict events pattern**: After healing, generate `ConflictDetected` events that contain both versions. A human or automated resolver processes them and emits the correct events.

### Monitoring

- Track cluster health: node heartbeats, replication lag, leader status.
- Alert on: partition events, replication lag spikes, leader changes.
- Test split-brain recovery in staging with chaos engineering (network partition injection).

---

## General Debugging Toolkit

### Essential Queries

```sql
-- Event store health
SELECT COUNT(*), MIN(created_at), MAX(created_at) FROM events;

-- Events per aggregate type (detect hot aggregates)
SELECT split_part(stream_id, '-', 1) AS agg_type, COUNT(*) FROM events GROUP BY 1 ORDER BY 2 DESC;

-- Recent failures in dead letter queue
SELECT event_type, error_message, COUNT(*) FROM dead_letter_queue
WHERE created_at > now() - INTERVAL '24 hours' GROUP BY 1, 2 ORDER BY 3 DESC;

-- Projection checkpoint comparison
SELECT projection_name, last_processed_position,
  (SELECT MAX(global_position) FROM events) - last_processed_position AS lag
FROM projection_checkpoints ORDER BY lag DESC;
```

### Logging Best Practices

- Log every command received (type, aggregate ID, command ID).
- Log every event emitted (type, stream ID, version, global position).
- Log projection position updates periodically (not every event — too noisy).
- Log all dead-lettered events with full error context.
- Use structured logging with `correlationId` in every log line for end-to-end tracing.
