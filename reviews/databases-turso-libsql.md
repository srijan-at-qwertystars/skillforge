# QA Review: databases/turso-libsql

**Reviewed**: 2025-07-18
**Skill path**: `~/skillforge/databases/turso-libsql/`
**Verdict**: `needs-fix`

---

## a. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter `name` | ✅ | `turso-libsql` |
| YAML frontmatter `description` | ✅ | Present and detailed |
| Positive triggers | ✅ | Package imports (`@libsql/client`, `libsql`, `go-libsql`, `libsql` crate), CLI commands, Turso mentions, embedded replicas, sqld, edge SQLite, database-per-tenant, vector search |
| Negative triggers | ✅ | Plain SQLite, D1, PlanetScale, Supabase, PostgreSQL, MySQL, MongoDB |
| Body under 500 lines | ✅ | 424 lines |
| Imperative voice, no filler | ✅ | Clean, direct prose throughout |
| Examples with input/output | ✅ | Excellent — every SDK section has runnable code with inline output comments |
| `references/` linked | ✅ | 3 files linked with descriptions |
| `scripts/` linked | ✅ | 3 files linked with usage instructions |
| `assets/` linked | ✅ | 4 templates linked with descriptions |

**Structure verdict**: Pass — well-organized, clean, comprehensive.

---

## b. Content Check (Web-Verified)

### ✅ Turso CLI commands — Accurate
All documented commands verified against official Turso CLI docs:
- `turso db create`, `turso db shell`, `turso db list`, `turso db show`, `turso db destroy`, `turso db inspect` — correct syntax and flags.
- `turso group create`, `turso group locations add/remove` — correct.
- `turso auth login`, `turso auth token`, `turso auth api-tokens mint` — correct.
- `turso db tokens create`, `turso group tokens create` — correct, including `--expiration` and `--read-only` flags.

### ✅ TypeScript @libsql/client SDK — Accurate
- `createClient()` API shape confirmed (url, authToken, syncUrl, syncInterval).
- `client.execute()` with positional args — correct.
- `client.batch()` with array of `{sql, args}` and mode — correct.
- `client.transaction("write")` with commit/rollback — correct.
- `client.sync()` for embedded replicas — correct.
- `@libsql/client/web` import for Workers/Edge — confirmed required.

**Minor note**: SDK docs recommend using `transaction.close()` in a `finally` block alongside commit/rollback. The skill's try/catch pattern works but omits `close()`.

### ⚠️ Python SDK — OUTDATED
**Issue**: The skill recommends `pip install libsql-experimental` and `import libsql_experimental as libsql`. As of 2025, **both `libsql-experimental` and `libsql-client` are deprecated**. The current recommended package is:
```bash
pip install libsql
```
```python
import libsql
```
This affects SKILL.md (lines 113-135), `assets/python-client.py`, and `references/sqlite-migration.md`.

Source: [Turso blog — New SDKs for Python and SQLAlchemy](https://turso.tech/blog/new-sdks-for-python-and-sqlalchemy)

### ✅ Embedded replica configuration — Accurate
- `url: "file:local.db"` + `syncUrl` + `authToken` + `syncInterval` pattern confirmed.
- `client.sync()` manual sync confirmed.
- Write-then-sync pattern for read-your-writes is correct.

### ✅ Vector search syntax — Accurate
- `F32_BLOB(N)` column type confirmed.
- `CREATE INDEX ... ON table(libsql_vector_idx(column))` confirmed.
- `vector_top_k('index_name', vector('...'), k)` with JOIN on rowid confirmed.
- `vector()` function for JSON-to-blob conversion confirmed.
- Cosine distance is the default/only supported metric — confirmed.

### ✅ Platform integrations — Accurate
- **Cloudflare Workers**: `@libsql/client/web` import requirement confirmed by Cloudflare docs.
- **Vercel**: Remote mode with env vars — standard pattern, correct.
- **Fly.io**: Embedded replicas with volumes — correct guidance.

### ⚠️ Pricing/limits — SIGNIFICANTLY OUTDATED
The pricing table in SKILL.md (lines 378-384) is materially wrong:

| Plan | Skill Says | Actual (2025) | Delta |
|------|-----------|---------------|-------|
| **Free** | 100 DBs, 5GB, 500M reads, 10M writes, $0 | 100 DBs, 5GB, 500M reads, 10M writes, $0 | ✅ Matches |
| **Scaler** | 500 DBs, 9GB, 2.5B reads, 25M writes, ~$25 | Unlimited DBs (2500 active), 24GB, 100B reads, 100M writes, ~$24.92 | ❌ Storage 2.7x, reads 40x, writes 4x wrong |
| **Pro** | 10K DBs, 50GB, 250B reads, 250M writes, ~$417 | Unlimited DBs (10K active), 50GB, 250B reads, 250M writes, ~$416.58 | ⚠️ Close but DB count model changed |

**Missing**: Developer plan ($4.99/mo) now exists between Free and Scaler.

The Scaler tier numbers are dangerously wrong — showing 40x fewer reads than actual could cause users to over-provision or avoid the platform.

### ✅ Gotchas section — Good coverage
9 pitfalls documented, all verified accurate. Could add:
- Interactive transactions have a 5-second timeout (mentioned in SDK docs, not in skill).
- `turso db create --from-file` for direct SQLite import (mentioned in migration section but not in gotchas).

---

## c. Trigger Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| Description pushy enough? | ✅ | Lists 5 specific positive trigger conditions with package names and use cases |
| False trigger on plain SQLite? | ✅ | Explicitly excluded: "DO NOT TRIGGER when: user works with plain SQLite without Turso/libSQL" |
| False trigger on competing DBs? | ✅ | Explicitly excludes D1, PlanetScale, Supabase, PostgreSQL, MySQL, MongoDB |
| Missing trigger scenarios? | ⚠️ | Could add: `sqlalchemy-libsql` (new SQLAlchemy adapter), `drizzle-orm/libsql`, `@prisma/adapter-libsql` as import triggers |

---

## d. Scores

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 3 | Core SDK/CLI content is accurate, but pricing table is materially wrong (Scaler 40x off on reads) and Python SDK package is deprecated |
| **Completeness** | 4 | Excellent breadth: 4 SDKs, CLI, vectors, multi-tenancy, migrations, 5 platform integrations, 3 reference docs, 3 scripts, 4 asset templates. Missing Developer plan tier and updated Python package |
| **Actionability** | 5 | Outstanding — every section has runnable code with output comments, copy-paste scripts, Docker setup, ORM configs. Templates cover all common use cases |
| **Trigger quality** | 5 | Precise positive triggers with package names; comprehensive negative triggers prevent false matches |

**Overall: 4.25 / 5**

---

## e. GitHub Issues

Overall ≥ 4.0 and no dimension ≤ 2 — no issues required per policy. However, two fixes are strongly recommended before the skill is considered production-ready:

1. **Update pricing table** — Scaler plan numbers are 40x wrong on reads; Developer plan missing entirely.
2. **Update Python SDK** — `libsql-experimental` is deprecated; replace with `libsql` package across SKILL.md, assets/python-client.py, and references/.

---

## f. Test Tag

`<!-- tested: needs-fix -->` appended to SKILL.md.

**Blocking fixes before pass**:
- [ ] Update pricing table to 2025 plans (Free, Developer, Scaler, Pro)
- [ ] Replace `libsql-experimental` → `libsql` in all files (SKILL.md, assets/python-client.py, references/sqlite-migration.md, references/troubleshooting.md)
- [ ] Add `transaction.close()` to TypeScript transaction examples (optional but recommended)
- [ ] Add `sqlalchemy-libsql`, `drizzle-orm/libsql`, `@prisma/adapter-libsql` to trigger description (optional)
