# QA Review: databases/drizzle-orm

**Reviewer**: Copilot CLI (automated)
**Date**: 2025-07-17
**Skill path**: `~/skillforge/databases/drizzle-orm/`

---

## a. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML `name` field | ✅ Pass | `drizzle-orm` |
| YAML `description` field | ✅ Pass | Present, detailed |
| Positive triggers in description | ✅ Pass | Covers imports (`drizzle-orm`, `drizzle-orm/pg-core`, `drizzle-kit`), keywords (`pgTable`, `sqliteTable`, `drizzle migrations`, `drizzle-kit generate/push/migrate/studio/introspect`), and concepts (`drizzle relations`, `drizzle query builder`, `drizzle prepared statements`, `drizzle transactions`) |
| Negative triggers in description | ✅ Pass | Excludes Prisma, TypeORM, Kysely, Sequelize, Knex, MikroORM, MongoDB, Mongoose, NoSQL |
| Body line count | ✅ Pass | 481 lines (under 500 limit) |
| Imperative voice, no filler | ✅ Pass | Concise, direct, action-oriented throughout |
| Examples with input/output | ✅ Pass | Extensive code examples for every API: schema, queries, relations, joins, transactions, type inference. Output type annotations inline (e.g., `// => { id: number; name: string }[]`) |
| References properly linked | ✅ Pass | 3 reference docs linked and verified: `advanced-patterns.md`, `troubleshooting.md`, `framework-integration.md` |
| Scripts properly linked | ✅ Pass | 3 scripts linked and verified: `setup-drizzle.sh`, `generate-schema.sh`, `seed-database.ts` |
| Assets properly linked | ✅ Pass | 4 assets linked and verified: `drizzle.config.ts`, `schema-template.ts`, `db-client.ts`, `docker-compose.yml` |

---

## b. Content Check — Accuracy Verification

### Drizzle ORM APIs (pgTable, select, insert, relations)
- ✅ `pgTable`, `sqliteTable`, `mysqlTable` definitions are correct
- ✅ Column helpers (`serial`, `text`, `integer`, `varchar`, `timestamp`, `boolean`) are accurate
- ✅ `.references()` syntax with `onDelete` option is correct
- ✅ `relations()` API with `one()` / `many()` is accurate
- ✅ Query builder API (`select`, `insert`, `update`, `delete`) syntax verified
- ✅ Relational query API (`db.query.*.findMany`, `findFirst`, `with`) is correct
- ✅ Index definition uses modern array syntax `(table) => [...]` (v0.36.0+) — correct for current versions

### drizzle-kit Commands
- ✅ `generate`, `migrate`, `push`, `pull`, `studio`, `check`, `up` — all accurate
- ✅ Correctly uses `pull` (not the deprecated `introspect` name)
- ✅ `defineConfig` from `drizzle-kit` is the current config API
- ✅ `dialect` property values (`'postgresql'`, `'mysql'`, `'sqlite'`, `'turso'`) are correct

### Driver Setups
- ✅ `drizzle-orm/postgres-js` with `postgres` driver — correct
- ✅ `drizzle-orm/better-sqlite3` with `better-sqlite3` — correct
- ✅ `drizzle-orm/libsql` with `@libsql/client` — correct
- ✅ `drizzle-orm/mysql2` with `mysql2/promise` — correct
- ✅ `drizzle-orm/neon-http` and `drizzle-orm/neon-serverless` — correct
- ✅ `drizzle-orm/d1`, `drizzle-orm/vercel-postgres`, `drizzle-orm/planetscale-serverless` — correct
- ✅ `drizzle-orm/bun-sqlite` — correct
- ✅ `drizzle-orm/node-postgres` with `pg` — correct

### Type Inference API
- ✅ `$inferSelect` / `$inferInsert` as `typeof table.$inferSelect` — correct
- ✅ `InferSelectModel` / `InferInsertModel` helper functions — correct
- ✅ Semantics explained correctly: `$inferInsert` makes defaulted/nullable fields optional

### Issues Found

1. **D1 `.returning()` claim is incorrect** (framework-integration.md, line 399):
   The reference states "No `.returning()`" for D1. However, Cloudflare D1 uses SQLite 3.35.0+ which supports `RETURNING`, and Drizzle ORM's D1 driver supports `.returning()` as of 2024. This is a factual error in the reference document.

2. **Missing modern PK pattern** (`generatedAlwaysAsIdentity`):
   All PostgreSQL examples use `serial('id')` for primary keys. In 2025, the recommended best practice is `integer('id').generatedAlwaysAsIdentity()` per SQL standard and Drizzle docs. While `serial` still works, the skill should mention the modern alternative.

3. **Minor: description mentions `introspect` as trigger keyword** (YAML line 8):
   The trigger description includes "drizzle-kit generate/push/migrate/studio/introspect". The command has been renamed to `pull`. While triggering on `introspect` is acceptable (users may still search for it), the body correctly uses `pull`.

---

## c. Trigger Check

| Aspect | Status | Notes |
|--------|--------|-------|
| Positive triggers cover main use cases | ✅ Pass | Imports, table helpers, config files, commands, concepts all covered |
| Negative triggers prevent false positives | ✅ Pass | Excludes all major competing ORMs and NoSQL |
| Edge cases handled | ✅ Pass | Includes `drizzle.config.ts`, relation queries, prepared statements, transactions |
| False positive risk | ✅ Low | Clear scoping to Drizzle-specific terms; no generic terms like "database" or "SQL" alone |

---

## d. Scoring

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 4 | APIs, commands, driver setups, and syntax are all correct for current Drizzle versions. One factual error in reference doc (D1 `.returning()`). Uses array syntax for indexes (v0.36.0+). |
| **Completeness** | 4 | Exceptionally thorough: 3 dialects, 11 driver variants, framework integrations, advanced patterns (CTEs, window functions, FTS, PostGIS), testing patterns, troubleshooting. Missing identity columns as modern PK alternative. |
| **Actionability** | 5 | Every concept has runnable code. Setup script auto-detects package manager. Seed script with faker. Docker Compose for local dev. Schema templates ready to copy. |
| **Trigger quality** | 5 | Comprehensive positive triggers covering imports, APIs, and concepts. Clear negative triggers excluding all competing tools. No false positive risk. |
| **Overall** | **4.5** | High-quality skill with excellent breadth and actionability. Minor accuracy issue in one reference file and missing one modern best practice. |

---

## e. Issue Filing

**Overall score 4.5 ≥ 4.0** and **no dimension ≤ 2** → No GitHub issues required.

### Recommended improvements (non-blocking):

1. Fix D1 `.returning()` claim in `references/framework-integration.md` line 399 — D1 supports `.returning()`.
2. Add `generatedAlwaysAsIdentity()` as the recommended modern PK pattern alongside `serial()` in the Schema Definition section.
3. Consider mentioning the simplified `drizzle()` constructor API (newer versions allow passing URL directly).

---

## f. Test Status

**PASS** — Skill meets all quality thresholds.

Appended `<!-- tested: pass -->` to SKILL.md.
