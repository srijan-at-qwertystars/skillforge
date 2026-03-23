# Polars IO Guide

## Table of Contents

- [CSV](#csv)
- [Parquet](#parquet)
- [Delta Lake](#delta-lake)
- [Cloud Storage](#cloud-storage)
- [Database Connections](#database-connections)
- [JSON and NDJSON](#json-and-ndjson)
- [Arrow IPC](#arrow-ipc)
- [Excel](#excel)
- [IO Performance Tips](#io-performance-tips)

---

## CSV

### Reading CSV (Eager)

```python
import polars as pl

df = pl.read_csv("data.csv")

# Common options
df = pl.read_csv(
    "data.csv",
    separator=",",               # delimiter
    has_header=True,             # first row is header
    columns=["id", "name"],      # read only specific columns
    dtypes={"id": pl.Int64, "amount": pl.Float64},  # enforce types
    null_values=["NA", "null", ""],  # strings treated as null
    skip_rows=1,                 # skip first N rows
    n_rows=1000,                 # read only first N rows
    encoding="utf8",             # utf8 or utf8-lossy
    low_memory=False,            # trade speed for lower memory
    ignore_errors=True,          # skip malformed rows
    try_parse_dates=True,        # auto-detect date columns
    comment_prefix="#",          # skip lines starting with #
    quote_char='"',              # quoting character
    truncate_ragged_lines=True,  # handle rows with uneven columns
    infer_schema_length=10000,   # rows to scan for type inference
)
```

### Scanning CSV (Lazy — Preferred)

```python
lf = pl.scan_csv("data.csv")

# With options
lf = pl.scan_csv(
    "data.csv",
    has_header=True,
    separator=",",
    dtypes={"id": pl.Int64},
    null_values=["NA"],
    n_rows=None,                 # None = all rows
    skip_rows=0,
    infer_schema_length=10000,
)

# Lazy benefits: predicate and projection pushdown
result = (
    pl.scan_csv("data.csv")
    .filter(pl.col("amount") > 100)
    .select("id", "amount")
    .collect()
)
# Only reads "id" and "amount" columns, filters during read
```

### Writing CSV

```python
df.write_csv("output.csv")

df.write_csv(
    "output.csv",
    separator=",",
    include_header=True,
    datetime_format="%Y-%m-%d %H:%M:%S",
    date_format="%Y-%m-%d",
    float_precision=4,
    null_value="",
    quote_style="necessary",  # "always", "necessary", "non_numeric", "never"
)

# Write to stdout
print(df.write_csv())

# Streaming sink (lazy)
lf.sink_csv("output.csv")
```

### CSV Tips

- Use `scan_csv` over `read_csv` for large files — enables optimizations
- Set `infer_schema_length` higher if type detection fails on first N rows
- Use `dtypes` to override inference for known column types
- `try_parse_dates=True` auto-detects ISO 8601 dates
- `ignore_errors=True` skips bad rows instead of failing
- For multi-file CSV: `pl.scan_csv("data/*.csv")` (glob patterns)

---

## Parquet

### Reading Parquet (Eager)

```python
df = pl.read_parquet("data.parquet")

df = pl.read_parquet(
    "data.parquet",
    columns=["id", "name"],         # only read these columns
    n_rows=1000,                    # limit rows
    use_pyarrow=False,              # use Polars native reader (default)
    low_memory=False,
    parallel="auto",                # "auto", "columns", "row_groups", "none"
    rechunk=True,                   # consolidate memory chunks
)
```

### Scanning Parquet (Lazy — Preferred)

```python
lf = pl.scan_parquet("data.parquet")

# Glob patterns for partitioned data
lf = pl.scan_parquet("data/**/*.parquet")
lf = pl.scan_parquet("data/year=2024/**/*.parquet")

# With options
lf = pl.scan_parquet(
    "data.parquet",
    n_rows=None,
    parallel="auto",
    rechunk=False,
    low_memory=False,
    hive_partitioning=True,     # read Hive-style partitions as columns
    hive_schema=None,           # override partition column types
)
```

### Row Group and Predicate Pushdown

Parquet files are divided into row groups. Polars can skip entire row groups based on filter predicates using min/max statistics stored in metadata:

```python
# This is extremely efficient — skips row groups where date < 2024-01-01
result = (
    pl.scan_parquet("large_dataset.parquet")
    .filter(pl.col("date") >= "2024-01-01")
    .filter(pl.col("amount") > 1000)
    .select("id", "date", "amount")
    .collect()
)

# Verify pushdown with explain()
print(
    pl.scan_parquet("large_dataset.parquet")
    .filter(pl.col("date") >= "2024-01-01")
    .select("id", "date")
    .explain()
)
# Look for "FILTER" appearing in the scan node
```

### Writing Parquet

```python
df.write_parquet("output.parquet")

df.write_parquet(
    "output.parquet",
    compression="zstd",           # "zstd", "snappy", "gzip", "lz4", "uncompressed"
    compression_level=3,          # zstd: 1-22 (default 3)
    statistics=True,              # write column statistics for pushdown
    row_group_size=512 * 1024,    # rows per row group
    use_pyarrow=False,
    pyarrow_options=None,
)

# Streaming sink (lazy — no memory materialization)
(
    pl.scan_csv("huge.csv")
    .filter(pl.col("valid"))
    .sink_parquet(
        "output.parquet",
        compression="zstd",
        row_group_size=100_000,
    )
)
```

### Parquet Metadata Inspection

```python
# Read just the schema (no data)
import pyarrow.parquet as pq

pf = pq.ParquetFile("data.parquet")
print(pf.schema_arrow)
print(f"Row groups: {pf.metadata.num_row_groups}")
print(f"Rows: {pf.metadata.num_rows}")
print(f"Columns: {pf.metadata.num_columns}")

# Row group statistics
for i in range(pf.metadata.num_row_groups):
    rg = pf.metadata.row_group(i)
    print(f"RG {i}: {rg.num_rows} rows")
```

### Parquet Best Practices

- **Always use `scan_parquet`** for lazy evaluation with pushdown
- **Use zstd compression** — best balance of speed and ratio
- **Set `statistics=True`** when writing for optimal read performance
- **Partition large datasets** by a low-cardinality column (date, region)
- **Row group size**: 100K–1M rows is typical; smaller = better pushdown granularity
- **Prefer Parquet over CSV** for any data pipeline — typed, compressed, columnar

---

## Delta Lake

Requires the `deltalake` package: `pip install deltalake`

### Reading Delta Tables

```python
# Lazy scan (preferred)
lf = pl.scan_delta("path/to/delta-table/")

# With version/timestamp (time travel)
lf = pl.scan_delta("path/to/delta-table/", version=5)
lf = pl.scan_delta(
    "path/to/delta-table/",
    delta_table_options={"without_files": False},
)

# Eager read
df = pl.read_delta("path/to/delta-table/")
```

### Writing Delta Tables

```python
# Write new table
df.write_delta("path/to/delta-table/")

# Append
df.write_delta("path/to/delta-table/", mode="append")

# Overwrite
df.write_delta("path/to/delta-table/", mode="overwrite")

# Overwrite specific partitions
df.write_delta(
    "path/to/delta-table/",
    mode="overwrite",
    delta_write_options={
        "predicate": "year = 2024 AND month = 1",
    },
)
```

### Delta with Cloud Storage

```python
lf = pl.scan_delta(
    "s3://bucket/delta-table/",
    storage_options={
        "AWS_ACCESS_KEY_ID": "...",
        "AWS_SECRET_ACCESS_KEY": "...",
        "AWS_REGION": "us-east-1",
    },
)
```

### Delta Features

```python
from deltalake import DeltaTable

dt = DeltaTable("path/to/delta-table/")

# Time travel
dt.load_as_version(5)

# Compact small files
dt.optimize.compact()

# Z-order for multi-dimensional clustering
dt.optimize.z_order(columns=["date", "region"])

# Vacuum old versions
dt.vacuum(retention_hours=168)  # 7 days

# History
history = dt.history()
```

---

## Cloud Storage

### S3 (AWS)

```python
# Using built-in object_store (no extra deps)
lf = pl.scan_parquet(
    "s3://bucket/path/**/*.parquet",
    storage_options={
        "aws_access_key_id": "...",
        "aws_secret_access_key": "...",
        "aws_region": "us-east-1",
    },
)

# Using environment variables (preferred in production)
# Set AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_REGION
lf = pl.scan_parquet("s3://bucket/path/*.parquet")

# Using AWS profile
lf = pl.scan_parquet(
    "s3://bucket/path/*.parquet",
    storage_options={"aws_profile": "my-profile"},
)

# Writing to S3
df.write_parquet(
    "s3://bucket/output.parquet",
    storage_options={"aws_region": "us-east-1"},
)
```

### Google Cloud Storage (GCS)

```python
lf = pl.scan_parquet(
    "gs://bucket/path/*.parquet",
    storage_options={
        "service_account": "/path/to/service-account.json",
    },
)

# Or with application default credentials
lf = pl.scan_parquet("gs://bucket/path/*.parquet")
```

### Azure Blob Storage

```python
lf = pl.scan_parquet(
    "abfss://container@account.dfs.core.windows.net/path/*.parquet",
    storage_options={
        "account_name": "myaccount",
        "account_key": "...",
    },
)

# With SAS token
lf = pl.scan_parquet(
    "az://container/path/*.parquet",
    storage_options={
        "account_name": "myaccount",
        "sas_token": "...",
    },
)

# With Azure AD / DefaultAzureCredential
lf = pl.scan_parquet(
    "az://container/path/*.parquet",
    storage_options={
        "account_name": "myaccount",
        "use_azure_cli": "true",
    },
)
```

### Using fsspec

For unsupported or custom storage backends:

```python
import fsspec

# With fsspec filesystem
fs = fsspec.filesystem("s3", anon=True)  # public bucket

with fs.open("s3://bucket/data.parquet") as f:
    df = pl.read_parquet(f)

# Or register a filesystem
from fsspec.implementations.http import HTTPFileSystem
fs = HTTPFileSystem()

with fs.open("https://example.com/data.parquet") as f:
    df = pl.read_parquet(f)
```

### Hive-Partitioned Data

```python
# Directory structure:
# data/
#   year=2023/
#     month=01/
#       part-001.parquet
#     month=02/
#       part-001.parquet
#   year=2024/
#     month=01/
#       part-001.parquet

lf = pl.scan_parquet(
    "data/**/*.parquet",
    hive_partitioning=True,
)
# year and month are automatically added as columns

# Filter on partition columns — extremely fast (file-level pruning)
result = lf.filter(
    (pl.col("year") == 2024) & (pl.col("month") == 1)
).collect()
```

---

## Database Connections

### ConnectorX (Default, Recommended)

`pip install connectorx`

```python
# PostgreSQL
df = pl.read_database_uri(
    query="SELECT * FROM users WHERE active = true",
    uri="postgresql://user:pass@host:5432/dbname",
)

# MySQL
df = pl.read_database_uri(
    query="SELECT * FROM orders LIMIT 10000",
    uri="mysql://user:pass@host:3306/dbname",
)

# SQLite
df = pl.read_database_uri(
    query="SELECT * FROM products",
    uri="sqlite:///path/to/database.db",
)

# SQL Server
df = pl.read_database_uri(
    query="SELECT * FROM table",
    uri="mssql://user:pass@host:1433/dbname",
)
```

### ADBC (Arrow Database Connectivity)

`pip install adbc-driver-postgresql adbc-driver-sqlite`

```python
import adbc_driver_postgresql.dbapi

conn = adbc_driver_postgresql.dbapi.connect(
    "postgresql://user:pass@host:5432/dbname"
)

df = pl.read_database(
    query="SELECT * FROM users",
    connection=conn,
)

conn.close()
```

### SQLAlchemy

```python
from sqlalchemy import create_engine

engine = create_engine("postgresql://user:pass@host:5432/db")
df = pl.read_database(
    query="SELECT * FROM users",
    connection=engine,
)
```

### Writing to Databases

```python
# Convert to Pandas and use to_sql (simplest approach)
df.to_pandas().to_sql("table_name", engine, if_exists="append", index=False)

# Or use ADBC for direct Arrow writes
import adbc_driver_postgresql.dbapi

with adbc_driver_postgresql.dbapi.connect(uri) as conn:
    with conn.cursor() as cur:
        cur.adbc_ingest("table_name", df.to_arrow(), mode="append")
    conn.commit()
```

---

## JSON and NDJSON

### JSON (Standard)

```python
# Read JSON array
df = pl.read_json("data.json")

# From string
df = pl.read_json(b'[{"a": 1, "b": "x"}, {"a": 2, "b": "y"}]')

# Write JSON
df.write_json("output.json")
df.write_json("output.json", row_oriented=True)  # array of objects
```

### NDJSON (Newline-Delimited JSON — Preferred for Large Files)

```python
# Read NDJSON (one JSON object per line)
df = pl.read_ndjson("data.ndjson")

# Lazy scan
lf = pl.scan_ndjson("data.ndjson")

# With options
df = pl.read_ndjson(
    "data.ndjson",
    n_rows=1000,
    ignore_errors=True,
    schema={"id": pl.Int64, "name": pl.String},
)

# Write NDJSON
df.write_ndjson("output.ndjson")

# Streaming sink
lf.sink_ndjson("output.ndjson")
```

### NDJSON Tips

- Prefer NDJSON over JSON for large datasets — streamable, each line is independent
- Use `scan_ndjson` for lazy evaluation
- NDJSON is ideal for log files, event streams, and data pipelines

---

## Arrow IPC

Arrow IPC (Inter-Process Communication) format is the fastest for Arrow-native data exchange.

### Reading IPC

```python
# Read IPC file
df = pl.read_ipc("data.arrow")
df = pl.read_ipc("data.feather")  # Feather v2 = IPC

# Lazy scan
lf = pl.scan_ipc("data.arrow")

# Memory-mapped (fastest, but file must stay accessible)
lf = pl.scan_ipc("data.arrow", memory_map=True)
```

### Writing IPC

```python
df.write_ipc("output.arrow")

df.write_ipc(
    "output.arrow",
    compression="zstd",  # "zstd", "lz4", "uncompressed"
)

# Streaming sink
lf.sink_ipc("output.arrow")
```

### IPC vs Parquet

| Feature | IPC (Arrow/Feather) | Parquet |
|---------|---------------------|---------|
| Read speed | Fastest (near zero-copy) | Fast with pushdown |
| Write speed | Fastest | Slower (encoding) |
| Compression | Good (zstd/lz4) | Best (zstd/snappy) |
| File size | Larger | Smaller |
| Predicate pushdown | No | Yes |
| Ecosystem support | Moderate | Universal |
| Best for | Caching, inter-process | Storage, data lakes |

---

## Excel

Requires `openpyxl`, `xlsx2csv`, or `calamine`: `pip install fastexcel`

### Reading Excel

```python
df = pl.read_excel(
    "data.xlsx",
    sheet_name="Sheet1",       # or sheet_id=0
    engine="calamine",         # fastest; also "openpyxl", "xlsx2csv"
)

# Read all sheets
sheets = pl.read_excel(
    "data.xlsx",
    sheet_name=None,  # returns dict of DataFrames
)

# With options
df = pl.read_excel(
    "data.xlsx",
    sheet_name="Sales",
    read_options={
        "skip_rows": 2,
        "n_rows": 1000,
        "columns": [0, 1, 3],  # by index
    },
)
```

### Writing Excel

```python
# Requires xlsxwriter: pip install xlsxwriter
df.write_excel(
    "output.xlsx",
    worksheet="Results",
    float_precision=2,
    has_header=True,
    autofit=True,
)
```

---

## IO Performance Tips

### Format Selection Guide

| Use Case | Best Format | Why |
|----------|-------------|-----|
| Data lake / warehouse | Parquet | Compressed, typed, pushdown |
| Fast caching | Arrow IPC | Near zero-copy reads |
| Data exchange | NDJSON | Human-readable, streamable |
| Delta/versioned data | Delta Lake | ACID, time travel |
| Legacy systems | CSV | Universal compatibility |
| Spreadsheet users | Excel | Business-friendly |

### General Tips

1. **Always use `scan_*` over `read_*`** for lazy evaluation
2. **Set column types explicitly** with `dtypes` to avoid inference overhead
3. **Read only needed columns** — projection pushdown saves IO and memory
4. **Use glob patterns** to read multiple files: `scan_parquet("data/**/*.parquet")`
5. **Enable Hive partitioning** for partitioned datasets
6. **Use streaming sinks** (`sink_parquet`, `sink_csv`) for large transformations
7. **Prefer Parquet** — columnar, compressed, typed, and supports pushdown
8. **Use zstd compression** — best speed/ratio tradeoff for Parquet
9. **Set `rechunk=True`** after reading multiple files for better performance
10. **Use `low_memory=True`** when memory is constrained (trades speed for memory)
