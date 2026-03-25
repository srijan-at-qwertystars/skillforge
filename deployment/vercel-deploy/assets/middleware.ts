// =============================================================================
// Edge Middleware Template — middleware.ts
// =============================================================================
// Place at project root (Next.js). Runs on Vercel's Edge Network before
// requests reach your application. Supports: auth, geo-routing, A/B testing,
// rate limiting, redirects, security headers.
//
// Uncomment the patterns you need. Remove the rest.
// =============================================================================

import { NextResponse } from 'next/server';
import type { NextRequest } from 'next/server';

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

const PUBLIC_PATHS = [
  '/login',
  '/signup',
  '/api/auth',
  '/api/health',
  '/api/webhooks',
  '/_next',
  '/favicon.ico',
  '/robots.txt',
  '/sitemap.xml',
];

// const COUNTRY_LOCALE_MAP: Record<string, string> = {
//   DE: 'de', FR: 'fr', ES: 'es', JP: 'ja', BR: 'pt-BR',
// };

// ---------------------------------------------------------------------------
// Main Middleware
// ---------------------------------------------------------------------------

export async function middleware(request: NextRequest) {
  const { pathname } = request.nextUrl;

  // Skip public paths and static files
  if (PUBLIC_PATHS.some((p) => pathname.startsWith(p))) {
    return NextResponse.next();
  }

  // ---- Pattern 1: Security Headers ----
  const response = NextResponse.next();
  response.headers.set('X-Content-Type-Options', 'nosniff');
  response.headers.set('X-Frame-Options', 'DENY');
  response.headers.set('X-XSS-Protection', '1; mode=block');
  response.headers.set('Referrer-Policy', 'strict-origin-when-cross-origin');
  response.headers.set(
    'Permissions-Policy',
    'camera=(), microphone=(), geolocation=()',
  );

  // ---- Pattern 2: Authentication (uncomment to enable) ----
  // const token = request.cookies.get('auth-token')?.value;
  // if (!token) {
  //   const loginUrl = new URL('/login', request.url);
  //   loginUrl.searchParams.set('callbackUrl', pathname);
  //   return NextResponse.redirect(loginUrl);
  // }
  //
  // // JWT verification (install 'jose': npm i jose)
  // // import { jwtVerify } from 'jose';
  // // const secret = new TextEncoder().encode(process.env.JWT_SECRET!);
  // // try {
  // //   const { payload } = await jwtVerify(token, secret);
  // //   response.headers.set('x-user-id', payload.sub as string);
  // // } catch {
  // //   const res = NextResponse.redirect(new URL('/login', request.url));
  // //   res.cookies.delete('auth-token');
  // //   return res;
  // // }

  // ---- Pattern 3: Geo-Routing (uncomment to enable) ----
  // const country = request.geo?.country || 'US';
  // const locale = COUNTRY_LOCALE_MAP[country] || 'en';
  // if (!pathname.startsWith(`/${locale}`) && !pathname.startsWith('/api')) {
  //   const url = request.nextUrl.clone();
  //   url.pathname = `/${locale}${pathname}`;
  //   return NextResponse.rewrite(url);
  // }

  // ---- Pattern 4: A/B Testing (uncomment to enable) ----
  // const experimentCookie = 'exp-homepage';
  // let variant = request.cookies.get(experimentCookie)?.value;
  // if (!variant) {
  //   variant = Math.random() < 0.5 ? 'control' : 'variant';
  //   response.cookies.set(experimentCookie, variant, {
  //     maxAge: 60 * 60 * 24 * 30, // 30 days
  //     httpOnly: true,
  //     sameSite: 'lax',
  //   });
  // }
  // response.headers.set('x-experiment-variant', variant);
  //
  // // Rewrite to variant page
  // if (pathname === '/' && variant === 'variant') {
  //   return NextResponse.rewrite(new URL('/home-variant', request.url));
  // }

  // ---- Pattern 5: Maintenance Mode (uncomment to enable) ----
  // Use with Edge Config for dynamic control:
  //   import { get } from '@vercel/edge-config';
  //   const maintenance = await get<boolean>('maintenance');
  // Or use a simple env var:
  // if (process.env.MAINTENANCE_MODE === 'true') {
  //   if (!pathname.startsWith('/api/health') && pathname !== '/maintenance') {
  //     return NextResponse.rewrite(new URL('/maintenance', request.url));
  //   }
  // }

  // ---- Pattern 6: Bot Protection (uncomment to enable) ----
  // const userAgent = request.headers.get('user-agent') || '';
  // if (pathname.startsWith('/api/') && !pathname.startsWith('/api/webhooks')) {
  //   if (!userAgent || /bot|crawler|spider|curl|wget|python-requests/i.test(userAgent)) {
  //     return NextResponse.json({ error: 'Forbidden' }, { status: 403 });
  //   }
  // }

  // ---- Pattern 7: Rate Limiting with Upstash (uncomment to enable) ----
  // Requires: npm i @upstash/ratelimit @upstash/redis
  //
  // import { Ratelimit } from '@upstash/ratelimit';
  // import { Redis } from '@upstash/redis';
  // import { ipAddress } from '@vercel/functions';
  //
  // const ratelimit = new Ratelimit({
  //   redis: Redis.fromEnv(),
  //   limiter: Ratelimit.slidingWindow(100, '1 m'),
  // });
  //
  // if (pathname.startsWith('/api/')) {
  //   const ip = ipAddress(request) || '127.0.0.1';
  //   const { success, limit, remaining, reset } = await ratelimit.limit(ip);
  //   if (!success) {
  //     return NextResponse.json({ error: 'Rate limited' }, {
  //       status: 429,
  //       headers: {
  //         'X-RateLimit-Limit': limit.toString(),
  //         'X-RateLimit-Remaining': remaining.toString(),
  //         'X-RateLimit-Reset': reset.toString(),
  //         'Retry-After': Math.ceil((reset - Date.now()) / 1000).toString(),
  //       },
  //     });
  //   }
  //   response.headers.set('X-RateLimit-Limit', limit.toString());
  //   response.headers.set('X-RateLimit-Remaining', remaining.toString());
  // }

  // ---- Pattern 8: Multi-Tenant Routing (uncomment to enable) ----
  // const hostname = request.headers.get('host') || '';
  // const subdomain = hostname.split('.')[0];
  // if (!['www', 'app', 'api', 'localhost:3000'].includes(subdomain)) {
  //   const url = request.nextUrl.clone();
  //   url.pathname = `/tenants/${subdomain}${pathname}`;
  //   return NextResponse.rewrite(url);
  // }

  return response;
}

// ---------------------------------------------------------------------------
// Matcher Configuration
// ---------------------------------------------------------------------------
// Define which routes middleware applies to.
// Excluding static files and images for performance.
export const config = {
  matcher: [
    /*
     * Match all request paths except:
     * - _next/static (static files)
     * - _next/image (image optimization files)
     * - favicon.ico (browser icon)
     * - public folder assets
     */
    '/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp|ico)$).*)',
  ],
};
