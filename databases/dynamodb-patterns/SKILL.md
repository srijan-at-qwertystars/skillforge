---
name: dynamodb-patterns
description: >
  DynamoDB data modeling and design patterns for AWS applications.
  Use when: DynamoDB table design, single-table design, DynamoDB GSI,
  partition key strategy, sort key design, DynamoDB query optimization,
  NoSQL data modeling, DynamoDB streams, DynamoDB TTL, DynamoDB transactions,
  batch operations, DAX caching, capacity planning, access pattern modeling,
  DynamoDB CDC, item collection, secondary index design, write sharding.
  Do NOT use when: relational database design, SQL queries, PostgreSQL schema,
  MySQL optimization, MongoDB queries, Redis caching, Elasticsearch indexing,
  general SQL joins, Oracle tuning, Cassandra ring design.
---

# DynamoDB Design Patterns

## Core Principles

- DynamoDB is a key-value and document store. Design for access patterns, not entities.
- Identify ALL access patterns before writing any schema. You cannot retrofit efficiently.
- Denormalize aggressively. Store data the way it will be read. Duplicate if needed.
- There are no JOINs. Pre-join data at write time.
- Item size limit: 400KB. Partition limit: 10GB (with LSI). Max 25 GSIs per table.

## Single-Table Design

Store multiple entity types in one table using generic key names (PK, SK).
Prefix values with entity type for disambiguation.

### Key structure pattern

```
PK                  | SK                      | Entity
USER#u123           | METADATA                | User profile
USER#u123           | ORDER#2024-03-15#o456   | User's order
USER#u123           | ORDER#2024-03-15#o456#ITEM#i789 | Order item
ORG#org1            | USER#u123               | Org membership
```

### When to use single-table vs multi-table

Use single-table when:
- Related entities are queried together (user + orders in one call)
- You need transactional writes across entity types
- Team has DynamoDB modeling expertise

Use multi-table when:
- Entities have completely independent access patterns
- Team is new to DynamoDB or access patterns are unpredictable
- Different entities need different capacity/backup settings

## Partition Key Strategies

### Requirements for good partition keys
- High cardinality (many distinct values)
- Even request distribution
- Known at query time without scan

### Patterns

| Pattern | PK Example | Use Case |
|---------|-----------|----------|
| Entity ID | `USER#u123` | Direct lookups |
| Composite | `TENANT#t1#USER#u123` | Multi-tenant isolation |
| Write sharding | `VOTES#item1#3` (append 0-N) | Hot partition mitigation |
| Time-bucketed | `LOGS#2024-03-15` | Time-series with known ranges |

### Write sharding for hot partitions

When a single key receives disproportionate traffic, append a random suffix:

```python
import random
SHARD_COUNT = 10
pk = f"COUNTER#{item_id}#{random.randint(0, SHARD_COUNT - 1)}"
# Read: query all shards and aggregate
```

## Sort Key Strategies

Sort keys enable range queries, hierarchical data, and version tracking within a partition.

### Patterns

| Pattern | SK Example | Enables |
|---------|-----------|---------|
| Hierarchical | `COUNTRY#US#STATE#CA#CITY#LA` | begins_with at any level |
| Timestamp | `ORDER#2024-03-15T10:30:00Z` | Range queries on time |
| Version | `v0` (current), `v1`, `v2` | Version history |
| Composite | `STATUS#active#DATE#2024-03-15` | Filter by status + time |
| Zero-padded | `RANK#000042` | Numeric sort as strings |

### Sort key query operators
- `=` exact match
- `<`, `<=`, `>`, `>=` range
- `BETWEEN` inclusive range
- `begins_with` prefix matching (most powerful for hierarchies)

## GSI (Global Secondary Index) Design

GSIs project data into a separate partition structure with different PK/SK.
They consume their own capacity and replicate asynchronously.

### Design rules
- GSI PK must have high cardinality (same rules as table PK)
- Project only attributes you need (KEYS_ONLY, INCLUDE, or ALL)
- Use sparse indexes: items missing the GSI key attribute are excluded
- Max 25 GSIs per table. Each adds write cost (every table write replicates to GSI)

### GSI overloading

Reuse a single GSI for multiple access patterns by overloading its key semantics:

```
GSI1PK              | GSI1SK                  | Use
user@email.com      | USER                    | Lookup user by email
ORG#org1             | USER#u123               | List users in org
STATUS#active        | DATE#2024-03-15         | Active items by date
```

### Inverted index pattern

Create a GSI with SK as its PK and PK as its SK to reverse query direction:

```
Table:  PK=USER#u123,  SK=ORDER#o456
GSI:    PK=ORDER#o456, SK=USER#u123   → "which user placed this order?"
```

## LSI (Local Secondary Index) Design

- Same partition key as table, different sort key
- Must be created at table creation time (cannot add later)
- Shares 10GB partition limit with base table
- Supports strongly consistent reads (unlike GSI)
- Use when you need alternate sort orders within the same partition with consistency

## Access Pattern Modeling

### Step-by-step process
1. List every read/write operation the application performs
2. For each: identify the entity, filter criteria, sort order, and frequency
3. Group patterns by partition key — patterns sharing a PK go in one table
4. Design SK to support range/filter queries within each partition
5. Add GSIs only for patterns that cannot be served by the primary key
6. Validate with sample queries before writing code

### Example: E-commerce

| Access Pattern | Key Design |
|---------------|------------|
| Get user profile | PK=`USER#u123`, SK=`METADATA` |
| List user orders (newest first) | PK=`USER#u123`, SK=`begins_with("ORDER#")`, ScanIndexForward=false |
| Get order details + items | PK=`ORDER#o456`, SK=`begins_with("")` |
| Orders by status | GSI1PK=`STATUS#shipped`, GSI1SK=`DATE#2024-03-15` |
| Lookup by email | GSI2PK=`email@example.com`, GSI2SK=`USER` |

## DynamoDB Streams and CDC

Streams capture item-level changes in time order. Each record contains the key and optionally old/new images.

### Stream view types
- `KEYS_ONLY` — only key attributes (cheapest)
- `NEW_IMAGE` — full item after modification
- `OLD_IMAGE` — full item before modification
- `NEW_AND_OLD_IMAGES` — both (most expensive, needed for diffs)

### Use cases
- Trigger Lambda on writes for event-driven architectures
- Replicate to Elasticsearch/OpenSearch for full-text search
- Aggregate into analytics tables or data lakes
- Cross-region replication (global tables use Streams internally)
- Audit log: stream to S3/Firehose for compliance

### Best practices
- Stream records are retained for 24 hours — process promptly
- Use DynamoDB Streams Kinesis Adapter for complex consumers
- Pair with EventBridge Pipes for filtering and routing without Lambda
- Handle duplicate deliveries (at-least-once) — make consumers idempotent

## TTL (Time To Live) Patterns

Set a numeric attribute (epoch seconds) as the TTL attribute. DynamoDB deletes expired items automatically at no write cost.

### Patterns

```python
import time

# Session expiry (24 hours)
item["ttl"] = int(time.time()) + 86400

# Soft delete: set TTL to 30 days, archive via Stream before deletion
item["ttl"] = int(time.time()) + (30 * 86400)
item["deleted"] = True

# Rolling window: keep only last 90 days of events
event["ttl"] = int(time.time()) + (90 * 86400)
```

### Important notes
- TTL deletion is eventual — can take up to 48 hours after expiry
- Expired items may still appear in queries; filter with `FilterExpression: ttl > :now`
- TTL deletes appear in Streams as system deletes (userIdentity.type = "Service")
- TTL attribute must be a top-level Number attribute (epoch seconds, not milliseconds)

## Transactions

`TransactWriteItems` and `TransactGetItems` provide ACID across up to 100 items/4MB.

### Use cases
- Transfer balance between accounts (debit + credit atomically)
- Create user + org membership in one operation
- Enforce uniqueness constraints across entities

### Example: Idempotent order creation

```python
client.transact_write_items(
    TransactItems=[
        {
            "Put": {
                "TableName": "app",
                "Item": {"PK": {"S": "ORDER#o789"}, "SK": {"S": "METADATA"}, ...},
                "ConditionExpression": "attribute_not_exists(PK)"  # idempotency
            }
        },
        {
            "Update": {
                "TableName": "app",
                "Key": {"PK": {"S": "USER#u123"}, "SK": {"S": "METADATA"}},
                "UpdateExpression": "SET orderCount = orderCount + :one",
                "ExpressionAttributeValues": {":one": {"N": "1"}}
            }
        }
    ]
)
```

### Cost and limits
- Transactions cost 2x standard WCU/RCU
- Max 100 items or 4MB per transaction
- All items must be in the same region
- No two operations can target the same item in one transaction
- Avoid transactions for high-throughput paths — reserve for correctness-critical operations

## Batch Operations

### BatchWriteItem
- Up to 25 put/delete operations per call (no updates)
- Max 16MB total request, 400KB per item
- Handle `UnprocessedItems` in response with exponential backoff

### BatchGetItem
- Up to 100 items or 16MB per call
- Returns `UnprocessedKeys` if throttled — retry with backoff
- Use ProjectionExpression to fetch only needed attributes

### Example: Batch write with retry

```python
import time

def batch_write_with_retry(table, items, max_retries=5):
    unprocessed = items
    for attempt in range(max_retries):
        response = table.batch_write_item(RequestItems=unprocessed)
        unprocessed = response.get("UnprocessedItems", {})
        if not unprocessed:
            return
        time.sleep(2 ** attempt * 0.1)  # exponential backoff
    raise Exception("Failed to process all items")
```

## Capacity Planning

### On-demand mode
- Pay per request, no capacity planning needed
- Scales instantly to any traffic level
- Best for: unpredictable traffic, new tables, spiky workloads
- Cost: ~5x more expensive per request than provisioned at steady state
- Switches between modes allowed once every 24 hours

### Provisioned mode
- Set RCU (read capacity units) and WCU (write capacity units)
- 1 RCU = 1 strongly consistent read/s for items ≤ 4KB
- 1 WCU = 1 write/s for items ≤ 1KB
- Enable auto-scaling with target utilization (typically 70%)
- Use reserved capacity for 1-3 year commits (up to 77% savings)
- Best for: predictable, steady-state workloads

### Cost optimization tactics
- Use eventually consistent reads (2x throughput per RCU)
- Project fewer attributes in queries and GSIs
- Compress large attribute values (gzip before storing)
- Offload large blobs to S3, store S3 key in DynamoDB
- Use sparse GSIs to index only relevant items
- Monitor with CloudWatch: ConsumedReadCapacityUnits, ThrottledRequests

## DAX (DynamoDB Accelerator)

In-memory cache that sits between your app and DynamoDB. Microsecond read latency.

### When to use
- Read-heavy workloads with repeated access to same items
- Latency-sensitive applications (gaming leaderboards, ad serving)
- Reduce cost by offloading reads from provisioned table

### When NOT to use
- Write-heavy workloads (DAX caches reads, not writes)
- Applications requiring strongly consistent reads (DAX returns eventually consistent)
- Infrequently accessed data (low cache hit rate wastes money)

### Configuration
- Item cache: caches GetItem/BatchGetItem results (default TTL: 5 min)
- Query cache: caches Query/Scan results (default TTL: 5 min)
- Use DAX client SDK (drop-in replacement for DynamoDB client)

```python
import amazondax
dax_client = amazondax.AmazonDaxClient(endpoints=["dax-cluster.abc123.dax-clusters.us-east-1.amazonaws.com:8111"])
response = dax_client.get_item(TableName="app", Key={"PK": {"S": "USER#u123"}, "SK": {"S": "METADATA"}})
```

## Common Anti-Patterns

| Anti-Pattern | Problem | Fix |
|-------------|---------|-----|
| Scan for queries | O(n) cost, reads entire table | Use Query with proper key design |
| Low-cardinality PK | Hot partitions, throttling | Use high-cardinality keys, add sharding |
| Read-before-write | 2x capacity, race conditions | Use ConditionExpression or UpdateExpression |
| One table per entity | Cannot fetch related data efficiently | Single-table design with shared PK |
| Missing projections | Wastes RCU on unneeded attributes | Always set ProjectionExpression |
| Large items (>100KB) | Slow reads, high RCU cost | Compress or move large data to S3 |
| Relational modeling | Normalized tables need multiple queries | Denormalize, duplicate data at write time |
| Ignoring GSI cost | Each GSI replicates all writes | Only create GSIs for real access patterns |
| No retry on unprocessed | Silent data loss in batch ops | Always handle UnprocessedItems/Keys |
| Filter instead of key design | Reads then discards data | Push filtering into key/index design |

## Quick Reference: API to Key Mapping

```
GetItem          → exact PK + SK
Query            → exact PK + SK condition (=, <, >, between, begins_with)
Scan             → avoid; full table read
PutItem          → write single item (upsert)
UpdateItem       → partial update with expressions
DeleteItem       → remove by PK + SK
BatchGetItem     → up to 100 GetItem calls
BatchWriteItem   → up to 25 Put/Delete calls
TransactGetItems → up to 100 items, ACID reads
TransactWriteItems → up to 100 items, ACID writes
```

## Example: Complete Single-Table Schema (SaaS App)

```
PK                  | SK                        | GSI1PK           | GSI1SK              | Attrs
TENANT#t1           | METADATA                  | —                | —                   | name, plan, createdAt
TENANT#t1           | USER#u1                   | USER#u1          | TENANT#t1           | email, role
TENANT#t1           | PROJECT#p1                | STATUS#active    | DATE#2024-03-15     | title, owner
USER#u1             | METADATA                  | EMAIL#a@b.com    | USER                | name, avatar
USER#u1             | SESSION#s1                | —                | —                   | token, ttl
PROJECT#p1          | METADATA                  | —                | —                   | title, description
PROJECT#p1          | TASK#2024-03-15#tk1        | ASSIGNEE#u1      | DUE#2024-03-20      | title, status
```

Access patterns served:
- Get tenant details: `Query PK=TENANT#t1, SK=METADATA`
- List tenant users: `Query PK=TENANT#t1, SK begins_with USER#`
- Get user by email: `Query GSI1 PK=EMAIL#a@b.com`
- List tasks by assignee: `Query GSI1 PK=ASSIGNEE#u1, SK begins_with DUE#`
- Active projects by date: `Query GSI1 PK=STATUS#active, SK begins_with DATE#`
- User sessions with TTL: auto-expire via TTL attribute on session items

## References

In-depth guides in the `references/` directory:

- **[references/advanced-patterns.md](references/advanced-patterns.md)** — Single-table design deep dive, adjacency list pattern, composite sort keys, sparse indexes, write sharding, hot partition mitigation, hierarchical data modeling, time-series patterns, graph-like queries, materialized aggregations, multi-tenant isolation, event sourcing.

- **[references/troubleshooting.md](references/troubleshooting.md)** — Throttling diagnosis, hot partition identification, GSI backpressure, scan performance optimization, large item issues, transaction conflicts, Stream processing lag, capacity estimation errors, cost optimization, common error codes, monitoring and alerting.

- **[references/api-reference.md](references/api-reference.md)** — Complete DynamoDB API patterns with code examples: GetItem, PutItem, UpdateItem, DeleteItem, Query, Scan, BatchGetItem, BatchWriteItem, TransactGetItems, TransactWriteItems, PartiQL, expression syntax (key conditions, filters, projections, conditions, update expressions), pagination patterns, error handling.

## Scripts

Executable helper scripts in the `scripts/` directory:

- **[scripts/table-design.sh](scripts/table-design.sh)** — Interactive CLI to scaffold a DynamoDB table definition. Prompts for table name, keys, billing mode, GSIs, TTL, Streams, and PITR. Outputs CloudFormation YAML, CDK TypeScript, or Terraform HCL. Supports `--non-interactive` mode for automation.
  ```bash
  ./scripts/table-design.sh                    # interactive
  ./scripts/table-design.sh --output cdk       # CDK output
  ./scripts/table-design.sh --output terraform  # Terraform output
  ```

- **[scripts/capacity-calculator.sh](scripts/capacity-calculator.sh)** — Calculate RCU/WCU requirements and estimated monthly cost based on item size, read/write rates, consistency mode, and GSI count. Compares provisioned vs on-demand pricing.
  ```bash
  ./scripts/capacity-calculator.sh --item-size 2.5 --reads 500 --writes 200 --consistency eventual
  ./scripts/capacity-calculator.sh --item-size 4 --reads 1000 --writes 100 --gsi-count 3
  ```

- **[scripts/scan-table.sh](scripts/scan-table.sh)** — Parallel scan a DynamoDB table with progress tracking. Supports filtering, projection, rate limiting, and JSON output. Requires AWS CLI and jq.
  ```bash
  ./scripts/scan-table.sh --table MyTable --segments 10 --output results.json
  ./scripts/scan-table.sh --table MyTable --filter "status = :s" --values '{":s":{"S":"active"}}'
  ```

## Assets

Reusable templates in the `assets/` directory:

- **[assets/cloudformation-table.yaml](assets/cloudformation-table.yaml)** — Production-ready CloudFormation template for a DynamoDB table with: two GSIs (GSI1, GSI2), auto-scaling on all indexes, Point-in-Time Recovery, DynamoDB Streams, Contributor Insights, TTL, CloudWatch alarms for throttling and system errors. Parameterized for billing mode, capacity ranges, and environment.

- **[assets/single-table-schema.json](assets/single-table-schema.json)** — Complete single-table design schema document for a SaaS project management app. Documents 8 entity types (Tenant, User, TenantMembership, Project, Task, Comment, Notification, AuditLog), their key patterns, GSI mappings (including sparse indexes), 14 access patterns with query specifications, TTL strategy, and capacity estimates.
<!-- tested: needs-fix -->
