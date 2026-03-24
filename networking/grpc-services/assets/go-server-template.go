// Template: Production-ready Go gRPC server with interceptors, health check,
// reflection, and graceful shutdown.
//
// Replace "yourorg/yourproject" and service registration with your own.
//
// Usage:
//   go run main.go
//   go run main.go -addr :50051 -env production

package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"runtime/debug"
	"syscall"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/health"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/keepalive"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/reflection"
	"google.golang.org/grpc/status"

	// Import your generated proto package:
	// pb "github.com/yourorg/yourproject/gen/go/example/v1"
)

// --- Configuration ---

type Config struct {
	Addr string
	Env  string
}

func parseConfig() Config {
	cfg := Config{}
	flag.StringVar(&cfg.Addr, "addr", ":50051", "gRPC listen address")
	flag.StringVar(&cfg.Env, "env", "development", "environment (development|staging|production)")
	flag.Parse()
	return cfg
}

// --- Interceptors ---

// recoveryInterceptor catches panics and returns INTERNAL.
// MUST be the outermost interceptor.
func recoveryInterceptor(
	ctx context.Context,
	req any,
	info *grpc.UnaryServerInfo,
	handler grpc.UnaryHandler,
) (resp any, err error) {
	defer func() {
		if r := recover(); r != nil {
			log.Printf("PANIC in %s: %v\n%s", info.FullMethod, r, debug.Stack())
			err = status.Errorf(codes.Internal, "internal server error")
		}
	}()
	return handler(ctx, req)
}

// loggingInterceptor logs method, duration, and status code.
func loggingInterceptor(
	ctx context.Context,
	req any,
	info *grpc.UnaryServerInfo,
	handler grpc.UnaryHandler,
) (any, error) {
	start := time.Now()
	resp, err := handler(ctx, req)
	duration := time.Since(start)

	code := codes.OK
	if err != nil {
		code = status.Code(err)
	}
	log.Printf("grpc method=%s code=%s duration=%s", info.FullMethod, code, duration)
	return resp, err
}

// requestIDInterceptor extracts or generates a request ID.
func requestIDInterceptor(
	ctx context.Context,
	req any,
	info *grpc.UnaryServerInfo,
	handler grpc.UnaryHandler,
) (any, error) {
	md, ok := metadata.FromIncomingContext(ctx)
	requestID := ""
	if ok {
		ids := md.Get("x-request-id")
		if len(ids) > 0 {
			requestID = ids[0]
		}
	}
	if requestID == "" {
		requestID = fmt.Sprintf("req-%d", time.Now().UnixNano())
	}
	_ = grpc.SetHeader(ctx, metadata.Pairs("x-request-id", requestID))
	return handler(ctx, req)
}

// streamRecoveryInterceptor catches panics in stream handlers.
func streamRecoveryInterceptor(
	srv any,
	ss grpc.ServerStream,
	info *grpc.StreamServerInfo,
	handler grpc.StreamHandler,
) (err error) {
	defer func() {
		if r := recover(); r != nil {
			log.Printf("PANIC in stream %s: %v\n%s", info.FullMethod, r, debug.Stack())
			err = status.Errorf(codes.Internal, "internal server error")
		}
	}()
	return handler(srv, ss)
}

// --- Server Setup ---

func main() {
	cfg := parseConfig()
	log.Printf("Starting gRPC server on %s (env=%s)", cfg.Addr, cfg.Env)

	// Listener
	lis, err := net.Listen("tcp", cfg.Addr)
	if err != nil {
		log.Fatalf("Failed to listen on %s: %v", cfg.Addr, err)
	}

	// Server options
	opts := []grpc.ServerOption{
		// Interceptor chain: outermost first
		grpc.ChainUnaryInterceptor(
			recoveryInterceptor,
			loggingInterceptor,
			requestIDInterceptor,
			// Add your auth interceptor here:
			// authInterceptor,
		),
		grpc.ChainStreamInterceptor(
			streamRecoveryInterceptor,
			// streamAuthInterceptor,
		),

		// Keepalive — tune for your environment
		grpc.KeepaliveParams(keepalive.ServerParameters{
			MaxConnectionIdle:     15 * time.Minute,
			MaxConnectionAge:      30 * time.Minute,
			MaxConnectionAgeGrace: 5 * time.Second,
			Time:                  5 * time.Minute,
			Timeout:               1 * time.Second,
		}),
		grpc.KeepaliveEnforcementPolicy(keepalive.EnforcementPolicy{
			MinTime:             5 * time.Second,
			PermitWithoutStream: true,
		}),

		// Message size limits
		grpc.MaxRecvMsgSize(4 * 1024 * 1024), // 4MB
		grpc.MaxSendMsgSize(4 * 1024 * 1024), // 4MB
	}

	s := grpc.NewServer(opts...)

	// --- Register your services ---
	// pb.RegisterExampleServiceServer(s, &exampleServer{})

	// --- Health check ---
	healthSrv := health.NewServer()
	healthpb.RegisterHealthServer(s, healthSrv)
	// Set per-service health status:
	// healthSrv.SetServingStatus("acme.example.v1.ExampleService", healthpb.HealthCheckResponse_SERVING)
	healthSrv.SetServingStatus("", healthpb.HealthCheckResponse_SERVING) // Overall server health

	// --- Reflection (disable in production if needed) ---
	if cfg.Env != "production" {
		reflection.Register(s)
		log.Println("Reflection enabled (non-production)")
	}

	// --- Graceful shutdown ---
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGTERM, syscall.SIGINT)

	go func() {
		sig := <-sigCh
		log.Printf("Received signal %v, starting graceful shutdown...", sig)

		// Mark as not serving so LB stops routing new requests
		healthSrv.SetServingStatus("", healthpb.HealthCheckResponse_NOT_SERVING)

		// Give load balancers time to detect health change
		time.Sleep(5 * time.Second)

		// Hard deadline for graceful stop
		done := make(chan struct{})
		go func() {
			s.GracefulStop()
			close(done)
		}()

		select {
		case <-done:
			log.Println("Graceful shutdown complete")
		case <-time.After(30 * time.Second):
			log.Println("Graceful shutdown timed out, forcing stop")
			s.Stop()
		}
	}()

	// --- Serve ---
	log.Printf("gRPC server listening on %s", cfg.Addr)
	if err := s.Serve(lis); err != nil {
		log.Fatalf("Server error: %v", err)
	}
}
