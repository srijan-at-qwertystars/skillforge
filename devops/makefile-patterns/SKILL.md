---
name: makefile-patterns
description:
  positive: "Use when user writes Makefiles, asks about GNU Make syntax, targets, prerequisites, variables, pattern rules, automatic variables, or just/justfile task runners."
  negative: "Do NOT use for CMake (build system generator), Gradle, or npm scripts without Make context."
---

# Makefile & Just Patterns

## Make Fundamentals

### Targets, Prerequisites, Recipes

```makefile
# Structure: target: prerequisites
#	recipe (MUST be indented with a tab, not spaces)
app: main.o utils.o
	$(CC) -o $@ $^

main.o: main.c main.h
	$(CC) $(CFLAGS) -c $<
```

- The **first target** in the file is the **default goal** (convention: name it `all`).
- Each recipe line runs in its own shell. Chain commands with `&&` or use backslash continuation.

### .PHONY Targets

Declare targets that don't produce files:

```makefile
.PHONY: all clean test lint help

all: build test
```

Without `.PHONY`, a file named `clean` would prevent `make clean` from running.

### Single-Shell Recipes

```makefile
.ONESHELL:
deploy:
	cd $(BUILD_DIR)
	tar czf release.tar.gz .
	scp release.tar.gz $(SERVER):$(DEPLOY_PATH)
```

## Variables

### Assignment Operators

| Operator | Name | Behavior |
|----------|------|----------|
| `=` | Recursive | Expanded at use time (lazy). |
| `:=` | Simple | Expanded at assignment time (eager). Prefer this. |
| `?=` | Conditional | Set only if not already defined. |
| `+=` | Append | Append to existing value. |

```makefile
CC := gcc
CFLAGS := -Wall -O2
CFLAGS += -std=c17          # append
DESTDIR ?= /usr/local       # default, overridable

# Override from CLI:  make CFLAGS="-g -O0"
```

### Target-Specific Variables

```makefile
debug: CFLAGS += -g -DDEBUG -O0
debug: build
```

### Environment & override

```makefile
# Environment variables become Make variables automatically.
# Use override to force a value even against CLI overrides:
override CFLAGS += -Werror
```

## Automatic Variables

| Variable | Expands To |
|----------|-----------|
| `$@` | Target filename |
| `$<` | First prerequisite |
| `$^` | All prerequisites (deduped) |
| `$+` | All prerequisites (with duplicates) |
| `$?` | Prerequisites newer than target |
| `$*` | Stem matched by `%` in pattern rule |
| `$(@D)` | Directory part of `$@` |
| `$(@F)` | Filename part of `$@` |

```makefile
build/%.o: src/%.c | build
	$(CC) $(CFLAGS) -c $< -o $@
	@echo "Built $(@F) from $(<F) [stem: $*]"
```

## Pattern Rules & Implicit Rules

### Basic Pattern Rule

```makefile
%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@
```

### Static Pattern Rule

Apply a pattern to an explicit list of targets:

```makefile
OBJECTS := foo.o bar.o baz.o

$(OBJECTS): %.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@
```

### Auto-Dependency Generation

```makefile
DEPFLAGS = -MMD -MP
CFLAGS += $(DEPFLAGS)

-include $(OBJECTS:.o=.d)
```

`-MMD` generates `.d` files listing header deps. `-MP` adds phony targets for deleted headers. The `-include` silently includes them if they exist.

## Functions

### File & String Functions

```makefile
SRC := $(wildcard src/*.c src/**/*.c)
OBJ := $(patsubst src/%.c,build/%.o,$(SRC))
C_ONLY := $(filter %.c,$(SRC))
NO_TEST := $(filter-out %_test.c,$(SRC))
BASENAME := $(basename $(notdir $(SRC)))
```

### Iteration

```makefile
MODULES := auth api db
test-all:
	$(foreach mod,$(MODULES),$(MAKE) -C $(mod) test &&) true
```

### Shell Execution

```makefile
GIT_SHA := $(shell git rev-parse --short HEAD)
DATE := $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
```

### User-Defined Functions

```makefile
log = @echo "[$(1)] $(2)"

build:
	$(call log,INFO,Compiling $(words $(OBJ)) objects)
	$(CC) $(CFLAGS) -c $(SRC)
```

## Conditionals

```makefile
# Directive-based
ifeq ($(OS),Windows_NT)
    RM := del /Q
else
    RM := rm -f
endif

ifdef VERBOSE
    Q :=
else
    Q := @
endif

ifndef CI
    CFLAGS += -g
endif

# Function-based (inline)
OUTDIR := $(if $(DEBUG),build/debug,build/release)
```

## Multi-Directory Projects

### Non-Recursive (preferred)

```makefile
SRCDIRS := src src/core src/net
SRC := $(foreach dir,$(SRCDIRS),$(wildcard $(dir)/*.c))
OBJ := $(SRC:%.c=build/%.o)
VPATH := $(SRCDIRS)

build/%.o: %.c | build
	@mkdir -p $(@D)
	$(CC) $(CFLAGS) -c $< -o $@
```

### Recursive (use sparingly)

```makefile
SUBDIRS := lib app tests
.PHONY: $(SUBDIRS)
$(SUBDIRS):
	$(MAKE) -C $@
```

Recursive make obscures the dependency graph. Prefer non-recursive with `include`.

### Include

```makefile
include config.mk
-include local.mk   # optional, no error if missing
```

## Common Targets

```makefile
.DEFAULT_GOAL := all
all: build

build:
	go build -ldflags "-X main.version=$(VERSION)" -o bin/app ./cmd/app
test:
	go test -race -cover ./...
lint:
	golangci-lint run
fmt:
	gofmt -w .
clean:
	rm -rf bin/ build/ *.o
install: build
	install -m 755 bin/app $(DESTDIR)/bin/
docker:
	docker build -t $(IMAGE):$(TAG) .
docker-push: docker
	docker push $(IMAGE):$(TAG)

.PHONY: all build test lint fmt clean install docker docker-push
```

## Self-Documenting Makefile

```makefile
.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

build: ## Build the application
	go build -o bin/app .

test: ## Run tests with coverage
	go test -cover ./...

clean: ## Remove build artifacts
	rm -rf bin/
```

Run `make help` to print a formatted list of documented targets.

## Parallel Execution

```makefile
# Run: make -j$(nproc)

# Order-only prerequisite (|): build dir created first, not tracked for rebuild
build/%.o: src/%.c | build
	$(CC) $(CFLAGS) -c $< -o $@

build:
	mkdir -p build

# Disable parallel for specific targets
.NOTPARALLEL: deploy
```

Set `MAKEFLAGS += -j$(shell nproc)` in the Makefile to default to parallel builds.

## just / justfile

`just` is a command runner (not a build system). Recipes always execute; no file-timestamp logic.

### Key Syntax Differences from Make

| Feature | Make | just |
|---------|------|------|
| Indentation | Tabs required | Spaces or tabs |
| Variables | `$(VAR)` | `{{VAR}}` |
| Arguments | Awkward (`$(filter-out $@,$(MAKECMDGOALS))`) | Native: `recipe arg:` |
| Shell | Each line = new shell | Each line = new shell (use `set shell` to change) |
| Default recipe | First target | First recipe, or `default` |
| Listing | DIY `help` target | Built-in `just --list` |

### Basic justfile

```just
set dotenv-load
VERSION := "1.0.0"
IMAGE := "myapp"

default: build test

build:
    cargo build --release
test *ARGS:
    cargo test {{ARGS}}
lint fix="false":
    #!/usr/bin/env bash
    if [ "{{fix}}" = "true" ]; then cargo clippy --fix; else cargo clippy; fi
deploy env="staging":
    kubectl apply -k deploy/{{env}}
docker tag=VERSION:
    docker build -t {{IMAGE}}:{{tag}} .
    docker push {{IMAGE}}:{{tag}}
```

### Arguments & Variadic Parameters

```just
greet name="world":           # positional with default
    echo "Hello, {{name}}!"
run *ARGS:                    # variadic (zero or more)
    cargo run -- {{ARGS}}
test +FILES:                  # variadic (one or more required)
    pytest {{FILES}}
```

### Conditional Execution

```just
compile:
    {{ if os() == "windows" { "cl /Fe:app.exe" } else { "gcc -o app" } }} main.c

BRANCH := `git branch --show-current`
```

### Modules & Imports

```just
import 'ci.just'       # import recipes from another file
mod docker              # namespaced module: just docker build
```

### Recipe Attributes

```just
@clean:                            # @ suppresses command echo
    rm -rf build/

[working-directory: 'frontend']    # run in specific directory
build-ui:
    npm run build

[confirm("Are you sure?")]         # prompt before running
nuke:
    rm -rf /data/*
```

## Taskfile.yml (Brief Comparison)

```yaml
# Taskfile.yml – Go-based task runner
version: "3"
tasks:
  build:
    desc: Build the application
    cmds:
      - go build -o bin/app .
    sources:
      - "**/*.go"
    generates:
      - bin/app
  test:
    desc: Run tests
    cmds:
      - go test ./...
```

**When to choose Taskfile**: YAML syntax preferred, checksum-based deps, teams uncomfortable with Make. **When to choose just**: Make-familiar syntax, rich argument handling, no YAML overhead. **When to choose Make**: File-based dependency graphs, C/C++ builds, maximum portability.

## Project Templates

### Go Project

```makefile
BINARY := myapp
VERSION := $(shell git describe --tags --always)
LDFLAGS := -ldflags "-X main.version=$(VERSION)"
.PHONY: all build test lint clean

all: lint test build
build:
	CGO_ENABLED=0 go build $(LDFLAGS) -o bin/$(BINARY) ./cmd/$(BINARY)
test:
	go test -race -coverprofile=coverage.out ./...
lint:
	golangci-lint run
clean:
	rm -rf bin/ coverage.out
```

### Python Project

```makefile
VENV := .venv
PYTHON := $(VENV)/bin/python
.PHONY: venv install test lint clean

venv:
	python3 -m venv $(VENV)
install: venv
	$(VENV)/bin/pip install -r requirements.txt -r requirements-dev.txt
test: install
	$(PYTHON) -m pytest tests/ -v --cov=src
lint:
	$(PYTHON) -m ruff check src/ tests/
clean:
	rm -rf $(VENV) .pytest_cache .coverage __pycache__
```

### Node.js Project

```makefile
.PHONY: install build test lint clean
install:
	npm ci
build: install
	npm run build
test: install
	npm test
lint: install
	npm run lint
clean:
	rm -rf node_modules dist .next
```

### Docker Project

```makefile
IMAGE := myorg/myapp
TAG := $(shell git rev-parse --short HEAD)
REGISTRY := ghcr.io
.PHONY: build push run clean

build:
	docker build -t $(IMAGE):$(TAG) -t $(IMAGE):latest .
push: build
	docker tag $(IMAGE):$(TAG) $(REGISTRY)/$(IMAGE):$(TAG)
	docker push $(REGISTRY)/$(IMAGE):$(TAG)
run:
	docker run --rm -p 8080:8080 $(IMAGE):latest
clean:
	docker rmi $(IMAGE):$(TAG) $(IMAGE):latest 2>/dev/null || true
```

## Anti-Patterns

### Recursive Make Pitfalls

Recursive `$(MAKE) -C subdir` breaks the global dependency graph. Make cannot parallelize across sub-makes and may rebuild unnecessarily. Prefer non-recursive make with `include`.

### Shell-Heavy Recipes

Move complex logic (>5 lines of shell) into scripts:

```makefile
deploy:  # Good: thin wrapper
	./scripts/deploy.sh $(ENV) $(VERSION)
```

### Other Pitfalls

- **Missing `.PHONY`**: Causes silent skips when a file matches the target name.
- **Recursive `=`**: Use `:=` by default to avoid re-expansion and perf issues.
- **Ignoring errors blindly**: Avoid `-` prefix; use `|| true` for specific commands.
- **Hardcoded paths**: Use variables (`PYTHON := python3`) so users can override.
- **Not using `$(MAKE)`**: Always use `$(MAKE)` for recursive calls to preserve flags.

<!-- tested: pass -->
