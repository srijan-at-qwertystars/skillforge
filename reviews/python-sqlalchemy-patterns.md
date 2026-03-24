# QA Review: sqlalchemy-patterns

**Skill path:** `~/skillforge/python/sqlalchemy-patterns/`
**Reviewed:** 2025-07-15
**Reviewer:** Copilot CLI (automated)

---

## A. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter (name) | ✅ Pass | `name: sqlalchemy-patterns` |
| YAML frontmatter (description with +/- triggers) | ✅ Pass | USE/DO NOT USE/TRIGGERS all present |
| Body ≤ 500 lines | ✅ Pass | Exactly 500 lines (at limit) |
| Imperative voice | ✅ Pass | "Use", "Always set", "Fix with" throughout |
| Examples with input/output | ✅ Pass | Rich code blocks with comments showing expected behavior |
| References linked from SKILL.md | ✅ Pass | 3 reference files linked: advanced-patterns.md, troubleshooting.md, alembic-guide.md |
| Assets linked from SKILL.md | ✅ Pass | 5 asset files linked: base-model.py, repository-pattern.py, async-session.py, alembic-env.py, conftest.py |
| Scripts linked from SKILL.md | ❌ Fail | `### Scripts (scripts/)` heading exists at line 499 but **body is empty** — the 3 scripts (alembic-setup.sh, model-generator.sh, sqlalchemy-init.sh) are not listed or described |

## B. Content Check

### Verified Claims (Web-Searched)

| Claim | Status | Detail |
|-------|--------|--------|
| `DeclarativeBase` replaces `declarative_base()` | ✅ Correct | Confirmed in SQLAlchemy 2.0 docs |
| `mapped_column()` replaces `Column()` for ORM | ✅ Correct | Canonical 2.0 pattern |
| `Mapped[Optional[T]]` → nullable | ✅ Correct | Type inference from Optional |
| `select()` over `session.query()` | ✅ Correct | `Query` is legacy in 2.0 |
| `create_async_engine` / `AsyncSession` / `async_sessionmaker` | ✅ Correct | All APIs verified in `sqlalchemy.ext.asyncio` |
| `alembic init -t async alembic` | ✅ Correct | Generates async env.py template |
| `alembic revision --autogenerate` / `upgrade head` / `downgrade -1` | ✅ Correct | Standard Alembic commands |
| `case()` positional tuple syntax | ✅ Correct | `case((cond, val), else_=...)` is valid 2.0 syntax (list form is deprecated) |
| `hybrid_property` with `@expression` + `@classmethod` | ✅ Correct | Accepted in SQLAlchemy 2.0 |
| `selectinload` for *-to-many, `joinedload` for *-to-one | ✅ Correct | Recommended strategy |
| `pool_pre_ping=True` detects stale connections | ✅ Correct | |
| `bulk_save_objects` is deprecated | ⚠️ Imprecise | It is **legacy**, not formally deprecated. Functionally correct advice (use Core `insert()`) but wording overstates |

### Issues Found

1. **Missing `AsyncAttrs` mixin for `awaitable_attrs`** (Accuracy)
   - SKILL.md line 252: `posts = await user.awaitable_attrs.posts`
   - This requires `AsyncAttrs` mixin on the declarative base: `class Base(AsyncAttrs, DeclarativeBase): pass`
   - Neither SKILL.md nor assets mention this prerequisite. Users following the async example will get `AttributeError`.

2. **Scripts section empty** (Completeness)
   - Line 499–500: heading `### Scripts (scripts/)` with no content below.
   - Three scripts exist (`alembic-setup.sh`, `model-generator.sh`, `sqlalchemy-init.sh`) but are not listed.

3. **`datetime.utcnow()` deprecated** (Accuracy, in assets)
   - `assets/base-model.py` line 79: `target.deleted_at = datetime.utcnow()`
   - `datetime.utcnow()` is deprecated since Python 3.12. Should use `datetime.now(datetime.UTC)`.

4. **`autocommit=False` on `async_sessionmaker`** (Minor, in assets)
   - `assets/async-session.py` line 87: `autocommit=False` — this is the default and unnecessary, but not harmful.

### Missing Gotchas (not covered)

- No mention that `AsyncAttrs` mixin is needed for `awaitable_attrs` (critical for async users).
- No mention of `insertmanyvalues_page_size` engine option for enhanced bulk insert performance (mentioned in troubleshooting but not in main SKILL.md performance section).
- No mention of `with_for_update()` for row-level locking / SELECT FOR UPDATE patterns.

### Example Correctness

All code examples in SKILL.md are syntactically correct and follow SQLAlchemy 2.0 idioms. The model definitions, query patterns, eager loading strategies, transaction handling, and Alembic workflows are all accurate and production-appropriate.

The asset files (conftest.py, repository-pattern.py, async-session.py, base-model.py, alembic-env.py) are well-structured and production-ready, with the `datetime.utcnow()` exception noted above.

The shell scripts are functional, well-documented with usage headers, and follow best practices (`set -euo pipefail`, input validation, idempotency checks).

## C. Trigger Check

### Would it trigger for SQLAlchemy queries?
**Yes ✅** — Description includes "imports sqlalchemy", "ORM models with DeclarativeBase/mapped_column/Mapped", "builds SQL queries with select/insert/update/delete", "configures engines or sessions". TRIGGERS list includes "SQLAlchemy", "mapped_column", "DeclarativeBase", "Session.execute", "create_engine", "selectinload", "joinedload", "Alembic", "relationship()", "Mapped[", "AsyncSession".

### Would it falsely trigger for Django ORM?
**No ✅** — Explicit exclusion: "DO NOT USE for ... Django ORM". No Django-specific keywords in positive triggers.

### Would it falsely trigger for Peewee?
**No ✅** — Explicit exclusion: "DO NOT USE for ... Peewee". Trigger keywords are SQLAlchemy-specific.

### Would it falsely trigger for Tortoise ORM / Drizzle?
**No ✅** — Both explicitly excluded in DO NOT USE clause.

### Edge case: "raw SQL without SQLAlchemy"
**Correctly excluded ✅** — Prevents triggering for plain `psycopg2` or `sqlite3` usage.

## D. Scores

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 4 | Almost all claims verified correct. Deductions: missing `AsyncAttrs` prerequisite for `awaitable_attrs` (could cause real user errors), `bulk_save_objects` "deprecated" vs "legacy" imprecision, `datetime.utcnow()` in assets. |
| **Completeness** | 4 | Comprehensive coverage: ORM mapping, Core expressions, relationships, eager loading, async, transactions, Alembic, events, hybrid properties, custom types, performance, testing, pitfalls. 3 deep reference docs, 5 asset templates, 3 scripts. Deduction: scripts section empty in SKILL.md, missing `AsyncAttrs` docs, no `SELECT FOR UPDATE`. |
| **Actionability** | 5 | Excellent. Copy-paste ready code blocks. Decision guides (eager loading strategy). Shell scripts for scaffolding projects. Repository pattern template. Production env.py. Complete conftest.py with sync/async fixtures. |
| **Trigger quality** | 5 | Well-defined positive triggers with specific keywords. Clear negative triggers for 5 competing ORMs. No false-positive risk identified. |
| **Overall** | **4.5** | Average of (4 + 4 + 5 + 5) / 4 |

## E. GitHub Issues

**Not required.** Overall score (4.5) ≥ 4.0 and no dimension ≤ 2.

## F. Recommended Fixes

1. **Add `AsyncAttrs` mixin documentation** — In the Async Support section, update Base class or add note: `class Base(AsyncAttrs, DeclarativeBase): pass` is required for `awaitable_attrs`.
2. **Complete the scripts section** — Add descriptions for `alembic-setup.sh`, `model-generator.sh`, `sqlalchemy-init.sh` below the heading at line 499.
3. **Fix `datetime.utcnow()`** — Replace with `datetime.now(datetime.UTC)` in `assets/base-model.py`.
4. **Soften `bulk_save_objects` language** — Change "deprecated" to "legacy" in pitfall #8.

## Status

**`needs-fix`** — Two concrete technical issues: missing `AsyncAttrs` prerequisite (could cause user errors) and empty scripts section (structural incompleteness).
