# QA Review: load-testing skill

**Skill path:** `~/skillforge/testing/load-testing/`
**Reviewed:** 2025-07-17
**Reviewer:** Copilot CLI (automated)

---

## A. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter has `name` | ✅ Pass | `name: load-testing` |
| YAML frontmatter has `description` | ✅ Pass | Multi-line description with tool coverage and test types |
| Positive triggers in description | ✅ Pass | load test, stress test, benchmark, performance test, measure throughput/latency, set up k6/Locust/Artillery/JMeter |
| Negative triggers in description | ✅ Pass | unit tests, integration tests, e2e functional tests, security pen testing, static analysis, code coverage, monitoring/alerting without load gen |
| Body under 500 lines | ✅ Pass | 471 lines (483 total minus 12-line frontmatter) |
| Imperative voice | ✅ Pass | Consistent use of "Use", "Set", "Add", "Write", "Run" throughout |
| Examples with I/O | ✅ Pass | 6 input→output examples covering RPS validation, spike tests, CI/CD, GraphQL, DB bottlenecks, Locust setup |
| Resources properly linked | ✅ Pass | 3 reference docs, 3 scripts, 5 asset templates — all documented in tables with descriptions |

**Structure verdict: PASS**

---

## B. Content Check

### k6 API Verification (web-searched)

| Element | Status | Notes |
|---------|--------|-------|
| Executors (6 listed) | ✅ Correct | `ramping-vus`, `constant-arrival-rate`, `ramping-arrival-rate`, `shared-iterations`, `per-vu-iterations`, `constant-vus` — all valid per official docs. Omits `externally-controlled` (minor, rarely used). |
| Threshold syntax | ✅ Correct | `p(95)<500`, `abortOnFail`, `delayAbortEval` — confirmed against grafana.com/docs |
| Per-group thresholds | ✅ Correct | `http_req_duration{group:::Login}` syntax verified |
| Custom metrics | ✅ Correct | `Rate`, `Trend`, `Counter`, `Gauge` — all valid k6/metrics types |
| Scenarios/options structure | ✅ Correct | `stages`, `scenarios`, executor configs all valid |
| DNS config (line 426) | ⚠️ **Error** | Uses `policy: 'roundRobin'` — should be `select: 'roundRobin'`. In k6, `dns.select` controls IP selection strategy (roundRobin/random/first); `dns.policy` controls IPv4/IPv6 preference (preferIPv4/preferIPv6/any). The asset `k6-api-test.js` correctly uses `select`. |
| Extensions (line 140) | ⚠️ **Outdated** | Lists `xk6-browser` as extension — since k6 v0.46+ the browser module is built-in (`k6/browser`). Similarly `xk6-dashboard` is now built-in (`--out web-dashboard`) since v0.49+. The browser asset file correctly imports from `k6/browser`. |

### Locust API Verification (web-searched)

| Element | Status | Notes |
|---------|--------|-------|
| `HttpUser`, `@task`, `between` | ✅ Correct | Current Locust 2.43+ API |
| `LoadTestShape` with `tick()` | ✅ Correct | Returns `(users, spawn_rate)` tuple or `None` |
| `catch_response=True` pattern | ✅ Correct | `resp.failure()` / `resp.success()` context manager |
| `events.request.add_listener` | ✅ Correct | Standard event hook API |
| Distributed mode flags | ✅ Correct | `--master`, `--worker`, `--master-host`, `--expect-workers` |
| `@tag` decorator | ✅ Correct | Available in current Locust |

### Artillery Config Verification (web-searched)

| Element | Status | Notes |
|---------|--------|-------|
| `config.phases` with `arrivalRate` | ✅ Correct | Standard Artillery config structure |
| `config.ensure.thresholds` | ✅ Correct | Proper placement at config level (not under plugins) |
| Metric names `http.response_time.p95/p99` | ✅ Correct | Valid Artillery metric identifiers |
| `scenarios.flow` with capture/expect | ✅ Correct | Standard scenario definition |

### Coordinated Omission Explanation

✅ **Accurate.** The explanation correctly identifies closed-loop (VU-based) testing as susceptible to coordinated omission, explains the mechanism (slower response → fewer requests → under-representation of latency spikes), and correctly recommends `constant-arrival-rate` executor for open-loop testing. The troubleshooting reference doc provides an excellent deep-dive with detection and mitigation strategies.

### Other Content Notes

- Test type definitions (smoke, load, stress, soak, spike, breakpoint) are standard and correct
- Grafana dashboard ID 2587 is the correct k6 InfluxDB dashboard
- `grafana/k6-action@v0.3.1` is a valid GitHub Action
- WebSocket, gRPC, GraphQL, and database testing examples are syntactically correct
- Scripts are well-structured with proper error handling, argument parsing, and color output

**Content verdict: PASS with minor issues**

---

## C. Trigger Check

### Should trigger ✅

| Query | Would trigger? |
|-------|---------------|
| "Set up a load test for our API" | ✅ Yes — matches "load test" |
| "Help me stress test the checkout flow" | ✅ Yes — matches "stress test" |
| "Benchmark our service performance" | ✅ Yes — matches "benchmark", "performance" |
| "Measure API throughput and latency" | ✅ Yes — matches "throughput", "latency" |
| "Create k6 test scripts" | ✅ Yes — matches "k6" |
| "Set up Locust for our team" | ✅ Yes — matches "Locust" |
| "Performance test before release" | ✅ Yes — matches "performance test" |

### Should NOT trigger ✅

| Query | Would trigger? |
|-------|---------------|
| "Write unit tests for the auth module" | ✅ No — excluded by "unit tests" |
| "Set up integration test suite" | ✅ No — excluded by "integration tests" |
| "Configure Selenium e2e tests" | ✅ No — excluded by "end-to-end functional tests" |
| "Run a security penetration test" | ✅ No — excluded by "security penetration testing" |
| "Improve code coverage to 80%" | ✅ No — excluded by "code coverage" |
| "Set up Datadog monitoring" | ✅ No — excluded by "monitoring/alerting setup without load generation" |

### Edge cases / gaps

- "Chaos engineering" / "resilience testing" — not explicitly excluded, could be a borderline false positive
- "Synthetic monitoring" — not excluded, though arguably distinct from load testing
- These are minor and unlikely to cause practical problems

**Trigger verdict: PASS**

---

## D. Scores

| Dimension | Score | Justification |
|-----------|-------|---------------|
| **Accuracy** | 4 / 5 | Nearly all technical content verified correct. Two issues: (1) DNS field name `policy` should be `select` for roundRobin selection, (2) `xk6-browser` and `xk6-dashboard` are now built-in modules, not extensions. Both are relatively minor. |
| **Completeness** | 5 / 5 | Exceptionally comprehensive. Covers 4 tools (k6 primary + Locust + Artillery + JMeter), 6 test types, 4 protocols (REST/GraphQL/gRPC/WebSocket), database testing, distributed testing, CI/CD integration, reporting stack, 10 common gotchas. Three deep-dive reference docs, three executable scripts, five asset templates. |
| **Actionability** | 5 / 5 | Copy-paste ready code for every scenario. `init-k6-project.sh` bootstraps a complete project. `run-test-suite.sh` automates smoke→load→stress progression with baseline comparison. Docker Compose for monitoring. GitHub Actions workflow. Input→output examples are concrete and immediately implementable. |
| **Trigger quality** | 4 / 5 | Strong positive and negative triggers covering the main use cases. Minor gaps: could explicitly exclude chaos engineering, synthetic monitoring. No significant false positive/negative risk in practice. |

### Overall: **4.5 / 5**

---

## E. Issues Found

| Severity | Location | Issue | Suggested Fix |
|----------|----------|-------|---------------|
| Minor | SKILL.md line 426 | DNS config uses `policy: 'roundRobin'` — wrong field name | Change to `select: 'roundRobin'` (k6 `dns.select` controls IP selection; `dns.policy` controls IPv4/IPv6 preference) |
| Minor | SKILL.md line 140 | Lists `xk6-browser` as extension | Note it's built-in since k6 v0.46+ (`import { browser } from 'k6/browser'`). Consider updating to mention the built-in module. |
| Minor | SKILL.md line 141 | Lists `xk6-dashboard` as extension | Note it's built-in since k6 v0.49+ (`k6 run --out web-dashboard`). Update accordingly. |
| Nit | SKILL.md description | Missing negative triggers for chaos engineering, synthetic monitoring | Consider adding for completeness |

No GitHub issues filed — overall score ≥ 4.0 and no dimension ≤ 2.

---

## F. Summary

This is a **high-quality, production-ready skill**. It provides comprehensive, accurate, and immediately actionable guidance for load testing across multiple tools and protocols. The reference documents, scripts, and asset templates are well-crafted and would meaningfully accelerate a team setting up load testing. The few issues found are minor field-name and outdated-reference corrections that don't materially impact usability.

**Result: PASS**
