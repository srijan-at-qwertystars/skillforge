---
name: github-actions-workflows
description: >
  Use when user creates or debugs GitHub Actions workflows, asks about CI/CD pipelines
  in .github/workflows/, reusable workflows, composite actions, matrix builds, artifact
  caching, secrets management, or workflow_dispatch triggers.
  Do NOT use for GitLab CI, Jenkins, CircleCI, or other CI/CD platforms.
  Do NOT use for GitHub API or GitHub CLI questions unrelated to Actions.
---

# GitHub Actions Workflows

## Workflow YAML Anatomy

Every workflow lives in `.github/workflows/`. Core structure:

```yaml
name: CI

on:
  push:
    branches: [main]
    paths: ['src/**', 'tests/**']
  pull_request:
    branches: [main]
  workflow_dispatch:
    inputs:
      environment:
        description: 'Target environment'
        required: true
        default: 'staging'
        type: choice
        options: [staging, production]
  schedule:
    - cron: '0 6 * * 1'  # Every Monday at 06:00 UTC

permissions:
  contents: read

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: npm run lint

  test:
    needs: lint
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: npm test

  deploy:
    needs: [lint, test]
    runs-on: ubuntu-latest
    steps:
      - run: echo "Deploy"
```

Key rules:
- `on` defines triggers. Combine `push`, `pull_request`, `workflow_dispatch`, `schedule`, `workflow_call`.
- `needs` declares job dependencies. Jobs without `needs` run in parallel.
- `permissions` sets `GITHUB_TOKEN` scopes. Always set at workflow level; override per-job if needed.
- Use `paths` and `branches` filters to avoid unnecessary runs.

## Reusable Workflows

Define a workflow callable by other workflows via `workflow_call`.

### Callee (reusable workflow)

```yaml
# .github/workflows/build.yml
on:
  workflow_call:
    inputs:
      node-version:
        required: true
        type: string
      environment:
        required: false
        type: string
        default: 'staging'
    secrets:
      DEPLOY_KEY:
        required: true
    outputs:
      artifact-url:
        description: 'URL of the built artifact'
        value: ${{ jobs.build.outputs.url }}

jobs:
  build:
    runs-on: ubuntu-latest
    outputs:
      url: ${{ steps.upload.outputs.url }}
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: ${{ inputs.node-version }}
      - run: npm ci && npm run build
      - id: upload
        run: echo "url=https://example.com/artifact" >> $GITHUB_OUTPUT
```

### Caller

```yaml
jobs:
  call-build:
    uses: my-org/shared-workflows/.github/workflows/build.yml@v2
    with:
      node-version: '22'
    secrets:
      DEPLOY_KEY: ${{ secrets.DEPLOY_KEY }}

  # Or inherit all secrets:
  call-build-inherit:
    uses: ./.github/workflows/build.yml
    with:
      node-version: '22'
    secrets: inherit

  post-build:
    needs: call-build
    runs-on: ubuntu-latest
    steps:
      - run: echo "${{ needs.call-build.outputs.artifact-url }}"
```

Constraints:
- Max 4 levels of nesting.
- Reusable workflows must be in `.github/workflows/` (no subdirectories).
- Pin to SHA or tag, not branch.
- Environment secrets cannot be passed via `workflow_call`; only workflow-level secrets.

## Composite Actions

Bundle multiple steps into a single reusable action. Define in `action.yml`.

```yaml
# .github/actions/setup-and-test/action.yml
name: 'Setup and Test'
description: 'Install deps and run tests'
inputs:
  node-version:
    description: 'Node.js version'
    required: false
    default: '22'
outputs:
  coverage:
    description: 'Coverage percentage'
    value: ${{ steps.test.outputs.coverage }}
runs:
  using: 'composite'
  steps:
    - uses: actions/setup-node@v4
      with:
        node-version: ${{ inputs.node-version }}
    - run: npm ci
      shell: bash
    - id: test
      run: |
        COVERAGE=$(npm test -- --coverage 2>&1 | grep 'All files' | awk '{print $4}')
        echo "coverage=$COVERAGE" >> $GITHUB_OUTPUT
      shell: bash
```

Use in a workflow:

```yaml
steps:
  - uses: actions/checkout@v4
  - uses: ./.github/actions/setup-and-test
    id: test
    with:
      node-version: '22'
  - run: echo "Coverage is ${{ steps.test.outputs.coverage }}%"
```

Composite vs reusable workflows:
- Composite actions encapsulate **steps** within a job. Use for shared setup/teardown logic.
- Reusable workflows encapsulate **entire jobs**. Use for full pipeline orchestration.

## Matrix Strategy

Run a job across multiple configurations in parallel.

```yaml
jobs:
  test:
    strategy:
      fail-fast: false          # Don't cancel others on first failure
      max-parallel: 4           # Limit concurrent jobs
      matrix:
        os: [ubuntu-latest, macos-latest, windows-latest]
        node: ['20', '22']
        include:
          - os: ubuntu-latest
            node: '22'
            coverage: true      # Extra variable for this combo
        exclude:
          - os: windows-latest
            node: '20'         # Skip this combination
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: ${{ matrix.node }}
      - run: npm test
      - if: matrix.coverage
        run: npm run coverage
```

Dynamic matrix from a prior job:

```yaml
jobs:
  detect:
    runs-on: ubuntu-latest
    outputs:
      packages: ${{ steps.find.outputs.packages }}
    steps:
      - uses: actions/checkout@v4
      - id: find
        run: |
          PKGS=$(ls packages/*/package.json | jq -R -s -c 'split("\n")[:-1] | map(split("/")[1])')
          echo "packages=$PKGS" >> $GITHUB_OUTPUT

  test:
    needs: detect
    strategy:
      matrix:
        package: ${{ fromJson(needs.detect.outputs.packages) }}
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: cd packages/${{ matrix.package }} && npm test
```

## Caching

Use `actions/cache` to persist dependencies across runs.

```yaml
- uses: actions/cache@v4
  with:
    path: ~/.npm
    key: npm-${{ runner.os }}-${{ hashFiles('**/package-lock.json') }}
    restore-keys: |
      npm-${{ runner.os }}-
```

Language-specific paths: `~/.cache/pip` (Python), `~/go/pkg/mod` (Go), `~/.gradle/caches` + `~/.gradle/wrapper` (Gradle). Use corresponding lock files in `hashFiles()`.

Tips:
- Include `runner.os` in keys when caching platform-specific binaries.
- Use `hashFiles()` on lock files to bust cache on dependency changes.
- `restore-keys` enables partial cache hits (prefix matching).
- Cache size limit: 10 GB per repo. Least-recently-used entries are evicted.
- Many setup actions (e.g., `actions/setup-node`, `actions/setup-python`) have built-in caching via `cache` input.

## Artifacts

Share files between jobs or persist build outputs.

```yaml
# Upload
- uses: actions/upload-artifact@v4
  with:
    name: build-output
    path: dist/
    retention-days: 7
    if-no-files-found: error

# Download in another job
- uses: actions/download-artifact@v4
  with:
    name: build-output
    path: ./dist
```

- Default retention: 90 days (configurable per repo/org).
- Artifacts are immutable once uploaded; use unique names per matrix leg.
- `actions/upload-artifact@v4` uses new artifact backend with improved performance.

## Security

### GITHUB_TOKEN Permissions

Set least-privilege at workflow level. Override per-job when one job needs elevated access:

```yaml
permissions:
  contents: read
  pull-requests: write
  id-token: write  # Required for OIDC

jobs:
  read-only-job:
    permissions: { contents: read }
    # ...
  deploy-job:
    permissions: { contents: read, deployments: write }
    # ...
```

### Pin Actions to SHA

Never use `@main` or mutable tags in production. Pin to full commit SHA:

```yaml
- uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2
```

Use Dependabot or Renovate to auto-update pinned SHAs. Add a comment with the version tag for readability.

### OIDC for Cloud Authentication

Eliminate static cloud credentials. Use short-lived OIDC tokens:

```yaml
permissions:
  id-token: write
  contents: read

steps:
  - uses: aws-actions/configure-aws-credentials@v4
    with:
      role-to-assume: arn:aws:iam::123456789:role/deploy
      aws-region: us-east-1
  - run: aws s3 sync dist/ s3://my-bucket/
```

Configure cloud provider to validate OIDC claims (repo, branch, environment).

### Additional Security Rules

- Never echo secrets in logs.
- Avoid `secrets: inherit` unless necessary.
- Use `environment` protection rules for production deployments.
- Restrict allowed actions at the org level.

## Concurrency Control

Prevent duplicate runs and race conditions:

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
```

For deployments, do not cancel in-progress:

```yaml
concurrency:
  group: deploy-${{ github.event.inputs.environment }}
  cancel-in-progress: false
```

## Environment Protection Rules

Control deployments with environments:

```yaml
jobs:
  deploy:
    environment:
      name: production
      url: https://example.com
    runs-on: ubuntu-latest
    steps:
      - run: ./deploy.sh
```

Configure in repo settings:
- Required reviewers (up to 6).
- Wait timer (delay before deployment proceeds).
- Branch/tag restrictions (only `main` can deploy to production).
- Environment-specific secrets and variables.

Deployment workflow pattern:

```yaml
jobs:
  deploy-staging:
    environment: staging
    runs-on: ubuntu-latest
    steps:
      - run: ./deploy.sh staging

  deploy-production:
    needs: deploy-staging
    environment: production
    runs-on: ubuntu-latest
    steps:
      - run: ./deploy.sh production
```

## Conditional Execution

Use `if` expressions to control step and job execution.

```yaml
steps:
  - run: echo "Only on main"
    if: github.ref == 'refs/heads/main'
  - run: echo "Only on PRs"
    if: github.event_name == 'pull_request'
  - run: echo "Always runs (even on failure)"
    if: always()
  - run: echo "Only on failure"
    if: failure()
  - run: echo "Conditional on output"
    if: steps.check.outputs.changed == 'true'
```

Job-level: `if: github.ref == 'refs/heads/main' && github.event_name == 'push'`

Status functions: `success()` (default), `always()`, `failure()`, `cancelled()`.
Expression helpers: `contains()`, `startsWith()`, `endsWith()`, `format()`, `toJson()`, `fromJson()`.

## Debugging

Set repo variable `ACTIONS_STEP_DEBUG=true` for verbose step output. Set `ACTIONS_RUNNER_DEBUG=true` for runner diagnostics. Or re-run with "Enable debug logging" in the UI.

Run workflows locally with [nektos/act](https://github.com/nektos/act): `act -W .github/workflows/ci.yml -j test`. Dump context: `${{ toJson(github.event) }}`. See `references/troubleshooting.md` for more.

## Performance Optimization

- Split monolithic jobs into parallel units with `needs` fan-in.
- Use `paths` filter to skip irrelevant workflows.
- Cache aggressively (`cache: 'npm'`, `cache: 'pip'` in setup actions).
- Set `timeout-minutes` on jobs to prevent runaway processes.
- Use self-hosted runners for specialized hardware or cost control (ephemeral mode for security).

See `references/advanced-patterns.md` for self-hosted runner autoscaling and monorepo patterns.

## References

| File | When to read |
|------|-------------|
| `references/advanced-patterns.md` | Dynamic matrices, workflow_run chains, approval gates, deployment strategies, self-hosted runners, monorepo patterns, custom action development |
| `references/troubleshooting.md` | Syntax errors, permission issues, cache debugging, silent failures, fork PR secrets, artifact v4 migration, workflow not triggering |
| `references/security-best-practices.md` | OIDC setup (AWS/GCP/Azure), SHA pinning, script injection prevention, pull_request_target security, least-privilege tokens, CodeQL scanning |

## Scripts

| Script | Usage |
|--------|-------|
| `scripts/validate-workflows.sh` | Validates all workflow YAML files for syntax, required fields, deprecated features |
| `scripts/pin-action-versions.sh [--dry-run]` | Resolves mutable action tags to SHA digests for supply chain security |
| `scripts/estimate-workflow-cost.sh <workflow.yml>` | Estimates GitHub Actions cost per run based on runners and matrix |
| `scripts/lint-workflow.sh [file]` | Wraps actionlint with severity categorization and fallback validation |

## Assets

Ready-to-use workflow templates:

| Template | Description |
|----------|-------------|
| `assets/ci-node.yml` | Node.js CI with matrix (20, 22), caching, lint/test/build |
| `assets/ci-python.yml` | Python CI with uv, ruff, mypy, pytest + coverage |
| `assets/ci-go.yml` | Go CI with golangci-lint, race detection |
| `assets/deploy-production.yml` | Staged deploy pipeline with OIDC AWS, rollback, Slack |
| `assets/release-please.yml` | Conventional-commit releases with OIDC publishing |
| `assets/security-scan.yml` | CodeQL + Trivy + dependency review + secret scanning |
| `assets/reusable-docker-build.yml` | Multi-platform Docker builds with SBOM and cosign |

<!-- tested: pass -->
