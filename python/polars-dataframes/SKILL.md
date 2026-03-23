---
name: polars-dataframes
description: >-
  Use when writing Python code that imports polars, uses pl.DataFrame, pl.LazyFrame,
  pl.col, pl.scan_csv, pl.scan_parquet, pl.read_csv, pl.read_parquet, or any Polars
  expression API. Also use when user asks to process DataFrames with Polars, migrate
  from Pandas to Polars, optimize DataFrame performance, or work with Arrow-backed
  columnar data in Python. Trigger on mentions of "polars", "LazyFrame", "pl.col",
  "scan_parquet", "group_by" (underscore form), or Polars expression chains.
  Do NOT use for: Pandas-only code (import pandas), PySpark/Dask/Vaex distributed
  computing, raw SQL databases, NumPy-only array math, or R data.table/dplyr.
---

# Polars DataFrames

## When to Use Polars vs Pandas

Choose Polars when:
- Dataset exceeds 1M rows or needs sub-second performance
- Pipeline benefits from lazy evaluation and query optimization
- Working with Parquet, Arrow, or Delta Lake formats
- Need parallel execution without GIL limitations
- Want strict type safety and null handling

Stay with Pandas when:
- Ecosystem requires it (sklearn pipelines, legacy APIs expecting pd.DataFrame)
- Using pandas-specific extensions (GeoPandas, pandas-ta)
- Quick prototyping with tiny datasets and matplotlib integration

## Core Concepts

### Eager vs Lazy Evaluation

Eager executes immediately. Lazy builds a query plan, optimizes, then executes on `.collect()`.

```python
import polars as pl

# Eager — executes each step immediately
df = pl.read_csv("data.csv")
result = df.filter(pl.col("age") > 30).select("name", "age")

# Lazy — builds optimized plan, executes once
result = (
    pl.scan_csv("data.csv")
    .filter(pl.col("age") > 30)
    .select("name", "age")
    .collect()
)
```

Prefer lazy. It enables predicate pushdown (filters pushed to scan), projection pushdown (only needed columns read), and common subexpression elimination.

### Expressions

Expressions are the building blocks. They describe computations on columns without executing them.

Three main contexts:
- `select()` — choose and transform columns (outputs only listed columns)
- `with_columns()` — add/modify columns (keeps all existing columns)
- `filter()` — row-level boolean filtering

```python
df.select(
    pl.col("name"),
    (pl.col("price") * pl.col("quantity")).alias("total"),
    pl.lit(True).alias("active"),
)
```

## DataFrame Creation

```python
# From dict
df = pl.DataFrame({
    "id": [1, 2, 3],
    "name": ["Alice", "Bob", "Carol"],
    "score": [95.0, 87.5, 92.0],
})

# From CSV / Parquet (eager)
df = pl.read_csv("data.csv")
df = pl.read_parquet("data.parquet")

# From CSV / Parquet (lazy — preferred for large files)
lf = pl.scan_csv("data.csv")
lf = pl.scan_parquet("data.parquet")

# From Pandas
df = pl.from_pandas(pandas_df)

# From Arrow table
df = pl.from_arrow(arrow_table)

# From dicts (row-oriented)
df = pl.from_dicts([{"a": 1, "b": "x"}, {"a": 2, "b": "y"}])

# From database (read_database requires connectorx or SQLAlchemy)
df = pl.read_database("SELECT * FROM users", connection_uri)
```

## Column Operations

### select and with_columns

```python
# Select specific columns with transformations
df.select(
    pl.col("name").str.to_uppercase().alias("NAME"),
    pl.col("score").round(0),
)

# Add new columns while keeping existing ones
df.with_columns(
    (pl.col("score") / 100).alias("score_pct"),
    pl.col("name").str.len_chars().alias("name_len"),
)
```

### filter

```python
df.filter(
    (pl.col("score") > 90) & (pl.col("name") != "Bob")
)

# Multiple conditions
df.filter(
    pl.col("status").is_in(["active", "pending"]),
    pl.col("age").is_between(18, 65),  # multiple args are AND-ed
)
```

### group_by and agg

```python
df.group_by("department").agg(
    pl.col("salary").mean().alias("avg_salary"),
    pl.col("salary").max().alias("max_salary"),
    pl.col("name").count().alias("headcount"),
    pl.col("name").first().alias("first_employee"),
)
# Input:
# ┌────────────┬────────┬───────┐
# │ department │ name   │salary │
# ├────────────┼────────┼───────┤
# │ Eng        │ Alice  │ 120k  │
# │ Eng        │ Bob    │ 110k  │
# │ Sales      │ Carol  │ 95k   │
# └────────────┴────────┴───────┘
# Output:
# ┌────────────┬────────────┬────────────┬───────────┬────────────────┐
# │ department │ avg_salary │ max_salary │ headcount │ first_employee │
# ├────────────┼────────────┼────────────┼───────────┼────────────────┤
# │ Eng        │ 115000     │ 120000     │ 2         │ Alice          │
# │ Sales      │ 95000      │ 95000      │ 1         │ Carol          │
# └────────────┴────────────┴────────────┴───────────┴────────────────┘
```

### join

```python
# Inner join (default)
df1.join(df2, on="id", how="inner")

# Left join with different column names
df1.join(df2, left_on="user_id", right_on="id", how="left")

# Available: "inner", "left", "right", "full", "cross", "semi", "anti"
# Anti join — rows in df1 with NO match in df2
missing = orders.join(products, on="product_id", how="anti")
```

### sort and unique

```python
df.sort("score", descending=True)
df.sort("dept", "score", descending=[False, True])  # multi-column
df.unique(subset=["email"])  # deduplicate
df.unique(subset=["email"], keep="last", maintain_order=True)
```

## Expression API

### col, lit, when/then/otherwise

```python
# Conditional column
df.with_columns(
    pl.when(pl.col("score") >= 90)
      .then(pl.lit("A"))
      .when(pl.col("score") >= 80)
      .then(pl.lit("B"))
      .otherwise(pl.lit("C"))
      .alias("grade")
)
```

### over (window functions)

`over()` computes an expression within groups without collapsing rows.

```python
df.with_columns(
    pl.col("salary").mean().over("department").alias("dept_avg"),
    pl.col("salary").rank("dense").over("department").alias("dept_rank"),
    (pl.col("salary") / pl.col("salary").sum().over("department"))
        .alias("salary_share"),
)
```

### struct and list expressions

```python
# Create struct column from multiple columns
df.with_columns(
    pl.struct(["first_name", "last_name"]).alias("full_name")
)

# Access struct fields
df.select(pl.col("full_name").struct.field("first_name"))

# List column operations
df.with_columns(
    pl.col("tags").list.len().alias("tag_count"),
    pl.col("tags").list.contains("python").alias("has_python"),
    pl.col("scores").list.mean().alias("avg_score"),
)

# Explode list column to rows
df.explode("tags")
```

## Lazy Frames and Query Optimization

```python
# Build lazy query
lf = (
    pl.scan_parquet("s3://bucket/data/**/*.parquet")
    .filter(pl.col("date") >= "2024-01-01")
    .with_columns(
        (pl.col("revenue") - pl.col("cost")).alias("profit")
    )
    .group_by("region")
    .agg(pl.col("profit").sum())
    .sort("profit", descending=True)
)

# Inspect the optimized plan before executing
print(lf.explain())

# Execute
result = lf.collect()

# Stream for datasets larger than RAM
result = lf.collect(streaming=True)
```

Key rules:
- Chain all transformations before `.collect()`
- Never call `.collect()` mid-pipeline; it kills optimization
- Use `.explain()` to verify pushdowns are applied
- Use `collect(streaming=True)` for out-of-core processing

## Data Types

| Polars Type      | Python Equivalent | Notes                              |
|------------------|-------------------|------------------------------------|
| `Int8`–`Int64`   | int               | Signed integers                    |
| `UInt8`–`UInt64` | int               | Unsigned integers                  |
| `Float32/64`     | float             |                                    |
| `Boolean`        | bool              |                                    |
| `Utf8` / `String`| str               | `String` is the canonical name     |
| `Date`           | date              | Calendar date, no time             |
| `Datetime`       | datetime          | With optional timezone             |
| `Duration`       | timedelta         | Difference between datetimes       |
| `Time`           | time              | Time of day                        |
| `Categorical`    | str               | Runtime-discovered categories      |
| `Enum`           | str               | Fixed, ordered set of categories   |
| `List`           | list              | Variable-length per row            |
| `Array`          | list              | Fixed-length per row               |
| `Struct`         | dict              | Named fields, like a row object    |
| `Null`           | None              |                                    |

### Categorical vs Enum

```python
# Categorical — categories discovered at runtime
s = pl.Series("animal", ["cat", "dog", "cat"], dtype=pl.Categorical)

# Enum — categories fixed upfront, enforced
level = pl.Enum(["low", "medium", "high"])
s = pl.Series("priority", ["low", "high", "medium"], dtype=level)
# pl.Series(["unknown"], dtype=level)  # raises InvalidOperationError
```

Use Enum when categories are known and you want ordering/validation. Use Categorical when categories are dynamic.

### Temporal Operations

```python
df.with_columns(
    pl.col("timestamp").dt.year().alias("year"),
    pl.col("timestamp").dt.month().alias("month"),
    pl.col("timestamp").dt.weekday().alias("dow"),  # Monday=1
    pl.col("timestamp").dt.truncate("1h").alias("hour_bucket"),
    (pl.col("end") - pl.col("start")).dt.total_seconds().alias("duration_s"),
)

# Parse strings to datetime
df.with_columns(
    pl.col("date_str").str.to_datetime("%Y-%m-%d %H:%M:%S")
)

# Filter by date range
df.filter(pl.col("date").is_between(pl.date(2024, 1, 1), pl.date(2024, 12, 31)))
```

## Window Functions and Rolling Operations

```python
# Rolling statistics
df.with_columns(
    pl.col("price").rolling_mean(window_size=7).alias("ma_7"),
    pl.col("price").rolling_std(window_size=7).alias("std_7"),
)

# Grouped rolling — rolling mean per category
df.with_columns(
    pl.col("sales").rolling_mean(window_size=3).over("category").alias("rolling_avg")
)

# Cumulative operations
df.with_columns(
    pl.col("revenue").cum_sum().over("region").alias("cumulative_rev"),
    pl.col("event").cum_count().alias("event_number"),
)

# group_by_dynamic for time-based windows
df.sort("timestamp").group_by_dynamic(
    "timestamp", every="1d", period="7d", group_by="category"
).agg(
    pl.col("value").mean().alias("weekly_avg"),
)
```

### String Operations

```python
df.with_columns(
    pl.col("email").str.to_lowercase(),
    pl.col("name").str.strip_chars(),
    pl.col("url").str.contains("https").alias("is_secure"),
    pl.col("text").str.replace_all(r"[^\w\s]", "").alias("clean"),
    pl.col("full_name").str.split(" ").alias("name_parts"),
    pl.col("csv_field").str.extract(r"(\d+)", 1).cast(pl.Int64),
)
```

## IO Operations

```python
# Read (eager) vs Scan (lazy — preferred for large files)
df = pl.read_csv("data.csv", separator=",", has_header=True, dtypes={"id": pl.Int64})
lf = pl.scan_csv("data.csv")
df = pl.read_parquet("data.parquet")
lf = pl.scan_parquet("data/**/*.parquet")  # glob patterns supported
df = pl.read_ndjson("data.ndjson")
lf = pl.scan_ndjson("data.ndjson")
lf = pl.scan_delta("path/to/delta-table/")  # requires deltalake package
df = pl.read_ipc("data.arrow")

# Writing
df.write_parquet("output.parquet", compression="zstd")
df.write_csv("output.csv")
df.write_ndjson("output.ndjson")
df.write_delta("path/to/delta-table/", mode="append")  # "overwrite", "append", "error"

# Cloud storage — pass storage_options for S3, Azure, GCS
lf = pl.scan_parquet("s3://bucket/path/*.parquet",
    storage_options={"AWS_ACCESS_KEY_ID": "...", "AWS_SECRET_ACCESS_KEY": "..."})
lf = pl.scan_parquet("abfss://container@account.dfs.core.windows.net/*.parquet",
    storage_options={"account_name": "...", "account_key": "..."})
lf = pl.scan_parquet("gs://bucket/path/*.parquet",
    storage_options={"token": "..."})
```

## Integration with Other Tools

```python
# To/from Pandas
pandas_df = df.to_pandas()
df = pl.from_pandas(pandas_df)

# To/from NumPy
numpy_arr = df.to_numpy()                      # returns 2D array
series_arr = df["column"].to_numpy()            # returns 1D array

# To/from Arrow
arrow_table = df.to_arrow()
df = pl.from_arrow(arrow_table)

# Zero-copy when possible — Arrow-backed data avoids copies
```

## Performance Tips

1. **Use `scan_*` over `read_*`** — enables predicate/projection pushdown
2. **Avoid `.to_pandas()`** — converts to row-major, kills performance. Stay in Polars.
3. **Never use `.apply()` with Python lambdas** — use expression API instead
4. **Use `.collect(streaming=True)`** for datasets larger than RAM
5. **Prefer Parquet over CSV** — columnar, compressed, typed, supports pushdown
6. **Use `Categorical`/`Enum`** for low-cardinality string columns
7. **Cast early** — `pl.col("x").cast(pl.Float32)` reduces memory
8. **Avoid row-wise iteration** — `for row in df.iter_rows()` is an antipattern; use expressions
9. **Use `sink_parquet()`** on lazy frames to write streaming results without materializing

## Common Pitfalls and Pandas Migration

| Pandas                          | Polars                                          |
|---------------------------------|-------------------------------------------------|
| `df["col"]`                     | `df.select("col")` or `df["col"]` (Series)     |
| `df.loc[mask]`                  | `df.filter(pl.col("x") > 5)`                   |
| `df["new"] = val`              | `df.with_columns(pl.lit(val).alias("new"))`     |
| `df.apply(fn, axis=1)`         | Use `pl.struct` + `.map_elements()` (last resort)|
| `df.groupby("x").agg({"y":"mean"})` | `df.group_by("x").agg(pl.col("y").mean())` |
| `df.merge(df2, on="id")`       | `df.join(df2, on="id")`                         |
| `df.rename(columns={...})`     | `df.rename({"old": "new"})`                     |
| `pd.concat([df1, df2])`        | `pl.concat([df1, df2])`                         |
| `df.fillna(0)`                 | `df.fill_null(0)`                               |
| `df.isna()`                    | `df.is_null()` (NOT `is_nan()`)                 |
| `df.drop_duplicates()`         | `df.unique()`                                   |
| `df.sort_values("x")`          | `df.sort("x")`                                  |
| `inplace=True`                 | Does not exist. Polars DataFrames are immutable. |

Key differences:
- Polars has no index. Use columns explicitly.
- Polars distinguishes `null` (missing) from `NaN` (float not-a-number).
- `group_by` uses underscore, not `groupby`.
- All operations return new DataFrames; no mutation in place.
- String methods live under `.str`, datetime under `.dt`, list under `.list`.

### SQL Interface

```python
ctx = pl.SQLContext(users=df_users, orders=df_orders)
result = ctx.execute("""
    SELECT u.name, SUM(o.amount) as total
    FROM users u
    JOIN orders o ON u.id = o.user_id
    GROUP BY u.name
""").collect()
```

## Additional Resources

### References (Deep Dives)

| File | Description |
|------|-------------|
| `references/advanced-patterns.md` | Complex expressions, LazyFrame optimization, streaming, plugins, struct/list manipulation, dynamic column selection, pivot/unpivot, time series ops, multi-DataFrame operations |
| `references/pandas-migration.md` | Side-by-side Pandas↔Polars comparison, common gotchas, `to_pandas()`/`from_pandas()` patterns, missing features, performance comparison, when to switch |
| `references/io-guide.md` | CSV, Parquet (row groups, pushdown), Delta Lake, cloud storage (S3/GCS/Azure), databases (connectorx, ADBC), JSON/NDJSON, Arrow IPC, Excel |

### Scripts (Runnable Tools)

| File | Description |
|------|-------------|
| `scripts/benchmark-vs-pandas.py` | Benchmark Polars vs Pandas on groupby, join, filter, sort. Run: `python benchmark-vs-pandas.py --rows 5000000` |
| `scripts/polars-profiler.py` | Profile LazyFrame query plans — shows optimized plan, detected optimizations, execution timing. Run: `python polars-profiler.py --demo` |
| `scripts/csv-to-parquet.py` | CLI tool to convert CSV→Parquet with compression, partitioning, streaming. Run: `python csv-to-parquet.py input.csv output.parquet` |

### Assets (Templates & References)

| File | Description |
|------|-------------|
| `assets/cheatsheet.md` | Quick-reference cheatsheet — all common Polars operations in 1-2 lines each |
| `assets/etl-template.py` | Production ETL pipeline template with schema validation, quality checks, lazy evaluation |
| `assets/jupyter-starter.py` | Data exploration starter script with profiling, cleaning, analysis, and visualization sections |

<!-- tested: needs-fix -->
