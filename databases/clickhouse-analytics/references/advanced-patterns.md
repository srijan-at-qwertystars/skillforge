# Advanced ClickHouse Patterns

## Table of Contents

- [Window Functions](#window-functions)
- [Array Operations](#array-operations)
- [Map Operations](#map-operations)
- [WITH FILL for Time Series Gaps](#with-fill-for-time-series-gaps)
- [JSON Extraction](#json-extraction)
- [Approximate Algorithms](#approximate-algorithms)
- [Parameterized Views](#parameterized-views)
- [External Dictionaries from Multiple Sources](#external-dictionaries-from-multiple-sources)
- [Integration Engines](#integration-engines)
- [ClickHouse Keeper Setup](#clickhouse-keeper-setup)
- [Query Profiling with system.query_log](#query-profiling-with-systemquery_log)

---

## Window Functions

ClickHouse supports standard SQL window functions. They execute after GROUP BY and before ORDER BY/LIMIT.

### Ranking Functions

```sql
SELECT
    user_id,
    event_type,
    revenue,
    row_number() OVER (PARTITION BY event_type ORDER BY revenue DESC) AS rn,
    rank() OVER (PARTITION BY event_type ORDER BY revenue DESC) AS rnk,
    dense_rank() OVER (PARTITION BY event_type ORDER BY revenue DESC) AS drnk,
    percent_rank() OVER (PARTITION BY event_type ORDER BY revenue DESC) AS pct_rnk
FROM events;
```

### Moving Averages and Running Totals

```sql
SELECT
    event_date,
    daily_revenue,
    -- 7-day moving average
    avg(daily_revenue) OVER (
        ORDER BY event_date
        ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
    ) AS moving_avg_7d,
    -- Running total
    sum(daily_revenue) OVER (
        ORDER BY event_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS cumulative_revenue
FROM daily_stats;
```

### Lag/Lead for Row Comparisons

```sql
SELECT
    event_date,
    daily_users,
    lag(daily_users, 1) OVER (ORDER BY event_date) AS prev_day_users,
    daily_users - lag(daily_users, 1) OVER (ORDER BY event_date) AS day_over_day_change,
    lead(daily_users, 1) OVER (ORDER BY event_date) AS next_day_users
FROM daily_stats;
```

### first_value / last_value

```sql
SELECT
    user_id,
    event_time,
    event_type,
    first_value(event_type) OVER (
        PARTITION BY user_id ORDER BY event_time
    ) AS first_event,
    last_value(event_type) OVER (
        PARTITION BY user_id ORDER BY event_time
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    ) AS last_event
FROM events;
```

### Named Windows

```sql
SELECT
    user_id,
    event_time,
    count() OVER w AS running_count,
    sum(value) OVER w AS running_sum
FROM events
WINDOW w AS (PARTITION BY user_id ORDER BY event_time ROWS UNBOUNDED PRECEDING);
```

**Performance notes:**
- Window functions materialize the full partition in memory. Large partitions can OOM.
- Use `ROWS` frames over `RANGE` when possible — `ROWS` is more predictable.
- Pre-filter data with WHERE/PREWHERE before windowing.

---

## Array Operations

Arrays are first-class types in ClickHouse with a rich function library.

### Creating and Transforming Arrays

```sql
-- Aggregate rows into an array
SELECT user_id, groupArray(event_type) AS events FROM events GROUP BY user_id;

-- groupArray with limit
SELECT user_id, groupArray(10)(event_type) AS last_10_events FROM events GROUP BY user_id;

-- Create array literals
SELECT [1, 2, 3] AS arr, array(4, 5, 6) AS arr2;
```

### arrayJoin — Explode Arrays to Rows

```sql
-- Expand array elements into individual rows
SELECT user_id, arrayJoin(tags) AS tag FROM user_profiles;

-- Equivalent to LATERAL VIEW EXPLODE in Spark
```

### arrayMap, arrayFilter, arrayExists

```sql
-- Transform each element
SELECT arrayMap(x -> x * 2, [1, 2, 3]);  -- [2, 4, 6]

-- Filter elements
SELECT arrayFilter(x -> x > 2, [1, 2, 3, 4, 5]);  -- [3, 4, 5]

-- Check existence
SELECT arrayExists(x -> x = 'error', log_levels) AS has_error FROM logs;

-- Apply with index
SELECT arrayMap((x, i) -> (i, x), arr, arrayEnumerate(arr)) AS indexed;
```

### Array Aggregation

```sql
-- Reduce an array to a scalar
SELECT arrayReduce('sum', [1, 2, 3, 4]);  -- 10
SELECT arrayReduce('avg', [10, 20, 30]);  -- 20

-- Array set operations
SELECT arrayIntersect([1,2,3], [2,3,4]);  -- [2, 3]
SELECT arrayUniq([1, 1, 2, 3, 3]);        -- 3
SELECT arrayDistinct([1, 1, 2, 2, 3]);    -- [1, 2, 3]
```

### Sorting and Slicing

```sql
SELECT arraySort([3, 1, 2]);              -- [1, 2, 3]
SELECT arrayReverseSort([3, 1, 2]);       -- [3, 2, 1]
SELECT arraySlice([1,2,3,4,5], 2, 3);     -- [2, 3, 4]
SELECT arrayResize([1, 2], 5, 0);         -- [1, 2, 0, 0, 0]
```

### Nested Arrays Pattern (Parallel Arrays)

```sql
CREATE TABLE user_events (
    user_id UInt64,
    event_names Array(String),
    event_times Array(DateTime),
    event_values Array(Float64)
) ENGINE = MergeTree() ORDER BY user_id;

-- Query: find events where value > 100
SELECT
    user_id,
    arrayFilter(
        (name, val) -> val > 100,
        event_names, event_values
    ) AS high_value_events
FROM user_events;
```

---

## Map Operations

The `Map(K, V)` type stores key-value pairs where keys and values share uniform types.

```sql
CREATE TABLE user_props (
    user_id UInt64,
    properties Map(String, String)
) ENGINE = MergeTree() ORDER BY user_id;

-- Access by key
SELECT properties['country'] FROM user_props;

-- Get all keys and values
SELECT mapKeys(properties) AS keys, mapValues(properties) AS vals FROM user_props;

-- Check key existence
SELECT mapContains(properties, 'plan') FROM user_props;

-- Apply functions
SELECT mapApply((k, v) -> (k, upper(v)), properties) FROM user_props;

-- Filter map entries
SELECT mapFilter((k, v) -> k IN ('country', 'plan'), properties) FROM user_props;

-- Merge maps (later keys win)
SELECT mapUpdate(map('a', '1', 'b', '2'), map('b', '3', 'c', '4'));
-- {'a':'1', 'b':'3', 'c':'4'}
```

**When to use Map vs Array vs JSON:**
- `Map`: uniform key/value types, known query patterns on arbitrary keys
- `Array`: ordered sequences, aggregation pipelines
- `JSON` type (v25.3+): truly dynamic schemas with mixed types per path

---

## WITH FILL for Time Series Gaps

`WITH FILL` in ORDER BY fills missing rows in sequences — essential for time-series queries.

### Basic Time Gap Filling

```sql
SELECT
    toStartOfHour(event_time) AS hour,
    count() AS events
FROM events
WHERE event_date = '2025-01-15'
GROUP BY hour
ORDER BY hour WITH FILL
    FROM toDateTime('2025-01-15 00:00:00')
    TO toDateTime('2025-01-16 00:00:00')
    STEP INTERVAL 1 HOUR;
```

Missing hours appear with `events = 0`.

### Multi-Column WITH FILL

```sql
SELECT
    toDate(event_time) AS day,
    event_type,
    count() AS cnt
FROM events
GROUP BY day, event_type
ORDER BY
    day WITH FILL FROM '2025-01-01' TO '2025-01-31' STEP 1,
    event_type;
```

### WITH FILL + INTERPOLATE

Fill missing values using interpolation instead of defaults:

```sql
SELECT
    toStartOfDay(ts) AS day,
    avg(temperature) AS avg_temp
FROM sensor_data
GROUP BY day
ORDER BY day WITH FILL
    FROM '2025-01-01' TO '2025-02-01' STEP INTERVAL 1 DAY
    INTERPOLATE (avg_temp AS avg_temp);
```

`INTERPOLATE` carries forward the last known value. Use `INTERPOLATE (col AS expr)` for custom logic.

---

## JSON Extraction

### JSONExtract Function Family

```sql
-- Type-specific extraction
SELECT
    JSONExtractString(payload, 'user', 'name') AS user_name,
    JSONExtractInt(payload, 'user', 'age') AS user_age,
    JSONExtractBool(payload, 'is_active') AS active,
    JSONExtractFloat(payload, 'score') AS score
FROM raw_events;

-- Generic extraction with type parameter
SELECT JSONExtract(payload, 'metadata', 'Map(String, String)') AS meta
FROM raw_events;

-- Extract to Tuple for batch extraction (parses JSON once)
SELECT
    JSONExtract(payload, 'Tuple(name String, age UInt32, email String)') AS parsed
FROM raw_events;

-- Array extraction
SELECT JSONExtractArrayRaw(payload, 'tags') AS tag_jsons FROM raw_events;
```

### Native JSON Type (v25.3+)

```sql
CREATE TABLE events_json (
    id UInt64,
    data JSON
) ENGINE = MergeTree() ORDER BY id;

INSERT INTO events_json VALUES
(1, '{"user": {"name": "Alice", "age": 30}, "action": "click"}');

-- Direct path access (columnar storage internally)
SELECT data.user.name, data.action FROM events_json;
```

### simpleJSONExtract (Faster for Simple Cases)

```sql
-- Faster than JSONExtract for flat, simple JSON
SELECT
    simpleJSONExtractString(line, 'level') AS log_level,
    simpleJSONExtractUInt64(line, 'duration_ms') AS duration
FROM raw_logs;
```

**Performance hierarchy:** `simpleJSONExtract*` > `JSONExtract*` > `JSON` type for read-heavy.
For write-heavy with varied schemas, the native `JSON` type is best.

---

## Approximate Algorithms

### Cardinality Estimation

```sql
-- Exact count distinct (slow on large data, high memory)
SELECT uniqExact(user_id) FROM events;

-- HyperLogLog (fast, ~1.6% error, low memory)
SELECT uniq(user_id) FROM events;  -- alias for uniqCombined

-- HLL with 12-bit precision (~1.6% error)
SELECT uniqHLL12(user_id) FROM events;

-- uniqCombined: adaptive — exact for small sets, HLL for large
SELECT uniqCombined(user_id) FROM events;
SELECT uniqCombined(64)(user_id) FROM events;  -- tunable precision

-- Theta sketch for set operations (intersection, union)
SELECT uniqTheta(user_id) FROM events;
```

### Quantile Estimation

```sql
-- Exact quantile (sorts all values — expensive)
SELECT quantileExact(0.95)(response_ms) FROM requests;

-- T-digest (streaming approximate, good accuracy at tails)
SELECT quantileTDigest(0.95)(response_ms) FROM requests;
SELECT quantilesTDigest(0.5, 0.9, 0.95, 0.99)(response_ms) FROM requests;

-- DDSketch (bounded relative error)
SELECT quantileDDSketch(0.95)(response_ms) FROM requests;

-- Timing-optimized (faster for UInt types)
SELECT quantileTiming(0.99)(response_ms) FROM requests;
```

### Aggregate Function Combinators for States

```sql
-- Store approximate states for incremental aggregation
SELECT
    toStartOfDay(ts) AS day,
    uniqState(user_id) AS users_state,
    quantileTDigestState(0.95)(response_ms) AS p95_state
FROM events
GROUP BY day;

-- Merge states across time periods
SELECT
    uniqMerge(users_state) AS total_users,
    quantileTDigestMerge(0.95)(p95_state) AS overall_p95
FROM daily_states
WHERE day BETWEEN '2025-01-01' AND '2025-01-31';
```

---

## Parameterized Views

ClickHouse does not have native parameterized views. Use these alternatives:

### SQL User-Defined Functions as Parameterized Queries

```sql
CREATE FUNCTION daily_revenue AS (start_date, end_date) ->
    (SELECT sum(amount) FROM orders
     WHERE order_date >= start_date AND order_date <= end_date);

SELECT daily_revenue('2025-01-01', '2025-01-31');
```

### Query Parameters (Client-Side)

```sql
-- clickhouse-client supports query parameters
SET param_start = '2025-01-01';
SET param_end = '2025-01-31';

SELECT count() FROM events
WHERE event_date >= {start:Date} AND event_date <= {end:Date};
```

### Views with Runtime Filtering

```sql
CREATE VIEW events_summary AS
SELECT
    toStartOfDay(event_time) AS day,
    event_type,
    count() AS cnt,
    uniq(user_id) AS users
FROM events
GROUP BY day, event_type;

-- Filter at query time
SELECT * FROM events_summary WHERE day >= '2025-01-01' AND event_type = 'purchase';
```

---

## External Dictionaries from Multiple Sources

### From ClickHouse Table

```sql
CREATE DICTIONARY user_dict (
    user_id UInt64,
    name String,
    country LowCardinality(String),
    plan LowCardinality(String)
) PRIMARY KEY user_id
SOURCE(CLICKHOUSE(TABLE 'users' DB 'default'))
LAYOUT(HASHED())
LIFETIME(MIN 300 MAX 600);
```

### From MySQL

```sql
CREATE DICTIONARY product_dict (
    product_id UInt32,
    product_name String,
    category String,
    price Float64
) PRIMARY KEY product_id
SOURCE(MYSQL(
    HOST 'mysql-host' PORT 3306
    USER 'reader' PASSWORD 'pass'
    DB 'ecommerce' TABLE 'products'
))
LAYOUT(HASHED())
LIFETIME(MIN 600 MAX 900);
```

### From PostgreSQL

```sql
CREATE DICTIONARY geo_dict (
    geo_id UInt32,
    city String,
    region String,
    country String,
    latitude Float64,
    longitude Float64
) PRIMARY KEY geo_id
SOURCE(POSTGRESQL(
    HOST 'pg-host' PORT 5432
    USER 'reader' PASSWORD 'pass'
    DB 'geo' TABLE 'cities'
))
LAYOUT(HASHED())
LIFETIME(MIN 3600 MAX 7200);
```

### From HTTP/REST Endpoint

```sql
CREATE DICTIONARY feature_flags (
    flag_name String,
    enabled UInt8,
    rollout_pct Float32
) PRIMARY KEY flag_name
SOURCE(HTTP(
    URL 'https://config-service.internal/flags.tsv'
    FORMAT 'TabSeparated'
))
LAYOUT(COMPLEX_KEY_HASHED())
LIFETIME(60);
```

### From Local File

```sql
CREATE DICTIONARY ip_geo (
    network String,
    country String,
    city String
) PRIMARY KEY network
SOURCE(FILE(PATH '/etc/clickhouse-server/dicts/ip_geo.csv' FORMAT 'CSVWithNames'))
LAYOUT(IP_TRIE())
LIFETIME(0);  -- static, reload manually
```

### Dictionary Layouts Reference

| Layout | Best For | Memory | Lookup |
|---|---|---|---|
| `FLAT` | Small datasets (<500K), integer keys | Array-based, fast | O(1) |
| `HASHED` | General purpose, any key type | Hash table | O(1) avg |
| `RANGE_HASHED` | Temporal/versioned lookups | Hash + ranges | O(log n) |
| `CACHE` | Large datasets, lazy loading | LRU cache | Cache hit/miss |
| `COMPLEX_KEY_HASHED` | Composite keys | Hash table | O(1) avg |
| `IP_TRIE` | IP address lookups (CIDR) | Trie | O(prefix len) |
| `DIRECT` | Always-fresh, queries source each time | None | Source latency |

### Using Dictionaries in Queries

```sql
-- Single attribute lookup
SELECT dictGet('user_dict', 'country', user_id) AS country FROM events;

-- Multiple attributes
SELECT
    dictGet('user_dict', 'name', user_id) AS name,
    dictGet('user_dict', 'plan', user_id) AS plan
FROM events;

-- With default value
SELECT dictGetOrDefault('user_dict', 'country', user_id, 'unknown') FROM events;

-- Check existence
SELECT dictHas('user_dict', user_id) FROM events;

-- Range dictionary lookup
SELECT dictGet('exchange_rates', 'rate', (currency, event_date)) FROM transactions;
```

---

## Integration Engines

### PostgreSQL Engine

```sql
-- Read/write to PostgreSQL tables
CREATE TABLE pg_orders
ENGINE = PostgreSQL('pg-host:5432', 'mydb', 'orders', 'user', 'pass');

-- Query as if local
SELECT * FROM pg_orders WHERE created_at > '2025-01-01';

-- Insert into PostgreSQL from ClickHouse
INSERT INTO pg_orders SELECT * FROM staged_orders;

-- Materialized PostgreSQL (CDC replication)
CREATE DATABASE pg_replica
ENGINE = MaterializedPostgreSQL('pg-host:5432', 'mydb', 'user', 'pass')
SETTINGS materialized_postgresql_tables_list = 'orders,users,products';
```

### MySQL Engine

```sql
CREATE TABLE mysql_users
ENGINE = MySQL('mysql-host:3306', 'mydb', 'users', 'user', 'pass');

-- Use as a regular table for reads
SELECT user_id, email FROM mysql_users WHERE status = 'active';

-- MySQL database engine (mirrors all tables)
CREATE DATABASE mysql_mirror
ENGINE = MySQL('mysql-host:3306', 'mydb', 'user', 'pass');
```

### S3 Engine and Table Function

```sql
-- S3 table engine for persistent external tables
CREATE TABLE s3_logs (
    ts DateTime,
    level String,
    message String
) ENGINE = S3(
    'https://bucket.s3.amazonaws.com/logs/{_partition_id}/*.parquet',
    'AWS_KEY', 'AWS_SECRET',
    'Parquet'
);

-- S3 table function for ad-hoc queries
SELECT count(), min(ts), max(ts)
FROM s3('s3://analytics-bucket/events/2025-01-*.parquet', 'Parquet');

-- Write query results to S3
INSERT INTO FUNCTION s3(
    's3://output-bucket/report.csv', 'CSVWithNames'
) SELECT * FROM daily_summary;

-- S3Queue for streaming ingestion from S3
CREATE TABLE s3_queue (
    ts DateTime, user_id UInt64, event String
) ENGINE = S3Queue(
    'https://bucket.s3.amazonaws.com/incoming/*.json',
    'JSONEachRow'
) SETTINGS mode = 'unordered', s3queue_processing_threads_num = 4;
```

### Kafka Engine

```sql
-- Full three-table Kafka ingestion pattern
-- 1. Kafka consumer table
CREATE TABLE kafka_events (
    ts DateTime,
    user_id UInt64,
    event_type String,
    payload String
) ENGINE = Kafka
SETTINGS
    kafka_broker_list = 'kafka1:9092,kafka2:9092,kafka3:9092',
    kafka_topic_list = 'user_events',
    kafka_group_name = 'clickhouse_consumer_group',
    kafka_format = 'JSONEachRow',
    kafka_num_consumers = 4,
    kafka_max_block_size = 65536,
    kafka_skip_broken_messages = 10;

-- 2. Target MergeTree table
CREATE TABLE events (
    ts DateTime,
    user_id UInt64,
    event_type LowCardinality(String),
    payload String
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(ts)
ORDER BY (event_type, user_id, ts);

-- 3. Materialized view to route data
CREATE MATERIALIZED VIEW kafka_to_events TO events AS
SELECT
    ts,
    user_id,
    event_type,
    payload
FROM kafka_events;
```

---

## ClickHouse Keeper Setup

ClickHouse Keeper is the built-in ZooKeeper-compatible coordination service. Use it instead of ZooKeeper for new deployments.

### 3-Node Keeper Cluster Configuration

Each Keeper node needs its own config. Below is the config for node 1:

```xml
<!-- /etc/clickhouse-keeper/keeper_config.xml (node 1) -->
<clickhouse>
    <keeper_server>
        <tcp_port>9181</tcp_port>
        <server_id>1</server_id>
        <log_storage_path>/var/lib/clickhouse-keeper/log</log_storage_path>
        <snapshot_storage_path>/var/lib/clickhouse-keeper/snapshots</snapshot_storage_path>

        <coordination_settings>
            <operation_timeout_ms>10000</operation_timeout_ms>
            <session_timeout_ms>30000</session_timeout_ms>
            <raft_logs_level>warning</raft_logs_level>
            <rotate_log_storage_interval>10000</rotate_log_storage_interval>
            <snapshots_to_keep>3</snapshots_to_keep>
        </coordination_settings>

        <raft_configuration>
            <server>
                <id>1</id>
                <hostname>keeper1.internal</hostname>
                <port>9234</port>
            </server>
            <server>
                <id>2</id>
                <hostname>keeper2.internal</hostname>
                <port>9234</port>
            </server>
            <server>
                <id>3</id>
                <hostname>keeper3.internal</hostname>
                <port>9234</port>
            </server>
        </raft_configuration>
    </keeper_server>
</clickhouse>
```

Change `server_id` to `2` and `3` on the other nodes. The `raft_configuration` is identical on all nodes.

### ClickHouse Server Pointing to Keeper

```xml
<!-- In ClickHouse server config.xml or config.d/keeper.xml -->
<clickhouse>
    <zookeeper>
        <node>
            <host>keeper1.internal</host>
            <port>9181</port>
        </node>
        <node>
            <host>keeper2.internal</host>
            <port>9181</port>
        </node>
        <node>
            <host>keeper3.internal</host>
            <port>9181</port>
        </node>
        <session_timeout_ms>30000</session_timeout_ms>
    </zookeeper>
</clickhouse>
```

### Verifying Keeper Health

```bash
# Check Keeper is running
echo ruok | nc keeper1.internal 9181
# Should return: imok

# Check leader status
echo stat | nc keeper1.internal 9181

# From ClickHouse client
SELECT * FROM system.zookeeper WHERE path = '/';
```

**Production tips:**
- Always use an odd number of Keeper nodes (3, 5, or 7).
- Run Keeper on dedicated nodes, not co-located with ClickHouse servers.
- Use separate disks for Keeper logs and snapshots.
- 4 GB RAM is sufficient for most Keeper workloads.

---

## Query Profiling with system.query_log

### Finding Slow Queries

```sql
SELECT
    query_start_time,
    query_duration_ms,
    read_rows,
    read_bytes,
    result_rows,
    memory_usage,
    query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today() - 7
  AND query_duration_ms > 1000
ORDER BY query_duration_ms DESC
LIMIT 20;
```

### Memory-Heavy Queries

```sql
SELECT
    query_start_time,
    formatReadableSize(memory_usage) AS peak_mem,
    formatReadableSize(read_bytes) AS data_read,
    query_duration_ms,
    query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND memory_usage > 1000000000  -- > 1GB
ORDER BY memory_usage DESC
LIMIT 10;
```

### Query Patterns Analysis

```sql
-- Find most frequent normalized query patterns
SELECT
    normalized_query_hash,
    count() AS executions,
    avg(query_duration_ms) AS avg_ms,
    max(query_duration_ms) AS max_ms,
    avg(read_rows) AS avg_rows,
    any(query) AS sample_query
FROM system.query_log
WHERE type = 'QueryFinish' AND event_date = today()
GROUP BY normalized_query_hash
ORDER BY executions DESC
LIMIT 20;
```

### Failed Queries Analysis

```sql
SELECT
    query_start_time,
    exception_code,
    exception,
    query
FROM system.query_log
WHERE type = 'ExceptionWhileProcessing'
  AND event_date >= today() - 1
ORDER BY query_start_time DESC
LIMIT 20;
```

### Real-Time Query Profiler

```sql
-- Enable CPU and real-time profiling for a specific query
SET query_profiler_cpu_time_period_ns = 10000000;    -- 10ms sampling
SET query_profiler_real_time_period_ns = 10000000;

-- Run your query, then inspect the trace
SELECT
    arrayStringConcat(arrayMap(x -> demangle(addressToSymbol(x)), trace), '\n') AS stack,
    count() AS samples
FROM system.trace_log
WHERE query_id = 'YOUR_QUERY_ID'
GROUP BY trace
ORDER BY samples DESC
LIMIT 5;
```

### EXPLAIN for Query Plans

```sql
-- Query execution plan
EXPLAIN SELECT count() FROM events WHERE event_type = 'click';

-- Pipeline plan (parallel execution)
EXPLAIN PIPELINE SELECT count() FROM events WHERE event_type = 'click';

-- Estimate rows read
EXPLAIN ESTIMATE SELECT count() FROM events WHERE event_type = 'click';

-- Query AST (abstract syntax tree)
EXPLAIN AST SELECT count() FROM events WHERE event_type = 'click';
```

### system.query_thread_log for Thread-Level Analysis

```sql
SELECT
    thread_name,
    read_rows,
    read_bytes,
    written_rows,
    memory_usage
FROM system.query_thread_log
WHERE query_id = 'YOUR_QUERY_ID'
ORDER BY memory_usage DESC;
```
