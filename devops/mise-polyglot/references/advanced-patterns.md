# Mise Advanced Patterns Reference

<!-- TOC -->
- [Task Runner Deep Dive](#task-runner-deep-dive)
  - [File-Based Tasks](#file-based-tasks)
  - [Task Dependencies](#task-dependencies)
  - [Task Outputs](#task-outputs)
  - [Parallel Tasks](#parallel-tasks)
  - [Watch Mode](#watch-mode)
  - [Task Metadata Options](#task-metadata-options)
- [Environment Templates](#environment-templates)
  - [Tera Template Syntax](#tera-template-syntax)
  - [Built-in Template Variables](#built-in-template-variables)
  - [Conditional Environment Variables](#conditional-environment-variables)
  - [Sourcing Scripts](#sourcing-scripts)
- [Backend-Specific Configuration](#backend-specific-configuration)
  - [Aqua Backend](#aqua-backend)
  - [UBI / GitHub Backend](#ubi--github-backend)
  - [Cargo Backend](#cargo-backend)
  - [Pipx Backend](#pipx-backend)
  - [NPM Backend](#npm-backend)
  - [Go Backend](#go-backend)
- [Mise Settings Reference](#mise-settings-reference)
  - [Core Settings](#core-settings)
  - [Performance Settings](#performance-settings)
  - [Behavior Settings](#behavior-settings)
  - [Experimental Settings](#experimental-settings)
- [Hooks](#hooks)
  - [Hook Types](#hook-types)
  - [Hook Use Cases](#hook-use-cases)
  - [Hook Limitations](#hook-limitations)
- [Plugin Development](#plugin-development)
  - [Plugin Structure](#plugin-structure)
  - [Required Scripts](#required-scripts)
  - [Optional Scripts](#optional-scripts)
  - [Testing Plugins](#testing-plugins)
- [Custom Tool Registries](#custom-tool-registries)
- [Profiles and Environments](#profiles-and-environments)
  - [Environment Files](#environment-files)
  - [Profile Activation](#profile-activation)
  - [Environment Composition](#environment-composition)
<!-- /TOC -->

---

## Task Runner Deep Dive

### File-Based Tasks

File-based tasks live in `.mise/tasks/` (or `mise/tasks/`). Each file is an executable script whose filename becomes the task name. Use directory nesting for namespacing (e.g., `.mise/tasks/db/migrate` becomes `db:migrate`).

```bash
#!/usr/bin/env bash
# .mise/tasks/db/migrate
# mise description="Run database migrations"
# mise depends=["build"]
# mise alias="migrate"
# mise sources=["migrations/*"]
# mise outputs=["db/schema.sql"]
# mise dir="{{config_root}}"
# mise env={DATABASE_URL="postgresql://localhost/devdb"}
# mise hide=false
# mise raw=false

set -euo pipefail
echo "Running migrations..."
python manage.py migrate "$@"
```

Tasks can be written in any language:

```python
#!/usr/bin/env python3
# .mise/tasks/generate-docs
# mise description="Generate API documentation"
# mise depends=["build"]

import subprocess
import sys

subprocess.run(["pdoc", "--html", "src/"], check=True)
print("Docs generated successfully")
```

### Task Dependencies

Dependencies define execution order. Mise runs independent dependencies in parallel automatically.

```toml
# Linear dependency chain
[tasks.deploy]
depends = ["lint", "test", "build"]
run = "./deploy.sh"

# With arguments passed to dependencies
[tasks.release]
depends = [
  { task = "build", args = ["--release", "--target=prod"] },
  { task = "test", env = { CI = "true", TEST_ENV = "staging" } },
  "changelog"
]
run = "./scripts/release.sh"

# Wait-for vs depends: wait_for does not pass failure upstream
[tasks.notify]
wait_for = ["deploy"]    # runs after deploy, even if deploy fails
run = "curl -X POST https://hooks.slack.com/..."
```

Dependency resolution is topological — mise detects circular dependencies and errors.

### Task Outputs

Use `sources` and `outputs` for incremental builds. If all outputs are newer than all sources, the task is skipped.

```toml
[tasks.compile]
description = "Compile TypeScript"
sources = ["src/**/*.ts", "tsconfig.json"]
outputs = ["dist/**/*.js"]
run = "tsc"

[tasks.styles]
description = "Compile SCSS"
sources = ["styles/**/*.scss"]
outputs = ["public/css/**/*.css"]
run = "sass styles/:public/css/"

# Force re-run ignoring outputs
# mise run compile --force
```

### Parallel Tasks

Mise runs independent tasks (no dependency relationship) in parallel by default when invoked together.

```sh
# These run in parallel (independent tasks)
mise run lint test typecheck

# Control parallelism
mise run lint test typecheck --jobs=2   # max 2 parallel tasks

# Sequential execution forced
mise run lint test typecheck --jobs=1
```

Within a task's `depends`, independent deps also run in parallel:

```toml
[tasks.ci]
description = "Full CI"
depends = ["lint", "test:unit", "test:integration", "typecheck"]  # all 4 run in parallel
run = "echo 'All checks passed'"
```

### Watch Mode

Watch mode re-runs tasks when source files change:

```sh
# Watch a single task
mise watch -t build

# Watch multiple tasks
mise watch -t build -t test

# Custom glob pattern
mise watch -t test --glob="src/**/*.py" --glob="tests/**/*.py"

# Watch with arguments passed to the task
mise watch -t test -- --verbose
```

Define a watch task in config:

```toml
[tasks.dev]
description = "Watch and rebuild"
run = "mise watch -t build -t test"
```

### Task Metadata Options

Complete list of TOML task configuration keys:

| Key | Type | Description |
|-----|------|-------------|
| `run` | string or string[] | Command(s) to execute |
| `description` | string | Shown in `mise tasks` |
| `alias` | string or string[] | Short name(s) |
| `depends` | string[] or object[] | Tasks to run before |
| `wait_for` | string[] | Tasks to wait for (no failure propagation) |
| `env` | table | Per-task environment variables |
| `dir` | string | Working directory (supports templates) |
| `sources` | string[] | Input file globs (for incremental builds) |
| `outputs` | string[] | Output file globs |
| `shell` | string | Shell to use (default: `sh -c`) |
| `raw` | bool | Pass stdin/stdout/stderr directly |
| `hide` | bool | Hide from `mise tasks` list |
| `quiet` | bool | Suppress task header output |
| `silent` | bool | Suppress all output |
| `file` | string | External script file to run |

---

## Environment Templates

### Tera Template Syntax

Mise uses [Tera](https://keats.github.io/tera/) (Jinja2-like) templates in `[env]` values:

```toml
[env]
# Access existing environment variables
HOME_BIN = "{{ env.HOME }}/.local/bin"
USER_CONFIG = "{{ env.XDG_CONFIG_HOME | default(value=env.HOME + '/.config') }}"

# Mise-specific variables
PROJECT = "{{ config_root }}"                          # directory containing this .mise.toml
PROJECT_NAME = "{{ config_root | split(pat='/') | last }}"

# String manipulation
APP_NAME = "{{ env.PROJECT_NAME | upper }}"
SLUG = "{{ config_root | split(pat='/') | last | lower | replace(from=' ', to='-') }}"

# Conditional values
LOG_LEVEL = "{% if env.CI is defined %}warn{% else %}debug{% endif %}"
```

### Built-in Template Variables

| Variable | Description |
|----------|-------------|
| `env.VAR` | Access environment variable `VAR` |
| `config_root` | Directory containing the current `.mise.toml` |
| `cwd` | Current working directory (in hooks/tasks) |
| `mise_bin` | Path to the mise binary |
| `mise_pid` | PID of the current mise process |

### Conditional Environment Variables

```toml
[env]
# Default values for undefined vars
REDIS_URL = "{{ env.REDIS_URL | default(value='redis://localhost:6379') }}"

# Platform-specific
_.source = """
  if [ "$(uname)" = "Darwin" ]; then
    export DYLD_LIBRARY_PATH="$HOME/.local/lib"
  else
    export LD_LIBRARY_PATH="$HOME/.local/lib"
  fi
"""
```

### Sourcing Scripts

```toml
[env]
# Source a shell script and capture exports
_.source = "./scripts/env.sh"

# Source multiple files in order
_.file = [".env", ".env.local", ".env.{{ env.MISE_ENV | default(value='development') }}"]

# Inline script
_.source = """
  export CALCULATED_VAR=$(python -c "print('computed')")
"""
```

---

## Backend-Specific Configuration

### Aqua Backend

Aqua installs tools from the [aqua registry](https://github.com/aquaproj/aqua-registry) — primarily GitHub release binaries.

```toml
[tools]
# Format: aqua:owner/repo
"aqua:cli/cli" = "2.45"                     # GitHub CLI
"aqua:BurntSushi/ripgrep" = "14"             # ripgrep
"aqua:sharkdp/fd" = "10"                     # fd
"aqua:junegunn/fzf" = "latest"               # fzf
"aqua:derailed/k9s" = "0.32"                 # k9s

# Aqua is the preferred backend for GitHub release binaries.
# It uses a curated registry with checksums and architecture mappings.
```

### UBI / GitHub Backend

Direct GitHub release download. Use when a tool isn't in the aqua registry:

```toml
[tools]
# Format: github:owner/repo
"github:astral-sh/ruff" = "0.3"
"github:casey/just" = "1.25"

# With options
[tools."github:owner/private-tool"]
version = "1.0"
options = {
  bin = "custom-binary-name",        # binary name if different from repo
  tag_prefix = "v"                   # version tag prefix
}
```

### Cargo Backend

Install Rust crates from crates.io:

```toml
[tools]
"cargo:ripgrep" = "14"
"cargo:bat" = "0.24"
"cargo:tokei" = "latest"

# With features
[tools."cargo:my-tool"]
version = "1.0"
options = {
  features = "feature1,feature2",
  default_features = false
}
```

**Note**: Cargo backend requires a Rust toolchain installed (mise can manage Rust too).

### Pipx Backend

Install Python CLI tools in isolated environments via pipx:

```toml
[tools]
"pipx:black" = "24"
"pipx:ruff" = "0.3"
"pipx:poetry" = "1.8"
"pipx:ansible" = "9"
"pipx:cookiecutter" = "latest"

# With extras
[tools."pipx:jupyter"]
version = "latest"
options = { extras = "lab,notebook" }

# From git
[tools."pipx:git+https://github.com/owner/repo"]
version = "latest"
```

### NPM Backend

Install Node.js packages globally (scoped to mise):

```toml
[tools]
"npm:prettier" = "3"
"npm:eslint" = "9"
"npm:typescript" = "5.4"
"npm:@biomejs/biome" = "1.6"
```

### Go Backend

Install Go modules:

```toml
[tools]
"go:golang.org/x/tools/gopls" = "latest"
"go:github.com/golangci/golangci-lint/cmd/golangci-lint" = "1.57"
"go:gotest.tools/gotestsum" = "latest"
```

---

## Mise Settings Reference

### Core Settings

```toml
[settings]
# Legacy file support
legacy_version_file = true              # read .node-version, .python-version, etc. (default: true)
legacy_version_file_disable_tools = ["python"]  # disable for specific tools

# Installation behavior
always_keep_download = false            # keep tarballs after install (default: false)
always_keep_install = false             # keep install dir on failure for debugging
jobs = 4                                # parallel installation jobs (default: 4)
raw = false                             # show raw install output (default: false)
yes = false                             # auto-confirm prompts (default: false)

# Behavior
experimental = false                    # enable experimental features
verbose = false                         # verbose logging
log_level = "info"                      # trace, debug, info, warn, error
```

### Performance Settings

```toml
[settings]
# Caching
plugin_autoupdate_last_check_duration = "7d"   # plugin update check interval
cache_prune_age = "30d"                        # remove cache entries older than this

# Parallelism
jobs = 8                                       # parallel install/upgrade jobs

# Disable unused backends for speed
disable_backends = ["asdf"]                    # disable specific backends
```

### Behavior Settings

```toml
[settings]
# Tool resolution
resolve_strategy = "latest"             # "latest" or "os-specific"
not_found_auto_install = true           # auto-install tools on first use

# Security
trusted_config_paths = ["~/work"]       # auto-trust configs in these paths
paranoid = false                        # require checksum verification

# Shell integration
status = { missing_tools = "always", show_env = false, show_tools = true }
```

### Experimental Settings

```toml
[settings]
experimental = true                     # required for experimental features

# Lockfile (tracks exact resolved versions)
lockfile = true                         # generate mise.lock
```

---

## Hooks

### Hook Types

```toml
[hooks]
# enter: fires once when you first cd into the project directory tree
enter = "echo 'Welcome to {{config_root}}'"

# leave: fires when you cd out of the project directory tree
leave = "deactivate_custom_stuff"

# cd: fires on every directory change within the project tree
cd = "echo 'Now in {{cwd}}'"

# preinstall / postinstall: around mise install
preinstall = "echo 'About to install tools'"
postinstall = "echo 'Tools installed'"
```

### Hook Use Cases

```toml
[hooks]
# Auto-setup on project entry
enter = """
  if [ ! -d node_modules ]; then
    echo '📦 Installing dependencies...'
    npm install
  fi
"""

# Run as a mise task
[hooks]
enter = { task = "setup" }

# Notify on leave
leave = "echo '👋 Left project $(basename {{config_root}})'"

# Track directory changes
cd = "echo '📂 {{cwd}}' >> /tmp/mise-cd.log"
```

### Hook Limitations

- Hooks **require** `mise activate` in the shell — they do not fire with `mise exec` or `mise run`
- Hooks run in a subshell; exported variables do not persist (use `[env]` instead)
- Long-running hooks block the shell prompt
- Hooks fire for the user's shell only, not in CI or scripts using `mise exec`
- The `enter` hook fires once per directory tree entry, not on every `cd` within the project

---

## Plugin Development

Plugins extend mise to support tools not covered by built-in backends. Mise plugins follow the asdf plugin interface.

### Plugin Structure

```
mise-plugin-mytool/
├── bin/
│   ├── list-all              # REQUIRED: list available versions
│   ├── download              # REQUIRED: download a version
│   ├── install               # REQUIRED: install a version
│   ├── latest-stable         # optional: resolve "latest"
│   ├── list-bin-paths        # optional: custom bin paths
│   ├── exec-env              # optional: set env on activation
│   ├── parse-legacy-file     # optional: read legacy version files
│   └── help.overview         # optional: plugin help text
└── README.md
```

### Required Scripts

**bin/list-all** — print all installable versions, one per line, oldest first:
```bash
#!/usr/bin/env bash
curl -s https://api.example.com/versions | jq -r '.[].tag' | sort -V
```

**bin/download** — download source/binary to `$ASDF_DOWNLOAD_PATH`:
```bash
#!/usr/bin/env bash
set -euo pipefail
version="$ASDF_INSTALL_VERSION"
url="https://releases.example.com/v${version}/mytool-$(uname -s)-$(uname -m).tar.gz"
curl -fsSL "$url" -o "$ASDF_DOWNLOAD_PATH/mytool.tar.gz"
tar -xzf "$ASDF_DOWNLOAD_PATH/mytool.tar.gz" -C "$ASDF_DOWNLOAD_PATH"
```

**bin/install** — install from `$ASDF_DOWNLOAD_PATH` to `$ASDF_INSTALL_PATH`:
```bash
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$ASDF_INSTALL_PATH/bin"
cp "$ASDF_DOWNLOAD_PATH/mytool" "$ASDF_INSTALL_PATH/bin/"
chmod +x "$ASDF_INSTALL_PATH/bin/mytool"
```

### Optional Scripts

**bin/exec-env** — set environment variables when the tool is active:
```bash
#!/usr/bin/env bash
echo "export MYTOOL_HOME=$ASDF_INSTALL_PATH"
echo "export MYTOOL_DATA=$ASDF_INSTALL_PATH/data"
```

**bin/parse-legacy-file** — read legacy version files:
```bash
#!/usr/bin/env bash
cat "$1"  # read .mytool-version file
```

### Testing Plugins

```sh
# Install from local path
mise plugin install mytool ./mise-plugin-mytool

# Install from git
mise plugin install mytool https://github.com/user/mise-plugin-mytool.git

# Test the plugin
mise install mytool@1.0.0
mise use mytool@1.0.0
mytool --version

# Update plugin
mise plugin update mytool
```

---

## Custom Tool Registries

Mise supports the aqua registry and custom plugin registries:

```toml
# ~/.config/mise/config.toml

[settings]
# Add a custom registry (in addition to the default)
# Registry format: name = "url"
# Registries are git repos with a plugins/ directory

# Use a custom shortname
[plugins]
mytool = "https://github.com/myorg/mise-plugin-mytool"

# Override default plugin source
terraform = "https://github.com/myorg/mise-plugin-terraform-custom"
```

Install from custom registry:

```sh
# Register a plugin
mise plugin install mytool https://github.com/myorg/mise-plugin-mytool

# Then use normally
mise use mytool@1.0
```

---

## Profiles and Environments

### Environment Files

Mise supports environment-specific configuration through file naming conventions:

```
project/
├── .mise.toml                  # base config (always loaded)
├── .mise.local.toml            # local overrides (gitignored)
├── mise.development.toml       # development profile
├── mise.staging.toml           # staging profile
├── mise.production.toml        # production profile
└── mise.test.toml              # test profile
```

### Profile Activation

```sh
# Activate a specific environment profile
MISE_ENV=production mise run deploy

# Or set in shell
export MISE_ENV=staging
mise install
mise run test

# In CI
MISE_ENV=ci mise run test
```

### Environment Composition

When `MISE_ENV=production`:
1. `.mise.toml` loads first (base)
2. `mise.production.toml` merges on top (overrides)
3. `.mise.local.toml` merges last (local overrides, if exists)

```toml
# .mise.toml (base)
[env]
LOG_LEVEL = "debug"
DATABASE_URL = "postgresql://localhost/devdb"

[tools]
node = "20"
python = "3.12"

# mise.production.toml (production overrides)
[env]
LOG_LEVEL = "warn"
DATABASE_URL = "postgresql://prod-host/proddb"
NODE_ENV = "production"

# mise.test.toml (test overrides)
[env]
LOG_LEVEL = "error"
DATABASE_URL = "postgresql://localhost/testdb"
NODE_ENV = "test"
```

Use profiles to:
- Swap database URLs between dev/staging/prod
- Adjust log levels per environment
- Set CI-specific flags (e.g., `CI=true`)
- Use different tool versions for testing compatibility
