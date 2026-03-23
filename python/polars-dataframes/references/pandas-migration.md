# Pandas to Polars Migration Guide

## Table of Contents

- [Philosophy Differences](#philosophy-differences)
- [Side-by-Side Comparison Table](#side-by-side-comparison-table)
- [DataFrame Creation and IO](#dataframe-creation-and-io)
- [Indexing and Selection](#indexing-and-selection)
- [Filtering](#filtering)
- [Column Operations](#column-operations)
- [Aggregation and GroupBy](#aggregation-and-groupby)
- [Joins and Merges](#joins-and-merges)
- [Reshaping](#reshaping)
- [String Operations](#string-operations)
- [DateTime Operations](#datetime-operations)
- [Missing Data](#missing-data)
- [Type System Differences](#type-system-differences)
- [Common Gotchas](#common-gotchas)
- [to_pandas and from_pandas Patterns](#to_pandas-and-from_pandas-patterns)
- [Missing Pandas Features and Workarounds](#missing-pandas-features-and-workarounds)
- [Performance Comparison](#performance-comparison)
- [When to Stay on Pandas vs Switch](#when-to-stay-on-pandas-vs-switch)

---

## Philosophy Differences

| Aspect | Pandas | Polars |
|--------|--------|--------|
| Execution | Eager only | Eager + Lazy |
| Mutation | In-place mutations (`inplace=True`) | Immutable; always returns new DataFrame |
| Index | Row index is fundamental | No index; use columns explicitly |
| Null handling | `NaN` for float, `None` for object | Dedicated `null` type, separate from `NaN` |
| Parallelism | Single-threaded (GIL) | Multi-threaded by default |
| Memory | Row-major (NumPy) | Columnar (Apache Arrow) |
| API style | Method chaining or indexing | Expression-based DSL |

---

## Side-by-Side Comparison Table

### Reading Data

| Pandas | Polars | Notes |
|--------|--------|-------|
| `pd.read_csv("f.csv")` | `pl.read_csv("f.csv")` | Eager |
| `pd.read_csv("f.csv")` | `pl.scan_csv("f.csv").collect()` | Lazy (preferred) |
| `pd.read_parquet("f.pq")` | `pl.read_parquet("f.pq")` | |
| `pd.read_json("f.json")` | `pl.read_json("f.json")` | |
| `pd.read_sql(q, conn)` | `pl.read_database(q, conn)` | Uses connectorx |

### Selection

| Pandas | Polars | Notes |
|--------|--------|-------|
| `df["col"]` | `df["col"]` | Returns Series |
| `df[["a", "b"]]` | `df.select("a", "b")` | Returns DataFrame |
| `df.loc[0:5]` | `df.head(6)` or `df[0:6]` | Polars slicing is exclusive end |
| `df.loc[mask]` | `df.filter(expr)` | |
| `df.iloc[0]` | `df.row(0)` | Returns tuple |
| `df.loc[df["a"] > 5, "b"]` | `df.filter(pl.col("a") > 5).select("b")` | |
| `df.at[0, "col"]` | `df["col"][0]` | |

### Column Manipulation

| Pandas | Polars | Notes |
|--------|--------|-------|
| `df["new"] = val` | `df.with_columns(pl.lit(val).alias("new"))` | |
| `df.assign(new=val)` | `df.with_columns(pl.lit(val).alias("new"))` | |
| `df.drop("col", axis=1)` | `df.drop("col")` | |
| `df.rename(columns={"a":"b"})` | `df.rename({"a": "b"})` | |
| `df.astype({"a": int})` | `df.cast({"a": pl.Int64})` | |
| `df.columns` | `df.columns` | Same |
| `df.dtypes` | `df.dtypes` | Returns Polars types |
| `df.shape` | `df.shape` | Same |

### Filtering

| Pandas | Polars | Notes |
|--------|--------|-------|
| `df[df["a"] > 5]` | `df.filter(pl.col("a") > 5)` | |
| `df[df["a"].isin([1,2])]` | `df.filter(pl.col("a").is_in([1, 2]))` | |
| `df[df["a"].between(1, 5)]` | `df.filter(pl.col("a").is_between(1, 5))` | |
| `df[df["a"].notna()]` | `df.filter(pl.col("a").is_not_null())` | |
| `df.query("a > 5 and b < 10")` | `df.filter((pl.col("a") > 5) & (pl.col("b") < 10))` | |

### Sorting

| Pandas | Polars | Notes |
|--------|--------|-------|
| `df.sort_values("a")` | `df.sort("a")` | |
| `df.sort_values("a", ascending=False)` | `df.sort("a", descending=True)` | |
| `df.sort_values(["a","b"], ascending=[True,False])` | `df.sort("a", "b", descending=[False, True])` | |
| `df.nsmallest(5, "a")` | `df.sort("a").head(5)` | |
| `df.nlargest(5, "a")` | `df.sort("a", descending=True).head(5)` | |

### Aggregation

| Pandas | Polars | Notes |
|--------|--------|-------|
| `df.groupby("a").agg({"b":"mean"})` | `df.group_by("a").agg(pl.col("b").mean())` | |
| `df.groupby("a")["b"].transform("mean")` | `pl.col("b").mean().over("a")` | Window function |
| `df.groupby("a").size()` | `df.group_by("a").len()` | |
| `df.groupby("a").first()` | `df.group_by("a").first()` | |
| `df.value_counts()` | `df["col"].value_counts()` | |
| `df.describe()` | `df.describe()` | |
| `df.agg(["mean", "std"])` | `df.select(pl.all().mean(), pl.all().std())` | |

### Joins

| Pandas | Polars | Notes |
|--------|--------|-------|
| `pd.merge(df1, df2, on="id")` | `df1.join(df2, on="id")` | |
| `pd.merge(df1, df2, left_on="a", right_on="b")` | `df1.join(df2, left_on="a", right_on="b")` | |
| `pd.merge(df1, df2, how="left")` | `df1.join(df2, on="id", how="left")` | |
| `pd.concat([df1, df2])` | `pl.concat([df1, df2])` | |
| `pd.concat([df1, df2], axis=1)` | `pl.concat([df1, df2], how="horizontal")` | |

### Reshaping

| Pandas | Polars | Notes |
|--------|--------|-------|
| `df.pivot_table(values, index, columns)` | `df.pivot(on=columns, index=index, values=values)` | |
| `df.melt(id_vars, value_vars)` | `df.unpivot(on=value_vars, index=id_vars)` | |
| `df.stack()` | `df.unpivot()` | Approximate |
| `df.unstack()` | `df.pivot()` | Approximate |
| `df.explode("col")` | `df.explode("col")` | Same |
| `df.T` | `df.transpose()` | |

### Apply / Map

| Pandas | Polars | Notes |
|--------|--------|-------|
| `df["a"].apply(fn)` | `df.select(pl.col("a").map_elements(fn))` | Slow, avoid |
| `df["a"].map(dict)` | `df.select(pl.col("a").replace(dict))` | |
| `df.apply(fn, axis=1)` | `df.select(pl.struct(cols).map_elements(fn))` | Last resort |
| `df.applymap(fn)` | Use expression API instead | |
| `np.where(cond, a, b)` | `pl.when(cond).then(a).otherwise(b)` | |

---

## Common Gotchas

### 1. No Index

```python
# Pandas: df.loc["2024-01-01"]
# Polars: no index — filter explicitly
df.filter(pl.col("date") == "2024-01-01")
```

### 2. No inplace

```python
# Pandas: df.drop("col", axis=1, inplace=True)
# Polars: always reassign
df = df.drop("col")
```

### 3. null vs NaN

```python
# Pandas conflates None and NaN
# Polars keeps them separate
s = pl.Series([1.0, None, float("nan")])
s.is_null()   # [false, true, false]
s.is_nan()    # [false, false, true]
s.fill_null(0)  # fills None, not NaN
s.fill_nan(0)   # fills NaN, not None
```

### 4. Column Assignment

```python
# Pandas: df["new"] = df["a"] + df["b"]
# Polars: must use with_columns
df = df.with_columns((pl.col("a") + pl.col("b")).alias("new"))
```

### 5. Boolean Operators

```python
# Pandas: df[(df["a"] > 5) & (df["b"] < 10)]
# Polars: same syntax but expressions required
df.filter((pl.col("a") > 5) & (pl.col("b") < 10))
# Use & (and), | (or), ~ (not) — same as Pandas
```

### 6. groupby → group_by

```python
# Pandas: df.groupby("a")
# Polars: underscore
df.group_by("a")
```

### 7. sort is NOT stable by default in group_by

```python
# Polars group_by does not guarantee row order
# Use maintain_order=True if needed (slightly slower)
df.group_by("a", maintain_order=True).agg(...)
```

### 8. String Column Type Name

```python
# Pandas: "object" or "string"
# Polars: pl.String (formerly pl.Utf8)
df.cast({"name": pl.String})
```

### 9. Chained Indexing Doesn't Work

```python
# Pandas: df["a"]["b"] (chained) — works but warns
# Polars: use proper selection
df.select("a", "b")
```

### 10. head/tail Return DataFrames

```python
# Pandas: df.head() returns DataFrame
# Polars: same, but .head() on lazy returns LazyFrame until .collect()
lf.head(5)  # still lazy — need .collect()
```

---

## to_pandas and from_pandas Patterns

### Converting Polars → Pandas

```python
# Basic conversion
pandas_df = polars_df.to_pandas()

# With use_pyarrow_extension_types for zero-copy where possible
pandas_df = polars_df.to_pandas(use_pyarrow_extension_types=True)

# Convert specific columns only
pandas_series = polars_df["column"].to_pandas()
```

### Converting Pandas → Polars

```python
# Basic conversion
polars_df = pl.from_pandas(pandas_df)

# Handle Pandas MultiIndex — reset first
polars_df = pl.from_pandas(pandas_df.reset_index())

# From Pandas Series
polars_series = pl.from_pandas(pandas_series)
```

### Interop Patterns

```python
# Use Polars for heavy lifting, Pandas for ecosystem tools
def process_with_polars(pandas_df):
    """Process data in Polars, return Pandas for sklearn."""
    result = (
        pl.from_pandas(pandas_df)
        .lazy()
        .filter(pl.col("value") > 0)
        .with_columns(pl.col("feature").fill_null(strategy="mean"))
        .collect()
    )
    return result.to_pandas()

# With sklearn
from sklearn.model_selection import train_test_split
X = polars_df.select(feature_cols).to_pandas()
y = polars_df["target"].to_pandas()
X_train, X_test, y_train, y_test = train_test_split(X, y)

# With matplotlib/seaborn
import matplotlib.pyplot as plt
pandas_df = polars_df.select("x", "y").to_pandas()
pandas_df.plot.scatter(x="x", y="y")
```

### Arrow as Bridge (Zero-Copy)

```python
# Most efficient: use Arrow as intermediate
arrow_table = polars_df.to_arrow()
pandas_df = arrow_table.to_pandas()  # potentially zero-copy

# And back
arrow_table = pa.Table.from_pandas(pandas_df)
polars_df = pl.from_arrow(arrow_table)
```

---

## Missing Pandas Features and Workarounds

### Features Polars Doesn't Have

| Pandas Feature | Polars Workaround |
|----------------|-------------------|
| MultiIndex | Use regular columns; `group_by` multiple columns |
| `.plot()` built-in | Convert to Pandas: `df.to_pandas().plot()` or use hvplot |
| `df.style` | Convert to Pandas for styling |
| `pd.eval()` / `df.query()` | Use expression API or `pl.SQLContext` |
| `resample()` | Use `group_by_dynamic()` |
| `df.interpolate()` | `pl.col("x").interpolate()` (linear only; for others use `.to_pandas()`) |
| `pd.Categorical.ordered` | Use `pl.Enum` for ordered categories |
| `df.corrwith()` | Compute manually with expressions |
| `df.cov()` / `df.corr()` | Use `pl.corr()` expression or `numpy` |
| `.iloc` positional indexing | `df[row_idx]`, `df.row(idx)`, `df[start:end]` |
| `.loc` label indexing | `.filter()` + `.select()` |
| `pd.io.formats.style` | Use Pandas for display formatting |
| `pd.testing.assert_frame_equal` | `from polars.testing import assert_frame_equal` |

### Correlation Matrix Workaround

```python
# Pandas: df.corr()
# Polars:
numeric_cols = [c for c, t in zip(df.columns, df.dtypes) if t.is_numeric()]
corr_data = {}
for col in numeric_cols:
    corr_data[col] = [
        df.select(pl.corr(col, other)).item()
        for other in numeric_cols
    ]
corr_matrix = pl.DataFrame(corr_data)
```

---

## Performance Comparison

### When Polars Is Faster

| Scenario | Speedup | Why |
|----------|---------|-----|
| Large CSV reads | 3–10x | Multi-threaded parsing |
| GroupBy aggregations | 5–20x | Parallel, vectorized |
| Joins on large tables | 3–15x | Hash-based, multi-threaded |
| String operations | 3–10x | Arrow-native string processing |
| Filter + Select | 2–10x | Predicate/projection pushdown (lazy) |
| Parquet scans with filters | 10–100x | Row group skipping, column pruning |
| Memory usage | 2–5x less | Columnar layout, no object dtype overhead |
| Chained operations | 5–50x | Query plan optimization eliminates intermediate allocations |

### When Pandas Is Comparable

| Scenario | Notes |
|----------|-------|
| Tiny DataFrames (<1K rows) | Overhead of Polars setup dominates |
| Single-column numeric ops | NumPy backend is already fast |
| Display/formatting | Both are similar for head/tail |

### Benchmark Tips

```python
import time
import polars as pl
import pandas as pd

# Fair comparison: include data loading
# Polars shines most with lazy evaluation on large data

# Generate test data
n = 10_000_000
data = {
    "id": range(n),
    "group": [f"g{i % 1000}" for i in range(n)],
    "value": [float(i) for i in range(n)],
}

# Pandas
start = time.time()
pdf = pd.DataFrame(data)
result_pd = pdf.groupby("group")["value"].mean()
print(f"Pandas: {time.time() - start:.3f}s")

# Polars
start = time.time()
plf = pl.DataFrame(data)
result_pl = plf.group_by("group").agg(pl.col("value").mean())
print(f"Polars: {time.time() - start:.3f}s")
```

---

## When to Stay on Pandas vs Switch

### Stay on Pandas When

- **Ecosystem lock-in**: sklearn pipelines, statsmodels, and many ML libraries expect Pandas DataFrames
- **Tiny data**: For <10K rows, switching adds complexity with negligible speed gains
- **Heavy use of `.plot()`**: Pandas integrates tightly with matplotlib
- **MultiIndex is essential**: Hierarchical indexing has no direct Polars equivalent
- **Team familiarity**: Switching has a learning curve; weigh dev velocity
- **GeoPandas or domain extensions**: Many Pandas extensions don't have Polars equivalents
- **Jupyter display features**: Pandas has richer notebook display integration

### Switch to Polars When

- **Data >100K rows**: Polars starts showing significant speed advantages
- **Pipeline has chained operations**: Lazy evaluation eliminates intermediate copies
- **Memory constrained**: Polars uses 2–5x less memory for same data
- **Parquet/Arrow workflow**: Polars is native Arrow; no conversion overhead
- **Need parallel execution**: Polars auto-parallelizes; Pandas is single-threaded
- **ETL pipelines**: Lazy mode + streaming = efficient data pipelines
- **Data >RAM**: `scan_*` + streaming handles out-of-core data
- **Type safety matters**: Polars' type system catches errors Pandas silently coerces
- **Greenfield project**: No legacy Pandas code to maintain

### Incremental Migration Strategy

1. **Start with IO**: Replace `pd.read_csv` → `pl.scan_csv` for data loading
2. **Core transforms**: Move heavy group_by, join, filter operations to Polars
3. **Bridge at boundaries**: Use `to_pandas()` / `from_pandas()` where ecosystem requires
4. **Keep Pandas for display**: Notebooks, plotting, quick inspection
5. **Gradual replacement**: Don't rewrite everything at once; migrate hot paths first
