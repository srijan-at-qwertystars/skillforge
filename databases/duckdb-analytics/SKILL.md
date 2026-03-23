---
name: duckdb-analytics
description: >
  Guide for building analytics solutions with DuckDB, the embedded OLAP columnar database engine.
  TRIGGER when: code imports duckdb, user asks about DuckDB queries, embedded analytics, in-process
  OLAP, columnar data analysis, Parquet/CSV/JSON querying, data lake queries from S3/HTTP, analytical
  SQL with window functions, ETL pipelines using DuckDB, reading external data sources into DuckDB,
  DuckDB extensions (spatial, FTS, httpfs, iceberg), or converting between Parquet/CSV/JSON formats.
  Keywords: DuckDB, embedded analytics, OLAP, columnar, Parquet, in-process, data analysis, data lake,
  analytical SQL, vectorized execution. DO NOT TRIGGER when: user needs OLTP/transactional database
  (use PostgreSQL/MySQL/SQLite instead), needs distributed multi-node processing (use Spark/Presto),
  needs a database server with concurrent write access, or works with MongoDB/Redis/Cassandra.
---

# DuckDB Analytics

## What DuckDB Is

DuckDB is an in-process, columnar, OLAP SQL database engine. Think "SQLite for analytics." It runs embedded inside the host process with zero external dependencies—no server, no daemon, no configuration. Optimized for analytical (OLAP) workloads: aggregations, joins, window functions, and scans over large datasets. Not for OLTP (high-concurrency transactional writes).

Current stable release: v1.4.0 LTS ("Andium"). Supports persistent and in-memory databases. Single-file storage format. Vectorized execution engine with automatic parallelism across CPU cores.

## Installation and Language Bindings

```bash
# CLI
brew install duckdb          # macOS
apt install duckdb           # Debian/Ubuntu (or download binary)
pip install duckdb           # Python
npm install duckdb           # Node.js (also: @duckdb/node-api)
cargo add duckdb             # Rust
go get github.com/marcboeker/go-duckdb  # Go
```

Java: add `org.duckdb:duckdb_jdbc` Maven dependency. WASM build available for in-browser use.

## SQL Extensions and DuckDB-Specific Syntax

### Friendly SQL

DuckDB extends standard SQL with productivity features. Use them.

```sql
-- SELECT * EXCLUDE: omit columns without listing all others
SELECT * EXCLUDE (ssn, internal_id) FROM customers;

-- SELECT * REPLACE: transform columns inline
SELECT * REPLACE (price * 1.1 AS price) FROM products;

-- Column aliases in GROUP BY / ORDER BY
SELECT category, sum(amount) AS total FROM sales GROUP BY category ORDER BY total DESC;

-- String slicing
SELECT 'DuckDB'[1:4];  -- 'Duck'

-- UNION BY NAME: union tables with different column orders
SELECT * FROM jan_sales UNION BY NAME SELECT * FROM feb_sales;

-- List comprehensions
SELECT [x * 2 FOR x IN [1, 2, 3]];

-- Struct access with dot notation
SELECT s.name FROM (SELECT {'name': 'Alice', 'age': 30} AS s);

-- Function chaining
SELECT 'Hello World'.lower().replace(' ', '_');

-- COLUMNS expression: apply operations to multiple columns
SELECT min(COLUMNS(*)) FROM readings;

-- PIVOT / UNPIVOT
PIVOT sales ON month USING sum(amount);
UNPIVOT monthly_sales ON COLUMNS(* EXCLUDE product) INTO NAME month VALUE amount;

-- MERGE INTO (v1.4+)
MERGE INTO target USING source ON target.id = source.id
  WHEN MATCHED THEN UPDATE SET val = source.val
  WHEN NOT MATCHED THEN INSERT VALUES (source.id, source.val);

-- Recursive CTEs
WITH RECURSIVE hierarchy AS (
  SELECT id, parent_id, name, 0 AS depth FROM nodes WHERE parent_id IS NULL
  UNION ALL
  SELECT n.id, n.parent_id, n.name, h.depth + 1 FROM nodes n JOIN hierarchy h ON n.parent_id = h.id
) SELECT * FROM hierarchy;

-- QUALIFY: filter window function results directly
SELECT *, row_number() OVER (PARTITION BY dept ORDER BY salary DESC) AS rn
FROM employees QUALIFY rn = 1;

-- SAMPLE: random sampling
SELECT * FROM large_table USING SAMPLE 10%;
SELECT * FROM large_table USING SAMPLE 1000 ROWS;
```

## Reading External Data

DuckDB reads Parquet, CSV, JSON, Excel, and more—directly in SQL. No ETL step needed.

```sql
-- Parquet (local, glob, remote)
SELECT * FROM read_parquet('data/*.parquet');
SELECT * FROM read_parquet(['2023.parquet', '2024.parquet']);
SELECT * FROM 'data.parquet';  -- auto-detection shorthand

-- CSV with options
SELECT * FROM read_csv('data.csv', header=true, delim='|', dateformat='%Y-%m-%d');
SELECT * FROM read_csv_auto('data.csv');  -- infer everything

-- JSON / NDJSON
SELECT * FROM read_json_auto('events.jsonl');
SELECT * FROM read_json('data.json', format='array');

-- S3 (install httpfs first)
INSTALL httpfs; LOAD httpfs;
SET s3_region = 'us-east-1';
SET s3_access_key_id = 'KEY'; SET s3_secret_access_key = 'SECRET';
SELECT * FROM read_parquet('s3://bucket/path/*.parquet');

-- HTTP/HTTPS
SELECT * FROM read_parquet('https://example.com/data.parquet');
SELECT * FROM read_csv('https://example.com/data.csv');

-- PostgreSQL
INSTALL postgres; LOAD postgres;
ATTACH 'dbname=mydb user=postgres host=localhost' AS pg (TYPE postgres);
SELECT * FROM pg.public.users;

-- MySQL
INSTALL mysql; LOAD mysql;
ATTACH 'host=localhost user=root database=mydb' AS mysql_db (TYPE mysql);
SELECT * FROM mysql_db.orders;

-- SQLite
INSTALL sqlite; LOAD sqlite;
ATTACH 'legacy.db' AS sqlite_db (TYPE sqlite);
SELECT * FROM sqlite_db.main.events;

-- Iceberg
INSTALL iceberg; LOAD iceberg;
SELECT * FROM iceberg_scan('s3://warehouse/db/table');

-- Delta Lake
INSTALL delta; LOAD delta;
SELECT * FROM delta_scan('s3://bucket/delta_table/');

-- Excel
INSTALL spatial; LOAD spatial;  -- needed for xlsx
SELECT * FROM st_read('data.xlsx', layer='Sheet1');
```

## Data Export

```sql
-- Parquet
COPY (SELECT * FROM analytics) TO 'output.parquet' (FORMAT parquet, COMPRESSION zstd);
COPY table_name TO 'partitioned/' (FORMAT parquet, PARTITION_BY (year, month));

-- CSV
COPY results TO 'output.csv' (HEADER, DELIMITER ',');

-- JSON
COPY results TO 'output.json' (FORMAT json);

-- Write directly to S3
COPY results TO 's3://bucket/output.parquet' (FORMAT parquet);
```

## Window Functions and Advanced Analytics

```sql
-- Running totals
SELECT date, revenue,
  sum(revenue) OVER (ORDER BY date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cumulative
FROM daily_revenue;

-- Ranking
SELECT name, score,
  rank() OVER (ORDER BY score DESC) AS rank,
  dense_rank() OVER (ORDER BY score DESC) AS dense_rank,
  ntile(4) OVER (ORDER BY score DESC) AS quartile
FROM students;

-- Moving averages
SELECT date, value,
  avg(value) OVER (ORDER BY date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS moving_avg_7d
FROM metrics;

-- Lead/Lag
SELECT date, value,
  lag(value, 1) OVER (ORDER BY date) AS prev_value,
  value - lag(value, 1) OVER (ORDER BY date) AS delta
FROM metrics;

-- FIRST_VALUE / LAST_VALUE
SELECT dept, employee, salary,
  first_value(employee) OVER (PARTITION BY dept ORDER BY salary DESC) AS top_earner
FROM employees;

-- Percentiles (approximate and exact)
SELECT approx_quantile(latency, 0.99) AS p99 FROM requests;
SELECT quantile_cont(salary, [0.25, 0.5, 0.75]) AS quartiles FROM employees;

-- LIST aggregation
SELECT dept, list(employee ORDER BY salary DESC) AS ranked_employees FROM employees GROUP BY dept;

-- GROUPING SETS / ROLLUP / CUBE
SELECT region, product, sum(sales) FROM orders
GROUP BY GROUPING SETS ((region, product), (region), ());
```

## Full-Text Search Extension

```sql
INSTALL fts; LOAD fts;

-- Create FTS index on a table
PRAGMA create_fts_index('documents', 'doc_id', 'title', 'body', stemmer='english');

-- Search with BM25 ranking
SELECT doc_id, title, body, score
FROM (SELECT *, fts_main_documents.match_bm25(doc_id, 'search query') AS score FROM documents)
WHERE score IS NOT NULL ORDER BY score DESC;

-- Drop index
PRAGMA drop_fts_index('documents');
```

## Spatial Extension

```sql
INSTALL spatial; LOAD spatial;

-- Read shapefiles, GeoJSON, GeoParquet, GPKG
SELECT * FROM st_read('boundaries.geojson');
SELECT * FROM st_read('cities.shp');

-- Spatial operations
SELECT name, ST_Area(geom) AS area FROM regions;
SELECT a.name, b.name FROM regions a, points b WHERE ST_Contains(a.geom, b.geom);
SELECT ST_Distance(ST_Point(lng1, lat1), ST_Point(lng2, lat2)) AS dist;

-- Export to GeoJSON
COPY (SELECT * FROM spatial_table) TO 'output.geojson'
WITH (FORMAT GDAL, DRIVER 'GeoJSON');
```

## Performance Tuning

```sql
-- Check/set resource limits
SELECT current_setting('threads');
SET threads = 8;
SET memory_limit = '8GB';

-- Enable disk spilling for larger-than-memory workloads
SET temp_directory = '/tmp/duckdb_swap';

-- Profile queries
EXPLAIN ANALYZE SELECT * FROM large_table WHERE category = 'A' GROUP BY region;
PRAGMA enable_profiling = 'json';
PRAGMA profile_output = 'profile.json';

-- Collect statistics for the optimizer
ANALYZE;

-- Preserve insertion order (disable for faster bulk loads)
SET preserve_insertion_order = false;

-- Force parallel CSV/Parquet reading
SET experimental_parallel_csv = true;
```

**Key performance rules:**
- Use Parquet over CSV for analytical queries—columnar format enables column pruning and predicate pushdown.
- Prefer fewer large files over many small files. Aim for 100MB–1GB per Parquet file.
- Run `ANALYZE` after bulk loads so the query optimizer has accurate statistics.
- Set `preserve_insertion_order = false` when order doesn't matter—enables more parallelism.
- Use `CREATE TABLE ... AS SELECT` to materialize expensive subqueries.
- Partition Parquet output by high-cardinality filter columns (date, region).

## Python Integration

```python
import duckdb

# In-memory (default)
con = duckdb.connect()

# Persistent database
con = duckdb.connect('analytics.duckdb')

# Query directly—returns a DuckDBPyRelation
result = con.sql("SELECT * FROM read_parquet('data.parquet') WHERE value > 100")

# Convert to pandas
df = result.df()                    # or .fetchdf()

# Convert to Polars
pl_df = result.pl()                 # returns polars DataFrame

# Convert to Arrow
arrow_table = result.arrow()        # returns pyarrow.Table

# Convert to NumPy
arrays = result.fetchnumpy()

# Query pandas DataFrames directly (auto-detected by variable name)
import pandas as pd
sales_df = pd.DataFrame({'product': ['A', 'B'], 'revenue': [100, 200]})
con.sql("SELECT * FROM sales_df WHERE revenue > 150").df()

# Query Polars DataFrames
import polars as pl
orders = pl.DataFrame({'id': [1, 2], 'amount': [50, 75]})
con.sql("SELECT sum(amount) FROM orders").pl()

# Relation API (programmatic query building)
rel = con.from_df(sales_df).filter("revenue > 50").project("product, revenue").order("revenue DESC")
rel.df()

# Register DataFrames explicitly
con.register('my_table', sales_df)

# Execute and fetch
con.execute("SELECT count(*) FROM my_table").fetchone()

# Parameterized queries
con.execute("SELECT * FROM sales WHERE region = ?", ['West']).df()
```

### Jupyter Integration

Use `duckdb.sql()` at module level (uses shared default connection). Results render as tables automatically. Combine SQL for heavy lifting with pandas/matplotlib for visualization:

```python
# Cell 1: Load and query
results = duckdb.sql("""
    SELECT date_trunc('month', created_at) AS month, count(*) AS signups
    FROM read_parquet('users.parquet')
    GROUP BY 1 ORDER BY 1
""").df()

# Cell 2: Visualize
results.plot(x='month', y='signups', kind='bar')
```

## Persistent vs In-Memory Databases

```python
# In-memory: fast, ephemeral, default
con = duckdb.connect()             # or duckdb.connect(':memory:')

# Persistent: survives process restarts, single-file
con = duckdb.connect('my.duckdb')
```

Use persistent databases for: datasets you reload frequently, intermediate ETL state, caching expensive transformations. Use in-memory for: one-off analysis, testing, ephemeral pipelines.

**Concurrency model:** single writer, multiple readers. Use read-only mode for concurrent access:
```python
con = duckdb.connect('shared.duckdb', read_only=True)
```

## Extensions Ecosystem

```sql
-- List installed extensions
SELECT * FROM duckdb_extensions();

-- Install and load
INSTALL httpfs;   LOAD httpfs;    -- S3, HTTP, HTTPS access
INSTALL json;     LOAD json;      -- JSON functions
INSTALL parquet;  LOAD parquet;   -- Parquet (usually autoloaded)
INSTALL fts;      LOAD fts;       -- Full-text search (BM25)
INSTALL spatial;  LOAD spatial;   -- Geometry, GDAL, shapefiles
INSTALL iceberg;  LOAD iceberg;   -- Apache Iceberg tables
INSTALL delta;    LOAD delta;     -- Delta Lake tables
INSTALL postgres; LOAD postgres;  -- Attach PostgreSQL
INSTALL mysql;    LOAD mysql;     -- Attach MySQL
INSTALL sqlite;   LOAD sqlite;    -- Attach SQLite
INSTALL excel;    LOAD excel;     -- Read .xlsx files
INSTALL vss;      LOAD vss;       -- Vector similarity search
INSTALL aws;      LOAD aws;       -- AWS credential chain
INSTALL azure;    LOAD azure;     -- Azure Blob Storage

-- Auto-install on first use (default behavior)
SET autoinstall_known_extensions = true;
SET autoload_known_extensions = true;
```

Community extensions available via `INSTALL name FROM community;`. Over 200 extensions exist in the ecosystem.

## DuckDB vs Alternatives

| Dimension | DuckDB | SQLite | Pandas | Polars | Spark | ClickHouse |
|-----------|--------|--------|--------|--------|-------|------------|
| Workload | OLAP | OLTP | In-memory analysis | In-memory analysis | Distributed OLAP | Server OLAP |
| Deployment | Embedded | Embedded | Library | Library | Cluster | Server |
| Concurrency | Single writer | WAL mode multi-writer | N/A | N/A | Multi-node | Multi-writer |
| Data size | Single-node (10s–100s GB) | Small (GBs) | RAM-bound | RAM-bound | TB+ distributed | TB+ server |
| SQL support | Rich analytical SQL | Basic SQL | No SQL | Limited SQL | Full SQL | Full SQL |
| Best for | Local analytics, ETL, data exploration | Mobile/web OLTP | Quick scripting | Fast transforms | Big data pipelines | Production analytics server |

**Choose DuckDB when:** single-node analytical queries, Parquet/CSV/JSON exploration, embedded analytics in applications, local ETL, replacing pandas for SQL-heavy analysis, querying data lakes from a laptop.

**Choose something else when:** you need OLTP with many concurrent writers (→ PostgreSQL), distributed processing across many nodes (→ Spark), a production analytics server with high concurrency (→ ClickHouse), or a simple key-value store (→ Redis/SQLite).

## Common Patterns

### ETL Pipeline

```sql
-- Extract from multiple sources, transform, load to Parquet
CREATE TABLE staging AS
  SELECT * FROM read_csv_auto('raw/*.csv')
  WHERE date >= '2024-01-01';

-- Transform
CREATE TABLE analytics AS
  SELECT date_trunc('day', timestamp) AS day,
         category,
         count(*) AS events,
         sum(value) AS total_value,
         approx_quantile(latency, 0.95) AS p95_latency
  FROM staging
  GROUP BY ALL;

-- Load
COPY analytics TO 's3://warehouse/analytics/' (FORMAT parquet, PARTITION_BY (day));
```

### Data Lake Query

```sql
-- Query across S3 data lake without loading locally
INSTALL httpfs; LOAD httpfs;
SELECT year, month, sum(revenue) AS total
FROM read_parquet('s3://data-lake/sales/**/*.parquet', hive_partitioning=true)
WHERE year >= 2024
GROUP BY ALL ORDER BY year, month;
```

### Embedded Analytics in Applications

```python
# Embed DuckDB in a web application for fast dashboard queries
import duckdb

class AnalyticsEngine:
    def __init__(self, db_path: str):
        self.con = duckdb.connect(db_path, read_only=True)

    def get_dashboard_data(self, metric: str, start: str, end: str):
        return self.con.execute("""
            SELECT date, value FROM metrics
            WHERE metric_name = ? AND date BETWEEN ? AND ?
            ORDER BY date
        """, [metric, start, end]).df()
```

### Format Conversion

```sql
-- CSV to Parquet
COPY (SELECT * FROM read_csv_auto('input.csv')) TO 'output.parquet' (FORMAT parquet);

-- JSON to Parquet
COPY (SELECT * FROM read_json_auto('input.jsonl')) TO 'output.parquet' (FORMAT parquet);

-- Parquet to CSV
COPY (SELECT * FROM 'input.parquet') TO 'output.csv' (HEADER);

-- SQLite to Parquet
INSTALL sqlite; LOAD sqlite;
ATTACH 'legacy.db' AS old (TYPE sqlite);
COPY (SELECT * FROM old.main.events) TO 'events.parquet' (FORMAT parquet);
```

## Anti-Patterns and Gotchas

- **Do not use DuckDB for OLTP.** It is not designed for high-frequency single-row inserts/updates/deletes with concurrent writers. Use PostgreSQL or SQLite for that.
- **Do not open the same persistent database from multiple writer processes.** DuckDB supports single-writer concurrency. Multiple readers are fine with `read_only=True`.
- **Do not scan many small files (thousands of 1KB files).** Merge small files into larger ones (100MB+). File-open overhead dominates with many small files.
- **Do not ignore `ANALYZE`.** Without statistics the optimizer guesses poorly. Run `ANALYZE` after bulk loads.
- **Do not use `ORDER BY` on massive results unless necessary.** It forces materialization. Use `LIMIT` when exploring.
- **Do not store BLOBs or large text in DuckDB.** Columnar storage is optimized for analytical types (numbers, dates, short strings).
- **Avoid `SELECT *` on wide Parquet files.** DuckDB can prune columns—specify only what you need for major speedups.
- **Do not assume thread safety on a single connection.** Each thread needs its own cursor or connection in Python. Use `con.cursor()` per thread.
- **Watch memory with large aggregations.** Some aggregate operators cannot spill to disk. Set `memory_limit` and `temp_directory` to avoid OOM.
- **Do not mix DuckDB versions on the same persistent file.** The storage format may change between major versions. Export to Parquet before upgrading.
