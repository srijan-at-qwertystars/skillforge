// =============================================================================
// go-client-example.go — Production-grade NATS client in Go
//
// Demonstrates:
//   • Connection with TLS, credentials, and reconnect handling
//   • JetStream stream creation
//   • Publishing with headers and message deduplication
//   • Pull consumer with batch fetch
//   • Push consumer with queue group
//   • Key/Value store operations
//   • Request/reply pattern
//   • Graceful shutdown via SIGINT / SIGTERM
//
// Prerequisites:
//   go get github.com/nats-io/nats.go
//
// Usage:
//   go run go-client-example.go
// =============================================================================
package main

import (
	"context"
	"crypto/tls"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/nats-io/nats.go"
)

// Config holds the application's NATS connection parameters.
type Config struct {
	URL       string // NATS server URL(s), comma-separated
	CredsFile string // Path to .creds file (optional)
	CertFile  string // TLS client certificate (optional)
	KeyFile   string // TLS client key (optional)
	CAFile    string // TLS CA bundle (optional)
}

func main() {
	// ── Configuration ────────────────────────────────────────────────────
	cfg := Config{
		URL:       nats.DefaultURL, // nats://localhost:4222
		CredsFile: os.Getenv("NATS_CREDS"),
		CertFile:  os.Getenv("NATS_CERT"),
		KeyFile:   os.Getenv("NATS_KEY"),
		CAFile:    os.Getenv("NATS_CA"),
	}

	if envURL := os.Getenv("NATS_URL"); envURL != "" {
		cfg.URL = envURL
	}

	// ── Root context with cancellation on OS signals ─────────────────────
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		sig := <-sigCh
		log.Printf("Received signal %v — shutting down gracefully…", sig)
		cancel()
	}()

	// ── Connect to NATS ──────────────────────────────────────────────────
	nc, err := connect(cfg)
	if err != nil {
		log.Fatalf("Failed to connect to NATS: %v", err)
	}
	defer func() {
		// Drain ensures in-flight messages are processed before closing.
		if err := nc.Drain(); err != nil {
			log.Printf("Error draining connection: %v", err)
		}
		log.Println("NATS connection closed")
	}()

	// ── Obtain JetStream context ─────────────────────────────────────────
	js, err := nc.JetStream(
		nats.PublishAsyncMaxPending(256),
	)
	if err != nil {
		log.Fatalf("Failed to create JetStream context: %v", err)
	}

	// ── Demo: Create stream ──────────────────────────────────────────────
	if err := createStream(js); err != nil {
		log.Fatalf("Stream creation failed: %v", err)
	}

	// ── Demo: Key/Value store ────────────────────────────────────────────
	if err := kvStoreDemo(js); err != nil {
		log.Printf("KV demo error (non-fatal): %v", err)
	}

	// ── Demo: Request/reply ──────────────────────────────────────────────
	if err := requestReplyDemo(ctx, nc); err != nil {
		log.Printf("Request/reply demo error (non-fatal): %v", err)
	}

	// ── Demo: Push consumer (queue group) ────────────────────────────────
	pushDone := make(chan struct{})
	go pushConsumerDemo(ctx, js, pushDone)

	// ── Demo: Pull consumer (batch fetch) ────────────────────────────────
	pullDone := make(chan struct{})
	go pullConsumerDemo(ctx, js, pullDone)

	// ── Demo: Publish messages ───────────────────────────────────────────
	if err := publishMessages(ctx, js, 10); err != nil {
		log.Printf("Publish error: %v", err)
	}

	// Wait for context cancellation (signal) or a short demo timeout
	select {
	case <-ctx.Done():
	case <-time.After(15 * time.Second):
		log.Println("Demo timeout reached — shutting down")
		cancel()
	}

	// Allow consumers to finish draining
	<-pushDone
	<-pullDone

	log.Println("All demos complete")
}

// =============================================================================
// Connection
// =============================================================================

// connect establishes a NATS connection with production-grade options.
func connect(cfg Config) (*nats.Conn, error) {
	opts := []nats.Option{
		// Reconnect settings — keep trying for up to ~5 minutes
		nats.MaxReconnects(60),
		nats.ReconnectWait(5 * time.Second),
		nats.ReconnectBufSize(8 * 1024 * 1024), // 8 MB buffer during reconnect

		// Jitter avoids thundering-herd reconnects across many clients
		nats.ReconnectJitter(500*time.Millisecond, 2*time.Second),

		// Connection name shows up in server monitoring (connz)
		nats.Name("go-nats-example"),

		// ── Event handlers ───────────────────────────────────────────────
		nats.DisconnectErrHandler(func(nc *nats.Conn, err error) {
			if err != nil {
				log.Printf("[NATS] Disconnected: %v", err)
			} else {
				log.Println("[NATS] Disconnected (clean)")
			}
		}),
		nats.ReconnectHandler(func(nc *nats.Conn) {
			log.Printf("[NATS] Reconnected to %s", nc.ConnectedUrl())
		}),
		nats.ClosedHandler(func(nc *nats.Conn) {
			if err := nc.LastError(); err != nil {
				log.Printf("[NATS] Connection closed with error: %v", err)
			} else {
				log.Println("[NATS] Connection closed")
			}
		}),
		nats.ErrorHandler(func(nc *nats.Conn, sub *nats.Subscription, err error) {
			log.Printf("[NATS] Async error: sub=%v err=%v", sub.Subject, err)
		}),
	}

	// ── Optional TLS ─────────────────────────────────────────────────────
	if cfg.CertFile != "" && cfg.KeyFile != "" {
		cert, err := tls.LoadX509KeyPair(cfg.CertFile, cfg.KeyFile)
		if err != nil {
			return nil, fmt.Errorf("loading TLS cert/key: %w", err)
		}
		tlsCfg := &tls.Config{
			Certificates: []tls.Certificate{cert},
			MinVersion:   tls.VersionTLS12,
		}
		opts = append(opts, nats.Secure(tlsCfg))
	}

	// ── Optional credentials file ────────────────────────────────────────
	if cfg.CredsFile != "" {
		opts = append(opts, nats.UserCredentials(cfg.CredsFile))
	}

	return nats.Connect(cfg.URL, opts...)
}

// =============================================================================
// JetStream Stream Management
// =============================================================================

// createStream idempotently creates (or updates) the ORDERS stream.
func createStream(js nats.JetStreamContext) error {
	streamCfg := &nats.StreamConfig{
		Name:     "ORDERS",
		Subjects: []string{"orders.>"},
		Storage:  nats.FileStorage,
		Replicas: 1, // Use 3 in a clustered deployment

		// Retention policy: limits-based (oldest messages are discarded first)
		Retention: nats.LimitsPolicy,

		// Discard policy: discard the oldest message when a limit is hit
		Discard: nats.DiscardOld,

		// Stream limits
		MaxMsgs:           -1,            // unlimited messages
		MaxBytes:          1024 * 1024 * 1024, // 1 GB
		MaxAge:            24 * time.Hour, // keep for 24 hours
		MaxMsgSize:        -1,            // inherit server max_payload
		DuplicateWindow:   2 * time.Minute,
		MaxMsgsPerSubject: -1,
	}

	// AddStream is idempotent — if the stream already exists with the same
	// configuration, it returns the existing stream info.
	info, err := js.AddStream(streamCfg)
	if err != nil {
		return fmt.Errorf("adding stream ORDERS: %w", err)
	}

	log.Printf("Stream %q ready — %d messages, %d bytes",
		info.Config.Name, info.State.Msgs, info.State.Bytes)
	return nil
}

// =============================================================================
// Publishing
// =============================================================================

// publishMessages publishes n order events with headers and dedup IDs.
func publishMessages(ctx context.Context, js nats.JetStreamContext, n int) error {
	for i := 1; i <= n; i++ {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}

		// Construct the message with headers
		msg := &nats.Msg{
			Subject: fmt.Sprintf("orders.created.%d", i),
			Data:    []byte(fmt.Sprintf(`{"order_id":%d,"item":"widget","qty":%d}`, i, i*10)),
			Header:  nats.Header{},
		}

		// Nats-Msg-Id enables server-side deduplication within the
		// stream's DuplicateWindow.  Retrying the same ID is safe.
		msg.Header.Set("Nats-Msg-Id", fmt.Sprintf("order-%d", i))

		// Application-level headers for tracing / filtering
		msg.Header.Set("X-Source", "go-client-example")
		msg.Header.Set("X-Timestamp", time.Now().UTC().Format(time.RFC3339Nano))

		ack, err := js.PublishMsg(msg)
		if err != nil {
			return fmt.Errorf("publishing order %d: %w", i, err)
		}

		log.Printf("Published order %d → stream=%s seq=%d", i, ack.Stream, ack.Sequence)

		// Small delay so consumers can keep up in the demo
		time.Sleep(200 * time.Millisecond)
	}

	log.Printf("Finished publishing %d messages", n)
	return nil
}

// =============================================================================
// Pull Consumer — Batch Fetch
// =============================================================================

// pullConsumerDemo creates a durable pull consumer and fetches messages in
// batches.  Pull consumers are ideal for worker-pool patterns where the
// application controls the rate of consumption.
func pullConsumerDemo(ctx context.Context, js nats.JetStreamContext, done chan struct{}) {
	defer close(done)

	// Create a durable pull subscription.
	// "order-processor" is the durable consumer name.
	sub, err := js.PullSubscribe(
		"orders.>",
		"order-processor",
		nats.AckExplicit(),
		nats.MaxAckPending(128),
		nats.DeliverAll(),
	)
	if err != nil {
		log.Printf("[Pull] Failed to subscribe: %v", err)
		return
	}
	log.Println("[Pull] Consumer 'order-processor' started — fetching batches")

	for {
		select {
		case <-ctx.Done():
			log.Println("[Pull] Shutting down")
			return
		default:
		}

		// Fetch up to 5 messages, waiting at most 2 seconds.
		msgs, err := sub.Fetch(5, nats.MaxWait(2*time.Second))
		if err != nil {
			// Timeout is normal when the stream is idle
			if err == nats.ErrTimeout {
				continue
			}
			log.Printf("[Pull] Fetch error: %v", err)
			continue
		}

		for _, msg := range msgs {
			log.Printf("[Pull] Received: subject=%s data=%s", msg.Subject, string(msg.Data))

			// Process message…

			// Acknowledge after successful processing
			if err := msg.Ack(); err != nil {
				log.Printf("[Pull] Ack error: %v", err)
			}
		}
	}
}

// =============================================================================
// Push Consumer — Queue Group
// =============================================================================

// pushConsumerDemo creates a push-based consumer with a queue group.
// Queue groups ensure each message is delivered to exactly one member of the
// group, enabling horizontal scaling of consumers.
func pushConsumerDemo(ctx context.Context, js nats.JetStreamContext, done chan struct{}) {
	defer close(done)

	// The queue group name "order-workers" load-balances messages across all
	// subscribers with the same group name.
	sub, err := js.QueueSubscribe(
		"orders.>",
		"order-workers",
		func(msg *nats.Msg) {
			log.Printf("[Push] Received: subject=%s data=%s", msg.Subject, string(msg.Data))

			// Inspect headers
			if src := msg.Header.Get("X-Source"); src != "" {
				log.Printf("[Push]   Source: %s", src)
			}

			// Acknowledge after processing
			if err := msg.Ack(); err != nil {
				log.Printf("[Push] Ack error: %v", err)
			}
		},
		nats.Durable("order-push-worker"),
		nats.AckExplicit(),
		nats.DeliverAll(),
		nats.MaxAckPending(64),
	)
	if err != nil {
		log.Printf("[Push] Failed to subscribe: %v", err)
		return
	}
	log.Println("[Push] Consumer 'order-push-worker' started (queue: order-workers)")

	<-ctx.Done()
	if err := sub.Drain(); err != nil {
		log.Printf("[Push] Drain error: %v", err)
	}
	log.Println("[Push] Shutting down")
}

// =============================================================================
// Key/Value Store
// =============================================================================

// kvStoreDemo shows how to use NATS JetStream as a distributed key-value
// store.  KV buckets are backed by streams under the hood.
func kvStoreDemo(js nats.JetStreamContext) error {
	// Create (or bind to) a KV bucket named "app-config"
	kv, err := js.CreateKeyValue(&nats.KeyValueConfig{
		Bucket:      "app-config",
		Description: "Application configuration key-value store",
		TTL:         0, // No automatic expiry
		History:     5, // Keep last 5 revisions per key
		Storage:     nats.FileStorage,
		Replicas:    1, // Use 3 in production
	})
	if err != nil {
		return fmt.Errorf("creating KV bucket: %w", err)
	}
	log.Println("[KV] Bucket 'app-config' ready")

	// ── Put ──────────────────────────────────────────────────────────────
	rev, err := kv.PutString("feature.dark-mode", "enabled")
	if err != nil {
		return fmt.Errorf("KV put: %w", err)
	}
	log.Printf("[KV] Put feature.dark-mode = enabled (revision %d)", rev)

	// ── Get ──────────────────────────────────────────────────────────────
	entry, err := kv.Get("feature.dark-mode")
	if err != nil {
		return fmt.Errorf("KV get: %w", err)
	}
	log.Printf("[KV] Get feature.dark-mode = %s (revision %d, created %s)",
		string(entry.Value()), entry.Revision(), entry.Created())

	// ── Update (optimistic concurrency via revision) ─────────────────────
	_, err = kv.Update("feature.dark-mode", []byte("disabled"), entry.Revision())
	if err != nil {
		return fmt.Errorf("KV update: %w", err)
	}
	log.Println("[KV] Updated feature.dark-mode = disabled")

	// ── List keys ────────────────────────────────────────────────────────
	keys, err := kv.Keys()
	if err != nil {
		return fmt.Errorf("KV keys: %w", err)
	}
	log.Printf("[KV] Keys in bucket: %v", keys)

	// ── Delete ───────────────────────────────────────────────────────────
	if err := kv.Delete("feature.dark-mode"); err != nil {
		return fmt.Errorf("KV delete: %w", err)
	}
	log.Println("[KV] Deleted feature.dark-mode")

	return nil
}

// =============================================================================
// Request / Reply
// =============================================================================

// requestReplyDemo demonstrates the request/reply pattern.  A responder
// subscribes to "service.echo" and replies with the payload uppercased.
func requestReplyDemo(ctx context.Context, nc *nats.Conn) error {
	// ── Responder ────────────────────────────────────────────────────────
	sub, err := nc.Subscribe("service.echo", func(msg *nats.Msg) {
		reply := fmt.Sprintf("ECHO: %s", string(msg.Data))
		if err := msg.Respond([]byte(reply)); err != nil {
			log.Printf("[ReqRep] Respond error: %v", err)
		}
	})
	if err != nil {
		return fmt.Errorf("subscribing to service.echo: %w", err)
	}
	defer func() { _ = sub.Unsubscribe() }()

	// ── Requester ────────────────────────────────────────────────────────
	reply, err := nc.RequestWithContext(ctx, "service.echo", []byte("hello from Go"), 5*time.Second)
	if err != nil {
		return fmt.Errorf("request/reply: %w", err)
	}
	log.Printf("[ReqRep] Reply: %s", string(reply.Data))

	return nil
}
