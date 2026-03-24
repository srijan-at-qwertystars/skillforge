/**
 * Jest setup file — loaded via setupFilesAfterEnv in jest.config.ts.
 * Configures custom matchers, global settings, and test lifecycle hooks.
 */

// -- Testing Library matchers (React projects) --
// Adds toBeInTheDocument(), toHaveTextContent(), etc.
import '@testing-library/jest-dom';

// -- jest-extended (optional, install separately) --
// Adds toBeArray(), toStartWith(), toContainKey(), etc.
// import 'jest-extended/all';

// -- Custom Matchers --
expect.extend({
  /**
   * Assert a value is within a numeric range [floor, ceiling].
   * Usage: expect(100).toBeWithinRange(90, 110)
   */
  toBeWithinRange(received: number, floor: number, ceiling: number) {
    const pass = received >= floor && received <= ceiling;
    return {
      pass,
      message: () =>
        `expected ${received} ${pass ? 'not ' : ''}to be within range [${floor}, ${ceiling}]`,
    };
  },

  /**
   * Assert an async function resolves within a timeout.
   * Usage: await expect(fetchData()).toResolveWithin(1000)
   */
  async toResolveWithin(received: Promise<unknown>, timeoutMs: number) {
    const start = Date.now();
    try {
      await Promise.race([
        received,
        new Promise((_, reject) =>
          setTimeout(() => reject(new Error('timeout')), timeoutMs)
        ),
      ]);
      return {
        pass: true,
        message: () =>
          `expected promise not to resolve within ${timeoutMs}ms (resolved in ${Date.now() - start}ms)`,
      };
    } catch {
      return {
        pass: false,
        message: () =>
          `expected promise to resolve within ${timeoutMs}ms`,
      };
    }
  },

  /**
   * Assert a value is a valid ISO date string.
   * Usage: expect('2024-01-15T10:30:00Z').toBeISODateString()
   */
  toBeISODateString(received: string) {
    const isoRegex = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$/;
    const pass = typeof received === 'string' && isoRegex.test(received) && !isNaN(Date.parse(received));
    return {
      pass,
      message: () =>
        `expected "${received}" ${pass ? 'not ' : ''}to be a valid ISO date string`,
    };
  },
});

// -- TypeScript declarations for custom matchers --
declare module 'expect' {
  interface Matchers<R> {
    toBeWithinRange(floor: number, ceiling: number): R;
    toResolveWithin(timeoutMs: number): Promise<R>;
    toBeISODateString(): R;
  }
}

// -- Global test lifecycle --
afterEach(() => {
  // Ensure fake timers don't leak between tests
  try {
    jest.useRealTimers();
  } catch {
    // already using real timers
  }
});

// -- Suppress specific console noise in tests --
// Uncomment to silence noisy warnings during test runs:
// const originalWarn = console.warn;
// beforeAll(() => {
//   console.warn = (...args: unknown[]) => {
//     if (typeof args[0] === 'string' && args[0].includes('KNOWN_WARNING')) return;
//     originalWarn(...args);
//   };
// });
// afterAll(() => { console.warn = originalWarn; });

// -- Global test timeout --
// Override default 5s timeout for all tests in this setup
// jest.setTimeout(10_000);
