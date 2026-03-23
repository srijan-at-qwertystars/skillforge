---
name: web-accessibility-a11y
description:
  positive: "Use when user builds accessible web interfaces, asks about WCAG compliance, ARIA roles/attributes, keyboard navigation, screen reader support, focus management, color contrast, or a11y testing tools (axe, Lighthouse, pa11y)."
  negative: "Do NOT use for PDF accessibility, native mobile accessibility (iOS/Android), or general UX design unrelated to accessibility."
---

# Web Accessibility (a11y)

## WCAG 2.2 Principles

Four pillars. Every success criterion falls under one.

### Perceivable
- Provide text alternatives for non-text content (1.1.1).
- Provide captions and audio descriptions for media (1.2.x).
- Make content adaptable — use semantic structure, not visual-only layout (1.3.x).
- Maintain minimum color contrast ratios (1.4.3, 1.4.6, 1.4.11).
- Allow text resize up to 200% without loss of content (1.4.4).
- Do not use color alone to convey information (1.4.1).

### Operable
- Make all functionality available via keyboard (2.1.1).
- Provide skip navigation links (2.4.1).
- Use descriptive page titles (2.4.2) and link purpose (2.4.4).
- Ensure focus order matches visual order (2.4.3).
- **WCAG 2.2**: Focus must not be obscured by sticky headers/footers (2.4.11, 2.4.12).
- **WCAG 2.2**: Focus indicators must meet minimum area and contrast (2.4.13).
- **WCAG 2.2**: Provide alternatives to dragging movements (2.5.7).
- **WCAG 2.2**: Minimum target size of 24×24 CSS pixels (2.5.8).

### Understandable
- Declare page language with `lang` attribute (3.1.1).
- Identify input errors and suggest corrections (3.3.1, 3.3.3).
- Provide labels or instructions for inputs (3.3.2).
- **WCAG 2.2**: Do not require redundant data entry (3.3.7).
- **WCAG 2.2**: Do not rely solely on cognitive tests for authentication (3.3.8, 3.3.9).

### Robust
- Use valid, well-formed HTML (4.1.1 — deprecated in 2.2 but still good practice).
- Ensure name, role, value are programmatically determinable for all UI components (4.1.2).
- Announce status messages to assistive tech without receiving focus (4.1.3).

---

## Semantic HTML as Foundation

Use native elements. They provide keyboard handling, focus management, and screen reader announcements for free.

### Landmarks
```html
<header>  <!-- banner -->
<nav>     <!-- navigation -->
<main>    <!-- main content — one per page -->
<aside>   <!-- complementary -->
<footer>  <!-- contentinfo -->
```

### Headings
- Use one `<h1>` per page. Nest `<h2>`–`<h6>` in logical order.
- Never skip heading levels (e.g., `<h1>` → `<h3>`).
- Screen reader users navigate by headings — make them descriptive.

### Buttons vs Divs
```html
<!-- WRONG: div as button -->
<div class="btn" onclick="save()">Save</div>

<!-- RIGHT: native button -->
<button type="button" onclick="save()">Save</button>
```
Native `<button>` gives you focus, Enter/Space activation, and `role="button"` automatically.

### Lists
Use `<ul>`/`<ol>` for groups. Screen readers announce "list, 5 items" — giving users context.

---

## ARIA Roles, States, and Properties

### When to Use ARIA
- Fill gaps where no native HTML element exists.
- Enhance dynamic widgets (tabs, comboboxes, dialogs).
- Communicate live updates to assistive tech.

### When NOT to Use ARIA
- **Never** override native semantics. `<button role="link">` is wrong — use `<a>`.
- Do not add `role="button"` to `<button>` — it already has it.
- No ARIA is better than bad ARIA. Incorrect ARIA actively harms users.

### Five Rules of ARIA
1. Use native HTML instead of ARIA when possible.
2. Do not change native semantics unless absolutely necessary.
3. All interactive ARIA controls must be keyboard operable.
4. Do not use `role="presentation"` or `aria-hidden="true"` on focusable elements.
5. All interactive elements must have an accessible name.

---

## Common ARIA Patterns

### Dialog (Modal)
```html
<div role="dialog" aria-modal="true" aria-labelledby="dlg-title" aria-describedby="dlg-desc">
  <h2 id="dlg-title">Delete item?</h2>
  <p id="dlg-desc">This action cannot be undone.</p>
  <button>Confirm</button>
  <button>Cancel</button>
</div>
```
- Trap focus inside dialog while open.
- Move focus to first focusable element on open.
- Return focus to trigger element on close.
- Close on Escape key.

### Tabs
```html
<div role="tablist" aria-label="Settings">
  <button role="tab" id="tab-1" aria-selected="true" aria-controls="panel-1">General</button>
  <button role="tab" id="tab-2" aria-selected="false" aria-controls="panel-2" tabindex="-1">Privacy</button>
</div>
<div role="tabpanel" id="panel-1" aria-labelledby="tab-1">General content</div>
<div role="tabpanel" id="panel-2" aria-labelledby="tab-2" hidden>Privacy content</div>
```
- Arrow keys move between tabs (roving tabindex).
- Tab key moves into the active panel content.
- Home/End keys jump to first/last tab.

### Combobox (Autocomplete)
```html
<label for="city-input">City</label>
<input id="city-input" role="combobox" aria-expanded="false"
       aria-controls="city-listbox" aria-activedescendant="">
<ul id="city-listbox" role="listbox" hidden>
  <li role="option" id="opt-1">New York</li>
  <li role="option" id="opt-2">Los Angeles</li>
</ul>
```
- Set `aria-expanded="true"` when listbox is visible.
- Update `aria-activedescendant` to the focused option's `id`.
- Arrow keys navigate options; Enter selects; Escape closes.

### Live Regions
```html
<!-- Polite: waits for screen reader to finish current speech -->
<div aria-live="polite" aria-atomic="true">3 results found</div>

<!-- Assertive: interrupts immediately — use sparingly -->
<div role="alert">Session expires in 2 minutes</div>
```
- `role="alert"` implies `aria-live="assertive"`.
- `role="status"` implies `aria-live="polite"`.
- Set `aria-atomic="true"` to announce the entire region content on change.
- Add `aria-busy="true"` during loading, remove when content is ready.

---

## Keyboard Navigation

### Focus Order
- Maintain a logical DOM order that matches visual layout.
- Never use positive `tabindex` values (e.g., `tabindex="5"`). Use `0` or `-1` only.
- `tabindex="0"` — element is focusable in natural order.
- `tabindex="-1"` — element is focusable programmatically only.

### Skip Links
```html
<body>
  <a href="#main-content" class="skip-link">Skip to main content</a>
  <nav>...</nav>
  <main id="main-content" tabindex="-1">...</main>
</body>
```
```css
.skip-link {
  position: absolute;
  left: -9999px;
}
.skip-link:focus {
  position: static;
  left: auto;
}
```

### Focus Trapping (Modals)
```js
function trapFocus(container) {
  const focusable = container.querySelectorAll(
    'a[href], button:not([disabled]), input:not([disabled]), select, textarea, [tabindex]:not([tabindex="-1"])'
  );
  const first = focusable[0];
  const last = focusable[focusable.length - 1];

  container.addEventListener('keydown', (e) => {
    if (e.key !== 'Tab') return;
    if (e.shiftKey && document.activeElement === first) {
      e.preventDefault();
      last.focus();
    } else if (!e.shiftKey && document.activeElement === last) {
      e.preventDefault();
      first.focus();
    }
  });
}
```

### Roving Tabindex (Toolbars, Tab Lists, Menus)
Set `tabindex="0"` on the active item and `tabindex="-1"` on all others. Move focus with arrow keys.

---

## Color Contrast Requirements

### Ratios
| Level | Normal text | Large text (≥18pt / bold ≥14pt) | UI components & graphics |
|-------|-------------|----------------------------------|--------------------------|
| AA    | 4.5:1       | 3:1                              | 3:1                      |
| AAA   | 7:1         | 4.5:1                            | —                        |

### Checking Tools
- **Browser DevTools**: Chrome/Edge → Inspect element → color picker shows contrast ratio.
- **WebAIM Contrast Checker**: https://webaim.org/resources/contrastchecker/
- **axe DevTools**: Flags contrast violations with suggested fixes.
- **Colour Contrast Analyser (CCA)**: Desktop app by TPGi.

### Rules
- Do not use color alone to indicate state (errors, required fields, active tabs).
- Provide additional visual cues: icons, underlines, patterns, or text labels.
- Ensure focus indicators meet 3:1 contrast against adjacent colors (WCAG 2.2 §2.4.13).

---

## Forms Accessibility

### Labels
```html
<!-- Explicit association -->
<label for="email">Email address</label>
<input id="email" type="email" required aria-describedby="email-hint">
<span id="email-hint">We'll never share your email.</span>
```
- Every input needs a visible `<label>`. Placeholder is not a label.
- Use `aria-describedby` for supplementary instructions.

### Required Fields
```html
<label for="name">Name <span aria-hidden="true">*</span></label>
<input id="name" type="text" required aria-required="true">
```
- Use the HTML `required` attribute. Add `aria-required="true"` for older screen readers.
- Indicate required fields visually AND programmatically.

### Error Messages
```html
<label for="phone">Phone</label>
<input id="phone" type="tel" aria-invalid="true" aria-describedby="phone-error">
<span id="phone-error" role="alert">Enter a valid phone number.</span>
```
- Set `aria-invalid="true"` on invalid fields.
- Link error messages via `aria-describedby`.
- Use `role="alert"` or a live region to announce errors immediately.

### Fieldset and Legend
```html
<fieldset>
  <legend>Shipping address</legend>
  <label for="street">Street</label>
  <input id="street" type="text">
  <!-- more fields -->
</fieldset>
```
Use `<fieldset>`/`<legend>` to group related inputs (radio buttons, checkboxes, address fields).

---

## Images

### Alt Text Guidelines
- **Informative images**: Describe the content concisely. `alt="Bar chart showing Q3 revenue up 12%"`.
- **Decorative images**: Use empty alt. `alt=""`. Do not omit the `alt` attribute entirely.
- **Functional images** (icons in buttons): Describe the action. `alt="Search"`, `alt="Close menu"`.
- **Complex images** (charts, diagrams): Provide a short alt + longer description nearby or via `aria-describedby`.
- Avoid "image of" or "picture of" — screen readers already announce "image".

```html
<!-- Informative -->
<img src="team.jpg" alt="Engineering team at the 2025 offsite">

<!-- Decorative -->
<img src="divider.svg" alt="">

<!-- Functional (inside button) -->
<button aria-label="Close dialog">
  <img src="x-icon.svg" alt="">
</button>

<!-- Complex -->
<figure>
  <img src="chart.png" alt="Revenue trends 2020–2025" aria-describedby="chart-desc">
  <figcaption id="chart-desc">Revenue grew from $2M in 2020 to $8M in 2025, with the steepest growth in 2023.</figcaption>
</figure>
```

---

## Dynamic Content and SPAs

### Live Regions for Dynamic Updates
```html
<div aria-live="polite" aria-atomic="true" class="sr-only" id="route-announcer"></div>
```
Update `textContent` after route changes or async operations so screen readers announce the change.

### aria-busy
```html
<div aria-live="polite" aria-busy="true">Loading results...</div>
<!-- After load completes: -->
<div aria-live="polite" aria-busy="false">5 results found</div>
```
Set `aria-busy="true"` during loading to suppress intermediate announcements.

### SPA Route Changes (React)
```jsx
import { useEffect, useRef } from 'react';
import { useLocation } from 'react-router-dom';

function RouteAnnouncer() {
  const { pathname } = useLocation();
  const ref = useRef(null);

  useEffect(() => {
    document.title = getPageTitle(pathname);
    ref.current?.focus();
  }, [pathname]);

  return <h1 tabIndex={-1} ref={ref}>{getPageTitle(pathname)}</h1>;
}
```
- Move focus to the main heading or content region on route change.
- Update `document.title` on every navigation.
- Use a visually hidden live region to announce the new page title.

### Visually Hidden Utility
```css
.sr-only {
  position: absolute;
  width: 1px;
  height: 1px;
  padding: 0;
  margin: -1px;
  overflow: hidden;
  clip: rect(0, 0, 0, 0);
  white-space: nowrap;
  border: 0;
}
```

---

## Testing Tools and Workflow

### Automated Testing

**axe-core** — gold standard engine. Zero false positives by design.
```bash
npm install --save-dev @axe-core/cli
npx axe http://localhost:3000
```

**axe with Playwright/Cypress:**
```js
// Playwright
import AxeBuilder from '@axe-core/playwright';

test('page has no a11y violations', async ({ page }) => {
  await page.goto('/');
  const results = await new AxeBuilder({ page }).analyze();
  expect(results.violations).toEqual([]);
});
```

**Lighthouse** — built into Chrome DevTools or CI:
```bash
npx lighthouse http://localhost:3000 --only-categories=accessibility --output=json
```

**pa11y** — CLI-first, supports multiple runners:
```bash
npx pa11y http://localhost:3000
npx pa11y --runner axe --runner htmlcs http://localhost:3000
```

### Manual Testing Checklist
1. Tab through the entire page. Verify logical focus order.
2. Activate every control with Enter/Space.
3. Verify Escape closes modals and dropdowns.
4. Test with screen reader (NVDA on Windows, VoiceOver on macOS, Orca on Linux).
5. Zoom to 200% — ensure no content loss or overlap.
6. Disable CSS — verify content order makes sense.
7. Check all images have appropriate alt text.
8. Verify form error messages are announced.

### Linting (React)
```bash
npm install --save-dev eslint-plugin-jsx-a11y
```
```json
// .eslintrc
{
  "plugins": ["jsx-a11y"],
  "extends": ["plugin:jsx-a11y/recommended"]
}
```
Catches issues at author time: missing alt, missing labels, invalid ARIA, non-interactive roles on interactive elements.

---

## React / Component Library A11y Patterns

### Accessible Modal (React)
```jsx
function Modal({ isOpen, onClose, title, children }) {
  const dialogRef = useRef(null);

  useEffect(() => {
    if (isOpen) dialogRef.current?.focus();
  }, [isOpen]);

  useEffect(() => {
    const handleEsc = (e) => { if (e.key === 'Escape') onClose(); };
    document.addEventListener('keydown', handleEsc);
    return () => document.removeEventListener('keydown', handleEsc);
  }, [onClose]);

  if (!isOpen) return null;

  return (
    <div role="dialog" aria-modal="true" aria-labelledby="modal-title" ref={dialogRef} tabIndex={-1}>
      <h2 id="modal-title">{title}</h2>
      {children}
      <button onClick={onClose}>Close</button>
    </div>
  );
}
```

### useId for Label Association (React 18+)
```jsx
import { useId } from 'react';

function TextField({ label }) {
  const id = useId();
  return (
    <>
      <label htmlFor={id}>{label}</label>
      <input id={id} type="text" />
    </>
  );
}
```

### Focus Restoration
```jsx
function useRestoreFocus() {
  const triggerRef = useRef(null);

  const saveFocus = () => { triggerRef.current = document.activeElement; };
  const restoreFocus = () => { triggerRef.current?.focus(); };

  return { saveFocus, restoreFocus };
}
```

---

## Common Violations and Quick Fixes

| Violation | Fix |
|-----------|-----|
| Missing alt text | Add descriptive `alt` or `alt=""` for decorative images |
| Missing form label | Add `<label for="id">` or `aria-label` |
| Low color contrast | Increase to 4.5:1 (normal text) or 3:1 (large text) |
| Non-keyboard-accessible control | Use `<button>` or `<a>` instead of `<div>` with click handler |
| Missing document language | Add `<html lang="en">` |
| Empty link / button | Add visible text, `aria-label`, or `sr-only` text |
| Positive tabindex | Remove. Use DOM order instead |
| Missing heading structure | Add headings in sequential order (`h1` → `h2` → `h3`) |
| Auto-playing media | Add pause/stop controls, or do not autoplay |
| Focus not visible | Ensure `:focus-visible` styles with 3:1 contrast |
| ARIA attribute on wrong role | Validate with axe. Remove mismatched attributes |
| Missing `aria-expanded` on toggle | Add `aria-expanded="true/false"` to toggle buttons |
| inaccessible custom select | Use native `<select>` or implement full ARIA listbox pattern |
| SPA route change not announced | Add route announcer with live region + focus management |
| Disabled focus styles | Restore `outline` on `:focus-visible`. Never use `outline: none` globally |

<!-- tested: pass -->
