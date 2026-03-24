/**
 * Complete Helmet.js Security Headers Configuration
 *
 * Install: npm install helmet
 * Usage: Import and apply as Express middleware
 *
 * This configuration sets ALL recommended security headers
 * with a strict, production-ready baseline.
 */

import helmet from 'helmet';
import crypto from 'node:crypto';
import type { Request, Response, NextFunction, RequestHandler } from 'express';

declare module 'express-serve-static-core' {
  interface Locals {
    cspNonce: string;
  }
}

/**
 * Middleware to generate a unique CSP nonce per request.
 * Must be applied BEFORE the Helmet middleware.
 */
export function cspNonceMiddleware(req: Request, res: Response, next: NextFunction): void {
  res.locals.cspNonce = crypto.randomBytes(16).toString('base64');
  next();
}

/**
 * Creates Helmet middleware configured with all security headers.
 *
 * Headers set:
 * - Content-Security-Policy (nonce-based with strict-dynamic)
 * - Strict-Transport-Security (1 year, includeSubDomains, preload)
 * - X-Content-Type-Options: nosniff
 * - X-Frame-Options: DENY
 * - Referrer-Policy: strict-origin-when-cross-origin
 * - Cross-Origin-Opener-Policy: same-origin
 * - Cross-Origin-Resource-Policy: same-origin
 * - Cross-Origin-Embedder-Policy: require-corp
 * - X-DNS-Prefetch-Control: off
 * - X-Download-Options: noopen
 * - X-Permitted-Cross-Domain-Policies: none
 *
 * @param options - Override default configuration
 */
export function createHelmetMiddleware(options?: {
  /** Additional script-src sources */
  scriptSrc?: string[];
  /** Additional style-src sources */
  styleSrc?: string[];
  /** Additional connect-src sources (API domains) */
  connectSrc?: string[];
  /** Additional img-src sources */
  imgSrc?: string[];
  /** Additional font-src sources */
  fontSrc?: string[];
  /** Additional frame-src sources (iframe embeds) */
  frameSrc?: string[];
  /** frame-ancestors value (who can embed your page) */
  frameAncestors?: string[];
  /** Deploy CSP in report-only mode */
  reportOnly?: boolean;
  /** CSP report endpoint URI */
  reportUri?: string;
  /** HSTS max-age in seconds (default: 31536000 = 1 year) */
  hstsMaxAge?: number;
  /** Cross-Origin-Embedder-Policy (default: require-corp) */
  coep?: 'require-corp' | 'credentialless' | 'unsafe-none';
  /** Cross-Origin-Opener-Policy (default: same-origin) */
  coop?: 'same-origin' | 'same-origin-allow-popups' | 'unsafe-none';
}): RequestHandler {
  const opts = options ?? {};

  return (req: Request, res: Response, next: NextFunction): void => {
    const nonce = res.locals.cspNonce;

    if (!nonce) {
      throw new Error(
        'cspNonce not found on res.locals. Apply cspNonceMiddleware before createHelmetMiddleware.'
      );
    }

    const directives: Record<string, string[] | boolean> = {
      // Fallback for all fetch directives
      defaultSrc: ["'self'"],

      // JavaScript: nonce-based with strict-dynamic
      // https: and 'unsafe-inline' are backward-compatibility fallbacks
      // (ignored by browsers that support strict-dynamic)
      scriptSrc: [
        "'self'",
        `'nonce-${nonce}'`,
        "'strict-dynamic'",
        'https:',
        "'unsafe-inline'",
        ...(opts.scriptSrc ?? []),
      ],

      // Block inline event handlers (onclick, etc.)
      scriptSrcAttr: ["'none'"],

      // Styles: nonce-based
      styleSrc: ["'self'", `'nonce-${nonce}'`, ...(opts.styleSrc ?? [])],

      // Images: self + data URIs (for inline images, favicons)
      imgSrc: ["'self'", 'data:', ...(opts.imgSrc ?? [])],

      // Fonts
      fontSrc: ["'self'", ...(opts.fontSrc ?? [])],

      // XHR, fetch, WebSocket, EventSource
      connectSrc: ["'self'", ...(opts.connectSrc ?? [])],

      // Audio/video
      mediaSrc: ["'self'"],

      // Plugins: block all (Flash, Java applets)
      objectSrc: ["'none'"],

      // Iframes embedded in your page
      frameSrc: opts.frameSrc?.length ? opts.frameSrc : ["'none'"],

      // Web Workers
      workerSrc: ["'self'"],

      // Who can embed YOUR page in an iframe
      frameAncestors: opts.frameAncestors ?? ["'none'"],

      // Form submission targets
      formAction: ["'self'"],

      // Block <base> tag injection
      baseUri: ["'none'"],

      // Web app manifest
      manifestSrc: ["'self'"],

      // Upgrade HTTP requests to HTTPS
      upgradeInsecureRequests: [],
    };

    // Add report-uri if configured
    if (opts.reportUri) {
      directives.reportUri = [opts.reportUri];
    }

    helmet({
      contentSecurityPolicy: {
        directives,
        reportOnly: opts.reportOnly ?? false,
      },

      // HSTS: force HTTPS
      strictTransportSecurity: {
        maxAge: opts.hstsMaxAge ?? 31536000,
        includeSubDomains: true,
        preload: true,
      },

      // Prevent MIME-type sniffing
      xContentTypeOptions: true,

      // Clickjacking protection (backup for frame-ancestors)
      xFrameOptions: { action: 'deny' },

      // Control referrer information leakage
      referrerPolicy: {
        policy: 'strict-origin-when-cross-origin',
      },

      // DNS prefetch control
      xDnsPrefetchControl: { allow: false },

      // IE download options
      xDownloadOptions: true,

      // Adobe cross-domain policies
      xPermittedCrossDomainPolicies: { permittedPolicies: 'none' },

      // Cross-origin isolation headers
      crossOriginEmbedderPolicy: {
        policy: opts.coep ?? 'require-corp',
      },
      crossOriginOpenerPolicy: {
        policy: opts.coop ?? 'same-origin',
      },
      crossOriginResourcePolicy: {
        policy: 'same-origin',
      },
    })(req, res, next);
  };
}

/**
 * Middleware to set Permissions-Policy header.
 * Helmet does not set this, so it must be added separately.
 */
export function permissionsPolicyMiddleware(
  overrides?: Partial<Record<string, string[]>>
): RequestHandler {
  const defaults: Record<string, string[]> = {
    camera: [],
    microphone: [],
    geolocation: [],
    payment: [],
    usb: [],
    magnetometer: [],
    gyroscope: [],
    accelerometer: [],
    'display-capture': [],
    'document-domain': [],
    'encrypted-media': ['self'],
    fullscreen: ['self'],
    'picture-in-picture': ['self'],
  };

  const policies = { ...defaults, ...overrides };
  const headerValue = Object.entries(policies)
    .map(([feature, allowlist]) => {
      if (allowlist.length === 0) return `${feature}=()`;
      const sources = allowlist.map(s => (s === 'self' ? 'self' : `"${s}"`)).join(' ');
      return `${feature}=(${sources})`;
    })
    .join(', ');

  return (_req: Request, res: Response, next: NextFunction): void => {
    res.setHeader('Permissions-Policy', headerValue);
    next();
  };
}

/* ────────────────────────────────────────────────────────────
 * Usage Example:
 *
 * import express from 'express';
 * import {
 *   cspNonceMiddleware,
 *   createHelmetMiddleware,
 *   permissionsPolicyMiddleware
 * } from './helmet-config';
 *
 * const app = express();
 *
 * // 1. Generate nonce per request
 * app.use(cspNonceMiddleware);
 *
 * // 2. Apply Helmet with all security headers
 * app.use(createHelmetMiddleware({
 *   connectSrc: ['https://api.example.com'],
 *   imgSrc: ['https://images.example.com'],
 *   reportUri: '/csp-report',
 *   // reportOnly: true,  // Enable for testing
 * }));
 *
 * // 3. Apply Permissions-Policy
 * app.use(permissionsPolicyMiddleware());
 *
 * // 4. Access nonce in routes for templates
 * app.get('/', (req, res) => {
 *   res.render('index', { nonce: res.locals.cspNonce });
 * });
 *
 * ──────────────────────────────────────────────────────────── */
