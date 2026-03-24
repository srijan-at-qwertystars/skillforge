# QA Review: deno-runtime

**Skill path**: `javascript/deno-runtime/SKILL.md`
**Reviewed**: 2026-03-24
**Reviewer**: Copilot QA

---

## A. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter | ✅ Pass | `name`, `description` with positive and negative triggers present |
| Line count | ✅ Pass | 489 lines (under 500 limit) |
| Imperative voice | ✅ Pass | Consistent imperative style throughout |
| Examples | ✅ Pass | 4 labeled end-to-end examples + numerous inline code blocks |
| References linked | ✅ Pass | 3 reference docs (advanced-patterns, troubleshooting, fresh-framework) — all substantive (922–1284 lines each) |
| Scripts linked | ✅ Pass | 3 scripts (project init, node migration, benchmark) — all well-documented with usage headers |
| Assets linked | ✅ Pass | 5 assets (deno.json template, Fresh route, Oak server, GH Actions CI, Dockerfile) |

**Structure verdict**: Excellent. Well-organized with clear section hierarchy.

---

## B. Content Check

### Verified Accurate ✅
- **Deno.serve** API — correct signature `Deno.serve({ port }, handler)` with Request/Response pattern
- **Permissions model** — CLI flags (--allow-read/write/net/env/run/ffi/sys) and deny flags are correct
- **Deno.openKv** — API, hierarchical keys, atomic transactions, KvU64 usage all correct
- **Deno.test** — subtests via `t.step()`, per-test permissions object, coverage commands correct
- **Deno.Command** — subprocess API with piped stdout/stderr is correct
- **Deno.dlopen (FFI)** — parameter types, nonblocking option correct
- **JSR / @std imports** — `jsr:` specifier syntax, `deno add` command correct
- **npm compatibility** — `npm:` specifier, import maps, package.json support all correct
- **deno compile** — cross-compilation targets, `--include` for assets correct
- **deno.json** — compiler options, imports, tasks, lint, fmt, exclude all valid
- **Fresh framework** — file-based routing, islands, middleware, FreshContext correct
- **Deno Deploy** — deployctl install and deploy syntax correct

### Missing or Outdated ⚠️

1. **Deno 2.5 permission sets in `deno.json`** (introduced Oct 2025) — The skill documents only CLI flag permissions. Deno 2.5 introduced `permissionSets` in config with the `-P`/`--permission-set` flag for reusable named permission profiles. This is a significant DX improvement that should be mentioned.

2. **`deno serve --parallel` thread count** — The skill shows `deno serve --parallel` but omits that thread count is controlled via the `DENO_JOBS` environment variable (not a `--parallel=N` argument). Passing `--parallel=4` would error.

3. **Fresh 2.x Vite integration** — Fresh 2.0 added optional Vite-powered build mode for HMR, which was Fresh 1.x's biggest gap. The main skill and the Fresh reference should mention this.

4. **`Deno.cron`** — Listed in the references TOC description but absent from the main skill. Since it's a built-in API available on Deno Deploy, a one-liner mention in the main skill would help discoverability.

### No Factual Errors Found
All code samples compile/run correctly against Deno 2.x semantics.

---

## C. Trigger Check

### Positive Triggers (will fire correctly)
- ✅ "Deno" keyword — direct match
- ✅ `jsr:`, `deno.land/std`, `@std/` imports — Deno-specific specifiers
- ✅ `deno.json` / `deno.jsonc` — unique to Deno
- ✅ `Deno.serve`, `Deno.test`, `Deno.openKv`, `Deno.dlopen`, `Deno.Command` — API-level triggers
- ✅ CLI commands: `deno deploy`, `deno compile`, `deno task`, `deno bench`
- ✅ "Fresh framework", "Fresh islands"
- ✅ Permission flags `--allow-read/write/net/env/ffi/run`

### Negative Triggers (correctly excluded)
- ✅ Node.js-only projects — explicitly excluded
- ✅ Bun runtime — explicitly excluded
- ✅ Browser-only JavaScript — excluded
- ✅ General TypeScript without Deno context — excluded
- ✅ npm/npx/yarn/pnpm commands — excluded unless alongside `npm:` specifier

### Edge Cases
- ⚠️ "JSR" alone could trigger even though JSR is also usable in Node/Bun — acceptable since JSR is Deno-native and the most common context is Deno
- ✅ Won't falsely trigger for Express.js/Next.js/Bun projects
- ✅ Smart `npm:` specifier exception is well-crafted

**Trigger verdict**: High precision with well-defined boundaries. No false-positive risk for Node/Bun/browser workflows.

---

## D. Scores

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 4 | All documented APIs are correct. Misses Deno 2.5 permission sets and `DENO_JOBS` detail for `--parallel`. |
| **Completeness** | 4 | Excellent breadth (KV, FFI, Fresh, Deploy, compile, testing, JSR). Gaps: permission sets in config, Fresh Vite mode, `Deno.cron` in main body. |
| **Actionability** | 5 | Outstanding. Copy-paste examples, 5 asset templates, 3 utility scripts, 3 deep-dive references. A developer can go from zero to deployed app. |
| **Trigger quality** | 5 | Very specific positive triggers with comprehensive negative exclusions. No realistic false-positive scenarios for adjacent runtimes. |

**Overall: 4.5 / 5.0** — PASS

---

## E. Recommendations

1. **Add Deno 2.5 permission sets** — Add a subsection under "Permissions Model" showing `permissionSets` in `deno.json` and `-P` flag usage.
2. **Fix `deno serve --parallel`** — Add note that thread count is set via `DENO_JOBS` env var, not a flag value.
3. **Mention Fresh 2.x Vite mode** — Add a note in the Fresh Framework section about optional Vite integration for HMR.
4. **Add `Deno.cron` snippet** — One small example in the main skill body for discoverability (already covered in references).

---

## F. Issue Filing

- Overall score 4.5 ≥ 4.0 — **no issue required**
- No dimension ≤ 2 — **no issue required**

---

## G. Verdict

**PASS** — Skill is production-ready with minor enhancement opportunities.
