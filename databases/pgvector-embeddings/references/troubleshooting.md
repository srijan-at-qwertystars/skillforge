# pgvector Troubleshooting Guide

## Table of Contents

- [Index Build Running Out of Memory](#index-build-running-out-of-memory)
- [Poor Recall After Index Build](#poor-recall-after-index-build)
- [Slow Queries on Large Datasets](#slow-queries-on-large-datasets)
- [Dimension Mismatch Errors](#dimension-mismatch-errors)
- [Extension Version Upgrade Path](#extension-version-upgrade-path)
- [VACUUM and Index Maintenance](#vacuum-and-index-maintenance)
- [Connection Pooling with pgvector](#connection-pooling-with-pgvector)
- [Other Common Issues](#other-common-issues)

---

## Index Build Running Out of Memory

### Symptoms

- `ERROR: out of memory` during `CREATE INDEX`
- OOM killer terminates PostgreSQL process
- Index build hangs or is extremely slow (disk spill)

### Root Cause

HNSW index builds load the entire graph into memory. The memory required depends on row count, dimensions, and the `m` parameter.

### Memory Estimation

```
HNSW memory ≈ rows × (dims × 4 bytes + m × 2 × 8 bytes + overhead)

Examples (m=16):
  1M × 1536 dims ≈ 6.5 GB
  5M × 1536 dims ≈ 32 GB
  1M × 768 dims  ≈ 3.5 GB
  1M × 3072 dims ≈ 12.5 GB
```

### Solutions

**1. Increase `maintenance_work_mem`**

```sql
-- Set high enough for the index build, then reset
SET maintenance_work_mem = '8GB';  -- or higher
CREATE INDEX CONCURRENTLY ON items USING hnsw (embedding vector_cosine_ops);
RESET maintenance_work_mem;
```

This is a session-level setting — it won't affect other connections.

**2. Use parallel workers to share the load**

```sql
SET max_parallel_maintenance_workers = 7;
```

**3. Build index with fewer connections active**

Other sessions competing for memory can cause OOM. Schedule index builds during low-traffic periods.

**4. Use IVFFlat instead (lower memory)**

IVFFlat requires much less memory than HNSW:

```sql
SET maintenance_work_mem = '2GB';
CREATE INDEX ON items USING ivfflat (embedding vector_cosine_ops) WITH (lists = 1000);
```

**5. Reduce dimensions**

If your embedding model supports Matryoshka (OpenAI text-embedding-3-*), store truncated vectors:

```sql
-- Store 256-dim instead of 3072-dim
ALTER TABLE items ADD COLUMN embedding_small vector(256);
UPDATE items SET embedding_small = (embedding::real[])[1:256]::vector(256);
CREATE INDEX ON items USING hnsw (embedding_small vector_cosine_ops);
```

**6. Use halfvec to halve index memory**

```sql
ALTER TABLE items ADD COLUMN embedding_half halfvec(1536);
UPDATE items SET embedding_half = embedding::halfvec(1536);
CREATE INDEX ON items USING hnsw (embedding_half halfvec_cosine_ops);
```

### Monitoring Build Progress

```sql
SELECT phase, tuples_done, tuples_total,
       ROUND(100.0 * tuples_done / NULLIF(tuples_total, 0), 1) AS pct_complete,
       blocks_done, blocks_total
FROM pg_stat_progress_create_index;
```

---

## Poor Recall After Index Build

### Symptoms

- ANN queries return results that are clearly not the nearest neighbors
- Recall@10 measured below 0.90
- Known-relevant items don't appear in results

### Diagnosis

Compare ANN results against exact brute-force search:

```sql
-- Brute force (disable index)
SET enable_indexscan = off;
SET enable_bitmapscan = off;
SELECT id, embedding <=> $1 AS distance FROM items ORDER BY distance LIMIT 10;

-- ANN (re-enable index)
RESET enable_indexscan;
RESET enable_bitmapscan;
SELECT id, embedding <=> $1 AS distance FROM items ORDER BY distance LIMIT 10;
```

### Solutions for HNSW

**1. Increase `ef_search`**

```sql
SET hnsw.ef_search = 200;  -- default is 40
-- Try 100, 200, 400 and measure recall
```

This is the single most impactful knob for HNSW recall.

**2. Rebuild with higher `ef_construction`**

```sql
DROP INDEX idx_items_embedding;
CREATE INDEX idx_items_embedding ON items
    USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 256);  -- was 64
```

Higher `ef_construction` builds a better graph. Must be ≥ 2 × m.

**3. Increase `m`**

```sql
-- Rebuild with higher connectivity
CREATE INDEX ON items USING hnsw (embedding vector_cosine_ops)
    WITH (m = 32, ef_construction = 128);
```

### Solutions for IVFFlat

**1. Increase `probes`**

```sql
SET ivfflat.probes = 20;  -- default is 1
-- Try 10, 20, 50 — higher = better recall, slower queries
```

**2. Rebuild with appropriate `lists`**

```sql
-- Check current lists
SELECT reloptions FROM pg_class WHERE relname = 'idx_items_embedding';

-- Rebuild with better lists count (sqrt of row count)
SELECT COUNT(*) FROM items;  -- e.g., 500,000
-- lists should be ~707 for 500K rows
REINDEX INDEX CONCURRENTLY idx_items_embedding;
```

**3. Rebuild after significant data changes**

IVFFlat clusters become stale when data distribution changes:

```sql
REINDEX INDEX CONCURRENTLY idx_items_embedding;
```

**4. Check for empty/near-empty table during build**

IVFFlat needs representative data to build good clusters. If built on < 1000 rows and table grew to millions, recall will be terrible. Solution: rebuild.

---

## Slow Queries on Large Datasets

### Diagnosis Checklist

```sql
-- 1. Check if index exists
SELECT indexname, indexdef FROM pg_indexes WHERE tablename = 'items';

-- 2. Check if index is being used
EXPLAIN (ANALYZE, BUFFERS) SELECT id FROM items ORDER BY embedding <=> $1 LIMIT 10;
-- Look for "Index Scan using hnsw..." vs "Seq Scan"

-- 3. Check table and index sizes
SELECT pg_size_pretty(pg_total_relation_size('items')) AS total,
       pg_size_pretty(pg_table_size('items')) AS table_only,
       pg_size_pretty(pg_indexes_size('items')) AS indexes;

-- 4. Check for bloat
SELECT n_dead_tup, n_live_tup, last_vacuum, last_autovacuum
FROM pg_stat_user_tables WHERE relname = 'items';
```

### Common Causes and Fixes

**1. No index — queries do sequential scan**

```sql
CREATE INDEX CONCURRENTLY ON items USING hnsw (embedding vector_cosine_ops);
```

**2. Planner chooses seq scan over index scan**

For small tables (< ~10K rows), PostgreSQL may prefer a sequential scan. Force index use to test:

```sql
SET enable_seqscan = off;
EXPLAIN ANALYZE SELECT ... ORDER BY embedding <=> $1 LIMIT 10;
RESET enable_seqscan;
```

If the index scan is faster, increase `random_page_cost` or lower table statistics target:

```sql
SET random_page_cost = 1.1;  -- default 4.0, lower for SSDs
```

**3. Index not in memory (cold cache)**

```sql
CREATE EXTENSION IF NOT EXISTS pg_prewarm;
SELECT pg_prewarm('idx_items_embedding');
```

**4. Too many dead tuples**

```sql
VACUUM ANALYZE items;
-- For HNSW, dead tuples in the index cause extra hops
```

**5. Over-fetching with high LIMIT**

ANN indexes are optimized for small LIMIT (10–100). For LIMIT > 1000, consider:
- Partitioning to reduce search space
- Two-stage search (coarse binary → precise re-rank)

**6. Wrong distance function**

Ensure the query operator matches the index ops class:

```sql
-- Index built with vector_cosine_ops
CREATE INDEX ON items USING hnsw (embedding vector_cosine_ops);

-- Query MUST use <=> (cosine), NOT <-> (L2) or <#> (inner product)
SELECT * FROM items ORDER BY embedding <=> $1 LIMIT 10;  -- ✓ Uses index
SELECT * FROM items ORDER BY embedding <-> $1 LIMIT 10;  -- ✗ Seq scan!
```

**7. Filtered queries returning few results**

```sql
-- Enable iterative scan (pgvector 0.8+)
SET hnsw.iterative_scan = relaxed_order;
SET hnsw.max_scan_tuples = 20000;
```

---

## Dimension Mismatch Errors

### Symptoms

```
ERROR: expected 1536 dimensions, not 768
ERROR: different vector dimensions 1536 and 3072
```

### Common Causes

1. **Wrong embedding model** — switched from ada-002 (1536) to text-embedding-3-small (1536) or text-embedding-3-large (3072) without updating the column.

2. **Truncated embeddings** — API returned different dimensions than expected.

3. **Mixed models in same column** — different documents embedded with different models.

### Solutions

**Check column dimension:**
```sql
SELECT column_name, udt_name,
       character_maximum_length AS dimension
FROM information_schema.columns
WHERE table_name = 'items' AND udt_name = 'vector';
```

**Verify embedding dimensions before insert:**
```python
embedding = get_embedding(text)
assert len(embedding) == 1536, f"Expected 1536 dims, got {len(embedding)}"
```

**Migrate to new dimension:**
```sql
-- Add new column with correct dimensions
ALTER TABLE items ADD COLUMN embedding_new vector(3072);

-- Re-embed all content (application code needed)
-- Then swap columns
ALTER TABLE items DROP COLUMN embedding;
ALTER TABLE items RENAME COLUMN embedding_new TO embedding;
```

**Use Matryoshka truncation for dimension reduction:**
```sql
-- OpenAI text-embedding-3-large supports truncation to any size
-- Store at 1536 instead of 3072
ALTER TABLE items ALTER COLUMN embedding TYPE vector(1536);
-- Re-embed with dimensions=1536 parameter in the API call
```

---

## Extension Version Upgrade Path

### Check Current Version

```sql
SELECT extversion FROM pg_extension WHERE extname = 'vector';
SELECT * FROM pg_available_extensions WHERE name = 'vector';
```

### Upgrade Process

```bash
# 1. Install new pgvector version on the server
cd /tmp && git clone --branch v0.8.0 https://github.com/pgvector/pgvector.git
cd pgvector && make && sudo make install

# 2. Update the extension in each database
psql -d mydb -c "ALTER EXTENSION vector UPDATE;"
```

### Version Compatibility

| pgvector | PostgreSQL | Key Features |
|----------|-----------|--------------|
| 0.5.0 | 13–16 | HNSW indexes, halfvec |
| 0.6.0 | 13–16 | Binary quantization, sparsevec |
| 0.7.0 | 13–17 | Parallel HNSW build improvements, iterative scan (experimental) |
| 0.8.0 | 13–17 | Iterative scan stable, improved memory efficiency |

### Important Upgrade Notes

- **0.4 → 0.5:** HNSW index format changed. Rebuild all HNSW indexes after upgrade.
- **0.6+:** No index rebuild required for upgrades within 0.6+.
- Always run `REINDEX` on vector indexes after a major version upgrade if the release notes mention index format changes.

```sql
-- Rebuild all vector indexes after upgrade
DO $$
DECLARE r RECORD;
BEGIN
    FOR r IN SELECT indexname FROM pg_indexes
             WHERE indexdef LIKE '%hnsw%' OR indexdef LIKE '%ivfflat%'
    LOOP
        EXECUTE format('REINDEX INDEX CONCURRENTLY %I', r.indexname);
    END LOOP;
END $$;
```

---

## VACUUM and Index Maintenance

### Why VACUUM Matters for pgvector

Dead tuples in the heap cause HNSW to traverse dead graph nodes, wasting I/O and increasing latency. IVFFlat has similar issues — dead entries bloat clusters.

### VACUUM Best Practices

```sql
-- Manual vacuum after bulk deletes/updates
VACUUM ANALYZE items;

-- Full vacuum to reclaim disk space (locks table!)
VACUUM FULL items;

-- Check autovacuum is running
SELECT relname, n_dead_tup, last_vacuum, last_autovacuum
FROM pg_stat_user_tables
WHERE relname = 'items';
```

### Autovacuum Tuning for Vector Tables

Vector tables tend to be large, and autovacuum may not run frequently enough:

```sql
-- Lower the autovacuum threshold for this table
ALTER TABLE items SET (
    autovacuum_vacuum_threshold = 1000,
    autovacuum_vacuum_scale_factor = 0.01,  -- default 0.2
    autovacuum_analyze_threshold = 500,
    autovacuum_analyze_scale_factor = 0.005
);
```

### Index Maintenance

**HNSW:** No periodic rebuild needed. Handles inserts/deletes via tombstoning. VACUUM cleans up dead entries.

**IVFFlat:** Clusters become stale as data changes. Rebuild periodically:

```sql
-- Rebuild IVFFlat after significant data changes (>20% new data)
REINDEX INDEX CONCURRENTLY idx_items_ivfflat;

-- Schedule as a cron job
-- 0 3 * * 0 psql -d mydb -c "REINDEX INDEX CONCURRENTLY idx_items_ivfflat;"
```

### Monitoring Index Health

```sql
-- Index bloat estimate
SELECT indexrelid::regclass AS index_name,
       pg_size_pretty(pg_relation_size(indexrelid)) AS size,
       idx_scan AS scans,
       idx_tup_read AS tuples_read,
       idx_tup_fetch AS tuples_fetched
FROM pg_stat_user_indexes
WHERE relname = 'items';
```

---

## Connection Pooling with pgvector

### The Problem

pgvector query-time settings (`hnsw.ef_search`, `ivfflat.probes`, `hnsw.iterative_scan`) are session-level (`SET`). Connection poolers (PgBouncer, pgcat) in **transaction mode** reset session state between transactions.

### Symptoms

- `ef_search` resets to default (40) between queries
- Recall drops unpredictably
- `SET` commands seem to have no effect

### Solutions

**1. Use `SET LOCAL` (transaction-scoped)**

```sql
BEGIN;
SET LOCAL hnsw.ef_search = 200;
SELECT * FROM items ORDER BY embedding <=> $1 LIMIT 10;
COMMIT;
```

`SET LOCAL` scopes the setting to the current transaction, which works correctly with transaction-mode pooling.

**2. Use function with SET clause**

```sql
CREATE OR REPLACE FUNCTION search_items(query_vec vector(1536), k int)
RETURNS TABLE(id bigint, content text, distance float)
LANGUAGE sql STABLE
SET hnsw.ef_search = 200  -- embedded in function definition
AS $$
    SELECT id, content, embedding <=> query_vec AS distance
    FROM items
    ORDER BY embedding <=> query_vec
    LIMIT k;
$$;
```

**3. Configure PgBouncer to preserve settings**

In `pgbouncer.ini`:
```ini
; Session mode preserves SET commands (but limits connection sharing)
pool_mode = session

; Or keep transaction mode but set defaults in postgresql.conf
; ALTER SYSTEM SET hnsw.ef_search = 200;
```

**4. Set server-wide defaults**

```sql
-- Set default ef_search for all connections
ALTER SYSTEM SET hnsw.ef_search = 200;
SELECT pg_reload_conf();
```

### PgBouncer vs pgcat vs Supavisor

| Pooler | Transaction Mode SET Support | Recommendation |
|--------|------------------------------|----------------|
| PgBouncer | No — use `SET LOCAL` or functions | Most common, use `SET LOCAL` |
| pgcat | No — same as PgBouncer | Use `SET LOCAL` |
| Supavisor | No — same behavior | Use `SET LOCAL` |

---

## Other Common Issues

### Index Not Created Due to Insufficient Permissions

```
ERROR: permission denied for schema public
```

**Fix:** Grant permissions or use a schema where the user has CREATE access:

```sql
GRANT CREATE ON SCHEMA public TO myuser;
-- or
CREATE SCHEMA vectors AUTHORIZATION myuser;
```

### Extension Not Available

```
ERROR: could not open extension control file "/usr/share/postgresql/16/extension/vector.control": No such file or directory
```

**Fix:** Install pgvector on the server. See the setup script in `scripts/setup-pgvector.sh`.

### `COPY` Fails with Vector Data

```
ERROR: invalid input syntax for type vector
```

**Fix:** Ensure vector format is `[0.1,0.2,0.3]` (square brackets, no spaces):

```
-- Correct format for COPY
some_text	[0.1,0.2,0.3]
-- NOT: some_text  {0.1, 0.2, 0.3}
-- NOT: some_text  (0.1, 0.2, 0.3)
```

### Concurrent Index Build Fails

```
ERROR: CONCURRENTLY requires exactly 0 tuples to be marked as dead
```

**Fix:** Run `VACUUM` first, then retry:

```sql
VACUUM items;
CREATE INDEX CONCURRENTLY ON items USING hnsw (embedding vector_cosine_ops);
```

### Maximum Dimensions Exceeded

| Type | Max Dims (no index) | Max Dims (HNSW) | Max Dims (IVFFlat) |
|------|-------------------|-----------------|-------------------|
| vector | 16,000 | 2,000 | 2,000 |
| halfvec | 16,000 | 4,000 | 4,000 |
| bit | 64,000 | 64,000 | 64,000 |
| sparsevec | Unlimited (non-zero ≤ 16,000) | 16,000 | N/A |

**Fix for high-dimensional embeddings:**
1. Use `halfvec` (doubles the index limit).
2. Truncate with Matryoshka (if model supports it).
3. Apply PCA/random projection to reduce dimensions.
