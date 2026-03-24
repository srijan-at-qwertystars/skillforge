/**
 * axe-core Test Setup for Jest / Vitest
 *
 * Provides custom matchers, helper functions, and common test patterns
 * for automated accessibility testing with axe-core.
 *
 * Setup:
 *   Jest  — Add to jest.config: setupFilesAfterSetup: ['./axe-test-setup.ts']
 *   Vitest — Add to vitest.config: test.setupFiles: ['./axe-test-setup.ts']
 *
 * Usage in tests:
 *   import { checkA11y, checkA11yScoped, checkWCAG22 } from './axe-test-setup';
 *
 *   it('is accessible', async () => {
 *     const { container } = render(<MyComponent />);
 *     await checkA11y(container);
 *   });
 */

import { configureAxe, toHaveNoViolations, JestAxeConfigureOptions } from 'jest-axe';
import type { AxeResults, Result } from 'axe-core';

// --- Extend expect with axe matchers ---
expect.extend(toHaveNoViolations);

// --- Default axe configuration ---
const defaultAxeConfig: JestAxeConfigureOptions = {
  rules: {
    // Disable rules that don't apply in unit test context
    region: { enabled: false }, // Components aren't always in landmarks in tests
    'page-has-heading-one': { enabled: false }, // Not relevant for component tests
    'landmark-one-main': { enabled: false }, // Not relevant for component tests
  },
};

const axe = configureAxe(defaultAxeConfig);

// --- Helper Functions ---

/**
 * Check a container for accessibility violations.
 * Throws a descriptive error if violations are found.
 */
export async function checkA11y(
  container: Element,
  options?: JestAxeConfigureOptions
): Promise<void> {
  const configuredAxe = options ? configureAxe({ ...defaultAxeConfig, ...options }) : axe;
  const results = await configuredAxe(container);
  expect(results).toHaveNoViolations();
}

/**
 * Check a specific element within a container for accessibility violations.
 */
export async function checkA11yScoped(
  container: Element,
  selector: string,
  options?: JestAxeConfigureOptions
): Promise<void> {
  const element = container.querySelector(selector);
  if (!element) {
    throw new Error(`checkA11yScoped: No element found matching "${selector}"`);
  }
  await checkA11y(element, options);
}

/**
 * Check against WCAG 2.2 AA criteria specifically.
 */
export async function checkWCAG22(container: Element): Promise<void> {
  const results = await configureAxe({
    ...defaultAxeConfig,
    rules: {
      ...defaultAxeConfig.rules,
    },
  })(container);

  // Filter to only WCAG 2.x AA violations
  const wcag22Violations = results.violations.filter((v: Result) =>
    v.tags.some((tag: string) =>
      ['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa', 'wcag22aa'].includes(tag)
    )
  );

  if (wcag22Violations.length > 0) {
    const formatted = formatViolations(wcag22Violations);
    throw new Error(`WCAG 2.2 AA violations found:\n${formatted}`);
  }
}

/**
 * Run axe and return detailed results (for custom assertions).
 */
export async function getA11yResults(
  container: Element,
  options?: JestAxeConfigureOptions
): Promise<AxeResults> {
  const configuredAxe = options ? configureAxe({ ...defaultAxeConfig, ...options }) : axe;
  return configuredAxe(container) as unknown as Promise<AxeResults>;
}

/**
 * Check a11y and only fail on critical/serious violations.
 * Useful for incremental adoption.
 */
export async function checkA11yCritical(container: Element): Promise<void> {
  const results = await axe(container);
  const critical = (results as unknown as AxeResults).violations?.filter(
    (v: Result) => v.impact === 'critical' || v.impact === 'serious'
  ) ?? [];

  if (critical.length > 0) {
    const formatted = formatViolations(critical);
    throw new Error(`Critical/serious a11y violations found:\n${formatted}`);
  }
}

// --- Formatting ---

function formatViolations(violations: Result[]): string {
  return violations
    .map((v) => {
      const nodes = v.nodes
        .map((n) => `    - ${n.html}\n      Fix: ${n.failureSummary}`)
        .join('\n');
      const wcagTags = v.tags
        .filter((t: string) => t.startsWith('wcag'))
        .join(', ');
      return `\n  [${v.impact?.toUpperCase()}] ${v.id}: ${v.description}\n  WCAG: ${wcagTags}\n  Help: ${v.helpUrl}\n  Affected nodes:\n${nodes}`;
    })
    .join('\n');
}

// --- Test Pattern Helpers ---

/**
 * Test all visual states of a component for a11y.
 * Pass an array of {name, element} objects.
 */
export async function checkA11yStates(
  states: Array<{ name: string; element: Element }>
): Promise<void> {
  const failures: string[] = [];

  for (const { name, element } of states) {
    try {
      const results = await axe(element);
      const violations = (results as unknown as AxeResults).violations ?? [];
      if (violations.length > 0) {
        failures.push(
          `State "${name}": ${violations.length} violation(s)\n${formatViolations(violations)}`
        );
      }
    } catch (err) {
      failures.push(`State "${name}": Error running axe - ${err}`);
    }
  }

  if (failures.length > 0) {
    throw new Error(`A11y violations in component states:\n${failures.join('\n\n')}`);
  }
}

/**
 * Create a test suite that checks a11y across multiple component configurations.
 *
 * Usage:
 *   describeA11y('Button', [
 *     { name: 'primary', render: () => render(<Button variant="primary">Click</Button>) },
 *     { name: 'disabled', render: () => render(<Button disabled>Click</Button>) },
 *     { name: 'loading', render: () => render(<Button loading>Click</Button>) },
 *   ]);
 */
export function describeA11y(
  componentName: string,
  variants: Array<{ name: string; render: () => { container: HTMLElement } }>
): void {
  describe(`${componentName} — Accessibility`, () => {
    variants.forEach(({ name, render: renderFn }) => {
      it(`"${name}" variant has no a11y violations`, async () => {
        const { container } = renderFn();
        await checkA11y(container);
      });
    });
  });
}

// --- Exports ---

export { axe, configureAxe, toHaveNoViolations };
