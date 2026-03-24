-- =============================================================================
-- PostgreSQL Event Store Schema
--
-- A production-ready schema for a custom event store.
-- Features: append-only events, optimistic concurrency, global ordering,
--           snapshots, projection checkpoints, outbox, dead letter queue.
--
-- Usage: psql -f event-store-schema.sql your_database
-- =============================================================================

BEGIN;

-- =============================================================================
-- Core: Event Streams
-- =============================================================================

-- Each aggregate instance is a stream identified by stream_id.
CREATE TABLE IF NOT EXISTS events (
    global_position   BIGSERIAL    NOT NULL,      -- Global ordering across all streams
    stream_id         TEXT         NOT NULL,       -- Aggregate type + ID (e.g., "order-abc123")
    version           INT          NOT NULL,       -- Per-stream sequence number (starts at 1)
    event_type        TEXT         NOT NULL,       -- e.g., "OrderCreated", "OrderConfirmed"
    data              JSONB        NOT NULL,       -- Event payload
    metadata          JSONB        NOT NULL DEFAULT '{}', -- causationId, correlationId, userId, etc.
    created_at        TIMESTAMPTZ  NOT NULL DEFAULT now(),

    PRIMARY KEY (stream_id, version)               -- Optimistic concurrency: unique per stream+version
);

-- Global position index for projections reading $all ordered
CREATE UNIQUE INDEX IF NOT EXISTS idx_events_global_position ON events (global_position);

-- Fast lookup by event type (useful for projections subscribing to specific events)
CREATE INDEX IF NOT EXISTS idx_events_type ON events (event_type);

-- Time-based queries (temporal queries, archival)
CREATE INDEX IF NOT EXISTS idx_events_created_at ON events (created_at);

-- =============================================================================
-- Optimistic Concurrency Helper Function
-- =============================================================================

-- Append events to a stream with optimistic concurrency check.
-- Raises an exception if expected_version doesn't match.
CREATE OR REPLACE FUNCTION append_events(
    p_stream_id       TEXT,
    p_expected_version INT,
    p_events          JSONB    -- Array of {event_type, data, metadata}
) RETURNS SETOF events AS $$
DECLARE
    current_version INT;
    event_record    JSONB;
    next_version    INT;
BEGIN
    -- Lock the stream to prevent concurrent appends
    PERFORM pg_advisory_xact_lock(hashtext(p_stream_id));

    -- Check current version
    SELECT COALESCE(MAX(version), 0) INTO current_version
    FROM events
    WHERE stream_id = p_stream_id;

    IF current_version != p_expected_version THEN
        RAISE EXCEPTION 'Concurrency conflict: expected version %, got %',
            p_expected_version, current_version
            USING ERRCODE = 'serialization_failure';
    END IF;

    -- Append each event
    next_version := current_version;
    FOR event_record IN SELECT * FROM jsonb_array_elements(p_events)
    LOOP
        next_version := next_version + 1;
        RETURN QUERY
        INSERT INTO events (stream_id, version, event_type, data, metadata)
        VALUES (
            p_stream_id,
            next_version,
            event_record->>'event_type',
            COALESCE(event_record->'data', '{}'),
            COALESCE(event_record->'metadata', '{}')
        )
        RETURNING *;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- Snapshots
-- =============================================================================

CREATE TABLE IF NOT EXISTS snapshots (
    stream_id       TEXT         NOT NULL PRIMARY KEY,
    version         INT          NOT NULL,       -- Event version at snapshot time
    schema_version  INT          NOT NULL DEFAULT 1, -- Snapshot format version
    state           JSONB        NOT NULL,       -- Serialized aggregate state
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- =============================================================================
-- Projection Checkpoints
-- =============================================================================

-- Each projection tracks its last processed global_position.
CREATE TABLE IF NOT EXISTS projection_checkpoints (
    projection_name          TEXT         NOT NULL PRIMARY KEY,
    last_processed_position  BIGINT       NOT NULL DEFAULT 0,
    updated_at               TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- =============================================================================
-- Outbox (Transactional Messaging)
-- =============================================================================

-- Write integration events in the same transaction as domain events.
-- A background worker publishes these to a message broker.
CREATE TABLE IF NOT EXISTS outbox (
    id            UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    event_type    TEXT         NOT NULL,
    payload       JSONB        NOT NULL,
    destination   TEXT         NOT NULL DEFAULT 'default', -- Topic/queue name
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),
    published_at  TIMESTAMPTZ,                              -- NULL = not yet published
    retry_count   INT          NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_outbox_unpublished
    ON outbox (created_at) WHERE published_at IS NULL;

-- =============================================================================
-- Dead Letter Queue
-- =============================================================================

-- Events that failed processing after max retries.
CREATE TABLE IF NOT EXISTS dead_letter_queue (
    id                UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    global_position   BIGINT       NOT NULL,
    stream_id         TEXT         NOT NULL,
    event_type        TEXT         NOT NULL,
    data              JSONB        NOT NULL,
    projection_name   TEXT         NOT NULL,
    error_message     TEXT         NOT NULL,
    error_stack       TEXT,
    retry_count       INT          NOT NULL DEFAULT 0,
    created_at        TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_dlq_projection ON dead_letter_queue (projection_name, created_at);

-- =============================================================================
-- Command Deduplication
-- =============================================================================

-- Tracks processed command IDs for idempotency.
-- Entries can be cleaned up after a retention period (e.g., 7 days).
CREATE TABLE IF NOT EXISTS processed_commands (
    command_id    TEXT         NOT NULL PRIMARY KEY,
    processed_at  TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_processed_commands_ttl ON processed_commands (processed_at);

-- =============================================================================
-- Notifications (for real-time subscriptions without polling)
-- =============================================================================

-- Trigger: Notify on new events appended.
CREATE OR REPLACE FUNCTION notify_new_event() RETURNS trigger AS $$
BEGIN
    PERFORM pg_notify('new_event', json_build_object(
        'global_position', NEW.global_position,
        'stream_id', NEW.stream_id,
        'event_type', NEW.event_type
    )::text);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_notify_new_event ON events;
CREATE TRIGGER trg_notify_new_event
    AFTER INSERT ON events
    FOR EACH ROW EXECUTE FUNCTION notify_new_event();

-- =============================================================================
-- Utility Views
-- =============================================================================

-- Stream summary: event counts per stream
CREATE OR REPLACE VIEW stream_summary AS
SELECT
    stream_id,
    COUNT(*) AS event_count,
    MIN(created_at) AS first_event_at,
    MAX(created_at) AS last_event_at,
    MAX(version) AS current_version
FROM events
GROUP BY stream_id;

-- Projection lag: how far behind each projection is
CREATE OR REPLACE VIEW projection_lag AS
SELECT
    pc.projection_name,
    pc.last_processed_position,
    (SELECT MAX(global_position) FROM events) AS store_head,
    (SELECT MAX(global_position) FROM events) - pc.last_processed_position AS lag,
    pc.updated_at AS last_updated
FROM projection_checkpoints pc;

COMMIT;
