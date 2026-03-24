# Cypress CI/CD Integration Guide

## Table of Contents

- [GitHub Actions Setup](#github-actions-setup)
  - [Basic Workflow](#basic-workflow)
  - [Caching Strategy](#caching-strategy)
  - [Matrix Testing](#matrix-testing)
- [Parallel Runs with Cypress Cloud](#parallel-runs-with-cypress-cloud)
- [Docker-Based Testing](#docker-based-testing)
- [Recording and Artifacts](#recording-and-artifacts)
- [Retry Strategies](#retry-strategies)
- [Test Splitting](#test-splitting)
- [Cypress Dashboard Integration](#cypress-dashboard-integration)
- [Cost Optimization](#cost-optimization)

---

## GitHub Actions Setup

### Basic Workflow

```yaml
name: Cypress E2E Tests
on:
  push:
    branches: [main, develop]
  pull_request:
    branches: [main]

jobs:
  cypress:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: 'npm'

      - name: Install dependencies
        run: npm ci

      - name: Run Cypress tests
        uses: cypress-io/github-action@v6
        with:
          build: npm run build
          start: npm run start
          wait-on: 'http://localhost:3000'
          wait-on-timeout: 120
          browser: chrome

      - uses: actions/upload-artifact@v4
        if: failure()
        with:
          name: cypress-screenshots
          path: cypress/screenshots
          retention-days: 7

      - uses: actions/upload-artifact@v4
        if: failure()
        with:
          name: cypress-videos
          path: cypress/videos
          retention-days: 7
```

### Caching Strategy

```yaml
jobs:
  cypress:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-node@v4
        with:
          node-version: 20

      # Cache npm dependencies
      - name: Cache npm
        uses: actions/cache@v4
        with:
          path: ~/.npm
          key: npm-${{ runner.os }}-${{ hashFiles('package-lock.json') }}
          restore-keys: npm-${{ runner.os }}-

      # Cache Cypress binary separately (large, changes infrequently)
      - name: Cache Cypress binary
        uses: actions/cache@v4
        with:
          path: ~/.cache/Cypress
          key: cypress-binary-${{ runner.os }}-${{ hashFiles('package-lock.json') }}
          restore-keys: cypress-binary-${{ runner.os }}-

      - name: Install dependencies
        run: npm ci

      - name: Verify Cypress
        run: npx cypress verify

      - uses: cypress-io/github-action@v6
        with:
          install: false  # already installed above
          start: npm run dev
          wait-on: 'http://localhost:3000'
```

### Matrix Testing

Test across multiple browsers and Node versions:

```yaml
jobs:
  cypress:
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        browser: [chrome, firefox, edge]
        node: [18, 20]
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-node@v4
        with:
          node-version: ${{ matrix.node }}
          cache: 'npm'

      - uses: cypress-io/github-action@v6
        with:
          build: npm run build
          start: npm run start
          wait-on: 'http://localhost:3000'
          browser: ${{ matrix.browser }}

      - uses: actions/upload-artifact@v4
        if: failure()
        with:
          name: screenshots-${{ matrix.browser }}-node${{ matrix.node }}
          path: cypress/screenshots
```

---

## Parallel Runs with Cypress Cloud

Cypress Cloud orchestrates spec distribution across CI machines for optimal parallelization:

```yaml
jobs:
  cypress:
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        containers: [1, 2, 3, 4, 5]
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: 'npm'

      - uses: cypress-io/github-action@v6
        with:
          build: npm run build
          start: npm run start
          wait-on: 'http://localhost:3000'
          record: true
          parallel: true
          group: 'e2e-${{ github.ref_name }}'
          tag: ${{ github.event_name }}
        env:
          CYPRESS_RECORD_KEY: ${{ secrets.CYPRESS_RECORD_KEY }}
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

### Cypress Config for Cloud

```ts
// cypress.config.ts
import { defineConfig } from 'cypress';

export default defineConfig({
  projectId: 'your-project-id', // from Cypress Cloud
  e2e: {
    baseUrl: 'http://localhost:3000',
    retries: {
      runMode: 2,
      openMode: 0,
    },
  },
});
```

### Free Parallelization Alternative (without Cypress Cloud)

Use `cypress-split` or manual spec splitting:

```yaml
jobs:
  cypress:
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        spec-group:
          - 'cypress/e2e/auth/**'
          - 'cypress/e2e/dashboard/**'
          - 'cypress/e2e/settings/**'
          - 'cypress/e2e/api/**'
    steps:
      - uses: actions/checkout@v4
      - uses: cypress-io/github-action@v6
        with:
          start: npm run dev
          wait-on: 'http://localhost:3000'
          spec: ${{ matrix.spec-group }}
```

---

## Docker-Based Testing

### Using Cypress Docker Images

```dockerfile
# Dockerfile.cypress
FROM cypress/included:13.6.0

WORKDIR /app

# Install project dependencies
COPY package.json package-lock.json ./
RUN npm ci

# Copy project files
COPY . .

# Build the app
RUN npm run build
```

### Docker Compose for Full Stack Testing

```yaml
# docker-compose.cypress.yml
version: '3.8'

services:
  db:
    image: postgres:16
    environment:
      POSTGRES_DB: testdb
      POSTGRES_USER: test
      POSTGRES_PASSWORD: test
    healthcheck:
      test: ['CMD-SHELL', 'pg_isready -U test']
      interval: 5s
      timeout: 5s
      retries: 5

  api:
    build:
      context: .
      dockerfile: Dockerfile.api
    depends_on:
      db:
        condition: service_healthy
    environment:
      DATABASE_URL: postgres://test:test@db:5432/testdb
    ports:
      - '4000:4000'
    healthcheck:
      test: ['CMD', 'curl', '-f', 'http://localhost:4000/health']
      interval: 5s
      timeout: 5s
      retries: 10

  web:
    build:
      context: .
      dockerfile: Dockerfile.web
    depends_on:
      api:
        condition: service_healthy
    ports:
      - '3000:3000'
    healthcheck:
      test: ['CMD', 'curl', '-f', 'http://localhost:3000']
      interval: 5s
      timeout: 5s
      retries: 10

  cypress:
    image: cypress/included:13.6.0
    depends_on:
      web:
        condition: service_healthy
    environment:
      CYPRESS_baseUrl: http://web:3000
      CYPRESS_apiUrl: http://api:4000
    working_dir: /e2e
    volumes:
      - ./:/e2e
      - /e2e/node_modules
    command: npx cypress run --browser chrome
```

```bash
# Run the full test suite
docker compose -f docker-compose.cypress.yml up --build --exit-code-from cypress

# Clean up
docker compose -f docker-compose.cypress.yml down -v
```

### GitHub Actions with Docker

```yaml
jobs:
  e2e:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Run E2E tests in Docker
        run: |
          docker compose -f docker-compose.cypress.yml up \
            --build --exit-code-from cypress --abort-on-container-exit

      - uses: actions/upload-artifact@v4
        if: failure()
        with:
          name: cypress-results
          path: |
            cypress/screenshots
            cypress/videos
```

---

## Recording and Artifacts

### Cypress Cloud Recording

```yaml
- uses: cypress-io/github-action@v6
  with:
    record: true
    tag: 'nightly,production'
    group: 'regression'
    ci-build-id: ${{ github.run_id }}-${{ github.run_attempt }}
  env:
    CYPRESS_RECORD_KEY: ${{ secrets.CYPRESS_RECORD_KEY }}
```

### Local Artifact Collection

```ts
// cypress.config.ts
export default defineConfig({
  e2e: {
    video: true,
    videoCompression: 32,
    videosFolder: 'cypress/videos',
    screenshotsFolder: 'cypress/screenshots',
    screenshotOnRunFailure: true,
    trashAssetsBeforeRuns: true,
  },
});
```

### JUnit/Mocha Reporters for CI

```bash
npm install --save-dev cypress-multi-reporters mocha-junit-reporter
```

```ts
// cypress.config.ts
export default defineConfig({
  reporter: 'cypress-multi-reporters',
  reporterOptions: {
    configFile: 'reporter-config.json',
  },
});
```

```json
// reporter-config.json
{
  "reporterEnabled": "spec, mocha-junit-reporter",
  "mochaJunitReporterReporterOptions": {
    "mochaFile": "cypress/results/junit-[hash].xml",
    "toConsole": false
  }
}
```

```yaml
# GitHub Actions — publish test results
- uses: dorny/test-reporter@v1
  if: always()
  with:
    name: Cypress Tests
    path: cypress/results/*.xml
    reporter: java-junit
```

---

## Retry Strategies

### Cypress Built-in Retries

```ts
// cypress.config.ts
export default defineConfig({
  retries: {
    runMode: 2,   // retry failed tests up to 2 times in CI
    openMode: 0,  // no retries in interactive mode
  },
});
```

### Per-Test Retry Override

```ts
// More retries for known flaky test
it('handles websocket reconnection', { retries: 4 }, () => {
  // flaky test code
});

// Disable retries for specific test
it('should not retry this', { retries: 0 }, () => {
  // critical test that should fail fast
});
```

### CI-Level Retry (Re-run Entire Job)

```yaml
# GitHub Actions — rerun failed jobs
jobs:
  cypress:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: cypress-io/github-action@v6
        id: cypress
        continue-on-error: true
        with:
          start: npm run dev
          wait-on: 'http://localhost:3000'

      # Retry on failure
      - uses: cypress-io/github-action@v6
        if: steps.cypress.outcome == 'failure'
        with:
          start: npm run dev
          wait-on: 'http://localhost:3000'
```

### Retry Only Failed Specs

```bash
# Use cypress-grep to run only failed specs
npx cypress run --spec "$(cat cypress/results/failed-specs.txt)"
```

---

## Test Splitting

### Time-Based Splitting with Cypress Cloud

Cypress Cloud automatically balances specs across machines based on historical timing data. No configuration needed beyond `parallel: true`.

### Manual Splitting by Directory

```yaml
strategy:
  matrix:
    include:
      - name: auth
        spec: 'cypress/e2e/auth/**'
      - name: dashboard
        spec: 'cypress/e2e/dashboard/**'
      - name: settings
        spec: 'cypress/e2e/settings/**'
      - name: api
        spec: 'cypress/e2e/api/**'
```

### Using `cypress-split` Package (Free)

```bash
npm install --save-dev cypress-split
```

```ts
// cypress.config.ts
import { defineConfig } from 'cypress';
import cypressSplit from 'cypress-split';

export default defineConfig({
  e2e: {
    setupNodeEvents(on, config) {
      cypressSplit(on, config);
      return config;
    },
  },
});
```

```yaml
# GitHub Actions with cypress-split
jobs:
  cypress:
    strategy:
      matrix:
        containers: [1, 2, 3, 4]
    steps:
      - uses: cypress-io/github-action@v6
        env:
          SPLIT: ${{ strategy.job-total }}
          SPLIT_INDEX: ${{ strategy.job-index }}
```

---

## Cypress Dashboard Integration

### Setup

1. Create a project at [cloud.cypress.io](https://cloud.cypress.io).
2. Copy the `projectId` to `cypress.config.ts`.
3. Set `CYPRESS_RECORD_KEY` as a CI secret.

### Features

- **Test Replay** — time-travel debugging for failed tests without local reproduction.
- **Flake Detection** — automatic identification of flaky tests with pass/fail history.
- **Parallelization** — intelligent spec balancing across CI machines.
- **Analytics** — test suite health metrics, slowest tests, failure trends.
- **GitHub Integration** — status checks and PR comments with test results.

### GitHub Integration

```yaml
# Automatic PR status checks
- uses: cypress-io/github-action@v6
  with:
    record: true
  env:
    CYPRESS_RECORD_KEY: ${{ secrets.CYPRESS_RECORD_KEY }}
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}  # enables PR comments
```

### Branch-Specific Recording

```yaml
- uses: cypress-io/github-action@v6
  with:
    record: ${{ github.ref == 'refs/heads/main' || github.event_name == 'pull_request' }}
    group: ${{ github.ref_name }}
    tag: ${{ github.event_name }}
```

---

## Cost Optimization

### Reduce CI Minutes

**1. Skip tests when irrelevant:**

```yaml
jobs:
  changes:
    runs-on: ubuntu-latest
    outputs:
      should-test: ${{ steps.filter.outputs.src }}
    steps:
      - uses: actions/checkout@v4
      - uses: dorny/paths-filter@v3
        id: filter
        with:
          filters: |
            src:
              - 'src/**'
              - 'cypress/**'
              - 'package.json'

  cypress:
    needs: changes
    if: needs.changes.outputs.should-test == 'true'
    runs-on: ubuntu-latest
    steps:
      - uses: cypress-io/github-action@v6
        # ...
```

**2. Optimize caching:**

```yaml
# Cache everything: npm, Cypress binary, Next.js build cache
- uses: actions/cache@v4
  with:
    path: |
      ~/.npm
      ~/.cache/Cypress
      .next/cache
    key: deps-${{ runner.os }}-${{ hashFiles('package-lock.json') }}
```

**3. Use smaller runners for component tests:**

```yaml
jobs:
  component-tests:
    runs-on: ubuntu-latest  # cheaper than larger runners
    steps:
      - uses: cypress-io/github-action@v6
        with:
          component: true  # no app server needed
```

**4. Right-size parallel containers:**

Run timing analysis to find the optimal number of containers:

| Containers | Total CI Time | Cost per Run | Specs/Container |
|------------|---------------|--------------|-----------------|
| 1 | 20 min | 20 min | 60 |
| 3 | 8 min | 24 min | 20 |
| 5 | 5 min | 25 min | 12 |
| 10 | 4 min | 40 min | 6 |

Sweet spot is usually 3–5 containers — diminishing returns beyond that.

**5. Conditional video recording:**

```ts
// cypress.config.ts
export default defineConfig({
  video: !!process.env.CI, // only in CI
  videoCompression: 32,    // aggressive compression
});
```

**6. Use Cypress Cloud free tier wisely:**
- Free tier: 500 test recordings/month.
- Record only `main` branch and PRs (not feature branch pushes).
- Use `record: ${{ github.event_name == 'pull_request' }}` to limit recordings.

**7. Self-hosted runners for heavy test suites:**

```yaml
jobs:
  cypress:
    runs-on: self-hosted  # your own hardware
    # ...
```
