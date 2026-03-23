#!/usr/bin/env python3
"""
CSV to Parquet Converter — Convert CSV files to optimized Parquet format.

Features:
  - Configurable compression (zstd, snappy, gzip, lz4, none)
  - Row group size tuning
  - Hive-style partitioning by column
  - Schema override via JSON
  - Streaming mode for large files
  - Glob pattern support for multiple files

Usage:
    # Basic conversion
    python csv-to-parquet.py input.csv output.parquet

    # With compression options
    python csv-to-parquet.py input.csv output.parquet --compression zstd --compression-level 6

    # Partition output by a column
    python csv-to-parquet.py input.csv output_dir/ --partition-by year,month

    # Convert all CSVs in a directory
    python csv-to-parquet.py "data/*.csv" output.parquet

    # Streaming mode for very large files
    python csv-to-parquet.py huge.csv output.parquet --streaming

    # Override column types
    python csv-to-parquet.py input.csv output.parquet --dtypes '{"id": "Int64", "amount": "Float64"}'

    # Custom CSV settings
    python csv-to-parquet.py input.tsv output.parquet --separator $'\\t' --no-header

Requirements:
    pip install polars
"""

import argparse
import json
import os
import sys
import time


DTYPE_MAP = {
    "Int8": "Int8",
    "Int16": "Int16",
    "Int32": "Int32",
    "Int64": "Int64",
    "UInt8": "UInt8",
    "UInt16": "UInt16",
    "UInt32": "UInt32",
    "UInt64": "UInt64",
    "Float32": "Float32",
    "Float64": "Float64",
    "String": "String",
    "Utf8": "String",
    "Boolean": "Boolean",
    "Date": "Date",
    "Datetime": "Datetime",
}


def parse_dtypes(dtypes_str: str) -> dict:
    """Parse a JSON string of column name → type mappings."""
    import polars as pl

    raw = json.loads(dtypes_str)
    result = {}
    for col, dtype_name in raw.items():
        if dtype_name in DTYPE_MAP:
            result[col] = getattr(pl, DTYPE_MAP[dtype_name])
        else:
            print(f"Warning: Unknown dtype '{dtype_name}' for column '{col}', skipping")
    return result


def convert(args):
    """Run the CSV → Parquet conversion."""
    import polars as pl

    start = time.perf_counter()

    # Build read options
    csv_kwargs = {
        "has_header": not args.no_header,
        "separator": args.separator,
        "try_parse_dates": args.parse_dates,
        "infer_schema_length": args.infer_schema_length,
        "ignore_errors": args.ignore_errors,
    }

    if args.null_values:
        csv_kwargs["null_values"] = args.null_values.split(",")

    if args.dtypes:
        csv_kwargs["dtypes"] = parse_dtypes(args.dtypes)

    # Parquet write options
    compression = args.compression if args.compression != "none" else "uncompressed"

    if args.streaming:
        # Streaming: scan → sink (never materializes full dataset)
        print(f"Scanning: {args.input}")
        lf = pl.scan_csv(args.input, **csv_kwargs)

        if args.columns:
            lf = lf.select(args.columns.split(","))

        if args.partition_by:
            print("Warning: --partition-by is not supported with --streaming. Ignoring.")

        print(f"Streaming to: {args.output}")
        lf.sink_parquet(
            args.output,
            compression=compression,
            compression_level=args.compression_level,
        )
    else:
        # Eager: read → write
        print(f"Reading: {args.input}")
        df = pl.read_csv(args.input, **csv_kwargs)

        if args.columns:
            df = df.select(args.columns.split(","))

        if args.partition_by:
            partition_cols = [c.strip() for c in args.partition_by.split(",")]
            print(f"Partitioning by: {partition_cols}")

            os.makedirs(args.output, exist_ok=True)

            # Group and write partitioned files
            groups = df.partition_by(partition_cols, as_dict=True)
            for key, group_df in groups.items():
                # Build partition path
                if isinstance(key, tuple):
                    parts = [
                        f"{col}={val}" for col, val in zip(partition_cols, key)
                    ]
                else:
                    parts = [f"{partition_cols[0]}={key}"]
                part_dir = os.path.join(args.output, *parts)
                os.makedirs(part_dir, exist_ok=True)

                part_path = os.path.join(part_dir, "data.parquet")
                group_df.drop(partition_cols).write_parquet(
                    part_path,
                    compression=compression,
                    compression_level=args.compression_level,
                    statistics=True,
                    row_group_size=args.row_group_size,
                )
            print(f"Wrote {len(groups)} partition(s) to: {args.output}")
        else:
            print(f"Writing: {args.output}")
            df.write_parquet(
                args.output,
                compression=compression,
                compression_level=args.compression_level,
                statistics=True,
                row_group_size=args.row_group_size,
            )

    elapsed = time.perf_counter() - start

    # Report
    input_size = _file_size(args.input)
    output_size = _file_size(args.output)

    print(f"\nConversion complete in {elapsed:.2f}s")
    if input_size:
        print(f"  Input:       {_format_size(input_size)}")
    if output_size:
        ratio = output_size / input_size if input_size else 0
        print(f"  Output:      {_format_size(output_size)} ({ratio:.1%} of original)")
    print(f"  Compression: {compression}")


def _file_size(path: str) -> int:
    """Get file size, handling directories and globs."""
    if os.path.isfile(path):
        return os.path.getsize(path)
    elif os.path.isdir(path):
        total = 0
        for root, _, files in os.walk(path):
            for f in files:
                total += os.path.getsize(os.path.join(root, f))
        return total
    return 0


def _format_size(size_bytes: int) -> str:
    """Format bytes as human-readable string."""
    for unit in ["B", "KB", "MB", "GB", "TB"]:
        if size_bytes < 1024:
            return f"{size_bytes:.1f} {unit}"
        size_bytes /= 1024
    return f"{size_bytes:.1f} PB"


def main():
    parser = argparse.ArgumentParser(
        description="Convert CSV files to optimized Parquet format",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("input", help="Input CSV path (supports glob patterns)")
    parser.add_argument("output", help="Output Parquet path (file or directory)")

    # Compression
    parser.add_argument(
        "--compression",
        choices=["zstd", "snappy", "gzip", "lz4", "none"],
        default="zstd",
        help="Compression codec (default: zstd)",
    )
    parser.add_argument(
        "--compression-level",
        type=int,
        default=3,
        help="Compression level for zstd (1-22, default: 3)",
    )

    # Parquet options
    parser.add_argument(
        "--row-group-size",
        type=int,
        default=512 * 1024,
        help="Rows per row group (default: 524288)",
    )
    parser.add_argument(
        "--partition-by",
        help="Comma-separated columns to partition by (Hive-style)",
    )

    # CSV options
    parser.add_argument("--separator", default=",", help="CSV separator (default: ,)")
    parser.add_argument(
        "--no-header", action="store_true", help="CSV has no header row"
    )
    parser.add_argument(
        "--parse-dates", action="store_true", help="Auto-detect date columns"
    )
    parser.add_argument(
        "--null-values", help="Comma-separated null value strings (e.g. 'NA,null,')"
    )
    parser.add_argument(
        "--ignore-errors", action="store_true", help="Skip malformed rows"
    )
    parser.add_argument(
        "--infer-schema-length",
        type=int,
        default=10000,
        help="Rows to scan for type inference (default: 10000)",
    )
    parser.add_argument(
        "--dtypes",
        help='Column type overrides as JSON: \'{"col": "Int64", "col2": "Float64"}\'',
    )
    parser.add_argument(
        "--columns", help="Comma-separated columns to include in output"
    )

    # Execution mode
    parser.add_argument(
        "--streaming",
        action="store_true",
        help="Use streaming mode for large files (no full materialization)",
    )

    args = parser.parse_args()

    try:
        import polars  # noqa: F401
    except ImportError:
        print("Polars is required: pip install polars")
        sys.exit(1)

    convert(args)


if __name__ == "__main__":
    main()
