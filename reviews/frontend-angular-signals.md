# QA Review: angular-signals

**Skill path:** `frontend/angular-signals/`
**Reviewer:** Copilot CLI (automated)
**Date:** 2025-07-17
**Verdict:** ✅ PASS

---

## A. Structure Check

| Criterion | Status | Notes |
|---|---|---|
| YAML `name` | ✅ | `angular-signals` |
| YAML `description` | ✅ | Comprehensive, lists all covered APIs |
| Positive triggers | ✅ | 14 trigger phrases (e.g., "Angular signals", "signal()", "linkedSignal", "NgRx SignalStore") |
| Negative triggers | ✅ | 4 exclusions: AngularJS 1.x, React/Vue/Solid, RxJS-only, Angular Material/CDK unless signal-specific |
| Body line count | ✅ | 497 lines (limit: 500) |
| Imperative voice | ✅ | Consistent ("Create a writable signal", "Use effect for…", "Do NOT mutate…") |
| Examples with I/O | ✅ | Code blocks include inline output comments (`// read: 0`, `// 6`), before/after migration pairs, template usage |
| Resources linked | ✅ | 3 references, 3 scripts, 4 assets — all linked with relative paths, all files exist |
| Migration table | ✅ | 12-row decorator→signal cheat sheet with notes |

**Structure score: No issues.**

---

## B. Content Check — API Accuracy

Verified against official Angular docs, angular.dev, and community sources (July 2025).

### Core Primitives

| API | Skill claims | Verified | Notes |
|---|---|---|---|
| `signal()` | `@angular/core`, since 16, `set()`/`update()`/`asReadonly()` | ✅ | Correct |
| `computed()` | Lazy, memoized, `ComputedOptions.equal` | ✅ | Correct |
| `effect()` | `onCleanup`, injection context, `allowSignalWrites` deprecated in v19 | ✅ | Correct |
| `input()` / `input.required()` | Since 17.1, `InputSignal<T>`, alias/transform | ✅ | Correct; stable in v19 |
| `output()` | Since 17.3, `OutputEmitterRef<T>` | ✅ | Correct |
| `model()` | Since 17.2, `ModelSignal<T>`, two-way binding | ✅ | Correct |
| `linkedSignal()` | Since 19, shorthand & object form | ✅ | Correct; **developer preview** (not noted in body) |
| `resource()` | Since 19, `ResourceRef`, `ResourceStatus` enum | ✅ | Correct; **experimental** (not noted in body) |
| `httpResource()` | `@angular/common/http`, since 19.2 | ✅ | Import path confirmed correct |

### RxJS Interop

| API | Verified |
|---|---|
| `toSignal()` — 5 options (initialValue, requireSync, manualCleanup, rejectErrors, equal) | ✅ |
| `toObservable()` — async via microtask, deduplicates | ✅ |
| `outputToObservable()` / `outputFromObservable()` | ✅ |
| `takeUntilDestroyed()` | ✅ |

### Zoneless Change Detection

| Claim | Verified | Notes |
|---|---|---|
| `provideExperimentalZonelessChangeDetection()` from `@angular/core` | ✅ | Correct for Angular 18–19 |
| CD triggers table (signal updates, events, async pipe ✅; setTimeout, fetch ❌) | ✅ | Accurate |
| Stable `provideZonelessChangeDetection()` in Angular 20 | ⚠️ | **Not mentioned** — minor gap. Angular 20 drops "Experimental" prefix. The check-zoneless.sh script does grep for both variants, which is forward-compatible. |

### NgRx SignalStore

| API | Verified |
|---|---|
| `signalStore()`, `withState()`, `withComputed()`, `withMethods()`, `patchState()` | ✅ |
| `withEntities()`, `addEntity()`, `updateEntity()`, `removeEntity()`, `setEntities()`, `setAllEntities()` | ✅ |
| `withHooks({ onInit, onDestroy })` | ✅ |
| `rxMethod()` from `@ngrx/signals/rxjs-interop` | ✅ |
| `signalStoreFeature()` (mentioned, not demoed) | ✅ Acceptable |
| Entity collection syntax `{ entity: type<T>(), collection: 'name' }` | ✅ |

### Minor Content Issues

1. **`linkedSignal()` and `resource()` stability labels** — Body says "Angular 19+" but doesn't note these are in developer preview / experimental. The api-reference.md correctly notes "Since: Angular 19" but also omits preview status. Low-risk since the APIs are correctly documented.
2. **Stable zoneless API** — `provideZonelessChangeDetection()` (non-experimental) ships in Angular 20. The skill should eventually add a note. Non-blocking since the experimental API is still valid.

---

## C. Trigger Check

### Positive Trigger Analysis

| Query | Would trigger? | Reason |
|---|---|---|
| "How do I use Angular signals?" | ✅ | Matches "Angular signals" |
| "Convert @Input to signal input" | ✅ | Matches "input signal", migration content |
| "linkedSignal example" | ✅ | Exact trigger phrase |
| "NgRx SignalStore withEntities" | ✅ | Matches "NgRx SignalStore" |
| "Angular resource API for HTTP" | ✅ | Matches "Angular resource API" |
| "toSignal vs toObservable" | ✅ | Matches both trigger phrases |
| "zoneless change detection Angular" | ✅ | Matches "zoneless Angular" |

### Negative Trigger Analysis

| Query | Would trigger? | Reason |
|---|---|---|
| "AngularJS $scope digest cycle" | ❌ Correct | Excluded: "NOT for AngularJS (1.x)" |
| "React useSignal hook" | ❌ Correct | Excluded: "NOT for React/Vue/Solid signals" |
| "Vue ref() and reactive()" | ❌ Correct | Excluded: "NOT for React/Vue/Solid signals" |
| "SolidJS createSignal" | ❌ Correct | Excluded: "NOT for React/Vue/Solid signals" |
| "RxJS BehaviorSubject patterns" | ❌ Correct | Excluded: "NOT for RxJS-only patterns without signal interop" |
| "Angular Material dialog setup" | ❌ Correct | Excluded: "NOT for Angular Material or CDK unless signal-specific" |

**Trigger verdict:** Highly selective. Good positive coverage across all Angular signal surfaces. Negative triggers properly exclude adjacent frameworks and non-signal Angular topics.

---

## D. Scoring

| Dimension | Score | Justification |
|---|---|---|
| **Accuracy** | 4.5 / 5 | All APIs, imports, types, and behavior are correct. Minor: missing developer-preview/experimental labels on linkedSignal/resource in body, missing stable zoneless API note. |
| **Completeness** | 5.0 / 5 | Covers all 8 requested APIs + queries, RxJS interop, zoneless CD, NgRx SignalStore, migration schematics, anti-patterns, troubleshooting, testing. 3 references, 3 scripts, 4 asset templates. Exceptional breadth. |
| **Actionability** | 5.0 / 5 | Before/after migration table, copy-paste asset templates, runnable shell scripts (migrate, audit, zoneless-check), complete component example, NgRx store template, custom utilities library. |
| **Trigger Quality** | 4.5 / 5 | 14 positive, 4 negative trigger phrases. Comprehensive coverage with proper exclusions. Could add version-specific triggers ("Angular 17 signals", "Angular 19 resource"). |

**Overall: 4.75 / 5.0** — PASS

---

## E. Supplemental Files Assessment

### References (3 files)

- **advanced-patterns.md** (525 lines) — Custom utilities, state management, fine-grained reactivity, nested signals, equality, RxJS interop deep dive, zoneless architecture, performance. Thorough and well-organized.
- **api-reference.md** (633 lines) — Complete API with all overloads, types, and options for every signal function. High-quality reference material.
- **troubleshooting.md** (510 lines) — 9 categories: effect pitfalls, computed gotchas, mutation vs set, circular deps, memory leaks, migration issues, zone.js removal, testing, error messages. Practical, with ❌/✅ code pairs.

### Scripts (3 files)

- **migrate-to-signals.sh** — Scans for decorator patterns, suggests signal equivalents with line numbers. Well-structured with color output and summary.
- **check-zoneless.sh** — 7-step analysis of zone.js deps. Checks angular.json, package.json, imports, NgZone, async patterns, ChangeDetectorRef, provider setup. Forward-compatible (checks both experimental and stable APIs).
- **signal-audit.sh** — 6-check audit: usage stats, effects without cleanup, writes in computed, effect signal sync, in-place mutations, nested effects. Useful for code review automation.

### Assets (4 files)

- **signal-store.ts** — Full NgRx SignalStore template with entities, computed, methods, hooks, rxMethod (commented). Ready to copy-paste.
- **signal-component.ts** — Complete component using all signal APIs. Excellent reference implementation.
- **rxjs-interop.ts** — 7 patterns (route→signal, search, BehaviorSubject bridge, takeUntilDestroyed, output interop, complex async, WebSocket→signal). Production-grade examples.
- **custom-signal.ts** — 6 utilities (toggle, history/undo-redo, debounced, array, localStorage-persisted, form field with validators). High-quality, well-typed.

**All supplemental files are high-quality, relevant, and properly linked.**

---

## F. Recommendations (non-blocking)

1. Add a note that `linkedSignal()` and `resource()` are in **developer preview** (may change).
2. Mention that Angular 20 introduces the stable `provideZonelessChangeDetection()` alongside the experimental version.
3. Consider adding version-specific trigger phrases ("Angular 17 signals", "Angular 19 resource") for better version-based queries.
4. SKILL.md is at 497 lines — very close to the 500-line limit. Any future additions should go to reference files.

---

## Summary

An exceptional skill document. Comprehensive API coverage, accurate code samples verified against official sources, practical migration tooling, and strong trigger quality. The minor gaps (stability labels, upcoming stable zoneless API) are non-blocking and easily addressed in a future update.

**Result: PASS** | **Overall Score: 4.75 / 5.0**
