/**
 * middleware.ts — Next.js Middleware for Supabase Auth (App Router SSR Pattern)
 *
 * This middleware handles:
 *   1. Refreshing expired auth tokens on every request (keeps sessions alive)
 *   2. Protecting routes that require authentication
 *   3. Redirecting authenticated users away from auth pages (login/signup)
 *
 * How it works:
 *   - Next.js runs this middleware on every matched request BEFORE rendering
 *   - We create a Supabase client that reads/writes auth cookies
 *   - Calling `getUser()` triggers a token refresh if the session is near expiry
 *   - Updated cookies are forwarded to the browser via the response headers
 *
 * Setup:
 *   Place this file at the root of your project (next to app/ or src/).
 *   Set NEXT_PUBLIC_SUPABASE_URL and NEXT_PUBLIC_SUPABASE_ANON_KEY in .env.local.
 *
 * @see https://supabase.com/docs/guides/auth/server-side/nextjs
 */

import { type NextRequest, NextResponse } from "next/server";
import { createServerClient } from "@supabase/ssr";

// ---------------------------------------------------------------------------
// Route Configuration
// ---------------------------------------------------------------------------

/**
 * Routes that do NOT require authentication.
 * All other routes matched by the `config.matcher` will require a valid session.
 */
const PUBLIC_ROUTES: string[] = [
  "/",
  "/login",
  "/signup",
  "/auth/callback",
  "/auth/confirm",
  "/forgot-password",
  "/reset-password",
  "/about",
  "/pricing",
  "/terms",
  "/privacy",
];

/**
 * Routes that authenticated users should be redirected AWAY from
 * (e.g., login page → dashboard if already signed in).
 */
const AUTH_ROUTES: string[] = ["/login", "/signup", "/forgot-password"];

/** Where to send unauthenticated users. */
const LOGIN_PATH = "/login";

/** Where to send authenticated users when they visit auth pages. */
const DEFAULT_AUTHENTICATED_PATH = "/dashboard";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Check if a pathname matches any route in the given list.
 * Supports exact matches and prefix matches (trailing wildcard).
 */
function matchesRoute(pathname: string, routes: string[]): boolean {
  return routes.some((route) => {
    if (route.endsWith("/*")) {
      return pathname.startsWith(route.slice(0, -2));
    }
    return pathname === route;
  });
}

// ---------------------------------------------------------------------------
// Middleware
// ---------------------------------------------------------------------------

export async function middleware(request: NextRequest) {
  // Start with the default response — we'll layer cookie updates on top
  let supabaseResponse = NextResponse.next({ request });

  // -------------------------------------------------------------------------
  // 1. Create a Supabase client that manages cookies via the request/response
  // -------------------------------------------------------------------------
  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        /**
         * Read all cookies from the incoming request.
         */
        getAll() {
          return request.cookies.getAll();
        },

        /**
         * Write cookies to BOTH the request (for downstream server code)
         * and the response (to send updated tokens back to the browser).
         *
         * This is critical for token refresh — if we only set on the response,
         * server components rendered in the same request would see stale tokens.
         */
        setAll(cookiesToSet) {
          // Set on the request so server components see the fresh tokens
          cookiesToSet.forEach(({ name, value }) => {
            request.cookies.set(name, value);
          });

          // Create a fresh response that carries the updated request
          supabaseResponse = NextResponse.next({ request });

          // Set on the response so the browser receives the updated cookies
          cookiesToSet.forEach(({ name, value, options }) => {
            supabaseResponse.cookies.set(name, value, options);
          });
        },
      },
    }
  );

  // -------------------------------------------------------------------------
  // 2. Refresh the session (this is the primary purpose of the middleware)
  // -------------------------------------------------------------------------
  // IMPORTANT: Use getUser() instead of getSession() for security.
  // getUser() validates the token with the Supabase Auth server,
  // while getSession() only reads the local JWT without verification.
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const { pathname } = request.nextUrl;

  // -------------------------------------------------------------------------
  // 3. Route protection logic
  // -------------------------------------------------------------------------

  // 3a. Redirect authenticated users away from auth pages (login, signup, etc.)
  if (user && matchesRoute(pathname, AUTH_ROUTES)) {
    const redirectUrl = request.nextUrl.clone();
    redirectUrl.pathname = DEFAULT_AUTHENTICATED_PATH;
    return NextResponse.redirect(redirectUrl);
  }

  // 3b. Redirect unauthenticated users to login for protected routes
  if (!user && !matchesRoute(pathname, PUBLIC_ROUTES)) {
    const redirectUrl = request.nextUrl.clone();
    redirectUrl.pathname = LOGIN_PATH;

    // Preserve the originally requested URL so we can redirect back after login
    redirectUrl.searchParams.set("redirectTo", pathname);

    return NextResponse.redirect(redirectUrl);
  }

  // -------------------------------------------------------------------------
  // 4. Return the response with updated cookies
  // -------------------------------------------------------------------------
  return supabaseResponse;
}

// ---------------------------------------------------------------------------
// Matcher Configuration
// ---------------------------------------------------------------------------

/**
 * Define which routes this middleware runs on.
 *
 * We exclude:
 *   - _next/static  — static assets
 *   - _next/image   — optimized images
 *   - favicon.ico   — browser icon
 *   - Common asset extensions (svg, png, jpg, etc.)
 *   - API routes that handle their own auth (optional — remove if you want
 *     middleware auth on API routes too)
 */
export const config = {
  matcher: [
    /*
     * Match all request paths EXCEPT:
     * - _next/static (static files)
     * - _next/image (image optimization)
     * - favicon.ico (favicon)
     * - public assets with common extensions
     */
    "/((?!_next/static|_next/image|favicon\\.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp|ico|css|js|woff|woff2|ttf|eot)$).*)",
  ],
};
