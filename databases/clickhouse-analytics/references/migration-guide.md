# Migrating to ClickHouse

## Table of Contents

- [Migration Overview](#migration-overview)
- [From PostgreSQL](#from-postgresql)
- [From MySQL](#from-mysql)
- [From Elasticsearch](#from-elasticsearch)
- [From BigQuery](#from-bigquery)
- [Data Transfer Tools](#data-transfer-tools)
- [Schema Design Translation](#schema-design-translation)
- [Query Syntax Differences](#query-syntax-differences)
- [ETL Pipeline Setup](#etl-pipeline-setup)

---

## Migration Overview

### When to Migrate to ClickHouse
- Analytical queries on billions of rows are too slow in your current system.
- You need sub-second aggregation for dashboards and reporting.
- Log/event/time-series data volume exceeds what your OLTP database handles efficiently.
- You're paying too much for managed OLAP solutions (BigQuery, Snowflake).

### When NOT to Migrate
- You need ACID transactions and strong consistency.
- Your workload is primarily OLTP (single-row reads/writes, updates, deletes).
- Dataset is small (<1M rows) — PostgreSQL/MySQL are fine.
- You need full-text search with relevance scoring (keep Elasticsearch).

### Migration Strategy
1. **Parallel run** — Keep the source system active. Dual-write or replicate to ClickHouse.
2. **Read migration first** — Point dashboards/analytics at ClickHouse while writes stay in the source.
3. **Full cutover** — Only when ClickHouse is validated with production data and query patterns.

---

## From PostgreSQL

### Data Type Mapping

| PostgreSQL | ClickHouse | Notes |
|---|---|---|
| `SERIAL` / `BIGSERIAL` | `UInt32` / `UInt64` | No auto-increment. Generate IDs externally or use `generateUUIDv4()`. |
| `INTEGER` | `Int32` | Use unsigned (`UInt32`) when values are non-negative. |
| `BIGINT` | `Int64` / `UInt64` | |
| `NUMERIC(p,s)` / `DECIMAL` | `Decimal(p,s)` | ClickHouse supports Decimal32/64/128/256. |
| `REAL` / `DOUBLE PRECISION` | `Float32` / `Float64` | |
| `VARCHAR(n)` / `TEXT` | `String` | No length limit in ClickHouse. |
| `BOOLEAN` | `UInt8` | Use 0/1. No native boolean type. |
| `DATE` | `Date` / `Date32` | `Date32` for dates before 1970 or after 2149. |
| `TIMESTAMP` | `DateTime` / `DateTime64(3)` | `DateTime64` for sub-second precision. |
| `TIMESTAMPTZ` | `DateTime64(3, 'UTC')` | Always store in UTC, convert at query time. |
| `UUID` | `UUID` | Native UUID type. |
| `JSONB` | `String` + JSONExtract / `JSON` | Use native JSON type (v25.3+) or store as String and extract. |
| `ARRAY` | `Array(T)` | Fully supported. |
| `INET` / `CIDR` | `IPv4` / `IPv6` | Native IP types. |
| `ENUM` | `Enum8` / `Enum16` | Or use `LowCardinality(String)` for flexibility. |
| `HSTORE` | `Map(String, String)` | |

### Schema Translation Example

**PostgreSQL:**
```sql
CREATE TABLE orders (
    id BIGSERIAL PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES users(id),
    status VARCHAR(20) NOT NULL DEFAULT 'pending',
    total NUMERIC(10,2) NOT NULL,
    metadata JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_orders_user ON orders(user_id);
CREATE INDEX idx_orders_status ON orders(status);
CREATE INDEX idx_orders_created ON orders(created_at);
```

**ClickHouse:**
```sql
CREATE TABLE orders (
    id UInt64,
    user_id UInt64,
    status LowCardinality(String) DEFAULT 'pending',
    total Decimal(10,2),
    metadata String,  -- or JSON type in v25.3+
    created_at DateTime64(3, 'UTC'),
    updated_at DateTime64(3, 'UTC')
)
ENGINE = ReplacingMergeTree(updated_at)
PARTITION BY toYYYYMM(created_at)
ORDER BY (status, user_id, created_at)
SETTINGS index_granularity = 8192;
```

Key differences:
- No SERIAL/auto-increment — generate IDs externally.
- No foreign keys — denormalize or use dictionaries.
- `ReplacingMergeTree` handles deduplication by keeping the latest `updated_at`.
- ORDER BY replaces indexes — design it for your query patterns.
- Use `LowCardinality(String)` for low-cardinality string columns.

### Data Transfer Methods

**Method 1: PostgreSQL integration engine (small-medium tables)**
```sql
CREATE TABLE pg_orders
ENGINE = PostgreSQL('pg-host:5432', 'mydb', 'orders', 'reader', 'pass');

INSERT INTO orders
SELECT id, user_id, status, total, metadata::String, created_at, updated_at
FROM pg_orders;
```

**Method 2: pg_dump + clickhouse-local (large tables)**
```bash
# Export from PostgreSQL as CSV
psql -h pg-host -U reader -d mydb \
  -c "\COPY (SELECT * FROM orders) TO '/tmp/orders.csv' WITH CSV HEADER"

# Import into ClickHouse
clickhouse-local --query "
  INSERT INTO FUNCTION remoteSecure('ch-host:9440', 'mydb', 'orders', 'user', 'pass')
  SELECT * FROM file('/tmp/orders.csv', 'CSVWithNames',
    'id UInt64, user_id UInt64, status String, total Decimal(10,2),
     metadata String, created_at DateTime64(3), updated_at DateTime64(3)')
"
```

**Method 3: MaterializedPostgreSQL for continuous replication**
```sql
CREATE DATABASE pg_replica
ENGINE = MaterializedPostgreSQL('pg-host:5432', 'mydb', 'user', 'pass')
SETTINGS materialized_postgresql_tables_list = 'orders,users,products';
-- Continuously replicates changes via PostgreSQL logical replication
```

---

## From MySQL

### Data Type Mapping

| MySQL | ClickHouse | Notes |
|---|---|---|
| `TINYINT` | `Int8` / `UInt8` | |
| `INT` | `Int32` / `UInt32` | |
| `BIGINT` | `Int64` / `UInt64` | |
| `FLOAT` / `DOUBLE` | `Float32` / `Float64` | |
| `DECIMAL(p,s)` | `Decimal(p,s)` | |
| `VARCHAR(n)` / `TEXT` | `String` | |
| `DATETIME` | `DateTime` | |
| `TIMESTAMP` | `DateTime` | MySQL auto-updates; ClickHouse does not. |
| `DATE` | `Date` | |
| `ENUM(...)` | `Enum8` / `LowCardinality(String)` | |
| `JSON` | `String` + JSONExtract / `JSON` | |
| `BLOB` / `BINARY` | `String` | Store as-is or base64 encode. |
| `BIT` | `UInt8` / `UInt64` | |

### Data Transfer Methods

**Method 1: MySQL integration engine**
```sql
CREATE TABLE mysql_orders
ENGINE = MySQL('mysql-host:3306', 'mydb', 'orders', 'reader', 'pass');

INSERT INTO orders SELECT * FROM mysql_orders;
```

**Method 2: MySQL database engine (mirror all tables)**
```sql
CREATE DATABASE mysql_mirror
ENGINE = MySQL('mysql-host:3306', 'mydb', 'reader', 'pass');

-- Query directly
SELECT count() FROM mysql_mirror.orders WHERE status = 'completed';

-- Materialize into local MergeTree
INSERT INTO local_orders SELECT * FROM mysql_mirror.orders;
```

**Method 3: mysqldump + clickhouse-client**
```bash
# Export from MySQL
mysqldump --tab=/tmp/export --fields-terminated-by=',' --no-create-info mydb orders

# Import into ClickHouse
clickhouse-client --query "
  INSERT INTO orders FORMAT CSV" < /tmp/export/orders.txt
```

**Method 4: MaterializedMySQL for CDC**
```sql
CREATE DATABASE mysql_cdc
ENGINE = MaterializedMySQL('mysql-host:3306', 'mydb', 'user', 'pass')
SETTINGS allows_query_when_mysql_lost = 1;
-- Uses MySQL binlog for real-time replication
```

---

## From Elasticsearch

### Conceptual Mapping

| Elasticsearch | ClickHouse | Notes |
|---|---|---|
| Index | Table | |
| Document | Row | |
| Field | Column | |
| Mapping | Schema (CREATE TABLE) | ClickHouse is strongly typed. |
| `text` field | `String` + token bloom filter | No full-text relevance scoring. |
| `keyword` | `LowCardinality(String)` | |
| `long` / `integer` | `Int64` / `Int32` | |
| `date` | `DateTime` / `DateTime64` | |
| `nested` | `Nested` / `Array(Tuple(...))` | |
| `object` | `Tuple(...)` / JSON type | |
| Aggregation | GROUP BY + aggregate functions | |
| `_id` | Define your own primary key | |

### Migration Strategy

1. **Export from Elasticsearch** using `elasticdump`, Logstash, or scroll API:
   ```bash
   # Using elasticdump to export as JSON
   elasticdump \
     --input=http://es-host:9200/logs \
     --output=/tmp/logs.json \
     --type=data \
     --limit=10000
   ```

2. **Import into ClickHouse:**
   ```bash
   clickhouse-client --query "INSERT INTO logs FORMAT JSONEachRow" < /tmp/logs.json
   ```

3. **Rewrite queries:**

   **Elasticsearch:**
   ```json
   {
     "query": { "range": { "timestamp": { "gte": "2025-01-01" } } },
     "aggs": {
       "by_level": {
         "terms": { "field": "level" },
         "aggs": { "count": { "value_count": { "field": "_id" } } }
       }
     }
   }
   ```

   **ClickHouse:**
   ```sql
   SELECT level, count() AS cnt
   FROM logs
   WHERE timestamp >= '2025-01-01'
   GROUP BY level
   ORDER BY cnt DESC;
   ```

### What ClickHouse Cannot Replace
- Full-text search with BM25/TF-IDF relevance scoring.
- Fuzzy matching and complex text analysis (stemming, synonyms).
- Per-document ACLs (use ClickHouse row policies instead).

For hybrid: keep Elasticsearch for search, use ClickHouse for analytics. Route data to both.

---

## From BigQuery

### Conceptual Mapping

| BigQuery | ClickHouse | Notes |
|---|---|---|
| Dataset | Database | |
| Table | Table | |
| `INT64` | `Int64` | |
| `FLOAT64` | `Float64` | |
| `NUMERIC` / `BIGNUMERIC` | `Decimal(p,s)` | |
| `STRING` | `String` | |
| `BYTES` | `String` | |
| `BOOL` | `UInt8` | |
| `DATE` | `Date` | |
| `TIMESTAMP` | `DateTime64(6, 'UTC')` | BigQuery uses microseconds. |
| `DATETIME` | `DateTime` | |
| `STRUCT` | `Tuple(...)` | |
| `ARRAY` | `Array(T)` | |
| `JSON` | `JSON` / `String` | |
| Partitioned table | `PARTITION BY` | |
| Clustered table | `ORDER BY` | Clustering ≈ ordering key in ClickHouse. |
| Materialized view | Materialized view | Similar concept, different execution model. |

### Data Transfer

**Method 1: Export to GCS, import via s3/gcs function**
```bash
# Export from BigQuery to GCS as Parquet
bq extract --destination_format=PARQUET \
  'project:dataset.table' \
  'gs://my-bucket/export/table_*.parquet'
```

```sql
-- Import from GCS into ClickHouse
INSERT INTO events
SELECT * FROM gcs(
    'https://storage.googleapis.com/my-bucket/export/table_*.parquet',
    'HMAC_KEY', 'HMAC_SECRET',
    'Parquet'
);
```

**Method 2: BigQuery → CSV → clickhouse-local**
```bash
bq query --format=csv --max_rows=0 \
  'SELECT * FROM `project.dataset.table`' > /tmp/export.csv

clickhouse-local --query "
  INSERT INTO FUNCTION remoteSecure('ch-host', 'db', 'table', 'user', 'pass')
  SELECT * FROM file('/tmp/export.csv', 'CSVWithNames')
"
```

### Query Translation Examples

**BigQuery:**
```sql
SELECT
  DATE_TRUNC(created_at, MONTH) AS month,
  COUNT(DISTINCT user_id) AS unique_users,
  APPROX_QUANTILES(duration_ms, 100)[OFFSET(95)] AS p95
FROM `project.dataset.events`
WHERE created_at >= '2025-01-01'
GROUP BY month
ORDER BY month;
```

**ClickHouse:**
```sql
SELECT
  toStartOfMonth(created_at) AS month,
  uniq(user_id) AS unique_users,
  quantileTDigest(0.95)(duration_ms) AS p95
FROM events
WHERE created_at >= '2025-01-01'
GROUP BY month
ORDER BY month;
```

---

## Data Transfer Tools

### clickhouse-local

A standalone ClickHouse binary for local data processing — no server required.

```bash
# Convert CSV to Parquet
clickhouse-local --query "
  SELECT * FROM file('input.csv', 'CSVWithNames')
  INTO OUTFILE 'output.parquet' FORMAT Parquet
"

# Transform and load directly to a remote ClickHouse server
clickhouse-local --query "
  INSERT INTO FUNCTION remoteSecure(
    'clickhouse-host:9440', 'analytics', 'events', 'user', 'pass'
  )
  SELECT
    toDateTime(timestamp) AS ts,
    toUInt64(user_id) AS user_id,
    event_type,
    JSONExtractFloat(payload, 'value') AS value
  FROM file('raw_events.json', 'JSONEachRow')
"

# Process multiple files with glob
clickhouse-local --query "
  SELECT count(), min(ts), max(ts)
  FROM file('/data/logs/*.csv.gz', 'CSVWithNames')
"
```

### clickhouse-copier

Cluster-to-cluster data copying tool. Configured via XML task file.

```xml
<!-- copier_task.xml -->
<clickhouse>
    <remote_servers>
        <source_cluster>
            <shard><replica><host>source-host</host><port>9000</port></replica></shard>
        </source_cluster>
        <destination_cluster>
            <shard><replica><host>dest-host</host><port>9000</port></replica></shard>
        </destination_cluster>
    </remote_servers>
    <tables>
        <table_events>
            <cluster_pull>source_cluster</cluster_pull>
            <database_pull>analytics</database_pull>
            <table_pull>events</table_pull>
            <cluster_push>destination_cluster</cluster_push>
            <database_push>analytics</database_push>
            <table_push>events</table_push>
            <engine>ENGINE = MergeTree() ORDER BY (event_type, ts)</engine>
            <sharding_key>rand()</sharding_key>
        </table_events>
    </tables>
</clickhouse>
```

```bash
clickhouse-copier --config copier_config.xml --task-file copier_task.xml
```

### dbt-clickhouse

SQL-based transformation framework for ClickHouse.

```bash
pip install dbt-clickhouse
```

**profiles.yml:**
```yaml
clickhouse_analytics:
  target: dev
  outputs:
    dev:
      type: clickhouse
      host: clickhouse-host
      port: 8443
      user: dbt_user
      password: "{{ env_var('CH_PASSWORD') }}"
      schema: analytics
      secure: true
      driver: native
      connect_timeout: 10
```

**Example dbt model (models/daily_revenue.sql):**
```sql
{{ config(
    materialized='table',
    engine='MergeTree()',
    order_by='(day)',
    partition_by='toYYYYMM(day)'
) }}

SELECT
    toDate(order_time) AS day,
    sum(amount) AS revenue,
    uniq(user_id) AS unique_buyers,
    count() AS order_count
FROM {{ source('raw', 'orders') }}
WHERE order_status = 'completed'
GROUP BY day
```

### Other ETL Tools

| Tool | Use Case |
|---|---|
| **Debezium + Kafka** | CDC from PostgreSQL/MySQL to ClickHouse via Kafka engine |
| **Airbyte** | Managed connectors for many sources to ClickHouse |
| **Sling** | CLI tool for PostgreSQL/MySQL → ClickHouse bulk loads |
| **Vector** | Log pipeline tool with ClickHouse sink |
| **Benthos / Redpanda Connect** | Stream processing with ClickHouse output |

---

## Schema Design Translation

### Key Principles

1. **Denormalize aggressively** — No foreign keys, JOINs are expensive. Flatten dimension attributes into fact tables at write time.

2. **Design ORDER BY for query patterns** — This replaces B-tree indexes. Place most-filtered columns first.

3. **Choose the right engine** — Don't default to MergeTree for everything:
   - Need deduplication? → `ReplacingMergeTree`
   - Need running totals? → `SummingMergeTree`
   - Need pre-aggregation? → `AggregatingMergeTree`

4. **Replace NULLs with defaults** — Avoid `Nullable` types. Use `0`, `''`, or sentinel dates.

5. **Use LowCardinality** — For any string column with fewer than ~10K distinct values.

### OLTP → OLAP Schema Transformation

**OLTP (3NF):**
```
users(id, name, country, plan)
orders(id, user_id, status, total, created_at)
order_items(id, order_id, product_id, qty, price)
products(id, name, category)
```

**OLAP (ClickHouse denormalized):**
```sql
CREATE TABLE order_facts (
    order_id UInt64,
    order_date Date,
    order_time DateTime,
    user_id UInt64,
    user_country LowCardinality(String),
    user_plan LowCardinality(String),
    product_id UInt32,
    product_name String,
    product_category LowCardinality(String),
    status LowCardinality(String),
    quantity UInt16,
    item_price Decimal(10,2),
    order_total Decimal(10,2)
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(order_date)
ORDER BY (product_category, user_country, order_date, user_id);
```

---

## Query Syntax Differences

### PostgreSQL → ClickHouse

| PostgreSQL | ClickHouse |
|---|---|
| `DATE_TRUNC('month', ts)` | `toStartOfMonth(ts)` |
| `EXTRACT(EPOCH FROM ts)` | `toUnixTimestamp(ts)` |
| `NOW()` | `now()` |
| `CURRENT_DATE` | `today()` |
| `ts AT TIME ZONE 'US/Eastern'` | `toTimezone(ts, 'US/Eastern')` |
| `COALESCE(a, b)` | `coalesce(a, b)` or `ifNull(a, b)` |
| `string \|\| string` | `concat(s1, s2)` or `s1 \|\| s2` |
| `LIKE 'abc%'` | `LIKE 'abc%'` (same) |
| `ILIKE` | `ilike` (or `lower(col) LIKE`) |
| `ARRAY_AGG(x)` | `groupArray(x)` |
| `STRING_AGG(x, ',')` | `arrayStringConcat(groupArray(x), ',')` |
| `COUNT(DISTINCT x)` | `uniq(x)` (approx) or `uniqExact(x)` |
| `PERCENTILE_CONT(0.95)` | `quantileTDigest(0.95)(x)` |
| `GENERATE_SERIES(...)` | `numbers(N)` / `WITH FILL` |
| `LATERAL JOIN` | `arrayJoin` or `ARRAY JOIN` |
| `UPDATE ... SET` | `ALTER TABLE ... UPDATE` (async mutation) |
| `DELETE FROM` | `ALTER TABLE ... DELETE` (async mutation) or lightweight delete `DELETE FROM` |
| `UPSERT` / `ON CONFLICT` | Use `ReplacingMergeTree` with `FINAL` |
| Transactions (`BEGIN/COMMIT`) | Not supported. Atomic inserts only. |

### MySQL → ClickHouse

| MySQL | ClickHouse |
|---|---|
| `DATE_FORMAT(ts, '%Y-%m')` | `formatDateTime(ts, '%Y-%m')` |
| `UNIX_TIMESTAMP(ts)` | `toUnixTimestamp(ts)` |
| `GROUP_CONCAT(x SEPARATOR ',')` | `arrayStringConcat(groupArray(x), ',')` |
| `IFNULL(a, b)` | `ifNull(a, b)` |
| `IF(cond, a, b)` | `if(cond, a, b)` (same) |
| `LIMIT offset, count` | `LIMIT count OFFSET offset` |
| `AUTO_INCREMENT` | Not supported. Use UUIDs or external sequences. |
| Subquery in FROM | Supported (same) |
| Stored procedures | Not supported. Use SQL UDFs for simple cases. |

---

## ETL Pipeline Setup

### Architecture Pattern: OLTP → Kafka → ClickHouse

```
┌──────────┐    CDC     ┌─────────┐  Stream  ┌────────────┐
│PostgreSQL ├───────────►│  Kafka  ├─────────►│ ClickHouse │
│  (OLTP)  │  Debezium  │         │  Kafka   │  (OLAP)    │
└──────────┘            └─────────┘  Engine   └────────────┘
```

**Step 1: Set up Debezium connector for PostgreSQL:**
```json
{
  "name": "pg-connector",
  "config": {
    "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
    "database.hostname": "pg-host",
    "database.port": "5432",
    "database.user": "debezium",
    "database.password": "pass",
    "database.dbname": "mydb",
    "table.include.list": "public.orders,public.users",
    "topic.prefix": "cdc",
    "plugin.name": "pgoutput"
  }
}
```

**Step 2: ClickHouse Kafka engine to consume CDC events:**
```sql
CREATE TABLE kafka_orders (
    before String,
    after String,
    op String
) ENGINE = Kafka
SETTINGS kafka_broker_list = 'kafka:9092',
         kafka_topic_list = 'cdc.public.orders',
         kafka_group_name = 'ch_cdc',
         kafka_format = 'JSONEachRow';

CREATE MATERIALIZED VIEW kafka_orders_mv TO orders AS
SELECT
    JSONExtractUInt64(after, 'id') AS id,
    JSONExtractUInt64(after, 'user_id') AS user_id,
    JSONExtractString(after, 'status') AS status,
    toDecimal64(JSONExtractFloat(after, 'total'), 2) AS total,
    parseDateTimeBestEffort(JSONExtractString(after, 'created_at')) AS created_at,
    parseDateTimeBestEffort(JSONExtractString(after, 'updated_at')) AS updated_at
FROM kafka_orders
WHERE op IN ('c', 'u', 'r');  -- create, update, read (snapshot)
```

### Batch ETL Pattern

```bash
#!/bin/bash
# Daily ETL from PostgreSQL to ClickHouse
DATE=$(date -d 'yesterday' +%Y-%m-%d)

# Extract
psql -h pg-host -U reader -d mydb \
  -c "\COPY (SELECT * FROM orders WHERE created_at::date = '${DATE}')
      TO '/tmp/orders_${DATE}.csv' WITH CSV HEADER"

# Load
clickhouse-client --host ch-host --secure \
  --query "INSERT INTO orders FORMAT CSVWithNames" \
  < /tmp/orders_${DATE}.csv

# Verify
EXPECTED=$(psql -h pg-host -U reader -d mydb -tAc \
  "SELECT count(*) FROM orders WHERE created_at::date = '${DATE}'")
ACTUAL=$(clickhouse-client --host ch-host -q \
  "SELECT count() FROM orders WHERE toDate(created_at) = '${DATE}'")

if [ "$EXPECTED" != "$ACTUAL" ]; then
  echo "ROW COUNT MISMATCH: expected=${EXPECTED} actual=${ACTUAL}"
  exit 1
fi

rm /tmp/orders_${DATE}.csv
```

### Validation Checklist

After migration, verify:

- [ ] Row counts match between source and ClickHouse.
- [ ] Aggregate sums/counts match (revenue, user counts).
- [ ] NULL handling is correct (sentinels vs Nullable).
- [ ] Timezone conversions are correct.
- [ ] Query performance meets SLA (run key dashboard queries).
- [ ] Materialized views are populating correctly.
- [ ] TTL and partition lifecycle are configured.
- [ ] Backup and monitoring are in place.
