# Skill Review: `databases/sqlite-patterns`

**Reviewer:** QA automated review
**Date:** 2025-07-17
**Skill path:** `~/skillforge/databases/sqlite-patterns/`

---

## (a) Structure

| Check | Status | Notes |
|-------|--------|-------|
| Frontmatter `name` | ✅ | `sqlite-patterns` |
| Frontmatter `description` | ✅ | Comprehensive, includes feature list |
| Positive triggers | ✅ | sqlite3, better-sqlite3, rusqlite, go-sqlite3, SQLAlchemy+SQLite, embedded database, WAL mode, PRAGMA, FTS5, SQLite JSON, SQLite performance |
| Negative triggers | ✅ | PostgreSQL-only (LISTEN/NOTIFY, logical replication), MySQL/MariaDB, MongoDB, Redis, general SQL unrelated to SQLite |
| Body under 500 lines | ✅ | 500 total lines; body is ~486 lines (frontmatter is 14 lines) |
| Imperative voice | ✅ | "Use SQLite for…", "Apply these at every connection open…", "Use FTS5 for text search…", "Always set busy_timeout…" |
| Examples | ✅ | Extensive: SQL, Python, Node.js, Go, Rust code blocks throughout |
| Resources linked | ✅ | 3 reference docs, 3 scripts, 4 assets — all linked in tables at bottom of SKILL.md |

**Structure score: Excellent.** All structural requirements met. Resources are well-organized in dedicated subdirectories.

---

## (b) Content Accuracy

Claims verified via web search against official SQLite documentation and authoritative sources:

| Claim | Verdict | Detail |
|-------|---------|--------|
| Built-in JSON since 3.38 | ✅ Correct | JSON functions became built-in (no compile flag) in 3.38.0 (Feb 2022) |
| JSONB since 3.45, stored as BLOB | ✅ Correct | JSONB introduced in 3.45.0 (Jan 2024) |
| JSONB "~3x faster parsing, ~10% smaller" | ⚠️ Slightly optimistic | Sources say 2x–3x faster, 5–10% smaller. The 3x is the upper bound. |
| STRICT types: INTEGER, REAL, TEXT, BLOB, ANY | ✅ Correct | Also accepts `INT` as alias. Introduced in 3.37.0 |
| WAL2 experimental, not production-ready | ✅ Correct | Separate dev branch, not in mainline releases |
| ALTER TABLE DROP COLUMN (3.35+) | ✅ Correct | Introduced in 3.35.0 (Mar 2021) |
| RETURNING clause (3.35+) | ✅ Correct | Same release as DROP COLUMN |
| VACUUM INTO (3.27+) | ✅ Correct | Introduced in 3.27.0 (Feb 2019) |
| UPSERT (3.24) | ✅ Correct | Introduced in 3.24.0 |
| Lock states: UNLOCKED→SHARED→RESERVED→PENDING→EXCLUSIVE | ✅ Correct | Standard SQLite locking model |
| `cache_size` negative = KiB | ✅ Correct | -64000 ≈ 62.5 MB (labeled ~64 MB, acceptable approximation) |
| WAL doesn't work over NFS/SMB | ✅ Correct | Official recommendation |
| Shared cache deprecated in 3.41.0 | ✅ Correct | Noted in advanced-patterns.md |
| FTS5 syntax (MATCH, bm25, highlight, sync triggers) | ✅ Correct | All examples verified |
| `timediff()` since 3.43+ | ✅ Correct | Noted in advanced-patterns.md |
| `PRAGMA optimize` since 3.18+ | ✅ Correct | Noted in troubleshooting.md |

### Missing gotchas (minor, not critical)

- No mention of `SQLITE_MAX_VARIABLE_NUMBER` (default 999 in older builds, 32766 in newer) for large parameterized IN clauses.
- No mention of the 2000 column limit per table.
- Maximum database size (281 TB) mentioned only in troubleshooting.md, not in SKILL.md.
- The Python `busy_handler` example in troubleshooting.md uses `set_progress_handler` instead of noting that Python's `sqlite3` module doesn't expose `set_busy_handler` — the comment does acknowledge this, which is fine.

### Examples correctness

All SQL examples are syntactically valid. Language binding examples (Python, Node.js, Go, Rust) use correct APIs and idiomatic patterns. The connection pool asset (`connection-pool.py`) is well-structured and thread-safe. Shell scripts have proper `set -euo pipefail`, argument validation, and error handling.

---

## (c) Trigger Quality

| Test query | Should trigger? | Would trigger? | Result |
|------------|----------------|----------------|--------|
| "optimize SQLite database" | Yes | Yes — matches "SQLite performance", "PRAGMA tuning" | ✅ |
| "WAL mode configuration" | Yes | Yes — explicit positive trigger | ✅ |
| "better-sqlite3 connection setup" | Yes | Yes — explicit positive trigger | ✅ |
| "rusqlite transaction example" | Yes | Yes — explicit positive trigger | ✅ |
| "embedded database for CLI tool" | Yes | Yes — matches "embedded database" | ✅ |
| "PostgreSQL tuning" | No | No — excluded by "PostgreSQL-only features" negative trigger | ✅ |
| "MySQL performance optimization" | No | No — excluded by "MySQL/MariaDB" negative trigger | ✅ |
| "Redis caching patterns" | No | No — excluded by "Redis" negative trigger | ✅ |
| "SQL JOIN tutorial" | No | No — excluded by "general SQL unrelated to SQLite" | ✅ |
| "SQLite vs PostgreSQL" | Yes | Yes — explicit positive trigger | ✅ |

**Trigger assessment:** Well-scoped with specific library/tool names as positive triggers and clear exclusions. The description could be slightly tighter around "general SQL" edge cases, but the negative trigger handles this adequately.

---

## (d) Scoring

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 5 | All key technical claims verified correct. JSONB performance claim uses the upper bound but is within documented range. |
| **Completeness** | 5 | Covers all major SQLite topics: WAL, PRAGMAs, STRICT, JSON/JSONB, FTS5, window functions, CTEs, generated columns, concurrency, connection pooling, backup, extensions, 4 language bindings, migrations, PostgreSQL comparison, performance tuning, anti-patterns. Three deep reference docs, three utility scripts, four reusable assets. |
| **Actionability** | 5 | Production PRAGMA settings are copy-paste ready. Code examples in 4 languages with complete connection setup. Scripts are executable with proper argument handling, help text, and error messages. Migration template is reusable. Connection pool asset is production-quality. |
| **Trigger quality** | 4 | Effective positive/negative triggers with specific library names. Minor: could add `libsql`, `Turso`, `Litestream` as positive triggers for completeness. |
| **Overall** | **4.75** | Average of (5 + 5 + 5 + 4) / 4 |

---

## Verdict: ✅ PASS

Overall score 4.75 ≥ 4.0, and no dimension ≤ 2. No GitHub issues required.

### Recommendations (non-blocking)

1. **JSONB performance claim:** Consider softening "~3x faster" to "2–3x faster" to match the range reported in benchmarks.
2. **Trigger enhancement:** Add `libsql`, `Turso`, and `Litestream` as positive triggers since they are SQLite-ecosystem tools users may ask about.
3. **Missing limits:** Consider adding a brief note about `SQLITE_MAX_VARIABLE_NUMBER` in the anti-patterns table (common gotcha with large IN-clause parameter lists).
4. **cache_size rounding:** The comment says "64MB" but -64000 KiB = 62.5 MB. Consider using -65536 for an exact 64 MB or adjusting the comment.
