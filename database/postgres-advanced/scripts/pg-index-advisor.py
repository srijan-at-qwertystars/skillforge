#!/usr/bin/env python3
"""
pg-index-advisor.py — PostgreSQL Index Advisor

Usage:
    ./pg-index-advisor.py [-H HOST] [-p PORT] [-d DATABASE] [-U USER]
                          [--min-size MIN_ROWS] [--seq-threshold PCT]

Analyzes pg_stat_user_tables and pg_stat_user_indexes to:
  - Identify tables with high sequential scan ratios (missing indexes)
  - Find unused indexes that waste space and slow writes
  - Detect duplicate/overlapping indexes
  - Suggest missing indexes based on access patterns

Requirements: psycopg2 (pip install psycopg2-binary)

Environment variables: PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD
"""

import argparse
import os
import sys

try:
    import psycopg2
    import psycopg2.extras
except ImportError:
    print("Error: psycopg2 is required. Install with: pip install psycopg2-binary")
    sys.exit(1)


def get_connection(args):
    """Establish database connection."""
    return psycopg2.connect(
        host=args.host,
        port=args.port,
        dbname=args.database,
        user=args.user,
        password=os.environ.get("PGPASSWORD", ""),
    )


def print_header(title):
    """Print a formatted section header."""
    print(f"\n{'=' * 78}")
    print(f"  {title}")
    print(f"{'=' * 78}")


def analyze_sequential_scans(conn, min_size, seq_threshold):
    """Find tables with high sequential scan ratio suggesting missing indexes."""
    print_header("TABLES WITH HIGH SEQUENTIAL SCAN RATIO (may need indexes)")

    query = """
    SELECT
        schemaname,
        relname AS table_name,
        seq_scan,
        idx_scan,
        CASE WHEN (seq_scan + idx_scan) > 0
             THEN round(seq_scan::numeric / (seq_scan + idx_scan) * 100, 2)
             ELSE 100 END AS seq_scan_pct,
        n_live_tup AS row_count,
        pg_size_pretty(pg_total_relation_size(schemaname || '.' || relname)) AS table_size,
        seq_tup_read,
        idx_tup_fetch
    FROM pg_stat_user_tables
    WHERE (seq_scan + idx_scan) > 10
      AND n_live_tup >= %s
      AND CASE WHEN (seq_scan + idx_scan) > 0
               THEN seq_scan::numeric / (seq_scan + idx_scan) * 100
               ELSE 100 END >= %s
    ORDER BY seq_scan_pct DESC, seq_tup_read DESC
    """

    with conn.cursor(cursor_factory=psycopg2.extras.DictCursor) as cur:
        cur.execute(query, (min_size, seq_threshold))
        rows = cur.fetchall()

    if not rows:
        print("  ✓ No tables with concerning sequential scan ratios found.")
        return []

    print(f"\n  {'Table':<40} {'Seq%':>6} {'SeqScans':>10} {'IdxScans':>10} {'Rows':>12}")
    print(f"  {'-' * 40} {'-' * 6} {'-' * 10} {'-' * 10} {'-' * 12}")

    candidates = []
    for row in rows:
        table = f"{row['schemaname']}.{row['table_name']}"
        print(
            f"  {table:<40} {row['seq_scan_pct']:>5}% "
            f"{row['seq_scan']:>10} {row['idx_scan']:>10} {row['row_count']:>12}"
        )
        candidates.append(
            {
                "schema": row["schemaname"],
                "table": row["table_name"],
                "seq_pct": float(row["seq_scan_pct"]),
                "row_count": row["row_count"],
            }
        )

    return candidates


def find_unused_indexes(conn):
    """Find indexes that have never been used (0 scans)."""
    print_header("UNUSED INDEXES (candidates for removal)")

    query = """
    SELECT
        schemaname,
        relname AS table_name,
        indexrelname AS index_name,
        pg_size_pretty(pg_relation_size(indexrelid)) AS index_size,
        pg_relation_size(indexrelid) AS index_size_bytes,
        idx_scan AS scans,
        idx_tup_read,
        idx_tup_fetch
    FROM pg_stat_user_indexes
    WHERE idx_scan = 0
      AND pg_relation_size(indexrelid) > 65536
      AND indexrelname NOT LIKE '%_pkey'
      AND indexrelname NOT LIKE '%_unique%'
    ORDER BY pg_relation_size(indexrelid) DESC
    """

    with conn.cursor(cursor_factory=psycopg2.extras.DictCursor) as cur:
        cur.execute(query)
        rows = cur.fetchall()

    if not rows:
        print("  ✓ No unused indexes found.")
        return

    total_waste = 0
    print(f"\n  {'Index':<45} {'Table':<25} {'Size':>10}")
    print(f"  {'-' * 45} {'-' * 25} {'-' * 10}")

    for row in rows:
        print(
            f"  {row['index_name']:<45} {row['table_name']:<25} "
            f"{row['index_size']:>10}"
        )
        total_waste += row["index_size_bytes"]

    total_mb = total_waste / (1024 * 1024)
    print(f"\n  Total space wasted by unused indexes: {total_mb:.1f} MB")
    print("\n  Suggested actions:")
    for row in rows:
        print(f"  -- DROP INDEX CONCURRENTLY {row['schemaname']}.{row['index_name']};")


def find_duplicate_indexes(conn):
    """Find indexes that are duplicates or subsets of other indexes."""
    print_header("POTENTIALLY DUPLICATE INDEXES")

    query = """
    SELECT
        pg_size_pretty(sum(pg_relation_size(idx))::bigint) AS total_size,
        array_agg(idx::text) AS indexes,
        (array_agg(indexdef))[1] AS index_definition
    FROM (
        SELECT
            indexrelid::regclass AS idx,
            (indrelid::text || E'\n' || indclass::text || E'\n' ||
             indkey::text || E'\n' || coalesce(indexprs::text, '') || E'\n' ||
             coalesce(indpred::text, '')) AS index_signature,
            pg_get_indexdef(indexrelid) AS indexdef
        FROM pg_index
        JOIN pg_class ON pg_class.oid = pg_index.indrelid
        WHERE indrelid::regclass::text NOT LIKE 'pg_%'
    ) sub
    GROUP BY index_signature
    HAVING count(*) > 1
    ORDER BY sum(pg_relation_size(idx)) DESC
    """

    with conn.cursor(cursor_factory=psycopg2.extras.DictCursor) as cur:
        cur.execute(query)
        rows = cur.fetchall()

    if not rows:
        print("  ✓ No duplicate indexes found.")
        return

    for row in rows:
        indexes = row["indexes"]
        print(f"\n  Duplicates (total size: {row['total_size']}):")
        for idx in indexes:
            print(f"    - {idx}")
        print(f"  Definition: {row['index_definition']}")


def suggest_indexes(conn, candidates):
    """Suggest indexes for tables with high sequential scan ratios."""
    if not candidates:
        return

    print_header("INDEX SUGGESTIONS")

    for candidate in candidates[:10]:
        schema = candidate["schema"]
        table = candidate["table"]
        full_table = f"{schema}.{table}"

        # Check existing indexes
        with conn.cursor(cursor_factory=psycopg2.extras.DictCursor) as cur:
            cur.execute(
                """
                SELECT indexdef FROM pg_indexes
                WHERE schemaname = %s AND tablename = %s
                """,
                (schema, table),
            )
            existing = cur.fetchall()

            # Check columns frequently used in WHERE clauses via pg_stats
            cur.execute(
                """
                SELECT
                    a.attname AS column_name,
                    format_type(a.atttypid, a.atttypmod) AS data_type,
                    s.null_frac,
                    s.n_distinct,
                    s.correlation
                FROM pg_attribute a
                JOIN pg_stats s ON s.tablename = a.attname IS NOT NULL
                    AND s.schemaname = %s AND s.tablename = %s
                    AND s.attname = a.attname
                JOIN pg_class c ON c.oid = a.attrelid
                JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE n.nspname = %s AND c.relname = %s
                  AND a.attnum > 0 AND NOT a.attisdropped
                  AND a.atttypid IN (
                      20, 21, 23, 26,     -- integer types
                      1082, 1114, 1184,   -- date/timestamp types
                      25, 1043,           -- text/varchar
                      16,                 -- boolean
                      2950               -- uuid
                  )
                ORDER BY abs(s.correlation) ASC
                LIMIT 5
                """,
                (schema, table, schema, table),
            )
            columns = cur.fetchall()

        print(f"\n  Table: {full_table}")
        print(f"  Seq scan ratio: {candidate['seq_pct']}% | Rows: {candidate['row_count']:,}")
        print(f"  Existing indexes: {len(existing)}")

        if existing:
            for idx in existing:
                print(f"    → {idx['indexdef']}")

        if columns:
            print(f"\n  Consider indexing these columns (low correlation = poor physical order):")
            for col in columns:
                corr = col["correlation"] or 0
                distinct = col["n_distinct"] or 0
                suggestion = ""
                if abs(corr) < 0.3 and candidate["row_count"] > 100000:
                    suggestion = " ← BRIN may help if data is append-only"
                if 0 < distinct < 100:
                    suggestion = " ← partial index candidate (low cardinality)"

                print(
                    f"    - {col['column_name']} ({col['data_type']}) "
                    f"correlation={corr:.3f} distinct={distinct}{suggestion}"
                )
            print(
                f"\n  -- Suggested (review columns based on your WHERE clauses):"
            )
            if columns:
                col_name = columns[0]["column_name"]
                print(
                    f"  CREATE INDEX CONCURRENTLY idx_{table}_{col_name} "
                    f"ON {full_table} ({col_name});"
                )
        else:
            print("  No column statistics available. Run ANALYZE first.")


def main():
    parser = argparse.ArgumentParser(
        description="PostgreSQL Index Advisor — Suggests missing indexes"
    )
    parser.add_argument("-H", "--host", default=os.environ.get("PGHOST", "localhost"))
    parser.add_argument("-p", "--port", type=int, default=int(os.environ.get("PGPORT", "5432")))
    parser.add_argument("-d", "--database", default=os.environ.get("PGDATABASE", "postgres"))
    parser.add_argument("-U", "--user", default=os.environ.get("PGUSER", "postgres"))
    parser.add_argument(
        "--min-size", type=int, default=10000,
        help="Minimum table row count to consider (default: 10000)",
    )
    parser.add_argument(
        "--seq-threshold", type=float, default=50.0,
        help="Sequential scan percentage threshold (default: 50.0)",
    )

    args = parser.parse_args()

    print("PostgreSQL Index Advisor")
    print(f"Connecting to {args.host}:{args.port}/{args.database} as {args.user}")

    try:
        conn = get_connection(args)
    except psycopg2.OperationalError as e:
        print(f"Error: Cannot connect to database: {e}")
        sys.exit(1)

    try:
        candidates = analyze_sequential_scans(conn, args.min_size, args.seq_threshold)
        find_unused_indexes(conn)
        find_duplicate_indexes(conn)
        suggest_indexes(conn, candidates)
    finally:
        conn.close()

    print(f"\n{'=' * 78}")
    print("  Analysis complete.")
    print(f"{'=' * 78}\n")


if __name__ == "__main__":
    main()
