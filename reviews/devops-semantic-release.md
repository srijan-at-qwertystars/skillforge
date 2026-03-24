# QA Review: devops/semantic-release

**Reviewer:** Automated QA  
**Date:** 2025-07-17  
**Skill path:** `~/skillforge/devops/semantic-release/`

---

## A. Structure Check

### YAML Frontmatter
- ✅ `name: semantic-release` — present
- ✅ `description` — present, multi-line, includes positive AND negative triggers

### Description Quality
- ✅ **Positive triggers:** "setting up semantic-release, automated versioning, semantic versioning automation, changelog generation, npm publish automation, release automation, conventional commits release, configuring .releaserc, multi-branch releases, release plugins, CI/CD release pipelines"
- ✅ **Negative triggers:** "manual versioning, changesets, release-please, standard-version, lerna publish without semantic-release, conventional-changelog-cli standalone, manual npm publish workflows, or non-semantic-release tools"

### Line Count
- ✅ SKILL.md: **489 lines** (under 500 limit)

### Writing Quality
- ✅ Imperative voice throughout — no filler, no hedging, no "you might want to consider"
- ✅ Terse, scannable format with tables, code blocks, and clear headers

### Examples
- ✅ Three concrete input/output examples at bottom of SKILL.md (basic npm, library no-publish, Docker exec)
- ✅ Each example shows config input and describes the resulting behavior

### References and Scripts Linked
- ✅ `references/` section with relative links: `references/advanced-patterns.md`, `references/troubleshooting.md`, `references/plugin-ecosystem.md`
- ✅ `scripts/` section with table: `scripts/setup-project.sh`, `scripts/validate-commits.sh`, `scripts/dry-run.sh`
- ✅ `assets/` section with table: `assets/.releaserc.json`, `assets/github-actions.yml`, `assets/commitlint.config.js`

---

## B. Content Check

### Accuracy Verification

| Claim | Verdict | Notes |
|---|---|---|
| Plugin package names (`@semantic-release/commit-analyzer`, etc.) | ✅ Correct | All 8 official plugins correctly named |
| Config file search order | ⚠️ Minor inaccuracy | SKILL.md lists `.releaserc` first; actual cosmiconfig order starts with `package.json` `release` key, then `.releaserc*`, then `release.config.*`. The stated order is close but not precisely correct — cosmiconfig searches in a different sequence. Impact: low, since only first-found matters. |
| CLI flags (`--dry-run`, `--no-ci`) | ✅ Correct | Both are valid, documented flags |
| `--print-config` referenced in troubleshooting.md line 617 | ❌ **Error** | `--print-config` does not exist as a semantic-release CLI flag. The troubleshooting file uses it in a command: `npx semantic-release --print-config 2>/dev/null`. This will fail silently (piped to /dev/null) so it won't break anything, but it's misleading. |
| `${npm.name}` in assets/.releaserc.json successComment | ❌ **Error** | `${npm.name}` is not a valid template variable in `@semantic-release/github` successComment. Only `nextRelease`, `lastRelease`, `branch`, `commits`, and `issue` context objects are available. The template on line 51 of assets/.releaserc.json will render `npm.name` as empty/undefined. |
| `fetch-depth: 0` requirement | ✅ Correct | Properly emphasized as critical |
| Plugin execution order matters | ✅ Correct | Correctly documents that `@semantic-release/git` must be last |
| `releaseRules` override defaults entirely | ✅ Correct | Important gotcha, correctly documented |
| multi-semantic-release & semantic-release-monorepo | ⚠️ Missing caveat | Both packages have maintenance concerns. `multi-semantic-release` self-describes as "proof of concept" not for production. `semantic-release-monorepo` hasn't had major updates since 2022. SKILL.md recommends `multi-semantic-release` without this caveat. |
| Conventional Commits preset names | ✅ Correct | `angular` and `conventionalcommits` both valid |
| `@semantic-release/exec` template variables | ✅ Correct | Variables and available-in lifecycle steps are accurate |
| `persist-credentials: false` in GH Actions | ✅ Correct | Properly documented for avoiding infinite loops |

### Missing Gotchas

1. **`npm.name` template variable** — The assets/.releaserc.json uses `${npm.name}` in successComment which won't resolve. Engineers copying this template will get broken comments.
2. **Node.js version requirement** — semantic-release requires Node.js >= 18.x (since v21). The setup script checks this but SKILL.md body doesn't mention the minimum version.
3. **Monorepo tool stability** — No warning about multi-semantic-release being "proof of concept" or semantic-release-monorepo being unmaintained.
4. **`--print-config` non-existence** — Referenced in troubleshooting but doesn't exist.
5. **pnpm/yarn support** — SKILL.md is npm-centric. No mention of `pnpm` or `yarn` equivalents for install/CI commands.

### Example Correctness
- ✅ Minimal `.releaserc.json` — correct and runnable
- ✅ Full `release.config.js` — correct syntax, valid plugin configs
- ✅ GitHub Actions workflow — correct, includes all critical settings
- ✅ GitLab CI config — correct structure
- ⚠️ Assets `.releaserc.json` — has the `${npm.name}` issue noted above
- ✅ Scripts — all three scripts are well-structured, have proper shebang lines, `set -euo pipefail`, arg parsing, and help text

### Would an AI Execute Perfectly?
**Mostly yes.** The SKILL.md provides enough detail for an AI to configure semantic-release end-to-end for standard use cases. The two errors (`${npm.name}` and `--print-config`) would cause minor issues but not block a release setup. The monorepo section would lead to recommending a potentially unstable tool without disclaimer. Overall, 90%+ of tasks would be executed correctly.

---

## C. Trigger Check

### Would it trigger for semantic-release queries?
✅ **Yes — strong trigger coverage.** Keywords include: "semantic-release", "automated versioning", "semantic versioning automation", "changelog generation", "npm publish automation", "release automation", "conventional commits release", ".releaserc", "multi-branch releases", "release plugins", "CI/CD release pipelines". This covers the vast majority of how engineers phrase semantic-release questions.

### False trigger risk for competing tools?

| Query | Would trigger? | Correct? |
|---|---|---|
| "Set up changesets for my monorepo" | ❌ No | ✅ Correct — excluded in negative triggers |
| "Configure release-please" | ❌ No | ✅ Correct — excluded in negative triggers |
| "Automate npm publishing" | ✅ Yes | ⚠️ Ambiguous — could be non-semantic-release. Acceptable risk since most automated npm publish queries relate to semantic-release. |
| "Set up standard-version" | ❌ No | ✅ Correct — excluded |
| "lerna publish setup" | ❌ No | ✅ Correct — excluded (unless with semantic-release) |
| "Generate changelog automatically" | ✅ Yes | ⚠️ Could be conventional-changelog-cli standalone, but acceptable overlap |

**Verdict:** Negative triggers are well-crafted. False positive risk is minimal. The exclusion list covers the main competing tools (changesets, release-please, standard-version, lerna, conventional-changelog-cli).

---

## D. Scores

| Dimension | Score | Rationale |
|---|---|---|
| **Accuracy** | 4 | Two factual errors (`${npm.name}` template var, `--print-config` flag) and config search order imprecision. All other plugin names, options, CLI flags, and patterns verified correct. |
| **Completeness** | 5 | Exceptional coverage: installation, configuration, commit format, plugin system (all 9 lifecycle steps), multi-branch, monorepo (3 approaches), CI/CD (GitHub + GitLab), private registries, custom plugins, dry-run, debugging, troubleshooting. Three reference docs, three scripts, three asset templates. |
| **Actionability** | 4 | Copy-paste examples throughout. Scripts are production-ready with arg parsing and error handling. Assets are copy-ready. Minor ding for the broken `${npm.name}` template that would cause confusion if copied as-is. |
| **Trigger Quality** | 5 | Comprehensive positive triggers covering all common phrasings. Explicit negative triggers for competing tools. No significant false-trigger risk. |

**Overall: 4.5 / 5.0**

---

## E. Issues

No GitHub issues required — overall score (4.5) is ≥ 4.0 and no individual dimension is ≤ 2.

### Recommended Fixes (non-blocking)

1. **Fix `${npm.name}` in `assets/.releaserc.json`** — Replace with hardcoded package name placeholder or remove from the template. The `@semantic-release/github` successComment only has access to `nextRelease`, `lastRelease`, `branch`, `commits`, and `issue` context variables.

2. **Fix `--print-config` in `references/troubleshooting.md`** — Remove or replace with `cat .releaserc* 2>/dev/null` (which is already the fallback in the same line).

3. **Add monorepo stability caveat** — Note that `multi-semantic-release` is self-described as "proof of concept" and `semantic-release-monorepo` is unmaintained since 2022.

4. **Clarify config search order** — Update to reflect cosmiconfig's actual order: `package.json` → `.releaserc` → `.releaserc.json` → `.releaserc.yml` → `.releaserc.js` → `.releaserc.cjs` → `.releaserc.mjs` → `release.config.js` → `release.config.cjs` → `release.config.mjs`.

5. **Add Node.js minimum version** — Mention Node.js >= 18 requirement in the Installation section.

---

## F. Verdict

**PASS** — High-quality skill with comprehensive coverage and strong trigger design. Two minor factual errors should be fixed but do not materially impact the skill's ability to guide correct semantic-release configuration.

---

*Review generated: 2025-07-17*
