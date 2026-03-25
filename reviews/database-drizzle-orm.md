# QA Review: drizzle-orm

**Skill path:** `~/skillforge/database/drizzle-orm/`
**Reviewer:** Copilot CLI (automated)
**Date:** 2025-07-17

---

## a. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter (`name`, `description`) | ✅ Pass | `name: drizzle-orm`, multi-line `description` present |
| Positive triggers | ✅ Pass | Exhaustive: pgTable, mysqlTable, sqliteTable, select/insert/update/delete, drizzle-kit commands, relational API, type inference, edge runtimes, transactions, joins, etc. |
| Negative triggers | ✅ Pass | Excludes Prisma, TypeORM, Sequelize, SQLAlchemy, raw SQL without ORM, MongoDB/Mongoose, Knex.js |
| Body under 500 lines | ✅ Pass | 464 lines (36 lines of headroom) |
| Imperative voice | ✅ Pass | "Always install both", "Pass schema for relational queries", "Never use push on production" |
| Examples | ✅ Pass | Every section has copy-paste-ready TypeScript/bash with imports shown |
| References/scripts linked | ✅ Pass | `references/` (3 files), `scripts/` (2 files), `assets/` (3 templates) all described in Resources section |

---

## b. Content Check (Web-Verified)

### Verified Correct

| Item | Status |
|------|--------|
| `drizzle-kit generate / migrate / push / pull / studio / check / up` | ✅ All commands verified current |
| `$inferSelect` / `$inferInsert` type inference | ✅ Correct syntax |
| `onConflictDoUpdate` / `onConflictDoNothing` | ✅ Correct API |
| `onDuplicateKeyUpdate` (MySQL) | ✅ Correct |
| `db.query.users.findMany({ with: { posts: true } })` relational API | ✅ Correct |
| `placeholder()` for prepared statements | ✅ Correct |
| `pgTable` / `mysqlTable` / `sqliteTable` builders | ✅ Correct |
| `pgEnum` / `mysqlEnum` / SQLite text enum | ✅ Correct |
| `relations()` with `one()` / `many()` | ✅ Correct |
| Column types (serial, integer, text, varchar, boolean, timestamp, jsonb, uuid, etc.) | ✅ Accurate per dialect |
| Driver imports (`drizzle-orm/node-postgres`, `/postgres-js`, `/mysql2`, `/better-sqlite3`, `/libsql`, `/bun-sqlite`, `/d1`, `/neon-http`, `/vercel-postgres`) | ✅ All verified |
| `defineConfig` from `drizzle-kit` | ✅ Correct |
| Programmatic `migrate()` per driver subpath | ✅ Correct |
| `db.transaction()` with nested savepoints, `tx.rollback()` | ✅ Correct |
| `sql` template tag, `sql.raw()`, `sql.join()` | ✅ Correct |
| `$onUpdate(() => new Date())` for updatedAt | ✅ Correct |
| `customType` from `drizzle-orm/pg-core` | ✅ Correct |
| `drizzle-kit introspect` → renamed to `pull` | ✅ Skill correctly uses `pull` |

### Minor Issues / Missing Items

1. **`serial` deprecation note missing**: The `api-reference.md` correctly notes "`serial` — legacy, prefer `identity`", but SKILL.md uses `serial` exclusively without any deprecation caveat. Recent Drizzle guidance recommends `identity` columns for PostgreSQL.

2. **Simplified `drizzle()` init not mentioned**: Newer Drizzle ORM versions support passing a connection string directly to `drizzle()` (e.g., `drizzle('postgres://...')`) without manually instantiating a Pool/client. The skill only shows the traditional explicit-client pattern.

3. **`casing` option not mentioned**: Drizzle now supports a `casing` option for automatic camelCase ↔ snake_case column name mapping — a commonly used DX feature absent from SKILL.md and references.

4. **`setWhere` in upsert (api-reference.md line 331)**: The property name `setWhere` may be outdated — current docs use `where` inside `onConflictDoUpdate`. This is in the reference file only, not SKILL.md.

5. **`drizzle-seed` coverage is thin**: Mentioned in `advanced-patterns.md` but the `drizzle-seed` package API details are minimal (just the `refine` example). No mention of `reset()` function.

### Gotchas Coverage

The troubleshooting reference is excellent — covers:
- ✅ N+1 avoidance, bigint coercion, JSONB typing
- ✅ Migration journal merge conflicts
- ✅ `prepared statement already exists` error
- ✅ better-sqlite3 native module rebuild
- ✅ Version mismatch between drizzle-orm and drizzle-kit
- ✅ Edge runtime driver limitations
- ✅ TypeScript strict mode pitfalls
- ✅ Common error messages table
- ✅ `toSQL()` debugging and query logging

---

## c. Trigger Check

| Aspect | Assessment |
|--------|------------|
| **Description completeness** | Very thorough — 13 lines covering schemas, queries, relations, drizzle-kit, drivers, runtimes, types, patterns |
| **False positive risk** | Low. Explicit ORM-specific terms (pgTable, drizzle-kit, onConflictDoUpdate) are unique to Drizzle |
| **False negative risk** | Low-medium. Missing "Drizzle Studio" and "drizzle-seed" as explicit trigger terms |
| **Negative trigger quality** | Good. Six competing tools explicitly excluded |
| **Description length** | Slightly long (13 lines) but justified by breadth of API surface |

**Suggestion**: Add `drizzle-seed`, `Drizzle Studio`, and `identity column` to positive triggers.

---

## d. Scores

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 4 | All major APIs verified correct. Minor: `serial` used without deprecation note; missing newer simplified `drizzle()` init; `setWhere` in reference may be stale |
| **Completeness** | 5 | Exceptionally thorough: 3 dialects × full CRUD + relations + joins + CTEs + views + materialized views + multi-schema + seeding + migrations + edge runtimes + troubleshooting + templates + scripts |
| **Actionability** | 5 | Every example is copy-paste-ready with imports. `init-drizzle.sh` automates full project setup. `migration-ops.sh` wraps all drizzle-kit ops. Templates cover all runtimes. |
| **Trigger quality** | 4 | Comprehensive positive/negative triggers. Could add a few more trigger terms (Drizzle Studio, drizzle-seed, identity columns) |
| **Overall** | **4.5** | High-quality skill. Minor freshness gaps don't impact day-to-day utility |

---

## e. GitHub Issues

**No issues required.** Overall score (4.5) ≥ 4.0 and no dimension ≤ 2.

---

## f. Tested Status

**Result: PASS**

The skill is accurate, comprehensive, and immediately actionable. The minor gaps (simplified init API, `serial` deprecation note, `casing` option) are non-blocking enhancements.

---

## Recommendations (non-blocking)

1. Add a note after `serial('id').primaryKey()` examples: _"For new PostgreSQL schemas, consider `integer().primaryKey().generatedAlwaysAsIdentity()` — `serial` is legacy."_
2. Add the simplified `drizzle('postgres://...')` initialization pattern alongside the explicit Pool pattern.
3. Mention the `casing: 'snake_case'` option in the drizzle config or schema section.
4. Verify `setWhere` → `where` in `api-reference.md` upsert section.
5. Add `Drizzle Studio`, `drizzle-seed`, and `identity` to the description triggers.
