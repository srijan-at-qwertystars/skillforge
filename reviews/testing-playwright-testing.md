# Review: playwright-testing

Accuracy: 5/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 4/5
Overall: 4.8/5

Issues:

- **Minor — Docker image version pinned to v1.52.0-noble**: SKILL.md (line 357) and troubleshooting.md reference `v1.52.0-noble`. Latest Playwright is v1.58.2. This is used as an example rather than a factual claim, so not a real error, but it will drift over time.
- **Minor — `route.fulfill` uses older `body: JSON.stringify(...)` pattern in SKILL.md**: The newer `json` option (e.g., `route.fulfill({ json: [...] })`) is available and cleaner. The api-reference.md correctly shows the `json` option, but the main SKILL.md network interception section uses the older pattern.
- **Minor — Component testing still experimental**: Correctly identified as `@playwright/experimental-ct-react`, but no caveat that the API may break between releases and doesn't follow semver. A brief warning would help.
- **Trigger description could add a few more keywords**: "playwright config", "browser automation setup", "cross-browser e2e" would improve recall slightly. Current triggers are solid but could be marginally more aggressive.

## Structure Check

- ✅ YAML frontmatter has `name` and `description`
- ✅ Description has positive AND negative triggers (comprehensive exclusion list including Selenium, Cypress, Puppeteer, Appium/Detox, k6/Artillery)
- ✅ Body is 495 lines (under 500 limit)
- ✅ Imperative voice throughout ("Prefer accessible locators...", "Avoid hard waits...", "Use storageState to save...")
- ✅ Examples with input/output in every section — code blocks show complete, runnable snippets
- ✅ References (3 docs), scripts (3 shell scripts), and assets (4 templates) all properly linked and files exist

## Content Check

- ✅ `pressSequentially` correctly replaces deprecated `locator.type()` (verified against Playwright 1.38+ docs)
- ✅ `page.clock.install` API correct (verified — controls `Date`, `setTimeout`, etc.)
- ✅ `route.fulfill` with `json` option exists (verified — api-reference.md uses it correctly)
- ✅ `@playwright/experimental-ct-react` is the correct package name (still experimental as of 2025)
- ✅ Locator priority order matches official Playwright recommendations
- ✅ Auto-waiting behavior correctly described; pitfalls around `innerText()`/`isVisible()` vs retrying assertions are covered in troubleshooting.md
- ✅ Auth patterns (globalSetup + storageState, project dependencies) are accurate
- ✅ GitHub Actions workflow templates use correct action versions (v4) and proper caching strategy
- ✅ Scripts are well-structured with proper argument parsing, error handling, and help text

## Trigger Check

- ✅ Positive triggers cover: browser tests, e2e tests, UI automation, cross-browser testing, visual regression, component testing, network mocking, multi-browser suites
- ✅ Negative triggers exclude: unit tests, API-only testing, Selenium, Cypress, Puppeteer, Appium/Detox, k6/Artillery
- ✅ Would trigger for real queries: "write Playwright tests", "set up e2e testing", "browser automation with Playwright"
- ✅ Low false-positive risk due to explicit competitor exclusions
- Minor gap: queries like "playwright config setup" or "test runner configuration" might not trigger as strongly

## Verdict

Excellent skill. Comprehensive, accurate, and immediately actionable. The main SKILL.md is a complete guide for writing Playwright tests, and the reference docs provide deep-dive coverage. All code examples are syntactically correct, follow best practices, and an AI could execute from this without needing external documentation. Minor issues are cosmetic (version pinning, newer API sugar).
