// locale-switcher.tsx — Locale switcher component
//
// Copy into your project's components directory.
// Works with both next-intl (Next.js) and react-i18next (React SPA).
//
// Features:
//   - Dropdown with locale names in their native script
//   - Current locale indicator
//   - URL-based locale switching (Next.js) or i18next language change (React)
//   - Keyboard accessible (arrow keys, Enter, Escape)
//   - Optional flag emoji display
//   - Responsive: compact on mobile, full on desktop

'use client';

import React, { useState, useRef, useEffect, useCallback } from 'react';

// ---------------------------------------------------------------------------
// Locale metadata
// ---------------------------------------------------------------------------

interface LocaleInfo {
  /** BCP 47 locale code */
  code: string;
  /** Native name (in the locale's own script) */
  name: string;
  /** English name */
  englishName: string;
  /** Country flag emoji (optional, uses region code) */
  flag: string;
  /** Text direction */
  dir: 'ltr' | 'rtl';
}

const LOCALES: LocaleInfo[] = [
  { code: 'en',    name: 'English',    englishName: 'English',              flag: '🇺🇸', dir: 'ltr' },
  { code: 'fr',    name: 'Français',   englishName: 'French',              flag: '🇫🇷', dir: 'ltr' },
  { code: 'de',    name: 'Deutsch',    englishName: 'German',              flag: '🇩🇪', dir: 'ltr' },
  { code: 'es',    name: 'Español',    englishName: 'Spanish',             flag: '🇪🇸', dir: 'ltr' },
  { code: 'pt-BR', name: 'Português',  englishName: 'Portuguese (Brazil)', flag: '🇧🇷', dir: 'ltr' },
  { code: 'ja',    name: '日本語',     englishName: 'Japanese',             flag: '🇯🇵', dir: 'ltr' },
  { code: 'zh-Hans', name: '简体中文', englishName: 'Chinese (Simplified)', flag: '🇨🇳', dir: 'ltr' },
  { code: 'ko',    name: '한국어',     englishName: 'Korean',               flag: '🇰🇷', dir: 'ltr' },
  { code: 'ar',    name: 'العربية',    englishName: 'Arabic',               flag: '🇸🇦', dir: 'rtl' },
  { code: 'he',    name: 'עברית',      englishName: 'Hebrew',               flag: '🇮🇱', dir: 'rtl' },
];

// ---------------------------------------------------------------------------
// Props
// ---------------------------------------------------------------------------

interface LocaleSwitcherProps {
  /** Currently active locale code */
  currentLocale: string;
  /** List of supported locale codes (filters LOCALES above) */
  supportedLocales: string[];
  /** Called when user selects a new locale */
  onLocaleChange: (locale: string) => void;
  /** Show flag emoji (default: true) */
  showFlags?: boolean;
  /** Show English name alongside native name (default: false) */
  showEnglishName?: boolean;
  /** Compact mode — icon only, no label (default: false) */
  compact?: boolean;
  /** Additional CSS class */
  className?: string;
}

// ---------------------------------------------------------------------------
// Component
// ---------------------------------------------------------------------------

export function LocaleSwitcher({
  currentLocale,
  supportedLocales,
  onLocaleChange,
  showFlags = true,
  showEnglishName = false,
  compact = false,
  className = '',
}: LocaleSwitcherProps) {
  const [isOpen, setIsOpen] = useState(false);
  const [focusIndex, setFocusIndex] = useState(-1);
  const containerRef = useRef<HTMLDivElement>(null);
  const listRef = useRef<HTMLUListElement>(null);

  const availableLocales = LOCALES.filter(l => supportedLocales.includes(l.code));
  const currentInfo = availableLocales.find(l => l.code === currentLocale) ?? availableLocales[0];

  // Close on outside click
  useEffect(() => {
    function handleClickOutside(e: MouseEvent) {
      if (containerRef.current && !containerRef.current.contains(e.target as Node)) {
        setIsOpen(false);
      }
    }
    document.addEventListener('mousedown', handleClickOutside);
    return () => document.removeEventListener('mousedown', handleClickOutside);
  }, []);

  // Keyboard navigation
  const handleKeyDown = useCallback((e: React.KeyboardEvent) => {
    switch (e.key) {
      case 'ArrowDown':
        e.preventDefault();
        if (!isOpen) { setIsOpen(true); setFocusIndex(0); }
        else setFocusIndex(i => Math.min(i + 1, availableLocales.length - 1));
        break;
      case 'ArrowUp':
        e.preventDefault();
        setFocusIndex(i => Math.max(i - 1, 0));
        break;
      case 'Enter':
      case ' ':
        e.preventDefault();
        if (isOpen && focusIndex >= 0) {
          onLocaleChange(availableLocales[focusIndex].code);
          setIsOpen(false);
        } else {
          setIsOpen(!isOpen);
          setFocusIndex(0);
        }
        break;
      case 'Escape':
        setIsOpen(false);
        setFocusIndex(-1);
        break;
    }
  }, [isOpen, focusIndex, availableLocales, onLocaleChange]);

  // Scroll focused item into view
  useEffect(() => {
    if (isOpen && focusIndex >= 0 && listRef.current) {
      const items = listRef.current.querySelectorAll('[role="option"]');
      items[focusIndex]?.scrollIntoView({ block: 'nearest' });
    }
  }, [focusIndex, isOpen]);

  return (
    <div
      ref={containerRef}
      className={`locale-switcher ${className}`}
      style={{ position: 'relative', display: 'inline-block' }}
    >
      {/* Trigger button */}
      <button
        type="button"
        role="combobox"
        aria-expanded={isOpen}
        aria-haspopup="listbox"
        aria-label={`Current language: ${currentInfo.englishName}. Change language.`}
        onClick={() => setIsOpen(!isOpen)}
        onKeyDown={handleKeyDown}
        style={{
          display: 'flex',
          alignItems: 'center',
          gap: '6px',
          padding: compact ? '6px 8px' : '6px 12px',
          border: '1px solid #d1d5db',
          borderRadius: '6px',
          background: 'white',
          cursor: 'pointer',
          fontSize: '14px',
          lineHeight: '1.4',
        }}
      >
        {showFlags && <span aria-hidden="true">{currentInfo.flag}</span>}
        {!compact && <span>{currentInfo.name}</span>}
        <span aria-hidden="true" style={{ fontSize: '10px', marginInlineStart: '4px' }}>
          {isOpen ? '▲' : '▼'}
        </span>
      </button>

      {/* Dropdown */}
      {isOpen && (
        <ul
          ref={listRef}
          role="listbox"
          aria-label="Select language"
          style={{
            position: 'absolute',
            insetBlockStart: '100%',
            insetInlineEnd: '0',
            marginBlockStart: '4px',
            padding: '4px 0',
            minInlineSize: '200px',
            maxBlockSize: '300px',
            overflowY: 'auto',
            background: 'white',
            border: '1px solid #d1d5db',
            borderRadius: '8px',
            boxShadow: '0 4px 12px rgba(0, 0, 0, 0.15)',
            listStyle: 'none',
            zIndex: 50,
          }}
        >
          {availableLocales.map((locale, index) => {
            const isActive = locale.code === currentLocale;
            const isFocused = index === focusIndex;

            return (
              <li
                key={locale.code}
                role="option"
                aria-selected={isActive}
                onClick={() => {
                  onLocaleChange(locale.code);
                  setIsOpen(false);
                }}
                onMouseEnter={() => setFocusIndex(index)}
                style={{
                  display: 'flex',
                  alignItems: 'center',
                  gap: '8px',
                  padding: '8px 12px',
                  cursor: 'pointer',
                  fontSize: '14px',
                  background: isFocused ? '#f3f4f6' : isActive ? '#eff6ff' : 'transparent',
                  fontWeight: isActive ? 600 : 400,
                  direction: locale.dir,
                }}
              >
                {showFlags && <span aria-hidden="true">{locale.flag}</span>}
                <span style={{ flex: 1 }}>
                  {locale.name}
                  {showEnglishName && locale.name !== locale.englishName && (
                    <span style={{ color: '#6b7280', fontSize: '12px', marginInlineStart: '6px' }}>
                      {locale.englishName}
                    </span>
                  )}
                </span>
                {isActive && (
                  <span aria-label="Current language" style={{ color: '#2563eb', fontSize: '16px' }}>
                    ✓
                  </span>
                )}
              </li>
            );
          })}
        </ul>
      )}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Usage with next-intl (Next.js App Router)
// ---------------------------------------------------------------------------

// import { useLocale } from 'next-intl';
// import { useRouter, usePathname } from '@/i18n/navigation';
// import { routing } from '@/i18n/routing';
//
// export function AppLocaleSwitcher() {
//   const locale = useLocale();
//   const router = useRouter();
//   const pathname = usePathname();
//
//   return (
//     <LocaleSwitcher
//       currentLocale={locale}
//       supportedLocales={[...routing.locales]}
//       onLocaleChange={(newLocale) => {
//         document.cookie = `NEXT_LOCALE=${newLocale};path=/;max-age=${365*24*60*60}`;
//         router.replace(pathname, { locale: newLocale });
//       }}
//     />
//   );
// }

// ---------------------------------------------------------------------------
// Usage with react-i18next (React SPA)
// ---------------------------------------------------------------------------

// import { useTranslation } from 'react-i18next';
// import { SUPPORTED_LOCALES } from './i18n-config';
//
// export function AppLocaleSwitcher() {
//   const { i18n } = useTranslation();
//
//   return (
//     <LocaleSwitcher
//       currentLocale={i18n.language}
//       supportedLocales={[...SUPPORTED_LOCALES]}
//       onLocaleChange={(newLocale) => {
//         i18n.changeLanguage(newLocale);
//       }}
//     />
//   );
// }
