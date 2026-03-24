# Review: playwright-testing

Accuracy: 4/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 4/5
Overall: 4.5/5

Issues:

1. **Codegen `--output` flag undocumented**: Line 441 uses `npx playwright codegen --output=tests/generated.spec.ts`. The `--output` / `-o` flag is not listed on the official Playwright codegen docs page (https://playwright.dev/docs/codegen). It may exist as an undocumented CLI option, but the skill should verify or remove to avoid misleading an AI agent.
2. **`>> nth=0` selector shown without preferred alternative**: Line 152 shows `page.locator('.card >> nth=0')` as a CSS/XPath last-resort example. While valid, the preferred API is `page.locator('.card').first()` or `.nth(0)`. Could mislead an AI into using chained-engine syntax.
3. **Missing `json:` shorthand for `route.fulfill`**: Network mocking section uses `body: JSON.stringify(...)` but doesn't mention `route.fulfill({ json: myObj })`, which auto-sets contentType and stringifies.
4. **No Puppeteer exclusion in negative triggers**: Description excludes Selenium and Cypress but not Puppeteer-specific API questions (e.g., `page.$()` patterns).
5. **Minor: `test.step()` not covered in main doc**: Only in references. Brief mention in main doc would help AI agents produce better-organized tests.

## Structure Check

- ✅ YAML frontmatter has `name` and `description`
- ✅ Description has positive AND negative triggers
- ✅ Body is 492 lines (under 500 limit)
- ✅ Imperative voice throughout, no filler
- ✅ Examples with input/output in every section — code blocks are complete and runnable
- ✅ References (3 files), scripts (5 shell scripts), and assets (7 templates) all properly linked from SKILL.md

## Content Verification

- ✅ `devices['Pixel 7']` / `devices['iPhone 14']` — confirmed valid (added Playwright 1.39+)
- ✅ `workers: '50%'` — confirmed valid percentage string
- ✅ `route.fulfill({ response, body })` — confirmed valid override behavior
- ✅ `.card >> nth=0` — valid but not preferred (see issue #2)
- ⚠️ `--output` codegen flag — not found in official docs (see issue #1)
- ✅ Auth storageState pattern — correct
- ✅ CI/CD GitHub Actions workflow — correct (uses actions/checkout@v4, actions/setup-node@v4)
- ✅ Anti-patterns — all accurate and well-chosen
- ✅ Locator priority order matches official Playwright recommendations
- ✅ Config options (fullyParallel, webServer, retries, projects) — all correct

## Trigger Check

- ✅ Positive triggers cover: setup, e2e tests, cross-browser, automation, POM, visual regression, fixtures, auth, network mocking, mobile emulation, CI/CD, debugging, codegen, multi-tab, parallel execution, selectors
- ✅ Negative triggers exclude: unit tests, API-only testing, Selenium, Cypress, perf/load testing, accessibility-only audits
- ✅ Would trigger for real queries: "write Playwright tests", "set up e2e testing", "browser automation"
- ✅ Low false-positive risk due to explicit exclusions
- Minor gap: Puppeteer not excluded; "playwright config" could be added as trigger keyword

## Verdict

**PASS** — High-quality skill. Comprehensive, accurate, and immediately actionable. All code examples follow best practices and an AI could execute from this alone. Minor issues are non-blocking (undocumented flag, style preferences, missing sugar API).
