# Comprehensive Accessibility Testing Guide

End-to-end guide for automated, semi-automated, and manual accessibility testing across the development lifecycle.

## Table of Contents

- [Testing Pyramid](#testing-pyramid)
- [axe-core Integration](#axe-core-integration)
  - [Jest / Vitest + axe-core](#jest--vitest--axe-core)
  - [Cypress + axe-core](#cypress--axe-core)
  - [Playwright + axe-core](#playwright--axe-core)
  - [Writing Custom axe Rules](#writing-custom-axe-rules)
- [Storybook Accessibility Addon](#storybook-accessibility-addon)
- [pa11y CI](#pa11y-ci)
- [WAVE Tool](#wave-tool)
- [Lighthouse Accessibility Audits](#lighthouse-accessibility-audits)
- [Screen Reader Testing](#screen-reader-testing)
  - [VoiceOver (macOS/iOS)](#voiceover-macosios)
  - [NVDA (Windows)](#nvda-windows)
  - [JAWS (Windows)](#jaws-windows)
  - [Testing Methodology](#testing-methodology)
- [Manual Testing Checklist](#manual-testing-checklist)
- [CI/CD Pipeline Integration](#cicd-pipeline-integration)
- [Continuous Monitoring](#continuous-monitoring)

---

## Testing Pyramid

```
        ╱ ▲ ╲          Manual Screen Reader Testing
       ╱  │  ╲         (catches ~50% of remaining issues)
      ╱   │   ╲
     ╱────┼────╲       Semi-Automated: Guided Checks
    ╱     │     ╲      Lighthouse, WAVE, browser DevTools
   ╱      │      ╲
  ╱───────┼───────╲   Automated: axe-core, pa11y, ESLint
 ╱        │        ╲  (catches ~30-50% of all issues)
╱─────────┼─────────╲
```

**Automated** catches: missing alt text, color contrast, missing form labels, duplicate IDs, ARIA misuse.
**Cannot catch**: logical reading order, meaningful alt text quality, keyboard trap edge cases, cognitive load, timing issues.

---

## axe-core Integration

axe-core is the industry standard a11y testing engine. It checks against WCAG 2.0/2.1/2.2 A, AA, and AAA criteria.

### Jest / Vitest + axe-core

#### Setup

```bash
npm install -D jest-axe @testing-library/react @testing-library/jest-dom
# or for Vitest:
npm install -D vitest-axe @testing-library/react
```

#### Configuration (Jest)

```ts
// jest.setup.ts
import 'jest-axe/extend-expect';
```

```json
// jest.config.json
{
  "setupFilesAfterSetup": ["./jest.setup.ts"]
}
```

#### Configuration (Vitest)

```ts
// vitest.setup.ts
import 'vitest-axe/extend-expect';
```

```ts
// vitest.config.ts
import { defineConfig } from 'vitest/config';
export default defineConfig({
  test: {
    setupFiles: ['./vitest.setup.ts'],
  },
});
```

#### Basic Test

```tsx
import { render } from '@testing-library/react';
import { axe, toHaveNoViolations } from 'jest-axe';

expect.extend(toHaveNoViolations);

describe('LoginForm', () => {
  it('has no accessibility violations', async () => {
    const { container } = render(<LoginForm />);
    const results = await axe(container);
    expect(results).toHaveNoViolations();
  });

  it('has no violations when showing errors', async () => {
    const { container, getByRole } = render(<LoginForm />);
    fireEvent.click(getByRole('button', { name: /submit/i }));
    const results = await axe(container);
    expect(results).toHaveNoViolations();
  });
});
```

#### Scoped Testing

```tsx
it('modal content is accessible', async () => {
  const { container } = render(<ModalWithForm isOpen={true} />);
  const modal = container.querySelector('[role="dialog"]')!;
  const results = await axe(modal);
  expect(results).toHaveNoViolations();
});
```

#### Testing Multiple States

```tsx
const states = [
  { name: 'default', props: {} },
  { name: 'loading', props: { isLoading: true } },
  { name: 'error', props: { error: 'Failed to load' } },
  { name: 'empty', props: { data: [] } },
];

states.forEach(({ name, props }) => {
  it(`has no a11y violations in ${name} state`, async () => {
    const { container } = render(<DataTable {...props} />);
    const results = await axe(container);
    expect(results).toHaveNoViolations();
  });
});
```

#### Custom axe Configuration

```tsx
const results = await axe(container, {
  rules: {
    'color-contrast': { enabled: false }, // disable for dark mode test
    region: { enabled: false }, // allow content outside landmarks in unit tests
  },
  runOnly: {
    type: 'tag',
    values: ['wcag2a', 'wcag2aa', 'wcag22aa'],
  },
});
```

### Cypress + axe-core

#### Setup

```bash
npm install -D cypress-axe axe-core
```

```ts
// cypress/support/e2e.ts
import 'cypress-axe';
```

#### Tests

```ts
describe('Homepage', () => {
  beforeEach(() => {
    cy.visit('/');
    cy.injectAxe();
  });

  it('has no detectable a11y violations on load', () => {
    cy.checkA11y();
  });

  it('has no a11y violations after opening modal', () => {
    cy.get('[data-testid="open-modal"]').click();
    cy.checkA11y('[role="dialog"]');
  });

  it('has no a11y violations in dark mode', () => {
    cy.get('[data-testid="theme-toggle"]').click();
    cy.checkA11y(null, {
      rules: { 'color-contrast': { enabled: true } },
    });
  });

  // Log violations as a table for CI
  it('logs all violations', () => {
    cy.checkA11y(null, null, (violations) => {
      cy.task('log', `${violations.length} a11y violations found`);
      const violationData = violations.map(({ id, impact, description, nodes }) => ({
        id,
        impact,
        description,
        nodes: nodes.length,
      }));
      cy.task('table', violationData);
    });
  });
});
```

#### Custom Command for Impact Filtering

```ts
// cypress/support/commands.ts
Cypress.Commands.add('checkA11yCritical', (context?: string) => {
  cy.checkA11y(context ?? null, {
    includedImpacts: ['critical', 'serious'],
  });
});
```

### Playwright + axe-core

#### Setup

```bash
npm install -D @axe-core/playwright
```

#### Tests

```ts
import AxeBuilder from '@axe-core/playwright';
import { test, expect } from '@playwright/test';

test.describe('Accessibility', () => {
  test('homepage has no a11y violations', async ({ page }) => {
    await page.goto('/');
    const results = await new AxeBuilder({ page })
      .withTags(['wcag2a', 'wcag2aa', 'wcag22aa'])
      .analyze();
    expect(results.violations).toEqual([]);
  });

  test('scoped to main content', async ({ page }) => {
    await page.goto('/dashboard');
    const results = await new AxeBuilder({ page })
      .include('#main-content')
      .exclude('[data-testid="ad-banner"]')
      .analyze();
    expect(results.violations).toEqual([]);
  });

  test('keyboard navigation works', async ({ page }) => {
    await page.goto('/');
    await page.keyboard.press('Tab');
    const skipLink = await page.locator(':focus');
    await expect(skipLink).toHaveText(/skip to/i);
  });

  test('focus is trapped in modal', async ({ page }) => {
    await page.goto('/');
    await page.click('[data-testid="open-dialog"]');
    const dialog = page.locator('[role="dialog"]');
    await expect(dialog).toBeFocused();

    // Tab through all focusable elements in modal
    const focusableCount = await dialog.locator(
      'button, [href], input, select, textarea, [tabindex]:not([tabindex="-1"])'
    ).count();

    for (let i = 0; i < focusableCount + 1; i++) {
      await page.keyboard.press('Tab');
    }
    // Should still be in the dialog (focus trapped)
    const focused = await page.evaluate(() =>
      document.activeElement?.closest('[role="dialog"]') !== null
    );
    expect(focused).toBe(true);
  });
});
```

#### Playwright Fixture for Consistent Testing

```ts
// a11y-fixtures.ts
import { test as base, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';

type A11yFixtures = {
  makeAxeBuilder: () => AxeBuilder;
};

export const test = base.extend<A11yFixtures>({
  makeAxeBuilder: async ({ page }, use) => {
    const makeAxeBuilder = () =>
      new AxeBuilder({ page })
        .withTags(['wcag2a', 'wcag2aa', 'wcag22aa'])
        .disableRules(['color-contrast']); // if testing in non-prod theme
    await use(makeAxeBuilder);
  },
});

export { expect };
```

### Writing Custom axe Rules

```ts
import axe from 'axe-core';

// Custom rule: all images in product cards must have descriptive alt text
axe.configure({
  rules: [
    {
      id: 'product-image-alt',
      selector: '.product-card img',
      enabled: true,
      tags: ['custom', 'wcag2a'],
      metadata: {
        description: 'Product images must have descriptive alt text',
        help: 'Add meaningful alt text describing the product',
        helpUrl: 'https://internal-wiki/a11y/product-images',
      },
      any: ['has-descriptive-alt'],
    },
  ],
  checks: [
    {
      id: 'has-descriptive-alt',
      evaluate(node: HTMLImageElement) {
        const alt = node.getAttribute('alt');
        if (!alt) return false;
        // Reject generic alt text
        const generic = ['image', 'photo', 'picture', 'img', 'product'];
        return !generic.includes(alt.toLowerCase().trim());
      },
      metadata: {
        impact: 'serious',
        messages: {
          pass: 'Image has descriptive alt text',
          fail: 'Image alt text is missing or too generic',
        },
      },
    },
  ],
});
```

---

## Storybook Accessibility Addon

### Setup

```bash
npm install -D @storybook/addon-a11y
```

```ts
// .storybook/main.ts
const config: StorybookConfig = {
  addons: ['@storybook/addon-a11y'],
};
export default config;
```

### Per-Story Configuration

```tsx
// Button.stories.tsx
import type { Meta, StoryObj } from '@storybook/react';
import { Button } from './Button';

const meta: Meta<typeof Button> = {
  component: Button,
  parameters: {
    a11y: {
      config: {
        rules: [
          { id: 'color-contrast', enabled: true },
          { id: 'autocomplete-valid', enabled: false },
        ],
      },
    },
  },
};
export default meta;

export const Primary: StoryObj<typeof Button> = {
  args: { label: 'Click me', variant: 'primary' },
};

// Disable a11y for decorative-only stories
export const IconOnly: StoryObj<typeof Button> = {
  args: { icon: 'star' },
  parameters: {
    a11y: { disable: true },
  },
};
```

### Storybook Test Runner with a11y

```bash
npm install -D @storybook/test-runner axe-playwright
```

```ts
// .storybook/test-runner.ts
import { injectAxe, checkA11y } from 'axe-playwright';
import type { TestRunnerConfig } from '@storybook/test-runner';

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

## pa11y CI

### Installation

```bash
npm install -D pa11y-ci pa11y
```

### Configuration

```json
// .pa11yci.json
{
  "defaults": {
    "standard": "WCAG2AA",
    "timeout": 30000,
    "wait": 1000,
    "chromeLaunchConfig": {
      "args": ["--no-sandbox"]
    },
    "runners": ["axe", "htmlcs"],
    "ignore": [
      "WCAG2AA.Principle1.Guideline1_4.1_4_3.G18.Fail"
    ]
  },
  "urls": [
    "http://localhost:3000/",
    "http://localhost:3000/login",
    "http://localhost:3000/dashboard",
    {
      "url": "http://localhost:3000/modal-page",
      "actions": [
        "click element #open-modal",
        "wait for element #modal-content to be visible"
      ]
    },
    {
      "url": "http://localhost:3000/form",
      "actions": [
        "set field #email to test@example.com",
        "click element #submit",
        "wait for element .error-summary to be visible"
      ]
    }
  ]
}
```

### Running

```bash
# Single URL
npx pa11y http://localhost:3000 --standard WCAG2AA --reporter cli

# CI mode (multiple URLs from config)
npx pa11y-ci

# With JSON reporter for CI artifacts
npx pa11y-ci --reporter json > a11y-results.json

# Sitemap-based scanning
npx pa11y-ci --sitemap http://localhost:3000/sitemap.xml
```

### GitHub Actions Integration

```yaml
# .github/workflows/a11y.yml
name: Accessibility Tests
on: [pull_request]

jobs:
  a11y:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 20
      - run: npm ci
      - run: npm run build
      - run: npm run start &
      - run: npx wait-on http://localhost:3000
      - run: npx pa11y-ci
```

---

## WAVE Tool

WAVE (Web Accessibility Evaluation Tool) is a browser extension and API for visual a11y checking.

### Browser Extension Usage

1. Install WAVE browser extension (Chrome/Firefox/Edge)
2. Navigate to page → click WAVE icon
3. Review: Errors (red), Alerts (yellow), Features (green), Structural elements, ARIA, Contrast

### WAVE API (CI Integration)

```bash
# API-based scanning (requires API key from wave.webaim.org)
curl "https://wave.webaim.org/api/request?key=YOUR_KEY&url=https://example.com&reporttype=4"
```

### What WAVE Catches

| Category | Examples |
|----------|----------|
| Errors | Missing alt text, empty links/buttons, missing form labels, broken ARIA |
| Alerts | Redundant alt text, suspicious link text ("click here"), small text |
| Contrast | Exact contrast ratios for all text elements |
| Structure | Heading hierarchy, landmark regions, list markup |
| ARIA | Roles, states, properties validation |

### Interpreting Results

- **Fix all errors** — these are definite WCAG violations
- **Review all alerts** — many are false positives but some catch real issues
- **Check contrast tab** — identifies exact failing text/background pairs
- **Verify structure** — ensures heading order and landmarks are correct

---

## Lighthouse Accessibility Audits

### CLI Usage

```bash
# Full a11y audit
npx lighthouse http://localhost:3000 \
  --only-categories=accessibility \
  --output=json \
  --output-path=./lighthouse-a11y.json

# HTML report
npx lighthouse http://localhost:3000 \
  --only-categories=accessibility \
  --output=html \
  --output-path=./lighthouse-a11y.html

# Multiple output formats
npx lighthouse http://localhost:3000 \
  --only-categories=accessibility \
  --output=json --output=html \
  --output-path=./reports/a11y

# With performance budget assertions
npx lighthouse http://localhost:3000 \
  --only-categories=accessibility \
  --budget-path=./a11y-budget.json
```

### Budget File

```json
// a11y-budget.json
[
  {
    "path": "/*",
    "options": {
      "firstPartyHostnames": ["localhost"]
    },
    "resourceSizes": [],
    "resourceCounts": [],
    "timings": []
  }
]
```

### Lighthouse CI

```bash
npm install -D @lhci/cli
```

```json
// lighthouserc.json
{
  "ci": {
    "collect": {
      "url": [
        "http://localhost:3000/",
        "http://localhost:3000/dashboard"
      ],
      "numberOfRuns": 3
    },
    "assert": {
      "assertions": {
        "categories:accessibility": ["error", { "minScore": 0.9 }],
        "color-contrast": "error",
        "image-alt": "error",
        "label": "error",
        "document-title": "warn"
      }
    },
    "upload": {
      "target": "temporary-public-storage"
    }
  }
}
```

```bash
npx lhci autorun
```

### What Lighthouse Checks

Lighthouse runs a subset of axe-core rules. It provides a 0–100 score weighted by impact. Key audits:
- Image alt text, button names, link names
- Color contrast ratios
- Document language, title
- Form labels, ARIA attributes
- Heading order, tabindex values
- Focus traps, bypass blocks (skip links)

**Limitation**: Lighthouse catches fewer issues than full axe-core + manual testing. Treat a score of 100 as a baseline, not a guarantee of accessibility.

---

## Screen Reader Testing

Automated tools miss ~50-70% of accessibility issues. Screen reader testing is essential.

### VoiceOver (macOS/iOS)

#### Essential Shortcuts (macOS)

| Shortcut | Action |
|----------|--------|
| `Cmd+F5` | Toggle VoiceOver on/off |
| `VO` = `Ctrl+Option` | VoiceOver modifier key |
| `VO+→` / `VO+←` | Move to next/previous element |
| `VO+Space` | Activate (click) element |
| `VO+U` | Open Rotor (navigation menu) |
| `VO+A` | Read from cursor position |
| `Ctrl` | Stop speaking |
| `VO+H` | Open Help menu |
| `VO+Shift+↓` | Enter web content |
| `VO+Shift+↑` | Exit web content |
| `VO+Cmd+H` | Next heading |
| `VO+Cmd+L` | Next link |
| `VO+Cmd+J` | Next form element |
| `VO+Cmd+T` | Next table |

#### VoiceOver Rotor

Press `VO+U` to open the Rotor. Navigate categories with `←`/`→`:
- Headings, Links, Form Controls, Landmarks, Tables, Web Spots

#### Testing Workflow

1. Open Safari (best VoiceOver support on macOS)
2. Enable VoiceOver (`Cmd+F5`)
3. Navigate to the page
4. Use `VO+U` (Rotor) to check headings, landmarks, links
5. Tab through all interactive elements
6. Test forms: labels announced, errors announced, required state
7. Test dynamic content: live regions, loading states
8. Test modals: focus trap, dismiss, focus return

### NVDA (Windows)

#### Essential Shortcuts

| Shortcut | Action |
|----------|--------|
| `Insert` (or `Caps Lock`) | NVDA modifier key |
| `NVDA+Space` | Toggle focus/browse mode |
| `↓` / `↑` | Next/previous line in browse mode |
| `Tab` / `Shift+Tab` | Next/previous focusable element |
| `Enter` | Activate element |
| `NVDA+F7` | Elements list (headings, links, landmarks) |
| `H` / `Shift+H` | Next/previous heading |
| `D` / `Shift+D` | Next/previous landmark |
| `K` / `Shift+K` | Next/previous link |
| `F` / `Shift+F` | Next/previous form field |
| `T` / `Shift+T` | Next/previous table |
| `Ctrl` | Stop speaking |
| `NVDA+Q` | Quit NVDA |
| `1`–`6` | Jump to heading level 1–6 |

#### Browse Mode vs Focus Mode

- **Browse mode**: Navigate page content with single keys (H for headings, etc.)
- **Focus mode**: Interact with form controls. NVDA switches automatically on form fields.
- **Toggle**: `NVDA+Space` or `Escape`

### JAWS (Windows)

#### Essential Shortcuts

| Shortcut | Action |
|----------|--------|
| `Insert` | JAWS modifier key |
| `Insert+F6` | Heading list |
| `Insert+F7` | Link list |
| `Insert+F5` | Form field list |
| `H` / `Shift+H` | Next/previous heading |
| `R` / `Shift+R` | Next/previous landmark |
| `F` / `Shift+F` | Next/previous form field |
| `T` / `Shift+T` | Next/previous table |
| `Tab` | Next focusable element |
| `Enter` | Activate link/button |
| `Insert+Ctrl+W` | Select current window |
| `Insert+F1` | Identify current element |
| `Ctrl` | Stop speaking |
| `Insert+Space` | Toggle virtual/forms mode |
| `Insert+F4` | Quit JAWS |

### Testing Methodology

#### Pre-Test Setup

1. Clear browser cache
2. Disable browser extensions that may interfere
3. Set screen reader verbosity to maximum
4. Use the screen reader's preferred browser:
   - VoiceOver → Safari
   - NVDA → Firefox or Chrome
   - JAWS → Chrome or Edge

#### Test Script Template

```markdown
## Screen Reader Test: [Component/Page Name]
Date: ___  Tester: ___  SR: ___  Browser: ___

### Navigation
- [ ] Page title is announced on load
- [ ] Skip link is announced and functional
- [ ] Landmarks are detected (main, nav, banner, etc.)
- [ ] Heading hierarchy is logical (check with heading list)

### Content
- [ ] All images have appropriate alt text
- [ ] Decorative images are hidden from AT
- [ ] Links and buttons have meaningful names
- [ ] Lists are announced with item count
- [ ] Tables have proper headers and captions

### Interactive Elements
- [ ] All controls are reachable via Tab
- [ ] Control type is announced (button, link, checkbox, etc.)
- [ ] State is announced (expanded, selected, checked, etc.)
- [ ] Form labels are associated and announced
- [ ] Required fields are indicated
- [ ] Error messages are announced

### Dynamic Content
- [ ] Loading states are announced
- [ ] Search results count is announced
- [ ] Toast/notifications are announced
- [ ] Modal focus is trapped and announced
- [ ] Modal dismiss returns focus

### Keyboard
- [ ] No keyboard traps
- [ ] Focus order matches visual order
- [ ] Focus indicator is visible
- [ ] Custom widgets follow WAI-ARIA keyboard patterns
```

---

## Manual Testing Checklist

Run this checklist on every feature before release.

### Keyboard

- [ ] **Tab order**: All interactive elements reachable in logical order
- [ ] **Focus visible**: Focus indicator clearly visible on every element
- [ ] **No traps**: Can tab away from every element (except intentional modal traps)
- [ ] **Enter/Space**: All buttons/links activate correctly
- [ ] **Escape**: Closes modals, dropdowns, tooltips
- [ ] **Arrow keys**: Work in custom widgets (tabs, menus, sliders)
- [ ] **Skip link**: Present and functional

### Visual

- [ ] **Zoom 200%**: No content clipped or overlapping
- [ ] **Zoom 400%**: Content reflows (no horizontal scroll)
- [ ] **Text spacing**: Overridable without breaking layout
- [ ] **Color-only info**: No information conveyed by color alone
- [ ] **Contrast**: Text ≥ 4.5:1, large text ≥ 3:1, UI components ≥ 3:1
- [ ] **Reduced motion**: Animations respect `prefers-reduced-motion`
- [ ] **Forced colors**: UI usable in Windows High Contrast Mode
- [ ] **Dark mode**: Contrast maintained in dark theme

### Content

- [ ] **Images**: Meaningful alt text or `alt=""` for decorative
- [ ] **Links**: Purpose clear from text (not "click here")
- [ ] **Headings**: Correct hierarchy, no skipped levels
- [ ] **Language**: `lang` attribute on `<html>` and language changes
- [ ] **Page title**: Descriptive and unique for each page
- [ ] **Error messages**: Descriptive, associated with fields, announced

### Forms

- [ ] **Labels**: Every input has a visible, associated label
- [ ] **Required**: Required fields indicated (not by color alone)
- [ ] **Errors**: Error messages reference specific fields
- [ ] **Error summary**: Present after form submission failure
- [ ] **Autocomplete**: `autocomplete` attribute on personal data fields
- [ ] **Fieldsets**: Related controls grouped with fieldset/legend

### Dynamic

- [ ] **Live regions**: Status updates announced appropriately
- [ ] **Loading**: Loading state communicated to screen readers
- [ ] **Route changes**: SPA navigation announced
- [ ] **Timeouts**: User warned before session timeout
- [ ] **Modals**: Focus trapped, escape closes, focus returned

---

## CI/CD Pipeline Integration

### Multi-Tool CI Strategy

```yaml
# .github/workflows/a11y-comprehensive.yml
name: Accessibility CI
on:
  pull_request:
    branches: [main]

jobs:
  lint:
    name: ESLint a11y rules
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: 20 }
      - run: npm ci
      - run: npx eslint --no-error-on-unmatched-pattern 'src/**/*.{tsx,jsx}' --rule '{"jsx-a11y/alt-text":"error","jsx-a11y/anchor-is-valid":"error"}'

  unit-a11y:
    name: Unit tests with axe
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: 20 }
      - run: npm ci
      - run: npm run test -- --grep "a11y|accessibility"

  e2e-a11y:
    name: E2E accessibility audit
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: 20 }
      - run: npm ci
      - run: npm run build
      - run: npm run start &
      - run: npx wait-on http://localhost:3000 --timeout 60000
      - run: npx pa11y-ci --reporter json > pa11y-results.json
      - run: npx playwright test tests/a11y/
      - uses: actions/upload-artifact@v4
        if: always()
        with:
          name: a11y-results
          path: |
            pa11y-results.json
            test-results/

  lighthouse:
    name: Lighthouse a11y score
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: 20 }
      - run: npm ci && npm run build
      - run: npm run start &
      - run: npx wait-on http://localhost:3000
      - run: |
          npx @lhci/cli autorun --config=lighthouserc.json || true
      - uses: actions/upload-artifact@v4
        if: always()
        with:
          name: lighthouse-results
          path: .lighthouseci/
```

### PR Comment Bot

```ts
// scripts/a11y-pr-comment.ts
import { readFileSync } from 'fs';

const results = JSON.parse(readFileSync('pa11y-results.json', 'utf-8'));
const violations = results.results?.flatMap((r: any) => r.issues) ?? [];

const critical = violations.filter((v: any) => v.type === 'error');
const warnings = violations.filter((v: any) => v.type === 'warning');

const comment = `## ♿ Accessibility Report

| Severity | Count |
|----------|-------|
| 🔴 Errors | ${critical.length} |
| 🟡 Warnings | ${warnings.length} |

${critical.length > 0 ? `### Critical Issues\n${critical.slice(0, 10).map((v: any) =>
  `- **${v.code}**: ${v.message}\n  \`${v.selector}\``
).join('\n')}` : '✅ No critical accessibility issues found!'}
`;

console.log(comment);
```

---

## Continuous Monitoring

### Scheduled Audits

```yaml
# .github/workflows/a11y-monitor.yml
name: Weekly A11y Monitor
on:
  schedule:
    - cron: '0 9 * * 1' # Monday 9am
  workflow_dispatch:

jobs:
  audit:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: 20 }
      - run: npm ci
      - run: |
          npx pa11y-ci \
            --sitemap https://yoursite.com/sitemap.xml \
            --reporter json > weekly-a11y.json
      - run: node scripts/a11y-pr-comment.ts
      # Store results for trend tracking
      - uses: actions/upload-artifact@v4
        with:
          name: weekly-a11y-${{ github.run_number }}
          path: weekly-a11y.json
          retention-days: 90
```

### Monitoring Dashboard Metrics

Track these over time:
- **axe violations count** by severity (critical, serious, moderate, minor)
- **Lighthouse a11y score** per page
- **WCAG criteria coverage**: which criteria have automated tests
- **Manual test completion rate**: % of pages with completed manual audit
- **Screen reader test coverage**: pages tested with each screen reader

### Regression Detection

```ts
// scripts/a11y-regression.ts
import { readFileSync, existsSync } from 'fs';

const current = JSON.parse(readFileSync('current-results.json', 'utf-8'));
const baseline = existsSync('baseline-results.json')
  ? JSON.parse(readFileSync('baseline-results.json', 'utf-8'))
  : { total: 0, violations: [] };

const newViolations = current.violations.filter(
  (v: any) => !baseline.violations.some((b: any) => b.id === v.id && b.selector === v.selector)
);

if (newViolations.length > 0) {
  console.error(`❌ ${newViolations.length} NEW accessibility violations detected!`);
  newViolations.forEach((v: any) => {
    console.error(`  - [${v.impact}] ${v.id}: ${v.description}`);
    console.error(`    ${v.helpUrl}`);
  });
  process.exit(1);
} else {
  console.log('✅ No new accessibility violations.');
}
```
