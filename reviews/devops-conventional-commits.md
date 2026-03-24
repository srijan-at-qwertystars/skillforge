# QA Review: conventional-commits

| Field          | Value                                              |
|----------------|----------------------------------------------------|
| **Skill**      | `devops/conventional-commits`                      |
| **Reviewer**   | automated-qa                                       |
| **Date**       | 2025-07-15                                         |
| **Verdict**    | ✅ PASS                                             |

---

## A. Structure Check

### YAML Frontmatter
- ✅ **name:** `conventional-commits` — present
- ✅ **description:** Multi-line, clearly states purpose ("Generate, validate, and fix commit messages following the Conventional Commits v1.0.0 spec")

### Trigger Definitions
- ✅ **Positive triggers (15):** conventional commits, commit message format, commitlint, commit convention, feat/fix/chore commit, breaking change commit, commit message validation, husky commit hook, commitizen setup, semantic-release config, standard-version, commit types, commit scopes, BREAKING CHANGE footer, angular commit convention, commit linting
- ✅ **Negative triggers (6):** git basics tutorial, git rebase/merge workflow, GitHub PR review, changelog manual writing, general git commands, branch management strategies

### Line Count
- ✅ **SKILL.md:** 499 lines (under 500 limit — just barely)
- ℹ️ **references/advanced-patterns.md:** 878 lines (reference files not subject to limit)
- ℹ️ **references/tooling-guide.md:** 1168 lines (reference files not subject to limit)

### Imperative Voice
- ✅ Examples consistently use imperative mood ("add", "resolve", "update", "remove", "extract")
- ✅ Custom commitlint plugin explicitly enforces imperative mood by rejecting past tense (line 131 of assets/commitlint.config.js)

### Examples
- ✅ **12 Input→Output examples** covering every standard type (feat, fix, docs, style, refactor, perf, test, build, ci, chore, plus breaking change and deps scope)
- ✅ **Breaking change examples** show footer, bang, and combined notation
- ✅ **Revert commit** example with format guidance
- ✅ **Multi-paragraph body** example with motivation/context pattern

### Links to References/Scripts
- ✅ **Skill Resources section** (line 426+) with tables linking to all references, scripts, and assets with descriptions
- ✅ Scripts table includes usage examples (`./scripts/setup-commitlint.sh --scopes "api,auth,ui"`)
- ✅ Assets table describes each file's purpose

---

## B. Content Check

### Conventional Commits Spec (v1.0.0) — Verified via web search
- ✅ Structure `<type>[optional scope]: <description>` matches official spec
- ✅ `feat` and `fix` correctly identified as the only spec-mandated types
- ✅ Other 9 types correctly attributed to Angular convention (acknowledged in references/advanced-patterns.md line 22)
- ✅ `BREAKING CHANGE` footer (uppercase) correctly documented
- ✅ `!` bang notation for breaking changes correctly documented
- ✅ Footer format `token: value` or `token #value` matches spec
- ⚠️ **Minor note:** Spec says "A BREAKING CHANGE MUST be indicated in the type/scope prefix of a commit, and/or as an entry in the footer." The skill correctly covers both but could more explicitly state that `BREAKING-CHANGE` (with hyphen) is also valid as a footer token per the spec. **Impact: negligible** — the hyphenated form is extremely rarely used.

### commitlint Rules — Verified via web search + npm docs
- ✅ `@commitlint/config-conventional` rule set is accurate
- ✅ Rule tuple format `[severity, applicable, value]` correctly documented
- ✅ Severity levels (0=off, 1=warn, 2=error) correct
- ✅ Default type enum matches the official config-conventional package
- ✅ Config file search order in tooling-guide.md matches commitlint docs
- ✅ ESM project guidance (`.cjs`/`.mjs` extensions) is correct and practical

### Husky v9 Setup — Verified via web search
- ✅ `npx husky init` (not the old `npx husky install`) — correct for v9+
- ✅ Hook file creation via direct file write (`echo ... > .husky/commit-msg`) — correct v9 approach
- ✅ `prepare` script set to `"husky"` — matches v9 convention
- ✅ CI skip via `HUSKY=0` and automatic `CI` env var detection documented
- ✅ `--no-verify` skip documented

### Semantic Versioning Integration
- ✅ semantic-release config, plugins, and GitHub Actions workflow are accurate
- ✅ `commit-analyzer` release rules mapping is correct

### standard-version Deprecation
- ✅ **Correctly flagged as deprecated** in tooling-guide.md (line 713: "standard-version is deprecated")
- ✅ `commit-and-tag-version` fork recommended as drop-in replacement
- ✅ `release-please` covered as alternative with config and monorepo support
- ⚠️ **SKILL.md itself** (line 345-357) presents standard-version without a deprecation warning. The deprecation note only appears in the tooling-guide reference. **Recommendation:** Add a one-line deprecation note in SKILL.md next to the standard-version section. **Impact: minor** — the tooling-guide has the note, and users exploring deeper will find it.

### Missing Gotchas
- ⚠️ **ESM `"type": "module"` gotcha** — partially covered in tooling-guide (line 69-76) but not mentioned in SKILL.md's commitlint setup section. Users with ESM projects will hit `require()` errors with `module.exports` configs. **Impact: moderate for new Node.js projects, but reference file covers it.**
- ⚠️ **`BREAKING-CHANGE`** (hyphenated synonym) — not mentioned anywhere. Rarely used, negligible impact.
- ✅ Husky v9 troubleshooting section covers common issues (hooks not running, permission errors, monorepo root mismatch)
- ✅ Squash merge conventions covered in advanced-patterns.md — a frequently missed topic
- ✅ Security commit conventions (don't leak vulnerability details in public repos) — excellent inclusion
- ✅ CI integration for commitlint (GitHub Actions + GitLab CI) covered

---

## C. Trigger Check

### Would it trigger for commit convention queries?

| Query                                              | Expected | Actual | ✓/✗ |
|----------------------------------------------------|----------|--------|-----|
| "How do I write conventional commit messages?"     | Yes      | Yes    | ✅  |
| "Set up commitlint in my project"                  | Yes      | Yes    | ✅  |
| "What commit type should I use for a bug fix?"     | Yes      | Yes    | ✅  |
| "Configure husky commit-msg hook"                  | Yes      | Yes    | ✅  |
| "Set up semantic-release with conventional commits"| Yes      | Yes    | ✅  |
| "How to format a breaking change commit"           | Yes      | Yes    | ✅  |
| "commitizen setup for my team"                     | Yes      | Yes    | ✅  |
| "What's the angular commit convention?"            | Yes      | Yes    | ✅  |
| "feat vs fix commit type"                          | Yes      | Yes    | ✅  |
| "BREAKING CHANGE footer format"                    | Yes      | Yes    | ✅  |

### False trigger for git basics?

| Query                                          | Expected | Actual | ✓/✗ |
|------------------------------------------------|----------|--------|-----|
| "How do I use git rebase?"                     | No       | No     | ✅  |
| "Git merge vs rebase workflow"                 | No       | No     | ✅  |
| "How to create a git branch"                   | No       | No     | ✅  |
| "Git basics tutorial for beginners"            | No       | No     | ✅  |
| "How to write a PR review"                     | No       | No     | ✅  |
| "How to write a changelog by hand"             | No       | No     | ✅  |
| "Git stash and cherry-pick commands"           | No       | No     | ✅  |

### Edge Cases

| Query                                          | Expected    | Actual   | Notes                        |
|------------------------------------------------|-------------|----------|------------------------------|
| "How to write better commit messages"          | Maybe       | Likely   | ⚠️ Could false-trigger, but relevant enough |
| "Generate a changelog from git"                | Maybe       | Likely   | Skill covers this; appropriate trigger |
| "Set up git hooks"                             | Maybe       | No       | ✅ Negative trigger "general git commands" protects |

**Trigger quality assessment:** The positive trigger list is comprehensive (15 terms covering spec, tooling, and workflow). The negative trigger list is well-targeted to prevent git-basics false triggering. The edge case of "better commit messages" is debatable but acceptable — the skill *is* about commit message format.

---

## D. Scores

| Dimension        | Score | Notes                                                                                   |
|------------------|-------|-----------------------------------------------------------------------------------------|
| **Accuracy**     | 5/5   | Spec rules, commitlint config, Husky v9 setup, semantic-release all verified correct. No factual errors found. |
| **Completeness** | 4/5   | Exceptional breadth: spec, 11 types, scopes, breaking changes, revert format, tooling (commitlint, Husky, Commitizen, lint-staged, semantic-release, standard-version, release-please, git-cliff), monorepo strategies, security conventions, squash merges, deprecation workflow. Minor gaps: standard-version deprecation warning missing from SKILL.md, ESM gotcha not in main file, `BREAKING-CHANGE` hyphen synonym omitted. |
| **Actionability** | 5/5  | Complete setup checklist (7 steps, copy-paste ready). Three executable scripts with `--help`. Production-ready config assets. 12 input→output examples. CI workflow YAML for GitHub Actions and GitLab. |
| **Trigger Quality** | 5/5 | 15 positive triggers cover the full domain. 6 negative triggers prevent plausible false triggers. No observed false positives or missed true positives in testing. |

### Overall Score: **4.75 / 5.0**

---

## E. Issues Found

### Minor (non-blocking)

1. **standard-version deprecation not surfaced in SKILL.md** — The deprecation note is only in `references/tooling-guide.md` (line 713). SKILL.md (lines 345-357) presents it as a current option. Add a deprecation note inline.

2. **ESM project gotcha** — `commitlint.config.js` using `module.exports` will fail in `"type": "module"` projects. Mentioned in tooling-guide but not in SKILL.md setup section. Consider adding a one-line note.

3. **`BREAKING-CHANGE` footer synonym** — The spec allows `BREAKING-CHANGE` (with hyphen) as a synonym for `BREAKING CHANGE` (with space). Not mentioned. Extremely low impact.

4. **SKILL.md line count at 499** — Just under the 500-line limit. Any additions will require extracting content to references.

### None Critical

No issues warrant filing GitHub issues. All scores ≥ 4 and overall is 4.75.

---

## F. File Inventory

| File                              | Lines | Status |
|-----------------------------------|-------|--------|
| `SKILL.md`                        | 499   | ✅ Well-structured, comprehensive |
| `references/advanced-patterns.md` | 878   | ✅ Deep coverage of edge cases |
| `references/tooling-guide.md`     | 1168  | ✅ Exhaustive tooling reference |
| `scripts/setup-commitlint.sh`     | 204   | ✅ Production-quality, PM detection, error handling |
| `scripts/validate-history.sh`     | 204   | ✅ JSON output, compliance %, color-coded |
| `scripts/generate-changelog.sh`   | 291   | ✅ Tag-to-tag changelog, prepend mode, repo URL auto-detect |
| `assets/commitlint.config.js`     | 205   | ✅ Custom plugins (imperative mood, vague subject), monorepo scopes, prompt config |
| `assets/.czrc`                    | 25    | ✅ All 11 types with emoji, width limits |
| `assets/commit-msg-hook`          | 109   | ✅ CI skip, merge/fixup skip, fallback regex |

---

## G. Verdict

**PASS** — This is a high-quality, production-ready skill. Accuracy is verified against the official spec, npm docs, and current tooling. Coverage is exceptional across spec, tooling, monorepo, CI, and edge cases. The three executable scripts and copy-paste assets make it immediately actionable. Trigger definitions are precise. Minor improvements noted above are non-blocking.
