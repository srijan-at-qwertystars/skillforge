-- =============================================================================
-- pg_partman — Time-Based Partition Setup
-- =============================================================================
-- pg_partman automates the creation and maintenance of partitioned tables.
-- It handles creating future partitions ahead of time and optionally dropping
-- or detaching old ones based on a retention policy.
--
-- Prerequisites:
--   1. PostgreSQL 14+ (native partitioning + pg_partman 5.x)
--   2. pg_partman extension installed:
--        sudo apt install postgresql-<ver>-partman   (Debian/Ubuntu)
--        sudo yum install pg_partman_<ver>           (RHEL/CentOS)
--   3. If using the background worker (recommended), add to postgresql.conf:
--        shared_preload_libraries = 'pg_partman_bgw'
--        pg_partman_bgw.interval = 3600   -- run maintenance every hour
--        pg_partman_bgw.dbname = 'your_database'
-- =============================================================================


-- ---------------------------------------------------------------------------
-- Step 1: Create the pg_partman extension
-- ---------------------------------------------------------------------------
-- pg_partman stores its config in the 'partman' schema by default.
-- Create it in a dedicated schema to keep things organized.

CREATE SCHEMA IF NOT EXISTS partman;

CREATE EXTENSION IF NOT EXISTS pg_partman
    SCHEMA partman;

COMMENT ON EXTENSION pg_partman IS
    'Automated partition management for time and serial based tables.';


-- ---------------------------------------------------------------------------
-- Step 2: Create the parent (partitioned) table
-- ---------------------------------------------------------------------------
-- This example creates an events table partitioned by a timestamp column.
-- PostgreSQL declarative partitioning (PARTITION BY RANGE) is used.
--
-- Key design decisions:
--   • The partition key (created_at) MUST be part of the primary key
--     or any unique constraint.
--   • Use RANGE partitioning for time-series data; LIST for categorical.
--   • Indexes on the parent are automatically inherited by children.

CREATE TABLE IF NOT EXISTS public.events (
    id              bigint GENERATED ALWAYS AS IDENTITY,
    created_at      timestamptz NOT NULL DEFAULT now(),
    event_type      text        NOT NULL,
    user_id         bigint,
    payload         jsonb,

    -- Primary key must include the partition key column.
    PRIMARY KEY (id, created_at)
) PARTITION BY RANGE (created_at);

-- Create indexes that every partition will inherit.
-- These are automatically propagated to new child partitions.
CREATE INDEX IF NOT EXISTS idx_events_event_type
    ON public.events (event_type);

CREATE INDEX IF NOT EXISTS idx_events_user_id
    ON public.events (user_id)
    WHERE user_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_events_created_at
    ON public.events (created_at);


-- ---------------------------------------------------------------------------
-- Step 3: Configure pg_partman to manage the table
-- ---------------------------------------------------------------------------
-- create_parent() tells pg_partman:
--   • Which table to manage
--   • Which column to partition on
--   • The partition interval (daily, weekly, monthly, etc.)
--   • How many future partitions to pre-create
--
-- Arguments:
--   p_parent_table   — schema-qualified parent table name
--   p_control        — partition key column
--   p_interval       — partition interval as an ISO interval string
--   p_premake        — how many future partitions to keep ready
--   p_start_partition— optional: when to start the first partition
--
-- The function creates the initial set of child partitions immediately.

SELECT partman.create_parent(
    p_parent_table   := 'public.events',
    p_control        := 'created_at',
    p_interval       := 'P1D',           -- daily partitions (P1M = monthly, P7D = weekly)
    p_premake        := 7                 -- keep 7 future partitions ready
);

-- Verify the configuration was stored.
-- You can query this table at any time to review pg_partman settings.
-- SELECT * FROM partman.part_config WHERE parent_table = 'public.events';


-- ---------------------------------------------------------------------------
-- Step 4: Configure retention policy
-- ---------------------------------------------------------------------------
-- Tell pg_partman to automatically drop partitions older than a threshold.
--
-- Options for p_retention_schema:
--   • NULL (default): old partitions are DROPPED permanently.
--   • Set to a schema name: old partitions are DETACHED and moved to that
--     schema instead of dropped — useful for archiving to cold storage.
--
-- retention_keep_table:
--   • true:  detach the partition but keep the table for manual archival.
--   • false: drop the table entirely (data is permanently deleted).

UPDATE partman.part_config
SET
    retention           = '90 days',      -- keep 90 days of data
    retention_keep_table = false,          -- drop old partitions (set true to archive)
    infinite_time_partitions = true        -- always maintain partitions even if no data
WHERE
    parent_table = 'public.events';

-- If you want to archive instead of drop, create an archive schema:
-- CREATE SCHEMA IF NOT EXISTS events_archive;
-- UPDATE partman.part_config
-- SET retention_schema = 'events_archive',
--     retention_keep_table = true
-- WHERE parent_table = 'public.events';


-- ---------------------------------------------------------------------------
-- Step 5: Run initial maintenance
-- ---------------------------------------------------------------------------
-- Maintenance creates any missing partitions and applies the retention policy.
-- In production, the pg_partman_bgw background worker handles this
-- automatically at the interval configured in postgresql.conf.
--
-- You can also schedule this via cron if the background worker is not used:
--   */30 * * * *  psql -d mydb -c "SELECT partman.run_maintenance();"

SELECT partman.run_maintenance(
    p_parent_table := 'public.events',
    p_analyze      := true               -- ANALYZE new partitions for planner stats
);


-- ---------------------------------------------------------------------------
-- Step 6: Verify the setup
-- ---------------------------------------------------------------------------
-- List all child partitions created by pg_partman.

SELECT
    inhrelid::regclass  AS partition_name,
    pg_size_pretty(pg_relation_size(inhrelid)) AS size
FROM
    pg_inherits
WHERE
    inhparent = 'public.events'::regclass
ORDER BY
    inhrelid::regclass::text;


-- ---------------------------------------------------------------------------
-- Optional: Configure sub-partitioning
-- ---------------------------------------------------------------------------
-- For very high-volume tables you can sub-partition (e.g., daily by time,
-- then by hash on user_id).  This is an advanced use case.
--
-- SELECT partman.create_sub_parent(
--     p_top_parent     := 'public.events',
--     p_control        := 'user_id',
--     p_interval       := '4',             -- 4 hash partitions per daily partition
--     p_type           := 'range'          -- or 'list'
-- );


-- ---------------------------------------------------------------------------
-- Notes
-- ---------------------------------------------------------------------------
-- • Always INSERT into the parent table; PostgreSQL routes rows to the
--   correct child partition automatically.
--
-- • Queries that filter on the partition key (created_at) benefit from
--   partition pruning — only relevant partitions are scanned.
--
-- • Monitor pg_partman maintenance with:
--     SELECT * FROM partman.part_config;
--     SELECT * FROM partman.part_config_sub;   -- if using sub-partitions
--
-- • To change the retention period:
--     UPDATE partman.part_config
--     SET retention = '180 days'
--     WHERE parent_table = 'public.events';
--
-- • To stop managing a table (without dropping partitions):
--     SELECT partman.undo_partition(
--         p_parent_table := 'public.events',
--         p_keep_table   := true
--     );
