# DuckDB Troubleshooting Guide

## Table of Contents

- [Out-of-Memory with Large Datasets](#out-of-memory-with-large-datasets)
- [Parquet Schema Evolution Problems](#parquet-schema-evolution-problems)
- [Type Casting Gotchas](#type-casting-gotchas)
- [Concurrent Write Limitations](#concurrent-write-limitations)
- [Extension Installation Failures](#extension-installation-failures)
- [Python GIL Interactions](#python-gil-interactions)
- [WASM Limitations](#wasm-limitations)
- [CSV Parsing Edge Cases](#csv-parsing-edge-cases)
- [Performance Regression Debugging](#performance-regression-debugging)
- [Quick Diagnostic Queries](#quick-diagnostic-queries)

---

## Out-of-Memory with Large Datasets

### Symptoms

- `Error: Out of Memory Error: failed to allocate block of X bytes`
- Process killed by OS OOM killer (no DuckDB error message)
- Extreme swapping / system unresponsiveness

### Root Causes

1. **Blocking operators**: Hash joins, hash aggregates, window functions, and sorts must materialize intermediate results. High-cardinality GROUP BYs or wide window frames are the usual culprits.
2. **Default memory limit too high**: DuckDB defaults to ~80% of system RAM. In Docker containers or shared servers, this competes with other processes.
3. **Many concurrent operators**: Complex queries with multiple joins each allocate buffers.
4. **Large string columns**: VARCHAR columns with large values (JSON blobs, text) consume more memory than numeric columns of the same row count.

### Solutions

```sql
-- Reduce memory limit (try 50-60% of available RAM)
SET memory_limit = '4GB';

-- Enable disk spilling
SET temp_directory = '/tmp/duckdb_temp';

-- Reduce thread count (fewer threads = fewer concurrent buffers)
SET threads = 4;

-- Disable preservation of insertion order (less memory for sorts)
SET preserve_insertion_order = false;
```

**Query-level strategies:**

```sql
-- Break large aggregations into chunks
CREATE TABLE chunk1 AS SELECT * FROM big_table WHERE id < 1000000;
CREATE TABLE chunk2 AS SELECT * FROM big_table WHERE id >= 1000000;

-- Materialize expensive subqueries instead of repeating them
CREATE TEMP TABLE expensive_cte AS
    SELECT ... FROM ... GROUP BY ...;

-- Use approximate aggregates
SELECT approx_count_distinct(user_id) FROM events;  -- vs count(DISTINCT user_id)
SELECT approx_quantile(latency, 0.99) FROM requests; -- vs quantile_cont

-- Project only needed columns (especially with Parquet)
SELECT col1, col2 FROM 'wide_table.parquet';  -- not SELECT *

-- Filter early with WHERE pushdown
SELECT * FROM read_parquet('data/*.parquet')
WHERE event_date = '2024-06-15';  -- pushes to file scan
```

**Python-level strategies:**

```python
import duckdb

con = duckdb.connect()
con.execute("SET memory_limit = '2GB'")
con.execute("SET temp_directory = '/tmp/duckdb'")

# Process in chunks
for offset in range(0, total_rows, chunk_size):
    chunk = con.execute(f"""
        SELECT * FROM read_parquet('huge.parquet')
        LIMIT {chunk_size} OFFSET {offset}
    """).df()
    process(chunk)

# Use Arrow streaming for large results
result = con.execute("SELECT * FROM big_query")
while batch := result.fetch_arrow_table(rows_per_batch=100000):
    if batch.num_rows == 0:
        break
    process_arrow_batch(batch)
```

### Docker-Specific OOM

```dockerfile
# Set memory limits in Docker
docker run -m 4g --memory-swap 4g myapp

# In your DuckDB config, stay under the container limit
# SET memory_limit = '3GB';  (leave headroom for OS + Python)
```

---

## Parquet Schema Evolution Problems

### Symptoms

- `Binder Error: column "X" not found` when reading multiple Parquet files
- `Conversion Error: Could not convert string 'X' to INT32`
- Silent data truncation when types differ across files

### Schema Drift Across Files

When Parquet files have different schemas (columns added/removed/retyped over time):

```sql
-- Problem: newer files have a column older files lack
SELECT * FROM read_parquet('data/*.parquet');
-- Error: column "new_col" not found in file data/2023.parquet

-- Solution 1: UNION BY NAME with explicit schema
SELECT a, b, CAST(NULL AS VARCHAR) AS new_col
FROM read_parquet('data/2023*.parquet')
UNION ALL BY NAME
SELECT a, b, new_col FROM read_parquet('data/2024*.parquet');

-- Solution 2: union_by_name parameter
SELECT * FROM read_parquet('data/*.parquet', union_by_name=true);

-- Solution 3: Explicit column list
SELECT col1, col2, col3
FROM read_parquet('data/*.parquet');
```

### Type Mismatches Across Files

```sql
-- Problem: price is INT in old files, DOUBLE in new files
-- Solution: Cast to common type
SELECT CAST(price AS DOUBLE) AS price, *
EXCLUDE (price) FROM read_parquet('data/*.parquet');

-- Inspect schema before loading
DESCRIBE SELECT * FROM read_parquet('data/2023_01.parquet');
DESCRIBE SELECT * FROM read_parquet('data/2024_01.parquet');
```

### Hive Partition Schema Issues

```sql
-- Problem: Hive partitions have inconsistent types
-- year=2023/ has year as string, year=2024/ as int

-- Solution: Explicit hive types
SELECT * FROM read_parquet(
    's3://bucket/data/**/*.parquet',
    hive_partitioning=true,
    hive_types={'year': INT, 'month': INT}
);

-- Auto-detect but override specific columns
SELECT * FROM read_parquet(
    'data/**/*.parquet',
    hive_partitioning=true,
    hive_types_autocast=false
);
```

### Parquet Metadata Inspection

```sql
-- Check schema of a specific file
SELECT * FROM parquet_schema('data.parquet');

-- Compare schemas across files
SELECT file_name, name, type FROM parquet_schema('data/2023*.parquet')
EXCEPT
SELECT file_name, name, type FROM parquet_schema('data/2024*.parquet');
```

---

## Type Casting Gotchas

### Implicit Cast Failures

```sql
-- Problem: DuckDB is stricter than PostgreSQL about implicit casts
SELECT '123' + 1;  -- Works (implicit VARCHAR → INTEGER)
SELECT '12.3' + 1; -- Works
SELECT 'abc' + 1;  -- Error: Could not convert string 'abc' to INT32

-- Fix: Explicit TRY_CAST for dirty data
SELECT TRY_CAST('abc' AS INTEGER);  -- Returns NULL instead of error
SELECT TRY_CAST(dirty_col AS DOUBLE) FROM raw_data;
```

### Timestamp Precision

```sql
-- DuckDB has microsecond precision by default
SELECT '2024-01-01 00:00:00.123456789'::TIMESTAMP;
-- Truncates to microseconds: 2024-01-01 00:00:00.123456

-- Use TIMESTAMP_NS for nanosecond precision
SELECT '2024-01-01 00:00:00.123456789'::TIMESTAMP_NS;

-- TIMESTAMP_S for second precision
SELECT '2024-01-01'::TIMESTAMP_S;
```

### Integer Division

```sql
-- DuckDB uses integer division for integer operands (like C, unlike Python 3)
SELECT 5 / 2;      -- Returns 2, not 2.5
SELECT 5.0 / 2;    -- Returns 2.5
SELECT 5 / 2.0;    -- Returns 2.5
SELECT CAST(5 AS DOUBLE) / 2;  -- Returns 2.5
```

### NULL Handling Surprises

```sql
-- NULLs in NOT IN subquery make the whole result NULL
SELECT * FROM t1 WHERE id NOT IN (SELECT id FROM t2);
-- If t2.id contains NULL, this returns ZERO rows!

-- Fix: Use NOT EXISTS or filter NULLs
SELECT * FROM t1 WHERE id NOT IN (SELECT id FROM t2 WHERE id IS NOT NULL);
SELECT * FROM t1 WHERE NOT EXISTS (SELECT 1 FROM t2 WHERE t2.id = t1.id);

-- NULL-safe equality
SELECT NULL = NULL;    -- NULL (not true!)
SELECT NULL IS NULL;   -- true
-- Use IS NOT DISTINCT FROM for NULL-safe comparison
SELECT NULL IS NOT DISTINCT FROM NULL;  -- true
```

### Boolean Casting

```sql
-- Strings to boolean
SELECT 'true'::BOOLEAN;   -- true
SELECT 'yes'::BOOLEAN;    -- Error! Only 'true'/'false'/'1'/'0' work
SELECT CASE WHEN val IN ('yes', 'y', '1', 'true') THEN true ELSE false END;
```

### Date/Time Casting from Strings

```sql
-- strptime for non-standard date formats
SELECT strptime('15/06/2024', '%d/%m/%Y')::DATE;
SELECT strptime('Jun 15, 2024 3:30 PM', '%b %d, %Y %I:%M %p')::TIMESTAMP;

-- strftime for formatting
SELECT strftime(current_date, '%Y-%m-%d');
```

---

## Concurrent Write Limitations

### The Single-Writer Model

DuckDB allows **one writer** at a time. Multiple readers are fine.

### Symptoms

- `IOException: Could not set lock on file "X.duckdb": Resource temporarily unavailable`
- `Error: database is locked`
- Silent corruption if lock files are on NFS without proper locking

### Common Scenarios and Fixes

**Scenario 1: Multiple processes writing to same database**

```python
# WRONG: two processes writing
# Process A
con_a = duckdb.connect('shared.duckdb')
con_a.execute("INSERT INTO t VALUES (1)")

# Process B (concurrent)
con_b = duckdb.connect('shared.duckdb')  # Blocks or errors
con_b.execute("INSERT INTO t VALUES (2)")

# FIX: Serialize writes through a single process/connection
# Or write to separate files and merge:
con_a = duckdb.connect('shard_a.duckdb')
con_b = duckdb.connect('shard_b.duckdb')
# Later: merge into one
```

**Scenario 2: Web application concurrent requests**

```python
# FIX: Use read-only connections for queries, serialize writes
import threading

write_lock = threading.Lock()

def handle_read(query):
    con = duckdb.connect('app.duckdb', read_only=True)
    return con.execute(query).df()

def handle_write(query):
    with write_lock:
        con = duckdb.connect('app.duckdb')
        con.execute(query)
        con.close()
```

**Scenario 3: NFS / network filesystems**

```
# DuckDB file locking may not work on NFS
# Solutions:
# 1. Use a local filesystem for the .duckdb file
# 2. Use in-memory databases with Parquet export
# 3. Mount with proper NFS locking (nfsv4 with lock support)
```

### Write Patterns for Production

```python
# Pattern: Write to temp, atomically replace
import shutil

con = duckdb.connect(':memory:')
con.execute("CREATE TABLE t AS SELECT * FROM read_parquet('data.parquet')")
con.execute("INSERT INTO t VALUES (...)")
con.execute("COPY t TO 'data_new.parquet' (FORMAT parquet)")

shutil.move('data_new.parquet', 'data.parquet')  # Atomic on same filesystem
```

---

## Extension Installation Failures

### Symptoms

- `HTTP Error: Unable to connect to URL`
- `Extension "X" is not available for this platform`
- `Catalog Error: Extension "X" not loaded`
- SSL certificate errors (especially macOS)

### Diagnosis and Fixes

```sql
-- Check platform/version
SELECT version();
SELECT * FROM pragma_platform();

-- Check what's installed
SELECT extension_name, installed, loaded, install_path
FROM duckdb_extensions();

-- Manual install with verbose output
INSTALL httpfs;
LOAD httpfs;
```

**Network issues:**

```bash
# Test connectivity
curl -I https://extensions.duckdb.org

# Behind a proxy
export HTTP_PROXY=http://proxy:8080
export HTTPS_PROXY=http://proxy:8080
duckdb  # Extensions will use these

# Air-gapped: download extension manually
# Download from: https://extensions.duckdb.org/v1.1.0/<platform>/httpfs.duckdb_extension.gz
# Then:
# INSTALL '/path/to/httpfs.duckdb_extension';
```

**SSL on macOS:**

```bash
# Fix certificate issues
pip install certifi
# Or run the macOS certificate installer:
# /Applications/Python\ 3.x/Install\ Certificates.command
```

**Version mismatch:**

```sql
-- Extensions must match the DuckDB version exactly
-- If you upgraded DuckDB, force reinstall extensions:
FORCE INSTALL httpfs;
LOAD httpfs;
```

**Python environment issues:**

```bash
# Ensure duckdb and extensions match
pip install duckdb --upgrade
python -c "import duckdb; print(duckdb.__version__)"

# In conda environments, prefer pip for duckdb
pip install duckdb  # Not conda install duckdb
```

---

## Python GIL Interactions

### The Issue

DuckDB's C++ engine releases the Python GIL during query execution, allowing true parallelism for DuckDB work. However, GIL-bound operations before/after queries can bottleneck.

### GIL-Releasing Operations (Fast)

```python
# These release the GIL - DuckDB runs in parallel
result = con.execute("SELECT * FROM big_table")  # GIL released during execution
arrow_table = result.arrow()  # GIL released for Arrow conversion
```

### GIL-Bound Operations (Bottleneck)

```python
# These hold the GIL
df = result.df()  # Pandas conversion holds GIL for object columns
# Processing pandas DataFrames in Python is GIL-bound
for _, row in df.iterrows():  # Very slow, holds GIL
    process(row)
```

### Multi-Threading Patterns

```python
import duckdb
from concurrent.futures import ThreadPoolExecutor

# CORRECT: Each thread gets its own cursor
con = duckdb.connect('data.duckdb', read_only=True)

def query_worker(query):
    cursor = con.cursor()  # Thread-safe: cursor per thread
    return cursor.execute(query).df()

with ThreadPoolExecutor(max_workers=4) as pool:
    futures = [pool.submit(query_worker, q) for q in queries]
    results = [f.result() for f in futures]

# WRONG: Sharing connection without cursors across threads
# con.execute(query)  # Not thread-safe!
```

### Multi-Processing for CPU-Bound Work

```python
from multiprocessing import Pool

def process_partition(partition_path):
    con = duckdb.connect()  # Fresh connection per process
    return con.execute(f"""
        SELECT category, sum(value)
        FROM read_parquet('{partition_path}')
        GROUP BY category
    """).df()

with Pool(4) as p:
    results = p.map(process_partition, partition_paths)
```

### Best Practices

- Push as much computation as possible into SQL (DuckDB releases GIL).
- Use `.arrow()` instead of `.df()` when possible—Arrow conversion is faster.
- For multi-threaded reads, use `con.cursor()` per thread.
- For CPU-bound Python post-processing, use `multiprocessing` not `threading`.
- Avoid Python UDFs in hot paths—they re-acquire the GIL per row.

---

## WASM Limitations

DuckDB compiles to WebAssembly for in-browser use. Key limitations:

### What Works

- In-memory databases
- Core SQL (SELECT, INSERT, CREATE TABLE, CTEs, window functions)
- Reading small CSV/JSON from JavaScript blobs
- Most built-in scalar and aggregate functions

### What Doesn't Work or Is Limited

| Feature | Status |
|---------|--------|
| Persistent storage | Limited (uses OPFS or IndexedDB, not regular files) |
| Extensions | Only `parquet`, `json`, `fts` available; no `httpfs`, `postgres`, `spatial` |
| File I/O | No direct filesystem access; must pass data through JS |
| `temp_directory` | Not available (no disk spilling) |
| Memory | Limited by browser tab (typically 1-4 GB) |
| Threads | Uses Web Workers; thread count constrained by browser |
| Large datasets | Practical limit ~500MB-1GB depending on browser |
| COPY TO file | Must use JS APIs to save output |

### WASM Usage Patterns

```javascript
import * as duckdb from '@duckdb/duckdb-wasm';

const db = await duckdb.AsyncDuckDB.create();
const conn = await db.connect();

// Register file from JS
await db.registerFileBuffer('data.csv', new Uint8Array(csvBuffer));
const result = await conn.query("SELECT * FROM read_csv_auto('data.csv')");

// Query Arrow result
const table = result.toArray();
```

### WASM Workarounds

- Pre-convert data to Parquet on the server for smaller transfer.
- Use streaming (fetch chunks) instead of loading entire datasets.
- For heavy analytics, run DuckDB server-side and expose results via API.

---

## CSV Parsing Edge Cases

### Common Issues

**BOM (Byte Order Mark):**
```sql
-- UTF-8 BOM (0xEF, 0xBB, 0xBF) can cause first column name to be garbled
-- Fix: strip BOM or skip first bytes
SELECT * FROM read_csv('bom_file.csv', header=true);
-- If column name looks wrong, check for BOM:
-- hex(column_name) will show EFBBBF prefix
```

**Mixed Line Endings:**
```sql
-- Files with mixed \r\n and \n (common from Windows↔Mac transfers)
-- DuckDB handles this automatically in most cases
-- If not: preprocess with dos2unix or:
SELECT * FROM read_csv('file.csv', new_line='\n');
```

**Embedded Quotes and Delimiters:**
```sql
-- CSV with commas inside quoted fields
-- "Smith, Jr.",42,"New York, NY"
SELECT * FROM read_csv('tricky.csv', quote='"', escape='"');

-- Fields with embedded newlines inside quotes
SELECT * FROM read_csv('multiline.csv', quote='"');
```

**NULL Representation:**
```sql
-- Different NULL representations: empty string, 'NA', 'null', 'N/A', '\N'
SELECT * FROM read_csv('data.csv', nullstr='NA');
SELECT * FROM read_csv('data.csv', nullstr=['NA', 'N/A', 'null', '']);
```

**Type Inference Failures:**
```sql
-- Column looks numeric but has some text values
-- DuckDB samples first N rows for type inference

-- Fix 1: Increase sample size
SELECT * FROM read_csv('data.csv', sample_size=100000);

-- Fix 2: Force all columns to VARCHAR, then cast
SELECT * FROM read_csv('data.csv', all_varchar=true);
-- Then cast: SELECT TRY_CAST(col1 AS INTEGER) ...

-- Fix 3: Explicit column types
SELECT * FROM read_csv('data.csv', columns={
    'id': 'INTEGER',
    'name': 'VARCHAR',
    'value': 'DOUBLE',
    'date': 'DATE'
});
```

**Headerless Files:**
```sql
SELECT * FROM read_csv('no_header.csv', header=false,
    columns={'column0': 'INTEGER', 'column1': 'VARCHAR'});
```

**Large Files with Inconsistent Rows:**
```sql
-- Skip malformed rows
SELECT * FROM read_csv('messy.csv',
    ignore_errors=true,
    store_rejects=true);

-- Check rejected rows
SELECT * FROM reject_errors;
SELECT * FROM reject_scans;
```

**Encoding Issues:**
```sql
-- Non-UTF8 files (Latin-1, Windows-1252)
-- DuckDB expects UTF-8 by default
-- Preprocess: iconv -f WINDOWS-1252 -t UTF-8 input.csv > output.csv
-- Or in Python:
-- df = pd.read_csv('file.csv', encoding='latin-1')
-- df.to_csv('file_utf8.csv', index=False)
```

---

## Performance Regression Debugging

### Step 1: Profile the Query

```sql
-- Enable profiling
PRAGMA enable_profiling = 'json';
PRAGMA profile_output = 'profile.json';

-- Run the slow query
SELECT ... FROM ... WHERE ...;

-- Or use EXPLAIN ANALYZE for inline output
EXPLAIN ANALYZE SELECT ... FROM ...;
```

### Step 2: Check Query Plan

```sql
-- Look for sequential scans, missing filters, bad join orders
EXPLAIN SELECT * FROM large_table WHERE indexed_col = 'value';

-- Key things to look for:
-- SEQ_SCAN vs INDEX_SCAN (DuckDB doesn't have B-tree indexes but has min/max/zonemap)
-- FILTER placement (should be as early as possible)
-- Hash join vs nested loop (nested loop on large tables = bad)
-- Unnecessary sorts
```

### Step 3: Check Statistics

```sql
-- Missing statistics cause bad plans
ANALYZE;  -- Collect stats for all tables

-- Verify stats exist
SELECT table_name, column_name, stats
FROM duckdb_statistics();
```

### Step 4: Common Performance Problems

| Problem | Symptom | Fix |
|---------|---------|-----|
| SELECT * on wide Parquet | Slow reads | Select only needed columns |
| Many small Parquet files | Slow file scanning | Merge into 100MB-1GB files |
| Missing ANALYZE | Bad join order | Run `ANALYZE` after bulk loads |
| ORDER BY without LIMIT | Materializes everything | Add LIMIT or remove ORDER BY |
| String-heavy aggregation | High memory | Pre-filter, reduce cardinality |
| Correlated subqueries | Quadratic execution | Rewrite as JOIN |
| LIKE '%pattern%' | Full scan | Use FTS extension or prefix LIKE |
| Cross joins (accidental) | Explosive row count | Check JOIN conditions |

### Step 5: Compare Versions

```sql
-- Check DuckDB version
SELECT version();

-- If a query regressed after upgrade:
-- 1. Test on previous version
-- 2. Check release notes for optimizer changes
-- 3. Report on GitHub with EXPLAIN ANALYZE output from both versions
```

### Step 6: System-Level Checks

```bash
# Check if DuckDB is IO-bound
iostat -x 1 5

# Check memory pressure
free -h
vmstat 1 5

# Check CPU utilization (DuckDB should use multiple cores)
htop  # Look for parallel thread usage
```

---

## Quick Diagnostic Queries

```sql
-- DuckDB version and platform
SELECT version();
SELECT * FROM pragma_platform();

-- Current settings
SELECT * FROM duckdb_settings() WHERE name IN (
    'memory_limit', 'threads', 'temp_directory',
    'preserve_insertion_order', 'default_order'
);

-- Extension status
SELECT extension_name, installed, loaded, install_path
FROM duckdb_extensions()
WHERE installed;

-- Database sizes
SELECT database_name, path, type FROM duckdb_databases();

-- Table sizes and row counts
SELECT table_name, estimated_size, column_count
FROM duckdb_tables();

-- Memory usage
SELECT * FROM pragma_database_size();

-- Running queries (if any)
SELECT * FROM duckdb_temporary_files();
```
