# QA Review: SolidJS Skill

**Skill path:** `frontend/solid-js/`
**Reviewer:** Automated QA
**Date:** 2025-07-17
**Verdict:** PASS (with recommendations)

---

## A. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter has `name` | ✅ | `name: solid-js` |
| YAML frontmatter has `description` | ✅ | Comprehensive, multi-line |
| Positive triggers in description | ✅ | SolidJS, createSignal, createEffect, createMemo, createResource, createStore, SolidStart, Solid Router, solid-js |
| Negative triggers in description | ✅ | NOT for React, Vue, Svelte, Angular, SOLID principles in OOP |
| Body under 500 lines | ✅ | 473 lines |
| Imperative voice | ✅ | "Always use these", "Never destructure props", "Use `class` not `className`" |
| Examples with Input/Output | ✅ | Two full examples: Todo app (line 383) and Data Fetching (line 421) |
| Resources properly linked | ✅ | Tables for references (3 files), scripts (3 files), assets (4 files) — all exist and are well-documented |

**Structure score: All criteria met.**

---

## B. Content Check

### Core Reactive Primitives — Verified Against Official Docs

| API | Accuracy | Notes |
|-----|----------|-------|
| `createSignal` | ✅ Correct | Signature, getter/setter pattern, `options.equals` — all match official docs |
| `createEffect` | ✅ Correct | Auto-tracking, `on()` for explicit deps, `defer` option |
| `createMemo` | ✅ Correct | Cached derived value, recalculates on dependency change |
| `createResource` | ✅ Correct | Returns `[resource, {mutate, refetch}]`, `resource.loading`, `.error`, `.state` with all 5 states |
| `createStore` | ✅ Correct | From `solid-js/store`, path syntax for surgical updates, predicate filtering |
| `produce` | ✅ Correct | Immer-like mutable draft syntax, from `solid-js/store` |
| `reconcile` | ✅ Correct | Diff-and-patch with `key` option, from `solid-js/store` |

### SolidStart APIs

| API | Accuracy | Notes |
|-----|----------|-------|
| `createAsync` | ✅ Correct | From `@solidjs/router`, returns reactive accessor |
| `"use server"` | ✅ Correct | Directive for server-only functions |
| `cache` | ⚠️ Deprecated | `cache` was renamed to `query` in `@solidjs/router` v0.15.0. The skill uses `cache` in SKILL.md (line 272), `solid-start-route.tsx`, and `advanced-patterns.md`. Code still works but is deprecated. **Recommend updating to `query`.** |

### JSX Differences from React

| Difference | Accuracy | Notes |
|------------|----------|-------|
| `class` not `className` | ✅ Correct | Solid supports both but `class` is preferred |
| `onChange` fires on blur | ✅ Correct | Use `onInput` for real-time input tracking |
| Style uses kebab-case strings | ✅ Correct | `style={{ "font-size": "16px" }}` — Solid also supports camelCase but kebab is idiomatic |
| `innerHTML` not `dangerouslySetInnerHTML` | ✅ Correct | |
| `for` not `htmlFor` | ✅ Correct | |
| No `key` prop | ✅ Correct | `<For>` handles identity via callback |
| Refs are plain variables | ✅ Correct | `let ref!: HTMLElement` with definite assignment |

### Content Issue: Context Example Anti-Pattern

SKILL.md line 199 shows:
```tsx
<ThemeCtx.Provider value={theme()}>
```
This passes a **static snapshot** of the signal value, which the skill's own `troubleshooting.md` (line 337) correctly identifies as a broken pattern. The context example should pass the signal accessor or an object:
```tsx
<ThemeCtx.Provider value={{ theme, setTheme }}>
```
**Recommend fixing this inconsistency.**

### Supplementary Files Quality

| File | Quality | Notes |
|------|---------|-------|
| `references/advanced-patterns.md` | ✅ Excellent | Custom primitives, batch, untrack, on, directives, transition group, streaming SSR, islands |
| `references/api-reference.md` | ✅ Excellent | Complete type signatures for all APIs including `unwrap`, `createRoot`, `createRenderEffect`, `Dynamic` |
| `references/troubleshooting.md` | ✅ Excellent | 10 pitfall sections with ❌/✅ code pairs, covers TypeScript issues |
| `scripts/setup-solid.sh` | ✅ Good | Scaffolds both plain Solid and SolidStart projects, auto-detects pnpm |
| `scripts/migrate-from-react.sh` | ✅ Good | 17 pattern checks covering hooks, JSX, and structural patterns |
| `scripts/check-reactivity.sh` | ✅ Good | 10 reactivity-breaking pattern detectors |
| `assets/solid-component.tsx` | ✅ Excellent | Demonstrates splitProps, signals, effects, cleanup, refs, Show |
| `assets/solid-store.tsx` | ✅ Excellent | Full store+context pattern with produce, derived values, actions |
| `assets/solid-start-route.tsx` | ⚠️ Minor issue | Uses deprecated `cache` (should be `query`) |
| `assets/vite.config.ts` | ✅ Good | Complete Vitest + Vite config with path aliases |

---

## C. Trigger Check

### Would it trigger for SolidJS queries?
✅ **Yes** — Strong positive triggers: "SolidJS", "Solid app", "createSignal", "createEffect", "createMemo", "createResource", "createStore", "SolidStart", "Solid Router", "solid-js"

### Would it falsely trigger for other frameworks?
| Framework | Risk | Notes |
|-----------|------|-------|
| React | ✅ Low | Explicit "NOT for React" exclusion |
| Vue | ✅ Low | Explicit "NOT for Vue" exclusion |
| Svelte | ✅ Low | Explicit "NOT for Svelte" exclusion |
| Angular | ✅ Low | Explicit "NOT for Angular" exclusion |
| SOLID principles (OOP) | ✅ Low | Explicit "NOT for SOLID principles in OOP" exclusion |

### Minor trigger risks:
- "Solid app" could match "build a solid application" (meaning robust) — low risk since other context clues would disambiguate
- "createStore" exists in other ecosystems (e.g., Redux Toolkit) — low risk given other trigger terms would need co-occurrence

---

## D. Scores

| Dimension | Score | Justification |
|-----------|-------|---------------|
| **Accuracy** | 4/5 | Core APIs verified correct. Two issues: (1) `cache` → `query` deprecation not reflected; (2) Context example in SKILL.md body demonstrates the anti-pattern its own troubleshooting guide warns against. |
| **Completeness** | 5/5 | Exceptional coverage: reactive primitives, control flow (6 components), stores, props handling, context, lifecycle, refs, lazy/portals, router, SolidStart (setup, routing, server fns, SSR/SSG), styling, testing, anti-patterns table, 2 full I/O examples, 3 deep-dive references, 3 utility scripts, 4 templates. |
| **Actionability** | 5/5 | Every section has copy-paste code. Anti-pattern table with 3-column Why/Fix format. Setup script scaffolds full project. Migration script detects 17 React patterns. Reactivity checker finds 10 common bugs. Templates cover component, store, route, and config patterns. |
| **Trigger quality** | 4/5 | Strong positive triggers covering framework name, all core primitives, and ecosystem tools. Explicit negative triggers for 5 confusion sources. Minor ambiguity with "Solid app" and "createStore" in isolation. |

### Overall: 4.5/5 — **PASS**

---

## Recommendations

1. **[High] Rename `cache` → `query`** across SKILL.md, `solid-start-route.tsx`, and `advanced-patterns.md`. The `cache` API was deprecated in `@solidjs/router` v0.15.0 and renamed to `query`. Add a note that `cache` is a deprecated alias.

2. **[High] Fix Context example** in SKILL.md (line 192-205). Currently passes `value={theme()}` (static snapshot). Should pass signal accessor or object `value={{ theme, setTheme }}` to maintain reactivity, consistent with the troubleshooting guide's own advice.

3. **[Low] Add `query` to trigger keywords** in the YAML description for future discoverability.

4. **[Low] Note `style` camelCase support** — the JSX differences table says Solid uses `"font-size": "16px"` but Solid also supports `fontSize: "16px"`. Mentioning both prevents confusion for React migrants.
