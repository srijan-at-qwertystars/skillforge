-- =============================================================================
-- Transactional Outbox Pattern: Schema + Polling Query
--
-- Purpose: Guarantee reliable event publishing alongside database writes.
-- Write domain events to the outbox table in the same transaction as
-- business data changes. A separate poller or CDC connector reads
-- unpublished events and publishes to the message broker.
--
-- Supports: PostgreSQL (primary), MySQL (noted where different)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. OUTBOX TABLE
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS outbox (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    aggregate_type  VARCHAR(255) NOT NULL,     -- e.g., 'Order', 'Payment', 'Inventory'
    aggregate_id    VARCHAR(255) NOT NULL,     -- e.g., 'ord-123'
    event_type      VARCHAR(255) NOT NULL,     -- e.g., 'OrderCreated', 'PaymentCharged'
    payload         JSONB NOT NULL,            -- Event data (MySQL: use JSON type)
    metadata        JSONB DEFAULT '{}',        -- Trace IDs, correlation IDs, headers
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    published_at    TIMESTAMPTZ,               -- NULL = not yet published
    retry_count     INT NOT NULL DEFAULT 0,
    last_error      TEXT
);

-- Index for the polling query (unpublished events, ordered by creation)
CREATE INDEX IF NOT EXISTS idx_outbox_unpublished
    ON outbox (created_at ASC)
    WHERE published_at IS NULL;

-- Index for cleanup of old published events
CREATE INDEX IF NOT EXISTS idx_outbox_published
    ON outbox (published_at ASC)
    WHERE published_at IS NOT NULL;

-- Index for aggregate lookups (debugging, replay)
CREATE INDEX IF NOT EXISTS idx_outbox_aggregate
    ON outbox (aggregate_type, aggregate_id, created_at DESC);


-- ---------------------------------------------------------------------------
-- 2. EXAMPLE: WRITING TO OUTBOX IN A TRANSACTION
-- ---------------------------------------------------------------------------
-- This demonstrates the atomic write pattern: business data + outbox event
-- in a single transaction.

BEGIN;

-- Step 1: Write business data
INSERT INTO orders (id, customer_id, status, total_amount, currency)
VALUES ('ord-123', 'cust-456', 'CREATED', 99.99, 'USD');

-- Step 2: Write outbox event in the SAME transaction
INSERT INTO outbox (aggregate_type, aggregate_id, event_type, payload, metadata)
VALUES (
    'Order',
    'ord-123',
    'OrderCreated',
    jsonb_build_object(
        'orderId', 'ord-123',
        'customerId', 'cust-456',
        'status', 'CREATED',
        'totalAmount', 99.99,
        'currency', 'USD',
        'items', jsonb_build_array(
            jsonb_build_object('productId', 'prod-789', 'quantity', 2, 'price', 49.995)
        )
    ),
    jsonb_build_object(
        'traceId', 'abc-def-123',
        'correlationId', 'req-789',
        'source', 'order-service',
        'schemaVersion', 1
    )
);

COMMIT;
-- Both writes succeed or both fail. No dual-write risk.


-- ---------------------------------------------------------------------------
-- 3. POLLING QUERY (for poller-based publishing)
-- ---------------------------------------------------------------------------
-- Run this periodically (e.g., every 100ms–1s) to pick up unpublished events.
-- Uses FOR UPDATE SKIP LOCKED for safe concurrent polling.

-- Fetch batch of unpublished events
SELECT id, aggregate_type, aggregate_id, event_type, payload, metadata, created_at
FROM outbox
WHERE published_at IS NULL
  AND retry_count < 5                -- Skip permanently failed events
ORDER BY created_at ASC
LIMIT 100
FOR UPDATE SKIP LOCKED;             -- Safe for concurrent pollers

-- After successful publish to broker, mark as published:
UPDATE outbox
SET published_at = NOW()
WHERE id = ANY($1::uuid[]);          -- $1 = array of published event IDs

-- On publish failure, increment retry count:
UPDATE outbox
SET retry_count = retry_count + 1,
    last_error = $2                  -- $2 = error message
WHERE id = $1;                       -- $1 = failed event ID


-- ---------------------------------------------------------------------------
-- 4. CLEANUP: Remove old published events
-- ---------------------------------------------------------------------------
-- Run daily to prevent outbox table growth.
-- Keep published events for N days for debugging, then delete.

DELETE FROM outbox
WHERE published_at IS NOT NULL
  AND published_at < NOW() - INTERVAL '7 days';


-- ---------------------------------------------------------------------------
-- 5. DEAD LETTER: Move permanently failed events
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS outbox_dead_letter (
    id              UUID PRIMARY KEY,
    aggregate_type  VARCHAR(255) NOT NULL,
    aggregate_id    VARCHAR(255) NOT NULL,
    event_type      VARCHAR(255) NOT NULL,
    payload         JSONB NOT NULL,
    metadata        JSONB DEFAULT '{}',
    created_at      TIMESTAMPTZ NOT NULL,
    failed_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    retry_count     INT NOT NULL,
    last_error      TEXT,
    resolved_at     TIMESTAMPTZ            -- Set when manually resolved
);

-- Move events that exceeded max retries
INSERT INTO outbox_dead_letter (id, aggregate_type, aggregate_id, event_type, payload, metadata, created_at, retry_count, last_error)
SELECT id, aggregate_type, aggregate_id, event_type, payload, metadata, created_at, retry_count, last_error
FROM outbox
WHERE published_at IS NULL
  AND retry_count >= 5;

DELETE FROM outbox
WHERE published_at IS NULL
  AND retry_count >= 5;


-- ---------------------------------------------------------------------------
-- 6. IDEMPOTENT CONSUMER TABLE (pair with outbox on consumer side)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS processed_events (
    event_id        UUID PRIMARY KEY,
    event_type      VARCHAR(255) NOT NULL,
    processed_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    result          JSONB                   -- Cached response for deduplication
);

-- TTL cleanup: remove entries older than retention window
CREATE INDEX IF NOT EXISTS idx_processed_events_ttl
    ON processed_events (processed_at ASC);

DELETE FROM processed_events
WHERE processed_at < NOW() - INTERVAL '72 hours';

-- Consumer deduplication check:
-- SELECT 1 FROM processed_events WHERE event_id = $1;
-- If found → skip processing, return cached result
-- If not found → process event, then INSERT into processed_events


-- ---------------------------------------------------------------------------
-- 7. MONITORING QUERIES
-- ---------------------------------------------------------------------------

-- Outbox backlog (should be near 0 in healthy system)
SELECT COUNT(*) AS pending_events,
       MIN(created_at) AS oldest_pending,
       EXTRACT(EPOCH FROM (NOW() - MIN(created_at))) AS max_lag_seconds
FROM outbox
WHERE published_at IS NULL;

-- Events by type (last 24 hours)
SELECT event_type,
       COUNT(*) AS total,
       COUNT(*) FILTER (WHERE published_at IS NOT NULL) AS published,
       COUNT(*) FILTER (WHERE published_at IS NULL) AS pending,
       COUNT(*) FILTER (WHERE retry_count > 0) AS retried
FROM outbox
WHERE created_at > NOW() - INTERVAL '24 hours'
GROUP BY event_type
ORDER BY total DESC;

-- Dead letter queue size
SELECT COUNT(*) AS dead_letter_count,
       COUNT(*) FILTER (WHERE resolved_at IS NULL) AS unresolved
FROM outbox_dead_letter;
