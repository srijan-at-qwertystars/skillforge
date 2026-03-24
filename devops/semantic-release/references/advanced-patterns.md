# Advanced semantic-release Patterns

## Table of Contents

- [Custom Plugin Development](#custom-plugin-development)
- [Commit Analyzer Customization](#commit-analyzer-customization)
- [Release Rules Deep Dive](#release-rules-deep-dive)
- [Monorepo Strategies](#monorepo-strategies)
- [Pre-release Channels](#pre-release-channels)
- [Maintenance Branches & Backport Workflows](#maintenance-branches--backport-workflows)
- [Programmatic API Usage](#programmatic-api-usage)
- [Advanced Branch Configuration](#advanced-branch-configuration)
- [Conditional Release Workflows](#conditional-release-workflows)
- [Performance Optimization](#performance-optimization)

---

## Custom Plugin Development

### Plugin Anatomy

Every semantic-release plugin is a module exporting one or more lifecycle hooks:

```js
// my-custom-plugin.js
const AggregateError = require("aggregate-error");

module.exports = {
  verifyConditions: async (pluginConfig, context) => { /* ... */ },
  analyzeCommits: async (pluginConfig, context) => { /* ... */ },
  verifyRelease: async (pluginConfig, context) => { /* ... */ },
  generateNotes: async (pluginConfig, context) => { /* ... */ },
  prepare: async (pluginConfig, context) => { /* ... */ },
  publish: async (pluginConfig, context) => { /* ... */ },
  addChannel: async (pluginConfig, context) => { /* ... */ },
  success: async (pluginConfig, context) => { /* ... */ },
  fail: async (pluginConfig, context) => { /* ... */ },
};
```

### Context Object Reference

Every hook receives `(pluginConfig, context)`. The context object contains:

| Property | Type | Available In | Description |
|---|---|---|---|
| `cwd` | `string` | All | Current working directory |
| `env` | `object` | All | Environment variables |
| `logger` | `object` | All | Logger instance (`.log()`, `.error()`) |
| `options` | `object` | All | Resolved semantic-release options |
| `branch` | `object` | All | Current branch (`name`, `channel`, `prerelease`, `range`) |
| `branches` | `array` | All | All configured branches |
| `lastRelease` | `object` | analyzeCommits+ | Last release (`version`, `gitTag`, `gitHead`, `channel`) |
| `commits` | `array` | analyzeCommits+ | Commits since last release |
| `nextRelease` | `object` | verifyRelease+ | Next release (`type`, `version`, `gitTag`, `channel`, `notes`) |
| `releases` | `array` | success, fail | Published releases from publish step |

### Full Custom Plugin Example: Deploy Notifier

```js
// plugins/deploy-notifier.js
const fetch = require("node-fetch");

const VALID_RELEASE_TYPES = ["major", "minor", "patch"];

async function verifyConditions(pluginConfig, { logger }) {
  const { webhookUrl, environment } = pluginConfig;

  if (!webhookUrl) {
    throw new AggregateError([new Error("'webhookUrl' is required in plugin config")]);
  }
  if (!environment) {
    throw new AggregateError([new Error("'environment' is required in plugin config")]);
  }

  logger.log("Deploy notifier configuration verified");
}

async function success(pluginConfig, { nextRelease, releases, logger, commits }) {
  const { webhookUrl, environment } = pluginConfig;

  const payload = {
    version: nextRelease.version,
    type: nextRelease.type,
    channel: nextRelease.channel || "default",
    environment,
    commitCount: commits.length,
    publishedTo: releases.map((r) => r.name),
    timestamp: new Date().toISOString(),
  };

  logger.log("Sending deploy notification for v%s to %s", nextRelease.version, environment);

  const response = await fetch(webhookUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });

  if (!response.ok) {
    logger.error("Notification failed: %s %s", response.status, response.statusText);
    // Don't throw — notification failure shouldn't block the release
  }
}

async function fail(pluginConfig, { errors, logger }) {
  const { webhookUrl, environment } = pluginConfig;

  await fetch(webhookUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      status: "failed",
      environment,
      errors: errors.map((e) => e.message),
      timestamp: new Date().toISOString(),
    }),
  });

  logger.log("Failure notification sent");
}

module.exports = { verifyConditions, success, fail };
```

Usage in `.releaserc.json`:
```json
["./plugins/deploy-notifier.js", {
  "webhookUrl": "https://hooks.slack.com/services/XXX",
  "environment": "production"
}]
```

### Plugin as npm Package

Structure for a publishable plugin:

```
semantic-release-my-plugin/
├── index.js          # Main entry — exports lifecycle hooks
├── lib/
│   ├── verify.js     # verifyConditions implementation
│   ├── publish.js    # publish implementation
│   └── utils.js      # Shared helpers
├── package.json
└── README.md
```

`package.json` must include:
```json
{
  "name": "semantic-release-my-plugin",
  "main": "index.js",
  "peerDependencies": {
    "semantic-release": ">=20.0.0"
  },
  "keywords": ["semantic-release", "plugin"]
}
```

### Error Handling in Plugins

Use `SemanticReleaseError` for user-facing errors:

```js
const SemanticReleaseError = require("@semantic-release/error");

async function verifyConditions(pluginConfig, context) {
  if (!process.env.API_KEY) {
    throw new SemanticReleaseError(
      "API_KEY environment variable is not set",    // message
      "ENOAPIKEY",                                   // error code
      "Set the API_KEY env var with your API key"    // details
    );
  }
}
```

For multiple errors, use `AggregateError`:

```js
const AggregateError = require("aggregate-error");

const errors = [];
if (!process.env.KEY_A) errors.push(new Error("KEY_A missing"));
if (!process.env.KEY_B) errors.push(new Error("KEY_B missing"));
if (errors.length > 0) throw new AggregateError(errors);
```

---

## Commit Analyzer Customization

### Presets

The `@semantic-release/commit-analyzer` supports these presets:

| Preset | Package | Description |
|---|---|---|
| `angular` | `conventional-changelog-angular` | Default. `feat`→minor, `fix`→patch |
| `conventionalcommits` | `conventional-changelog-conventionalcommits` | More configurable, stricter spec |
| `atom` | `conventional-changelog-atom` | Atom editor convention |
| `ember` | `conventional-changelog-ember` | Ember.js convention |
| `eslint` | `conventional-changelog-eslint` | ESLint convention |
| `jshint` | `conventional-changelog-jshint` | JSHint convention |

### Custom Preset Configuration

The `conventionalcommits` preset offers `presetConfig` for full control:

```js
["@semantic-release/commit-analyzer", {
  preset: "conventionalcommits",
  presetConfig: {
    types: [
      { type: "feat", section: "Features" },
      { type: "fix", section: "Bug Fixes" },
      { type: "perf", section: "Performance", hidden: false },
      { type: "revert", section: "Reverts", hidden: false },
      { type: "docs", section: "Documentation", hidden: true },
      { type: "style", hidden: true },
      { type: "chore", hidden: true },
      { type: "refactor", section: "Code Refactoring", hidden: false },
      { type: "test", hidden: true },
      { type: "build", hidden: true },
      { type: "ci", hidden: true },
    ],
  },
}]
```

### Custom Parser Options

Override how commit messages are parsed:

```json
["@semantic-release/commit-analyzer", {
  "parserOpts": {
    "headerPattern": "^(\\w+)(?:\\(([\\w$\\.\\-\\*/]+)\\))?:?\\s(.+)$",
    "headerCorrespondence": ["type", "scope", "subject"],
    "noteKeywords": ["BREAKING CHANGE", "BREAKING-CHANGE", "BREAKING"],
    "revertPattern": "^(?:Revert|revert:)\\s\"?([\\s\\S]+?)\"?\\s*This reverts commit (\\w+)\\.",
    "revertCorrespondence": ["header", "hash"],
    "issuePrefixes": ["#", "JIRA-"]
  }
}]
```

### Custom Writer Options for Release Notes

```json
["@semantic-release/release-notes-generator", {
  "preset": "conventionalcommits",
  "writerOpts": {
    "commitsSort": ["scope", "subject"],
    "groupBy": "type",
    "commitGroupsSort": "title",
    "noteGroupsSort": "title",
    "headerPartial": "## {{version}} ({{date}})\n",
    "footerPartial": "\n---\nGenerated by semantic-release\n"
  }
}]
```

---

## Release Rules Deep Dive

### Rule Structure

Each rule is an object matching commit properties to a release type:

```js
{
  type: "string",        // Commit type (feat, fix, etc.)
  scope: "string",       // Commit scope
  subject: "string",     // Commit subject (regex)
  breaking: true/false,  // Whether the commit has a breaking change
  revert: true/false,    // Whether the commit is a revert
  release: "major" | "minor" | "patch" | false  // false = no release
}
```

### Advanced Release Rules Examples

```js
releaseRules: [
  // Breaking changes always major
  { breaking: true, release: "major" },

  // Features are minor
  { type: "feat", release: "minor" },

  // Fixes are patch
  { type: "fix", release: "patch" },
  { type: "perf", release: "patch" },

  // Docs changes to README trigger patch
  { type: "docs", scope: "README", release: "patch" },

  // Refactors to critical modules trigger patch
  { type: "refactor", scope: "core", release: "patch" },
  { type: "refactor", scope: "auth", release: "patch" },

  // Dependency updates can trigger patch
  { type: "build", scope: "deps", release: "patch" },

  // Reverts trigger patch
  { revert: true, release: "patch" },

  // Suppress release for certain scopes
  { type: "feat", scope: "internal", release: false },
  { type: "fix", scope: "test", release: false },
]
```

### Rules Evaluation Order

Rules are evaluated top-to-bottom. The **highest** release type across all matching commits wins:
- `major` > `minor` > `patch` > `false`
- If any commit matches `major`, the release is `major` regardless of other commits.
- `false` means the specific commit doesn't count, not that it blocks the release.

---

## Monorepo Strategies

### multi-semantic-release (Recommended)

Best for: Independent package versioning within a monorepo.

```bash
npm install --save-dev multi-semantic-release
```

**Root `package.json`:**
```json
{
  "workspaces": ["packages/*"],
  "scripts": {
    "release": "multi-semantic-release"
  }
}
```

**Root `.releaserc.json` (shared config):**
```json
{
  "branches": ["main"],
  "plugins": [
    "@semantic-release/commit-analyzer",
    "@semantic-release/release-notes-generator",
    "@semantic-release/npm",
    "@semantic-release/github"
  ]
}
```

Key behaviors:
- Each package in `workspaces` gets independent versioning.
- Only commits touching a package's files trigger its release.
- Cross-package dependency bumps propagate automatically (if package A depends on B and B releases, A gets a patch bump).
- Per-package override: place `.releaserc.json` in any package directory.
- Git tags are namespaced: `@scope/package-name@1.2.3`.

**CLI flags:**
```bash
# Only release packages that changed
npx multi-semantic-release --ignore-private-packages

# Sequential releases (avoids race conditions)
npx multi-semantic-release --sequential-init
```

### semantic-release-monorepo

Best for: Simple monorepos where you want to keep the standard `semantic-release` CLI.

```bash
npm install --save-dev semantic-release-monorepo
```

Per-package config (`packages/my-pkg/.releaserc.json`):
```json
{
  "extends": "semantic-release-monorepo",
  "plugins": [
    "@semantic-release/commit-analyzer",
    "@semantic-release/release-notes-generator",
    "@semantic-release/npm"
  ],
  "tagFormat": "${name}@${version}"
}
```

Run per-package in CI:
```yaml
strategy:
  matrix:
    package: [packages/core, packages/cli, packages/utils]
steps:
  - run: cd ${{ matrix.package }} && npx semantic-release
```

### Nx + semantic-release

```bash
npm install --save-dev @theunderscorer/nx-semantic-release
```

`project.json` per package:
```json
{
  "targets": {
    "semantic-release": {
      "executor": "@theunderscorer/nx-semantic-release:semantic-release",
      "options": {
        "tagFormat": "${PROJECT_NAME}@${version}",
        "buildTarget": "my-lib:build",
        "commitMessage": "chore(release): ${PROJECT_NAME} ${nextRelease.version} [skip ci]"
      }
    }
  }
}
```

Run all releases respecting dependency order:
```bash
npx nx run-many --target=semantic-release --all
```

### Monorepo Commit Convention

For any monorepo strategy, use scoped commits to indicate which package changed:

```
feat(core): add new utility function
fix(cli): handle missing config file
feat(api)!: change response format
```

If a commit touches multiple packages, some tools (like multi-semantic-release) use file paths rather than scopes to determine affected packages.

---

## Pre-release Channels

### Channel Configuration

```js
module.exports = {
  branches: [
    "main",                                              // default channel → latest
    { name: "next", channel: "next", prerelease: "rc" }, // → 1.1.0-rc.1 on @next
    { name: "beta", prerelease: true },                  // → 1.1.0-beta.1 on @beta
    { name: "alpha", prerelease: true },                 // → 1.1.0-alpha.1 on @alpha
    { name: "canary", prerelease: "canary" },            // → 1.1.0-canary.1 on @canary
  ],
};
```

**How `prerelease` values work:**
- `true` — uses branch name as pre-release identifier: `1.0.0-beta.1`
- `"rc"` — uses specified string: `1.0.0-rc.1`
- `false` or omitted — regular release

### Installing Pre-releases

```bash
npm install mypackage@next     # Release candidate
npm install mypackage@beta     # Beta
npm install mypackage@alpha    # Alpha
npm install mypackage@latest   # Stable (default)
```

### Promoting Pre-releases to Stable

Merge the pre-release branch into `main`. semantic-release creates a stable version automatically — it does not re-use the pre-release version number. Instead, it determines the next stable version based on commit analysis.

```bash
# After testing on beta channel
git checkout main
git merge beta
git push origin main
# semantic-release creates e.g. 1.1.0 (not 1.1.0-beta.3)
```

---

## Maintenance Branches & Backport Workflows

### Configuring Maintenance Branches

```json
{
  "branches": [
    "main",
    { "name": "1.x", "range": "1.x", "channel": "1.x" },
    { "name": "2.x", "range": "2.x", "channel": "2.x" },
    "+([0-9])?(.{+([0-9]),x}).x"
  ]
}
```

The glob pattern `+([0-9])?(.{+([0-9]),x}).x` matches any maintenance branch like `1.x`, `2.3.x`, `3.x`.

### Backport Workflow

```bash
# 1. Create maintenance branch from last release of that major
git checkout -b 1.x v1.9.5
git push origin 1.x

# 2. Cherry-pick the fix
git cherry-pick <commit-sha>
git push origin 1.x

# 3. semantic-release automatically:
#    - Analyzes the cherry-picked commit
#    - Creates 1.9.6 on the 1.x channel
#    - Tags and publishes to npm @1.x dist-tag
```

### Range Constraints

The `range` option limits the version range for a maintenance branch:
- `"range": "1.x"` → only `1.x.y` versions (never `2.0.0`)
- `"range": ">=1.5.0 <1.8.0"` → only versions in that range
- If a breaking change is pushed to a maintenance branch, semantic-release will error because it would exceed the range.

---

## Programmatic API Usage

### Basic Programmatic Usage

```js
const semanticRelease = require("semantic-release");

async function release() {
  const result = await semanticRelease(
    {
      // Options — same as .releaserc config
      branches: ["main"],
      plugins: [
        "@semantic-release/commit-analyzer",
        "@semantic-release/release-notes-generator",
        "@semantic-release/npm",
        "@semantic-release/github",
      ],
      dryRun: false,
      ci: true,
    },
    {
      // Environment
      cwd: process.cwd(),
      env: { ...process.env, GITHUB_TOKEN: "xxx", NPM_TOKEN: "yyy" },
      stdout: process.stdout,
      stderr: process.stderr,
    }
  );

  if (result) {
    const { lastRelease, commits, nextRelease, releases } = result;
    console.log(`Published ${nextRelease.type} release: ${nextRelease.version}`);
    console.log(`Last release was: ${lastRelease.version}`);
    console.log(`${commits.length} commits in this release`);
    console.log(`Published to: ${releases.map((r) => r.name).join(", ")}`);
  } else {
    console.log("No release published — no relevant commits found");
  }
}

release().catch(console.error);
```

### Embedding in a Custom CLI

```js
#!/usr/bin/env node
const semanticRelease = require("semantic-release");
const { WritableStreamBuffer } = require("stream-buffers");

async function releaseWithCapture(options = {}) {
  const stdoutBuffer = new WritableStreamBuffer();
  const stderrBuffer = new WritableStreamBuffer();

  try {
    const result = await semanticRelease(
      { ...options, ci: false },
      {
        cwd: process.cwd(),
        env: process.env,
        stdout: stdoutBuffer,
        stderr: stderrBuffer,
      }
    );

    return {
      success: !!result,
      version: result?.nextRelease?.version,
      stdout: stdoutBuffer.getContentsAsString("utf8"),
      stderr: stderrBuffer.getContentsAsString("utf8"),
    };
  } catch (error) {
    return {
      success: false,
      error: error.message,
      stderr: stderrBuffer.getContentsAsString("utf8"),
    };
  }
}
```

### Using the API in Tests

```js
const semanticRelease = require("semantic-release");

describe("release process", () => {
  it("should determine correct version bump", async () => {
    const result = await semanticRelease(
      {
        branches: ["main"],
        dryRun: true,
        ci: false,
        plugins: ["@semantic-release/commit-analyzer"],
      },
      {
        cwd: "/path/to/repo",
        env: { ...process.env },
        stdout: { write: () => {} },
        stderr: { write: () => {} },
      }
    );

    expect(result.nextRelease.type).toBe("minor");
  });
});
```

---

## Advanced Branch Configuration

### Branch Object Properties

```js
{
  name: "branch-name",       // Git branch name (required)
  channel: "channel-name",   // npm dist-tag / release channel
  prerelease: true | "id",   // Pre-release identifier
  range: "1.x",              // Version range constraint
}
```

### Glob Patterns for Branch Names

```js
branches: [
  "main",
  { name: "next", prerelease: true },
  // Match all release/* branches as pre-release
  { name: "release/*", channel: "${name.replace(/^release\\//g, '')}", prerelease: "${name.replace(/^release\\//g, '')}" },
  // Match all N.x maintenance branches
  "+([0-9])?(.{+([0-9]),x}).x",
]
```

### Branch Ordering Rules

1. **Release branches** (non-prerelease, non-maintenance) must come first.
2. **Pre-release branches** follow.
3. **Maintenance branches** can be anywhere after the first release branch.
4. The first branch in the array is the **primary** release branch (gets `@latest` dist-tag).

---

## Conditional Release Workflows

### Skip Release for Specific Paths

Use the exec plugin to abort early:

```json
["@semantic-release/exec", {
  "verifyConditionsCmd": "git diff --name-only HEAD~$(git rev-list --count ${lastRelease.gitHead}..HEAD) | grep -qvE '\\.(md|txt)$' || exit 1"
}]
```

### Gate Release on External Condition

```js
// plugins/gate-check.js
module.exports = {
  verifyConditions: async (config, { logger }) => {
    const res = await fetch("https://api.statuspage.io/v1/status");
    const data = await res.json();
    if (data.indicator !== "none") {
      throw new Error(`Infrastructure degraded: ${data.description}. Aborting release.`);
    }
    logger.log("Infrastructure status: OK");
  },
};
```

---

## Performance Optimization

### Reducing CI Time

1. **Cache node_modules** — semantic-release installs are heavy:
   ```yaml
   - uses: actions/cache@v4
     with:
       path: ~/.npm
       key: ${{ runner.os }}-node-${{ hashFiles('**/package-lock.json') }}
   ```

2. **Skip unnecessary steps** — If not publishing to npm:
   ```json
   ["@semantic-release/npm", { "npmPublish": false }]
   ```

3. **Run only on release branches** — Don't waste CI on feature branches:
   ```yaml
   on:
     push:
       branches: [main, next, beta]
   ```

4. **Use `--dry-run` in PRs** — Validate configuration without releasing:
   ```yaml
   - if: github.event_name == 'pull_request'
     run: npx semantic-release --dry-run
   ```

### Git Fetch Optimization

Instead of full clone (`fetch-depth: 0`), fetch only what's needed:

```yaml
- uses: actions/checkout@v4
  with:
    fetch-depth: 0
    fetch-tags: true
```

For very large repos, consider shallow fetch with tag fetching:
```yaml
- uses: actions/checkout@v4
  with:
    fetch-depth: 100
- run: git fetch --tags
```

**Warning:** Shallow fetch can miss commits and cause incorrect version bumps. Use `fetch-depth: 0` unless repo size is a real issue.
