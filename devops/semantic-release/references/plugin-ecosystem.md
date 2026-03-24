# semantic-release Plugin Ecosystem

## Table of Contents

- [Plugin Lifecycle Overview](#plugin-lifecycle-overview)
- [Official Plugins](#official-plugins)
- [Community Plugins](#community-plugins)
- [Writing Custom Plugins](#writing-custom-plugins)
- [Plugin Composition Patterns](#plugin-composition-patterns)
- [Plugin Compatibility Matrix](#plugin-compatibility-matrix)

---

## Plugin Lifecycle Overview

Plugins hook into the semantic-release lifecycle. Each step runs plugins in declared order.

```
verifyConditions → analyzeCommits → verifyRelease → generateNotes → prepare → publish → addChannel → success/fail
```

| Step | Purpose | Return Value |
|---|---|---|
| `verifyConditions` | Validate config, tokens, permissions | Nothing (throw on failure) |
| `analyzeCommits` | Determine release type from commits | `"major"`, `"minor"`, `"patch"`, or `null` |
| `verifyRelease` | Custom validation before release | Nothing (throw to abort) |
| `generateNotes` | Create release notes content | String (release notes) |
| `prepare` | Prepare release artifacts | Nothing |
| `publish` | Publish the release | `{ name, url }` object |
| `addChannel` | Add release to distribution channel | `{ name, url }` object |
| `success` | Post-release success actions | Nothing |
| `fail` | Post-release failure actions | Nothing |

Multiple plugins can implement the same step. Results are:
- **verifyConditions**: All run; any throw aborts.
- **analyzeCommits**: Only one plugin should implement this (usually commit-analyzer).
- **generateNotes**: Notes from all plugins are concatenated.
- **publish**: All run; results collected in `releases` array.
- **success/fail**: All run.

---

## Official Plugins

### @semantic-release/commit-analyzer

Determines the release type by analyzing commit messages.

```json
["@semantic-release/commit-analyzer", {
  "preset": "conventionalcommits",
  "releaseRules": [
    { "type": "feat", "release": "minor" },
    { "type": "fix", "release": "patch" },
    { "type": "perf", "release": "patch" },
    { "type": "revert", "release": "patch" },
    { "breaking": true, "release": "major" }
  ],
  "parserOpts": {
    "noteKeywords": ["BREAKING CHANGE", "BREAKING-CHANGE"]
  }
}]
```

**Key options:**
| Option | Type | Description |
|---|---|---|
| `preset` | string | Conventional changelog preset (`angular`, `conventionalcommits`, etc.) |
| `releaseRules` | array | Custom rules mapping commit properties to release types |
| `parserOpts` | object | Override commit message parser options |
| `presetConfig` | object | Configuration for the chosen preset |

### @semantic-release/release-notes-generator

Generates release notes/changelog content from commits.

```json
["@semantic-release/release-notes-generator", {
  "preset": "conventionalcommits",
  "presetConfig": {
    "types": [
      { "type": "feat", "section": "🚀 Features" },
      { "type": "fix", "section": "🐛 Bug Fixes" },
      { "type": "perf", "section": "⚡ Performance" },
      { "type": "revert", "section": "⏪ Reverts" },
      { "type": "docs", "section": "📖 Documentation", "hidden": true },
      { "type": "chore", "hidden": true },
      { "type": "refactor", "section": "♻️ Refactoring", "hidden": false }
    ]
  },
  "writerOpts": {
    "commitsSort": ["scope", "subject"]
  }
}]
```

### @semantic-release/changelog

Writes release notes to a `CHANGELOG.md` file.

```json
["@semantic-release/changelog", {
  "changelogFile": "CHANGELOG.md",
  "changelogTitle": "# Changelog\n\nAll notable changes to this project."
}]
```

**Must be before `@semantic-release/git`** so the updated file gets committed.

### @semantic-release/npm

Updates `package.json` version and optionally publishes to npm.

```json
["@semantic-release/npm", {
  "npmPublish": true,
  "pkgRoot": ".",
  "tarballDir": "release"
}]
```

**Key options:**
| Option | Type | Default | Description |
|---|---|---|---|
| `npmPublish` | boolean | `true` | Whether to publish to npm |
| `pkgRoot` | string | `.` | Directory with `package.json` |
| `tarballDir` | string | — | Directory to store `.tgz` tarball |

**Disable publish** (version bump only):
```json
["@semantic-release/npm", { "npmPublish": false }]
```

### @semantic-release/github

Creates GitHub releases, comments on issues/PRs referenced in commits.

```json
["@semantic-release/github", {
  "assets": [
    { "path": "dist/**/*.js", "label": "JavaScript bundles" },
    { "path": "dist/**/*.css", "label": "CSS bundles" },
    { "path": "release/*.tgz", "label": "npm package" }
  ],
  "successComment": "🎉 This ${issue.pull_request ? 'PR' : 'issue'} is included in version ${nextRelease.version}",
  "failTitle": "🚨 Release failed",
  "failComment": "The release from branch ${branch.name} failed.",
  "labels": ["released"],
  "releasedLabels": ["released-on-@${nextRelease.channel}"],
  "addReleases": "bottom",
  "draftRelease": false
}]
```

**Key options:**
| Option | Type | Description |
|---|---|---|
| `assets` | array | Files to upload to GitHub release |
| `successComment` | string/false | Comment on issues/PRs. `false` disables. |
| `failTitle` | string | Title of failure issue |
| `failComment` | string/false | Comment on failure issue. `false` disables. |
| `labels` | array | Labels for issues/PRs |
| `addReleases` | string | Where to add release links (`"top"`, `"bottom"`, `false`) |
| `draftRelease` | boolean | Create as draft release |
| `proxy` | string | HTTP proxy for GitHub API requests |

### @semantic-release/git

Commits release artifacts (CHANGELOG, package.json, etc.) back to the repository.

```json
["@semantic-release/git", {
  "assets": ["CHANGELOG.md", "package.json", "package-lock.json", "npm-shrinkwrap.json"],
  "message": "chore(release): ${nextRelease.version} [skip ci]\n\n${nextRelease.notes}"
}]
```

**⚠️ Must be the last plugin** — it commits everything prepared by earlier plugins.

**Key options:**
| Option | Type | Description |
|---|---|---|
| `assets` | array | Glob patterns for files to commit |
| `message` | string | Commit message template |

### @semantic-release/exec

Run arbitrary shell commands at any lifecycle step.

```json
["@semantic-release/exec", {
  "verifyConditionsCmd": "test -f deploy.key",
  "analyzeCommitsCmd": "echo patch",
  "generateNotesCmd": "cat custom-notes.md",
  "prepareCmd": "make build VERSION=${nextRelease.version}",
  "publishCmd": "make deploy VERSION=${nextRelease.version}",
  "successCmd": "notify-team 'Released ${nextRelease.version}'",
  "failCmd": "notify-team 'Release failed: ${errors.map(e => e.message).join(\", \")}'"
}]
```

**Available template variables:**
| Variable | Available In | Description |
|---|---|---|
| `${nextRelease.version}` | prepare, publish, success | Next version |
| `${nextRelease.type}` | prepare, publish, success | `major`, `minor`, `patch` |
| `${nextRelease.channel}` | prepare, publish, success | Release channel |
| `${nextRelease.gitTag}` | prepare, publish, success | Git tag |
| `${nextRelease.notes}` | prepare, publish, success | Release notes |
| `${lastRelease.version}` | all | Previous version |
| `${branch.name}` | all | Current branch |
| `${commits.length}` | success | Commit count |

**Return values from commands:**
- `analyzeCommitsCmd`: stdout is used as release type (`major`, `minor`, `patch`)
- `generateNotesCmd`: stdout is used as release notes
- `publishCmd`: stdout (JSON) is used as release info

### @semantic-release/gitlab

Creates GitLab releases (replaces `@semantic-release/github` for GitLab).

```json
["@semantic-release/gitlab", {
  "gitlabUrl": "https://gitlab.company.com",
  "assets": [
    { "path": "dist/app.zip", "label": "Application bundle", "type": "package" }
  ]
}]
```

---

## Community Plugins

### Notification Plugins

#### semantic-release-slack-bot
Post release notifications to Slack.

```bash
npm install --save-dev semantic-release-slack-bot
```

```json
["semantic-release-slack-bot", {
  "notifyOnSuccess": true,
  "notifyOnFail": true,
  "markdownReleaseNotes": true,
  "slackWebhook": "https://hooks.slack.com/services/..."
}]
```

Environment variable: `SLACK_WEBHOOK`

#### @semantic-release/slack
Alternative Slack plugin.

```json
["@semantic-release/exec", {
  "successCmd": "curl -X POST $SLACK_WEBHOOK -H 'Content-type: application/json' -d '{\"text\": \"Released v${nextRelease.version}\"}'"
}]
```

### Container & Infrastructure Plugins

#### semantic-release-docker
Build and push Docker images with semantic versioning.

```bash
npm install --save-dev @codedependant/semantic-release-docker
```

```json
["@codedependant/semantic-release-docker", {
  "dockerTags": ["latest", "{{version}}", "{{major}}", "{{major}}.{{minor}}"],
  "dockerImage": "myapp",
  "dockerRegistry": "ghcr.io",
  "dockerProject": "myorg"
}]
```

#### semantic-release-helm
Package and publish Helm charts.

```bash
npm install --save-dev @semantic-release-helm/semantic-release-helm
```

```json
["@semantic-release-helm/semantic-release-helm", {
  "chartPath": "./charts/myapp",
  "registry": "oci://ghcr.io/myorg/charts"
}]
```

### Issue Tracking Plugins

#### semantic-release-jira
Update JIRA issues on release.

```bash
npm install --save-dev semantic-release-jira-releases
```

```json
["semantic-release-jira-releases", {
  "projectId": "PROJ",
  "releaseNameTemplate": "v${version}",
  "jiraHost": "mycompany.atlassian.net",
  "released": true,
  "setReleaseDate": true
}]
```

Environment variables: `JIRA_EMAIL`, `JIRA_API_TOKEN`

### Version File Plugins

#### semantic-release-replace-plugin
Update version strings in arbitrary files.

```bash
npm install --save-dev semantic-release-replace-plugin
```

```json
["semantic-release-replace-plugin", {
  "replacements": [
    {
      "files": ["src/version.ts"],
      "from": "export const VERSION = \".*\"",
      "to": "export const VERSION = \"${nextRelease.version}\"",
      "results": [{ "file": "src/version.ts", "hasChanged": true, "numMatches": 1, "numReplacements": 1 }],
      "countMatches": true
    },
    {
      "files": ["Chart.yaml"],
      "from": "version: .*",
      "to": "version: ${nextRelease.version}",
      "results": [{ "file": "Chart.yaml", "hasChanged": true, "numMatches": 1, "numReplacements": 1 }],
      "countMatches": true
    }
  ]
}]
```

#### @google/semantic-release-replace-plugin
Google's version — same concept, different API.

```json
["@google/semantic-release-replace-plugin", {
  "replacements": [
    {
      "files": ["version.go"],
      "from": "const Version = \".*\"",
      "to": "const Version = \"${nextRelease.version}\""
    }
  ]
}]
```

### Build & Deploy Plugins

#### @semantic-release/exec (Advanced Patterns)

**Docker build + push:**
```json
["@semantic-release/exec", {
  "prepareCmd": "docker build -t ghcr.io/org/app:${nextRelease.version} -t ghcr.io/org/app:latest .",
  "publishCmd": "docker push ghcr.io/org/app:${nextRelease.version} && docker push ghcr.io/org/app:latest"
}]
```

**Terraform module tagging:**
```json
["@semantic-release/exec", {
  "publishCmd": "echo '{\"name\": \"Terraform Registry\", \"url\": \"https://registry.terraform.io/modules/org/module\"}'"
}]
```

**S3 upload:**
```json
["@semantic-release/exec", {
  "publishCmd": "aws s3 sync dist/ s3://my-bucket/releases/${nextRelease.version}/"
}]
```

### Monorepo Plugins

#### multi-semantic-release
```bash
npm install --save-dev multi-semantic-release
```
See [advanced-patterns.md](./advanced-patterns.md#monorepo-strategies) for detailed configuration.

#### semantic-release-monorepo
```bash
npm install --save-dev semantic-release-monorepo
```
Filters commits by package directory. Extend in each package's config:
```json
{ "extends": "semantic-release-monorepo" }
```

#### @theunderscorer/nx-semantic-release
For Nx workspaces. Uses Nx dependency graph for release ordering.

---

## Writing Custom Plugins

### Minimal Plugin

A plugin is a module exporting one or more async functions:

```js
// plugins/version-file.js
const fs = require("fs").promises;

module.exports = {
  async prepare(pluginConfig, { nextRelease, logger }) {
    const file = pluginConfig.file || "VERSION";
    await fs.writeFile(file, nextRelease.version);
    logger.log("Wrote version %s to %s", nextRelease.version, file);
  },
};
```

Config:
```json
["./plugins/version-file.js", { "file": "VERSION.txt" }]
```

### Full Plugin Template

```js
// plugins/my-full-plugin.js
const SemanticReleaseError = require("@semantic-release/error");

/**
 * Verify that all conditions are met for the release.
 * Called first. Throw to abort the release.
 */
async function verifyConditions(pluginConfig, context) {
  const { env, logger } = context;

  if (!env.MY_TOKEN) {
    throw new SemanticReleaseError(
      "MY_TOKEN environment variable is not set",
      "ENOMYTOKEN",
      "Set MY_TOKEN in your CI environment"
    );
  }

  logger.log("Conditions verified ✓");
}

/**
 * Analyze commits to determine the release type.
 * Only ONE plugin should implement this (usually commit-analyzer).
 *
 * @returns {"major"|"minor"|"patch"|null}
 */
async function analyzeCommits(pluginConfig, context) {
  const { commits, logger } = context;

  // Custom analysis logic
  const hasBreaking = commits.some((c) => c.message.includes("BREAKING"));
  const hasFeature = commits.some((c) => c.message.startsWith("feat"));
  const hasFix = commits.some((c) => c.message.startsWith("fix"));

  if (hasBreaking) return "major";
  if (hasFeature) return "minor";
  if (hasFix) return "patch";
  return null;
}

/**
 * Generate release notes.
 * Notes from ALL plugins implementing this step are concatenated.
 *
 * @returns {string} Release notes content
 */
async function generateNotes(pluginConfig, context) {
  const { nextRelease, commits, lastRelease } = context;

  const notes = [
    `## Custom Notes for ${nextRelease.version}`,
    "",
    `Released from ${lastRelease.version || "initial"}`,
    `${commits.length} commits in this release`,
    "",
    ...commits.map((c) => `- ${c.subject} (${c.hash.substring(0, 7)})`),
  ];

  return notes.join("\n");
}

/**
 * Prepare the release (build, update files, etc.).
 * Runs after version is determined but before publish.
 */
async function prepare(pluginConfig, context) {
  const { nextRelease, logger } = context;
  logger.log("Preparing release %s", nextRelease.version);
  // Build artifacts, update version files, etc.
}

/**
 * Publish the release.
 * @returns {{ name: string, url: string }} Release info
 */
async function publish(pluginConfig, context) {
  const { nextRelease, logger } = context;
  logger.log("Publishing version %s", nextRelease.version);

  // Publish logic here

  return {
    name: "My Custom Registry",
    url: `https://registry.example.com/pkg/${nextRelease.version}`,
  };
}

/**
 * Handle successful release.
 * `releases` contains results from all publish plugins.
 */
async function success(pluginConfig, context) {
  const { nextRelease, releases, logger } = context;
  logger.log("Release %s published to %d registries", nextRelease.version, releases.length);
}

/**
 * Handle failed release.
 */
async function fail(pluginConfig, context) {
  const { errors, logger } = context;
  logger.error("Release failed with %d errors", errors.length);
  errors.forEach((e) => logger.error("  - %s", e.message));
}

module.exports = {
  verifyConditions,
  analyzeCommits,
  generateNotes,
  prepare,
  publish,
  success,
  fail,
};
```

### Testing Custom Plugins

```js
// plugins/__tests__/my-plugin.test.js
const { verifyConditions, publish } = require("../my-full-plugin");

const createContext = (overrides = {}) => ({
  logger: { log: jest.fn(), error: jest.fn() },
  env: { MY_TOKEN: "test-token" },
  nextRelease: { version: "1.0.0", type: "minor", gitTag: "v1.0.0", channel: null },
  lastRelease: { version: "0.9.0", gitTag: "v0.9.0" },
  commits: [{ hash: "abc1234", message: "feat: new feature", subject: "feat: new feature" }],
  releases: [],
  branch: { name: "main" },
  ...overrides,
});

describe("verifyConditions", () => {
  it("throws when MY_TOKEN is missing", async () => {
    const context = createContext({ env: {} });
    await expect(verifyConditions({}, context)).rejects.toThrow("MY_TOKEN");
  });

  it("passes when MY_TOKEN is set", async () => {
    const context = createContext();
    await expect(verifyConditions({}, context)).resolves.not.toThrow();
  });
});

describe("publish", () => {
  it("returns release info", async () => {
    const context = createContext();
    const result = await publish({}, context);
    expect(result).toEqual({
      name: "My Custom Registry",
      url: expect.stringContaining("1.0.0"),
    });
  });
});
```

### Plugin as Shareable Config

Create a shareable config that bundles plugins together:

```js
// semantic-release-config-myorg/index.js
module.exports = {
  branches: ["main", { name: "next", prerelease: true }],
  plugins: [
    ["@semantic-release/commit-analyzer", { preset: "conventionalcommits" }],
    ["@semantic-release/release-notes-generator", { preset: "conventionalcommits" }],
    ["@semantic-release/changelog", { changelogFile: "CHANGELOG.md" }],
    "@semantic-release/npm",
    "@semantic-release/github",
    ["@semantic-release/git", {
      assets: ["CHANGELOG.md", "package.json"],
      message: "chore(release): ${nextRelease.version} [skip ci]",
    }],
  ],
};
```

Usage:
```json
{ "extends": "semantic-release-config-myorg" }
```

---

## Plugin Composition Patterns

### Pattern: Build Before Publish

```json
{
  "plugins": [
    "@semantic-release/commit-analyzer",
    "@semantic-release/release-notes-generator",
    ["@semantic-release/exec", {
      "prepareCmd": "npm run build"
    }],
    ["@semantic-release/npm", { "pkgRoot": "dist" }],
    "@semantic-release/github"
  ]
}
```

### Pattern: Multi-Registry Publish

```json
{
  "plugins": [
    "@semantic-release/commit-analyzer",
    "@semantic-release/release-notes-generator",
    "@semantic-release/npm",
    ["@semantic-release/exec", {
      "publishCmd": "npm publish --registry https://npm.pkg.github.com"
    }],
    "@semantic-release/github"
  ]
}
```

### Pattern: Docker + npm + GitHub

```json
{
  "plugins": [
    "@semantic-release/commit-analyzer",
    "@semantic-release/release-notes-generator",
    ["@semantic-release/changelog", { "changelogFile": "CHANGELOG.md" }],
    "@semantic-release/npm",
    ["@semantic-release/exec", {
      "prepareCmd": "docker build -t ghcr.io/org/app:${nextRelease.version} .",
      "publishCmd": "docker push ghcr.io/org/app:${nextRelease.version}"
    }],
    ["@semantic-release/github", {
      "assets": ["dist/**"]
    }],
    ["@semantic-release/git", {
      "assets": ["CHANGELOG.md", "package.json"],
      "message": "chore(release): ${nextRelease.version} [skip ci]"
    }]
  ]
}
```

### Pattern: Conditional Plugin Execution

Use `@semantic-release/exec` with shell conditionals:

```json
["@semantic-release/exec", {
  "publishCmd": "if [ \"${nextRelease.type}\" = \"major\" ]; then ./scripts/major-deploy.sh ${nextRelease.version}; else ./scripts/deploy.sh ${nextRelease.version}; fi"
}]
```

---

## Plugin Compatibility Matrix

| Plugin | verifyConditions | analyzeCommits | generateNotes | prepare | publish | addChannel | success | fail |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| commit-analyzer | | ✅ | | | | | | |
| release-notes-generator | | | ✅ | | | | | |
| changelog | | | | ✅ | | | | |
| npm | ✅ | | | ✅ | ✅ | ✅ | | |
| github | ✅ | | | | ✅ | | ✅ | ✅ |
| gitlab | ✅ | | | | ✅ | | ✅ | ✅ |
| git | ✅ | | | ✅ | | | | |
| exec | ✅ | ✅ | ✅ | ✅ | ✅ | | ✅ | ✅ |
