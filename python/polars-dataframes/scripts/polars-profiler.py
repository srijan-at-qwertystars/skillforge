#!/usr/bin/env python3
"""
Polars LazyFrame Query Profiler.

Profiles a Polars LazyFrame query plan, showing:
  - Unoptimized query plan
  - Optimized query plan (with pushdowns)
  - Optimization differences
  - Execution time breakdown

Usage:
    # Import and use in your code:
    from polars_profiler import profile_query

    lf = (
        pl.scan_parquet("data.parquet")
        .filter(pl.col("x") > 100)
        .group_by("category")
        .agg(pl.col("value").sum())
    )
    profile_query(lf)

    # Or run standalone with the built-in demo:
    python polars-profiler.py
    python polars-profiler.py --demo          # run demo with synthetic data
    python polars-profiler.py --rows 5000000  # custom demo size

Requirements:
    pip install polars
"""

import argparse
import sys
import time
from typing import Optional


def profile_query(
    lf,
    name: str = "Query",
    collect: bool = True,
    show_plans: bool = True,
    show_timing: bool = True,
    streaming: bool = False,
):
    """
    Profile a Polars LazyFrame query.

    Args:
        lf: A Polars LazyFrame query to profile.
        name: Label for the query in output.
        collect: Whether to execute the query and measure time.
        show_plans: Whether to print unoptimized and optimized plans.
        show_timing: Whether to measure and print execution timing.
        streaming: Whether to use streaming execution.

    Returns:
        The collected DataFrame if collect=True, else None.
    """
    import polars as pl

    if not isinstance(lf, pl.LazyFrame):
        print(f"Error: Expected LazyFrame, got {type(lf).__name__}")
        return None

    sep = "=" * 70
    thin_sep = "-" * 70

    print(f"\n{sep}")
    print(f"  QUERY PROFILE: {name}")
    print(sep)

    if show_plans:
        # Unoptimized plan
        print(f"\n{'UNOPTIMIZED PLAN':^70}")
        print(thin_sep)
        try:
            unopt = lf.explain(optimized=False)
            print(unopt)
        except Exception as e:
            print(f"  Could not retrieve unoptimized plan: {e}")

        # Optimized plan
        print(f"\n{'OPTIMIZED PLAN':^70}")
        print(thin_sep)
        try:
            opt = lf.explain(optimized=True)
            print(opt)
        except Exception as e:
            print(f"  Could not retrieve optimized plan: {e}")

        # Detect optimizations
        print(f"\n{'DETECTED OPTIMIZATIONS':^70}")
        print(thin_sep)
        _detect_optimizations(lf)

    result = None
    if collect and show_timing:
        print(f"\n{'EXECUTION TIMING':^70}")
        print(thin_sep)

        # Warm-up: schema resolution
        _ = lf.schema

        # Timed execution
        start = time.perf_counter()
        try:
            if streaming:
                result = lf.collect(streaming=True)
                mode_label = "streaming"
            else:
                result = lf.collect()
                mode_label = "standard"
            elapsed = time.perf_counter() - start

            print(f"  Mode:          {mode_label}")
            print(f"  Execution:     {elapsed:.4f}s")
            print(f"  Result shape:  {result.shape[0]:,} rows × {result.shape[1]} cols")
            print(f"  Result schema: {dict(result.schema)}")

            # Estimate memory
            mem_bytes = result.estimated_size()
            if mem_bytes < 1024:
                mem_str = f"{mem_bytes} B"
            elif mem_bytes < 1024 ** 2:
                mem_str = f"{mem_bytes / 1024:.1f} KB"
            elif mem_bytes < 1024 ** 3:
                mem_str = f"{mem_bytes / 1024**2:.1f} MB"
            else:
                mem_str = f"{mem_bytes / 1024**3:.2f} GB"
            print(f"  Memory est:    {mem_str}")

        except Exception as e:
            elapsed = time.perf_counter() - start
            print(f"  FAILED after {elapsed:.4f}s: {e}")

    elif collect:
        result = lf.collect(streaming=streaming)

    print(f"\n{sep}\n")
    return result


def _detect_optimizations(lf):
    """Detect and report query optimizations applied by Polars."""
    try:
        unopt = lf.explain(optimized=False)
        opt = lf.explain(optimized=True)
    except Exception:
        print("  Could not analyze optimizations.")
        return

    optimizations_found = []

    # Predicate pushdown: FILTER appears closer to scan in optimized
    unopt_upper = unopt.upper()
    opt_upper = opt.upper()

    if "FILTER" in unopt_upper:
        # Check if filter moved (simplified heuristic)
        unopt_lines = unopt.strip().split("\n")
        opt_lines = opt.strip().split("\n")
        unopt_filter_pos = next(
            (i for i, l in enumerate(unopt_lines) if "FILTER" in l.upper()), -1
        )
        opt_filter_pos = next(
            (i for i, l in enumerate(opt_lines) if "FILTER" in l.upper()), -1
        )
        if opt_filter_pos > unopt_filter_pos and unopt_filter_pos >= 0:
            optimizations_found.append(
                "Predicate pushdown — filters moved closer to data source"
            )
        elif "SELECTION" in opt_upper and "FILTER" not in opt_upper:
            optimizations_found.append(
                "Predicate pushdown — filter integrated into scan"
            )

    # Projection pushdown: fewer columns in optimized scan
    if "PROJECT" in opt_upper or opt.count("/") < unopt.count("/"):
        optimizations_found.append(
            "Projection pushdown — only required columns are read"
        )

    # CSE
    if len(opt_lines) < len(unopt_lines):
        optimizations_found.append(
            "Plan simplification — optimized plan has fewer nodes"
        )

    # Slice pushdown
    if "SLICE" in unopt_upper and "SLICE" not in opt_upper.split("SCAN")[0] if "SCAN" in opt_upper else True:
        if "FETCH" in opt_upper or opt_upper.count("SLICE") < unopt_upper.count("SLICE"):
            optimizations_found.append("Slice pushdown — LIMIT pushed to scan")

    if optimizations_found:
        for opt_desc in optimizations_found:
            print(f"  ✓ {opt_desc}")
    else:
        print("  No obvious optimizations detected (plan may already be optimal)")


def _run_demo(n_rows: int):
    """Run a demo profiling session with synthetic data."""
    import polars as pl

    print(f"Generating demo data: {n_rows:,} rows...")

    # Create sample data
    import random
    random.seed(42)

    df = pl.DataFrame({
        "id": range(n_rows),
        "category": [f"cat_{i % 50}" for i in range(n_rows)],
        "region": [["US", "EU", "APAC", "LATAM"][i % 4] for i in range(n_rows)],
        "value": [random.gauss(100, 25) for _ in range(n_rows)],
        "cost": [random.gauss(50, 10) for _ in range(n_rows)],
        "active": [i % 7 != 0 for i in range(n_rows)],
    })

    # Save temporarily and scan for realistic demo
    import tempfile
    import os

    with tempfile.TemporaryDirectory() as tmpdir:
        path = os.path.join(tmpdir, "demo.parquet")
        df.write_parquet(path)

        # Query 1: Simple filter + select
        lf1 = (
            pl.scan_parquet(path)
            .filter(pl.col("active"))
            .filter(pl.col("value") > 100)
            .select("id", "category", "value")
        )
        profile_query(lf1, name="Filter + Select (Parquet)")

        # Query 2: GroupBy aggregation
        lf2 = (
            pl.scan_parquet(path)
            .filter(pl.col("active"))
            .group_by("category", "region")
            .agg(
                pl.col("value").mean().alias("avg_value"),
                pl.col("cost").sum().alias("total_cost"),
                pl.col("id").count().alias("count"),
            )
            .sort("avg_value", descending=True)
        )
        profile_query(lf2, name="GroupBy Aggregation")

        # Query 3: Window function
        lf3 = (
            pl.scan_parquet(path)
            .filter(pl.col("region") == "US")
            .with_columns(
                pl.col("value").mean().over("category").alias("cat_avg"),
                pl.col("value").rank().over("category").alias("rank_in_cat"),
            )
            .filter(pl.col("value") > pl.col("cat_avg"))
            .select("id", "category", "value", "cat_avg", "rank_in_cat")
            .head(100)
        )
        profile_query(lf3, name="Window Functions + Head")


def main():
    parser = argparse.ArgumentParser(description="Profile Polars LazyFrame queries")
    parser.add_argument(
        "--demo", action="store_true", help="Run demo with synthetic data"
    )
    parser.add_argument(
        "--rows", type=int, default=1_000_000, help="Demo row count (default: 1000000)"
    )
    args = parser.parse_args()

    try:
        import polars  # noqa: F401
    except ImportError:
        print("Polars is required: pip install polars")
        sys.exit(1)

    if args.demo or len(sys.argv) == 1:
        _run_demo(args.rows)
    else:
        print("Use --demo to run with synthetic data, or import profile_query in your code.")
        print("  from polars_profiler import profile_query")


if __name__ == "__main__":
    main()
