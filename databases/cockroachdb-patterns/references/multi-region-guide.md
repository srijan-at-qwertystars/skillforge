# CockroachDB Multi-Region Deep Dive

## Table of Contents

- [Overview](#overview)
- [Locality Flags and Topology](#locality-flags-and-topology)
  - [Region and Zone Topology](#region-and-zone-topology)
  - [Configuring Locality on Nodes](#configuring-locality-on-nodes)
- [Database Region Configuration](#database-region-configuration)
  - [Adding and Removing Regions](#adding-and-removing-regions)
  - [Primary Region Selection](#primary-region-selection)
- [Table Locality Patterns](#table-locality-patterns)
  - [REGIONAL BY TABLE](#regional-by-table)
  - [REGIONAL BY ROW](#regional-by-row)
  - [GLOBAL Tables](#global-tables)
  - [Choosing the Right Pattern](#choosing-the-right-pattern)
- [Survival Goals](#survival-goals)
  - [Zone Failure Survival](#zone-failure-survival)
  - [Region Failure Survival](#region-failure-survival)
  - [Replication Factor Implications](#replication-factor-implications)
- [Latency Tradeoffs](#latency-tradeoffs)
  - [Write Latency by Pattern](#write-latency-by-pattern)
  - [Read Latency by Pattern](#read-latency-by-pattern)
  - [Cross-Region Round Trip Costs](#cross-region-round-trip-costs)
- [Follower Reads for Stale Data](#follower-reads-for-stale-data)
  - [Exact Staleness](#exact-staleness)
  - [Bounded Staleness](#bounded-staleness)
  - [Session-Level Configuration](#session-level-configuration)
- [Zone Config Overrides](#zone-config-overrides)
  - [Constraining Replicas](#constraining-replicas)
  - [Lease Preferences](#lease-preferences)
  - [GC TTL and Range Size](#gc-ttl-and-range-size)
- [Demo: 9-Node Multi-Region Cluster](#demo-9-node-multi-region-cluster)
  - [Cluster Topology](#cluster-topology)
  - [Starting the Nodes](#starting-the-nodes)
  - [Configuring Multi-Region](#configuring-multi-region)
  - [Creating Tables with Locality](#creating-tables-with-locality)
  - [Verifying Data Placement](#verifying-data-placement)
  - [Testing Failover](#testing-failover)
- [Operational Best Practices](#operational-best-practices)

---

## Overview

CockroachDB's multi-region capabilities allow a single database cluster to span
multiple geographic regions while providing:

- Low-latency reads and writes for users close to their data
- Survival of zone or entire region failures without data loss
- Automatic data placement based on table locality configuration
- Compliance with data residency requirements

Multi-region requires an **Enterprise license** for production use. The core
mechanism relies on Raft consensus across replicas placed in different regions
according to locality flags and zone configurations.

## Locality Flags and Topology

### Region and Zone Topology

CockroachDB uses a hierarchical locality model. Every node is tagged with
key-value locality tiers that describe its physical location:

```
region > zone > rack > node
```

The most common configuration uses `region` and `zone`:

| Tier     | Example Values                        | Purpose                          |
|----------|---------------------------------------|----------------------------------|
| region   | us-east1, us-west2, eu-west1          | Geographic region                |
| zone     | us-east1-a, us-east1-b, us-east1-c   | Availability zone within region  |
| rack     | rack-1, rack-2                        | Physical rack (optional)         |

CockroachDB uses locality tiers to:
1. Place replicas across failure domains for fault tolerance
2. Route reads to the nearest replica (follower reads)
3. Place leaseholders close to the data's "home" region
4. Enforce data residency via REGIONAL BY ROW

### Configuring Locality on Nodes

Every node must start with `--locality` flags:

```bash
# Node in us-east1, zone b
cockroach start \
  --locality=region=us-east1,zone=us-east1-b \
  --store=node1 \
  --listen-addr=node1.example.com:26257 \
  --http-addr=node1.example.com:8080 \
  --join=node1.example.com:26257,node4.example.com:26257,node7.example.com:26257

# Node in us-west2, zone a
cockroach start \
  --locality=region=us-west2,zone=us-west2-a \
  --store=node4 \
  --listen-addr=node4.example.com:26257 \
  --http-addr=node4.example.com:8080 \
  --join=node1.example.com:26257,node4.example.com:26257,node7.example.com:26257

# Node in eu-west1, zone c
cockroach start \
  --locality=region=eu-west1,zone=eu-west1-c \
  --store=node7 \
  --listen-addr=node7.example.com:26257 \
  --http-addr=node7.example.com:8080 \
  --join=node1.example.com:26257,node4.example.com:26257,node7.example.com:26257
```

**Important**: Locality flags cannot be changed after node startup without
restarting the node. Plan your topology carefully before deployment.

Verify locality configuration:

```sql
SELECT node_id, address, locality FROM crdb_internal.gossip_nodes;
```

## Database Region Configuration

### Adding and Removing Regions

A multi-region database requires at least one primary region:

```sql
-- Set the primary region (must match a locality region from running nodes)
ALTER DATABASE myapp PRIMARY REGION "us-east1";

-- Add secondary regions
ALTER DATABASE myapp ADD REGION "us-west2";
ALTER DATABASE myapp ADD REGION "eu-west1";

-- View configured regions
SHOW REGIONS FROM DATABASE myapp;

-- Remove a region (only if no REGIONAL BY ROW data references it)
ALTER DATABASE myapp DROP REGION "eu-west1";
```

### Primary Region Selection

The primary region is the default home for:
- REGIONAL BY TABLE tables (unless overridden)
- Rows in REGIONAL BY ROW tables where `crdb_region` is not specified
- System metadata for the database

Choose the primary region based on:
- Where the majority of your traffic originates
- Where your application servers are deployed
- Regulatory requirements for data residency

```sql
-- Change primary region
ALTER DATABASE myapp SET PRIMARY REGION "eu-west1";
```

## Table Locality Patterns

### REGIONAL BY TABLE

The entire table's leaseholders are placed in a single home region. All replicas
for every range of this table have their lease in the specified region.

```sql
-- Home in primary region (default for new tables in multi-region DB)
CREATE TABLE user_sessions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL,
    token STRING NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL
);
ALTER TABLE user_sessions SET LOCALITY REGIONAL BY TABLE;

-- Home in a specific region
CREATE TABLE eu_audit_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    action STRING NOT NULL,
    created_at TIMESTAMPTZ DEFAULT now()
);
ALTER TABLE eu_audit_log SET LOCALITY REGIONAL BY TABLE IN "eu-west1";
```

**When to use**: Tables accessed primarily from one region — config tables,
region-specific audit logs, session stores for a regional app deployment.

**Latency profile**:
- Reads from home region: ~1-2ms (local)
- Reads from other regions: ~50-200ms (cross-region)
- Writes from home region: ~10-20ms (quorum in-region if ZONE FAILURE)
- Writes from other regions: ~100-300ms (quorum requires cross-region)

### REGIONAL BY ROW

Each row is individually assigned to a region via the `crdb_region` column.
CockroachDB automatically partitions the table by region and places each
partition's leaseholders in the corresponding region.

```sql
CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email STRING UNIQUE NOT NULL,
    name STRING NOT NULL,
    profile JSONB,
    crdb_region crdb_internal_region NOT NULL DEFAULT default_to_database_primary_region(gateway_region())
);
ALTER TABLE users SET LOCALITY REGIONAL BY ROW;
```

The `crdb_region` column is automatically added if not present. You can also
use a custom column:

```sql
ALTER TABLE users SET LOCALITY REGIONAL BY ROW AS home_region;
```

**Querying REGIONAL BY ROW tables efficiently**:

```sql
-- GOOD: Filter includes crdb_region — scans only the relevant partition
SELECT * FROM users WHERE crdb_region = 'us-east1' AND id = $1;

-- ACCEPTABLE: No region filter — scans all partitions (fan-out)
-- Slower but functionally correct
SELECT * FROM users WHERE email = 'alice@example.com';

-- BEST: Use computed column or application logic to include region
SELECT * FROM users
WHERE crdb_region = gateway_region()::crdb_internal_region
  AND id = $1;
```

**Unique indexes on REGIONAL BY ROW tables** must include `crdb_region`:

```sql
-- This won't enforce global uniqueness — only per-region
CREATE UNIQUE INDEX idx_users_email ON users (crdb_region, email);

-- For global uniqueness, use a UNIQUE WITHOUT INDEX constraint
ALTER TABLE users ADD CONSTRAINT unique_email UNIQUE WITHOUT INDEX (email);
```

### GLOBAL Tables

GLOBAL tables replicate data to all regions and serve reads from any replica
without cross-region latency using a "non-blocking transaction" protocol.

```sql
ALTER TABLE currencies SET LOCALITY GLOBAL;
ALTER TABLE countries SET LOCALITY GLOBAL;
ALTER TABLE feature_flags SET LOCALITY GLOBAL;
```

**Key characteristics**:
- Reads are always local (any region) — no cross-region latency
- Writes are slow — must propagate to all regions before committing
- Write latency ≈ 2 × max inter-region round trip time
- Best for small, rarely-updated reference tables

**When to use**: Currency codes, country lists, configuration flags, product
catalogs with infrequent updates, permissions/roles tables.

**When NOT to use**: Tables with frequent writes, large tables where replication
cost is high, per-user data.

### Choosing the Right Pattern

```
Is data accessed from multiple regions?
├─ No → REGIONAL BY TABLE (home it where it's used)
└─ Yes
   ├─ Can rows be assigned to specific regions?
   │  ├─ Yes → REGIONAL BY ROW
   │  └─ No → continue
   └─ Is the table small and rarely written?
      ├─ Yes → GLOBAL
      └─ No → REGIONAL BY TABLE + follower reads
```

## Survival Goals

### Zone Failure Survival

```sql
ALTER DATABASE myapp SURVIVE ZONE FAILURE;
```

- Default survival goal for multi-region databases
- Requires 3+ nodes across 3+ availability zones per region
- Replication factor: 3 (one replica per AZ)
- Can lose one AZ per region without losing availability
- Writes require quorum (2/3 replicas) — achievable within one region

### Region Failure Survival

```sql
ALTER DATABASE myapp SURVIVE REGION FAILURE;
```

- Requires 3+ regions with nodes in each
- Replication factor: 5 (ensures replicas in at least 3 regions)
- Can lose an entire region without losing availability
- Writes require quorum (3/5 replicas) — must reach at least 2 additional regions
- **Significantly higher write latency** due to cross-region quorum

### Replication Factor Implications

| Survival Goal    | Min Regions | Min Zones/Region | Replication Factor | Write Quorum |
|------------------|-------------|-------------------|--------------------|--------------|
| ZONE FAILURE     | 1+          | 3                 | 3                  | 2 (in-region)|
| REGION FAILURE   | 3           | 1+                | 5                  | 3 (cross-region)|

**Critical tradeoff**: REGION FAILURE survival dramatically increases write
latency because every write must reach replicas in multiple regions before
acknowledging.

## Latency Tradeoffs

### Write Latency by Pattern

| Pattern            | ZONE FAILURE        | REGION FAILURE       |
|--------------------|---------------------|----------------------|
| REGIONAL BY TABLE  | ~10ms (home)        | ~100-200ms (home)    |
| REGIONAL BY ROW    | ~10ms (home row)    | ~100-200ms (home row)|
| GLOBAL             | ~200-400ms          | ~200-400ms           |

### Read Latency by Pattern

| Pattern            | From Home Region    | From Other Region    |
|--------------------|---------------------|----------------------|
| REGIONAL BY TABLE  | ~1-2ms              | ~50-200ms            |
| REGIONAL BY ROW    | ~1-2ms              | ~50-200ms (fan-out)  |
| GLOBAL             | ~1-2ms              | ~1-2ms               |

### Cross-Region Round Trip Costs

Typical inter-region latencies (one-way):

| Route                   | Latency     |
|-------------------------|-------------|
| us-east1 ↔ us-west2     | ~30-40ms    |
| us-east1 ↔ eu-west1     | ~70-90ms    |
| us-west2 ↔ ap-southeast1| ~120-160ms  |
| eu-west1 ↔ ap-southeast1| ~140-180ms  |

A Raft consensus write in REGION FAILURE mode requires one round trip to each
quorum participant, so expected write latency is approximately:

```
write_latency ≈ max(RTT to 2nd closest region, RTT to 3rd closest region)
```

## Follower Reads for Stale Data

### Exact Staleness

Read from the nearest replica with a guaranteed staleness bound:

```sql
-- Use the built-in function (typically ~4.2s stale)
SELECT * FROM products
    AS OF SYSTEM TIME follower_read_timestamp()
    WHERE category = 'electronics';

-- Explicit staleness
SELECT * FROM orders
    AS OF SYSTEM TIME '-10s'
    WHERE customer_id = $1;
```

The `follower_read_timestamp()` function returns the newest timestamp that is
guaranteed to be served by any replica, typically ~4.2 seconds in the past.

### Bounded Staleness

Request the freshest data available from the nearest replica:

```sql
-- Read data no older than 10 seconds
SELECT * FROM inventory
    AS OF SYSTEM TIME with_max_staleness('10s')
    WHERE product_id = $1;

-- Combines with nearest replica routing
SELECT * FROM prices
    AS OF SYSTEM TIME with_min_timestamp(now() - '5s'::INTERVAL)
    WHERE sku = $1;
```

Bounded staleness reads may be fresher than exact staleness — they use the
newest closed timestamp available at the nearest replica.

### Session-Level Configuration

```sql
-- Enable follower reads for all queries in session
SET default_transaction_use_follower_reads = on;

-- All subsequent reads use follower_read_timestamp()
SELECT * FROM products WHERE id = $1;
SELECT * FROM inventory WHERE warehouse_id = $1;

-- Disable
SET default_transaction_use_follower_reads = off;
```

**Use cases for follower reads**:
- Analytics dashboards (staleness acceptable)
- Product catalog browsing
- Reporting queries
- Search result rendering
- Any read where ~5s staleness is acceptable

## Zone Config Overrides

### Constraining Replicas

Override automatic replica placement with zone configurations:

```sql
-- Pin all replicas to US regions
ALTER TABLE us_pii CONFIGURE ZONE USING
    num_replicas = 3,
    constraints = '{+region=us-east1: 1, +region=us-west2: 1, +region=us-central1: 1}';

-- Prohibit replicas in a specific region
ALTER TABLE sensitive_data CONFIGURE ZONE USING
    constraints = '[-region=eu-west1]';

-- Require replicas in specific zones
ALTER TABLE critical_data CONFIGURE ZONE USING
    constraints = '{+zone=us-east1-a: 1, +zone=us-east1-b: 1, +zone=us-west2-a: 1}';
```

### Lease Preferences

Control where leaseholders are placed:

```sql
-- Prefer leaseholders in us-east1
ALTER TABLE orders CONFIGURE ZONE USING
    lease_preferences = '[[+region=us-east1]]';

-- Fallback preference chain
ALTER TABLE orders CONFIGURE ZONE USING
    lease_preferences = '[[+region=us-east1], [+region=us-west2]]';
```

### GC TTL and Range Size

```sql
-- Extend GC window for longer AS OF SYSTEM TIME queries
ALTER TABLE audit_log CONFIGURE ZONE USING gc.ttlseconds = 172800; -- 48h

-- Adjust range size for large tables
ALTER TABLE events CONFIGURE ZONE USING
    range_min_bytes = 134217728,  -- 128 MiB
    range_max_bytes = 536870912;  -- 512 MiB

-- View current zone config
SHOW ZONE CONFIGURATION FOR TABLE orders;
```

## Demo: 9-Node Multi-Region Cluster

### Cluster Topology

```
Region: us-east1          Region: us-west2          Region: eu-west1
┌─────────────────┐      ┌─────────────────┐      ┌─────────────────┐
│ Zone: us-east1-a│      │ Zone: us-west2-a│      │ Zone: eu-west1-a│
│   Node 1        │      │   Node 4        │      │   Node 7        │
├─────────────────┤      ├─────────────────┤      ├─────────────────┤
│ Zone: us-east1-b│      │ Zone: us-west2-b│      │ Zone: eu-west1-b│
│   Node 2        │      │   Node 5        │      │   Node 8        │
├─────────────────┤      ├─────────────────┤      ├─────────────────┤
│ Zone: us-east1-c│      │ Zone: us-west2-c│      │ Zone: eu-west1-c│
│   Node 3        │      │   Node 6        │      │   Node 9        │
└─────────────────┘      └─────────────────┘      └─────────────────┘
```

### Starting the Nodes

```bash
#!/bin/bash
# Demo: 9-node multi-region cluster on a single machine using different ports

REGIONS=("us-east1" "us-west2" "eu-west1")
ZONES_SUFFIX=("a" "b" "c")
BASE_SQL_PORT=26257
BASE_HTTP_PORT=8080
JOIN_ADDRS="localhost:26257,localhost:26260,localhost:26263"

node_num=1
for r in "${REGIONS[@]}"; do
  for z in "${ZONES_SUFFIX[@]}"; do
    sql_port=$((BASE_SQL_PORT + (node_num - 1) * 1))
    # Adjust port calculation for demo simplicity
    sql_port=$((26256 + node_num))
    http_port=$((8079 + node_num))

    cockroach start \
      --insecure \
      --locality="region=${r},zone=${r}-${z}" \
      --store="node${node_num}" \
      --listen-addr="localhost:${sql_port}" \
      --http-addr="localhost:${http_port}" \
      --join="${JOIN_ADDRS}" \
      --background

    echo "Started node ${node_num} in ${r}/${r}-${z} on port ${sql_port}"
    node_num=$((node_num + 1))
  done
done

# Initialize the cluster
cockroach init --insecure --host=localhost:26257
echo "Cluster initialized"
```

### Configuring Multi-Region

```sql
-- Create the database
CREATE DATABASE commerce;
USE commerce;

-- Configure regions
ALTER DATABASE commerce PRIMARY REGION "us-east1";
ALTER DATABASE commerce ADD REGION "us-west2";
ALTER DATABASE commerce ADD REGION "eu-west1";

-- Set survival goal
ALTER DATABASE commerce SURVIVE REGION FAILURE;

-- Verify
SHOW REGIONS FROM DATABASE commerce;
```

### Creating Tables with Locality

```sql
-- Users partitioned by region
CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email STRING NOT NULL,
    name STRING NOT NULL,
    country_code STRING(2),
    created_at TIMESTAMPTZ DEFAULT now()
);
ALTER TABLE users SET LOCALITY REGIONAL BY ROW;

-- Orders follow users
CREATE TABLE orders (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id),
    total DECIMAL(12,2) NOT NULL,
    status STRING DEFAULT 'pending',
    created_at TIMESTAMPTZ DEFAULT now()
);
ALTER TABLE orders SET LOCALITY REGIONAL BY ROW;

-- Product catalog — global read access
CREATE TABLE products (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name STRING NOT NULL,
    price DECIMAL(10,2) NOT NULL,
    description STRING
);
ALTER TABLE products SET LOCALITY GLOBAL;

-- Regional config
CREATE TABLE region_settings (
    region_code STRING PRIMARY KEY,
    currency STRING NOT NULL,
    tax_rate DECIMAL(5,4)
);
ALTER TABLE region_settings SET LOCALITY GLOBAL;
```

### Verifying Data Placement

```sql
-- Insert users in different regions
INSERT INTO users (email, name, country_code, crdb_region)
VALUES
    ('alice@example.com', 'Alice', 'US', 'us-east1'),
    ('bob@example.com', 'Bob', 'US', 'us-west2'),
    ('claire@example.com', 'Claire', 'FR', 'eu-west1');

-- Verify region assignment
SELECT id, email, crdb_region FROM users;

-- Check range distribution
SELECT
    table_name,
    range_id,
    lease_holder,
    replicas
FROM [SHOW RANGES FROM DATABASE commerce]
WHERE table_name = 'users'
ORDER BY table_name, range_id;

-- Verify leaseholder locality
SELECT
    r.range_id,
    r.lease_holder,
    g.locality
FROM crdb_internal.ranges r
JOIN crdb_internal.gossip_nodes g ON r.lease_holder = g.node_id
WHERE r.table_name = 'users'
LIMIT 10;
```

### Testing Failover

```bash
# Simulate region failure by stopping all nodes in us-west2
cockroach quit --insecure --host=localhost:26261  # Node 4
cockroach quit --insecure --host=localhost:26262  # Node 5
cockroach quit --insecure --host=localhost:26263  # Node 6

# Verify cluster still serves traffic (connect to us-east1)
cockroach sql --insecure --host=localhost:26257 \
  -e "SELECT count(*) FROM commerce.users;"

# Verify us-west2 user data is still accessible (via surviving replicas)
cockroach sql --insecure --host=localhost:26257 \
  -e "SELECT * FROM commerce.users WHERE crdb_region = 'us-west2';"
```

## Operational Best Practices

1. **Always start nodes with locality flags** — without them, CockroachDB cannot
   make intelligent data placement decisions.

2. **Use at least 3 nodes per region** (one per AZ) for zone failure survival.
   Use 3+ regions for region failure survival.

3. **Set the primary region to your highest-traffic region** to minimize latency
   for the majority of requests.

4. **Include `crdb_region` in queries** against REGIONAL BY ROW tables to avoid
   full-cluster fan-out reads.

5. **Use GLOBAL sparingly** — only for small, infrequently-updated reference
   data. Every write to a GLOBAL table must synchronize across all regions.

6. **Monitor replication lag** — under-replicated ranges indicate topology or
   capacity problems:
   ```sql
   SELECT count(*) FROM crdb_internal.ranges WHERE array_length(replicas, 1) < 3;
   ```

7. **Test failover regularly** — shut down nodes/regions in staging to verify
   your survival goals work as expected.

8. **Use follower reads** for any query that can tolerate ~5 seconds of
   staleness — this dramatically reduces cross-region read latency.

9. **Plan for region additions** — adding a region triggers data rebalancing
   which can take hours for large datasets. Schedule during low-traffic periods.

10. **Monitor inter-region latency** — use `crdb_internal.cluster_contention_events`
    and the DB Console Network dashboard to track cross-region communication health.
