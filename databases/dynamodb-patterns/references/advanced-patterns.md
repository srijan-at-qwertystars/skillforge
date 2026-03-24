# DynamoDB Advanced Patterns

## Table of Contents

- [Single-Table Design Deep Dive](#single-table-design-deep-dive)
- [Adjacency List Pattern](#adjacency-list-pattern)
- [Composite Sort Keys](#composite-sort-keys)
- [Sparse Indexes](#sparse-indexes)
- [Write Sharding](#write-sharding)
- [Hot Partition Mitigation](#hot-partition-mitigation)
- [Hierarchical Data Modeling](#hierarchical-data-modeling)
- [Time-Series Patterns](#time-series-patterns)
- [Graph-Like Queries](#graph-like-queries)
- [Materialized Aggregations](#materialized-aggregations)
- [Multi-Tenant Isolation](#multi-tenant-isolation)
- [Event Sourcing with DynamoDB](#event-sourcing-with-dynamodb)

---

## Single-Table Design Deep Dive

### Why single-table design exists

DynamoDB charges per request, and every `Query` call is one round-trip. If fetching a page requires user profile + preferences + last 10 orders, a multi-table design means 3 round-trips. A single-table design serves this in 1 `Query` — same partition key, different sort keys.

### Entity mapping methodology

1. **Enumerate every entity**: User, Order, OrderItem, Address, Payment
2. **Map relationships**: User → many Orders → many OrderItems
3. **Group by co-access**: "Which entities are always fetched together?"
4. **Assign key prefixes**: Entity type becomes the PK/SK prefix

### Generic key attribute naming

Always use generic names (`PK`, `SK`, `GSI1PK`, `GSI1SK`, etc.) — not semantic names like `userId`. This allows the same attribute to hold different entity types.

```
PK              | SK                           | EntityType | Data...
USER#u001       | METADATA                     | User       | name, email
USER#u001       | ADDR#home                    | Address    | street, city
USER#u001       | ORDER#2024-01-15#ord001      | Order      | total, status
ORDER#ord001    | METADATA                     | Order      | total, status, userId
ORDER#ord001    | ITEM#sku042                  | OrderItem  | qty, price
ORDER#ord001    | PAYMENT#pay001               | Payment    | method, amount
```

### Item collection management

An item collection is all items sharing the same PK. With an LSI, the collection is capped at 10GB. Monitor collection sizes:

```python
response = table.query(
    KeyConditionExpression=Key('PK').eq('USER#u001'),
    Select='COUNT'
)
# response['ScannedCount'] tells you collection size
```

### When single-table design breaks down

- **Team skill**: Requires strong DynamoDB modeling expertise
- **Lambda-per-entity**: If each Lambda accesses only its entity, co-location gains nothing
- **Access pattern volatility**: New patterns may require table redesign
- **Item size divergence**: One entity at 1KB, another at 300KB — vastly different RCU cost

### Migration path

Start multi-table if unsure. Migrate to single-table when access patterns stabilize. Use DynamoDB Streams to replicate from old tables to a new consolidated table during transition.

---

## Adjacency List Pattern

The adjacency list pattern models many-to-many relationships. Each edge is stored as an item with both connected nodes in PK/SK.

### Structure

```
PK              | SK              | Data
USER#u001       | GROUP#g100      | joinedAt, role
USER#u001       | GROUP#g200      | joinedAt, role
GROUP#g100      | USER#u001       | joinedAt, role
GROUP#g100      | USER#u002       | joinedAt, role
```

### Query patterns this enables

| Query                        | Key condition                              |
|-----------------------------|--------------------------------------------|
| Groups for a user           | `PK = USER#u001, SK begins_with GROUP#`    |
| Members of a group          | `PK = GROUP#g100, SK begins_with USER#`    |
| Specific membership check   | `PK = USER#u001, SK = GROUP#g100`          |

### Bidirectional edges

Store each relationship as two items (one per direction). Use `TransactWriteItems` to ensure both are created/deleted atomically.

```python
client.transact_write_items(TransactItems=[
    {"Put": {"TableName": "app", "Item": {
        "PK": {"S": "USER#u001"}, "SK": {"S": "GROUP#g100"},
        "role": {"S": "admin"}, "joinedAt": {"S": "2024-03-15"}
    }}},
    {"Put": {"TableName": "app", "Item": {
        "PK": {"S": "GROUP#g100"}, "SK": {"S": "USER#u001"},
        "role": {"S": "admin"}, "joinedAt": {"S": "2024-03-15"}
    }}}
])
```

### Edge attributes

Store relationship metadata (role, weight, timestamp) directly on the edge item. This avoids a separate lookup.

### Counting edges efficiently

Maintain a counter on the node item. Update it transactionally when adding/removing edges:

```python
{"Update": {
    "TableName": "app",
    "Key": {"PK": {"S": "GROUP#g100"}, "SK": {"S": "METADATA"}},
    "UpdateExpression": "ADD memberCount :one",
    "ExpressionAttributeValues": {":one": {"N": "1"}}
}}
```

---

## Composite Sort Keys

Composite sort keys pack multiple dimensions into a single SK, enabling multi-faceted queries with `begins_with`.

### Pattern: Status + Date

```
SK = STATUS#active#DATE#2024-03-15T10:30:00Z
```

Queries:
- All active items: `SK begins_with STATUS#active`
- Active items on a date: `SK begins_with STATUS#active#DATE#2024-03-15`
- Active items in a range: `SK BETWEEN STATUS#active#DATE#2024-03-01 AND STATUS#active#DATE#2024-03-31`

### Pattern: Geography hierarchy

```
SK = COUNTRY#US#STATE#CA#CITY#SanFrancisco#ZIP#94102
```

Queries:
- All US locations: `SK begins_with COUNTRY#US`
- California locations: `SK begins_with COUNTRY#US#STATE#CA`
- San Francisco: `SK begins_with COUNTRY#US#STATE#CA#CITY#SanFrancisco`

### Dimension ordering rules

1. **Most filtered dimension first** — the dimension you always specify goes leftmost
2. **Highest cardinality last** — fine-grained values at the end
3. **Never put optional dimensions first** — `begins_with` requires all prefixes present

### Limitations

- Cannot skip levels: If SK = `A#B#C`, you cannot query B without specifying A
- String comparison: Numeric dimensions must be zero-padded (`RANK#000042`)
- Delimiter collisions: Use `#` consistently; avoid it in values

### Zero-padding for numeric sort

```python
def make_sk(status, priority, timestamp):
    return f"STATUS#{status}#PRI#{str(priority).zfill(5)}#TS#{timestamp}"
# "STATUS#open#PRI#00003#TS#2024-03-15T10:30:00Z"
```

---

## Sparse Indexes

A sparse index is a GSI where only items with the indexed attribute appear. Items missing the GSI key attribute are excluded from the index.

### Use cases

- **Active orders only**: GSI on `activeOrderId` — only items with this attribute appear
- **Flagged items**: Set `flagged = "true"` attribute only on flagged items; GSI indexes only those
- **Pending approvals**: GSI PK = `pendingApprovalId`, exists only on unapproved items

### Implementation

```python
# Only set the GSI attribute when the item should be indexed
item = {
    "PK": "ORDER#o001", "SK": "METADATA",
    "status": "pending", "total": 99.99
}
# Add GSI key ONLY for pending orders
if item["status"] == "pending":
    item["GSI1PK"] = "PENDING"
    item["GSI1SK"] = f"DATE#{item['createdAt']}"

# When order is fulfilled, REMOVE the GSI attribute
client.update_item(
    Key={"PK": {"S": "ORDER#o001"}, "SK": {"S": "METADATA"}},
    UpdateExpression="REMOVE GSI1PK, GSI1SK SET #s = :fulfilled",
    ExpressionAttributeNames={"#s": "status"},
    ExpressionAttributeValues={":fulfilled": {"S": "fulfilled"}}
)
```

### Cost benefits

- GSI only replicates items that have the indexed attribute
- Fewer items = less storage cost and write replication cost
- Queries scan only relevant items — no filtering waste

### Combining with overloaded GSIs

A single GSI can serve multiple sparse patterns:

```
GSI1PK              | GSI1SK               | Only on items where...
PENDING_APPROVAL    | DATE#2024-03-15      | approval is pending
FLAGGED             | SEVERITY#high        | item is flagged
EXPIRING_SOON       | TTL#1710489600       | TTL within 7 days
```

---

## Write Sharding

### When you need write sharding

A single partition supports up to 1,000 WCU and 3,000 RCU per second. If one key receives more than this, you must shard.

### Deterministic sharding (for aggregation reads)

```python
SHARD_COUNT = 10

def write_vote(item_id, user_id):
    shard = hash(user_id) % SHARD_COUNT  # deterministic per user
    table.update_item(
        Key={"PK": f"VOTES#{item_id}#{shard}", "SK": "COUNT"},
        UpdateExpression="ADD voteCount :one",
        ExpressionAttributeValues={":one": 1}
    )

def read_votes(item_id):
    total = 0
    for shard in range(SHARD_COUNT):
        resp = table.get_item(
            Key={"PK": f"VOTES#{item_id}#{shard}", "SK": "COUNT"}
        )
        total += resp.get("Item", {}).get("voteCount", 0)
    return total
```

### Random sharding (for high-ingest, no individual reads)

```python
import random
pk = f"LOGS#2024-03-15#{random.randint(0, 99)}"
# Reading requires parallel scan across all shards
```

### Calculating shard count

```
shard_count = ceil(expected_writes_per_second / 1000)
```

Add buffer: use 2x the calculated count. Too many shards = more reads; too few = throttling.

### GSI sharding

GSIs can also have hot partitions. Apply the same sharding strategy to GSI keys when a single GSI PK receives disproportionate traffic.

---

## Hot Partition Mitigation

### Identifying hot partitions

CloudWatch metrics to monitor:
- `ConsumedReadCapacityUnits` / `ConsumedWriteCapacityUnits` (per-partition via Contributor Insights)
- `ThrottledRequests` — non-zero means at least one partition is hot
- `SystemErrors` — persistent errors may indicate partition issues

Enable **DynamoDB Contributor Insights** to see the most frequently accessed and throttled partition keys.

### Mitigation strategies

| Strategy | When to use |
|----------|------------|
| Write sharding | Known hot key with high write rate |
| Caching (DAX) | Hot key with high read rate, tolerates eventual consistency |
| Request buffering (SQS) | Burst writes that can be smoothed into a queue |
| Item splitting | Single large item updated by many writers → split into sub-items |
| Time-based partitioning | Time-series data where "now" partition is hot |

### Adaptive capacity

DynamoDB automatically redistributes capacity to hot partitions (adaptive capacity). However:
- It takes minutes to kick in
- It borrows from other partitions — not unlimited
- It does not solve sustained hot keys, only short bursts

### Burst capacity

Each partition retains up to 300 seconds of unused read/write capacity for burst usage. This helps absorb short spikes but is not a substitute for proper key design.

---

## Hierarchical Data Modeling

### File system pattern

```
PK              | SK                                      | Type  | Name
FS#user1        | /                                       | dir   | root
FS#user1        | /documents/                             | dir   | documents
FS#user1        | /documents/report.pdf                   | file  | report.pdf
FS#user1        | /documents/drafts/                      | dir   | drafts
FS#user1        | /documents/drafts/v1.docx               | file  | v1.docx
FS#user1        | /photos/                                | dir   | photos
FS#user1        | /photos/vacation/                       | dir   | vacation
FS#user1        | /photos/vacation/beach.jpg              | file  | beach.jpg
```

Queries:
- List root contents: `PK = FS#user1, SK begins_with /` (one level only: filter with `/` count)
- List all in `/documents/`: `PK = FS#user1, SK begins_with /documents/`
- Get specific file: `PK = FS#user1, SK = /documents/report.pdf`

### Org chart pattern

```
PK              | SK                                  | Name    | Title
ORG#acme        | EMP#CEO                             | Alice   | CEO
ORG#acme        | EMP#CEO#VP_ENG                      | Bob     | VP Engineering
ORG#acme        | EMP#CEO#VP_ENG#DIR_BE               | Carol   | Director Backend
ORG#acme        | EMP#CEO#VP_ENG#DIR_BE#ENG001        | Dave    | Engineer
ORG#acme        | EMP#CEO#VP_SALES                    | Eve     | VP Sales
```

- Direct reports of VP Eng: `SK begins_with EMP#CEO#VP_ENG#` (one level only)
- Full engineering org: `SK begins_with EMP#CEO#VP_ENG`

### Category/subcategory for e-commerce

```
PK                | SK                                     | Name
CAT#electronics   | SUB#                                   | Electronics (root)
CAT#electronics   | SUB#computers#                         | Computers
CAT#electronics   | SUB#computers#laptops#                 | Laptops
CAT#electronics   | SUB#computers#laptops#gaming#          | Gaming Laptops
CAT#electronics   | SUB#phones#                            | Phones
```

---

## Time-Series Patterns

### The "hot partition" problem

Time-series data naturally creates hot partitions: all writes go to the current time period.

### Table-per-period pattern

Create separate tables for each time period. Advantages:
- Each table has independent capacity settings (lower for historical tables)
- TTL on the table level: delete entire old tables
- No hot partition: current table absorbs all writes

```
events_2024_03  ← current, provisioned high
events_2024_02  ← historical, provisioned low or on-demand
events_2024_01  ← archived to S3, table deleted
```

### Time-bucketed partition keys

```
PK                      | SK                           | Data
SENSOR#s001#2024-03-15  | 10:30:00.000                 | temperature=72.4
SENSOR#s001#2024-03-15  | 10:30:01.000                 | temperature=72.5
SENSOR#s001#2024-03-15  | 10:30:02.000                 | temperature=72.3
```

- Bucket by hour/day depending on ingest rate
- Shard the current bucket if ingest rate exceeds partition throughput
- Query a day's data: `PK = SENSOR#s001#2024-03-15`
- Query a range: `PK = ..., SK BETWEEN 10:00:00 AND 11:00:00`

### Write-sharded time-series

For sensors with >1000 writes/sec to one bucket:

```python
import random
SHARD_COUNT = 5
pk = f"SENSOR#{sensor_id}#{date}#{random.randint(0, SHARD_COUNT-1)}"
# Reading: scatter-gather across all shards
```

### Rollup/aggregation pattern

Maintain pre-computed aggregations at different granularities:

```
PK                        | SK            | avg  | min  | max  | count
SENSOR#s001#AGG#hourly    | 2024-03-15T10 | 72.4 | 71.8 | 73.1 | 3600
SENSOR#s001#AGG#daily     | 2024-03-15    | 72.1 | 68.2 | 76.5 | 86400
SENSOR#s001#AGG#monthly   | 2024-03                | 71.9 | 62.1 | 78.3 | 2678400
```

Compute aggregations via DynamoDB Streams + Lambda on write, or batch via scheduled jobs.

---

## Graph-Like Queries

### DynamoDB is not a graph database

DynamoDB cannot do recursive traversals or shortest-path algorithms natively. But it can model one-hop and two-hop graph queries efficiently using the adjacency list pattern.

### One-hop queries (direct relationships)

```
PK          | SK          | relType
USER#alice  | FOLLOWS#bob | follows
USER#alice  | FOLLOWS#carol | follows
USER#bob    | FOLLOWS#alice | follows
```

- Alice's following: `PK = USER#alice, SK begins_with FOLLOWS#`
- Alice's followers: GSI with inverted keys → `GSI PK = FOLLOWS#alice`

### Two-hop queries (friend-of-friend)

Requires two queries (not one):

```python
# Step 1: Get Alice's friends
friends = query(PK="USER#alice", SK_begins_with="FOLLOWS#")
# Step 2: For each friend, get their friends
for friend in friends:
    fof = query(PK=f"USER#{friend}", SK_begins_with="FOLLOWS#")
```

Use `BatchGetItem` to parallelize step 2.

### Materialized paths

For tree/DAG structures where you need ancestry queries:

```
PK              | SK                              | depth
NODE#n001       | PATH#n001                       | 0     (self)
NODE#n001       | PATH#n001#n002                  | 1     (child)
NODE#n001       | PATH#n001#n002#n005             | 2     (grandchild)
```

- All descendants of n001: `PK = NODE#n001, SK begins_with PATH#n001`
- Direct children only: filter by `depth = 1`

### When to use a real graph database

If you need:
- Recursive traversals (shortest path, BFS/DFS)
- Variable-length path queries
- Graph algorithms (PageRank, community detection)

→ Use Amazon Neptune, Neo4j, or similar. Use DynamoDB Streams to sync.

---

## Materialized Aggregations

### Pattern: Pre-computed counts

Instead of counting items on read (which requires a scan), maintain running counts updated on every write.

```python
# When adding an order:
client.transact_write_items(TransactItems=[
    {"Put": {  # The order itself
        "TableName": "app",
        "Item": {"PK": {"S": "ORDER#o001"}, "SK": {"S": "METADATA"}, ...}
    }},
    {"Update": {  # Increment user's order count
        "TableName": "app",
        "Key": {"PK": {"S": "USER#u001"}, "SK": {"S": "STATS"}},
        "UpdateExpression": "ADD orderCount :one, totalSpent :amount",
        "ExpressionAttributeValues": {
            ":one": {"N": "1"},
            ":amount": {"N": "99.99"}
        }
    }}
])
```

### Pattern: Leaderboard

```
PK              | SK                  | score
LEADERBOARD#daily#2024-03-15 | SCORE#000999#USER#u001 | 999
LEADERBOARD#daily#2024-03-15 | SCORE#000875#USER#u002 | 875
```

- Top N: `PK = LEADERBOARD#..., ScanIndexForward = false, Limit = N`
- Score is zero-padded and in SK for natural sort order
- Reset: let TTL expire old leaderboard items

### Pattern: Running statistics via Streams

```python
# Lambda triggered by DynamoDB Stream
def handler(event):
    for record in event['Records']:
        if record['eventName'] == 'INSERT' and is_order(record):
            order = record['dynamodb']['NewImage']
            amount = Decimal(order['total']['N'])
            # Update aggregation item
            table.update_item(
                Key={'PK': 'AGG#REVENUE', 'SK': f"MONTH#{order['month']}"},
                UpdateExpression='ADD revenue :amt, orderCount :one',
                ExpressionAttributeValues={':amt': amount, ':one': 1}
            )
```

### Dealing with accuracy

- Transactions guarantee exact counts but cost 2x WCU
- Stream-based aggregations are eventually consistent (seconds of lag)
- For exact counts on read: query and count (expensive but accurate)
- Hybrid: use materialized counts for display, exact counts for billing

---

## Multi-Tenant Isolation

### Partition-level isolation

Prefix all keys with tenant ID:

```
PK                      | SK              | Data
TENANT#t001#USER#u001   | METADATA        | ...
TENANT#t001#ORDER#o001  | METADATA        | ...
TENANT#t002#USER#u001   | METADATA        | ...  (different tenant, same userId)
```

All queries require tenant ID, ensuring isolation. No cross-tenant queries are possible.

### Table-per-tenant (strong isolation)

For compliance (HIPAA, SOC2) or noisy-neighbor prevention:
- Separate tables per tenant
- Independent capacity settings and backup schedules
- Higher operational overhead (manage N tables)

### Tag-based access control

Use IAM conditions to restrict access:

```json
{
  "Effect": "Allow",
  "Action": ["dynamodb:GetItem", "dynamodb:Query"],
  "Resource": "arn:aws:dynamodb:*:*:table/app",
  "Condition": {
    "ForAllValues:StringLike": {
      "dynamodb:LeadingKeys": ["TENANT#${aws:PrincipalTag/tenantId}#*"]
    }
  }
}
```

---

## Event Sourcing with DynamoDB

### Event store structure

```
PK                | SK                            | eventType       | payload
AGGREGATE#order001 | EVENT#00001#2024-03-15T10:00  | OrderCreated    | {items: [...]}
AGGREGATE#order001 | EVENT#00002#2024-03-15T10:05  | ItemAdded       | {sku: "X"}
AGGREGATE#order001 | EVENT#00003#2024-03-15T10:10  | OrderSubmitted  | {total: 99.99}
```

### Key design principles

- PK = aggregate ID (all events for one aggregate in one partition)
- SK = sequence number + timestamp (ordering guarantee within partition)
- Zero-pad sequence numbers for correct string sort
- Use `ConditionExpression` on `attribute_not_exists(SK)` to prevent duplicate events

### Snapshot pattern

Store periodic snapshots to avoid replaying full history:

```
PK                | SK                    | Data
AGGREGATE#order001 | SNAPSHOT#00100        | {full state at event 100}
AGGREGATE#order001 | EVENT#00101#...       | {events after snapshot}
```

Rebuild state: load latest snapshot, then replay events after it.

### Projecting read models via Streams

Use DynamoDB Streams to project events into read-optimized views in another table or in ElasticSearch/OpenSearch for complex queries.
