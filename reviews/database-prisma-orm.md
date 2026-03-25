# QA Review: database/prisma-orm

**Reviewer:** Copilot CLI (automated)
**Date:** 2025-07-15
**Skill path:** `~/skillforge/database/prisma-orm/`

---

## A. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter `name` | ✅ Pass | `prisma-orm` |
| YAML frontmatter `description` | ✅ Pass | Detailed, multi-line |
| Positive triggers | ✅ Pass | Covers schema files, Client queries, migrations, raw SQL, extensions, Accelerate, seeding, testing |
| Negative triggers | ✅ Pass | Explicitly excludes SQLAlchemy, Django ORM, TypeORM, Drizzle, Sequelize, Knex, raw-SQL-only, MongoDB native, general DBA |
| Body under 500 lines | ✅ Pass | 380 lines (well under 500) |
| Imperative voice | ✅ Pass | "Use `select` over `include`", "Add `@@index`", "Never instantiate per request", "Never mix `select` and `include`" |
| Code examples | ✅ Pass | Extensive examples for every section — schema, CRUD, filtering, pagination, transactions, raw SQL, migrations, extensions, error handling, testing |
| References linked from SKILL.md | ✅ Pass | Section "Reference Docs (`references/`)" lists all three files with descriptions |
| Scripts linked from SKILL.md | ✅ Pass | Section "Scripts (`scripts/`)" lists both scripts with usage |
| Assets linked from SKILL.md | ✅ Pass | Section "Templates (`assets/`)" lists all three templates |

**Structure verdict: PASS** — Clean, well-organized, all supporting files documented.

---

## B. Content Check

### API names verified (web-searched against official Prisma docs)

| API / Concept | Skill accuracy | Notes |
|---------------|---------------|-------|
| `findUnique`, `findFirst`, `findMany` | ✅ Correct | |
| `findUniqueOrThrow`, `findFirstOrThrow` | ✅ Correct | Correctly notes P2025 in Prisma 6 |
| `create`, `createMany`, `update`, `upsert`, `delete`, `deleteMany` | ✅ Correct | |
| `createManyAndReturn` | ✅ Correct | Documented in api-reference.md (Prisma 5.14+) |
| `updateManyAndReturn` | ⚠️ Missing | Available since Prisma 6.2; not mentioned anywhere in skill |
| `$queryRaw`, `$executeRaw`, `$queryRawUnsafe` | ✅ Correct | |
| `$queryRawTyped` (TypedSQL) | ✅ Correct | Correctly shows SQL file + generate --sql workflow |
| `$transaction` (batch + interactive) | ✅ Correct | Both patterns shown with options |
| `$extends` (client extensions) | ✅ Correct | Result, model, client, query extensions all covered |
| `Prisma.defineExtension` | ✅ Correct | Used in advanced-patterns.md |
| `$connect` / `$disconnect` | ✅ Correct | |
| `$on` (event system) | ✅ Correct | |
| Filter operators (`contains`, `startsWith`, `in`, `some`, `every`, `none`, `is`, `isNot`) | ✅ Correct | |
| `skipDuplicates` | ✅ Correct | |
| `relationLoadStrategy` | ✅ Correct | `'join'` (default Prisma 6) and `'query'` |

### Schema syntax verified

| Syntax | Status | Notes |
|--------|--------|-------|
| `datasource`, `generator` blocks | ✅ Correct | |
| Model attributes (`@id`, `@unique`, `@@unique`, `@default`, `@updatedAt`, `@map`, `@@map`, `@db.VarChar`, `@@index`) | ✅ Correct | |
| Scalar types list | ✅ Correct | String, Int, BigInt, Float, Decimal, Boolean, DateTime, Json, Bytes |
| Relation attributes (`@relation`, `fields`, `references`, `onDelete`) | ✅ Correct | |
| `enum` syntax | ✅ Correct | |
| `view` keyword | ✅ Correct | Covered in advanced-patterns.md |
| `@@fulltext` | ✅ Correct | Noted for MySQL (GA) and PostgreSQL (preview) |
| `previewFeatures` | ✅ Correct | |
| Multi-schema (`schemas`, `@@schema`) | ✅ Correct | |

### Migration commands verified

| Command | Status |
|---------|--------|
| `npx prisma migrate dev --name` | ✅ Correct |
| `npx prisma migrate deploy` | ✅ Correct |
| `npx prisma migrate reset` | ✅ Correct |
| `npx prisma migrate status` | ✅ Correct |
| `npx prisma migrate resolve --applied/--rolled-back` | ✅ Correct |
| `npx prisma migrate diff` | ✅ Correct |
| `npx prisma db push` | ✅ Correct |
| `npx prisma db pull` | ✅ Correct |
| `npx prisma db seed` | ✅ Correct |
| `npx prisma validate` | ✅ Correct |
| `npx prisma generate --sql` | ✅ Correct |

### Prisma 6 features

| Feature | Covered? | Notes |
|---------|----------|-------|
| Min Node 18.18, TS 5.1 | ✅ Yes | |
| `Bytes` → `Uint8Array` | ✅ Yes | |
| `NotFoundError` removed → P2025 | ✅ Yes | |
| New client generator `prisma-client` | ✅ Yes | |
| Custom output path | ✅ Yes | |
| Adapter pattern (`@prisma/adapter-pg`) | ✅ Yes | |
| `relationLoadStrategy` default `'join'` | ✅ Yes | |
| Nested create optimization (bulk inserts) | ✅ Yes | |
| `prisma.config.ts` | ✅ Yes | Mentioned but not deeply covered |
| `prismaSchemaFolder` / multi-file schema | ❌ Missing | Not mentioned; significant Prisma 6 feature |
| `updateManyAndReturn` | ❌ Missing | Added in Prisma 6.2 |

### Missing gotchas / gaps

1. **`@@fulltext` in PostgreSQL template**: The `schema.template.prisma` uses `@@fulltext([title, content])` with a PostgreSQL datasource. `@@fulltext` is MySQL-only for GA; PostgreSQL full-text search uses the `search` filter operator with `previewFeatures = ["fullTextSearchPostgres"]` (which the template does enable), but the `@@fulltext` index attribute itself is MySQL-specific and would cause a validation error on PostgreSQL. **This is a bug in the template.**

2. **Multi-file schema**: No mention of `prismaSchemaFolder` preview feature or `prisma.config.ts` `schema` directory option — an increasingly popular Prisma 6 workflow.

3. **`updateManyAndReturn`**: Missing from both SKILL.md and api-reference.md despite being available since Prisma 6.2 for PostgreSQL/CockroachDB/SQLite.

4. **`omit` API**: Prisma 5.16+ added a global `omit` option and per-query `omit` to exclude fields (e.g., password). Not mentioned.

### Examples correctness

All code examples compile correctly and follow current Prisma API patterns. The singleton pattern, NestJS integration, Next.js usage, seed script, and error handling patterns are all idiomatic and accurate.

---

## C. Trigger Check

**Description quality:** The description is comprehensive and specific. It enumerates key Prisma concepts (schema files, Client queries, relations, transactions, aggregations, raw SQL, TypedSQL, middleware, extensions, Accelerate, seeding, testing). The explicit negative triggers prevent false matches against 7 competing ORMs/tools.

| Aspect | Assessment |
|--------|------------|
| Will trigger on "write a Prisma schema" | ✅ Yes |
| Will trigger on "Prisma Client query" | ✅ Yes |
| Will trigger on "prisma migrate" | ✅ Yes |
| Will trigger on "$extends" | ✅ Yes |
| Will trigger on "Prisma Accelerate caching" | ✅ Yes |
| False trigger on "Drizzle ORM query" | ✅ No — explicitly excluded |
| False trigger on "TypeORM migration" | ✅ No — explicitly excluded |
| False trigger on "raw SQL query" (no Prisma context) | ✅ No — excluded |
| False trigger on "MongoDB native driver" | ✅ No — excluded |
| Missing trigger on "prisma.config.ts" | ⚠️ Possible miss — not in description |

**Trigger verdict:** Strong. Broad positive coverage, clean negative boundaries. Minor gap on `prisma.config.ts`.

---

## D. Scores

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 4 | All API names, schema syntax, and migration commands are correct. One bug: `@@fulltext` in PostgreSQL template. |
| **Completeness** | 4 | Excellent coverage of core + advanced topics. Missing `updateManyAndReturn`, `omit` API, and multi-file schema. Reference docs are thorough (750+763+632 = 2145 lines of supporting material). |
| **Actionability** | 5 | Imperative instructions, copy-paste examples, ready-to-use templates, working shell scripts, performance checklist, clear "do this / don't do that" patterns. |
| **Trigger quality** | 5 | Precise positive triggers covering all Prisma domains. Explicit negative exclusions for 7+ competing tools. Very low false-positive risk. |

### **Overall: 4.5 / 5.0**

---

## E. Issues

No issues required (overall ≥ 4.0 and no dimension ≤ 2).

**Recommended improvements** (non-blocking):
1. Fix `@@fulltext` in `schema.template.prisma` — remove it or switch template to MySQL, or add a comment noting it's MySQL-only
2. Add `updateManyAndReturn` to SKILL.md and api-reference.md
3. Add `omit` API (per-query and global) to filtering / select section
4. Add `prismaSchemaFolder` / multi-file schema section under Prisma 6 Changes
5. Mention `prisma.config.ts` `defineConfig` in Setup or Prisma 6 section

---

## F. Test Status

**Result: PASS**

Review path: `~/skillforge/reviews/database-prisma-orm.md`
