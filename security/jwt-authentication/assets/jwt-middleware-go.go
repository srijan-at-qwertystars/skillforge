/*
Package jwtmiddleware provides production-ready HTTP middleware for JWT
authentication in Go services.

Features:
  - JWKS endpoint support with automatic caching and rotation
  - Algorithm pinning (RS256) to prevent algorithm confusion attacks
  - Standard claim validations: exp, nbf, iss, aud
  - Context-based user propagation (request-scoped)
  - Pluggable token blocklist for revocation support
  - Well-structured error responses

Dependencies:
  go get github.com/golang-jwt/jwt/v5
  go get github.com/MicahParks/keyfunc/v3
*/
package jwtmiddleware

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/MicahParks/keyfunc/v3"
	"github.com/golang-jwt/jwt/v5"
)

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

// AuthUser holds the claims extracted from a verified JWT.
type AuthUser struct {
	// Sub is the subject – typically the user ID.
	Sub string `json:"sub"`
	// Iss is the issuer that minted the token.
	Iss string `json:"iss"`
	// Aud contains the audience(s) the token was issued for.
	Aud []string `json:"aud"`
	// Exp is the expiration time (Unix seconds).
	Exp int64 `json:"exp"`
	// Iat is the issued-at time (Unix seconds).
	Iat int64 `json:"iat"`
	// Scopes contains the permissions / scopes (if present).
	Scopes []string `json:"scopes,omitempty"`
	// RawClaims holds the full set of token claims.
	RawClaims jwt.MapClaims `json:"-"`
}

// contextKey is an unexported type to prevent collisions in context values.
type contextKey string

const userContextKey contextKey = "auth_user"

// UserFromContext extracts the authenticated AuthUser from the request context.
// Returns nil if no user is present (i.e., the middleware did not run or auth failed).
func UserFromContext(ctx context.Context) *AuthUser {
	u, _ := ctx.Value(userContextKey).(*AuthUser)
	return u
}

// BlocklistChecker is a function that returns true if a token (by its JTI) is revoked.
type BlocklistChecker func(ctx context.Context, jti string) (bool, error)

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

// Config holds the settings for the JWT middleware.
type Config struct {
	// JWKSUri is the URL of the JWKS endpoint.
	JWKSUri string
	// Issuer is the expected "iss" claim value.
	Issuer string
	// Audience is the expected "aud" claim value.
	Audience string
	// Algorithms lists the allowed signing algorithms. Defaults to ["RS256"].
	Algorithms []string
	// JWKSCacheTTL controls how frequently the JWKS is refreshed. Defaults to 10 minutes.
	JWKSCacheTTL time.Duration
	// IsRevoked is an optional callback for token blocklist checking.
	IsRevoked BlocklistChecker
	// Logger is an optional structured logger. Defaults to slog.Default().
	Logger *slog.Logger
}

func (c *Config) defaults() {
	if len(c.Algorithms) == 0 {
		c.Algorithms = []string{"RS256"}
	}
	if c.JWKSCacheTTL == 0 {
		c.JWKSCacheTTL = 10 * time.Minute
	}
	if c.Logger == nil {
		c.Logger = slog.Default()
	}
}

// ---------------------------------------------------------------------------
// Middleware
// ---------------------------------------------------------------------------

// JWTMiddleware verifies JWTs on incoming HTTP requests using a remote JWKS.
type JWTMiddleware struct {
	cfg  Config
	jwks keyfunc.Keyfunc
}

// New creates a new JWTMiddleware. It starts a background goroutine that
// periodically refreshes the JWKS from the configured endpoint.
//
// Usage:
//
//	mw, err := jwtmiddleware.New(jwtmiddleware.Config{
//	    JWKSUri:  "https://auth.example.com/.well-known/jwks.json",
//	    Issuer:   "https://auth.example.com/",
//	    Audience: "my-api",
//	})
//	if err != nil {
//	    log.Fatal(err)
//	}
//	defer mw.Close()
//
//	mux := http.NewServeMux()
//	mux.Handle("/api/", mw.Handler(apiHandler))
func New(cfg Config) (*JWTMiddleware, error) {
	cfg.defaults()

	// keyfunc manages fetching, caching, and rotating JWKS keys automatically.
	k, err := keyfunc.NewDefault([]string{cfg.JWKSUri})
	if err != nil {
		return nil, fmt.Errorf("jwtmiddleware: failed to initialise JWKS client: %w", err)
	}

	return &JWTMiddleware{cfg: cfg, jwks: k}, nil
}

// Close shuts down the background JWKS refresh goroutine.
func (m *JWTMiddleware) Close() {
	m.jwks.End()
}

// Handler wraps an http.Handler with JWT authentication.
func (m *JWTMiddleware) Handler(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		user, err := m.authenticate(r)
		if err != nil {
			m.writeError(w, err)
			return
		}
		// Propagate the authenticated user via the request context.
		ctx := context.WithValue(r.Context(), userContextKey, user)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

// HandlerFunc is a convenience wrapper for http.HandlerFunc.
func (m *JWTMiddleware) HandlerFunc(next http.HandlerFunc) http.Handler {
	return m.Handler(next)
}

// ---------------------------------------------------------------------------
// Authentication logic
// ---------------------------------------------------------------------------

// authError carries an HTTP status code alongside the error message.
type authError struct {
	Status  int    `json:"-"`
	Code    string `json:"error"`
	Message string `json:"message"`
}

func (e *authError) Error() string { return e.Message }

func unauthorized(msg string) *authError {
	return &authError{Status: http.StatusUnauthorized, Code: "unauthorized", Message: msg}
}

func forbidden(msg string) *authError {
	return &authError{Status: http.StatusForbidden, Code: "forbidden", Message: msg}
}

func (m *JWTMiddleware) authenticate(r *http.Request) (*AuthUser, *authError) {
	// 1. Extract the Bearer token.
	authHeader := r.Header.Get("Authorization")
	if authHeader == "" {
		return nil, unauthorized("Missing Authorization header")
	}
	parts := strings.SplitN(authHeader, " ", 2)
	if len(parts) != 2 || !strings.EqualFold(parts[0], "bearer") {
		return nil, unauthorized("Authorization header must use Bearer scheme")
	}
	rawToken := parts[1]

	// 2. Parse and verify the token.
	parserOpts := []jwt.ParserOption{
		jwt.WithIssuer(m.cfg.Issuer),
		jwt.WithAudience(m.cfg.Audience),
		jwt.WithValidMethods(m.cfg.Algorithms),
		jwt.WithExpirationRequired(),
		jwt.WithIssuedAt(),
	}

	token, err := jwt.Parse(rawToken, m.jwks.KeyfuncCtx(r.Context()), parserOpts...)
	if err != nil {
		m.cfg.Logger.Warn("JWT verification failed", "error", err)
		return nil, unauthorized(fmt.Sprintf("Invalid token: %v", err))
	}

	claims, ok := token.Claims.(jwt.MapClaims)
	if !ok || !token.Valid {
		return nil, unauthorized("Invalid token claims")
	}

	// 3. Extract the subject (required).
	sub, _ := claims.GetSubject()
	if sub == "" {
		return nil, unauthorized("Token missing required 'sub' claim")
	}

	// 4. Check the blocklist (if configured).
	if m.cfg.IsRevoked != nil {
		if jti, ok := claims["jti"].(string); ok && jti != "" {
			revoked, err := m.cfg.IsRevoked(r.Context(), jti)
			if err != nil {
				m.cfg.Logger.Error("Blocklist check failed", "error", err)
				return nil, unauthorized("Unable to verify token status")
			}
			if revoked {
				return nil, unauthorized("Token has been revoked")
			}
		}
	}

	// 5. Build the AuthUser.
	user := buildUser(claims, sub)
	return user, nil
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

func buildUser(claims jwt.MapClaims, sub string) *AuthUser {
	iss, _ := claims.GetIssuer()
	aud, _ := claims.GetAudience()

	var exp, iat int64
	if e, _ := claims.GetExpirationTime(); e != nil {
		exp = e.Unix()
	}
	if i, _ := claims.GetIssuedAt(); i != nil {
		iat = i.Unix()
	}

	return &AuthUser{
		Sub:       sub,
		Iss:       iss,
		Aud:       aud,
		Exp:       exp,
		Iat:       iat,
		Scopes:    extractScopes(claims),
		RawClaims: claims,
	}
}

// extractScopes handles both space-delimited strings and JSON arrays.
func extractScopes(claims jwt.MapClaims) []string {
	raw, ok := claims["scope"]
	if !ok {
		raw, ok = claims["scopes"]
		if !ok {
			return nil
		}
	}

	switch v := raw.(type) {
	case string:
		parts := strings.Fields(v)
		return parts
	case []interface{}:
		out := make([]string, 0, len(v))
		for _, item := range v {
			if s, ok := item.(string); ok {
				out = append(out, s)
			}
		}
		return out
	default:
		return nil
	}
}

func (m *JWTMiddleware) writeError(w http.ResponseWriter, err *authError) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("WWW-Authenticate", `Bearer realm="api"`)
	w.WriteHeader(err.Status)
	_ = json.NewEncoder(w).Encode(err)
}

// ---------------------------------------------------------------------------
// RequireScopes middleware
// ---------------------------------------------------------------------------

// RequireScopes returns middleware that ensures the authenticated user possesses
// all of the given scopes. Must be chained after JWTMiddleware.Handler.
//
// Usage:
//
//	mux.Handle("/api/admin", mw.Handler(
//	    jwtmiddleware.RequireScopes("admin")(adminHandler),
//	))
func RequireScopes(required ...string) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			user := UserFromContext(r.Context())
			if user == nil {
				writeJSONError(w, http.StatusUnauthorized, "unauthorized", "Authentication required")
				return
			}

			scopeSet := make(map[string]struct{}, len(user.Scopes))
			for _, s := range user.Scopes {
				scopeSet[s] = struct{}{}
			}

			var missing []string
			for _, s := range required {
				if _, ok := scopeSet[s]; !ok {
					missing = append(missing, s)
				}
			}

			if len(missing) > 0 {
				msg := fmt.Sprintf("Insufficient scope. Missing: %s", strings.Join(missing, ", "))
				writeJSONError(w, http.StatusForbidden, "forbidden", msg)
				return
			}

			next.ServeHTTP(w, r)
		})
	}
}

func writeJSONError(w http.ResponseWriter, status int, code, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]string{
		"error":   code,
		"message": message,
	})
}
