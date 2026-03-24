-- =============================================================================
-- PostgreSQL Partitioning Templates
-- =============================================================================
-- Ready-to-use templates for range, list, and hash partitioning
-- with maintenance procedures and monitoring queries.
-- Compatible with PostgreSQL 12+ (some features require 14+)
-- =============================================================================


-- =============================================================================
-- 1. RANGE PARTITIONING — Time-Series Data
-- =============================================================================
-- Best for: logs, events, metrics, time-series data
-- Partition key: timestamp column
-- Strategy: monthly partitions with automated creation/archival

CREATE TABLE events (
    id          bigint GENERATED ALWAYS AS IDENTITY,
    created_at  timestamptz NOT NULL,
    event_type  text NOT NULL,
    user_id     bigint,
    payload     jsonb,
    CONSTRAINT events_pkey PRIMARY KEY (id, created_at)
) PARTITION BY RANGE (created_at);

-- Create initial partitions
CREATE TABLE events_2024_01 PARTITION OF events
    FOR VALUES FROM ('2024-01-01') TO ('2024-02-01');
CREATE TABLE events_2024_02 PARTITION OF events
    FOR VALUES FROM ('2024-02-01') TO ('2024-03-01');
CREATE TABLE events_2024_03 PARTITION OF events
    FOR VALUES FROM ('2024-03-01') TO ('2024-04-01');
CREATE TABLE events_2024_04 PARTITION OF events
    FOR VALUES FROM ('2024-04-01') TO ('2024-05-01');
CREATE TABLE events_2024_05 PARTITION OF events
    FOR VALUES FROM ('2024-05-01') TO ('2024-06-01');
CREATE TABLE events_2024_06 PARTITION OF events
    FOR VALUES FROM ('2024-06-01') TO ('2024-07-01');
-- ... create more as needed

-- Default partition for data outside defined ranges
CREATE TABLE events_default PARTITION OF events DEFAULT;

-- Indexes propagate from parent to all partitions
CREATE INDEX idx_events_user_id ON events (user_id);
CREATE INDEX idx_events_type ON events (event_type, created_at);
CREATE INDEX idx_events_payload ON events USING gin (payload jsonb_path_ops);

-- Function: Create next month's partition automatically
CREATE OR REPLACE FUNCTION create_monthly_partition(
    parent_table text,
    target_month date DEFAULT date_trunc('month', now() + interval '1 month')
) RETURNS text AS $$
DECLARE
    partition_name text;
    start_date date;
    end_date date;
BEGIN
    start_date := date_trunc('month', target_month);
    end_date := start_date + interval '1 month';
    partition_name := parent_table || '_' ||
                      to_char(start_date, 'YYYY_MM');

    -- Check if partition already exists
    IF EXISTS (SELECT 1 FROM pg_class WHERE relname = partition_name) THEN
        RETURN 'Partition ' || partition_name || ' already exists';
    END IF;

    EXECUTE format(
        'CREATE TABLE %I PARTITION OF %I FOR VALUES FROM (%L) TO (%L)',
        partition_name, parent_table, start_date, end_date
    );

    RETURN 'Created partition: ' || partition_name;
END;
$$ LANGUAGE plpgsql;

-- Usage: Create partitions 3 months ahead
-- SELECT create_monthly_partition('events', '2024-07-01'::date);
-- SELECT create_monthly_partition('events', '2024-08-01'::date);
-- SELECT create_monthly_partition('events', '2024-09-01'::date);

-- Function: Drop old partitions (archival)
CREATE OR REPLACE FUNCTION drop_old_partitions(
    parent_table text,
    retention_months int DEFAULT 12
) RETURNS text AS $$
DECLARE
    partition_record record;
    cutoff_date date;
    dropped_count int := 0;
BEGIN
    cutoff_date := date_trunc('month', now() - (retention_months || ' months')::interval);

    FOR partition_record IN
        SELECT inhrelid::regclass::text AS partition_name,
               pg_get_expr(c.relpartbound, c.oid) AS bound_expr
        FROM pg_inherits i
        JOIN pg_class c ON c.oid = i.inhrelid
        WHERE i.inhparent = parent_table::regclass
          AND c.relpartbound IS NOT NULL
          AND pg_get_expr(c.relpartbound, c.oid) NOT LIKE '%DEFAULT%'
    LOOP
        -- Extract the start date from partition bound
        -- Simple heuristic: if partition name contains date before cutoff
        IF partition_record.partition_name ~ to_char(cutoff_date - interval '1 year', 'YYYY') THEN
            EXECUTE format('ALTER TABLE %s DETACH PARTITION %s CONCURRENTLY',
                          parent_table, partition_record.partition_name);
            EXECUTE format('DROP TABLE %s', partition_record.partition_name);
            dropped_count := dropped_count + 1;
        END IF;
    END LOOP;

    RETURN 'Dropped ' || dropped_count || ' partitions older than ' || cutoff_date;
END;
$$ LANGUAGE plpgsql;


-- =============================================================================
-- 2. LIST PARTITIONING — Categorical Data
-- =============================================================================
-- Best for: multi-tenant, regional data, status-based routing
-- Partition key: categorical column (region, tenant_id, etc.)

CREATE TABLE orders (
    id          bigint GENERATED ALWAYS AS IDENTITY,
    region      text NOT NULL,
    customer_id bigint NOT NULL,
    total       numeric(12,2) NOT NULL,
    status      text NOT NULL DEFAULT 'pending',
    created_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT orders_pkey PRIMARY KEY (id, region)
) PARTITION BY LIST (region);

-- Regional partitions
CREATE TABLE orders_us_east PARTITION OF orders
    FOR VALUES IN ('us-east-1', 'us-east-2');

CREATE TABLE orders_us_west PARTITION OF orders
    FOR VALUES IN ('us-west-1', 'us-west-2');

CREATE TABLE orders_eu_west PARTITION OF orders
    FOR VALUES IN ('eu-west-1', 'eu-west-2', 'eu-central-1');

CREATE TABLE orders_ap PARTITION OF orders
    FOR VALUES IN ('ap-southeast-1', 'ap-northeast-1');

-- Default partition for new/unknown regions
CREATE TABLE orders_other PARTITION OF orders DEFAULT;

-- Indexes
CREATE INDEX idx_orders_customer ON orders (customer_id);
CREATE INDEX idx_orders_status ON orders (status, created_at);
CREATE INDEX idx_orders_created ON orders (created_at);


-- =============================================================================
-- 3. HASH PARTITIONING — Even Distribution
-- =============================================================================
-- Best for: high-write tables with no natural partition key, even load distribution
-- Partition key: UUID, ID, or any column needing even spread

CREATE TABLE sessions (
    id          uuid NOT NULL DEFAULT gen_random_uuid(),
    user_id     bigint NOT NULL,
    data        jsonb,
    created_at  timestamptz NOT NULL DEFAULT now(),
    expires_at  timestamptz NOT NULL,
    CONSTRAINT sessions_pkey PRIMARY KEY (id)
) PARTITION BY HASH (id);

-- Create hash partitions (power of 2 is recommended: 4, 8, 16, 32)
CREATE TABLE sessions_p0 PARTITION OF sessions
    FOR VALUES WITH (MODULUS 8, REMAINDER 0);
CREATE TABLE sessions_p1 PARTITION OF sessions
    FOR VALUES WITH (MODULUS 8, REMAINDER 1);
CREATE TABLE sessions_p2 PARTITION OF sessions
    FOR VALUES WITH (MODULUS 8, REMAINDER 2);
CREATE TABLE sessions_p3 PARTITION OF sessions
    FOR VALUES WITH (MODULUS 8, REMAINDER 3);
CREATE TABLE sessions_p4 PARTITION OF sessions
    FOR VALUES WITH (MODULUS 8, REMAINDER 4);
CREATE TABLE sessions_p5 PARTITION OF sessions
    FOR VALUES WITH (MODULUS 8, REMAINDER 5);
CREATE TABLE sessions_p6 PARTITION OF sessions
    FOR VALUES WITH (MODULUS 8, REMAINDER 6);
CREATE TABLE sessions_p7 PARTITION OF sessions
    FOR VALUES WITH (MODULUS 8, REMAINDER 7);

-- Indexes
CREATE INDEX idx_sessions_user ON sessions (user_id);
CREATE INDEX idx_sessions_expires ON sessions (expires_at);


-- =============================================================================
-- 4. SUB-PARTITIONING — Multi-Dimensional
-- =============================================================================
-- Best for: data that needs both temporal and categorical partitioning
-- Example: range by month, then list by tenant

CREATE TABLE tenant_events (
    id          bigint GENERATED ALWAYS AS IDENTITY,
    tenant_id   text NOT NULL,
    created_at  timestamptz NOT NULL,
    event_type  text NOT NULL,
    data        jsonb,
    CONSTRAINT tenant_events_pkey PRIMARY KEY (id, tenant_id, created_at)
) PARTITION BY RANGE (created_at);

-- Top-level: monthly partitions, each sub-partitioned by tenant
CREATE TABLE tenant_events_2024_01 PARTITION OF tenant_events
    FOR VALUES FROM ('2024-01-01') TO ('2024-02-01')
    PARTITION BY LIST (tenant_id);

CREATE TABLE tenant_events_2024_01_acme PARTITION OF tenant_events_2024_01
    FOR VALUES IN ('acme');
CREATE TABLE tenant_events_2024_01_globex PARTITION OF tenant_events_2024_01
    FOR VALUES IN ('globex');
CREATE TABLE tenant_events_2024_01_other PARTITION OF tenant_events_2024_01
    DEFAULT;

-- Repeat for each month...
-- (Use pg_partman or a custom function for automation)


-- =============================================================================
-- 5. PARTITION MONITORING QUERIES
-- =============================================================================

-- List all partitions of a table with their sizes
SELECT
    parent.relname AS parent_table,
    child.relname AS partition_name,
    pg_size_pretty(pg_relation_size(child.oid)) AS data_size,
    pg_size_pretty(pg_total_relation_size(child.oid)) AS total_size,
    pg_get_expr(child.relpartbound, child.oid) AS partition_bound,
    (SELECT count(*) FROM pg_stat_user_tables WHERE relname = child.relname) AS has_stats
FROM pg_inherits i
JOIN pg_class parent ON parent.oid = i.inhparent
JOIN pg_class child ON child.oid = i.inhrelid
WHERE parent.relname = 'events'  -- Change to your table name
ORDER BY child.relname;

-- Partition row counts (approximate from statistics)
SELECT
    child.relname AS partition_name,
    child.reltuples::bigint AS approx_row_count,
    pg_size_pretty(pg_relation_size(child.oid)) AS data_size
FROM pg_inherits i
JOIN pg_class parent ON parent.oid = i.inhparent
JOIN pg_class child ON child.oid = i.inhrelid
WHERE parent.relname = 'events'  -- Change to your table name
ORDER BY child.relname;

-- Verify partition pruning is working
-- Run EXPLAIN on a query with partition key filter:
-- EXPLAIN (ANALYZE, COSTS OFF)
-- SELECT * FROM events WHERE created_at >= '2024-03-01' AND created_at < '2024-04-01';
-- Should show: only relevant partition scanned, others pruned


-- =============================================================================
-- 6. PARTITION MAINTENANCE PROCEDURES
-- =============================================================================

-- Safely attach a pre-existing table as a partition
-- Step 1: Add constraint matching partition bounds (avoids full table scan)
-- ALTER TABLE events_staging ADD CONSTRAINT chk_date
--     CHECK (created_at >= '2024-07-01' AND created_at < '2024-08-01');
-- Step 2: Attach (fast because constraint proves data fits)
-- ALTER TABLE events ATTACH PARTITION events_staging
--     FOR VALUES FROM ('2024-07-01') TO ('2024-08-01');

-- Safely detach a partition for archival (PG14+ CONCURRENTLY)
-- ALTER TABLE events DETACH PARTITION events_2023_01 CONCURRENTLY;
-- The table events_2023_01 now exists as a standalone table.

-- Archive and clean up
-- pg_dump -t events_2023_01 mydb | gzip > /archive/events_2023_01.sql.gz
-- DROP TABLE events_2023_01;

-- Schedule partition maintenance with pg_cron
-- CREATE EXTENSION IF NOT EXISTS pg_cron;
-- SELECT cron.schedule('create-partitions', '0 0 15 * *',
--     $$SELECT create_monthly_partition('events')$$);
-- SELECT cron.schedule('drop-old-partitions', '0 2 1 * *',
--     $$SELECT drop_old_partitions('events', 12)$$);
