# Comprehensive Testing with Storybook

> Complete guide to testing strategies using Storybook 8.x: interaction tests, visual regression, accessibility, CI/CD integration.

## Table of Contents

- [Interaction Testing with Play Functions](#interaction-testing-with-play-functions)
- [Visual Regression with Chromatic](#visual-regression-with-chromatic)
- [Accessibility Testing with a11y Addon](#accessibility-testing-with-a11y-addon)
- [Test Runner Setup](#test-runner-setup)
- [Coverage Reporting](#coverage-reporting)
- [Portable Stories in Jest/Vitest](#portable-stories-in-jestvitest)
- [Snapshot Testing Strategies](#snapshot-testing-strategies)
- [CI/CD Integration for Visual Tests](#cicd-integration-for-visual-tests)

---

## Interaction Testing with Play Functions

Play functions let you write component-level integration tests directly in stories using Testing Library and Vitest APIs.

### Setup

```bash
npm install -D @storybook/test @storybook/addon-interactions
```

```ts
// main.ts
addons: [
  '@storybook/addon-essentials',
  '@storybook/addon-interactions',
],
```

### Basic Interaction Test

```tsx
import { expect, fn, userEvent, within, waitFor } from '@storybook/test';
import type { Meta, StoryObj } from '@storybook/react';
import { LoginForm } from './LoginForm';

const meta = {
  component: LoginForm,
  args: { onSubmit: fn() },
} satisfies Meta<typeof LoginForm>;
export default meta;
type Story = StoryObj<typeof meta>;

export const SuccessfulLogin: Story = {
  play: async ({ canvasElement, args, step }) => {
    const canvas = within(canvasElement);

    await step('Fill credentials', async () => {
      await userEvent.type(canvas.getByLabelText('Email'), 'user@test.com');
      await userEvent.type(canvas.getByLabelText('Password'), 'password123');
    });

    await step('Submit form', async () => {
      await userEvent.click(canvas.getByRole('button', { name: /sign in/i }));
    });

    await step('Verify submission', async () => {
      await waitFor(() => {
        expect(args.onSubmit).toHaveBeenCalledWith({
          email: 'user@test.com',
          password: 'password123',
        });
      });
    });
  },
};
```

### Testing Error States

```tsx
export const ValidationErrors: Story = {
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);

    // Submit empty form
    await userEvent.click(canvas.getByRole('button', { name: /sign in/i }));

    await waitFor(() => {
      expect(canvas.getByText('Email is required')).toBeVisible();
      expect(canvas.getByText('Password is required')).toBeVisible();
    });

    // Type invalid email
    await userEvent.type(canvas.getByLabelText('Email'), 'not-an-email');
    await userEvent.click(canvas.getByRole('button', { name: /sign in/i }));

    await waitFor(() => {
      expect(canvas.getByText('Invalid email address')).toBeVisible();
    });
  },
};
```

### Testing Keyboard Navigation

```tsx
export const KeyboardNavigation: Story = {
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);

    // Tab through form elements
    await userEvent.tab();
    expect(canvas.getByLabelText('Email')).toHaveFocus();

    await userEvent.tab();
    expect(canvas.getByLabelText('Password')).toHaveFocus();

    await userEvent.tab();
    expect(canvas.getByRole('button', { name: /sign in/i })).toHaveFocus();

    // Submit with Enter
    await userEvent.keyboard('{Enter}');
  },
};
```

### Testing Async Operations

```tsx
export const AsyncSubmit: Story = {
  parameters: {
    msw: {
      handlers: [
        http.post('/api/login', async () => {
          await delay(500);
          return HttpResponse.json({ token: 'abc123' });
        }),
      ],
    },
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);

    await userEvent.type(canvas.getByLabelText('Email'), 'user@test.com');
    await userEvent.type(canvas.getByLabelText('Password'), 'pass');
    await userEvent.click(canvas.getByRole('button', { name: /sign in/i }));

    // Loading state
    await waitFor(() => {
      expect(canvas.getByText('Signing in...')).toBeVisible();
    });

    // Success state
    await waitFor(() => {
      expect(canvas.getByText('Welcome!')).toBeVisible();
    }, { timeout: 3000 });
  },
};
```

### Testing with Mock Functions

```tsx
import { fn, expect } from '@storybook/test';

export const CallbackTracking: Story = {
  args: {
    onChange: fn(),
    onBlur: fn(),
  },
  play: async ({ canvasElement, args }) => {
    const canvas = within(canvasElement);
    const input = canvas.getByRole('textbox');

    await userEvent.type(input, 'hello');
    expect(args.onChange).toHaveBeenCalledTimes(5); // once per character

    await userEvent.tab(); // blur
    expect(args.onBlur).toHaveBeenCalledOnce();
  },
};
```

---

## Visual Regression with Chromatic

### Setup

```bash
npm install -D chromatic
```

### Basic Usage

```bash
# First run — establishes baselines
npx chromatic --project-token=$CHROMATIC_PROJECT_TOKEN

# Subsequent runs — detects visual changes
npx chromatic --project-token=$CHROMATIC_PROJECT_TOKEN --exit-zero-on-changes
```

### Per-Story Configuration

```tsx
export const ResponsiveCard: Story = {
  parameters: {
    chromatic: {
      viewports: [320, 768, 1200],    // capture at multiple widths
      delay: 300,                      // wait 300ms before snapshot
      diffThreshold: 0.2,             // 0-1, lower = more sensitive
      pauseAnimationAtEnd: true,       // capture final animation state
    },
  },
};

export const AnimatedComponent: Story = {
  parameters: {
    chromatic: {
      delay: 1000,                     // wait for animation to complete
      disableSnapshot: false,
    },
  },
};

export const DevOnly: Story = {
  parameters: {
    chromatic: { disableSnapshot: true }, // skip in visual tests
  },
};
```

### Modes — Test Multiple Themes/Locales

```ts
// .storybook/preview.ts
parameters: {
  chromatic: {
    modes: {
      light: { theme: 'light' },
      dark: { theme: 'dark', backgrounds: { value: '#1a1a1a' } },
      mobile: { viewport: 375 },
      desktop: { viewport: 1200 },
    },
  },
},
```

### TurboSnap — Only Test Changed Components

```bash
npx chromatic --only-changed
# Requires fetch-depth: 0 in checkout
```

```yaml
- uses: actions/checkout@v4
  with:
    fetch-depth: 0  # required for TurboSnap
```

### Handling Dynamic Content

```tsx
// Fix timestamps, random data for deterministic snapshots
export const WithDate: Story = {
  parameters: {
    chromatic: { delay: 0 },
  },
  decorators: [
    (Story) => {
      jest.useFakeTimers();
      jest.setSystemTime(new Date('2024-01-15'));
      return <Story />;
    },
  ],
};

// Or use a loader to set deterministic data
export const WithRandomAvatar: Story = {
  args: {
    seed: 42, // deterministic random
  },
};
```

---

## Accessibility Testing with a11y Addon

### Setup

```bash
npm install -D @storybook/addon-a11y
```

```ts
// main.ts
addons: ['@storybook/addon-essentials', '@storybook/addon-a11y'],
```

### Configuration

```ts
// preview.ts — global a11y config
parameters: {
  a11y: {
    config: {
      rules: [
        { id: 'color-contrast', enabled: true },
        { id: 'landmark-one-main', enabled: false }, // disable for component stories
      ],
    },
    options: {
      runOnly: {
        type: 'tag',
        values: ['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'],
      },
    },
  },
},
```

### Per-Story Overrides

```tsx
export const LowContrast: Story = {
  parameters: {
    a11y: {
      config: {
        rules: [
          { id: 'color-contrast', enabled: false }, // intentionally low contrast for this story
        ],
      },
    },
  },
};

export const SkipA11y: Story = {
  parameters: {
    a11y: { disable: true },
  },
};
```

### Automated a11y Checks in Play Functions

```tsx
import { expect } from '@storybook/test';

export const AccessibleForm: Story = {
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);

    // Verify ARIA labels exist
    expect(canvas.getByRole('form', { name: 'Login' })).toBeInTheDocument();
    expect(canvas.getByLabelText('Email address')).toBeInTheDocument();

    // Verify error messages are associated with inputs
    await userEvent.click(canvas.getByRole('button', { name: /submit/i }));
    const emailInput = canvas.getByLabelText('Email address');
    const errorId = emailInput.getAttribute('aria-describedby');
    expect(document.getElementById(errorId!)).toHaveTextContent('Required');
  },
};
```

### a11y in Test Runner

```ts
// .storybook/test-runner.ts
import type { TestRunnerConfig } from '@storybook/test-runner';
import { injectAxe, checkA11y } from 'axe-playwright';

const config: TestRunnerConfig = {
  async preVisit(page) {
    await injectAxe(page);
  },
  async postVisit(page) {
    await checkA11y(page, '#storybook-root', {
      detailedReport: true,
      detailedReportOptions: { html: true },
    });
  },
};
export default config;
```

---

## Test Runner Setup

The Storybook test runner turns every story into a test using Playwright.

### Installation

```bash
npm install -D @storybook/test-runner
```

### Configuration

```ts
// .storybook/test-runner.ts
import type { TestRunnerConfig } from '@storybook/test-runner';

const config: TestRunnerConfig = {
  tags: {
    include: ['test'],         // only run stories tagged 'test'
    exclude: ['no-tests'],     // skip stories tagged 'no-tests'
    skip: ['skip-test'],       // mark as skipped (shows in results)
  },

  async preVisit(page, context) {
    // Runs before each story renders
    await page.setViewportSize({ width: 1280, height: 720 });
  },

  async postVisit(page, context) {
    // Runs after each story renders and play function completes
    // Add custom assertions here
    const elementHandler = await page.$('#storybook-root');
    const innerHTML = await elementHandler?.innerHTML();
    expect(innerHTML).toBeTruthy();
  },

  getHttpHeaders: async (url) => ({
    Authorization: 'Bearer test-token',
  }),
};
export default config;
```

### Running

```bash
# Against running dev server
npx test-storybook --url http://localhost:6006

# Against static build
npx concurrently -k -s first \
  "npx http-server storybook-static --port 6006 --silent" \
  "npx wait-on tcp:127.0.0.1:6006 && npx test-storybook --url http://127.0.0.1:6006"

# With filtering
npx test-storybook --stories "src/components/Button/**"
npx test-storybook --shard 1/3  # parallel sharding

# Watch mode
npx test-storybook --watch

# Verbose output
npx test-storybook --verbose

# Fail fast
npx test-storybook --bail
```

### Tags for Test Filtering

```tsx
// Only run interaction tests
const meta = {
  component: Button,
  tags: ['test'],  // included by test runner
} satisfies Meta<typeof Button>;

// Skip in test runner
export const DesignReference: Story = {
  tags: ['!test'],  // excluded
};
```

---

## Coverage Reporting

### Setup with Istanbul

```bash
npm install -D @storybook/addon-coverage
```

```ts
// main.ts
addons: ['@storybook/addon-essentials', '@storybook/addon-coverage'],
```

### Running Coverage

```bash
# Generate coverage from test runner
npx test-storybook --coverage

# Output formats
npx test-storybook --coverage --coverageDirectory ./coverage

# View report
npx nyc report --reporter=lcov --reporter=text -t coverage/storybook
open coverage/lcov-report/index.html
```

### Configuration

```ts
// main.ts
addons: [
  {
    name: '@storybook/addon-coverage',
    options: {
      istanbul: {
        include: ['src/**/*.{ts,tsx}'],
        exclude: [
          '**/*.stories.*',
          '**/*.test.*',
          '**/types/**',
          '**/mocks/**',
        ],
        excludeAfterRemap: true,
      },
    },
  },
],
```

### Merging with Unit Test Coverage

```bash
# Generate Storybook coverage
npx test-storybook --coverage --coverageDirectory coverage/storybook

# Generate unit test coverage
npx vitest run --coverage --coverageDirectory coverage/unit

# Merge reports
npx nyc merge coverage/ coverage/merged/coverage.json
npx nyc report -t coverage/merged --reporter=lcov --reporter=text-summary
```

---

## Portable Stories in Jest/Vitest

Reuse stories as unit tests with full decorator/arg/loader support.

### Vitest Setup

```ts
// vitest.config.ts
import { defineConfig } from 'vitest/config';
export default defineConfig({
  test: {
    environment: 'jsdom',
    setupFiles: ['./vitest.setup.ts'],
    globals: true,
  },
});
```

```ts
// vitest.setup.ts
import { setProjectAnnotations } from '@storybook/react';
import * as previewAnnotations from './.storybook/preview';
import '@testing-library/jest-dom/vitest';

setProjectAnnotations(previewAnnotations);
```

### Using composeStories

```tsx
// Button.test.tsx
import { composeStories } from '@storybook/react';
import { render, screen } from '@testing-library/react';
import * as stories from './Button.stories';

const { Primary, Secondary, Loading, Disabled } = composeStories(stories);

describe('Button', () => {
  it('renders primary variant', () => {
    render(<Primary />);
    expect(screen.getByRole('button')).toHaveClass('btn-primary');
  });

  it('renders with custom args', () => {
    render(<Primary label="Custom" />);
    expect(screen.getByText('Custom')).toBeInTheDocument();
  });

  it('runs play function assertions', async () => {
    const { container } = render(<Primary />);
    await Primary.play!({ canvasElement: container });
  });

  it('handles click events', async () => {
    const onClickSpy = vi.fn();
    render(<Primary onClick={onClickSpy} />);
    await userEvent.click(screen.getByRole('button'));
    expect(onClickSpy).toHaveBeenCalled();
  });
});
```

### Jest Setup

```ts
// jest.setup.ts
import { setProjectAnnotations } from '@storybook/react';
import * as previewAnnotations from './.storybook/preview';
import '@testing-library/jest-dom';

setProjectAnnotations(previewAnnotations);
```

```js
// jest.config.js
module.exports = {
  testEnvironment: 'jsdom',
  setupFilesAfterSetup: ['./jest.setup.ts'],
  transform: {
    '^.+\\.tsx?$': 'ts-jest',
  },
  moduleNameMapper: {
    '\\.(css|less|scss)$': 'identity-obj-proxy',
    '^@/(.*)$': '<rootDir>/src/$1',
  },
};
```

### Testing All Stories Automatically

```tsx
// stories.test.tsx — auto-test every story in project
import { composeStories } from '@storybook/react';
import { render } from '@testing-library/react';

const modules = import.meta.glob('./src/**/*.stories.tsx', { eager: true });

describe('Story smoke tests', () => {
  Object.entries(modules).forEach(([path, module]) => {
    const stories = composeStories(module as any);
    Object.entries(stories).forEach(([name, Story]) => {
      it(`${path} — ${name} renders without error`, () => {
        const { container } = render(<Story />);
        expect(container).not.toBeEmptyDOMElement();
      });
    });
  });
});
```

---

## Snapshot Testing Strategies

### DOM Snapshots

```tsx
import { composeStories } from '@storybook/react';
import { render } from '@testing-library/react';
import * as stories from './Card.stories';

const { Default, WithImage, Loading } = composeStories(stories);

describe('Card snapshots', () => {
  it('Default matches snapshot', () => {
    const { container } = render(<Default />);
    expect(container.firstChild).toMatchSnapshot();
  });

  it('Loading matches snapshot', () => {
    const { container } = render(<Loading />);
    expect(container.firstChild).toMatchSnapshot();
  });
});
```

### Inline Snapshots (for small components)

```tsx
it('renders badge text', () => {
  const { container } = render(<Badge label="New" />);
  expect(container.innerHTML).toMatchInlineSnapshot(
    `"<span class=\\"badge badge-default\\">New</span>"`
  );
});
```

### When to Use Snapshots vs Other Tests

| Strategy | Use When | Avoid When |
|----------|----------|------------|
| DOM snapshot | Stable markup, design tokens | Dynamic content, frequent refactors |
| Visual (Chromatic) | Pixel-perfect UI, cross-browser | Fast iteration, early development |
| Interaction test | User flows, form validation | Static display components |
| a11y test | Compliance requirements | Decorative elements |

### Snapshot Update Workflow

```bash
# Update snapshots after intentional changes
npx vitest --update       # Vitest
npx jest --updateSnapshot # Jest

# Review changes in PR
git diff **/__snapshots__/*.snap
```

---

## CI/CD Integration for Visual Tests

### GitHub Actions — Full Pipeline

```yaml
name: Storybook CI
on:
  pull_request:
    branches: [main]
  push:
    branches: [main]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0  # for TurboSnap

      - uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: npm

      - run: npm ci

      # Build Storybook for testing
      - run: npx storybook build --test
        env:
          NODE_OPTIONS: '--max-old-space-size=8192'

      # Run interaction tests
      - name: Run Storybook tests
        run: |
          npx concurrently -k -s first \
            "npx http-server storybook-static --port 6006 --silent" \
            "npx wait-on tcp:127.0.0.1:6006 && npx test-storybook --url http://127.0.0.1:6006"

      # Visual regression with Chromatic
      - name: Chromatic
        if: github.event_name == 'pull_request'
        uses: chromaui/action@latest
        with:
          projectToken: ${{ secrets.CHROMATIC_PROJECT_TOKEN }}
          storybookBuildDir: storybook-static
          onlyChanged: true
          exitZeroOnChanges: true
          exitOnceUploaded: true

      # Upload test results
      - uses: actions/upload-artifact@v4
        if: failure()
        with:
          name: storybook-test-results
          path: storybook-static/
          retention-days: 7
```

### Parallel Test Sharding

```yaml
jobs:
  test:
    strategy:
      matrix:
        shard: [1, 2, 3, 4]
    steps:
      - run: npx test-storybook --shard ${{ matrix.shard }}/${{ strategy.job-total }}
```

### GitLab CI

```yaml
storybook-test:
  image: node:20
  stage: test
  before_script:
    - npm ci
    - npx playwright install --with-deps chromium
  script:
    - npx storybook build --test
    - npx concurrently -k -s first
        "npx http-server storybook-static --port 6006 --silent"
        "npx wait-on tcp:127.0.0.1:6006 && npx test-storybook"
  artifacts:
    when: always
    paths:
      - storybook-static/
    expire_in: 1 week

chromatic:
  image: node:20
  stage: test
  script:
    - npm ci
    - npx chromatic --project-token=$CHROMATIC_TOKEN --exit-zero-on-changes
  only:
    - merge_requests
```

### CircleCI

```yaml
version: 2.1
jobs:
  storybook-tests:
    docker:
      - image: cimg/node:20.0-browsers
    steps:
      - checkout
      - run: npm ci
      - run: npx storybook build --test
      - run:
          name: Run tests
          command: |
            npx concurrently -k -s first \
              "npx http-server storybook-static --port 6006 --silent" \
              "npx wait-on tcp:127.0.0.1:6006 && npx test-storybook"
      - store_artifacts:
          path: storybook-static
```

### Docker — Reproducible Test Environment

```dockerfile
FROM mcr.microsoft.com/playwright:v1.44.0-jammy
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npx storybook build --test
CMD ["sh", "-c", "npx concurrently -k -s first \
  'npx http-server storybook-static --port 6006 --silent' \
  'npx wait-on tcp:127.0.0.1:6006 && npx test-storybook --url http://127.0.0.1:6006'"]
```

### Status Checks and PR Comments

```yaml
- name: Comment PR with results
  if: always() && github.event_name == 'pull_request'
  uses: actions/github-script@v7
  with:
    script: |
      const fs = require('fs');
      const results = fs.existsSync('test-results.json')
        ? JSON.parse(fs.readFileSync('test-results.json', 'utf-8'))
        : { passed: 0, failed: 0 };
      await github.rest.issues.createComment({
        owner: context.repo.owner,
        repo: context.repo.repo,
        issue_number: context.issue.number,
        body: `## Storybook Test Results\n✅ Passed: ${results.passed}\n❌ Failed: ${results.failed}`,
      });
```
