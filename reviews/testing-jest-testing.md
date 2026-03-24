# QA Review: jest-testing

**Skill path:** `~/skillforge/testing/jest-testing/`
**Reviewer:** Copilot CLI QA
**Date:** 2025-07-17

---

## A. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter `name` | ✅ Pass | `name: jest-testing` |
| YAML frontmatter `description` | ✅ Pass | Multi-line description present |
| Positive triggers in description | ✅ Pass | 12 trigger terms: "Jest", "jest.mock", "jest.fn", "jest.spyOn", "test suite", "snapshot testing", "describe block", "toMatchSnapshot", "jest.config", "__mocks__", "jest --coverage", "test.each" |
| Negative triggers in description | ✅ Pass | 5 exclusions: Vitest, Mocha/Chai, Playwright/Cypress, pytest, Storybook interaction tests |
| Body under 500 lines | ✅ Pass | 493 total lines (≈487 body lines after frontmatter) |
| Imperative voice | ✅ Pass | Consistent: "Use `describe` to group…", "Keep snapshots small…", "Prefer `restoreAllMocks`…" |
| Examples with I/O | ✅ Pass | 7+ examples annotated with `// Input:` / `// Output:` comments (calculator, throw test, callback mock, API module, debounce, parameterized, custom matcher, login form) |
| Resources properly linked | ✅ Pass | 3 references, 3 scripts, 5 assets — all linked with Markdown paths and one-line descriptions |

**Structure verdict: PASS** — all criteria met.

---

## B. Content Check (Jest 29 API Verification)

Each API claim was cross-referenced against official Jest 29 docs and community sources.

### jest.fn()
- ✅ `mockReturnValue`, `mockReturnValueOnce`, `mockImplementation`, `mockResolvedValue`, `mockRejectedValue` — all correct.
- ✅ `.mock.calls`, `.mock.results`, `.mock.instances`, `.mock.lastCall`, `.mock.contexts` — accurate for Jest 29.
- ✅ Typed mock syntax `jest.fn<(a: number) => string>()` — valid Jest 29+ TS overload.

### jest.mock() hoisting
- ✅ Correctly states `jest.mock()` is hoisted above imports by Babel/ts-jest.
- ✅ Documents the `mock`-prefix variable exception for factory closures.
- ✅ Covers `jest.doMock()` (not hoisted) and `jest.unstable_mockModule()` for ESM — accurate.
- ✅ Partial mocking with `jest.requireActual()` pattern is correct.

### jest.spyOn()
- ✅ Standard method spying syntax correct.
- ✅ Getter/setter spy syntax (`jest.spyOn(obj, 'prop', 'get')`) — confirmed in Jest 29 docs.
- ✅ `.mockRestore()` advice is correct and important.

### Timer mocking (useFakeTimers)
- ✅ `jest.useFakeTimers()` options: `advanceTimers`, `doNotFake`, `now`, `timerLimit` — all valid Jest 29 config properties.
- ✅ `advanceTimersByTime`, `runAllTimers`, `runOnlyPendingTimers`, `advanceTimersToNextTimer` — all correct.
- ✅ Async variants (`advanceTimersByTimeAsync`, `runAllTimersAsync`, etc.) documented in api-reference.md — correct for Jest 29.
- ✅ `jest.setSystemTime()`, `jest.getRealSystemTime()`, `jest.getTimerCount()`, `jest.clearAllTimers()` — all accurate.
- ⚠️ Minor: `timerLimit: 100` in api-reference.md example could mislead readers (default is 100,000). Value works as an illustrative example but a comment noting the default would help.

### @testing-library/react renderHook
- ✅ Correctly imports `renderHook` from `@testing-library/react` (not the deprecated `@testing-library/react-hooks`).
- ✅ `act` import also from `@testing-library/react` — correct for React 18+.
- ✅ Wrapper pattern for context providers documented accurately.

### Snapshot testing API
- ✅ `toMatchSnapshot()`, `toMatchInlineSnapshot()`, `toThrowErrorMatchingSnapshot()` — all verified in Jest 29 docs.
- ✅ Update workflow (`jest --updateSnapshot`, `jest -u`, watch mode `u`/`i` keys) — correct.
- ✅ `snapshotFormat`, `snapshotSerializers`, `expect.addSnapshotSerializer()` — all valid config.

### Configuration options
- ✅ `workerThreads: true/false` — valid Jest 29 option.
- ✅ `workerIdleMemoryLimit: '512MB'` — correct format and semantics.
- ✅ `coverageProvider: 'v8' | 'babel'` — both options documented correctly.
- ✅ `clearMocks`, `resetMocks`, `restoreMocks` auto-cleanup config flags — accurate.
- ✅ `injectGlobals: false` for `@jest/globals` imports — correct.
- ✅ CLI flags (`--shard`, `--bail`, `--detectOpenHandles`, `--ci`, `--logHeapUsage`, etc.) — all valid.

**Content verdict: PASS** — all APIs verified accurate for Jest 29. One minor documentation nit (timerLimit example value).

---

## C. Trigger Check

### Would trigger for Jest queries ✅
- Direct mentions: "jest.mock", "jest.fn", "jest.spyOn", "toMatchSnapshot", "jest.config", "jest --coverage" — all unambiguous Jest identifiers.
- Contextual mentions: "test suite", "describe block", "test.each", "__mocks__", "snapshot testing" — these are Jest-adjacent but also used by Mocha/Jasmine; however, paired with negative triggers they should filter correctly.

### Would NOT trigger for competing frameworks
| Framework | Exclusion | Assessment |
|-----------|-----------|------------|
| Vitest | "NOT for Vitest" | ✅ Clear exclusion. Vitest uses `vi.fn()`/`vi.mock()` which differ syntactically. |
| Mocha/Chai | "NOT for Mocha/Chai" | ✅ Excluded. Note: Mocha shares `describe`/`it` syntax but Chai's `expect().to.equal()` differs enough. |
| Playwright | "NOT for Playwright/Cypress E2E testing" | ✅ Excluded. Different testing paradigm (E2E vs unit). |
| pytest | "NOT for pytest or other non-JS test frameworks" | ✅ Excluded. Broad catch-all for non-JS. |
| Storybook | "NOT for Storybook interaction tests" | ✅ Excluded. |

### Minor gaps
- ⚠️ **Jasmine** is not explicitly called out in negative triggers. Since Jasmine shares significant API overlap with Jest (`describe`/`it`/`expect`/`spyOn`), a user asking "how do I use `spyOn` in my Jasmine tests" could potentially trigger this skill. Consider adding "NOT for Jasmine" or "NOT for standalone Jasmine."
- ⚠️ Generic terms "test suite" and "describe block" could false-positive for non-Jest contexts, but this is mitigated by the negative trigger list.

**Trigger verdict: PASS** — strong positive/negative coverage with minor Jasmine gap.

---

## D. Scores

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 5/5 | All Jest 29 APIs verified correct. Mock hoisting, timer options, renderHook imports, config options, snapshot API — all match official docs. No factual errors found. |
| **Completeness** | 5/5 | Comprehensive coverage: test structure, matchers (7 categories), async testing (3 patterns), mocking (fn/mock/spyOn/manual/partial), timers, snapshots, setup/teardown, parameterized tests, custom matchers, React testing (components + hooks + providers), config, coverage, performance. 3 reference docs (advanced patterns, troubleshooting, API reference), 3 scripts (setup, slow-test finder, migration), 5 asset templates. |
| **Actionability** | 5/5 | Every section has copy-paste code examples with Input/Output annotations. Scripts are executable with `--help` flags. Assets are production-ready templates. Troubleshooting guide has symptom→fix format. Migration script covers Mocha + Jasmine. |
| **Trigger quality** | 4/5 | Strong positive triggers (12 Jest-specific terms). Good negative triggers (5 exclusions). Minor gap: Jasmine not excluded; "test suite"/"describe block" are slightly generic. |

### Overall: **4.75 / 5.0**

---

## E. Verdict

**PASS** ✅

- Overall score 4.75 ≥ 4.0 threshold
- No dimension ≤ 2
- No GitHub issues required

### Recommendations (non-blocking)
1. Add "NOT for Jasmine" to negative triggers to prevent overlap with Jasmine-specific queries.
2. Add a comment in `api-reference.md` noting that `timerLimit` default is 100,000 (the example uses 100 which could mislead).
3. Consider adding `esbuild-jest` to the transformer comparison table (mentioned in Performance section but not in the table).
