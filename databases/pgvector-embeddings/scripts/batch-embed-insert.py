#!/usr/bin/env python3
"""
batch-embed-insert.py — Batch insert embeddings from OpenAI API into a pgvector table.

Reads text content from a PostgreSQL table, generates embeddings via OpenAI API,
and writes them back with progress tracking and retry logic.

Usage:
    # Embed all rows missing embeddings
    python batch-embed-insert.py \
        --db "postgresql://user:pass@localhost/mydb" \
        --table items \
        --text-column content \
        --vector-column embedding

    # With custom model and batch size
    python batch-embed-insert.py \
        --db "postgresql://user:pass@localhost/mydb" \
        --table items \
        --text-column content \
        --vector-column embedding \
        --model text-embedding-3-large \
        --dimensions 1024 \
        --batch-size 500

    # Dry run (show what would be processed)
    python batch-embed-insert.py \
        --db "postgresql://user:pass@localhost/mydb" \
        --table items \
        --text-column content \
        --vector-column embedding \
        --dry-run

Prerequisites:
    pip install openai psycopg[binary] tqdm

Environment:
    OPENAI_API_KEY  — Required. Your OpenAI API key.
    DATABASE_URL    — Optional. Alternative to --db flag.
"""

import argparse
import os
import sys
import time
from dataclasses import dataclass

try:
    import psycopg
    from pgvector.psycopg import register_vector
except ImportError:
    print("ERROR: Required packages not installed.")
    print("Run: pip install 'psycopg[binary]' pgvector")
    sys.exit(1)

try:
    from openai import OpenAI, RateLimitError, APITimeoutError, APIConnectionError
except ImportError:
    print("ERROR: openai package not installed. Run: pip install openai")
    sys.exit(1)

try:
    from tqdm import tqdm
except ImportError:
    # Fallback progress bar
    class tqdm:
        def __init__(self, iterable=None, total=None, desc="", unit=""):
            self.iterable = iterable
            self.total = total
            self.desc = desc
            self.n = 0

        def __iter__(self):
            for item in self.iterable:
                yield item
                self.n += 1
                if self.n % 10 == 0 or self.n == self.total:
                    print(f"\r{self.desc}: {self.n}/{self.total}", end="", flush=True)
            print()

        def update(self, n=1):
            self.n += n

        def set_postfix_str(self, s):
            pass

        def close(self):
            pass


@dataclass
class Stats:
    total_rows: int = 0
    embedded: int = 0
    skipped: int = 0
    errors: int = 0
    retries: int = 0
    tokens_used: int = 0
    start_time: float = 0.0

    @property
    def elapsed(self) -> float:
        return time.time() - self.start_time

    @property
    def rate(self) -> float:
        return self.embedded / max(self.elapsed, 0.001)

    def summary(self) -> str:
        return (
            f"\nDone! Embedded {self.embedded:,} rows in {self.elapsed:.1f}s "
            f"({self.rate:.0f} rows/s)\n"
            f"  Tokens used: ~{self.tokens_used:,}\n"
            f"  Skipped:     {self.skipped:,}\n"
            f"  Errors:      {self.errors:,}\n"
            f"  Retries:     {self.retries:,}"
        )


def parse_args():
    parser = argparse.ArgumentParser(
        description="Batch embed text and insert into pgvector table"
    )
    parser.add_argument("--db", type=str, default=os.environ.get("DATABASE_URL"),
                        help="PostgreSQL connection string (or set DATABASE_URL)")
    parser.add_argument("--table", type=str, required=True,
                        help="Table name")
    parser.add_argument("--id-column", type=str, default="id",
                        help="Primary key column (default: id)")
    parser.add_argument("--text-column", type=str, required=True,
                        help="Column containing text to embed")
    parser.add_argument("--vector-column", type=str, default="embedding",
                        help="Vector column to write embeddings to (default: embedding)")
    parser.add_argument("--model", type=str, default="text-embedding-3-small",
                        help="OpenAI embedding model (default: text-embedding-3-small)")
    parser.add_argument("--dimensions", type=int, default=None,
                        help="Request reduced dimensions (Matryoshka). Default: model's native dims")
    parser.add_argument("--batch-size", type=int, default=100,
                        help="Rows per API call (default: 100, max: 2048)")
    parser.add_argument("--max-retries", type=int, default=5,
                        help="Max retries per batch on failure (default: 5)")
    parser.add_argument("--max-text-length", type=int, default=8000,
                        help="Max text characters per item (default: 8000)")
    parser.add_argument("--where", type=str, default=None,
                        help="Additional WHERE clause filter (e.g., \"category = 'docs'\")")
    parser.add_argument("--dry-run", action="store_true",
                        help="Show what would be processed without making changes")
    parser.add_argument("--resume", action="store_true", default=True,
                        help="Skip rows that already have embeddings (default: true)")
    parser.add_argument("--no-resume", action="store_true",
                        help="Re-embed all rows, even those with existing embeddings")
    return parser.parse_args()


def get_pending_rows(conn, table: str, id_col: str, text_col: str,
                     vector_col: str, where: str | None, skip_existing: bool) -> list:
    """Fetch rows that need embedding."""
    conditions = [f"{text_col} IS NOT NULL", f"{text_col} != ''"]
    if skip_existing:
        conditions.append(f"{vector_col} IS NULL")
    if where:
        conditions.append(f"({where})")

    where_clause = " AND ".join(conditions)
    query = f"SELECT {id_col}, {text_col} FROM {table} WHERE {where_clause} ORDER BY {id_col}"

    rows = conn.execute(query).fetchall()
    return [(row[0], row[1]) for row in rows]


def embed_batch_with_retry(
    client: OpenAI,
    texts: list[str],
    model: str,
    dimensions: int | None,
    max_retries: int,
    stats: Stats,
) -> list[list[float]] | None:
    """Call OpenAI embeddings API with exponential backoff retry."""
    for attempt in range(max_retries):
        try:
            kwargs = {"input": texts, "model": model}
            if dimensions:
                kwargs["dimensions"] = dimensions
            response = client.embeddings.create(**kwargs)
            stats.tokens_used += response.usage.total_tokens
            sorted_data = sorted(response.data, key=lambda x: x.index)
            return [d.embedding for d in sorted_data]

        except RateLimitError as e:
            wait = min(2 ** attempt * 2, 60)
            stats.retries += 1
            print(f"\n  Rate limited. Waiting {wait}s... (attempt {attempt + 1}/{max_retries})")
            time.sleep(wait)

        except (APITimeoutError, APIConnectionError) as e:
            wait = min(2 ** attempt, 30)
            stats.retries += 1
            print(f"\n  API error: {e}. Retrying in {wait}s... (attempt {attempt + 1}/{max_retries})")
            time.sleep(wait)

        except Exception as e:
            print(f"\n  Unexpected error: {e}")
            stats.errors += len(texts)
            return None

    print(f"\n  Failed after {max_retries} retries. Skipping batch of {len(texts)} rows.")
    stats.errors += len(texts)
    return None


def update_embeddings(conn, table: str, id_col: str, vector_col: str,
                      ids: list, embeddings: list[list[float]]):
    """Write embeddings back to the table."""
    with conn.cursor() as cur:
        for row_id, emb in zip(ids, embeddings):
            cur.execute(
                f"UPDATE {table} SET {vector_col} = %s WHERE {id_col} = %s",
                (emb, row_id)
            )
    conn.commit()


def main():
    args = parse_args()

    if not args.db:
        print("ERROR: --db connection string or DATABASE_URL env var required")
        sys.exit(1)

    if not os.environ.get("OPENAI_API_KEY"):
        print("ERROR: OPENAI_API_KEY environment variable required")
        sys.exit(1)

    skip_existing = not args.no_resume
    batch_size = min(args.batch_size, 2048)

    # Connect to database
    print(f"Connecting to database...")
    conn = psycopg.connect(args.db)
    register_vector(conn)

    # Fetch pending rows
    print(f"Fetching rows from {args.table}...")
    rows = get_pending_rows(
        conn, args.table, args.id_column, args.text_column,
        args.vector_column, args.where, skip_existing
    )

    if not rows:
        print("No rows to process. All embeddings are up to date.")
        conn.close()
        return

    print(f"Found {len(rows):,} rows to embed")
    print(f"Model: {args.model}, Dimensions: {args.dimensions or 'native'}")
    print(f"Batch size: {batch_size}")

    if args.dry_run:
        print("\n[DRY RUN] Would process the above rows. Exiting.")
        conn.close()
        return

    # Initialize OpenAI client
    client = OpenAI()
    stats = Stats(total_rows=len(rows), start_time=time.time())

    # Process in batches
    progress = tqdm(total=len(rows), desc="Embedding", unit="rows")

    for i in range(0, len(rows), batch_size):
        batch = rows[i:i + batch_size]
        ids = [r[0] for r in batch]
        texts = [r[1][:args.max_text_length].replace("\n", " ").strip() for r in batch]

        # Skip empty texts
        valid = [(id_, text) for id_, text in zip(ids, texts) if text]
        if not valid:
            stats.skipped += len(batch)
            progress.update(len(batch))
            continue

        valid_ids, valid_texts = zip(*valid)

        embeddings = embed_batch_with_retry(
            client, list(valid_texts), args.model, args.dimensions,
            args.max_retries, stats
        )

        if embeddings:
            update_embeddings(
                conn, args.table, args.id_column, args.vector_column,
                list(valid_ids), embeddings
            )
            stats.embedded += len(embeddings)

        skipped = len(batch) - len(valid)
        stats.skipped += skipped

        progress.update(len(batch))
        progress.set_postfix_str(
            f"embedded={stats.embedded}, tokens={stats.tokens_used:,}, "
            f"err={stats.errors}"
        )

    progress.close()
    conn.close()

    print(stats.summary())


if __name__ == "__main__":
    main()
