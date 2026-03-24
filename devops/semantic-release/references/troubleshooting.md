# semantic-release Troubleshooting Guide

## Table of Contents

- [Authentication Errors](#authentication-errors)
- [Git & Repository Errors](#git--repository-errors)
- [Version Bump Issues](#version-bump-issues)
- [CI/CD Environment Issues](#cicd-environment-issues)
- [npm Publishing Issues](#npm-publishing-issues)
- [Plugin Errors](#plugin-errors)
- [Branch Configuration Errors](#branch-configuration-errors)
- [Dry-Run Discrepancies](#dry-run-discrepancies)
- [GPG Signing Issues](#gpg-signing-issues)
- [Monorepo Issues](#monorepo-issues)
- [Debugging Techniques](#debugging-techniques)
- [Quick Diagnostic Checklist](#quick-diagnostic-checklist)

---

## Authentication Errors

### ENOGHTOKEN — GitHub Token Missing or Invalid

**Symptoms:**
```
ENOGHTOKEN The GitHub token is not valid.
```

**Causes & Fixes:**

1. **Token not set:**
   ```bash
   # Verify token exists
   echo $GITHUB_TOKEN | head -c 10
   ```
   Set in CI: `GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}`

2. **Insufficient permissions:**
   The `GITHUB_TOKEN` needs these permissions:
   ```yaml
   permissions:
     contents: write       # Create releases and tags
     issues: write         # Comment on issues
     pull-requests: write  # Comment on PRs
   ```

3. **Fine-grained PAT missing scopes:**
   If using a Personal Access Token instead of `GITHUB_TOKEN`, ensure these scopes:
   - `repo` (full control of private repos)
   - Or for fine-grained: `Contents: Read and write`, `Issues: Read and write`, `Pull requests: Read and write`, `Metadata: Read`

4. **Token expired:** Regenerate and update the secret.

5. **Wrong token for private repo:** `GITHUB_TOKEN` is auto-scoped to the current repo. For cross-repo operations, use a PAT.

### ENOGITLABTOKEN — GitLab Token Missing

**Symptoms:**
```
ENOGITLABTOKEN The GitLab token is not valid.
```

**Fix:** Set `GITLAB_TOKEN` with `api` and `write_repository` scopes. Ensure it's a project or group access token with Maintainer role.

### NPM_TOKEN Authentication Failures

**Symptoms:**
```
ENPMTOKEN npm token is invalid or missing.
```

**Fixes:**

1. **Use automation token:** npm publish tokens don't work in CI. Create an automation token:
   - npm → Access Tokens → Generate New Token → Automation

2. **Verify token:** `npm whoami --registry https://registry.npmjs.org`

3. **2FA conflict:** If your npm account has 2FA enabled, only automation tokens work in CI. Publish tokens require OTP input.

4. **Scoped registry:** Ensure `.npmrc` matches:
   ```
   //registry.npmjs.org/:_authToken=${NPM_TOKEN}
   ```

---

## Git & Repository Errors

### ENOGITHEAD — No Git HEAD

**Symptoms:**
```
ENOGITHEAD The git head branch is not set.
```

**Causes & Fixes:**

1. **Detached HEAD in CI:** Most CI systems checkout a specific commit, not a branch.
   ```yaml
   # GitHub Actions fix:
   - uses: actions/checkout@v4
     with:
       fetch-depth: 0
       ref: ${{ github.ref }}
   ```

2. **Shallow clone:** `fetch-depth: 1` (default) means no history.
   ```yaml
   # ALWAYS use:
   fetch-depth: 0
   ```

### ENOREPOURL — Repository URL Not Found

**Symptoms:**
```
ENOREPOURL The repository URL is not valid.
```

**Fixes:**

1. **Set in config:**
   ```json
   { "repositoryUrl": "https://github.com/owner/repo.git" }
   ```

2. **Or in `package.json`:**
   ```json
   { "repository": { "type": "git", "url": "https://github.com/owner/repo.git" } }
   ```

3. **SSH vs HTTPS:** If CI uses HTTPS but your repo URL is SSH:
   ```json
   { "repositoryUrl": "https://github.com/owner/repo.git" }
   ```

### EINVALIDTAGFORMAT — Invalid Tag Format

**Symptoms:**
```
EINVALIDTAGFORMAT The tag format must contain the variable 'version'.
```

**Fix:** Ensure `tagFormat` contains `${version}`:
```json
{ "tagFormat": "v${version}" }
```

For monorepos:
```json
{ "tagFormat": "@myorg/mypackage@${version}" }
```

### Missing Commits — Commits Not Analyzed

**Symptoms:** No release created even though there are `feat` or `fix` commits.

**Diagnostic steps:**

```bash
# 1. Check what commits semantic-release sees
DEBUG=semantic-release:* npx semantic-release --dry-run 2>&1 | grep "commits"

# 2. Check the last tag
git describe --tags --abbrev=0

# 3. See commits since last tag
git log $(git describe --tags --abbrev=0)..HEAD --oneline

# 4. Verify fetch depth
git rev-list --count HEAD
```

**Common causes:**
- Shallow clone (`fetch-depth` not 0)
- Tags not fetched: add `git fetch --tags` after checkout
- Wrong branch: current branch not in `branches` config
- Squash merge: commit messages in squashed commits may not follow convention

---

## Version Bump Issues

### Wrong Version Bump Type

**Symptom:** Expected `minor` but got `patch`, or no release at all.

**Diagnostic:**
```bash
# See exactly what the analyzer decides
DEBUG=semantic-release:commit-analyzer npx semantic-release --dry-run
```

**Common causes:**

1. **Commit doesn't match expected format:**
   ```
   # WRONG — missing colon after type
   feat add new feature

   # WRONG — extra space before colon
   feat (scope) : subject

   # CORRECT
   feat(scope): subject
   feat: subject
   ```

2. **`releaseRules` override defaults entirely:**
   If you define custom `releaseRules`, the defaults are replaced. Include all rules:
   ```json
   "releaseRules": [
     { "breaking": true, "release": "major" },
     { "type": "feat", "release": "minor" },
     { "type": "fix", "release": "patch" }
   ]
   ```

3. **BREAKING CHANGE not detected:**
   - Must be in the commit **body or footer**, not the subject
   - Must be uppercase: `BREAKING CHANGE:` (not `breaking change:`)
   - Alternative: use `!` after type: `feat!: breaking thing`
   - Must have a blank line before the footer:
     ```
     feat: something

     BREAKING CHANGE: this breaks things
     ```

### Version Stuck — Same Version Re-released

**Causes:**
- Git tags not pushed to remote: `git push --tags`
- `.git` directory missing history
- `tagFormat` mismatch between config and existing tags

### Pre-release Version Unexpected

**Symptom:** Getting `1.0.0-beta.1` when expecting `1.1.0-beta.1`.

**Cause:** Pre-release versions are based on what would be the next release on the primary branch. If `main` is at `1.0.0` and no `minor` commits exist on main, beta will be `1.0.1-beta.1` for a fix.

---

## CI/CD Environment Issues

### ECIENVNOTSET — CI Environment Not Detected

**Symptoms:**
```
ECIENVNOTSET No CI environment detected.
```

**Fixes:**
```bash
# Set CI env var
export CI=true

# Or use --no-ci flag (for local testing only)
npx semantic-release --no-ci
```

### GitHub Actions — Permission Denied

**Symptom:** `HttpError: Resource not accessible by integration`

**Fix:** Add permissions block to workflow:
```yaml
permissions:
  contents: write
  issues: write
  pull-requests: write
  id-token: write  # For npm provenance
```

Or use a PAT with appropriate scopes instead of `GITHUB_TOKEN`.

### GitHub Actions — Release Creates Infinite Loop

**Symptom:** Release commit triggers another workflow run, which triggers another release.

**Fixes:**

1. **Add `[skip ci]` to release commit** (via `@semantic-release/git`):
   ```json
   ["@semantic-release/git", {
     "message": "chore(release): ${nextRelease.version} [skip ci]"
   }]
   ```

2. **Filter workflow trigger:**
   ```yaml
   on:
     push:
       branches: [main]
   jobs:
     release:
       if: "!contains(github.event.head_commit.message, '[skip ci]')"
   ```

3. **Use `persist-credentials: false`** with checkout to prevent automatic auth:
   ```yaml
   - uses: actions/checkout@v4
     with:
       persist-credentials: false
       fetch-depth: 0
   ```

### GitLab CI — Protected Branch/Tag Issues

**Symptom:** `remote: You are not allowed to push code to protected branches`

**Fix:**
- Ensure the CI token has `write_repository` scope
- Unprotect tags in Settings → Repository → Protected Tags, or allow the CI user
- Use a project deploy token with write access

---

## npm Publishing Issues

### npm 2FA / OTP Required

**Symptom:**
```
npm ERR! This operation requires a one-time password from your authenticator.
```

**Fix:** You cannot use a publish token with 2FA in CI. Use an **automation token**:
1. Go to npmjs.com → Access Tokens
2. Generate New Token → select **Automation**
3. Automation tokens bypass 2FA for publish

### npm Provenance

For npm provenance (supply chain security), add to workflow:
```yaml
permissions:
  id-token: write  # Required for provenance
```

And in config:
```json
["@semantic-release/npm", { "provenance": true }]
```

Only works in GitHub Actions with `id-token: write` permission.

### Publishing to GitHub Packages

```json
["@semantic-release/npm", {
  "npmPublish": true,
  "pkgRoot": "."
}]
```

`.npmrc`:
```
//npm.pkg.github.com/:_authToken=${NPM_TOKEN}
@myorg:registry=https://npm.pkg.github.com
```

`package.json`:
```json
{
  "publishConfig": {
    "registry": "https://npm.pkg.github.com"
  }
}
```

### EPUBLISHCONFLICT — Package Already Published

**Symptom:** npm returns 403 because a version already exists.

**Cause:** Usually a tag mismatch — semantic-release thinks it's a new version but npm already has it.

**Fix:**
```bash
# Check what's on npm
npm view mypackage versions --json

# Check local tags
git tag -l

# If tag exists but npm publish failed, delete the tag and re-run
git tag -d v1.2.3
git push origin :refs/tags/v1.2.3
```

---

## Plugin Errors

### Plugin Ordering Issues

**Critical rule:** Plugins run in the order declared. Order matters.

**Correct order (typical):**
```json
[
  "@semantic-release/commit-analyzer",       // 1. Determine version
  "@semantic-release/release-notes-generator", // 2. Generate notes
  "@semantic-release/changelog",              // 3. Write CHANGELOG
  "@semantic-release/npm",                    // 4. Update package.json + publish
  "@semantic-release/github",                 // 5. Create GitHub release
  "@semantic-release/git"                     // 6. Commit changes (MUST BE LAST)
]
```

**Common mistakes:**
- `@semantic-release/git` before `@semantic-release/changelog` → CHANGELOG changes not committed
- `@semantic-release/npm` before `@semantic-release/changelog` → `package.json` version updated but changelog not written yet
- `@semantic-release/github` before `@semantic-release/npm` → GitHub release created before npm publish (might reference unpublished version)

### EPLUGIN — Plugin Not Found

**Symptom:**
```
EPLUGIN Cannot find module '@semantic-release/changelog'
```

**Fix:**
```bash
# Install the missing plugin
npm install --save-dev @semantic-release/changelog

# Verify it's installed
npm ls @semantic-release/changelog
```

### Plugin Returns Wrong Type

**Symptom:** `TypeError: plugin.publish is not a function`

**Cause:** The plugin module doesn't export the expected lifecycle hooks.

**Diagnostic:**
```bash
node -e "console.log(Object.keys(require('@semantic-release/npm')))"
```

### Multiple Plugins for Same Step

Multiple plugins can implement the same lifecycle step. They run in order:

```json
[
  "@semantic-release/npm",     // publish to npm first
  "@semantic-release/github",  // then create GitHub release
  ["@semantic-release/exec", { "publishCmd": "..." }]  // then run custom command
]
```

Results from all `publish` plugins are collected in the `releases` array passed to `success`.

---

## Branch Configuration Errors

### EINVALIDBRANCH — Branch Not in Config

**Symptom:** `The release branch "develop" is not included in the branches configuration.`

**Fix:** Add the branch to config:
```json
{ "branches": ["main", "develop"] }
```

### EINVALIDNEXTVERSION — Next Version Out of Range

**Symptom:** On a maintenance branch, commit would require a version outside the branch's range.

**Example:** Branch `1.x` with `range: "1.x"` can't create version `2.0.0`.

**Fix:** Breaking changes must go to the main branch, not maintenance branches.

### Branch Name vs. Channel Confusion

```json
{
  "name": "next",         // Git branch name
  "channel": "next",      // npm dist-tag (defaults to branch name if omitted)
  "prerelease": "rc"      // Version identifier (1.0.0-rc.1)
}
```

- `name` must match actual Git branch name
- `channel` is the npm dist-tag; defaults to branch `name` for non-primary branches
- `prerelease` controls the version suffix; `true` uses the branch name, string uses that string

---

## Dry-Run Discrepancies

### Dry-Run Shows Release but CI Doesn't

**Common causes:**

1. **Different Git history:** Local repo has different commits than CI. Compare:
   ```bash
   # Local
   git log --oneline -10

   # CI — add debug step
   - run: git log --oneline -10
   ```

2. **Different branch:** Dry-run ran on wrong branch locally.

3. **Token issues:** Dry-run still needs valid tokens for verification steps. A failed `verifyConditions` aborts before `analyzeCommits`.

4. **`--no-ci` vs `CI=true`:** Local dry-run with `--no-ci` skips CI checks that might fail in actual CI.

### Dry-Run Shows Wrong Version

**Cause:** Dry-run analyzes commits since last tag on the current branch. If local tags are outdated:

```bash
git fetch --tags
npx semantic-release --dry-run
```

---

## GPG Signing Issues

### Signed Commits Failing in CI

**Symptom:** `error: gpg failed to sign the data`

**Fixes:**

1. **Import GPG key in CI:**
   ```yaml
   - name: Import GPG key
     run: echo "${{ secrets.GPG_PRIVATE_KEY }}" | gpg --batch --import

   - name: Configure Git signing
     run: |
       git config user.signingkey ${{ secrets.GPG_KEY_ID }}
       git config commit.gpgsign true
   ```

2. **Disable GPG signing for release commits** (if not required):
   ```yaml
   - run: git config commit.gpgsign false
   ```

3. **GPG TTY issue:**
   ```bash
   export GPG_TTY=$(tty)
   ```

---

## Monorepo Issues

### Wrong Package Released

**Symptom:** Commit to `packages/a` triggers release for `packages/b`.

**Fixes (multi-semantic-release):**
- Ensure `workspaces` in root `package.json` correctly defines package directories
- Check that file paths in commits match expected package directories

**Fixes (semantic-release-monorepo):**
- Verify the `extends: "semantic-release-monorepo"` is present in each package config
- Run from the correct package directory

### Cross-Package Dependencies Not Updated

**Symptom:** Package A depends on Package B. B is released but A's dependency version isn't bumped.

**Fix (multi-semantic-release):** This is automatic — multi-semantic-release detects workspace dependencies and bumps them. Ensure both packages are in `workspaces`.

**Fix (manual):** Use `@semantic-release/exec` to update dependency versions:
```json
["@semantic-release/exec", {
  "prepareCmd": "npm version ${nextRelease.version} --no-git-tag-version --workspace=packages/dependent"
}]
```

---

## Debugging Techniques

### Enable Full Debug Logging

```bash
# All semantic-release debug output
DEBUG=semantic-release:* npx semantic-release --dry-run

# Specific plugin
DEBUG=semantic-release:commit-analyzer npx semantic-release --dry-run

# All debug including dependencies
DEBUG=* npx semantic-release --dry-run 2>&1 | tee release-debug.log
```

### Step-by-Step Verification

```bash
# 1. Verify Git state
git log --oneline -20
git describe --tags --abbrev=0
git remote -v
git branch -a

# 2. Verify tokens
echo "GH: ${GITHUB_TOKEN:0:10}..."
echo "NPM: ${NPM_TOKEN:0:10}..."

# 3. Verify config
npx semantic-release --print-config 2>/dev/null || cat .releaserc.json

# 4. Dry-run with full debug
export CI=true
DEBUG=semantic-release:* npx semantic-release --dry-run 2>&1
```

### CI Debug Step

Add this to your workflow for troubleshooting:

```yaml
- name: Debug release
  if: failure()
  run: |
    echo "=== Git Info ==="
    git log --oneline -10
    git describe --tags --abbrev=0 2>/dev/null || echo "No tags"
    git remote -v
    echo "=== Branch ==="
    git branch -a
    echo "=== Config ==="
    cat .releaserc* 2>/dev/null || echo "No .releaserc"
    echo "=== Node/npm ==="
    node --version
    npm --version
    echo "=== Installed plugins ==="
    npm ls | grep semantic-release
```

---

## Quick Diagnostic Checklist

When a release isn't working, check these in order:

| # | Check | Command |
|---|---|---|
| 1 | Git history is complete | `git rev-list --count HEAD` (should be > 1) |
| 2 | Tags are present | `git tag -l` |
| 3 | Current branch is in config | Check `branches` array in `.releaserc` |
| 4 | Commits follow convention | `git log --oneline -5` — look for `feat:`, `fix:` |
| 5 | Tokens are set | `echo ${GITHUB_TOKEN:0:5}` |
| 6 | Plugins are installed | `npm ls \| grep semantic-release` |
| 7 | Config is valid JSON/JS | `node -e "require('./.releaserc.json')"` |
| 8 | `fetch-depth: 0` in CI | Check checkout step config |
| 9 | `CI=true` is set | `echo $CI` |
| 10 | No tag conflicts | `git tag -l "v*"` vs `npm view pkg versions` |
