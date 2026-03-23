#!/usr/bin/env python3
"""
Benchmark: Polars vs Pandas on common DataFrame operations.

Generates synthetic data and compares execution time for:
  - GroupBy aggregation
  - Join (merge)
  - Filter
  - Sort
  - Column creation (with_columns / assign)

Usage:
    python benchmark-vs-pandas.py                  # default: 1M rows
    python benchmark-vs-pandas.py --rows 5000000   # custom row count
    python benchmark-vs-pandas.py --rows 10000000 --groups 10000

Requirements:
    pip install polars pandas
"""

import argparse
import time
import sys
from contextlib import contextmanager


@contextmanager
def timer(label: str, results: dict):
    """Context manager to time a block and store result."""
    start = time.perf_counter()
    yield
    elapsed = time.perf_counter() - start
    results[label] = elapsed


def generate_data(n_rows: int, n_groups: int):
    """Generate synthetic data as Python lists (framework-agnostic)."""
    import random
    random.seed(42)

    groups = [f"g{i % n_groups}" for i in range(n_rows)]
    categories = [f"cat{i % 20}" for i in range(n_rows)]
    values_a = [random.random() * 1000 for _ in range(n_rows)]
    values_b = [random.random() * 500 for _ in range(n_rows)]
    ids = list(range(n_rows))

    return {
        "id": ids,
        "group": groups,
        "category": categories,
        "value_a": values_a,
        "value_b": values_b,
    }


def run_pandas_benchmarks(data: dict, n_rows: int, n_groups: int) -> dict:
    """Run all benchmarks with Pandas."""
    import pandas as pd

    results = {}

    with timer("create_dataframe", results):
        df = pd.DataFrame(data)

    # Build a smaller DataFrame for joins
    join_data = {
        "group": [f"g{i}" for i in range(n_groups)],
        "group_label": [f"label_{i}" for i in range(n_groups)],
    }
    df_join = pd.DataFrame(join_data)

    with timer("groupby_agg", results):
        _ = df.groupby("group").agg(
            mean_a=("value_a", "mean"),
            sum_b=("value_b", "sum"),
            count=("id", "count"),
        )

    with timer("join", results):
        _ = pd.merge(df, df_join, on="group", how="left")

    with timer("filter", results):
        _ = df[(df["value_a"] > 500) & (df["category"].isin(["cat0", "cat1", "cat2"]))]

    with timer("sort", results):
        _ = df.sort_values(["group", "value_a"], ascending=[True, False])

    with timer("with_columns", results):
        _ = df.assign(
            total=df["value_a"] + df["value_b"],
            ratio=df["value_a"] / (df["value_b"] + 1),
        )

    return results


def run_polars_benchmarks(data: dict, n_rows: int, n_groups: int) -> dict:
    """Run all benchmarks with Polars."""
    import polars as pl

    results = {}

    with timer("create_dataframe", results):
        df = pl.DataFrame(data)

    join_data = {
        "group": [f"g{i}" for i in range(n_groups)],
        "group_label": [f"label_{i}" for i in range(n_groups)],
    }
    df_join = pl.DataFrame(join_data)

    with timer("groupby_agg", results):
        _ = df.group_by("group").agg(
            pl.col("value_a").mean().alias("mean_a"),
            pl.col("value_b").sum().alias("sum_b"),
            pl.col("id").count().alias("count"),
        )

    with timer("join", results):
        _ = df.join(df_join, on="group", how="left")

    with timer("filter", results):
        _ = df.filter(
            (pl.col("value_a") > 500)
            & pl.col("category").is_in(["cat0", "cat1", "cat2"])
        )

    with timer("sort", results):
        _ = df.sort("group", "value_a", descending=[False, True])

    with timer("with_columns", results):
        _ = df.with_columns(
            (pl.col("value_a") + pl.col("value_b")).alias("total"),
            (pl.col("value_a") / (pl.col("value_b") + 1)).alias("ratio"),
        )

    return results


def print_results(pandas_results: dict, polars_results: dict, n_rows: int):
    """Print a formatted comparison table."""
    ops = list(pandas_results.keys())
    col_w = 20
    num_w = 14

    header = (
        f"{'Operation':<{col_w}}"
        f"{'Pandas (s)':>{num_w}}"
        f"{'Polars (s)':>{num_w}}"
        f"{'Speedup':>{num_w}}"
    )
    sep = "-" * len(header)

    print(f"\n{'Benchmark Results':^{len(header)}}")
    print(f"{'(' + f'{n_rows:,} rows' + ')':^{len(header)}}")
    print(sep)
    print(header)
    print(sep)

    for op in ops:
        pd_time = pandas_results[op]
        pl_time = polars_results[op]
        speedup = pd_time / pl_time if pl_time > 0 else float("inf")
        marker = " ◀" if speedup > 1 else ""

        print(
            f"{op:<{col_w}}"
            f"{pd_time:>{num_w}.4f}"
            f"{pl_time:>{num_w}.4f}"
            f"{speedup:>{num_w - 2}.2f}x{marker}"
        )

    total_pd = sum(pandas_results.values())
    total_pl = sum(polars_results.values())
    total_speedup = total_pd / total_pl if total_pl > 0 else float("inf")

    print(sep)
    print(
        f"{'TOTAL':<{col_w}}"
        f"{total_pd:>{num_w}.4f}"
        f"{total_pl:>{num_w}.4f}"
        f"{total_speedup:>{num_w - 2}.2f}x"
    )
    print(sep)
    print("◀ = Polars is faster\n")


def main():
    parser = argparse.ArgumentParser(
        description="Benchmark Polars vs Pandas on common operations"
    )
    parser.add_argument(
        "--rows", type=int, default=1_000_000, help="Number of rows (default: 1000000)"
    )
    parser.add_argument(
        "--groups", type=int, default=1000, help="Number of groups (default: 1000)"
    )
    args = parser.parse_args()

    try:
        import pandas  # noqa: F401
        import polars  # noqa: F401
    except ImportError as e:
        print(f"Missing dependency: {e}")
        print("Install with: pip install polars pandas")
        sys.exit(1)

    print(f"Generating {args.rows:,} rows with {args.groups:,} groups...")
    data = generate_data(args.rows, args.groups)

    print("Running Pandas benchmarks...")
    pandas_results = run_pandas_benchmarks(data, args.rows, args.groups)

    print("Running Polars benchmarks...")
    polars_results = run_polars_benchmarks(data, args.rows, args.groups)

    print_results(pandas_results, polars_results, args.rows)


if __name__ == "__main__":
    main()
