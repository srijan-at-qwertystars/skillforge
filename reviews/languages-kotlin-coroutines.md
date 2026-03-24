# QA Review: kotlin-coroutines

**Skill path:** `languages/kotlin-coroutines/SKILL.md`
**Reviewed:** 2025-07-17
**Reviewer:** Copilot QA

---

## A. Structure Check

| Criterion | Status | Notes |
|---|---|---|
| YAML frontmatter | ✅ Pass | `name`, `description` with positive triggers and `NOT` exclusions present |
| Under 500 lines | ✅ Pass | 485 lines |
| Imperative voice | ✅ Pass | Consistent imperative/declarative style throughout |
| Code examples | ✅ Pass | Every section has annotated `// Input:` / `// Output:` examples |
| References linked | ✅ Pass | 3 reference docs (`advanced-patterns.md`, `troubleshooting.md`, `android-patterns.md`) — all exist |
| Scripts linked | ✅ Pass | 3 scripts (`coroutine-benchmark.kt`, `flow-visualizer.kt`, `lint-coroutines.sh`) — all exist |
| Assets linked | ✅ Pass | 5 assets (test template, flow patterns, ktor patterns, gradle config, cheatsheet) — all exist |

## B. Content Check

### Verified Correct
- **Coroutine builders** (`launch`, `async`, `runBlocking`, `coroutineScope`, `withContext`): Accurate descriptions and semantics.
- **Dispatchers table**: `Default` (CPU-bound), `IO` (elastic), `Main` (UI), `Unconfined` (caller) — all correct.
- **`limitedParallelism` named parameter**: Correctly noted as 1.9+ feature. Verified against kotlinx.coroutines changelog.
- **`flowOn` upstream semantics**: Correctly states it changes upstream dispatcher; collection stays in collector's context. Verified.
- **StateFlow conflation**: Correctly describes equality-based conflation (skips equal values). Verified.
- **Channel.BUFFERED default = 64**: Correct. Verified against official docs.
- **SharedFlow vs StateFlow table**: Accurate comparison (initial value, replay, conflation, use case).
- **Exception handling rules**: `CoroutineExceptionHandler` only on root coroutines, `async` surfaces at `.await()`, `CancellationException` special — all correct.
- **Testing**: `runTest`, `advanceUntilIdle`, `advanceTimeBy`, Turbine library — all correct.
- **Android integration**: `viewModelScope`, `lifecycleScope`, `repeatOnLifecycle` — correct and idiomatic.

### Issues Found

#### 🔴 Error: StandardTestDispatcher mislabeled (Line 334)

> `StandardTestDispatcher` (eager: no auto-run)

**Problem:** `StandardTestDispatcher` is **not** eager. It is the *scheduled/lazy* dispatcher — tasks are queued and require manual advancement (`advanceUntilIdle`, `advanceTimeBy`). `UnconfinedTestDispatcher` is the eager one that auto-runs coroutines immediately at launch.

**Correct description:**
- `StandardTestDispatcher` — scheduled: requires manual advancement
- `UnconfinedTestDispatcher` — eager: auto-dispatches at launch

#### 🟡 Missing: `callbackFlow` / `suspendCancellableCoroutine`

These are essential APIs for bridging callback-based code (Firebase, legacy Android SDKs, etc.) to coroutines/Flows. Neither is mentioned in SKILL.md or the Flow operators section. `callbackFlow` is especially critical for Android developers.

#### 🟡 Missing: `flowOn` implicit buffering gotcha

When `flowOn` switches dispatchers, it introduces an implicit `Channel.BUFFERED` (64-element) buffer between upstream and downstream. This is a common source of confusion and is not mentioned despite `flowOn` being documented.

#### 🟡 Missing: `withTimeout` vs `withTimeoutOrNull`

Only `withTimeoutOrNull` is shown (line 431). `withTimeout` throws `TimeoutCancellationException` (a `CancellationException` subclass), which has subtle implications — it can be silently swallowed in a `supervisorScope`. Both variants should be documented.

#### 🟡 Minor: Version scope

Title says "kotlinx.coroutines 1.8+" but latest stable is **1.10.2**. The named `limitedParallelism` parameter (shown on line 109) requires 1.9+. Consider updating the title to "1.9+" or adding a version note to the `limitedParallelism` example.

## C. Trigger Check

| Criterion | Status | Notes |
|---|---|---|
| Positive triggers specific to Kotlin coroutines | ✅ | 17 specific trigger terms covering builders, scopes, dispatchers, flows, channels |
| False-trigger risk: RxJava | ✅ Low | Explicitly excluded in NOT clause |
| False-trigger risk: Project Reactor | ✅ Low | Explicitly excluded in NOT clause |
| False-trigger risk: General Kotlin | ✅ Low | NOT clause requires "concurrency context" |
| False-trigger risk: "Flow" ambiguity | ⚠️ Minor | Bare "Flow" could match non-Kotlin contexts (e.g., UI flow, data flow), but description context and other trigger terms disambiguate sufficiently |
| Negative triggers comprehensive | ✅ | Covers Java threads, RxJava, Reactor, goroutines, asyncio |

## D. Scores

| Dimension | Score | Rationale |
|---|---|---|
| **Accuracy** | 4 / 5 | One factual error (StandardTestDispatcher "eager" label). All other API descriptions verified correct. |
| **Completeness** | 4 / 5 | Excellent breadth — builders, structured concurrency, Flow, StateFlow/SharedFlow, Channels, Select, exceptions, testing, Android, Ktor, patterns. Missing `callbackFlow`, `withTimeout`, `flowOn` buffering gotcha. |
| **Actionability** | 5 / 5 | Outstanding. Every concept has copy-paste code with input/output annotations. Includes reusable patterns (retry, timeout, mutex, parallel decomposition). Rich supporting assets: test template, flow patterns, Ktor patterns, gradle config, lint script, benchmark, visualizer, cheatsheet. |
| **Trigger quality** | 4 / 5 | Well-crafted positive triggers with comprehensive NOT exclusions. Minor "Flow" ambiguity risk. |

**Overall: 4.25 / 5.0** — Pass

## E. Recommendations

1. **Fix** the `StandardTestDispatcher` label from "eager: no auto-run" to "scheduled: requires manual advancement" (accuracy fix).
2. **Add** a `callbackFlow` / `suspendCancellableCoroutine` section for callback bridging — this is a top-3 use case in Android coroutine adoption.
3. **Add** a note about `flowOn` introducing implicit buffering (Channel.BUFFERED = 64).
4. **Add** `withTimeout` alongside `withTimeoutOrNull` with a note about `TimeoutCancellationException`.
5. **Consider** updating the version scope from "1.8+" to "1.9+" given the `limitedParallelism` named parameter feature.

---

**Verdict: PASS** — No dimension ≤ 2, overall ≥ 4.0. Quality is high; issues are incremental improvements.
