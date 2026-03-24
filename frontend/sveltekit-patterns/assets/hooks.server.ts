// Server hooks template — src/hooks.server.ts
// Handles auth, CSP headers, request logging, and error handling.
// Copy to src/hooks.server.ts and customize for your project.

import type { Handle, HandleFetch, HandleServerError } from '@sveltejs/kit';
import { sequence } from '@sveltejs/kit/hooks';

// --- Auth Hook ---
// Reads session cookie, validates it, and populates event.locals.user.
const auth: Handle = async ({ event, resolve }) => {
	const sessionToken = event.cookies.get('session');

	if (sessionToken) {
		try {
			// TODO: Replace with your actual session validation logic
			// Examples:
			//   const session = await db.session.findUnique({ where: { token: sessionToken } });
			//   const payload = jwt.verify(sessionToken, JWT_SECRET);
			//   const user = await lucia.validateSession(sessionToken);
			event.locals.user = {
				id: 'user-id',
				email: 'user@example.com',
				name: 'User',
				role: 'user'
			};
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

// --- Security Headers Hook ---
// Sets CSP, HSTS, and other security headers on all responses.
const securityHeaders: Handle = async ({ event, resolve }) => {
	const response = await resolve(event);

	// Content Security Policy
	// Adjust directives based on your needs (CDNs, analytics, etc.)
	response.headers.set(
		'Content-Security-Policy',
		[
			"default-src 'self'",
			"script-src 'self' 'unsafe-inline'", // Remove unsafe-inline in production if possible
			"style-src 'self' 'unsafe-inline'",
			"img-src 'self' data: https:",
			"font-src 'self'",
			"connect-src 'self'",
			"frame-ancestors 'none'",
			"base-uri 'self'",
			"form-action 'self'"
		].join('; ')
	);

	// Other security headers
	response.headers.set('X-Frame-Options', 'DENY');
	response.headers.set('X-Content-Type-Options', 'nosniff');
	response.headers.set('Referrer-Policy', 'strict-origin-when-cross-origin');
	response.headers.set('Permissions-Policy', 'camera=(), microphone=(), geolocation=()');

	// HSTS — uncomment when you're confident HTTPS is fully set up
	// response.headers.set('Strict-Transport-Security', 'max-age=63072000; includeSubDomains; preload');

	return response;
};

// --- Request Logging Hook ---
// Logs method, path, status, and duration for each request.
const logging: Handle = async ({ event, resolve }) => {
	const start = performance.now();
	const response = await resolve(event);
	const duration = (performance.now() - start).toFixed(1);

	const { method } = event.request;
	const { pathname } = event.url;
	const status = response.status;

	// Skip logging for static assets
	if (
		!pathname.startsWith('/_app/') &&
		!pathname.startsWith('/favicon') &&
		!pathname.endsWith('.js') &&
		!pathname.endsWith('.css')
	) {
		console.log(`${method} ${pathname} ${status} ${duration}ms`);
	}

	return response;
};

// --- Compose Hooks ---
// sequence() runs hooks in order: auth → logging → securityHeaders
export const handle = sequence(auth, logging, securityHeaders);

// --- Handle Server-Side Fetch ---
// Intercept outgoing fetch calls made during SSR (e.g., adding auth headers).
export const handleFetch: HandleFetch = async ({ request, fetch, event }) => {
	// Forward auth to internal API calls
	if (request.url.startsWith(event.url.origin)) {
		// Internal fetch — cookies are forwarded automatically
		return fetch(request);
	}

	// Add auth header for external API calls
	// if (request.url.startsWith('https://api.myservice.com')) {
	//   const token = event.cookies.get('api_token');
	//   if (token) {
	//     request.headers.set('Authorization', `Bearer ${token}`);
	//   }
	// }

	return fetch(request);
};

// --- Handle Server Errors ---
// Catches unhandled errors and returns a safe error response.
// IMPORTANT: Never expose internal error details to clients.
export const handleError: HandleServerError = async ({ error, event, status, message }) => {
	// Log the full error for debugging (server-side only)
	console.error(`[${status}] ${event.url.pathname}:`, error);

	// Optional: send to error tracking service
	// await Sentry.captureException(error, { extra: { url: event.url.pathname } });

	// Return a safe error object to the client
	return {
		message: status === 404 ? 'Page not found' : 'An unexpected error occurred',
		code: status === 404 ? 'NOT_FOUND' : 'INTERNAL_ERROR'
	};
};
