# DuckDB Advanced Patterns

## Table of Contents

- [Recursive CTEs](#recursive-ctes)
- [ASOF Joins](#asof-joins)
- [PIVOT and UNPIVOT](#pivot-and-unpivot)
- [List, Struct, and Map Types](#list-struct-and-map-types)
- [Lambda Functions](#lambda-functions)
- [Macro Definitions](#macro-definitions)
- [Custom Types](#custom-types)
- [Multi-Database Queries](#multi-database-queries)
- [Iceberg and Delta Lake Integration](#iceberg-and-delta-lake-integration)
- [Secrets Management](#secrets-management)
- [Community Extensions](#community-extensions)

---

## Recursive CTEs

### Basic Hierarchical Traversal

```sql
-- Org chart traversal
WITH RECURSIVE org_tree AS (
    SELECT id, name, manager_id, 1 AS depth, name AS path
    FROM employees WHERE manager_id IS NULL
    UNION ALL
    SELECT e.id, e.name, e.manager_id, t.depth + 1,
           t.path || ' > ' || e.name
    FROM employees e JOIN org_tree t ON e.manager_id = t.id
)
SELECT * FROM org_tree ORDER BY path;
```

### Graph Shortest Path with USING KEY

DuckDB v1.3+ supports `USING KEY` in recursive CTEs, which treats the working set as a keyed dictionary—updating rows by key instead of accumulating all rows. This is critical for graph algorithms.

```sql
-- Shortest path (Dijkstra-style) with USING KEY
WITH RECURSIVE shortest(node, distance) AS (
    SELECT 'A'::VARCHAR, 0
    UNION
    SELECT e.dst, s.distance + e.weight
    FROM edges e
    JOIN shortest s ON e.src = s.node
) USING KEY (node) MIN BY (distance)
SELECT * FROM shortest ORDER BY distance;
```

Without `USING KEY`, the CTE accumulates every path variant—exponential blowup on dense graphs. With it, DuckDB keeps only the best row per key.

### Cycle Detection

```sql
WITH RECURSIVE traversal AS (
    SELECT id, parent_id, [id] AS visited, false AS has_cycle
    FROM nodes WHERE id = 1
    UNION ALL
    SELECT n.id, n.parent_id,
           list_append(t.visited, n.id),
           list_contains(t.visited, n.id)
    FROM nodes n JOIN traversal t ON n.parent_id = t.id
    WHERE NOT t.has_cycle
)
SELECT * FROM traversal WHERE has_cycle;
```

### Bill of Materials Explosion

```sql
WITH RECURSIVE bom AS (
    SELECT part_id, component_id, quantity, 1 AS level
    FROM assemblies WHERE part_id = 'WIDGET-100'
    UNION ALL
    SELECT a.part_id, a.component_id, a.quantity * b.quantity, b.level + 1
    FROM assemblies a JOIN bom b ON a.part_id = b.component_id
)
SELECT component_id, sum(quantity) AS total_needed
FROM bom GROUP BY component_id ORDER BY total_needed DESC;
```

---

## ASOF Joins

ASOF joins match each row in the left table with the nearest preceding (or succeeding) row in the right table, based on an ordering column. Essential for time-series alignment.

### Basic ASOF Join

```sql
-- Match each trade to the most recent quote
SELECT t.*, q.bid, q.ask
FROM trades t
ASOF JOIN quotes q
  ON t.symbol = q.symbol AND t.timestamp >= q.timestamp;
```

### Sensor Data Alignment

```sql
-- Align temperature readings (every 5 min) with pressure readings (irregular)
SELECT t.timestamp, t.temperature, p.pressure
FROM temperature_readings t
ASOF JOIN pressure_readings p
  ON t.sensor_id = p.sensor_id AND t.timestamp >= p.timestamp;
```

### Event Attribution

```sql
-- Attribute conversions to the last ad impression before conversion
SELECT c.user_id, c.conversion_time, c.revenue,
       a.campaign_id, a.impression_time,
       age(c.conversion_time, a.impression_time) AS attribution_delay
FROM conversions c
ASOF JOIN ad_impressions a
  ON c.user_id = a.user_id AND c.conversion_time >= a.impression_time;
```

### ASOF with Tolerance Window

```sql
-- Only match if the quote is within 5 seconds of the trade
SELECT t.*, q.bid, q.ask
FROM trades t
ASOF JOIN quotes q
  ON t.symbol = q.symbol
  AND t.timestamp >= q.timestamp
  AND t.timestamp - q.timestamp <= INTERVAL '5 seconds';
```

---

## PIVOT and UNPIVOT

### Dynamic PIVOT

```sql
-- Pivot sales by month
PIVOT sales ON month USING sum(amount) GROUP BY product;

-- Equivalent verbose form
SELECT product,
       sum(amount) FILTER (WHERE month = 'Jan') AS Jan,
       sum(amount) FILTER (WHERE month = 'Feb') AS Feb,
       sum(amount) FILTER (WHERE month = 'Mar') AS Mar
FROM sales GROUP BY product;
```

### Multi-Value PIVOT

```sql
-- Pivot with multiple aggregates
PIVOT sales ON quarter
  USING sum(revenue) AS total_rev, count(*) AS num_orders
  GROUP BY region;
```

### UNPIVOT Wide Tables

```sql
-- Turn columns into rows
UNPIVOT monthly_metrics
  ON jan, feb, mar, apr, may, jun
  INTO NAME month VALUE metric_value;

-- Dynamic UNPIVOT with COLUMNS expression
UNPIVOT wide_table
  ON COLUMNS(* EXCLUDE (id, name))
  INTO NAME attribute VALUE value;
```

### Pivot + Unpivot Round-Trip

```sql
-- Reshape for comparison: long → wide → analysis
WITH pivoted AS (
    PIVOT events ON event_type USING count(*) GROUP BY date
)
SELECT date, page_view, purchase,
       purchase::FLOAT / NULLIF(page_view, 0) AS conversion_rate
FROM pivoted ORDER BY date;
```

---

## List, Struct, and Map Types

### List Operations

```sql
-- Create and query lists
SELECT [1, 2, 3, 4, 5] AS nums;
SELECT list_value(1, 2, 3) AS nums;

-- Aggregate into lists
SELECT dept, list(name ORDER BY hire_date) AS team FROM employees GROUP BY dept;

-- Unnest (explode) lists
SELECT unnest([1, 2, 3]) AS val;
SELECT id, unnest(tags) AS tag FROM articles;

-- List functions
SELECT list_sort([3, 1, 2]);                -- [1, 2, 3]
SELECT list_distinct([1, 1, 2, 3, 3]);      -- [1, 2, 3]
SELECT list_contains([1, 2, 3], 2);          -- true
SELECT list_aggregate([10, 20, 30], 'avg');  -- 20.0
SELECT list_slice([1, 2, 3, 4, 5], 2, 4);   -- [2, 3, 4]
SELECT list_zip([1, 2], ['a', 'b']);         -- [(1, a), (2, b)]
SELECT list_reduce([1, 2, 3, 4], (x, y) -> x + y);  -- 10
SELECT flatten([[1, 2], [3, 4]]);            -- [1, 2, 3, 4]
```

### Struct Operations

```sql
-- Create structs
SELECT {'name': 'Alice', 'age': 30, 'scores': [95, 87, 92]} AS person;

-- Access struct fields
SELECT person.name, person.scores[1] FROM (
    SELECT {'name': 'Alice', 'scores': [95, 87]} AS person
);

-- Struct packing from columns
SELECT struct_pack(id, name, email) AS user_record FROM users;

-- Nested struct queries
SELECT event.user.name, event.metadata.source
FROM (SELECT {
    'user': {'name': 'Bob', 'id': 42},
    'metadata': {'source': 'web', 'ts': current_timestamp}
} AS event);
```

### Map Operations

```sql
-- Create maps
SELECT map(['key1', 'key2'], ['val1', 'val2']) AS kv;
SELECT MAP {'postgres': 5432, 'mysql': 3306, 'duckdb': 0} AS ports;

-- Access map values
SELECT ports['postgres'] FROM (
    SELECT MAP {'postgres': 5432, 'mysql': 3306} AS ports
);

-- Map from entries
SELECT map_from_entries([('a', 1), ('b', 2)]);

-- Map keys and values
SELECT map_keys(m), map_values(m)
FROM (SELECT MAP {'x': 10, 'y': 20} AS m);
```

---

## Lambda Functions

DuckDB supports lambda expressions for list and map transformations.

```sql
-- list_transform: apply function to each element
SELECT list_transform([1, 2, 3, 4], x -> x * x);        -- [1, 4, 9, 16]
SELECT list_transform(['hello', 'world'], s -> upper(s)); -- ['HELLO', 'WORLD']

-- list_filter: keep elements matching predicate
SELECT list_filter([1, 2, 3, 4, 5, 6], x -> x % 2 = 0);  -- [2, 4, 6]

-- list_reduce: fold list to single value
SELECT list_reduce([1, 2, 3, 4], (acc, x) -> acc + x);    -- 10

-- Chaining transforms
SELECT list_filter(
    list_transform([1, 2, 3, 4, 5], x -> x * 3),
    x -> x > 6
);  -- [9, 12, 15]

-- List comprehensions (alternative syntax)
SELECT [x * 2 FOR x IN [1, 2, 3, 4] IF x > 1];  -- [4, 6, 8]

-- Lambda with structs
SELECT list_transform(
    [{'name': 'Alice', 'score': 85}, {'name': 'Bob', 'score': 92}],
    s -> s.score
);  -- [85, 92]
```

---

## Macro Definitions

Macros create reusable SQL expressions (scalar or table-valued). They persist in the database.

### Scalar Macros

```sql
-- Simple expression macro
CREATE MACRO percentage(part, total) AS round(part * 100.0 / NULLIF(total, 0), 2);
SELECT percentage(25, 200);  -- 12.5

-- Macro with default parameters
CREATE MACRO clip(val, lo := 0, hi := 100) AS greatest(lo, least(hi, val));
SELECT clip(150);       -- 100
SELECT clip(-5, lo:=0); -- 0

-- Date utility macros
CREATE MACRO fiscal_quarter(d) AS
    CASE WHEN month(d) <= 3 THEN 'Q1'
         WHEN month(d) <= 6 THEN 'Q2'
         WHEN month(d) <= 9 THEN 'Q3'
         ELSE 'Q4' END;

CREATE MACRO business_days_between(start_date, end_date) AS (
    SELECT count(*) FROM generate_series(start_date, end_date, INTERVAL '1 day') t(d)
    WHERE dayofweek(d::DATE) BETWEEN 1 AND 5
);
```

### Table Macros

```sql
-- Table macro: reusable parameterized queries
CREATE MACRO top_n(tbl, col, n := 10) AS TABLE
    SELECT * FROM query_table(tbl) ORDER BY query_column(col) DESC LIMIT n;

-- Useful for exploration
SELECT * FROM top_n('sales', 'revenue', n := 5);

-- Parameterized report
CREATE MACRO daily_summary(target_date) AS TABLE
    SELECT category, count(*) AS events, sum(value) AS total
    FROM events
    WHERE event_date = target_date
    GROUP BY category ORDER BY total DESC;

SELECT * FROM daily_summary('2024-06-15');
```

### Listing and Dropping Macros

```sql
SELECT * FROM duckdb_functions() WHERE function_type = 'macro';
DROP MACRO percentage;
DROP MACRO top_n;
```

---

## Custom Types

DuckDB supports user-defined types via `CREATE TYPE`. Useful for semantic clarity and domain modeling.

```sql
-- Enum type (categorical with known values)
CREATE TYPE mood AS ENUM ('happy', 'sad', 'neutral', 'excited');
CREATE TABLE journal (entry_date DATE, feeling mood, notes VARCHAR);
INSERT INTO journal VALUES ('2024-06-15', 'happy', 'Great day');

-- Composite type alias
CREATE TYPE address AS STRUCT(
    street VARCHAR, city VARCHAR, state VARCHAR, zip VARCHAR
);
CREATE TABLE customers (id INT, name VARCHAR, addr address);
INSERT INTO customers VALUES (
    1, 'Alice',
    {'street': '123 Main St', 'city': 'Portland', 'state': 'OR', 'zip': '97201'}
);
SELECT c.addr.city FROM customers c;

-- Domain-specific type aliases
CREATE TYPE currency AS DECIMAL(18, 4);
CREATE TYPE user_id AS BIGINT;

-- List available types
SELECT * FROM duckdb_types() WHERE schema_name = 'main';

-- Drop custom type
DROP TYPE mood;
```

---

## Multi-Database Queries

DuckDB can attach PostgreSQL, MySQL, and SQLite databases simultaneously—querying across them in a single SQL statement.

### Attaching Multiple Databases

```sql
-- Attach all three
INSTALL postgres; LOAD postgres;
INSTALL mysql;    LOAD mysql;
INSTALL sqlite;   LOAD sqlite;

ATTACH 'dbname=analytics user=app host=pg.internal' AS pg (TYPE postgres);
ATTACH 'host=mysql.internal user=root database=shop' AS my (TYPE mysql);
ATTACH 'legacy.db' AS lite (TYPE sqlite);
```

### Cross-Database Joins

```sql
-- Join PostgreSQL users with MySQL orders and SQLite product catalog
SELECT u.name, o.order_date, p.product_name, o.amount
FROM pg.public.users u
JOIN my.shop.orders o ON u.id = o.user_id
JOIN lite.main.products p ON o.product_id = p.id
WHERE o.order_date >= '2024-01-01';
```

### ETL Across Databases

```sql
-- Migrate data: PostgreSQL → DuckDB → Parquet
CREATE TABLE local_users AS SELECT * FROM pg.public.users;
COPY local_users TO 'users.parquet' (FORMAT parquet);

-- Federated aggregation
SELECT 'postgres' AS source, count(*) FROM pg.public.events
UNION ALL
SELECT 'mysql', count(*) FROM my.shop.events
UNION ALL
SELECT 'sqlite', count(*) FROM lite.main.events;
```

### Attach Options

```sql
-- Read-only attach (safer for production databases)
ATTACH 'dbname=prod' AS prod_pg (TYPE postgres, READ_ONLY);

-- List attached databases
SELECT * FROM duckdb_databases();

-- Detach when done
DETACH pg;
```

---

## Iceberg and Delta Lake Integration

### Apache Iceberg

```sql
INSTALL iceberg; LOAD iceberg;

-- Scan Iceberg table from S3
SELECT * FROM iceberg_scan('s3://warehouse/db/events');

-- With metadata path
SELECT * FROM iceberg_scan('s3://warehouse/db/events/metadata/v3.metadata.json');

-- Iceberg metadata queries
SELECT * FROM iceberg_metadata('s3://warehouse/db/events');
SELECT * FROM iceberg_snapshots('s3://warehouse/db/events');

-- Filter with predicate pushdown
SELECT event_type, count(*)
FROM iceberg_scan('s3://warehouse/db/events')
WHERE event_date >= '2024-01-01'
GROUP BY event_type;
```

### Delta Lake

```sql
INSTALL delta; LOAD delta;

-- Read Delta table
SELECT * FROM delta_scan('s3://bucket/delta_table/');

-- Local Delta tables
SELECT * FROM delta_scan('./delta/orders/');

-- Query with filters (predicate pushdown on partition columns)
SELECT product, sum(revenue)
FROM delta_scan('s3://bucket/sales/')
WHERE year = 2024 AND quarter = 'Q1'
GROUP BY product;
```

### Iceberg/Delta to Parquet Migration

```sql
-- Snapshot Iceberg to local Parquet
COPY (SELECT * FROM iceberg_scan('s3://warehouse/db/events'))
TO 'local_events/' (FORMAT parquet, PARTITION_BY (event_date));

-- Delta to DuckDB persistent table
CREATE TABLE orders AS SELECT * FROM delta_scan('s3://bucket/orders/');
```

---

## Secrets Management

DuckDB's secrets manager provides SQL-based credential management for cloud storage.

### S3 Credentials

```sql
-- Temporary secret (session-only)
CREATE SECRET my_s3 (
    TYPE s3,
    KEY_ID 'AKIAIOSFODNN7EXAMPLE',
    SECRET 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY',
    REGION 'us-east-1'
);

-- Persistent secret (survives restarts, stored locally)
CREATE PERSISTENT SECRET prod_s3 (
    TYPE s3,
    KEY_ID 'AKIAIOSFODNN7EXAMPLE',
    SECRET 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY',
    REGION 'us-west-2',
    SCOPE 's3://my-production-bucket'
);

-- Use AWS credential chain (env vars, ~/.aws/credentials, instance profile)
CREATE SECRET aws_chain (
    TYPE s3,
    PROVIDER credential_chain
);
```

### GCS Credentials

```sql
CREATE SECRET my_gcs (
    TYPE gcs,
    KEY_ID 'GOOGTS7C7FUP3EXAMPLE',
    SECRET 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY'
);
```

### Azure Credentials

```sql
-- Service principal
CREATE SECRET my_azure (
    TYPE azure,
    PROVIDER service_principal,
    TENANT_ID 'my-tenant-id',
    CLIENT_ID 'my-client-id',
    CLIENT_SECRET 'my-client-secret',
    ACCOUNT_NAME 'mystorageaccount'
);

-- Connection string
CREATE SECRET azure_connstr (
    TYPE azure,
    CONNECTION_STRING 'DefaultEndpointsProtocol=https;AccountName=...;AccountKey=...;'
);
```

### Managing Secrets

```sql
-- List all secrets (values are redacted)
SELECT * FROM duckdb_secrets();

-- Drop a secret
DROP SECRET my_s3;

-- Drop persistent secret
DROP PERSISTENT SECRET prod_s3;
```

**Security notes:**
- Persistent secrets are stored unencrypted on disk by default (`~/.duckdb/stored_secrets/`).
- Prefer `credential_chain` provider in production to avoid hardcoding keys.
- Use `SCOPE` to restrict secrets to specific buckets/paths.
- Secrets are visible in SQL history—use `.duckdbrc` or env vars in CI.

---

## Community Extensions

Install community extensions with `INSTALL <name> FROM community;`.

### Notable Community Extensions

| Extension | Purpose |
|-----------|---------|
| `spatial` | Geospatial analytics (ST_* functions, WKT/WKB, GDAL) |
| `vss` | Vector similarity search (nearest-neighbor for embeddings) |
| `h3` | Uber H3 hexagonal geospatial indexing |
| `shellfs` | Query filesystem metadata as tables |
| `bigquery` | Direct Google BigQuery connector |
| `ducklake` | Native DuckLake lakehouse format |
| `cache_httpfs` | Local caching for remote file reads |
| `airport` | Arrow Flight protocol support |
| `excel` | Read/write Excel (.xlsx) files |

### Using Vector Similarity Search (VSS)

```sql
INSTALL vss FROM community; LOAD vss;

-- Create table with embedding column
CREATE TABLE documents (id INT, content VARCHAR, embedding FLOAT[3]);
INSERT INTO documents VALUES
    (1, 'DuckDB is fast', [0.1, 0.8, 0.3]),
    (2, 'SQL is great', [0.2, 0.7, 0.4]),
    (3, 'Python rocks', [0.9, 0.1, 0.2]);

-- Create HNSW index
CREATE INDEX doc_idx ON documents USING HNSW (embedding);

-- Find nearest neighbors
SELECT id, content, array_distance(embedding, [0.15, 0.75, 0.35]::FLOAT[3]) AS dist
FROM documents
ORDER BY dist LIMIT 5;
```

### Using H3 Geospatial Indexing

```sql
INSTALL h3 FROM community; LOAD h3;

SELECT h3_latlng_to_cell(37.7749, -122.4194, 9) AS cell_id;
SELECT h3_cell_to_latlng('89283082837ffff'::H3INDEX) AS center;
SELECT h3_grid_disk('89283082837ffff'::H3INDEX, 1) AS neighbors;
```

### Extension Development

Community extensions follow the DuckDB Extension Template. Build with CMake:

```bash
git clone https://github.com/duckdb/extension-template
cd extension-template
# Follow the README to implement your extension in C++
make
```

Extensions can define new functions, table functions, types, optimizers, and storage backends.
