---
name: github-actions
description: >
  USE when writing, debugging, or modifying GitHub Actions workflows (.github/workflows/*.yml),
  creating composite actions, reusable workflows, or workflow_call templates. USE for CI/CD
  pipeline configuration with GitHub Actions triggers, matrix strategies, caching, artifacts,
  secrets, OIDC, environment protection rules, or runner selection. USE when referencing
  actions/* marketplace actions, ${{ expressions }}, or GITHUB_TOKEN permissions.
  DO NOT USE for Dagger CI, GitLab CI, CircleCI, Jenkins, Travis CI, or other non-GitHub
  CI/CD systems. DO NOT USE for general YAML editing unrelated to GitHub Actions.
---

# GitHub Actions — Authoritative Reference

## File Location and Structure

Place workflow files in `.github/workflows/` with `.yml` or `.yaml` extension. Every workflow requires `name`, `on` (trigger), and `jobs`.

```yaml
name: CI
on:
  push:
    branches: [main]
permissions:
  contents: read
defaults:
  run:
    shell: bash
    working-directory: src
env:
  NODE_ENV: production
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: echo "Hello"
```

## Triggers (`on:`)

| Trigger | Use Case |
|---|---|
| `push` | Run on push to branches/tags. Filter with `branches`, `tags`, `paths`. |
| `pull_request` | Run on PR open/sync/reopen. Filter with `branches`, `paths`, `types`. |
| `pull_request_target` | Run in base branch context. DANGEROUS with fork PRs — never checkout PR head without validation. |
| `schedule` | Cron syntax: `cron: '30 5 * * 1-5'`. Runs on default branch only. |
| `workflow_dispatch` | Manual trigger. Define `inputs:` for parameters with `type`, `required`, `default`, `options`. |
| `workflow_call` | Reusable workflow trigger. Define `inputs:`, `outputs:`, `secrets:`. |
| `repository_dispatch` | External API trigger via `POST /repos/{owner}/{repo}/dispatches`. Filter with `types`. |
| `release` | `types: [published, created, released]`. Use `published` for most release workflows. |

Filter examples:
```yaml
on:
  push:
    branches: [main, 'release/**']
    paths: ['src/**', '!src/**/*.test.ts']
    tags: ['v*']
  pull_request:
    types: [opened, synchronize, reopened]
    paths-ignore: ['docs/**']
```

## Runners

| Runner | Label |
|---|---|
| Ubuntu (default) | `ubuntu-latest`, `ubuntu-24.04`, `ubuntu-22.04` |
| macOS | `macos-latest`, `macos-15`, `macos-14` (ARM), `macos-13` (Intel) |
| Windows | `windows-latest`, `windows-2022`, `windows-2019` |
| Self-hosted | `[self-hosted, linux, x64]` — use label arrays |
| Larger runners | `ubuntu-latest-4-cores`, `ubuntu-latest-8-cores` (GitHub Team/Enterprise) |

## Jobs, Steps, and Dependencies

```yaml
jobs:
  lint:
    runs-on: ubuntu-latest
    outputs:
      result: ${{ steps.check.outputs.status }}
    steps:
      - id: check
        run: echo "status=clean" >> "$GITHUB_OUTPUT"

  test:
    needs: lint
    if: needs.lint.outputs.result == 'clean'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: npm test

  deploy:
    needs: [lint, test]
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    runs-on: ubuntu-latest
    environment: production
    steps:
      - run: echo "Deploying"
```

Set outputs from steps using `>> "$GITHUB_OUTPUT"`. Pass between jobs via `needs.<job>.outputs.<name>`.

## Expressions and Contexts

Use `${{ }}` for expressions. Available contexts:
| Context | Common Properties |
|---|---|
| `github` | `ref`, `sha`, `event_name`, `actor`, `repository`, `run_id`, `workflow`, `event` |
| `env` | Workflow/job/step environment variables |
| `secrets` | `GITHUB_TOKEN`, custom secrets |
| `needs` | `needs.<job>.outputs.<name>`, `needs.<job>.result` |
| `matrix` | Current matrix combination values |
| `inputs` | `workflow_dispatch` or `workflow_call` input values |
| `vars` | Repository/environment/org variables |
| `runner` | `os`, `arch`, `temp`, `tool_cache` |
| `steps` | `steps.<id>.outputs.<name>`, `steps.<id>.outcome` |

Key functions: `contains()`, `startsWith()`, `endsWith()`, `format()`, `join()`, `toJSON()`, `fromJSON()`, `hashFiles()`.

Status functions for `if:`: `success()`, `failure()`, `always()`, `cancelled()`.

```yaml
- if: contains(github.event.pull_request.labels.*.name, 'deploy')
- if: github.event_name == 'push' && startsWith(github.ref, 'refs/tags/v')
- run: echo "${{ toJSON(github.event) }}"
```

## Matrix Strategy

```yaml
strategy:
  fail-fast: false
  max-parallel: 4
  matrix:
    os: [ubuntu-latest, macos-latest, windows-latest]
    node: [18, 20, 22]
    include:
      - os: ubuntu-latest
        node: 22
        coverage: true
    exclude:
      - os: windows-latest
        node: 18
runs-on: ${{ matrix.os }}
steps:
  - uses: actions/setup-node@v4
    with:
      node-version: ${{ matrix.node }}
  - if: matrix.coverage
    run: npm run test:coverage
```

Set `fail-fast: false` to avoid cancelling sibling jobs on first failure. Use `max-parallel` to limit concurrent jobs.

## Actions Marketplace (`uses:`)

Reference actions as `owner/repo@ref`. Pin to SHA for security.

```yaml
steps:
  # Pin to full SHA — add version comment for readability
  - uses: actions/checkout@b4ffde65f46336ab88eb53be808477a3936bae11 # v4.1.1
    with:
      fetch-depth: 0

  - uses: actions/setup-node@v4
    with:
      node-version-file: '.nvmrc'
      cache: 'npm'

  # Local action from same repo
  - uses: ./.github/actions/my-action

  # Reusable workflow from another repo
  # (only valid at job level, not step level)
```

Essential actions: `actions/checkout`, `actions/setup-node`, `actions/setup-python`, `actions/setup-go`, `actions/cache`, `actions/upload-artifact`, `actions/download-artifact`, `actions/github-script`.

## Secrets and Variables

```yaml
env:
  API_KEY: ${{ secrets.API_KEY }}
  APP_ENV: ${{ vars.APP_ENV }}
steps:
  - run: echo "Deploying to $APP_ENV"
    env:
      DB_PASSWORD: ${{ secrets.DB_PASSWORD }}
```

- **Repository secrets**: Settings → Secrets and variables → Actions.
- **Environment secrets**: Scoped to deployment environments with protection rules.
- **Organization secrets**: Shared across repos, with repository access policies.
- **`GITHUB_TOKEN`**: Auto-generated, scoped to the repo. Set minimal permissions at workflow level.
- **OIDC**: Use `id-token: write` permission to get short-lived cloud credentials without storing long-lived secrets.

```yaml
permissions:
  id-token: write
  contents: read
steps:
  - uses: aws-actions/configure-aws-credentials@v4
    with:
      role-to-assume: arn:aws:iam::123456789:role/deploy
      aws-region: us-east-1
```

Never interpolate secrets directly into `run:` scripts. Use `env:` mapping instead to prevent injection.

## Artifacts

```yaml
- uses: actions/upload-artifact@v4
  with:
    name: build-output
    path: |
      dist/
      !dist/**/*.map
    retention-days: 7
    if-no-files-found: error

- uses: actions/download-artifact@v4
  with:
    name: build-output
    path: ./downloaded
```

Artifacts persist across jobs within a workflow run. Default retention: 90 days. Use `if-no-files-found: error` to fail fast. v4 does not allow multiple uploads with the same name — use unique names or `merge-multiple: true` on download.

## Caching

```yaml
- uses: actions/cache@v4
  with:
    path: |
      ~/.npm
      node_modules
    key: ${{ runner.os }}-node-${{ hashFiles('**/package-lock.json') }}
    restore-keys: |
      ${{ runner.os }}-node-
```

- Use `hashFiles()` on lockfiles for deterministic keys. `restore-keys` provide fallback partial matches.
- Cache limit: 10 GB per repo. Entries evicted after 7 days of no access.
- Many `setup-*` actions have built-in caching (`cache: 'npm'`). Prefer built-in over manual `actions/cache`.
## Docker Container Actions and Services

```yaml
jobs:
  test:
    runs-on: ubuntu-latest
    container:
      image: node:20-alpine
      env:
        NODE_ENV: test
      volumes:
        - /src/data:/data
    services:
      postgres:
        image: postgres:16
        env:
          POSTGRES_PASSWORD: test
        ports:
          - 5432:5432
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5
    steps:
      - uses: actions/checkout@v4
      - run: npm test
        env:
          DATABASE_URL: postgres://postgres:test@postgres:5432/postgres
```

When job runs in a container, reference services by their service name as hostname (e.g., `postgres`). When running directly on the runner, use `localhost` with mapped ports.

## Reusable Workflows

Define a reusable workflow:
```yaml
# .github/workflows/reusable-deploy.yml
on:
  workflow_call:
    inputs:
      environment:
        required: true
        type: string
    outputs:
      deploy-url:
        description: Deployment URL
        value: ${{ jobs.deploy.outputs.url }}
    secrets:
      DEPLOY_TOKEN:
        required: true

jobs:
  deploy:
    runs-on: ubuntu-latest
    outputs:
      url: ${{ steps.deploy.outputs.url }}
    steps:
      - uses: actions/checkout@v4
      - id: deploy
        run: echo "url=https://example.com" >> "$GITHUB_OUTPUT"
        env:
          TOKEN: ${{ secrets.DEPLOY_TOKEN }}
```

Call it:
```yaml
jobs:
  staging:
    uses: org/repo/.github/workflows/reusable-deploy.yml@main
    with:
      environment: staging
    secrets: inherit  # or pass individually
```

Constraints: max 4 levels of nesting. Reusable workflow jobs cannot be mixed with regular steps. The `uses:` key for reusable workflows is at the job level, not step level.

## Composite Actions

```yaml
# .github/actions/setup-and-test/action.yml
name: Setup and Test
description: Install deps and run tests
inputs:
  node-version:
    required: false
    default: '20'
outputs:
  coverage:
    description: Coverage percentage
    value: ${{ steps.test.outputs.coverage }}
runs:
  using: composite
  steps:
    - uses: actions/setup-node@v4
      with:
        node-version: ${{ inputs.node-version }}
    - run: npm ci
      shell: bash
    - id: test
      run: |
        COVERAGE=$(npm test -- --coverage 2>&1 | grep 'All files' | awk '{print $4}')
        echo "coverage=$COVERAGE" >> "$GITHUB_OUTPUT"
      shell: bash
```

Composite actions MUST specify `shell:` on every `run:` step. They cannot define `services:` or `container:`. Use for shared step sequences; use reusable workflows for shared job orchestration.

## Environment Protection Rules

```yaml
jobs:
  deploy:
    runs-on: ubuntu-latest
    environment:
      name: production
      url: https://example.com
```

Configure in repo Settings → Environments:
- **Required reviewers**: Gate deployments behind manual approval (up to 6).
- **Wait timer**: Delay deployment by N minutes.
- **Deployment branches/tags**: Restrict which refs can deploy.
- **Environment secrets/variables**: Scoped to jobs targeting that environment.

## Permissions (`GITHUB_TOKEN`)

Always set minimal permissions. Default `permissions: {}` denies all.

```yaml
permissions:
  contents: read
  pull-requests: write
  issues: write
  packages: read
  id-token: write       # OIDC
  actions: read          # also: checks, deployments, statuses, security-events
```

Set at workflow level for baseline, override per job for escalation. For `pull_request` from forks, `GITHUB_TOKEN` is always read-only.

## Security Best Practices

See [security-guide.md](references/security-guide.md) for comprehensive coverage.

1. **Pin actions to full commit SHA** — tags can be repointed maliciously. Add version comment: `# v4.1.1`.
2. **Minimal `GITHUB_TOKEN` permissions** — start with `contents: read`, add only what's needed.
3. **Never interpolate untrusted input in `run:`** — use `env:` mapping to prevent script injection.
4. **Use OIDC** for cloud auth instead of long-lived credential secrets.
5. **Enable Dependabot for actions** — keep third-party actions updated:
   ```yaml
   # .github/dependabot.yml
   version: 2
   updates:
     - package-ecosystem: github-actions
       directory: /
       schedule:
         interval: weekly
   ```
6. **Avoid `pull_request_target` with fork checkout** — attacker-controlled code runs with write permissions.
7. **Use environment protection rules** for production deployments.
8. **Enable secret scanning and push protection** on the repository.

## Debugging

- Set repo secret `ACTIONS_RUNNER_DEBUG=true` and `ACTIONS_STEP_DEBUG=true` for verbose logs.
- Use `::debug::`, `::warning::`, `::error::` workflow commands. Re-run failed jobs with debug logging in the UI.
- Use [`nektos/act`](https://github.com/nektos/act) locally and [`actionlint`](https://github.com/rhysd/actionlint) to lint YAML. See [troubleshooting.md](references/troubleshooting.md) for detailed solutions.

## Performance Optimization

1. **Cache dependencies** — use `actions/cache` or built-in `setup-*` caching.
2. **Matrix parallelism** — split tests across matrix legs.
3. **Conditional steps** — skip expensive steps with `if:` guards.
4. **Shallow clones** — `fetch-depth: 1` (default) when full history isn't needed.
5. **Concurrency groups** — cancel superseded runs. **Path filters** — trigger only on relevant changes.
6. **Larger runners** for CPU/memory-intensive builds (GitHub Team/Enterprise).

## Common Patterns

See full production-ready templates in `assets/`. Quick starters:

```yaml
# CI — see assets/ci-workflow.yml for full matrix version
name: CI
on: [push, pull_request]
permissions: { contents: read }
jobs:
  ci:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: 20, cache: npm }
      - run: npm ci && npm run lint && npm test && npm run build

# Release — see assets/release-workflow.yml
on:
  push: { tags: ['v*'] }
jobs:
  release:
    runs-on: ubuntu-latest
    permissions: { contents: write }
    steps:
      - uses: actions/checkout@v4
      - run: npm ci && npm run build
      - uses: softprops/action-gh-release@v2
        with: { files: 'dist/*', generate_release_notes: true }
```

## Common Pitfalls

See [troubleshooting.md](references/troubleshooting.md) for detailed solutions.

- **`paths` filter + required checks**: PR with only excluded paths → check never runs → blocks merge.
- **`schedule` only runs on default branch**. **Missing `shell: bash`** in composite `run:` steps.
- **`GITHUB_TOKEN` in forks**: Always read-only for `pull_request` from forks.
- **Artifact name collisions in v4**: Requires unique names. **Cache key misses**: Use `restore-keys`.
- **`needs` context**: Outputs only available to jobs declaring `needs:` on the producer.
- **`if:` auto-wraps in `${{ }}`** — don't double-wrap. **Exit code 137**: OOM kill.

## Extended References

### Deep-Dive Guides (references/)

| Guide | Topics |
|---|---|
| [advanced-patterns.md](references/advanced-patterns.md) | Custom JS/Docker actions, `action.yml` metadata, GitHub API (octokit, `gh` CLI), dynamic matrix generation, `workflow_run` chaining, deployment environments, OIDC (AWS/GCP/Azure), GitHub Packages, release automation (semantic-release, changesets), monorepo strategies (paths filter, Nx, Turborepo), self-hosted runners, ephemeral runners, ARC |
| [troubleshooting.md](references/troubleshooting.md) | Workflow not triggering, permission denied, `GITHUB_TOKEN` scope limits, cache misses, artifact failures, disk space, Docker caching, secret masking, concurrency conflicts, matrix failures, reusable workflow validation, action pinning, rate limits, self-hosted runner connectivity |
| [security-guide.md](references/security-guide.md) | Supply chain attacks (typosquatting, action compromise), SHA pinning, minimal permissions, OIDC secretless auth, environment protection rules, branch protection, Dependabot for actions, CodeQL, secret scanning, SARIF upload, attestation/provenance (SLSA), script injection prevention, self-hosted runner hardening |

### Workflow Templates (assets/)

| Template | Use Case |
|---|---|
| [ci-workflow.yml](assets/ci-workflow.yml) | Production CI: lint → test (matrix, multi-OS) → build, with caching |
| [cd-workflow.yml](assets/cd-workflow.yml) | CD: Docker build → staging (OIDC) → smoke test → production (approval gate) |
| [release-workflow.yml](assets/release-workflow.yml) | Release on tag push: build → GitHub Release with changelog → npm publish → Docker publish |
| [reusable-workflow.yml](assets/reusable-workflow.yml) | Reusable deploy workflow with typed inputs, outputs, secrets, validation, and caller example |
| [composite-action/action.yml](assets/composite-action/action.yml) | Composite action: setup → cache → install → build → test, with outputs |

### Scaffolding Scripts (scripts/)

| Script | Purpose |
|---|---|
| [workflow-init.sh](scripts/workflow-init.sh) | Detect language and generate CI workflow. Supports Node, Python, Go, Rust, Java, Ruby, PHP, .NET. `./workflow-init.sh [lang]` |
| [action-init.sh](scripts/action-init.sh) | Scaffold a custom action (JS, Docker, composite) with metadata, source, tests. `./action-init.sh <name> <type>` |
| [workflow-lint.sh](scripts/workflow-lint.sh) | Lint workflow files with actionlint (auto-installs). `./workflow-lint.sh [file-or-dir]` |
