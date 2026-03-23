# Review: go-api-patterns

Accuracy: 5/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 4/5
Overall: 4.75/5

Issues: Non-standard description format.

Excellent Go API skill covering net/http Go 1.22+ (method routing, path params, wildcards), router comparison (stdlib/chi/echo/gin), idiomatic project structure (cmd/internal layout), handler patterns (struct-based with Register method, generic request decoder), middleware (logging with statusWriter, request ID, recovery, auth, CORS, rate limiting, chaining), request validation (go-playground/validator), JSON handling, error handling (RFC 9457 ProblemDetail, errors.As), dependency injection (constructors, options pattern), graceful shutdown (signal.NotifyContext, srv.Shutdown with timeouts), testing (httptest, table-driven tests), configuration (caarlos0/env), and common patterns (health/ready checks, cursor pagination, API versioning with StripPrefix).
