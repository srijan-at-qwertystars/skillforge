# ============================================================================
# Go Project Makefile
# ============================================================================
# Copy-paste ready Makefile for Go projects.
# Targets: build, test, lint, docker, release, and more.
# Usage: make help
# ============================================================================

.DEFAULT_GOAL := help
.DELETE_ON_ERROR:
.SUFFIXES:

# ─── Project Configuration ──────────────────────────────────
BINARY     := $(shell basename $(CURDIR))
CMD_DIR    := ./cmd/$(BINARY)
VERSION    := $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
COMMIT     := $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
BRANCH     := $(shell git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)
BUILD_TIME := $(shell date -u +%Y-%m-%dT%H:%M:%SZ)

# Linker flags for embedding build metadata
LDFLAGS := -s -w \
    -X main.version=$(VERSION) \
    -X main.commit=$(COMMIT) \
    -X main.branch=$(BRANCH) \
    -X main.buildTime=$(BUILD_TIME)

# Go settings
GOFILES     := $(shell find . -name '*.go' -not -path './vendor/*')
GOPACKAGES  := ./...
GOTEST_ARGS ?= -count=1
CGO_ENABLED ?= 0

# Docker settings
IMAGE       := $(BINARY)
REGISTRY    ?= ghcr.io/$(shell git config user.name 2>/dev/null || echo myorg)
DOCKER_TAG  := $(VERSION)

# Release settings
DIST_DIR    := dist
PLATFORMS   := linux-amd64 linux-arm64 darwin-amd64 darwin-arm64

# Tool versions (pin for reproducibility)
GOLANGCI_LINT_VERSION ?= v1.61.0

# ─── Build Targets ──────────────────────────────────────────
.PHONY: all build build-all run install

all: lint test build ## Lint, test, and build

build: ## Build binary for current platform
	CGO_ENABLED=$(CGO_ENABLED) go build -ldflags '$(LDFLAGS)' -o bin/$(BINARY) $(CMD_DIR)

define build_platform
.PHONY: build-$(1)
build-$(1):
	@echo "Building for $(1)..."
	CGO_ENABLED=0 GOOS=$$(word 1,$$(subst -, ,$(1))) GOARCH=$$(word 2,$$(subst -, ,$(1))) \
		go build -ldflags '$$(LDFLAGS)' -o $(DIST_DIR)/$(BINARY)-$(1) $(CMD_DIR)
endef

$(foreach p,$(PLATFORMS),$(eval $(call build_platform,$(p))))

build-all: $(addprefix build-,$(PLATFORMS)) ## Build for all platforms

run: build ## Build and run
	./bin/$(BINARY)

install: ## Install binary to GOPATH/bin
	go install -ldflags '$(LDFLAGS)' $(CMD_DIR)

# ─── Test Targets ───────────────────────────────────────────
.PHONY: test test-race test-cover test-short test-bench

test: ## Run tests
	go test $(GOTEST_ARGS) $(GOPACKAGES)

test-race: ## Run tests with race detector
	go test -race $(GOTEST_ARGS) $(GOPACKAGES)

test-cover: ## Run tests with coverage report
	go test -race -coverprofile=coverage.out -covermode=atomic $(GOPACKAGES)
	go tool cover -func=coverage.out
	go tool cover -html=coverage.out -o coverage.html
	@echo "Coverage report → coverage.html"

test-short: ## Run short tests only
	go test -short $(GOTEST_ARGS) $(GOPACKAGES)

test-bench: ## Run benchmarks
	go test -bench=. -benchmem $(GOPACKAGES)

# ─── Code Quality ──────────────────────────────────────────
.PHONY: lint fmt vet tidy generate check

lint: ## Run golangci-lint
	golangci-lint run --timeout 5m $(GOPACKAGES)

fmt: ## Format code
	gofmt -s -w $(GOFILES)
	@command -v goimports >/dev/null 2>&1 && goimports -w $(GOFILES) || true

vet: ## Run go vet
	go vet $(GOPACKAGES)

tidy: ## Tidy and verify module dependencies
	go mod tidy
	go mod verify

generate: ## Run go generate
	go generate $(GOPACKAGES)

check: fmt vet tidy ## Format, vet, and tidy (pre-commit check)
	@git diff --exit-code --quiet || \
		(echo "Working tree is dirty after fmt/vet/tidy. Please commit changes." && exit 1)

# ─── Docker Targets ─────────────────────────────────────────
.PHONY: docker docker-push docker-run

docker: ## Build Docker image
	docker build \
		--build-arg VERSION=$(VERSION) \
		--build-arg COMMIT=$(COMMIT) \
		--build-arg BUILD_TIME=$(BUILD_TIME) \
		-t $(REGISTRY)/$(IMAGE):$(DOCKER_TAG) \
		-t $(REGISTRY)/$(IMAGE):latest .

docker-push: docker ## Push Docker image to registry
	docker push $(REGISTRY)/$(IMAGE):$(DOCKER_TAG)
	docker push $(REGISTRY)/$(IMAGE):latest

docker-run: ## Run Docker container locally
	docker run --rm -it -p 8080:8080 $(REGISTRY)/$(IMAGE):$(DOCKER_TAG)

# ─── Release Targets ────────────────────────────────────────
.PHONY: release release-dry changelog

release: build-all ## Create release archives
	@mkdir -p $(DIST_DIR)
	@for platform in $(PLATFORMS); do \
		echo "Packaging $$platform..."; \
		tar czf $(DIST_DIR)/$(BINARY)-$$platform.tar.gz \
			-C $(DIST_DIR) $(BINARY)-$$platform; \
		sha256sum $(DIST_DIR)/$(BINARY)-$$platform.tar.gz >> $(DIST_DIR)/checksums.txt; \
	done
	@echo "Release artifacts → $(DIST_DIR)/"

release-dry: ## Dry-run release (show what would be built)
	@echo "Binary:   $(BINARY)"
	@echo "Version:  $(VERSION)"
	@echo "Commit:   $(COMMIT)"
	@echo "Platforms: $(PLATFORMS)"

changelog: ## Generate changelog from git log
	@echo "# Changelog" > CHANGELOG.md
	@echo "" >> CHANGELOG.md
	@git log --oneline --no-merges $$(git describe --tags --abbrev=0 2>/dev/null)..HEAD >> CHANGELOG.md 2>/dev/null || \
		git log --oneline --no-merges >> CHANGELOG.md
	@echo "Changelog → CHANGELOG.md"

# ─── Utility Targets ────────────────────────────────────────
.PHONY: clean deps version print-% help

clean: ## Remove build artifacts
	rm -rf bin/ $(DIST_DIR)/ coverage.out coverage.html

deps: ## Download dependencies
	go mod download

version: ## Print version information
	@echo "Version:    $(VERSION)"
	@echo "Commit:     $(COMMIT)"
	@echo "Branch:     $(BRANCH)"
	@echo "Build Time: $(BUILD_TIME)"

print-%: ## Print any variable (usage: make print-VERSION)
	@echo '$* = $($*)'

help: ## Show this help message
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-15s\033[0m %s\n", $$1, $$2}'
