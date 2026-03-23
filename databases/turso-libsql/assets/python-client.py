"""
Turso/libSQL Python Client Template

Supports three modes:
  1. Remote — direct connection to Turso
  2. Embedded replica — local SQLite file synced from Turso
  3. Local file — pure SQLite for development/testing

Install:
  pip install libsql-experimental

Environment variables:
  TURSO_DATABASE_URL  — libsql://dbname-org.turso.io
  TURSO_AUTH_TOKEN    — JWT auth token
  TURSO_LOCAL_DB      — (optional) local replica file path
"""

import os
import time
from contextlib import contextmanager
from typing import Any, Generator

import libsql_experimental as libsql


def create_connection() -> libsql.Connection:
    """Create a libSQL connection based on environment configuration."""
    url = os.environ.get("TURSO_DATABASE_URL", "")
    token = os.environ.get("TURSO_AUTH_TOKEN", "")
    local_db = os.environ.get("TURSO_LOCAL_DB", "")

    # Embedded replica: local reads, remote writes
    if local_db and url:
        print(f"[turso] Connecting as embedded replica: {local_db}")
        conn = libsql.connect(
            local_db,
            sync_url=url,
            auth_token=token,
        )
        conn.sync()
        return conn

    # Remote: direct to Turso
    if url and url.startswith("libsql://"):
        print(f"[turso] Connecting to remote: {url}")
        return libsql.connect(url, auth_token=token)

    # Local file: development mode
    local_path = url if url else "dev.db"
    print(f"[turso] Connecting to local file: {local_path}")
    return libsql.connect(local_path)


# Module-level singleton
_connection: libsql.Connection | None = None


def get_connection() -> libsql.Connection:
    """Get or create the singleton database connection."""
    global _connection
    if _connection is None:
        _connection = create_connection()
    return _connection


def sync() -> None:
    """Sync embedded replica with remote primary. No-op for other modes."""
    conn = get_connection()
    if hasattr(conn, "sync"):
        conn.sync()


def execute_with_retry(
    sql: str,
    params: tuple[Any, ...] = (),
    max_retries: int = 3,
) -> list[Any]:
    """Execute a query with exponential backoff retry for transient failures."""
    conn = get_connection()

    for attempt in range(1, max_retries + 1):
        try:
            result = conn.execute(sql, params)
            return result.fetchall()
        except Exception as e:
            error_msg = str(e).lower()
            is_transient = any(
                keyword in error_msg
                for keyword in ("timeout", "network", "connection")
            )

            if not is_transient or attempt == max_retries:
                raise

            delay = min(2 ** (attempt - 1), 10)
            print(f"[turso] Retry {attempt}/{max_retries} after {delay}s")
            time.sleep(delay)

    raise RuntimeError("Unreachable")


@contextmanager
def transaction() -> Generator[libsql.Connection, None, None]:
    """Context manager for transactions with auto-commit/rollback."""
    conn = get_connection()
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise


# --- Usage Example ---

def main() -> None:
    conn = get_connection()

    # Create table
    conn.execute("""
        CREATE TABLE IF NOT EXISTS users (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            email TEXT NOT NULL UNIQUE,
            created_at TEXT NOT NULL DEFAULT (datetime('now'))
        )
    """)
    conn.commit()

    # Insert
    conn.execute(
        "INSERT OR IGNORE INTO users (name, email) VALUES (?, ?)",
        ("Alice", "alice@example.com"),
    )
    conn.commit()

    # Sync replica after write
    sync()

    # Query
    rows = conn.execute("SELECT * FROM users").fetchall()
    print("Users:", rows)

    # Transaction
    with transaction() as tx:
        tx.execute(
            "INSERT OR IGNORE INTO users (name, email) VALUES (?, ?)",
            ("Bob", "bob@example.com"),
        )
        tx.execute(
            "INSERT OR IGNORE INTO users (name, email) VALUES (?, ?)",
            ("Carol", "carol@example.com"),
        )

    # Verify
    count = conn.execute("SELECT count(*) FROM users").fetchone()[0]
    print(f"Total users: {count}")


if __name__ == "__main__":
    main()
