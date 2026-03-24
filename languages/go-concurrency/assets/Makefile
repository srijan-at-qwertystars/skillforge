# Makefile — Go project with race detection, benchmarks, profiling, and trace targets.
#
# Usage:
#   make build           # standard build
#   make test            # run tests
#   make test-race       # run tests with race detector
#   make bench           # run benchmarks
#   make profile-cpu     # CPU profile with pprof
#   make trace           # execution trace
#   make lint            # run linters
#
# Copy into your Go project root. Adjust BINARY and PKG as needed.

.PHONY: all build build-race test test-race test-race-repeat test-cover \
        bench bench-compare profile-cpu profile-mem profile-mutex profile-block \
        trace vet lint clean help

# --- Configuration ---
BINARY    := $(shell basename $(CURDIR))
PKG       := ./...
GOFLAGS   := -v
RACE      := -race
BENCH_RUN := -run='^$$'
COVER_OUT := coverage.out

# --- Default ---
all: vet test-race build

# --- Build ---
build:
	@echo "==> Building..."
	go build $(GOFLAGS) -o bin/$(BINARY) .

build-race:
	@echo "==> Building with race detector..."
	go build $(RACE) $(GOFLAGS) -o bin/$(BINARY)-race .

# --- Testing ---
test:
	@echo "==> Running tests..."
	go test $(GOFLAGS) $(PKG)

test-race:
	@echo "==> Running tests with race detector..."
	go test $(RACE) -count=1 -timeout=5m $(PKG)

test-race-repeat:
	@echo "==> Running tests with race detector (100 iterations)..."
	go test $(RACE) -count=100 -timeout=30m $(PKG)

test-cover:
	@echo "==> Running tests with coverage..."
	go test $(RACE) -coverprofile=$(COVER_OUT) -covermode=atomic $(PKG)
	go tool cover -func=$(COVER_OUT)
	@echo "HTML report: go tool cover -html=$(COVER_OUT)"

# --- Benchmarks ---
bench:
	@echo "==> Running benchmarks..."
	go test -bench=. -benchmem $(BENCH_RUN) $(PKG)

bench-compare:
	@echo "==> Saving benchmark baseline..."
	go test -bench=. -benchmem -count=10 $(BENCH_RUN) $(PKG) > bench-old.txt
	@echo "  Saved to bench-old.txt"
	@echo "  After making changes, run:"
	@echo "    go test -bench=. -benchmem -count=10 $(BENCH_RUN) $(PKG) > bench-new.txt"
	@echo "    benchstat bench-old.txt bench-new.txt"

# --- Profiling ---
profile-cpu:
	@echo "==> CPU profiling..."
	go test -bench=. -cpuprofile=cpu.out $(BENCH_RUN) $(PKG)
	@echo "View: go tool pprof -http=:8080 cpu.out"

profile-mem:
	@echo "==> Memory profiling..."
	go test -bench=. -memprofile=mem.out -memprofilerate=1 $(BENCH_RUN) $(PKG)
	@echo "View: go tool pprof -http=:8080 mem.out"

profile-mutex:
	@echo "==> Mutex contention profiling..."
	go test -bench=. -mutexprofile=mutex.out $(BENCH_RUN) $(PKG)
	@echo "View: go tool pprof -http=:8080 mutex.out"

profile-block:
	@echo "==> Block profiling..."
	go test -bench=. -blockprofile=block.out $(BENCH_RUN) $(PKG)
	@echo "View: go tool pprof -http=:8080 block.out"

# --- Tracing ---
trace:
	@echo "==> Capturing execution trace..."
	go test -trace=trace.out $(PKG)
	@echo "View: go tool trace trace.out"

# --- Linting ---
vet:
	@echo "==> Running go vet..."
	go vet $(PKG)

lint: vet
	@echo "==> Running golangci-lint..."
	@which golangci-lint > /dev/null 2>&1 || \
		(echo "Install: go install github.com/golangci/golangci-lint/cmd/golangci-lint@latest" && exit 1)
	golangci-lint run $(PKG)

# --- Cleanup ---
clean:
	rm -rf bin/ *.out *.test trace.out
	go clean -cache -testcache

# --- Help ---
help:
	@echo "Targets:"
	@echo "  build             Build the binary"
	@echo "  build-race        Build with race detector"
	@echo "  test              Run tests"
	@echo "  test-race         Run tests with race detector"
	@echo "  test-race-repeat  Run tests 100x with race detector"
	@echo "  test-cover        Run tests with coverage report"
	@echo "  bench             Run benchmarks"
	@echo "  bench-compare     Save benchmark baseline for comparison"
	@echo "  profile-cpu       CPU profile via benchmarks"
	@echo "  profile-mem       Memory profile via benchmarks"
	@echo "  profile-mutex     Mutex contention profile"
	@echo "  profile-block     Block profile (goroutine wait times)"
	@echo "  trace             Capture execution trace"
	@echo "  vet               Run go vet"
	@echo "  lint              Run golangci-lint"
	@echo "  clean             Remove build artifacts and caches"
