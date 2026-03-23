#!/usr/bin/env python3
"""
Production ETL Pipeline Template using Polars Lazy Evaluation.

This template demonstrates a structured ETL pipeline with:
  - Configurable source/target paths
  - Schema validation
  - Data quality checks
  - Lazy evaluation for efficiency
  - Error handling and logging
  - Streaming support for large datasets

Customize the extract(), transform(), and load() functions for your use case.

Usage:
    python etl-template.py --input data/raw/ --output data/processed/
    python etl-template.py --input s3://bucket/raw/ --output s3://bucket/processed/ --streaming
"""

import argparse
import logging
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

import polars as pl

# ──────────────────────────────────────────────────────────────────────
# Configuration
# ──────────────────────────────────────────────────────────────────────

@dataclass
class PipelineConfig:
    """Pipeline configuration."""
    input_path: str = "data/raw/"
    output_path: str = "data/processed/"
    streaming: bool = False
    compression: str = "zstd"
    log_level: str = "INFO"
    max_rows: Optional[int] = None
    storage_options: dict = field(default_factory=dict)


# Define expected schema for validation
EXPECTED_SCHEMA = {
    "id": pl.Int64,
    "timestamp": pl.Datetime,
    "category": pl.String,
    "value": pl.Float64,
    "status": pl.String,
}

# ──────────────────────────────────────────────────────────────────────
# Logging Setup
# ──────────────────────────────────────────────────────────────────────

def setup_logging(level: str = "INFO") -> logging.Logger:
    """Configure structured logging."""
    logger = logging.getLogger("etl_pipeline")
    logger.setLevel(getattr(logging, level.upper()))

    handler = logging.StreamHandler()
    handler.setFormatter(
        logging.Formatter("%(asctime)s [%(levelname)s] %(message)s", "%Y-%m-%d %H:%M:%S")
    )
    logger.addHandler(handler)
    return logger


# ──────────────────────────────────────────────────────────────────────
# Extract
# ──────────────────────────────────────────────────────────────────────

def extract(config: PipelineConfig, logger: logging.Logger) -> pl.LazyFrame:
    """
    Extract data from source.

    Reads Parquet files using lazy scan for optimal performance.
    Customize this function for your data source (CSV, database, API, etc.)
    """
    logger.info(f"Extracting from: {config.input_path}")

    scan_kwargs = {}
    if config.storage_options:
        scan_kwargs["storage_options"] = config.storage_options

    # Scan source data lazily
    lf = pl.scan_parquet(
        config.input_path + "**/*.parquet" if not config.input_path.endswith(".parquet") else config.input_path,
        **scan_kwargs,
    )

    if config.max_rows:
        lf = lf.head(config.max_rows)
        logger.info(f"Limited to {config.max_rows:,} rows")

    return lf


# ──────────────────────────────────────────────────────────────────────
# Validate
# ──────────────────────────────────────────────────────────────────────

def validate_schema(lf: pl.LazyFrame, logger: logging.Logger) -> pl.LazyFrame:
    """
    Validate and enforce schema.

    Checks that expected columns exist and casts to correct types.
    """
    schema = lf.schema

    # Check for required columns
    missing = [col for col in EXPECTED_SCHEMA if col not in schema]
    if missing:
        logger.warning(f"Missing columns (will be added as null): {missing}")
        for col in missing:
            lf = lf.with_columns(pl.lit(None).cast(EXPECTED_SCHEMA[col]).alias(col))

    # Cast columns to expected types
    cast_exprs = []
    for col, dtype in EXPECTED_SCHEMA.items():
        if col in schema and schema[col] != dtype:
            logger.info(f"Casting {col}: {schema[col]} → {dtype}")
            cast_exprs.append(pl.col(col).cast(dtype))

    if cast_exprs:
        lf = lf.with_columns(cast_exprs)

    return lf


def data_quality_checks(df: pl.DataFrame, logger: logging.Logger) -> dict:
    """
    Run data quality checks on the result.

    Returns a dict of check results. Customize checks for your domain.
    """
    checks = {}

    total_rows = len(df)
    checks["total_rows"] = total_rows

    # Null checks per column
    null_counts = df.null_count().row(0, named=True)
    for col, count in null_counts.items():
        pct = count / total_rows * 100 if total_rows > 0 else 0
        if pct > 0:
            level = "WARNING" if pct > 10 else "INFO"
            logger.log(
                getattr(logging, level),
                f"Column '{col}': {count:,} nulls ({pct:.1f}%)",
            )
        checks[f"null_{col}"] = count

    # Duplicate check on ID
    if "id" in df.columns:
        dupes = total_rows - df.n_unique(subset=["id"])
        if dupes > 0:
            logger.warning(f"Duplicate IDs: {dupes:,}")
        checks["duplicate_ids"] = dupes

    # Row count sanity
    if total_rows == 0:
        logger.error("No rows in output!")
        checks["empty_output"] = True

    return checks


# ──────────────────────────────────────────────────────────────────────
# Transform
# ──────────────────────────────────────────────────────────────────────

def transform(lf: pl.LazyFrame, logger: logging.Logger) -> pl.LazyFrame:
    """
    Apply business transformations.

    All transformations are lazy — nothing executes until collect/sink.
    Customize this function with your transformation logic.
    """
    logger.info("Applying transformations...")

    lf = (
        lf
        # ── Clean ────────────────────────────────────────────────
        .filter(pl.col("status") != "deleted")
        .with_columns(
            pl.col("category").str.to_lowercase().str.strip_chars(),
        )

        # ── Enrich ───────────────────────────────────────────────
        .with_columns(
            pl.col("timestamp").dt.year().alias("year"),
            pl.col("timestamp").dt.month().alias("month"),
            pl.col("timestamp").dt.weekday().alias("day_of_week"),
            pl.when(pl.col("value") > 0)
              .then(pl.lit("positive"))
              .when(pl.col("value") == 0)
              .then(pl.lit("zero"))
              .otherwise(pl.lit("negative"))
              .alias("value_sign"),
        )

        # ── Aggregate Features ───────────────────────────────────
        .with_columns(
            pl.col("value").mean().over("category").alias("category_avg"),
            pl.col("value").rank().over("category").alias("rank_in_category"),
            (pl.col("value") / pl.col("value").sum().over("category"))
              .alias("value_share"),
        )

        # ── Filter Outliers ──────────────────────────────────────
        .filter(
            pl.col("value").is_between(
                pl.col("value").quantile(0.01).over("category"),
                pl.col("value").quantile(0.99).over("category"),
            )
        )

        # ── Select Final Columns ─────────────────────────────────
        .select(
            "id",
            "timestamp",
            "year",
            "month",
            "category",
            "value",
            "value_sign",
            "category_avg",
            "rank_in_category",
            "value_share",
            "status",
        )
    )

    return lf


# ──────────────────────────────────────────────────────────────────────
# Load
# ──────────────────────────────────────────────────────────────────────

def load(
    lf: pl.LazyFrame,
    config: PipelineConfig,
    logger: logging.Logger,
) -> Optional[pl.DataFrame]:
    """
    Load transformed data to target.

    Uses streaming sink for large datasets, eager collect for smaller ones.
    """
    logger.info(f"Loading to: {config.output_path}")

    write_kwargs = {}
    if config.storage_options:
        write_kwargs["storage_options"] = config.storage_options

    if config.streaming:
        logger.info("Using streaming mode (sink)")
        lf.sink_parquet(
            config.output_path,
            compression=config.compression,
            **write_kwargs,
        )
        logger.info("Streaming write complete")
        return None
    else:
        logger.info("Collecting results...")
        df = lf.collect()
        logger.info(f"Collected {len(df):,} rows × {len(df.columns)} cols")

        df.write_parquet(
            config.output_path,
            compression=config.compression,
            statistics=True,
            **write_kwargs,
        )

        logger.info(f"Written {df.estimated_size() / 1024**2:.1f} MB")
        return df


# ──────────────────────────────────────────────────────────────────────
# Pipeline Orchestration
# ──────────────────────────────────────────────────────────────────────

def run_pipeline(config: PipelineConfig):
    """Execute the full ETL pipeline."""
    logger = setup_logging(config.log_level)

    logger.info("=" * 60)
    logger.info("ETL Pipeline Starting")
    logger.info("=" * 60)

    start = time.perf_counter()

    try:
        # Extract
        lf = extract(config, logger)

        # Validate
        lf = validate_schema(lf, logger)

        # Transform
        lf = transform(lf, logger)

        # Show optimized plan
        logger.info("Query plan:\n" + lf.explain())

        # Load
        result = load(lf, config, logger)

        # Quality checks (only if we have the result in memory)
        if result is not None:
            checks = data_quality_checks(result, logger)
            logger.info(f"Quality checks: {checks}")

        elapsed = time.perf_counter() - start
        logger.info(f"Pipeline completed in {elapsed:.2f}s")

    except Exception as e:
        elapsed = time.perf_counter() - start
        logger.error(f"Pipeline failed after {elapsed:.2f}s: {e}")
        raise


# ──────────────────────────────────────────────────────────────────────
# CLI
# ──────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Polars ETL Pipeline")
    parser.add_argument("--input", default="data/raw/", help="Input path")
    parser.add_argument("--output", default="data/processed/output.parquet", help="Output path")
    parser.add_argument("--streaming", action="store_true", help="Use streaming mode")
    parser.add_argument("--compression", default="zstd", help="Parquet compression")
    parser.add_argument("--max-rows", type=int, help="Limit rows for testing")
    parser.add_argument("--log-level", default="INFO", help="Log level")
    args = parser.parse_args()

    config = PipelineConfig(
        input_path=args.input,
        output_path=args.output,
        streaming=args.streaming,
        compression=args.compression,
        max_rows=args.max_rows,
        log_level=args.log_level,
    )

    run_pipeline(config)


if __name__ == "__main__":
    main()
