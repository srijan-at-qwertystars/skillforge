// hooks.server.ts — Production server hooks for SvelteKit
// Copy to src/hooks.server.ts and customize auth, logging, and headers.

import type { Handle, HandleFetch, HandleServerError } from '@sveltejs/kit';
import { sequence } from '@sveltejs/kit/hooks';
import { dev } from '$app/environment';

// =============================================================================
// Type declarations — add to src/app.d.ts in your project:
//
// declare global {
//   namespace App {
//     interface Locals {
//       user: { id: string; email: string; role: string } | null;
//       requestId: string;
//     }
//     interface Error {
//       message: string;
//       id?: string;
//       code?: string;
//     }
//   }
// }
// export {};
// =============================================================================

// --- Request ID ---
// Assign a unique ID to every request for tracing through logs.
const requestId: Handle = async ({ event, resolve }) => {
	event.locals.requestId =
		event.request.headers.get('x-request-id') ?? crypto.randomUUID();
	return resolve(event);
};

// --- Authentication ---
// Reads session cookie, validates token, and populates event.locals.user.
const auth: Handle = async ({ event, resolve }) => {
	const sessionToken = event.cookies.get('session');

	if (sessionToken) {
		try {
			// Replace with your actual session validation logic:
			// - JWT verification
			// - Database session lookup
			// - External auth service call
			const user = await validateSession(sessionToken);
			event.locals.user = user;
		} catch {
			// Invalid or expired session — clear the cookie
			event.cookies.delete('session', { path: '/' });
			event.locals.user = null;
		}
	} else {
		event.locals.user = null;
	}

	return resolve(event);
};

// --- Rate Limiting (simple in-memory, replace with Redis for production) ---
const rateLimitMap = new Map<string, { count: number; resetAt: number }>();
const RATE_LIMIT = 100; // requests per window
const RATE_WINDOW = 60_000; // 1 minute

const rateLimit: Handle = async ({ event, resolve }) => {
	// Only rate-limit API routes and form actions
	if (!event.url.pathname.startsWith('/api') && event.request.method === 'GET') {
		return resolve(event);
	}

	const clientIp =
		event.request.headers.get('x-forwarded-for')?.split(',')[0]?.trim() ??
		event.getClientAddress();

	const now = Date.now();
	const entry = rateLimitMap.get(clientIp);

	if (!entry || now > entry.resetAt) {
		rateLimitMap.set(clientIp, { count: 1, resetAt: now + RATE_WINDOW });
	} else {
		entry.count++;
		if (entry.count > RATE_LIMIT) {
			return new Response('Too Many Requests', {
				status: 429,
				headers: {
					'Retry-After': String(Math.ceil((entry.resetAt - now) / 1000))
				}
			});
		}
	}

	return resolve(event);
};

// --- Request Logging ---
const logger: Handle = async ({ event, resolve }) => {
	const start = performance.now();

	const response = await resolve(event);

	const duration = Math.round(performance.now() - start);
	const { method } = event.request;
	const { pathname } = event.url;
	const status = response.status;
	const requestId = event.locals.requestId;

	// Structured log format
	const logEntry = {
		requestId,
		method,
		path: pathname,
		status,
		duration: `${duration}ms`,
		user: event.locals.user?.id ?? 'anonymous'
	};

	if (status >= 500) {
		console.error('[HTTP]', JSON.stringify(logEntry));
	} else if (status >= 400) {
		console.warn('[HTTP]', JSON.stringify(logEntry));
	} else if (!dev || pathname !== '/__data.json') {
		// Skip noisy internal requests in dev
		console.log('[HTTP]', JSON.stringify(logEntry));
	}

	return response;
};

// --- Security Headers ---
const securityHeaders: Handle = async ({ event, resolve }) => {
	const response = await resolve(event);

	// Prevent MIME type sniffing
	response.headers.set('X-Content-Type-Options', 'nosniff');

	// Prevent clickjacking
	response.headers.set('X-Frame-Options', 'DENY');

	// XSS protection (legacy browsers)
	response.headers.set('X-XSS-Protection', '1; mode=block');

	// Referrer policy
	response.headers.set('Referrer-Policy', 'strict-origin-when-cross-origin');

	// Permissions policy — disable unused browser features
	response.headers.set(
		'Permissions-Policy',
		'camera=(), microphone=(), geolocation=(), payment=()'
	);

	// Strict Transport Security (HTTPS only)
	if (!dev) {
		response.headers.set(
			'Strict-Transport-Security',
			'max-age=63072000; includeSubDomains; preload'
		);
	}

	return response;
};

// --- Compose All Hooks ---
// Order matters: requestId → auth → rateLimit → logger → securityHeaders
export const handle = sequence(
	requestId,
	auth,
	rateLimit,
	logger,
	securityHeaders
);

// --- Handle Fetch (internal API calls) ---
// Modify outgoing fetch requests made during SSR (e.g., add auth headers).
export const handleFetch: HandleFetch = async ({ request, fetch, event }) => {
	// Forward auth to internal API endpoints
	if (request.url.startsWith(event.url.origin)) {
		const session = event.cookies.get('session');
		if (session) {
			request.headers.set('Authorization', `Bearer ${session}`);
		}
		// Forward request ID for distributed tracing
		request.headers.set('x-request-id', event.locals.requestId);
	}

	return fetch(request);
};

// --- Handle Server Errors ---
// Catch unexpected errors, log them, and return a safe error to the client.
export const handleError: HandleServerError = async ({ error, event, status, message }) => {
	const errorId = crypto.randomUUID();

	// Log the full error server-side
	console.error(`[ERROR ${errorId}]`, {
		status,
		message,
		path: event.url.pathname,
		method: event.request.method,
		user: event.locals.user?.id,
		requestId: event.locals.requestId,
		error: error instanceof Error ? error.stack : error
	});

	// Return safe error to client (never expose internals)
	return {
		message: dev ? (error instanceof Error ? error.message : message) : 'An unexpected error occurred',
		id: errorId,
		code: `E${status}`
	};
};

// =============================================================================
// Placeholder — replace with your actual session validation
// =============================================================================
async function validateSession(
	token: string
): Promise<{ id: string; email: string; role: string }> {
	// Example: verify JWT, look up session in DB, or call auth service
	// throw new Error('Invalid session') to reject
	throw new Error('Implement validateSession()');
}
