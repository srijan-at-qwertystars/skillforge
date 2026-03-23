-- production-pragmas.sql
-- Complete PRAGMA configuration for production SQLite databases.
-- Apply these settings at every connection open, before any queries.
-- Order matters: journal_mode should be set first.

-- ═══════════════════════════════════════════════════════════════
-- JOURNAL AND DURABILITY
-- ═══════════════════════════════════════════════════════════════

-- Enable Write-Ahead Logging for concurrent reads during writes.
-- Persists in the database file — only needs to be set once, but safe to repeat.
PRAGMA journal_mode = WAL;

-- NORMAL is safe with WAL mode and ~2x faster than FULL.
-- Use FULL only if you cannot tolerate any data loss on power failure.
PRAGMA synchronous = NORMAL;

-- ═══════════════════════════════════════════════════════════════
-- CONSTRAINTS AND SAFETY
-- ═══════════════════════════════════════════════════════════════

-- Enable foreign key enforcement (OFF by default — a common source of data bugs).
-- Must be set per-connection, does not persist.
PRAGMA foreign_keys = ON;

-- ═══════════════════════════════════════════════════════════════
-- LOCKING AND CONCURRENCY
-- ═══════════════════════════════════════════════════════════════

-- Wait up to 5 seconds when the database is locked instead of failing immediately.
-- Adjust based on your application's tolerance for write latency.
PRAGMA busy_timeout = 5000;

-- ═══════════════════════════════════════════════════════════════
-- PERFORMANCE: CACHE AND I/O
-- ═══════════════════════════════════════════════════════════════

-- Set page cache to 64 MB (negative value = KiB, so -64000 ≈ 64 MB).
-- Increase for read-heavy workloads; decrease for memory-constrained environments.
PRAGMA cache_size = -64000;

-- Enable memory-mapped I/O up to 256 MB for faster reads (zero-copy).
-- Set to 0 to disable. Not beneficial if DB is larger than available RAM.
-- Warning: a corrupt DB file can cause SIGBUS instead of an error code.
PRAGMA mmap_size = 268435456;

-- Store temporary tables and indexes in memory for faster sorting and grouping.
-- Use FILE (PRAGMA temp_store = 1) if temp data is too large for RAM.
PRAGMA temp_store = MEMORY;

-- ═══════════════════════════════════════════════════════════════
-- SPACE RECLAMATION
-- ═══════════════════════════════════════════════════════════════

-- Incrementally reclaim space from deleted rows. Set before creating tables,
-- or run VACUUM once after changing this setting.
-- INCREMENTAL (2) lets you control when pages are reclaimed via:
--   PRAGMA incremental_vacuum(N);  -- reclaim up to N pages
-- Use FULL (1) for automatic reclamation (more I/O on every DELETE).
PRAGMA auto_vacuum = INCREMENTAL;

-- ═══════════════════════════════════════════════════════════════
-- WAL MANAGEMENT
-- ═══════════════════════════════════════════════════════════════

-- Auto-checkpoint when WAL reaches 1000 pages (~4 MB with 4K pages). Default.
-- Increase for write-heavy workloads to reduce checkpoint frequency.
-- Set to 0 to disable auto-checkpoint (manage manually).
PRAGMA wal_autocheckpoint = 1000;

-- ═══════════════════════════════════════════════════════════════
-- OPTIONAL: READ-ONLY CONNECTIONS
-- ═══════════════════════════════════════════════════════════════

-- Uncomment for read-only connections (prevents accidental writes):
-- PRAGMA query_only = ON;

-- ═══════════════════════════════════════════════════════════════
-- OPTIONAL: APPLICATION-LEVEL SETTINGS
-- ═══════════════════════════════════════════════════════════════

-- Set an application ID to identify the database format (use a unique 32-bit int):
-- PRAGMA application_id = 0x12345678;

-- Set a user version for your own schema versioning:
-- PRAGMA user_version = 1;

-- ═══════════════════════════════════════════════════════════════
-- MAINTENANCE (run periodically, not at every connection open)
-- ═══════════════════════════════════════════════════════════════

-- Update query planner statistics. Run after bulk data changes.
-- ANALYZE;

-- Lightweight optimize: only re-analyzes tables with stale stats.
-- Safe to run at every connection close.
-- PRAGMA optimize;

-- Reclaim freelist pages (if auto_vacuum = INCREMENTAL):
-- PRAGMA incremental_vacuum(1000);

-- Truncate WAL file (reclaim disk space used by WAL):
-- PRAGMA wal_checkpoint(TRUNCATE);
