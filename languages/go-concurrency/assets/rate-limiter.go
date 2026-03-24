// rate-limiter.go — Token bucket rate limiter with per-key limits, burst support,
// and automatic cleanup of stale entries.
//
// Usage:
//   rl := NewRateLimiter(RateLimiterConfig{
//       Rate:            10,               // 10 requests per second per key
//       Burst:           20,               // allow bursts up to 20
//       CleanupInterval: 5 * time.Minute,  // remove stale entries every 5 min
//       StaleAfter:      10 * time.Minute, // entries unused for 10 min are stale
//   })
//   defer rl.Stop()
//
//   // In HTTP middleware:
//   if !rl.Allow(clientIP) {
//       http.Error(w, "rate limited", http.StatusTooManyRequests)
//       return
//   }

package concurrency

import (
	"context"
	"net/http"
	"sync"
	"time"
)

// RateLimiterConfig holds configuration for the rate limiter.
type RateLimiterConfig struct {
	Rate            float64       // tokens per second per key
	Burst           int           // maximum burst size per key
	CleanupInterval time.Duration // how often to clean stale entries
	StaleAfter      time.Duration // remove entries not accessed for this long
}

func (c RateLimiterConfig) withDefaults() RateLimiterConfig {
	if c.Rate <= 0 {
		c.Rate = 10
	}
	if c.Burst <= 0 {
		c.Burst = int(c.Rate) * 2
	}
	if c.CleanupInterval <= 0 {
		c.CleanupInterval = 5 * time.Minute
	}
	if c.StaleAfter <= 0 {
		c.StaleAfter = 10 * time.Minute
	}
	return c
}

// bucket tracks tokens for a single key using the token bucket algorithm.
type bucket struct {
	tokens     float64
	maxTokens  float64
	refillRate float64   // tokens per second
	lastAccess time.Time // for stale entry cleanup
	lastRefill time.Time // for token refill calculation
}

func newBucket(rate float64, burst int, now time.Time) *bucket {
	return &bucket{
		tokens:     float64(burst),
		maxTokens:  float64(burst),
		refillRate: rate,
		lastAccess: now,
		lastRefill: now,
	}
}

// tryConsume refills tokens based on elapsed time and attempts to consume one.
func (b *bucket) tryConsume(now time.Time) bool {
	elapsed := now.Sub(b.lastRefill).Seconds()
	b.tokens += elapsed * b.refillRate
	if b.tokens > b.maxTokens {
		b.tokens = b.maxTokens
	}
	b.lastRefill = now
	b.lastAccess = now

	if b.tokens >= 1 {
		b.tokens--
		return true
	}
	return false
}

// RateLimiter implements per-key token bucket rate limiting with automatic cleanup.
type RateLimiter struct {
	mu      sync.Mutex
	buckets map[string]*bucket
	cfg     RateLimiterConfig
	cancel  context.CancelFunc
}

// NewRateLimiter creates a rate limiter and starts the background cleanup goroutine.
func NewRateLimiter(cfg RateLimiterConfig) *RateLimiter {
	cfg = cfg.withDefaults()
	ctx, cancel := context.WithCancel(context.Background())

	rl := &RateLimiter{
		buckets: make(map[string]*bucket),
		cfg:     cfg,
		cancel:  cancel,
	}

	go rl.cleanupLoop(ctx)
	return rl
}

// Allow checks if a request for the given key is allowed.
// Returns true if allowed, false if rate limited.
func (rl *RateLimiter) Allow(key string) bool {
	rl.mu.Lock()
	defer rl.mu.Unlock()

	now := time.Now()
	b, ok := rl.buckets[key]
	if !ok {
		b = newBucket(rl.cfg.Rate, rl.cfg.Burst, now)
		rl.buckets[key] = b
	}

	return b.tryConsume(now)
}

// AllowN checks if n tokens are available for the given key.
func (rl *RateLimiter) AllowN(key string, n int) bool {
	rl.mu.Lock()
	defer rl.mu.Unlock()

	now := time.Now()
	b, ok := rl.buckets[key]
	if !ok {
		b = newBucket(rl.cfg.Rate, rl.cfg.Burst, now)
		rl.buckets[key] = b
	}

	// Refill
	elapsed := now.Sub(b.lastRefill).Seconds()
	b.tokens += elapsed * b.refillRate
	if b.tokens > b.maxTokens {
		b.tokens = b.maxTokens
	}
	b.lastRefill = now
	b.lastAccess = now

	if b.tokens >= float64(n) {
		b.tokens -= float64(n)
		return true
	}
	return false
}

// Wait blocks until a token is available for the given key or the context is done.
func (rl *RateLimiter) Wait(ctx context.Context, key string) error {
	for {
		if rl.Allow(key) {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(time.Duration(float64(time.Second) / rl.cfg.Rate)):
		}
	}
}

// Reset removes the rate limit state for a specific key.
func (rl *RateLimiter) Reset(key string) {
	rl.mu.Lock()
	delete(rl.buckets, key)
	rl.mu.Unlock()
}

// Len returns the number of tracked keys.
func (rl *RateLimiter) Len() int {
	rl.mu.Lock()
	defer rl.mu.Unlock()
	return len(rl.buckets)
}

// Stop shuts down the cleanup goroutine.
func (rl *RateLimiter) Stop() {
	rl.cancel()
}

func (rl *RateLimiter) cleanupLoop(ctx context.Context) {
	ticker := time.NewTicker(rl.cfg.CleanupInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			rl.cleanup()
		}
	}
}

func (rl *RateLimiter) cleanup() {
	rl.mu.Lock()
	defer rl.mu.Unlock()

	cutoff := time.Now().Add(-rl.cfg.StaleAfter)
	for key, b := range rl.buckets {
		if b.lastAccess.Before(cutoff) {
			delete(rl.buckets, key)
		}
	}
}

// --- HTTP Middleware ---

// Middleware returns an HTTP middleware that rate limits requests by key.
// keyFunc extracts the rate limit key from the request (e.g., client IP, API key).
func (rl *RateLimiter) Middleware(keyFunc func(*http.Request) string) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			key := keyFunc(r)
			if !rl.Allow(key) {
				w.Header().Set("Retry-After", "1")
				http.Error(w, "rate limit exceeded", http.StatusTooManyRequests)
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}

// IPKeyFunc extracts the client IP from X-Forwarded-For or RemoteAddr.
func IPKeyFunc(r *http.Request) string {
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		return xff
	}
	return r.RemoteAddr
}
