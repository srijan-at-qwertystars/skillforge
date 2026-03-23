---
name: go-api-patterns
description:
  positive: "Use when user builds HTTP APIs in Go, asks about net/http, http.ServeMux (Go 1.22+), chi/echo/gin routers, middleware, graceful shutdown, request validation, or Go API project structure."
  negative: "Do NOT use for Go concurrency (use go-concurrency-patterns skill), gRPC (use grpc-protobuf skill), or general Go syntax."
---

# Go HTTP API Patterns

## Standard Library: net/http (Go 1.22+)

Go 1.22 enhanced `http.ServeMux` with method-based routing and path parameters. Prefer stdlib for most APIs.

```go
mux := http.NewServeMux()
mux.HandleFunc("GET /posts/{id}", getPost)     // Method routing — 405 auto for wrong methods
mux.HandleFunc("POST /posts", createPost)
mux.HandleFunc("DELETE /posts/{id}", deletePost)
mux.HandleFunc("GET /files/{path...}", serveFile) // Wildcard: capture remainder

func getPost(w http.ResponseWriter, r *http.Request) {
    id := r.PathValue("id") // Extract path parameter
}
```

- Most-specific pattern wins: `"GET /posts/latest"` beats `"GET /posts/{id}"`.
- Trailing slash `"GET /posts/"` matches subtree; no slash matches exact path.

---

## Router Comparison

| Feature | stdlib (1.22+) | chi | echo | gin |
|---------|---------------|-----|------|-----|
| Method routing | ✅ | ✅ | ✅ | ✅ |
| Path params | `{id}` | `{id}` | `:id` | `:id` |
| Route groups | ❌ | ✅ | ✅ | ✅ |
| Middleware chain | Manual | ✅ | ✅ | ✅ |
| net/http compat | Native | ✅ | Adapter | Adapter |
| Dependencies | Zero | Minimal | Moderate | Moderate |

### When to use which

- **stdlib**: Sufficient for most APIs. Zero dependencies. Use when you want simplicity.
- **chi**: Idiomatic Go. Uses `http.Handler` natively. Best for composable middleware and route groups without framework lock-in.
- **echo**: Richer built-in features (validation, binding, WebSockets). Good for teams wanting batteries-included.
- **gin**: Largest ecosystem. Fast radix-tree routing. Good default for teams already familiar with it.

---

## Project Structure

```
myapi/
├── cmd/api/main.go              # Wiring: config, DI, server start
├── internal/
│   ├── config/config.go         # Env/file config loading
│   ├── handler/user.go          # HTTP handlers (thin: parse, validate, delegate)
│   ├── service/user.go          # Business logic
│   ├── repository/user.go       # Data access (DB queries)
│   ├── model/user.go            # Domain types
│   └── middleware/logging.go    # Middleware
├── api/                         # OpenAPI specs
├── migrations/                  # SQL migrations
└── go.mod
```

- `cmd/` contains only main packages. Keep `main.go` minimal — wiring only.
- `internal/` prevents external imports. Handlers → services → repository interfaces.

---

## Handler Patterns

```go
type UserHandler struct {
    svc service.UserService
}

func NewUserHandler(svc service.UserService) *UserHandler {
    return &UserHandler{svc: svc}
}

func (h *UserHandler) Register(mux *http.ServeMux) {
    mux.HandleFunc("GET /users/{id}", h.Get)
    mux.HandleFunc("POST /users", h.Create)
}

func (h *UserHandler) Get(w http.ResponseWriter, r *http.Request) {
    id := r.PathValue("id")
    user, err := h.svc.GetByID(r.Context(), id)
    if err != nil {
        writeError(w, err)
        return
    }
    writeJSON(w, http.StatusOK, user)
}
```

### Generic request decoder

```go
func decode[T any](r *http.Request) (T, error) {
    var v T
    if err := json.NewDecoder(r.Body).Decode(&v); err != nil {
        return v, fmt.Errorf("decode json: %w", err)
    }
    return v, nil
}
```

---

## Middleware

Middleware signature: `func(http.Handler) http.Handler`.

### Logging

```go
func Logging(logger *slog.Logger) func(http.Handler) http.Handler {
    return func(next http.Handler) http.Handler {
        return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
            start := time.Now()
            ww := &statusWriter{ResponseWriter: w, status: 200}
            next.ServeHTTP(ww, r)
            logger.Info("request", "method", r.Method, "path", r.URL.Path,
                "status", ww.status, "duration", time.Since(start))
        })
    }
}

type statusWriter struct {
    http.ResponseWriter
    status int
}

func (w *statusWriter) WriteHeader(code int) { w.status = code; w.ResponseWriter.WriteHeader(code) }
```

### Request ID

```go
func RequestID(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        id := r.Header.Get("X-Request-ID")
        if id == "" {
            id = uuid.NewString()
        }
        ctx := context.WithValue(r.Context(), requestIDKey, id)
        w.Header().Set("X-Request-ID", id)
        next.ServeHTTP(w, r.WithContext(ctx))
    })
}
```

### Recovery

```go
func Recovery(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        defer func() {
            if v := recover(); v != nil {
                slog.Error("panic", "error", v, "stack", string(debug.Stack()))
                http.Error(w, "internal server error", 500)
            }
        }()
        next.ServeHTTP(w, r)
    })
}
```

### Auth

```go
func Auth(verify func(string) (Claims, error)) func(http.Handler) http.Handler {
    return func(next http.Handler) http.Handler {
        return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
            token := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
            claims, err := verify(token)
            if err != nil { writeError(w, ErrUnauthorized); return }
            ctx := context.WithValue(r.Context(), claimsKey, claims)
            next.ServeHTTP(w, r.WithContext(ctx))
        })
    }
}
```

### CORS

```go
func CORS(origin string) func(http.Handler) http.Handler {
    return func(next http.Handler) http.Handler {
        return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
            w.Header().Set("Access-Control-Allow-Origin", origin)
            w.Header().Set("Access-Control-Allow-Methods", "GET,POST,PUT,DELETE,OPTIONS")
            w.Header().Set("Access-Control-Allow-Headers", "Content-Type,Authorization")
            if r.Method == http.MethodOptions { w.WriteHeader(204); return }
            next.ServeHTTP(w, r)
        })
    }
}
```

### Rate limiting

```go
func RateLimit(rps int) func(http.Handler) http.Handler {
    limiter := rate.NewLimiter(rate.Limit(rps), rps)
    return func(next http.Handler) http.Handler {
        return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
            if !limiter.Allow() {
                writeProblem(w, http.StatusTooManyRequests, "rate limit exceeded")
                return
            }
            next.ServeHTTP(w, r)
        })
    }
}
```

### Chaining

```go
func Chain(mw ...func(http.Handler) http.Handler) func(http.Handler) http.Handler {
    return func(h http.Handler) http.Handler {
        for i := len(mw) - 1; i >= 0; i-- { h = mw[i](h) }
        return h
    }
}

stack := Chain(RequestID, Logging(logger), Recovery, CORS("*"), RateLimit(100), Auth(verify))
srv := &http.Server{Handler: stack(mux)}
```

---

## Request Validation

```go
import "github.com/go-playground/validator/v10"

var validate = validator.New()

type CreateUserRequest struct {
    Email string `json:"email" validate:"required,email"`
    Name  string `json:"name"  validate:"required,min=1,max=100"`
    Age   int    `json:"age"   validate:"omitempty,gte=0,lte=150"`
}

func (h *UserHandler) Create(w http.ResponseWriter, r *http.Request) {
    req, err := decode[CreateUserRequest](r)
    if err != nil {
        writeProblem(w, http.StatusBadRequest, "invalid JSON body")
        return
    }
    if err := validate.Struct(req); err != nil {
        writeProblem(w, http.StatusUnprocessableEntity, formatValidationErrors(err))
        return
    }
    // proceed
}
```

---

## JSON Handling

```go
func writeJSON(w http.ResponseWriter, status int, v any) {
    w.Header().Set("Content-Type", "application/json")
    w.WriteHeader(status)
    if err := json.NewEncoder(w).Encode(v); err != nil {
        slog.Error("encode response", "error", err)
    }
}
```

Implement `json.Marshaler`/`json.Unmarshaler` for custom serialization (e.g., unix timestamps, enums).

---

## Error Handling

### Error types and ProblemDetail (RFC 9457)

```go
type AppError struct {
    Type   string `json:"type"`
    Title  string `json:"title"`
    Status int    `json:"status"`
    Detail string `json:"detail"`
}

func (e *AppError) Error() string { return e.Detail }

var (
    ErrNotFound     = &AppError{Type: "about:blank", Title: "Not Found", Status: 404}
    ErrUnauthorized = &AppError{Type: "about:blank", Title: "Unauthorized", Status: 401}
)

func writeProblem(w http.ResponseWriter, status int, detail string) {
    w.Header().Set("Content-Type", "application/problem+json")
    w.WriteHeader(status)
    json.NewEncoder(w).Encode(AppError{
        Type: "about:blank", Title: http.StatusText(status), Status: status, Detail: detail,
    })
}

func writeError(w http.ResponseWriter, err error) {
    var appErr *AppError
    if errors.As(err, &appErr) {
        w.Header().Set("Content-Type", "application/problem+json")
        w.WriteHeader(appErr.Status)
        json.NewEncoder(w).Encode(appErr)
        return
    }
    writeProblem(w, http.StatusInternalServerError, "internal error")
}
```

---

## Dependency Injection

Wire dependencies via constructors in `main.go`. Use the options pattern for configurable components:

```go
// main.go
func main() {
    cfg := config.Load()
    db := connectDB(cfg)
    userRepo := repository.NewUserRepo(db)
    userSvc := service.NewUserService(userRepo)
    handler.NewUserHandler(userSvc).Register(mux)
}

// Options pattern
type ServerOption func(*http.Server)

func WithReadTimeout(d time.Duration) ServerOption {
    return func(s *http.Server) { s.ReadTimeout = d }
}

func NewServer(addr string, h http.Handler, opts ...ServerOption) *http.Server {
    srv := &http.Server{Addr: addr, Handler: h}
    for _, o := range opts { o(srv) }
    return srv
}
```

---

## Graceful Shutdown

```go
func main() {
    mux := http.NewServeMux()
    // register routes...

    srv := &http.Server{
        Addr: ":8080", Handler: mux,
        ReadTimeout: 15 * time.Second, WriteTimeout: 15 * time.Second, IdleTimeout: 60 * time.Second,
    }

    go func() {
        if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
            slog.Error("server error", "error", err)
            os.Exit(1)
        }
    }()

    ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
    defer stop()
    <-ctx.Done()

    shutdownCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
    defer cancel()
    if err := srv.Shutdown(shutdownCtx); err != nil {
        slog.Error("shutdown error", "error", err)
    }
    // Close DB, flush logs here
}
```

- `signal.NotifyContext` cancels context on SIGINT/SIGTERM.
- `srv.Shutdown` stops accepting connections, drains in-flight requests up to timeout.
- Always set `ReadTimeout`, `WriteTimeout`, `IdleTimeout` to prevent resource leaks.

---

## Testing HTTP Handlers

```go
func TestGetUser(t *testing.T) {
    mockSvc := &mockUserService{
        getByID: func(ctx context.Context, id string) (*model.User, error) {
            if id == "123" { return &model.User{ID: "123", Name: "Alice"}, nil }
            return nil, ErrNotFound
        },
    }
    h := handler.NewUserHandler(mockSvc)
    tests := []struct {
        name       string
        path       string
        wantStatus int
        wantBody   string
    }{
        {"found", "/users/123", 200, `"Alice"`},
        {"not found", "/users/999", 404, `"Not Found"`},
    }
    for _, tc := range tests {
        t.Run(tc.name, func(t *testing.T) {
            req := httptest.NewRequest("GET", tc.path, nil)
            rec := httptest.NewRecorder()
            mux := http.NewServeMux()
            h.Register(mux)
            mux.ServeHTTP(rec, req)
            if rec.Code != tc.wantStatus {
                t.Errorf("status = %d, want %d", rec.Code, tc.wantStatus)
            }
            if !strings.Contains(rec.Body.String(), tc.wantBody) {
                t.Errorf("body = %s, want substring %s", rec.Body.String(), tc.wantBody)
            }
        })
    }
}
```

Use `httptest.NewServer(handler)` for integration tests needing a real TCP listener. Define service interfaces for mockability.

---

## Configuration

```go
type Config struct {
    Port        string        `env:"PORT"         default:"8080"`
    DatabaseURL string        `env:"DATABASE_URL" required:"true"`
    ReadTimeout time.Duration `env:"READ_TIMEOUT" default:"15s"`
}

func Load() (*Config, error) {
    cfg := &Config{}
    if err := env.Parse(cfg); err != nil { return nil, err } // github.com/caarlos0/env/v11
    return cfg, nil
}
```

Libraries: **caarlos0/env** (struct tags, lightweight), **spf13/viper** (file+env+remote), **alecthomas/kong** (CLI+env).

---

## Common Patterns

### Health check

```go
mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
    writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
})
mux.HandleFunc("GET /ready", func(w http.ResponseWriter, r *http.Request) {
    if err := db.PingContext(r.Context()); err != nil {
        writeProblem(w, http.StatusServiceUnavailable, "database unavailable")
        return
    }
    writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
})
```

### Pagination

```go
func parsePagination(r *http.Request) (page, perPage int) {
    page, _ = strconv.Atoi(r.URL.Query().Get("page"))
    perPage, _ = strconv.Atoi(r.URL.Query().Get("per_page"))
    if page < 1 { page = 1 }
    if perPage < 1 || perPage > 100 { perPage = 20 }
    return
}

type PageResponse[T any] struct {
    Data  []T `json:"data"`
    Page  int `json:"page"`
    Total int `json:"total_count"`
}
```

### API versioning

```go
v1 := http.NewServeMux()
v1.HandleFunc("GET /users", listUsersV1)
v2 := http.NewServeMux()
v2.HandleFunc("GET /users", listUsersV2)
mux := http.NewServeMux()
mux.Handle("/v1/", http.StripPrefix("/v1", v1))
mux.Handle("/v2/", http.StripPrefix("/v2", v2))
```
