-- analytics-schema.sql
-- Complete analytics schema: events table, daily aggregation, materialized view
-- with proper partitioning, ordering, and TTL.

-- ============================================================================
-- 1. Raw Events Table (MergeTree)
-- ============================================================================
-- Primary fact table for raw event ingestion. Append-only.
-- Partitioned monthly, ordered for typical analytics queries.

CREATE TABLE IF NOT EXISTS analytics.events (
    -- Time dimensions
    event_date    Date DEFAULT toDate(event_time),
    event_time    DateTime64(3, 'UTC'),

    -- Entity identifiers
    user_id       UInt64,
    session_id    String,
    device_id     String DEFAULT '',

    -- Event attributes
    event_type    LowCardinality(String),
    event_name    LowCardinality(String),
    page_url      String DEFAULT '',
    referrer_url  String DEFAULT '',

    -- Denormalized user dimensions (avoid JOINs at query time)
    user_country  LowCardinality(String) DEFAULT '',
    user_plan     LowCardinality(String) DEFAULT '',
    platform      LowCardinality(String) DEFAULT '',

    -- Event payload
    properties    String DEFAULT '{}',

    -- Numeric measures
    revenue       Decimal(12, 4) DEFAULT 0,
    duration_ms   UInt32 DEFAULT 0,
    item_count    UInt16 DEFAULT 0
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_type, user_country, user_id, event_time)
PRIMARY KEY (event_type, user_country, user_id)
TTL event_date + INTERVAL 365 DAY DELETE,
    event_date + INTERVAL 90 DAY TO VOLUME 'cold'
SETTINGS
    index_granularity = 8192,
    min_bytes_for_wide_part = 10485760,
    storage_policy = 'default';

-- Data skipping indexes for columns not in the ordering key
ALTER TABLE analytics.events ADD INDEX IF NOT EXISTS idx_session session_id TYPE bloom_filter(0.01) GRANULARITY 4;
ALTER TABLE analytics.events ADD INDEX IF NOT EXISTS idx_page page_url TYPE ngrambf_v1(4, 256, 2, 0) GRANULARITY 4;
ALTER TABLE analytics.events ADD INDEX IF NOT EXISTS idx_event_name event_name TYPE set(100) GRANULARITY 2;


-- ============================================================================
-- 2. Daily Aggregation Table (AggregatingMergeTree)
-- ============================================================================
-- Pre-aggregated daily metrics. Uses AggregateFunction types for incremental merges.
-- Query with -Merge combinators (countMerge, sumMerge, uniqMerge, etc.)

CREATE TABLE IF NOT EXISTS analytics.daily_metrics (
    -- Dimensions
    day           Date,
    event_type    LowCardinality(String),
    user_country  LowCardinality(String),
    platform      LowCardinality(String),

    -- Aggregate states
    event_count   AggregateFunction(count, UInt64),
    unique_users  AggregateFunction(uniq, UInt64),
    unique_sessions AggregateFunction(uniq, String),
    total_revenue AggregateFunction(sum, Decimal(12, 4)),
    avg_duration  AggregateFunction(avg, UInt32),
    p50_duration  AggregateFunction(quantileTDigest(0.5), UInt32),
    p95_duration  AggregateFunction(quantileTDigest(0.95), UInt32),
    p99_duration  AggregateFunction(quantileTDigest(0.99), UInt32),
    max_duration  AggregateFunction(max, UInt32)
)
ENGINE = AggregatingMergeTree()
PARTITION BY toYYYYMM(day)
ORDER BY (event_type, user_country, platform, day)
TTL day + INTERVAL 730 DAY DELETE
SETTINGS index_granularity = 8192;


-- ============================================================================
-- 3. Materialized View (populates daily_metrics from events on INSERT)
-- ============================================================================
-- Automatically aggregates every batch inserted into events.
-- Data flows: INSERT into events → MV transforms → INSERT into daily_metrics.

CREATE MATERIALIZED VIEW IF NOT EXISTS analytics.daily_metrics_mv
TO analytics.daily_metrics
AS SELECT
    toDate(event_time) AS day,
    event_type,
    user_country,
    platform,

    countState()                         AS event_count,
    uniqState(user_id)                   AS unique_users,
    uniqState(session_id)                AS unique_sessions,
    sumState(revenue)                    AS total_revenue,
    avgState(duration_ms)                AS avg_duration,
    quantileTDigestState(0.5)(duration_ms)  AS p50_duration,
    quantileTDigestState(0.95)(duration_ms) AS p95_duration,
    quantileTDigestState(0.99)(duration_ms) AS p99_duration,
    maxState(duration_ms)                AS max_duration
FROM analytics.events
GROUP BY day, event_type, user_country, platform;


-- ============================================================================
-- 4. Querying the Aggregated Data
-- ============================================================================
-- Use -Merge combinators to finalize aggregate states.

-- Daily dashboard query
-- SELECT
--     day,
--     event_type,
--     countMerge(event_count)           AS events,
--     uniqMerge(unique_users)           AS users,
--     uniqMerge(unique_sessions)        AS sessions,
--     sumMerge(total_revenue)           AS revenue,
--     round(avgMerge(avg_duration), 0)  AS avg_duration_ms,
--     quantileTDigestMerge(0.95)(p95_duration) AS p95_ms
-- FROM analytics.daily_metrics
-- WHERE day >= today() - 30
-- GROUP BY day, event_type
-- ORDER BY day, event_type;

-- Weekly rollup (aggregate states merge across days)
-- SELECT
--     toStartOfWeek(day) AS week,
--     countMerge(event_count)  AS events,
--     uniqMerge(unique_users)  AS users,
--     sumMerge(total_revenue)  AS revenue
-- FROM analytics.daily_metrics
-- WHERE day >= today() - 90
-- GROUP BY week
-- ORDER BY week;


-- ============================================================================
-- 5. Projection on events table (alternative sort order)
-- ============================================================================
-- For queries that filter by user_id first.

ALTER TABLE analytics.events ADD PROJECTION IF NOT EXISTS proj_by_user (
    SELECT * ORDER BY (user_id, event_time)
);
-- Materialize after adding (backfills existing data):
-- ALTER TABLE analytics.events MATERIALIZE PROJECTION proj_by_user;


-- ============================================================================
-- 6. Hourly Funnel Table (SummingMergeTree)
-- ============================================================================
-- For funnel analysis: auto-sums step counts on merge.

CREATE TABLE IF NOT EXISTS analytics.funnel_steps (
    hour       DateTime,
    funnel_id  LowCardinality(String),
    step       UInt8,
    step_name  LowCardinality(String),
    user_count UInt64,
    drop_count UInt64
)
ENGINE = SummingMergeTree((user_count, drop_count))
PARTITION BY toYYYYMM(hour)
ORDER BY (funnel_id, step, hour);
