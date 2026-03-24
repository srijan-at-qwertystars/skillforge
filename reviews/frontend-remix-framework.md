# Review: remix-framework

Accuracy: 4/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 4/5
Overall: 4.5/5

Issues:

1. **Vercel deployment config is incorrect (Accuracy):**
   The Vercel section (line ~377) places `vercelPreset()` inside `reactRouter({ presets: [...] })` in `vite.config.ts`. Per Vercel's own docs, presets belong in `react-router.config.ts`, not in the Vite plugin call:
   ```ts
   // react-router.config.ts
   import { vercelPreset } from "@vercel/react-router/vite";
   import type { Config } from "@react-router/dev/config";
   export default { presets: [vercelPreset()] } satisfies Config;
   ```
   Engineers following the current SKILL.md will get a build error or misconfiguration.

2. **Bridge pattern re-exports removed `json` (Accuracy, minor):**
   `references/advanced-patterns.md` line ~728 re-exports `json` from `"react-router"` in the compatibility shim. `json()` is removed in React Router v7 (the SKILL.md itself says this). This would cause an import error during migration.

3. **Missing gotcha: `reactRouter()` replaces `@vitejs/plugin-react` (Completeness, minor):**
   The skill doesn't mention that `reactRouter()` should *replace* the standard `@vitejs/plugin-react` plugin, not be used alongside it. This is a common mistake for engineers migrating from a plain Vite+React setup.

4. **Missing gotcha: tsconfig `rootDirs` for typegen (Completeness, minor):**
   `react-router typegen` places types in `.react-router/types/`. The tsconfig must include `rootDirs` configuration for TypeScript to resolve `./+types/*` imports. Not documented in SKILL.md or troubleshooting.

5. **Trigger gap: React Router library mode (Trigger quality, minor):**
   Negative triggers don't exclude "React Router library mode" (SPA without framework mode). A query like "set up React Router v7 for client-side routing" could trigger this skill, which would over-serve with SSR/loader/action guidance. Consider adding "React Router v7 library/SPA mode without SSR" to the negative trigger list.

## Structure Assessment

- YAML frontmatter: ✅ Has `name` and `description`
- Positive + negative triggers: ✅ Both present and comprehensive
- Body length: ✅ 442 lines (under 500 limit)
- Voice: ✅ Imperative, no filler
- Examples: ✅ Extensive input/output code examples throughout
- References linked: ✅ All 3 reference files, 2 scripts, 3 assets properly linked

## Content Verification (Web Search)

- `npx create-react-router@latest` CLI command: ✅ Verified correct
- `@react-router/dev/vite` import + `reactRouter()` plugin: ✅ Verified correct
- `@react-router/fs-routes` + `flatRoutes()`: ✅ Verified correct
- `react-router typegen` + `Route.LoaderArgs` / `Route.ComponentProps`: ✅ Verified correct
- `npx codemod remix/2/react-router/upgrade`: ✅ Verified correct
- Remix v2 → RR7 dependency mapping: ✅ Verified correct
- Vercel preset location: ❌ Should be in react-router.config.ts, not vite.config.ts

## Verdict

High-quality skill with comprehensive coverage of Remix/React Router v7. The Vercel config error is the only issue likely to block engineers. All other content is accurate, well-structured, and immediately actionable. References and scripts are thorough. An AI could execute most Remix tasks from this skill alone.

**Status: PASS** (with minor fixes recommended)
