# Review: ruff-linting

**Reviewed:** SKILL.md (492 lines), 3 references, 3 scripts, 3 assets (3,890 total lines)

## Scores

Accuracy: 4/5
Completeness: 4/5
Actionability: 5/5
Trigger quality: 5/5
Overall: 4.5/5

## a. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter (name + description) | ✅ Pass | `name: ruff-linting`, multi-line description present |
| Positive triggers | ✅ Pass | 8 listed: "Ruff linter", "ruff check", "ruff format", "Python linting with Ruff", etc. |
| Negative triggers | ✅ Pass | 5 listed: "flake8 without Ruff", "pylint config", "mypy type checking", "black formatter without Ruff", "ESLint JavaScript" |
| Under 500 lines | ✅ Pass | SKILL.md = 492 lines (just under limit) |
| Imperative voice | ✅ Pass | Commands and instructions use imperative throughout |
| Examples | ✅ Pass | 4 before/after code examples, CLI examples throughout |
| Links to references/scripts | ✅ Pass | Explicit tables linking to all 3 references, 3 scripts, 3 assets |

## b. Content Check

### Verified correct (via web search + official docs)

- **Core commands:** `ruff check`, `ruff format`, `ruff rule <CODE>`, `ruff linter`, `ruff clean` — all valid current CLI subcommands ✅
- **Rule codes:** All 28 prefix codes in the rule table (E, W, F, I, N, UP, S, B, A, C4, D, SIM, PT, RET, ARG, DTZ, ISC, ICN, PL, PERF, RUF, ANN, FA, TCH, T20, ERA, FBT, PIE, NPY, FURB) verified against official Ruff rules page ✅
- **Config structure:** `[tool.ruff]`, `[tool.ruff.lint]`, `[tool.ruff.format]`, `[tool.ruff.lint.isort]`, `[tool.ruff.lint.per-file-ignores]` — all correct TOML section paths ✅
- **`ruff format` as Black replacement:** ">99.9% identical output" claim matches official docs ✅
- **Formatter conflicts (COM812, ISC001):** Correctly documented as must-ignore when using `ruff format` ✅
- **Output formats:** `text`, `json`, `github`, `gitlab`, `pylint`, `rdjson`, `sarif` all confirmed; advanced-config.md also adds `grouped`, `azure`, `concise`, `full` ✅
- **`--fix` vs `--unsafe-fixes` semantics:** Correctly explained (safe = no semantic change, unsafe = review needed) ✅
- **`extend-select` vs `select` semantics:** Correctly explained in advanced-config.md ✅
- **Pre-commit hook order:** Correctly states lint before format ✅
- **GitHub Actions `astral-sh/ruff-action@v3`:** Confirmed as current major version ✅
- **VS Code extension ID:** `charliermarsh.ruff` confirmed correct ✅

### Issues found

1. **ANN101 status outdated (minor):** SKILL.md line 126 and advanced-config.md list ANN101 as "deprecated." It was actually **removed** in Ruff 0.8.0 (not just deprecated). Ignoring a removed rule is harmless but the comment is misleading — users on current Ruff versions will get "unknown rule" warnings if they reference it.

2. **Pinned versions are stale (cosmetic):** Pre-commit config pins `v0.11.12`; current Ruff release is v0.15.7. The skill does annotate "pin to latest release" which mitigates this, but example versions could be refreshed.

3. **Missing `ruff check --watch` mode:** The `--watch` flag for continuous re-checking on file change is not mentioned anywhere in the skill or references. Useful for development workflows.

4. **Missing Jupyter notebook (.ipynb) support:** Ruff has native `.ipynb` linting support. The data-science config in advanced-config.md references `*.ipynb` in per-file-ignores but never explains how to enable/use notebook linting.

5. **Missing newer subcommands in quick reference:** `ruff server` (LSP), `ruff analyze` (import graph), `ruff config` (show effective config) are not covered.

6. **No gotchas/pitfalls section:** Common issues not mentioned:
   - `# noqa` with typo'd rule codes silently fails (no warning)
   - `--fix` can remove imports with side effects (e.g., `import matplotlib; matplotlib.use('Agg')`)
   - `preview = true` rules can change behavior between minor releases
   - `exclude` (without `extend-`) silently drops all built-in defaults

### Content in references, scripts, and assets

- **references/rule-categories.md (696 lines):** Comprehensive per-category breakdowns with top rules, fixability, examples, and selection strategy matrix. Well-structured.
- **references/migration-guide.md (746 lines):** Setting-by-setting mapping tables from 8+ legacy tools. Parity percentages match community consensus. Verification checklist included.
- **references/advanced-config.md (831 lines):** Covers monorepo, Django, FastAPI, pytest, data-science configs. extend vs override semantics clearly explained. Production config template included.
- **scripts/migrate-config.sh (293 lines):** Detects `.flake8`, `setup.cfg`, `pyproject.toml` configs; extracts and generates Ruff TOML. Read-only (doesn't modify files). Solid.
- **scripts/setup-precommit.sh (209 lines):** Creates `.pre-commit-config.yaml`, supports `--dry-run`, `--unsafe-fixes`, backup existing config. Well-designed.
- **scripts/audit-rules.sh (296 lines):** Runs `ruff check --select ALL --statistics`, groups by category, suggests phased adoption. Practical and useful.
- **assets/pyproject.toml (150 lines):** Heavily commented production template. Every rule category explained inline.
- **assets/pre-commit-config.yaml (78 lines):** Includes general file hygiene hooks beyond just Ruff. Optional mypy/detect-secrets commented out.
- **assets/github-actions.yml (99 lines):** Path-filtered triggers, concurrency groups, optional auto-fix job. Production-ready.

## c. Trigger Check

| Query | Should trigger? | Would trigger? | Result |
|-------|----------------|----------------|--------|
| "How do I configure Ruff?" | Yes | Yes — matches "Ruff" + "config" | ✅ |
| "ruff check not working" | Yes | Yes — matches "ruff check" | ✅ |
| "migrate from flake8 to Ruff" | Yes | Yes — explicit positive trigger | ✅ |
| "Ruff rule E501 what does it do" | Yes | Yes — matches "Ruff rules" | ✅ |
| "python linting best practices" | Maybe | Unlikely — no generic Python linting trigger | ✅ Correct |
| "flake8 configuration guide" | No | No — "flake8 without Ruff" is negative trigger | ✅ |
| "pylint setup for Django" | No | No — "pylint config" is negative trigger | ✅ |
| "mypy type checking errors" | No | No — "mypy type checking" is negative trigger | ✅ |
| "black formatter line length" | No | No — "black formatter without Ruff" is negative trigger | ✅ |
| "ESLint setup React" | No | No — "ESLint JavaScript" is negative trigger | ✅ |

**Trigger quality assessment:** Excellent. Positive triggers cover the main Ruff use cases without being overly broad. Negative triggers correctly exclude adjacent tools (flake8, pylint, mypy, black, ESLint) to avoid false positives. The inclusion of migration-related triggers ("migrate from flake8/isort/black to Ruff") is smart — it captures the overlap case correctly.

## d. Score Rationale

- **Accuracy (4/5):** All core commands, rule codes, config options, and tool-replacement claims verified correct against official docs and web sources. Deducted 1 for ANN101 removal status being slightly wrong and a few minor omissions (watch mode, notebook support).

- **Completeness (4/5):** Exceptional breadth — covers installation, config, 28+ rule categories, formatting, import sorting, per-file ignores, fix modes, migration from 8 tools, pre-commit, editor integration, CI/CD, and provides 3 reference docs + 3 scripts + 3 asset templates. Deducted 1 for missing gotchas section, watch mode, notebook support, and newer CLI subcommands.

- **Actionability (5/5):** Outstanding. Users can immediately copy-paste: starter config, recommended config, strict config, Django/FastAPI/pytest/data-science configs, pre-commit config, GitHub Actions workflow. Before/after code examples for 3 common scenarios. Helper scripts automate migration, pre-commit setup, and rule auditing. Quick command reference table covers all essential operations.

- **Trigger quality (5/5):** Well-crafted positive triggers (8 specific patterns) and negative triggers (5 exclusions) that correctly scope the skill. No false-positive risk for adjacent tools. Migration use case correctly captured as a positive trigger.

## Issues Summary

Issues: ANN101 described as "deprecated" but was removed in Ruff 0.8.0; missing `--watch` mode; missing notebook (.ipynb) linting docs; missing gotchas section; pinned versions stale (v0.11.12 vs v0.15.7); missing `ruff server`/`ruff analyze`/`ruff config` subcommands.

## Verdict

**PASS** — Overall 4.5/5, no dimension ≤ 2, no GitHub issues required. All issues are minor and do not affect core usability. The skill is well-structured, accurate, and immediately actionable.
