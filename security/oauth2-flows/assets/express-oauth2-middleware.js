/**
 * express-oauth2-middleware.js — Express.js OAuth2/OIDC middleware using Passport
 *
 * Drop-in middleware for Express apps implementing OAuth2 Authorization Code + PKCE
 * with OpenID Connect. Supports Google, GitHub, Microsoft, and generic OIDC providers.
 *
 * Usage:
 *   const { setupAuth, requireAuth } = require('./express-oauth2-middleware');
 *
 *   setupAuth(app, {
 *     providers: {
 *       google: {
 *         clientID: process.env.GOOGLE_CLIENT_ID,
 *         clientSecret: process.env.GOOGLE_CLIENT_SECRET,
 *       },
 *     },
 *     sessionSecret: process.env.SESSION_SECRET,
 *     callbackBaseURL: 'https://app.example.com',
 *   });
 *
 *   app.get('/dashboard', requireAuth, (req, res) => {
 *     res.json({ user: req.user });
 *   });
 *
 * Dependencies:
 *   npm install express express-session passport passport-google-oauth20
 *   npm install passport-github2 passport-openidconnect
 */

const crypto = require("crypto");
const session = require("express-session");
const passport = require("passport");
const GoogleStrategy = require("passport-google-oauth20").Strategy;

// Optional providers — require only if installed
let GitHubStrategy, OIDCStrategy;
try {
  GitHubStrategy = require("passport-github2").Strategy;
} catch {}
try {
  OIDCStrategy = require("passport-openidconnect").Strategy;
} catch {}

/**
 * Set up OAuth2/OIDC authentication on an Express app.
 *
 * @param {import('express').Application} app
 * @param {Object} config
 * @param {Object} config.providers — Provider configurations
 * @param {string} config.sessionSecret — Session encryption secret
 * @param {string} config.callbackBaseURL — Base URL for callbacks (e.g., https://app.example.com)
 * @param {Function} [config.findOrCreateUser] — Custom user lookup/creation function
 * @param {Object} [config.sessionOptions] — Additional express-session options
 */
function setupAuth(app, config) {
  const {
    providers,
    sessionSecret,
    callbackBaseURL,
    findOrCreateUser,
    sessionOptions = {},
  } = config;

  // Session configuration with security defaults
  app.use(
    session({
      secret: sessionSecret,
      resave: false,
      saveUninitialized: false,
      name: "__session",
      cookie: {
        secure: process.env.NODE_ENV === "production",
        httpOnly: true,
        sameSite: "lax",
        maxAge: 24 * 60 * 60 * 1000, // 24 hours
      },
      ...sessionOptions,
    })
  );

  app.use(passport.initialize());
  app.use(passport.session());

  // Serialize/deserialize user
  passport.serializeUser((user, done) => done(null, user));
  passport.deserializeUser((user, done) => done(null, user));

  // Default user handler — normalizes profile across providers
  const userHandler =
    findOrCreateUser ||
    ((provider, profile, tokens) => ({
      id: profile.id,
      provider,
      email: profile.emails?.[0]?.value || null,
      name: profile.displayName || profile.username,
      picture:
        profile.photos?.[0]?.value || profile._json?.picture || null,
      raw: profile._json,
    }));

  // --- Google ---
  if (providers.google) {
    passport.use(
      new GoogleStrategy(
        {
          clientID: providers.google.clientID,
          clientSecret: providers.google.clientSecret,
          callbackURL: `${callbackBaseURL}/auth/google/callback`,
          scope: providers.google.scope || [
            "openid",
            "profile",
            "email",
          ],
          accessType: "offline",
          prompt: "consent",
          pkce: true,
          state: true,
        },
        (accessToken, refreshToken, profile, done) => {
          try {
            const user = userHandler("google", profile, {
              accessToken,
              refreshToken,
            });
            done(null, user);
          } catch (err) {
            done(err);
          }
        }
      )
    );

    app.get("/auth/google", passport.authenticate("google"));
    app.get(
      "/auth/google/callback",
      passport.authenticate("google", { failureRedirect: "/auth/error" }),
      (req, res) => res.redirect(req.session.returnTo || "/")
    );
  }

  // --- GitHub ---
  if (providers.github && GitHubStrategy) {
    passport.use(
      new GitHubStrategy(
        {
          clientID: providers.github.clientID,
          clientSecret: providers.github.clientSecret,
          callbackURL: `${callbackBaseURL}/auth/github/callback`,
          scope: providers.github.scope || ["read:user", "user:email"],
        },
        (accessToken, refreshToken, profile, done) => {
          try {
            const user = userHandler("github", profile, {
              accessToken,
              refreshToken,
            });
            done(null, user);
          } catch (err) {
            done(err);
          }
        }
      )
    );

    app.get("/auth/github", passport.authenticate("github"));
    app.get(
      "/auth/github/callback",
      passport.authenticate("github", { failureRedirect: "/auth/error" }),
      (req, res) => res.redirect(req.session.returnTo || "/")
    );
  }

  // --- Generic OIDC (Auth0, Keycloak, Okta, Microsoft Entra, etc.) ---
  if (providers.oidc && OIDCStrategy) {
    passport.use(
      "oidc",
      new OIDCStrategy(
        {
          issuer: providers.oidc.issuer,
          authorizationURL: providers.oidc.authorizationURL,
          tokenURL: providers.oidc.tokenURL,
          userInfoURL: providers.oidc.userInfoURL,
          clientID: providers.oidc.clientID,
          clientSecret: providers.oidc.clientSecret,
          callbackURL: `${callbackBaseURL}/auth/oidc/callback`,
          scope: providers.oidc.scope || "openid profile email",
          pkce: true,
          state: true,
        },
        (issuer, profile, context, idToken, accessToken, refreshToken, done) => {
          try {
            const user = userHandler("oidc", profile, {
              accessToken,
              refreshToken,
              idToken,
            });
            done(null, user);
          } catch (err) {
            done(err);
          }
        }
      )
    );

    app.get("/auth/oidc", passport.authenticate("oidc"));
    app.get(
      "/auth/oidc/callback",
      passport.authenticate("oidc", { failureRedirect: "/auth/error" }),
      (req, res) => res.redirect(req.session.returnTo || "/")
    );
  }

  // --- Shared routes ---

  app.get("/auth/me", (req, res) => {
    if (req.isAuthenticated()) {
      res.json({ authenticated: true, user: req.user });
    } else {
      res.status(401).json({ authenticated: false });
    }
  });

  app.post("/auth/logout", (req, res) => {
    req.logout((err) => {
      if (err) return res.status(500).json({ error: "Logout failed" });
      req.session.destroy(() => {
        res.clearCookie("__session");
        res.json({ success: true });
      });
    });
  });

  app.get("/auth/error", (req, res) => {
    res.status(401).json({ error: "Authentication failed" });
  });
}

/**
 * Middleware that requires authentication.
 * Redirects to login or returns 401 for API requests.
 */
function requireAuth(req, res, next) {
  if (req.isAuthenticated()) return next();

  // Store intended destination for post-login redirect
  req.session.returnTo = req.originalUrl;

  // API requests get 401; browser requests get redirected
  if (
    req.headers.accept?.includes("application/json") ||
    req.xhr
  ) {
    return res.status(401).json({ error: "Authentication required" });
  }
  return res.redirect("/auth/google"); // Default provider
}

/**
 * Middleware that requires specific roles/claims.
 * @param {...string} roles — Required roles
 */
function requireRole(...roles) {
  return (req, res, next) => {
    if (!req.isAuthenticated()) {
      return res.status(401).json({ error: "Authentication required" });
    }
    const userRoles = req.user.roles || [];
    const hasRole = roles.some((r) => userRoles.includes(r));
    if (!hasRole) {
      return res.status(403).json({ error: "Insufficient permissions" });
    }
    next();
  };
}

/**
 * CSRF protection middleware for state parameter validation.
 * Use this if you're building a custom OAuth flow without Passport.
 */
function generateOAuthState(req, res, next) {
  const state = crypto.randomBytes(32).toString("hex");
  req.session.oauthState = state;
  req.oauthState = state;
  next();
}

function validateOAuthState(req, res, next) {
  const { state } = req.query;
  if (!state || state !== req.session.oauthState) {
    delete req.session.oauthState;
    return res.status(403).json({ error: "Invalid state — CSRF detected" });
  }
  delete req.session.oauthState;
  next();
}

module.exports = {
  setupAuth,
  requireAuth,
  requireRole,
  generateOAuthState,
  validateOAuthState,
};
