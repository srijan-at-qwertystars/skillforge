# Advanced Conventional Commits Patterns

## Table of Contents

- [Custom Types Beyond the Standard 11](#custom-types-beyond-the-standard-11)
- [Multi-line Bodies and Footers](#multi-line-bodies-and-footers)
- [Co-authored-by and Other Trailers](#co-authored-by-and-other-trailers)
- [Ticket and Issue Linking Patterns](#ticket-and-issue-linking-patterns)
- [Squash Merge Conventions](#squash-merge-conventions)
- [Revert Commit Format](#revert-commit-format)
- [Monorepo Scope Strategies](#monorepo-scope-strategies)
- [Automating Changelogs from Commits](#automating-changelogs-from-commits)
- [Commit Message Templates](#commit-message-templates)
- [Advanced Breaking Change Patterns](#advanced-breaking-change-patterns)
- [Deprecation Workflow](#deprecation-workflow)
- [Security Commit Conventions](#security-commit-conventions)

---

## Custom Types Beyond the Standard 11

The Conventional Commits spec only mandates `feat` and `fix`. The other 9 types (`docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`) are conventions from the Angular project. Teams can extend this list.

### Commonly Added Custom Types

| Type       | Purpose                                             | When to Use                                    |
|------------|-----------------------------------------------------|------------------------------------------------|
| `hotfix`   | Emergency production fix                            | Critical bug requiring fast-track release      |
| `security` | Security patch or vulnerability fix                 | CVE fixes, dependency security bumps           |
| `wip`      | Work-in-progress (never reaches main)               | Feature branches only; squashed before merge   |
| `release`  | Release-related commits                             | Version bumps, release notes, changelog updates|
| `deps`     | Dependency updates (instead of `chore(deps)`)       | When dep updates are frequent enough to justify|
| `i18n`     | Internationalization / localization                  | Translation files, locale configs              |
| `a11y`     | Accessibility improvements                          | ARIA, keyboard nav, screen reader fixes        |
| `dx`       | Developer experience improvements                   | Tooling, error messages, dev docs              |
| `infra`    | Infrastructure changes                              | Terraform, Kubernetes, cloud configs           |
| `data`     | Data migrations or seed data changes                | Schema migrations, fixtures, seed scripts      |

### commitlint Config for Custom Types

```js
module.exports = {
  extends: ['@commitlint/config-conventional'],
  rules: {
    'type-enum': [2, 'always', [
      // Standard
      'feat', 'fix', 'docs', 'style', 'refactor',
      'perf', 'test', 'build', 'ci', 'chore', 'revert',
      // Custom
      'hotfix', 'security', 'deps', 'i18n', 'a11y', 'dx', 'infra', 'data',
    ]],
  },
};
```

### Mapping Custom Types to SemVer (semantic-release)

```json
{
  "plugins": [
    ["@semantic-release/commit-analyzer", {
      "preset": "conventionalcommits",
      "releaseRules": [
        { "type": "hotfix", "release": "patch" },
        { "type": "security", "release": "patch" },
        { "type": "deps", "release": "patch" },
        { "type": "perf", "release": "patch" },
        { "type": "i18n", "release": "patch" },
        { "type": "a11y", "release": "patch" },
        { "type": "dx", "release": false },
        { "type": "infra", "release": false },
        { "type": "data", "release": "patch" }
      ]
    }]
  ]
}
```

**Rule of thumb:** Only add a custom type when the standard types create ambiguity in your changelog. If `chore(deps)` is clear enough, don't add `deps`.

---

## Multi-line Bodies and Footers

### Body Best Practices

The body explains **why**, not what. The diff shows what changed; the body provides motivation.

**Structure for complex changes:**

```
fix(auth): prevent token replay attacks

Problem:
Refresh tokens could be reused after rotation, allowing replay attacks
within the grace period window.

Solution:
Implement token family tracking. When a rotated token is reused, all
tokens in the family are revoked (automatic reuse detection).

Impact:
- Users with multiple tabs may need to re-authenticate
- Grace period reduced from 60s to 10s

Refs: #892
Reviewed-by: @security-team
```

**Multiple paragraphs use blank line separators:**

```
refactor(db): migrate from callbacks to async/await

Convert all database access methods from callback-based patterns
to async/await for consistency with the rest of the codebase.

This is a large refactor touching 47 files. No behavior changes.
All existing tests pass without modification, confirming semantic
equivalence.

The remaining callback-based code in src/legacy/ is intentionally
left unchanged — it will be removed in v4.0.
```

### Footer Format Rules

Footers follow git-trailer convention: `token: value` or `token #value`.

**Multi-line footer values** — continue on the next line with leading whitespace:

```
feat(api)!: redesign authentication endpoints

BREAKING CHANGE: The authentication API has been completely redesigned.
  - POST /auth/login now returns a session object instead of a token string
  - POST /auth/refresh requires the full session object in the request body
  - DELETE /auth/logout now requires authentication
  Migration guide: https://docs.example.com/auth-v3-migration
```

**Multiple footers:**

```
fix(payments): handle currency conversion rounding

Fixes #234
Refs: #200, #215
Reviewed-by: @finance-team
Tested-by: @qa-payments
Signed-off-by: Alice <alice@example.com>
```

---

## Co-authored-by and Other Trailers

### Co-authored-by

GitHub, GitLab, and Bitbucket recognize `Co-authored-by` trailers to credit multiple contributors.

```
feat(dashboard): add real-time metrics widget

Implement WebSocket-based real-time metrics display with
auto-reconnection and exponential backoff.

Co-authored-by: Alice Chen <alice@example.com>
Co-authored-by: Bob Smith <bob@example.com>
```

**Rules:**
- Use the contributor's commit email (must match their Git/GitHub account)
- One `Co-authored-by` line per contributor
- Place after all other footers

### Other Standard Trailers

| Trailer            | Purpose                           | Example                                   |
|--------------------|-----------------------------------|--------------------------------------------|
| `Signed-off-by`    | DCO compliance                    | `Signed-off-by: Name <email>`             |
| `Reviewed-by`      | Code review credit                | `Reviewed-by: @username`                   |
| `Tested-by`        | QA attestation                    | `Tested-by: @qa-lead`                      |
| `Acked-by`         | Acknowledgment (kernel style)     | `Acked-by: Maintainer <email>`            |
| `Reported-by`      | Bug reporter credit               | `Reported-by: @reporter`                   |
| `Fixes`            | Closes an issue                   | `Fixes #123`                               |
| `Closes`           | Closes an issue                   | `Closes #456`                              |
| `Refs`             | References without closing        | `Refs: #789, #790`                         |
| `See-also`         | Related commits/issues            | `See-also: abc1234`                        |
| `Cherry-picked-from` | Backport tracking              | `Cherry-picked-from: def5678`             |

### Enforcing Signed-off-by (DCO)

For projects requiring Developer Certificate of Origin:

```js
// commitlint.config.js
module.exports = {
  extends: ['@commitlint/config-conventional'],
  rules: {
    'signed-off-by': [2, 'always', 'Signed-off-by:'],
  },
};
```

Contributors use `git commit -s` to auto-add the trailer.

---

## Ticket and Issue Linking Patterns

### GitHub/GitLab Issue References

```
fix(api): resolve rate limiting bypass

Closes #142
Refs: #100, #130
```

GitHub keywords that auto-close: `close`, `closes`, `closed`, `fix`, `fixes`, `fixed`, `resolve`, `resolves`, `resolved`.

### Jira Ticket Linking

**Scope-based:**
```
feat(PROJ-456): add bulk user import
```

**Footer-based (preferred — keeps scope semantic):**
```
feat(users): add bulk import endpoint

Implements the CSV upload and async processing pipeline for
bulk user imports with validation and error reporting.

Jira: PROJ-456
```

**commitlint enforcement for Jira footers:**

```js
module.exports = {
  extends: ['@commitlint/config-conventional'],
  plugins: [{
    rules: {
      'jira-footer': ({ raw }) => {
        const hasJira = /^Jira: [A-Z]+-\d+$/m.test(raw);
        return [hasJira, 'commit must include Jira footer (e.g., Jira: PROJ-123)'];
      },
    },
  }],
  rules: {
    'jira-footer': [1, 'always'],  // warning; use [2, 'always'] to enforce
  },
};
```

### Azure DevOps Work Item Linking

```
feat(auth): add SSO support

AB#12345
```

Azure DevOps recognizes `AB#` prefix automatically.

### Linear Issue Linking

```
feat(onboarding): add welcome flow

Linear: ENG-234
```

### Multi-tracker Pattern

For organizations using multiple trackers:

```
fix(billing): correct proration calculation

Fixes rounding error when upgrading mid-cycle with
fractional day counts.

Jira: BILL-789
Fixes #234
Sentry: FRONTEND-1A2B
```

---

## Squash Merge Conventions

### Problem

When squash merging a PR, GitHub creates a single commit from all PR commits. If not configured, the squash commit message defaults to the PR title + list of individual commits, which is often noisy.

### Best Practices

**1. PR title IS the conventional commit message:**

Configure GitHub branch protection to require PR titles matching conventional commit format. The squash merge uses the PR title as the commit header.

```
PR Title: feat(payments): add Stripe webhook handling
```

**2. Squash commit body = PR description (not individual commits):**

In repository settings → Pull Requests → select "Default to PR description" for squash merge commit messages.

**3. commitlint for squash merges:**

Individual PR commits can be informal (they'll be squashed), but enforce the PR title:

```yaml
# .github/workflows/pr-lint.yml
name: PR Title Lint
on:
  pull_request:
    types: [opened, edited, synchronize]

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: echo "${{ github.event.pull_request.title }}" | npx commitlint
```

**4. Individual commit guidelines during PR:**

Even though they'll be squashed, use conventional format for PR review clarity:

```
# Good PR commit series (will be squashed)
feat(payments): scaffold Stripe webhook handler
feat(payments): add signature verification
feat(payments): handle invoice.paid event
test(payments): add webhook handler tests
docs(payments): add webhook setup guide
```

### Relaxing Rules for Non-main Branches

```js
// commitlint.config.js — skip linting on feature branches
module.exports = {
  extends: ['@commitlint/config-conventional'],
  ignores: [
    (message) => /^Merge branch/.test(message),
    (message) => /^WIP/.test(message),
  ],
};
```

---

## Revert Commit Format

### Standard Format

```
revert: <original commit header>

This reverts commit <full SHA>.

<optional reason for reverting>
```

### Examples

**Simple revert:**
```
revert: feat(api): add user endpoint

This reverts commit a]1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0.
```

**Revert with reason:**
```
revert: perf(search): add elasticsearch caching layer

This reverts commit f1e2d3c4b5a6978869504132a3b4c5d6e7f8a9b0.

The caching layer introduced stale results for authenticated users.
Cache invalidation logic needs redesign. Tracked in #567.
```

**Revert of a breaking change:**
```
revert: feat(api)!: change authentication flow

This reverts commit 1234567890abcdef1234567890abcdef12345678.

Reverting due to client compatibility issues discovered post-deploy.
This revert undoes the BREAKING CHANGE — the old auth flow is restored.

BREAKING CHANGE: Authentication flow reverted to v2 session-based auth.
The X-API-Key header is no longer required.
```

**Partial revert (revert + fix):**
```
fix(api): revert rate limit changes, keep logging

Partially reverts commit abc1234.

The aggressive rate limiting caused false positives for legitimate
batch API users. The request logging additions are retained.

Refs: #890
```

### Automated Revert via `git revert`

`git revert <SHA>` auto-generates a message. Modify it to match conventional format:

```bash
# Default git revert message (not conventional):
# Revert "add user endpoint"
# This reverts commit abc1234.

# Preferred: edit to conventional format
git revert --no-commit abc1234
git commit -m 'revert: feat(api): add user endpoint

This reverts commit abc1234.
Reason: endpoint caused authentication failures.
Refs: #456'
```

---

## Monorepo Scope Strategies

### Strategy 1: Package Name as Scope

The most common. Scope = directory name under `packages/`.

```
feat(ui-components): add DatePicker component
fix(api-gateway): handle timeout in health check
test(shared-utils): add date formatting tests
```

**Pros:** Direct mapping to build/release targets.  
**Cons:** Long scope names; changes spanning packages need multiple commits or no scope.

### Strategy 2: Layered Scopes

For monorepos with nested structure (`packages/frontend/components/`):

```
feat(frontend/components): add DatePicker
fix(backend/auth): refresh token rotation
```

**commitlint config:**
```js
rules: {
  'scope-case': [2, 'always', 'kebab-case'],
  // Allow slashes in scope for nested packages
},
plugins: [{
  rules: {
    'scope-nested': ({ scope }) => {
      if (!scope) return [true];
      const parts = scope.split('/');
      return [parts.every(p => /^[a-z][a-z0-9-]*$/.test(p)),
        'scope segments must be lowercase kebab-case'];
    },
  },
}],
```

### Strategy 3: Domain Scopes (Not Package-Based)

Scope by business domain rather than package boundary:

```
feat(payments): add refund flow           # touches packages/api + packages/ui
fix(onboarding): email verification loop  # touches packages/auth + packages/email
```

**Pros:** Meaningful changelogs; maps to product areas.  
**Cons:** Harder to automate per-package releases.

### Strategy 4: Root vs Package Scope

Reserve a scope for repo-wide changes:

```
ci(repo): update GitHub Actions matrix
build(repo): upgrade TypeScript to 5.3
chore(repo): add workspace-level prettier config
```

### Dynamic Scope Extraction

Auto-extract scopes from workspace config:

```js
// commitlint.config.js
const { readdirSync, existsSync } = require('fs');
const { resolve } = require('path');

function getWorkspacePackages() {
  const dirs = ['packages', 'apps', 'libs'];
  const packages = [];
  for (const dir of dirs) {
    const fullPath = resolve(__dirname, dir);
    if (!existsSync(fullPath)) continue;
    const entries = readdirSync(fullPath, { withFileTypes: true });
    packages.push(...entries.filter(e => e.isDirectory()).map(e => e.name));
  }
  return packages;
}

module.exports = {
  extends: ['@commitlint/config-conventional'],
  rules: {
    'scope-enum': [2, 'always', ['repo', ...getWorkspacePackages()]],
  },
};
```

### pnpm Workspace + Turborepo Integration

```js
// commitlint.config.js — read from pnpm-workspace.yaml
const { execSync } = require('child_process');

function getPnpmPackages() {
  const output = execSync('pnpm list -r --json --depth -1', { encoding: 'utf8' });
  return JSON.parse(output).map(p => p.name.replace(/^@[^/]+\//, ''));
}

module.exports = {
  extends: ['@commitlint/config-conventional'],
  rules: {
    'scope-enum': [2, 'always', ['repo', ...getPnpmPackages()]],
  },
};
```

---

## Automating Changelogs from Commits

### Approach 1: conventional-changelog (Node.js)

```bash
npm install --save-dev conventional-changelog-cli
npx conventional-changelog -p conventionalcommits -i CHANGELOG.md -s
```

Reads `feat` and `fix` commits since last tag and prepends to `CHANGELOG.md`.

**Customizing included types:**

```js
// .versionrc.js (for standard-version)
module.exports = {
  types: [
    { type: 'feat', section: 'Features' },
    { type: 'fix', section: 'Bug Fixes' },
    { type: 'perf', section: 'Performance' },
    { type: 'security', section: 'Security', hidden: false },
    { type: 'deps', section: 'Dependencies', hidden: false },
    { type: 'docs', hidden: true },
    { type: 'style', hidden: true },
    { type: 'refactor', hidden: true },
    { type: 'test', hidden: true },
    { type: 'build', hidden: true },
    { type: 'ci', hidden: true },
    { type: 'chore', hidden: true },
  ],
};
```

### Approach 2: git-cliff (Rust — Fast, Flexible)

```bash
# Install
cargo install git-cliff
# Or via npm
npm install --save-dev git-cliff

# Generate changelog
git-cliff -o CHANGELOG.md
```

**cliff.toml configuration:**

```toml
[changelog]
header = "# Changelog\n\nAll notable changes to this project.\n"
body = """
{% if version %}\
    ## [{{ version }}] - {{ timestamp | date(format="%Y-%m-%d") }}
{% else %}\
    ## [Unreleased]
{% endif %}\
{% for group, commits in commits | group_by(attribute="group") %}
    ### {{ group | upper_first }}
    {% for commit in commits %}
        - {% if commit.scope %}**{{ commit.scope }}:** {% endif %}\
          {{ commit.message | upper_first }} \
          ([{{ commit.id | truncate(length=7, end="") }}](https://github.com/owner/repo/commit/{{ commit.id }}))\
    {% endfor %}
{% endfor %}\n
"""
trim = true

[git]
conventional_commits = true
filter_unconventional = true
commit_parsers = [
    { message = "^feat", group = "Features" },
    { message = "^fix", group = "Bug Fixes" },
    { message = "^perf", group = "Performance" },
    { message = "^security", group = "Security" },
    { message = "^doc", group = "Documentation" },
    { message = "^refactor", group = "Refactoring" },
    { message = "^deps", group = "Dependencies" },
    { message = ".*", group = "Other", default_scope = "other" },
]
filter_commits = false
tag_pattern = "v[0-9]*"
```

### Approach 3: Pure Git Log Parsing

For lightweight changelog generation without extra tools:

```bash
#!/bin/bash
# Generate grouped changelog between two tags
FROM="${1:-$(git describe --tags --abbrev=0 HEAD~1 2>/dev/null || echo '')}"
TO="${2:-HEAD}"

echo "## Changes ${FROM:+since $FROM}"
echo ""

for type_label in "feat:Features" "fix:Bug Fixes" "perf:Performance" "docs:Documentation"; do
  type="${type_label%%:*}"
  label="${type_label##*:}"
  commits=$(git log ${FROM:+$FROM..}$TO --pretty=format:"- %s (%h)" --grep="^${type}" 2>/dev/null)
  if [ -n "$commits" ]; then
    echo "### $label"
    echo "$commits"
    echo ""
  fi
done
```

### Approach 4: release-please (Google)

Fully automated: opens a release PR, maintains changelog, bumps versions.

```yaml
# .github/workflows/release-please.yml
on:
  push:
    branches: [main]

permissions:
  contents: write
  pull-requests: write

jobs:
  release-please:
    runs-on: ubuntu-latest
    steps:
      - uses: googleapis/release-please-action@v4
        with:
          release-type: node
```

release-please creates/updates a PR with changelog entries. Merging the PR triggers the release.

---

## Commit Message Templates

### Git Template Setup

```bash
# Create template file
cat > ~/.gitmessage << 'EOF'
# <type>(<scope>): <description>
#
# [optional body]
#
# [optional footer(s)]
#
# Types: feat fix docs style refactor perf test build ci chore revert
# Scope: lowercase noun for affected module (auth, api, db, ui, etc.)
# Description: imperative, lowercase, no period, ≤72 chars
# Body: explain WHY, not what. Wrap at 72 chars.
# Footer: BREAKING CHANGE: ... | Closes #123 | Refs: #456
#
# Examples:
#   feat(auth): add OAuth2 login flow
#   fix(api): handle null response from upstream
#   docs: update contributing guidelines
#   feat(api)!: remove deprecated v1 endpoints
EOF

# Set as default template
git config --global commit.template ~/.gitmessage
```

### Per-project Template

```bash
# In project root
cat > .gitmessage << 'EOF'

# <type>(<scope>): <description>   [≤72 chars this line]
#
# Body: explain the WHY behind this change
#
# Footer(s):
# Jira: PROJ-XXX
# Closes #XXX
EOF

git config commit.template .gitmessage
```

### Team Template with Project-Specific Scopes

```bash
cat > .gitmessage << 'EOF'

# <type>(<scope>): <description>
#
# Allowed types: feat fix docs style refactor perf test build ci chore revert
# Allowed scopes: api auth billing dashboard shared infra
#
# Body (optional — explain motivation, not mechanics):
#
#
# Footer (required for features and fixes):
# Jira: PROJ-
# Closes #
EOF
```

---

## Advanced Breaking Change Patterns

### Gradual Deprecation → Breaking Change Workflow

**Phase 1 — Deprecation (MINOR bump):**
```
feat(api): add v2 user endpoint, deprecate v1

The /v1/users endpoint is now deprecated. A console warning
is emitted on each request. Use /v2/users instead.

Deprecated: /v1/users endpoint — removal planned for v5.0
Refs: #300
```

**Phase 2 — Removal (MAJOR bump):**
```
feat(api)!: remove deprecated /v1/users endpoint

BREAKING CHANGE: The /v1/users endpoint has been removed.
All clients must use /v2/users. Migration guide:
  https://docs.example.com/migrate-v1-to-v2

Refs: #300, #425
```

### Multiple Breaking Changes in One Commit

```
feat(config)!: redesign configuration system

Migrate from flat .env files to structured YAML configuration.

BREAKING CHANGE: Configuration file format changed from .env to config.yaml.
  See docs/migration/config-v3.md for conversion guide.
BREAKING CHANGE: Environment variable prefix changed from APP_ to MYAPP_.
  All APP_* variables must be renamed to MYAPP_*.
BREAKING CHANGE: Default port changed from 3000 to 8080.
  Deployments must update port mappings.
```

---

## Deprecation Workflow

Track deprecations systematically through commits:

```
# Adding deprecation notice
feat(api): deprecate GET /users/:id/profile

Add deprecation header (Sunset: 2025-06-01) and console warning.
Use GET /users/:id instead, which now includes profile data.

Deprecated: GET /users/:id/profile (sunset: 2025-06-01)
Refs: RFC-023
```

### commitlint Plugin for Deprecation Tracking

```js
plugins: [{
  rules: {
    'deprecation-footer': ({ footer, raw }) => {
      if (raw.includes('deprecat') && !raw.includes('Deprecated:')) {
        return [false, 'commits mentioning deprecation should include Deprecated: footer'];
      }
      return [true];
    },
  },
}],
```

---

## Security Commit Conventions

### For Public Repositories

**Never include vulnerability details in public commit messages before a fix is released.**

```
# GOOD — vague until CVE is published
fix(auth): address session handling vulnerability

See SECURITY.md for details. CVE pending assignment.

Security-Advisory: GHSA-xxxx-xxxx-xxxx
```

### For Private Repositories / Post-Disclosure

```
security(auth): fix JWT signature bypass (CVE-2024-12345)

The JWT verification logic did not validate the algorithm
parameter, allowing an attacker to submit tokens signed
with 'none' algorithm.

Fix: Enforce algorithm whitelist in verification middleware.
Impact: Any user with a valid JWT could forge admin tokens.

CVE: CVE-2024-12345
CVSS: 9.8
Reported-by: @security-researcher
```

### Automated Security Commit Detection

```js
// commitlint plugin: ensure security commits include required metadata
plugins: [{
  rules: {
    'security-metadata': ({ type, raw }) => {
      if (type !== 'security') return [true];
      const hasCVE = /CVE-\d{4}-\d+/.test(raw) || /CVE pending/.test(raw);
      const hasSeverity = /CVSS:|Severity:/i.test(raw);
      return [hasCVE && hasSeverity,
        'security commits must include CVE reference and severity'];
    },
  },
}],
```
