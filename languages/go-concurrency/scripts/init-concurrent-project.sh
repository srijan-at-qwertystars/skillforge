#!/bin/bash
# init-concurrent-project.sh — Set up a Go project with concurrency-ready structure
#
# Usage:
#   ./init-concurrent-project.sh <project-name> [module-path]
#
# Examples:
#   ./init-concurrent-project.sh myservice
#   ./init-concurrent-project.sh myservice github.com/org/myservice
#
# Creates:
#   <project-name>/
#   ├── go.mod
#   ├── Makefile            (race detection, bench, profile targets)
#   ├── main.go
#   ├── internal/
#   │   └── worker/
#   │       ├── pool.go     (worker pool template)
#   │       └── pool_test.go
#   └── cmd/
#       └── server/
#           └── main.go

set -euo pipefail

# --- Argument parsing ---
PROJECT_NAME="${1:?Usage: $0 <project-name> [module-path]}"
MODULE_PATH="${2:-github.com/example/${PROJECT_NAME}}"

if [[ -d "$PROJECT_NAME" ]]; then
    echo "Error: directory '$PROJECT_NAME' already exists"
    exit 1
fi

echo "==> Creating project: $PROJECT_NAME (module: $MODULE_PATH)"

# --- Create directory structure ---
mkdir -p "$PROJECT_NAME"/{cmd/server,internal/worker}
cd "$PROJECT_NAME"

# --- Initialize Go module ---
go mod init "$MODULE_PATH"
echo "==> Initialized Go module: $MODULE_PATH"

# --- Add concurrency dependencies ---
echo "==> Adding dependencies..."
go get golang.org/x/sync/errgroup
go get golang.org/x/sync/singleflight
go get golang.org/x/sync/semaphore
go get golang.org/x/time/rate
go get go.uber.org/goleak
go get go.uber.org/automaxprocs

# --- Create Makefile ---
cat > Makefile << 'MAKEFILE'
.PHONY: build test test-race bench lint vet profile trace clean

BINARY := $(shell basename $(CURDIR))
GOFLAGS := -v
RACE_FLAGS := -race

# Build
build:
	go build $(GOFLAGS) -o bin/$(BINARY) ./cmd/server

build-race:
	go build $(RACE_FLAGS) $(GOFLAGS) -o bin/$(BINARY)-race ./cmd/server

# Testing
test:
	go test $(GOFLAGS) ./...

test-race:
	go test $(RACE_FLAGS) -count=1 -timeout=5m ./...

test-race-repeat:
	go test $(RACE_FLAGS) -count=100 -timeout=30m ./...

# Benchmarks
bench:
	go test -bench=. -benchmem -run='^$$' ./...

bench-cpu:
	go test -bench=. -benchmem -cpuprofile=cpu.out -run='^$$' ./...
	@echo "Run: go tool pprof -http=:8080 cpu.out"

bench-mem:
	go test -bench=. -benchmem -memprofile=mem.out -run='^$$' ./...
	@echo "Run: go tool pprof -http=:8080 mem.out"

# Profiling
profile-mutex:
	go test -bench=. -mutexprofile=mutex.out -run='^$$' ./...
	@echo "Run: go tool pprof -http=:8080 mutex.out"

profile-block:
	go test -bench=. -blockprofile=block.out -run='^$$' ./...
	@echo "Run: go tool pprof -http=:8080 block.out"

# Tracing
trace:
	go test -trace=trace.out -run=TestMain ./...
	@echo "Run: go tool trace trace.out"

# Linting
vet:
	go vet ./...

lint: vet
	@which golangci-lint > /dev/null 2>&1 || echo "Install: go install github.com/golangci/golangci-lint/cmd/golangci-lint@latest"
	golangci-lint run ./...

# Clean
clean:
	rm -rf bin/ *.out *.test
	go clean -cache -testcache
MAKEFILE

# --- Create worker pool template ---
cat > internal/worker/pool.go << 'GOFILE'
package worker

import (
	"context"
	"fmt"
	"sync"
)

// Job represents a unit of work to be processed by the worker pool.
type Job struct {
	ID      int
	Payload any
}

// Result represents the outcome of processing a Job.
type Result struct {
	JobID int
	Value any
	Err   error
}

// ProcessFunc defines the function signature for processing a job.
type ProcessFunc func(ctx context.Context, job Job) Result

// Pool is a worker pool that processes jobs concurrently with configurable
// worker count, graceful shutdown, and error handling.
type Pool struct {
	workers    int
	processFn  ProcessFunc
	jobs       chan Job
	results    chan Result
	wg         sync.WaitGroup
}

// NewPool creates a new worker pool.
//   - workers: number of concurrent workers
//   - queueSize: buffer size for the job queue
//   - processFn: function to process each job
func NewPool(workers, queueSize int, processFn ProcessFunc) *Pool {
	return &Pool{
		workers:   workers,
		processFn: processFn,
		jobs:      make(chan Job, queueSize),
		results:   make(chan Result, queueSize),
	}
}

// Start launches the worker goroutines. Call Stop() when done.
func (p *Pool) Start(ctx context.Context) {
	for i := range p.workers {
		p.wg.Add(1)
		go func() {
			defer p.wg.Done()
			for {
				select {
				case <-ctx.Done():
					return
				case job, ok := <-p.jobs:
					if !ok {
						return
					}
					result := p.processFn(ctx, job)
					select {
					case p.results <- result:
					case <-ctx.Done():
						return
					}
				}
			}
			_ = i // worker ID available for logging
		}()
	}
}

// Submit adds a job to the queue. Blocks if the queue is full.
func (p *Pool) Submit(ctx context.Context, job Job) error {
	select {
	case p.jobs <- job:
		return nil
	case <-ctx.Done():
		return fmt.Errorf("submit cancelled: %w", ctx.Err())
	}
}

// Results returns the results channel for reading processed results.
func (p *Pool) Results() <-chan Result {
	return p.results
}

// Stop closes the job queue and waits for all workers to finish.
// After Stop returns, the results channel is closed.
func (p *Pool) Stop() {
	close(p.jobs)
	p.wg.Wait()
	close(p.results)
}
GOFILE

# --- Create worker pool test ---
cat > internal/worker/pool_test.go << 'GOFILE'
package worker

import (
	"context"
	"sync/atomic"
	"testing"
	"time"
)

func TestPoolProcessesAllJobs(t *testing.T) {
	const numJobs = 100
	ctx := context.Background()

	pool := NewPool(4, numJobs, func(ctx context.Context, job Job) Result {
		return Result{JobID: job.ID, Value: job.ID * 2}
	})

	pool.Start(ctx)

	go func() {
		for i := range numJobs {
			if err := pool.Submit(ctx, Job{ID: i}); err != nil {
				t.Errorf("submit failed: %v", err)
			}
		}
		pool.Stop()
	}()

	count := 0
	for range pool.Results() {
		count++
	}

	if count != numJobs {
		t.Errorf("got %d results, want %d", count, numJobs)
	}
}

func TestPoolCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())

	var processed atomic.Int32
	pool := NewPool(4, 100, func(ctx context.Context, job Job) Result {
		time.Sleep(50 * time.Millisecond)
		processed.Add(1)
		return Result{JobID: job.ID}
	})

	pool.Start(ctx)

	for i := range 50 {
		pool.Submit(ctx, Job{ID: i})
	}

	cancel() // cancel while jobs are in-flight
	pool.Stop()

	if processed.Load() >= 50 {
		t.Error("expected cancellation to prevent processing all jobs")
	}
}
GOFILE

# --- Create main.go ---
cat > main.go << 'GOFILE'
package main

import (
	"fmt"
	"runtime"
)

func main() {
	fmt.Printf("Go %s | GOMAXPROCS=%d | NumCPU=%d\n",
		runtime.Version(), runtime.GOMAXPROCS(0), runtime.NumCPU())
	fmt.Println("Project initialized. See cmd/server/ for the server entry point.")
}
GOFILE

# --- Create server main.go ---
cat > cmd/server/main.go << 'GOFILE'
package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	_ "go.uber.org/automaxprocs"
)

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("ok"))
	})

	srv := &http.Server{
		Addr:         ":8080",
		Handler:      mux,
		ReadTimeout:  5 * time.Second,
		WriteTimeout: 10 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	go func() {
		log.Printf("server starting on %s", srv.Addr)
		if err := srv.ListenAndServe(); err != http.ErrServerClosed {
			log.Fatalf("server error: %v", err)
		}
	}()

	<-ctx.Done()
	log.Println("shutting down...")

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Fatalf("shutdown error: %v", err)
	}
	log.Println("server stopped")
}
GOFILE

# --- Tidy module ---
go mod tidy
echo ""
echo "==> Project '$PROJECT_NAME' created successfully!"
echo ""
echo "Structure:"
find . -type f | sort | head -20
echo ""
echo "Next steps:"
echo "  cd $PROJECT_NAME"
echo "  make test-race    # run tests with race detector"
echo "  make build        # build the project"
echo "  make bench        # run benchmarks"
