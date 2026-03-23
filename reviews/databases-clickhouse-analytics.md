# Review: clickhouse-analytics

Accuracy: 4/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 5/5
Overall: 4.8/5

## Issues

### 1. Two server-level settings incorrectly shown as SET-level (SKILL.md lines 414–415)

In the "Performance Tuning Settings" section, `background_pool_size` and `parts_to_throw_insert` are shown as `SET` query-level commands:

```sql
SET background_pool_size = 16;
SET parts_to_throw_insert = 300;
```

These are server-level MergeTree settings that must be configured in `config.xml` (under `<merge_tree>`) or via `ALTER TABLE ... MODIFY SETTING` (for `parts_to_throw_insert`). Running `SET background_pool_size = 16` in a modern ClickHouse session will either be silently ignored or produce a warning. The remaining 16 settings in that block are correctly SET-able at the session level.

**Fix:** Move these two into a separate "Server-level settings (config.xml)" sub-block with XML syntax, matching how they already appear correctly in `assets/clickhouse-server-config.xml` lines 102–109.

### 2. Minor: `AggregateFunction(count, UInt64)` vs `AggregateFunction(count)` (SKILL.md line 139)

The `hourly_stats` table defines `cnt AggregateFunction(count, UInt64)` but the MV populates it with `countState()` (no args). Strictly, `countState()` without arguments pairs with `AggregateFunction(count)` (no type arg). This works in practice on recent ClickHouse versions, but for correctness the type should be `AggregateFunction(count)` or the MV should use `countState(user_id)`. Same pattern in `assets/analytics-schema.sql` line 71.

### 3. Minor: `uniqHLL12` error rate inconsistency

SKILL.md line 197 says "~2% error" for `uniqHLL12`, while `references/advanced-patterns.md` line 349 correctly says "~1.6% error". The ~1.6% figure matches ClickHouse documentation.

## Structure Check

- ✅ YAML frontmatter has `name` and `description`
- ✅ Description has positive triggers (8 specific use cases) AND negative triggers (4 exclusions)
- ✅ Body is 460 lines (under 500 limit)
- ✅ Imperative voice throughout, no filler
- ✅ Abundant SQL examples with expected behavior
- ✅ `references/`, `scripts/`, and `assets/` properly linked from SKILL.md via tables

## Content Check

- ✅ Version info accurate: says "v25.x", confirmed latest is v25.5.x
- ✅ SQL syntax correct across all examples (CREATE TABLE, MV, projections, dictionaries)
- ✅ Table engine descriptions accurate (MergeTree family, Replicated prefix)
- ✅ Configuration values match ClickHouse defaults (index_granularity=8192, background_pool_size default=16)
- ✅ Anti-patterns list is practical and accurate
- ✅ Scripts are executable with proper argument parsing, env var fallbacks, and error handling
- ✅ Docker Compose is a complete working 2-shard × 2-replica cluster with Keeper
- ✅ Grafana dashboard JSON is valid and uses correct system table queries
- ✅ Migration guide covers 4 source systems with accurate type mappings
- ✅ Troubleshooting covers 10 failure scenarios with diagnosis + fix steps

## Trigger Check

- ✅ Would trigger for "set up ClickHouse for analytics" — matches keywords and use cases
- ✅ Would trigger for "optimize ClickHouse queries" — matches "optimizing columnar query performance"
- ✅ Would trigger for "ClickHouse vs BigQuery" — explicit comparison section
- ✅ Would trigger for "migrate PostgreSQL to ClickHouse" — migration guide linked
- ✅ Would NOT falsely trigger for "set up PostgreSQL" — explicit negative trigger
- ✅ Would NOT falsely trigger for "Redis caching" — explicit negative trigger
- ✅ Keywords are comprehensive and specific

## Strengths

- Exceptionally thorough coverage from schema design to production operations
- Three reference files (877 + 718 + 664 lines) provide deep-dive content without bloating SKILL.md
- Three executable scripts with consistent CLI patterns (env vars, flags, help text)
- Five asset files provide ready-to-use templates (schema, config, users, Grafana, Docker)
- Anti-patterns section prevents common mistakes proactively
- Comparison table gives clear decision criteria vs alternatives
