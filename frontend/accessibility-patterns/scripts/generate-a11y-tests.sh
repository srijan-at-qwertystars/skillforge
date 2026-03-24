#!/usr/bin/env bash
# ============================================================================
# generate-a11y-tests.sh — Generate accessibility test templates for a component
#
# Usage:
#   ./generate-a11y-tests.sh <ComponentName> [--output-dir <dir>] [--framework jest|vitest]
#
# Examples:
#   ./generate-a11y-tests.sh Modal
#   ./generate-a11y-tests.sh DataTable --output-dir src/__tests__
#   ./generate-a11y-tests.sh Dropdown --framework vitest
#
# Generates:
#   1. <Component>.a11y.test.tsx — axe-core integration test
#   2. <Component>.keyboard.test.tsx — Keyboard navigation test
#   3. <Component>.sr.test.tsx — Screen reader announcement test
#
# Requirements: Node.js 16+
# ============================================================================

set -euo pipefail

# --- Colors ---
GREEN='\033[0;32m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# --- Defaults ---
COMPONENT=""
OUTPUT_DIR="."
FRAMEWORK="jest"

# --- Parse args ---
usage() {
  echo "Usage: $0 <ComponentName> [--output-dir <dir>] [--framework jest|vitest]"
  echo ""
  echo "Generates three accessibility test files for a React component:"
  echo "  1. axe-core integration test"
  echo "  2. Keyboard navigation test"
  echo "  3. Screen reader announcement test"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    --framework) FRAMEWORK="$2"; shift 2 ;;
    -h|--help) usage ;;
    -*) echo "Unknown option: $1"; usage ;;
    *) COMPONENT="$1"; shift ;;
  esac
done

if [[ -z "$COMPONENT" ]]; then
  echo "Error: Component name is required"
  usage
fi

# Derive lowercase/kebab variants
COMPONENT_LOWER=$(echo "$COMPONENT" | sed 's/\([A-Z]\)/-\L\1/g' | sed 's/^-//')
COMPONENT_CAMEL=$(echo "${COMPONENT:0:1}" | tr '[:upper:]' '[:lower:]')${COMPONENT:1}

mkdir -p "$OUTPUT_DIR"

# --- Determine imports based on framework ---
if [[ "$FRAMEWORK" == "vitest" ]]; then
  TEST_IMPORT="import { describe, it, expect, beforeEach } from 'vitest';"
  AXE_IMPORT="import { axe } from 'vitest-axe';
import 'vitest-axe/extend-expect';"
else
  TEST_IMPORT=""
  AXE_IMPORT="import { axe, toHaveNoViolations } from 'jest-axe';

expect.extend(toHaveNoViolations);"
fi

# ============================================================================
# 1. axe-core integration test
# ============================================================================
AXE_FILE="$OUTPUT_DIR/${COMPONENT}.a11y.test.tsx"
cat > "$AXE_FILE" << AXEEOF
/**
 * Accessibility integration tests for ${COMPONENT}
 *
 * Tests automated a11y checks using axe-core across all component states.
 * Catches ~30-50% of accessibility issues: missing labels, ARIA misuse,
 * contrast violations, and structural problems.
 *
 * Run: npx ${FRAMEWORK} ${AXE_FILE}
 */
${TEST_IMPORT}
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
${AXE_IMPORT}
// TODO: Update this import path to match your project structure
import { ${COMPONENT} } from '../${COMPONENT}';

describe('${COMPONENT} — axe-core accessibility', () => {
  // Test default/idle state
  it('has no accessibility violations in default state', async () => {
    const { container } = render(<${COMPONENT} />);
    const results = await axe(container);
    expect(results).toHaveNoViolations();
  });

  // Test with content/data
  it('has no violations when populated with data', async () => {
    const { container } = render(
      <${COMPONENT}>
        {/* TODO: Add typical content/props */}
      </${COMPONENT}>
    );
    const results = await axe(container);
    expect(results).toHaveNoViolations();
  });

  // Test loading state
  it('has no violations in loading state', async () => {
    const { container } = render(<${COMPONENT} isLoading />);
    const results = await axe(container);
    expect(results).toHaveNoViolations();
  });

  // Test error state
  it('has no violations in error state', async () => {
    const { container } = render(<${COMPONENT} error="Something went wrong" />);
    const results = await axe(container);
    expect(results).toHaveNoViolations();
  });

  // Test disabled state
  it('has no violations when disabled', async () => {
    const { container } = render(<${COMPONENT} isDisabled />);
    const results = await axe(container);
    expect(results).toHaveNoViolations();
  });

  // Test interactive state (e.g., open/expanded)
  it('has no violations in open/expanded state', async () => {
    const { container } = render(<${COMPONENT} isOpen />);
    const results = await axe(container);
    expect(results).toHaveNoViolations();
  });

  // Scoped test — only check the component, not full page
  it('component subtree passes axe audit', async () => {
    const { container } = render(
      <div>
        <header>Header</header>
        <main>
          <${COMPONENT} data-testid="${COMPONENT_LOWER}" />
        </main>
      </div>
    );
    const componentEl = container.querySelector('[data-testid="${COMPONENT_LOWER}"]');
    if (componentEl) {
      const results = await axe(componentEl as HTMLElement);
      expect(results).toHaveNoViolations();
    }
  });

  // Test with specific WCAG tags
  it('passes WCAG 2.2 AA criteria', async () => {
    const { container } = render(<${COMPONENT} />);
    const results = await axe(container, {
      runOnly: {
        type: 'tag',
        values: ['wcag2a', 'wcag2aa', 'wcag22aa'],
      },
    });
    expect(results).toHaveNoViolations();
  });
});
AXEEOF

echo -e "${GREEN}✓${NC} Created ${BLUE}${AXE_FILE}${NC}"

# ============================================================================
# 2. Keyboard navigation test
# ============================================================================
KB_FILE="$OUTPUT_DIR/${COMPONENT}.keyboard.test.tsx"
cat > "$KB_FILE" << KBEOF
/**
 * Keyboard navigation tests for ${COMPONENT}
 *
 * Verifies the component is fully operable via keyboard per WCAG 2.1.1
 * and follows WAI-ARIA Authoring Practices keyboard patterns.
 *
 * Run: npx ${FRAMEWORK} ${KB_FILE}
 */
${TEST_IMPORT}
import { render, screen, fireEvent } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
// TODO: Update this import path to match your project structure
import { ${COMPONENT} } from '../${COMPONENT}';

describe('${COMPONENT} — Keyboard Navigation', () => {
  let user: ReturnType<typeof userEvent.setup>;

  beforeEach(() => {
    user = userEvent.setup();
  });

  // WCAG 2.1.1: All functionality available from keyboard
  describe('Tab navigation', () => {
    it('is reachable via Tab key', async () => {
      render(<${COMPONENT} />);
      await user.tab();
      // TODO: Assert the correct element receives focus
      // expect(screen.getByRole('button', { name: /.../ })).toHaveFocus();
    });

    it('follows logical tab order', async () => {
      render(<${COMPONENT} />);
      // Tab through interactive elements and verify order
      await user.tab(); // First element
      // expect(screen.getByRole('...', { name: /first/ })).toHaveFocus();
      await user.tab(); // Second element
      // expect(screen.getByRole('...', { name: /second/ })).toHaveFocus();
    });

    it('does not create a keyboard trap (WCAG 2.1.2)', async () => {
      render(
        <>
          <button>Before</button>
          <${COMPONENT} />
          <button>After</button>
        </>
      );
      // Tab forward through the component
      const afterBtn = screen.getByRole('button', { name: 'After' });
      await user.tab(); // Before
      await user.tab(); // Into component
      // Keep tabbing...
      for (let i = 0; i < 10; i++) {
        await user.tab();
        if (document.activeElement === afterBtn) break;
      }
      // Should eventually reach the "After" button
      expect(afterBtn).toHaveFocus();
    });
  });

  // WCAG 2.4.7: Focus indicator visible
  describe('Focus visibility', () => {
    it('shows visible focus indicator', async () => {
      render(<${COMPONENT} />);
      await user.tab();
      const focused = document.activeElement;
      if (focused instanceof HTMLElement) {
        const styles = window.getComputedStyle(focused);
        // Check that outline is not 'none' or there is a box-shadow for focus
        const hasOutline = styles.outline !== 'none' && styles.outline !== '';
        const hasBoxShadow = styles.boxShadow !== 'none' && styles.boxShadow !== '';
        expect(hasOutline || hasBoxShadow).toBe(true);
      }
    });
  });

  // Activation keys
  describe('Enter and Space activation', () => {
    it('activates primary action with Enter', async () => {
      const onAction = ${FRAMEWORK === 'vitest' ? 'vi.fn()' : 'jest.fn()'};
      render(<${COMPONENT} onAction={onAction} />);
      // TODO: Focus the primary interactive element
      // await user.tab();
      await user.keyboard('{Enter}');
      // expect(onAction).toHaveBeenCalledTimes(1);
    });

    it('activates primary action with Space', async () => {
      const onAction = ${FRAMEWORK === 'vitest' ? 'vi.fn()' : 'jest.fn()'};
      render(<${COMPONENT} onAction={onAction} />);
      // TODO: Focus the primary interactive element
      // await user.tab();
      await user.keyboard(' ');
      // expect(onAction).toHaveBeenCalledTimes(1);
    });
  });

  // Escape key dismissal (for overlays, dropdowns, modals)
  describe('Escape key', () => {
    it('closes/dismisses with Escape key', async () => {
      const onClose = ${FRAMEWORK === 'vitest' ? 'vi.fn()' : 'jest.fn()'};
      render(<${COMPONENT} isOpen onClose={onClose} />);
      await user.keyboard('{Escape}');
      expect(onClose).toHaveBeenCalledTimes(1);
    });

    it('returns focus to trigger element after Escape', async () => {
      render(
        <>
          <button data-testid="trigger">Open ${COMPONENT}</button>
          <${COMPONENT} isOpen />
        </>
      );
      await user.keyboard('{Escape}');
      // expect(screen.getByTestId('trigger')).toHaveFocus();
    });
  });

  // Arrow key navigation (for composite widgets)
  describe('Arrow key navigation', () => {
    it('navigates items with ArrowDown/ArrowUp', async () => {
      render(<${COMPONENT} />);
      // TODO: Focus the composite widget
      // await user.tab();
      await user.keyboard('{ArrowDown}');
      // expect(/* next item */).toHaveFocus();
      await user.keyboard('{ArrowUp}');
      // expect(/* previous item */).toHaveFocus();
    });

    it('wraps focus or stops at boundaries', async () => {
      render(<${COMPONENT} />);
      // TODO: Navigate to last item, press ArrowDown
      // Verify it either wraps to first or stays on last
    });

    it('Home/End keys jump to first/last item', async () => {
      render(<${COMPONENT} />);
      // TODO: Focus within the widget
      await user.keyboard('{Home}');
      // expect(/* first item */).toHaveFocus();
      await user.keyboard('{End}');
      // expect(/* last item */).toHaveFocus();
    });
  });
});
KBEOF

echo -e "${GREEN}✓${NC} Created ${BLUE}${KB_FILE}${NC}"

# ============================================================================
# 3. Screen reader announcement test
# ============================================================================
SR_FILE="$OUTPUT_DIR/${COMPONENT}.sr.test.tsx"
cat > "$SR_FILE" << SREOF
/**
 * Screen reader announcement tests for ${COMPONENT}
 *
 * Verifies ARIA attributes, live region announcements, and role
 * assignments that screen readers depend on. Tests what AT will
 * announce, not visual rendering.
 *
 * Run: npx ${FRAMEWORK} ${SR_FILE}
 */
${TEST_IMPORT}
import { render, screen, fireEvent, within, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
// TODO: Update this import path to match your project structure
import { ${COMPONENT} } from '../${COMPONENT}';

describe('${COMPONENT} — Screen Reader Announcements', () => {
  // Accessible name
  describe('Accessible naming', () => {
    it('has an accessible name', () => {
      render(<${COMPONENT} />);
      // Verify via role query — if it has a role, it should have a name
      // TODO: Use the correct role for your component
      // const el = screen.getByRole('dialog', { name: /.../ });
      // expect(el).toBeInTheDocument();
    });

    it('uses aria-label or aria-labelledby correctly', () => {
      render(<${COMPONENT} title="My ${COMPONENT}" />);
      // TODO: Check that the label is properly associated
      // const el = screen.getByRole('...');
      // expect(el).toHaveAttribute('aria-label', 'My ${COMPONENT}');
      // — or —
      // expect(el).toHaveAttribute('aria-labelledby');
    });
  });

  // ARIA roles
  describe('ARIA roles', () => {
    it('has the correct role', () => {
      render(<${COMPONENT} />);
      // TODO: Replace with the expected role
      // expect(screen.getByRole('dialog')).toBeInTheDocument();
      // expect(screen.getByRole('tablist')).toBeInTheDocument();
      // expect(screen.getByRole('menu')).toBeInTheDocument();
    });
  });

  // ARIA states
  describe('ARIA states', () => {
    it('communicates expanded/collapsed state', () => {
      render(<${COMPONENT} />);
      // TODO: Find the trigger element
      // const trigger = screen.getByRole('button', { name: /toggle/i });
      // expect(trigger).toHaveAttribute('aria-expanded', 'false');
      // fireEvent.click(trigger);
      // expect(trigger).toHaveAttribute('aria-expanded', 'true');
    });

    it('communicates selected state', () => {
      render(<${COMPONENT} />);
      // TODO: For tabs, listbox options, etc.
      // const option = screen.getByRole('option', { name: /first/i });
      // expect(option).toHaveAttribute('aria-selected', 'false');
    });

    it('communicates disabled state', () => {
      render(<${COMPONENT} isDisabled />);
      // TODO: Check aria-disabled
      // const el = screen.getByRole('...');
      // expect(el).toHaveAttribute('aria-disabled', 'true');
    });

    it('communicates loading state via aria-busy', () => {
      render(<${COMPONENT} isLoading />);
      // const el = screen.getByRole('...');
      // expect(el).toHaveAttribute('aria-busy', 'true');
    });
  });

  // Live region announcements
  describe('Live regions', () => {
    it('announces status changes via aria-live', async () => {
      render(<${COMPONENT} />);

      // Verify a live region exists
      const liveRegion = document.querySelector('[aria-live]');
      expect(liveRegion).toBeInTheDocument();

      // TODO: Trigger an action that should cause an announcement
      // fireEvent.click(screen.getByRole('button', { name: /submit/i }));

      // Verify the live region content was updated
      // await waitFor(() => {
      //   expect(liveRegion).toHaveTextContent(/success|completed|updated/i);
      // });
    });

    it('uses polite for non-urgent updates', () => {
      render(<${COMPONENT} />);
      const statusRegion = document.querySelector('[role="status"]');
      if (statusRegion) {
        expect(statusRegion).toHaveAttribute('aria-live', 'polite');
      }
    });

    it('uses assertive for error/urgent messages', () => {
      render(<${COMPONENT} error="Critical error" />);
      const alertRegion = document.querySelector('[role="alert"]');
      if (alertRegion) {
        expect(alertRegion).toHaveTextContent(/critical error/i);
      }
    });
  });

  // Error announcements
  describe('Error announcements', () => {
    it('associates error messages with fields via aria-describedby', () => {
      render(<${COMPONENT} error="This field is required" />);
      // TODO: Find the input and its error
      // const input = screen.getByRole('textbox');
      // const errorId = input.getAttribute('aria-describedby');
      // expect(errorId).toBeTruthy();
      // const errorEl = document.getElementById(errorId!);
      // expect(errorEl).toHaveTextContent('This field is required');
    });

    it('marks invalid fields with aria-invalid', () => {
      render(<${COMPONENT} error="Invalid" />);
      // const input = screen.getByRole('textbox');
      // expect(input).toHaveAttribute('aria-invalid', 'true');
    });
  });

  // Descriptions
  describe('Descriptions', () => {
    it('provides description via aria-describedby', () => {
      render(<${COMPONENT} description="Help text for this field" />);
      // TODO: Check aria-describedby linkage
      // const el = screen.getByRole('...');
      // const descId = el.getAttribute('aria-describedby');
      // expect(document.getElementById(descId!)).toHaveTextContent('Help text');
    });
  });

  // Modal-specific (if applicable)
  describe('Modal semantics', () => {
    it('has aria-modal="true" when open', () => {
      render(<${COMPONENT} isOpen />);
      // const dialog = screen.getByRole('dialog');
      // expect(dialog).toHaveAttribute('aria-modal', 'true');
    });

    it('announces dialog title on open', () => {
      render(<${COMPONENT} isOpen title="Confirm Action" />);
      // const dialog = screen.getByRole('dialog', { name: 'Confirm Action' });
      // expect(dialog).toBeInTheDocument();
    });
  });
});
SREOF

echo -e "${GREEN}✓${NC} Created ${BLUE}${SR_FILE}${NC}"

# --- Summary ---
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}${BOLD}  ✅ Generated 3 accessibility test files for ${COMPONENT}${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${BLUE}1.${NC} ${AXE_FILE}"
echo -e "     axe-core integration — tests WCAG violations across component states"
echo ""
echo -e "  ${BLUE}2.${NC} ${KB_FILE}"
echo -e "     Keyboard navigation — Tab, Enter, Space, Escape, Arrow keys"
echo ""
echo -e "  ${BLUE}3.${NC} ${SR_FILE}"
echo -e "     Screen reader — ARIA roles, states, live regions, error messages"
echo ""
echo -e "  ${YELLOW}Next steps:${NC}"
echo -e "  1. Update import paths in each test file"
echo -e "  2. Uncomment and customize assertions marked with TODO"
echo -e "  3. Add component-specific test cases"
echo -e "  4. Run: npx ${FRAMEWORK} --testPathPattern='(a11y|keyboard|sr)'"
echo ""
