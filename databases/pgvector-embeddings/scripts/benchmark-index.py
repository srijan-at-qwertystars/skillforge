#!/usr/bin/env python3
"""
benchmark-index.py — Benchmark recall@k and query latency for pgvector indexes.

Compares IVFFlat vs HNSW with various parameter configurations on your actual data.

Usage:
    python benchmark-index.py --db "postgresql://user:pass@localhost/mydb" --table items --column embedding
    python benchmark-index.py --db "postgresql://user:pass@localhost/mydb" --table items --column embedding --dims 1536 --k 10 --queries 100
    python benchmark-index.py --help

Prerequisites:
    pip install psycopg[binary] numpy tabulate

What this script does:
    1. Samples random query vectors from your table
    2. Computes exact (brute-force) nearest neighbors as ground truth
    3. Creates HNSW and IVFFlat indexes with various parameter configs
    4. Benchmarks recall@k and p50/p99 latency for each config
    5. Prints a comparison table and optionally exports CSV

Environment:
    DATABASE_URL — Connection string (alternative to --db flag)
"""

import argparse
import json
import os
import sys
import time
from dataclasses import dataclass

try:
    import psycopg
    from psycopg.rows import dict_row
except ImportError:
    print("ERROR: psycopg not installed. Run: pip install 'psycopg[binary]'")
    sys.exit(1)

try:
    import numpy as np
except ImportError:
    print("ERROR: numpy not installed. Run: pip install numpy")
    sys.exit(1)


@dataclass
class BenchmarkResult:
    index_type: str
    params: dict
    search_params: dict
    recall_at_k: float
    latency_p50_ms: float
    latency_p99_ms: float
    index_size_mb: float
    build_time_s: float


def parse_args():
    parser = argparse.ArgumentParser(description="Benchmark pgvector index configurations")
    parser.add_argument("--db", type=str, default=os.environ.get("DATABASE_URL"),
                        help="PostgreSQL connection string")
    parser.add_argument("--table", type=str, required=True,
                        help="Table name containing vectors")
    parser.add_argument("--column", type=str, default="embedding",
                        help="Vector column name (default: embedding)")
    parser.add_argument("--dims", type=int, default=None,
                        help="Vector dimensions (auto-detected if not specified)")
    parser.add_argument("--k", type=int, default=10,
                        help="Number of nearest neighbors (default: 10)")
    parser.add_argument("--queries", type=int, default=50,
                        help="Number of test queries (default: 50)")
    parser.add_argument("--distance", type=str, default="cosine",
                        choices=["cosine", "l2", "ip"],
                        help="Distance function (default: cosine)")
    parser.add_argument("--csv", type=str, default=None,
                        help="Export results to CSV file")
    parser.add_argument("--skip-ivfflat", action="store_true",
                        help="Skip IVFFlat benchmarks")
    parser.add_argument("--skip-hnsw", action="store_true",
                        help="Skip HNSW benchmarks")
    return parser.parse_args()


DISTANCE_OPS = {
    "cosine": {"operator": "<=>", "ops_class": "vector_cosine_ops"},
    "l2": {"operator": "<->", "ops_class": "vector_l2_ops"},
    "ip": {"operator": "<#>", "ops_class": "vector_ip_ops"},
}

HNSW_CONFIGS = [
    {"m": 16, "ef_construction": 64, "ef_search_values": [40, 100, 200]},
    {"m": 16, "ef_construction": 128, "ef_search_values": [40, 100, 200]},
    {"m": 32, "ef_construction": 128, "ef_search_values": [100, 200, 400]},
]

IVFFLAT_CONFIGS_BY_SIZE = {
    "small": [  # < 100K rows
        {"lists": 50, "probes_values": [1, 5, 10]},
        {"lists": 100, "probes_values": [1, 5, 10, 20]},
    ],
    "medium": [  # 100K – 1M rows
        {"lists": 200, "probes_values": [1, 10, 20]},
        {"lists": 500, "probes_values": [1, 10, 20, 50]},
        {"lists": 1000, "probes_values": [5, 10, 20, 50]},
    ],
    "large": [  # > 1M rows
        {"lists": 1000, "probes_values": [10, 20, 50]},
        {"lists": 3000, "probes_values": [10, 30, 50, 100]},
        {"lists": 5000, "probes_values": [10, 50, 100]},
    ],
}


def get_row_count(conn, table: str) -> int:
    return conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]


def get_dimensions(conn, table: str, column: str) -> int:
    row = conn.execute(
        f"SELECT vector_dims({column}) FROM {table} WHERE {column} IS NOT NULL LIMIT 1"
    ).fetchone()
    if row is None:
        raise RuntimeError(f"No rows with non-NULL {column} found in {table}")
    return row[0]


def sample_query_vectors(conn, table: str, column: str, n: int) -> list:
    """Sample n random vectors from the table to use as queries."""
    rows = conn.execute(
        f"SELECT {column}::text FROM {table} WHERE {column} IS NOT NULL "
        f"ORDER BY RANDOM() LIMIT %s", (n,)
    ).fetchall()
    vectors = []
    for row in rows:
        vec_str = row[0].strip("[]")
        vectors.append([float(x) for x in vec_str.split(",")])
    return vectors


def compute_ground_truth(conn, table: str, column: str, query_vectors: list,
                         k: int, operator: str) -> list[list[int]]:
    """Compute exact nearest neighbors (brute force) for each query vector."""
    print(f"  Computing ground truth (brute force) for {len(query_vectors)} queries...")
    conn.execute("SET enable_indexscan = off")
    conn.execute("SET enable_bitmapscan = off")

    ground_truth = []
    for i, qv in enumerate(query_vectors):
        vec_literal = "[" + ",".join(str(x) for x in qv) + "]"
        rows = conn.execute(
            f"SELECT id FROM {table} "
            f"ORDER BY {column} {operator} %s::vector LIMIT %s",
            (vec_literal, k)
        ).fetchall()
        ground_truth.append([r[0] for r in rows])
        if (i + 1) % 10 == 0:
            print(f"    {i + 1}/{len(query_vectors)} queries done")

    conn.execute("RESET enable_indexscan")
    conn.execute("RESET enable_bitmapscan")
    return ground_truth


def compute_recall(result_ids: list[int], truth_ids: list[int]) -> float:
    return len(set(result_ids) & set(truth_ids)) / len(truth_ids)


def benchmark_queries(conn, table: str, column: str, query_vectors: list,
                      ground_truth: list, k: int, operator: str) -> tuple[float, float, float]:
    """Run queries and measure recall and latency."""
    latencies = []
    recalls = []

    for qv, truth in zip(query_vectors, ground_truth):
        vec_literal = "[" + ",".join(str(x) for x in qv) + "]"

        start = time.perf_counter()
        rows = conn.execute(
            f"SELECT id FROM {table} "
            f"ORDER BY {column} {operator} %s::vector LIMIT %s",
            (vec_literal, k)
        ).fetchall()
        elapsed = (time.perf_counter() - start) * 1000  # ms

        result_ids = [r[0] for r in rows]
        recalls.append(compute_recall(result_ids, truth))
        latencies.append(elapsed)

    latencies_arr = np.array(latencies)
    return (
        float(np.mean(recalls)),
        float(np.percentile(latencies_arr, 50)),
        float(np.percentile(latencies_arr, 99)),
    )


def get_index_size_mb(conn, index_name: str) -> float:
    row = conn.execute(
        "SELECT pg_relation_size(%s) / (1024.0 * 1024.0)", (index_name,)
    ).fetchone()
    return row[0] if row else 0.0


def drop_benchmark_indexes(conn, table: str):
    """Drop any benchmark indexes we created."""
    rows = conn.execute(
        "SELECT indexname FROM pg_indexes WHERE tablename = %s AND indexname LIKE 'bench_idx_%%'",
        (table,)
    ).fetchall()
    for row in rows:
        conn.execute(f"DROP INDEX IF EXISTS {row[0]}")
    conn.commit()


def benchmark_hnsw(conn, table: str, column: str, query_vectors: list,
                   ground_truth: list, k: int, dist_config: dict) -> list[BenchmarkResult]:
    results = []
    operator = dist_config["operator"]
    ops_class = dist_config["ops_class"]

    for config in HNSW_CONFIGS:
        m = config["m"]
        ef_construction = config["ef_construction"]
        idx_name = f"bench_idx_hnsw_m{m}_ef{ef_construction}"

        print(f"\n  Building HNSW index: m={m}, ef_construction={ef_construction}...")
        drop_benchmark_indexes(conn, table)

        start = time.perf_counter()
        conn.execute(
            f"CREATE INDEX {idx_name} ON {table} USING hnsw ({column} {ops_class}) "
            f"WITH (m = {m}, ef_construction = {ef_construction})"
        )
        conn.commit()
        build_time = time.perf_counter() - start
        index_size = get_index_size_mb(conn, idx_name)

        print(f"    Built in {build_time:.1f}s, size: {index_size:.1f} MB")

        for ef_search in config["ef_search_values"]:
            conn.execute(f"SET hnsw.ef_search = {ef_search}")
            recall, p50, p99 = benchmark_queries(
                conn, table, column, query_vectors, ground_truth, k, operator
            )
            print(f"    ef_search={ef_search}: recall@{k}={recall:.4f}, p50={p50:.1f}ms, p99={p99:.1f}ms")

            results.append(BenchmarkResult(
                index_type="HNSW",
                params={"m": m, "ef_construction": ef_construction},
                search_params={"ef_search": ef_search},
                recall_at_k=recall,
                latency_p50_ms=p50,
                latency_p99_ms=p99,
                index_size_mb=index_size,
                build_time_s=build_time,
            ))

        conn.execute("RESET hnsw.ef_search")

    drop_benchmark_indexes(conn, table)
    return results


def benchmark_ivfflat(conn, table: str, column: str, query_vectors: list,
                      ground_truth: list, k: int, dist_config: dict,
                      row_count: int) -> list[BenchmarkResult]:
    results = []
    operator = dist_config["operator"]
    ops_class = dist_config["ops_class"]

    if row_count < 100_000:
        configs = IVFFLAT_CONFIGS_BY_SIZE["small"]
    elif row_count < 1_000_000:
        configs = IVFFLAT_CONFIGS_BY_SIZE["medium"]
    else:
        configs = IVFFLAT_CONFIGS_BY_SIZE["large"]

    for config in configs:
        lists = config["lists"]
        if lists > row_count // 10:
            print(f"\n  Skipping IVFFlat lists={lists} (too many for {row_count} rows)")
            continue

        idx_name = f"bench_idx_ivfflat_l{lists}"
        print(f"\n  Building IVFFlat index: lists={lists}...")
        drop_benchmark_indexes(conn, table)

        start = time.perf_counter()
        conn.execute(
            f"CREATE INDEX {idx_name} ON {table} USING ivfflat ({column} {ops_class}) "
            f"WITH (lists = {lists})"
        )
        conn.commit()
        build_time = time.perf_counter() - start
        index_size = get_index_size_mb(conn, idx_name)

        print(f"    Built in {build_time:.1f}s, size: {index_size:.1f} MB")

        for probes in config["probes_values"]:
            conn.execute(f"SET ivfflat.probes = {probes}")
            recall, p50, p99 = benchmark_queries(
                conn, table, column, query_vectors, ground_truth, k, operator
            )
            print(f"    probes={probes}: recall@{k}={recall:.4f}, p50={p50:.1f}ms, p99={p99:.1f}ms")

            results.append(BenchmarkResult(
                index_type="IVFFlat",
                params={"lists": lists},
                search_params={"probes": probes},
                recall_at_k=recall,
                latency_p50_ms=p50,
                latency_p99_ms=p99,
                index_size_mb=index_size,
                build_time_s=build_time,
            ))

        conn.execute("RESET ivfflat.probes")

    drop_benchmark_indexes(conn, table)
    return results


def print_results(results: list[BenchmarkResult], k: int):
    try:
        from tabulate import tabulate
    except ImportError:
        tabulate = None

    headers = ["Index", "Build Params", "Search Params", f"Recall@{k}",
               "p50 (ms)", "p99 (ms)", "Size (MB)", "Build (s)"]
    rows = []
    for r in sorted(results, key=lambda x: (-x.recall_at_k, x.latency_p50_ms)):
        rows.append([
            r.index_type,
            json.dumps(r.params),
            json.dumps(r.search_params),
            f"{r.recall_at_k:.4f}",
            f"{r.latency_p50_ms:.1f}",
            f"{r.latency_p99_ms:.1f}",
            f"{r.index_size_mb:.1f}",
            f"{r.build_time_s:.1f}",
        ])

    print("\n" + "=" * 100)
    print("BENCHMARK RESULTS")
    print("=" * 100)

    if tabulate:
        print(tabulate(rows, headers=headers, tablefmt="grid"))
    else:
        print("\t".join(headers))
        for row in rows:
            print("\t".join(str(x) for x in row))


def export_csv(results: list[BenchmarkResult], filepath: str, k: int):
    import csv
    with open(filepath, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["index_type", "build_params", "search_params",
                         f"recall_at_{k}", "latency_p50_ms", "latency_p99_ms",
                         "index_size_mb", "build_time_s"])
        for r in results:
            writer.writerow([
                r.index_type, json.dumps(r.params), json.dumps(r.search_params),
                f"{r.recall_at_k:.4f}", f"{r.latency_p50_ms:.1f}",
                f"{r.latency_p99_ms:.1f}", f"{r.index_size_mb:.1f}",
                f"{r.build_time_s:.1f}",
            ])
    print(f"\nResults exported to {filepath}")


def main():
    args = parse_args()

    if not args.db:
        print("ERROR: --db connection string or DATABASE_URL env var required")
        sys.exit(1)

    dist_config = DISTANCE_OPS[args.distance]

    print(f"Connecting to database...")
    conn = psycopg.connect(args.db, autocommit=True)

    # Auto-detect dimensions
    dims = args.dims or get_dimensions(conn, args.table, args.column)
    row_count = get_row_count(conn, args.table)
    print(f"Table: {args.table}, Column: {args.column}")
    print(f"Rows: {row_count:,}, Dimensions: {dims}, Distance: {args.distance}")
    print(f"Queries: {args.queries}, k: {args.k}")

    if row_count < 100:
        print("WARNING: Very few rows. Benchmarks may not be meaningful.")

    # Set high maintenance_work_mem for index builds
    conn.execute("SET maintenance_work_mem = '2GB'")

    # Sample query vectors and compute ground truth
    print(f"\nSampling {args.queries} query vectors...")
    query_vectors = sample_query_vectors(conn, args.table, args.column, args.queries)

    if len(query_vectors) < args.queries:
        print(f"  Only {len(query_vectors)} non-NULL vectors available")

    print("Computing ground truth (exact nearest neighbors)...")
    ground_truth = compute_ground_truth(
        conn, args.table, args.column, query_vectors, args.k, dist_config["operator"]
    )

    all_results = []

    # Benchmark HNSW
    if not args.skip_hnsw:
        print("\n" + "=" * 50)
        print("BENCHMARKING HNSW")
        print("=" * 50)
        hnsw_results = benchmark_hnsw(
            conn, args.table, args.column, query_vectors,
            ground_truth, args.k, dist_config
        )
        all_results.extend(hnsw_results)

    # Benchmark IVFFlat
    if not args.skip_ivfflat:
        print("\n" + "=" * 50)
        print("BENCHMARKING IVFFlat")
        print("=" * 50)
        ivfflat_results = benchmark_ivfflat(
            conn, args.table, args.column, query_vectors,
            ground_truth, args.k, dist_config, row_count
        )
        all_results.extend(ivfflat_results)

    # Print results
    print_results(all_results, args.k)

    # Export CSV
    if args.csv:
        export_csv(all_results, args.csv, args.k)

    conn.close()
    print("\nDone. All benchmark indexes have been cleaned up.")


if __name__ == "__main__":
    main()
