# Advanced GitHub Actions Patterns

## Table of Contents

- [Custom JavaScript Actions](#custom-javascript-actions)
- [Custom Docker Actions](#custom-docker-actions)
- [action.yml Metadata Reference](#actionyml-metadata-reference)
- [GitHub API in Workflows](#github-api-in-workflows)
- [Dynamic Matrix Generation](#dynamic-matrix-generation)
- [Workflow Run Chaining](#workflow-run-chaining)
- [Deployment Environments with Approval Gates](#deployment-environments-with-approval-gates)
- [OIDC for Cloud Providers](#oidc-for-cloud-providers)
- [GitHub Packages Publishing](#github-packages-publishing)
- [Release Automation](#release-automation)
- [Monorepo CI Strategies](#monorepo-ci-strategies)
- [Self-Hosted Runner Management](#self-hosted-runner-management)

---

## Custom JavaScript Actions

JavaScript actions run directly on the runner using Node.js. They start fast (no container build) and have full access to the runner filesystem.

### Project structure

```
my-action/
├── action.yml
├── src/
│   └── index.js
├── dist/
│   └── index.js          # ncc-compiled bundle
├── package.json
├── package-lock.json
└── __tests__/
    └── index.test.js
```

### action.yml for JavaScript

```yaml
name: 'My Custom Action'
description: 'Does something useful'
inputs:
  token:
    description: 'GitHub token'
    required: true
  environment:
    description: 'Target environment'
    required: false
    default: 'staging'
outputs:
  result:
    description: 'The action result'
runs:
  using: 'node20'
  main: 'dist/index.js'
  post: 'dist/cleanup.js'        # runs after job completes
  post-if: 'always()'            # post condition
```

### Core toolkit packages

```json
{
  "dependencies": {
    "@actions/core": "^1.10.0",
    "@actions/github": "^6.0.0",
    "@actions/exec": "^1.1.1",
    "@actions/io": "^1.1.3",
    "@actions/tool-cache": "^2.0.1",
    "@actions/cache": "^3.2.0",
    "@actions/artifact": "^2.1.0",
    "@actions/glob": "^0.4.0"
  },
  "devDependencies": {
    "@vercel/ncc": "^0.38.0"
  }
}
```

### Implementation pattern

```javascript
const core = require('@actions/core');
const github = require('@actions/github');

async function run() {
  try {
    const token = core.getInput('token', { required: true });
    const environment = core.getInput('environment');

    // Use core for logging
    core.info(`Deploying to ${environment}`);
    core.debug('Debug info (only shown with ACTIONS_STEP_DEBUG)');

    // Group collapsible log output
    await core.group('Installation', async () => {
      // ... steps logged inside a collapsible group
    });

    // Set outputs
    core.setOutput('result', 'success');

    // Export variables for subsequent steps
    core.exportVariable('DEPLOY_URL', 'https://example.com');

    // Add to PATH
    core.addPath('/opt/my-tool/bin');

    // Create annotations
    core.warning('Deprecation notice', {
      file: 'src/old.js',
      startLine: 10,
    });

    // Save/restore state (for main -> post lifecycle)
    core.saveState('pidToKill', '12345');
    // In post script: const pid = core.getState('pidToKill');

  } catch (error) {
    core.setFailed(`Action failed: ${error.message}`);
  }
}

run();
```

### Compile with ncc

```bash
npx @vercel/ncc build src/index.js -o dist --source-map --license licenses.txt
# Commit dist/ to the repo — actions must be self-contained
```

Always compile before release. Add a CI check that ensures `dist/` is up to date:

```yaml
- run: npm run build
- run: git diff --exit-code dist/
```

---

## Custom Docker Actions

Docker actions run in a container. Use when you need a specific OS environment, non-Node.js languages, or system-level dependencies.

### Project structure

```
my-docker-action/
├── action.yml
├── Dockerfile
├── entrypoint.sh
└── README.md
```

### action.yml for Docker

```yaml
name: 'Docker Action'
description: 'Runs in a container'
inputs:
  who-to-greet:
    description: 'Who to greet'
    required: true
    default: 'World'
outputs:
  time:
    description: 'The greeting time'
runs:
  using: 'docker'
  image: 'Dockerfile'           # Build from local Dockerfile
  # image: 'docker://alpine:3.19'  # Or use pre-built image (faster)
  args:
    - ${{ inputs.who-to-greet }}
  env:
    GREETING_MODE: formal
  pre-entrypoint: 'setup.sh'    # Optional pre-script
  entrypoint: 'entrypoint.sh'   # Override Dockerfile ENTRYPOINT
```

### Dockerfile best practices

```dockerfile
FROM alpine:3.19

RUN apk add --no-cache bash curl jq

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
```

### Entrypoint script

```bash
#!/bin/bash
set -euo pipefail

WHO_TO_GREET="$1"
CURRENT_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo "Hello ${WHO_TO_GREET}! The time is ${CURRENT_TIME}"
echo "time=${CURRENT_TIME}" >> "$GITHUB_OUTPUT"
```

**Performance tip**: Use `docker://` pre-built images instead of building from `Dockerfile` to skip the build step. Publish your action image to GHCR:

```yaml
runs:
  using: 'docker'
  image: 'docker://ghcr.io/myorg/my-action:v1'
```

---

## action.yml Metadata Reference

Complete metadata schema:

```yaml
name: 'Action Name'                # Required. Display name in logs.
author: 'author-name'              # Optional.
description: 'What it does'        # Required. Shows in marketplace.
branding:                          # Marketplace listing icon
  icon: 'award'                    # Feather icon name
  color: 'green'                   # blue|orange|green|purple|yellow|gray-dark|white

inputs:
  input-name:
    description: 'What this input does'  # Required per input
    required: true                       # Default: false
    default: 'fallback value'            # Used if not provided
    deprecationMessage: 'Use X instead'  # Warn on usage

outputs:
  output-name:
    description: 'What this output contains'
    # value: only used in composite actions

runs:
  # JavaScript action
  using: 'node20'                  # node16 | node20
  main: 'dist/index.js'           # Required entry point
  pre: 'dist/setup.js'            # Before main
  pre-if: 'runner.os == Linux'    # Conditional pre
  post: 'dist/cleanup.js'         # After job
  post-if: 'always()'             # Conditional post

  # Docker action
  using: 'docker'
  image: 'Dockerfile'
  pre-entrypoint: 'setup.sh'
  entrypoint: 'main.sh'
  post-entrypoint: 'cleanup.sh'
  args: ['${{ inputs.name }}']
  env:
    VAR: value

  # Composite action
  using: 'composite'
  steps:
    - run: echo "step"
      shell: bash                  # Required on every run step
```

---

## GitHub API in Workflows

### Using octokit via actions/github-script

```yaml
- uses: actions/github-script@v7
  with:
    github-token: ${{ secrets.GITHUB_TOKEN }}
    script: |
      // Create a comment on a PR
      await github.rest.issues.createComment({
        owner: context.repo.owner,
        repo: context.repo.repo,
        issue_number: context.issue.number,
        body: '✅ Build passed! [View artifacts](${{ steps.upload.outputs.artifact-url }})'
      });

      // Add labels
      await github.rest.issues.addLabels({
        owner: context.repo.owner,
        repo: context.repo.repo,
        issue_number: context.issue.number,
        labels: ['ready-to-merge']
      });

      // Create a deployment status
      const { data: deployment } = await github.rest.repos.createDeployment({
        owner: context.repo.owner,
        repo: context.repo.repo,
        ref: context.sha,
        environment: 'production',
        auto_merge: false,
        required_contexts: []
      });
```

### Using gh CLI in workflows

`gh` is pre-installed on all GitHub-hosted runners.

```yaml
- name: Create PR comment
  env:
    GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
  run: |
    gh pr comment ${{ github.event.pull_request.number }} \
      --body "Build succeeded: $(date -u)"

- name: Merge PR when checks pass
  env:
    GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
  run: |
    gh pr merge ${{ github.event.pull_request.number }} \
      --auto --squash --delete-branch

- name: Create release
  env:
    GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
  run: |
    gh release create "v${{ env.VERSION }}" \
      --title "Release v${{ env.VERSION }}" \
      --generate-notes \
      dist/*.tar.gz
```

### GraphQL queries via github-script

```yaml
- uses: actions/github-script@v7
  with:
    script: |
      const result = await github.graphql(`
        query($owner: String!, $repo: String!, $pr: Int!) {
          repository(owner: $owner, name: $repo) {
            pullRequest(number: $pr) {
              mergeable
              reviewDecision
              commits(last: 1) {
                nodes {
                  commit {
                    statusCheckRollup { state }
                  }
                }
              }
            }
          }
        }
      `, {
        owner: context.repo.owner,
        repo: context.repo.repo,
        pr: context.issue.number
      });
      core.setOutput('mergeable', result.repository.pullRequest.mergeable);
```

---

## Dynamic Matrix Generation

Generate matrix values at runtime from scripts, file listings, or API calls.

```yaml
jobs:
  prepare:
    runs-on: ubuntu-latest
    outputs:
      matrix: ${{ steps.set-matrix.outputs.matrix }}
    steps:
      - uses: actions/checkout@v4
      - id: set-matrix
        run: |
          # From directory listing
          DIRS=$(ls -d packages/*/  | jq -R -s -c 'split("\n") | map(select(. != ""))')
          echo "matrix={\"package\":${DIRS}}" >> "$GITHUB_OUTPUT"

  build:
    needs: prepare
    strategy:
      matrix: ${{ fromJSON(needs.prepare.outputs.matrix) }}
    runs-on: ubuntu-latest
    steps:
      - run: echo "Building ${{ matrix.package }}"
```

### Multi-dimensional dynamic matrix

```yaml
- id: set-matrix
  run: |
    echo 'matrix={"include":[
      {"project":"api","lang":"go","version":"1.22"},
      {"project":"web","lang":"node","version":"20"},
      {"project":"cli","lang":"rust","version":"1.77"}
    ]}' >> "$GITHUB_OUTPUT"
```

### Matrix from changed files

```yaml
- id: changes
  run: |
    CHANGED=$(git diff --name-only HEAD~1 HEAD | grep '^packages/' | cut -d/ -f2 | sort -u | jq -R -s -c 'split("\n") | map(select(. != ""))')
    if [ "$CHANGED" = "[]" ]; then
      echo "matrix={\"package\":[\"none\"]}" >> "$GITHUB_OUTPUT"
      echo "skip=true" >> "$GITHUB_OUTPUT"
    else
      echo "matrix={\"package\":${CHANGED}}" >> "$GITHUB_OUTPUT"
      echo "skip=false" >> "$GITHUB_OUTPUT"
    fi
```

---

## Workflow Run Chaining

Use `workflow_run` to trigger a workflow after another completes. Useful for separating privileged operations from untrusted code.

```yaml
# .github/workflows/deploy.yml
name: Deploy
on:
  workflow_run:
    workflows: ["CI"]
    types: [completed]
    branches: [main]

jobs:
  deploy:
    if: github.event.workflow_run.conclusion == 'success'
    runs-on: ubuntu-latest
    steps:
      # Download artifacts from the triggering workflow
      - uses: actions/download-artifact@v4
        with:
          name: build-output
          github-token: ${{ secrets.GITHUB_TOKEN }}
          run-id: ${{ github.event.workflow_run.id }}

      - run: echo "Deploying artifacts from run ${{ github.event.workflow_run.id }}"
```

### Safe fork PR handling pattern

Separate untrusted PR builds from privileged operations:

```yaml
# ci.yml — runs on PR (unprivileged)
name: CI
on: [pull_request]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: npm ci && npm test && npm run build
      - uses: actions/upload-artifact@v4
        with: { name: pr-build, path: dist/ }

# deploy-preview.yml — runs after CI (privileged, on default branch context)
name: Deploy Preview
on:
  workflow_run:
    workflows: ["CI"]
    types: [completed]
jobs:
  preview:
    if: >
      github.event.workflow_run.event == 'pull_request' &&
      github.event.workflow_run.conclusion == 'success'
    runs-on: ubuntu-latest
    permissions:
      deployments: write
      pull-requests: write
    steps:
      - uses: actions/download-artifact@v4
        with:
          name: pr-build
          run-id: ${{ github.event.workflow_run.id }}
      - run: echo "Deploy preview with write permissions safely"
```

---

## Deployment Environments with Approval Gates

### Environment configuration

```yaml
jobs:
  deploy-staging:
    runs-on: ubuntu-latest
    environment:
      name: staging
      url: https://staging.example.com
    steps:
      - run: echo "Deploy to staging"

  deploy-production:
    needs: deploy-staging
    runs-on: ubuntu-latest
    environment:
      name: production
      url: https://example.com
    steps:
      - run: echo "Deploy to production (requires approval)"
```

### Environment protection rules (configured in repo Settings → Environments)

| Rule | Effect |
|---|---|
| Required reviewers | Up to 6 people/teams must approve before the job proceeds |
| Wait timer | Delay execution by 0–43200 minutes |
| Deployment branches | Restrict to `main`, specific branches, or tag patterns |
| Custom deployment protection rules | Third-party integrations (e.g., Datadog, ServiceNow) |

### Multi-stage deployment pattern

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    outputs:
      image-tag: ${{ steps.meta.outputs.tags }}
    steps:
      - uses: actions/checkout@v4
      - id: meta
        run: echo "tags=ghcr.io/org/app:${{ github.sha }}" >> "$GITHUB_OUTPUT"

  deploy-staging:
    needs: build
    environment: staging
    runs-on: ubuntu-latest
    steps:
      - run: deploy --image ${{ needs.build.outputs.image-tag }} --env staging

  smoke-test:
    needs: deploy-staging
    runs-on: ubuntu-latest
    steps:
      - run: curl -f https://staging.example.com/health

  deploy-production:
    needs: [build, smoke-test]
    environment: production           # Has required reviewers configured
    runs-on: ubuntu-latest
    steps:
      - run: deploy --image ${{ needs.build.outputs.image-tag }} --env production
```

---

## OIDC for Cloud Providers

OpenID Connect eliminates long-lived cloud credentials. The workflow requests a short-lived JWT from GitHub's OIDC provider, which is exchanged for cloud credentials.

### AWS

```yaml
permissions:
  id-token: write
  contents: read

steps:
  - uses: aws-actions/configure-aws-credentials@v4
    with:
      role-to-assume: arn:aws:iam::123456789012:role/GitHubActionsRole
      aws-region: us-east-1
      # role-session-name: defaults to repo-workflow-run
      # audience: sts.amazonaws.com (default)
```

AWS trust policy:
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
      },
      "StringLike": {
        "token.actions.githubusercontent.com:sub": "repo:myorg/myrepo:ref:refs/heads/main"
      }
    }
  }]
}
```

### GCP

```yaml
steps:
  - uses: google-github-actions/auth@v2
    with:
      workload_identity_provider: 'projects/123/locations/global/workloadIdentityPools/github/providers/my-repo'
      service_account: 'deploy@my-project.iam.gserviceaccount.com'
```

### Azure

```yaml
steps:
  - uses: azure/login@v2
    with:
      client-id: ${{ secrets.AZURE_CLIENT_ID }}
      tenant-id: ${{ secrets.AZURE_TENANT_ID }}
      subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
```

### OIDC subject claims

Lock down by filtering on the `sub` claim:

| Pattern | Matches |
|---|---|
| `repo:org/repo:ref:refs/heads/main` | Pushes to main only |
| `repo:org/repo:environment:production` | Production environment only |
| `repo:org/repo:pull_request` | Any PR |
| `repo:org/repo:ref:refs/tags/v*` | Version tags |

---

## GitHub Packages Publishing

### npm to GitHub Packages

```yaml
- uses: actions/setup-node@v4
  with:
    node-version: 20
    registry-url: 'https://npm.pkg.github.com'
    scope: '@myorg'
- run: npm publish
  env:
    NODE_AUTH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

Package.json must include:
```json
{
  "name": "@myorg/my-package",
  "publishConfig": {
    "registry": "https://npm.pkg.github.com"
  }
}
```

### Docker to GHCR

```yaml
permissions:
  packages: write
  contents: read

steps:
  - uses: docker/login-action@v3
    with:
      registry: ghcr.io
      username: ${{ github.actor }}
      password: ${{ secrets.GITHUB_TOKEN }}

  - uses: docker/metadata-action@v5
    id: meta
    with:
      images: ghcr.io/${{ github.repository }}
      tags: |
        type=semver,pattern={{version}}
        type=semver,pattern={{major}}.{{minor}}
        type=sha
        type=ref,event=branch

  - uses: docker/build-push-action@v6
    with:
      push: true
      tags: ${{ steps.meta.outputs.tags }}
      labels: ${{ steps.meta.outputs.labels }}
      cache-from: type=gha
      cache-to: type=gha,mode=max
```

### Maven to GitHub Packages

```yaml
- uses: actions/setup-java@v4
  with:
    java-version: '21'
    distribution: 'temurin'
    server-id: github
    server-username: GITHUB_ACTOR
    server-password: GITHUB_TOKEN
- run: mvn deploy -DskipTests
  env:
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

---

## Release Automation

### semantic-release

```yaml
name: Release
on:
  push:
    branches: [main]
permissions:
  contents: write
  issues: write
  pull-requests: write
  packages: write
jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
          persist-credentials: false
      - uses: actions/setup-node@v4
        with: { node-version: 20 }
      - run: npm ci
      - run: npx semantic-release
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          NPM_TOKEN: ${{ secrets.NPM_TOKEN }}
```

### changesets

```yaml
name: Release
on:
  push:
    branches: [main]
jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: 20, cache: npm }
      - run: npm ci
      - uses: changesets/action@v1
        with:
          publish: npm run release
          version: npm run version
          commit: 'chore: release'
          title: 'chore: release'
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          NPM_TOKEN: ${{ secrets.NPM_TOKEN }}
```

---

## Monorepo CI Strategies

### Path-filtered workflows

```yaml
# .github/workflows/api.yml
on:
  pull_request:
    paths:
      - 'packages/api/**'
      - 'packages/shared/**'          # also triggers for shared deps
      - 'package-lock.json'

# .github/workflows/web.yml
on:
  pull_request:
    paths:
      - 'packages/web/**'
      - 'packages/shared/**'
      - 'package-lock.json'
```

### Nx-affected strategy

```yaml
jobs:
  affected:
    runs-on: ubuntu-latest
    outputs:
      matrix: ${{ steps.set.outputs.matrix }}
      has-changes: ${{ steps.set.outputs.has-changes }}
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: actions/setup-node@v4
        with: { node-version: 20, cache: npm }
      - run: npm ci
      - id: set
        run: |
          AFFECTED=$(npx nx show projects --affected --base=origin/main --json)
          if [ "$AFFECTED" = "[]" ]; then
            echo "has-changes=false" >> "$GITHUB_OUTPUT"
          else
            MATRIX=$(echo "$AFFECTED" | jq -c '{project: .}')
            echo "matrix=${MATRIX}" >> "$GITHUB_OUTPUT"
            echo "has-changes=true" >> "$GITHUB_OUTPUT"
          fi

  build:
    needs: affected
    if: needs.affected.outputs.has-changes == 'true'
    strategy:
      matrix: ${{ fromJSON(needs.affected.outputs.matrix) }}
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: npx nx build ${{ matrix.project }}
```

### Turborepo strategy

```yaml
- uses: actions/cache@v4
  with:
    path: .turbo
    key: turbo-${{ runner.os }}-${{ github.sha }}
    restore-keys: turbo-${{ runner.os }}-
- run: npx turbo run build test lint --filter='...[origin/main]'
```

---

## Self-Hosted Runner Management

### Runner groups

Configure in org Settings → Actions → Runner groups:
- Assign runners to groups for access control
- Restrict groups to specific repos or workflows
- Use labels for runner selection: `[self-hosted, linux, x64, gpu]`

### Ephemeral runners (recommended)

Ephemeral runners run exactly one job, then terminate. Prevents state leakage between jobs.

```bash
# Register ephemeral runner
./config.sh --url https://github.com/org/repo \
  --token <REG_TOKEN> \
  --ephemeral \
  --labels "linux,x64,ephemeral" \
  --disableupdate
```

### Auto-scaling with Actions Runner Controller (ARC)

```yaml
# Kubernetes-based auto-scaling (Helm)
apiVersion: actions.summerwind.dev/v1alpha1
kind: RunnerDeployment
metadata:
  name: runner-deploy
spec:
  replicas: 1
  template:
    spec:
      repository: myorg/myrepo
      labels:
        - self-hosted
        - linux
---
apiVersion: actions.summerwind.dev/v1alpha1
kind: HorizontalRunnerAutoscaler
metadata:
  name: runner-autoscaler
spec:
  scaleTargetRef:
    name: runner-deploy
  minReplicas: 1
  maxReplicas: 10
  scaleUpTriggers:
    - githubEvent:
        workflowJob: {}
      duration: "30m"
```

### Runner maintenance best practices

| Practice | Why |
|---|---|
| Use ephemeral mode | Clean environment per job, no credential leakage |
| Pin runner version or enable auto-update | Avoid compatibility issues |
| Mount work directory on fast storage | Speeds up checkout and builds |
| Use Docker-in-Docker or rootless Docker | Isolate container builds |
| Monitor disk space | `df -h` in pre-job hook, alert at 80% |
| Rotate registration tokens | Tokens expire after 1 hour; automate registration |
| Network: allow `github.com`, `*.actions.githubusercontent.com`, `ghcr.io` | Required connectivity |

### Pre/post job hooks

```bash
# Set ACTIONS_RUNNER_HOOK_JOB_STARTED and ACTIONS_RUNNER_HOOK_JOB_COMPLETED
# environment variables on the runner machine

# pre-job.sh — clean workspace, check disk
#!/bin/bash
df -h /home/runner/work
docker system prune -f --volumes 2>/dev/null || true

# post-job.sh — cleanup sensitive data
#!/bin/bash
rm -rf /home/runner/work/_temp/*
docker system prune -f 2>/dev/null || true
```
