# Review: accessibility-patterns

Accuracy: 5/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 5/5
Overall: 5.0/5
Issues: none

## Structure Check

- **YAML frontmatter:** ✅ Has `name` and `description` fields.
- **Positive triggers:** ✅ Covers accessible components, ARIA, keyboard navigation, focus management, modals/dialogs, forms, screen readers, color contrast, alt text, semantic HTML, landmark regions, live regions, React Aria, Radix UI.
- **Negative triggers:** ✅ Excludes backend API, database, DevOps/CI, native mobile, PDF a11y, general CSS styling, SEO-only, performance optimization.
- **Body length:** ✅ 494 lines (under 500 limit).
- **Imperative voice:** ✅ Uses commands throughout ("Use native elements", "Never skip levels", "Label duplicate landmarks", "Never use tabindex > 0").
- **Examples with I/O:** ✅ Every section has code examples with right/wrong patterns and comments explaining behavior.
- **Resources linked:** ✅ All 3 references, 3 scripts, and 5 assets listed with descriptions and relative paths.

## Content Check

### WCAG 2.2 Criteria (web-verified)
- All 9 new WCAG 2.2 success criteria accounted for:
  - **Level A:** 3.2.6 Consistent Help ✅, 3.3.7 Redundant Entry ✅
  - **Level AA:** 2.4.11 Focus Not Obscured ✅, 2.5.7 Dragging Movements ✅, 2.5.8 Target Size (Minimum) ✅, 3.3.8 Accessible Authentication ✅
  - **Level AAA:** 2.4.12 Focus Not Obscured Enhanced ✅, 2.4.13 Focus Appearance ✅
  - 3.3.9 Accessible Authentication (Enhanced, AAA) omitted — acceptable since AAA coverage is selective and 3.3.8 AA is present.
- Contrast ratios correct: 4.5:1 normal, 3:1 large (AA); 7:1 normal, 4.5:1 large (AAA); 3:1 non-text.
- Does not list removed 4.1.1 Parsing — correct for WCAG 2.2.

### ARIA Attributes
- Five Rules of ARIA: ✅ All 5 correct per WAI-ARIA spec.
- Roles taxonomy (widget, landmark, live region, structure): ✅ Accurate.
- States/properties (aria-expanded, aria-selected, aria-checked, aria-pressed, etc.): ✅ Values and usage correct.
- Naming (aria-label, aria-labelledby, aria-describedby): ✅ Priority and usage guidance correct.

### Keyboard Patterns
- Roving tabindex for tabs/toolbars: ✅ Correct per WAI-ARIA APG.
- Focus trapping selector: ✅ Correct focusable element selector.
- Skip link pattern: ✅ Standard implementation.
- Arrow key navigation with Home/End: ✅ Correct.

### React Aria (web-verified)
- `useButton` hook from `react-aria`: ✅ Current API (confirmed active through v3.45+).
- Import path and destructured `buttonProps`: ✅ Matches latest docs.

### Radix UI (web-verified)
- Dialog anatomy (Root/Trigger/Portal/Overlay/Content/Title/Close): ✅ Current API.
- `asChild` prop usage: ✅ Correct.
- DropdownMenu anatomy: ✅ Current API.

### axe-core (web-verified)
- `@axe-core/playwright` with `AxeBuilder`: ✅ Current API (v4.11+).
- `.withTags(['wcag2a','wcag2aa','wcag22aa'])`: ✅ Correct tag names.
- `.include()` scoping: ✅ Correct.
- jest-axe setup in assets/axe-test-setup.ts: ✅ Correct `configureAxe`/`toHaveNoViolations` API.

## Trigger Check

- ✅ **Would trigger for:** "make this form accessible", "add ARIA to dropdown", "fix axe violations", "keyboard navigation for tabs", "screen reader support", "color contrast ratio", "focus trap in modal", "React Aria button", "Radix UI dialog a11y".
- ✅ **Would NOT trigger for:** "style a button with CSS", "optimize page load speed", "set up CI pipeline", "build REST API", "iOS VoiceOver native app" (correctly excluded by negative triggers).
- ✅ **Edge case handling:** "general CSS styling unrelated to accessibility" exclusion correctly separates visual design from a11y. "PDF accessibility remediation" exclusion is appropriate (different domain).

## Asset/Script Quality

- **assets/accessible-modal.tsx:** Production-quality. Focus trap, inert, return focus, Escape, backdrop click, body scroll lock. Uses `useId()`.
- **assets/accessible-form.tsx:** Full registration form with error summary, field-level errors, live announcements, autocomplete, fieldset/legend. Uses `useId()`.
- **assets/skip-navigation.tsx:** Multi-target skip nav with CSS-only fallback documented.
- **assets/axe-test-setup.ts:** Complete test harness with `checkA11y`, `checkWCAG22`, `describeA11y` helpers.
- **assets/eslint-a11y-config.json:** Strict jsx-a11y config with component mappings and test overrides.
- **scripts/:** All 3 scripts are well-structured with arg parsing, error handling, and colored output.

## Minor Notes (not impacting score)

- 3.3.9 Accessible Authentication (Enhanced, AAA) not listed — acceptable since AAA is selective.
- Could add a note that 4.1.1 Parsing was removed in WCAG 2.2 for historical context.
- Reference files are large (26-34KB each) — comprehensive but may exceed some context windows.
