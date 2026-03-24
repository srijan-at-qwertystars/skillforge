import { NextRequest, NextResponse } from "next/server";

// --- Configuration ---
const PUBLIC_PATHS = ["/", "/login", "/register", "/forgot-password"];
const PROTECTED_PREFIX = ["/dashboard", "/settings", "/account"];
const API_RATE_LIMIT = 100; // requests per window
const RATE_LIMIT_WINDOW_MS = 60_000; // 1 minute

const SUPPORTED_LOCALES = ["en", "es", "fr", "de"];
const DEFAULT_LOCALE = "en";

// --- Rate Limiting (in-memory, per-instance) ---
const rateLimitMap = new Map<
  string,
  { count: number; resetTime: number }
>();

function checkRateLimit(ip: string): {
  limited: boolean;
  remaining: number;
} {
  const now = Date.now();
  const record = rateLimitMap.get(ip);

  if (!record || now > record.resetTime) {
    rateLimitMap.set(ip, {
      count: 1,
      resetTime: now + RATE_LIMIT_WINDOW_MS,
    });
    return { limited: false, remaining: API_RATE_LIMIT - 1 };
  }

  record.count++;
  const remaining = Math.max(0, API_RATE_LIMIT - record.count);
  return { limited: record.count > API_RATE_LIMIT, remaining };
}

// Periodic cleanup to prevent memory leak
if (typeof setInterval !== "undefined") {
  setInterval(() => {
    const now = Date.now();
    for (const [key, value] of rateLimitMap) {
      if (now > value.resetTime) rateLimitMap.delete(key);
    }
  }, RATE_LIMIT_WINDOW_MS);
}

// --- Locale Detection ---
function detectLocale(request: NextRequest): string {
  // 1. Check cookie preference
  const cookieLocale = request.cookies.get("locale")?.value;
  if (cookieLocale && SUPPORTED_LOCALES.includes(cookieLocale)) {
    return cookieLocale;
  }

  // 2. Parse Accept-Language header
  const acceptLang = request.headers.get("accept-language") || "";
  const preferred = acceptLang
    .split(",")
    .map((lang) => {
      const [code, q] = lang.trim().split(";q=");
      return { code: code.split("-")[0], quality: q ? parseFloat(q) : 1 };
    })
    .sort((a, b) => b.quality - a.quality)
    .find((lang) => SUPPORTED_LOCALES.includes(lang.code));

  return preferred?.code || DEFAULT_LOCALE;
}

// --- Main Middleware ---
export function middleware(request: NextRequest) {
  const { pathname } = request.nextUrl;
  const response = NextResponse.next();

  // 1. Security headers (all routes)
  response.headers.set("X-Frame-Options", "DENY");
  response.headers.set("X-Content-Type-Options", "nosniff");
  response.headers.set(
    "Referrer-Policy",
    "strict-origin-when-cross-origin"
  );
  response.headers.set("X-DNS-Prefetch-Control", "on");

  // 2. Rate limiting for API routes
  if (pathname.startsWith("/api/")) {
    const ip =
      request.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ||
      "unknown";
    const { limited, remaining } = checkRateLimit(ip);

    response.headers.set("X-RateLimit-Limit", String(API_RATE_LIMIT));
    response.headers.set("X-RateLimit-Remaining", String(remaining));

    if (limited) {
      return NextResponse.json(
        { error: "Too many requests" },
        {
          status: 429,
          headers: {
            "Retry-After": "60",
            "X-RateLimit-Limit": String(API_RATE_LIMIT),
            "X-RateLimit-Remaining": "0",
          },
        }
      );
    }
  }

  // 3. Auth check for protected routes
  if (PROTECTED_PREFIX.some((prefix) => pathname.startsWith(prefix))) {
    const sessionToken =
      request.cookies.get("session-token")?.value ||
      request.cookies.get("__Secure-next-auth.session-token")?.value;

    if (!sessionToken) {
      const loginUrl = new URL("/login", request.url);
      loginUrl.searchParams.set("callbackUrl", pathname);
      return NextResponse.redirect(loginUrl);
    }
  }

  // 4. Locale detection (set header for server components)
  const locale = detectLocale(request);
  response.headers.set("x-locale", locale);

  return response;
}

// Only run middleware on relevant paths (skip static assets)
export const config = {
  matcher: [
    "/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp|ico|woff2|woff|ttf|css|js)$).*)",
  ],
};
