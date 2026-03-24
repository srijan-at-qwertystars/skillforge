---
name: cockroachdb-patterns
description: >
  Patterns for CockroachDB distributed SQL: schema design with UUID/hash-sharded
  keys, multi-region locality (REGIONAL BY ROW/TABLE, GLOBAL), serializable
  transaction retry loops, changefeeds for CDC, follower reads, AS OF SYSTEM TIME,
  online DDL migrations, backup/restore, cluster topology, and performance tuning.
  Use for CRDB architecture, multi-region database design, and distributed SQL
  workloads. Do NOT use for plain PostgreSQL, MySQL, MongoDB, or single-node databases.
triggers:
  positive:
    - CockroachDB
    - CRDB
    - distributed SQL database
    - multi-region database
    - serializable transactions
    - changefeeds
    - cockroach sql
    - hash-sharded index
    - regional by row
    - follower reads
    - AS OF SYSTEM TIME
    - CRDB changefeed
  negative:
    - PostgreSQL without CockroachDB
    - MySQL
    - MongoDB
    - single-node database
    - general SQL tutorial
    - SQLite
    - DynamoDB
---

# CockroachDB Distributed SQL Patterns

## Architecture Fundamentals

CockroachDB is a distributed SQL database providing serializable isolation, multi-active
availability, and PostgreSQL wire-protocol compatibility. Understand these core concepts:

- **Ranges**: Data splits into ~64 MiB ranges, each replicated (default 3x) via Raft consensus.
  Every range forms a Raft group with an elected leader coordinating writes.
- **Leaseholder**: One replica per range holds the lease and serves reads/writes. Leaseholders
  are automatically balanced across nodes.
- **Gateway node**: The node receiving the SQL connection. It parses, plans, and coordinates
  distributed execution across relevant leaseholders.
- **Hybrid Logical Clocks (HLC)**: Provide causal ordering across nodes without requiring
  synchronized wall clocks.

## Schema Design

### Primary Key Rules

Never use sequential/auto-increment primary keys — they create write hotspots on a single range.

```sql
-- WRONG: sequential key creates hotspot
CREATE TABLE orders (
    id SERIAL PRIMARY KEY,
    customer_id UUID
);

-- CORRECT: UUID distributes writes across ranges
CREATE TABLE orders (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_id UUID NOT NULL,
    total DECIMAL(10,2),
    created_at TIMESTAMPTZ DEFAULT now()
);

-- CORRECT: composite key with tenant for co-locality
CREATE TABLE tenant_orders (
    tenant_id UUID,
    order_id UUID DEFAULT gen_random_uuid(),
    amount DECIMAL(10,2),
    PRIMARY KEY (tenant_id, order_id)
);
```

### Hash-Sharded Indexes

Use hash-sharded indexes when you must index sequential values (timestamps, counters):

```sql
-- Spread sequential timestamp writes across 16 buckets
CREATE INDEX idx_events_ts ON events (created_at)
    USING HASH WITH (bucket_count = 16);

-- Hash-sharded primary key for time-series
CREATE TABLE metrics (
    ts TIMESTAMPTZ NOT NULL,
    sensor_id UUID NOT NULL,
    value FLOAT,
    PRIMARY KEY (ts, sensor_id) USING HASH WITH (bucket_count = 8)
);
```

Trade-off: hash-sharding eliminates write hotspots but scatters logically contiguous data,
slowing ordered range scans.

### Index Best Practices

- Always define explicit primary keys — never rely on CockroachDB's hidden `rowid`.
- Align multi-column index order with most frequent query filter order.
- Use `STORING (col1, col2)` to create covering indexes and avoid index joins.
- Drop unused indexes — each index adds write amplification.
- Use `EXPLAIN ANALYZE` to verify index usage and spot full table scans.

```sql
CREATE INDEX idx_orders_customer ON orders (customer_id)
    STORING (total, created_at);
```

## Multi-Region Configuration

### Setup

Start nodes with locality flags:
```bash
cockroach start --locality=region=us-east1,zone=us-east1-b ...
```

Configure the database:
```sql
ALTER DATABASE mydb PRIMARY REGION "us-east1";
ALTER DATABASE mydb ADD REGION "us-west2";
ALTER DATABASE mydb ADD REGION "eu-west1";
```

### Table Locality Patterns

**REGIONAL BY TABLE** — entire table homed in one region:
```sql
-- Fast reads/writes from home region; higher latency elsewhere
ALTER TABLE config SET LOCALITY REGIONAL BY TABLE IN "us-east1";
```

**REGIONAL BY ROW** — each row homed in its own region:
```sql
ALTER TABLE users SET LOCALITY REGIONAL BY ROW;

-- crdb_region column added automatically; set per-row
INSERT INTO users (name, email, crdb_region)
VALUES ('Alice', 'alice@example.com', 'eu-west1');

-- Omitting crdb_region defaults to gateway node's region
```

**GLOBAL** — replicated everywhere, fast reads globally, slow writes:
```sql
-- Use for reference/lookup tables with infrequent writes
ALTER TABLE currencies SET LOCALITY GLOBAL;
ALTER TABLE feature_flags SET LOCALITY GLOBAL;
```

### Survival Goals

```sql
-- Survive availability zone failure (default, 3 replicas)
ALTER DATABASE mydb SURVIVE ZONE FAILURE;

-- Survive entire region failure (requires 5+ replicas, 3+ regions)
ALTER DATABASE mydb SURVIVE REGION FAILURE;
```

### Decision Matrix

| Pattern           | Read Latency     | Write Latency      | Use Case                        |
|-------------------|------------------|--------------------|---------------------------------|
| REGIONAL BY TABLE | Fast (home)      | Fast (home)        | Region-specific tables          |
| REGIONAL BY ROW   | Fast (row home)  | Fast (row home)    | Per-user/tenant geo-partitioned |
| GLOBAL            | Fast (anywhere)  | Slow (global RTT)  | Reference data, feature flags   |

## Serializable Transactions & Retry Handling

CockroachDB uses serializable isolation exclusively. Concurrent conflicts produce
SQLSTATE `40001` errors that require client-side retry.

### Retry Loop Pattern

```sql
BEGIN;
SAVEPOINT cockroach_restart;

-- Transaction statements here
UPDATE accounts SET balance = balance - 100 WHERE id = 'src';
UPDATE accounts SET balance = balance + 100 WHERE id = 'dst';

RELEASE SAVEPOINT cockroach_restart;
COMMIT;

-- On 40001 error: ROLLBACK TO SAVEPOINT cockroach_restart; then retry
```

### Application-Level Retry (Python)

```python
import psycopg2
import time

def run_transaction(conn, callback, max_retries=10):
    sleep = 0.1
    for attempt in range(max_retries):
        try:
            with conn.cursor() as cur:
                callback(cur)
            conn.commit()
            return
        except psycopg2.extensions.TransactionRollbackError:
            conn.rollback()
            time.sleep(sleep)
            sleep = min(sleep * 2, 5.0)
    raise Exception("Transaction failed after max retries")

def transfer(cur):
    cur.execute("UPDATE accounts SET balance = balance - 100 WHERE id = 'src'")
    cur.execute("UPDATE accounts SET balance = balance + 100 WHERE id = 'dst'")

run_transaction(conn, transfer)
```

### Reducing Contention

- Keep transactions short — minimize rows touched and time held.
- Use `SELECT FOR UPDATE` to acquire locks early and reduce retries.
- Avoid cross-range transactions when possible.
- Monitor contention via `crdb_internal.cluster_contention_events`.

## Performance Tuning

### Follower Reads

Serve reads from the nearest replica (4.2s staleness) to reduce cross-region latency:

```sql
-- Single query
SELECT * FROM products
    AS OF SYSTEM TIME follower_read_timestamp()
    WHERE category = 'electronics';

-- Entire session
SET default_transaction_use_follower_reads = on;

-- Bounded staleness (experimental)
SELECT * FROM products
    AS OF SYSTEM TIME with_max_staleness('10s');
```

Use follower reads for dashboards, analytics, and any read tolerating slight staleness.

### AS OF SYSTEM TIME

Read historical data without contention:

```sql
-- Read data as of 30 seconds ago
SELECT * FROM orders AS OF SYSTEM TIME '-30s';

-- Point-in-time reporting
SELECT count(*) FROM orders
    AS OF SYSTEM TIME '2024-01-15 12:00:00';
```

Constrained by the GC TTL window (default 4 hours). Adjust with:
```sql
ALTER TABLE orders CONFIGURE ZONE USING gc.ttlseconds = 86400; -- 24h
```

### Query Optimization

```sql
-- Analyze query plan
EXPLAIN ANALYZE SELECT * FROM orders WHERE customer_id = $1;

-- Find full table scans
SHOW FULL TABLE SCANS;

-- Check index usage statistics
SELECT * FROM crdb_internal.index_usage_statistics
    WHERE total_reads = 0 AND created_at < now() - INTERVAL '7 days';
```

### Batch Operations

```sql
-- Multi-row INSERT (optimal: 100-500 rows per batch)
INSERT INTO events (id, type, data) VALUES
    (gen_random_uuid(), 'click', '{}'),
    (gen_random_uuid(), 'view', '{}');

-- Use UPSERT for idempotent inserts (no secondary index conflicts)
UPSERT INTO cache (key, value, updated_at)
VALUES ('k1', 'v1', now());

-- IMPORT for bulk data loading (bypasses SQL layer)
IMPORT INTO events CSV DATA ('gs://bucket/events.csv');
```

## Changefeeds (CDC)

### Core Changefeed (no license required)

```sql
-- Enable rangefeeds first
SET CLUSTER SETTING kv.rangefeed.enabled = true;

-- Emit to stdout (development)
EXPERIMENTAL CHANGEFEED FOR orders;
```

### Enterprise Changefeed to Kafka

```sql
CREATE CHANGEFEED FOR TABLE orders, customers
INTO 'kafka://broker1:9092?topic_prefix=crdb_'
WITH
    format = avro,
    confluent_schema_registry = 'http://registry:8081',
    diff,
    resolved = '10s',
    min_checkpoint_frequency = '30s';
```

### Webhook Sink

```sql
CREATE CHANGEFEED FOR TABLE orders
INTO 'webhook-https://api.example.com/cdc'
WITH
    format = json,
    resolved = '30s';
```

### Changefeed Management

```sql
-- Monitor running changefeeds
SHOW CHANGEFEED JOBS;

-- Pause/resume
PAUSE JOB <job_id>;
RESUME JOB <job_id>;

-- Handle schema changes
-- schema_change_policy: 'backfill' (default), 'stop', 'ignore'
CREATE CHANGEFEED FOR orders INTO 'kafka://...'
    WITH schema_change_policy = 'stop';
```

## Online Schema Changes

CockroachDB performs DDL without downtime. Execute schema changes as single implicit
transactions (not inside BEGIN/COMMIT blocks):

```sql
-- Add column (online, non-blocking)
ALTER TABLE orders ADD COLUMN status STRING DEFAULT 'pending';

-- Add index (built in background)
CREATE INDEX CONCURRENTLY idx_orders_status ON orders (status);

-- Drop column
ALTER TABLE orders DROP COLUMN legacy_field;
```

Rules:
- Run one schema change per statement — do not batch DDL in explicit transactions.
- Monitor progress: `SHOW JOBS WHERE job_type = 'SCHEMA CHANGE';`
- Schema changes are resumable — they survive node restarts.

## Backup & Restore

### Full and Incremental Backups

```sql
-- Full cluster backup to cloud storage
BACKUP INTO 'gs://my-bucket/backups'
    AS OF SYSTEM TIME '-10s';

-- Incremental (references latest full)
BACKUP INTO LATEST IN 'gs://my-bucket/backups';

-- Scheduled backups
CREATE SCHEDULE daily_backup FOR BACKUP INTO 'gs://my-bucket/backups'
    RECURRING '@daily'
    WITH SCHEDULE OPTIONS first_run = 'now';
```

### Restore

```sql
-- Restore full cluster
RESTORE FROM LATEST IN 'gs://my-bucket/backups';

-- Restore single table
RESTORE TABLE orders FROM LATEST IN 'gs://my-bucket/backups';

-- Point-in-time restore
RESTORE FROM LATEST IN 'gs://my-bucket/backups'
    AS OF SYSTEM TIME '2024-06-15 08:00:00';
```

### Backup Destinations

Supported: `gs://` (GCS), `s3://` (AWS S3), `azure://` (Azure Blob),
`nodelocal://` (node-local filesystem), `userfile://` (cluster-local).

## cockroach CLI Essentials

```bash
cockroach start --insecure --store=node1 --listen-addr=localhost:26257 \
    --http-addr=localhost:8080 --join=localhost:26257,localhost:26258
cockroach init --insecure --host=localhost:26257
cockroach sql --insecure --host=localhost:26257
cockroach node status --insecure --host=localhost:26257
cockroach node decommission <node-id> --insecure --host=localhost:26257
cockroach debug zip debug.zip --insecure --host=localhost:26257
```

## Monitoring & Observability

Access DB Console at `http://<node>:8080` for SQL, Storage, Replication, and
Hardware dashboards. CockroachDB exposes Prometheus metrics at `/_status/vars`.

```sql
SELECT * FROM crdb_internal.cluster_sessions;
SELECT * FROM crdb_internal.node_statement_statistics
    WHERE mean_service_lat > 1.0 ORDER BY mean_service_lat DESC;
SELECT lease_holder, count(*) FROM crdb_internal.ranges_no_leases
    GROUP BY lease_holder;
SELECT * FROM crdb_internal.cluster_contention_events
    ORDER BY count DESC LIMIT 20;
```

Alert on: `sql_service_latency_p99`, `ranges_underreplicated`,
`capacity_available` < 20%, `txn_restarts` spikes.

## PostgreSQL Compatibility Notes

CockroachDB supports most PostgreSQL syntax with key differences:
- **Supported**: JOINs, CTEs, window functions, JSON/JSONB, arrays, GIN indexes, `pg_catalog`
- **Not supported**: stored procedures with PL/pgSQL (limited), extensions (PostGIS partial),
  `LISTEN`/`NOTIFY`, advisory locks, XA transactions, custom operators
- **Different behavior**: all transactions are serializable (no READ COMMITTED option by
  default), `SERIAL` creates unique_rowid() not sequences, temp tables are session-scoped

Use `crdb_internal` schema for CockroachDB-specific introspection instead of `pg_stat_*` views.

## Common Anti-Patterns

- Using `SERIAL`/`INT` PKs → hotspots. Use UUID or hash-sharded keys.
- Long-running transactions → lock contention and retry storms. Keep txns under 1 minute.
- Missing retry logic → application errors on serialization conflicts.
- Explicit transaction DDL → schema changes fail. Use implicit (single-statement) DDL.
- Ignoring `crdb_region` in REGIONAL BY ROW → data placed at gateway, not user's region.
- Over-indexing → write amplification. Audit with `index_usage_statistics`.
- Cross-region JOINs on hot paths → high latency. Co-locate joined tables in same region.

## References

In-depth guides in `references/`:

| File | Description |
|------|-------------|
| [multi-region-guide.md](references/multi-region-guide.md) | Deep dive into multi-region: locality flags, topology, REGIONAL BY ROW/TABLE, GLOBAL tables, survival goals, latency tradeoffs, follower reads, zone config overrides, 9-node cluster demo |
| [troubleshooting.md](references/troubleshooting.md) | Common issues: 40001 retry errors, contention analysis, hot ranges, leaseholder rebalancing, clock skew, stuck decommission, changefeed lag, OOM, slow schema changes, range splits, admission control |
| [migration-from-postgres.md](references/migration-from-postgres.md) | PostgreSQL migration: compatible/incompatible features, MOLT tools, schema conversion, data import, retry logic, ORM compatibility (ActiveRecord, SQLAlchemy, GORM, Prisma, Django, Hibernate) |

## Scripts

Operational scripts in `scripts/` (all executable):

| Script | Purpose |
|--------|---------|
| [setup-cockroachdb-cluster.sh](scripts/setup-cockroachdb-cluster.sh) | Stand up a 3-node Docker cluster, init, create database, verify |
| [check-cluster-health.sh](scripts/check-cluster-health.sh) | Health check: node status, ranges, replication, hotspots, storage, clock offsets, license |
| [backup-restore.sh](scripts/backup-restore.sh) | Full/incremental backup, restore (cluster, database, table), scheduled backups |

## Assets

Ready-to-use configuration and code in `assets/`:

| File | Description |
|------|-------------|
| [docker-compose.yml](assets/docker-compose.yml) | 3-node CockroachDB cluster with HAProxy load balancer |
| [multi-region-schema.sql](assets/multi-region-schema.sql) | Complete multi-region schema: REGIONAL BY ROW, GLOBAL, REGIONAL BY TABLE examples |
| [retry-transaction.go](assets/retry-transaction.go) | Go (pgx) transaction retry with exponential backoff |
| [retry-transaction.py](assets/retry-transaction.py) | Python (psycopg2) transaction retry with SAVEPOINT protocol |
| [cockroachdb-helm-values.yaml](assets/cockroachdb-helm-values.yaml) | Helm values for Kubernetes deployment with TLS, monitoring, topology spread |

<!-- tested: pass -->
