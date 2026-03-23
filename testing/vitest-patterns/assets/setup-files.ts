/**
 * Vitest global setup file.
 * Register in vitest.config.ts: setupFiles: ['./test/setup.ts']
 */
import { afterEach, expect, vi } from 'vitest';

// ─── Testing Library Integration ────────────────────────────────────────────
// Uncomment for DOM testing (requires @testing-library/jest-dom):
// import '@testing-library/jest-dom/vitest';

// Uncomment for React (requires @testing-library/react):
// import { cleanup } from '@testing-library/react';
// afterEach(() => cleanup());

// ─── Mock Restoration ───────────────────────────────────────────────────────
// Restore all mocks after each test to prevent leakage
afterEach(() => {
  vi.restoreAllMocks();
  vi.useRealTimers();
});

// ─── Custom Matchers ────────────────────────────────────────────────────────

expect.extend({
  /**
   * Assert a number is within an inclusive range.
   * Usage: expect(5).toBeWithinRange(1, 10)
   */
  toBeWithinRange(received: number, floor: number, ceiling: number) {
    const pass = received >= floor && received <= ceiling;
    return {
      pass,
      message: () =>
        pass
          ? `expected ${received} not to be within range ${floor}–${ceiling}`
          : `expected ${received} to be within range ${floor}–${ceiling}`,
    };
  },

  /**
   * Assert a value is a valid ISO 8601 date string.
   * Usage: expect(dateStr).toBeISODate()
   */
  toBeISODate(received: unknown) {
    const pass =
      typeof received === 'string' &&
      !isNaN(Date.parse(received)) &&
      /^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2}:\d{2})?/.test(received);
    return {
      pass,
      message: () =>
        pass
          ? `expected "${received}" not to be a valid ISO date`
          : `expected "${received}" to be a valid ISO date string`,
    };
  },

  /**
   * Assert an async function resolves within a time limit.
   * Usage: await expect(asyncFn()).toResolveWithin(1000)
   */
  async toResolveWithin(received: Promise<unknown>, ms: number) {
    const start = performance.now();
    try {
      await received;
      const elapsed = performance.now() - start;
      const pass = elapsed <= ms;
      return {
        pass,
        message: () =>
          pass
            ? `expected promise not to resolve within ${ms}ms (took ${elapsed.toFixed(1)}ms)`
            : `expected promise to resolve within ${ms}ms (took ${elapsed.toFixed(1)}ms)`,
      };
    } catch (error) {
      return {
        pass: false,
        message: () => `expected promise to resolve but it rejected: ${error}`,
      };
    }
  },
});

// ─── TypeScript Augmentation ────────────────────────────────────────────────
// Declare custom matcher types for TypeScript
declare module 'vitest' {
  interface Assertion<T = any> {
    toBeWithinRange(floor: number, ceiling: number): void;
    toBeISODate(): void;
    toResolveWithin(ms: number): Promise<void>;
  }
  interface AsymmetricMatchersContaining {
    toBeWithinRange(floor: number, ceiling: number): void;
    toBeISODate(): void;
  }
}

// ─── Global Stubs ───────────────────────────────────────────────────────────
// Stub browser APIs not available in Node/jsdom

// IntersectionObserver
if (typeof globalThis.IntersectionObserver === 'undefined') {
  vi.stubGlobal(
    'IntersectionObserver',
    vi.fn(() => ({
      disconnect: vi.fn(),
      observe: vi.fn(),
      unobserve: vi.fn(),
      takeRecords: vi.fn(() => []),
    }))
  );
}

// ResizeObserver
if (typeof globalThis.ResizeObserver === 'undefined') {
  vi.stubGlobal(
    'ResizeObserver',
    vi.fn(() => ({
      disconnect: vi.fn(),
      observe: vi.fn(),
      unobserve: vi.fn(),
    }))
  );
}

// matchMedia
if (typeof globalThis.matchMedia === 'undefined') {
  vi.stubGlobal(
    'matchMedia',
    vi.fn((query: string) => ({
      matches: false,
      media: query,
      onchange: null,
      addListener: vi.fn(),
      removeListener: vi.fn(),
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
      dispatchEvent: vi.fn(),
    }))
  );
}

// ─── Console Noise Suppression (Optional) ───────────────────────────────────
// Uncomment to suppress console.warn/error in tests (while still tracking calls):
// vi.spyOn(console, 'warn').mockImplementation(() => {});
// vi.spyOn(console, 'error').mockImplementation(() => {});
