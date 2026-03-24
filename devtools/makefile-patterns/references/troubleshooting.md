# GNU Make Troubleshooting Guide

Comprehensive guide to debugging, diagnosing, and fixing GNU Make issues.

## Table of Contents

- [Common Errors](#common-errors)
  - [Missing Separator](#missing-separator)
  - [No Rule to Make Target](#no-rule-to-make-target)
  - [Circular Dependency](#circular-dependency)
  - [Unterminated Variable Reference](#unterminated-variable-reference)
  - [Command Not Found / 127](#command-not-found--127)
  - [Recipe Commences Before First Target](#recipe-commences-before-first-target)
  - [Overriding Recipe / Ignoring Old Recipe](#overriding-recipe--ignoring-old-recipe)
- [Debugging Techniques](#debugging-techniques)
  - [Dry Run (-n)](#dry-run--n)
  - [Debug Flags (--debug)](#debug-flags---debug)
  - [Print Database (-p)](#print-database--p)
  - [Trace Mode (--trace)](#trace-mode---trace)
  - [Diagnostic Functions](#diagnostic-functions)
  - [Variable Inspection Target](#variable-inspection-target)
  - [Remake Debugger](#remake-debugger)
- [Recipe Execution Environment](#recipe-execution-environment)
  - [Each Line is a Separate Shell](#each-line-is-a-separate-shell)
  - [Shell Selection](#shell-selection)
  - [Error Handling in Recipes](#error-handling-in-recipes)
  - [Silent and Verbose Recipes](#silent-and-verbose-recipes)
- [Shell Compatibility Issues](#shell-compatibility-issues)
  - [POSIX sh vs Bash](#posix-sh-vs-bash)
  - [Dollar Sign Escaping](#dollar-sign-escaping)
  - [Quoting Rules](#quoting-rules)
- [Tab vs Spaces](#tab-vs-spaces)
- [Windows Compatibility](#windows-compatibility)
  - [Path Separators](#path-separators)
  - [Shell Differences](#shell-differences)
  - [Line Endings](#line-endings)
  - [Tool Availability](#tool-availability)
  - [Cross-Platform Makefile Pattern](#cross-platform-makefile-pattern)

---

## Common Errors

### Missing Separator

```
Makefile:10: *** missing separator.  Stop.
```

**Cause**: Recipe lines are indented with spaces instead of a tab character.

**Fix**: Replace leading spaces with a literal tab.

```makefile
# WRONG — spaces
target:
    echo "hello"    # 4 spaces — causes error

# RIGHT — tab
target:
	echo "hello"    # literal tab character
```

**Checking for tabs**:
```bash
# Show tabs as ^I
cat -A Makefile | head -20

# Find lines with leading spaces that should be tabs
grep -nP '^ +[^\t#]' Makefile
```

**Editor configuration**:
```
# .editorconfig
[Makefile]
indent_style = tab
indent_size = 4

[*.mk]
indent_style = tab
indent_size = 4
```

**Another cause**: Misplaced text that Make interprets as a rule:

```makefile
# WRONG — stray text looks like a rule body
SRC = main.c
  util.c        # This indented line triggers "missing separator"

# RIGHT — use backslash continuation
SRC = main.c \
      util.c
```

### No Rule to Make Target

```
make: *** No rule to make target 'foo.o', needed by 'app'.  Stop.
```

**Common causes and fixes**:

1. **Misspelled filename or target**:
   ```makefile
   # WRONG
   app: main.o utlis.o   # typo: "utlis" instead of "utils"

   # RIGHT
   app: main.o utils.o
   ```

2. **Missing source file**:
   ```bash
   # Check if file exists
   ls -la src/foo.c
   ```

3. **Wrong path / VPATH issue**:
   ```makefile
   # Source is in src/ but rule expects it in current directory
   vpath %.c src
   # OR use explicit paths
   OBJS := $(addprefix build/,main.o utils.o)
   ```

4. **Deleted header file** (from stale `.d` dependency files):
   ```bash
   # Fix: delete all dependency files and rebuild
   find . -name '*.d' -delete
   make clean && make
   ```
   Prevention: always use `-MP` flag in dependency generation.

5. **Generated file not yet created**:
   ```makefile
   # Ensure generation rule exists and runs first
   generated.h: config.yaml
   	./generate.sh $< > $@

   app.o: app.c generated.h
   ```

### Circular Dependency

```
make: Circular main.o <- main.o dependency dropped.
```

**Cause**: A target directly or indirectly depends on itself.

**Diagnosis**:
```bash
# Print the dependency graph
make -p --no-builtin-rules | grep -A2 '^main.o'

# Or use debug output
make --debug=v 2>&1 | grep -i circular
```

**Common scenarios**:

1. **Implicit rule chain creates a loop**:
   ```makefile
   # If you have both:
   %.o: %.c
   %.c: %.o   # This creates a circular chain!
   ```

2. **Include file that depends on what it builds**:
   ```makefile
   # Fix: use order-only prerequisite or restructure
   config.mk: generate-config   # If config.mk includes rules that
   include config.mk             # need generate-config...circular!
   ```

3. **Fix**: Draw out the dependency graph. Remove back-edges.

### Unterminated Variable Reference

```
Makefile:5: *** unterminated variable reference.  Stop.
```

**Cause**: Missing closing parenthesis or brace in a variable reference.

```makefile
# WRONG
OBJS := $(patsubst %.c,%.o,$(SRCS)    # Missing closing )

# RIGHT
OBJS := $(patsubst %.c,%.o,$(SRCS))
```

**Tip**: Use an editor with bracket matching. Count opening and closing
parens in complex expressions.

### Command Not Found / 127

```
/bin/sh: mycommand: not found
make: *** [Makefile:10: target] Error 127
```

**Cause**: The command doesn't exist in `$PATH` during recipe execution.

**Fixes**:
```makefile
# 1. Use full path
/usr/local/bin/mycommand arg1 arg2

# 2. Guard with a check
lint:
	@command -v golangci-lint >/dev/null 2>&1 || \
		(echo "Error: golangci-lint not installed" && exit 1)
	golangci-lint run

# 3. Set PATH in the Makefile
export PATH := $(HOME)/go/bin:$(PATH)
```

### Recipe Commences Before First Target

```
Makefile:3: *** recipe commences before first target.  Stop.
```

**Cause**: A recipe line (tab-indented) appears before any target definition.

```makefile
# WRONG — tab-indented line with no target above
	echo "this causes the error"

all:
	echo "hello"

# RIGHT — ensure all recipe lines follow a target
all:
	echo "hello"
```

### Overriding Recipe / Ignoring Old Recipe

```
Makefile:20: warning: overriding recipe for target 'clean'
Makefile:10: warning: ignoring old recipe for target 'clean'
```

**Cause**: Two rules define recipes for the same target.

```makefile
# WRONG — duplicate recipes
clean:
	rm -rf build/

# ... later in file or included file ...
clean:
	rm -rf dist/

# RIGHT — combine into one rule
clean:
	rm -rf build/ dist/

# Or use double-colon rules if both should run independently
clean::
	rm -rf build/
clean::
	rm -rf dist/
```

---

## Debugging Techniques

### Dry Run (-n)

Show what commands would execute without running them:

```bash
make -n                    # Dry run for default target
make -n deploy             # Dry run for specific target
make -n --warn-undefined-variables  # Also warn about undefined vars
```

**Caveat**: `-n` doesn't execute recipes, so if a recipe generates files
that later rules depend on, the dry run may show errors. Use with
`--always-make` for completeness:

```bash
make -n -B   # Dry run, treating all targets as out of date
```

### Debug Flags (--debug)

```bash
make --debug=b    # Basic: show rules considered and why they're rebuilt
make --debug=v    # Verbose: basic + detailed file analysis
make --debug=i    # Implicit: show implicit rule search
make --debug=j    # Jobs: show details of parallel invocations
make --debug=m    # Makefile: show remake of included makefiles
make --debug=a    # All: enable all of the above (very verbose!)
```

**Recommended workflow**:
```bash
# Start with basic to understand what's rebuilding and why
make --debug=b target 2>&1 | head -50

# If implicit rules are involved, add that
make --debug=bi target 2>&1 | grep -A3 'Considering'

# Redirect to file for large outputs
make --debug=v target 2>&1 | tee make-debug.log
```

**Sample basic debug output**:
```
Considering target file 'app'.
  File 'app' does not exist.
  Considering target file 'main.o'.
    File 'main.o' does not exist.
    Considering target file 'main.c'.
      File 'main.c' exists.
    Finished prerequisites of target file 'main.c'.
    No recipe for 'main.c' and no prerequisites actually changed.
  Must remake target 'main.o'.
```

### Print Database (-p)

Dump Make's entire internal database: all rules, variables, and their
values:

```bash
# Print everything (very long!)
make -p --no-builtin-rules > make-db.txt

# Find a specific variable
make -p --no-builtin-rules 2>/dev/null | grep -A1 '^CFLAGS'

# Find rules for a target
make -p --no-builtin-rules 2>/dev/null | grep -B2 -A5 '^app:'

# Show only variables (not rules)
make -p --no-builtin-rules 2>/dev/null | \
    awk '/^# Variables/,/^# /'
```

### Trace Mode (--trace)

Available in GNU Make 4.1+. Prints each recipe with file/line info
before execution:

```bash
make --trace
```

Output looks like:
```
Makefile:15: update target 'main.o' due to: main.c
gcc -Wall -O2 -c main.c -o main.o
```

### Diagnostic Functions

Use Make's built-in diagnostic functions to inspect values during parsing:

```makefile
SRCS := $(wildcard src/*.c)
$(info SRCS = $(SRCS))                 # Print at parse time, continue
$(warning OBJS not set yet!)           # Print with file:line, continue
$(error Fatal: COMPILER not defined)   # Print and abort immediately

# Conditional diagnostics
ifndef CC
$(error CC must be defined. Set CC=gcc or CC=clang)
endif

ifeq ($(SRCS),)
$(warning No source files found in src/ — is the path correct?)
endif
```

**Output format**:
```
Makefile:3: SRCS = src/main.c src/util.c     # $(info)
Makefile:4: OBJS not set yet!                 # $(warning)
Makefile:5: *** Fatal: COMPILER not defined.  Stop.  # $(error)
```

### Variable Inspection Target

Add a reusable debug target:

```makefile
.PHONY: print-%
print-%:
	@echo '──────────────────────────────────'
	@echo '  $* = $($*)'
	@echo '  origin: $(origin $*)'
	@echo '  flavor: $(flavor $*)'
	@echo '──────────────────────────────────'
```

Usage:
```bash
make print-CFLAGS
# ──────────────────────────────────
#   CFLAGS = -Wall -O2
#   origin: file
#   flavor: simple
# ──────────────────────────────────

make print-CC
# Shows CC value and where it was defined (default, environment, file, etc.)
```

### Remake Debugger

`remake` is a patched GNU Make with a built-in debugger:

```bash
# Install
sudo apt install remake    # Debian/Ubuntu
brew install remake        # macOS

# Run with debugger
remake -X                  # Break at first target
remake -X target           # Break at specific target

# Debugger commands
# step     — step into next rule
# next     — step over
# continue — run until next breakpoint
# print    — inspect variable
# where    — show target stack
# quit     — exit
```

---

## Recipe Execution Environment

### Each Line is a Separate Shell

By default, every line of a recipe runs in a **separate shell**:

```makefile
# WRONG — cd has no effect on second line
deploy:
	cd /opt/app          # Runs in shell 1
	./start.sh           # Runs in shell 2 — still in original directory!

# FIX 1 — single line with &&
deploy:
	cd /opt/app && ./start.sh

# FIX 2 — line continuation
deploy:
	cd /opt/app && \
		./start.sh

# FIX 3 — .ONESHELL
.ONESHELL:
deploy:
	cd /opt/app
	./start.sh
```

### Shell Selection

```makefile
# Default is /bin/sh (POSIX shell)
SHELL := /bin/sh

# Use bash for bash-specific features
SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

# Per-target shell (GNU Make 3.82+)
python-task: SHELL := /usr/bin/python3
python-task: .SHELLFLAGS := -c
python-task:
	import os; print(os.getcwd())
```

### Error Handling in Recipes

```makefile
# Default: recipe stops on first error (non-zero exit)
strict-target:
	command1        # If this fails, Make stops
	command2        # Never reached

# Prefix with - to ignore errors
lenient-target:
	-rm -f might-not-exist.txt    # Ignore failure
	command2                      # Always runs

# Prefix with + to run even with -n (dry run)
generate:
	+$(MAKE) -C subdir            # Recursive make always runs

# Use && for explicit chaining
safe-target:
	command1 && command2 && command3
```

### Silent and Verbose Recipes

```makefile
# @ prefix suppresses command echo
quiet-target:
	@echo "Only this output is shown"

# Controllable verbosity
V ?= 0
ifeq ($(V),0)
  Q := @
  ECHO := @echo
else
  Q :=
  ECHO := @true
endif

build:
	$(ECHO) "  CC    $<"
	$(Q)$(CC) $(CFLAGS) -c $< -o $@
```

Usage: `make` (quiet) vs `make V=1` (verbose).

---

## Shell Compatibility Issues

### POSIX sh vs Bash

Make uses `/bin/sh` by default. Many systems link `/bin/sh` to `dash`
(Debian/Ubuntu) or other minimal POSIX shells, not `bash`.

**Features that FAIL under `/bin/sh`**:

```makefile
# FAIL: bash-only array syntax
target:
	arr=(one two three); echo $${arr[0]}

# FAIL: bash process substitution
target:
	diff <(sort file1) <(sort file2)

# FAIL: bash [[ ]] test syntax
target:
	[[ -f file.txt ]] && echo "exists"

# FAIL: bash {1..10} brace expansion
target:
	echo {1..10}

# FAIL: $RANDOM, $BASHPID
```

**Solutions**:
```makefile
# Option 1: Set SHELL to bash
SHELL := /bin/bash

# Option 2: Use POSIX-compatible alternatives
target:
	if [ -f file.txt ]; then echo "exists"; fi

# Option 3: Use Make functions instead of shell
FILES := $(wildcard *.txt)
target:
	@echo "Found: $(FILES)"
```

### Dollar Sign Escaping

Make interprets `$` for variable expansion. To pass `$` to the shell,
double it:

```makefile
# WRONG — Make tries to expand $HOME and $i
target:
	echo $HOME
	for i in 1 2 3; do echo $i; done

# RIGHT — escape with $$
target:
	echo $$HOME
	for i in 1 2 3; do echo $$i; done

# In awk, quadruple the dollar sign:
target:
	awk '{print $$1, $$2}' data.txt

# Inside $(call)/$(eval), you may need $$$$:
define template
target-$(1):
	echo "PID: $$$$$$$$"    # $$$$ -> $$ (after call) -> $ (in shell)
endef
```

### Quoting Rules

```makefile
# Single quotes pass through to shell — Make doesn't interpret them
target:
	echo 'Make variable: $(CC)'     # Make DOES expand $(CC) first!

# To prevent Make expansion, escape or use $$
target:
	echo '$$PATH = '"$$PATH"        # Shows actual $PATH

# Handle filenames with spaces
FILES := "file with spaces.txt"
target:
	cat $(FILES)                     # Works if quoted properly
```

---

## Tab vs Spaces

### The Rule

**Recipe lines MUST start with a TAB character.** This is non-negotiable
in GNU Make (unless you change `.RECIPEPREFIX`).

### Changing the Recipe Prefix (GNU Make 3.82+)

```makefile
.RECIPEPREFIX = >

# Now use > instead of tab
target: prerequisite
> echo "This uses > as the recipe prefix"
> gcc -o $@ $<
```

### Detecting Tab Issues

```bash
# Show whitespace characters
cat -A Makefile | grep '^\s'
# ^I = tab, spaces show as spaces

# Find recipe lines using spaces instead of tabs
awk '/^[^ \t].*:/ { target=1; next }
     target && /^    / { print NR": "$0 }
     /^$/ { target=0 }' Makefile

# Vim: show tabs vs spaces
:set list listchars=tab:▸\ ,trail:·

# VS Code: "Render Whitespace" setting
# Or use the Makefile extension which highlights issues
```

### Fixing Tab Issues

```bash
# Convert leading spaces to tabs (careful — only for recipe lines!)
# Use unexpand with caution
unexpand --first-only Makefile > Makefile.fixed

# Vim: convert spaces to tabs on specific lines
:set noexpandtab
:%retab!

# sed: convert 4-space indents to tabs (rough — verify results!)
sed -i 's/^    /\t/' Makefile
```

---

## Windows Compatibility

### Path Separators

```makefile
# Detect OS and set path separator
ifeq ($(OS),Windows_NT)
    SEP := \\
    PATHSEP := ;
else
    SEP := /
    PATHSEP := :
endif

# Use forward slashes universally — Make and most tools accept them
BUILDDIR := build/output    # Works on Windows too (in most cases)
```

### Shell Differences

Windows Make may use `cmd.exe` instead of `/bin/sh`:

```makefile
ifeq ($(OS),Windows_NT)
    SHELL := cmd.exe
    .SHELLFLAGS := /c

    # Windows commands
    RM := del /Q /F
    RMDIR := rmdir /S /Q
    MKDIR := mkdir
    COPY := copy
    NULL := NUL
    SEP := \\
else
    RM := rm -f
    RMDIR := rm -rf
    MKDIR := mkdir -p
    COPY := cp
    NULL := /dev/null
    SEP := /
endif

clean:
	$(RM) build$(SEP)*.o 2>$(NULL)
	$(RMDIR) build 2>$(NULL)
```

### Line Endings

Windows text editors may save files with `\r\n` (CRLF) line endings.
Make may misparse these, causing cryptic errors.

**Fix**:
```bash
# Convert to Unix line endings
dos2unix Makefile

# Git: prevent the issue
echo "Makefile text eol=lf" >> .gitattributes
echo "*.mk text eol=lf" >> .gitattributes
```

**.gitattributes**:
```
Makefile    text eol=lf
*.mk        text eol=lf
```

### Tool Availability

Standard Unix tools (`rm`, `cp`, `find`, `grep`, `sed`, `awk`) don't
exist natively on Windows.

**Solutions**:
1. **Git Bash / MSYS2**: Install and set `SHELL := C:/Program Files/Git/bin/bash.exe`
2. **WSL**: Run Make inside Windows Subsystem for Linux.
3. **GnuWin32**: Standalone ports of Unix tools.
4. **Portable alternatives**: Use Make functions instead of shell commands.

```makefile
# Portable: use Make's built-in functions instead of shell tools
SRCS := $(wildcard src/*.c)           # Instead of: $(shell find src -name '*.c')
CLEAN_FILES := $(wildcard build/*.o)

clean:
ifeq ($(OS),Windows_NT)
	$(foreach f,$(CLEAN_FILES),del /Q $(subst /,\,$(f)) 2>NUL &)
else
	rm -f $(CLEAN_FILES)
endif
```

### Cross-Platform Makefile Pattern

```makefile
# Detect platform
UNAME_S := $(shell uname -s 2>/dev/null || echo Windows)

ifeq ($(UNAME_S),Linux)
    PLATFORM := linux
    OPEN := xdg-open
    NPROC := $(shell nproc)
endif
ifeq ($(UNAME_S),Darwin)
    PLATFORM := macos
    OPEN := open
    NPROC := $(shell sysctl -n hw.ncpu)
endif
ifeq ($(OS),Windows_NT)
    PLATFORM := windows
    OPEN := start
    NPROC := $(NUMBER_OF_PROCESSORS)
    SHELL := cmd.exe
endif

# Portable file operations
define rm_file
	$(if $(filter windows,$(PLATFORM)),\
		del /Q $(subst /,\,$(1)) 2>NUL,\
		rm -f $(1))
endef

define rm_dir
	$(if $(filter windows,$(PLATFORM)),\
		if exist $(subst /,\,$(1)) rmdir /S /Q $(subst /,\,$(1)),\
		rm -rf $(1))
endef

clean:
	$(call rm_dir,build)
	$(call rm_file,app$(if $(filter windows,$(PLATFORM)),.exe))
```

---

## Quick Reference: Debugging Cheat Sheet

| What You Want | Command |
|--------------|---------|
| See what would run | `make -n target` |
| See why something rebuilds | `make --debug=b target` |
| See all defined variables | `make -p \| grep '^[A-Z]'` |
| See rules for a target | `make -p \| grep -A5 '^target:'` |
| Find implicit rule used | `make --debug=i target` |
| Trace execution with context | `make --trace target` |
| Pretend a file changed | `make -W file.c target` |
| Inspect a single variable | `make print-VARNAME` (with print-% rule) |
| Verbose everything | `make --debug=a target 2>&1 \| less` |
| Check Make version | `make --version` |
| Show value at parse time | Add `$(info VAR = $(VAR))` to Makefile |

---

## Troubleshooting Decision Tree

```
Error?
├── "missing separator"
│   └── Check: tabs vs spaces in recipe lines
├── "No rule to make target 'X'"
│   ├── Does X exist? → Check filename/path
│   ├── Is X generated? → Ensure generation rule exists
│   └── Is X a deleted header? → Delete .d files, rebuild
├── "Circular dependency dropped"
│   └── Print deps: make -p | grep target, remove back-edges
├── Nothing happens / wrong thing rebuilds
│   ├── Is target .PHONY? → Check .PHONY declaration
│   ├── Is target up to date? → make --debug=b
│   └── Wrong rule matched? → make --debug=i
├── Recipe runs but fails
│   ├── Exit code 127 → Command not found, check PATH
│   ├── Exit code 2 → Command error, run manually
│   └── Partial output → Add .DELETE_ON_ERROR
└── Parallel build fails but serial works
    ├── Missing dependency → Add prerequisite
    ├── Race condition → Check for shared temp files
    └── Output interleaved → Use -Otarget
```

---

## Further Reading

- GNU Make Manual — Errors: https://www.gnu.org/software/make/manual/html_node/Error-Messages.html
- GNU Make Manual — Debugging: https://www.gnu.org/software/make/manual/html_node/Running.html
- remake (Make debugger): https://remake.readthedocs.io/
- Paul Smith's Make tips: https://make.mad-scientist.net/
