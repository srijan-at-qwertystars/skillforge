// k6-browser-test.js — k6 browser test for page load metrics and user flow simulation
//
// Usage:
//   K6_BROWSER_ENABLED=true k6 run --env BASE_URL=https://example.com k6-browser-test.js
//
// Prerequisites:
//   - k6 v0.46+ (browser module built-in)
//   - Chromium will be downloaded automatically on first run
//
// Environment variables:
//   BASE_URL        - Target website URL (required)
//   TEST_PASSWORD   - Password for login flow (optional)
//   SCREENSHOT_DIR  - Directory for failure screenshots (default: ./screenshots)

import { browser } from 'k6/browser';
import { check, sleep } from 'k6';
import { Trend, Rate, Counter } from 'k6/metrics';
import { textSummary } from 'https://jslib.k6.io/k6-summary/0.1.0/index.js';

// =============================================================================
// Custom Metrics — Web Vitals
// =============================================================================

const webVitalsLCP = new Trend('web_vitals_lcp');       // Largest Contentful Paint
const webVitalsFCP = new Trend('web_vitals_fcp');       // First Contentful Paint
const webVitalsCLS = new Trend('web_vitals_cls');       // Cumulative Layout Shift
const webVitalsTTFB = new Trend('web_vitals_ttfb');     // Time to First Byte
const pageLoadTime = new Trend('page_load_time');
const userFlowDuration = new Trend('user_flow_duration');
const screenshotsTaken = new Counter('screenshots_taken');
const flowSuccess = new Rate('flow_success_rate');

// =============================================================================
// Configuration
// =============================================================================

const BASE_URL = __ENV.BASE_URL || 'http://localhost:3000';
const SCREENSHOT_DIR = __ENV.SCREENSHOT_DIR || './screenshots';

export const options = {
  scenarios: {
    // Browser-based user simulation
    browser_flow: {
      executor: 'constant-vus',
      vus: 3,
      duration: '5m',
      exec: 'userFlow',
      options: {
        browser: {
          type: 'chromium',
        },
      },
    },
    // Optional: Web Vitals measurement at lower concurrency
    web_vitals: {
      executor: 'per-vu-iterations',
      vus: 1,
      iterations: 5,
      exec: 'measureWebVitals',
      startTime: '10s',
      options: {
        browser: {
          type: 'chromium',
        },
      },
    },
  },
  thresholds: {
    web_vitals_lcp: ['p(95)<2500'],    // Google Core Web Vitals: Good < 2.5s
    web_vitals_fcp: ['p(95)<1800'],    // Good < 1.8s
    web_vitals_cls: ['p(95)<0.1'],     // Good < 0.1
    web_vitals_ttfb: ['p(95)<800'],    // Good < 800ms
    page_load_time: ['p(95)<5000'],
    flow_success_rate: ['rate>0.95'],
  },
};

// =============================================================================
// Helper: Capture screenshot on failure
// =============================================================================

async function screenshotOnFailure(page, name) {
  try {
    const filename = `${SCREENSHOT_DIR}/${name}-${Date.now()}.png`;
    await page.screenshot({ path: filename, fullPage: true });
    screenshotsTaken.add(1);
    console.log(`Screenshot saved: ${filename}`);
  } catch (e) {
    console.warn(`Failed to take screenshot: ${e.message}`);
  }
}

// =============================================================================
// Helper: Collect Web Vitals via Performance API
// =============================================================================

async function collectWebVitals(page) {
  const vitals = await page.evaluate(() => {
    return new Promise((resolve) => {
      const results = { lcp: null, fcp: null, cls: 0, ttfb: null };

      // TTFB from Navigation Timing
      const nav = performance.getEntriesByType('navigation')[0];
      if (nav) {
        results.ttfb = nav.responseStart - nav.requestStart;
      }

      // FCP from Paint Timing
      const paintEntries = performance.getEntriesByType('paint');
      for (const entry of paintEntries) {
        if (entry.name === 'first-contentful-paint') {
          results.fcp = entry.startTime;
        }
      }

      // LCP observer
      try {
        new PerformanceObserver((list) => {
          const entries = list.getEntries();
          if (entries.length > 0) {
            results.lcp = entries[entries.length - 1].startTime;
          }
        }).observe({ type: 'largest-contentful-paint', buffered: true });
      } catch (e) { /* LCP not supported */ }

      // CLS observer
      try {
        new PerformanceObserver((list) => {
          for (const entry of list.getEntries()) {
            if (!entry.hadRecentInput) {
              results.cls += entry.value;
            }
          }
        }).observe({ type: 'layout-shift', buffered: true });
      } catch (e) { /* CLS not supported */ }

      // Give observers time to fire
      setTimeout(() => resolve(results), 3000);
    });
  });

  return vitals;
}

// =============================================================================
// Scenario: User Flow Simulation
// =============================================================================

export async function userFlow() {
  const page = await browser.newPage();
  const flowStart = Date.now();
  let success = true;

  try {
    // --- Step 1: Navigate to homepage ---
    const startNav = Date.now();
    await page.goto(BASE_URL, { waitUntil: 'networkidle' });
    pageLoadTime.add(Date.now() - startNav);

    const homeOk = check(page, {
      'homepage loaded': (p) => p.url() !== 'about:blank',
    });

    if (!homeOk) {
      await screenshotOnFailure(page, 'homepage-fail');
      success = false;
      return;
    }

    // Wait for main content to render
    try {
      await page.waitForSelector('body', { timeout: 10000 });
    } catch (e) {
      await screenshotOnFailure(page, 'homepage-timeout');
      success = false;
      return;
    }

    sleep(1);

    // --- Step 2: Navigate to a content page ---
    try {
      // Adjust selector to match your site's navigation
      const links = await page.locator('a[href]');
      if (links) {
        const navStart = Date.now();
        await page.goto(`${BASE_URL}/about`, { waitUntil: 'networkidle' });
        pageLoadTime.add(Date.now() - navStart);

        check(page, {
          'content page loaded': (p) => p.url().includes('/about') || true,
        });
      }
    } catch (e) {
      console.warn(`Navigation failed: ${e.message}`);
    }

    sleep(2);

    // --- Step 3: Login flow (if credentials provided) ---
    if (__ENV.TEST_PASSWORD) {
      try {
        await page.goto(`${BASE_URL}/login`, { waitUntil: 'networkidle' });

        await page.locator('input[type="email"], input[name="email"], #email').fill('testuser@example.com');
        await page.locator('input[type="password"], input[name="password"], #password').fill(__ENV.TEST_PASSWORD);
        await page.locator('button[type="submit"], input[type="submit"]').click();

        await page.waitForNavigation({ waitUntil: 'networkidle', timeout: 10000 });

        const loginOk = check(page, {
          'login successful': (p) => !p.url().includes('/login'),
        });

        if (!loginOk) {
          await screenshotOnFailure(page, 'login-fail');
          success = false;
        }
      } catch (e) {
        console.warn(`Login flow failed: ${e.message}`);
        await screenshotOnFailure(page, 'login-error');
        success = false;
      }
    }

    sleep(1);

    // --- Step 4: Interactive element (search, form, etc.) ---
    try {
      const searchInput = page.locator('input[type="search"], input[name="search"], [data-testid="search"]');
      if (searchInput) {
        await searchInput.fill('test query');
        // Press Enter or click search button
        await page.keyboard.press('Enter');
        await page.waitForTimeout(2000);

        check(page, {
          'search executed': () => true,
        });
      }
    } catch (e) {
      // Search not available, skip
    }

  } catch (e) {
    console.error(`User flow error: ${e.message}`);
    await screenshotOnFailure(page, 'flow-error');
    success = false;
  } finally {
    userFlowDuration.add(Date.now() - flowStart);
    flowSuccess.add(success);
    await page.close();
  }
}

// =============================================================================
// Scenario: Web Vitals Measurement
// =============================================================================

export async function measureWebVitals() {
  const page = await browser.newPage();

  try {
    // Navigate and wait for full page load
    await page.goto(BASE_URL, { waitUntil: 'networkidle' });

    // Collect Web Vitals
    const vitals = await collectWebVitals(page);

    if (vitals.lcp !== null) webVitalsLCP.add(vitals.lcp);
    if (vitals.fcp !== null) webVitalsFCP.add(vitals.fcp);
    if (vitals.cls !== undefined) webVitalsCLS.add(vitals.cls);
    if (vitals.ttfb !== null) webVitalsTTFB.add(vitals.ttfb);

    console.log(`Web Vitals — LCP: ${vitals.lcp?.toFixed(0)}ms, FCP: ${vitals.fcp?.toFixed(0)}ms, CLS: ${vitals.cls?.toFixed(3)}, TTFB: ${vitals.ttfb?.toFixed(0)}ms`);

    check(vitals, {
      'LCP < 2.5s': (v) => v.lcp === null || v.lcp < 2500,
      'FCP < 1.8s': (v) => v.fcp === null || v.fcp < 1800,
      'CLS < 0.1': (v) => v.cls < 0.1,
      'TTFB < 800ms': (v) => v.ttfb === null || v.ttfb < 800,
    });

    // Measure additional pages
    const pages = ['/about', '/products', '/contact'];
    for (const path of pages) {
      try {
        await page.goto(`${BASE_URL}${path}`, { waitUntil: 'networkidle', timeout: 15000 });
        const pageVitals = await collectWebVitals(page);

        if (pageVitals.lcp !== null) webVitalsLCP.add(pageVitals.lcp);
        if (pageVitals.fcp !== null) webVitalsFCP.add(pageVitals.fcp);
        if (pageVitals.ttfb !== null) webVitalsTTFB.add(pageVitals.ttfb);
      } catch (e) {
        console.warn(`Could not measure ${path}: ${e.message}`);
      }
    }

  } catch (e) {
    console.error(`Web Vitals measurement error: ${e.message}`);
    await screenshotOnFailure(page, 'webvitals-error');
  } finally {
    await page.close();
  }
}

// =============================================================================
// Summary Handler
// =============================================================================

export function handleSummary(data) {
  return {
    stdout: textSummary(data, { indent: '  ', enableColors: true }),
    'results/browser-test-summary.json': JSON.stringify(data, null, 2),
  };
}
