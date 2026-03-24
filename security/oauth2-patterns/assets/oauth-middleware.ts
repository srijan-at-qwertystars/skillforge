/**
 * Express/Node middleware for OAuth2 access token validation with JWKS support.
 *
 * Features:
 * - JWT validation using RS256/ES256 with JWKS auto-discovery
 * - JWKS key caching with automatic rotation
 * - Scope-based authorization
 * - Standard error responses per RFC 6750
 *
 * Usage:
 *   import { createOAuthMiddleware, requireScopes } from './oauth-middleware';
 *
 *   const auth = createOAuthMiddleware({
 *     issuer: 'https://auth.example.com',
 *     audience: 'https://api.example.com',
 *     jwksUri: 'https://auth.example.com/.well-known/jwks.json',
 *   });
 *
 *   app.get('/api/users', auth, requireScopes('read:users'), handler);
 */

import type { Request, Response, NextFunction, RequestHandler } from 'express';
import crypto from 'node:crypto';

// ─── Types ───────────────────────────────────────────────────────────────────

export interface OAuthMiddlewareConfig {
  /** Expected token issuer (iss claim) */
  issuer: string;
  /** Expected token audience (aud claim) */
  audience: string;
  /** URL to fetch the JWKS (JSON Web Key Set) */
  jwksUri: string;
  /** Allowed signing algorithms (default: ['RS256', 'ES256']) */
  algorithms?: string[];
  /** Clock skew tolerance in seconds (default: 30) */
  clockToleranceSec?: number;
  /** JWKS cache TTL in milliseconds (default: 600000 = 10 minutes) */
  jwksCacheTtlMs?: number;
  /** Custom claim to extract scopes from (default: 'scope') */
  scopeClaim?: string;
}

export interface JWK {
  kty: string;
  kid?: string;
  use?: string;
  alg?: string;
  n?: string;
  e?: string;
  x?: string;
  y?: string;
  crv?: string;
}

export interface JWKS {
  keys: JWK[];
}

export interface JWTPayload {
  iss?: string;
  sub?: string;
  aud?: string | string[];
  exp?: number;
  nbf?: number;
  iat?: number;
  jti?: string;
  scope?: string;
  permissions?: string[];
  [key: string]: unknown;
}

export interface JWTHeader {
  alg: string;
  typ?: string;
  kid?: string;
}

declare global {
  namespace Express {
    interface Request {
      auth?: JWTPayload;
    }
  }
}

// ─── JWKS Cache ──────────────────────────────────────────────────────────────

class JWKSClient {
  private cache: JWKS | null = null;
  private cacheExpiry = 0;
  private fetchPromise: Promise<JWKS> | null = null;

  constructor(
    private jwksUri: string,
    private cacheTtlMs: number,
  ) {}

  async getKey(kid: string | undefined): Promise<crypto.KeyObject> {
    const jwks = await this.getJWKS();
    const key = kid
      ? jwks.keys.find((k) => k.kid === kid)
      : jwks.keys.find((k) => k.use === 'sig' || !k.use);

    if (!key) {
      // Key not found — maybe keys were rotated. Force refresh once.
      if (this.cache) {
        this.cache = null;
        this.cacheExpiry = 0;
        const refreshedJwks = await this.getJWKS();
        const refreshedKey = kid
          ? refreshedJwks.keys.find((k) => k.kid === kid)
          : refreshedJwks.keys.find((k) => k.use === 'sig' || !k.use);
        if (!refreshedKey) {
          throw new AuthError('invalid_token', `No matching key found for kid: ${kid}`);
        }
        return this.jwkToKeyObject(refreshedKey);
      }
      throw new AuthError('invalid_token', `No matching key found for kid: ${kid}`);
    }

    return this.jwkToKeyObject(key);
  }

  private async getJWKS(): Promise<JWKS> {
    if (this.cache && Date.now() < this.cacheExpiry) {
      return this.cache;
    }

    if (this.fetchPromise) {
      return this.fetchPromise;
    }

    this.fetchPromise = this.fetchJWKS();
    try {
      const jwks = await this.fetchPromise;
      this.cache = jwks;
      this.cacheExpiry = Date.now() + this.cacheTtlMs;
      return jwks;
    } finally {
      this.fetchPromise = null;
    }
  }

  private async fetchJWKS(): Promise<JWKS> {
    const response = await fetch(this.jwksUri, {
      headers: { Accept: 'application/json' },
      signal: AbortSignal.timeout(10_000),
    });

    if (!response.ok) {
      throw new Error(`Failed to fetch JWKS from ${this.jwksUri}: ${response.status}`);
    }

    const jwks = (await response.json()) as JWKS;
    if (!jwks.keys || !Array.isArray(jwks.keys)) {
      throw new Error('Invalid JWKS response: missing keys array');
    }

    return jwks;
  }

  private jwkToKeyObject(jwk: JWK): crypto.KeyObject {
    return crypto.createPublicKey({ key: jwk as crypto.JsonWebKey, format: 'jwk' });
  }
}

// ─── JWT Verification ────────────────────────────────────────────────────────

function decodeJWT(token: string): { header: JWTHeader; payload: JWTPayload; signature: string } {
  const parts = token.split('.');
  if (parts.length !== 3) {
    throw new AuthError('invalid_token', 'Malformed JWT: expected 3 parts');
  }

  try {
    const header = JSON.parse(Buffer.from(parts[0], 'base64url').toString()) as JWTHeader;
    const payload = JSON.parse(Buffer.from(parts[1], 'base64url').toString()) as JWTPayload;
    return { header, payload, signature: parts[2] };
  } catch {
    throw new AuthError('invalid_token', 'Malformed JWT: invalid base64url encoding');
  }
}

function verifySignature(token: string, key: crypto.KeyObject, algorithm: string): boolean {
  const [headerB64, payloadB64, signatureB64] = token.split('.');
  const data = `${headerB64}.${payloadB64}`;
  const signature = Buffer.from(signatureB64, 'base64url');

  const nodeAlg = algorithm === 'ES256' ? 'SHA256' : 'SHA256';
  const verifier = crypto.createVerify(nodeAlg);
  verifier.update(data);

  if (algorithm.startsWith('ES')) {
    return verifier.verify({ key, dsaEncoding: 'ieee-p1363' }, signature);
  }
  return verifier.verify(key, signature);
}

function validateClaims(
  payload: JWTPayload,
  config: OAuthMiddlewareConfig,
): void {
  const now = Math.floor(Date.now() / 1000);
  const tolerance = config.clockToleranceSec ?? 30;

  // Check expiration
  if (payload.exp !== undefined && now > payload.exp + tolerance) {
    throw new AuthError('invalid_token', 'Token has expired');
  }

  // Check not-before
  if (payload.nbf !== undefined && now < payload.nbf - tolerance) {
    throw new AuthError('invalid_token', 'Token is not yet valid');
  }

  // Check issuer
  if (payload.iss !== config.issuer) {
    throw new AuthError('invalid_token', `Invalid issuer: expected ${config.issuer}, got ${payload.iss}`);
  }

  // Check audience
  const audiences = Array.isArray(payload.aud) ? payload.aud : [payload.aud];
  if (!audiences.includes(config.audience)) {
    throw new AuthError('invalid_token', `Invalid audience: expected ${config.audience}`);
  }
}

// ─── Error Handling ──────────────────────────────────────────────────────────

class AuthError extends Error {
  constructor(
    public code: 'invalid_token' | 'invalid_request' | 'insufficient_scope',
    message: string,
  ) {
    super(message);
    this.name = 'AuthError';
  }

  get statusCode(): number {
    switch (this.code) {
      case 'invalid_request': return 400;
      case 'invalid_token': return 401;
      case 'insufficient_scope': return 403;
    }
  }

  toWWWAuthenticate(realm = 'api'): string {
    return `Bearer realm="${realm}", error="${this.code}", error_description="${this.message}"`;
  }
}

function sendAuthError(res: Response, error: AuthError): void {
  res
    .status(error.statusCode)
    .set('WWW-Authenticate', error.toWWWAuthenticate())
    .json({
      error: error.code,
      error_description: error.message,
    });
}

// ─── Middleware Factory ──────────────────────────────────────────────────────

export function createOAuthMiddleware(config: OAuthMiddlewareConfig): RequestHandler {
  const allowedAlgs = config.algorithms ?? ['RS256', 'ES256'];
  const jwksClient = new JWKSClient(config.jwksUri, config.jwksCacheTtlMs ?? 600_000);

  return async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    try {
      // Extract token from Authorization header
      const authHeader = req.headers.authorization;
      if (!authHeader) {
        throw new AuthError('invalid_request', 'Missing Authorization header');
      }

      const [scheme, token] = authHeader.split(' ', 2);
      if (scheme.toLowerCase() !== 'bearer' || !token) {
        throw new AuthError('invalid_request', 'Authorization header must use Bearer scheme');
      }

      // Decode and validate JWT
      const { header, payload } = decodeJWT(token);

      if (!allowedAlgs.includes(header.alg)) {
        throw new AuthError('invalid_token', `Unsupported algorithm: ${header.alg}`);
      }

      // Fetch the signing key
      const key = await jwksClient.getKey(header.kid);

      // Verify signature
      if (!verifySignature(token, key, header.alg)) {
        throw new AuthError('invalid_token', 'Invalid token signature');
      }

      // Validate standard claims
      validateClaims(payload, config);

      // Attach parsed token to request
      req.auth = payload;
      next();
    } catch (error) {
      if (error instanceof AuthError) {
        sendAuthError(res, error);
      } else {
        console.error('OAuth middleware error:', error);
        sendAuthError(res, new AuthError('invalid_token', 'Token validation failed'));
      }
    }
  };
}

// ─── Scope Authorization ─────────────────────────────────────────────────────

/**
 * Middleware that requires specific scopes on the validated token.
 * Must be used after createOAuthMiddleware().
 *
 * @param requiredScopes - Space-separated scope string or array of scopes (all required)
 */
export function requireScopes(...requiredScopes: string[]): RequestHandler {
  const required = requiredScopes.flatMap((s) => s.split(' '));

  return (req: Request, res: Response, next: NextFunction): void => {
    if (!req.auth) {
      sendAuthError(res, new AuthError('invalid_token', 'No authenticated token found'));
      return;
    }

    const tokenScopes = extractScopes(req.auth);
    const missing = required.filter((s) => !tokenScopes.has(s));

    if (missing.length > 0) {
      sendAuthError(
        res,
        new AuthError('insufficient_scope', `Missing required scopes: ${missing.join(', ')}`),
      );
      return;
    }

    next();
  };
}

/**
 * Middleware that requires at least one of the specified scopes.
 */
export function requireAnyScope(...scopes: string[]): RequestHandler {
  const required = scopes.flatMap((s) => s.split(' '));

  return (req: Request, res: Response, next: NextFunction): void => {
    if (!req.auth) {
      sendAuthError(res, new AuthError('invalid_token', 'No authenticated token found'));
      return;
    }

    const tokenScopes = extractScopes(req.auth);
    const hasAny = required.some((s) => tokenScopes.has(s));

    if (!hasAny) {
      sendAuthError(
        res,
        new AuthError('insufficient_scope', `Requires one of: ${required.join(', ')}`),
      );
      return;
    }

    next();
  };
}

function extractScopes(payload: JWTPayload): Set<string> {
  // Support both 'scope' (string) and 'permissions' (array) claims
  const scopes = new Set<string>();
  if (typeof payload.scope === 'string') {
    payload.scope.split(' ').forEach((s) => scopes.add(s));
  }
  if (Array.isArray(payload.permissions)) {
    payload.permissions.forEach((s) => scopes.add(s));
  }
  return scopes;
}
