---
name: mise-polyglot
description: >
  Use when: user mentions mise, rtx, .mise.toml, mise.toml, mise install, mise use, mise tasks,
  mise activate, mise hooks, polyglot tool version management, replacing asdf/nvm/pyenv/rbenv/direnv,
  managing multiple language runtimes in one project, project-level tool pinning, or CI/CD with
  jdx/mise-action. Also use when configuring .tool-versions with mise, mise backends, mise env vars,
  or mise task runner.
  Do NOT use when: user asks about Docker/container orchestration, Kubernetes, Terraform/OpenTofu
  provisioning, Ansible/Chef/Puppet config management, generic shell scripting unrelated to mise,
  npm/pip/cargo as standalone package managers (not as mise backends), or asdf without any mention
  of mise or migration intent.
---

# Mise (mise-en-place) — Polyglot Dev Tool Manager

## Overview

Mise is a single binary (Rust) that replaces asdf, nvm, pyenv, rbenv, direnv, and Makefiles.
It manages tool versions, environment variables, and tasks per-project via `.mise.toml`.
Formerly named "rtx". Runs on macOS, Linux, and WSL. Written by @jdx.

Key capabilities:
- Install and switch between versions of Node, Python, Ruby, Go, Rust, Terraform, Java, and 500+ tools
- Set per-project environment variables (replaces direnv)
- Define and run tasks (replaces Make, npm scripts, Just)
- Read legacy files: `.node-version`, `.python-version`, `.ruby-version`, `.tool-versions`, `.nvmrc`
- Hooks for enter/leave/cd events
- CI/CD integration via `jdx/mise-action`

## Installation

Install mise:
```sh
curl https://mise.run | sh
```

Alternative methods:
```sh
brew install mise          # macOS Homebrew
apt install mise           # Debian/Ubuntu (after adding repo)
yay -S mise                # Arch AUR
cargo install mise         # From source
```

### Shell Activation (REQUIRED)

Mise does NOT work without shell activation. Add ONE of these:

**Bash** — append to `~/.bashrc`:
```sh
eval "$(mise activate bash)"
```

**Zsh** — append to `~/.zshrc`:
```sh
eval "$(mise activate zsh)"
```

**Fish** — append to `~/.config/fish/config.fish`:
```fish
mise activate fish | source
```

Restart shell or `source` the config file. Verify:
```sh
mise --version
mise doctor        # diagnose configuration issues
```

## Tool Management

### Install and Use Tools

```sh
mise use node@20           # install node 20.x, pin in .mise.toml (local)
mise use -g python@3.12    # install python 3.12, set as global default
mise install               # install all tools defined in .mise.toml
mise install node@22       # install without activating
mise ls                    # list installed tools and active versions
mise ls-remote node        # list all available node versions
mise outdated              # show tools with newer versions available
mise upgrade               # upgrade all tools to latest within constraints
mise uninstall node@18     # remove a specific version
mise prune                 # remove unused tool versions
```

### Version Resolution Order

1. `.mise.toml` in current directory (highest priority)
2. `.mise.toml` in parent directories (walking up)
3. `~/.config/mise/config.toml` (global)
4. Legacy files (`.node-version`, `.python-version`, `.tool-versions`)

### Example: Pin Versions

```sh
mise use node@20.11.0 python@3.12 terraform@1.7
# Creates/updates .mise.toml:
# [tools]
# node = "20.11.0"
# python = "3.12"
# terraform = "1.7"
```

## .mise.toml Configuration

Central config file. Place in project root. Commit to version control.

### Full Example

```toml
min_version = "2025.1.0"

[tools]
node = "20"                        # latest 20.x
python = "3.12.2"                  # exact version
go = "latest"                      # latest stable
ruby = ["3.3.0", "3.2.2"]         # multiple versions (first is default)
terraform = "1.7"                  # latest 1.7.x
erlang = "26"
elixir = "1.16"

[tools.java]
version = "21"
options = { provider = "temurin" }  # tool-specific options

[env]
NODE_ENV = "development"
DATABASE_URL = "postgresql://localhost/devdb"
_.file = ".env"                     # source .env file
_.path = ["./node_modules/.bin", "./bin"]  # prepend to PATH

[tasks]
build = "npm run build"
test = "npm test"
lint = "eslint src/"

[tasks.dev]
description = "Start dev server"
run = "npm run dev"
depends = ["build"]

[tasks.ci]
description = "Full CI pipeline"
depends = ["lint", "test", "build"]
run = "echo 'CI passed'"

[settings]
legacy_version_file = true          # read .node-version, .python-version, etc.
always_keep_download = false
```

### Config File Hierarchy (merged, later overrides)

1. `~/.config/mise/config.toml` — global
2. `.mise.toml` — project (committed)
3. `.mise.local.toml` — local overrides (gitignored)
4. `.mise/config.toml` — alternative project location
5. `mise.<ENV>.toml` — environment-specific

## Environment Variables

### In .mise.toml

```toml
[env]
NODE_ENV = "development"
API_URL = "http://localhost:3000"
SECRET_KEY = "dev-only-key"

# Template syntax (tera templates)
PROJECT_ROOT = "{{ config_root }}"
PATH_ADDITION = "{{ env.HOME }}/.local/bin"

# Source external files
_.file = [".env", ".env.local"]

# Prepend to PATH
_.path = ["./node_modules/.bin", "./scripts"]
```

### Precedence

- `.mise.toml` `[env]` overrides shell env; `.mise.local.toml` overrides `.mise.toml`
- `_.file` values loaded in order; later files override earlier
- Use `_.source` to run a script and capture exported variables

### Example: Per-Environment Config

```toml
# mise.production.toml
[env]
NODE_ENV = "production"
DATABASE_URL = "postgresql://prod-host/proddb"
LOG_LEVEL = "warn"
```
Activate with: `MISE_ENV=production mise run deploy`

## Task Runner

### TOML-Based Tasks

Define in `.mise.toml`:

```toml
[tasks.build]
description = "Build the application"
run = "cargo build --release"
alias = "b"                        # mise b

[tasks.test]
description = "Run tests"
run = ["cargo test", "./scripts/integration.sh"]  # sequential commands
env = { RUST_LOG = "debug" }       # per-task env vars
dir = "{{config_root}}"            # working directory

[tasks.deploy]
description = "Deploy to production"
depends = ["build", "test"]        # run deps first (parallel when possible)
run = "./deploy.sh"

[tasks.watch]
description = "Watch and rebuild"
run = "cargo watch -x build"

[tasks.format]
description = "Format all code"
run = '''
cargo fmt
prettier --write "src/**/*.{ts,tsx}"
'''
```

Run tasks:
```sh
mise run build          # or just: mise build
mise run test -- -v     # pass args after --
mise run                # interactive task selector (no args)
mise tasks              # list all available tasks
```

### File-Based Tasks

Create executable scripts in `.mise/tasks/`:

```bash
#!/usr/bin/env bash
# mise description="Database migration"
# mise depends=["build"]
# mise alias="db:migrate"

set -euo pipefail
echo "Running migrations..."
./scripts/migrate.sh "$@"
```

File name becomes task name. Metadata via `# mise` comments.

### Task Dependencies with Args

```toml
[tasks.deploy]
depends = [
  { task = "build", args = ["--release"] },
  { task = "test", env = { CI = "true" } }
]
run = "./deploy.sh"
```

## Backends

Mise uses backends to install tools. Priority order:

| Backend | Use Case | Syntax |
|---------|----------|--------|
| **core** | Built-in (Node, Python, Go, Ruby, Java, Erlang, etc.) | `node`, `python` |
| **aqua** | GitHub releases via aqua registry (preferred for new tools) | `aqua:cli/cli` |
| **github** | Direct GitHub release binaries (replaced ubi) | `github:owner/repo` |
| **cargo** | Rust crates | `cargo:ripgrep` |
| **npm** | Node packages | `npm:prettier` |
| **pipx** | Python CLI tools (isolated envs) | `pipx:black` |
| **go** | Go modules | `go:golang.org/x/tools/gopls` |
| **asdf** | asdf plugins (legacy fallback) | `asdf:plugin-name` |

### Example: Mixed Backends

```toml
[tools]
node = "20"                              # core backend (automatic)
"npm:prettier" = "3"                     # npm backend
"cargo:ripgrep" = "14"                   # cargo backend
"aqua:cli/cli" = "2.45"                 # aqua backend for GitHub CLI
"pipx:black" = "24"                      # pipx backend
"go:golang.org/x/tools/gopls" = "latest" # go backend
```

### Disable a Backend

```sh
mise settings set disable_backends asdf   # disable asdf backend globally
```

## Legacy File Support

Mise reads existing version files automatically (when `legacy_version_file = true`, which is default):

| File | Tool |
|------|------|
| `.node-version`, `.nvmrc` | Node.js |
| `.python-version` | Python |
| `.ruby-version` | Ruby |
| `.go-version` | Go |
| `.java-version` | Java |
| `.tool-versions` | Any (asdf format) |

No migration required — mise reads these alongside `.mise.toml`. When both exist, `.mise.toml` takes precedence.

## Hooks

Hooks run shell commands on directory events. Require `mise activate`.

```toml
[hooks]
enter = "echo 'Entered project'"         # once on first cd into project
leave = "echo 'Left project'"            # when leaving project tree
cd = "echo 'Changed to {{cwd}}'"         # every cd within project
enter = { task = "setup" }               # run a mise task as hook
```
## Settings

Configure via `mise settings set KEY VALUE` or in `[settings]`:

```toml
[settings]
legacy_version_file = true        # read .node-version, .python-version, etc.
always_keep_download = false      # delete tarballs after install
plugin_autoupdate_last_check_duration = "7d"
jobs = 4                          # parallel install jobs
raw = false                       # show raw install output
yes = false                       # auto-confirm prompts
```

```sh
mise settings ls                  # list all settings and values
mise settings set jobs 8          # set parallel jobs
```

## Comparison with Other Tools

| Feature | mise | asdf | nvm | pyenv | direnv |
|---------|------|------|-----|-------|--------|
| Multi-language | ✅ | ✅ | ❌ | ❌ | ❌ |
| Env vars | ✅ | ❌ | ❌ | ❌ | ✅ |
| Task runner | ✅ | ❌ | ❌ | ❌ | ❌ |
| Performance | Fast (Rust) | Slow (Bash) | Medium | Medium | Fast |
| Legacy compat | ✅ | N/A | N/A | N/A | N/A |
| Single binary | ✅ | ❌ | ❌ | ❌ | ✅ |

Mise is a drop-in replacement for asdf with better performance and more features. It reads `.tool-versions` natively — just install mise and activate.

## Team Usage Patterns

### Onboarding

1. Commit `.mise.toml` to the repo
2. New developers run:
```sh
curl https://mise.run | sh          # install mise
eval "$(mise activate bash)"        # activate (add to shell rc)
mise install                        # install all project tools
mise run setup                      # run project setup task (if defined)
```

### Monorepo Pattern

```
repo/
├── .mise.toml              # shared tools (node, python)
├── services/
│   ├── api/.mise.toml      # api-specific (go, extra env vars)
│   └── web/.mise.toml      # web-specific (node version override)
```

Child `.mise.toml` files inherit and override parent settings.

### Recommended .gitignore Additions

```gitignore
.mise.local.toml
mise.local.toml
```

## CI/CD Integration

### GitHub Actions with `jdx/mise-action`

```yaml
name: CI
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: jdx/mise-action@v2
        with:
          install: true
          cache: true
      - run: mise run test
      - run: mise run build
```

The action reads `.mise.toml`, installs and caches all tools.

### Inline Config (no .mise.toml in repo)

```yaml
- uses: jdx/mise-action@v2
  with:
    mise_toml: |
      [tools]
      node = "20"
      python = "3.12"
```

### Generic CI (non-GitHub)

```sh
curl https://mise.run | sh
eval "$(mise activate bash)"
mise install
mise run test
```

## Common Pitfalls

1. **Forgot shell activation** — tools don't activate. Add `eval "$(mise activate ...)"` to shell rc. Run `mise doctor`.
2. **Conflicting version files** — `.mise.toml` takes precedence over `.tool-versions`/`.node-version`. Remove duplicates.
3. **PATH not updated** — restart shell or `source` rc file after first install.
4. **asdf plugins disabled** — enable with `mise settings set disable_backends ""` if needed.
5. **Global vs local** — `mise use node@20` is local; use `-g` for global default.
6. **Tasks not found** — check `.mise.toml` or `.mise/tasks/`. Run `mise tasks` to list.
7. **Hooks not firing** — hooks require `mise activate`; they don't work with `mise exec` or `mise run`.
8. **Lockfile** — use `mise.lock` for reproducible builds. Generated automatically by `mise use`.

## Quick Reference

```sh
# Tool management
mise use node@20 python@3.12    # install + pin locally
mise use -g go@1.22             # install + pin globally
mise install                    # install from .mise.toml
mise ls                         # list installed
mise outdated                   # check for updates
mise upgrade                    # upgrade all

# Environment
mise env                        # show resolved env vars
mise env --json                 # JSON output
mise where node                 # show install path

# Tasks
mise run build                  # run task
mise build                      # shorthand
mise tasks                      # list tasks
mise watch -t build             # watch mode

# Diagnostics
mise doctor                     # check setup
mise self-update                # update mise itself
mise cache clear                # clear download cache
mise reshim                     # rebuild shims
```

## Resources

### Reference Guides (`references/`)

| File | Contents |
|------|----------|
| `advanced-patterns.md` | File tasks, task dependencies/outputs/parallelism, watch mode, environment templates (Tera), backend-specific config (aqua, cargo, pipx, npm, go), full settings reference, hooks, plugin development, custom registries, profiles |
| `team-workflow.md` | Adopting mise in repos, onboarding developers, CI/CD setup (GitHub Actions via jdx/mise-action, GitLab CI, CircleCI), migration from asdf/.tool-versions, migration from nvm/.nvmrc, migration from pyenv/.python-version, enforcing versions, Docker integration |
| `troubleshooting.md` | Shell activation issues, PATH conflicts, tool install failures (Python/Node/Ruby), backend errors, legacy file conflicts, slow shell startup diagnosis, `mise doctor` interpretation, plugin compatibility |

### Scripts (`scripts/`)

| File | Purpose |
|------|---------|
| `install-mise.sh` | Install mise and configure shell activation (bash/zsh/fish). Supports `--no-activate` flag. |
| `migrate-from-asdf.sh` | Convert `.tool-versions` to `.mise.toml` with tool name mapping (nodejs→node, golang→go). |
| `mise-project-init.sh` | Detect languages in a project and generate `.mise.toml` with tools, tasks, and env vars. |

### Templates & Assets (`assets/`)

| File | Description |
|------|-------------|
| `mise.toml` | Comprehensive `.mise.toml` template with tools, env, tasks, hooks, and settings sections |
| `github-action.yml` | GitHub Actions CI workflow using `jdx/mise-action` with lint/test/build/deploy jobs |
| `dockerfile` | Multi-stage Dockerfile installing tools via mise, producing a minimal runtime image |

<!-- tested: pass -->
