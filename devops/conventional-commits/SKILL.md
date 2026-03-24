---
name: conventional-commits
description: >
  Generate, validate, and fix commit messages following the Conventional Commits v1.0.0 spec.
  Trigger when user mentions: conventional commits, commit message format, commitlint,
  commit convention, feat/fix/chore commit, breaking change commit, commit message validation,
  husky commit hook, commitizen setup, semantic-release config, standard-version, commit types,
  commit scopes, BREAKING CHANGE footer, angular commit convention, commit linting.
  Do NOT trigger for: git basics tutorial, git rebase/merge workflow, GitHub PR review,
  changelog manual writing, general git commands, branch management strategies.
---

# Conventional Commits Skill

## Spec Overview (v1.0.0)

Every commit message follows this structure:

```
<type>[optional scope]: <description>

[optional body]

[optional footer(s)]
```

Rules:
- `type` and `description` are REQUIRED.
- `scope` is OPTIONAL, wrapped in parentheses after type.
- `description` starts lowercase, imperative mood, no trailing period.
- Separate `body` from description with one blank line.
- `body` is free-form, may consist of multiple paragraphs.
- `footer(s)` follow git-trailer format: `token: value` or `token #value`.
- BREAKING CHANGE footer MUST be uppercase `BREAKING CHANGE: <description>`.
- `!` after type/scope is shorthand for breaking change: `feat!:` or `feat(api)!:`.
- A commit with `!` SHOULD also include a BREAKING CHANGE footer for full context.

## Standard Types

| Type       | Purpose                                      | SemVer Impact |
|------------|----------------------------------------------|---------------|
| `feat`     | New feature                                  | MINOR         |
| `fix`      | Bug fix                                      | PATCH         |
| `docs`     | Documentation only                           | none          |
| `style`    | Formatting, whitespace, semicolons           | none          |
| `refactor` | Code change: no bug fix, no new feature      | none          |
| `perf`     | Performance improvement                      | PATCH         |
| `test`     | Add or correct tests                         | none          |
| `build`    | Build system or external dependencies        | none          |
| `ci`       | CI configuration and scripts                 | none          |
| `chore`    | Maintenance tasks (no src/test modification) | none          |
| `revert`   | Revert a previous commit                     | varies        |

When generating a type, match the PRIMARY intent of the change. If a feat also fixes a bug, use `feat`. If a refactor improves perf, use `perf`.

## Scopes

Scopes are nouns describing the affected code section. Use them when the project has clear modules.

Good scopes: `auth`, `api`, `parser`, `cli`, `db`, `ui`, `config`, `deps`.

Rules for scopes:
- Keep scopes consistent across the project. Define an allowed list.
- Use lowercase, kebab-case for multi-word: `user-auth`, `data-layer`.
- Omit scope when the change is cross-cutting or project-wide.
- In monorepos, use the package name as scope: `feat(payments): add refund endpoint`.

## Breaking Changes

Two notations (use both together for maximum clarity):

**Footer notation:**
```
feat(api): change authentication flow

BREAKING CHANGE: The /auth/login endpoint now requires an API key header.
Clients must update their request headers.
```

**Bang notation:**
```
feat(api)!: change authentication flow
```

**Combined (preferred for major changes):**
```
feat(api)!: change authentication flow

Migrate from session-based auth to API key authentication.

BREAKING CHANGE: The /auth/login endpoint now requires X-API-Key header.
All existing session tokens are invalidated.
Refs: #456
```

Breaking changes ALWAYS trigger a MAJOR version bump regardless of type.

## Revert Commits

Format reverts as:
```
revert: feat(api): add user endpoint

This reverts commit abc1234.
```

The description SHOULD be the header of the reverted commit. Include the reverted SHA in the body.

## Multi-paragraph Body

Use the body for motivation, context, and contrast with previous behavior:
```
fix(parser): handle nested brackets correctly

The parser previously failed when encountering more than 3 levels
of nested brackets, causing a stack overflow.

This fix replaces the recursive approach with an iterative one
using an explicit stack data structure.

Closes #789
```

## Examples — Input → Output

**User:** "I added a login page"
```
feat(auth): add login page
```

**User:** "Fixed the bug where users couldn't reset password"
```
fix(auth): resolve password reset failure
```

**User:** "Updated README with new API docs"
```
docs: update README with API documentation
```

**User:** "Removed trailing whitespace everywhere"
```
style: remove trailing whitespace
```

**User:** "Moved validation logic into its own module"
```
refactor(validation): extract validation into separate module
```

**User:** "Made the search 2x faster by adding an index"
```
perf(search): add database index for search queries
```

**User:** "Added unit tests for the payment module"
```
test(payments): add unit tests for payment processing
```

**User:** "Updated webpack to v5"
```
build: upgrade webpack to v5
```

**User:** "Added GitHub Actions CI pipeline"
```
ci: add GitHub Actions workflow
```

**User:** "Cleaned up old scripts in package.json"
```
chore: remove unused scripts from package.json
```

**User:** "Removed the deprecated /v1/users endpoint — this breaks clients"
```
feat(api)!: remove deprecated /v1/users endpoint

BREAKING CHANGE: The /v1/users endpoint has been removed.
Clients must migrate to /v2/users.
```

**User:** "Bumped lodash and axios"
```
chore(deps): update lodash and axios
```

## commitlint Setup

### Install

```bash
npm install --save-dev @commitlint/cli @commitlint/config-conventional
```

### Configuration

Create `commitlint.config.js` (or `.commitlintrc.js`, `.commitlintrc.yml`):

```js
// commitlint.config.js
module.exports = {
  extends: ['@commitlint/config-conventional'],
  rules: {
    // Severity: 0=off, 1=warn, 2=error
    // Applicable: 'always' | 'never'
    'type-enum': [2, 'always', [
      'feat', 'fix', 'docs', 'style', 'refactor',
      'perf', 'test', 'build', 'ci', 'chore', 'revert'
    ]],
    'scope-case': [2, 'always', 'lower-case'],
    'subject-case': [2, 'never', ['start-case', 'pascal-case', 'upper-case']],
    'subject-empty': [2, 'never'],
    'subject-full-stop': [2, 'never', '.'],
    'type-case': [2, 'always', 'lower-case'],
    'type-empty': [2, 'never'],
    'header-max-length': [2, 'always', 100],
    'body-max-line-length': [2, 'always', 200],
    'footer-max-line-length': [2, 'always', 200],
  },
};
```

### Restricting Scopes

```js
module.exports = {
  extends: ['@commitlint/config-conventional'],
  rules: {
    'scope-enum': [2, 'always', ['api', 'auth', 'cli', 'core', 'db', 'ui']],
  },
};
```

### Custom Plugin Rules

```js
module.exports = {
  extends: ['@commitlint/config-conventional'],
  plugins: [{
    rules: {
      'jira-ticket-scope': ({ scope }) => {
        if (!scope) return [true];
        return [/^[A-Z]+-\d+$/.test(scope), 'scope must be JIRA ticket (e.g., PROJ-123)'];
      },
    },
  }],
  rules: { 'jira-ticket-scope': [2, 'always'] },
};
```

### Testing: `echo "feat(auth): add login" | npx commitlint` or `npx commitlint --from=HEAD~1`.

## Husky Integration

### Setup (Husky v9+)

```bash
npm install --save-dev husky
npx husky init
```

This creates `.husky/` directory and adds `prepare` script to `package.json`.

### Add commit-msg Hook

```bash
echo 'npx --no -- commitlint --edit "$1"' > .husky/commit-msg
```

### Optional: pre-commit Hook with lint-staged

```bash
npm install --save-dev lint-staged
echo 'npx lint-staged' > .husky/pre-commit
```

Configure in `package.json`: `"lint-staged": { "*.{js,ts}": ["eslint --fix", "prettier --write"] }`

### Full package.json Scripts

```json
{ "scripts": { "prepare": "husky", "commit": "cz", "release": "semantic-release" } }
```

## Commitizen (Interactive Commits)

### Setup

```bash
npm install --save-dev commitizen cz-conventional-changelog
```

Add to `package.json`: `"config": { "commitizen": { "path": "cz-conventional-changelog" } }`

### Usage: `npx cz` (interactive wizard) or `npm run commit` (via script).

### Custom Adapters

- `cz-customizable`: fully customizable prompts via `.cz-config.js`.
- `@commitlint/cz-commitlint`: integrates prompts with commitlint rules.

```bash
npm install --save-dev @commitlint/cz-commitlint
# Then set path to "@commitlint/cz-commitlint" in commitizen config
```

## Semantic Versioning Integration

### semantic-release (fully automated, CI-driven)

```bash
npm install --save-dev semantic-release \
  @semantic-release/commit-analyzer \
  @semantic-release/release-notes-generator \
  @semantic-release/changelog \
  @semantic-release/npm \
  @semantic-release/github \
  @semantic-release/git
```

Create `.releaserc.json`:
```json
{
  "branches": ["main", {"name": "next", "prerelease": true}],
  "plugins": [
    "@semantic-release/commit-analyzer",
    "@semantic-release/release-notes-generator",
    ["@semantic-release/changelog", {"changelogFile": "CHANGELOG.md"}],
    "@semantic-release/npm",
    ["@semantic-release/git", {"assets": ["CHANGELOG.md", "package.json"],
      "message": "chore(release): ${nextRelease.version}\n\n${nextRelease.notes}"}],
    "@semantic-release/github"
  ]
}
```

Commit type → version mapping (default `commit-analyzer`):
- `feat` → MINOR bump
- `fix`, `perf` → PATCH bump
- `BREAKING CHANGE` or `!` → MAJOR bump
- All others (`docs`, `style`, `refactor`, `test`, `build`, `ci`, `chore`) → no release

### standard-version (manual/semi-automated, local)

```bash
npm install --save-dev standard-version
```

Add to `package.json`:
```json
{ "scripts": { "release": "standard-version", "release:major": "standard-version --release-as major" } }
```

Usage: `npm run release` (auto-detect bump), `npx standard-version --dry-run` (preview).
standard-version bumps `package.json`, updates `CHANGELOG.md`, creates git tag. Then `git push --follow-tags && npm publish`.

### When to Choose Which

| Criteria         | semantic-release        | standard-version       |
|------------------|-------------------------|------------------------|
| Automation level | Full CI/CD              | Manual trigger         |
| npm publish      | Automatic               | Manual                 |
| GitHub releases  | Automatic               | Manual                 |
| Monorepo support | Via plugins             | Via Lerna              |
| Control          | Less (opinionated)      | More (flexible)        |
| Best for         | OSS, CI-first teams     | Internal, cautious     |

## Monorepo Conventions

### Scopes = Package Names

```
feat(payments): add refund endpoint
fix(shared-utils): correct date formatting
ci(repo): update root CI pipeline
```

### Dynamic Scope Enforcement

```js
// commitlint.config.js for monorepo
const { readdirSync } = require('fs');
const packages = readdirSync('./packages', { withFileTypes: true })
  .filter(d => d.isDirectory())
  .map(d => d.name);

module.exports = {
  extends: ['@commitlint/config-conventional'],
  rules: {
    'scope-enum': [2, 'always', ['repo', ...packages]],
  },
};
```

### Lerna Scope Integration

```bash
npm install --save-dev @commitlint/config-lerna-scopes
```

```js
module.exports = {
  extends: [
    '@commitlint/config-conventional',
    '@commitlint/config-lerna-scopes',
  ],
};
```

This auto-extracts valid scopes from all Lerna-managed packages.

### Multi-package Releases

For semantic-release in monorepos, use `@qiwi/multi-semantic-release`:
```bash
npx multi-semantic-release
```

Each package gets independent versioning based on commits scoped to that package.

## Skill Resources

### References (Deep Dives)

| File | Contents |
|------|----------|
| `references/advanced-patterns.md` | Custom types beyond standard 11, multi-line bodies/footers, co-authored-by trailers, ticket/issue linking (Jira, Linear, Azure DevOps), squash merge conventions, revert format, monorepo scope strategies (4 approaches), automating changelogs (conventional-changelog, git-cliff, release-please, pure git), commit message templates, deprecation workflow, security commit conventions |
| `references/tooling-guide.md` | commitlint (full rule reference, custom parsers, plugins, shareable configs, CI integration), Husky v9 (install, all hook types, CI skip, troubleshooting), Commitizen (adapters, cz-customizable, prompt customization), lint-staged (advanced patterns, monorepo configs), standard-version vs semantic-release vs release-please comparison, git-cliff (config, Tera templates, CI) |

### Scripts (Executable Helpers)

| Script | Purpose | Usage |
|--------|---------|-------|
| `scripts/setup-commitlint.sh` | Full project setup: commitlint + Husky + lint-staged + commitizen | `./scripts/setup-commitlint.sh --scopes "api,auth,ui"` |
| `scripts/validate-history.sh` | Audit git history for conventional commit compliance | `./scripts/validate-history.sh --from v1.0.0 --json` |
| `scripts/generate-changelog.sh` | Generate CHANGELOG.md from conventional commits | `./scripts/generate-changelog.sh --unreleased --output CHANGELOG.md` |

### Assets (Copy-Paste Templates)

| Asset | Description |
|-------|-------------|
| `assets/commitlint.config.js` | Production commitlint config with custom plugin rules (imperative mood check, vague subject detection), monorepo-aware dynamic scope extraction, prompt config for @commitlint/cz-commitlint |
| `assets/.czrc` | Commitizen config for cz-conventional-changelog with all 11 standard types, emoji mappings, and header/line width limits |
| `assets/commit-msg-hook` | Git commit-msg hook: commitlint integration, auto-skip for CI/merge/fixup, fallback regex |

## Quick Reference — Generating Commit Messages

When asked to write a commit message:
1. Identify the PRIMARY change type from the standard types table.
2. Determine scope from the affected module/package (omit if cross-cutting).
3. Write a concise imperative description (≤72 chars, no period).
4. Add body ONLY if motivation/context is non-obvious.
5. Add `BREAKING CHANGE:` footer if public API changes.
6. Add `Refs: #NNN` or `Closes #NNN` footer for linked issues.
7. Use `!` after type/scope for breaking changes.

When asked to validate a commit message:
1. Check type is from the allowed list.
2. Check scope format (lowercase, no spaces).
3. Check description starts lowercase, no trailing period.
4. Check header length ≤ 100 chars.
5. Check blank line between header and body.
6. Check BREAKING CHANGE footer is uppercase.
7. Check footers follow `token: value` or `token #value` format.

## Complete Setup Checklist

```bash
# 1. Install all tooling
npm install --save-dev \
  @commitlint/cli \
  @commitlint/config-conventional \
  husky \
  commitizen \
  cz-conventional-changelog

# 2. Initialize Husky
npx husky init

# 3. Add commit-msg hook
echo 'npx --no -- commitlint --edit "$1"' > .husky/commit-msg

# 4. Create commitlint config
cat > commitlint.config.js << 'EOF'
module.exports = {
  extends: ['@commitlint/config-conventional'],
};
EOF

# 5. Configure Commitizen in package.json
npm pkg set config.commitizen.path="cz-conventional-changelog"

# 6. Add commit script
npm pkg set scripts.commit="cz"

# 7. Test
echo "feat: initial setup" | npx commitlint
