/**
 * Next.js Security Headers Configuration
 *
 * Usage: Import into next.config.js/next.config.ts
 *
 * For static headers (no nonce), use the `headers()` config.
 * For nonce-based CSP, use the middleware approach below.
 */

import type { NextConfig } from 'next';

// ── Static Security Headers ─────────────────────────────────
// These headers don't change per request and can be set in next.config.js.
// CSP is handled separately via middleware for nonce support.

const securityHeaders = [
  {
    key: 'Strict-Transport-Security',
    value: 'max-age=31536000; includeSubDomains; preload',
  },
  {
    key: 'X-Content-Type-Options',
    value: 'nosniff',
  },
  {
    key: 'X-Frame-Options',
    value: 'DENY',
  },
  {
    key: 'Referrer-Policy',
    value: 'strict-origin-when-cross-origin',
  },
  {
    key: 'Permissions-Policy',
    value: 'camera=(), microphone=(), geolocation=(), payment=(), usb=()',
  },
  {
    key: 'X-DNS-Prefetch-Control',
    value: 'on',
  },
  {
    key: 'Cross-Origin-Opener-Policy',
    value: 'same-origin',
  },
  {
    key: 'Cross-Origin-Resource-Policy',
    value: 'same-origin',
  },
];

// ── Next.js Config ──────────────────────────────────────────

const nextConfig: NextConfig = {
  // Security: disable x-powered-by header
  poweredByHeader: false,

  async headers() {
    return [
      {
        // Apply to all routes
        source: '/(.*)',
        headers: securityHeaders,
      },
    ];
  },
};

export default nextConfig;

// ── CSP Middleware (for nonce-based CSP) ─────────────────────
// Save as middleware.ts in your project root.
//
// This middleware:
// 1. Generates a unique nonce per request
// 2. Sets a strict CSP header with the nonce
// 3. Passes the nonce via x-nonce header for use in Server Components

/*
// middleware.ts
import { NextResponse } from 'next/server';
import type { NextRequest } from 'next/server';

export function middleware(request: NextRequest) {
  const nonce = Buffer.from(crypto.randomUUID()).toString('base64');

  // Build CSP directives
  const cspDirectives = [
    // Fallback for all resource types
    "default-src 'self'",

    // JavaScript: nonce-based with strict-dynamic
    // https: and 'unsafe-inline' are backward-compat fallbacks
    `script-src 'self' 'nonce-${nonce}' 'strict-dynamic' https: 'unsafe-inline'`,

    // Styles: nonce-based
    `style-src 'self' 'nonce-${nonce}'`,

    // Images
    "img-src 'self' data: blob: https:",

    // Fonts
    "font-src 'self' https:",

    // API/fetch calls — add your API domains here
    "connect-src 'self'",

    // Iframes — block unless needed
    "frame-src 'none'",

    // Block plugins
    "object-src 'none'",

    // Block <base> injection
    "base-uri 'none'",

    // Block framing of this page
    "frame-ancestors 'none'",

    // Restrict form targets
    "form-action 'self'",

    // Upgrade HTTP to HTTPS
    "upgrade-insecure-requests",
  ];

  const csp = cspDirectives.join('; ');

  const response = NextResponse.next();

  // Set CSP header
  response.headers.set('Content-Security-Policy', csp);

  // Pass nonce to Server Components via custom header
  response.headers.set('x-nonce', nonce);

  return response;
}

export const config = {
  matcher: [
    // Match all routes except static files and API routes
    {
      source: '/((?!api|_next/static|_next/image|favicon.ico|sitemap.xml|robots.txt).*)',
      missing: [
        { type: 'header', key: 'next-router-prefetch' },
        { type: 'header', key: 'purpose', value: 'prefetch' },
      ],
    },
  ],
};
*/

// ── Using the Nonce in Server Components ────────────────────
//
// app/layout.tsx:
//
// import { headers } from 'next/headers';
// import Script from 'next/script';
//
// export default async function RootLayout({
//   children,
// }: {
//   children: React.ReactNode;
// }) {
//   const headersList = await headers();
//   const nonce = headersList.get('x-nonce') ?? '';
//
//   return (
//     <html lang="en">
//       <head>
//         {/* Pass nonce to any inline scripts */}
//         <Script nonce={nonce} strategy="beforeInteractive">
//           {`console.log('App loaded');`}
//         </Script>
//       </head>
//       <body>{children}</body>
//     </html>
//   );
// }

// ── Using the Nonce with styled-jsx ─────────────────────────
//
// In your component:
//
// import { headers } from 'next/headers';
//
// export default async function Page() {
//   const headersList = await headers();
//   const nonce = headersList.get('x-nonce') ?? '';
//
//   return (
//     <>
//       <style jsx nonce={nonce}>{`
//         .container { max-width: 1200px; margin: 0 auto; }
//       `}</style>
//       <div className="container">Content</div>
//     </>
//   );
// }
