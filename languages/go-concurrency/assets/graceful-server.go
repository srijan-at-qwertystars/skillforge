// graceful-server.go — HTTP server with graceful shutdown, signal handling,
// connection draining, health check endpoint, and request timeout middleware.
//
// Usage:
//   Copy into your project, customize routes in setupRoutes(), and run:
//     go run graceful-server.go
//
//   Test graceful shutdown:
//     curl http://localhost:8080/health
//     kill -SIGTERM <pid>

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	_ "net/http/pprof"
	"os"
	"os/signal"
	"runtime"
	"sync/atomic"
	"syscall"
	"time"
)

// --- Server ---

type Server struct {
	httpServer *http.Server
	logger     *slog.Logger
	healthy    atomic.Bool
	inflight   atomic.Int64
	startTime  time.Time
}

func NewServer(addr string, logger *slog.Logger) *Server {
	s := &Server{
		logger:    logger,
		startTime: time.Now(),
	}

	mux := http.NewServeMux()
	s.setupRoutes(mux)

	s.httpServer = &http.Server{
		Addr:         addr,
		Handler:      s.middleware(mux),
		ReadTimeout:  15 * time.Second,
		WriteTimeout: 30 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	return s
}

func (s *Server) setupRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /health", s.handleHealth)
	mux.HandleFunc("GET /ready", s.handleReady)
	mux.HandleFunc("GET /metrics", s.handleMetrics)

	// Add your application routes here:
	// mux.HandleFunc("GET /api/v1/resource", s.handleGetResource)
	// mux.HandleFunc("POST /api/v1/resource", s.handleCreateResource)
}

// --- Middleware Chain ---

func (s *Server) middleware(next http.Handler) http.Handler {
	// Applied in reverse order (outermost first)
	h := next
	h = s.recoverMiddleware(h)
	h = s.requestTimeoutMiddleware(10*time.Second)(h)
	h = s.inflightTrackingMiddleware(h)
	h = s.requestLoggingMiddleware(h)
	return h
}

// requestTimeoutMiddleware adds a timeout to each request's context.
func (s *Server) requestTimeoutMiddleware(timeout time.Duration) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			ctx, cancel := context.WithTimeout(r.Context(), timeout)
			defer cancel()
			next.ServeHTTP(w, r.WithContext(ctx))
		})
	}
}

// inflightTrackingMiddleware tracks the number of in-flight requests.
func (s *Server) inflightTrackingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		s.inflight.Add(1)
		defer s.inflight.Add(-1)
		next.ServeHTTP(w, r)
	})
}

// requestLoggingMiddleware logs request method, path, status, and duration.
func (s *Server) requestLoggingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rw := &responseWriter{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rw, r)
		s.logger.Info("request",
			"method", r.Method,
			"path", r.URL.Path,
			"status", rw.status,
			"duration", time.Since(start).String(),
			"inflight", s.inflight.Load(),
		)
	})
}

// recoverMiddleware recovers from panics and returns 500.
func (s *Server) recoverMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if err := recover(); err != nil {
				s.logger.Error("panic recovered",
					"error", fmt.Sprintf("%v", err),
					"path", r.URL.Path,
				)
				http.Error(w, "Internal Server Error", http.StatusInternalServerError)
			}
		}()
		next.ServeHTTP(w, r)
	})
}

// responseWriter wraps http.ResponseWriter to capture status code.
type responseWriter struct {
	http.ResponseWriter
	status int
}

func (rw *responseWriter) WriteHeader(code int) {
	rw.status = code
	rw.ResponseWriter.WriteHeader(code)
}

// --- Handlers ---

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	if !s.healthy.Load() {
		http.Error(w, "not healthy", http.StatusServiceUnavailable)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{
		"status": "healthy",
		"uptime": time.Since(s.startTime).String(),
	})
}

func (s *Server) handleReady(w http.ResponseWriter, r *http.Request) {
	if !s.healthy.Load() {
		http.Error(w, "not ready", http.StatusServiceUnavailable)
		return
	}
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("ready"))
}

func (s *Server) handleMetrics(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{
		"uptime_seconds": time.Since(s.startTime).Seconds(),
		"inflight":       s.inflight.Load(),
		"goroutines":     runtime.NumGoroutine(),
		"gomaxprocs":     runtime.GOMAXPROCS(0),
	})
}

// --- Lifecycle ---

// Run starts the server and blocks until shutdown is complete.
func (s *Server) Run(ctx context.Context) error {
	// Mark as healthy
	s.healthy.Store(true)

	// Start pprof server on separate port for profiling
	go func() {
		pprofServer := &http.Server{Addr: ":6060", Handler: nil}
		if err := pprofServer.ListenAndServe(); err != http.ErrServerClosed {
			s.logger.Error("pprof server error", "error", err)
		}
	}()

	// Start main server
	errCh := make(chan error, 1)
	go func() {
		s.logger.Info("server starting", "addr", s.httpServer.Addr)
		if err := s.httpServer.ListenAndServe(); err != http.ErrServerClosed {
			errCh <- err
		}
		close(errCh)
	}()

	// Wait for shutdown signal or server error
	select {
	case err := <-errCh:
		return fmt.Errorf("server error: %w", err)
	case <-ctx.Done():
	}

	return s.shutdown()
}

func (s *Server) shutdown() error {
	s.logger.Info("initiating graceful shutdown...")

	// 1. Mark as unhealthy (load balancer stops sending traffic)
	s.healthy.Store(false)
	s.logger.Info("marked unhealthy, waiting for load balancer to drain...")
	time.Sleep(2 * time.Second) // allow LB health checks to fail

	// 2. Gracefully shut down HTTP server (stops accepting, drains connections)
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	s.logger.Info("shutting down HTTP server",
		"inflight", s.inflight.Load(),
	)
	if err := s.httpServer.Shutdown(shutdownCtx); err != nil {
		return fmt.Errorf("shutdown error: %w", err)
	}

	// 3. Wait for in-flight requests to complete
	deadline := time.After(10 * time.Second)
	for s.inflight.Load() > 0 {
		select {
		case <-deadline:
			s.logger.Warn("force stopping with inflight requests",
				"remaining", s.inflight.Load(),
			)
			return nil
		case <-time.After(100 * time.Millisecond):
		}
	}

	s.logger.Info("shutdown complete")
	return nil
}

// --- Main ---

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	}))

	srv := NewServer(":8080", logger)

	// Listen for interrupt signals
	ctx, stop := signal.NotifyContext(context.Background(),
		os.Interrupt,
		syscall.SIGTERM,
	)
	defer stop()

	if err := srv.Run(ctx); err != nil {
		logger.Error("server failed", "error", err)
		os.Exit(1)
	}
}
