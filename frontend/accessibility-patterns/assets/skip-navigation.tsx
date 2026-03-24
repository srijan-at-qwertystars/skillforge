/**
 * Skip Navigation Component
 *
 * Provides a skip link that becomes visible on focus, allowing keyboard
 * users to bypass repetitive navigation and jump to main content.
 *
 * WCAG 2.4.1: A mechanism is available to bypass blocks of content
 * that are repeated on multiple Web pages.
 *
 * Usage:
 *   // In your app layout, place as the first focusable element:
 *   <SkipNavigation />
 *   <Header />
 *   <nav>...</nav>
 *   <main id="main-content" tabIndex={-1}>
 *     <SkipNavigationTarget />
 *     ...page content...
 *   </main>
 *
 *   // Or with custom targets:
 *   <SkipNavigation
 *     links={[
 *       { href: '#main-content', label: 'Skip to main content' },
 *       { href: '#search', label: 'Skip to search' },
 *       { href: '#footer-nav', label: 'Skip to footer navigation' },
 *     ]}
 *   />
 */

import React from 'react';

// --- Styles ---

const skipNavStyles: React.CSSProperties = {
  position: 'fixed',
  top: 0,
  left: 0,
  width: '100%',
  zIndex: 99999,
  display: 'flex',
  gap: '8px',
  padding: '8px',
  pointerEvents: 'none',
};

const skipLinkStyles: React.CSSProperties = {
  position: 'absolute',
  left: '-9999px',
  top: 'auto',
  width: '1px',
  height: '1px',
  overflow: 'hidden',
  // These properties are overridden on :focus via the inline handler below
  padding: '0',
  border: 'none',
  pointerEvents: 'auto',
};

const skipLinkFocusStyles: React.CSSProperties = {
  position: 'fixed',
  top: '8px',
  left: '8px',
  width: 'auto',
  height: 'auto',
  overflow: 'visible',
  padding: '12px 24px',
  backgroundColor: '#1a1a2e',
  color: '#ffffff',
  fontSize: '16px',
  fontWeight: 700,
  textDecoration: 'none',
  borderRadius: '4px',
  border: '2px solid #ffffff',
  boxShadow: '0 4px 12px rgba(0, 0, 0, 0.3)',
  outline: '2px solid #4f9cf8',
  outlineOffset: '2px',
  zIndex: 99999,
};

// --- Components ---

interface SkipLink {
  href: string;
  label: string;
}

interface SkipNavigationProps {
  /** Custom skip links. Defaults to a single "Skip to main content" link. */
  links?: SkipLink[];
}

export function SkipNavigation({ links }: SkipNavigationProps) {
  const defaultLinks: SkipLink[] = [
    { href: '#main-content', label: 'Skip to main content' },
  ];

  const skipLinks = links ?? defaultLinks;

  const handleClick = (e: React.MouseEvent<HTMLAnchorElement>, href: string) => {
    e.preventDefault();
    const targetId = href.replace('#', '');
    const target = document.getElementById(targetId);
    if (target) {
      // Ensure target is focusable
      if (!target.hasAttribute('tabindex')) {
        target.setAttribute('tabindex', '-1');
      }
      target.focus({ preventScroll: false });
      target.scrollIntoView({ behavior: 'smooth', block: 'start' });
    }
  };

  return (
    <nav aria-label="Skip navigation" style={skipNavStyles}>
      {skipLinks.map((link) => (
        <a
          key={link.href}
          href={link.href}
          onClick={(e) => handleClick(e, link.href)}
          style={skipLinkStyles}
          onFocus={(e) => {
            Object.assign(e.currentTarget.style, skipLinkFocusStyles);
          }}
          onBlur={(e) => {
            Object.assign(e.currentTarget.style, skipLinkStyles);
          }}
        >
          {link.label}
        </a>
      ))}
    </nav>
  );
}

/**
 * Skip Navigation Target
 *
 * Place this at the beginning of your main content area.
 * It provides the landing target for the skip link.
 */
interface SkipNavigationTargetProps {
  id?: string;
}

export function SkipNavigationTarget({ id = 'main-content' }: SkipNavigationTargetProps) {
  return (
    <div
      id={id}
      tabIndex={-1}
      style={{ outline: 'none' }}
      aria-hidden="true"
    />
  );
}

/**
 * CSS-only alternative (for non-React projects)
 *
 * Add this CSS to your stylesheet:
 *
 * .skip-link {
 *   position: absolute;
 *   left: -9999px;
 *   top: auto;
 *   width: 1px;
 *   height: 1px;
 *   overflow: hidden;
 *   z-index: 99999;
 * }
 *
 * .skip-link:focus {
 *   position: fixed;
 *   top: 8px;
 *   left: 8px;
 *   width: auto;
 *   height: auto;
 *   overflow: visible;
 *   padding: 12px 24px;
 *   background-color: #1a1a2e;
 *   color: #ffffff;
 *   font-size: 16px;
 *   font-weight: 700;
 *   text-decoration: none;
 *   border-radius: 4px;
 *   border: 2px solid #ffffff;
 *   box-shadow: 0 4px 12px rgba(0, 0, 0, 0.3);
 *   outline: 2px solid #4f9cf8;
 *   outline-offset: 2px;
 * }
 *
 * HTML:
 *   <a href="#main-content" class="skip-link">Skip to main content</a>
 *   ...
 *   <main id="main-content" tabindex="-1">...</main>
 */

export default SkipNavigation;
