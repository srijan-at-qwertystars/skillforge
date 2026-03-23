/**
 * Production-ready Express.js JWT Authentication Middleware
 *
 * Features:
 * - JWKS endpoint support with in-memory caching
 * - Algorithm pinning (RS256) to prevent algorithm confusion attacks
 * - Standard claim validations: exp, nbf, iss, aud
 * - Pluggable token blocklist for revocation support
 * - Proper HTTP error responses (401/403)
 * - Type-safe request extension via req.user
 *
 * Dependencies:
 *   npm install jose express
 *   npm install -D @types/express
 */

import { createRemoteJWKSet, jwtVerify, type JWTPayload, type JWTVerifyOptions } from "jose";
import type { Request, Response, NextFunction, RequestHandler } from "express";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/** Claims extracted from a verified JWT and attached to the request. */
export interface AuthUser {
  /** Subject – typically the user ID */
  sub: string;
  /** Issuer that minted the token */
  iss: string;
  /** Audience the token was issued for */
  aud: string | string[];
  /** Expiration (Unix seconds) */
  exp: number;
  /** Issued-at (Unix seconds) */
  iat: number;
  /** Scopes / permissions (if present in the token) */
  scopes: string[];
  /** Any additional custom claims from the token payload */
  [key: string]: unknown;
}

/** Extend the Express Request type to include the authenticated user. */
declare global {
  namespace Express {
    interface Request {
      user?: AuthUser;
    }
  }
}

/**
 * Pluggable blocklist checker.
 * Return `true` if the token (identified by its JTI) has been revoked.
 */
export type BlocklistChecker = (jti: string) => Promise<boolean>;

/** Configuration for the JWT middleware. */
export interface JwtMiddlewareOptions {
  /** URL of the JWKS endpoint (e.g. https://auth.example.com/.well-known/jwks.json) */
  jwksUri: string;
  /** Expected `iss` claim value */
  issuer: string;
  /** Expected `aud` claim value(s) */
  audience: string | string[];
  /**
   * Allowed signing algorithms. Defaults to ["RS256"].
   * Restrict this to prevent algorithm confusion attacks.
   */
  algorithms?: string[];
  /** Maximum clock skew tolerance in seconds. Defaults to 0. */
  clockToleranceSec?: number;
  /** Optional blocklist checker for token revocation. */
  isRevoked?: BlocklistChecker;
  /**
   * JWKS cache TTL in milliseconds.
   * The `jose` library handles JWKS caching internally via `createRemoteJWKSet`,
   * but this value controls how long we keep our own reference. Defaults to 600_000 (10 min).
   */
  jwksCacheTtlMs?: number;
}

// ---------------------------------------------------------------------------
// Error helpers
// ---------------------------------------------------------------------------

class AuthError extends Error {
  constructor(
    public readonly statusCode: number,
    message: string,
  ) {
    super(message);
    this.name = "AuthError";
  }
}

function sendAuthError(res: Response, err: AuthError): void {
  res.status(err.statusCode).json({
    error: err.statusCode === 401 ? "unauthorized" : "forbidden",
    message: err.message,
  });
}

// ---------------------------------------------------------------------------
// JWKS cache wrapper
// ---------------------------------------------------------------------------

interface CachedJWKS {
  getKey: ReturnType<typeof createRemoteJWKSet>;
  createdAt: number;
}

let cachedJWKS: CachedJWKS | null = null;

function getJWKS(jwksUri: string, ttlMs: number): ReturnType<typeof createRemoteJWKSet> {
  const now = Date.now();
  if (cachedJWKS && now - cachedJWKS.createdAt < ttlMs) {
    return cachedJWKS.getKey;
  }
  // createRemoteJWKSet fetches and caches the JWKS internally, but we wrap it
  // to avoid creating a new instance on every request.
  const getKey = createRemoteJWKSet(new URL(jwksUri));
  cachedJWKS = { getKey, createdAt: now };
  return getKey;
}

// ---------------------------------------------------------------------------
// Middleware factory
// ---------------------------------------------------------------------------

/**
 * Creates an Express middleware that verifies JWTs on incoming requests.
 *
 * Usage:
 * ```ts
 * import express from "express";
 * import { createJwtMiddleware } from "./jwt-middleware-node";
 *
 * const app = express();
 *
 * app.use(
 *   "/api",
 *   createJwtMiddleware({
 *     jwksUri: "https://auth.example.com/.well-known/jwks.json",
 *     issuer: "https://auth.example.com/",
 *     audience: "my-api",
 *   }),
 * );
 *
 * app.get("/api/me", (req, res) => {
 *   res.json({ user: req.user });
 * });
 * ```
 */
export function createJwtMiddleware(options: JwtMiddlewareOptions): RequestHandler {
  const {
    jwksUri,
    issuer,
    audience,
    algorithms = ["RS256"],
    clockToleranceSec = 0,
    isRevoked,
    jwksCacheTtlMs = 600_000,
  } = options;

  return async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    try {
      // ---------------------------------------------------------------
      // 1. Extract the Bearer token from the Authorization header
      // ---------------------------------------------------------------
      const authHeader = req.headers.authorization;
      if (!authHeader) {
        throw new AuthError(401, "Missing Authorization header");
      }

      const parts = authHeader.split(" ");
      if (parts.length !== 2 || parts[0].toLowerCase() !== "bearer") {
        throw new AuthError(401, "Authorization header must use Bearer scheme");
      }
      const token = parts[1];

      // ---------------------------------------------------------------
      // 2. Verify the JWT signature and standard claims
      // ---------------------------------------------------------------
      const jwks = getJWKS(jwksUri, jwksCacheTtlMs);

      const verifyOptions: JWTVerifyOptions = {
        issuer,
        audience,
        algorithms,
        clockTolerance: clockToleranceSec,
      };

      const { payload } = await jwtVerify(token, jwks, verifyOptions);

      // ---------------------------------------------------------------
      // 3. Validate required claims are present
      // ---------------------------------------------------------------
      if (!payload.sub) {
        throw new AuthError(401, "Token missing required 'sub' claim");
      }

      // ---------------------------------------------------------------
      // 4. Check the blocklist (if configured)
      // ---------------------------------------------------------------
      if (isRevoked && payload.jti) {
        const revoked = await isRevoked(payload.jti);
        if (revoked) {
          throw new AuthError(401, "Token has been revoked");
        }
      }

      // ---------------------------------------------------------------
      // 5. Attach the user to the request
      // ---------------------------------------------------------------
      req.user = mapPayloadToUser(payload);

      next();
    } catch (err) {
      if (err instanceof AuthError) {
        sendAuthError(res, err);
        return;
      }

      // jose library throws typed errors for common JWT failures
      const message = err instanceof Error ? err.message : "Token verification failed";

      // Distinguish expired / not-yet-valid from other verification failures
      if (message.includes("expired") || message.includes("not active")) {
        sendAuthError(res, new AuthError(401, message));
        return;
      }

      sendAuthError(res, new AuthError(401, `Invalid token: ${message}`));
    }
  };
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Map a verified JWT payload to our AuthUser type. */
function mapPayloadToUser(payload: JWTPayload): AuthUser {
  // Extract scopes from common claim locations
  const scopes = extractScopes(payload);

  return {
    sub: payload.sub!,
    iss: payload.iss!,
    aud: payload.aud!,
    exp: payload.exp!,
    iat: payload.iat!,
    scopes,
    ...payload,
  };
}

/** Extract scopes from a JWT payload. Handles both space-delimited strings and arrays. */
function extractScopes(payload: JWTPayload): string[] {
  const raw = (payload as Record<string, unknown>).scope ?? (payload as Record<string, unknown>).scopes;
  if (Array.isArray(raw)) {
    return raw.map(String);
  }
  if (typeof raw === "string") {
    return raw.split(" ").filter(Boolean);
  }
  return [];
}

// ---------------------------------------------------------------------------
// Optional: scope-checking middleware
// ---------------------------------------------------------------------------

/**
 * Returns a middleware that ensures the authenticated user has **all** of the
 * specified scopes. Must be used after `createJwtMiddleware`.
 *
 * Usage:
 * ```ts
 * app.delete("/api/users/:id", requireScopes("admin", "users:delete"), handler);
 * ```
 */
export function requireScopes(...required: string[]): RequestHandler {
  return (req: Request, res: Response, next: NextFunction): void => {
    if (!req.user) {
      sendAuthError(res, new AuthError(401, "Authentication required"));
      return;
    }

    const missing = required.filter((s) => !req.user!.scopes.includes(s));
    if (missing.length > 0) {
      sendAuthError(
        res,
        new AuthError(403, `Insufficient scope. Missing: ${missing.join(", ")}`),
      );
      return;
    }

    next();
  };
}
