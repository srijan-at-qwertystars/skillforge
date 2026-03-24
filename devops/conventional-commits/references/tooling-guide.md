# Conventional Commits Tooling Guide

## Table of Contents

- [commitlint](#commitlint)
  - [Installation](#commitlint-installation)
  - [Configuration Files](#configuration-files)
  - [Rule System](#rule-system)
  - [Custom Parsers](#custom-parsers)
  - [Plugins](#plugins)
  - [Shareable Configs](#shareable-configs)
  - [CI Integration](#commitlint-ci-integration)
- [Husky v9](#husky-v9)
  - [Installation and Init](#husky-installation-and-init)
  - [Hook Types](#hook-types)
  - [CI Skip](#ci-skip)
  - [Troubleshooting](#husky-troubleshooting)
- [Commitizen](#commitizen)
  - [Setup](#commitizen-setup)
  - [Built-in Adapters](#built-in-adapters)
  - [Custom Adapters](#custom-adapters)
  - [Prompt Customization](#prompt-customization)
- [lint-staged](#lint-staged)
  - [Configuration](#lint-staged-configuration)
  - [Integration with Husky](#lint-staged-with-husky)
  - [Advanced Patterns](#lint-staged-advanced-patterns)
- [standard-version vs semantic-release](#standard-version-vs-semantic-release)
  - [standard-version Deep Dive](#standard-version-deep-dive)
  - [semantic-release Deep Dive](#semantic-release-deep-dive)
  - [Comparison Matrix](#comparison-matrix)
  - [Migration Between Tools](#migration-between-tools)
- [release-please](#release-please)
  - [How It Works](#how-release-please-works)
  - [Configuration](#release-please-configuration)
  - [Monorepo Support](#release-please-monorepo)
- [git-cliff](#git-cliff)
  - [Installation](#git-cliff-installation)
  - [Configuration](#git-cliff-configuration)
  - [Templates](#git-cliff-templates)
  - [Integration with CI](#git-cliff-ci)

---

## commitlint

### commitlint Installation

```bash
# npm
npm install --save-dev @commitlint/cli @commitlint/config-conventional

# yarn
yarn add -D @commitlint/cli @commitlint/config-conventional

# pnpm
pnpm add -D @commitlint/cli @commitlint/config-conventional
```

### Configuration Files

commitlint searches for config in this order:

1. `commitlint.config.js` / `commitlint.config.cjs` / `commitlint.config.mjs`
2. `.commitlintrc.js` / `.commitlintrc.cjs` / `.commitlintrc.mjs`
3. `.commitlintrc.yml` / `.commitlintrc.yaml`
4. `.commitlintrc.json`
5. `commitlint` field in `package.json`

**ESM projects** (package.json has `"type": "module"`) — use `.cjs` extension or `commitlint.config.mjs`:

```js
// commitlint.config.mjs
export default {
  extends: ['@commitlint/config-conventional'],
};
```

### Rule System

Every rule is a tuple: `[severity, applicable, value]`.

| Severity | Meaning                    |
|----------|----------------------------|
| `0`      | Disabled                   |
| `1`      | Warning (non-blocking)     |
| `2`      | Error (blocks commit)      |

| Applicable | Meaning                                |
|------------|----------------------------------------|
| `'always'` | Rule must be satisfied                 |
| `'never'`  | Rule must NOT be satisfied (inverted)  |

**All available rules:**

```js
module.exports = {
  extends: ['@commitlint/config-conventional'],
  rules: {
    // --- Header ---
    'header-case': [0],                           // disabled by default
    'header-full-stop': [2, 'never', '.'],        // no trailing period
    'header-max-length': [2, 'always', 100],      // max 100 chars
    'header-min-length': [0],                     // no minimum
    'header-trim': [2, 'always'],                 // no leading/trailing whitespace

    // --- Type ---
    'type-case': [2, 'always', 'lower-case'],
    'type-empty': [2, 'never'],                   // type is required
    'type-enum': [2, 'always', [
      'feat', 'fix', 'docs', 'style', 'refactor',
      'perf', 'test', 'build', 'ci', 'chore', 'revert',
    ]],
    'type-max-length': [0],
    'type-min-length': [0],

    // --- Scope ---
    'scope-case': [2, 'always', 'lower-case'],
    'scope-empty': [0],                           // scope is optional
    'scope-enum': [0],                            // no restrictions by default
    'scope-max-length': [0],
    'scope-min-length': [0],

    // --- Subject (description) ---
    'subject-case': [2, 'never', ['start-case', 'pascal-case', 'upper-case']],
    'subject-empty': [2, 'never'],                // description required
    'subject-full-stop': [2, 'never', '.'],       // no trailing period
    'subject-max-length': [0],
    'subject-min-length': [0],
    'subject-exclamation-mark': [0],              // allow ! for breaking

    // --- Body ---
    'body-case': [0],
    'body-empty': [0],                            // body is optional
    'body-full-stop': [0],
    'body-leading-blank': [2, 'always'],          // blank line before body
    'body-max-length': [0],
    'body-max-line-length': [2, 'always', 200],
    'body-min-length': [0],

    // --- Footer ---
    'footer-empty': [0],
    'footer-leading-blank': [2, 'always'],        // blank line before footer
    'footer-max-length': [0],
    'footer-max-line-length': [2, 'always', 200],
    'footer-min-length': [0],

    // --- Trailer ---
    'signed-off-by': [0],                         // DCO
    'trailer-exists': [0],                        // require specific trailer

    // --- References ---
    'references-empty': [0],                      // issue references
  },
};
```

### Custom Parsers

Override the default parser for non-standard formats:

```js
// commitlint.config.js
module.exports = {
  extends: ['@commitlint/config-conventional'],
  parserPreset: {
    parserOpts: {
      // Custom header pattern: TYPE(SCOPE): JIRA-123 description
      headerPattern: /^(\w+)(?:\(([^)]*)\))?:\s((?:[A-Z]+-\d+\s)?.+)$/,
      headerCorrespondence: ['type', 'scope', 'subject'],
      // Custom note keywords (footers that trigger major bump)
      noteKeywords: ['BREAKING CHANGE', 'BREAKING-CHANGE'],
      // Custom reference patterns
      issuePrefixes: ['#', 'JIRA-', 'GH-'],
    },
  },
};
```

**Parser for emoji-prefixed commits:**

```js
parserPreset: {
  parserOpts: {
    // Match: ✨ feat(scope): description
    headerPattern: /^(?:[\u{1F300}-\u{1F9FF}]\s)?(\w+)(?:\(([^)]*)\))?!?:\s(.+)$/u,
    headerCorrespondence: ['type', 'scope', 'subject'],
  },
},
```

### Plugins

Plugins add custom rules. A plugin is an object with a `rules` property:

```js
// commitlint-plugin-jira.js
module.exports = {
  rules: {
    'jira-scope': ({ scope }) => {
      if (!scope) return [true];
      const valid = /^[A-Z]+-\d+$/.test(scope);
      return [valid, `scope must be a Jira ticket (got: ${scope})`];
    },
    'jira-footer-required': ({ raw, type }) => {
      if (['docs', 'style', 'chore'].includes(type)) return [true];
      const hasJira = /^Jira:\s+[A-Z]+-\d+$/m.test(raw);
      return [hasJira, 'feat/fix commits must reference a Jira ticket in footer'];
    },
  },
};
```

**Using the plugin:**

```js
// commitlint.config.js
const jiraPlugin = require('./commitlint-plugin-jira');

module.exports = {
  extends: ['@commitlint/config-conventional'],
  plugins: [jiraPlugin],
  rules: {
    'jira-footer-required': [1, 'always'],
  },
};
```

**Community plugins:**
- `commitlint-plugin-function-rules` — use functions for any rule
- `@commitlint/config-lerna-scopes` — auto-extract scopes from Lerna monorepo
- `@commitlint/config-nx-scopes` — auto-extract scopes from Nx workspace
- `@commitlint/config-pnpm-scopes` — auto-extract scopes from pnpm workspace

### Shareable Configs

| Config                                     | Description                                  |
|--------------------------------------------|----------------------------------------------|
| `@commitlint/config-conventional`          | Standard Conventional Commits rules          |
| `@commitlint/config-angular`               | Angular commit conventions                   |
| `@commitlint/config-lerna-scopes`          | Lerna package scopes                         |
| `@commitlint/config-nx-scopes`             | Nx project scopes                            |
| `@commitlint/config-pnpm-scopes`           | pnpm workspace scopes                        |
| `@commitlint/config-patternplate`          | patternplate conventions                     |

**Creating your own shareable config:**

```js
// @myorg/commitlint-config/index.js
module.exports = {
  extends: ['@commitlint/config-conventional'],
  rules: {
    'type-enum': [2, 'always', [
      'feat', 'fix', 'docs', 'style', 'refactor',
      'perf', 'test', 'build', 'ci', 'chore', 'revert',
      'hotfix', 'security',
    ]],
    'scope-empty': [1, 'never'],
    'header-max-length': [2, 'always', 120],
  },
};
```

### commitlint CI Integration

**GitHub Actions:**

```yaml
# .github/workflows/commitlint.yml
name: Commitlint
on: [pull_request]

jobs:
  commitlint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: actions/setup-node@v4
        with:
          node-version: 20
      - run: npm ci
      - run: npx commitlint --from ${{ github.event.pull_request.base.sha }} --to ${{ github.event.pull_request.head.sha }} --verbose
```

**GitLab CI:**

```yaml
commitlint:
  stage: test
  script:
    - npm ci
    - npx commitlint --from "$CI_MERGE_REQUEST_DIFF_BASE_SHA" --to "$CI_COMMIT_SHA" --verbose
  only:
    - merge_requests
```

**Testing locally:**

```bash
# Lint last commit
npx commitlint --from HEAD~1

# Lint range
npx commitlint --from HEAD~5 --to HEAD

# Lint from stdin
echo "feat: add feature" | npx commitlint

# Lint with verbose output
npx commitlint --from HEAD~1 --verbose

# Dry run (parse only, don't enforce)
echo "feat: test" | npx commitlint --verbose 2>&1 | head
```

---

## Husky v9

### Husky Installation and Init

```bash
# Install
npm install --save-dev husky

# Initialize — creates .husky/ directory and adds "prepare" script
npx husky init
```

This adds to `package.json`:
```json
{
  "scripts": {
    "prepare": "husky"
  }
}
```

And creates `.husky/pre-commit` with a sample hook.

### Hook Types

Commonly used git hooks with Husky:

| Hook              | Trigger                       | Common Use                          |
|-------------------|-------------------------------|-------------------------------------|
| `pre-commit`      | Before commit is created      | lint-staged, format, type-check     |
| `commit-msg`      | After message is entered      | commitlint validation               |
| `pre-push`        | Before push to remote         | Run tests, build check              |
| `prepare-commit-msg` | Before editor opens        | Add template, ticket from branch    |
| `post-commit`     | After commit is created       | Notifications, stats                |
| `post-merge`      | After merge completes         | `npm install` (dependency refresh)  |
| `post-checkout`   | After checkout/switch         | `npm install` if lockfile changed   |

**Creating hooks:**

```bash
# commit-msg hook for commitlint
echo 'npx --no -- commitlint --edit "$1"' > .husky/commit-msg

# pre-commit hook for lint-staged
echo 'npx lint-staged' > .husky/pre-commit

# pre-push hook for tests
echo 'npm test' > .husky/pre-push

# prepare-commit-msg: auto-add Jira ticket from branch name
cat > .husky/prepare-commit-msg << 'HOOK'
#!/bin/sh
BRANCH=$(git branch --show-current)
TICKET=$(echo "$BRANCH" | grep -oE '[A-Z]+-[0-9]+')
if [ -n "$TICKET" ] && ! grep -q "$TICKET" "$1"; then
  echo "" >> "$1"
  echo "Jira: $TICKET" >> "$1"
fi
HOOK

# post-merge hook: reinstall deps if lockfile changed
cat > .husky/post-merge << 'HOOK'
#!/bin/sh
CHANGED=$(git diff-tree -r --name-only --no-commit-id ORIG_HEAD HEAD)
if echo "$CHANGED" | grep -q "package-lock.json"; then
  echo "📦 package-lock.json changed — running npm install..."
  npm install
fi
HOOK
```

### CI Skip

In CI environments, Husky hooks should not run. Husky v9 handles this automatically:

**Automatic skip:** Husky checks for the `CI` environment variable. When `CI=true` (set by GitHub Actions, GitLab CI, etc.), hooks are skipped automatically.

**Manual skip methods:**

```bash
# Skip all hooks for one commit
HUSKY=0 git commit -m "feat: skip hooks"

# Skip specific hook
git commit -m "feat: test" --no-verify  # skips pre-commit and commit-msg

# Disable for entire session
export HUSKY=0
```

**In CI config (if auto-skip doesn't work):**

```yaml
# GitHub Actions
env:
  HUSKY: 0

# Or in package.json — skip install entirely
{
  "scripts": {
    "prepare": "node -e \"try { require('husky') } catch (e) { if (e.code !== 'MODULE_NOT_FOUND') throw e }\""
  }
}

# Simpler: use husky's built-in CI check
{
  "scripts": {
    "prepare": "husky || true"
  }
}
```

### Husky Troubleshooting

**Hooks not running:**
```bash
# Verify .husky directory exists and has hooks
ls -la .husky/

# Verify prepare script exists
npm pkg get scripts.prepare

# Reinstall
npx husky init

# Check git hook path
git config core.hooksPath  # should be .husky
```

**Permission errors (macOS/Linux):**
```bash
# Hooks are shell scripts, no chmod needed in Husky v9
# But if using custom scripts:
chmod +x .husky/*
```

**Monorepo with Husky at root:**
```bash
# If package.json is not at repo root:
# In package.json at subdirectory:
{
  "scripts": {
    "prepare": "cd .. && husky ./frontend/.husky"
  }
}
```

---

## Commitizen

### Commitizen Setup

```bash
# Install globally (for personal use)
npm install -g commitizen

# Install locally (for team)
npm install --save-dev commitizen cz-conventional-changelog
```

Configure adapter in `package.json`:
```json
{
  "config": {
    "commitizen": {
      "path": "cz-conventional-changelog"
    }
  }
}
```

Or use `.czrc`:
```json
{
  "path": "cz-conventional-changelog"
}
```

**Usage:** `npx cz` or `git cz` (if installed globally).

### Built-in Adapters

| Adapter                         | Description                              |
|---------------------------------|------------------------------------------|
| `cz-conventional-changelog`    | Standard conventional commits            |
| `@commitlint/cz-commitlint`   | Syncs prompts with commitlint rules      |
| `cz-customizable`             | Fully customizable prompts               |
| `cz-emoji`                    | Emoji-based commit types                 |
| `cz-format-extension`         | Extensible format                        |

### Custom Adapters

**cz-customizable** — full control over prompts:

```bash
npm install --save-dev cz-customizable
```

```js
// .cz-config.js
module.exports = {
  types: [
    { value: 'feat',     name: 'feat:     A new feature' },
    { value: 'fix',      name: 'fix:      A bug fix' },
    { value: 'docs',     name: 'docs:     Documentation only' },
    { value: 'style',    name: 'style:    Formatting changes' },
    { value: 'refactor', name: 'refactor: Code restructuring' },
    { value: 'perf',     name: 'perf:     Performance improvement' },
    { value: 'test',     name: 'test:     Adding/fixing tests' },
    { value: 'build',    name: 'build:    Build system changes' },
    { value: 'ci',       name: 'ci:       CI configuration' },
    { value: 'chore',    name: 'chore:    Maintenance tasks' },
    { value: 'revert',   name: 'revert:   Revert a commit' },
    { value: 'hotfix',   name: 'hotfix:   Emergency fix' },
    { value: 'security', name: 'security: Security patch' },
  ],
  scopes: [
    { name: 'api' },
    { name: 'auth' },
    { name: 'billing' },
    { name: 'core' },
    { name: 'db' },
    { name: 'ui' },
  ],
  allowCustomScopes: true,
  allowBreakingChanges: ['feat', 'fix', 'refactor'],
  subjectLimit: 72,
  breaklineChar: '|',
  footerPrefix: 'Refs:',
  askForBreakingChangeFirst: false,

  // Skip questions
  skipQuestions: ['body'],

  // Custom messages
  messages: {
    type: "Select the type of change you're committing:",
    scope: 'Scope of this change (optional):',
    customScope: 'Custom scope:',
    subject: 'Short description (imperative, lowercase):\n',
    body: 'Longer description (optional). Use "|" for new lines:\n',
    breaking: 'List any BREAKING CHANGES (optional):\n',
    footer: 'Issues this commit closes (e.g., #123):\n',
    confirmCommit: 'Proceed with the commit above?',
  },
};
```

**@commitlint/cz-commitlint** — derive prompts from commitlint config:

```bash
npm install --save-dev @commitlint/cz-commitlint inquirer@9
```

```json
{
  "config": {
    "commitizen": {
      "path": "@commitlint/cz-commitlint"
    }
  }
}
```

This reads your commitlint config and auto-generates the interactive prompts, keeping commitlint rules and commitizen prompts in sync.

### Prompt Customization

**Customizing @commitlint/cz-commitlint prompts via commitlint config:**

```js
// commitlint.config.js
module.exports = {
  extends: ['@commitlint/config-conventional'],
  prompt: {
    settings: {
      enableMultipleScopes: true,
      scopeEnumSeparator: ',',
    },
    messages: {
      skip: '(press enter to skip)',
      max: '(max %d chars)',
      min: '(min %d chars)',
      emptyWarning: 'cannot be empty',
      upperLimitWarning: 'over the limit',
      lowerLimitWarning: 'below the limit',
    },
    questions: {
      type: {
        description: "Select the type of change you're committing",
        enum: {
          feat: { description: 'A new feature', title: 'Features', emoji: '✨' },
          fix: { description: 'A bug fix', title: 'Bug Fixes', emoji: '🐛' },
          docs: { description: 'Documentation only', title: 'Docs', emoji: '📚' },
          // ... etc
        },
      },
    },
  },
};
```

---

## lint-staged

### lint-staged Configuration

lint-staged runs linters/formatters only on staged files, making pre-commit hooks fast.

```bash
npm install --save-dev lint-staged
```

**Configuration locations** (in order of precedence):
1. `lint-staged` field in `package.json`
2. `.lintstagedrc` (JSON or YAML)
3. `.lintstagedrc.js` / `.lintstagedrc.cjs` / `.lintstagedrc.mjs`
4. `lint-staged.config.js` / `lint-staged.config.cjs` / `lint-staged.config.mjs`

**Basic config in package.json:**

```json
{
  "lint-staged": {
    "*.{js,jsx,ts,tsx}": ["eslint --fix", "prettier --write"],
    "*.{json,md,yml,yaml}": ["prettier --write"],
    "*.css": ["stylelint --fix", "prettier --write"],
    "*.py": ["ruff check --fix", "ruff format"]
  }
}
```

### lint-staged with Husky

```bash
# .husky/pre-commit
npx lint-staged
```

Combined workflow: staged files → lint-staged (format + lint) → commit-msg → commitlint.

### lint-staged Advanced Patterns

**Function-based config for complex logic:**

```js
// lint-staged.config.js
module.exports = {
  '*.{ts,tsx}': (filenames) => {
    const files = filenames.join(' ');
    return [
      `eslint --fix ${files}`,
      `prettier --write ${files}`,
      // Run tsc on entire project (not per-file)
      'tsc --noEmit',
    ];
  },
  '*.test.{ts,tsx}': (filenames) => {
    // Run only affected tests
    return `jest --bail --findRelatedTests ${filenames.join(' ')}`;
  },
};
```

**Ignore patterns:**

```json
{
  "lint-staged": {
    "*.js": ["eslint --fix"],
    "!(*test).js": ["prettier --write"]
  }
}
```

**Monorepo with different configs per package:**

```js
// Root lint-staged.config.js
module.exports = {
  'packages/frontend/**/*.{ts,tsx}': ['eslint --fix --config packages/frontend/.eslintrc'],
  'packages/backend/**/*.ts': ['eslint --fix --config packages/backend/.eslintrc'],
  '*.md': ['prettier --write'],
};
```

---

## standard-version vs semantic-release

### standard-version Deep Dive

> **Note:** standard-version is deprecated. Consider `release-please` or `commit-and-tag-version` (a maintained fork) as alternatives.

```bash
npm install --save-dev standard-version
# Or the maintained fork:
npm install --save-dev commit-and-tag-version
```

**How it works:**
1. Reads commits since last tag
2. Determines version bump from commit types
3. Updates `CHANGELOG.md`
4. Bumps version in `package.json` (and `package-lock.json`)
5. Creates git commit and tag
6. You manually push and publish

**Commands:**

```bash
# Auto-detect bump
npx standard-version

# Force specific bump
npx standard-version --release-as major
npx standard-version --release-as minor
npx standard-version --release-as patch

# Pre-release
npx standard-version --prerelease alpha   # 1.0.1-alpha.0
npx standard-version --prerelease beta    # 1.0.1-beta.0

# First release
npx standard-version --first-release

# Dry run (preview)
npx standard-version --dry-run

# Skip steps
npx standard-version --skip.changelog --skip.tag

# After standard-version:
git push --follow-tags origin main
npm publish
```

**Configuration (.versionrc.js):**

```js
module.exports = {
  types: [
    { type: 'feat', section: 'Features' },
    { type: 'fix', section: 'Bug Fixes' },
    { type: 'perf', section: 'Performance' },
    { type: 'revert', section: 'Reverts' },
    { type: 'docs', section: 'Documentation', hidden: false },
    { type: 'style', hidden: true },
    { type: 'refactor', section: 'Code Refactoring', hidden: false },
    { type: 'test', hidden: true },
    { type: 'build', hidden: true },
    { type: 'ci', hidden: true },
    { type: 'chore', hidden: true },
  ],
  commitUrlFormat: 'https://github.com/{{owner}}/{{repository}}/commit/{{hash}}',
  compareUrlFormat: 'https://github.com/{{owner}}/{{repository}}/compare/{{previousTag}}...{{currentTag}}',
  issueUrlFormat: 'https://github.com/{{owner}}/{{repository}}/issues/{{id}}',
  releaseCommitMessageFormat: 'chore(release): {{currentTag}}',
  // Bump files beyond package.json
  bumpFiles: [
    { filename: 'package.json', type: 'json' },
    { filename: 'version.txt', type: 'plain-text' },
    { filename: 'src/version.ts', updater: 'standard-version-updater.js' },
  ],
};
```

### semantic-release Deep Dive

Fully automated — runs in CI, publishes to npm, creates GitHub releases.

```bash
npm install --save-dev semantic-release
```

**Core plugins (run in order):**

| Plugin                                     | Phase         | Purpose                        |
|--------------------------------------------|---------------|--------------------------------|
| `@semantic-release/commit-analyzer`       | analyzeCommits| Determine version bump         |
| `@semantic-release/release-notes-generator`| generateNotes | Create release notes           |
| `@semantic-release/changelog`             | prepare       | Update CHANGELOG.md            |
| `@semantic-release/npm`                   | prepare/publish| Bump package.json, npm publish |
| `@semantic-release/git`                   | prepare       | Commit modified files          |
| `@semantic-release/github`               | publish       | Create GitHub release          |
| `@semantic-release/gitlab`               | publish       | Create GitLab release          |
| `@semantic-release/exec`                 | any           | Run custom shell commands      |

**Full .releaserc.json:**

```json
{
  "branches": [
    "main",
    "master",
    { "name": "next", "prerelease": true },
    { "name": "beta", "prerelease": true },
    { "name": "alpha", "prerelease": true },
    { "name": "*.x", "range": "${name}" }
  ],
  "plugins": [
    ["@semantic-release/commit-analyzer", {
      "preset": "conventionalcommits",
      "releaseRules": [
        { "type": "feat", "release": "minor" },
        { "type": "fix", "release": "patch" },
        { "type": "perf", "release": "patch" },
        { "type": "revert", "release": "patch" },
        { "type": "security", "release": "patch" },
        { "type": "hotfix", "release": "patch" },
        { "breaking": true, "release": "major" },
        { "type": "docs", "scope": "README", "release": "patch" },
        { "type": "refactor", "release": false },
        { "type": "style", "release": false },
        { "type": "test", "release": false },
        { "type": "build", "release": false },
        { "type": "ci", "release": false },
        { "type": "chore", "release": false }
      ]
    }],
    ["@semantic-release/release-notes-generator", {
      "preset": "conventionalcommits",
      "presetConfig": {
        "types": [
          { "type": "feat", "section": "Features" },
          { "type": "fix", "section": "Bug Fixes" },
          { "type": "perf", "section": "Performance" },
          { "type": "security", "section": "Security" },
          { "type": "revert", "section": "Reverts" }
        ]
      }
    }],
    ["@semantic-release/changelog", {
      "changelogFile": "CHANGELOG.md"
    }],
    "@semantic-release/npm",
    ["@semantic-release/git", {
      "assets": ["CHANGELOG.md", "package.json", "package-lock.json"],
      "message": "chore(release): ${nextRelease.version} [skip ci]\n\n${nextRelease.notes}"
    }],
    "@semantic-release/github"
  ]
}
```

**GitHub Actions workflow:**

```yaml
name: Release
on:
  push:
    branches: [main]

permissions:
  contents: write
  issues: write
  pull-requests: write
  id-token: write

jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
          persist-credentials: false
      - uses: actions/setup-node@v4
        with:
          node-version: 20
      - run: npm ci
      - run: npx semantic-release
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          NPM_TOKEN: ${{ secrets.NPM_TOKEN }}
```

**Required tokens:**
- `GITHUB_TOKEN` — auto-provided by GitHub Actions (for GitHub releases)
- `NPM_TOKEN` — npm automation token (for npm publish)

### Comparison Matrix

| Feature                     | standard-version           | semantic-release           | release-please             |
|-----------------------------|----------------------------|----------------------------|----------------------------|
| **Automation level**        | Manual trigger             | Fully automated in CI      | Semi-auto (PR-based)       |
| **npm publish**             | Manual                     | Automatic                  | Manual / configurable      |
| **GitHub/GitLab releases**  | Manual                     | Automatic                  | Automatic                  |
| **Changelog**               | CHANGELOG.md               | CHANGELOG.md + release notes| CHANGELOG.md              |
| **Pre-releases**            | `--prerelease alpha`       | Branch-based               | Branch-based               |
| **Monorepo**                | Via Lerna                  | `multi-semantic-release`   | Native support             |
| **Dry run**                 | `--dry-run`                | `--dry-run`                | Via API                    |
| **Customization**           | `.versionrc`               | `.releaserc` + plugins     | `release-please-config.json`|
| **Status**                  | ⚠️ Deprecated              | ✅ Active                   | ✅ Active                   |
| **Hosted by**               | Community                  | Community                  | Google                     |
| **Best for**                | Simple projects            | OSS, CI-first teams        | GitHub-native workflows    |

### Migration Between Tools

**standard-version → semantic-release:**

1. Remove standard-version: `npm uninstall standard-version`
2. Install semantic-release: `npm install --save-dev semantic-release @semantic-release/changelog @semantic-release/git`
3. Create `.releaserc.json` (see config above)
4. Add CI workflow
5. Remove manual release scripts from `package.json`
6. Ensure existing tags follow `vX.Y.Z` format

**standard-version → commit-and-tag-version (drop-in fork):**

```bash
npm uninstall standard-version
npm install --save-dev commit-and-tag-version
# Update scripts: replace "standard-version" with "commit-and-tag-version"
```

---

## release-please

### How release-please Works

1. On every push to main, release-please analyzes conventional commits
2. It creates/updates a "Release PR" with version bump and changelog
3. Merging the Release PR triggers the actual release (tag + GitHub release)
4. No tokens beyond `GITHUB_TOKEN` needed

### release-please Configuration

**release-please-config.json:**

```json
{
  "$schema": "https://raw.githubusercontent.com/googleapis/release-please/main/schemas/config.json",
  "release-type": "node",
  "bump-minor-pre-major": true,
  "bump-patch-for-minor-pre-major": true,
  "draft": false,
  "prerelease": false,
  "changelog-sections": [
    { "type": "feat", "section": "Features" },
    { "type": "fix", "section": "Bug Fixes" },
    { "type": "perf", "section": "Performance Improvements" },
    { "type": "revert", "section": "Reverts" },
    { "type": "docs", "section": "Documentation" },
    { "type": "chore", "section": "Miscellaneous", "hidden": true },
    { "type": "refactor", "section": "Code Refactoring", "hidden": true },
    { "type": "test", "section": "Tests", "hidden": true },
    { "type": "build", "section": "Build System", "hidden": true },
    { "type": "ci", "section": "CI", "hidden": true }
  ],
  "extra-files": ["src/version.ts", "version.txt"]
}
```

### release-please Monorepo

**.release-please-manifest.json:**
```json
{
  "packages/api": "1.2.3",
  "packages/web": "2.0.1",
  "packages/shared": "0.5.0"
}
```

**release-please-config.json for monorepo:**
```json
{
  "packages": {
    "packages/api": { "release-type": "node" },
    "packages/web": { "release-type": "node" },
    "packages/shared": { "release-type": "node" }
  }
}
```

---

## git-cliff

### git-cliff Installation

```bash
# Cargo
cargo install git-cliff

# npm
npm install --save-dev git-cliff

# Homebrew
brew install git-cliff

# Pre-built binaries
# https://github.com/orhun/git-cliff/releases
```

### git-cliff Configuration

**cliff.toml** (full example):

```toml
[changelog]
header = """
# Changelog\n
All notable changes to this project will be documented in this file.\n
"""
body = """
{%- macro remote_url() -%}
  https://github.com/{{ remote.github.owner }}/{{ remote.github.repo }}
{%- endmacro -%}

{% if version -%}
    ## [{{ version | trim_start_matches(pat="v") }}] - {{ timestamp | date(format="%Y-%m-%d") }}
{% else -%}
    ## [Unreleased]
{% endif -%}

{% for group, commits in commits | group_by(attribute="group") %}
    ### {{ group | striptags | trim | upper_first }}
    {% for commit in commits
    | filter(attribute="scope")
    | sort(attribute="scope") %}
        - **{{commit.scope}}:** {{ commit.message | upper_first }} ([{{ commit.id | truncate(length=7, end="") }}]({{ self::remote_url() }}/commit/{{ commit.id }}))
        {%- if commit.breaking %}
        {% raw %}  {% endraw %}- ⚠️ **BREAKING:** {{ commit.breaking_description }}
        {%- endif -%}
    {%- endfor -%}
    {% for commit in commits %}
        {%- if not commit.scope -%}
        - {{ commit.message | upper_first }} ([{{ commit.id | truncate(length=7, end="") }}]({{ self::remote_url() }}/commit/{{ commit.id }}))
        {%- if commit.breaking %}
        {% raw %}  {% endraw %}- ⚠️ **BREAKING:** {{ commit.breaking_description }}
        {%- endif -%}
        {% endif -%}
    {% endfor -%}
{% endfor %}\n
"""
footer = ""
trim = true
postprocessors = [
  { pattern = '<REPO>', replace = "https://github.com/owner/repo" },
]

[git]
conventional_commits = true
filter_unconventional = true
split_commits = false
commit_preprocessors = [
  { pattern = '\((\w+\s)?#([0-9]+)\)', replace = "([#${2}](https://github.com/owner/repo/issues/${2}))" },
]
commit_parsers = [
  { message = "^feat", group = "<!-- 0 -->🚀 Features" },
  { message = "^fix", group = "<!-- 1 -->🐛 Bug Fixes" },
  { message = "^perf", group = "<!-- 2 -->⚡ Performance" },
  { message = "^doc", group = "<!-- 3 -->📚 Documentation" },
  { message = "^refactor", group = "<!-- 4 -->🔨 Refactoring" },
  { message = "^style", group = "<!-- 5 -->🎨 Style" },
  { message = "^test", group = "<!-- 6 -->🧪 Tests" },
  { message = "^build", group = "<!-- 7 -->📦 Build" },
  { message = "^ci", group = "<!-- 8 -->👷 CI" },
  { message = "^chore\\(release\\)", skip = true },
  { message = "^chore|^ci", group = "<!-- 9 -->⚙️ Miscellaneous" },
  { body = ".*security", group = "<!-- 10 -->🔒 Security" },
]
protect_breaking_commits = false
filter_commits = false
tag_pattern = "v[0-9].*"
skip_tags = ""
ignore_tags = ""
topo_order = false
sort_commits = "oldest"

[remote.github]
owner = "owner"
repo = "repo"
```

### git-cliff Templates

git-cliff uses Tera templates (Jinja2-like). Key variables:

| Variable                     | Description                                  |
|------------------------------|----------------------------------------------|
| `{{ version }}`              | Current version tag                          |
| `{{ timestamp }}`            | Release timestamp                            |
| `{{ commits }}`              | List of commits                              |
| `{{ commit.message }}`       | Commit subject line                          |
| `{{ commit.body }}`          | Commit body                                  |
| `{{ commit.id }}`            | Full commit SHA                              |
| `{{ commit.scope }}`         | Parsed scope                                 |
| `{{ commit.group }}`         | Group assigned by commit_parsers             |
| `{{ commit.breaking }}`      | Boolean: is breaking change                  |
| `{{ commit.breaking_description }}` | Breaking change description           |
| `{{ remote.github.owner }}`  | GitHub owner                                 |

### git-cliff CI

**GitHub Actions — auto-update changelog on release:**

```yaml
name: Changelog
on:
  push:
    tags: ['v*']

jobs:
  changelog:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: orhun/git-cliff-action@v3
        with:
          config: cliff.toml
          args: --latest --strip header
        env:
          OUTPUT: CHANGES.md
      - uses: softprops/action-gh-release@v2
        with:
          body_path: CHANGES.md
```

**Usage commands:**

```bash
# Generate full changelog
git-cliff -o CHANGELOG.md

# Generate for latest tag only
git-cliff --latest

# Generate unreleased changes
git-cliff --unreleased

# Generate for specific range
git-cliff v1.0.0..v2.0.0

# Prepend to existing changelog
git-cliff --prepend CHANGELOG.md

# Bump version automatically
git-cliff --bump

# Output to stdout (for piping)
git-cliff --latest --strip header
```
