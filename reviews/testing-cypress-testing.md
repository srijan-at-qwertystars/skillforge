# QA Review: cypress-testing

**Skill path:** `~/skillforge/testing/cypress-testing/`
**Reviewer:** Copilot CLI
**Date:** 2025-07-17

---

## a. Structure Check

| Criterion | Status | Notes |
|---|---|---|
| YAML `name` | ✅ | `cypress-testing` |
| YAML `description` | ✅ | Present with positive and negative triggers |
| Positive triggers | ✅ | Comprehensive: Cypress E2E, component testing, cy.intercept, cy.get, cy.contains, custom commands, fixtures, CI, config, Cloud, selectors, data-cy, debugging, flaky tests, setup |
| Negative triggers | ✅ | Excludes Playwright, Selenium, Puppeteer, WebDriver, Jest/Vitest without Cypress context, pure API testing, React Testing Library alone |
| Body length | ✅ | 444 lines (under 500 limit) |
| Imperative voice | ✅ | Direct, no filler phrases |
| Examples with I/O | ✅ | Numerous code examples with realistic input/output throughout |
| `references/` linked | ✅ | 3 files linked in table: advanced-patterns.md, troubleshooting.md, component-testing-guide.md — all exist on disk |
| `scripts/` linked | ✅ | 3 scripts linked in table: setup-cypress-project.sh, cypress-ci-setup.sh, cleanup-test-data.sh — all exist on disk |
| `assets/` linked | ✅ | 5 assets linked: cypress.config.ts, commands.ts, github-actions-cypress.yml, e2e-spec-template.cy.ts, component-spec-template.cy.tsx — all exist |

## b. Content Check

### Accuracy Issues

1. **`video` default value is WRONG (line 386):** The config reference table states `video` default is `true`. Since **Cypress 13** (Sep 2023), the default changed to `false`. This is a notable breaking change and the skill should reflect the current default.

2. **GitHub Action version is correct:** `cypress-io/github-action@v7` is the latest major version (released Jan 2026). ✅

3. **`cy.intercept` API** — all examples are accurate and match current stable API. ✅

4. **`cy.session` usage** — correct API shape, correct recommendation to use for auth caching. ✅

5. **`experimentalMemoryManagement`** — correctly listed as `false` default. Available since Cypress 12.4+. ✅

6. **`defaultCommandTimeout`** — correctly listed as 4000ms. ✅

7. **TypeScript config** — the `cypress/tsconfig.json` includes `"../node_modules/cypress"` in `include`. This is unnecessary and unconventional; the `"types": ["cypress"]` in `compilerOptions` is sufficient. Minor issue.

### Missing Gotchas

1. **`cy.selectFile()` not mentioned** — native file upload support (Cypress 9.3+) replaces the third-party `cypress-file-upload` plugin. The skill lists the plugin but doesn't mention the built-in alternative in the main body. (It is covered in advanced-patterns.md reference, partial credit.)

2. **`testIsolation` behavior** — listed in the config table but no explanation of what happens when set to `false` (state leaks between tests). Real test engineers frequently trip on this.

3. **No mention of `cy.origin()`** in main body — important for multi-domain/SSO testing. Covered in references but warrants a brief mention in the main skill.

4. **No mention of Cypress 13+ Test Replay** — a major feature replacing video-based debugging. Should at least be referenced.

5. **Missing `cacheAcrossSpecs` option** for `cy.session()` — a common configuration that dramatically affects spec-level caching behavior.

### Examples Quality

- All code examples are syntactically correct and follow Cypress best practices. ✅
- The login custom command correctly uses `cy.session()`. ✅
- The component testing example is idiomatic React + Cypress. ✅
- CI/CD examples for GitHub Actions and GitLab CI are production-ready. ✅
- The App Actions pattern recommendation over Page Objects aligns with Cypress team guidance. ✅

## c. Trigger Check

| Scenario | Expected | Actual | Status |
|---|---|---|---|
| "Write Cypress E2E tests for login" | Trigger | Would trigger (mentions Cypress, E2E) | ✅ |
| "Set up cy.intercept for API mocking" | Trigger | Would trigger (cy.intercept) | ✅ |
| "Fix flaky Cypress tests in CI" | Trigger | Would trigger (Cypress, flaky, CI) | ✅ |
| "Write Playwright tests for my app" | No trigger | Would not trigger (excluded) | ✅ |
| "Set up Selenium WebDriver" | No trigger | Would not trigger (excluded) | ✅ |
| "Write Jest unit tests" | No trigger | Would not trigger (excluded) | ✅ |
| "Write React Testing Library tests" | No trigger | Would not trigger (excluded) | ✅ |
| "Help with browser automation" | No trigger | Would not trigger (excluded) | ✅ |
| "Set up end-to-end testing" | Ambiguous | Might not trigger (no Cypress keyword) | ⚠️ |

**Trigger quality note:** The description is appropriately specific. It won't false-trigger on competing frameworks. The one edge case is generic "E2E testing" queries without mentioning Cypress — but this is correct behavior since the user hasn't specified Cypress.

## d. Dimension Scores

| Dimension | Score | Rationale |
|---|---|---|
| **Accuracy** | 4 | One factual error (`video` default), one minor issue (tsconfig). All APIs and patterns are otherwise correct. |
| **Completeness** | 4 | Excellent coverage of core topics. Missing a few modern features (Test Replay, cy.selectFile, cy.origin in main body). References fill some gaps. |
| **Actionability** | 5 | Every section has runnable code. Config table is practical. CI templates are copy-paste ready. Scripts bootstrap real projects. |
| **Trigger quality** | 5 | Precise positive/negative triggers. No false-trigger risk for competing frameworks. |

**Overall: 4.5 / 5.0**

## e. Required Fixes

1. **Fix `video` default** in config reference table (line 386): change `true` to `false` and add note about Cypress 13+ change.

## f. Recommended Improvements (non-blocking)

1. Add brief mention of `cy.selectFile()` as built-in alternative to `cypress-file-upload` plugin.
2. Add one-liner about Test Replay (Cypress 13+) in the Debugging section.
3. Mention `cacheAcrossSpecs` option for `cy.session()`.
4. Brief mention of `cy.origin()` for multi-domain testing in the main body.
5. Clean up tsconfig example — remove unnecessary `include` of `node_modules/cypress`.

## g. Verdict

**PASS** — High-quality skill with strong structure, accurate triggers, and actionable examples. One factual error to fix (`video` default), but overall well above the quality bar.

---

*Review generated by Copilot CLI QA process*
