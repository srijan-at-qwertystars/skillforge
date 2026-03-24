# Review: rxjs-patterns

Accuracy: 4/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 4/5
Overall: 4.5/5
Issues:

1. **Incorrect debounceTime marble test (SKILL.md line 409):**
   `debounceTime(20)` with source `'-a--bc--d---|'` (≈13ms total) cannot produce
   `'----b---d---|'`. In run mode each dash is 1ms — a 20ms silence window never
   occurs within a 13ms source. The pending value `d` would emit only on source
   completion, yielding something like `'-----------(d|)'`. This test would fail
   if executed.

2. **Deprecated `retryWhen` imported without warning (SKILL.md line 167):**
   `retryWhen` is imported alongside `catchError`, `retry`, etc. in the Error
   Handling section but is deprecated since RxJS 7.x (removal targeted for v9).
   The import should be removed or annotated as deprecated. The migration table
   (line 416) also omits the `retryWhen → retry({ delay })` replacement.

3. **Minor: NgRx excluded in trigger but covered in references:**
   Description says "Do NOT use for … Redux/NgRx store logic" but
   `references/angular-integration.md` has a full NgRx Effects + ComponentStore
   section. Consider narrowing the exclusion to "standalone NgRx store design"
   to avoid suppressing valid RxJS-in-NgRx queries.

## Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML `name` + `description` | ✅ Pass | Present and well-formed |
| Positive triggers in description | ✅ Pass | Observable streams, operators, Subjects, marble tests, Angular |
| Negative triggers in description | ✅ Pass | Promises, async/await, Redux/NgRx, general TS |
| Body under 500 lines | ✅ Pass | 493 lines |
| Imperative voice, no filler | ✅ Pass | Dense, direct, no fluff |
| Examples with input/output | ✅ Pass | Marble diagrams, code samples throughout |
| references/ linked | ✅ Pass | 3 docs linked with descriptions (lines 465-471) |
| scripts/ linked | ✅ Pass | 3 scripts linked with descriptions (lines 475-481) |
| assets/ linked | ✅ Pass | 5 templates linked with descriptions (lines 485-493) |

## Content Verification

| Topic | Status | Notes |
|-------|--------|-------|
| switchMap/mergeMap/concatMap/exhaustMap | ✅ Accurate | Signatures, behavior, concurrency, cancellation all correct per RxJS docs |
| Higher-order strategy table | ✅ Accurate | Matches official behavior |
| shareReplay refCount gotcha | ✅ Accurate | Correctly warns `refCount: true` required; anti-pattern shown |
| Subject types (Behavior/Replay/Async) | ✅ Accurate | Descriptions and examples correct |
| Marble syntax table | ✅ Accurate | `-` = 1ms in run mode, `()` sync groups, `^`/`!` sub/unsub |
| debounceTime marble test | ❌ Incorrect | See issue #1 above |
| Import path deprecation (rxjs/operators) | ✅ Accurate | Correctly identifies RxJS 7.2+ change |
| toSignal/toObservable (Angular 16+) | ✅ Current | Matches Angular 18/19 stable APIs |
| takeUntilDestroyed / DestroyRef | ✅ Current | Correct injection context requirements documented |
| retry with config (RxJS 7+) | ✅ Accurate | `retry({ count, delay })` pattern shown correctly |
| retryWhen deprecation | ⚠️ Omitted | See issue #2 |
| Memory leak patterns | ✅ Thorough | 3 patterns + rules + detection in troubleshooting ref |
| Hot vs Cold | ✅ Accurate | Table and share/shareReplay solutions correct |
| Error handling patterns | ✅ Accurate | catchError position, retry backoff, EMPTY swallow |
| Combination operators | ✅ Accurate | combineLatest, forkJoin, zip, merge, withLatestFrom |
| Performance guidelines | ✅ Solid | Anti-patterns (nested subscribe, shareReplay without refCount) |

### Assets & Scripts Quality

- **assets/**: All 5 TypeScript templates are well-structured, properly typed, and would compile with Angular/RxJS dependencies. The `reactive-service.ts` and `polling-with-backoff.ts` are production-quality.
- **scripts/**: All 3 bash scripts are functional with `set -euo pipefail`, proper argument handling, and useful output. The `operator-finder.sh` is particularly well done as an interactive reference tool.
- **references/**: All 3 deep-dive docs are thorough and accurate. The `troubleshooting.md` covers edge cases rarely found in other references (ExpressionChanged, zone.js, router guard completion).

## Trigger Check

- ✅ Triggers for: "switchMap vs mergeMap", "RxJS memory leak", "marble test failing", "Observable HttpClient", "shareReplay"
- ✅ Does NOT trigger for: "async/await pattern", "Promise.all", "addEventListener", "general TypeScript types"
- ⚠️ Edge case: "NgRx effect using switchMap" might be suppressed despite being a valid RxJS pattern question

## Summary

Exceptionally thorough skill with production-quality examples, comprehensive reference docs, useful scripts, and ready-to-use TypeScript templates. The two substantive issues (incorrect marble test, deprecated retryWhen import) are minor and localized. No structural problems. Angular integration patterns are current through Angular 18/19. The skill would enable an AI to handle virtually any RxJS coding task autonomously.
