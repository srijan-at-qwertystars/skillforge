// date-formatter.ts — Locale-aware date/time/relative time formatting utilities
//
// Copy into your project as src/lib/date-formatter.ts or src/utils/date-formatter.ts
//
// Features:
//   - Locale-aware date formatting (short, medium, long, full)
//   - Time formatting with timezone support
//   - Relative time ("2 hours ago", "yesterday", "in 3 days")
//   - Smart formatting (relative for recent, absolute for older)
//   - Date range formatting
//   - Calendar system support (Gregorian, Buddhist, Persian, Japanese)
//   - formatToParts wrappers for custom rendering
//   - All functions use Intl API — zero dependencies

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export type DateStyle = 'short' | 'medium' | 'long' | 'full';
export type TimeStyle = 'short' | 'medium' | 'long' | 'full';
export type RelativeTimeStyle = 'long' | 'short' | 'narrow';
export type RelativeTimeNumeric = 'always' | 'auto';

export interface FormatDateOptions {
  locale: string;
  dateStyle?: DateStyle;
  timeStyle?: TimeStyle;
  timeZone?: string;
  calendar?: string;
  hourCycle?: 'h11' | 'h12' | 'h23' | 'h24';
}

export interface FormatRelativeOptions {
  locale: string;
  style?: RelativeTimeStyle;
  numeric?: RelativeTimeNumeric;
  now?: Date;
}

export interface SmartFormatOptions {
  locale: string;
  /** Max age in ms to show relative time (default: 7 days) */
  relativeThreshold?: number;
  /** Date style for absolute dates (default: 'medium') */
  absoluteDateStyle?: DateStyle;
  now?: Date;
}

// ---------------------------------------------------------------------------
// Date formatting
// ---------------------------------------------------------------------------

/**
 * Format a date with locale-aware date and/or time style.
 *
 * @example
 * formatDate(new Date(), { locale: 'de-DE', dateStyle: 'long' })
 * // → "15. März 2024"
 *
 * formatDate(new Date(), { locale: 'ja-JP', dateStyle: 'full' })
 * // → "2024年3月15日金曜日"
 */
export function formatDate(date: Date | number | string, options: FormatDateOptions): string {
  const d = toDate(date);
  const { locale, ...intlOptions } = options;
  return new Intl.DateTimeFormat(locale, intlOptions).format(d);
}

/**
 * Format only the date portion (no time).
 */
export function formatDateOnly(
  date: Date | number | string,
  locale: string,
  style: DateStyle = 'medium'
): string {
  return formatDate(date, { locale, dateStyle: style });
}

/**
 * Format only the time portion.
 */
export function formatTimeOnly(
  date: Date | number | string,
  locale: string,
  style: TimeStyle = 'short',
  timeZone?: string
): string {
  return formatDate(date, { locale, timeStyle: style, timeZone });
}

/**
 * Format date and time together.
 */
export function formatDateTime(
  date: Date | number | string,
  locale: string,
  dateStyle: DateStyle = 'medium',
  timeStyle: TimeStyle = 'short',
  timeZone?: string
): string {
  return formatDate(date, { locale, dateStyle, timeStyle, timeZone });
}

// ---------------------------------------------------------------------------
// Date parts (for custom rendering)
// ---------------------------------------------------------------------------

export interface DatePart {
  type: Intl.DateTimeFormatPartTypes;
  value: string;
}

/**
 * Get formatted date as individual parts for custom rendering.
 *
 * @example
 * const parts = formatDateParts(new Date(), 'en-US', { month: 'long', day: 'numeric' });
 * // → [{ type: 'month', value: 'March' }, { type: 'literal', value: ' ' }, { type: 'day', value: '15' }]
 */
export function formatDateParts(
  date: Date | number | string,
  locale: string,
  options: Intl.DateTimeFormatOptions = {}
): DatePart[] {
  const d = toDate(date);
  return new Intl.DateTimeFormat(locale, options).formatToParts(d);
}

/**
 * Extract a specific part from a formatted date.
 *
 * @example
 * getDatePart(new Date(), 'en-US', 'month', { month: 'long' })
 * // → "March"
 */
export function getDatePart(
  date: Date | number | string,
  locale: string,
  partType: Intl.DateTimeFormatPartTypes,
  options: Intl.DateTimeFormatOptions = {}
): string | undefined {
  return formatDateParts(date, locale, options)
    .find(p => p.type === partType)?.value;
}

// ---------------------------------------------------------------------------
// Relative time formatting
// ---------------------------------------------------------------------------

type TimeUnit = 'year' | 'month' | 'week' | 'day' | 'hour' | 'minute' | 'second';

const TIME_UNITS: [TimeUnit, number][] = [
  ['year', 31536000],
  ['month', 2592000],
  ['week', 604800],
  ['day', 86400],
  ['hour', 3600],
  ['minute', 60],
  ['second', 1],
];

/**
 * Format a date as relative time from now (or a reference date).
 *
 * @example
 * formatRelativeTime(yesterday, { locale: 'en' })     // → "yesterday"
 * formatRelativeTime(yesterday, { locale: 'ja' })     // → "昨日"
 * formatRelativeTime(twoHoursAgo, { locale: 'fr' })   // → "il y a 2 heures"
 * formatRelativeTime(nextWeek, { locale: 'ar-EG' })   // → "خلال أسبوع واحد"
 */
export function formatRelativeTime(
  date: Date | number | string,
  options: FormatRelativeOptions
): string {
  const { locale, style = 'long', numeric = 'auto', now = new Date() } = options;
  const d = toDate(date);
  const diffSec = (d.getTime() - now.getTime()) / 1000;
  const absDiff = Math.abs(diffSec);

  const rtf = new Intl.RelativeTimeFormat(locale, { numeric, style });

  for (const [unit, seconds] of TIME_UNITS) {
    if (absDiff >= seconds || unit === 'second') {
      return rtf.format(Math.round(diffSec / seconds), unit);
    }
  }

  return rtf.format(0, 'second');
}

/**
 * Get the best time unit for a given duration.
 */
export function getBestTimeUnit(seconds: number): { unit: TimeUnit; value: number } {
  const abs = Math.abs(seconds);
  for (const [unit, unitSeconds] of TIME_UNITS) {
    if (abs >= unitSeconds) {
      return { unit, value: Math.round(seconds / unitSeconds) };
    }
  }
  return { unit: 'second', value: Math.round(seconds) };
}

// ---------------------------------------------------------------------------
// Smart formatting (relative vs. absolute)
// ---------------------------------------------------------------------------

const SEVEN_DAYS_MS = 7 * 24 * 60 * 60 * 1000;

/**
 * Intelligently format a date:
 *  - Recent dates (within threshold): relative time ("2 hours ago", "yesterday")
 *  - Same year: month and day ("Mar 15")
 *  - Different year: full date ("Mar 15, 2023")
 *
 * @example
 * smartFormatDate(twoHoursAgo, { locale: 'en' })       // → "2 hours ago"
 * smartFormatDate(lastMonth, { locale: 'en' })          // → "Feb 15"
 * smartFormatDate(lastYear, { locale: 'en' })           // → "Mar 15, 2023"
 * smartFormatDate(twoHoursAgo, { locale: 'ja' })        // → "2時間前"
 */
export function smartFormatDate(
  date: Date | number | string,
  options: SmartFormatOptions
): string {
  const {
    locale,
    relativeThreshold = SEVEN_DAYS_MS,
    absoluteDateStyle = 'medium',
    now = new Date(),
  } = options;
  const d = toDate(date);
  const diffMs = Math.abs(now.getTime() - d.getTime());

  // Recent: use relative time
  if (diffMs < relativeThreshold) {
    return formatRelativeTime(d, { locale, now });
  }

  // Same year: short format without year
  if (d.getFullYear() === now.getFullYear()) {
    return new Intl.DateTimeFormat(locale, {
      month: 'short',
      day: 'numeric',
    }).format(d);
  }

  // Different year: include year
  return formatDateOnly(d, locale, absoluteDateStyle);
}

// ---------------------------------------------------------------------------
// Date range formatting
// ---------------------------------------------------------------------------

/**
 * Format a date range in a locale-aware manner.
 *
 * @example
 * formatDateRange(startDate, endDate, 'en-US', { dateStyle: 'medium' })
 * // → "Mar 15 – 20, 2024"
 *
 * formatDateRange(startDate, endDate, 'ja-JP', { dateStyle: 'long' })
 * // → "2024年3月15日～20日"
 */
export function formatDateRange(
  start: Date | number | string,
  end: Date | number | string,
  locale: string,
  options: Intl.DateTimeFormatOptions = { dateStyle: 'medium' }
): string {
  const s = toDate(start);
  const e = toDate(end);

  // Use formatRange if available (modern browsers)
  try {
    const fmt = new Intl.DateTimeFormat(locale, options);
    if ('formatRange' in fmt) {
      return (fmt as any).formatRange(s, e);
    }
  } catch {
    // Fall through to manual formatting
  }

  // Fallback: manual range
  const fmt = new Intl.DateTimeFormat(locale, options);
  return `${fmt.format(s)} – ${fmt.format(e)}`;
}

// ---------------------------------------------------------------------------
// Calendar system support
// ---------------------------------------------------------------------------

/**
 * Format a date using a specific calendar system.
 *
 * @example
 * formatWithCalendar(new Date(), 'fa-IR', 'persian')
 * // → "۱۴۰۳/۱/۲۶" (Persian Solar Hijri)
 *
 * formatWithCalendar(new Date(), 'th-TH', 'buddhist')
 * // → "15 มี.ค. 2567" (Buddhist Era)
 *
 * formatWithCalendar(new Date(), 'ja-JP', 'japanese')
 * // → "令和6年3月15日" (Japanese Imperial Era)
 */
export function formatWithCalendar(
  date: Date | number | string,
  locale: string,
  calendar: string,
  dateStyle: DateStyle = 'medium'
): string {
  const d = toDate(date);
  return new Intl.DateTimeFormat(locale, {
    dateStyle,
    calendar,
  } as Intl.DateTimeFormatOptions).format(d);
}

// ---------------------------------------------------------------------------
// Timezone utilities
// ---------------------------------------------------------------------------

/**
 * Get the current timezone offset description for a locale.
 *
 * @example
 * getTimezoneLabel('America/New_York', 'en-US')
 * // → "Eastern Daylight Time" or "GMT-4"
 */
export function getTimezoneLabel(timeZone: string, locale: string): string {
  const parts = new Intl.DateTimeFormat(locale, {
    timeZone,
    timeZoneName: 'long',
  }).formatToParts(new Date());

  return parts.find(p => p.type === 'timeZoneName')?.value ?? timeZone;
}

/**
 * Get the short timezone abbreviation.
 *
 * @example
 * getTimezoneAbbr('America/New_York', 'en-US')
 * // → "EDT"
 */
export function getTimezoneAbbr(timeZone: string, locale: string): string {
  const parts = new Intl.DateTimeFormat(locale, {
    timeZone,
    timeZoneName: 'short',
  }).formatToParts(new Date());

  return parts.find(p => p.type === 'timeZoneName')?.value ?? timeZone;
}

/**
 * Format a date in multiple timezones for display.
 *
 * @example
 * formatMultiTimezone(new Date(), 'en-US', ['America/New_York', 'Europe/London', 'Asia/Tokyo'])
 * // → [
 * //   { timezone: 'America/New_York', label: 'EDT', formatted: '2:30 PM' },
 * //   { timezone: 'Europe/London', label: 'BST', formatted: '7:30 PM' },
 * //   { timezone: 'Asia/Tokyo', label: 'JST', formatted: '3:30 AM' },
 * // ]
 */
export function formatMultiTimezone(
  date: Date | number | string,
  locale: string,
  timezones: string[]
): Array<{ timezone: string; label: string; formatted: string }> {
  const d = toDate(date);
  return timezones.map(tz => ({
    timezone: tz,
    label: getTimezoneAbbr(tz, locale),
    formatted: formatTimeOnly(d, locale, 'short', tz),
  }));
}

// ---------------------------------------------------------------------------
// Duration formatting
// ---------------------------------------------------------------------------

/**
 * Format a duration in a human-readable, locale-aware manner.
 * Uses Intl.DurationFormat if available, otherwise falls back to Intl.ListFormat.
 *
 * @example
 * formatDuration({ hours: 2, minutes: 30 }, 'en')
 * // → "2 hours, 30 minutes"
 *
 * formatDuration({ hours: 2, minutes: 30 }, 'ja')
 * // → "2時間、30分"
 */
export function formatDuration(
  duration: Partial<Record<TimeUnit, number>>,
  locale: string,
  style: 'long' | 'short' | 'narrow' = 'long'
): string {
  // Try Intl.DurationFormat (Stage 3 proposal, available in newer browsers)
  if ('DurationFormat' in Intl) {
    try {
      return new (Intl as any).DurationFormat(locale, { style }).format(duration);
    } catch {
      // Fall through to manual formatting
    }
  }

  // Manual fallback using NumberFormat with units
  const parts: string[] = [];
  const unitMap: Record<string, string> = {
    year: 'year', month: 'month', week: 'week',
    day: 'day', hour: 'hour', minute: 'minute', second: 'second',
  };

  for (const [unit, value] of Object.entries(duration)) {
    if (value && value > 0 && unit in unitMap) {
      try {
        const formatted = new Intl.NumberFormat(locale, {
          style: 'unit',
          unit: unitMap[unit],
          unitDisplay: style,
        } as Intl.NumberFormatOptions).format(value);
        parts.push(formatted);
      } catch {
        parts.push(`${value} ${unit}${value !== 1 ? 's' : ''}`);
      }
    }
  }

  // Join with locale-aware list format
  if (parts.length === 0) return '';
  try {
    return new Intl.ListFormat(locale, { style: 'long', type: 'conjunction' }).format(parts);
  } catch {
    return parts.join(', ');
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Normalize date input to a Date object. */
function toDate(input: Date | number | string): Date {
  if (input instanceof Date) return input;
  if (typeof input === 'number') return new Date(input);
  return new Date(input);
}

/**
 * Check if a date is today in the given timezone.
 */
export function isToday(date: Date | number | string, timeZone?: string): boolean {
  const d = toDate(date);
  const now = new Date();
  const opts: Intl.DateTimeFormatOptions = {
    year: 'numeric', month: '2-digit', day: '2-digit',
    ...(timeZone ? { timeZone } : {}),
  };
  const fmt = new Intl.DateTimeFormat('en-CA', opts); // en-CA gives YYYY-MM-DD
  return fmt.format(d) === fmt.format(now);
}

/**
 * Get the first day of the week for a locale (0 = Sunday, 1 = Monday, etc.).
 * Falls back to Sunday if Locale API is unavailable.
 */
export function getFirstDayOfWeek(locale: string): number {
  try {
    const localeObj = new Intl.Locale(locale);
    if ('weekInfo' in localeObj) {
      return (localeObj as any).weekInfo.firstDay % 7;
    }
  } catch {
    // Fallback
  }

  // Manual mapping for common locales
  const mondayFirst = ['de', 'fr', 'es', 'it', 'nl', 'pt', 'ru', 'pl', 'sv', 'nb', 'da', 'fi', 'ja', 'ko', 'zh'];
  const saturdayFirst = ['ar', 'fa', 'he'];
  const lang = locale.split('-')[0];

  if (saturdayFirst.includes(lang)) return 6;
  if (mondayFirst.includes(lang)) return 1;
  return 0; // Sunday (US, CA, etc.)
}
