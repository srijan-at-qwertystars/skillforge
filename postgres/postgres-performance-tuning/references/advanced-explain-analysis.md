# Advanced EXPLAIN Analysis

Deep dive into EXPLAIN output interpretation: output formats, visualization tools, node types, JIT, parallel plans, CTEs, window functions, and common interpretation traps.

---

## Table of Contents

1. [Custom EXPLAIN Output Formats](#custom-explain-output-formats)
2. [Plan Visualization Tools](#plan-visualization-tools)
3. [Node Types Reference](#node-types-reference)
4. [JIT Compilation](#jit-compilation)
5. [Parallel Query Plans](#parallel-query-plans)
6. [CTEs vs Subqueries](#ctes-vs-subqueries)
7. [Window Function Execution Plans](#window-function-execution-plans)
8. [The "Actual Loops × Actual Time" Trap](#the-actual-loops--actual-time-trap)

---

## Custom EXPLAIN Output Formats

PostgreSQL supports four output formats: `TEXT` (default), `JSON`, `YAML`, and `XML`.

### TEXT (default)

```sql
EXPLAIN (ANALYZE, BUFFERS) SELECT ...;
```

Best for quick interactive use. Compact and human-readable, but harder to parse programmatically.

### JSON

```sql
EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) SELECT ...;
```

Returns a JSON array of plan objects. Each node includes all fields as structured key-value pairs.

**When to use JSON:**
- Feeding plans into visualization tools or custom dashboards
- Programmatic analysis (Python, jq)
- Storing plans in tables for historical comparison
- When you need exact numeric values without parsing whitespace-aligned text

```sql
-- Store plans for regression analysis
CREATE TABLE query_plans (
    id SERIAL PRIMARY KEY,
    query_hash TEXT,
    plan JSONB,
    captured_at TIMESTAMPTZ DEFAULT now()
);

INSERT INTO query_plans (query_hash, plan)
SELECT md5('SELECT ...'), plan
FROM (SELECT EXPLAIN_JSON('SELECT ...')) AS t(plan);
```

Parsing with `jq`:
```bash
# Extract total execution time
echo "$plan_json" | jq '.[0]."Execution Time"'

# Find all Seq Scan nodes
echo "$plan_json" | jq '.. | objects | select(."Node Type" == "Seq Scan")'
```

### YAML

```sql
EXPLAIN (ANALYZE, BUFFERS, FORMAT YAML) SELECT ...;
```

**When to use YAML:**
- Human-readable structured output (easier to scan than JSON for large plans)
- When pasting plans into documentation or tickets
- Slightly more compact than JSON for deeply nested plans

### XML

```sql
EXPLAIN (ANALYZE, BUFFERS, FORMAT XML) SELECT ...;
```

Rarely used directly. Useful when integrating with XML-based tooling or XSLT transformations.

### Additional EXPLAIN Options

```sql
EXPLAIN (
    ANALYZE,        -- actually execute the query
    BUFFERS,        -- show buffer hit/read/write counts
    COSTS,          -- show estimated costs (on by default)
    TIMING,         -- show actual time per node (on by default with ANALYZE)
    VERBOSE,        -- show output column lists, schema-qualified names
    SETTINGS,       -- show non-default planner settings (PG 12+)
    WAL,            -- show WAL usage (PG 13+, write queries only)
    SUMMARY         -- show planning/execution time summary (on by default)
) SELECT ...;
```

**Tip:** `TIMING OFF` reduces overhead on plans with many loops. Use it when you only need row counts:

```sql
EXPLAIN (ANALYZE, TIMING OFF) SELECT ...;
```

---

## Plan Visualization Tools

### pgAdmin Query Tool

Built-in graphical EXPLAIN viewer. Shows nodes as boxes with color-coded cost indicators. Hover for details. Good for quick visual inspection but limited for complex plans.

### explain.depesz.com

Paste TEXT-format EXPLAIN ANALYZE output. Highlights:
- Color-codes nodes by "exclusive" time (time spent in that node alone)
- Shows % of total time per node
- Highlights rows estimation errors (estimated vs actual)
- Best for identifying **which node** is the bottleneck

### explain.dalibo.com (PEV2)

Paste JSON or TEXT-format output. Highlights:
- Interactive tree visualization with zoom/collapse
- Shows buffer usage per node
- Better for understanding plan **structure** and data flow
- Node details panel with all statistics

### auto_explain Extension

Automatically logs slow query plans without manual EXPLAIN:

```sql
-- In postgresql.conf or per-session
LOAD 'auto_explain';
SET auto_explain.log_min_duration = '1s';      -- log plans for queries > 1s
SET auto_explain.log_analyze = true;            -- include ANALYZE output
SET auto_explain.log_buffers = true;            -- include buffer stats
SET auto_explain.log_timing = false;            -- reduce overhead in production
SET auto_explain.log_nested_statements = true;  -- capture plans inside functions
SET auto_explain.log_format = 'json';           -- structured for parsing
SET auto_explain.sample_rate = 0.1;             -- log 10% of qualifying queries
```

**Production setup** (in `postgresql.conf`):

```
shared_preload_libraries = 'auto_explain'
auto_explain.log_min_duration = '3s'
auto_explain.log_analyze = true
auto_explain.log_buffers = true
auto_explain.log_timing = false   # timing adds overhead; disable in prod
auto_explain.log_format = 'json'
auto_explain.sample_rate = 0.01   # 1% sample rate to limit overhead
```

**Warning:** `auto_explain` with `log_analyze = true` **executes the query** to get actual stats. With `log_timing = true`, the overhead is measurable (~10-15% on loop-heavy plans). Always use `sample_rate < 1.0` in production.

---

## Node Types Reference

### Bitmap Scan Nodes

#### BitmapAnd

Combines multiple bitmap index scans with a logical AND. Appears when the planner uses two or more indexes on the same table and intersects the results.

```
->  BitmapAnd
      ->  Bitmap Index Scan on idx_status (rows=5000)
      ->  Bitmap Index Scan on idx_region (rows=3000)
```

**Key insight:** If you see BitmapAnd frequently on the same column combination, consider a composite index instead. A single composite index scan is almost always faster than BitmapAnd.

#### BitmapOr

Combines bitmap index scans with a logical OR. Common with `IN (...)` or `OR` conditions spanning different indexes.

```
->  BitmapOr
      ->  Bitmap Index Scan on idx_status (cond: status = 'active')
      ->  Bitmap Index Scan on idx_status (cond: status = 'pending')
```

**Key insight:** If BitmapOr appears on a single index, the planner may be splitting an `IN` list. For large IN lists, this is normal. If on different indexes, evaluate whether a single index with an expression could cover both.

### Materialize

Caches the output of a child node in memory (or spills to disk) for re-reads. Appears when an inner node in a Nested Loop needs to be scanned multiple times.

```
->  Nested Loop
      ->  Seq Scan on orders (rows=100)
      ->  Materialize
            ->  Seq Scan on products (rows=50)
```

**Watch for:** Large Materialize nodes with many loops. If the materialized set is large and loops are high, total memory or temp file usage grows. Check `BUFFERS` output for `temp read/written`.

### Memoize (PG 14+)

Like Materialize, but with a hash-based cache keyed on the join parameter. Avoids re-executing the inner side when the same key appears again.

```
->  Nested Loop
      ->  Index Scan on orders
      ->  Memoize (cache key: orders.customer_id)
            Cache Hits: 950  Misses: 50  Evictions: 0
            ->  Index Scan on customers
```

**Key metrics:**
- **Hits vs Misses:** High hit ratio = Memoize is effective
- **Evictions:** If evictions are high, `work_mem` may be too low for the cache
- **Cache Overflows:** Node falls back to re-executing; increase `work_mem`

### Incremental Sort (PG 13+)

Sorts data that is already partially sorted on a prefix of the sort key. Much cheaper than full Sort when the leading sort keys are pre-ordered.

```
->  Incremental Sort
      Sort Key: department, hire_date
      Presorted Key: department
      Full-sort Groups: 50  Pre-sorted Groups: 50
```

**When it helps:** Queries with `ORDER BY a, b` where an index on `a` exists but not on `(a, b)`. The planner sorts each group of rows sharing the same `a` value independently.

**Key metric:** Compare `Full-sort Groups` memory usage to what a full Sort would require. Incremental Sort uses much less memory because it sorts small groups.

### CTE Scan

Scans the result of a Common Table Expression. Before PG 12, CTEs were always materialized (optimization fence). PG 12+ may inline them.

```
->  CTE Scan on recent_orders
      Filter: (total > 100)
      CTE recent_orders
        ->  Seq Scan on orders
              Filter: (created_at > '2024-01-01')
```

**Watch for:** CTE Scan with a Filter that could have been pushed down into the CTE subquery. If the CTE is materialized, the filter runs **after** materialization, scanning all CTE rows. See [CTEs vs Subqueries](#ctes-vs-subqueries).

### Subquery Scan

Wraps a subquery's output. Often appears as a no-op pass-through, but sometimes applies filters or projections.

```
->  Subquery Scan on subq
      Filter: (subq.rank <= 10)
      ->  WindowAgg
            ->  Sort
                  ->  Seq Scan on events
```

**Key insight:** If the Subquery Scan has a Filter removing many rows, check whether the filter can be pushed deeper. The planner sometimes cannot push filters past window functions or set-returning functions.

### Append

Concatenates results from multiple child plans. Common with:
- `UNION ALL` queries
- Partitioned table scans (one child per partition)
- Inheritance hierarchies

```
->  Append
      ->  Seq Scan on orders_2023q1
      ->  Seq Scan on orders_2023q2
      ->  Index Scan on orders_2023q3
      ->  Index Scan on orders_2023q4
```

**Key insight for partitioned tables:** Check which partitions are being scanned. If partition pruning is working, only relevant partitions should appear as children. If all partitions appear, the WHERE clause may not align with the partition key, or `enable_partition_pruning` is off.

### MergeAppend

Like Append but maintains sort order across pre-sorted children. Used when the planner needs sorted output from a partitioned table or UNION ALL and each child is already sorted.

```
->  MergeAppend
      Sort Key: created_at
      ->  Index Scan on orders_2023q1 (idx_created_at)
      ->  Index Scan on orders_2023q2 (idx_created_at)
```

**Advantage over Append + Sort:** Avoids a full sort of the combined result. Each child provides sorted data; MergeAppend merges them in O(n log k) where k = number of children.

### Gather / Gather Merge

Collect results from parallel worker processes. See [Parallel Query Plans](#parallel-query-plans) for details.

---

## JIT Compilation

PostgreSQL 11+ includes LLVM-based JIT (Just-In-Time) compilation for expressions and tuple deforming.

### When JIT Helps

- **CPU-bound queries** processing millions of rows with complex expressions, aggregations, or WHERE clauses
- Queries where expression evaluation dominates execution time
- Large analytical queries with many columns or computed expressions

### When JIT Hurts

- **Short queries** (< 100ms): JIT compilation overhead (10-100ms) exceeds the savings
- OLTP workloads with simple predicates
- Queries that are I/O-bound (JIT doesn't help with disk reads)
- Queries run very frequently — compilation cost is amortized only within a single execution

### Controlling JIT

```sql
-- Global thresholds (postgresql.conf)
jit = on                            -- enable JIT globally
jit_above_cost = 100000             -- JIT expressions above this cost
jit_inline_above_cost = 500000      -- inline functions above this cost
jit_optimize_above_cost = 500000    -- apply LLVM optimizations above this cost

-- Per-session override
SET jit = off;                       -- disable JIT for this session
SET jit_above_cost = 50000;          -- lower threshold for this session
```

### Reading JIT Stats in EXPLAIN

```sql
EXPLAIN (ANALYZE, BUFFERS) SELECT complex_expression FROM large_table WHERE ...;
```

```
JIT:
  Functions: 12
  Options: Inlining true, Optimization true, Expressions true, Deforming true
  Timing: Generation 2.345 ms, Inlining 15.678 ms, Optimization 45.234 ms,
          Emission 30.456 ms, Total 93.713 ms
```

**Fields:**
| Field | Meaning |
|-------|---------|
| Functions | Number of functions JIT-compiled |
| Inlining | Whether LLVM inlined function calls |
| Optimization | Whether LLVM optimization passes ran |
| Expressions | Whether WHERE/SELECT expressions were JIT-compiled |
| Deforming | Whether tuple deforming was JIT-compiled |
| Generation | Time to generate LLVM IR |
| Inlining | Time for inlining pass |
| Optimization | Time for optimization passes |
| Emission | Time to emit machine code |
| Total | Total JIT overhead |

**Decision rule:** If `JIT Total` is a significant fraction of `Execution Time` (say >20%) and the query is fast (<500ms), JIT is likely hurting. Set `jit_above_cost` higher or disable JIT for that query class.

```sql
-- Quick check: is JIT helping or hurting?
-- Run with and without JIT, compare Execution Time
SET jit = on;
EXPLAIN (ANALYZE) SELECT ...;  -- note Execution Time and JIT Total

SET jit = off;
EXPLAIN (ANALYZE) SELECT ...;  -- note Execution Time
```

---

## Parallel Query Plans

### Reading Gather Nodes

```
Gather (actual time=5.2..150.3 rows=10000 loops=1)
  Workers Planned: 4
  Workers Launched: 4
  ->  Parallel Seq Scan on orders (actual time=0.1..120.5 rows=2500 loops=5)
        Filter: (status = 'active')
        Rows Removed by Filter: 47500
```

**Key fields:**
- **Workers Planned:** Number of parallel workers the planner wants
- **Workers Launched:** Number actually started (may be fewer if `max_parallel_workers` is exhausted)
- **loops=5:** The child node ran in 5 processes (4 workers + 1 leader)
- **rows=2500 per loop:** Each process handled ~2500 rows; total = 2500 × 5 = 12,500 (before Gather filtering)

### Gather vs Gather Merge

| Node | Behavior | Use Case |
|------|----------|----------|
| **Gather** | Collects rows from workers in arbitrary order | No ordering needed, or sort happens after Gather |
| **Gather Merge** | Merges pre-sorted results from workers, preserving order | Each worker produces sorted output; final result must be sorted |

```
Gather Merge (actual time=10.5..200.1 rows=50000 loops=1)
  Workers Planned: 4
  Workers Launched: 4
  ->  Sort (actual time=8.1..50.3 rows=12500 loops=5)
        Sort Key: created_at
        ->  Parallel Seq Scan on orders ...
```

Gather Merge avoids a separate Sort after collection. Each worker sorts its partition, and Gather Merge does a k-way merge.

### Parallel Safety

Not all operations can run in parallel workers. Operations are classified as:

| Safety Level | Meaning | Examples |
|-------------|---------|----------|
| **parallel safe** | Can run in any worker | Most built-in functions, simple expressions |
| **parallel restricted** | Must run in leader only | Queries on temp tables, cursor operations |
| **parallel unsafe** | Prevents parallelism entirely | User functions marked PARALLEL UNSAFE, writes (INSERT/UPDATE/DELETE in PG < 17) |

**Common parallel blockers:**
- Functions not marked `PARALLEL SAFE` (default for user functions is `PARALLEL UNSAFE`)
- Queries touching temporary tables
- `SELECT ... FOR UPDATE/SHARE`
- Queries inside serializable transactions

**Fix:** Mark your functions as parallel safe if they have no side effects:

```sql
CREATE OR REPLACE FUNCTION my_func(x INT) RETURNS INT
LANGUAGE sql PARALLEL SAFE IMMUTABLE
AS $$ SELECT x * 2; $$;
```

### Tuning Parallelism

```sql
-- Key GUCs
SET max_parallel_workers_per_gather = 4;     -- max workers per query node
SET max_parallel_workers = 8;                 -- max total parallel workers
SET max_worker_processes = 16;                -- max total background workers
SET parallel_tuple_cost = 0.01;               -- cost of transferring a tuple to leader
SET parallel_setup_cost = 1000;               -- cost of starting a worker
SET min_parallel_table_scan_size = '8MB';     -- minimum table size for parallel scan
SET min_parallel_index_scan_size = '512kB';   -- minimum index size for parallel scan
```

**Diagnosis: Workers Launched < Workers Planned**

Check current worker usage:
```sql
SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'parallel worker';
```

If at `max_parallel_workers`, no more workers are available. Either increase the limit or reduce parallelism of concurrent queries.

---

## CTEs vs Subqueries

### Pre-PG 12: CTEs as Optimization Fences

Before PostgreSQL 12, every CTE was **materialized** — computed once, stored in memory/temp file, and scanned as a static result. The planner could not:
- Push predicates into the CTE
- Eliminate unused CTE columns
- Merge the CTE with the outer query

This made CTEs an intentional optimization fence (sometimes useful for plan stability, usually harmful for performance).

### PG 12+: Automatic Inlining

PostgreSQL 12 introduced automatic CTE inlining. A CTE is inlined (not materialized) when:
1. It is **not recursive**
2. It has **no side effects** (not a data-modifying CTE)
3. It is referenced **exactly once** in the outer query
4. It is not explicitly marked `MATERIALIZED`

```sql
-- INLINED (PG 12+): treated like a subquery, predicates pushed down
WITH recent AS (
    SELECT * FROM orders WHERE created_at > '2024-01-01'
)
SELECT * FROM recent WHERE total > 100;

-- Plan: single Index Scan with both predicates
```

```sql
-- MATERIALIZED: explicit fence, no predicate pushdown
WITH recent AS MATERIALIZED (
    SELECT * FROM orders WHERE created_at > '2024-01-01'
)
SELECT * FROM recent WHERE total > 100;

-- Plan: Seq Scan/Index Scan into CTE, then CTE Scan with Filter
```

```sql
-- MATERIALIZED (implicit): referenced twice
WITH recent AS (
    SELECT * FROM orders WHERE created_at > '2024-01-01'
)
SELECT * FROM recent WHERE total > 100
UNION ALL
SELECT * FROM recent WHERE total <= 100;

-- Referenced 2x → materialized → computed once, scanned twice
```

### When to Force MATERIALIZED

- **Preventing repeated expensive computation:** If a CTE is referenced multiple times and is expensive, materialization computes it once
- **Plan stability:** Force a specific join order by materializing intermediate results
- **Avoiding bad plans:** When the planner makes poor cardinality estimates that propagate into the outer query, materialization can give the outer query better stats

### When to Force NOT MATERIALIZED

```sql
-- Force inlining even when referenced multiple times (PG 12+)
WITH recent AS NOT MATERIALIZED (
    SELECT * FROM orders WHERE created_at > '2024-01-01'
)
SELECT * FROM recent r1 JOIN recent r2 ON r1.customer_id = r2.customer_id;
```

**Warning:** `NOT MATERIALIZED` on a multiply-referenced CTE means the subquery executes multiple times. Only use if the planner produces a better plan with inlining.

### Identifying CTE Materialization in EXPLAIN

Look for `CTE Scan` nodes:
- **CTE Scan present** → CTE was materialized
- **No CTE Scan** → CTE was inlined (merged into outer query)

```
CTE recent
  ->  Seq Scan on orders (actual time=0.05..50.00 rows=100000 loops=1)
        Filter: (created_at > '2024-01-01')
->  CTE Scan on recent (actual time=0.01..30.00 rows=5000 loops=1)
      Filter: (total > 100)
      Rows Removed by Filter: 95000   ← 95% of CTE rows wasted
```

If `Rows Removed by Filter` on a CTE Scan is high, the CTE should probably be inlined or the filter pushed into the CTE definition.

---

## Window Function Execution Plans

### Typical Plan Structure

```sql
SELECT id, department, salary,
       rank() OVER (PARTITION BY department ORDER BY salary DESC)
FROM employees;
```

```
WindowAgg (actual time=5.0..25.0 rows=10000 loops=1)
  ->  Sort (actual time=3.0..4.5 rows=10000 loops=1)
        Sort Key: department, salary DESC
        Sort Method: quicksort  Memory: 1200kB
        ->  Seq Scan on employees (actual time=0.01..1.5 rows=10000 loops=1)
```

**Pattern:** WindowAgg always requires sorted input matching the `PARTITION BY` + `ORDER BY` of the window specification. The Sort node beneath it provides this ordering.

### Multiple Window Functions

If multiple window functions share the same `PARTITION BY / ORDER BY`, they share a single Sort + WindowAgg:

```sql
SELECT id,
       rank() OVER w,
       dense_rank() OVER w,
       row_number() OVER w
FROM employees
WINDOW w AS (PARTITION BY department ORDER BY salary DESC);
```

```
WindowAgg                    ← computes all three functions in one pass
  ->  Sort (department, salary DESC)
        ->  Seq Scan on employees
```

Different window specifications require separate Sort + WindowAgg stacks:

```sql
SELECT id,
       rank() OVER (PARTITION BY department ORDER BY salary DESC),
       row_number() OVER (ORDER BY hire_date)
FROM employees;
```

```
WindowAgg                    ← second window function (ORDER BY hire_date)
  ->  Sort (hire_date)
        ->  WindowAgg          ← first window function (PARTITION BY department ...)
              ->  Sort (department, salary DESC)
                    ->  Seq Scan on employees
```

**Optimization:** Minimize distinct window specifications. Consolidate where possible to avoid multiple sorts.

### Index-Backed Window Functions

If an index matches the window's `PARTITION BY + ORDER BY`, the planner can skip the Sort:

```sql
CREATE INDEX idx_emp_dept_salary ON employees (department, salary DESC);

-- Plan now uses Index Scan instead of Seq Scan + Sort
WindowAgg
  ->  Index Scan using idx_emp_dept_salary on employees
```

This is a significant win for large tables. Check that the index column order matches exactly.

### Window Functions with Frame Clauses

Complex frame clauses (`ROWS BETWEEN`, `RANGE BETWEEN`, `GROUPS BETWEEN`) don't change the plan structure but affect WindowAgg execution time. Wide frames (e.g., `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`) can be slow because the aggregate must track all preceding rows.

**Tip:** `ROWS` mode is faster than `RANGE` mode (the default) because `RANGE` must handle ties.

---

## The "Actual Loops × Actual Time" Trap

This is the single most common mistake when reading EXPLAIN ANALYZE output.

### The Problem

EXPLAIN ANALYZE reports `actual time` and `rows` as **per-loop averages**, but `loops` can be large. The **true cost** of a node is:

```
True Time = actual time × loops
True Rows = rows × loops
```

### Example

```
Nested Loop (actual time=0.05..500.00 rows=100000 loops=1)
  ->  Seq Scan on customers (actual time=0.01..5.00 rows=1000 loops=1)
  ->  Index Scan on orders (actual time=0.02..0.45 rows=100 loops=1000)
        Index Cond: (customer_id = customers.id)
```

**Naive reading:** "The Index Scan on orders takes 0.45ms — it's fast!"

**Correct reading:** The Index Scan runs 1000 times (once per customer). True time = 0.45 × 1000 = **450ms**. It dominates the query.

### Spotting the Trap

Look for nodes where:
- `loops` > 1 (especially > 100)
- `actual time` looks small but `loops` is large
- Inner side of Nested Loop joins

### Real-World Impact

```
Nested Loop (actual time=0.1..2500.0 rows=50000 loops=1)
  ->  Seq Scan on departments (actual time=0.01..0.5 rows=50 loops=1)
  ->  Index Scan on employees (actual time=0.02..45.0 rows=1000 loops=50)
        ↑ looks like 45ms, actually 45 × 50 = 2250ms
```

### Buffer Counts Are Also Per-Loop

```
->  Index Scan on orders (actual time=0.02..0.45 rows=100 loops=1000)
      Buffers: shared hit=300 read=5
```

True buffer hits = 300 × 1000 = **300,000**. True disk reads = 5 × 1000 = **5,000**.

### Tools That Handle This Correctly

- **explain.depesz.com:** Shows "exclusive" and "inclusive" time with loops factored in
- **explain.dalibo.com (PEV2):** Multiplies time × loops in its summary
- **pgAdmin:** Shows per-loop values; you must multiply manually

### Quick Mental Model

When reading EXPLAIN ANALYZE:
1. Find nodes with `loops > 1`
2. Multiply `actual time` × `loops` for true time
3. Multiply `rows` × `loops` for true row count
4. Multiply `Buffers` × `loops` for true I/O
5. Compare the multiplied values to find the real bottleneck
