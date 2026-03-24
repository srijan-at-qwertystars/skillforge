# QA Review: database/sqlalchemy-patterns

**Reviewer:** Copilot CLI  
**Date:** 2025-07-17  
**Skill path:** `~/skillforge/database/sqlalchemy-patterns/`

---

## a. Structure Check

| Criterion | Pass? | Notes |
|-----------|-------|-------|
| YAML `name` field | ✅ | `sqlalchemy-patterns` |
| YAML `description` field | ✅ | Present, thorough |
| Positive triggers in description | ✅ | 25+ specific triggers: models, ORM queries, session management, relationships, Alembic, async, mapped_column, pooling, hybrid properties, events, bulk ops, N+1, etc. |
| Negative triggers in description | ✅ | Excludes Django ORM, Prisma, Drizzle, TypeORM, Sequelize, raw SQL without SA context, NoSQL, DB admin without ORM, SA < 1.4 |
| Body under 500 lines | ✅ | 432 lines |
| Imperative voice, no filler | ✅ | Dense, direct, no preamble or filler paragraphs |
| Examples with input/output | ✅ | Every section has code examples; inline comments show outputs (e.g., `# → ["python"]`, `# → [("admin", 12, 34.5)]`) |
| references/ linked from SKILL.md | ✅ | 3 files linked with descriptions: advanced-patterns.md, troubleshooting.md, api-reference.md |
| scripts/ linked from SKILL.md | ✅ | 2 files linked: init-sqlalchemy.sh, migration-ops.sh |
| assets/ linked from SKILL.md | ✅ | 3 templates linked: base-model.template.py, alembic-env.template.py, conftest.template.py |

---

## b. Content Check

### Accuracy Verification (web-searched)

| Item | Correct? | Notes |
|------|----------|-------|
| `DeclarativeBase` import from `sqlalchemy.orm` | ✅ | Verified |
| `Mapped`, `mapped_column` from `sqlalchemy.orm` | ✅ | Verified |
| `create_async_engine` from `sqlalchemy.ext.asyncio` | ✅ | Verified |
| `AsyncAttrs` / `awaitable_attrs` API | ✅ | Verified — correct class and attribute name (available since SA 2.0.13) |
| `async_sessionmaker` from `sqlalchemy.ext.asyncio` | ✅ | Verified |
| `session.run_sync()` on AsyncSession | ✅ | Verified — correct API |
| `alembic check` command | ✅ | Verified — exists since Alembic 1.9.0 |
| `alembic init -t async` syntax | ✅ | Verified |
| `selectinload`, `joinedload`, `raiseload` imports | ✅ | Correct from `sqlalchemy.orm` |
| `WriteOnlyMapped` relationship pattern | ✅ | Correct — new in SA 2.0 |
| `ConcreteBase` for concrete table inheritance | ✅ | Correct from `sqlalchemy.orm` |
| Query API migration table (1.x → 2.0) | ✅ | All 20+ mappings verified correct |
| `version_id_col` for optimistic locking | ✅ | Correct mapper arg |
| `pool_pre_ping`, `pool_recycle` engine params | ✅ | Correct |

### Minor Issues Found

1. **`datetime.utcnow()` deprecated** — Used in soft delete mixin (`soft_delete()` method in SKILL.md L253, base-model.template.py L141, advanced-patterns.md L673, L477). Python 3.12 deprecated `utcnow()` in favor of `datetime.now(datetime.UTC)`. Not an error yet, but a gotcha worth noting.

2. **SQL injection in multi-tenancy example** — `advanced-patterns.md` L787-792 uses f-string interpolation in `cursor.execute(f"SET search_path TO {schema}, public")` and `session.execute(text(f"SET search_path TO {tenant_schema}, public"))`. Schema name should be validated or use `quoted_name()`.

3. **Async Alembic env.py lambda pattern** — SKILL.md L300-302 uses `connection.run_sync(lambda conn: (context.configure(...), context.run_migrations()))`. While functional (tuple forces sequential evaluation), this is unconventional. The template file (`alembic-env.template.py`) does it correctly with a separate `do_run_migrations()` function.

4. **`init-sqlalchemy.sh` async env.py URL replacement** — Line 316 does `get_url().replace("+psycopg2", "+asyncpg")` which only works for PostgreSQL; would fail silently for SQLite/MySQL async setups.

### Missing Gotchas

- No mention of `datetime.utcnow()` deprecation (Python 3.12+)
- No mention of `psycopg3` (psycopg) as the modern PostgreSQL driver vs legacy psycopg2 (though the api-reference.md does list the psycopg3 URL format)
- No warning about the SQL injection risk in schema-based multi-tenancy

### Examples Correctness

All code examples are syntactically correct and use valid SQLAlchemy 2.0 APIs. The patterns follow established community best practices. The scripts (`init-sqlalchemy.sh`, `migration-ops.sh`) are well-structured with proper `set -euo pipefail`, argument parsing, and help text.

---

## c. Trigger Check

### Would it trigger for real SQLAlchemy queries?

| Query | Should trigger? | Would trigger? |
|-------|----------------|----------------|
| "How do I set up SQLAlchemy models?" | Yes | ✅ Yes — "writing SQLAlchemy models" |
| "Fix N+1 query in SQLAlchemy" | Yes | ✅ Yes — "troubleshooting N+1 queries" |
| "Alembic migration workflow" | Yes | ✅ Yes — "Alembic migrations" |
| "AsyncSession with FastAPI" | Yes | ✅ Yes — "async SQLAlchemy with AsyncSession" |
| "SQLAlchemy relationship one-to-many" | Yes | ✅ Yes — "relationship mapping (one-to-many, many-to-many)" |
| "Connection pooling SQLAlchemy" | Yes | ✅ Yes — "connection pooling" |
| "mapped_column vs Column" | Yes | ✅ Yes — "SQLAlchemy 2.0 style with Mapped/mapped_column" |
| "Write-only relationships SQLAlchemy" | Yes | ✅ Yes — "write-only relationships" |

### Would it falsely trigger?

| Query | Should trigger? | Would trigger? |
|-------|----------------|----------------|
| "Django model with ForeignKey" | No | ✅ No — "Django ORM" in negative triggers |
| "MongoDB aggregation pipeline" | No | ✅ No — "MongoDB or NoSQL" in negative triggers |
| "TypeORM entity relations" | No | ✅ No — "TypeORM" in negative triggers |
| "Raw SQL query optimization" | No | ✅ No — "raw SQL without SQLAlchemy context" |
| "PostgreSQL admin backup" | No | ✅ No — "database administration tasks without ORM context" |
| "Python database connection" | Maybe | ⚠️ Borderline — no generic "database" trigger, but "database engine configuration" could match loosely |

**Verdict:** Triggers are well-calibrated. The description is comprehensive enough to catch real use cases without being overly broad. The explicit negative triggers prevent false positives for competing ORMs.

---

## d. Scores

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 4 | All core APIs verified correct. Minor issues: deprecated `datetime.utcnow()`, SQL injection in multi-tenancy example, unconventional lambda in async Alembic env |
| **Completeness** | 5 | Exceptionally thorough — covers engine, sessions, mapping, relationships, queries, loading, hybrids, events, mixins, custom types, Alembic, testing, performance, bulk ops, streaming, type annotations, repository pattern. Reference docs add polymorphism, versioning, multi-tenancy, write-only. Scripts and templates are production-ready |
| **Actionability** | 5 | Every pattern has copy-paste code. `init-sqlalchemy.sh` bootstraps a full project. `migration-ops.sh` wraps all Alembic workflows. Templates are directly usable. Conftest provides N+1 detection, transaction rollback, and factory fixtures |
| **Trigger quality** | 4 | Broad positive coverage (25+ specific triggers). Good negative exclusions. Slight risk of false-negative for very generic "Python database" queries that don't mention SQLAlchemy by name |

**Overall: 4.5 / 5.0**

---

## e. GitHub Issues

No issues required — overall score (4.5) > 4.0 and no dimension ≤ 2.

---

## f. Test Status

**PASS** ✅

The skill is comprehensive, accurate, well-structured, and production-ready. Minor improvements recommended:
- Update `datetime.utcnow()` → `datetime.now(datetime.UTC)` across all files
- Add SQL injection warning to schema-based multi-tenancy example
- Normalize async Alembic env.py example in SKILL.md to use named function (matching template)
