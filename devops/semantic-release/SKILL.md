---
name: semantic-release
description: >
  Automate versioning and package publishing with semantic-release. Use when: setting up semantic-release,
  automated versioning, semantic versioning automation, changelog generation, npm publish automation,
  release automation, conventional commits release, configuring .releaserc, multi-branch releases,
  release plugins, CI/CD release pipelines. Do NOT use for: manual versioning, changesets,
  release-please, standard-version, lerna publish without semantic-release, conventional-changelog-cli
  standalone, manual npm publish workflows, or non-semantic-release tools.
---

# semantic-release

Fully automated version management and package publishing. Determines next version from commit messages,
generates release notes, publishes packages, and creates Git tags/GitHub releases — all without human intervention.

## Installation

```bash
# Core + common plugins
npm install --save-dev semantic-release \
  @semantic-release/commit-analyzer \
  @semantic-release/release-notes-generator \
  @semantic-release/changelog \
  @semantic-release/npm \
  @semantic-release/github \
  @semantic-release/git

# Optional plugins
npm install --save-dev @semantic-release/exec          # Run shell commands during release
npm install --save-dev @semantic-release/gitlab         # GitLab releases instead of GitHub
npm install --save-dev multi-semantic-release           # Monorepo support
```

Add release script to `package.json`:
```json
{ "scripts": { "release": "semantic-release" } }
```

## Configuration

Place config in one of (searched in this order): `.releaserc` (JSON/YAML/JS), `.releaserc.json`,
`.releaserc.yml`, `release.config.js`, `release.config.cjs`, `release.config.mjs`, or `release` key in `package.json`.

**Do NOT** add a top-level `release` wrapper in `.releaserc` files — put options directly at root.
CLI args override top-level options only; plugin configs MUST be in the config file.

### Minimal `.releaserc.json`
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

### Full-featured `release.config.js`
```js
module.exports = {
  branches: [
    "main",
    { name: "next", prerelease: true },
    { name: "beta", prerelease: true, channel: "beta" },
    { name: "alpha", prerelease: true, channel: "alpha" },
    { name: "1.x", range: "1.x", channel: "1.x" }  // maintenance branch
  ],
  plugins: [
    ["@semantic-release/commit-analyzer", {
      preset: "conventionalcommits",
      releaseRules: [
        { type: "feat", release: "minor" },
        { type: "fix", release: "patch" },
        { type: "perf", release: "patch" },
        { type: "docs", scope: "README", release: "patch" },
        { type: "refactor", release: "patch" },
        { breaking: true, release: "major" }
      ]
    }],
    ["@semantic-release/release-notes-generator", {
      preset: "conventionalcommits",
      presetConfig: {
        types: [
          { type: "feat", section: "Features" },
          { type: "fix", section: "Bug Fixes" },
          { type: "perf", section: "Performance" },
          { type: "refactor", section: "Refactoring", hidden: false },
          { type: "docs", section: "Documentation", hidden: true },
          { type: "chore", hidden: true }
        ]
      }
    }],
    ["@semantic-release/changelog", { changelogFile: "CHANGELOG.md" }],
    "@semantic-release/npm",
    ["@semantic-release/github", { assets: ["dist/**/*.js", "dist/**/*.css"] }],
    ["@semantic-release/git", {
      assets: ["CHANGELOG.md", "package.json", "package-lock.json"],
      message: "chore(release): ${nextRelease.version} [skip ci]\n\n${nextRelease.notes}"
    }]
  ]
};
```

## Conventional Commits Format

semantic-release uses commit messages to determine version bumps. Follow Conventional Commits:

```
<type>(<scope>): <subject>

<body>

<footer>
```

### Commit → Version mapping (default Angular preset)

| Commit message | Release type |
|---|---|
| `fix(api): handle null response` | Patch (1.0.0 → 1.0.1) |
| `feat(auth): add OAuth2 support` | Minor (1.0.0 → 1.1.0) |
| `feat(api)!: redesign endpoints` | Major (1.0.0 → 2.0.0) |
| `fix(core): crash on startup\n\nBREAKING CHANGE: config format changed` | Major |
| `perf(db): optimize queries` | No release (unless custom rule) |
| `chore: update deps` | No release |
| `docs: update README` | No release |

Use `conventionalcommits` preset for finer control over which types trigger releases.

## Plugin System

Plugins execute in order through lifecycle steps:

1. **verifyConditions** — Verify release prerequisites (tokens, permissions)
2. **analyzeCommits** — Determine release type from commits
3. **verifyRelease** — Validate the release (custom checks)
4. **generateNotes** — Create release notes content
5. **prepare** — Prepare the release (update files, build)
6. **publish** — Publish the release (npm, GitHub)
7. **addChannel** — Add release to a distribution channel
8. **success** — Handle successful release (comments, notifications)
9. **fail** — Handle failed release

### Core plugins

| Plugin | Purpose |
|---|---|
| `@semantic-release/commit-analyzer` | Analyze commits → determine version bump |
| `@semantic-release/release-notes-generator` | Generate changelog/release notes |
| `@semantic-release/npm` | Update `package.json` version, publish to npm |
| `@semantic-release/github` | Create GitHub release, comment on issues/PRs |
| `@semantic-release/changelog` | Write `CHANGELOG.md` file |
| `@semantic-release/git` | Commit release artifacts back to repo |
| `@semantic-release/exec` | Run arbitrary shell commands at any lifecycle step |
| `@semantic-release/gitlab` | Create GitLab release |

### Plugin configuration syntax

Pass plugin as string (defaults) or as `[plugin, options]` tuple:
```json
{
  "plugins": [
    "@semantic-release/commit-analyzer",
    ["@semantic-release/npm", { "npmPublish": false }],
    ["@semantic-release/exec", {
      "prepareCmd": "echo ${nextRelease.version} > VERSION",
      "publishCmd": "./scripts/deploy.sh ${nextRelease.version}"
    }]
  ]
}
```

## Multi-Branch Releases

Configure `branches` array to release from multiple branches with different channels:

```json
{
  "branches": [
    "main",
    "next",
    { "name": "beta", "prerelease": true },
    { "name": "alpha", "prerelease": true },
    { "name": "1.x", "range": "1.x", "channel": "1.x" },
    { "name": "2.x", "range": "2.x", "channel": "2.x" }
  ]
}
```

**How versions flow:**
- `main` → `1.0.0` (latest npm tag)
- `next` → `1.1.0` (next npm tag)
- `beta` → `1.1.0-beta.1` (beta npm tag)
- `alpha` → `1.1.0-alpha.1` (alpha npm tag)
- `1.x` → `1.0.1` (1.x npm tag, maintenance patches only)

Order matters: list branches from most stable to least stable, then maintenance branches.
The first branch is the primary release branch using the default distribution channel.

## Monorepo Support

semantic-release has no built-in monorepo support. Use a wrapper:

### multi-semantic-release (recommended)
```bash
npm install --save-dev multi-semantic-release
npx multi-semantic-release
```

Place shared config at repo root `.releaserc`. Each package can override with its own config.
Handles cross-package dependency updates automatically.

### semantic-release-monorepo
```bash
npm install --save-dev semantic-release-monorepo
```
```json
{
  "extends": "semantic-release-monorepo",
  "plugins": ["@semantic-release/commit-analyzer", "@semantic-release/release-notes-generator", "@semantic-release/npm"]
}
```
Filters commits by package directory — only commits touching a package's files trigger its release.

### Nx integration
```bash
npm install --save-dev @theunderscorer/nx-semantic-release
```
Add to `project.json` targets per package. Leverages Nx dependency graph for release ordering.

## CI/CD Integration

### GitHub Actions
```yaml
# .github/workflows/release.yml
name: Release
on:
  push:
    branches: [main, next, beta, alpha]
permissions:
  contents: write
  issues: write
  pull-requests: write
jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0        # REQUIRED: full history for commit analysis
          persist-credentials: false
      - uses: actions/setup-node@v4
        with:
          node-version: lts/*
          cache: npm
      - run: npm ci
      - run: npx semantic-release
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          NPM_TOKEN: ${{ secrets.NPM_TOKEN }}
```

**Critical:** `fetch-depth: 0` is mandatory. Without full Git history, commit analysis fails silently
and no release is created.

### GitLab CI
```yaml
# .gitlab-ci.yml
stages:
  - release
release:
  image: node:lts
  stage: release
  script:
    - npm ci
    - npx semantic-release
  only:
    - main
    - next
  variables:
    GITLAB_TOKEN: $GITLAB_TOKEN
    NPM_TOKEN: $NPM_TOKEN
```

Use `@semantic-release/gitlab` plugin instead of `@semantic-release/github`.
Set `GITLAB_TOKEN` as protected CI/CD variable with `api` and `write_repository` scopes.

### Shareable configs
Extend a preset to reduce boilerplate:
```json
{ "extends": "@semantic-release/gitlab-config" }
```

## Private Package Publishing

Set `publishConfig` in `package.json` for private registries:
```json
{ "publishConfig": { "access": "restricted", "registry": "https://npm.pkg.github.com" } }
```

`.npmrc` for CI: `//npm.pkg.github.com/:_authToken=${NPM_TOKEN}`

Skip npm publish (version bump only): `["@semantic-release/npm", { "npmPublish": false }]`

## Custom Plugins

### Using @semantic-release/exec for custom commands
```json
["@semantic-release/exec", {
  "verifyConditionsCmd": "./scripts/verify.sh",
  "analyzeCommitsCmd": "./scripts/analyze.sh",
  "prepareCmd": "docker build -t myapp:${nextRelease.version} .",
  "publishCmd": "docker push myapp:${nextRelease.version}",
  "successCmd": "curl -X POST https://slack.webhook/... -d '{\"text\": \"Released ${nextRelease.version}\"}'",
  "failCmd": "curl -X POST https://slack.webhook/... -d '{\"text\": \"Release failed\"}'"
}]
```

### Writing a custom plugin module
Create `my-plugin.js`:
```js
module.exports = {
  verifyConditions: async (pluginConfig, context) => {
    const { logger } = context;
    if (!process.env.DEPLOY_KEY) throw new Error("DEPLOY_KEY not set");
    logger.log("Deploy key verified");
  },
  publish: async (pluginConfig, context) => {
    const { nextRelease, logger } = context;
    logger.log(`Publishing version ${nextRelease.version}`);
    // Custom publish logic here
    return { name: "Custom Registry", url: "https://example.com" };
  }
};
```
Reference in config: `"plugins": ["./my-plugin.js"]`

Available context properties: `nextRelease`, `lastRelease`, `commits`, `releases`, `branch`, `logger`, `env`.

## Dry-Run and Debugging

### Dry-run (preview without publishing)
```bash
npx semantic-release --dry-run
```
Runs full pipeline except destructive actions (no publish, no tag, no Git push).
Still requires valid tokens and correct branch — set `CI=true` if running locally.

### Debug mode (verbose logging)
```bash
DEBUG=semantic-release:* npx semantic-release
# Or for specific plugins:
DEBUG=semantic-release:commit-analyzer npx semantic-release
```

### Local dry-run recipe
```bash
export GITHUB_TOKEN=$(gh auth token)
export CI=true
npx semantic-release --dry-run --no-ci
```
The `--no-ci` flag skips CI environment validation. Combine with `--dry-run` for safe local testing.

## Troubleshooting

### "No release published"
- Check commits follow Conventional Commits format. Run `git log --oneline` and verify types.
- Ensure branch is listed in `branches` config.
- Verify `fetch-depth: 0` in CI checkout step.
- Run with `--dry-run` and `DEBUG=semantic-release:*` to see commit analysis output.

### "ENOGH token" / authentication errors
- Verify `GITHUB_TOKEN` or `GITLAB_TOKEN` is set and has correct scopes.
- For npm: ensure `NPM_TOKEN` is valid automation token, not publish token.
- Tokens must be available as environment variables, not CLI args.

### "ENOREPOURL" / repository URL errors
- Set `repositoryUrl` in config or ensure `repository.url` in `package.json` is correct.
- Format: `https://github.com/owner/repo.git` or `git@github.com:owner/repo.git`.

### Plugin not executing
- Plugins run in declared order. If you specify `plugins`, you MUST include ALL plugins —
  declaring `plugins` replaces the default list entirely.
- Check plugin is installed: `npm ls @semantic-release/changelog`.

### Version not incrementing as expected
- Custom `releaseRules` override defaults entirely; include all rules you need.
- `BREAKING CHANGE` footer must be uppercase and in the commit body/footer, not the subject.
- The `!` after type/scope (e.g., `feat!:`) also signals breaking change.

### Monorepo releases triggering for wrong package
- Ensure commit scope or file-path filtering is configured per package.
- With `semantic-release-monorepo`, only commits touching files in the package directory are analyzed.

### CI running release on every push
- Add `[skip ci]` to release commit message via `@semantic-release/git` config.
- Filter workflow triggers to release branches only.
- Use `if: "!contains(github.event.head_commit.message, '[skip ci]')"` in GitHub Actions.

## References

In-depth guides in `references/`:

- **[`references/advanced-patterns.md`](references/advanced-patterns.md)** — Custom plugin development, commit analyzer customization, release rules, monorepo strategies (multi-semantic-release, semantic-release-monorepo, Nx), pre-release channels, maintenance branches and backport workflows, programmatic API usage, advanced branch configuration, conditional releases, performance optimization.

- **[`references/troubleshooting.md`](references/troubleshooting.md)** — Diagnosing and fixing common failures: ENOGHTOKEN, ENOGITHEAD, ENOREPOURL, missing commits, wrong version bumps, CI permission issues, npm 2FA, GPG signing, dry-run discrepancies, branch config errors, plugin ordering issues. Includes a quick diagnostic checklist.

- **[`references/plugin-ecosystem.md`](references/plugin-ecosystem.md)** — Complete guide to the plugin lifecycle, all official plugins with full option reference, community plugins (Slack, Docker, Helm, JIRA, version-file replacement), writing and testing custom plugins, plugin composition patterns, shareable configs, and a compatibility matrix.

## Scripts

Ready-to-use helper scripts in `scripts/`:

| Script | Purpose |
|---|---|
| `scripts/setup-project.sh` | Initialize semantic-release in a project: install deps, create `.releaserc`, configure CI (GitHub Actions/GitLab), set up commitlint+husky. Run with `--help` for options. |
| `scripts/validate-commits.sh` | Check if recent commits follow Conventional Commits format. Reports violations with optional `--fix-hints`. Shows version bump preview. |
| `scripts/dry-run.sh` | Enhanced dry-run wrapper with pre/post analysis, token auto-detection, commit preview, error diagnosis, and formatted results summary. |

Usage: `bash scripts/setup-project.sh --ci github` or copy scripts into the target project.

## Assets / Templates

Copy-ready configuration templates in `assets/`:

| Asset | Description |
|---|---|
| `assets/.releaserc.json` | Production-ready `.releaserc.json` with conventionalcommits preset, emoji-sectioned release notes, multi-branch support (main/next/beta + maintenance), and all common plugins configured. |
| `assets/github-actions.yml` | GitHub Actions release workflow with test gate, npm caching, proper permissions (including `id-token` for npm provenance), concurrency control, and `[skip ci]` filtering. Copy to `.github/workflows/release.yml`. |
| `assets/commitlint.config.js` | Commitlint config aligned with semantic-release conventions. Includes all standard types, header/body rules, and optional commitizen prompt configuration. |

## Examples

### Input: Configure basic npm package release
```json
// .releaserc.json
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
**Output:** On `git push main` with `feat: add search`, creates release `v1.1.0`, publishes to npm,
creates GitHub release with auto-generated notes.

### Input: Library with changelog but no npm publish
```json
{
  "branches": ["main"],
  "plugins": [
    "@semantic-release/commit-analyzer",
    "@semantic-release/release-notes-generator",
    ["@semantic-release/changelog", { "changelogFile": "CHANGELOG.md" }],
    ["@semantic-release/npm", { "npmPublish": false }],
    "@semantic-release/github",
    ["@semantic-release/git", {
      "assets": ["CHANGELOG.md", "package.json"],
      "message": "chore(release): ${nextRelease.version} [skip ci]"
    }]
  ]
}
```
**Output:** Bumps `package.json` version, updates `CHANGELOG.md`, commits both, creates GitHub release.
No npm publish occurs.

### Input: Docker image release with exec plugin
```json
{
  "branches": ["main"],
  "plugins": [
    "@semantic-release/commit-analyzer",
    "@semantic-release/release-notes-generator",
    ["@semantic-release/exec", {
      "prepareCmd": "docker build -t ghcr.io/myorg/myapp:${nextRelease.version} .",
      "publishCmd": "docker push ghcr.io/myorg/myapp:${nextRelease.version}"
    }],
    ["@semantic-release/npm", { "npmPublish": false }],
    "@semantic-release/github"
  ]
}
```
**Output:** Builds and pushes Docker image tagged with semver, creates GitHub release. No npm publish.
