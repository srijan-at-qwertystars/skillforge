# Review: remix-framework

Accuracy: 3/5
Completeness: 4/5
Actionability: 4/5
Trigger quality: 4/5
Overall: 3.8/5

## Structure Check

- ✅ YAML frontmatter has `name` and `description`
- ✅ Description includes positive triggers (Remix, React Router v7, loaders, etc.) AND negative triggers (plain React Router library-mode, Next.js, Gatsby, Astro, generic SPA)
- ✅ Body is 494 lines (under 500 limit)
- ✅ Imperative voice, no filler
- ✅ Extensive code examples with input/output throughout
- ✅ references/, scripts/, and assets/ properly linked from SKILL.md with descriptions

## Content Check — Verified Claims

### Correct
- `npx create-react-router@latest` for new projects ✅
- `reactRouter()` from `@react-router/dev/vite` for Vite plugin ✅
- `react-router.config.ts` with `Config` type from `@react-router/dev/config` ✅
- `flatRoutes()` from `@react-router/fs-routes` ✅ (separate package, correctly documented)
- `loaderData` as component prop via `Route.ComponentProps` ✅
- `json()` and `defer()` removed in v7 — return plain objects ✅
- Streaming via un-awaited promises + `<Await>` + `<Suspense>` ✅
- `npx codemod remix/2/react-router/upgrade` migration codemod ✅
- Deployment adapters: `@react-router/node`, `@react-router/serve`, `@react-router/cloudflare` ✅
- Vercel preset: `import { vercelPreset } from "@vercel/react-router/vite"` ✅
- Cloudflare: `npm create cloudflare@latest -- my-app --framework=react-router` ✅
- `createRoutesStub` for testing ✅
- `react-router typegen` for type generation ✅
- Package mapping table in migration guide is largely correct ✅

### Incorrect

1. **Meta merging claim is wrong** (SKILL.md line 270): States "meta merges with parent route meta by default in v2+". This is false. In v2+, each route's `meta` function **replaces** parent meta entirely. To include parent meta, you must explicitly spread it using the `matches` argument. This will mislead engineers into expecting automatic inheritance.

2. **File upload imports use non-existent packages** (references/advanced-patterns.md lines 386-387): Uses `@remix-run/form-data-parser` and `@remix-run/file-storage/local`. These packages do not exist. The correct package for file upload parsing in React Router v7 is `@mjackson/form-data-parser` (by the same author, Michael Jackson). An AI executing this code would get `npm install` failures.

### Minor Observations
- Package mapping shows `@remix-run/node` → `react-router` (unified). This is correct for most APIs (redirect, json replacement, etc.) but runtime-specific features like filesystem session storage live in `@react-router/node`. The table could note this nuance.
- Vite plugin ordering: troubleshooting.md says `reactRouter()` must come first, but vite.config.ts asset and setup-project.sh put `tailwindcss()` before it. Both orderings work, but the contradiction may confuse.

## Trigger Check

| Query | Triggers? | Correct? |
|-------|-----------|----------|
| "build Remix app" | ✅ Yes | ✅ |
| "React Router v7 framework" | ✅ Yes | ✅ |
| "full-stack React" | ⚠️ Unlikely | Acceptable — too broad a query |
| "Next.js app" | ❌ No | ✅ Correctly excluded |
| "plain React SPA" | ❌ No | ✅ Correctly excluded |
| "Gatsby site" | ❌ No | ✅ Correctly excluded |
| "React Router library mode" | ❌ No | ✅ Correctly excluded |

## Issues Filed

1. `QA: web/remix-framework — meta merging claim is incorrect`
2. `QA: web/remix-framework — file upload imports use non-existent packages`
