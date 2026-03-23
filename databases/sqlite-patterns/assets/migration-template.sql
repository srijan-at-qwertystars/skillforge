-- migration-template.sql
-- Schema migration template with version tracking for SQLite.
-- Copy this template for each migration and fill in the UP and DOWN sections.

-- ═══════════════════════════════════════════════════════════════
-- MIGRATION METADATA
-- ═══════════════════════════════════════════════════════════════
-- Version:     002
-- Description: Add user profiles table and index
-- Author:      your_name
-- Date:        2024-01-15
-- Requires:    001
-- ═══════════════════════════════════════════════════════════════

-- ═══════════════════════════════════════════════════════════════
-- VERSION TRACKING TABLE (create once, reuse across all migrations)
-- ═══════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS _schema_migrations (
    version     INTEGER PRIMARY KEY,
    description TEXT NOT NULL,
    applied_at  TEXT NOT NULL DEFAULT (datetime('now')),
    checksum    TEXT  -- optional: hash of migration SQL for drift detection
);

-- ═══════════════════════════════════════════════════════════════
-- PRE-FLIGHT CHECK
-- Abort if this migration has already been applied.
-- ═══════════════════════════════════════════════════════════════

-- Uncomment and run before applying:
-- SELECT CASE
--     WHEN EXISTS (SELECT 1 FROM _schema_migrations WHERE version = 2)
--     THEN RAISE(ABORT, 'Migration 002 already applied')
-- END;

-- ═══════════════════════════════════════════════════════════════
-- UP MIGRATION
-- Wrap everything in a single transaction. DDL is transactional in SQLite.
-- ═══════════════════════════════════════════════════════════════

BEGIN;

-- --- Your schema changes go here ---

-- Example: Create a new table
CREATE TABLE user_profiles (
    user_id     INTEGER PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    bio         TEXT,
    avatar_url  TEXT,
    location    TEXT,
    website     TEXT,
    created_at  TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at  TEXT NOT NULL DEFAULT (datetime('now'))
) STRICT;

-- Example: Add a column to an existing table
-- ALTER TABLE users ADD COLUMN profile_complete INTEGER NOT NULL DEFAULT 0;

-- Example: Create an index
CREATE INDEX idx_user_profiles_location ON user_profiles(location)
    WHERE location IS NOT NULL;

-- Example: The 12-step table recreate pattern (for changes ALTER TABLE can't do)
-- 1.  CREATE TABLE new_table (...new schema...);
-- 2.  INSERT INTO new_table SELECT ...mapped columns... FROM old_table;
-- 3.  DROP TABLE old_table;
-- 4.  ALTER TABLE new_table RENAME TO old_table;
-- 5.  Recreate indexes
-- 6.  Recreate triggers
-- 7.  Recreate views

-- --- End of schema changes ---

-- Record this migration
INSERT INTO _schema_migrations (version, description)
VALUES (2, 'Add user profiles table and index');

COMMIT;

-- ═══════════════════════════════════════════════════════════════
-- DOWN MIGRATION (rollback)
-- Keep this section for reference. Run manually if rollback is needed.
-- ═══════════════════════════════════════════════════════════════

-- BEGIN;
-- DROP INDEX IF EXISTS idx_user_profiles_location;
-- DROP TABLE IF EXISTS user_profiles;
-- ALTER TABLE users DROP COLUMN profile_complete;
-- DELETE FROM _schema_migrations WHERE version = 2;
-- COMMIT;

-- ═══════════════════════════════════════════════════════════════
-- POST-MIGRATION VERIFICATION
-- Run these queries to verify the migration was applied correctly.
-- ═══════════════════════════════════════════════════════════════

-- Check migration was recorded:
-- SELECT * FROM _schema_migrations ORDER BY version;

-- Verify table exists:
-- SELECT name FROM sqlite_master WHERE type='table' AND name='user_profiles';

-- Verify index exists:
-- SELECT name FROM sqlite_master WHERE type='index' AND name='idx_user_profiles_location';

-- Verify column types (STRICT mode will enforce these):
-- PRAGMA table_info(user_profiles);

-- Full integrity check:
-- PRAGMA integrity_check;
-- PRAGMA foreign_key_check;
