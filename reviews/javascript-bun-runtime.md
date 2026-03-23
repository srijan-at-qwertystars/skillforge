# QA Review: javascript/bun-runtime

**Reviewer:** Copilot CLI QA  
**Date:** 2025-07-18  
**Skill path:** `~/skillforge/javascript/bun-runtime/`

---

## a. Structure Check

| Criterion | Status | Notes |
|---|---|---|
| YAML frontmatter has `name` and `description` | ✅ Pass | `name: bun-runtime`, description present |
| Positive triggers in description | ✅ Pass | Comprehensive keyword list (Bun.serve, Bun.file, bun:sqlite, etc.) |
| Negative triggers in description | ✅ Pass | Excludes Node.js-only, Deno, browser JS, npm/yarn/pnpm without Bun |
| Body under 500 lines | ✅ Pass | Exactly 500 lines (borderline — no room for additions without trimming) |
| Imperative voice, no filler | ✅ Pass | Direct, code-first, no fluff |
| Examples with input/output | ✅ Pass | Extensive code examples throughout; some include inline output comments |
| references/ linked from SKILL.md | ✅ Pass | 3 references linked: advanced-patterns.md, troubleshooting.md, migration-from-node.md |
| scripts/ linked from SKILL.md | ✅ Pass | 3 scripts linked: setup-project.sh, migrate-from-node.sh, benchmark.sh |
| assets/ linked from SKILL.md | ✅ Pass | 4 assets linked: bunfig.toml, server-template.ts, Dockerfile, docker-compose.yml |

---

## b. Content Check — Accuracy Verification

### Correct ✅

- **Bun.serve** syntax: Basic server, streaming, WebSocket, TLS — all match current docs.
- **Bun.file / Bun.write**: Lazy BunFile, `.text()`, `.json()`, `.bytes()`, `.exists()` — correct.
- **Bun.$**: Tagged template, `.text()`, `.lines()`, `.quiet()`, `.nothrow()`, `.env()`, `.cwd()` — correct.
- **bun:sqlite**: `Database`, `db.run()`, `db.query()`, `db.prepare()`, `.all()`, `.get()`, `.values()`, transactions — correct.
- **bun:ffi**: `dlopen`, `FFIType`, `ptr`, `JSCallback`, type list — correct.
- **CLI commands**: `bun install`, `bun add`, `bun build`, `bun test`, `bun run`, `bunx` — correct.
- **bunfig.toml format**: `[install]`, `[install.scopes]`, `[test]`, `[run]` sections — correct structure.
- **Bun.serve `routes`** (advanced-patterns.md): Radix tree routing with params/wildcards — matches Bun 1.2+ API.
- **Test runner**: Jest-compatible API, `mock`, `spyOn`, `mock.module` — correct.

### Inaccurate / Outdated ❌

1. **Lockfile information is outdated (HIGH):**
   - SKILL.md (line 41): "Bun uses a binary lockfile `bun.lockb`"
   - Since Bun 1.2 (Jan 2025), the default is `bun.lock` (text-based, human-readable).
   - `bun.lockb` is legacy. The advice to use `bun install --yarn` for a text lockfile is superseded.
   - Affects: SKILL.md §Lockfile, Dockerfile (`COPY bun.lockb`), migration guide, troubleshooting, scripts, CI examples.

2. **Native addon compatibility statement is misleading (MEDIUM):**
   - SKILL.md (line 466): "Not supported: native C++ addons (non-N-API)" implies N-API addons DO work.
   - Reality: N-API support is still not fully working in Bun as of mid-2025 (see [oven-sh/bun#19578](https://github.com/oven-sh/bun/issues/19578)).
   - troubleshooting.md (line 111) correctly states "Bun does not support Node.js N-API native addons" — contradicts SKILL.md.

### Missing Content ⚠️

3. **Bun.s3 / S3Client (HIGH):** Bun 1.2 introduced a built-in S3 client for object storage. Not mentioned anywhere. This is a major new API.

4. **bun:sql / built-in Postgres client (MEDIUM):** Bun 1.2 added a native PostgreSQL client. Not mentioned.

5. **Bun.password (LOW):** Built-in password hashing API. Mentioned in migration-from-node.md but absent from SKILL.md core APIs.

6. **req.cookies (LOW):** Bun 1.2+ has built-in cookie parsing on requests. Not mentioned.

---

## c. Trigger Check

| Test Query | Should Trigger? | Would Trigger? | Result |
|---|---|---|---|
| "Bun project setup" | Yes | Yes — matches "Bun" keyword | ✅ |
| "Bun HTTP server" | Yes | Yes — matches "Bun" and "Bun.serve" | ✅ |
| "migrate from Node to Bun" | Yes | Yes — matches "migrating from Node.js to Bun" | ✅ |
| "Node.js Express server" (no Bun) | No | No — excluded by negative trigger | ✅ |
| "Deno deploy" | No | No — excluded by "Deno exclusively" | ✅ |
| "npm install react" (no Bun) | No | No — excluded by "generic npm/yarn/pnpm without Bun context" | ✅ |
| "JavaScript async/await tutorial" | No | No — excluded by "browser-only JavaScript" | ✅ |

Trigger quality is excellent with no false-positive risk identified.

---

## d. Scores

| Dimension | Score | Rationale |
|---|---|---|
| **Accuracy** | 3 / 5 | Core APIs correct but lockfile info significantly outdated; N-API claim contradicts troubleshooting doc; missing Bun 1.2 APIs |
| **Completeness** | 3 / 5 | Missing Bun.s3, bun:sql, Bun.password, req.cookies, bun.lock. Existing coverage is thorough. |
| **Actionability** | 4 / 5 | Excellent code examples, practical scripts, Docker/CI templates. Would mislead on lockfile workflow. |
| **Trigger Quality** | 5 / 5 | Comprehensive positive triggers, clear negative exclusions, no false-positive risk |

**Overall: 3.75 / 5** — Needs fixes before passing.

---

## e. Issues Filed

Overall < 4.0 → GitHub issues required.

1. **Outdated lockfile information (bun.lockb → bun.lock)** — affects SKILL.md, Dockerfile, scripts, CI examples
2. **Contradictory N-API compatibility statement** — SKILL.md vs troubleshooting.md
3. **Missing Bun 1.2 APIs (Bun.s3, bun:sql)** — significant omissions for current Bun

---

## f. SKILL.md Annotation

`<!-- tested: needs-fix -->` appended as last line.

---

## Summary

The skill has excellent structure, trigger design, and code quality. The main issues are (1) outdated lockfile information from the pre-1.2 era, (2) a contradictory native addon compatibility claim, and (3) missing coverage of major Bun 1.2 features. Once these are addressed, this skill should score ≥ 4.0.
