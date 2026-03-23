---
name: sql-query-optimization
description: |
  Use when user optimizes SQL queries, asks about slow queries, execution plans, join strategies, subquery vs CTE performance, index utilization, query rewriting, or N+1 query problems in ORMs.
  Do NOT use for database administration, schema design, PostgreSQL-specific tuning (use postgres-performance-tuning skill), or NoSQL databases.
---

# SQL Query Optimization

Database-agnostic guide. MySQL and PostgreSQL specifics noted where behavior diverges.

## Reading Execution Plans

Run `EXPLAIN` before optimizing anything. Without a plan, you are guessing.

### MySQL

```sql
EXPLAIN FORMAT=JSON
SELECT u.name, COUNT(o.id)
FROM users u
JOIN orders o ON o.user_id = u.id
WHERE o.created_at >= '2025-01-01'
GROUP BY u.id;
```

Key fields: `type` (ALL = full scan, ref = index lookup, range = index range), `rows` (estimated rows examined), `Extra` (Using index, Using filesort, Using temporary).

Red flags in MySQL EXPLAIN:
- `type: ALL` — full table scan, add an index or fix the predicate.
- `Extra: Using temporary; Using filesort` — heavy sort/group, check indexes.
- `rows` vastly exceeds actual result count — stale statistics, run `ANALYZE TABLE`.

### PostgreSQL

```sql
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT u.name, COUNT(o.id)
FROM users u
JOIN orders o ON o.user_id = u.id
WHERE o.created_at >= '2025-01-01'
GROUP BY u.id;
```

Key fields: `Seq Scan` vs `Index Scan`, `actual time`, `rows`, `Buffers: shared hit/read`.

Red flags in PostgreSQL EXPLAIN:
- `Seq Scan` on large table with a selective filter — missing index.
- Large gap between `rows=` (estimated) and `actual rows=` — run `ANALYZE`.
- `Buffers: shared read` far exceeds `shared hit` — working set exceeds memory.

### General Rules

- Compare estimated vs actual row counts. Mismatches cause bad plans.
- Look for the most expensive node first — optimize top-down.
- Re-run EXPLAIN after every change to confirm improvement.

## Join Optimization

### Join Types and When the Optimizer Picks Them

| Algorithm     | Best For                                    | Watch For                     |
|---------------|---------------------------------------------|-------------------------------|
| Nested Loop   | Small inner table, index on join key        | Explodes on large unindexed tables |
| Hash Join     | Large unsorted tables, equi-joins           | High memory for large build tables |
| Merge Join    | Pre-sorted inputs (index or explicit sort)  | Requires sorted input         |

### Reduce Join Width

Select only needed columns before joining. Narrower rows = more rows per I/O page = faster joins.

```sql
-- Bad: joins full wide tables then discards columns
SELECT o.id, o.total
FROM orders o
JOIN products p ON p.id = o.product_id
JOIN categories c ON c.id = p.category_id;

-- Better: if only category name needed from products/categories
SELECT o.id, o.total, c.name
FROM orders o
JOIN products p ON p.id = o.product_id
JOIN categories c ON c.id = p.category_id;
```

### Join Order

- Filter the largest table first. Push WHERE conditions as early as possible.
- Most optimizers reorder joins automatically, but complex queries (10+ tables) may exceed the optimizer's search space. Use `STRAIGHT_JOIN` (MySQL) or `join_collapse_limit` (PostgreSQL) to guide order when needed.

### Index the Join Columns

Every foreign key used in a JOIN ON clause needs an index. This is the single highest-impact optimization for join-heavy queries.

## Subquery Refactoring

### Correlated Subquery → JOIN

Correlated subqueries execute once per outer row. Refactor to a JOIN.

```sql
-- Slow: correlated subquery
SELECT u.name,
  (SELECT MAX(o.total) FROM orders o WHERE o.user_id = u.id) AS max_order
FROM users u;

-- Fast: JOIN with aggregate
SELECT u.name, mo.max_total
FROM users u
LEFT JOIN (
  SELECT user_id, MAX(total) AS max_total
  FROM orders
  GROUP BY user_id
) mo ON mo.user_id = u.id;
```

### EXISTS vs IN

- Use `EXISTS` for checking existence — it short-circuits on first match.
- Use `IN` with small, known sets or subqueries returning few rows.
- Avoid `NOT IN` with nullable columns — it returns no rows if any NULL exists. Use `NOT EXISTS` instead.

```sql
-- Prefer EXISTS for large subquery results
SELECT u.id FROM users u
WHERE EXISTS (SELECT 1 FROM orders o WHERE o.user_id = u.id);

-- NOT IN trap: returns empty if orders.user_id has any NULL
SELECT u.id FROM users u
WHERE u.id NOT IN (SELECT user_id FROM orders);

-- Safe alternative
SELECT u.id FROM users u
WHERE NOT EXISTS (SELECT 1 FROM orders o WHERE o.user_id = u.id);
```

### LATERAL Joins (PostgreSQL 9.3+, MySQL 8.0.14+)

Use LATERAL when you need a correlated subquery in FROM — the optimizer can push filters down more effectively.

```sql
-- Top 3 orders per user using LATERAL
SELECT u.id, u.name, lo.id AS order_id, lo.total
FROM users u
CROSS JOIN LATERAL (
  SELECT o.id, o.total
  FROM orders o
  WHERE o.user_id = u.id
  ORDER BY o.total DESC
  LIMIT 3
) lo;
```

## CTE Performance Considerations

### Materialized vs Inlined

**PostgreSQL 12+**: CTEs are inlined (merged into main query) by default when referenced once. Override with:
- `AS MATERIALIZED` — force computation once, store result. Use when the CTE is referenced multiple times or is expensive to recompute.
- `AS NOT MATERIALIZED` — force inlining. Use when you want predicate pushdown into the CTE.

**MySQL 8.0+**: The optimizer decides whether to materialize. Non-recursive CTEs referenced once are typically merged. No manual override syntax.

```sql
-- PostgreSQL: force materialization for a CTE used twice
WITH active_users AS MATERIALIZED (
  SELECT id, name FROM users WHERE status = 'active'
)
SELECT a1.name, COUNT(o.id)
FROM active_users a1
JOIN orders o ON o.user_id = a1.id
GROUP BY a1.name
UNION ALL
SELECT a2.name, 0 FROM active_users a2
WHERE NOT EXISTS (SELECT 1 FROM orders WHERE user_id = a2.id);
```

### Recursive CTEs

Recursive CTEs are always materialized. Keep the working table small:
- Add a depth limit (`WHERE depth < 10`).
- Filter aggressively in the recursive member.
- Index the self-referencing column.

## Index-Aware Query Patterns

### Sargable Predicates

A predicate is **sargable** (Search ARGument ABLE) if the database can use an index to satisfy it. Wrapping an indexed column in a function destroys sargability.

```sql
-- Non-sargable: function on indexed column
WHERE YEAR(created_at) = 2025
WHERE LOWER(email) = 'user@example.com'
WHERE amount + 10 > 100

-- Sargable rewrites
WHERE created_at >= '2025-01-01' AND created_at < '2026-01-01'
WHERE email = 'user@example.com'  -- use a case-insensitive collation or functional index
WHERE amount > 90
```

PostgreSQL: create expression indexes for unavoidable function calls:
```sql
CREATE INDEX idx_users_email_lower ON users (LOWER(email));
```

### Covering Indexes

A covering index includes all columns the query needs, avoiding table lookups (heap fetches).

```sql
-- Query
SELECT user_id, created_at, total FROM orders
WHERE user_id = 42 AND created_at >= '2025-01-01';

-- Covering index (PostgreSQL)
CREATE INDEX idx_orders_covering ON orders (user_id, created_at) INCLUDE (total);

-- MySQL: add columns to the index directly (no INCLUDE syntax before 8.0)
CREATE INDEX idx_orders_covering ON orders (user_id, created_at, total);
```

EXPLAIN output shows `Index Only Scan` (PostgreSQL) or `Using index` (MySQL) when covering.

### Composite Index Column Order

Order columns by: equality predicates first, then range predicates, then sort columns.

```sql
-- Query: WHERE status = 'active' AND created_at > '2025-01-01' ORDER BY name
-- Index: (status, created_at, name)
```

## Window Functions Optimization

### Index to Match PARTITION BY + ORDER BY

```sql
-- Query
SELECT user_id, created_at, amount,
  SUM(amount) OVER (PARTITION BY user_id ORDER BY created_at) AS running_total
FROM orders
WHERE status = 'completed';

-- Index: match partition + order keys
CREATE INDEX idx_orders_window ON orders (user_id, created_at)
  INCLUDE (amount, status);  -- PostgreSQL
```

### Avoid Repeated Scans

Compute multiple window aggregates in a single pass when they share the same PARTITION BY and ORDER BY:

```sql
-- One scan, multiple aggregates
SELECT user_id, created_at, amount,
  SUM(amount) OVER w AS running_total,
  AVG(amount) OVER w AS running_avg,
  ROW_NUMBER() OVER w AS rn
FROM orders
WINDOW w AS (PARTITION BY user_id ORDER BY created_at);
```

### Frame Specifications

Default frame is `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`. Use `ROWS` for predictable performance:

```sql
-- Explicit ROWS frame — faster, deterministic
SUM(amount) OVER (
  PARTITION BY user_id ORDER BY created_at
  ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
)
```

## UNION vs UNION ALL and DISTINCT

- `UNION` deduplicates — requires sort or hash. Use `UNION ALL` when duplicates are impossible or acceptable.
- Avoid `SELECT DISTINCT` as a band-aid for bad joins. Fix the join instead.
- Move DISTINCT inside subqueries to deduplicate early on smaller sets when it is genuinely needed.

```sql
-- Bad: UNION deduplicates unnecessarily
SELECT id FROM active_users UNION SELECT id FROM premium_users;

-- Better: if overlap is impossible or acceptable
SELECT id FROM active_users UNION ALL SELECT id FROM premium_users;
```

## Pagination Patterns

### OFFSET Pagination (Avoid at Scale)

```sql
-- Page 500 of 20 results: scans and discards 9980 rows
SELECT * FROM orders ORDER BY id LIMIT 20 OFFSET 9980;
```

Performance degrades linearly with page depth. O(OFFSET + LIMIT) rows scanned.

### Keyset / Cursor Pagination (Preferred)

```sql
-- First page
SELECT id, created_at, total FROM orders
ORDER BY created_at DESC, id DESC
LIMIT 20;

-- Next page: pass last row's values as cursor
SELECT id, created_at, total FROM orders
WHERE (created_at, id) < ('2025-06-15 10:30:00', 4523)
ORDER BY created_at DESC, id DESC
LIMIT 20;
```

Requires a unique, indexed sort key. Constant performance regardless of page depth. Index on `(created_at DESC, id DESC)`.

Tradeoff: no "jump to page N" — use for infinite scroll, feeds, API pagination.

## Batch Operations

### Bulk INSERT

```sql
-- Single statement with multiple rows — one round-trip, one transaction
INSERT INTO events (user_id, event_type, created_at) VALUES
  (1, 'login', NOW()),
  (2, 'purchase', NOW()),
  (3, 'login', NOW());
```

Batch size: 500–5000 rows per statement depending on row width and DB limits. MySQL `max_allowed_packet` and PostgreSQL `max_query_length` cap the batch.

### UPDATE with JOIN

```sql
-- MySQL
UPDATE orders o
JOIN users u ON u.id = o.user_id
SET o.discount = 0.10
WHERE u.tier = 'gold';

-- PostgreSQL
UPDATE orders o
SET discount = 0.10
FROM users u
WHERE u.id = o.user_id AND u.tier = 'gold';
```

### DELETE in Chunks

Avoid locking an entire table with a single massive DELETE. Delete in batches:

```sql
-- Delete in chunks of 1000
DELETE FROM logs
WHERE created_at < '2024-01-01'
ORDER BY id
LIMIT 1000;
-- Repeat until 0 rows affected
```

PostgreSQL lacks DELETE ... LIMIT. Use a CTE:

```sql
WITH to_delete AS (
  SELECT id FROM logs
  WHERE created_at < '2024-01-01'
  ORDER BY id
  LIMIT 1000
)
DELETE FROM logs WHERE id IN (SELECT id FROM to_delete);
```

## ORM Query Optimization

### Detecting N+1 Queries

N+1 pattern: 1 query fetches N parents, then N separate queries fetch children.

```python
# N+1 in Django
for user in User.objects.all():          # 1 query
    print(user.orders.count())            # N queries

# Fixed: prefetch
for user in User.objects.prefetch_related('orders'):  # 2 queries total
    print(user.orders.count())
```

Detection tools:
- **Django**: `django-debug-toolbar`, `nplusone`
- **SQLAlchemy**: `echo=True`, `selectinload()` / `joinedload()`
- **ActiveRecord**: `bullet` gem
- **Hibernate/JPA**: enable `hibernate.generate_statistics`, use `@EntityGraph`

### Eager Loading Strategies

| Strategy        | SQL Generated           | Use When                              |
|-----------------|-------------------------|---------------------------------------|
| JOIN fetch      | Single query with JOIN  | One-to-one or small many-to-one       |
| Subquery fetch  | 2 queries (IN list)     | One-to-many with moderate child count |
| Batch fetch     | Multiple queries (batched IN) | Large collections, memory-sensitive |

### Raw SQL Escape Hatches

Use raw SQL when the ORM generates suboptimal queries:

```python
# SQLAlchemy
db.session.execute(text("""
  SELECT u.id, COUNT(o.id)
  FROM users u
  LEFT JOIN orders o ON o.user_id = u.id
  GROUP BY u.id
  HAVING COUNT(o.id) > 10
"""))
```

Keep raw SQL in named queries or repository methods — do not scatter it through business logic.

## Query Anti-Patterns

### SELECT *

Fetches all columns including BLOBs and unused data. Blocks covering index usage. Always list columns explicitly.

### Implicit Type Conversion

```sql
-- phone_number is VARCHAR, but compared to integer — index skipped
WHERE phone_number = 5551234

-- Fix: match the column type
WHERE phone_number = '5551234'
```

### Functions on Indexed Columns

```sql
-- Index on created_at not used
WHERE DATE(created_at) = '2025-06-15'

-- Fix: range predicate
WHERE created_at >= '2025-06-15' AND created_at < '2025-06-16'
```

### OR Chains on Different Columns

```sql
-- Hard to optimize: OR across different columns
WHERE email = 'a@b.com' OR phone = '555-1234'

-- Rewrite as UNION ALL (each branch uses its own index)
SELECT id FROM users WHERE email = 'a@b.com'
UNION ALL
SELECT id FROM users WHERE phone = '555-1234';
```

### Wildcard-Leading LIKE

```sql
-- Cannot use index
WHERE name LIKE '%smith'

-- Can use index (prefix match)
WHERE name LIKE 'smith%'
```

For suffix or infix search, use full-text indexes (MySQL `FULLTEXT`, PostgreSQL `pg_trgm` + GIN).

## Measuring and Benchmarking

### Before Optimizing

1. Identify the slow query — use slow query log (MySQL: `long_query_time`, PostgreSQL: `log_min_duration_statement`).
2. Run EXPLAIN ANALYZE on the exact query with production-like data.
3. Record baseline: execution time, rows scanned, buffer hits/reads.

### After Optimizing

1. Re-run EXPLAIN ANALYZE — confirm the plan changed as expected.
2. Compare rows scanned, sort operations, and buffer reads.
3. Test under load — a query fast in isolation may block under concurrency.

### Benchmarking Checklist

- Use production-representative data volume and distribution.
- Warm the buffer pool first — cold-cache benchmarks are misleading for steady-state performance.
- Run the query multiple times, discard the first run, average the rest.
- Test with concurrent connections to surface lock contention.
- Monitor `IOPS`, `CPU`, and `memory` during benchmark — a query might be fast but resource-hungry.

### Ongoing Monitoring

- MySQL: enable Performance Schema, use `sys.statement_analysis`.
- PostgreSQL: enable `pg_stat_statements`, query by `mean_exec_time` and `calls`.
- Set alerts on query duration percentiles (p95, p99), not just averages.
