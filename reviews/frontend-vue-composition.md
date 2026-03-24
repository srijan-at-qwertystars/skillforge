# QA Review: vue-composition

**Skill path:** `frontend/vue-composition/`
**Reviewer:** Copilot CLI (automated)
**Date:** 2025-07-17

---

## A. Structure Check

| Criterion | Status | Notes |
|---|---|---|
| YAML frontmatter has `name` + `description` | ✅ Pass | `name: vue-composition`, multi-line description present |
| Description has **positive** triggers | ✅ Pass | "Use when writing Vue 3 SFCs, composables, or stores with Composition API" |
| Description has **negative** triggers | ✅ Pass | "Do NOT use for Vue 2, Options API-only code, Nuxt server routes, or non-Vue frameworks (React, Svelte, Angular)" |
| Body under 500 lines | ✅ Pass | 489 lines (11 lines under limit) |
| Imperative voice | ✅ Pass | "Always use `<script setup lang="ts">`", "Prefer `ref` over `reactive`", "Extract reusable logic into `use*` composables", "Type everything" |
| Examples with I/O | ✅ Pass | Every section has code blocks with usage patterns; composable examples show input parameters → returned refs |
| Resources properly linked | ✅ Pass | All 3 references, 3 scripts, 5 assets linked with relative paths — all files exist on disk |

**Structure verdict: PASS**

---

## B. Content Check

### Reactivity APIs — Verified ✅

- `ref`, `reactive`, `computed`, `watch`, `watchEffect`, `shallowRef`, `triggerRef` — all accurately described with correct `.value` semantics and caveats (destructuring `reactive` loses reactivity, etc.)
- Writable `computed` syntax matches official docs.

### Lifecycle Hooks — Verified ✅

- Lists all 10 standard hooks: `onBeforeMount`, `onMounted`, `onBeforeUpdate`, `onUpdated`, `onBeforeUnmount`, `onUnmounted`, `onActivated`, `onDeactivated`, `onErrorCaptured`, `onServerPrefetch`.
- Correctly notes synchronous registration requirement ("Never call inside `setTimeout` or after `await`").
- **Minor omission**: `onRenderTracked` and `onRenderTriggered` (debug-only hooks) not mentioned — acceptable since these are rarely used in production.

### defineModel (3.4+) — Verified ✅

- Correctly attributed to Vue 3.4+.
- Accurately describes it as replacing manual `modelValue` prop + `update:modelValue` emit.
- Named model (`defineModel('title')`) shown correctly.
- TypeScript generic parameter (`defineModel<string>`) correct.
- Matches official Vue docs at vuejs.org/guide/components/v-model.html.

### defineProps with Destructure (3.5+) — Verified ✅

- Correctly notes destructured props with defaults as Vue 3.5+ feature that stays reactive.
- `withDefaults` pattern is correctly shown for earlier versions.

### Vue 3.5 Features — Verified ✅

- `onWatcherCleanup` correctly labeled as 3.5+.
- `useTemplateRef` correctly labeled as Vue 3.5+.
- `useId()` mentioned in troubleshooting reference for SSR-safe IDs — correct.

### Pinia API — Verified ✅

- Setup store syntax with `defineStore('id', () => {...})` — correct.
- Options store syntax — correct.
- `storeToRefs` usage and critical warning about destructuring — accurate.
- `$reset` not available on setup stores — correctly documented with manual implementation.

### VueUse Composables — Verified ✅

- `useStorage`, `useFetch`, `useEventListener`, `useDark`, `useToggle` — all from `@vueuse/core`, APIs match current VueUse docs.
- SSR safety note ("Guard browser APIs with `onMounted` or `isClient`") — accurate.

### Supporting Files Quality

| File | Quality | Notes |
|---|---|---|
| `references/advanced-patterns.md` | ⭐⭐⭐⭐⭐ | Renderless components, headless UI, state machines, effectScope, DI patterns |
| `references/troubleshooting.md` | ⭐⭐⭐⭐⭐ | Symptom → cause → fix format; covers reactivity, watchers, SSR, Pinia, TS generics |
| `references/testing-guide.md` | ⭐⭐⭐⭐⭐ | Vitest + @vue/test-utils setup, composable testing, Pinia mocking |
| `scripts/init-vue-project.sh` | ⭐⭐⭐⭐⭐ | Full scaffold with Vite + TS + Pinia + VueUse + Router + Vitest |
| `scripts/generate-composable.sh` | ⭐⭐⭐⭐⭐ | Generates composable + test + barrel export |
| `scripts/migrate-options-to-composition.sh` | ⭐⭐⭐⭐⭐ | Analyzes Options API SFC and generates migration template |
| `assets/composable-template.ts` | ⭐⭐⭐⭐⭐ | SSR-safe, AbortController, debounce, MaybeRefOrGetter, generics |
| `assets/pinia-store-template.ts` | ⭐⭐⭐⭐⭐ | Setup store with optimistic updates, $reset, HMR, persistence config |
| `assets/form-composable.ts` | ⭐⭐⭐⭐⭐ | Full form handling with validation rules, dirty/touched tracking |
| `assets/fetch-composable.ts` | ⭐⭐⭐⭐⭐ | Caching, retry with backoff, pagination, AbortController |
| `assets/vitest-setup.ts` | ⭐⭐⭐⭐⭐ | Browser API mocks, mountWithPinia, mountAsync, withSetup, mockFetch |

**Content verdict: PASS** — All APIs verified against current official docs and community resources.

---

## C. Trigger Check

| Query | Should Trigger? | Would Trigger? | Result |
|---|---|---|---|
| "How do I use ref and reactive in Vue 3?" | ✅ Yes | ✅ Yes | ✅ |
| "Create a Vue composable for fetching data" | ✅ Yes | ✅ Yes | ✅ |
| "Use defineModel for v-model in Vue 3.4" | ✅ Yes | ✅ Yes | ✅ |
| "Set up a Pinia store with Composition API" | ✅ Yes | ✅ Yes | ✅ |
| "Migrate Vue Options API to Composition API" | ✅ Yes | ✅ Yes | ✅ |
| "Vue Options API data/methods/computed" | ❌ No | ❌ No | ✅ |
| "React useState and useEffect hooks" | ❌ No | ❌ No | ✅ |
| "Svelte reactive statements" | ❌ No | ❌ No | ✅ |
| "Nuxt server routes and API handlers" | ❌ No | ❌ No | ✅ |
| "Vue 2 mixins and filters" | ❌ No | ❌ No | ✅ |

**Trigger verdict: PASS** — Clean separation between Composition API (positive) and Options-only/non-Vue (negative).

---

## D. Scores

| Dimension | Score | Justification |
|---|---|---|
| **Accuracy** | 5/5 | All APIs verified against Vue 3.4/3.5 official docs, Pinia docs, VueUse docs. Version attributions (3.3+, 3.4+, 3.5+) are correct. No factual errors found. |
| **Completeness** | 5/5 | Covers reactivity, lifecycle, composables, props/emits/model, provide/inject, template refs, slots, Pinia, VueUse, TypeScript, async/Suspense, performance, testing, migration, gotchas. Three reference docs, three scripts, five asset templates. |
| **Actionability** | 5/5 | Every section has copy-paste code. Scripts are executable. Assets are production-ready templates. Gotchas section prevents common bugs. Migration table gives clear 1:1 mappings. |
| **Trigger quality** | 4/5 | Strong positive and negative triggers. Minor gap: could explicitly exclude "Nuxt middleware/plugins" and "Vue Router guards" as separate concerns, though current negative list is adequate. |

**Overall: 4.75 / 5.0**

---

## Verdict

**PASS** — Overall ≥ 4.0, no dimension ≤ 2. No GitHub issues required.

### Minor Suggestions (non-blocking)

1. **Line count headroom**: At 489/500 lines, the body is nearly at the limit. If adding content, consider moving a section to references/.
2. **Debug hooks**: Could add a one-line mention of `onRenderTracked`/`onRenderTriggered` in the lifecycle section for completeness.
3. **Trigger refinement**: Adding "Nuxt page components" as a positive trigger and "Vue Router navigation guards" as a negative trigger would improve precision.
