# QA Review: testing/k6-load-testing

**Reviewer:** Copilot CLI  
**Date:** 2025-07-14  
**Skill path:** `~/skillforge/testing/k6-load-testing/`

---

## a. Structure Check

| Criterion | Status | Notes |
|---|---|---|
| YAML frontmatter `name` | ✅ Pass | `k6-load-testing` |
| YAML frontmatter `description` | ✅ Pass | Multi-line, detailed |
| Positive triggers (USE WHEN) | ✅ Pass | 12 trigger phrases covering scripts, test types, protocols, metrics |
| Negative triggers (DO NOT USE WHEN) | ✅ Pass | Excludes JMeter, Locust, Artillery, Gatling, Playwright e2e, unit testing |
| Body under 500 lines | ✅ Pass | SKILL.md = 414 lines |
| Imperative voice | ✅ Pass | Instructions use imperative throughout ("Run:", "Use", "Set") |
| Code examples | ✅ Pass | Every section has runnable JS/YAML/bash examples |
| references/ linked from SKILL.md | ✅ Pass | 3 files linked with descriptions (lines 390-396) |
| scripts/ linked from SKILL.md | ✅ Pass | 2 files linked with descriptions (lines 400-404) |
| assets/ linked from SKILL.md | ✅ Pass | 3 files linked with descriptions (lines 408-414) |

**Structure verdict:** Excellent. Clean organization, well within line budget, all supporting files properly linked.

---

## b. Content Check

### Verified Correct ✅

- **Executor types:** 6 of 7 correctly named with accurate config properties (`shared-iterations`, `per-vu-iterations`, `constant-vus`, `ramping-vus`, `constant-arrival-rate`, `ramping-arrival-rate`). 7th (`externally-controlled`) covered in `references/advanced-patterns.md`.
- **Built-in metrics:** Table on lines 334-346 matches official Grafana k6 docs. Types (Trend/Rate/Counter/Gauge) all correct.
- **CLI flags:** `--vus`, `--duration`, `--out` usage is accurate. Multiple `--out` flags shown correctly.
- **Custom metrics API:** `Counter`, `Gauge`, `Rate`, `Trend` from `k6/metrics` — constructor signatures and `.add()` semantics correct.
- **HTTP module:** `http.get/post/put/del/batch` all correct. Response object properties (`status`, `body`, `timings`, `json()`) accurate.
- **Browser module:** Correctly uses `import { browser } from 'k6/browser'` (not deprecated `k6/experimental/browser`). Async/await pattern correct.
- **gRPC module:** `k6/net/grpc` import, `client.load()`, `client.connect()`, `client.invoke()` all match current API.
- **Threshold exit code 99:** Confirmed correct.
- **Test lifecycle:** `init → setup → default → teardown` order and semantics correct.
- **`open()` init-only restriction:** Correctly documented.
- **SharedArray usage:** Correctly shown with memory efficiency explanation.
- **CI/CD integration:** GitHub Actions workflow uses current `grafana/setup-k6-action@v1` and `grafana/run-k6-action@v1`.

### Issues Found ⚠️

1. **"All six executors" — should be seven** (Accuracy)
   - Frontmatter line 6 says "all six executors" but k6 has 7. The `externally-controlled` executor is missing from the main SKILL.md (only in advanced-patterns.md). Inconsistently, the api-reference.md link description on line 396 says "all 7 executors."
   - **Impact:** Medium. Users may not discover the externally-controlled executor.

2. **WebSocket module uses legacy `k6/ws`** (Accuracy/Completeness)
   - Lines 260-272 import from `k6/ws`, which is now the legacy module. The current recommended module is `k6/websockets` (browser-compatible API, multiple concurrent connections per VU). `k6/ws` still works but is not the recommended path.
   - **Impact:** Medium. Scripts will work but miss modern features.

3. **`echo.websocket.org` is defunct** (Accuracy)
   - Line 263 uses `wss://echo.websocket.org` as the WebSocket test URL. This service was shut down in 2023.
   - **Impact:** Low. Example URL, but copy-paste will fail.

4. **Missing `dropped_iterations` metric** (Completeness)
   - The built-in metrics table (lines 334-346) omits `dropped_iterations` (Counter), which is important for arrival-rate executor diagnostics. It's mentioned in troubleshooting but not the main reference table.
   - **Impact:** Low.

### Missing Gotchas

- No mention of the `group()` limitation with async browser APIs (groups don't support async functions in browser module).
- No note about `http.asyncRequest` for Promise-based HTTP in the main HTTP section (only in api-reference.md).
- No mention of `gracefulStop`/`gracefulRampDown` in main SKILL.md (covered in advanced-patterns.md — acceptable).

### Examples Correctness

All code examples are syntactically correct and follow k6 conventions. The complete example (lines 349-386) is production-quality with multi-scenario composition, data parameterization, custom metrics, and proper error tracking.

---

## c. Trigger Check

### Description Analysis

The description is **strong and specific**. It opens with the core purpose ("Generate and edit Grafana k6 load testing scripts") and enumerates protocols, executors, features, and integration points.

**Strengths:**
- 12 positive trigger phrases cover broad k6 usage: scripts, all test types, scenarios, thresholds, checks, protocols, cloud, custom metrics, data parameterization
- 6 negative triggers properly exclude competing tools (JMeter, Locust, Artillery, Gatling) and unrelated testing (Playwright e2e, Jest/Mocha/pytest)
- Specific enough to avoid false triggers on general "load testing" queries

**Weaknesses:**
- Could false-trigger on "WebSocket load testing" for non-k6 tools (e.g., someone using ws library in Node.js)
- "HTTP load testing" is broad — could trigger for Artillery HTTP tests if user doesn't specify tool
- "browser testing with k6" is good disambiguation vs plain "browser testing"

**False trigger risk:** Low. The description is k6-specific enough that generic performance testing queries won't match easily.

---

## d. Scoring

| Dimension | Score | Rationale |
|---|---|---|
| **Accuracy** | 4 | Core APIs verified correct. Deductions: "six executors" (should be 7), legacy `k6/ws` module, defunct WebSocket URL |
| **Completeness** | 4 | Excellent coverage of lifecycle, executors, protocols, metrics, CI/CD, extensions. Deductions: missing `externally-controlled` in main doc, no `k6/websockets` mention, missing `dropped_iterations` |
| **Actionability** | 5 | Outstanding. Every concept has runnable code. Templates are production-ready. Scripts (setup-k6.sh, run-suite.sh) are well-engineered with error handling, color output, help text. Docker Compose stack is immediately usable. |
| **Trigger quality** | 4 | Strong positive/negative triggers. Minor risk of false triggers on generic "HTTP load testing" or "WebSocket load testing" without k6 context. |
| **Overall** | **4.25** | High-quality skill with minor accuracy issues that should be fixed |

---

## e. GitHub Issues

Overall score 4.25 ≥ 4.0 and no dimension ≤ 2. **No issues required.**

Recommended improvements (non-blocking):
1. Fix "all six executors" → "all seven executors" and add `externally-controlled` to the Scenarios section
2. Add `k6/websockets` module example alongside or replacing `k6/ws`
3. Replace `echo.websocket.org` with a working test URL (e.g., `wss://test-api.k6.io/ws`)
4. Add `dropped_iterations` to the built-in metrics table

---

## f. Test Status

**Result: PASS** ✅

The skill is accurate, comprehensive, and immediately actionable. The issues found are minor and do not prevent effective use of the skill.
