# GitHub Actions Troubleshooting Guide

## Table of Contents

- [Workflow Not Triggering](#workflow-not-triggering)
- [Permission Denied Errors](#permission-denied-errors)
- [GITHUB_TOKEN Scope Limitations](#github_token-scope-limitations)
- [Cache Misses](#cache-misses)
- [Artifact Upload Failures](#artifact-upload-failures)
- [Runner Out of Disk Space](#runner-out-of-disk-space)
- [Docker Layer Caching Issues](#docker-layer-caching-issues)
- [Secret Masking Problems](#secret-masking-problems)
- [Concurrency Conflicts](#concurrency-conflicts)
- [Matrix Job Failures](#matrix-job-failures)
- [Reusable Workflow Input Validation](#reusable-workflow-input-validation)
- [Action Version Pinning Warnings](#action-version-pinning-warnings)
- [Rate Limiting](#rate-limiting)
- [Self-Hosted Runner Connectivity](#self-hosted-runner-connectivity)
- [General Debugging Techniques](#general-debugging-techniques)

---

## Workflow Not Triggering

### Symptom: Push/PR doesn't start the workflow

**Check these in order:**

1. **Workflow file location**: Must be in `.github/workflows/` on the **default branch** for schedule/workflow_dispatch, or on the PR's head branch for pull_request triggers.

2. **YAML syntax errors**: A malformed YAML file is silently ignored.
   ```bash
   # Validate locally
   actionlint .github/workflows/ci.yml
   # Or use yamllint
   yamllint .github/workflows/ci.yml
   ```

3. **Branch filter mismatch**:
   ```yaml
   # This only triggers on pushes to main — not develop
   on:
     push:
       branches: [main]
   ```

4. **Path filters exclude all changed files**:
   ```yaml
   # If PR only changes docs/, this never triggers
   on:
     pull_request:
       paths: ['src/**']
   ```

5. **Skipped by commit message**: Commits containing `[skip ci]`, `[ci skip]`, `[no ci]`, `[skip actions]`, or `[actions skip]` in the message skip all workflows.

6. **Workflow disabled**: Check Actions tab → workflow name → "..." menu → ensure it's not disabled.

7. **Fork restrictions**: By default, workflows don't run on first-time contributor PRs. Approve in the Actions tab.

8. **GitHub API/status outage**: Check [githubstatus.com](https://www.githubstatus.com).

### Symptom: `schedule` cron never fires

- Schedule triggers only run on the **default branch** (usually `main`).
- Cron jobs on repos with no recent activity (>60 days) are auto-disabled. Push a commit or manually re-enable.
- GitHub does not guarantee exact cron timing. Peak-hour delays of 10-30 minutes are normal.
- Maximum: 5 scheduled workflows per repo at once.

### Symptom: `workflow_dispatch` not showing in UI

- The workflow must exist on the **default branch** to appear in the Actions UI manual trigger dropdown.
- Verify `on: workflow_dispatch` is defined (not just `on: push`).

---

## Permission Denied Errors

### `Resource not accessible by integration`

The `GITHUB_TOKEN` lacks the required permission.

```yaml
# Fix: Add explicit permissions
permissions:
  contents: read
  pull-requests: write    # For PR comments
  issues: write           # For issue comments
  checks: write           # For check runs
  statuses: write         # For commit statuses
  packages: write         # For package publishing
```

### `refusing to allow a GitHub App to create or update workflow`

Updating `.github/workflows/` files requires `contents: write` AND the token must have workflow scope. `GITHUB_TOKEN` cannot modify workflow files — use a Personal Access Token (PAT) or GitHub App token.

```yaml
- uses: actions/checkout@v4
  with:
    token: ${{ secrets.PAT_WITH_WORKFLOW_SCOPE }}
- run: |
    # Now can commit workflow changes
    git add .github/workflows/
    git commit -m "Update workflow"
    git push
```

### `HttpError: Resource not accessible by personal access token`

Fine-grained PATs require explicit repository and permission grants. Check token settings.

---

## GITHUB_TOKEN Scope Limitations

| Cannot do | Workaround |
|---|---|
| Trigger other workflows | Use PAT, GitHub App token, or `workflow_dispatch` API |
| Push to protected branches | Use PAT or GitHub App with bypass permissions |
| Modify workflow files | Use PAT with `workflow` scope |
| Access other private repos | Use PAT, GitHub App, or deploy keys |
| Create/manage deploy keys | Use PAT with `admin:public_key` scope |
| Manage repo settings | Use PAT with `admin:repo` scope |

The `GITHUB_TOKEN` for `pull_request` events from forks is always read-only — this cannot be overridden.

### Generating a GitHub App token in a workflow

```yaml
- uses: actions/create-github-app-token@v1
  id: app-token
  with:
    app-id: ${{ secrets.APP_ID }}
    private-key: ${{ secrets.APP_PRIVATE_KEY }}
- uses: actions/checkout@v4
  with:
    token: ${{ steps.app-token.outputs.token }}
```

---

## Cache Misses

### Symptom: Cache never hits / always misses

1. **Key mismatch**: Cache keys are exact-match first. If the key changes every run, it never hits.
   ```yaml
   # BAD — timestamp means every run is unique
   key: build-${{ github.run_id }}

   # GOOD — based on lockfile content
   key: ${{ runner.os }}-node-${{ hashFiles('**/package-lock.json') }}
   ```

2. **Branch isolation**: Caches are scoped to branches. A PR branch can read caches from the base branch but not from other PR branches.
   ```
   main → feature-a (can read main's cache)
   main → feature-b (can read main's cache, NOT feature-a's)
   ```

3. **Cache eviction**: 10 GB limit per repo. Least recently used entries are evicted. Entries unused for 7+ days are removed.

4. **`restore-keys` too specific**:
   ```yaml
   # Provide progressively less specific fallbacks
   restore-keys: |
     ${{ runner.os }}-node-${{ hashFiles('**/package-lock.json') }}
     ${{ runner.os }}-node-
     ${{ runner.os }}-
   ```

5. **Immutable caches**: Once a cache key is created, it cannot be updated. You must use a different key to store updated content.

### Debugging cache operations

```yaml
- uses: actions/cache@v4
  id: cache
  with:
    path: node_modules
    key: ${{ runner.os }}-node-${{ hashFiles('**/package-lock.json') }}
- run: echo "Cache hit = ${{ steps.cache.outputs.cache-hit }}"
```

---

## Artifact Upload Failures

### `No files were found with the provided path`

```yaml
# Check the path is correct and files exist
- run: ls -la dist/      # Debug: list files before upload
- uses: actions/upload-artifact@v4
  with:
    name: build
    path: dist/
    if-no-files-found: error    # Fail explicitly instead of silently
```

### Artifact name collision (v4)

`upload-artifact@v4` does **not** allow multiple uploads with the same `name` in the same workflow run.

```yaml
# BAD — collision when matrix jobs use same name
- uses: actions/upload-artifact@v4
  with:
    name: test-results          # Fails for second matrix job

# GOOD — unique names per matrix leg
- uses: actions/upload-artifact@v4
  with:
    name: test-results-${{ matrix.os }}-${{ matrix.node }}
    path: results/
```

To merge artifacts from matrix jobs on download:
```yaml
- uses: actions/download-artifact@v4
  with:
    pattern: test-results-*
    merge-multiple: true
    path: all-results/
```

### Artifact size limits

- Single artifact: 10 GB max.
- Total per repo: check billing/plan limits.
- Use compression before upload for large artifacts.

---

## Runner Out of Disk Space

### Symptom: `No space left on device` or exit code 137

GitHub-hosted runners have ~14 GB free disk space (Ubuntu). Large projects exhaust this.

```yaml
# Check disk at job start
- run: df -h

# Free space by removing pre-installed software
- name: Free disk space
  run: |
    sudo rm -rf /usr/share/dotnet
    sudo rm -rf /usr/local/lib/android
    sudo rm -rf /opt/ghc
    sudo rm -rf /opt/hostedtoolcache/CodeQL
    df -h

# Or use a dedicated action
- uses: jlumbroso/free-disk-space@main
  with:
    tool-cache: false
    android: true
    dotnet: true
    haskell: true
    large-packages: true
```

### Exit code 137

Means the process was killed by OOM (Out of Memory). Solutions:
- Reduce test parallelism (`--maxWorkers=2` for Jest)
- Use a larger runner (`ubuntu-latest-4-cores`)
- Split the job into smaller matrix legs
- Add swap space: `sudo fallocate -l 4G /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile`

---

## Docker Layer Caching Issues

### Build is slow / not caching layers

```yaml
# Use GitHub Actions cache backend for Docker BuildKit
- uses: docker/build-push-action@v6
  with:
    context: .
    push: true
    tags: ghcr.io/org/app:latest
    cache-from: type=gha
    cache-to: type=gha,mode=max

# Alternative: registry-based caching
    cache-from: type=registry,ref=ghcr.io/org/app:buildcache
    cache-to: type=registry,ref=ghcr.io/org/app:buildcache,mode=max
```

### Layer cache invalidation

Docker caches are invalidated when:
- Any preceding layer changes
- `COPY` / `ADD` source files change
- Build arguments change

**Fix**: Order Dockerfile instructions from least to most frequently changing:
```dockerfile
FROM node:20-alpine
WORKDIR /app
COPY package*.json ./         # Changes less often
RUN npm ci                    # Cached if lockfile unchanged
COPY . .                      # Changes most often
RUN npm run build
```

---

## Secret Masking Problems

### Symptom: Secret value visible in logs

GitHub automatically masks secret values in logs, but:

1. **Structured/transformed secrets** may not be masked:
   ```yaml
   # BAD — base64 encoding produces a different string, not masked
   - run: echo "$SECRET" | base64
     env:
       SECRET: ${{ secrets.MY_SECRET }}
   ```

2. **Short secrets** (< 4 chars) are not masked.

3. **Multiline secrets**: Each line is registered as a separate mask, but partial matches may leak.

4. **JSON secrets**: Parse carefully.
   ```yaml
   # Mask individual fields from a JSON secret
   - run: |
       DB_HOST=$(echo '${{ secrets.DB_CONFIG }}' | jq -r '.host')
       echo "::add-mask::$DB_HOST"
       echo "Connecting to $DB_HOST"
   ```

### Manually mask a value

```yaml
- run: |
    TOKEN=$(generate-token)
    echo "::add-mask::$TOKEN"
    echo "token=$TOKEN" >> "$GITHUB_OUTPUT"
```

---

## Concurrency Conflicts

### Symptom: Runs cancel each other unexpectedly

```yaml
# This cancels in-progress runs for the same branch
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
```

**Issue**: If `cancel-in-progress: true` is set at workflow level and you push rapidly, intermediate runs are cancelled — including deploy jobs.

**Fix**: Use different concurrency groups for CI vs CD, or disable cancellation for deploy:
```yaml
# CI workflow — cancel is fine
concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

# Deploy workflow — don't cancel in-progress deploys
concurrency:
  group: deploy-${{ github.event.inputs.environment }}
  cancel-in-progress: false
```

### Symptom: Jobs queued indefinitely

If `cancel-in-progress: false` and the concurrency group is occupied by a stuck/long-running job, subsequent runs queue forever. Set timeout:
```yaml
jobs:
  deploy:
    timeout-minutes: 30    # Prevents infinite hangs
```

---

## Matrix Job Failures

### Symptom: One matrix leg fails, all others cancel

```yaml
strategy:
  fail-fast: false          # Don't cancel siblings on failure
  matrix:
    os: [ubuntu-latest, macos-latest, windows-latest]
```

### Symptom: Matrix job skipped with no error

Check `if:` conditions — a false condition silently skips the job. Debug with:
```yaml
- run: |
    echo "Matrix values: os=${{ matrix.os }}, node=${{ matrix.node }}"
    echo "Event: ${{ github.event_name }}"
    echo "Ref: ${{ github.ref }}"
```

### Symptom: Dynamic matrix produces empty matrix

`fromJSON` with an empty array `[]` causes the job to be skipped entirely (no error). Guard against it:
```yaml
build:
  needs: prepare
  if: needs.prepare.outputs.has-changes == 'true'
  strategy:
    matrix: ${{ fromJSON(needs.prepare.outputs.matrix) }}
```

---

## Reusable Workflow Input Validation

### Symptom: Inputs are always strings

All `workflow_call` inputs are passed as strings, even `boolean` and `number` types. Compare carefully:

```yaml
# In reusable workflow
on:
  workflow_call:
    inputs:
      deploy:
        type: boolean
        default: false

jobs:
  run:
    if: inputs.deploy == true       # Works — GitHub coerces for comparison
    # if: inputs.deploy == 'true'   # Also works, but less clear
```

### Symptom: `secrets: inherit` doesn't pass environment secrets

`secrets: inherit` passes repository and organization secrets, but NOT environment secrets. Environment secrets are only available in jobs with `environment:` set in the reusable workflow itself.

### Constraint: Max 4 levels of reusable workflow nesting

```
caller → reusable-1 → reusable-2 → reusable-3 → reusable-4  # max depth
```

If you exceed this, refactor into composite actions or combine workflows.

### Constraint: Max 20 reusable workflows per workflow file

A single workflow file can call at most 20 reusable workflows (across all jobs). Split into multiple top-level workflows if needed.

---

## Action Version Pinning Warnings

### Dependabot / security scanners flag unpinned actions

```yaml
# WARNING — tag can be repointed to malicious code
- uses: actions/checkout@v4

# SAFE — pinned to immutable commit SHA
- uses: actions/checkout@b4ffde65f46336ab88eb53be808477a3936bae11 # v4.1.1
```

### Finding the SHA for a version

```bash
# Get the commit SHA for a tag
git ls-remote --tags https://github.com/actions/checkout.git v4.1.1
# Or use gh
gh api repos/actions/checkout/git/refs/tags/v4.1.1 --jq '.object.sha'
```

### Automating SHA pinning

```yaml
# .github/dependabot.yml
version: 2
updates:
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly
```

Or use [pin-github-action](https://github.com/mheap/pin-github-action):
```bash
npx pin-github-action .github/workflows/ci.yml
```

---

## Rate Limiting

### GitHub API rate limits in workflows

| Token type | Rate limit |
|---|---|
| `GITHUB_TOKEN` | 1,000 requests/hour per repo |
| PAT (classic) | 5,000 requests/hour per user |
| GitHub App | 5,000 requests/hour per installation (+ scaling) |

### Symptom: `API rate limit exceeded`

```yaml
# Add retry logic
- uses: actions/github-script@v7
  with:
    script: |
      const { data } = await github.rest.rateLimit.get();
      console.log(`Remaining: ${data.rate.remaining}/${data.rate.limit}`);

      // Use retry with backoff
      await github.rest.issues.createComment({
        ...context.repo,
        issue_number: 1,
        body: 'Hello',
        request: { retries: 3, retryAfter: 60 }
      });
```

### Workflow run limits

| Limit | Value |
|---|---|
| Concurrent jobs (Free) | 20 |
| Concurrent jobs (Team) | 40 |
| Concurrent jobs (Enterprise) | 500 |
| Concurrent macOS jobs | 5 (Free) |
| Matrix jobs per workflow run | 256 |
| Workflow run duration | 35 days (jobs: 6 hours each) |
| API requests per workflow run | 1,000 (GITHUB_TOKEN) |
| Queued workflow runs | 500 per 10-second window per repo |

---

## Self-Hosted Runner Connectivity

### Required network access

Allow outbound HTTPS (443) to:
- `github.com`
- `api.github.com`
- `*.actions.githubusercontent.com`
- `ghcr.io` (if using GHCR)
- `*.pkg.github.com` (if using packages)
- `pipelines.actions.githubusercontent.com`
- `results-receiver.actions.githubusercontent.com`

### Symptom: Runner appears offline

1. Check the runner service: `sudo ./svc.sh status`
2. Check logs: `_diag/Runner_*.log` and `_diag/Worker_*.log`
3. Verify network connectivity: `curl -v https://api.github.com`
4. Re-register if token expired: tokens expire after 1 hour

### Symptom: Jobs stuck in "Queued"

- No runner matches the required labels. Check `runs-on:` labels match the runner's labels exactly.
- Runner is busy (not ephemeral / limited concurrency).
- Runner group doesn't include the repo.

### Proxy configuration

```bash
export http_proxy=http://proxy.example.com:8080
export https_proxy=http://proxy.example.com:8080
export no_proxy=localhost,127.0.0.1
./config.sh --url https://github.com/org/repo --token <TOKEN>
```

---

## General Debugging Techniques

### Enable debug logging

```yaml
# Set these as repository secrets (not variables)
ACTIONS_RUNNER_DEBUG: true      # Runner diagnostic logs
ACTIONS_STEP_DEBUG: true        # Step debug output (::debug:: messages)
```

Or re-run a specific job with "Enable debug logging" checkbox in the UI.

### Inspect contexts

```yaml
- name: Dump contexts
  run: |
    echo "github = $GITHUB_CONTEXT"
    echo "env = $ENV_CONTEXT"
    echo "job = $JOB_CONTEXT"
  env:
    GITHUB_CONTEXT: ${{ toJSON(github) }}
    ENV_CONTEXT: ${{ toJSON(env) }}
    JOB_CONTEXT: ${{ toJSON(job) }}
```

### Run workflows locally with `act`

```bash
# Install act
brew install act   # or: curl -sfL https://raw.githubusercontent.com/nektos/act/master/install.sh | sudo bash

# Run default event (push)
act

# Run specific workflow and job
act -W .github/workflows/ci.yml -j build

# Pass secrets
act -s GITHUB_TOKEN="$(gh auth token)"

# Use specific event
act pull_request --eventpath event.json
```

### actionlint for static analysis

```bash
# Install
brew install actionlint   # or: go install github.com/rhysd/actionlint/cmd/actionlint@latest

# Lint all workflows
actionlint

# Lint specific file
actionlint .github/workflows/ci.yml

# Common checks: expression syntax, action inputs, runner labels, shell syntax, deprecated features
```

### Workflow timing analysis

```yaml
# Add timestamps to track slow steps
- run: |
    START=$(date +%s)
    npm test
    END=$(date +%s)
    echo "Tests took $((END - START)) seconds"
```

Use the Actions UI timing breakdown (click any job → see step-by-step durations) to find bottlenecks.
