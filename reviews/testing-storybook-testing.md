# Skill Review: `storybook-testing`

**Path:** `~/skillforge/testing/storybook-testing/`
**Reviewer:** Copilot CLI (automated)
**Date:** 2025-07-18

---

## A. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter — `name` | ✅ | `name: storybook-testing` |
| YAML frontmatter — `description` | ✅ | Thorough; includes positive and negative triggers |
| Positive triggers | ✅ | Stories, CSF3, play functions, addons, visual testing, controls/args, decorators, loaders, component libraries |
| Negative triggers | ✅ | Playwright/Cypress e2e, Jest/Vitest unit (no UI), REST/GraphQL API, CLI, backend |
| Body ≤ 500 lines | ✅ | 492 lines (`wc -l`) — just under the limit |
| Imperative voice | ✅ | Consistent throughout ("Initialize Storybook", "Use the correct one", "Add `tags`") |
| Code examples | ✅ | Extensive runnable examples for every section (CSF3, play functions, MSW, CI/CD, etc.) |
| References/scripts linked | ✅ | "Additional Resources" table at bottom links all 3 reference docs, 2 scripts, 3 templates with descriptions |

**Structure verdict:** All structural requirements met.

---

## B. Content Check — API Verification (Web-Searched)

### Verified Correct

| Item | Verdict |
|------|---------|
| `Meta`, `StoryObj` from `@storybook/react` | ✅ Correct |
| `satisfies Meta<typeof Component>` pattern | ✅ Recommended in SB8 |
| CSF3 format (stories as objects, not functions) | ✅ Correct |
| `@storybook/test` exports: `fn`, `expect`, `within`, `userEvent`, `waitFor`, `spyOn` | ✅ Correct |
| `composeStories` / `composeStory` from `@storybook/react` | ✅ Correct |
| `@storybook/addon-essentials` addon name | ✅ Correct |
| `@storybook/addon-a11y` addon name | ✅ Correct |
| `@chromatic-com/storybook` (new namespace) | ✅ Correct |
| `msw-storybook-addon` w/ `initialize` + `mswLoader` (not deprecated decorator) | ✅ Correct |
| MSW v2 handler format (`http.get`, `HttpResponse.json`) | ✅ Correct |
| `@storybook/test-runner` + Playwright-based | ✅ Correct |
| `argTypesRegex` removed in SB8 → use `fn()` | ✅ Correct |
| `@storybook/testing-library` + `@storybook/jest` → `@storybook/test` migration | ✅ Correct (in troubleshooting) |
| `storiesOf` API removed in SB8 | ✅ Correct |

### Minor Issues Found

1. **`@storybook/nextjs-vite` naming (troubleshooting.md line 371):** The current published package is `@storybook/experimental-nextjs-vite`. Calling it `@storybook/nextjs-vite` could confuse users looking for it on npm. Severity: Low.

2. **`@storybook/addon-interactions` in init script but not in SKILL.md main.ts example:** The init script (line 100) installs `@storybook/addon-interactions`, but the SKILL.md main.ts config doesn't list it. This addon provides the Interactions panel UI for debugging play functions — still valid in SB8 but its relationship to `@storybook/test` could be clarified. Severity: Low.

3. **`step` utility omitted from SKILL.md exports list:** The API reference mentions `step` as a play function utility, but SKILL.md line 197 lists only `fn, expect, within, userEvent, waitFor, spyOn, clearAllMocks`. The `step` function for grouping play function steps is useful and should be mentioned. Severity: Low.

4. **`beforeAll` hook not covered in SKILL.md body:** Only `beforeEach` is documented. The `beforeAll` hook (global one-time setup) is mentioned in the preview template but absent from the main skill body. Severity: Low.

### Missing Gotchas (Nice-to-Have)

- Node 18+ minimum requirement for SB8 (only in troubleshooting migration section)
- CSF Factories (experimental, OK to omit)
- `@storybook/addon-interactions` no longer bundles `@storybook/test` as of SB 8.2.0 — could trip up users upgrading mid-8.x

### Examples Correctness

All code examples verified correct: CSF3 story objects, play function patterns, MSW setup with `mswLoader`, decorator composition, CI workflow with `concurrently`/`wait-on`, framework-specific patterns (Next.js, Vue, Angular, Svelte).

---

## C. Trigger Check

### Description Analysis

The description is **well-crafted** with appropriate scope:

**Strengths:**
- Covers 10 positive trigger scenarios spanning the full Storybook workflow
- 5 explicit negative triggers prevent common false-positive categories
- Uses natural language that matches how developers describe Storybook tasks

**Potential False Triggers:**
- "visual testing" alone could match Playwright visual comparison (mitigated by negative trigger)
- "component documentation" could match non-Storybook doc tasks (low risk)

**Missing Trigger Keywords (suggestions):**
- "Chromatic" — users asking about Chromatic visual regression
- `.stories.tsx` / `.stories.ts` — users referencing story files by extension
- "MSW with Storybook" — common query pattern

**Overall trigger quality:** Good. Description is specific enough to avoid most false triggers while being broad enough to catch legitimate Storybook work.

---

## D. Scoring

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 4 | All major APIs verified correct. Minor issues: `@storybook/nextjs-vite` naming, `step` utility omission, `addon-interactions` inconsistency between script and SKILL.md |
| **Completeness** | 5 | Exceptionally thorough: setup → CSF3 → args → decorators → play functions → mocking (MSW + module) → a11y → docs/MDX → visual testing → CI/CD → framework-specific. 3 reference docs (867+880+542 lines), 2 scripts, 3 templates |
| **Actionability** | 5 | Every section has copy-paste-ready code. Init script automates full setup. CI template covers build → test → a11y → Chromatic → deploy. Visual test script handles build-serve-test flow |
| **Trigger Quality** | 4 | Good positive/negative coverage. Could add Chromatic, file extensions, MSW keywords. Minor false-trigger risk on "visual testing" |

### **Overall Score: 4.5 / 5.0**

---

## E. Issue Filing

- Overall ≥ 4.0: ✅ No blocking issues
- All dimensions > 2: ✅ No blocking issues
- **No GitHub issues required.**

---

## F. Test Result

**PASS** ✅

Minor suggestions for future improvement:
1. Add `@storybook/addon-interactions` to the main.ts example or document its relationship to `@storybook/test`
2. Note that `@storybook/nextjs-vite` is currently `@storybook/experimental-nextjs-vite` on npm
3. Add `step` to the `@storybook/test` exports list in SKILL.md
4. Add a brief `beforeAll` section alongside `beforeEach`
5. Consider adding "Chromatic" and ".stories.tsx" as trigger keywords
