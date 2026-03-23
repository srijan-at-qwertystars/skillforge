# SQLite Troubleshooting Guide

## Table of Contents

- [Database is Locked Errors](#database-is-locked-errors)
- [WAL Checkpoint Stalls](#wal-checkpoint-stalls)
- [Corruption Detection and Recovery](#corruption-detection-and-recovery)
- [SQLITE_BUSY Handling Strategies](#sqlite_busy-handling-strategies)
- [Performance Cliffs with Large Databases](#performance-cliffs-with-large-databases)
- [Temp Storage Exhaustion](#temp-storage-exhaustion)
- [Index Selection Problems](#index-selection-problems)
- [Platform-Specific Issues](#platform-specific-issues)
  - [NFS and Network Drives](#nfs-and-network-drives)
  - [Android](#android)
  - [macOS and iOS](#macos-and-ios)
  - [Windows](#windows)
  - [Docker and Containers](#docker-and-containers)

---

## Database is Locked Errors

The most common SQLite error. Causes and solutions:

### Cause 1: No busy_timeout set

SQLite returns `SQLITE_BUSY` immediately if another connection holds a lock.

```sql
-- Fix: always set busy_timeout at connection open
PRAGMA busy_timeout = 5000;  -- wait up to 5 seconds
```

### Cause 2: Long-running write transactions

A write transaction holds an EXCLUSIVE lock for its entire duration, blocking all
other writers and (in DELETE journal mode) readers.

```python
# BAD: holding a write transaction for too long
conn.execute("BEGIN")
rows = conn.execute("SELECT * FROM large_table").fetchall()
for row in rows:
    process(row)  # slow processing while lock is held
    conn.execute("UPDATE ...", ...)
conn.execute("COMMIT")

# GOOD: batch into short transactions
rows = conn.execute("SELECT id FROM large_table").fetchall()
for batch in chunks(rows, 1000):
    with conn:  # auto-commit after each batch
        for row_id in batch:
            conn.execute("UPDATE ... WHERE id = ?", (row_id,))
```

### Cause 3: Unclosed statements or connections

An open prepared statement can hold a SHARED lock, preventing WAL checkpoints or
EXCLUSIVE locks.

```python
# BAD: cursor not closed
cursor = conn.execute("SELECT * FROM users")
row = cursor.fetchone()
# cursor still holds a SHARED lock!

# GOOD: close cursors explicitly or use fetchall()
cursor = conn.execute("SELECT * FROM users")
rows = cursor.fetchall()
cursor.close()
```

### Cause 4: Multiple processes without WAL mode

In DELETE journal mode, readers block writers and writers block readers.

```sql
-- Fix: enable WAL mode
PRAGMA journal_mode = WAL;
```

### Cause 5: Unfinalized statements in other connections

```sql
-- Diagnose: list all held locks (via sqlite3_stmt_status or instrumentation)
-- Fix: ensure all statements are finalized/reset before committing
```

### Debugging locked errors

```python
# Python: enable verbose error messages
import sqlite3
import traceback

class DebugConnection:
    def __init__(self, path):
        self.conn = sqlite3.connect(path)
        self.conn.execute("PRAGMA busy_timeout = 5000")

    def execute(self, sql, params=()):
        try:
            return self.conn.execute(sql, params)
        except sqlite3.OperationalError as e:
            if "locked" in str(e) or "busy" in str(e):
                print(f"LOCK ERROR: {e}")
                print(f"SQL: {sql}")
                traceback.print_stack()
            raise
```

---

## WAL Checkpoint Stalls

WAL checkpoints transfer data from the WAL file back to the main database. Stalls
occur when checkpoints can't complete.

### Symptoms

- WAL file grows continuously (>100 MB).
- `PRAGMA wal_checkpoint` returns without transferring all pages.
- Database reads slow down as WAL gets large (readers must search WAL).

### Cause 1: Long-running read transactions

A checkpoint cannot advance past a page that is still being read by any connection.

```sql
-- Check current WAL status
PRAGMA wal_checkpoint;  -- returns (busy, log_pages, checkpointed_pages)

-- Force a truncating checkpoint (blocks until complete)
PRAGMA wal_checkpoint(TRUNCATE);
```

### Cause 2: Readers not closing transactions

Even in WAL mode with autocommit, an implicit transaction exists during `SELECT`.
Long-running queries prevent checkpoint progress.

```python
# BAD: iterating lazily over a large result set
for row in conn.execute("SELECT * FROM huge_table"):
    slow_process(row)
    # read transaction is open the entire time, WAL can't checkpoint

# GOOD: fetch in bounded pages
offset = 0
while True:
    rows = conn.execute(
        "SELECT * FROM huge_table LIMIT 1000 OFFSET ?", (offset,)
    ).fetchall()
    if not rows:
        break
    for row in rows:
        slow_process(row)
    offset += 1000
```

### Cause 3: Checkpoint frequency

By default, SQLite auto-checkpoints when the WAL reaches 1000 pages (~4 MB with
4 KB page size).

```sql
-- Increase auto-checkpoint threshold (pages)
PRAGMA wal_autocheckpoint = 5000;  -- ~20 MB before auto-checkpoint

-- Disable auto-checkpoint (manage manually)
PRAGMA wal_autocheckpoint = 0;

-- Run checkpoint in a background thread/process
PRAGMA wal_checkpoint(PASSIVE);    -- non-blocking, do what you can
PRAGMA wal_checkpoint(FULL);       -- block writers, complete checkpoint
PRAGMA wal_checkpoint(RESTART);    -- like FULL, also reset WAL file
PRAGMA wal_checkpoint(TRUNCATE);   -- like RESTART, also truncate WAL to zero
```

### Monitoring WAL size

```bash
# Check WAL file size on disk
ls -lh app.db-wal

# In SQLite
sqlite3 app.db "PRAGMA page_size; PRAGMA wal_checkpoint;"
```

---

## Corruption Detection and Recovery

### Detection

```sql
-- Full integrity check (slow on large databases)
PRAGMA integrity_check;
-- Returns 'ok' or a list of errors

-- Quick check (subset of integrity_check, faster)
PRAGMA quick_check;

-- Check foreign key constraints
PRAGMA foreign_key_check;

-- Check specific table
PRAGMA integrity_check(tablename);
```

### Common corruption causes

1. **Incomplete writes** — Power loss during a write without `synchronous = FULL`.
2. **NFS/network filesystems** — File locking is unreliable.
3. **Copying while open** — Copying the .db file without the -wal and -shm files.
4. **Disk errors** — Bad sectors, failing SSD.
5. **Memory corruption** — Bugs in custom extensions or application code.
6. **Incorrect file permissions** — WAL/SHM files owned by different users.
7. **Force-killing** the SQLite process during a write.

### Recovery strategies

```bash
# Method 1: .recover command (SQLite 3.29+, best option)
sqlite3 corrupt.db ".recover" | sqlite3 recovered.db

# Method 2: .dump and reimport
sqlite3 corrupt.db ".dump" | sqlite3 recovered.db

# Method 3: export schema only, then copy data table by table
sqlite3 corrupt.db ".schema" > schema.sql
sqlite3 recovered.db < schema.sql
# Then copy data from tables that are intact

# Method 4: use a backup (best if available)
cp /backups/latest_backup.db app.db
```

```python
# Python: automatic recovery attempt
import sqlite3
import shutil

def try_recover(db_path, backup_path):
    conn = sqlite3.connect(db_path)
    try:
        result = conn.execute("PRAGMA integrity_check").fetchone()[0]
        if result != 'ok':
            print(f"Corruption detected: {result}")
            conn.close()
            # Try .recover
            import subprocess
            subprocess.run(
                f'sqlite3 "{db_path}" ".recover" | sqlite3 "{backup_path}"',
                shell=True, check=True
            )
            # Verify recovered database
            rconn = sqlite3.connect(backup_path)
            rresult = rconn.execute("PRAGMA integrity_check").fetchone()[0]
            rconn.close()
            if rresult == 'ok':
                shutil.move(backup_path, db_path)
                print("Recovery successful")
            else:
                print("Recovery failed, restore from backup")
    finally:
        conn.close()
```

### Prevention

```sql
-- Maximum safety configuration (at cost of performance)
PRAGMA journal_mode = WAL;
PRAGMA synchronous = FULL;     -- fsync after every transaction
PRAGMA integrity_check;        -- run periodically (e.g., on startup)
```

```bash
# Verify backup integrity
sqlite3 backup.db "PRAGMA integrity_check; PRAGMA quick_check;"
```

---

## SQLITE_BUSY Handling Strategies

`SQLITE_BUSY` (error code 5) means another connection holds a conflicting lock.

### Strategy 1: busy_timeout (simplest)

```sql
PRAGMA busy_timeout = 5000;  -- sleep/retry for up to 5 seconds
```

SQLite's built-in busy handler sleeps with exponential backoff. Simple and usually
sufficient.

### Strategy 2: Custom busy handler

```python
# Python: custom busy handler with logging
import sqlite3
import time

def busy_handler(attempt_count):
    """Return True to retry, False to give up."""
    if attempt_count > 50:
        return False
    wait = min(0.01 * (2 ** min(attempt_count, 8)), 1.0)  # exponential up to 1s
    print(f"Database busy, attempt {attempt_count}, waiting {wait:.3f}s")
    time.sleep(wait)
    return True

conn = sqlite3.connect('app.db')
conn.set_progress_handler(None, 0)
# Note: Python sqlite3 doesn't expose set_busy_handler directly.
# Use busy_timeout pragma or apsw for custom busy handlers.
```

```c
// C: custom busy handler
static int my_busy_handler(void *data, int count) {
    if (count > 100) return 0;  // give up
    int ms = (count < 10) ? count * 10 : 100;
    sqlite3_sleep(ms);
    return 1;  // retry
}
sqlite3_busy_handler(db, my_busy_handler, NULL);
```

### Strategy 3: BEGIN IMMEDIATE

Acquire write lock at transaction start, failing fast instead of mid-transaction.

```sql
BEGIN IMMEDIATE;
-- If SQLITE_BUSY, we know immediately instead of after doing work
UPDATE accounts SET balance = balance - 100 WHERE id = 1;
UPDATE accounts SET balance = balance + 100 WHERE id = 2;
COMMIT;
```

### Strategy 4: Application-level retry with backoff

```python
import sqlite3
import time
import random

def execute_with_retry(conn, sql, params=(), max_retries=5):
    for attempt in range(max_retries):
        try:
            return conn.execute(sql, params)
        except sqlite3.OperationalError as e:
            if "locked" in str(e) or "busy" in str(e):
                if attempt == max_retries - 1:
                    raise
                wait = (2 ** attempt) * 0.1 + random.uniform(0, 0.1)
                time.sleep(wait)
            else:
                raise
```

### Strategy 5: Write queue (serialize all writes)

```python
import sqlite3
import threading
import queue

class WriteQueue:
    def __init__(self, db_path):
        self.queue = queue.Queue()
        self.db_path = db_path
        self.thread = threading.Thread(target=self._writer, daemon=True)
        self.thread.start()

    def _writer(self):
        conn = sqlite3.connect(self.db_path)
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA busy_timeout=5000")
        while True:
            sql, params, event, result = self.queue.get()
            try:
                cursor = conn.execute(sql, params)
                conn.commit()
                result.append(cursor.lastrowid)
            except Exception as e:
                result.append(e)
            finally:
                event.set()

    def write(self, sql, params=()):
        event = threading.Event()
        result = []
        self.queue.put((sql, params, event, result))
        event.wait()
        if isinstance(result[0], Exception):
            raise result[0]
        return result[0]
```

---

## Performance Cliffs with Large Databases

SQLite can handle databases up to 281 TB (theoretical), but performance
characteristics change significantly with size.

### Symptom: Queries slow down around 1-10 GB

**Causes:**
1. **Page cache miss:** `cache_size` too small. Data must be read from disk.
2. **B-tree depth increases:** More page reads per lookup.
3. **Index becomes stale:** `ANALYZE` not run after bulk loads.

```sql
-- Fix 1: increase page cache
PRAGMA cache_size = -128000;  -- 128 MB

-- Fix 2: enable memory-mapped I/O
PRAGMA mmap_size = 1073741824;  -- 1 GB

-- Fix 3: update planner statistics
ANALYZE;
```

### Symptom: INSERT throughput drops

**Causes:**
1. **Too many indexes:** each INSERT updates every index.
2. **WAL file too large:** checkpoint overhead grows.
3. **fsync overhead:** `synchronous = FULL` or many small transactions.

```sql
-- Fix 1: batch inserts in larger transactions
BEGIN;
-- ... thousands of INSERTs ...
COMMIT;

-- Fix 2: drop indexes before bulk load, recreate after
DROP INDEX idx_name;
-- ... bulk insert ...
CREATE INDEX idx_name ON table(column);
ANALYZE;

-- Fix 3: tune synchronous
PRAGMA synchronous = NORMAL;  -- safe with WAL
```

### Symptom: Full table scans on seemingly indexed queries

```sql
-- Diagnose with EXPLAIN QUERY PLAN
EXPLAIN QUERY PLAN SELECT * FROM orders WHERE status = 'active' AND total > 100;
-- Look for "SCAN" (bad) vs "SEARCH" (good)

-- Common reasons:
-- 1. Wrong column order in composite index
-- 2. Function on indexed column: WHERE lower(email) = '...'
-- 3. Type mismatch: WHERE id = '5' (string vs integer)
-- 4. OR conditions: WHERE a = 1 OR b = 2 (can't use single index)

-- Fix OR conditions with UNION
SELECT * FROM t WHERE a = 1
UNION ALL
SELECT * FROM t WHERE b = 2 AND a != 1;
```

### Memory usage management

```sql
-- Release memory
PRAGMA shrink_memory;

-- Limit cache to reduce memory footprint
PRAGMA cache_size = -8000;  -- 8 MB

-- Use temp_store = FILE for large temp operations
PRAGMA temp_store = FILE;
PRAGMA temp_store_directory = '/fast-ssd/tmp';
```

---

## Temp Storage Exhaustion

SQLite uses temporary storage for ORDER BY, GROUP BY, CREATE INDEX, compound
SELECT, VACUUM, and subqueries. By default, this is in `/tmp` or memory.

### Symptoms

- `SQLITE_FULL` error during queries.
- Disk space exhaustion in `/tmp`.
- OOM errors with `temp_store = MEMORY`.

### Diagnosis and fixes

```sql
-- Check current temp store mode
PRAGMA temp_store;      -- 0=DEFAULT, 1=FILE, 2=MEMORY

-- Switch to file-based temp with custom directory
PRAGMA temp_store = FILE;

-- For large sort/group operations, use file-based temp
PRAGMA temp_store = 1;
```

```bash
# Check available temp space
df -h /tmp

# Set SQLite temp directory via environment variable
export SQLITE_TMPDIR=/mnt/fast-ssd/sqlite-tmp
```

### Reduce temp storage needs

```sql
-- Avoid ORDER BY on large result sets without LIMIT
SELECT * FROM logs ORDER BY created_at LIMIT 100;

-- Use covering indexes to avoid temp sort
CREATE INDEX idx_logs_date ON logs(created_at, id, message);

-- For CREATE INDEX on large tables, ensure ample temp space
-- or create in stages with partial indexes
```

---

## Index Selection Problems

### unlikely() and likelihood()

Hint the query planner about expected selectivity when it misjudges:

```sql
-- Tell planner this condition rarely matches (use index)
SELECT * FROM events WHERE unlikely(type = 'error');

-- Tell planner specific probability (0.0 to 1.0)
SELECT * FROM events WHERE likelihood(status = 'active', 0.95);

-- These don't change results, only influence the planner's cost estimation
```

### Diagnosing bad index choices

```sql
-- See what indexes the planner uses
EXPLAIN QUERY PLAN SELECT * FROM orders WHERE status = 'pending' AND amount > 100;

-- See detailed opcodes (for advanced debugging)
EXPLAIN SELECT * FROM orders WHERE status = 'pending' AND amount > 100;

-- Force index usage (SQLite 3.32+)
SELECT * FROM orders INDEXED BY idx_status WHERE status = 'pending';

-- List all indexes on a table
SELECT * FROM pragma_index_list('orders');

-- Show index columns
SELECT * FROM pragma_index_info('idx_status');

-- Show index predicate (partial indexes)
SELECT sql FROM sqlite_master WHERE type = 'index' AND name = 'idx_active';
```

### Common index selection mistakes

```sql
-- Mistake 1: NOT IN with large subquery (planner gives up on index)
-- BAD
SELECT * FROM users WHERE id NOT IN (SELECT user_id FROM blocked);
-- BETTER
SELECT u.* FROM users u
LEFT JOIN blocked b ON u.id = b.user_id
WHERE b.user_id IS NULL;

-- Mistake 2: implicit type conversion
-- BAD: id is INTEGER but parameter is TEXT
SELECT * FROM users WHERE id = '42';  -- may not use index
-- GOOD
SELECT * FROM users WHERE id = 42;

-- Mistake 3: composite index column order
-- Index on (a, b, c) can be used for:
--   WHERE a = ?               ✅
--   WHERE a = ? AND b = ?     ✅
--   WHERE a = ? AND b = ? AND c = ?  ✅
--   WHERE b = ?               ❌ (leftmost prefix not used)
--   WHERE a = ? AND c = ?     ⚠️ (a used, c skipped)

-- Mistake 4: function wrapping indexed column
-- BAD
SELECT * FROM users WHERE substr(name, 1, 3) = 'Ali';
-- GOOD: use expression index
CREATE INDEX idx_name_prefix ON users(substr(name, 1, 3));
```

### Updating stale statistics

```sql
-- Run ANALYZE to update the sqlite_stat1 table
ANALYZE;

-- Verify statistics exist
SELECT * FROM sqlite_stat1;

-- ANALYZE specific table
ANALYZE users;

-- Optimize pragma (3.18+): runs ANALYZE only on tables that need it
PRAGMA optimize;

-- Run at connection close for automatic maintenance
-- (Language bindings can call this in a cleanup hook)
```

---

## Platform-Specific Issues

### NFS and Network Drives

**SQLite does not work reliably on network filesystems.** The file locking mechanisms
that SQLite depends on are not correctly implemented by NFS, SMB/CIFS, or most
distributed filesystems.

**Symptoms:**
- Intermittent "database is locked" errors.
- Silent data corruption.
- WAL mode doesn't work (shared memory file can't be shared).

**Solutions:**
1. **Don't use SQLite on network drives.** This is the official recommendation.
2. Use a client-server database (PostgreSQL, MySQL) instead.
3. If you must, use `PRAGMA locking_mode = EXCLUSIVE` (single-process only).
4. Consider LiteFS for distributed read replicas.

```sql
-- If you absolutely must use network storage (not recommended)
PRAGMA locking_mode = EXCLUSIVE;  -- prevents other connections
PRAGMA journal_mode = DELETE;     -- WAL doesn't work over NFS
```

### Android

**Common issues:**

1. **WAL mode and multi-process access:**
   Android's `SQLiteDatabase` uses WAL mode by default since API 16, but WAL doesn't
   work across multiple processes (e.g., ContentProvider in a different process).

   ```java
   // Enable WAL for single-process apps
   db.enableWriteAheadLogging();
   // Or for multi-process: use DELETE journal mode
   db.disableWriteAheadLogging();
   ```

2. **Database path:**
   Always use `context.getDatabasePath()`. Never use external storage or SD cards
   (FAT32 doesn't support file locking).

3. **Cursor window size:**
   Android limits cursor windows to 2 MB. Large queries fail with
   `CursorWindowAllocationException`.

   ```java
   // Paginate queries
   cursor = db.rawQuery("SELECT * FROM data LIMIT ? OFFSET ?",
                        new String[]{"100", String.valueOf(offset)});
   ```

4. **Room library pitfalls:**
   - Room's `@Transaction` annotation doesn't guarantee BEGIN IMMEDIATE.
   - Use `beginTransactionNonExclusive()` for WAL mode compatibility.
   - Test migrations with `MigrationTestHelper`.

### macOS and iOS

1. **App Sandbox:** On macOS, the database must be within the app's sandbox container.
2. **iOS background termination:** iOS can kill apps while SQLite is writing. Use
   `synchronous = FULL` for maximum safety, or WAL mode with `synchronous = NORMAL`.
3. **File protection:** iOS encrypts files at rest. Set the appropriate
   `NSFileProtectionKey` for your database file.

```swift
// iOS: set file protection
let dbURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("app.db")
try FileManager.default.setAttributes(
    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
    ofItemAtPath: dbURL.path
)
```

### Windows

1. **Antivirus interference:** Real-time scanning can cause spurious SQLITE_BUSY errors.
   Exclude the database directory from antivirus scanning.
2. **File name length:** Windows has a 260-character path limit (unless long paths
   are enabled). Keep database paths short.
3. **Mandatory file locking:** Windows uses mandatory locks (not advisory like Unix).
   This means a locked database file can't be deleted or renamed while open.
4. **Line endings in SQL scripts:** Use LF, not CRLF, in `.sql` files loaded via
   `.read` command.

### Docker and Containers

1. **Volume mounts:** Always use named volumes or bind mounts for the database file.
   Overlay filesystems do not support SQLite's locking correctly.

   ```yaml
   # docker-compose.yml
   volumes:
     - sqlite-data:/app/data  # named volume (correct)
   # NOT:
   #   - ./data:/app/data     # bind mount (usually ok, but test)
   ```

2. **File permissions:** The container user must own both the database file and its
   parent directory (SQLite creates temporary files in the same directory).

3. **tmpfs for temp storage:** Mount `/tmp` as tmpfs for faster temporary operations.

   ```yaml
   tmpfs:
     - /tmp:size=512M
   ```

4. **Read-only containers:** If using `read_only: true`, mount the database
   directory as a writable volume and set `SQLITE_TMPDIR` to a writable path.
