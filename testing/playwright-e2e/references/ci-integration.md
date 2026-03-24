# CI Integration for Playwright

## Table of Contents

- [GitHub Actions Setup](#github-actions-setup)
- [GitHub Actions with Sharding](#github-actions-with-sharding)
- [GitLab CI](#gitlab-ci)
- [Docker Containers for CI](#docker-containers-for-ci)
- [Parallel Execution Strategies](#parallel-execution-strategies)
- [Test Splitting](#test-splitting)
- [Retry Strategies](#retry-strategies)
- [Artifact Collection](#artifact-collection)
- [Playwright Test Reporter for CI](#playwright-test-reporter-for-ci)
- [Merge Queue Testing](#merge-queue-testing)

---

## GitHub Actions Setup

### Basic Workflow with Caching

```yaml
name: Playwright Tests
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  test:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: 'npm'

      - name: Install dependencies
        run: npm ci

      - name: Cache Playwright browsers
        id: playwright-cache
        uses: actions/cache@v4
        with:
          path: ~/.cache/ms-playwright
          key: playwright-${{ runner.os }}-${{ hashFiles('package-lock.json') }}

      - name: Install Playwright browsers
        if: steps.playwright-cache.outputs.cache-hit != 'true'
        run: npx playwright install --with-deps

      - name: Install Playwright system deps
        if: steps.playwright-cache.outputs.cache-hit == 'true'
        run: npx playwright install-deps

      - name: Run Playwright tests
        run: npx playwright test

      - name: Upload test results
        uses: actions/upload-artifact@v4
        if: ${{ !cancelled() }}
        with:
          name: playwright-report
          path: playwright-report/
          retention-days: 14
```

### With Application Build and webServer

```yaml
      - name: Build application
        run: npm run build

      - name: Run Playwright tests
        run: npx playwright test
        env:
          CI: true
          BASE_URL: http://localhost:3000
```

The `webServer` config in `playwright.config.ts` handles starting/stopping the dev server.

---

## GitHub Actions with Sharding

Split tests across multiple CI machines for faster execution:

```yaml
name: Playwright Sharded Tests
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  test:
    runs-on: ubuntu-latest
    timeout-minutes: 20
    strategy:
      fail-fast: false
      matrix:
        shardIndex: [1, 2, 3, 4]
        shardTotal: [4]
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: 'npm'

      - run: npm ci

      - name: Cache Playwright browsers
        id: playwright-cache
        uses: actions/cache@v4
        with:
          path: ~/.cache/ms-playwright
          key: playwright-${{ runner.os }}-${{ hashFiles('package-lock.json') }}

      - name: Install Playwright browsers
        if: steps.playwright-cache.outputs.cache-hit != 'true'
        run: npx playwright install --with-deps

      - name: Install Playwright system deps
        if: steps.playwright-cache.outputs.cache-hit == 'true'
        run: npx playwright install-deps

      - name: Run tests (shard ${{ matrix.shardIndex }}/${{ matrix.shardTotal }})
        run: npx playwright test --shard=${{ matrix.shardIndex }}/${{ matrix.shardTotal }}

      - name: Upload blob report
        uses: actions/upload-artifact@v4
        if: ${{ !cancelled() }}
        with:
          name: blob-report-${{ matrix.shardIndex }}
          path: blob-report/
          retention-days: 1

  merge-reports:
    if: ${{ !cancelled() }}
    needs: test
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: 'npm'

      - run: npm ci

      - name: Download blob reports
        uses: actions/download-artifact@v4
        with:
          path: all-blob-reports
          pattern: blob-report-*
          merge-multiple: true

      - name: Merge reports
        run: npx playwright merge-reports --reporter html ./all-blob-reports

      - name: Upload merged report
        uses: actions/upload-artifact@v4
        with:
          name: playwright-report
          path: playwright-report/
          retention-days: 14
```

For sharding, configure blob reporter in `playwright.config.ts`:

```ts
reporter: process.env.CI
  ? [['blob'], ['github']]
  : [['html', { open: 'never' }], ['list']],
```

---

## GitLab CI

```yaml
# .gitlab-ci.yml
stages:
  - test

playwright:
  stage: test
  image: mcr.microsoft.com/playwright:v1.52.0-noble
  script:
    - npm ci
    - npx playwright test
  artifacts:
    when: always
    paths:
      - playwright-report/
      - test-results/
    expire_in: 7 days
  retry:
    max: 1
    when: script_failure

# Sharded variant
.playwright-shard:
  stage: test
  image: mcr.microsoft.com/playwright:v1.52.0-noble
  script:
    - npm ci
    - npx playwright test --shard=$SHARD_INDEX/$SHARD_TOTAL
  artifacts:
    when: always
    paths:
      - blob-report/
    expire_in: 1 day
  parallel:
    matrix:
      - SHARD_INDEX: [1, 2, 3, 4]
        SHARD_TOTAL: [4]

merge-reports:
  stage: test
  image: mcr.microsoft.com/playwright:v1.52.0-noble
  needs:
    - .playwright-shard
  script:
    - npm ci
    - npx playwright merge-reports --reporter html ./blob-report
  artifacts:
    when: always
    paths:
      - playwright-report/
    expire_in: 7 days
```

---

## Docker Containers for CI

### Official Playwright Docker Image

```dockerfile
FROM mcr.microsoft.com/playwright:v1.52.0-noble

WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .

CMD ["npx", "playwright", "test"]
```

```bash
# Build and run
docker build -t playwright-tests .
docker run --rm --ipc=host playwright-tests

# With shared memory fix for browser stability
docker run --rm --shm-size=2gb playwright-tests

# Mount results directory
docker run --rm --ipc=host \
  -v $(pwd)/playwright-report:/app/playwright-report \
  -v $(pwd)/test-results:/app/test-results \
  playwright-tests
```

### Custom Docker Image (Smaller)

```dockerfile
FROM node:20-slim

RUN apt-get update && apt-get install -y \
  libnss3 libatk1.0-0 libatk-bridge2.0-0 libcups2 \
  libdrm2 libxkbcommon0 libxcomposite1 libxdamage1 \
  libxfixes3 libxrandr2 libgbm1 libpango-1.0-0 \
  libcairo2 libasound2 libxshmfence1 \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY package*.json ./
RUN npm ci
RUN npx playwright install chromium --with-deps

COPY . .
CMD ["npx", "playwright", "test", "--project=chromium"]
```

### Docker Compose for Tests with Services

```yaml
# docker-compose.test.yml
services:
  app:
    build: .
    ports:
      - "3000:3000"
    environment:
      DATABASE_URL: postgres://test:test@db:5432/testdb

  db:
    image: postgres:16
    environment:
      POSTGRES_USER: test
      POSTGRES_PASSWORD: test
      POSTGRES_DB: testdb

  tests:
    build:
      context: .
      dockerfile: Dockerfile.playwright
    depends_on:
      - app
    environment:
      BASE_URL: http://app:3000
    volumes:
      - ./playwright-report:/app/playwright-report
      - ./test-results:/app/test-results
```

---

## Parallel Execution Strategies

### Worker-Level Parallelism

```ts
// playwright.config.ts
export default defineConfig({
  fullyParallel: true,   // parallelize tests within files
  workers: process.env.CI ? 4 : undefined,  // undefined = half of CPU cores
});
```

### File-Level vs Test-Level

```ts
// File-level parallel (default): different files run in parallel
// Test-level parallel: tests within a file also run in parallel

// Force serial within a describe block
test.describe.configure({ mode: 'serial' });

// Force parallel within a describe block
test.describe.configure({ mode: 'parallel' });
```

### Optimal Worker Count

| CI Environment      | Recommended Workers |
|---------------------|-------------------|
| 2 vCPU (free tier)  | 2                 |
| 4 vCPU (standard)   | 4                 |
| 8+ vCPU (large)     | 6-8               |

More workers doesn't always mean faster — browsers are memory-hungry (~300MB each).

---

## Test Splitting

### Time-Based Splitting

Use `--shard` which splits by test file, distributing roughly equally:

```bash
# 4-way split
npx playwright test --shard=1/4
npx playwright test --shard=2/4
npx playwright test --shard=3/4
npx playwright test --shard=4/4
```

### Tag-Based Splitting

```ts
// Mark tests with tags
test('fast checkout', { tag: '@smoke' }, async ({ page }) => { });
test('full regression', { tag: '@regression' }, async ({ page }) => { });
```

```bash
# Run subsets by tag
npx playwright test --grep @smoke        # fast feedback
npx playwright test --grep @regression   # full suite
npx playwright test --grep-invert @slow  # skip slow tests
```

### Project-Based Splitting

```ts
// Run different browsers on different CI machines
projects: [
  { name: 'chromium', use: { ...devices['Desktop Chrome'] } },
  { name: 'firefox', use: { ...devices['Desktop Firefox'] } },
],
```

```bash
# Machine 1
npx playwright test --project=chromium
# Machine 2
npx playwright test --project=firefox
```

---

## Retry Strategies

### Global Retries

```ts
// playwright.config.ts
export default defineConfig({
  retries: process.env.CI ? 2 : 0,  // retry twice on CI, never locally
});
```

### Per-Test Retries

```ts
test('flaky external service', async ({ page }) => {
  test.info().annotations.push({ type: 'retries', description: '3' });
  // Or use: test.describe.configure({ retries: 3 });
});
```

### Retry with Different Strategy on Each Attempt

```ts
test('login flow', async ({ page }, testInfo) => {
  if (testInfo.retry > 0) {
    // On retry, clear all state
    await page.context().clearCookies();
    await page.context().clearPermissions();
  }
  // ... test logic
});
```

### Distinguishing Flaky from Broken

```ts
// Custom reporter to track retry patterns
class FlakyTracker {
  onTestEnd(test: TestCase, result: TestResult) {
    if (result.status === 'passed' && result.retry > 0) {
      console.warn(`FLAKY: ${test.title} passed on retry ${result.retry}`);
    }
  }
}
```

---

## Artifact Collection

### Comprehensive Artifact Config

```ts
// playwright.config.ts
export default defineConfig({
  use: {
    trace: 'on-first-retry',       // trace on first retry attempt
    screenshot: 'only-on-failure', // screenshot when test fails
    video: 'retain-on-failure',    // video only for failures
  },
  outputDir: 'test-results',
});
```

### GitHub Actions Artifact Upload

```yaml
- name: Upload test results
  uses: actions/upload-artifact@v4
  if: ${{ !cancelled() }}
  with:
    name: test-results-${{ matrix.shardIndex || 'all' }}
    path: |
      playwright-report/
      test-results/
    retention-days: 7

# For large test suites, compress first
- name: Compress results
  if: ${{ !cancelled() }}
  run: tar -czf test-results.tar.gz playwright-report/ test-results/

- name: Upload compressed results
  uses: actions/upload-artifact@v4
  if: ${{ !cancelled() }}
  with:
    name: test-results
    path: test-results.tar.gz
```

### Custom Artifact Attachment Per Test

```ts
test('visual test', async ({ page }, testInfo) => {
  await page.goto('/');

  // Attach screenshot
  const screenshot = await page.screenshot();
  await testInfo.attach('homepage', { body: screenshot, contentType: 'image/png' });

  // Attach arbitrary data
  await testInfo.attach('performance', {
    body: JSON.stringify(await getPerformanceMetrics(page)),
    contentType: 'application/json',
  });
});
```

---

## Playwright Test Reporter for CI

### Built-in Reporters for CI

```ts
// playwright.config.ts
reporter: process.env.CI
  ? [
      ['github'],                   // GitHub Actions annotations
      ['blob'],                     // for merging sharded results
      ['junit', { outputFile: 'results.xml' }],  // CI dashboards
      ['html', { open: 'never' }],  // browsable report
    ]
  : [
      ['list'],
      ['html', { open: 'on-failure' }],
    ],
```

### GitHub Reporter

The `github` reporter creates inline annotations on PRs:

```ts
// Enabled by default when GITHUB_ACTIONS env var is set
reporter: [['github']],
```

This shows test failures directly in the PR "Files changed" tab.

### JUnit Reporter

For CI dashboards (Jenkins, Azure DevOps, CircleCI):

```ts
['junit', {
  outputFile: 'test-results/junit.xml',
  embedAnnotationsAsProperties: true,
  embedAttachmentsAsProperty: 'testng',
}],
```

### Custom Reporter

```ts
// reporters/slack-reporter.ts
import type { Reporter, TestCase, TestResult } from '@playwright/test/reporter';

class SlackReporter implements Reporter {
  private failures: string[] = [];

  onTestEnd(test: TestCase, result: TestResult) {
    if (result.status === 'failed') {
      this.failures.push(`❌ ${test.title}: ${result.error?.message}`);
    }
  }

  async onEnd() {
    if (this.failures.length > 0) {
      await fetch(process.env.SLACK_WEBHOOK!, {
        method: 'POST',
        body: JSON.stringify({
          text: `Playwright failures:\n${this.failures.join('\n')}`,
        }),
      });
    }
  }
}

export default SlackReporter;
```

```ts
// playwright.config.ts
reporter: [['./reporters/slack-reporter.ts']],
```

---

## Merge Queue Testing

### GitHub Merge Queue Workflow

```yaml
name: Merge Queue Tests
on:
  merge_group:
    types: [checks_requested]

jobs:
  playwright:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: 'npm'

      - run: npm ci

      - name: Cache Playwright browsers
        uses: actions/cache@v4
        with:
          path: ~/.cache/ms-playwright
          key: playwright-${{ runner.os }}-${{ hashFiles('package-lock.json') }}

      - name: Install Playwright browsers
        run: npx playwright install --with-deps

      - name: Run full test suite
        run: npx playwright test

      - name: Upload results
        uses: actions/upload-artifact@v4
        if: ${{ !cancelled() }}
        with:
          name: merge-queue-results
          path: playwright-report/
          retention-days: 3
```

### Tiered Testing Strategy

```yaml
# PR: Run smoke tests only (fast feedback)
# Merge queue: Run full suite (thorough validation)
# Main branch: Run full suite + visual regression

# PR workflow
on: pull_request
# ...
- run: npx playwright test --grep @smoke

# Merge queue workflow
on: merge_group
# ...
- run: npx playwright test

# Post-merge workflow
on:
  push:
    branches: [main]
# ...
- run: npx playwright test --update-snapshots
```

### Branch Protection Rules

Configure branch protection to require the merge queue workflow:

1. Settings → Branches → Branch protection rules
2. Enable "Require merge queue"
3. Add the Playwright workflow as a required status check
4. Set merge method (squash recommended)
5. Set maximum group size (3-5 PRs per batch)

This ensures every PR passes the full Playwright suite before merging, while the PR check only runs smoke tests for fast feedback.
