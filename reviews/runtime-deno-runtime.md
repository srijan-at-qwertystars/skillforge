# Review: deno-runtime

Accuracy: 4/5
Completeness: 4/5
Actionability: 4/5
Trigger quality: 5/5
Overall: 4.2/5

Issues:

1. **Deprecated `@std/flags` import (Accuracy)** — Line 330 of SKILL.md references
   `import { parse as parseFlags } from "jsr:@std/flags"` but `@std/flags` is deprecated
   in Deno 2.x. The correct replacement is `import { parseArgs } from "jsr:@std/cli/parse-args"`.
   Note: the CLI scaffold script correctly uses `@std/cli`, so this is only a SKILL.md body issue.

2. **Fresh 1.x vs Fresh 2.x API mismatch (Accuracy)** — The Fresh section in SKILL.md
   (lines 278–306) uses Fresh 1.x patterns (`$fresh/server.ts`, `Handlers` type, `deno run -A
   jsr:@fresh/init`). Fresh 2.x is the current version with a different API (`jsr:@fresh/core`,
   middleware-centric `App()` class, Vite integration). The `assets/fresh-app-template/` correctly
   uses Fresh 2.x, but the SKILL.md body and `scripts/scaffold-deno-project.sh` use Fresh 1.x
   patterns. An AI following the SKILL.md body would produce outdated Fresh code.

3. **KV consistency claim slightly misleading (Accuracy)** — Line 275 states "KV is globally
   distributed with strong consistency." On Deno Deploy, KV reads default to *eventual*
   consistency for performance; you must explicitly request `{ consistency: "strong" }`. The
   troubleshooting doc correctly covers this, but the main body gives a false impression of
   default strong consistency.

4. **`Deno.listen()` not truly deprecated (Accuracy, minor)** — Line 429 says "Use
   `Deno.serve()` not deprecated `Deno.listen()` for HTTP." `Deno.listen()` is not deprecated;
   it remains valid for raw TCP/UDP. The advice to prefer `Deno.serve()` for HTTP is correct,
   but the word "deprecated" is inaccurate.

5. **Missing `deno publish` workflow (Completeness)** — No mention of `deno publish` for
   publishing to JSR, which is a key Deno 2.x workflow for library authors. The library scaffold
   includes `publish.include` config but no publish task or guidance in SKILL.md.

6. **No Fresh 2.x coverage in main body (Completeness)** — Fresh 2.x brings significant
   changes (Vite integration, middleware-centric app structure, no `fresh.gen.ts`). The main
   SKILL.md body should be updated to reflect the current Fresh API.

## Structure Check Summary

- ✅ YAML frontmatter has `name` and `description`
- ✅ Description has positive triggers (Deno, Fresh, KV, Deploy) and negative triggers (NOT Node.js, NOT Bun, NOT browser JS, NOT frontend)
- ✅ Body is 483 lines (under 500)
- ✅ Imperative voice, no filler
- ✅ Examples with input/output throughout
- ✅ `references/` and `scripts/` properly linked from SKILL.md with descriptions

## Trigger Check Summary

- ✅ Description covers comprehensive trigger terms: "Deno runtime", "Deno 2", "Deno Deploy", "Fresh framework", "Deno KV", "secure JavaScript/TypeScript runtime"
- ✅ Negative triggers are clear and appropriate
- ✅ Would not falsely trigger for Node.js, Bun, or browser-only tasks
- ✅ Would correctly trigger for Deno-related queries

## Verdict: PASS
