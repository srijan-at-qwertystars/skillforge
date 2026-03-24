# Advanced PostgreSQL Patterns

## Table of Contents

- [Lateral Joins](#lateral-joins)
- [Grouping Sets, Cube, and Rollup](#grouping-sets-cube-and-rollup)
- [Recursive CTEs for Graph Traversal](#recursive-ctes-for-graph-traversal)
- [generate_series Tricks](#generate_series-tricks)
- [Advanced Indexing](#advanced-indexing)
  - [Partial Indexes](#partial-indexes)
  - [Expression Indexes](#expression-indexes)
  - [Covering Indexes (INCLUDE)](#covering-indexes-include)
  - [Index-Only Scans](#index-only-scans)
  - [Multicolumn Index Ordering](#multicolumn-index-ordering)
- [Advanced Partitioning](#advanced-partitioning)
  - [Partition Pruning](#partition-pruning)
  - [Default Partitions](#default-partitions)
  - [Attaching and Detaching Partitions](#attaching-and-detaching-partitions)
  - [Sub-Partitioning](#sub-partitioning)
  - [Partition Maintenance Automation](#partition-maintenance-automation)

---

## Lateral Joins

`LATERAL` allows a subquery in FROM to reference columns from preceding tables,
enabling per-row correlated subqueries that are far more efficient than scalar subqueries.

### Top-N Per Group

```sql
-- Top 3 recent orders per customer (much faster than window function + filter)
SELECT c.id, c.name, o.id AS order_id, o.total, o.created_at
FROM customers c
LEFT JOIN LATERAL (
    SELECT id, total, created_at
    FROM orders
    WHERE customer_id = c.id
    ORDER BY created_at DESC
    LIMIT 3
) o ON true;
```

### Unnesting with Computation

```sql
-- Expand JSON array and compute per-element stats
SELECT p.id, p.name, t.tag, t.tag_length
FROM products p
LEFT JOIN LATERAL (
    SELECT elem::text AS tag, length(elem::text) AS tag_length
    FROM jsonb_array_elements_text(p.tags) AS elem
) t ON true;
```

### Dependent Function Calls

```sql
-- Call a set-returning function with values from each row
SELECT d.department_name, e.employee_name, e.salary
FROM departments d
LEFT JOIN LATERAL get_top_earners(d.id, 5) AS e ON true;
```

### LATERAL vs Correlated Subquery

```sql
-- SLOW: correlated subquery (executes once per outer row, returns single value)
SELECT c.id, (SELECT MAX(total) FROM orders WHERE customer_id = c.id) AS max_order
FROM customers c;

-- FAST: LATERAL (can return multiple rows/columns, uses index efficiently)
SELECT c.id, o.max_total, o.order_count
FROM customers c
LEFT JOIN LATERAL (
    SELECT MAX(total) AS max_total, COUNT(*) AS order_count
    FROM orders WHERE customer_id = c.id
) o ON true;
```

**When to use LATERAL:**
- Top-N per group queries
- Expanding arrays/JSONB per row
- Calling set-returning functions with row-dependent arguments
- Replacing slow correlated subqueries with multi-column results

---

## Grouping Sets, Cube, and Rollup

These extensions to GROUP BY produce multiple levels of aggregation in a single pass.

### GROUPING SETS

```sql
-- Produce subtotals by region, by product, and a grand total — one query
SELECT
    region,
    product_category,
    SUM(revenue) AS total_revenue,
    COUNT(*) AS order_count
FROM sales
GROUP BY GROUPING SETS (
    (region, product_category),   -- detail
    (region),                      -- subtotal by region
    (product_category),            -- subtotal by product
    ()                             -- grand total
)
ORDER BY region NULLS LAST, product_category NULLS LAST;
```

### ROLLUP — Hierarchical Subtotals

```sql
-- Year → Quarter → Month drill-down with subtotals at each level
SELECT
    EXTRACT(YEAR FROM sale_date) AS year,
    EXTRACT(QUARTER FROM sale_date) AS quarter,
    EXTRACT(MONTH FROM sale_date) AS month,
    SUM(amount) AS total,
    GROUPING(EXTRACT(YEAR FROM sale_date),
             EXTRACT(QUARTER FROM sale_date),
             EXTRACT(MONTH FROM sale_date)) AS grouping_level
FROM sales
GROUP BY ROLLUP (
    EXTRACT(YEAR FROM sale_date),
    EXTRACT(QUARTER FROM sale_date),
    EXTRACT(MONTH FROM sale_date)
)
ORDER BY year, quarter, month;
-- Produces: month detail, quarter subtotal, year subtotal, grand total
```

### CUBE — All Combinations

```sql
-- Full cross-dimensional analysis
SELECT
    region,
    product_category,
    sales_channel,
    SUM(revenue) AS total_revenue
FROM sales
GROUP BY CUBE (region, product_category, sales_channel);
-- Produces: 2^3 = 8 grouping combinations including grand total
```

### Distinguishing Aggregation Levels with GROUPING()

```sql
SELECT
    CASE WHEN GROUPING(region) = 1 THEN 'ALL REGIONS' ELSE region END AS region,
    CASE WHEN GROUPING(category) = 1 THEN 'ALL CATEGORIES' ELSE category END AS category,
    SUM(revenue) AS total_revenue
FROM sales
GROUP BY ROLLUP (region, category);
```

---

## Recursive CTEs for Graph Traversal

### Shortest Path in a Weighted Graph

```sql
WITH RECURSIVE shortest_path AS (
    -- Start from source node
    SELECT
        target_node AS node,
        weight AS total_cost,
        ARRAY[source_node, target_node] AS path
    FROM edges
    WHERE source_node = 'A'

    UNION ALL

    -- Extend path
    SELECT
        e.target_node,
        sp.total_cost + e.weight,
        sp.path || e.target_node
    FROM shortest_path sp
    JOIN edges e ON e.source_node = sp.node
    WHERE e.target_node <> ALL(sp.path)  -- prevent cycles
      AND sp.total_cost + e.weight < 1000 -- cost guard
)
SELECT DISTINCT ON (node)
    node, total_cost, path
FROM shortest_path
ORDER BY node, total_cost;
```

### Bill of Materials (BOM) Explosion

```sql
WITH RECURSIVE bom AS (
    -- Top-level assembly
    SELECT part_id, component_id, quantity, 1 AS level,
           ARRAY[part_id] AS path
    FROM bill_of_materials
    WHERE part_id = 'ASSEMBLY-100'

    UNION ALL

    -- Sub-components
    SELECT b.part_id, b.component_id, b.quantity * bom.quantity,
           bom.level + 1, bom.path || b.part_id
    FROM bill_of_materials b
    JOIN bom ON b.part_id = bom.component_id
    WHERE bom.level < 20
      AND b.part_id <> ALL(bom.path)
)
SELECT component_id, SUM(quantity) AS total_needed, MAX(level) AS deepest_level
FROM bom
GROUP BY component_id
ORDER BY total_needed DESC;
```

### Transitive Closure (Who Can Reach Whom)

```sql
WITH RECURSIVE reachable AS (
    SELECT DISTINCT source, target FROM connections
    UNION
    SELECT r.source, c.target
    FROM reachable r
    JOIN connections c ON r.target = c.source
)
SELECT * FROM reachable ORDER BY source, target;
```

### Cycle Detection (PG14+)

```sql
-- PG14+ CYCLE clause — automatic cycle detection
WITH RECURSIVE graph_walk AS (
    SELECT id, parent_id, name, 1 AS depth
    FROM nodes WHERE parent_id IS NULL
    UNION ALL
    SELECT n.id, n.parent_id, n.name, g.depth + 1
    FROM nodes n JOIN graph_walk g ON n.parent_id = g.id
)
CYCLE id SET is_cycle USING path
SELECT * FROM graph_walk WHERE NOT is_cycle;
```

### SEARCH clause (PG14+)

```sql
-- Breadth-first vs depth-first traversal
WITH RECURSIVE tree AS (
    SELECT id, parent_id, name FROM categories WHERE parent_id IS NULL
    UNION ALL
    SELECT c.id, c.parent_id, c.name
    FROM categories c JOIN tree t ON c.parent_id = t.id
)
SEARCH BREADTH FIRST BY id SET ordercol
SELECT * FROM tree ORDER BY ordercol;
```

---

## generate_series Tricks

### Gap-Filling Time Series

```sql
-- Fill missing dates with zero values
SELECT
    d::date AS date,
    COALESCE(s.revenue, 0) AS revenue,
    COALESCE(s.order_count, 0) AS order_count
FROM generate_series(
    '2024-01-01'::date,
    '2024-12-31'::date,
    '1 day'::interval
) AS d
LEFT JOIN daily_sales s ON s.sale_date = d::date
ORDER BY d;
```

### Generate Time Slots

```sql
-- Generate 30-minute appointment slots
SELECT
    slot_start,
    slot_start + interval '30 minutes' AS slot_end
FROM generate_series(
    '2024-06-01 09:00'::timestamp,
    '2024-06-01 17:00'::timestamp,
    '30 minutes'::interval
) AS slot_start
WHERE NOT EXISTS (
    SELECT 1 FROM appointments a
    WHERE a.start_time < slot_start + interval '30 minutes'
      AND a.end_time > slot_start
);
```

### Pivot / Cross-Tabulation

```sql
-- Dynamic month columns using generate_series
SELECT
    product_id,
    SUM(CASE WHEN month = 1 THEN revenue END) AS jan,
    SUM(CASE WHEN month = 2 THEN revenue END) AS feb,
    SUM(CASE WHEN month = 3 THEN revenue END) AS mar
    -- ... etc
FROM (
    SELECT product_id, EXTRACT(MONTH FROM sale_date)::int AS month, revenue
    FROM sales WHERE sale_date >= '2024-01-01' AND sale_date < '2025-01-01'
) sub
GROUP BY product_id;
```

### Generate Test Data

```sql
-- Insert 1 million test rows efficiently
INSERT INTO test_events (user_id, event_type, created_at, payload)
SELECT
    (random() * 10000)::int AS user_id,
    (ARRAY['click','view','purchase','signup'])[1 + (random()*3)::int] AS event_type,
    '2024-01-01'::timestamp + (random() * 365) * interval '1 day' AS created_at,
    jsonb_build_object('value', round((random() * 1000)::numeric, 2)) AS payload
FROM generate_series(1, 1000000);
```

### IP Address Range Expansion

```sql
-- Expand CIDR to individual IPs (small ranges only)
SELECT host(network + gs) AS ip
FROM (SELECT '192.168.1.0/28'::inet AS network) n,
     generate_series(0, (1 << (32 - masklen(n.network))) - 1) AS gs;
```

---

## Advanced Indexing

### Partial Indexes

Index only the rows that matter — dramatically smaller, faster, and cheaper to maintain.

```sql
-- Only index active orders (if 95% are archived)
CREATE INDEX idx_orders_active ON orders (customer_id, created_at)
    WHERE status = 'active';

-- Only index non-null emails
CREATE INDEX idx_users_email ON users (email) WHERE email IS NOT NULL;

-- Unique constraint on subset
CREATE UNIQUE INDEX idx_unique_active_subscription
    ON subscriptions (user_id) WHERE status = 'active';
-- Allows multiple cancelled subs per user, but only one active
```

**Query must include the WHERE clause** for the planner to use the partial index:
```sql
-- ✅ Uses partial index
SELECT * FROM orders WHERE status = 'active' AND customer_id = 42;

-- ❌ Cannot use partial index (no status filter)
SELECT * FROM orders WHERE customer_id = 42;
```

### Expression Indexes

Index computed values for queries that filter/sort on expressions.

```sql
-- Case-insensitive email lookup
CREATE INDEX idx_users_lower_email ON users (lower(email));
-- Query: SELECT * FROM users WHERE lower(email) = 'user@example.com';

-- Index on JSONB field extraction
CREATE INDEX idx_events_type ON events ((payload->>'type'));
-- Query: SELECT * FROM events WHERE payload->>'type' = 'purchase';

-- Date truncation for daily aggregation queries
CREATE INDEX idx_sales_day ON sales (date_trunc('day', created_at));

-- Computed column index
CREATE INDEX idx_orders_total_with_tax ON orders ((total * 1.08));
```

### Covering Indexes (INCLUDE)

Add non-key columns to enable index-only scans without bloating the B-tree.

```sql
-- Covering index: key=customer_id, payload=status,total,created_at
CREATE INDEX idx_orders_cust_covering ON orders (customer_id)
    INCLUDE (status, total, created_at);

-- This query can now be satisfied entirely from the index:
SELECT status, total, created_at FROM orders WHERE customer_id = 42;
-- EXPLAIN shows: Index Only Scan using idx_orders_cust_covering
```

**INCLUDE vs multi-column index:**
- `(a, b, c)` — all three columns are in the B-tree, support range scans on b,c
- `(a) INCLUDE (b, c)` — only `a` in B-tree, b,c stored as payload; smaller, faster writes

### Index-Only Scans

Requirements for index-only scans:
1. All columns in SELECT, WHERE, JOIN must be in the index (key or INCLUDE)
2. Visibility map must be up-to-date (run VACUUM regularly)
3. Most effective on read-heavy, infrequently-updated tables

```sql
-- Check if your queries get index-only scans
EXPLAIN (ANALYZE, BUFFERS)
SELECT customer_id, status FROM orders WHERE customer_id = 42;

-- Look for: "Index Only Scan" and "Heap Fetches: 0"
-- If Heap Fetches is high, run: VACUUM orders;
```

### Multicolumn Index Ordering

Column order in multi-column indexes matters enormously:

```sql
-- For query: WHERE status = 'active' AND created_at > '2024-01-01'
-- Equality columns first, range columns last
CREATE INDEX idx_orders_status_date ON orders (status, created_at);

-- For query: WHERE status = 'active' ORDER BY created_at DESC LIMIT 10
-- Same index works — range scan on created_at after status equality
CREATE INDEX idx_orders_status_date_desc ON orders (status, created_at DESC);
```

**Rule of thumb for column order:**
1. Equality conditions (=, IN)
2. Range conditions (<, >, BETWEEN)
3. ORDER BY / GROUP BY columns
4. SELECT-only columns → use INCLUDE

---

## Advanced Partitioning

### Partition Pruning

Partition pruning eliminates irrelevant partitions during planning and execution.

```sql
-- Verify pruning is enabled
SHOW enable_partition_pruning;  -- must be 'on'

-- Check pruning in action
EXPLAIN (ANALYZE, COSTS OFF)
SELECT * FROM events WHERE created_at >= '2024-07-01' AND created_at < '2024-10-01';
-- Should show: "Partitions removed: X" or only relevant partitions scanned
```

**Runtime pruning (PG11+):**
```sql
-- Pruning happens at execution time with parameterized queries
PREPARE get_events(timestamptz) AS
    SELECT * FROM events WHERE created_at >= $1 AND created_at < $1 + interval '1 month';
EXECUTE get_events('2024-06-01');
-- Planner can't prune at plan time, but executor prunes at runtime
```

**JOIN-based pruning (PG14+):**
```sql
-- Partitions are pruned based on join conditions
SELECT e.*, c.name
FROM events e JOIN campaigns c ON e.campaign_id = c.id
WHERE c.start_date >= '2024-07-01';
-- Only relevant event partitions are scanned
```

### Default Partitions

Catch-all for rows that don't match any partition boundary.

```sql
CREATE TABLE metrics (
    id bigint GENERATED ALWAYS AS IDENTITY,
    recorded_at timestamptz NOT NULL,
    value numeric
) PARTITION BY RANGE (recorded_at);

CREATE TABLE metrics_2024_q1 PARTITION OF metrics
    FOR VALUES FROM ('2024-01-01') TO ('2024-04-01');
CREATE TABLE metrics_2024_q2 PARTITION OF metrics
    FOR VALUES FROM ('2024-04-01') TO ('2024-07-01');
CREATE TABLE metrics_default PARTITION OF metrics DEFAULT;
```

**Caution:** When adding a new partition, PostgreSQL must scan the default partition
to verify no rows belong in the new partition. For large defaults, this is slow:
```sql
-- This triggers a full scan of metrics_default
CREATE TABLE metrics_2024_q3 PARTITION OF metrics
    FOR VALUES FROM ('2024-07-01') TO ('2024-10-01');

-- Workaround: detach default, add partition, move rows, reattach
ALTER TABLE metrics DETACH PARTITION metrics_default;
CREATE TABLE metrics_2024_q3 PARTITION OF metrics
    FOR VALUES FROM ('2024-07-01') TO ('2024-10-01');
INSERT INTO metrics_2024_q3 SELECT * FROM metrics_default
    WHERE recorded_at >= '2024-07-01' AND recorded_at < '2024-10-01';
DELETE FROM metrics_default
    WHERE recorded_at >= '2024-07-01' AND recorded_at < '2024-10-01';
ALTER TABLE metrics ATTACH PARTITION metrics_default DEFAULT;
```

### Attaching and Detaching Partitions

```sql
-- Attach: add an existing table as a partition
-- The table must have a compatible schema and a CHECK constraint
ALTER TABLE events_staging ADD CONSTRAINT chk_date
    CHECK (created_at >= '2024-10-01' AND created_at < '2025-01-01');
ALTER TABLE events ATTACH PARTITION events_staging
    FOR VALUES FROM ('2024-10-01') TO ('2025-01-01');
-- With CHECK constraint, PG skips full table scan validation

-- Detach: remove partition for archival (non-blocking in PG14+)
ALTER TABLE events DETACH PARTITION events_2023_q1 CONCURRENTLY;
-- The table events_2023_q1 still exists as a standalone table
-- Can be archived, dumped, moved to cold storage, or dropped
```

**Zero-downtime partition rotation:**
```sql
BEGIN;
-- 1. Create new partition for upcoming period
CREATE TABLE events_2025_q1 PARTITION OF events
    FOR VALUES FROM ('2025-01-01') TO ('2025-04-01');
-- 2. Create indexes (they propagate from parent automatically)
COMMIT;

-- 3. Later, archive old data
ALTER TABLE events DETACH PARTITION events_2023_q1 CONCURRENTLY;
-- 4. Compress or move to archive
pg_dump -t events_2023_q1 mydb | gzip > events_2023_q1.sql.gz
DROP TABLE events_2023_q1;
```

### Sub-Partitioning

Partition partitions for multi-dimensional data.

```sql
-- First level: range by date
CREATE TABLE orders (
    id bigint GENERATED ALWAYS AS IDENTITY,
    created_at timestamptz NOT NULL,
    region text NOT NULL,
    total numeric
) PARTITION BY RANGE (created_at);

-- Second level: list by region within each date range
CREATE TABLE orders_2024_q1 PARTITION OF orders
    FOR VALUES FROM ('2024-01-01') TO ('2024-04-01')
    PARTITION BY LIST (region);

CREATE TABLE orders_2024_q1_us PARTITION OF orders_2024_q1
    FOR VALUES IN ('us-east', 'us-west');
CREATE TABLE orders_2024_q1_eu PARTITION OF orders_2024_q1
    FOR VALUES IN ('eu-west', 'eu-central');
CREATE TABLE orders_2024_q1_default PARTITION OF orders_2024_q1 DEFAULT;
```

**Guidelines:**
- Keep total partition count under a few hundred (planner overhead)
- Sub-partition only when queries consistently filter on both dimensions
- Use `pg_partman` for automated creation/dropping of time-based sub-partitions

### Partition Maintenance Automation

```sql
-- Using pg_partman for automated partition management
CREATE EXTENSION pg_partman;

SELECT partman.create_parent(
    p_parent_table := 'public.events',
    p_control := 'created_at',
    p_type := 'range',
    p_interval := '1 month',
    p_premake := 3          -- create 3 future partitions
);

-- Configure retention
UPDATE partman.part_config
SET retention = '12 months',
    retention_keep_table = false  -- drop old partitions
WHERE parent_table = 'public.events';

-- Run maintenance (schedule via pg_cron)
SELECT partman.run_maintenance();
```
