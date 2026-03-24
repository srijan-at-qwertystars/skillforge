# Review: turborepo-monorepo

Accuracy: 5/5
Completeness: 4/5
Actionability: 5/5
Trigger quality: 5/5
Overall: 4.8/5
Issues: [minor gaps listed below]

---

## a. Structure Check — ✅ PASS

| Criterion | Status | Notes |
|---|---|---|
| YAML frontmatter (name+description) | ✅ | `name: turborepo-monorepo`, multi-line description present |
| Positive triggers | ✅ | 10 specific keywords: Turborepo, turbo.json, turbo run, turbo prune, remote caching, task pipeline, workspace dependencies, topological ordering, internal packages pattern, monorepo build orchestration |
| Negative triggers | ✅ | 7 exclusions: Nx, Lerna, Bazel, Rush, Moon, single-package repos, non-Turborepo tooling |
| Under 500 lines | ✅ | SKILL.md is 498 lines (just under limit) |
| Imperative voice | ✅ | Consistent imperative throughout ("Create", "Place", "Use", "Configure") |
| Examples | ✅ | 25+ code blocks with bash, JSON, YAML, Dockerfile, and TypeScript examples |
| Links to references/scripts/assets | ✅ | All 3 reference docs, 3 scripts, and 3 assets linked in tables at bottom |

## b. Content Check — Verified via Web Search

### Confirmed Correct
- **`tasks` vs `pipeline` (v2 migration):** Accurately documents that v2 renamed `pipeline` to `tasks`. Codemod commands verified (`npx @turbo/codemod migrate-to-turbo-v2`).
- **`turbo prune --docker` output structure:** `json/`, `full/`, pruned lockfile layout confirmed against official docs (turborepo.dev/docs/reference/prune).
- **`--filter` syntax:** All 6 filter patterns in the table verified (`pkg`, `pkg...`, `...pkg`, `./path`, `[ref]`, `...[ref1...ref2]`). Negation with `!` also correct.
- **`dependsOn` with `^` prefix:** Topological vs same-package semantics accurately described.
- **Environment variable handling:** `env`, `passThroughEnv`, `globalEnv`, `globalPassThroughEnv`, wildcard support (`NEXT_PUBLIC_*`) — all verified correct.
- **`persistent: true` + `cache: false`** for dev tasks — confirmed correct behavior.
- **Package-level `turbo.json` with `"extends": ["//"]`** — verified correct syntax.
- **Remote caching:** `turbo login`/`turbo link`, `TURBO_TOKEN`/`TURBO_TEAM` env vars — correct.
- **CLI flags:** `--summarize`, `--dry=json`, `--graph`, `--force`, `--concurrency` — all verified.
- **`turbo gen workspace`** generators with Plop-based custom generators — correct.
- **Changesets integration** — correct workflow and config.
- **Docker multi-stage with prune** — best-practice pattern confirmed.
- **Framework-specific output patterns** (Next.js, Vite, Remix, etc.) — accurate.

### Anti-Patterns Table
All 10 anti-patterns are valid and accurately described. Particularly valuable entries:
- `fetch-depth: 1` in CI breaking git-based `--filter`
- `persistent: true` task as dependency causing deadlocks
- Missing `outputs` causing cache restore failures

### Missing Content (minor)
1. **`turbo watch` command** — A significant v2 feature for dependency-aware file watching during development. Not mentioned in SKILL.md or any reference doc.
2. **`--affected` flag** — Shortcut equivalent to `--filter=...[main...HEAD]`, added in recent versions.
3. **Terminal UI (TUI)** — v2's interactive task monitoring UI (`"ui": "tui"` in turbo.json). Not mentioned.
4. **`turbo.jsonc` support** — Ability to use JSON-with-comments format.
5. **`--out-dir` option** for `turbo prune` — Allows custom output directory.
6. **`futureFlags`** configuration — Controls experimental/forward-looking behaviors.
7. **Filter `^` modifier** for excluding the package itself (`--filter=...^pkg`) — not in the filter table.

None of these are critical gaps; the skill covers all core workflows thoroughly.

## c. Trigger Check — ✅ PASS

### Would Correctly Trigger For:
- "How do I configure turbo.json?"
- "Set up Turborepo monorepo"
- "turbo run build filter"
- "turbo prune Docker deployment"
- "remote caching Vercel Turborepo"
- "workspace dependencies topological ordering"
- "internal packages pattern monorepo"
- "monorepo task pipeline configuration"

### Would Correctly NOT Trigger For:
- "How to set up Nx monorepo" — explicitly excluded
- "Lerna workspace management" — explicitly excluded
- "Bazel build rules" — explicitly excluded
- "Rush monorepo configuration" — explicitly excluded
- "Moon build system" — explicitly excluded
- "Single-package npm project" — explicitly excluded

### False Trigger Risk: LOW
The term "monorepo build orchestration" is somewhat generic, but the combination of all 7 negative triggers effectively prevents false positives for competing tools. The description is well-balanced between recall (positive triggers) and precision (negative triggers).

## d. Detailed Scoring

### Accuracy: 5/5
Every command, config option, flag, and code example verified against current Turborepo v2 documentation and web search results. Zero factual errors found. The v1→v2 migration table is accurate. Filter syntax matches official docs exactly.

### Completeness: 4/5
Excellent coverage of core features: config, caching, filtering, Docker, CI/CD, internal packages, environment variables, generators, changesets, troubleshooting. Three deep-dive reference docs and three helper scripts provide comprehensive supplementary material. Deducted 1 point for missing `turbo watch`, `--affected`, and TUI — all significant v2 features that users will ask about.

### Actionability: 5/5
Outstanding copy-paste usability. The skill provides:
- Working `turbo.json` configs (both inline and as asset template)
- Complete multi-stage Dockerfile
- Production-grade GitHub Actions workflow
- Three functional shell scripts (init, add-package, analyze-cache)
- Shared config patterns (ESLint, TypeScript, Prettier)
- Anti-patterns table with immediate fixes
- Quick reference command cheat sheet

### Trigger Quality: 5/5
10 positive triggers covering both specific terms (`turbo.json`, `turbo prune`) and conceptual queries (`monorepo build orchestration`, `topological ordering`). 7 negative triggers explicitly excluding all major competing tools. Near-zero false trigger risk.

## e. GitHub Issues

No issues filed. Overall score (4.8) ≥ 4.0 and no dimension ≤ 2.

## f. SKILL.md Tag

Appended `<!-- tested: pass -->` to SKILL.md.

---

*Reviewed: 2026-03-24T21:40:08Z*
*Reviewer: automated QA*
