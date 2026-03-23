"""
DuckDB ETL Pipeline Template
=============================
A complete extract-transform-load pipeline using DuckDB.
Reads from multiple sources (CSV, JSON, Parquet, databases),
applies transformations, and writes optimized Parquet output.

Usage:
    python etl-pipeline.py --config config.yaml
    python etl-pipeline.py --sources data/*.csv --output warehouse/

Requires: pip install duckdb pyarrow
"""

import duckdb
import argparse
import logging
import time
import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger(__name__)


@dataclass
class ETLConfig:
    """Pipeline configuration."""
    sources: list[str] = field(default_factory=list)
    output_dir: str = "output"
    output_format: str = "parquet"
    compression: str = "zstd"
    partition_by: list[str] = field(default_factory=list)
    memory_limit: str = "4GB"
    threads: int = 0  # 0 = auto
    temp_directory: str = "/tmp/duckdb_etl"


class DuckDBETLPipeline:
    """Configurable ETL pipeline powered by DuckDB."""

    def __init__(self, config: ETLConfig):
        self.config = config
        self.con = duckdb.connect()
        self._configure()

    def _configure(self):
        """Apply DuckDB settings for ETL workloads."""
        self.con.execute(f"SET memory_limit = '{self.config.memory_limit}'")
        self.con.execute(f"SET temp_directory = '{self.config.temp_directory}'")
        if self.config.threads > 0:
            self.con.execute(f"SET threads = {self.config.threads}")
        self.con.execute("SET preserve_insertion_order = false")
        log.info(
            "DuckDB configured: memory=%s, threads=%s",
            self.config.memory_limit,
            self.config.threads or "auto",
        )

    # ── Extract ──────────────────────────────────────────

    def extract(self, sources: Optional[list[str]] = None) -> str:
        """Read from multiple sources into a staging table."""
        sources = sources or self.config.sources
        if not sources:
            raise ValueError("No sources provided")

        log.info("Extracting from %d source(s)...", len(sources))
        start = time.time()

        parts = []
        for i, source in enumerate(sources):
            read_fn = self._detect_reader(source)
            view_name = f"_src_{i}"
            self.con.execute(f"CREATE OR REPLACE VIEW {view_name} AS SELECT * FROM {read_fn}")
            parts.append(f"SELECT * FROM {view_name}")
            log.info("  Source %d: %s", i + 1, source)

        union_query = " UNION ALL BY NAME ".join(parts)
        self.con.execute(f"CREATE OR REPLACE TABLE staging AS {union_query}")

        row_count = self.con.execute("SELECT count(*) FROM staging").fetchone()[0]
        elapsed = time.time() - start
        log.info("Extracted %d rows in %.2fs", row_count, elapsed)
        return "staging"

    def _detect_reader(self, source: str) -> str:
        """Auto-detect the right DuckDB reader for a source path."""
        lower = source.lower()
        if lower.endswith((".parquet", ".pq")):
            return f"read_parquet('{source}')"
        elif lower.endswith((".csv", ".tsv")):
            return f"read_csv_auto('{source}')"
        elif lower.endswith((".json", ".jsonl", ".ndjson")):
            return f"read_json_auto('{source}')"
        elif lower.startswith(("s3://", "gs://", "https://", "http://")):
            if "parquet" in lower:
                return f"read_parquet('{source}')"
            elif "csv" in lower:
                return f"read_csv_auto('{source}')"
            else:
                return f"read_parquet('{source}')"
        else:
            return f"read_csv_auto('{source}')"

    # ── Transform ────────────────────────────────────────

    def transform(self, transformations: Optional[list[str]] = None) -> str:
        """Apply SQL transformations to staged data.

        Args:
            transformations: List of SQL statements to execute in order.
                             Each can be a CREATE TABLE AS SELECT, ALTER TABLE, etc.
        """
        if not transformations:
            transformations = self._default_transforms()

        log.info("Applying %d transformation(s)...", len(transformations))
        start = time.time()

        for i, sql in enumerate(transformations, 1):
            log.info("  Transform %d: %s...", i, sql[:80])
            self.con.execute(sql)

        elapsed = time.time() - start
        log.info("Transforms complete in %.2fs", elapsed)
        return "transformed"

    def _default_transforms(self) -> list[str]:
        """Example transformations — customize for your use case."""
        return [
            # Deduplicate
            """CREATE OR REPLACE TABLE deduped AS
               SELECT DISTINCT * FROM staging""",

            # Add computed columns
            """CREATE OR REPLACE TABLE transformed AS
               SELECT *,
                      current_timestamp AS _etl_loaded_at,
                      md5(CAST(COLUMNS(*) AS VARCHAR)) AS _row_hash
               FROM deduped""",
        ]

    # ── Load ─────────────────────────────────────────────

    def load(self, table_name: str = "transformed", output_dir: Optional[str] = None):
        """Write results to Parquet (or other format)."""
        output_dir = output_dir or self.config.output_dir
        os.makedirs(output_dir, exist_ok=True)

        log.info("Loading to %s (format=%s, compression=%s)...",
                 output_dir, self.config.output_format, self.config.compression)
        start = time.time()

        row_count = self.con.execute(f"SELECT count(*) FROM {table_name}").fetchone()[0]

        if self.config.partition_by:
            partition_clause = ", ".join(self.config.partition_by)
            self.con.execute(f"""
                COPY {table_name}
                TO '{output_dir}'
                (FORMAT {self.config.output_format},
                 COMPRESSION {self.config.compression},
                 PARTITION_BY ({partition_clause}))
            """)
        else:
            output_file = os.path.join(output_dir, f"{table_name}.parquet")
            self.con.execute(f"""
                COPY {table_name}
                TO '{output_file}'
                (FORMAT {self.config.output_format},
                 COMPRESSION {self.config.compression})
            """)

        elapsed = time.time() - start
        log.info("Loaded %d rows in %.2fs → %s", row_count, elapsed, output_dir)

    # ── Run Full Pipeline ────────────────────────────────

    def run(self, transformations: Optional[list[str]] = None):
        """Execute the complete ETL pipeline."""
        log.info("=" * 60)
        log.info("Starting ETL pipeline")
        log.info("=" * 60)
        pipeline_start = time.time()

        self.extract()
        self.transform(transformations)
        self.load()

        elapsed = time.time() - pipeline_start
        log.info("=" * 60)
        log.info("Pipeline complete in %.2fs", elapsed)
        log.info("=" * 60)

    def close(self):
        self.con.close()


# ── Example Usage ────────────────────────────────────────

def example_sales_pipeline():
    """Example: Multi-source sales data ETL."""
    config = ETLConfig(
        sources=[
            "data/sales_2023.csv",
            "data/sales_2024.csv",
            "data/returns.parquet",
        ],
        output_dir="warehouse/sales",
        compression="zstd",
        partition_by=["year", "month"],
        memory_limit="8GB",
    )

    pipeline = DuckDBETLPipeline(config)

    transforms = [
        # Clean and normalize
        """CREATE OR REPLACE TABLE cleaned AS
           SELECT
               CAST(order_id AS BIGINT) AS order_id,
               TRIM(LOWER(customer_email)) AS customer_email,
               product_id,
               TRY_CAST(quantity AS INTEGER) AS quantity,
               TRY_CAST(unit_price AS DOUBLE) AS unit_price,
               strptime(order_date, '%Y-%m-%d')::DATE AS order_date
           FROM staging
           WHERE TRY_CAST(order_id AS BIGINT) IS NOT NULL""",

        # Enrich with computed fields
        """CREATE OR REPLACE TABLE transformed AS
           SELECT *,
               quantity * unit_price AS total_amount,
               EXTRACT(YEAR FROM order_date) AS year,
               EXTRACT(MONTH FROM order_date) AS month,
               CASE
                   WHEN quantity * unit_price > 1000 THEN 'high'
                   WHEN quantity * unit_price > 100 THEN 'medium'
                   ELSE 'low'
               END AS order_tier,
               current_timestamp AS _etl_loaded_at
           FROM cleaned""",
    ]

    try:
        pipeline.run(transforms)
    finally:
        pipeline.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="DuckDB ETL Pipeline")
    parser.add_argument("--sources", nargs="+", help="Input file paths")
    parser.add_argument("--output", default="output", help="Output directory")
    parser.add_argument("--compression", default="zstd", choices=["zstd", "snappy", "gzip", "none"])
    parser.add_argument("--partition-by", nargs="*", help="Partition columns")
    parser.add_argument("--memory", default="4GB", help="Memory limit")
    parser.add_argument("--threads", type=int, default=0, help="Thread count (0=auto)")
    parser.add_argument("--example", action="store_true", help="Run example pipeline")
    args = parser.parse_args()

    if args.example:
        example_sales_pipeline()
    elif args.sources:
        config = ETLConfig(
            sources=args.sources,
            output_dir=args.output,
            compression=args.compression,
            partition_by=args.partition_by or [],
            memory_limit=args.memory,
            threads=args.threads,
        )
        pipeline = DuckDBETLPipeline(config)
        try:
            pipeline.run()
        finally:
            pipeline.close()
    else:
        parser.print_help()
