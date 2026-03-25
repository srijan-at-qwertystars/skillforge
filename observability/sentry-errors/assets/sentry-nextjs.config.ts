// sentry-nextjs.config.ts — Complete Next.js Sentry configuration template
//
// Usage:
//   1. Copy this file to your Next.js project root as next.config.ts
//   2. Create sentry.client.config.ts, sentry.server.config.ts, sentry.edge.config.ts
//      (templates below in comments)
//   3. Create instrumentation.ts in project root
//   4. Set environment variables (see .env section)
//
// Required packages:
//   npm install @sentry/nextjs
//
// Required environment variables:
//   NEXT_PUBLIC_SENTRY_DSN  — Public DSN for client-side
//   SENTRY_DSN              — Server-side DSN (can be same value)
//   SENTRY_ORG              — Organization slug (for source maps)
//   SENTRY_PROJECT          — Project slug (for source maps)
//   SENTRY_AUTH_TOKEN       — Auth token (for source map upload in CI)

import type { NextConfig } from "next";
import { withSentryConfig } from "@sentry/nextjs";

const nextConfig: NextConfig = {
  // Your existing Next.js config goes here
  reactStrictMode: true,

  // Required for Sentry server-side instrumentation (Next.js 13.4+)
  experimental: {
    instrumentationHook: true,
  },
};

export default withSentryConfig(nextConfig, {
  // === Sentry Build Options ===

  org: process.env.SENTRY_ORG,
  project: process.env.SENTRY_PROJECT,
  authToken: process.env.SENTRY_AUTH_TOKEN,

  // Suppress noisy logs during local dev
  silent: !process.env.CI,

  // Upload wider set of source maps (recommended)
  widenClientFileUpload: true,

  // Remove source maps from production deployment
  hideSourceMaps: true,

  // Tree-shake Sentry logger for smaller bundle
  disableLogger: true,

  // Automatically instrument API routes and server components
  autoInstrumentServerFunctions: true,

  // Automatically instrument middleware
  autoInstrumentMiddleware: true,

  // Automatically instrument app directory components
  autoInstrumentAppDirectory: true,

  // Tunnel Sentry events through your Next.js server to avoid ad blockers
  // tunnelRoute: "/monitoring",

  // Uncomment to route through a custom Sentry ingest domain
  // sentryUrl: "https://sentry.your-company.com",
});

// ============================================================
// TEMPLATE: sentry.client.config.ts (create in project root)
// ============================================================
/*
import * as Sentry from "@sentry/nextjs";

Sentry.init({
  dsn: process.env.NEXT_PUBLIC_SENTRY_DSN,
  environment: process.env.NODE_ENV,

  // Performance Monitoring
  tracesSampleRate: process.env.NODE_ENV === "production" ? 0.2 : 1.0,

  // Session Replay
  replaysSessionSampleRate: 0.1,
  replaysOnErrorSampleRate: 1.0,

  integrations: [
    Sentry.replayIntegration({
      maskAllText: true,
      blockAllMedia: true,
      maskAllInputs: true,
    }),
  ],

  // Filter non-actionable errors
  ignoreErrors: [
    /ResizeObserver loop/,
    /Network request failed/,
    "Non-Error promise rejection captured",
    /Load failed/,
  ],

  denyUrls: [
    /extensions\//i,
    /^chrome:\/\//i,
    /^moz-extension:\/\//i,
  ],

  beforeSend(event, hint) {
    // Scrub PII
    if (event.user?.email) {
      event.user.email = "[REDACTED]";
    }
    return event;
  },
});
*/

// ============================================================
// TEMPLATE: sentry.server.config.ts (create in project root)
// ============================================================
/*
import * as Sentry from "@sentry/nextjs";

Sentry.init({
  dsn: process.env.SENTRY_DSN,
  environment: process.env.NODE_ENV,

  tracesSampleRate: process.env.NODE_ENV === "production" ? 0.2 : 1.0,
  profilesSampleRate: 0.1,

  // Dynamic sampling for server-side
  tracesSampler(samplingContext) {
    const { name } = samplingContext;

    // Drop health checks
    if (name?.match(/\/(health|ready|live|api\/health)/)) return 0;

    // Always trace critical paths
    if (name?.match(/\/api\/(payments|checkout|auth)/)) return 1.0;

    return 0.2;
  },

  beforeSend(event, hint) {
    const error = hint?.originalException;
    // Don't report expected errors
    if (error instanceof Error && error.message.includes("NEXT_NOT_FOUND")) {
      return null;
    }
    return event;
  },
});
*/

// ============================================================
// TEMPLATE: sentry.edge.config.ts (create in project root)
// ============================================================
/*
import * as Sentry from "@sentry/nextjs";

Sentry.init({
  dsn: process.env.SENTRY_DSN,
  environment: process.env.NODE_ENV,
  tracesSampleRate: 0.2,
});
*/

// ============================================================
// TEMPLATE: instrumentation.ts (create in project root)
// ============================================================
/*
export async function register() {
  if (process.env.NEXT_RUNTIME === "nodejs") {
    await import("./sentry.server.config");
  }

  if (process.env.NEXT_RUNTIME === "edge") {
    await import("./sentry.edge.config");
  }
}

export const onRequestError = Sentry.captureRequestError;
*/

// ============================================================
// TEMPLATE: app/global-error.tsx (create for App Router)
// ============================================================
/*
"use client";

import * as Sentry from "@sentry/nextjs";
import { useEffect } from "react";

export default function GlobalError({
  error,
  reset,
}: {
  error: Error & { digest?: string };
  reset: () => void;
}) {
  useEffect(() => {
    Sentry.captureException(error);
  }, [error]);

  return (
    <html>
      <body>
        <h2>Something went wrong!</h2>
        <button onClick={() => reset()}>Try again</button>
      </body>
    </html>
  );
}
*/
