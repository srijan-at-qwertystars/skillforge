"""
connection-pool.py — Python connection pool pattern for SQLite with WAL mode.

Implements the recommended "single writer + multiple readers" pattern:
- One dedicated write connection (serialized via threading.Lock)
- A pool of read-only connections (concurrent via WAL mode)
- Automatic PRAGMA configuration for each connection
- Context managers for safe resource management
"""

import sqlite3
import threading
import queue
import os
from contextlib import contextmanager
from typing import Any


class SQLitePool:
    """
    Connection pool for SQLite using the single-writer + multi-reader pattern.

    Usage:
        pool = SQLitePool("app.db", max_readers=4)

        # Read queries (concurrent)
        with pool.read() as conn:
            rows = conn.execute("SELECT * FROM users").fetchall()

        # Write queries (serialized)
        with pool.write() as conn:
            conn.execute("INSERT INTO users (name) VALUES (?)", ("Alice",))

        # Cleanup
        pool.close()
    """

    def __init__(
        self,
        db_path: str,
        max_readers: int = 4,
        busy_timeout: int = 5000,
        cache_size_kb: int = 64000,
        mmap_size: int = 268435456,
    ):
        self.db_path = os.path.abspath(db_path)
        self._busy_timeout = busy_timeout
        self._cache_size_kb = cache_size_kb
        self._mmap_size = mmap_size

        # Writer: single connection, protected by a lock
        self._writer = self._create_connection(readonly=False)
        self._write_lock = threading.Lock()

        # Readers: pool of read-only connections
        self._reader_pool: queue.Queue[sqlite3.Connection] = queue.Queue()
        self._max_readers = max_readers
        for _ in range(max_readers):
            self._reader_pool.put(self._create_connection(readonly=True))

        self._closed = False

    def _create_connection(self, readonly: bool = False) -> sqlite3.Connection:
        """Create and configure a new SQLite connection."""
        conn = sqlite3.connect(
            self.db_path,
            isolation_level=None,        # manual transaction control
            check_same_thread=False,     # allow cross-thread access
            detect_types=sqlite3.PARSE_DECLTYPES | sqlite3.PARSE_COLNAMES,
        )
        conn.row_factory = sqlite3.Row

        # Apply production PRAGMAs
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA foreign_keys=ON")
        conn.execute(f"PRAGMA busy_timeout={self._busy_timeout}")
        conn.execute(f"PRAGMA cache_size=-{self._cache_size_kb}")
        conn.execute(f"PRAGMA mmap_size={self._mmap_size}")
        conn.execute("PRAGMA synchronous=NORMAL")
        conn.execute("PRAGMA temp_store=MEMORY")

        if readonly:
            conn.execute("PRAGMA query_only=ON")

        return conn

    @contextmanager
    def read(self):
        """
        Acquire a read-only connection from the pool.

        Usage:
            with pool.read() as conn:
                rows = conn.execute("SELECT ...").fetchall()
        """
        if self._closed:
            raise RuntimeError("Pool is closed")

        conn = self._reader_pool.get(timeout=10)
        try:
            yield conn
        finally:
            self._reader_pool.put(conn)

    @contextmanager
    def write(self):
        """
        Acquire the write connection with automatic transaction management.
        Only one writer at a time (enforced by lock).

        Usage:
            with pool.write() as conn:
                conn.execute("INSERT INTO ...", (...))
                # auto-commits on success, rolls back on exception
        """
        if self._closed:
            raise RuntimeError("Pool is closed")

        with self._write_lock:
            self._writer.execute("BEGIN IMMEDIATE")
            try:
                yield self._writer
                self._writer.execute("COMMIT")
            except Exception:
                self._writer.execute("ROLLBACK")
                raise

    def execute_read(self, sql: str, params: tuple = ()) -> list[sqlite3.Row]:
        """Convenience: execute a read query and return all rows."""
        with self.read() as conn:
            return conn.execute(sql, params).fetchall()

    def execute_write(self, sql: str, params: tuple = ()) -> int:
        """Convenience: execute a write query and return lastrowid."""
        with self.write() as conn:
            cursor = conn.execute(sql, params)
            return cursor.lastrowid

    def executemany_write(self, sql: str, params_seq) -> int:
        """Convenience: execute many writes in a single transaction."""
        with self.write() as conn:
            cursor = conn.executemany(sql, params_seq)
            return cursor.rowcount

    def close(self):
        """Close all connections and release resources."""
        if self._closed:
            return
        self._closed = True

        # Run PRAGMA optimize before closing (updates planner statistics)
        try:
            self._writer.execute("PRAGMA optimize")
        except Exception:
            pass

        self._writer.close()
        while not self._reader_pool.empty():
            try:
                conn = self._reader_pool.get_nowait()
                conn.close()
            except queue.Empty:
                break

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    def __del__(self):
        self.close()


# ─── Example usage ─────────────────────────────────────────────

if __name__ == "__main__":
    import tempfile

    # Create a temporary database for demonstration
    db_path = os.path.join(tempfile.gettempdir(), "pool_demo.db")

    with SQLitePool(db_path, max_readers=2) as pool:
        # Create schema
        with pool.write() as conn:
            conn.execute("""
                CREATE TABLE IF NOT EXISTS users (
                    id INTEGER PRIMARY KEY,
                    name TEXT NOT NULL,
                    email TEXT UNIQUE NOT NULL
                ) STRICT
            """)

        # Insert data
        pool.execute_write(
            "INSERT OR IGNORE INTO users (name, email) VALUES (?, ?)",
            ("Alice", "alice@example.com"),
        )

        # Bulk insert
        users = [
            ("Bob", "bob@example.com"),
            ("Charlie", "charlie@example.com"),
            ("Diana", "diana@example.com"),
        ]
        pool.executemany_write(
            "INSERT OR IGNORE INTO users (name, email) VALUES (?, ?)",
            users,
        )

        # Concurrent reads
        rows = pool.execute_read("SELECT * FROM users ORDER BY name")
        for row in rows:
            print(f"  {row['id']}: {row['name']} <{row['email']}>")

        # Demonstrate thread safety
        import concurrent.futures

        def read_users(thread_id: int) -> str:
            rows = pool.execute_read("SELECT count(*) as n FROM users")
            return f"Thread {thread_id}: {rows[0]['n']} users"

        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
            futures = [executor.submit(read_users, i) for i in range(8)]
            for future in concurrent.futures.as_completed(futures):
                print(f"  {future.result()}")

    # Cleanup
    for suffix in ("", "-wal", "-shm"):
        path = db_path + suffix
        if os.path.exists(path):
            os.unlink(path)

    print("\nDone.")
