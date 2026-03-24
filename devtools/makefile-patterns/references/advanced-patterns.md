# Advanced GNU Make Patterns

A deep-dive into advanced GNU Make techniques for production build systems.

## Table of Contents

- [Non-Recursive Make (Peter Miller's Approach)](#non-recursive-make-peter-millers-approach)
- [Generated Dependencies](#generated-dependencies)
- [Order-Only Prerequisites](#order-only-prerequisites)
- [Secondary Expansion](#secondary-expansion)
- [Target-Specific Variables](#target-specific-variables)
- [Multi-Line Recipes](#multi-line-recipes)
- [Metaprogramming with eval and call](#metaprogramming-with-eval-and-call)
- [Makefile Includes for Modularity](#makefile-includes-for-modularity)
- [Parallel Builds with make --jobs](#parallel-builds-with-make---jobs)
- [.ONESHELL](#oneshell)
- [.DELETE_ON_ERROR](#delete_on_error)
- [.INTERMEDIATE and .PRECIOUS](#intermediate-and-precious)

---

## Non-Recursive Make (Peter Miller's Approach)

Peter Miller's 1997 paper "Recursive Make Considered Harmful" argues that
recursive Make (where each subdirectory invokes `$(MAKE)` on itself) is
fundamentally broken because it fragments the dependency graph. Each
sub-make only sees its own slice of dependencies, leading to incorrect
builds, missed rebuilds, and unreliable parallel execution.

### The Problem with Recursive Make

```makefile
# Traditional recursive approach — AVOID
SUBDIRS := lib src tests

.PHONY: all $(SUBDIRS)
all: $(SUBDIRS)

$(SUBDIRS):
	$(MAKE) -C $@

# Fragile ordering — Make can't verify cross-directory deps
src: lib
tests: src
```

Issues:
- Make cannot see that `src/app.o` depends on `lib/util.h`.
- Parallel builds (`-j`) may start `src` before `lib` finishes.
- A change in `lib/util.h` won't trigger a rebuild of `src/app.o`
  unless explicitly wired up.

### The Non-Recursive Solution

Use a single top-level Makefile that includes per-directory fragments:

```makefile
# Top-level Makefile
.SUFFIXES:
.DELETE_ON_ERROR:

# Each module appends to these variables
SRCS :=
BINS :=

include lib/module.mk
include src/module.mk
include tests/module.mk

# Global rules
OBJS := $(SRCS:.c=.o)

%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@
```

Each `module.mk` is self-contained:

```makefile
# lib/module.mk
lib_SRCS := lib/util.c lib/parse.c
SRCS += $(lib_SRCS)

lib/libutil.a: $(lib_SRCS:.c=.o)
	$(AR) rcs $@ $^
```

```makefile
# src/module.mk
src_SRCS := src/main.c src/app.c
SRCS += $(src_SRCS)

src/app: $(src_SRCS:.c=.o) lib/libutil.a
	$(CC) $(LDFLAGS) -o $@ $^

BINS += src/app
```

### Benefits

| Aspect | Recursive | Non-Recursive |
|--------|-----------|---------------|
| Dependency accuracy | Partial per-directory | Complete global graph |
| Parallel safety | Fragile ordering | Fully correct |
| Build speed | Redundant sub-make overhead | Single process |
| Cross-dir deps | Must be manually wired | Automatic |

### Scaling Tips

- Use `sp :=` (stack prefix) variables to avoid namespace collisions:
  ```makefile
  sp := $(sp).x
  dirstack_$(sp) := $(d)
  d := lib
  include $(d)/module.mk
  d := $(dirstack_$(sp))
  sp := $(basename $(sp))
  ```
- For very large projects, use `$(eval)` to generate per-directory rules
  from a template.

---

## Generated Dependencies

Auto-dependency generation ensures header changes trigger recompilation.
Modern compilers (GCC, Clang) emit dependency files directly.

### Basic Approach

```makefile
SRCS := $(wildcard src/*.c)
OBJS := $(SRCS:.c=.o)
DEPS := $(OBJS:.o=.d)

DEPFLAGS = -MMD -MP -MF $(@:.o=.d)

%.o: %.c
	$(CC) $(CFLAGS) $(DEPFLAGS) -c $< -o $@

-include $(DEPS)
```

Flag meanings:
- `-MMD`: Write dependency rules to `.d` file, excluding system headers.
- `-MP`: Add phony targets for each dependency (prevents errors when
  headers are deleted).
- `-MF`: Specify the output dependency file path.

### Advanced: Separate Dependency Directory

```makefile
DEPDIR := .deps
DEPFLAGS = -MT $@ -MMD -MP -MF $(DEPDIR)/$*.d

%.o: %.c | $(DEPDIR)
	$(CC) $(CFLAGS) $(DEPFLAGS) -c $< -o $@

$(DEPDIR):
	mkdir -p $@

-include $(wildcard $(DEPDIR)/*.d)
```

### Why `-MP` Matters

Without `-MP`, if you delete a header file, Make fails with:
```
No rule to make target 'deleted_header.h', needed by 'foo.o'.
```

`-MP` generates empty phony targets for each header, so Make simply
rebuilds instead of erroring.

### Atomic Dependency Updates

For build systems where partial writes could corrupt `.d` files:

```makefile
DEPFLAGS = -MMD -MP -MF $(@:.o=.d.tmp)

%.o: %.c
	$(CC) $(CFLAGS) $(DEPFLAGS) -c $< -o $@
	mv $(@:.o=.d.tmp) $(@:.o=.d)
```

---

## Order-Only Prerequisites

Normal prerequisites trigger rebuilds when they're newer than the target.
Order-only prerequisites (after `|`) only ensure the prerequisite exists;
timestamp changes are ignored.

### Directory Creation

The canonical use case:

```makefile
BUILDDIR := build

$(BUILDDIR)/%.o: src/%.c | $(BUILDDIR)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILDDIR):
	mkdir -p $@
```

Without order-only, every modification to the `build/` directory
(adding any file) would trigger recompilation of all objects.

### Nested Directories

```makefile
# Create all necessary subdirectories
DIRS := build build/lib build/src build/tests

$(DIRS):
	mkdir -p $@

build/lib/%.o: lib/%.c | build/lib
	$(CC) $(CFLAGS) -c $< -o $@

build/src/%.o: src/%.c | build/src
	$(CC) $(CFLAGS) -c $< -o $@
```

### Ensuring Tool Availability

```makefile
.PHONY: check-tools
check-tools:
	@command -v gcc >/dev/null || (echo "gcc not found" && exit 1)

build: src/main.c | check-tools
	$(CC) -o $@ $<
```

---

## Secondary Expansion

`.SECONDEXPANSION:` enables a second round of expansion for prerequisites.
During this second pass, automatic variables like `$@`, `$*` are available.

### Basic Usage

```makefile
.SECONDEXPANSION:

# Each program depends on its own .o file
PROGRAMS := foo bar baz
$(PROGRAMS): $$@.o
	$(CC) -o $@ $<
```

Without secondary expansion, `$@` has no value in the prerequisite list.
The `$$` escapes the first expansion, so `$$@` becomes `$@` during the
second pass.

### Per-Target Dependencies

```makefile
.SECONDEXPANSION:

# Each program has its own list of objects
foo_OBJS := foo.o util.o
bar_OBJS := bar.o parse.o util.o

PROGRAMS := foo bar
$(PROGRAMS): $$($$@_OBJS)
	$(CC) -o $@ $^
```

During secondary expansion of target `foo`:
1. `$$` → `$`
2. `$@` → `foo`
3. `$(foo_OBJS)` → `foo.o util.o`

### Directory-Based Rules

```makefile
.SECONDEXPANSION:

build/%.o: src/%.c | $$(dir $$@)
	$(CC) $(CFLAGS) -c $< -o $@

# The directory prerequisite is computed per-target
%/:
	mkdir -p $@
```

### Caveats

- Secondary expansion applies to all rules after the `.SECONDEXPANSION:`
  directive, not just the next one.
- Use `$$` consistently to escape the first pass. Forgetting causes
  silent incorrect behavior.
- Can make Makefiles harder to read — use comments liberally.

---

## Target-Specific Variables

Variables can be scoped to individual targets. They also propagate to
all prerequisites built as part of that target.

### Basic Usage

```makefile
# Global defaults
CFLAGS := -O2

# Debug build gets different flags
debug: CFLAGS := -g -O0 -DDEBUG
debug: build

# Release build
release: CFLAGS += -DNDEBUG -flto
release: build

build: $(OBJS)
	$(CC) $(CFLAGS) -o app $^
```

### Per-Target Compilation

```makefile
lib/secure.o: CFLAGS += -fstack-protector-strong -D_FORTIFY_SOURCE=2
lib/fast_path.o: CFLAGS += -O3 -march=native

# These objects get their specific CFLAGS when compiled
$(OBJS): %.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@
```

### Pattern-Specific Variables

```makefile
# All test binaries get test-specific flags
test_%: LDLIBS += -lcheck -lsubunit
test_%: CFLAGS += -DTESTING

test_%: test_%.o $(LIB_OBJS)
	$(CC) -o $@ $^ $(LDLIBS)
```

### Propagation Rules

Target-specific variables propagate to prerequisites:

```makefile
debug: CFLAGS := -g -O0
debug: app

# When building 'debug', all .o files compiled for 'app'
# also receive CFLAGS := -g -O0
app: main.o util.o
	$(CC) $(CFLAGS) -o $@ $^
```

**Warning**: This propagation can cause unexpected rebuilds when
alternating between `make debug` and `make release`. Use separate
build directories to avoid conflicts:

```makefile
debug: BUILDDIR := build/debug
release: BUILDDIR := build/release
```

---

## Multi-Line Recipes

### Using define/endef

`define` creates multi-line variables, commonly used as reusable recipe
fragments:

```makefile
define compile_and_link
	@echo "Compiling $< ..."
	$(CC) $(CFLAGS) -c $< -o $(@:.bin=.o)
	@echo "Linking $@ ..."
	$(CC) $(LDFLAGS) -o $@ $(@:.bin=.o) $(LDLIBS)
endef

%.bin: %.c
	$(compile_and_link)
```

### Canned Recipes

```makefile
define run_tests
	@echo "=== Running $(1) tests ==="
	@cd $(1) && ./run_tests.sh
	@echo "=== $(1) tests complete ==="
endef

.PHONY: test-unit test-integration
test-unit:
	$(call run_tests,unit)

test-integration:
	$(call run_tests,integration)
```

### Multi-Line with Line Continuations

```makefile
long-command:
	docker run --rm \
		-v $(PWD):/workspace \
		-e APP_ENV=test \
		-e DATABASE_URL=$(DB_URL) \
		--network=host \
		myimage:latest \
		./run-tests.sh
```

**Reminder**: Each line in a recipe normally runs in its own shell.
Use `\` for line continuation (same shell command) or `.ONESHELL` for
multi-line scripts.

---

## Metaprogramming with eval and call

`$(eval)` and `$(call)` together enable generating Makefile rules
dynamically — a powerful technique for DRY build systems.

### Basic Template Pattern

```makefile
# Template: generates build rules for a program
define PROGRAM_template
$(1): $$($(1)_OBJS)
	$$(CC) $$(LDFLAGS) -o $$@ $$^ $$($(1)_LIBS)

$(1)_OBJS := $$(patsubst %.c,%.o,$$($(1)_SRCS))
endef

# Define programs
server_SRCS := src/server.c src/net.c src/config.c
server_LIBS := -lpthread -lssl

client_SRCS := src/client.c src/net.c src/ui.c
client_LIBS := -lncurses

PROGRAMS := server client

# Generate rules for each program
$(foreach prog,$(PROGRAMS),$(eval $(call PROGRAM_template,$(prog))))
```

### Escaping Rules in eval/call

Inside `define` blocks used with `$(eval $(call ...))`:
- `$$` → `$` after `call` expansion (needed for Make variables)
- `$$$$` → `$$` → `$` after both `call` and `eval` (needed for shell `$`)

```makefile
define DOCKER_template
.PHONY: docker-$(1)
docker-$(1):
	docker build -t $(1):$$(VERSION) -f docker/Dockerfile.$(1) .
	@echo "Built $(1):$$$$(date +%s)"
endef
```

### Multi-Platform Build Generator

```makefile
PLATFORMS := linux-amd64 linux-arm64 darwin-amd64 darwin-arm64

define platform_rule
build-$(1):
	GOOS=$$(word 1,$$(subst -, ,$(1))) \
	GOARCH=$$(word 2,$$(subst -, ,$(1))) \
	go build -o bin/app-$(1) ./cmd/app
endef

$(foreach p,$(PLATFORMS),$(eval $(call platform_rule,$(p))))

build-all: $(addprefix build-,$(PLATFORMS))
```

### Generating Test Targets

```makefile
TEST_SUITES := unit integration e2e

define test_suite
.PHONY: test-$(1)
test-$(1):
	@echo "Running $(1) tests..."
	$(PYTHON) -m pytest tests/$(1)/ -v --tb=short
endef

$(foreach suite,$(TEST_SUITES),$(eval $(call test_suite,$(suite))))

test: $(addprefix test-,$(TEST_SUITES))
```

---

## Makefile Includes for Modularity

### Project Structure

```
project/
├── Makefile            # Top-level orchestrator
├── make/
│   ├── config.mk       # Shared variables and flags
│   ├── docker.mk       # Docker-related targets
│   ├── lint.mk          # Linting targets
│   └── release.mk       # Release/deploy targets
├── src/
│   └── module.mk        # Source module
└── tests/
    └── module.mk        # Test module
```

### Top-Level Makefile

```makefile
# Load configuration first
include make/config.mk

# Load feature modules
include make/docker.mk
include make/lint.mk
include make/release.mk

# Load source modules
include src/module.mk
include tests/module.mk
```

### Config Module

```makefile
# make/config.mk
PROJECT := myapp
VERSION := $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
COMMIT  := $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
BUILD_TIME := $(shell date -u +%Y-%m-%dT%H:%M:%SZ)

# Detect OS
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
    SED := gsed
    OPEN := open
else
    SED := sed
    OPEN := xdg-open
endif
```

### Conditional Includes

```makefile
# Include local developer overrides if they exist
-include local.mk

# Include CI-specific settings
ifdef CI
    include make/ci.mk
endif

# Include OS-specific settings
-include make/$(shell uname -s | tr A-Z a-z).mk
```

---

## Parallel Builds with make --jobs

### Basic Usage

```bash
make -j$(nproc)               # Use all CPU cores
make -j$(nproc) -l$(nproc)    # Limit by load average too
make -j8 -Otarget             # Parallel with output grouped by target
```

### Output Synchronization Modes

| Flag | Behavior |
|------|----------|
| `-O` or `-Onone` | No synchronization (interleaved output) |
| `-Otarget` | Group output by target |
| `-Oline` | Synchronize per output line |
| `-Orecurse` | Synchronize per recursive make |

### Parallel-Safe Patterns

```makefile
# BAD: Two rules write to the same file
gen-header:
	./gen.sh > include/generated.h

gen-source:
	./gen.sh > src/generated.c

# GOOD: Make both depend on a single generation step
generated: gen.input
	./gen.sh --header > include/generated.h
	./gen.sh --source > src/generated.c

gen-header gen-source: generated
```

### .NOTPARALLEL

Disable parallelism globally or for specific targets:

```makefile
# Disable parallelism entirely (last resort)
.NOTPARALLEL:

# Better: declare actual dependencies between targets
deploy: build test
test: build
```

### Grouped Targets (GNU Make 4.3+)

When a single recipe produces multiple outputs:

```makefile
# The &: syntax declares grouped targets — the recipe runs once
foo.h foo.c &: foo.template
	./generate.sh foo.template foo.h foo.c
```

Without `&:`, Make might run the recipe multiple times in parallel.

---

## .ONESHELL

By default, each line of a recipe runs in a separate shell invocation.
`.ONESHELL` makes the entire recipe run in a single shell.

### Basic Usage

```makefile
.ONESHELL:
SHELL := /bin/bash

deploy:
	set -euo pipefail
	echo "Deploying version $(VERSION)..."
	cd deploy/
	terraform init
	terraform plan -out=tfplan
	terraform apply tfplan
	echo "Deploy complete"
```

Without `.ONESHELL`, the `cd deploy/` would have no effect on
subsequent lines because each runs in a fresh shell.

### Combining with set -e

```makefile
.ONESHELL:
SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

test:
	echo "Running tests..."
	result=$$(./run_tests.sh)
	if [ $$? -ne 0 ]; then
		echo "Tests failed: $$result"
		exit 1
	fi
	echo "All tests passed"
```

### Caveats

- `.ONESHELL` is **global** — it affects all recipes in the Makefile.
- The `@`, `-`, and `+` prefixes only apply to the **first line**.
- Make still processes `$` signs, so shell variables need `$$`.
- Not available in Make versions before 3.82.

### When to Use

- Multi-line shell scripts with `cd`, variables, loops.
- When you need consistent error handling (`set -e`).
- Complex deployment or setup scripts.

### When NOT to Use

- Simple one-line-per-command recipes (adds unnecessary coupling).
- When you need per-line `@` (silence) or `-` (ignore errors).

---

## .DELETE_ON_ERROR

When a recipe fails, Make normally leaves the partially-created target
file in place. This is dangerous: the next `make` invocation sees the
file exists and skips rebuilding it.

### Usage

```makefile
.DELETE_ON_ERROR:

output.json: input.csv
	./transform.sh $< > $@
```

If `transform.sh` fails mid-write, Make deletes `output.json` instead
of leaving a corrupt file.

### Best Practice

**Always include `.DELETE_ON_ERROR:` at the top of every Makefile.**
There's virtually no downside, and it prevents an entire class of
"works on clean build but fails on incremental build" bugs.

```makefile
# Put these at the top of every Makefile
.DELETE_ON_ERROR:
.SUFFIXES:
```

### Exception: Expensive Targets

For targets that are very expensive to create (hours of computation),
you might want to keep partial results. Use `.PRECIOUS` selectively:

```makefile
.DELETE_ON_ERROR:
.PRECIOUS: expensive-model.bin

expensive-model.bin: training-data.csv
	./train.sh $< $@   # Takes 6 hours
```

---

## .INTERMEDIATE and .PRECIOUS

### .INTERMEDIATE

Marks targets as intermediate files that should be automatically deleted
when no longer needed.

```makefile
.INTERMEDIATE: %.pp.c

# Preprocessed files are generated then consumed, then auto-deleted
%.pp.c: %.c
	$(CC) -E $< -o $@

%.o: %.pp.c
	$(CC) $(CFLAGS) -c $< -o $@
```

Make automatically treats files created by chains of implicit rules as
intermediate. `.INTERMEDIATE` lets you explicitly mark other files too.

### .SECONDARY

Prevents intermediate files from being auto-deleted (opposite of
`.INTERMEDIATE`):

```makefile
.SECONDARY: $(GENERATED_FILES)

# These generated files won't be auto-deleted
%.pb.go: %.proto
	protoc --go_out=. $<
```

### .PRECIOUS

Prevents file deletion on interrupt (Ctrl+C) or recipe failure:

```makefile
.PRECIOUS: %.o

# Object files are preserved even if compilation is interrupted
%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@
```

### Combining Them

```makefile
.DELETE_ON_ERROR:

# Downloaded files: keep even on failure (resume later)
.PRECIOUS: downloads/%.tar.gz
downloads/%.tar.gz:
	curl -L -o $@ $(URL)/$*.tar.gz

# Extracted files: auto-delete when no longer needed
.INTERMEDIATE: extracted/%
extracted/%: downloads/%.tar.gz
	tar xzf $< -C extracted/

# Final artifacts: normal handling
build/%: extracted/%
	./process.sh $< $@
```

### Summary Table

| Directive | On Success | On Failure/Interrupt | When No Longer Needed |
|-----------|-----------|---------------------|----------------------|
| (default) | Keep | Keep (delete with .DELETE_ON_ERROR) | Keep |
| `.INTERMEDIATE` | Auto-delete | Delete | Auto-delete |
| `.SECONDARY` | Keep | Keep | Keep |
| `.PRECIOUS` | Keep | **Keep** | Keep |

---

## Further Reading

- Peter Miller, "Recursive Make Considered Harmful" (1997) — the foundational paper
- GNU Make Manual: https://www.gnu.org/software/make/manual/
- Paul Smith's GNU Make site: https://make.mad-scientist.net/
- "Managing Projects with GNU Make" by Robert Mecklenburg (O'Reilly)
