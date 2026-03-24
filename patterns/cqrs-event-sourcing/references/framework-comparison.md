# Event Sourcing Framework Comparison

> EventStoreDB vs Axon Framework vs Marten vs Eventuous vs Custom — an opinionated guide.

## Table of Contents

- [Summary Matrix](#summary-matrix)
- [1. EventStoreDB](#1-eventstoredb)
- [2. Axon Framework](#2-axon-framework)
- [3. Marten](#3-marten)
- [4. Eventuous](#4-eventuous)
- [5. Custom (Roll Your Own)](#5-custom-roll-your-own)
- [Decision Guide](#decision-guide)

---

## Summary Matrix

| Dimension | EventStoreDB | Axon Framework | Marten | Eventuous | Custom |
|-----------|-------------|---------------|--------|-----------|--------|
| **Type** | Event store engine | Full CQRS/ES framework | .NET library + PostgreSQL | .NET ES library | Your code |
| **Languages** | Any (gRPC/HTTP) | Java/Kotlin | C# (.NET) | C# (.NET) | Any |
| **Event store** | Native, purpose-built | Axon Server or RDBMS | PostgreSQL (transparent) | Pluggable (ESDB/PG/Cosmos) | Your DB |
| **Aggregates** | App-level (you build) | Built-in annotations | Built-in | Built-in | You build |
| **Projections** | Server-side (JS) + client subscriptions | Framework-managed | Inline, async, live | Via .NET code | You build |
| **Sagas/PM** | App-level | Built-in | App-level | App-level | You build |
| **Snapshots** | App-level | Built-in | Built-in | Built-in | You build |
| **Upcasting** | App-level | Built-in | Built-in | Built-in | You build |
| **License** | Apache 2.0 (server), commercial cloud | Apache 2.0 (framework), commercial server | Apache 2.0 | Apache 2.0 | N/A |
| **Managed hosting** | Event Store Cloud | AxonIQ Cloud | No (self-host PostgreSQL) | No | Your infra |
| **Maturity** | 12+ years | 10+ years | 8+ years | 3+ years | Varies |

---

## 1. EventStoreDB

### What It Is
Purpose-built, append-only event database. Not a framework — it's the storage engine. You build aggregates, command handlers, and projections in your application code.

### Strengths
- **Polyglot**: Official clients for .NET, Java, Node.js, Go, Rust. gRPC API for anything else.
- **Native projections**: Server-side JavaScript projections for cross-stream queries and derived streams.
- **Global ordered log**: `$all` stream gives global ordering across all aggregates — essential for certain projections.
- **Catch-up and persistent subscriptions**: First-class subscription model for projections.
- **Clustering**: Built-in Raft-based clustering with leader election and replication.
- **Admin UI**: Web dashboard for inspecting streams, events, projections, cluster status.

### Weaknesses
- **No framework-level abstractions**: You build aggregate lifecycle, upcasting, snapshotting yourself.
- **Write performance**: Benchmarks show slower sequential writes vs PostgreSQL-based stores (Marten).
- **Operational complexity**: Running a cluster requires understanding Raft, gossip protocol, certificates.
- **Server-side projections are limited**: JavaScript-only, no access to external services, debugging is awkward.

### Best For
- Polyglot architectures (multiple languages need the same event store).
- Teams that want full control over application-level patterns.
- Systems needing global event ordering.

### Hosting
- **Docker**: Single node or 3-node cluster.
- **Event Store Cloud**: Managed offering (AWS, GCP, Azure). Pay per cluster.
- **Kubernetes**: Helm charts available, but cluster management needs care.
- **Self-hosted VM**: Supported on Linux, macOS, Windows.

### Quick Start
```bash
docker run -d --name esdb -p 2113:2113 \
  -e EVENTSTORE_INSECURE=true \
  -e EVENTSTORE_RUN_PROJECTIONS=All \
  -e EVENTSTORE_START_STANDARD_PROJECTIONS=true \
  eventstore/eventstore:latest
# UI at http://localhost:2113
```

---

## 2. Axon Framework

### What It Is
Full-featured Java/Kotlin CQRS and event sourcing framework. Provides command bus, event bus, query bus, aggregate management, saga support, and more. Pairs with Axon Server (event store + message router).

### Strengths
- **Batteries-included**: Annotations for `@CommandHandler`, `@EventSourcingHandler`, `@Saga` — minimal boilerplate.
- **Axon Server**: Purpose-built event store and message router with clustering, multi-context support.
- **Mature ecosystem**: 70M+ downloads, extensive documentation, Baeldung guides, Spring Boot integration.
- **Built-in sagas**: First-class saga support with `@SagaEventHandler`, automatic lifecycle management.
- **Snapshotting and upcasting**: Built-in with configurable triggers and event transformers.
- **Testing**: `AggregateTestFixture` for given-when-then style aggregate testing.

### Weaknesses
- **Java/Kotlin only**: Not usable from other languages (Axon Server is accessible via gRPC, but you lose the framework).
- **Vendor lock-in risk**: Axon Server's commercial features (multi-node, multi-context) require a paid license.
- **Heavy abstraction**: The framework hides a lot; debugging issues requires understanding internal dispatch.
- **Learning curve**: Many concepts (command bus, event bus, query bus, tracking processors, subscribing processors) to learn upfront.

### Best For
- Java/Kotlin teams wanting a complete CQRS/ES solution.
- Enterprise environments with Spring Boot already in use.
- Teams that prefer convention over configuration.

### Licensing Details
| Component | Free | Paid |
|-----------|------|------|
| Axon Framework | ✅ Apache 2.0 | — |
| Axon Server SE (single node) | ✅ Free | — |
| Axon Server EE (cluster, multi-context) | — | Commercial license |
| AxonIQ Cloud | — | SaaS pricing |

### Quick Start
```xml
<!-- Spring Boot + Axon -->
<dependency>
  <groupId>org.axonframework</groupId>
  <artifactId>axon-spring-boot-starter</artifactId>
  <version>4.9.x</version>
</dependency>
```

---

## 3. Marten

### What It Is
.NET library that turns PostgreSQL into both a document database and an event store. No separate infrastructure — your existing PostgreSQL instance becomes the event store.

### Strengths
- **PostgreSQL-native**: No new infrastructure. Leverages PostgreSQL's JSONB, indexing, partitioning.
- **High write throughput**: Benchmarks show significantly faster writes than EventStoreDB for .NET workloads.
- **Rich projections**: Inline (synchronous), async (background), live (real-time) projection modes.
- **Document DB**: Can serve as both event store and read model store.
- **Schema management**: Automatic table/index creation and migration.
- **Active community**: Growing .NET adoption, responsive maintainers, good documentation.
- **Wolverine integration**: Pairs with Wolverine for command/message handling and sagas.

### Weaknesses
- **.NET only**: C# library, no polyglot support.
- **PostgreSQL dependency**: Tied to one database engine.
- **No managed service**: You manage PostgreSQL yourself (or use managed PG like RDS/Cloud SQL).
- **No global ordering**: Events are ordered per-stream, not globally (unlike EventStoreDB's `$all`).
- **Learning curve for projections**: Multiple projection modes with different consistency and performance characteristics.

### Best For
- .NET teams already using PostgreSQL.
- Teams wanting simplicity — one database for events + read models.
- High write-throughput requirements.

### Performance Profile
```
Benchmark: 10,000 events append + read (single stream)
Marten/PostgreSQL: ~200ms write, ~50ms read
EventStoreDB:      ~2000ms write, ~80ms read
(Numbers vary by hardware, schema, and version — benchmark your workload.)
```

### Quick Start
```csharp
// Program.cs
builder.Services.AddMarten(opts => {
    opts.Connection(connectionString);
    opts.Events.StreamIdentity = StreamIdentity.AsString;
});
```

---

## 4. Eventuous

### What It Is
Modern, lightweight .NET library focused purely on event sourcing patterns. Pluggable event store backends — not tied to a specific database.

### Strengths
- **Backend-agnostic**: Supports EventStoreDB, PostgreSQL, MongoDB, Azure Cosmos DB, and more.
- **Clean API**: Minimal, well-designed abstractions for aggregates, commands, subscriptions.
- **Modern .NET**: Targets .NET 8+, uses modern C# features (records, minimal APIs).
- **Testable**: Designed for unit testing aggregates and projections.
- **Lightweight**: No heavy framework overhead — you compose what you need.
- **Good documentation**: Clear examples, growing adoption.

### Weaknesses
- **.NET only**: C# library.
- **Smaller ecosystem**: Fewer community resources, examples, and Stack Overflow answers than Axon or Marten.
- **No built-in sagas**: Process managers are app-level (use Wolverine or build your own).
- **Newer project**: Less battle-tested in very large production deployments.

### Best For
- .NET teams wanting flexibility in event store choice.
- Projects that might migrate between EventStoreDB and PostgreSQL.
- Teams preferring a library over a framework (compose vs inherit).

### Quick Start
```csharp
// Aggregate with Eventuous
public record OrderState : State<OrderState> {
    public string Status { get; init; } = "draft";

    public override OrderState When(object @event) => @event switch {
        OrderCreated => this with { Status = "created" },
        OrderConfirmed => this with { Status = "confirmed" },
        _ => this
    };
}

public class Order : Aggregate<OrderState> {
    public void Create(string orderId, string customerId) {
        EnsureDoesntExist();
        Apply(new OrderCreated(orderId, customerId));
    }
}
```

---

## 5. Custom (Roll Your Own)

### What It Is
Build your own event store and CQRS infrastructure on top of a general-purpose database (PostgreSQL, MySQL, DynamoDB, MongoDB).

### When It Makes Sense
- You need complete control over storage format and performance characteristics.
- Your language/platform has no mature event sourcing library.
- You have unique requirements (multi-tenant partitioning, custom encryption, regulatory constraints).
- You want to understand the internals deeply (educational or R&D).

### When It Doesn't
- You're a small team without deep event sourcing experience.
- Time-to-market matters more than customization.
- You'd end up rebuilding what Marten or Eventuous already provides.

### Essential Components to Build

| Component | Complexity | Critical? |
|-----------|-----------|-----------|
| Append-only event table | Low | Yes |
| Optimistic concurrency (version check) | Low | Yes |
| Event serialization/deserialization | Medium | Yes |
| Aggregate lifecycle (load/replay/save) | Medium | Yes |
| Projection framework (subscriptions) | High | Yes |
| Upcasting pipeline | Medium | Yes |
| Snapshotting | Medium | No (optimization) |
| Global position tracking | Medium | Depends |
| Outbox for transactional messaging | Medium | If using broker |

### PostgreSQL-Based Custom Event Store

See `assets/event-store-schema.sql` for a production-ready schema.

Key decisions:
- **JSONB vs typed columns**: JSONB is flexible; typed columns are faster for queries.
- **Global position**: Use a `BIGSERIAL` column for global ordering.
- **Partitioning**: Partition by `stream_id` hash for write throughput, or by tenant for multi-tenancy.
- **Notify/Listen**: Use PostgreSQL `NOTIFY` for real-time subscription without polling.

### Cost of Custom

| Year 1 | Year 2+ |
|--------|---------|
| 3-6 months to build basics | Ongoing maintenance |
| Debug concurrency, ordering, replay edge cases | Handle schema evolution |
| Build monitoring and tooling | Performance tuning as data grows |
| Less time on business features | Team knowledge dependency |

---

## Decision Guide

### Decision Tree

```
Start
├─ Java/Kotlin team?
│  └─ Yes → Axon Framework (batteries-included, mature)
├─ .NET team?
│  ├─ Already have PostgreSQL? → Marten (simple, fast)
│  ├─ Need backend flexibility? → Eventuous (pluggable)
│  └─ Need global ordering? → EventStoreDB + custom app code
├─ Polyglot / multi-language?
│  └─ EventStoreDB (gRPC clients for any language)
├─ Need managed service?
│  ├─ Java → AxonIQ Cloud
│  └─ Any → Event Store Cloud
└─ Unique requirements, experienced team?
   └─ Custom on PostgreSQL
```

### Selection Criteria Weights

Score each criterion 1-5 for your project, multiply by weight:

| Criterion | Weight | EventStoreDB | Axon | Marten | Eventuous | Custom |
|-----------|--------|-------------|------|--------|-----------|--------|
| Language support | 3 | 5 | 2 | 2 | 2 | 5 |
| Framework features | 2 | 2 | 5 | 4 | 3 | 1 |
| Operational simplicity | 3 | 2 | 3 | 5 | 4 | 2 |
| Write performance | 2 | 3 | 3 | 5 | 4 | 4 |
| Community / docs | 2 | 4 | 5 | 4 | 3 | 1 |
| Flexibility | 1 | 4 | 2 | 3 | 5 | 5 |
| Cost (total) | 2 | 3 | 2 | 5 | 5 | 3 |

### Migration Paths

- **Axon → EventStoreDB**: Extract events via Axon's event processor, replay into ESDB. Rewrite aggregates without annotations.
- **Marten → EventStoreDB**: Export events from PostgreSQL, import via ESDB client. Projection code stays similar.
- **Custom → Marten/Eventuous**: If PostgreSQL-based, Marten can read your existing tables with schema mapping. Otherwise, full event migration.
- **EventStoreDB → Marten**: Read all events via `$all` subscription, write to Marten. Requires dual-running during migration.
