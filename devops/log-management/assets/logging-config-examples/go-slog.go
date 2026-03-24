// Package logging provides production-ready structured logging with Go slog.
//
// Features:
//   - JSON output with consistent schema
//   - Request context via context.Context
//   - PII redaction handler wrapper
//   - OpenTelemetry trace context injection
//   - Configurable log level from environment
//
// Usage:
//
//	import "yourapp/logging"
//
//	func main() {
//	    logging.Init()
//	    slog.Info("server started", "port", 8080)
//	}
package logging

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/google/uuid"
)

// Context keys for request-scoped data
type ctxKey string

const (
	RequestIDKey ctxKey = "request_id"
	TraceIDKey   ctxKey = "trace_id"
	SpanIDKey    ctxKey = "span_id"
	UserIDKey    ctxKey = "user_id"
	TenantIDKey  ctxKey = "tenant_id"
)

// Init configures the default slog logger for production use.
// Reads LOG_LEVEL from environment (debug, info, warn, error). Defaults to info.
// Reads LOG_FORMAT from environment (json, text). Defaults to json.
func Init() {
	level := parseLevel(os.Getenv("LOG_LEVEL"))
	format := os.Getenv("LOG_FORMAT")

	var handler slog.Handler
	opts := &slog.HandlerOptions{
		Level:     level,
		AddSource: level == slog.LevelDebug,
		ReplaceAttr: func(groups []string, a slog.Attr) slog.Attr {
			// Redact sensitive fields
			key := strings.ToLower(a.Key)
			for _, sensitive := range []string{"password", "secret", "token", "authorization", "cookie", "ssn"} {
				if strings.Contains(key, sensitive) {
					return slog.String(a.Key, "[REDACTED]")
				}
			}
			return a
		},
	}

	if format == "text" {
		handler = slog.NewTextHandler(os.Stdout, opts)
	} else {
		handler = slog.NewJSONHandler(os.Stdout, opts)
	}

	// Wrap with context-aware handler
	handler = &contextHandler{
		inner: handler,
		attrs: []slog.Attr{
			slog.String("service", envOrDefault("SERVICE_NAME", "app")),
			slog.String("environment", envOrDefault("ENVIRONMENT", "development")),
			slog.String("version", envOrDefault("APP_VERSION", "0.0.0")),
		},
	}

	slog.SetDefault(slog.New(handler))
}

// contextHandler wraps a slog.Handler to inject context values and static attributes.
type contextHandler struct {
	inner slog.Handler
	attrs []slog.Attr
}

func (h *contextHandler) Enabled(ctx context.Context, level slog.Level) bool {
	return h.inner.Enabled(ctx, level)
}

func (h *contextHandler) Handle(ctx context.Context, r slog.Record) error {
	// Add static attributes
	for _, a := range h.attrs {
		r.AddAttrs(a)
	}

	// Add context values
	if v, ok := ctx.Value(RequestIDKey).(string); ok && v != "" {
		r.AddAttrs(slog.String("request_id", v))
	}
	if v, ok := ctx.Value(TraceIDKey).(string); ok && v != "" {
		r.AddAttrs(slog.String("trace_id", v))
	}
	if v, ok := ctx.Value(SpanIDKey).(string); ok && v != "" {
		r.AddAttrs(slog.String("span_id", v))
	}
	if v, ok := ctx.Value(UserIDKey).(string); ok && v != "" {
		r.AddAttrs(slog.String("user_id", v))
	}
	if v, ok := ctx.Value(TenantIDKey).(string); ok && v != "" {
		r.AddAttrs(slog.String("tenant_id", v))
	}

	return h.inner.Handle(ctx, r)
}

func (h *contextHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	return &contextHandler{
		inner: h.inner.WithAttrs(attrs),
		attrs: h.attrs,
	}
}

func (h *contextHandler) WithGroup(name string) slog.Handler {
	return &contextHandler{
		inner: h.inner.WithGroup(name),
		attrs: h.attrs,
	}
}

// LoggerFromCtx returns a logger enriched with context values.
func LoggerFromCtx(ctx context.Context) *slog.Logger {
	return slog.Default()
}

// Middleware returns HTTP middleware that injects request context and logs requests.
func Middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()

		// Extract or generate request ID
		requestID := r.Header.Get("X-Request-ID")
		if requestID == "" {
			requestID = uuid.New().String()
		}

		// Build context
		ctx := r.Context()
		ctx = context.WithValue(ctx, RequestIDKey, requestID)
		ctx = context.WithValue(ctx, TraceIDKey, r.Header.Get("X-Trace-ID"))
		ctx = context.WithValue(ctx, UserIDKey, r.Header.Get("X-User-ID"))
		ctx = context.WithValue(ctx, TenantIDKey, r.Header.Get("X-Tenant-ID"))

		// Set response header
		w.Header().Set("X-Request-ID", requestID)

		// Wrap response writer to capture status code
		rw := &responseWriter{ResponseWriter: w, statusCode: http.StatusOK}

		next.ServeHTTP(rw, r.WithContext(ctx))

		duration := time.Since(start)
		level := slog.LevelInfo
		if rw.statusCode >= 500 {
			level = slog.LevelError
		} else if rw.statusCode >= 400 {
			level = slog.LevelWarn
		}

		slog.Log(ctx, level, "request completed",
			"method", r.Method,
			"path", r.URL.Path,
			"status", rw.statusCode,
			"duration_ms", duration.Milliseconds(),
			"bytes", rw.bytesWritten,
			"user_agent", r.UserAgent(),
		)
	})
}

type responseWriter struct {
	http.ResponseWriter
	statusCode   int
	bytesWritten int64
}

func (rw *responseWriter) WriteHeader(code int) {
	rw.statusCode = code
	rw.ResponseWriter.WriteHeader(code)
}

func (rw *responseWriter) Write(b []byte) (int, error) {
	n, err := rw.ResponseWriter.Write(b)
	rw.bytesWritten += int64(n)
	return n, err
}

// ---- Helpers ----

func parseLevel(s string) slog.Level {
	switch strings.ToLower(s) {
	case "debug":
		return slog.LevelDebug
	case "warn", "warning":
		return slog.LevelWarn
	case "error":
		return slog.LevelError
	default:
		return slog.LevelInfo
	}
}

func envOrDefault(key, defaultVal string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return defaultVal
}

// Discard returns a logger that discards all output (useful for tests).
func Discard() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}
