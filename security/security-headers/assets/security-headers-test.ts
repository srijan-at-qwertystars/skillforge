/**
 * Security Headers Test Suite
 *
 * Verifies all recommended security headers are correctly set
 * on HTTP responses from your application.
 *
 * Compatible with Jest and Vitest (uses standard describe/it/expect).
 *
 * Usage with supertest:
 *   npm install --save-dev supertest @types/supertest
 *   // Import your Express app and run these tests
 *
 * Usage with fetch (for external URL testing):
 *   Set TEST_URL environment variable to your app's URL
 *   TEST_URL=https://staging.example.com npx vitest run
 */

import { describe, it, expect, beforeAll } from 'vitest';

// ── Configuration ───────────────────────────────────────────
// Choose ONE of these approaches:

// Option A: Test with supertest against your Express app
// import request from 'supertest';
// import app from '../src/app';

// Option B: Test against a running server URL
const TEST_URL = process.env.TEST_URL || 'http://localhost:3000';

// ── Helper ──────────────────────────────────────────────────

interface HeaderMap {
  [key: string]: string | undefined;
}

let headers: HeaderMap = {};

async function fetchHeaders(url: string, path = '/'): Promise<HeaderMap> {
  const response = await fetch(`${url}${path}`, {
    method: 'GET',
    redirect: 'follow',
  });

  const result: HeaderMap = {};
  response.headers.forEach((value, key) => {
    result[key.toLowerCase()] = value;
  });

  // Consume body to close connection
  await response.text();

  return result;
}

// ── Setup ───────────────────────────────────────────────────

beforeAll(async () => {
  headers = await fetchHeaders(TEST_URL);
});

// ── Tests ───────────────────────────────────────────────────

describe('Security Headers', () => {
  // ── Content-Security-Policy ─────────────────────────────

  describe('Content-Security-Policy', () => {
    it('should be present', () => {
      const csp =
        headers['content-security-policy'] ||
        headers['content-security-policy-report-only'];
      expect(csp).toBeDefined();
    });

    it('should include default-src directive', () => {
      const csp = headers['content-security-policy'] || '';
      expect(csp).toMatch(/default-src\s/);
    });

    it('should set object-src to none', () => {
      const csp = headers['content-security-policy'] || '';
      expect(csp).toMatch(/object-src\s+'none'/);
    });

    it('should set base-uri to none or self', () => {
      const csp = headers['content-security-policy'] || '';
      expect(csp).toMatch(/base-uri\s+'(none|self)'/);
    });

    it('should not contain unsafe-inline in script-src without nonce/strict-dynamic', () => {
      const csp = headers['content-security-policy'] || '';
      const scriptSrc = csp.match(/script-src\s+([^;]+)/)?.[1] || '';

      if (scriptSrc.includes("'unsafe-inline'")) {
        // unsafe-inline is acceptable ONLY as a fallback alongside nonce or strict-dynamic
        expect(
          scriptSrc.includes("'nonce-") || scriptSrc.includes("'strict-dynamic'")
        ).toBe(true);
      }
    });

    it('should not contain unsafe-eval', () => {
      const csp = headers['content-security-policy'] || '';
      expect(csp).not.toMatch(/(?<!')unsafe-eval(?!')/);
      // Allow 'wasm-unsafe-eval' which is fine
      if (csp.includes("'unsafe-eval'")) {
        // Fail — unsafe-eval should not be in CSP
        expect(csp).not.toContain("'unsafe-eval'");
      }
    });

    it('should include frame-ancestors directive', () => {
      const csp = headers['content-security-policy'] || '';
      expect(csp).toMatch(/frame-ancestors\s/);
    });

    it('should not use wildcard in script-src', () => {
      const csp = headers['content-security-policy'] || '';
      const scriptSrc = csp.match(/script-src\s+([^;]+)/)?.[1] || '';
      // script-src should not contain bare * or http://*
      expect(scriptSrc).not.toMatch(/(?:^|\s)\*(?:\s|$)/);
    });
  });

  // ── Strict-Transport-Security ───────────────────────────

  describe('Strict-Transport-Security', () => {
    it('should be present', () => {
      expect(headers['strict-transport-security']).toBeDefined();
    });

    it('should have max-age of at least 1 year', () => {
      const hsts = headers['strict-transport-security'] || '';
      const maxAge = parseInt(hsts.match(/max-age=(\d+)/)?.[1] || '0', 10);
      expect(maxAge).toBeGreaterThanOrEqual(31536000);
    });

    it('should include includeSubDomains', () => {
      const hsts = headers['strict-transport-security'] || '';
      expect(hsts.toLowerCase()).toContain('includesubdomains');
    });

    it('should include preload (if submitting to preload list)', () => {
      const hsts = headers['strict-transport-security'] || '';
      expect(hsts.toLowerCase()).toContain('preload');
    });
  });

  // ── X-Content-Type-Options ──────────────────────────────

  describe('X-Content-Type-Options', () => {
    it('should be set to nosniff', () => {
      expect(headers['x-content-type-options']?.toLowerCase()).toBe('nosniff');
    });
  });

  // ── X-Frame-Options ────────────────────────────────────

  describe('X-Frame-Options', () => {
    it('should be present', () => {
      expect(headers['x-frame-options']).toBeDefined();
    });

    it('should be DENY or SAMEORIGIN', () => {
      const xfo = headers['x-frame-options']?.toUpperCase() || '';
      expect(['DENY', 'SAMEORIGIN']).toContain(xfo);
    });
  });

  // ── Referrer-Policy ─────────────────────────────────────

  describe('Referrer-Policy', () => {
    it('should be present', () => {
      expect(headers['referrer-policy']).toBeDefined();
    });

    it('should use a secure policy', () => {
      const policy = headers['referrer-policy']?.toLowerCase() || '';
      const securePolicies = [
        'no-referrer',
        'strict-origin',
        'strict-origin-when-cross-origin',
        'same-origin',
        'origin',
        'origin-when-cross-origin',
      ];
      expect(securePolicies.some((p) => policy.includes(p))).toBe(true);
    });

    it('should not use unsafe-url', () => {
      const policy = headers['referrer-policy']?.toLowerCase() || '';
      expect(policy).not.toBe('unsafe-url');
    });
  });

  // ── Permissions-Policy ──────────────────────────────────

  describe('Permissions-Policy', () => {
    it('should be present', () => {
      expect(headers['permissions-policy']).toBeDefined();
    });

    it('should restrict camera', () => {
      const policy = headers['permissions-policy'] || '';
      expect(policy).toMatch(/camera=\(\)/);
    });

    it('should restrict microphone', () => {
      const policy = headers['permissions-policy'] || '';
      expect(policy).toMatch(/microphone=\(\)/);
    });

    it('should restrict geolocation', () => {
      const policy = headers['permissions-policy'] || '';
      expect(policy).toMatch(/geolocation=\(\)/);
    });
  });

  // ── Cross-Origin Headers ────────────────────────────────

  describe('Cross-Origin-Opener-Policy', () => {
    it('should be present', () => {
      expect(headers['cross-origin-opener-policy']).toBeDefined();
    });

    it('should be same-origin or same-origin-allow-popups', () => {
      const coop = headers['cross-origin-opener-policy']?.toLowerCase() || '';
      expect(['same-origin', 'same-origin-allow-popups']).toContain(coop);
    });
  });

  describe('Cross-Origin-Resource-Policy', () => {
    it('should be present', () => {
      expect(headers['cross-origin-resource-policy']).toBeDefined();
    });

    it('should be same-origin or same-site', () => {
      const corp = headers['cross-origin-resource-policy']?.toLowerCase() || '';
      expect(['same-origin', 'same-site']).toContain(corp);
    });
  });

  // ── Information Disclosure ──────────────────────────────

  describe('Information Disclosure Prevention', () => {
    it('should not expose X-Powered-By', () => {
      expect(headers['x-powered-by']).toBeUndefined();
    });

    it('should not expose detailed Server version', () => {
      const server = headers['server'] || '';
      // Server header should not contain version numbers
      // e.g., "nginx/1.21.0" or "Apache/2.4.51"
      expect(server).not.toMatch(/\/\d+\.\d+/);
    });
  });

  // ── Cookie Security (test authenticated endpoints) ──────

  describe('Cookie Security', () => {
    it('should set Secure flag on session cookies', async () => {
      // This test requires an endpoint that sets cookies
      // Adjust the path to an endpoint that sets a session cookie
      const cookieHeaders = await fetchHeaders(TEST_URL, '/');
      const setCookie = cookieHeaders['set-cookie'] || '';

      if (setCookie) {
        // If cookies are being set, they should have Secure flag
        // (skip if no cookies are set on this endpoint)
        const cookies = setCookie.split(',').map((c) => c.trim().toLowerCase());
        for (const cookie of cookies) {
          if (cookie.includes('session') || cookie.includes('token')) {
            expect(cookie).toContain('secure');
            expect(cookie).toContain('httponly');
            expect(cookie).toMatch(/samesite=(strict|lax)/);
          }
        }
      }
    });
  });
});

// ── Additional Test Utilities ───────────────────────────────

/**
 * Test security headers for multiple routes.
 * Useful for ensuring headers are consistent across your application.
 */
export async function auditRoutes(
  baseUrl: string,
  paths: string[]
): Promise<{ path: string; missing: string[] }[]> {
  const requiredHeaders = [
    'content-security-policy',
    'strict-transport-security',
    'x-content-type-options',
    'x-frame-options',
    'referrer-policy',
    'permissions-policy',
  ];

  const results: { path: string; missing: string[] }[] = [];

  for (const path of paths) {
    const h = await fetchHeaders(baseUrl, path);
    const missing = requiredHeaders.filter((name) => !h[name]);
    results.push({ path, missing });
  }

  return results;
}
