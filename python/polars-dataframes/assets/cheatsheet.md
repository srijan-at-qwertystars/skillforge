# Polars Cheatsheet

## Import

```python
import polars as pl
import polars.selectors as cs
```

## Create DataFrame

```python
df = pl.DataFrame({"a": [1, 2], "b": ["x", "y"]})      # from dict
df = pl.from_dicts([{"a": 1}, {"a": 2}])                 # from list of dicts
df = pl.from_pandas(pandas_df)                            # from Pandas
df = pl.from_arrow(arrow_table)                           # from Arrow
```

## Read / Scan

```python
df = pl.read_csv("f.csv")                                # eager CSV
lf = pl.scan_csv("f.csv")                                # lazy CSV
df = pl.read_parquet("f.parquet")                         # eager Parquet
lf = pl.scan_parquet("f.parquet")                         # lazy Parquet
lf = pl.scan_parquet("data/**/*.parquet")                 # glob
df = pl.read_ndjson("f.ndjson")                           # NDJSON
df = pl.read_database_uri(query, uri)                     # SQL database
```

## Write

```python
df.write_csv("out.csv")
df.write_parquet("out.parquet", compression="zstd")
df.write_ndjson("out.ndjson")
lf.sink_parquet("out.parquet")                            # streaming write
```

## Select & Transform

```python
df.select("a", "b")                                      # select columns
df.select(pl.col("a") * 2)                               # with transform
df.with_columns((pl.col("a") + 1).alias("a_plus"))       # add column
df.drop("col")                                            # drop column
df.rename({"old": "new"})                                 # rename
df.cast({"a": pl.Float64})                                # cast types
```

## Filter

```python
df.filter(pl.col("a") > 5)                               # simple filter
df.filter(pl.col("a").is_in([1, 2, 3]))                  # in list
df.filter(pl.col("a").is_between(1, 10))                  # range
df.filter(pl.col("a").is_not_null())                      # not null
df.filter((pl.col("a") > 5) & (pl.col("b") < 10))       # AND
df.filter((pl.col("a") > 5) | (pl.col("b") < 10))       # OR
```

## Sort & Deduplicate

```python
df.sort("a")                                              # ascending
df.sort("a", descending=True)                             # descending
df.sort("a", "b", descending=[True, False])               # multi-col
df.unique(subset=["a"])                                    # deduplicate
df.unique(subset=["a"], keep="last")                      # keep last
```

## Aggregate

```python
df.group_by("grp").agg(
    pl.col("val").mean().alias("avg"),
    pl.col("val").sum().alias("total"),
    pl.col("val").count().alias("n"),
    pl.col("val").min().alias("min"),
    pl.col("val").max().alias("max"),
    pl.col("val").std().alias("std"),
    pl.col("val").first().alias("first"),
    pl.col("val").last().alias("last"),
)
```

## Window Functions

```python
pl.col("val").mean().over("grp")                          # group mean
pl.col("val").rank().over("grp")                          # rank in group
pl.col("val").cum_sum().over("grp")                       # cumulative sum
pl.col("val").shift(1).over("grp")                        # lag
```

## Join

```python
df1.join(df2, on="id")                                    # inner (default)
df1.join(df2, on="id", how="left")                        # left
df1.join(df2, on="id", how="full")                        # full outer
df1.join(df2, on="id", how="semi")                        # semi (filter)
df1.join(df2, on="id", how="anti")                        # anti (exclude)
df1.join(df2, left_on="a", right_on="b")                  # diff col names
```

## Conditionals

```python
pl.when(pl.col("a") > 0).then("pos").otherwise("neg")    # if/else
pl.when(cond1).then(v1).when(cond2).then(v2).otherwise(v3)  # elif
```

## String Ops

```python
pl.col("s").str.to_lowercase()                            # lowercase
pl.col("s").str.to_uppercase()                            # uppercase
pl.col("s").str.strip_chars()                             # trim
pl.col("s").str.contains("pattern")                       # contains
pl.col("s").str.replace("old", "new")                     # replace
pl.col("s").str.split(" ")                                # split → list
pl.col("s").str.len_chars()                               # char length
pl.col("s").str.extract(r"(\d+)", 1)                      # regex extract
```

## DateTime Ops

```python
pl.col("dt").dt.year()                                    # year
pl.col("dt").dt.month()                                   # month
pl.col("dt").dt.day()                                     # day
pl.col("dt").dt.weekday()                                 # weekday (Mon=1)
pl.col("dt").dt.truncate("1h")                            # truncate
pl.col("s").str.to_datetime("%Y-%m-%d")                   # parse string
```

## List Ops

```python
pl.col("l").list.len()                                    # length
pl.col("l").list.mean()                                   # mean
pl.col("l").list.contains(val)                            # contains
pl.col("l").list.sort()                                   # sort
pl.col("l").list.unique()                                 # unique
pl.col("l").list.join(", ")                               # to string
df.explode("l")                                           # list → rows
```

## Struct Ops

```python
pl.struct(["a", "b"]).alias("s")                          # create struct
pl.col("s").struct.field("a")                             # access field
df.unnest("s")                                            # struct → cols
```

## Selectors

```python
cs.numeric()                                              # all numeric
cs.string()                                               # all string
cs.temporal()                                             # date/time cols
cs.starts_with("feat_")                                   # by prefix
cs.matches(r"col_\d+")                                   # by regex
cs.numeric() - cs.by_name("id")                           # set difference
```

## Null Handling

```python
df.fill_null(0)                                           # fill with value
df.fill_null(strategy="forward")                          # forward fill
pl.col("a").fill_null(pl.col("b"))                        # fill from col
pl.col("a").is_null()                                     # check null
pl.col("a").is_not_null()                                 # check not null
df.drop_nulls()                                           # drop null rows
df.drop_nulls(subset=["a", "b"])                          # subset
```

## Reshape

```python
df.pivot(on="col", index="id", values="val")              # long → wide
df.unpivot(on=["a", "b"], index="id")                     # wide → long
df.explode("list_col")                                    # explode list
df.transpose()                                            # transpose
pl.concat([df1, df2])                                     # vertical stack
pl.concat([df1, df2], how="horizontal")                   # horizontal
pl.concat([df1, df2], how="diagonal")                     # union (fill nulls)
```

## Lazy Execution

```python
lf = df.lazy()                                            # eager → lazy
result = lf.collect()                                     # execute
result = lf.collect(streaming=True)                       # streaming
print(lf.explain())                                       # show plan
lf.sink_parquet("out.parquet")                            # stream to file
```

## Conversion

```python
df.to_pandas()                                            # → Pandas
df.to_arrow()                                             # → Arrow table
df.to_numpy()                                             # → NumPy array
df.to_dicts()                                             # → list of dicts
df.write_csv()                                            # → CSV string
```

## SQL Interface

```python
ctx = pl.SQLContext(my_table=df)
result = ctx.execute("SELECT * FROM my_table WHERE a > 5").collect()
```
