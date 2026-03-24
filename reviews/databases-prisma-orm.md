# Review: prisma-orm

Accuracy: 4/5
Completeness: 4/5
Actionability: 5/5
Trigger quality: 5/5
Overall: 4.5/5
Issues:

1. **`prismaSchemaFolder` listed as preview feature (outdated):** Line 407 states `previewFeatures = ["prismaSchemaFolder"]`, but this feature graduated to GA in Prisma 6.7.0 (April 2025). The preview flag is no longer required.

2. **Missing `findFirstOrThrow` from Read section:** The CRUD Read section documents `findUniqueOrThrow` but omits `findFirstOrThrow`, which is a standard Prisma Client method.

3. **Missing `count`, `aggregate`, `groupBy` from main CRUD section:** These are important query methods. They appear in `references/performance-guide.md` but not in the main SKILL.md body, which could cause an AI to miss them for basic use cases.

4. **Missing ESM/module compatibility gotcha:** Prisma 6+ generates ESM-compatible output and code-splits by default. Engineers upgrading from older versions frequently hit import/require mismatches. Not mentioned in gotchas.

5. **Missing PlanetScale/Vitess `relationMode` note:** When using PlanetScale (no FK constraints), you must set `relationMode = "prisma"` and manually add indexes on relation fields. This is a common stumbling point not covered.

## Structure Check

| Criterion | Status |
|-----------|--------|
| YAML frontmatter `name` + `description` | ✅ Pass |
| Positive triggers in description | ✅ Pass — 12 specific trigger scenarios |
| Negative triggers in description | ✅ Pass — 10 explicit exclusions + general exclusion |
| Body under 500 lines | ✅ Pass — 494 lines |
| Imperative voice, no filler | ✅ Pass — direct, no fluff |
| Examples with input/output | ✅ Pass — extensive code examples throughout |
| references/ linked from SKILL.md | ✅ Pass — table with 3 guides |
| scripts/ linked from SKILL.md | ✅ Pass — table with 3 scripts |
| assets/ linked from SKILL.md | ✅ Pass — table with 5 templates |

## Content Check

| Topic | Status | Notes |
|-------|--------|-------|
| CLI commands (migrate dev/deploy/reset/status/diff) | ✅ Accurate | Verified against current Prisma docs |
| Prisma Client CRUD API | ✅ Mostly accurate | Missing findFirstOrThrow, count, aggregate, groupBy in main body |
| Connection pooling params | ✅ Accurate | connection_limit, pool_timeout correctly documented |
| Prisma Accelerate | ✅ Accurate | @prisma/extension-accelerate + withAccelerate confirmed current |
| Edge/serverless adapters | ✅ Accurate | adapter-neon, adapter-planetscale, adapter-d1, adapter-libsql all valid |
| Error codes (P2002/P2003/P2025/P2024) | ✅ Accurate | Correct codes and handling patterns |
| Schema syntax | ✅ Accurate | All attributes, relations, and model definitions correct |
| Multi-file schema | ⚠️ Outdated | prismaSchemaFolder is GA, not preview |
| N+1 / performance gotchas | ✅ Accurate | Well-documented with bad/good examples |
| Testing patterns | ✅ Accurate | jest-mock-extended, transaction isolation, factories |
| Docker deployment | ✅ Accurate | Binary targets, OpenSSL, entrypoint patterns correct |
| Raw queries | ✅ Accurate | Tagged template + $executeRaw + $queryRawUnsafe |

## Trigger Check

- **Specificity:** Excellent. Mentions schema.prisma, Prisma Client, prisma migrate, Prisma Accelerate, Prisma extensions — all unique to Prisma.
- **False positive risk for TypeORM:** None — explicitly excluded.
- **False positive risk for Sequelize:** None — explicitly excluded.
- **False positive risk for Drizzle:** None — explicitly excluded.
- **False positive risk for general TS/Node:** None — explicitly excluded.

## Supporting Files Quality

- **references/advanced-patterns.md:** Excellent. Covers client extensions (all 4 types), multi-tenancy (RLS + schema-per-tenant), soft deletes, audit logging, GraphQL integration, optimistic concurrency.
- **references/troubleshooting.md:** Excellent. Comprehensive error code guide, Docker/CI/CD patterns, binary targets, connection debugging.
- **references/performance-guide.md:** Excellent. Query logging, N+1 detection, batch operations, connection pool tuning, Accelerate caching, index recommendations.
- **scripts/init-project.sh:** Well-structured. Handles multiple DB providers, creates proper project scaffold.
- **scripts/generate-crud.sh:** Useful. Generates paginated CRUD service with proper Prisma types.
- **scripts/migration-helper.sh:** Good interactive + CLI migration workflow wrapper.
- **assets/**: All 5 files are production-quality templates (schema, service, seed, docker-compose, jest setup).

## Verdict

High-quality skill with minor currency issues. The `prismaSchemaFolder` preview flag is outdated and a few standard API methods are missing from the main body (though covered in references). No showstoppers. Passes QA.
