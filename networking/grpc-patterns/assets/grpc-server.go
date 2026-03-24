// grpc-server.go — Production-ready gRPC server template for Go.
//
// Features:
//   - Unary and stream interceptors (logging, recovery)
//   - Health checking with per-service status
//   - Server reflection for introspection
//   - Channelz for runtime diagnostics
//   - Graceful shutdown on SIGINT/SIGTERM
//   - Configurable keepalive and connection limits
//
// Customize: replace the orderServer stub with your service implementation.
// Build: go build -o server ./grpc-server.go

package main

import (
	"context"
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

	channelzsvc "google.golang.org/grpc/channelz/service"

	// Import your generated proto package:
	// pb "github.com/myorg/myservice/gen/go/orders/v1"
)

// ---------- Configuration ----------

type serverConfig struct {
	Port                int
	MaxRecvMsgSize      int
	MaxSendMsgSize      int
	MaxConcurrentStream uint32
	EnableReflection    bool
	EnableChannelz      bool
}

func defaultConfig() serverConfig {
	return serverConfig{
		Port:                50051,
		MaxRecvMsgSize:      4 * 1024 * 1024, // 4 MB
		MaxSendMsgSize:      4 * 1024 * 1024,
		MaxConcurrentStream: 100,
		EnableReflection:    true,
		EnableChannelz:      true,
	}
}

// ---------- Interceptors ----------

// loggingUnaryInterceptor logs method, duration, and status for every unary RPC.
func loggingUnaryInterceptor(
	ctx context.Context,
	req interface{},
	info *grpc.UnaryServerInfo,
	handler grpc.UnaryHandler,
) (interface{}, error) {
	start := time.Now()

	// Extract request ID from metadata if present
	reqID := ""
	if md, ok := metadata.FromIncomingContext(ctx); ok {
		if vals := md.Get("x-request-id"); len(vals) > 0 {
			reqID = vals[0]
		}
	}

	resp, err := handler(ctx, req)

	duration := time.Since(start)
	code := status.Code(err)
	log.Printf("unary  method=%s code=%s duration=%s req_id=%s",
		info.FullMethod, code, duration, reqID)

	return resp, err
}

// loggingStreamInterceptor logs stream lifecycle events.
func loggingStreamInterceptor(
	srv interface{},
	ss grpc.ServerStream,
	info *grpc.StreamServerInfo,
	handler grpc.StreamHandler,
) error {
	start := time.Now()
	log.Printf("stream started method=%s", info.FullMethod)

	err := handler(srv, ss)

	duration := time.Since(start)
	code := status.Code(err)
	log.Printf("stream ended   method=%s code=%s duration=%s",
		info.FullMethod, code, duration)

	return err
}

// recoveryUnaryInterceptor catches panics and returns INTERNAL error.
func recoveryUnaryInterceptor(
	ctx context.Context,
	req interface{},
	info *grpc.UnaryServerInfo,
	handler grpc.UnaryHandler,
) (resp interface{}, err error) {
	defer func() {
		if r := recover(); r != nil {
			log.Printf("PANIC in %s: %v\n%s", info.FullMethod, r, debug.Stack())
			err = status.Errorf(codes.Internal, "internal server error")
		}
	}()
	return handler(ctx, req)
}

// recoveryStreamInterceptor catches panics in stream handlers.
func recoveryStreamInterceptor(
	srv interface{},
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

// ---------- Service Implementation (stub) ----------

// Uncomment and implement when you have generated proto code:
//
// type orderServer struct {
// 	pb.UnimplementedOrderServiceServer
// }
//
// func (s *orderServer) CreateOrder(ctx context.Context, req *pb.CreateOrderRequest) (*pb.CreateOrderResponse, error) {
// 	if req.GetCustomerId() == "" {
// 		return nil, status.Errorf(codes.InvalidArgument, "customer_id is required")
// 	}
// 	order := &pb.Order{
// 		Id:         uuid.NewString(),
// 		CustomerId: req.GetCustomerId(),
// 		Items:      req.GetItems(),
// 		Status:     pb.OrderStatus_ORDER_STATUS_PENDING,
// 	}
// 	return &pb.CreateOrderResponse{Order: order}, nil
// }

// ---------- Main ----------

func main() {
	cfg := defaultConfig()

	// Override port from environment
	if p := os.Getenv("GRPC_PORT"); p != "" {
		fmt.Sscanf(p, "%d", &cfg.Port)
	}

	// Create TCP listener
	addr := fmt.Sprintf(":%d", cfg.Port)
	lis, err := net.Listen("tcp", addr)
	if err != nil {
		log.Fatalf("failed to listen on %s: %v", addr, err)
	}

	// Build server with options
	srv := grpc.NewServer(
		// Message size limits
		grpc.MaxRecvMsgSize(cfg.MaxRecvMsgSize),
		grpc.MaxSendMsgSize(cfg.MaxSendMsgSize),
		grpc.MaxConcurrentStreams(cfg.MaxConcurrentStream),

		// Keepalive — critical for load balancing and connection health
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

		// Interceptor chains — order: recovery → logging → (add auth, metrics here)
		grpc.ChainUnaryInterceptor(
			recoveryUnaryInterceptor,
			loggingUnaryInterceptor,
		),
		grpc.ChainStreamInterceptor(
			recoveryStreamInterceptor,
			loggingStreamInterceptor,
		),
	)

	// Register your service
	// pb.RegisterOrderServiceServer(srv, &orderServer{})

	// Health checking — set per-service and overall status
	hsrv := health.NewServer()
	healthpb.RegisterHealthServer(srv, hsrv)
	hsrv.SetServingStatus("", healthpb.HealthCheckResponse_SERVING)
	// hsrv.SetServingStatus("orders.v1.OrderService", healthpb.HealthCheckResponse_SERVING)

	// Server reflection — enables grpcurl, Evans, and dynamic clients
	if cfg.EnableReflection {
		reflection.Register(srv)
	}

	// Channelz — runtime diagnostics for connections, streams, sockets
	if cfg.EnableChannelz {
		channelzsvc.RegisterChannelzServiceToServer(srv)
	}

	// Graceful shutdown on SIGINT / SIGTERM
	go func() {
		sigCh := make(chan os.Signal, 1)
		signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
		sig := <-sigCh
		log.Printf("received signal %v, shutting down gracefully...", sig)

		// Mark health as NOT_SERVING so load balancers stop sending traffic
		hsrv.SetServingStatus("", healthpb.HealthCheckResponse_NOT_SERVING)

		// Allow in-flight RPCs to complete (with timeout)
		stopped := make(chan struct{})
		go func() {
			srv.GracefulStop()
			close(stopped)
		}()

		select {
		case <-stopped:
			log.Println("graceful shutdown complete")
		case <-time.After(30 * time.Second):
			log.Println("graceful shutdown timed out, forcing stop")
			srv.Stop()
		}
	}()

	log.Printf("gRPC server listening on %s", addr)
	if err := srv.Serve(lis); err != nil {
		log.Fatalf("server exited with error: %v", err)
	}
}
