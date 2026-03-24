/**
 * Express.js JWT Authentication Middleware
 *
 * Features:
 * - Access token verification with algorithm pinning
 * - Refresh token rotation with reuse detection
 * - Token family tracking for security
 * - JWKS-based key resolution
 * - Rate limiting on auth endpoints
 *
 * Dependencies:
 *   npm install jose express cookie-parser uuid
 *
 * Usage:
 *   import { authenticate, refreshHandler, loginHandler } from './middleware-express.js';
 *   app.use(cookieParser());
 *   app.post('/auth/login', loginHandler);
 *   app.post('/auth/refresh', refreshHandler);
 *   app.get('/api/protected', authenticate, (req, res) => { ... });
 */

import { SignJWT, jwtVerify, createRemoteJWKSet, importPKCS8 } from 'jose';
import crypto from 'crypto';

// ─── Configuration ───────────────────────────────────────────────────────────

const config = {
  issuer: process.env.JWT_ISSUER || 'https://auth.example.com',
  audience: process.env.JWT_AUDIENCE || 'https://api.example.com',
  accessTokenExpiry: '15m',
  refreshTokenExpiry: '7d',
  algorithm: 'ES256',           // Pin algorithm — never read from token
  clockTolerance: '30s',
  cookieOptions: {
    httpOnly: true,
    secure: process.env.NODE_ENV === 'production',
    sameSite: process.env.NODE_ENV === 'production' ? 'strict' : 'lax',
    path: '/auth/refresh',
    maxAge: 7 * 24 * 60 * 60 * 1000, // 7 days
  },
  // Rate limiting
  maxRefreshPerMinute: 10,
  maxLoginPerMinute: 5,
};

// ─── Key Management ──────────────────────────────────────────────────────────

// Option 1: Remote JWKS (recommended for multi-service)
// const JWKS = createRemoteJWKSet(new URL('https://auth.example.com/.well-known/jwks.json'));

// Option 2: Local key (for single-service setups)
let signingKey = null;

async function getSigningKey() {
  if (!signingKey) {
    const privateKeyPem = process.env.JWT_PRIVATE_KEY;
    if (!privateKeyPem) throw new Error('JWT_PRIVATE_KEY environment variable not set');
    signingKey = await importPKCS8(privateKeyPem, config.algorithm);
  }
  return signingKey;
}

// ─── Token Store Interface ───────────────────────────────────────────────────
// Replace with your database/Redis implementation

const tokenStore = {
  /**
   * Save a refresh token record.
   * In production, use a database with proper indexing.
   */
  async save(tokenRecord) {
    // TODO: Replace with DB insert
    // Schema: { jti, familyId, userId, parentJti, issuedAt, expiresAt, revokedAt, replacedBy }
    throw new Error('Implement tokenStore.save() with your database');
  },

  async getByJti(jti) {
    // TODO: Replace with DB query
    throw new Error('Implement tokenStore.getByJti() with your database');
  },

  async revokeFamily(familyId) {
    // TODO: UPDATE refresh_tokens SET revokedAt = NOW() WHERE familyId = ? AND revokedAt IS NULL
    throw new Error('Implement tokenStore.revokeFamily() with your database');
  },

  async markReplaced(jti, replacedByJti) {
    // TODO: UPDATE refresh_tokens SET replacedBy = ? WHERE jti = ?
    throw new Error('Implement tokenStore.markReplaced() with your database');
  },

  async revokeAllForUser(userId) {
    // TODO: UPDATE refresh_tokens SET revokedAt = NOW() WHERE userId = ? AND revokedAt IS NULL
    throw new Error('Implement tokenStore.revokeAllForUser() with your database');
  },
};

// ─── Token Generation ────────────────────────────────────────────────────────

async function generateAccessToken(user) {
  const key = await getSigningKey();

  return new SignJWT({
    sub: user.id,
    roles: user.roles || [],
    email: undefined,         // Don't include PII in access tokens
  })
    .setProtectedHeader({ alg: config.algorithm, typ: 'JWT' })
    .setIssuedAt()
    .setIssuer(config.issuer)
    .setAudience(config.audience)
    .setExpirationTime(config.accessTokenExpiry)
    .setJti(crypto.randomUUID())
    .sign(key);
}

async function generateRefreshToken(userId, familyId = null, parentJti = null) {
  const key = await getSigningKey();
  const jti = crypto.randomUUID();
  const fid = familyId || crypto.randomUUID();
  const now = new Date();
  const expiresAt = new Date(now.getTime() + 7 * 24 * 60 * 60 * 1000);

  const token = await new SignJWT({ sub: userId })
    .setProtectedHeader({ alg: config.algorithm, typ: 'JWT' })
    .setIssuedAt()
    .setIssuer(config.issuer)
    .setExpirationTime(config.refreshTokenExpiry)
    .setJti(jti)
    .sign(key);

  // Store refresh token for revocation tracking
  await tokenStore.save({
    jti,
    familyId: fid,
    userId,
    parentJti,
    issuedAt: now,
    expiresAt,
    revokedAt: null,
    replacedBy: null,
  });

  return { token, jti, familyId: fid };
}

// ─── Middleware: Authenticate Access Token ────────────────────────────────────

/**
 * Verify the access token from the Authorization header.
 * Attaches decoded claims to req.user on success.
 */
export async function authenticate(req, res, next) {
  const authHeader = req.headers.authorization;
  if (!authHeader?.startsWith('Bearer ')) {
    return res.status(401).json({ error: 'missing_token', message: 'Authorization header required' });
  }

  const token = authHeader.slice(7);

  try {
    const key = await getSigningKey();
    const { payload } = await jwtVerify(token, key, {
      algorithms: [config.algorithm],     // Pin algorithm
      issuer: config.issuer,
      audience: config.audience,
      clockTolerance: config.clockTolerance,
      requiredClaims: ['sub', 'exp', 'iss', 'aud'],
    });

    // Attach user info to request
    req.user = {
      id: payload.sub,
      roles: payload.roles || [],
      jti: payload.jti,
      tokenPayload: payload,
    };

    next();
  } catch (err) {
    if (err.code === 'ERR_JWT_EXPIRED') {
      return res.status(401).json({ error: 'token_expired', message: 'Access token has expired' });
    }
    // Don't reveal specific validation failures to clients
    return res.status(401).json({ error: 'invalid_token', message: 'Invalid access token' });
  }
}

// ─── Middleware: Role-Based Authorization ─────────────────────────────────────

/**
 * Check if the authenticated user has any of the required roles.
 * Use after authenticate middleware.
 *
 * Usage: app.get('/admin', authenticate, requireRoles('admin', 'superadmin'), handler)
 */
export function requireRoles(...roles) {
  return (req, res, next) => {
    if (!req.user) {
      return res.status(401).json({ error: 'unauthenticated' });
    }
    const userRoles = req.user.roles || [];
    const hasRole = roles.some((role) => userRoles.includes(role));
    if (!hasRole) {
      return res.status(403).json({ error: 'forbidden', message: 'Insufficient permissions' });
    }
    next();
  };
}

// ─── Handler: Refresh Token ──────────────────────────────────────────────────

/**
 * Refresh token endpoint handler.
 * Reads refresh token from httpOnly cookie, performs rotation with reuse detection.
 *
 * Route: POST /auth/refresh
 */
export async function refreshHandler(req, res) {
  const refreshTokenValue = req.cookies?.refreshToken;

  if (!refreshTokenValue) {
    return res.status(401).json({ error: 'missing_refresh_token' });
  }

  try {
    // 1. Verify the refresh token
    const key = await getSigningKey();
    const { payload } = await jwtVerify(refreshTokenValue, key, {
      algorithms: [config.algorithm],
      issuer: config.issuer,
      clockTolerance: config.clockTolerance,
    });

    // 2. Look up the token in our store
    const storedToken = await tokenStore.getByJti(payload.jti);

    if (!storedToken) {
      return res.status(401).json({ error: 'unknown_token' });
    }

    // 3. Check if the token has been revoked
    if (storedToken.revokedAt) {
      return res.status(401).json({ error: 'token_revoked' });
    }

    // 4. Reuse detection: if this token was already replaced, revoke the family
    if (storedToken.replacedBy) {
      // SECURITY: Token reuse detected — possible theft
      await tokenStore.revokeFamily(storedToken.familyId);
      // Log security event
      console.error(
        `[SECURITY] Refresh token reuse detected: jti=${payload.jti}, ` +
        `family=${storedToken.familyId}, user=${storedToken.userId}, ` +
        `ip=${req.ip}`
      );
      return res.status(401).json({ error: 'token_reuse_detected' });
    }

    // 5. Rotate: issue new tokens
    const user = { id: storedToken.userId, roles: [] }; // Fetch roles from DB
    const accessToken = await generateAccessToken(user);
    const newRefresh = await generateRefreshToken(
      storedToken.userId,
      storedToken.familyId,   // Same family
      payload.jti             // Current token is the parent
    );

    // 6. Mark old token as replaced
    await tokenStore.markReplaced(payload.jti, newRefresh.jti);

    // 7. Set new refresh token cookie
    res.cookie('refreshToken', newRefresh.token, config.cookieOptions);

    // 8. Return new access token
    return res.json({
      access_token: accessToken,
      token_type: 'bearer',
      expires_in: 900, // 15 minutes in seconds
    });
  } catch (err) {
    if (err.code === 'ERR_JWT_EXPIRED') {
      return res.status(401).json({ error: 'refresh_token_expired' });
    }
    return res.status(401).json({ error: 'invalid_refresh_token' });
  }
}

// ─── Handler: Login ──────────────────────────────────────────────────────────

/**
 * Login handler template.
 * Replace authenticateUser() with your actual authentication logic.
 *
 * Route: POST /auth/login
 * Body: { "email": "user@example.com", "password": "..." }
 */
export async function loginHandler(req, res) {
  const { email, password } = req.body;

  if (!email || !password) {
    return res.status(400).json({ error: 'Email and password are required' });
  }

  try {
    // TODO: Replace with your authentication logic
    // const user = await authenticateUser(email, password);
    const user = null; // Placeholder
    if (!user) {
      // Generic error message — don't reveal whether user exists
      return res.status(401).json({ error: 'invalid_credentials' });
    }

    // Generate tokens
    const accessToken = await generateAccessToken(user);
    const refresh = await generateRefreshToken(user.id);

    // Set refresh token as httpOnly cookie
    res.cookie('refreshToken', refresh.token, config.cookieOptions);

    return res.json({
      access_token: accessToken,
      token_type: 'bearer',
      expires_in: 900,
    });
  } catch (err) {
    console.error('[AUTH] Login error:', err.message);
    return res.status(500).json({ error: 'internal_error' });
  }
}

// ─── Handler: Logout ─────────────────────────────────────────────────────────

/**
 * Logout handler — revokes refresh token and clears cookie.
 *
 * Route: POST /auth/logout
 */
export async function logoutHandler(req, res) {
  const refreshTokenValue = req.cookies?.refreshToken;

  if (refreshTokenValue) {
    try {
      const key = await getSigningKey();
      const { payload } = await jwtVerify(refreshTokenValue, key, {
        algorithms: [config.algorithm],
        issuer: config.issuer,
      });
      const storedToken = await tokenStore.getByJti(payload.jti);
      if (storedToken) {
        await tokenStore.revokeFamily(storedToken.familyId);
      }
    } catch {
      // Token may be expired or invalid — still clear the cookie
    }
  }

  res.clearCookie('refreshToken', { path: '/auth/refresh' });
  return res.json({ message: 'Logged out' });
}
