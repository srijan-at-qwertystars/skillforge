# QA Review: ci-cd/github-actions

**Reviewer**: Copilot CLI (automated)
**Date**: 2025-01-13
**Skill path**: `~/skillforge/ci-cd/github-actions/`

---

## A. Structure Check

| Criterion | Status | Notes |
|---|---|---|
| YAML frontmatter (name) | ✅ Pass | `name: github-actions` |
| YAML frontmatter (description with +/− triggers) | ✅ Pass | Positive: 6 USE clauses covering workflows, composite actions, reusable workflows, CI/CD config, marketplace actions, expressions, GITHUB_TOKEN. Negative: DO NOT USE for GitLab CI, CircleCI, Jenkins, Travis CI, Dagger CI, general YAML. |
| Body under 500 lines | ✅ Pass | Exactly 500 lines (at the limit). |
| Imperative voice | ✅ Pass | Consistently uses imperative ("Place workflow files…", "Pin actions to full commit SHA", "Set minimal permissions", "Use OIDC…"). |
| Examples with input/output | ✅ Pass | 20+ YAML code blocks showing workflow configurations, expression usage, and expected patterns. Domain-appropriate (config → behavior, not Q&A). |
| References linked from SKILL.md | ✅ Pass | All 3 reference docs linked: `advanced-patterns.md`, `troubleshooting.md`, `security-guide.md`. |
| Scripts linked from SKILL.md | ✅ Pass | All 3 scripts linked: `workflow-init.sh`, `action-init.sh`, `workflow-lint.sh`. |
| Assets linked from SKILL.md | ✅ Pass | All 5 templates linked: `ci-workflow.yml`, `cd-workflow.yml`, `release-workflow.yml`, `reusable-workflow.yml`, `composite-action/action.yml`. |

---

## B. Content Check (Web-Verified)

### Workflow Syntax
- ✅ **Correct**: `name`, `on`, `jobs` required top-level keys.
- ✅ **Correct**: Trigger types (`push`, `pull_request`, `schedule`, `workflow_dispatch`, `workflow_call`, `repository_dispatch`, `release`, `pull_request_target`) all accurately described.
- ✅ **Correct**: Filter syntax (`branches`, `tags`, `paths`, `paths-ignore`, `types`) matches official docs.

### Action Versions
- ✅ `actions/checkout@v4` — current major is v4 (latest v4.3.1). Correctly used throughout.
- ✅ `actions/setup-node@v4`, `actions/upload-artifact@v4`, `actions/cache@v4` — all current.
- ✅ `docker/build-push-action@v6` — current.
- ✅ `aws-actions/configure-aws-credentials@v4` — current.
- ⚠️ SHA example `b4ffde65f46336ab88eb53be808477a3936bae11` is for checkout v4.1.1 (outdated; latest is v4.3.1). Acceptable as an illustrative example of SHA pinning, not a recommended pin target.

### OIDC Setup
- ✅ **Correct**: `id-token: write` permission required.
- ✅ **Correct**: Provider URL `https://token.actions.githubusercontent.com`, audience `sts.amazonaws.com`.
- ✅ **Correct**: AWS trust policy with `StringLike` on `sub` claim.
- ✅ **Correct**: GCP (`google-github-actions/auth@v2`) and Azure (`azure/login@v2`) examples.
- ✅ **Correct**: Subject claim patterns for access control.

### Permissions
- ✅ **Correct**: Fork PRs always read-only for `GITHUB_TOKEN`.
- ✅ **Correct**: Per-job permission overrides, deny-all with `permissions: {}`.
- ⚠️ Minor: security-guide.md states "By default, `GITHUB_TOKEN` has broad permissions" (line 123). Since Feb 2023, new repos/orgs default to read-only. The SKILL.md itself says "Default `permissions: {}` denies all" which is correct for workflow-level YAML.

### Runner Specs
- ✅ `ubuntu-latest` → skill lists `ubuntu-24.04` as a runner label. Verified: `ubuntu-latest` now maps to 24.04 (migrated Dec 2024–Jan 2025).
- ✅ `macos-14` = ARM (Apple Silicon), `macos-13` = Intel — correct.
- ✅ Larger runners naming convention (`ubuntu-latest-4-cores`) — correct, Team/Enterprise only.

### Cache
- ⚠️ Skill states "Cache limit: 10 GB per repo." As of Nov 2025, the free tier remains 10 GB but pay-as-you-go expansion is available. The stated default is still accurate for most users.
- ✅ 7-day eviction policy — correct.
- ✅ `hashFiles()` on lockfiles, `restore-keys` fallback — correct.

### Missing Gotchas (minor)
1. **`timeout-minutes`**: Not recommended as default practice in main SKILL.md body (only in security checklist in references). Adding it to the main "Performance" or "Common Pitfalls" section would help.
2. **`ubuntu-latest` = 24.04**: The runners table lists both `ubuntu-latest` and `ubuntu-24.04` but doesn't explicitly state they're now equivalent. Users on older workflows may need this callout.
3. **Job-level `timeout-minutes` default**: GitHub defaults to 360 min (6h); explicitly setting shorter timeouts is a best practice not emphasized in the main body.

### Examples Correctness
- ✅ All YAML examples are syntactically valid.
- ✅ Asset templates (CI, CD, release, reusable, composite) follow current best practices.
- ✅ Scripts (`workflow-init.sh`, `action-init.sh`, `workflow-lint.sh`) are well-structured with proper error handling and support multiple languages/frameworks.

---

## C. Trigger Check

### Would description trigger for GitHub Actions queries?
**✅ Yes** — Strong coverage. The description mentions:
- `.github/workflows/*.yml` (file pattern)
- Composite actions, reusable workflows, `workflow_call`
- Triggers, matrix strategies, caching, artifacts, secrets, OIDC
- Environment protection rules, runner selection
- `actions/*` marketplace actions, `${{ expressions }}`, `GITHUB_TOKEN`

Test queries that would correctly trigger:
- "How do I set up a CI workflow with GitHub Actions?" → ✅
- "Fix my matrix strategy in a GitHub Actions workflow" → ✅
- "How do I use OIDC with GitHub Actions for AWS?" → ✅
- "What permissions does GITHUB_TOKEN need?" → ✅
- "Create a composite action" → ✅

### Would it falsely trigger for GitLab CI or CircleCI?
**✅ No** — Explicitly excluded: "DO NOT USE for Dagger CI, GitLab CI, CircleCI, Jenkins, Travis CI, or other non-GitHub CI/CD systems. DO NOT USE for general YAML editing unrelated to GitHub Actions."

Test queries that should NOT trigger:
- "Set up a GitLab CI pipeline" → ✅ Excluded
- "Configure CircleCI orbs" → ✅ Excluded
- "Create a Jenkinsfile" → ✅ Excluded
- "Edit my docker-compose.yml" → ✅ Excluded (general YAML)

---

## D. Scores

| Dimension | Score | Rationale |
|---|---|---|
| **Accuracy** | 4 | Technically accurate on all core claims (syntax, OIDC, permissions, triggers, runners). Minor: outdated SHA example (v4.1.1 vs v4.3.1), security-guide says GITHUB_TOKEN defaults to "broad permissions" (outdated for new repos since Feb 2023), cache limit doesn't mention pay-as-you-go option. None are materially misleading. |
| **Completeness** | 5 | Exceptionally comprehensive. Main body covers all major topics. 3 deep-dive reference guides (advanced patterns 550+ lines, security 725 lines, troubleshooting 654 lines). 5 production-ready templates. 3 scaffolding scripts covering 9 languages. Covers edge cases (fork token behavior, artifact v4 naming, schedule on default branch). |
| **Actionability** | 5 | Every section has copy-paste YAML. Templates are production-ready with caching, matrix, concurrency, and proper permissions. Scripts auto-detect languages and scaffold workflows. Composite action template includes build timing and coverage. |
| **Trigger quality** | 5 | Positive triggers comprehensively cover the GitHub Actions domain with specific keywords (file patterns, feature names, expression syntax). Negative triggers explicitly list 5 competing CI/CD systems plus general YAML. No false-trigger risk identified. |

### Overall Score: **4.75 / 5.0**

---

## E. Issue Filing

- Overall score (4.75) ≥ 4.0 → **No issues required.**
- No dimension ≤ 2 → **No issues required.**

### Recommendations (non-blocking)
1. **Update security-guide.md line 123**: Change "By default, `GITHUB_TOKEN` has broad permissions" to note that new repos/orgs default to read-only since Feb 2023.
2. **Add `timeout-minutes` to main body**: Mention it in Performance Optimization or Common Pitfalls as a recommended default.
3. **Note `ubuntu-latest` = 24.04 equivalence**: Add a note in the Runners table that `ubuntu-latest` now maps to 24.04 as of Jan 2025.
4. **Update SHA example**: Consider using a more recent checkout SHA for the pinning example, or add a note that users should look up the current SHA.

---

## F. Verdict

**PASS** ✅

The GitHub Actions skill is production-quality with exceptional coverage, accuracy, and actionability. Minor improvements noted above are non-blocking.
