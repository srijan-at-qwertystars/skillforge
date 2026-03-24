# Review: cypress-testing

Accuracy: 4/5
Completeness: 4/5
Actionability: 5/5
Trigger quality: 5/5
Overall: 4.5/5

Issues:

## a. Structure Check

| Criterion | Status | Notes |
|---|---|---|
| YAML `name` | ✅ | `cypress-testing` |
| YAML `description` | ✅ | Present with positive and negative triggers |
| Positive triggers | ✅ | Cypress E2E, component testing, cy.intercept, custom commands, cy.session, data-cy selectors, assertion chains, flake fixes, Cypress Cloud, GitHub Actions |
| Negative triggers | ✅ | Explicitly excludes Playwright, Selenium, Jest, Vitest, React Testing Library (non-Cypress), mobile/native, multi-browser outside Cypress Cloud |
| Body length | ✅ | 466 lines (under 500 limit) |
| Imperative voice | ✅ | Direct, no filler |
| Examples with I/O | ✅ | Abundant runnable code examples throughout |
| `references/` linked | ⚠️ | 3 of 4 linked: advanced-patterns.md, troubleshooting.md, ci-integration.md. **`component-testing-guide.md` (1988 lines) is NOT linked** |
| `scripts/` linked | ⚠️ | 2 of 5 linked: setup-cypress.sh, generate-command.sh. **3 unlinked: setup-cypress-project.sh, cypress-ci-setup.sh, cleanup-test-data.sh** |
| `assets/` linked | ⚠️ | 3 of 6 linked: cypress.config.ts, commands.ts, github-actions.yml. **3 unlinked: github-actions-cypress.yml, e2e-spec-template.cy.ts, component-spec-template.cy.tsx** |

## b. Content Check

### Verified Claims
- `cy.selectFile()` introduced in Cypress 9.3 ✅ (verified via web search)
- `cy.origin()` described as Cypress 12+ ✅ (experimental since 9.6, GA in 12 — verified)
- `Cypress.Commands.addQuery` attributed to Cypress 12+ ✅ (verified)
- `cy.session()` API shape and caching behavior ✅
- `cy.intercept` API signatures and patterns ✅
- GitHub Actions workflow syntax and action versions ✅

### Accuracy Issues
1. **`addQuery` example uses undocumented `cy.now()` API** (SKILL.md line 237, advanced-patterns.md line 51). The official Cypress docs use synchronous DOM querying in the inner function, not `cy.now()`. Works but may break in future Cypress versions.
2. **Inconsistent `cypress-io/github-action` versions**: SKILL.md and `assets/github-actions.yml` use `@v6`; `assets/github-actions-cypress.yml` and `scripts/cypress-ci-setup.sh` use `@v7` (latest). Not broken, but inconsistent.
3. **`waitForNetworkIdle` in `assets/commands.ts`** uses `cy.wait(500)` hard waits — contradicts the skill's own flake-prevention guidance.

### Missing Gotchas
1. `component-spec-template.cy.tsx` uses `cy.realPress('Tab')` which requires the `cypress-real-events` plugin — never mentioned as a dependency.
2. No mention of Cypress 13+ Test Replay feature for debugging.

### Examples Quality
- All code examples are syntactically correct and idiomatic ✅
- Login command correctly uses `cy.session()` with validation ✅
- Component testing examples are proper React + Cypress ✅
- CI/CD workflows are production-ready with caching, parallelization, and artifact upload ✅
- E2E and component spec templates demonstrate excellent test structure ✅

### AI Executability
An AI agent could set up Cypress from scratch, write E2E/component tests, configure CI, debug flaky tests, and scaffold custom commands using this skill alone. ✅

## c. Trigger Check

| Scenario | Expected | Would Trigger? | Status |
|---|---|---|---|
| "Write Cypress E2E tests for login" | Yes | ✅ matches Cypress E2E | ✅ |
| "Set up cy.intercept for API mocking" | Yes | ✅ matches cy.intercept | ✅ |
| "Fix flaky Cypress tests in CI" | Yes | ✅ matches flake fixes, CI | ✅ |
| "Add data-cy selectors" | Yes | ✅ matches data-cy selectors | ✅ |
| "Configure Cypress Cloud" | Yes | ✅ matches Cypress Cloud setup | ✅ |
| "Write Playwright tests" | No | ✅ explicitly excluded | ✅ |
| "Set up Selenium WebDriver" | No | ✅ explicitly excluded | ✅ |
| "Write Jest unit tests" | No | ✅ explicitly excluded | ✅ |
| "React Testing Library" | No | ✅ explicitly excluded (non-Cypress) | ✅ |
| "Mobile app testing" | No | ✅ explicitly excluded | ✅ |

No false-trigger risk. Appropriate specificity.

## d. Dimension Scores

| Dimension | Score | Rationale |
|---|---|---|
| **Accuracy** | 4/5 | All version claims verified correct. Deducted for `cy.now()` undocumented API usage, inconsistent action versions, and self-contradicting hard-wait pattern. |
| **Completeness** | 4/5 | Excellent breadth. Deducted for 9 orphaned files not linked from SKILL.md (including the 1988-line component testing guide), missing `cypress-real-events` dependency note. |
| **Actionability** | 5/5 | Every section has runnable code. Scripts bootstrap real projects. Templates are copy-paste ready. CI workflows are production-grade. |
| **Trigger quality** | 5/5 | Precise positive triggers covering all Cypress scenarios. Explicit negative triggers for every competing tool. No false-trigger risk. |

**Overall: 4.5/5**

## e. Recommendations (non-blocking)

1. Link all 9 orphaned files from SKILL.md (especially `component-testing-guide.md` and the spec templates) or remove duplicates.
2. Replace `cy.now()` in `addQuery` example with the official documented synchronous pattern.
3. Standardize `cypress-io/github-action` to `@v7` across all files.
4. Add `cypress-real-events` as a noted dependency for keyboard testing in component spec template.
5. Fix or annotate the `waitForNetworkIdle` hard-wait to acknowledge the intentional tradeoff.

## f. Verdict

**PASS** — High-quality, comprehensive skill. Accurate API references (verified via web search), excellent examples, strong trigger design. Issues are minor: orphaned files, one undocumented API usage, version inconsistencies. Well above quality bar.

---

*Reviewed by Copilot CLI — 2025-07-17*
