# Review: selenium-testing

Accuracy: 4/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 4/5
Overall: 4.5/5

Issues:

1. **Relative locator method names (SKILL.md line 64):** Lists `toLeftOf()`, `toRightOf()` (Java camelCase) but Python uses `to_left_of()`, `to_right_of()`. Since the skill covers both languages, both conventions should be noted.

2. **setup-selenium-grid.sh line 135 bug:** When `--vnc` is enabled, `SE_VNC_NO_PASSWORD=true` is appended under the `ports:` YAML block instead of `environment:`, producing invalid docker-compose YAML.

3. **conftest.py contradicts SKILL.md advice:** The conftest fixture sets `driver.implicitly_wait(5)` while SKILL.md line 170 warns "Avoid mixing with explicit waits." The base_page.py asset uses explicit waits throughout, which would conflict.

4. **generate-page-object.sh `--headless` flag is a no-op:** `HEADLESS` defaults to `"true"` (line 40), so the `--headless` flag redundantly sets it to `"true"` again. There is no `--no-headless` option.

5. **Minor: deprecated `version: "3"` in docker-compose files.** Modern Docker Compose ignores the version field; removing it avoids deprecation warnings.

## Structure Check
- ✅ YAML frontmatter: name + description present
- ✅ Positive AND negative triggers in description
- ✅ Body: 487 lines (under 500 limit)
- ✅ Imperative voice throughout
- ✅ Examples with input/output in Python and Java
- ✅ References (3 docs), scripts (3 executables), assets (4 templates) all properly linked

## Content Check
- ✅ Selenium Manager in 4.6+ — verified accurate
- ✅ Relative locators API (locate_with / RelativeLocator.withTagName) — verified accurate
- ✅ Grid 4 microservices architecture (Router, Distributor, Session Map, etc.) — verified accurate
- ✅ CDP integration (Network.emulateNetworkConditions) — verified accurate
- ✅ BiDi protocol, New Window API, locator strategies, waits, POM, Actions API — all correct
- ⚠️ Minor inaccuracies noted in issues above

## Trigger Check
- ✅ Strong positive triggers: Selenium WebDriver, Grid, migration, locators, POM, Actions API
- ✅ Clear negative exclusions: Playwright, Cypress, Puppeteer, API-only, Appium native
- ✅ Would correctly trigger for "selenium test", "selenium grid docker", "page object model selenium"
- ✅ Would correctly NOT trigger for "playwright e2e" or "cypress component test"
- Could add broader terms like "browser automation testing" for better recall
