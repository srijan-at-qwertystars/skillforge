# QA Review: vitest-patterns

**Skill path:** `~/skillforge/testing/vitest-patterns/`
**Review date:** 2025-07-17
**Reviewer:** Copilot QA

---

## (a) Structure

| Check | Status | Notes |
|-------|--------|-------|
| Frontmatter `name` | ✅ Pass | `vitest-patterns` |
| Frontmatter `description` | ✅ Pass | Multi-line, detailed |
| Positive triggers | ✅ Pass | Vitest, vitest.config.ts, vi.fn, vi.mock, vi.spyOn, vi.stubGlobal, vi.useFakeTimers, bench API, snapshot testing, component testing, in-source testing, @vitest/\*, vitest.workspace, Jest→Vitest migration |
| Negative triggers | ✅ Pass | Explicit exclusions: Jest-without-Vite, Playwright/Cypress e2e, pytest, JUnit |
| Body length | ✅ Pass | 394 lines (limit: 500) |
| Imperative voice | ✅ Pass | Uses "prefer", "install", "create", "use", "set", "run" throughout |
| Resources linked | ✅ Pass | 3 reference docs, 3 scripts, 4 asset files — all documented in tables at bottom |
| Reference files exist | ✅ Pass | `references/advanced-patterns.md`, `references/troubleshooting.md`, `references/migration-from-jest.md` |
| Scripts exist | ✅ Pass | `scripts/vitest-init.sh`, `scripts/vitest-coverage-check.sh`, `scripts/jest-to-vitest.sh` |
| Assets exist | ✅ Pass | `assets/vitest.config.ts`, `assets/vitest-workspace.ts`, `assets/setup-files.ts`, `assets/component-test-utils.tsx` |

**Structure verdict:** Excellent. All structural requirements met.

---

## (b) Content — Accuracy Verification

Claims verified via web search against official Vitest documentation and release notes:

| Claim | Verified | Notes |
|-------|----------|-------|
| "Vitest 4+ is the current stable line" | ✅ | Vitest 4.1.0 is latest stable (March 2026) |
| `aroundEach` and `aroundAll` hooks in Vitest 4+ | ✅ | Confirmed in Vitest 4.1 release notes |
| `defineWorkspace` imported from `vitest/config` | ✅ | Correct import path per official docs |
| Browser mode stable in Vitest 4+ | ✅ | Confirmed — major Vitest 4.0 feature |
| `@vitest/browser-playwright` package & `playwright()` provider | ✅ | Correct API and config syntax |
| `@vitest/browser-react` render API | ✅ | Package exists (vitest-community); import path may be `vitest-browser-react` in practice |
| `@vitest/browser-vue`, `@vitest/browser-svelte` | ⚠️ Minor | Vue package not fully public yet; Svelte package may use `vitest-browser-svelte` name |
| `vi.mock` hoisting behavior | ✅ | Correct — hoisted to file top |
| `vi.hoisted()` API | ✅ | Confirmed in troubleshooting reference (not in main body — see below) |
| `vi.importActual` is async | ✅ | Correct — unlike Jest's synchronous `requireActual` |
| `vi.importMock` exists | ✅ | Confirmed in Vitest API docs |
| `vi.stubGlobal`, `vi.stubEnv` | ✅ | Both confirmed |
| `vitest-codemod` package | ✅ | Exists at `trivikr/vitest-codemod` on GitHub |
| `importOriginal` parameter in `vi.mock` factory | ✅ | Modern recommended pattern (shown in troubleshooting, not main body) |
| Coverage providers: `@vitest/coverage-v8`, `@vitest/coverage-istanbul` | ✅ | Correct package names |
| Pool options: `threads`, `forks`, `vmThreads` | ✅ | Correct |
| `sequence.shuffle` config option | ✅ | Correct |
| `expectTypeOf` API | ✅ | Correct signatures shown |
| `--shard` flag syntax | ✅ | Correct |
| `github-actions` reporter | ✅ | Correct |

### Missing Gotchas / Content Gaps

1. **`vi.hoisted()` absent from main body** — Only appears in `references/troubleshooting.md`. This is the recommended way to reference variables inside `vi.mock()` factories and should be in the Mocking section of SKILL.md.

2. **`importOriginal` parameter not shown in main body** — The main SKILL.md (line 120–124) uses the older `vi.importActual` pattern inside `vi.mock`. The modern recommended pattern is the `importOriginal` callback parameter, which is shown in the troubleshooting and migration references but not the main body.

3. **`globalSetup` not mentioned in main body** — Only appears in troubleshooting reference. This is an important config option for expensive one-time setup (DB seeding, server start).

4. **No mention of test fixtures** — Vitest 4+ supports dependency-injection-style test fixtures (similar to Playwright). This is a significant feature omission.

5. **Component testing package names may be inaccurate** — `@vitest/browser-vue` and `@vitest/browser-svelte` listed in SKILL.md but the actual npm packages may use un-scoped names (`vitest-browser-vue`, `vitest-browser-svelte`).

---

## (c) Trigger Quality

**Strengths:**
- Comprehensive positive triggers covering all major Vitest surface area
- Specific enough to avoid false positives (e.g., `vitest.workspace`, `@vitest/*` packages)
- Good negative triggers excluding related-but-different tools (Jest-only, Playwright e2e, Cypress, pytest, JUnit)

**Weaknesses:**
- "describe/it/expect blocks" is overly generic — these are used by Mocha, Jasmine, Bun test, etc. This is mitigated by appearing alongside Vitest-specific terms, but could cause false triggers in ambiguous contexts.

**Overall:** Triggers are well-crafted with good signal-to-noise ratio.

---

## (d) Scores

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 4 | All major API claims verified correct. Minor issues: component testing package names may differ from actual npm names; main body uses older `vi.importActual` pattern instead of newer `importOriginal` callback. |
| **Completeness** | 4 | Exceptionally broad coverage of Vitest features. Missing: `vi.hoisted()` in main body, `globalSetup` config, test fixtures feature, `importOriginal` callback pattern. References cover some gaps. |
| **Actionability** | 5 | Excellent copy-paste code examples throughout. Production-ready asset configs, shell scripts for init/migration/coverage, step-by-step migration guide, anti-patterns section. |
| **Trigger quality** | 4 | Well-defined positive/negative triggers. Minor over-breadth on "describe/it/expect blocks" generic trigger. |
| **Overall** | **4.25** | Strong skill with high practical value. |

---

## Recommendations

### High Priority
1. Add `vi.hoisted()` to the Mocking section of SKILL.md — this is a critical pattern for safe `vi.mock` usage.
2. Show the `importOriginal` callback parameter pattern in the main body's `vi.importActual` example (line 120–124).

### Medium Priority
3. Add a brief `globalSetup` subsection under Configuration.
4. Verify and correct component testing package names (`@vitest/browser-vue` vs `vitest-browser-vue`).
5. Add a Test Fixtures section (Vitest 4+ feature for DI-style test context).

### Low Priority
6. Narrow the "describe/it/expect blocks" trigger — consider removing or qualifying it.
7. Add a note about `vi.mock` limitations in `describe.concurrent` contexts.

---

## Verdict

**Status: PASS** — Overall score 4.25, no dimension ≤ 2. No GitHub issue required.

The skill is comprehensive, accurate, and highly actionable. The identified gaps are minor and largely covered by the reference documents. The main body would benefit from surfacing `vi.hoisted()` and the `importOriginal` pattern, which are modern best practices.
