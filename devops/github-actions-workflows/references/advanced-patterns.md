# Advanced GitHub Actions Patterns

## Table of Contents

- [Dynamic Matrix Generation](#dynamic-matrix-generation)
- [Workflow Call Chains (workflow_run)](#workflow-call-chains-workflow_run)
- [Manual Approval Gates with Environments](#manual-approval-gates-with-environments)
- [Deployment Workflows (Staging → Production with Rollback)](#deployment-workflows-staging--production-with-rollback)
- [Self-Hosted Runners](#self-hosted-runners)
- [Large Monorepo Patterns](#large-monorepo-patterns)
- [Conditional Job Execution Patterns](#conditional-job-execution-patterns)
- [Custom GitHub Actions Development](#custom-github-actions-development)
- [GitHub Packages Publishing Workflows](#github-packages-publishing-workflows)
- [Concurrency and Queue Management](#concurrency-and-queue-management)
- [Workflow Visualization and Debugging](#workflow-visualization-and-debugging)

---

## Dynamic Matrix Generation

### Multi-dimensional dynamic matrix from file discovery

Generate matrix values from repo contents, API calls, or computed logic. The key pattern: a setup job outputs a JSON array, consumed by `fromJson()` in a downstream matrix.

```yaml
jobs:
  discover:
    runs-on: ubuntu-latest
    outputs:
      services: ${{ steps.scan.outputs.services }}
      has_changes: ${{ steps.scan.outputs.has_changes }}
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 2
      - id: scan
        run: |
          # Build a JSON array of objects for a multi-dimensional matrix
          SERVICES=$(find services/ -name Dockerfile -maxdepth 2 | while read f; do
            dir=$(dirname "$f")
            name=$(basename "$dir")
            # Check if this service changed
            if git diff --name-only HEAD~1 -- "$dir" | grep -q .; then
              echo "{\"name\":\"$name\",\"path\":\"$dir\"}"
            fi
          done | jq -s -c '.')
          if [ "$SERVICES" = "[]" ] || [ -z "$SERVICES" ]; then
            echo "has_changes=false" >> "$GITHUB_OUTPUT"
            echo 'services=[]' >> "$GITHUB_OUTPUT"
          else
            echo "has_changes=true" >> "$GITHUB_OUTPUT"
            echo "services=$SERVICES" >> "$GITHUB_OUTPUT"
          fi

  build:
    needs: discover
    if: needs.discover.outputs.has_changes == 'true'
    strategy:
      fail-fast: false
      matrix:
        service: ${{ fromJson(needs.discover.outputs.services) }}
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: docker build -t ${{ matrix.service.name }} ${{ matrix.service.path }}
```

### Matrix from a JSON config file

Store matrix config in a checked-in file for easy editing without touching workflow YAML:

```yaml
# .github/matrix.json
# { "include": [{"app": "web", "node": "22"}, {"app": "api", "node": "20"}] }
jobs:
  setup:
    runs-on: ubuntu-latest
    outputs:
      matrix: ${{ steps.read.outputs.matrix }}
    steps:
      - uses: actions/checkout@v4
      - id: read
        run: echo "matrix=$(cat .github/matrix.json)" >> "$GITHUB_OUTPUT"

  build:
    needs: setup
    strategy:
      matrix: ${{ fromJson(needs.setup.outputs.matrix) }}
    runs-on: ubuntu-latest
    steps:
      - run: echo "Building ${{ matrix.app }} on Node ${{ matrix.node }}"
```

### Expanding a matrix with computed `include` entries

Use a script to generate the full `include` array, giving you complete control over combinations:

```yaml
jobs:
  generate:
    runs-on: ubuntu-latest
    outputs:
      matrix: ${{ steps.compute.outputs.matrix }}
    steps:
      - id: compute
        run: |
          # Generate include entries programmatically
          MATRIX=$(python3 -c "
          import json
          envs = ['staging', 'production']
          regions = ['us-east-1', 'eu-west-1']
          include = []
          for env in envs:
              for region in regions:
                  if env == 'staging' and region == 'eu-west-1':
                      continue  # Skip this combo
                  include.append({'environment': env, 'region': region, 'timeout': 10 if env == 'staging' else 30})
          print(json.dumps({'include': include}))
          ")
          echo "matrix=$MATRIX" >> "$GITHUB_OUTPUT"

  deploy:
    needs: generate
    strategy:
      matrix: ${{ fromJson(needs.generate.outputs.matrix) }}
    runs-on: ubuntu-latest
    timeout-minutes: ${{ matrix.timeout }}
    environment: ${{ matrix.environment }}
    steps:
      - run: echo "Deploying to ${{ matrix.environment }} in ${{ matrix.region }}"
```

---

## Workflow Call Chains (workflow_run)

The `workflow_run` event triggers a workflow after another workflow completes. Unlike `needs` (which is intra-workflow), `workflow_run` chains separate workflow files. This is essential for separating privileged operations from untrusted PR builds.

### Basic chain: test → deploy

```yaml
# .github/workflows/test.yml
name: Tests
on:
  push:
    branches: [main]
  pull_request:

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: npm test
```

```yaml
# .github/workflows/deploy.yml
name: Deploy
on:
  workflow_run:
    workflows: ["Tests"]
    types: [completed]
    branches: [main]   # Only trigger for runs on main

jobs:
  deploy:
    if: github.event.workflow_run.conclusion == 'success'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          ref: ${{ github.event.workflow_run.head_sha }}
      - run: ./deploy.sh
```

Critical details:
- `workflow_run` always runs on the **default branch** workflow definition — not the PR branch.
- Always check `github.event.workflow_run.conclusion == 'success'` to avoid deploying on failure.
- Use `github.event.workflow_run.head_sha` to check out the correct commit.
- The `branches` filter matches the branch that triggered the **upstream** workflow.

### Downloading artifacts from the triggering workflow

A common pattern for PR labeling, commenting, or reporting — where the upstream workflow runs in an untrusted context and the downstream workflow has write permissions:

```yaml
# .github/workflows/report.yml
name: PR Report
on:
  workflow_run:
    workflows: ["Tests"]
    types: [completed]

permissions:
  pull-requests: write
  actions: read

jobs:
  comment:
    if: >
      github.event.workflow_run.event == 'pull_request' &&
      github.event.workflow_run.conclusion == 'success'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/download-artifact@v4
        with:
          name: coverage-report
          run-id: ${{ github.event.workflow_run.id }}
          github-token: ${{ secrets.GITHUB_TOKEN }}

      - name: Find PR number
        id: pr
        run: |
          PR_NUM=$(cat coverage-report/pr-number.txt)
          echo "number=$PR_NUM" >> "$GITHUB_OUTPUT"

      - name: Comment on PR
        uses: actions/github-script@v7
        with:
          script: |
            const fs = require('fs');
            const report = fs.readFileSync('coverage-report/summary.txt', 'utf8');
            await github.rest.issues.createComment({
              owner: context.repo.owner,
              repo: context.repo.repo,
              issue_number: ${{ steps.pr.outputs.number }},
              body: `## Coverage Report\n${report}`
            });
```

### Multi-stage workflow chain

Chain multiple workflows in sequence:

```yaml
# build.yml → test.yml → deploy.yml
# test.yml
on:
  workflow_run:
    workflows: ["Build"]
    types: [completed]

# deploy.yml
on:
  workflow_run:
    workflows: ["Test"]
    types: [completed]
    branches: [main]
```

Limit: GitHub supports chaining up to 3 levels of `workflow_run`. Deeper chains are ignored.

---

## Manual Approval Gates with Environments

### Multi-stage deployment with approval gates

```yaml
name: Production Deploy
on:
  push:
    branches: [main]

jobs:
  build:
    runs-on: ubuntu-latest
    outputs:
      image_tag: ${{ steps.build.outputs.tag }}
    steps:
      - uses: actions/checkout@v4
      - id: build
        run: |
          TAG="sha-${GITHUB_SHA::8}"
          docker build -t myapp:$TAG .
          echo "tag=$TAG" >> "$GITHUB_OUTPUT"

  deploy-staging:
    needs: build
    environment:
      name: staging
      url: https://staging.example.com
    runs-on: ubuntu-latest
    steps:
      - run: ./deploy.sh staging ${{ needs.build.outputs.image_tag }}

  # Smoke tests run automatically after staging deploy
  smoke-test:
    needs: deploy-staging
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: ./smoke-test.sh https://staging.example.com

  # This job pauses until a reviewer approves in the GitHub UI
  deploy-production:
    needs: [build, smoke-test]
    environment:
      name: production
      url: https://example.com
    runs-on: ubuntu-latest
    steps:
      - run: ./deploy.sh production ${{ needs.build.outputs.image_tag }}
```

### Environment configuration checklist

Configure in **Settings → Environments**:

| Setting | Staging | Production |
|---|---|---|
| Required reviewers | None | 2 team leads |
| Wait timer | 0 min | 5 min (buffer for second thoughts) |
| Deployment branches | `main`, `release/*` | `main` only |
| Environment secrets | `STAGING_API_KEY` | `PROD_API_KEY` |
| Environment variables | `API_URL=https://staging.api.com` | `API_URL=https://api.com` |

### Custom deployment protection rules

GitHub Apps can implement custom protection rules. The environment waits for the app to approve/reject:

```yaml
jobs:
  deploy:
    environment:
      name: production
    # GitHub pauses here until ALL protection rules pass:
    # 1. Required reviewers approve
    # 2. Wait timer elapses
    # 3. Custom protection rules (e.g., "no open P0 incidents") approve
    runs-on: ubuntu-latest
    steps:
      - run: ./deploy.sh
```

---

## Deployment Workflows (Staging → Production with Rollback)

### Blue/green deployment with rollback

```yaml
name: Deploy with Rollback
on:
  workflow_dispatch:
    inputs:
      environment:
        type: choice
        options: [staging, production]
      action:
        type: choice
        options: [deploy, rollback]
        default: deploy

concurrency:
  group: deploy-${{ inputs.environment }}
  cancel-in-progress: false

permissions:
  contents: read
  id-token: write
  deployments: write

jobs:
  deploy:
    if: inputs.action == 'deploy'
    environment: ${{ inputs.environment }}
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Get current deployment (for rollback later)
        id: current
        run: |
          CURRENT=$(aws ecs describe-services \
            --cluster ${{ inputs.environment }} \
            --services myapp \
            --query 'services[0].taskDefinition' --output text)
          echo "task_def=$CURRENT" >> "$GITHUB_OUTPUT"

      - name: Store rollback info
        uses: actions/upload-artifact@v4
        with:
          name: rollback-${{ inputs.environment }}-${{ github.run_number }}
          path: |
            rollback-info.json
          retention-days: 30

      - name: Deploy new version
        run: |
          aws ecs update-service \
            --cluster ${{ inputs.environment }} \
            --service myapp \
            --task-definition myapp:latest \
            --deployment-configuration "maximumPercent=200,minimumHealthyPercent=100"

      - name: Wait for deployment stability
        run: |
          aws ecs wait services-stable \
            --cluster ${{ inputs.environment }} \
            --services myapp
        timeout-minutes: 15

  rollback:
    if: inputs.action == 'rollback'
    environment: ${{ inputs.environment }}
    runs-on: ubuntu-latest
    steps:
      - name: Download rollback info
        uses: actions/download-artifact@v4
        with:
          pattern: rollback-${{ inputs.environment }}-*
          merge-multiple: true

      - name: Rollback to previous version
        run: |
          PREVIOUS=$(jq -r '.task_definition' rollback-info.json)
          aws ecs update-service \
            --cluster ${{ inputs.environment }} \
            --service myapp \
            --task-definition "$PREVIOUS"

      - name: Verify rollback
        run: |
          aws ecs wait services-stable \
            --cluster ${{ inputs.environment }} \
            --services myapp
        timeout-minutes: 10
```

### Automated rollback on health check failure

```yaml
jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: production
    steps:
      - uses: actions/checkout@v4

      - name: Deploy
        id: deploy
        run: ./deploy.sh

      - name: Health check
        id: health
        continue-on-error: true
        run: |
          for i in {1..12}; do
            STATUS=$(curl -s -o /dev/null -w "%{http_code}" https://example.com/healthz)
            if [ "$STATUS" = "200" ]; then
              echo "Health check passed"
              exit 0
            fi
            echo "Attempt $i: status=$STATUS, retrying in 10s..."
            sleep 10
          done
          echo "Health check failed after 2 minutes"
          exit 1

      - name: Rollback on failure
        if: steps.health.outcome == 'failure'
        run: |
          echo "::error::Health check failed — rolling back"
          ./rollback.sh
          exit 1
```

### Canary deployment pattern

```yaml
jobs:
  canary:
    environment: production-canary
    runs-on: ubuntu-latest
    steps:
      - name: Deploy to 5% of traffic
        run: |
          kubectl set image deployment/myapp myapp=myapp:${{ github.sha }}
          kubectl patch deployment myapp -p \
            '{"spec":{"strategy":{"rollingUpdate":{"maxSurge":"5%","maxUnavailable":"0"}}}}'

      - name: Monitor error rate (10 minutes)
        id: monitor
        run: |
          for i in {1..10}; do
            ERROR_RATE=$(curl -s "https://prometheus.internal/api/v1/query?query=rate(http_errors[1m])" \
              | jq '.data.result[0].value[1] // "0"' -r)
            if (( $(echo "$ERROR_RATE > 0.01" | bc -l) )); then
              echo "Error rate $ERROR_RATE exceeds threshold"
              echo "passed=false" >> "$GITHUB_OUTPUT"
              exit 0
            fi
            sleep 60
          done
          echo "passed=true" >> "$GITHUB_OUTPUT"

      - name: Rollback canary
        if: steps.monitor.outputs.passed == 'false'
        run: kubectl rollout undo deployment/myapp

  full-rollout:
    needs: canary
    if: needs.canary.result == 'success'
    environment: production
    runs-on: ubuntu-latest
    steps:
      - name: Scale to 100%
        run: kubectl rollout status deployment/myapp --timeout=300s
```

---

## Self-Hosted Runners

### Setup and registration

```bash
# Download and configure runner (Linux x64)
mkdir actions-runner && cd actions-runner
curl -o actions-runner-linux-x64-2.321.0.tar.gz -L \
  https://github.com/actions/runner/releases/download/v2.321.0/actions-runner-linux-x64-2.321.0.tar.gz
tar xzf ./actions-runner-linux-x64-2.321.0.tar.gz

# Configure with repo or org-level token
./config.sh --url https://github.com/YOUR-ORG \
  --token REGISTRATION_TOKEN \
  --labels gpu,linux,x64 \
  --runnergroup production \
  --work _work \
  --replace

# Install as systemd service
sudo ./svc.sh install
sudo ./svc.sh start
```

### Ephemeral runners (recommended for security)

Ephemeral runners process one job then exit. Prevents state leaks between jobs:

```bash
./config.sh --url https://github.com/YOUR-ORG \
  --token TOKEN \
  --ephemeral \
  --labels ephemeral,linux
```

```yaml
# Workflow usage
jobs:
  build:
    runs-on: [self-hosted, ephemeral, linux]
    steps:
      - uses: actions/checkout@v4
      - run: make build
```

### Autoscaling with Actions Runner Controller (ARC)

ARC manages runners as Kubernetes pods. Install via Helm:

```bash
helm install arc \
  --namespace arc-systems --create-namespace \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller

helm install arc-runner-set \
  --namespace arc-runners --create-namespace \
  -f values.yaml \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set
```

`values.yaml` for runner scale set:

```yaml
githubConfigUrl: "https://github.com/YOUR-ORG"
githubConfigSecret:
  github_app_id: "12345"
  github_app_installation_id: "67890"
  github_app_private_key: |
    -----BEGIN RSA PRIVATE KEY-----
    ...
    -----END RSA PRIVATE KEY-----

maxRunners: 20
minRunners: 1

template:
  spec:
    containers:
      - name: runner
        image: ghcr.io/actions/actions-runner:latest
        resources:
          requests:
            cpu: "2"
            memory: "4Gi"
          limits:
            cpu: "4"
            memory: "8Gi"
    tolerations:
      - key: "workload"
        operator: "Equal"
        value: "ci"
        effect: "NoSchedule"
```

### Security hardening for self-hosted runners

- **Never use self-hosted runners on public repos** — any PR can execute arbitrary code.
- Use runner groups to restrict which repos/workflows can target which runners.
- Run in containers or VMs to isolate workloads.
- Use ephemeral mode to prevent data persistence.
- Restrict network access — only allow outbound to GitHub and required registries.
- Monitor runner logs at `/home/runner/_diag/`.
- Rotate registration tokens regularly.

---

## Large Monorepo Patterns

### Path-based triggers with dorny/paths-filter

GitHub's built-in `paths` filter only controls whether the workflow triggers at all. Use `dorny/paths-filter` for per-job conditional execution within a single workflow:

```yaml
name: Monorepo CI
on:
  push:
    branches: [main]
  pull_request:

jobs:
  changes:
    runs-on: ubuntu-latest
    outputs:
      frontend: ${{ steps.filter.outputs.frontend }}
      backend: ${{ steps.filter.outputs.backend }}
      infra: ${{ steps.filter.outputs.infra }}
      shared: ${{ steps.filter.outputs.shared }}
    steps:
      - uses: actions/checkout@v4
      - uses: dorny/paths-filter@v3
        id: filter
        with:
          filters: |
            frontend:
              - 'frontend/**'
              - 'shared/ui/**'
            backend:
              - 'backend/**'
              - 'shared/models/**'
            infra:
              - 'terraform/**'
              - 'docker/**'
            shared:
              - 'shared/**'

  frontend:
    needs: changes
    if: needs.changes.outputs.frontend == 'true' || needs.changes.outputs.shared == 'true'
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: frontend
    steps:
      - uses: actions/checkout@v4
      - run: npm ci && npm test && npm run build

  backend:
    needs: changes
    if: needs.changes.outputs.backend == 'true' || needs.changes.outputs.shared == 'true'
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: backend
    steps:
      - uses: actions/checkout@v4
      - run: cargo test

  infra:
    needs: changes
    if: needs.changes.outputs.infra == 'true'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: cd terraform && terraform validate
```

### Dynamic service discovery in monorepos

Discover and build only changed services:

```yaml
jobs:
  detect-changes:
    runs-on: ubuntu-latest
    outputs:
      services: ${{ steps.discover.outputs.services }}
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - id: discover
        run: |
          BASE_SHA=${{ github.event.pull_request.base.sha || 'HEAD~1' }}
          CHANGED_SERVICES=$(git diff --name-only "$BASE_SHA" HEAD \
            | grep '^services/' \
            | cut -d'/' -f2 \
            | sort -u \
            | jq -R -s -c 'split("\n") | map(select(. != ""))')
          echo "services=$CHANGED_SERVICES" >> "$GITHUB_OUTPUT"

  build-service:
    needs: detect-changes
    if: needs.detect-changes.outputs.services != '[]'
    strategy:
      matrix:
        service: ${{ fromJson(needs.detect-changes.outputs.services) }}
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: |
          cd services/${{ matrix.service }}
          docker build -t ${{ matrix.service }}:${{ github.sha }} .
```

### Shared workflow per project type

Use reusable workflows with path-based triggers to keep DRY:

```yaml
# .github/workflows/node-ci.yml (reusable)
on:
  workflow_call:
    inputs:
      working-directory:
        required: true
        type: string

jobs:
  ci:
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: ${{ inputs.working-directory }}
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: '22'
          cache: 'npm'
          cache-dependency-path: ${{ inputs.working-directory }}/package-lock.json
      - run: npm ci
      - run: npm test
```

```yaml
# .github/workflows/ci.yml
on:
  push:
    paths: ['frontend/**', 'admin/**']

jobs:
  frontend:
    uses: ./.github/workflows/node-ci.yml
    with:
      working-directory: frontend

  admin:
    uses: ./.github/workflows/node-ci.yml
    with:
      working-directory: admin
```

---

## Conditional Job Execution Patterns

### Using the `needs` context for fan-in decisions

```yaml
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - run: npm run lint

  unit-test:
    runs-on: ubuntu-latest
    steps:
      - run: npm test

  e2e-test:
    runs-on: ubuntu-latest
    continue-on-error: true
    steps:
      - run: npm run e2e

  # Runs only if ALL required jobs succeeded
  deploy:
    needs: [lint, unit-test, e2e-test]
    if: |
      always() &&
      needs.lint.result == 'success' &&
      needs.unit-test.result == 'success' &&
      (needs.e2e-test.result == 'success' || needs.e2e-test.result == 'failure')
    runs-on: ubuntu-latest
    steps:
      - run: echo "Deploying (e2e was ${{ needs.e2e-test.result }})"
```

### Skipping jobs based on commit message

```yaml
jobs:
  test:
    if: "!contains(github.event.head_commit.message, '[skip ci]')"
    runs-on: ubuntu-latest
    steps:
      - run: npm test
```

### Conditional based on changed files (without external action)

```yaml
jobs:
  check:
    runs-on: ubuntu-latest
    outputs:
      docs_only: ${{ steps.diff.outputs.docs_only }}
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 2
      - id: diff
        run: |
          FILES=$(git diff --name-only HEAD~1)
          if echo "$FILES" | grep -qvE '^(docs/|README\.md|\.github/ISSUE_TEMPLATE)'; then
            echo "docs_only=false" >> "$GITHUB_OUTPUT"
          else
            echo "docs_only=true" >> "$GITHUB_OUTPUT"
          fi

  build:
    needs: check
    if: needs.check.outputs.docs_only == 'false'
    runs-on: ubuntu-latest
    steps:
      - run: npm run build

  deploy-docs:
    needs: check
    if: needs.check.outputs.docs_only == 'true'
    runs-on: ubuntu-latest
    steps:
      - run: ./deploy-docs.sh
```

### Job output-driven conditional chains

```yaml
jobs:
  analyze:
    runs-on: ubuntu-latest
    outputs:
      has_migrations: ${{ steps.check.outputs.has_migrations }}
      has_api_changes: ${{ steps.check.outputs.has_api_changes }}
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - id: check
        run: |
          CHANGED=$(git diff --name-only origin/main...HEAD)
          echo "has_migrations=$(echo "$CHANGED" | grep -q 'migrations/' && echo true || echo false)" >> "$GITHUB_OUTPUT"
          echo "has_api_changes=$(echo "$CHANGED" | grep -q 'api/' && echo true || echo false)" >> "$GITHUB_OUTPUT"

  run-migrations:
    needs: analyze
    if: needs.analyze.outputs.has_migrations == 'true'
    environment: staging
    runs-on: ubuntu-latest
    steps:
      - run: ./run-migrations.sh

  api-contract-test:
    needs: analyze
    if: needs.analyze.outputs.has_api_changes == 'true'
    runs-on: ubuntu-latest
    steps:
      - run: npm run contract-test
```

---

## Custom GitHub Actions Development

### JavaScript action

Best for fast startup, rich GitHub API access, and cross-platform compatibility.

```
my-action/
├── action.yml
├── dist/
│   └── index.js     # Bundled output (committed)
├── src/
│   └── index.js
├── package.json
└── tsconfig.json    # If using TypeScript
```

```yaml
# action.yml
name: 'Label PR by Size'
description: 'Add size labels based on lines changed'
inputs:
  token:
    description: 'GitHub token'
    required: true
    default: ${{ github.token }}
  xs-max:
    description: 'Max lines for XS label'
    required: false
    default: '10'
outputs:
  label:
    description: 'The label that was applied'
runs:
  using: 'node20'
  main: 'dist/index.js'
```

```javascript
// src/index.js
const core = require('@actions/core');
const github = require('@actions/github');

async function run() {
  try {
    const token = core.getInput('token', { required: true });
    const xsMax = parseInt(core.getInput('xs-max'));
    const octokit = github.getOctokit(token);
    const { context } = github;

    if (context.eventName !== 'pull_request') {
      core.info('Not a pull request, skipping');
      return;
    }

    const { data: pr } = await octokit.rest.pulls.get({
      ...context.repo,
      pull_number: context.payload.pull_request.number,
    });

    const lines = pr.additions + pr.deletions;
    let label;
    if (lines <= xsMax) label = 'size/XS';
    else if (lines <= 50) label = 'size/S';
    else if (lines <= 200) label = 'size/M';
    else if (lines <= 500) label = 'size/L';
    else label = 'size/XL';

    await octokit.rest.issues.addLabels({
      ...context.repo,
      issue_number: context.payload.pull_request.number,
      labels: [label],
    });

    core.setOutput('label', label);
    core.info(`Applied label: ${label} (${lines} lines changed)`);
  } catch (error) {
    core.setFailed(`Action failed: ${error.message}`);
  }
}

run();
```

Bundle with `@vercel/ncc`: `npx @vercel/ncc build src/index.js -o dist`

### Docker action

Best for complex dependencies, specific OS requirements, or tools not available in Node.

```yaml
# action.yml
name: 'Security Scan'
description: 'Run custom security scanner'
inputs:
  severity:
    description: 'Minimum severity to report'
    required: false
    default: 'medium'
runs:
  using: 'docker'
  image: 'Dockerfile'
  args:
    - ${{ inputs.severity }}
  env:
    SCANNER_VERSION: '3.0'
```

```dockerfile
# Dockerfile
FROM alpine:3.20
RUN apk add --no-cache bash curl jq
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
```

```bash
#!/bin/bash
# entrypoint.sh
SEVERITY="${1:-medium}"
echo "Scanning with minimum severity: $SEVERITY"
# ... scanner logic ...
FINDINGS=$(./scan --severity "$SEVERITY" --format json)
echo "findings=$FINDINGS" >> "$GITHUB_OUTPUT"
if [ "$(echo "$FINDINGS" | jq length)" -gt 0 ]; then
  echo "::error::Security issues found"
  exit 1
fi
```

Docker actions only run on Linux runners. For pre-built images, use `image: 'docker://myregistry/scanner:v2'`.

### Composite action (advanced)

Composite actions bundle multiple steps and can mix `run` and `uses`:

```yaml
# .github/actions/deploy-service/action.yml
name: 'Deploy Service'
description: 'Build, push, and deploy a service'
inputs:
  service-name:
    required: true
  registry:
    required: true
  environment:
    required: true
outputs:
  deployed-url:
    description: 'URL of the deployed service'
    value: ${{ steps.deploy.outputs.url }}
runs:
  using: 'composite'
  steps:
    - name: Build image
      shell: bash
      run: |
        docker build -t ${{ inputs.registry }}/${{ inputs.service-name }}:${{ github.sha }} .
        docker push ${{ inputs.registry }}/${{ inputs.service-name }}:${{ github.sha }}

    - name: Deploy
      id: deploy
      uses: azure/webapps-deploy@v3
      with:
        app-name: ${{ inputs.service-name }}-${{ inputs.environment }}
        images: ${{ inputs.registry }}/${{ inputs.service-name }}:${{ github.sha }}

    - name: Verify
      shell: bash
      run: |
        for i in {1..6}; do
          curl -sf "${{ steps.deploy.outputs.webapp-url }}/healthz" && exit 0
          sleep 10
        done
        echo "::error::Deployment health check failed"
        exit 1
```

### Choosing action type

| Feature | JavaScript | Docker | Composite |
|---|---|---|---|
| Startup speed | Fast (~1s) | Slow (image pull/build) | Fast |
| Platform support | Linux, macOS, Windows | Linux only | All |
| Dependencies | Bundled via ncc | Full OS control | Uses existing actions |
| Complexity | Medium (Node.js required) | High (Dockerfile) | Low |
| Best for | GitHub API work, labeling | Custom tools, scanners | Gluing steps together |

---

## GitHub Packages Publishing Workflows

### npm package

```yaml
name: Publish npm
on:
  release:
    types: [published]

permissions:
  contents: read
  packages: write

jobs:
  publish:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: '22'
          registry-url: 'https://npm.pkg.github.com'
          scope: '@my-org'
      - run: npm ci
      - run: npm publish
        env:
          NODE_AUTH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

Ensure `package.json` has:

```json
{
  "name": "@my-org/my-package",
  "publishConfig": {
    "registry": "https://npm.pkg.github.com"
  }
}
```

### Docker image to GHCR

```yaml
name: Publish Docker
on:
  push:
    tags: ['v*']

permissions:
  contents: read
  packages: write

jobs:
  publish:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

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

      - uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

### Maven package

```yaml
name: Publish Maven
on:
  release:
    types: [published]

permissions:
  contents: read
  packages: write

jobs:
  publish:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with:
          java-version: '21'
          distribution: 'temurin'
          server-id: github
      - run: mvn deploy -DskipTests
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

`pom.xml` must include:

```xml
<distributionManagement>
  <repository>
    <id>github</id>
    <url>https://maven.pkg.github.com/OWNER/REPO</url>
  </repository>
</distributionManagement>
```

### Multi-package publish with matrix

```yaml
jobs:
  publish:
    strategy:
      matrix:
        package: [core, cli, sdk]
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: packages/${{ matrix.package }}
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: '22'
          registry-url: 'https://npm.pkg.github.com'
      - run: npm ci
      - run: npm publish
        env:
          NODE_AUTH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

---

## Concurrency and Queue Management

### Preventing deployment races

```yaml
# Only one deploy per environment at a time; DO NOT cancel in-progress deploys
concurrency:
  group: deploy-${{ github.event.inputs.environment || 'production' }}
  cancel-in-progress: false
```

### Cancel redundant PR builds

```yaml
on:
  pull_request:

concurrency:
  group: ci-${{ github.event.pull_request.number }}
  cancel-in-progress: true
```

### Per-branch concurrency

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: ${{ github.ref != 'refs/heads/main' }}
  # Cancel in-progress on feature branches, but NOT on main
```

### Queue behavior

When `cancel-in-progress: false`, GitHub queues the pending run. Only one pending run is retained per concurrency group — if a third run arrives while one is running and one is pending, the pending run is superseded (cancelled) by the newest.

To implement true FIFO queuing with multiple pending runs, use a third-party solution like [Mergify merge queue](https://mergify.com) or GitHub's built-in merge queue feature.

### Avoiding concurrency deadlocks

Be cautious with concurrency on workflows that call reusable workflows. The caller and callee share the same concurrency group namespace — if both define the same group name, they can deadlock.

```yaml
# BAD: Both use the same group name
# caller.yml
concurrency: { group: deploy }
# callee.yml (reusable)
concurrency: { group: deploy }  # Deadlock!

# GOOD: Use unique prefixes
# caller.yml
concurrency: { group: caller-deploy }
# callee.yml
concurrency: { group: callee-deploy }
```

---

## Workflow Visualization and Debugging

### Local testing with act

[nektos/act](https://github.com/nektos/act) runs workflows locally using Docker containers. Essential for fast iteration.

```bash
# Install
brew install act        # macOS
# or: curl -s https://raw.githubusercontent.com/nektos/act/master/install.sh | sudo bash

# Basic usage
act push                           # Simulate push event
act pull_request                   # Simulate PR event
act -W .github/workflows/ci.yml   # Run specific workflow
act -j build                      # Run specific job
act -l                             # List available jobs

# Pass secrets and variables
act -s GITHUB_TOKEN="$(gh auth token)" \
    -s NPM_TOKEN="tok_xxx" \
    --var MY_VAR=value

# Use specific event payload
act pull_request -e event.json

# Choose runner image size
act -P ubuntu-latest=catthehacker/ubuntu:act-latest      # Medium image
act -P ubuntu-latest=catthehacker/ubuntu:full-latest      # Full image (closest to GitHub)
act -P ubuntu-latest=node:20-slim                         # Minimal image (fastest)

# Dry run (list what would execute)
act -n
```

Example `event.json` for testing PR events:

```json
{
  "pull_request": {
    "number": 42,
    "head": { "ref": "feature-branch", "sha": "abc123" },
    "base": { "ref": "main" }
  }
}
```

### act limitations

- No OIDC token support.
- Service containers may behave differently.
- Some GitHub-hosted runner tools may be missing.
- `actions/cache` does not persist between `act` runs by default.
- Composite actions and reusable workflows have partial support.

### Workflow visualization

Use the GitHub UI's workflow graph view (available on every workflow run page) to see the job dependency DAG. For programmatic analysis:

```bash
# List all workflows and their recent run status
gh run list --limit 10

# View a specific run with job details
gh run view RUN_ID

# Watch a run in real time
gh run watch RUN_ID

# Download logs for analysis
gh run download RUN_ID --dir logs/

# Re-run failed jobs only
gh run rerun RUN_ID --failed
```

### Structured debug output in workflows

```yaml
steps:
  - name: Debug context
    if: runner.debug == '1'
    run: |
      echo "::group::GitHub Context"
      echo '${{ toJson(github) }}'
      echo "::endgroup::"
      echo "::group::Runner Context"
      echo '${{ toJson(runner) }}'
      echo "::endgroup::"
      echo "::group::Env"
      env | sort
      echo "::endgroup::"

  - name: Annotate warnings
    run: |
      echo "::warning file=app.js,line=5,col=10::Deprecated API usage"
      echo "::notice::Deployment took 45s"
      echo "::error file=deploy.sh,line=22::Missing required variable"
```

### Remote debugging with tmate

Drop into an SSH session on the runner for interactive debugging:

```yaml
steps:
  - name: Setup tmate session
    if: failure()   # Only on failure, or use: runner.debug == '1'
    uses: mxschmitt/action-tmate@v3
    with:
      limit-access-to-actor: true  # Only the workflow trigger user can connect
    timeout-minutes: 15            # Auto-terminate after 15 min
```

This prints an SSH command in the workflow logs. Connect and inspect the runner environment interactively. **Never use on public repos without `limit-access-to-actor: true`.**
