# Advanced Polars Patterns

## Table of Contents

- [Complex Expression Chains](#complex-expression-chains)
- [Custom Expressions](#custom-expressions)
- [LazyFrame Optimization](#lazyframe-optimization)
- [Streaming Mode](#streaming-mode)
- [Plugin System and Custom Rust Expressions](#plugin-system-and-custom-rust-expressions)
- [Struct Column Manipulation](#struct-column-manipulation)
- [List Column Manipulation](#list-column-manipulation)
- [Dynamic Column Selection](#dynamic-column-selection)
- [Pivot, Unpivot, and Melt](#pivot-unpivot-and-melt)
- [Time Series Operations](#time-series-operations)
- [Multi-DataFrame Operations](#multi-dataframe-operations)

---

## Complex Expression Chains

### Chaining Multiple Transformations

Polars expressions compose naturally. Chain methods to build complex column transformations in a single pass:

```python
import polars as pl

df.with_columns(
    pl.col("revenue")
      .fill_null(0)
      .cast(pl.Float64)
      .log()
      .rolling_mean(window_size=7)
      .over("region")
      .alias("log_revenue_ma7"),
)
```

### Multi-Column Expressions

Apply the same expression to multiple columns:

```python
# Apply to columns matching a pattern
df.with_columns(
    pl.col("^metric_.*$").fill_null(0).name.prefix("clean_"),
)

# Apply to a list of columns
df.with_columns(
    pl.col(["revenue", "cost", "profit"]).cast(pl.Float64).round(2),
)

# Apply to all columns of a type
df.with_columns(
    pl.col(pl.Float64).round(2),
)
```

### Horizontal Expressions

Operate across columns within a row:

```python
df.with_columns(
    pl.sum_horizontal("q1", "q2", "q3", "q4").alias("annual_total"),
    pl.mean_horizontal("q1", "q2", "q3", "q4").alias("quarterly_avg"),
    pl.min_horizontal("q1", "q2", "q3", "q4").alias("worst_quarter"),
    pl.max_horizontal("q1", "q2", "q3", "q4").alias("best_quarter"),
    pl.any_horizontal(pl.col("q1") > 100, pl.col("q2") > 100).alias("any_over_100"),
    pl.all_horizontal(pl.col("q1") > 0, pl.col("q2") > 0).alias("all_positive"),
)
```

### Nested when/then/otherwise

```python
df.with_columns(
    pl.when(pl.col("status") == "premium")
      .then(pl.col("price") * 0.8)
      .when(
          (pl.col("status") == "member") & (pl.col("quantity") > 10)
      )
      .then(pl.col("price") * 0.9)
      .when(pl.col("coupon").is_not_null())
      .then(pl.col("price") - pl.col("coupon"))
      .otherwise(pl.col("price"))
      .alias("final_price")
)
```

### map_batches for Vectorized UDFs

When the expression API isn't enough, use `map_batches` for vectorized operations:

```python
df.with_columns(
    pl.col("text").map_batches(
        lambda s: s.str.replace_all(r"\s+", " "),
        return_dtype=pl.String,
    ).alias("cleaned_text"),
)
```

Warning: `map_elements` (per-element) is much slower than `map_batches` (per-column). Use `map_elements` only as a last resort.

```python
# SLOW — avoid unless absolutely necessary
df.with_columns(
    pl.col("data").map_elements(
        lambda x: complex_python_function(x),
        return_dtype=pl.Float64,
    )
)
```

---

## Custom Expressions

### Extending with pl.Expr.register

Register reusable expression methods via custom namespaces:

```python
@pl.api.register_expr_namespace("finance")
class FinanceExpr:
    def __init__(self, expr: pl.Expr):
        self._expr = expr

    def returns(self) -> pl.Expr:
        """Calculate period-over-period returns."""
        return self._expr.pct_change()

    def log_returns(self) -> pl.Expr:
        """Calculate log returns."""
        return (self._expr / self._expr.shift(1)).log()

    def sharpe_ratio(self, risk_free: float = 0.0, periods: int = 252) -> pl.Expr:
        """Annualized Sharpe ratio."""
        returns = self._expr.pct_change()
        return (
            (returns.mean() - risk_free / periods)
            / returns.std()
            * (periods ** 0.5)
        )

# Usage
df.with_columns(
    pl.col("close").finance.returns().alias("daily_returns"),
    pl.col("close").finance.log_returns().alias("log_returns"),
)
```

### Custom DataFrame Namespace

```python
@pl.api.register_dataframe_namespace("utils")
class DataFrameUtils:
    def __init__(self, df: pl.DataFrame):
        self._df = df

    def describe_nulls(self) -> pl.DataFrame:
        """Show null counts and percentages for all columns."""
        return self._df.select(
            pl.all().null_count().name.suffix("_null_count"),
        ).unpivot().with_columns(
            (pl.col("value") / len(self._df) * 100).round(2).alias("pct"),
        )

# Usage
df.utils.describe_nulls()
```

---

## LazyFrame Optimization

Polars' query optimizer applies several transformations automatically.

### Predicate Pushdown

Filters are pushed as close to the data source as possible:

```python
# Before optimization: scan all data, then filter
# After optimization: filter applied during scan (Parquet row group skipping)
lf = (
    pl.scan_parquet("data/*.parquet")
    .join(pl.scan_parquet("lookup.parquet"), on="id")
    .filter(pl.col("date") >= "2024-01-01")  # pushed to scan
)

# Verify with explain()
print(lf.explain())
# Output shows FILTER pushed before JOIN
```

### Projection Pushdown

Only needed columns are read from disk:

```python
lf = (
    pl.scan_parquet("wide_table.parquet")  # 500 columns on disk
    .select("name", "date", "revenue")      # only 3 columns read
)
```

### Slice Pushdown

Limit operations are pushed to scans:

```python
lf = (
    pl.scan_csv("huge.csv")
    .filter(pl.col("status") == "active")
    .head(100)  # pushes LIMIT to scan
)
```

### Common Subexpression Elimination (CSE)

Repeated expressions are computed once:

```python
lf = pl.scan_csv("data.csv").with_columns(
    (pl.col("a") + pl.col("b")).alias("sum_ab"),
    ((pl.col("a") + pl.col("b")) * 2).alias("double_sum"),
    # The engine computes (a + b) once and reuses it
)

# Enable CSE explicitly if needed
result = lf.collect(comm_subexpr_elim=True)
```

### Inspecting Query Plans

```python
lf = (
    pl.scan_parquet("data.parquet")
    .filter(pl.col("value") > 100)
    .group_by("category")
    .agg(pl.col("value").sum())
)

# Unoptimized plan
print(lf.explain(optimized=False))

# Optimized plan (default)
print(lf.explain())

# Show the plan as a diagram (returns a string representation)
print(lf.explain(format="tree"))
```

---

## Streaming Mode

For datasets larger than RAM, use streaming execution:

```python
# Streaming collect — processes data in batches
result = (
    pl.scan_parquet("s3://bucket/huge/**/*.parquet")
    .filter(pl.col("year") >= 2023)
    .group_by("category")
    .agg(pl.col("amount").sum())
    .collect(streaming=True)
)

# Streaming sink — write results without collecting to memory
(
    pl.scan_csv("huge_input.csv")
    .filter(pl.col("valid") == True)
    .with_columns(pl.col("amount").cast(pl.Float64))
    .sink_parquet("output.parquet")
)

# sink_csv and sink_ipc also available
(
    pl.scan_parquet("input.parquet")
    .filter(pl.col("region") == "US")
    .sink_csv("us_data.csv")
)
```

### Streaming Limitations

Not all operations support streaming. These will fall back to in-memory:
- Some join types (cross joins, certain anti-joins)
- `sort()` on very large datasets (requires materializing)
- `group_by` with very high cardinality keys
- Custom Python UDFs (`map_elements`, `map_batches`)

Check `lf.explain(streaming=True)` to verify streaming is active.

---

## Plugin System and Custom Rust Expressions

Polars supports writing custom expressions in Rust for maximum performance.

### Plugin Structure

```
my_polars_plugin/
├── Cargo.toml
├── src/
│   └── lib.rs
└── my_plugin/
    └── __init__.py
```

### Rust Side (src/lib.rs)

```rust
use polars::prelude::*;
use polars_plan::dsl::FieldsMapper;
use pyo3_polars::derive::polars_expr;

#[polars_expr(output_type=Float64)]
fn fast_sigmoid(inputs: &[Series]) -> PolarsResult<Series> {
    let s = inputs[0].f64()?;
    let out: Float64Chunked = s.apply(|val| {
        val.map(|v| 1.0 / (1.0 + (-v).exp()))
    });
    Ok(out.into_series())
}
```

### Python Side (\_\_init\_\_.py)

```python
import polars as pl
from pathlib import Path

LIB = Path(__file__).parent

def fast_sigmoid(expr: pl.Expr) -> pl.Expr:
    return expr.register_plugin(
        lib=LIB,
        symbol="fast_sigmoid",
        is_elementwise=True,
    )

# Usage
df.with_columns(fast_sigmoid(pl.col("score")).alias("probability"))
```

---

## Struct Column Manipulation

### Creating Structs

```python
# From multiple columns
df.with_columns(
    pl.struct(["city", "state", "zip"]).alias("address"),
)

# From expressions
df.with_columns(
    pl.struct(
        pl.col("first_name").alias("first"),
        pl.col("last_name").alias("last"),
        (pl.col("first_name") + " " + pl.col("last_name")).alias("full"),
    ).alias("name_info"),
)
```

### Accessing Struct Fields

```python
# Single field
df.select(pl.col("address").struct.field("city"))

# Multiple fields
df.select(pl.col("address").struct.field("city", "state"))

# Rename fields
df.with_columns(
    pl.col("address").struct.rename_fields(["City", "State", "ZIP"]),
)
```

### Unnesting Structs

```python
# Expand struct into top-level columns
df.unnest("address")
# city | state | zip  (as separate columns)

# With prefix to avoid name collisions
df.with_columns(
    pl.col("address").struct.field("city").alias("addr_city"),
    pl.col("address").struct.field("state").alias("addr_state"),
)
```

### Struct in group_by

```python
# Use struct for multi-column aggregation results
df.group_by("department").agg(
    pl.struct(
        pl.col("salary").mean().alias("mean"),
        pl.col("salary").std().alias("std"),
        pl.col("salary").min().alias("min"),
        pl.col("salary").max().alias("max"),
    ).alias("salary_stats"),
)
```

---

## List Column Manipulation

### Creating List Columns

```python
# From aggregation
df.group_by("user").agg(
    pl.col("purchase").alias("all_purchases"),
    pl.col("amount").sort(descending=True).alias("amounts_desc"),
)

# From literal
df = pl.DataFrame({
    "tags": [["python", "rust"], ["java"], ["python", "go", "rust"]],
})
```

### List Operations

```python
df.with_columns(
    pl.col("tags").list.len().alias("count"),
    pl.col("tags").list.first().alias("first_tag"),
    pl.col("tags").list.last().alias("last_tag"),
    pl.col("tags").list.contains("python").alias("has_python"),
    pl.col("tags").list.sort().alias("sorted"),
    pl.col("tags").list.unique().alias("unique"),
    pl.col("tags").list.reverse().alias("reversed"),
    pl.col("tags").list.join(", ").alias("tag_string"),
    pl.col("tags").list.head(2).alias("first_two"),
    pl.col("tags").list.tail(1).alias("last_one"),
    pl.col("tags").list.slice(1, 2).alias("middle"),
    pl.col("tags").list.set_intersection(pl.lit(["python", "rust"])).alias("common"),
)
```

### List eval — Apply Expressions Inside Lists

```python
# Apply arbitrary expressions to each list element
df.with_columns(
    pl.col("scores").list.eval(pl.element().rank()).alias("ranked_scores"),
    pl.col("names").list.eval(
        pl.element().str.to_uppercase()
    ).alias("upper_names"),
    pl.col("values").list.eval(
        pl.element().filter(pl.element() > 0)
    ).alias("positive_values"),
)
```

### Explode and Implode

```python
# Explode: one row per list element
exploded = df.explode("tags")

# Implode: collect values back into lists (reverse of explode)
reimploded = exploded.group_by("id").agg(pl.col("tags"))
```

---

## Dynamic Column Selection

### Column Selectors (cs module)

```python
import polars.selectors as cs

# By dtype
df.select(cs.numeric())           # all numeric columns
df.select(cs.temporal())          # Date, Datetime, Time, Duration
df.select(cs.string())            # String/Utf8 columns
df.select(cs.boolean())           # Boolean columns
df.select(cs.categorical())       # Categorical columns
df.select(cs.float())             # Float32, Float64
df.select(cs.integer())           # Int8–Int64, UInt8–UInt64

# By name patterns
df.select(cs.by_name("id", "name"))           # exact names
df.select(cs.starts_with("metric_"))          # prefix match
df.select(cs.ends_with("_score"))             # suffix match
df.select(cs.contains("revenue"))             # substring match
df.select(cs.matches(r"^col_\d+$"))           # regex match

# By position
df.select(cs.first())
df.select(cs.last())
df.select(cs.by_index(0, 2, 4))

# Set operations on selectors
df.select(cs.numeric() - cs.by_name("id"))          # numeric except id
df.select(cs.numeric() | cs.temporal())              # numeric or temporal
df.select(cs.numeric() & cs.starts_with("metric_")) # numeric AND starts with metric_
df.select(~cs.string())                              # everything except strings

# Use selectors with operations
df.with_columns(cs.numeric().fill_null(0))
df.with_columns(cs.float().round(2))
df.with_columns(cs.string().str.to_lowercase())
```

### Programmatic Column Selection

```python
# Select columns dynamically from a list
cols = ["revenue", "cost", "profit"]
df.select(pl.col(cols))

# Regex-based column selection
df.select(pl.col("^feature_.*$"))

# Exclude columns
df.select(pl.exclude("internal_id", "debug_flag"))

# All columns
df.select(pl.all())
df.with_columns(pl.all().fill_null(strategy="forward"))
```

---

## Pivot, Unpivot, and Melt

### Pivot (Long → Wide)

```python
df = pl.DataFrame({
    "name": ["Alice", "Alice", "Bob", "Bob"],
    "subject": ["math", "english", "math", "english"],
    "score": [95, 88, 78, 92],
})

pivoted = df.pivot(
    on="subject",
    index="name",
    values="score",
    aggregate_function="first",
)
# ┌───────┬──────┬─────────┐
# │ name  │ math │ english │
# ├───────┼──────┼─────────┤
# │ Alice │ 95   │ 88      │
# │ Bob   │ 78   │ 92      │
# └───────┴──────┴─────────┘
```

### Unpivot / Melt (Wide → Long)

```python
wide_df = pl.DataFrame({
    "name": ["Alice", "Bob"],
    "math": [95, 78],
    "english": [88, 92],
    "science": [91, 85],
})

long_df = wide_df.unpivot(
    on=["math", "english", "science"],
    index="name",
    variable_name="subject",
    value_name="score",
)
# ┌───────┬─────────┬───────┐
# │ name  │ subject │ score │
# ├───────┼─────────┼───────┤
# │ Alice │ math    │ 95    │
# │ Alice │ english │ 88    │
# │ Alice │ science │ 91    │
# │ Bob   │ math    │ 78    │
# │ Bob   │ english │ 92    │
# │ Bob   │ science │ 85    │
# └───────┴─────────┴───────┘
```

### Dynamic Pivot with Aggregation

```python
df.pivot(
    on="quarter",
    index="product",
    values="revenue",
    aggregate_function="sum",   # sum, mean, first, last, count, min, max
)
```

---

## Time Series Operations

### group_by_dynamic

Time-based grouping with flexible windows:

```python
# Daily aggregation
df.sort("timestamp").group_by_dynamic(
    "timestamp",
    every="1d",
).agg(
    pl.col("value").sum().alias("daily_total"),
    pl.col("value").count().alias("daily_count"),
)

# Weekly windows sliding daily, per category
df.sort("timestamp").group_by_dynamic(
    "timestamp",
    every="1d",        # window starts every day
    period="7d",       # each window spans 7 days
    group_by="category",
    closed="left",
    label="left",
    start_by="datapoint",
).agg(
    pl.col("value").mean().alias("rolling_7d_avg"),
)
```

### Rolling Operations

```python
# Index-based rolling (time-aware)
df.sort("date").with_columns(
    pl.col("price").rolling_mean_by(
        by="date",
        window_size="30d",
    ).alias("30d_ma"),
)

# Integer-based rolling
df.with_columns(
    pl.col("value").rolling_mean(window_size=7).alias("ma_7"),
    pl.col("value").rolling_std(window_size=7).alias("std_7"),
    pl.col("value").rolling_min(window_size=7).alias("min_7"),
    pl.col("value").rolling_max(window_size=7).alias("max_7"),
    pl.col("value").rolling_median(window_size=7).alias("med_7"),
    pl.col("value").rolling_quantile(0.95, window_size=20).alias("p95_20"),
)

# Exponentially weighted moving average
df.with_columns(
    pl.col("value").ewm_mean(span=10).alias("ewma_10"),
)
```

### Upsample

Fill gaps in time series:

```python
df.sort("timestamp").upsample(
    time_column="timestamp",
    every="1h",           # insert missing hourly rows
    group_by="sensor_id",
).with_columns(
    pl.col("value").interpolate().alias("value"),  # fill gaps
)
```

### Resampling with group_by_dynamic

```python
# Downsample: 1-minute data → 5-minute bars (OHLCV)
df.sort("timestamp").group_by_dynamic(
    "timestamp",
    every="5m",
).agg(
    pl.col("price").first().alias("open"),
    pl.col("price").max().alias("high"),
    pl.col("price").min().alias("low"),
    pl.col("price").last().alias("close"),
    pl.col("volume").sum().alias("volume"),
)
```

### Shift and Diff

```python
df.with_columns(
    pl.col("value").shift(1).alias("prev_value"),
    pl.col("value").shift(-1).alias("next_value"),
    pl.col("value").diff().alias("change"),
    pl.col("value").pct_change().alias("pct_change"),
)
```

---

## Multi-DataFrame Operations

### concat — Vertical Stacking

```python
# Stack DataFrames vertically (same columns)
combined = pl.concat([df1, df2, df3])

# Rechunk after concat for better performance
combined = pl.concat([df1, df2, df3], rechunk=True)

# Relaxed concat — allows different column orders
combined = pl.concat([df1, df2], how="vertical_relaxed")
```

### diagonal_concat — Union with Missing Columns

```python
# DataFrames with different columns — fills missing with null
df1 = pl.DataFrame({"a": [1, 2], "b": [3, 4]})
df2 = pl.DataFrame({"a": [5, 6], "c": [7, 8]})
result = pl.concat([df1, df2], how="diagonal")
# ┌─────┬──────┬──────┐
# │ a   │ b    │ c    │
# ├─────┼──────┼──────┤
# │ 1   │ 3    │ null │
# │ 2   │ 4    │ null │
# │ 5   │ null │ 7    │
# │ 6   │ null │ 8    │
# └─────┴──────┴──────┘
```

### Horizontal Concatenation

```python
# Side-by-side concat (must have same number of rows)
wide = pl.concat([features_df, labels_df], how="horizontal")
```

### align_frames

Align multiple DataFrames on a common key:

```python
df1 = pl.DataFrame({"date": ["2024-01-01", "2024-01-02"], "a": [1, 2]})
df2 = pl.DataFrame({"date": ["2024-01-02", "2024-01-03"], "b": [3, 4]})

aligned_1, aligned_2 = pl.align_frames(df1, df2, on="date")
# Both DataFrames now have the same date range, with nulls where data is missing
```

### Multi-DataFrame Joins

```python
# Chain multiple joins
result = (
    base_df
    .join(users_df, on="user_id", how="left")
    .join(products_df, on="product_id", how="left")
    .join(regions_df, on="region_code", how="left")
)

# Join with suffix to handle duplicate column names
result = df1.join(df2, on="id", how="left", suffix="_right")

# Asof join — match on nearest key (great for time series)
trades.sort("timestamp").join_asof(
    quotes.sort("timestamp"),
    on="timestamp",
    by="ticker",
    strategy="backward",   # match to most recent quote
    tolerance="1s",        # within 1 second
)
```

### Cross Join

```python
# Every combination of rows
combinations = df1.join(df2, how="cross")
```
