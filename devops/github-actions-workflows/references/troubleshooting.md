# GitHub Actions Troubleshooting Guide

## Table of Contents

- [Workflow Syntax Errors and Validation](#workflow-syntax-errors-and-validation)
- [Resource Not Accessible by Integration](#resource-not-accessible-by-integration)
- [Actions Failing Silently](#actions-failing-silently)
- [Cache Key Mismatches and Debugging](#cache-key-mismatches-and-debugging)
- [Rate Limiting and API Quota Issues](#rate-limiting-and-api-quota-issues)
- [Self-Hosted Runner Connectivity Issues](#self-hosted-runner-connectivity-issues)
- [Secrets Not Available in Fork PRs](#secrets-not-available-in-fork-prs)
- [Artifact Upload/Download Failures](#artifact-uploaddownload-failures)
- [Timeout Tuning and Job Duration Optimization](#timeout-tuning-and-job-duration-optimization)
- [Matrix Job Failures (fail-fast vs continue-on-error)](#matrix-job-failures-fail-fast-vs-continue-on-error)
- [Debugging with ACTIONS_STEP_DEBUG and tmate](#debugging-with-actions_step_debug-and-tmate)
- [Workflow Not Triggering](#workflow-not-triggering)

---

## Workflow Syntax Errors and Validation

### Common YAML syntax mistakes

**Indentation errors** — the most frequent cause of workflow parse failures:

```yaml
# BAD: steps not indented under job
jobs:
  build:
    runs-on: ubuntu-latest
  steps:  # Wrong: should be indented under build
    - run: echo hello

# GOOD:
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: echo hello
```

**Missing `on` trigger** — workflow will never run:

```yaml
# BAD: 'on' is missing
name: CI
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: echo hello

# GOOD:
name: CI
on: [push]
jobs:
  build: ...
```

**Unquoted `on` key** — in some YAML parsers `on` is interpreted as boolean `true`:

```yaml
# Potential issue in strict YAML parsers:
on:
  push:

# Safer (though GitHub handles this fine):
"on":
  push:
```

**Invalid expression syntax**:

```yaml
# BAD: missing braces
if: github.ref == 'refs/heads/main'
# Technically works, but this does NOT:
if: ${{ github.ref == 'refs/heads/main' && github.actor == 'dependabot' }}
# Must handle string comparison carefully:
# BAD:
if: ${{ github.event.action == 'opened' || 'synchronize' }}  # Always true! 'synchronize' is truthy
# GOOD:
if: ${{ github.event.action == 'opened' || github.event.action == 'synchronize' }}
```

### Validation tools

```bash
# Validate locally with actionlint (recommended)
brew install actionlint  # or: go install github.com/rhysd/actionlint/cmd/actionlint@latest
actionlint .github/workflows/*.yml

# Validate with GitHub CLI
gh workflow view ci.yml

# Check-jsonschema against the official schema
pip install check-jsonschema
check-jsonschema --schemafile \
  "https://json.schemastore.org/github-workflow.json" \
  .github/workflows/ci.yml
```

`actionlint` catches:
- Invalid `runs-on` labels
- Undefined action inputs
- Expression type errors (e.g., comparing string to number)
- Unreachable jobs (circular `needs`)
- `shellcheck` integration for `run` steps

### Common actionlint findings and fixes

```
# "property X is not defined in object type Y"
# Fix: Check that you're using correct context — e.g., github.event.pull_request only exists on PR events

# "label X is unknown"
# Fix: Use valid runner labels. Custom labels need quotes if they contain special chars

# "workflow_call event can't be triggered with other events"
# Fix: A reusable workflow (workflow_call) cannot also have push/pr triggers. Split into two files.
```

---

## Resource Not Accessible by Integration

This is the most confusing GitHub Actions error. It means the `GITHUB_TOKEN` lacks the required permission.

### Diagnosis

The error appears as:
```
Error: Resource not accessible by integration
```

### Common causes and fixes

**1. Missing `permissions` block** — default token permissions depend on repo/org settings:

```yaml
# Fix: Explicitly declare needed permissions
permissions:
  contents: read
  pull-requests: write
  issues: write

jobs:
  comment:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/github-script@v7
        with:
          script: |
            await github.rest.issues.createComment({
              ...context.repo,
              issue_number: context.issue.number,
              body: 'Hello!'
            });
```

**2. Fork PR restrictions** — `GITHUB_TOKEN` on fork PRs has read-only permissions by default. Cannot write to the base repo.

**3. Organization-level restriction** — the org may have set default token permissions to "read" only. Check: **Org Settings → Actions → General → Workflow permissions**.

**4. Permission needed per operation**:

| Operation | Required Permission |
|---|---|
| Create/update PR comment | `pull-requests: write` |
| Create issue | `issues: write` |
| Push commits | `contents: write` |
| Create release | `contents: write` |
| Update deployment status | `deployments: write` |
| Read packages | `packages: read` |
| Push packages | `packages: write` |
| Request OIDC token | `id-token: write` |
| Read Actions cache | `actions: read` |
| Write Actions cache | `actions: write` |
| Manage checks | `checks: write` |
| Read org members | `members: read` |

**5. Job-level permission override**:

```yaml
permissions:
  contents: read  # Workflow-level: restrictive

jobs:
  deploy:
    permissions:
      contents: read
      deployments: write  # Job-level: additional permission
    steps:
      - run: ./deploy.sh
```

When you set `permissions` at the job level, it **replaces** (not merges with) the workflow-level permissions. Always include all permissions the job needs.

---

## Actions Failing Silently

### Exit code swallowed by pipes

```yaml
# BAD: grep failure (no match) is swallowed by the pipe
- run: cat results.txt | grep "PASS" | wc -l

# GOOD: Enable pipefail
- run: |
    set -euo pipefail
    cat results.txt | grep "PASS" | wc -l
  shell: bash
```

The default shell for `run` is `bash --noprofile --norc -e -o pipefail {0}` on Linux/macOS, so `pipefail` IS enabled. But if you use `shell: sh` or `shell: /bin/bash {0}`, pipefail is NOT set.

### Deprecated `set-output` command

The `::set-output` workflow command was deprecated (disabled November 2023). Use `$GITHUB_OUTPUT` instead:

```yaml
# DEPRECATED (silently fails on newer runners):
- run: echo "::set-output name=version::1.0.0"

# CORRECT:
- run: echo "version=1.0.0" >> "$GITHUB_OUTPUT"
  id: my_step
```

Similarly deprecated:
- `::save-state` → use `$GITHUB_STATE`
- `::set-env` → use `$GITHUB_ENV`
- `add-path` → use `$GITHUB_PATH`

### Multiline output values

```yaml
# BAD: Breaks on newlines
- run: echo "report=$(cat report.txt)" >> "$GITHUB_OUTPUT"

# GOOD: Use heredoc delimiter for multiline
- run: |
    {
      echo "report<<EOF"
      cat report.txt
      echo "EOF"
    } >> "$GITHUB_OUTPUT"
```

### `continue-on-error` masking failures

```yaml
# This job appears green even if the step fails
- run: npm test
  continue-on-error: true

# Check the actual outcome:
- run: npm test
  id: test
  continue-on-error: true
- run: |
    if [ "${{ steps.test.outcome }}" = "failure" ]; then
      echo "::warning::Tests failed but were non-blocking"
    fi
```

### Silent action failures

Some third-party actions catch errors internally and log warnings instead of failing. Always verify:

```yaml
- uses: some-action/deploy@v1
  id: deploy
- run: |
    if [ -z "${{ steps.deploy.outputs.url }}" ]; then
      echo "::error::Deploy action produced no URL output"
      exit 1
    fi
```

---

## Cache Key Mismatches and Debugging

### Diagnosing cache misses

```yaml
- uses: actions/cache@v4
  id: cache
  with:
    path: node_modules
    key: npm-${{ runner.os }}-${{ hashFiles('**/package-lock.json') }}
    restore-keys: |
      npm-${{ runner.os }}-

# Check if cache was hit
- run: echo "Cache hit = ${{ steps.cache.outputs.cache-hit }}"
```

### Common cache miss causes

**1. Wrong `hashFiles` glob**:

```yaml
# BAD: Only checks root lock file, misses workspace lock files
key: npm-${{ hashFiles('package-lock.json') }}

# GOOD: Check all lock files
key: npm-${{ hashFiles('**/package-lock.json') }}
```

**2. Path doesn't match what was cached**:

```yaml
# Cached ~/.npm but trying to restore node_modules
- uses: actions/cache@v4
  with:
    path: node_modules           # Should match what you want to skip reinstalling
    key: modules-${{ hashFiles('**/package-lock.json') }}

# Or cache the npm download cache:
- uses: actions/cache@v4
  with:
    path: ~/.npm                 # npm's download cache, still need npm ci
    key: npm-cache-${{ hashFiles('**/package-lock.json') }}
```

**3. OS-specific binaries cached across platforms**:

```yaml
# BAD: Same key on all platforms
key: deps-${{ hashFiles('**/package-lock.json') }}

# GOOD: Include OS in key
key: deps-${{ runner.os }}-${{ hashFiles('**/package-lock.json') }}
```

**4. Cache eviction** — 10 GB per repo limit. LRU eviction removes old entries:

```bash
# List caches via CLI
gh cache list --limit 20

# Delete specific cache
gh cache delete "npm-Linux-abc123"

# Delete all caches matching a pattern
gh cache list --json key -q '.[].key' | grep "old-prefix" | while read k; do
  gh cache delete "$k"
done
```

**5. Branch scoping** — caches from the default branch are available to all branches. Feature branch caches are only available to that branch. PRs can read caches from the base branch.

### Debugging hashFiles

```yaml
# Print what hashFiles evaluates to
- run: |
    echo "Hash: ${{ hashFiles('**/package-lock.json') }}"
    echo "Files matched:"
    find . -name 'package-lock.json' -not -path '*/node_modules/*'
```

---

## Rate Limiting and API Quota Issues

### GITHUB_TOKEN rate limits

- **1,000 API requests per hour per repo** for `GITHUB_TOKEN` in Actions.
- GraphQL API: 1,000 points per hour.
- Search API: 30 requests per minute.

### Symptoms

```
Error: API rate limit exceeded for installation ID XXXX
Error: You have exceeded a secondary rate limit
```

### Mitigation strategies

```yaml
# 1. Reduce API calls with batching
- uses: actions/github-script@v7
  with:
    script: |
      // BAD: One API call per label
      for (const label of labels) {
        await github.rest.issues.addLabels({...context.repo, issue_number: 1, labels: [label]});
      }
      // GOOD: One API call for all labels
      await github.rest.issues.addLabels({
        ...context.repo,
        issue_number: 1,
        labels: labels
      });

# 2. Add retry logic with backoff
- uses: actions/github-script@v7
  with:
    script: |
      const { Octokit } = require('@octokit/rest');
      // @octokit/plugin-retry handles 429 automatically
      // actions/github-script already includes retry by default

# 3. Use conditional requests (304 Not Modified)
- run: |
    ETAG=$(cat .cache/etag 2>/dev/null || echo "")
    RESPONSE=$(curl -s -w "\n%{http_code}" \
      -H "Authorization: Bearer ${{ secrets.GITHUB_TOKEN }}" \
      -H "If-None-Match: $ETAG" \
      "https://api.github.com/repos/${{ github.repository }}/pulls")
    HTTP_CODE=$(echo "$RESPONSE" | tail -1)
    if [ "$HTTP_CODE" = "304" ]; then
      echo "No changes, using cached data"
    fi
```

### Secondary rate limits

GitHub enforces concurrent request limits. You may hit these with parallel matrix jobs all making API calls:

```yaml
strategy:
  max-parallel: 3  # Limit concurrency to reduce API pressure
  matrix:
    project: [a, b, c, d, e]
```

### Git operations rate limits

```yaml
# Shallow clone to reduce data transfer
- uses: actions/checkout@v4
  with:
    fetch-depth: 1  # Default. Use 0 only when you need full history

# Sparse checkout for large repos
- uses: actions/checkout@v4
  with:
    sparse-checkout: |
      src/
      tests/
    sparse-checkout-cone-mode: true
```

---

## Self-Hosted Runner Connectivity Issues

### Runner not picking up jobs

**Check runner status**:

```bash
# On the runner machine
cd /home/runner/actions-runner
cat _diag/Runner_*.log | tail -50

# Check systemd service
sudo systemctl status actions.runner.*

# Verify connectivity
curl -s -o /dev/null -w "%{http_code}" https://api.github.com
curl -s -o /dev/null -w "%{http_code}" https://github.com
```

**Required network access** (all HTTPS/443):
- `github.com`
- `api.github.com`
- `*.actions.githubusercontent.com`
- `ghcr.io` and `*.pkg.github.com` (if using packages)
- `results-receiver.actions.githubusercontent.com`
- `*.blob.core.windows.net` (artifact/cache storage)

### Runner goes offline during a job

Common causes:
1. **OOM killer** — the job exhausted memory. Check `dmesg | grep -i oom`.
2. **Disk full** — check `df -h`. Clean `_work` directory.
3. **Token expiration** — re-register the runner.
4. **Network interruption** — check runner logs for reconnection attempts.

```bash
# Clean up disk on self-hosted runner
cd /home/runner/actions-runner
# Remove old work directories (careful — don't delete active jobs)
find _work -maxdepth 1 -mtime +7 -exec rm -rf {} +

# Prune Docker (if runner runs Docker jobs)
docker system prune -af --volumes
```

### Labels not matching

```yaml
# Workflow specifies:
runs-on: [self-hosted, linux, gpu]

# Runner must have ALL of these labels. Check:
cd /home/runner/actions-runner
cat .runner | jq '.agentLabels'
# Re-configure to add labels:
./config.sh --labels self-hosted,linux,gpu --replace
```

### Runner version mismatch

GitHub requires runners to be within 30 days of the latest version. Auto-update is enabled by default but can be blocked by firewalls.

```bash
# Check runner version
./run.sh --version

# Manual update
./bin/Runner.Listener --version
# Download latest from https://github.com/actions/runner/releases
```

---

## Secrets Not Available in Fork PRs

### The problem

For security, GitHub does not expose repository secrets to workflows triggered by PRs from forks. `${{ secrets.MY_SECRET }}` evaluates to an empty string.

### Identifying the issue

```yaml
- run: |
    if [ -z "${{ secrets.API_KEY }}" ]; then
      echo "::warning::API_KEY is not available (likely a fork PR)"
      echo "is_fork=true" >> "$GITHUB_OUTPUT"
    fi
  id: check
```

### Solutions

**1. Split privileged steps** — use `workflow_run` to run privileged operations after an untrusted PR build:

```yaml
# ci.yml — runs on PR (no secrets needed)
on: [pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: npm test
      - uses: actions/upload-artifact@v4
        with:
          name: test-results
          path: results/

# report.yml — runs after CI completes (has secrets)
on:
  workflow_run:
    workflows: ["CI"]
    types: [completed]
permissions:
  pull-requests: write
jobs:
  report:
    if: github.event.workflow_run.event == 'pull_request'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/download-artifact@v4
        with:
          run-id: ${{ github.event.workflow_run.id }}
          name: test-results
          github-token: ${{ secrets.GITHUB_TOKEN }}
      - run: ./post-results-to-pr.sh
        env:
          API_KEY: ${{ secrets.API_KEY }}
```

**2. Skip secret-dependent steps on forks**:

```yaml
- name: Deploy preview
  if: github.event.pull_request.head.repo.full_name == github.repository
  run: ./deploy-preview.sh
  env:
    DEPLOY_TOKEN: ${{ secrets.DEPLOY_TOKEN }}
```

**3. Use `pull_request_target`** (use with extreme caution — see security-best-practices.md):

```yaml
on:
  pull_request_target:
    # Runs in the context of the BASE branch with secrets available
    # NEVER checkout and execute code from the PR head without review
```

---

## Artifact Upload/Download Failures

### Upload failures

**1. No files found**:

```
Error: No files were found with the provided path: dist/
```

```yaml
# Fix: Verify path exists before upload
- run: ls -la dist/
- uses: actions/upload-artifact@v4
  with:
    name: build
    path: dist/
    if-no-files-found: warn  # 'error' (default), 'warn', or 'ignore'
```

**2. Name conflicts** — artifact v4 requires unique names within a workflow run:

```yaml
# BAD: Same name in matrix
strategy:
  matrix:
    os: [ubuntu-latest, macos-latest]
steps:
  - uses: actions/upload-artifact@v4
    with:
      name: build-output  # Conflict!
      path: dist/

# GOOD: Unique names per matrix leg
  - uses: actions/upload-artifact@v4
    with:
      name: build-output-${{ matrix.os }}
      path: dist/
```

**3. Large artifact failures** — default upload chunk size may cause timeouts:

```yaml
- uses: actions/upload-artifact@v4
  with:
    name: large-build
    path: build/
    compression-level: 6  # 0-9, higher = smaller but slower
    retention-days: 3     # Reduce retention for large files
```

### Download failures

**1. Artifact not found** — artifact was uploaded in a different workflow run:

```yaml
# Download from the current run (default)
- uses: actions/download-artifact@v4
  with:
    name: build-output

# Download from a specific run
- uses: actions/download-artifact@v4
  with:
    name: build-output
    run-id: 12345678
    github-token: ${{ secrets.GITHUB_TOKEN }}  # Required for cross-run downloads
```

**2. Download all matrix artifacts**:

```yaml
- uses: actions/download-artifact@v4
  with:
    pattern: build-output-*
    merge-multiple: true   # Merge all into one directory
    path: all-builds/
```

**3. Artifact expired** — default retention is 90 days (configurable). Expired artifacts cannot be recovered.

### Artifact v3 → v4 migration issues

Artifact v4 (`actions/upload-artifact@v4`) introduced breaking changes:
- Artifact names must be unique within a run (v3 allowed overwriting).
- Artifact immutability — cannot re-upload with the same name.
- New backend with improved performance but different size limits.

---

## Timeout Tuning and Job Duration Optimization

### Setting appropriate timeouts

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    timeout-minutes: 15  # Job-level timeout (default: 360 = 6 hours)
    steps:
      - run: npm ci
        timeout-minutes: 5  # Step-level timeout

      - name: Run tests with generous timeout
        run: npm test
        timeout-minutes: 10
```

### Finding slow steps

```bash
# Download and analyze workflow run timing
gh run view RUN_ID --json jobs --jq '.jobs[] | {name, duration: ((.completedAt | fromdateiso8601) - (.startedAt | fromdateiso8601))}'

# Or use the "Workflow run" timing summary in the GitHub UI
```

### Common performance improvements

**1. Parallel test execution**:

```yaml
# Split tests across matrix jobs
jobs:
  test:
    strategy:
      matrix:
        shard: [1, 2, 3, 4]
    steps:
      - run: npx jest --shard=${{ matrix.shard }}/4
```

**2. Avoid unnecessary checkouts**:

```yaml
# Only fetch what you need
- uses: actions/checkout@v4
  with:
    fetch-depth: 1          # Shallow clone (default)
    sparse-checkout: src/   # Only checkout src directory
```

**3. Docker layer caching**:

```yaml
- uses: docker/build-push-action@v6
  with:
    context: .
    cache-from: type=gha
    cache-to: type=gha,mode=max
```

**4. Skip redundant installs with cache**:

```yaml
- uses: actions/cache@v4
  id: deps
  with:
    path: node_modules
    key: modules-${{ hashFiles('package-lock.json') }}
- if: steps.deps.outputs.cache-hit != 'true'
  run: npm ci
```

---

## Matrix Job Failures (fail-fast vs continue-on-error)

### `fail-fast` behavior

```yaml
strategy:
  fail-fast: true   # Default. Cancels ALL running matrix jobs when ANY job fails
  matrix:
    os: [ubuntu-latest, macos-latest, windows-latest]
```

When one matrix leg fails with `fail-fast: true`, GitHub sends cancellation signals to other running legs. Those cancelled jobs show as "cancelled" — not "failed" — which can be confusing.

### When to disable `fail-fast`

```yaml
strategy:
  fail-fast: false  # Let all matrix legs complete, even if some fail
  matrix:
    os: [ubuntu-latest, macos-latest, windows-latest]
```

Use `fail-fast: false` when:
- You want to see the full failure picture across all platforms.
- Failures on one OS don't indicate failures on others.
- Running a compatibility test suite.

### `continue-on-error` at the job level

```yaml
jobs:
  experimental:
    runs-on: ubuntu-latest
    continue-on-error: true  # Job failure won't fail the workflow
    steps:
      - run: npm run experimental-tests

  required:
    runs-on: ubuntu-latest
    needs: experimental  # Still runs even if experimental "failed"
    steps:
      - run: echo "Result was ${{ needs.experimental.result }}"
```

### Combining with matrix (allow specific failures)

```yaml
jobs:
  test:
    strategy:
      fail-fast: false
      matrix:
        node: ['20', '22', '23']
        include:
          - node: '23'
            experimental: true
    runs-on: ubuntu-latest
    continue-on-error: ${{ matrix.experimental || false }}
    steps:
      - uses: actions/setup-node@v4
        with:
          node-version: ${{ matrix.node }}
      - run: npm test
```

### Aggregating matrix results

```yaml
jobs:
  test:
    strategy:
      fail-fast: false
      matrix:
        shard: [1, 2, 3]
    runs-on: ubuntu-latest
    steps:
      - run: npm test -- --shard=${{ matrix.shard }}/3

  check-results:
    needs: test
    if: always()
    runs-on: ubuntu-latest
    steps:
      - run: |
          if [ "${{ needs.test.result }}" != "success" ]; then
            echo "::error::One or more test shards failed"
            exit 1
          fi
```

---

## Debugging with ACTIONS_STEP_DEBUG and tmate

### Enabling debug logging

**Method 1: Repository variable** (persistent):
- Go to **Settings → Secrets and variables → Actions → Variables**.
- Add `ACTIONS_STEP_DEBUG` = `true`.
- Add `ACTIONS_RUNNER_DEBUG` = `true` (for runner-level diagnostics).

**Method 2: Re-run with debug** (one-time):
- On any workflow run page, click **Re-run all jobs** → check **Enable debug logging**.

**Method 3: Workflow dispatch input**:

```yaml
on:
  workflow_dispatch:
    inputs:
      debug:
        description: 'Enable debug logging'
        type: boolean
        default: false

jobs:
  build:
    runs-on: ubuntu-latest
    env:
      ACTIONS_STEP_DEBUG: ${{ inputs.debug }}
    steps:
      - run: echo "Debug mode is ${{ inputs.debug }}"
```

### What debug logging reveals

With `ACTIONS_STEP_DEBUG=true`, you see:
- Full HTTP request/response for action downloads.
- Exact command executed for each `run` step (including environment variables).
- Cache key matching details.
- Expression evaluation results.
- Token permissions used for each API call.

### Conditional debug output

```yaml
steps:
  - name: Debug info
    if: runner.debug == '1'
    run: |
      echo "::group::Environment Variables"
      env | sort
      echo "::endgroup::"

      echo "::group::Disk Usage"
      df -h
      echo "::endgroup::"

      echo "::group::Docker Info"
      docker info 2>/dev/null || echo "Docker not available"
      echo "::endgroup::"

      echo "::group::Network"
      ip addr show 2>/dev/null || ifconfig
      echo "::endgroup::"
```

### Interactive debugging with tmate

```yaml
steps:
  - name: Build
    run: npm run build
    id: build

  # Drop into SSH on failure
  - name: Debug session
    if: failure() && steps.build.outcome == 'failure'
    uses: mxschmitt/action-tmate@v3
    with:
      limit-access-to-actor: true
      detached: false
    timeout-minutes: 30

  # Or: always allow debug when triggered manually
  - name: Debug session (manual trigger)
    if: github.event_name == 'workflow_dispatch' && inputs.debug
    uses: mxschmitt/action-tmate@v3
    with:
      limit-access-to-actor: true
```

After the tmate step runs, the log shows:

```
SSH: ssh abcdef123@nyc1.tmate.io
Web shell: https://tmate.io/t/abcdef123
```

Common debugging commands once connected:

```bash
# Check workspace
ls -la $GITHUB_WORKSPACE

# Check environment
env | grep GITHUB

# Test commands manually
cd $GITHUB_WORKSPACE && npm test

# When done, create a continue file to resume the workflow
touch /tmp/continue
```

---

## Workflow Not Triggering

### Checklist when a workflow doesn't fire

**1. Workflow file location** — must be in `.github/workflows/` on the **default branch** for most events (except `push` and `pull_request` which use the ref being pushed/PRed).

**2. Workflow file syntax** — a YAML syntax error silently prevents the workflow from being registered. Validate with `actionlint`.

**3. Event type mismatch**:

```yaml
# Only triggers on opened PRs, NOT on new pushes to the PR
on:
  pull_request:
    types: [opened]

# For all PR activity (opened, synchronize, reopened — the defaults):
on:
  pull_request:
  # types defaults to: [opened, synchronize, reopened]
```

**4. Branch/path filter too restrictive**:

```yaml
# This only runs on pushes to main that change files in src/
on:
  push:
    branches: [main]
    paths: ['src/**']
# A push to main that only changes docs/ will NOT trigger this workflow
```

**5. `workflow_run` only triggers from the default branch**:

```yaml
# This workflow definition must exist on the default branch (e.g., main)
on:
  workflow_run:
    workflows: ["Build"]
    types: [completed]
# If you add this on a feature branch, it won't trigger until merged to default
```

**6. Skipped due to path filtering on the PR base**:

For `pull_request`, `paths` filters compare the PR diff against the base branch. If no matching files changed, the workflow is skipped — and the PR may be unblocked by required checks skipping.

**7. Disabled workflows** — check **Actions → Workflows** in the repo UI. Workflows can be disabled manually or automatically (after 60 days of no repo activity on free plans).

**8. Fork restrictions** — org settings may restrict fork PRs from running workflows entirely. Check **Org → Settings → Actions → Fork pull request workflows**.

**9. Maximum workflow file count** — repos are limited to 20 concurrent workflow runs by default. Also, GitHub limits to detecting ~600 workflow files.

**10. Commit authored by GitHub Actions** — pushes made by `GITHUB_TOKEN` do not trigger `push` or `pull_request` events (to prevent infinite loops). Use a PAT or GitHub App token if you need downstream triggers:

```yaml
- uses: actions/checkout@v4
  with:
    token: ${{ secrets.PAT_TOKEN }}  # PAT triggers downstream workflows
- run: |
    git commit -m "Automated update"
    git push
```

### Debugging trigger issues

```bash
# Check recent workflow runs (including skipped)
gh run list --workflow=ci.yml --limit 10

# Check if the workflow is registered
gh workflow list

# Check if the workflow is disabled
gh workflow view ci.yml
```
