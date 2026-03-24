# QA Review: testing/vitest-testing

**Reviewer:** Copilot CLI  
**Date:** 2025-07-17  
**Skill Path:** `~/skillforge/testing/vitest-testing/`

---

## a. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter has `name` | ✅ Pass | `name: vitest-testing` |
| YAML frontmatter has `description` | ✅ Pass | Multi-line description present |
| Positive triggers in description | ✅ Pass | 12 specific USE-WHEN triggers listed |
| Negative triggers in description | ✅ Pass | 5 DO-NOT-USE-WHEN triggers (Jest, Playwright/Cypress e2e, non-JS, Mocha/Jasmine/Karma, general Vite build) |
| Body under 500 lines | ✅ Pass | 441 lines |
| Imperative voice, no filler | ✅ Pass | Direct, action-oriented prose throughout. No "in this guide" or "let's explore" filler. |
| Examples with input/output | ✅ Pass | Extensive code examples with comments showing expected values (e.g., `fn() // 'first'`, `impl(5) // 10`) |
| references/ linked from SKILL.md | ✅ Pass | All 3 files linked with descriptions (lines 25-27) |
| scripts/ linked from SKILL.md | ✅ Pass | Both scripts linked with descriptions (lines 30-31) |
| assets/ linked from SKILL.md | ✅ Pass | All 3 templates linked with descriptions (lines 34-36) |

**Structure Score: Excellent.** Clean layout, well-organized sections with quick-reference table at the end.

---

## b. Content Check

### Accuracy Verification (web-search validated)

| Claim | Status | Notes |
|-------|--------|-------|
| Requires Vite ≥6.0.0, Node.js ≥20.0.0 | ✅ Correct | Verified against official Vitest v3 docs |
| `defineConfig` from `vitest/config` | ✅ Correct | |
| `vi.mock()` hoisted to top | ✅ Correct | |
| `vi.hoisted()` for sharing state | ✅ Correct | |
| `vi.mock(path, { spy: true })` | ✅ Correct | Verified — keeps real impl, wraps as spies |
| `importOriginal` param in factory | ✅ Correct | v3+ API |
| Browser mode `instances` array config | ✅ Correct | v3 API uses `browser.instances` (replacing deprecated `browser.name`) |
| Coverage: "Since v3.2.0 no accuracy difference" | ✅ Correct | AST-based remapping in v3.2.0 brought V8/Istanbul to parity |
| `defineWorkspace` / `defineProject` | ✅ Correct | |
| Type test files use `.test-d.ts` | ✅ Correct | |
| `@testing-library/jest-dom/vitest` import | ✅ Correct | v6+ of jest-dom provides vitest entry |
| `vitest bench --compare` | ✅ Correct | |

### Minor Issues Found

1. **`MockInstance` type signature in `test-utils.template.ts` (line 214-215):**
   ```ts
   export type MockOf<T extends (...args: any) => any> = MockInstance<
     Parameters<T>, ReturnType<T>
   >
   ```
   In Vitest v3, `MockInstance` takes a single function type generic `MockInstance<T>` where T is the function type — NOT two separate `Parameters`/`ReturnType` generics. The old two-generic form was deprecated. Should be:
   ```ts
   export type MockOf<T extends (...args: any) => any> = MockInstance<T>
   ```
   **Severity: Medium** — would cause a TypeScript error with Vitest v3+.

2. **Missing blank line between Templates section and Installation section (line 37):** The `## Installation` header immediately follows the last template link with no blank line separator. Minor formatting.

### Missing Gotchas (Minor Gaps)

- **No mention of `vi.mock()` path resolution gotcha**: The mock path must match the import path exactly (relative vs alias). This is briefly in troubleshooting but not in the main SKILL.md mocking section.
- **No mention of `--pool` flag deprecation path**: v3 changed some pool option names (e.g., `poolOptions.threads` vs `poolOptions.forks`), but the doc handles this correctly.
- **`browser.name` deprecation not called out**: The browser mode section uses `instances` correctly (v3 API) but doesn't note that `browser.name` is deprecated, which could confuse users migrating from v2.

### Examples Correctness

All code examples in SKILL.md are syntactically correct and follow current Vitest v3 API patterns. The `test.each`, mocking, snapshot, and lifecycle examples would all run correctly.

### Reference Files Quality

- **advanced-patterns.md** (777 lines): Excellent depth on module factories, vi.hoisted, class mocking, fixtures, workspace, browser mode, type testing, benchmarking. All verified accurate.
- **api-reference.md** (743 lines): Comprehensive API tables covering test/describe variants, vi methods, expect matchers, config options. Well-structured.
- **troubleshooting.md** (700 lines): Covers 14 categories of common issues. Error message reference table is particularly useful. Verified fixes are accurate.

### Scripts Quality

- **setup-vitest.sh**: Well-written, detects PM/framework, generates config + setup files, handles existing files gracefully. Uses `set -euo pipefail`.
- **coverage-check.sh**: Parses JSON coverage summary, per-file breakdown, threshold checking. Clean error handling.

### Templates Quality

- **vitest.config.template.ts**: Production-ready with CI-aware settings, comprehensive coverage config, pool options, mock defaults. Well-commented.
- **test-utils.template.ts**: Useful utilities (mock factories, fetch stubs, timer helpers, console capture). The `MockOf` type issue noted above.
- **ci-workflow.template.yml**: Solid GitHub Actions workflow with matrix, caching, coverage upload, artifact storage.

---

## c. Trigger Check

### Would it trigger for real queries?

| Query | Should Trigger? | Would Trigger? |
|-------|----------------|----------------|
| "Set up Vitest in my React project" | ✅ Yes | ✅ Yes — "setting up Vitest" |
| "Mock an API module in Vitest" | ✅ Yes | ✅ Yes — "mocking modules" |
| "vitest.config.ts coverage setup" | ✅ Yes | ✅ Yes — "configuring vitest.config.ts" |
| "Why are my Vitest tests slow?" | ✅ Yes | ✅ Yes — "debugging test failures", "optimizing slow test suites" |
| "How to write unit tests" (generic) | ⚠️ Maybe | ⚠️ Possibly — no explicit "generic testing" trigger, but description is broad enough |
| "Set up Jest for my project" | ❌ No | ❌ No — "Jest-specific questions without Vitest context" excluded |
| "Configure Playwright e2e tests" | ❌ No | ❌ No — "configuring Playwright for e2e testing" excluded |
| "Vite build optimization" | ❌ No | ❌ No — "general Vite build questions unrelated to testing" excluded |
| "Write Mocha tests" | ❌ No | ❌ No — "configuring Mocha/Jasmine/Karma" excluded |

### Trigger Quality Assessment

The description is appropriately aggressive — it casts a wide net for anything Vitest-related while cleanly excluding adjacent tools. The 12 positive triggers cover the full breadth of Vitest features. The 5 negative triggers prevent false positives for the most likely confusion points (Jest, e2e tools, other test frameworks, generic Vite).

**One gap:** No explicit trigger for "migrate from Jest to Vitest" — a common query. The skill content covers this implicitly but the description doesn't call it out as a trigger.

---

## d. Scores

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 4 | All API names, config options, CLI commands verified correct. One `MockInstance` type signature error in template. |
| **Completeness** | 5 | Covers installation → config → testing → mocking → coverage → workspace → browser mode → type testing → benchmarking → CI → troubleshooting. 3 reference docs, 2 scripts, 3 templates. Extremely thorough. |
| **Actionability** | 5 | Every section has runnable code. Scripts automate setup. Templates are copy-paste ready. Troubleshooting has specific error → fix mappings. |
| **Trigger Quality** | 4 | Strong positive and negative triggers. Minor gap: no "Jest migration" trigger. Could add "writing unit tests in TypeScript" as positive trigger. |

### Overall Score: **4.5 / 5.0**

---

## e. Issues

No GitHub issues required — overall score (4.5) is above 4.0 and no dimension is ≤ 2.

**Recommended improvements (non-blocking):**
1. Fix `MockOf` type in `test-utils.template.ts` to use single-generic `MockInstance<T>` for Vitest v3 compatibility.
2. Add "migrating from Jest to Vitest" as a positive trigger.
3. Add blank line before `## Installation` heading.
4. Note `browser.name` deprecation in browser mode section.

---

## f. Verdict

**PASS** — High-quality, comprehensive, accurate skill. The `MockInstance` type issue is minor and isolated to one template file.

---

*Review path: `~/skillforge/reviews/testing-vitest-testing.md`*
