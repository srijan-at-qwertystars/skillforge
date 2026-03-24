/**
 * CSP Violation Report Handler
 *
 * Express endpoint for receiving, processing, and logging
 * Content-Security-Policy violation reports.
 *
 * Supports both:
 * - report-uri format (application/csp-report)
 * - Reporting API format (application/reports+json)
 *
 * Usage:
 *   import { cspReportRouter } from './csp-report-handler';
 *   app.use(cspReportRouter);
 */

import { Router, json } from 'express';
import type { Request, Response } from 'express';

// ── Types ───────────────────────────────────────────────────

interface CSPReportUriBody {
  'csp-report': {
    'document-uri': string;
    referrer?: string;
    'violated-directive': string;
    'effective-directive'?: string;
    'original-policy': string;
    'blocked-uri': string;
    'status-code'?: number;
    'source-file'?: string;
    'line-number'?: number;
    'column-number'?: number;
    'script-sample'?: string;
    disposition?: 'enforce' | 'report';
  };
}

interface CSPReportToBody {
  type: 'csp-violation';
  age: number;
  url: string;
  user_agent: string;
  body: {
    documentURL: string;
    blockedURL: string;
    violatedDirective: string;
    effectiveDirective: string;
    originalPolicy: string;
    disposition: 'enforce' | 'report';
    statusCode: number;
    sample?: string;
    sourceFile?: string;
    lineNumber?: number;
    columnNumber?: number;
    referrer?: string;
  };
}

interface NormalizedReport {
  timestamp: string;
  documentUrl: string;
  blockedUrl: string;
  violatedDirective: string;
  effectiveDirective: string;
  sourceFile?: string;
  lineNumber?: number;
  columnNumber?: number;
  sample?: string;
  disposition: string;
  statusCode?: number;
  referrer?: string;
  isNoise: boolean;
  userAgent?: string;
}

// ── Configuration ───────────────────────────────────────────

const config = {
  /** Max reports to keep in memory */
  maxReportsInMemory: 10000,

  /** Rate limit: max reports per IP per minute */
  rateLimit: 100,

  /** Max report body size in bytes */
  maxBodySize: '100kb',

  /** Browser extension URI patterns to filter as noise */
  noisePatterns: [
    /^(chrome|moz|safari|ms-browser)-extension:\/\//,
    /^about:/,
    /^blob:/,
    /webkit-masked-url/,
    /^data:/,
  ],
};

// ── State ───────────────────────────────────────────────────

const reports: NormalizedReport[] = [];
const rateLimitMap = new Map<string, { count: number; resetAt: number }>();

// ── Helpers ─────────────────────────────────────────────────

function isNoise(blockedUrl: string): boolean {
  return config.noisePatterns.some((pattern) => pattern.test(blockedUrl));
}

function normalizeReportUri(body: CSPReportUriBody, userAgent?: string): NormalizedReport {
  const r = body['csp-report'];
  const blockedUrl = r['blocked-uri'] || '';
  return {
    timestamp: new Date().toISOString(),
    documentUrl: r['document-uri'],
    blockedUrl,
    violatedDirective: r['violated-directive'],
    effectiveDirective: r['effective-directive'] || r['violated-directive'],
    sourceFile: r['source-file'],
    lineNumber: r['line-number'],
    columnNumber: r['column-number'],
    sample: r['script-sample'],
    disposition: r.disposition || 'enforce',
    statusCode: r['status-code'],
    referrer: r.referrer,
    isNoise: isNoise(blockedUrl),
    userAgent,
  };
}

function normalizeReportTo(body: CSPReportToBody): NormalizedReport {
  const r = body.body;
  const blockedUrl = r.blockedURL || '';
  return {
    timestamp: new Date().toISOString(),
    documentUrl: r.documentURL,
    blockedUrl,
    violatedDirective: r.violatedDirective,
    effectiveDirective: r.effectiveDirective,
    sourceFile: r.sourceFile,
    lineNumber: r.lineNumber,
    columnNumber: r.columnNumber,
    sample: r.sample,
    disposition: r.disposition || 'enforce',
    statusCode: r.statusCode,
    referrer: r.referrer,
    isNoise: isNoise(blockedUrl),
    userAgent: body.user_agent,
  };
}

function checkRateLimit(ip: string): boolean {
  const now = Date.now();
  const entry = rateLimitMap.get(ip);

  if (!entry || now > entry.resetAt) {
    rateLimitMap.set(ip, { count: 1, resetAt: now + 60_000 });
    return true;
  }

  entry.count++;
  return entry.count <= config.rateLimit;
}

function storeReport(report: NormalizedReport): void {
  reports.push(report);
  if (reports.length > config.maxReportsInMemory) {
    reports.splice(0, reports.length - config.maxReportsInMemory);
  }
}

// ── Router ──────────────────────────────────────────────────

export const cspReportRouter = Router();

// Parse JSON for both content types
cspReportRouter.use(
  json({
    type: ['application/csp-report', 'application/reports+json', 'application/json'],
    limit: config.maxBodySize,
  })
);

/**
 * POST /csp-report
 * Receives CSP violation reports in both report-uri and report-to formats.
 */
cspReportRouter.post('/csp-report', (req: Request, res: Response) => {
  const clientIp = req.ip || req.socket.remoteAddress || 'unknown';

  if (!checkRateLimit(clientIp)) {
    res.status(429).json({ error: 'Too many reports' });
    return;
  }

  try {
    const body = req.body;

    if (!body || typeof body !== 'object') {
      res.status(400).json({ error: 'Invalid report body' });
      return;
    }

    const userAgent = req.headers['user-agent'];
    let normalized: NormalizedReport[];

    if (Array.isArray(body)) {
      // Reporting API sends arrays of reports
      normalized = body
        .filter((r: CSPReportToBody) => r.type === 'csp-violation')
        .map((r: CSPReportToBody) => normalizeReportTo(r));
    } else if (body['csp-report']) {
      // report-uri format
      normalized = [normalizeReportUri(body as CSPReportUriBody, userAgent)];
    } else if (body.type === 'csp-violation') {
      // Single report-to format
      normalized = [normalizeReportTo(body as CSPReportToBody)];
    } else {
      res.status(400).json({ error: 'Unrecognized report format' });
      return;
    }

    for (const report of normalized) {
      storeReport(report);

      // Log non-noise reports (replace with your logging/alerting system)
      if (!report.isNoise) {
        console.log(
          `[CSP ${report.disposition}] ${report.violatedDirective}: ` +
            `blocked ${report.blockedUrl} on ${report.documentUrl}` +
            (report.sourceFile ? ` (${report.sourceFile}:${report.lineNumber})` : '')
        );
      }
    }

    res.status(204).end();
  } catch (err) {
    console.error('[CSP Report Handler] Error processing report:', err);
    res.status(500).json({ error: 'Internal error processing report' });
  }
});

/**
 * GET /csp-report/stats
 * Returns aggregated violation statistics.
 * Protect this endpoint with authentication in production.
 */
cspReportRouter.get('/csp-report/stats', (_req: Request, res: Response) => {
  const realReports = reports.filter((r) => !r.isNoise);

  // Aggregate by directive + blocked domain
  const byDirective = new Map<string, number>();
  const byBlockedDomain = new Map<string, number>();
  const byPage = new Map<string, number>();

  for (const r of realReports) {
    // By directive
    const directive = r.effectiveDirective || r.violatedDirective;
    byDirective.set(directive, (byDirective.get(directive) || 0) + 1);

    // By blocked domain
    let domain: string;
    try {
      domain = new URL(r.blockedUrl).hostname;
    } catch {
      domain = r.blockedUrl || 'inline/eval';
    }
    byBlockedDomain.set(domain, (byBlockedDomain.get(domain) || 0) + 1);

    // By page
    try {
      const page = new URL(r.documentUrl).pathname;
      byPage.set(page, (byPage.get(page) || 0) + 1);
    } catch {
      /* skip invalid URLs */
    }
  }

  const sortMap = (map: Map<string, number>) =>
    [...map.entries()].sort((a, b) => b[1] - a[1]).slice(0, 20);

  res.json({
    totalReports: reports.length,
    noiseFiltered: reports.length - realReports.length,
    realViolations: realReports.length,
    byDirective: Object.fromEntries(sortMap(byDirective)),
    byBlockedDomain: Object.fromEntries(sortMap(byBlockedDomain)),
    byPage: Object.fromEntries(sortMap(byPage)),
    recentReports: realReports.slice(-10).reverse(),
  });
});

/**
 * GET /csp-report/recent
 * Returns the most recent violation reports.
 * Protect this endpoint with authentication in production.
 */
cspReportRouter.get('/csp-report/recent', (req: Request, res: Response) => {
  const limit = Math.min(parseInt(req.query.limit as string, 10) || 50, 200);
  const includeNoise = req.query.noise === 'true';

  const filtered = includeNoise ? reports : reports.filter((r) => !r.isNoise);

  res.json({
    count: filtered.length,
    reports: filtered.slice(-limit).reverse(),
  });
});
