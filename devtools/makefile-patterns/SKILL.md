---
name: makefile-patterns
description: >
  Guide for writing production-grade GNU Makefiles with correct syntax, automatic variables,
  pattern rules, functions, conditionals, and modern project templates. Use when user needs
  Makefile, GNU Make, build automation with make, Makefile targets, make recipes, make
  variables, pattern rules, phony targets, parallel builds, Makefile debugging, or
  self-documenting Makefiles. NOT for CMake, NOT for Bazel/Buck build systems, NOT for
  npm scripts or task runners like Just or Task, NOT for CI/CD pipeline configuration
  files like GitHub Actions or Jenkins.
---

# Makefile Patterns

## Core Syntax

Every rule follows: target, prerequisites, recipe (tab-indented).

```makefile
target: prerequisites
	recipe-command
```

CRITICAL: Recipes MUST use literal tab characters, not spaces. A space-indented recipe causes `*** missing separator` errors.

Set the default target explicitly:

```makefile
.DEFAULT_GOAL := all
```

## Automatic Variables

Use these inside recipes only:

| Variable | Expands To | Example Context |
|----------|-----------|-----------------|
| `$@` | Target filename | `gcc -o $@` → `gcc -o myapp` |
| `$<` | First prerequisite | `gcc -c $<` → `gcc -c main.c` |
| `$^` | All prerequisites (deduped) | `gcc $^ -o $@` → `gcc main.o util.o -o myapp` |
| `$?` | Prerequisites newer than target | Incremental operations |
| `$*` | Stem matched by `%` in pattern rule | `%.o: %.c` with `foo.o` → `$*` is `foo` |
| `$(@D)` | Directory part of `$@` | `mkdir -p $(@D)` |
| `$(@F)` | File part of `$@` | Logging the output filename |

## Variable Assignment

```makefile
CC = gcc          # Recursive: re-evaluated on every use
CC := gcc         # Simple: evaluated once at assignment time
CC ?= gcc         # Conditional: set only if not already defined
CFLAGS += -Wall   # Append: add to existing value
```

When to use each:
- Use `:=` by default to avoid circular references and improve performance.
- Use `=` when the value depends on variables defined later.
- Use `?=` for user-overridable defaults (e.g., `CC ?= gcc`).
- Use `+=` to accumulate flags or file lists.

```makefile
# Input: CFLAGS is empty
CFLAGS := -std=c11
CFLAGS += -Wall
CFLAGS += -O2
# Result: CFLAGS is "-std=c11 -Wall -O2"
```

## Pattern Rules

Replace repetitive rules with `%` wildcard:

```makefile
# Instead of writing a rule per .o file:
%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

# Static pattern rule — restrict to a known list:
OBJECTS := foo.o bar.o baz.o
$(OBJECTS): %.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@
```

## Phony Targets

Declare targets that don't produce files:

```makefile
.PHONY: all build test lint clean help deploy

all: build test
```

Without `.PHONY`, if a file named `clean` exists, `make clean` does nothing.

## Functions

### File and String Functions

```makefile
SOURCES := $(wildcard src/*.c)
# Input: src/ contains main.c, util.c, parse.c
# Result: SOURCES = src/main.c src/util.c src/parse.c

OBJECTS := $(patsubst src/%.c,build/%.o,$(SOURCES))
# Result: OBJECTS = build/main.o build/util.o build/parse.o

# Shorter substitution reference form:
OBJECTS := $(SOURCES:src/%.c=build/%.o)

C_FILES := $(filter %.c,$(ALL_FILES))
# Keeps only .c files from a mixed list

NON_TESTS := $(filter-out %_test.c,$(SOURCES))
# Removes test files from source list
```

### Iteration and Shell

```makefile
DIRS := src lib tests
$(foreach dir,$(DIRS),$(wildcard $(dir)/*.c))
# Collects all .c files across multiple directories

GIT_SHA := $(shell git rev-parse --short HEAD)
# Captures command output into a variable

VERSION := $(shell cat VERSION 2>/dev/null || echo "dev")
```

### User-Defined Functions with call

```makefile
define log
	@echo "[$(1)] $(2)"
endef

build:
	$(call log,BUILD,Compiling sources...)
	$(CC) $(CFLAGS) -o $@ $(SOURCES)
# Output: [BUILD] Compiling sources...
```

### Other Useful Functions

```makefile
$(addprefix build/,$(OBJECTS))   # Prepend path      $(addsuffix .bak,$(FILES))  # Append suffix
$(notdir src/main.c)             # → main.c          $(dir src/main.c)           # → src/
$(basename src/main.c)           # → src/main         $(suffix src/main.c)        # → .c
$(word 2,foo bar baz)            # → bar             $(words foo bar baz)         # → 3
$(sort foo bar baz bar)          # → bar baz foo (deduped+sorted)
$(strip  spaced  out )           # → spaced out
$(if $(DEBUG),yes,no)            # Conditional        $(or $(A),$(B),default)     # First non-empty
```

## Conditional Directives

```makefile
ifeq ($(OS),Windows_NT)        # Test equality
    RM := del /Q
else
    RM := rm -f
endif

ifdef VERBOSE                  # Test if defined
    Q :=
else
    Q := @
endif

ifndef CI                      # Test if not defined
    DOCKER_FLAGS += -it
endif

ifneq ($(DEBUG),)              # Test inequality
    CFLAGS += -g -O0
endif
```

## Include Directives

```makefile
# Hard include — error if missing:
include config.mk

# Soft include — silently skip if missing:
-include .env.mk
-include $(OBJECTS:.o=.d)  # Auto-generated dependency files
```

Generate dependency files for C/C++:

```makefile
DEPFLAGS = -MMD -MP -MF $(@:.o=.d)
%.o: %.c
	$(CC) $(CFLAGS) $(DEPFLAGS) -c $< -o $@
-include $(OBJECTS:.o=.d)
```

## VPATH and vpath

Search for prerequisites in alternate directories:

```makefile
# Global search path for all files:
VPATH = src:lib:../shared

# Pattern-specific search (preferred — more precise):
vpath %.c src lib
vpath %.h include
```

## Order-Only Prerequisites

Use `|` to declare prerequisites that must exist but whose timestamps are ignored:

```makefile
build/%.o: src/%.c | build/
	$(CC) -c $< -o $@

build/:
	mkdir -p $@
```

The `build/` directory is created if missing, but changes to it don't trigger rebuilds.

## .SUFFIXES

Disable all built-in suffix rules for a clean slate:

```makefile
.SUFFIXES:
```

This prevents Make's implicit rules (like `.c` → `.o`) from interfering.

## Parallel Execution

```bash
make -j$(nproc)          # Use all CPU cores
make -j8                 # Use 8 parallel jobs
make -j8 -O              # Parallel with synchronized output per target
make -j8 -Otarget        # Group output by target (cleaner logs)
make -j8 --output-sync=recurse  # Sync output in recursive make
```

Ensure rules with ordering constraints declare proper dependencies. Use `.NOTPARALLEL:` to disable parallelism for specific targets if needed.

## Debugging

```bash
make -n                  # Dry run: print commands without executing
make -p --no-builtin-rules | grep -A5 'myvar'  # Find specific variable
make --debug=b           # Basic: show what needs rebuilding and why
make --debug=v           # Verbose: full decision-making trace
make --trace             # Print each recipe with context before execution
make -W file.c build     # Pretend file.c is modified, show what rebuilds
```

Add a variable-inspection target:

```makefile
.PHONY: print-%
print-%:
	@echo '$* = $($*)'
# Usage: make print-CFLAGS → "CFLAGS = -Wall -O2"
```

## Self-Documenting Help Target

Annotate targets with `## comment`. The help target extracts and formats them:

```makefile
.DEFAULT_GOAL := help

help: ## Show this help message
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

build: ## Build the application
	go build -o bin/app ./cmd/app

test: ## Run all tests
	go test -race ./...

clean: ## Remove build artifacts
	rm -rf bin/ dist/
# Output of `make help`:
#   build                Build the application
#   test                 Run all tests
#   clean                Remove build artifacts
```

## Recursive vs Non-Recursive Make

**Recursive** — each subdirectory has its own Makefile:

```makefile
SUBDIRS := lib app tests
.PHONY: $(SUBDIRS)
$(SUBDIRS):
	$(MAKE) -C $@
app: lib              # Declare ordering between subdirectories
```

Drawback: cross-directory dependencies are invisible to Make.

**Non-recursive** (preferred) — single process, included modules:

```makefile
MODULES := lib app tests
include $(addsuffix /module.mk,$(MODULES))
# Each module.mk appends to shared SOURCES, OBJECTS, etc.
```

## Modern Project Templates

### Go Project

```makefile
BINARY := myapp
VERSION := $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
LDFLAGS := -s -w -X main.version=$(VERSION)
.PHONY: build test lint clean docker

build: ## Build binary
	CGO_ENABLED=0 go build -ldflags '$(LDFLAGS)' -o bin/$(BINARY) ./cmd/$(BINARY)

test: ## Run tests with race detector
	go test -race -cover ./...

lint: ## Run golangci-lint
	golangci-lint run --timeout 5m

clean: ## Remove build artifacts
	rm -rf bin/ dist/ coverage.out

docker: ## Build Docker image
	docker build -t $(BINARY):$(VERSION) .
```

### Node.js Project

```makefile
NODE_MODULES := node_modules/.package-lock.json

$(NODE_MODULES): package.json package-lock.json
	npm ci && touch $@

.PHONY: build test lint dev clean

build: $(NODE_MODULES) ## Build for production
	npm run build

test: $(NODE_MODULES) ## Run test suite
	npm test

lint: $(NODE_MODULES) ## Lint and format check
	npm run lint

dev: $(NODE_MODULES) ## Start dev server
	npm run dev

clean: ## Remove artifacts and dependencies
	rm -rf node_modules dist .next .cache
```

### Python Project

```makefile
VENV := .venv
PYTHON := $(VENV)/bin/python

$(VENV)/bin/activate: requirements.txt
	python3 -m venv $(VENV)
	$(VENV)/bin/pip install --upgrade pip && $(VENV)/bin/pip install -r requirements.txt
	@touch $@

.PHONY: install test lint format clean

install: $(VENV)/bin/activate ## Install dependencies

test: install ## Run tests
	$(PYTHON) -m pytest tests/ -v --cov=src

lint: install ## Run linters
	$(PYTHON) -m ruff check src/ tests/ && $(PYTHON) -m mypy src/

format: install ## Format code
	$(PYTHON) -m ruff format src/ tests/

clean: ## Remove artifacts and virtualenv
	rm -rf $(VENV) __pycache__ .pytest_cache .mypy_cache dist *.egg-info
```

### Docker Multi-Stage

```makefile
IMAGE := myapp
REGISTRY := ghcr.io/myorg
TAG := $(shell git rev-parse --short HEAD)
.PHONY: docker-build docker-push docker-run

docker-build: ## Build Docker image
	docker build --build-arg VERSION=$(TAG) --target production \
		-t $(REGISTRY)/$(IMAGE):$(TAG) -t $(REGISTRY)/$(IMAGE):latest .

docker-push: docker-build ## Push to registry
	docker push $(REGISTRY)/$(IMAGE):$(TAG)
	docker push $(REGISTRY)/$(IMAGE):latest

docker-run: ## Run container locally
	docker run --rm -p 8080:8080 $(REGISTRY)/$(IMAGE):$(TAG)
```

## Common Patterns

### Guard against missing tools

```makefile
REQUIRED_BINS := go docker kubectl
$(foreach bin,$(REQUIRED_BINS),\
	$(if $(shell command -v $(bin) 2>/dev/null),,\
		$(error "$(bin) is required but not installed")))
```

### Environment file loading

```makefile
ifneq (,$(wildcard .env))
    include .env
    export
endif
```

### Confirmation prompt for destructive actions

```makefile
deploy: ## Deploy to production (requires confirmation)
	@echo "Deploying to PRODUCTION. Press Ctrl+C to cancel."
	@read -p "Are you sure? [y/N] " ans && [ "$$ans" = "y" ]
	./scripts/deploy.sh production
```

### Timestamped build artifacts

```makefile
TIMESTAMP := $(shell date +%Y%m%d_%H%M%S)
release:
	tar czf dist/release-$(TIMESTAMP).tar.gz -C build .
```

### Multi-platform builds

```makefile
PLATFORMS := linux/amd64 linux/arm64 darwin/amd64 darwin/arm64

define build_platform
build-$(subst /,-,$(1)):
	GOOS=$(word 1,$(subst /, ,$(1))) GOARCH=$(word 2,$(subst /, ,$(1))) \
		go build -o bin/app-$(subst /,-,$(1)) ./cmd/app
endef

$(foreach platform,$(PLATFORMS),$(eval $(call build_platform,$(platform))))

build-all: $(foreach p,$(PLATFORMS),build-$(subst /,-,$(p))) ## Build for all platforms
```

## Makefile vs Task Runners

| Aspect | GNU Make | Just | Task (Taskfile) |
|--------|---------|------|-----------------|
| Dependency tracking | File-based timestamps | None (always runs) | Checksum-based |
| Syntax | Tab-sensitive | Space-friendly | YAML |
| Parameterization | Env vars, awkward | Built-in args | Built-in vars |
| Availability | Pre-installed on Unix | Requires install | Requires install |
| Best for | File-based builds | Command running | Cross-platform tasks |

Use Make when: file-based dependency tracking matters, POSIX compatibility is required, or the project already uses Make. Use Just/Task when: running developer workflow commands that don't produce file outputs.

## Key Anti-Patterns to Avoid

- Never use spaces for recipe indentation — tabs only.
- Never omit `.PHONY` for non-file targets.
- Avoid recursive `$(MAKE)` calls when flat includes work.
- Don't use `:=` for variables that reference not-yet-defined variables.
- Don't put side effects in variable assignments via `$(shell ...)` at parse time.
- Escape `$` in shell commands as `$$` (e.g., `$$HOME`, `$$variable`).
- Always quote `$(MAKEFILE_LIST)` in grep-based help targets.

## Reference Documentation

In-depth guides in `references/`:

- **`references/advanced-patterns.md`** — Non-recursive Make (Peter Miller), generated dependencies, order-only prerequisites, secondary expansion, target-specific variables, multi-line recipes, `eval`/`call` metaprogramming, Makefile includes for modularity, parallel builds, `.ONESHELL`, `.DELETE_ON_ERROR`, `.INTERMEDIATE`/`.PRECIOUS`. Includes table of contents.
- **`references/troubleshooting.md`** — Common errors (missing separator, no rule to make target, circular dependency), debugging with `--debug=v`, `-n`, `-p`, `$(info)`/`$(warning)`/`$(error)`, recipe execution environment, shell compatibility, tab vs spaces, Windows compatibility. Includes table of contents and decision tree.

## Scripts

