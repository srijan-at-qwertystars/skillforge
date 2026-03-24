# QA Review: nextjs-app-router

**Skill path:** `~/skillforge/frameworks/nextjs-app-router/`
**Reviewed:** 2025-07-28
**Reviewer:** Copilot CLI (automated)

---

## A. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter — `name` | ✅ Pass | `nextjs-app-router` |
| YAML frontmatter — `description` with positive triggers | ✅ Pass | Lists 20+ positive signals (app/ dir, next/navigation, "use client", route.ts, etc.) |
| YAML frontmatter — `description` with negative triggers | ✅ Pass | Explicitly excludes Pages Router, Remix, SvelteKit, Astro, Nuxt, plain React, Vite |
| Body under 500 lines | ✅ Pass | Exactly 500 lines (tight fit) |
| Imperative voice | ✅ Pass | Consistently uses imperative ("Use", "Add", "Move", "Keep", "Validate") |
| Examples with input/output | ✅ Pass | Code examples throughout with filenames, comments, and expected behavior |
| References linked from SKILL.md | ✅ Pass | 3 references linked: advanced-patterns.md, troubleshooting.md, deployment-guide.md |
| Scripts linked from SKILL.md | ✅ Pass | 3 scripts linked: nextjs-init.sh, route-generator.sh, component-generator.sh |
| Assets linked from SKILL.md | ✅ Pass | 5 assets linked: next.config.ts, middleware.ts, Dockerfile, docker-compose.yml, server-action-template.ts |

**Structure verdict:** All structural checks pass.

---

## B. Content Check — Fact Verification

### Verified Claims (via web search against official docs and community sources)

| Claim | Verdict | Detail |
|-------|---------|--------|
| Fetch not cached by default in v15 | ✅ Correct | v15 changed default from `force-cache` to `no-store`. Skill states this accurately. |
| `params` and `searchParams` are `Promise`-based in v15 | ✅ Correct | Breaking change confirmed. Skill shows correct `Promise<{ slug: string }>` typing and `await params`. |
| Server Components are default, Client Components need `"use client"` | ✅ Correct | Standard App Router behavior. |
| Server Actions use `"use server"` directive | ✅ Correct | Both file-level and function-level usage shown correctly. |
| Middleware runs on Edge Runtime | ✅ Correct | Confirmed: defaults to Edge, subset of Web APIs, no Node.js fs/db. |
| `route.ts` cannot coexist with `page.tsx` | ✅ Correct | Documented Next.js constraint. |
| Request Memoization auto-deduplicates same-URL fetches | ✅ Correct | Per-render dedup confirmed, not persistent caching. |
| Data Cache OFF by default in v15 | ✅ Correct | Must opt in with `force-cache` or `revalidate`. |
| `generateMetadata` uses async `params` in v15 | ✅ Correct | Example correctly shows `Promise<{ slug: string }>` and `await params`. |

### Inaccuracies Found

| Issue | Severity | Detail |
|-------|----------|--------|
| **Router Cache defaults wrong** | 🟡 Medium | SKILL.md line 332 states Router Cache is "30s dynamic, 5min static". In Next.js 15, dynamic routes changed to **0 seconds** (not cached by default). Static remains 5 minutes. The "30s dynamic" figure is the Next.js 14 default. |

### Missing Content (Gotchas)

| Gap | Severity | Detail |
|-----|----------|--------|
| **`"use cache"` directive not mentioned** | 🟡 Low-Medium | Next.js 15 introduced the `"use cache"` directive as the new explicit opt-in caching mechanism (replacing implicit fetch caching). It's still experimental/canary but is the direction of the framework. Worth a brief mention. |
| **`cookies()` and `headers()` are also async in v15** | 🟡 Low-Medium | The skill correctly notes `params`/`searchParams` are async but doesn't mention that `cookies()`, `headers()`, and `draftMode()` from `next/headers` are also now async Promises in v15. |
| **`useActionState` not mentioned** | 🟢 Low | `useActionState` (React 19) replaces `useFormState` for Server Action form handling. The skill mentions `useOptimistic` but not this companion hook. |
| **`clsx` imported but not installed in init script** | 🟡 Medium | `scripts/nextjs-init.sh` generates `src/lib/utils.ts` that imports `clsx`, but only installs `zod` and `server-only`. Missing `npm install clsx`. |
| **`staleTimes` experimental config** | 🟢 Low | No mention of `experimental.staleTimes` for controlling Router Cache duration, which is the escape hatch for the new 0s default. |

### Examples Correctness

All code examples reviewed are syntactically correct and follow current Next.js 15 patterns:
- Dynamic route page with async params ✅
- Server Action with Zod validation ✅
- Middleware with matcher config ✅
- generateMetadata with async params ✅
- Parallel routes layout props ✅
- Docker multi-stage build ✅
- Route handler with NextRequest/NextResponse ✅

---

## C. Trigger Check

### Would the description trigger for Next.js App Router queries?

**Yes — strong coverage.** The description includes:
- File/directory signals: `next.config.js/ts`, `app/`, `page.tsx`, `layout.tsx`, `route.ts`, `middleware.ts`, `loading.tsx`, `error.tsx`, `not-found.tsx`
- Import signals: `next/navigation`, `next/image`, `next/link`, `next/font`, `next/headers`, `next/form`
- Directive signals: `"use client"`, Server Components, Server Actions
- API signals: `generateMetadata`, `generateStaticParams`, `revalidatePath`, `revalidateTag`
- Pattern signals: parallel routes `@slot`, intercepting routes, route groups `(group)`, dynamic segments `[slug]`

### Would it falsely trigger for competing frameworks?

**No — explicit exclusions.** The DO NOT TRIGGER list covers:
- ❌ Remix
- ❌ SvelteKit
- ❌ Astro
- ❌ Nuxt
- ❌ Plain React (no Next.js)
- ❌ Vite-only React
- ❌ Next.js Pages Router (`pages/`, `getServerSideProps`, `getStaticProps`, `_app.tsx`, `_document.tsx`)

**Edge case consideration:** A project using both Pages Router and App Router could correctly trigger this skill since `app/` directory presence is a positive signal.

---

## D. Scoring

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 4 / 5 | Router Cache table has incorrect v15 default (30s → should be 0s). Init script has clsx dependency bug. All other claims verified correct. |
| **Completeness** | 4 / 5 | Excellent coverage of core APIs. Missing `"use cache"` directive, async `cookies()`/`headers()`, `useActionState`. Reference files are substantial (3000+ lines total). |
| **Actionability** | 5 / 5 | Outstanding. Production-ready Dockerfile, docker-compose, middleware template, server action template. Three shell scripts for scaffolding. 10 common pitfalls listed. Troubleshooting guide covers real-world issues. |
| **Trigger quality** | 5 / 5 | Comprehensive positive signals (20+), explicit negative exclusions for 6 competing frameworks + Pages Router. No realistic false-trigger scenarios. |
| **Overall** | **4.5** | High-quality skill with minor factual inaccuracy in caching table and a few completeness gaps around newer v15 APIs. |

---

## E. Issue Filing

**Overall score (4.5) ≥ 4.0 and no dimension ≤ 2 → No GitHub issues required.**

### Recommended fixes (non-blocking):

1. **Fix Router Cache table (line 332):** Change "30s dynamic" → "0s dynamic (not cached)" to reflect Next.js 15 behavior.
2. **Fix init script clsx dependency:** Add `clsx` to the `npm install --save` command in `scripts/nextjs-init.sh`, or remove the import from the generated `utils.ts`.
3. **Add note about async `cookies()`/`headers()`** near the `params`/`searchParams` async breaking change section.
4. **Consider adding a brief `"use cache"` section** in the caching architecture table or as a note about the experimental direction.

---

## F. Test Status

**Status: PASS** ✅

The skill is accurate, comprehensive, and actionable. The identified issues are minor (one table cell, one missing dependency) and do not impair the skill's overall utility. The structural requirements are fully met.
